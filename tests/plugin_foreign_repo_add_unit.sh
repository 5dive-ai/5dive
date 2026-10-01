#!/usr/bin/env bash
# DIVE-4290 — one-step install from a GitHub marketplace repository.
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

TMP="$(mktemp -d /tmp/plugin-foreign.XXXXXX)"
export STATE_DIR="$TMP/state"
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want=[$2] got=[$3]"; }
has_t() { [[ "$3" == *"$2"* ]] && ok_t "$1" || bad_t "$1" "missing=[$2] in [$3]"; }

OUT=""; ERR=""; RC=0
run(){
  local o="$TMP/out" e="$TMP/err"
  ( "$@" ) >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
}

mk_repo(){ # <repo-dir> <plugin>...
  local repo="$1"; shift
  mkdir -p "$repo/.claude-plugin"
  local plugins='[]' p
  for p in "$@"; do
    mkdir -p "$repo/$p/.claude-plugin"
    jq -cn --arg p "$p" '{name:$p,version:"1.0.0",description:"fixture",
      author:{name:"acme"},fivedive:{contract:"1",capabilities:[],grants:[],
      trust:{publisher:"acme",did:"did:key:fixture",review:"official"}}}' \
      > "$repo/$p/.claude-plugin/plugin.json"
    plugins=$(jq -c --arg p "$p" '. + [{name:$p,description:"fixture",source:("./"+$p)}]' <<<"$plugins")
  done
  jq -n --argjson p "$plugins" '{name:"fixture",owner:{name:"acme"},plugins:$p}' \
    > "$repo/.claude-plugin/marketplace.json"
}

REMOTE="$TMP/remotes"
mk_repo "$REMOTE/weather" forecast
mk_repo "$REMOTE/tools" alpha beta
mk_repo "$REMOTE/suite" suite extra
mk_repo "$REMOTE/urlonly" urlplug
mk_repo "$REMOTE/tools2" gamma delta
# DIVE-5308: two repositories whose plugins declare the same verb.
mk_verb_repo(){ # <repo-dir> <plugin> <verb>
  local repo="$1" p="$2" v="$3"
  mk_repo "$repo" "$p"
  jq --arg v "$v" '.fivedive.capabilities=["verb"] | .fivedive.verbs=[{name:$v,summary:"fixture verb"}]' \
    "$repo/$p/.claude-plugin/plugin.json" > "$repo/x" && mv "$repo/x" "$repo/$p/.claude-plugin/plugin.json"
  mkdir -p "$repo/$p/bin"; printf '#!/bin/sh\n' > "$repo/$p/bin/$v"; chmod +x "$repo/$p/bin/$v"
}
mk_verb_repo "$REMOTE/choir" choir sing
mk_verb_repo "$REMOTE/rival" rival sing
mk_verb_repo "$REMOTE/rival2" rival2 sing
mkdir -p "$REMOTE/broken/plugin/.claude-plugin"
printf '{"name":"plugin","version":"1.0.0"}\n' > "$REMOTE/broken/plugin/.claude-plugin/plugin.json"

# Keep the built-in registry's automatic first-use registration hermetic.
REGISTRY="$TMP/registry"; mk_repo "$REGISTRY" registry-control
export FIVEDIVE_PLUGIN_REGISTRY="$REGISTRY"

