"""Executes one claimed job through the lifecycle.

queued → validating → fetching_metadata → downloading → merging → verifying
→ completed. Other outcomes: failed, cancelled, or interrupted (worker shutdown;
the reaper also produces `interrupted`). A transient failure sends the job back
to `queued` with a backoff delay while attempts remain. A job is only
`completed` after the output passed FFprobe verification.
"""

from __future__ import annotations

import logging
import random
import shutil
import time
from pathlib import Path
from typing import Callable

from ..config import Settings
from ..engine.base import DownloadEngine, DownloadRequest, ProgressUpdate, Stage
from ..errors import (
    CancelledError, ErrorCode, JobTimeoutError, NamaoError, classify_exception,
)
from ..logging_setup import log_event
from ..models import JobStatus
from ..security import safe_filename
from .cleanup import dir_size, remove_tree
from .store import JobRecord, JobStore

log = logging.getLogger("namao.runner")

_STAGE_TO_STATUS = {
    Stage.FETCHING_METADATA: JobStatus.FETCHING_METADATA,
    Stage.DOWNLOADING: JobStatus.DOWNLOADING,
    Stage.MERGING: JobStatus.MERGING,
    Stage.VERIFYING: JobStatus.VERIFYING,
}
_PROGRESS_WRITE_INTERVAL = 0.5  # seconds between DB writes for the same stage
_CANCEL_POLL_INTERVAL = 1.0
# Failures after which partial files are useless; others keep yt-dlp's .part files for resume.
_DISCARD_PARTIALS = {ErrorCode.OUTPUT_INVALID, ErrorCode.MERGE_FAILED, ErrorCode.FILE_TOO_LARGE}


class _LostOwnership(Exception):
    """The job was cancelled/reaped/reassigned underneath this worker."""


def backoff_delay(attempt: int, base: float, cap: float, rng: random.Random | None = None) -> float:
    """Exponential backoff with equal jitter: delay ∈ [d/2, d], d = min(cap, base·2^(attempt-1))."""
    rng = rng or random
    ceiling = min(cap, base * (2 ** max(attempt - 1, 0)))
    return ceiling / 2 + rng.random() * ceiling / 2


