"""A thin, dependency-free wrapper over the local ``5dive`` CLI's JSON mode.

WHY THIS IS A WRAPPER AND NOT AN HTTP CLIENT: 5dive's state lives on the box the
agents run on, and the CLI is the only interface with a stable contract over it.
Every ``--json`` verb answers in one envelope::

    {"ok": true,  "data": {...}}
    {"ok": false, "error": {"code": 4, "class": "not_found", "message": "..."}}

so the whole job of this module is to run the binary, parse that envelope, and
raise on the false branch instead of handing back a dict the caller has to
remember to check. An unchecked ``ok`` is the bug this exists to prevent.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from typing import Any, Dict, List, Optional, Sequence


class FiveDiveError(RuntimeError):
    """The CLI answered with ``ok: false``.

    Carries the machine-readable fields so callers can branch on ``err_class``
    rather than matching on message text, which is not a stable contract.
    """

    def __init__(self, message: str, code: Optional[int] = None, err_class: Optional[str] = None):
        super().__init__(message)
        self.code = code
        self.err_class = err_class


class CliNotFound(FiveDiveError):
    """The ``5dive`` binary is not on PATH."""


class FiveDive:
    """Run 5dive CLI verbs and return parsed JSON.

    :param binary: path to the CLI, if it is not simply ``5dive`` on PATH.
    :param timeout: seconds before a call is abandoned. ``None`` waits forever,
        which is rarely what you want from a library.
    """

    def __init__(self, binary: str = "5dive", timeout: Optional[float] = 30.0):
        self.binary = binary
        self.timeout = timeout

    # -- the one place a subprocess is run -------------------------------
    def raw(self, *args: str) -> Any:
        """Run ``5dive <args> --json`` and return the ``data`` payload.

        ``--json`` is appended only when the caller has not already passed it,
        so ``raw("task", "ls", "--json")`` and ``raw("task", "ls")`` agree.
        """
        argv: List[str] = [self.binary, *args]
        if "--json" not in argv:
            argv.append("--json")

        if shutil.which(self.binary) is None and "/" not in self.binary:
            raise CliNotFound(f"{self.binary!r} is not on PATH — is this a 5dive box?")

        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout)
        except FileNotFoundError as exc:  # binary named by path, but absent
            raise CliNotFound(f"cannot execute {self.binary!r}: {exc}") from exc
        except subprocess.TimeoutExpired as exc:
            raise FiveDiveError(f"{' '.join(argv)} timed out after {self.timeout}s") from exc

        # A non-zero exit still carries a JSON envelope on the error path, so
        # parse BEFORE judging the status: the envelope's message is better than
        # "exited 4", and falling back to stderr only when there is no envelope
        # keeps a genuine crash legible instead of masking it as a parse error.
        payload = None
        if proc.stdout.strip():
            try:
                payload = json.loads(proc.stdout)
            except json.JSONDecodeError:
                payload = None

        if payload is None:
            detail = (proc.stderr or proc.stdout or "").strip() or f"exited {proc.returncode}"
            raise FiveDiveError(f"{' '.join(argv)}: no JSON envelope — {detail}")

        if not payload.get("ok", False):
            err = payload.get("error") or {}
            raise FiveDiveError(
                err.get("message", "unknown error"),
                code=err.get("code"),
                err_class=err.get("class"),
            )
        return payload.get("data")

    # -- convenience readers ---------------------------------------------
    def tasks(self, *flags: str) -> List[Dict[str, Any]]:
        """The task queue. Extra flags pass straight through, e.g.
        ``tasks("--status=todo", "--assignee=main")``."""
        data = self.raw("task", "ls", *flags) or {}
        return data.get("tasks", [])

    def task(self, ident: str) -> Dict[str, Any]:
        """One task by ident, e.g. ``task("DIVE-3903")``."""
        return self.raw("task", "show", ident) or {}

    def agents(self, *flags: str) -> List[Dict[str, Any]]:
        """The agent seats on this box."""
        data = self.raw("agent", "list", *flags)
        if isinstance(data, list):
            return data
        return (data or {}).get("agents", [])

    def version(self) -> str:
        """The CLI's version string (does not use the JSON envelope)."""
        proc = subprocess.run(
            [self.binary, "--version"], capture_output=True, text=True, timeout=self.timeout
        )
        return proc.stdout.strip()
