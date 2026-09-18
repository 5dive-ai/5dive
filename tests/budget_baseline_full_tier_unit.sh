#!/usr/bin/env bash
# DIVE-4519 — THE WEIGHTS TABLE PRICED ONLY THE TIER IT WAS FETCHED FROM.
#
# THE MEASUREMENT (full-sweep 35313238307, main f5e91ee1, 2026-09-18).
# `full-installed-host (1)` exited 4 = OVER BUDGET at wall_clock_s=1358 against
# budget_s=1320, with every one of its 204 harnesses green, while shards 2 and 3
# finished at 811s and 644s. The corpus total had barely moved from the run before it
# (2836s -> 2813s); the DISTRIBUTION had. `tier_shard_assign` had planned all three
# shards at 352s each — a number that was not a measurement, because
# `.github/scripts/fetch-budget-baseline.sh` fetched only the `core-<env>-<shard>`
# artifacts of a green unit-tests run, a job in which no `# TIER: nightly` harness
# ever runs. All 125 nightly harnesses were therefore absent from
# tests/lib/harness-weights.tsv and priced at the median (~1s). The three most
# expensive files in the corpus are all nightly — gate_channel_session_t2_mutation
# (350s), selfcheck_mutation_e2e (152s), harness_rc_corpus_contract_unit (119s) — and
# all three landed in shard 1: ~620s of a 1320s budget the planner could not see.
#
# WHAT THIS FILE GRADES. That the fetcher can be asked for the full tier and that the
# refresher asks; that the merge rule is FULL-WINS rather than max-wins or
# last-file-wins; and — the half that matters more — that NONE of it reaches the
# caller that did not ask. The confirm jobs in unit-tests.yml call the fetcher with no
# flag and pass every file under `baseline-reports/` to `tier_budget_attribution`,
# which keys on the harness PATH and takes the LAST row it reads for one. `tier_list
# full` is every harness in tests/, core included, so unzipping full reports into that
# directory would silently reprice the whole attribution baseline from another run.
# T1-T4 are the anchors for "the default is byte-identical to before this row".
#
# The arms that could be satisfied by DELETING a guard are anchored in both
# directions: a partial full fetch must leave NO full rows AND must not disarm the
# core baseline (T12/T12b); a red full row is dropped while its GREEN neighbours in
# the same report survive (T9/T9b); and the mutant is proven to be a working fetcher
# that differs in exactly this case (M0a/M0b/M2/M3).
#
# Only `gh` is stubbed. zip/unzip are the real ones, so the artifact round-trip this
# script performs is the one CI performs.
#
# Run: bash tests/budget_baseline_full_tier_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
TMP="$(mktemp -d /tmp/budget-baseline-full-tier.XXXXXX)"
export TMPDIR="$TMP"
mkdir -p "$TMP/bin" "$TMP/fix/runs" "$TMP/fix/arts" "$TMP/fix/zips"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
chk()   { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want=[$3] got=[$2]"; }

# ── the sandbox repo ────────────────────────────────────────────────────────────
# Both scripts under test, in the layout they resolve each other through: the
# refresher calls "$OLDPWD/.github/scripts/fetch-budget-baseline.sh" by path. A copy
# rather than the tree so the MUTANT arms can edit one without touching the checkout.
SBX="$TMP/repo"
mkdir -p "$SBX/.github/scripts" "$SBX/scripts" "$SBX/tests/lib"
cp "$REPO_ROOT/.github/scripts/fetch-budget-baseline.sh" "$SBX/.github/scripts/"
cp "$REPO_ROOT/scripts/refresh-harness-weights.sh"       "$SBX/scripts/"
FETCH="$SBX/.github/scripts/fetch-budget-baseline.sh"
REFRESH="$SBX/scripts/refresh-harness-weights.sh"

# ── fixtures ────────────────────────────────────────────────────────────────────
# ms<TAB>rc<TAB>path, the shape run-harnesses.sh writes. CORE_ONLY is a core-tier
# harness measured in the core job; NIGHTLY is one that only the full sweep ever runs;
# BOTH is a core-tier file that the full sweep also runs, at a different price — the
# overlap the merge rule is about.
CORE_ONLY=tests/aaa_core_only_unit.sh
NIGHTLY=tests/zzz_nightly_only_mutation.sh
BOTH=tests/mmm_runs_in_both_unit.sh
RED_IN_FULL=tests/rrr_red_in_full_unit.sh

mk_report() { # <file> <line...>   each line "ms rc path"
  local f="$1"; shift
  { printf '# harness report fixture\n'
    local l; for l in "$@"; do printf '%s\t%s\t%s\n' $l; done
  } >"$f"
}

# core artifacts: shard 1 and 2 of a green unit-tests run, per environment
for env in pristine installed; do
  base=$([[ $env == pristine ]] && echo 1000 || echo 2000)
  mkdir -p "$TMP/fix/build/core-$env-1" "$TMP/fix/build/core-$env-2"
  mk_report "$TMP/fix/build/core-$env-1/core-$env-1.txt" \
    "$((base + 10)) 0 $CORE_ONLY" "$((base + 20)) 0 $BOTH"
  # the verdict hand-off file rides along in the same artifact and must never reach
  # the join — it is not a report and its lines are not measurements.
  printf 'verdict=ok\n' >"$TMP/fix/build/core-$env-1/core-verdict-$env-1.txt"
  mk_report "$TMP/fix/build/core-$env-2/core-$env-2.txt" "$((base + 30)) 0 tests/filler_core_unit.sh"
done
# full artifacts: shard 1 and 2 of the most recent completed full sweep
for env in pristine installed; do
  base=$([[ $env == pristine ]] && echo 100000 || echo 200000
)
  mkdir -p "$TMP/fix/build/full-$env-1" "$TMP/fix/build/full-$env-2"
  mk_report "$TMP/fix/build/full-$env-1/full-$env-1.txt" \
    "$((base + 1)) 0 $NIGHTLY" "$((base + 2)) 0 $BOTH" "$((base + 3)) 1 $RED_IN_FULL"
  mk_report "$TMP/fix/build/full-$env-2/full-$env-2.txt" "$((base + 4)) 0 tests/filler_full_unit.sh"
done

art_id=100
# NOT a function that PRINTS its id: `$(reg_art …)` would run the counter in a subshell,
# every artifact would come back 101, and `zip -r` appends to an existing archive — so
# one id would name a zip holding every report. The harness stayed green on the arms
# that only count files and went red on the ones that read a price, which is how this
# was caught rather than shipped.
reg_art() { # <run-listing-tsv> <artifact-dir-name>
  art_id=$((art_id + 1))
  ( cd "$TMP/fix/build/$2" && zip -q -r "$TMP/fix/zips/$art_id.zip" . )
  printf '%s\t%s\n' "$art_id" "$2" >>"$1"
}
CORE_RUN=900001
FULL_RUN=900002
FULL_RUN_EMPTY=900003   # a completed run that uploaded nothing matching
: >"$TMP/fix/arts/$CORE_RUN.tsv"
: >"$TMP/fix/arts/$FULL_RUN.tsv"
: >"$TMP/fix/arts/$FULL_RUN_EMPTY.tsv"
for env in pristine installed; do
  for s in 1 2; do
    reg_art "$TMP/fix/arts/$CORE_RUN.tsv" "core-$env-$s"
    reg_art "$TMP/fix/arts/$FULL_RUN.tsv" "full-$env-$s"
  done
done
# artifacts that must NEVER be matched: the confirm re-runs and the sweep's probes.
printf '%s\t%s\n' 777 "core-installed-confirm-1" >>"$TMP/fix/arts/$CORE_RUN.tsv"
printf '%s\t%s\n' 778 "probe-installed-1"        >>"$TMP/fix/arts/$FULL_RUN.tsv"
printf '%s\t%s\n' 779 "probe-slow"               >>"$TMP/fix/arts/$FULL_RUN_EMPTY.tsv"

printf '%s\t%s\t%s\n' "$CORE_RUN" deadbeefcafe 2026-09-18T05:00:00Z >"$TMP/fix/runs/unit-tests"
{ printf '%s\t%s\t%s\t%s\n' "$FULL_RUN_EMPTY" aaaa1111 2026-09-18T06:10:00Z failure
  printf '%s\t%s\t%s\t%s\n' "$FULL_RUN"       bbbb2222 2026-09-18T06:03:00Z failure
} >"$TMP/fix/runs/full-sweep"

# ── the gh stub ─────────────────────────────────────────────────────────────────
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Only `gh api` is modelled, and only the four calls the fetcher makes.
[[ "${1:-}" == "api" ]] || { printf 'gh stub: unexpected verb %s\n' "${1:-}" >&2; exit 2; }
path="$2"
printf 'GH %s\n' "$path" >>"${GH_CALLS:-/dev/null}"
case "$path" in
  *actions/workflows/unit-tests.yml/runs*)
    [[ -n "${GH_NO_CORE_RUN:-}" ]] && exit 1
    cat "$FIX/runs/unit-tests" ;;
  *actions/workflows/full-sweep.yml/runs*)
    [[ -n "${GH_NO_FULL_RUN:-}" ]] && exit 1
    cat "$FIX/runs/full-sweep" ;;
  *actions/runs/*/artifacts*)
    rid="${path#*actions/runs/}"; rid="${rid%%/*}"
    [[ -s "$FIX/arts/$rid.tsv" ]] || exit 1
    cat "$FIX/arts/$rid.tsv" ;;
  *actions/artifacts/*/zip)
    aid="${path#*actions/artifacts/}"; aid="${aid%%/*}"
    [[ ",${GH_FAIL_ZIP:-}," == *",$aid,"* ]] && exit 1
    [[ -f "$FIX/zips/$aid.zip" ]] || exit 1
    cat "$FIX/zips/$aid.zip" ;;
  *) printf 'gh stub: unexpected path %s\n' "$path" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export FIX="$TMP/fix"
