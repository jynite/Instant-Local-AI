@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "EXPECTED=v2.0.0-beta.4.1-20260826"
if not exist "BUILD-ID.txt" (
    echo FAIL: BUILD-ID.txt missing.
    pause
    exit /b 1
)
set /p BUILD=<"BUILD-ID.txt"
if /I not "%BUILD%"=="%EXPECTED%" (
    echo FAIL: Build mismatch. Expected %EXPECTED%, found %BUILD%.
    pause
    exit /b 2
)
set "PS5=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS5%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\smoke\Test-Paths.ps1"
if errorlevel 1 (
    echo FAIL: Required file test failed.
    pause
    exit /b 3
)
"%PS5%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\smoke\Test-Static.ps1"
if errorlevel 1 (
    echo FAIL: Static smoke test failed.
    pause
    exit /b 4
)
"%PS5%" -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop; $root=(Resolve-Path '.').Path; $bad=@(); Get-Content '.\SHA256SUMS.txt' | ForEach-Object { if ($_ -match '^([0-9a-f]{64})  (.+)$') { $want=$matches[1]; $rel=$matches[2]; $p=Join-Path $root ($rel -replace '/','\'); if (!(Test-Path $p) -or (Get-FileHash -Algorithm SHA256 $p).Hash.ToLowerInvariant() -ne $want) { $bad += $rel } } }; if($bad.Count){Write-Host ('FAIL: checksum mismatch: '+($bad -join ', ')); exit 5}"
if errorlevel 1 (
    pause
    exit /b 5
)
echo PASS: JYNERATION beta 4.1 files are internally consistent.
pause
exit /b 0
