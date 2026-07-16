#!/usr/bin/env bash
# DIVE-1294 regression: the policy doctor category runs by default and is named
# in the validation error, so the explicit --category=policy filter must also
# pass the whitelist and emit only policy checks.
# Run: bash tests/doctor_policy_category_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-policy-category-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "src/$f"
done
# shellcheck source=/dev/null
source src/cmd_doctor.sh

require_root() { :; }
# Read by the sourced doctor implementation.
# shellcheck disable=SC2034
JSON_MODE=1
# shellcheck disable=SC2034
TASKS_DB="$TMP/missing/tasks.db"

set +e
OUT="$(cmd_doctor --category=policy 2>"$TMP/stderr")"
RC=$?
set -e

if [[ "$RC" -ne 0 ]]; then
  printf 'FAIL - doctor --category=policy exited %d\n' "$RC"
  cat "$TMP/stderr"
  exit 1
fi

jq -e '
  .ok == true and
  .data.summary.total == 1 and
  (.data.checks | length) == 1 and
  .data.checks[0].category == "policy" and
  .data.checks[0].name == "precedent-autoclear"
' >/dev/null <<<"$OUT"

echo "ok - doctor --category=policy is accepted and runs only policy checks"
