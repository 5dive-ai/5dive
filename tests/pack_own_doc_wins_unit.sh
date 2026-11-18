#!/usr/bin/env bash
# DIVE-8723 — a pack that carries its OWN CLAUDE.md is installed from that text,
# persona.yaml or not; persona.yaml renders the doc only for a pack with none.
# Before, any persona.yaml won: a partner pack (CLAUDE.md + persona.yaml + skills)
# imported as a persona render, and every rule its CLAUDE.md kept was gone.
# And an export carries only the agent's own section: the seat's CLI blocks are
# cut off (on export, and on import for packs exported whole), so a re-import
# does not install them twice.
# Drives the real helpers and the real pack-sync identity render; cmd_import and
# cmd_export are graded by wiring (they create seats), in their order.
# TIER: core
# Run: bash tests/pack_own_doc_wins_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-own-doc.XXXXXX)"

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

PACK_TEXT='# Vera — Internal Auditor

## Talking to the person
Never name the model or the provider.

## Always
Ask yes before you send anything.'

mk_stage() { # <dir> [doc]: a partner-shaped pack (manifest + persona.yaml [+ CLAUDE.md])
  local s="$1"; rm -rf "$s"; mkdir -p "$s"
  printf '{"packFormat":1,"agentName":"vera","includes":{"memory":false,"persona":true},"config":{"type":"claude"},"skills":[]}\n' >"$s/manifest.json"
  cat >"$s/persona.yaml" <<'EOF'
openagent: "0.1"
id: vera
name: Vera
role: an internal auditor
behavior: Checks every number twice.
voice:
  written:
    rules: [Short sentences.]
EOF
  [[ $# -ge 2 ]] && printf '%s\n' "$2" >"$s/CLAUDE.md"
  return 0
}

echo '== the pack has its own CLAUDE.md =='
S="$TMP/s"; mk_stage "$S" "$PACK_TEXT"
_pack_has_own_doc "$S" && ok_t 'a non-empty CLAUDE.md is the pack'"'"'s own' || bad_t 'own doc detected'
eq_t 'disclosure: rendersSystemPrompt=false beside a persona.yaml' 'false' "$(_pack_disclosure_json "$S" 2>/dev/null | jq -r .rendersSystemPrompt)"
printf ' \n\n' >"$S/CLAUDE.md"
_pack_has_own_doc "$S" && bad_t 'a blank CLAUDE.md is not a doc' || ok_t 'a blank CLAUDE.md is not a doc'
rm -f "$S/CLAUDE.md"
eq_t 'disclosure control: persona.yaml and no CLAUDE.md renders' 'true' "$(_pack_disclosure_json "$S" 2>/dev/null | jq -r .rendersSystemPrompt)"

echo '== pack-sync identity render (the same steps as cmd_import) =='
mk_stage "$S" "$PACK_TEXT"
_pack_sync_render_identity "$S" vera claude; eq_t 'rc 0' 0 $?
D=$(cat "$S/CLAUDE.md")
[[ "$D" == "$PACK_TEXT"* ]] && ok_t 'the doc starts with the pack text, byte for byte' || bad_t 'pack text first' "$(head -3 <<<"$D")"
grep -qxF '## Your card' "$S/CLAUDE.md" && ok_t 'then the card section' || bad_t 'card section appended'
grep -qF 'Never name the model or the provider.' "$S/CLAUDE.md" && ok_t 'the brand rule survives' || bad_t 'brand rule kept'
grep -qxF '## How you write' "$S/CLAUDE.md" && bad_t 'no persona render' "$(head -5 "$S/CLAUDE.md")" || ok_t 'no persona render in its place'
mk_stage "$S"
_pack_sync_render_identity "$S" vera claude
grep -qF 'an internal auditor' "$S/CLAUDE.md" && ok_t 'control: no CLAUDE.md -> rendered from persona.yaml' || bad_t 'render control' "$(cat "$S/CLAUDE.md" 2>&1 | head -3)"

echo '== the seat'"'"'s own blocks are cut =='
F="$TMP/doc.md"
SEAT_TAIL='# Telegram-paired agent

The user reads Telegram.

# Working comms (chat / Telegram / team)

Reply every turn.'
printf '%s\n\n## Your card\nYour card is ~/.claude/persona.yaml.\n\n%s\n' "$PACK_TEXT" "$SEAT_TAIL" >"$F"
_pack_cut_seat_tail "$F"; eq_t 'rc 0' 0 $?
eq_t 'whole installed file -> the section only' "$(printf '%s\n\n## Your card\nYour card is ~/.claude/persona.yaml.' "$PACK_TEXT")" "$(cat "$F")"
[[ "$(tail -c1 "$F" | od -An -c | tr -d ' ')" == '\n' ]] && ok_t 'ends in one newline' || bad_t 'trailing newline'
printf '%s\n' "$SEAT_TAIL" >"$F"
_pack_cut_seat_tail "$F"
[[ -e "$F" ]] && bad_t 'a file that is only seat blocks is removed' "$(cat "$F")" || ok_t 'a file that is only seat blocks is removed'
printf '%s\n' "$PACK_TEXT" >"$F"
_pack_cut_seat_tail "$F"; eq_t 'no marker: untouched' "$PACK_TEXT" "$(cat "$F")"
printf 'Intro line\n# Telegram-paired agent is mid-paragraph here\nmore\n' >"$F"
_pack_cut_seat_tail "$F"; eq_t 'a marker that does not open a paragraph: untouched' $'Intro line\n# Telegram-paired agent is mid-paragraph here\nmore' "$(cat "$F")"

echo '== an old export (whole file) re-imported through the sync render =='
mk_stage "$S" "$(printf '%s\n\n%s' "$PACK_TEXT" "$SEAT_TAIL")"
_pack_sync_render_identity "$S" vera claude
grep -qF 'Telegram-paired agent' "$S/CLAUDE.md" && bad_t 'seat blocks cut before install' || ok_t 'seat blocks cut before install'
[[ "$(cat "$S/CLAUDE.md")" == "$PACK_TEXT"* ]] && ok_t '…and the pack text kept' || bad_t 'pack text kept'

echo '== wiring: cmd_import and cmd_export, in order =='
IMP=$(sed -n '/^cmd_import() {/,/^}/p' src/cmd_pack.sh)
EXP=$(sed -n '/^cmd_export() {/,/^}/p' src/cmd_pack.sh)
# shellcheck disable=SC2016
grep -qF 'if [[ -f "$stage/persona.yaml" ]] && ! _pack_has_own_doc "$stage"; then' <<<"$IMP" \
  && ok_t 'import renders from persona.yaml only without an own doc' || bad_t 'import render guard'
cut_at=$(grep -n '_pack_cut_seat_tail "\$stage/CLAUDE.md"' <<<"$IMP" | head -1 | cut -d: -f1)
ren_at=$(grep -n '_persona_render_claudemd "\$stage/persona.yaml"' <<<"$IMP" | head -1 | cut -d: -f1)
[[ -n "$cut_at" && -n "$ren_at" ]] && (( cut_at < ren_at )) \
  && ok_t 'import cuts the seat blocks before the render decision' || bad_t 'import cut order' "cut=$cut_at render=$ren_at"
cp_at=$(grep -n 'cp "\$cdir/CLAUDE.md" "\$stage/CLAUDE.md"' <<<"$EXP" | head -1 | cut -d: -f1)
ecut_at=$(grep -n '_pack_cut_seat_tail "\$stage/CLAUDE.md"' <<<"$EXP" | head -1 | cut -d: -f1)
[[ -n "$cp_at" && -n "$ecut_at" ]] && (( cp_at < ecut_at )) \
  && ok_t 'export cuts the copied doc' || bad_t 'export cut wiring' "cp=$cp_at cut=$ecut_at"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
