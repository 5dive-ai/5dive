#!/usr/bin/env bash
# DIVE-2039 — the union half of `5dive selfcheck`.
#
# selfcheck reports three verdicts per probe: pass, fail, NOT-REACHED. NOT-REACHED
# is deliberately NOT a failure in any single run — a probe whose precondition is
# genuinely absent (no test corpus on an installed host, no unprivileged actor in a
# root cron) has not been shown to be broken, and calling it broken is a FALSE
# ACCUSATION. That is the same call harness-verdict-probe.sh made for skips, and it
# is the right one.
#
# But it has the same consequence, and DIVE-2018 is the proof: if NOT-REACHED is
# excusable in every single run, COVERAGE IS SILENTLY ENVIRONMENT-DEPENDENT. A probe
# that is not-reached in the pristine CI job AND not-reached on the installed host is
# reported "not reached here" twice and reached nowhere — permanently unmeasured,
# permanently green. That is exactly the defect class `selfcheck` exists to find,
# one level up in the instrument.
#
# So the invariant does not belong to any single run. It belongs to the UNION:
#
#   every probe in the declared corpus is REACHED (pass or fail) in at least one
#   environment.
#
# REACHED means the probe RAN and reached a verdict about the rail — `pass` or
# `fail`. Deliberately NOT `not-reached` (nothing was measured) and NOT `error`
# (the probe itself broke before it could measure, which is a finding about the
# probe, not an observation of the rail).
#
# The corpus is READ FROM THE REPORTS, never restated here. Two corpus lists
# written in two places are one contract with two authors, and when they drift the
# consumer refuses a state only the producer can mint (DIVE-2004). All reports must
# agree on it, or that disagreement is itself the finding.
#
# FAILS CLOSED. No reports, an unreadable report, a report with no header, or
# reports that disagree about the corpus are all non-zero — because in CI a job
# that died before writing its report would otherwise silently shrink the union to
# whatever survived, and a shrunken union is indistinguishable from a complete one.
set -uo pipefail

usage() {
  cat <<'USAGE'
selfcheck-union.sh <report>...

Asserts every probe in the declared corpus was REACHED (pass|fail) by at least one
of the given `5dive selfcheck --report=<file>` reports.

exit 0  every probe reached somewhere
exit 1  a probe reached nowhere, or a report is missing/malformed/about another corpus
exit 2  usage (no reports given)
USAGE
}

REPORTS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    -*) printf 'unknown arg: %s\n' "$a" >&2; usage >&2; exit 2 ;;
    *) REPORTS+=("$a") ;;
  esac
done