CLONES="$TMP/clones"; : > "$CLONES"
git(){
  if [[ "${1:-}" == clone ]]; then
    local url="${*: -2:1}" dest="${*: -1}" src=""
    # DIVE-4955: the fixtures are published under 5dive-ai, because `official`
    # is now decided by the owner a repository was fetched from and these arms
    # grade the one-step SYNTAX, which has to get past the trust gate to be
    # observed. A third-party owner is refused; plugin_official_from_source_unit.sh
    # grades that half.
    case "$url" in
      https://github.com/5dive-ai/weather.git) src="$REMOTE/weather" ;;
      https://github.com/5dive-ai/tools.git)   src="$REMOTE/tools" ;;
      https://github.com/5dive-ai/suite.git)   src="$REMOTE/suite" ;;
      https://github.com/5dive-ai/urlonly.git|https://github.com/5dive-ai/urlonly) src="$REMOTE/urlonly" ;;
      https://github.com/5dive-ai/broken.git)  src="$REMOTE/broken" ;;
      https://github.com/5dive-ai/tools2.git)  src="$REMOTE/tools2" ;;
      https://github.com/5dive-ai/choir.git)   src="$REMOTE/choir" ;;
      https://github.com/5dive-ai/rival.git)   src="$REMOTE/rival" ;;
      https://github.com/5dive-ai/rival2.git)  src="$REMOTE/rival2" ;;
      *) return 91 ;;
    esac
    printf '%s -> %s\n' "$url" "$dest" >> "$CLONES"
    cp -a "$src" "$dest"
    return
  fi
  command git "$@"
}

# Record the canonical disclosure call in a file because run() uses a subshell.
CONSENTS="$TMP/consents"; : > "$CONSENTS"
_plugin_consent(){ printf '%s|%s|%s\n' "$1" "$2" "$5" >> "$CONSENTS"; }

run cmd_plugin_add 5dive-ai/weather --yes
eq_t 'single-plugin repository installs in one command' 0 "$RC"
eq_t 'single-plugin install records its marketplace' weather \
  "$(jq -r '.["forecast@weather"].marketplace // ""' "$(_plugin_installed_json)")"
has_t 'foreign install traverses the canonical DIVE-995 disclosure call' 'forecast|1.0.0|' "$(cat "$CONSENTS")"

clone_before=$(wc -l < "$CLONES")
run cmd_plugin_add 5dive-ai/weather --yes
eq_t 'already-registered repository remains installable' 0 "$RC"
eq_t 'already-registered repository is not cloned or duplicated' "$clone_before" "$(wc -l < "$CLONES")"
eq_t 'marketplace registry contains one weather key' 1 \
  "$(jq '[to_entries[] | select(.key=="weather")] | length' "$(_plugin_mkt_json)")"

run cmd_plugin_add 5dive-ai/tools/beta --yes
eq_t 'owner/repo/plugin selects the named plugin' 0 "$RC"
eq_t 'explicit plugin is installed from repo marketplace' true \
  "$(jq 'has("beta@tools")' "$(_plugin_installed_json)")"

run cmd_plugin_add 5dive-ai/tools --yes
eq_t 'multi-plugin repository without matching repo name refuses' "$E_USAGE" "$RC"
has_t 'multi-plugin refusal lists available names' 'alpha beta' "$ERR"
has_t 'multi-plugin refusal gives the explicit form' '<owner>/<repo>/<plugin>' "$ERR"

run cmd_plugin_add 5dive-ai/suite --yes
eq_t 'multi-plugin repository selects plugin named after repo' 0 "$RC"
eq_t 'repo-named plugin was installed' true "$(jq 'has("suite@suite")' "$(_plugin_installed_json)")"

run cmd_plugin_add 5dive-ai/broken --yes
eq_t 'repository without marketplace index refuses' "$E_VALIDATION" "$RC"
has_t 'missing-index error names the required file' '.claude-plugin/marketplace.json' "$ERR"
eq_t 'missing-index refusal leaves no registry entry' false "$(jq 'has("broken")' "$(_plugin_mkt_json)")"
eq_t 'missing-index refusal removes the staged clone' no "$([[ -e "$(_plugin_mkt_dir)/broken" ]] && echo yes || echo no)"

run cmd_plugin_add https://github.com/5dive-ai/urlonly --yes
eq_t 'GitHub URL form installs in one command' 0 "$RC"
eq_t 'URL form derives repository marketplace name' true "$(jq 'has("urlplug@urlonly")' "$(_plugin_installed_json)")"

run cmd_plugin_add 5dive-ai/weather --as=wx --yes
eq_t '--as is honoured on repository source' 0 "$RC"
eq_t '--as controls installed marketplace key' true "$(jq 'has("forecast@wx")' "$(_plugin_installed_json)")"

