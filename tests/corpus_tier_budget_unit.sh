#!/usr/bin/env bash
# DIVE-2525 isolated unit harness for the two halves of the corpus wall-clock
# budget: the tier resolver (tests/lib/tier.sh) and the budgeted runner
# (scripts/run-harnesses.sh).
#
# WHY THIS FILE IS ITSELF SMALL AND FAST, and says so. It is a harness added by the
# row whose whole subject is that harnesses are added faster than they are retired.
# The honest version of that is not to skip the coverage — it is to pay the budget
# it enforces. Throwaway corpus of three one-line harnesses, no sleeps longer than
# the assertion needs, and every arm below is one this mechanism can actually get
# wrong.
#
# THE ARMS, and the mutation each one would catch:
#   1-3   default is core; an explicit `# TIER: core` is legal; a marker below the
#         header window does not demote. (Flipping the default to nightly would
#         empty the PR path and nothing else here would notice.)
#   4-5   a nightly demotion with no reason REFUSES (exit 3), and a `# TIER:` line
#         naming an unknown tier REFUSES. This is the reverse gear: a demotion that
#         costs nothing to write is a second budget nobody watches.
#   6-8   tier_list partitions core/nightly and `full` is their union — the property
#         that makes "the nightly sweep still runs everything" true rather than
#         asserted. And a corpus containing ONE unclassifiable file makes the whole
#         listing refuse, rather than silently returning the subset it understood.
#   9-12  the runner: over budget exits 4 and names the slowest; a FAILING harness
#         exits 1 even when also over budget (the failure is what you fix first);
#         an empty selection is exit 1, never a green run over nothing; the report
#         carries the wall-clock header the nightly summary reads.
#  13-14  the over-budget message actually names a remedy and the slowest file —
#         a budget that reds without saying what to retire is a warning with a
#         worse exit code (feedback: grade the REMEDY half, not only the predicate).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TIER_LIB="tests/lib/tier.sh"
RUNNER="scripts/run-harnesses.sh"
TMP="$(mktemp -d /tmp/corpus-tier-budget.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
want() { # want <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# shellcheck source=tests/lib/tier.sh
. "$TIER_LIB"

mk() { printf '%s\n' "$2" > "$TMP/$1"; }

# ---------------------------------------------------------------- 1-3 resolution
mk plain.sh '#!/usr/bin/env bash
echo plain'
want "default tier is core" "core" "$(tier_of "$TMP/plain.sh")"

mk explicit_core.sh '#!/usr/bin/env bash
# TIER: core
echo core'
want "an explicit core marker is legal" "core" "$(tier_of "$TMP/explicit_core.sh")"

# A marker outside the 40-line header window must not demote. The window is what
# stops a string in a fixture, an assertion or a heredoc from moving a harness out
# of the PR path silently.
{ printf '#!/usr/bin/env bash\n'; for i in $(seq 45); do printf '# filler %s\n' "$i"; done
  printf '# TIER: nightly — far below the header window\n'; printf 'echo late\n'; } > "$TMP/late_marker.sh"
want "a marker below the header window does not demote" "core" "$(tier_of "$TMP/late_marker.sh")"

# ---------------------------------------------------------------- 4-5 refusals
mk bare_nightly.sh '#!/usr/bin/env bash
# TIER: nightly
echo bare'
out="$(tier_of "$TMP/bare_nightly.sh" 2>&1)"; rc=$?
if (( rc == 3 )) && [[ "$out" == *"no reason"* ]]; then
  ok "an unjustified demotion REFUSES (exit 3)"
else
  bad "an unjustified demotion REFUSES (exit 3)" "rc=$rc out=$out"
fi

mk bogus_tier.sh '#!/usr/bin/env bash
# TIER: weekly — only on Tuesdays
echo bogus'
out="$(tier_of "$TMP/bogus_tier.sh" 2>&1)"; rc=$?
if (( rc == 3 )) && [[ "$out" == *"unknown tier"* ]]; then
  ok "an unknown tier REFUSES rather than defaulting either way"
else
  bad "an unknown tier REFUSES rather than defaulting either way" "rc=$rc out=$out"
fi

# ---------------------------------------------------------------- 6-8 selection
rm -f "$TMP"/*.sh
mk a_core.sh '#!/usr/bin/env bash
exit 0'
mk b_core.sh '#!/usr/bin/env bash
exit 0'
mk c_night.sh '#!/usr/bin/env bash
# TIER: nightly — 40s of container setup, cannot fit the PR core
exit 0'
want "core selects only the core harnesses" \
  "a_core.sh b_core.sh" "$(tier_list core "$TMP" | xargs -n1 basename | paste -sd' ' -)"
want "nightly selects only the demoted harnesses" \
  "c_night.sh" "$(tier_list nightly "$TMP" | xargs -n1 basename | paste -sd' ' -)"
want "full is the union, so the nightly sweep still runs everything" \
  "a_core.sh b_core.sh c_night.sh" "$(tier_list full "$TMP" | xargs -n1 basename | paste -sd' ' -)"

mk d_bogus.sh '#!/usr/bin/env bash
# TIER: fortnightly — nope
exit 0'
tier_list core "$TMP" >/dev/null 2>&1; rc=$?
want "one unclassifiable file makes the WHOLE listing refuse" "3" "$rc"
rm -f "$TMP/d_bogus.sh"

# ---------------------------------------------------------------- 9-14 the runner
# Two cheap harnesses and one that burns a second, so a 1-second budget is
# genuinely exceeded by measured time rather than by a constant in the assertion.
rm -f "$TMP"/*.sh
mk fast_one.sh '#!/usr/bin/env bash
exit 0'
mk slow_one.sh '#!/usr/bin/env bash
sleep 1.2
exit 0'

run() { OUT="$(bash "$RUNNER" --corpus-dir="$TMP" "$@" 2>&1)"; RC=$?; }

run --tier=core --budget=1 --label=t
want "over budget exits 4 (not 1 — a slow suite is not a broken one)" "4" "$RC"
if [[ "$OUT" == *"OVER BUDGET"* ]]; then ok "over-budget run says so in its output"
else bad "over-budget run says so in its output" "$OUT"; fi

# The remedy half. A budget that reds without naming the file to merge, retire or
# demote is a warning with a worse exit code, and the whole finding behind this row
# is that a number nobody can act on gets read by nobody.
if [[ "$OUT" == *"slow_one.sh"* ]]; then ok "over-budget output NAMES the slowest harness"
else bad "over-budget output NAMES the slowest harness" "$OUT"; fi
if [[ "$OUT" == *"MERGE by subject"* && "$OUT" == *"RETIRE"* && "$OUT" == *"TIER: nightly"* ]]; then
  ok "over-budget output names all three remedies (merge / retire / demote)"
else bad "over-budget output names all three remedies (merge / retire / demote)" "$OUT"; fi

run --tier=core --budget=600 --label=t
want "inside budget exits 0" "0" "$RC"
if [[ "$OUT" == *"harness-budget[core/t]"* && "$OUT" == *"% of budget)"* ]]; then
  ok "every run prints the number and the percentage of budget"
else bad "every run prints the number and the percentage of budget" "$OUT"; fi

# A FAILING harness dominates an over-budget one: same run, both true, exit 1.
mk red_one.sh '#!/usr/bin/env bash
exit 1'
run --tier=core --budget=1 --label=t
want "a failing harness dominates over-budget (exit 1, not 4)" "1" "$RC"
if [[ "$OUT" == *"FAILED: $TMP/red_one.sh"* ]]; then ok "the failing harness is named"
else bad "the failing harness is named" "$OUT"; fi
rm -f "$TMP/red_one.sh"

run --tier=core --budget=600 --label=t --report="$TMP/rep.txt"
hdr_s="$(sed -n 's/^# wall_clock_s=//p' "$TMP/rep.txt")"
hdr_n="$(sed -n 's/^# harnesses=//p' "$TMP/rep.txt")"
if [[ -n "$hdr_s" && "$hdr_n" == 2 ]]; then
  ok "the report carries the header the nightly summary reads"
else
  bad "the report carries the header the nightly summary reads" "harnesses=[$hdr_n] wall_clock_s=[$hdr_s]"
fi

# An empty selection is UNDETERMINED, never clean: `for t in <nothing>` passes
# loudly, having graded nothing (the grade-release-commit.sh lesson).
mkdir -p "$TMP/empty"
run --tier=core --budget=600 --corpus-dir="$TMP/empty" 2>/dev/null || true
OUT="$(bash "$RUNNER" --tier=core --budget=600 --corpus-dir="$TMP/empty" 2>&1)"; RC=$?
if (( RC == 1 )) && [[ "$OUT" == *"not a green one"* ]]; then
  ok "an empty corpus FAILS rather than passing over nothing"
else
  bad "an empty corpus FAILS rather than passing over nothing" "rc=$RC out=$OUT"
fi

# --------------------------------------------- 15-16 the precondition tiering exposed
# MEASURED on this row's own first CI run: install_checksum_unit.sh, ledger_unit.sh and
# policy_refusals_unit.sh went red in BOTH core jobs. They need ./5dive and
# ./5dive.sha256 and say so in their own failure text — and no job ever built them.
# They passed for months because SOME EARLIER HARNESS in the 267-file glob runs
# ./build.sh as a side effect and leaves the artifact in the working tree for
# everything after it. The corpus was ORDER-DEPENDENT through a shared file, and
# running a SUBSET is what exposed it: same code, same runner, three reds.
#
# An implicit precondition that a full sweep happens to satisfy is not satisfied, it
# is UNOBSERVED. So every job that runs harnesses declares it, and this arm holds that
# open — it is the cheapest possible check (a grep over two YAML files, no runtime) and
# it guards the exact defect that cost this PR a CI round trip.
jobs_missing_build() {   # <workflow> -> job names that run harnesses without building
  # Only below `jobs:` — the `on:` block has two-space keys too, and full-sweep.yml
  # lists scripts/run-harnesses.sh among its pull_request paths, which read as a
  # harness-running "job" named `schedule`. First version of this arm did exactly
  # that and was red for a reason with nothing to do with the invariant.
  awk '
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    !injobs { next }
    /^  [a-z][a-z0-9-]*:[[:space:]]*$/ { if (job != "" ) emit(); job=$1; sub(/:$/,"",job); runs=0; built=0; next }
    # COMMENTS ARE NOT STEPS. Second version of this arm matched the prose — the
    # comment above the build step names ./build.sh, so deleting the step left the
    # explanation of the step behind and the check stayed green. Both mutations
    # passed. A guard that reads the sentence describing the mechanism instead of
    # the mechanism is the vacuity this corpus keeps re-learning.
    /^[[:space:]]*#/ { next }
    /run-harnesses\.sh|harness-verdict-probe\.sh/ { runs=1 }
    /^[[:space:]]*(run:[[:space:]]*)?\.\/build\.sh/ { built=1 }
    END { emit() }
    function emit() { if (job != "" && runs && !built) print job }
  ' "$1"
}
for wf in .github/workflows/unit-tests.yml .github/workflows/full-sweep.yml; do
  miss="$(jobs_missing_build "$wf" | paste -sd, -)"
  if [[ -z "$miss" ]]; then
    ok "every harness-running job in ${wf##*/} builds the bundle first"
  else
    bad "every harness-running job in ${wf##*/} builds the bundle first" "missing in: $miss"
  fi
