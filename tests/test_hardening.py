"""Regression tests for issues found in the security and concurrency reviews."""

import sqlite3
import threading
import time
import types

import pytest
from fastapi.testclient import TestClient

from namao.api.app import _client_identity, create_app
from namao.engine.ytdlp import YtDlpEngine, _ProgressTracker, _safe_thumbnail
from namao.errors import ErrorCode, NamaoError
from namao.jobs import cleanup
from namao.jobs.store import JobStore
from namao.models import JobStatus
from namao.worker import Worker
from tests.conftest import requires_ffmpeg, wait_for
from tests.fakes import GOOD_URL, FakeEngine, writes_file
from namao.engine.base import ProgressUpdate

BASE = "/api/v1/downloads"


@pytest.fixture(autouse=True)
def _offline_dns(monkeypatch):
    # `namao.security.socket` *is* the global socket module, so delegate localhost to the real resolver
    # (the engine integration tests talk to a real local server).
    import socket
    real = socket.getaddrinfo

    def fake(host, *args, **kwargs):
        if host in ("localhost", "127.0.0.1", "::1"):
            return real(host, *args, **kwargs)
        return [(2, 1, 6, "", ("142.250.72.14", 0))]

    monkeypatch.setattr(socket, "getaddrinfo", fake)


@pytest.fixture()
def env(settings):
    settings.ensure_dirs()
    store, engine = JobStore(settings), FakeEngine(settings)
    return types.SimpleNamespace(settings=settings, store=store, engine=engine)


def client_for(env, **overrides):
    app = create_app(env.settings.with_overrides(**overrides), engine=env.engine, store=env.store)
    return TestClient(app)


# ------------------------------------------------------- client identity

def fake_request(peer, xff=None):
    headers = {"x-forwarded-for": xff} if xff else {}
    return types.SimpleNamespace(client=types.SimpleNamespace(host=peer), headers=headers)


def test_forwarded_for_is_ignored_unless_a_proxy_is_trusted(settings):
    assert _client_identity(fake_request("10.0.0.1", "6.6.6.6"), settings) == "10.0.0.1"


def test_rightmost_trusted_hop_is_used_so_spoofed_prefixes_do_not_matter(settings):
    s = settings.with_overrides(trust_proxy=True, trusted_proxies=1)
    assert _client_identity(fake_request("10.0.0.1", "6.6.6.6, 7.7.7.7, 203.0.113.9"), s) == "203.0.113.9"
    assert _client_identity(fake_request("10.0.0.1", "1.1.1.1, 203.0.113.9"), s) == "203.0.113.9"
    two = settings.with_overrides(trust_proxy=True, trusted_proxies=2)
    assert _client_identity(fake_request("10.0.0.1", "6.6.6.6, 203.0.113.9, 10.0.0.2"), two) == "203.0.113.9"


def test_garbage_or_short_forwarded_headers_fall_back_to_the_peer(settings):
    s = settings.with_overrides(trust_proxy=True, trusted_proxies=2)
    assert _client_identity(fake_request("10.0.0.1", "203.0.113.9"), s) == "10.0.0.1"
    one = settings.with_overrides(trust_proxy=True, trusted_proxies=1)
    assert _client_identity(fake_request("10.0.0.1", "not-an-ip"), one) == "10.0.0.1"
    assert _client_identity(fake_request("10.0.0.1", "x" * 5000), one) == "10.0.0.1"


def test_ipv6_clients_are_keyed_by_their_slash_64(settings):
    a = _client_identity(fake_request("2001:db8:1:2::1"), settings)
    b = _client_identity(fake_request("2001:db8:1:2:ffff:ffff:ffff:ffff"), settings)
    c = _client_identity(fake_request("2001:db8:1:3::1"), settings)
    assert a == b != c and a.endswith("/64")


def test_spoofed_forwarded_for_cannot_evade_the_rate_limit(env):
    limited = dict(trust_proxy=True, trusted_proxies=1, rate_limit_per_minute=2)
    with client_for(env, **limited) as client:
        codes = [
            client.post(f"{BASE}/metadata", json={"url": GOOD_URL},
                        headers={"X-Forwarded-For": f"{i}.{i}.{i}.{i}, 203.0.113.9"}).status_code
            for i in range(1, 6)
        ]
    assert codes == [200, 200, 429, 429, 429]


# ----------------------------------------------------------- API surface

