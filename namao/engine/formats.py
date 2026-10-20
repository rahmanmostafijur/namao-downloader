"""Turn an engine's raw format list into the UI-facing options.

Only qualities the source actually offers are listed, and each option's `id`
is an exact height: the engine selects that height or fails, it never quietly
picks a lower one (the old `/b` fallback did).
"""

from __future__ import annotations

from ..models import FormatOption
from .base import MediaFormat, MediaMetadata


def _best_by_tbr(candidates: list[MediaFormat]) -> MediaFormat:
    return max(candidates, key=lambda f: (f.fps or 0, f.tbr or 0))


def _size_of(fmt: MediaFormat, duration: int) -> tuple[int | None, bool]:
    """(size in bytes, is_estimate): the reported size, else bitrate x duration, else unknown."""
    if fmt.size_bytes:
        return fmt.size_bytes, False
    rate = fmt.tbr or fmt.abr
    if rate and duration:
        return int(rate * 125 * duration), True  # kbit/s -> bytes/s
    return None, False


def build_format_options(metadata: MediaMetadata) -> list[FormatOption]:
    video = [f for f in metadata.formats if f.has_video]
    audio_only = [f for f in metadata.formats if f.has_audio and not f.has_video]

    best_audio = max(audio_only, key=lambda f: f.abr or f.tbr or 0, default=None)
    best_audio_size, audio_estimated = _size_of(best_audio, metadata.duration_seconds) if best_audio else (None, False)

    by_height: dict[int, list[MediaFormat]] = {}
    for fmt in video:
        if fmt.height:
            by_height.setdefault(fmt.height, []).append(fmt)

    options: list[FormatOption] = []
    for height in sorted(by_height, reverse=True):
        best = _best_by_tbr(by_height[height])
        needs_merge = not best.has_audio
        size, estimated = _size_of(best, metadata.duration_seconds)
        if size and needs_merge and best_audio_size:
            size += best_audio_size
            estimated = estimated or audio_estimated
        fps_suffix = f"{round(best.fps)}" if best.fps and best.fps > 30 else ""
        options.append(
            FormatOption(
                id=str(height),
                label=f"{height}p{fps_suffix}",
                kind="video",
                height=height,
                size_bytes=size,
                size_estimated=estimated,
                needs_merge=needs_merge,
            )
        )

    if options:
        options[0].note = "Highest available"
    elif video:
        # Video exists but the source doesn't report heights (some short-form platforms).
        options.append(
            FormatOption(id="best", label="Best available", kind="video",
                         size_bytes=_size_of(_best_by_tbr(video), metadata.duration_seconds)[0],
                         size_estimated=_size_of(_best_by_tbr(video), metadata.duration_seconds)[1],
                         needs_merge=not _best_by_tbr(video).has_audio)
        )

    if audio_only or video:
        options.append(
            FormatOption(id="audio", label="Audio only", kind="audio", note="MP3",
                         size_bytes=best_audio_size, size_estimated=audio_estimated)
        )
    return options
