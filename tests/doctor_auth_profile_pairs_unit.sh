#!/usr/bin/env bash
# DIVE-5957 — doctor probes the credentials seats RUN on, not just the type's
# default connector credential.
#
# The bug (exact-swallow, 2026-10-10): the auth loop called
# `auth_status_one "$type"` with no profile, so it only ever probed
# /etc/5dive/connectors/<type>.env. DIVE-4342 asked whether some seat runs on
# the TYPE, never on that CREDENTIAL. Both directions were a false verdict:
#   1. every claude seat on a named profile, default token dead -> a red
#      `auth/claude` re-auth for a credential no seat reads;
#   2. a seat's PROFILE token dead, default fine -> `auth/claude ok` while that
#      seat cannot run a turn.
#
# Driven through `cmd_doctor --category=auth --json`, not the helper, so the
# same arms run against the pre-fix tree (where they go red: arm A prints
# auth/claude ok and no auth/claude:p1, arm B prints an error).
#
# Seams: registry_read (the registry), TYPE_BIN (installed harnesses) and
# auth_status_one, the leaf that would call the provider. The stub answers by
# the PROFILE it is handed — the fact the defect got wrong — and logs every
# call so the probe count is graded, not assumed.
# Run: bash tests/doctor_auth_profile_pairs_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-auth-profile-pairs.XXXXXX)"

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

# ---- seams -------------------------------------------------------------------
require_root() { :; }
declare -A TYPE_BIN=([claude]=/bin/true)
REG_JSON=""
registry_read() { [[ "$REG_JSON" == "UNREADABLE" ]] && return 1; printf '%s' "$REG_JSON"; }
# STALE_SCOPES: space list of scopes (DEFAULT or a profile name) the provider
# rejects. Called inside $(...), so the call log goes to a FILE.
STALE_SCOPES=""
PROBE_LOG="$TMP/probes"
auth_status_one() {
  local scope="${3:-DEFAULT}"
  printf '%s:%s\n' "$1" "$scope" >>"$PROBE_LOG"
  if [[ " $STALE_SCOPES " == *" $scope "* ]]; then echo stale; else echo ok; fi
}

# run <registry-json> <stale-scopes> -> doctor's --json checks array (auth only)
run() {
  REG_JSON="$1"; STALE_SCOPES="$2"; : >"$PROBE_LOG"
  ( JSON_MODE=1 cmd_doctor --category=auth 2>/dev/null ) | jq -c '[.data.checks // .checks | .[] | select(.category=="auth")]'
}
sev()    { jq -r --arg n "$2" '[.[] | select(.name==$n) | .severity] | if length==0 then "absent" else join(",") end' <<<"$1"; }
errors() { jq -r '[.[] | select(.severity=="error") | .name] | join(",")' <<<"$1"; }
probes() { sort "$PROBE_LOG" | tr '\n' ' ' | sed 's/ $//'; }

P1_TWO='{"agents":{"a":{"type":"claude","authProfile":"p1"},"b":{"type":"claude","authProfile":"p1"}}}'

# ---- A. negative control: dead PROFILE token, default fine -------------------
out=$(run "$P1_TWO" "p1")
[[ "$(sev "$out" claude:p1)" == "error" ]] \
  && ok_t "A: a dead profile token two seats run on is an error on auth/claude:p1" \
  || bad_t "A: dead profile token must read error on auth/claude:p1" "got: $out"
[[ "$(errors "$out")" == "claude:p1" ]] \
  && ok_t "A: it is the only error (no error line for the default)" \
  || bad_t "A: errors should be exactly claude:p1" "got: $(errors "$out")"
[[ "$(probes)" == "claude:p1" ]] \
  && ok_t "A: two seats on p1 cost ONE probe, and the unused default is not probed" \
  || bad_t "A: expected exactly one probe of claude:p1" "got: $(probes)"
jq -e '.[] | select(.name=="claude:p1") | .message | test("seats: a,b") and test("--auth-profile=p1")' <<<"$out" >/dev/null \
  && ok_t "A: the error names the seats and the profile-scoped re-auth command" \
  || bad_t "A: error message should name seats a,b and --auth-profile=p1" "got: $out"

# ---- B. inverse: dead DEFAULT token no seat uses, profile fine ---------------
out=$(run "$P1_TWO" "DEFAULT")
[[ -z "$(errors "$out")" ]] \
  && ok_t "B: a dead default credential no seat runs on raises no error" \
  || bad_t "B: no error expected" "got: $(errors "$out")"
[[ "$(sev "$out" claude:p1)" == "ok" ]] \
  && ok_t "B: auth/claude:p1 reads ok" || bad_t "B: claude:p1 should be ok" "got: $out"
jq -e '.[] | select(.name=="claude") | .severity=="ok" and (.message | test("no registered seat runs on the default"))' <<<"$out" >/dev/null \
  && ok_t "B: auth/claude stays in the report as ok, with the reason named" \
  || bad_t "B: auth/claude should be ok with a named reason" "got: $out"

# ---- C. mixed: a default seat plus two profiles; each pair probed once -------
MIX='{"agents":{"a":{"type":"claude","authProfile":"p1"},"b":{"type":"claude","authProfile":"p1"},
  "c":{"type":"claude","authProfile":"p2"},"d":{"type":"claude"},"e":{"type":"claude","authProfile":""}}}'
out=$(run "$MIX" "DEFAULT")
[[ "$(probes)" == "claude:DEFAULT claude:p1 claude:p2" ]] \
  && ok_t "C: 5 seats on 3 credentials cost 3 probes" \
  || bad_t "C: expected one probe per distinct pair" "got: $(probes)"
[[ "$(errors "$out")" == "claude" ]] \
  && ok_t "C: a dead default that seats d,e run on keeps the hard error" \
  || bad_t "C: default in use must be an error" "got: $(errors "$out")"

# ---- D. unreadable registry keeps the hard error on the default path ---------
out=$(run "UNREADABLE" "DEFAULT")
[[ "$(errors "$out")" == "claude" && "$(probes)" == "claude:DEFAULT" ]] \
  && ok_t "D: an unreadable registry is not health — default probed, stale is an error" \
  || bad_t "D: unreadable registry must keep the default error" "errors=$(errors "$out") probes=$(probes)"

# ---- E. DIVE-4342 still holds: no seat on the type at all --------------------
out=$(run '{"agents":{}}' "DEFAULT")
[[ "$(sev "$out" claude)" == "warn" && -z "$(errors "$out")" ]] \
  && ok_t "E: a stale credential on a harness no seat runs on is a warn, not an error" \
  || bad_t "E: unused harness should warn" "got: $out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
