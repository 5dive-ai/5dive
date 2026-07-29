#!/usr/bin/env bash
# DIVE-2287: every staleness signal we ship is a COMPARISON against a published
# "latest". When the release process itself stops, the comparand stops too —
# every box compares equal, `behind` is false fleet-wide, and the board reports
# green while nothing has updated for a week. DIVE-2243's monotonicity guard
# made that sharper, not safer: it turned a silent fleet-wide DOWNGRADE into a
# loud refusal AND a frozen fleet, and nothing alarms on a frozen fleet.
#
# `_cli_freeze_observe` is the ABSOLUTE reading that survives all of it: has the
# version this box RUNS changed, ever, within N days. No comparand, so no way
# for a dead cutter to silence it.
#
# Hermetic in the shape DIVE-2042 established: the observer block is extracted
# VERBATIM from src/cmd_selfupdate.sh between its fence markers and run as the
# shipped bytes, with `now` injected as the third argument so no case depends on
# the wall clock. jq/date are the REAL ones.
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload, and silencing it silenced 210 harnesses at once.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-2287 version-freeze observer/,/^# <<< DIVE-2287 version-freeze observer/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_cli_freeze_observe()' <<<"$block"; then
  ok_t "observer block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "observer block missing" "markers '# >>> / # <<< DIVE-2287 version-freeze observer' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DAY=86400
NOW=1753800000   # fixed epoch; never `date +%s` — a wall-clock test is not a test

# observe <version> <record> <now> [block-override] -> three lines
observe() {
  local blk="${4:-$block}"
  bash -c "set -uo pipefail
$blk
_cli_freeze_observe \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"
}
line() { sed -n "$2p" <<<"$1"; }
# Write a record as it would look if <version> were first seen <age> secs ago.
seed() { printf '{"version":"%s","first_seen_epoch":%s,"first_seen_at":"x"}\n' "$1" "$2" > "$3"; }

# --------------------------------------------------------------------- 1 --
# ABSENT RECORD IS UNKNOWN, NOT FRESH. "First pass on a new box" and "record
# wiped" emit the same absence, so it resolves to neither. A green here would
# rebuild DIVE-2230's fail-open one layer down.
rec="$WORK/absent.json"
out="$(observe 0.17.1 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == unknown ]]; then
  ok_t "no prior record => UNKNOWN (never a green)"
else
  bad_t "absent record did not resolve to unknown" "state '$(line "$out" 1)'"
fi
if [[ -r "$rec" ]] && [[ "$(jq -r .version "$rec")" == "0.17.1" ]] \
   && [[ "$(jq -r .first_seen_epoch "$rec")" == "$NOW" ]]; then
  ok_t "absent record is seeded with the running version and the clock starts"
else
  bad_t "record was not seeded" "$(cat "$rec" 2>&1)"
fi

# --------------------------------------------------------------------- 2 --
# The alarm itself.
rec="$WORK/old.json"; seed 0.17.1 $((NOW - 8 * DAY)) "$rec"
out="$(observe 0.17.1 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == frozen && "$(line "$out" 2)" == "$((8 * DAY))" ]]; then
  ok_t "unchanged version, 8d old record => FROZEN with the age in seconds"
else
  bad_t "8d-unchanged version did not report frozen" "state '$(line "$out" 1)' age '$(line "$out" 2)'"
fi
# The claim must be the OBSERVED one. "has not changed" asserts something we
# never watched; "has not been observed to change" is what the record supports,
# and it is also true for a seeded clock, which the stronger phrasing is not.
if [[ "$(line "$out" 3)" == *"not been observed to change"* ]]; then
  ok_t "frozen detail states the observed claim, not the stronger unobserved one"
else
  bad_t "frozen detail overclaims" "'$(line "$out" 3)'"
fi

# --------------------------------------------------------------------- 3 --
rec="$WORK/recent.json"; seed 0.17.1 $((NOW - 2 * DAY)) "$rec"
out="$(observe 0.17.1 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == moving ]]; then
  ok_t "unchanged version, 2d old record => moving (inside the window)"
else
  bad_t "2d-old record misclassified" "state '$(line "$out" 1)'"
