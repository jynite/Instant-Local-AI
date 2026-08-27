# Local AI v2 Changelog

## beta 4.1 - 2026-08-26

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
