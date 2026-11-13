@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0QQUpdateLock.ps1" -Action status
echo.
pause
