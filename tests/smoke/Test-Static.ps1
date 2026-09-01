$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Expected = "v2.0.0-beta.4.1-20260826"
$build = (Get-Content -LiteralPath (Join-Path $Root "BUILD-ID.txt") -Raw).Trim()
if ($build -ne $Expected) { throw "BUILD-ID mismatch." }
$config = Get-Content -LiteralPath (Join-Path $Root "config\default.json") -Raw | ConvertFrom-Json
if ([string]$config.build -ne $Expected) { throw "default.json build mismatch." }
if ([int]$config.model.context -ne 65536) { throw "Default agent context is not 65,536." }
if ([string]$config.ollama.kv_cache_type -ne "f16" -or [bool]$config.ollama.flash_attention) { throw "Beta4 must default to conservative f16 KV with Flash Attention opt-in." }

$controller = Get-Content -LiteralPath (Join-Path $Root "powershell\Local-AI.ps1") -Raw
foreach ($needle in @("Start-Profile","Start-Pi","Stop-Pi","Stop-All","WebUI-Probe","Diagnostics","Reset-WebUICredentials","Get-RuntimeSnapshot","resetwebuicredentials","snapshot","PASSWORD_UPDATED",'$db.backup-',"piresume","PI_CODING_AGENT_DIR","PI_CODING_AGENT_SESSION_DIR","Resolve-PiThinking","Resolve-PiTools","Get-SelectedModelCapabilities","read,grep,find,ls","-Consecutive 2")) {
    if (-not $controller.Contains($needle)) { throw "Controller is missing $needle." }
}
if ($controller.Contains("pkill pi") -or $controller.Contains("~/.pi/agent")) { throw "Controller contains unsafe/legacy Pi targeting." }
if (-not $controller.Contains('} 2>/dev/null | grep -Fxq')) { throw "Managed Pi detection does not suppress unreadable proc entries." }
if ($controller -match '-- wslpath -u \$WindowsPath') { throw "Controller passes Windows paths directly through wsl.exe to wslpath." }
if (-not $controller.Contains('bash -lc ("wslpath -u -- " + $quotedPath)')) { throw "Controller does not shell-quote Windows paths before calling wslpath." }
if (-not $controller.Contains('$script.Replace("`r`n", "`n").Replace("`r", "`n")')) { throw "Controller does not normalize the generated Pi script to LF." }
if (-not $controller.Contains('$Command.Replace("`r`n", "`n").Replace("`r", "`n")')) { throw "Controller WSL command helpers do not normalize multiline commands to LF." }
if (-not $controller.Contains('base64 -d | bash')) { throw "Controller WSL command helpers do not use encoded shell transport." }
if (-not $controller.Contains('exec bash <(printf %s')) { throw "Controller Pi launcher does not preserve terminal stdin while decoding its script." }
if (-not $controller.Contains('$inputPayload | & wsl.exe') -or -not $controller.Contains('exec bash <(printf %s ''$encodedScript'' | base64 -d)')) { throw "Credential recovery does not preserve secure stdin while decoding its script." }
if (-not $controller.Contains('Get-Command wt.exe') -or -not $controller.Contains("'-w'") -or -not $controller.Contains("'new'") -or -not $controller.Contains('$quotedPwsh')) { throw "Controller does not launch Pi in a dedicated Windows Terminal when available." }
if (-not $controller.Contains('StatusCode -ge 200') -or -not $controller.Contains('Invoke-Helper "health" -IgnoreExitCode')) { throw "Controller health probes do not distinguish HTTP failures or preserve useful health output." }
$uiController = Get-Content -LiteralPath (Join-Path $Root "ui\LocalAIController.py") -Raw
if ($uiController.Contains('"start": "Start-Local-AI.bat"')) { throw "QML controller must not recursively launch Start-Local-AI.bat." }
if (-not $uiController.Contains('errorOccurred') -or -not $uiController.Contains('quiet_runner.py')) { throw "QML controller lacks hidden-runner failure handling." }
foreach ($needle in @("activityChanged","Syncing runtime state","_power_shell_args","_overlay_pending","def cancel","_extract_snapshot","_consume_ollama_auto_start","auto_start_ollama=True","operationState","recentActivity","resetWebUICredentials","QQuickStyle.setStyle","CREATE_NO_WINDOW")) {
    if (-not $uiController.Contains($needle)) { throw "QML controller is missing $needle." }
}
foreach ($needle in @("Invoke-LifecycleMutation","Normalize-ProcessStamp","[object]`$ExpectedStart",'Get-Date -Format "yyyy-MM-dd_HH-mm-ss"','+ $PID + ".log"')) {
    if (-not $controller.Contains($needle)) { throw "Controller lifecycle safety is missing $needle." }
}
if ($controller -match '\[string\]\$(?:oldState|state)\.(?:keepalive_start|pi_window_start)') { throw "Controller culture-formats a persisted process timestamp." }
foreach ($needle in @("QLockFile","hud.lock","tryLock(100)")) {
    if (-not $uiController.Contains($needle)) { throw "QML controller single-instance guard is missing $needle." }
}

