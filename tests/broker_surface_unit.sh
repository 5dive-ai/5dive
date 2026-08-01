#!/usr/bin/env bash
# tests/broker_surface_unit.sh — INST-5.
#
# Two questions, and the first is the one that decides whether this refactor was
# safe to make at all.
#
# 1. IS THE PUSH PATH INERT? `_push_gate_check` and `_push_bind_branch` are the
#    predicates that stand between a granted agent and a git write. INST-5 moved
#    their bodies into lib/broker.sh and left one-line wrappers behind. "I only
#    parameterized the nouns" is exactly the claim that is cheap to assert and
#    expensive to be wrong about, so this file does not assert it — it MEASURES
#    it, differentially, against origin/main's own copies of those functions,
#    driving BOTH implementations through the same fixture states and comparing
#    the refusal text and the exit status byte for byte.
#
# 2. IS THE PARAMETERIZATION ACTUALLY LIVE? A differential test that passes
#    because both sides are equally dead is the standard way this shape lies. So
#    every string arm is paired with a liveness arm: the SAME predicate, on the
#    SAME state, under the `deploy` surface must say "deploy" where push says
#    "push" — and the case set must produce distinct messages, or the harness is
#    grading one sentence six times.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
want() { local n="$1"; shift; if eval "$@"; then echo "  ok   $n"; PASS=$((PASS+1)); else echo "  FAIL $n"; FAIL=$((FAIL+1)); fi; }
same() { # <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; PASS=$((PASS+1));
  else echo "  FAIL $1"; echo "    old: $2"; echo "    new: $3"; FAIL=$((FAIL+1)); fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- the baseline
# origin/main's copies, renamed so both live in one shell. If the baseline ref
# is unreachable the arms would silently become "compare new against nothing",
# which is the vacuous pass this file exists to avoid — so refuse instead.
BASE="${BROKER_BASELINE_REF:-origin/main}"
if ! git -C "$ROOT" cat-file -e "${BASE}:src/cmd_push.sh" 2>/dev/null; then
  echo "REFUSING: baseline ${BASE}:src/cmd_push.sh is unreachable — the differential arms cannot run."
  echo "  (fetch origin, or set BROKER_BASELINE_REF to a ref that predates INST-5)"
  exit 1
fi
git -C "$ROOT" show "${BASE}:src/cmd_push.sh" > "$TMP/base_push.sh"
# Guard the extraction itself: the baseline must actually still CONTAIN the
# pre-refactor bodies. If someone re-runs this after INST-5 has landed on the
# baseline ref, the "old" side becomes a wrapper too and every arm passes for
# the wrong reason.
grep -q 'gansweredat=\$(db' "$TMP/base_push.sh" \
  || { echo "REFUSING: ${BASE} already carries the refactored wrapper — nothing to differ against."; exit 1; }

extract() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p{print} p&&/^\}$/{exit}' "$TMP/base_push.sh"; }
{
  for fn in _push_gate_check _push_task_branch _push_bind_branch _push_branch_from_body; do
    extract "$fn"
  done
} | sed -E 's/(^|[^A-Za-z0-9_])_push_(gate_check|task_branch|bind_branch|branch_from_body)\b/\1old_push_\2/g' \
  > "$TMP/old.sh"
for fn in old_push_gate_check old_push_task_branch old_push_bind_branch old_push_branch_from_body; do
  grep -q "^${fn}() {" "$TMP/old.sh" || { echo "REFUSING: could not extract ${fn} from ${BASE}"; exit 1; }
done

# ------------------------------------------------------------------- the stubs
E_VALIDATION=2; E_USAGE=1; E_GENERIC=1; E_PERMISSION=3
warn() { printf 'warn: %s\n' "$*" >&2; }
fail() { printf '%s\n' "$2"; exit 9; }
# One fixture row, addressed by column name pulled out of the SQL. Both
# implementations issue the identical SELECTs, so one stub serves both.
declare -A ROW=()
db() {
  local col; col=$(sed -nE 's/.*COALESCE\(([a-z_]+),.*/\1/p' <<<"$1")
  printf '%s' "${ROW[$col]:-}"
}
_gate_closure_verify() { return "${CLOSURE_RC:-0}"; }
_gate_agent_for_uid()  { printf '%s' "${UID_AGENT:-}"; }

# shellcheck source=../src/lib/broker.sh
. "$ROOT/src/lib/broker.sh"
# shellcheck source=/dev/null
. "$TMP/old.sh"
# The new wrappers, taken from the real file rather than retyped here.
eval "$(awk '/^_push_gate_check\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"
eval "$(awk '/^_push_bind_branch\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"
eval "$(awk '/^_push_task_branch\(\) \{/,/^\}$/' "$ROOT/src/cmd_push.sh")"

