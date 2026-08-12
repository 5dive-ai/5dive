#!/usr/bin/env bash
# DIVE-2751 — `task show` EXIT CODE on a row with no dependency edge.
#
# The defect: the last statement of cmd_task_show's human branch was a bare
# conditional render,
#
#     [[ -n "$deps" ]] && { echo; echo "blocked by:"; ...; }
#
# so on a row with no `blocked by` edge the false test WAS the function's exit
# status, and `set -euo pipefail` killed the script — after the row had already
# printed in full. That is the majority of the board, and `5dive task show <id>`
# is the canonical verification command a /goal stop-hook is pointed at, so a
# correctly-rendered row read as a failed command whose trap then declared the
# effect UNKNOWN.
#
# WHY THIS HARNESS ASSERTS rc AND NOT TEXT: every arm below already printed its
# row on the broken build. A test that greps stdout passes on the bug. The whole
# defect lives in $?, so $? is the assertion — and each arm additionally proves
# the render did not go silent, because "return 0" would also be satisfied by a
# function that prints nothing.
#
# Arms: no-dep (the bug) / subtasks-but-no-dep / gate-but-no-dep / --json / and
# the WITH-dep control that was already green (so a fix that hard-codes rc=0
# without keeping the block is still distinguishable by its text assertion).
#
# NINE instances of the shape, not two. The count was wrong twice because the
# instrument was narrower than the class each time, and each miss was found by
# main2 re-deriving the sweep rather than reading the count:
#   iteration 1 guard: `[[ ]]` + a braced block -> blind to `(( )) && echo`
#   iteration 2 guard: the last PHYSICAL line   -> blind to a wrapped `&& printf \`
# So the guard no longer lives here as a regex. scripts/scan-trailing-conditional.sh
# joins continuations, walks back from the closing brace, follows a bare `return`
# to the statement whose $? it inherits, and decides by ELIMINATION rather than by
# listing printers. It is graded below by a control SET built from shapes that were
# not yet found when it was written, plus a negative control, because a guard whose
# only evidence is its own silence is what produced both wrong counts.
#   cmd_task_show          - the reported bug (rc 1 on any row with no dep edge)
#   usage_render_board     - bare `5dive usage` on the healthy no-overage path
#   cmd_usage_budget_check - LIVE CALLER: _hb_budget_sweep, every healthy tick (main2)
#   wt_task_num            - latent; both call sites assign plainly under set -e
#   cmd_project_show x2    - the early `return` that inherits $? from
#                            `(( n > 0 )) && printf` is LIVE (`5dive project show
#                            <a project with no dependency edge>`); the trailing
#                            wrapped `[[ ]] && printf \` is LATENT — see below
#   paperclip_seed_all_from_registry - LIVE: main.sh:738, bare, from update.sh
#   paperclip_unseed_for_profile     - same shape; caller absorbs with `|| true`
#   link_agent_profile               - latent at five bare call sites
# Plus TWO unguarded `_gate_tier2_floor_term` call sites, not one — the count was
# wrong a third time, and again because the instrument could not see the miss:
#   cmd_task_need Rule 3 - `local v; v=$(...)`, invisible to a grep anchored to the
#                          start of the line. Its ARGUMENT was also a phantom:
#                          `$_dd_residual` occurs exactly once in the repo, so the
#                          path died `unbound variable` under set -u regardless.
#   the `_fbt` assembly   - `[[ t ]] && v="...$(...)..."`; an assignment inherits
#                          its LAST command substitution, so the false rc arrives
#                          from the RHS where no left-side classifier can see it.
#
# Sources src/ against a throwaway tasks.db (same posture as
# project_show_graph_unit.sh) so it NEVER touches the shared queue.
# Run: bash tests/task_show_exit_code_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/taskshow-rc-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# show <ident> [json] -> sets $SHOW_RC and $SHOW_OUT.
#
# Sets globals rather than printing the rc: `rc=$(show ...)` would run the whole
# helper in a SUBSHELL and the captured stdout would never reach the parent,
# which silently turns every text assertion below into a no-op.
#
# The inner subshell re-enables `set -e` so this reproduces the REAL failure
# mode: not "the function returned 1" but "the script died before its next
# statement". The sentinel is the proof — on the broken build it never printed.
SHOW_OUT=""; SHOW_RC=""
show() {
  local ident="$1" jm="${2:-0}"
  SHOW_OUT=$( JSON_MODE="$jm"; set -euo pipefail; cmd_task_show "$ident" 2>&1; echo "__REACHED__" )
  SHOW_RC=$?
}
reached() { [[ "$SHOW_OUT" == *"__REACHED__"* ]]; }

