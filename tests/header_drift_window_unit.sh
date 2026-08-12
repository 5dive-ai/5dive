#!/usr/bin/env bash
# DIVE-3188 — THE CROSS-JOB STALE-CLAIM RAIL, GRADED END TO END.
#
# TIER: nightly — 5.0s measured (5dive host, agent-dev seat, 2026-08-10): four of those
# five seconds are one `sleep 4`, and core has no room for them.
#
# THE DEMOTION IS ARGUED FROM A CI NUMBER, not a local one, because a local reading on
# the contended control plane runs ~45% high and a demotion argued on an unverified
# figure is the second budget the tier system exists to prevent. Read off unit-tests.yml
# run 31437553333 on main, 2026-08-10:
#     core/pristine        279 harnesses, 306s wall-clock, budget 300s (102%)
#     core/installed-host  279 harnesses, 385s (128%), confirm re-time 251s (83%)
# Core is AT its cap on that sample. CLAUDE.md ranks merge and retire ahead of demotion
# and neither applies — this harness has no sibling to fold into and the mechanism it
# guards is brand new — but adding 5s of recurring cost to a tier already at 102% would
# red somebody else's PR on content they did not change, which is the exact harm the
# budget exists to price.
#
# THE COST CANNOT BE ENGINEERED AWAY, which is what makes this a tier question rather
# than an optimisation. WRONG is `>=50% AND >=3s` over the claim, so a fixture that
# provokes one must actually burn three wall-clock seconds; there is no faster way to
# make a real drift verdict happen. That same fact makes this figure unusually STABLE
# across runners — a sleep costs the same on a slow box, so almost none of the 5s is
# platform draw, and this header should not itself go stale.
#
# THE LATENCY IS ACCEPTABLE HERE FOR A REASON SPECIFIC TO WHAT THIS GUARDS: the rail it
# grades (header-drift-window.yml) is ITSELF nightly, so a 24h detection window on the
# guard matches the cadence of the thing guarded. And `changed-harnesses` runs a touched
# harness at introduction whatever its tier, so anyone editing this chain still pays for
# it on their own PR — the tier only sets the RECURRING cost. Decision: dev, 2026-08-10.
#
# WHAT THIS EXISTS TO CATCH. DIVE-3163 removed a per-job `exit 5` because one box
# cannot separate a stale header from a slow runner, and left the count in the report
# with the reader it needed unwritten. DIVE-3188 writes that reader as a chain of
# three files, and a chain is exactly the shape where every link can be individually
# green while the thing itself does nothing: the runner can print a line no harvester
# matches, the harvester can emit a field no window reads, and the window can score a
# verdict off samples that never carried the field. So the arms below follow ONE fact
# from the runner's stdout, through a harvested report, to a verdict — and the
# negative arms are the load-bearing half.
#
# THE ARMS:
#   1-4   CARRIER. The runner prints a parseable summary line on EVERY run including a
#         clean one (so `wrong 0` is a GRADED zero), plus one row per drifting file
#         carrying its severity and name. Shaped `harness-budget[...]` because that is
#         the harvester's contract; an arm on the shape, since a prettier line that
#         does not match is the silent break.
#   5-9   HARVEST. The lines parse back into report fields and per-file rows — and a
#         PRE-DIVE-3188 log yields NO header_drift_wrong at all, never a zero. That
#         negative arm is the one that protects the statistic: the window counts
#         recurrences across history, so a missing-means-zero default would
#         manufacture a majority of clean historical samples inside the instrument
#         built to count them.
#  10-16  VERDICT. WRONG on one job is a stopwatch disagreement; on two DISTINCT jobs
#         it is a STALE CLAIM. Two reports from the SAME job count once (a re-run must
#         not convict a file on its own second opinion). `stale` never counts (it is
#         the WARN band, below the margin the removed exit 5 used). Samples with no job
#         identity leave the denominator by name. Under three graded jobs the verdict
#         is UNDETERMINED, not clean. `--drift-strict` exits 8; the default does not.
#  17-18  ITEM 4's WATCH. `--drift-fatal=required` survives as a local re-arm and NO
#         workflow may pass it — an unwatched second enforcement path beside a new
#         verdict is the thing DIVE-3188 refused to leave standing. And the scheduled
#         rail must not pass `--drift-strict` either: release-cut.yml refuses to cut on
#         ANY red on main's tip, so a workflow that reddened on a stale header would
#         re-create the exact harm DIVE-3163 measured, through a scheduled door.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2692: the corpus RC contract. Registered HERE, above the `cd ... || exit 2`
# below, because that is an early exit and a trap set after it would not cover it.
# The TMP cleanup is FOLDED IN rather than left as a second `trap ... EXIT` — bash
# keeps only the LAST registration per signal, so a second one silently replaces the
# first and the temp dir would leak with nothing to notice. `${TMP:-}` because TMP is
# not created until further down and this trap is live before it exists.
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"
RUNNER="$ROOT/scripts/run-harnesses.sh"
HARVEST="$ROOT/scripts/tier-cal-harvest.sh"
WINDOW="$ROOT/scripts/tier-cal-window.sh"

