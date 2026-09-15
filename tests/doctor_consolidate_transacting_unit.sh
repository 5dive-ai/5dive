#!/usr/bin/env bash
# DIVE-4562 — `5dive doctor --category=memory` must be able to say that a seat's
# memory consolidation is NOT TRANSACTING.
#
# The failure this exists for is invisible to every other memory check, and that
# is the whole point: those grade the CONTENT of a store, and the store of a seat
# whose distiller has been refused by the API for sixteen days is perfectly
# clean. It is frozen. luca measured five teal-fox seats losing 63 consolidation
# passes each over 16 days with nothing said anywhere; 428 API-error turns across
# 12 seats ran on this box over the same window.
#
# So the arms here are about the two readings that must never collapse into each
# other — "no seat is failing" and "nothing has ever run" — and about the
# threshold being a STREAK, not a hair trigger an operator learns to ignore.
# Run: bash tests/doctor_consolidate_transacting_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-consol-tx.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

DIR="$TMP/memory-consolidate"

run_check() { # <threshold>
  DOCTOR_CHECKS='[]'
  doctor_check_consolidate_transacting "$DIR" "${1:-4}"
  jq -c '.[0]' <<<"$DOCTOR_CHECKS"
}

assert_check() { # <label> <severity> <message regex> [threshold]
  local label="$1" severity="$2" rx="$3" thr="${4:-4}" row
  row=$(run_check "$thr")
  if jq -e --arg severity "$severity" --arg rx "$rx" \
      '.category == "memory" and .name == "consolidate" and
       .severity == $severity and (.message | test($rx))' \
      <<<"$row" >/dev/null; then
    ok_t "$label"
  else
    bad_t "$label" "$row"
  fi
}

# 1. Never run here. This is the arm that stops the check from being worse than
#    nothing: a box where the scheduler has never fired must not read "clean".
assert_check "a box where the scheduler never ran is a WARN, not ok" warn "never run on this box"

mkdir -p "$DIR"

# 2. Ran, nobody refusing. The ordinary healthy box.
assert_check "no refusing seat is ok" ok "reached the model"

# 3. One seat under the threshold — real, but a resetting limit or a rotating
#    token looks exactly like this for one pass. WARN, never an error, or the
#    alarm is noise within a day and gets filtered out.
printf '2\n' > "$DIR/alice.notx"
assert_check "a seat under the threshold is a WARN" warn "under the 4-pass threshold"

# 4. THE row's arm: a seat past the threshold is an ERROR and is NAMED. A count
#    is not something an operator can act on.
printf '63\n' > "$DIR/alice.notx"
assert_check "a seat past the threshold is an ERROR"       error "NOT TRANSACTING"
assert_check "and the seat is named, with its streak"      error "alice \(63 passes\)"
assert_check "and the message says retrying will not fix it" error "Retrying will not clear it"

# 4b. EXACTLY at the threshold. Iteration 1 shipped fixtures of 2, 63, 10 and a
#     non-number — never 4 — so the comparison could be relaxed from `>=` to `>`
#     (moving the alarm from one day to 30 hours) with the harness still 12/12
#     green. The boundary is the only value that grades the operator, so it is
#     pinned here: at the threshold is an ERROR, one short of it is not.
printf '4\n' > "$DIR/alice.notx"
assert_check "EXACTLY at the threshold is already an ERROR (pins >=, not >)" error "alice \(4 passes\)"
printf '3\n' > "$DIR/alice.notx"
assert_check "and one pass short of it is still only a WARN"                 warn  "under the 4-pass threshold"
printf '63\n' > "$DIR/alice.notx"

# 5. The threshold is the argument, not a constant baked into the branch.
assert_check "the same file is ok-side of a higher threshold" warn "under the 99-pass threshold" 99

# 6. Two seats: both named, because a fleet-wide auth lapse hits several at once
#    and a check that named only the first would hide the shape entirely.
printf '10\n' > "$DIR/bob.notx"
row=$(run_check 4)
if jq -e '.message | test("alice") and test("bob")' <<<"$row" >/dev/null; then
  ok_t "every failing seat is named, not just the first"
else
  bad_t "every failing seat is named, not just the first" "$row"
fi

