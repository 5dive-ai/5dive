#!/usr/bin/env bash
# DIVE-2013: a harness whose EXIT STATUS is not wired to its own assertions can
# never fail CI, no matter how loudly it prints FAIL. That is not hypothetical:
# heartbeat_gate_shipped_unit.sh shipped that way for three consecutive releases
# (0.15.26/27/28) printing "14 passed, 2 failed" and exiting 0, because a tally
# `printf` had been moved after the verdict line. CI runs `for t in tests/*.sh`
# and `5dive task verify --cmd` grades on exit 0 — both were blind.
#
# Static analysis CANNOT close this (olivia measured three instruments, all
# agreeing, none sound): none can see a harness whose assertions never fire, a
# verdict placed before the last assertion, or a `set -e` verdict bypassed. So
# this is EMPIRICAL — it induces a failure and demands the harness report it.
#
# For each tests/*.sh:
#   1. establish it is green clean (or take that from a prior suite run with
#      --assume-clean, which is what CI does since the `test` job just proved it)
#   2. identify the verdict variable from the final verdict expression
#   3. inject `<VAR>=$((<VAR>+1))` immediately BEFORE the verdict line
#   4. require exit != 0
#
# A harness whose verdict variable cannot be identified is reported UNPROBEABLE
# and FAILS the check. A silent skip here would be the exact defect class the
# check exists to find — that is the whole lesson of DIVE-2003.
#
# Lives in tests/meta/ deliberately: `tests/*.sh` does not glob subdirectories,
# so the suite never runs this, and this never recurses into itself.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
ASSUME_CLEAN=0; ONLY=""; REPORT=""; LABEL=""; SHARD=""; TIMEOUT=${PROBE_TIMEOUT:-180}
for a in "$@"; do case "$a" in
  --assume-clean) ASSUME_CLEAN=1 ;;
  --only=*) ONLY="${a#--only=}" ;;      # one basename, or a comma-separated list
  # DIVE-3488: i/N, 1-based, same stride and same spelling as run-harnesses.sh's
  # --shard. The corpus this probe re-runs is ALREADY sharded three ways by
  # full-sweep.yml's `full-pristine` / `full-installed-host` matrices; this one job
  # then re-ran all of it single-file, so the probe pass measured 1475s against
  # shards of 459-723s and WAS the sweep's second half.
  #
  # Sharding here is sound for a reason that does not hold for most instruments:
  # the coverage claim was NEVER this job's to make. harness-verdict-union.sh owns
  # it, over the UNION of every report, and it fails closed on a missing one. A
  # shard reports what it observed; the union still asserts every harness in
  # tests/*.sh was probed SOMEWHERE. `# corpus=` below stays the whole tree's count
  # in every shard, so a shard cannot shrink the corpus the union checks against.
  --shard=*) SHARD="${a#--shard=}" ;;   # i/N, 1-based
  # DIVE-2018: a machine-readable verdict per harness, so the UNION of several
  # environments can be asserted to cover the corpus. NOT-REACHED is correctly not
  # a failure in any single run (a skip is not an accusation), which is precisely
  # why no single run can establish coverage — see harness-verdict-union.sh.
  --report=*) REPORT="${a#--report=}" ;;
  --label=*)  LABEL="${a#--label=}" ;;  # names the environment in union failures
  *) printf 'unknown arg: %s\n' "$a" >&2; exit 2 ;;
esac; done

