"""The extractor allow-list must name yt-dlp extractors the way yt-dlp matches them.

yt-dlp applies `allowed_extractors` / `--use-extractors` as case-insensitive whole-name regexes over
each extractor's IE_NAME (e.g. "facebook:reel"), not its class key ("FacebookReel"). A pattern that
matches no extractor silently blocks that site's links, which surfaced as Facebook Reels being
rejected as "unsupported". These tests run against the installed yt-dlp, so they also catch an
upgrade that renames an extractor.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

yt_dlp_extractor = pytest.importorskip("yt_dlp.extractor")

from namao.engine.ytdlp import _ALLOWED_EXTRACTORS  # noqa: E402

DART_OPTIONS = (
    Path(__file__).resolve().parents[1]
    / "mobile_flutter" / "lib" / "data" / "engine" / "ytdlp_options.dart"
)

# Single-video kinds a user pastes, each with a URL its extractor must claim.
MUST_BE_REACHABLE = {
    "facebook": "https://www.facebook.com/watch/?v=1234567890",
    "facebook:reel": "https://www.facebook.com/reel/1234567890",
    "youtube:clip": "https://www.youtube.com/clip/UgkxAbCdEfGhIjKlMnOpQrStUvWxYz0123",
    "Instagram": "https://www.instagram.com/reel/CxAbCdEfGhI/",
    "TikTok": "https://www.tiktok.com/@someone/video/1234567890123456789",
    "vm.tiktok": "https://vm.tiktok.com/ZMabcdefg/",
    "twitter": "https://x.com/someone/status/1234567890",
}

NOT_ALLOWED = ("generic", "youtube:tab", "instagram:user", "facebook:ads", "tiktok:user")


def _ie_names() -> set[str]:
    return {ie.IE_NAME.lower() for ie in yt_dlp_extractor.gen_extractor_classes()}


def _matching(patterns, names) -> set[str]:
    return {n for p in patterns for n in names if re.compile(p, re.I).fullmatch(n)}


def _dart_patterns() -> list[str]:
    text = DART_OPTIONS.read_text(encoding="utf-8")
    block = re.search(r"_allowedExtractors\s*=\s*\[(.*?)\];", text, re.S)
    assert block, "could not find _allowedExtractors in ytdlp_options.dart"
    return re.findall(r"r'([^']+)'", block.group(1))


def test_server_every_pattern_matches_a_real_extractor():
    names = _ie_names()
    dead = [p for p in _ALLOWED_EXTRACTORS if not _matching([p], names)]
    assert not dead, f"allow-list entries that match no yt-dlp extractor: {dead}"


@pytest.mark.skipif(not DART_OPTIONS.exists(), reason="Flutter app not in this checkout")
def test_app_every_pattern_matches_a_real_extractor():
    patterns = _dart_patterns()
    assert patterns, "no patterns parsed from the Dart file"
    assert all("," not in p for p in patterns), "yt-dlp splits --use-extractors on commas"
    names = _ie_names()
    dead = [p for p in patterns if not _matching([p], names)]
    assert not dead, f"allow-list entries that match no yt-dlp extractor: {dead}"


@pytest.mark.parametrize("ie_name,url", MUST_BE_REACHABLE.items())
def test_supported_urls_are_claimed_by_an_allowed_extractor(ie_name, url):
    classes = yt_dlp_extractor.gen_extractor_classes()
    claimed = {c.IE_NAME.lower() for c in classes if c.IE_NAME != "generic" and c.suitable(url)}
    assert claimed, f"no extractor claims {url}"
    allowed = _matching(_ALLOWED_EXTRACTORS, claimed)
    assert allowed, f"{url} is claimed by {claimed} but none is on the server allow-list"


def test_playlists_users_and_generic_stay_blocked():
    allowed = _matching(_ALLOWED_EXTRACTORS, _ie_names())
    assert not allowed.intersection(NOT_ALLOWED)
