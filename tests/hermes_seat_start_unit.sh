#!/usr/bin/env bash
# DIVE-7330: every new Hermes seat was dead on arrival, and `5dive init` asked
# for the Hermes key twice.
#   1. the recipe installed upstream hermes unpinned; 0.21.6+ keeps its
#      dependency env per HERMES_HOME and every seat has its own, so the seat's
#      hermes refused to start. The recipe is now pinned (installer + tree).
#   2. `hermes auth add` read the key from /dev/tty, not the pipe, whenever
#      create ran on a real terminal. Graded here UNDER A PTY with a fake hermes
#      that prompts on /dev/tty exactly when it can open it, as getpass does.
#   3. create's self-check runs the harness as the seat, and so does the
#      nightly harness smoke, so the next "starts as claude, dies as the seat"
#      is a named issue instead of a PASS.
# Run: bash tests/hermes_seat_start_unit.sh (no root, no network, ~2s)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT=$PWD

PASS=0 FAIL=0
ok_t()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad_t() { FAIL=$((FAIL+1)); echo "FAIL $1${2:+ — $2}"; }

# --- 1. the recipe is pinned --------------------------------------------------
# shellcheck disable=SC1091
source src/header.sh
recipe="${TYPE_INSTALL[hermes]}"
[[ "$HERMES_PIN_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  && ok_t "the pin is a full commit sha" || bad_t "the pin is not a full sha" "$HERMES_PIN_COMMIT"
[[ "$recipe" == *"NousResearch/hermes-agent/${HERMES_PIN_COMMIT}/scripts/install.sh"* ]] \
  && ok_t "the installer comes from the pinned commit" || bad_t "the installer is not the pinned commit's" "$recipe"
[[ "$recipe" == *"--commit ${HERMES_PIN_COMMIT}"* && "$recipe" == *"--branch ${HERMES_PIN_TAG}"* ]] \
  && ok_t "the installer checks out the pinned tree" || bad_t "the tree is not pinned" "$recipe"
[[ "$recipe" != *"hermes-agent.nousresearch.com/install.sh"* ]] \
  && ok_t "no unpinned upstream installer" || bad_t "the unpinned installer is still used" "$recipe"
[[ "$recipe" == "[[ -x ${TYPE_BIN[hermes]} ]] ||"* ]] \
  && ok_t "the recipe still skips an installed hermes" || bad_t "the idempotence guard moved" "$recipe"

# --- 2. the key goes in once, from the pipe, on a real terminal ---------------
mkdir -p "$TMP/rec"
cat > "$TMP/hermes" <<'FAKE'
#!/bin/bash
# getpass: prompt on /dev/tty when the process can open it, else read stdin.
printf '%s\n' "$*" >> "$REC/argv"
if [[ "$1 $2" == "auth add" ]]; then
  [[ "${FAKE_AUTH_FAIL:-0}" == 1 ]] && { echo "Unknown provider: $3" >&2; exit 5; }
  if { : 3<>/dev/tty; } 2>/dev/null; then
    echo "Paste your API key: " > /dev/tty
    echo prompted > "$REC/tty"
    exit 7
  fi
  cat > "$REC/key"
fi
exit 0
FAKE
chmod +x "$TMP/hermes"
cat > "$TMP/inner.sh" <<INNER
set -uo pipefail
cd "$ROOT"
source src/header.sh
source src/lib/validation.sh
source src/lib/models.sh
source src/lib/agent_setup.sh
source src/cmd_agent_create.sh
TYPE_BIN[hermes]="$TMP/hermes"
E_GENERIC=1 E_NOT_INSTALLED=1
step() { :; }
warn() { :; }
fail() { echo "FAILED: \$*"; exit 9; }
sudo() { [[ "\$1" == -u ]] && shift 2; [[ "\$1" == -H ]] && shift; "\$@"; }
_apply_byo_hermes anthropic anthropic sk-ant-test-7330 ""
echo "APPLIED rc=\$?"
INNER
# Run it with a controlling terminal: pty.fork makes the child a session leader
# whose ctty is the pty, which is what `5dive init` on a person's terminal is.
under_pty() {
  REC="$TMP/rec" FAKE_AUTH_FAIL="${FAKE_AUTH_FAIL:-0}" timeout 30 python3 - "$TMP/inner.sh" <<'PY'
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", sys.argv[1]])
out = b""
while True:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(status))
PY
}
rc=0; out=$(under_pty) || rc=$?
[[ $rc -eq 0 && "$out" == *"APPLIED rc=0"* ]] \
  && ok_t "on a terminal the BYO write finishes" || bad_t "on a terminal the BYO write did not finish" "rc=$rc $out"
[[ ! -e "$TMP/rec/tty" ]] \
  && ok_t "hermes never asks for the key on the terminal" || bad_t "hermes prompted on /dev/tty (the second key prompt)" "$out"
[[ "$(cat "$TMP/rec/key" 2>/dev/null)" == sk-ant-test-7330 ]] \
  && ok_t "the key reaches hermes on stdin" || bad_t "the key did not reach hermes on stdin" "$(cat "$TMP/rec/key" 2>/dev/null)"
grep -qF sk-ant-test-7330 "$TMP/rec/argv" \
  && bad_t "the key was on argv" "$(cat "$TMP/rec/argv")" || ok_t "never on argv"
[[ "$out" != *"Paste your API key"* ]] \
  && ok_t "no hermes prompt text on a clean write" || bad_t "hermes' prompt text leaked on success" "$out"

rm -rf "$TMP/rec"; mkdir -p "$TMP/rec"
rc=0; out=$(FAKE_AUTH_FAIL=1 under_pty) || rc=$?
[[ $rc -eq 9 && "$out" == *"Unknown provider: anthropic"* && "$out" == *"FAILED:"*"hermes auth add anthropic failed"* ]] \
  && ok_t "a refused key fails the create and shows hermes' reason" || bad_t "a refused key" "rc=$rc $out"

# --- 3. the seat-level start checks -------------------------------------------
create_src=$(cat src/cmd_agent_create.sh)
[[ "$create_src" == *'sudo -u "agent-${name}" -H timeout 60 "${TYPE_BIN[hermes]}" --version'* ]] \
  && ok_t "create's self-check runs hermes as the seat" || bad_t "no seat-level hermes start check in create"
[[ "$create_src" == *'_hc_issues+=("hermes does NOT start as agent-${name}'* ]] \
  && ok_t "a seat hermes that does not start is a self-check issue" || bad_t "a dead seat hermes is not an issue"
[[ "$create_src" == *'elif [[ -z "$profile" && -s /home/claude/.hermes/config.yaml ]]; then'* ]] \
  && ok_t "no openai-codex pin over the box's own hermes config" || bad_t "the openai-codex pin still runs over the box config"
smoke_src=$(cat scripts/harness-smoke.sh)
[[ "$smoke_src" == *'step seat-version'* && "$smoke_src" == *'sudo -u "agent-${name}" -H timeout 60 "$bin" --version'* ]] \
  && ok_t "the nightly harness smoke runs the harness as the seat" || bad_t "harness smoke has no seat-level start step"

TOTAL=$((PASS+FAIL))
if (( FAIL )); then echo "FAIL: $FAIL of $TOTAL hermes seat-start arms failed"
else echo "PASS: $PASS of $TOTAL hermes seat-start arms"; fi
(( FAIL == 0 && TOTAL > 0 ))
