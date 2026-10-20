"""Input hardening: URL allowlist, SSRF checks, and safe filenames.

Submitted URLs are untrusted. The old code matched platform names anywhere in
the string, so `https://evil.example/?x=youtube.com` passed and was handed to
yt-dlp's generic extractor. Here the *parsed host* must belong to a platform
allowlist, the port and scheme are restricted, userinfo is rejected, and the
host must not resolve to a private / loopback / link-local address.

Redirect validation: yt-dlp follows redirects inside its platform extractors
(e.g. youtu.be, fb.watch, vm.tiktok.com). The engine additionally restricts
yt-dlp to platform extractors via `allowed_extractors` (see engine/ytdlp.py),
so a redirect can never be handed to the generic "fetch anything" extractor.
DNS pinning per redirect hop is not possible through yt-dlp's API; this is
documented as a residual risk in docs/architecture.md.
"""

from __future__ import annotations

import ipaddress
import re
import socket
import unicodedata
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

from .config import Settings
from .errors import ErrorCode, NamaoError

MAX_URL_LENGTH = 2048

# platform -> registrable domains. A host matches if it equals a domain or is
# a subdomain of it ("m.youtube.com" matches "youtube.com"; "notyoutube.com"
# and "youtube.com.evil.example" do not).
PLATFORM_DOMAINS: dict[str, tuple[str, ...]] = {
    "youtube": ("youtube.com", "youtu.be", "youtube-nocookie.com"),
    "facebook": ("facebook.com", "fb.watch", "fb.com"),
    "tiktok": ("tiktok.com",),
    "twitter": ("twitter.com", "x.com"),
    "instagram": ("instagram.com",),
}

_ALLOWED_PORTS = {None, 80, 443}
# Strict LDH hostname labels. Python's idna codec doesn't enforce this, and urlsplit leaves
# characters such as a backslash in the hostname, which browsers treat as a path separator.
_HOST_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+")
_LABEL_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")
_NAT64 = ipaddress.ip_network("64:ff9b::/96")
_SIXTO4 = ipaddress.ip_network("2002::/16")
_CONTROL_CHARS = re.compile(r"[\x00-\x20\x7f]")


@dataclass(frozen=True)
class ValidatedUrl:
    url: str
    platform: str
    host: str


def _platform_for_host(host: str, extra_hosts: tuple[str, ...]) -> str | None:
    for platform, domains in PLATFORM_DOMAINS.items():
        if any(host == d or host.endswith("." + d) for d in domains):
            return platform
    if any(host == h or host.endswith("." + h) for h in extra_hosts):
        return "generic-test"
    return None


def _is_public_address(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address.split("%")[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address):
        embedded = ip.ipv4_mapped
        if embedded is None and ip in _NAT64:
            embedded = ipaddress.IPv4Address(int(ip) & 0xFFFFFFFF)
        if embedded is None and ip in _SIXTO4:
            embedded = ipaddress.IPv4Address((int(ip) >> 80) & 0xFFFFFFFF)
        if embedded is not None:
            return _is_public_address(str(embedded))
    return ip.is_global and not ip.is_multicast


def assert_public_host(host: str) -> None:
    """Reject hosts that resolve to non-public addresses.

    A DNS failure is *not* an SSRF signal (the platform domain is allowlisted),
    so it is left for the engine to report as a network problem.
    """
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except socket.gaierror:
        return
    for info in infos:
        if not _is_public_address(info[4][0]):
            raise NamaoError(ErrorCode.INVALID_URL, "host resolves to a non-public address")


def validate_url(raw: str, settings: Settings) -> ValidatedUrl:
    """Return a normalized, allowlisted URL or raise NamaoError."""
    if not isinstance(raw, str):
        raise NamaoError(ErrorCode.INVALID_URL)
    candidate = raw.strip()
    if not candidate or len(candidate) > MAX_URL_LENGTH or _CONTROL_CHARS.search(candidate):
        raise NamaoError(ErrorCode.INVALID_URL)
    if "://" not in candidate:
        candidate = "https://" + candidate.lstrip("/")

    try:
        parts = urlsplit(candidate)
        port = parts.port
    except ValueError:
        raise NamaoError(ErrorCode.INVALID_URL) from None

    if parts.scheme not in ("http", "https"):
        raise NamaoError(ErrorCode.INVALID_URL, "scheme not allowed")
    if parts.username is not None or parts.password is not None:
        raise NamaoError(ErrorCode.INVALID_URL, "credentials in URL")
    if port not in _ALLOWED_PORTS and not settings.allow_private_networks:
        raise NamaoError(ErrorCode.INVALID_URL, "port not allowed")

    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        raise NamaoError(ErrorCode.INVALID_URL)
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        raise NamaoError(ErrorCode.INVALID_URL) from None
    valid_host = _HOST_RE.fullmatch(host) or (settings.allow_private_networks and _LABEL_RE.fullmatch(host))
    if not valid_host:  # (single-label hosts like "localhost" are only valid in test mode)
        raise NamaoError(ErrorCode.INVALID_URL, "host contains illegal characters")
    # Literal IPs are never platform hosts.
    try:
        ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        pass
    else:
        raise NamaoError(ErrorCode.UNSUPPORTED_PLATFORM)

    platform = _platform_for_host(host, settings.extra_allowed_hosts)
    if platform is None:
        raise NamaoError(ErrorCode.UNSUPPORTED_PLATFORM)

    if not settings.allow_private_networks:
        assert_public_host(host)

    normalized = urlunsplit((parts.scheme, host if port is None else f"{host}:{port}", parts.path, parts.query, ""))
    return ValidatedUrl(url=normalized, platform=platform, host=host)


# ---------------------------------------------------------------------------
# Filenames
# ---------------------------------------------------------------------------

_RESERVED_WINDOWS = {
    "con", "prn", "aux", "nul",
    *(f"com{i}" for i in range(1, 10)),
    *(f"lpt{i}" for i in range(1, 10)),
}
_ILLEGAL_CHARS = re.compile(r'[<>:"/\\|?*\x00-\x1f\x7f]')
MAX_FILENAME_BYTES = 120


def _truncate_utf8(text: str, max_bytes: int) -> str:
    encoded = text.encode("utf-8")
    if len(encoded) <= max_bytes:
        return text
    return encoded[:max_bytes].decode("utf-8", errors="ignore")


def safe_filename(title: str | None, extension: str, fallback: str = "video") -> str:
    """Build a download filename that is safe on Windows, macOS and Linux.

    Untrusted titles may contain path separators, control characters, bidi
    overrides or reserved Windows device names. The extension comes from our
    own verified output, never from the title.
    """
    ext = re.sub(r"[^A-Za-z0-9]", "", extension)[:8].lower() or "bin"
    name = unicodedata.normalize("NFC", title or "")
    name = "".join(ch for ch in name if unicodedata.category(ch) not in {"Cc", "Cf", "Cs", "Co"})
    name = _ILLEGAL_CHARS.sub(" ", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    name = _truncate_utf8(name, MAX_FILENAME_BYTES).strip(" .")
    if not name or name.lower() in _RESERVED_WINDOWS:
        name = fallback
    return f"{name}.{ext}"
