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

mapfile -t ADDED < <(git diff --name-only --diff-filter=A "$BASE" "$NEW" -- 'tests/*.sh' 2>/dev/null || true)
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
  content="$(git show "${NEW}:${f}" 2>/dev/null || true)"
  [[ -z "$content" ]] && continue
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
