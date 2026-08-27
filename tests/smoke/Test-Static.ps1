$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Expected = "v2.0.0-beta.4.1-20260826"
$build = (Get-Content -LiteralPath (Join-Path $Root "BUILD-ID.txt") -Raw).Trim()
if ($build -ne $Expected) { throw "BUILD-ID mismatch." }
$config = Get-Content -LiteralPath (Join-Path $Root "config\default.json") -Raw | ConvertFrom-Json
if ([string]$config.build -ne $Expected) { throw "default.json build mismatch." }
if ([int]$config.model.context -ne 65536) { throw "Default agent context is not 65,536." }
if ([string]$config.ollama.kv_cache_type -ne "f16" -or [bool]$config.ollama.flash_attention) { throw "Beta4 must default to conservative f16 KV with Flash Attention opt-in." }

$controller = Get-Content -LiteralPath (Join-Path $Root "powershell\Local-AI.ps1") -Raw
foreach ($needle in @("Start-Profile","Start-Pi","Stop-Pi","Stop-All","WebUI-Probe","Diagnostics","piresume","PI_CODING_AGENT_DIR","PI_CODING_AGENT_SESSION_DIR","Resolve-PiThinking","Resolve-PiTools","read,grep,find,ls","-Consecutive 2")) {
    if (-not $controller.Contains($needle)) { throw "Controller is missing $needle." }
}
if ($controller.Contains("pkill pi") -or $controller.Contains("~/.pi/agent")) { throw "Controller contains unsafe/legacy Pi targeting." }
if ($controller -match '-- wslpath -u \$WindowsPath') { throw "Controller passes Windows paths directly through wsl.exe to wslpath." }
if (-not $controller.Contains('bash -lc ("wslpath -u -- " + $quotedPath)')) { throw "Controller does not shell-quote Windows paths before calling wslpath." }
if (-not $controller.Contains('$script.Replace("`r`n", "`n").Replace("`r", "`n")')) { throw "Controller does not normalize the generated Pi script to LF." }
if (-not $controller.Contains('$Command.Replace("`r`n", "`n").Replace("`r", "`n")')) { throw "Controller WSL command helpers do not normalize multiline commands to LF." }
if (-not $controller.Contains('base64 -d | bash')) { throw "Controller WSL command helpers do not use encoded shell transport." }
if (-not $controller.Contains('exec bash <(printf %s')) { throw "Controller Pi launcher does not preserve terminal stdin while decoding its script." }
if (-not $controller.Contains('Get-Command wt.exe') -or -not $controller.Contains("'-w'") -or -not $controller.Contains("'new'")) { throw "Controller does not launch Pi in a dedicated Windows Terminal when available." }

$setup = Get-Content -LiteralPath (Join-Path $Root "powershell\Setup-Local-AI.ps1") -Raw
foreach ($needle in @("Merge-InstallState","config\models.json","config\settings.json","OLLAMA_CONTEXT_LENGTH","OLLAMA_FLASH_ATTENTION","OLLAMA_KV_CACHE_TYPE","ps -p 1 -o comm=","Assert-ServicePortOwnership",".local/share/local-ai/pi-runtime",".local/share/local-ai/pi-agent")) {
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
