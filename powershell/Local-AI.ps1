# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
param(
    [ValidateSet("menu","start","webui","pi","piresume","both","ollama","runtime","stop","restart","status","snapshot","health","logs","benchmark","benchmarkhistory","models","selectmodel","tokens","livetokens","dashboard","diagnostics","probe","resetwebuicredentials","about")]
    [string]$Action = "menu",
    [string]$Model = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Build = "v2.0.0-beta.4.1-20260826"
$Root = Split-Path -Parent $PSScriptRoot
$DefaultConfigPath = Join-Path $Root "config\default.json"
$LocalConfigPath = Join-Path $Root "config\local.json"
$StatePath = Join-Path $Root "state\session.json"
$InstallStatePath = Join-Path $Root "state\install.json"
$PiRunnerPath = Join-Path $Root "state\pi-launch.ps1"
$LogDir = Join-Path $Root "logs\launcher"
$DiagnosticsDir = Join-Path $Root "logs\diagnostics"
New-Item -ItemType Directory -Force -Path $LogDir,$DiagnosticsDir,(Split-Path $StatePath) | Out-Null
$LogPath = Join-Path $LogDir ("controller-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + "-" + $PID + ".log")

function Log {
    param([string]$Message,[string]$Level="INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"),$Level,$Message
    Write-Host $line
    $writeFile = $true
    if (Get-Variable Config -Scope Script -ErrorAction SilentlyContinue) { $writeFile = [bool]$Config.logging.enabled }
    if ($writeFile) { Add-Content -LiteralPath $LogPath -Value $line }
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

function Load-Config {
    if (-not (Test-Path $DefaultConfigPath)) { throw "Missing config: $DefaultConfigPath" }
    $defaults = Get-Content -LiteralPath $DefaultConfigPath -Raw | ConvertFrom-Json
    if (-not (Test-Path $LocalConfigPath)) { return $defaults }
    $local = Get-Content -LiteralPath $LocalConfigPath -Raw | ConvertFrom-Json
    return (Merge-Defaults $local $defaults)
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

$Config = Load-Config
$Distro = [string]$Config.distro
$OllamaPort = [int]$Config.ports.ollama
$WebUiPort = [int]$Config.ports.open_webui

function Invoke-LifecycleMutation {
    param([Parameter(Mandatory=$true)][scriptblock]$Operation)
    $rootBytes = [Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())
    $digest = [Security.Cryptography.SHA256]::HashData($rootBytes)
    $suffix = ([Convert]::ToHexString($digest)).Substring(0,16)
    $mutex = [Threading.Mutex]::new($false, "Local\JYNERATION_LIFECYCLE_$suffix")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(420)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "Another JYNERATION lifecycle command is still running. Try again after it completes." }
        & $Operation
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Wsl {
    param([Parameter(Mandatory=$true)][string]$Command,[switch]$IgnoreExitCode)
    $normalizedCommand = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    $encodedCommand = Encode-B64 $normalizedCommand
    $out = & wsl.exe -d $Distro -- bash -lc "printf %s '$encodedCommand' | base64 -d | bash" 2>&1
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) { throw (($out | Out-String).Trim()) }
    return @($out)
}

function WslRoot {
    param([Parameter(Mandatory=$true)][string]$Command,[switch]$IgnoreExitCode)
    $normalizedCommand = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    $encodedCommand = Encode-B64 $normalizedCommand
    $out = & wsl.exe -d $Distro -u root -- bash -lc "printf %s '$encodedCommand' | base64 -d | bash" 2>&1
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) { throw (($out | Out-String).Trim()) }
    return @($out)
}

function WslPath {
    param([string]$WindowsPath)
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $shellQuoteEscape = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    $quotedPath = $singleQuote + $WindowsPath.Replace($singleQuote, $shellQuoteEscape) + $singleQuote
    $result = & wsl.exe -d $Distro -- bash -lc ("wslpath -u -- " + $quotedPath) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Could not convert path to WSL: $WindowsPath" }
    return ($result | Select-Object -First 1).Trim()
}

function Encode-B64 {
    param([string]$Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Get-RunningDistros {
    try { return @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { return @() }
}

function DistroRunning { return (Get-RunningDistros) -contains $Distro }

function HttpOk {
    param([string]$Url,[int]$Timeout=3)
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,$Url)
            try {
                $response = $client.SendAsync($request,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                try { return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 } finally { $response.Dispose() }
            } finally { $request.Dispose() }
        } finally { $client.Dispose(); $handler.Dispose() }
    } catch { return $false }
}


function Service-Active {
    param([string]$Name)
    if (-not (DistroRunning)) { return $false }
    $result = WslRoot -IgnoreExitCode "systemctl is-active '$Name' 2>/dev/null || true"
    return (($result -join "").Trim() -eq "active")
}

function OllamaOk { return (HttpOk "http://127.0.0.1:$OllamaPort/api/version") }
function WebUiOk {
    if (HttpOk "http://127.0.0.1:$WebUiPort/health" 2) { return $true }
    return (HttpOk "http://127.0.0.1:$WebUiPort/" 3)
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $rows = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
        return @($rows | ForEach-Object {
            $ownerPid = $_.OwningProcess
            $name = try { (Get-Process -Id $ownerPid -ErrorAction Stop).ProcessName } catch { "unknown" }
            "PID $ownerPid ($name)"
        }) -join ", "
    } catch { return "unknown" }
}

function Assert-PortUsable {
    param([int]$Port,[scriptblock]$Healthy,[string]$Name)
    if (& $Healthy) { return }
    $listening = $false
    try { $listening = [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop) } catch {}
    if ($listening) { throw "$Name port $Port is already occupied by $(Get-PortOwner $Port), but its health check failed." }
}

function Wait-For {
    param([scriptblock]$Check,[int]$Seconds,[string]$Name,[int]$Consecutive=1)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    $hits = 0
    do {
        if (& $Check) {
            $hits++
            if ($hits -ge $Consecutive) { Log "$Name is ready." "OK"; return $true }
        } else { $hits = 0 }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $false
}

function Resolve-Workspace {
    $configured = [string]$Config.workspace.default
    if ([string]::IsNullOrWhiteSpace($configured)) { return (WslPath $Root) }
    if ($configured -match '^[A-Za-z]:\\') { return (WslPath $configured) }
    return $configured
}

function Workspace-Display {
    $configured = [string]$Config.workspace.default
    if ([string]::IsNullOrWhiteSpace($configured)) { return $Root }
    return $configured
}

function Read-State { return (Read-JsonSafe $StatePath) }
function Read-InstallState { return (Read-JsonSafe $InstallStatePath) }

function Get-ProcessStamp {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return "" }
    try { return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o") } catch { return "" }
}

function Normalize-ProcessStamp {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString("o") }
        if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString("o") }
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
            return $parsed.UtcDateTime.ToString("o")
        }
    } catch {}
    return [string]$Value
}

