"""Format options and the quality contract (no silent downgrade)."""

import pytest

from namao.engine.base import MediaFormat, MediaMetadata
from namao.engine.formats import build_format_options
from namao.engine.ytdlp import _selection_options
from namao.models import parse_quality


def fmt(height=None, vcodec="avc1", acodec="none", tbr=1000, size=None, fps=30, abr=None, fid="x"):
    return MediaFormat(fid, height, None, fps, vcodec, acodec, "mp4", tbr, abr, size)


def meta(*formats):
    return MediaMetadata("youtube", "id", "t", "u", 100, None, False, tuple(formats))


def test_lists_only_heights_the_source_offers_highest_first():
    options = build_format_options(meta(fmt(360), fmt(1080), fmt(720), fmt(None, "none", "mp4a", abr=128)))
    assert [o.id for o in options] == ["1080", "720", "360", "audio"]
    assert options[0].note == "Highest available"
    assert options[-1].kind == "audio"


def test_size_estimate_adds_audio_for_video_only_streams():
    options = build_format_options(
        meta(fmt(720, size=1_000), fmt(None, "none", "opus", size=200, abr=130))
    )
    assert options[0].size_bytes == 1_200 and options[0].needs_merge is True


def test_progressive_stream_needs_no_merge():
    options = build_format_options(meta(fmt(360, acodec="mp4a", size=500)))
    assert options[0].needs_merge is False and options[0].size_bytes == 500


def test_unknown_sizes_stay_unknown():
    assert build_format_options(meta(fmt(360, tbr=None)))[0].size_bytes is None


def test_missing_sizes_are_estimated_from_bitrate_and_flagged_as_estimates():
    option = build_format_options(meta(fmt(360, tbr=800)))[0]  # 800 kbit/s x 100 s
    assert option.size_bytes == 800 * 125 * 100 and option.size_estimated is True
    exact = build_format_options(meta(fmt(360, tbr=800, size=5_000)))[0]
    assert exact.size_bytes == 5_000 and exact.size_estimated is False


def test_high_fps_is_shown_in_the_label():
    assert build_format_options(meta(fmt(1080, fps=60)))[0].label == "1080p60"


def test_duplicate_heights_collapse_to_one_option():
    options = build_format_options(meta(fmt(720, tbr=500, fps=30), fmt(720, tbr=900, fps=60)))
    assert [o.id for o in options if o.kind == "video"] == ["720"]


def test_source_without_heights_offers_best_available():
    options = build_format_options(meta(fmt(None, acodec="mp4a")))
    assert [o.id for o in options] == ["best", "audio"]


def test_audio_only_source_offers_audio():
    options = build_format_options(meta(fmt(None, "none", "mp4a", abr=96)))
    assert [o.id for o in options] == ["audio"]


def test_empty_source_has_no_options():
    assert build_format_options(meta()) == []


def test_exact_height_selection_has_no_silent_fallback_to_other_resolutions():
    selection = _selection_options("height", 1080)["format"]
    assert selection == "bv*[height=1080]+ba/b[height=1080]"
    assert "<=" not in selection and not selection.endswith("/b")


def test_best_and_audio_selection():
    assert _selection_options("best", None)["format"] == "bv*+ba/b"
    audio = _selection_options("audio", None)
    assert audio["postprocessors"][0]["preferredcodec"] == "mp3"


@pytest.mark.parametrize("value, expected", [
    ("best", ("best", None)), ("audio", ("audio", None)), ("1080", ("height", 1080)), ("144", ("height", 144)),
])
def test_parse_quality_accepts(value, expected):
    assert parse_quality(value) == expected


@pytest.mark.parametrize("value", ["", "0", "99", "99999", "1080p", "-1", "best;rm", "1e3", " 720", "720\n", "BEST"])
def test_parse_quality_rejects(value):
    with pytest.raises(ValueError):
        parse_quality(value)
