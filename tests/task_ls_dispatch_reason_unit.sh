#!/usr/bin/env bash
# DIVE-4558 — `task ls --json` must carry `task doctor`'s per-row DISPATCH
# REASON, and must carry it for the unassigned rows doctor does not report.
#
# THE DEFECT. lodar read a board of 53 rows, saw "hold"/"(unassigned)" on 41 of
# them, and could not tell a row nobody will ever pick up from a row waiting its
# turn. `task doctor` knew the difference; this projection did not, so every
# consumer of it — the dashboard board, whose /tasks/snapshot route is a
# pass-through of this exact command — rendered the two identically.
#
# WHAT IS PINNED, and why each arm is here rather than a grep for the column:
#   A  every class classifies a real row (no-anchor/stale-edge/park-no-wake/
#      wake-passed/dead-lane/dead-verifier/unassigned-no-coordinator)
#   B  a DISPATCHABLE row carries an explicit null, not an absent key — the
#      DIVE-2777 trap: dbfmt -json drops null-valued keys, so "healthy" and
#      "this view does not report dispatch" are indistinguishable unless the
#      jq pass normalises. Asserted with `has()`, which is the only assertion
#      that can tell those two apart.
#   C  dispatch_fix is the text `_task_doctor_explain` prints — compared against
#      a live call to that function, so the two cannot drift into a surface
#      promising a verb the report does not.
#   D  PRECEDENCE matches the report: a row that is BOTH parked-no-wake and on a
#      dead lane reads park-no-wake on both surfaces (doctor keeps a row's first
#      classification; an `ls` ordering these differently would label one ident
#      two ways).
#   E  `task doctor`'s own finding set is UNCHANGED — the unassigned class is
#      carried by `ls` only. This arm is the one that fails if a future hand
#      widens the shared CASE without deciding to widen the report.
#   F  DEGRADE: with the registry unreadable the lane arms drop out and the
#      roster-free classes still classify. Never "everything is dead".
#   G  the scan is SET-BASED — `_task_doctor_lane_wakeable` is called once per
#      DISTINCT seat, not once per row. Counted by wrapping the predicate, so
#      the arm grades the call pattern the perf note claims, not a comment.
# Run: bash tests/task_ls_dispatch_reason_unit.sh   (no root, no network)
set -uo pipefail
# DIVE-2692 / DIVE-4440: ONE EXIT trap, registered before any early exit, with
# the temp-dir cleanup FOLDED IN. bash keeps only the last registration per
# signal, so a second `trap ... EXIT` further down would silently unarm this.
# TMP is not assigned yet at this point, hence the guarded expansion.
trap 'rc=$?; [[ -z "${TMP:-}" ]] || rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/task-ls-dispatch.XXXXXX)"

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
set +e   # header.sh enabled `set -e`; these arms expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# `alice` is enrolled, `zed` is registered and its heartbeat is off — the exact
# discriminator _task_doctor_lane_wakeable applies (heartbeat.enabled == true).
cat > "$STATE_DIR/agents.json" <<'J'
{"agents":{"alice":{"heartbeat":{"enabled":true}},"zed":{"heartbeat":{"enabled":false}}}}
J

tasks_db_init
# Seed the chart directly, never through `org set` (DIVE-2124: that verb is
# root-only, and a fixture needs the ROW, not the authz path).
db "INSERT OR IGNORE INTO agents_org (name) VALUES ('alice'),('zed');"

mk() { cmd_task_add --assignee="$1" -- "$2" 2>/dev/null | jq -r '.data.id'; }
reason() { printf '%s' "$1" | jq -r --arg i "$2" '.data.tasks[] | select(.ident==$i) | (.dispatch_reason // "null")'; }
fixtext() { printf '%s' "$1" | jq -r --arg i "$2" '.data.tasks[] | select(.ident==$i) | (.dispatch_fix // "null")'; }

t_ok=$(mk alice "dispatchable row")
t_lane=$(mk zed  "on a lane nothing wakes")
t_park=$(mk alice "parked with no wake")
db "UPDATE tasks SET parked_at=datetime('now'), wake_at=NULL WHERE id=$t_park;"
t_wake=$(mk alice "park whose wake has passed")
db "UPDATE tasks SET parked_at=datetime('now','-2 days'), wake_at=datetime('now','-1 day') WHERE id=$t_wake;"
t_anchor=$(mk alice "blocked with no anchor")
db "UPDATE tasks SET status='blocked' WHERE id=$t_anchor;"
t_stale=$(mk alice "blocked behind rows that all closed")
t_closed=$(mk alice "the closed blocker")
db "UPDATE tasks SET status='blocked' WHERE id=$t_stale;
    INSERT INTO task_deps (task_id, blocked_by) VALUES ($t_stale, $t_closed);
    UPDATE tasks SET status='done' WHERE id=$t_closed;"
t_grader=$(mk alice "grader nothing wakes")
db "UPDATE tasks SET verifier='zed' WHERE id=$t_grader;"
t_unassigned=$(mk alice "on no seat at all")
db "UPDATE tasks SET assignee=NULL WHERE id=$t_unassigned;"
# BOTH parked-no-wake AND on a dead lane — the precedence arm.
t_both=$(mk zed "parked AND on a dead lane")
db "UPDATE tasks SET parked_at=datetime('now'), wake_at=NULL WHERE id=$t_both;"

