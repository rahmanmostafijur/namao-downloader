"""Output verification with FFprobe.

A job is only reported `completed` after this passes. Empty, truncated,
unplayable or stream-less files are rejected (and deleted by the runner).
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from ..errors import ErrorCode, NamaoError
from .base import VerifiedMedia

MIN_OUTPUT_BYTES = 1024
# A file shorter than this fraction of the source duration is treated as truncated.
MIN_DURATION_RATIO = 0.5
_FFPROBE_TIMEOUT_SECONDS = 60


def probe_media(path: Path, ffprobe: str) -> dict:
    try:
        completed = subprocess.run(
            [
                ffprobe, "-v", "error", "-print_format", "json",
                "-show_format", "-show_streams", str(path),
            ],
            capture_output=True,
            text=True,
            timeout=_FFPROBE_TIMEOUT_SECONDS,
            check=False,
        )
    except FileNotFoundError:
        raise NamaoError(ErrorCode.FFMPEG_MISSING, "ffprobe not found") from None
    except subprocess.TimeoutExpired:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "ffprobe timed out") from None
    if completed.returncode != 0:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, f"ffprobe rejected the file: {completed.stderr[:200]}")
    try:
        return json.loads(completed.stdout or "{}")
    except json.JSONDecodeError:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "ffprobe returned unreadable output") from None


def verify_media_file(
    path: Path,
    *,
    ffprobe: str,
    expect_video: bool,
    max_bytes: int,
    source_duration: int | None,
    max_duration: int | None = None,
) -> VerifiedMedia:
    if not path.is_file():
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "output file is missing")
    size = path.stat().st_size
    if size < MIN_OUTPUT_BYTES:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, f"output file is only {size} bytes")
    if size > max_bytes:
        raise NamaoError(ErrorCode.FILE_TOO_LARGE, f"output is {size} bytes")

    info = probe_media(path, ffprobe)
    streams = info.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"
                  and not (s.get("disposition") or {}).get("attached_pic")), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)

    if expect_video and video is None:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "no video stream in output")
    if not expect_video and audio is None:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "no audio stream in output")

    try:
        duration = float((info.get("format") or {}).get("duration") or 0)
    except (TypeError, ValueError):
        duration = 0.0
    if duration <= 0:
        raise NamaoError(ErrorCode.OUTPUT_INVALID, "output has no duration")
    if max_duration and duration > max_duration:
        # Catches sources that didn't report a length before the download started.
        raise NamaoError(ErrorCode.DURATION_TOO_LONG, f"output is {duration:.0f}s, limit {max_duration}s")
    if source_duration and duration < source_duration * MIN_DURATION_RATIO:
        raise NamaoError(
            ErrorCode.OUTPUT_INVALID,
            f"output is {duration:.0f}s but the source is {source_duration}s (truncated)",
        )

    return VerifiedMedia(
        path=path,
        size_bytes=size,
        duration_seconds=duration,
        height=int(video["height"]) if video and video.get("height") else None,
        width=int(video["width"]) if video and video.get("width") else None,
        has_video=video is not None,
        has_audio=audio is not None,
        container=str((info.get("format") or {}).get("format_name") or ""),
    )
