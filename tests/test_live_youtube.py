"""Opt-in smoke tests against real YouTube (NAMAO_LIVE_TESTS=1).

Asset: Blender Foundation, "Big Buck Bunny 60fps 4K" (Creative Commons
Attribution 3.0, https://peach.blender.org), the same video used in
docs/upgrade-audit.md. Downloads are 144p / audio to keep traffic small. These
exercise the genuine chain: yt-dlp (pinned) + yt-dlp-ejs + the JS runtime +
FFmpeg. Run them in CI on a schedule and before promoting a new yt-dlp pin;
they are skipped by default because they depend on the live platform.
"""

import os
import time

import pytest

from namao.config import Settings
from namao.engine.base import DownloadRequest
from namao.engine.formats import build_format_options
from namao.engine.ytdlp import YtDlpEngine
from tests.conftest import requires_ffmpeg

pytestmark = [
    pytest.mark.live,
    requires_ffmpeg,
    pytest.mark.skipif(os.environ.get("NAMAO_LIVE_TESTS") != "1", reason="set NAMAO_LIVE_TESTS=1 to run"),
]

URL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"


@pytest.fixture()
def engine(tmp_path):
    settings = Settings(data_dir=tmp_path / "data")
    settings.ensure_dirs()
    return YtDlpEngine(settings)


def test_dependency_chain_is_healthy(engine):
    diagnostics = engine.diagnostics()
    assert diagnostics.ok, diagnostics.problems
    assert not diagnostics.stale, diagnostics.warnings


def test_metadata_and_formats(engine):
    metadata = engine.extract_metadata(URL)
    options = build_format_options(metadata)
    ids = [o.id for o in options]
    assert "audio" in ids and {"1080", "720", "480", "144"} <= set(ids)
    assert "Big Buck Bunny" in metadata.title


@pytest.mark.parametrize("quality, expect_video", [("144", True), ("audio", False)])
def test_download_merge_and_verify(engine, tmp_path, quality, expect_video):
    workdir = tmp_path / quality
    workdir.mkdir()
    request = DownloadRequest(URL, "youtube", quality, workdir, 300 * 1024 * 1024, 4 * 3600)
    downloaded = engine.download(request, lambda u: None, lambda: False, time.monotonic() + 600)
    verified = engine.verify_output(downloaded, request)
    assert verified.has_audio and verified.has_video is expect_video
    if expect_video:
        assert verified.height == 144
