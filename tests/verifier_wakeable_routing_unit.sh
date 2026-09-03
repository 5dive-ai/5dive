#!/usr/bin/env bash
# TIER: core — ~4s measured 2026-09-03 (DIVE-3939). One scratch board, one
# registry fixture, no root, no network.
#
# DIVE-3939. The wakeability predicate was enforced on ONE of the two columns of
# the dispatch rail — `assignee` — and absent on `verifier`, which is the same
# rail one step later in time (`task done` writes assignee=<verifier>). So a row
# handed to a seat nothing wakes looked perfectly healthy for its whole life and
# died AT HANDOFF, after the maker had already spent the work. Six measured
# strands across four dates. See
# community/wiki/a-control-enforced-on-one-path-is-absent-on-the-parallel-one.md
#
# WHAT IT ASSERTS. Two halves, because they are two defects with one cause and
# either one alone leaves the strand reachable:
#   PICKER (src/task/routing.sh:_task_default_verifier)
#     P1  a candidate that resolves to an UNWAKEABLE seat is SKIPPED, and the
#         next wakeable candidate in the chain wins
#     P2  a chain that is unwakeable end to end returns EMPTY — it does NOT
#         silently pick a dead seat, and it does NOT fall back to the assignee
#         (that recreates the DIVE-3366 maker==grader skew)
#     P3  `task add` on P2's org labels the row verifyUnavailable (the existing
#         INST-2 path) rather than stamping a grader nothing wakes
#     P4  an UNREADABLE registry DEGRADES to the status quo — the candidate is
#         still picked. "I could not find out" must not read as "dead", or one
#         missing file silently strips grading off the whole board.
#   DOCTOR (src/task/doctor.sh)
#     D1  a row whose VERIFIER is unwakeable is a finding, class dead-verifier,
#         even though its assignee is live
#     D2  a row whose verifier is live is NOT a finding (negative)
#     D3  the remedy SLOT names `task verifier`, not `task assign`, and the
#         explanation says it strands AT HANDOFF rather than now
#     D4  --fix --to=<live> re-points the VERIFIER column and leaves assignee alone
#     D5  --fix --to=<another dead seat> is REFUSED — the verb that reports the
#         defect must not be the fastest way to create it
#     D6  --fix on a dead-verifier row REFUSES without --to
#
# EVERY ARM ASSERTS ON WAKEABILITY, NEVER ON A SEAT NAME. Fixture names only:
# hardcoding a real seat is red only on that seat
# ([[a-fixture-that-hardcodes-a-real-seat-name-is-red-only-on-that-seat]]).
# Run: bash tests/verifier_wakeable_routing_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/verifier-wakeable.XXXXXX)"

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

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
ident() { db "SELECT ident FROM tasks WHERE id=$1;"; }
reroster() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; }

# ---- the registry fixture ---------------------------------------------------
# `deadqa` and `deadlead` are REGISTERED and never woken (no heartbeat key —
# the measured shape). `livelead` and `livehand` are wakeable. `frozen` is
# heartbeat-on but operator-stopped: the wake loop iterates it and the wake
# fails every tick, forever, which is the same outcome for the row.
mk_registry() {
  cat > "$STATE_DIR/agents.json" <<'JSON'
{"agents":{
  "maker":    {"type":"claude","heartbeat":{"enabled":true}},
  "livelead": {"type":"claude","heartbeat":{"enabled":true}},
  "livehand": {"type":"claude","heartbeat":{"enabled":true}},
  "deadqa":   {"type":"claude"},
  "deadlead": {"type":"claude"},
  "frozen":   {"type":"claude","heartbeat":{"enabled":true},"desiredState":"stopped"}
}}
JSON
  reroster
}
mk_registry

# The predicate itself, on the fixture — a CONTROL. Without it every arm below
# could be green because the fixture is wrong rather than because the code is
# right: if `deadqa` read wakeable, "skipped" and "never a candidate" render
# identically.
_task_doctor_lane_wakeable livelead; rc_live=$?
_task_doctor_lane_wakeable deadqa;   rc_dead=$?
_task_doctor_lane_wakeable frozen;   rc_frozen=$?
{ [[ "$rc_live" == "0" && "$rc_dead" == "1" && "$rc_frozen" == "1" ]]; } \
  && ok_t "CONTROL: the fixture registry really does make livelead wakeable and deadqa/frozen not (0/1/1)" \
  || bad_t "CONTROL: fixture wakeability" "livelead=$rc_live (want 0) deadqa=$rc_dead (want 1) frozen=$rc_frozen (want 1)"

org_seed() {  # <name> [--role=x] [--title=y] [--reports-to=z]
  local n="$1"; shift
  db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$n"));"
  for a in "$@"; do case "$a" in
    --role=*)       db "UPDATE agents_org SET role=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
    --title=*)      db "UPDATE agents_org SET title=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
    --reports-to=*) db "UPDATE agents_org SET reports_to=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
  esac; done
  return 0
}

