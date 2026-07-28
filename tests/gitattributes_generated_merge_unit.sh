#!/usr/bin/env bash
# DIVE-2250 — generated files must never be content-merged by git.
#
# WHAT THIS GRADES, and why it is shaped this way:
#   (a) the SHIPPED .gitattributes, read through `git check-attr`, not the existence
#       of the file. A .gitattributes that is present but whose pattern does not match
#       is exactly the vacuous control this repo keeps finding
#       (community/wiki/a-vacuously-passing-control-is-invisible-in-a-failure-list.md).
#   (b) the EFFECT, by running a real merge in a throwaway repo that uses the REAL
#       shipped .gitattributes — copied in, never reimplemented.
#
# THE ASSERTION IS "UNMERGED", NEVER "HAS CONFLICT MARKERS" (dev, measured 2026-07-28):
# with `-merge`, git leaves the index at stages 1/2/3 (`UU`) but writes OUR version to
# the worktree VERBATIM — zero <<<<<<< or >>>>>>>. A marker-based assertion would be
# green against a broken implementation AND green against a correct one, i.e. it would
# grade nothing. Measured in a throwaway repo: UU, worktree == ours, 0 markers.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   - $1"; }
bad(){ fail=$((fail+1)); echo "FAIL - $1: $2"; }

# --- (a) the shipped attribute, via check-attr -------------------------------
for f in 5dive src/cmd_council.sh; do
  got=$(git check-attr merge -- "$f" 2>/dev/null | sed 's/.*merge: //')
  [[ "$got" == "unset" ]] && ok "check-attr says merge is unset for $f" \
                          || bad "merge must be unset for $f" "got '$got'"
done
# 5dive.sha256 is DELIBERATELY left mergeable: it is one 64-hex line, so any two
# rebuilt branches always collide on it and the markers there are informative (you
# can read both hashes). Pinned so a later "tidy up" does not silently change it.
got=$(git check-attr merge -- 5dive.sha256 2>/dev/null | sed 's/.*merge: //')
[[ "$got" == "unspecified" ]] && ok "5dive.sha256 stays mergeable on purpose (its conflict is readable)" \
                              || bad "5dive.sha256 attribute changed" "got '$got'"

# --- (b) the effect, in a throwaway repo using the SHIPPED .gitattributes -----
# The scenario is the REAL hazard, not the easy one: two branches edit DIFFERENT
# regions of a large generated file. That is what git text-merges silently today.
scenario() { # $1 = "with-attrs" | "without-attrs" ; echoes UNMERGED|MERGED-SILENTLY
  local mode="$1" t; t=$(mktemp -d /tmp/gitattr-unit.XXXXXX) || return 1
  ( set -e; cd "$t"; git init -q .; git config user.email t@t; git config user.name t
    [[ "$mode" == "with-attrs" ]] && cp "$REPO_ROOT/.gitattributes" .
    seq 1 400 > 5dive; git add -A; git commit -qm base
    git checkout -qb side; sed -i '390s/.*/THEIR-EDIT/' 5dive; git commit -qam theirs
    git checkout -q -; sed -i '10s/.*/OUR-EDIT/' 5dive; git commit -qam ours
    git merge side >/dev/null 2>&1 || true
    if [[ -n "$(git ls-files -u -- 5dive)" ]]; then echo UNMERGED; else echo MERGED-SILENTLY; fi
  ); rm -rf "$t"
}
r=$(scenario with-attrs)
[[ "$r" == "UNMERGED" ]] && ok "a two-region concurrent edit leaves the bundle UNMERGED (git refuses to stitch it)" \
                         || bad "the attribute must stop the content merge" "got '$r'"
# TWO-SIDED: without the shipped file the SAME scenario stitches silently. Without
# this arm the test passes on a git that refuses everything, and proves nothing about
# our .gitattributes.
r=$(scenario without-attrs)
[[ "$r" == "MERGED-SILENTLY" ]] && ok "and without it git DOES stitch the same edit silently (the hazard is real, arm is not vacuous)" \
                                || bad "control must show a silent stitch" "got '$r'"

printf '\ngitattributes-generated-merge: %s passed, %s failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
