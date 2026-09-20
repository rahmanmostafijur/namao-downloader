"""
Double-click entry point for the packaged Namao.exe.

`uvicorn main:app --reload` (the dev workflow) isn't appropriate for a frozen
executable — the reload feature re-spawns a subprocess that expects a live
main.py on disk, which doesn't exist once everything is bundled. This runs
the same app directly, in-process, and opens the browser once it's ready.
"""

import threading
import time
import webbrowser

import uvicorn

from main import app

HOST = "127.0.0.1"
PORT = 8000


def open_browser_when_ready():
    time.sleep(1.5)
    webbrowser.open(f"http://{HOST}:{PORT}")


if __name__ == "__main__":
    threading.Thread(target=open_browser_when_ready, daemon=True).start()
    print(f"Namao is running at http://{HOST}:{PORT}")
    print("Keep this window open while you use it. Close it to stop the app.")
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
