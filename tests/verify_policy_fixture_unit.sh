#!/usr/bin/env bash
# TIER: core — pure fixture helper test; no root, network, or live state.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/verify-policy-fixture.XXXXXX)"
P=0; F=0
ok_t() { P=$((P+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { F=$((F+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

STATE_DIR="$TMP/state"
fixture_box_verify_policy always
[[ "$BOX_CONFIG" == "$STATE_DIR/box.json" && "$(jq -r .verify "$BOX_CONFIG")" == always ]] \
  && ok_t 'always policy is explicit in the disposable box fixture' \
  || bad_t 'always fixture' "BOX_CONFIG=${BOX_CONFIG:-unset} body=$(cat "${BOX_CONFIG:-/dev/null}" 2>/dev/null)"

. src/lib/verify_policy.sh
[[ "$(box_verify_policy)" == always ]] \
  && ok_t 'production resolver reads the explicit always fixture' \
  || bad_t 'resolver did not read fixture' "got=$(box_verify_policy)"

fixture_box_verify_policy delivered-only
[[ "$(box_verify_policy)" == delivered-only ]] \
  && ok_t 'helper can select delivered-only without changing production defaults' \
  || bad_t 'delivered-only fixture' "got=$(box_verify_policy)"

if ( STATE_DIR=/var/lib/5dive; fixture_box_verify_policy always ) 2>"$TMP/refused"; then
  bad_t 'live state is refused' 'helper accepted /var/lib/5dive'
else
  ok_t 'helper refuses the live box state directory'
fi

if ( STATE_DIR="$TMP/invalid"; fixture_box_verify_policy sometimes ) 2>/dev/null; then
  bad_t 'invalid policy is refused' 'helper accepted sometimes'
else
  ok_t 'helper refuses an invalid policy'
fi

echo '-----'
printf 'verify_policy_fixture_unit: %d passed, %d failed\n' "$P" "$F"
[[ $F -eq 0 ]]
