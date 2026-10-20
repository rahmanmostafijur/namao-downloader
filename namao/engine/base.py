"""The engine interface.

Clients, the API and the job runner depend only on this module. A different
open-source engine could be evaluated later by implementing `DownloadEngine`
without changing the public API or any client. No second engine is wired in as
an automatic fallback (see docs/download-reliability.md).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Callable, Protocol

from ..security import ValidatedUrl


class Stage(str, Enum):
    FETCHING_METADATA = "fetching_metadata"
    DOWNLOADING = "downloading"
    MERGING = "merging"
    VERIFYING = "verifying"


@dataclass(frozen=True)
class MediaFormat:
    format_id: str
    height: int | None
    width: int | None
    fps: float | None
    vcodec: str | None
    acodec: str | None
    ext: str | None
    tbr: float | None
    abr: float | None
    size_bytes: int | None  # exact or approximate; None when unknown

    @property
    def has_video(self) -> bool:
        return self.vcodec not in (None, "none")

    @property
    def has_audio(self) -> bool:
        return self.acodec not in (None, "none")


@dataclass(frozen=True)
class MediaMetadata:
    platform: str
    video_id: str | None
    title: str
    uploader: str
    duration_seconds: int
    thumbnail: str | None
    is_live: bool
    formats: tuple[MediaFormat, ...]


@dataclass(frozen=True)
class DownloadRequest:
    url: str
    platform: str
    quality: str  # best | audio | <height>
    workdir: Path
    max_output_bytes: int
    max_duration_seconds: int


@dataclass(frozen=True)
class ProgressUpdate:
    stage: Stage
    percent: float = 0.0
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    speed_bps: float | None = None
    eta_seconds: int | None = None


@dataclass(frozen=True)
class DownloadedFile:
    path: Path
    title: str
    duration_seconds: int | None


@dataclass(frozen=True)
class VerifiedMedia:
    path: Path
    size_bytes: int
    duration_seconds: float
    height: int | None
    width: int | None
    has_video: bool
    has_audio: bool
    container: str


@dataclass(frozen=True)
class ToolStatus:
    name: str
    ok: bool
    version: str | None = None
    note: str | None = None


@dataclass(frozen=True)
class EngineDiagnostics:
    engine: str
    version: str
    channel: str  # stable | nightly
    age_days: int | None
    stale: bool
    tools: tuple[ToolStatus, ...]
    problems: tuple[str, ...] = field(default_factory=tuple)  # make the engine not ready
    warnings: tuple[str, ...] = field(default_factory=tuple)  # worth acting on, still works

    @property
    def ok(self) -> bool:
        return not self.problems


ProgressCallback = Callable[[ProgressUpdate], None]
CancelCheck = Callable[[], bool]


class DownloadEngine(Protocol):
    name: str

    def validate_url(self, url: str) -> ValidatedUrl:
        """Raise NamaoError unless the URL is an allowed, supported platform URL."""

    def extract_metadata(self, url: str) -> MediaMetadata:
        """Fetch title, duration and the formats the source actually offers."""

    def download(
        self,
        request: DownloadRequest,
        on_progress: ProgressCallback,
        should_cancel: CancelCheck,
        deadline: float,
    ) -> DownloadedFile:
        """Download (and merge/convert) to request.workdir.

        Must raise `CancelledError` / `JobTimeoutError` when asked to stop and a
        `NamaoError` for every other failure.
        """

    def verify_output(self, downloaded: DownloadedFile, request: DownloadRequest) -> VerifiedMedia:
        """Prove the file is complete and playable, or raise NamaoError."""

    def diagnostics(self) -> EngineDiagnostics:
        """Real dependency checks (versions of engine, JS runtime, FFmpeg...)."""
