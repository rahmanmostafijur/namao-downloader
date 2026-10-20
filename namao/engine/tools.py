"""Locate and verify external binaries (FFmpeg, FFprobe, JavaScript runtime).

Declaring a dependency is not proof it works, so each tool is actually
executed (`<tool> -version`) and its version parsed. Binaries are resolved from
an operator-controlled directory (NAMAO_BIN_DIR) and PATH only; nothing is ever
downloaded at runtime. All subprocess calls use argument lists (no shell).
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from ..config import Settings

# Minimums from https://github.com/yt-dlp/yt-dlp/wiki/EJS (checked 2026-10-20).
MIN_RUNTIME_VERSIONS: dict[str, tuple[int, int, int]] = {
    "deno": (2, 3, 0),
    "node": (22, 0, 0),
}
_RUNTIME_PREFERENCE = ("deno", "node")
_VERSION_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")
_CACHE_TTL_SECONDS = 300.0
_PROBE_TIMEOUT_SECONDS = 15


@dataclass(frozen=True)
class Tool:
    name: str
    path: str | None
    version: str | None
    ok: bool
    note: str | None = None


@dataclass(frozen=True)
class Toolchain:
    ffmpeg: Tool
    ffprobe: Tool
    js_runtime: Tool  # name is the runtime ("deno"/"node") or "none"

    @property
    def ffmpeg_dir(self) -> str | None:
        return str(Path(self.ffmpeg.path).parent) if self.ffmpeg.path else None


def parse_version(text: str) -> tuple[int, int, int] | None:
    match = _VERSION_RE.search(text)
    if not match:
        return None
    major, minor, patch = match.group(1), match.group(2), match.group(3) or "0"
    return int(major), int(minor), int(patch)


def _search_path(settings: Settings) -> str:
    parts = []
    if settings.bin_dir:
        parts.append(str(settings.bin_dir))
    parts.append(os.environ.get("PATH", ""))
    return os.pathsep.join(p for p in parts if p)


def find_executable(name: str, settings: Settings) -> str | None:
    return shutil.which(name, path=_search_path(settings))


def _run_version(path: str, args: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            [path, *args],
            capture_output=True,
            text=True,
            timeout=_PROBE_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    lines = (completed.stdout or completed.stderr or "").strip().splitlines()
    return lines[0].strip() if lines else None


def _probe_ffmpeg_family(name: str, settings: Settings) -> Tool:
    path = find_executable(name, settings)
    if not path:
        return Tool(name, None, None, False, "not found on PATH or NAMAO_BIN_DIR")
    first_line = _run_version(path, ["-version"])
    if not first_line:
        return Tool(name, path, None, False, "found but failed to run")
    parsed = parse_version(first_line)
    version = ".".join(map(str, parsed)) if parsed else first_line[:40]
    return Tool(name, path, version, True)


def _probe_runtime(name: str, settings: Settings) -> Tool:
    path = find_executable(name, settings)
    if not path:
        return Tool(name, None, None, False, "not found on PATH or NAMAO_BIN_DIR")
    first_line = _run_version(path, ["--version"])
    parsed = parse_version(first_line or "")
    if not parsed:
        return Tool(name, path, None, False, "found but failed to run")
    version = ".".join(map(str, parsed))
    minimum = MIN_RUNTIME_VERSIONS[name]
    if parsed < minimum:
        return Tool(name, path, version, False, f"needs >= {'.'.join(map(str, minimum))}")
    return Tool(name, path, version, True)


def _resolve_runtime(settings: Settings) -> Tool:
    wanted = settings.js_runtime
    if wanted not in ("auto", *MIN_RUNTIME_VERSIONS):
        return Tool(wanted, None, None, False, "unsupported runtime; use deno, node or auto")
    candidates = _RUNTIME_PREFERENCE if wanted == "auto" else (wanted,)
    probes = [_probe_runtime(name, settings) for name in candidates]
    for probe in probes:
        if probe.ok:
            return probe
    # Report the most informative failure (one that was at least found).
    found = [p for p in probes if p.path]
    return found[0] if found else Tool("none", None, None, False, "no JavaScript runtime found (install Deno)")


def probe_toolchain(settings: Settings) -> Toolchain:
    return Toolchain(
        ffmpeg=_probe_ffmpeg_family("ffmpeg", settings),
        ffprobe=_probe_ffmpeg_family("ffprobe", settings),
        js_runtime=_resolve_runtime(settings),
    )


_cache_lock = threading.Lock()
_cache: dict[tuple, tuple[float, Toolchain]] = {}


def get_toolchain(settings: Settings, *, refresh: bool = False) -> Toolchain:
    """Cached toolchain probe (spawning processes on every request would be wasteful)."""
    key = (str(settings.bin_dir), settings.js_runtime)
    now = time.monotonic()
    with _cache_lock:
        cached = _cache.get(key)
        if cached and not refresh and now - cached[0] < _CACHE_TTL_SECONDS:
            return cached[1]
    toolchain = probe_toolchain(settings)
    with _cache_lock:
        _cache[key] = (now, toolchain)
    return toolchain
