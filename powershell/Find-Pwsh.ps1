$ErrorActionPreference = "SilentlyContinue"

$candidates = New-Object System.Collections.Generic.List[string]

function Add-Candidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not $candidates.Contains($Path)) { $candidates.Add($Path) }
}

if ($env:ProgramFiles) { Add-Candidate (Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe") }
if (${env:ProgramW6432}) { Add-Candidate (Join-Path ${env:ProgramW6432} "PowerShell\7\pwsh.exe") }
if ($env:LOCALAPPDATA) { Add-Candidate (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\pwsh.exe") }
if ($env:USERPROFILE) { Add-Candidate (Join-Path $env:USERPROFILE ".dotnet\tools\pwsh.exe") }

$command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($command -and $command.Source) { Add-Candidate $command.Source }

foreach ($key in @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe"
)) {
    $item = Get-Item $key -ErrorAction SilentlyContinue
    if ($item) { Add-Candidate ([string]$item.GetValue("")) }
}

$appx = Get-AppxPackage -Name "Microsoft.PowerShell*" -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($appx -and $appx.InstallLocation) {
    Add-Candidate (Join-Path $appx.InstallLocation "pwsh.exe")
}

foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        Write-Output $candidate
        exit 0
    }
}

exit 1
