#!/usr/bin/env bash
# DIVE-594 isolated unit harness for `5dive loop verify` (maker→verifier wrapper).
# Same isolation as loop_spawn_unit.sh: sources src/ directly, points STATE_DIR
# at a throwaway temp dir → never touches the live shared tasks.db. Asserts:
# verifier+accept attach to the target, writer≠grader guard, terminal-target
# guard, loop_runs row, and the --wait verdict/halt paths. Run:
#   bash tests/loop_verify_unit.sh   (no root, no network)
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
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/loop-verify-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; LOOP_POLL_SECS=1; export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# helper: create a target task assigned to a maker, echo its numeric id
mk_target() { ( JSON_MODE=1 cmd_task_add --assignee="$1" --body="$2" -- "$2" ) 2>/dev/null | jq -r '.data.id'; }

# --- T1: attach verifier + accept; returns verifying; loop_runs row; fields set
tid=$(mk_target maker "UNIQ_target_one")
out=$( ( cmd_loop_verify --target="$tid" --verifier=grader --accept="must compile" ) 2>"$TMP"/lv.err )
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
lid=$(printf '%s' "$out" | jq -r '.data.loopId' 2>/dev/null)
[[ "$st" == "verifying" && "$lid" == L-* ]] && ok_t "verify returns {verifying, loopId}" || bad_t "verify basic" "$out $(cat "$TMP"/lv.err)"
v=$(db "SELECT verifier FROM tasks WHERE id=$tid;"); a=$(db "SELECT acceptance_criteria FROM tasks WHERE id=$tid;")
[[ "$v" == "grader" && "$a" == "must compile" ]] && ok_t "verifier+acceptance attached to target ($v/$a)" || bad_t "attach" "v=$v a=$a"
topo=$(db "SELECT topology FROM loop_runs WHERE loop_id='$lid';"); child=$(db "SELECT child_task_ids FROM loop_runs WHERE loop_id='$lid';")
[[ "$topo" == "verify" && "$child" == "[$tid]" ]] && ok_t "loop_runs verify row linked ($child)" || bad_t "loop_runs" "topo=$topo child=$child"

