#!/usr/bin/env bash
# DIVE-1326: PTY-level coverage for the init onboarding controls. This drives
# real arrow-key bytes and secret input through a pseudo-terminal; no root,
# network, auth, install, or agent state is touched.
set -euo pipefail
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

[[ "$body" == *'_init_section 4 4 "Review and create"'* ]] \
  || { echo "FAIL: missing pre-create review stage" >&2; exit 1; }

python3 - "$(pwd)" <<'PY'
import errno
import os
import pty
import select
import shlex
import sys
import time

root = sys.argv[1]


def drive(shell_body, interactions, timeout=5, term="xterm-256color"):
    pid, fd = pty.fork()
    if pid == 0:
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
            os.write(fd, payload)

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
