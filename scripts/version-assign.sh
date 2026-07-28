#!/usr/bin/env bash
# DIVE-2118: PERFORM the version assignment that the merge rule describes and
# nothing owns.
#
# CONTRIBUTING says a PR must not bump FIVE_VERSION — the version is assigned at
# MERGE, by merge order. The prohibition half is understood and followed; the
# PERFORMANCE half is done by nobody. Measured 2026-07-26: #218, #219, #220 and
# #221 all merged claiming 0.16.19, a version already published against a
# DIFFERENT bundle. version-uniqueness caught it on the push to main and turned
# main red, which is the job working — but it is a POST-HOC detector on a shared
# branch, so it imposes cleanup on whoever notices, and until then the shared
# checkout updater (which is VERSION-triggered, not content-hash triggered) keeps
# every box on its old binary and silently delivers none of the merged fixes.
#
# This is the exact inverse of scripts/version-bump-guard.sh: the SAME predicate,
# used to repair instead of to refuse. Deliberately not forked into a new rule —
# if the guard's notion of "the bundle changed" ever moves, this must move with it.
#
# BUMP YES, TAG NO. lodar froze GitHub releases on 2026-07-26 (36 versions in ~36
# hours, 26 of them fixes) — but froze the TAG, explicitly not the bump: the bump
# is load-bearing (it prevents two merges claiming one version, and it keeps the
# installed-bundle-matches-its-commit selfcheck honest). So this script bumps,
# and must NEVER create a tag or a GitHub release.
#
# DIVE-2230: THE QUESTION IS ABSOLUTE, SO THE BASE IS DERIVED, NEVER PASSED.
#
# This script used to compare the bundle at <new-rev> against <base-rev> — the
# PREVIOUS COMMIT. That asks "did the bundle move in THIS push". The invariant it
# exists to defend is "does main's bundle match the LAST ASSIGNED VERSION". Those
# two agree exactly until an assignment fails to land. After that the debt is
# carried by no one and ERASED by the next unrelated commit, silently and for good.
#
# Measured 2026-07-28, three artifacts: run #268 (a2e2009) printed "ASSIGNMENT
# OWED ... next = 0.16.36" and died on a branch-protection push rejection — loud
# and correct. Run #271 (0e37bf7), a workflow-only push, then printed "no
# assignment needed — the bundle is unchanged since a2e2009" and went GREEN, with
# main's bundle still unassigned. Every run after that was green too. bundle-drift
# cannot see it either: it compares bundle to SOURCE, and those agree.
#
# So the base is now the ANCHOR: the commit that set FIVE_VERSION to its CURRENT
# value. The bundle recorded there IS the bundle this version shipped, so the
# comparison answers the absolute question at ANY commit, independent of what the
# adjacent one did — and one transient push failure can no longer launder itself
# green. Same wrong-target shape as an anchor pinned to a moving ref (DIVE-2213):
# the instrument was fine, the thing it was pointed at was not.
#
# <base-rev> is still ACCEPTED and still VALIDATED — an unresolvable base means a
# truncated fetch, and a truncated fetch is exactly what breaks the anchor walk, so
# it stays as a canary. It is never DECIDED on. A caller cannot reintroduce the
# delta semantics by passing the wrong thing, which is why version-assign.yml needs
# no change: its `$before` is now inert.
#
# Usage: version-assign.sh <new-rev> [<base-rev>] [--apply]
#        <base-rev> is a truncated-history canary only; the owed/not-owed decision
#        is computed against the last ASSIGNED version, never against it.
# Exit:  0 = no assignment needed (prints why) or assignment computed/applied
#        2 = could not determine (NOT a pass — never silently skip)
set -uo pipefail

NEW="${1:?usage: version-assign.sh <new-rev> [<base-rev>] [--apply]}"
BASE="${2:-}"
APPLY=0
for a in "$@"; do [[ "$a" == "--apply" ]] && APPLY=1; done
[[ "$BASE" == "--apply" ]] && BASE=""
BASE="${BASE:-${NEW}^}"

ver_at() { git show "$1:src/header.sh" 2>/dev/null | grep -m1 -oE '^readonly FIVE_VERSION="[^"]+"' | sed 's/.*"\(.*\)"/\1/'; }
sha_at() { git show "$1:5dive.sha256" 2>/dev/null | cut -d' ' -f1; }

if ! git rev-parse --verify --quiet "$NEW" >/dev/null; then
  echo "version-assign: UNDETERMINED — no such rev '$NEW'. This is NOT a pass." >&2; exit 2
fi
if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "version-assign: UNDETERMINED — no usable base rev '$BASE' (first commit, or a truncated fetch). This is NOT a pass; a bump may be owed and could not be computed. The base does not decide anything (DIVE-2230) — it is kept as a truncated-history canary, and a truncated history is what breaks the anchor walk below." >&2; exit 2
fi

v_new=$(ver_at "$NEW")
s_new=$(sha_at "$NEW")

