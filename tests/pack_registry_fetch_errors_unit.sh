#!/usr/bin/env bash
# DIVE-2600 — a registry transport failure must never be reported as evidence
# that a by-slug pack does not exist. This harness drives the real resolver with
# deterministic index/curl stubs and grades every classified outcome plus both
# consumers (inspect and import).
# TIER: core
# Run: bash tests/pack_registry_fetch_errors_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-registry-errors.XXXXXX)"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_pack.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check_rc() {
  local want="$1" label="$2" got
  shift 2
  "$@" >/dev/null 2>&1; got=$?
  if [[ "$got" -eq "$want" ]]; then
    ok_t "$label"
  else
    bad_t "$label" "want=$want got=$got"
  fi
}

# 0. Drive the real HTTP seam once: curl rc and HTTP status are separate signals.
CURL_MODE="ok"
curl() {
  local out="" arg prev=""
  for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
  done
  case "$CURL_MODE" in
    ok)        printf '%s' '{"packs":[]}' >"$out"; printf '200' ;;
    http404)   printf '%s' 'not found' >"$out"; printf '404' ;;
    http503)   printf '%s' 'unavailable' >"$out"; printf '503' ;;
    timeout)   return 28 ;;
    transport) return 7 ;;
  esac
}
OUT=$(_marketplace_index); RC=$?
[[ $RC -eq 0 && "$OUT" == '{"packs":[]}' ]] \
  && ok_t "HTTP 200 index returns its body" \
  || bad_t "HTTP 200 index body" "rc=$RC out=$OUT"
CURL_MODE=http404;   check_rc 1 "HTTP 404 index has its own status" _marketplace_index
CURL_MODE=http503;   check_rc 2 "other HTTP non-2xx index has its own status" _marketplace_index
CURL_MODE=timeout;   check_rc 3 "curl timeout remains distinguishable" _marketplace_index
CURL_MODE=transport; check_rc 4 "curl transport failure remains distinguishable" _marketplace_index

# 1. The index itself did not arrive: each observable failure class remains
# distinct, and none is turned into evidence that the slug is absent.
_marketplace_index() { return 3; }
check_rc 4 "index timeout is classified as registry timeout" \
  _marketplace_fetch_pack atlas
_marketplace_index() { return 2; }
check_rc 3 "index HTTP non-2xx is classified separately from timeout" \
  _marketplace_fetch_pack atlas
_marketplace_index() { return 1; }
check_rc 2 "index HTTP 404 is classified separately from missing slug" \
  _marketplace_fetch_pack atlas
_marketplace_index() { return 4; }
check_rc 5 "index transport failure preserves uncertainty" \
  _marketplace_fetch_pack atlas

# 2. Only a successfully fetched, structurally valid index can prove absence.
_marketplace_index() { printf '%s' '{"packs":[]}'; }
check_rc 1 "valid index without the slug is classified as not found" \
  _marketplace_fetch_pack atlas

# 3. A response body without the registry's packs array is malformed, not proof
# of absence (e.g. a proxy error document that still arrived with curl rc 0).
_marketplace_index() { printf '%s' '{"message":"upstream unavailable"}'; }
check_rc 6 "malformed index is not classified as missing slug" \
  _marketplace_fetch_pack atlas

# 4. The slug can be present while its required object fetch fails. That is an
# inconsistent/unavailable registry object, not "no pack".
_marketplace_index() {
  printf '%s' '{"packs":[{"slug":"atlas","path":"packs/atlas"}]}'
}
curl() { printf '404'; return 0; }
check_rc 7 "listed slug with HTTP 404 manifest is an inconsistent registry" \
  _marketplace_fetch_pack atlas
curl() { return 28; }
check_rc 9 "listed slug with manifest timeout stays distinct from absence" \
  _marketplace_fetch_pack atlas
curl() { return 7; }
check_rc 10 "listed slug with manifest transport failure preserves uncertainty" \
  _marketplace_fetch_pack atlas

# 5. Non-vacuity: the same seam can resolve a pack. The curl stub writes the
# required manifest; optional registry files may be absent without failing.
curl() {
  local out="" arg prev="" write_status=0
  for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$prev" == "-w" ]] && write_status=1
    prev="$arg"
  done
  (( write_status )) || return 22
  [[ "$out" == */manifest.json ]] || return 22
  printf '%s' '{"skills":[],"includes":{"memory":false}}' >"$out"
  printf '200'
}
OUT=$(_marketplace_fetch_pack atlas); RC=$?
if [[ $RC -eq 0 && -f "$OUT" ]] && tar -tzf "$OUT" | grep -q './manifest.json'; then
  ok_t "valid indexed pack resolves to a readable tarball"
else
  bad_t "successful resolution control" "rc=$RC out=$OUT"
fi
rm -f "$OUT"

# 6. Creator-facing errors name the measured category. Capture fail() in a
# subshell because it exits by contract.
message_for() {
  (_marketplace_fetch_pack_fail atlas "$1") 2>&1
}
OUT=$(message_for 1); RC=$?
if [[ $RC -eq "$E_NOT_FOUND" && "$OUT" == *"no pack 'atlas' in the registry index"* ]]; then
  ok_t "absence error says the slug is absent from a fetched index"
else
  bad_t "absence error wording" "rc=$RC out=$OUT"
fi

for classified in \
  '2|registry index returned HTTP 404' \
  '3|registry index returned a non-2xx HTTP response' \
  '4|timed out fetching the character-pack registry index' \
  '5|transport failure fetching the character-pack registry index' \
  '6|registry index is malformed' \
  '7|is listed in the registry index, but its manifest returned HTTP 404' \
  '8|is listed in the registry index, but its manifest returned a non-2xx HTTP response' \
  '9|is listed in the registry index, but its manifest fetch timed out' \
  '10|is listed in the registry index, but its manifest had a transport failure'
do
  RC_KIND="${classified%%|*}"; WANT="${classified#*|}"
  OUT=$(message_for "$RC_KIND"); RC=$?
  WANT_RC="$E_GENERIC"
  [[ "$RC_KIND" == 2 || "$RC_KIND" == 7 ]] && WANT_RC="$E_NOT_FOUND"
  if [[ $RC -eq "$WANT_RC" && "$OUT" == *"$WANT"* && "$OUT" != *"no pack 'atlas'"* ]]; then
    ok_t "fetch class $RC_KIND reports uncertainty without claiming absence"
  else
    bad_t "fetch class $RC_KIND message" "rc=$RC out=$OUT"
  fi
done

# 7. Wiring: both by-slug consumers call the shared classified renderer. These
# assertions pin the two real call sites so a correct but orphan helper is red.
INSPECT_ARM=$(sed -n '/^cmd_inspect()/,/^}/p' src/cmd_pack.sh)
IMPORT_ARM=$(sed -n '/^cmd_import()/,/^}/p' src/cmd_pack.sh)
if [[ "$INSPECT_ARM" == *'_marketplace_fetch_pack_fail "$pack" "$fetch_rc"'* ]]; then
  ok_t "agent inspect routes resolver failures through the classifier"
else
  bad_t "inspect classifier wiring"
fi
if [[ "$IMPORT_ARM" == *'_marketplace_fetch_pack_fail "$pack" "$fetch_rc"'* ]]; then
  ok_t "agent import routes resolver failures through the classifier"
else
  bad_t "import classifier wiring"
fi

echo
printf 'DIVE-2600 registry fetch classification: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
