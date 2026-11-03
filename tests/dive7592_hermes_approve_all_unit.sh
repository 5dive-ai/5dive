#!/usr/bin/env bash
# DIVE-7592 — a Hermes seat stalled on Hermes' own "Dangerous Command" dialog.
#
# init-smoke run 41564728440 (hermes-standard / ubuntu-24.04): the model ran
# `python3 -c 'print(444 + 532)'`, Hermes flagged it ("script execution via -e/-c
# flag") and its Allow/Deny dialog waited 4m57s for a keypress nobody gives. The
# fix starts the seat's pane in Hermes' approve-all mode (HERMES_YOLO_MODE=1, what
# `hermes --yolo` sets), as grok and antigravity already run.
#
#   Y1  a hermes seat's pane exports HERMES_YOLO_MODE=1; no other type gets it.
#   Y2  the launch line (INNER) carries it, before the run loop starts hermes.
#   Y3  it is exported nowhere else: the gateway the boot script starts beside a
#       seat (and Telegram's approval buttons) does not inherit it.
#   Y4  the pane's shell, as built, hands it to the process it runs.
#   R1  REAL HERMES (skipped when not installed): the failing run's exact command,
#       under the pane's environment, raises no dialog; without it, it does (the
#       negative control — the stall is real, and the switch is what clears it).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
START=bin/5dive-agent-start

PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'skip - %s (%s)\n' "$1" "$2"; }
eq_t()   { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

BLOCK=$(awk '/^HERMES_OVERRIDE=""$/ {on=1} on {print} on && /^fi$/ {exit}' "$START")
[[ -n "$BLOCK" ]] || bad_t "the HERMES_OVERRIDE block is in $START" "not found"
override() { ( TYPE="$1"; eval "$BLOCK"; printf '%s' "$HERMES_OVERRIDE" ); }

# --- Y1: hermes only -------------------------------------------------------------
eq_t "Y1 hermes: the pane exports HERMES_YOLO_MODE=1" "export HERMES_YOLO_MODE=1; " "$(override hermes)"
got=""
for t in claude codex grok antigravity openclaw opencode pi devin; do got+="$t:[$(override "$t")] "; done
eq_t "Y1 no other type gets it" "claude:[] codex:[] grok:[] antigravity:[] openclaw:[] opencode:[] pi:[] devin:[] " "$got"

# --- Y2: on the launch line, before the loop ------------------------------------
inner=$(grep -E '^INNER=' "$START")
[[ "$inner" == *'${HERMES_OVERRIDE}'*'${LOOP}'* ]] \
  && ok_t "Y2 INNER carries \${HERMES_OVERRIDE} before \${LOOP}" \
  || bad_t "Y2 INNER carries \${HERMES_OVERRIDE} before \${LOOP}" "$inner"

# --- Y3: nowhere else -----------------------------------------------------------
uses=$(grep -n 'HERMES_YOLO_MODE' "$START" | grep -vE '^[0-9]+:[[:space:]]*#')
eq_t "Y3 HERMES_YOLO_MODE is set in one place, the pane's override string" \
  '  HERMES_OVERRIDE="export HERMES_YOLO_MODE=1; "' "$(printf '%s\n' "$uses" | cut -d: -f2-)"

# --- Y4: the shell hands it on ---------------------------------------------------
eq_t "Y4 the pane's shell passes it to what it runs" "1" \
  "$(env -u HERMES_YOLO_MODE bash -c "$(override hermes) printenv HERMES_YOLO_MODE")"
eq_t "Y4 negative: a grok pane's shell does not" "" \
  "$(env -u HERMES_YOLO_MODE bash -c "$(override grok) printenv HERMES_YOLO_MODE")"

# --- R1: real hermes -------------------------------------------------------------
HSRC="${HERMES_SRC:-/home/claude/.hermes/hermes-agent}"
PY="$HSRC/venv/bin/python"
probe() {   # <pane override> → "asked" | "not-asked" (the dialog is the approval callback)
  local home; home=$(mktemp -d)
  env -u HERMES_YOLO_MODE HERMES_INTERACTIVE=1 HERMES_HOME="$home" bash -c "$1 cd $(printf %q "$HSRC") && timeout 30 $(printf %q "$PY") -I -c '
import sys; sys.path.insert(0, \".\")
from tools.approval import check_all_command_guards
asked = []
def dialog(*a, **k):
    asked.append(a)
    return \"deny\"
r = check_all_command_guards(\"python3 -c \\x27print(444 + 532)\\x27\", \"local\", approval_callback=dialog)
print(\"asked\" if asked else (\"not-asked\" if r.get(\"approved\") else \"blocked\"))
'" </dev/null 2>/dev/null | tail -1
  rm -rf "$home"
}
if [[ -x "$PY" && -f "$HSRC/tools/approval.py" ]]; then
  eq_t "R1 negative control: without it, Hermes raises its dialog for the failing run's command" "asked" "$(probe "")"
  eq_t "R1 under the hermes pane's environment: no dialog, the command runs" "not-asked" "$(probe "$(override hermes)")"
else
  skip_t "R1 real hermes" "no hermes install at $HSRC (set HERMES_SRC)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
