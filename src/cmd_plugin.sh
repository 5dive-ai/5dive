# -------- plugins (DIVE-4020) — the lifecycle verb the contract needs --------
#
# Contract: community/wiki/the-5dive-plugin-contract-v1.md. This file is its
# ENFORCER. The contract was written first and graded on its own; quinn's
# iteration-1 reject was that a contract with nothing enforcing it is prose:
# "an undeclared surface is inert" (§2) is a rule, and a rule with no code is a
# wish. Everything below exists to make one of the contract's clauses true on a
# real box, and each function names the clause it serves.
#
# WHAT WAS MEASURED BEFORE WRITING THIS (DIVE-4020 body): there is no `5dive
# plugin` command. 47 top-level subcommands, none of them `plugin`. Plugins
# install today only as SIDE EFFECTS of other verbs — `agent create` calls
# install_channel_for_agent, `agent buzz enable` installs the buzz plugin — so a
# CLI-only self-hoster has no path to discovering or installing one at all.
# That gap is what `plugin` closes.
#
# SCOPE, and it is narrower than the contract on purpose. lodar answered the
# DIVE-4020 gate on 2026-09-07 02:43:57Z: *"Ship voice only now, defer
# third-party."* So this file implements the `official` tier and REFUSES the
# other two. That is not a stub — refusing is the shipped behaviour of the
# deferral, and it is tested. The trust-root / CRL / launch-recheck machinery in
# contract §5.1 is exactly what `community` would need, it does not exist, and
# nothing here pretends it does. See _plugin_trust_gate.
#
# ---- WHERE THE STORE LIVES, AND WHY IT IS NOT WHERE THE CONTRACT SAYS -------
#
# Contract §3 writes the cache at `~/.5dive/plugins/cache/...`. This uses
# `$STATE_DIR/plugins/` instead (i.e. /var/lib/5dive/plugins). The deviation is
# deliberate and it is the same finding DIVE-4021 raises about browser profiles:
# a per-HOME store is right for a single-user install and wrong for a box with
# ~18 agent seats. Concretely, under `~/.5dive` the same plugin is copied once
# per seat (N times the disk, N versions to revoke), and every other piece of
# 5dive state — the registry, auth profiles, connectors — is already host-level
# under STATE_DIR. A plugin is host software; WHICH AGENT may use it is a
# separate question that the per-agent channel path already answers.
#
# STATE_DIR is honoured from the environment exactly as header.sh:70 defines it,
# which is also what makes every arm of the test suite able to run against a
# throwaway tree instead of the live box.
#
#   $STATE_DIR/plugins/marketplaces.json     registered sources
#   $STATE_DIR/plugins/marketplaces/<name>/  the materialised source
#   $STATE_DIR/plugins/cache/<mkt>/<plugin>/<version>/   §4 version-keyed install
#   $STATE_DIR/plugins/enabled/<plugin>@<mkt>            §3 pointer (enable/disable)
#   $STATE_DIR/plugins/installed.json        what is installed, and what it DECLARED

_plugin_root()      { echo "${STATE_DIR}/plugins"; }
_plugin_mkt_dir()   { echo "$(_plugin_root)/marketplaces"; }
_plugin_mkt_json()  { echo "$(_plugin_root)/marketplaces.json"; }
_plugin_cache_dir() { echo "$(_plugin_root)/cache"; }
_plugin_enabled_dir() { echo "$(_plugin_root)/enabled"; }
_plugin_installed_json() { echo "$(_plugin_root)/installed.json"; }

# The capability and grant enums are contract §1. They are declared here as the
# single source of truth because THREE places need them to agree: validation
# (refuse an unknown value), the consent screen (render a grant in English), and
# registration (an undeclared surface is inert). A fourth copy in a test is fine;
# a fourth copy in the code is how they drift.
readonly PLUGIN_CAPABILITIES="channel mcp skill verb hook"
readonly PLUGIN_GRANTS="telegram-token audio-io agent-credentials fs-home network"
readonly PLUGIN_REVIEW_TIERS="official community unreviewed"

# Plain English for the consent screen (§5.2). The point of this map is that the
# screen must describe what the user is HANDING OVER, not echo our enum back at
# them: "grants: agent-credentials" tells a customer nothing, and a consent
# screen nobody understands is not consent.
_plugin_grant_english() {
  case "$1" in
    telegram-token)     echo "your Telegram bot token" ;;
    audio-io)           echo "your microphone and speakers" ;;
    agent-credentials)  echo "your agent's own login credentials" ;;
    fs-home)            echo "read and write access to your agent's home directory" ;;
    network)            echo "outbound network access" ;;
    *)                  echo "$1" ;;
  esac
}

_plugin_usage() {
  cat <<'USAGE'
5dive plugin — install and manage 5dive plugins

  5dive plugin list [--json]                      # what is installed, with version and tier
  5dive plugin add <plugin>[@<marketplace>] [--yes]
  5dive plugin remove <plugin>[@<marketplace>]
  5dive plugin upgrade <plugin>[@<marketplace>]

  5dive plugin marketplace add <source> [--as=<name>]
  5dive plugin marketplace list [--json]
  5dive plugin marketplace upgrade [<name>]
  5dive plugin marketplace remove <name>

  <source> is a local path, an <owner>/<repo>[@<ref>], or a git URL.

  Discovery lives in `5dive market --kind=plugin`, not here — one front door for
  "what can I add?" whether the answer is a plugin, a persona or a skill.

  Installing a plugin is installing CODE that runs with your agent's access.
  `add` prints who published it and exactly what it will be handed, and waits
  for you to agree. Pass --yes only when you have already read that.
USAGE
}