def test_interactive_docs_and_schema_are_off_unless_enabled(env):
    with client_for(env) as client:
        for path in ("/docs", "/redoc", "/openapi.json"):
            assert client.get(path).status_code == 404, path
    with client_for(env, expose_docs=True) as client:
        assert client.get("/openapi.json").status_code == 200


def test_static_pages_get_a_strict_csp_without_inline_scripts(env):
    with client_for(env) as client:
        csp = client.get("/").headers["content-security-policy"]
    assert "script-src 'self';" in csp and "'unsafe-inline'" not in csp.split("script-src")[1].split(";")[0]
    assert "fonts.googleapis.com" in csp and "fonts.gstatic.com" in csp and "frame-ancestors 'none'" in csp


def test_error_detail_is_hidden_from_clients_unless_enabled(env):
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    env.store.claim_next("w1")
    env.store.update(job.id, "w1", status=JobStatus.FAILED, error_code="download_failed", error_message="Failed",
                     error_retryable=False, error_detail="connect to http://10.0.0.5:6379 refused")
    with client_for(env) as client:
        assert client.get(f"{BASE}/{job.id}").json()["error"].get("detail") is None
        assert "10.0.0.5" not in client.get(f"{BASE}/{job.id}").text
    with client_for(env, expose_error_detail=True) as client:
        assert "10.0.0.5" in client.get(f"{BASE}/{job.id}").json()["error"]["detail"]


def test_read_endpoints_are_rate_limited_too(env):
    with client_for(env, read_rate_limit_per_minute=3) as client:
        job = client.post(BASE, json={"url": GOOD_URL}).json()
        codes = [client.get(f"{BASE}/{job['id']}").status_code for _ in range(5)]
    assert 429 in codes


# ------------------------------------------------------------ quotas

def test_one_client_cannot_fill_the_queue(env):
    with client_for(env, max_open_jobs_per_client=2) as client:
        assert [client.post(BASE, json={"url": GOOD_URL}).status_code for _ in range(3)] == [202, 202, 429]


def test_queue_limit_is_atomic_under_concurrent_creates(env):
    results = []

    def create(n):
        try:
            env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1,
                                 client_key=f"c{n}", max_open=5, max_open_per_client=5)
            results.append("ok")
        except NamaoError as exc:
            results.append(exc.code)

    threads = [threading.Thread(target=create, args=(n,)) for n in range(20)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results.count("ok") == 5 and results.count(ErrorCode.QUEUE_FULL) == 15
    assert env.store.open_job_count() == 5


def test_idempotency_keys_are_scoped_per_client_and_bound_to_the_request(env):
    a, created_a = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1,
                                        idempotency_key="shared-key-1", client_key="alice")
    b, created_b = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1,
                                        idempotency_key="shared-key-1", client_key="mallory")
    assert created_a and created_b and a.id != b.id, "another client must not be handed alice's job"
    again, created_again = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1,
                                                idempotency_key="shared-key-1", client_key="alice")
    assert not created_again and again.id == a.id
    with pytest.raises(NamaoError) as err:
        env.store.create_job(url=GOOD_URL, platform="youtube", quality="720", max_attempts=1,
                             idempotency_key="shared-key-1", client_key="alice")
    assert err.value.code == ErrorCode.CONFLICT


def test_api_reports_409_when_a_key_is_replayed_with_different_parameters(env):
    headers = {"Idempotency-Key": "retry-key-0001"}
    with client_for(env) as client:
        assert client.post(BASE, json={"url": GOOD_URL, "quality": "best"}, headers=headers).status_code == 202
        clash = client.post(BASE, json={"url": GOOD_URL, "quality": "720"}, headers=headers)
    assert clash.status_code == 409 and clash.json()["error"]["code"] == "conflict"


# ------------------------------------------------------------------ SSE

def test_sse_streams_are_capped_and_end_at_their_lifetime(env):
    with client_for(env, max_sse_streams=0) as client:
        job = client.post(BASE, json={"url": GOOD_URL}).json()
        assert client.get(f"{BASE}/{job['id']}/progress").status_code == 429
    with client_for(env, sse_max_seconds=1) as client:
        job = client.post(BASE, json={"url": GOOD_URL}).json()  # stays queued: no worker
        started = time.monotonic()
        with client.stream("GET", f"{BASE}/{job['id']}/progress") as response:
            body = "".join(response.iter_text())
        assert "event: job" in body and time.monotonic() - started < 6


