#!/usr/bin/env bash
# DIVE-2214 — skills and 5dive-plugins publish no tag rail (git ls-remote --tags
# is empty for both), so install.sh's record_sibling_sha writes a best-effort
# derived receipt instead of a DIVE-1977-style pin. doctor must surface that
# receipt: ok with the recorded sha, warn when a repo resolved to null (fetch
# succeeded, sha resolution didn't), warn when the receipt file is absent
# entirely (pre-DIVE-2214 install, or never upgraded since).
# Run: bash tests/doctor_sibling_repos_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-sibling-repos.XXXXXX)"
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

row_for() {
  local repo="$1"
  jq -c --arg n "sibling-repos/$repo" '.[] | select(.name == $n)' <<<"$DOCTOR_CHECKS"
}

# 1. No receipt file at all — warn, not error (never fatal: a box that hasn't
#    upgraded since DIVE-2214 shipped is not broken, just uninformative).
DOCTOR_CHECKS='[]'
doctor_check_sibling_repos "$TMP/nope"
row=$(jq -c '.[0]' <<<"$DOCTOR_CHECKS")
if jq -e '.category == "supply-chain" and .name == "sibling-repos" and .severity == "warn" and (.message | test("missing.*no receipt"))' <<<"$row" >/dev/null; then
  ok_t "missing receipt file is a named warn, not silence"
else
  bad_t "missing receipt file is a named warn, not silence" "$row"
fi

# 2. A resolved sha for one repo, an unresolved (null) one for the other —
#    each repo gets its own row with its own verdict.
cat > "$TMP/sibling-repos.json" <<'EOF'
{"skills":{"sha":"abc123def4567890abc123def4567890abc123d","resolved_at":"2026-08-03T00:00:00Z"},"5dive-plugins":{"sha":null,"resolved_at":"2026-08-03T00:00:00Z"}}
EOF
DOCTOR_CHECKS='[]'
doctor_check_sibling_repos "$TMP"

row=$(row_for skills)
if jq -e '.severity == "ok" and (.message | test("abc123def456.*resolved 2026-08-03"))' <<<"$row" >/dev/null; then
  ok_t "resolved skills sha reports ok with the sha and timestamp"
else
  bad_t "resolved skills sha reports ok with the sha and timestamp" "$row"
fi

row=$(row_for 5dive-plugins)
if jq -e '.severity == "warn" and (.message | test("could not be resolved"))' <<<"$row" >/dev/null; then
  ok_t "null sha (resolution failed) reports warn, distinct from a missing entry"
else
  bad_t "null sha (resolution failed) reports warn, distinct from a missing entry" "$row"
fi

# 3. A repo with no key in the receipt at all (staged before DIVE-2214, file
#    exists from some other write) is distinguished from a null sha.
echo '{"skills":{"sha":"abc123def4567890abc123def4567890abc123d","resolved_at":"2026-08-03T00:00:00Z"}}' > "$TMP/sibling-repos.json"
DOCTOR_CHECKS='[]'
doctor_check_sibling_repos "$TMP"
row=$(row_for 5dive-plugins)
if jq -e '.severity == "warn" and (.message | test("no receipt entry"))' <<<"$row" >/dev/null; then
  ok_t "a repo absent from an existing receipt file is its own distinct warn"
else
  bad_t "a repo absent from an existing receipt file is its own distinct warn" "$row"
fi

echo
echo "doctor_sibling_repos_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
