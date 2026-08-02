#!/usr/bin/env bash
# TIER: nightly — 10.2s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-593 isolated unit harness for `5dive loop spawn` (the atom).
#
# Sources the src/ libs directly and points STATE_DIR at a throwaway temp dir,
# so it NEVER touches the live shared tasks.db (see memory
# reference_5dive_cli_smoke_hits_live_taskdb — STATE_DIR is otherwise hardcoded
# and a stray real verb migrates+writes the live queue). Asserts: row + backing
# task created, schema/arg validation, ceiling halt, kill halt, clean done
# passthrough. Run: bash tests/loop_spawn_unit.sh  (no root, no network).
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

# temp state dir we own → mkdir works as a normal user, live db untouched.
TMP="$(mktemp -d /tmp/loop-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Source in build.sh order, minus main.sh (we call functions directly).
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# Re-point state at the temp dir AFTER sourcing (header.sh hardcodes it).
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
LOOP_POLL_SECS=1
export LOOP_POLL_SECS
mkdir -p "$TASKS_DIR"   # init refuses to mkdir as non-root; we own this temp dir
set +e   # header.sh enabled `set -e` on source; tests deliberately expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# run a verb in a subshell so its `fail`→exit can't kill the harness
run() { ( cmd_loop_spawn "$@" ) 2>"$TMP"/loop-unit.err; }

tasks_db_init
# sanity: default project must exist (cmd_task_add validates it)
proj=$(db "SELECT key FROM projects WHERE key='dive' AND status='active';")
[[ "$proj" == "dive" ]] && ok_t "default 'dive' project present" || bad_t "default project" "got '$proj'"

# --- T1: spawn (no --wait) creates row + backing task, status running
out=$(run --role=maker --agent=main --prompt="do a thing")
st=$(printf '%s' "$out" | jq -r '.data.status' 2>/dev/null)
lid=$(printf '%s' "$out" | jq -r '.data.loopId' 2>/dev/null)
tid=$(printf '%s' "$out" | jq -r '.data.taskId' 2>/dev/null)
[[ "$st" == "running" && "$lid" == L-* && "$tid" =~ ^[0-9]+$ ]] \
  && ok_t "spawn returns {running, loopId, taskId}" || bad_t "spawn basic" "$out $(cat "$TMP"/loop-unit.err)"
rowtopo=$(db "SELECT topology FROM loop_runs WHERE loop_id='$lid';")
child=$(db "SELECT child_task_ids FROM loop_runs WHERE loop_id='$lid';")
[[ "$rowtopo" == "spawn" && "$child" == "[$tid]" ]] \
  && ok_t "loop_runs row linked to backing task ($child)" || bad_t "loop_runs row" "topo=$rowtopo child=$child"
tbody=$(db "SELECT body FROM tasks WHERE id=$tid;")
[[ "$tbody" == *"loop_id=$lid"* ]] && ok_t "backing task carries loop marker" || bad_t "task marker" "$tbody"
tassignee=$(db "SELECT assignee FROM tasks WHERE id=$tid;")
[[ "$tassignee" == "main" ]] && ok_t "backing task assigned to --agent" || bad_t "assignee" "$tassignee"

# --- T2: validation
run --agent=main >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "missing --prompt fails" || bad_t "missing prompt" "exit 0"
run --prompt=x   >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "missing --agent fails"  || bad_t "missing agent" "exit 0"
run --agent=main --prompt=x --role=bogus >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "bad --role rejected" || bad_t "bad role" "exit 0"
run --agent=main --prompt=x --ceiling=abc >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "non-int --ceiling rejected" || bad_t "bad ceiling" "exit 0"
run --agent=main --prompt=x --schema='{bad' >/dev/null 2>&1; [[ $? -ne 0 ]] && ok_t "invalid --schema json rejected" || bad_t "bad schema" "exit 0"

# --- T3: ceiling default resolution
out=$(run --agent=main --prompt=y); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "200000" ]] && ok_t "built-in ceiling default applied ($c)" || bad_t "ceiling default" "$c"
out=$(LOOP_CEILING_DEFAULT=50000 run --agent=main --prompt=y); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "50000" ]] && ok_t "env LOOP_CEILING_DEFAULT override ($c)" || bad_t "env ceiling" "$c"
out=$(run --agent=main --prompt=y --ceiling=12345); c=$(printf '%s' "$out" | jq -r '.data.ceiling')
[[ "$c" == "12345" ]] && ok_t "--ceiling beats env+builtin ($c)" || bad_t "flag ceiling" "$c"

