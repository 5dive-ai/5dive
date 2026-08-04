#!/usr/bin/env bash
# DIVE-2211 -- the helper that makes every other harness name the tree it grades.
#
# This is the one file in the corpus whose subject IS tests/lib/grading_tree.sh,
# so it is where that helper's three outcomes get graded.  The contract test
# (tests/names_the_tree_contract_unit.sh) only establishes that every harness
# SOURCES the helper; it credits nothing about what the helper emits.  This file
# is the other half, and the two are only sound together.
#
# Every case below runs the helper in a REAL directory of the shape it claims to
# handle -- a clean repo, a dirty repo, a non-repo -- rather than stubbing git.
# A stubbed observable would make these vacuously green.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

# shellcheck source=lib/grading_tree.sh
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

TMP="$(mktemp -d /tmp/grading-tree.XXXXXX)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nok()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
like() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else nok "$1 (got: $2)"; fi; }
unlike(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else nok "$1 (got: $2)"; fi; }

# Stand up a throwaway tree shaped like the repo: <root>/tests/lib/grading_tree.sh
# plus src/, because the helper diffs `-- src tests`.
mk() {
  local root="$1"
  mkdir -p "$root/tests/lib" "$root/src"
  cp tests/lib/grading_tree.sh "$root/tests/lib/grading_tree.sh"
  printf 'seed\n' > "$root/src/thing.sh"
}

# Run the helper out of a given root, in a clean subshell, and hand back stderr.
run_in() {
  ( unset _5D_GRADING_TREE_PRINTED
    . "$1/tests/lib/grading_tree.sh" ) 2>&1 >/dev/null
}

# ---- 1. not a git tree at all --------------------------------------------
NOGIT="$TMP/nogit"; mk "$NOGIT"
out="$(run_in "$NOGIT")"
like   "no-git: names the resolved root"            "$out" "$NOGIT"
like   "no-git: says NOT-A-GIT-TREE"                "$out" "NOT-A-GIT-TREE"
# The DIVE-1921 regression, and the reason this assertion is on ABSENCE and not
# just on the value: the first version of that line printed "NOT-A-GIT-TREE
# +UNCOMMITTED CHANGES" -- a dirtiness verdict from a check that could not run.
unlike "no-git: makes NO dirtiness claim"           "$out" "UNCOMMITTED"
unlike "no-git: does not claim clean either"        "$out" "CLEAN"

# ---- 2. clean git tree ----------------------------------------------------
CLEAN="$TMP/clean"; mk "$CLEAN"
git -C "$CLEAN" init -q 2>/dev/null
git -C "$CLEAN" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$CLEAN" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
csha="$(git -C "$CLEAN" rev-parse --short HEAD)"
out="$(run_in "$CLEAN")"
like   "clean: prints the actual HEAD sha"          "$out" "@ $csha"
unlike "clean: no uncommitted-changes label"        "$out" "UNCOMMITTED"
unlike "clean: no unknown-dirtiness label"          "$out" "UNKNOWN"

# ---- 3. dirty (UNSTAGED) --------------------------------------------------
DIRTY="$TMP/dirty"; mk "$DIRTY"
git -C "$DIRTY" init -q 2>/dev/null
git -C "$DIRTY" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$DIRTY" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
printf 'edited\n' >> "$DIRTY/src/thing.sh"
out="$(run_in "$DIRTY")"
like   "dirty-unstaged: flags uncommitted changes"  "$out" "UNCOMMITTED CHANGES"

# ---- 4. dirty (STAGED) -- the whole reason it is `diff --quiet HEAD` ------
# A bare `git diff --quiet` compares against the INDEX, so `git add` makes a
# real, uncommitted change report CLEAN.  This case is the graded difference
# between the two spellings; without it the file passes with the wrong one.
STAGED="$TMP/staged"; mk "$STAGED"
git -C "$STAGED" init -q 2>/dev/null
git -C "$STAGED" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$STAGED" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
printf 'edited\n' >> "$STAGED/src/thing.sh"
git -C "$STAGED" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
out="$(run_in "$STAGED")"
like   "dirty-STAGED: still flags uncommitted"      "$out" "UNCOMMITTED CHANGES"

# ---- 5. print-once guard --------------------------------------------------
# Sourcing twice in one process must emit one line, or a harness that pulls the
# helper in transitively doubles it and the log stops being readable.
twice="$( ( unset _5D_GRADING_TREE_PRINTED
            . "$CLEAN/tests/lib/grading_tree.sh"
            . "$CLEAN/tests/lib/grading_tree.sh" ) 2>&1 >/dev/null | grep -c 'grading tree:' )"
if [[ "$twice" == "1" ]]; then ok "sourced twice emits exactly one line"
else nok "sourced twice emitted $twice lines (want 1)"; fi

# ---- 6. it goes to STDERR, not stdout ------------------------------------
# Load-bearing: a harness's stdout can be its output contract, and a control
# that corrupts what it grades reds for the wrong reason.
so="$( ( unset _5D_GRADING_TREE_PRINTED; . "$CLEAN/tests/lib/grading_tree.sh" ) 2>/dev/null )"
unlike "the line does not go to stdout"             "$so" "grading tree:"

# ---- 7. survives set -e / set -u in the caller ---------------------------
if ( set -euo pipefail
     unset _5D_GRADING_TREE_PRINTED
     . "$NOGIT/tests/lib/grading_tree.sh" ) >/dev/null 2>&1; then
  ok "sourcing under set -euo pipefail does not kill the caller"
else
  nok "sourcing under set -euo pipefail returned nonzero"
fi

# ---- 8. END TO END: a REAL corpus harness emits the line ------------------
# The case that was missing, and its absence cost the whole change. Case 1-7
# source the helper DIRECTLY; the contract test credits only the presence of a
# source LINE. Neither exercises the call site as it appears in a harness -- so
# a `2>/dev/null` added to that line to hide bash's "No such file" swallowed the
# helper's stderr, silenced all 210 harnesses, and every other check stayed
# green. Grade the seam, not just the two things it joins.
e2e="$(bash tests/names_the_tree_contract_unit.sh 2>&1 >/dev/null | grep -c 'grading tree:')"
if [[ "$e2e" == "1" ]]; then ok "a real harness emits exactly one grading-tree line on stderr"
else nok "a real harness emitted $e2e grading-tree lines on stderr (want 1)"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