fi

# --------------------------------------------------------------------- 4 --
# NON-VACUITY for case 2: prove the 7d threshold is what produced `frozen`, not
# some path that reports frozen regardless. One-line mutant pushing the window
# past the fixture; if case 2 still says frozen under it, case 2 proves nothing.
mut="${block/_CLI_FREEZE_AFTER_SECS=\$((7 \* 86400))/_CLI_FREEZE_AFTER_SECS=\$((999 * 86400))}"
if [[ "$mut" == "$block" ]]; then
  bad_t "threshold mutation did not land" "the _CLI_FREEZE_AFTER_SECS line did not match — case 2 is UNGRADED"
else
  ok_t "threshold mutation landed (the substitution changed the block)"
  rec="$WORK/old2.json"; seed 0.17.1 $((NOW - 8 * DAY)) "$rec"
  mout="$(observe 0.17.1 "$rec" "$NOW" "$mut")"
  if [[ "$(line "$mout" 1)" == moving ]]; then
    ok_t "widening the window flips the 8d case to moving — the threshold is graded"
  else
    bad_t "8d case reports frozen even with a 999d window" "state '$(line "$mout" 1)' — case 2 is vacuous"
  fi
fi

# --------------------------------------------------------------------- 5 --
# A version CHANGE is the movement signal, and it restarts the clock.
rec="$WORK/moved.json"; seed 0.17.1 $((NOW - 30 * DAY)) "$rec"
out="$(observe 0.17.2 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == moving && "$(line "$out" 3)" == *"0.17.1 -> 0.17.2"* ]]; then
  ok_t "a changed version reports moving and names both versions"
else
  bad_t "version change misreported" "state '$(line "$out" 1)' detail '$(line "$out" 3)'"
fi
if [[ "$(jq -r .version "$rec")" == "0.17.2" && "$(jq -r .first_seen_epoch "$rec")" == "$NOW" ]]; then
  ok_t "the record is rewritten to the new version with the clock restarted"
else
  bad_t "record not restarted on a version change" "$(cat "$rec" 2>&1)"
fi

# --------------------------------------------------------------------- 6 --
# THE MTIME TRAP. The tempting simplification is to drop the recorded epoch and
# `stat` the record (or the installed binary) instead. It passes every case
# above and is WRONG, for a reason that is invisible from here: the installer's
# `refresh_managed_files()` swaps the bundle in unconditionally, so the nightly
# rewrites 5dive every night whether or not the version moved — an mtime-based
# freeze reading says "moved yesterday" forever and can never fire. Touch the
# record to NOW and the answer must not move: the epoch INSIDE the file is the
# baseline, and nothing about the file's own timestamps may be.
rec="$WORK/touched.json"; seed 0.17.1 $((NOW - 9 * DAY)) "$rec"
touch "$rec"
out="$(observe 0.17.1 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == frozen ]]; then
  ok_t "touching the record does not reset the freeze clock (baseline is the recorded epoch)"
else
  bad_t "the record's own mtime leaked into the reading" "state '$(line "$out" 1)'"
fi

# --------------------------------------------------------------------- 7 --
# Unusable inputs resolve to UNKNOWN and never fail the caller — this runs
# inside a supervisor tick and inside a read-only `update --check`.
rec="$WORK/corrupt.json"; printf 'not json at all\n' > "$rec"
out="$(observe 0.17.1 "$rec" "$NOW")"; rc=$?
if (( rc == 0 )) && [[ "$(line "$out" 1)" == unknown ]]; then
  ok_t "an unparseable record => UNKNOWN, exit 0"
else
  bad_t "corrupt record not handled" "rc=$rc state '$(line "$out" 1)'"
fi

rec="$WORK/future.json"; seed 0.17.1 $((NOW + 5 * DAY)) "$rec"
out="$(observe 0.17.1 "$rec" "$NOW")"
if [[ "$(line "$out" 1)" == unknown && "$(line "$out" 3)" == *skew* ]]; then
  ok_t "a record dated in the future => UNKNOWN (clock skew), not a negative age"
else
  bad_t "future-dated record mishandled" "state '$(line "$out" 1)' detail '$(line "$out" 3)'"