# -------------------------------------------------------------- metadata

def test_metadata_is_cached_briefly(env):
    calls = {"n": 0}
    original = env.engine.extract_metadata

    def counted(url):
        calls["n"] += 1
        return original(url)

    env.engine.extract_metadata = counted
    with client_for(env) as client:
        assert client.post(f"{BASE}/metadata", json={"url": GOOD_URL}).status_code == 200
        assert client.post(f"{BASE}/metadata", json={"url": GOOD_URL}).status_code == 200
    assert calls["n"] == 1


def test_slow_metadata_times_out_instead_of_hanging_the_request(env):
    env.engine.extract_metadata = lambda url: time.sleep(2.5)
    with client_for(env, metadata_timeout_seconds=1) as client:
        started = time.monotonic()
        response = client.post(f"{BASE}/metadata", json={"url": GOOD_URL})
    assert response.status_code == 504 and response.json()["error"]["code"] == "timeout"
    assert time.monotonic() - started < 2.4


def test_busy_metadata_slots_fail_fast_with_503(env):
    gate = threading.Event()
    env.engine.extract_metadata = lambda url: gate.wait(5)
    results = {}
    with client_for(env, metadata_concurrency=1, metadata_timeout_seconds=10) as client:
        first = threading.Thread(
            target=lambda: results.setdefault("first", client.post(f"{BASE}/metadata", json={"url": GOOD_URL}).status_code))
        first.start()
        time.sleep(0.5)
        started = time.monotonic()
        other = client.post(f"{BASE}/metadata", json={"url": "https://www.youtube.com/watch?v=other"})
        assert other.status_code == 503 and time.monotonic() - started < 1.5
        gate.set()
        first.join(10)


def test_thumbnails_must_be_plain_https_urls():
    assert _safe_thumbnail("https://i.ytimg.com/vi/x/hq.jpg") == "https://i.ytimg.com/vi/x/hq.jpg"
    for bad in ("http://x/y.jpg", "javascript:alert(1)", "data:image/png;base64,AAA", "https://x/ y", None, 5,
                "https://x/" + "a" * 3000):
        assert _safe_thumbnail(bad) is None


# ------------------------------------------------------- store: lifecycle

def test_database_migration_adds_the_client_key_column_to_an_old_schema(settings):
    settings.ensure_dirs()
    with sqlite3.connect(settings.db_path) as conn:
        conn.execute("""CREATE TABLE jobs (id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            status TEXT NOT NULL, url TEXT NOT NULL, platform TEXT NOT NULL, quality TEXT NOT NULL,
            idempotency_key TEXT UNIQUE, attempt INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 1,
            next_attempt_at REAL NOT NULL DEFAULT 0, worker_id TEXT, heartbeat_at REAL,
            cancel_requested INTEGER NOT NULL DEFAULT 0, percent REAL NOT NULL DEFAULT 0, downloaded_bytes INTEGER,
            total_bytes INTEGER, speed_bps REAL, eta_seconds INTEGER, title TEXT, filename TEXT, output_name TEXT,
            output_size INTEGER, output_height INTEGER, output_duration REAL, error_code TEXT, error_message TEXT,
            error_retryable INTEGER, error_detail TEXT, completed_at REAL, expires_at REAL,
            files_deleted INTEGER NOT NULL DEFAULT 0)""")
        conn.execute("PRAGMA user_version = 1")
    store = JobStore(settings)
    job, _ = store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1, client_key="x")
    assert store.get(job.id).status == JobStatus.QUEUED


def test_a_database_from_a_newer_version_is_refused(settings):
    settings.ensure_dirs()
    JobStore(settings)
    with sqlite3.connect(settings.db_path) as conn:
        conn.execute("PRAGMA user_version = 99")
    with pytest.raises(RuntimeError, match="newer"):
        JobStore(settings)


def test_shutdown_never_overwrites_a_job_that_already_finished(env):
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    env.store.claim_next("w1")
    env.store.update(job.id, "w1", status=JobStatus.COMPLETED, output_name="media.mp4")
    assert env.store.interrupt_worker_jobs("w1", 60) == []
    assert env.store.get(job.id).status == JobStatus.COMPLETED


