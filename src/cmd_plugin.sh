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

# _plugin_publish_json <tmp> <dest> — the ONLY way these two files are replaced.
#
# DIVE-4035, and it is a real box defect rather than tidiness. Every writer here
# builds the new document in a `mktemp` and moves it into place, and mktemp
# creates 0600 — so `installed.json` ended up ROOT-ONLY on a real install. That
# was invisible for the whole of DIVE-4020 because every `5dive plugin` subverb
# is root-gated, so the only readers were root. Verb dispatch is the first
# UNPRIVILEGED reader of this registry: a normal user typing `5dive voice` could
# not read it, `_plugin_verb_claims` came back empty, and the verb fell through
# to "unknown command" — install said the verb was live and the box disagreed,
# which is precisely the failure this row exists to remove, one layer down.
#
# The registry holds names, versions, publishers and declared grants. No secret
# has ever been written here and none may be; 0644 is the mode that matches what
# it is, and the directories above it are 0755 for the same reason.
_plugin_publish_json() {
  local tmp="$1" dest="$2"
  mv "$tmp" "$dest" || return 1
  chmod 644 "$dest"
}

# The capability and grant enums are contract §1. They are declared here as the
# single source of truth because THREE places need them to agree: validation
# (refuse an unknown value), the consent screen (render a grant in English), and
# registration (an undeclared surface is inert). A fourth copy in a test is fine;
# a fourth copy in the code is how they drift.
readonly PLUGIN_CAPABILITIES="channel mcp skill verb hook"
readonly PLUGIN_GRANTS="telegram-token audio-io agent-credentials fs-home network browser-profiles"
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
    browser-profiles)   echo "the browser profile store — the logged-in sessions you authenticated by hand" ;;
    *)                  echo "$1" ;;
  esac
}

# ---- contract §1: a grant names a resource, and naming it is not the job -----
#
# DIVE-4126. `browser-profiles` was missing from the enum above, so the browser
# plugin we SHIPPED in v0.28.0 could not be installed on any box: `plugin add
# browser` died at "unknown grant". Adding the string is the one-line half.
#
# The half that matters is that a grant with nothing enforcing it is the wish §2
# was written against — it renders on the consent screen as a promise no code
# keeps. So the enum entry comes with (a) a plain-English rendering above, and
# (b) this function, which is what the grant MEANS on a real box.
#
# What `browser-profiles` authorises, exactly, and nothing else:
#
#   $STATE_DIR/browser-profiles/          root, 0711   traverse, do not list
#                              /<seat>/   that seat,   0700
#                                     /<site>/         0700
#
# It is deliberately NARROWER than `fs-home` rather than a special case of it. A
# profile directory IS a credential — anything that can read it replays the
# session — so the grant names one root that sits outside every home, instead of
# handing the plugin a home it could rummage. A plugin that wants both is asking
# for two things and must declare two things.
#
# CREATION STAYS A ROOT ACT AND `plugin add` DOES NOT DO IT. That was the open
# question on this row; the answer is the browser plugin's own threat model. On a
# parent any seat can write to, a hostile seat pre-creates another seat's
# directory NAME, owns it, and every session that seat later authenticates lands
# somewhere it can read — that is the whole credential, not a theoretical squat.
# Provisioning it from `plugin add` would also make a credential store appear as
# a side effect of an install the user ran for another reason, which is the exact
# "5dive does not create it behind your back" the plugin itself prints. So the
# installer PRINTS `fivedive.setup` and the human runs `sudo 5dive browser
# setup`, the same shape voice already uses for `5dive-setup-voice`.
#
# What the installer DOES enforce is fail-closed. If the store is ABSENT that is
# a fresh box and setup is the next thing the user is told to run — not an error.
# If it EXISTS and is not a root-owned 0711 directory, the install is REFUSED:
# installing on top of a store that hands sessions to the wrong uid is worse than
# not installing, and the plugin would only discover it later, one `auth` in.
_plugin_browser_profile_root() { echo "${STATE_DIR}/browser-profiles"; }

