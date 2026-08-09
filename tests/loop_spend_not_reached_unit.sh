#!/usr/bin/env bash
# DIVE-2304: a FAILED spend read is a third state (NOT-REACHED), not zero.
#
# The defect this grades: `_loop_refresh_spend` coerced every failure — missing
# loop_runs row, python exiting non-zero with its stderr discarded, non-numeric
# output — to the integer 0, which is ALSO what a genuinely-idle loop reports.
# `spent >= ceiling` therefore could not fire, and the persist ran on the
# fail-open path too, so one transient failure CLOBBERED the accumulated running
# total to 0 in durable state. The ceiling did not go blind for a tick; it lost
# the number it was supposed to test against.
#
# TWO-SIDED on purpose (the acceptance criterion): the sick arm alone would pass
# against a producer that had simply stopped working, so every unreadable case
# is paired with a HEALTHY case run through the same code on the same fixture.
#
# Two levels, deliberately, because they can disagree:
#   - PRODUCER arms drive the real `_loop_refresh_spend` with a real broken
#     python (shadowed as a shell function) — no stub, so the contract is the
#     shipped one.
#   - CONSUMER arms drive the real `cmd_loop_spawn --wait` poll with that SAME
#     real broken producer, so a contract mismatch between the two cannot hide.
# Run: bash tests/loop_spend_not_reached_unit.sh  (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-spend-nr.XXXXXX)"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh \
         cmd_usage.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; LOOP_POLL_SECS=1; export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- fixture: one loop with one in-window child task and a real transcript ----
AG="spendtest"
FAKEHOME="$TMP/home-$AG"; mkdir -p "$FAKEHOME/.claude/projects/proj"
REGISTRY="$TMP/registry.json"
printf '{"agents":{"%s":{"type":"claude"}}}' "$AG" > "$REGISTRY"
now=$(date +%s); start=$((now-300))
db "INSERT INTO tasks (ident,title,status,assignee,kind,started_at,created_at,updated_at)
    VALUES ('FIX-1','spend fixture','in_progress','$AG','standard',datetime($start,'unixepoch'),datetime($start,'unixepoch'),datetime($start,'unixepoch'));"
tid=$(db "SELECT id FROM tasks WHERE ident='FIX-1';")
db "INSERT INTO loop_runs (loop_id,topology,status,tokens_spent,ceiling,child_task_ids,spawned_by_task,started_at,updated_at)
    VALUES ('L-nr','spawn','running',60000,50000,'[$tid]',$tid,$start,$start);"
ts1=$(date -u -d "@$((start+10))" +%FT%TZ); ts2=$(date -u -d "@$((start+20))" +%FT%TZ)
{
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":10000,"output_tokens":5000,"cache_creation_input_tokens":15000,"cache_read_input_tokens":999999}}}\n' "$ts1"
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":20000,"output_tokens":10000,"cache_creation_input_tokens":0,"cache_read_input_tokens":5}}}\n' "$ts2"
} > "$FAKEHOME/.claude/projects/proj/session.jsonl"
export REGISTRY LOOP_HOME_OVERRIDE_JSON
LOOP_HOME_OVERRIDE_JSON=$(printf '{"%s":"%s"}' "$AG" "$FAKEHOME")

# The injected failure. Shadowing `python3` as a shell function reproduces the
# exact class the `2>/dev/null` hid: the interpreter exits non-zero and writes a
# diagnostic. It varies the INPUT the producer reads (can the recompute run?),
# which is the axis the ceiling decision actually turns on — a mutation that
# varied the ceiling or the row instead would say nothing about this branch.
break_python()  { python3() { printf 'Traceback: simulated interpreter failure\n' >&2; return 1; }; }
heal_python()   { unset -f python3; }

# =========================== PRODUCER, SICK ARM ==============================
break_python
seed_before=$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-nr';")
out_nr=$(_loop_refresh_spend "L-nr" 2>"$TMP/nr.err"); rc_nr=$?
[[ "$rc_nr" == "2" ]] && ok_t "unreadable spend returns rc 2 (NOT-REACHED), not rc 0" \
  || bad_t "producer rc" "got rc=$rc_nr out='$out_nr'"
