# SPDX-FileCopyrightText: Copyright (c) 2026 saj
# SPDX-License-Identifier: MIT
from __future__ import annotations

import codecs
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QLockFile, QObject, Property, QProcess, QTimer, Signal, Slot
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlApplicationEngine
from PySide6.QtQuickControls2 import QQuickStyle


ROOT = Path(__file__).resolve().parents[1]
SERVICE_ORDER = ("Ollama", "Open WebUI", "Pi Agent", "Ubuntu WSL")
LIFECYCLE_ACTIONS = {"start", "both", "webui", "pi", "ollama", "stop", "restart"}
VERBOSE_ACTIONS = {"logs", "livetokens", "benchmark", "benchmarkhistory", "diagnostics", "probe"}


def _print_qml_warnings(warnings) -> None:
    """Write QML diagnostics without crashing on legacy Windows encodings."""
    text = "\n".join(warning.toString() for warning in warnings) + "\n"
    stream = getattr(sys.stderr, "buffer", None)
    if stream is not None:
        stream.write(text.encode("utf-8", "replace"))
        stream.flush()
        return
    try:
        sys.stderr.write(text)
    except UnicodeEncodeError:
        sys.stderr.write(text.encode("ascii", "replace").decode("ascii"))


def _human_size(value: object) -> str:
    try:
        size = float(value or 0)
    except (TypeError, ValueError):
        return "Unknown size"
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return "Unknown size"


