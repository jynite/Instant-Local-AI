#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPECTED_BUILD = "v2.0.0-beta.4.1-20260826"


def fail(message: str) -> None:
    raise AssertionError(message)


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig")


def require(rel: str) -> Path:
    p = ROOT / rel
    if not p.is_file():
        fail(f"missing required file: {rel}")
    return p


def production_text() -> str:
    allowed = {".ps1", ".bat", ".py", ".ts", ".sh"}
    chunks: list[str] = []
    for p in ROOT.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in allowed:
            continue
        rel = p.relative_to(ROOT).as_posix()
        if rel.startswith("tests/"):
            continue
        chunks.append(p.read_text(encoding="utf-8-sig", errors="replace"))
    return "\n".join(chunks)


def leaf_paths(obj: object, prefix: tuple[str, ...] = ()):
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield from leaf_paths(value, prefix + (key,))
    else:
        yield prefix, obj


def check_build_and_required_files() -> None:
    required = [
        "BUILD-ID.txt", "README.md", "CHANGELOG.md", "LICENSE", ".gitignore", "SHA256SUMS.txt",
        "Local-AI.bat", "Setup-Local-AI.bat", "Start-Local-AI.bat", "Stop-Local-AI.bat",
        "Restart-Local-AI.bat", "Status-Local-AI.bat", "Health-Check.bat", "Live-Logs.bat",
        "Benchmark.bat", "Benchmark-History.bat", "Tokens.bat", "Live-Tokens.bat", "Dashboard.bat",
        "Diagnostics.bat", "WebUI-Probe.bat", "Start-WebUI.bat", "Start-Pi.bat", "Start-Both.bat",
        "Start-Ollama.bat", "Resume-Pi.bat", "Open-WSL-Runtime.bat", "Manage-Models.bat",
        "Repair-Local-AI.bat", "Update-Local-AI.bat", "Uninstall-Local-AI.bat", "VERIFY-BUILD.bat",
        "config/default.json", "config/models.json", "config/settings.json", "extension/local-ai.ts",
        "powershell/Local-AI.ps1", "powershell/Setup-Local-AI.ps1", "powershell/Find-Pwsh.ps1", "powershell/Repair-Local-AI.ps1",
        "powershell/Update-Local-AI.ps1", "powershell/Uninstall-Local-AI.ps1",
        "wsl/local-ai-tools.py", "tests/smoke/Test-Paths.ps1",
        "tests/smoke/Test-Static.ps1", "tests/release/verify_release.py",
    ]
    for rel in required:
        require(rel)
    if read("BUILD-ID.txt").strip() != EXPECTED_BUILD:
        fail("BUILD-ID.txt is not final beta4.1 build")
    cfg = json.loads(read("config/default.json"))
    if cfg.get("build") != EXPECTED_BUILD:
        fail("default.json build mismatch")
    for rel in ["powershell/Local-AI.ps1", "powershell/Setup-Local-AI.ps1", "VERIFY-BUILD.bat", "tests/smoke/Test-Static.ps1"]:
        if EXPECTED_BUILD not in read(rel):
            fail(f"build id missing from {rel}")



def check_pwsh_bootstrap() -> None:
    resolver = require("powershell/Find-Pwsh.ps1")
    resolver_text = resolver.read_text(encoding="utf-8-sig")
    for needle in ["Get-AppxPackage", "Microsoft.PowerShell", "pwsh.exe", "ProgramFiles"]:
        if needle not in resolver_text:
            fail(f"PowerShell resolver missing {needle}")

    launchers = [
        p.relative_to(ROOT).as_posix() for p in ROOT.glob("*.bat")
        if p.name not in {"VERIFY-BUILD.bat"}
        and ("PWSH=" in p.read_text(encoding="utf-8-sig", errors="replace") or p.name == "Setup-Local-AI.bat")
    ]
    for rel in launchers:
        text = read(rel)
        if "powershell\\Find-Pwsh.ps1" not in text:
            fail(f"{rel} does not use the MSIX-aware PowerShell resolver")
        if "FOUND_PWSH" in text:
            fail(f"{rel} still uses stale same-block FOUND_PWSH expansion")

    setup = read("Setup-Local-AI.bat")
    if setup.count("powershell\\Find-Pwsh.ps1") < 2:
        fail("Setup must resolve PowerShell both before and after WinGet")
    if "PowerShell 7 is installed but pwsh.exe could not be located" not in setup:
        fail("Setup lacks an explicit post-install PowerShell resolution failure")

