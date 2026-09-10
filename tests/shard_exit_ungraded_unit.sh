#!/usr/bin/env bash
# DIVE-4229 — an UNGRADED harness shard must not red the job.
#
# run-harnesses.sh has distinguished graded from ungraded since DIVE-2728 (1 = a
# harness failed, 4 = corpus over its cap, 6 = could not grade). CI discarded that
# distinction, because a step ending non-zero reds the job whatever the number
# meant — so release-cut, which refuses on ANY red without reading which red it is,
# refused v0.31.0 on a shard sitting at 65% of budget with zero failing harnesses
# (run 34470906776, full-installed-host (2), calibration probe at 243% of baseline).
#
# THE ARMS THAT MATTER MOST ARE THE NEGATIVE ONES. This translator is a control
# being WEAKENED on purpose, and the whole safety of it is that it weakens exactly
# one code. Arms 2-4 are the graded verdicts that must still red; shard 1 of that
# same run was a genuine 118% budget red and must keep reddening.
# Run: bash tests/shard_exit_ungraded_unit.sh  (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/shard-exit-unit.XXXXXX)"
SE=scripts/shard-exit.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

run_se() { out=$(bash "$SE" "$@" 2>&1); rc=$?; }

# --- Arm 1: the ungraded slot is translated, and it ANNOUNCES itself ---------
# Turning a red green is only safe if the fact survives. The annotation is the
# thing a human sees on the job, the PR and the run summary; silence here would
# read as "measured, fine" on a shard that was never measured.
run_se 6 'full/installed-host-s2'
[[ $rc -eq 0 ]] && ok_t "arm 1: exit 6 -> 0" || bad_t "arm 1: exit 6 must not red the job" "rc=$rc"
grep -q '^::warning title=harness budget UNGRADED' <<<"$out" \
  && ok_t "arm 1b: it emits a GitHub warning annotation" \
  || bad_t "arm 1b: an ungraded shard must announce itself" "got: $out"
grep -q 'full/installed-host-s2' <<<"$out" \
  && ok_t "arm 1c: the annotation names the shard" \
  || bad_t "arm 1c: the annotation must name the shard" "got: $out"
grep -q 'not a red' <<<"$out" \
  && ok_t "arm 1d: and says outright that it is not a red" \
  || bad_t "arm 1d: the annotation must say it is not a red" "got: $out"

# --- Arms 2-4: EVERY graded verdict still reds ------------------------------
# The one-code boundary, stated three times because each of these is a different
# claim about the tree and each was reachable on the same run.
for pair in "1:a harness FAILED" "4:the corpus is OVER ITS CAP" "5:the opt-in drift gate"; do
  code="${pair%%:*}"; what="${pair#*:}"
  run_se "$code" 'core/pristine-s1'
  [[ $rc -eq $code ]] && ok_t "arm 2-4: exit $code ($what) passes through unchanged" \
                      || bad_t "arm 2-4: exit $code must still red" "rc=$rc"
  grep -q '::warning' <<<"$out" \
    && bad_t "arm 2-4: exit $code was annotated as ungraded" "got: $out" \
    || ok_t "arm 2-4: exit $code is NOT annotated as ungraded"
done

# --- Arm 5: a green run stays green and stays silent ------------------------
run_se 0 'core/pristine-s1'
{ [[ $rc -eq 0 ]] && [[ -z "$out" ]]; } && ok_t "arm 5: exit 0 -> 0, no output" \
                                        || bad_t "arm 5: a green shard must pass silently" "rc=$rc out=$out"

# --- Arm 6: the REASON is read from the report, by its real field names ------
# A field name that matches nothing degrades to the generic reason SILENTLY, so
# each of the three is driven here, and arm 7 pins the names against the writer.
mk_report() { printf '%s\n' "$@" > "$TMP/r.txt"; }
mk_report '# undetermined=1' '# cross_runner_state=off' '# budget_attribution=off'
run_se 6 'core/pristine-s1' "$TMP/r.txt"
grep -q 'calibration probe drew past its clamp' <<<"$out" \
  && ok_t "arm 6a: undetermined=1 -> the calibration-clamp reason" \
  || bad_t "arm 6a: the calibration reason must be named" "got: $out"
