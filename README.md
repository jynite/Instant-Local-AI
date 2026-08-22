# Local AI v1

A Windows + WSL launcher for running Ollama and Open WebUI locally without turning setup into a whole side quest.

It handles startup, shutdown, logging, health checks, GPU monitoring, token usage, benchmarks, diagnostics, and Open WebUI service management.

## Requirements

You need:

- Windows 11
- WSL2
- Ubuntu installed in WSL
- systemd enabled in Ubuntu
- Ollama installed inside Ubuntu
- `ollama.service` available through systemd
- `uv` installed inside Ubuntu
- PowerShell 7
- `winget` if you want the launcher to install PowerShell 7 automatically

An NVIDIA GPU is recommended. CPU-only Ollama can still work, but the GPU and VRAM monitoring features are built around NVIDIA.

The default WSL distro name is `Ubuntu`.

## Prerequisites

Open Ubuntu and make sure these work:

```bash
systemctl is-system-running
ollama --version
uv --version
```

If systemd is not enabled, put this in `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then run this in Windows PowerShell:

```powershell
wsl --shutdown
```

Open Ubuntu again after that.

If you still need Ollama or `uv`:

```bash
curl -fsSL https://ollama.com/install.sh | sh
curl -LsSf https://astral.sh/uv/install.sh | sh
```

## Install

Do not run the BAT files from inside the ZIP. Extract everything first.

Then run:

1. `VERIFY-BUILD.bat`
2. `Install-Local-AI.bat`
3. `Start-Local-AI.bat`

The installer sets up Open WebUI, `nvitop`, the utility script, `open-webui.service`, and persistent journald logging.

Your Open WebUI data lives at:

```text
~/.open-webui
```

Open WebUI runs at:

```text
http://localhost:3000
```

## Start

Run:

```text
Start-Local-AI.bat
```

A PowerShell console and an Ubuntu window will open.

Keep the Ubuntu window open while Local AI is running. It keeps the WSL runtime alive.

The browser opens automatically once Open WebUI and Ollama are ready.

## Stop

Run:

```text
Stop-Local-AI.bat
```

Stop verifies that Ubuntu is stopped, Open WebUI is offline, and the Ollama API is offline.

If no other WSL distro is running, it also tries to reclaim the WSL VM.

A successful stop closes its PowerShell window automatically.

## Configuration

Defaults:

```text
WSL distro: Ubuntu
Model: huihui_ai/Qwen3.8-abliterated
Open WebUI: http://localhost:3000
```

Override the distro or default model with Windows environment variables:

```powershell
setx LOCAL_AI_DISTRO "Ubuntu"
setx LOCAL_AI_MODEL "your-ollama-model"
```

Open a new shell after using `setx`.

You can still select any installed Ollama model inside Open WebUI.

## Launchers

| File | Purpose |
| --- | --- |
| `Local-AI.bat` | Main menu |
| `Install-Local-AI.bat` | Install or repair the stack |
| `Start-Local-AI.bat` | Start Local AI |
| `Stop-Local-AI.bat` | Stop Local AI and verify shutdown |
| `Restart-Local-AI.bat` | Restart the stack |
| `Health-Check.bat` | Run health checks |
| `Live-Logs.bat` | Follow Open WebUI and Ollama logs |
| `Diagnostics.bat` | Generate diagnostics |
| `Benchmark.bat` | Benchmark an Ollama model |
| `WebUI-Probe.bat` | Probe Open WebUI endpoints |
| `VERIFY-BUILD.bat` | Verify release files match |
| `DEBUG-Local-AI.bat` | Keep the bootstrap window open for debugging |

## Logs

Controller logs:

```text
logs/controller-*.log
```

Service logs:

```text
logs/services-*.log
```

Journald:

```bash
journalctl -u open-webui.service
journalctl -u ollama.service
```

Open WebUI audit metadata:

```text
~/.open-webui/audit.log
```

## Token usage

The utility suite reads token usage from the Open WebUI database when usage metadata exists.

The main menu includes token totals, live token usage, benchmark history, model state, and GPU or VRAM state.

Token counts depend on what the model or provider writes into Open WebUI. Missing usage metadata cannot be reconstructed perfectly.

## Updating

The update flow backs up `~/.open-webui` before upgrading Open WebUI when that data directory exists.

The launcher is not supposed to wipe your chats or settings.

## Troubleshooting

If startup fails:

```text
Diagnostics.bat
Live-Logs.bat
```

If Open WebUI loads but detection looks wrong:

```text
WebUI-Probe.bat
```

If WSL is being weird:

```powershell
wsl --list --running
wsl --shutdown
```

Then start Local AI again.

## License

MIT.