function Process-StampMatches {
    param([int]$ProcessId,[object]$ExpectedStart)
    $normalizedStart = Normalize-ProcessStamp $ExpectedStart
    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($normalizedStart)) { return $false }
    try { return (Get-ProcessStamp $ProcessId) -eq $normalizedStart } catch { return $false }
}

function Close-OwnedProcess {
    param([int]$ProcessId,[object]$ExpectedStart)
    if (-not (Process-StampMatches $ProcessId $ExpectedStart)) { return }
    try { Stop-Process -Id $ProcessId -ErrorAction Stop } catch {}
}

function Save-State {
    param([string]$Profile,[string]$SessionId,[int]$PiWindowPid=0,[string]$PiWindowStart="",[int]$KeepAlivePid=0,[string]$KeepAliveStart="")
    $state = [ordered]@{
        build = $Build
        session_id = $SessionId
        started_at = (Get-Date).ToString("o")
        profile = $Profile
        pi_window_pid = $PiWindowPid
        pi_window_start = $PiWindowStart
        keepalive_pid = $KeepAlivePid
        keepalive_start = $KeepAliveStart
        model = [string]$Config.model.primary
        context = [int]$Config.model.context
        reasoning = Resolve-PiThinking
        access_mode = [string]$Config.workspace.access_mode
        workspace = Resolve-Workspace
    }
    $tempStatePath = "$StatePath.$PID.tmp"
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempStatePath -Encoding UTF8
        Move-Item -LiteralPath $tempStatePath -Destination $StatePath -Force
    } finally {
        Remove-Item -LiteralPath $tempStatePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ManagedPiPids {
    param([string]$SessionId)
    if ([string]::IsNullOrWhiteSpace($SessionId) -or -not (DistroRunning)) { return @() }
    if ($SessionId -notmatch '^[A-Za-z0-9-]+$') { return @() }
    $script = @'
for p in /proc/[0-9]*; do
  [ -r "$p/environ" ] || continue
  if { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -Fxq 'LOCAL_AI_SESSION_ID=__SESSION__'; then
    basename "$p"
  fi
done
'@
    $script = $script.Replace("__SESSION__",$SessionId)
    $rows = Wsl -IgnoreExitCode $script
    return @($rows | ForEach-Object { ($_ -as [string]).Trim() } | Where-Object { $_ -match '^\d+$' })
}

function Managed-PiRunning {
    param($State)
    if ($null -eq $State -or -not (DistroRunning)) { return $false }
    return (Get-ManagedPiPids ([string]$State.session_id)).Count -gt 0
}

function PiInstalled {
    if (-not (DistroRunning)) { return $false }
    $x = Wsl -IgnoreExitCode 'if [ -x "$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi" ]; then echo private; elif command -v pi >/dev/null 2>&1; then echo system; fi'
    return -not [string]::IsNullOrWhiteSpace(($x -join "").Trim())
}

function Sync-PiConfig {
    if (-not (DistroRunning)) { return }
    $repo64 = Encode-B64 (WslPath $Root)
    $script = @'
set -e
repo=$(printf %s '__REPO__' | base64 -d)
agent_dir="$HOME/.local/share/local-ai/pi-agent"
mkdir -p "$agent_dir/extensions" "$agent_dir/sessions"
cp "$repo/state/pi-models.json" "$agent_dir/models.json"
cp "$repo/state/pi-settings.json" "$agent_dir/settings.json"
cp "$repo/extension/local-ai.ts" "$agent_dir/extensions/local-ai.ts"
'@
    $script = $script.Replace("__REPO__",$repo64)
    Wsl $script | Out-Null
}

function Resolve-PiThinking {
    $level = [string]$Config.model.reasoning_level
    switch ($level.ToLowerInvariant()) {
        "off" { return "off" }
        "minimal" { return "low" }
        "low" { return "low" }
        "medium" { return "medium" }
        "high" { return "xhigh" }
        "xhigh" { return "xhigh" }
        "max" { return "xhigh" }
        default { throw "Unsupported reasoning level '$level'. Use off, minimal, low, medium, high, xhigh, or max." }
    }
}

function Resolve-PiTools {
    $mode = [string]$Config.workspace.access_mode
    switch ($mode.ToLowerInvariant()) {
        "read" { return "read,grep,find,ls" }
        "workspace" { return "read,bash,edit,write,grep,find,ls" }
        "workspace_net" { return "read,bash,edit,write,grep,find,ls" }
        "workspace+net" { return "read,bash,edit,write,grep,find,ls" }
        "full" { return "read,bash,edit,write,grep,find,ls" }
        default { throw "Unsupported access mode '$mode'. Use read, workspace, workspace_net, or full." }
    }
}

function Start-KeepAlive {
    if (-not [bool]$Config.wsl.visible_keepalive_without_pi) { return $null }
    # Keep WSL alive without opening a user-facing Ubuntu terminal.  The old
    # ubuntu.exe launcher created one visible shell for every overlapping
    # profile start, which looked like duplicate runtimes and required manual
    # cleanup.  A hidden wsl.exe process running sleep has the same lifecycle
    # semantics and is owned/tracked by the existing session state.
    Log "Starting hidden WSL runtime keepalive."
    $process = Start-Process -FilePath "wsl.exe" -ArgumentList @("-d",$Distro,"--","sleep","infinity") -WindowStyle Hidden -PassThru
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$Config.timeouts.keepalive_start_seconds)
    while (-not (DistroRunning) -and [DateTimeOffset]::UtcNow -lt $deadline) {
        try { $process.Refresh(); if ($process.HasExited) { throw "WSL keepalive exited during startup." } } catch { throw $_ }
        Start-Sleep -Milliseconds 250
    }
    if (-not (DistroRunning)) { try { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue } catch {}; throw "WSL keepalive did not become active in time." }
    return [pscustomobject]@{ pid = $process.Id; start = (Get-ProcessStamp $process.Id) }
}

function Start-Ollama {
    $serviceActive = Service-Active "ollama.service"
    if ((OllamaOk) -and $serviceActive) { Log "Ollama is already ready." "OK"; return }
    if ((OllamaOk) -and -not $serviceActive) { throw "Port $OllamaPort is answering, but WSL ollama.service is not active. Stop the conflicting Ollama/server before starting Local AI." }
    Assert-PortUsable -Port $OllamaPort -Healthy { $false } -Name "Ollama"
    Log "Starting Ollama..."
    WslRoot "systemctl reset-failed ollama.service >/dev/null 2>&1 || true; systemctl start ollama.service" | Out-Null
    if (-not (Wait-For -Check { OllamaOk } -Seconds ([int]$Config.timeouts.ollama_start_seconds) -Name "Ollama")) {
        $tail = WslRoot -IgnoreExitCode "journalctl -u ollama.service -n 60 --no-pager"
        Add-Content -LiteralPath $LogPath -Value ($tail -join [Environment]::NewLine)
        throw "Ollama did not become ready. See $LogPath"
    }
}

function Start-WebUI {
    $serviceActive = Service-Active "open-webui.service"
    if ((WebUiOk) -and $serviceActive) { Log "Open WebUI is already ready." "OK"; return }
    if ((WebUiOk) -and -not $serviceActive) { throw "Port $WebUiPort is answering, but WSL open-webui.service is not active. Stop the conflicting server before starting Local AI." }
    Assert-PortUsable -Port $WebUiPort -Healthy { $false } -Name "Open WebUI"
    $unit = WslRoot -IgnoreExitCode "systemctl cat open-webui.service >/dev/null 2>&1 && echo yes || true"
    if (($unit -join "") -notmatch "yes") { throw "Open WebUI is not installed. Run Setup-Local-AI.bat." }
    Log "Starting Open WebUI..."
    WslRoot "systemctl reset-failed open-webui.service >/dev/null 2>&1 || true; systemctl start open-webui.service" | Out-Null
    if (-not (Wait-For -Check { WebUiOk } -Seconds ([int]$Config.timeouts.webui_start_seconds) -Name "Open WebUI" -Consecutive 2)) {
        $tail = WslRoot -IgnoreExitCode "journalctl -u open-webui.service -n 80 --no-pager"
        Add-Content -LiteralPath $LogPath -Value ($tail -join [Environment]::NewLine)
        throw "Open WebUI did not become ready. See $LogPath"
    }
}

function Start-Pi {
    param([string]$SessionId,[switch]$Continue)
    if (-not (PiInstalled)) { throw "Pi is not installed. Run Setup-Local-AI.bat." }
    Sync-PiConfig
    $workspace = Resolve-Workspace
    $model = [string]$Config.model.primary
    $capabilities = @(Get-SelectedModelCapabilities)
    if ($capabilities.Count -gt 0 -and $capabilities -notcontains 'tools') {
        Log "Selected model '$model' does not report Ollama tool support; Pi may be limited to text-only responses." "WARN"
    }
    $thinking = Resolve-PiThinking
    $tools = Resolve-PiTools
    $workspace64 = Encode-B64 $workspace
    $model64 = Encode-B64 $model
    $thinking64 = Encode-B64 $thinking
    $tools64 = Encode-B64 $tools
    $session64 = Encode-B64 $SessionId
    $continueArg = if ($Continue) { "-c" } else { "" }
    $script = @'
set -euo pipefail
workspace=$(printf %s '__WORKSPACE__' | base64 -d)
model=$(printf %s '__MODEL__' | base64 -d)
thinking=$(printf %s '__THINKING__' | base64 -d)
tools=$(printf %s '__TOOLS__' | base64 -d)
session=$(printf %s '__SESSION__' | base64 -d)
agent_dir="$HOME/.local/share/local-ai/pi-agent"
session_dir="$agent_dir/sessions"
private_pi="$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi"
if [ -x "$private_pi" ]; then pi_bin="$private_pi"; else pi_bin=$(command -v pi || true); fi
[ -n "${pi_bin:-}" ] || { echo "Pi is not installed. Run Setup-Local-AI.bat."; exit 127; }
mkdir -p "$agent_dir/extensions" "$session_dir"
cd -- "$workspace"
export PI_CODING_AGENT_DIR="$agent_dir"
export PI_CODING_AGENT_SESSION_DIR="$session_dir"
export LOCAL_AI_MANAGED_PI=1
export LOCAL_AI_SESSION_ID="$session"
exec "$pi_bin" --provider ollama --model "$model" --thinking "$thinking" --tools "$tools" --session-dir "$session_dir" __CONTINUE__
'@
    $script = $script.Replace("__WORKSPACE__",$workspace64).Replace("__MODEL__",$model64).Replace("__THINKING__",$thinking64).Replace("__TOOLS__",$tools64).Replace("__SESSION__",$session64).Replace("__CONTINUE__",$continueArg)
    $script = $script.Replace("`r`n", "`n").Replace("`r", "`n")
    $script64 = Encode-B64 $script
    $escapedDistro = $Distro.Replace("'","''")
    $runner = "& wsl.exe -d '$escapedDistro' -- bash -lc `"exec bash <(printf %s '$script64' | base64 -d)`"`r`n"
    Set-Content -LiteralPath $PiRunnerPath -Value $runner -Encoding UTF8
    $pathPwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $pwshCandidates = @(
        if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe' }
        if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
        if ($PSHOME) { Join-Path $PSHOME 'pwsh.exe' }
        if ($pathPwsh) { $pathPwsh.Source }
    )
    $pwshPath = $pwshCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) -and ($_ -notmatch '\\WindowsApps\\') } | Select-Object -First 1
    if (-not $pwshPath) { throw 'A real pwsh.exe installation could not be located.' }
    Log "Starting Pi in workspace: $workspace"
    $quotedRunner = '"' + $PiRunnerPath + '"'
    $windowsTerminal = Get-Command wt.exe -ErrorAction SilentlyContinue
    $terminalLauncherMayExit = $false
    if ($windowsTerminal) {
        $quotedPwsh = '"' + $pwshPath + '"'
        $process = Start-Process -FilePath $windowsTerminal.Source -ArgumentList @('-w','new',$quotedPwsh,'-NoLogo','-NoProfile','-File',$quotedRunner) -PassThru
        $terminalLauncherMayExit = $true
    } else {
        $process = Start-Process -FilePath $pwshPath -ArgumentList @("-NoLogo","-NoProfile","-NoExit","-File",$quotedRunner) -PassThru
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$Config.timeouts.pi_start_seconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ((Get-ManagedPiPids $SessionId).Count -gt 0) {
            Log "Pi is ready." "OK"
            $windowStart = Get-ProcessStamp $process.Id
            $windowPid = if ($windowStart) { $process.Id } else { 0 }
            return [pscustomobject]@{ pid = $windowPid; start = $windowStart }
        }
        if (-not $terminalLauncherMayExit) {
            try { $process.Refresh(); if ($process.HasExited) { throw "Pi terminal exited during startup." } } catch { throw $_ }
        }
        Start-Sleep -Milliseconds 300
    }
    if (-not $terminalLauncherMayExit) {
        try { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue } catch {}
    }
    throw "Pi did not become ready within $([int]$Config.timeouts.pi_start_seconds) seconds."
}

function Stop-Pi {
    $state = Read-State
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.session_id)) {
        Log "No managed Pi session is recorded." "OK"
        return
    }
    $sessionId = [string]$state.session_id
    $processIds = Get-ManagedPiPids $sessionId
    if ($processIds.Count -eq 0) {
        Log "Managed Pi is already stopped." "OK"
        Close-OwnedProcess ([int]$state.pi_window_pid) $state.pi_window_start
        return
    }
    Log "Requesting managed Pi shutdown..."
    Wsl -IgnoreExitCode ("kill -TERM " + ($processIds -join " ") + " 2>/dev/null || true") | Out-Null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$Config.timeouts.pi_stop_seconds)
    while ((Get-ManagedPiPids $sessionId).Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 400 }
    $remaining = Get-ManagedPiPids $sessionId
    if ($remaining.Count -gt 0) {
        Log "Pi did not exit in time. Forcing only the Local AI managed process tree closed." "WARN"
        Wsl -IgnoreExitCode ("kill -KILL " + ($remaining -join " ") + " 2>/dev/null || true") | Out-Null
    }
    Close-OwnedProcess ([int]$state.pi_window_pid) $state.pi_window_start
}

function Stop-WebUI {
    if (-not (DistroRunning)) { return }
    Log "Stopping Open WebUI..."
    WslRoot -IgnoreExitCode "systemctl stop open-webui.service >/dev/null 2>&1 || true" | Out-Null
}

function Stop-Ollama {
    if (-not (DistroRunning)) { return }
    Log "Stopping Ollama..."
    WslRoot -IgnoreExitCode "systemctl stop ollama.service >/dev/null 2>&1 || true" | Out-Null
}

function Start-Profile {
    param([ValidateSet("webui","pi","both","ollama")][string]$Profile,[switch]$ContinuePi)
    $oldState = Read-State
    $oldPiRunning = Managed-PiRunning $oldState
    $needsPi = $Profile -in @("pi","both")
    $needsWeb = $Profile -in @("webui","both")
    $needsKeepAlive = $Profile -in @("webui","both","ollama") -and [bool]$Config.wsl.visible_keepalive_without_pi

    if (-not $needsPi -and $oldPiRunning) {
        Stop-Pi
        $oldPiRunning = $false
    }
    if (-not $needsWeb -and (DistroRunning)) {
        $webuiServiceActive = Service-Active "open-webui.service"
        if ((WebUiOk) -or $webuiServiceActive) { Stop-WebUI }
    }

    Start-Ollama
    if ($needsWeb) { Start-WebUI }

    $sessionId = [guid]::NewGuid().ToString()
    $piWindowPid = 0
    $piWindowStart = ""
    if ($needsPi) {
        if ($oldPiRunning -and $oldState) {
            $sessionId = [string]$oldState.session_id
            $piWindowPid = [int]$oldState.pi_window_pid
            $piWindowStart = Normalize-ProcessStamp $oldState.pi_window_start
            Log "Reusing the existing Local AI managed Pi session." "OK"
        } else {
            if ($oldState) { Close-OwnedProcess ([int]$oldState.pi_window_pid) $oldState.pi_window_start }
            $piWindow = Start-Pi -SessionId $sessionId -Continue:$ContinuePi
            $piWindowPid = [int]$piWindow.pid
            $piWindowStart = [string]$piWindow.start
        }
    }

    $keepAlivePid = 0
    $keepAliveStart = ""
    if ($needsKeepAlive) {
        if ($oldState -and (Process-StampMatches ([int]$oldState.keepalive_pid) $oldState.keepalive_start)) {
            $keepAlivePid = [int]$oldState.keepalive_pid
            $keepAliveStart = Normalize-ProcessStamp $oldState.keepalive_start
        } else {
            $keepAlive = Start-KeepAlive
            if ($keepAlive) {
                $keepAlivePid = [int]$keepAlive.pid
                $keepAliveStart = [string]$keepAlive.start
            }
        }
    } elseif ($oldState) {
        Close-OwnedProcess ([int]$oldState.keepalive_pid) $oldState.keepalive_start
    }

    Save-State -Profile $Profile -SessionId $sessionId -PiWindowPid $piWindowPid -PiWindowStart $piWindowStart -KeepAlivePid $keepAlivePid -KeepAliveStart $keepAliveStart
    if ($needsWeb) { Start-Process "http://127.0.0.1:$WebUiPort" | Out-Null }
    Log "Profile '$Profile' started." "OK"
}

function Stop-All {
    Log "Beginning Local AI shutdown..."
    $state = Read-State
    $distroWasRunning = DistroRunning
    try { Stop-Pi } catch { Log $_.Exception.Message "WARN" }
    try { Stop-WebUI } catch { Log $_.Exception.Message "WARN" }
    try { Stop-Ollama } catch { Log $_.Exception.Message "WARN" }
    if ($state) { Close-OwnedProcess ([int]$state.keepalive_pid) $state.keepalive_start }

    if ($distroWasRunning) {
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$Config.timeouts.service_stop_seconds)
        while (((OllamaOk) -or (WebUiOk)) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 400 }
    }

    if ([bool]$Config.wsl.terminate_on_stop -and (DistroRunning)) {
        Log "Terminating WSL distro '$Distro' to reclaim memory."
        & wsl.exe --terminate $Distro *> $null
        Start-Sleep -Seconds 1
    }

    $distroStillRunning = DistroRunning
    $ollama = if ($distroStillRunning) { OllamaOk } else { $false }
    $webui = if ($distroStillRunning) { WebUiOk } else { $false }
    $pi = $false
    if ($distroStillRunning -and $state) { $pi = (Get-ManagedPiPids ([string]$state.session_id)).Count -gt 0 }
    Write-Host ""
    Write-Host "Shutdown verification"
    Write-Host "---------------------"
    Write-Host ("Ollama     : " + $(if ($ollama) { "STILL REACHABLE" } else { "OFFLINE" }))
    Write-Host ("Open WebUI : " + $(if ($webui) { "STILL REACHABLE" } else { "OFFLINE" }))
    Write-Host ("Pi Agent   : " + $(if ($pi) { "STILL RUNNING" } else { "STOPPED" }))
    Write-Host ("Ubuntu WSL : " + $(if ($distroStillRunning) { "RUNNING" } else { "STOPPED" }))

    if ($ollama -or $webui -or $pi) { throw "Shutdown verification failed." }
    if ([bool]$Config.wsl.terminate_on_stop -and $distroStillRunning) { throw "Ubuntu WSL is still running after termination." }
    if ($state) { Close-OwnedProcess ([int]$state.pi_window_pid) $state.pi_window_start }
    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    Remove-Item $PiRunnerPath -Force -ErrorAction SilentlyContinue
    Log "Verified shutdown complete." "OK"
}

function Restart-All {
    $state = Read-State
    $profile = if ($state -and [string]$state.profile -in @("webui","pi","both","ollama")) { [string]$state.profile } else { [string]$Config.profile }
    if ($profile -notin @("webui","pi","both","ollama")) { $profile = "both" }
    Stop-All
    Start-Sleep -Seconds 1
    Start-Profile $profile
}

function Show-Status {
    $distroRunning = DistroRunning
    $ollamaEndpoint = if ($distroRunning) { OllamaOk } else { $false }
    $webuiEndpoint = if ($distroRunning) { WebUiOk } else { $false }
    $ollamaService = if ($distroRunning) { Service-Active "ollama.service" } else { $false }
    $webuiService = if ($distroRunning) { Service-Active "open-webui.service" } else { $false }
    $ollamaText = if ($ollamaEndpoint -and $ollamaService) { "RUNNING" } elseif ($ollamaEndpoint) { "PORT RESPONDING / WSL SERVICE STOPPED" } elseif ($ollamaService) { "SERVICE ACTIVE / API DOWN" } else { "STOPPED" }
    $webuiText = if ($webuiEndpoint -and $webuiService) { "RUNNING" } elseif ($webuiEndpoint) { "PORT RESPONDING / WSL SERVICE STOPPED" } elseif ($webuiService) { "SERVICE ACTIVE / HTTP DOWN" } else { "STOPPED" }
    $state = Read-State
    $managedPi = $false
    if ($state -and $distroRunning) { $managedPi = (Get-ManagedPiPids ([string]$state.session_id)).Count -gt 0 }
    $piText = "DISABLED"
    if ([bool]$Config.components.pi) {
        if ($managedPi) { $piText = "RUNNING" }
        elseif ($distroRunning) { $piText = $(if (PiInstalled) { "INSTALLED / STOPPED" } else { "NOT INSTALLED" }) }
        else { $piText = "CONFIGURED / WSL STOPPED" }
    }
    Write-Host ""
    Write-Host "JYNERATION // OLLAMA CONTROL HUD"
    Write-Host "-------------------------------"
    Write-Host ("Ollama     : " + $ollamaText)
    Write-Host ("Open WebUI : " + $webuiText)
    Write-Host ("Pi Agent   : " + $piText)
    Write-Host ("Ubuntu WSL : " + $(if ($distroRunning) { "RUNNING" } else { "STOPPED" }))
    Write-Host ("Model      : " + [string]$Config.model.primary)
    Write-Host ("Context    : " + [string]$Config.model.context)
    Write-Host ("Workspace  : " + (Workspace-Display))
    Write-Host ("Access     : " + [string]$Config.workspace.access_mode)
    Write-Host ("Reasoning  : " + (Resolve-PiThinking))
    if ($state) {
        Write-Host ("Profile    : " + [string]$state.profile)
        Write-Host ("Started    : " + [string]$state.started_at)
    }
}

function Invoke-Helper {
    param([string]$HelperArgs,[switch]$IgnoreExitCode)
    $model64 = Encode-B64 ([string]$Config.model.primary)
    $webuiEnabled = if ([bool]$Config.components.open_webui) { "1" } else { "0" }
    $webuiEnabled64 = Encode-B64 $webuiEnabled
    $helperPath = (WslPath (Join-Path $Root 'wsl\local-ai-tools.py')).Replace("'", "'\\''")
    $script = @'
set -e
model=$(printf %s '__MODEL__' | base64 -d)
webui_enabled=$(printf %s '__WEBUI_ENABLED__' | base64 -d)
export LOCAL_AI_MODEL="$model"
export LOCAL_AI_OPEN_WEBUI_ENABLED="$webui_enabled"
exec python3 '__HELPER__' __ARGS__
'@
    $script = $script.Replace("__MODEL__",$model64).Replace("__WEBUI_ENABLED__",$webuiEnabled64).Replace("__HELPER__",$helperPath).Replace("__ARGS__",$HelperArgs)
    if ($IgnoreExitCode) { Wsl $script -IgnoreExitCode } else { Wsl $script }
}

function Get-RuntimeSnapshot {
    $distroRunning = DistroRunning
    $ollamaEndpoint = if ($distroRunning) { OllamaOk } else { $false }
    $webuiEndpoint = if ($distroRunning) { WebUiOk } else { $false }
    $ollamaService = if ($distroRunning) { Service-Active "ollama.service" } else { $false }
    $webuiService = if ($distroRunning) { Service-Active "open-webui.service" } else { $false }
    $ollamaText = if ($ollamaEndpoint -and $ollamaService) { "RUNNING" } elseif ($ollamaEndpoint) { "PORT RESPONDING / WSL SERVICE STOPPED" } elseif ($ollamaService) { "SERVICE ACTIVE / API DOWN" } else { "STOPPED" }
    $webuiText = if ($webuiEndpoint -and $webuiService) { "RUNNING" } elseif ($webuiEndpoint) { "PORT RESPONDING / WSL SERVICE STOPPED" } elseif ($webuiService) { "SERVICE ACTIVE / HTTP DOWN" } else { "STOPPED" }
    $state = Read-State
    $managedPi = $false
    if ($state -and $distroRunning) { $managedPi = (Get-ManagedPiPids ([string]$state.session_id)).Count -gt 0 }
    $piText = "DISABLED"
    if ([bool]$Config.components.pi) {
        if ($managedPi) { $piText = "RUNNING" }
        elseif ($distroRunning) { $piText = $(if (PiInstalled) { "INSTALLED / STOPPED" } else { "NOT INSTALLED" }) }
        else { $piText = "CONFIGURED / WSL STOPPED" }
    }

    $models = @()
    $loaded = @{}
    if ($ollamaEndpoint) {
        try {
            $runningResponse = Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/ps" -TimeoutSec 4
            foreach ($entry in @($runningResponse.models)) {
                $runningName = [string]$(if ($entry.name) { $entry.name } else { $entry.model })
                if ($runningName) { $loaded[$runningName.ToLowerInvariant()] = $true }
            }
        } catch {}
        try {
            $tags = Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/tags" -TimeoutSec 5
            $models = @($tags.models | ForEach-Object {
                $name = [string]$(if ($_.name) { $_.name } else { $_.model })
                [ordered]@{
                    name = $name
                    size = [int64]$_.size
                    parameters = [string]$_.details.parameter_size
                    quantization = [string]$_.details.quantization_level
                    loaded = [bool]$loaded[$name.ToLowerInvariant()]
                    selected = $name -eq [string]$Config.model.primary
                }
            })
        } catch {}
    }

    $capabilities = if ($ollamaEndpoint) { @(Get-SelectedModelCapabilities) } else { @() }
    [ordered]@{
        timestamp = (Get-Date).ToString("o")
        services = @(
            [ordered]@{ name = "Ollama"; value = $ollamaText; detail = "Local model runtime" }
            [ordered]@{ name = "Open WebUI"; value = $webuiText; detail = "Browser workspace" }
            [ordered]@{ name = "Pi Agent"; value = $piText; detail = "Interactive coding agent" }
            [ordered]@{ name = "Ubuntu WSL"; value = $(if ($distroRunning) { "RUNNING" } else { "STOPPED" }); detail = "Linux runtime host" }
        )
        details = [ordered]@{
            model = [string]$Config.model.primary
            context = [string]$Config.model.context
            workspace = (Workspace-Display)
            access = [string]$Config.workspace.access_mode
            reasoning = (Resolve-PiThinking)
            profile = $(if ($state) { [string]$state.profile } else { [string]$Config.profile })
            started = $(if ($state) { [string]$state.started_at } else { "" })
            capabilities = @($capabilities)
        }
        models = @($models)
    } | ConvertTo-Json -Depth 8 -Compress
}

function Run-Health {
    if (-not (DistroRunning)) { Show-Status; return }
    if ($env:JYNERATION_NONINTERACTIVE -eq "1") { Invoke-Helper "health" -IgnoreExitCode } else { Invoke-Helper "health" }
}
function Run-Models {
    if (-not (DistroRunning)) {
        Write-Host "Ubuntu WSL is stopped. Start Ollama to inspect installed models."
        return
    }
    if (-not (OllamaOk)) {
        Write-Host "Ollama is stopped. Start Ollama to inspect installed models."
        return
    }
    Invoke-Helper "models"
}
function Run-SelectModel {
    param([string]$RequestedModel = "")
    $state = Read-State
    if ($state -and (Managed-PiRunning $state)) { throw "Stop the active Pi session before changing models." }
    if (-not (DistroRunning) -or -not (OllamaOk)) { Start-Ollama }
    $rows = Wsl -IgnoreExitCode 'ollama list | tail -n +2 | cut -d " " -f 1'
    $names = @($rows | ForEach-Object { ($_ -as [string]).Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._:/-]+$' } | Select-Object -Unique)
    if ($names.Count -eq 0) { throw "No Ollama models are installed." }
    Write-Host ""
    Write-Host "SELECT LOCAL OLLAMA MODEL"
    Write-Host "-------------------------"
    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("[{0}] {1}" -f ($i + 1),$names[$i]) }
    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
        $selected = $names | Where-Object { $_ -eq $RequestedModel.Trim() } | Select-Object -First 1
        if (-not $selected) { throw "Model '$RequestedModel' is not installed. Run the model list first." }
    } else {
        $choice = Read-Host ("Choose a model [current: " + [string]$Config.model.primary + "]")
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        $index = 0
        if (-not [int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $names.Count) { throw "Choose a number from 1 to $($names.Count)." }
        $selected = $names[$index - 1]
    }
    $Config.model.primary = $selected
    $Config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $LocalConfigPath -Encoding UTF8
    $piModelsPath = Join-Path $Root 'state\pi-models.json'
    $piModels = Read-JsonSafe $piModelsPath
    if ($piModels -and $piModels.providers.ollama.models) {
        $entry = $piModels.providers.ollama.models | Select-Object -First 1
        $entry.id = $selected
        $entry.name = $selected
        $piModels.providers.ollama.models = @($entry)
        $piModels | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $piModelsPath -Encoding UTF8
    }
    Sync-PiConfig
    Write-Host "Selected model: $selected" -ForegroundColor Green
}

function Get-SelectedModelCapabilities {
    if (-not (OllamaOk)) { return @() }
    try {
        $payload = @{ name = [string]$Config.model.primary } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/show" -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 8
        return @($response.capabilities | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    } catch { return @() }
}
function Run-Tokens { Invoke-Helper "tokens --days 7" }
function Run-LiveTokens { Invoke-Helper "tokens --days 7 --live --interval 2" }
function Run-Dashboard { Invoke-Helper "dashboard" }
function Run-BenchmarkHistory { Invoke-Helper "benchmark-history --limit 20" }
function Run-Benchmark {
    $model64 = Encode-B64 ([string]$Config.model.primary)
    $ctx = [int]$Config.model.context
    $script = @'
set -e
model=$(printf %s '__MODEL__' | base64 -d)
export LOCAL_AI_MODEL="$model"
exec python3 ~/.local/bin/local-ai-tools.py benchmark --model "$model" --num-ctx __CTX__ --runs 3 --output-tokens 128
'@
    $script = $script.Replace("__MODEL__",$model64).Replace("__CTX__",[string]$ctx)
    Wsl $script
}

function Live-Logs {
    Write-Host "Following Ollama + Open WebUI logs. Ctrl+C closes the viewer only."
    & wsl.exe -d $Distro -u root -- bash -lc "journalctl -f -u ollama.service -u open-webui.service -o short-iso"
}

function WebUI-Probe {
    if (-not (DistroRunning)) {
        Write-Host "Ubuntu WSL is stopped; WebUI endpoints are not probed."
        return
    }
    $targets = @("http://127.0.0.1:$WebUiPort/health","http://127.0.0.1:$WebUiPort/ready","http://127.0.0.1:$WebUiPort/health/db","http://127.0.0.1:$WebUiPort/")
    foreach ($url in $targets) {
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $response = Invoke-WebRequest -Uri $url -Method Get -MaximumRedirection 0 -TimeoutSec 5 -SkipHttpErrorCheck
            $sw.Stop()
            Write-Host ("{0,-46} {1,4} {2,7} ms" -f $url,[int]$response.StatusCode,[int]$sw.ElapsedMilliseconds)
        } catch { Write-Host ("{0,-46} FAIL {1}" -f $url,$_.Exception.Message) }
    }
}

function ConvertFrom-SecureStringPlainText {
    param([Parameter(Mandatory=$true)][Security.SecureString]$Value)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Reset-WebUICredentials {
    if (-not [bool]$Config.components.open_webui) { throw "Open WebUI is disabled in this Local AI profile." }
    $distroWasRunning = DistroRunning
    try {
        $unit = WslRoot -IgnoreExitCode "systemctl cat open-webui.service >/dev/null 2>&1 && echo yes || true"
        if (($unit -join "").Trim() -ne "yes") { throw "Open WebUI is not installed. Run Setup-Local-AI.bat first." }
        $htpasswd = Wsl -IgnoreExitCode "command -v htpasswd 2>/dev/null || true"
        if (-not (($htpasswd -join "").Trim())) {
            Log "Installing the Open WebUI credential recovery prerequisite."
            WslRoot "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y apache2-utils" | Out-Null
        }

    $accountScript = @'
set -euo pipefail
data_dir=$(systemctl cat open-webui.service 2>/dev/null | sed -nE 's/^[[:space:]]*Environment="?DATA_DIR=([^" ]+)"?$/\1/p' | tail -n 1)
[ -n "$data_dir" ] || data_dir="$HOME/.open-webui"
db="$data_dir/webui.db"
[ -f "$db" ] || { echo "ERROR: Open WebUI database not found at $db" >&2; exit 4; }
python3 - "$db" <<'PY'
import sqlite3
import sys

db = sys.argv[1]
with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as connection:
    table = connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='auth'").fetchone()
    if table is None:
        raise SystemExit("ERROR: Open WebUI auth table was not found.")
    rows = connection.execute("SELECT email FROM auth ORDER BY lower(email)").fetchall()
for (email,) in rows:
    print(f"ACCOUNT\t{email}")
PY
'@
    $accountOutput = Wsl $accountScript
    $accounts = @($accountOutput | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith("ACCOUNT`t") } | ForEach-Object { $_.Substring(8).Trim() } | Where-Object { $_ })
    if ($accounts.Count -eq 0) { throw "No Open WebUI accounts were found. Open WebUI may still be waiting for first-time setup." }

    Write-Host ""
    Write-Host "RESET OPEN WEBUI LOGIN" -ForegroundColor Cyan
    Write-Host "----------------------"
    Write-Host "This changes one password only. Chats, settings, and other accounts are preserved."
    Write-Host "A timestamped webui.db backup is created before the update."
    Write-Host ""
    Write-Host "Local accounts:"
    foreach ($account in $accounts) { Write-Host "  $account" }
    Write-Host ""

    $defaultEmail = if ($accounts.Count -eq 1) { $accounts[0] } else { "" }
    $prompt = if ($defaultEmail) { "Account email [$defaultEmail]" } else { "Account email" }
    $email = (Read-Host $prompt).Trim()
    if (-not $email) { $email = $defaultEmail }
    if (-not $email -or $accounts -notcontains $email) { throw "Choose an email from the local account list." }

    $securePassword = Read-Host "New password (8+ characters)" -AsSecureString
    $secureConfirm = Read-Host "Confirm new password" -AsSecureString
    $password = ConvertFrom-SecureStringPlainText $securePassword
    $confirmation = ConvertFrom-SecureStringPlainText $secureConfirm
    try {
        if ($password.Length -lt 8) { throw "The new password must be at least 8 characters." }
        if ($password -cne $confirmation) { throw "The passwords do not match." }

        $wasActive = Service-Active "open-webui.service"
        if ($wasActive) {
            Log "Stopping Open WebUI for credential recovery."
            WslRoot "systemctl stop open-webui.service" | Out-Null
        }

        try {
            $resetScript = @'
set -euo pipefail
IFS= read -r email
IFS= read -r password
command -v htpasswd >/dev/null 2>&1 || { echo "ERROR: htpasswd is missing. Run Setup-Local-AI.bat to install recovery prerequisites." >&2; exit 5; }
data_dir=$(systemctl cat open-webui.service 2>/dev/null | sed -nE 's/^[[:space:]]*Environment="?DATA_DIR=([^" ]+)"?$/\1/p' | tail -n 1)
[ -n "$data_dir" ] || data_dir="$HOME/.open-webui"
db="$data_dir/webui.db"
[ -f "$db" ] || { echo "ERROR: Open WebUI database not found at $db" >&2; exit 4; }
hash=$(htpasswd -bnBC 10 "" "$password" | tr -d ':\n')
unset password
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="$db.backup-$stamp"
cp -a -- "$db" "$backup"
export JYNERATION_WEBUI_EMAIL="$email"
export JYNERATION_WEBUI_HASH="$hash"
python3 - "$db" <<'PY'
import os
import sqlite3
import sys

db = sys.argv[1]
email = os.environ["JYNERATION_WEBUI_EMAIL"]
password_hash = os.environ["JYNERATION_WEBUI_HASH"]
with sqlite3.connect(db) as connection:
    row = connection.execute("SELECT id FROM auth WHERE lower(email) = lower(?)", (email,)).fetchone()
    if row is None:
        raise SystemExit("ERROR: The selected Open WebUI account no longer exists.")
    connection.execute("UPDATE auth SET password = ? WHERE id = ?", (password_hash, row[0]))
    connection.commit()
print("PASSWORD_UPDATED")
PY
unset JYNERATION_WEBUI_EMAIL JYNERATION_WEBUI_HASH hash
printf 'BACKUP\t%s\n' "$backup"
'@
            $encodedScript = Encode-B64 ($resetScript.Replace("`r`n", "`n").Replace("`r", "`n"))
            $inputPayload = $email + "`n" + $password + "`n"
            $result = $inputPayload | & wsl.exe -d $Distro -- bash -lc "exec bash <(printf %s '$encodedScript' | base64 -d)" 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { throw (($result | Out-String).Trim()) }
            if (($result -join "`n") -notmatch "PASSWORD_UPDATED") { throw "Open WebUI did not confirm the credential update." }
            $backupLine = $result | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith("BACKUP`t") } | Select-Object -First 1
            $backupPath = if ($backupLine) { $backupLine.Substring(7).Trim() } else { "the Open WebUI data directory" }
            Log "Open WebUI password updated for $email. Backup: $backupPath" "OK"
        } finally {
            if ($wasActive) {
                Log "Restoring Open WebUI service."
                WslRoot "systemctl start open-webui.service" | Out-Null
            }
        }
    } finally {
        $password = $null
        $confirmation = $null
        $inputPayload = $null
    }
    } finally {
        if (-not $distroWasRunning -and (DistroRunning) -and -not (Service-Active "open-webui.service")) {
            Log "Restoring the previously stopped WSL runtime."
            & wsl.exe --terminate $Distro 2>$null | Out-Null
        }
    }
}

