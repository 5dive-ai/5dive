#!/usr/bin/env bash
# DIVE-2525 isolated unit harness for the two halves of the corpus wall-clock
# budget: the tier resolver (tests/lib/tier.sh) and the budgeted runner
# (scripts/run-harnesses.sh).
#
# TIER: nightly — 41.4s measured (GitHub Actions ubuntu-latest, core/pristine job,
# run 30988600395, 2026-08-05). This is a META-harness: it grades the tier resolver
# and the budgeted runner, so NO product path a customer reaches runs through it —
# the standard nightly criterion. It costs 14% of the 300s core budget it is itself
# grading, which makes it the strongest nightly candidate in the corpus on its own
# merits. CLAUDE.md ranks merge and retire ahead of demotion and neither applies: it
# has no sibling to fold into, and the mechanism it guards is live. A regression in
# the runner is now caught within 24h instead of per-PR; that latency is acceptable
# because the runner FAILS LOUD (exit 4 with numbers), so a break announces itself
# rather than passing silently. If it ever starts failing OPEN, revisit this first.
# Decision: main, 2026-08-05.
#
# THE "SMALL AND FAST" CLAIM THIS HEADER USED TO MAKE IS RETIRED, not quietly
# dropped. It read: "WHY THIS FILE IS ITSELF SMALL AND FAST, and says so ... the
# honest version is not to skip the coverage, it is to pay the budget it enforces."
# That was true when written and is now false — at 41.4s this file is the SLOWEST in
# core. Leaving it standing two lines above a nightly marker would be exactly the
# stale unverified number this harness exists to catch (see the DIVE-2555 arms
# below, which grade a demotion's claim against the clock). The coverage is still
# paid for; it is paid nightly.
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

# >= 50% AND >= 3s over its claim is graded WRONG. DIVE-3163 CHANGED WHAT THAT VERDICT
# IS ALLOWED TO DO. These arms used to require exit 5 and the literal words "not runner
# variance"; both were measured false on 2026-08-10 (same sha red then green with no code
# change; three unrelated harnesses drifting together in one shard; and THIS FILE drawing
# 62.1s against its own 41.4s claim on a branch that does not touch it). The finding is
# still graded and still printed in full — what it may no longer do is red the run off ONE
# box, because release-cut.yml refuses on any red without reading which red it is.
mk wrong_claim.sh '#!/usr/bin/env bash
# TIER: nightly — 0.5s measured (DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
sleep 4
exit 0'
rm -f "$TMP/stale_claim.sh"
run --tier=full --budget=600 --label=t --report="$TMP/drift-report.txt"
want "a WRONG header is a WARNING, not a red: exit 0 on one box (DIVE-3163)" "0" "$RC"
if [[ "$OUT" == *"WRONG"* && "$OUT" == *"wrong_claim.sh"* ]]; then
  ok "the refuted header is still called WRONG and still named"
else bad "the refuted header is still called WRONG and still named" "$OUT"; fi
# The half that actually cost the releases: the sentence must stop ASSERTING a cause it
# has no instrument to separate. An arm on the absence, because the defect was a claim
# that was PRESENT and false, and the next reader's cheapest revert is to re-add it.
if [[ "$OUT" != *"not runner variance"* ]]; then
  ok "the run no longer asserts 'that is not runner variance' — one box cannot exclude the runner"
else bad "the run no longer asserts 'that is not runner variance' — one box cannot exclude the runner" "$OUT"; fi
if [[ "$OUT" == *"WHAT IS NOT EXCLUDED"* && "$OUT" == *"probe"* ]]; then
  ok "it names what it did not exclude, and that the calibration probe cannot substitute"
else bad "it names what it did not exclude, and that the calibration probe cannot substitute" "$OUT"; fi
# The signal is PRESERVED on a rail that is not the PR gate: a count in the report, which
# is the only place a reader can compare the same file ACROSS runners. Losing the exit
# code while also losing the number would be hiding the finding, not de-escalating it.
if grep -qx '# header_drift_wrong=1' "$TMP/drift-report.txt" \
   && grep -qx '# drift_fatal_policy=off' "$TMP/drift-report.txt"; then
  ok "the report carries header_drift_wrong and the policy that governed it"
else bad "the report carries header_drift_wrong and the policy that governed it" "$(cat "$TMP/drift-report.txt" 2>&1)"; fi
# DISARMED, NOT DELETED. --drift-fatal=required restores exit 5 for a caller that has some
# other reason to trust one box; without this arm the next reader cannot tell a demoted
# control from a removed one.
run --tier=full --budget=600 --label=t --drift-fatal=required
want "--drift-fatal=required restores exit 5 (not 1, not 4)" "5" "$RC"
# Fail closed on a typo, in BOTH directions — the DIVE-2736 inertness shape: a misspelt
# policy flag that quietly picks a side is the control silently ceasing to exist.
run --tier=full --budget=600 --label=t --drift-fatal=yes
want "a misspelt --drift-fatal is usage (exit 2), never a silent default" "2" "$RC"

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

