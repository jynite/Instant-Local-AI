$ErrorActionPreference = "Stop"
$setup = Join-Path $PSScriptRoot "Setup-Local-AI.ps1"
Write-Host "Local AI v2 Repair"
& $setup -Repair