# ---- P1: the dead QA candidate is skipped, the live one downchain wins -------
# `deadqa`'s TITLE carries " verif", so it wins _task_resolve_qa — the first link
# in the chain and exactly how the live strand happened. `livelead` is the
# maker's manager, further down. If the picker ignores wakeability, deadqa wins.
# Seed the referenced rows FIRST: agents_org.reports_to is a real foreign key,
# so a manager named before it exists is an unenforced write, not a fixture.
org_seed livelead --role=coordinator
org_seed deadqa   --title="Deadqa · Verifier (codex)"
org_seed maker    --role=builder --reports-to=livelead
got=$(_task_default_verifier maker "")
if [[ "$got" == "livelead" ]]; then
  ok_t "P1: picker SKIPS the unwakeable QA candidate and takes the next wakeable one in the chain"
else
  _task_doctor_lane_wakeable "${got:-}" && grc=0 || grc=$?
  bad_t "P1: picker ignores wakeability" "picked '${got:-<empty>}', whose wakeability rc is ${grc} (want a seat with rc 0)"
fi

# ---- P2: an end-to-end unwakeable chain returns EMPTY ------------------------
# Rebuild the chart so EVERY candidate resolves to a seat nothing wakes:
# QA=deadqa, manager=deadlead, coordinator=frozen (stopped, the other half),
# and no org root or deputy that is alive.
db "DELETE FROM agents_org;"
org_seed deadlead
org_seed frozen   --role=coordinator
org_seed deadqa   --title="Deadqa · Verifier (codex)"
org_seed maker2   --role=builder --reports-to=deadlead
got2=$(_task_default_verifier maker2 "")
if [[ -z "$got2" ]]; then
  ok_t "P2: an unwakeable chain returns EMPTY — no dead grader, and no fallback to the maker"
elif [[ "$got2" == "maker2" ]]; then
  bad_t "P2: fell back to the ASSIGNEE" "picked the maker itself ('maker2') — that is the DIVE-3366 maker==grader skew"
else
  _task_doctor_lane_wakeable "$got2" && grc=0 || grc=$?
  bad_t "P2: picked a dead grader" "picked '${got2}', wakeability rc=${grc} (want empty)"
fi

# ---- P3: `task add` on that org labels the row verifyUnavailable -------------
add_out=$( ( cmd_task_add --assignee=maker2 --priority=high -- "a high row filed into an unwakeable org" ) 2>/dev/null | tail -n1 )
vu=$(printf '%s' "$add_out" | jq -r '.data.verifyUnavailable')
vraw=$(printf '%s' "$add_out" | jq -r '.data.verifier // ""')
{ [[ "$vu" == "true" && -z "$vraw" ]]; } \
  && ok_t "P3: task add labels the row verifyUnavailable instead of stamping a grader nothing wakes" \
  || bad_t "P3: task add stamped an unwakeable grader" "verifyUnavailable=${vu} verifier='${vraw}'"

# ---- P4: an UNREADABLE registry degrades to the status quo -------------------
# Failure direction matters more than the arm: "I could not find out" must not
# read as "dead". If it did, one unreadable agents.json would strip the grading
# rail off every row the board files while it is missing.
db "DELETE FROM agents_org;"
org_seed livelead --role=coordinator
org_seed deadqa   --title="Deadqa · Verifier (codex)"
org_seed maker    --role=builder --reports-to=livelead
mv "$STATE_DIR/agents.json" "$TMP/agents.json.hidden"; reroster
got4=$(_task_default_verifier maker "")
[[ -n "$got4" ]] \
  && ok_t "P4: with the registry unreadable the picker still returns a grader ('${got4}') — UNKNOWN degrades to the status quo, it does not read as dead" \
  || bad_t "P4: unreadable registry stripped the rail" "returned empty; one missing agents.json would un-grade the whole board"
mv "$TMP/agents.json.hidden" "$STATE_DIR/agents.json"; reroster

# ---- the doctor half --------------------------------------------------------
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
doctor() { ( cmd_task_doctor "$@" ) 2>"$TMP/err" | tail -n1; }
reason_of() { printf '%s' "$1" | jq -r --arg i "$2" '.data.rows[]? | select(.ident==$i) | .reason' 2>/dev/null; }

# assignee LIVE, verifier DEAD. This is the whole finding: nothing about this row
# is wrong today and it cannot be graded tomorrow.
t_dv=$(addt --assignee=maker --no-verify -- "live lane, grader nothing wakes")
db "UPDATE tasks SET verifier='deadqa' WHERE id=${t_dv};"
t_frozenv=$(addt --assignee=maker --no-verify -- "live lane, grader the operator stopped")
db "UPDATE tasks SET verifier='frozen' WHERE id=${t_frozenv};"
# negative: a live grader
t_okv=$(addt --assignee=maker --no-verify -- "live lane, live grader")
db "UPDATE tasks SET verifier='livelead' WHERE id=${t_okv};"

