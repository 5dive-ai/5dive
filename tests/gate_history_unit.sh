#!/usr/bin/env bash
# TIER: nightly — 14.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2119 isolated unit harness — retiring a gate must ARCHIVE it and then
# reset ALL SIX provenance columns, at EVERY path that retires one.
#
# WHY THIS EXISTS. Four separate UPDATEs retired a gate by nulling only the two
# columns that carry the MEANING (need_answer, need_answered_at) and leaving the
# three that carry the ATTRIBUTION (need_answered_by, need_answered_uid,
# need_answer_sig) plus the human tap nonce standing:
#   gate re-file, `need --withdraw`, `task park`, loop-ceiling auto-park.
# DIVE-2094 measured 21 live rows in that state — 8 of them a LIVE gate wearing
# the previous gate's answerer, 3 of those claiming `human:*` provenance on a
# gate no human had seen. A row in that state reads as UNANSWERED to every guard
# and as HUMAN-ATTESTED to every reader that skips the guard.
#
# The obvious one-line fix (null the three too) would have been destructive:
# there was no gate history anywhere, so the leaked attribution WAS the only
# surviving trace of the displaced gate. Hence archive-then-clear, indivisible.
#
# What is pinned here:
#   1. LIVENESS + the archive: a re-file over an ANSWERED gate writes exactly one
#      gate_history row carrying the OUTGOING gate's answer, answerer and type —
#      the content that was destroyed before this fix;
#   2. the reset: after each of the FOUR retirement paths, all six provenance
#      columns are NULL. Each case is asserted separately, because the defect was
#      precisely that a fix scoped to two paths leaves the other two producing;
#   3. ATOMICITY: an archive row exists if and only if the reset happened — no
#      path can leave provenance cleared with nothing archived;
#   4. NON-VACUITY: filing a FIRST gate on a virgin task archives NOTHING, so an
#      archive row is evidence a gate was displaced, not that a verb ran;
#   5. the nonce is reset too — a nonce minted for a superseded gate must not
#      verify against the gate that replaced it;
#   6. _proof_ledger's need_answered_by arm no longer counts re-file residue,
#      while its human_nonce_hash arm still counts a delivered-but-unanswered
#      gate (the deliberate asymmetry — see cmd_proof.sh).
#   7. the archive is READABLE through task show + task gate-history, with
#      secret answers redacted and pre-archive blindness stated explicitly.
# Run: bash tests/gate_history_unit.sh   (no root, no network)
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
TMP="$(mktemp -d /tmp/gate-history.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_proof.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

# Preconditions, not observables: never ping a channel, never write the fleet
# audit log, and keep gate-proof enforcement deterministic on any box.
task_need_notify() { return 0; }
audit_log() { return 0; }
_gate_proof_enforced() { return 0; }
# `need --withdraw` authorizes on the REAL caller identity; this suite is not
# testing that gate, so present as a human caller (mirrors the seam the
# DIVE-1401 suite uses).
_gate_withdraw_actor() { printf 'human'; }

