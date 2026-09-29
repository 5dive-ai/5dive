#!/usr/bin/env bash
# TIER: nightly — 135s measured on the control plane (thirteen full runs of task_rebalance_unit.sh): does not fit the 300s PR core; the nightly sweep runs it.
#
# DIVE-5191 mutation arms for tests/task_rebalance_unit.sh. Each guard in
# src/task/rebalance.sh is removed from a COPY of the module, and the core
# harness is run against that copy (REBAL_MODULE=). A guard whose removal leaves
# the core harness green is a guard nothing tests — that is the red here.
#
# Every mutant is `bash -n`-checked first: a mutant that does not parse would
# turn the harness red for the wrong reason and pass as a caught mutation. And an
# anchor that matches nothing is its own red, or the "mutant" grades the product
# against itself.
# Run: bash tests/task_rebalance_mutation_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/task-rebalance-mut.XXXXXX)"
MOD=src/task/rebalance.sh
CORE=tests/task_rebalance_unit.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The control: the unmutated module must be green, or every red below is noise.
if REBAL_MODULE="$MOD" bash "$CORE" >"$TMP/control.log" 2>&1; then
  ok_t "control: the core harness is green on the real module"
else
  bad_t "control: the core harness is RED on the real module — mutation results would mean nothing" "$(tail -5 "$TMP/control.log")"
  echo "PASS=${PASS} FAIL=${FAIL}"; exit 1
fi

mutate() {  # <label> <sed-expr>
  local m="$TMP/mut-$1.sh"
  sed -e "$2" "$MOD" >"$m"
  if cmp -s "$m" "$MOD"; then bad_t "M $1: the mutation anchor matched nothing" "$2"; return; fi
  bash -n "$m" 2>/dev/null || { bad_t "M $1: mutant does not parse" "$2"; return; }
  if REBAL_MODULE="$m" bash "$CORE" >"$TMP/mut-$1.log" 2>&1; then
    bad_t "M $1: core harness stayed GREEN with the guard removed" "$(tail -3 "$TMP/mut-$1.log")"
  else
    ok_t "M $1: core harness goes red without the guard ($(grep -c '^FAIL' "$TMP/mut-$1.log") arm(s))"
  fi
}

mutate headroom 's/if (( rc == 0 )); then printf/if true; then printf/'
mutate cap      's/(( moves < max_moves )) || break/: || break/'
mutate half     's/(( taken < total \/ 2 )) || break/: || break/'
mutate hold     's/(( now - held < _REBAL_HOLD_SEC ))/false/'
mutate pinned   's/if _rebal_pinned "$body" "$busy"; then/if false; then/'
mutate branch   's/grep -qxF -- "$b" <<<"$_REBAL_WIP_BRANCHES"/false/'
mutate started  's/\[\[ -z "$fsa" && -z "$sa" \]\]    ||/true ||/'
mutate gated    's/\[\[ -z "$gate" \]\]               ||/true ||/'
mutate dispatchable 's/if ! why=$(_rebal_dispatchable "$m"); then/if false; then/'
mutate parked   's/if _hb_agent_is_parked "$seat"; then/if false; then/'
mutate hboff    's/if \[\[ "$enabled" != "true" \]\]; then/if false; then/'
mutate guarded  's/WHERE id=${id} AND assignee=$(sqlq "$from") AND status=.todo./WHERE id=${id}/'

echo "---"
echo "PASS=${PASS} FAIL=${FAIL}"
(( FAIL == 0 ))
