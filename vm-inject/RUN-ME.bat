@echo off
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0guest-selftest.ps1"
pause
