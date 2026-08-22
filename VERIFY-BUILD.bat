@echo off
setlocal EnableExtensions
title Verify Local AI v1
cd /d "%~dp0"

set "EXPECTED_BUILD=v1.0.0"

echo ==========================================
echo       LOCAL AI BUILD VERIFICATION
echo ==========================================
echo.
echo Expected build:
echo   %EXPECTED_BUILD%
echo.

if not exist "BUILD-ID.txt" (
    echo FAIL: BUILD-ID.txt missing.
    pause
    exit /b 1
)

set /p "BUILD="<"BUILD-ID.txt"
echo Folder build:
echo   %BUILD%
echo.

if /I not "%BUILD%"=="%EXPECTED_BUILD%" (
    echo FAIL: Build ID mismatch.
    pause
    exit /b 2
)

if not exist "LocalAI.ps1" (
    echo FAIL: LocalAI.ps1 missing.
    pause
    exit /b 3
)

if not exist "PowerShell-Runner.ps1" (
    echo FAIL: PowerShell-Runner.ps1 missing.
    pause
    exit /b 4
)

powershell.exe -NoLogo -NoProfile -NonInteractive -Command ^
  "$c=Get-Content -LiteralPath '.\LocalAI.ps1' -Raw; $m='$LocalAIBuild = ""%EXPECTED_BUILD%""'; if(-not $c.Contains($m)){exit 11}"
if errorlevel 1 (
    echo FAIL: LocalAI.ps1 build mismatch.
    pause
    exit /b 5
)

powershell.exe -NoLogo -NoProfile -NonInteractive -Command ^
  "$c=Get-Content -LiteralPath '.\PowerShell-Runner.ps1' -Raw; $m='$ExpectedBuild = ""%EXPECTED_BUILD%""'; if(-not $c.Contains($m)){exit 12}"
if errorlevel 1 (
    echo FAIL: PowerShell-Runner.ps1 build mismatch.
    pause
    exit /b 6
)

powershell.exe -NoLogo -NoProfile -NonInteractive -Command ^
  "$c=Get-Content -LiteralPath '.\LocalAI.ps1' -Raw; if($c.Contains('$SECONDS')){exit 13}; if($c.Contains('Get-Command wt.exe')){exit 14}"
if errorlevel 1 (
    echo FAIL: Old launcher code was detected.
    pause
    exit /b 7
)

echo PASS: Local AI v1 files match.
echo PASS: No old SECONDS startup loop.
echo PASS: No wt.exe Ubuntu runtime launcher.
echo.
echo You can run Install-Local-AI.bat now.
echo.
pause
exit /b 0