# DIVE-3149: THE CANARY NEEDS A CHANNEL THE HARNESS CANNOT TAKE AWAY.
# The canary below used to ride the mutant's STDERR, read back out of the same
# capture this loop uses for everything else. That made it only as reliable as the
# harness's own stderr: any harness that redirects or closes fd 2 before its verdict
# line — deliberately, or by accident as in DIVE-3148 — silences the canary, and the
# probe then reports not-reached, "harness exits early in this environment". The
# harness did not exit early; the probe could not hear it. That misread is SILENT per
# environment (not-reached is tolerated in any single run) and only surfaces when it
# happens EVERYWHERE at once — as NEVER PROBED, which reds harness-verdict-union and
# refuses the release cut. Loudest possible symptom, quietest possible cause, and a
# message that sends the reader hunting a skip guard that does not exist.
#
# Note the shape, because it is the one this whole file exists to find: the canary was
# introduced to stop a mutation that never EXECUTED from being reported UNWIRED — a
# false accusation. A canary that cannot be heard makes a different false statement
# about the same unknown, so the mechanism inherited the failure mode it was built to
# remove. So the canary now writes a FILE at a path the probe names and exports; a
# harness would have to unset the probe's own variable to defeat it.
#
# TWO channels, not one, and reached = EITHER. The file is the one that survives a
# stderr redirection; stderr is kept as the one that survives an unwritable canary dir.
# Neither is free to fail silently on its own, which is the property the single-channel
# version did not have.
_PROBE_CANARY_DIR=$(mktemp -d 2>/dev/null) || _PROBE_CANARY_DIR=""
export _PROBE_CANARY_FILE="${_PROBE_CANARY_DIR}/reached"
# …and PROVE the channel works before trusting a negative from it. An unwritable dir
# would make every harness read not-reached — exactly the failure being fixed, re-entered
# through a different door — so it is a loud exit here, never a quiet verdict there.
if [[ -z "$_PROBE_CANARY_DIR" ]] || ! printf 1 > "$_PROBE_CANARY_FILE" 2>/dev/null || [[ ! -s "$_PROBE_CANARY_FILE" ]]; then
  printf 'probe: cannot write the canary file (%s) — refusing to run, because every harness would read not-reached\n' \
    "${_PROBE_CANARY_FILE:-unset}" >&2
  exit 2
fi
rm -f "$_PROBE_CANARY_FILE"
trap 'rm -rf "$_PROBE_CANARY_DIR"' EXIT

# Allowlisted UNPROBEABLE, BY NAME with a reason — the cmd_init.sh heredoc pattern:
# still detected and still reported, just permitted. A NEW unprobeable harness is
# not covered by this and reds the check, which is the property olivia asked for
# (a silent skip here is the defect the check exists to find).
#
#   council_amend_e2e.sh          hand-verified by olivia: exits 1 at `if (( fail ))`
#                                 and only reaches its hardcoded "0 failed" echo when
#                                 fail==0.
#   schema_sync_unit.sh           hand-verified by olivia: ends in `EOF` closing a
#                                 python heredoc whose own `sys.exit(1 if fail else 0)`
#                                 propagates.
#   council_roster_lineage_e2e.sh READ, NOT EMPIRICALLY PROVEN: `set -uo pipefail` with
#                                 per-assertion `|| { echo "FAIL: …"; exit 1; }`, so it
#                                 is wired by explicit exit — but it has no verdict
#                                 variable and no `set -e`, so neither mutation applies
#                                 and this probe cannot demonstrate it. Weaker evidence
#                                 than the other two; say so rather than imply parity.
ALLOW_UNPROBEABLE="council_amend_e2e.sh council_roster_lineage_e2e.sh schema_sync_unit.sh"

WIRED=(); UNWIRED=(); UNPROBEABLE=(); ALREADY_RED=(); ALLOWED=(); NOT_REACHED=()
# DIVE-2555: killed by the time cap. Its own class, because it is neither of the two
# it used to be folded into: not a failed assertion (already-red) and not an early
# skip (not-reached), and above all not a verdict (a non-zero exit produced by the
# KILL is not evidence that the harness's exit status is wired to anything).
TIMED_OUT=()

# DIVE-3679: `counter_verdict` moved to tests/lib/harness-verdict-detect.sh, verbatim
# and with every comment, so this probe and the STATIC guard
# (tests/meta/harness-verdict-toplevel.sh) name the same line as the verdict. The
# static guard's entire claim is about the line THIS file would mutate, so two
# copies of the detector would be two detectors the first time one was edited.
# shellcheck source=tests/lib/harness-verdict-detect.sh
source tests/lib/harness-verdict-detect.sh

