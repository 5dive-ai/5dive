#!/usr/bin/env bash
# DIVE-1921 mutation runner for tests/digest_window_30d_unit.sh.
#
# WHY THIS IS COMMITTED RATHER THAN DESCRIBED. The PR for DIVE-1921 claimed
# "three negative controls, each reddening exactly one named assertion". That
# claim was true and NOBODY ELSE COULD EXECUTE IT — it lived as prose in a PR
# body, so a verifier could only take my word. dev's finding from DIVE-1932 the
# same night: a claim nobody else can run is the one that propagates furthest.
# So the grade ships as a script.
#
# WHAT IT ASSERTS, and why the signature is a NAME and not a count: all three
# controls produce the IDENTICAL tally "20 passed, 1 failed". Three different
# defects, one number. A tally cannot tell them apart (DIVE-2114: a suite sat at
# 9/2 for four commits while a genuinely broken gate ALSO read 9/2), so each
# control is graded on the assertion NAME it reds AND on the names it does not.
#
# THE PROPERTY THIS INSTRUMENT MUST BE ABLE TO OBSERVE. Asserting "exactly one
# assertion reds" requires a harness that KEEPS GOING after the first failure.
# digest_window_30d_unit.sh collects (set -uo pipefail, no -e; every assertion is
# `&& ok_t || bad_t` into counters), so "20 passed, 1 failed" genuinely means one
# red and twenty held. Arm 0 below PROVES that collection property before any
# single-red claim is graded — a fail-fast harness can only ever show which
# assertion fails FIRST, never that the others still hold, and the claim would be
# unsupported no matter how honestly the tool was run.
#
# Mutations are applied to a COPY of src/ + tests/ in a temp dir. The working
# tree is never written to, so this is safe under CI and safe to run dirty.
# Run: bash tests/digest_window_30d_controls.sh   (no root, no network.)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

TMP="$(mktemp -d /tmp/digest-30d-ctl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; PRECOND=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# A PRECONDITION is not a guard. It establishes that the instrument can OBSERVE
# the property the graded arms claim; it catches nothing about the code under
# test. Counted separately so a reader can never total them into "N guards" —
# the arms below are worth exactly as much as this precondition is true.
ok_p()  { PRECOND=$((PRECOND+1)); printf 'ok   - [PRECONDITION, not a guard] %s\n' "$1"; }

HARNESS="tests/digest_window_30d_unit.sh"

# Fresh pristine copy per mutation: no control can inherit another's defect.
# (The first time these were run by hand they DID stack, because a restore path
# silently failed — which is how a negative control becomes a shipped regression.)
fresh() {
  rm -rf "$TMP/w"; mkdir -p "$TMP/w"
  cp -r "$REPO/src" "$REPO/tests" "$TMP/w/" 2>/dev/null
  [[ -f "$TMP/w/$HARNESS" && -f "$TMP/w/src/cmd_digest.sh" ]] \
    || { echo "FAIL - could not stage a pristine copy"; exit 1; }
}

# Run the harness in the staged copy; echo its FAIL lines (assertion names only).
run_reds() { ( cd "$TMP/w" && bash "$HARNESS" 2>&1 | sed -n 's/^FAIL - //p' ); }
run_tally() { ( cd "$TMP/w" && bash "$HARNESS" 2>&1 | sed -n 's/^\([0-9]* passed, [0-9]* failed\)$/\1/p' ); }

mutate() {  # <file> <python-repr-of-old> <python-repr-of-new>
  MUT_F="$TMP/w/$1" MUT_O="$2" MUT_N="$3" python3 -c '
import os,sys
p=os.environ["MUT_F"]; o=os.environ["MUT_O"]; n=os.environ["MUT_N"]
s=open(p).read()
if o not in s: sys.exit(9)
open(p,"w").write(s.replace(o,n,1))'
}

# --- Arm 0: the PRECONDITION. Prove the harness COLLECTS before grading any
# "exactly one red" claim. Two independent defects at once must yield TWO names.
#
# WHAT THIS ARM CANNOT SEE, stated because a blind spot left in someone's head
# is not recorded anywhere. Arm 0 counts reds; it does not know how many
# assertions RAN. A harness truncated so that both defect assertions survive
# still reports two reds and arm 0 passes, on a matrix silently missing
# assertions. MEASURED, not reasoned: deleting one late assertion leaves arm 0
# green (+1 precondition) while armB refuses on the pinned count. armB is what
# covers this, which is why arm 0 alone is never sufficient to start grading.
# (dev hit the same blindness in their DIVE-1932 grader from the other side:
# theirs asserts two specific NAMES, so it fails the name check on a short
# harness and the count never matters — the same hole, differently shaped.)
fresh
mutate src/cmd_digest.sh '      --30d)   window=2592000 ;;
' '' || { echo "FAIL - arm0 mutation A did not apply"; exit 1; }
mutate src/cmd_digest.sh 'window_label = _WINDOW_LABELS.get(window) or f"{max(1, round(window / 86400))} days"' \
                         'window_label = "7 days" if window >= 604800 else "24h"' \
  || { echo "FAIL - arm0 mutation B did not apply"; exit 1; }