def test_a_cancelled_queued_job_expires_and_its_leftovers_are_swept(env):
    settings = env.settings
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=3)
    env.store.claim_next("w1")
    leftover = settings.jobs_dir / job.id
    leftover.mkdir(parents=True)
    (leftover / "media.mp4.part").write_bytes(b"partial")
    env.store.schedule_retry(job.id, "w1", next_attempt_at=time.time() + 60, error_code="network_transient",
                             error_message="m", error_retryable=True, error_detail=None)
    cancelled = env.store.request_cancel(job.id, retention_seconds=0.01)
    assert cancelled.status == JobStatus.CANCELLED and cancelled.expires_at is not None
    time.sleep(0.05)
    assert cleanup.sweep(settings, env.store)["expired"] == 1 and not leftover.exists()


def test_source_url_query_tokens_are_scrubbed_once_files_are_deleted(env):
    secret_url = "https://www.facebook.com/watch/?v=1&s=PRIVATE_SHARE_TOKEN"
    job, _ = env.store.create_job(url=secret_url, platform="facebook", quality="best", max_attempts=1)
    env.store.mark_files_deleted(job.id)
    assert "PRIVATE" not in env.store.get(job.id).url and env.store.get(job.id).url.endswith("/watch/")


def test_health_probe_does_not_write_to_the_database(env):
    env.store.register_worker("w1", 1)
    before = env.settings.db_path.stat().st_mtime_ns
    wal = env.settings.db_path.with_name(env.settings.db_path.name + "-wal")
    wal_before = wal.stat().st_mtime_ns if wal.exists() else 0
    for _ in range(3):
        env.store.alive_worker_count(5)
    assert env.settings.db_path.stat().st_mtime_ns == before
    assert (wal.stat().st_mtime_ns if wal.exists() else 0) == wal_before


def test_a_pruned_worker_row_reappears_on_the_next_heartbeat(env):
    env.store.heartbeat_worker("w9", 2)
    assert env.store.alive_worker_count(5) == 1
    env.store.unregister_worker("w9")
    env.store.heartbeat_worker("w9", 2)
    assert env.store.alive_worker_count(5) == 1


# ------------------------------------------------------------------ worker

def test_slow_cleanup_cannot_starve_heartbeats_and_get_healthy_jobs_reaped(env, monkeypatch):
    settings = env.settings.with_overrides(stale_after_seconds=1.0, heartbeat_interval_seconds=0.2)
    done = threading.Event()

    def long_job(request, on_progress, should_cancel, deadline):
        time.sleep(2.5)  # silent for longer than stale_after, like a long FFmpeg merge
        return writes_file()(request, on_progress, should_cancel, deadline)

    engine = FakeEngine(settings)
    engine.default_behavior = long_job
    monkeypatch.setattr("namao.worker.sweep", lambda *a, **k: time.sleep(3) or done.set())
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    worker = Worker(settings, store=env.store, engine=engine)
    worker.start()
    try:
        wait_for(lambda: env.store.get(job.id).is_terminal, timeout=20)
    finally:
        worker.request_stop()
        worker.stop(timeout=10)
    assert env.store.get(job.id).status == JobStatus.COMPLETED


def test_a_job_stuck_past_its_deadline_stops_being_heartbeated_and_is_reaped(env):
    settings = env.settings.with_overrides(stale_after_seconds=0.6, heartbeat_interval_seconds=0.1,
                                           job_timeout_seconds=1)
    engine = FakeEngine(settings)
    engine.default_behavior = lambda request, *a: (request.workdir.mkdir(parents=True, exist_ok=True),
                                                   time.sleep(8))[1]  # ignores cancel and deadline
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    worker = Worker(settings, store=env.store, engine=engine)
    worker.start()
    try:
        wait_for(lambda: env.store.get(job.id).status == JobStatus.INTERRUPTED, timeout=15)
    finally:
        worker.request_stop()
        worker.stop(timeout=1)
    assert env.store.get(job.id).error_code == "interrupted"


def test_a_crash_in_the_runner_marks_the_job_failed_instead_of_leaving_it_active(env, monkeypatch):
    settings = env.settings
    monkeypatch.setattr("namao.worker.JobRunner.run", lambda self, job: (_ for _ in ()).throw(RuntimeError("boom")))
    job, _ = env.store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    worker = Worker(settings, store=env.store, engine=FakeEngine(settings))
    worker.start()
    try:
        wait_for(lambda: env.store.get(job.id).is_terminal, timeout=10)
    finally:
        worker.stop(timeout=5)
    final = env.store.get(job.id)
    assert final.status == JobStatus.FAILED and final.error_code == "internal_error"
    assert "boom" not in (final.error_message or "") + (final.error_detail or "")


