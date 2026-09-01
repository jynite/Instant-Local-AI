# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
$ErrorActionPreference = "SilentlyContinue"

$candidates = New-Object System.Collections.Generic.List[string]

function Add-Candidate {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $resolved = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $Path }
    if (-not $candidates.Contains($resolved)) { $candidates.Add($resolved) }
}

function Test-Python {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $version = (& $Path -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2>$null | Select-Object -First 1).Trim()
        if ($version -notmatch '^\d+\.\d+$') { return $false }
        $parts = $version.Split('.')
        return ([int]$parts[0] -gt 3) -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10)
    } catch { return $false }
}

$command = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($command -and $command.Source -and $command.Source -notmatch '\\WindowsApps\\') { Add-Candidate $command.Source }

$launcher = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($launcher -and $launcher.Source) {
    $resolved = & $launcher.Source -3 -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1
    if ($resolved) { Add-Candidate ([string]$resolved).Trim() }
}

foreach ($root in @($env:LocalAppData, $env:ProgramFiles, ${env:ProgramFiles(x86)}, ${env:ProgramW6432})) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    foreach ($base in @((Join-Path $root 'Programs\Python'), $root)) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Python*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            Add-Candidate (Join-Path $directory.FullName 'python.exe')
        }
    }
}

foreach ($candidate in $candidates) {
    if (Test-Python $candidate) {
        $pythonw = Join-Path (Split-Path -Parent $candidate) 'pythonw.exe'
        if (Test-Path -LiteralPath $pythonw -PathType Leaf) {
            Write-Output $candidate
            exit 0
        }
    }
}

exit 1
