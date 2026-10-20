"""Standalone worker lifecycle and environment-driven configuration."""

import time

import pytest

from namao.config import GIB, MIB, load_settings
from namao.jobs.store import JobStore
from namao.models import JobStatus
from namao.worker import Worker
from tests.conftest import wait_for
from tests.fakes import GOOD_URL, FakeEngine, blocks_until_cancelled, writes_file


@pytest.fixture(autouse=True)
def _offline_dns(monkeypatch):
    monkeypatch.setattr("namao.security.socket.getaddrinfo",
                        lambda *a, **k: [(2, 1, 6, "", ("142.250.72.14", 0))])


# ------------------------------------------------------------------ config

def test_defaults_are_conservative_for_a_small_host(monkeypatch):
    for name in list(__import__("os").environ):
        if name.startswith("NAMAO_"):
            monkeypatch.delenv(name)
    s = load_settings()
    assert s.worker_concurrency == 2 and s.max_attempts == 3
    assert s.max_output_bytes == 2 * GIB and s.min_free_bytes == 1 * GIB and s.retention_seconds == 3600
    assert s.allow_private_networks is False and s.allow_generic_extractor is False
    assert s.extra_allowed_hosts == () and s.api_key is None and s.embedded_worker is False


def test_every_limit_is_adjustable_from_the_environment(monkeypatch):
    values = {
        "WORKER_CONCURRENCY": "5", "MAX_ATTEMPTS": "4", "JOB_TIMEOUT_SECONDS": "99", "MAX_DURATION_SECONDS": "100",
        "MAX_OUTPUT_MB": "512", "MIN_FREE_MB": "256", "MAX_STORAGE_MB": "4096", "RETENTION_SECONDS": "120",
        "MAX_QUEUE_LENGTH": "7", "RATE_LIMIT_PER_MINUTE": "9", "JS_RUNTIME": "Node", "API_KEY": "k",
        "TRUST_PROXY": "yes", "EMBEDDED_WORKER": "1", "CORS_ORIGINS": "https://a.example, https://b.example",
        "BIN_DIR": "/opt/bin", "DATA_DIR": "/var/namao", "ENGINE_STALE_DAYS": "30",
    }
    for key, value in values.items():
        monkeypatch.setenv(f"NAMAO_{key}", value)
    s = load_settings()
    assert (s.worker_concurrency, s.max_attempts, s.job_timeout_seconds, s.max_duration_seconds) == (5, 4, 99, 100)
    assert (s.max_output_bytes, s.min_free_bytes, s.max_storage_bytes) == (512 * MIB, 256 * MIB, 4096 * MIB)
    assert (s.retention_seconds, s.max_queue_length, s.rate_limit_per_minute) == (120, 7, 9)
    assert s.js_runtime == "node" and s.api_key == "k" and s.trust_proxy and s.embedded_worker
    assert s.cors_origins == ("https://a.example", "https://b.example") and s.engine_stale_days == 30
    assert str(s.bin_dir).endswith("bin") and str(s.db_path).endswith("namao.db")


def test_invalid_numbers_fail_fast_with_a_clear_message(monkeypatch):
    monkeypatch.setenv("NAMAO_MAX_ATTEMPTS", "three")
    with pytest.raises(ValueError, match="NAMAO_MAX_ATTEMPTS"):
        load_settings()


def test_concurrency_never_drops_below_one(monkeypatch):
    monkeypatch.setenv("NAMAO_WORKER_CONCURRENCY", "0")
    assert load_settings().worker_concurrency == 1


# ------------------------------------------------------------------ worker

def test_worker_runs_queued_jobs_up_to_its_concurrency_and_stops_cleanly(settings):
    settings.ensure_dirs()
    store = JobStore(settings)
    engine = FakeEngine(settings)
    ids = [store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)[0].id
           for _ in range(5)]
    worker = Worker(settings, store=store, engine=engine)
    worker.start()
    try:
        wait_for(lambda: all(store.get(i).status == JobStatus.COMPLETED for i in ids), timeout=20)
        assert store.alive_worker_count(settings.stale_after_seconds) == 1
    finally:
        worker.stop()
    assert store.alive_worker_count(settings.stale_after_seconds) == 0
    assert engine.download_calls == 5