$runner = Get-Content -LiteralPath (Join-Path $Root "ui\quiet_runner.py") -Raw
if (-not $runner.Contains('JYNERATION_NONINTERACTIVE')) { throw "Quiet runner does not mark batch commands as non-interactive." }
$qml = Get-Content -LiteralPath (Join-Path $Root "ui\Main.qml") -Raw
foreach ($needle in @("Drawer","ComboBox","currentModelIndex","Services and model selection in one place.","Reset WebUI login","SequentialAnimation","NumberAnimation","controllerRef.cancel","controllerRef.resetWebUICredentials")) {
    if (-not $qml.Contains($needle)) { throw "QML is missing $needle." }
}
if ($qml.Contains('objectName: "ModelsPage"') -or $qml.Contains('label: "Models"')) { throw "QML still contains the redundant Models page." }
if ($qml.Contains('text: "BETA 4.1"') -or $qml.Contains('text: "v2.0.0 beta 4.1"')) { throw "QML still exposes an internal beta build suffix." }
if (([regex]::Matches($qml,'(?m)^\s*TextArea\s*\{')).Count -ne 1) { throw "QML must have exactly one shared activity console." }
$brandLauncher = Get-Content -LiteralPath (Join-Path $Root "JYNERATION.bat") -Raw
if (-not $brandLauncher.Contains('--reset-webui') -or -not $brandLauncher.Contains('Reset-WebUI-Credentials.bat')) { throw "JYNERATION launcher does not expose credential recovery." }

$setup = Get-Content -LiteralPath (Join-Path $Root "powershell\Setup-Local-AI.ps1") -Raw
foreach ($needle in @("Merge-InstallState","Ensure-WindowsPython","Python.Python.3.13","--upgrade","--user","System Python is not writable","PySide6","pythonw.exe","apache2-utils","config\models.json","config\settings.json","OLLAMA_CONTEXT_LENGTH","OLLAMA_FLASH_ATTENTION","OLLAMA_KV_CACHE_TYPE","ps -p 1 -o comm=","Assert-ServicePortOwnership",".local/share/local-ai/pi-runtime",".local/share/local-ai/pi-agent")) {
    if (-not $setup.Contains($needle)) { throw "Setup is missing $needle." }
}
if ($setup.Contains("npm install -g") -or $setup.Contains("~/.pi/agent")) { throw "Setup contains legacy/global Pi install behavior." }
if ($setup -match '-- wslpath -u \$Path') { throw "Setup passes Windows paths directly through wsl.exe to wslpath." }
if (-not $setup.Contains('bash -lc ("wslpath -u -- " + $quotedPath)')) { throw "Setup does not shell-quote Windows paths before calling wslpath." }
if (-not $setup.Contains('$Script.Replace("`r`n", "`n").Replace("`r", "`n")')) { throw "Setup does not normalize transported Bash scripts to LF." }
if (-not $setup.Contains('*/pi-coding-agent/*')) { throw "Setup does not distinguish the Pi coding agent from unrelated system pi executables." }
if ($setup.Contains("awk '{print ``$1}'")) { throw "Setup model parsing still relies on a cross-shell awk `$1 expression." }

$update = Get-Content -LiteralPath (Join-Path $Root "powershell\Update-Local-AI.ps1") -Raw
if ($update.Contains("pgrep -af '[p]i") -or -not $update.Contains("LOCAL_AI_SESSION_ID")) { throw "Update does not isolate Local AI Pi process checks." }
Write-Host "Static smoke test passed."
