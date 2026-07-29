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
# Usage: version-assign.sh <new-rev> [<base-rev>] [--apply]
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
# DIVE-2091: 5dive.sha256 is generated at tag time and no longer committed, so it
# cannot be read from a commit. It was only ever a proxy for "did the source
# change" — ask that directly. Same exemption for workflow/doc-only pushes.
_src_changed() { ! git diff --quiet "$1" "$2" -- src build.sh 2>/dev/null; }

if ! git rev-parse --verify --quiet "$NEW" >/dev/null; then
  echo "version-assign: UNDETERMINED — no such rev '$NEW'. This is NOT a pass." >&2; exit 2
fi
if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "version-assign: UNDETERMINED — no usable base rev '$BASE' (first commit, or a truncated fetch). This is NOT a pass; a bump may be owed and could not be computed." >&2; exit 2
fi

v_new=$(ver_at "$NEW"); v_base=$(ver_at "$BASE")
src_moved=0; _src_changed "$BASE" "$NEW" && src_moved=1

# Fail-open must be LOUD, and the two unreadable causes must not share a message.
if [[ -z "$v_new" ]]; then
  echo "version-assign: UNDETERMINED — could not read FIVE_VERSION at '$NEW' (missing src/header.sh, or the 'readonly FIVE_VERSION=' anchor drifted). This is NOT a pass." >&2; exit 2
fi
if [[ "$src_moved" == "0" ]]; then
  echo "version-assign: no assignment needed — src/ and build.sh are unchanged since '$BASE' (workflow/doc-only push)."; exit 0
fi
if [[ "$v_new" != "$v_base" ]]; then
  echo "version-assign: no assignment needed — src changed AND FIVE_VERSION already moved ($v_base -> $v_new); whoever merged assigned it."; exit 0
fi

# The bundle moved and the version did not: this is the assignment nobody performed.
if [[ ! "$v_new" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "version-assign: UNDETERMINED — FIVE_VERSION '$v_new' is not MAJOR.MINOR.PATCH, refusing to guess the successor. This is NOT a pass." >&2; exit 2
fi
NEXT="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$(( BASH_REMATCH[3] + 1 ))"

echo "version-assign: ASSIGNMENT OWED — src/ changed since '$BASE' with FIVE_VERSION still $v_new."
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
