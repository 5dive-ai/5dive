#!/usr/bin/env bash
# DIVE-3388 — token-burn leaks lodar measured 2026-08-14. Two of the three arms are
# ours to fix; this harness grades both fixes (the third arm, skill-text re-injection
# on the re-armed turn, is Claude Code per-turn context assembly, not 5dive code —
# recorded on the row, not testable here).
#
# ARM 1: `task ls/show --json` SELECTs every row's full body+result, so a single list
#   dumps hundreds of KB into an agent's context before any filtering is possible.
#   `--no-body` must strip body+result from every emitted row (ls) and from the task
#   object (show), and its ABSENCE must not change what the default path emits.
# ARM 2: `agent ask` waited the full --timeout even when the injected question never
#   landed (a delivery failure), surfacing only as a bare timeout. A delivery whose
#   marker never appears in the pane must now fail FAST (within --deliver-secs) with a
#   message that names it, and --deliver-secs=0 must restore the old wait-to-timeout.
#
# Run: bash tests/burn_leaks_no_body_ask_fastfail_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/burn-leaks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
audit_log() { :; }
_gate_history_summary_json() { printf '[]'; }   # show's JSON path only needs the shape

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ============================ ARM 1: --no-body ================================
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,body,result)
    VALUES ('DIVE-8101','t','high','dev','dev','standard','todo',
            'BODY-BODY-BODY-BODY','RESULT-RESULT-RESULT');"

# ls default keeps body+result (control — the flag must not change the default path)
out=$( (JSON_MODE=1 cmd_task_ls) 2>/dev/null )
printf '%s' "$out" | jq -e '.data.tasks[0].body == "BODY-BODY-BODY-BODY"' >/dev/null 2>&1 \
  && ok_t "task ls default still emits body" || bad_t "ls default body" "raw: [${out:0:160}]"

# ls --no-body strips body AND result from every row
out=$( (JSON_MODE=1 cmd_task_ls --no-body) 2>/dev/null )
printf '%s' "$out" | jq -e '.data.tasks[0] | (has("body")|not) and (has("result")|not)' >/dev/null 2>&1 \
  && ok_t "task ls --no-body strips body+result" || bad_t "ls --no-body" "raw: [${out:0:160}]"
# ...but keeps the rest of the row intact
printf '%s' "$out" | jq -e '.data.tasks[0].ident == "DIVE-8101" and .data.tasks[0].status == "todo"' >/dev/null 2>&1 \
  && ok_t "task ls --no-body keeps non-body fields" || bad_t "ls --no-body fields" "raw: [${out:0:160}]"

# show default keeps body (control)
out=$( (JSON_MODE=1 cmd_task_show DIVE-8101) 2>/dev/null )
printf '%s' "$out" | jq -e '.data.task.body == "BODY-BODY-BODY-BODY"' >/dev/null 2>&1 \
  && ok_t "task show default still emits body" || bad_t "show default body" "raw: [${out:0:160}]"

# show --no-body strips body+result
out=$( (JSON_MODE=1 cmd_task_show DIVE-8101 --no-body) 2>/dev/null )
printf '%s' "$out" | jq -e '.data.task | (has("body")|not) and (has("result")|not)' >/dev/null 2>&1 \
  && ok_t "task show --no-body strips body+result" || bad_t "show --no-body" "raw: [${out:0:160}]"
printf '%s' "$out" | jq -e '.data.task.ident == "DIVE-8101"' >/dev/null 2>&1 \
  && ok_t "task show --no-body keeps non-body fields" || bad_t "show --no-body fields" "raw: [${out:0:160}]"

# ====================== ARM 2: ask delivery fast-fail =========================
# Stub the world exactly like ask_cmd_wiring_unit.sh: nothing touches tmux/sudo/net.
JSON_MODE=0
MID="feed3388a"
FRAME_F="$TMP/frame_n"; echo 0 > "$FRAME_F"
# A pane of pure furniture: the injected question's id=<msg_id> marker NEVER appears.
_frame_nomark() { printf '%s\n' "  some TUI chrome" ">" "──────────"; }
sudo() {
  case "$*" in
    *"tmux has-session"*)  return 0 ;;
    *"tmux capture-pane"*) _frame_nomark ;;
    *)                     return 0 ;;
  esac
}
require_agent()             { :; }
wait_agent_input_ready()    { return 0; }
inject_and_submit()         { return 0; }
mirror_interagent_outbound(){ :; }
auto_sender_from_sudo()     { echo dev; }
gen_msg_id()                { echo "$MID"; }
step()                      { :; }
envelope_tier()             { echo admin; }
envelope_via()              { :; }
a2a_needs_scoped()          { return 1; }   # DIRECT branch (marker observable)

# A delivery failure must fail FAST (≈deliver-secs, not the full timeout) and NAME it.
t0=$(date +%s)
err=$(cmd_ask ada "ping" --from=dev --timeout=60 --deliver-secs=2 --idle-secs=1 --poll-secs=1 2>&1 >/dev/null)
rc=$?
t1=$(date +%s)
(( rc != 0 )) && ok_t "ask fast-fails a delivery failure (non-zero exit)" \
  || bad_t "ask should fail on undelivered question" "rc=$rc out-err: [${err:0:120}]"
[[ "$err" == *"delivery failure"* ]] && ok_t "the fast-fail names the delivery failure" \
  || bad_t "message should say delivery failure" "[${err:0:160}]"
(( t1 - t0 < 30 )) && ok_t "fast-fail returns well before the 60s timeout ($((t1-t0))s)" \
  || bad_t "fast-fail took too long" "$((t1-t0))s"

# --deliver-secs=0 restores the old wait-to-timeout behaviour (no fast-fail).
err=$(cmd_ask ada "ping" --from=dev --timeout=3 --deliver-secs=0 --idle-secs=1 --poll-secs=1 2>&1 >/dev/null)
rc=$?
(( rc != 0 )) && [[ "$err" == *"no idle reply"* ]] \
  && ok_t "--deliver-secs=0 disables the fast-fail (waits to the timeout)" \
  || bad_t "deliver-secs=0 should fall through to the timeout path" "rc=$rc [${err:0:160}]"

echo
if (( FAIL == 0 )); then
  echo "PASS — ${PASS} assertions (DIVE-3388 burn-leak fixes)"
else
  echo "FAILED — ${FAIL}/${PASS} assertions (DIVE-3388)"
  exit 1
fi
