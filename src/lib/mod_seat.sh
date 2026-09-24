# ---------------------------------------------------------------------------
# DIVE-4936: seat the Claude Code mod on new Claude seats — OUR box only,
# behind a box switch that defaults OFF.
# ---------------------------------------------------------------------------
# `mod@5dive-plugins` carries the tool-call guard, and on our box that guard is
# the only enforcement left for the rules DIVE-4741 deleted from CLAUDE.md. The
# existing seats were armed by hand (claude plugin install + the env flag, per
# seat), and nothing in core did it for a seat created afterwards — so a new seat
# here got the rules from neither the prose nor the guard.
#
# WHY A SWITCH, AND WHY IT DEFAULTS OFF (lodar, 2026-09-24: "be sure those changes
# won't break 5dive"). Function hooks are an early-access Claude Code API and every
# box upgrades Claude Code nightly, so a change in that API would land on every
# seat at once. The box-damage the guard prevents has no recorded incident on a
# customer box. So every other box carries this code DORMANT: with `mod_seat`
# absent from box.json, agent create does exactly what it did before and doctor's
# mod category probes nothing. Turn it on with `5dive config mod-seat=on`.
# Revisit the default when function hooks leave early access.
#
# What a seated seat gets: the plugin (`claude plugin install`, which also writes
# enabledPlugins) and CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 in its settings.json env
# — without that flag the module never loads. settings.json and NOT
# agents.d/<seat>.env: write_agent_env rewrites that file from a fixed key list on
# every `agent config set`. The guard runs its default policy (the full
# guard.json). Nothing else the plugin can do is switched on: telemetry, the panel,
# /task and /gate and boundary compaction each sit behind their own flag.
#
# FAIL OPEN. A seat whose seating fails runs exactly as it would have without it.

MOD_SEAT_PLUGIN="mod"
MOD_SEAT_MARKETPLACE="5dive-plugins"
MOD_SEAT_HOOKS_ENV="CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"

# mod_seat_enabled -> 0 only when box.json says `"mod_seat": "on"`. Anything
# else — absent, unreadable, a typo — is off.
mod_seat_enabled() {
  local f="${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}" v=""
  [[ -r "$f" ]] && v=$(jq -r '.mod_seat // empty' "$f" 2>/dev/null || true)
  [[ "$v" == on ]]
}

_mod_seat_settings() { printf '%s/agent-%s/.claude/settings.json\n' "${AGENT_HOME_ROOT:-${PERSONA_HOME_ROOT:-/home}}" "${1:-}"; }