# DIVE-2801: OVER BUDGET **AND** RED. The arm above is the no-failures case; this is
# its pair. The banner used to assert "NO TEST FAILED" unconditionally inside the
# over-budget branch while computing "N of M" from the very `failed` array that
# contradicts it — a real run printed "NO TEST FAILED — 241 of 243 harnesses
# passed". That is a verdict the printer did not compute, in the output whose only
# job is to say what the red IS, and it is the same defect this row exists to fix.
# Both facts are true here and the reader needs both plus which exit wins.
rm -f "$TMP"/*.seen
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/broken.sh"
C3="$(bash "$RUNNER" --no-calibrate --corpus-dir="$TMP" --tier=full --budget=1 --label=t 2>&1)"; RC3=$?
want "over budget AND a failing harness exits 1 (the failure wins, not 4)" "1" "$RC3"
if [[ "$C3" != *"NO TEST FAILED"* ]]; then
  ok "an over-budget run WITH failures does not claim NO TEST FAILED (DIVE-2801)"
else bad "an over-budget run WITH failures still claims NO TEST FAILED (DIVE-2801)" "$C3"; fi
if [[ "$C3" == *"ALSO FAILED"* && "$C3" == *"BOTH over budget AND red"* && "$C3" == *"exits 1, not 4"* ]]; then
  ok "the both-red banner states both facts and which exit code wins (DIVE-2801)"
else bad "the both-red banner states both facts and which exit code wins (DIVE-2801)" "$C3"; fi
rm -f "$TMP/broken.sh"

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

# ------------------ DIVE-3477: THE CORPUS-GROWTH TRIPWIRE, GRADED AS ARITHMETIC
# The shard restored headroom, which is how corpus growth becomes invisible again, so
# main's ruling made a growth metric the condition it landed under: raw microseconds per
# harness against a FIXED reference, independent of shard count and of the calibration
# clamp. Those three properties are the deliverable — so they are graded HERE, on the
# function, rather than asserted in the comment beside it. An assertion in a comment is
# not a control (arm 98's own lesson, one row later).
want "us per harness is the summed wall over the summed harness COUNT" \
  "1048231" "$(tier_core_us_per_harness 326 311)"

# SHARD-COUNT INDEPENDENCE. Arm 98 pins the matrix at two; this metric must be
# indifferent to that number regardless, because a metric that moves when the matrix does
# is a metric that reports a capacity change as a corpus change. Same corpus, same total
# wall, split three ways instead of two:
want "two shards and three shards over the SAME corpus give the same figure" \
  "$(tier_core_us_per_harness $((149 + 177)) $((156 + 155)))" \
  "$(tier_core_us_per_harness $((109 + 108 + 109)) $((104 + 104 + 103)))"
want "and an UNSHARDED run of that corpus gives it too — this is the number main's runs already carry" \
  "$(tier_core_us_per_harness 326 311)" "$(tier_core_us_per_harness $((326)) $((311)))"

# The runner's own report is the only input, and a corpus that GREW must move it: 320
# harnesses at 345s is 3% dearer per harness than 311 at 326s, which is the movement a
# raw wall-clock sum against a per-shard cap cannot show once sharding restored headroom.
_g1="$(tier_core_us_per_harness 326 311)"; _g2="$(tier_core_us_per_harness 345 320)"
if (( _g2 > _g1 )); then
  ok "a corpus that grew reads DEARER even when the wall-clock barely moved — the whole point of dividing by the count"
else bad "a grown corpus reads dearer" "$_g1 vs $_g2"; fi

if tier_core_us_per_harness 326 0 >/dev/null 2>&1; then
  bad "a zero harness count REFUSES rather than dividing by it" "returned 0"
else ok "a zero harness count REFUSES rather than dividing by it"; fi

# CLAMP INDEPENDENCE, asserted on the code and not on the intent. wall/draw is circular —
# it assumes the probe explains the corpus, which is the proposition DIVE-2736 exists to
# TEST and which it marked DISCORDANT on the very run that arithmetic was applied to
# (DIVE-3476: 305s/280s by hand against 340s/353s by the instrument, a sign flip on the
# leg carrying the conclusion). So the metric must not be able to read a calibration
# field, and "must not" is a property of the function body.
_calread="$(sed -n '/^tier_core_us_per_harness()/,/^}/p' tests/lib/tier.sh \
             | grep -cE 'cal_|CAL_|SCALE|scale|effective' || true)"
want "the growth figure reads NO calibration field — the clamp is the mechanism that made growth invisible, and a metric that inherits it inherits the defect" \
  "0" "$_calread"

# THE REFERENCE IS SPELLED ONCE, beside the tier definition. Same rule as --budget and
# --cal-us: a reference spelled in the caller is moved by a one-line YAML edit that nobody
# reviews as the policy change it is.
want "the reference constant is spelled exactly once in the tree" \
  "1" "$(grep -rn '^TIER_CORE_US_PER_HARNESS_REF_PRISTINE=' --include='*.sh' --include='*.yml' . 2>/dev/null | wc -l)"
_wfref="$(grep -rnE '109415[0-9]|113398[0-9]' .github/workflows/ 2>/dev/null || true)"
if [[ -z "$_wfref" ]]; then
  ok "NO workflow spells the reference value — it comes through tier_core_us_per_harness_ref or not at all"
else bad "NO workflow spells the reference value" "$_wfref"; fi
if tier_core_us_per_harness_ref not-an-environment >/dev/null 2>&1; then
  bad "an unknown environment REFUSES rather than inventing a reference" "returned 0"
else ok "an unknown environment REFUSES rather than inventing a reference"; fi

# IT STARTS AT PARITY, WHICH IS THE ONLY REASON IT CAN SHIP. TIER_BUDGET_CORE cannot be
# met today (340s/353s at typical per-harness cost against a 300s cap), so a metric
# referenced to anything but TODAY would red on day one and be muted by the end of the
# week. The first sharded run on main, 31941359141: pristine 137s+168s over 156+155
# harnesses, installed-host 176s+168s over the same corpus.
want "the reference starts UNDER parity on run one, pristine" \
  "89" "$(tier_core_growth_pct_of_ref "$(tier_core_us_per_harness $((137 + 168)) $((156 + 155)))" pristine)"
want "the reference starts UNDER parity on run one, installed-host" \
  "97" "$(tier_core_growth_pct_of_ref "$(tier_core_us_per_harness $((176 + 168)) $((156 + 155)))" installed-host)"

# THE FIRING HALF. Split from emission deliberately: per-run us/harness moved 935483 ..
# 1148867 on main across three hours in which the corpus moved by two harnesses, so a
# per-run threshold against a fixed reference fires on the runner and gets muted. The
# window median is what survives that, and these arms grade that it does.
_TW=scripts/core-growth-tripwire.sh
_twd="$TMP/tw"; rm -rf "$_twd"; mkdir -p "$_twd"
_mkrun() {   # <file> <pristine_us> <installed_us>
  { printf 'unsharded_total_s pristine 326 311 2\n'
    printf 'core_us_per_harness pristine %s 311 2 ref=1094155 pct_of_ref=0\n' "$2"
    printf 'core_us_per_harness installed-host %s 311 2 ref=1133986 pct_of_ref=0\n' "$3"
  } > "$1"
}
for i in 1 2 3 4 5; do _mkrun "$_twd/at-ref-$i.txt" 1094155 1133986; done
_OUT="$(bash "$_TW" "$_twd"/at-ref-*.txt 2>&1)"; _RC=$?
if (( _RC == 0 )) && [[ "$_OUT" == *"pristine        CLEAR"* && "$_OUT" == *"installed-host  CLEAR"* ]]; then
  ok "a window sitting AT the reference is CLEAR — the metric does not fire on the day it ships"
else bad "a window at the reference is CLEAR" "rc=$_RC $_OUT"; fi

# A window of four is under the floor. UNDETERMINED, not CLEAR: an environment that drops
# out of the window silently is an environment nobody is watching.
_OUT="$(bash "$_TW" "$_twd"/at-ref-1.txt "$_twd"/at-ref-2.txt "$_twd"/at-ref-3.txt "$_twd"/at-ref-4.txt 2>&1)"; _RC=$?
if [[ "$_OUT" == *UNDETERMINED* && "$_OUT" != *CLEAR* && "$_OUT" != *FIRED* ]]; then
  ok "a window under the run floor reports UNDETERMINED rather than CLEAR — too few points reads exactly like enough of them"
else bad "a short window is UNDETERMINED" "rc=$_RC $_OUT"; fi

# A DRAW SPIKE MUST NOT FIRE IT. Two runs of the five drawing 141% (the census maximum)
# against three at the reference: the mean would clear 110%, the median does not.
for i in 1 2 3; do _mkrun "$_twd/spike-$i.txt" 1094155 1133986; done
for i in 4 5; do _mkrun "$_twd/spike-$i.txt" 1542758 1598920; done
_OUT="$(bash "$_TW" "$_twd"/spike-*.txt 2>&1)"; _RC=$?
if (( _RC == 0 )) && [[ "$_OUT" == *"pristine        CLEAR"* ]]; then
  ok "two runner-draw spikes in five runs do NOT fire the tripwire — a median is what survives a 74-141% draw spread, and an alarm that cries wolf is muted"
else bad "a draw spike does not fire the tripwire" "rc=$_RC $_OUT"; fi

# AND IT MUST STILL FIRE ON A REAL RISE, or it is a green that means nothing. Every run
# 15% dearer per harness.
for i in 1 2 3 4 5; do _mkrun "$_twd/grown-$i.txt" 1258278 1304084; done
_OUT="$(bash "$_TW" "$_twd"/grown-*.txt 2>&1)"; _RC=$?
if (( _RC == 0 )) && [[ "$_OUT" == *FIRED* && "$_OUT" == *"FILE A ROW"* ]]; then
  ok "a corpus 15% dearer across the whole window FIRES, and says to file a row"
else bad "a real rise FIRES" "rc=$_RC $_OUT"; fi
_OUT="$(bash "$_TW" --strict "$_twd"/grown-*.txt 2>&1)"; _RC=$?
if (( _RC == 7 )); then
  ok "--strict is the seam for an agent that wants an exit code to hang a filing action off (rc=7)"
else bad "--strict exits 7 on a fired window" "rc=$_RC"; fi

# FIRING FILES A ROW. IT DOES NOT RED A BUILD. main authorised a metric, not a gate, and
# widening one mid-ship is how a tripwire becomes a second cap nobody agreed to.
# INVOCATION, not mention. The printing job's summary text names the tripwire on purpose
# — a reader who finds the emitted figure must be able to find the thing that reads it —
# so the arm looks for the script in COMMAND position and nowhere else.
_twwf="$(grep -rhE '(^|[|&;]|bash )[[:space:]]*(\./)?scripts/core-growth-tripwire\.sh' .github/workflows/ 2>/dev/null | grep -v '^[[:space:]]*#' || true)"
if [[ -z "$_twwf" ]]; then
  ok "NO workflow runs the tripwire — firing files a row, it does not red a build, and there is no new required context"
else bad "NO workflow runs the tripwire" "$_twwf"; fi
rm -rf "$_twd"


# ------------------------ 61-73 DIVE-2736: THE PROBE IS GRADED AGAINST THE CORPUS
# THE MEASUREMENT THAT FORCED THIS, on core/installed-host, same PR, 13 minutes apart:
#
#     01:47   237 harnesses   282s   calibration 117714us/iter (68% of a normal)
#     02:00   236 harnesses   372s   calibration  82218us/iter (47% of a normal)
#
# ONE FEWER harness, 90s SLOWER corpus, and the probe reported the runner 31 points
# FASTER. That is DIVE-2710's premise inverted — the ratio's two halves moved in
# opposite directions — and because the clamp floors at 100%, a probe that under-reads
# can NEVER widen the cap. The mechanism gave zero relief on the one run it existed for.
#
# TWO THINGS SHIP HERE AND NEITHER OF THEM IS A REMEDY. A post-corpus probe (the
# discriminator between "the probe sampled the wrong moment" and "the probe measures the
# wrong mix"), and a cross-run reader. The remedy waits for the data, which is why arm 65
# below — the post probe changes NO verdict — is the load-bearing one in this section:
# wiring the second reading into the scale is a one-line edit anybody might make while
# "finishing the job", and it would ship a fix for a cause that is still n=1.
rm -f "$TMP"/*.sh "$TMP"/*.seen

# ---- 61-63 the arithmetic. SIGNED, because the two directions mean different things:
# the corpus warms the cache and biases the post probe FAST, so only "post slower"
# survives the confound. An absolute value would fold the clean signal into the dirty one.
want "the post probe reading SLOWER than the pre probe is a POSITIVE divergence" \
  "20" "$(tier_cal_diverge_pct 100000 120000)"
want "the post probe reading FASTER is NEGATIVE (the direction a warm cache also produces)" \
  "-30" "$(tier_cal_diverge_pct 100000 70000)"
if tier_cal_diverge_pct 0 100000 >/dev/null 2>&1; then
  bad "a zero pre-probe REFUSES rather than dividing by it" "returned 0"
else ok "a zero pre-probe REFUSES rather than dividing by it"; fi

# ---- 64 the report carries the pair, or the cross-run reader has nothing to read
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/w.sh"
bash "$RUNNER" --corpus-dir="$TMP" --tier=full --budget=1 --label=t \
  --cal-baseline-us=100000 --cal-us=120000 --cal-post-us=150000 --confirm-top=0 \
  --report="$TMP/rep2.txt" >/dev/null 2>&1
_miss=""
for f in cal_post_status cal_post_us_per_iter cal_post_delta_pct; do
  grep -q "^# $f=" "$TMP/rep2.txt" || _miss="$_miss $f"
done
want "the report's post-probe delta is computed, not just echoed" \
  "# cal_post_delta_pct=25" "$(grep -m1 '^# cal_post_delta_pct=' "$TMP/rep2.txt")"
if [[ -z "$_miss" ]]; then
  ok "the report carries the post-probe fields beside the pre-probe ones — a window read needs BOTH readings from the same run or it is comparing runs to each other on one number"
else bad "the report carries the post-probe fields" "missing:$_miss"; fi

# ---- 65 THE LOAD-BEARING ARM: THE SECOND PROBE GRADES NOTHING.
# 1.4s of corpus against a 1s cap on a runner measured NORMAL is exit 4. The post probe
# says 300% — under any bracket-on-max remedy that is a 150% clamp, a 1.5s cap, and a
# PASS. So this arm goes green if and only if the discriminator stayed out of the
# verdict. Paired, as the 2592 arms are, with the run that must NOT red: same post
# probe, corpus inside the cap.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --cal-post-us=300000 --confirm-top=0
want "a post probe reading 3x slow does NOT rescue an over-budget run (it is a discriminator, not an input)" "4" "$RC"
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --cal-post-us=300000 --confirm-top=0
want "and the same post probe does not RED a run that was inside its cap either" "0" "$RC"

# ---- 66-68 the three branches of the diagnosis. A branch that prints the wrong verdict
# is invisible: every branch exits 0 and the run passes regardless, so the TEXT is the
# only observable and each one has to be named separately.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --cal-post-us=104000 --confirm-top=0
if [[ "$OUT" == *"PROBE BRACKET"* && "$OUT" == *"AGREES"* && "$OUT" == *"cache"* ]]; then
  ok "probes within the threshold say AGREES — and say in the same breath that the corpus warmed what the probe pays for, so agreement is weak evidence, not a clearance"
else bad "probes within the threshold say AGREES, with the confound named" "$OUT"; fi
relrun --budget=1 --cal-us=100000 --cal-post-us=140000 --confirm-top=0
if [[ "$OUT" == *"DIVERGES"* && "$OUT" == *"SLOWER after the corpus"* && "$OUT" == *"COUNTERFACTUAL, NOT APPLIED"* ]]; then
  ok "a post probe 40% slower says DIVERGES, names the direction that survives the confound, and prints the cap a max-bracket WOULD have set — labelled as not applied"
else bad "a slower post probe prints the counterfactual, labelled as not applied" "$OUT"; fi
relrun --budget=1 --cal-us=100000 --cal-post-us=60000 --confirm-top=0
if [[ "$OUT" == *"DIVERGES"* && "$OUT" == *"FASTER after the corpus"* ]]; then
  ok "a post probe 40% faster diverges in the direction that costs nobody a red, and is reported as such rather than as the same event"
else bad "a faster post probe is reported as its own direction" "$OUT"; fi

# ---- 69 the off switch, and that it is an off switch and not a lie
relrun --budget=1 --cal-us=100000 --no-cal-post --confirm-top=0 --report="$TMP/rep3.txt"
want "--no-cal-post records the probe as skipped rather than as a reading of zero" \
  "# cal_post_status=skipped" "$(grep -m1 '^# cal_post_status=' "$TMP/rep3.txt")"

# ---- 70 no workflow injects the new seams either, same rule as --cal-us
_wfp="$(grep -rn -- '--cal-post-us=' .github/workflows/ 2>/dev/null || true)"
if [[ -z "$_wfp" ]]; then
  ok "NO workflow injects a post-probe reading — the discriminator must measure the runner it is standing on, or it discriminates nothing"
else bad "NO workflow injects a post-probe reading" "$_wfp"; fi

# ---- 71-73 the cross-run reader. TWO OF THESE ROWS ARE THE REAL MEASUREMENT (the
# 01:47 and 02:00 installed-host runs above); the third is CONSTRUCTED to complete a
# window, and is labelled so nobody later reads it as a fourth CI reading.
WIN="scripts/tier-cal-window.sh"
mkrep() { # mkrep <file> <label> <harnesses> <wall_s> <cal_us> <post_us> <delta>
  printf '# run-harnesses report\n# tier=core\n# label=%s\n# harnesses=%d\n# wall_clock_s=%d\n# cal_status=measured\n# cal_us_per_iter=%d\n# cal_post_us_per_iter=%d\n# cal_post_delta_pct=%d\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$TMP/$1"
}
mkrep r1.txt installed-host 237 282 117714 0 0      # MEASURED, gh run 30962...  01:47
mkrep r2.txt installed-host 236 372  82218 0 0      # MEASURED, gh run 30967674559 02:00
mkrep r3.txt installed-host 237 275 120693 0 0      # CONSTRUCTED to make a window of 3
_w="$(bash "$WIN" "$TMP/r1.txt" "$TMP/r2.txt" "$TMP/r3.txt" --strict 2>&1)"; _wrc=$?
if (( _wrc == 7 )) && [[ "$_w" == *"UNPROTECTED"* ]]; then
  ok "the measured anti-correlated pair is read as UNPROTECTED and FAILS --strict (exit 7) — probe below the window median while the corpus sat above it is the case the clamp floor guarantees no relief for"
else bad "the measured anti-correlated pair fails --strict as UNPROTECTED" "rc=$_wrc $_w"; fi

# A window of two has no interior. Refusing is exit 2, and exit 2 is NOT a pass — the
# same three-state the tier resolver and the runner both keep.
bash "$WIN" "$TMP/r1.txt" "$TMP/r2.txt" >/dev/null 2>&1
want "a window shorter than three REFUSES rather than reporting a verdict from an endpoint" "2" "$?"

# THE CONTROL, and it is the arm that grades the normalisation rather than the counting:
# a corpus that TRIPLES in size while the runner drifts mildly must read CONCORDANT. On
# raw wall-clock it would not — run g3 has the largest wall-clock in the window and the
# fastest probe, which is the anti-correlation signature — so this arm reds if anyone
# ever compares wall_clock_s directly, which is the obvious way to write this tool.
mkrep g1.txt pristine 100 100 100000 0 0
mkrep g2.txt pristine 200 220 110000 0 0
mkrep g3.txt pristine 300 270  90000 0 0
_g="$(bash "$WIN" "$TMP/g1.txt" "$TMP/g2.txt" "$TMP/g3.txt" --strict 2>&1)"; _grc=$?
if (( _grc == 0 )) && [[ "$_g" == *"concordant 2"* ]]; then
  ok "CORPUS GROWTH is not anti-correlation: normalising wall-clock to us/harness keeps a window concordant that raw wall-clock would have called discordant"
else bad "corpus growth is not read as anti-correlation" "rc=$_grc $_g"; fi

# ---------------------------------------------------------------------------
# DIVE-2867: THE REFERENCE-SETTING GUARD, and the harvester that makes it satisfiable.
#
# These arms live in THIS file rather than a new one on purpose. The core tier is at
# 91-111% of its cap across the last 20 main runs; a new harness costs its own setup on
# every future PR forever, and "merge by subject" is the remedy this budget's own failure
# text ranks first. The subject is the tier budget and it is already here.
#
# THE FIXTURE IS THE MEASURED WINDOW, not an invented one — the whole finding is that the
# concordant population is BIMODAL, and a hand-made fixture would not have been.
# Harvested 2026-08-08 from the last 20 `unit-tests` runs on main, CONCORDANT rows only.
# ---------------------------------------------------------------------------
CONC=(92852 96155 97360 99941 106833 117761 118000 119341 119385 119409 119419 120087 \
      120166 120409 120524 121160 121277 121807 122037 122703 122762 123341 123362 \
      123884 123901 124500 125012 125493 125513 125628 126454)

# THE ARM THE WHOLE ROW TURNS ON. 116584 was the proposed fast-end reference, and by the
# guard's PREVIOUS form ("K concordant samples strictly below") it passes at K=5. Every
# one of those five is from the fast mode. Kill the band and this arm goes green while
# the constant moves on evidence from a different population.
if _r="$(bash tests/lib/tier.sh refadmit 116584 119000 "${CONC[@]}" 2>&1)"; then
  bad "the proposed fast-end reference 116584 is REFUSED on the measured window" "admitted: $_r"
elif [[ "$_r" == *"refuse support"* && "$_r" == *"K=1"* ]]; then
  ok "a candidate supported ONLY by a distinct fast mode is REFUSED (116584 has 5 concordant samples below it and 1 within 10% — the count alone would have certified it)"
else bad "116584 is refused with K=1" "$_r"; fi

# The incumbent, on the same window, admitted — so the guard is not simply a refusal
# machine, and the arm above cannot pass by the check being broken in one direction.
if _r="$(bash tests/lib/tier.sh refadmit 119000 119000 "${CONC[@]}" 2>&1)" && [[ "$_r" == "admit raise" ]]; then
  ok "a candidate equal to the incumbent needs no evidence (not a lowering)"
else bad "119000 vs 119000 admits as a non-lowering" "$_r"; fi
if _r="$(bash tests/lib/tier.sh refadmit 119000 121000 "${CONC[@]}" 2>&1)" && [[ "$_r" == *"K=2"* ]]; then
  ok "the incumbent 119000 IS admissible as a lowering from 121000 — K=2 from 117761 and 118000, both in the normal mode"
else bad "119000 admits at K=2 with in-band support" "$_r"; fi

# ONE-SIDED, and this is the arm that stops a future edit from making the guard
# symmetric "for consistency": raising tightens toward the floor and must never need a
# sample, or the honest response to a slower runner image is blocked by the guard.
if _r="$(bash tests/lib/tier.sh refadmit 200000 119000 2>&1)" && [[ "$_r" == "admit raise" ]]; then
  ok "RAISING the reference is admitted with ZERO samples — it tightens toward the clamp floor and cannot ratchet the cap open"
else bad "raising needs no samples" "$_r"; fi
# THE SECOND CONJUNCT, and this arm is why it exists. A candidate placed INSIDE the fast
# mode PASSES the support test at K=4 off its own neighbours — the band proves local
# density and cannot tell a dense fast mode from the low tail of the working one. Only
# the bounded-cost half catches it. Delete either conjunct and one of these two arms goes
# green on a reference that hands the typical run a 363s cap against a 300s policy.
_r="$(bash tests/lib/tier.sh refadmit 100000 119000 "${CONC[@]}" 2>&1)"; _rc=$?
if (( _rc != 0 )) && [[ "$_r" == *"refuse cost"* ]]; then
  ok "a candidate down in the fast mode is refused on BOUNDED COST, not on support — it has K=4 neighbours and still scales the median run to 121% (363s cap). Support and cost catch different things and neither alone is sufficient"
else bad "a fast-mode candidate is refused on cost" "rc=$_rc $_r"; fi

# Fail closed with nothing to measure against: "no samples" and "the cost is fine" are
# different answers and only one of them is a pass.
_r="$(bash tests/lib/tier.sh refadmit 118000 119000 117900 117950 2>&1)"; _rc=$?
if (( _rc == 0 )) && [[ "$_r" == *"median-widen"* ]]; then
  ok "an admitted lowering REPORTS the widening it bought, so the cost is in the output rather than in the reviewer's head"
else bad "an admitted lowering prints its median-widen" "rc=$_rc $_r"; fi

# The harvester. Graded on a SAVED log rather than a live gh call: a test that needs
# credentials and a network is a test that gets skipped, and a skip on the arm that
# proves the window can be rebuilt is exactly the silence this row is about.
HARV="scripts/tier-cal-harvest.sh"
if [[ -x "$HARV" ]]; then
  printf 'test\tUNKNOWN STEP\t2026-01-01T00:00:00Z harness-budget[core/pristine]: 254 harnesses, 283s wall-clock, budget 300s (94%% of budget)\n' > "$TMP/fake.log"
  printf 'test\tUNKNOWN STEP\t2026-01-01T00:00:01Z harness-budget[core/pristine]: CALIBRATION (measured) 119385us/iter vs baseline 119000us/iter = 100%% of a normal\n' >> "$TMP/fake.log"
  printf 'test\tUNKNOWN STEP\t2026-01-01T00:00:02Z   runner; applied 100%% (clamp 100-150%%) -> effective cap 300s. This run is 94%% of the RAW cap\n' >> "$TMP/fake.log"
  printf 'test\tUNKNOWN STEP\t2026-01-01T00:00:03Z   and 94%% of the EFFECTIVE cap. Raw high + effective low = the VM was slow; both high =\n' >> "$TMP/fake.log"
  printf 'test\tUNKNOWN STEP\t2026-01-01T00:00:04Z harness-budget[core/pristine]: PROBE BRACKET (DIVE-2736) pre 119385us/iter -> post 119349us/iter (+0%%),\n' >> "$TMP/fake.log"
  # A SECOND JOB in the same stream, with a different probe. Two jobs interleave in a
  # real `gh run view --log` and their budget blocks are byte-similar, so keying on the
  # harness-budget label instead of the job column would merge two runners into one
  # sample — which is the one parsing mistake that would silently corrupt the window.
  printf 'test-installed-host\tUNKNOWN STEP\t2026-01-01T00:00:05Z harness-budget[core/installed-host]: 255 harnesses, 335s wall-clock, budget 300s (111%% of budget)\n' >> "$TMP/fake.log"
  printf 'test-installed-host\tUNKNOWN STEP\t2026-01-01T00:00:06Z harness-budget[core/installed-host]: CALIBRATION (measured) 100111us/iter vs baseline 119000us/iter = 84%% of a normal\n' >> "$TMP/fake.log"
  printf 'test-installed-host\tUNKNOWN STEP\t2026-01-01T00:00:07Z   runner; applied 100%% (clamp 100-150%%) -> effective cap 300s. This run is 111%% of the RAW cap\n' >> "$TMP/fake.log"

  bash "$HARV" --from-log="$TMP/fake.log" --run=31192491258 --sha=deadbee --out="$TMP/harv" >/dev/null 2>&1
  _p="$TMP/harv/31192491258-test.report"; _i="$TMP/harv/31192491258-test-installed-host.report"
  if [[ -r "$_p" && -r "$_i" ]] \
     && grep -q '^# cal_us_per_iter=119385$' "$_p" && grep -q '^# wall_clock_s=283$' "$_p" \
     && grep -q '^# cal_us_per_iter=100111$' "$_i" && grep -q '^# wall_clock_s=335$' "$_i"; then
    ok "the harvester rebuilds one report PER JOB from a single interleaved run log, and does not merge two runners into one sample"
  else bad "harvest splits an interleaved log by job column" "$(ls -1 "$TMP/harv" 2>&1)"; fi

  # ABSENCE IS ABSENT. The log does not carry a probe bracket for installed-host in the
  # fixture above, and a zero-filled cal_post_us_per_iter would be read by
  # tier-cal-window.sh as a measured -100% bracket — a fabricated finding, not a gap.
  if grep -q '^# cal_post_us_per_iter=119349$' "$_p" && ! grep -q '^# cal_post_' "$_i"; then
    ok "a field the log did not carry is OMITTED, never zero-filled — an absence encoded as a value is read as presence, and this one feeds arithmetic"
  else bad "missing bracket fields are omitted rather than zero-filled" "$(grep -c cal_post "$_i" 2>&1)"; fi

  # Provenance is not optional: a harvested number with no run id is 173000 again.
  bash "$HARV" --from-log="$TMP/fake.log" --out="$TMP/harv2" >/dev/null 2>&1
  want "harvesting WITHOUT a run id refuses (a sample that cannot name its runner is not evidence)" "2" "$?"

  # An empty harvest must not read as a clean window.
  : > "$TMP/empty.log"
  bash "$HARV" --from-log="$TMP/empty.log" --run=1 --out="$TMP/harv3" >/dev/null 2>&1
  want "a harvest that finds NOTHING exits 6 rather than 0 — an empty window is not a window" "6" "$?"

  # The window tool must consume harvested reports UNCHANGED. If this ever needs a
  # translation layer, the harvester has drifted from the report format it mimics.
  bash "$HARV" --from-log="$TMP/fake.log" --run=2 --out="$TMP/harv" >/dev/null 2>&1
  bash "$HARV" --from-log="$TMP/fake.log" --run=3 --out="$TMP/harv" >/dev/null 2>&1
  if bash "$WIN" "$TMP"/harv/*.report >/dev/null 2>&1; then
    ok "scripts/tier-cal-window.sh reads harvested reports with no changes — the window's stated blocker ('reports do not persist') was never true of the fields it reads"
  else bad "window consumes harvested reports unchanged" "$(bash "$WIN" "$TMP"/harv/*.report 2>&1 | tail -3)"; fi
else
  bad "scripts/tier-cal-harvest.sh is executable" "not found or not +x"
fi

# ------------- 74-82 DIVE-2829: THE OVER-BUDGET RED STOPS ASSERTING A CAUSE IT LACKS
# THE MEASUREMENT THAT FORCED THIS is the pair the row was filed on — 828c1ea, run
# 31051177868, the one that froze release-cut.yml for ~40 minutes:
#
#              corpus        pre probe        post probe   bracket
#   attempt 1  416s (138%)   110990us = 93%   -10%         AGREES  -> exit 4, main red
#   attempt 2  245s ( 81%)   106833us = 89%    +0%         AGREES  -> green
#
# Same sha, same corpus, same job name, 1.70x apart. And BOTH attempts printed AGREES,
# from pre probes four points apart that both clamped to 100%. The calibration machinery
# resolved a 70-point corpus swing as 4 points of probe.
#
# THAT KILLED THE REMEDY THIS ROW RECOMMENDED (promote the post probe to grading on the
# red path). On the slow attempt the post probe read FASTER, so a promotion keyed on
# "post slower" would not have fired on the run it was built for. Arm 65 above therefore
# STANDS, and these arms exist because what CAN be fixed from inside one job is not the
# verdict but the CLAIM: the red used to say "the CORPUS no longer fits its cap", which
# on this pair was false, and false in the direction that costs real coverage.
#
# PAIRED THROUGHOUT, per the rule the 2592 and 2728 arms already follow: an arm asserting
# that a STRING IS ABSENT passes trivially if the whole block stopped printing, so every
# absence below is paired with a presence in the same output.
rm -f "$TMP"/*.sh "$TMP"/*.seen

# ---- 74-77 the red path: 1.4s of corpus, 1s cap, runner measured NORMAL. Still exit 4 —
# this is the control whose expected value is NON-ZERO, without which every arm below is
# satisfied by a verdict that simply stopped firing.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0
want "CONTROL: a genuinely over-cap corpus on a NORMAL runner still exits 4" "4" "$RC"
if [[ "$OUT" != *"no longer fits its cap"* ]]; then
  ok "the red no longer asserts 'the CORPUS no longer fits its cap' — a cause, asserted from a sum that cannot separate the two causes, and measured WRONG on 828c1ea"
else bad "the red no longer asserts the corpus-growth cause" "$OUT"; fi
if [[ "$OUT" == *"WHAT IS MEASURED"* && "$OUT" == *"WHAT IS NOT EXCLUDED"* && "$OUT" == *"NO TEST FAILED"* ]]; then
  ok "it says what it measured and names the runner as the thing it did NOT exclude, keeping the budget-vs-test distinction it already had"
else bad "the red says what it measured and what it did not exclude" "$OUT"; fi
if [[ "$OUT" == *"RE-RUN THIS JOB ON THE SAME SHA"* && "$OUT" == *"DIFFERENT"* ]]; then
  ok "the re-run on a DIFFERENT runner is named as the first action — the only discriminator with a measured track record, and it settled this twice"
else bad "the re-run is named as the first action" "$OUT"; fi

# ---- 78 THE PAIR. Same corpus inside the cap: none of the above prints. Without this,
# arm 75 is also satisfied by a runner that prints nothing at all on the red path.
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0
if (( RC == 0 )) && [[ "$OUT" != *"RE-RUN THIS JOB ON THE SAME SHA"* && "$OUT" != *"WHAT IS NOT EXCLUDED"* ]]; then
  ok "PAIR: a run inside its cap prints none of the over-budget block — the arms above are about the RED path, not about the runner having gone quiet"
else bad "PAIR: a run inside its cap prints none of the over-budget block" "rc=$RC $OUT"; fi

# ---- 79 the DIVE-2592 confirmation line is SCOPED. "measured TWICE ... so it is not
# variance" was the sentence that made a same-runner pair sound like a settled question.
# Both samples share a runner, so it excludes the noise it can see and nothing else.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000
if (( RC == 4 )) && [[ "$OUT" == *"measured TWICE"* && "$OUT" == *"does NOT rule out the runner"* \
      && "$OUT" != *"so it is not variance"* ]]; then
  ok "the two-sample confirmation now says WHICH variance it excluded — within this runner — and states that both samples share the runner it cannot exclude"
else bad "the confirmation line scopes itself to within-runner noise" "rc=$RC $OUT"; fi

# ---- 80 the scaled-cap line stops concluding the same thing one level up. Surviving the
# allowance bounds what a SLOW PROBE could explain; the probe is the thing measured blind.
printf '#!/usr/bin/env bash\nsleep 1.6\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=140000 --confirm-top=0
if (( RC == 4 )) && [[ "$OUT" == *"does not bound the runner"* \
      && "$OUT" != *"makes this the corpus and not the VM"* ]]; then
  ok "a red that survived the scaled cap no longer concludes 'the corpus and not the VM' — the allowance is only as good as the probe, and the probe is blind on the one pair we can grade it against"
else bad "the scaled-cap red does not conclude corpus-not-VM" "rc=$RC $OUT"; fi

# ---- 81 AGREES carries the falsification, in the output, on every calibrated run. This
# is the arm that stops the recommended remedy being re-derived from priors: the next
# reader of "AGREES" meets the pair where AGREES printed on BOTH sides of a 1.70x split.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --cal-post-us=104000 --confirm-top=0
if [[ "$OUT" == *"AGREEMENT IS NOT A CLEARANCE"* && "$OUT" == *"1.70x"* && "$OUT" == *"416s"* ]]; then
  ok "the AGREES branch carries the measured pair — agreement means the probe saw nothing, not that there was nothing to see, and the number is there so the next reader does not have to take that on trust"
else bad "the AGREES branch carries the measured pair" "$OUT"; fi

# ---- 82 AND THE INVARIANT ARM 65 PROTECTS IS RESTATED WITH ITS NEW REASON. The post
# probe still grades nothing, in BOTH directions, and it is no longer a "wait for data"
# holding position — the data arrived and said the probe cannot see this factor.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --cal-post-us=40000 --confirm-top=0
want "a post probe reading 2.5x FAST does not red-shift the verdict either — the discriminator is out of the exit code in both directions, now for a measured reason" "4" "$RC"

# ------------- 83-91 DIVE-2829 iteration 2: A SINGLE RUNNER CANNOT RED main ALONE
# The arms above fixed the CLAIM. These fix the VERDICT, and they are the two arms the
# row's acceptance names — a slow-runner arm that must NOT red, and the control that
# must still red — plus the one-sidedness and fail-closed cases that keep the first from
# being an escape hatch.
#
# WHY THIS SHAPE AND NOT THE ROW'S OWN RECOMMENDED ONE: the post-corpus discriminator is
# measured BLIND to this factor (arms 81/82 and the note at run-harnesses.sh). What is
# left is the discriminator that has settled it twice in the record — a second sample
# from a DIFFERENT box — and the only reason it was deprioritised (olivia, DIVE-2828) was
# the cost of a second corpus run. That cost is now paid ONLY on the red path, which is
# the ~1-in-N of runs where the alternative was ~40 minutes of frozen release cut.
#
# THE SEAM IS EQUALITY ON A STRING, deliberately. The harness injects the confirmation
# state the same way it injects --cal-us, so every arm below grades the GATE and not the
# runner it happens to be on — the DIVE-2555 §4 rule this whole file is built around.
rm -f "$TMP"/*.sh "$TMP"/*.seen

# ---- 83 THE ACCEPTANCE'S FIRST ARM. Over the cap, one box, nobody else has looked.
# Exit 6, not 4. This is the 2026-08-05 run: on this branch before this change it exited
# 4, main went red and the cut froze.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required --runner-id=box-a
want "SLOW-RUNNER ARM: over the cap on ONE box, unconfirmed, is UNDETERMINED (6) and not OVER BUDGET (4)" "6" "$RC"
if [[ "$OUT" == *"NOT CONFIRMED ON A SECOND RUNNER"* && "$OUT" == *"ONE sample from ONE box"* ]]; then
  ok "and it says which sample it has and which it lacks, rather than reporting a cap it could not grade"
else bad "the unconfirmed red names the missing second runner" "$OUT"; fi

# ---- 84 THE ACCEPTANCE'S SECOND ARM, the control whose expected value is non-zero. The
# SAME corpus, the SAME cap, once a DIFFERENT box has already gone over: still exit 4.
# Without this, arm 83 is satisfied by a gate that simply never reds.
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required \
  --runner-id=box-b --prior-over-runner=box-a
want "CONTROL: the same over-cap corpus, confirmed by a DIFFERENT box, still exits 4" "4" "$RC"
if [[ "$OUT" == *"CONFIRMED ON A SECOND RUNNER"* && "$OUT" == *"IS about your corpus"* ]]; then
  ok "and only THEN does the output tell the reader the finding is about their corpus — the sentence arm 74 stopped it asserting on one sample"
else bad "the confirmed red claims the corpus, and only when confirmed" "$OUT"; fi

# ---- 85 a second ATTEMPT is not a second RUNNER. The DIVE-2592 confirmation re-times on
# the same box and calls that "not variance"; this is the same mistake one level up, and
# it is the one an operator makes by hand when they re-run and paste the same id.
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required \
  --runner-id=box-a --prior-over-runner=box-a
want "a prior over-budget sample from the SAME box id does not confirm anything — exit 6" "6" "$RC"
if [[ "$OUT" == *"second ATTEMPT, not a second RUNNER"* ]]; then
  ok "and it names the attempt-vs-runner distinction, which is exactly what the same-runner confirmation above it cannot see"
else bad "the same-box case names attempt vs runner" "$OUT"; fi

# ---- 86 FAIL CLOSED. Armed but unable to identify itself: it cannot prove it is a
# different box, so it is not credited with a sample. The alternative — treat an unnamed
# box as distinct — is an escape hatch reachable by omitting an argument.
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required \
  --prior-over-runner=box-a
want "armed with NO --runner-id fails CLOSED to UNDETERMINED rather than crediting an unnamed box" "6" "$RC"

# ---- 87 ONE-SIDED, PROVEN ON THE GREEN PATH. The gate must be unable to turn a passing
# run into anything at all. An arm asserting a string is ABSENT passes trivially if the
# block stopped printing, so this also asserts the run's own verdict.
printf '#!/usr/bin/env bash\nsleep 0.3\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required --runner-id=box-a
if (( RC == 0 )) && [[ "$OUT" != *"NOT CONFIRMED ON A SECOND RUNNER"* && "$OUT" != *"OVER BUDGET"* ]]; then
  ok "ONE-SIDED: a run INSIDE its cap is untouched by --cross-runner=required — the gate can only ever move a 4 to a 6, never a green to a red and never a red to a green"
else bad "cross-runner=required leaves a passing run alone" "rc=$RC $OUT"; fi

# ---- 88 A FAILING HARNESS STILL DOMINATES. Exit 1 outranks 6 for the same reason it
# outranks 4: an unmeasurable box must never hide a broken test.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 1\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=required --runner-id=box-a
want "a FAILED harness still exits 1 under an unconfirmed over-budget run — the ladder order is unchanged" "1" "$RC"

# ---- 89 DEFAULT IS OFF, and the default path is byte-for-byte the one arms 74-82 grade.
# This is what keeps the change from being a silent policy edit for every other caller.
printf '#!/usr/bin/env bash\nsleep 1.4\nexit 0\n' > "$TMP/w.sh"
relrun --budget=1 --cal-us=100000 --confirm-top=0
if (( RC == 4 )) && [[ "$OUT" == *"DO THIS FIRST: RE-RUN THIS JOB ON THE SAME SHA"* \
      && "$OUT" != *"NOT CONFIRMED ON A SECOND RUNNER"* ]]; then
  ok "DEFAULT OFF: with no --cross-runner the verdict and the text are unchanged — a caller that has no second box still gets the advisory it had, not a gate it cannot satisfy"
else bad "the default is off and unchanged" "rc=$RC $OUT"; fi

# ---- 90 an unrecognised MODE is usage, not a silent disarm. DIVE-2736's inertness was
# a control that stopped existing while everything still printed; a typo'd flag is the
# one-character version of it.
relrun --budget=1 --cal-us=100000 --confirm-top=0 --cross-runner=requried
want "a misspelt --cross-runner mode is exit 2 usage, never a silent fall back to off" "2" "$RC"

# ---- 91 THE WIRING IS PART OF THE REMEDY. A gate that no caller arms grades nothing —
# which is the exact failure this row was filed about (a discriminator that ships, runs
# and is wired to nothing). So the workflow that reds `main` is asserted here, by the
# same file that grades the gate, rather than left to a reviewer noticing the YAML.
_wf="$(dirname "${BASH_SOURCE[0]}")/../.github/workflows/unit-tests.yml"
if [[ -f "$_wf" ]]; then
  _armed=$(grep -c -- '--cross-runner=required' "$_wf")
  _prior=$(grep -c -- '--prior-over-runner=' "$_wf")
  if (( _armed >= 3 && _prior >= 2 )); then
    ok "unit-tests.yml ARMS the gate on both core jobs and carries a confirm job for each ($_armed armed invocations, $_prior confirming) — the remedy is wired to the workflow that reds main, not merely available to it"
  else bad "unit-tests.yml arms the cross-runner gate on both core jobs" "armed=$_armed prior=$_prior"; fi
else bad "unit-tests.yml is readable from the harness" "no file at $_wf"; fi

# ---- 92-96 DIVE-3315: THE SPLIT, AND THE FOUR NAMES THE MERGE GATE KNOWS
# core is TWO independently capped jobs per environment now. The corpus read 313s against
# a 312s effective cap with ~6% runner spread, and the trimming levers were measured
# exhausted (~7s available against ~13s needed, olivia's by-construction census on
# DIVE-3313), so a cap breached by 1s on the draw of a runner was presenting as a flaky
# test. The cap is PER JOB, so two shards of ~157s each hold the SAME 300s: the corpus is
# split, the constraint is not relaxed.
#
# Four things have to stay true or the split is a capacity raise in disguise, a broken
# merge gate, or both. All four are graded by PARSING the workflow, not by grepping it —
# a `grep 'always()'` matches the comment that explains why it is there, which is the
# vacuity this file keeps re-learning (see the jobs_missing_build arm above).
#
#   92  the four REQUIRED status-check names still exist as jobs. `test` is required on
#       main; a matrix job reports as `test (1)`, so sharding under the old name leaves
#       the required context unable to ever report and every PR waits on a check that
#       cannot arrive. The names survive as aggregators over the shards.
#   93  those aggregators FAIL CLOSED. A job skipped because its dependency failed
#       reports SKIPPED, and GitHub counts a skipped required check as satisfied — so the
#       one-line `needs:`-only version passes the merge gate exactly when the corpus went
#       red. `if: always()` plus an explicit .result comparison, or it is not a gate.
#   94  every core invocation is sharded, and the DIVISOR is the matrix length rather
#       than a literal — a divisor spelled twice drifts, and the runner would then split
#       the corpus a different number of ways than the matrix runs it.
#   95  one job re-sums the shards and prints the UN-SHARDED total. Two shards reporting
#       157s read as comfortable while the corpus still costs 313s; sharding is the
#       obvious way to lose the number the whole tier scheme exists to surface.
#   96  and that total is PRINTED, NEVER ENFORCED, and nothing gates on the job that
#       prints it. Held to the 300s per-job cap the sum reads 313 > 300 on day one and
#       the split fixes nothing — the number is an instrument, not a second budget.
_wf3315="$(dirname "${BASH_SOURCE[0]}")/../.github/workflows/unit-tests.yml"
if [[ -r "$_wf3315" ]]; then
  while IFS=$'\t' read -r _v _name _detail; do
    [[ -n "$_v" ]] || continue
    if [[ "$_v" == ok ]]; then ok "$_name"; else bad "$_name" "$_detail"; fi
  done < <(python3 - "$_wf3315" <<'PY' 2>&1
import re, sys, yaml
wf = sys.argv[1]
d = yaml.safe_load(open(wf)) or {}
jobs = d.get('jobs') or {}
def chk(good, name, detail=''):
    print('%s\t%s\t%s' % ('ok' if good else 'bad', name, detail.replace('\t', ' ')))
def runs(job):
    return [s.get('run') or '' for s in (job.get('steps') or []) if isinstance(s, dict)]

# 92 — the names branch protection requires, pinned here so a rename is a red in the
# repo rather than a queue of PRs blocked on a context that will never report.
REQUIRED = ['test', 'test-installed-host', 'test-confirm', 'test-installed-host-confirm']
missing = [c for c in REQUIRED if c not in jobs]
chk(not missing,
    'every REQUIRED status check on main is still a job NAME in unit-tests.yml (sharding must not rename the merge gate out from under branch protection)',
    'missing: ' + ','.join(missing))

# 93 — fail closed. Grades the aggregator's `if:` and the presence of a .result test.
bad_agg = []
for c in REQUIRED:
    j = jobs.get(c) or {}
    if str(j.get('if', '')).strip() != 'always()':
        bad_agg.append('%s: if=%r, so a failed dependency SKIPS it and a skipped required check reads as satisfied' % (c, j.get('if')))
        continue
    if not any('.result' in r for r in runs(j)):
        bad_agg.append('%s: runs always() but never compares a dependency .result — it is green by construction' % c)
chk(not bad_agg,
    'each required check RUNS on always() and asserts its dependencies\' .result (a bare needs: is satisfied by a skip, which is the merge gate passing precisely when the corpus went red)',
    ' | '.join(bad_agg))

# 94 — sharded, with the divisor taken from the matrix length.
bad_shard, sharded = [], 0
for jn, j in jobs.items():
    for r in runs(j):
        flat = re.sub(r'\\\n\s*', ' ', r)
        for line in flat.splitlines():
            if 'run-harnesses.sh' not in line or '--tier=core' not in line:
                continue
            # NOT \S+: the value is `${{ matrix.shard }}/${{ strategy.job-total }}`, which
            # contains spaces, and splitting on the first one reads the divisor as `${{`.
            m = re.search(r'--shard=(.+?)(?=\s+--|\s*$)', line)
            if not m:
                bad_shard.append('%s: a core invocation with no --shard=' % jn)
                continue
            sharded += 1
            div = m.group(1).split('/')[-1]
            if not re.search(r'strategy\.job-total|matrix\.shards', div):
                bad_shard.append('%s: literal divisor %s — spelled twice, it drifts from the matrix' % (jn, div))
chk(sharded >= 4 and not bad_shard,
    'every core invocation in unit-tests.yml is SHARDED and takes its divisor from the matrix length, in both environments and in both confirm jobs (%d invocations)' % sharded,
    ' | '.join(bad_shard) or 'sharded=%d' % sharded)

# 95/96 — the un-sharded total: printed, and wired to nothing.
summ = [jn for jn, j in jobs.items()
        if any('wall_clock_s' in r and 'GITHUB_STEP_SUMMARY' in r for r in runs(j))]
chk(len(summ) == 1,
    'exactly one job re-sums the shards and prints the UN-SHARDED core total (per-shard is what the budget enforces; the total is what the trend is read from)',
    'jobs printing a re-summed total: %s' % (summ or 'none'))
if len(summ) == 1:
    jn = summ[0]
    body = '\n'.join(runs(jobs[jn]))
    gated = re.findall(r'exit\s+[1-9]\b|\|\|\s*exit|exit\s+"\$\{?rc', body)
    def needs_of(j):
        n = j.get('needs')
        return [n] if isinstance(n, str) else (n or [])
    depended = [o for o, j in jobs.items() if jn in needs_of(j)]
    # 96 — the total's VALUE is graded by nothing. Its PRODUCTION is graded next door, and
    # that dependent is the one thing allowed to need this job: a presence check is not a
    # budget. So the arm reads WHAT the dependent does rather than counting dependents —
    # a job that reads `unsharded_total_s` and never mentions a budget is the permitted
    # shape, and anything else that hangs off the printing job is a second cap arriving
    # through the back door. Comments are stripped first: this file's own remedy text says
    # "budget" in a comment, and an arm that reads the prose instead of the code is the
    # vacuity the jobs_missing_build arm above already learned once.
    def code_of(job):
        out = []
        for r in runs(job):
            for ln in r.splitlines():
                if not ln.strip().startswith('#'):
                    out.append(ln)
        return '\n'.join(out)
    stray, valuey = [], []
    for o in depended:
        c = code_of(jobs[o])
        if 'unsharded_total_s' not in c:
            stray.append(o)
        elif re.search(r'budget|TIER_BUDGET|\b300\b', c):
            valuey.append(o)
    chk(not gated and not stray and not valuey,
        'the un-sharded total is PRINTED, NEVER ENFORCED — the printing job exits 0 on every path, and the only job allowed to depend on it is the one that grades whether the figure was PRODUCED, which may not mention a budget (an enforced sum is 331 > 300 on day one and the split would fix nothing)',
        'gating exits: %s; dependents that are not the presence check: %s; dependents that compare it to a budget: %s'
        % (gated or 'none', stray or 'none', valuey or 'none'))

# 97 — AND IT MUST NOT BE SWITCHABLE OFF. Found by quinn grading this row's own PR: a
# one-line `if: false` on the total-printing job SURVIVES arms 95 and 96 at 140/0. 95 grades
# the job's EXISTENCE and 96 grades that it does not gate — the job is still in the `jobs`
# map, still carries the step, still matches every pattern, and never runs again. And because
# the total deliberately gates nothing (arm 96 is the reason), nothing else reds either: the
# instrument that keeps the corpus legible is turned off in one line with every check green.
#
# 96 says the total must not GATE. This says it must not be GATEABLE. They are not the same
# claim, and the first one being green is what made the second one invisible.
#
# THE GENERAL SHAPE, because it is the second wrong-object guard measured on 2026-08-12 (the
# other read a log's mtime, which shows a cron FIRED rather than that its work SUCCEEDED):
# an arm asserts a property OF AN OBJECT, and a parsed workflow offers two objects that read
# alike — the job as WRITTEN and the job as RUN. Name which one the property lives on. Here
# it is liveness, so `if:` is part of the assertion and not decoration.
#
#   community/wiki/a-presence-arm-cannot-see-a-job-disabled-with-if-false.md
#
# No `if:` at all, or exactly `always()`. Anything else — `false`, a `github.event_name`
# test, `success()` — reds, because a total that is conditional is a total that can be absent
# without anything saying so. `always()` is required rather than merely allowed for the same
# reason it is required on the aggregators (arm 93): the runs worth summarising most are the
# ones that went over, and those are the runs where a shard failed.
if len(summ) == 1:
    jn = summ[0]
    # 97a — the WEAK half, labelled weak so nobody mistakes it for the check. A parsed `if:`
    # sees one of the five causes of an absent figure. Kept because it is free and it fails at
    # review time, NOT because it grades production.
    cond = jobs[jn].get('if')
    cond_s = '' if cond is None else str(cond).strip()
    chk(cond_s in ('', 'always()'),
        'DECLARED liveness only (weak, and not the check): the printing job carries no `if:` or exactly always() — this sees `if: false` and nothing else, so 97b below is the arm that matters',
        'if=%r on job %s' % (cond, jn))

    # 97b — THE ARM THAT MATTERS: something grades the figure that was EMITTED. Four
    # properties, because each one alone is satisfiable by a job that grades nothing:
    #   exists      a job reads the machine-readable line out of the run's own output
    #   can fail    it exits non-zero on an absence (a reader that cannot red is a print)
    #   no value    it does not compare the figure to a budget (that is arm 96's clause,
    #               asserted from the other side)
    #   is required every required-name aggregator lists it, or it is a job that can sit
    #               red for a week with the merge gate green
    graders = [o for o, j in jobs.items()
               if jn in needs_of(j) and 'unsharded_total_s' in code_of(j)]
    problems = []
    if not graders:
        problems.append('no job reads unsharded_total_s out of the emitted output')
    for g in graders:
        c = code_of(jobs[g])
        # NOT a search for "return 1 appears somewhere". Measured: removing the job's
        # propagation (`|| rc=1` -> `|| true`, `exit "$rc"` -> `exit 0`) left the `return 1`s
        # inside its helper untouched, so a permissive search stayed GREEN on a job that can
        # no longer fail — output saying failure over a status saying success. The status is
        # what CI reads, so grade the LAST exit: it must propagate a variable or be non-zero.
        exits = re.findall(r'^\s*exit\s+(\S+)', c, re.M)
        if not exits or exits[-1] in ('0',):
            problems.append('%s ends with `exit %s` — it cannot fail whatever it prints'
                            % (g, exits[-1] if exits else '(none)'))
        # And it must PROVE it can fail, on every run, in both directions. A structural arm
        # in this file cannot know whether the CI job still reds on a broken production —
        # only the job's own positive control can, so the arm asserts the control EXISTS and
        # the job refuses to report a green without it (DIVE-3317's keeper).
        if 'SELFTEST FAIL' not in c or c.count('SELFTEST FAIL') < 3:
            problems.append('%s carries no positive control with all three arms (absent -> red, empty -> red, real -> green)' % g)
        if not re.search(r'if\s+!\s+selftest', c):
            problems.append('%s does not refuse to report a green when its own control fails' % g)
    REQUIRED_AGG = ['test', 'test-installed-host']
    for agg in REQUIRED_AGG:
        n = needs_of(jobs.get(agg) or {})
        if not any(g in n for g in graders):
            problems.append('required check %s does not require the figure to have been produced' % agg)
    chk(not problems,
        'the EMITTED figure is graded: a job reads the un-sharded total out of the run output, can fail on its absence, never compares it to a budget, and both required checks require it (an if:-only arm survives a broken glob, a renamed step, an early return and a dropped upload — measured)',
        ' | '.join(problems))

# 98 — THE SHARD COUNT IS A PINNED NUMBER, NOT A SENTENCE. Found by codex grading this
# row's own PR: changing BOTH core matrices from [1, 2] to [1, 2, 3] passes 142/0. Every
# arm above stays green because every one of them is about the shape of the split and not
# its SIZE — 94 asks that a divisor be taken from the matrix length and is happier the
# longer the matrix gets, 95/96/97 are about the total being printed and ungated, and 92/93
# key on aggregator names that were deliberately built to survive a shard-count change
# (`the contract with the merge gate is the aggregator's name, not the corpus's shape`).
# So the one property nothing held was N.
#
# This job's own header says a third shard `is exactly as visible, and exactly as much a
# policy decision, as raising the number would have been`. Measured, it was neither: the
# mutation adds a full extra independently-capped job per environment — the same capacity a
# forbidden TIER_BUDGET_CORE raise would buy — and arrives silently, on green.
#
# THAT IS THIS ROW'S OWN DEFECT ONE LEVEL OUT, and main's lead review predicted it in
# advance (residual 4): `an assertion in a comment is not a control`. The row shipped an
# honesty instrument, then a guard for the instrument (97), and the guard for the SIZE was
# left as prose. Written down because the class keeps recurring, not because the fix is
# clever: a rule that names itself a policy decision must be enforced by something that
# reds, or the next reader satisfies it by editing one character.
#
#   community/wiki/an-assertion-in-a-comment-is-not-a-control.md
#
# WHAT THIS IS NOT. It is not a second budget and it does not touch one: TIER_BUDGET_CORE,
# the calibration cap and the runner scaling factor are all untouched by this arm and by
# this commit. It pins N, and N only.
#
# THE POLICY MECHANISM the exception rides on is this constant. The number is spelled ONCE
# here, so raising it is a deliberate edit to a test file, in the diff, next to a message
# that says what it costs — reviewable in the same way and at the same weight as raising
# the cap, which is exactly the standing rule main set. A workflow-only change to [1, 2, 3]
# now reds; a change that means it must come back as a gate and move this line too.
#
# FAIL CLOSED, because the interesting evasions are not `3`:
#   * a computed matrix (`shard: ${{ fromJson(...) }}`) moves N out of this file and out of
#     review entirely — a non-literal reds rather than being skipped as unparseable
#   * `matrix: { include: [...] }` with three entries drops the `shard` key, so counting
#     only jobs that HAVE the key would silently grade nothing — the count of sharded core
#     corpus jobs is asserted too, at exactly one per environment
#   * a third capacity job added ALONGSIDE the two (`core-pristine-3`) never touches a
#     matrix at all, and is caught by that same count
# `strategy.job-total` stays the runner's divisor throughout: arm 94 requires it and this
# arm deliberately does not introduce a literal 2 into the workflow to satisfy itself. The
# matrix stays the single source of N; this file is the single source of what N may BE.
CORE_SHARDS = 2

def matrix_of(job):
    s = job.get('strategy')
    return s.get('matrix') if isinstance(s, dict) else None

core_jobs = [jn for jn, j in jobs.items()
             if any('run-harnesses.sh' in r and '--tier=core' in r for r in runs(j))]
# The confirm jobs are core invocations too, but their matrix is `include:` built at run
# time from the shards that went over (one entry per over-budget shard, possibly none). N
# is not declared there and must not be pinned there — the corpus jobs are the ones that
# DECLARE the split, and they are the ones this arm is about.
declared = {jn: matrix_of(jobs[jn]).get('shard')
            for jn in core_jobs
            if isinstance(matrix_of(jobs[jn]), dict) and 'shard' in matrix_of(jobs[jn])}

want = list(range(1, CORE_SHARDS + 1))
shard_problems = []
if len(declared) != 2:
    shard_problems.append(
        'expected exactly 2 core corpus jobs declaring a literal shard matrix, one per '
        'environment; found %d (%s) — a core job that does not declare its shards puts N '
        'somewhere this arm cannot read it'
        % (len(declared), ', '.join(sorted(declared)) or 'none'))
for jn in sorted(declared):
    v = declared[jn]
    if not isinstance(v, list) or not all(isinstance(x, int) for x in v):
        shard_problems.append(
            '%s: shard matrix %r is not a literal list of integers — a computed matrix '
            'sets the shard count outside this file, where no review sees it' % (jn, v))
    elif v != want:
        shard_problems.append(
            '%s: shard matrix is %r, pinned at %r — each shard is another independently '
            'capped job, so this is a capacity change of the same weight as raising '
            'TIER_BUDGET_CORE and must come back as a gate (then move CORE_SHARDS here)'
            % (jn, v, want))
chk(not shard_problems,
    'the core shard count is PINNED at %d per environment and the pin is parsed, not asserted in a comment (a third shard is a declared capacity raise: it must arrive as a policy decision that edits this line, not as one character in the workflow)' % CORE_SHARDS,
    ' | '.join(shard_problems))
PY
  )
else bad "unit-tests.yml is readable from the harness (DIVE-3315 arms)" "no file at $_wf3315"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