# ---- reading a plugin manifest (contract §1) -------------------------------
#
# Three accepted locations. `.claude-plugin/` is the format we adopt rather than
# invent (the whole point of the contract's "adopt, do not invent": our telegram
# bridges already ARE plugins in this format). `.5dive-plugin/` is the alias the
# contract promises so a 5dive-only plugin need not brand itself Claude.
# `.codex-plugin/` is here because it is not hypothetical — plugins/telegram-codex
# in our own 5dive-plugins repo ships exactly that and nothing else, so a reader
# that refused it would refuse a plugin we publish.
_plugin_manifest_path() {
  local dir="$1" c
  for c in .claude-plugin .5dive-plugin .codex-plugin; do
    [[ -f "$dir/$c/plugin.json" ]] && { echo "$dir/$c/plugin.json"; return 0; }
  done
  # A few plugins in the wild put plugin.json at the top of the dir. Accept it
  # last so a directory carrying both is read from the canonical place.
  [[ -f "$dir/plugin.json" ]] && { echo "$dir/plugin.json"; return 0; }
  return 1
}

# _plugin_validate_manifest <dir> <manifest-path>
# Sets _PL_MANIFEST to the validated manifest JSON. Fails loudly on anything the
# contract forbids — every refusal here is a refusal to install, which is the
# only place validation is worth anything.
#
# IT SETS A GLOBAL RATHER THAN ECHOING, and that is not a style choice. Written
# as `j=$(_plugin_validate_manifest ...)` the whole body runs in a command
# substitution, so `fail` exits only THAT subshell: the message printed, the
# caller carried on with an empty manifest, every field read back empty, and the
# install was then refused several steps later by the trust gate with the wrong
# exit code and a message about provenance for what was actually a malformed
# name. It still refused — by luck, because an empty manifest reads as
# `unreviewed` — which is exactly what makes the shape dangerous: it looks like
# working validation. Caught by T1a-T1g, which asserted the CODE and not just
# "it did not install".
_plugin_validate_manifest() {
  local dir="$1" mf="$2" j
  j=$(jq -c . "$mf" 2>/dev/null) \
    || fail "$E_VALIDATION" "$mf is not valid JSON"

  local name ver
  name=$(jq -r '.name // ""' <<<"$j")
  ver=$(jq -r '.version // ""' <<<"$j")

  [[ -n "$name" ]] || fail "$E_VALIDATION" "$mf declares no 'name'"
  # §1: name MUST equal the folder name. We inherit this from Codex rather than
  # choosing it, and it is load-bearing rather than tidy: the install path, the
  # enabled pointer and the config stanza are all keyed on the name, so a plugin
  # whose folder and manifest disagree installs under one identity and is looked
  # up under another.
  [[ "$name" == "$(basename "$dir")" ]] \
    || fail "$E_VALIDATION" "manifest name '$name' does not match the folder name '$(basename "$dir")' — they must be identical (contract §1)"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] \
    || fail "$E_VALIDATION" "plugin name '$name' must be lowercase kebab-case"

  # §4 hangs entirely on version being real and comparable. A plugin with no
  # version has no version-keyed path, so `upgrade` could never resolve one.
  [[ -n "$ver" ]] || fail "$E_VALIDATION" "$mf declares no 'version' — the install path is keyed on it (contract §4)"
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]] \
    || fail "$E_VALIDATION" "version '$ver' is not a version number"

  # The `fivedive` block is OPTIONAL, and its absence is meaningful rather than
  # an error: a plain Codex/Claude plugin (every one we ship today) declares no
  # 5dive surfaces, so under §2 it registers none. That is "an undeclared surface
  # is inert" applied to the plugins that predate the contract — they install and
  # sit inert rather than being retro-granted anything.
  local fd; fd=$(jq -c '.fivedive // {}' <<<"$j")
  if [[ "$fd" != "{}" ]]; then
    local contract; contract=$(jq -r '.contract // ""' <<<"$fd")
    [[ -z "$contract" || "$contract" == "1" ]] \
      || fail "$E_VALIDATION" "plugin targets contract '$contract'; this CLI implements contract 1"

    local c
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      [[ " $PLUGIN_CAPABILITIES " == *" $c "* ]] \
        || fail "$E_VALIDATION" "unknown capability '$c' (contract §1: $PLUGIN_CAPABILITIES)"
    done < <(jq -r '(.capabilities // [])[]' <<<"$fd")

    local g
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      [[ " $PLUGIN_GRANTS " == *" $g "* ]] \
        || fail "$E_VALIDATION" "unknown grant '$g' (contract §1: $PLUGIN_GRANTS)"
    done < <(jq -r '(.grants // [])[]' <<<"$fd")

    local review; review=$(jq -r '.trust.review // ""' <<<"$fd")
    [[ -z "$review" || " $PLUGIN_REVIEW_TIERS " == *" $review "* ]] \
      || fail "$E_VALIDATION" "unknown review tier '$review' (contract §5: $PLUGIN_REVIEW_TIERS)"

    # §2, and this is the clause with teeth. A plugin that ships a surface it did
    # not declare does not get it registered — but silently dropping it is how a
    # publisher discovers the rule in a bug report, so name it at install time.
    local caps; caps=$(jq -r '(.capabilities // []) | join(" ")' <<<"$fd")
    [[ -f "$dir/.mcp.json" && " $caps " != *" mcp "* ]] \
      && warn "$name ships .mcp.json but does not declare the 'mcp' capability — it will NOT be registered (contract §2: an undeclared surface is inert)"
    [[ -d "$dir/skills" && " $caps " != *" skill "* ]] \
      && warn "$name ships skills/ but does not declare the 'skill' capability — they will NOT be registered (contract §2)"
    [[ -f "$dir/hooks.json" || -f "$dir/hooks/hooks.json" ]] && [[ " $caps " != *" hook "* ]] \
      && warn "$name ships hooks but does not declare the 'hook' capability — they will NOT be registered (contract §2)"
  fi

  _PL_MANIFEST="$j"
}

