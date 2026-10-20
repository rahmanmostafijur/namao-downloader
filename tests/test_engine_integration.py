"""Real yt-dlp + real FFmpeg/FFprobe against a local synthetic DASH server.

No mocks in the extraction/merge path: separate video-only and audio-only
streams are downloaded by yt-dlp and merged by FFmpeg, then verified with
FFprobe. Requires ffmpeg/ffprobe on PATH (skipped otherwise).
"""

import subprocess
import time

import pytest

from namao.engine import tools
from namao.engine.base import DownloadedFile, DownloadRequest, Stage
from namao.engine.media import verify_media_file
from namao.engine.ytdlp import YtDlpEngine
from namao.errors import CancelledError, ErrorCode, JobTimeoutError, NamaoError
from tests.conftest import requires_ffmpeg

pytestmark = [pytest.mark.integration, requires_ffmpeg]

MAX_BYTES = 200 * 1024 * 1024


@pytest.fixture()
def engine(settings):
    settings.ensure_dirs()
    return YtDlpEngine(settings)


def request_for(engine_url, quality, workdir):
    workdir.mkdir(parents=True, exist_ok=True)
    return DownloadRequest(engine_url, "generic-test", quality, workdir, MAX_BYTES, 3600)


def run(engine, url, quality, workdir, *, cancel=lambda: False, timeout=120):
    updates = []
    request = request_for(url, quality, workdir)
    downloaded = engine.download(request, updates.append, cancel, time.monotonic() + timeout)
    return request, downloaded, updates


# ------------------------------------------------------------- diagnostics

def test_diagnostics_run_the_real_tools_and_report_versions(engine):
    diagnostics = engine.diagnostics()
    tools_by_name = {t.name: t for t in diagnostics.tools}
    assert tools_by_name["ffmpeg"].ok and tools_by_name["ffmpeg"].version
    assert tools_by_name["ffprobe"].ok and tools_by_name["ffprobe"].version
    assert tools_by_name["yt-dlp-ejs"].ok, "yt-dlp-ejs must match the version yt-dlp declares"
    assert diagnostics.engine == "yt-dlp" and diagnostics.channel in ("stable", "nightly")
    assert diagnostics.age_days is not None and diagnostics.age_days >= 0


def test_missing_js_runtime_is_a_readiness_problem_when_required(settings):
    strict = settings.with_overrides(js_runtime="deno", require_js_runtime=True, bin_dir=settings.data_dir)
    if tools.find_executable("deno", strict):
        pytest.skip("deno is installed")
    diagnostics = YtDlpEngine(strict).diagnostics()
    assert any("js runtime" in p for p in diagnostics.problems) and not diagnostics.ok


def test_missing_ffmpeg_is_reported_and_stops_downloads_before_any_network_use(settings, monkeypatch, tmp_path):
    monkeypatch.setattr("namao.engine.tools.shutil.which", lambda *a, **k: None)
    engine = YtDlpEngine(settings)
    assert any("ffmpeg" in p for p in engine.diagnostics().problems)
    request = request_for("http://localhost:1/never-contacted", "best", tmp_path / "w")
    with pytest.raises(NamaoError) as err:
        engine.download(request, lambda u: None, lambda: False, time.monotonic() + 5)
    assert err.value.code == ErrorCode.FFMPEG_MISSING


def test_toolchain_versions_are_checked_against_runtime_minimums():
    assert tools.parse_version("v24.13.0") == (24, 13, 0)
    assert tools.parse_version("deno 2.5.1 (stable, release, x86_64-pc-windows-msvc)") == (2, 5, 1)
    assert tools.parse_version("ffmpeg version 8.1.2-full_build") == (8, 1, 2)
    assert tools.MIN_RUNTIME_VERSIONS["node"] >= (22, 0, 0) and tools.MIN_RUNTIME_VERSIONS["deno"] >= (2, 3, 0)


# ----------------------------------------------------------------- metadata

def test_metadata_lists_the_formats_the_source_really_offers(engine, media_server):
    metadata = engine.extract_metadata(media_server())
    heights = sorted({f.height for f in metadata.formats if f.has_video})
    assert heights == [180, 360]
    assert all(not f.has_audio for f in metadata.formats if f.has_video), "streams are video-only: merge needed"


