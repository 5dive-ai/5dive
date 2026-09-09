#!/usr/bin/env bash
# DIVE-4158 unit: the `agent list` heartbeat badge must report the LAST-RUN AGE,
# not the configured cadence.
#
# The defect (DIVE-4157, 2026-09-09): the badge printed `heartbeat.everyMin`.
# main2 was 68m past a 5m cadence — 13.5 intervals overdue — and rendered `∿5m`,
# byte-identical to a seat that had just ticked. A column that renders a dead
# seat and a live seat the same way is not a weak signal, it is an absent one,
# and it disagrees with reality in the REASSURING direction.
#
# Graded here, against the shared renderer both call sites now use:
#   - two seats on the SAME cadence and DIFFERENT ages render DIFFERENTLY
#     (the whole defect in one arm — this is what `∿5m` could not do);
#   - a seat past 2x its own cadence carries `!` and is NAMED in a legend;
#   - the threshold is a RATIO, not a constant: 20m is fine on a 30m seat and
#     overdue on a 5m one, so the arms cross-check the two directions;
#   - the boundary is strict: exactly 2x is NOT flagged, one second past is;
#   - a seat enrolled and NEVER run reads `never` and IS overdue (zero runs is
#     the alarm state, not a clean one);
#   - clock skew (lastRunAt in the future) clamps to 0m and does NOT flag;
#   - a seat with the heartbeat OFF carries no badge at all, and never appears
#     in the overdue legend — the legend must not cry wolf about seats that are
#     not enrolled;
#   - the row expression exists in exactly ONE place in src/, so the fix cannot
#     be live on `cmd_list` and stale on `_cmd_list_legacy`.
#
# Pure: no root, no systemd, no registry, no network. The clock is PINNED as an
# argument rather than read from `date`, so no arm races the wall clock.
#
# Run: bash tests/agent_list_hb_age_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"          # _agent_list_table, the subject

set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "output containing '$3'" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "output WITHOUT '$3'" "$2"; }

NOW=1788000000

# One fixture agent. Only the heartbeat block varies per arm; every other field
# is the shape `agent list` merges, so the renderer is exercised whole rather
# than through a hand-cut sub-object.
mkrow() { # <name> <hb-json>
  jq -nc --arg n "$1" --argjson hb "$2" '[{
    name: $n, type: "claude", channels: "none", workdir: "/w", authProfile: "p",
    heartbeat: $hb, active: "active", enabled: "enabled",
    operationalState: "ready",
    sudo: {grant: "none", runas: "-", impliedIsolation: "none", measured: true,
           extraEntries: false, diverges: false},
    health: {auth: {state: "ok"}, startup: {state: "clear"}}
  }]'
}
hb() { jq -nc --argjson e "$1" --argjson l "$2" '{enabled: true, everyMin: $e, fresh: false, lastRunAt: $l}'; }
# The badge as rendered, for <name>: first field of that agent's row.
badge() { awk -v n="$1" '$1 ~ "^"n"$" || $1 == n {print $2}' <<<"$2"; }

echo "== the defect: same cadence, different ages must not render the same =="
# Both seats wake every 5m. `fresh5` ticked 1m ago; `stale5` ticked 68m ago —
# main2's exact shape on the night this was filed. Under the old badge both
# printed `∿5m`.
TWO=$(jq -nc --argjson a "$(mkrow fresh5 "$(hb 5 $((NOW-60)))")" \
              --argjson b "$(mkrow stale5 "$(hb 5 $((NOW-68*60)))")" '$a + $b')
OUT=$(_agent_list_table "$TWO" "$NOW")
F=$(badge fresh5 "$OUT"); S=$(badge stale5 "$OUT")
is  'a seat that just ticked reports its AGE, not its cadence' "$F" '∿1m/5m'
is  'a seat 13.6 intervals overdue reports the age and is flagged' "$S" '∿68m/5m!'
if [[ "$F" != "$S" ]]; then ok 'two seats on one cadence with different ages render DIFFERENTLY'
else bad 'two seats on one cadence with different ages render DIFFERENTLY' 'different badges' "$F == $S"; fi
has 'the overdue seat is named in a legend line'   "$OUT" 'OVERDUE'
has 'the legend names the overdue seat by name'    "$OUT" 'stale5'
hasnt 'the legend does not name the fresh seat'    "$OUT" ': fresh5'