# _plugin_browser_store_fault <root> <owner-uid> <mode>
# Echoes the fault in a sentence, or nothing when the store is safe. It is a
# separate function because the two faults are not equally reachable from a
# test: a harness running as an ordinary seat can never CREATE a root-owned
# directory, so an end-to-end arm always trips the owner check first and the
# mode check is graded by nobody. Splitting the predicate out lets it be driven
# with the pairs the filesystem will not hand us, on any seat, as root or not.
_plugin_browser_store_fault() {
  local root="$1" owner="$2" mode="$3"
  [[ "$owner" == "0" ]] \
    || { echo "$root is owned by uid $owner rather than root. Anything that owns that directory can hand a seat's logged-in sessions to someone else, so this install is refused."; return 0; }
  [[ "$mode" == "711" ]] \
    || { echo "$root is mode $mode rather than 711. 0711 is traverse-but-not-list: on anything wider one seat can enumerate — or pre-create — another seat's profile directory and read its sessions."; return 0; }
  return 0
}

# _plugin_grant_enforce <plugin> <grants>
# Runs BEFORE the consent screen and before anything is copied, for the same
# reason _plugin_verb_install_check does: a grant we cannot honour must not reach
# the point where the user has agreed to it.
_plugin_grant_enforce() {
  local plugin="$1" grants="$2" g
  for g in $grants; do
    case "$g" in
      browser-profiles)
        local root; root="$(_plugin_browser_profile_root)"
        [[ -e "$root" ]] || continue
        [[ -d "$root" ]] \
          || fail "$E_VALIDATION" "$plugin asks for the browser profile store, but $root exists and is not a directory. A profile is a credential and 5dive will not install on top of that. Move it aside, then: sudo 5dive browser setup"
        local owner mode fault
        owner=$(stat -c '%u' "$root" 2>/dev/null) || owner=""
        mode=$(stat -c '%a' "$root" 2>/dev/null) || mode=""
        fault=$(_plugin_browser_store_fault "$root" "$owner" "$mode")
        [[ -z "$fault" ]] || fail "$E_PERMISSION" "$plugin asks for the browser profile store, and $fault Fix the store first: sudo 5dive browser setup"
        ;;
    esac
  done
  return 0
}

