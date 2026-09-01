# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $Root "config\local.json"
$installStatePath = Join-Path $Root "state\install.json"
$sessionStatePath = Join-Path $Root "state\session.json"
if (-not (Test-Path $configPath)) { throw "Run Setup-Local-AI.bat first." }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$installState = if (Test-Path $installStatePath) { Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json } else { $null }
$sessionState = if (Test-Path $sessionStatePath) { try { Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json } catch { $null } } else { $null }
$distro = [string]$config.distro
$repoWsl = (& wsl.exe -d $distro -- wslpath -u $Root | Select-Object -First 1).Trim()
$repo64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($repoWsl))

function User {
    param([string]$Command)
    & wsl.exe -d $distro -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu command failed." }
}

function Root {
    param([string]$Command)
    & wsl.exe -d $distro -u root -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu root command failed." }
}

function Capture {
    param([string]$Command,[switch]$AsRoot)
    $out = if ($AsRoot) { & wsl.exe -d $distro -u root -- bash -lc $Command 2>$null } else { & wsl.exe -d $distro -- bash -lc $Command 2>$null }
    if ($LASTEXITCODE -ne 0) { return "" }
    return (($out | Out-String).Trim())
}

function Get-ManagedPiPids {
    if ($null -eq $sessionState) { return @() }
    $sessionId = [string]$sessionState.session_id
    if ($sessionId -notmatch '^[A-Za-z0-9-]+$') { return @() }
    $script = @'
for p in /proc/[0-9]*; do
  [ -r "$p/environ" ] || continue
  if tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -Fxq 'LOCAL_AI_SESSION_ID=__SESSION__'; then
    basename "$p"
  fi
done
'@
    $script = $script.Replace("__SESSION__",$sessionId)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $rows = & wsl.exe -d $distro -- bash -lc "printf %s '$encoded' | base64 -d | bash" 2>$null
    return @($rows | ForEach-Object { ($_ -as [string]).Trim() } | Where-Object { $_ -match '^\d+$' })
}

if ((Get-ManagedPiPids).Count -gt 0) { throw "A Local AI-managed Pi session is active. Exit or stop that session before updating its runtime." }

$manageWeb = [bool]$config.components.open_webui
$webOwned = $installState -and [bool]$installState.open_webui_created_by_local_ai
$piOwned = $installState -and [bool]$installState.pi_installed_by_local_ai
$ollamaOwned = $installState -and [bool]$installState.ollama_installed_by_local_ai
$webWasActive = $false
if ($manageWeb) { $webWasActive = (Capture "systemctl is-active open-webui.service 2>/dev/null || true" -AsRoot) -eq "active" }
$ollamaWasActive = (Capture "systemctl is-active ollama.service 2>/dev/null || true" -AsRoot) -eq "active"
$failure = $null

try {
    if ($webWasActive) { Root "systemctl stop open-webui.service" }
    if ($ollamaWasActive) { Root "systemctl stop ollama.service" }

    if ($manageWeb -and $webOwned) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        User "if [ -d ~/.open-webui ]; then cp -a ~/.open-webui ~/.open-webui.backup-$stamp; fi"
        Write-Host "Updating Local AI-owned Open WebUI..."
        User 'export PATH="$HOME/.local/bin:$PATH"; uv tool upgrade open-webui || uv tool install --python 3.11 open-webui'
    } elseif ($manageWeb) {
        Write-Host "Preserving pre-existing Open WebUI package/service. Local AI does not own it."
    }

    if ([bool]$config.components.pi) {
        if ($piOwned) {
            Write-Host "Updating Local AI's private Pi runtime..."
            User 'mkdir -p "$HOME/.local/share/local-ai/pi-runtime"; npm install --prefix "$HOME/.local/share/local-ai/pi-runtime" --ignore-scripts @earendil-works/pi-coding-agent@latest'
        } else {
            Write-Host "Preserving pre-existing Pi package. Local AI does not own it."
        }
        $copy = @'
set -e
repo=$(printf %s '__REPO__' | base64 -d)
agent_dir="$HOME/.local/share/local-ai/pi-agent"
mkdir -p "$agent_dir/extensions" "$agent_dir/sessions"
cp "$repo/extension/local-ai.ts" "$agent_dir/extensions/local-ai.ts"
'@
        $copy = $copy.Replace("__REPO__",$repo64)
        $copy64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($copy))
        User "printf %s '$copy64' | base64 -d | bash"
    }

    if ($ollamaOwned) {
        Write-Host "Updating Local AI-owned Ollama..."
        Root "curl -fsSL https://ollama.com/install.sh | sh"
    } else {
        Write-Host "Preserving pre-existing Ollama binary. Local AI will keep managing its integration/context override only."
    }
    Root "systemctl daemon-reload"

    $helper = @'
set -e
repo=$(printf %s '__REPO__' | base64 -d)
mkdir -p ~/.local/bin
install -m 755 "$repo/wsl/local-ai-tools.py" ~/.local/bin/local-ai-tools.py
'@
    $helper = $helper.Replace("__REPO__",$repo64)
    $helper64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($helper))
    User "printf %s '$helper64' | base64 -d | bash"
} catch {
    $failure = $_
} finally {
    try { if ($ollamaWasActive) { Root "systemctl start ollama.service" } else { Root "systemctl stop ollama.service >/dev/null 2>&1 || true" } } catch { Write-Warning $_.Exception.Message }
    if ($manageWeb) {
        try { if ($webWasActive) { Root "systemctl start open-webui.service" } else { Root "systemctl stop open-webui.service >/dev/null 2>&1 || true" } } catch { Write-Warning $_.Exception.Message }
    }
}

if ($failure) { throw $failure }
Write-Host "Update complete. Previous service state was restored. Owned Open WebUI data was backed up before upgrade."
