@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0QQUpdateLock.ps1" -Action on
echo.
pause