[[ -z "$out_nr" ]] && ok_t "unreadable spend echoes NOTHING (never the integer 0)" \
  || bad_t "producer stdout" "echoed '$out_nr' — a 0 here is indistinguishable from an idle loop"
[[ -s "$TMP/nr.err" ]] && grep -q 'NOT-REACHED' "$TMP/nr.err" \
  && ok_t "cause reaches stderr (the discarded 2>/dev/null is why this was invisible)" \
  || bad_t "producer stderr" "empty or unnamed: $(cat "$TMP/nr.err")"
grep -q 'simulated interpreter failure' "$TMP/nr.err" \
  && ok_t "the interpreter's OWN stderr is carried through, not swallowed" \
  || bad_t "python stderr dropped" "$(cat "$TMP/nr.err")"
after=$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-nr';")
[[ "$after" == "$seed_before" && "$after" == "60000" ]] \
  && ok_t "failed read does NOT clobber the persisted total (still $after)" \
  || bad_t "CLOBBERED" "tokens_spent went $seed_before -> $after on a failed read"

# _loop_spent must propagate rather than re-launder the stale row as fresh.
sp=$(_loop_spent "L-nr" 2>/dev/null); rc_sp=$?
[[ "$rc_sp" == "2" && -z "$sp" ]] && ok_t "_loop_spent propagates NOT-REACHED (rc 2, no value)" \
  || bad_t "_loop_spent" "rc=$rc_sp out='$sp'"
_loop_ceiling_check "L-nr" 50000 >/dev/null 2>&1
[[ $? == 2 ]] && ok_t "_loop_ceiling_check: unreadable -> rc 2 (third state survives to the consumer)" \
  || bad_t "ceiling_check unreadable" "rc=$?"

# ========================== PRODUCER, HEALTHY ARM ============================
# Anchor: the sick arm's red must not be "the producer is simply broken".
heal_python
unset _LOOP_SPEND_LAST; declare -A _LOOP_SPEND_LAST
db "UPDATE loop_runs SET tokens_spent=0 WHERE loop_id='L-nr';"
out_ok=$(_loop_refresh_spend "L-nr" 2>"$TMP/ok.err"); rc_ok=$?
# (10000+5000+15000) + (20000+10000+0) = 60000; cache-read excluded.
[[ "$rc_ok" == "0" && "$out_ok" == "60000" ]] \
  && ok_t "healthy read still recomputes real spend (rc 0, =$out_ok)" \
  || bad_t "healthy producer" "rc=$rc_ok out='$out_ok' err=$(cat "$TMP/ok.err")"
