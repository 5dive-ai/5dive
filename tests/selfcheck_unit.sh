#!/usr/bin/env bash
# DIVE-2039 — `5dive selfcheck` runner semantics.
#
# The probes are proven by MUTATION in tests/selfcheck_mutation_e2e.sh (breaking a
# rail for real and requiring red). This harness proves the thing that sits above
# them: that a THIRD VERDICT survives all the way to the exit code.
#
# Weighted toward the FALSE-CLEAN direction, because every way NOT-REACHED can leak
# into "pass" is a way selfcheck goes back to being the instrument it was built to
# replace. A probe that measured nothing must never read as a probe that passed, and
# a probe that measured nothing FOR NO STATED REASON must be a hard failure — the
# reason IS the escape hatch, so an empty one cannot be excusable.
#
# Hermetic: the real probes are never dispatched. `_sc_dispatch` is overridden with a
# fixture table, so this never files a gate, never writes an audit row and never
# shells out.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
SRC=src
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh cmd_selfcheck.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/selfcheck-unit.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

# The fixture table one run answers with. Keyed by probe id.
declare -A FIX=()
_sc_dispatch() { printf '%s\n' "${FIX[$1]:-error||no fixture}"; }

# stdout and stderr are captured SEPARATELY and that separation is itself under test.
# Progress must stream to stderr (a --full sweep is minutes and a silent one is
# indistinguishable from a hang) while stdout stays the machine-readable surface —
# `--json | jq` breaks the moment one progress line leaks into it.
run() { # run <args...> -> sets OUT (stdout) / ERR (stderr) / RC
  OUT=$(cmd_selfcheck "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
}

# ── 1. all pass -> 0 ──────────────────────────────────────────────────────────
FIX=([gate-delivery]="pass||row landed" [audit-root]="pass||row landed")
run --only=gate-delivery,audit-root
chk "all probes pass -> exit 0" 0 "$RC"

# ── 2. one fail -> non-zero, and the detail is SHOWN ─────────────────────────
FIX=([gate-delivery]="fail||no delivery row for the filed gate" [audit-root]="pass||row landed")
run --only=gate-delivery,audit-root
[[ $RC -ne 0 ]] && ok_t "a failing probe exits non-zero" || fail_t "a failing probe exited 0"
grep -q 'no delivery row for the filed gate' <<<"$OUT" \
  && ok_t "the failure detail is printed, not just a count" || fail_t "detail missing: $OUT"

# ── 3. THE CORE PROPERTY: not-reached is NOT pass ────────────────────────────
# It must be rendered as its own state and counted separately. This is the DIVE-2018
# gap restated: a probe that was never reached, reported as one that passed, is a
# rail nobody measured reporting as a rail that works.
FIX=([gate-delivery]="not-reached|no-test-corpus|no checkout here")
run --only=gate-delivery
chk "a reasoned not-reached alone exits 0 (a skip is not an accusation)" 0 "$RC"
grep -q 'NOT-REACHED' <<<"$OUT" && ok_t "not-reached renders as its own verdict" \
  || fail_t "not-reached was not rendered distinctly: $OUT"
grep -q 'no-test-corpus' <<<"$OUT" && ok_t "the reason is printed with the verdict" \
  || fail_t "reason not printed: $OUT"
grep -qE '0 pass, 0 fail, 1 not-reached' <<<"$OUT" \
  && ok_t "not-reached is counted apart from pass" || fail_t "counted as a pass: $OUT"

# ── 4. AN UNEXPLAINED not-reached IS A FAILURE ───────────────────────────────
# The reason is the entire escape hatch. "I did not measure this" with no "because"
# is the silence this verb exists to remove, so it cannot be the cheapest verdict a
# broken probe can return.
FIX=([gate-delivery]="not-reached||")
run --only=gate-delivery
[[ $RC -ne 0 ]] && ok_t "not-reached with NO reason exits non-zero" \
  || fail_t "an unexplained not-reached passed — silence is the cheapest verdict again"
grep -q 'NONE GIVEN' <<<"$OUT" && ok_t "the missing reason is named in the output" \
  || fail_t "missing reason not surfaced: $OUT"

# ── 5. a probe that returns nothing at all is an ERROR, never a pass ─────────
FIX=([gate-delivery]="")
run --only=gate-delivery
[[ $RC -ne 0 ]] && ok_t "a probe that emits no verdict line exits non-zero" \
  || fail_t "an empty probe response passed"
grep -q 'ERROR' <<<"$OUT" && ok_t "an empty probe response renders as ERROR" \
  || fail_t "empty response was not an error: $OUT"

# ── 6. --strict turns any not-reached into a failure ────────────────────────
FIX=([gate-delivery]="not-reached|no-test-corpus|no checkout here")
run --only=gate-delivery --strict
[[ $RC -ne 0 ]] && ok_t "--strict fails a reasoned not-reached" || fail_t "--strict did not fail a not-reached"

# ── 7. the report is machine-readable and names the WHOLE corpus ────────────
# Not just the probes this run happened to execute: the union check has to know what
# was supposed to be covered, and a report that only lists what ran can never reveal
# a probe that ran nowhere.
FIX=([gate-delivery]="pass||row landed")
run --only=gate-delivery --report="$TMP/r.txt" --label=unit-env
chk "--report exits 0 on a passing run" 0 "$RC"
grep -q '^# selfcheck report$' "$TMP/r.txt" && ok_t "report carries its header" \
  || fail_t "no report header"
grep -q "^# probes=$(IFS=,; echo "${SELFCHECK_PROBES[*]}")$" "$TMP/r.txt" \
  && ok_t "report declares the FULL corpus, not just what ran" || fail_t "report corpus is not the full list: $(cat "$TMP/r.txt")"
grep -q '^# label=unit-env$' "$TMP/r.txt" && ok_t "report names its environment" || fail_t "no label"
grep -q '^# allow=$' "$TMP/r.txt" && ok_t "report declares an EMPTY allowlist explicitly" \
  || fail_t "no allow line — the union could not tell an empty allowlist from an absent one: $(cat "$TMP/r.txt")"
FIX=([gate-delivery]="not-reached|no-ops-repo|no ops checkout in CI")
run --only=gate-delivery --report="$TMP/r3.txt" --allow=snapshot-rails
grep -q '^# allow=snapshot-rails$' "$TMP/r3.txt" && ok_t "--allow is carried in the report, not applied locally" \
  || fail_t "--allow not recorded: $(cat "$TMP/r3.txt")"
grep -qP '^pass\tgate-delivery\t' "$TMP/r.txt" && ok_t "report is tab-separated verdict/probe/reason" \
  || fail_t "report row shape wrong: $(cat "$TMP/r.txt")"

# a not-reached report row carries its reason, so the union can quote it
FIX=([gate-delivery]="not-reached|no-test-corpus|nope")
run --only=gate-delivery --report="$TMP/r2.txt"
grep -qP '^not-reached\tgate-delivery\tno-test-corpus$' "$TMP/r2.txt" \
  && ok_t "a not-reached report row carries its reason" || fail_t "reason lost in report: $(cat "$TMP/r2.txt")"

# ── 8. --json shape (the CI contract) ───────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  FIX=([gate-delivery]="pass||row landed" [audit-root]="not-reached|not-root|uid 1007")
  run --json --only=gate-delivery,audit-root
  jq -e . >/dev/null 2>&1 <<<"$OUT" && ok_t "--json emits valid json" || fail_t "invalid json: $OUT"
  chk "--json counts not-reached separately" "1" "$(jq -r '.summary["not-reached"]' <<<"$OUT")"
  chk "--json counts pass separately" "1" "$(jq -r '.summary.pass' <<<"$OUT")"
  chk "--json carries the reason" "not-root" "$(jq -r '.probes[1].reason' <<<"$OUT")"
  chk "--json nulls the reason on a pass (never an empty string that reads as one)" \
    "null" "$(jq -r '.probes[0].reason' <<<"$OUT")"
  FIX=([gate-delivery]="not-reached||")
  run --json --only=gate-delivery
  [[ $RC -ne 0 ]] && ok_t "--json still exits non-zero on an unexplained not-reached" \
    || fail_t "--json swallowed the unexplained not-reached"
  chk "--json reports the unexplained count" "1" "$(jq -r '.summary.unexplained_not_reached' <<<"$OUT")"
else
  printf 'skip - jq absent, --json cases not run\n'
fi

# ── 9. an unknown probe name is refused, not silently skipped ───────────────
out=$( (FIX=(); cmd_selfcheck --only=nope-not-a-probe) 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && ok_t "an unknown --only probe is refused" || fail_t "unknown probe silently accepted"

# ── 10. --list prints the corpus the report and the union agree on ──────────
out=$(cmd_selfcheck --list 2>/dev/null)
chk "--list prints every probe" "${#SELFCHECK_PROBES[@]}" "$(wc -l <<<"$out")"

# ── 11. PROGRESS IS LOUD, AND IT IS ON STDERR ───────────────────────────────
# --full runs every harness in the corpus twice; the first cut printed nothing for
# >15 minutes and was reported as a hang before anyone could show it was merely slow.
# A long job that emits nothing cannot be told apart from a wedged one — which is this
# release's own subject, turned on its flagship verb. So progress is mandatory, and it
# is mandatory on stderr, because stdout belongs to --json and the report.
FIX=([gate-delivery]="pass||row landed" [audit-root]="pass||row landed")
run --only=gate-delivery,audit-root
grep -q 'gate-delivery' <<<"$ERR" && grep -q 'audit-root' <<<"$ERR" \
  && ok_t "each probe announces itself on stderr as it starts" \
  || fail_t "no per-probe progress on stderr: $ERR"
grep -qE '\[1/2\]' <<<"$ERR" && ok_t "progress is counted (n of total), so a stall is locatable" \
  || fail_t "progress carries no position: $ERR"
if command -v jq >/dev/null 2>&1; then
  run --json --only=gate-delivery,audit-root
  jq -e . >/dev/null 2>&1 <<<"$OUT" \
    && ok_t "--json stdout stays parseable with progress streaming" \
    || fail_t "progress leaked into --json stdout: $OUT"
  [[ -n "$ERR" ]] && ok_t "--json still reports progress on stderr" \
    || fail_t "--json went silent instead of moving progress to stderr"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
