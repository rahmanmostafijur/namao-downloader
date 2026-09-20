"""
Namao — personal-use social media video downloader.

FastAPI backend that wraps yt-dlp. All the heavy lifting (parsing pages,
finding stream URLs, handling platform quirks) is delegated to yt-dlp — this
file only does: platform detection, format selection/shaping for the UI,
and serving the downloaded file back to the browser.
"""

import mimetypes
import os
import re
import shutil
import sys
import tempfile

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.background import BackgroundTask

import yt_dlp
from yt_dlp.utils import DownloadError

app = FastAPI(title="Namao")


def resource_path(relative_path: str) -> str:
    """
    Resolve a path bundled alongside this file. When frozen into a single-file
    executable (PyInstaller), bundled data is unpacked to sys._MEIPASS instead
    of living next to the script, and the process's working directory can be
    anywhere the user double-clicked the .exe from.
    """
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, relative_path)

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

# One compiled regex per supported platform. Order doesn't matter since the
# patterns don't overlap. Add a new (name, pattern) pair here to support a
# new site — yt-dlp already knows how to extract it, so no other code needs
# to change.
PLATFORM_PATTERNS = {
    "youtube": re.compile(r"(youtube\.com|youtu\.be)", re.IGNORECASE),
    "facebook": re.compile(r"(facebook\.com|fb\.watch|fb\.com)", re.IGNORECASE),
    "tiktok": re.compile(r"([a-z]{2}\.)?tiktok\.com", re.IGNORECASE),
    "twitter": re.compile(r"(twitter\.com|x\.com)", re.IGNORECASE),
    "instagram": re.compile(r"instagram\.com", re.IGNORECASE),
}


def detect_platform(url: str) -> str | None:
    """Return a short platform name for a supported URL, or None."""
    for name, pattern in PLATFORM_PATTERNS.items():
        if pattern.search(url):
            return name
    return None


def require_platform(url: str) -> str:
    platform = detect_platform(url)
    if platform is None:
        raise HTTPException(
            status_code=400,
            detail=(
                "That link doesn't look like YouTube, Facebook, TikTok, "
                "X/Twitter, or Instagram. Paste a direct video link from "
                "one of those platforms."
            ),
        )
    return platform


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def format_size(num_bytes: float | None) -> str | None:
    """Human-readable file size, e.g. 128.4 MB. None stays None (unknown size)."""
    if not num_bytes:
        return None
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} {unit}"
        size /= 1024
    return None


def build_qualities(info: dict) -> list[dict]:
    """
    Turn yt-dlp's raw `formats` list into a compact, UI-friendly list:
    one entry per resolution (height), highest quality first, with a
    realistic size estimate (video + audio, when they'd be merged).
    """
    formats = info.get("formats") or []

    video_formats = [f for f in formats if f.get("vcodec") not in (None, "none")]
    audio_formats = [
        f
        for f in formats
        if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")
    ]

    # Best standalone audio stream, used both as the "audio only" option and
    # to pad out size estimates for video-only formats that need a merge.
    best_audio = max(audio_formats, key=lambda f: f.get("abr") or 0, default=None)
    best_audio_size = (
        (best_audio.get("filesize") or best_audio.get("filesize_approx"))
        if best_audio
        else None
    )

    # Keep only the best (highest bitrate) format per resolution height.
    best_by_height: dict[int, dict] = {}
    for f in video_formats:
        height = f.get("height")
        if not height:
            continue
        current = best_by_height.get(height)
        if current is None or (f.get("tbr") or 0) > (current.get("tbr") or 0):
            best_by_height[height] = f

    qualities = []
    for height in sorted(best_by_height.keys(), reverse=True):
        f = best_by_height[height]
        size = f.get("filesize") or f.get("filesize_approx")
        has_audio = f.get("acodec") not in (None, "none")
        if not has_audio and best_audio_size and size:
            size += best_audio_size  # will be merged with best audio on download
        qualities.append(
            {
                "id": str(height),
                "label": f"{height}p",
                "note": "",
                "size": format_size(size),
                "kind": "progressive" if has_audio else "video-only",
            }
        )

    if qualities:
        qualities[0]["note"] = "Original quality"

    # Always offer an audio-only download, even if no video formats parsed.
    qualities.append(
        {
            "id": "audio",
            "label": "Audio only",
            "note": "MP3" if ffmpeg_available() else "M4A",
            "size": format_size(best_audio_size),
            "kind": "audio",
        }
    )

    return qualities


