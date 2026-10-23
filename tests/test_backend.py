"""Regression tests for data-integrity boundaries; uses no real model or network.

Run: python3 -m unittest discover -s tests -v
"""

from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


BACKEND = Path(__file__).resolve().parents[1] / "bin/dictations.py"
SPEC = importlib.util.spec_from_file_location("dictations_backend", BACKEND)
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class BackendBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "data"
        self.environment = patch.dict(os.environ, {"DICTATIONS_DATA_DIR": str(self.directory)})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temporary.cleanup()

    def record(self, text):
        backend.capture(text.encode("utf-8"))
        return backend.rpc({"action": "state"})["entries"][0]["id"]

    def test_capture_preserves_bytes_even_when_storage_fails(self):
        blocked = Path(self.temporary.name) / "not-a-directory"
        blocked.write_bytes(b"blocked")
        raw = b"  dictated\x00bytes\xff\r\n\n"
        environment = {**os.environ, "DICTATIONS_DATA_DIR": str(blocked)}
        result = subprocess.run(
            [sys.executable, str(BACKEND), "capture"], input=raw,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
            timeout=10, check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, raw)
        self.assertNotIn(b"dictated", result.stderr)
        self.assertTrue(result.stderr)

    def test_capture_pause_does_not_change_passthrough(self):
        backend.rpc({"action": "settings", "enabled": False})
        raw = b"paused transcript\r\n"
        result = subprocess.run(
            [sys.executable, str(BACKEND), "capture"], input=raw,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10, check=True,
        )
        self.assertEqual(result.stdout, raw)
        self.assertEqual(backend.rpc({"action": "state"})["entries"], [])

    def test_search_terms_cannot_be_fts_operators_or_prefixes(self):
        alpha = self.record("alpha")
        self.record("alphabet")
        literal = self.record("alpha OR beta")
        self.record("beta")
        result = backend.rpc({"action": "state", "query": "alpha*"})
        self.assertEqual({row["id"] for row in result["entries"]}, {alpha, literal})
        result = backend.rpc({"action": "state", "query": "alpha OR beta"})
        self.assertEqual([row["id"] for row in result["entries"]], [literal])
        self.assertEqual(backend.rpc({"action": "state", "query": "NEAR(alpha beta)"})["entries"], [])
        self.assertEqual(backend.rpc({"action": "state", "query": "text:alpha"})["entries"], [])
        result = backend.rpc({"action": "state", "query": "(alpha)"})
        self.assertEqual({row["id"] for row in result["entries"]}, {alpha, literal})

    def test_summary_has_only_selected_snapshots_and_survives_entry_deletion(self):
        first = self.record("selected source")
        hidden = self.record("unselected private source")
        with patch.object(backend, "generate_summary", return_value="A real provider result supplied by this test") as generate:
            summary = backend.rpc({"action": "summarize", "kind": "handoff", "ids": [first]})["summary"]
        sent_sources = generate.call_args.args[2]
        self.assertEqual([row["id"] for row in sent_sources], [first])
        self.assertEqual(summary["entry_ids"], [first])
        self.assertNotIn(str(hidden), json.dumps(summary["entry_ids"]))
        backend.rpc({"action": "delete", "ids": [first]})
        saved = backend.rpc({"action": "state"})["summaries"][0]
        self.assertEqual(saved["sources"][0]["text"], "selected source")
        exported = backend.rpc({"action": "export", "summary_id": summary["id"]})["text"]
        self.assertIn("selected source", exported)
        self.assertNotIn("unselected private source", exported)
        backend.rpc({"action": "delete_summary", "id": summary["id"]})
        self.assertEqual(backend.rpc({"action": "state"})["summaries"], [])

    def test_retention_expires_summary_snapshot_even_after_original_deletion(self):
        entry_id = self.record("old source")
        old = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        with backend.database() as db:
            db.execute("UPDATE entries SET created_at = ? WHERE id = ?", (old, entry_id))
        with patch.object(backend, "generate_summary", return_value="Selected old source summary"):
            backend.rpc({"action": "summarize", "kind": "daily", "ids": [entry_id]})
        backend.rpc({"action": "delete", "ids": [entry_id]})
        current_id = self.record("current source")
        result = backend.rpc({"action": "settings", "retention_days": 1})
        self.assertEqual(result["summaries"], [])
        self.assertEqual([row["id"] for row in result["entries"]], [current_id])


if __name__ == "__main__":
    unittest.main()
