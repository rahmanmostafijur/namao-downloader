"""Desktop-only features: output folder preference, save-to-folder, open folder.

Enabled only with NAMAO_DESKTOP_MODE=1 (the desktop launcher sets it and binds the
server to loopback). A local web server is reachable by every web page the user
visits, so desktop mode adds two defences on top of the normal API:

  * Host-header allowlist (localhost / 127.0.0.1 / [::1]) against DNS rebinding.
  * Every desktop endpoint requires a custom header (`X-Namao-Desktop: 1`), which
    forces a CORS preflight; no CORS headers are served, so cross-site pages
    cannot call them.

The output folder must live under the user's home directory, the endpoints never
accept an arbitrary filesystem path for reading or opening, and files are copied
to a unique name (an existing file is never overwritten).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, ConfigDict, Field

from .config import Settings
from .errors import ErrorCode, NamaoError
from .jobs.store import JobRecord, JobStore
from .models import JobStatus

DESKTOP_HEADER = "x-namao-desktop"
DESKTOP_COOKIE = "namao_desktop"
_MAX_PATH_CHARS = 500
_RESERVED_TOP_LEVEL = {"appdata", "library", "application data", "local settings"}


def default_output_dir() -> Path:
    return Path.home() / "Downloads" / "Namao"


_LOCAL_HOST_RE = re.compile(r"(localhost|127\.0\.0\.1|\[::1\])(:\d{1,5})?")


def host_is_local(host_header: str | None) -> bool:
    """True only for a Host header that names this machine (optional numeric port)."""
    return bool(host_header) and _LOCAL_HOST_RE.fullmatch(host_header.strip().lower()) is not None


def validate_output_dir(raw: str, *, home: Path | None = None) -> Path:
    """An absolute directory strictly inside the user's home folder, with no hidden segments."""
    if not isinstance(raw, str) or not raw.strip() or len(raw) > _MAX_PATH_CHARS or "\x00" in raw:
        raise NamaoError(ErrorCode.INVALID_REQUEST, "invalid folder")
    candidate = Path(os.path.expanduser(raw.strip()))
    if not candidate.is_absolute():
        raise NamaoError(ErrorCode.INVALID_REQUEST, "folder must be an absolute path")
    base = (home or Path.home()).resolve()
    resolved = candidate.resolve()
    if resolved == base or base not in resolved.parents:
        raise NamaoError(ErrorCode.INVALID_REQUEST, "folder must be inside your home folder")
    relative = resolved.relative_to(base)
    if any(part.startswith(".") for part in relative.parts):
        raise NamaoError(ErrorCode.INVALID_REQUEST, "hidden folders are not allowed")
    # Application-support areas (Windows AppData incl. Startup, macOS Library) are not download folders.
    if relative.parts[0].lower() in _RESERVED_TOP_LEVEL:
        raise NamaoError(ErrorCode.INVALID_REQUEST, "that folder is reserved for applications")
    return resolved