def check_launcher_routes() -> None:
    routes = {
        "Start-Local-AI.bat": ("powershell\\Local-AI.ps1", "start"),
        "Stop-Local-AI.bat": ("powershell\\Local-AI.ps1", "stop"),
        "Restart-Local-AI.bat": ("powershell\\Local-AI.ps1", "restart"),
        "Status-Local-AI.bat": ("powershell\\Local-AI.ps1", "status"),
        "Health-Check.bat": ("powershell\\Local-AI.ps1", "health"),
        "Live-Logs.bat": ("powershell\\Local-AI.ps1", "logs"),
        "Benchmark.bat": ("powershell\\Local-AI.ps1", "benchmark"),
        "Benchmark-History.bat": ("powershell\\Local-AI.ps1", "benchmarkhistory"),
        "Tokens.bat": ("powershell\\Local-AI.ps1", "tokens"),
        "Live-Tokens.bat": ("powershell\\Local-AI.ps1", "livetokens"),
        "Dashboard.bat": ("powershell\\Local-AI.ps1", "dashboard"),
        "Diagnostics.bat": ("powershell\\Local-AI.ps1", "diagnostics"),
        "WebUI-Probe.bat": ("powershell\\Local-AI.ps1", "probe"),
        "Start-WebUI.bat": ("powershell\\Local-AI.ps1", "webui"),
        "Start-Pi.bat": ("powershell\\Local-AI.ps1", "pi"),
        "Start-Both.bat": ("powershell\\Local-AI.ps1", "both"),
        "Start-Ollama.bat": ("powershell\\Local-AI.ps1", "ollama"),
        "Resume-Pi.bat": ("powershell\\Local-AI.ps1", "piresume"),
        "Manage-Models.bat": ("powershell\\Local-AI.ps1", "models"),
        "Repair-Local-AI.bat": ("powershell\\Repair-Local-AI.ps1", None),
        "Update-Local-AI.bat": ("powershell\\Update-Local-AI.ps1", None),
        "Uninstall-Local-AI.bat": ("powershell\\Uninstall-Local-AI.ps1", None),
    }
    for rel, (script, action) in routes.items():
        text = read(rel)
        if script not in text:
            fail(f"{rel} does not route to {script}")
        if action and f"-Action {action}" not in text:
            fail(f"{rel} does not route to action {action}")


