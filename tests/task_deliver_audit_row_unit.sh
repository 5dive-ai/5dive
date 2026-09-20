#!/usr/bin/env bash
# `task deliver` and the GRADE VERDICT leave an audit row, like every other task
# state change.
#
# THE DEFECT this pins. Every other verb that changes a row's state calls
# `_task_store_audit_log`: `task start|done|cancel|set-body|merge|answer gate` all
# do. `task deliver` did not, and neither did the verdict. Measured on one box
# over the 24h to 2026-09-19: eight deliveries, and in the same window the fleet
# log carried 8 `task start` rows and 14 `task done` rows — so "when was this row
# bound, and to what" was answerable for every verb except the one that binds.
# The only trace of a delivery was the row's own mutable columns, which the next
# delivery overwrites.
#
# WHAT THIS GRADES. Not "a function is called" — that a ROW LANDS in the log, with
# the fields a reader needs, through the real `audit_log` rail. The rig is built
# out of the product's own documented seams rather than stubs, because the two
# things most likely to make this test lie are both guards on that rail:
#
#   * `_audit_sourced_caller_fence` (src/lib/audit.sh) withholds every row from a
#     caller that SOURCED the libraries instead of entering through the CLI — as
#     every harness does. Its own message names the sanctioned exit: point
#     AUDIT_LOG under a throwaway dir, which makes `_audit_sink_is_live` false.
#   * `_task_store_audit_log` (DIVE-2010) withholds when TASKS_DB is not the
#     production store — which is every harness. Arm P1 proves that fence is
#     still intact and that overriding it is what makes A/B able to see anything.
#
# Both are graded in BOTH directions (P0 writes, P1 does not), because a harness
# whose rail is silently fenced reports "no row" for the fixed tree exactly as it
# does for the broken one, and every arm below would pass vacuously on a green
# checkmark that measured nothing.
#
# NO ROOT, NO NETWORK, NO INSTALL, and arm L proves it rather than asserting it:
# AUDIT_LOG is a file in the tempdir (never /var/log/5dive), the reach probe is
# turned off through its own env seam, and nothing reads /usr/local/bin.
#
#   bash tests/task_deliver_audit_row_unit.sh
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
TMP="$(mktemp -d /tmp/task-deliver-audit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/disk.sh lib/tasks_db.sh lib/broker.sh lib/actor.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e
# AFTER sourcing header.sh, which sets AUDIT_LOG=/var/log/5dive/... unconditionally.
# The file must EXIST: _emit_audit_line gates on `-w "$AUDIT_LOG"` and routes a
# non-writable path through sudo, which is exactly the leg a pristine runner has
# no grant for.
AUDIT_LOG="$TMP/audit.log"; : >"$AUDIT_LOG"
# The reach probe is a GitHub read. Off through the product's own knob, not a
# `gh` stub: what this file grades is the audit row, and a stubbed probe would be
# one more thing that can silently stop matching the product.
export FIVE_DELIVER_NO_REACH_PROBE=1

