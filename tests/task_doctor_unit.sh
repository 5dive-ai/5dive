#!/usr/bin/env bash
# TIER: nightly — ~9s measured (DIVE-3784): the core tier is already at its cap, and this
# harness builds a 13-row scratch board plus a registry fixture; it belongs in the sweep.
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
#   T5  dead-lane    assignee registered, heartbeat absent               -> found
#   T5b dead-lane    assignee registered + heartbeat ON but desiredState=stopped -> found
#                    (the OTHER half: the wake loop DOES iterate it and the wake
#                     then fails every tick, forever — same outcome for the row)
#   T6  NEGATIVES    a live gate, a live edge, a future park, a todo -> NOT found
#   T7  the remedy SLOT for a park holds `unpark` and NOT `unblock` (the filed
#       symptom: `unblock` on a parked row reports success and changes nothing)
#   T7c the census prints on the FINDINGS path, not only on a clean board
#   T8  a clean board reports zero and still prints the census
#   T9  an unreadable registry DEGRADES (the roster-free classes still report)
#       instead of refusing the way `orphans` does
#   T11..T18 DIVE-3826 `--fix`: the remedy the report NAMES is the one it RUNS,
#       for ONE named row, re-derived at fix time.
#   T11  --dry-run prints the command and mutates NOTHING
#   T12  --fix on each class runs that class's own verb (unblock/unpark/assign)
#   T13  --fix on a dead lane REFUSES without --to
#   T14  --fix --to=<another dead lane> is REFUSED — the tool must not create
#        the defect it reports
#   T15  --fix on a row that is NOT a current finding is refused, naming its
#        actual state (the report is a claim about a board that kept moving)
#   T16  --fix changes exactly ONE row; there is no --all
#   T17  --to / --dry-run without --fix are REFUSED, not parsed into nothing
#   T18  --fix with no row argument is refused
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
  "zombie":{"type":"claude"},
  "stopped":{"type":"claude","heartbeat":{"enabled":true},"desiredState":"stopped"}
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
t_stopped=$(addt --assignee=stopped -- "assigned to a seat the operator turned off")

# negatives
t_gate=$(addt --assignee=live -- "waiting on a human")
( cmd_task_need "$t_gate" --type=decision --ask="pick one" --options="A|B" --recommend="A" ) >/dev/null 2>&1
# `task need` REASSIGNS the row to the routed reviewer, and that name is derived
# from the running actor — so it varies by whoever runs this harness and would not
# be in the fixture registry. Put it back on `live`: the gate, not the routing, is
# what this negative arm measures. (Found by this harness on its first run, which
# flagged the gate row dead-lane.)
db "UPDATE tasks SET assignee='live' WHERE id=${t_gate};"
# An ANSWERED gate. The census must count OPEN gates only: on the live board most
# gates are already answered, so a census reading `need_type IS NOT NULL` would
# report the whole gate HISTORY as a live hold. Without this row planted, that
# loosening is invisible — the fixture would carry no answered gate to miscount.
# (quinn, iteration 1.) An answered gate leaves the row dispatchable again, with
# need_type still recorded, so this is also a negative: it is not a finding.
t_gatedone=$(addt --assignee=live -- "a gate that was already answered")
( cmd_task_need "$t_gatedone" --type=decision --ask="pick one" --options="A|B" --recommend="A" ) >/dev/null 2>&1
db "UPDATE tasks SET need_answered_at=datetime('now'), status='todo', assignee='live' WHERE id=${t_gatedone};"

t_livedep=$(addt --assignee=live -- "behind a blocker that is still open")
t_openblocker=$(addt --assignee=live -- "still open blocker")
( cmd_task_block "$t_livedep" --by="$t_openblocker" ) >/dev/null 2>&1
t_futurepark=$(addt --assignee=live -- "parked, wakes next week")
( cmd_task_park "$t_futurepark" --reason="waiting" --wake="+7d" ) >/dev/null 2>&1
t_todo=$(addt --assignee=live -- "plain dispatchable row")

out=$(doctor)

