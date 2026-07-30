#!/usr/bin/env bash
# Range PII scanner (DIVE-2267).
#
# WHY THIS EXISTS: pii-guard.yml's PUSH path scanned `git log -1 --format=%B` and
# nothing else, so a denylisted identifier in an ADDED LINE reached public main
# with a green pii-guard. The per-checkout pre-push hook (scripts/git-hooks/
# pre-push) does scan added content, but git will not run a repo-tracked hook
# automatically -- deliberately, since a repo that executed code on clone would be
# a supply-chain hazard (DIVE-2255). So on a FRESH CLONE, which is the route admin
# and bot pushes actually take, neither side scanned content: not the hook (absent)
# and not CI (message only).
#
# WHY A SCRIPT AND NOT INLINE YAML, two reasons and both load-bearing:
#   1. a workflow body cannot be unit-tested; this can, and is
#      (tests/pii_scan_range_unit.sh).
#   2. .github/workflows/ needs a credential most agents do not hold (DIVE-2262),
#      so logic living in YAML is logic that cannot be repaired on the normal
#      rail. Logic here can.
#
# FAIL CLOSED, which is the entire point (DIVE-2264). The previous generation of
# these workflows collapsed "no usable previous tip" into `exit 0` and reported
# green -- a script that failed closed wrapped by a caller that failed open. There
# is NO input for which this script reports clean without having scanned content:
# every path that cannot read content exits non-zero.
#
# Usage: pii-scan-range.sh <base-ref> <head-ref>
#
# Exits, matching scripts/pii-scan.sh's own contract so a caller can tell
# "clean" from "could not look":
#   0  scanned, clean
#   1  one or more denylisted identifiers found
#   2  UNDETERMINED -- could not scan. This is NOT a pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${PII_SCAN:-$HERE/pii-scan.sh}"

if [[ $# -lt 2 ]]; then
  echo "usage: pii-scan-range.sh <base-ref> <head-ref>" >&2
  exit 2
fi
if [[ ! -f "$SCAN" ]]; then
  echo "pii-scan-range: UNDETERMINED -- scanner not found: $SCAN. This is NOT a pass." >&2
  exit 2
fi

BASE="$1"
HEAD_REF="$2"
ZERO="0000000000000000000000000000000000000000"

# Run the scanner over stdin and translate its exit code. A scanner rc we do not
# recognise (2 = missing denylist, or any future code) is UNDETERMINED, never
# clean -- the caller must not have to guess which non-zero means "found" and
# which means "could not look".
scan_stdin() {  # $1 = human label for the log
  local label="$1" s
  bash "$SCAN"; s=$?
  case "$s" in
    0) return 0 ;;
    1) echo "pii-scan-range: DENYLIST HIT in $label" >&2; return 1 ;;
    *) echo "pii-scan-range: UNDETERMINED -- scanner exited $s on $label, so it did not complete a scan. This is NOT a pass." >&2
       return 2 ;;
  esac
}

# Resolve the head first: with no head there is no scan at all, narrowed or not.
if ! head_sha="$(git rev-parse -q --verify "${HEAD_REF}^{commit}")"; then
  echo "pii-scan-range: UNDETERMINED -- head ref '$HEAD_REF' does not resolve to a commit. This is NOT a pass." >&2
  exit 2
fi

# ANCHOR LADDER. A push event's `before` is EMPTY on branch creation, ALL-ZEROES
# on a force push, and UNRESOLVABLE against a shallow fetch or a rewritten
# history. The retired version-assign.yml collapsed those three into one silent
# `exit 0`; none of them is a reason to skip, because a narrower scan is still a
# scan. We narrow to the head commit and SAY SO in the log, and only give up when
# there is nothing to diff against at all.
narrowed=0
if [[ -n "$BASE" && "$BASE" != "$ZERO" ]] \
   && base_sha="$(git rev-parse -q --verify "${BASE}^{commit}")"; then
  :
elif base_sha="$(git rev-parse -q --verify "${head_sha}^^{commit}")"; then
  narrowed=1
  echo "pii-scan-range: no usable base anchor (base='${BASE}') -- NARROWED to the head commit ${head_sha:0:12}." >&2
  echo "pii-scan-range: this is NOT a full-range all-clear; any earlier commit in this push was not scanned." >&2
else
  echo "pii-scan-range: UNDETERMINED -- base '${BASE}' does not resolve and ${head_sha:0:12} has no parent, so no content could be scanned. This is NOT a pass." >&2
  exit 2
fi

range="${base_sha}..${head_sha}"
rc=0

# 1. Commit messages across the WHOLE range. The old push path read `git log -1`,
#    so a denylisted id in the message of any earlier commit of a multi-commit
#    push was invisible.
if ! msgs="$(git log --format='%B' "$range" 2>&1)"; then
  echo "pii-scan-range: UNDETERMINED -- could not read commit messages for $range. This is NOT a pass." >&2
  printf '%s\n' "$msgs" >&2
  exit 2
fi
printf '%s\n' "$msgs" | scan_stdin "commit messages in $range"; s=$?
(( s == 2 )) && exit 2
(( s == 1 )) && rc=1

# 2. ADDED LINES of the diff -- the coverage this whole ticket is about.
if ! diff_out="$(git diff "$range" 2>&1)"; then
  echo "pii-scan-range: UNDETERMINED -- could not produce the diff for $range. This is NOT a pass." >&2
  printf '%s\n' "$diff_out" >&2
  exit 2
fi
# A range with no added lines at all (a pure deletion, or a message-only commit)
# makes grep exit 1. That is an EMPTY scan, not a failed one, so the verdict has
# to come from the scanner rather than from grep -- with pipefail set, letting
# grep's status through here would turn every deletion-only push red.
added="$(printf '%s\n' "$diff_out" | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//')" || true
printf '%s\n' "$added" | scan_stdin "added lines in $range"; s=$?
(( s == 2 )) && exit 2
(( s == 1 )) && rc=1

if (( rc == 0 )); then
  if (( narrowed )); then
    echo "pii-scan-range: clean over the NARROWED range $range (head commit only)."
  else
    echo "pii-scan-range: clean over $range."
  fi
fi
exit "$rc"
