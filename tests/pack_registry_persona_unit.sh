#!/usr/bin/env bash
# DIVE-5162 — a registry pack carries its character's persona, so the imported
# agent speaks in its own voice (the voice engine reads voice.audio from
# ~/.claude/persona.yaml). It rides as registry-persona.yaml, NOT persona.yaml:
# that name makes cmd_import re-render the agent's CLAUDE.md from the persona,
# and a registry agent keeps the pack's own CLAUDE.md exactly as before.
# Drives the real _marketplace_fetch_pack with a stubbed registry, and the real
# install helper cmd_import calls.
# TIER: core
# Run: bash tests/pack_registry_persona_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-registry-persona.XXXXXX)"

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
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

# The registry: a directory served through stubbed fetch seams.
REG="$TMP/reg"
_marketplace_base() { printf 'https://reg.example'; }
_marketplace_index() { printf '{"packs":[{"slug":"maya","path":"packs/maya"}]}'; }
_serve() { local f="$REG/${1#https://reg.example/}"; [[ -f "$f" ]] && cp "$f" "$2"; }
_marketplace_get_required() { _serve "$1" "$2" || return 1; }
curl() {
  local out="" url="" prev="" arg
  for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    [[ "$arg" == https://* ]] && url="$arg"
    prev="$arg"
  done
  _serve "$url" "$out" || return 22
}

PERSONA='openagent: "0.2"
id: maya
name: Maya
voice:
  audio:
    base: Sulafat
    style: warm, unhurried'
mkdir -p "$REG/packs/maya"
printf '{"packFormat":1,"agentName":"maya"}' > "$REG/packs/maya/manifest.json"
printf 'You are Maya. Hand-written, richer than any render.\n' > "$REG/packs/maya/CLAUDE.md"

fetch_list() { # -> sorted member list of the fetched pack; extracts into $TMP/x
  local p; p=$(_marketplace_fetch_pack maya) || { echo "FETCH-RC=$?"; return; }
  rm -rf "$TMP/x"; mkdir -p "$TMP/x"; tar -xzf "$p" -C "$TMP/x"
  tar -tzf "$p" | sed 's#^\./##' | grep -v '^$' | sort | tr '\n' ' '
  rm -f "$p"
}

echo '== fetch =='
printf '%s\n' "$PERSONA" > "$REG/packs/maya/persona.yaml"
L=$(fetch_list)
[[ " $L " == *" registry-persona.yaml "* ]] && ok_t 'the persona is fetched as registry-persona.yaml' || bad_t 'the persona is fetched as registry-persona.yaml' "$L"
[[ " $L " != *" persona.yaml "* ]] && ok_t 'never as persona.yaml (that name re-renders CLAUDE.md on import)' || bad_t 'never as persona.yaml' "$L"
eq_t 'byte for byte' "$PERSONA" "$(cat "$TMP/x/registry-persona.yaml" 2>/dev/null)"
eq_t "the pack's own CLAUDE.md is untouched" 'You are Maya. Hand-written, richer than any render.' "$(cat "$TMP/x/CLAUDE.md")"

rm -f "$REG/packs/maya/persona.yaml"
L=$(fetch_list)
[[ " $L " != *"persona"* ]] && ok_t 'a pack with no persona fetches exactly as before' || bad_t 'a pack with no persona fetches exactly as before' "$L"

printf '%s\next:\n  x-5dive:\n    signing_key: AAAA\n' "$PERSONA" > "$REG/packs/maya/persona.yaml"
L=$(fetch_list)
[[ " $L " != *"persona"* ]] && ok_t 'a persona naming a signing key is dropped at fetch' || bad_t 'a persona naming a signing key is dropped at fetch' "$L"

echo '== disclosure: the import does NOT re-render from it =='
printf '%s\n' "$PERSONA" > "$REG/packs/maya/persona.yaml"
fetch_list >/dev/null
eq_t 'inspect/import disclosure: rendersSystemPrompt=false' 'false' "$(_pack_disclosure_json "$TMP/x" 2>/dev/null | jq -r '.rendersSystemPrompt')"
cp "$TMP/x/registry-persona.yaml" "$TMP/x/persona.yaml"
eq_t '…control: the same file as persona.yaml WOULD re-render' 'true' "$(_pack_disclosure_json "$TMP/x" 2>/dev/null | jq -r '.rendersSystemPrompt')"

echo '== install =='
ME=$(id -un); MG=$(id -gn)
S="$TMP/stage"; C="$TMP/cdir"; mkdir -p "$S" "$C"
printf '%s\n' "$PERSONA" > "$S/registry-persona.yaml"
_pack_install_registry_persona "$S" "$C" "$ME" "$MG"; eq_t 'installed: rc 0' 0 $?
eq_t 'as <cdir>/persona.yaml, the path the voice engine reads' "$PERSONA" "$(cat "$C/persona.yaml" 2>/dev/null)"
eq_t 'mode 644' 644 "$(stat -c %a "$C/persona.yaml" 2>/dev/null)"

rm -f "$C/persona.yaml"; printf 'id: own\n' > "$S/persona.yaml"
_pack_install_registry_persona "$S" "$C" "$ME" "$MG"; eq_t "a pack's own persona.yaml wins (cmd_import installs that one): rc 1" 1 $?
[[ ! -e "$C/persona.yaml" ]] && ok_t '…and nothing is written here' || bad_t '…and nothing is written here' "$(cat "$C/persona.yaml")"

rm -f "$S/persona.yaml" "$S/registry-persona.yaml"
_pack_install_registry_persona "$S" "$C" "$ME" "$MG"; eq_t 'no persona in the pack: rc 1, nothing written' "1:no" "$?:$([[ -e "$C/persona.yaml" ]] && echo yes || echo no)"

printf 'id: x\nsigning_key: AAAA\n' > "$S/registry-persona.yaml"
_pack_install_registry_persona "$S" "$C" "$ME" "$MG"; eq_t 'a signing key is refused at install too: rc 2, nothing written' "2:no" "$?:$([[ -e "$C/persona.yaml" ]] && echo yes || echo no)"

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
