#!/usr/bin/env bash
# DIVE-5014: the busy check was blind on main. `_agent_busy_state` asked the
# board (no row — a Telegram conversation is not a row) and then the native
# signal, `claude agents --json`. main sets `disableAgentView: true`, which makes
# that command print a refusal and exit 1, and rc 1 meant "no reading changes
# nothing" -> idle -> the v0.55.0 self-update restarted main mid-answer
# (2026-09-26 02:01:36Z).
#
# The fix: when the native reading is ABSENT, ask the pane (`_hb_agent_pane_idle`,
# the pane half of `_hb_agent_idle`, split out so it can be asked alone) before
# concluding idle. No pane at all still reads idle — that is what keeps codex
# seats restartable.
#
# Part A drives the pane probe with fixture panes (sudo/sleep stubbed, no tmux).
# Part B extracts the DIVE-3173 block from src/cmd_selfupdate.sh VERBATIM, the
# shape tests/self_update_busy_defer_unit.sh established, and composes it with
# the REAL pane probe from Part A.
# Run: bash tests/dive5014_busy_pane_fallback_unit.sh  (no root, no network, no tmux).
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"; export PENDING_RESTART_DIR="$WORK/pending"

# ------------------------------------------------------------------ fixtures --
# Shapes of a real Claude Code pane. MID_TURN's spinner line is copied from a
# live agent-dev pane, 2026-09-26, mid-turn — note it carries NO "esc to
# interrupt"; today's Claude Code dropped that suffix from the spinner.
RULE='────────────────────────────────────────'
MID_TURN="● Bash(5dive task show DIVE-5014)
  ⎿  ident = DIVE-5014

✻ Fermenting… (1m 39s · ↓ 9.1k tokens · thought for 2s)
  ⎿  Tip: Use /btw to ask a quick side question without interrupting

$RULE
❯
$RULE
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
OLD_MID_TURN="● Reading files

✳ Cogitating… (7s · esc to interrupt)

$RULE
❯
$RULE"
# A FINISHED turn whose transcript QUOTES both busy shapes — the row body did.
# Only the status line may decide, or this seat reads busy forever.
DONE_QUOTING="● The ask: fall back to the \"esc to interrupt\" line.
  e.g. ✻ Fermenting… (1m 39s · ↓ 9.1k tokens)

✻ Worked for 9m 11s · done 8:09 AM

$RULE
❯
$RULE"
DIALOG="Do you want to proceed?
  1. Yes
  2. No"

# sudo stub: each call to `sudo -u … tmux capture-pane` prints the next fixture
# named in $PANES (a file: $(…) subshells cannot share a counter otherwise).
# An empty entry means "capture failed" (no session).
PANES="$WORK/panes"; CALLS="$WORK/calls"
panes() { printf '%s\n' "$@" > "$PANES"; : > "$CALLS"; }
sudo() {
  local i; printf x >> "$CALLS"; i=$(wc -c < "$CALLS")
  local key; key=$(sed -n "${i}p" "$PANES")
  [[ -n "$key" ]] || return 1
  printf '%s\n' "${!key}"
}
sleep() { :; }
agent_type() { printf 'claude'; }
pane_rc() { _hb_agent_pane_idle main 0; echo $?; }

# ------------------------------------------------ Part A: the pane probe -----
panes MID_TURN MID_TURN
if [[ "$(pane_rc)" == 1 ]]; then
  ok_t "a live spinner on the status line reads BUSY even on two byte-identical samples"
else
  bad_t "a mid-turn pane read idle" "rc=$(pane_rc) — the restart-mid-answer shape"
fi
panes MID_TURN MID_TURN; pane_rc >/dev/null
if [[ "$(wc -c < "$CALLS")" == 1 ]]; then
  ok_t "the status-line answer is taken from ONE sample (no second capture, no sleep)"
else
  bad_t "the status-line check still sampled twice" "captures=$(wc -c < "$CALLS")"