function Diagnostics {
    $distroRunning = DistroRunning
    $path = Join-Path $DiagnosticsDir ("diagnostics-" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".txt")
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("JYNERATION // Ollama Control HUD diagnostics")
    $lines.Add("Build: $Build")
    $lines.Add("Author: saj")
    $lines.Add("License: MIT")
    $lines.Add("Attribution: Copyright (c) 2026 saj")
    $lines.Add("Provenance manifest: SHA256SUMS.txt")
    $lines.Add("Generated: $((Get-Date).ToString('o'))")
    $lines.Add("")
    $lines.Add("Windows")
    $lines.Add((Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber,OsArchitecture | Format-List | Out-String))
    $lines.Add("HUD Python")
    $python = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $pythonw = Get-Command pythonw.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($python) {
        $lines.Add(("python.exe: " + [string]$python.Source))
        $lines.Add(("version: " + ((& $python.Source --version 2>&1 | Select-Object -First 1) -join " ")))
        $lines.Add(("PySide6: " + ((& $python.Source -c "import PySide6; print(getattr(PySide6, '__version__', 'ready'))" 2>&1 | Select-Object -First 1) -join " ")))
    } else { $lines.Add("python.exe: unavailable") }
    $lines.Add(("pythonw.exe: " + $(if ($pythonw) { [string]$pythonw.Source } else { "unavailable" })))
    $lines.Add("WSL")
    $lines.Add((& wsl.exe --version 2>&1 | Out-String))
    $lines.Add((& wsl.exe -l -v 2>&1 | Out-String))
    if ($distroRunning) {
        $lines.Add("Ubuntu")
        $runtimeDiagnostics = @'
uname -a
echo
id
echo
free -h
echo
df -h /
echo
private_pi="$HOME/.local/share/local-ai/pi-runtime/node_modules/.bin/pi"
if [ -x "$private_pi" ]; then "$private_pi" --version; else pi --version 2>/dev/null || true; fi
echo
ollama --version 2>/dev/null || true
'@
        $lines.Add((Wsl -IgnoreExitCode $runtimeDiagnostics | Out-String))
        $lines.Add("GPU")
        $lines.Add((Wsl -IgnoreExitCode "nvidia-smi 2>&1 || /usr/lib/wsl/lib/nvidia-smi 2>&1 || true" | Out-String))
        $lines.Add("Services")
        $lines.Add((WslRoot -IgnoreExitCode "systemctl status ollama.service open-webui.service --no-pager -l 2>&1 || true" | Out-String))
        $journalLines = [int]$Config.logging.diagnostics_journal_lines
        $lines.Add("Journal")
        $lines.Add((WslRoot -IgnoreExitCode "journalctl -u ollama.service -u open-webui.service -n $journalLines --no-pager -o short-iso 2>&1 || true" | Out-String))
    }
    $lines.Add("Status")
    $lines.Add("Ollama: $(if ($distroRunning) { OllamaOk } else { $false })")
    $lines.Add("Open WebUI: $(if ($distroRunning) { WebUiOk } else { $false })")
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Diagnostics saved to: $path"
}

