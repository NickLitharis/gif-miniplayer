@echo off
rem Double-click launcher for GifMiniPlayer.ps1
rem Pass a GIF path as an argument, or just run it and pick one.
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0GifMiniPlayer.ps1" %*
