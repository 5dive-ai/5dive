# shellcheck shell=bash
# ---------------------------------------------------------------------------
# DIVE-8315 — one hook for plugin channels.
# ---------------------------------------------------------------------------
# A chat channel used to be core code: every new one touched about a dozen
# places that named it (validation, agent create and config, the launch line in
# 5dive-agent-start, the per-seat install, the Claude Code allowlist, local-only,
# people knocks). lodar, 2026-11-13 on the first draft of the email channel:
# «why to the core? i thought its a plugin». Core stays lean, and a feature is a plugin.
#
# So a plugin DECLARES its channel in its manifest and core reads it from there:
#
#   "fivedive": {
#     "capabilities": ["channel", ...],
#     "channel": {
#       "name": "<the --channels word>",           # [a-z][a-z0-9-]{1,23}, never a built-in
#       "harnesses": ["claude"],                   # agent types that can run it (default claude)
#       "local_only": {"label": "...", "note": "..."},   # optional: may be opened on a local-only box
#       "knock": {"sender": "email" | "id",        # optional: the owner's Allow/No card
#                 "cards": {"<kind>": "<text with {agent} and {sender}>"}}
#     }
#   }
#
# Only an ENABLED plugin that declares the `channel` capability counts, and a
# name that collides with a built-in channel is ignored: telegram, discord,
# dashboard, buzz and teams keep their own wiring (no migration here).
#
# Claude Code launches it as `--channels plugin:<plugin>@<marketplace>`, and it
# delivers nothing unless /etc/claude-code/managed-settings.json lists that pair:
# without it Claude connects the server and silently drops every message
# (measured on a live box, DIVE-8315). plugin_channels_allowlist_json feeds the
# pair into the same reconcile that already covers the built-in channels.

PLUGIN_CHANNEL_BUILTINS="none telegram discord dashboard buzz teams"

_plugin_channels_store() { echo "${STATE_DIR:-/var/lib/5dive}/plugins"; }

# plugin_channels_json -> JSON array of
#   {name, plugin, marketplace, dir, harnesses, local_only, knock}
# Never fails: no store, no plugins or a bad manifest all read as [].
plugin_channels_json() {
  local store inst out='[]' key plugin mkt dir mf e rows
  store=$(_plugin_channels_store); inst="$store/installed.json"
  [[ -r "$inst" ]] || { echo '[]'; return 0; }
  # Captured first, not read from a process substitution (epipe corpus guard C3).
  rows=$(jq -r 'to_entries[]
                | select(.value.enabled == true and ((.value.capabilities // []) | index("channel")))
                | [.key, (.value.plugin // ""), (.value.marketplace // "")] | @tsv' "$inst" 2>/dev/null) || rows=""
  while IFS=$'\t' read -r key plugin mkt; do
    [[ -n "$key" ]] || continue
    dir="$store/enabled/$key"
    mf=""
    for e in .claude-plugin .5dive-plugin .codex-plugin; do
      [[ -r "$dir/$e/plugin.json" ]] && { mf="$dir/$e/plugin.json"; break; }
    done
    [[ -n "$mf" ]] || continue
    e=$(jq -c --arg p "$plugin" --arg m "$mkt" --arg d "$dir" --arg b " $PLUGIN_CHANNEL_BUILTINS " '
          .fivedive.channel // empty
          | select(type == "object" and ((.name // "") | test("^[a-z][a-z0-9-]{1,23}$")))
          | .name as $n | select(($b | contains(" " + $n + " ")) | not)
          | {name, plugin: $p, marketplace: $m, dir: $d,
             harnesses: ((.harnesses // ["claude"]) | map(strings)),
             local_only: (.local_only // null | if type == "object" then . else null end),
             knock: (.knock // null | if type == "object" and (.cards | type) == "object" then . else null end)}
        ' "$mf" 2>/dev/null) || continue
    [[ -n "$e" ]] || continue
    out=$(jq -c --argjson e "$e" 'if any(.[]; .name == $e.name) then . else . + [$e] end' <<<"$out")
  done <<<"$rows"
  printf '%s\n' "$out"
}

# plugin_channel <name> -> that channel's entry; non-zero when no enabled plugin declares it.
plugin_channel() {
  local e
  e=$(plugin_channels_json | jq -c --arg n "${1:-}" '.[] | select(.name == $n)' 2>/dev/null)
  [[ -n "$e" ]] || return 1
  printf '%s\n' "$e"
}

# plugin_channel_names -> the declared names, space-separated (may be empty).
plugin_channel_names() { plugin_channels_json | jq -r '[.[].name] | join(" ")'; }

# plugin_channel_runs_on <name> <type> -> 0 when that agent type can run it.
# Claude Code only for now: it is the one harness that loads a channel plugin by
# name (--channels plugin:<p>@<m>); the others are wired per channel in core.
plugin_channel_runs_on() {
  [[ "${2:-}" == claude ]] || return 1
  plugin_channel "${1:-}" | jq -e --arg t "${2:-}" '.harnesses | index($t)' >/dev/null 2>&1
}

# plugin_channel_harness_check <name> <type> <agent> — fail with the sentence a
# person reads when the agent's type cannot run this channel.
plugin_channel_harness_check() {
  local ch="$1" type="$2" agent="$3" list
  plugin_channel_runs_on "$ch" "$type" && return 0
  list=$(plugin_channel "$ch" | jq -r '.harnesses | join(", ")')
  fail "$E_VALIDATION" "channels=$ch runs on ${list:-no agent type} agents only (agent '$agent' is type $type)"
}

# plugin_channels_in <csv> -> the plugin-declared channels in that list, one per line.
plugin_channels_in() {
  local c names; names=" $(plugin_channel_names) "
  local IFS=,
  for c in ${1:-}; do
    [[ -n "$c" && "$names" == *" $c "* ]] && printf '%s\n' "$c"
  done
  return 0
}

# plugin_channels_allowlist_json -> [{plugin, marketplace}] for the managed
# settings allowlist (merged with FIVEDIVE_CHANNEL_PLUGINS_JSON by its callers).
plugin_channels_allowlist_json() {
  plugin_channels_json | jq -c 'map({plugin, marketplace})'
}

# channel_plugins_wanted_json -> every pair the allowlist must hold: the built-in
# channels plus each enabled plugin channel.
channel_plugins_wanted_json() {
  jq -cn --argjson a "${FIVEDIVE_CHANNEL_PLUGINS_JSON:-[]}" --argjson b "$(plugin_channels_allowlist_json)" \
    '$a + ($b | map(select(. as $n | $a | any(.plugin == $n.plugin and .marketplace == $n.marketplace) | not)))'
}