function Show-About {
    $creditsPath = Join-Path $Root "CREDITS.json"
    $credits = Get-Content -LiteralPath $creditsPath -Raw | ConvertFrom-Json
    Write-Host ""
    Write-Host "JYNERATION // OLLAMA CONTROL HUD" -ForegroundColor Cyan
    Write-Host "---------------------------------"
    Write-Host ("Build      : " + [string]$credits.build)
    Write-Host ("Author     : " + [string]$credits.author)
    Write-Host ("Copyright  : " + [string]$credits.copyright)
    Write-Host ("License    : " + [string]$credits.license)
    Write-Host ("Runtime    : " + [string]$credits.runtime)
    Write-Host ("Provenance : " + [string]$credits.provenance.manifest)
    Write-Host ""
    Write-Host "Preserve LICENSE and NOTICE.md when redistributing this project." -ForegroundColor Yellow
}


function Open-Runtime {
    $ubuntu = $null
    if ($Distro -eq "Ubuntu") { $ubuntu = Get-Command ubuntu.exe -ErrorAction SilentlyContinue }
    if ($ubuntu) { Start-Process -FilePath $ubuntu.Source | Out-Null }
    else { Start-Process -FilePath "wsl.exe" -ArgumentList @("-d",$Distro) | Out-Null }
}

