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
# FOUR instances of the shape, not two. Iteration 1 claimed "exactly one other"
# and shipped a guard that could only see `[[ ]]` with a braced block; main2 found
# `(( n_unknown > 0 )) && echo ...` in cmd_usage_budget_check, which failed every
# HEALTHY heartbeat tick. The count was wrong because the instrument was narrow,
# so the guard below now finds the last statement STRUCTURALLY and is itself
# graded against that exact syntax by a positive control.
#   cmd_task_show          - the reported bug (rc 1 on any row with no dep edge)
#   usage_render_board     - bare `5dive usage` on the healthy no-overage path
#   cmd_usage_budget_check - LIVE CALLER: _hb_budget_sweep, every healthy tick (main2)
#   wt_task_num            - latent; both call sites assign plainly under set -e
# Plus the one unguarded `_gate_tier2_floor_term` assignment.
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
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
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
  bare=$(grep -nE '^\s*[A-Za-z_]+=\$\(_gate_tier2_floor_term ' "$SRC/cmd_task.sh" \
         | grep -v '|| *[A-Za-z_]*=""' )
  [[ -z "$bare" ]] && ok_t "no unguarded \$(_gate_tier2_floor_term) assignment remains" \
    || bad_t "unguarded floor-term assignment (dies under set -e when no term matches)" "$bare"
else
  bad_t "_gate_tier2_floor_term missing" "helper was renamed or removed"
fi

# ---- the structural detector, used by the three sections below ----
# Defined here because the budget-check arms grade it before the class guard runs.
cat > "$TMP/detect.awk" <<'AWK'
/^[a-zA-Z_][a-zA-Z0-9_]*[ \t]*\([ \t]*\)[ \t]*\{/ { fn=$0; sub(/[ \t]*\(.*/,"",fn); inf=1; n=0; next }
inf && /^\}/ {
  for (i=n; i>=1; i--) {
    l=buf[i]; s=l; gsub(/[ \t]/,"",s)
    if (s=="" || s ~ /^#/ || s=="fi" || s=="done" || s=="esac" || s=="else" || s==";;" || s=="}") continue
    # Must START a statement, or a jq continuation line and an `&&` inside an
    # awk program string both read as shell operators. A `||` fallback makes the
    # compound succeed regardless, so it is not this defect.
    if (l ~ /^[ \t]*(\[\[|\(\(|\[ |test |grep |declare )/ &&    \
        l ~ /&&/ && l !~ /\|\|/ &&                              \
        l ~ /&&[ \t]*[{(]?[ \t]*(echo|printf|cat |indent2)/ &&  \
        l !~ /return|exit/)
      print FILENAME":"lno[i]"  "fn
    break
  }
  inf=0; next
}
inf { n++; buf[n]=$0; lno[n]=FNR }
AWK

# ================= third instance: cmd_usage_budget_check (found by main2) ==========
# Executing it needs the whole usage plan, so grade it through the detector below
# instead — and grade it BY MUTATION, or this is just the guard agreeing with
# itself. Strip the fix from a COPY and the detector must name the function; with
# the fix in place it must not. The live-caller consequence is what made this the
# serious one: _hb_budget_sweep does `out=$(cmd_usage_budget_check) || return 1`,
# and the test is inverted relative to health, so a HEALTHY tick returned 1.
mkdir -p "$TMP/mut/lib"; : > "$TMP/mut/lib/empty.sh"
sed '/DIVE-2751 (found by main2 on iteration 1)/,/^  return 0$/d' "$SRC/cmd_usage.sh" > "$TMP/mut/cmd_usage.sh"
if ! cmp -s "$SRC/cmd_usage.sh" "$TMP/mut/cmd_usage.sh"; then
  ok_t "[budget-check] the mutation applied (fix removed from the copy)"
else
  bad_t "[budget-check] mutation did NOT apply — the arm below would prove nothing" "sed matched nothing"
fi
mut_hit=$(awk -f "$TMP/detect.awk" "$TMP/mut/cmd_usage.sh" "$TMP/mut"/lib/*.sh 2>/dev/null || true)
[[ "$mut_hit" == *cmd_usage_budget_check* ]] \
  && ok_t "[budget-check] detector names it once the fix is removed" \
  || bad_t "[budget-check] detector CANNOT see main2's instance" "hit=$mut_hit"
live_hit=$(awk -f "$TMP/detect.awk" "$SRC/cmd_usage.sh" 2>/dev/null || true)
[[ "$live_hit" != *cmd_usage_budget_check* ]] \
  && ok_t "[budget-check] fixed in the live tree" || bad_t "[budget-check] still live" "$live_hit"

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
# The bug is a shape, not a line, so this guard is what makes the class extinct
# rather than the three fixes above.
#
# ITERATION 1 SHIPPED A GUARD THAT COULD NOT SEE THE CLASS IT CLAIMED TO CLOSE.
# It grepped for `[[ ... ]] && { ...echo... }` — a bracket test AND a braced
# block — so `(( n_unknown > 0 )) && echo ...` was invisible, and that was a live
# third instance (cmd_usage_budget_check, failing every healthy heartbeat tick).
# main2 caught it. The lesson is not "add `((` to the regex": enumerating test
# syntaxes is how the first pattern went wrong. So this finds the last statement
# STRUCTURALLY — walk back from the function's closing brace, skipping blanks,
# comments and block closers — and only then asks whether that statement is a
# conditional with a printing side effect and no `||` fallback.
#
# Predicate functions ending in a bare test stay legitimately excluded: the
# signal is the PRINTING side effect, not the trailing test.
# Two DELIBERATE survivors, allow-listed by name with the reason, so the guard
# stays armed for anything new instead of being widened until it is quiet:
#   _gate_tier2_floor_term — value producer; rc 1 means "named no term". Contract
#     is intentional and every call site absorbs it (asserted above).
#   _compose_create_args   — its only caller reads it through a process
#     substitution (`mapfile -t args < <(...)`), where the rc never reaches
#     errexit. Fragile but not live; changing its contract is not this row's job.
offenders=$(awk -f "$TMP/detect.awk" "$SRC"/*.sh "$SRC"/lib/*.sh \
            | grep -vE '  (_gate_tier2_floor_term|_compose_create_args)$' || true)
[[ -z "$offenders" ]] && ok_t "no function ends in a trailing conditional render (class guard, structural)" \
  || bad_t "trailing conditional render is the last statement of a function" "$offenders"

# The guard must be able to SEE the shape that defeated iteration 1. A guard
# whose only evidence is its own silence is the thing this harness exists to
# refuse — so hand it that exact syntax and require it to fire.
mkdir -p "$TMP/canary/lib"
cat > "$TMP/canary/fixture.sh" <<'CANARY'
some_render() {
  local n=0
  (( n > 0 )) && echo "the unbraced arithmetic form that iteration 1 could not see"
}
CANARY
: > "$TMP/canary/lib/empty.sh"
canary=$(awk -f "$TMP/detect.awk" "$TMP/canary"/*.sh "$TMP/canary"/lib/*.sh || true)
[[ "$canary" == *some_render* ]] \
  && ok_t "class guard FIRES on the (( )) unbraced form (positive control)" \
  || bad_t "class guard is blind to the form that defeated iteration 1" "canary=$canary"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
