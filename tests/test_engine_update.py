"""Pin management logic (no network)."""

import importlib.util
import sys
from datetime import date
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "engine_update.py"
spec = importlib.util.spec_from_file_location("engine_update", SCRIPT)
engine_update = importlib.util.module_from_spec(spec)
sys.modules["engine_update"] = engine_update
spec.loader.exec_module(engine_update)

REQUIREMENTS = """fastapi==0.139.0
# comment
yt-dlp[default]==2026.8.19
yt-dlp-ejs==0.8.0
"""


def release(upload, yanked=False):
    return [{"upload_time_iso_8601": upload, "yanked": yanked}]


def test_latest_is_chosen_per_channel_by_upload_time_and_skips_yanked():
    releases = {
        "2026.8.19": release("2026-08-19T10:00:00Z"),
        "2026.7.4": release("2026-07-04T10:00:00Z"),
        "2026.10.10.233141.dev0": release("2026-10-10T23:31:41Z"),
        "2026.10.17.1.dev0": release("2026-10-17T01:00:00Z", yanked=True),
        "2026.9.27.232945.dev0": release("2026-09-27T23:29:45Z"),
        "empty": [],
    }
    assert engine_update.pick_latest(releases, "stable") == "2026.8.19"
    assert engine_update.pick_latest(releases, "nightly") == "2026.10.10.233141.dev0"
    assert engine_update.pick_latest({}, "stable") is None


def test_ejs_pin_is_read_from_the_release_metadata():
    requires = ["brotli; extra == 'default'", "yt-dlp-ejs==0.8.0; extra == 'default'", "requests"]
    assert engine_update.ejs_requirement(requires) == "0.8.0"
    assert engine_update.ejs_requirement(["requests"]) is None and engine_update.ejs_requirement(None) is None


def test_pins_round_trip_without_touching_other_lines():
    assert engine_update.read_pins(REQUIREMENTS) == ("2026.8.19", "0.8.0")
    updated = engine_update.rewrite_pins(REQUIREMENTS, "2026.10.10.233141.dev0", "0.9.0")
    assert engine_update.read_pins(updated) == ("2026.10.10.233141.dev0", "0.9.0")
    assert "fastapi==0.139.0" in updated and "# comment" in updated


def test_files_without_exact_pins_are_refused():
    with pytest.raises(ValueError):
        engine_update.rewrite_pins("yt-dlp\nfastapi\n", "1", "2")
    with pytest.raises(ValueError):
        engine_update.read_pins("yt-dlp[default]>=2026.1.1\nyt-dlp-ejs==0.8.0\n")


def test_version_age_and_channel():
    assert engine_update.version_age_days("2026.8.19", today=date(2026, 10, 20)) == 62
    assert engine_update.version_age_days("2026.10.10.233141.dev0", today=date(2026, 10, 20)) == 10
    assert engine_update.version_age_days("not-a-date") is None
    assert engine_update.is_nightly("2026.10.10.233141.dev0") and not engine_update.is_nightly("2026.8.19")


def test_promote_saves_the_previous_pins_and_rollback_restores_them(tmp_path, monkeypatch):
    requirements, known_good = tmp_path / "requirements.txt", tmp_path / "requirements-known-good.txt"
    requirements.write_text(REQUIREMENTS, encoding="utf-8")
    monkeypatch.setattr(engine_update, "REQUIREMENTS", requirements)
    monkeypatch.setattr(engine_update, "KNOWN_GOOD", known_good)
    monkeypatch.setattr(engine_update, "describe_release",
                        lambda version: {"version": version, "ejs": "0.9.0", "channel": "nightly", "age_days": 1})

    args = type("A", (), {"version": "2026.10.10.233141.dev0"})()
    assert engine_update.cmd_promote(args) == 0
    assert engine_update.read_pins(requirements.read_text()) == ("2026.10.10.233141.dev0", "0.9.0")
    assert engine_update.read_pins(known_good.read_text()) == ("2026.8.19", "0.8.0")

    assert engine_update.cmd_rollback(None) == 0
    assert engine_update.read_pins(requirements.read_text()) == ("2026.8.19", "0.8.0")
    assert engine_update.cmd_promote(type("A", (), {"version": "2026.8.19"})()) == 0  # already pinned: no-op


def test_version_strings_must_look_like_versions(monkeypatch):
    for bad in ("1.0\1", "../x", "1.0; rm -rf /", "", "v1", "1 .0"):
        with pytest.raises(ValueError):
            engine_update.describe_release(bad)


def test_only_pypi_https_urls_are_fetched():
    with pytest.raises(ValueError):
        engine_update.fetch_json("http://pypi.org/pypi/yt-dlp/json")
    with pytest.raises(ValueError):
        engine_update.fetch_json("https://evil.example/pypi/yt-dlp/json")


def test_the_repository_pins_are_exact_and_consistent():
    root = Path(__file__).resolve().parents[1]
    ytdlp, ejs = engine_update.read_pins((root / "requirements.txt").read_text())
    good_ytdlp, good_ejs = engine_update.read_pins((root / "requirements-known-good.txt").read_text())
    assert ytdlp and ejs and good_ytdlp and good_ejs
    import os
    if os.environ.get("NAMAO_ENGINE_CANDIDATE") == "1":
        pytest.skip("candidate environment intentionally differs from the pin")
    from importlib.metadata import version
    assert version("yt-dlp") == ytdlp, "installed yt-dlp must equal the pin in requirements.txt"
    assert version("yt-dlp-ejs") == ejs
