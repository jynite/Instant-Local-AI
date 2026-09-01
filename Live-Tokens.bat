@echo off
setlocal EnableExtensions
title JYNERATION - Live Tokens
cd /d "%~dp0"
set "PS5=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do set "PWSH=%%I"
if not exist "%PWSH%" if exist "%PS5%" for /f "delims=" %%I in ('%PS5% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Pwsh.ps1"') do set "PWSH=%%I"
if not exist "%PWSH%" (
    echo PowerShell 7 is required. Run Setup-Local-AI.bat first.
    pause
    exit /b 10
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Local-AI.ps1" -Action livetokens
set "RC=%ERRORLEVEL%"
if not "%JYNERATION_NONINTERACTIVE%"=="1" if not "%RC%"=="0" pause
exit /b %RC%
