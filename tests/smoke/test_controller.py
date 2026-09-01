#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ui"))

from PySide6.QtCore import QCoreApplication

import LocalAIController as controller_module
from LocalAIController import Controller, SERVICE_ORDER, _human_size


APP = QCoreApplication.instance() or QCoreApplication([])


class ControllerLogicTests(unittest.TestCase):
    def setUp(self) -> None:
        self.controller = Controller(enable_polling=False)

    def test_snapshot_parser_ignores_non_json_prefix(self) -> None:
        payload = {"services": [], "details": {}, "models": []}
        parsed = self.controller._extract_snapshot("status text\n" + json.dumps(payload) + "\n")
        self.assertEqual(parsed, payload)

    def test_snapshot_keeps_service_order_and_model_metadata(self) -> None:
        self.controller._apply_snapshot(
            {
                "services": [
                    {"name": "Ubuntu WSL", "value": "RUNNING", "detail": "host"},
                    {"name": "Ollama", "value": "RUNNING", "detail": "runtime"},
                ],
                "details": {"model": "model-b", "context": 8192, "capabilities": ["tools"]},
                "models": [
                    {"name": "model-a", "size": 1024, "selected": False, "loaded": False},
                    {"name": "model-b", "size": 2048, "selected": True, "loaded": True},
                ],
            }
        )
        self.assertEqual([row["name"] for row in self.controller.statusRows], list(SERVICE_ORDER))
        self.assertEqual(self.controller.models[0]["name"], "model-b")
        self.assertTrue(self.controller.models[0]["selected"])
        self.assertEqual(self.controller.details["model"], "model-b")

    def test_empty_snapshot_clears_stale_models(self) -> None:
        self.controller._models = [{"name": "stale"}]
        self.controller._apply_snapshot({"services": [], "details": {}, "models": []})
        self.assertEqual(self.controller.models, [])

    def test_pending_state_is_an_overlay(self) -> None:
        stable = self.controller.statusRows[0]["value"]
        self.controller._overlay_pending("ollama")
        self.assertEqual(self.controller.statusRows[0]["value"], stable)
        self.assertEqual(self.controller.statusRows[0]["pending"], "STARTING")
        self.controller._clear_pending()
        self.assertEqual(self.controller.statusRows[0]["pending"], "")

    def test_busy_guard_does_not_poison_active_command(self) -> None:
        self.controller._busy = True
        self.controller._active_action = "benchmark"
        self.controller.run("stop")
        self.assertEqual(self.controller._active_action, "benchmark")
        self.assertFalse(any(row["pending"] for row in self.controller.statusRows))

    def test_human_size(self) -> None:
        self.assertEqual(_human_size(1024**3), "1.0 GiB")

    def test_activity_starts_with_latest_persisted_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            log_dir = Path(temp_dir) / "logs" / "launcher"
            log_dir.mkdir(parents=True)
            (log_dir / "controller-older.log").write_text("older event", encoding="utf-8")
            latest = log_dir / "controller-latest.log"
            latest.write_text("latest persisted event", encoding="utf-8")
            latest.touch()
            with patch.object(controller_module, "ROOT", Path(temp_dir)):
                controller = Controller(enable_polling=False)
            self.assertEqual(controller.output, "latest persisted event")

    def test_startup_requests_ollama_when_stopped(self) -> None:
        controller = Controller(enable_polling=False, auto_start_ollama=True)
        controller._apply_snapshot(
            {"services": [{"name": "Ollama", "value": "STOPPED"}], "details": {}, "models": []}
        )
        self.assertTrue(controller._consume_ollama_auto_start(True))
        self.assertFalse(controller._consume_ollama_auto_start(True))

    def test_startup_keeps_running_ollama_untouched(self) -> None:
        controller = Controller(enable_polling=False, auto_start_ollama=True)
        controller._apply_snapshot(
            {"services": [{"name": "Ollama", "value": "RUNNING"}], "details": {}, "models": []}
        )
        self.assertFalse(controller._consume_ollama_auto_start(True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
