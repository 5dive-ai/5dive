#!/usr/bin/env bash
# DIVE-2063 + DIVE-2111 — the /goal nudge's maker→verifier terminal-state clause,
# BOTH halves of the rail.
#
# The wedge this covers: a /goal condition that accepts only done/cancelled/gated
# is UNSATISFIABLE by either role on a verifier-loop task, because each role has a
# correct action that reaches none of the three:
#   - maker: `task done` delivers (status stays todo, assignee moves to the
#     verifier)                                                      [DIVE-2063]
#   - verifier: `task reject` returns a FAIL verdict (status back to todo, assignee
#     back to the maker) — a complete terminal action, not a wedge   [DIVE-2111]
# The fix appends a clause naming the role's second terminal state — but ONLY where
# a loop genuinely exists, or it becomes the worse bug (any todo with a result
# counts as done).
#
# Asserts, over a throwaway TASKS_DB:
#   - maker on a live loop gets the maker clause, naming verifier, the handoff line
#     and its own maker line;
#   - verifier on a DELIVERED loop gets the verifier clause, naming `task reject`
#     as terminal plus the bounced-back state it produces;
#   - NO clause for a solo task, for the verifier BEFORE delivery, for a task owned
#     by someone else, or for a closed task; a non-numeric id is a silent no-op;
#   - LIVENESS (the one that matters): after a real `task done` handoff and after a
#     real `task reject`, a real `task show` actually PRINTS the state each clause
#     tells the agent to look for. Without this a clause could name an unreachable
#     string and re-wedge the session exactly as before, with every negative case
#     still green.
# Run: bash tests/heartbeat_goal_loop_terminal_unit.sh  (no root, no network).
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

TMP="$(mktemp -d /tmp/hb-goal-loop.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
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

# The verifier BEFORE any handoff: no maker_agent, so nothing has been delivered
# and they are just an ordinary owner — the reject verb itself would refuse here
# ("not in a maker→verifier loop (no maker to bounce to)"), so naming it would
# point the agent at a command the rail rejects.
grade=$(mk olivia olivia)
[[ -z "$(_hb_loop_terminal_clause olivia "$grade" "DIVE-$grade")" ]] \
  && ok_t "verifier pre-delivery (no maker_agent) => no clause" \
  || bad_t "verifier pre-delivery (no maker_agent) => no clause"

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

# ---- 4. DIVE-2111: the VERIFIER half, on the same live row -------------------
# $live is now genuinely delivered (maker=dev, assignee=verifier=olivia) — the
# exact state DIVE-2090 wedged in. Reuse it rather than hand-writing maker_agent,
# so the clause is keyed on a handoff the rail really produced.
v=$(_hb_loop_terminal_clause olivia "$live" "DIVE-$live")
if [[ -n "$v" ]]; then
  ok_t "verifier on a delivered loop => clause emitted"
else
  bad_t "verifier on a delivered loop => clause emitted" "got empty"
fi
[[ "$v" == *"task reject DIVE-$live"* ]] \
  && ok_t "verifier clause names 'task reject' as a terminal action" \
  || bad_t "verifier clause names 'task reject'" "got: $v"
[[ "$v" == *"maker: dev"* ]] \
  && ok_t "verifier clause names the maker it would bounce to" \
  || bad_t "verifier clause names the maker" "got: $v"
[[ "$v" == *"treat the goal as MET"* ]] \
  && ok_t "verifier clause declares reject terminal for the goal" \
  || bad_t "verifier clause declares reject terminal for the goal" "got: $v"
[[ "$v" == *"false record"* || "$v" == *"do not believe"* ]] \
  && ok_t "verifier clause forbids the false-record exits (done/cancel/gate)" \
  || bad_t "verifier clause forbids the false-record exits" "got: $v"
[[ "$v" != *$'\n'* && "${v:0:1}" == " " ]] \
  && ok_t "verifier clause is a single space-prefixed line" \
  || bad_t "verifier clause is a single space-prefixed line" "got: [$v]"
# A BYSTANDER who happens to share the verifier's wake: not the assignee.
[[ -z "$(_hb_loop_terminal_clause main "$live" "DIVE-$live")" ]] \
  && ok_t "bystander on a delivered loop => no clause" \
  || bad_t "bystander on a delivered loop => no clause"

# LIVENESS, verifier side: a real `task reject` must actually produce the state
# the clause tells the verifier to look for. Same trap as the maker side — the
# clause could name a string no verb emits and every assert above stays green.
task_actor() { echo olivia; }        # the verifier grades
rout=$(cmd_task_reject "$live" --feedback="PR unmergeable against moved main" 2>&1)
[[ "$rout" == *"bounced back to maker 'dev'"* ]] \
  && ok_t "liveness: verifier's 'task reject' bounces to the maker" \
  || bad_t "liveness: verifier's 'task reject' bounces to the maker" "got: $rout"
rst=$(db "SELECT status FROM tasks WHERE id=${live};")
[[ "$rst" == "todo" ]] \
  && ok_t "liveness: status stays todo after a reject (the wedge DIVE-2111 fixes)" \
  || bad_t "liveness: status stays todo after a reject" "got: $rst"
rshow=$(cmd_task_show "$live" 2>&1)
[[ "$rshow" == *"assignee = dev"* ]] \
  && ok_t "liveness: 'task show' prints the 'assignee = dev' the clause names" \
  || bad_t "liveness: 'task show' prints 'assignee = dev'" "got: $rshow"
# DIVE-2112 attributes the marker to the REAL actor, not to the recorded verifier —
# so the clause must name '❌ <woken agent> rejected'. Cross-check it against the
# clause text itself, not a hand-copied literal: that is what makes this assert
# fail when either side's wording drifts.
[[ "$rshow" == *"❌ olivia rejected"* ]] \
  && ok_t "liveness: 'task show' prints the rejection marker the clause names" \
  || bad_t "liveness: 'task show' prints the rejection marker" "got: $rshow"
[[ "$v" == *"❌ olivia rejected"* ]] \
  && ok_t "verifier clause quotes the marker verbatim as the rail emits it" \
  || bad_t "verifier clause quotes the marker verbatim" "got: $v"
# And after the bounce the row is the maker's again, so the VERIFIER's next wake
# gets nothing — the clause tracks who actually holds the handoff.
[[ -z "$(_hb_loop_terminal_clause olivia "$live" "DIVE-$live")" ]] \
  && ok_t "post-reject re-wake of the verifier => no clause" \
  || bad_t "post-reject re-wake of the verifier => no clause"

echo
printf 'tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
