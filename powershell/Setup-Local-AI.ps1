param([switch]$Repair)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Build = "v2.0.0-beta.4.1-20260826"
$Root = Split-Path -Parent $PSScriptRoot
$DefaultConfigPath = Join-Path $Root "config\default.json"
$LocalConfigPath = Join-Path $Root "config\local.json"
$StateDir = Join-Path $Root "state"
$InstallStatePath = Join-Path $StateDir "install.json"
$LogDir = Join-Path $Root "logs\launcher"
New-Item -ItemType Directory -Force -Path $StateDir,$LogDir | Out-Null
$prefix = if ($Repair) { "repair-" } else { "setup-" }
$LogPath = Join-Path $LogDir ($prefix + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".log")

function Log {
    param([string]$Message,[string]$Level="INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"),$Level,$Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Is-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Merge-Defaults {
    param($Target,$Defaults)
    foreach ($property in $Defaults.PSObject.Properties) {
        $current = $Target.PSObject.Properties[$property.Name]
        if ($null -eq $current) {
            $Target | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        } elseif ($current.Value -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
            Merge-Defaults $current.Value $property.Value | Out-Null
        }
    }
    return $Target
}

function Write-JsonUtf8 {
    param([string]$Path,$Object)
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function New-InstallState {
    return [pscustomobject]@{
        build = $Build
        pi_installed_by_local_ai = $false
        pi_preexisting = $false
        ollama_installed_by_local_ai = $false
        ollama_preexisting = $false
        open_webui_created_by_local_ai = $false
        open_webui_preexisting = $false
        context_override_created = $false
        helper_installed = $false
    }
}

function Merge-InstallState {
    param($State)
    if ($null -eq $State) { return (New-InstallState) }
    return (Merge-Defaults $State (New-InstallState))
}

function Resolve-PiThinking {
    param([string]$Level)
    switch ($Level.ToLowerInvariant()) {
        "off" { return "off" }
        "minimal" { return "low" }
        "low" { return "low" }
        "medium" { return "medium" }
        "high" { return "xhigh" }
        "xhigh" { return "xhigh" }
        "max" { return "xhigh" }
        default { throw "Unsupported reasoning level '$Level'." }
    }
}

function Save-InstallState {
    $script:InstallState.build = $Build
    Write-JsonUtf8 $InstallStatePath $script:InstallState
}

function WslUser {
    param([string]$Distro,[Parameter(Mandatory=$true)][string]$Command,[switch]$IgnoreExitCode)
    & wsl.exe -d $Distro -- bash -lc $Command
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) { throw "Ubuntu command failed with exit code $code." }
}

function WslRoot {
    param([string]$Distro,[Parameter(Mandatory=$true)][string]$Command,[switch]$IgnoreExitCode)
    & wsl.exe -d $Distro -u root -- bash -lc $Command
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) { throw "Ubuntu root command failed with exit code $code." }
}

function WslCapture {
    param([string]$Distro,[Parameter(Mandatory=$true)][string]$Command,[switch]$Root)
    $out = if ($Root) { & wsl.exe -d $Distro -u root -- bash -lc $Command 2>$null } else { & wsl.exe -d $Distro -- bash -lc $Command 2>$null }
    if ($LASTEXITCODE -ne 0) { return "" }
    return (($out | Out-String).Trim())
}

function WslPath {
    param([string]$Distro,[string]$Path)
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $shellQuoteEscape = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    $quotedPath = $singleQuote + $Path.Replace($singleQuote, $shellQuoteEscape) + $singleQuote
    $out = & wsl.exe -d $Distro -- bash -lc ("wslpath -u -- " + $quotedPath) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { throw "Could not convert to WSL path: $Path" }
    return ($out | Select-Object -First 1).Trim()
}