out=$(doctor)
i_dv=$(ident "$t_dv"); i_fv=$(ident "$t_frozenv"); i_okv=$(ident "$t_okv")

# ---- D1 ---------------------------------------------------------------------
r_dv=$(reason_of "$out" "$i_dv"); r_fv=$(reason_of "$out" "$i_fv")
{ [[ "$r_dv" == "dead-verifier" && "$r_fv" == "dead-verifier" ]]; } \
  && ok_t "D1: a row with a live assignee and an unwakeable VERIFIER is reported dead-verifier (both halves: no-heartbeat and operator-stopped)" \
  || bad_t "D1: the verifier column is never scanned" "no-heartbeat grader -> '${r_dv:-<not a finding>}', stopped grader -> '${r_fv:-<not a finding>}' (want dead-verifier for both)"

# ---- D2 negative ------------------------------------------------------------
r_okv=$(reason_of "$out" "$i_okv")
[[ -z "$r_okv" ]] \
  && ok_t "D2: a row whose grader IS wakeable is not a finding" \
  || bad_t "D2: false positive on a live grader" "${i_okv} -> ${r_okv}"

# ---- D3: the remedy slot, and the WHEN ---------------------------------------
# Anchor the SLOT after '-> ', not the presence of the word: `task assign` and
# `task verifier` share all the surrounding vocabulary, and the wrong verb here
# re-points the MAKER's lane and leaves the grader dead.
dv_block=$(grep -A4 -F "$i_dv" "$TMP/err")
dv_line=$(printf '%s' "$dv_block" | grep -F -- '-> 5dive task ')
{ [[ -n "$dv_line" ]] \
    && grep -qF -- '-> 5dive task verifier' <<<"$dv_line" \
    && ! grep -qF -- '-> 5dive task assign' <<<"$dv_line" \
    && grep -qi 'handoff' <<<"$dv_block"; } \
  && ok_t "D3: the dead-verifier remedy SLOT holds 'task verifier' (not 'task assign') and the finding says it strands at HANDOFF" \
  || bad_t "D3: remedy slot / timing" "$dv_block"

# ---- D6: --fix refuses without --to -----------------------------------------
( cmd_task_doctor --fix "$i_dv" ) >"$TMP/o6" 2>"$TMP/e6"; rc6=$?
# Assert it refuses AND names the flag it needs — an unexplained refusal is the
# same dead end for the operator as a coin-flip repair.
{ [[ "$rc6" != "0" ]] && grep -qiE 'grader|verifier' "$TMP/e6" && grep -qF -- '--to=' "$TMP/e6"; } \
  && ok_t "D6: --fix on a dead-verifier row refuses without --to (the destination cannot be invented)" \
  || bad_t "D6: --fix without --to" "rc=$rc6 $(cat "$TMP/e6")"

# ---- D5: --to a second dead seat is REFUSED ---------------------------------
( cmd_task_doctor --fix "$i_dv" --to=deadlead ) >"$TMP/o5" 2>"$TMP/e5"; rc5=$?
now5=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${t_dv};")
{ [[ "$rc5" != "0" && "$now5" == "deadqa" ]] && grep -qi 'wake' "$TMP/e5"; } \
  && ok_t "D5: --fix --to=<another seat nothing wakes> is refused and the row is unchanged" \
  || bad_t "D5: the repair verb created the defect" "rc=$rc5 verifier now '${now5}' (want unchanged 'deadqa'): $(cat "$TMP/e5")"

# ---- D4: --fix --to=<live> re-points the VERIFIER, not the assignee ---------
( cmd_task_doctor --fix "$i_dv" --to=livehand ) >"$TMP/o4" 2>"$TMP/e4"; rc4=$?
v4=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE id=${t_dv};")
a4=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${t_dv};")
{ [[ "$rc4" == "0" && "$v4" == "livehand" && "$a4" == "maker" ]]; } \
  && ok_t "D4: --fix --to=<live seat> re-points the verifier rail and leaves the assignee alone" \
  || bad_t "D4: --fix did not re-point the verifier" "rc=$rc4 verifier='${v4}' (want livehand) assignee='${a4}' (want maker): $(cat "$TMP/e4")"

# and the repaired row is no longer a finding
out2=$(doctor)
[[ -z "$(reason_of "$out2" "$i_dv")" ]] \
  && ok_t "D4b: after the fix the row is no longer reported" \
  || bad_t "D4b: still a finding after the fix" "$(reason_of "$out2" "$i_dv")"

printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] || exit 1
