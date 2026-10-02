@echo off
rem SteadyFrame launcher: asks for admin rights, then starts the interactive menu.
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
rem Files copied from a zip/Discord carry a "downloaded from the internet" mark; clear it for this folder only.
set "SF_DIR=%~dp0"
powershell -NoProfile -Command "Get-ChildItem -LiteralPath $env:SF_DIR -Recurse -File | Unblock-File" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SteadyFrame.ps1"
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
