"""Worker process: claims queued jobs and runs them with bounded concurrency.

Run standalone with `python -m namao.worker` (Docker Compose does this in its
own container), or embedded in the API process for single-machine/desktop use
(`NAMAO_EMBEDDED_WORKER=1`). Concurrency is `NAMAO_WORKER_CONCURRENCY`.

Threads
  * N job threads      claim a job and run it to a terminal state (or a retry).
  * 1 heartbeat thread does *only* liveness: worker row + the jobs a job thread
                       is really running. It never does slow work, so a slow
                       cleanup cannot make healthy jobs look dead.
  * 1 maintenance thread reaps jobs of dead workers and sweeps expired files.

Drain mode: while `<data dir>/DRAIN` exists no new job is claimed, so a deploy or
engine update can wait for running jobs to finish (see `python -m namao.ops`).

A job whose thread has run past its deadline plus a grace period stops being
heartbeated, so it is reaped and the API stops reporting it as active even if
the thread is stuck somewhere no cancel/timeout hook can reach (e.g. FFmpeg).
"""

from __future__ import annotations

import logging
import os
import signal
import socket
import threading
import time
import uuid

from .config import Settings, load_settings
from .engine.base import DownloadEngine
from .engine.ytdlp import YtDlpEngine
from .errors import ErrorCode, NamaoError
from .jobs.cleanup import remove_job_files, sweep
from .jobs.runner import JobRunner
from .jobs.store import JobRecord, JobStore
from .logging_setup import configure_logging, log_event
from .models import JobStatus

log = logging.getLogger("namao.worker")