_plugin_usage() {
  cat <<'USAGE'
5dive plugin — install and manage 5dive plugins

  5dive plugin list [--json]                      # what is installed, with version and tier
  5dive plugin add <plugin>[@<marketplace>] [--yes]
  5dive plugin remove <plugin>[@<marketplace>]
  5dive plugin upgrade <plugin>[@<marketplace>]
  5dive plugin enable|disable <plugin>[@<marketplace>]    # a flag flip; the code stays on disk
  5dive plugin rollback <plugin>[@<marketplace>] [<version>]

  5dive plugin marketplace add <source> [--as=<name>]
  5dive plugin marketplace list [--json]
  5dive plugin marketplace upgrade [<name>]
  5dive plugin marketplace remove <name>

  <source> is a local path, an <owner>/<repo>[@<ref>], or a git URL.

  Discovery lives in `5dive market --kind=plugin`, not here — one front door for
  "what can I add?" whether the answer is a plugin, a persona or a skill.

  A plugin that declares the `verb` capability adds a top-level command. It is
  reached only AFTER every builtin one, so a plugin can never take `5dive task`
  from you — a manifest naming a builtin, or a verb a second plugin already
  claims, is refused at install rather than installed dead. 5dive runs
  <plugin>/bin/<verb> and nothing else: the manifest names the verb, it never
  supplies a command line.

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

    # DIVE-4035 — the `verb` capability, both directions.
    #
    # DECLARED-BUT-NOT-DISPATCHED is the shape this whole row exists to kill, so
    # it is said out loud here rather than left for the publisher to discover as
    # a bug report. It is a warning and not a refusal on purpose: `verbs` without
    # the capability is a manifest that is honestly inert under §2, and refusing
    # it would make §2's own rule uninstallable.
    #
    # The converse IS a refusal, because it is not inert — it is incoherent. A
    # manifest claiming the `verb` capability while naming no verbs asks for a
    # surface and then declines to say what goes on it, and every later step
    # (collision check, entry-point check, dispatch) has nothing to read.
    local vnames; vnames=$(jq -r '(.verbs // []) | map(.name? // empty) | join(" ")' <<<"$fd")
    if [[ " $caps " == *" verb "* ]]; then
      [[ -n "$vnames" ]] \
        || fail "$E_VALIDATION" "$name declares the 'verb' capability but names no verbs — add fivedive.verbs: [{\"name\": \"...\"}] (contract §2)"
      local vn
      for vn in $vnames; do
        _plugin_verb_name_ok "$vn" \
          || fail "$E_VALIDATION" "verb name '$vn' must be lowercase kebab-case — it becomes a top-level '5dive' command (contract §2)"
      done
    elif [[ -n "$vnames" ]]; then
      warn "$name names verbs ($vnames) but does not declare the 'verb' capability — they will NOT be dispatched, and '5dive $(cut -d' ' -f1 <<<"$vnames")' stays an unknown command (contract §2: an undeclared surface is inert)"
    fi
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

# The ONE registry. Every 5dive plugin — telegram, dashboard, buzz, voice,
# browser — is published to 5dive-ai/5dive-plugins, and that repo is the only
# marketplace this CLI registers for you.
#
# DIVE-4202 removed the second home. `voice` and `browser` used to be BUNDLED in
# this repo's plugins/ and registered as a local marketplace named "5dive", so
# they were the only two plugins whose fix reached a customer on a CLI release
# rather than on a publish — which is how the browser plugin shipped
# uninstallable on 0.28.0 (DIVE-4126) with every check green. One home, one
# grading path: the install-contract enumerates the registry's manifest, so a
# plugin published there is graded on a fresh box the day it lands.
#
# FIVEDIVE_PLUGIN_REGISTRY overrides the source and, when set, is the ONLY thing
# consulted — a test or the docker-install contract points it at a local clone
# and must not silently fall through to the network and grade the real registry
# instead of its own fixture. Same env-honouring convention as STATE_DIR
# (header.sh:70). It takes anything `marketplace add` takes: a local path, an
# owner/repo, or a git URL.
_plugin_registry_name() { echo "5dive-plugins"; }
_plugin_registry_source() {
  if [[ -n "${FIVEDIVE_PLUGIN_REGISTRY:-}" ]]; then
    printf '%s' "$FIVEDIVE_PLUGIN_REGISTRY"; return 0
  fi
  printf 'https://github.com/%s/5dive-plugins.git' "$(gh_org)"
}

# The registry registers ITSELF, once, on first use.
#
# This is what keeps contract §6 true after the move: `5dive plugin add voice`
# resolves with no prior setup, because the very first thing a new user would
# otherwise have to do to install our own reference plugin is add a marketplace
# by hand — the gap this verb exists to close, reintroduced one level up.
#
# Unlike the bundled dir it replaces, this needs the network ONCE (the clone).
# It is best-effort by design: every failure path returns 0 and leaves the
# marketplace unregistered, so an offline box gets `plugin ls` with no
# marketplace rather than a plugin verb that dies. `plugin add`'s not-found
# message names the registry, so the recovery is one documented command.
_plugin_register_registry() {
  local name; name=$(_plugin_registry_name)
  jq -e --arg n "$name" 'has($n)' "$(_plugin_mkt_json)" >/dev/null 2>&1 && return 0
  local src; src=$(_plugin_registry_source)
  local dest; dest="$(_plugin_mkt_dir)/$name"
  rm -rf "$dest"
  if [[ -d "$src" ]]; then
    cp -a "$src" "$dest" 2>/dev/null || { rm -rf "$dest"; return 0; }
  else
    command -v git >/dev/null 2>&1 || return 0
    local url="$src" ref=""
    case "$src" in
      *://*|*@*:*) : ;;
      */*) ref="${src##*@}"; [[ "$ref" == "$src" ]] && ref="" || src="${src%@*}"
           url="https://github.com/${src}.git" ;;
      *)   return 0 ;;
    esac
    if [[ -n "$ref" ]]; then
      timeout 30 git clone --quiet --depth 1 --branch "$ref" "$url" "$dest" 2>/dev/null \
        || { rm -rf "$dest"; return 0; }
    else
      timeout 30 git clone --quiet --depth 1 "$url" "$dest" 2>/dev/null \
        || { rm -rf "$dest"; return 0; }
    fi
  fi
  # A registry clone with no manifest is not a registry — leave it unregistered
  # rather than record a marketplace whose every resolve then fails.
  [[ -f "$dest/.claude-plugin/marketplace.json" ]] || { rm -rf "$dest"; return 0; }
  local tmp; tmp=$(mktemp)
  jq --arg n "$name" --arg s "$(_plugin_registry_source)" --arg t "$(date -u +%FT%TZ)" \
     '.[$n] = {source:$s, kind:"git", ref:"", added_at:$t, registry:true}' \
     "$(_plugin_mkt_json)" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_mkt_json)"
  # Explicit, because this function's last command is a CONDITIONAL and would
  # otherwise supply its exit status: every caller is `_plugin_ensure_store`,
  # which runs under errexit, so a failed jq here would take the whole verb down
  # with no message rather than leaving the registry unregistered. Registering
  # is best-effort by design — every early `return 0` above says so — and the
  # last line must agree with them.
  return 0
}

_plugin_ensure_store() {
  require_root
  mkdir -p "$(_plugin_mkt_dir)" "$(_plugin_cache_dir)" "$(_plugin_enabled_dir)"
  # DIVE-4035: the store is written by root and READ by whoever types a plugin
  # verb, so its traversal has to survive a tight umask on the installing shell.
  chmod 755 "$(_plugin_root)" "$(_plugin_mkt_dir)" "$(_plugin_cache_dir)" "$(_plugin_enabled_dir)" 2>/dev/null || true
  [[ -f "$(_plugin_mkt_json)" ]]       || echo '{}' > "$(_plugin_mkt_json)"
  [[ -f "$(_plugin_installed_json)" ]] || echo '{}' > "$(_plugin_installed_json)"
  chmod 644 "$(_plugin_mkt_json)" "$(_plugin_installed_json)" 2>/dev/null || true
  _plugin_register_registry
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
     && _plugin_publish_json "$tmp" "$(_plugin_mkt_json)"

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
  jq --arg n "$name" 'del(.[$n])' "$(_plugin_mkt_json)" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_mkt_json)"
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
      fail "$E_NOT_FOUND" "no plugin '$plugin' in any registered marketplace. Registered: $(jq -r 'if (keys | length) == 0 then "(none)" else (keys | join(", ")) end' "$(_plugin_mkt_json)" 2>/dev/null). Every 5dive plugin is published to the registry — add it first: 5dive plugin marketplace add $(gh_org)/5dive-plugins"
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

  # BEFORE resolution, deliberately. quinn measured that on a fresh box this hint
  # never fired: `plugin add telegram` died at "no plugin telegram in any
  # registered marketplace" because the builtin branch sat behind the trust gate,
  # which sits behind manifest resolution, which needs the marketplace the user
  # has not added. The whole value of the hint is for the person who has NOT set
  # anything up, so it has to run before anything that needs setup.
  local _bare="${ref%@*}"
  if [[ "$ref" != *@* ]] && _plugin_is_builtin_channel "$_bare"; then
    fail "$E_USAGE" "'$_bare' is one of 5dive's built-in channel plugins — it is installed per AGENT, not per box, so 'plugin add' is not the path. Use: 5dive agent create <name> --channels=$_bare  (or, for an existing agent, 5dive agent config <name> --channels=$_bare). It predates the plugin contract and carries no 5dive manifest block, which is why it would otherwise read as unreviewed."
  fi

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

  # DIVE-4035, and it runs BEFORE the consent screen and before anything is
  # copied. A verb that cannot be dispatched — because it collides with a
  # builtin, because another plugin holds it, or because the plugin ships no
  # executable for it — must not reach the point where the user has agreed to
  # install it. Refusing here costs the publisher one message; refusing later
  # would leave a half-installed plugin whose verb silently does not exist,
  # which is the state this row was filed to remove.
  _plugin_verb_install_check "$srcdir" "$plugin" "$key" "$caps" "$j"

  # §1's other half (DIVE-4126). Same placement and same reason as the line
  # above: before the consent screen, before the copy.
  _plugin_grant_enforce "$plugin" "$grants"

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
     "$(_plugin_installed_json)" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_installed_json)"

  if [[ -z "$caps" ]]; then
    echo "  Note: $plugin declares no 5dive capabilities, so it registers no surfaces." >&2
    echo "  It is installed and inert (contract §2)." >&2
  fi

  # §2's live half, stated. The publisher's next question after "installed" is
  # "so what do I type", and the answer is now a fact about this box rather than
  # documentation.
  if [[ " $caps " == *" verb "* ]]; then
    local _v
    while IFS= read -r _v; do
      [[ -z "$_v" ]] && continue
      echo "  '5dive $_v' now runs this plugin ($PLUGIN_VERB_BINDIR/$_v)." >&2
    done < <(_plugin_verbs_of_manifest "$j")
  fi

  # `fivedive.setup` — a PROPOSED addendum to contract §6, and the whole of its
  # design is in one word: PRINTED. Some plugins need a host-level step the
  # installer must not take for them (voice pulls ffmpeg, a python venv and a
  # systemd unit). Without this the user is left at "installed — now what?", which
  # is the same dead end `plugin` exists to remove, one step later.
  #
  # It is NOT a post-install hook and must never become one. Executing a string
  # from a manifest at install time is arbitrary code execution chosen by the
  # publisher, which is precisely the door contract §5 keeps shut and lodar
  # deferred on 2026-09-07 — and it would be worse than the door, because it
  # would run BEFORE the user had seen what they installed. So we print it and
  # the human runs it. T9c asserts that we do not run it.
  local setup_hint setup_cmd
  setup_hint=$(jq -r '.fivedive.setup.hint // ""' <<<"$j")
  setup_cmd=$(jq -r '.fivedive.setup.command // ""' <<<"$j")
  if [[ -n "$setup_hint" || -n "$setup_cmd" ]]; then
    echo >&2
    [[ -n "$setup_hint" ]] && echo "  $setup_hint" >&2
    [[ -n "$setup_cmd"  ]] && echo "  Run it yourself when you are ready:  $setup_cmd" >&2
    echo "  (5dive does not run this for you — read it first; it is the publisher's text.)" >&2
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
  # Both come from a key that was just verified to exist in installed.json, so
  # neither can be empty — asserted anyway, because the next line is an `rm -rf`
  # and "cannot be empty" is exactly the reasoning that precedes deleting a cache
  # root. Cheap here, unrecoverable if wrong.
  [[ -n "$plugin" && -n "$mkt" && "$plugin" != "null" && "$mkt" != "null" ]] \
    || fail "$E_GENERIC" "refusing to remove: '$key' has no plugin/marketplace recorded"
  rm -f  "$(_plugin_enabled_dir)/$key"
  rm -rf "$(_plugin_cache_dir)/$mkt/$plugin"
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" 'del(.[$k])' <<<"$j" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_installed_json)"
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
     <<<"$j" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_installed_json)"

  ok "$key upgraded $cur -> $new (roll back: 5dive plugin rollback $key)" \
     '{plugin:$k, from:$f, to:$t, changed:true}' --arg k "$key" --arg f "$cur" --arg t "$new"
}

# §3: "Enable/disable is a config FLAG, not a re-copy."
#
# This exists because `plugin list` renders an ENABLED column, and a column that
# can only ever say "yes" is a claim the product cannot honour — a reader takes it
# to mean the state is controllable and it is not. Either the verb exists or the
# column should not.
#
# Disable removes the POINTER and clears the flag; the version-keyed dir stays
# untouched, so re-enabling is a flip and not a re-fetch from a marketplace that
# may since have moved on — the same property that makes `rollback` cheap. This is
# also the honest answer to "I want this off NOW": it needs no network, no
# marketplace and no consent screen, because nothing new is being installed.
_plugin_set_enabled() {
  local ref="$1" want="$2"     # want = true|false
  _plugin_ensure_store
  local j; j=$(cat "$(_plugin_installed_json)")
  local key; _plugin_resolve_installed_key "$ref" "$j"; key="$_PL_KEY"

  local cur; cur=$(jq -r --arg k "$key" '.[$k].enabled' <<<"$j")
  if [[ "$cur" == "$want" ]]; then
    ok "$key is already $([[ "$want" == true ]] && echo enabled || echo disabled)" \
       '{plugin:$k, enabled:($e=="true"), changed:false}' --arg k "$key" --arg e "$want"
    return 0
  fi

  local plugin mkt version
  plugin=$(jq -r --arg k "$key" '.[$k].plugin' <<<"$j")
  mkt=$(jq -r --arg k "$key" '.[$k].marketplace' <<<"$j")
  version=$(jq -r --arg k "$key" '.[$k].version' <<<"$j")

  if [[ "$want" == true ]]; then
    local dest="$(_plugin_cache_dir)/$mkt/$plugin/$version"
    # The recorded version must still be ON DISK. If it is not, re-enabling would
    # write a dangling pointer and `list` would then claim enabled for a plugin
    # with no code behind it — a worse state than disabled.
    [[ -d "$dest" ]] \
      || fail "$E_NOT_FOUND" "$key records version $version but that version is not on disk — reinstall it: 5dive plugin add $key"
    ln -sfn "$dest" "$(_plugin_enabled_dir)/$key"
  else
    rm -f "$(_plugin_enabled_dir)/$key"
  fi

  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --argjson e "$want" '.[$k].enabled = $e' <<<"$j" > "$tmp" \
    && _plugin_publish_json "$tmp" "$(_plugin_installed_json)"
  if [[ "$want" == true ]]; then
    ok "$key enabled ($version)" '{plugin:$k, enabled:true, changed:true}' --arg k "$key"
  else
    ok "$key disabled — its code is still on disk at version $version, so 'plugin enable $key' is a flip, not a reinstall" \
       '{plugin:$k, enabled:false, changed:true}' --arg k "$key"
  fi
}

cmd_plugin_enable()  { [[ -n "${1:-}" ]] || fail "$E_USAGE" "usage: 5dive plugin enable <plugin>[@<marketplace>]";  _plugin_set_enabled "$1" true; }
cmd_plugin_disable() { [[ -n "${1:-}" ]] || fail "$E_USAGE" "usage: 5dive plugin disable <plugin>[@<marketplace>]"; _plugin_set_enabled "$1" false; }

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
    # `|| want=""` is load-bearing, not defensive noise. With exactly ONE version
    # on disk `grep -vFx "$cur"` matches nothing and exits 1; under header.sh's
    # `set -euo pipefail` the ASSIGNMENT then kills the process on this line and
    # the friendly refusal below is unreachable code — `plugin rollback` exited 1
    # with nothing on stdout or stderr. One version on disk is not an edge case:
    # it is the state of every install that has never been upgraded, so this is
    # the FIRST thing a user does after their first upgrade goes wrong.
    # `|| want=""` and not `|| true`: the empty value states the post-condition
    # the line below actually reads (DIVE-2566/2603/2604,
    # scripts/unguarded-probe-scan.sh).
    want=$(ls "$base" 2>/dev/null | grep -vFx "$cur" | sort -V | tail -1) || want=""
    [[ -n "$want" ]] || fail "$E_NOT_FOUND" "no other version of $key is on disk (only $cur)"
  fi
  [[ -d "$base/$want" ]] || fail "$E_NOT_FOUND" "version '$want' of $key is not on disk (have: $(ls "$base" 2>/dev/null | tr '\n' ' '))"

  # A DISABLED plugin stays disabled through a rollback. Writing the pointer
  # unconditionally would turn "roll back to the version that worked" into
  # "...and switch it back on", which is a second decision the user did not make.
  if [[ "$(jq -r --arg k "$key" '.[$k].enabled' <<<"$j")" == "true" ]]; then
    ln -sfn "$base/$want" "$(_plugin_enabled_dir)/$key"
  fi
  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --arg v "$want" '.[$k].version = $v' <<<"$j" > "$tmp" && _plugin_publish_json "$tmp" "$(_plugin_installed_json)"
  ok "$key rolled back $cur -> $want" '{plugin:$k, from:$f, to:$t}' --arg k "$key" --arg f "$cur" --arg t "$want"
}

# ---- contract §2, the other half: a DECLARED verb is LIVE (DIVE-4035) -------
#
# DIVE-4020 shipped one half of §2 and quinn signed the other half as a residual.
# The enforcer got "an undeclared surface is inert" right; the unstated converse,
# "a DECLARED surface is live", was false. A manifest could name a verb, install
# cleanly, print no warning — and `5dive <verb>` was still "unknown command".
# One clause checked and not honoured, in the more surprising direction: the
# publisher gets no signal at all.
#
# ---- THE DESIGN CALL: WHAT A VERB IS INVOKED AS ----------------------------
#
# A verb resolves to an EXECUTABLE FILE AT A PATH 5DIVE COMPUTES, exec'd with the
# caller's argv as an argument VECTOR. The manifest supplies one thing: the NAME.
# It never supplies a command line, an interpreter, an entry-point path or any
# other string that reaches a shell.
#
# That is the whole of it, and the alternative is the reason it is written down.
# The obvious shape — `"verbs": [{"name": "voice", "command": "..."}]` and a
# `$command "$@"` in the dispatcher — is arbitrary code execution chosen by the
# publisher, which is the door contract §5 keeps shut and which DIVE-4020 already
# refused once for `fivedive.setup` (printed, never executed). Verb dispatch must
# not reopen it from the other side. With the path fixed by us, a plugin can only
# ship a file where we look; `exec "$entry" "$@"` passes a vector, so no argument
# is ever word-split or glob-expanded, and nothing from plugin.json is evaluated.
#
# WHY RUNNING THE FILE AT ALL IS NOT THE SAME DOOR. `plugin add` already copies
# the publisher's whole directory onto the box after a consent screen that names
# the publisher and the grants. What §5 keeps shut is code that runs because the
# publisher said so — at install, before the user has seen what they installed. A
# verb runs because the USER TYPED IT. That is the distinction, and it is the
# only one doing work here: user-initiated, after consent, at a path we chose.
#
# ---- COLLISIONS: STRUCTURALLY IMPOSSIBLE, THEN REFUSED ANYWAY --------------
#
# Dispatch hangs off main()'s `*)` branch — the last thing before "unknown
# command". A plugin therefore CANNOT shadow a builtin: by the time we are
# consulted the 47 builtin verbs have already matched. That is the strong form of
# the guarantee (a bug in the list below cannot cost a user their `5dive task`),
# and it is why the list is a refusal aid rather than a security boundary.
#
# But "cannot shadow" would leave a publisher with a verb that installs and never
# runs — the exact silent-inertness this row exists to remove. So a colliding
# verb is REFUSED AT INSTALL, naming the builtin. Same for a second plugin
# claiming a verb the first already holds: refused, naming the incumbent, because
# picking a winner is a decision the box should not make on the user's behalf.
#
# ---- COST -----------------------------------------------------------------
#
# ~73% of every 5dive invocation is already bash parsing one 91k-line bundle, and
# that is paid by every heartbeat tick fleet-wide. So the registry read happens
# ONLY on the unknown-command path — a command that was about to die anyway. A
# successful `5dive task ls` never reaches _plugin_dispatch_verb, never opens
# installed.json and never shells jq.

# Where a plugin's verb entry points live inside its own directory. A constant
# rather than an inline literal because three places must agree: the install-time
# check (source dir), the dispatcher (installed dir) and the error text that
# tells a publisher where to put the file.
readonly PLUGIN_VERB_BINDIR="bin"

# Every label main()'s dispatch table already answers to. Kept as data because it
# is read at install time, when the dispatcher itself is not a thing we can ask.
# It is NOT hand-maintained on trust: tests/plugin_verb_dispatch_unit.sh
# re-extracts the case labels from src/main.sh and asserts set equality, so a new
# builtin verb that forgets this line reds the suite rather than silently
# becoming claimable by a plugin.
readonly FIVEDIVE_BUILTIN_VERBS="a2a account acp activity agent _audit_append bug buzz company constitution cost council crew deploy _deploy_do digest doctor down export fire fleet gate-proof gh _gh_do goal -h heartbeat --help help hire host human humans init liveness loop market memory _merge_do models objective objectives org paperclip-seed plugin project projects proof ps push _push_do run runs secret selfcheck self-update self_update supervisor task _task_answer team trace trigger triggers ui uninstall up update usage -v --version version watch whoami"

_plugin_verb_name_ok()   { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }
_plugin_verb_is_builtin(){ [[ " $FIVEDIVE_BUILTIN_VERBS " == *" $1 "* ]]; }

# _plugin_verb_claims <verb> [<key-to-ignore>]
# Prints the installed.json key of every ENABLED plugin that declared the `verb`
# capability AND names <verb>. Empty output means unclaimed.
#
# Both halves of the select are §2: the capability is the declaration, the verbs
# array is the content, and a plugin that ships one without the other registers
# nothing. Reading the RECORD and never the directory is DIVE-4020's rule — a
# file dropped into bin/ after install cannot mint a verb the manifest never
# named.
_plugin_verb_claims() {
  local verb="$1" skip="${2:-}" f
  f=$(_plugin_installed_json)
  [[ -r "$f" ]] || return 0
  jq -r --arg v "$verb" --arg skip "$skip" '
    to_entries[]
    | select(.key != $skip)
    | select(.value.enabled == true)
    | select((.value.capabilities // []) | index("verb"))
    | select((.value.verbs // []) | map(.name? // empty) | index($v))
    | .key' "$f" 2>/dev/null || true
}

# _plugin_verb_entry_in <dir> <verb> — echoes the entry path, rc 1 if unusable.
# One function for both callers so the convention cannot drift between the check
# that gates the install and the lookup that runs the verb.
_plugin_verb_entry_in() {
  local dir="$1" verb="$2" entry="$1/$PLUGIN_VERB_BINDIR/$2"
  [[ -d "$dir" ]] || return 1
  [[ -f "$entry" && -x "$entry" ]] || return 1
  printf '%s\n' "$entry"
}

# _plugin_verbs_of_manifest <manifest-json> — one verb name per line.
_plugin_verbs_of_manifest() {
  jq -r '(.fivedive.verbs // []) | map(.name? // empty)[]' <<<"$1" 2>/dev/null || true
}

# _plugin_verb_install_check <srcdir> <plugin> <key> <caps> <manifest-json>
# Every refusal a declared verb can earn, run BEFORE anything is copied. Called
# from cmd_plugin_add; separate so the suite can drive it without an install.
_plugin_verb_install_check() {
  local srcdir="$1" plugin="$2" key="$3" caps="$4" j="$5" v other
  [[ " $caps " == *" verb "* ]] || return 0
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    _plugin_verb_is_builtin "$v" \
      && fail "$E_VALIDATION" "$plugin declares the verb '$v', which is already a 5dive command — a plugin verb is only ever reached AFTER the builtin table, so this one could never run. Rename it in plugin.json (contract §2)."
    other=$(_plugin_verb_claims "$v" "$key")
    [[ -n "$other" ]] \
      && fail "$E_VALIDATION" "$plugin declares the verb '$v', which is already claimed by $(tr '\n' ' ' <<<"$other" | sed 's/ $//') — 5dive will not pick between them. Remove or disable that plugin first, or rename this verb (contract §2)."
    _plugin_verb_entry_in "$srcdir" "$v" >/dev/null \
      || fail "$E_VALIDATION" "$plugin declares the verb '$v' but ships no executable at $PLUGIN_VERB_BINDIR/$v — that is the only place 5dive looks, and a verb it cannot run must not install as if it could. Add the file and chmod +x it (contract §2)."
  done < <(_plugin_verbs_of_manifest "$j")
  return 0
}

# _plugin_dispatch_verb <verb> [args...]
# EXECS on success and therefore does not return. Returns 1 — quietly, with
# nothing printed — only when no installed, enabled plugin claims <verb>, which
# is the caller's signal to carry on to "unknown command".
#
# Quiet is the contract with main(): every other outcome here is a plugin problem
# worth a sentence, but "no plugin claims it" is the overwhelmingly common case
# (a typo) and must read exactly as it did before this row existed.
_plugin_dispatch_verb() {
  local verb="${1:-}"; [[ $# -gt 0 ]] && shift
  _plugin_verb_name_ok "$verb" || return 1
  # Belt to the structural brace: main() has already matched every builtin before
  # we are called, so this can only fire on a hand-edited installed.json. It
  # still refuses, because "a plugin cannot shadow a builtin" should not depend
  # on the reader knowing where the call site sits.
  _plugin_verb_is_builtin "$verb" && return 1
  command -v jq >/dev/null 2>&1 || return 1

  local claims; claims=$(_plugin_verb_claims "$verb")
  [[ -n "$claims" ]] || return 1

  if [[ "$(wc -l <<<"$claims")" -gt 1 ]]; then
    fail "$E_VALIDATION" "verb '$verb' is claimed by more than one enabled plugin ($(tr '\n' ' ' <<<"$claims" | sed 's/ $//')) — 5dive will not pick between them. Disable all but one: 5dive plugin disable <plugin>"
  fi

  local key="$claims" dir entry
  dir="$(_plugin_enabled_dir)/$key"
  entry=$(_plugin_verb_entry_in "$dir" "$verb") \
    || fail "$E_NOT_FOUND" "$key declares the verb '$verb' but $dir/$PLUGIN_VERB_BINDIR/$verb is missing or not executable. Reinstall it: 5dive plugin upgrade $key"

  # The child gets its own location and identity and nothing else invented for
  # it. STATE_DIR and the rest of the environment pass through untouched, which
  # is what lets the suite run a real dispatch against a throwaway tree.
  export FIVEDIVE_PLUGIN_DIR="$dir"
  export FIVEDIVE_PLUGIN_KEY="$key"
  export FIVEDIVE_VERB="$verb"

  # DIVE-2797: `exec` replaces the process, so the dispatcher's EXIT trap never
  # fires and AUDIT_CMD would be lost. Same fix cmd_acp uses — write the row
  # here, before the exec, rather than pretending the trap will.
  if declare -F audit_log >/dev/null 2>&1 && [[ -n "${AUDIT_LOG:-}" ]]; then
    audit_log "plugin-verb" "start" 0 -- "verb=$verb" "plugin=$key" || true
  fi

  exec "$entry" "$@"
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
    enable)          cmd_plugin_enable "$@" ;;
    disable)         cmd_plugin_disable "$@" ;;
    rollback)        cmd_plugin_rollback "$@" ;;
    *) fail "$E_USAGE" "unknown: 5dive plugin $sub (see: 5dive plugin --help)" ;;
  esac
}
