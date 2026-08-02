#!/usr/bin/env bash
# DIVE-2286: push-time guard for the DIVE-2211 corpus invariant (every
# harness in tests/*.sh sources tests/lib/grading_tree.sh).
#
# WHY a push-time guard and not just the CI contract
# (tests/names_the_tree_contract_unit.sh): CI catches a missing source line
# only after a full round trip -- measured on gh#290, test 9m11s +
# test-installed-host 16m54s (~27 min) to learn about one absent line. A
# local grep over just the files THIS push adds catches it before it ever
# leaves the machine.
#
# MEASURED, 2026-07-29: four harnesses, three authors, one calendar day, all
# missing this exact line (olivia DIVE-2265 iteration 1, dev gh#288, main2
# gh#289, dev gh#290) -- see DIVE-2286. A missing scaffold, not four careless
# people.
#
# SCOPE: only files ADDED in this push's range (--diff-filter=A), matching
# tests/*.sh. A harness that later DELETES the source line is CI-only, which
# is correct -- that is a rarer edit and the whole-corpus contract test
# already owns it.
#
# REUSES the contract test's own detection regex via
# tests/lib/grading_tree_source_re.sh rather than re-spelling it here, so
# this guard and the CI contract cannot independently drift into checking
# two different things under the same name.
#
# WHAT HAPPENS WHEN THIS GUARD CANNOT TELL, stated explicitly rather than left
# to be inferred from the code (DIVE-2286 review, main): "could not determine"
# is not the same claim as "nothing to flag", and folding the two together is
# exactly the DIVE-2274 class this whole epic is about -- a check that cannot
# run and reports clean. Two different unknowns, two different answers:
#   - The guard's OWN dependency is unreadable (tests/lib/grading_tree_source_re.sh
#     missing at NEW -- expected on a branch cut before this guard shipped):
#     FAILS OPEN, loudly (a message on stderr, exit 0), matching the existing
#     documented convention for every guard in this hook -- see
#     scripts/git-hooks/pre-push's own "fail OPEN with a warning if their
#     script is missing" note. The CI contract test is the net for this case.
#   - THE DETECTION MECHANISM ITSELF fails (git diff cannot enumerate what
#     this push added, or git show cannot read a file diff just told us was
#     added): FAILS LOUD, exit 1, refusing the push rather than silently
#     reporting clear. Nothing was actually checked in that case, and a guard
#     that reports clean when it checked nothing is worse than no guard.
#
# Usage: harness-tree-guard.sh <new-rev> [<base-rev>=origin/main]
# Exit 0 = clear to push. Exit 1 = blocked, reason + fix snippet on stderr.
set -uo pipefail

NEW="${1:?usage: harness-tree-guard.sh <new-rev> [<base-rev>]}"
BASE="${2:-origin/main}"

RE_FILE_REL="tests/lib/grading_tree_source_re.sh"
re_src="$(git show "${NEW}:${RE_FILE_REL}" 2>/dev/null || true)"
if [[ -z "$re_src" ]]; then
  echo "harness-tree-guard: $RE_FILE_REL not found at $NEW; skipping (the CI contract test is the net)." >&2
  exit 0
fi
# shellcheck disable=SC1090
source <(printf '%s\n' "$re_src")
if [[ -z "${GRADING_TREE_SOURCE_RE:-}" ]]; then
  echo "harness-tree-guard: GRADING_TREE_SOURCE_RE not set after sourcing $RE_FILE_REL; skipping (the CI contract test is the net)." >&2
  exit 0
fi

# SCOPE MUST MATCH THE CONTRACT TEST'S, and it did not (DIVE-2518).
#
# The contract enumerates the corpus as `CORPUS=(tests/*.sh)` — a SHELL glob, which
# does not descend into `tests/lib/`. This guard used the git pathspec `tests/*.sh`,
# and git's wildmatch runs WITHOUT WM_PATHNAME by default, so its `*` DOES cross `/`
# and the pathspec silently also matched `tests/lib/*.sh`.
#
# So the guard and the contract it exists to front-run disagreed about what a
# harness IS — the exact drift this file's header says the shared
# GRADING_TREE_SOURCE_RE prevents. Sharing the regex was never enough: two checks
# can apply an identical predicate to different populations and still diverge.
#
# It fires on the first `tests/lib/` helper added since the guard shipped, and the
# fix it prints is actively WRONG there: the snippet resolves
# `$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh`, which from inside tests/lib/
# is `tests/lib/lib/grading_tree.sh` — a path that cannot exist. Following the
# instruction would have made every harness sourcing that helper print
# "grading tree: UNRESOLVED" forever. `tests/lib/pinned_baseline.sh` and
# `tests/lib/grading_tree.sh` itself are both already in the tree without the line,
# because they predate the guard rather than because they were exempted.
#
# A helper is not a harness: it has no arms, it names no tree, and it is sourced BY
# the harness that does.
if ! diff_out="$(git diff --name-only --diff-filter=A "$BASE" "$NEW" -- 'tests/*.sh' ':(exclude)tests/lib/*' 2>&1)"; then
  echo "harness-tree-guard: BLOCKED -- could not enumerate tests/*.sh files added by this push (git diff --diff-filter=A $BASE $NEW failed: $diff_out). Refusing rather than silently reporting clear, since nothing was actually checked." >&2
  exit 1
fi
ADDED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ADDED+=("$line")
done <<< "$diff_out"
(( ${#ADDED[@]} == 0 )) && exit 0

# The exact two functional lines every passing harness carries, plus the
# short comment explaining the load-bearing absence of `2>/dev/null` (see
# tests/lib/grading_tree.sh for the full rationale). Safe to hardcode here,
# unlike inside the contract test itself: this file is not in tests/*.sh, so
# it is never part of the corpus this snippet's own regex scans, and cannot
# create the self-matching trap the contract test's comment warns about.
read -r -d '' FIX_SNIPPET <<'SNIPPET' || true
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SNIPPET

fail=0
for f in "${ADDED[@]}"; do
  if ! content="$(git show "${NEW}:${f}" 2>&1)"; then
    echo "harness-tree-guard: BLOCKED -- could not read $f at $NEW even though git diff reported it as newly added ($content). Refusing rather than silently skipping a file nothing was actually checked." >&2
    fail=1
    continue
  fi
  if ! printf '%s\n' "$content" | grep -qE "$GRADING_TREE_SOURCE_RE"; then
    echo "harness-tree-guard: BLOCKED -- $f is a new harness that does not source tests/lib/grading_tree.sh (DIVE-2211 contract)." >&2
    echo "  FIX -- paste this immediately after \`set -uo pipefail\` in $f:" >&2
    echo "" >&2
    printf '%s\n' "$FIX_SNIPPET" | sed 's/^/      /' >&2
    echo "" >&2
    echo "  Keep the ABSENCE of \`2>/dev/null\` on the source line: it would swallow the" >&2
    echo "  helper's own stderr line, which IS the payload, and no other check would notice." >&2
    fail=1
  fi
done

exit $fail