TMP="$(mktemp -d /tmp/header-drift-window.XXXXXX)" || exit 2
CORPUS="$TMP/corpus"; mkdir -p "$CORPUS" "$TMP/reports"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
want() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
has() { # has <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
hasnt() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpectedly found [$3] in: $2"; fi; }

mk() { printf '%s\n' "$2" > "$CORPUS/$1"; chmod +x "$CORPUS/$1"; }
run() { OUT="$(bash "$RUNNER" --no-calibrate --corpus-dir="$CORPUS" "$@" 2>&1)"; RC=$?; }

# --- 1-4: the carrier -------------------------------------------------------
mk truthful.sh '#!/usr/bin/env bash
# TIER: nightly — 10.0s measured (DIVE-3188 fixture): headroom to spare.
exit 0'
run --tier=full --budget=600 --label=t
want "a clean corpus still exits 0" "0" "$RC"
# THE ARM THAT MAKES ABSENT MEAN ABSENT. If this line only printed when something
# drifted, then "no drift" and "this build predates DIVE-3188" would be the same bytes
# in the log, and the window could not tell a graded zero from a missing field.
has "a CLEAN run still prints the drift summary line (wrong 0 is a graded zero)" \
  "$OUT" "HEADER DRIFT (DIVE-3188) files 0, wrong 0, policy off"
has "the summary line carries the harness-budget[] prefix the harvester keys on" \
  "$OUT" "harness-budget[full/t]: HEADER DRIFT (DIVE-3188)"

mk wrong_claim.sh '#!/usr/bin/env bash
# TIER: nightly — 0.5s measured (DIVE-3188 fixture): claims half a second, draws four.
sleep 4
exit 0'
run --tier=full --budget=600 --label=t
want "a WRONG header is still only a warning on one box (DIVE-3163 stands)" "0" "$RC"
has "the summary line counts the wrong file" \
  "$OUT" "HEADER DRIFT (DIVE-3188) files 1, wrong 1, policy off"
if [[ "$OUT" =~ harness-budget\[full/t\]:\ HEADER\ DRIFT\ FILE\ WRONG\ [^[:space:]]*wrong_claim\.sh\ claim\ 0\.5s\ measured\ [0-9.]+s\ over\ [0-9]+% ]]; then
  ok "one parseable per-FILE row, carrying severity, name, claim and measurement"
else bad "one parseable per-FILE row, carrying severity, name, claim and measurement" "$OUT"; fi

# --- 5-9: harvest -----------------------------------------------------------
# `gh run view --log` prefixes every line with "<job>\t<step>\t<timestamp> ". The
# harvester splits on the job column FIRST, so the fixture must too — a log built
# without the prefix would grade a parser nobody runs.
mklog() { # mklog <file> <job> <wrong-count> <extra drift rows...>
  local f="$1" job="$2" wrongn="$3"; shift 3
  {
    printf '%s\tRun\t2026-08-10T04:00:00Z harness-budget[full/pristine]: 120 harnesses, 500s wall-clock, budget 1320s (37%% of budget)\n' "$job"
    # The harness-budget[] prefix is not decoration on THIS line either: the harvester
    # narrows to a block with `grep harness-budget|runner; applied|EFFECTIVE cap` before
    # it parses anything, so a CALIBRATION line without it is invisible to the parser.
    printf '%s\tRun\t2026-08-10T04:00:00Z harness-budget[full/pristine]: CALIBRATION (measured) 119385us/iter vs baseline 119000us/iter = 100%%\n' "$job"
    printf '%s\tRun\t2026-08-10T04:00:00Z of a normal runner; applied 100%% (clamp 100-150%%) -> effective cap 1320s\n' "$job"
    printf '%s\tRun\t2026-08-10T04:00:00Z harness-budget[full/pristine]: HEADER DRIFT (DIVE-3188) files %d, wrong %s, policy off\n' "$job" "$#" "$wrongn"
    local r; for r in "$@"; do
      printf '%s\tRun\t2026-08-10T04:00:00Z harness-budget[full/pristine]: HEADER DRIFT FILE %s\n' "$job" "$r"
    done
  } > "$f"
}
DROW='WRONG tests/slow_unit.sh claim 41.4s measured 62.1s over 50%'
SROW='stale tests/mild_unit.sh claim 10.0s measured 12.0s over 20%'

mklog "$TMP/log-a" "full-pristine (1)" 1 "$DROW" "$SROW"
"$HARVEST" --from-log="$TMP/log-a" --run=111 --sha=abc --out="$TMP/reports" >/dev/null 2>&1
RA="$TMP/reports/111-full-pristine (1).report"
if [[ -r "$RA" ]]; then ok "harvest wrote a report for the job"; else bad "harvest wrote a report for the job" "$(ls "$TMP/reports")"; fi
BODY="$(cat "$RA" 2>/dev/null)"
has "harvested report carries header_drift_wrong"  "$BODY" "# header_drift_wrong=1"
has "harvested report carries the drift denominator" "$BODY" "# header_drift=2"
has "harvested report carries the policy that governed the run" "$BODY" "# drift_fatal_policy=off"
if [[ "$BODY" == *"# header_drift_file=WRONG"$'\t'"tests/slow_unit.sh"$'\t'"41.4"$'\t'"62.1"$'\t'"50"* ]]; then
  ok "the per-file row survives harvest as a tab-separated repeated key"
else bad "the per-file row survives harvest as a tab-separated repeated key" "$BODY"; fi
has "the existing cal fields are untouched by the new parsing" "$BODY" "# cal_us_per_iter=119385"

# THE NEGATIVE ARM THIS WHOLE ROW TURNS ON. A log from before the carrier shipped must
# yield NO field — not a zero. See the block in tier-cal-harvest.sh.
{ printf 'old-job\tRun\t2026-08-09T04:00:00Z harness-budget[full/pristine]: 120 harnesses, 500s wall-clock, budget 1320s (37%% of budget)\n'; } > "$TMP/log-old"
"$HARVEST" --from-log="$TMP/log-old" --run=222 --out="$TMP/old" >/dev/null 2>&1
OLDBODY="$(cat "$TMP/old/222-old-job.report" 2>/dev/null)"
hasnt "a PRE-DIVE-3188 log harvests with NO header_drift_wrong — absent, never 0" \
  "$OLDBODY" "header_drift_wrong"

# --- 10-16: the verdict -----------------------------------------------------
W="$TMP/w"; mkdir -p "$W"
mkreport() { # mkreport <file> <run> <job> <wrong> [rows...]
  local f="$1" run="$2" job="$3" wrong="$4"; shift 4
  {
    printf '# run-harnesses report (HARVESTED from CI log by scripts/tier-cal-harvest.sh)\n'
    printf '# harvest_source=ci-log\n# harvest_run_id=%s\n# harvest_job=%s\n' "$run" "$job"
    printf '# tier=full\n# label=pristine\n# harnesses=120\n# wall_clock_s=500\n# budget_s=1320\n# pct_of_budget=37\n'
    printf '# cal_status=measured\n# cal_us_per_iter=119385\n'
    printf '# header_drift_wrong=%s\n# drift_fatal_policy=off\n' "$wrong"
    local r; for r in "$@"; do printf '# header_drift_file=%s\n' "$r"; done
  } > "$W/$f"
}
FROW=$'WRONG\ttests/slow_unit.sh\t41.4\t62.1\t50'
FROW2=$'WRONG\ttests/other_unit.sh\t10.0\t20.0\t100'
FSTALE=$'stale\ttests/mild_unit.sh\t10.0\t12.0\t20'

# Three graded jobs, so the verdict is answerable at all. slow_unit is WRONG on ONE.
mkreport a.report 111 "job-a" 1 "$FROW"
mkreport b.report 222 "job-b" 0
mkreport c.report 333 "job-c" 0 "$FSTALE"
WOUT="$("$WINDOW" "$W"/*.report 2>&1)"; WRC=$?
has "one box's WRONG is a stopwatch disagreement, not a stale claim" \
  "$WOUT" "stopwatch disagreement (1 box)"
hasnt "and it is NOT called a stale claim" "$WOUT" "STALE CLAIM  "
hasnt "a 'stale' severity row never enters the verdict (WARN band, not the FAIL margin)" \
  "$WOUT" "mild_unit.sh"
want "the default is not a gate — a finding does not change the exit code" "0" "$WRC"

# A SECOND, DISTINCT job sees the SAME file. This is the reading the slow-runner
# explanation does not cover, and the only one the removed exit 5 never had.
mkreport b.report 222 "job-b" 1 "$FROW"
WOUT="$("$WINDOW" "$W"/*.report 2>&1)"
has "the same file WRONG on two distinct jobs is a STALE CLAIM" "$WOUT" "STALE CLAIM"
has "and the verdict names the jobs it rests on" "$WOUT" "111/job-a"

# TWO REPORTS, ONE JOB. Distinct reports are not distinct boxes — two attempts on one
# ephemeral VM are one box, and counting them twice would convict a file on its own
# second opinion, which is precisely the one-box assertion DIVE-3163 removed.
rm -f "$W/b.report"
mkreport a2.report 111 "job-a" 1 "$FROW"
mkreport d.report 444 "job-d" 0
WOUT="$("$WINDOW" "$W"/*.report 2>&1)"
has "two reports from the SAME job count as one box" "$WOUT" "stopwatch disagreement (1 box)"

# --drift-strict, on a confirmed recurrence.
mkreport b.report 222 "job-b" 1 "$FROW" "$FROW2"
WOUT="$("$WINDOW" "$W"/*.report --drift-strict 2>&1)"; WRC=$?
want "--drift-strict exits 8 on a confirmed stale claim" "8" "$WRC"
has "the other_unit row, WRONG on only one job, stays a disagreement" "$WOUT" "stopwatch disagreement (1 box)"

# ABSENT IS EXCLUDED, NOT SCORED CLEAN — and the exclusion is NAMED. A window of
# pre-carrier samples must refuse, not report a healthy corpus.
OLD="$TMP/oldw"; mkdir -p "$OLD"
for i in 1 2 3 4; do
  { printf '# run-harnesses report\n# harvest_run_id=9%s\n# harvest_job=job-%s\n' "$i" "$i"
    printf '# tier=full\n# label=pristine\n# harnesses=120\n# wall_clock_s=500\n'
    printf '# cal_status=measured\n# cal_us_per_iter=119385\n'; } > "$OLD/o$i.report"
done
OOUT="$("$OLD"/../../dev/null 2>/dev/null; "$WINDOW" "$OLD"/*.report --drift-strict 2>&1)"; ORC=$?
has "a window of pre-carrier samples is UNDETERMINED, never 'nothing recurred'" \
  "$OOUT" "DRIFT UNDETERMINED"
has "and every excluded sample is named, with why" "$OOUT" "(no header_drift_wrong)"
if (( ORC != 8 )); then ok "--drift-strict does not gate on an undetermined drift window"
else bad "--drift-strict does not gate on an undetermined drift window" "exit $ORC"; fi

# --- 17-18: item 4's watch --------------------------------------------------
# The disarmed arm survives as a local re-arm, so it must stay unreachable from CI.
# `git grep` would read the checkout's branch; this reads the tree as it will ship.
# COMMENT LINES ARE STRIPPED FIRST, and the first version of these arms did not: it
# read its own explanation of why the flag is absent as the flag being present. A grep
# over raw text cannot tell a MENTION from a USE, and the careful author who writes down
# why a control is off is exactly the person it then accuses.
uses_flag() { # uses_flag <flag> -> prints the offending lines, empty if only mentioned
  grep -rn -- "$1" "$ROOT/.github/workflows/" 2>/dev/null | grep -v ':[[:space:]]*#'
}
for _f in --drift-fatal=required --drift-strict; do
  case "$_f" in
    --drift-fatal=required) _why="the verdict is the window, not a per-job exit" ;;
    *)                      _why="release-cut refuses on ANY red on main's tip" ;;
  esac
  _hit="$(uses_flag "$_f")"
  if [[ -n "$_hit" ]]; then bad "no workflow passes $_f — $_why" "$_hit"
  else ok "no workflow passes $_f — $_why"; fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
exit 0
