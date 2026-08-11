#!/usr/bin/env bash
# TIER: nightly — mutation harness (demoted under the mutation-harness rule, DIVE-2867).
#
# DIVE-3245 CONNECTION PROOF. main's gate answer: "THE MUTATION ARM IS THE
# DELIVERABLE, not the cap. A cap that never fires and a cap that fires on
# everyone both present as no complaints." So this disconnects the cap seven ways
# with syntax-valid source mutations and proves the unit harness NOTICES each one
# — and, just as important, that the mutation reds only the arms it should.
#
# M1-M4 perturb the RULE; M5-M7 perturb the KEY AND THE COUNT. That split is not
# cosmetic. The first four were all green at a9618e4 while the cap had a bypass,
# because every one of them drove the cap through `--from` — the same door the
# bypass used. A mutation suite proves the arms are wired to the logic they grade;
# it says nothing whatever about an axis no mutation moves (DIVE-3245 it.2).
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
if [[ "$base_out" == *'RESULT: 25 passed, 0 failed'* ]]; then
  ok_t "baseline: unit harness is green before any mutation"
else
  bad_t "baseline: unit harness is green before any mutation" "$(tail -4 <<<"$base_out")"
fi

# run_mutation <label> <sed-expr> <must-red-regex> <must-stay-green-regex>
run_mutation() {
  local label="$1" expr="$2" must_red="$3" must_green="$4"
  local dir="$MUT_TMP/$label"
  rm -rf "$dir"; mkdir -p "$dir"; cp -a "$ROOT/src" "$dir/src"
  local target="$dir/src/cmd_task.sh"
  local before after
  before=$(md5sum "$target" | cut -d' ' -f1)
  sed -i "$expr" "$target"
  after=$(md5sum "$target" | cut -d' ' -f1)
  if [[ "$before" == "$after" ]]; then
    bad_t "$label: mutation applied (anchor still matches the source)" "sed was a no-op — the anchor has drifted"
    return
  fi
  ok_t "$label: mutation applied to a copy of src"
  # A mutation must stay SYNTAX-VALID, or every arm reds for the wrong reason and
  # the result says nothing about the cap.
  if bash -n "$target" 2>/dev/null; then
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

# ---- M5: the KEY goes back to the CLAIM -------------------------------------
# THE MUTATION THIS SUITE DID NOT HAVE, and its absence is why a9618e4 shipped a
# bypass under a green board. M1-M4 all perturb the RULE (threshold, window,
# priority, template) and every one of them reds correctly — but each drives the
# cap through `--from`, which is the same door the bypass uses, so no arrangement
# of them could have noticed the key.
#
# This restores the shipped defect exactly: count on the claim instead of the
# derivation. Read the CONTROL carefully, because it is the finding — an
# over-budget filer with NO `--from` is still refused, so the cap looks completely
# healthy while one argv token walks around it. A mutation is only evidence about
# the axis it moves, and a green suite says nothing about the axes it never moved.
run_mutation m5-key-on-the-claim \
  's/_vfiler=$(task_actor "")/_vfiler=$(task_actor "$from")/' \
  'a FRESH --from does NOT start a fresh budget' \
  'at the cap, a medium row is REFUSED'

# ---- M6: the COUNT goes back to created_by ----------------------------------
# The other half of the same key, one layer down. `created_by` is the CLAIM on any
# row that carried one, so counting it re-opens the hole from the query side even
# with the caller keyed correctly. Control: a filer whose two columns AGREE is
# still refused — which is every arm above, and precisely why this needs its own.
run_mutation m6-count-on-created-by \
  "s@COALESCE(NULLIF(derived_actor,''), created_by)@created_by@" \
  'rows filed as a relay principal are charged to the SEAT' \
  'at the cap, a medium row is REFUSED'

# ---- M7: loop scaffolding starts counting again ------------------------------
# Same class as M4 and a different writer: `task loop` bypasses the add path
# entirely, so its rows carry no `--materialized` and only the marker separates
# them. Control: the ordinary over-budget refusal is untouched, so this exclusion
# cannot have been implemented by simply counting less.
run_mutation m7-count-loop-scaffolding \
  "s@AND body NOT LIKE '%' || \$(sqlq \"\$loopmark\") || ':%'@@" \
  'loop-materialized rows do NOT count' \
  'at the cap, a medium row is REFUSED'

printf -- '-----\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