# 7. CONTROL — the counter files are the ONLY input, so a cleared seat clears the
#    check. Without this the error is sticky and an operator who fixed the box
#    still sees it, which is how a real alarm gets ignored.
rm -f "$DIR"/*.notx
assert_check "CONTROL: clearing the seats clears the check" ok "reached the model"

# 8. CONTROL — a garbage counter file must not read as a huge streak. It is not a
#    number, so it cannot cross a numeric threshold.
printf 'not-a-number\n' > "$DIR/alice.notx"
assert_check "CONTROL: an unparseable counter never fabricates an alarm" warn "under the 4-pass threshold"
rm -f "$DIR"/*.notx

# 9. The off switch. A box that deliberately runs no consolidation is healthy,
#    and must not be reported as a frozen fleet.
printf '63\n' > "$DIR/alice.notx"
MEMORY_CONSOLIDATE=off assert_check "MEMORY_CONSOLIDATE=off reports ok, not a false alarm" ok "switched off"
rm -f "$DIR"/*.notx

# 11. THE GHOST SEAT (quinn, iteration 1 — blocking). A counter is cleared only
#     by a pass that gets through, so a seat removed WHILE it was refusing left
#     one behind that nothing could ever clear. This check would then have named
#     a seat nobody can restore, forever, with no --fix and no verb to clear it —
#     the cry-wolf alarm alternative (c) was rejected for, through another door.
#     It is likeliest exactly during a fleet-wide auth lapse: several seats
#     refusing at once, remove any one of them.
doctor_consolidate_known_seats() { printf 'alice\nbob\n'; }
printf '63\n' > "$DIR/ghost-seat.notx"
assert_check "a counter for a seat the registry does not know raises NOTHING" ok "reached the model"
row=$(run_check 4)
if jq -e '.message | test("ghost-seat") | not' <<<"$row" >/dev/null; then
  ok_t "and the removed seat is never named"
else
  bad_t "and the removed seat is never named" "$row"
fi
assert_check "it is reported as ignored, not silently dropped" ok "stale counter\(s\) for seat\(s\) the registry no longer knows"

# 12. NEGATIVE CONTROL for that filter — it must remove the ghost and NOTHING
#     else. A filter that swallowed every counter would pass arm 11 and quietly
#     disable the whole check, which is the defect this row exists to fix.
printf '63\n' > "$DIR/alice.notx"
assert_check "CONTROL: a REAL seat past the threshold still errors beside a ghost" error "alice \(63 passes\)"
row=$(run_check 4)
if jq -e '.message | test("ghost-seat") | not' <<<"$row" >/dev/null; then
  ok_t "CONTROL: and the ghost is still not named in the error"
else
  bad_t "CONTROL: and the ghost is still not named in the error" "$row"
fi

# 13. CONTROL — an UNREADABLE registry must not filter. Unknown is not "gone":
#     suppressing a real standing alarm because a registry read hiccuped is the
#     worse of the two errors, so the check fails LOUD, not quiet.
rm -f "$DIR/alice.notx"
doctor_consolidate_known_seats() { return 1; }
assert_check "CONTROL: an unreadable registry still reports the ghost rather than hiding it" error "ghost-seat \(63 passes\)"
# Restore the SHIPPED definition rather than unsetting it, so the next arm
# grades the real default and not an absence production never has.
# shellcheck disable=SC1091
source src/cmd_doctor.sh
rm -f "$DIR"/*.notx

# 14. The shipped default with no registry reachable (no `registry_read` in
#     scope) must also read as UNKNOWN and therefore not filter — the fail-open
#     direction has to hold for the real function, not only for a stub.
printf '63\n' > "$DIR/carol.notx"
assert_check "with no registry function defined, a failing seat is still named" error "carol \(63 passes\)"
rm -f "$DIR"/*.notx

# 10. The check is WIRED, not merely defined — a function nothing calls is the
#     same invisibility this row is about.
grep -q 'doctor_check_consolidate_transacting' src/cmd_doctor.sh \
  && [ "$(grep -c 'doctor_check_consolidate_transacting' src/cmd_doctor.sh)" -ge 2 ] \
  && ok_t "cmd_doctor actually calls the check (defined AND wired)" \
  || bad_t "cmd_doctor does not call the check"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
