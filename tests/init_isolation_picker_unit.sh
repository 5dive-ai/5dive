#!/usr/bin/env bash
# DIVE init: isolation-tier picker (no root/network needed — inspects cmd_init body).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../src/cmd_init.sh
source "$ROOT/src/cmd_init.sh"
source "$ROOT/src/lib/validation.sh"
body="$(declare -f cmd_init)"

fail() { echo "FAIL: $1" >&2; exit 1; }
has()  { [[ "$body" == *"$1"* ]] || fail "$2"; }

has "Pick isolation:"                       "wizard must present an isolation picker"
has "iso_opts=(admin standard sandboxed)"   "picker must offer all three tiers"
has 'iso_default="sandboxed"'               "pi must default to sandboxed"
has 'iso_default="admin"'                   "first agent on a fresh box must default to admin"
has 'iso_default="standard"'                "non-first non-pi agents must default to standard"
has '--isolation=$isolation'                "create must forward the chosen tier"

# Every offered tier must be accepted by the create-path validator.
for t in admin standard sandboxed; do
  valid_isolation "$t" || fail "valid_isolation rejects offered tier '$t'"
done

echo "PASS: init isolation picker offers admin/standard/sandboxed with tier-correct defaults"
