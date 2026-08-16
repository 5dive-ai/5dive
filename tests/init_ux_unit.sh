#!/usr/bin/env bash
# DIVE-1326: PTY-level coverage for the init onboarding controls. This drives
# real arrow-key bytes and secret input through a pseudo-terminal; no root,
# network, auth, install, or agent state is touched.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

# Structural coverage: every bounded choice uses the shared picker, all secret
# classes use the masked reader, and the final create has an explicit review.
# shellcheck disable=SC1091
# shellcheck source=../src/cmd_init.sh
source src/cmd_init.sh
body="$(declare -f cmd_init)"

# These are literal source fragments; expansion would defeat the assertion.
# shellcheck disable=SC2016
for needle in \
  '_init_pick type "Pick an agent type:"' \
  '_init_pick auth_choice "How should Claude Code authenticate?"' \
  '_init_pick auth_choice "How should Codex authenticate?"' \
  '_init_pick ch_choice "Where do you want to talk to $name?"' \
  '_init_pick isolation "Pick isolation:"' \
  '_init_pick create_choice "Ready to create $name?"'
do
  [[ "$body" == *"$needle"* ]] || { echo "FAIL: missing picker wiring: $needle" >&2; exit 1; }
done

# shellcheck disable=SC2016
for needle in \
  '_init_secret key "Anthropic API key"' \
  '_init_secret key "OpenAI API key"' \
  '_init_secret byo_key "${byo_provider} API key"' \
  '_init_secret pi_key "$provider API key"' \
  '_init_secret telegram_token "Telegram bot token"'
do
  [[ "$body" == *"$needle"* ]] || { echo "FAIL: missing masked-input wiring: $needle" >&2; exit 1; }
done

# DIVE-3505: the pty below now runs with ECHO cleared (see the note in drive()),
# which is what makes it deterministic -- but it also retires the coverage the
# echo race was providing by accident. A `_init_secret` that lost its `-s` would
# have leaked the secret via KERNEL echo, and with echo off the pty can no longer
# see that. Measured: mutating `read -r -s -n1` -> `read -r -n1` fails the old
# harness and passes the echo-off one. So assert the no-echo read structurally,
# where it is a fact about the source rather than a race against the tty.
secret_body="$(declare -f _init_secret)"
[[ "$secret_body" == *'read -r -s -n1'* ]] \
  || { echo "FAIL: _init_secret must read with -s (no terminal echo)" >&2; exit 1; }

[[ "$body" == *'_init_section 4 4 "Review and create"'* ]] \
  || { echo "FAIL: missing pre-create review stage" >&2; exit 1; }

python3 - "$(pwd)" <<'PY'
import errno
import os
import pty
import select
import shlex
import sys
import termios
import time

root = sys.argv[1]


# DIVE-3505: this harness, not the product, owned a pty ECHO race that reds
# `test-installed-host` at random. `_init_secret` reads with `read -r -s -n1`,
# and bash's `-s` turns echo off on ENTRY and restores it on EXIT -- per call,
# so with `-n1` that is one echo-off/echo-on cycle PER CHARACTER. Writing a
# whole payload in one os.write leaves the unconsumed tail sitting in the tty
# input buffer, and the kernel echoes it the moment echo comes back on. The
# product was innocent: the failing runs showed the kernel echo AND the
# product's own `*******` mask AND RESULT_LEN=7 all at once.
#
# Two independent layers, because either alone leaves a window:
#   1. Clear ECHO in the CHILD before execv. Doing it from the parent after
#      pty.fork() races the child: if bash has already entered a `read -s`, the
#      termios it restores on exit is the one it saved -- echo ON -- and the
#      buffered tail echoes anyway. Clearing it before bash exists means every
#      save/restore cycle can only ever restore echo-off.
#   2. Write payloads one byte at a time (below), so no unconsumed tail is ever
#      parked in the buffer for an echo-on window to flush.
def drive(shell_body, interactions, timeout=5, term="xterm-256color"):
    pid, fd = pty.fork()
    if pid == 0:
        attrs = termios.tcgetattr(0)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(0, termios.TCSANOW, attrs)
        os.environ["TERM"] = term
        os.environ["NO_COLOR"] = "1"
        command = f"source {shlex.quote(root)}/src/cmd_init.sh; {shell_body}"
        os.execv("/bin/bash", ["bash", "-c", command])

    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        for marker, payload in interactions:
            marker = marker.encode()
            while marker not in output:
                if time.monotonic() >= deadline:
                    raise AssertionError(f"timed out waiting for {marker!r}; output={output!r}")
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    output.extend(os.read(fd, 4096))
            for byte in payload:
                os.write(fd, bytes([byte]))

        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if not ready:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    if status != 0:
                        raise AssertionError(f"child exited with status {status}; output={output!r}")
                    return output.decode(errors="replace")
                continue
            try:
                output.extend(os.read(fd, 4096))
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                os.waitpid(pid, 0)
                return output.decode(errors="replace")
        raise AssertionError(f"child did not exit; output={output!r}")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


picker = drive(
    "_init_pick picked 'Choose runtime:' 1 "
    "'alpha|Alpha|first' 'beta|Beta|second'; printf 'RESULT=%s\\n' \"$picked\"",
    [("move", b"\x1b[B\n")],
)
assert "RESULT=beta" in picker, picker
print("ok - down-arrow moves the picker and Enter selects")

fallback = drive(
    "_init_pick picked 'Choose runtime:' 1 "
    "'alpha|Alpha|first' 'beta|Beta|second'; printf 'RESULT=%s\\n' \"$picked\"",
    [("Choose [1]:", b"2\n")],
    term="dumb",
)
assert "RESULT=beta" in fallback, fallback
assert "\x1b[" not in fallback, fallback
print("ok - dumb terminals receive a plain numbered fallback")

secret = drive(
    "_init_secret token 'API key'; printf 'RESULT_LEN=%d\\n' \"${#token}\"",
    [("API key:", b"hunter2\n")],
)
assert "*******" in secret, secret
assert "hunter2" not in secret, secret
assert "RESULT_LEN=7" in secret, secret
print("ok - API key input renders stars without exposing the secret")
PY

echo "PASS: init UX picker, masking, review, and wiring"