fi

# Read-only state dir: `update --check` takes no root, so the write must fail
# SOFT. The observation degrades to unknown — which is honestly what an
# unrecordable observation is — and the command still answers.
ro="$WORK/ro"; mkdir -p "$ro"; chmod 555 "$ro"
if [[ -w "$ro" ]]; then
  printf 'skip - read-only dir case (running as root: chmod is inert)\n'
else
  out="$(observe 0.17.1 "$ro/rec.json" "$NOW")"; rc=$?
  if (( rc == 0 )) && [[ "$(line "$out" 1)" == unknown ]]; then
    ok_t "an unwritable state dir => UNKNOWN, exit 0 (no root required to run --check)"
  else
    bad_t "unwritable state dir broke the observer" "rc=$rc state '$(line "$out" 1)'"
  fi
fi
chmod 755 "$ro"

out="$(observe "" "$WORK/x.json" "$NOW")"
if [[ "$(line "$out" 1)" == unknown ]]; then
  ok_t "an unreadable running version => UNKNOWN"
else
  bad_t "empty version not handled" "state '$(line "$out" 1)'"
fi
out="$(observe 0.17.1 "" "$NOW")"
if [[ "$(line "$out" 1)" == unknown ]]; then
  ok_t "no record path => UNKNOWN"
else
  bad_t "empty record path not handled" "state '$(line "$out" 1)'"
fi

# --------------------------------------------------------------------- 8 --
# WIRING FENCE, and it is a STRUCTURAL assertion, not a behavioural one — say so
# rather than let it read as coverage it is not. What it defends is an ordering
# claim that no unit of the observer can express: inside `_sup_cli_check`, the
# freeze observation must run BEFORE the staleness probe's early returns. Every
# one of those returns is a case where the comparison could not be made, which
# is precisely when the absolute reading is the only signal left; move the call
# below them and the alarm goes silent in exactly the conditions it exists for,
# with no test failing.
sup="$(sed -n '/^_sup_cli_check() {/,/^}/p' src/cmd_supervisor.sh)"
if [[ -z "$sup" ]]; then
  bad_t "_sup_cli_check not extractable" "function body not found in src/cmd_supervisor.sh"
else
  # Anchor on the PROBE CALL, not on the first `return 0` — the first return in
  # this function is the once-per-process memo guard, which legitimately
  # precedes everything. Every early return that matters is downstream of the
  # probe, so "before the probe" is the checkable form of the claim.
  obs_at=$(grep -n '_cli_freeze_observe'  <<<"$sup" | head -1 | cut -d: -f1)
  prb_at=$(grep -n '_published_cli_probe' <<<"$sup" | head -1 | cut -d: -f1)
  memo_at=$(grep -n '_SUP_CLI_CHECKED' <<<"$sup" | head -1 | cut -d: -f1)
  if [[ -n "$obs_at" && -n "$prb_at" ]] && (( obs_at < prb_at )); then
    ok_t "supervisor observes the freeze BEFORE the staleness probe (so no probe outage can silence it)"
  else
    bad_t "freeze observation runs after the staleness probe in _sup_cli_check" \
          "observe at line ${obs_at:-none}, probe at line ${prb_at:-none} — a probe outage would silence the alarm"
  fi
  if [[ -n "$memo_at" ]] && (( memo_at < obs_at )); then
    ok_t "the once-per-process memo guard still precedes the observation (no double-write per pass)"
  else
    bad_t "memo guard no longer precedes the freeze observation" \
          "memo at line ${memo_at:-none}, observe at line ${obs_at:-none}"
  fi
  # The whole point of an ABSOLUTE reading is that it takes no comparand. If it
  # ever gets gated on the probe's own result, it has rejoined the family it was
  # written to be independent of.
  if ! grep -qE '(_SUP_CLI_(BEHIND|STALE|LATEST)|consistent).*_cli_freeze_observe' <<<"$sup"; then
    ok_t "the freeze observation is not gated on the probe's verdict"
  else
    bad_t "freeze observation depends on the staleness probe" "it is no longer absolute"
  fi
fi

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