# ---- seed rows directly (bypass the verbs so no gate/actor policy is involved) ----
mk() { # mk <title> -> global id
  db "INSERT INTO tasks (title, assignee, created_by, kind, status)
      VALUES ($(sqlq "$1"),'dev','dev','standard','todo');
      SELECT last_insert_rowid();"
}
ident_of() { db "SELECT ident FROM tasks WHERE id=$1;"; }

plain=$(mk "plain row, no deps no subtasks no gate")
blocker=$(mk "the blocker")
blocked=$(mk "row WITH a dependency edge")
parent=$(mk "row with subtasks but no dependency edge")
child=$(mk "the subtask")
gated=$(mk "row with a human gate but no dependency edge")

db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${blocked},${blocker});"
db "UPDATE tasks SET parent_id=${parent} WHERE id=${child};"
db "UPDATE tasks SET need_type='decision', ask='pick one', tier=1 WHERE id=${gated};"

I_PLAIN=$(ident_of "$plain"); I_BLOCKED=$(ident_of "$blocked")
I_PARENT=$(ident_of "$parent"); I_GATED=$(ident_of "$gated")

# ================= the reported bug =================
show "$I_PLAIN"
[[ "$SHOW_RC" == "0" ]] && ok_t "no-dep row: task show exits 0 (DIVE-2751)" \
  || bad_t "no-dep row exits $SHOW_RC" "$SHOW_OUT"
reached && ok_t "no-dep row: script survives past task show" \
  || bad_t "script died at task show on a no-dep row" "$SHOW_OUT"
[[ "$SHOW_OUT" == *"$I_PLAIN"* ]] && ok_t "no-dep row: still renders the row" \
  || bad_t "no-dep row rendered nothing" "$SHOW_OUT"

# ================= control: the shape that was already green =================
# Asserts BOTH halves — rc 0 AND the block still prints — so a "fix" that simply
# deleted the conditional render would fail here instead of passing everything.
show "$I_BLOCKED"
[[ "$SHOW_RC" == "0" ]] && ok_t "dep row: task show exits 0 (control)" \
  || bad_t "dep row exits $SHOW_RC" "$SHOW_OUT"
[[ "$SHOW_OUT" == *"blocked by:"* ]] && ok_t "dep row: 'blocked by:' block still rendered" \
  || bad_t "the blocked-by block stopped printing" "$SHOW_OUT"

# ================= the other no-dep shapes olivia measured =================
show "$I_PARENT"
[[ "$SHOW_RC" == "0" ]] && ok_t "subtasks-but-no-dep row: exits 0" || bad_t "subtask row exits $SHOW_RC" "$SHOW_OUT"
[[ "$SHOW_OUT" == *"subtasks:"* ]] && ok_t "subtasks-but-no-dep row: 'subtasks:' still rendered" \
  || bad_t "the subtasks block stopped printing" "$SHOW_OUT"

show "$I_GATED"
[[ "$SHOW_RC" == "0" ]] && ok_t "gated-but-no-dep row: exits 0" || bad_t "gated row exits $SHOW_RC" "$SHOW_OUT"
[[ "$SHOW_OUT" == *"human gate:"* ]] && ok_t "gated-but-no-dep row: 'human gate:' still rendered" \
  || bad_t "the gate block stopped printing" "$SHOW_OUT"

