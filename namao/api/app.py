"""FastAPI application: the v1 download-job API plus health checks.

The API never runs a download. It validates input, writes a job row, and
reports that row's state; the worker process does the heavy lifting.
"""

from __future__ import annotations

import asyncio
import logging
import mimetypes
import re
import secrets
import shutil
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import APIRouter, Depends, FastAPI, Header, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from starlette.concurrency import run_in_threadpool
from starlette.exceptions import HTTPException as StarletteHTTPException

from .. import __version__
from ..config import Settings, load_settings
from ..engine.base import DownloadEngine
from ..engine.formats import build_format_options
from ..engine.ytdlp import YtDlpEngine
from ..errors import ErrorCode, NamaoError
from ..jobs.store import JobRecord, JobStore
from ..logging_setup import configure_logging
from ..models import (
    CreateDownloadRequest, ErrorDetail, ErrorResponse, JobResponse, JobResult, JobStatus,
    MetadataResponse, Progress, UrlRequest, iso, parse_quality,
)
from ..worker import Worker

log = logging.getLogger("namao.api")

_JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
_IDEMPOTENCY_RE = re.compile(r"^[A-Za-z0-9_.:-]{8,128}$")
_SSE_POLL_SECONDS = 1.0
_SSE_KEEPALIVE_SECONDS = 15.0
_METADATA_QUEUE_WAIT_SECONDS = 5.0

_STATUS_FOR_CODE: dict[ErrorCode, int] = {
    ErrorCode.INVALID_URL: 400,
    ErrorCode.UNSUPPORTED_PLATFORM: 400,
    ErrorCode.INVALID_QUALITY: 400,
    ErrorCode.INVALID_REQUEST: 422,
    ErrorCode.UNAUTHORIZED: 401,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.CONFLICT: 409,
    ErrorCode.EXPIRED: 410,
    ErrorCode.RATE_LIMITED_LOCAL: 429,
    ErrorCode.QUEUE_FULL: 503,
    ErrorCode.INTERNAL: 500,
}
_ERROR_RESPONSES = {
    code: {"model": ErrorResponse} for code in (400, 401, 404, 409, 410, 422, 429, 500, 503)
}


def resource_path(relative_path: str) -> str:
    """Bundled data lives in sys._MEIPASS when frozen by PyInstaller."""
    base = getattr(sys, "_MEIPASS", None) or str(Path(__file__).resolve().parents[2])
    return str(Path(base) / relative_path)


def error_response(error: NamaoError, status_code: int | None = None, headers: dict | None = None) -> JSONResponse:
    status = status_code or _STATUS_FOR_CODE.get(error.code, 422)
    body = ErrorResponse(error=ErrorDetail(
        code=error.code.value, message=error.message, retryable=error.retryable, detail=error.detail,
    ))
    return JSONResponse(body.model_dump(exclude_none=True), status_code=status, headers=headers)


class SlidingWindowLimiter:
    """Per-client request limiter (in-process; one API process per deployment)."""

    def __init__(self, limit: int, window_seconds: float = 60.0) -> None:
        self._limit = limit
        self._window = window_seconds
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        if self._limit <= 0:
            return True
        now = time.monotonic()
        with self._lock:
            recent = [t for t in self._hits.get(key, []) if now - t < self._window]
            if len(recent) >= self._limit:
                self._hits[key] = recent
                return False
            recent.append(now)
            self._hits[key] = recent
            if len(self._hits) > 10_000:  # bound memory under address churn
                self._hits = {k: v for k, v in self._hits.items() if v and now - v[-1] < self._window}
            return True


def to_job_response(job: JobRecord) -> JobResponse:
    result = None
    if job.status == JobStatus.COMPLETED and job.output_name and not job.files_deleted:
        result = JobResult(
            filename=job.filename or "video",
            size_bytes=job.output_size or 0,
            height=job.output_height,
            duration_seconds=job.output_duration,
            download_url=f"/api/v1/downloads/{job.id}/file",
        )
    error = None
    if job.error_code and job.status != JobStatus.COMPLETED:
        error = ErrorDetail(
            code=job.error_code, message=job.error_message or "", retryable=bool(job.error_retryable),
            detail=job.error_detail,
        )
    retry_at = job.next_attempt_at if job.status == JobStatus.QUEUED and job.attempt > 0 else None
    return JobResponse(
        id=job.id, status=job.status, platform=job.platform, quality=job.quality, title=job.title,
        progress=Progress(
            percent=job.percent, downloaded_bytes=job.downloaded_bytes, total_bytes=job.total_bytes,
            speed_bps=job.speed_bps, eta_seconds=job.eta_seconds,
        ),
        attempt=job.attempt, max_attempts=job.max_attempts, retry_at=iso(retry_at),
        error=error, result=result,
        created_at=iso(job.created_at) or "", updated_at=iso(job.updated_at) or "",
        expires_at=iso(job.expires_at),
    )