done

# ---------------------------------------------------- 17-20 sharding is a PARTITION
# main's call reviewing #376: the first measured sweep came in at 83-86% of its own
# cap, so the sweep is SHARDED rather than given a bigger number — the cap is per job,
# and splitting cuts each job's wall-clock without relaxing the constraint.
#
# That is only sound if the shards PARTITION the corpus. A split that drops a harness
# is a corpus that shrank silently, which is the failure this whole file is about;
# a split that duplicates one just wastes the budget it exists to protect. So: union
# equals the full tier, no overlap, and nothing selects an empty set in silence.
rm -f "$TMP"/*.sh
for i in 1 2 3 4 5 6 7; do mk "s$i.sh" '#!/usr/bin/env bash
exit 0'; done
ran() { bash "$RUNNER" --corpus-dir="$TMP" --tier=full --budget=600 "$@" 2>&1 \
          | sed -n 's|^=== .*/||p' | sort; }
u="$(for i in 1 2 3; do ran --shard=$i/3; done | sort)"
flat() { tr '\n' ' ' | sed 's/ *$//'; }
want "the shards' union is the whole tier" \
  "$(ran | flat)" "$(printf '%s\n' "$u" | flat)"
want "no harness runs twice across the shards" \
  "$(printf '%s\n' "$u" | wc -l)" "$(printf '%s\n' "$u" | sort -u | wc -l)"
