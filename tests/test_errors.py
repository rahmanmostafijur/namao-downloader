"""Failure classification: real yt-dlp / OS message samples -> normalized codes."""

import errno

import pytest

from namao.errors import (
    CancelledError, ErrorCode, JobTimeoutError, NamaoError, classify_exception, redact, sanitize_detail,
)


def classify(message, **kwargs):
    return classify_exception(Exception(message), **kwargs).code


@pytest.mark.parametrize("message, expected", [
    ("ERROR: [youtube] abc: Video unavailable", ErrorCode.VIDEO_UNAVAILABLE),
    ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video", ErrorCode.AUTH_REQUIRED),
    ("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", ErrorCode.AUTH_REQUIRED),
    ("ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser", ErrorCode.ACCESS_BLOCKED),
    ("ERROR: [youtube] abc: The uploader has not made this video available in your country", ErrorCode.GEO_RESTRICTED),
    ("ERROR: [youtube] abc: This video is not available in your country", ErrorCode.GEO_RESTRICTED),
    ("HTTP Error 429: Too Many Requests", ErrorCode.RATE_LIMITED),
    ("ERROR: [Instagram] x: Instagram sent an empty media response. Check if this post is accessible in your "
     "browser without being logged-in. If it is not, then use --cookies-from-browser", ErrorCode.AUTH_REQUIRED),
    ("Requested format is not available. Use --list-formats for a list of available formats", ErrorCode.FORMAT_UNAVAILABLE),
    ("ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location",
     ErrorCode.FFMPEG_MISSING),
    ("You have requested merging of multiple formats but ffmpeg is not installed", ErrorCode.FFMPEG_MISSING),
    ("ERROR: unable to download video data: [Errno 28] No space left on device", ErrorCode.STORAGE_FULL),
    ("<urlopen error [Errno 11001] getaddrinfo failed>", ErrorCode.NETWORK_TRANSIENT),
    ("ERROR: unable to download video data: The read operation timed out", ErrorCode.NETWORK_TRANSIENT),
    ("HTTP Error 503: Service Unavailable", ErrorCode.NETWORK_TRANSIENT),
    ("Unsupported URL: https://example.com/x", ErrorCode.UNSUPPORTED_PLATFORM),
    ("ERROR: [facebook] 123: Cannot parse data; please report this issue on https://github.com/yt-dlp/yt-dlp",
     ErrorCode.EXTRACTOR_BROKEN),
    ("ERROR: Postprocessing: Error merging formats: ffmpeg exited with code 1", ErrorCode.MERGE_FAILED),
    ("No supported JavaScript runtime could be found.", ErrorCode.JS_RUNTIME_MISSING),
    ("n challenge solving failed: Some formats may be missing", ErrorCode.JS_CHALLENGE_FAILED),
    ("HTTP Error 404: Not Found", ErrorCode.VIDEO_UNAVAILABLE),
])
def test_known_messages(message, expected):
    assert classify(message) == expected


def test_403_is_access_blocked_on_a_fresh_engine_and_engine_outdated_on_a_stale_one():
    message = "ERROR: unable to download video data: HTTP Error 403: Forbidden"
    assert classify(message, engine_stale=False) == ErrorCode.ACCESS_BLOCKED
    # we measured exactly this failure on a 100+ day old yt-dlp (docs/upgrade-audit.md)
    assert classify(message, engine_stale=True) == ErrorCode.ENGINE_OUTDATED


def test_extractor_breakage_is_engine_outdated_only_when_the_engine_is_stale():
    message = "Unable to extract player response; please report this issue"
    assert classify(message, engine_stale=False) == ErrorCode.EXTRACTOR_BROKEN
    assert classify(message, engine_stale=True) == ErrorCode.ENGINE_OUTDATED


