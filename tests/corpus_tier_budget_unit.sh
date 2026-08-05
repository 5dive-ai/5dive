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
#  31-41 DIVE-2592: an over-budget run RE-TIMES its slowest files and keeps the
#         smaller sample, so a red that flips on a re-run of the same commit cannot
#         reach a PR author. Paired arms: the rescue, the corpus that is over on
#         BOTH samples anyway, and --confirm-top=0 (an override may only make the
#         control stricter). Plus: the red says NO TEST FAILED and names the set
#         that COVERS the overage, min-of-two never RAISES a total, a re-run
#         failure keeps its pass, and no workflow passes the new flag. The CONTROL
#         olivia asked for: same flapping harness, one real harness added between
#         two runs — the min rescues the first and reds the second, so it removes
#         weather and not cost, measured rather than argued.
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

TIER_LIB="tests/lib/tier.sh"
RUNNER="scripts/run-harnesses.sh"
TMP="$(mktemp -d /tmp/corpus-tier-budget.XXXXXX)"

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

run() { OUT="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" "$@" 2>&1)"; RC=$?; }

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
OUT="$(bash "$RUNNER" --no-calibrate --tier=core --budget=600 --corpus-dir="$TMP/empty" 2>&1)"; RC=$?
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
ran() { bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=600 "$@" 2>&1 \
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

OUT="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --shard=4/3 2>&1)"; RC=$?
if (( RC == 2 )) && [[ "$OUT" == *"out of range"* ]]; then
  ok "an out-of-range shard REFUSES"
else bad "an out-of-range shard REFUSES" "rc=$RC out=$OUT"; fi

# 9 shards over 7 files: shard 8 selects nothing. Green-over-nothing, per shard.
OUT="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --shard=8/9 2>&1)"; RC=$?
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

# ------------------------------------ 23-26 DIVE-2555: a TIMEOUT KILL is not a verdict
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
# These arms force the kill BEFORE the canary prints. The killed-AFTER-the-canary
# shape — the false `wired`, and the half that matters — is arms 27-30 below.
#
# GRADED AGAINST A STUB, NOT A REAL HARNESS, and iteration 2 is why. This arm used
# to point a 1s cap at tests/gate_nonce_unit.sh (11.3s on the control plane, so
# reliably killed HERE) and it was green locally in two trees and RED in CI. The
# split was never in the probe: gate_nonce_unit.sh opens with a skip guard —
# "no agent-* user on this host to source a real agent uid", then `exit 0` — and a
# GitHub runner has no agent-* user. So on CI the clean run finished in
# milliseconds, NOTHING was killed, the mutant exited before the canary, and the
# row was `not-reached`. The arm's premise was "this victim is slower than the cap
# here", which is a property of the HOST POPULATION, not of the code under test.
# That is the same lesson as the header measurements above, one layer out: a
# duration read off one box is not a constant. So the victim is now a stub whose
# runtime is written down rather than measured, via the same fake-repo seam arms
# 27-30 already proved — the claim that this needed a real harness ("no
# --corpus-dir seam") was retired the moment that seam was found.
# Cost: one kill at a 1s cap plus an instant control, ~1s.
PROBE="tests/meta/harness-verdict-probe.sh"
FAKE="$TMP/fakerepo"
mkdir -p "$FAKE/tests/meta"
# THE SEAM (shared with arms 27-30). The probe roots itself at
# `dirname "$BASH_SOURCE"/../..` and globs `tests/*.sh` from there, so a throwaway
# tree with a SYMLINK to the probe in tests/meta/ becomes a corpus of exactly the
# stubs written below — no file added to tests/, per this row's own rule. Symlink
# and not a copy, deliberately: the arms grade the probe in THIS checkout, so
# deleting either kill classification reds it here.
# Both stubs live in one fake corpus, so every probe run below passes `--only`:
# without it each run would probe the other stub too, and the kill counts these
# arms assert are counts over the whole run.
FAKE_PROBE="$FAKE/tests/meta/$(basename "$PROBE")"
SEAM=0
[[ -r "$PROBE" ]] && ln -s "$PWD/$PROBE" "$FAKE_PROBE" 2>/dev/null && SEAM=1
CSTUB=hang_before_verdict.sh
if (( SEAM )); then
  # Hangs on its CLEAN run, before any verdict, in every environment — the kill is
  # written into the stub instead of hoped for from the host. STUB_HANG=0 turns the
  # hang off for the control.
  cat > "$FAKE/tests/$CSTUB" <<'STUBEOF'
#!/usr/bin/env bash
# Stub corpus for DIVE-2555: green and instant with STUB_HANG=0, otherwise it
# sleeps past any sane cap before reaching its verdict line.
fail=0
sleep "${STUB_HANG:-20}"
(( fail == 0 ))
STUBEOF
  # CONTROL FIRST, and it is what makes the kill arm non-vacuous. Same stub, same
  # cap, hang switched off: the probe runs it clean, mutates it, and earns `wired`.
  # So a `timed-out` verdict below cannot be this stub being unprobeable, missing
  # from the corpus, or red on its own assertions — the only thing that changed is
  # the CLOCK.
  CCOUT="$(STUB_HANG=0 PROBE_TIMEOUT=20 bash "$FAKE_PROBE" --only="$CSTUB" --label=ctl1 --report="$TMP/probe-ctl1.txt" 2>/dev/null)"; CCRC=$?
  if (( CCRC == 0 )) && grep -q "^wired	$CSTUB$" "$TMP/probe-ctl1.txt"; then
    ok "control: this stub is probeable and earns 'wired' when nothing kills it"
  else bad "control: this stub is probeable and earns 'wired' when nothing kills it" "rc=$CCRC $(cat "$TMP/probe-ctl1.txt" 2>&1)"; fi

  POUT="$(PROBE_TIMEOUT=1 bash "$FAKE_PROBE" --only="$CSTUB" --label=cap1 --report="$TMP/probe.txt" 2>/dev/null)"; PRC=$?
  want "a harness killed by the cap does not fail the probe (a kill is not a verdict)" "0" "$PRC"
  # SCOPED TO THE VERDICT LINES, because the previous form was vacuous: the summary
  # always contains the literal "timed-out (cap 1s)" whatever the count is, and the
  # victim's name appears in whichever per-harness row it landed in. `*timed-out*`
  # and `*$VICTIM*` over the whole transcript therefore passed on the CI run where
  # the classification was `not-reached` — the arm that mattered was the report grep
  # below, alone. Assert the COUNT off the summary and the CLEAN-RUN wording off the
  # row: only a clean-phase kill produces both.
  PSUM="$(grep -m1 '^harness-verdict-probe:' <<<"$POUT")"
  if [[ "$PSUM" == *"1 timed-out (cap 1s)"* && "$PSUM" == *"0 already-red"* \
     && "$POUT" == *"timed-out    $CSTUB (clean run killed at 1s"* ]]; then
    ok "the kill is reported as timed-out, NOT as a harness that failed its own clean run"
  else bad "the kill is reported as timed-out, NOT as a harness that failed its own clean run" "$POUT"; fi
  # The report is what the union reads, and `timed-out` is deliberately absent from
  # its probed set: a harness killed in EVERY environment must red the union as NEVER
  # PROBED rather than bank coverage it never earned.
  if grep -q "^timed-out	$CSTUB$" "$TMP/probe.txt" && ! grep -qE "^(wired|UNWIRED|not-reached)	$CSTUB$" "$TMP/probe.txt"; then
    ok "the report row is timed-out and is NOT in the union's probed set"
  else bad "the report row is timed-out and is NOT in the union's probed set" "$(cat "$TMP/probe.txt")"; fi
else
  bad "probe timeout arms" "NOT REACHED: could not symlink $PROBE into $FAKE — arms 23-26 graded nothing"
fi

# --------------- 27-30 DIVE-2555: the kill that arrives AFTER the canary has printed
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
# THE SEAM is the fake repo built for arms 23-26 above — same throwaway tree, same
# symlinked probe, one more stub in its corpus.
#
# THE STUB is green and instant on its clean run and hangs only once MUTATED: the
# injected `fail=$((fail+1))` lands after the canary and before the verdict, and the
# sleep is downstream of the verdict and gated on `fail`. `STUB_HANG` makes the hang
# itself a variable, which buys the control below. Cost: one kill, ~2s.
STUB=hang_after_verdict.sh
if (( SEAM )); then
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
  # CONTROL FIRST, and it is what makes the arm below non-vacuous. Same stub, same
  # mutation, hang switched off: the canary prints, the mutant exits non-zero on its
  # own, and the probe correctly says `wired`. That is the exact shape the kill
  # arrives in — so a `timed-out` verdict below cannot be the canary going unreached
  # (that would be `not-reached`), and `wired` is demonstrably what this stub earns
  # when the CLOCK does not intervene. Without this, arm 28 passes just as well
  # against a stub that never reached its verdict line at all.
  COUT="$(STUB_HANG=0 PROBE_TIMEOUT=20 bash "$FAKE_PROBE" --only="$STUB" --label=ctl --report="$TMP/probe-ctl.txt" 2>/dev/null)"; CRC=$?
  if (( CRC == 0 )) && grep -q "^wired	$STUB$" "$TMP/probe-ctl.txt"; then
    ok "control: the canary IS reached and this stub earns 'wired' when nothing kills it"
  else bad "control: the canary IS reached and this stub earns 'wired' when nothing kills it" "rc=$CRC $(cat "$TMP/probe-ctl.txt" 2>&1)"; fi

  # Now the same stub, killed after the canary. rc is non-zero and the canary is in
  # the output — every precondition the old code read as `wired`.
  KOUT="$(PROBE_TIMEOUT=2 bash "$FAKE_PROBE" --only="$STUB" --label=cap2 --report="$TMP/probe-kill.txt" 2>/dev/null)"; KRC=$?
  want "a mutant killed after the canary does not fail the probe" "0" "$KRC"
  if [[ "$KOUT" == *"0 wired"* && "$KOUT" == *"1 timed-out (cap 2s)"* ]]; then
    ok "the kill is classified timed-out and is NOT counted wired (the false PASS)"
  else bad "the kill is classified timed-out and is NOT counted wired (the false PASS)" "$KOUT"; fi
  if grep -q "^timed-out	$STUB$" "$TMP/probe-kill.txt" && ! grep -qE "^(wired|UNWIRED)	$STUB$" "$TMP/probe-kill.txt"; then
    ok "the killed mutant is absent from the union's probed set, so coverage is not banked"
  else bad "the killed mutant is absent from the union's probed set, so coverage is not banked" "$(cat "$TMP/probe-kill.txt" 2>&1)"; fi
else
  bad "probe mutant-kill arms" "NOT REACHED: could not symlink $PROBE into $FAKE — arms 27-30 graded nothing"
fi

# ------------------------------------- 31-41 DIVE-2592: A BUDGET RED CONFIRMS ITSELF
# The measurement that forced this: PR #395 red at 356s and green at 289s on the SAME
# commit, no rebase — a 67s swing, all of it inside one network-priced harness. A cap
# compared against ONE noisy sample reds PRs on content they did not change, so an
# over-budget run now re-times its slowest files and keeps the SMALLER sample per file.
#
# Every arm below is one this mechanism can get wrong, and they are deliberately
# PAIRED: a rescue arm alone is satisfied by "confirmation always rescues", which is
# the budget silently switched off. Sleeps are 1.2s against a 1s budget — the smallest
# pair the runner's second-resolution clock can tell apart — because this file is
# itself charged to the tier it enforces.
rm -f "$TMP"/*.sh "$TMP"/*.seen
# Slow once, then free: the shape of a harness whose cost was the runner, not itself.
cat > "$TMP/flaps.sh" <<'FLAPS'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] && exit 0
touch "$0.seen"; sleep 1.2; exit 0
FLAPS
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/tiny.sh"

C1="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; RC1=$?
if (( RC1 == 0 )); then
  ok "a run OVER on its first sample and INSIDE on its second exits 0"
else bad "a run OVER on its first sample and INSIDE on its second exits 0" "rc=$RC1"; fi
# A rescue that prints nothing is a budget that relaxed itself in silence. Both
# numbers, or the trend this row exists to keep legible is gone on exactly the runs
# where it moved.
if [[ "$C1" == *"BUDGET CONFIRMATION"* && "$C1" == *"first sample"* && "$C1" == *"confirmed"* ]]; then
  ok "the rescue SAYS SO, with both the first and the confirmed number"
else bad "the rescue SAYS SO, with both the first and the confirmed number" "$C1"; fi
if [[ "$C1" == *"flaps.sh"* && "$C1" == *"->"* ]]; then
  ok "the rescue NAMES the harness whose timing swung"
else bad "the rescue NAMES the harness whose timing swung" "$C1"; fi

# NON-VACUITY. Same runner, same budget, a corpus that is over on BOTH samples: if
# this passed too, the arm above would be measuring nothing but the retry existing.
# Slow EVERY time: the shape of a corpus that genuinely does not fit its cap.
rm -f "$TMP"/*.seen "$TMP/flaps.sh"
printf '#!/usr/bin/env bash\nsleep 1.2\nexit 0\n' > "$TMP/always.sh"
C2="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; RC2=$?
want "a corpus that is over on BOTH samples still exits 4" "4" "$RC2"
if [[ "$C2" == *"NO TEST FAILED"* && "$C2" == *"BUDGET failure"* ]]; then
  ok "the budget red says NO TEST FAILED — the sentence exit 4 alone does not carry"
else bad "the budget red says NO TEST FAILED — the sentence exit 4 alone does not carry" "$C2"; fi
if [[ "$C2" == *"cover it"* && "$C2" == *"always.sh"* ]]; then
  ok "the budget red names the smallest set of harnesses that COVERS the overage"
else bad "the budget red names the smallest set of harnesses that COVERS the overage" "$C2"; fi

# --confirm-top may only make this gate STRICTER. The rescued corpus, confirmation
# off, must red — an override that can turn a red green is the hatch, not the control.
cat > "$TMP/flaps.sh" <<'FLAPS'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] && exit 0
touch "$0.seen"; sleep 1.2; exit 0
FLAPS
rm -f "$TMP/always.sh" "$TMP"/*.seen
bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t --confirm-top=0 >/dev/null 2>&1
want "--confirm-top=0 reds the SAME corpus the confirmation rescues (stricter, never looser)" "4" "$?"

# MIN OF TWO NEVER RAISES A TIMING. A harness slower on its re-run keeps its first
# sample: a confirmation that could INVENT a red is a second, worse coin flip.
rm -f "$TMP"/*.sh "$TMP"/*.seen
cat > "$TMP/rev.sh" <<'REV'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] || { touch "$0.seen"; exit 0; }
sleep 1.2; exit 0
REV
printf '#!/usr/bin/env bash\nsleep 1.2\nexit 0\n' > "$TMP/always.sh"
C3="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"
f3="$(sed -n 's/.*first sample \([0-9]*\)s.*/\1/p' <<<"$C3" | head -1)"
c3="$(sed -n 's/.*confirmed \([0-9]*\)s.*/\1/p' <<<"$C3" | head -1)"
if [[ -n "$f3" && -n "$c3" ]] && (( c3 <= f3 )); then
  ok "a harness SLOWER on its re-run keeps its first sample (confirmation never raises a total)"
else bad "a harness SLOWER on its re-run keeps its first sample (confirmation never raises a total)" "first=[$f3] confirmed=[$c3]"; fi

# A harness that FAILS its re-run keeps its PASS. The graded run is the first one, and
# flipping a pass to a fail on a second sample is this same one-sample error inverted —
# but the non-determinism is reported, not swallowed.
rm -f "$TMP"/*.sh "$TMP"/*.seen
cat > "$TMP/flake.sh" <<'FLK'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] && exit 1
touch "$0.seen"; sleep 1.2; exit 0
FLK
C4="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; RC4=$?
if (( RC4 == 4 )) && [[ "$C4" == *"RE-RUN DISAGREED (observed)"* && "$C4" == *"flake.sh"* ]]; then
  ok "a harness that fails its RE-RUN keeps its pass (exit 4, not 1) and the disagreement is reported"
else bad "a harness that fails its RE-RUN keeps its pass (exit 4, not 1) and the disagreement is reported" "rc=$RC4 out=$C4"; fi
# olivia, DIVE-2592: the observation and the CAUSE are different claims, and a guess
# printed among measured sentences inherits their authority. The hedge lives in the
# string, which is read forever, not only in the handoff, which is read once — so it
# is graded here rather than trusted.
if [[ "$C4" == *"CAUSE NOT MEASURED (inferred)"* ]]; then
  ok "the re-run disagreement marks its CAUSE as inferred, in the output string itself"
else bad "the re-run disagreement marks its CAUSE as inferred, in the output string itself" "$C4"; fi

# CONTROL (olivia, grading DIVE-2592): DOES THE MIN STILL SEE GROWTH?
# The whole defence of min-of-two is that it removes WEATHER and keeps GROWTH — and
# that was an argument, not a measurement, which is exactly the kind of claim this
# corpus is supposed to refuse. So measure it, differentially: the SAME flapping
# harness in both runs, one harness of real cost ADDED between them, nothing else
# changed. If the min hid growth, the grown corpus would be rescued too.
rm -f "$TMP"/*.sh "$TMP"/*.seen
cat > "$TMP/flaps.sh" <<'FLAPS'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] && exit 0
touch "$0.seen"; sleep 1.2; exit 0
FLAPS
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/tiny.sh"
G1="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; GRC1=$?
g1="$(sed -n 's/.*confirmed \([0-9]*\)s.*/\1/p' <<<"$G1" | head -1)"
# GROW IT: one more harness that costs its time every single run.
rm -f "$TMP"/*.seen
printf '#!/usr/bin/env bash\nsleep 1.2\nexit 0\n' > "$TMP/grew.sh"
G2="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; GRC2=$?
g2="$(sed -n 's/.*confirmed \([0-9]*\)s.*/\1/p' <<<"$G2" | head -1)"
if (( GRC1 == 0 && GRC2 == 4 )); then
  ok "GROWTH SURVIVES THE MIN: the confirmation that rescues the flapping corpus does NOT rescue it once one real harness is added"
else bad "GROWTH SURVIVES THE MIN: the confirmation that rescues the flapping corpus does NOT rescue it once one real harness is added" "rc1=$GRC1 rc2=$GRC2"; fi
# And the growth is VISIBLE IN THE CONFIRMED NUMBER, not only in the exit code — a
# min that reported a flat total while reddening would be measuring something else.
if [[ -n "$g1" && -n "$g2" ]] && (( g2 > g1 )); then
  ok "the CONFIRMED total rises with the added harness (${g1}s -> ${g2}s): the min removes weather, not cost"
else bad "the CONFIRMED total rises with the added harness: the min removes weather, not cost" "g1=[$g1] g2=[$g2]"; fi
# Non-vacuity for the pair above: the second run must have actually RUN the
# confirmation and reclaimed the flap, or "it went red" proves only that nothing
# confirmed anything.
if [[ "$G2" == *"BUDGET CONFIRMATION"* && "$G2" == *"flaps.sh"* ]]; then
  ok "the grown corpus DID confirm and DID reclaim the flap, and reds anyway"
else bad "the grown corpus DID confirm and DID reclaim the flap, and reds anyway" "$G2"; fi

# The hatch arm the --budget flag never got (community/wiki/a-budget-with-a-free-
# escape-hatch-is-a-second-budget-nobody-watches.md): enumerate the hatches from the
# RUNNER'S FLAG SURFACE, not from the policy. --confirm-top is safe only while no job
# passes it, and "no job does today" is not a control until something pins it.
rm -f "$TMP"/*.sh "$TMP"/*.seen
if grep -rn -- '--confirm-top' .github/workflows/ >/dev/null 2>&1; then
  bad "no CI workflow passes --confirm-top" "$(grep -rn -- '--confirm-top' .github/workflows/)"
else ok "no CI workflow passes --confirm-top"; fi

# --- DIVE-2667: the tier must run often enough to ATTRIBUTE a break ------------
# The nightly was red on main for ~17h across ~12 commits because full-sweep ran
# once a day and is not in the per-PR check set. Two properties are pinned here,
# and they only mean something together: `push: main` is what makes the sweep
# frequent enough to name one merge, and `cancel-in-progress` is what makes that
# frequency affordable. Ship one without the other and the next person deletes it.
#
# Graded by PARSING the workflow, not by grepping it. A `grep 'push:'` matches the
# word inside any of this file's own comments, and would have passed against the
# unchanged file. Note the YAML 1.1 gotcha the parse has to survive: the `on:` key
# loads as the BOOLEAN True, not the string 'on'.
_wf_on() {  # <file> -> the on: keys, one per line
  python3 - "$1" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get('on', {})) or {}
print('\n'.join(sorted(on)) if isinstance(on, dict) else '')
PY
}
_wf_push_branches() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get('on', {})) or {}
p = (on.get('push') or {}) if isinstance(on, dict) else {}
print(' '.join(p.get('branches', []) or []))
PY
}
SWEEP=.github/workflows/full-sweep.yml
SWEEP_ON="$(_wf_on "$SWEEP")"
# Liveness first: a parser that returns nothing makes every membership test below
# vacuously... false, which is the safe direction, but says the wrong thing about WHY.
if [[ -n "$SWEEP_ON" ]] && grep -qx 'schedule' <<<"$SWEEP_ON"; then
  ok "full-sweep's on: block PARSES and still carries the nightly schedule"
else bad "full-sweep's on: block PARSES and still carries the nightly schedule" "on=[$SWEEP_ON]"; fi
if grep -qx 'push' <<<"$SWEEP_ON" && [[ " $(_wf_push_branches "$SWEEP") " == *" main "* ]]; then
  ok "full-sweep runs on PUSH TO MAIN: a break is attributable to one merge, not to a day's window (DIVE-2667)"
else bad "full-sweep runs on PUSH TO MAIN: a break is attributable to one merge, not to a day's window (DIVE-2667)" \
       "on=[$(tr '\n' ',' <<<"$SWEEP_ON")] branches=[$(_wf_push_branches "$SWEEP")]"; fi
# The parser is discriminating, not just permissive: a trigger this workflow does
# NOT declare must come back absent from the same call that reported push present.
if ! grep -qx 'release' <<<"$SWEEP_ON"; then
  ok "the same parse reports an ABSENT trigger as absent (the membership test discriminates)"
else bad "the same parse reports an ABSENT trigger as absent (the membership test discriminates)" "on=[$SWEEP_ON]"; fi
# Cost bound. Without cancel-in-progress, push-on-main is 6 jobs per merge with no
# collapse, and the first person to read the bill deletes the trigger this row added.
if python3 - "$SWEEP" <<'PY' 2>/dev/null
import sys, yaml
c = (yaml.safe_load(open(sys.argv[1])) or {}).get('concurrency') or {}
sys.exit(0 if isinstance(c, dict) and c.get('cancel-in-progress') is True and 'github.ref' in str(c.get('group','')) else 1)
PY
then
  ok "the push trigger is cost-bounded: concurrency cancels in progress, grouped per REF so a PR sweep is not cancelled by a merge"
else bad "the push trigger is cost-bounded: concurrency cancels in progress, grouped per REF so a PR sweep is not cancelled by a merge" \
       "$(grep -A3 '^concurrency:' "$SWEEP" 2>&1)"; fi
# Anchor: the neighbour workflow must NOT satisfy the same assertion, or "full-sweep
# has push: main" is a claim about every workflow in the directory and grades nothing.
if ! grep -qx 'schedule' <<<"$(_wf_on .github/workflows/unit-tests.yml)"; then
  ok "ANCHOR: the neighbour (unit-tests.yml) parses to a DIFFERENT trigger set — the assertions above are about this file"
else bad "ANCHOR: the neighbour (unit-tests.yml) parses to a DIFFERENT trigger set" "unit-tests on=[$(tr '\n' ',' <<<"$(_wf_on .github/workflows/unit-tests.yml)")]"; fi

# ------------------------------ 42-58 DIVE-2728: THE BUDGET IS SPENT IN A RELATIVE UNIT
# The measurement that forced this: PR #461 red at 322s/300s with 234 of 234 harnesses
# passing and a diff worth +0.1s, while unrelated files ran 10-36% slower and the one
# file the diff touched moved +0.3%. The cap had stopped measuring the corpus and
# started measuring the runner. So the budget is now spent in units of a calibration
# workload carried in the same job, and a uniformly slow VM scales both sides.
#
# EVERY TIMING ARM BELOW IS DRIVEN THROUGH --corpus-dir WITH DURATIONS THIS FILE WROTE
# AND A CALIBRATION IT INJECTED (--cal-us). A test that MEASURES its own inputs grades
# the runner it happens to be sitting on, which is the exact defect under repair
# (DIVE-2555 §4) — and on a mechanism whose subject IS runner variance, that is not a
# stylistic preference, it is the difference between an assertion and a coin flip.
#
# WHY THESE ARMS LIVE IN THIS FILE and not a new one: the runner's own over-budget
# advice says MERGE BY SUBJECT before adding, and the subject here is identical. They
# cost this file ~6s of sleeps, which it pays out of the tier it enforces. They cannot
# be cheaper: the smallest budget the runner accepts is 1s, so an arm that must be OVER
# a cap must burn more than a second of real clock (feedback: say what a cost buys, in
# the file that pays it).
#
# THE PAIRING RULE FROM THE 2592 ARMS APPLIES DOUBLY HERE. Arms that assert a RED fail
# quietly: a harness that reds for the WRONG REASON still reads green to the grader. So
# every red arm below is paired with the run that must NOT red, differing in exactly one
# input — and the pair is the assertion, not either half.
rm -f "$TMP"/*.sh "$TMP"/*.seen

# ---- 42-45 the arithmetic, graded on its own before any clock is involved
want "scale is measured/baseline as a percent" "140" "$(tier_cal_scale_pct 140000 100000)"
want "a faster runner reads BELOW 100%" "50" "$(tier_cal_scale_pct 50000 100000)"
# The clamp is the escape-hatch guard (trap 2) and the never-tighten call (the open
# question in DIVE-2710 §2.2, decided at 1.0 here). Both directions, or "clamp" is a
# word in a comment.
want "the clamp CEILING bounds how much a slow runner may buy" \
  "$TIER_CAL_SCALE_MAX_PCT" "$(tier_cal_clamp_pct 400)"
want "the clamp FLOOR means a fast runner never TIGHTENS the agreed cap" \
  "$TIER_CAL_SCALE_MIN_PCT" "$(tier_cal_clamp_pct 50)"

# ---- 46-48 ARM 1: A UNIFORMLY SLOW VM DOES NOT MOVE THE VERDICT
# Three runs, one input changing at a time. 0.8s of corpus against a 1s cap passes.
# The same corpus 1.4x slower, on a runner measured 1.4x slow, must STILL pass — that
# is the whole claim. And the CONTROL: that same slow corpus on a runner measured
# NORMAL must go RED, or the arm above is satisfied by a cap that simply got bigger.
relrun() { OUT="$(bash "$RUNNER" --corpus-dir="$TMP" --tier=full --label=t \
  --cal-baseline-us=100000 "$@" 2>&1)"; RC=$?; }

printf '#!/usr/bin/env bash\nsleep 0.8\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000
want "a normal corpus on a normal runner passes" "0" "$RC"

printf '#!/usr/bin/env bash\nsleep 1.12\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=140000 --confirm-top=0
want "ARM 1: the SAME corpus 1.4x slower, on a runner measured 1.4x slow, still passes" "0" "$RC"
if [[ "$OUT" == *"140%"* && "$OUT" == *"effective cap"* ]]; then
  ok "the run SHOWS its scale and its effective cap, so the reader can tell VM from corpus"
else bad "the run SHOWS its scale and its effective cap" "$OUT"; fi

relrun --budget=1 --cal-us=100000 --confirm-top=0
want "CONTROL: that same slow corpus on a NORMAL runner reds — the pass above came from the calibration, not from slack" \
  "4" "$RC"

# ---- 49-50 ARM 2: THE RATCHET SURVIVES. Growth still reds, even with the allowance.
# This is the arm that proves the fix did not become the hatch: a corpus that outgrows
# its cap by MORE than the clamp forgives reds on a slow runner exactly as it would on
# a fast one. Without it, "scale the cap" is indistinguishable from "raise the cap".
printf '#!/usr/bin/env bash\nsleep 1.6\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=140000 --confirm-top=0
want "ARM 2: corpus growth beyond what the clamp forgives still exits 4 on a slow runner" "4" "$RC"
if [[ "$OUT" == *"held to is"* && "$OUT" == *"EVEN WITH that allowance"* ]]; then
  ok "the red states the cap it was ACTUALLY graded against — 'over by Ns' against an unstated cap is how a slow runner gets blamed on a diff"
else bad "the red states the cap it was ACTUALLY graded against" "$OUT"; fi

# ---- 51-53 ARM 3: PAST THE CLAMP THE RUN IS UNDETERMINED, NEVER GREEN
# Trap 2, enforced. An unclamped scale factor licenses an arbitrarily larger corpus, so
# past the ceiling the runner refuses to grade rather than generously passing. Exit 6,
# and the pair below is what makes this an assertion: the SAME under-cap corpus one
# notch inside the clamp exits 0, so the 6 is the clamp and not the corpus.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=200000
want "ARM 3: a runner past the clamp is UNDETERMINED (exit 6), not green" "6" "$RC"
if [[ "$OUT" == *"UNDETERMINED"* && "$OUT" != *"OVER BUDGET"* ]]; then
  ok "the undetermined run does NOT claim the corpus is over — those are different events and DIVE-2667 was them sharing a red"
else bad "the undetermined run does NOT claim the corpus is over" "$OUT"; fi
relrun --budget=1 --cal-us=140000
want "PAIR: the same corpus one notch INSIDE the clamp exits 0 — the 6 above is the clamp, not the corpus" "0" "$RC"

# ---- 54-56 ARM 4: A CALIBRATION THAT CANNOT BE TAKEN FAILS CLOSED
# The lazy version of this line is "calibration unavailable, falling back to the raw
# cap", which is the free escape hatch DIVE-2525 closed wearing a new name. A probe
# that cannot run means the budget was not graded, and not-graded is not passed.
OUT="$(bash "$RUNNER" --corpus-dir="$TMP" --tier=full --budget=1 --label=t \
  --cal-cli=/nonexistent/5dive 2>&1)"; RC=$?
want "ARM 4: a calibration that cannot run FAILS CLOSED (exit 6)" "6" "$RC"
if [[ "$OUT" == *"UNDETERMINED"* && "$OUT" != *"BUDGET DISABLED"* ]]; then
  ok "a missing probe is UNDETERMINED, never 'budget disabled' — the difference is whether the gate still exists"
else bad "a missing probe is UNDETERMINED, never 'budget disabled'" "$OUT"; fi
# ...but a genuinely BROKEN harness still dominates. An unmeasurable runner must never
# hide a failing test, which is why the undetermined verdict is resolved at the exit
# ladder rather than short-circuiting before the corpus ever ran.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/broken.sh"
bash "$RUNNER" --corpus-dir="$TMP" --tier=full --budget=1 --label=t \
  --cal-cli=/nonexistent/5dive >/dev/null 2>&1; RC=$?
want "a FAILING harness still exits 1 even when the runner could not be measured" "1" "$RC"
rm -f "$TMP/broken.sh"

# ---- 57 ARM 5: DIVE-2592's CONFIRMATION STILL FIRES, and now against the SCALED cap
# The two mechanisms are complementary, not alternatives (olivia, DIVE-2710): the
# confirmation covers the CONCENTRATED outlier, the relative budget covers the UNIFORM
# slowdown. This arm is what stops the second quietly disabling the first.
rm -f "$TMP"/*.sh "$TMP"/*.seen
cat > "$TMP/flaps.sh" <<'FLAPS'
#!/usr/bin/env bash
[[ -e "$0.seen" ]] && exit 0
touch "$0.seen"; sleep 1.5; exit 0
FLAPS
relrun --budget=1 --cal-us=140000
if (( RC == 0 )) && [[ "$OUT" == *"BUDGET CONFIRMATION"* && "$OUT" == *"flaps.sh"* ]]; then
  ok "ARM 5: a concentrated outlier is still re-timed and still rescued, against the EFFECTIVE cap"
else bad "ARM 5: a concentrated outlier is still re-timed and still rescued" "rc=$RC $OUT"; fi

# ---- 58-59 the report, and the flags no workflow may carry
rm -f "$TMP"/*.sh "$TMP"/*.seen
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/w.sh"
bash "$RUNNER" --corpus-dir="$TMP" --tier=full --budget=1 --label=t \
  --cal-baseline-us=100000 --cal-us=120000 --report="$TMP/rep.txt" >/dev/null 2>&1
_miss=""
for f in cal_status cal_us_per_iter cal_baseline_us_per_iter cal_scale_pct \
         cal_scale_pct_applied effective_budget_s pct_of_effective_budget undetermined \
         wall_clock_s budget_s pct_of_budget; do
  grep -q "^# $f=" "$TMP/rep.txt" || _miss="$_miss $f"
done
if [[ -z "$_miss" ]]; then
  ok "the report carries the calibration fields AND still carries wall_clock_s/budget_s/pct_of_budget under their old names (every trend reader parses by name)"
else bad "the report carries the calibration fields beside the originals" "missing:$_miss"; fi

# Same rule as --budget and --confirm-top: the policy lives beside the tier definition,
# not scattered across callers. A workflow that injected its own calibration would be
# choosing its own cap in a YAML nobody reviews as a policy change.
_wfcal="$(grep -rn -- '--cal-us=\|--cal-baseline-us=\|--cal-cli=' .github/workflows/ 2>/dev/null || true)"
if [[ -z "$_wfcal" ]]; then
  ok "NO workflow injects a calibration — the seam is for this harness and for a human measuring, never for a caller picking its own cap"
else bad "NO workflow injects a calibration" "$_wfcal"; fi

# ---- 60 the precondition this row MADE load-bearing
# Before DIVE-2728 a job that forgot ./build.sh ran the corpus anyway (some earlier
# harness builds the bundle as a side effect — the ordering accident unit-tests.yml
# already documents at its own build step). Now the calibration probe SPAWNS that
# bundle, and a missing one fails closed at exit 6. Fail-closed is correct and it also
# means a mis-ordered workflow reds the whole sweep for a reason whose message is
# about calibration, not about YAML. So the ordering gets an assertion.
#
# WHAT THIS CHECKS AND WHAT IT DOES NOT: step INDEX within the SAME JOB, parsed, not
# grepped — a file-wide "both strings appear" test would pass a workflow where the two
# live in different jobs, which is precisely the arrangement that breaks. It does not
# follow composite actions or `uses:` steps that might build; if one is ever added,
# this arm will complain and the fix is to teach it, not to delete it.
_ord="$(python3 - <<'PY' 2>&1
import glob, yaml
bad = []
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f)) or {}
    for jn, j in (d.get('jobs') or {}).items():
        steps = j.get('steps') or []
        run = [i for i, s in enumerate(steps) if 'run-harnesses.sh' in str((s or {}).get('run', ''))]
        if not run:
            continue
        build = [i for i, s in enumerate(steps) if './build.sh' in str((s or {}).get('run', ''))]
        if not build or min(build) > min(run):
            bad.append(f'{f}:{jn}')
print(' '.join(bad))
PY
)"
if [[ -z "$_ord" ]]; then
  ok "every job that runs the budgeted runner BUILDS THE BUNDLE FIRST, in that job — the calibration probe spawns it, and a missing bundle now fails closed"
else bad "every job that runs the budgeted runner builds the bundle first, in that job" "offending job(s): $_ord"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
