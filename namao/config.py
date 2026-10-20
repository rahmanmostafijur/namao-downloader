"""Runtime configuration, read once from NAMAO_* environment variables.

Every limit that protects a small host (worker count, job duration, output
size, disk usage, retention) is configurable here instead of being a magic
number in the code. `Settings` is immutable; tests build their own instances.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field, replace
from pathlib import Path

KIB = 1024
MIB = 1024 * KIB
GIB = 1024 * MIB


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(f"NAMAO_{name}")
    return value if value not in (None, "") else default


def _env_int(name: str, default: int) -> int:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"NAMAO_{name} must be an integer, got {raw!r}") from exc


def _env_float(name: str, default: float) -> float:
    raw = _env(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError(f"NAMAO_{name} must be a number, got {raw!r}") from exc


def _env_bool(name: str, default: bool) -> bool:
    raw = _env(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_list(name: str) -> tuple[str, ...]:
    raw = _env(name, "") or ""
    return tuple(part.strip().lower() for part in raw.split(",") if part.strip())


@dataclass(frozen=True)
class Settings:
    # --- storage -----------------------------------------------------------
    data_dir: Path = Path("data")
    # --- worker pool -------------------------------------------------------
    worker_concurrency: int = 2
    heartbeat_interval_seconds: float = 5.0
    stale_after_seconds: float = 60.0
    poll_interval_seconds: float = 1.0
    # --- retries -----------------------------------------------------------
    max_attempts: int = 3
    retry_base_seconds: float = 2.0
    retry_max_seconds: float = 60.0
    # --- per-job limits ----------------------------------------------------
    job_timeout_seconds: int = 1800
    max_duration_seconds: int = 4 * 3600
    max_output_bytes: int = 2 * GIB
    # --- disk --------------------------------------------------------------
    min_free_bytes: int = 1 * GIB
    max_storage_bytes: int = 20 * GIB
    retention_seconds: int = 3600
    cleanup_interval_seconds: float = 60.0
    # --- API protection ----------------------------------------------------
    max_queue_length: int = 50
    max_open_jobs_per_client: int = 5
    max_sse_streams: int = 100
    sse_max_seconds: int = 900
    read_rate_limit_per_minute: int = 600
    rate_limit_per_minute: int = 30
    metadata_concurrency: int = 4
    metadata_timeout_seconds: int = 60
    api_key: str | None = None
    trust_proxy: bool = False
    trusted_proxies: int = 1  # reverse-proxy hops that append to X-Forwarded-For
    expose_error_detail: bool = False  # sanitized engine text in API errors (debugging only)
    expose_docs: bool = False  # /docs, /redoc, /openapi.json
    # --- engine ------------------------------------------------------------
    js_runtime: str = "auto"  # auto | deno | node
    require_js_runtime: bool = True
    bin_dir: Path | None = None  # optional dir holding ffmpeg/ffprobe/deno
    socket_timeout_seconds: int = 20
    concurrent_fragments: int = 4
    engine_stale_days: int = 90  # upstream itself warns after 90 days
    # --- deployment --------------------------------------------------------
    embedded_worker: bool = False
    cors_origins: tuple[str, ...] = field(default_factory=tuple)
    # --- test-only escape hatches (never enable in production) -------------
    allow_private_networks: bool = False
    extra_allowed_hosts: tuple[str, ...] = field(default_factory=tuple)
    allow_generic_extractor: bool = False

    @property
    def db_path(self) -> Path:
        return self.data_dir / "namao.db"

    @property
    def drain_file(self) -> Path:
        """While this file exists workers finish running jobs but claim no new ones."""
        return self.data_dir / "DRAIN"

    @property
    def jobs_dir(self) -> Path:
        return self.data_dir / "jobs"

    @property
    def cache_dir(self) -> Path:
        return self.data_dir / "ytdlp-cache"

    def with_overrides(self, **changes) -> "Settings":
        return replace(self, **changes)

    def ensure_dirs(self) -> None:
        for path in (self.data_dir, self.jobs_dir, self.cache_dir):
            path.mkdir(parents=True, exist_ok=True)


def _require_positive(name: str, value: float) -> None:
    if value <= 0:
        raise ValueError(f"NAMAO_{name} must be greater than zero, got {value}")


def _api_key() -> str | None:
    raw = os.environ.get("NAMAO_API_KEY")
    if raw is None:
        return None
    if not raw.strip():
        # An empty value almost always means a missing secret in a template
        # (NAMAO_API_KEY=${API_KEY}); silently disabling auth would be worse than refusing to start.
        raise ValueError("NAMAO_API_KEY is set but empty; unset it to disable authentication or give it a value")
    return raw


def load_settings() -> Settings:
    defaults = Settings()
    bin_dir = _env("BIN_DIR")
    settings = _build_settings(defaults, bin_dir)
    _require_positive("JOB_TIMEOUT_SECONDS", settings.job_timeout_seconds)
    _require_positive("HEARTBEAT_INTERVAL_SECONDS", settings.heartbeat_interval_seconds)
    _require_positive("POLL_INTERVAL_SECONDS", settings.poll_interval_seconds)
    _require_positive("RETENTION_SECONDS", settings.retention_seconds)
    if settings.stale_after_seconds < 3 * settings.heartbeat_interval_seconds:
        raise ValueError(
            "NAMAO_STALE_AFTER_SECONDS must be at least 3x NAMAO_HEARTBEAT_INTERVAL_SECONDS, "
            "otherwise healthy jobs get reaped"
        )
    if settings.trust_proxy and settings.trusted_proxies < 1:
        raise ValueError("NAMAO_TRUSTED_PROXIES must be >= 1 when NAMAO_TRUST_PROXY is on")
    return settings


def _build_settings(defaults: Settings, bin_dir: str | None) -> Settings:
    return Settings(
        data_dir=Path(_env("DATA_DIR", str(defaults.data_dir))),
        worker_concurrency=max(1, _env_int("WORKER_CONCURRENCY", defaults.worker_concurrency)),
        heartbeat_interval_seconds=_env_float("HEARTBEAT_INTERVAL_SECONDS", defaults.heartbeat_interval_seconds),
        stale_after_seconds=_env_float("STALE_AFTER_SECONDS", defaults.stale_after_seconds),
        poll_interval_seconds=_env_float("POLL_INTERVAL_SECONDS", defaults.poll_interval_seconds),
        max_attempts=max(1, _env_int("MAX_ATTEMPTS", defaults.max_attempts)),
        retry_base_seconds=_env_float("RETRY_BASE_SECONDS", defaults.retry_base_seconds),
        retry_max_seconds=_env_float("RETRY_MAX_SECONDS", defaults.retry_max_seconds),
        job_timeout_seconds=_env_int("JOB_TIMEOUT_SECONDS", defaults.job_timeout_seconds),
        max_duration_seconds=_env_int("MAX_DURATION_SECONDS", defaults.max_duration_seconds),
        max_output_bytes=_env_int("MAX_OUTPUT_MB", defaults.max_output_bytes // MIB) * MIB,
        min_free_bytes=_env_int("MIN_FREE_MB", defaults.min_free_bytes // MIB) * MIB,
        max_storage_bytes=_env_int("MAX_STORAGE_MB", defaults.max_storage_bytes // MIB) * MIB,
        retention_seconds=_env_int("RETENTION_SECONDS", defaults.retention_seconds),
        cleanup_interval_seconds=_env_float("CLEANUP_INTERVAL_SECONDS", defaults.cleanup_interval_seconds),
        max_queue_length=_env_int("MAX_QUEUE_LENGTH", defaults.max_queue_length),
        max_open_jobs_per_client=_env_int("MAX_OPEN_JOBS_PER_CLIENT", defaults.max_open_jobs_per_client),
        max_sse_streams=_env_int("MAX_SSE_STREAMS", defaults.max_sse_streams),
        sse_max_seconds=_env_int("SSE_MAX_SECONDS", defaults.sse_max_seconds),
        read_rate_limit_per_minute=_env_int("READ_RATE_LIMIT_PER_MINUTE", defaults.read_rate_limit_per_minute),
        rate_limit_per_minute=_env_int("RATE_LIMIT_PER_MINUTE", defaults.rate_limit_per_minute),
        metadata_concurrency=max(1, _env_int("METADATA_CONCURRENCY", defaults.metadata_concurrency)),
        metadata_timeout_seconds=_env_int("METADATA_TIMEOUT_SECONDS", defaults.metadata_timeout_seconds),
        api_key=_api_key(),
        trust_proxy=_env_bool("TRUST_PROXY", defaults.trust_proxy),
        trusted_proxies=_env_int("TRUSTED_PROXIES", defaults.trusted_proxies),
        expose_error_detail=_env_bool("EXPOSE_ERROR_DETAIL", defaults.expose_error_detail),
        expose_docs=_env_bool("EXPOSE_DOCS", defaults.expose_docs),
        js_runtime=(_env("JS_RUNTIME", defaults.js_runtime) or "auto").lower(),
        require_js_runtime=_env_bool("REQUIRE_JS_RUNTIME", defaults.require_js_runtime),
        bin_dir=Path(bin_dir) if bin_dir else None,
        socket_timeout_seconds=_env_int("SOCKET_TIMEOUT_SECONDS", defaults.socket_timeout_seconds),
        concurrent_fragments=max(1, _env_int("CONCURRENT_FRAGMENTS", defaults.concurrent_fragments)),
        engine_stale_days=_env_int("ENGINE_STALE_DAYS", defaults.engine_stale_days),
        embedded_worker=_env_bool("EMBEDDED_WORKER", defaults.embedded_worker),
        cors_origins=_env_list("CORS_ORIGINS"),
        allow_private_networks=_env_bool("ALLOW_PRIVATE_NETWORKS", False),
        extra_allowed_hosts=_env_list("EXTRA_ALLOWED_HOSTS"),
        allow_generic_extractor=_env_bool("ALLOW_GENERIC_EXTRACTOR", False),
    )
