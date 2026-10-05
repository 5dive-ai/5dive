#!/usr/bin/env bash
# DIVE-5559: an agent exported to agent.tar.gz and imported back under ANY name
# is still the same marketplace persona. The export used to carry no record of
# which pack the seat was, so the import recorded slug "" and the Mini App fell
# back to matching the new seat's NAME against pack slugs ("agent" matches none:
# role gone, row says "Working"). Grades, on a fixture registry (no root, no net):
#   1-4  _pack_persona_slug_of reads the seat's registry .pack.slug, empty if none
#        or not a plain slug;
#   5-8  _pack_manifest_persona_slug reads what the export wrote, dropping
#        anything but a plain slug (pack bytes are third-party);
#   9    the export's manifest jq writes pack.slug, and only when there is one;
#   10   a file import records {source:"file", slug} -> `agent list` reports the
#        persona, and pack-sync still SKIPS it (a file pack cannot be re-fetched).
# Run: bash tests/pack_persona_slug_travels_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/pack-persona-slug.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh lib/agent_setup.sh cmd_skill.sh cmd_pack.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home" REGISTRY="$TMP/agents.json"
chown() { :; }
fail() { printf 'FAIL-CALLED %s\n' "$*" >&2; return 1; }

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 (want [$3] got [$2])"; }

jq -n '{agents:{
  olivia:{type:"claude", pack:{source:"marketplace", slug:"olivia"}},
  hand:{type:"claude"},
  odd:{type:"claude", pack:{source:"marketplace", slug:"../x"}},
  agent:{type:"claude"}}}' >"$REGISTRY"

echo "== export side: the seat's persona =="
is "1 marketplace seat -> its slug" "$(_pack_persona_slug_of olivia)" olivia
is "2 hand-made seat -> empty" "$(_pack_persona_slug_of hand)" ""
is "3 not a plain slug -> empty" "$(_pack_persona_slug_of odd)" ""
is "4 no such seat -> empty" "$(_pack_persona_slug_of nosuch)" ""

echo "== import side: what the manifest says =="
m() { printf '%s' "$1" >"$TMP/m.json"; _pack_manifest_persona_slug "$TMP/m.json"; }
is "5 recorded slug read" "$(m '{"packFormat":1,"pack":{"slug":"olivia"}}')" olivia
is "6 old export (no pack) -> empty" "$(m '{"packFormat":1}')" ""
is "7 forged path -> empty" "$(m '{"pack":{"slug":"../../etc"}}')" ""
is "8 wrong shape -> empty, no error" "$(m '{"pack":"olivia"}')" ""

echo "== 9. the export's manifest carries it only when there is one =="
# The exact filter tail cmd_export appends, lifted from the shipped source so a
# rename there fails here.
tail_expr=$(grep -o '+ (if \$packslug == "" then {} else {pack: {slug: \$packslug}} end)' src/cmd_pack.sh)
[[ -n "$tail_expr" ]] && ok_ "9a cmd_export appends pack.slug to the manifest" || bad_ "9a cmd_export appends pack.slug to the manifest"
is "9b with a slug" "$(jq -nc --arg packslug olivia "{packFormat:1} $tail_expr")" '{"packFormat":1,"pack":{"slug":"olivia"}}'
is "9c without one: no key at all" "$(jq -nc --arg packslug "" "{packFormat:1} $tail_expr")" '{"packFormat":1}'
grep -q 'pk_slug=$(_pack_manifest_persona_slug "$stage/manifest.json")' src/cmd_pack.sh \
  && ok_ "9d cmd_import's file branch reads it" || bad_ "9d cmd_import's file branch reads it"

echo "== 10. a file import is that persona, and stays un-synced =="
_pack_record_write agent file "$(m '{"pack":{"slug":"olivia"}}')" '{}' '{}'
is "10a record" "$(jq -c '.agents.agent.pack | {source, slug}' "$REGISTRY")" '{"source":"file","slug":"olivia"}'
out=$(_pack_sync_one agent "" 1 0); rc=$?
is "10b pack-sync rc 0" "$rc" 0
is "10c pack-sync skips a file pack" "$(jq -r .status <<<"$out")" skipped

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
