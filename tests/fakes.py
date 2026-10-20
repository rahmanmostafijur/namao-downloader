"""A scriptable in-memory engine for runner/API tests.

It implements the same `DownloadEngine` protocol as the real yt-dlp engine, so
job-pipeline behaviour (retries, cancellation, cleanup, state machine) can be
tested deterministically. Real extractor/FFmpeg behaviour is covered separately
by tests/test_engine_integration.py and tests/test_pipeline_e2e.py.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Callable

from namao.config import Settings
from namao.engine.base import (
    DownloadedFile, DownloadRequest, EngineDiagnostics, MediaFormat, MediaMetadata,
    ProgressCallback, ProgressUpdate, Stage, ToolStatus, VerifiedMedia,
)
from namao.errors import CancelledError, ErrorCode, JobTimeoutError, NamaoError
from namao.security import ValidatedUrl, validate_url

Behavior = Callable[[DownloadRequest, ProgressCallback, Callable[[], bool], float], DownloadedFile]

GOOD_URL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"


def writes_file(name: str = "media.mp4", size: int = 4096, title: str = "Test Video") -> Behavior:
    """A successful download that reports all stages."""

    def behavior(request, on_progress, should_cancel, deadline):
        on_progress(ProgressUpdate(stage=Stage.FETCHING_METADATA))
        on_progress(ProgressUpdate(stage=Stage.DOWNLOADING, percent=10, downloaded_bytes=1, total_bytes=10))
        request.workdir.mkdir(parents=True, exist_ok=True)
        path = request.workdir / name
        path.write_bytes(b"\0" * size)
        (request.workdir / "tmp").mkdir(exist_ok=True)
        on_progress(ProgressUpdate(stage=Stage.MERGING, percent=99))
        return DownloadedFile(path=path, title=title, duration_seconds=10)

    return behavior


def fails_with(error: Exception) -> Behavior:
    def behavior(request, on_progress, should_cancel, deadline):
        request.workdir.mkdir(parents=True, exist_ok=True)
        (request.workdir / "media.mp4.part").write_bytes(b"partial")
        raise error

    return behavior


def blocks_until_cancelled(started: list | None = None) -> Behavior:
    def behavior(request, on_progress, should_cancel, deadline):
        request.workdir.mkdir(parents=True, exist_ok=True)
        (request.workdir / "media.mp4.part").write_bytes(b"partial")
        on_progress(ProgressUpdate(stage=Stage.DOWNLOADING, percent=5))
        if started is not None:
            started.append(True)
        while True:
            if should_cancel():
                raise CancelledError()
            if time.monotonic() > deadline:
                raise JobTimeoutError()
            time.sleep(0.02)

    return behavior


class FakeEngine:
    name = "fake"

    def __init__(self, settings: Settings, behaviors: list[Behavior] | None = None) -> None:
        self._settings = settings
        self._behaviors = list(behaviors or [])
        self.default_behavior: Behavior = writes_file()
        self.download_calls = 0
        self.metadata: MediaMetadata | Exception = MediaMetadata(
            platform="youtube", video_id="aqz", title="Test Video", uploader="Tester",
            duration_seconds=10, thumbnail="https://i.ytimg.com/vi/x/hq.jpg", is_live=False,
            formats=(
                MediaFormat("v1080", 1080, 1920, 30, "avc1", "none", "mp4", 4000, None, 4_000_000),
                MediaFormat("v720", 720, 1280, 30, "avc1", "none", "mp4", 2000, None, 2_000_000),
                MediaFormat("a1", None, None, None, "none", "mp4a", "m4a", 128, 128, 160_000),
            ),
        )
        self.verify_error: NamaoError | None = None
        self.diagnostics_problems: tuple[str, ...] = ()
        self.diagnostics_warnings: tuple[str, ...] = ()

    def queue(self, *behaviors: Behavior) -> "FakeEngine":
        self._behaviors.extend(behaviors)
        return self

    def validate_url(self, url: str) -> ValidatedUrl:
        return validate_url(url, self._settings)

    def extract_metadata(self, url: str) -> MediaMetadata:
        if isinstance(self.metadata, Exception):
            raise self.metadata
        return self.metadata

    def download(self, request, on_progress, should_cancel, deadline) -> DownloadedFile:
        self.download_calls += 1
        behavior = self._behaviors.pop(0) if self._behaviors else self.default_behavior
        return behavior(request, on_progress, should_cancel, deadline)

    def verify_output(self, downloaded: DownloadedFile, request: DownloadRequest) -> VerifiedMedia:
        if self.verify_error:
            raise self.verify_error
        size = downloaded.path.stat().st_size
        if size == 0:
            raise NamaoError(ErrorCode.OUTPUT_INVALID, "empty")
        return VerifiedMedia(
            path=downloaded.path, size_bytes=size, duration_seconds=10.0, height=720, width=1280,
            has_video=True, has_audio=True, container="mp4",
        )

    def diagnostics(self) -> EngineDiagnostics:
        return EngineDiagnostics(
            engine="fake", version="2099.01.01", channel="stable", age_days=1, stale=False,
            tools=(ToolStatus("ffmpeg", True, "8.0"), ToolStatus("ffprobe", True, "8.0")),
            problems=self.diagnostics_problems, warnings=self.diagnostics_warnings,
        )