def test_the_generic_extractor_is_blocked_in_production_configuration(settings, media_server):
    production_like = settings.with_overrides(allow_generic_extractor=False)
    with pytest.raises(NamaoError) as err:
        YtDlpEngine(production_like).extract_metadata(media_server())
    assert err.value.code == ErrorCode.UNSUPPORTED_PLATFORM


def test_unavailable_media_is_classified_not_blamed_on_the_engine(engine, media_server):
    with pytest.raises(NamaoError) as err:
        engine.extract_metadata(media_server("gone/manifest.mpd"))
    assert err.value.code in (ErrorCode.VIDEO_UNAVAILABLE, ErrorCode.METADATA_FAILED)
    assert err.value.code != ErrorCode.ENGINE_OUTDATED


# ----------------------------------------------------------------- download

def test_separate_streams_are_merged_and_verified(engine, media_server, tmp_path):
    request, downloaded, updates = run(engine, media_server(), "best", tmp_path / "w")
    verified = engine.verify_output(downloaded, request)
    assert verified.has_video and verified.has_audio, "merge must produce a file with both streams"
    assert verified.height == 360 and 3.5 < verified.duration_seconds < 4.6
    assert downloaded.path.suffix == ".mp4" and verified.size_bytes > 1024
    stages = [u.stage for u in updates]
    assert stages[0] == Stage.FETCHING_METADATA and Stage.DOWNLOADING in stages and stages[-1] == Stage.MERGING
    percents = [u.percent for u in updates]
    assert percents == sorted(percents) and max(percents) <= 99.0, "progress is monotonic and never 100 before verify"


def test_exact_height_is_honoured(engine, media_server, tmp_path):
    request, downloaded, _ = run(engine, media_server(), "180", tmp_path / "w")
    assert engine.verify_output(downloaded, request).height == 180


def test_unavailable_height_fails_instead_of_silently_downgrading(engine, media_server, tmp_path):
    workdir = tmp_path / "w"
    with pytest.raises(NamaoError) as err:
        run(engine, media_server(), "720", workdir)
    assert err.value.code == ErrorCode.FORMAT_UNAVAILABLE
    assert not any(p.suffix in (".mp4", ".mkv", ".webm") for p in workdir.rglob("*") if p.is_file())


def test_audio_only_is_converted_to_mp3(engine, media_server, tmp_path):
    request, downloaded, _ = run(engine, media_server(), "audio", tmp_path / "w")
    verified = engine.verify_output(downloaded, request)
    assert downloaded.path.suffix == ".mp3" and verified.has_audio and not verified.has_video


def test_output_stays_inside_the_job_directory_with_a_fixed_name(engine, media_server, tmp_path):
    workdir = tmp_path / "w"
    _, downloaded, _ = run(engine, media_server(), "best", workdir)
    assert downloaded.path.parent == workdir and downloaded.path.name == "media.mp4"


def test_cancellation_stops_a_slow_download_quickly(engine, media_server, tmp_path):
    calls = {"n": 0}

    def cancel_after_first_progress():
        calls["n"] += 1
        return calls["n"] > 4

    started = time.monotonic()
    with pytest.raises(CancelledError):
        run(engine, media_server("slow/manifest.mpd"), "best", tmp_path / "w", cancel=cancel_after_first_progress)
    assert time.monotonic() - started < 20


def test_deadline_stops_a_slow_download(engine, media_server, tmp_path):
    with pytest.raises(JobTimeoutError):
        run(engine, media_server("slow/manifest.mpd"), "best", tmp_path / "w", timeout=1)


def test_failing_segments_surface_as_a_normalized_error_with_no_output(engine, media_server, tmp_path):
    workdir = tmp_path / "w"
    with pytest.raises(NamaoError):
        run(engine, media_server("broken/manifest.mpd"), "best", workdir)
    assert not (workdir / "media.mp4").exists()