export GITHUB_REPOSITORY=5dive-ai/5dive

run_fetch() { # <env> [args...] -> CWD is a fresh scratch dir, left at $RUNDIR
  RUNDIR="$(mktemp -d "$TMP/run.XXXXXX")"
  export GH_CALLS="$RUNDIR/gh.calls"; : >"$GH_CALLS"
  OUT="$( cd "$RUNDIR" && bash "$FETCH" "$@" 2>&1 )"; RC=$?
}
ls_reports()      { ls "$RUNDIR/baseline-reports"      2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
ls_reports_full() { ls "$RUNDIR/baseline-reports-full" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }

# ── T1-T4 — THE DEFAULT IS TODAY ───────────────────────────────────────────────
run_fetch installed
chk "T1 the default call still exits 0"                              "$RC" "0"
chk "T1b and fetches exactly the core shard reports, verdict dropped" \
    "$(ls_reports)" "core-installed-1.txt core-installed-2.txt"
chk "T2 the default call creates NO full-tier directory at all"      "$(ls_reports_full)" ""
chk "T3 and never asks GitHub for a full-sweep run" \
    "$(grep -c 'full-sweep' "$GH_CALLS")" "0"
[[ "$OUT" == *"baseline is run $CORE_RUN"* ]] \
  && ok_t "T4 the default call names the core run it priced from" \
  || bad_t "T4 the default call names the core run it priced from" "$OUT"
# The confirm-run artifact shares the prefix and must be excluded by the [0-9]+ anchor
# alone — a shape T1b would also catch, stated separately so a regression says which.
chk "T4b core-<env>-confirm-<n> is not a baseline shard"  "$(grep -c 'artifacts/777/zip' "$GH_CALLS")" "0"

# ── T5-T8 — THE OPT-IN ─────────────────────────────────────────────────────────
run_fetch installed --tiers=core+full
chk "T5 core+full exits 0"                                           "$RC" "0"
chk "T5b and the CORE directory is unchanged by asking for full"     "$(ls_reports)" "core-installed-1.txt core-installed-2.txt"
chk "T6 the full reports land in their OWN directory"                "$(ls_reports_full)" "full-installed-1.txt full-installed-2.txt"
[[ "$OUT" == *"full-tier rows are run $FULL_RUN"* ]] \
  && ok_t "T7 it names the full-sweep run and its conclusion" \
  || bad_t "T7 it names the full-sweep run and its conclusion" "$OUT"
[[ "$OUT" == *"conclusion=failure"* ]] \
  && ok_t "T7b a RED full sweep is usable and says so — requiring success would deadlock on the very imbalance this fixes" \
  || bad_t "T7b a RED full sweep is usable and says so" "$OUT"
chk "T8 the sweep's probe-* artifacts are not baseline shards" "$(grep -c 'artifacts/778/zip' "$GH_CALLS")" "0"
# THE MOST RECENT RUN WHOSE REPORTS EXIST: run $FULL_RUN_EMPTY is newer and completed,
# and carries only a probe artifact. Stopping there would report no rows with last
# night's sitting one row down.
[[ "$OUT" != *"full-tier rows are run $FULL_RUN_EMPTY"* ]] \
  && ok_t "T8b a newer completed run carrying no full-<env>-* shard is walked past, not settled on" \
  || bad_t "T8b a newer completed run carrying no shard is walked past" "$OUT"

# ── T9-T11 — THE MERGE, through the refresher ──────────────────────────────────
run_refresh() { # [args...] -> table at $SBX/tests/lib/harness-weights.tsv
  rm -f "$SBX/tests/lib/harness-weights.tsv"
  export GH_CALLS="$TMP/refresh.calls"; : >"$GH_CALLS"
  ROUT="$( cd "$SBX" && bash "$REFRESH" "$@" 2>&1 )"; RRC=$?
  TBL="$SBX/tests/lib/harness-weights.tsv"
}
weight() { # <path> <1=pristine|2=installed column offset>
  awk -F'\t' -v f="$1" -v c="$2" '$1 == f { print $(c+1); found=1 } END { if (!found) print "NOROW" }' "$TBL"
}
run_refresh
chk "T9 the refresher exits 0 with both tiers available"             "$RRC" "0"
chk "T9a a nightly-only harness now carries its FULL-tier milliseconds (installed)" \
    "$(weight "$NIGHTLY" 2)" "200001"
chk "T9b a RED full row is dropped while its green neighbours in the same report survive" \
    "$(weight "$RED_IN_FULL" 2)" "NOROW"
chk "T10 FULL WINS THE OVERLAP — a harness measured in both takes the full figure" \
    "$(weight "$BOTH" 2)" "200002"
chk "T10b ... in the pristine column too, from that environment's own full report" \
    "$(weight "$BOTH" 1)" "100002"
chk "T11 a core-only harness the full sweep never measured keeps its core figure" \
    "$(weight "$CORE_ONLY" 2)" "2010"
grep -q '^# generated=.*full_run='"$FULL_RUN"' tiers=core+full ' "$TBL" \
  && ok_t "T11b the header records the full run and the tiers, so the table states its own basis" \
  || bad_t "T11b the header records the full run and the tiers" "$(sed -n 3p "$TBL")"

# ── T12-T14 — FAILING THE SECOND FETCH MUST NOT DISARM THE FIRST ───────────────
GH_FAIL_ZIP="$(awk -F'\t' '$2 == "full-installed-2" { print $1 }' "$TMP/fix/arts/$FULL_RUN.tsv")"
export GH_FAIL_ZIP
run_fetch installed --tiers=core+full
chk "T12 a partial full fetch still exits 0"                         "$RC" "0"
chk "T12a MATCHED IS NOT FETCHED — it leaves NO full rows rather than half of them" "$(ls_reports_full)" ""
chk "T12b and the CORE baseline is untouched: a stale weights table is safe, an unattributed red is not" \
    "$(ls_reports)" "core-installed-1.txt core-installed-2.txt"
[[ "$OUT" == *"NO FULL-TIER ROWS"* && "$OUT" == *"never as \"measured at zero\""* ]] \
  && ok_t "T12c and it says so out loud, in the words a caller has to act on" \
  || bad_t "T12c it says so out loud" "$OUT"
run_refresh
chk "T13 the refresher REFUSES a core-only table rather than writing a fresh-looking one" "$RRC" "1"
chk "T13b and writes no table at all" "$([[ -f "$TBL" ]] && echo present || echo absent)" "absent"
run_refresh --allow-core-only
chk "T14 --allow-core-only is the recorded escape and it succeeds"   "$RRC" "0"
chk "T14a the nightly harness is back to having no row — the defect, accepted knowingly" \
    "$(weight "$NIGHTLY" 2)" "NOROW"
grep -q '^# generated=.*full_run=none tiers=core ' "$TBL" \
  && ok_t "T14b and the header stamps tiers=core, so the table names the plan it cannot price" \
  || bad_t "T14b the header stamps tiers=core" "$(sed -n 3p "$TBL")"
unset GH_FAIL_ZIP

# ── T15 — no full-sweep run at all ─────────────────────────────────────────────
GH_NO_FULL_RUN=1 run_fetch installed --tiers=core+full
chk "T15 an unreachable full-sweep listing exits 0"                  "$RC" "0"
chk "T15a with no full rows"                                         "$(ls_reports_full)" ""
chk "T15b and the core baseline still fetched"                       "$(ls_reports)" "core-installed-1.txt core-installed-2.txt"

# ── MUTANT — revert the full fetch ─────────────────────────────────────────────
# The mutation is the one-line revert of the tier switch: the addendum exits before it
# runs, so the script is exactly the pre-DIVE-4519 fetcher wearing the new flag. M0a
# and M0b are the non-vacuity controls — the sed must MATCH, and what it produces must
# still be a working fetcher, or every arm below passes for the wrong reason.
MUT="$TMP/fetch-mutant.sh"
MUT_MARK='MUTANT: the full tier is never fetched'
# '%' as the delimiter on purpose: the pattern carries '||' and the replacement carries
# '#', so neither of the two obvious delimiters can be used here. An unusable delimiter
# does not fail loudly — sed errors, $MUT is left EMPTY, and a `cmp` control then reports
# "the files differ" and goes green on a mutation that never happened.
sed 's%^\[\[ "\$tiers" == "core+full" \]\] || exit 0$%exit 0  # '"$MUT_MARK"'%' \
  "$REPO_ROOT/.github/scripts/fetch-budget-baseline.sh" >"$MUT"
chk "M0a BEFORE — the mutation SUBSTITUTED the shipped tier switch, exactly once" \
    "$(grep -c -- "$MUT_MARK" "$MUT")" "1"
chk "M0a2 ... and the line it replaces is gone, so the revert is real and not an addition" \
    "$(grep -c '^\[\[ "\$tiers" == "core+full" \]\] || exit 0$' "$MUT")" "0"
chk "M0a3 ... and the mutant is otherwise the shipped script, one line different" \
    "$(diff "$REPO_ROOT/.github/scripts/fetch-budget-baseline.sh" "$MUT" | grep -c '^[<>]')" "2"
bash -n "$MUT" && ok_t "M0b ... and the mutant is still valid bash — a working fetcher, not a syntax error" \
               || bad_t "M0b the mutant does not parse" "a broken script fails every arm for the wrong reason"
cp "$MUT" "$FETCH"
run_fetch installed --tiers=core+full
chk "M1 MUTANT — asking for core+full fetches NO full rows (T6 is red on it)" "$(ls_reports_full)" ""
chk "M2 MUTANT — the core half still works, so the mutant is a fetcher that differs in exactly this case (T1b green on it)" \
    "$(ls_reports)" "core-installed-1.txt core-installed-2.txt"
run_refresh
chk "M3 MUTANT — the refresher refuses, because a core-only table is what it now gets (T9 is red on it)" "$RRC" "1"
cp "$REPO_ROOT/.github/scripts/fetch-budget-baseline.sh" "$FETCH"
run_refresh
chk "M4 RESTORE took — the shipped fetcher prices the nightly harness from the full sweep again" \
    "$(weight "$NIGHTLY" 2)" "200001"

printf -- '-----\n%s: %s passed, %s failed\n' "$(basename "$0" .sh)" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