run() { ( "$@" ) 2>/dev/null; printf 'rc=%s' "$?"; }

reset_row() { ROW=( [need_type]="" [need_answered_at]="" [need_answer]="" \
                    [need_answered_by]="" [need_answered_uid]="" [need_answer_sig]="" \
                    [routed_reviewer]="" [body]="" ); CLOSURE_RC=0; UID_AGENT=""; }

echo "== 1. the push path is INERT: new wrappers == origin/main, string for string"
declare -a SEEN=()
case_gate() { # <name> then the caller has already set ROW
  local n="$1" old new
  old=$(run old_push_gate_check 7 DIVE-7 "${2:-0}")
  new=$(run _push_gate_check     7 DIVE-7 "${2:-0}")
  same "gate/${n}" "$old" "$new"
  SEEN+=("$new")
}

reset_row;                                              case_gate "no gate at all"
reset_row; ROW[need_type]=approval;                     case_gate "gate OPEN (unanswered)"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]="no, not yet"
                                                        case_gate "gate REJECTED"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]=agent-dev; ROW[routed_reviewer]=main
                                                        case_gate "unauthorized, reviewer named"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]=agent-dev;              case_gate "unauthorized, no reviewer"
reset_row; ROW[need_type]=decision; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]=main; ROW[routed_reviewer]=main
           ROW[need_answered_uid]=1234567890; UID_AGENT=dev
                                                        case_gate "decision by reviewer, uid mismatch"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]="human:lodar";          case_gate "AUTHORIZED (human)"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]="lead:main";            case_gate "AUTHORIZED (lead)"
reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes
           ROW[need_answered_by]="human:lodar"; CLOSURE_RC=1
                                                        case_gate "signed-closure failure" 1

case_bind() { # <name> <branch-arg>
  local n="$1" b="$2" old new
  old=$(run old_push_bind_branch 7 DIVE-7 "$b")
  new=$(run _push_bind_branch     7 DIVE-7 "$b")
  same "bind/${n}" "$old" "$new"
  SEEN+=("$new")
}
reset_row;                                       case_bind "task declares no branch" feat/x
reset_row; ROW[body]=$'Branch: feat/a\n';        case_bind "branch mismatch"          feat/b
reset_row; ROW[body]=$'Branch: feat/a\n';        case_bind "branch matches"           feat/a
reset_row; ROW[body]=$'branch:   feat/a  \n';    case_bind "case+space insensitive"   feat/a

echo "-- non-vacuity: the arms above must not all be one sentence"
uniq_n=$(printf '%s\n' "${SEEN[@]}" | sort -u | wc -l)
want "the ${#SEEN[@]} differential arms produced >=8 distinct outcomes (got ${uniq_n})" "[[ $uniq_n -ge 8 ]]"
want "at least one arm SUCCEEDED (rc=0), so the harness can reach the pass path" \
     'printf "%s\n" "${SEEN[@]}" | grep -qx "rc=0"'
want "at least one arm REFUSED (rc=9), so the harness can reach the fail path" \
     'printf "%s\n" "${SEEN[@]}" | grep -q "^gate on\|^no gate on\|^task DIVE-7 declares"'

echo
echo "== 2. the parameterization is LIVE, not dead: deploy says deploy"
reset_row
d_nogate=$(run broker_gate_check deploy 7 DIVE-7)
p_nogate=$(run broker_gate_check push   7 DIVE-7)
want "deploy's no-gate refusal names deploy"  '[[ "$d_nogate" == *"deploy-for-review gate"* ]]'
want "push's no-gate refusal still names push" '[[ "$p_nogate" == *"push-for-review gate"* ]]'
want "the two differ (the surface argument is load-bearing)" '[[ "$d_nogate" != "$p_nogate" ]]'
want "deploy suggests its own --ask, not push's" \
     '[[ "$d_nogate" == *"approve production deploy of <project>@<ref>"* ]]'

reset_row; ROW[need_type]=approval; ROW[need_answered_at]=t; ROW[need_answer]=yes; ROW[need_answered_by]=agent-dev
d_unauth=$(run broker_gate_check deploy 7 DIVE-7)
want "deploy's unauthorized refusal says 'delegated deploy'" '[[ "$d_unauth" == *"delegated deploy accepts"* ]]'

