"""Normalized failure taxonomy.

Every failure that reaches a client is a `NamaoError` with a stable `code`, a
safe user-facing `message`, and a `retryable` flag. Raw exception text never
leaves the server except as a short, sanitized `detail` (see `sanitize_detail`).

`classify_exception` maps yt-dlp / OS / subprocess errors onto these codes. It
is intentionally conservative: anything it cannot positively identify becomes
`DOWNLOAD_FAILED` / `METADATA_FAILED` rather than being blamed on the library.
"""

from __future__ import annotations

import errno
import re
from dataclasses import dataclass
from enum import Enum


class ErrorCode(str, Enum):
    # request / policy
    INVALID_URL = "invalid_url"
    UNSUPPORTED_PLATFORM = "unsupported_platform"
    UNSUPPORTED_CONTENT = "unsupported_content"  # playlist, live stream, ...
    INVALID_QUALITY = "invalid_quality"
    FILE_TOO_LARGE = "file_too_large"
    DURATION_TOO_LONG = "duration_too_long"
    QUEUE_FULL = "queue_full"
    RATE_LIMITED_LOCAL = "too_many_requests"
    # source-side
    VIDEO_UNAVAILABLE = "video_unavailable"  # deleted / private / removed
    AUTH_REQUIRED = "auth_required"  # login, age gate, members-only
    GEO_RESTRICTED = "geo_restricted"
    RATE_LIMITED = "source_rate_limited"
    ACCESS_BLOCKED = "access_blocked"  # bot-check / IP or network block
    FORMAT_UNAVAILABLE = "format_unavailable"
    # engine / dependencies
    ENGINE_OUTDATED = "engine_outdated"
    EXTRACTOR_BROKEN = "extractor_broken"
    JS_RUNTIME_MISSING = "js_runtime_missing"
    JS_CHALLENGE_FAILED = "js_challenge_failed"
    FFMPEG_MISSING = "ffmpeg_missing"
    ENVIRONMENT_UNSUPPORTED = "environment_unsupported"
    # network
    NETWORK_TRANSIENT = "network_transient"
    TIMEOUT = "timeout"
    # media
    MERGE_FAILED = "merge_failed"
    OUTPUT_INVALID = "output_invalid"
    STORAGE_FULL = "storage_full"
    # fall-throughs
    METADATA_FAILED = "metadata_failed"
    DOWNLOAD_FAILED = "download_failed"
    # lifecycle
    CANCELLED = "cancelled"
    INTERRUPTED = "interrupted"
    NOT_FOUND = "not_found"
    EXPIRED = "expired"
    INVALID_REQUEST = "invalid_request"
    CONFLICT = "conflict"
    UNAUTHORIZED = "unauthorized"
    INTERNAL = "internal_error"


