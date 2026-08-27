# Architecture

Local AI v2 is an orchestrator, not a second agent runtime.

Windows owns the BAT launchers and PowerShell control plane. WSL Ubuntu owns Ollama, Open WebUI, Pi, and the Linux helper tooling. Ollama is the shared inference backend. Open WebUI and Pi are sibling frontends and can run independently.

Pi owns the agent loop, sessions, compaction, file tools, shell tools, and extensions. Local AI owns prerequisite installation, configuration, component lifecycle, WSL lifetime, health checks, diagnostics, and integration.

The v13.7 project is a source of battle-tested behavior rather than a folder layout to copy. v2 carries forward its useful readiness, GPU/RAM, token, benchmark, logging, update, and shutdown behavior inside the cleaner component model.

Runtime state is separate from immutable repository templates. Setup writes machine-specific configuration to `config/local.json`, generated Pi configuration to `state/`, and installed Pi configuration/sessions to `~/.local/share/local-ai/pi-agent/` through `PI_CODING_AGENT_DIR`.

A Local AI Pi session receives a random `LOCAL_AI_SESSION_ID`. Shutdown finds processes carrying that marker instead of killing every `pi` process in the distro.