# Zero reports is a usage error, NOT a vacuous pass. "No evidence" and "evidence of
# full coverage" are the two states this whole script exists to keep apart.
if (( ${#REPORTS[@]} == 0 )); then
  printf 'selfcheck-union: no reports given — refusing to declare coverage over nothing\n' >&2
  usage >&2
  exit 2
fi

declare -A REACHED=()     # probe -> 1 once any environment reached a verdict
declare -A SEEN=()        # "probe|label" -> verdict, for the failure message
CORPUS=""                 # the probe list every report must agree on
CORPUS_FROM=""            # which report declared it, so a mismatch names both
ALLOW=""; ALLOW_SET=0     # probes the DEPLOYMENT cannot reach, read from the reports
LABELS=()
RC=0

for r in "${REPORTS[@]}"; do
  if [[ ! -r "$r" ]]; then
    printf 'selfcheck-union: FAIL — report not readable: %s\n' "$r" >&2
    printf '  a report that did not arrive is not a report about a clean run.\n' >&2
    RC=1; continue
  fi
  hdr_probes=$(sed -n 's/^# probes=//p' "$r" | head -1)
  hdr_label=$(sed -n 's/^# label=//p' "$r" | head -1)
  hdr_allow=$(sed -n 's/^# allow=//p' "$r" | head -1)
  if ! grep -q '^# selfcheck report$' "$r" || [[ -z "$hdr_probes" ]]; then
    printf 'selfcheck-union: FAIL — %s is not a selfcheck report (no header / no corpus line)\n' "$r" >&2
    RC=1; continue
  fi
  [[ -n "$hdr_label" ]] || hdr_label="$(basename "$r")"
  if [[ -z "$CORPUS" ]]; then
    CORPUS="$hdr_probes"; CORPUS_FROM="$hdr_label"
  elif [[ "$CORPUS" != "$hdr_probes" ]]; then
    # The DIVE-2018 signature itself: two green runs about DIFFERENT corpora, with
    # nothing anywhere saying so.
    printf 'selfcheck-union: FAIL — %s and %s are not about the same code\n' "$CORPUS_FROM" "$hdr_label" >&2
    printf '  %s: %s\n  %s: %s\n' "$CORPUS_FROM" "$CORPUS" "$hdr_label" "$hdr_probes" >&2
    RC=1; continue
  fi
  # The allowlist is one contract. Reports that disagree on it are two authors, and
  # the disagreement is itself the finding — never silently unioned or intersected.
  if (( ALLOW_SET == 0 )); then
    ALLOW="$hdr_allow"; ALLOW_SET=1
  elif [[ "$ALLOW" != "$hdr_allow" ]]; then
    printf 'selfcheck-union: FAIL — %s and %s disagree about the allowlist\n' "$CORPUS_FROM" "$hdr_label" >&2
    printf '  %s: [%s]\n  %s: [%s]\n' "$CORPUS_FROM" "$ALLOW" "$hdr_label" "$hdr_allow" >&2
    RC=1; continue
  fi
  LABELS+=("$hdr_label")
  while IFS=$'\t' read -r verdict probe _reason; do
    [[ -n "${verdict:-}" && "$verdict" != \#* ]] || continue
    [[ -n "${probe:-}" ]] || continue
    SEEN["$probe|$hdr_label"]="$verdict"
    case "$verdict" in
      pass|fail) REACHED["$probe"]=1 ;;
      *) : ;;   # not-reached / error are not observations of the rail
    esac
  done < "$r"
done

(( RC == 0 )) || exit "$RC"

# An empty corpus must not report 100% coverage of nothing.
IFS=',' read -r -a PROBES <<< "$CORPUS"
if (( ${#PROBES[@]} == 0 )) || [[ -z "${PROBES[0]}" ]]; then
  printf 'selfcheck-union: FAIL — the reports declare an empty probe corpus\n' >&2
  exit 1
fi

declare -A ALLOWED=()
IFS=',' read -r -a _al <<< "$ALLOW"
for a in "${_al[@]+"${_al[@]}"}"; do [[ -n "$a" ]] && ALLOWED["$a"]=1; done
# A stale allowlist name is drift worth SAYING and not worth reddening — it can only
# ever excuse nothing.
for a in "${!ALLOWED[@]}"; do
  grep -qx "$a" <<<"$(printf '%s\n' "${PROBES[@]}")" \
    || printf 'selfcheck-union: note — allowlisted probe "%s" is not in the corpus (stale name)\n' "$a" >&2
done

missing=0
for p in "${PROBES[@]}"; do
  [[ -n "$p" ]] || continue
  if [[ -n "${ALLOWED[$p]:-}" ]]; then
    printf 'allowlisted   %s (declared unreachable by this deployment)\n' "$p"
    continue
  fi
  if [[ -z "${REACHED[$p]:-}" ]]; then
    missing=$((missing+1))
    printf 'NEVER REACHED  %s\n' "$p" >&2
    for l in "${LABELS[@]}"; do
      printf '    %s=%s\n' "$l" "${SEEN[$p|$l]:-absent}" >&2
    done
  fi
done

if (( missing )); then
  printf 'selfcheck-union: FAIL — %d of %d probes reached no verdict in ANY environment (%s)\n' \
    "$missing" "${#PROBES[@]}" "$(IFS=,; echo "${LABELS[*]}")" >&2
  printf '  a probe that is excusably not-reached everywhere is permanently unmeasured and permanently green.\n' >&2
  exit 1
fi

printf 'selfcheck-union: OK — all %d probes reached in the union of %d environment(s): %s\n' \
  "${#PROBES[@]}" "${#LABELS[@]}" "$(IFS=,; echo "${LABELS[*]}")"
exit 0