CORPUS_N=0; for t in tests/*.sh; do [[ -e "$t" ]] && CORPUS_N=$(( CORPUS_N + 1 )); done
only_set=" ${ONLY//,/ } "

# DIVE-3488: SELECT FIRST, then loop — the stride has to be taken over the list this
# run would actually probe, so --only and --shard compose instead of one silently
# eating the other.
SELECTED=()
for t in tests/*.sh; do
  [[ -e "$t" ]] || continue
  b=$(basename "$t")
  # --only takes a LIST so a second environment can re-probe exactly the harnesses
  # the first one skipped, instead of paying for the whole corpus twice.
  [[ -n "$ONLY" && "$only_set" != *" $b "* ]] && continue
  SELECTED+=("$t")
done

if [[ -n "$SHARD" ]]; then
  if [[ ! "$SHARD" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    printf 'probe: --shard must be i/N (1-based), got %s\n' "$SHARD" >&2; exit 2
  fi
  si="${BASH_REMATCH[1]}"; sn="${BASH_REMATCH[2]}"
  if (( si < 1 || sn < 1 || si > sn )); then
    printf 'probe: --shard=%s is out of range\n' "$SHARD" >&2; exit 2
  fi
  picked=()
  for i in "${!SELECTED[@]}"; do (( i % sn == si - 1 )) && picked+=("${SELECTED[$i]}"); done
  SELECTED=("${picked[@]}")
  # The label carries the shard, because the union keys its per-environment detail
  # on the label: three reports all called `pristine` would overwrite each other in
  # the NEVER PROBED explanation and print one shard's verdict as the environment's.
  # Coverage would still be right; the sentence a human reads would not.
  [[ -n "$LABEL" ]] && LABEL="$LABEL-s$si"
  # A shard that selected nothing reports green having probed none of the corpus it
  # names — the same UNDETERMINED state run-harnesses.sh refuses, for the same reason.
  if (( ${#SELECTED[@]} == 0 )); then
    printf 'probe: FAIL — shard %s selected 0 harnesses; an empty shard is not a probed one\n' "$SHARD" >&2
    exit 1
  fi
fi
# DIVE-2039: every line of this script's output was buffered into arrays and printed
# at the END, so a full sweep wrote ZERO BYTES for tens of minutes — indistinguishable
# from a hang, both to a person and to CI, which has to guess whether to keep waiting.
# `5dive selfcheck --full` inherited that silence and was reported as a hang before
# anyone could show it was merely slow. Progress goes to STDERR only: stdout carries
# the summary and the report file carries the verdicts, and both formats are read by
# harness-verdict-union.sh, so neither may gain a line.
PROBED_N=0
for t in "${SELECTED[@]:-}"; do
  [[ -n "$t" ]] || continue
  b=$(basename "$t")
  PROBED_N=$(( PROBED_N + 1 ))
  printf '  probing %d/%d %s\n' "$PROBED_N" "$CORPUS_N" "$b" >&2
  if (( ! ASSUME_CLEAN )); then
    timeout "$TIMEOUT" bash "$t" >/dev/null 2>&1; rc=$?
    # DIVE-2555: A KILL IS NOT A FAILURE. `timeout` exits 124 when it has to signal
    # the child (137 when the child needed SIGKILL), and folding either into
    # already-red publishes "failed its own clean run" — a statement about the
    # harness's ASSERTIONS, made on evidence that is entirely about the CLOCK. The
    # remedy the label implies (find the broken assertion) does not exist, and the
    # one that does (the long lane, or a slower harness to merge or retire) is not
    # named anywhere. Same shape as the exit-code split this corpus already carries:
    # over-budget is exit 4 and a red test is exit 1, because a red that could mean
    # either gets triaged as neither.
    if (( rc == 124 || rc == 137 )); then
      TIMED_OUT+=("$b (clean run killed at ${TIMEOUT}s — over the probe's time cap, NOT a failed assertion)")
      continue
    fi
    if (( rc != 0 )); then ALREADY_RED+=("$b"); continue; fi
  fi
  if spec=$(counter_verdict "$t"); then
    IFS=$'\t' read -r var ln pos <<<"$spec"
    strategy="counter '$var' at line $ln ($pos executable line)"
    inject="${var}=\$((${var}+1))"
  elif grep -qE '^set -[a-z]*e' "$t"; then
    ln=$(grep -nvE '^[[:space:]]*(#|$)' "$t" | tail -1 | cut -d: -f1)
    strategy="injected 'false' before line $ln under set -e"
    inject="false"
  else
if [[ " $ALLOW_UNPROBEABLE " == *" $b "* ]]; then ALLOWED+=("$b"); else UNPROBEABLE+=("$b"); fi; continue
  fi
  # The mutant lives in tests/ as a DOTFILE: `tests/*.sh` will not glob it, and
  # keeping it in the same directory preserves every harness's
  # `cd "$(dirname "$0")/.."` and its relative fixture paths.
  mutant="tests/.probe-${b}"
  # CANARY: a mutation that never EXECUTED proves nothing, and calling that
  # "unwired" is a false accusation. Harnesses that skip early in one environment
  # (no 5dive installed, not root) exit 0 long before the verdict — which is
  # exactly how three correctly-wired files were reported UNWIRED on the CI runner
  # while passing on this box. So the injected line announces itself, and a run
  # that never reached it is NOT-REACHED, never UNWIRED.
  # (community/wiki/test-harness-credential-reach-and-transcript-durability.md:
  #  a canary proves the extractor RAN; the fixture proves it is still RIGHT.)
  # DIVE-2018: the canary must print BEFORE the injected mutation, not after.
  # Its job is to answer "did execution reach the injection point", and placing it
  # after a statement whose whole purpose is to be FATAL guarantees it cannot: for
  # the ABORT family the injected `false` under `set -e` terminates the shell on
  # the spot, so the canary never ran, so EVERY abort-family harness reported
  # not-reached — in every environment, forever. That is olivia's limit case made
  # real, and it was 18 harnesses: reported "probed in an environment where it
  # runs" while no environment ever could. Before it, `set -e` harnesses were
  # structurally unprobeable and the check was green about it.
  # DIVE-3149 FOLLOW-UP: TWO CHANNELS IN SERIES ARE NOT REDUNDANT. The first cut of
  # this shipped `printf 1 > "$_PROBE_CANARY_FILE"` FIRST and the stderr canary second,
  # and regressed six harnesses (the constitution/council family) into not-reached,
  # refusing the cut a second time. constitution_set_e2e.sh:41 re-execs itself through
  # `exec sudo -n env PATH="$PATH" bash "$0"`; sudo's env_reset scrubs the environment,
  # so _PROBE_CANARY_FILE arrived UNSET, and under that harness's `set -u` the injected
  # line was a FATAL unbound variable that killed the shell ON THAT LINE — so the stderr
  # canary, sitting one line below, never ran either. The family never had to touch
  # stderr; the redundant channel was suppressed by its own partner.
  #
  # Three properties now, and each is load-bearing on its own:
  #   1. THE PATH IS A BAKED-IN LITERAL, not an env reference. Nothing has to survive a
  #      sudo hop, an `env -i`, an `unset`, or a re-exec — the value is fixed when the
  #      mutant is WRITTEN, not read when it runs. This is what actually closes the class.
  #   2. STDERR GOES FIRST, because it needs no environment and no filesystem.
  #   3. NEITHER LINE MAY BE FATAL (`|| :`). A canary that can abort the harness is a
  #      canary that can manufacture the very not-reached it exists to disprove, and
  #      under `set -e` or `set -u` an unguarded one does exactly that.
  # Both still precede the injected mutation, preserving DIVE-2018.
  awk -v n="$ln" -v inj="$inject" -v cf="$_PROBE_CANARY_FILE" \
    'NR==n{print "printf \x27__PROBE_REACHED__\\n\x27 >&2 || :"; print "printf 1 > \"" cf "\" 2>/dev/null || :"; print inj} {print}' "$t" > "$mutant"
  # Removed BETWEEN harnesses, so a stale file can never certify the next one.
  rm -f "$_PROBE_CANARY_FILE"
  # The stderr capture is unchanged and still discards the mutant's stdout: it keeps
  # the mutant's noise off the probe's own progress stream. It is now the SECOND
  # canary channel rather than the only one.
  out=$(timeout "$TIMEOUT" bash "$mutant" 2>&1 >/dev/null); rc=$?
  rm -f "$mutant"
  # DIVE-2555: THE KILL MUST BE CLASSIFIED BEFORE THE VERDICT IS READ, because a
  # killed mutant produces BOTH of this loop's outcomes for reasons that have
  # nothing to do with wiring:
  #   * killed after the canary printed -> rc 124, non-zero, counted WIRED. That is
  #     a FALSE PASS in the coverage direction, and the worst one available here: an
  #     unwired harness earns a `wired` row, the union counts it as probed, and the
  #     one check that exists to find harnesses that cannot fail CI says it can.
  #   * killed before the canary printed -> not-reached, whose message says the
  #     harness "exits early in this environment". It did not exit; it was killed.
  #     A true classification with a false explanation sends the reader to look for
  #     a skip guard that is not there (DIVE-2412 spent exactly that trip before
  #     landing the 900s lane).
  # Neither is a failure and neither is coverage: `timed-out` is reported, carried
  # into the report, and NOT in the union's probed set — so a harness timed out in
  # EVERY environment reds the union as NEVER PROBED, which is true and is the
  # signal that its lane needs the time.
  if (( rc == 124 || rc == 137 )); then
    TIMED_OUT+=("$b (mutant killed at ${TIMEOUT}s — no verdict was observed; raise PROBE_TIMEOUT for it or make it faster)")
    continue
  fi
  if [[ ! -s "$_PROBE_CANARY_FILE" ]] && ! grep -q '__PROBE_REACHED__' <<<"$out"; then
    NOT_REACHED+=("$b (verdict line $ln never executed — harness exits early in this environment)")
    continue
  fi
  if (( rc == 0 )); then
    UNWIRED+=("$b — $strategy")
  else WIRED+=("$b"); fi
done

printf 'harness-verdict-probe: %d wired, %d UNWIRED, %d UNPROBEABLE, %d allowlisted, %d not-reached, %d already-red, %d timed-out (cap %ss)\n' \
  "${#WIRED[@]}" "${#UNWIRED[@]}" "${#UNPROBEABLE[@]}" "${#ALLOWED[@]}" "${#NOT_REACHED[@]}" "${#ALREADY_RED[@]}" "${#TIMED_OUT[@]}" "$TIMEOUT"
for x in "${UNWIRED[@]:-}";     do [[ -n "$x" ]] && printf 'UNWIRED      %s — exit status is NOT wired to its assertions; it cannot fail CI\n' "$x"; done
for x in "${UNPROBEABLE[@]:-}"; do [[ -n "$x" ]] && printf 'UNPROBEABLE  %s — no identifiable verdict variable; NOT counted clean\n' "$x"; done
for x in "${NOT_REACHED[@]:-}";  do [[ -n "$x" ]] && printf 'not-reached  %s — skipped before the verdict here; probed in an environment where it runs\n' "$x"; done
for x in "${ALLOWED[@]:-}";     do [[ -n "$x" ]] && printf 'allowlisted  %s — unprobeable, permitted by name with a recorded reason\n' "$x"; done
for x in "${ALREADY_RED[@]:-}"; do [[ -n "$x" ]] && printf 'ALREADY-RED  %s — failed its own clean run; reported, not probed\n' "$x"; done
for x in "${TIMED_OUT[@]:-}";   do [[ -n "$x" ]] && printf 'timed-out    %s — the CLOCK ran out, not an assertion; not counted as probed, so the union will say so if every environment times it out\n' "$x"; done

# DIVE-2018: the machine-readable half. `not-reached` is still not a failure HERE
# — a skip is not an accusation — so this run cannot establish coverage on its own.
# It records what it actually observed and lets harness-verdict-union.sh assert the
# invariant that does hold: every harness is probed in SOME environment.
# The corpus size and the allowlist travel WITH the verdicts, because the defect
# this closes is two green runs describing different corpora with nothing saying so.
if [[ -n "$REPORT" ]]; then
  {
    printf '# harness-verdict-probe report — one line per harness observed by THIS run\n'
    printf '# corpus=%d\n' "$CORPUS_N"
    printf '# allowlist=%s\n' "${ALLOW_UNPROBEABLE// /,}"
    printf '# label=%s\n' "${LABEL:-$(uname -n)}"
    # Basename is field 1 in every array: the annotated entries are "<name> — …"
    # and "<name> (…)", the rest are bare names.
    for x in "${WIRED[@]:-}";       do [[ -n "$x" ]] && printf 'wired\t%s\n'        "${x%% *}"; done
    for x in "${UNWIRED[@]:-}";     do [[ -n "$x" ]] && printf 'UNWIRED\t%s\n'      "${x%% *}"; done
    for x in "${UNPROBEABLE[@]:-}"; do [[ -n "$x" ]] && printf 'UNPROBEABLE\t%s\n'  "${x%% *}"; done
    for x in "${ALLOWED[@]:-}";     do [[ -n "$x" ]] && printf 'allowlisted\t%s\n'  "${x%% *}"; done
    for x in "${NOT_REACHED[@]:-}"; do [[ -n "$x" ]] && printf 'not-reached\t%s\n'  "${x%% *}"; done
    for x in "${ALREADY_RED[@]:-}"; do [[ -n "$x" ]] && printf 'already-red\t%s\n'  "${x%% *}"; done
    for x in "${TIMED_OUT[@]:-}";   do [[ -n "$x" ]] && printf 'timed-out\t%s\n'    "${x%% *}"; done
    # Terminating `:` is load-bearing. A brace group's status is its LAST command's,
    # and every loop above ends on `[[ -n "$x" ]] && printf` — which is FALSE, not an
    # error, whenever that category is empty. Without this the guard below fired on a
    # perfectly good report and exited 1: a false failure whose only cause was reading
    # the wrong exit status, which is the same defect this whole check exists to find,
    # committed inside the fix for it. With `:`, a failed redirect (bash aborts the
    # group before running anything) is the only thing that can make this non-zero.
    :
  } > "$REPORT" || { printf 'probe: FAILED to write report %s\n' "$REPORT" >&2; exit 1; }
  # …and corroborate the EFFECT rather than trust that status: a mid-write failure
  # (full disk) leaves a truncated file that the redirect status cannot see. The row
  # count must match what we classified, or the report is not usable as evidence.
  rows=$(grep -cv '^#' "$REPORT")
  want=$(( ${#WIRED[@]} + ${#UNWIRED[@]} + ${#UNPROBEABLE[@]} + ${#ALLOWED[@]} + ${#NOT_REACHED[@]} + ${#ALREADY_RED[@]} + ${#TIMED_OUT[@]} ))
  if (( rows != want )); then
    printf 'probe: report %s has %d rows, classified %d — refusing to emit a partial report\n' "$REPORT" "$rows" "$want" >&2
    exit 1
  fi
  printf 'report written: %s (%d harness rows)\n' "$REPORT" "$rows"
fi
(( ${#UNWIRED[@]} == 0 && ${#UNPROBEABLE[@]} == 0 ))
