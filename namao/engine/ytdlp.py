"""yt-dlp implementation of `DownloadEngine`.

This is the only module that imports `yt_dlp`. It uses the Python API (no
shell, no string-built command lines), restricts yt-dlp to the platform
extractors Namao supports (so redirects can never reach the generic
"fetch any URL" extractor), enables the configured JS runtime explicitly, and
does NOT enable `remote_components`: no code is downloaded at runtime.
"""

from __future__ import annotations

import logging
import re
import time
from datetime import date
from importlib import metadata as importlib_metadata
from pathlib import Path
from typing import Any

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

from ..config import Settings
from ..errors import (
    CancelledError, ErrorCode, JobTimeoutError, NamaoError, classify_exception, redact,
)
from ..models import parse_quality
from ..security import ValidatedUrl, validate_url
from .base import (
    CancelCheck, DownloadedFile, DownloadEngine, DownloadRequest, EngineDiagnostics,
    MediaFormat, MediaMetadata, ProgressCallback, ProgressUpdate, Stage, ToolStatus, VerifiedMedia,
)
from .media import verify_media_file
from .tools import Toolchain, get_toolchain

log = logging.getLogger("namao.engine")

# Extractor *keys* (not URLs) yt-dlp may use. Single-video extractors only:
# playlists/channels/search/user pages are intentionally excluded.
_ALLOWED_EXTRACTORS = (
    r"^Youtube$", r"^YoutubeYtBe$", r"^YoutubeClip$",
    r"^Facebook$", r"^FacebookReel$", r"^FacebookRedirectURL$", r"^FacebookPluginsVideo$",
    r"^TikTok$", r"^TikTokVM$",
    r"^Instagram$", r"^InstagramIOS$",
    r"^Twitter$",
)
_TEST_GENERIC_EXTRACTOR = (r"^Generic$",)
_MAX_LOGGED_WARNINGS = 20
_OUTPUT_TEMPLATE = "media.%(ext)s"
_YT_DLP_AGE_RE = re.compile(r"^(\d{4})\.(\d{1,2})\.(\d{1,2})")


class _YdlLogger:
    """Routes yt-dlp output through our redacting logger and keeps warnings."""

    def __init__(self) -> None:
        self.warnings: list[str] = []

    def debug(self, msg: str) -> None:  # yt-dlp sends progress lines here too; drop them
        return None

    def info(self, msg: str) -> None:
        return None

    def warning(self, msg: str) -> None:
        if len(self.warnings) < _MAX_LOGGED_WARNINGS:
            self.warnings.append(redact(str(msg)))
        log.warning("yt-dlp warning", extra={"ytdlp_warning": redact(str(msg))[:300]})

    def error(self, msg: str) -> None:
        log.error("yt-dlp error", extra={"ytdlp_error": redact(str(msg))[:300]})


class _ProgressTracker:
    """Combine per-stream yt-dlp events into one monotonic progress value.

    A merged download is two sequential transfers (video, then audio); the raw
    per-file percentage would jump 0 → 100 twice. Here progress is
    downloaded / expected-total across all streams, capped at 99% until the
    post-processing (merge/convert) finishes.
    """

    def __init__(self, expected_total: int | None, on_progress: ProgressCallback,
                 max_output_bytes: int, stream_count: int) -> None:
        self._expected_total = expected_total or 0
        self._on_progress = on_progress
        self._max_bytes = max_output_bytes
        self._stream_count = max(stream_count, 1)
        self._downloaded: dict[str, int] = {}
        self._totals: dict[str, int] = {}
        self._last_percent = 0.0

    def downloading(self, event: dict[str, Any]) -> None:
        key = str(event.get("filename") or event.get("tmpfilename") or "stream")
        done = int(event.get("downloaded_bytes") or 0)
        total = int(event.get("total_bytes") or event.get("total_bytes_estimate") or 0)
        self._downloaded[key] = max(self._downloaded.get(key, 0), done)
        if total:
            self._totals[key] = total

        downloaded = sum(self._downloaded.values())
        if downloaded > self._max_bytes:
            raise NamaoError(ErrorCode.FILE_TOO_LARGE, f"download exceeded {self._max_bytes} bytes")

        known_total = max(self._expected_total, sum(self._totals.values()))
        if known_total:
            percent = min(99.0, downloaded * 100.0 / known_total)
        else:  # unknown size: spread streams evenly
            percent = min(99.0, (len(self._downloaded) - 1 + 0.0) * 100.0 / self._stream_count)
        self._last_percent = max(self._last_percent, percent)
        self._on_progress(
            ProgressUpdate(
                stage=Stage.DOWNLOADING,
                percent=self._last_percent,
                downloaded_bytes=downloaded,
                total_bytes=known_total or None,
                speed_bps=event.get("speed"),
                eta_seconds=int(event["eta"]) if event.get("eta") is not None else None,
            )
        )

    def merging(self) -> None:
        self._on_progress(ProgressUpdate(stage=Stage.MERGING, percent=max(self._last_percent, 99.0)))


