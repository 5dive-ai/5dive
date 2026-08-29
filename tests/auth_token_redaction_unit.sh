#!/usr/bin/env bash
# DIVE-3811 — `5dive agent auth login claude` must not print the 1-year OAuth
# token to the operator's terminal, and must stay INTERACTIVE while it doesn't.
#
# The token is upstream's output (`claude setup-token` prints it in the clear),
# but the stream is ours: we run it under `script` so we can capture the token
# and persist it. Masking it on the way to the terminal is therefore free — the
# operator loses nothing, because we already stored it for them.
#
# The interactivity half is the part that can regress silently: setup-token
# writes its "paste the code" prompt with NO trailing newline, so any
# line-oriented filter (sed -u, awk) holds that prompt forever and the login
# looks hung with no error anywhere. Case 2 is the arm that catches that.
#
# Run: bash tests/auth_token_redaction_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/auth-token-redaction.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 absent"; exit 0; }

# Pull in just the two functions under test. cmd_auth.sh is sourced wholesale by
# the suite elsewhere; here we only need the filter and the extractor, and
# sourcing the file needs the header/error-code/output libs it references.
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_auth.sh
set +e

# A fixture token, never a real one: reserved-shape filler only (see the
# test-fixtures rule — a real credential in a harness is the defect this whole
# row is about).
FAKE='sk-ant-oat01-AAAABBBBCCCCDDDDEEEEFFFF0000111122223333444455556666'

# --- case 1: a token in a complete line is masked ------------------------------
out=$(printf '  Your OAuth token (valid for 1 year): %s\n  Store this token securely.\n' "$FAKE" \
        | _redact_oauth_stream)
if [[ "$out" != *"$FAKE"* ]] && [[ "$out" == *"Store this token securely."* ]]; then
  ok_t "case 1: token masked, surrounding output preserved"
else
  bad_t "case 1: token masked, surrounding output preserved" "$out"
fi

# --- case 2: a partial line (no trailing newline) flushes IMMEDIATELY ----------
# The regression this guards: a line-buffered filter would hold the prompt and
# the interactive login would hang with the terminal blank. We hold the writer
# open (so EOF cannot be what flushes it) and require the prompt to arrive.
fifo="$TMP/in"; mkfifo "$fifo"
: > "$TMP/out"
exec 9<>"$fifo"
# 9>&- : the filter must NOT inherit our write end of the fifo, or closing fd 9
# below never delivers EOF and the wait hangs forever.
_redact_oauth_stream < "$fifo" > "$TMP/out" 2>/dev/null 9>&- &
filter_pid=$!
printf 'Paste code here: ' >&9
got=""
for _ in $(seq 1 50); do
  got=$(cat "$TMP/out")
  [[ "$got" == *"Paste code here: "* ]] && break
  sleep 0.1
done
exec 9>&-
wait "$filter_pid" 2>/dev/null
if [[ "$got" == *"Paste code here: "* ]]; then
  ok_t "case 2: newline-less prompt reaches the terminal before EOF (login stays interactive)"
else
  bad_t "case 2: newline-less prompt reaches the terminal before EOF (login stays interactive)" \
        "nothing flushed within 5s; got '$got'"
fi

# --- case 3: a token split across two reads is still masked --------------------
# The filter writes bytes through as they arrive, so the naive implementation
# leaks whichever half of the token lands in the first read.
head="${FAKE:0:20}"; tail_="${FAKE:20}"
out=$( { printf 'token: %s' "$head"; sleep 0.3; printf '%s\n' "$tail_"; } | _redact_oauth_stream )
if [[ "$out" != *"$FAKE"* && "$out" != *"$head"* ]]; then
  ok_t "case 3: token split across reads is masked, neither half leaks"
else
  bad_t "case 3: token split across reads is masked, neither half leaks" "$out"
fi

# --- case 4: end-to-end through script(1), the exact shape cmd_auth_login uses --
# The log keeps the raw token (extract_claude_token has to read it); the piped
# stream — the operator's terminal — must not.
if command -v script >/dev/null 2>&1; then
  log="$TMP/login.log"
  cols=120 rows=40
  seen=$(script -fq -c "stty cols $cols rows $rows >/dev/null 2>&1; \
      printf 'token: %s\n' '$FAKE'; stty size" "$log" | _redact_oauth_stream)
  raw=$(extract_claude_token "$log" 2>/dev/null)
  if [[ "$seen" != *"$FAKE"* ]]; then
    ok_t "case 4a: token absent from the stream that reaches the terminal"
  else
    bad_t "case 4a: token absent from the stream that reaches the terminal" "$seen"
  fi
  if [[ "$raw" == "$FAKE" ]]; then
    ok_t "case 4b: script's log still yields the token to extract_claude_token"
  else
    bad_t "case 4b: script's log still yields the token to extract_claude_token" "got '$raw'"
  fi
  # The pty window size is the cost of piping script's stdout: without the stty
  # prefix the child sees 0 0 and renders into a zero-column terminal.
  if [[ "$seen" == *"$rows $cols"* ]]; then
    ok_t "case 4c: the child pty is sized $rows x $cols despite stdout being a pipe"
  else
    bad_t "case 4c: the child pty is sized $rows x $cols despite stdout being a pipe" "$seen"
  fi
  # Negative control: WITHOUT the stty prefix the same pipeline gives 0 0. If
  # this ever stops holding, case 4c is passing for a reason that is not ours.
  bare=$(script -fq -c "stty size" "$TMP/bare.log" | cat)
  if [[ "$bare" == *"0 0"* ]]; then
    ok_t "case 4d: negative control — no stty prefix really does yield a 0x0 pty"
  else
    bad_t "case 4d: negative control — no stty prefix really does yield a 0x0 pty" "$bare"
  fi
else
  echo "note: script(1) absent — cases 4a-4d not run"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
