from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

PLUGIN_PATH = Path(__file__).with_name("__init__.py")
SPEC = importlib.util.spec_from_file_location("household_scribe_guard", PLUGIN_PATH)
assert SPEC and SPEC.loader
plugin = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = plugin
SPEC.loader.exec_module(plugin)

TOOL = "mcp__holthome__finances_context_add"


class HouseholdScribeGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        plugin._successful_messages.clear()

    def test_rewrites_volunteered_message_verbatim(self) -> None:
        context = plugin.ScribeContext(
            message_id=7,
            note="just spent $80 at Home Depot, that's the berry garden",
            author="Ryan Holt",
            pulse_reply=False,
        )
        with patch.object(plugin, "_read_scribe_context", return_value=context):
            result = plugin._rewrite_tool_request(
                tool_name=TOOL,
                session_id="session-1",
                args={
                    "note": "that's the berry garden",
                    "author": "user",
                    "ref_date": None,
                    "ref_amount": 80.0,
                    "ref_payee": "Home Depot",
                    "source": "volunteered",
                },
            )

        assert result
        rewritten = result["args"]
        self.assertEqual(rewritten["note"], context.note)
        self.assertEqual(rewritten["author"], "Ryan Holt")
        self.assertEqual(rewritten["ref_date"], date.today().isoformat())
        self.assertEqual(rewritten["ref_amount"], 80.0)
        self.assertEqual(rewritten["ref_payee"], "Home Depot")
        self.assertEqual(rewritten["source"], "volunteered")

    def test_reply_context_sets_pulse_source(self) -> None:
        content = (
            "[Replying to your previous message: \"Couldn't place: 7/30 Garden Supply "
            '$84.21 — reply if you remember; ignoring is fine."]\n\n'
            "that was for the berry garden"
        )
        note, reply = plugin._split_reply_context(content)
        self.assertEqual(note, "that was for the berry garden")
        self.assertIn("Couldn't place:", reply or "")

        context = plugin.ScribeContext(8, note, "Ryan Holt", True)
        with patch.object(plugin, "_read_scribe_context", return_value=context):
            result = plugin._rewrite_tool_request(
                tool_name=TOOL,
                session_id="session-2",
                args={"note": note, "author": "Ryan", "ref_date": "2026-07-30"},
            )
        assert result
        self.assertEqual(result["args"]["source"], "pulse_clarify")
        self.assertEqual(result["args"]["ref_date"], "2026-07-30")

    def test_success_forces_confirmation_and_blocks_duplicate(self) -> None:
        context = plugin.ScribeContext(9, "purchase context", "Ryan Holt", False)
        calls = 0

        def execute(_args: dict[str, object]) -> str:
            nonlocal calls
            calls += 1
            return json.dumps({"content": [{"text": json.dumps({"added": True})}]})

        with patch.object(plugin, "_read_scribe_context", return_value=context):
            first = plugin._guard_tool_execution(
                tool_name=TOOL,
                args={},
                next_call=execute,
                session_id="session-3",
            )
            second = plugin._guard_tool_execution(
                tool_name=TOOL,
                args={},
                next_call=execute,
                session_id="session-3",
            )
            transformed = plugin._force_scribe_confirmation(
                response_text="verbose model answer",
                session_id="session-3",
                platform="signal",
            )
            unchanged = plugin._force_scribe_confirmation(
                response_text="another answer",
                session_id="session-3",
                platform="signal",
            )

        self.assertTrue(plugin._contains_added(first))
        self.assertIn("already recorded", second)
        self.assertEqual(calls, 1)
        self.assertEqual(transformed, plugin.CONFIRMATION)
        self.assertIsNone(unchanged)


if __name__ == "__main__":
    unittest.main()