echo
echo "== 3. deploy binds to ITS OWN body key, and a push task cannot satisfy it"
reset_row; ROW[body]=$'Branch: feat/a\nDeploy: app@feat/a\n'
want "deploy reads the Deploy: line"  '[[ "$(broker_task_target deploy 7)" == "app@feat/a" ]]'
want "push still reads the Branch: line" '[[ "$(broker_task_target push 7)" == "feat/a" ]]'
b_ok=$(run broker_bind_target deploy 7 DIVE-7 "app@feat/a")
b_no=$(run broker_bind_target deploy 7 DIVE-7 "other@feat/a")
want "the declared deploy target binds"  '[[ "$b_ok" == "rc=0" ]]'
want "a DIFFERENT project is refused"    '[[ "$b_no" == *"is not the deploy target bound to DIVE-7"* ]]'
want "…and the refusal cites the declared value, not the requested one" \
     '[[ "$b_no" == *"(&#39;app@feat/a&#39;)"* || "$b_no" == *"('"'"'app@feat/a'"'"')"* ]]'
reset_row; ROW[body]=$'Branch: feat/a\n'
b_unb=$(run broker_bind_target deploy 7 DIVE-7 "app@feat/a")
want "a task with ONLY a Branch: line cannot authorize a deploy" \
     '[[ "$b_unb" == *"declares no deploy target"* ]]'

echo
echo "== 4. an unknown surface is a hard failure, never an empty noun"
u=$(run broker_surface bananas noun)
want "unknown surface fails loudly" '[[ "$u" == *"unknown surface/field"* ]]'
# Subshell parens deliberate: `want` evals in THIS shell, so a bare `exit` here
# would end the harness with status 0 and skip the tally (see the same note in
# tests/capability_registry_unit.sh — it cost a vacuous mutation pass there).
want "every surface in broker_surfaces resolves every field" \
     '( for s in $(broker_surfaces); do for f in noun Noun cap verb key target ask ticket; do [[ -n "$(broker_surface "$s" "$f")" ]] || exit 1; done; done )'

# == 6. every consumer of the broker asserts the broker is LOADED (INST-5).
# The consumer list is DERIVED from the tree, never hand-written: a seventh
# surface folded in later gets swept automatically, which is the whole point —
# a hand list would go stale exactly when a new surface is added. A consumer
# that calls a broker predicate without require_loaded is the fail-open shape
# CI caught on this branch (push reporting "gate cleared" on an unread gate).
echo "== 6. brokered surfaces fail closed when lib/broker.sh is absent"
_consumers=$(grep -rlE '(^|[^_[:alnum:]])broker_(gate_check|bind_target|task_target)\b' \
               "$ROOT/src" --include='cmd_*.sh' | sort)
want "the derived consumer sweep is non-vacuous (found at least push + deploy)" \
     '[[ "$(printf "%s\n" "$_consumers" | grep -c .)" -ge 2 ]]'
for _c in $_consumers; do
  want "$(basename "$_c") guards its broker calls with require_loaded" \
       'grep -q "require_loaded" "$_c"'
done
# And the guard itself must live OUTSIDE lib/broker.sh — a check for a missing
# file cannot be defined in the file that might be missing.
want "require_loaded is not defined in lib/broker.sh" \
     '! grep -q "^require_loaded()" "$ROOT/src/lib/broker.sh"'
want "require_loaded is defined in header.sh (always first in the bundle)" \
     'grep -q "^require_loaded()" "$ROOT/src/header.sh"'

# == 7. no harness loads a broker CONSUMER without lib/broker.sh (INST-5).
# This is how the branch broke: tests/ harnesses hand-maintain a source list
# mirroring build.sh, and a new lib is invisible to every one of them. push_unit
# and gate_lead_standing failed loudly because they CALL cmd_push; 18 others
# sourced cmd_push.sh and stayed green only because they never called it —
# latent, and the next arm added to any of them would have graded through a
# missing predicate. Derived from the tree, so it also covers surface N+1.
echo "== 7. every harness sourcing a broker consumer also sources lib/broker.sh"
_bad=""
for _t in "$ROOT"/tests/*.sh; do
  awk '/for f in/,/; do/' "$_t" | grep -qE 'cmd_push\.sh|cmd_deploy\.sh' || continue
  grep -q 'lib/broker.sh' "$_t" || _bad="$_bad $(basename "$_t")"
done
want "no harness sources a broker consumer without lib/broker.sh" '[[ -z "$_bad" ]]'
[[ -n "$_bad" ]] && echo "    missing:$_bad"
# Non-vacuity: the sweep must actually be finding harnesses to check, or it
# passes by inspecting nothing — the exact way this check could rot silently.
_seen=$(for _t in "$ROOT"/tests/*.sh; do
          awk '/for f in/,/; do/' "$_t" | grep -qE 'cmd_push\.sh|cmd_deploy\.sh' && echo x
        done | grep -c x)
want "non-vacuity: the harness sweep inspected at least 15 harnesses (saw $_seen)" \
     '[[ "$_seen" -ge 15 ]]'

echo
echo "broker surface unit: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
