# JYNERATION — Ollama Control HUD Changelog

## beta 4.1 - 2026-08-26

- Serialized lifecycle mutations so simultaneous launcher/HUD commands cannot race or overwrite runtime ownership state.
- Fixed persisted process timestamp normalization across PowerShell JSON deserialization, preventing duplicate WSL keepalives and missed owned-process cleanup.
- Made state writes replace from PID-specific temporary files and made controller log filenames PID-unique for concurrent safety.
- Added a single-instance HUD lock, fixed invalid QML control bindings, and added a headless QML runtime regression test with zero-warning enforcement.
- Fixed Open WebUI credential recovery so its decoded Bash script no longer consumes the stdin channel carrying the email and password.
- Restored visible runtime history by seeding the HUD activity drawer from persisted logs and clarified token reports for provider responses that omit usage metadata.
- Simplified the HUD to Runtime, Operations, and About; model selection now uses a dropdown beside live service state instead of a separate Models page.
- The HUD now starts Ollama automatically after its initial snapshot when the service is stopped, while leaving an already-running instance untouched.
- Shortened every visible build badge to `BETA` while retaining the full internal build ID for diagnostics and integrity checks.
- Suppressed unreadable `/proc/*/environ` entries when detecting the managed Pi process so runtime snapshots remain reliable under stricter Linux process permissions.
- Rebuilt the HUD around one responsive runtime surface, one shared activity drawer, stable service rows, model metadata, recent activity, and explicit running/reconciling/completed states.
- Replaced the three-process refresh chain with one side-effect-free JSON snapshot for services, configuration, installed models, and load state.
- Added background synchronization that pauses while commands run, buffered output delivery, output follow-tail, and asynchronous process-tree cancellation.
- Fixed stale pending states after failed or canceled lifecycle commands and kept completion feedback visible before returning to Ready.
- Removed the idle progress animation and the duplicated hidden output panel that were wasting UI work.
- Added safe Open WebUI credential recovery with account discovery, masked password confirmation, a timestamped database backup, and prior service-state restoration.
- Added `Reset-WebUI-Credentials.bat`, PowerShell menu/HUD recovery routes, and setup handling for the required `apache2-utils` package.
- Added controller logic tests for service ordering, model clearing, pending overlays, snapshot parsing, metadata, and busy-state isolation.
- Added a PySide6/Qt Quick control center under `ui/` with runtime, operations, and about pages.
- Branded the user-facing control surface as JYNERATION — Ollama Control HUD.
- Rebuilt the QML presentation with a denser operator-console layout, live status cards, grouped operations, and an About / Credits page.
- Tuned the QML copy and palette toward a quieter, near-black interface with seafoam highlights.
- Added transparent attribution and provenance files: `NOTICE.md`, `CREDITS.json`, and `PROVENANCE.md`, plus `About.bat` and `JYNERATION.bat --about`.
- `Start-Local-AI.bat` now opens the QML control center when PySide6 is available, with the PowerShell menu retained as a fallback.
- Added `Start-UI.bat` for direct UI launch and routed UI actions through the tested PowerShell lifecycle controller.
- Added a hidden QML command runner so lifecycle output stays in the HUD log without blank helper consoles; intentional Pi/Ubuntu runtime windows remain visible.
- Wired the HUD directly to the PowerShell controller, added visible action progress/spinner feedback, and synchronized status cards after lifecycle commands.
- Added a safe HUD Cancel control for long-running logs and live-token views.
- Reduced stopped-runtime latency by skipping network probes when WSL is already stopped.
- Hardened setup for clean machines: it now installs/validates Windows Python + PySide6, verifies `pythonw.exe`, and installs the complete Ubuntu runtime package baseline.
- Hardened health and shutdown paths: optional WebUI/GPU checks no longer masquerade as required failures, HTTP error responses are rejected, and failed shutdowns retain state for recovery.
- Added capability-aware model selection and warnings for models that do not report Ollama tool support.
- Fixed PowerShell 7.6+ MSIX detection during setup and launch.
- Added a Windows PowerShell 5.1-compatible `Find-Pwsh.ps1` resolver for MSI, MSIX/Store, PATH, App Paths, and .NET global-tool installs.
- Removed the broken `FOUND_PWSH` batch expansion pattern that could discard a path discovered inside a parenthesized block.
- Setup now resolves `pwsh.exe` again after WinGet and fails with a specific message if an installed PowerShell cannot be located.
- Applied the same PowerShell resolver to every PowerShell-backed launcher.

## v2.0.0-beta.4 - 2026-08-26

- Isolated Local AI Pi config and sessions with `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`.
- Added Local AI-owned Pi runtime installs under `~/.local/share/local-ai/pi-runtime` when Pi is not already installed.
- Added access-mode startup tool selection and Qwen3.8 reasoning-level mapping.
- Added install-state migration and safer ownership-aware update/uninstall behavior.
- Added conservative Ollama Flash Attention/KV-cache configuration with validation.
- Added exhaustive launcher/package verification and PowerShell parser checks.
- Added `Manage-Models.bat` and removed dead/duplicate beta3 launch helpers.
- Hardened port ownership checks, managed Pi process targeting, and release checksums.

## v2.0.0-beta.3

- made Status side-effect free so it does not wake a stopped WSL distro
- restored a reliable visible WSL keepalive for Web UI, Both, and Ollama-only profiles
- uses the Ubuntu launcher when available for the keepalive window
- tracks only Local AI-managed Pi process trees with a session marker
- added Pi startup verification and Resume Pi
- fixed managed Pi shell quoting with base64 transport
- fixed the Pi benchmark extension to supply the configured model/context
- made the Pi extension async/cancellable
- added fallback Ollama model inspection to the Pi extension
- made profile switching stop frontends that are not part of the requested profile
- fixed Restart so a failed shutdown cannot be silently ignored
- made setup merge new defaults into older local config files
- installs Node only when Pi is selected and uv only when Open WebUI is selected
- tracks component ownership for safer uninstall behavior
- keeps checksum-protected Pi templates immutable during setup
- restores previous service state after failed updates
- stops a legacy auto-started Open WebUI service when the selected profile disables it
- added direct Resume Pi, Ubuntu runtime, and debug launchers
- added stronger static smoke tests and build verification
- detects healthy-looking port conflicts when the expected WSL service is not actually active
- preserves any pre-existing Open WebUI systemd unit instead of relying on PATH detection
- restores exact pre-update service state and refuses to update Pi while a Pi session is running
- Fixed duplicate-looking Ubuntu shells by replacing the visible WSL keepalive with a hidden, state-tracked `wsl.exe sleep infinity` process.