# Fail-open must be LOUD, and the two unreadable causes must not share a message.
if [[ -z "$v_new" ]]; then
  echo "version-assign: UNDETERMINED — could not read FIVE_VERSION at '$NEW' (missing src/header.sh, or the 'readonly FIVE_VERSION=' anchor drifted). This is NOT a pass." >&2; exit 2
fi
if [[ -z "$s_new" ]]; then
  echo "version-assign: UNDETERMINED — could not read 5dive.sha256 at '$NEW'. This is NOT a pass." >&2; exit 2
fi

# THE ANCHOR: walk back over the commits that touched src/header.sh and stop at the
# first one carrying a DIFFERENT version. The commit after it — the oldest one still
# carrying $v_new — is where $v_new was assigned. First-parent, because main's trunk
# is what gets assigned; a merge that changes the version relative to its first
# parent is itself an assignment and is listed.
#
# Walking is the whole point: reading it off the adjacent commit is the bug. The loop
# normally ends on its first or second iteration (the version moves nearly every
# release commit), and it is bounded by the history of ONE file.
ANCHOR=""
while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  if [[ "$(ver_at "$c")" != "$v_new" ]]; then break; fi
  ANCHOR="$c"
done < <(git log --first-parent --format=%H "$NEW" -- src/header.sh)

# Never infer an anchor we could not actually see. A shallow clone reaches the end of
# its grafted history and reports "the version never changed", which is
# indistinguishable from a genuinely-first version except by asking git whether the
# history is complete. Guessing here would restore the exact fail-open this ticket is
# about, one layer down.
if [[ -z "$ANCHOR" ]]; then
  echo "version-assign: UNDETERMINED — could not locate the commit that assigned FIVE_VERSION $v_new at '$NEW'. This is NOT a pass; a bump may be owed and could not be computed." >&2; exit 2
fi
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]] && [[ -z "$(git rev-parse --verify --quiet "${ANCHOR}^" 2>/dev/null)" ]]; then
  echo "version-assign: UNDETERMINED — the history is SHALLOW and the walk ran off its end at '${ANCHOR:0:12}', so '$v_new' may have been assigned before the graft. This is NOT a pass; fetch with depth 0." >&2; exit 2
fi

s_anchor=$(sha_at "$ANCHOR")
if [[ -z "$s_anchor" ]]; then
  echo "version-assign: UNDETERMINED — could not read 5dive.sha256 at the assignment commit '${ANCHOR:0:12}'. This is NOT a pass." >&2; exit 2
fi

if [[ "$s_new" == "$s_anchor" ]]; then
  echo "version-assign: no assignment needed — the bundle is unchanged since $v_new was assigned at ${ANCHOR:0:12}; main ships the bundle its version claims."; exit 0
fi

# The bundle moved since the version was last assigned, and the version did not
# follow: this is the assignment nobody performed. Note this is TRUE even when the
# move happened several commits ago and this push touched nothing — that case is
# DIVE-2230 itself, and reporting it is the fix.
if [[ ! "$v_new" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "version-assign: UNDETERMINED — FIVE_VERSION '$v_new' is not MAJOR.MINOR.PATCH, refusing to guess the successor. This is NOT a pass." >&2; exit 2
fi
NEXT="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$(( BASH_REMATCH[3] + 1 ))"

echo "version-assign: ASSIGNMENT OWED — bundle changed (${s_anchor:0:16} -> ${s_new:0:16}) since $v_new was assigned at ${ANCHOR:0:12}, with FIVE_VERSION still $v_new."
echo "version-assign: next = $NEXT"
(( APPLY )) || { echo "version-assign: --apply not given; nothing written."; exit 0; }

sed -i -E "s/^readonly FIVE_VERSION=\"[^\"]+\"/readonly FIVE_VERSION=\"${NEXT}\"/" src/header.sh
[[ "$(grep -m1 -oE '^readonly FIVE_VERSION="[^"]+"' src/header.sh)" == "readonly FIVE_VERSION=\"${NEXT}\"" ]] \
  || { echo "version-assign: the bump did NOT take in src/header.sh — refusing to continue." >&2; exit 2; }
./build.sh >/dev/null 2>&1 || { echo "version-assign: build.sh failed after the bump." >&2; exit 2; }

# Assert EFFECT, not the exit code of the thing that was supposed to cause it.
built=$(sha256sum 5dive | cut -d' ' -f1)
[[ "$built" == "$(cut -d' ' -f1 < 5dive.sha256)" ]] \
  || { echo "version-assign: rebuilt bundle does not match 5dive.sha256." >&2; exit 2; }
grep -q "FIVE_VERSION=\"${NEXT}\"" 5dive \
  || { echo "version-assign: ${NEXT} is not embedded in the rebuilt bundle." >&2; exit 2; }
echo "version-assign: applied ${v_new} -> ${NEXT}, bundle rebuilt (${built:0:16}). NO TAG — releases are batched."
