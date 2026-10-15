@echo off
rem Double-click to set up this PC for .NET + React development.
rem Re-launches itself as administrator, then runs setup-devbox.ps1 with its default settings.

fltmc >nul 2>&1 || (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-devbox.ps1" %*
echo.
pause
