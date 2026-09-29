#!/usr/bin/env bash
# DIVE-5191 — heartbeat auto-rebalance of un-started todo rows between the
# seats of a declared pool (src/task/rebalance.sh + _hb_rebalance_sweep).
#
# Throwaway tasks.db (STATE_DIR -> tmp), never the live board. The meter is
# stood in for by overriding _rebal_headroom; the lead's send by cmd_send.
#
# Arms, named as the row's DONE names them:
#   A1 an overloaded member plus an idle member with headroom moves the right
#      rows (the ones the busy seat reaches LAST), appends one body line each,
#      and sends ONE line to the lead and nothing to either seat
#   A2 an idle member out of quota receives nothing — nor does one an operator
#      parked (desiredState=stopped) or one whose heartbeat is off, since the
#      wake loop never reaches either and the 24h hold would strand the rows
#   A3 a started, gated, blocked, branch-linked or seat-named row never moves
#      (plus parent/child, a named in-progress ident, a recurring template, a
#      parked row) — and a bare mention of the seat name does NOT pin a row
#   A4 the per-tick cap and the 24h no-return hold both work
#   A5 a seat outside any pool is untouched; no pool = the sweep is a no-op
#   A6 a dry run changes nothing
#   A7 pool config: one pool per seat, at least two seats
#   (mutation arms live in tests/task_rebalance_mutation_unit.sh, nightly tier)
# Run: bash tests/task_rebalance_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
MODULE="${REBAL_MODULE:-$SRC/task/rebalance.sh}"

TMP="$(mktemp -d /tmp/task-rebalance-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
# shellcheck disable=SC1090
source "$MODULE"   # after cmd_task.sh, so a mutant copy wins over the real one

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
_PACE_USAGE_CMD=:   # never read the host's real meter
REGISTRY="$STATE_DIR/agents.json"   # a throwaway registry; the real one is never read
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }

# ── stand-ins ────────────────────────────────────────────────────────────────
# Every pool seat is dispatchable (heartbeat on, not parked) unless an arm says
# otherwise. The real _hb_agent_is_parked and registry_read read this file.
REG_ALL='{"agents":{"dev":{"heartbeat":{"enabled":true}},"dev2":{"heartbeat":{"enabled":true}},
  "fe1":{"heartbeat":{"enabled":true}},"fe2":{"heartbeat":{"enabled":true}}}}'
printf '%s' "$REG_ALL" >"$REGISTRY"
HEADROOM_OK=" dev2 fe2 "          # seats whose account reads open
_rebal_headroom() {
  if [[ "$HEADROOM_OK" == *" $1 "* ]]; then printf 'account acct-%s open' "$1"; return 0; fi
  printf 'account acct-%s hard: 97%% of the week' "$1"; return 1
}
SENT="$TMP/sent.log"; : >"$SENT"
cmd_send() { local to="$1"; shift; printf '%s\t%s\n' "$to" "$*" >>"$SENT"; }
require_root() { :; }
_task_require_lane() { :; }