# ---- the trust gate (contract §5, narrowed by lodar's gate answer) ---------
#
# This is where the deferral is IMPLEMENTED rather than described. lodar's
# answer was "ship voice only now, defer third-party", so the only tier that
# installs is `official`.
#
# It refuses rather than warning, and the difference matters: a warning would let
# a third-party plugin land today and make the deferral a documentation claim.
# The message names what is missing, because the honest reason this is closed is
# not "we don't trust you", it is that contract §5.1's trust root, its
# counter-signed key enrollment and its revocation list are all unbuilt — there
# is nothing to verify a community signature AGAINST, and a check against the
# marketplace the plugin came from proves only that a publisher agrees with
# themselves (the circular check quinn caught in iteration 1).
#
# ONE special case, and it is not a carve-out in the gate — it is a better
# error. Our own telegram / dashboard / buzz plugins predate the contract, carry
# no `fivedive` block, and so read as `unreviewed` here. They are not installed
# by this verb at all: they are wired PER AGENT by `agent create --channels=`
# and `agent buzz enable`, which is a different install path with a different
# unit (an agent, not the box). Refusing them with the generic third-party
# message would be true and useless, so name the path that actually works.
_plugin_is_builtin_channel() {
  jq -e --arg p "$1" 'any(.[]; .plugin==$p)' <<<"$FIVEDIVE_CHANNEL_PLUGINS_JSON" >/dev/null 2>&1
}

_plugin_trust_gate() {
  local name="$1" review="$2"
  case "$review" in
    official) return 0 ;;
    community|unreviewed|"")
      if _plugin_is_builtin_channel "$name"; then
        fail "$E_USAGE" "'$name' is one of 5dive's built-in channel plugins — it is installed per AGENT, not per box, so 'plugin add' is not the path. Use: 5dive agent create <name> --channels=$name  (or, for an existing agent, 5dive agent config <name> --channels=$name). It predates the plugin contract and carries no 5dive manifest block, which is why it reads as unreviewed here."
      fi
      fail "$E_PERMISSION" "$(cat <<MSG
'$name' is a ${review:-unreviewed} plugin, and 5dive installs only 'official' plugins today.

A third-party plugin runs as your agent, under your agent's user, with your
agent's credentials — there is no sandbox between them. Opening that door needs
a way to prove who wrote a plugin and to switch a bad one off after it is
installed. That machinery is specified (contract §5.1) and is not built yet, so
the door stays shut rather than being propped open with a flag.
MSG
)" ;;
  esac
}

# ---- consent (contract §5.2) ----------------------------------------------
#
# Printed BEFORE any code is copied, from the manifest only. Fail-closed on a
# non-interactive stdin: a pipeline that cannot be asked has not consented, and
# defaulting to yes there would make the screen decorative on exactly the path
# (scripts, the dashboard exec tunnel) where nobody is watching.
_plugin_consent() {
  local name="$1" version="$2" publisher="$3" review="$4" grants="$5" assume_yes="$6"

  echo
  echo "  Installing a plugin installs CODE that runs with your agent's access."
  echo
  echo "    plugin:     $name $version"
  echo "    published:  ${publisher:-unknown}"
  echo "    review:     $review"
  if [[ -n "$grants" ]]; then
    echo "    handed to it:"
    local g
    for g in $grants; do echo "      · $(_plugin_grant_english "$g")"; done
  else
    echo "    handed to it: nothing beyond its own directory"
  fi
  echo

  (( assume_yes )) && { echo "  (--yes given)"; echo; return 0; }
  [[ -t 0 ]] || fail "$E_PERMISSION" "plugin add needs your confirmation and stdin is not a terminal — re-run with --yes if you have read the above"

  local reply
  read -r -p "  Install $name? [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] \
    || fail "$E_GENERIC" "cancelled — nothing was installed"
}

# ---- marketplaces ----------------------------------------------------------

# Where the CLI's OWN bundled plugins live. Mirrors _team_templates_dir: the
# installed path first, a repo-local plugins/ second so a source checkout and a
# test worktree behave like a real box.
_plugin_bundled_dir() {
  # FIVEDIVE_BUNDLED_PLUGINS wins and, when set, is the ONLY thing consulted —
  # a test that points it at a fixture must not silently fall through to
  # /usr/local/lib/5dive/plugins and grade the real box's plugins instead of its
  # own. Same env-honouring convention as STATE_DIR (header.sh:70).
  if [[ -n "${FIVEDIVE_BUNDLED_PLUGINS:-}" ]]; then
    [[ -d "$FIVEDIVE_BUNDLED_PLUGINS" ]] && { realpath "$FIVEDIVE_BUNDLED_PLUGINS"; return 0; }
    return 1
  fi
  local self d
  self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || self=""
  # Installed layout first, then both source shapes: the BUILT single-file
  # binary sits at the repo root (so plugins/ is its sibling) while the SPLIT
  # source sits in src/ (so plugins/ is one level up). Checking both is what
  # keeps `./build.sh && ./5dive plugin ...` in a worktree behave like a box.
  for d in /usr/local/lib/5dive/plugins \
           ${self:+"$(dirname "$self")/plugins"} \
           ${self:+"$(dirname "$self")/../plugins"}; do
    [[ -n "$d" && -d "$d" ]] && { realpath "$d"; return 0; }
  done
  return 1
}