function Menu {
    while ($true) {
        Clear-Host
        Write-Host "=========================================="
        Write-Host "         JYNERATION // OLLAMA HUD"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "[1] Web UI"
        Write-Host "[2] Pi Agent"
        Write-Host "[3] Resume Pi"
        Write-Host "[4] Both"
        Write-Host "[5] Ollama Only"
        Write-Host "[6] Custom"
        Write-Host "[7] Status"
        Write-Host "[8] Health"
        Write-Host "[9] Models"
        Write-Host "[10] Select Model"
        Write-Host "[11] Tokens"
        Write-Host "[12] Live Tokens"
        Write-Host "[13] Dashboard"
        Write-Host "[14] Benchmark"
        Write-Host "[15] Benchmark History"
        Write-Host "[16] Live Logs"
        Write-Host "[17] WebUI Probe"
        Write-Host "[18] Diagnostics"
        Write-Host "[19] Reset WebUI Login"
        Write-Host "[20] About / Credits"
        Write-Host "[21] Stop Everything"
        Write-Host "[0] Exit"
        Write-Host ""
        $choice = Read-Host "Select"
        try {
            switch ($choice) {
                "1" { Invoke-LifecycleMutation { Start-Profile "webui" } }
                "2" { Invoke-LifecycleMutation { Start-Profile "pi" } }
                "3" { Invoke-LifecycleMutation { Start-Profile "pi" -ContinuePi } }
                "4" { Invoke-LifecycleMutation { Start-Profile "both" } }
                "5" { Invoke-LifecycleMutation { Start-Profile "ollama" } }
                "6" {
                    $wantWeb = (Read-Host "Start Open WebUI? [y/N]") -match '^[Yy]'
                    $wantPi = (Read-Host "Start Pi? [y/N]") -match '^[Yy]'
                    if ($wantWeb -and $wantPi) { $customProfile = "both" } elseif ($wantWeb) { $customProfile = "webui" } elseif ($wantPi) { $customProfile = "pi" } else { $customProfile = "ollama" }
                    Invoke-LifecycleMutation { Start-Profile $customProfile }
                }
                "7" { Show-Status }
                "8" { Run-Health }
                "9" { Run-Models }
                "10" { Invoke-LifecycleMutation { Run-SelectModel } }
                "11" { Run-Tokens }
                "12" { Run-LiveTokens }
                "13" { Run-Dashboard }
                "14" { Run-Benchmark }
                "15" { Run-BenchmarkHistory }
                "16" { Live-Logs }
                "17" { WebUI-Probe }
                "18" { Diagnostics }
                "19" { Invoke-LifecycleMutation { Reset-WebUICredentials } }
                "20" { Show-About }
                "21" { Invoke-LifecycleMutation { Stop-All } }
                "0" { return }
            }
        } catch { Log $_.Exception.Message "ERROR"; Write-Host $_.Exception.Message -ForegroundColor Red }
        Write-Host ""
        Read-Host "Press Enter to continue"
    }
}

