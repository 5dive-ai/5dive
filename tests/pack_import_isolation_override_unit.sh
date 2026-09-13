#!/usr/bin/env bash
# DIVE-4414 — agent import accepted --isolation but silently discarded it for
# pack/marketplace imports. Grade the explicit override, the no-flag manifest
# path, invalid values, persona compatibility, and the production wiring.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d)

echo '== effective isolation =='
eq_t 'explicit admin overrides a standard pack manifest' \
  admin "$(_import_resolve_isolation standard admin 1)"
eq_t 'no flag preserves a sandboxed manifest instead of applying the standard default' \
  sandboxed "$(_import_resolve_isolation sandboxed standard 0)"
eq_t 'an explicit standard tier can override an admin manifest' \
  standard "$(_import_resolve_isolation admin standard 1)"

echo '== validation =='
if ( _import_validate_isolation bogus ) >/dev/null 2>&1; then
  bad_t 'bogus isolation is rejected before staging/create' 'validator returned success'
else
  ok_t 'bogus isolation is rejected before staging/create'
fi
if ( _import_parse_args --isolation=bogus ) >/dev/null 2>&1; then
  bad_t 'hire/import validate-only parser rejects bogus isolation' 'parser returned success'
else
  ok_t 'hire/import validate-only parser rejects bogus isolation'
fi
if ( _import_parse_args --isolation=admin ) >/dev/null 2>&1; then
  ok_t 'admin is accepted by the validate-only parser'
else
  bad_t 'admin was rejected by the validate-only parser' ''
fi

echo '== real cmd_import seam =='
# Drive cmd_import itself through manifest resolution and as far as cmd_create,
# but replace every mutating boundary. The recorder is a file because cmd_create
# runs in a subshell in production. Returning non-zero stops the import exactly
# after the argv under test, before it can touch an agent home.
printf '%s\n' '{"packFormat":1,"agentName":"fixture","config":{"type":"claude","isolation":"sandboxed"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/fixture.tar.gz"
export DIVE4414_FIXTURE="$TMP/manifest.json"
require_root() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE4414_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
is_known_type() { [[ "$1" == claude ]]; }
step() { :; }
cmd_create() { printf '%s\n' "$@" > "$DIVE4414_REC"; return 1; }

export DIVE4414_REC="$TMP/admin.argv"
( cmd_import "$TMP/fixture.tar.gz" --as=fixture-admin --isolation=admin ) >/dev/null 2>&1
eq_t 'fixture pack plus explicit admin reaches cmd_create as --isolation=admin' \
  '--isolation=admin' "$(grep -m1 '^--isolation=' "$DIVE4414_REC")"

export DIVE4414_REC="$TMP/manifest.argv"
( cmd_import "$TMP/fixture.tar.gz" --as=fixture-manifest ) >/dev/null 2>&1
eq_t 'fixture pack without a flag reaches cmd_create with its sandboxed manifest tier' \
  '--isolation=sandboxed' "$(grep -m1 '^--isolation=' "$DIVE4414_REC")"

export DIVE4414_REC="$TMP/bogus.argv"
rm -f "$DIVE4414_REC"
( cmd_import "$TMP/fixture.tar.gz" --as=fixture-bogus --isolation=bogus ) >/dev/null 2>&1
[[ ! -e "$DIVE4414_REC" ]] \
  && ok_t 'bogus isolation fails before cmd_create is reached' \
  || bad_t 'bogus isolation reached cmd_create' "$(tr '\n' ' ' < "$DIVE4414_REC")"

echo '== production wiring =='
SRC="$ROOT/src/cmd_pack.sh"
grep -q 'p_iso="${1#--isolation=}"; p_iso_set=1' "$SRC" \
  && ok_t 'the real parser records that --isolation was explicit' \
  || bad_t 'the explicit-bit wiring is absent' ''
grep -q 'isolation=$(\_import_resolve_isolation "$isolation" "$p_iso" "$p_iso_set")' "$SRC" \
  && ok_t 'the manifest-to-create path calls the graded resolver' \
  || bad_t 'cmd_import does not apply the graded resolver' ''
grep -q '_persona_to_pack "$from_persona" "$synth_type" "$p_iso"' "$SRC" \
  && ok_t 'from-persona still receives the same p_iso value' \
  || bad_t 'from-persona isolation path changed' ''
grep -q -- '\[--isolation=admin|standard|sandboxed\]' "$SRC" \
  && ok_t 'agent import usage documents --isolation and its values' \
  || bad_t 'agent import usage omits --isolation' ''

echo
printf 'DIVE-4414 pack import isolation override: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