def test_output_size_limit_is_enforced_while_downloading(engine, media_server, tmp_path):
    workdir = tmp_path / "w"
    workdir.mkdir()
    request = DownloadRequest(media_server(), "generic-test", "best", workdir, 1024, 3600)
    with pytest.raises(NamaoError) as err:
        engine.download(request, lambda u: None, lambda: False, time.monotonic() + 60)
    assert err.value.code == ErrorCode.FILE_TOO_LARGE


def test_duration_limit_is_enforced_before_downloading_when_the_source_reports_a_length(engine, tmp_path):
    request = DownloadRequest("https://youtu.be/x", "youtube", "best", tmp_path, MAX_BYTES, 60)
    with pytest.raises(NamaoError) as err:
        engine._check_policy({"duration": 3600, "id": "x"}, request)
    assert err.value.code == ErrorCode.DURATION_TOO_LONG
    with pytest.raises(NamaoError) as live:
        engine._check_policy({"is_live": True}, request)
    assert live.value.code == ErrorCode.UNSUPPORTED_CONTENT


def test_duration_limit_is_still_enforced_after_download_when_the_source_hides_its_length(engine, media_server, tmp_path):
    workdir = tmp_path / "w"
    workdir.mkdir()
    request = DownloadRequest(media_server(), "generic-test", "best", workdir, MAX_BYTES, 1)
    downloaded = engine.download(request, lambda u: None, lambda: False, time.monotonic() + 60)
    with pytest.raises(NamaoError) as err:
        engine.verify_output(downloaded, request)
    assert err.value.code == ErrorCode.DURATION_TOO_LONG


# ---------------------------------------------------------- output verifying

@pytest.fixture()
def good_file(engine, media_server, tmp_path):
    request, downloaded, _ = run(engine, media_server(), "best", tmp_path / "good")
    return request, downloaded


def verify(path, **overrides):
    ffprobe = tools.find_executable("ffprobe", __import__("namao.config", fromlist=["Settings"]).Settings())
    kwargs = dict(ffprobe=ffprobe, expect_video=True, max_bytes=MAX_BYTES, source_duration=None)
    kwargs.update(overrides)
    return verify_media_file(path, **kwargs)


def test_verification_rejects_missing_empty_and_garbage_files(tmp_path):
    with pytest.raises(NamaoError) as missing:
        verify(tmp_path / "nope.mp4")
    empty = tmp_path / "empty.mp4"
    empty.write_bytes(b"")
    with pytest.raises(NamaoError) as empty_err:
        verify(empty)
    garbage = tmp_path / "garbage.mp4"
    garbage.write_bytes(b"this is not a video" * 500)
    with pytest.raises(NamaoError) as garbage_err:
        verify(garbage)
    assert {e.value.code for e in (missing, empty_err, garbage_err)} == {ErrorCode.OUTPUT_INVALID}


def test_verification_rejects_truncated_output(good_file, tmp_path):
    _, downloaded = good_file
    with pytest.raises(NamaoError) as err:
        verify(downloaded.path, source_duration=60)  # file is ~4s of a claimed 60s
    assert err.value.code == ErrorCode.OUTPUT_INVALID and "truncated" in (err.value.detail or "")


def test_verification_rejects_wrong_stream_type(good_file, tmp_path):
    _, downloaded = good_file
    silent = tmp_path / "video_only.mp4"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(downloaded.path), "-an", "-c:v", "copy",
                    str(silent)], check=True)
    with pytest.raises(NamaoError):
        verify(silent, expect_video=False)  # asked for audio, none present
    assert verify(silent, expect_video=True).has_audio is False


def test_verification_enforces_the_size_cap(good_file):
    _, downloaded = good_file
    with pytest.raises(NamaoError) as err:
        verify(downloaded.path, max_bytes=2048)
    assert err.value.code == ErrorCode.FILE_TOO_LARGE


def test_engine_verify_output_uses_ffprobe(engine, good_file):
    request, downloaded = good_file
    verified = engine.verify_output(downloaded, request)
    assert verified.container and verified.size_bytes == downloaded.path.stat().st_size
    bad = DownloadedFile(path=downloaded.path.parent / "absent.mp4", title="x", duration_seconds=4)
    with pytest.raises(NamaoError):
        engine.verify_output(bad, request)
