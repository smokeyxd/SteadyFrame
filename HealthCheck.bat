@echo off
rem Read-only health check: changes nothing. Report is saved under runs\.
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights for the full check...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteadyFrame.ps1" -DiagnoseOnly
echo.
pause