# ---- T1..T5: each class is found, with its OWN label -------------------------
for pair in "$t_noanchor:no-anchor" "$t_stale:stale-edge" "$t_wakepast:wake-passed" \
            "$t_nowake:park-no-wake" "$t_dead:dead-lane" "$t_stopped:dead-lane"; do
  id="${pair%%:*}"; want="${pair##*:}"; i=$(ident "$id"); got=$(reason_of "$out" "$i")
  [[ "$got" == "$want" ]] \
    && ok_t "${want}: ${i} classified ${want}" \
    || bad_t "${want}: ${i}" "wanted '${want}', got '${got:-<not a finding>}'"
done

# ---- T6: the negatives are NOT findings -------------------------------------
neg_bad=""
for pair in "$t_gate:live human gate" "$t_gatedone:an ANSWERED gate" \
            "$t_livedep:live blocker edge" \
            "$t_futurepark:park with a future wake" "$t_todo:plain todo" \
            "$t_openblocker:the open blocker itself"; do
  id="${pair%%:*}"; what="${pair##*:}"; i=$(ident "$id"); got=$(reason_of "$out" "$i")
  [[ -z "$got" ]] || neg_bad+="${i} (${what}) -> ${got}; "
done
[[ -z "$neg_bad" ]] \
  && ok_t "a live gate / an answered gate / live edge / future park / plain todo are NOT reported undispatchable" \
  || bad_t "false positives" "$neg_bad"

# ---- count is exactly the five --------------------------------------------
nf=$(printf '%s' "$out" | jq -r '.data.findings')
[[ "$nf" == "6" ]] && ok_t "findings count is exactly the 6 planted rows" \
                   || bad_t "findings count" "wanted 6, got '${nf}' (rows: $(printf '%s' "$out" | jq -rc '[.data.rows[]?|{ident,reason}]'))"

# ---- census counts the rest, and names what clears them ---------------------
disp=$(printf '%s' "$out" | jq -r '.data.census.dispatchable')
gated=$(printf '%s' "$out" | jq -r '.data.census.gated')
parked=$(printf '%s' "$out" | jq -r '.data.census.parked')
# gated MUST be exactly 1 and not 2: two gates are planted, one live and one
# answered, and only the live one is a hold. `>= 1` here would accept the
# `need_type IS NOT NULL` loosening.
{ [[ "$gated" == "1" ]] && [[ "$parked" == "1" ]] && [[ "$disp" -ge 1 ]]; } \
  && ok_t "census separates dispatchable (${disp}) from gated (${gated}, the ANSWERED gate excluded) and future-parked (${parked})" \
  || bad_t "census" "dispatchable=$disp gated=$gated parked=$parked (gated must be 1: the answered gate is not a hold)"

# ---- T7: the park remedy SLOT holds unpark, and NOT unblock -----------------
# This is the filed symptom, not a wording preference: `unblock` drops EDGES, a
# park has none, so it prints "OK — unblocked" over a row that did not move.
#
# ANCHOR THE SLOT, NOT THE PRESENCE (quinn, iteration 1). The first cut of this
# arm grepped the line for the word "unpark" and for the prose "unblock only
# drops edges" — and BOTH survive the exact inversion that ships the filed
# defect, because "-> 5dive task unblock <id>  (NOT unpark: unblock only drops
# edges, ...)" still contains "unpark" (inside "NOT unpark") and keeps the prose
# untouched. The two phrasings share ALL of the vocabulary; only the verb in the
# slot after "-> " differs. So assert what occupies the slot, and assert the
# wrong verb does not.
park_line=$(grep -A3 -F "$(ident "$t_wakepast")" "$TMP/err" | grep -F -- '-> 5dive task ')
{ [[ -n "$park_line" ]] \
    && grep -qF -- '-> 5dive task unpark <id>' <<<"$park_line" \
    && ! grep -qF -- '-> 5dive task unblock' <<<"$park_line" \
    && grep -qi "unblock only drops edges" <<<"$park_line"; } \
  && ok_t "the park remedy SLOT holds 'unpark' and not 'unblock', and says why unblock silently no-ops" \
  || bad_t "park remedy slot" "$(grep -A3 -F "$(ident "$t_wakepast")" "$TMP/err")"

