#!/usr/bin/env bash
# DIVE-2009 — doctor must name the structural precondition that lets a failed
# audit append leave evidence: notify/ is a real 2770 directory in group claude.
# A writable marker path is not enough because the marker does not exist before
# the first drop, and a missing parent is not a disk failure.
# Run: bash tests/doctor_audit_drop_dir_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-audit-drop-dir.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

EXPECTED_GROUP="$(id -gn)"
DROP_DIR="$TMP/audit/notify"

run_check() {
  DOCTOR_CHECKS='[]'
  doctor_check_audit_drop_dir "$DROP_DIR" "$EXPECTED_GROUP"
  jq -c '.[0]' <<<"$DOCTOR_CHECKS"
}

assert_check() {
  local label="$1" severity="$2" message_rx="$3" row
  row=$(run_check)
  if jq -e --arg severity "$severity" --arg rx "$message_rx" \
      '.category == "host" and .name == "audit-drop-dir" and
       .severity == $severity and (.message | test($rx))' \
      <<<"$row" >/dev/null; then
    ok_t "$label"
  else
    bad_t "$label" "$row"
  fi
}

# 1. The never-provisioned shape is a named error, not misclassified as disk.
assert_check "missing notify directory is a named error" error "is missing.*expected directory mode 2770"

# 2. A path that exists but is a regular file does not satisfy DIRECTORY.
mkdir -p "$(dirname "$DROP_DIR")"
: >"$DROP_DIR"
chmod 2770 "$DROP_DIR"
assert_check "a mode-2770 regular file is rejected" error "is not a real directory"

# 3. A directory without group write is rejected even though it exists.
rm -f "$DROP_DIR"
mkdir "$DROP_DIR"
chmod 2750 "$DROP_DIR"
assert_check "an existing directory without group write is rejected" error "mode 2750.*expected 2770"

# 4. Group identity is part of the precondition, not inferred from writability.
chmod 2770 "$DROP_DIR"
EXPECTED_GROUP="not-the-actual-group"
assert_check "a 2770 directory in the wrong group is rejected" error "group .*expected 2770, group not-the-actual-group"

# 5. The exact audit_init shape is the sole green control.
EXPECTED_GROUP="$(id -gn)"
assert_check "a 2770 directory in the expected group passes" ok "directory with mode 2770 and group"

echo
echo "doctor_audit_drop_dir_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