def extract_info(url: str) -> dict:
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "noprogress": True,
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)
    if info.get("_type") == "playlist" or "entries" in info:
        entries = list(info.get("entries") or [])
        if not entries:
            raise DownloadError("No playable video found at that link.")
        info = entries[0]
    return info


# ---------------------------------------------------------------------------
# API routes
# ---------------------------------------------------------------------------


class UrlIn(BaseModel):
    url: str


@app.post("/api/info")
def get_info(body: UrlIn):
    platform = require_platform(body.url)

    try:
        info = extract_info(body.url)
    except DownloadError as e:
        raise HTTPException(
            status_code=422,
            detail=(
                "Couldn't read that video. It may be private, deleted, "
                "age-restricted, or blocked in your region. "
                f"({e})"
            ),
        )

    return {
        "platform": platform,
        "title": info.get("title") or "Untitled",
        "uploader": info.get("uploader") or info.get("channel") or "",
        "duration": info.get("duration") or 0,
        "thumbnail": info.get("thumbnail"),
        "ffmpeg": ffmpeg_available(),
        "qualities": build_qualities(info),
    }


@app.get("/api/download")
def download(url: str = Query(...), quality: str = Query(...)):
    require_platform(url)
    has_ffmpeg = ffmpeg_available()

    tempdir = tempfile.mkdtemp(prefix="namao_")
    # ".120B" truncates the title to 120 *bytes* (not characters) at a valid
    # UTF-8 boundary, so long or non-ASCII titles (Bengali, Japanese, ...)
    # can never produce a broken or over-length filename.
    outtmpl = os.path.join(tempdir, "%(title).120B.%(ext)s")

    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "noprogress": True,
        "outtmpl": outtmpl,
    }

    if quality == "audio":
        ydl_opts["format"] = "bestaudio/best"
        if has_ffmpeg:
            ydl_opts["postprocessors"] = [
                {
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": "192",
                }
            ]
        # Without ffmpeg the best audio stream downloads as-is (typically M4A).
    elif quality == "best":
        if has_ffmpeg:
            ydl_opts["format"] = "bv*+ba/b"
            ydl_opts["merge_output_format"] = "mp4"
        else:
            ydl_opts["format"] = "b"
    else:
        try:
            height = int(quality)
        except ValueError:
            shutil.rmtree(tempdir, ignore_errors=True)
            raise HTTPException(status_code=400, detail="Invalid quality value.")
        if has_ffmpeg:
            ydl_opts["format"] = f"bv*[height<={height}]+ba/b[height<={height}]/b"
            ydl_opts["merge_output_format"] = "mp4"
        else:
            # No ffmpeg means no merging, so we're limited to formats that
            # already bundle audio+video (progressive) at or under the height.
            ydl_opts["format"] = f"b[height<={height}]/b"

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
    except DownloadError as e:
        shutil.rmtree(tempdir, ignore_errors=True)
        raise HTTPException(
            status_code=422,
            detail=f"Download failed — the video may no longer be available. ({e})",
        )

    files = [os.path.join(tempdir, name) for name in os.listdir(tempdir)]
    if not files:
        shutil.rmtree(tempdir, ignore_errors=True)
        raise HTTPException(status_code=422, detail="Download produced no file.")

    # yt-dlp may leave behind intermediate streams (e.g. separate video/audio
    # before merging); the final merged/converted file is always the largest.
    result_path = max(files, key=os.path.getsize)
    media_type = mimetypes.guess_type(result_path)[0] or "application/octet-stream"
    filename = os.path.basename(result_path)

    return FileResponse(
        result_path,
        media_type=media_type,
        filename=filename,
        background=BackgroundTask(shutil.rmtree, tempdir, ignore_errors=True),
    )


# Static frontend is mounted last so it never shadows the /api/* routes above.
app.mount("/", StaticFiles(directory=resource_path("static"), html=True), name="static")