# ------------------------------------------------------- progress tracker

def collect():
    updates = []
    return updates, updates.append


def event(name, done, total, status="downloading"):
    return {"filename": name, "downloaded_bytes": done, "total_bytes": total, "status": status}


def test_progress_is_weighted_by_stream_size_and_does_not_jump_per_stream():
    updates, sink = collect()
    tracker = _ProgressTracker([900, 100], sink, max_output_bytes=10 ** 9)
    tracker.update(event("v", 450, 900))
    assert updates[-1].percent == pytest.approx(45.0)
    tracker.update(event("v", 900, 900, "finished"))
    assert updates[-1].percent == pytest.approx(90.0)
    tracker.update(event("a", 50, 100))
    assert updates[-1].percent == pytest.approx(95.0)
    tracker.update(event("a", 100, 100, "finished"))
    assert updates[-1].percent == 99.0 and updates[-1].total_bytes == 1000


def test_progress_with_unknown_sizes_still_advances_and_never_stalls_at_99_mid_stream():
    updates, sink = collect()
    tracker = _ProgressTracker([None, None], sink, max_output_bytes=10 ** 9)
    tracker.update(event("v", 10, 100))
    assert 0 < updates[-1].percent < 50
    tracker.update(event("v", 100, 100, "finished"))
    assert updates[-1].percent == pytest.approx(50.0)
    tracker.update(event("a", 5, 50))
    assert 50 < updates[-1].percent < 99 and updates[-1].total_bytes is None


def test_progress_is_monotonic_even_if_estimates_shrink():
    updates, sink = collect()
    tracker = _ProgressTracker([None], sink, max_output_bytes=10 ** 9)
    tracker.update(event("v", 80, 100))
    tracker.update(event("v", 85, 1000))  # a revised, larger estimate
    assert updates[-1].percent >= updates[0].percent


def test_progress_tracker_is_safe_under_concurrent_fragment_threads():
    updates, sink = collect()
    tracker = _ProgressTracker([None], sink, max_output_bytes=10 ** 12)
    errors = []

    def hammer(n):
        try:
            for i in range(300):
                tracker.update(event(f"frag{n}-{i % 7}", i, 1000))
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=hammer, args=(n,)) for n in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert errors == []


def test_download_size_cap_is_enforced_by_the_tracker():
    _, sink = collect()
    tracker = _ProgressTracker([None], sink, max_output_bytes=100)
    with pytest.raises(NamaoError) as err:
        tracker.update(event("v", 500, None))
    assert err.value.code == ErrorCode.FILE_TOO_LARGE


# ------------------------------------------------------- engine boundary

@pytest.mark.integration
@pytest.mark.parametrize("url", [
    "https://www.youtube.com/playlist?list=PLbpi6ZahtOH6Ar_3GPy3workUk2ioEWFB",
    "https://www.youtube.com/@NASA",
    "https://www.tiktok.com/@someuser",
    "https://www.instagram.com/someuser/",
])
def test_playlist_channel_and_profile_urls_are_rejected_without_any_fetch(settings, url):
    production_like = settings.with_overrides(allow_generic_extractor=False, extra_allowed_hosts=(),
                                              allow_private_networks=False)
    with pytest.raises(NamaoError) as err:
        YtDlpEngine(production_like).extract_metadata(url)
    assert err.value.code in (ErrorCode.UNSUPPORTED_PLATFORM, ErrorCode.UNSUPPORTED_CONTENT)


@pytest.mark.integration
@requires_ffmpeg
def test_a_bug_in_a_progress_callback_surfaces_unchanged_not_as_a_download_failure(settings, media_server, tmp_path):
    engine = YtDlpEngine(settings)
    workdir = tmp_path / "w"
    workdir.mkdir()
    from namao.engine.base import DownloadRequest

    def broken_callback(update: ProgressUpdate):
        if update.percent > 0:
            raise RuntimeError("bug in our code")

    request = DownloadRequest(media_server(), "generic-test", "best", workdir, 10 ** 9, 3600)
    with pytest.raises(RuntimeError, match="bug in our code"):
        engine.download(request, broken_callback, lambda: False, time.monotonic() + 60)