fi
panes OLD_MID_TURN OLD_MID_TURN
if [[ "$(pane_rc)" == 1 ]]; then
  ok_t "the older '(7s · esc to interrupt)' status line reads BUSY"
else
  bad_t "an 'esc to interrupt' status line read idle" "rc=$(pane_rc)"
fi
panes DONE_QUOTING DONE_QUOTING
if [[ "$(pane_rc)" == 0 ]]; then
  ok_t "a finished turn whose transcript QUOTES both busy shapes reads idle (status line only)"
else
  bad_t "quoted text above the status line read busy" "rc=$(pane_rc) — the seat would never take a restart"
fi
panes DONE_QUOTING MID_TURN
if [[ "$(pane_rc)" == 1 ]]; then
  ok_t "two samples that differ read BUSY (the heartbeat's two-sample diff, unchanged)"
else
  bad_t "a changing pane read idle" "rc=$(pane_rc)"
fi
panes DIALOG DIALOG
if [[ "$(pane_rc)" == 1 ]]; then
  ok_t "a byte-stable pane NOT at the composer (a dialog) reads BUSY"
else
  bad_t "a dialog read idle" "rc=$(pane_rc)"
fi
panes '' ''
if [[ "$(pane_rc)" == 2 ]]; then
  ok_t "no pane at all is rc 2 (no signal), not busy"
else
  bad_t "an absent pane did not read no-signal" "rc=$(pane_rc)"
fi
# _hb_agent_idle's fallback IS the probe: same pane, same rc.
_hb_agent_native_state() { return 1; }
panes MID_TURN MID_TURN; _hb_agent_idle main 0; a_rc=$?
panes DONE_QUOTING DONE_QUOTING; _hb_agent_idle main 0; b_rc=$?
if [[ "$a_rc" == 1 && "$b_rc" == 0 ]]; then
  ok_t "_hb_agent_idle with native unavailable delegates to the same probe (1 mid-turn, 0 done)"
else
  bad_t "_hb_agent_idle's fallback diverged from _hb_agent_pane_idle" "mid=$a_rc done=$b_rc"
fi
unset -f _hb_agent_native_state

# MUTANT: drop the spinner match and the live-pane fixture reads idle again.
mut="$(declare -f _hb_agent_pane_idle | grep -v "0-9]+\[smh\]")"
if [[ "$mut" != "$(declare -f _hb_agent_pane_idle)" ]]; then
  mut_rc="$( eval "$mut"; panes MID_TURN MID_TURN; _hb_agent_pane_idle main 0; echo $? )"
  if [[ "$mut_rc" == 0 ]]; then
    ok_t "MUTANT: without the spinner match, today's mid-turn pane reads idle — the arm above is not vacuous"
  else
    bad_t "mutant must reproduce the blind spot" "rc=$mut_rc"
  fi
else
  bad_t "the spinner mutation is a no-op" "the arm above would pass vacuously"
fi

# ------------------------------- Part B: _agent_busy_state and _restart_decide --
block="$(sed -n '/^# >>> DIVE-3173 deferred restart for a busy agent/,/^# <<< DIVE-3173 deferred restart for a busy agent/p' \
  src/cmd_selfupdate.sh)"
if grep -q '_agent_busy_state()' <<<"$block" && grep -q '_restart_decide()' <<<"$block"; then
  ok_t "the DIVE-3173 block is extractable and carries _agent_busy_state and _restart_decide"
else
  bad_t "DIVE-3173 block missing" "fence markers not found"; echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
BOARD_IDLE='db(){ echo 0; }; sqlq(){ printf "%s" "$1"; }'
# What main's native probe does under disableAgentView: prints nothing, rc 1.
NATIVE_BLIND='_hb_agent_native_state(){ return 1; }'
bsp() { ( eval "$BOARD_IDLE"; eval "$1"; eval "$2"; eval "$block"; _agent_busy_state main ); }

if [[ "$(bsp "$NATIVE_BLIND" '_hb_agent_pane_idle(){ return 1; }')" == busy ]]; then
  ok_t "THE DEFECT'S CELL: board idle + native UNREADABLE + pane working reads busy"