# mod_seat_env_apply <name> -> add CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 to the
# seat's settings.json env when it is ABSENT (an explicit 0 is the owner's no).
# Prints "changed" or "unchanged"; non-zero when the file is missing or not a
# JSON object. Atomic, owner and 0600 kept, and never rewritten when nothing moved.
mod_seat_env_apply() { # <name>
  local file cur next own tmp
  file=$(_mod_seat_settings "${1:-}")
  [[ -f "$file" ]] || return 1
  cur=$(cat "$file" 2>/dev/null) || return 1
  [[ -n "${cur//[[:space:]]/}" ]] || cur='{}'
  next=$(jq --arg k "$MOD_SEAT_HOOKS_ENV" '
      if (type != "object") or ((.env // {}) | type != "object") then error("not an object") else . end
      | .env = (.env // {})
      | if (.env | has($k)) then . else .env[$k] = "1" end' <<<"$cur" 2>/dev/null) || return 1
  if jq -n -e --argjson x "$cur" --argjson y "$next" '$x == $y' >/dev/null 2>&1; then
    printf 'unchanged\n'; return 0
  fi
  own=$(stat -c '%U:%G' "$file" 2>/dev/null) || return 1
  tmp=$(mktemp -p "$(dirname "$file")" .modseat.XXXXXX) || return 1
  printf '%s\n' "$next" >"$tmp" || { rm -f "$tmp"; return 1; }
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  printf 'changed\n'
}

# mod_seat_ensure <name> -> seat the mod on one claude seat. Registration is
# skipped when the seat already carries the plugin (re-running `plugin install`
# rewrites installed_plugins.json, which self-update fingerprints).
mod_seat_ensure() { # <name>
  local name="${1:-}"
  if ! plugin_seat_registered "$name" "$MOD_SEAT_PLUGIN" "$MOD_SEAT_MARKETPLACE"; then
    plugin_seat_register_claude "$name" "$MOD_SEAT_PLUGIN" "$MOD_SEAT_MARKETPLACE" || return 1
  fi
  mod_seat_env_apply "$name" >/dev/null
}

# mod_seat_claude_rows -> registry rows of type claude whose home exists.
mod_seat_claude_rows() {
  local name type
  while IFS=$'\t' read -r name type; do
    [[ -n "$name" && "$type" == claude ]] || continue
    plugin_seat_home_exists "$name" || continue
    printf '%s\n' "$name"
  done < <(plugin_seat_rows)
}

# ---------------------------------------------------------------------------
# The load check. A settings.json that names the plugin is not a plugin that
# loaded: after a Claude Code upgrade the engine can refuse the module and the
# seat runs unguarded while every file still says it is guarded. The reading is
# a REAL load: `claude -p /cost` as the seat, answered locally ($0, no model call,
# ~3s on 2.1.281), writing the engine's "hooks module mod@5dive-plugins loaded"
# line to a debug file.
# ---------------------------------------------------------------------------

MOD_SEAT_LOADED_RE='hooks module mod@5dive-plugins loaded'

# mod_seat_probe_run <name> <debug-file> — the one privilege drop, stubbed by the
# unit suite.
# - NO MCP SERVER STARTS (--strict-mcp-config + an empty --mcp-config). The first
#   version of this probe started the seat's channel plugins: this shell has no
#   channel secret (the unit launcher injects it; sudo does not), telegram failed,
#   Claude Code cached that in mcp-needs-auth-cache.json and SKIPPED the server for
#   15 minutes on every session the seat started — main and marketing went deaf on
#   2026-09-24. Where the token WAS reachable it connected a second telegram poller
#   beside the live one. Strict mode starts zero MCP servers and the mod still
#   loads (measured on 2.1.281).
# - STDIN IS /dev/null: the caller walks seats in a `while read` loop, and claude
#   reading the loop's stdin ate every seat after the first (measured: 1 of 10).
# - NOT a login shell, CLAUDE_CONFIG_DIR unset: a login shell reads the claude
#   user's config (plugin_seats.sh's header).
mod_seat_probe_run() { # <name> <debug-file>
  local user="agent-${1:-}" dbg="${2:-}"
  sudo -u "$user" -H env -u CLAUDE_CONFIG_DIR DBG="$dbg" \
    timeout "${MOD_SEAT_PROBE_TIMEOUT:-45}" bash -c '
      export NVM_DIR=/home/claude/.nvm; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
      export PATH="/home/claude/.local/bin:$PATH"
      CLAUDE="${CLAUDE_BIN:-/home/claude/.local/bin/claude}"
      [ -x "$CLAUDE" ] || CLAUDE="$(command -v claude 2>/dev/null || echo "$CLAUDE")"
      cd "$HOME" || exit 1
      exec "$CLAUDE" -p /cost --no-session-persistence \
        --strict-mcp-config --mcp-config "{\"mcpServers\":{}}" --debug-file "$DBG" >/dev/null 2>&1' \
    </dev/null >/dev/null 2>&1
}

# mod_seat_probe <name> -> "loaded" | "not-loaded<TAB><why>", the why naming the
# first missing gate, cheapest first.
mod_seat_probe() { # <name>
  local name="${1:-}" dir dbg settings why="" line cache had=0
  settings=$(_mod_seat_settings "$name")
  # A DIRECTORY the seat owns: under fs.protected_regular a seat cannot open a
  # root-made file in sticky /tmp for writing.
  dir=$(mktemp -d /tmp/5dive-modprobe.XXXXXX) || { printf 'not-loaded\tcould not create a probe directory\n'; return 0; }
  chown "agent-${name}" "$dir" 2>/dev/null || true
  dbg="$dir/debug.log"
  # Belt and braces for the MCP note above: the seat's needs-auth cache is left
  # exactly as found — restored byte for byte if it existed, removed if it did
  # not (removal is the safe verb, DIVE-4852).
  cache="$(dirname "$settings")/mcp-needs-auth-cache.json"
  [[ -f "$cache" ]] && cp -p "$cache" "$dir/mcp-cache.bak" 2>/dev/null && had=1
  mod_seat_probe_run "$name" "$dbg" || true
  if (( had )); then cp -p "$dir/mcp-cache.bak" "$cache" 2>/dev/null || rm -f "$cache"; else rm -f "$cache"; fi
  if grep -qF "$MOD_SEAT_LOADED_RE" "$dbg" 2>/dev/null; then
    rm -rf "$dir"; printf 'loaded\n'; return 0
  fi
  if ! plugin_seat_registered "$name" "$MOD_SEAT_PLUGIN" "$MOD_SEAT_MARKETPLACE"; then
    why="the plugin is not installed for this seat"
  elif [[ "$(jq -r --arg k "$MOD_SEAT_HOOKS_ENV" '.env[$k] // ""' "$settings" 2>/dev/null)" != 1 ]]; then
    why="$MOD_SEAT_HOOKS_ENV is not 1 in the seat's settings.json"
  elif [[ ! -s "$dbg" ]]; then
    why="the probe produced no debug log (claude did not start as this seat)"
  else
    line=$(grep -m1 -iE 'mod@5dive-plugins.*(fail|refus|error|reject)' "$dbg" 2>/dev/null | cut -c1-200) || line=""
    why="${line:-installed and enabled, but the engine did not load it}"
  fi
  rm -rf "$dir"
  printf 'not-loaded\t%s\n' "$why"
}

# doctor_check_mod_seats — `doctor --category=mod`. Switch off: one line, and no
# seat is probed (nothing starts, nothing is touched). Switch on: one line per
# claude seat, and a seat that did not load is an ERROR — the nightly Claude Code
# upgrade reads summary.errors and pages ops.
doctor_check_mod_seats() {
  local name r why n=0
  if ! mod_seat_enabled; then
    doctor_add mod seating ok "mod seating is off on this box — nothing probed (5dive config mod-seat=on turns it on)"
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    r=$(mod_seat_probe "$name")
    if [[ "$r" == loaded ]]; then
      doctor_add mod "seat-$name" ok "$name: mod loaded"
    else
      why="${r#not-loaded}"; why="${why#$'\t'}"
      doctor_add mod "seat-$name" error \
        "$name: mod NOT loaded — ${why:-unknown}. The seat runs without the tool-call guard." \
        false false
    fi
  done < <(mod_seat_claude_rows)
  (( n )) || doctor_add mod seats ok "no claude seat on this box — nothing to probe"
}