# ================= --json branch =================
show "$I_PLAIN" 1
[[ "$SHOW_RC" == "0" ]] && ok_t "no-dep row: --json exits 0" || bad_t "--json exits $SHOW_RC" "$SHOW_OUT"
printf '%s' "${SHOW_OUT%__REACHED__}" | jq -e '.ok==true and (.data.blocked_by|length)==0' >/dev/null 2>&1 \
  && ok_t "no-dep row: --json still emits ok envelope with blocked_by=[]" \
  || bad_t "--json envelope wrong" "$SHOW_OUT"

# ================= same shape, second site: usage_render_board (DIVE-2751) =================
# `5dive usage` (the default board render) exited 1 on the HEALTHY path — nobody
# over budget — for the identical reason. Sourced separately: cmd_usage.sh is not part of the task libs.
if source "$SRC/cmd_usage.sh" 2>/dev/null && declare -F usage_render_board >/dev/null; then
  uout=$( set -euo pipefail
          usage_render_board '{"agents":{},"tasks":{},"total":0}' 24h '{}' >/dev/null 2>&1
          echo "__REACHED__" )
  urc=$?
  [[ "$urc" == "0" ]] && ok_t "usage_render_board: exits 0 with no budget overage" \
    || bad_t "usage_render_board exits $urc with no overage" "$uout"
  [[ "$uout" == *"__REACHED__"* ]] && ok_t "usage_render_board: script survives past it" \
    || bad_t "script died in usage_render_board" "$uout"
else
  bad_t "usage_render_board not loadable" "cmd_usage.sh did not source, or the function is gone"
fi

