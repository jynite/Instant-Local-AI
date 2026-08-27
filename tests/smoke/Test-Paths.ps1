$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Required = @(
    "Local-AI.bat","Setup-Local-AI.bat","Start-Local-AI.bat","Stop-Local-AI.bat","Restart-Local-AI.bat",
    "Status-Local-AI.bat","Health-Check.bat","Live-Logs.bat","Benchmark.bat","Benchmark-History.bat",
    "Tokens.bat","Live-Tokens.bat","Dashboard.bat","Diagnostics.bat","WebUI-Probe.bat",
    "Start-WebUI.bat","Start-Pi.bat","Start-Both.bat","Start-Ollama.bat","Resume-Pi.bat",
    "Open-WSL-Runtime.bat","Manage-Models.bat","Repair-Local-AI.bat","Update-Local-AI.bat",
    "Uninstall-Local-AI.bat","VERIFY-BUILD.bat","DEBUG-Local-AI.bat",
    "powershell\Local-AI.ps1","powershell\Setup-Local-AI.ps1","powershell\Find-Pwsh.ps1","powershell\Repair-Local-AI.ps1",
    "powershell\Update-Local-AI.ps1","powershell\Uninstall-Local-AI.ps1",
    "config\default.json","config\models.json","config\settings.json","extension\local-ai.ts","wsl\local-ai-tools.py"
)
$Missing = foreach ($item in $Required) { if (-not (Test-Path (Join-Path $Root $item))) { $item } }
if ($Missing) { throw "Missing files: $($Missing -join ', ')" }

$Parser = [System.Management.Automation.Language.Parser]
$ParseFailures = New-Object System.Collections.Generic.List[string]
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $Root "powershell") -Filter "*.ps1" -File) {
    $tokens = $null
    $errors = $null
    $null = $Parser::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach ($error in $errors) { $ParseFailures.Add("$($file.Name): $($error.Message)") }
}
if ($ParseFailures.Count -gt 0) { throw "PowerShell parse failures: $($ParseFailures -join ' | ')" }
Write-Host "Path and PowerShell parser smoke test passed."
