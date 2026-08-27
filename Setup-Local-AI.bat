@echo off
setlocal EnableExtensions
title Local AI v2 Setup
cd /d "%~dp0"
set "PS5=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do set "PWSH=%%I"
if not exist "%PWSH%" if exist "%PS5%" for /f "delims=" %%I in ('%PS5% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Pwsh.ps1"') do set "PWSH=%%I"
if not exist "%PWSH%" (
    where winget.exe >nul 2>&1
    if errorlevel 1 (
        echo PowerShell 7 is missing and winget is unavailable.
        pause
        exit /b 11
    )
    echo Installing PowerShell 7...
    winget install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements
    if errorlevel 1 (
        echo PowerShell 7 installation failed.
        pause
        exit /b 12
    )
)
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do set "PWSH=%%I"
if not exist "%PWSH%" if exist "%PS5%" for /f "delims=" %%I in ('%PS5% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Find-Pwsh.ps1"') do set "PWSH=%%I"
if not exist "%PWSH%" (
    echo PowerShell 7 is installed but pwsh.exe could not be located.
    echo Open a new terminal and run Setup-Local-AI.bat again.
    pause
    exit /b 13
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0powershell\Setup-Local-AI.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="3010" echo Windows must restart. Run Setup-Local-AI.bat again afterward.
pause
exit /b %RC%