try {
    switch ($Action) {
        "menu" { Menu }
        "start" { $profile = [string]$Config.profile; if ($profile -notin @("webui","pi","both","ollama")) { $profile = "both" }; Invoke-LifecycleMutation { Start-Profile $profile } }
        "webui" { Invoke-LifecycleMutation { Start-Profile "webui" } }
        "pi" { Invoke-LifecycleMutation { Start-Profile "pi" } }
        "piresume" { Invoke-LifecycleMutation { Start-Profile "pi" -ContinuePi } }
        "both" { Invoke-LifecycleMutation { Start-Profile "both" } }
        "ollama" { Invoke-LifecycleMutation { Start-Profile "ollama" } }
        "runtime" { Open-Runtime }
        "stop" { Invoke-LifecycleMutation { Stop-All } }
        "restart" { Invoke-LifecycleMutation { Restart-All } }
        "status" { Show-Status }
        "snapshot" { Get-RuntimeSnapshot }
        "health" { Run-Health }
        "logs" { Live-Logs }
        "benchmark" { Run-Benchmark }
        "benchmarkhistory" { Run-BenchmarkHistory }
        "models" { Run-Models }
        "selectmodel" { Invoke-LifecycleMutation { Run-SelectModel $Model } }
        "tokens" { Run-Tokens }
        "livetokens" { Run-LiveTokens }
        "dashboard" { Run-Dashboard }
        "diagnostics" { Diagnostics }
        "probe" { WebUI-Probe }
        "resetwebuicredentials" { Invoke-LifecycleMutation { Reset-WebUICredentials } }
        "about" { Show-About }
    }
    exit 0
} catch { Log $_.Exception.Message "ERROR"; exit 1 }