json_add(){ JSON_MODE=1 cmd_plugin_add "$@"; }
run json_add 5dive-ai/weather --as=json-weather --yes
eq_t 'JSON mode succeeds for one-step repository install' 0 "$RC"
eq_t 'JSON mode emits one response envelope' 1 "$(printf '%s\n' "$OUT" | grep -c .)"
jq -e '.ok == true and .data.plugin == "forecast" and .data.marketplace == "json-weather"' \
  <<<"$OUT" >/dev/null \
  && ok_t 'JSON response identifies the installed plugin and marketplace' \
  || bad_t 'JSON response identifies the installed plugin and marketplace' "$OUT"

# Old two-step form and the literal aliases remain live.
run cmd_plugin_marketplace add 5dive-ai/weather --as=legacy
eq_t 'existing marketplace-add step still works' 0 "$RC"
run cmd_plugin_add forecast@legacy --yes
eq_t 'existing plugin@marketplace install still works' 0 "$RC"
run cmd_plugin install 5dive-ai/weather --yes
eq_t 'plugin install aliases canonical add' 0 "$RC"
grep -qE '^[[:space:]]*plugin\|plugins\)' src/main.sh \
  && ok_t 'top-level plugins aliases plugin' \
  || bad_t 'top-level plugins alias' 'main dispatch lacks plugin|plugins)'

# ---- DIVE-5308: a refused add leaves the marketplace list as it found it -----
# Before the fix `_plugin_add_foreign` registered the repository's marketplace
# and then refused, so every refused add stacked one more marketplace with
# nothing installed from it. The verdict is the list itself, read before and
# after, not the absence of one key.
mkt_list(){ jq -c 'keys' "$(_plugin_mkt_json)"; }
run cmd_plugin_add 5dive-ai/choir --yes
eq_t 'setup: the first verb-claiming plugin installs' 0 "$RC"
before=$(mkt_list)
run cmd_plugin_add 5dive-ai/rival --yes
eq_t 'a verb-claim refusal keeps its rc (E_VALIDATION)' "$E_VALIDATION" "$RC"
has_t 'the verb-claim refusal is the one that fired' "already claimed by" "$ERR"
eq_t 'a refused add leaves the marketplace list unchanged' "$before" "$(mkt_list)"
eq_t 'a refused add leaves no staged clone behind' no "$([[ -e "$(_plugin_mkt_dir)/rival" ]] && echo yes || echo no)"
eq_t 'a refused add installs nothing' false "$(jq 'has("rival@rival")' "$(_plugin_installed_json)")"
run cmd_plugin_add 5dive-ai/rival2 --yes
eq_t 'a second refused add does not stack another marketplace' "$before" "$(mkt_list)"

# A refusal that fires before the installer (no plugin chosen) is the same case.
run cmd_plugin_add 5dive-ai/tools2 --yes
eq_t 'a multi-plugin refusal keeps its rc (E_USAGE)' "$E_USAGE" "$RC"
eq_t 'a multi-plugin refusal leaves the marketplace list unchanged' "$before" "$(mkt_list)"

# Negative control on scope: a marketplace the OPERATOR registered beforehand is
# theirs, and a refused add through it must not remove it.
run cmd_plugin_marketplace add 5dive-ai/rival --as=rival-kept
eq_t 'setup: operator registers the rival marketplace' 0 "$RC"
before=$(mkt_list)
run cmd_plugin_add 5dive-ai/rival --as=rival-kept --yes
eq_t 'a refused add through a pre-registered marketplace keeps its rc' "$E_VALIDATION" "$RC"
eq_t 'a pre-registered marketplace survives a refused add' "$before" "$(mkt_list)"

# And a successful add from a new repository still keeps its marketplace.
run cmd_plugin_add 5dive-ai/tools2/gamma --yes
eq_t 'a successful add after a refusal still installs' 0 "$RC"
eq_t 'a successful add keeps the marketplace it registered' true "$(jq 'has("tools2")' "$(_plugin_mkt_json)")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAILN"
[[ "$FAILN" == 0 ]]
