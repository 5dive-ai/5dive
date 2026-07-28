#!/usr/bin/env bash
# DIVE init: isolation-tier picker (no root/network needed — inspects cmd_init body).
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
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
