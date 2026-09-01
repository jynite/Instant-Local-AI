#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("local_ai_tools", ROOT / "wsl" / "local-ai-tools.py")
assert SPEC and SPEC.loader
TOOLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOLS)


class UsageAggregationTests(unittest.TestCase):
    def test_null_usage_is_unavailable_not_metered_zero(self) -> None:
        rows = [
            {
                "model_id": "model-a",
                "usage": "null",
                "created_at": 2_000_000_000,
            }
        ]
        total, by_model, _last = TOOLS.agg(rows)
        self.assertEqual(total["metered"], 0)
        self.assertEqual(total["unmetered"], 1)
        self.assertEqual(by_model["model-a"]["unmetered"], 1)

    def test_real_usage_remains_metered(self) -> None:
        rows = [
            {
                "model_id": "model-a",
                "usage": json.dumps({"input_tokens": 120, "output_tokens": 30}),
                "created_at": 2_000_000_000,
            }
        ]
        total, by_model, _last = TOOLS.agg(rows)
        self.assertEqual((total["in"], total["out"]), (120, 30))
        self.assertEqual(total["metered"], 1)
        self.assertEqual(total["unmetered"], 0)
        self.assertEqual(by_model["model-a"]["metered"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
