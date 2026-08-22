@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Local AI Bootstrap

set "SCRIPT_DIR=%~dp0"
set "CONTROLLER=%SCRIPT_DIR%LocalAI.ps1"
set "RUNNER=%SCRIPT_DIR%PowerShell-Runner.ps1"
set "TOOLS=%SCRIPT_DIR%local-ai-tools.py"
set "BOOTLOG=%SCRIPT_DIR%bootstrap.log"
set "PWSH="

set "EXPECTED_BUILD=v1.0.0"
set "BUILD_FILE=%SCRIPT_DIR%BUILD-ID.txt"

if not exist "%BUILD_FILE%" (
    echo ERROR: BUILD-ID.txt is missing.
    echo This folder is incomplete or mixed with an older Local AI build.
    echo Extract the new ZIP into a BRAND-NEW folder.
    pause
    exit /b 20
)

set /p "ACTUAL_BUILD="<"%BUILD_FILE%"
if /I not "%ACTUAL_BUILD%"=="%EXPECTED_BUILD%" (
    echo ERROR: Local AI build mismatch.
    echo Expected: %EXPECTED_BUILD%
    echo Found:    %ACTUAL_BUILD%
    echo.
    echo Extract the new ZIP into a BRAND-NEW folder.
    pause
    exit /b 21
)


>>"%BOOTLOG%" echo.
>>"%BOOTLOG%" echo ============================================================
>>"%BOOTLOG%" echo [%DATE% %TIME%] Bootstrap action: health
>>"%BOOTLOG%" echo Script dir: %SCRIPT_DIR%

echo Local AI bootstrap
echo Action: health
echo.

if not exist "%CONTROLLER%" (
    echo ERROR: LocalAI.ps1 is missing.
    echo Extract the ENTIRE ZIP into one folder first.
    >>"%BOOTLOG%" echo ERROR: LocalAI.ps1 missing.
    pause
    exit /b 10
)

if not exist "%RUNNER%" (
    echo ERROR: PowerShell-Runner.ps1 is missing.
    echo Extract the ENTIRE ZIP into one folder first.
    >>"%BOOTLOG%" echo ERROR: PowerShell-Runner.ps1 missing.
    pause
    exit /b 11
)

if not exist "%TOOLS%" (
    echo ERROR: local-ai-tools.py is missing.
    echo Extract the ENTIRE ZIP into one folder first.
    >>"%BOOTLOG%" echo ERROR: local-ai-tools.py missing.
    pause
    exit /b 12
)

if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
)

if not defined PWSH (
    for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do (
        if not defined PWSH set "PWSH=%%I"
    )
)

if not defined PWSH (
    where winget.exe >nul 2>&1
    if errorlevel 1 (
        echo ERROR: PowerShell 7 is required and winget is unavailable.
        >>"%BOOTLOG%" echo ERROR: PowerShell 7 and winget unavailable.
        pause
        exit /b 13
    )

    echo PowerShell 7 was not found. Installing it...
    winget install --id Microsoft.PowerShell --exact --source winget --accept-package-agreements --accept-source-agreements
    if errorlevel 1 (
        echo ERROR: PowerShell 7 installation failed.
        >>"%BOOTLOG%" echo ERROR: PowerShell install failed.
        pause
        exit /b 14
    )

    set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
)

if not exist "%PWSH%" (
    echo ERROR: pwsh.exe still could not be located.
    >>"%BOOTLOG%" echo ERROR: pwsh unresolved.
    pause
    exit /b 15
)

>>"%BOOTLOG%" echo PowerShell: %PWSH%
>>"%BOOTLOG%" echo Runner: %RUNNER%
>>"%BOOTLOG%" echo Controller: %CONTROLLER%

start "Local AI PowerShell" "%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RUNNER%" -Controller "%CONTROLLER%" -Action health

if errorlevel 1 (
    echo ERROR: Could not launch the separate PowerShell console.
    >>"%BOOTLOG%" echo ERROR: start command failed.
    pause
    exit /b 16
)

exit /b 0
