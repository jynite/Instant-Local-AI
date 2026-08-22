param(
    [ValidateSet(
        "menu","install","start","stop","restart","status","health","logs",
        "tokens","livetokens","gpu","dashboard","models","benchmark",
        "benchmarkhistory","diagnostics","update","probe"
    )]
    [string]$Action = "menu"
)

$ErrorActionPreference = "Stop"
$LocalAIBuild = "v1.0.0"
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Distro = if ($env:LOCAL_AI_DISTRO) { $env:LOCAL_AI_DISTRO } else { "Ubuntu" }
$Model = if ($env:LOCAL_AI_MODEL) { $env:LOCAL_AI_MODEL } else { "huihui_ai/Qwen3.8-abliterated" }
$WebUIUrl = "http://localhost:3000"

$LogDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$WindowsLog = Join-Path $LogDir "controller-$Stamp.log"
$ServiceLog = Join-Path $LogDir "services-$Stamp.log"

$BuildFile = Join-Path $PSScriptRoot "BUILD-ID.txt"
if (-not (Test-Path -LiteralPath $BuildFile)) {
    Write-Host "ERROR: BUILD-ID.txt is missing. This folder is incomplete or mixed with an older build." -ForegroundColor Red
    exit 91
}
$DiskBuild = (Get-Content -LiteralPath $BuildFile -Raw).Trim()
if ($DiskBuild -ne $LocalAIBuild) {
    Write-Host "ERROR: Local AI build mismatch." -ForegroundColor Red
    Write-Host "Controller: $LocalAIBuild"
    Write-Host "Folder:     $DiskBuild"
    Write-Host "Extract Local AI v1 into a clean folder instead of mixing versions." -ForegroundColor Yellow
    exit 92
}

function Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR")][string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $WindowsLog -Value $line
    switch ($Level) {
        "OK"    { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Invoke-Linux {
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [switch]$Root,
        [switch]$IgnoreExitCode
    )

    $Script = $Script.Replace("`r`n", "`n").Replace("`r", "`n")

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "wsl.exe"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true

    [void]$psi.ArgumentList.Add("-d")
    [void]$psi.ArgumentList.Add($Distro)
    if ($Root) {
        [void]$psi.ArgumentList.Add("-u")
        [void]$psi.ArgumentList.Add("root")
    }
    [void]$psi.ArgumentList.Add("--")
    [void]$psi.ArgumentList.Add("bash")
    [void]$psi.ArgumentList.Add("-s")

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    [void]$p.Start()

    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()

    $p.StandardInput.NewLine = "`n"
    $p.StandardInput.Write($Script)
    $p.StandardInput.Close()

    $p.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $code = $p.ExitCode
    $p.Dispose()

    if ($stdout) { Add-Content -LiteralPath $WindowsLog -Value $stdout.TrimEnd() }
    if ($stderr) { Add-Content -LiteralPath $WindowsLog -Value ("[WSL STDERR]`r`n" + $stderr.TrimEnd()) }

    if (-not $IgnoreExitCode -and $code -ne 0) {
        if ($stderr) { Write-Host $stderr -ForegroundColor Red }
        throw "Ubuntu command failed with exit code $code."
    }

    [pscustomobject]@{ ExitCode=$code; StdOut=$stdout; StdErr=$stderr }
}

function Ensure-Ubuntu {
    & wsl.exe -d $Distro -e true *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start WSL distro '$Distro'. Run 'wsl -l -v' and confirm the exact name."
    }
}

function Get-Identity {
    $r = Invoke-Linux -Script @'
printf 'LOCALAI_USER=%s\n' "$(id -un)"
printf 'LOCALAI_HOME=%s\n' "$HOME"
'@
    $userLine = ($r.StdOut -split "`r?`n" | Where-Object { $_ -like "LOCALAI_USER=*" } | Select-Object -First 1)
    $homeLine = ($r.StdOut -split "`r?`n" | Where-Object { $_ -like "LOCALAI_HOME=*" } | Select-Object -First 1)

    if (-not $userLine -or -not $homeLine) {
        Write-Host "--- raw WSL output ---" -ForegroundColor Yellow
        Write-Host $r.StdOut
        Write-Host "--- end ---" -ForegroundColor Yellow
        throw "Could not determine Ubuntu username/home. See raw output above and $WindowsLog."
    }

    $user = $userLine.Substring("LOCALAI_USER=".Length).Trim()
    $homeDir = $homeLine.Substring("LOCALAI_HOME=".Length).Trim()

    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($homeDir)) {
        throw "Ubuntu returned an empty username or home directory."
    }

    [pscustomobject]@{ User = $user; Home = $homeDir }
}

function ConvertTo-Utf8Base64 {
    param([Parameter(Mandatory=$true)][string]$Value)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Install-TextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Cannot install missing source file: $Source"
    }

    $content = [System.IO.File]::ReadAllText($Source)
    $content = $content.Replace("`r`n", "`n").Replace("`r", "`n")
    $contentB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
    $destB64 = ConvertTo-Utf8Base64 $Destination

    Invoke-Linux -Script @"
set -euo pipefail
DEST="`$(printf '%s' '$destB64' | base64 -d)"
mkdir -p "`$(dirname "`$DEST")"
printf '%s' '$contentB64' | base64 -d > "`$DEST"
chmod 0755 "`$DEST"
"@ | Out-Null
}

function Ensure-Installed {
    $r = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl cat open-webui.service >/dev/null 2>&1
'@
    if ($r.ExitCode -ne 0) {
        throw "Local AI service is not installed yet. Run Install-Local-AI.bat first."
    }
}