[[ "$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-nr';")" == "60000" ]] \
  && ok_t "healthy read still PERSISTS (the un-clobbering did not disable the write)" \
  || bad_t "healthy persist" "$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-nr';")"
_loop_ceiling_check "L-nr" 50000 >/dev/null 2>&1
[[ $? == 1 ]] && ok_t "_loop_ceiling_check: 60000 over ceiling 50000 -> rc 1 (ceiling still fires)" \
  || bad_t "ceiling_check breach" "rc=$?"
_loop_ceiling_check "L-nr" 500000 >/dev/null 2>&1
[[ $? == 0 ]] && ok_t "_loop_ceiling_check: under ceiling -> rc 0 (loop keeps running)" \
  || bad_t "ceiling_check under" "rc=$?"

# A loop row that is absent is also NOT-REACHED, never "0 spent".
# shellcheck disable=SC2218  # the real producer is sourced; the stub below is later
_loop_refresh_spend "L-does-not-exist" >/dev/null 2>&1
[[ $? == 2 ]] && ok_t "missing loop_runs row -> rc 2, not a silent 0" || bad_t "missing row" "rc=$?"

# ========================== CONSUMER, END TO END =============================
# Same real producer, same real failure, driven through the shipped --wait poll.
# `status` cannot carry this (DIVE-2105: ceiling/timeout/escalated all fold onto
# "escalated"), so the assertion is on haltReason — which is also why asserting
# status alone here would assert the failure mode's own value.
poll_row() {   # <prompt-marker> -> echoes loop_id once its row appears
  local marker="$1" i lid
  for (( i=0; i<60; i++ )); do
    lid=$(db "SELECT l.loop_id FROM loop_runs l JOIN tasks t ON l.child_task_ids='['||t.id||']'
              WHERE t.title LIKE '%${marker}%' OR t.body LIKE '%${marker}%' LIMIT 1;")
    [[ -n "$lid" ]] && { printf '%s' "$lid"; return 0; }
    sleep 0.25
  done
  return 1
}

break_python
( cmd_loop_spawn --agent=main --prompt="UNIQ_unreadable" --ceiling=1000000 --wait=25 \
    >"$TMP/spawn-nr.out" 2>"$TMP/spawn-nr.err" ) &
bgpid=$!
poll_row UNIQ_unreadable >/dev/null || bad_t "consumer setup" "loop row never appeared"
wait $bgpid
u_st=$(jq -r '.data.status'     "$TMP/spawn-nr.out" 2>/dev/null)
u_hr=$(jq -r '.data.haltReason' "$TMP/spawn-nr.out" 2>/dev/null)
[[ "$u_hr" == "spend-unreadable" ]] \
  && ok_t "--wait HALTS on an unreadable spend (haltReason=spend-unreadable, ceiling 1000000 never reached)" \
  || bad_t "consumer halt" "status=$u_st haltReason=$u_hr $(cat "$TMP/spawn-nr.out")"
[[ "$u_st" == "escalated" ]] \
  && ok_t "unreadable halt maps to the existing wire status (escalated) — no reader breaks" \
  || bad_t "consumer wire status" "status=$u_st"
[[ "$u_hr" != "timeout" ]] \
  && ok_t "the halt is the spend read, NOT the --wait deadline expiring" \
  || bad_t "halted on timeout" "the poll ran to its deadline; the third state never fired"

# Healthy consumer arm: the ceiling must still fire, as itself, on the same path.
heal_python
_loop_refresh_spend() { db "SELECT COALESCE(tokens_spent,0) FROM loop_runs WHERE loop_id='$1';"; }
( cmd_loop_spawn --agent=main --prompt="UNIQ_spendy" --ceiling=1000 --wait=25 \
    >"$TMP/spawn-ceil.out" 2>"$TMP/spawn-ceil.err" ) &
bgpid=$!
if clid=$(poll_row UNIQ_spendy); then
  db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"
else
  bad_t "ceiling setup" "loop row never appeared"
fi
wait $bgpid
c_st=$(jq -r '.data.status'     "$TMP/spawn-ceil.out" 2>/dev/null)
c_hr=$(jq -r '.data.haltReason' "$TMP/spawn-ceil.out" 2>/dev/null)
[[ "$c_st" == "escalated" && "$c_hr" == "ceiling" ]] \
  && ok_t "healthy path: ceiling still fires at the threshold (haltReason=ceiling)" \
  || bad_t "ceiling regressed" "status=$c_st haltReason=$c_hr $(cat "$TMP/spawn-ceil.out")"
unset -f _loop_refresh_spend

# ===================== HEARTBEAT SWEEP (async backstop) ======================
# The sweep is the ONLY ceiling enforcement a fire-and-forget loop has, and it
# called the producer with `2>/dev/null || echo 0` — so a broken recompute both
# passed every breached loop AND wrote the 0 back every tick.
source "$SRC/cmd_loop.sh"   # restore the shipped producer after the stub above
db "UPDATE loop_runs SET tokens_spent=60000, status='running' WHERE loop_id='L-nr';"
cmd_task_need() { :; }
break_python
_hb_loop_ceiling_sweep >"$TMP/sweep.out" 2>&1
sw_tok=$(db "SELECT tokens_spent FROM loop_runs WHERE loop_id='L-nr';")
[[ "$sw_tok" == "60000" ]] \
  && ok_t "sweep with a broken recompute leaves the last good total intact (=$sw_tok)" \
  || bad_t "sweep CLOBBERED" "tokens_spent -> $sw_tok"
heal_python
printf -- '-----\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