# Round-robin, not contiguous blocks: with a long-tailed cost distribution (one
# harness is 300s, the median is under a second) contiguous blocks put a whole
# alphabetical neighbourhood of expensive e2e files in one shard.
want "shard 1 of 3 takes every third harness, not the first third" \
  "s1.sh s4.sh s7.sh" "$(ran --shard=1/3 | tr '\n' ' ' | sed 's/ $//')"

OUT="$(bash "$RUNNER" --corpus-dir="$TMP" --tier=full --shard=4/3 2>&1)"; RC=$?
if (( RC == 2 )) && [[ "$OUT" == *"out of range"* ]]; then
  ok "an out-of-range shard REFUSES"
else bad "an out-of-range shard REFUSES" "rc=$RC out=$OUT"; fi

# 9 shards over 7 files: shard 8 selects nothing. Green-over-nothing, per shard.
OUT="$(bash "$RUNNER" --corpus-dir="$TMP" --tier=full --shard=8/9 2>&1)"; RC=$?
if (( RC == 1 )) && [[ "$OUT" == *"selected 0 harnesses"* ]]; then
  ok "a shard that selects nothing FAILS rather than reporting green over nothing"
else bad "a shard that selects nothing FAILS rather than reporting green over nothing" "rc=$RC out=$OUT"; fi


