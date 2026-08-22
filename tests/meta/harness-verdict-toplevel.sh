#!/usr/bin/env bash
# DIVE-3679: RED ON A TOP-LEVEL VERDICT VIOLATION, NOT ON `not-reached`.
#
# WHY NOT `not-reached`, which is what DIVE-3678 proposed. The `changed-harnesses`
# job is ONE `runs-on: ubuntu-latest` runner: one checkout, one ./build.sh, one
# setup-bun, one probe pass. No matrix, no installed host. So "not-reached in every
# environment this lane can offer" evaluates, here, to "not-reached in one pristine
# run" — which is precisely the false accusation DIVE-2039 exists to prevent, aimed
# at the whole class of harnesses whose verdict is legitimately reachable only on an
# installed host with real sudo and seeded host state. `not-reached` is a claim about
# THIS environment; "runs nowhere" is a claim about the UNION of environments, and no
# single lane can make it however it is wired — adding an installed-host job makes
# N=2 against a union of 7 and only moves the boundary.
#   community/wiki/the-pr-harness-lane-is-one-environment-so-not-reached-cannot-be-the-guard.md
#
# WHAT IS SOUND IN ONE ENVIRONMENT is the STATIC property: the probe's INJECTION
# POINT — immediately above the terminal verdict-shaped line — must be a top-level
# statement boundary, not a position inside an arm. That is a property of the DIFF,
# decidable here, and it accuses nobody for skipping: an installed-host-only harness
# with a top-level terminal verdict passes, and the harness that broke the v0.21.3
# cut fails. It is decided by BASH'S OWN PARSER, not by indentation and not by a
# hand-rolled lexer — see tests/lib/harness-verdict-detect.sh for what that cost.
#
# THIS IS A COMPLEMENT TO THE PROBE, NEVER A REPLACEMENT. The probe's own header
# records that static analysis cannot close the DIVE-2013 class (three instruments
# measured, all agreeing, none sound: a harness whose assertions never fire, a
# verdict before the last assertion, a `set -e` verdict bypassed). Top-level-NESS of
# the terminal verdict-shaped line is a strictly NARROWER claim than "the verdict is
# wired", so it does not inherit that refutation — and it must never be cited as
# doing the probe's job. And hardening `changed-harnesses` is hardening the
# INSTRUMENT; the union's whole-corpus claim is still the product.
#   community/wiki/a-test-of-the-instrument-is-not-an-exit-from-the-gate.md
#
# NO THIRD ALLOWLIST. `ALLOW_UNPROBEABLE` means "no identifiable verdict variable"
# and `SLOW_HARNESSES` means "killed by the timeout"; neither is this. A harness that
# is genuinely live-only does not need an exemption, because it can always be GIVEN a
# top-level terminal verdict — that is exactly what the DIVE-3675 fix did (`return`
# out of `live_arms()` instead of `exit` from mid-file, behaviour and exit status
# unchanged). A list created before a case requires it is a widened safety control
# with nothing measured behind it.
#
# NO IDENTIFIABLE VERDICT IS NOT A FINDING HERE. If counter_verdict cannot name a
# verdict variable, this prints `no-verdict-line` and does not fail: that condition
# is the probe's UNPROBEABLE, it already fails there, and a second accusation path
# for the same condition would let the two instruments disagree about the same file.
#
# Usage:
#   harness-verdict-toplevel.sh --only=a.sh,b.sh [--label=changed] [--report=f] [--enforce]
#   harness-verdict-toplevel.sh tests/foo.sh tests/bar.sh
# WARN-ONLY IS THE DEFAULT and `--enforce` is opt-in, per this row: the guard must
# not fail anything until both negative-control arms are on the row.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
# shellcheck source=tests/lib/harness-verdict-detect.sh
source tests/lib/harness-verdict-detect.sh

ONLY=""; LABEL=""; REPORT=""; ENFORCE=0; FILES=()
for a in "$@"; do case "$a" in
  --only=*)   ONLY="${a#--only=}" ;;
  --label=*)  LABEL="${a#--label=}" ;;
  --report=*) REPORT="${a#--report=}" ;;
  --enforce)  ENFORCE=1 ;;
  --warn-only) ENFORCE=0 ;;
  -*) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
  *)  FILES+=("$a") ;;
esac; done