class JobRunner:
    def __init__(
        self,
        settings: Settings,
        store: JobStore,
        engine: DownloadEngine,
        worker_id: str,
        is_stopping: Callable[[], bool] = lambda: False,
    ) -> None:
        self._settings = settings
        self._store = store
        self._engine = engine
        self._worker_id = worker_id
        self._is_stopping = is_stopping

    # ----------------------------------------------------------------- run
    def run(self, job: JobRecord) -> None:
        jobdir = self._settings.jobs_dir / job.id
        started = time.monotonic()
        deadline = started + self._settings.job_timeout_seconds
        log_event(log, "job.start", job_id=job.id, platform=job.platform, attempt=job.attempt)
        try:
            self._execute(job, jobdir, deadline)
        except _LostOwnership:
            log_event(log, "job.lost_ownership", job_id=job.id)
            remove_tree(jobdir)
        except CancelledError:
            self._finish_cancelled_or_interrupted(job, jobdir)
        except BaseException as exc:  # noqa: BLE001 - every failure is normalized below
            self._handle_failure(job, jobdir, exc)
        finally:
            log_event(log, "job.end", job_id=job.id, seconds=round(time.monotonic() - started, 1))

    def _execute(self, job: JobRecord, jobdir: Path, deadline: float) -> None:
        self._set(job, status=JobStatus.VALIDATING)
        validated = self._engine.validate_url(job.url)
        self._preflight_storage()
        jobdir.mkdir(parents=True, exist_ok=True)

        request = DownloadRequest(
            url=validated.url,
            platform=validated.platform,
            quality=job.quality,
            workdir=jobdir,
            max_output_bytes=self._settings.max_output_bytes,
            max_duration_seconds=self._settings.max_duration_seconds,
        )
        cancel = self._cancel_check(job.id)
        progress = self._progress_writer(job)

        downloaded = self._engine.download(request, progress, cancel, deadline)

        self._set(job, status=JobStatus.VERIFYING, percent=99.0, speed_bps=None, eta_seconds=None)
        verified = self._engine.verify_output(downloaded, request)
        if cancel():
            raise CancelledError()

        remove_tree(jobdir / "tmp")
        now = time.time()
        filename = safe_filename(downloaded.title, verified.path.suffix.lstrip("."))
        self._set(
            job,
            status=JobStatus.COMPLETED,
            percent=100.0,
            speed_bps=None,
            eta_seconds=None,
            title=downloaded.title[:300],
            filename=filename,
            output_name=verified.path.resolve().relative_to(jobdir.resolve()).as_posix(),
            output_size=verified.size_bytes,
            output_height=verified.height,
            output_duration=verified.duration_seconds,
            error_code=None, error_message=None, error_retryable=None, error_detail=None,
            completed_at=now,
            expires_at=now + self._settings.retention_seconds,
        )
        log_event(log, "job.completed", job_id=job.id, size=verified.size_bytes, height=verified.height)

    # ------------------------------------------------------------ helpers
    def _set(self, job: JobRecord, **fields) -> None:
        if not self._store.update(job.id, self._worker_id, **fields):
            raise _LostOwnership()

    def _cancel_check(self, job_id: str) -> Callable[[], bool]:
        state = {"checked": 0.0, "value": False}

        def should_cancel() -> bool:
            if self._is_stopping():
                return True
            now = time.monotonic()
            if not state["value"] and now - state["checked"] >= _CANCEL_POLL_INTERVAL:
                state["checked"] = now
                state["value"] = self._store.is_cancel_requested(job_id)
            return state["value"]

        return should_cancel

    def _progress_writer(self, job: JobRecord) -> Callable[[ProgressUpdate], None]:
        last = {"stage": None, "at": 0.0}

        def write(update: ProgressUpdate) -> None:
            now = time.monotonic()
            if update.stage == last["stage"] and now - last["at"] < _PROGRESS_WRITE_INTERVAL:
                return
            last["stage"], last["at"] = update.stage, now
            self._set(
                job,
                status=_STAGE_TO_STATUS[update.stage],
                percent=round(update.percent, 1),
                downloaded_bytes=update.downloaded_bytes,
                total_bytes=update.total_bytes,
                speed_bps=update.speed_bps,
                eta_seconds=update.eta_seconds,
            )

        return write

    def _preflight_storage(self) -> None:
        settings = self._settings
        settings.jobs_dir.mkdir(parents=True, exist_ok=True)
        free = shutil.disk_usage(settings.jobs_dir).free
        if free < settings.min_free_bytes:
            raise NamaoError(ErrorCode.STORAGE_FULL, f"free space {free} below minimum {settings.min_free_bytes}")
        used = dir_size(settings.jobs_dir)
        if used >= settings.max_storage_bytes:
            raise NamaoError(ErrorCode.STORAGE_FULL, f"temporary storage {used} reached its limit")

    # ----------------------------------------------------------- failures
    def _finish_cancelled_or_interrupted(self, job: JobRecord, jobdir: Path) -> None:
        user_cancelled = self._store.is_cancel_requested(job.id) and not self._is_stopping()
        remove_tree(jobdir)
        code = ErrorCode.CANCELLED if user_cancelled else ErrorCode.INTERRUPTED
        status = JobStatus.CANCELLED if user_cancelled else JobStatus.INTERRUPTED
        error = NamaoError(code)
        self._store.update(
            job.id, self._worker_id, status=status, speed_bps=None, eta_seconds=None,
            error_code=code.value, error_message=error.message, error_retryable=error.retryable,
            completed_at=time.time(), expires_at=time.time() + self._settings.retention_seconds,
        )
        log_event(log, "job.cancelled" if user_cancelled else "job.interrupted", job_id=job.id)

    def _handle_failure(self, job: JobRecord, jobdir: Path, exc: BaseException) -> None:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            raise exc
        if isinstance(exc, JobTimeoutError):
            error = NamaoError(ErrorCode.TIMEOUT)
        elif isinstance(exc, NamaoError):
            error = exc
        else:
            error = classify_exception(exc)
            if error.code in (ErrorCode.DOWNLOAD_FAILED, ErrorCode.METADATA_FAILED):
                # An unexpected exception type is a bug on our side: say so, log only the class.
                log.error("job.unexpected_error", extra={"job_id": job.id, "exc_type": type(exc).__name__})
                error = NamaoError(ErrorCode.INTERNAL, type(exc).__name__)

        will_retry = error.auto_retryable and job.attempt < job.max_attempts
        if error.code in _DISCARD_PARTIALS or not will_retry:
            remove_tree(jobdir)

        fields = dict(
            error_code=error.code.value, error_message=error.message,
            error_retryable=error.retryable, error_detail=error.detail,
        )
        if will_retry:
            delay = backoff_delay(job.attempt, self._settings.retry_base_seconds, self._settings.retry_max_seconds)
            self._store.schedule_retry(
                job.id, self._worker_id, next_attempt_at=time.time() + delay,
                retention_seconds=self._settings.retention_seconds, **fields,
            )
            log_event(log, "job.retry_scheduled", job_id=job.id, code=error.code.value,
                      attempt=job.attempt, delay_seconds=round(delay, 1))
            return

        now = time.time()
        self._store.update(
            job.id, self._worker_id, status=JobStatus.FAILED, speed_bps=None, eta_seconds=None,
            completed_at=now, expires_at=now + self._settings.retention_seconds, **fields,
        )
        log_event(log, "job.failed", job_id=job.id, code=error.code.value, attempt=job.attempt)
