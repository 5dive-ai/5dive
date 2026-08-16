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
# pause/resume, and the DIVE-2512 tombstone: `rm` RETIRES (keeps the objective row
# plus its audited objective_cycles + objective_readings), `ls` hides retired rows
# but says how many it hid, an empty list can no longer be confused with a wipe,
# and only `rm --purge --yes` still destroys — naming BOTH child tables when it does.
# Run: bash tests/objective_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/objective-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_objective.sh; do
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

# ---- (12) DIVE-2512: rm TOMBSTONES — it must not take cycles/readings with it ----
# Plant an audited cycle row first. Without one, a test that only counts readings
# would have passed against the OLD hard-DELETE too (readings were named in the old
# success message; the SILENT loss was objective_cycles). The cycle row is the
# discriminator, so it is planted deliberately rather than assumed.
oid=$(db "SELECT id FROM objectives WHERE name='ratio';")
db "INSERT INTO objective_cycles (objective_id, cycle_no, reading_value, outcome)
    VALUES ($oid, 1, 96.5, 'applied');"
pre_cycles=$(db   "SELECT COUNT(*) FROM objective_cycles   WHERE objective_id=$oid;")
pre_reads=$(db    "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
[[ "$pre_cycles" -ge 1 && "$pre_reads" -ge 1 ]] \
  && ok_t "precondition: 'ratio' has $pre_cycles cycle(s) + $pre_reads reading(s) to lose" \
  || bad_t "tombstone precondition" "cycles=$pre_cycles readings=$pre_reads (test proves nothing)"

out=$(run cmd_objective_rm "ratio" --reason="metric has no autonomous lever left" --ref=DIVE-1928); rc=$?
st=$(db       "SELECT status FROM objectives WHERE id=$oid;")
kept_cyc=$(db "SELECT COUNT(*) FROM objective_cycles   WHERE objective_id=$oid;")
kept_rd=$(db  "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
[[ $rc -eq 0 && "$st" == "retired" && "$kept_cyc" == "$pre_cycles" && "$kept_rd" == "$pre_reads" ]] \
  && ok_t "rm retires (status=retired) and KEEPS all cycles + readings" \
  || bad_t "rm tombstone" "rc=$rc status=$st cycles=$kept_cyc/$pre_cycles readings=$kept_rd/$pre_reads"

# the row itself must answer who/when/why/whose-authority
IFS="|" read -r r_at r_by r_why r_ref < <(db "SELECT COALESCE(retired_at,''), COALESCE(retired_by,''), COALESCE(retired_reason,''), COALESCE(retired_ref,'') FROM objectives WHERE id=$oid;")
[[ -n "$r_at" && -n "$r_by" && "$r_why" == "metric has no autonomous lever left" && "$r_ref" == "DIVE-1928" ]] \
  && ok_t "tombstone records retired_at/by/reason/ref on the row" \
  || bad_t "tombstone provenance" "at=$r_at by=$r_by why=$r_why ref=$r_ref"

# the success message must NAME what survives (the old one said only "readings deleted")
# the claim and the store must AGREE — a message asserting "kept" while the rows
# are gone is the exact failure mode the old "(readings deleted)" line had.
printf '%s' "$out" | jq -e --argjson c "$kept_cyc" --argjson r "$kept_rd" \
  '.data.retired==true and .data.cycles_kept==$c and .data.readings_kept==$r and $c>=1 and $r>=1 and .data.retired_ref=="DIVE-1928"' >/dev/null \
  && ok_t "rm result names the kept cycles + readings and the authorizing ref" \
  || bad_t "rm result payload" "out=$out"

# ---- (12b) a retired objective does not tick ----
# Asserts the row is STILL THERE as well as un-ticked: "no new readings" is also
# true of an objective that was deleted, so without the survives= arm this passes
# against the very hard-DELETE the task is about.
before=$(db "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
run cmd_objective_tick >/dev/null
after=$(db "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
survives=$(db "SELECT COUNT(*) FROM objectives WHERE id=$oid;")
[[ "$before" == "$after" && "$survives" == "1" ]] && ok_t "tick (all) skips a retired objective (which is still there)" \
  || bad_t "retired still ticks" "before=$before after=$after survives=$survives"

# ---- (12c) ls hides retired by default, --all shows it, and the count is surfaced ----
out=$(run cmd_objective_ls); rc=$?
hid=$(printf '%s' "$out" | jq -r '[.data.objectives[].name] | index("ratio") // "absent"')
n_hidden=$(printf '%s' "$out" | jq -r '.data.retired_hidden')
[[ $rc -eq 0 && "$hid" == "absent" && "$n_hidden" -ge 1 ]] \
  && ok_t "ls hides retired by default and reports retired_hidden=$n_hidden" \
  || bad_t "ls default" "idx=$hid hidden=$n_hidden out=$out"
out=$(run cmd_objective_ls --all)
printf '%s' "$out" | jq -e '[.data.objectives[].name] | index("ratio") != null' >/dev/null \
  && ok_t "ls --all shows the retired objective" || bad_t "ls --all" "out=$out"

# ---- (12d) the empty render distinguishes retired from never-existed (DIVE-2507) ----
# THE bug this task exists for: a bare ls that shows nothing had two causes — an
# authorized retirement and a catastrophic wipe — and they rendered identically.
JSON_MODE=0
db "UPDATE objectives SET status='retired';"
txt=$(run cmd_objective_ls)
# Assert the EMPTY-LIST message specifically, and that the never-existed wording is
# absent. A loose grep for "retired" passes on a broken filter too — the box render
# has a `status` column, so the word appears in the very output this arm must reject.
if grep -q "no live objectives" <<<"$txt" && grep -q "1 retired\|3 retired\|[0-9] retired" <<<"$txt" \
   && ! grep -q "no objectives yet" <<<"$txt"; then
  ok_t "empty ls says 'no live objectives — N retired', never 'no objectives yet'"
else
  bad_t "empty-render honesty" "text=$txt"
fi
db "UPDATE objectives SET status='active' WHERE name<>'ratio';"
JSON_MODE=1

# ---- (12e) re-adding a retired name says WHICH conflict it is ----
out=$(run cmd_objective_add "ratio" --metric-cmd="echo 1" --target=1); rc=$?
[[ $rc -eq "$E_CONFLICT" ]] && ok_t "add over a tombstone => conflict (named as retired)" \
  || bad_t "add over tombstone" "rc=$rc out=$out"

# ---- (12f) rm again on a retired objective refuses instead of destroying ----
out=$(run cmd_objective_rm "ratio"); rc=$?
still=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$oid;")
[[ $rc -eq "$E_CONFLICT" && "$still" == "$pre_cycles" ]] \
  && ok_t "rm on an already-retired objective refuses (history intact)" \
  || bad_t "double rm" "rc=$rc cycles=$still"

# ---- (12g) resume un-retires and clears the tombstone ----
run cmd_objective_setstatus active "ratio" >/dev/null
IFS="|" read -r st2 rat2 < <(db "SELECT status, COALESCE(retired_at,'') FROM objectives WHERE id=$oid;")
[[ "$st2" == "active" && -z "$rat2" ]] && ok_t "resume un-retires and clears retired_at" \
  || bad_t "un-retire" "status=$st2 retired_at=$rat2"
run cmd_objective_rm "ratio" --reason="re-retire for the purge test" >/dev/null

# ---- (12h) --purge without --yes refuses; with --yes it deletes and SAYS the counts ----
out=$(run cmd_objective_rm "ratio" --purge); rc=$?
surv=$(db "SELECT COUNT(*) FROM objectives WHERE id=$oid;")
[[ $rc -eq "$E_CONFLICT" && "$surv" == "1" ]] && ok_t "--purge without --yes refuses (nothing destroyed)" \
  || bad_t "purge needs --yes" "rc=$rc surv=$surv"
out=$(run cmd_objective_rm "ratio" --purge --yes); rc=$?
gone=$(db "SELECT COUNT(*) FROM objectives WHERE name='ratio';")
orphans=$(db "SELECT COUNT(*) FROM objective_readings WHERE objective_id=$oid;")
orph_cyc=$(db "SELECT COUNT(*) FROM objective_cycles WHERE objective_id=$oid;")
[[ $rc -eq 0 && "$gone" == "0" && "$orphans" == "0" && "$orph_cyc" == "0" ]] \
  && ok_t "--purge --yes deletes the objective and cascades cycles + readings" \
  || bad_t "purge cascade" "rc=$rc gone=$gone readings=$orphans cycles=$orph_cyc"
printf '%s' "$out" | jq -e '.data.purged==true and .data.cycles_deleted>=1 and .data.readings_deleted>=1' >/dev/null \
  && ok_t "purge result names BOTH destroyed tables (the old message named only readings)" \
  || bad_t "purge payload" "out=$out"

# ---- (13) show/ls on a missing objective fails cleanly ----
out=$(run cmd_objective_show "ghost"); rc=$?
[[ $rc -eq "$E_NOT_FOUND" ]] && ok_t "show on missing objective => not_found" \
  || bad_t "show missing" "rc=$rc"

echo "-----"
echo "objective_unit: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
