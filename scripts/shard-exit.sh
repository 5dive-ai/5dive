#!/usr/bin/env bash
# DIVE-4229 — TRANSLATE A HARNESS SHARD'S EXIT CODE INTO A CI VERDICT.
#
# `scripts/run-harnesses.sh` already distinguishes GRADED from UNGRADED, and has
# since DIVE-2728: exit 1 is a failing harness, exit 4 is a corpus measured over
# its cap, exit 5 is the opt-in drift gate — and exit 6 is the slot every arm that
# COULD NOT GRADE resolves into (the calibration clamp, an over-budget verdict no
# second runner has confirmed, an over-budget total attributed to the runner). The
# script's own text says so: "this is exit 6, NOT exit 4: nothing says your corpus
# is over".
#
# CI threw that distinction away. A step that ends non-zero reds the job whatever
# the number meant, so an ungraded shard reached release-cut and the merge queue as
# a RED — and release-cut refuses on ANY red without reading which red it is.
#
# MEASURED 2026-09-10, run 34470906776 (main @599c1f5), the cut that this row was
# filed on. full-installed-host (2): 169 harnesses, 863s against a 1320s cap — 65%
# of budget, ZERO failing harnesses — and the calibration probe drew 243% of
# baseline, past the 150% clamp, so the run printed UNDETERMINED and exited 6. The
# cut then read "CI is RED on 599c1f5910d7 — refusing to cut v0.31.0. Failing:
# full-installed-host (2)". Nothing on that sha was red. The v0.31.0 cut was
# refused, and DIVE-4206's heartbeat fix stayed merged-and-unreleased.
#
# WHAT THIS IS NOT. It does not touch exit 1 or exit 4 and must never be extended
# to. Shard 1 of that same run WAS a real budget red — 1565s against the 1320s cap,
# 118%, re-timed and CONFIRMED at 118% on a second sample — and it still reds here.
# A graded verdict is not what was mis-rendered; an ungraded one was.
#
# AND THE HEADER-DRIFT LINT IS NOT THE PRODUCER, though it is printed two lines
# above the exit and was read as one when this row was filed. With `policy off`
# (the default since DIVE-3163) the drift arm exits nothing at all — the exit is
# the calibration clamp's. Fixing the drift lint would have changed no exit code.
#
# THE SIGNAL MUST NOT VANISH, which is the whole risk of turning a red green: an
# ungraded shard is a shard whose budget was NOT measured, and silence would read
# as "measured, fine". So this emits a GitHub `::warning::` annotation (visible on
# the job, the PR and the run summary) naming the shard and the reason, and prints
# the same fact on stdout for the log the harvester parses.
#
# Usage: shard-exit.sh <rc> <label> [<report-file>]
#        exit 6 -> annotate, exit 0.   everything else -> exit <rc> unchanged.
set -uo pipefail

rc="${1:-}"; label="${2:-shard}"; report="${3:-}"

[[ "$rc" =~ ^[0-9]+$ ]] || {
  printf 'shard-exit: refusing a non-numeric rc %s (label %s)\n' "${rc:-<empty>}" "$label" >&2
  exit 2
}

# Only the ungraded slot is translated. Listed as an explicit equality rather than
# a range so widening it is a visible edit and not an off-by-one.
if [[ "$rc" != "6" ]]; then
  exit "$rc"
fi

# WHY it could not grade, read back from the report the run just wrote. The report
# is the graded record; this is a label for a human, so an unreadable or missing
# report degrades to the generic reason rather than to a red — the exit code
# already told us the shard was ungraded, and no report can un-tell us.
reason="ungraded (run-harnesses.sh exit 6)"
if [[ -n "$report" && -r "$report" ]]; then
  # THE FIELD NAMES ARE THE REPORT'S, READ OFF THE WRITER (run-harnesses.sh, the
  # `> "$REPORT"` block) rather than guessed from the log prose: `budget_attribution`,
  # not `attr_verdict`, and `cross_runner_state` whose UNCONFIRMED values are the
  # three that are not `confirmed` -- `single`, `same` and `unidentified` -- so there
  # is no literal `unconfirmed` to match. A name that matches nothing degrades to the
  # generic reason silently, which is the failure this comment exists to prevent, so
  # the harness DERIVES the three field names from run-harnesses.sh's own report
  # writer and reds if either side renames one.
  if grep -q '^# undetermined=1' "$report" 2>/dev/null; then
    reason="the calibration probe drew past its clamp, so the budget could not be graded on this runner"
  elif grep -qE '^# cross_runner_state=(single|same|unidentified)' "$report" 2>/dev/null; then
    reason="over budget on ONE box, not yet confirmed by a second runner"
  elif grep -q '^# budget_attribution=runner' "$report" 2>/dev/null; then
    reason="over budget, and the baseline comparison attributes the overrun to the RUNNER"
  fi
fi

printf '::warning title=harness budget UNGRADED (%s)::%s — the corpus was NOT measured against its cap on this runner. This is not a red: no harness failed and no over-budget verdict stands. run-harnesses.sh exit 6, translated by scripts/shard-exit.sh (DIVE-4229).\n' \
  "$label" "$reason"
printf 'shard-exit[%s]: UNGRADED (exit 6 -> 0) — %s\n' "$label" "$reason"
exit 0