function Encode-B64 {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function WslUserScript {
    param([string]$Distro,[string]$Script)
    $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoded = Encode-B64 $normalizedScript
    WslUser $Distro "printf %s '$encoded' | base64 -d | bash"
}

function Get-Distros {
    try { return @(& wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { return @() }
}

function Port-Listening {
    param([int]$Port)
    try { return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop) } catch { return $false }
}

function Http-Ok {
    param([string]$Url,[int]$Timeout=3)
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -MaximumRedirection 0 -TimeoutSec $Timeout -SkipHttpErrorCheck
        return $null -ne $response
    } catch { return $false }
}

function Assert-ServicePortOwnership {
    param([string]$Distro,[int]$Port,[string]$Service,[string[]]$HealthUrls,[string]$Name)
    if (-not (Port-Listening $Port)) { return }
    $active = (WslCapture $Distro "systemctl is-active '$Service' 2>/dev/null || true" -Root) -eq "active"
    $healthy = $false
    foreach ($url in $HealthUrls) { if (Http-Ok $url 2) { $healthy = $true; break } }
    if (-not ($active -and $healthy)) { throw "Windows port $Port is already occupied, but the expected WSL $Service ownership/health check failed for $Name." }
}

function Assert-ModelName {
    param([string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model) -or $Model -notmatch '^[A-Za-z0-9._:/-]+$') { throw "Invalid Ollama model name: '$Model'" }
}

Log "Local AI v2 $(if ($Repair) {'repair'} else {'setup'}) starting."
if (-not [Environment]::Is64BitOperatingSystem) { throw "64-bit Windows is required." }
Log "64-bit Windows detected." "OK"

$wslOk = $false
try { & wsl.exe --status *> $null; $wslOk = $LASTEXITCODE -eq 0 } catch {}
if (-not $wslOk) {
    if (-not (Is-Admin)) {
        Log "WSL is not ready. Relaunching setup as administrator." "WARN"
        $pwshPath = (Get-Process -Id $PID).Path
        $repairArg = if ($Repair) { " -Repair" } else { "" }
        $args = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"$repairArg"
        $process = Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList $args -Wait -PassThru
        exit $process.ExitCode
    }
    Log "Installing WSL and Ubuntu. Windows may require a restart."
    & wsl.exe --install -d Ubuntu
    if ($LASTEXITCODE -ne 0) { throw "WSL installation failed." }
    exit 3010
}

$defaults = Get-Content -LiteralPath $DefaultConfigPath -Raw | ConvertFrom-Json
$config = $defaults
if (Test-Path $LocalConfigPath) {
    $local = Get-Content -LiteralPath $LocalConfigPath -Raw | ConvertFrom-Json
    $config = Merge-Defaults $local $defaults
}
$config.version = 2
$config.build = $Build
$distro = [string]$config.distro
if ([string]::IsNullOrWhiteSpace($distro)) { $distro = "Ubuntu" }

$script:InstallState = Merge-InstallState (Read-JsonSafe $InstallStatePath)
Save-InstallState

if ((Get-Distros) -notcontains $distro) {
    Log "Installing WSL distro '$distro'."
    & wsl.exe --install -d $distro
    if ($LASTEXITCODE -ne 0) { throw "Could not install $distro." }
    Write-Host "Complete Ubuntu's first-run username/password creation if it opens, then run setup again."
    exit 3010
}

Log "Checking Ubuntu connectivity."
WslUser $distro "echo Local-AI-WSL-OK" | Out-Null

$kernel = WslCapture $distro "uname -r"
if ($kernel -notmatch 'microsoft-standard-WSL2|WSL2') {
    Log "Converting '$distro' to WSL2."
    & wsl.exe --terminate $distro *> $null
    & wsl.exe --set-version $distro 2
    if ($LASTEXITCODE -ne 0) { throw "Could not convert $distro to WSL2." }
    Start-Sleep -Seconds 2
    WslUser $distro "echo WSL2-READY" | Out-Null
}

$pidOne = WslCapture $distro "ps -p 1 -o comm="
if ($pidOne.Trim() -ne "systemd") {
    Log "Enabling systemd in $distro."
    WslRoot $distro "if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then if grep -A20 '^\[boot\]' /etc/wsl.conf | grep -q '^[[:space:]]*systemd[[:space:]]*='; then sed -i '/^\[boot\]/,/^\[/{s/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/}' /etc/wsl.conf; else sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf; fi; else printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf; fi"
    & wsl.exe --terminate $distro *> $null
    Start-Sleep -Seconds 2
    $pidOne = WslCapture $distro "ps -p 1 -o comm="
    if ($pidOne.Trim() -ne "systemd") { throw "systemd could not be enabled automatically. Check /etc/wsl.conf." }
    Log "systemd enabled." "OK"
} else { Log "systemd detected." "OK" }

if (-not $Repair) {
    Write-Host ""
    Write-Host "Components"
    Write-Host "----------"
    $web = Read-Host "Install/enable Open WebUI? [Y/n]"
    $piChoice = Read-Host "Install/enable Pi Agent? [Y/n]"
    $config.components.open_webui = -not ($web -match '^[Nn]')
    $config.components.pi = -not ($piChoice -match '^[Nn]')
    $config.components.ollama = $true
    if ($config.components.open_webui -and $config.components.pi) { $config.profile = "both" } elseif ($config.components.open_webui) { $config.profile = "webui" } elseif ($config.components.pi) { $config.profile = "pi" } else { $config.profile = "ollama" }
    $workspace = Read-Host "Default Pi workspace (Windows path or WSL path, Enter = Local-AI-v2 folder)"
    if (-not [string]::IsNullOrWhiteSpace($workspace)) { $config.workspace.default = $workspace.Trim() }
    $access = Read-Host "Pi access mode: read, workspace, workspace_net, full [$($config.workspace.access_mode)]"
    if (-not [string]::IsNullOrWhiteSpace($access)) { $config.workspace.access_mode = $access.Trim().ToLowerInvariant() }
    $terminate = Read-Host "Terminate the entire Ubuntu distro on Stop to reclaim RAM? [Y/n]"
    $config.wsl.terminate_on_stop = -not ($terminate -match '^[Nn]')
}
if ([string]$config.workspace.access_mode -notin @("read","workspace","workspace_net","workspace+net","full")) { throw "Invalid workspace.access_mode '$($config.workspace.access_mode)'." }
Resolve-PiThinking ([string]$config.model.reasoning_level) | Out-Null
Assert-ServicePortOwnership -Distro $distro -Port ([int]$config.ports.ollama) -Service "ollama.service" -HealthUrls @("http://127.0.0.1:$($config.ports.ollama)/api/version") -Name "Ollama"
if ([bool]$config.components.open_webui) {
    Assert-ServicePortOwnership -Distro $distro -Port ([int]$config.ports.open_webui) -Service "open-webui.service" -HealthUrls @("http://127.0.0.1:$($config.ports.open_webui)/health","http://127.0.0.1:$($config.ports.open_webui)/") -Name "Open WebUI"
}

Log "Updating Ubuntu package lists. Output is streamed below."
WslRoot $distro "export DEBIAN_FRONTEND=noninteractive; apt-get update"
$corePackages = "ca-certificates curl jq unzip python3 python3-pip python3-venv"
if ([bool]$config.components.pi) { $corePackages += " git ripgrep" }
Log "Installing Ubuntu prerequisites."
WslRoot $distro "export DEBIAN_FRONTEND=noninteractive; apt-get install -y $corePackages"

if ([bool]$config.components.pi) {
    $nodeVersion = WslCapture $distro "node --version 2>/dev/null || true"
    $nodeMajor = 0
    $nodeMinor = 0
    if ($nodeVersion -match '^v(\d+)\.(\d+)') { $nodeMajor = [int]$Matches[1]; $nodeMinor = [int]$Matches[2] }
    if ($nodeMajor -lt 22 -or ($nodeMajor -eq 22 -and $nodeMinor -lt 19)) {
        Log "Installing Node.js 24 for current Pi compatibility."
        WslRoot $distro "curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && export DEBIAN_FRONTEND=noninteractive; apt-get install -y nodejs"
    } else { Log "Node.js detected: $(WslCapture $distro 'node --version')" "OK" }
}

if ([bool]$config.components.open_webui) {
    if (-not (WslCapture $distro "command -v uv")) {
        Log "Installing uv."
        WslUser $distro "curl -LsSf https://astral.sh/uv/install.sh | sh"
    } else { Log "uv detected: $(WslCapture $distro 'uv --version')" "OK" }
}

$ollamaBefore = WslCapture $distro "command -v ollama || true"
if ($ollamaBefore) {
    $script:InstallState.ollama_preexisting = $true
    Log "Ollama detected: $(WslCapture $distro 'ollama --version')" "OK"
} else {
    Log "Installing Ollama inside WSL."
    WslRoot $distro "curl -fsSL https://ollama.com/install.sh | sh"
    $script:InstallState.ollama_installed_by_local_ai = $true
    Save-InstallState
}

$context = [int]$config.model.context
$flashAttention = [bool]$config.ollama.flash_attention
$kvCacheType = ([string]$config.ollama.kv_cache_type).ToLowerInvariant()
if ($kvCacheType -notin @("f16","q8_0","q4_0")) { throw "Unsupported ollama.kv_cache_type '$kvCacheType'. Use f16, q8_0, or q4_0." }
if ($kvCacheType -ne "f16" -and -not $flashAttention) { throw "Quantized KV cache requires ollama.flash_attention=true. Keep f16 for beta4 defaults unless you explicitly test q8_0/q4_0." }
Log "Configuring Ollama context length: $context (Flash Attention=$flashAttention, KV=$kvCacheType)."
$overrideLines = @("[Service]","Environment=`"OLLAMA_CONTEXT_LENGTH=$context`"")
if ($flashAttention) { $overrideLines += "Environment=`"OLLAMA_FLASH_ATTENTION=1`"" }
if ($kvCacheType -ne "f16") { $overrideLines += "Environment=`"OLLAMA_KV_CACHE_TYPE=$kvCacheType`"" }
$override = ($overrideLines -join "`n") + "`n"
$override64 = Encode-B64 $override
WslRoot $distro "mkdir -p /etc/systemd/system/ollama.service.d && echo '$override64' | base64 -d > /etc/systemd/system/ollama.service.d/local-ai.conf && systemctl daemon-reload && systemctl enable --now ollama.service"
$script:InstallState.context_override_created = $true
Save-InstallState

$repoWsl = WslPath $distro $Root
$repo64 = Encode-B64 $repoWsl
Log "Installing Local AI helper tools."
$helperScript = @'
set -e
repo=$(printf %s '__REPO__' | base64 -d)
mkdir -p ~/.local/bin
install -m 755 "$repo/wsl/local-ai-tools.py" ~/.local/bin/local-ai-tools.py
'@
WslUserScript $distro ($helperScript.Replace("__REPO__",$repo64))
$script:InstallState.helper_installed = $true
Save-InstallState

if ([bool]$config.components.pi) {
    $privatePi = WslCapture $distro 'if [ -x "$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi" ]; then printf %s "$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi"; fi'
    $systemPi = WslCapture $distro 'candidate=$(command -v pi 2>/dev/null || true); if [ -n "$candidate" ]; then target=$(readlink -f "$candidate" 2>/dev/null || true); case "$target" in */pi-coding-agent/*) printf %s "$candidate";; esac; fi'
    if ($privatePi) {
        $script:InstallState.pi_installed_by_local_ai = $true
        Log "Local AI Pi runtime detected: $privatePi" "OK"
    } elseif ($systemPi -and -not [bool]$script:InstallState.pi_installed_by_local_ai) {
        $script:InstallState.pi_preexisting = $true
        Log "Pre-existing Pi detected and preserved: $systemPi" "OK"
    } else {
        Log "Installing Pi into Local AI's private user-owned runtime."
        WslUser $distro 'mkdir -p "$HOME/.local/share/local-ai/pi-runtime"; npm install --prefix "$HOME/.local/share/local-ai/pi-runtime" --ignore-scripts @earendil-works/pi-coding-agent@latest'
        $script:InstallState.pi_installed_by_local_ai = $true
        Save-InstallState
    }
}

$installedModels = WslCapture $distro "ollama list | tail -n +2 | cut -d ' ' -f 1"
$model = [string]$config.model.primary
Assert-ModelName $model
$names = @($installedModels -split "\r?\n" | Where-Object { $_ })
$exact = $names | Where-Object { $_ -eq $model } | Select-Object -First 1
if (-not $exact) {
    $normalized = $model -replace ':latest$',''
    $exact = $names | Where-Object { ($_ -replace ':latest$','') -eq $normalized } | Select-Object -First 1
}
if ($exact) { $model = $exact }
elseif ($names.Count -gt 0 -and -not $Repair) {
    Write-Host ""
    Write-Host "Configured model '$model' is not installed."
    Write-Host ($names -join [Environment]::NewLine)
    $choice = Read-Host "Enter an installed model name, or press Enter to pull '$model'"
    if (-not [string]::IsNullOrWhiteSpace($choice)) { $model = $choice.Trim(); Assert-ModelName $model }
    else { WslUser $distro "ollama pull '$model'" }
} elseif ($names.Count -eq 0) {
    if ($Repair) { Log "No Ollama models are installed." "WARN" }
    else {
        $pull = Read-Host "No Ollama models are installed. Enter a model to pull [$model]"
        if (-not [string]::IsNullOrWhiteSpace($pull)) { $model = $pull.Trim() }
        Assert-ModelName $model
        WslUser $distro "ollama pull '$model'"
    }
}
$config.model.primary = $model
$config.build = $Build
Write-JsonUtf8 $LocalConfigPath $config
Log "Saved config\local.json." "OK"

if ([bool]$config.components.pi) {
    $models = Get-Content -LiteralPath (Join-Path $Root "config\models.json") -Raw | ConvertFrom-Json
    $settings = Get-Content -LiteralPath (Join-Path $Root "config\settings.json") -Raw | ConvertFrom-Json
    $modelEntry = $models.providers.ollama.models | Select-Object -First 1
    $modelEntry.id = $model
    $modelEntry.name = $model
    $modelEntry.contextWindow = [int]$config.model.context
    $modelEntry.maxTokens = [int]$config.model.max_output_tokens
    $settings.defaultProvider = "ollama"
    $settings.defaultModel = $model
    $settings.defaultThinkingLevel = Resolve-PiThinking ([string]$config.model.reasoning_level)
    $piModelsPath = Join-Path $StateDir "pi-models.json"
    $piSettingsPath = Join-Path $StateDir "pi-settings.json"
    Write-JsonUtf8 $piModelsPath $models
    Write-JsonUtf8 $piSettingsPath $settings
    Log "Installing isolated Pi configuration and extension."
    $piCopyScript = @'
set -e
repo=$(printf %s '__REPO__' | base64 -d)
agent_dir="$HOME/.local/share/local-ai/pi-agent"
mkdir -p "$agent_dir/extensions" "$agent_dir/sessions"
cp "$repo/state/pi-models.json" "$agent_dir/models.json"
cp "$repo/state/pi-settings.json" "$agent_dir/settings.json"
cp "$repo/extension/local-ai.ts" "$agent_dir/extensions/local-ai.ts"
'@
    WslUserScript $distro ($piCopyScript.Replace("__REPO__",$repo64))
}

if ([bool]$config.components.open_webui) {
    $existingUnit = WslCapture $distro "systemctl cat open-webui.service >/dev/null 2>&1 && echo yes || true" -Root
    if ($existingUnit -match "yes") {
        $script:InstallState.open_webui_preexisting = $true
        Log "Existing Open WebUI service detected. Preserving its working service definition." "OK"
    } else {
        Log "Installing Open WebUI with Python 3.11 in a persistent uv tool environment."
        WslUser $distro 'export PATH="$HOME/.local/bin:$PATH"; uv tool install --python 3.11 open-webui || uv tool upgrade open-webui'
        $linuxUser = WslCapture $distro "id -un"
        $linuxHome = WslCapture $distro 'printf %s "$HOME"'
        $openWebUi = WslCapture $distro 'command -v open-webui || printf %s "$HOME/.local/bin/open-webui"'
        $unit = @"
[Unit]
Description=Open WebUI
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=$linuxUser
Environment=HOME=$linuxHome
Environment=DATA_DIR=$linuxHome/.open-webui
Environment=OLLAMA_BASE_URL=http://127.0.0.1:11434
Environment=WEBUI_URL=http://localhost:$($config.ports.open_webui)
Environment=UVICORN_WORKERS=1
ExecStart=$openWebUi serve --host 0.0.0.0 --port $($config.ports.open_webui)
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
"@
        $unit64 = Encode-B64 $unit
        WslRoot $distro "set -e; echo '$unit64' | base64 -d > /etc/systemd/system/open-webui.service; systemctl daemon-reload; systemctl disable open-webui.service >/dev/null 2>&1 || true"
        $script:InstallState.open_webui_created_by_local_ai = $true
        Save-InstallState
        Log "Open WebUI installed without WSL-boot autostart." "OK"
    }
} else {
    WslRoot $distro "systemctl stop open-webui.service >/dev/null 2>&1 || true" -IgnoreExitCode
    Log "Open WebUI is disabled in the Local AI profile." "OK"
}

$gpu = WslCapture $distro "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || /usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true"
if ($gpu) { Log "GPU: $gpu" "OK" } else { Log "NVIDIA GPU telemetry was not detected. CPU or non-NVIDIA inference can still work." "WARN" }

Log "Running smoke checks."
$smokeCommands = @("python3 --version","ollama --version")
if ([bool]$config.components.open_webui) { $smokeCommands += "uv --version" }
if ([bool]$config.components.pi) { $smokeCommands += "node --version"; $smokeCommands += "npm --version" }
WslUser $distro ($smokeCommands -join "; ")
WslUser $distro "export LOCAL_AI_MODEL='$model'; python3 ~/.local/bin/local-ai-tools.py health" -IgnoreExitCode | Out-Null
if ([bool]$config.components.pi) {
    $piSmokeScript = @'
set -e
agent_dir="$HOME/.local/share/local-ai/pi-agent"
session_dir="$agent_dir/sessions"
private_pi="$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi"
if [ -x "$private_pi" ]; then pi_bin="$private_pi"; else pi_bin=$(command -v pi); fi
export PI_CODING_AGENT_DIR="$agent_dir"
export PI_CODING_AGENT_SESSION_DIR="$session_dir"
"$pi_bin" --version
"$pi_bin" --list-models | grep -F -- '__MODEL__' >/dev/null
'@
    WslUserScript $distro ($piSmokeScript.Replace("__MODEL__",$model))
    Log "Pi sees the configured model through the isolated Local AI home." "OK"
    $smoke = if ($Repair) { "n" } else { Read-Host "Run a short Pi/Ollama inference smoke test? [Y/n]" }
    if ($smoke -notmatch '^[Nn]') {
        $thinking = Resolve-PiThinking ([string]$config.model.reasoning_level)
        $inferenceScript = @'
agent_dir="$HOME/.local/share/local-ai/pi-agent"
session_dir="$agent_dir/sessions"
private_pi="$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi"
if [ -x "$private_pi" ]; then pi_bin="$private_pi"; else pi_bin=$(command -v pi); fi
export PI_CODING_AGENT_DIR="$agent_dir"
export PI_CODING_AGENT_SESSION_DIR="$session_dir"
timeout 90 "$pi_bin" --provider ollama --model '__MODEL__' --thinking '__THINKING__' --no-session -p 'Reply with exactly LOCAL_AI_PI_OK.' 2>/dev/null || true
'@
        $result = WslCapture $distro (($inferenceScript.Replace("__MODEL__",$model)).Replace("__THINKING__",$thinking))
        if ($result -match 'LOCAL_AI_PI_OK') { Log "Pi inference smoke test passed." "OK" } else { Log "Pi launched but the inference smoke test did not return the expected marker." "WARN" }
    }
}

Save-InstallState
Write-Host ""
Write-Host "=========================================="
Write-Host "          LOCAL AI v2 READY"
Write-Host "=========================================="
Write-Host "Profile : $($config.profile)"
Write-Host "Model   : $model"
Write-Host "Context : $($config.model.context)"
Write-Host ""
Write-Host "Run Local-AI.bat or Start-Local-AI.bat."
Log "Setup completed." "OK"