reds="$(run_reds)"; n_reds="$(grep -c . <<<"$reds")"
[[ "$n_reds" -ge 2 ]] \
  && ok_p "arm0: the harness COLLECTS — two independent defects yield $n_reds named reds, not one (blind to truncation; armB covers that)" \
  || {
    bad_t "harness is fail-fast" "two defects produced $n_reds red(s): $reds — a single-red claim is unsupportable on this instrument"
    # REFUSE to grade the rest. On a fail-fast harness every arm below asserts a
    # property the instrument cannot observe, so they would pass or fail for
    # reasons unrelated to the code — and three green arms under a failed
    # precondition is a worse artifact than a bare refusal. Bail with the reason.
    printf '\nREFUSING to grade C1-C3: the precondition failed, so "reds exactly one assertion"\nis not observable on this instrument. Fix the harness, not these arms.\n'
    printf '\n%s assertions passed, %s failed  (+%s precondition)\n' "$PASS" "$FAIL" "$PRECOND"
    exit 1
  }

# --- Arm B: the positive control, and the source of the BASELINE count. Runs
# BEFORE the graded arms because they are measured against it: without a known
# whole-matrix size there is nothing to compare a mutation's total to. Also
# catches a silently-broken staging, which would otherwise read as a pass.
fresh
reds="$(run_reds)"; tally="$(run_tally)"
BASELINE_N="$(awk '{print $1 + $3}' <<<"$tally" 2>/dev/null)"
# PINNED, and cross-checked against the derived count. Deriving the baseline
# alone is not enough: a UNIFORMLY truncated harness truncates the baseline too,
# so derived == mutated and every arm passes on a matrix that is short at both
# ends. The pin is what makes truncation visible. Update it deliberately when
# assertions are added to digest_window_30d_unit.sh — a stale pin also reds.
BASELINE_EXPECTED=21
if [[ -n "$reds" ]]; then
  bad_t "pristine copy is not green" "$(tr '\n' '|' <<<"$reds")"
  BASELINE_N=""
elif [[ "$BASELINE_N" != "$BASELINE_EXPECTED" ]]; then
  bad_t "baseline is not the pinned size" "pristine run evaluated ${BASELINE_N:-no} assertions, pinned at $BASELINE_EXPECTED (tally: $tally) — either the harness is truncated or the pin is stale; BOTH invalidate every arm below"
  BASELINE_N=""
else
  ok_t "armB: the pristine copy reds NOTHING and evaluates $BASELINE_N assertions, matching the pinned baseline"
fi
if [[ -z "$BASELINE_N" ]]; then
  printf '\nREFUSING to grade C1-C3: no valid baseline, so "N of N assertions evaluated"\nis not checkable. Fix the harness or the pin, not these arms.\n'
  printf '\n%s assertions passed, %s failed  (+%s precondition)\n' "$PASS" "$FAIL" "$PRECOND"
  exit 1
fi

# --- Arms 1-3: each defect in isolation reds its OWN assertion and no other.
# expected_only <label> <expected assertion name>
expect_only() {
  local label="$1" want="$2" reds tally n total
  reds="$(run_reds)"; tally="$(run_tally)"; n="$(grep -c . <<<"$reds")"
  # dev's DIVE-1932 finding, applied to THIS grader: reading which assertions
  # red says nothing about whether the harness produced a WHOLE matrix. A
  # mutation that reds the right name and then exits early satisfies the name
  # check while most assertions never ran — the grader would certify a partial
  # run as a clean single-red. So the count is ASSERTED, not printed. Earlier
  # revisions of this file displayed `tally` inside the pass label and checked
  # nothing, which is the same defect one level up.
  total="$(awk '{print $1 + $3}' <<<"$tally" 2>/dev/null)"
  if [[ "$reds" != "$want" ]]; then
    bad_t "$label" "expected exactly \"$want\"; got $n red(s): $(tr '\n' '|' <<<"$reds")"
  elif [[ "$total" != "$BASELINE_N" ]]; then
    bad_t "$label" "correct red name, but the harness evaluated $total of $BASELINE_N assertions ($tally) — a PARTIAL matrix cannot support \"reds exactly one\""
  else
    ok_t "$label -> reds exactly \"$want\", $total of $BASELINE_N assertions evaluated"
  fi
}

