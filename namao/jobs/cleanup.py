"""Expiry of finished jobs' files, orphan directory sweep, and size accounting."""

from __future__ import annotations

import gc
import logging
import os
import shutil
import time
from pathlib import Path

from ..config import Settings
from ..logging_setup import log_event
from .store import JobStore

log = logging.getLogger("namao.cleanup")

ORPHAN_MIN_AGE_SECONDS = 3600  # never touch a directory younger than this
ROW_RETENTION_SECONDS = 7 * 24 * 3600


def dir_size(path: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                continue  # file vanished mid-walk
    return total


_REMOVE_ATTEMPTS = 6
_REMOVE_DELAY_SECONDS = 0.25


def remove_tree(path: Path) -> bool:
    """Delete a directory tree, tolerating files that are briefly still open.

    On Windows (and after a cancelled yt-dlp fragment download) a `.part` file can
    stay open until its owner is garbage-collected, which makes a plain
    `rmtree(ignore_errors=True)` silently leave the directory behind. Returns
    True only when the directory is really gone.
    """
    for attempt in range(_REMOVE_ATTEMPTS):
        shutil.rmtree(path, ignore_errors=True)
        if not path.exists():
            return True
        gc.collect()  # drop unreachable file objects that still hold handles
        time.sleep(_REMOVE_DELAY_SECONDS * (attempt + 1))
    return not path.exists()


def _remove_job_dir(settings: Settings, job_id: str) -> bool:
    target = (settings.jobs_dir / job_id).resolve()
    # Defence in depth: only ever delete a direct child of the jobs directory.
    if target.parent != settings.jobs_dir.resolve():
        log.error("cleanup.refused_path", extra={"job_id": job_id})
        return False
    return remove_tree(target)


def remove_job_files(settings: Settings, job_ids: list[str]) -> None:
    for job_id in job_ids:
        _remove_job_dir(settings, job_id)


def sweep(settings: Settings, store: JobStore) -> dict[str, int]:
    """Delete files of expired jobs, orphaned directories, and very old rows."""
    expired = store.expired_with_files()
    removed = 0
    for job in expired:
        # Only record success when the files are really gone; otherwise the next sweep retries.
        if _remove_job_dir(settings, job.id):
            store.mark_files_deleted(job.id)
            removed += 1
        else:
            log_event(log, "cleanup.delete_failed", job_id=job.id)

    orphans = 0
    if settings.jobs_dir.is_dir():
        known = store.known_job_ids()
        cutoff = time.time() - ORPHAN_MIN_AGE_SECONDS
        for child in settings.jobs_dir.iterdir():
            try:
                is_orphan = child.is_dir() and child.name not in known and child.stat().st_mtime < cutoff
            except OSError:  # vanished mid-iteration (concurrent cleanup)
                continue
            if is_orphan:
                orphans += remove_tree(child)

    purged = store.purge_rows_older_than(ROW_RETENTION_SECONDS)
    if removed or orphans or purged:
        log_event(log, "cleanup.sweep", expired=removed, orphans=orphans, purged_rows=purged)
    return {"expired": removed, "orphans": orphans, "purged_rows": purged}
