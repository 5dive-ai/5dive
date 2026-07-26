#!/usr/bin/env bash
# DIVE-1378: a maker→verifier dispatch is only "delivered" until the assigned
# verifier themselves starts it. That receiver action emits one durable ACK and
# advances the inspectable handoff state to "reviewing".
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/handoff-ack-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

tasks_db_init
out=$(USER=agent-maker cmd_task_add --assignee=maker --verifier=reviewer \
      --body="implement it" -- "handoff ACK fixture" 2>"$TMP/err")
tid=$(printf '%s' "$out" | jf '.data.id')

USER=agent-maker cmd_task_start "$tid" >/dev/null 2>"$TMP/err"
route=$(USER=agent-maker cmd_task_done "$tid" --result="ready" 2>"$TMP/err")
state=$(db "SELECT status||'|'||assignee||'|'||COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")
[[ "$state" == "todo|reviewer|" && "$(printf '%s' "$route" | jf '.data.handoff')" == "delivered" ]] \
  && ok_t "maker close emits delivered, not reviewing" \
  || bad_t "delivered state" "state=$state route=$route"

# Starting it as anyone except the assigned verifier must not forge the ACK.
third=$(USER=agent-intruder cmd_task_start "$tid" 2>"$TMP/err")
ack=$(db "SELECT COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")
[[ -z "$ack" && "$(printf '%s' "$third" | jf '.data.handoff // empty')" == "" ]] \
  && ok_t "third-party start cannot claim review began" \
  || bad_t "third-party ACK guard" "ack=$ack out=$third"

# The real receiver's start emits and persists the one ACK even if status was
# already moved to in_progress by the third-party call above.
review=$(USER=agent-reviewer cmd_task_start "$tid" 2>"$TMP/err")
ack=$(db "SELECT COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")
[[ -n "$ack" && "$(printf '%s' "$review" | jf '.data.handoff')" == "reviewing" ]] \
  && ok_t "assigned verifier start ACKs reviewing" \
  || bad_t "reviewing ACK" "ack=$ack out=$review"

board=$(USER=agent-reviewer cmd_task_loops 2>"$TMP/err")
[[ "$(printf '%s' "$board" | jf '.data.loops[0].handoff_state')" == "reviewing" && \
   "$(printf '%s' "$board" | jf '.data.loops[0].handoff_ack_at')" == "$ack" ]] \
  && ok_t "loop board exposes reviewing receipt" \
  || bad_t "loop board receipt" "$board"

USER=agent-reviewer cmd_task_assign "$tid" substitute >/dev/null 2>"$TMP/err"
reassigned=$(db "SELECT assignee||'|'||COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")
[[ "$reassigned" == "substitute|" ]] \
  && ok_t "reassignment clears stale receiver ACK" \
  || bad_t "reassignment ACK reset" "$reassigned"
USER=agent-substitute cmd_task_assign "$tid" reviewer >/dev/null 2>"$TMP/err"

# A rejection returns ownership and clears the prior ACK; the next maker close
# will create a fresh delivered handoff for the next review iteration.
USER=agent-reviewer cmd_task_reject "$tid" --feedback="revise" >/dev/null 2>"$TMP/err"
reset=$(db "SELECT assignee||'|'||COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")
[[ "$reset" == "maker|" ]] \
  && ok_t "reject clears ACK for the next handoff" \
  || bad_t "ACK reset" "$reset"

echo "-----"
echo "handoff_ack_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
