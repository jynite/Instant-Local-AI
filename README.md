# JYNERATION — Ollama Control HUD

JYNERATION is a Windows + WSL2 control HUD for Ollama, Open WebUI, and Pi.
The internal runtime remains Local AI v2 beta4.1; JYNERATION is the user-facing product identity.

The beta UI is built as a dark operator console: one branded surface for
runtime status, model selection, lifecycle commands, diagnostics, and release
credits.

It is built around one idea: install the stack once, then choose whether you want the Web UI, the coding agent, both, or only the model API.

## Modes

`Web UI` runs Ollama + Open WebUI.

`Pi Agent` runs Ollama + Pi.

`Resume Pi` opens Pi with its most recent saved session.

`Both` runs Ollama + Open WebUI + Pi.

`Ollama Only` runs only the model backend.

`Custom` asks which frontends to start.

## Requirements

- Windows 11
- x64
- WSL2
- Ubuntu
- PowerShell 7
- Python 3.10+ and PySide6 for the HUD (installed by setup)
- internet access during setup
- enough RAM and disk space for the model you select
- an NVIDIA GPU is recommended, but the launcher does not require one

`Setup-Local-AI.bat` installs or repairs the normal prerequisites instead of expecting you to do the dependency hunt yourself.

## Install

Extract the repo first. Do not run the BAT files from inside the ZIP.

Run:

```text
VERIFY-BUILD.bat
Setup-Local-AI.bat
```

Setup handles:

- PowerShell 7
- WSL and Ubuntu
- WSL2 conversion when needed
- systemd
- Linux prerequisites, including the local Open WebUI password-recovery tool
- Node.js when Pi is enabled
- Windows Python 3.10+ and PySide6 for the HUD (Python 3.13 is installed when missing)
- Ubuntu Python 3 and pip/venv tooling
- uv when Open WebUI is enabled
- Ollama
- Pi when enabled
- Open WebUI when enabled
- Local AI helper tooling
- Pi's Ollama provider configuration
- the `local_ai_status` Pi extension
- optional model download
- smoke tests

Ubuntu package-manager output is streamed directly into the setup window. A Linux sudo prompt is not used for Local AI's root-side installer operations because Windows launches those WSL commands as root explicitly.

If Windows or Ubuntu needs a restart/first-run setup, run `Setup-Local-AI.bat` again afterward.

## Launchers

```text
JYNERATION.bat --about
JYNERATION.bat --diagnostics
JYNERATION.bat --reset-webui
About.bat
Local-AI.bat
Start-Local-AI.bat
Start-UI.bat
Start-WebUI.bat
Start-Pi.bat
Resume-Pi.bat
Start-Both.bat
Start-Ollama.bat
Stop-Local-AI.bat
Restart-Local-AI.bat
Reset-WebUI-Credentials.bat
Status-Local-AI.bat
Health-Check.bat
Manage-Models.bat
List-Models.bat
Tokens.bat
Live-Tokens.bat
Dashboard.bat
Benchmark.bat
Benchmark-History.bat
Live-Logs.bat
WebUI-Probe.bat
Diagnostics.bat
Open-WSL-Runtime.bat
DEBUG-Local-AI.bat
```

`Start-Local-AI.bat` uses the profile saved during setup.

`Status-Local-AI.bat` is intentionally side-effect free. It does not start Ubuntu merely to answer whether the stack is running.

`Start-Local-AI.bat` opens the QML control center when Python and PySide6 are available. The HUD starts Ollama automatically, then loads installed models into the Runtime page selector. The control center is the preferred beta interface for lifecycle actions, model selection, service status, and logs. `Local-AI.bat` remains the PowerShell menu fallback, and `Start-UI.bat` launches the QML interface directly.