echo "== overdue is a RATIO of the seat's own cadence, not a constant =="
# 20m is 4x a 5m cadence and 0.67x a 30m one. A fixed threshold gets exactly one
# of these two right, whichever way it is tuned.
R=$(jq -nc --argjson a "$(mkrow quick "$(hb 5 $((NOW-20*60)))")" \
            --argjson b "$(mkrow slow "$(hb 30 $((NOW-20*60)))")" '$a + $b')
OUT=$(_agent_list_table "$R" "$NOW")
is '20m on a 5m cadence is overdue'      "$(badge quick "$OUT")" '∿20m/5m!'
is '20m on a 30m cadence is NOT overdue' "$(badge slow "$OUT")"  '∿20m/30m'

echo "== the 2x boundary is strict =="
AT=$(mkrow edge "$(hb 10 $((NOW-1200)))")          # exactly 2x
OVER=$(mkrow edge "$(hb 10 $((NOW-1201)))")        # one second past 2x
is 'exactly 2x its cadence is not yet overdue' "$(badge edge "$(_agent_list_table "$AT" "$NOW")")" '∿20m/10m'
is 'one second past 2x is overdue'             "$(badge edge "$(_agent_list_table "$OVER" "$NOW")")" '∿20m/10m!'

echo "== zero runs is the alarm state, not a clean one =="
for missing in '{"enabled":true,"everyMin":15,"lastRunAt":0}' '{"enabled":true,"everyMin":15}'; do
  OUT=$(_agent_list_table "$(mkrow newborn "$missing")" "$NOW")
  is  "an enrolled seat that never ticked reads never+flag ($missing)" "$(badge newborn "$OUT")" '∿never/15m!'
  has "a never-run seat reaches the overdue legend ($missing)" "$OUT" 'newborn'
done

echo "== a broken clock is not an overdue seat =="
OUT=$(_agent_list_table "$(mkrow skewed "$(hb 5 $((NOW+3600)))")" "$NOW")
is 'lastRunAt in the future clamps to 0m and does not flag' "$(badge skewed "$OUT")" '∿0m/5m'
hasnt 'a clock-skewed seat raises no overdue legend' "$OUT" 'OVERDUE'

echo "== ages coarsen, and stay honest while they do =="
is 'under 90m reads in minutes' "$(badge long "$(_agent_list_table "$(mkrow long "$(hb 60 $((NOW-89*60)))")" "$NOW")")" '∿89m/60m'
is 'at 90m it reads in hours'   "$(badge long "$(_agent_list_table "$(mkrow long "$(hb 60 $((NOW-90*60)))")" "$NOW")")" '∿1h/60m'
is 'past two days it reads in days and is flagged' "$(badge long "$(_agent_list_table "$(mkrow long "$(hb 60 $((NOW-3*86400)))")" "$NOW")")" '∿3d/60m!'

echo "== a seat that is not enrolled carries no badge and no alarm =="
OUT=$(_agent_list_table "$(mkrow asleep '{"enabled":false,"everyMin":15,"lastRunAt":0}')" "$NOW")
hasnt 'a heartbeat-off seat gets no badge' "$OUT" '∿'
hasnt 'a heartbeat-off seat raises no overdue legend' "$OUT" 'OVERDUE'
OUT=$(_agent_list_table "$(jq -nc '[{name:"bare",type:"claude",channels:"none",authProfile:"p",heartbeat:null,operationalState:"ready",enabled:"enabled",sudo:{measured:false},health:null}]')" "$NOW")
hasnt 'a seat with no heartbeat block at all gets no badge' "$OUT" '∿'
has   'and still renders its row'                           "$OUT" 'bare'

echo "== empty fleet still answers =="
is 'an empty registry renders the no-agents line' "$(_agent_list_table '[]' "$NOW")" 'no agents'

echo "== one implementation, not two =="
# The two renderers carried byte-identical copies of the row expression before
# this change. A second copy is how the badge gets fixed on the production path
# and left stale on the fixture one.
n_badge=$(grep -c 'hb_badge:' "$SRC"/*.sh | awk -F: '{s+=$2} END {print s+0}')
n_call=$(grep -c '_agent_list_table "\$merged"' "$SRC/cmd_agent.sh")
is 'the badge is defined exactly once across src/' "$n_badge" 1
is 'and both list renderers call it'               "$n_call"  2
n_old=$(grep -c 'heartbeat.everyMin // 30)|tostring' "$SRC/cmd_agent.sh")
is 'no renderer still prints the bare cadence as the badge' "$n_old" 0

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
