"""Unit arms for the envelope contract. No 5dive binary is required: every arm
drives the real FiveDive.raw() and fakes only subprocess.run, so the parsing and
the raising under test are the shipped ones.
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from fivedive import FiveDive, FiveDiveError, CliNotFound  # noqa: E402


def completed(stdout="", stderr="", rc=0):
    return subprocess.CompletedProcess(args=[], returncode=rc, stdout=stdout, stderr=stderr)


class EnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.fd = FiveDive()
        patcher = mock.patch("shutil.which", return_value="/usr/local/bin/5dive")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_ok_true_returns_data(self):
        env = json.dumps({"ok": True, "data": {"tasks": [{"ident": "DIVE-1"}]}})
        with mock.patch("subprocess.run", return_value=completed(env)):
            self.assertEqual(self.fd.tasks(), [{"ident": "DIVE-1"}])

    def test_ok_false_raises_with_machine_fields(self):
        env = json.dumps(
            {"ok": False, "error": {"code": 4, "class": "not_found", "message": "no such task: NOPE-1"}}
        )
        with mock.patch("subprocess.run", return_value=completed(env, rc=4)):
            with self.assertRaises(FiveDiveError) as ctx:
                self.fd.task("NOPE-1")
        self.assertEqual(ctx.exception.code, 4)
        self.assertEqual(ctx.exception.err_class, "not_found")
        self.assertIn("NOPE-1", str(ctx.exception))

    def test_error_envelope_is_read_even_though_exit_is_nonzero(self):
        """The regression this guards: judging returncode first would report
        'exited 4' and throw away the message the CLI actually sent."""
        env = json.dumps({"ok": False, "error": {"code": 4, "class": "not_found", "message": "gone"}})
        with mock.patch("subprocess.run", return_value=completed(env, stderr="error: gone", rc=4)):
            with self.assertRaises(FiveDiveError) as ctx:
                self.fd.raw("task", "show", "X")
        self.assertEqual(str(ctx.exception), "gone")

    def test_no_envelope_falls_back_to_stderr(self):
        with mock.patch("subprocess.run", return_value=completed("", "segfault", rc=139)):
            with self.assertRaises(FiveDiveError) as ctx:
                self.fd.raw("task", "ls")
        self.assertIn("segfault", str(ctx.exception))

    def test_json_flag_not_duplicated(self):
        env = json.dumps({"ok": True, "data": {}})
        with mock.patch("subprocess.run", return_value=completed(env)) as run:
            self.fd.raw("task", "ls", "--json")
        self.assertEqual(run.call_args[0][0].count("--json"), 1)

    def test_missing_binary_raises_cli_not_found(self):
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(CliNotFound):
                FiveDive().raw("task", "ls")

    def test_timeout_is_reported_not_swallowed(self):
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="5dive", timeout=1)):
            with self.assertRaises(FiveDiveError) as ctx:
                self.fd.raw("task", "ls")
        self.assertIn("timed out", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