# The six columns a retirement must reset, and the archive.
prov() { db "SELECT COALESCE(need_answer,'.')||'|'||COALESCE(need_answered_at,'.')||'|'
                 ||COALESCE(need_answered_by,'.')||'|'||COALESCE(need_answered_uid,'.')||'|'
                 ||COALESCE(need_answer_sig,'.')
             FROM tasks WHERE id=${1};" | tr -d ' \n'; }
# The nonce is the sixth column of the reset; kept separate because a re-file
# mints a fresh one for the INCOMING gate (case 1) while the other three paths
# leave the row gateless (cases 2-4).
nonce() { db "SELECT COALESCE(human_nonce_hash,'.') FROM tasks WHERE id=${1};"; }
hist_n() { db "SELECT COUNT(*) FROM gate_history WHERE task_id=${1};"; }

# Plant an ANSWERED gate carrying all six columns, the state a retirement must
# displace. Written directly so the case is identical across all four paths and
# does not depend on the answer path's own policy checks.
plant() {
  local id="$1"
  ( cmd_task_need "$id" --type=decision --options="A|B" --recommend="A" \
    --ask="fixture gate on $id" --tier=1 ) >/dev/null 2>&1
  db "UPDATE tasks SET need_answer='B', need_answered_at=datetime('now'),
        need_answered_by='human:lodar', need_answered_uid=1000,
        need_answer_sig='sig-fixture', human_nonce_hash='deadbeef'
      WHERE id=${id};"
}

# --- 1. re-file: archives the outgoing gate, and archives its CONTENT ---------
t1=$(addt --assignee=dev -- "fixture: re-file over an answered gate")
plant "$t1"
( cmd_task_need "$t1" --type=manual --ask="the SECOND gate" --tier=1 ) >/dev/null 2>&1
if [[ "$(hist_n "$t1")" == "1" ]]; then
  ok_t "re-file archives exactly one gate_history row"
else
  bad_t "re-file must archive the displaced gate" "rows=$(hist_n "$t1")"
fi
H=$(db "SELECT COALESCE(need_answer,'')||'|'||COALESCE(need_answered_by,'')||'|'
            ||COALESCE(need_type,'')||'|'||COALESCE(retired_by,'')
        FROM gate_history WHERE task_id=${t1};")
if [[ "$H" == "B|human:lodar|decision|file" ]]; then
  ok_t "the archive preserves the OUTGOING answer, answerer and type ($H)"
else
  bad_t "archive must carry the displaced gate's content" "got='$H'"
fi
# The whole point: the answer TEXT survives, which is the half that used to be
# lost while the answerer leaked through.
if [[ "$(db "SELECT need_answer FROM gate_history WHERE task_id=${t1};")" == "B" ]]; then
  ok_t "the displaced ANSWER TEXT survives its own retirement"
else
  bad_t "the answer text must be archived — it is the half with decision content"
fi
if [[ "$(prov "$t1")" == ".|.|.|.|." ]]; then
  ok_t "re-file resets all five answer-provenance columns on the live row"
else
  bad_t "re-file must reset all five columns" "got=$(prov "$t1")"
fi
# The nonce is reset too — but the INCOMING gate is `manual`, which mints its
# own nonce right after the filing UPDATE. So assert the displacement, not
# absence: the surviving hash must not be the retired gate's.
N1=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${t1};")
if [[ "$N1" != "deadbeef" ]]; then
  ok_t "the retired gate's nonce does not survive the re-file (case 6 pins the clear)"
else
  bad_t "the previous gate's nonce leaked onto the new gate" "hash=$N1"
fi
# The new gate is intact — the reset must not eat the gate it just filed.
if [[ "$(db "SELECT need_type FROM tasks WHERE id=${t1};")" == "manual" ]]; then
  ok_t "the incoming gate is intact after the reset"
else
  bad_t "the incoming gate must survive" "type=$(db "SELECT need_type FROM tasks WHERE id=${t1};")"
fi

# --- 2. withdraw --------------------------------------------------------------
t2=$(addt --assignee=dev -- "fixture: withdraw")
plant "$t2"
# --withdraw refuses an ALREADY-ANSWERED gate, so clear the answered marker the
# way the live path sees it: a still-pending gate carrying stale provenance from
# a PREVIOUS gate. That is exactly DIVE-2094's re-file residue shape.
db "UPDATE tasks SET need_answer=NULL, need_answered_at=NULL WHERE id=${t2};"
( cmd_task_need "$t2" --withdraw ) >/dev/null 2>&1
if [[ "$(prov "$t2")" == ".|.|.|.|." && "$(nonce "$t2")" == "." ]]; then
  ok_t "withdraw resets all six provenance columns (13 orphans were this path + park)"
else
  bad_t "withdraw must reset all six columns (5 + nonce)" "got=$(prov "$t2")"
fi
if [[ "$(hist_n "$t2")" == "1" ]]; then
  ok_t "withdraw archives the gate it retires"
else
  bad_t "withdraw must archive before clearing" "rows=$(hist_n "$t2")"
fi
if [[ "$(db "SELECT retired_by FROM gate_history WHERE task_id=${t2};")" == "withdraw" ]]; then
  ok_t "the archive names the verb that retired it (withdraw)"
else
  bad_t "retired_by must name the withdrawing verb"
fi

# --- 3. task park -------------------------------------------------------------
# park REFUSES over a live gate (DIVE-1453), so the gate it retires is an
# answered one — precisely the case that leaked provenance with no gate left.
t3=$(addt --assignee=dev -- "fixture: park")
plant "$t3"
( cmd_task_park "$t3" --reason="fixture park" --wake=+7d ) >/dev/null 2>&1
if [[ "$(prov "$t3")" == ".|.|.|.|." && "$(nonce "$t3")" == "." ]]; then
  ok_t "park resets all six provenance columns (was MISSING from the first scoping)"
else
  bad_t "park must reset all six columns (5 + nonce)" "got=$(prov "$t3")"
fi
if [[ "$(hist_n "$t3")" == "1" && "$(db "SELECT retired_by FROM gate_history WHERE task_id=${t3};")" == "park" ]]; then
  ok_t "park archives the gate it retires, tagged retired_by=park"
else
  bad_t "park must archive before clearing" "rows=$(hist_n "$t3") by=$(db "SELECT retired_by FROM gate_history WHERE task_id=${t3};")"
fi
if [[ "$(db "SELECT status FROM tasks WHERE id=${t3};")" == "blocked" \
   && -n "$(db "SELECT parked_at FROM tasks WHERE id=${t3};")" ]]; then
  ok_t "park still parks (the archive did not displace the verb's own effect)"
else
  bad_t "park must still park the task"
fi

# --- 4. loop-ceiling auto-park (the SET path) --------------------------------
# The heartbeat's ceiling sweep parks a whole set of child tasks with one UPDATE.
# Exercise the same SQL shape it emits, over two rows at once, including a row
# the predicate must NOT touch (already parked).
t4a=$(addt --assignee=dev -- "fixture: loop child A")
t4b=$(addt --assignee=dev -- "fixture: loop child B")
t4c=$(addt --assignee=dev -- "fixture: loop child C (already parked — untouched)")
plant "$t4a"; plant "$t4b"; plant "$t4c"
# A live gate leaves the task 'blocked'; the sweep only touches todo/in_progress.
db "UPDATE tasks SET status='todo' WHERE id IN (${t4a},${t4b},${t4c});"
db "UPDATE tasks SET parked_at=datetime('now') WHERE id=${t4c};"
PRED="id IN (${t4a},${t4b},${t4c}) AND status IN ('todo','in_progress') AND parked_at IS NULL"
db "BEGIN IMMEDIATE;
    $(_gate_archive_and_clear_sql loop-ceiling "$PRED")
    UPDATE tasks
      SET status='blocked', parked_at=datetime('now'), park_reason='ceiling',
          need_type=NULL, ask=NULL, need_options=NULL, recommend=NULL
    WHERE ${PRED};
    COMMIT;"
if [[ "$(prov "$t4a")" == ".|.|.|.|." && "$(prov "$t4b")" == ".|.|.|.|." && "$(nonce "$t4a")" == "." ]]; then
  ok_t "loop-ceiling park resets all six columns across the whole SET"
else
  bad_t "loop-ceiling park must reset every row it parks" "a=$(prov "$t4a") b=$(prov "$t4b")"
fi
if [[ "$(hist_n "$t4a")" == "1" && "$(hist_n "$t4b")" == "1" ]]; then
  ok_t "loop-ceiling park archives one row per task it retires"
else
  bad_t "set-wide archive must be per-task" "a=$(hist_n "$t4a") b=$(hist_n "$t4b")"
fi
# ATOMICITY, read as a coupling: the untouched row keeps BOTH its provenance and
# its empty history. Cleared-without-archive and archived-without-clear are the
# two states the transaction exists to forbid.
if [[ "$(prov "$t4c")" != ".|.|.|.|." && "$(hist_n "$t4c")" == "0" ]]; then
  ok_t "a row outside the predicate is neither archived NOR cleared (coupled)"
else
  bad_t "the archive and the reset must cover exactly the same rows" \
        "prov=$(prov "$t4c") hist=$(hist_n "$t4c")"
fi

# --- 5. NON-VACUITY: a FIRST gate archives nothing ---------------------------
t5=$(addt --assignee=dev -- "fixture: virgin task, first gate ever")
( cmd_task_need "$t5" --type=decision --options="A|B" --ask="first gate" --tier=1 ) >/dev/null 2>&1
if [[ "$(hist_n "$t5")" == "0" ]]; then
  ok_t "filing a FIRST gate archives nothing (a row means a gate was DISPLACED)"
else
  bad_t "an empty gate must not produce a history row" "rows=$(hist_n "$t5")"
fi

# --- 6. the nonce cannot outlive the gate it was minted for ------------------
# _human_nonce_verify checks a presented nonce against whatever hash the ROW
# holds, so a nonce surviving a retirement would verify against the gate that
# replaced it — an old Telegram tap button clearing a new gate.
t6=$(addt --assignee=dev -- "fixture: nonce must not survive a retirement")
( cmd_task_need "$t6" --type=approval --ask="tier-2 gate that mints a nonce" ) >/dev/null 2>&1
NONCE_BEFORE=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${t6};")
( cmd_task_need "$t6" --withdraw ) >/dev/null 2>&1
NONCE_AFTER=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${t6};")
if [[ -n "$NONCE_BEFORE" ]]; then
  ok_t "liveness: an approval gate really did mint a nonce (the path is live)"
else
  bad_t "no nonce was minted, so the assertion below is vacuous"
fi
if [[ -z "$NONCE_AFTER" ]]; then
  ok_t "a retired gate's nonce is cleared — a stale tap cannot clear its successor"
else
  bad_t "human_nonce_hash must not survive a retirement" "after='$NONCE_AFTER'"
fi
if [[ "$(db "SELECT COALESCE(human_nonce_hash,'') FROM gate_history WHERE task_id=${t6};")" == "$NONCE_BEFORE" ]]; then
  ok_t "the nonce hash is preserved in the archive (cleared, not destroyed)"
else
  bad_t "the archive must carry the nonce hash"
fi

# --- 7. _proof_ledger: guarded by-arm, deliberately unguarded nonce arm ------
# Both cases are done+standard, the ledger's own partition.
led_asks() { _proof_ledger | jq -r '.asks'; }
t7=$(addt --assignee=dev -- "fixture: re-file residue on a done task")
db "UPDATE tasks SET status='done', kind='standard', need_type='approval',
      need_answered_by='human:lodar', need_answered_at=NULL WHERE id=${t7};"
BEFORE=$(led_asks)
if [[ "$BEFORE" == "0" ]]; then
  ok_t "re-file residue (human:* answerer, NULL answered_at) counts as ZERO asks"
else
  bad_t "the by-arm must require need_answered_at" "asks=$BEFORE"
fi
# Same row, now genuinely answered: the arm must still FIRE, or the guard has
# simply disabled the metric rather than corrected it.
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE id=${t7};"
if [[ "$(led_asks)" == "1" ]]; then
  ok_t "a genuinely human-answered gate still counts (the guard corrects, not disables)"
else
  bad_t "an answered human gate must count as an ask" "asks=$(led_asks)"
fi
# The nonce arm keeps its 'delivered to a human' semantics: an unanswered gate
# carrying a nonce still counts. Changing this would move a published number.
db "UPDATE tasks SET need_answered_by=NULL, need_answered_at=NULL,
      human_nonce_hash='deadbeef' WHERE id=${t7};"
if [[ "$(led_asks)" == "1" ]]; then
  ok_t "the nonce arm still counts a delivered-but-unanswered gate (conservative)"
else
  bad_t "the nonce arm must keep its delivered semantics" "asks=$(led_asks)"
fi

# --- 8. reader: detailed rows + compact task-show summary --------------------
JSON_MODE=1
HJSON=$(cmd_task_gate_history "$t1" 2>"$TMP/history-json.err")
if jq -e '.ok == true and .data.summary.recorded == 1 and
          .data.summary.coverage_state == "complete" and
          .data.gates[0].need_answer == "B" and
          .data.gates[0].retired_by == "file" and
          (.data.gates[0].retired_at | length > 0)' <<<"$HJSON" >/dev/null; then
  ok_t "gate-history JSON reads the displaced answer plus retirement reason/time"
else
  bad_t "gate-history JSON must expose the archived gate" "$HJSON"
fi

SHOWJSON=$(cmd_task_show "$t1" 2>"$TMP/show-json.err")
if jq -e '.data.previous_gates.recorded == 1 and
          .data.previous_gates.coverage_complete_for_task == true' <<<"$SHOWJSON" >/dev/null; then
  ok_t "task show JSON carries the compact previous-gate count and coverage state"
else
  bad_t "task show JSON must surface the archive summary" "$SHOWJSON"
fi

JSON_MODE=0
HSHOW=$(cmd_task_show "$t1" 2>"$TMP/show-human.err")
if grep -Fq 'previous gates = 1' <<<"$HSHOW"; then
  ok_t "task show human output surfaces the compact previous-gate count"
else
  bad_t "task show human output must surface previous gates" "$HSHOW"
fi

# --- 9. secret answers never cross the new reader ----------------------------
JSON_MODE=1
t8=$(addt --assignee=dev -- "fixture: archived secret is redacted")
db "INSERT INTO gate_history(task_id,ident,need_type,ask,need_answer,retired_by)
      SELECT id,ident,'secret','provide fixture secret','DO-NOT-PRINT','withdraw'
      FROM tasks WHERE id=${t8};"
SECRET_JSON=$(cmd_task_gate_history "$t8" 2>"$TMP/secret-json.err")
JSON_MODE=0
SECRET_HUMAN=$(cmd_task_gate_history "$t8" 2>"$TMP/secret-human.err")
if [[ "$SECRET_JSON" != *"DO-NOT-PRINT"* && "$SECRET_HUMAN" != *"DO-NOT-PRINT"* ]] \
   && grep -Fq '(provided - redacted)' <<<"$SECRET_JSON" \
   && grep -Fq '(provided - redacted)' <<<"$SECRET_HUMAN"; then
  ok_t "gate-history redacts secret answers in JSON and human output"
else
  bad_t "a secret answer crossed the reader" "json=$SECRET_JSON human=$SECRET_HUMAN"
fi

# --- 10. zero rows: complete evidence vs pre-archive blindness ---------------
# t5 was created after the fresh-store coverage stamp, so zero is a truthful
# complete zero. A task moved before the boundary must instead say only zero
# RECORDED and mark its earlier era unknown.
JSON_MODE=1
FRESH_STAMP=$(_task_pref_get gate_history_coverage)
FRESH_TIME="${FRESH_STAMP#fresh:}"
db "UPDATE tasks SET created_at=$(sqlq "$FRESH_TIME") WHERE id=${t5};"
COMPLETE_ZERO=$(cmd_task_gate_history "$t5" 2>"$TMP/complete-zero.err")
t9=$(addt --assignee=dev -- "fixture: task predates archive coverage")
db "UPDATE tasks SET created_at='2000-01-01 00:00:00' WHERE id=${t9};"
PARTIAL_ZERO=$(cmd_task_gate_history "$t9" 2>"$TMP/partial-zero.err")
if jq -e '.data.summary.recorded == 0 and
          .data.summary.coverage_complete_for_task == true and
          .data.summary.coverage_basis == "fresh" and
          .data.summary.history_before_coverage == "none"' <<<"$COMPLETE_ZERO" >/dev/null; then
  ok_t "a fresh-store task exactly on the second-granular boundary reports a complete zero"
else
  bad_t "fresh-boundary equality must be distinguishable" "$COMPLETE_ZERO"
fi
if jq -e '.data.summary.recorded == 0 and
          .data.summary.coverage_complete_for_task == false and
          .data.summary.history_before_coverage == "unknown"' <<<"$PARTIAL_ZERO" >/dev/null; then
  ok_t "a pre-boundary task reports zero recorded with earlier history unknown"
else
  bad_t "pre-archive blindness must not render as no displaced gates" "$PARTIAL_ZERO"
fi

JSON_MODE=0
PARTIAL_SHOW=$(cmd_task_show "$t9" 2>"$TMP/partial-show.err")
if grep -Fq 'previous gates = 0 recorded (earlier history unknown; coverage begins ' <<<"$PARTIAL_SHOW"; then
  ok_t "task show states the blind era on a pre-boundary zero"
else
  bad_t "task show must not assert the pre-archive era was quiet" "$PARTIAL_SHOW"
fi

# --- 11. upgraded store marker: earliest provable row, stamped once ----------
EARLIEST=$(db "SELECT MIN(retired_at) FROM gate_history;")
db "DELETE FROM task_prefs WHERE key='gate_history_coverage';"
tasks_db_init
STAMPED=$(_task_pref_get gate_history_coverage)
if [[ -n "$EARLIEST" && "$STAMPED" == "inferred:$EARLIEST" ]]; then
  ok_t "migration stamps the earliest provable archived row as the coverage boundary"
else
  bad_t "migration must use evidence, not a release-date guess" "earliest=$EARLIEST stamped=$STAMPED"
fi
tasks_db_init
if [[ "$(_task_pref_get gate_history_coverage)" == "$STAMPED" ]]; then
  ok_t "the coverage boundary is immutable after its one-time stamp"
else
  bad_t "coverage boundary drifted on a second init"
fi
db "UPDATE tasks SET created_at=$(sqlq "$EARLIEST") WHERE id=${t9};"
JSON_MODE=1
INFERRED_EQUAL=$(cmd_task_gate_history "$t9" 2>"$TMP/inferred-equal.err")
if jq -e '.data.summary.coverage_basis == "inferred" and
          .data.summary.coverage_complete_for_task == false and
          .data.summary.history_before_coverage == "unknown"' <<<"$INFERRED_EQUAL" >/dev/null; then
  ok_t "inferred-boundary equality stays partial (timestamps are only second-granular)"
else
  bad_t "an inferred same-second task must not be overstated as covered" "$INFERRED_EQUAL"
fi

printf -- '-----\n'
printf 'gate_history_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