if (( ${#FILES[@]} == 0 )) && [[ -n "$ONLY" ]]; then
  only_set=" ${ONLY//,/ } "
  for t in tests/*.sh; do
    [[ -e "$t" ]] || continue
    [[ "$only_set" == *" $(basename "$t") "* ]] && FILES+=("$t")
  done
fi
# An EMPTY selection with no selector is "nothing was asked", which is fine. An
# empty selection from a NON-EMPTY --only is a selector that matched nothing, and
# reporting that as a pass is the shape of hole this whole workflow exists to close.
if (( ${#FILES[@]} == 0 )); then
  if [[ -n "$ONLY" ]]; then
    printf 'harness-verdict-toplevel: BLOCKED — --only=%s matched no tests/*.sh; refusing to report clean on a selection that never resolved.\n' "$ONLY" >&2
    exit 1
  fi
  printf 'harness-verdict-toplevel: nothing selected, nothing to grade.\n'
  exit 0
fi

OK=(); VIOLATION=(); NOVERDICT=()
for f in "${FILES[@]}"; do
  b=$(basename "$f")
  # BOTH probe families, selected exactly as harness-verdict-probe.sh selects them —
  # the counter family (mutate the verdict variable, injected before its line) and the
  # ABORT family (`set -e` plus bare assertions, a `false` injected before the LAST
  # executable line). Grading only the counter family would have left 25 of the 444
  # harnesses on origin/main silently ungraded: the check would print a clean pass on
  # files it never looked at, which is the hole this workflow exists to close.
  cv=$(counter_verdict "$f") || cv=""
  if [[ -n "$cv" ]]; then
    var=$(cut -f1 <<<"$cv"); ln=$(cut -f2 <<<"$cv"); pos=$(cut -f3 <<<"$cv")
  elif grep -qE '^set -[a-z]*e' "$f"; then
    ln=$(grep -nvE '^[[:space:]]*(#|$)' "$f" | tail -1 | cut -d: -f1)
    var="(abort family: 'false' under set -e)"; pos="last"
  else
    # Neither family: the probe reports this as UNPROBEABLE and FAILS there. A second
    # accusation path for the same condition would let the two instruments disagree
    # about the same file, so this is reported and is not a finding here.
    NOVERDICT+=("$b")
    printf '  %-52s no-verdict-line (no counter, no `set -e` — the probe owns this as UNPROBEABLE)\n' "$b"
    continue
  fi
  if why=$(verdict_injection_point_top_level "$f" "$ln"); then
    OK+=("$b")
    printf '  %-52s ok        verdict `%s` at line %s (%s), injection point at top level\n' "$b" "$var" "$ln" "$pos"
  else
    VIOLATION+=("$b:$ln")
    printf '  %-52s VIOLATION verdict `%s` at line %s (%s executable line): the probe injects immediately above it, and lines 1-%s are not a complete program — bash says:\n' \
      "$b" "$var" "$ln" "$pos" "$(( ln - 1 ))"
    printf '      %s\n' "$why"
  fi
done

printf '\nharness-verdict-toplevel%s: %d ok, %d VIOLATION, %d no-verdict-line (of %d selected)\n' \
  "${LABEL:+ [$LABEL]}" "${#OK[@]}" "${#VIOLATION[@]}" "${#NOVERDICT[@]}" "${#FILES[@]}"
# DIVE-3679: assert the buckets sum to N. A file that fell out of every bucket would
# read as a clean pass on a harness nobody looked at.
sum=$(( ${#OK[@]} + ${#VIOLATION[@]} + ${#NOVERDICT[@]} ))
if (( sum != ${#FILES[@]} )); then
  printf 'harness-verdict-toplevel: BLOCKED — buckets sum to %d against %d selected; a harness fell out of every bucket.\n' "$sum" "${#FILES[@]}" >&2
  exit 1
fi
if [[ -n "$REPORT" ]]; then
  { printf '# harness-verdict-toplevel label=%s selected=%d\n' "${LABEL:-none}" "${#FILES[@]}"
    for x in "${OK[@]:-}";        do [[ -n "$x" ]] && printf 'ok\t%s\n' "$x"; done
    for x in "${VIOLATION[@]:-}"; do [[ -n "$x" ]] && printf 'violation\t%s\n' "$x"; done
    for x in "${NOVERDICT[@]:-}"; do [[ -n "$x" ]] && printf 'no-verdict-line\t%s\n' "$x"; done
  } > "$REPORT"
fi

if (( ${#VIOLATION[@]} == 0 )); then exit 0; fi
cat >&2 <<'MSG'

A harness's terminal verdict-shaped line sits inside an arm rather than at top level.
harness-verdict-probe.sh injects its mutation immediately before that line, so in any
environment that does not enter the arm the mutation never executes and the probe
reports `not-reached`. That is tolerated per-environment and correctly so — and when
it happens in ALL of them the nightly union reports NEVER PROBED and refuses the
release cut. It has cost the train twice: DIVE-3148 and DIVE-3675.

The fix is not an allowlist. Give the harness ONE terminal verdict at top level,
after the last arm — `return` out of the arm's function instead of `exit`ing from
mid-file, and end the file in the verdict expression. Behaviour and exit status do
not change; see tests/buzz_preseed_dm_live.sh and commit 07a4345.
MSG
if (( ENFORCE )); then exit 1; fi
printf 'harness-verdict-toplevel: WARN-ONLY (--enforce not passed) — reporting, not failing.\n' >&2
exit 0
