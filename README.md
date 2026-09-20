# নামাও (Namao)

A personal-use video downloader for YouTube, Facebook, TikTok, X (Twitter),
and Instagram. Paste a link, see the available qualities, click download.

All extraction is done by [yt-dlp](https://github.com/yt-dlp/yt-dlp) — this
project just gives it a UI.

## Requirements

- Windows 10
- Python 3.11+
- [ffmpeg](https://www.gyan.dev/ffmpeg/builds/) on your `PATH` (optional, but
  required for 1080p+ merged downloads and MP3 conversion — without it the
  app still works, just limited to progressive formats and M4A audio)

## Setup (Windows / PowerShell)

```powershell
# from the project folder
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --reload
```

Open **http://localhost:8000** in your browser.

## Windows .exe (no terminal needed)

Namao can also be packaged into a single `Namao.exe`. Double-clicking it
starts the server in the background and opens your browser automatically —
no venv, no typing commands.

To build it yourself (from an activated venv with `requirements.txt`
already installed):

```powershell
pip install pyinstaller
pyinstaller --onefile --name Namao --add-data "static;static" --collect-all yt_dlp --collect-data certifi launcher.py
```

The finished executable lands at `dist\Namao.exe`. Copy it anywhere (your
Desktop, a USB stick, another PC with no Python installed) and double-click
to run — the console window it opens shows the server log and must stay
open while you use the app; closing it stops the server. ffmpeg still needs
to be on the `PATH` of whichever machine runs it, same as the source version.

Once built, `Namao.spec` remembers these options, so future rebuilds (after
you change `main.py`, `launcher.py`, or `static/`) are just:

```powershell
pyinstaller Namao.spec
```

## Android app (standalone, no PC needed)

`android/` is a separate, standalone Android app — not a copy of the PC
version talking to a server. It bundles its own yt-dlp + ffmpeg (via the
[youtubedl-android](https://github.com/yausername/youtubedl-android) library)
and reuses the same frontend (`static/index.html`) in a WebView, wired to a
Kotlin bridge instead of the FastAPI routes. See `android/README.md` for the
full build steps and current status — building it requires an Android
SDK/Gradle toolchain, which this repo doesn't assume you have installed.

## How it works

```
 browser                          FastAPI (main.py)                yt-dlp
 ───────                          ─────────────────                ──────
 paste URL ──► POST /api/info ──► detect_platform()
                                   extract_info(url)          ───►  fetch page,
                                   build_qualities(formats)  ◄───   parse formats
              ◄── qualities JSON ──
 click "Download" ──► GET /api/download?url=&quality= ──►
                                   pick format string
                                   (merge w/ ffmpeg if needed) ───► download +
                                   serve largest file,        ◄───  merge/convert
                                   delete temp dir after
              ◄── file streamed to browser ──
```

Nothing is stored server-side beyond the lifetime of a single download —
each request gets its own temp folder, which is deleted right after the file
is sent to the browser.

## Troubleshooting

- **A specific video won't fetch / download**: platforms change their site
  frequently, and yt-dlp ships frequent fixes. Try:
  ```powershell
  pip install -U yt-dlp
  ```
- **"ffmpeg wasn't found" banner**: install ffmpeg and make sure `ffmpeg.exe`
  is on your `PATH` (test with `ffmpeg -version` in a new terminal), then
  restart the server.
- **1080p+ download looks tiny / video-only**: that means ffmpeg isn't
  available to merge the separate video and audio streams — install ffmpeg.

## Notes

Personal-use tool. Respect creators and each platform's terms of service —
don't use this to redistribute or pirate content.
