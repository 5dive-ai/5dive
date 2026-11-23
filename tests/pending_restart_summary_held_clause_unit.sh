#!/usr/bin/env bash
# DIVE-9079 — the heartbeat's `[pending-restart] pass done` summary must say
# "restart held … desiredState=stopped" ONLY when a restart is actually left
# parked. Printed unconditionally, it blamed every deferred/bounced seat on a
# registry/unit mismatch: teal-fox logged 8,277 such lines with 0 parked, and
# two canary boxes each lost a round ruling out a parked-seat regression.
#
# Arms:
#   1. _PR_PARKED=0, other counters >0 -> summary logged, no HELD/desiredState
#   2. _PR_PARKED=1 -> the explanation sits right after "1 left parked"
#   3. NEGATIVE CONTROL: arm 1 against origin/main's pre-fix line (read through
#      git, the clause unconditional) must FAIL
#   4. only src/cmd_heartbeat.sh sourced, `set -u`, counters unset -> nothing
#      logged and the shell does not abort
# Run: bash tests/pending_restart_summary_held_clause_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pr-summary-held.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Run the summary in a child bash with ONLY src/cmd_heartbeat.sh sourced and
# `set -u` on — the shape ~10 harnesses drive the tick in. $1 = file holding the
# summary function; the remaining args are counter assignments.
run_summary() {
  local src="$1"; shift
  env -i PATH="$PATH" HOME="$TMP" bash -c '
    src="$1"; shift
    # shellcheck source=/dev/null
    source src/cmd_heartbeat.sh 2>/dev/null
    # shellcheck source=/dev/null
    [ "$src" = "-" ] || source "$src"
    _hb_log() { printf "%s\n" "$*"; }
    for kv in "$@"; do export "$kv"; done
    set -u
    _hb_pending_restart_summary
    echo "ALIVE"
  ' _ "$src" "$@"
}

# ---- arm 1 --------------------------------------------------------------------
out="$(run_summary - _PR_DEFERRED=1 _PR_OVERDUE=1 _PR_PARKED=0)"
line="$(printf '%s\n' "$out" | grep '\[pending-restart\] pass done')"
if [ -n "$line" ] && ! printf '%s' "$line" | grep -qiE 'held|desiredState'; then
  ok_t "arm 1: 0 parked, 1 deferred -> summary logged with no HELD/desiredState"
else
  bad_t "arm 1: 0 parked must not name the parked cause" "got: $out"
fi
out="$(run_summary - _PR_FIRED=1 _PR_PARKED=0)"
line="$(printf '%s\n' "$out" | grep '\[pending-restart\] pass done')"
if [ -n "$line" ] && ! printf '%s' "$line" | grep -qiE 'held|desiredState'; then
  ok_t "arm 1b: 0 parked, 1 bounced -> no HELD/desiredState (chill-gorge's line)"
else
  bad_t "arm 1b: 0 parked, 1 bounced must not name the parked cause" "got: $out"
fi

# ---- arm 2 --------------------------------------------------------------------
out="$(run_summary - _PR_DEFERRED=1 _PR_PARKED=1)"
if printf '%s' "$out" | grep -qE '1 left parked \(restart held until the registry and the unit agree, desiredState=stopped\)$'; then
  ok_t "arm 2: 1 parked -> explanation attached to '1 left parked'"
else
  bad_t "arm 2: the parked explanation must follow '1 left parked'" "got: $out"
fi

# ---- arm 3: negative control --------------------------------------------------
pre="$TMP/prefix.sh"
prefix_line="$(git show origin/main:src/cmd_heartbeat.sh 2>/dev/null \
  | grep -A1 -F '(( ${_PR_FIRED:-0} || ${_PR_DEFERRED:-0}' | head -2)"
if [ -z "$prefix_line" ] || ! printf '%s' "$prefix_line" | grep -q 'restart HELD'; then
  echo "SKIP - arm 3: origin/main no longer carries the pre-fix line (nothing to control against)"
else
  printf '_hb_pending_restart_summary() {\n%s\n}\n' "$prefix_line" >"$pre"
  out="$(run_summary "$pre" _PR_DEFERRED=1 _PR_OVERDUE=1 _PR_PARKED=0)"
  if printf '%s' "$out" | grep -q 'pass done' && printf '%s' "$out" | grep -qiE 'held|desiredState'; then
    ok_t "arm 3: NEGATIVE CONTROL — the pre-fix line logs HELD with 0 parked (arm 1 would fail on it)"
  else
    bad_t "arm 3: the pre-fix line was expected to log HELD with 0 parked" "got: $out"
  fi
fi

# ---- arm 4 --------------------------------------------------------------------
out="$(run_summary -)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ALIVE" ]; then
  ok_t "arm 4: counters unset under set -u -> nothing logged, no abort"
else
  bad_t "arm 4: unset counters must log nothing and not abort" "rc=$rc out: $out"
fi

printf '\n%d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
