# Security

Pi runs with the permissions of the Linux user that launches it. Project trust controls whether project-local Pi resources are loaded, but it is not an operating-system sandbox.

The current beta does not claim to enforce workspace or network isolation.

The planned policy modes are Read, Workspace, Workspace + Net, and Full Access. Enforcement should intercept tool calls and process launches. Prompt instructions alone are not a security boundary.

Local AI shutdown tracks its own Pi session with a unique environment marker rather than issuing a generic process kill. The installer also records whether selected components already existed so uninstall can avoid removing software it did not create.

If `wsl.terminate_on_stop` is enabled, Stop terminates the entire configured distro after services are stopped. Disable that option when the distro also hosts unrelated work.

Read mode starts Pi with only read-oriented tools enabled. Workspace, Workspace + Net, and Full Access are not OS sandboxes when Bash is available. Optional stronger isolation belongs behind explicit opt-in and version-pinned sandbox tooling.