class YtDlpEngine:
    name = "yt-dlp"

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    # ----------------------------------------------------------- validation
    def validate_url(self, url: str) -> ValidatedUrl:
        return validate_url(url, self._settings)

    # -------------------------------------------------------------- options
    def _toolchain(self) -> Toolchain:
        return get_toolchain(self._settings)

    def _base_options(self, logger: _YdlLogger, toolchain: Toolchain) -> dict[str, Any]:
        settings = self._settings
        settings.cache_dir.mkdir(parents=True, exist_ok=True)
        allowed = list(_ALLOWED_EXTRACTORS)
        if settings.allow_generic_extractor:  # tests only
            allowed.extend(_TEST_GENERIC_EXTRACTOR)
        options: dict[str, Any] = {
            "logger": logger,
            "quiet": True,
            "noprogress": True,
            "noplaylist": True,
            "socket_timeout": settings.socket_timeout_seconds,
            "retries": 3,
            "fragment_retries": 3,
            "extractor_retries": 2,
            "concurrent_fragment_downloads": settings.concurrent_fragments,
            "cachedir": str(settings.cache_dir),
            "allowed_extractors": allowed,
            "enable_file_urls": False,
            "remote_components": [],  # never fetch/execute code at runtime
            "format_sort": ["res", "fps", "vcodec:h264", "acodec:aac"],
        }
        runtime = toolchain.js_runtime
        if runtime.ok and runtime.path:
            options["js_runtimes"] = {runtime.name: {"path": runtime.path}}
        if toolchain.ffmpeg_dir:
            options["ffmpeg_location"] = toolchain.ffmpeg_dir
        return options

    def _stale(self) -> bool:
        age = _engine_age_days()
        return age is not None and age > self._settings.engine_stale_days

    # ------------------------------------------------------------- metadata
    def extract_metadata(self, url: str) -> MediaMetadata:
        validated = self.validate_url(url)
        info = self._extract_info(validated.url, phase="metadata")
        return _to_metadata(info, validated.platform)

    def _extract_info(self, url: str, *, phase: str) -> dict[str, Any]:
        logger = _YdlLogger()
        toolchain = self._toolchain()
        options = self._base_options(logger, toolchain)
        try:
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(url, download=False)
        except (CancelledError, JobTimeoutError, NamaoError):
            raise
        except UnsupportedError as exc:
            raise NamaoError(ErrorCode.UNSUPPORTED_PLATFORM, str(exc)) from exc
        except (DownloadError, ExtractorError) as exc:
            raise self._classify(exc, phase, logger, toolchain) from exc
        except Exception as exc:  # noqa: BLE001 - normalized, never leaked raw
            raise self._classify(exc, phase, logger, toolchain) from exc
        if not info:
            raise NamaoError(ErrorCode.METADATA_FAILED, "extractor returned nothing")
        return _first_video(info)

    def _classify(self, exc: BaseException, phase: str, logger: _YdlLogger, toolchain: Toolchain) -> NamaoError:
        error = classify_exception(exc, phase=phase, engine_stale=self._stale())
        # Warnings give context yt-dlp omits from the exception itself.
        if error.code in (ErrorCode.METADATA_FAILED, ErrorCode.DOWNLOAD_FAILED, ErrorCode.EXTRACTOR_BROKEN,
                          ErrorCode.FORMAT_UNAVAILABLE):
            joined = " ".join(logger.warnings).lower()
            if "javascript runtime" in joined and not toolchain.js_runtime.ok:
                return NamaoError(ErrorCode.JS_RUNTIME_MISSING, str(exc))
        return error

    # ------------------------------------------------------------- download
    def download(
        self,
        request: DownloadRequest,
        on_progress: ProgressCallback,
        should_cancel: CancelCheck,
        deadline: float,
    ) -> DownloadedFile:
        toolchain = self._toolchain()
        if not toolchain.ffmpeg.ok:
            raise NamaoError(ErrorCode.FFMPEG_MISSING, toolchain.ffmpeg.note)
        kind, height = parse_quality(request.quality)

        logger = _YdlLogger()
        options = self._base_options(logger, toolchain)
        options.update(_selection_options(kind, height))
        options["paths"] = {"home": str(request.workdir), "temp": str(request.workdir / "tmp")}
        options["outtmpl"] = _OUTPUT_TEMPLATE

        def guard() -> None:
            if should_cancel():
                raise CancelledError()
            if time.monotonic() > deadline:
                raise JobTimeoutError()

        tracker_box: dict[str, _ProgressTracker] = {}

        def progress_hook(event: dict[str, Any]) -> None:
            guard()
            if event.get("status") == "downloading" and "t" in tracker_box:
                tracker_box["t"].downloading(event)

        def postprocessor_hook(event: dict[str, Any]) -> None:
            guard()
            if event.get("status") == "started" and "t" in tracker_box:
                tracker_box["t"].merging()

        options["progress_hooks"] = [progress_hook]
        options["postprocessor_hooks"] = [postprocessor_hook]

        try:
            with yt_dlp.YoutubeDL(options) as ydl:
                guard()
                on_progress(ProgressUpdate(stage=Stage.FETCHING_METADATA))
                info = _first_video(ydl.extract_info(request.url, download=False))
                self._check_policy(info, request)
                formats = info.get("requested_formats") or [info]
                tracker_box["t"] = _ProgressTracker(
                    _expected_size(formats), on_progress, request.max_output_bytes, len(formats)
                )
                guard()
                on_progress(ProgressUpdate(stage=Stage.DOWNLOADING))
                result = ydl.process_ie_result(info, download=True)
        except (CancelledError, JobTimeoutError, NamaoError):
            raise
        except Exception as exc:  # noqa: BLE001 - normalized, never leaked raw
            raise self._classify(exc, "download", logger, toolchain) from exc

        path = _final_path(result)
        if path is None or not path.is_file():
            raise NamaoError(ErrorCode.OUTPUT_INVALID, "engine reported success but produced no file")
        return DownloadedFile(
            path=path,
            title=str(result.get("title") or "video"),
            duration_seconds=int(result["duration"]) if result.get("duration") else None,
        )

    def _check_policy(self, info: dict[str, Any], request: DownloadRequest) -> None:
        if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
            raise NamaoError(ErrorCode.UNSUPPORTED_CONTENT, "live stream")
        duration = info.get("duration")
        if duration and duration > request.max_duration_seconds:
            raise NamaoError(ErrorCode.DURATION_TOO_LONG, f"{duration}s > {request.max_duration_seconds}s")
        estimate = _expected_size(info.get("requested_formats") or [info])
        if estimate and estimate > request.max_output_bytes:
            raise NamaoError(ErrorCode.FILE_TOO_LARGE, f"estimated {estimate} bytes")

    # --------------------------------------------------------------- verify
    def verify_output(self, downloaded: DownloadedFile, request: DownloadRequest) -> VerifiedMedia:
        toolchain = self._toolchain()
        if not toolchain.ffprobe.ok or not toolchain.ffprobe.path:
            raise NamaoError(ErrorCode.FFMPEG_MISSING, toolchain.ffprobe.note)
        return verify_media_file(
            downloaded.path,
            ffprobe=toolchain.ffprobe.path,
            expect_video=request.quality != "audio",
            max_bytes=request.max_output_bytes,
            source_duration=downloaded.duration_seconds,
            max_duration=request.max_duration_seconds,
        )

    # ---------------------------------------------------------- diagnostics
    def diagnostics(self) -> EngineDiagnostics:
        toolchain = self._toolchain()
        version = yt_dlp.version.__version__
        age = _engine_age_days()
        stale = age is not None and age > self._settings.engine_stale_days
        channel = "nightly" if ".dev" in _package_version("yt-dlp") else "stable"

        problems: list[str] = []
        tools = [
            ToolStatus("ffmpeg", toolchain.ffmpeg.ok, toolchain.ffmpeg.version, toolchain.ffmpeg.note),
            ToolStatus("ffprobe", toolchain.ffprobe.ok, toolchain.ffprobe.version, toolchain.ffprobe.note),
            ToolStatus(f"js_runtime:{toolchain.js_runtime.name}", toolchain.js_runtime.ok,
                       toolchain.js_runtime.version, toolchain.js_runtime.note),
        ]
        for tool in (toolchain.ffmpeg, toolchain.ffprobe):
            if not tool.ok:
                problems.append(f"{tool.name}: {tool.note}")
        if self._settings.require_js_runtime and not toolchain.js_runtime.ok:
            problems.append(f"js runtime: {toolchain.js_runtime.note}")

        ejs_installed = _package_version("yt-dlp-ejs")
        ejs_required = _required_ejs_version()
        ejs_ok = ejs_installed != "" and (ejs_required is None or ejs_installed == ejs_required)
        tools.append(ToolStatus("yt-dlp-ejs", ejs_ok, ejs_installed or None,
                                None if ejs_ok else f"yt-dlp requires {ejs_required or 'yt-dlp-ejs'}"))
        if not ejs_ok:
            problems.append(f"yt-dlp-ejs: installed {ejs_installed or 'none'}, yt-dlp requires {ejs_required}")
        warnings = []
        if stale:
            warnings.append(f"yt-dlp {version} is {age} days old (limit {self._settings.engine_stale_days})")

        return EngineDiagnostics(
            engine=self.name, version=version, channel=channel, age_days=age,
            stale=stale, tools=tuple(tools), problems=tuple(problems),
            warnings=tuple(warnings),
        )


