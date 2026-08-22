@echo off
setlocal EnableExtensions
title Local AI Live Logs
set "CONTROLLER=%~dp0LocalAI.ps1"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%I"
)
if not defined PWSH (
    echo PowerShell 7 not found.
    pause
    exit /b 1
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CONTROLLER%" logs
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