# ---- T7c: the census prints on the FINDINGS path, not only on a clean board --
# (quinn, iteration 1): the clean-board arm read the census out of the JSON
# payload, so deleting ${census_line} from the findings-path warn survived every
# arm. The census is the answer to the question the row was filed on ("31 open,
# 1 dispatchable"); a run that lists findings and drops it reproduces the 42h.
# Assert the rendered TEXT, with the payload's own numbers, so the two cannot
# drift apart either.
cens_open=$(printf '%s' "$out" | jq -r '.data.census.open')
cens_disp=$(printf '%s' "$out" | jq -r '.data.census.dispatchable')
{ grep -qF -- "open ${cens_open}: ${cens_disp} dispatchable now," "$TMP/err" \
    && grep -qF -- "awaiting a human gate" "$TMP/err"; } \
  && ok_t "the findings run prints the census text too (open ${cens_open}, ${cens_disp} dispatchable now)" \
  || bad_t "census absent from the findings path" "$(cat "$TMP/err")"

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

# ---- T10: an unknown flag is REFUSED, not accepted and ignored ---------------
# The first cut carried a --quiet that was parsed and then had no effect. A flag
# the verb accepts and does not honour is worse than one it rejects.
( cmd_task_doctor --quiet ) >/dev/null 2>"$TMP/flag.err"; frc=$?
{ [[ $frc -ne 0 ]] && grep -qi "unknown flag" "$TMP/flag.err"; } \
  && ok_t "an unknown flag is refused rather than accepted and ignored" \
  || bad_t "flag handling" "rc=$frc :: $(cat "$TMP/flag.err")"

# ============================ DIVE-3826: --fix ==============================
# The fixtures above are consumed by the report arms and are still in their
# undispatchable states, so they are exactly the population --fix must act on.
# Each arm below asserts the DATABASE moved (or did not), never the prose: the
# filed defect was a remedy that printed success over a row that had not moved.