The QML UI is a thin controller over the tested PowerShell controller; it does not duplicate service-management logic. A single runtime snapshot keeps services and models synchronized. On initial HUD load, that snapshot starts Ollama only when it is not already running. Model selection lives beside service state on the Runtime page rather than in a separate page. UI actions run through `ui/quiet_runner.py`, report running, reconciling, success, failure, and canceled states, and keep raw output in one shared activity drawer instead of opening blank helper consoles. Long-running live views expose a non-blocking Cancel control that stops only the HUD-launched command tree. The batch files remain the command-line recovery path if the UI is unavailable.

Only one HUD instance runs at a time. Lifecycle mutations are serialized across the HUD and batch launchers, so accidental double-clicks or simultaneous commands reuse the tracked WSL keepalive instead of creating competing controller state.

The `About / Credits` page in the QML HUD and `About.bat` show the release
identity without contacting a remote service. `JYNERATION.bat --about` is the
short CLI form, while `JYNERATION.bat --diagnostics` runs the existing
diagnostics bundle.

### QML control center

The UI requires Python 3.10+ and PySide6. Install PySide6 for the active Python interpreter if needed:

```text
python -m pip install PySide6
```

The source lives under `ui/` and consists of a PySide6 process bridge plus a Qt Quick/QML presentation layer.

## WSL lifetime

Open WebUI and Ollama are Linux services. WSL can shut a distro down when there is no active Windows-side client, even while Linux services exist.

For Web UI, Both, and Ollama-only profiles, Local AI keeps the Ubuntu runtime alive with a hidden, tracked WSL process. No blank Ubuntu terminal is opened by the controller; the process is stopped automatically with the managed profile.

Pi-only mode does not need the extra keepalive because the interactive Pi terminal itself keeps WSL active.

The behavior can be changed in `config/local.json`.

## Pi

Pi runs inside Ubuntu and talks to Ollama at:

```text
http://127.0.0.1:11434/v1
```

Runtime Pi configuration is generated from the checksum-protected templates in `config/` and installed into Local AI's isolated Pi home:

```text
~/.local/share/local-ai/pi-agent/
├── models.json
├── settings.json
├── extensions/
└── sessions/
```

Local AI sets `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` before Pi starts. Plain `pi` outside Local AI keeps using its normal configuration and sessions. If Pi is not already installed, Local AI installs its package into `~/.local/share/local-ai/pi-runtime` instead of requiring a root-owned global npm install.

Pi saves Local AI interactive sessions in the isolated session directory. `Resume-Pi.bat` starts Pi with its most recent Local AI session.

Local AI tags only the Pi process tree it launches. Stop does not use a generic `pkill pi`, so unrelated Pi sessions are not intentionally killed.

## Local AI Pi tool

The first extension exposes:

```text
local_ai_status
```

Actions:

```text
health
models
benchmark
```

It uses `~/.local/bin/local-ai-tools.py` when available and has direct safe fallbacks for health/model inspection. Benchmark uses the model and context configured for Pi.

Token reports read the usage metadata Open WebUI stores for each assistant response. Some providers/models return no usage metadata (for example, failed tool-only requests); those responses are labeled `unavailable` instead of being misreported as zero tokens. The HUD activity drawer is seeded from the latest persisted controller log and continues to stream command output while an operation runs.

## Context

The initial default is 65,536 tokens.

Local AI writes that value into the Ollama systemd override and Pi model metadata. The project does not yet pretend that one context size is ideal for every GPU or model.

The existing benchmark tooling is the basis for a later 32K / 64K / 96K / 128K profiler after real Pi sessions show whether that is actually useful.

## Stop behavior

`Stop-Local-AI.bat` does the following:

1. stops only the Local AI managed Pi process tree
2. stops Open WebUI
3. stops Ollama
4. closes Local AI-owned runtime windows
5. waits with timeouts
6. optionally terminates the configured WSL distro
7. verifies the endpoints and managed Pi process are gone

Pi session history is saved by Pi itself. An in-flight tool call or generation can still be interrupted by a forced shutdown, so finish important writes before deliberately killing the runtime.