# Counters are ok_t/bad_t, NEVER ok/no. `cmd_task_deliver` and `cmd_task_verify`
# both call the PRODUCT's `ok()` on success (src/lib/output.sh), so a harness that
# shadows `ok` as its pass counter scores the product's success message as its own
# passing arm — silently inflating the count by one per delivery.
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# `grep -c` prints the count AND exits 1 when that count is zero, so a
# `|| printf 0` fallback appends a SECOND zero and every "== 0" comparison fails
# against the literal "0\n0". Take the output, ignore the status.
rows()  { local n; n=$(grep -c "\"cmd\":\"$1\"" "$AUDIT_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
row()   { grep "\"cmd\":\"$1\"" "$AUDIT_LOG" 2>/dev/null | tail -1; }
clear_log() { : >"$AUDIT_LOG"; }

# An evidence-complete result: the DIVE-4576 rail REFUSES a delivery whose result
# names a PR without these five fields, and a refused delivery is non-mutating —
# so without them every A arm would be grading the refusal, not the delivery.
EVID='did the thing.
CHANGED: src/x.sh - one clause
CHECKED: bash tests/x_unit.sh 3 pass / 0 fail
DELIVERED-SHA: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
CI: green
CRITERIA: the one criterion -> the line above'
PR=https://github.com/5dive-ai/5dive/pull/1

seed() { # -> echoes the row id
  tasks_db_init >/dev/null 2>&1
  db "INSERT INTO tasks (title,status,assignee,verifier,kind,priority,created_by,review_mode)
      VALUES ('t','in_progress','dev','','standard','medium','main','check');" >/dev/null 2>&1
  db "SELECT id FROM tasks ORDER BY id DESC LIMIT 1;"
}
dref() { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE id=$1;"; }

# --- P) THE RAIL ITSELF, in both directions ----------------------------------
# Without P0 a green run proves nothing: "no task deliver row" is what a fenced
# rail reports for the FIXED tree too.
clear_log
audit_log "probe-control" ok 0 -- "x=1"
[[ "$(rows probe-control)" == "1" ]] \
  && ok_t "P0: POSITIVE CONTROL — audit_log really writes to this rig (the sourced-caller fence is not swallowing rows)" \
  || bad_t "P0: the rig can write an audit row at all" "got $(rows probe-control) rows in $AUDIT_LOG; every arm below would be vacuous"

# The DIVE-2010 fence, UNTOUCHED: a non-production TASKS_DB must still withhold.
clear_log
_task_store_audit_log "probe-fenced" ok 0 -- "x=1" 2>/dev/null
[[ "$(rows probe-fenced)" == "0" ]] \
  && ok_t "P1: the DIVE-2010 store fence still withholds on a throwaway TASKS_DB (this change does not loosen it)" \
  || bad_t "P1: the non-production store fence holds" "it wrote $(rows probe-fenced) rows — the fence is broken, not just bypassed"

# Now override the fence for the arms that need to SEE the row. Kept as a named
# override rather than a blanket stub of _task_store_audit_log, so the arms still
# run the real helper, the real audit_log and the real sanitizer.
_task_human_send_allowed_real() { return 1; }
_task_human_send_allowed() { return 0; }
clear_log
_task_store_audit_log "probe-unfenced" ok 0 -- "x=1"
[[ "$(rows probe-unfenced)" == "1" ]] \
  && ok_t "P2: ... and with the store fence overridden the SAME helper does write (P1 measured the fence, not a dead rail)" \
  || bad_t "P2: the helper writes once unfenced" "got $(rows probe-unfenced)"

# --- A) `task deliver` leaves exactly one row, carrying the binding ----------
clear_log
id=$(seed)
out=$( cmd_task_deliver "$id" --pr="$PR" --result="$EVID" 2>&1 ); rc=$?
[[ "$rc" == "0" && "$(dref "$id")" == "$PR" ]] \
  && ok_t "A0: the delivery itself succeeded and bound the ref (the arms below grade a real state change)" \
  || bad_t "A0: the delivery succeeded" "rc=$rc ref=$(dref "$id") out=${out:0:300}"
[[ "$(rows 'task deliver')" == "1" ]] \
  && ok_t "A1: exactly ONE 'task deliver' audit row — this is the defect, gone" \
  || bad_t "A1: task deliver writes one audit row" "got $(rows 'task deliver') rows"
grep -q "ref=$PR" <<<"$(row 'task deliver')" \
  && ok_t "A2: the row names the pull request it bound" \
  || bad_t "A2: the row carries ref=<pr>" "$(row 'task deliver')"
{ grep -q 'iteration=' <<<"$(row 'task deliver')" && grep -q 'review=check' <<<"$(row 'task deliver')"; } \
  && ok_t "A3: ... and the binding iteration and the row's review mode, so the record is readable without the row" \
  || bad_t "A3: the row carries iteration= and review=" "$(row 'task deliver')"
grep -q '"result":"ok"' <<<"$(row 'task deliver')" \
  && ok_t "A4: the row is recorded as a SUCCESS, matching what the verb did" \
  || bad_t "A4: the row records result=ok" "$(row 'task deliver')"

# A5: a RE-POINT is its own event. DIVE-2682 makes re-binding the legitimate act;
# a trail that recorded only the first binding would lose exactly the history the
# merge gate's iteration stamp exists to explain.
PR2=https://github.com/5dive-ai/5dive/pull/2
out=$( cmd_task_deliver "$id" --pr="$PR2" --result="$EVID" --force-redeliver="re-point" 2>&1 )
[[ "$(rows 'task deliver')" == "2" && "$(dref "$id")" == "$PR2" ]] \
  && ok_t "A5: a re-pointed binding writes a SECOND row (the trail keeps both, it does not overwrite)" \
  || bad_t "A5: a re-point is its own audit row" "rows=$(rows 'task deliver') ref=$(dref "$id") out=${out:0:300}"

# --- B) The GRADE VERDICT leaves a row ---------------------------------------
clear_log
out=$( cmd_task_verify "$id" --cmd=true --no-done 2>&1 ); rc=$?
[[ "$(rows 'task.graded')" == "1" ]] \
  && ok_t "B1: a stored verdict writes exactly ONE 'task.graded' audit row" \
  || bad_t "B1: the verdict writes an audit row" "got $(rows 'task.graded') rows, verify rc=$rc out=${out:0:300}"
grep -q 'verdict=pass' <<<"$(row 'task.graded')" \
  && ok_t "B2: the row names the verdict" \
  || bad_t "B2: the row carries verdict=" "$(row 'task.graded')"
grep -q 'sha=' <<<"$(row 'task.graded')" \
  && ok_t "B3: ... and the graded sha field the lifecycle event carries" \
  || bad_t "B3: the row carries sha=" "$(row 'task.graded')"
# B4: a FAIL is just as much an end of grading as a PASS — the same reasoning the
# ledger event's own comment gives for emitting on both.
clear_log
out=$( cmd_task_verify "$id" --cmd=false --no-done 2>&1 )
{ [[ "$(rows 'task.graded')" == "1" ]] && grep -q 'verdict=fail' <<<"$(row 'task.graded')"; } \
  && ok_t "B4: a FAIL verdict is audited too, and says so" \
  || bad_t "B4: both verdicts are audited" "rows=$(rows 'task.graded') row=$(row 'task.graded')"

# --- C) A REFUSED delivery must NOT look like a delivery ---------------------
# The evidence rail refuses before the binding UPDATE, so nothing was written to
# the row; an audit row here would record a state change that did not happen.
clear_log
id2=$(seed)
out=$( cmd_task_deliver "$id2" --pr="$PR" --result="no evidence here at all" 2>&1 ); rc=$?
[[ "$rc" != "0" && -z "$(dref "$id2")" ]] \
  && ok_t "C0: a result with no evidence is REFUSED and binds nothing (C1 grades a real refusal)" \
  || bad_t "C0: the evidence rail refuses" "rc=$rc ref=$(dref "$id2") out=${out:0:300}"
[[ "$(rows 'task deliver')" == "0" ]] \
  && ok_t "C1: ... and writes NO 'task deliver' row — the trail does not claim a delivery that was refused" \
  || bad_t "C1: a refused delivery writes no deliver row" "got $(rows 'task deliver'): $(row 'task deliver')"

# --- M) MUTANT: put the defect back and the arms go red ----------------------
# BEFORE/AFTER on purpose: "the call is gone" is also true of a sed that matched
# nothing, which would make the mutant arms vacuous.
ORIG_D="$(declare -f cmd_task_deliver)"
MUT_D="$(printf '%s\n' "$ORIG_D" | sed '/_task_store_audit_log "task deliver"/d')"
grep -q '_task_store_audit_log "task deliver"' <<<"$ORIG_D" \
  && ok_t "M0a: BEFORE — the shipped cmd_task_deliver really does audit" \
  || bad_t "M0a: the shipped verb audits" "no call found; every mutant arm below is vacuous"
! grep -q '_task_store_audit_log "task deliver"' <<<"$MUT_D" \
  && ok_t "M0b: AFTER — the mutation removed it (the sed matched)" \
  || bad_t "M0b: the mutation removed the call" "the sed did not match; the mutant is not mutated"
eval "$MUT_D"
clear_log; id3=$(seed)
out=$( cmd_task_deliver "$id3" --pr="$PR" --result="$EVID" 2>&1 )
{ [[ "$(rows 'task deliver')" == "0" ]] && [[ "$(dref "$id3")" == "$PR" ]]; } \
  && ok_t "M1: MUTANT — the delivery still HAPPENS and leaves no row (A1 would be red; this is the pre-fix state exactly)" \
  || bad_t "M1: mutant delivers silently" "rows=$(rows 'task deliver') ref=$(dref "$id3")"
eval "$ORIG_D"
clear_log; id4=$(seed)
out=$( cmd_task_deliver "$id4" --pr="$PR" --result="$EVID" 2>&1 )
[[ "$(rows 'task deliver')" == "1" ]] \
  && ok_t "M2: RESTORE took — the fixed verb is back (later arms grade the fix, not the mutant)" \
  || bad_t "M2: restore took" "rows=$(rows 'task deliver')"

ORIG_V="$(declare -f cmd_task_verify)"
# ONE line, not `,+1d`: `declare -f` re-prints a backslash-continued call as a
# single line, so deleting a second line takes the NEXT statement with it and the
# mutant fails to parse — which would "fail" for the wrong reason and say nothing
# about whether the audit call is what writes the row.
MUT_V="$(printf '%s\n' "$ORIG_V" | sed '/_task_store_audit_log "task.graded"/d')"
grep -q '_task_store_audit_log "task.graded"' <<<"$ORIG_V" \
  && ok_t "M3a: BEFORE — the shipped cmd_task_verify really does audit the verdict" \
  || bad_t "M3a: the shipped verb audits the verdict" "no call found; M4 is vacuous"
! grep -q '_task_store_audit_log "task.graded"' <<<"$MUT_V" \
  && ok_t "M3b: AFTER — the mutation removed it (the sed matched)" \
  || bad_t "M3b: the mutation removed the call" "the sed did not match"
eval "$MUT_V"
clear_log
out=$( cmd_task_verify "$id4" --cmd=true --no-done 2>&1 )
[[ "$(rows 'task.graded')" == "0" ]] \
  && ok_t "M4: MUTANT — a verdict is stored with no audit row (B1 would be red)" \
  || bad_t "M4: mutant grades silently" "rows=$(rows 'task.graded')"
eval "$ORIG_V"
clear_log
out=$( cmd_task_verify "$id4" --cmd=true --no-done 2>&1 )
[[ "$(rows 'task.graded')" == "1" ]] \
  && ok_t "M5: RESTORE took for the verdict too" \
  || bad_t "M5: verdict restore took" "rows=$(rows 'task.graded')"

# --- L) CI IS PRISTINE: no root, no install, no box paths --------------------
# marcus/DIVE-562: a predicate that short-circuits on an installed binary or a
# root-only path passes at a desk and reds on the runner.
[[ "$AUDIT_LOG" == "$TMP/"* ]] \
  && ok_t "L1: every arm above wrote to a tempdir log, never the fleet log" \
  || bad_t "L1: AUDIT_LOG is under the tempdir" "$AUDIT_LOG"
L_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx '/usr/local/bin' | paste -sd:)"
clear_log; id5=$(seed)
out=$( PATH="$L_PATH" HOME="$TMP" cmd_task_deliver "$id5" --pr="$PR" --result="$EVID" 2>&1 )
[[ "$(rows 'task deliver')" == "1" ]] \
  && ok_t "L2: still writes with /usr/local/bin off PATH and HOME in the tempdir — nothing here needs this box's install" \
  || bad_t "L2: the arms do not depend on an installed 5dive" "rows=$(rows 'task deliver') out=${out:0:300}"
# The pattern lives in a variable so the arm cannot match its OWN literal.
_boxpat='/etc/5dive|/var/lib/5dive|/var/log/5dive|/usr/local/bin/5dive'
# Comment lines are excluded: this file's own header EXPLAINS which box paths it
# avoids, and an arm that cannot tell prose from code would forbid saying so.
_boxhits="$(grep -nE "$_boxpat" "$0" | grep -v '_boxpat=' | grep -vE '^[0-9]+:[[:space:]]*#')"
[[ -z "$_boxhits" ]] \
  && ok_t "L3: ... and this harness names no box path outside its own prose (L2 is not the only thing holding that)" \
  || bad_t "L3: the harness reads no box path" "$_boxhits"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