_MESSAGES: dict[ErrorCode, str] = {
    ErrorCode.INVALID_URL: "That doesn't look like a valid video link.",
    ErrorCode.UNSUPPORTED_PLATFORM: "That site isn't supported. Use a YouTube, Facebook, TikTok, X/Twitter or Instagram link.",
    ErrorCode.UNSUPPORTED_CONTENT: "Only single, non-live videos are supported (no playlists or live streams).",
    ErrorCode.INVALID_QUALITY: "That quality option isn't valid.",
    ErrorCode.FILE_TOO_LARGE: "The file is larger than this server allows.",
    ErrorCode.DURATION_TOO_LONG: "The video is longer than this server allows.",
    ErrorCode.QUEUE_FULL: "The server is busy. Please try again in a few minutes.",
    ErrorCode.RATE_LIMITED_LOCAL: "Too many requests. Please slow down and try again shortly.",
    ErrorCode.VIDEO_UNAVAILABLE: "This video is unavailable. It may be private, deleted, or removed.",
    ErrorCode.AUTH_REQUIRED: "This video requires signing in (private, age-restricted or members-only). Namao can't download it without authorized access.",
    ErrorCode.GEO_RESTRICTED: "This video isn't available in the server's region.",
    ErrorCode.RATE_LIMITED: "The source site is rate-limiting this server. Try again later.",
    ErrorCode.ACCESS_BLOCKED: "The source site refused the request from this server's network. Retrying or updating may not help.",
    ErrorCode.FORMAT_UNAVAILABLE: "The selected quality isn't available for this video. Pick another option.",
    ErrorCode.ENGINE_OUTDATED: "The download engine is out of date for this site. The operator needs to update it.",
    ErrorCode.EXTRACTOR_BROKEN: "The site changed and the extractor couldn't read this video. An engine update may be needed.",
    ErrorCode.JS_RUNTIME_MISSING: "A required JavaScript runtime isn't installed on the server.",
    ErrorCode.JS_CHALLENGE_FAILED: "The server couldn't solve the site's JavaScript challenge. The operator should check the JS runtime and engine versions.",
    ErrorCode.FFMPEG_MISSING: "FFmpeg isn't installed on the server, so this download can't be processed.",
    ErrorCode.ENVIRONMENT_UNSUPPORTED: "The server environment can't run this download.",
    ErrorCode.NETWORK_TRANSIENT: "A temporary network problem interrupted the download.",
    ErrorCode.TIMEOUT: "The download took too long and was stopped.",
    ErrorCode.MERGE_FAILED: "The video was downloaded but combining audio and video failed.",
    ErrorCode.OUTPUT_INVALID: "The downloaded file failed verification and was discarded.",
    ErrorCode.STORAGE_FULL: "The server is out of storage space.",
    ErrorCode.METADATA_FAILED: "Couldn't read this video's information.",
    ErrorCode.DOWNLOAD_FAILED: "The download failed.",
    ErrorCode.CANCELLED: "The download was cancelled.",
    ErrorCode.INTERRUPTED: "The download was interrupted. Start it again.",
    ErrorCode.NOT_FOUND: "Not found.",
    ErrorCode.EXPIRED: "This download has expired and its file was deleted. Start it again.",
    ErrorCode.INVALID_REQUEST: "The request was malformed.",
    ErrorCode.CONFLICT: "That action isn't possible in the job's current state.",
    ErrorCode.UNAUTHORIZED: "Missing or invalid credentials.",
    ErrorCode.INTERNAL: "Something went wrong on the server.",
}

# Worth retrying automatically (bounded by Settings.max_attempts).
_AUTO_RETRYABLE = {
    ErrorCode.NETWORK_TRANSIENT,
    ErrorCode.RATE_LIMITED,
}
# The client may sensibly try again later even though we don't auto-retry.
_CLIENT_RETRYABLE = _AUTO_RETRYABLE | {
    ErrorCode.INTERRUPTED,
    ErrorCode.TIMEOUT,
    ErrorCode.QUEUE_FULL,
    ErrorCode.RATE_LIMITED_LOCAL,
    ErrorCode.ACCESS_BLOCKED,
    ErrorCode.STORAGE_FULL,
}


def user_message(code: ErrorCode) -> str:
    return _MESSAGES[code]


class NamaoError(Exception):
    """A normalized, client-safe failure."""

    def __init__(self, code: ErrorCode, detail: str | None = None, message: str | None = None):
        self.code = code
        self.message = message or user_message(code)
        self.detail = sanitize_detail(detail) if detail else None
        super().__init__(f"{code.value}: {self.message}")

    @property
    def retryable(self) -> bool:
        """True when it's reasonable to try again (automatically or by the client)."""
        return self.code in _CLIENT_RETRYABLE

    @property
    def auto_retryable(self) -> bool:
        return self.code in _AUTO_RETRYABLE


class CancelledError(Exception):
    """Raised inside an engine when the job was cancelled."""


class JobTimeoutError(Exception):
    """Raised inside an engine when the job exceeded its time budget."""


# ---------------------------------------------------------------------------
# Sanitizing text before it is stored / returned / logged
# ---------------------------------------------------------------------------