ident() { db "SELECT ident FROM tasks WHERE id=$1;"; }
I_OK=$(ident "$t_ok");       I_LANE=$(ident "$t_lane")
I_PARK=$(ident "$t_park");   I_WAKE=$(ident "$t_wake")
I_ANCHOR=$(ident "$t_anchor"); I_GRADER=$(ident "$t_grader")
I_STALE=$(ident "$t_stale")
I_UNASG=$(ident "$t_unassigned"); I_BOTH=$(ident "$t_both")

OUT=$(cmd_task_ls --no-body 2>/dev/null)

# --- A: every class classifies -------------------------------------------
for pair in "$I_LANE:dead-lane" "$I_PARK:park-no-wake" "$I_WAKE:wake-passed" \
            "$I_ANCHOR:no-anchor" "$I_STALE:stale-edge" "$I_GRADER:dead-verifier" \
            "$I_UNASG:unassigned-no-coordinator"; do
  i="${pair%%:*}"; want="${pair##*:}"; got=$(reason "$OUT" "$i")
  [[ "$got" == "$want" ]] && ok_t "A: $i classifies as $want" \
                          || bad_t "A: $i" "want=$want got=$got"
done

# --- B: a dispatchable row carries an explicit null, not an absent key ----
# `has()` is the whole point: `.dispatch_reason` is null either way.
present=$(printf '%s' "$OUT" | jq -r --arg i "$I_OK" \
  '.data.tasks[] | select(.ident==$i) | (has("dispatch_reason") and has("dispatch_fix"))')
[[ "$present" == "true" ]] && ok_t "B: healthy row carries both keys, explicitly null" \
                           || bad_t "B: healthy row" "has(dispatch_reason) and has(dispatch_fix) = $present"
nulled=$(reason "$OUT" "$I_OK")
[[ "$nulled" == "null" ]] && ok_t "B: healthy row's reason is null" \
                          || bad_t "B: healthy row reason" "got=$nulled"

# --- C: the fix text is _task_doctor_explain's, not a second copy ---------
want_fix=$(_task_doctor_explain dead-lane)
got_fix=$(fixtext "$OUT" "$I_LANE")
[[ "$got_fix" == "$want_fix" ]] && ok_t "C: dispatch_fix is _task_doctor_explain's text" \
                                || bad_t "C: dispatch_fix drift" "want=[$want_fix] got=[$got_fix]"
want_un=$(_task_doctor_explain unassigned-no-coordinator)
got_un=$(fixtext "$OUT" "$I_UNASG")
[[ -n "$want_un" && "$got_un" == "$want_un" ]] \
  && ok_t "C: unassigned class has its own remedy line" \
  || bad_t "C: unassigned remedy" "want=[$want_un] got=[$got_un]"

# --- D: precedence matches the report ------------------------------------
got_both=$(reason "$OUT" "$I_BOTH")
[[ "$got_both" == "park-no-wake" ]] \
  && ok_t "D: parked AND dead-lane reads park-no-wake (report's precedence)" \
  || bad_t "D: precedence" "want=park-no-wake got=$got_both"

# --- E: `task doctor`'s finding set is NOT widened ------------------------
DOC=$(JSON_MODE=0 cmd_task_doctor 2>&1)
if printf '%s' "$DOC" | grep -q "unassigned-no-coordinator"; then
  bad_t "E: doctor unchanged" "the report now carries the ls-only class; widening it is a decision, not a side effect"
else
  ok_t "E: doctor's report does not carry the ls-only unassigned class"
fi
printf '%s' "$DOC" | grep -q "$I_LANE" \
  && ok_t "E: doctor still reports its own dead-lane finding" \
  || bad_t "E: doctor dead-lane" "$I_LANE absent from the report"

# --- F: unreadable registry degrades to the roster-free classes -----------
mv "$STATE_DIR/agents.json" "$STATE_DIR/agents.json.away"
OUT_D=$(cmd_task_ls --no-body 2>/dev/null)
mv "$STATE_DIR/agents.json.away" "$STATE_DIR/agents.json"
d_park=$(reason "$OUT_D" "$I_PARK"); d_lane=$(reason "$OUT_D" "$I_LANE")
[[ "$d_park" == "park-no-wake" ]] \
  && ok_t "F: roster-free classes survive an unreadable registry" \
  || bad_t "F: degrade" "park row want=park-no-wake got=$d_park"
[[ "$d_lane" != "dead-lane" ]] \
  && ok_t "F: an UNCHECKABLE lane is not reported dead" \
  || bad_t "F: degrade direction" "the lane arm fired with no registry to decide it"

# --- G: the scan is per-SEAT, not per-ROW --------------------------------
# Wrap the predicate and count. Two distinct seats hold open rows (alice, zed)
# and each column is scanned once, so the ceiling is 2 columns x 2 seats = 4 —
# far under the 8 rows on this board. A per-row call would be >= 8.
_real_lane_wakeable=$(declare -f _task_doctor_lane_wakeable)
eval "_orig_lane_wakeable${_real_lane_wakeable#_task_doctor_lane_wakeable}"
LANE_CALLS=0
_task_doctor_lane_wakeable() { LANE_CALLS=$((LANE_CALLS+1)); _orig_lane_wakeable "$@"; }
n_rows=$(db "SELECT COUNT(*) FROM tasks WHERE kind='standard' AND status IN ('todo','in_progress','blocked');")
cmd_task_ls --no-body >/dev/null 2>&1
if (( LANE_CALLS > 0 && LANE_CALLS <= 4 && LANE_CALLS < n_rows )); then
  ok_t "G: lane scan is set-based ($LANE_CALLS predicate calls over $n_rows rows)"
else
  bad_t "G: lane scan shape" "calls=$LANE_CALLS rows=$n_rows (want 1..4 and < rows)"
fi
eval "$_real_lane_wakeable"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
