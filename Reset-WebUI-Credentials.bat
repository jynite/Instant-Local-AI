@echo off
rem SPDX-FileCopyrightText: Copyright (c) 2026 saj
rem SPDX-License-Identifier: MIT
setlocal EnableExtensions
title JYNERATION - Reset Open WebUI Login
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
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Local-AI.ps1" -Action resetwebuicredentials
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
    echo Credential recovery finished.
) else (
    echo Credential recovery failed with exit code %RC%.
)
if not "%JYNERATION_NONINTERACTIVE%"=="1" pause
exit /b %RC%
