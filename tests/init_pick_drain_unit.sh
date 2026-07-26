#!/usr/bin/env bash
# DIVE-1398: a typed numeric shortcut in _init_pick must consume its terminating
# Enter, so the newline does not leak into the following prompt as an empty
# submission. This exercises the real interactive (PTY) branch of _init_pick.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Driver script run *inside* a PTY: source the wizard's helpers, pick via the
# "2" shortcut, then read a text field. If the shortcut's Enter leaks, the text
# read returns empty and we print MODEL=<empty>.
DRIVER="$(mktemp)"
cat > "$DRIVER" <<DRV
set -euo pipefail
# Pull in just the helper functions without running cmd_init.
source "$ROOT/src/cmd_init.sh"
export COLUMNS=80
_init_pick provider "provider:" 1 \
  "anthropic|Anthropic|Claude" \
  "openrouter|OpenRouter|Broad catalog" \
  "openai|OpenAI|GPT"
_init_text model "Model"
printf 'PROVIDER=%s\n' "\$provider"
printf 'MODEL=%s\n' "\$model"
DRV

# Feed "2" + Enter (selects OpenRouter) then "sonnet-4" + Enter (the model).
# Drive it through a real PTY so _init_pick takes its interactive -n1 branch.
OUT="$(python3 - "$DRIVER" <<'PY'
import os, pty, sys, time
driver = sys.argv[1]
out = bytearray()
def read(fd):
    data = os.read(fd, 1024)
    out.extend(data)
    return data
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", driver])
else:
    # Send the whole scripted input up front, exactly as an ssh -tt paste would:
    # "2\r" (shortcut+Enter) immediately followed by the model line.
    time.sleep(0.3)
    os.write(fd, b"2\r")
    time.sleep(0.3)
    os.write(fd, b"sonnet-4\r")
    try:
        while True:
            read(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
PY
)"
rm -f "$DRIVER"

# The PTY turns \n into \r\n, so strip carriage returns before comparing.
OUT="${OUT//$'\r'/}"
provider_line="$(printf '%s\n' "$OUT" | grep '^PROVIDER=' | tail -1 || true)"
model_line="$(printf '%s\n' "$OUT" | grep '^MODEL=' | tail -1 || true)"

fail() { echo "FAIL: $1" >&2; echo "--- transcript ---" >&2; printf '%s\n' "$OUT" >&2; exit 1; }

[[ "$provider_line" == "PROVIDER=openrouter" ]] || fail "shortcut '2' should select openrouter (got: '$provider_line')"
[[ "$model_line" == "MODEL=sonnet-4" ]] || fail "model must be 'sonnet-4', not eaten by leaked Enter (got: '$model_line')"

echo "PASS: numeric shortcut drains its terminating Enter (no leak into next prompt)"
