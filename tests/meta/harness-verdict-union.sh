#!/usr/bin/env bash
# DIVE-2018: harness-verdict-probe.sh treats NOT-REACHED as neither pass nor fail,
# and NOT-REACHED is absent from its final condition. That was the right call for
# the case it was written for — a harness that skips before its verdict has not
# been shown to be unwired, and calling it UNWIRED is a FALSE ACCUSATION, which is
# worse than a gap (three correctly-wired harnesses were accused that way on the
# pristine CI runner). But the consequence is that probe COVERAGE IS SILENTLY
# ENVIRONMENT-DEPENDENT:
#
#   on the control-plane host   135 wired, 0 UNWIRED, 3 allowlisted, 16 not-reached  -> exit 0
#   on a pristine CI runner     151 wired, 0 UNWIRED, 3 allowlisted,  0 not-reached  -> exit 0
#
# 135+3+16 == 151+3 == 154. Both runs are GREEN while probing DIFFERENT CORPORA,
# and nothing anywhere says so. The limit case is the point: a harness that skips
# in EVERY environment is reported "probed in an environment where it runs" and no
# environment ever does. It stays permanently unprobed and the check stays green —
# succeeding in appearance, which is the exact defect class DIVE-2013 exists to
# find, one level up in the instrument itself.
#
# So the invariant does not belong to any single run. It belongs to the UNION:
#
#   every harness in tests/*.sh is PROBED in at least one environment,
#   or is named in the allowlist with a reason.
#
# This script asserts that over one or more probe reports (`--report=<file>`).
# A skip in one environment is still not an accusation; a skip in ALL of them is
# now a failure. That keeps the property olivia asked for and closes the hole.
#
# PROBED means the mutation EXECUTED — verdict `wired` or `UNWIRED`. Deliberately
# NOT `already-red` (its clean run failed, so it was reported and never probed)
# and NOT `UNPROBEABLE` (no identifiable verdict variable; it already reds the
# probe itself, and counting it as coverage here would excuse it twice).
#
# The allowlist is READ FROM THE REPORTS, never restated here. Two allowlists
# written in two places are one contract with two authors, and when they drift the
# consumer refuses a state only the producer can mint (DIVE-2004). All reports must
# agree on it, or that disagreement is itself the finding.
#
# FAILS CLOSED. No reports, an unreadable report, a report with no header, or
# reports that disagree about the size of the corpus are all exit 1 — because the
# whole premise of this check is that a missing observation must not read as a
# clean one.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

CORPUS_DIR="tests"
REPORTS=()
for a in "$@"; do case "$a" in
  --corpus-dir=*) CORPUS_DIR="${a#--corpus-dir=}" ;;
  --*) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
  *) REPORTS+=("$a") ;;
esac; done

if (( ${#REPORTS[@]} == 0 )); then
  printf 'usage: %s [--corpus-dir=<dir>] <probe-report>...\n' "${BASH_SOURCE[0]##*/}" >&2
  printf '  each report is written by: harness-verdict-probe.sh --report=<file>\n' >&2
  exit 2
fi

# The corpus is derived from the tree this script runs in — ONE source of truth,
# so a report produced from a different checkout is caught by the count below
# rather than silently shrinking what we claim to cover.
corpus=()
for t in "$CORPUS_DIR"/*.sh; do [[ -e "$t" ]] && corpus+=("$(basename "$t")"); done
if (( ${#corpus[@]} == 0 )); then
  printf 'union: FAIL — corpus dir %s contains no *.sh; refusing to declare full coverage of nothing\n' "$CORPUS_DIR"
  exit 1
fi

PROBED=" "        # space-delimited membership sets, matched as *" name "*
ALLOWLIST=""
declare -A VERDICT_BY_ENV=()   # "<harness>|<label>" -> verdict
LABELS=()
fail=0

for r in "${REPORTS[@]}"; do
  if [[ ! -r "$r" ]]; then
    printf 'union: FAIL — report %s is missing or unreadable; a missing observation is not a clean one\n' "$r"
    fail=1; continue
  fi
  hdr_corpus=$(sed -n 's/^# corpus=\([0-9]\{1,\}\).*/\1/p' "$r" | head -1)
  hdr_allow=$(sed -n 's/^# allowlist=//p' "$r" | head -1)
  label=$(sed -n 's/^# label=//p' "$r" | head -1)
  [[ -n "$label" ]] || label="$r"
  LABELS+=("$label")
  if [[ -z "$hdr_corpus" ]]; then
    printf 'union: FAIL — report %s has no "# corpus=" header; it was not written by harness-verdict-probe --report\n' "$r"
    fail=1; continue
  fi
  if (( hdr_corpus != ${#corpus[@]} )); then
    printf 'union: FAIL — report %s (%s) describes a corpus of %d harnesses, this tree has %d — the reports are not about the same code\n' \
      "$r" "$label" "$hdr_corpus" "${#corpus[@]}"
    fail=1; continue
  fi
  # The allowlist is the producer's, and every producer must agree on it.
  if [[ -z "$ALLOWLIST" ]]; then ALLOWLIST="$hdr_allow"
  elif [[ "$ALLOWLIST" != "$hdr_allow" ]]; then
    printf 'union: FAIL — reports disagree on the allowlist (%s) vs (%s); one contract, two authors\n' \
      "$ALLOWLIST" "$hdr_allow"
    fail=1
  fi
  while IFS=$'\t' read -r verdict name; do
    [[ -n "${name:-}" ]] || continue
    VERDICT_BY_ENV["$name|$label"]="$verdict"
    case "$verdict" in
      wired|UNWIRED) [[ "$PROBED" == *" $name "* ]] || PROBED+="$name " ;;
    esac
  done < <(grep -v '^#' "$r")
done

(( fail == 0 )) || { printf 'union: refusing to assert coverage from reports that do not agree\n'; exit 1; }

allow_set=" ${ALLOWLIST//,/ } "
unprobed=()
for h in "${corpus[@]}"; do
  [[ "$PROBED"    == *" $h "* ]] && continue
  [[ "$allow_set" == *" $h "* ]] && continue
  unprobed+=("$h")
done

# Stale allowlist entries are drift worth SAYING, not worth reddening: a renamed
# harness loses its exemption and turns UNPROBEABLE, which reds the probe itself,
# so this can only ever be a leftover name that excuses nothing.
for a in ${ALLOWLIST//,/ }; do
  [[ " ${corpus[*]} " == *" $a "* ]] || printf 'stale-allowlist  %s — named in the allowlist but not in the corpus\n' "$a"
done

printf 'harness-verdict-union: %d in corpus, %d probed across %d environment(s) [%s], %d allowlisted, %d NEVER PROBED\n' \
  "${#corpus[@]}" "$(( $(wc -w <<<"$PROBED") ))" "${#LABELS[@]}" "${LABELS[*]}" \
  "$(wc -w <<<"${ALLOWLIST//,/ }")" "${#unprobed[@]}"

for h in "${unprobed[@]:-}"; do
  [[ -n "$h" ]] || continue
  detail=""
  for l in "${LABELS[@]}"; do detail+=" ${l}=${VERDICT_BY_ENV["$h|$l"]:-absent}"; done
  printf 'NEVER PROBED  %s —%s; its exit status has never been shown to be wired in ANY environment\n' "$h" "$detail"
done
(( ${#unprobed[@]} == 0 ))
