#!/usr/bin/env bash
# DIVE-6241 — a bare `5dive plugin add browser` installs the browser's own repo.
#
# Round 2 of the Claude in Chrome head-to-head (marketing/reddit/2026-10-14-cic-vs-5dive-browser.md,
# finding 1): on a fresh box `plugin add browser` installed browser@5dive-plugins 1.32.0, the
# registry's hand-synced mirror, while 5dive-browser was at 1.39.0. These arms grade where a ref
# goes, with the registry and the repo install both stubbed: the install itself is graded by
# plugin_foreign_repo_add_unit.sh and plugin_bundled_install_unit.sh.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

source src/lib/error_codes.sh
source src/lib/output.sh
source src/header.sh
source src/cmd_plugin.sh
set +e -o pipefail
require_root(){ :; }

TMP="$(mktemp -d /tmp/plugin-bare-add.XXXXXX)"
export STATE_DIR="$TMP/state"
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want=[$2] got=[$3]"; }
has_t() { [[ "$3" == *"$2"* ]] && ok_t "$1" || bad_t "$1" "missing=[$2] in [$3]"; }

# The registry, as a local marketplace carrying a browser mirror (the shape of
# 5dive-plugins: plugins/browser) and voice.
REG="$TMP/registry"; mkdir -p "$REG/.claude-plugin"
for p in browser voice; do
  mkdir -p "$REG/plugins/$p/.claude-plugin"
  jq -cn --arg p "$p" '{name:$p,version:"1.32.0",description:"mirror",author:{name:"5dive"},
    fivedive:{contract:"1",capabilities:[],grants:[],trust:{publisher:"5dive",review:"official"}}}' \
    > "$REG/plugins/$p/.claude-plugin/plugin.json"
done
jq -n '{name:"5dive-plugins",owner:{name:"5dive"},plugins:[{name:"browser",source:"./plugins/browser"},{name:"voice",source:"./plugins/voice"}]}' \
  > "$REG/.claude-plugin/marketplace.json"
export FIVEDIVE_PLUGIN_REGISTRY="$REG"

# Stub the repo install: record what it was asked for, install nothing.
_plugin_add_foreign() { printf '%s|%s|%s|%s\n' "$@" > "$TMP/foreign"; }
# Stub the registry install past resolution: record the resolved key and stop.
_plugin_trust_gate() { printf '%s\n' "${6:-}" > "$TMP/registry-key"; exit 0; }

add() { rm -f "$TMP/foreign" "$TMP/registry-key"; ( cmd_plugin_add "$@" ) >"$TMP/out" 2>"$TMP/err"
        if [[ -f "$TMP/foreign" ]]; then echo "repo $(cut -d'|' -f1 "$TMP/foreign")"
        elif [[ -f "$TMP/registry-key" ]]; then echo "registry $(cat "$TMP/registry-key")"
        else echo "neither: $(cat "$TMP/err")"; fi; }

eq_t 'B1 a bare `plugin add browser` installs 5dive-ai/5dive-browser'   'repo 5dive-ai/5dive-browser' "$(add browser --yes)"
has_t 'B1b ...and says why, naming the mirror it did not take'           'browser@5dive-plugins' "$(cat "$TMP/err")"
eq_t 'B1c --official-only and --yes ride along'                          '5dive-ai/5dive-browser||1|1' "$(add browser --yes --official-only >/dev/null; cat "$TMP/foreign")"
eq_t 'B2 the qualified browser@5dive-plugins still installs the mirror' 'registry browser@5dive-plugins' "$(add browser@5dive-plugins --yes)"
eq_t 'B3 a plugin not in the list resolves as before (voice, from the registry)' 'registry voice@5dive-plugins' "$(add voice --yes)"
# A box that already runs the mirror keeps it: two copies would claim one verb.
jq -n '{"browser@5dive-plugins":{plugin:"browser",marketplace:"5dive-plugins",version:"1.32.0"}}' > "$(_plugin_installed_json)"
eq_t 'B4 with the mirror installed, a bare name stays on the mirror' 'registry browser@5dive-plugins' "$(add browser --yes)"
echo '{}' > "$(_plugin_installed_json)"
# The mutant: the list emptied, so the bare name goes back to the mirror (round 2's install).
eq_t 'B5 MUTANT (no bare-add list): `plugin add browser` installs the 1.32.0 mirror again' 'registry browser@5dive-plugins' \
  "$(_plugin_bare_add_repo() { :; }; add browser --yes)"

printf '\nplugin bare add: %d pass, %d fail\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