_URL_RE = re.compile(r"(?:https?:)?//[^\s'\"<>]+", re.IGNORECASE)
_URL_HOST_RE = re.compile(r"((?:https?:)?)//(?:[^/?#@]*@)?([^/?#]+)", re.IGNORECASE)
# Windows path: directory segments may contain spaces; the final segment ends at whitespace.
_WIN_PATH_RE = re.compile(r"\b[A-Za-z]:\\(?:[^\\/:*?\"<>|\r\n]+\\)*[^\\/:*?\"<>|\s]*")
_POSIX_PATH_RE = re.compile(r"(?<![\w:/.\-])/[\w.\-]+(?:/[\w.\-]*)*")
_SECRET_PARAM_RE = re.compile(
    r"(?i)\b(token|access_token|api[_-]?key|key|sig|signature|password|passwd|secret|sessionid|cookie|"
    r"authorization)(\s*[=:]\s*)(?:bearer\s+)?[^\s&;,'\"]+"
)
_BEARER_RE = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+")
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
MAX_DETAIL_CHARS = 240


def redact(text: str) -> str:
    """Strip anything that could carry credentials or reveal server layout.

    URLs are reduced to scheme://host/… (userinfo, path and query dropped: signed
    media URLs keep their secrets there), token-like key=value pairs and bearer
    tokens are masked, and filesystem paths are replaced.
    """

    def _url(match: re.Match[str]) -> str:
        parts = _URL_HOST_RE.match(match.group(0))
        if not parts:
            return "<url>"
        scheme = parts.group(1) or "https:"
        return f"{scheme}//{parts.group(2)}/…"

    text = _ANSI_RE.sub("", text)
    text = _URL_RE.sub(_url, text)
    text = _BEARER_RE.sub("Bearer <redacted>", text)
    text = _SECRET_PARAM_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", text)
    text = _WIN_PATH_RE.sub("<path>", text)
    text = _POSIX_PATH_RE.sub("<path>", text)
    return text


def sanitize_detail(text: str) -> str:
    cleaned = " ".join(redact(text).split())
    if len(cleaned) > MAX_DETAIL_CHARS:
        cleaned = cleaned[: MAX_DETAIL_CHARS - 1] + "…"
    return cleaned


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

# Order matters: the first matching rule wins, so specific rules come first.
_RULES: tuple[tuple[ErrorCode, tuple[str, ...]], ...] = (
    (ErrorCode.FFMPEG_MISSING, (
        "ffmpeg is not installed", "ffmpeg not found", "ffprobe and ffmpeg not found",
        "ffmpeg or avconv not found", "ffmpeg/avconv not found", "unable to find ffmpeg",
        "ffprobe/avprobe and ffmpeg/avconv not found", "no such file or directory: 'ffmpeg'",
        "requested merging of multiple formats but ffmpeg",
    )),
    (ErrorCode.STORAGE_FULL, ("no space left on device", "disk full", "not enough space", "errno 28")),
    (ErrorCode.FILE_TOO_LARGE, ("larger than max-filesize", "file is larger than")),
    (ErrorCode.JS_RUNTIME_MISSING, ("no supported javascript runtime", "javascript runtime could not be found")),
    (ErrorCode.JS_CHALLENGE_FAILED, (
        "challenge solving failed", "n challenge", "nsig extraction failed", "signature extraction failed",
        "unable to solve", "only images are available", "js challenge",
    )),
    (ErrorCode.MERGE_FAILED, (
        "error merging", "merger", "postprocessing:", "postprocessing error",
        "ffmpeg exited with code", "conversion failed", "error opening output",
    )),
    (ErrorCode.UNSUPPORTED_CONTENT, ("is live", "live event will begin", "premieres in", "this live event")),
    (ErrorCode.UNSUPPORTED_PLATFORM, ("unsupported url", "no suitable extractor", "extractor is not allowed")),
    (ErrorCode.INVALID_URL, ("is not a valid url", "invalid url")),
    (ErrorCode.ACCESS_BLOCKED, (
        "not a bot", "ip is likely being blocked", "your ip address is blocked", "http error 407",
    )),
    (ErrorCode.RATE_LIMITED, (
        "http error 429", "too many requests", "rate-limited", "rate limited", "rate limit",
        "try again later",
    )),
    (ErrorCode.GEO_RESTRICTED, (
        "not available in your country", "blocked it in your country", "geo restrict", "geo-restrict",
        "not available in your location", "unavailable in your country",
        "uploader has not made this video available",
    )),
    (ErrorCode.AUTH_REQUIRED, (
        "sign in to confirm your age", "age-restricted", "age restricted", "inappropriate for some users",
        "login required", "log in", "sign in", "members-only", "members only", "join this channel",
        "private video", "this video is private", "requires authentication", "use --cookies",
        "cookies are needed", "authentication required",
    )),
    (ErrorCode.VIDEO_UNAVAILABLE, (
        "video unavailable", "has been removed", "this video is no longer available",
        "account associated with this video has been terminated", "does not exist",
        "this video isn't available", "content isn't available", "content is not available",
        "removed by the uploader", "no longer available", "copyright", "http error 404", "http error 410",
        "post is unavailable", "page isn't available",
    )),
    (ErrorCode.FORMAT_UNAVAILABLE, (
        "requested format is not available", "no video formats found", "no formats found",
        "no video could be found",
    )),
    (ErrorCode.NETWORK_TRANSIENT, (
        "timed out", "timeout", "connection reset", "connection aborted", "temporary failure",
        "name or service not known", "getaddrinfo failed", "network is unreachable", "econnreset",
        "failed to establish a new connection", "remote end closed connection", "incompleteread",
        "incomplete read", "http error 500", "http error 502", "http error 503", "http error 504",
        "transporterror", "ssl:", "unexpected eof", "connection refused", "read error",
        "chunkedencodingerror",
    )),
    (ErrorCode.EXTRACTOR_BROKEN, (
        "unable to extract", "please report this issue", "make sure you are using the latest version",
        "unable to download json metadata", "player response", "unable to parse", "failed to parse",
    )),
)