function Install-Stack {
    Ensure-Ubuntu
    $id = Get-Identity

    Log "Ubuntu user: $($id.User)"
    Log "Ubuntu home: $($id.Home)"

    Invoke-Linux -Script @'
test "$(ps -p 1 -o comm=)" = "systemd"
'@ | Out-Null
    Log "systemd is active." "OK"

    Log "Installing/repairing isolated Open WebUI and nvitop tools..."
    $tools = Invoke-Linux -Script @'
set -euo pipefail

if command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV="$HOME/.local/bin/uv"
else
    echo "uv is missing."
    echo "Install it with:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 127
fi

export PATH="$HOME/.local/bin:$PATH"
export UV_TOOL_BIN_DIR="$HOME/.local/bin"

"$UV" --version

if [ ! -x "$HOME/.local/bin/open-webui" ]; then
    "$UV" tool install --python 3.11 open-webui
elif ! "$HOME/.local/bin/open-webui" --help >/dev/null 2>&1; then
    echo "Open WebUI executable exists but is broken. Forcing a clean reinstall..."
    "$UV" tool install --force --python 3.11 open-webui
fi

if [ ! -x "$HOME/.local/bin/nvitop" ]; then
    "$UV" tool install nvitop
elif ! "$HOME/.local/bin/nvitop" --version >/dev/null 2>&1; then
    echo "nvitop executable exists but is broken. Forcing a clean reinstall..."
    "$UV" tool install --force nvitop
fi

"$HOME/.local/bin/open-webui" --help >/dev/null
"$HOME/.local/bin/nvitop" --version >/dev/null
'@
    Write-Host $tools.StdOut
    Log "Open WebUI + nvitop installed." "OK"

    $toolsSource = Join-Path $PSScriptRoot "local-ai-tools.py"
    Install-TextFile -Source $toolsSource -Destination "$($id.Home)/.local/bin/local-ai-tools.py"
    Log "Local AI utility suite installed." "OK"

    $service = @"
[Unit]
Description=Open WebUI
Documentation=https://docs.openwebui.com/
Requires=ollama.service
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=$($id.User)
WorkingDirectory=$($id.Home)
Environment=HOME=$($id.Home)
Environment=PATH=$($id.Home)/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/wsl/lib
Environment=DATA_DIR=$($id.Home)/.open-webui
Environment=OLLAMA_BASE_URL=http://127.0.0.1:11434
Environment=WEBUI_URL=http://localhost:3000
Environment=ENABLE_ADMIN_ANALYTICS=True
Environment=GLOBAL_LOG_LEVEL=INFO
Environment=AUDIT_LOG_LEVEL=METADATA
Environment=ENABLE_AUDIT_LOGS_FILE=True
Environment=AUDIT_LOGS_FILE_PATH=$($id.Home)/.open-webui/audit.log
Environment=AUDIT_LOG_FILE_ROTATION_SIZE=10MB
ExecStart=$($id.Home)/.local/bin/open-webui serve --host 0.0.0.0 --port 3000
Restart=on-failure
RestartSec=3
KillSignal=SIGTERM
TimeoutStartSec=300
TimeoutStopSec=30
SuccessExitStatus=0 143
UMask=0077
CPUAccounting=yes
MemoryAccounting=yes
TasksAccounting=yes

[Install]
WantedBy=multi-user.target
"@

    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($service))

    Invoke-Linux -Root -Script @"
set -e
printf '%s' '$b64' | base64 -d > /etc/systemd/system/open-webui.service

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/local-ai.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
MaxRetentionSec=14day
EOF

mkdir -p /var/log/journal
systemctl restart systemd-journald
systemctl daemon-reload
"@ | Out-Null

    Log "open-webui.service installed." "OK"
    Log "Persistent journald: 14 days, max 500 MB." "OK"

    Write-Host ""
    Write-Host "Installation complete." -ForegroundColor Green
    Write-Host "Your existing Open WebUI data stays at $($id.Home)/.open-webui"
}

