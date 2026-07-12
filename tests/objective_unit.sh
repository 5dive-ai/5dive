#!/usr/bin/env bash
# OSS-19 (OSS-26 phase A1) isolated unit harness for `5dive objective`.
#
# Sources the src/ libs directly and points STATE_DIR at a throwaway temp dir so
# it NEVER touches the live shared tasks.db (same posture as goal_add_unit.sh —
# the binary hard-sets STATE_DIR, so a subprocess test would leak; sourcing +
# overriding the globals is the only truly isolated path). Exercises the
# measurement-only pipeline: add + validation rejects, tick appends a reading
# (and records a FAILED metric as value=NULL rc!=0, not a silent skip), the
# read-only contract (non-numeric stdout => failure), dup/name rejects,
# pause/resume/rm, and rm cascading its readings.
# Run: bash tests/objective_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/objective-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_objective.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { ( "$@" ) 2>/dev/null; }

# ---- (1) add: happy path ----
out=$(run cmd_objective_add "ratio" --metric-cmd="echo 96.5" --target=97 --direction=up --unit=% --public); rc=$?
[[ $rc -eq 0 ]] && printf '%s' "$out" | jq -e '.data.public==true and .data.direction=="up"' >/dev/null \
  && ok_t "add creates an objective (public flag stored)" \
  || bad_t "add happy path" "rc=$rc out=$out"

# ---- (2) add: missing --metric-cmd rejected ----
out=$(run cmd_objective_add "no-metric" --target=1); rc=$?
[[ $rc -eq "$E_VALIDATION" ]] && ok_t "missing --metric-cmd rejected" \
  || bad_t "missing metric-cmd" "rc=$rc out=$out"

# ---- (3) add: bad --direction rejected ----
out=$(run cmd_objective_add "bad-dir" --metric-cmd="echo 1" --direction=sideways); rc=$?
[[ $rc -eq "$E_VALIDATION" ]] && ok_t "bad --direction rejected" \
  || bad_t "bad direction" "rc=$rc out=$out"

# ---- (4) add: non-numeric --target rejected ----
out=$(run cmd_objective_add "bad-target" --metric-cmd="echo 1" --target=lots); rc=$?
[[ $rc -eq "$E_VALIDATION" ]] && ok_t "non-numeric --target rejected" \
  || bad_t "bad target" "rc=$rc out=$out"

# ---- (5) add: unknown --project rejected ----
out=$(run cmd_objective_add "orphan" --metric-cmd="echo 1" --project=nope); rc=$?
[[ $rc -eq "$E_NOT_FOUND" ]] && ok_t "unknown --project rejected" \
  || bad_t "unknown project" "rc=$rc out=$out"

# ---- (6) add: duplicate name rejected (E_CONFLICT) ----
out=$(run cmd_objective_add "ratio" --metric-cmd="echo 2" --target=1); rc=$?
[[ $rc -eq "$E_CONFLICT" ]] && ok_t "duplicate name rejected (conflict)" \
  || bad_t "dup name" "rc=$rc out=$out"

# ---- (7) tick: appends a reading with the metric value ----
run cmd_objective_tick "ratio" >/dev/null
v=$(db "SELECT value FROM objective_readings r JOIN objectives o ON o.id=r.objective_id WHERE o.name='ratio' ORDER BY r.id DESC LIMIT 1;")
[[ "$v" == "96.5" ]] && ok_t "tick appends the metric reading (96.5)" \
  || bad_t "tick reading" "value=$v"

# ---- (8) read-only contract: non-numeric stdout recorded as a FAILURE (NULL/rc!=0) ----
run cmd_objective_add "wordy" --metric-cmd="echo hello" --target=1 >/dev/null
run cmd_objective_tick "wordy" >/dev/null
IFS="|" read -r val rcv < <(db "SELECT COALESCE(value,'NULL'), rc FROM objective_readings r JOIN objectives o ON o.id=r.objective_id WHERE o.name='wordy' ORDER BY r.id DESC LIMIT 1;")
[[ "$val" == "NULL" && "$rcv" != "0" ]] && ok_t "non-numeric metric stdout recorded as gap (value NULL, rc!=0)" \
  || bad_t "non-numeric contract" "val=$val rc=$rcv"

# ---- (9) tick: failing command (rc!=0) recorded as a gap ----
run cmd_objective_add "boom" --metric-cmd="exit 4" --target=1 >/dev/null
run cmd_objective_tick "boom" >/dev/null
IFS="|" read -r val rcv < <(db "SELECT COALESCE(value,'NULL'), rc FROM objective_readings r JOIN objectives o ON o.id=r.objective_id WHERE o.name='boom' ORDER BY r.id DESC LIMIT 1;")
[[ "$val" == "NULL" && "$rcv" == "4" ]] && ok_t "failing metric-cmd recorded as gap (rc preserved)" \
  || bad_t "failing metric" "val=$val rc=$rcv"

# ---- (10) tick (no arg): ticks ALL active objectives, skips paused ----
run cmd_objective_setstatus paused "boom" >/dev/null
before=$(db "SELECT COUNT(*) FROM objective_readings;")
out=$(run cmd_objective_tick); rc=$?
after=$(db "SELECT COUNT(*) FROM objective_readings;")
# 3 active (ratio, wordy) after pausing boom -> expect 2 new readings, boom untouched
n=$(printf '%s' "$out" | jq -r '.data.ticked')
boom_reads_delta=0
[[ "$n" == "2" && $((after-before)) -eq 2 ]] && ok_t "tick (all) skips paused, ticks active only" \
  || bad_t "tick all skips paused" "ticked=$n delta=$((after-before)) out=$out"

# ---- (11) resume restores active ----
run cmd_objective_setstatus active "boom" >/dev/null
st=$(db "SELECT status FROM objectives WHERE name='boom';")
[[ "$st" == "active" ]] && ok_t "resume restores active status" || bad_t "resume" "status=$st"

# ---- (12) rm cascades its readings ----
oid=$(db "SELECT id FROM objectives WHERE name='ratio';")
run cmd_objective_rm "ratio" >/dev/null
gone=$(db "SELECT COUNT(*) FROM objectives WHERE name='ratio';")
orphans=$(db "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
[[ "$gone" == "0" && "$orphans" == "0" ]] && ok_t "rm deletes objective and cascades its readings" \
  || bad_t "rm cascade" "gone=$gone orphans=$orphans"

# ---- (13) show/ls on a missing objective fails cleanly ----
out=$(run cmd_objective_show "ghost"); rc=$?
[[ $rc -eq "$E_NOT_FOUND" ]] && ok_t "show on missing objective => not_found" \
  || bad_t "show missing" "rc=$rc"

echo "-----"
echo "objective_unit: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