# The bundled marketplace registers ITSELF, once, on first use.
#
# This is what makes contract §6 literally true — `5dive plugin add voice@5dive`
# resolves on a box with no network, no GitHub credential and no prior setup.
# Without it the very first thing a new user must do to install our own
# reference plugin is add a marketplace by hand, which is the gap this whole
# verb exists to close, reintroduced one level up.
#
# Registered as kind=local pointing at the bundled dir, so `plugin marketplace
# upgrade 5dive` re-copies from whatever the installed CLI now ships — a CLI
# upgrade therefore refreshes the source, and (per §4) still installs nothing
# until the plugin's own version is bumped.
_plugin_register_bundled() {
  local src; src=$(_plugin_bundled_dir) || return 0
  [[ -f "$src/.claude-plugin/marketplace.json" ]] || return 0
  jq -e 'has("5dive")' "$(_plugin_mkt_json)" >/dev/null 2>&1 && return 0
  local dest; dest="$(_plugin_mkt_dir)/5dive"
  rm -rf "$dest"
  cp -a "$src" "$dest" 2>/dev/null || return 0
  local tmp; tmp=$(mktemp)
  jq --arg s "$src" --arg t "$(date -u +%FT%TZ)" \
     '.["5dive"] = {source:$s, kind:"local", ref:"", added_at:$t, bundled:true}' \
     "$(_plugin_mkt_json)" > "$tmp" && mv "$tmp" "$(_plugin_mkt_json)"
}

_plugin_ensure_store() {
  require_root
  mkdir -p "$(_plugin_mkt_dir)" "$(_plugin_cache_dir)" "$(_plugin_enabled_dir)"
  [[ -f "$(_plugin_mkt_json)" ]]       || echo '{}' > "$(_plugin_mkt_json)"
  [[ -f "$(_plugin_installed_json)" ]] || echo '{}' > "$(_plugin_installed_json)"
  _plugin_register_bundled
}

# A marketplace name keys a directory and a config stanza, so it is constrained
# for the same reason a plugin name is: it becomes a path.
_plugin_valid_mkt_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# Derive a default name from the source, so `marketplace add ./plugins` does not
# demand a --as= for the common case.
_plugin_mkt_default_name() {
  local src="$1" n
  case "$src" in
    *://*|*@*:*) n="${src##*/}"; n="${n%.git}" ;;
    */*)         [[ -d "$src" ]] && n=$(basename "$(cd "$src" && pwd)") || { n="${src##*/}"; n="${n%.git}"; } ;;
    *)           n=$(basename "$src") ;;
  esac
  printf '%s' "$n" | tr '[:upper:]' '[:lower:]'
}

cmd_plugin_marketplace() {
  local sub="${1:-list}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    add)     _plugin_mkt_add "$@" ;;
    ls|list) _plugin_mkt_list "$@" ;;
    upgrade|update) _plugin_mkt_upgrade "$@" ;;
    rm|remove|delete) _plugin_mkt_remove "$@" ;;
    -h|--help) _plugin_usage ;;
    *) fail "$E_USAGE" "unknown: plugin marketplace $sub (add|list|upgrade|remove)" ;;
  esac
}

_plugin_mkt_add() {
  local src="" name="" a
  for a in "$@"; do
    case "$a" in
      --as=*) name="${a#--as=}" ;;
      --*)    fail "$E_USAGE" "unknown flag: $a" ;;
      *)      [[ -z "$src" ]] && src="$a" || fail "$E_USAGE" "one source at a time" ;;
    esac
  done
  [[ -n "$src" ]] || fail "$E_USAGE" "usage: 5dive plugin marketplace add <local-path|owner/repo[@ref]|git-url> [--as=<name>]"
  _plugin_ensure_store

  [[ -n "$name" ]] || name=$(_plugin_mkt_default_name "$src")
  _plugin_valid_mkt_name "$name" || fail "$E_VALIDATION" "marketplace name '$name' must be lowercase kebab/dot/underscore"

  local dest; dest="$(_plugin_mkt_dir)/$name"
  [[ -e "$dest" ]] && fail "$E_CONFLICT" "marketplace '$name' already exists — 'plugin marketplace upgrade $name' to refresh it, or --as=<other-name>"

  local kind ref=""
  if [[ -d "$src" ]]; then
    kind="local"
    # A local source is COPIED, not symlinked, for the same reason §3 says an
    # install is a copy: a symlinked source mutates under an installed plugin,
    # so what was consented to at install time is not what runs afterwards.
    cp -a "$src" "$dest" || fail "$E_GENERIC" "could not copy $src"
  else
    kind="git"
    local url="$src"
    case "$src" in
      *://*|*@*:*) : ;;
      */*) ref="${src##*@}"; [[ "$ref" == "$src" ]] && ref="" || src="${src%@*}"
           url="https://github.com/${src}.git" ;;
      *)   fail "$E_VALIDATION" "'$src' is not a local path, an owner/repo, or a git URL" ;;
    esac
    command -v git >/dev/null 2>&1 || fail "$E_NOT_INSTALLED" "git is required to add a remote marketplace"
    if [[ -n "$ref" ]]; then
      git clone --quiet --depth 1 --branch "$ref" "$url" "$dest" 2>/dev/null \
        || fail "$E_GENERIC" "could not clone $url at ref '$ref'"
    else
      git clone --quiet --depth 1 "$url" "$dest" 2>/dev/null \
        || fail "$E_GENERIC" "could not clone $url"
    fi
  fi

  local tmp; tmp=$(mktemp)
  jq --arg n "$name" --arg s "$src" --arg k "$kind" --arg r "$ref" --arg t "$(date -u +%FT%TZ)" \
     '.[$n] = {source:$s, kind:$k, ref:$r, added_at:$t}' "$(_plugin_mkt_json)" > "$tmp" \
     && mv "$tmp" "$(_plugin_mkt_json)"

  local n; n=$(_plugin_mkt_plugins "$name" | jq 'length' 2>/dev/null || echo 0)
  ok "marketplace '$name' added ($kind) — $n plugin(s) available" \
     '{marketplace:$n, kind:$k, plugins:$c}' --arg n "$name" --arg k "$kind" --argjson c "${n:-0}"
}

# The plugin list a marketplace offers. Reads `.claude-plugin/marketplace.json`
# when present (the format 5dive-plugins already publishes), and otherwise falls
# back to walking plugins/*/ — a plain directory of plugins is a legitimate
# local marketplace and demanding an index file for `marketplace add ./plugins`
# would make the local path the awkward case rather than the easy one.
_plugin_mkt_plugins() {
  local mkt="$1" dir; dir="$(_plugin_mkt_dir)/$mkt"
  [[ -d "$dir" ]] || return 1
  local idx
  for idx in "$dir/.claude-plugin/marketplace.json" "$dir/.5dive-plugin/marketplace.json" "$dir/marketplace.json"; do
    [[ -f "$idx" ]] || continue
    jq -c '[.plugins[]? | {name, description, source}]' "$idx" 2>/dev/null && return 0
  done
  local out="[]" d n
  for d in "$dir"/plugins/*/ "$dir"/*/; do
    [[ -d "$d" ]] || continue
    _plugin_manifest_path "${d%/}" >/dev/null 2>&1 || continue
    n=$(basename "${d%/}")
    out=$(jq -c --arg n "$n" --arg s "./$(realpath --relative-to="$dir" "${d%/}")" \
          '. + [{name:$n, description:"", source:$s}]' <<<"$out")
  done
  printf '%s\n' "$out"
}