def create_app(
    settings: Settings | None = None,
    engine: DownloadEngine | None = None,
    store: JobStore | None = None,
) -> FastAPI:
    settings = settings or load_settings()
    settings.ensure_dirs()
    engine = engine or YtDlpEngine(settings)
    store = store or JobStore(settings)
    limiter = SlidingWindowLimiter(settings.rate_limit_per_minute)
    metadata_slots = threading.BoundedSemaphore(settings.metadata_concurrency)
    embedded: dict[str, Worker] = {}

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        configure_logging()
        if settings.embedded_worker:
            worker = Worker(settings, store=store, engine=engine)
            worker.start()
            embedded["worker"] = worker
        try:
            yield
        finally:
            if "worker" in embedded:
                await run_in_threadpool(embedded["worker"].stop)

    app = FastAPI(
        title="Namao", version=__version__, lifespan=lifespan,
        description="Download-job API shared by the web, mobile and desktop clients.",
    )

    # ------------------------------------------------------- cross-cutting
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware, allow_origins=list(settings.cors_origins),
            allow_methods=["GET", "POST"], allow_headers=["Authorization", "Content-Type", "X-API-Key", "Idempotency-Key"],
        )

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        if not request.url.path.startswith("/api/"):
            response.headers.setdefault(
                "Content-Security-Policy",
                "default-src 'self'; img-src 'self' https: data:; style-src 'self' 'unsafe-inline'; "
                "script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
            )
        return response

    @app.exception_handler(NamaoError)
    async def _namao_error(_request: Request, exc: NamaoError):
        return error_response(exc)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_request: Request, _exc: RequestValidationError):
        return error_response(NamaoError(ErrorCode.INVALID_REQUEST), 422)

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_request: Request, exc: StarletteHTTPException):
        code = ErrorCode.NOT_FOUND if exc.status_code == 404 else ErrorCode.INVALID_REQUEST
        return error_response(NamaoError(code), exc.status_code)

    @app.exception_handler(Exception)
    async def _unexpected(_request: Request, exc: Exception):
        log.error("api.unhandled", extra={"exc_type": type(exc).__name__})
        return error_response(NamaoError(ErrorCode.INTERNAL), 500)

    # ----------------------------------------------------------- dependencies
    def client_key(request: Request) -> str:
        if settings.trust_proxy:
            forwarded = request.headers.get("x-forwarded-for", "")
            if forwarded:
                return forwarded.split(",")[0].strip()
        return request.client.host if request.client else "unknown"

    def require_auth(
        authorization: str | None = Header(default=None),
        x_api_key: str | None = Header(default=None),
    ) -> None:
        if not settings.api_key:
            return
        supplied = x_api_key or (authorization[7:] if authorization and authorization.lower().startswith("bearer ") else "")
        if not supplied or not secrets.compare_digest(supplied.encode(), settings.api_key.encode()):
            raise NamaoError(ErrorCode.UNAUTHORIZED)

    def rate_limit(request: Request) -> None:
        if not limiter.allow(client_key(request)):
            raise NamaoError(ErrorCode.RATE_LIMITED_LOCAL)

    def load_job(job_id: str) -> JobRecord:
        job = store.get(job_id) if _JOB_ID_RE.fullmatch(job_id) else None
        if job is None:
            raise NamaoError(ErrorCode.NOT_FOUND)
        return job

    # ------------------------------------------------------------- v1 routes
    v1 = APIRouter(prefix="/api/v1/downloads", dependencies=[Depends(require_auth)], responses=_ERROR_RESPONSES)

    @v1.post("/metadata", response_model=MetadataResponse, dependencies=[Depends(rate_limit)])
    def get_metadata(body: UrlRequest) -> MetadataResponse:
        validated = engine.validate_url(body.url)
        if not metadata_slots.acquire(timeout=_METADATA_QUEUE_WAIT_SECONDS):
            raise NamaoError(ErrorCode.QUEUE_FULL)
        try:
            metadata = engine.extract_metadata(validated.url)
        finally:
            metadata_slots.release()
        if metadata.is_live:
            raise NamaoError(ErrorCode.UNSUPPORTED_CONTENT)
        diagnostics = engine.diagnostics()
        ffmpeg_ok = any(t.name == "ffmpeg" and t.ok for t in diagnostics.tools)
        options = build_format_options(metadata)
        if not options:
            raise NamaoError(ErrorCode.FORMAT_UNAVAILABLE)
        return MetadataResponse(
            platform=metadata.platform, title=metadata.title, uploader=metadata.uploader,
            duration_seconds=metadata.duration_seconds, thumbnail=metadata.thumbnail,
            formats=options, ffmpeg=ffmpeg_ok,
        )

    @v1.post("", response_model=JobResponse, status_code=202, dependencies=[Depends(rate_limit)])
    def create_download(
        body: CreateDownloadRequest,
        response: Response,
        idempotency_key: str | None = Header(default=None),
    ) -> JobResponse:
        validated = engine.validate_url(body.url)
        try:
            parse_quality(body.quality)
        except ValueError:
            raise NamaoError(ErrorCode.INVALID_QUALITY) from None
        if idempotency_key is not None and not _IDEMPOTENCY_RE.fullmatch(idempotency_key):
            raise NamaoError(ErrorCode.INVALID_REQUEST)
        if store.open_job_count() >= settings.max_queue_length:
            raise NamaoError(ErrorCode.QUEUE_FULL)
        job, created = store.create_job(
            url=validated.url, platform=validated.platform, quality=body.quality,
            max_attempts=settings.max_attempts, idempotency_key=idempotency_key,
        )
        response.headers["Location"] = f"/api/v1/downloads/{job.id}"
        if not created:
            response.status_code = 200
        return to_job_response(job)

    @v1.get("/{job_id}", response_model=JobResponse)
    def get_download(job_id: str) -> JobResponse:
        return to_job_response(load_job(job_id))

    @v1.get("/{job_id}/progress", response_class=StreamingResponse,
            responses={200: {"content": {"text/event-stream": {}}, "description": "Server-sent events of JobResponse JSON"}})
    async def stream_progress(job_id: str, request: Request) -> StreamingResponse:
        await run_in_threadpool(load_job, job_id)  # 404 before the stream starts

        async def events():
            last_payload = None
            last_sent = time.monotonic()
            while True:
                if await request.is_disconnected():
                    return
                job = await run_in_threadpool(store.get, job_id)
                if job is None:
                    return
                payload = to_job_response(job).model_dump_json(exclude={"updated_at"})
                if payload != last_payload:
                    last_payload, last_sent = payload, time.monotonic()
                    yield f"event: job\ndata: {to_job_response(job).model_dump_json()}\n\n"
                elif time.monotonic() - last_sent > _SSE_KEEPALIVE_SECONDS:
                    last_sent = time.monotonic()
                    yield ": keepalive\n\n"
                if job.is_terminal:
                    return
                await asyncio.sleep(_SSE_POLL_SECONDS)

        return StreamingResponse(
            events(), media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @v1.post("/{job_id}/cancel", response_model=JobResponse)
    def cancel_download(job_id: str) -> JobResponse:
        load_job(job_id)
        job = store.request_cancel(job_id)
        if job is None:
            raise NamaoError(ErrorCode.NOT_FOUND)
        if job.status in (JobStatus.COMPLETED, JobStatus.FAILED, JobStatus.INTERRUPTED):
            raise NamaoError(ErrorCode.CONFLICT)
        return to_job_response(job)

    @v1.get("/{job_id}/file", response_class=FileResponse,
            responses={200: {"content": {"application/octet-stream": {}}, "description": "The verified media file"}})
    def download_file(job_id: str) -> FileResponse:
        job = load_job(job_id)
        if job.status != JobStatus.COMPLETED:
            raise NamaoError(ErrorCode.CONFLICT)
        if job.files_deleted or not job.output_name or (job.expires_at and job.expires_at < time.time()):
            raise NamaoError(ErrorCode.EXPIRED)
        job_root = (settings.jobs_dir / job.id).resolve()
        path = (job_root / job.output_name).resolve()
        if job_root not in path.parents or not path.is_file():  # no traversal, no symlink escape
            raise NamaoError(ErrorCode.EXPIRED)
        media_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        return FileResponse(
            path, media_type=media_type, filename=job.filename, content_disposition_type="attachment",
            headers={"Cache-Control": "private, no-store"},
        )

    app.include_router(v1)

    # ---------------------------------------------------------------- health
    @app.get("/health/live", tags=["health"])
    def live() -> dict:
        return {"status": "ok", "version": __version__}

    @app.get("/health/ready", tags=["health"])
    def ready() -> JSONResponse:
        checks: dict[str, dict] = {}
        diagnostics = engine.diagnostics()
        checks["engine"] = {
            "ok": diagnostics.ok, "name": diagnostics.engine, "version": diagnostics.version,
            "channel": diagnostics.channel, "age_days": diagnostics.age_days, "stale": diagnostics.stale,
        }
        for tool in diagnostics.tools:
            checks[tool.name] = {"ok": tool.ok, "version": tool.version, **({"note": tool.note} if tool.note else {})}
        try:
            store.ping()
            checks["database"] = {"ok": True}
        except Exception:  # noqa: BLE001
            checks["database"] = {"ok": False}
        free = _free_bytes(settings)
        checks["storage"] = {"ok": free >= settings.min_free_bytes, "free_mb": free // (1024 * 1024)}
        workers = store.alive_worker_count(settings.stale_after_seconds)
        checks["worker"] = {"ok": workers > 0, "alive": workers}

        healthy = all(c["ok"] for c in checks.values())
        body = {"status": "ready" if healthy else "degraded", "checks": checks}
        if diagnostics.problems:
            body["problems"] = list(diagnostics.problems)
        if diagnostics.warnings:
            body["warnings"] = list(diagnostics.warnings)
        return JSONResponse(body, status_code=200 if healthy else 503)

    # --------------------------------------------------------------- static
    static_dir = Path(resource_path("static"))
    if static_dir.is_dir():
        app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="static")

    return app


def _free_bytes(settings: Settings) -> int:
    return shutil.disk_usage(settings.data_dir).free
