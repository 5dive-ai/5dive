#!/usr/bin/env bash
# DIVE-4230 unit: the heartbeat's same-account spread gate must let two seats on
# the same account wake in the SAME tick, while still spacing wakes ACROSS ticks.
#
# THE DEFECT. The gate computed gap = everyMin*60/acct_count (11 seats at 5m ->
# 27s) and then bumped its own reference to `now` after every wake inside the
# tick, so every later same-account seat in that pass failed `now - last < gap`.
# At most ONE seat per account woke per tick; with ten due, nine were deferred
# every tick and the fleet starved (2026-09-10: 'spread-deferred 6' on one tick,
# dev3 deferred six ticks in a row with 7 todo). The fix drops the in-tick bump
# and keeps the cross-tick spacing that lastRunAt already provides.
#
# WHAT IS ASSERTED HERE
#   A. Same tick, two seats on one account, both due: BOTH pass the gate.
#   B. Cross-tick spacing is kept: a seat whose account-mate woke 10s ago (gap
#      150s) is deferred.
#   C. The deferral log prints the ages in SECONDS ('last woke Ns ago, need a Ns gap').
#   D. NON-VACUITY: re-inserting the in-tick bump into the extracted block makes
#      arm A red — so this harness catches the bug's return, not just today's shape.
#   E. Structural: src/cmd_heartbeat.sh carries no in_tick_woke reference.
#
# The gate block is extracted VERBATIM from src/cmd_heartbeat.sh at run time
# (not reimplemented), wrapped so `continue` becomes `return 1`; _hb_log is
# stubbed to capture. Pure: fixture registries as strings, no root, no tmux, no db.
#   bash tests/heartbeat_spread_gate_unit.sh
# TIER: core — 1s measured (pristine, 2026-09-10): five bash arms over jq fixtures, no I/O beyond the source read.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/cmd_heartbeat.sh"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   - $1"; }
bad()  { fail=$((fail+1)); echo "FAIL - $1"; }

# --- extract the gate block verbatim: from the section banner to the closing `    fi` ---
extract_block() {
  awk '/# --- Same-account spread/{p=1} p{print} p && /^    fi$/{exit}' "$SRC"
}
BLOCK=$(extract_block)
[[ -n "$BLOCK" ]] || { bad "gate block not found in $SRC"; exit 1; }
[[ "$BLOCK" == *'if (( acct_count > 1 ))'* ]] && ok "extracted the same-account spread block verbatim from src/cmd_heartbeat.sh" \
  || bad "extracted block does not contain the account gate"

LOGS=""
_hb_log() { LOGS+="$*"$'\n'; }

# spread_gate <name> <registry-json> <now> <everyMin>: 0 = wake, 1 = defer
define_gate() {   # $1 = block text
  eval "spread_gate() { local name=\"\$1\" reg=\"\$2\" now=\"\$3\" everyMin=\"\$4\"; local sk_spread=0
$(printf '%s\n' "$1" | sed 's/^\([[:space:]]*\)continue$/\1return 1/')
  return 0; }"
}
define_gate "$BLOCK"

reg_two() {   # two seats on account mark, everyMin 5; $1 = a1 lastRunAt, $2 = a2 lastRunAt
  printf '{"agents":{"a1":{"authProfile":"mark","heartbeat":{"enabled":true,"everyMin":5,"lastRunAt":%s}},"a2":{"authProfile":"mark","heartbeat":{"enabled":true,"everyMin":5,"lastRunAt":%s}}}}' "$1" "$2"
}
NOW=1800000000

# A. same tick, both due (each last woke 10 min ago, gap = 300/2 = 150s): both pass
REG=$(reg_two $((NOW-600)) $((NOW-600)))
r1=0; spread_gate a1 "$REG" "$NOW" 5 || r1=$?
r2=0; spread_gate a2 "$REG" "$NOW" 5 || r2=$?
[[ $r1 -eq 0 && $r2 -eq 0 ]] && ok "A: two same-account seats due in the same tick BOTH pass the gate (rc $r1/$r2)" \
  || bad "A: same-tick wakes serialised again (a1 rc=$r1, a2 rc=$r2)"

# B. cross-tick spacing kept: a2 woke 10s ago -> a1 (gap 150s) is deferred
REG=$(reg_two $((NOW-600)) $((NOW-10)))
LOGS=""; r=0; spread_gate a1 "$REG" "$NOW" 5 || r=$?
[[ $r -eq 1 ]] && ok "B: a seat whose account-mate woke 10s ago is deferred (gap 150s kept across ticks)" \
  || bad "B: cross-tick spacing lost (rc=$r)"

# C. the deferral line prints seconds
[[ "$LOGS" =~ last\ woke\ 10s\ ago,\ need\ a\ 150s\ gap ]] && ok "C: deferral log prints seconds: $(printf '%s' "$LOGS" | grep -o 'last woke.*gap')" \
  || bad "C: deferral log does not print seconds — got: ${LOGS:-<empty>}"

# D. NON-VACUITY: put the in-tick bump back into the extracted block; arm A must red.
MUT=$(printf '%s\n' "$BLOCK" | sed 's/^\([[:space:]]*\)gap=\$(( everyMin \* 60 \/ acct_count ))$/\1if [[ -n "${in_tick_woke[$acct]:-}" ]] \&\& (( in_tick_woke[$acct] > acct_last )); then acct_last=${in_tick_woke[$acct]}; fi\n&/')
[[ "$MUT" != "$BLOCK" ]] || bad "D: mutant did not apply (gap= line not found)"
declare -A in_tick_woke=()
define_gate "$MUT"
REG=$(reg_two $((NOW-600)) $((NOW-600)))
m1=0; spread_gate a1 "$REG" "$NOW" 5 || m1=$?
in_tick_woke[mark]=$NOW                    # what the old loop did after a1's wake
m2=0; spread_gate a2 "$REG" "$NOW" 5 || m2=$?
[[ $m1 -eq 0 && $m2 -eq 1 ]] && ok "D: with the in-tick bump re-inserted, the second seat is deferred again — arm A would red (non-vacuous)" \
  || bad "D: mutant not caught (a1 rc=$m1, a2 rc=$m2)"
define_gate "$BLOCK"   # restore

# E. structural
n=$(grep -c 'in_tick_woke' "$SRC" || true)
[[ "$n" -eq 0 ]] && ok "E: src/cmd_heartbeat.sh carries no in_tick_woke reference" || bad "E: in_tick_woke still referenced $n time(s)"

echo; echo "heartbeat_spread_gate_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