mk_report '# undetermined=0' '# cross_runner_state=single' '# budget_attribution=off'
run_se 6 'core/pristine-s1' "$TMP/r.txt"
grep -q 'not yet confirmed by a second runner' <<<"$out" \
  && ok_t "arm 6b: cross_runner_state=single -> the unconfirmed reason" \
  || bad_t "arm 6b: the cross-runner reason must be named" "got: $out"
mk_report '# undetermined=0' '# cross_runner_state=off' '# budget_attribution=runner'
run_se 6 'core/pristine-s1' "$TMP/r.txt"
grep -q 'attributes the overrun to the RUNNER' <<<"$out" \
  && ok_t "arm 6c: budget_attribution=runner -> the attribution reason" \
  || bad_t "arm 6c: the attribution reason must be named" "got: $out"
# An unreadable report degrades to the generic reason and STILL returns 0 — the
# exit code already said the shard was ungraded and no missing file un-says it.
run_se 6 'core/pristine-s1' "$TMP/does-not-exist.txt"
{ [[ $rc -eq 0 ]] && grep -q 'ungraded (run-harnesses.sh exit 6)' <<<"$out"; } \
  && ok_t "arm 6d: an unreadable report degrades to the generic reason, still not a red" \
  || bad_t "arm 6d: a missing report must not change the verdict" "rc=$rc out=$out"

# --- Arm 7: the field names are the WRITER'S ---------------------------------
# The drift guard. shard-exit.sh greps three fields out of a file run-harnesses.sh
# writes; if either side renames one, the reason silently becomes generic and
# nobody learns why the shard was ungraded. Derived from the writer's own printf,
# never from a copy of the list.
for f in undetermined cross_runner_state budget_attribution; do
  if grep -q "# ${f}=" scripts/run-harnesses.sh && grep -q "# ${f}=" "$SE"; then
    ok_t "arm 7: report field '${f}' is written by run-harnesses.sh and read by shard-exit.sh"
  else
    bad_t "arm 7: report field '${f}' drifted between writer and reader" \
      "writer=$(grep -c "# ${f}=" scripts/run-harnesses.sh) reader=$(grep -c "# ${f}=" "$SE")"
  fi
done

# --- Arm 8: a non-numeric rc REFUSES rather than being swallowed -------------
run_se '' 'core/pristine-s1'
[[ $rc -eq 2 ]] && ok_t "arm 8: an empty rc refuses (exit 2), it is not read as green" \
               || bad_t "arm 8: a non-numeric rc must refuse" "rc=$rc"

# --- Arm 9: EVERY workflow shard routes through the translator ---------------
# The fix is worth nothing on a call site that did not get it, and a new shard is
# added by copying an existing block. Counted per FILE so a partial wiring reds.
for wf in .github/workflows/unit-tests.yml .github/workflows/full-sweep.yml; do
  runs=$(grep -c 'bash scripts/run-harnesses.sh' "$wf")
  wired=$(grep -c 'bash scripts/shard-exit.sh' "$wf")
  [[ "$runs" -eq "$wired" ]] \
    && ok_t "arm 9: $(basename "$wf") — all $runs run-harnesses call(s) route through shard-exit.sh" \
    || bad_t "arm 9: $(basename "$wf") has $runs run-harnesses call(s) but $wired shard-exit call(s)" \
             "a shard that skips the translator still reds on an ungraded run"
done

# --- Arm 10: the translator is executable and shellcheck-clean at error level -
[[ -x "$SE" ]] && ok_t "arm 10: shard-exit.sh is executable" \
               || bad_t "arm 10: shard-exit.sh must be executable" "not +x"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