# resolve a loop row deterministically by its child task's unique prompt
# (avoids started_at ties when several rows land in the same second).
loop_by_prompt() { db "SELECT lr.loop_id FROM loop_runs lr, tasks t WHERE lr.child_task_ids='['||t.id||']' AND t.body LIKE '%$1%' ORDER BY t.id DESC LIMIT 1;"; }
task_by_prompt() { db "SELECT t.id FROM tasks t WHERE t.body LIKE '%$1%' ORDER BY t.id DESC LIMIT 1;"; }

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

# --- T4: --wait halts on KILL (flip kill_requested mid-wait)
( cmd_loop_spawn --agent=main --prompt="UNIQ_killme" --wait=20 >"$TMP"/loop-kill.out 2>&1 ) &
bgpid=$!
# DIVE-2105: GRADE the poll. `klid=$(poll_new …)` throws poll_new's exit status
# away, so a timed-out poll steers nothing and the assertion below reds naming
# the PRODUCT — the silent-poller shape that cost DIVE-2083 two diagnostic passes.
if klid=$(poll_new "" loop_by_prompt UNIQ_killme); then
  db "UPDATE loop_runs SET kill_requested=1 WHERE loop_id='$klid';"
else
  bad_t "kill halt setup" "poll_new timed out — the loop row never appeared, so kill_requested was never set on any row"
fi
wait $bgpid
kst=$(jq -r '.data.status' "$TMP"/loop-kill.out 2>/dev/null)
[[ "$kst" == "killed" ]] && ok_t "--wait halts on kill_requested → killed" || bad_t "kill halt" "$(cat "$TMP"/loop-kill.out)"

# --- T5: --wait halts on CEILING breach
# DIVE-2105: this case had NEVER exercised the ceiling — byte-for-byte the same
# construction, and the same two independent mechanisms, as the panel's T9 that
# DIVE-2083 fixed. MEASURED before the fix: this harness took 25.8s and 7.0s with
# the refresher stubbed, a ~19s drop on a --wait=20 deadline. That runtime IS the
# signature of the vacuity — the case was timing out, not breaching, every run.
#   1. `cmd_loop_spawn` labelled a ceiling breach "escalated", and so does a
#      --wait timeout AND a rejected/escalated backing task. The asserted value
#      was also the failure mode's value, so the assertion could not discriminate.
#   2. `_loop_spent` refreshes on its FIRST call (the throttle window starts at 0)
#      and `_loop_refresh_spend` recomputes tokens_spent from the agent usage
#      registry — which a unit harness does not have — writing 0 straight over
#      the 5000 poked in below.
# Stubbing the refresher removes the one input this harness cannot supply and
# leaves tokens_spent as the input the ceiling decision actually READS; haltReason
# is what makes ceiling-vs-timeout observable at all.
_loop_refresh_spend() { db "SELECT COALESCE(tokens_spent,0) FROM loop_runs WHERE loop_id='$1';"; }
( cmd_loop_spawn --agent=main --prompt="UNIQ_spendy" --ceiling=1000 --wait=20 >"$TMP"/loop-ceil.out 2>&1 ) &
bgpid=$!
if clid=$(poll_new "" loop_by_prompt UNIQ_spendy); then
  db "UPDATE loop_runs SET tokens_spent=5000 WHERE loop_id='$clid';"
else
  bad_t "ceiling halt setup" "poll_new timed out — the loop row never appeared, so the ceiling was never breached"
fi
wait $bgpid
cst=$(jq -r '.data.status' "$TMP"/loop-ceil.out 2>/dev/null)
chr=$(jq -r '.data.haltReason' "$TMP"/loop-ceil.out 2>/dev/null)
# status alone is NOT an assertion here (see above): assert the halt REASON.
[[ "$cst" == "escalated" && "$chr" == "ceiling" ]] \
  && ok_t "--wait halts on ceiling breach → escalated (haltReason=ceiling, not timeout)" \
  || bad_t "ceiling halt" "status=$cst haltReason=$chr $(cat "$TMP"/loop-ceil.out)"

# --- T6: --wait returns clean done + result passthrough
( cmd_loop_spawn --agent=main --prompt="UNIQ_finish" --wait=20 >"$TMP"/loop-done.out 2>&1 ) &
bgpid=$!
dtid=$(poll_new "" task_by_prompt UNIQ_finish)
db "UPDATE tasks SET status='done', result='shipped clean' WHERE id=$dtid;"
wait $bgpid
dst=$(jq -r '.data.status' "$TMP"/loop-done.out 2>/dev/null)
dres=$(jq -r '.data.result' "$TMP"/loop-done.out 2>/dev/null)
[[ "$dst" == "done" && "$dres" == "shipped clean" ]] \
  && ok_t "--wait → done with result passthrough" || bad_t "done passthrough" "$(cat "$TMP"/loop-done.out)"

echo "-----"; echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
