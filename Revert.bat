@echo off
rem Undo SteadyFrame changes from a previous run (uses the run's journal).
setlocal
cd /d "%~dp0"
if not exist "%~dp0lib\SteadyFrame.psm1" goto notextracted
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    rem the path goes through an environment variable so an apostrophe in it can't break the command
    set "SF_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:SF_SELF -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteadyFrame.ps1" -Revert
echo.
pause
exit /b

:notextracted
echo.
echo   SteadyFrame can't find its other files.
echo   If you opened it straight from the zip: right-click the zip, choose Extract All,
echo   then open this file again from the extracted folder.
echo.
pause
exit /b 1
