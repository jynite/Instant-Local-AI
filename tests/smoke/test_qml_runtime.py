from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ui"))

from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

from LocalAIController import Controller  # noqa: E402


class QmlRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QGuiApplication.instance() or QGuiApplication([])

    def test_main_qml_loads_without_runtime_warnings(self) -> None:
        warnings: list[str] = []
        engine = QQmlApplicationEngine()
        controller = Controller(enable_polling=False)
        engine.setInitialProperties({"controller": controller})
        engine.warnings.connect(lambda items: warnings.extend(item.toString() for item in items))
        engine.load(str(ROOT / "ui" / "Main.qml"))
        self.assertEqual(len(engine.rootObjects()), 1, "Main.qml did not create an application window")
        self.assertEqual(warnings, [], "QML runtime warnings:\n" + "\n".join(warnings))


if __name__ == "__main__":
    unittest.main()
