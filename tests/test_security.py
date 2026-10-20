"""URL allowlist, SSRF defence and filename safety."""

import socket

import pytest

from namao.config import Settings
from namao.errors import ErrorCode, NamaoError
from namao.security import safe_filename, validate_url

PUBLIC = "142.250.72.14"


@pytest.fixture()
def strict():
    return Settings()  # production defaults: no private networks, no extra hosts


@pytest.fixture()
def dns(monkeypatch):
    """Make DNS hermetic: every name resolves to the address set on `dns.answer`."""

    class Resolver:
        answer = PUBLIC

    def fake_getaddrinfo(host, port, *args, **kwargs):
        family = socket.AF_INET6 if ":" in Resolver.answer else socket.AF_INET
        return [(family, socket.SOCK_STREAM, 6, "", (Resolver.answer, 0))]

    monkeypatch.setattr("namao.security.socket.getaddrinfo", fake_getaddrinfo)
    return Resolver


@pytest.mark.parametrize("url, platform", [
    ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "youtube"),
    ("https://youtu.be/aqz-KE-bpKQ", "youtube"),
    ("https://m.youtube.com/watch?v=abc", "youtube"),
    ("youtube.com/watch?v=abc", "youtube"),
    ("https://www.facebook.com/reel/123456", "facebook"),
    ("https://fb.watch/abc123/", "facebook"),
    ("https://vm.tiktok.com/ZMabc/", "tiktok"),
    ("https://www.tiktok.com/@user/video/123", "tiktok"),
    ("https://x.com/user/status/123", "twitter"),
    ("https://twitter.com/user/status/123", "twitter"),
    ("https://www.instagram.com/reel/abc/", "instagram"),
])
def test_supported_platform_urls_are_accepted(strict, dns, url, platform):
    assert validate_url(url, strict).platform == platform


@pytest.mark.parametrize("url", [
    "https://evil.example/?x=youtube.com",            # the old unanchored-regex bypass
    "https://evil.example/youtube.com/watch?v=1",
    "https://youtube.com.evil.example/watch?v=1",
    "https://notyoutube.com/watch?v=1",
    "https://fakeyoutu.be/abc",
    "https://example.com/",
])
def test_lookalike_hosts_are_rejected(strict, dns, url):
    with pytest.raises(NamaoError) as err:
        validate_url(url, strict)
    assert err.value.code == ErrorCode.UNSUPPORTED_PLATFORM


@pytest.mark.parametrize("url", [
    "ftp://youtube.com/x",
    "file:///etc/passwd",
    "javascript:alert(1)",
    "https://user:pw@youtube.com/watch?v=1",
    "https://youtube.com:8080/watch?v=1",
    "https://youtube.com/watch?v=1\nhttp://evil.example",
    "https://youtube.com/\x00",
    "",
    "   ",
    "https://youtube.com/" + "a" * 3000,
])
def test_malformed_or_dangerous_urls_are_rejected(strict, dns, url):
    with pytest.raises(NamaoError) as err:
        validate_url(url, strict)
    assert err.value.code in (ErrorCode.INVALID_URL, ErrorCode.UNSUPPORTED_PLATFORM)


@pytest.mark.parametrize("url", ["http://127.0.0.1/", "http://[::1]/", "http://169.254.169.254/latest/meta-data",
                                 "http://2130706433/"])
def test_literal_ip_hosts_are_never_platform_hosts(strict, dns, url):
    with pytest.raises(NamaoError):
        validate_url(url, strict)


@pytest.mark.parametrize("answer", ["127.0.0.1", "10.0.0.5", "192.168.1.9", "169.254.169.254", "172.16.0.1",
                                    "::1", "fd00::1", "::ffff:127.0.0.1", "0.0.0.0"])
def test_allowlisted_host_resolving_to_a_private_address_is_rejected(strict, dns, answer):
    dns.answer = answer
    with pytest.raises(NamaoError) as err:
        validate_url("https://www.youtube.com/watch?v=abc", strict)
    assert err.value.code == ErrorCode.INVALID_URL


def test_dns_failure_is_not_treated_as_ssrf(strict, monkeypatch):
    def failing(*args, **kwargs):
        raise socket.gaierror("no network")

    monkeypatch.setattr("namao.security.socket.getaddrinfo", failing)
    assert validate_url("https://youtu.be/abc", strict).platform == "youtube"


def test_url_is_normalized_without_fragment(strict, dns):
    result = validate_url("  https://YouTube.com/watch?v=abc#t=10  ", strict)
    assert result.url == "https://youtube.com/watch?v=abc"


def test_test_only_escape_hatches_exist_but_are_off_by_default(strict, dns):
    assert strict.allow_private_networks is False and strict.extra_allowed_hosts == ()
    with pytest.raises(NamaoError):
        validate_url("http://localhost:8000/x", strict)


# ----------------------------------------------------------------- filenames

@pytest.mark.parametrize("title", [
    "../../etc/passwd", "..\\..\\windows\\system32", "a/b\\c", "name\x00with\x1fcontrol",
    "evil‮gnp.exe", "CON", "nul", "   ", "...", "", None,
])
def test_filenames_cannot_escape_or_be_reserved(title):
    name = safe_filename(title, "mp4")
    assert "/" not in name and "\\" not in name and ".." not in name.replace(".mp4", "")
    assert name.endswith(".mp4")
    stem = name[:-4]
    assert stem and stem.lower() not in {"con", "nul"}
    assert all(ord(ch) >= 32 for ch in name) and "‮" not in name


def test_long_non_ascii_titles_are_truncated_on_a_utf8_boundary():
    name = safe_filename("বাংলা " * 100, "mp4")
    assert len(name.encode("utf-8")) <= 120 + len(".mp4")
    name.encode("utf-8").decode("utf-8")  # must be valid UTF-8


def test_extension_comes_from_the_verified_output_not_the_title():
    assert safe_filename("movie.exe", "mp4") == "movie.exe.mp4"
    assert safe_filename("x", "../../sh") == "x.sh"


@pytest.mark.parametrize("url", [
    r"https://evil.com\.youtube.com/x",
    "https://you tube.com/x",
    "https://youtube.com_evil.example/x",
    "https://-youtube.com/x",
    "https://youtube..com/x",
])
def test_hostnames_must_be_plain_ldh_labels(strict, dns, url):
    with pytest.raises(NamaoError):
        validate_url(url, strict)


@pytest.mark.parametrize("answer", ["64:ff9b::7f00:1", "64:ff9b::a00:1", "2002:7f00:1::1", "2002:c0a8:101::1"])
def test_embedded_private_ipv4_in_nat64_and_6to4_is_rejected(strict, dns, answer):
    dns.answer = answer
    with pytest.raises(NamaoError) as err:
        validate_url("https://www.youtube.com/watch?v=abc", strict)
    assert err.value.code == ErrorCode.INVALID_URL


def test_nat64_wrapping_a_public_address_is_allowed(strict, dns):
    dns.answer = "64:ff9b::8efa:480e"  # 142.250.72.14
    assert validate_url("https://www.youtube.com/watch?v=abc", strict).platform == "youtube"
