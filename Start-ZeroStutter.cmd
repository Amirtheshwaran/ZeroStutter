@echo off
if exist "%~dp0ZeroStutter.exe" (
    start "" "%~dp0ZeroStutter.exe"
    exit /b
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launch-ZeroStutter.ps1"