# mk <assignee> <priority> [status] [body] -> id; ident = DIVE-<id>
mk() {
  local id
  id=$(db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
           VALUES ('t', $(sqlq "${4:-}"), $(sqlq "$2"), $(sqlq "$1"), 'main', 'standard', $(sqlq "${3:-todo}"));
           SELECT last_insert_rowid();")
  db "UPDATE tasks SET ident='DIVE-'||id WHERE id=${id};"
  printf '%s' "$id"
}
who() { db "SELECT assignee FROM tasks WHERE id=$1;"; }
reset_board() { db "DELETE FROM task_deps; DELETE FROM tasks; DELETE FROM task_prefs WHERE key LIKE 'rebalance%';"; : >"$SENT"; }
pools() { _task_pref_set rebalance_pools "$1"; }
NOW=$(date +%s)

db "INSERT OR IGNORE INTO agents_org(name, reports_to) VALUES ('main', NULL), ('dev','main'), ('dev2','main');"

# ── A1: overloaded + idle-with-headroom moves the rows reached LAST ─────────
reset_board
pools '{"builders":["dev","dev2"]}'
H1=$(mk dev high);   H2=$(mk dev high);   M1=$(mk dev medium)
M2=$(mk dev medium); L1=$(mk dev low);    L2=$(mk dev low)
out=$(_hb_rebalance_sweep "$NOW" "" 2>"$TMP/hb.log")
check "A1 newest low row moves first"  "$(who "$L2")" "dev2"
check "A1 next-to-last row moves too"  "$(who "$L1")" "dev2"
check "A1 cap 2: medium stays"         "$(who "$M2")" "dev"
check "A1 high stays"                  "$(who "$H1")" "dev"
body=$(db "SELECT body FROM tasks WHERE id=${L2};")
[[ "$body" == *"REBALANCED"*"dev -> dev2 (pool builders)"*"Undo: 5dive task assign DIVE-${L2} dev"* ]] \
  && ok_t "A1 the moved row's body carries one from/to/why line" || bad_t "A1 body line" "$body"
check "A1 exactly one line per moved row" "$(grep -c 'REBALANCED' <<<"$body")" "1"
check "A1 one message, to the lead"    "$(wc -l <"$SENT" | tr -d ' ')" "1"
check "A1 the lead is dev's manager"   "$(cut -f1 "$SENT")" "main"
grep -q "DIVE-${L2} dev->dev2" "$SENT" && ok_t "A1 lead line names the moves" || bad_t "A1 lead line" "$(cat "$SENT")"
grep -qE '^(dev|dev2)	' "$SENT" && bad_t "A1 no message to either seat" "$(cat "$SENT")" || ok_t "A1 no message to either seat"
grep -q '\[rebalance\] moved:' "$TMP/hb.log" && ok_t "A1 tick log names the moves" || bad_t "A1 tick log" "$(cat "$TMP/hb.log")"
held=$(_task_pref_get "rebalance_moved:${L2}")
[[ "$held" == "$NOW" ]] && ok_t "A1 24h hold stamped" || bad_t "A1 hold stamp" "got [$held]"
# receiver now has open work -> no longer idle -> next tick moves nothing
_hb_rebalance_sweep "$((NOW+60))" "" 2>/dev/null
check "A1 receiver no longer idle: next tick moves nothing" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "2"

# ── A2: idle member out of quota receives nothing ────────────────────────────
reset_board
pools '{"builders":["dev","dev2"]}'
for _ in 1 2 3 4 5; do mk dev medium >/dev/null; done
HEADROOM_OK=" "
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A2 walled idle seat receives nothing" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "0"
check "A2 no lead message when nothing moved" "$(wc -l <"$SENT" | tr -d ' ')" "0"
plan=$(_rebal_plan "$NOW" "")
grep -q 'idle but no headroom: account acct-dev2 hard' <<<"$plan" && ok_t "A2 plan says why" || bad_t "A2 plan reason" "$plan"
HEADROOM_OK=" dev2 fe2 "
# An operator-parked idle seat: headroom is open, but the wake loop skips it.
reset_board; pools '{"builders":["dev","dev2"]}'
for _ in 1 2 3 4 5 6; do mk dev medium >/dev/null; done
jq '.agents.dev2.desiredState="stopped"' <<<"$REG_ALL" >"$REGISTRY"
_hb_agent_is_parked dev2 && ok_t "A2 fixture: the heartbeat's own predicate reads dev2 as parked" \
  || bad_t "A2 fixture: dev2 not parked" "$(cat "$REGISTRY")"
plan=$(_rebal_plan "$NOW" "")
grep -qP '^seat\tdev2\t.*\tidle but parked by operator' <<<"$plan" && ok_t "A2 parked: the seat line names the operator park" \
  || bad_t "A2 parked seat line" "$plan"
grep -q '^move' <<<"$plan" && bad_t "A2 parked: the plan moves nothing" "$plan" || ok_t "A2 parked: the plan moves nothing"
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A2 parked idle seat receives nothing" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "0"
check "A2 parked: no lead message" "$(wc -l <"$SENT" | tr -d ' ')" "0"
# Heartbeat off: never dispatched, same shape.
jq '.agents.dev2.heartbeat.enabled=false' <<<"$REG_ALL" >"$REGISTRY"
plan=$(_rebal_plan "$NOW" "")
grep -qP '^seat\tdev2\t.*\tidle but heartbeat off' <<<"$plan" && ok_t "A2 heartbeat off: the seat line says so" \
  || bad_t "A2 heartbeat-off seat line" "$plan"
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A2 heartbeat-off idle seat receives nothing" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "0"
# A seat the registry does not name at all fails closed the same way.
jq 'del(.agents.dev2)' <<<"$REG_ALL" >"$REGISTRY"
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A2 a seat missing from the registry receives nothing" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "0"
# Control for the three above: the same board with dev2 dispatchable moves rows.
printf '%s' "$REG_ALL" >"$REGISTRY"
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A2 control: the same board moves 2 once dev2 is dispatchable" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "2"
# the REAL headroom reader fails closed with no meter in this process
unset -f _rebal_headroom; source "$MODULE"
_hb_quota_parked() { return 1; }   # not parked; the band decides below
_pace_band() { return 2; }; _pace_band_name() { printf soft; }
_grader_account_of() { printf 'acct-x'; }
r=$(_rebal_headroom dev2 "$NOW" '{}'); rc=$?
check "A2 real reader: a soft band is not headroom" "$rc" "1"
_pace_band() { printf 'open'; return 0; }
r=$(_rebal_headroom dev2 "$NOW" '{}'); rc=$?
check "A2 real reader: an open band is headroom" "$rc" "0"
_grader_account_of() { printf ''; }
r=$(_rebal_headroom dev2 "$NOW" '{}'); rc=$?
check "A2 real reader: no account fails closed" "$rc" "1"
unset -f _pace_band _pace_band_name _grader_account_of
_rebal_headroom() {
  if [[ "$HEADROOM_OK" == *" $1 "* ]]; then printf 'account acct-%s open' "$1"; return 0; fi
  printf 'account acct-%s hard: 97%% of the week' "$1"; return 1
}

# ── A3: rows that must never move ────────────────────────────────────────────
reset_board
pools '{"builders":["dev","dev2"]}'
_task_pref_set rebalance_max_moves 20
WIP=$(mk dev high in_progress $'work in flight\nBranch: dive-9-wip')
S=$(mk dev low);  db "UPDATE tasks SET first_started_at=datetime('now') WHERE id=${S};"
G=$(mk dev low);  db "UPDATE tasks SET need_type='decision', ask='?' WHERE id=${G};"
BL=$(mk dev low); BLK=$(mk ops low); db "INSERT INTO task_deps(task_id, blocked_by) VALUES (${BL}, ${BLK});"
BR=$(mk dev low todo $'follow-up\nBranch: `dive-9-wip`.')
SN=$(mk dev low todo $'Seat: dev — needs the local build cache')
AT=$(mk dev low todo 'ask @dev, it holds the context')
CH=$(mk dev low); db "UPDATE tasks SET parent_id=${WIP} WHERE id=${CH};"
NM=$(mk dev low todo "after DIVE-${WIP} lands")
RC=$(mk dev low); db "UPDATE tasks SET kind='recurring' WHERE id=${RC};"
PK=$(mk dev low); db "UPDATE tasks SET parked_at=datetime('now') WHERE id=${PK};"
FREE=$(mk dev medium todo 'MAKER NOTES (dev): the dev box needs this; reassigned from dev once')
out=$(_hb_rebalance_sweep "$NOW" "" 2>&1)
for pair in "started:$S" "gated:$G" "blocked:$BL" "branch-linked:$BR" "seat-named:$SN" "at-named:$AT" \
            "child-of-wip:$CH" "names-wip-ident:$NM" "parked:$PK"; do
  check "A3 ${pair%%:*} row never moves" "$(who "${pair#*:}")" "dev"
done
# a recurring template is not a standard row, so it is not even a candidate
check "A3 recurring template never moves" "$(who "$RC")" "dev"
check "A3 a bare mention of 'dev' does not pin a row" "$(who "$FREE")" "dev2"
plan=$(_task_pref_set rebalance_max_moves 2; db "UPDATE tasks SET assignee='dev' WHERE id=${FREE};"; db "DELETE FROM task_prefs WHERE key='rebalance_moved:${FREE}';"; _rebal_plan "$NOW" "")
# Each reason is matched on ITS row's keep line — a bare "started" would also
# match the "un-started" in every seat line and grade nothing.
for want in "$S:started" "$G:gated (decision)" "$BL:blocked by an open dependency" "$BR:shares Branch: dive-9-wip" \
            "$SN:pinned to dev in its body" "$AT:pinned to dev in its body" "$CH:child of DIVE-${WIP}" \
            "$NM:names DIVE-${WIP}" "$PK:parked"; do
  line="keep	${want%%:*}	DIVE-${want%%:*}	dev	${want#*:}"
  grep -qxF "$line" <<<"$plan" && ok_t "A3 dry run explains DIVE-${want%%:*}: ${want#*:}" || bad_t "A3 reason missing: $line" "$plan"
done
db "UPDATE tasks SET parent_id=NULL WHERE id=${CH};"; db "UPDATE tasks SET parent_id=${CH} WHERE id=${WIP};"
plan=$(_rebal_plan "$NOW" "")
grep -qF "parent of DIVE-${WIP}" <<<"$plan" && ok_t "A3 parent of the in-progress row stays" || bad_t "A3 parent link" "$plan"
BW=$(mk dev low todo 'the live row waits on this one')
BLOCKED_WIP=$(mk dev high blocked 'waits'); db "INSERT INTO task_deps(task_id, blocked_by) VALUES (${BLOCKED_WIP}, ${BW});"
plan=$(_rebal_plan "$NOW" "")
grep -qF "DIVE-${BW}	dev	dependency edge with DIVE-${BLOCKED_WIP}" <<<"$plan" && ok_t "A3 a row the seat's blocked work waits on stays" || bad_t "A3 reverse dependency" "$plan"

# ── A4: per-tick cap and the 24h no-return hold ─────────────────────────────
reset_board
pools '{"builders":["dev","dev2"]}'
_task_pref_set rebalance_max_moves 1
for _ in 1 2 3 4 5 6; do mk dev medium >/dev/null; done
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A4 max-moves=1 moves one row" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "1"
_task_pref_set rebalance_max_moves 10
reset_board; pools '{"builders":["dev","dev2"]}'; _task_pref_set rebalance_max_moves 10
for _ in 1 2 3 4 5; do mk dev medium >/dev/null; done
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A4 never more than half a busy queue in one tick (5 -> 2)" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "2"
# ping-pong: a moved row handed back does not move again inside 24h
reset_board; pools '{"builders":["dev","dev2"]}'
for _ in 1 2 3 4; do mk dev medium >/dev/null; done
X=$(mk dev low)
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A4 X moved on the first tick" "$(who "$X")" "dev2"
db "UPDATE tasks SET assignee='dev' WHERE assignee='dev2';"
plan=$(_rebal_plan "$((NOW + 3600))" "")
grep -qF "DIVE-${X}	dev	moved 1h ago (24h hold)" <<<"$plan" && ok_t "A4 dry run names the hold" || bad_t "A4 hold reason" "$plan"
_hb_rebalance_sweep "$((NOW + 3600))" "" 2>/dev/null
check "A4 X held for 24h after a move (1h later)" "$(who "$X")" "dev"
db "UPDATE tasks SET assignee='dev' WHERE assignee='dev2';"   # dev2 idle again
_hb_rebalance_sweep "$((NOW + 86400 + 60))" "" 2>/dev/null
check "A4 X moves again once 24h passed" "$(who "$X")" "dev2"
# a row claimed between the plan and the write stays with its claimant
reset_board
Y=$(mk dev low)
db "UPDATE tasks SET status='in_progress', started_at=datetime('now') WHERE id=${Y};"
_rebal_move "$Y" dev dev2 builders "$NOW" "note"; rc=$?
check "A4 guarded write refuses a row that was claimed meanwhile" "$rc:$(who "$Y")" "1:dev"
Z=$(mk dev low)
db "UPDATE tasks SET assignee='ops' WHERE id=${Z};"   # a person re-routed it meanwhile
_rebal_move "$Z" dev dev2 builders "$NOW" "note"; rc=$?
check "A4 guarded write refuses a row re-routed meanwhile" "$rc:$(who "$Z")" "1:ops"

# ── A5: outside any pool = untouched; no pool = no-op ───────────────────────
reset_board
pools '{"builders":["dev","dev2"]}'
for _ in 1 2 3 4 5 6; do mk ops medium >/dev/null; done
before=$(db "SELECT group_concat(id||assignee) FROM tasks;")
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A5 a seat outside any pool keeps every row" "$(db "SELECT group_concat(id||assignee) FROM tasks;")" "$before"
reset_board
for _ in 1 2 3 4 5 6; do mk dev medium >/dev/null; done
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A5 no pool declared: nothing moves" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "0"
out=$(cmd_task_rebalance --dry-run 2>&1)
grep -q 'no pools declared' <<<"$out" && ok_t "A5 dry run says rebalancing is off" || bad_t "A5 off message" "$out"
# two pools do not trade with each other
pools '{"builders":["dev","dev2"],"frontend":["fe1","fe2"]}'
_hb_rebalance_sweep "$NOW" "" 2>/dev/null
check "A5 dev's rows go to its own pool only" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee IN ('fe1','fe2');")" "0"
check "A5 ...and do reach dev2" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "2"

# ── A6: a dry run changes nothing ────────────────────────────────────────────
reset_board
pools '{"builders":["dev","dev2"]}'
for _ in 1 2 3 4 5 6; do mk dev low >/dev/null; done
snap() { sqlite3 "$TASKS_DB" "SELECT * FROM tasks ORDER BY id; SELECT key,value FROM task_prefs ORDER BY key;" | md5sum; }
b=$(snap)
out=$(cmd_task_rebalance --dry-run 2>&1)
out2=$(cmd_task_rebalance 2>&1)
check "A6 dry run leaves the board byte-identical" "$(snap)" "$b"
check "A6 dry run sends nothing" "$(wc -l <"$SENT" | tr -d ' ')" "0"
n=$(grep -c '  MOVE ' <<<"$out"); grep -q '^DRY RUN' <<<"$out" && [[ $n == 2 ]] \
  && ok_t "A6 dry run prints the two moves the tick would make" || bad_t "A6 dry run output" "$out"
[[ "$out" == "$out2" ]] && ok_t "A6 bare verb is the dry run" || bad_t "A6 bare verb" "$out2"
JSON_MODE=1; js=$(cmd_task_rebalance --dry-run 2>&1); JSON_MODE=0
check "A6 --json dry run lists two moves" "$(jq '[.data.plan[] | select(.[0]=="move")] | length' <<<"$js" 2>/dev/null)" "2"
out=$(cmd_task_rebalance --apply 2>&1)
check "A6 --apply does move (the dry run was the only no-op)" "$(db "SELECT COUNT(*) FROM tasks WHERE assignee='dev2';")" "2"

# ── A7: pool config ─────────────────────────────────────────────────────────
reset_board
out=$(cmd_task_rebalance pool builders dev,dev2 2>&1); check "A7 pool declared" "$(_rebal_pools_json)" '{"builders":["dev","dev2"]}'
out=$( (cmd_task_rebalance pool other dev2,fe1) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"already in pool 'builders'"* ]] && ok_t "A7 a seat is in at most one pool" || bad_t "A7 one pool per seat" "rc=$rc $out"
out=$( (cmd_task_rebalance pool solo dev3) 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok_t "A7 a one-seat pool is refused" || bad_t "A7 one-seat pool" "$out"
out=$(cmd_task_rebalance pool builders --clear 2>&1); check "A7 pool cleared" "$(_rebal_pools_json)" '{}'
out=$(cmd_task_rebalance set min-todo=6 max-moves=3 2>&1)
check "A7 knobs stored" "$(_rebal_knob rebalance_min_todo 4):$(_rebal_knob rebalance_max_moves 2)" "6:3"

echo "---"
echo "PASS=${PASS} FAIL=${FAIL}"
(( FAIL == 0 ))