class Preferences:
    """A tiny JSON file in the app data directory (atomic writes)."""

    def __init__(self, settings: Settings) -> None:
        self._path = settings.data_dir / "preferences.json"
        self._lock = threading.Lock()

    def load(self) -> dict:
        with self._lock:
            try:
                data = json.loads(self._path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                data = {}
        if not isinstance(data, dict):
            data = {}
        output = data.get("output_dir")
        try:
            output_dir = str(validate_output_dir(output)) if output else str(default_output_dir())
        except NamaoError:
            output_dir = str(default_output_dir())
        return {"output_dir": output_dir, "auto_save": bool(data.get("auto_save", True))}

    def save(self, output_dir: str, auto_save: bool) -> dict:
        folder = validate_output_dir(output_dir)
        folder.mkdir(parents=True, exist_ok=True)
        try:  # prove it is writable before accepting it
            with tempfile.NamedTemporaryFile(dir=folder, prefix=".namao-write-test-", delete=True):
                pass
        except OSError as exc:
            raise NamaoError(ErrorCode.STORAGE_FULL, f"folder is not writable: {exc.strerror}") from exc
        payload = {"output_dir": str(folder), "auto_save": bool(auto_save)}
        with self._lock:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            temp = self._path.with_suffix(".tmp")
            temp.write_text(json.dumps(payload), encoding="utf-8")
            os.replace(temp, self._path)
        return payload


def unique_destination(folder: Path, filename: str) -> Path:
    """`name.ext`, or `name (1).ext`, `name (2).ext`... : an existing file is never overwritten."""
    stem, suffix = Path(filename).stem, Path(filename).suffix
    candidate = folder / filename
    counter = 1
    while os.path.lexists(candidate):  # lexists: a dangling symlink also occupies the name
        candidate = folder / f"{stem} ({counter}){suffix}"
        counter += 1
    return candidate


def copy_without_overwriting(source: Path, folder: Path, filename: str) -> Path:
    """Copy `source` into `folder` under a name nobody else holds, atomically.

    The data is copied once to a private temp file, then the destination name is
    claimed with an operation that fails if the name exists (hard link, or exclusive
    create on filesystems without links), so concurrent saves and pre-existing files
    can never be overwritten.
    """
    folder.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(dir=folder, prefix=".namao-", suffix=".part")
    os.close(handle)
    temp = Path(temp_name)
    try:
        shutil.copyfile(source, temp)
        if os.name != "nt":  # mkstemp creates 0600; saved media should follow the user's umask
            umask = os.umask(0)
            os.umask(umask)
            os.chmod(temp, 0o666 & ~umask)
        for _ in range(1000):
            destination = unique_destination(folder, filename)
            try:
                os.link(temp, destination)
                return destination
            except FileExistsError:
                continue  # lost the race for this name
            except OSError:  # no hard links (FAT/exFAT, some network shares)
                created = False
                try:
                    with open(temp, "rb") as src, open(destination, "xb") as dst:
                        created = True
                        shutil.copyfileobj(src, dst)
                    return destination
                except FileExistsError:
                    continue
                except BaseException:
                    if created:  # never delete something we did not create
                        destination.unlink(missing_ok=True)
                    raise
        raise NamaoError(ErrorCode.CONFLICT, "could not find a free file name")
    finally:
        temp.unlink(missing_ok=True)


def open_folder(path: Path) -> None:
    """Open a directory in the platform file manager. Argument lists only; the path is ours."""
    if sys.platform == "win32":
        os.startfile(str(path))  # noqa: S606 - a directory we validated
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])  # noqa: S603,S607
    else:
        subprocess.Popen(["xdg-open", str(path)])  # noqa: S603,S607


class PreferencesBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    output_dir: str = Field(min_length=1, max_length=_MAX_PATH_CHARS)
    auto_save: bool = True


class PreferencesResponse(BaseModel):
    output_dir: str
    auto_save: bool
    platform: str = sys.platform


class SaveResponse(BaseModel):
    saved: bool
    name: str
    folder: str


def require_desktop_header(x_namao_desktop: str | None = Header(default=None)) -> None:
    if x_namao_desktop != "1":
        raise NamaoError(ErrorCode.UNAUTHORIZED)


def build_desktop_router(settings: Settings, store: JobStore, load_job, opener=None) -> APIRouter:
    preferences = Preferences(settings)
    router = APIRouter(prefix="/api/v1/desktop", tags=["desktop"], dependencies=[Depends(require_desktop_header)])

    @router.get("/preferences", response_model=PreferencesResponse)
    def get_preferences() -> PreferencesResponse:
        return PreferencesResponse(**preferences.load())

    @router.put("/preferences", response_model=PreferencesResponse)
    def put_preferences(body: PreferencesBody) -> PreferencesResponse:
        return PreferencesResponse(**preferences.save(body.output_dir, body.auto_save))

    @router.post("/jobs/{job_id}/save", response_model=SaveResponse)
    def save_job(job_id: str) -> SaveResponse:
        job: JobRecord = load_job(job_id)
        if job.status != JobStatus.COMPLETED:
            raise NamaoError(ErrorCode.CONFLICT)
        if job.files_deleted or not job.output_name or (job.expires_at and job.expires_at < time.time()):
            raise NamaoError(ErrorCode.EXPIRED)
        job_root = (settings.jobs_dir / job.id).resolve()
        source = (job_root / job.output_name).resolve()
        if job_root not in source.parents or not source.is_file():
            raise NamaoError(ErrorCode.EXPIRED)
        folder = Path(preferences.load()["output_dir"])
        destination = copy_without_overwriting(source, folder, job.filename or "video")
        return SaveResponse(saved=True, name=destination.name, folder=str(folder))

    @router.post("/open-folder")
    def open_output_folder() -> dict:
        folder = Path(preferences.load()["output_dir"])
        folder.mkdir(parents=True, exist_ok=True)
        (opener or open_folder)(folder)
        return {"opened": True}

    return router
