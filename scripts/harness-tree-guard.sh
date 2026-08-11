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
# DIVE-3074: the remediation this guard PRINTS is computed per-file, and a source
# line that matches the regex but cannot RESOLVE is itself a violation. See the
# rel_grading_tree/source_line_resolves block below for why the text match alone
# was not the property.
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

# DIVE-3074: THE REMEDIATION IS DEPTH-DEPENDENT, so it is COMPUTED, not fixed.
#
# The canonical line `. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"` is
# correct only for a file directly in `tests/`. From `tests/meta/` it resolves to
# `tests/meta/lib/grading_tree.sh` — a path that cannot exist — so the harness
# prints `grading tree: UNRESOLVED` on every invocation. GRADING_TREE_SOURCE_RE is
# a TEXT match (`.*lib/grading_tree\.sh`), so the broken paste SATISFIES this guard.
# An author doing exactly what this guard told them to do got: guard GREEN,
# property ABSENT, nothing anywhere saying the two disagreed.
#
# The same wrongness was already known for ONE directory — see the `tests/lib/*`
# exclusion above, whose comment spells out the identical `tests/lib/lib/...`
# arithmetic — and was not generalised. It is generalised here: the guard already
# knows the path it is refusing, so it can emit the right number of `../`.
#
# The comment about the load-bearing absence of `2>/dev/null` (see
# tests/lib/grading_tree.sh for the full rationale) rides along unchanged.
# Safe to spell the snippet here, unlike inside the contract test itself: this
# file is not in tests/*.sh, so it is never part of the corpus this snippet's own
# regex scans, and cannot create the self-matching trap the contract test warns of.

# rel_grading_tree <path-under-tests> -> the path the snippet must use from that
# file's own directory, e.g. tests/foo.sh -> lib/grading_tree.sh,
# tests/meta/foo.sh -> ../lib/grading_tree.sh, tests/a/b/foo.sh -> ../../lib/...
rel_grading_tree() {
  local f="$1" dir depth=0
  dir="$(dirname "$f")"
  # Anything the guard enumerates is under tests/ by construction (the pathspec).
  # If that ever stops being true, fall back to the canonical spelling rather
  # than inventing arithmetic for a path shape nobody has reasoned about.
  [[ "$dir" == "tests" || "$dir" == tests/* ]] || { printf 'lib/grading_tree.sh'; return; }
  local rest="${dir#tests}"; rest="${rest#/}"
  if [[ -n "$rest" ]]; then
    local IFS=/ part
    for part in $rest; do [[ -n "$part" && "$part" != "." ]] && depth=$((depth+1)); done
  fi
  local up="" i
  for (( i = 0; i < depth; i++ )); do up+="../"; done
  printf '%slib/grading_tree.sh' "$up"
}

# fix_snippet_for <path-under-tests> -> the paste-able block for THAT file.
fix_snippet_for() {
  local rel; rel="$(rel_grading_tree "$1")"
  cat <<SNIPPET
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# \`set -e\` harness is not killed by a failed source.
# NOTE the absence of \`2>/dev/null\`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "\$(dirname "\${BASH_SOURCE[0]}")/$rel" \\
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\\n' >&2
SNIPPET
}

# norm_path <slashy/path> -> the same path with `.` and `..` resolved LEXICALLY.
# Lexical is what we want: the target is a fixed repo path, there are no symlinks
# in tests/, and we are reasoning about a blob in git, not the working tree.
norm_path() {
  local c oldIFS="$IFS"
  local -a out=() parts=()
  IFS='/'; read -r -a parts <<< "$1"; IFS="$oldIFS"
  for c in ${parts[@]+"${parts[@]}"}; do
    case "$c" in
      ''|.) ;;
      ..)
        if (( ${#out[@]} > 0 )) && [[ "${out[$(( ${#out[@]} - 1 ))]}" != ".." ]]; then
          out=( ${out[@]+"${out[@]:0:$(( ${#out[@]} - 1 ))}"} )
        else
          out+=("..")
        fi
        ;;
      *) out+=("$c") ;;
    esac
  done
  local joined=""
  for c in ${out[@]+"${out[@]}"}; do joined="${joined:+$joined/}$c"; done
  printf '%s' "$joined"
}

# source_line_resolves <file-path> <file-content>
# Answers: does this file carry a source line that actually REACHES
# tests/lib/grading_tree.sh — not merely one that matches the text regex?
#
# Only the `$(dirname ...)`-relative family can be judged statically, and it is
# exactly the family this guard prints, so it is exactly the family that can be
# silently wrong because of this guard. Any OTHER spelling (a $VAR, an absolute
# path, a computed root) is not judged here: rc 2 = "cannot tell", and the caller
# defers to CI rather than blocking on a shape it did not reason about.
#   rc 0 = at least one dirname-relative line resolves to tests/lib/grading_tree.sh
#   rc 1 = every matching line is dirname-relative and NONE of them resolve
#   rc 2 = no dirname-relative matching line to judge
source_line_resolves() {
  local f="$1" content="$2" dir line sfx judged=0
  dir="$(dirname "$f")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sfx="$(printf '%s\n' "$line" | sed -n 's|.*dirname[^)]*)\(/[^"]*lib/grading_tree\.sh\).*|\1|p')"
    [[ -n "$sfx" ]] || continue
    judged=1
    [[ "$(norm_path "$dir$sfx")" == "tests/lib/grading_tree.sh" ]] && return 0
  done < <(printf '%s\n' "$content" | grep -E "$GRADING_TREE_SOURCE_RE")
  (( judged )) && return 1
  return 2
}

fail=0
for f in "${ADDED[@]}"; do
  if ! content="$(git show "${NEW}:${f}" 2>&1)"; then
    echo "harness-tree-guard: BLOCKED -- could not read $f at $NEW even though git diff reported it as newly added ($content). Refusing rather than silently skipping a file nothing was actually checked." >&2
    fail=1
    continue
  fi
  violation=""
  if ! printf '%s\n' "$content" | grep -qE "$GRADING_TREE_SOURCE_RE"; then
    violation="$f is a new harness that does not source tests/lib/grading_tree.sh (DIVE-2211 contract)."
  else
    # DIVE-3074: the text match is not the property. A `$(dirname ...)`-relative
    # line can satisfy the regex and still resolve nowhere, which prints
    # "grading tree: UNRESOLVED" forever while every check reads green. Only the
    # family this guard itself prints is judged; rc 2 (some other spelling) is
    # deliberately left to CI.
    source_line_resolves "$f" "$content"
    case $? in
      1) violation="$f sources a grading_tree.sh path that CANNOT RESOLVE from $(dirname "$f")/ -- it matches the DIVE-2211 regex but reaches no file, so the harness would print 'grading tree: UNRESOLVED' on every run (DIVE-3074)." ;;
    esac
  fi
  if [[ -n "$violation" ]]; then
    echo "harness-tree-guard: BLOCKED -- $violation" >&2
    echo "  FIX -- paste this immediately after \`set -uo pipefail\` in $f:" >&2
    echo "" >&2
    fix_snippet_for "$f" | sed 's/^/      /' >&2
    echo "" >&2
    echo "  The relative path above is computed for THIS file's directory -- the canonical" >&2
    echo "  \`/lib/grading_tree.sh\` spelling is correct only directly inside tests/." >&2
    echo "  Keep the ABSENCE of \`2>/dev/null\` on the source line: it would swallow the" >&2
    echo "  helper's own stderr line, which IS the payload, and no other check would notice." >&2
    fail=1
  fi
done

exit $fail