# ------------------------------------------- 17-22 DIVE-2555: the CLOCK vs the CLAIM
# MERGED HERE, NOT GIVEN A NEW FILE. This row's own rule is that past the cap a new
# guard replaces or merges an existing one, and the subject is the same subject: what
# the corpus's clock is allowed to be reported as. Two claims about a reading of it —
# a HEADER's "Ns measured" and the probe's TIMEOUT KILL — and neither may be reported
# as something it is not.
#
# WHY THIS EXISTS (DIVE-2555, measured 2026-08-03): a demotion is argued in the diff
# with a number, and gate_channel_session_t2_mutation.sh claimed 300.0s while running
# 335s on the control plane. Nothing had ever re-read that number. The runner already
# times every harness, so grading the claim against the measurement is free.
rm -f "$TMP"/*.sh
mk truthful.sh '#!/usr/bin/env bash
# TIER: nightly — 10.0s measured (DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
exit 0'
mk stale_claim.sh '#!/usr/bin/env bash
# TIER: nightly — 0.5s measured (DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
sleep 2
exit 0'
run --tier=full --budget=600 --label=t
want "a header the clock only mildly refutes is REPORTED, not red (that band is runner variance)" "0" "$RC"
if [[ "$OUT" == *"HEADER MEASUREMENT"* && "$OUT" == *"stale"* && "$OUT" == *"stale_claim.sh"* ]]; then
  ok "the drifted header is named, with its severity"
else bad "the drifted header is named, with its severity" "$OUT"; fi
# The remedy half again: a drift report that does not print the replacement line is a
# number nobody can act on, which is the finding this whole row descends from.
if [[ "$OUT" == *"# TIER: nightly —"* && "$OUT" == *"measured (t,"* ]]; then
  ok "the drift report prints the REPLACEMENT header line, with the environment in it"
else bad "the drift report prints the REPLACEMENT header line, with the environment in it" "$OUT"; fi
# Scoped to the DRIFT BLOCK, not to the whole output: the runner echoes every harness
# path as it runs it, so "truthful.sh appears somewhere in stdout" is true of every
# run and asserting on it grades nothing. First version of this arm did exactly that.
DRIFT_BLOCK="$(printf '%s\n' "$OUT" | sed -n '/HEADER MEASUREMENT/,$p')"
if [[ -n "$DRIFT_BLOCK" && "$DRIFT_BLOCK" != *"truthful.sh"* ]]; then
  ok "a header the clock AGREES with is not accused"
else bad "a header the clock AGREES with is not accused" "$DRIFT_BLOCK"; fi

# >= 50% AND >= 3s under is not variance: exit 5, its own code, because the remedy is
# neither "fix a test" (1) nor "retire a guard" (4) but "correct a number in a header".
mk wrong_claim.sh '#!/usr/bin/env bash
# TIER: nightly — 0.5s measured (DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
sleep 4
exit 0'
rm -f "$TMP/stale_claim.sh"
run --tier=full --budget=600 --label=t
want "a header the clock flatly refutes exits 5 (not 1, not 4)" "5" "$RC"
if [[ "$OUT" == *"WRONG"* && "$OUT" == *"not runner variance"* ]]; then
  ok "the refuted header is called WRONG and the message says why it is not variance"
else bad "the refuted header is called WRONG and the message says why it is not variance" "$OUT"; fi

# A harness that FAILED is not accused of drift: an aborted run's wall-clock is not a
# measurement of what it costs, and the failure is the thing to fix first (exit 1).
rm -f "$TMP/wrong_claim.sh"
mk red_claim.sh '#!/usr/bin/env bash
# TIER: nightly — 0.5s measured (DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
sleep 4
exit 1'
run --tier=full --budget=600 --label=t
if (( RC == 1 )) && [[ "$OUT" != *"red_claim.sh"*"claims"* ]]; then
  ok "a FAILING harness is not also accused of header drift"
else bad "a FAILING harness is not also accused of header drift" "rc=$RC out=$OUT"; fi

# ------------------------------------ 23-25 DIVE-2555: a TIMEOUT KILL is not a verdict
# tests/meta/harness-verdict-probe.sh runs every harness under `timeout`. A kill used
# to be laundered into two verdicts that are about the harness rather than the clock:
# a killed CLEAN run became `already-red` ("failed its own clean run" — an accusation
# about assertions, on evidence entirely about time), and a killed MUTANT became
# `wired` whenever the canary had already printed, which is a FALSE PASS in the
# coverage direction: the non-zero exit came from the KILL, not from the harness's
# verdict. DIVE-2412 paid for this once already — 300s of mutation grader killed at
# the 180s cap in every environment, reported as `not-reached`, i.e. "skips early
# here", which it never did.
#
# Graded with a 1s cap against ONE real harness (`--only`), because the probe globs
# tests/*.sh and has no --corpus-dir seam. Cost: two kills, ~2s.
# These arms force the kill BEFORE the canary prints. The killed-AFTER-the-canary
# shape — the false `wired`, and the half that matters — is arms 26-29 below.
PROBE="tests/meta/harness-verdict-probe.sh"
VICTIM="gate_nonce_unit.sh"
if [[ -r "$PROBE" && -r "tests/$VICTIM" ]]; then
  POUT="$(PROBE_TIMEOUT=1 bash "$PROBE" --only="$VICTIM" --label=cap1 --report="$TMP/probe.txt" 2>/dev/null)"; PRC=$?
  want "a harness killed by the cap does not fail the probe (a kill is not a verdict)" "0" "$PRC"
  if [[ "$POUT" == *"timed-out"* && "$POUT" == *"$VICTIM"* && "$POUT" != *"ALREADY-RED"* ]]; then
    ok "the kill is reported as timed-out, NOT as a harness that failed its own clean run"
  else bad "the kill is reported as timed-out, NOT as a harness that failed its own clean run" "$POUT"; fi
  # The report is what the union reads, and `timed-out` is deliberately absent from
  # its probed set: a harness killed in EVERY environment must red the union as NEVER
  # PROBED rather than bank coverage it never earned.
  if grep -q "^timed-out	$VICTIM$" "$TMP/probe.txt" && ! grep -qE "^(wired|UNWIRED)	$VICTIM$" "$TMP/probe.txt"; then
    ok "the report row is timed-out and is NOT in the union's probed set"
  else bad "the report row is timed-out and is NOT in the union's probed set" "$(cat "$TMP/probe.txt")"; fi
else
  bad "probe timeout arms" "NOT REACHED: $PROBE or tests/$VICTIM missing — arms 23-25 graded nothing"
fi

# --------------- 26-29 DIVE-2555: the kill that arrives AFTER the canary has printed
# THE HALF THAT MATTERS, and the one nothing in tests/*.sh can reach:
# `grep -rln '__PROBE_REACHED__' tests/*.sh` is empty, so no real harness exercises
# the mutant phase's kill at all. The arms above force the kill BEFORE the canary
# (the old false `not-reached`). This forces it AFTER, which is the FALSE PASS: the
# canary has printed, so the probe believes the mutation executed, and `timeout`
# hands it a non-zero exit for free — so an UNWIRED harness banks a `wired` row and
# the union counts it as probed. The one check that exists to find harnesses which
# cannot fail CI then reports that they can. The two halves fail in opposite
# directions and neither subsumes the other (DIVE-2464), so both need an arm.
#
# THE SEAM. The probe roots itself at `dirname "$BASH_SOURCE"/../..` and globs
# `tests/*.sh` from there, so a throwaway tree with a SYMLINK to the probe in
# tests/meta/ becomes a corpus of exactly one stub — no file added to tests/, per
# this row's own rule. Symlink and not a copy, deliberately: the arm grades the probe
# in THIS checkout, so deleting the mutant-phase kill classification reds it here.
#
# THE STUB is green and instant on its clean run and hangs only once MUTATED: the
# injected `fail=$((fail+1))` lands after the canary and before the verdict, and the
# sleep is downstream of the verdict and gated on `fail`. `STUB_HANG` makes the hang
# itself a variable, which buys the control below. Cost: one kill, ~2s.
FAKE="$TMP/fakerepo"
mkdir -p "$FAKE/tests/meta"
STUB=hang_after_verdict.sh
if ln -s "$PWD/$PROBE" "$FAKE/tests/meta/$(basename "$PROBE")" 2>/dev/null; then
  cat > "$FAKE/tests/$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stub corpus for DIVE-2555. Its exit status IS wired to its counter; the probe
# injects its canary and `fail=$((fail+1))` immediately before the verdict line.
fail=0
(( fail == 0 ))
rc=$?
# Downstream of the verdict and gated on the MUTATED counter: the clean run never
# sleeps, the mutant always does. STUB_HANG=0 turns the hang off for the control.
if (( fail != 0 )); then sleep "${STUB_HANG:-20}"; fi
exit "$rc"
STUBEOF
  FAKE_PROBE="$FAKE/tests/meta/$(basename "$PROBE")"
  # CONTROL FIRST, and it is what makes the arm below non-vacuous. Same stub, same
  # mutation, hang switched off: the canary prints, the mutant exits non-zero on its
  # own, and the probe correctly says `wired`. That is the exact shape the kill
  # arrives in — so a `timed-out` verdict below cannot be the canary going unreached
  # (that would be `not-reached`), and `wired` is demonstrably what this stub earns
  # when the CLOCK does not intervene. Without this, arm 28 passes just as well
  # against a stub that never reached its verdict line at all.
  COUT="$(STUB_HANG=0 PROBE_TIMEOUT=20 bash "$FAKE_PROBE" --label=ctl --report="$TMP/probe-ctl.txt" 2>/dev/null)"; CRC=$?
  if (( CRC == 0 )) && grep -q "^wired	$STUB$" "$TMP/probe-ctl.txt"; then
    ok "control: the canary IS reached and this stub earns 'wired' when nothing kills it"
  else bad "control: the canary IS reached and this stub earns 'wired' when nothing kills it" "rc=$CRC $(cat "$TMP/probe-ctl.txt" 2>&1)"; fi

  # Now the same stub, killed after the canary. rc is non-zero and the canary is in
  # the output — every precondition the old code read as `wired`.
  KOUT="$(PROBE_TIMEOUT=2 bash "$FAKE_PROBE" --label=cap2 --report="$TMP/probe-kill.txt" 2>/dev/null)"; KRC=$?
  want "a mutant killed after the canary does not fail the probe" "0" "$KRC"
  if [[ "$KOUT" == *"0 wired"* && "$KOUT" == *"1 timed-out (cap 2s)"* ]]; then
    ok "the kill is classified timed-out and is NOT counted wired (the false PASS)"
  else bad "the kill is classified timed-out and is NOT counted wired (the false PASS)" "$KOUT"; fi
  if grep -q "^timed-out	$STUB$" "$TMP/probe-kill.txt" && ! grep -qE "^(wired|UNWIRED)	$STUB$" "$TMP/probe-kill.txt"; then
    ok "the killed mutant is absent from the union's probed set, so coverage is not banked"
  else bad "the killed mutant is absent from the union's probed set, so coverage is not banked" "$(cat "$TMP/probe-kill.txt" 2>&1)"; fi
else
  bad "probe mutant-kill arms" "NOT REACHED: could not symlink $PROBE into $FAKE — arms 26-29 graded nothing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