# --- T2: writer≠grader guard (verifier == assignee → reject)
tid2=$(mk_target maker "UNIQ_target_two")
( cmd_loop_verify --target="$tid2" --verifier=maker ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "verifier==assignee rejected (writer≠grader)" || bad_t "writer=grader" "exit 0"

# --- T3: terminal-target guard
tid3=$(mk_target maker "UNIQ_target_three"); db "UPDATE tasks SET status='done' WHERE id=$tid3;"
( cmd_loop_verify --target="$tid3" --verifier=grader ) >/dev/null 2>&1
[[ $? -ne 0 ]] && ok_t "done target rejected (attach before close)" || bad_t "terminal target" "exit 0"

# --- T4: arg validation
( cmd_loop_verify --target="$tid" --verifier=grader --max-iters=0 ) >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "--max-iters=0 rejected" || bad_t "max-iters" "exit 0"
( cmd_loop_verify --target="$tid" --verifier=grader --ceiling=x ) >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "non-int --ceiling rejected" || bad_t "ceiling" "exit 0"

# Poll until a probe reports the background --wait spawn has actually landed its
# row, instead of assuming a fixed `sleep 1` is enough. On a loaded 2-core CI
# runner the spawn path (task insert + loop row, several sqlite/jq execs) can
# take longer than a second: the id below then comes back EMPTY, the UPDATE that
# is supposed to steer the waiter no-ops, and the waiter burns its full --wait
# and reports the wrong status — a flaky red with no bug behind it (DIVE-1951).
# Same precedent as wait_graders() in loop_panel_unit.sh. Bounded ~10s.
poll_new() { # <prev-value> <probe...> → echo first value that is non-empty and != prev
  local prev="$1"; shift
  local i out=""
  for i in $(seq 1 100); do
    out=$("$@")
    [[ -n "$out" && "$out" != "$prev" ]] && { printf '%s' "$out"; return 0; }
    sleep 0.1
  done
  # never fail SILENTLY into an empty id: an empty return here makes the assertion
  # below red as if the product misbehaved, when in fact the CHECK never got an
  # answer. Say so out loud (DIVE-1951).
  echo "poll_new: TIMED OUT after ~10s waiting for '$*' to yield a new value (prev='$prev', last='$out') — the next assertion fails on an EMPTY id, not on a product bug" >&2
  printf '%s' "$out"; return 1
}

# the loop row for a target only exists once cmd_loop_verify is past its
# terminal-target validation — poll for it before flipping the target, or the
# flip can land first and the command legitimately rejects a done target.
lv_loop_for() { db "SELECT lr.loop_id FROM loop_runs lr WHERE lr.child_task_ids='[$1]' ORDER BY lr.started_at DESC LIMIT 1;"; }

# --- T5: --wait → done verdict pass (flip target done mid-wait)
tidw=$(mk_target maker "UNIQ_target_wait")
( cmd_loop_verify --target="$tidw" --verifier=grader --wait=20 >"$TMP"/lv-done.out 2>&1 ) &
bg=$!; poll_new "" lv_loop_for "$tidw" >/dev/null
db "UPDATE tasks SET status='done', result='graded PASS' WHERE id=$tidw;"; wait $bg
dst=$(jq -r '.data.status' "$TMP"/lv-done.out 2>/dev/null); dvd=$(jq -r '.data.verdict' "$TMP"/lv-done.out 2>/dev/null); dres=$(jq -r '.data.result' "$TMP"/lv-done.out 2>/dev/null)
[[ "$dst" == "done" && "$dvd" == "pass" && "$dres" == "graded PASS" ]] && ok_t "--wait → done/pass with result" || bad_t "wait done" "$(cat "$TMP"/lv-done.out)"

# --- T6: --wait halts on KILL
tidk=$(mk_target maker "UNIQ_target_kill")
( cmd_loop_verify --target="$tidk" --verifier=grader --wait=20 >"$TMP"/lv-kill.out 2>&1 ) &
bg=$!
# DIVE-2105: GRADE the poll — a discarded exit status steers nothing and reds the
# next assertion as if the PRODUCT misbehaved (the DIVE-2083 silent-poller shape).
if klid=$(poll_new "" lv_loop_for "$tidk"); then
  db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"
else
  bad_t "kill setup" "poll_new timed out — the verify loop row never appeared, so kill_requested was never set"
fi
wait $bg
kst=$(jq -r '.data.status' "$TMP"/lv-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill → killed" || bad_t "kill" "$(cat "$TMP"/lv-kill.out)"

# --- T7: --wait halts on CEILING
# DIVE-2105: this case had NEVER exercised the ceiling — the same construction and
# the same two mechanisms as the panel's T9 (DIVE-2083). MEASURED before the fix:
# this harness took 26.0s, and 7.0s with the refresher stubbed — a ~19s drop on a
# --wait=20 deadline, i.e. it was halting on TIMEOUT every run.
#   1. cmd_loop_verify labelled a ceiling breach "escalated", and its `*)` arm maps
#      EVERY non-done, non-killed halt (timeout included) onto exactly the same
#      status AND verdict — so both asserted values were also the failure mode's.
#   2. `_loop_spent` refreshes on its first call and `_loop_refresh_spend`
#      recomputes tokens_spent from the agent usage registry (absent in a unit
#      harness), writing 0 over the 5000 poked in below.
_loop_refresh_spend() { db "SELECT COALESCE(tokens_spent,0) FROM loop_runs WHERE loop_id='$1';"; }
tidc=$(mk_target maker "UNIQ_target_ceil")
( cmd_loop_verify --target="$tidc" --verifier=grader --ceiling=1000 --wait=20 >"$TMP"/lv-ceil.out 2>&1 ) &
bg=$!
if clid=$(poll_new "" lv_loop_for "$tidc"); then
  db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"
else
  bad_t "ceiling halt setup" "poll_new timed out — the verify loop row never appeared, so the ceiling was never breached"
fi
wait $bg
cst=$(jq -r '.data.status' "$TMP"/lv-ceil.out 2>/dev/null); cvd=$(jq -r '.data.verdict' "$TMP"/lv-ceil.out 2>/dev/null)
chr=$(jq -r '.data.haltReason' "$TMP"/lv-ceil.out 2>/dev/null)
[[ "$cst" == "escalated" && "$cvd" == "escalated" && "$chr" == "ceiling" ]] \
  && ok_t "--wait halts on ceiling → escalated (haltReason=ceiling, not timeout)" \
  || bad_t "ceiling halt" "status=$cst verdict=$cvd haltReason=$chr $(cat "$TMP"/lv-ceil.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