def test_unknown_errors_are_not_blamed_on_the_library_or_the_video():
    assert classify("something nobody has seen before", phase="metadata") == ErrorCode.METADATA_FAILED
    assert classify("something nobody has seen before", phase="download") == ErrorCode.DOWNLOAD_FAILED


def test_exception_types():
    assert classify_exception(CancelledError()).code == ErrorCode.CANCELLED
    assert classify_exception(JobTimeoutError()).code == ErrorCode.TIMEOUT
    assert classify_exception(OSError(errno.ENOSPC, "No space left")).code == ErrorCode.STORAGE_FULL
    missing = FileNotFoundError(2, "No such file", "ffmpeg")
    assert classify_exception(missing).code == ErrorCode.FFMPEG_MISSING
    original = NamaoError(ErrorCode.FILE_TOO_LARGE)
    assert classify_exception(original) is original


def test_only_transient_failures_are_auto_retried():
    assert NamaoError(ErrorCode.NETWORK_TRANSIENT).auto_retryable
    assert NamaoError(ErrorCode.RATE_LIMITED).auto_retryable
    for permanent in (ErrorCode.VIDEO_UNAVAILABLE, ErrorCode.AUTH_REQUIRED, ErrorCode.GEO_RESTRICTED,
                      ErrorCode.FORMAT_UNAVAILABLE, ErrorCode.ENGINE_OUTDATED, ErrorCode.ACCESS_BLOCKED,
                      ErrorCode.FFMPEG_MISSING, ErrorCode.OUTPUT_INVALID, ErrorCode.UNSUPPORTED_PLATFORM):
        assert not NamaoError(permanent).auto_retryable, permanent


def test_every_code_has_a_user_message():
    for code in ErrorCode:
        assert NamaoError(code).message


def test_redact_removes_signed_urls_and_paths():
    text = ("unable to download https://rr3---sn.googlevideo.com/videoplayback?expire=1&sig=SECRET&key=k "
            "to C:\\Users\\bob\\data\\jobs\\abc\\media.mp4 and /srv/namao/data/jobs/abc/media.mp4")
    cleaned = redact(text)
    assert "SECRET" not in cleaned and "videoplayback" not in cleaned
    assert "bob" not in cleaned and "/srv/namao" not in cleaned
    assert "https://rr3---sn.googlevideo.com/…" in cleaned


def test_detail_is_single_line_and_bounded():
    detail = sanitize_detail("line one\nline two " + "x" * 1000)
    assert "\n" not in detail and len(detail) <= 240


def test_error_detail_never_contains_the_raw_signed_url():
    error = classify_exception(Exception("HTTP Error 403 for https://host.example/a?token=SECRET"))
    assert "SECRET" not in (error.detail or "")


@pytest.mark.parametrize("text, leaked", [
    ("fail https://user:tok@cdn.example.com/a/b?sig=ABC", "tok@"),
    ("fail https://user:tok@cdn.example.com/a/b?sig=ABC", "ABC"),
    ("see //cdn2.example/x?token=ZZZ", "ZZZ"),
    ("Authorization: Bearer abc.def.ghi", "abc.def"),
    ("cookie=SESSIONVALUE; other", "SESSIONVALUE"),
    ("api_key=hunter2&x=1", "hunter2"),
    (r"wrote C:\Users\bob smith\data\jobs\x.mp4 ok", "bob"),
    (r"wrote C:\Users\bob smith\data\jobs\x.mp4 ok", "jobs"),
    ("open /etc failed", "/etc"),
    ("open /srv/namao/data/x failed", "/srv"),
])
def test_redaction_gaps_found_in_review_are_closed(text, leaked):
    assert leaked not in redact(text)


def test_redaction_keeps_useful_context():
    cleaned = redact("HTTP Error 403 from https://rr3.googlevideo.com/videoplayback?sig=S for host")
    assert "https://rr3.googlevideo.com/…" in cleaned and "HTTP Error 403" in cleaned
    assert redact("and/or n/a http/1.1") == "and/or n/a http/1.1"