function Get-HttpStatus {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [int]$TimeoutSeconds = 3
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)

    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get,
            $Url
        )

        try {
            $response = $client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

            try {
                return [int]$response.StatusCode
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }
    }
    catch {
        return 0
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-WebUIProbe {
    # On this Open WebUI build the SPA root is consistently reachable while
    # /health may time out from the Windows side. Do not call a functioning UI
    # unhealthy just because the optional health endpoint is weird.
    $root = Get-HttpStatus "$WebUIUrl/" 3
    $health = Get-HttpStatus "$WebUIUrl/health" 1

    [pscustomobject]@{
        Root = $root
        Health = $health
    }
}

function Get-WebUIExtendedProbe {
    $basic = Get-WebUIProbe
    $ready = Get-HttpStatus "$WebUIUrl/ready" 1
    $db = Get-HttpStatus "$WebUIUrl/health/db" 1

    [pscustomobject]@{
        Root = $basic.Root
        Health = $basic.Health
        Ready = $ready
        Database = $db
    }
}

function Test-WebUIHealth {
    # Root reachability + active systemd service is the actual local readiness
    # contract. /health is retained for diagnostics only.
    $probe = Get-WebUIProbe
    return ($probe.Root -ge 200 -and $probe.Root -lt 400)
}

function Wait-Health {
    param([int]$Seconds=180)

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    $successes = 0
    $attempt = 0
    $lastSummary = ""

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $attempt++

        # First make sure the backend process still exists.
        $service = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl is-active --quiet open-webui.service
'@
        if ($service.ExitCode -ne 0) {
            Log "open-webui.service stopped during startup." "ERROR"
            return $false
        }

        $probe = Get-WebUIProbe
        $rootOK = ($probe.Root -ge 200 -and $probe.Root -lt 400)

        if ($rootOK) {
            $successes++
            if ($successes -ge 2) {
                if ($probe.Health -ge 200 -and $probe.Health -lt 300) {
                    Log "Open WebUI ready: /=$($probe.Root) /health=$($probe.Health)" "OK"
                }
                else {
                    Log "Open WebUI ready: /=$($probe.Root); /health=$($probe.Health) is diagnostic-only on this build." "OK"
                }
                return $true
            }
        }
        else {
            $successes = 0
        }

        $summary = "/=$($probe.Root) /health=$($probe.Health) service=active"
        if ($summary -ne $lastSummary -or $attempt -eq 1 -or $attempt % 10 -eq 0) {
            Log "Waiting for Open WebUI: $summary"
            $lastSummary = $summary
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Test-OllamaAPI {
    $r = Invoke-Linux -IgnoreExitCode -Script @'
curl -fsS --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1
'@
    return ($r.ExitCode -eq 0)
}

function Write-ServiceSnapshot {
    param([int]$Lines = 80)

    # Literal here-string: Bash $(...) must reach Ubuntu untouched.
    $script = @'
echo "===== $(date --iso-8601=seconds) ====="
systemctl --no-pager --plain status open-webui.service ollama.service 2>&1 || true
echo
journalctl -u open-webui.service -u ollama.service -n __LINES__ --no-pager -o short-iso 2>&1 || true
'@
    $script = $script.Replace("__LINES__", [string][Math]::Max(1, $Lines))

    $snapshot = Invoke-Linux -Root -IgnoreExitCode -Script $script

    if ($snapshot.StdOut) {
        Add-Content -LiteralPath $ServiceLog -Value $snapshot.StdOut.TrimEnd()
    }
    if ($snapshot.StdErr) {
        Add-Content -LiteralPath $ServiceLog -Value ("[snapshot stderr]`r`n" + $snapshot.StdErr.TrimEnd())
    }
}

function Follow-ServiceLogs {
    $launcher = Get-UbuntuLauncher
    if (-not $launcher) {
        Log "Cannot open live service logs because ubuntu.exe was not found." "WARN"
        return
    }

    Write-Host ""
    Write-Host "================================================" -ForegroundColor DarkCyan
    Write-Host "              LIVE SERVICE LOGS" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor DarkCyan
    Write-Host "Open WebUI + Ollama journal. Ctrl+C stops only this log viewer." -ForegroundColor DarkGray
    Write-Host "Log file: $ServiceLog" -ForegroundColor DarkGray
    Write-Host ""

    try {
        & $launcher run journalctl -f -n 60 -u open-webui.service -u ollama.service -o short-iso 2>&1 |
            Tee-Object -FilePath $ServiceLog -Append
    }
    catch {
        Log "Live journal viewer ended: $($_.Exception.Message)" "WARN"
    }
}

function Get-UbuntuLauncher {
    # Prefer the exact Ubuntu App Execution Alias the user already launches
    # by typing `ubuntu` in PowerShell.
    foreach ($candidate in @(
        "ubuntu.exe",
        "ubuntu",
        "ubuntu2404.exe",
        "ubuntu2204.exe",
        "ubuntu2004.exe"
    )) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Open-UbuntuShell {
    $launcher = Get-UbuntuLauncher

    if ($launcher) {
        Log "Opening the installed Ubuntu app directly: $launcher"
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $launcher
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        return
    }

    # Fallback only. The normal path on this machine is ubuntu.exe.
    Log "ubuntu.exe was not found. Falling back to wsl.exe -d $Distro." "WARN"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "wsl.exe"
    $psi.UseShellExecute = $true
    [void]$psi.ArgumentList.Add("-d")
    [void]$psi.ArgumentList.Add($Distro)
    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Open-Ubuntu {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$Title="Ubuntu | Local AI"
    )

    $launcher = Get-UbuntuLauncher

    if (-not $launcher) {
        # A command window is optional functionality. Fall back to a normal
        # visible Ubuntu shell rather than going back through wt.exe.
        Log "ubuntu.exe was not found. Opening a normal WSL shell instead." "WARN"
        Open-UbuntuShell
        return
    }

    # Never pass the user's Linux command through wt.exe, cmd.exe, or nested
    # Windows quoting. Encode the entire Linux script, then let bash decode it.
    $payload = ConvertTo-Utf8Base64 $Command
    $linuxWrapper = "printf '%s' '$payload' | base64 -d | bash"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $launcher
    $psi.UseShellExecute = $true

    # Ubuntu's distro launcher accepts:
    #   ubuntu.exe run <command> <args...>
    #
    # ArgumentList keeps each argument separate. This is what avoids the old
    # Windows Terminal tabs named "echo" / "exec".
    [void]$psi.ArgumentList.Add("run")
    [void]$psi.ArgumentList.Add("bash")
    [void]$psi.ArgumentList.Add("-lc")
    [void]$psi.ArgumentList.Add($linuxWrapper)

    [System.Diagnostics.Process]::Start($psi) | Out-Null
}

function Start-Stack {
    Ensure-Ubuntu
    Ensure-Installed

    Log "Opening DIRECT Ubuntu runtime shell via ubuntu.exe..."
    Open-UbuntuShell
    Log "Keep the Ubuntu window open while using Local AI." "OK"
    Start-Sleep -Seconds 1

    $already = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl is-active --quiet open-webui.service
'@

    if ($already.ExitCode -eq 0 -and (Test-WebUIHealth) -and (Test-OllamaAPI)) {
        Log "Open WebUI + Ollama are already running." "OK"
        Write-ServiceSnapshot -Lines 40
        Start-Process $WebUIUrl
        Log "Opened $WebUIUrl" "OK"

        if ($Action -eq "start") {
            Follow-ServiceLogs
        }
        return
    }

    Log "Starting open-webui.service. systemd will start Ollama first."
    $startResult = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl reset-failed open-webui.service ollama.service >/dev/null 2>&1 || true
systemctl start open-webui.service
'@

    Write-ServiceSnapshot -Lines 30

    if ($startResult.ExitCode -ne 0) {
        Log "systemctl could not start Open WebUI." "ERROR"
        Write-ServiceSnapshot -Lines 180
        Get-Content -LiteralPath $ServiceLog -Tail 120 | Write-Host
        throw "Open WebUI service failed to start."
    }

    if (-not (Wait-Health -Seconds 180)) {
        Log "Open WebUI failed its readiness check." "ERROR"
        $probe = Get-WebUIExtendedProbe
        Write-Host ("HTTP probe: /={0} /health={1} /ready={2} /health/db={3}" -f $probe.Root, $probe.Health, $probe.Ready, $probe.Database) -ForegroundColor Yellow
        Write-ServiceSnapshot -Lines 220
        Get-Content -LiteralPath $ServiceLog -Tail 160 | Write-Host
        throw "Open WebUI startup failed."
    }

    $finalState = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl is-active --quiet open-webui.service
'@
    if ($finalState.ExitCode -ne 0) {
        Write-ServiceSnapshot -Lines 180
        throw "Open WebUI became reachable but the service stopped immediately afterward."
    }

    if (-not (Test-OllamaAPI)) {
        Write-ServiceSnapshot -Lines 120
        throw "Open WebUI is reachable, but the Ollama API is not responding."
    }

    Write-ServiceSnapshot -Lines 60

    Log "Detection summary: Open WebUI root reachable, systemd active, Ollama API reachable." "OK"
    Start-Process $WebUIUrl
    Log "Opened $WebUIUrl" "OK"
    Log "Ubuntu is the WSL keepalive window." "OK"

    # For the dedicated Start launcher, turn this same PowerShell window into
    # the live log console after startup instead of leaving it nearly empty.
    if ($Action -eq "start") {
        Follow-ServiceLogs
    }
}

function Test-HttpEndpoint {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [int]$TimeoutMilliseconds = 1200
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)

    try {
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Get,
            $Url
        )
        try {
            $response = $client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            try {
                # Any HTTP response proves an HTTP server is still reachable,
                # even if it returns 404/500.
                return $true
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-LocalAIEndpointState {
    [pscustomobject]@{
        WebUI = Test-HttpEndpoint -Url "http://127.0.0.1:3000/" -TimeoutMilliseconds 1000
        Ollama = Test-HttpEndpoint -Url "http://127.0.0.1:11434/api/tags" -TimeoutMilliseconds 1000
    }
}

function Invoke-WslShutdownWithTimeout {
    param([int]$TimeoutSeconds = 4)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "wsl.exe"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void]$psi.ArgumentList.Add("--shutdown")

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi

    try {
        [void]$p.Start()

        if ($p.WaitForExit($TimeoutSeconds * 1000)) {
            return $p.ExitCode
        }

        Log "wsl.exe --shutdown exceeded ${TimeoutSeconds}s. Continuing because Local AI services are already stopped." "WARN"

        try { $p.Kill($true) } catch {}
        return 124
    }
    catch {
        Log "Best-effort WSL VM reclaim failed: $($_.Exception.Message)" "WARN"
        return 125
    }
    finally {
        $p.Dispose()
    }
}

function Get-RunningWslDistros {
    try {
        $raw = & wsl.exe --list --running --quiet 2>$null
        $code = $LASTEXITCODE
    }
    catch {
        return @()
    }

    if ($code -ne 0 -or -not $raw) {
        return @()
    }

    # wsl.exe output can contain embedded NULs depending on console encoding.
    # Use PowerShell string replacement instead of .NET's Char,Char Replace
    # overload, which rejects an empty replacement string.
    $joined = ($raw -join "`n") -replace ([string][char]0), ""

    return @(
        $joined -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )
}

function Get-ListeningProcessInfo {
    param([int[]]$Ports = @(3000, 11434))

    $items = @()

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "$env:SystemRoot\System32\netstat.exe"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    [void]$psi.ArgumentList.Add("-ano")
    [void]$psi.ArgumentList.Add("-p")
    [void]$psi.ArgumentList.Add("tcp")

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi

    try {
        [void]$p.Start()
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit(2000)) {
            Log "netstat listener check exceeded 2s. Skipping socket metadata." "WARN"
            try { $p.Kill($true) } catch {}
            return @()
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
    }
    catch {
        Log "netstat listener check failed: $($_.Exception.Message)" "WARN"
        return @()
    }
    finally {
        $p.Dispose()
    }

    foreach ($line in ($stdout -split "`r?`n")) {
        if ($line -notmatch '^\s*TCP\s+(\S+)\s+(\S+)\s+LISTENING\s+(\d+)\s*$') {
            continue
        }

        $localAddress = $Matches[1]
        $pidValue = [int]$Matches[3]

        $matchedPort = $null
        foreach ($port in $Ports) {
            if ($localAddress -match "[:\]]$port$") {
                $matchedPort = $port
                break
            }
        }

        if ($null -eq $matchedPort) {
            continue
        }

        $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue

        $items += [pscustomobject]@{
            Port = $matchedPort
            PID = $pidValue
            Process = if ($proc) { $proc.ProcessName } else { "unknown" }
            Path = if ($proc) {
                try { $proc.Path } catch { "" }
            } else { "" }
        }
    }

    return @($items)
}

function Stop-KnownWindowsLocalAIListeners {
    $listeners = @(Get-ListeningProcessInfo)

    foreach ($item in $listeners) {
        # WSL listeners normally disappear when the distro is terminated.
        # Only kill clearly recognizable native Local-AI leftovers here.
        $name = ($item.Process ?? "").ToLowerInvariant()
        $path = ($item.Path ?? "").ToLowerInvariant()

        $known =
            ($name -eq "ollama") -or
            ($name -eq "ollama app") -or
            ($name -eq "open-webui") -or
            ($path -match "open-webui")

        if ($known) {
            Log "Stopping native Windows listener on port $($item.Port): $($item.Process) PID $($item.PID)" "WARN"
            Stop-Process -Id $item.PID -Force -ErrorAction SilentlyContinue
        }
    }
}

function Close-StartConsole {
    # The dedicated Start PowerShell becomes a journal viewer after startup.
    # Once WSL is terminated that viewer is useless, so close only our own
    # start-console window. Never touch unrelated PowerShell processes.
    try {
        Get-Process pwsh -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Id -ne $PID -and
                $_.MainWindowTitle -eq "Local AI PowerShell - start"
            } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Stop-Stack {
    Log "Beginning VERIFIED Local AI shutdown..."

    Log "Closing Local AI start/log console before WSL termination..."
    Close-StartConsole
    Start-Sleep -Milliseconds 750

    $runningBefore = @(Get-RunningWslDistros)
    $ubuntuWasRunning = ($runningBefore -contains $Distro)

    if ($runningBefore.Count -gt 0) {
        Log ("Running WSL distros before stop: " + ($runningBefore -join ", "))
    }
    else {
        Log "No running WSL distros reported before stop."
    }

    if ($ubuntuWasRunning) {
        Log "Ubuntu is running. Capturing pre-stop state..."
        Write-ServiceSnapshot -Lines 40

        Log "Stopping Open WebUI, Ollama, and recognizable orphan processes..."
        $shutdown = Invoke-Linux -Root -IgnoreExitCode -Script @'
set +e

systemctl stop open-webui.service
systemctl stop ollama.service

pkill -TERM -f '[o]pen-webui.*serve' 2>/dev/null
pkill -TERM -f '[u]vx.*open-webui' 2>/dev/null
pkill -TERM -f '[o]llama serve' 2>/dev/null
sleep 1
pkill -KILL -f '[o]pen-webui.*serve' 2>/dev/null
pkill -KILL -f '[u]vx.*open-webui' 2>/dev/null
pkill -KILL -f '[o]llama serve' 2>/dev/null

echo "SERVICE_OPENWEBUI=$(systemctl is-active open-webui.service 2>/dev/null || true)"
echo "SERVICE_OLLAMA=$(systemctl is-active ollama.service 2>/dev/null || true)"
echo "PORTS_BEFORE_TERMINATE="
ss -ltnp 2>/dev/null | grep -E '(:3000|:11434)' || true
exit 0
'@

        if ($shutdown.StdOut) {
            Add-Content -LiteralPath $ServiceLog -Value $shutdown.StdOut.TrimEnd()
            Write-Host $shutdown.StdOut
        }
        if ($shutdown.StdErr) {
            Add-Content -LiteralPath $ServiceLog -Value ("[stop stderr]`r`n" + $shutdown.StdErr.TrimEnd())
        }
    }
    else {
        Log "Ubuntu is already stopped. Skipping Linux-side shutdown commands." "OK"
    }

    # Old Docker setup cleanup, exact legacy container only.
    $docker = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($docker) {
        try {
            $containerIds = @(
                & $docker.Source ps -q --filter "name=^/open-webui$" 2>$null |
                Where-Object { $_ }
            )
            foreach ($containerId in $containerIds) {
                Log "Stopping leftover Docker container open-webui ($containerId)..." "WARN"
                & $docker.Source stop $containerId *> $null
            }
        }
        catch {
            Log "Docker cleanup check failed: $($_.Exception.Message)" "WARN"
        }
    }

    if ($ubuntuWasRunning) {
        Log "Terminating WSL distro '$Distro'..."
        & wsl.exe --terminate $Distro *> $null

        if ($LASTEXITCODE -ne 0) {
            Log "wsl.exe --terminate returned exit code $LASTEXITCODE." "WARN"
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 500
            $distroStillRunning = (Get-RunningWslDistros) -contains $Distro
        }
        while ($distroStillRunning -and [DateTimeOffset]::UtcNow -lt $deadline)

        if ($distroStillRunning) {
            Log "Ubuntu survived targeted termination. Escalating to full WSL shutdown." "WARN"
            [void](Invoke-WslShutdownWithTimeout -TimeoutSeconds 6)

            $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 500
                $distroStillRunning = (Get-RunningWslDistros) -contains $Distro
            }
            while ($distroStillRunning -and [DateTimeOffset]::UtcNow -lt $deadline)
        }
    }

    $runningAfter = @(Get-RunningWslDistros)
    $distroStillRunning = ($runningAfter -contains $Distro)

    # If no WSL distro remains, explicitly tear down the WSL VM/forwarding
    # layer too. This reclaims VmmemWSL and helps remove stale localhost
    # forwarding listeners.
    if (-not $distroStillRunning -and $runningAfter.Count -eq 0) {
        Log "No WSL distros remain. Attempting best-effort WSL VM reclaim..."
        $reclaimCode = Invoke-WslShutdownWithTimeout -TimeoutSeconds 3
        if ($reclaimCode -eq 0) {
            Log "WSL VM reclaim completed." "OK"
        }
        elseif ($reclaimCode -eq 124) {
            Log "WSL VM reclaim timed out, but no distro is running. Continuing with endpoint verification." "WARN"
        }
        Start-Sleep -Milliseconds 500
    }
    elseif (-not $distroStillRunning -and $runningAfter.Count -gt 0) {
        Log ("Ubuntu stopped. Other WSL distros remain active: " + ($runningAfter -join ", ")) "WARN"
    }

    # Native Windows Ollama / old native Open WebUI can survive WSL.
    Stop-KnownWindowsLocalAIListeners

    Log "Verifying Open WebUI and Ollama are offline..."
    $endpointDeadline = [DateTimeOffset]::UtcNow.AddSeconds(6)
    $endpointAttempt = 0

    do {
        $endpointAttempt++
        $state = Get-LocalAIEndpointState

        Log ("Endpoint check #{0}: WebUI={1}, Ollama={2}" -f
            $endpointAttempt,
            $(if ($state.WebUI) { "reachable" } else { "offline" }),
            $(if ($state.Ollama) { "reachable" } else { "offline" }))

        if (-not $state.WebUI -and -not $state.Ollama) {
            break
        }

        Stop-KnownWindowsLocalAIListeners
        Start-Sleep -Milliseconds 350
    }
    while ([DateTimeOffset]::UtcNow -lt $endpointDeadline)

    $state = Get-LocalAIEndpointState
    Log "Collecting final Windows socket metadata..."
    $listeners = @(Get-ListeningProcessInfo)
    $relevantListeners = @(
        $listeners | Where-Object { $_.Port -in @(3000, 11434) }
    )

    # Purely informational socket details. A stale svchost forwarding stub does
    # not fail shutdown if neither actual HTTP endpoint responds.
    $stubListeners = @(
        $relevantListeners | Where-Object {
            ($_.Process -in @("svchost", "System", "WslService")) -and
            (($_.Port -eq 3000 -and -not $state.WebUI) -or
             ($_.Port -eq 11434 -and -not $state.Ollama))
        }
    )

    Write-Host ""
    Write-Host "Shutdown verification" -ForegroundColor Cyan
    Write-Host "---------------------"

    if ($distroStillRunning) {
        Write-Host "Ubuntu WSL : STILL RUNNING" -ForegroundColor Red
    }
    else {
        Write-Host "Ubuntu WSL : STOPPED" -ForegroundColor Green
    }

    if ($state.WebUI) {
        Write-Host "Open WebUI : STILL REACHABLE on :3000" -ForegroundColor Red
    }
    else {
        Write-Host "Open WebUI : OFFLINE" -ForegroundColor Green
    }

    if ($state.Ollama) {
        Write-Host "Ollama API : STILL REACHABLE on :11434" -ForegroundColor Red
    }
    else {
        Write-Host "Ollama API : OFFLINE" -ForegroundColor Green
    }

    if ($stubListeners.Count -gt 0) {
        foreach ($item in $stubListeners) {
            Write-Host ("Port {0}    : stale Windows forwarding stub ({1} PID {2}), backend is offline" -f $item.Port, $item.Process, $item.PID) -ForegroundColor Yellow
            Log ("Inactive forwarding stub: port {0}, process {1}, PID {2}" -f $item.Port, $item.Process, $item.PID) "WARN"
        }
    }

    # List genuinely suspicious listeners only.
    foreach ($item in $relevantListeners) {
        $isKnownStub = $stubListeners | Where-Object { $_.PID -eq $item.PID -and $_.Port -eq $item.Port }
        if (-not $isKnownStub) {
            Log ("Listener after stop: port {0}, process {1}, PID {2}, path {3}" -f $item.Port, $item.Process, $item.PID, $item.Path) "WARN"
        }
    }

    if ($distroStillRunning -or $state.WebUI -or $state.Ollama) {
        throw "Shutdown verification failed. One or more Local AI backends are still active."
    }

    Log "VERIFIED STOP: Ubuntu stopped; Open WebUI and Ollama endpoints are offline." "OK"
}

function Invoke-Health {
    Ensure-Ubuntu
    Ensure-Installed

    $r = Invoke-Linux -IgnoreExitCode -Script @'
"$HOME/.local/bin/local-ai-tools.py" health
'@
    Write-Host $r.StdOut
    if ($r.StdErr) { Write-Host $r.StdErr -ForegroundColor Yellow }
    return [int]$r.ExitCode
}

function Show-Status {
    [void](Invoke-Health)
}

function Show-Health {
    return (Invoke-Health)
}

function Show-Logs {
    Ensure-Ubuntu
    Ensure-Installed
    Follow-ServiceLogs
}

function Show-Tokens {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . Token Usage" `
        -Command '"$HOME/.local/bin/local-ai-tools.py" tokens --days 7; echo; read -p "Press Enter to close..."'
}

function Show-LiveTokens {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . Live Tokens" `
        -Command 'exec "$HOME/.local/bin/local-ai-tools.py" tokens --days 1 --live --interval 2'
}

function Show-GPU {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . nvitop" `
        -Command 'exec "$HOME/.local/bin/nvitop"'
}

function Show-Dashboard {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . Local AI Dashboard" `
        -Command 'exec "$HOME/.local/bin/local-ai-tools.py" dashboard'
}

function Manage-Models {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . Ollama Models" `
        -Command 'exec "$HOME/.local/bin/local-ai-tools.py" manage-models'
}

function Run-Benchmark {
    Ensure-Ubuntu
    Ensure-Installed

    $ctx = 8192
    $ctxText = Read-Host "Context size [8192]"
    if (-not [string]::IsNullOrWhiteSpace($ctxText)) {
        if ($ctxText -notmatch '^\d+$') { throw "Context size must be an integer." }
        $ctx = [int]$ctxText
    }
    if ($ctx -lt 512 -or $ctx -gt 262144) { throw "Context must be between 512 and 262144." }

    $runs = 3
    $runsText = Read-Host "Runs [3]"
    if (-not [string]::IsNullOrWhiteSpace($runsText)) {
        if ($runsText -notmatch '^\d+$') { throw "Runs must be an integer." }
        $runs = [int]$runsText
    }
    if ($runs -lt 1 -or $runs -gt 20) { throw "Runs must be between 1 and 20." }

    $installed = Invoke-Linux -IgnoreExitCode -Script @'
"$HOME/.local/bin/local-ai-tools.py" models
'@
    Write-Host ""
    Write-Host $installed.StdOut
    Write-Host ""

    $chosen = Read-Host "Model [$Model]"
    if ([string]::IsNullOrWhiteSpace($chosen)) { $chosen = $Model }
    $modelB64 = ConvertTo-Utf8Base64 $chosen

    # Base64 keeps the model name out of both the PowerShell and Bash quoting
    # layers. Only validated integers are interpolated directly.
    $cmd = "MODEL=`$(printf '%s' '$modelB64' | base64 -d); `"`$HOME/.local/bin/local-ai-tools.py`" benchmark --model `"`$MODEL`" --num-ctx $ctx --runs $runs; echo; read -p `"Press Enter to close...`""
    Open-Ubuntu -Title "Ubuntu | LLM Benchmark" -Command $cmd
}

function Show-BenchmarkHistory {
    Ensure-Ubuntu
    Open-Ubuntu `
        -Title "Ubuntu . Benchmark History" `
        -Command '"$HOME/.local/bin/local-ai-tools.py" benchmark-history --limit 40; echo; read -p "Press Enter to close..."'
}

function Probe-WebUI {
    Ensure-Ubuntu

    Write-Host ""
    Write-Host "Open WebUI HTTP probes" -ForegroundColor Cyan
    Write-Host "----------------------"

    $probe = Get-WebUIExtendedProbe
    Write-Host ("/health    : {0}" -f $probe.Health)
    Write-Host ("/           : {0}" -f $probe.Root)
    Write-Host ("/ready     : {0}  (diagnostic only)" -f $probe.Ready)
    Write-Host ("/health/db : {0}  (diagnostic only)" -f $probe.Database)

    Write-Host ""
    Write-Host "Service state" -ForegroundColor Cyan
    Write-Host "-------------"
    $status = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl status open-webui.service ollama.service --no-pager -l 2>&1 || true
echo
echo "=== RECENT OPEN WEBUI JOURNAL ==="
journalctl -u open-webui.service -n 120 --no-pager -o short-iso 2>&1 || true
'@
    Write-Host $status.StdOut

    if ($probe.Root -ge 500) {
        Write-Host ""
        Write-Host "The backend is returning a real 5xx on the UI root." -ForegroundColor Red
    }
    elseif ($probe.Health -eq 0 -or $probe.Root -eq 0) {
        Write-Host ""
        Write-Host "Open WebUI is not reachable right now." -ForegroundColor Yellow
    }
}

function Create-Diagnostics {
    Ensure-Ubuntu

    $diag = Join-Path $LogDir "diagnostics-$Stamp.txt"
    $windows = @(
        "LOCAL AI DIAGNOSTICS",
        "Generated: $(Get-Date -Format o)",
        "PowerShell: $($PSVersionTable.PSVersion)",
        "Build: $LocalAIBuild",
        "Latest service capture: $ServiceLog",
        "",
        "=== WSL VERSION ===",
        (& wsl.exe --version 2>&1 | Out-String),
        "",
        "=== WSL DISTROS ===",
        (& wsl.exe -l -v 2>&1 | Out-String),
        "",
        "=== UBUNTU WINDOWS LAUNCHER ===",
        ((Get-UbuntuLauncher) ?? "NOT FOUND")
    )

    $linux = Invoke-Linux -Root -IgnoreExitCode -Script @'
echo "=== HEALTH CHECK ==="
WEBUI_USER="$(systemctl show open-webui.service -p User --value 2>/dev/null || true)"
if [ -n "$WEBUI_USER" ]; then
    WEBUI_HOME="$(getent passwd "$WEBUI_USER" | cut -d: -f6)"
    if [ -n "$WEBUI_HOME" ] && [ -x "$WEBUI_HOME/.local/bin/local-ai-tools.py" ]; then
        runuser -u "$WEBUI_USER" -- "$WEBUI_HOME/.local/bin/local-ai-tools.py" health 2>&1 || true
    else
        echo "Could not locate local-ai-tools.py for service user $WEBUI_USER"
    fi
else
    echo "open-webui.service has no configured User"
fi
echo

echo "=== OPEN WEBUI HTTP PROBES ==="
for endpoint in /health /ready /health/db /; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:3000$endpoint" 2>/dev/null || true)"
    [ -n "$code" ] || code=000
    echo "$endpoint -> $code"
done
echo

echo "=== SYSTEM ==="
date --iso-8601=seconds
uname -a
cat /etc/os-release 2>/dev/null || true
echo

echo "=== MEMORY / DISK ==="
free -h
df -h / 2>/dev/null || true
echo

echo "=== GPU ==="
nvidia-smi 2>&1 || true
echo

echo "=== SERVICES ==="
systemctl status open-webui.service ollama.service --no-pager -l 2>&1 || true
echo

echo "=== SERVICE ACCOUNTING ==="
systemctl show open-webui.service -p MainPID -p MemoryCurrent -p MemoryPeak -p CPUUsageNSec -p TasksCurrent 2>&1 || true
echo

echo "=== PORTS ==="
ss -ltnp 2>&1 | grep -E '(:3000|:11434)' || true
echo

echo "=== TOP MEMORY PROCESSES ==="
ps aux --sort=-%mem | head -20
echo

echo "=== OPEN WEBUI JOURNAL ==="
journalctl -u open-webui.service -n 150 --no-pager -o short-iso 2>&1 || true
echo

echo "=== OLLAMA JOURNAL ==="
journalctl -u ollama.service -n 150 --no-pager -o short-iso 2>&1 || true
'@

    ($windows -join "`r`n") | Set-Content -LiteralPath $diag
    Add-Content -LiteralPath $diag -Value "`r`n=== UBUNTU ===`r`n"
    Add-Content -LiteralPath $diag -Value $linux.StdOut
    if ($linux.StdErr) {
        Add-Content -LiteralPath $diag -Value "`r`n=== UBUNTU STDERR ===`r`n$($linux.StdErr)"
    }

    Log "Diagnostics saved: $diag" "OK"
    Start-Process notepad.exe $diag
}

function Update-Stack {
    Ensure-Ubuntu
    Ensure-Installed

    $active = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl is-active --quiet open-webui.service
'@
    $wasActive = ($active.ExitCode -eq 0)

    if ($wasActive) {
        Log "Open WebUI was running. Stopping it for a consistent backup/update..."
        Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl stop open-webui.service >/dev/null 2>&1 || true
'@ | Out-Null
    }
    else {
        Log "Open WebUI was already stopped. It will remain stopped after the update."
    }

    try {
        $backup = Invoke-Linux -Script @'
set -euo pipefail
STAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
DIR="$HOME/.local/state/local-ai/backups"
mkdir -p "$DIR"

if [ -d "$HOME/.open-webui" ]; then
    OUT="$DIR/open-webui-before-update-$STAMP.tar.gz"
    tar -C "$HOME" -czf "$OUT" .open-webui
    tar -tzf "$OUT" >/dev/null
    printf 'BACKUP=%s\n' "$OUT"
else
    echo "BACKUP=none (data directory does not exist yet)"
fi

export PATH="$HOME/.local/bin:$PATH"
export UV_TOOL_BIN_DIR="$HOME/.local/bin"

if command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
elif [ -x "$HOME/.local/bin/uv" ]; then
    UV="$HOME/.local/bin/uv"
else
    echo "uv not found" >&2
    exit 127
fi

if [ -x "$HOME/.local/bin/open-webui" ]; then
    "$UV" tool upgrade open-webui
else
    "$UV" tool install --python 3.11 open-webui
fi

if [ -x "$HOME/.local/bin/nvitop" ]; then
    "$UV" tool upgrade nvitop
else
    "$UV" tool install nvitop
fi
'@
        Write-Host $backup.StdOut
    }
    catch {
        if ($wasActive) {
            Log "Update failed. Attempting to bring the previous service back up..." "WARN"
            Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl reset-failed open-webui.service >/dev/null 2>&1 || true
systemctl start open-webui.service >/dev/null 2>&1 || true
'@ | Out-Null
        }
        throw
    }

    if ($wasActive) {
        Log "Restarting Open WebUI because it was running before the update..."
        $restart = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl reset-failed open-webui.service >/dev/null 2>&1 || true
systemctl start open-webui.service
'@

        if ($restart.ExitCode -ne 0 -or -not (Wait-Health -Seconds 300)) {
            $journal = Invoke-Linux -Root -IgnoreExitCode -Script @'
systemctl status open-webui.service --no-pager -l 2>&1 || true
echo
journalctl -u open-webui.service -n 200 --no-pager -o short-iso 2>&1 || true
'@
            Write-Host $journal.StdOut
            throw "Update completed, but Open WebUI did not recover cleanly. Use the backup path printed above if needed."
        }

        Log "Open WebUI + nvitop updated and health verified." "OK"
    }
    else {
        Log "Open WebUI + nvitop updated. Services were left stopped because they were stopped before the update." "OK"
    }
}

function Menu {
    while ($true) {
        Clear-Host
        Write-Host "================================================" -ForegroundColor DarkCyan
        Write-Host "                LOCAL AI CONTROL" -ForegroundColor Cyan
        Write-Host "================================================" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host " Runtime" -ForegroundColor Cyan
        Write-Host "   1  Start"
        Write-Host "   2  Stop + reclaim WSL RAM"
        Write-Host "   3  Restart"
        Write-Host "   4  Health check"
        Write-Host ""
        Write-Host " Models + Performance" -ForegroundColor Cyan
        Write-Host "   5  Model manager"
        Write-Host "   6  Benchmark model"
        Write-Host "   7  Benchmark history"
        Write-Host ""
        Write-Host " Usage + Monitoring" -ForegroundColor Cyan
        Write-Host "   8  Token report"
        Write-Host "   9  Live token counter"
        Write-Host "   G  GPU monitor (nvitop)"
        Write-Host "   M  Combined dashboard"
        Write-Host "   L  Live service logs"
        Write-Host ""
        Write-Host " Maintenance" -ForegroundColor Cyan
        Write-Host "   P  Probe Open WebUI HTTP + logs"
        Write-Host "   D  Diagnostic bundle"
        Write-Host "   U  Update Open WebUI + nvitop"
        Write-Host "   I  Install / repair"
        Write-Host "   Q  Quit"
        Write-Host ""

        $choice = (Read-Host "Choose").Trim().ToUpperInvariant()

        try {
            switch ($choice) {
                "1" { Start-Stack }
                "2" { Stop-Stack; Read-Host "Press Enter" | Out-Null }
                "3" { Stop-Stack; Start-Sleep 2; Start-Stack }
                "4" { [void](Show-Health); Read-Host "Press Enter" | Out-Null }
                "5" { Manage-Models }
                "6" { Run-Benchmark }
                "7" { Show-BenchmarkHistory }
                "8" { Show-Tokens }
                "9" { Show-LiveTokens }
                "G" { Show-GPU }
                "M" { Show-Dashboard }
                "L" { Show-Logs }
                "P" { Probe-WebUI; Read-Host "Press Enter" | Out-Null }
                "D" { Create-Diagnostics }
                "U" { Update-Stack; Read-Host "Press Enter" | Out-Null }
                "I" { Install-Stack; Read-Host "Press Enter" | Out-Null }
                "Q" { return }
                default { Write-Host "Unrecognized choice: $choice" -ForegroundColor Yellow; Start-Sleep 1 }
            }
        }
        catch {
            Log $_.Exception.Message "ERROR"
            Write-Host ""
            Read-Host "Press Enter to return to menu" | Out-Null
        }
    }
}

$ExitCode = 0
try {
    Log "Action: $Action"
    Log "Build: $LocalAIBuild"
    Log "PowerShell: $($PSVersionTable.PSVersion)"
    Log "Controller log: $WindowsLog"

    switch ($Action) {
        "menu"             { Menu }
        "install"          { Install-Stack }
        "start"            { Start-Stack }
        "stop"             { Stop-Stack }
        "restart"          { Stop-Stack; Start-Sleep 2; Start-Stack }
        "status"           { Show-Status }
        "health"           { $ExitCode = Show-Health }
        "logs"             { Show-Logs }
        "tokens"           { Show-Tokens }
        "livetokens"       { Show-LiveTokens }
        "gpu"              { Show-GPU }
        "dashboard"        { Show-Dashboard }
        "models"           { Manage-Models }
        "benchmark"        { Run-Benchmark }
        "benchmarkhistory" { Show-BenchmarkHistory }
        "diagnostics"      { Create-Diagnostics }
        "probe"            { Probe-WebUI }
        "update"           { Update-Stack }
    }
}
catch {
    $ExitCode = 1
    Log $_.Exception.Message "ERROR"
    Write-Host ""
    Write-Host "Controller log:" -ForegroundColor Yellow
    Write-Host "  $WindowsLog"
    Write-Host $_.Exception.Message -ForegroundColor Red
}

exit $ExitCode
