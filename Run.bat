@echo off
rem SteadyFrame launcher: asks for admin rights, then starts the interactive menu.
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
rem Files copied from a zip/Discord carry a "downloaded from the internet" mark; clear it for this folder only.
powershell -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File | Unblock-File" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteadyFrame.ps1"
echo.
pause
