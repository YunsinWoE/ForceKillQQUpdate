@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0QQUpdateLock.ps1" -Action off -Backstop acl
echo.
pause
