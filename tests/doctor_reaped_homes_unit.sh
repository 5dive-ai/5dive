#!/usr/bin/env bash
# DIVE-2165 — /home/.5dive-reaped (DIVE-2138's quarantined-agent-home pile) had
# no TTL and no visibility. lodar's decision gate answer was option B: stay
# operator-managed forever (no auto-reap), but stop being invisible. This
# checks the visibility half: `5dive doctor` must report the pile's existence,
# count, oldest age, and permission posture — and must never delete anything.
# Run: bash tests/doctor_reaped_homes_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-reaped-homes.XXXXXX)"

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

DIR="$TMP/.5dive-reaped"

run_check() {
  DOCTOR_CHECKS='[]'
  doctor_check_reaped_homes "$DIR"
  jq -c '.[0]' <<<"$DOCTOR_CHECKS"
}

assert_check() {
  local label="$1" severity="$2" message_rx="$3" row
  row=$(run_check)
  if jq -e --arg severity "$severity" --arg rx "$message_rx" \
      '.category == "host" and .name == "reaped-homes" and
       .severity == $severity and (.message | test($rx))' \
      <<<"$row" >/dev/null; then
    ok_t "$label"
  else
    bad_t "$label" "$row"
  fi
}

# 1. Never-quarantined-anything host: the never-provisioned shape is fine, not an error.
assert_check "missing directory is ok (nothing ever quarantined)" ok "does not exist"

# 2. Directory exists, empty: still ok, still named.
mkdir -p "$DIR"
chmod 700 "$DIR"
assert_check "empty quarantine dir is ok and named" ok "0 quarantined agent homes"

# 3. One quarantined home: reported by name and age, and the manual-delete
#    path is named so an operator never has to guess it (never auto-deleted).
mkdir -p "$DIR/dev-20260101010101"
assert_check "one quarantined home is counted, named, and the delete-by-hand path is given" ok \
  "1 quarantined agent home.*dev-20260101010101.*operator-managed.*DIVE-2165.*sudo rm -rf"

# 4. A second entry: count increases and this check never removes anything.
mkdir -p "$DIR/dev-20260202020202"
assert_check "a second entry bumps the count" ok "^2 quarantined agent home"
[[ -d "$DIR/dev-20260101010101" && -d "$DIR/dev-20260202020202" ]] \
  && ok_t "the check deleted nothing" \
  || bad_t "the check deleted nothing" "an entry vanished after running the doctor check"

# 5. Permission drift off 0700 is the one thing this check treats as a real
#    problem: the whole point of quarantine is that a recycled uid, or any
#    non-root reader, cannot see the credentials inside.
chmod 750 "$DIR"
assert_check "mode drift off 700 is flagged (credentials must not be group-readable)" warn \
  "mode 750, not 700"

# 6. A regular file where the directory should be is a structural error, not
#    a silent no-op — a later `agent rm` cannot quarantine into it either.
chmod 700 "$DIR"
rm -rf "$DIR"
: >"$DIR"
assert_check "a non-directory in place of the quarantine dir is a named error" error \
  "not a real directory"

echo
echo "doctor_reaped_homes_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