else
  bad_t "native rc 1 still short-circuited to idle" "got '$(bsp "$NATIVE_BLIND" '_hb_agent_pane_idle(){ return 1; }')' — main is restarted mid-answer"
fi
if [[ "$(bsp "$NATIVE_BLIND" '_hb_agent_pane_idle(){ return 0; }')" == idle ]]; then
  ok_t "native unreadable + pane at rest reads idle — main still takes its restart between turns"
else
  bad_t "an idle pane did not read idle" "NEVER FIRES for main"
fi
if [[ "$(bsp "$NATIVE_BLIND" '_hb_agent_pane_idle(){ return 2; }')" == idle ]]; then
  ok_t "native unreadable + NO pane reads idle — a runtime with neither signal (codex) still restarts"
else
  bad_t "no signal at all deferred" "codex seats would never take a payload update"
fi
PANE_CALLS="$WORK/pane.calls"; : > "$PANE_CALLS"
if [[ "$(bsp '_hb_agent_native_state(){ printf idle; }' '_hb_agent_pane_idle(){ printf 1 >>"$PANE_CALLS"; return 1; }')" == idle ]] \
   && [[ ! -s "$PANE_CALLS" ]]; then
  ok_t "a DEFINITE native idle is not second-guessed by the pane (the fallback is for rc 1 only)"
else
  bad_t "a native idle reading consulted the pane" "calls=[$(cat "$PANE_CALLS")]"
fi
if [[ "$(bsp "$NATIVE_BLIND" ':')" == idle ]]; then
  ok_t "the pane helper ABSENT (split tree) behaves as before — guarded by declare -F"
else
  bad_t "an absent pane helper changed the verdict" "a missing function must not be a silent policy change"
fi

# ACCEPTANCE: native rc 1 and the REAL pane probe on a live turn -> busy ->
# `_restart_decide` writes the marker and says deferred; nothing restarts
# (the verb never restarts — the caller does, only on `restart`).
out="$(
  eval "$BOARD_IDLE"; eval "$NATIVE_BLIND"; unset REGISTRY
  eval "$block"
  panes MID_TURN MID_TURN
  _restart_decide main "payload changed"
)"
if [[ "$out" == "deferred busy" && -f "$PENDING_RESTART_DIR/main" ]]; then
  ok_t "ACCEPTANCE: _restart_decide main during a Telegram-only turn prints 'deferred busy' and writes the marker"
else
  bad_t "main mid-turn was not deferred" "verdict='$out' marker=$([[ -f "$PENDING_RESTART_DIR/main" ]] && echo yes || echo no)"
fi
rm -rf "$PENDING_RESTART_DIR"
out="$(
  eval "$BOARD_IDLE"; eval "$NATIVE_BLIND"; unset REGISTRY
  eval "$block"
  panes DONE_QUOTING DONE_QUOTING
  _restart_decide main "payload changed"
)"
if [[ "$out" == "restart idle" && ! -f "$PENDING_RESTART_DIR/main" ]]; then
  ok_t "the same verb on main between turns says 'restart idle' and writes no marker"
else
  bad_t "an idle main was deferred" "verdict='$out'"
fi

# MUTANT: delete the fallback and the acceptance cell reads idle again.
mut_block="$(printf '%s\n' "$block" | sed '/if (( prc == 1 )); then printf .busy/d')"
if [[ "$mut_block" != "$block" ]]; then
  mut_state="$( eval "$BOARD_IDLE"; eval "$NATIVE_BLIND"; eval "$mut_block"; panes MID_TURN MID_TURN; _agent_busy_state main )"
  if [[ "$mut_state" == idle ]]; then
    ok_t "MUTANT: without the pane fallback, native rc 1 + a live turn reads 'idle' — the 02:01Z restart, live"
  else
    bad_t "mutant must reproduce the defect" "got '$mut_state' — the arms above are vacuous"
  fi
else
  bad_t "the fallback mutation is a no-op" "the acceptance arm would pass vacuously"
fi

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
