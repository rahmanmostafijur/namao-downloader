"""Shared domain types and the public (wire) schemas.

The same `JobResponse` / `ErrorResponse` shapes are consumed by the web,
mobile and desktop clients (see docs/architecture.md).
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field


class JobStatus(str, Enum):
    QUEUED = "queued"
    VALIDATING = "validating"
    FETCHING_METADATA = "fetching_metadata"
    DOWNLOADING = "downloading"
    MERGING = "merging"
    VERIFYING = "verifying"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"
    INTERRUPTED = "interrupted"


TERMINAL_STATUSES = frozenset(
    {JobStatus.COMPLETED, JobStatus.FAILED, JobStatus.CANCELLED, JobStatus.INTERRUPTED}
)
ACTIVE_STATUSES = frozenset(
    {JobStatus.VALIDATING, JobStatus.FETCHING_METADATA, JobStatus.DOWNLOADING,
     JobStatus.MERGING, JobStatus.VERIFYING}
)

_QUALITY_RE = re.compile(r"^(best|audio|[1-9][0-9]{2,4})$")
MIN_HEIGHT, MAX_HEIGHT = 100, 8640


def parse_quality(value: str) -> tuple[str, int | None]:
    """Return (kind, height) for "best" | "audio" | "<height>", else ValueError."""
    if not _QUALITY_RE.fullmatch(value):
        raise ValueError("quality must be 'best', 'audio' or a height such as '1080'")
    if value in ("best", "audio"):
        return value, None
    height = int(value)
    if not MIN_HEIGHT <= height <= MAX_HEIGHT:
        raise ValueError("height out of range")
    return "height", height


def iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# Wire schemas
# ---------------------------------------------------------------------------


class UrlRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: str = Field(min_length=1, max_length=2048)


class CreateDownloadRequest(UrlRequest):
    quality: str = Field(default="best", max_length=8, description="'best', 'audio' or a height like '1080'")


class FormatOption(BaseModel):
    id: str = Field(description="Value to send as `quality`")
    label: str
    kind: str = Field(description="video | audio")
    height: int | None = None
    note: str = ""
    size_bytes: int | None = Field(default=None, description="Estimate; null when unknown")
    needs_merge: bool = False


class MetadataResponse(BaseModel):
    platform: str
    title: str
    uploader: str = ""
    duration_seconds: int = 0
    thumbnail: str | None = None
    formats: list[FormatOption]
    ffmpeg: bool = True


class Progress(BaseModel):
    percent: float = 0.0
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    speed_bps: float | None = None
    eta_seconds: int | None = None


class ErrorDetail(BaseModel):
    code: str
    message: str
    retryable: bool
    detail: str | None = None


class ErrorResponse(BaseModel):
    error: ErrorDetail


class JobResult(BaseModel):
    filename: str
    size_bytes: int
    height: int | None = None
    duration_seconds: float | None = None
    download_url: str


class JobResponse(BaseModel):
    id: str
    status: JobStatus
    platform: str
    quality: str
    title: str | None = None
    progress: Progress
    attempt: int = 0
    max_attempts: int = 1
    retry_at: str | None = None
    error: ErrorDetail | None = None
    result: JobResult | None = None
    created_at: str
    updated_at: str
    expires_at: str | None = None
