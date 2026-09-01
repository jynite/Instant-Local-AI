# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $Root "config\local.json"
$installStatePath = Join-Path $Root "state\install.json"
$config = if (Test-Path $configPath) { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } else { Get-Content -LiteralPath (Join-Path $Root "config\default.json") -Raw | ConvertFrom-Json }
$installState = if (Test-Path $installStatePath) { Get-Content -LiteralPath $installStatePath -Raw | ConvertFrom-Json } else { $null }
$distro = [string]$config.distro

function User { param([string]$Command); & wsl.exe -d $distro -- bash -lc $Command; if ($LASTEXITCODE -ne 0) { throw "Ubuntu command failed." } }
function Root { param([string]$Command); & wsl.exe -d $distro -u root -- bash -lc $Command; if ($LASTEXITCODE -ne 0) { throw "Ubuntu root command failed." } }

Write-Host "JYNERATION // Uninstall"
Write-Host "Everything is opt-in. WSL and Ubuntu are never removed automatically."

$piIntegration = Read-Host "Remove Local AI's isolated Pi config/extension? [y/N]"
if ($piIntegration -match '^[Yy]') {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupScript = @'
agent_dir="$HOME/.local/share/local-ai/pi-agent"
backup_dir="$agent_dir/backups/__STAMP__"
if [ -d "$agent_dir" ]; then
  mkdir -p "$backup_dir"
  [ -f "$agent_dir/models.json" ] && mv "$agent_dir/models.json" "$backup_dir/" || true
  [ -f "$agent_dir/settings.json" ] && mv "$agent_dir/settings.json" "$backup_dir/" || true
  [ -d "$agent_dir/extensions" ] && mv "$agent_dir/extensions" "$backup_dir/" || true
fi
'@
    User ($backupScript.Replace("__STAMP__",$stamp))
}

$piSessions = Read-Host "DELETE Local AI's isolated Pi sessions? [y/N]"
if ($piSessions -match '^[Yy]') { User 'rm -rf "$HOME/.local/share/local-ai/pi-agent/sessions"' }

if ($installState -and [bool]$installState.pi_installed_by_local_ai) {
    $removePi = Read-Host "Remove the Local AI-owned private Pi runtime? [y/N]"
    if ($removePi -match '^[Yy]') { User 'rm -rf "$HOME/.local/share/local-ai/pi-runtime"' }
} else {
    Write-Host "Pre-existing Pi packages are preserved."
}

$web = Read-Host "Remove the Local AI Open WebUI service/application? [y/N]"
if ($web -match '^[Yy]') {
    if ($installState -and [bool]$installState.open_webui_created_by_local_ai) {
        Root "systemctl disable --now open-webui.service 2>/dev/null || true; rm -f /etc/systemd/system/open-webui.service; systemctl daemon-reload"
        User 'export PATH="$HOME/.local/bin:$PATH"; uv tool uninstall open-webui || true'
    } else { Write-Host "The Open WebUI service/application was preserved because Local AI did not record ownership of it." }
    $data = Read-Host "Also DELETE ~/.open-webui chats/settings? [y/N]"
    if ($data -match '^[Yy]') {
        $confirm = Read-Host "Type DELETE WEBUI DATA to confirm"
        if ($confirm -eq "DELETE WEBUI DATA") { User 'rm -rf "$HOME/.open-webui"' } else { Write-Host "Open WebUI data preserved." }
    }
}

$override = Read-Host "Remove Local AI's Ollama context/Flash/KV override? [y/N]"
if ($override -match '^[Yy]') { Root "rm -f /etc/systemd/system/ollama.service.d/local-ai.conf; systemctl daemon-reload" }

if ($installState -and [bool]$installState.ollama_installed_by_local_ai) {
    $ollama = Read-Host "Remove the Local AI-owned Ollama binary/service too? Models are kept. [y/N]"
    if ($ollama -match '^[Yy]') {
        Root "systemctl disable --now ollama.service 2>/dev/null || true; rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama; systemctl daemon-reload"
    }
} else { Write-Host "Pre-existing Ollama is preserved." }

$models = Read-Host "Delete downloaded Ollama models too? [y/N]"
if ($models -match '^[Yy]') {
    Write-Host "Model deletion is intentionally not bulk-automated in beta4. Use Manage-Models.bat / ollama rm so model removal stays explicit per model."
}

$helper = Read-Host "Remove Local AI helper tooling from ~/.local/bin? [y/N]"
if ($helper -match '^[Yy]') { User 'rm -f "$HOME/.local/bin/local-ai-tools.py"' }

$local = Read-Host "Remove generated config/state/logs from this repo? [y/N]"
if ($local -match '^[Yy]') {
    Remove-Item (Join-Path $Root "config\local.json") -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $Root "state") -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne ".gitkeep" } | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $Root "logs") -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne ".gitkeep" } | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "WSL/Ubuntu were preserved. Uninstall pass complete."
