#!/usr/bin/env bash
# DIVE-2063 — the /goal nudge's maker→verifier terminal-state clause.
#
# The wedge this covers: a /goal condition that accepts only done/cancelled/gated
# is UNSATISFIABLE by the maker of a verifier-loop task, because a correct
# `task done` delivers (status stays todo, assignee moves to the verifier). The
# fix appends a clause naming "delivered, awaiting ACK" as a second terminal
# state — but ONLY where a loop genuinely exists, or it becomes the worse bug
# (any todo with a result counts as done).
#
# Asserts, over a throwaway TASKS_DB:
#   - maker on a live loop gets the clause, naming verifier, the handoff line and
#     its own maker line;
#   - NO clause for a solo task, for the verifier's own wake, for a task owned by
#     someone else, or for a closed task; a non-numeric id is a silent no-op;
#   - LIVENESS (the one that matters): after a real `task done` handoff, a real
#     `task show` actually PRINTS the state the clause tells the agent to look
#     for. Without this the clause could name an unreachable string and re-wedge
#     the session exactly as before, with every negative case still green.
# Run: bash tests/heartbeat_goal_loop_terminal_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-goal-loop.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e   # header.sh enabled set -e; asserts below probe non-zero paths

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
JSON_MODE=0
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk() {  # mk <assignee> <verifier|""> [status]
  local asg="$1" vf="$2" st="${3:-todo}"
  db "INSERT INTO tasks (title,status,priority,assignee,created_by,kind,verifier)
        VALUES ('t','${st}','high',$(sqlq "$asg"),'main','standard',$(sqlq_or_null "$vf"));
      UPDATE tasks SET ident='DIVE-'||id WHERE id=last_insert_rowid();
      SELECT last_insert_rowid();"
}

# ---- 1. maker on a live loop: clause present and specific ---------------------
id=$(mk dev olivia)
c=$(_hb_loop_terminal_clause dev "$id" "DIVE-$id")
if [[ -n "$c" ]]; then
  ok_t "maker on live loop => clause emitted"
else
  bad_t "maker on live loop => clause emitted" "got empty"
fi
[[ "$c" == *"handoff: delivered (awaiting verifier ACK)"* ]] \
  && ok_t "clause names the handoff line to look for" \
  || bad_t "clause names the handoff line to look for" "got: $c"
[[ "$c" == *"maker: dev"* ]] \
  && ok_t "clause names the maker line (this agent)" \
  || bad_t "clause names the maker line" "got: $c"
[[ "$c" == *olivia* ]] \
  && ok_t "clause names the verifier" || bad_t "clause names the verifier" "got: $c"
[[ "$c" == *"Do NOT re-run"* ]] \
  && ok_t "clause forbids the second 'task done' bypass" \
  || bad_t "clause forbids the second 'task done' bypass" "got: $c"
[[ "$c" != *$'\n'* && "${c:0:1}" == " " ]] \
  && ok_t "clause is a single space-prefixed line (nudge stays one line)" \
  || bad_t "clause is a single space-prefixed line" "got: [$c]"

# ---- 2. the negatives: no clause where no maker-side loop exists --------------
solo=$(mk dev "")
[[ -z "$(_hb_loop_terminal_clause dev "$solo" "DIVE-$solo")" ]] \
  && ok_t "solo task (no verifier) => no clause" \
  || bad_t "solo task (no verifier) => no clause"

# The verifier's OWN wake: they are the one who must actually close it.
grade=$(mk olivia olivia)
[[ -z "$(_hb_loop_terminal_clause olivia "$grade" "DIVE-$grade")" ]] \
  && ok_t "verifier's own wake => no clause (their close IS terminal)" \
  || bad_t "verifier's own wake => no clause"

# A delivered task, woken for the verifier: assignee is olivia, not dev.
[[ -z "$(_hb_loop_terminal_clause dev "$grade" "DIVE-$grade")" ]] \
  && ok_t "task owned by another agent => no clause" \
  || bad_t "task owned by another agent => no clause"

closed=$(mk dev olivia done)
[[ -z "$(_hb_loop_terminal_clause dev "$closed" "DIVE-$closed")" ]] \
  && ok_t "closed task => no clause" || bad_t "closed task => no clause"

[[ -z "$(_hb_loop_terminal_clause dev "not-a-number" "DIVE-x")" ]] \
  && ok_t "non-numeric id => no clause, no error" \
  || bad_t "non-numeric id => no clause, no error"

[[ -z "$(_hb_loop_terminal_clause dev 999999 "DIVE-999999")" ]] \
  && ok_t "absent row => no clause, no error" || bad_t "absent row => no clause"

# ---- 3. LIVENESS: the state the clause names is one a real handoff produces ---
# Drive the real `task done` -> `task show` path. If `task show`'s wording ever
# drifts from the clause, this fails and the negatives above stay green — which
# is the whole point of asserting it here.
live=$(mk dev olivia)
task_actor() { echo dev; }           # the maker delivers
out=$(cmd_task_done "$live" --result="built and checked" 2>&1)
[[ "$out" == *"delivered to verifier"* ]] \
  && ok_t "liveness: maker's 'task done' delivers (does not close)" \
  || bad_t "liveness: maker's 'task done' delivers" "got: $out"
st=$(db "SELECT status FROM tasks WHERE id=${live};")
[[ "$st" == "todo" ]] && ok_t "liveness: status stays todo after delivery (the wedge)" \
  || bad_t "liveness: status stays todo after delivery" "got: $st"

show=$(cmd_task_show "$live" 2>&1)
clause=$(_hb_loop_terminal_clause dev "$live" "DIVE-$live")   # pre-delivery text
[[ "$show" == *"handoff: delivered (awaiting verifier ACK)"* ]] \
  && ok_t "liveness: 'task show' prints the handoff line the clause names" \
  || bad_t "liveness: 'task show' prints the handoff line" "got: $show"
[[ "$show" == *"maker: dev"* ]] \
  && ok_t "liveness: 'task show' prints 'maker: dev'" \
  || bad_t "liveness: 'task show' prints 'maker: dev'" "got: $show"
# Post-delivery the row belongs to the verifier, so a re-wake of the maker gets
# no clause — the goal is already met and the maker has nothing left to do.
[[ -z "$clause" ]] \
  && ok_t "post-delivery re-wake of the maker => no clause" \
  || bad_t "post-delivery re-wake of the maker => no clause" "got: $clause"

echo
printf 'tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