Setup asks whether Stop should terminate the entire Ubuntu distro. Leave that disabled if you regularly use the same distro for unrelated WSL work.

## Configuration

Repository defaults live in:

```text
config/default.json
```

Machine-specific configuration is generated at:

```text
config/local.json
```

Setup merges newly added defaults into older `local.json` files, which makes beta upgrades less brittle.

Generated runtime/install state is kept under `state/` and is ignored by Git.

## Open WebUI

Open WebUI uses Python 3.11 and a persistent uv tool environment for new Local AI installations.

If setup detects an existing working `open-webui.service`, it preserves that service definition rather than replacing it. This is useful when migrating from an older Local AI build.

Newly created Open WebUI services are not enabled for automatic WSL-boot startup. Profiles start the service only when needed.

### Forgotten Open WebUI login

Use **Operations → Recovery → Reset WebUI login** in the HUD, choose option 19 in the PowerShell menu, or run:

```text
Reset-WebUI-Credentials.bat
```

The recovery terminal lists the local Open WebUI account emails, asks for a new password twice without echoing it, stops only Open WebUI, creates a timestamped `webui.db.backup-*` copy, updates that account's bcrypt password hash, and restores the service if it was previously running. It does not delete chats, models, settings, or other accounts.

Setup installs the required Ubuntu `htpasswd` utility. Credential recovery also installs it on demand for older beta installations.

## Logging and diagnostics

Controller and setup logs:

```text
logs/launcher/
```

Diagnostics bundles:

```text
logs/diagnostics/
```

Ollama and Open WebUI service logs remain in journald.

`Live-Logs.bat` follows both services.

`WebUI-Probe.bat` checks `/health`, `/ready`, `/health/db`, and `/` separately because a usable Open WebUI root can come online even when one of the narrower probes behaves differently.

## Update

`Update-Local-AI.bat`:

- stops services that were active
- backs up `~/.open-webui` before an Open WebUI upgrade
- updates enabled components
- refreshes the Local AI extension/helper
- restores the previous service state even when the update fails

It does not overwrite Pi's runtime model/settings files with repository templates.

## Repair

`Repair-Local-AI.bat` reruns the idempotent prerequisite/configuration checks without asking you to rebuild the installation manually.

## Uninstall

`Uninstall-Local-AI.bat` is ownership-aware where possible.

A Pi package or Open WebUI service that Local AI did not record as creating is preserved by default. User data, WSL, Ubuntu, Ollama, and downloaded models are not silently deleted.

## Security

Pi is an agent harness, not a sandbox. It runs with the Linux user's permissions.

Local AI exposes these access profiles:

- Read
- Workspace
- Workspace + Net
- Full Access

Read mode is enforced at Pi startup by allowing only `read`, `grep`, `find`, and `ls`. The other profiles currently remain guardrails because raw Bash is not an operating-system sandbox. Stronger Bubblewrap or dedicated-WSL isolation remains opt-in/future work rather than a beta4 core dependency.

## Beta scope

This build focuses on setup, prerequisites, lifecycle, Pi integration, status, health, diagnostics, update safety, and reliable shutdown.

Automatic context profiling, stronger sandbox enforcement, richer Pi audit logs, model routing, Pi RPC/SDK control, and Windows-native desktop tools are later layers.

## License

MIT. Preserve `LICENSE` and `NOTICE.md` when redistributing the project.

## Attribution and provenance

`NOTICE.md` and `CREDITS.json` carry the JYNERATION identity and the author
credit (`Copyright (c) 2026 saj`). `SHA256SUMS.txt` records the exact hashes
for the beta files. The current workspace is intentionally marked
`unsigned-local-build`; official releases can publish a detached signature for
that manifest using the process documented in `PROVENANCE.md`.

This is transparent provenance, not hidden telemetry: the project makes no
network callback or secret tracking request to preserve credit. The MIT license
already requires the copyright and permission notice to remain in copies and
substantial portions of the software.