# Resolve a plugin name to its directory inside a marketplace.
_plugin_source_dir() {
  local mkt="$1" plugin="$2" dir; dir="$(_plugin_mkt_dir)/$mkt"
  local src; src=$(_plugin_mkt_plugins "$mkt" 2>/dev/null \
    | jq -r --arg p "$plugin" '.[] | select(.name==$p) | .source // ""' | head -1)
  if [[ -n "$src" && "$src" != "null" ]]; then
    local p="$dir/${src#./}"
    [[ -d "$p" ]] && { echo "$p"; return 0; }
  fi
  [[ -d "$dir/plugins/$plugin" ]] && { echo "$dir/plugins/$plugin"; return 0; }
  [[ -d "$dir/$plugin" ]] && { echo "$dir/$plugin"; return 0; }
  return 1
}

_plugin_mkt_list() {
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_mkt_json)")
  if (( JSON_MODE )); then ok "" '$m' --argjson m "$j"; return; fi
  if [[ "$j" == "{}" ]]; then
    echo "No plugin marketplaces registered."
    echo "Add one:  5dive plugin marketplace add <local-path|owner/repo|git-url>"
    return
  fi
  { printf 'NAME\tKIND\tPLUGINS\tSOURCE\n'
    local n
    while IFS= read -r n; do
      printf '%s\t%s\t%s\t%s\n' "$n" \
        "$(jq -r --arg n "$n" '.[$n].kind' <<<"$j")" \
        "$(_plugin_mkt_plugins "$n" 2>/dev/null | jq 'length' 2>/dev/null || echo '?')" \
        "$(jq -r --arg n "$n" '.[$n].source' <<<"$j")"
    done < <(jq -r 'keys[]' <<<"$j")
  } | column -t -s $'\t' | sed 's/^/  /'
}

_plugin_mkt_upgrade() {
  _plugin_ensure_store
  local want="${1:-}" j; j=$(cat "$(_plugin_mkt_json)")
  local names
  if [[ -n "$want" ]]; then
    jq -e --arg n "$want" 'has($n)' <<<"$j" >/dev/null || fail "$E_NOT_FOUND" "no marketplace '$want'"
    names="$want"
  else
    names=$(jq -r 'keys[]' <<<"$j")
  fi
  local n kind src dir done_n=0
  for n in $names; do
    kind=$(jq -r --arg n "$n" '.[$n].kind' <<<"$j")
    src=$(jq -r --arg n "$n" '.[$n].source' <<<"$j")
    dir="$(_plugin_mkt_dir)/$n"
    if [[ "$kind" == "git" ]]; then
      git -C "$dir" fetch --quiet --depth 1 origin 2>/dev/null \
        && git -C "$dir" reset --quiet --hard FETCH_HEAD 2>/dev/null \
        && { step "refreshed $n"; done_n=$((done_n+1)); } \
        || warn "could not refresh '$n' from $src"
    else
      if [[ -d "$src" ]]; then
        rm -rf "$dir" && cp -a "$src" "$dir" && { step "refreshed $n"; done_n=$((done_n+1)); }
      else
        warn "local source $src for '$n' no longer exists"
      fi
    fi
  done
  # Refreshing a SOURCE installs nothing. Saying so is the difference between a
  # user who runs `plugin upgrade` next and one who wonders why nothing changed.
  ok "$done_n marketplace(s) refreshed — installed plugins are unchanged until 'plugin upgrade'" \
     '{refreshed:$n}' --argjson n "$done_n"
}

