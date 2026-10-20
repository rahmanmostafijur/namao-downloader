# -*- mode: python ; coding: utf-8 -*-
# Build (from a venv with requirements-desktop.txt installed), on each target OS:
#     pyinstaller Namao.spec            ->  dist/Namao[.exe]
# Optional: put ffmpeg, ffprobe and deno in ./desktop-bin/ before building to ship them inside
# the app (they are then used instead of whatever is on PATH). Download them from their
# official release pages and verify checksums yourself; the build never fetches anything.
import os

from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules

datas = [('static', 'static')]
binaries = []
hiddenimports = collect_submodules('uvicorn') + collect_submodules('namao')

# yt_dlp_ejs ships the JavaScript challenge solver as *data files*; without it YouTube
# extraction degrades in the packaged app even though the Python import succeeds.
for package in ('yt_dlp', 'yt_dlp_ejs'):
    package_datas, package_binaries, package_imports = collect_all(package)
    datas += package_datas
    binaries += package_binaries
    hiddenimports += package_imports
datas += collect_data_files('certifi')

if os.path.isdir('desktop-bin'):
    datas += [('desktop-bin', 'bin')]

a = Analysis(
    ['launcher.py'],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tests', 'pytest'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='Namao',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,  # UPX-packed executables trip antivirus heuristics
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,  # the console shows the log and closing it stops the app
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
