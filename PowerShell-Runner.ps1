param(
    [Parameter(Mandatory=$true)][string]$Controller,
    [Parameter(Mandatory=$true)][string]$Action
)


$ExpectedBuild = "v1.0.0"
$Folder = Split-Path -Parent $Controller
$BuildFile = Join-Path $Folder "BUILD-ID.txt"

if (-not (Test-Path -LiteralPath $BuildFile)) {
    Write-Host "ERROR: BUILD-ID.txt is missing." -ForegroundColor Red
    Write-Host "This folder is incomplete or mixed with another Local AI build." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 90
}

$DiskBuild = (Get-Content -LiteralPath $BuildFile -Raw).Trim()
if ($DiskBuild -ne $ExpectedBuild) {
    Write-Host "ERROR: Launcher build mismatch." -ForegroundColor Red
    Write-Host "Expected: $ExpectedBuild"
    Write-Host "Found:    $DiskBuild"
    Write-Host "Extract the ZIP into a brand-new folder." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 91
}

$controllerText = Get-Content -LiteralPath $Controller -Raw -ErrorAction SilentlyContinue
$expectedControllerBuild = '$LocalAIBuild = "' + $ExpectedBuild + '"'
if (-not $controllerText -or -not $controllerText.Contains($expectedControllerBuild)) {
    Write-Host "ERROR: LocalAI.ps1 is stale or from another build." -ForegroundColor Red
    Write-Host "Expected controller build: $ExpectedBuild"
    Write-Host "Extract Local AI v1 into a clean folder." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 92
}

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Local AI PowerShell - $Action"

Write-Host ""
Write-Host "================================================" -ForegroundColor DarkCyan
Write-Host "          LOCAL AI POWERSHELL CONSOLE" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "Build      : v1.0.0" -ForegroundColor Green
Write-Host "Action     : $Action"
Write-Host "Controller : $Controller"
Write-Host "PowerShell : $($PSVersionTable.PSVersion)"
Write-Host ""

if (-not (Test-Path -LiteralPath $Controller)) {
    Write-Host "ERROR: LocalAI.ps1 was not found." -ForegroundColor Red
    Write-Host $Controller
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 10
}

$pwsh = (Get-Process -Id $PID).Path

& $pwsh `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $Controller `
    $Action

$rc = $LASTEXITCODE

Write-Host ""
Write-Host "================================================" -ForegroundColor DarkCyan
if ($rc -eq 0) {
    Write-Host "Local AI action finished successfully. Exit: 0" -ForegroundColor Green
    if ($Action -eq "stop") {
        Write-Host ""
        Write-Host "Shutdown completed and passed verification." -ForegroundColor Green
    }
    if ($Action -eq "start") {
        Write-Host ""
        Write-Host "Keep the separate Ubuntu window open while using Open WebUI." -ForegroundColor Yellow
        Write-Host "Stop-Local-AI.bat will close the WSL runtime when you are done." -ForegroundColor DarkGray
    }
}
else {
    Write-Host "Local AI action failed. Exit: $rc" -ForegroundColor Red
}
Write-Host "================================================" -ForegroundColor DarkCyan
Write-Host ""

if ($rc -ne 0) {
    $logDir = Join-Path (Split-Path -Parent $Controller) "logs"
    Write-Host "Controller logs:" -ForegroundColor Yellow
    Write-Host "  $logDir"
    Write-Host ""
    Read-Host "Press Enter to close this PowerShell window"
    exit $rc
}

if ($Action -eq "stop") {
    Write-Host "Closing automatically in 2 seconds..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
    exit 0
}

Read-Host "Press Enter to close this PowerShell window"
exit $rc
