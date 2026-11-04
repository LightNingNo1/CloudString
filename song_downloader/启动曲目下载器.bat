@echo off
rem ============================================================
rem  CurMu Downloader launcher (portable, relative-path based)
rem  Place this file in the app root (song_downloader/).
rem  Works on any Windows x64 without installing node/electron,
rem  because node_modules is bundled inside this folder.
rem  (ASCII only to avoid codepage issues)
rem ============================================================
cd /d "%~dp0"

rem --- sanity checks (make errors visible) ---
if not exist "%~dp0node_modules\electron\dist\electron.exe" (
    echo [ERROR] electron.exe not found. node_modules missing or unzip incomplete.
    pause
    exit /b 1
)
if not exist "%~dp0package.json" (
    echo [ERROR] package.json not found. Are you in the app root song_downloader?
    pause
    exit /b 1
)

rem --- launch directly (NO 'start', to avoid quoted-arg mangling) ---
"%~dp0node_modules\electron\dist\electron.exe" "%~dp0."