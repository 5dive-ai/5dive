#!/usr/bin/env bash
# DIVE-2072 unit harness for scripts/hook-staleness-check.sh.
#
# Hermetic: builds throwaway `git init` repos per case, no network, no fixture
# drift, and calls the REAL script rather than a reimplementation — a
# reimplementation drifts in exactly the way the thing you are catching drifts.
# Run: bash tests/hook_staleness_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
CHECK="$PWD/scripts/hook-staleness-check.sh"
TMP="$(mktemp -d /tmp/hook-staleness-unit.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# A repo with main carrying a hook, and a branch cut BEFORE main changed it.
mkrepo() { # $1 = dir
  local d="$TMP/$1"; mkdir -p "$d/scripts/git-hooks"; git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'v1 hook\n' > "$d/scripts/git-hooks/pre-push"
  echo x > "$d/f"; git -C "$d" add -A; git -C "$d" commit -qm "base: hook v1"
  git -C "$d" branch feature                       # branch point == base
  printf 'v2 hook with the version guard\n' > "$d/scripts/git-hooks/pre-push"
  git -C "$d" add -A; git -C "$d" commit -qm "fix(release): add version-bump guard to the hook"
  printf '%s' "$d"
}
run() { ( cd "$1" && shift && bash "$CHECK" "$@" ) >"$TMP/out" 2>"$TMP/err"; }

# --- A: THE BUG — branch cut before the hook change, does not touch the hook.
D=$(mkrepo a); git -C "$D" checkout -q feature; echo y > "$D/other"; git -C "$D" add -A
git -C "$D" commit -qm "unrelated work"
run "$D" HEAD main; rc=$?
(( rc == 1 )) && ok_t "A stale branch exits 1" || bad_t "A stale not detected" "rc=$rc $(cat "$TMP/err")"
grep -q 'STALE' "$TMP/err" && ok_t "A output says STALE" || bad_t "A no STALE marker" "$(cat "$TMP/err")"
grep -q 'add version-bump guard' "$TMP/err" \
  && ok_t "A names the specific commit the branch is missing" \
  || bad_t "A does not name the missing commit" "a guard that will not say what it graded is not distinguishable from one that did not run"
grep -qi 'rebase' "$TMP/err" && ok_t "A names the remedy (rebase)" || bad_t "A no remedy" "$(cat "$TMP/err")"

# --- B: THE FALSE POSITIVE GUARD — a branch that IMPROVES the hook is not stale.
# A bare `git diff main -- scripts/git-hooks` would fire here and tell the PR
# fixing the hook to rebase away its own work.
D=$(mkrepo b); git -C "$D" checkout -q feature
printf 'my own better hook\n' > "$D/scripts/git-hooks/pre-push"; git -C "$D" add -A
git -C "$D" commit -qm "improve the hook"
run "$D" HEAD main; rc=$?
(( rc == 0 )) && ok_t "B branch that edits the hooks is NOT stale (exit 0)" \
  || bad_t "B false positive on the hook-fixing PR" "rc=$rc — a bare diff-vs-main would do exactly this"
grep -q 'owns its copy' "$TMP/out" && ok_t "B says why it passed (owns its copy)" || bad_t "B message" "$(cat "$TMP/out")"

# --- C: main has not touched the hooks since the base.
D=$(mkrepo c); git -C "$D" checkout -q main; git -C "$D" reset -q --hard HEAD~1
git -C "$D" checkout -q feature; echo y > "$D/o"; git -C "$D" add -A; git -C "$D" commit -qm w
run "$D" HEAD main; rc=$?
(( rc == 0 )) && ok_t "C unchanged hooks on main is not stale" || bad_t "C" "rc=$rc $(cat "$TMP/err")"

# --- D: current branch that already contains main's hook change.
D=$(mkrepo d); git -C "$D" checkout -q -b later main; echo y > "$D/o"; git -C "$D" add -A
git -C "$D" commit -qm w
run "$D" HEAD main; rc=$?
(( rc == 0 )) && ok_t "D branch containing main's hook change is not stale" || bad_t "D" "rc=$rc $(cat "$TMP/err")"

# --- E: UNDETERMINED must not read as a pass, and its two causes must not share
# one message (wiki stubbed-boundary-format-contract rule 2: folding two
# fall-through causes buries the one that matters inside the one that is routine).
D=$(mkrepo e)
run "$D" HEAD nonexistent-ref; rc=$?
(( rc == 2 )) && ok_t "E missing base ref exits 2, distinct from both pass(0) and stale(1)" \
  || bad_t "E missing ref misgraded" "rc=$rc — undetermined must not be indistinguishable from OK"
grep -q 'NOT a pass' "$TMP/err" && ok_t "E says explicitly it is not a pass" || bad_t "E soft-fails silently" "$(cat "$TMP/err")"
E1=$(cat "$TMP/err")
D2=$(mkrepo e2); git -C "$D2" checkout -q --orphan orphan; git -C "$D2" rm -rqf . 2>/dev/null
echo z > "$D2/z"; git -C "$D2" add -A; git -C "$D2" commit -qm orphan
run "$D2" HEAD main; rc=$?
(( rc == 2 )) && ok_t "E unrelated histories also exit 2" || bad_t "E orphan" "rc=$rc $(cat "$TMP/err")"
# olivia, verifying DIVE-2072: the first version of this compared the two runs
# RAW — and they use different MAIN_REF values ('nonexistent-ref' vs 'main'), so
# the interpolated ref name ALONE made the strings differ. It graded string
# interpolation, not message distinctness, and stayed GREEN under a mutation that
# folded both causes into one shared template. Normalise the quoted ref out of
# both before comparing, so only the TEMPLATE is under test.
norm_ref() { sed "s/'[^']*'/'REF'/g"; }
E1N=$(printf '%s' "$E1" | norm_ref)
E2N=$(norm_ref < "$TMP/err")
[[ "$E2N" != "$E1N" ]] \
  && ok_t "E the two UNDETERMINED causes emit DIFFERENT message TEMPLATES (rule 2: not folded)" \
  || bad_t "E folded messages" "a missing ref and unrelated histories read identically once the ref name is normalised out — the rare one hides in the routine one"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
