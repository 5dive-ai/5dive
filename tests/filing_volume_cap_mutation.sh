#!/usr/bin/env bash
# TIER: nightly — mutation harness (demoted under the mutation-harness rule, DIVE-2867).
#
# DIVE-3245 CONNECTION PROOF. main's gate answer: "THE MUTATION ARM IS THE
# DELIVERABLE, not the cap. A cap that never fires and a cap that fires on
# everyone both present as no complaints." So this disconnects the cap four ways
# with syntax-valid source mutations and proves the unit harness NOTICES each one
# — and, just as important, that the mutation reds only the arms it should.
#
# WHY THE CONTROL HALF MATTERS. A mutation that reds almost every arm is usually a
# BROKEN HARNESS, not a strong result: if the mutated source fails to load, every
# arm fails for a reason that has nothing to do with the mutation. So each case
# below names the arm(s) that MUST red AND an arm that MUST stay green, and the
# red set is predicted before it is measured.
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${MUT_TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$ROOT/tests/filing_volume_cap_unit.sh"
MUT_TMP="$(mktemp -d /tmp/filing-volume-cap-mut.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
set +e

# ---- baseline: the harness is green against UNMUTATED source ----------------
base_out=$(DIVE_TEST_SRC="$ROOT/src" bash "$UNIT" 2>&1)
if [[ "$base_out" == *'RESULT: 15 passed, 0 failed'* ]]; then
  ok_t "baseline: unit harness is green before any mutation"
else
  bad_t "baseline: unit harness is green before any mutation" "$(tail -4 <<<"$base_out")"
fi

# run_mutation <label> <sed-expr> <must-red-regex> <must-stay-green-regex>
run_mutation() {
  local label="$1" expr="$2" must_red="$3" must_green="$4"
  local dir="$MUT_TMP/$label"
  rm -rf "$dir"; mkdir -p "$dir"; cp -a "$ROOT/src" "$dir/src"
  # DIVE-3278: `task` is src/cmd_task.sh + src/task/*.sh now. sed the whole set and
  # fingerprint the whole set, so a no-op still reads as a no-op.
  local target=("$dir/src/cmd_task.sh" "$dir"/src/task/*.sh)
  local before after
  before=$(cat "${target[@]}" | md5sum | cut -d' ' -f1)
  sed -i "$expr" "${target[@]}"
  after=$(cat "${target[@]}" | md5sum | cut -d' ' -f1)
  if [[ "$before" == "$after" ]]; then
    bad_t "$label: mutation applied (anchor still matches the source)" "sed was a no-op — the anchor has drifted"
    return
  fi
  ok_t "$label: mutation applied to a copy of src"
  # A mutation must stay SYNTAX-VALID, or every arm reds for the wrong reason and
  # the result says nothing about the cap.
  if bash -n "${target[0]}" 2>/dev/null && bash -n "$dir"/src/task/*.sh 2>/dev/null; then
    ok_t "$label: mutated source still parses (the red is behaviour, not a syntax error)"
  else
    bad_t "$label: mutated source still parses" "bash -n failed"
    return
  fi
  local out; out=$(DIVE_TEST_SRC="$dir/src" bash "$UNIT" 2>&1)
  if grep -qE "^FAIL ${must_red}" <<<"$out"; then
    ok_t "$label: the arm that grades this behaviour WENT RED"
  else
    bad_t "$label: the arm that grades this behaviour WENT RED" \
          "expected a FAIL matching /${must_red}/; got: $(grep -c '^FAIL' <<<"$out") failures"
  fi
  if grep -qE "^ok   ${must_green}" <<<"$out"; then
    ok_t "$label: the named CONTROL arm stayed green (harness still functioning)"
  else
    bad_t "$label: the named CONTROL arm stayed green" \
          "control /${must_green}/ did not pass — suspect a broken harness, not a strong mutation"
  fi
}

# ---- M1: the cap stops sparing high/urgent ----------------------------------
# lodar's rule is that a quota must never be able to eat a serious finding. Drop
# the priority exemption from the volume cap's own condition and the two
# never-capped arms must notice. Control: an over-budget MEDIUM row is still
# refused, which proves the cap itself still works and only the exemption moved.
run_mutation m1-no-priority-exemption \
  's/&& -z "$_cap_exempt_priority" ]] \\$/]] \\/' \
  'urgent is never capped' \
  'at the cap, a medium row is REFUSED'

# ---- M2: the cap never fires ------------------------------------------------
# The failure mode that presents as "no complaints". Push the threshold out of
# reach; the fires-arms must red. Control: high is still uncapped, so the
# priority rule is untouched and the harness is plainly still running.
run_mutation m2-threshold-unreachable \
  's/(( _v24 >= _TASK_FILING_DAILY_CAP ))/(( _v24 >= 99999 ))/' \
  'at the cap, a medium row is REFUSED' \
  'high is never capped'

# ---- M3: the window stops rolling -------------------------------------------
# If the window is not honoured the cap counts a filer's whole history, so a
# quiet filer with old rows is refused for work they did last week.
run_mutation m3-window-not-rolling \
  "s/datetime('now','-24 hours')/datetime('now','-9999 hours')/" \
  'rows older than 24h do NOT count' \
  'a filer at 6\/24h'

# ---- M4: materialized rows start counting -----------------------------------
# A recurring instance is created by the scheduler. Counting it burns a
# schedule's budget on a cadence nobody chose that day.
run_mutation m4-count-materialized \
  's/AND COALESCE(from_template_id,0)=0//' \
  'template-materialized rows do NOT count' \
  'a filer at 6\/24h'

printf -- '-----\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