# ---------------------------------------------------------------------------
# Pure helpers (unit-testable without a network)
# ---------------------------------------------------------------------------


def _selection_options(kind: str, height: int | None) -> dict[str, Any]:
    """yt-dlp options for a quality choice. Heights are exact: no silent downgrade."""
    if kind == "audio":
        return {
            "format": "bestaudio/best",
            "postprocessors": [
                {"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}
            ],
        }
    if kind == "best":
        return {"format": "bv*+ba/b", "merge_output_format": "mp4/mkv"}
    return {"format": f"bv*[height={height}]+ba/b[height={height}]", "merge_output_format": "mp4/mkv"}


def _first_video(info: dict[str, Any]) -> dict[str, Any]:
    if info.get("_type") == "playlist" or "entries" in info:
        entries = [e for e in (info.get("entries") or []) if e]
        if not entries:
            raise NamaoError(ErrorCode.UNSUPPORTED_CONTENT, "no playable video at that link")
        return entries[0]
    return info


def _expected_size(formats: list[dict[str, Any]]) -> int | None:
    sizes = [f.get("filesize") or f.get("filesize_approx") for f in formats]
    if not sizes or any(not s for s in sizes):
        return None
    return int(sum(sizes))


def _final_path(result: dict[str, Any]) -> Path | None:
    downloads = result.get("requested_downloads") or []
    for item in downloads:
        filepath = item.get("filepath")
        if filepath:
            return Path(filepath)
    filepath = result.get("filepath")
    return Path(filepath) if filepath else None


def _to_metadata(info: dict[str, Any], platform: str) -> MediaMetadata:
    formats = []
    for raw in info.get("formats") or []:
        vcodec, acodec = raw.get("vcodec"), raw.get("acodec")
        if vcodec in (None, "none") and acodec in (None, "none"):
            continue  # storyboards, thumbnails
        size = raw.get("filesize") or raw.get("filesize_approx")
        formats.append(
            MediaFormat(
                format_id=str(raw.get("format_id")),
                height=raw.get("height"), width=raw.get("width"), fps=raw.get("fps"),
                vcodec=vcodec, acodec=acodec, ext=raw.get("ext"),
                tbr=raw.get("tbr"), abr=raw.get("abr"),
                size_bytes=int(size) if size else None,
            )
        )
    return MediaMetadata(
        platform=platform,
        video_id=info.get("id"),
        title=str(info.get("title") or "Untitled"),
        uploader=str(info.get("uploader") or info.get("channel") or ""),
        duration_seconds=int(info.get("duration") or 0),
        thumbnail=info.get("thumbnail"),
        is_live=bool(info.get("is_live")),
        formats=tuple(formats),
    )


def _package_version(name: str) -> str:
    try:
        return importlib_metadata.version(name)
    except importlib_metadata.PackageNotFoundError:
        return ""


def _required_ejs_version() -> str | None:
    """The exact yt-dlp-ejs version this yt-dlp release declares (extra: default)."""
    for requirement in importlib_metadata.requires("yt-dlp") or []:
        match = re.match(r"^yt-dlp-ejs\s*==\s*([\w.]+)", requirement)
        if match:
            return match.group(1)
    return None


def _engine_age_days(today: date | None = None) -> int | None:
    match = _YT_DLP_AGE_RE.match(yt_dlp.version.__version__)
    if not match:
        return None
    released = date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return ((today or date.today()) - released).days


