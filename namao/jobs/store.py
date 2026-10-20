"""Durable job state in SQLite.

Why SQLite and not Redis/Postgres: the project had no database, the API and
worker run on one host sharing a volume, and a few concurrent downloads is
the target scale. WAL mode gives concurrent readers (API) with one writer at
a time; claiming is an atomic `BEGIN IMMEDIATE` transaction, so two workers
can never run the same job. If Namao ever has to span several hosts, replace
this class (its methods are the whole persistence contract) with Postgres.

Every worker-side write is compare-and-set on (id, worker_id, non-terminal),
so a "zombie" worker can never overwrite a job that was cancelled or reaped.
"""

from __future__ import annotations

import secrets
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from ..config import Settings
from ..errors import ErrorCode, NamaoError
from ..models import ACTIVE_STATUSES, TERMINAL_STATUSES, JobStatus

_SCHEMA_VERSION = 2
_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    status TEXT NOT NULL,
    url TEXT NOT NULL,
    platform TEXT NOT NULL,
    quality TEXT NOT NULL,
    idempotency_key TEXT UNIQUE,
    client_key TEXT,
    attempt INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 1,
    next_attempt_at REAL NOT NULL DEFAULT 0,
    worker_id TEXT,
    heartbeat_at REAL,
    cancel_requested INTEGER NOT NULL DEFAULT 0,
    percent REAL NOT NULL DEFAULT 0,
    downloaded_bytes INTEGER,
    total_bytes INTEGER,
    speed_bps REAL,
    eta_seconds INTEGER,
    title TEXT,
    filename TEXT,
    output_name TEXT,
    output_size INTEGER,
    output_height INTEGER,
    output_duration REAL,
    error_code TEXT,
    error_message TEXT,
    error_retryable INTEGER,
    error_detail TEXT,
    completed_at REAL,
    expires_at REAL,
    files_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_jobs_claim ON jobs (status, next_attempt_at, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_expiry ON jobs (expires_at);
CREATE INDEX IF NOT EXISTS idx_jobs_client ON jobs (client_key, status);
CREATE TABLE IF NOT EXISTS workers (
    id TEXT PRIMARY KEY,
    started_at REAL NOT NULL,
    heartbeat_at REAL NOT NULL,
    concurrency INTEGER NOT NULL
);
"""

_TERMINAL = tuple(s.value for s in TERMINAL_STATUSES)
_ACTIVE = tuple(s.value for s in ACTIVE_STATUSES)

# Columns a worker may set via `update`. Anything else is a programming error.
_UPDATABLE = frozenset({
    "status", "percent", "downloaded_bytes", "total_bytes", "speed_bps", "eta_seconds", "title",
    "filename", "output_name", "output_size", "output_height", "output_duration",
    "error_code", "error_message", "error_retryable", "error_detail",
    "completed_at", "expires_at", "next_attempt_at", "files_deleted",
})


@dataclass(frozen=True)
class JobRecord:
    id: str
    created_at: float
    updated_at: float
    status: JobStatus
    url: str
    platform: str
    quality: str
    attempt: int
    max_attempts: int
    next_attempt_at: float
    worker_id: str | None
    heartbeat_at: float | None
    cancel_requested: bool
    percent: float
    downloaded_bytes: int | None
    total_bytes: int | None
    speed_bps: float | None
    eta_seconds: int | None
    title: str | None
    filename: str | None
    output_name: str | None
    output_size: int | None
    output_height: int | None
    output_duration: float | None
    error_code: str | None
    error_message: str | None
    error_retryable: bool | None
    error_detail: str | None
    completed_at: float | None
    expires_at: float | None
    files_deleted: bool

    @property
    def is_terminal(self) -> bool:
        return self.status in TERMINAL_STATUSES


def new_job_id() -> str:
    # 144 bits of randomness: the id is the access capability for the job.
    return secrets.token_urlsafe(18)


def _row_to_job(row: sqlite3.Row) -> JobRecord:
    data = dict(row)
    data.pop("idempotency_key", None)
    data.pop("client_key", None)
    data["status"] = JobStatus(data["status"])
    data["cancel_requested"] = bool(data["cancel_requested"])
    data["files_deleted"] = bool(data["files_deleted"])
    if data["error_retryable"] is not None:
        data["error_retryable"] = bool(data["error_retryable"])
    return JobRecord(**data)


class JobStore:
    def __init__(self, settings: Settings) -> None:
        self._path: Path = settings.db_path
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    # ------------------------------------------------------------ plumbing
    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self._path, timeout=30, isolation_level=None)  # timeout == busy_timeout
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA synchronous = NORMAL")  # per-connection setting
            yield conn
        finally:
            conn.close()

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode = WAL")
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            if version > _SCHEMA_VERSION:
                raise RuntimeError(
                    f"database schema v{version} is newer than this build (v{_SCHEMA_VERSION}); refusing to start"
                )
            existing = {r["name"] for r in conn.execute("PRAGMA table_info(jobs)")}
            if existing and "client_key" not in existing:  # v1 -> v2
                conn.execute("ALTER TABLE jobs ADD COLUMN client_key TEXT")
            conn.executescript(_SCHEMA)
            conn.execute(f"PRAGMA user_version = {_SCHEMA_VERSION}")

    def ping(self) -> bool:
        with self._connect() as conn:
            conn.execute("SELECT 1").fetchone()
        return True

    # -------------------------------------------------------------- create
    def create_job(
        self, *, url: str, platform: str, quality: str, max_attempts: int,
        idempotency_key: str | None = None, client_key: str | None = None,
        max_open: int | None = None, max_open_per_client: int | None = None,
    ) -> tuple[JobRecord, bool]:
        """Insert a job atomically; returns (record, created).

        The queue limits are checked in the same transaction as the insert, so
        concurrent requests cannot overshoot them. An idempotency key is scoped
        to the client; replaying it with a different URL/quality is a conflict.
        """
        now = time.time()
        job_id = new_job_id()
        scoped_key = f"{client_key or '-'}:{idempotency_key}" if idempotency_key else None
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                if scoped_key:
                    row = conn.execute("SELECT * FROM jobs WHERE idempotency_key = ?", (scoped_key,)).fetchone()
                    if row is not None:
                        conn.execute("COMMIT")
                        if row["url"] != url or row["quality"] != quality:
                            raise NamaoError(ErrorCode.CONFLICT, "idempotency key reused with a different request")
                        return _row_to_job(row), False
                if max_open is not None:
                    open_count = conn.execute(
                        f"SELECT COUNT(*) FROM jobs WHERE status NOT IN ({placeholders})", _TERMINAL
                    ).fetchone()[0]
                    if open_count >= max_open:
                        conn.execute("ROLLBACK")
                        raise NamaoError(ErrorCode.QUEUE_FULL)
                if max_open_per_client is not None and client_key:
                    mine = conn.execute(
                        f"SELECT COUNT(*) FROM jobs WHERE client_key = ? AND status NOT IN ({placeholders})",
                        (client_key, *_TERMINAL),
                    ).fetchone()[0]
                    if mine >= max_open_per_client:
                        conn.execute("ROLLBACK")
                        raise NamaoError(ErrorCode.RATE_LIMITED_LOCAL)
                conn.execute(
                    """INSERT INTO jobs
                       (id, created_at, updated_at, status, url, platform, quality,
                        idempotency_key, client_key, max_attempts)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (job_id, now, now, JobStatus.QUEUED.value, url, platform, quality,
                     scoped_key, client_key, max_attempts),
                )
                row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
                conn.execute("COMMIT")
            except NamaoError:
                raise
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return _row_to_job(row), True

    def get(self, job_id: str) -> JobRecord | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _row_to_job(row) if row else None

    def open_job_count(self) -> int:
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            return conn.execute(
                f"SELECT COUNT(*) FROM jobs WHERE status NOT IN ({placeholders})", _TERMINAL
            ).fetchone()[0]

    # --------------------------------------------------------------- claim
    def claim_next(self, worker_id: str) -> JobRecord | None:
        now = time.time()
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                row = conn.execute(
                    """SELECT id FROM jobs
                       WHERE status = ? AND cancel_requested = 0 AND next_attempt_at <= ?
                       ORDER BY created_at LIMIT 1""",
                    (JobStatus.QUEUED.value, now),
                ).fetchone()
                if row is None:
                    conn.execute("COMMIT")
                    return None
                conn.execute(
                    """UPDATE jobs SET status = ?, worker_id = ?, heartbeat_at = ?, updated_at = ?,
                              attempt = attempt + 1, percent = 0, speed_bps = NULL, eta_seconds = NULL
                       WHERE id = ?""",
                    (JobStatus.VALIDATING.value, worker_id, now, now, row["id"]),
                )
                claimed = conn.execute("SELECT * FROM jobs WHERE id = ?", (row["id"],)).fetchone()
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return _row_to_job(claimed)

    # -------------------------------------------------------------- update
    def update(self, job_id: str, worker_id: str, **fields) -> bool:
        """Compare-and-set update. False means this worker no longer owns the job."""
        unknown = set(fields) - _UPDATABLE
        if unknown:
            raise ValueError(f"cannot update columns: {sorted(unknown)}")
        if isinstance(fields.get("status"), JobStatus):
            fields["status"] = fields["status"].value
        if "error_retryable" in fields and fields["error_retryable"] is not None:
            fields["error_retryable"] = int(fields["error_retryable"])
        now = time.time()
        assignments = ", ".join(f"{name} = ?" for name in fields)
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            cursor = conn.execute(
                f"""UPDATE jobs SET {assignments}{', ' if assignments else ''}updated_at = ?, heartbeat_at = ?
                    WHERE id = ? AND worker_id = ? AND status NOT IN ({placeholders})""",
                (*fields.values(), now, now, job_id, worker_id, *_TERMINAL),
            )
        return cursor.rowcount == 1

    def schedule_retry(
        self, job_id: str, worker_id: str, *, next_attempt_at: float, retention_seconds: float = 3600,
        **error_fields,
    ) -> bool:
        """Requeue for another attempt, unless the user asked to cancel meanwhile (then: cancelled)."""
        now = time.time()
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                cursor = conn.execute(
                    f"""UPDATE jobs SET status = ?, worker_id = NULL, next_attempt_at = ?, updated_at = ?,
                               error_code = ?, error_message = ?, error_retryable = ?, error_detail = ?,
                               percent = 0, speed_bps = NULL, eta_seconds = NULL
                        WHERE id = ? AND worker_id = ? AND cancel_requested = 0
                              AND status NOT IN ({placeholders})""",
                    (JobStatus.QUEUED.value, next_attempt_at, now,
                     error_fields.get("error_code"), error_fields.get("error_message"),
                     int(bool(error_fields.get("error_retryable"))), error_fields.get("error_detail"),
                     job_id, worker_id, *_TERMINAL),
                )
                done = cursor.rowcount == 1
                if not done:
                    cursor = conn.execute(
                        f"""UPDATE jobs SET status = ?, worker_id = NULL, updated_at = ?, completed_at = ?,
                                   expires_at = ?, error_code = 'cancelled',
                                   error_message = 'The download was cancelled.', error_retryable = 0
                            WHERE id = ? AND worker_id = ? AND cancel_requested = 1
                                  AND status NOT IN ({placeholders})""",
                        (JobStatus.CANCELLED.value, now, now, now + retention_seconds, job_id, worker_id, *_TERMINAL),
                    )
                    done = cursor.rowcount == 1
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return done

    def is_cancel_requested(self, job_id: str) -> bool:
        with self._connect() as conn:
            row = conn.execute("SELECT cancel_requested, status FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return bool(row and (row["cancel_requested"] or row["status"] in _TERMINAL))

    def request_cancel(self, job_id: str, retention_seconds: float) -> JobRecord | None:
        """Cancel a queued job immediately; flag a running one so its worker stops it."""
        now = time.time()
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
                if row is None:
                    conn.execute("COMMIT")
                    return None
                status = row["status"]
                if status == JobStatus.QUEUED.value:
                    conn.execute(
                        """UPDATE jobs SET status = ?, cancel_requested = 1, updated_at = ?, completed_at = ?,
                                  expires_at = ?, error_code = 'cancelled',
                                  error_message = 'The download was cancelled.', error_retryable = 0
                           WHERE id = ?""",
                        (JobStatus.CANCELLED.value, now, now, now + retention_seconds, job_id),
                    )
                elif status in _ACTIVE:
                    conn.execute(
                        "UPDATE jobs SET cancel_requested = 1, updated_at = ? WHERE id = ?", (now, job_id)
                    )
                updated = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return _row_to_job(updated)

    # ------------------------------------------------------- liveness/reap
    def heartbeat_jobs(self, worker_id: str, job_ids: list[str]) -> None:
        """Refresh liveness for jobs a thread of this worker is *actually* running."""
        if not job_ids:
            return
        now = time.time()
        marks = ",".join("?" * len(job_ids))
        with self._connect() as conn:
            conn.execute(
                f"UPDATE jobs SET heartbeat_at = ? WHERE worker_id = ? AND id IN ({marks})",
                (now, worker_id, *job_ids),
            )

    def reap_stale(self, stale_after: float, retention_seconds: float) -> list[str]:
        """Mark active jobs whose worker stopped heartbeating as `interrupted`."""
        now = time.time()
        placeholders = ",".join("?" * len(_ACTIVE))
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute(
                    f"SELECT id FROM jobs WHERE status IN ({placeholders}) AND heartbeat_at < ?",
                    (*_ACTIVE, now - stale_after),
                ).fetchall()
                ids = [r["id"] for r in rows]
                for job_id in ids:
                    conn.execute(
                        """UPDATE jobs SET status = ?, updated_at = ?, completed_at = ?, expires_at = ?,
                                  error_code = 'interrupted',
                                  error_message = 'The download was interrupted. Start it again.',
                                  error_retryable = 1, worker_id = NULL
                           WHERE id = ?""",
                        (JobStatus.INTERRUPTED.value, now, now, now + retention_seconds, job_id),
                    )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return ids

    def interrupt_worker_jobs(self, worker_id: str, retention_seconds: float) -> list[str]:
        """On shutdown: mark this worker's still-active jobs interrupted (never touches finished ones)."""
        now = time.time()
        placeholders = ",".join("?" * len(_ACTIVE))
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute(
                    f"SELECT id FROM jobs WHERE worker_id = ? AND status IN ({placeholders})",
                    (worker_id, *_ACTIVE),
                ).fetchall()
                ids = [r["id"] for r in rows]
                for job_id in ids:
                    conn.execute(
                        f"""UPDATE jobs SET status = ?, updated_at = ?, completed_at = ?, expires_at = ?,
                                  error_code = 'interrupted',
                                  error_message = 'The download was interrupted. Start it again.',
                                  error_retryable = 1
                           WHERE id = ? AND worker_id = ? AND status IN ({placeholders})""",
                        (JobStatus.INTERRUPTED.value, now, now, now + retention_seconds, job_id, worker_id, *_ACTIVE),
                    )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        return ids

    # ------------------------------------------------------------- workers
    def register_worker(self, worker_id: str, concurrency: int) -> None:
        now = time.time()
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO workers (id, started_at, heartbeat_at, concurrency) VALUES (?, ?, ?, ?)",
                (worker_id, now, now, concurrency),
            )

    def heartbeat_worker(self, worker_id: str, concurrency: int) -> None:
        now = time.time()
        with self._connect() as conn:  # upsert: a pruned row re-registers itself
            conn.execute(
                """INSERT INTO workers (id, started_at, heartbeat_at, concurrency) VALUES (?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET heartbeat_at = excluded.heartbeat_at""",
                (worker_id, now, now, concurrency),
            )

    def unregister_worker(self, worker_id: str) -> None:
        with self._connect() as conn:
            conn.execute("DELETE FROM workers WHERE id = ?", (worker_id,))

    def prune_workers(self, stale_after: float) -> None:
        with self._connect() as conn:
            conn.execute("DELETE FROM workers WHERE heartbeat_at < ?", (time.time() - stale_after * 5,))

    def alive_worker_count(self, stale_after: float) -> int:
        with self._connect() as conn:  # read-only: safe for health probes
            return conn.execute(
                "SELECT COUNT(*) FROM workers WHERE heartbeat_at >= ?", (time.time() - stale_after,)
            ).fetchone()[0]

    # ------------------------------------------------------------- cleanup
    def expired_with_files(self) -> list[JobRecord]:
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            rows = conn.execute(
                f"""SELECT * FROM jobs WHERE status IN ({placeholders}) AND files_deleted = 0
                    AND expires_at IS NOT NULL AND expires_at < ?""",
                (*_TERMINAL, time.time()),
            ).fetchall()
        return [_row_to_job(r) for r in rows]

    def mark_files_deleted(self, job_id: str) -> None:
        with self._connect() as conn:
            conn.execute(
                """UPDATE jobs SET files_deleted = 1, output_name = NULL,
                          url = CASE WHEN instr(url, '?') > 0 THEN substr(url, 1, instr(url, '?') - 1) ELSE url END
                   WHERE id = ?""",
                (job_id,),
            )

    def purge_rows_older_than(self, age_seconds: float) -> int:
        placeholders = ",".join("?" * len(_TERMINAL))
        with self._connect() as conn:
            cursor = conn.execute(
                f"DELETE FROM jobs WHERE status IN ({placeholders}) AND files_deleted = 1 AND completed_at < ?",
                (*_TERMINAL, time.time() - age_seconds),
            )
        return cursor.rowcount

    def known_job_ids(self) -> set[str]:
        with self._connect() as conn:
            return {r["id"] for r in conn.execute("SELECT id FROM jobs")}