class Worker:
    def __init__(self, settings: Settings, store: JobStore | None = None,
                 engine: DownloadEngine | None = None) -> None:
        self._settings = settings
        settings.ensure_dirs()
        self._store = store or JobStore(settings)
        self._engine = engine or YtDlpEngine(settings)
        self.worker_id = f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:6]}"
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._inflight: dict[str, float] = {}  # job id -> monotonic deadline
        self._inflight_lock = threading.Lock()

    # ----------------------------------------------------------- lifecycle
    def start(self) -> None:
        settings = self._settings
        self._store.register_worker(self.worker_id, settings.worker_concurrency)
        diagnostics = self._engine.diagnostics()
        log_event(
            log, "worker.start", worker_id=self.worker_id, concurrency=settings.worker_concurrency,
            engine=diagnostics.engine, engine_version=diagnostics.version, channel=diagnostics.channel,
            engine_age_days=diagnostics.age_days, problems=list(diagnostics.problems),
            warnings=list(diagnostics.warnings),
        )
        for index in range(settings.worker_concurrency):
            self._spawn(self._job_loop, f"namao-job-{index}")
        self._spawn(self._heartbeat_loop, "namao-heartbeat")
        self._spawn(self._maintenance_loop, "namao-maintenance")

    def _spawn(self, target, name: str) -> None:
        thread = threading.Thread(target=target, name=name, daemon=True)
        thread.start()
        self._threads.append(thread)

    def request_stop(self) -> None:
        self._stop.set()

    def stop(self, timeout: float = 30.0) -> None:
        """Stop claiming work and ask running jobs to stop; wait up to `timeout` in total.

        Jobs that have not finished by then are marked `interrupted` and their
        files removed. A thread stuck outside any engine hook may outlive this
        call (it is a daemon thread and finds it has lost ownership when it wakes).
        """
        self._stop.set()
        deadline = time.monotonic() + timeout
        for thread in self._threads:
            thread.join(timeout=max(0.0, deadline - time.monotonic()))
        ids = self._store.interrupt_worker_jobs(self.worker_id, self._settings.retention_seconds)
        remove_job_files(self._settings, ids)
        self._store.unregister_worker(self.worker_id)
        log_event(log, "worker.stopped", worker_id=self.worker_id, interrupted=len(ids))

    def wait(self) -> None:
        # A bounded wait keeps the main thread responsive to Ctrl+C on Windows.
        while not self._stop.wait(0.5):
            pass

    # --------------------------------------------------------------- loops
    def _job_loop(self) -> None:
        runner = JobRunner(self._settings, self._store, self._engine, self.worker_id,
                           is_stopping=self._stop.is_set)
        while not self._stop.is_set():
            if self._settings.drain_file.exists():  # operator is updating: finish, don't start
                self._stop.wait(self._settings.poll_interval_seconds)
                continue
            try:
                job = self._store.claim_next(self.worker_id)
            except Exception:  # noqa: BLE001 - keep the loop alive; DB may be briefly locked
                log.exception("worker.claim_failed")
                self._stop.wait(self._settings.poll_interval_seconds * 2)
                continue
            if job is None:
                self._stop.wait(self._settings.poll_interval_seconds)
                continue
            self._run(runner, job)

    def _run(self, runner: JobRunner, job: JobRecord) -> None:
        with self._inflight_lock:
            self._inflight[job.id] = time.monotonic() + self._settings.job_timeout_seconds
        try:
            runner.run(job)
        except Exception as exc:  # noqa: BLE001 - runner normalizes; this is a last resort
            log.exception("worker.run_crashed", extra={"job_id": job.id})
            error = NamaoError(ErrorCode.INTERNAL, type(exc).__name__)
            now = time.time()
            try:  # never leave the row "active" with no thread behind it
                self._store.update(
                    job.id, self.worker_id, status=JobStatus.FAILED, speed_bps=None, eta_seconds=None,
                    error_code=error.code.value, error_message=error.message, error_retryable=error.retryable,
                    completed_at=now, expires_at=now + self._settings.retention_seconds,
                )
            except Exception:  # noqa: BLE001 - the reaper will clean it up once heartbeats stop
                log.exception("worker.mark_failed_failed", extra={"job_id": job.id})
        finally:
            with self._inflight_lock:
                self._inflight.pop(job.id, None)

    def _live_job_ids(self) -> list[str]:
        """Jobs worth keeping alive: running, and not hopelessly past their deadline."""
        now = time.monotonic()
        grace = self._settings.stale_after_seconds
        with self._inflight_lock:
            return [job_id for job_id, deadline in self._inflight.items() if now <= deadline + grace]

    def _heartbeat_loop(self) -> None:
        settings = self._settings
        while not self._stop.wait(settings.heartbeat_interval_seconds):
            try:
                self._store.heartbeat_worker(self.worker_id, settings.worker_concurrency)
                self._store.heartbeat_jobs(self.worker_id, self._live_job_ids())
            except Exception:  # noqa: BLE001
                log.exception("worker.heartbeat_failed")

    def _maintenance_loop(self) -> None:
        settings = self._settings
        last_sweep = 0.0
        while not self._stop.wait(settings.heartbeat_interval_seconds):
            try:
                reaped = self._store.reap_stale(settings.stale_after_seconds, settings.retention_seconds)
                if reaped:
                    remove_job_files(settings, reaped)
                    log_event(log, "worker.reaped", count=len(reaped))
                if time.monotonic() - last_sweep >= settings.cleanup_interval_seconds:
                    last_sweep = time.monotonic()
                    self._store.prune_workers(settings.stale_after_seconds)
                    sweep(settings, self._store)
            except Exception:  # noqa: BLE001
                log.exception("worker.maintenance_failed")


def main() -> None:
    configure_logging(os.environ.get("NAMAO_LOG_LEVEL", "INFO"))
    settings = load_settings()
    worker = Worker(settings)

    def _shutdown(signum, _frame) -> None:
        log_event(log, "worker.signal", signal=signum)
        worker.request_stop()

    signal.signal(signal.SIGINT, _shutdown)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _shutdown)

    worker.start()
    worker.wait()
    worker.stop()


if __name__ == "__main__":
    main()
