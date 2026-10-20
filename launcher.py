"""Desktop entry point (Windows, macOS, Linux): the packaged Namao app.

Runs the same API + worker as the server deployment, in one process, bound to
loopback only, and opens the web UI in the default browser:

  * data (job database, temporary files, preferences) lives in the per-user app
    data directory, not next to the executable;
  * the worker is embedded (NAMAO_EMBEDDED_WORKER) so there is no second process;
  * desktop mode adds the output-folder features and DNS-rebinding protection;
  * FFmpeg / FFprobe / Deno are taken from a `bin/` folder shipped with the app
    when present, otherwise from PATH. Nothing is downloaded at run time.

    Namao.exe               start (or just open the UI if it is already running)
    Namao.exe --check       print dependency diagnostics as JSON and exit (0 = healthy)
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import sys
import threading
import time
import urllib.request
import webbrowser
from pathlib import Path

HOST = "127.0.0.1"
PREFERRED_PORT = 8000
APP_NAME = "Namao"


def app_data_dir() -> Path:
    if sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    elif sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return base / APP_NAME


def bundled_bin_dir() -> Path | None:
    """A `bin/` directory shipped inside the frozen app or next to it."""
    candidates = []
    if getattr(sys, "_MEIPASS", None):
        candidates.append(Path(sys._MEIPASS) / "bin")
    candidates.append(Path(sys.executable).resolve().parent / "bin")
    candidates.append(Path(__file__).resolve().parent / "bin")
    return next((c for c in candidates if c.is_dir()), None)


def find_free_port(preferred: int = PREFERRED_PORT) -> int:
    for port in (preferred, 0):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            try:
                probe.bind((HOST, port))
            except OSError:
                continue
            return probe.getsockname()[1]
    raise RuntimeError("no free local port available")


def namao_running_on(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://{HOST}:{port}/health/live", timeout=1.5) as response:
            return response.status == 200 and "version" in json.load(response)
    except (OSError, ValueError):
        return False


def load_or_create_token(data_dir: Path) -> str:
    """A secret kept in the user's own data folder; other accounts on the machine cannot read it."""
    path = data_dir / "desktop-token"
    try:
        existing = path.read_text(encoding="utf-8").strip()
        if len(existing) >= 20:
            return existing
    except OSError:
        pass
    data_dir.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(24)
    path.write_text(token, encoding="utf-8")
    if sys.platform != "win32":
        path.chmod(0o600)
    return token


def configure_environment(data_dir: Path | None) -> None:
    """Defaults for desktop use. Anything the user already exported wins."""
    defaults = {
        "NAMAO_DATA_DIR": str(data_dir or app_data_dir()),
        "NAMAO_EMBEDDED_WORKER": "1",
        "NAMAO_DESKTOP_MODE": "1",
        "NAMAO_LOG_LEVEL": "WARNING",
        "NAMAO_RATE_LIMIT_PER_MINUTE": "0",  # a local single user does not need request throttling
        "NAMAO_MAX_OPEN_JOBS_PER_CLIENT": "20",
    }
    bin_dir = bundled_bin_dir()
    if bin_dir:
        defaults["NAMAO_BIN_DIR"] = str(bin_dir)
    for key, value in defaults.items():
        os.environ.setdefault(key, value)
    os.environ.setdefault("NAMAO_DESKTOP_TOKEN", load_or_create_token(Path(os.environ["NAMAO_DATA_DIR"])))


def ui_url(port: int) -> str:
    """The address to open: carries the per-user token once; the server turns it into a cookie."""
    return f"http://{HOST}:{port}/?t={os.environ['NAMAO_DESKTOP_TOKEN']}"


def run_check() -> int:
    from namao.config import load_settings
    from namao.engine.ytdlp import YtDlpEngine

    settings = load_settings()
    settings.ensure_dirs()
    diagnostics = YtDlpEngine(settings).diagnostics()
    print(json.dumps({
        "ok": diagnostics.ok,
        "engine": diagnostics.engine,
        "version": diagnostics.version,
        "channel": diagnostics.channel,
        "tools": [{"name": t.name, "ok": t.ok, "version": t.version, "note": t.note} for t in diagnostics.tools],
        "problems": list(diagnostics.problems),
        "warnings": list(diagnostics.warnings),
    }, indent=2))
    return 0 if diagnostics.ok else 1


def open_browser_when_ready(port: int) -> None:
    for _ in range(100):
        if namao_running_on(port):
            webbrowser.open(ui_url(port))
            return
        time.sleep(0.2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog=APP_NAME)
    parser.add_argument("--check", action="store_true", help="print dependency diagnostics and exit")
    parser.add_argument("--no-browser", action="store_true", help="do not open the web UI")
    parser.add_argument("--port", type=int, default=PREFERRED_PORT)
    parser.add_argument("--data-dir", type=Path, default=None)
    args = parser.parse_args(argv)

    configure_environment(args.data_dir)
    if args.check:
        return run_check()

    if namao_running_on(args.port):  # single instance: just show the existing one
        if not args.no_browser:
            webbrowser.open(ui_url(args.port))
        print(f"{APP_NAME} is already running at http://{HOST}:{args.port}")
        return 0

    import uvicorn
    from namao.api.app import create_app

    port = find_free_port(args.port)
    app = create_app()  # after configure_environment(): settings are read here
    if not args.no_browser:
        threading.Thread(target=open_browser_when_ready, args=(port,), daemon=True).start()
    print(f"{APP_NAME} is running at http://{HOST}:{port}")
    print("Keep this window open while you use it. Close it to stop the app.")
    uvicorn.run(app, host=HOST, port=port, log_level="warning")
    return 0


if __name__ == "__main__":
    sys.exit(main())