def check_pi_isolation_and_policy() -> None:
    controller = read("powershell/Local-AI.ps1")
    setup = read("powershell/Setup-Local-AI.ps1")
    update = read("powershell/Update-Local-AI.ps1")
    uninstall = read("powershell/Uninstall-Local-AI.ps1")
    extension = read("extension/local-ai.ts")
    prod = production_text()

    for token in [
        "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "LOCAL_AI_SESSION_ID",
        ".local/share/local-ai/pi-agent", ".local/share/local-ai/pi-runtime",
    ]:
        if token not in controller + setup + update + uninstall + extension:
            fail(f"Pi isolation token missing: {token}")
    if "~/.pi/agent" in prod or '".pi", "agent"' in extension:
        fail("production code still writes Local AI state into normal ~/.pi/agent")
    if "npm install -g" in setup or "npm install -g" in update:
        fail("Pi installation/update still depends on root/global npm")
    if "npm uninstall -g" in uninstall:
        fail("Pi uninstall still targets global npm")
    if "--name" in controller:
        fail("managed Pi startup must not rename resumed sessions")
    if "Resolve-PiThinking" not in controller:
        fail("Qwen reasoning mapping helper is missing")
    for pair in [
        '"off" { return "off" }',
        '"minimal" { return "low" }',
        '"low" { return "low" }',
        '"medium" { return "medium" }',
        '"high" { return "xhigh" }',
        '"xhigh" { return "xhigh" }',
        '"max" { return "xhigh" }',
    ]:
        if pair not in controller:
            fail(f"reasoning map missing: {pair}")
    if '"read" { return "read,grep,find,ls" }' not in controller:
        fail("Read mode must allowlist read-only built-in tools before startup")
    if "--tools \"$tools\"" not in controller:
        fail("Pi startup does not apply selected tool allowlist")
    if "--thinking \"$thinking\"" not in controller:
        fail("Pi startup does not apply mapped thinking level")
    if "Get-ManagedPiPids" not in update or "LOCAL_AI_SESSION_ID" not in update:
        fail("Update does not target Local AI-managed Pi session state")
    if "pgrep -af '[p]i" in update:
        fail("Update still blocks on unrelated Pi sessions")
    if "process.env.PI_CODING_AGENT_DIR" not in extension:
        fail("extension does not resolve config from isolated Pi home")


def check_context_and_services() -> None:
    cfg = json.loads(read("config/default.json"))
    setup = read("powershell/Setup-Local-AI.ps1")
    controller = read("powershell/Local-AI.ps1")
    if int(cfg["model"]["context"]) != 65536:
        fail("default context must be 65536")
    if "OLLAMA_CONTEXT_LENGTH=$context" not in setup:
        fail("Ollama systemd override does not consume configured context")
    if "OLLAMA_FLASH_ATTENTION" not in setup or "OLLAMA_KV_CACHE_TYPE" not in setup:
        fail("Ollama Flash Attention/KV settings are not validated/applied")
    ollama_cfg = cfg.get("ollama", {})
    if ollama_cfg.get("flash_attention") is not False or ollama_cfg.get("kv_cache_type") != "f16":
        fail("experimental Ollama cache settings must remain conservative by default")
    if "q8_0" not in setup or "q4_0" not in setup or "f16" not in setup:
        fail("KV cache validation allowlist missing")
    if "ps -p 1 -o comm=" not in setup:
        fail("setup does not verify systemd is PID 1")
    if "-Consecutive 2" not in controller or "webui_start_seconds" not in controller:
        fail("two-hit WebUI readiness/cold-start allowance missing")
    if "Get-NetTCPConnection" not in setup or "ollama.service" not in setup or "open-webui.service" not in setup:
        fail("setup port/service ownership preflight missing")


def check_status_stop_and_state() -> None:
    controller = read("powershell/Local-AI.ps1")
    setup = read("powershell/Setup-Local-AI.ps1")
    update = read("powershell/Update-Local-AI.ps1")
    if "Get-RunningDistros" not in controller or "DistroRunning" not in controller:
        fail("side-effect-free WSL status primitives missing")
    show_status = controller.split("function Show-Status", 1)[1].split("function Invoke-Helper", 1)[0]
    if "wsl.exe -d" in show_status:
        fail("Show-Status directly starts/enters WSL")
    stop_all = controller.split("function Stop-All", 1)[1].split("function Show-Status", 1)[0]
    order = [stop_all.find("Stop-Pi"), stop_all.find("Stop-WebUI"), stop_all.find("Stop-Ollama"), stop_all.find("--terminate")]
    if any(i < 0 for i in order) or order != sorted(order):
        fail("Stop-All order is not Pi -> WebUI -> Ollama -> WSL terminate")
    if "service_stop_seconds" not in stop_all or "pi_stop_seconds" not in controller:
        fail("bounded stop timeouts are missing")
    if "pi_window_start" not in controller or "keepalive_start" not in controller:
        fail("Windows PID reuse protection timestamps missing")
    for field in ["pi_installed_by_local_ai", "open_webui_created_by_local_ai", "ollama_installed_by_local_ai"]:
        if field not in setup:
            fail(f"install ownership field missing: {field}")
    if "Merge-InstallState" not in setup:
        fail("older install.json migration helper missing")
    if "ollamaWasActive" not in update or "webWasActive" not in update or "finally" not in update:
        fail("update does not restore prior service states")
    if "~/.open-webui.backup-" not in update:
        fail("Open WebUI update backup missing")