fix() { ( cmd_task_doctor --fix "$@" ) 2>"$TMP/fix.err"; }
statusof()  { db "SELECT status FROM tasks WHERE id=$1;"; }
parkedof()  { db "SELECT CASE WHEN parked_at IS NULL THEN 'clear' ELSE 'parked' END FROM tasks WHERE id=$1;"; }
asgof()     { db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=$1;"; }

# ---- T11: --dry-run names the command and changes NOTHING -------------------
i_wp=$(ident "$t_wakepast")
dry=$(fix "$i_wp" --dry-run | tail -n1); drc=$?
dcmd=$(printf '%s' "$dry" | jq -r '.data.fix.command' 2>/dev/null)
dapp=$(printf '%s' "$dry" | jq -r '.data.fix.applied' 2>/dev/null)
{ [[ $drc -eq 0 ]] && [[ "$dcmd" == "5dive task unpark ${i_wp}" ]] && [[ "$dapp" == "false" ]] \
    && [[ "$(parkedof "$t_wakepast")" == "parked" ]]; } \
  && ok_t "--dry-run names 'unpark' for a wake-passed row and the row is STILL parked" \
  || bad_t "--dry-run" "rc=$drc command='${dcmd}' applied='${dapp}' park=$(parkedof "$t_wakepast") :: $(cat "$TMP/fix.err")"

# ---- T12: each class runs ITS OWN verb, and the row actually moves ----------
# wake-passed -> unpark
out12a=$(fix "$i_wp" | tail -n1); rc12a=$?
{ [[ $rc12a -eq 0 ]] && [[ "$(parkedof "$t_wakepast")" == "clear" ]] \
    && [[ "$(statusof "$t_wakepast")" == "todo" ]] \
    && [[ "$(printf '%s' "$out12a" | jq -r '.data.fix.applied')" == "true" ]]; } \
  && ok_t "--fix wake-passed: ran unpark, the row is unparked and back to todo" \
  || bad_t "--fix wake-passed" "rc=$rc12a park=$(parkedof "$t_wakepast") status=$(statusof "$t_wakepast") :: $(cat "$TMP/fix.err")"

# park-no-wake -> unpark
i_nw=$(ident "$t_nowake")
fix "$i_nw" >/dev/null; rc12b=$?
{ [[ $rc12b -eq 0 ]] && [[ "$(parkedof "$t_nowake")" == "clear" ]]; } \
  && ok_t "--fix park-no-wake: ran unpark, the row is unparked" \
  || bad_t "--fix park-no-wake" "rc=$rc12b park=$(parkedof "$t_nowake") :: $(cat "$TMP/fix.err")"

# no-anchor -> unblock
i_na=$(ident "$t_noanchor")
fix "$i_na" >/dev/null; rc12c=$?
{ [[ $rc12c -eq 0 ]] && [[ "$(statusof "$t_noanchor")" == "todo" ]]; } \
  && ok_t "--fix no-anchor: ran unblock, the row is todo" \
  || bad_t "--fix no-anchor" "rc=$rc12c status=$(statusof "$t_noanchor") :: $(cat "$TMP/fix.err")"

# stale-edge -> unblock, and the dead EDGE is actually gone (not just the status
# flipped): a status-only repair leaves the edge to re-block on the next sweep.
i_se=$(ident "$t_stale")
fix "$i_se" >/dev/null; rc12d=$?
edges=$(db "SELECT COUNT(*) FROM task_deps WHERE task_id=${t_stale};")
{ [[ $rc12d -eq 0 ]] && [[ "$(statusof "$t_stale")" == "todo" ]] && [[ "$edges" == "0" ]]; } \
  && ok_t "--fix stale-edge: ran unblock, the row is todo AND the dead edge is dropped" \
  || bad_t "--fix stale-edge" "rc=$rc12d status=$(statusof "$t_stale") edges=$edges :: $(cat "$TMP/fix.err")"

# ---- T13: a dead lane REFUSES without a destination -------------------------
i_dl=$(ident "$t_dead")
fix "$i_dl" >/dev/null 2>"$TMP/fix.err"; rc13=$?
{ [[ $rc13 -ne 0 ]] && grep -qi -- "--to" "$TMP/fix.err" && [[ "$(asgof "$t_dead")" == "zombie" ]]; } \
  && ok_t "--fix dead-lane with no --to is refused and the row did not move" \
  || bad_t "dead-lane without --to" "rc=$rc13 assignee=$(asgof "$t_dead") :: $(cat "$TMP/fix.err")"

# ---- T14: --to a lane that is ALSO dead is refused --------------------------
# The verb that reports dead lanes must not be the fastest way to make one. Both
# halves of the wakeability test are exercised: 'zombie' (no heartbeat key) was
# the finding, 'stopped' (heartbeat on, operator-stopped) is the destination.
fix "$i_dl" --to=stopped >/dev/null 2>"$TMP/fix.err"; rc14=$?
{ [[ $rc14 -ne 0 ]] && [[ "$(asgof "$t_dead")" == "zombie" ]]; } \
  && ok_t "--fix --to=<an operator-stopped seat> is refused; the row stays where it was" \
  || bad_t "--to a dead lane accepted" "rc=$rc14 assignee=$(asgof "$t_dead") :: $(cat "$TMP/fix.err")"

# ...and a WAKEABLE destination is accepted and the row actually moves.
fix "$i_dl" --to=live >/dev/null 2>"$TMP/fix.err"; rc14b=$?
{ [[ $rc14b -eq 0 ]] && [[ "$(asgof "$t_dead")" == "live" ]]; } \
  && ok_t "--fix dead-lane --to=<a wakeable seat>: the row is re-assigned" \
  || bad_t "--fix dead-lane --to=live" "rc=$rc14b assignee=$(asgof "$t_dead") :: $(cat "$TMP/fix.err")"

# ---- T15: a row that is NOT a current finding is refused ---------------------
# This is the whole reason --fix re-derives instead of reading the report: the
# row just repaired above is no longer a finding, and running the remedy again
# (unpark on a healthy row) would silently drop live park state.
fix "$i_wp" >/dev/null 2>"$TMP/fix.err"; rc15=$?
{ [[ $rc15 -ne 0 ]] && grep -qi "not an undispatchable row" "$TMP/fix.err"; } \
  && ok_t "--fix on an already-repaired row is refused, naming its actual state" \
  || bad_t "stale finding accepted" "rc=$rc15 :: $(cat "$TMP/fix.err")"

# A healthy row that was NEVER a finding is refused too (the negative control:
# the arm above could pass merely because the row was touched).
i_ok=$(ident "$t_todo")
fix "$i_ok" >/dev/null 2>"$TMP/fix.err"; rc15b=$?
{ [[ $rc15b -ne 0 ]] && [[ "$(statusof "$t_todo")" == "todo" ]]; } \
  && ok_t "--fix on a plain healthy row is refused (never-a-finding control)" \
  || bad_t "healthy row accepted" "rc=$rc15b :: $(cat "$TMP/fix.err")"

# A row waiting on a LIVE human gate is refused: it is correctly in flight, and
# unblocking it would take the row off the human's inbox without an answer.
i_gate=$(ident "$t_gate")
fix "$i_gate" >/dev/null 2>"$TMP/fix.err"; rc15c=$?
{ [[ $rc15c -ne 0 ]] && [[ "$(statusof "$t_gate")" == "blocked" ]]; } \
  && ok_t "--fix on a row awaiting a live human gate is refused, and the gate still holds" \
  || bad_t "live gate cleared by --fix" "rc=$rc15c status=$(statusof "$t_gate") :: $(cat "$TMP/fix.err")"

# ---- T16: there is no --all, and one --fix touched exactly one row ----------
# t_futurepark is a legitimate hold that sat next to every row repaired above.
{ [[ "$(parkedof "$t_futurepark")" == "parked" ]] \
    && [[ "$(statusof "$t_livedep")" == "blocked" ]]; } \
  && ok_t "the untouched neighbours are untouched — a future park is still parked, a live edge still blocks" \
  || bad_t "collateral damage" "futurepark=$(parkedof "$t_futurepark") livedep=$(statusof "$t_livedep")"
( cmd_task_doctor --fix-all ) >/dev/null 2>"$TMP/fix.err"; rc16=$?
{ [[ $rc16 -ne 0 ]] && grep -qi "unknown flag" "$TMP/fix.err"; } \
  && ok_t "--fix-all does not exist and is refused as an unknown flag" \
  || bad_t "--fix-all" "rc=$rc16 :: $(cat "$TMP/fix.err")"

# ---- T17: --to and --dry-run WITHOUT --fix are refused, not ignored ---------
# Same bar T10 sets: a flag the verb accepts and does not honour is worse than
# one it rejects.
( cmd_task_doctor --to=live ) >/dev/null 2>"$TMP/fix.err"; rc17=$?
[[ $rc17 -ne 0 ]] && r17a=1 || r17a=0
( cmd_task_doctor --dry-run ) >/dev/null 2>"$TMP/fix.err2"; rc17b=$?
{ [[ "$r17a" == "1" ]] && [[ $rc17b -ne 0 ]]; } \
  && ok_t "--to and --dry-run are refused without --fix rather than parsed and ignored" \
  || bad_t "orphan flags accepted" "--to rc=$rc17 :: --dry-run rc=$rc17b :: $(cat "$TMP/fix.err") $(cat "$TMP/fix.err2")"

# ---- T18: --fix with no row is refused --------------------------------------
( cmd_task_doctor --fix ) >/dev/null 2>"$TMP/fix.err"; rc18=$?
{ [[ $rc18 -ne 0 ]] && grep -qi "needs the row" "$TMP/fix.err"; } \
  && ok_t "--fix with no row argument is refused" \
  || bad_t "--fix bare" "rc=$rc18 :: $(cat "$TMP/fix.err")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