# ================= same family: the unguarded floor-term assignment =================
# _gate_tier2_floor_term is itself trailing-test-terminated (rc 1 when it names
# no term) — that contract is deliberate and unchanged. What must not happen is a
# PLAIN assignment from it killing `task need` under set -e; the call site
# absorbs the status. Grade the call sites, not the helper.
if declare -F _gate_tier2_floor_term >/dev/null; then
  ft=$( set -euo pipefail
        v=$(_gate_tier2_floor_term "nothing in here trips any category floor") || v=""
        printf '%s' "__REACHED__${v}" )
  [[ "$ft" == *"__REACHED__"* ]] && ok_t "_gate_tier2_floor_term: absorbed rc does not kill set -e" \
    || bad_t "guarded floor-term call still died" "$ft"
  # The grep that used to live here is GONE, not tightened. It was anchored to
  # `^\s*VAR=$(...`, and that anchor is exactly why iteration 3's "every call site
  # absorbs it" was false: the Rule 3 site in `task need` is written
  # `local _dd_term; _dd_term=$(...)`, so what PRECEDED the assignment on the
  # physical line hid it — while a guarded site four lines away matched and the
  # test passed on zero hits. A statement is not a line, in either direction.
  # The claim is now checked by the same script that grants the exemption, in
  # --call-sites mode, graded by its own control set — see the class guard below.
  #
  # THE OTHER HALF of that miss was not an rc at all: the argument was
  # `$_dd_residual`, an identifier occurring EXACTLY ONCE in the repo, so it had
  # never held a value and the substitution died `unbound variable` under set -u
  # before absorption could matter. A read-once name in a `set -u` script is a
  # typo by construction, so this grades the class over the two paths touched
  # rather than the one name — and it is mutation-graded against the pre-fix file
  # in the control section below.
  # Whole-line comments are dropped first: a name in a comment cannot die under
  # set -u, and this file's own fix note names the phantom it removed.
  phantom=$(grep -vhE '^[[:space:]]*#' "$SRC/cmd_task.sh" "$SRC"/task/*.sh \
            | grep -ohE '\$\{?(_dd_|_ft_|_fbt)[a-zA-Z0-9_]*' \
            | sed -E 's/^\$\{?//' | sort -u \
            | while read -r v; do
                grep -qE "(^|[ \t;(&|])${v}=" "$SRC/cmd_task.sh" "$SRC"/task/*.sh || printf '%s\n' "$v"
              done)
  [[ -z "$phantom" ]] && ok_t "no read-once phantom identifier on the gate-term paths" \
    || bad_t "an identifier is READ but never assigned (dies 'unbound variable' under set -u)" "$phantom"
else
  bad_t "_gate_tier2_floor_term missing" "helper was renamed or removed"
fi

# ---- and the same path EXECUTED, not merely scanned ----
# main2 could only prove the Rule 3 defect statically: reaching it needs a floored
# gate, and they were not going to file one on the shared prod store to prove a
# point. This harness already owns a throwaway tasks.db, so it can just run it —
# a gate whose ask names money is floored, and --discusses asks to appeal that.
# On the pre-fix text this died `line 7385: _dd_residual: unbound variable` before
# the sentinel; the assertion is the sentinel PLUS the refusal actually naming its
# term, so a "fix" that silences the path without answering also fails here.
if declare -F cmd_task_need >/dev/null && declare -F _push_branch_from_body >/dev/null; then
  r3id=$(mk "probe row for the rule 3 appeal path")
  r3=$(ident_of "$r3id")
  r3out=$( set -euo pipefail
           cmd_task_need "$r3" --type=decision \
             --ask="approve a \$500 spend on the ads account" \
             --discusses="this is a design discussion, not a spend" 2>&1
           echo "__REACHED__" )
  [[ "$r3out" == *"__REACHED__"* ]] && ok_t "task need --discusses on a floored gate survives Rule 3 (executed)" \
    || bad_t "Rule 3 path still dies before the next statement" "$r3out"
  [[ "$r3out" == *"--discusses REFUSED"* && "$r3out" == *"matched '"*"'"* ]] \
    && ok_t "Rule 3 refusal renders and NAMES the surviving term" \
    || bad_t "Rule 3 refusal did not name its term (a silent fix passes the rc arm alone)" "$r3out"
else
  bad_t "Rule 3 arm not runnable" "cmd_task_need or _push_branch_from_body did not source"
fi

# ================= fifth+sixth instance: cmd_project_show (found by main2) ==========
# The sibling of the command in this row's title. TWO sites in one function, and
# they are NOT equally live — say which is which, because "both are live" is the
# same kind of unchecked claim as the wrong counts:
#   - the EARLY bare `return` inheriting $? from `(( n > 0 )) && printf` is LIVE:
#     `5dive project show <a project with no dependency edge>` rendered in full
#     and then printed the identical "exited 1 without reporting a reason" trap.
#     Measured on the installed CLI before the fix, rc 0 after. Executed below.
#   - the trailing `[[ -n "$chain" ]] && printf ... \` wrapped onto a continuation
#     line — the shape that defeated the iteration-2 detector — is LATENT: it is
#     only reached when edges > 0, and every graph with an edge that I could
#     construct yields a non-empty critical chain, so the test is true. It is
#     graded by mutation and by the detector, NOT by execution, and this note is
#     what makes that gap refutable rather than invisible.
if source "$SRC/cmd_org.sh" 2>/dev/null && source "$SRC/cmd_project.sh" 2>/dev/null \
   && declare -F cmd_project_show >/dev/null; then
  db "INSERT INTO projects (key, prefix, name) VALUES ('empty','EMP','Empty');
      INSERT INTO projects (key, prefix, name) VALUES ('flat','FLT','Flat');
      INSERT INTO projects (key, prefix, name) VALUES ('dag','DAG','Dag');"
  pshow() { # -> PS_OUT / PS_RC
    PS_OUT=$( JSON_MODE=0; set -euo pipefail; cmd_project_show "$1" 2>&1; echo "__REACHED__" )
    PS_RC=$?
  }
  # (a) zero tasks: `(( n > 0 ))` is false, so the bare `return` returned 1.
  pshow empty
  [[ "$PS_RC" == "0" ]] && ok_t "[project show] zero-task project exits 0 (early bare return)" \
    || bad_t "[project show] zero-task project exits $PS_RC" "$PS_OUT"
  [[ "$PS_OUT" == *"__REACHED__"* ]] && ok_t "[project show] script survives the early-return path" \
    || bad_t "[project show] script died on the early-return path" "$PS_OUT"

  # (b) tasks but no edges: the `(( n > 0 ))` block MUST still print, or `return 0`
  #     would be satisfied by a function that silently stopped rendering.
  f1=$(db "INSERT INTO tasks (title, assignee, created_by, project_key, kind, status)
           VALUES ('flat one','dev','dev','flat','standard','todo');
           SELECT last_insert_rowid();")
  pshow flat
  [[ "$PS_RC" == "0" ]] && ok_t "[project show] no-edge project exits 0" \
    || bad_t "[project show] no-edge project exits $PS_RC" "$PS_OUT"
  [[ "$PS_OUT" == *"no task_deps recorded"* ]] \
    && ok_t "[project show] the no-deps line still renders" \
    || bad_t "[project show] the no-deps line stopped printing" "$PS_OUT"

  # (c) control — a project WITH an edge reaches the trailing wrapped conditional
  #     and must both exit 0 and still print the Critical path line.
  d1=$(db "INSERT INTO tasks (title, assignee, created_by, project_key, kind, status)
           VALUES ('dag blocker','dev','dev','dag','standard','todo');
           SELECT last_insert_rowid();")
  d2=$(db "INSERT INTO tasks (title, assignee, created_by, project_key, kind, status)
           VALUES ('dag blocked','dev','dev','dag','standard','todo');
           SELECT last_insert_rowid();")
  db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${d2},${d1});"
  pshow dag
  [[ "$PS_RC" == "0" ]] && ok_t "[project show] project WITH an edge exits 0 (control)" \
    || bad_t "[project show] dep project exits $PS_RC" "$PS_OUT"
  [[ "$PS_OUT" == *"Critical path:"* ]] \
    && ok_t "[project show] the Critical path line still renders (control)" \
    || bad_t "[project show] the Critical path line stopped printing" "$PS_OUT"
else
  bad_t "[project show] not loadable" "cmd_project.sh did not source, or cmd_project_show is gone"
fi

# ---- the structural detector ----
# scripts/scan-trailing-conditional.sh. Exit 0 = clean, 1 = offenders on stdout,
# 2 = could not scan (never a pass — a scanner that cannot run must not read as
# silence, which is the failure this whole row is about).
SCAN="scripts/scan-trailing-conditional.sh"
scan() { bash "$SCAN" "$@"; }   # rc 1 is a normal "found something" here

if [[ -x "$SCAN" || -r "$SCAN" ]]; then
  ok_t "detector present ($SCAN)"
else
  bad_t "detector missing" "$SCAN is not readable — every arm below would read as clean"
fi

# ================= third instance: cmd_usage_budget_check (found by main2) ==========
# Executing it needs the whole usage plan, so grade it through the detector below
# instead — and grade it BY MUTATION, or this is just the guard agreeing with
# itself. Strip the fix from a COPY and the detector must name the function; with
# the fix in place it must not. The live-caller consequence is what made this the
# serious one: _hb_budget_sweep does `out=$(cmd_usage_budget_check) || return 1`,
# and the test is inverted relative to health, so a HEALTHY tick returned 1.
mkdir -p "$TMP/mut"
sed '/DIVE-2751 (found by main2 on iteration 1)/,/^  return 0$/d' "$SRC/cmd_usage.sh" > "$TMP/mut/cmd_usage.sh"
if ! cmp -s "$SRC/cmd_usage.sh" "$TMP/mut/cmd_usage.sh"; then
  ok_t "[budget-check] the mutation applied (fix removed from the copy)"
else
  bad_t "[budget-check] mutation did NOT apply — the arm below would prove nothing" "sed matched nothing"
fi
mut_hit=$(scan "$TMP/mut/cmd_usage.sh" 2>&1)
[[ "$mut_hit" == *cmd_usage_budget_check* ]] \
  && ok_t "[budget-check] detector names it once the fix is removed" \
  || bad_t "[budget-check] detector CANNOT see main2's instance" "hit=$mut_hit"
live_hit=$(scan "$SRC/cmd_usage.sh" 2>&1)
[[ "$live_hit" != *cmd_usage_budget_check* ]] \
  && ok_t "[budget-check] fixed in the live tree" || bad_t "[budget-check] still live" "$live_hit"

# Same mutation grade for the two cmd_project_show sites main2 found on iteration
# 2 — strip each `return 0` from a COPY and the detector must name the function
# for BOTH reasons (the wrapped trailing conditional, and the bare early return).
sed -e 's|^    return 0   # DIVE-2751: a BARE.*|    return|' \
    -e '/# project with zero tasks rendered in full/d' \
    "$SRC/cmd_project.sh" > "$TMP/mut/cmd_project_a.sh"
sed '/DIVE-2751: a render that reached the end succeeded/,+1d; /^  return 0   #/d' \
    "$SRC/cmd_project.sh" > "$TMP/mut/cmd_project_b.sh"
for pair in "a:bare return inherits this" "b:function rc"; do
  m="${pair%%:*}"; why="${pair#*:}"
  if cmp -s "$SRC/cmd_project.sh" "$TMP/mut/cmd_project_$m.sh"; then
    bad_t "[project show/$m] mutation did NOT apply" "sed matched nothing"
  else
    ok_t "[project show/$m] the mutation applied"
  fi
  hit=$(scan "$TMP/mut/cmd_project_$m.sh" 2>&1)
  [[ "$hit" == *cmd_project_show* && "$hit" == *"$why"* ]] \
    && ok_t "[project show/$m] detector names it as '$why' once the fix is removed" \
    || bad_t "[project show/$m] detector cannot see it" "hit=$hit"
done
live_hit=$(scan "$SRC/cmd_project.sh" 2>&1)
[[ "$live_hit" != *cmd_project_show* ]] \
  && ok_t "[project show] fixed in the live tree" || bad_t "[project show] still live" "$live_hit"

# ================= fourth instance: wt_task_num (latent, worktree reclaim) ==========
# Cheap to execute, so execute it. A non-numeric ident must report "no number" as
# EMPTY OUTPUT, not as a failure — cmd_task.sh:199's `[[ -n "$num" ]] || return 0`
# is proof the empty case was meant to be handled, and errexit killed the caller
# before that guard could run.
if source "$SRC/lib/disk.sh" 2>/dev/null && declare -F wt_task_num >/dev/null; then
  wtout=$( set -euo pipefail; v=$(wt_task_num "not-a-number-xyz"); printf 'REACHED[%s]' "$v" )
  [[ "$wtout" == "REACHED[]" ]] \
    && ok_t "[wt_task_num] non-numeric ident yields empty output, rc 0 (caller survives set -e)" \
    || bad_t "[wt_task_num] non-numeric ident still kills the caller" "got='$wtout'"
  wtok=$( set -euo pipefail; v=$(wt_task_num "DIVE-2751"); printf '%s' "$v" )
  [[ "$wtok" == "2751" ]] && ok_t "[wt_task_num] still extracts the number (not silenced)" \
    || bad_t "[wt_task_num] stopped returning the number" "got='$wtok'"
else
  bad_t "[wt_task_num] not loadable" "src/lib/disk.sh did not source"
fi

# ================= class guard: no NEW trailing conditional render =================
# The bug is a shape, not a line, so the sweep — not the nine fixes — is what
# closes the class. What this guard does NOT claim is that the class is extinct:
# two iterations made exactly that claim in the same change that shipped a blind
# instrument, so the claim is now the control set below, not a comment.
#
# The deliberate survivors are named in the script's ALLOWLIST with their reasons
# (_gate_tier2_floor_term, _compose_create_args, _gate_anon_ok) so the guard stays
# armed for anything new instead of being widened until it goes quiet.
offenders=$(scan 2>&1)
[[ -z "$offenders" ]] && ok_t "no function's rc is supplied by a false-able conditional (class guard)" \
  || bad_t "a conditional that may be false supplies a function's exit status" "$offenders"

# ---- the control SET ----
# The recurring failure is a detector whose only evidence of completeness is its
# own silence on the instances already known. So it is handed a set built from
# the shapes that were NOT yet found when each earlier version was written — one
# fixture per shape, each of which must be named — plus negative controls that
# must NOT be named, so "widen it until it is quiet" also fails.
mkdir -p "$TMP/ctl"
cat > "$TMP/ctl/positive.sh" <<'CTL'
arith_unbraced() {          # defeated iteration 1: (( )) with no braced block
  local n=0
  (( n > 0 )) && echo "unseen by a [[ ]]-plus-brace pattern"
}
wrapped_printf() {          # defeated iteration 2: the central [[ ]] && printf form,
  local chain=""            # wrapped, so the last PHYSICAL line is not the statement
  [[ -n "$chain" ]] && printf 'Critical path: %s (%s)\n' \
    "$chain" "1"
}
early_bare_return() {       # unreachable by any walk-back from the closing brace
  local n=0
  if true; then
    (( n > 0 )) && printf 'nothing to graph\n'
    return
  fi
  printf 'graph\n'
}
trailing_loop() {           # a for-loop returns its LAST iteration's status
  local t p
  for t in a b c; do
    p=""
    [[ -n "$p" ]] && seed_it "$t" "$p"
  done
}
CTL
cat > "$TMP/ctl/negative.sh" <<'CTL'
pure_predicate() {          # && lives INSIDE the test — rc IS the contract
  [[ -n "$1" && "$1" == "$2" ]]
}
test_consequent() {         # consequent is only another test, so still a predicate
  [ -r "$1" ] && [ -s "$1" ]
}
has_fallback() {            # a || fallback makes the compound always succeed
  [[ -n "$1" ]] && printf '%s\n' "$1" || printf 'none\n'
}
pipeline_tail() {           # rc comes from the pipe's tail, not the conditional
  { [[ -n "$1" ]] && printf '%s\n' "$1"; printf 'x\n'; } | cat
}
states_its_status() {       # the status is stated explicitly on the line
  [[ -n "$1" ]] && printf '%s\n' "$1"; return 0
}
CTL
pos=$(scan "$TMP/ctl/positive.sh" 2>&1)
for shape in arith_unbraced wrapped_printf early_bare_return trailing_loop; do
  [[ "$pos" == *"$shape"* ]] && ok_t "detector FIRES on $shape (positive control)" \
    || bad_t "detector is BLIND to $shape" "$pos"
done
neg=$(scan "$TMP/ctl/negative.sh" 2>&1)
[[ -z "$neg" ]] && ok_t "detector stays silent on all five predicate/absorbed shapes (negative control)" \
  || bad_t "detector fires on a legitimate contract — it would be widened-then-muted" "$neg"

# A scanner that cannot run must not read as clean: exit 2, never 0.
unreadable=$(scan "$TMP/ctl/does-not-exist.sh" 2>/dev/null; echo "rc=$?")
[[ "$unreadable" == *"rc=2"* ]] && ok_t "unscannable input exits 2, not 0 (silence is not a pass)" \
  || bad_t "scanner reported clean on input it could not read" "$unreadable"

# ============ call-site guard: the ALLOWLIST's own justification ============
# Iterations 1 and 2 leaked through a blind DETECTOR. Iteration 3's detector was
# sound and the leak moved one level out, into the three allowlist entries' REASON
# — "every call site absorbs it", checked by exactly the kind of prefix regex the
# detector had been rewritten to stop using. An exemption is only as good as its
# justification, so the justification is a guard now, not prose.
unabsorbed=$(scan --call-sites 2>&1)
[[ -z "$unabsorbed" ]] && ok_t "every allowlisted rc-bearing call absorbs its status (call-site guard)" \
  || bad_t "an allowlisted contract's rc reaches a plain assignment (dies under set -e)" "$unabsorbed"

# ---- control SET for the call-site guard ----
# Same rule as above: the positives are the shapes the REPLACED grep could not
# see, so "it is quiet" cannot be the evidence.
cat > "$TMP/ctl/cs-positive.sh" <<'CTL'
same_line_local() {         # the actual escapee: prefix-blind, not shape-blind
  local _dd_term; _dd_term=$(_gate_tier2_floor_term "$1")
  printf '%s\n' "$_dd_term"
}
rhs_substitution() {        # rc arrives from the RHS — invisible to any detector
  local _fbt=""             # that classifies the LEFT side of &&
  _fbt=" matched '$(_gate_tier2_floor_term "$1")' in the title"
  printf '%s\n' "$_fbt"
}
conditional_assign() {      # test TRUE, assignment still hands over the call's rc
  local _cav=""
  [[ -n "$1" ]] && _cav=$(_gate_tier2_floor_term "$1")
  printf '%s\n' "$_cav"
}
wrapped_assign() {          # the statement continues onto the next physical line
  local _wav=""
  _wav=$(_gate_tier2_floor_term \
      "$1")
  printf '%s\n' "$_wav"
}
CTL
cat > "$TMP/ctl/cs-negative.sh" <<'CTL'
absorbed() {                # the documented contract
  local v; v=$(_gate_tier2_floor_term "$1") || v=""
  printf '%s\n' "$v"
}
as_argument() {             # rc goes to printf, not to this statement
  printf 'matched %s\n' "$(_gate_tier2_floor_term "$1")"
}
in_condition() {            # rc is the test's, not the call's
  if [[ -n "$(_gate_tier2_floor_term "$1")" ]]; then printf 'hit\n'; fi
}
builtin_prefix() {          # `local` returns the BUILTIN's status, which is 0
  local v=$(_gate_tier2_floor_term "$1")
  printf '%s\n' "$v"
}
CTL
cspos=$(scan --call-sites "$TMP/ctl/cs-positive.sh" 2>&1)
for shape in same_line_local rhs_substitution conditional_assign wrapped_assign; do
  case "$shape" in
    same_line_local)    probe='_dd_term=$(' ;;
    rhs_substitution)   probe='_fbt=" matched' ;;
    conditional_assign) probe='_cav=$(' ;;
    wrapped_assign)     probe='_wav=$(' ;;
  esac
  [[ "$cspos" == *"$probe"* ]] && ok_t "call-site guard FIRES on $shape (positive control)" \
    || bad_t "call-site guard is BLIND to $shape" "$cspos"
done
csneg=$(scan --call-sites "$TMP/ctl/cs-negative.sh" 2>&1)
[[ -z "$csneg" ]] && ok_t "call-site guard stays silent on all four absorbing shapes (negative control)" \
  || bad_t "call-site guard fires on an absorbed call — it would be widened-then-muted" "$csneg"

# ---- mutation control for the phantom-identifier arm ----
# The arm above is a regex, and a regex that has only ever been run on a CLEAN
# file has not been shown to fire. Hand it the pre-fix text.
mkdir -p "$TMP/ctl/pre"
{ printf 'phantom_arg() {\n  local _dd_res_ask=""\n'
  printf '  local _dd_term; _dd_term=$(_gate_tier2_floor_term "$_dd_residual")\n'
  printf '  printf %s "$_dd_term" "$_dd_res_ask"\n' "'%s%s\\n'"
  printf '}\n'; } > "$TMP/ctl/pre/cmd_task.sh"
premiss=$(grep -ohE '\$\{?(_dd_|_ft_|_fbt)[a-zA-Z0-9_]*' "$TMP/ctl/pre/cmd_task.sh" \
          | sed -E 's/^\$\{?//' | sort -u \
          | while read -r v; do
              grep -qE "(^|[ \t;(&|])${v}=" "$TMP/ctl/pre/cmd_task.sh" || printf '%s\n' "$v"
            done)
[[ "$premiss" == *"_dd_residual"* ]] && ok_t "phantom-identifier arm FIRES on the pre-fix text (mutation control)" \
  || bad_t "phantom-identifier arm cannot see the defect it was written for" "got='$premiss'"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