def check_config_consumption_and_hygiene() -> None:
    cfg = json.loads(read("config/default.json"))
    prod = production_text()
    missing: list[str] = []
    for path, _value in leaf_paths(cfg):
        dotted = ".".join(path)
        leaf = path[-1]
        candidates = [dotted, "." + dotted, f".{leaf}", f"['{leaf}']", f'"{leaf}"']
        if not any(c in prod for c in candidates):
            missing.append(dotted)
    if missing:
        fail("config leaves not consumed by production code: " + ", ".join(missing))
    gi = read(".gitignore")
    for pattern in ["config/local.json", "state/*.json", "state/*.txt", "logs/**/*.log", "logs/**/*.jsonl"]:
        if pattern not in gi:
            fail(f"generated-file ignore missing: {pattern}")
    for bad in [r"\\\$", r'\\"']:
        regex = re.compile(bad)
        for rel in ["powershell/Local-AI.ps1", "powershell/Setup-Local-AI.ps1", "powershell/Update-Local-AI.ps1", "powershell/Uninstall-Local-AI.ps1"]:
            if regex.search(read(rel)):
                fail(f"bash-style escaping remains in PowerShell: {rel}")


def check_language_syntax() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        py_compile.compile(str(ROOT / "wsl/local-ai-tools.py"), cfile=str(Path(tmp) / "local-ai-tools.pyc"), doraise=True)
    # PowerShell parser validation runs on Windows through Test-Paths.ps1/VERIFY-BUILD.bat.
    tpaths = read("tests/smoke/Test-Paths.ps1")
    if "System.Management.Automation.Language.Parser" not in tpaths or "ParseFile" not in tpaths:
        fail("Windows smoke test does not parse every shipped PowerShell script")


def check_no_generated_artifacts() -> None:
    bad = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        if "__pycache__/" in rel or p.suffix.lower() == ".pyc":
            bad.append(rel)
    if bad:
        fail("generated artifacts must not ship: " + ", ".join(sorted(bad)))


def check_checksums_if_populated() -> None:
    sums_path = ROOT / "SHA256SUMS.txt"
    lines = [ln for ln in sums_path.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if not lines:
        return
    for line in lines:
        m = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not m:
            fail(f"bad checksum line: {line}")
        digest, rel = m.groups()
        p = ROOT / rel
        if not p.is_file():
            fail(f"checksum references missing file: {rel}")
        got = hashlib.sha256(p.read_bytes()).hexdigest()
        if got != digest:
            fail(f"checksum mismatch: {rel}")


def main() -> int:
    checks = [
        check_build_and_required_files,
        check_pwsh_bootstrap,
        check_launcher_routes,
        check_pi_isolation_and_policy,
        check_context_and_services,
        check_status_stop_and_state,
        check_config_consumption_and_hygiene,
        check_language_syntax,
        check_no_generated_artifacts,
        check_checksums_if_populated,
    ]
    failures: list[str] = []
    for check in checks:
        try:
            check()
            print(f"PASS {check.__name__}")
        except Exception as exc:
            failures.append(f"{check.__name__}: {exc}")
            print(f"FAIL {check.__name__}: {exc}")
    if failures:
        print(f"\n{len(failures)} release check(s) failed.")
        return 1
    print(f"\nAll {len(checks)} release check groups passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