def test_concurrency_is_bounded(settings):
    settings = settings.with_overrides(worker_concurrency=2)
    settings.ensure_dirs()
    store = JobStore(settings)
    peak, live = {"n": 0}, {"n": 0}

    def tracked(request, on_progress, should_cancel, deadline):
        live["n"] += 1
        peak["n"] = max(peak["n"], live["n"])
        try:
            time.sleep(0.3)
            return writes_file()(request, on_progress, should_cancel, deadline)
        finally:
            live["n"] -= 1

    engine = FakeEngine(settings)
    engine.default_behavior = tracked
    ids = [store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)[0].id
           for _ in range(6)]
    worker = Worker(settings, store=store, engine=engine)
    worker.start()
    try:
        wait_for(lambda: all(store.get(i).is_terminal for i in ids), timeout=30)
    finally:
        worker.stop()
    assert peak["n"] == 2, "never more than worker_concurrency jobs at once, and the pool is actually used"


def test_stopping_a_worker_marks_its_running_job_interrupted_and_cleans_up(settings):
    settings.ensure_dirs()
    store = JobStore(settings)
    started = []
    engine = FakeEngine(settings, [blocks_until_cancelled(started)])
    job, _ = store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    worker = Worker(settings, store=store, engine=engine)
    worker.start()
    wait_for(lambda: started)
    worker.stop()
    final = store.get(job.id)
    assert final.status == JobStatus.INTERRUPTED and final.error_retryable is True
    assert not (settings.jobs_dir / job.id).exists()


def test_a_crashed_worker_is_detected_and_its_job_reaped_by_another_worker(settings):
    settings.ensure_dirs()
    store = JobStore(settings)
    job, _ = store.create_job(url=GOOD_URL, platform="youtube", quality="best", max_attempts=1)
    store.claim_next("crashed-worker")  # claimed, then the process died: no more heartbeats
    jobdir = settings.jobs_dir / job.id
    jobdir.mkdir(parents=True)
    (jobdir / "media.mp4.part").write_bytes(b"partial")
    survivor = Worker(settings, store=store, engine=FakeEngine(settings))
    survivor.start()
    try:
        wait_for(lambda: store.get(job.id).status == JobStatus.INTERRUPTED, timeout=15)
        wait_for(lambda: not jobdir.exists(), timeout=10)
    finally:
        survivor.stop()
    assert store.get(job.id).error_code == "interrupted"


def test_an_empty_api_key_refuses_to_start_instead_of_silently_disabling_auth(monkeypatch):
    monkeypatch.setenv("NAMAO_API_KEY", "   ")
    with pytest.raises(ValueError, match="NAMAO_API_KEY"):
        load_settings()
    monkeypatch.delenv("NAMAO_API_KEY")
    assert load_settings().api_key is None


def test_stale_threshold_must_exceed_heartbeat_interval(monkeypatch):
    monkeypatch.setenv("NAMAO_HEARTBEAT_INTERVAL_SECONDS", "10")
    monkeypatch.setenv("NAMAO_STALE_AFTER_SECONDS", "15")
    with pytest.raises(ValueError, match="STALE_AFTER"):
        load_settings()


def test_a_binary_planted_in_the_working_directory_is_never_used(tmp_path, monkeypatch):
    import os
    from namao.config import Settings
    from namao.engine.tools import find_executable
    planted = tmp_path / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
    planted.write_text("#!/bin/sh\necho evil\n")
    planted.chmod(0o755)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PATH", str(tmp_path / "elsewhere"))
    assert find_executable("ffmpeg", Settings()) is None
    assert find_executable("ffmpeg", Settings(bin_dir=tmp_path)) is not None  # explicit opt-in works
