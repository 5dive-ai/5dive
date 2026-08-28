#!/usr/bin/env bash
# TIER: nightly — ~7s measured (DIVE-3784): the core tier is already at its cap, and this
# harness builds a 9-row scratch board plus a registry fixture; it belongs in the sweep.
# DIVE-3784 isolated unit harness for `5dive task doctor` — the verb that
# enumerates every open row nothing will dispatch, and says WHY.
#
# WHAT IT ASSERTS, and why each arm is a SEPARATE one: the four classes are four
# different SQL predicates over three different columns, and the filing symptom
# was that a row in ONE of them (a park) was mistaken for another (an edge
# block). A harness that only counted findings would pass while the classifier
# swapped two labels, which is the exact defect.
#   T1  no-anchor    blocked, no edge / no park / no gate            -> found
#   T2  stale-edge   blocked, every blocker closed                   -> found
#   T3  wake-passed  parked, wake_at in the past                     -> found
#   T4  park-no-wake parked, wake_at NULL                            -> found
#   T5  dead-lane    assignee registered but heartbeat.enabled false -> found
#   T6  NEGATIVES    a live gate, a live edge, a future park, a todo -> NOT found
#   T7  the remedy line for a park says unpark and warns off unblock (the filed
#       symptom: `unblock` on a parked row reports success and changes nothing)
#   T8  a clean board reports zero and still prints the census
#   T9  an unreadable registry DEGRADES (the roster-free classes still report)
#       instead of refusing the way `orphans` does
# Run: bash tests/task_doctor_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-doctor.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

# The registry fixture. `live` is wakeable; `zombie` is registered and will never
# be woken (no heartbeat key at all — the measured shape: 4 of 17 agents on the
# host carry none). Names are fixtures, not real seats.
mk_registry() {
  cat > "$TMP/agents.json" <<'JSON'
{"agents":{
  "live":  {"type":"claude","heartbeat":{"enabled":true}},
  "zombie":{"type":"claude"}
}}
JSON
}
mk_registry
# The roster is memoised per process (_TASK_ROSTER_STATE); clear it whenever the
# fixture registry changes or the second read silently grades the first file.
reroster() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; }
reroster

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
ident() { db "SELECT ident FROM tasks WHERE id=$1;"; }

# Run the verb and keep BOTH streams: the findings render on stderr (warn) and the
# machine payload on stdout (ok), exactly like `orphans`.
doctor() { ( cmd_task_doctor "$@" ) 2>"$TMP/err" | tail -n1; }
# reason for a given ident in the payload, or "" when it is not a finding.
reason_of() { printf '%s' "$1" | jq -r --arg i "$2" '.data.rows[]? | select(.ident==$i) | .reason' 2>/dev/null; }

# ---- fixtures ---------------------------------------------------------------
t_noanchor=$(addt --assignee=live -- "no anchor at all")
db "UPDATE tasks SET status='blocked' WHERE id=${t_noanchor};"   # direct write: `task block` refuses this shape (DIVE-1357)

t_blocker=$(addt --assignee=live -- "a blocker that finished")
t_stale=$(addt --assignee=live -- "held by a closed blocker")
( cmd_task_block "$t_stale" --by="$t_blocker" ) >/dev/null 2>&1
db "UPDATE tasks SET status='done', done_at=datetime('now') WHERE id=${t_blocker};"

t_wakepast=$(addt --assignee=live -- "parked, wake already passed")
( cmd_task_park "$t_wakepast" --reason="waiting" --wake="+7d" ) >/dev/null 2>&1
db "UPDATE tasks SET wake_at=datetime('now','-2 days') WHERE id=${t_wakepast};"

t_nowake=$(addt --assignee=live -- "parked with no wake at all")
( cmd_task_park "$t_nowake" --reason="waiting" --wake="+7d" ) >/dev/null 2>&1
db "UPDATE tasks SET wake_at=NULL WHERE id=${t_nowake};"

t_dead=$(addt --assignee=zombie -- "assigned to a seat nothing wakes")

# negatives
t_gate=$(addt --assignee=live -- "waiting on a human")
( cmd_task_need "$t_gate" --type=decision --ask="pick one" --options="A|B" --recommend="A" ) >/dev/null 2>&1
# `task need` REASSIGNS the row to the routed reviewer, and that name is derived
# from the running actor — so it varies by whoever runs this harness and would not
# be in the fixture registry. Put it back on `live`: the gate, not the routing, is
# what this negative arm measures. (Found by this harness on its first run, which
# flagged the gate row dead-lane.)
db "UPDATE tasks SET assignee='live' WHERE id=${t_gate};"
t_livedep=$(addt --assignee=live -- "behind a blocker that is still open")
t_openblocker=$(addt --assignee=live -- "still open blocker")
( cmd_task_block "$t_livedep" --by="$t_openblocker" ) >/dev/null 2>&1
t_futurepark=$(addt --assignee=live -- "parked, wakes next week")
( cmd_task_park "$t_futurepark" --reason="waiting" --wake="+7d" ) >/dev/null 2>&1
t_todo=$(addt --assignee=live -- "plain dispatchable row")

out=$(doctor)

