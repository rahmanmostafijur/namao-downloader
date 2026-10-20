"""Job pipeline behaviour: lifecycle, retries, cancellation, cleanup, limits."""

import random
import threading
import time

import pytest

from namao.errors import ErrorCode, NamaoError
from namao.jobs.runner import JobRunner, backoff_delay
from namao.jobs.store import JobStore
from namao.models import JobStatus
from tests.conftest import wait_for
from tests.fakes import GOOD_URL, FakeEngine, blocks_until_cancelled, fails_with, writes_file


@pytest.fixture(autouse=True)
def _offline_dns(monkeypatch):
    monkeypatch.setattr("namao.security.socket.getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("142.250.72.14", 0))])


class Harness:
    def __init__(self, settings, behaviors=None):
        settings.ensure_dirs()
        self.settings = settings
        self.store = JobStore(settings)
        self.engine = FakeEngine(settings, behaviors)
        self.stopping = threading.Event()
        self.runner = JobRunner(settings, self.store, self.engine, "w1", is_stopping=self.stopping.is_set)
        self.statuses: list[str] = []
        original = self.store.update

        def spy(job_id, worker_id, **fields):
            if "status" in fields:
                value = fields["status"]
                self.statuses.append(getattr(value, "value", value))
            return original(job_id, worker_id, **fields)

        self.store.update = spy  # type: ignore[method-assign]

    def submit(self, quality="best", max_attempts=3):
        job, _ = self.store.create_job(url=GOOD_URL, platform="youtube", quality=quality, max_attempts=max_attempts)
        return job

    def run_once(self):
        job = self.store.claim_next("w1")
        assert job is not None
        self.runner.run(job)
        return self.store.get(job.id)

    def run_to_end(self, job_id, limit=10):
        for _ in range(limit):
            current = self.store.get(job_id)
            if current.is_terminal:
                return current
            wait_for(lambda: self.store.get(job_id).next_attempt_at <= time.time(), timeout=5)
            claimed = self.store.claim_next("w1")
            if claimed:
                self.runner.run(claimed)
        return self.store.get(job_id)

    def jobdir(self, job_id):
        return self.settings.jobs_dir / job_id


def test_happy_path_walks_every_stage_and_publishes_a_verified_result(settings):
    h = Harness(settings)
    job = h.submit()
    done = h.run_once()
    assert done.status == JobStatus.COMPLETED and done.percent == 100.0
    assert done.output_size == 4096 and done.filename == "Test Video.mp4" and done.output_height == 720
    assert (h.jobdir(job.id) / done.output_name).is_file()
    assert not (h.jobdir(job.id) / "tmp").exists()
    assert done.error_code is None and done.expires_at > time.time()
    order = [s for i, s in enumerate(h.statuses) if i == 0 or s != h.statuses[i - 1]]
    assert order == ["validating", "fetching_metadata", "downloading", "merging", "verifying", "completed"]


def test_progress_is_written_from_engine_events(settings):
    seen = []
    h = Harness(settings)
    original = h.store.update

    def spy(job_id, worker_id, **fields):
        if "downloaded_bytes" in fields and fields["downloaded_bytes"]:
            seen.append((fields["percent"], fields["downloaded_bytes"]))
        return original(job_id, worker_id, **fields)

    h.store.update = spy
    h.submit()
    h.run_once()
    assert (10, 1) in seen


def test_transient_failure_is_retried_with_backoff_then_succeeds(settings):
    h = Harness(settings, [fails_with(NamaoError(ErrorCode.NETWORK_TRANSIENT, "timed out")), writes_file()])
    job = h.submit()
    after_first = h.run_once()
    assert after_first.status == JobStatus.QUEUED and after_first.attempt == 1
    assert after_first.next_attempt_at > time.time() - 1 and after_first.error_code == "network_transient"
    final = h.run_to_end(job.id)
    assert final.status == JobStatus.COMPLETED and final.attempt == 2 and final.error_code is None


def test_retries_are_bounded_and_the_final_error_is_reported(settings):
    transient = NamaoError(ErrorCode.NETWORK_TRANSIENT, "timed out")
    h = Harness(settings, [fails_with(transient)] * 5)
    job = h.submit(max_attempts=3)
    final = h.run_to_end(job.id)
    assert final.status == JobStatus.FAILED and final.attempt == 3 and h.engine.download_calls == 3
    assert final.error_code == "network_transient" and final.error_retryable is True
    assert not h.jobdir(job.id).exists()


@pytest.mark.parametrize("code", [ErrorCode.VIDEO_UNAVAILABLE, ErrorCode.AUTH_REQUIRED, ErrorCode.GEO_RESTRICTED,
                                  ErrorCode.FORMAT_UNAVAILABLE, ErrorCode.ENGINE_OUTDATED, ErrorCode.FFMPEG_MISSING])
def test_permanent_failures_are_never_retried(settings, code):
    h = Harness(settings, [fails_with(NamaoError(code, "detail"))])
    job = h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.attempt == 1 and h.engine.download_calls == 1
    assert final.error_code == code.value
    assert not h.jobdir(job.id).exists(), "partial files must be removed on failure"


def test_unexpected_exceptions_become_internal_errors_without_leaking_text(settings):
    h = Harness(settings, [fails_with(KeyError("secret-token-123 in C:\\srv\\data"))])
    final = (h.submit(), h.run_once())[1]
    assert final.status == JobStatus.FAILED and final.error_code == "internal_error"
    assert "secret" not in (final.error_message or "") + (final.error_detail or "")


def test_failed_jobs_never_look_successful(settings):
    h = Harness(settings, [fails_with(NamaoError(ErrorCode.VIDEO_UNAVAILABLE))])
    h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.output_name is None and final.output_size is None


def test_empty_output_is_rejected_and_deleted(settings):
    h = Harness(settings, [writes_file(size=0)])
    job = h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.error_code == "output_invalid"
    assert final.output_name is None and not h.jobdir(job.id).exists()


def test_verification_failure_is_not_retried_and_discards_output(settings):
    h = Harness(settings)
    h.engine.verify_error = NamaoError(ErrorCode.OUTPUT_INVALID, "truncated")
    job = h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.error_code == "output_invalid" and final.attempt == 1
    assert not h.jobdir(job.id).exists()


def test_cancel_stops_a_running_download_and_cleans_up(settings):
    started = []
    h = Harness(settings, [blocks_until_cancelled(started)])
    job = h.submit()
    result = {}
    thread = threading.Thread(target=lambda: result.setdefault("job", h.run_once()))
    thread.start()
    wait_for(lambda: started)
    assert h.jobdir(job.id).exists()
    h.store.request_cancel(job.id)
    thread.join(10)
    final = result["job"]
    assert final.status == JobStatus.CANCELLED and final.error_code == "cancelled"
    assert not h.jobdir(job.id).exists()


def test_worker_shutdown_marks_running_jobs_interrupted_not_cancelled(settings):
    started = []
    h = Harness(settings, [blocks_until_cancelled(started)])
    job = h.submit()
    result = {}
    thread = threading.Thread(target=lambda: result.setdefault("job", h.run_once()))
    thread.start()
    wait_for(lambda: started)
    h.stopping.set()
    thread.join(10)
    final = result["job"]
    assert final.status == JobStatus.INTERRUPTED and final.error_retryable is True
    assert not h.jobdir(job.id).exists()


def test_job_timeout_fails_with_timeout(settings):
    h = Harness(settings.with_overrides(job_timeout_seconds=0), [blocks_until_cancelled()])
    job = h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.error_code == "timeout"
    assert not h.jobdir(job.id).exists()


def test_insufficient_free_disk_fails_before_touching_the_engine(settings):
    h = Harness(settings.with_overrides(min_free_bytes=10 ** 18))
    h.submit()
    final = h.run_once()
    assert final.status == JobStatus.FAILED and final.error_code == "storage_full"
    assert h.engine.download_calls == 0


def test_temporary_storage_cap_is_enforced(settings):
    h = Harness(settings.with_overrides(max_storage_bytes=1000))
    (settings.jobs_dir / "older").mkdir(parents=True)
    (settings.jobs_dir / "older" / "f.bin").write_bytes(b"x" * 5000)
    h.submit()
    final = h.run_once()
    assert final.error_code == "storage_full" and h.engine.download_calls == 0


def test_job_reaped_mid_run_stops_quietly_without_overwriting_state(settings):
    started = []
    h = Harness(settings.with_overrides(stale_after_seconds=0.01), [blocks_until_cancelled(started)])
    job = h.submit()
    thread = threading.Thread(target=h.run_once)
    thread.start()
    wait_for(lambda: started)
    time.sleep(0.05)
    h.store.reap_stale(stale_after=0.01, retention_seconds=60)
    thread.join(10)
    final = h.store.get(job.id)
    assert final.status == JobStatus.INTERRUPTED
    assert not h.jobdir(job.id).exists()


def test_two_workers_never_run_the_same_job(settings):
    settings.ensure_dirs()
    store = JobStore(settings)
    engine = FakeEngine(settings)
    store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    ran = []

    def worker(name):
        job = store.claim_next(name)
        if job:
            JobRunner(settings, store, engine, name).run(job)
            ran.append(name)

    threads = [threading.Thread(target=worker, args=(f"w{i}",)) for i in range(6)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(ran) == 1 and engine.download_calls == 1


def test_each_job_writes_only_inside_its_own_directory(settings):
    h = Harness(settings)
    a, b = h.submit(), h.submit()
    h.run_once()
    h.run_once()
    dirs = {p.name for p in settings.jobs_dir.iterdir()}
    assert dirs == {a.id, b.id}


def test_backoff_grows_exponentially_with_jitter_and_is_capped():
    rng = random.Random(7)
    delays = [backoff_delay(n, base=2, cap=60, rng=rng) for n in range(1, 8)]
    ceilings = [min(60, 2 * 2 ** (n - 1)) for n in range(1, 8)]
    for delay, ceiling in zip(delays, ceilings):
        assert ceiling / 2 <= delay <= ceiling
    assert max(delays) <= 60
    assert len({round(backoff_delay(3, 2, 60, random.Random(s)), 6) for s in range(20)}) > 1, "must be jittered"