_plugin_mkt_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive plugin marketplace remove <name>"
  _plugin_ensure_store
  jq -e --arg n "$name" 'has($n)' "$(_plugin_mkt_json)" >/dev/null \
    || fail "$E_NOT_FOUND" "no marketplace '$name'"

  # Refuse while something installed still came from here. Removing the source
  # of an installed plugin would leave an entry whose origin cannot be resolved,
  # which breaks `upgrade` later with an error that points at the wrong thing.
  local still; still=$(jq -r --arg m "$name" '[to_entries[] | select(.value.marketplace==$m) | .key] | join(", ")' "$(_plugin_installed_json)")
  [[ -z "$still" ]] || fail "$E_CONFLICT" "still installed from '$name': $still — remove those first"

  rm -rf "$(_plugin_mkt_dir)/$name"
  local tmp; tmp=$(mktemp)
  jq --arg n "$name" 'del(.[$n])' "$(_plugin_mkt_json)" > "$tmp" && mv "$tmp" "$(_plugin_mkt_json)"
  ok "marketplace '$name' removed" '{marketplace:$n}' --arg n "$name"
}

# ---- install / list / remove / upgrade -------------------------------------

# Resolve "<plugin>[@<marketplace>]" into _PL_PLUGIN / _PL_MKT.
#
# It sets GLOBALS and is called in the CURRENT shell rather than echoing a pair
# into `read` from a process substitution. That is not style: `fail` inside
# `$( )` or `< <( )` kills only the SUBSHELL, so a refusal there prints its
# message, exits nothing, and leaves the caller running on with empty variables —
# a validation that reads as passing. (Same class as the errexit-in-a-subshell
# trap in my notes: the dangerous half is the one that under-reds.)
#
# With no @, the marketplace is resolved by searching the registered ones.
# Ambiguity is an ERROR, never a first-match: two marketplaces can both offer
# `telegram`, and silently picking one is how a user installs the other one.
_plugin_split_ref() {
  local ref="$1" plugin mkt
  if [[ "$ref" == *@* ]]; then
    plugin="${ref%@*}"; mkt="${ref##*@}"
  else
    plugin="$ref"; mkt=""
  fi
  [[ -n "$plugin" ]] || fail "$E_USAGE" "empty plugin name"
  if [[ -z "$mkt" ]]; then
    local found=() m
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      _plugin_source_dir "$m" "$plugin" >/dev/null 2>&1 && found+=("$m")
    done < <(jq -r 'keys[]' "$(_plugin_mkt_json)" 2>/dev/null)
    if (( ${#found[@]} == 0 )); then
      fail "$E_NOT_FOUND" "no plugin '$plugin' in any registered marketplace. Registered: $(jq -r 'keys | join(", ") // "(none)"' "$(_plugin_mkt_json)" 2>/dev/null). If it is published rather than bundled, add its source first: 5dive plugin marketplace add $(gh_org)/5dive-plugins"
    elif (( ${#found[@]} > 1 )); then
      fail "$E_CONFLICT" "'$plugin' exists in ${#found[@]} marketplaces (${found[*]}) — name one: ${plugin}@${found[0]}"
    fi
    mkt="${found[0]}"
  fi
  _PL_PLUGIN="$plugin"; _PL_MKT="$mkt"
}

# The installed key for a bare name, same anti-first-match rule. Sets _PL_KEY.
_plugin_resolve_installed_key() {
  local ref="$1" j="$2"
  if [[ "$ref" == *@* ]]; then
    jq -e --arg k "$ref" 'has($k)' <<<"$j" >/dev/null \
      || fail "$E_NOT_FOUND" "'$ref' is not installed (see: 5dive plugin list)"
    _PL_KEY="$ref"; return 0
  fi
  local -a m=(); local line
  while IFS= read -r line; do [[ -n "$line" ]] && m+=("$line"); done \
    < <(jq -r --arg p "$ref" 'to_entries[] | select(.value.plugin==$p) | .key' <<<"$j")
  if (( ${#m[@]} == 0 )); then
    fail "$E_NOT_FOUND" "'$ref' is not installed (see: 5dive plugin list)"
  elif (( ${#m[@]} > 1 )); then
    fail "$E_CONFLICT" "'$ref' is installed from ${#m[@]} marketplaces (${m[*]}) — name one"
  fi
  _PL_KEY="${m[0]}"
}

cmd_plugin_add() {
  local ref="" assume_yes=0 a
  for a in "$@"; do
    case "$a" in
      --yes|-y) assume_yes=1 ;;
      --*)      fail "$E_USAGE" "unknown flag: $a" ;;
      *)        [[ -z "$ref" ]] && ref="$a" || fail "$E_USAGE" "one plugin at a time" ;;
    esac
  done
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive plugin add <plugin>[@<marketplace>] [--yes]"
  _plugin_ensure_store

  local plugin mkt
  _plugin_split_ref "$ref"; plugin="$_PL_PLUGIN"; mkt="$_PL_MKT"
  local srcdir; srcdir=$(_plugin_source_dir "$mkt" "$plugin") \
    || fail "$E_NOT_FOUND" "no plugin '$plugin' in marketplace '$mkt'"

  local mf; mf=$(_plugin_manifest_path "$srcdir") \
    || fail "$E_VALIDATION" "$srcdir has no plugin.json (looked in .claude-plugin/, .5dive-plugin/, .codex-plugin/)"
  local j; _plugin_validate_manifest "$srcdir" "$mf"; j="$_PL_MANIFEST"

  local version publisher review grants caps
  version=$(jq -r '.version' <<<"$j")
  publisher=$(jq -r '.fivedive.trust.publisher // .author.name // ""' <<<"$j")
  review=$(jq -r '.fivedive.trust.review // "unreviewed"' <<<"$j")
  grants=$(jq -r '(.fivedive.grants // []) | join(" ")' <<<"$j")
  caps=$(jq -r '(.fivedive.capabilities // []) | join(" ")' <<<"$j")

  _plugin_trust_gate "$plugin" "$review"

  local key="${plugin}@${mkt}"
  local dest; dest="$(_plugin_cache_dir)/$mkt/$plugin/$version"

  # §4, and this is the trap the atom
  # [[a-plugin-install-path-is-version-keyed-so-an-unbumped-merge-fetches-nothing]]
  # is about. The keyed dir already existing means the installer has nothing to
  # do — which is correct, and which is also EXACTLY how a publisher ships a fix,
  # sees "OK", and never wonders why the fix is not running. So this path is
  # loud. It is not an error (re-running add is not a mistake), it is a sentence
  # that names the cause.
  if [[ -d "$dest" ]]; then
    echo "  $key is already installed at version $version — nothing was fetched." >&2
    echo "  The install path is keyed on the version, so a change that did not bump" >&2
    echo "  'version' in plugin.json cannot arrive. Bump it and run 'plugin upgrade $key'." >&2
    ok "$key already at $version" '{plugin:$p, marketplace:$m, version:$v, changed:false}' \
       --arg p "$plugin" --arg m "$mkt" --arg v "$version"
    return 0
  fi

  _plugin_consent "$plugin" "$version" "$publisher" "$review" "$grants" "$assume_yes"

  mkdir -p "$(dirname "$dest")"
  # §3: install is a COPY of the whole directory, node_modules and all. Not a
  # symlink into the marketplace — see _plugin_mkt_add for why.
  cp -a "$srcdir" "$dest" || fail "$E_GENERIC" "could not copy $srcdir to $dest"

  # §3: enable/disable is a POINTER, not a re-copy. That is what makes rollback
  # after an upgrade a flip rather than a reinstall, and it is why the old
  # version's directory is deliberately left on disk by `upgrade`.
  ln -sfn "$dest" "$(_plugin_enabled_dir)/$key"

  # §2: what gets recorded is what was DECLARED. Registration reads this record,
  # never the directory, so a surface the manifest did not name cannot be
  # activated later by something walking the files.
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg p "$plugin" --arg m "$mkt" --arg v "$version" \
     --arg r "$review" --arg pub "$publisher" --arg t "$(date -u +%FT%TZ)" \
     --argjson caps "$(jq -c '(.fivedive.capabilities // [])' <<<"$j")" \
     --argjson grants "$(jq -c '(.fivedive.grants // [])' <<<"$j")" \
     --argjson verbs "$(jq -c '(.fivedive.verbs // [])' <<<"$j")" \
     '.[$k] = {plugin:$p, marketplace:$m, version:$v, enabled:true, review:$r,
               publisher:$pub, capabilities:$caps, grants:$grants, verbs:$verbs,
               installed_at:$t}' \
     "$(_plugin_installed_json)" > "$tmp" && mv "$tmp" "$(_plugin_installed_json)"

  if [[ -z "$caps" ]]; then
    echo "  Note: $plugin declares no 5dive capabilities, so it registers no surfaces." >&2
    echo "  It is installed and inert (contract §2)." >&2
  fi
  ok "$key $version installed${caps:+ — registers: $caps}" \
     '{plugin:$p, marketplace:$m, version:$v, review:$r, capabilities:$c, changed:true}' \
     --arg p "$plugin" --arg m "$mkt" --arg v "$version" --arg r "$review" \
     --argjson c "$(jq -c '(.fivedive.capabilities // [])' <<<"$j")"
}

cmd_plugin_list() {
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_installed_json)")
  if (( JSON_MODE )); then ok "" '$p' --argjson p "$j"; return; fi
  if [[ "$j" == "{}" ]]; then
    echo "No plugins installed."
    echo "Browse:  5dive market --kind=plugin"
    echo "Install: 5dive plugin add <plugin>"
    return
  fi
  { printf 'PLUGIN\tVERSION\tTIER\tENABLED\tREGISTERS\n'
    jq -r 'to_entries[] | [ .key, .value.version, .value.review,
             (if .value.enabled then "yes" else "no" end),
             ((.value.capabilities // []) | if length==0 then "(nothing)" else join(",") end) ] | @tsv' <<<"$j"
  } | column -t -s $'\t' | sed 's/^/  /'
}

cmd_plugin_remove() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive plugin remove <plugin>[@<marketplace>]"
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_installed_json)")

  local key; _plugin_resolve_installed_key "$ref" "$j"; key="$_PL_KEY"

  local plugin mkt; plugin=$(jq -r --arg k "$key" '.[$k].plugin' <<<"$j"); mkt=$(jq -r --arg k "$key" '.[$k].marketplace' <<<"$j")

  # §3: "uninstall is TOTAL". Not just the enabled version — every version dir
  # this plugin ever installed, the pointer, and the config stanza. A plugin that
  # leaves a version behind leaves code on the box that the user believes they
  # removed, which is the whole point of the clause.
  rm -f  "$(_plugin_enabled_dir)/$key"
  rm -rf "$(_plugin_cache_dir)/$mkt/$plugin"
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" 'del(.[$k])' <<<"$j" > "$tmp" && mv "$tmp" "$(_plugin_installed_json)"
  ok "$key removed — every version, its pointer and its grants are gone" '{plugin:$k}' --arg k "$key"
}

cmd_plugin_upgrade() {
  local ref="${1:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive plugin upgrade <plugin>[@<marketplace>]"
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_installed_json)")

  local key; _plugin_resolve_installed_key "$ref" "$j"; key="$_PL_KEY"

  local plugin mkt cur
  plugin=$(jq -r --arg k "$key" '.[$k].plugin' <<<"$j")
  mkt=$(jq -r --arg k "$key" '.[$k].marketplace' <<<"$j")
  cur=$(jq -r --arg k "$key" '.[$k].version' <<<"$j")

  local srcdir; srcdir=$(_plugin_source_dir "$mkt" "$plugin") \
    || fail "$E_NOT_FOUND" "'$plugin' is no longer in marketplace '$mkt' — refresh it: 5dive plugin marketplace upgrade $mkt"
  local mf; mf=$(_plugin_manifest_path "$srcdir") || fail "$E_VALIDATION" "$srcdir has no plugin.json"
  local nj; _plugin_validate_manifest "$srcdir" "$mf"; nj="$_PL_MANIFEST"
  local new; new=$(jq -r '.version' <<<"$nj")

  # The same §4 trap from the other end, and the more common one: the publisher
  # merged a fix without bumping the version, so the marketplace source really
  # has changed and the installer really can do nothing about it. Answering "up
  # to date" here would be true and useless.
  if [[ "$new" == "$cur" ]]; then
    echo "  $key is at $cur and the marketplace still offers $cur." >&2
    echo "  If a fix was published without bumping 'version' in plugin.json, it cannot" >&2
    echo "  arrive: the install path is keyed on the version (contract §4)." >&2
    ok "$key already at $cur" '{plugin:$k, version:$v, changed:false}' --arg k "$key" --arg v "$cur"
    return 0
  fi

  local review; review=$(jq -r '.fivedive.trust.review // "unreviewed"' <<<"$nj")
  _plugin_trust_gate "$plugin" "$review"

  local dest; dest="$(_plugin_cache_dir)/$mkt/$plugin/$new"
  if [[ ! -d "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$srcdir" "$dest" || fail "$E_GENERIC" "could not copy $srcdir to $dest"
  fi
  # §4: install ALONGSIDE, then flip the pointer. The old version dir stays, so
  # rollback is a flip and not a re-fetch from a marketplace that may since have
  # moved on.
  ln -sfn "$dest" "$(_plugin_enabled_dir)/$key"
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg v "$new" --arg t "$(date -u +%FT%TZ)" \
     --argjson caps "$(jq -c '(.fivedive.capabilities // [])' <<<"$nj")" \
     --argjson grants "$(jq -c '(.fivedive.grants // [])' <<<"$nj")" \
     '.[$k].version = $v | .[$k].capabilities = $caps | .[$k].grants = $grants | .[$k].upgraded_at = $t' \
     <<<"$j" > "$tmp" && mv "$tmp" "$(_plugin_installed_json)"

  ok "$key upgraded $cur -> $new (roll back: 5dive plugin rollback $key)" \
     '{plugin:$k, from:$f, to:$t, changed:true}' --arg k "$key" --arg f "$cur" --arg t "$new"
}

# Rollback is the other half of §4's "install alongside, then flip". Without it
# the old version dir left on disk is dead weight rather than a safety net, and
# the reason the cache is version-keyed at all disappears.
cmd_plugin_rollback() {
  local ref="${1:-}" want="${2:-}"
  [[ -n "$ref" ]] || fail "$E_USAGE" "usage: 5dive plugin rollback <plugin>[@<marketplace>] [<version>]"
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_installed_json)")
  local key; _plugin_resolve_installed_key "$ref" "$j"; key="$_PL_KEY"

  local plugin mkt cur
  plugin=$(jq -r --arg k "$key" '.[$k].plugin' <<<"$j")
  mkt=$(jq -r --arg k "$key" '.[$k].marketplace' <<<"$j")
  cur=$(jq -r --arg k "$key" '.[$k].version' <<<"$j")

  local base="$(_plugin_cache_dir)/$mkt/$plugin"
  if [[ -z "$want" ]]; then
    want=$(ls "$base" 2>/dev/null | grep -vFx "$cur" | sort -V | tail -1)
    [[ -n "$want" ]] || fail "$E_NOT_FOUND" "no other version of $key is on disk (only $cur)"
  fi
  [[ -d "$base/$want" ]] || fail "$E_NOT_FOUND" "version '$want' of $key is not on disk (have: $(ls "$base" 2>/dev/null | tr '\n' ' '))"

  ln -sfn "$base/$want" "$(_plugin_enabled_dir)/$key"
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg v "$want" '.[$k].version = $v' <<<"$j" > "$tmp" && mv "$tmp" "$(_plugin_installed_json)"
  ok "$key rolled back $cur -> $want" '{plugin:$k, from:$f, to:$t}' --arg k "$key" --arg f "$cur" --arg t "$want"
}

cmd_plugin() {
  local sub="${1:-list}"; [[ $# -gt 0 ]] && shift
  case "$sub" in
    -h|--help|help) _plugin_usage ;;
    marketplace|mkt) cmd_plugin_marketplace "$@" ;;
    add|install)     cmd_plugin_add "$@" ;;
    ls|list)         cmd_plugin_list "$@" ;;
    rm|remove|uninstall) cmd_plugin_remove "$@" ;;
    upgrade|update)  cmd_plugin_upgrade "$@" ;;
    rollback)        cmd_plugin_rollback "$@" ;;
    *) fail "$E_USAGE" "unknown: 5dive plugin $sub (see: 5dive plugin --help)" ;;
  esac
}