# ---- T1..T5: each class is found, with its OWN label -------------------------
for pair in "$t_noanchor:no-anchor" "$t_stale:stale-edge" "$t_wakepast:wake-passed" \
            "$t_nowake:park-no-wake" "$t_dead:dead-lane"; do
  id="${pair%%:*}"; want="${pair##*:}"; i=$(ident "$id"); got=$(reason_of "$out" "$i")
  [[ "$got" == "$want" ]] \
    && ok_t "${want}: ${i} classified ${want}" \
    || bad_t "${want}: ${i}" "wanted '${want}', got '${got:-<not a finding>}'"
done

# ---- T6: the negatives are NOT findings -------------------------------------
neg_bad=""
for pair in "$t_gate:live human gate" "$t_livedep:live blocker edge" \
            "$t_futurepark:park with a future wake" "$t_todo:plain todo" \
            "$t_openblocker:the open blocker itself"; do
  id="${pair%%:*}"; what="${pair##*:}"; i=$(ident "$id"); got=$(reason_of "$out" "$i")
  [[ -z "$got" ]] || neg_bad+="${i} (${what}) -> ${got}; "
done
[[ -z "$neg_bad" ]] \
  && ok_t "a live gate / live edge / future park / plain todo are NOT reported undispatchable" \
  || bad_t "false positives" "$neg_bad"

# ---- count is exactly the five --------------------------------------------
nf=$(printf '%s' "$out" | jq -r '.data.findings')
[[ "$nf" == "5" ]] && ok_t "findings count is exactly the 5 planted rows" \
                   || bad_t "findings count" "wanted 5, got '${nf}' (rows: $(printf '%s' "$out" | jq -rc '[.data.rows[]?|{ident,reason}]'))"

# ---- census counts the rest, and names what clears them ---------------------
disp=$(printf '%s' "$out" | jq -r '.data.census.dispatchable')
gated=$(printf '%s' "$out" | jq -r '.data.census.gated')
parked=$(printf '%s' "$out" | jq -r '.data.census.parked')
{ [[ "$gated" == "1" ]] && [[ "$parked" == "1" ]] && [[ "$disp" -ge 1 ]]; } \
  && ok_t "census separates dispatchable (${disp}) from gated (${gated}) and future-parked (${parked})" \
  || bad_t "census" "dispatchable=$disp gated=$gated parked=$parked"

# ---- T7: the park remedy names unpark AND warns off unblock -----------------
# This is the filed symptom, not a wording preference: `unblock` drops EDGES, a
# park has none, so it prints "OK — unblocked" over a row that did not move.
park_line=$(grep -A3 -F "$(ident "$t_wakepast")" "$TMP/err" | grep -i "unpark")
{ [[ -n "$park_line" ]] && grep -qi "unblock only drops edges\|NOT unblock" <<<"$park_line"; } \
  && ok_t "a parked finding tells the operator to unpark and says why unblock silently no-ops" \
  || bad_t "park remedy text" "$(grep -A3 -F "$(ident "$t_wakepast")" "$TMP/err")"

# ---- T7b: it REPORTS, it does not FIX ---------------------------------------
still=$(db "SELECT status FROM tasks WHERE id=${t_noanchor};")
stillp=$(db "SELECT CASE WHEN parked_at IS NULL THEN 'clear' ELSE 'parked' END FROM tasks WHERE id=${t_wakepast};")
{ [[ "$still" == "blocked" ]] && [[ "$stillp" == "parked" ]]; } \
  && ok_t "doctor changed nothing — the no-anchor row is still blocked and the park is still parked" \
  || bad_t "doctor mutated the board" "no-anchor=$still park=$stillp"

# ---- T8: a clean board reports zero and still prints the census -------------
CLEAN="$TMP/clean"; mkdir -p "$CLEAN/tasks"
( STATE_DIR="$CLEAN"; TASKS_DIR="$CLEAN/tasks"; TASKS_DB="$CLEAN/tasks/tasks.db"
  tasks_db_init
  cmd_task_add --assignee=live -- "one healthy row" >/dev/null 2>&1
  cmd_task_doctor ) >"$TMP/clean.out" 2>"$TMP/clean.err"
cn=$(tail -n1 "$TMP/clean.out" | jq -r '.data.findings' 2>/dev/null)
co=$(tail -n1 "$TMP/clean.out" | jq -r '.data.census.open' 2>/dev/null)
{ [[ "$cn" == "0" ]] && [[ "$co" == "1" ]]; } \
  && ok_t "a clean board reports 0 findings and still prints the census (open=${co})" \
  || bad_t "clean board" "findings=$cn open=$co :: $(cat "$TMP/clean.err")"

# ---- T9: an unreadable registry DEGRADES, it does not refuse ----------------
# `orphans` refuses outright with no roster, correctly — every name would look
# orphaned. Three of doctor's four classes need no roster, so a registry problem
# must not take them down with it.
mv "$TMP/agents.json" "$TMP/agents.json.away"
reroster
out2=$(doctor); rc2=$?
n2=$(printf '%s' "$out2" | jq -r '.data.findings' 2>/dev/null)
{ [[ "$rc2" == "0" ]] && [[ "$n2" == "4" ]]; } \
  && ok_t "no readable registry: still reports the 4 roster-free findings (dropped only the lane class)" \
  || bad_t "degrade on unreadable registry" "rc=$rc2 findings=${n2:-<none>}"
grep -qi "lane check SKIPPED" "$TMP/err" \
  && ok_t "and SAYS the lane check was skipped rather than reporting every lane healthy" \
  || bad_t "skip is named" "$(cat "$TMP/err")"
mv "$TMP/agents.json.away" "$TMP/agents.json"; reroster

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