fresh
mutate src/cmd_digest.sh '      --30d)   window=2592000 ;;
' '' || { echo "FAIL - C1 mutation did not apply"; exit 1; }
expect_only "C1 delete the --30d arg-parse case arm (SHELL layer)" "--30d not wired in the arg parser"

fresh
mutate src/cmd_digest.sh 'window_label = _WINDOW_LABELS.get(window) or f"{max(1, round(window / 86400))} days"' \
                         'window_label = "7 days" if window >= 604800 else "24h"' \
  || { echo "FAIL - C2 mutation did not apply"; exit 1; }
expect_only "C2 restore the >= label ladder (RENDERER layer)" "30d window mislabelled"

fresh
mutate src/cmd_proof.sh "policy_refusals WHERE ts>=datetime('now',\$(sqlq \"\$sql_window\"))" \
                        "policy_refusals WHERE ts>=datetime('now','-7 days')" \
  || { echo "FAIL - C3 mutation did not apply"; exit 1; }
expect_only "C3 leave ONE scorecard SQL site at 7 days (MIXED-WINDOW)" "a hard-coded span survives in the scorecard"

# --- Arm S: SELF-TEST of this runner's own count branch.
#
# dev's audit of their grader, applied here: expect_only()'s "N of N assertions
# evaluated" branch is reachable and nothing else demonstrates it REDS when it
# should. Arm 0 grades a two-defect run and armB grades the pristine run, so
# neither can fire it — it trips only when an INDIVIDUAL mutation's run comes up
# short. Until this arm existed that control lived in a transcript, which is the
# defect this file exists to fix, one level up: the grader was committed and the
# grader's own control was prose.
#
# Keyed to C3's defect ONLY, deliberately: arm 0 uses the two DIGEST defects and
# armB runs pristine, so both still see whole matrices and pass, isolating the
# count branch as the one thing that can catch this. A control caught by a
# different arm proves nothing about the arm it was written for.
#
# The staged harness is doctored to exit early ONLY when C3's defect is present.
# Anchor and injection travel through the ENVIRONMENT rather than being quoted
# into the python, because nesting bash and python quoting is how the first two
# attempts at this arm silently produced dead code and a syntax error.
_armS_truncate() {
  SELF_ANCHOR="grep -q 'digest --json \"--\\\$window\"' <<<\"\$SCORE_FN\"" \
  SELF_INJ="[[ \"\$HARDCODED\" == \"1\" ]] || { printf '\\n%s passed, %s failed\\n' \"\$PASS\" \"\$FAIL\"; exit 1; }" \
  SELF_F="$TMP/w/tests/digest_window_30d_unit.sh" python3 <<'SELFPY'
import os, sys
p = os.environ["SELF_F"]
s = open(p).read()
a = os.environ["SELF_ANCHOR"]
if a not in s:
    sys.exit(1)
open(p, "w").write(s.replace(a, os.environ["SELF_INJ"] + "\n" + a, 1))
SELFPY
}
fresh
if ! _armS_truncate; then
  bad_t "armS: could not stage the self-test truncation" "the anchor in digest_window_30d_unit.sh moved — this arm no longer tests what it claims, and a silent skip would leave the count branch uncontrolled"
elif ! mutate src/cmd_proof.sh "policy_refusals WHERE ts>=datetime('now',\$(sqlq \"\$sql_window\"))" \
                               "policy_refusals WHERE ts>=datetime('now','-7 days')"; then
  bad_t "armS: the C3 mutation did not apply" "cannot self-test the count branch without it"
else
  # expect_only runs in a SUBSHELL so its bad_t cannot touch the real counters.
  _out="$( expect_only "armS probe" "a hard-coded span survives in the scorecard" 2>&1 )"
  if grep -q "correct red name, but the harness evaluated" <<<"$_out"; then
    ok_t "armS: the count branch REDS on a short matrix even when the red NAME is correct ($(sed -n 's/.*evaluated \([0-9]* of [0-9]*\).*/\1/p' <<<"$_out"))"
  else
    bad_t "armS: the count branch did NOT fire on a deliberately short matrix" "expect_only printed: $(tr '\n' '|' <<<"$_out")"
  fi
fi

printf '\n%s assertions passed, %s failed  (+%s precondition, which grades the INSTRUMENT, not the code)\n' \
  "$PASS" "$FAIL" "$PRECOND"
[[ "$FAIL" -eq 0 ]]