class Controller(QObject):
    outputChanged = Signal()
    busyChanged = Signal()
    activityChanged = Signal()
    statusChanged = Signal()
    modelsChanged = Signal()
    detailsChanged = Signal()
    operationChanged = Signal()
    recentActivityChanged = Signal()
    consoleRequested = Signal()

    def __init__(self, *, enable_polling: bool = True, auto_start_ollama: bool = False) -> None:
        super().__init__()
        self._output = self._load_recent_log()
        self._busy = False
        self._activity = "Loading runtime state"
        self._status_rows = [
            {"name": name, "value": "WAITING", "detail": "Waiting for first sync", "pending": ""}
            for name in SERVICE_ORDER
        ]
        self._models: list[dict[str, object]] = []
        self._details: dict[str, object] = {
            "model": "Not loaded",
            "context": "",
            "workspace": "",
            "access": "",
            "reasoning": "",
            "profile": "",
            "started": "",
            "capabilities": [],
        }
        self._operation_state = "loading"
        self._operation_title = "Loading runtime state"
        self._operation_phase = "Reading local services"
        self._last_result = "No commands have run yet."
        self._last_sync = "Not synchronized"
        self._has_error = False
        self._recent_activity: list[dict[str, str]] = []
        self._auto_start_ollama_pending = auto_start_ollama

        self._active_action = ""
        self._active_label = ""
        self._snapshot_purpose = ""
        self._needs_reconcile = False
        self._pending_outcome: tuple[str, str, str] | None = None
        self._process_error_reported = False
        self._cancel_requested = False
        self._completion_handled = False

        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._snapshot_capture = ""
        self._pending_output: list[str] = []
        self._flush_timer = QTimer(self)
        self._flush_timer.setSingleShot(True)
        self._flush_timer.setInterval(70)
        self._flush_timer.timeout.connect(self._flush_output)

        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.MergedChannels)
        self._process.readyReadStandardOutput.connect(self._read_output)
        self._process.errorOccurred.connect(self._process_error)
        self._process.finished.connect(self._finished)

        self._probe = QProcess(self)
        self._probe.setProcessChannelMode(QProcess.MergedChannels)
        self._probe_buffer = bytearray()
        self._probe.readyReadStandardOutput.connect(self._read_probe)
        self._probe.finished.connect(self._probe_finished)

        self._poll_timer = QTimer(self)
        self._poll_timer.setInterval(12000)
        self._poll_timer.timeout.connect(self._start_probe)
        if enable_polling:
            self._poll_timer.start()

    @staticmethod
    def _load_recent_log() -> str:
        """Seed the activity drawer with the latest persisted controller log."""
        log_dir = ROOT / "logs" / "launcher"
        try:
            candidates = sorted(log_dir.glob("controller-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
            if candidates:
                text = candidates[0].read_text(encoding="utf-8", errors="replace").strip()
                if text:
                    return text[-30000:]
        except OSError:
            pass
        return "Runtime output will appear here."

    @Property(str, notify=outputChanged)
    def output(self) -> str:
        return self._output

    @Property(bool, notify=busyChanged)
    def busy(self) -> bool:
        return self._busy

    @Property(str, notify=activityChanged)
    def activity(self) -> str:
        return self._activity

    @Property("QVariantList", notify=statusChanged)
    def statusRows(self):
        return self._status_rows

    @Property("QVariantList", notify=modelsChanged)
    def models(self):
        return self._models

    @Property("QVariantMap", notify=detailsChanged)
    def details(self):
        return self._details

    @Property(str, notify=operationChanged)
    def operationState(self) -> str:
        return self._operation_state

    @Property(str, notify=operationChanged)
    def operationTitle(self) -> str:
        return self._operation_title

    @Property(str, notify=operationChanged)
    def operationPhase(self) -> str:
        return self._operation_phase

    @Property(str, notify=operationChanged)
    def lastResult(self) -> str:
        return self._last_result

    @Property(str, notify=operationChanged)
    def lastSync(self) -> str:
        return self._last_sync

    @Property(bool, notify=operationChanged)
    def hasError(self) -> bool:
        return self._has_error

    @Property("QVariantList", notify=recentActivityChanged)
    def recentActivity(self):
        return self._recent_activity

    def _set_busy(self, value: bool) -> None:
        if value == self._busy:
            return
        self._busy = value
        self.busyChanged.emit()

    def _set_operation(self, state: str, title: str, phase: str, *, error: bool = False) -> None:
        changed = (
            state != self._operation_state
            or title != self._operation_title
            or phase != self._operation_phase
            or error != self._has_error
        )
        self._operation_state = state
        self._operation_title = title
        self._operation_phase = phase
        self._has_error = error
        if title != self._activity:
            self._activity = title
            self.activityChanged.emit()
        if changed:
            self.operationChanged.emit()

    def _set_output(self, value: str) -> None:
        trailing_newline = value.endswith("\n")
        lines = value.splitlines()
        if len(lines) > 500:
            lines = lines[-500:]
        trimmed = "\n".join(lines)[-30000:]
        if trailing_newline and trimmed:
            trimmed += "\n"
        if trimmed == self._output:
            return
        self._output = trimmed
        self.outputChanged.emit()

    def _append_output(self, value: str) -> None:
        prefix = "" if self._output.endswith("\n") else "\n"
        self._set_output(self._output + prefix + value)

    def _queue_output(self, value: str) -> None:
        if not value:
            return
        self._pending_output.append(value)
        if not self._flush_timer.isActive():
            self._flush_timer.start()

    def _flush_output(self) -> None:
        if not self._pending_output:
            return
        chunk = "".join(self._pending_output)
        self._pending_output.clear()
        self._set_output(self._output + chunk)

    def _record_recent(self, title: str, result: str, state: str) -> None:
        entry = {
            "time": datetime.now().strftime("%I:%M %p").lstrip("0"),
            "title": title,
            "result": result,
            "state": state,
        }
        self._recent_activity = [entry, *self._recent_activity][:8]
        self.recentActivityChanged.emit()

    def _overlay_pending(self, action: str) -> None:
        pending: dict[str, str] = {}
        if action in {"start", "both"}:
            pending = {name: "STARTING" for name in SERVICE_ORDER}
        elif action == "webui":
            pending = {"Ollama": "STARTING", "Open WebUI": "STARTING", "Ubuntu WSL": "STARTING"}
        elif action == "pi":
            pending = {"Ollama": "STARTING", "Pi Agent": "STARTING", "Ubuntu WSL": "STARTING"}
        elif action == "ollama":
            pending = {"Ollama": "STARTING", "Ubuntu WSL": "STARTING"}
        elif action == "stop":
            pending = {name: "STOPPING" for name in SERVICE_ORDER}
        elif action == "restart":
            pending = {name: "RESTARTING" for name in SERVICE_ORDER}
        if not pending:
            return
        self._status_rows = [
            {**row, "pending": pending.get(str(row["name"]), "")}
            for row in self._status_rows
        ]
        self.statusChanged.emit()

    def _clear_pending(self) -> None:
        if not any(row.get("pending") for row in self._status_rows):
            return
        self._status_rows = [{**row, "pending": ""} for row in self._status_rows]
        self.statusChanged.emit()

    @staticmethod
    def _extract_snapshot(text: str) -> dict[str, object] | None:
        for line in reversed(text.splitlines()):
            candidate = line.strip()
            if not candidate.startswith("{"):
                continue
            try:
                parsed = json.loads(candidate)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict) and "services" in parsed:
                return parsed
        return None

    def _apply_snapshot(self, snapshot: dict[str, object]) -> None:
        raw_services = snapshot.get("services")
        service_map: dict[str, dict[str, object]] = {}
        if isinstance(raw_services, list):
            for row in raw_services:
                if isinstance(row, dict) and str(row.get("name", "")) in SERVICE_ORDER:
                    service_map[str(row["name"])] = row
        self._status_rows = [
            {
                "name": name,
                "value": str(service_map.get(name, {}).get("value", "UNKNOWN")),
                "detail": str(service_map.get(name, {}).get("detail", "")),
                "pending": "",
            }
            for name in SERVICE_ORDER
        ]
        self.statusChanged.emit()

        raw_details = snapshot.get("details")
        if isinstance(raw_details, dict):
            self._details = {
                "model": str(raw_details.get("model", "Not selected")),
                "context": str(raw_details.get("context", "")),
                "workspace": str(raw_details.get("workspace", "")),
                "access": str(raw_details.get("access", "")),
                "reasoning": str(raw_details.get("reasoning", "")),
                "profile": str(raw_details.get("profile", "")),
                "started": str(raw_details.get("started", "")),
                "capabilities": list(raw_details.get("capabilities") or []),
            }
            self.detailsChanged.emit()

        parsed_models: list[dict[str, object]] = []
        raw_models = snapshot.get("models")
        if isinstance(raw_models, list):
            for model in raw_models:
                if not isinstance(model, dict) or not str(model.get("name", "")).strip():
                    continue
                parsed_models.append(
                    {
                        "name": str(model["name"]),
                        "size": _human_size(model.get("size")),
                        "parameters": str(model.get("parameters", "")),
                        "quantization": str(model.get("quantization", "")),
                        "loaded": bool(model.get("loaded", False)),
                        "selected": bool(model.get("selected", False)),
                    }
                )
        parsed_models.sort(key=lambda item: (not bool(item["selected"]), str(item["name"]).lower()))
        if parsed_models != self._models:
            self._models = parsed_models
            self.modelsChanged.emit()

        self._last_sync = datetime.now().strftime("%I:%M:%S %p").lstrip("0")
        self.operationChanged.emit()

    def _service_value(self, name: str) -> str:
        for row in self._status_rows:
            if str(row.get("name", "")) == name:
                return str(row.get("value", "UNKNOWN")).upper()
        return "UNKNOWN"

    def _consume_ollama_auto_start(self, snapshot_succeeded: bool) -> bool:
        if not self._auto_start_ollama_pending:
            return False
        self._auto_start_ollama_pending = False
        return snapshot_succeeded and self._service_value("Ollama") != "RUNNING"

    def _start_ollama_after_bootstrap(self) -> None:
        if not self._busy:
            self.run("ollama")

    @staticmethod
    def _resolve_pwsh() -> str:
        roots = [
            os.environ.get("ProgramFiles(x86)"),
            os.environ.get("ProgramFiles"),
            os.environ.get("ProgramW6432"),
        ]
        for root in roots:
            if root:
                candidate = Path(root) / "PowerShell" / "7" / "pwsh.exe"
                if candidate.is_file():
                    return str(candidate)
        return shutil.which("pwsh.exe") or "pwsh.exe"

    def _power_shell_args(self, action: str, extra: list[str] | None = None) -> list[str]:
        args = [
            self._resolve_pwsh(),
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "powershell" / "Local-AI.ps1"),
            "-Action",
            action,
        ]
        if extra:
            args.extend(extra)
        return args

    @staticmethod
    def _runner() -> tuple[str, str] | None:
        pythonw = Path(sys.executable).with_name("pythonw.exe")
        if not pythonw.is_file():
            pythonw_path = shutil.which("pythonw.exe")
            pythonw = Path(pythonw_path) if pythonw_path else Path(sys.executable)
        runner = Path(__file__).with_name("quiet_runner.py")
        if not runner.is_file():
            return None
        return str(pythonw), str(runner)

    def _start_command(
        self,
        action: str,
        label: str,
        *,
        extra: list[str] | None = None,
        preserve_output: bool = False,
        internal: bool = False,
        snapshot_purpose: str = "",
    ) -> bool:
        if self._busy and not internal:
            return False
        runner = self._runner()
        if runner is None:
            self._append_output("ERROR: ui/quiet_runner.py is missing.")
            self._finalize("error", f"{label} could not start", error=True)
            return False
        if not preserve_output:
            self._set_output(f"{label}\n")
        else:
            self._append_output(label)
        self._set_busy(True)
        self._active_action = action
        self._active_label = label
        self._snapshot_purpose = snapshot_purpose
        self._process_error_reported = False
        self._cancel_requested = False
        self._completion_handled = False
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._snapshot_capture = ""
        self._pending_output.clear()
        self._set_operation(
            "reconciling" if snapshot_purpose == "reconcile" else "running",
            label,
            "Reading runtime state" if action == "snapshot" else "Command is running",
        )
        program, runner_script = runner
        self._process.start(program, [runner_script, *self._power_shell_args(action, extra)])
        return True

    def _read_output(self) -> None:
        raw = bytes(self._process.readAllStandardOutput())
        if raw:
            decoded = self._decoder.decode(raw, final=False)
            if self._active_action == "snapshot":
                self._snapshot_capture += decoded
            else:
                self._queue_output(decoded)

    def _finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        self._complete_current(exit_code)

    def _complete_current(self, exit_code: int) -> None:
        if self._completion_handled:
            return
        self._completion_handled = True
        self._read_output()
        final_text = self._decoder.decode(b"", final=True)
        if self._active_action == "snapshot":
            self._snapshot_capture += final_text
        else:
            self._queue_output(final_text)
        self._flush_output()

        failed = exit_code != 0 or self._process_error_reported
        if self._active_action == "snapshot":
            snapshot = None if failed else self._extract_snapshot(self._snapshot_capture)
            if snapshot is not None:
                self._apply_snapshot(snapshot)
                self._append_output("Runtime state synchronized.")
            else:
                failed = True
                self._append_output("Runtime snapshot could not be parsed.")
            purpose = self._snapshot_purpose
            auto_start_ollama = purpose == "refresh" and self._consume_ollama_auto_start(not failed)
            if purpose == "reconcile" and self._pending_outcome is not None:
                state, message, original_label = self._pending_outcome
                self._pending_outcome = None
                if failed and state == "success":
                    state, message = "error", "Command finished, but runtime state could not be verified"
                self._finalize(state, message, error=state == "error", record_title=original_label)
            elif failed:
                self._finalize("error", "Runtime refresh failed", error=True)
            else:
                self._finalize("success", "Runtime state synchronized")
                if auto_start_ollama:
                    QTimer.singleShot(0, self._start_ollama_after_bootstrap)
            return

        if self._cancel_requested:
            state = "canceled"
            message = f"{self._active_label} canceled"
            self._append_output("Command canceled.")
        elif failed:
            state = "error"
            message = f"{self._active_label} failed"
            if not self._process_error_reported:
                self._append_output(f"Command failed with exit code {exit_code}.")
        else:
            state = "success"
            message = f"{self._active_label} complete"
            self._append_output(message + ".")

        if self._needs_reconcile:
            self._pending_outcome = (state, message, self._active_label)
            self._needs_reconcile = False
            self._set_operation("reconciling", "Syncing runtime state", "Verifying service state")
            self._start_command(
                "snapshot",
                "Syncing runtime state",
                preserve_output=True,
                internal=True,
                snapshot_purpose="reconcile",
            )
            return
        self._clear_pending()
        self._finalize(state, message, error=state == "error")

    def _process_error(self, error: QProcess.ProcessError) -> None:
        if self._completion_handled:
            return
        if self._cancel_requested:
            return
        messages = {
            QProcess.FailedToStart: "The command could not be started.",
            QProcess.Crashed: "The command process crashed.",
            QProcess.Timedout: "The command timed out.",
            QProcess.WriteError: "The command input failed.",
            QProcess.ReadError: "The command output could not be read.",
            QProcess.UnknownError: "The command failed.",
        }
        detail = self._process.errorString().strip()
        message = messages.get(error, "The command failed.")
        if detail:
            message += f" {detail}"
        self._append_output("ERROR: " + message)
        self._process_error_reported = True
        if error == QProcess.FailedToStart:
            QTimer.singleShot(0, lambda: self._complete_current(127))

    def _finalize(self, state: str, message: str, *, error: bool = False, record_title: str = "") -> None:
        self._set_busy(False)
        self._cancel_requested = False
        self._clear_pending()
        self._last_result = message
        title = message
        phase = "Completed" if state == "success" else message
        self._set_operation(state, title, phase, error=error)
        self._record_recent(record_title or self._active_label or "Runtime refresh", message, state)
        if error:
            self.consoleRequested.emit()
        elif state == "success":
            QTimer.singleShot(5500, self._settle_ready)
        self._active_action = ""
        self._active_label = ""
        self._snapshot_purpose = ""

    def _settle_ready(self) -> None:
        if not self._busy and self._operation_state == "success":
            self._set_operation("success", "Ready", "Runtime is ready for the next command")

    def _read_probe(self) -> None:
        self._probe_buffer.extend(bytes(self._probe.readAllStandardOutput()))

    def _start_probe(self) -> None:
        if self._busy or self._probe.state() != QProcess.NotRunning:
            return
        runner = self._runner()
        if runner is None:
            return
        self._probe_buffer.clear()
        program, runner_script = runner
        self._probe.start(program, [runner_script, *self._power_shell_args("snapshot")])

    def _probe_finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        self._read_probe()
        if exit_code != 0 or self._busy:
            return
        snapshot = self._extract_snapshot(self._probe_buffer.decode("utf-8", "replace"))
        if snapshot is not None:
            self._apply_snapshot(snapshot)
            if self._operation_state in {"loading", "success"}:
                self._set_operation("success", "Ready", "Runtime state is synchronized")

    @Slot()
    def cancel(self) -> None:
        """Stop the current HUD command without blocking the GUI thread."""
        if not self._busy or self._process.state() == QProcess.NotRunning:
            return
        self._cancel_requested = True
        self._set_operation("running", "Canceling command", "Stopping the command process")
        self._append_output("Cancel requested.")
        pid = int(self._process.processId())
        if os.name == "nt" and pid > 0:
            taskkill = shutil.which("taskkill.exe") or "taskkill.exe"
            try:
                subprocess.Popen(
                    [taskkill, "/PID", str(pid), "/T", "/F"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000),
                )
            except OSError:
                pass
        QTimer.singleShot(1500, self._force_kill)

    def _force_kill(self) -> None:
        if self._process.state() != QProcess.NotRunning:
            self._process.kill()

    @Slot(str)
    def run(self, action: str) -> None:
        if self._busy:
            return
        normalized = action.replace(" ", "").lower()
        if normalized in {"status", "models", "refresh"}:
            self.refresh()
            return
        mapping = {
            "start": ("both", "Launching stack"),
            "both": ("both", "Launching stack"),
            "webui": ("webui", "Starting Open WebUI"),
            "pi": ("pi", "Starting Pi agent"),
            "ollama": ("ollama", "Starting Ollama"),
            "stop": ("stop", "Stopping managed services"),
            "restart": ("restart", "Restarting managed services"),
            "health": ("health", "Running health check"),
            "dashboard": ("dashboard", "Loading usage dashboard"),
            "tokens": ("tokens", "Reading token usage"),
            "livetokens": ("livetokens", "Following live token usage"),
            "benchmark": ("benchmark", "Running benchmark"),
            "benchmarkhistory": ("benchmarkhistory", "Loading benchmark history"),
            "logs": ("logs", "Following service logs"),
            "probe": ("probe", "Probing Open WebUI"),
            "diagnostics": ("diagnostics", "Collecting diagnostics"),
            "about": ("about", "Loading release details"),
        }
        target = mapping.get(normalized)
        if target is None:
            self._set_output(f"Unknown command: {normalized or '(empty)'}")
            self._set_operation("error", "Unknown command", "Choose a supported operation", error=True)
            return
        command, label = target
        self._needs_reconcile = normalized in LIFECYCLE_ACTIONS
        if self._needs_reconcile:
            self._overlay_pending(normalized)
        if normalized in VERBOSE_ACTIONS:
            self.consoleRequested.emit()
        self._start_command(command, label)

    @Slot(str)
    def selectModel(self, model: str) -> None:
        if self._busy or not model.strip():
            return
        self._needs_reconcile = True
        self._start_command("selectmodel", "Selecting model", extra=["-Model", model.strip()])

    @Slot()
    def refresh(self) -> None:
        if self._busy:
            return
        self._needs_reconcile = False
        self._start_command("snapshot", "Refreshing runtime", snapshot_purpose="refresh")

    @Slot()
    def clearOutput(self) -> None:
        self._set_output("Runtime output cleared.")

    @Slot()
    def resetWebUICredentials(self) -> None:
        if self._busy:
            return
        batch = ROOT / "Reset-WebUI-Credentials.bat"
        if not batch.is_file():
            self._set_operation("error", "Credential recovery unavailable", "Recovery launcher is missing", error=True)
            return
        result = QProcess.startDetached("cmd.exe", ["/d", "/c", "start", "", str(batch)])
        started = result[0] if isinstance(result, tuple) else bool(result)
        if not started:
            self._set_operation("error", "Credential recovery could not open", "Run Reset-WebUI-Credentials.bat directly", error=True)
            return
        message = "Credential recovery opened in a secure terminal"
        self._last_result = message
        self._set_operation("success", message, "Complete the secure prompts in the terminal")
        self._record_recent("Reset Open WebUI login", message, "success")
        self._append_output(message + ".")
        QTimer.singleShot(5500, self._settle_ready)


def main() -> int:
    os.environ["QT_QUICK_CONTROLS_STYLE"] = "Basic"
    QQuickStyle.setStyle("Basic")
    app = QGuiApplication(sys.argv)
    lock_path = ROOT / "state" / "hud.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    instance_lock = QLockFile(str(lock_path))
    instance_lock.setStaleLockTime(30_000)
    if not instance_lock.tryLock(100):
        return 0
    app._jyneration_instance_lock = instance_lock
    engine = QQmlApplicationEngine()
    controller = Controller(auto_start_ollama=True)
    engine.setInitialProperties({"controller": controller})
    engine.warnings.connect(_print_qml_warnings)
    engine.load(str(Path(__file__).with_name("Main.qml")))
    if not engine.rootObjects():
        return 1
    controller.refresh()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
