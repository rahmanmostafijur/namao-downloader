"""Worker process: claims queued jobs and runs them with bounded concurrency.

Run standalone with `python -m namao.worker` (Docker Compose does this in its
own container), or embedded in the API process for single-machine/desktop use
(`NAMAO_EMBEDDED_WORKER=1`). Concurrency is `NAMAO_WORKER_CONCURRENCY`.
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
from .jobs.cleanup import remove_job_files, sweep
from .jobs.runner import JobRunner
from .jobs.store import JobStore
from .logging_setup import configure_logging, log_event

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

    # ----------------------------------------------------------- lifecycle
    def start(self) -> None:
        settings = self._settings
        self._store.register_worker(self.worker_id, settings.worker_concurrency)
        diagnostics = self._engine.diagnostics()
        log_event(
            log, "worker.start", worker_id=self.worker_id, concurrency=settings.worker_concurrency,
            engine=diagnostics.engine, engine_version=diagnostics.version, channel=diagnostics.channel,
            engine_age_days=diagnostics.age_days, problems=list(diagnostics.problems),
        )
        for index in range(settings.worker_concurrency):
            self._spawn(self._job_loop, f"namao-job-{index}")
        self._spawn(self._maintenance_loop, "namao-maintenance")

    def _spawn(self, target, name: str) -> None:
        thread = threading.Thread(target=target, name=name, daemon=True)
        thread.start()
        self._threads.append(thread)

    def stop(self, timeout: float = 30.0) -> None:
        """Stop claiming work, cancel running jobs (they become `interrupted`), wait for threads."""
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=timeout)
        ids = self._store.interrupt_worker_jobs(self.worker_id, self._settings.retention_seconds)
        remove_job_files(self._settings, ids)
        self._store.unregister_worker(self.worker_id)
        log_event(log, "worker.stopped", worker_id=self.worker_id, interrupted=len(ids))

    def wait(self) -> None:
        self._stop.wait()

    # --------------------------------------------------------------- loops
    def _job_loop(self) -> None:
        runner = JobRunner(self._settings, self._store, self._engine, self.worker_id,
                           is_stopping=self._stop.is_set)
        while not self._stop.is_set():
            try:
                job = self._store.claim_next(self.worker_id)
            except Exception:  # noqa: BLE001 - keep the loop alive; DB may be briefly locked
                log.exception("worker.claim_failed")
                self._stop.wait(self._settings.poll_interval_seconds * 2)
                continue
            if job is None:
                self._stop.wait(self._settings.poll_interval_seconds)
                continue
            try:
                runner.run(job)
            except Exception:  # noqa: BLE001 - runner normalizes; this is a last resort
                log.exception("worker.run_crashed", extra={"job_id": job.id})

    def _maintenance_loop(self) -> None:
        settings = self._settings
        last_sweep = 0.0

        while not self._stop.wait(settings.heartbeat_interval_seconds):
            try:
                self._store.heartbeat_worker(self.worker_id)
                self._store.heartbeat_jobs(self.worker_id)
                reaped = self._store.reap_stale(settings.stale_after_seconds, settings.retention_seconds)
                if reaped:
                    remove_job_files(settings, reaped)
                    log_event(log, "worker.reaped", count=len(reaped))
                if time.monotonic() - last_sweep >= settings.cleanup_interval_seconds:
                    last_sweep = time.monotonic()
                    sweep(settings, self._store)
            except Exception:  # noqa: BLE001
                log.exception("worker.maintenance_failed")


def main() -> None:
    configure_logging(os.environ.get("NAMAO_LOG_LEVEL", "INFO"))
    settings = load_settings()
    worker = Worker(settings)

    def _shutdown(signum, _frame) -> None:
        log_event(log, "worker.signal", signal=signum)
        worker._stop.set()

    signal.signal(signal.SIGINT, _shutdown)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _shutdown)

    worker.start()
    worker.wait()
    worker.stop()


if __name__ == "__main__":
    main()
