#!/usr/bin/env bash
# DIVE-4175: `5dive council floor-diff` — the seal-time diff between the sealed
# constitution's hard_gates and the shipped _GATE_T2_FLOOR_RX. The loader REPLACES
# rather than unions, so ratifying a document silently repeals every default it
# forgot to restate. This grades the report that makes that visible.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/council-floordiff.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - council_floor_diff_unit exited early (rc=%s); assertions after the last ok were SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || true
done
STATE_DIR="$TMP"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Drive the reporting block in isolation: it is a pure function of the two regexes,
# so the fixture is the two regexes. No council runtime, no node, no seal.
run_diff() { # $1=shipped $2=sealed
  local _ship_rx="$1" _live_rx="$2" _t _miss_c=0 _miss_s=0
  _norm() { printf '%s' "$1" | tr '|' '\n' | sed -e 's/^(*//' -e 's/)*$//' | grep -v '^$'; }
  printf 'REPEALED:'
  while IFS= read -r _t; do [[ -n "$_t" ]] || continue
    case "|$(_norm "$_live_rx" | tr '\n' '|')|" in *"|$_t|"*) ;; *) printf ' %s' "$_t"; _miss_c=$((_miss_c+1)) ;; esac
  done < <(_norm "$_ship_rx")
  printf '\nADDED:'
  while IFS= read -r _t; do [[ -n "$_t" ]] || continue
    case "|$(_norm "$_ship_rx" | tr '\n' '|')|" in *"|$_t|"*) ;; *) printf ' %s' "$_t"; _miss_s=$((_miss_s+1)) ;; esac
  done < <(_norm "$_live_rx")
  printf '\nrepealed=%s added=%s\n' "$_miss_c" "$_miss_s"
}

# ---- 1. A TERM THE SEAL OMITS IS NAMED AS REPEALED ----
out=$(run_diff 'spend|delete|€[0-9]' 'spend|delete')
grep -q 'repealed=1 added=0' <<<"$out" && grep -q 'REPEALED: €\[0-9\]' <<<"$out" \
  && ok_t "a shipped term the seal omits is reported repealed" \
  || bad_t "omitted term not reported" "$out"

# ---- 2. AN ORG ADDITION IS NAMED, AND NOT CONFUSED WITH A REPEAL ----
out=$(run_diff 'spend|delete' 'spend|delete|chargeback')
grep -q 'repealed=0 added=1' <<<"$out" \
  && ok_t "a term only the org added is reported as an addition, not a repeal" \
  || bad_t "addition mis-reported" "$out"

# ---- 3. IDENTICAL LISTS DIFF TO NOTHING ----
out=$(run_diff 'spend|delete|purge' 'spend|delete|purge')
grep -q 'repealed=0 added=0' <<<"$out" \
  && ok_t "identical lists report no difference" \
  || bad_t "identical lists reported a difference" "$out"

# ---- 4. REGRESSION: GROUPED CLASSES MUST NOT READ AS REPEALS ----
# The loader emits the constitution's named classes as `(classA)|(classB)`. The
# first version of this report split on `|` alone, so `(spend` and `pricing)` matched
# nothing and it named NINE present terms as repealed. Caught only because the true
# answer was already known behaviourally — a report disagreeing with the measurement
# is the report being wrong. Without this arm the bug returns silently.
out=$(run_diff 'spend|pricing|delete|purge' '(spend|pricing)|(delete|purge)')
grep -q 'repealed=0 added=0' <<<"$out" \
  && ok_t "grouped classes are normalised — boundary terms are not false repeals" \
  || bad_t "paren grouping produced phantom repeals" "$out"

# ---- 5. NEGATIVE CONTROL for arm 4: normalising must not hide a REAL repeal
# inside a grouped list. A fix that stripped too much (or compared nothing) reads
# green on arm 4 alone.
out=$(run_diff 'spend|pricing|delete|€[0-9]' '(spend|pricing)|(delete)')
grep -q 'repealed=1 added=0' <<<"$out" && grep -q 'REPEALED: €\[0-9\]' <<<"$out" \
  && ok_t "a real repeal inside a GROUPED list is still found" \
  || bad_t "normalisation swallowed a real repeal" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
[[ $FAIL -eq 0 ]]
