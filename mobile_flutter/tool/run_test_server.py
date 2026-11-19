"""Start a REAL Namao server for verifying the Flutter app (no mocks anywhere).

What it does (same approach as tests/conftest.py + tests/test_pipeline_e2e.py):
  1. Generates a small synthetic DASH stream with the real FFmpeg (640x360 + 320x180 + AAC).
  2. Serves it on localhost (rights-free content, no internet needed).
  3. Starts the real FastAPI app with the embedded worker, so yt-dlp + FFmpeg + FFprobe run the
     whole pipeline. The test-only escapes (generic extractor, localhost host, private networks)
     are enabled ONLY in this script's environment, never in the app.

Usage (repo root, repo venv):
    ./venv/Scripts/python.exe mobile_flutter/tool/run_test_server.py [--port 8000] [--api-key KEY]

The DASH manifest URL to paste into the app is printed at startup.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def make_dash(root: Path, seconds: int) -> None:
    subprocess.run(
        [
            "ffmpeg", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=25:duration={seconds}",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
            "-filter_complex", "[0:v]split=2[a][b];[b]scale=320:180[c]",
            "-map", "[a]", "-map", "[c]", "-map", "1:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "25", "-keyint_min", "25",
            "-sc_threshold", "0", "-c:a", "aac", "-b:a", "64k",
            "-f", "dash", "-seg_duration", "1",
            "-adaptation_sets", "id=0,streams=0 id=1,streams=1 id=2,streams=2",
            "manifest.mpd",
        ],
        check=True,
        cwd=root,
    )


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # noqa: D401 - keep the console readable
        pass


class DualStack(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def start_media_server(root: Path) -> int:
    handler = functools.partial(QuietHandler, directory=str(root))
    try:
        server = DualStack(("::", 0), handler)
    except OSError:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--seconds", type=int, default=8, help="length of the synthetic video")
    parser.add_argument("--retention", type=int, default=600, help="seconds a finished file stays on the server")
    args = parser.parse_args()

    work = Path(tempfile.mkdtemp(prefix="namao_flutter_verify_"))
    dash_dir = work / "dash"
    dash_dir.mkdir()
    make_dash(dash_dir, args.seconds)
    media_port = start_media_server(dash_dir)

    env = {
        "NAMAO_DATA_DIR": str(work / "data"),
        "NAMAO_EMBEDDED_WORKER": "1",
        "NAMAO_ALLOW_PRIVATE_NETWORKS": "1",
        "NAMAO_EXTRA_ALLOWED_HOSTS": "localhost",
        "NAMAO_ALLOW_GENERIC_EXTRACTOR": "1",
        "NAMAO_MIN_FREE_MB": "1",
        "NAMAO_RETENTION_SECONDS": str(args.retention),
        "NAMAO_RATE_LIMIT_PER_MINUTE": "0",
        "NAMAO_READ_RATE_LIMIT_PER_MINUTE": "0",
    }
    if args.api_key:
        env["NAMAO_API_KEY"] = args.api_key
    os.environ.update(env)
    sys.path.insert(0, str(REPO_ROOT))

    print(f"DASH manifest: http://localhost:{media_port}/manifest.mpd", flush=True)
    print(f"Server: http://{args.host}:{args.port}  (emulator: http://10.0.2.2:{args.port})", flush=True)

    import uvicorn  # imported late so env vars are in place

    from namao.api.app import create_app

    uvicorn.run(create_app(), host=args.host, port=args.port, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
