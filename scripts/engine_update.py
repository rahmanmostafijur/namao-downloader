#!/usr/bin/env python3
"""Manage the pinned yt-dlp / yt-dlp-ejs versions.

Policy (docs/download-reliability.md): production only ever runs an *exact*,
tested pin. Upstream recommends nightly builds for regular users, so a nightly
is the default candidate, but it is installed in an isolated virtualenv and must
pass the regression suite (including the live smoke tests) before it is
promoted. The previous pin is kept in requirements-known-good.txt for rollback.

    python scripts/engine_update.py check
    python scripts/engine_update.py candidate --channel nightly --venv .candidate-venv
    python scripts/engine_update.py promote --version 2026.10.10.233141.dev0
    python scripts/engine_update.py rollback

Nothing here installs anything into the running environment, and nothing runs
while jobs are active: deploy with `python -m namao.ops drain` (see docs/deployment.md).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIREMENTS = ROOT / "requirements.txt"
KNOWN_GOOD = ROOT / "requirements-known-good.txt"
PYPI_PROJECT = "https://pypi.org/pypi/{name}/json"
PYPI_RELEASE = "https://pypi.org/pypi/{name}/{version}/json"

_YTDLP_PIN = re.compile(r"^yt-dlp\[default\]==(?P<v>[\w.]+)\s*$", re.MULTILINE)
_EJS_PIN = re.compile(r"^yt-dlp-ejs==(?P<v>[\w.]+)\s*$", re.MULTILINE)
_EJS_REQUIRES = re.compile(r"^yt-dlp-ejs\s*==\s*(?P<v>[\w.]+)")
_DATE_PREFIX = re.compile(r"^(\d{4})\.(\d{1,2})\.(\d{1,2})")


# ------------------------------------------------------------------ pure logic

def is_nightly(version: str) -> bool:
    return ".dev" in version


def version_age_days(version: str, today: date | None = None) -> int | None:
    match = _DATE_PREFIX.match(version)
    if not match:
        return None
    released = date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return ((today or date.today()) - released).days


def pick_latest(releases: dict[str, list[dict]], channel: str) -> str | None:
    """Newest non-yanked release of a channel ("stable" or "nightly") by upload time."""
    best: tuple[str, str] | None = None
    for version, files in releases.items():
        if not files or all(f.get("yanked") for f in files):
            continue
        if is_nightly(version) != (channel == "nightly"):
            continue
        uploaded = max(f.get("upload_time_iso_8601", "") for f in files)
        if best is None or uploaded > best[0]:
            best = (uploaded, version)
    return best[1] if best else None


def ejs_requirement(requires_dist: list[str] | None) -> str | None:
    """The exact yt-dlp-ejs version a yt-dlp release declares (it pins it exactly)."""
    for requirement in requires_dist or []:
        match = _EJS_REQUIRES.match(requirement)
        if match:
            return match.group("v")
    return None


def read_pins(text: str) -> tuple[str, str]:
    ytdlp, ejs = _YTDLP_PIN.search(text), _EJS_PIN.search(text)
    if not ytdlp or not ejs:
        raise ValueError("requirements file must contain exact yt-dlp[default]== and yt-dlp-ejs== pins")
    return ytdlp.group("v"), ejs.group("v")


def rewrite_pins(text: str, ytdlp_version: str, ejs_version: str) -> str:
    read_pins(text)  # refuse to touch a file without the expected pins
    text = _YTDLP_PIN.sub(f"yt-dlp[default]=={ytdlp_version}", text, count=1)
    return _EJS_PIN.sub(f"yt-dlp-ejs=={ejs_version}", text, count=1)


def known_good_text(ytdlp_version: str, ejs_version: str, today: date | None = None) -> str:
    return (
        "# Last promoted-and-tested engine pins. Restore with: python scripts/engine_update.py rollback\n"
        f"# Recorded {(today or date.today()).isoformat()}\n"
        f"yt-dlp[default]=={ytdlp_version}\n"
        f"yt-dlp-ejs=={ejs_version}\n"
    )


# --------------------------------------------------------------------- network

def fetch_json(url: str) -> dict:
    if not url.startswith("https://pypi.org/"):
        raise ValueError("refusing to fetch a non-PyPI URL")
    with urllib.request.urlopen(url, timeout=30) as response:  # noqa: S310 - fixed https host
        return json.load(response)


def describe_release(version: str) -> dict:
    data = fetch_json(PYPI_RELEASE.format(name="yt-dlp", version=version))
    ejs = ejs_requirement(data["info"].get("requires_dist"))
    if ejs is None:
        raise RuntimeError(f"yt-dlp {version} declares no yt-dlp-ejs requirement; cannot build a consistent pin")
    return {"version": version, "ejs": ejs, "channel": "nightly" if is_nightly(version) else "stable",
            "age_days": version_age_days(version)}


# -------------------------------------------------------------------- commands

def cmd_check(_args) -> int:
    pinned, pinned_ejs = read_pins(REQUIREMENTS.read_text(encoding="utf-8"))
    releases = fetch_json(PYPI_PROJECT.format(name="yt-dlp"))["releases"]
    report = {
        "pinned": {"version": pinned, "ejs": pinned_ejs, "age_days": version_age_days(pinned)},
        "latest_stable": pick_latest(releases, "stable"),
        "latest_nightly": pick_latest(releases, "nightly"),
        "known_good": read_pins(KNOWN_GOOD.read_text(encoding="utf-8"))[0] if KNOWN_GOOD.exists() else None,
    }
    print(json.dumps(report, indent=2))
    return 0


def cmd_candidate(args) -> int:
    releases = fetch_json(PYPI_PROJECT.format(name="yt-dlp"))["releases"]
    version = args.version or pick_latest(releases, args.channel)
    if not version:
        print(f"no {args.channel} release found", file=sys.stderr)
        return 1
    info = describe_release(version)
    venv = Path(args.venv).resolve()
    subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    python = venv / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    subprocess.run(
        [str(python), "-m", "pip", "install", "--quiet", "-r", str(ROOT / "requirements-dev.txt")],
        check=True,
    )
    # Override just the engine pins inside the otherwise identical environment.
    subprocess.run(
        [str(python), "-m", "pip", "install", "--quiet",
         f"yt-dlp[default]=={info['version']}", f"yt-dlp-ejs=={info['ejs']}"],
        check=True,
    )
    print(json.dumps({**info, "python": str(python)}, indent=2))
    return 0


def cmd_promote(args) -> int:
    info = describe_release(args.version)
    current = REQUIREMENTS.read_text(encoding="utf-8")
    current_ytdlp, current_ejs = read_pins(current)
    if current_ytdlp == info["version"]:
        print(f"already pinned to {current_ytdlp}")
        return 0
    KNOWN_GOOD.write_text(known_good_text(current_ytdlp, current_ejs), encoding="utf-8")
    REQUIREMENTS.write_text(rewrite_pins(current, info["version"], info["ejs"]), encoding="utf-8")
    print(f"promoted yt-dlp {current_ytdlp} -> {info['version']} (ejs {current_ejs} -> {info['ejs']}); "
          f"previous pins saved to {KNOWN_GOOD.name}")
    return 0


def cmd_rollback(_args) -> int:
    if not KNOWN_GOOD.exists():
        print("no known-good pins recorded", file=sys.stderr)
        return 1
    good_ytdlp, good_ejs = read_pins(KNOWN_GOOD.read_text(encoding="utf-8"))
    REQUIREMENTS.write_text(rewrite_pins(REQUIREMENTS.read_text(encoding="utf-8"), good_ytdlp, good_ejs),
                            encoding="utf-8")
    print(f"rolled back to yt-dlp {good_ytdlp} / yt-dlp-ejs {good_ejs}; rebuild the image and redeploy")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="compare the pin with the latest stable and nightly releases")
    candidate = sub.add_parser("candidate", help="install a candidate engine into an isolated virtualenv")
    candidate.add_argument("--channel", choices=["stable", "nightly"], default="nightly")
    candidate.add_argument("--version", help="exact version instead of the latest of the channel")
    candidate.add_argument("--venv", default=".candidate-venv")
    promote = sub.add_parser("promote", help="pin a tested version (saves the old pins as known-good)")
    promote.add_argument("--version", required=True)
    sub.add_parser("rollback", help="restore the known-good pins")
    args = parser.parse_args(argv)
    return {"check": cmd_check, "candidate": cmd_candidate, "promote": cmd_promote,
            "rollback": cmd_rollback}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