# A 403 on the media request: could be an outdated engine (we measured exactly
# that on yt-dlp 2026.07.04) or a network block. Decide with engine age.
_FORBIDDEN_MARKERS = ("http error 403", "403: forbidden")


def classify_exception(
    exc: BaseException,
    *,
    phase: str = "download",
    engine_stale: bool = False,
) -> NamaoError:
    """Translate an arbitrary exception into a NamaoError.

    `phase` is "metadata" or "download" and only affects the fall-through code.
    `engine_stale` should be True when the installed yt-dlp is older than the
    operator's freshness threshold; it upgrades ambiguous 403 / extractor
    failures to `ENGINE_OUTDATED` instead of guessing at the network.
    """
    if isinstance(exc, NamaoError):
        return exc
    if isinstance(exc, CancelledError):
        return NamaoError(ErrorCode.CANCELLED)
    if isinstance(exc, JobTimeoutError):
        return NamaoError(ErrorCode.TIMEOUT)
    if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
        return NamaoError(ErrorCode.STORAGE_FULL, str(exc))
    if isinstance(exc, FileNotFoundError) and _is_ffmpeg_name(exc):
        return NamaoError(ErrorCode.FFMPEG_MISSING, str(exc))
    if isinstance(exc, TimeoutError):
        return NamaoError(ErrorCode.NETWORK_TRANSIENT, str(exc))

    text = str(exc)
    lowered = text.lower()

    for code, markers in _RULES:
        if any(marker in lowered for marker in markers):
            return NamaoError(_maybe_upgrade(code, engine_stale), text)

    if any(marker in lowered for marker in _FORBIDDEN_MARKERS):
        return NamaoError(ErrorCode.ENGINE_OUTDATED if engine_stale else ErrorCode.ACCESS_BLOCKED, text)

    fallback = ErrorCode.METADATA_FAILED if phase == "metadata" else ErrorCode.DOWNLOAD_FAILED
    return NamaoError(fallback, text)


def _maybe_upgrade(code: ErrorCode, engine_stale: bool) -> ErrorCode:
    if engine_stale and code in {ErrorCode.EXTRACTOR_BROKEN, ErrorCode.JS_CHALLENGE_FAILED}:
        return ErrorCode.ENGINE_OUTDATED
    return code


def _is_ffmpeg_name(exc: FileNotFoundError) -> bool:
    name = str(getattr(exc, "filename", "") or exc).lower()
    return "ffmpeg" in name or "ffprobe" in name


@dataclass(frozen=True)
class ErrorBody:
    """Wire representation, identical for HTTP errors and failed jobs."""

    code: str
    message: str
    retryable: bool
    detail: str | None = None

    @classmethod
    def from_error(cls, error: NamaoError) -> "ErrorBody":
        return cls(error.code.value, error.message, error.retryable, error.detail)
