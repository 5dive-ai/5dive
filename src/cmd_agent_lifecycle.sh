cmd_restart() {
  local name="" defer=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --defer) defer=1 ;;
      -*)      fail "$E_USAGE" "unknown flag: $1" ;;
      *)       [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent restart <name> [--defer]"
  require_agent "$name"
  if (( defer )); then
    # DIVE-1002: CLI-mediated deferred restart. `sudo 5dive` already runs as
    # root, so the CLI fires systemd-run internally — an (scoped-)admin agent
    # can restart itself via `sudo 5dive agent restart <self> --defer` and never
    # needs a raw `sudo systemd-run` grant (which is arbitrary root). The ~1s
    # transient unit survives the caller's own session teardown, so an agent
    # restarting itself (e.g. after editing model/effort) doesn't SIGTERM the
    # restart mid-flight.
    systemd-run --on-active=1 --collect \
      /bin/systemctl restart "5dive-agent@${name}.service" >&2
    ok "agent '$name' restart scheduled (deferred ~1s)." \
       '{name:$n, action:"restart", deferred:true}' --arg n "$name"
  else
    systemctl restart "5dive-agent@${name}.service" >&2
    ok "agent '$name' restarted." \
       '{name:$n, action:"restart"}' --arg n "$name"
  fi
}

cmd_rm() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent rm <name>"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local rm_profile
  rm_profile=$(jq -r --arg n "$name" '.agents[$n].authProfile // empty' <<<"$reg")
  step "Stopping 5dive-agent@${name}.service"
  systemctl disable --now "5dive-agent@${name}.service" 2>/dev/null || true
  step "Removing systemd env + channel secrets"
  rm -f "${ENV_DIR}/${name}.env" "${ENV_DIR}/${name}-auth.env"
  remove_channel_secret telegram "$name"
  remove_channel_secret discord  "$name"
  step "Deleting user agent-${name}"
  delete_agent_user "$name"
  step "Updating registry"
  jq --arg n "$name" 'del(.agents[$n])' <<<"$reg" | registry_write
  # Drop any paperclip-shared symlinks pointing into this agent's profile
  # and re-seed from another agent of the same type if one remains. Best-
  # effort — never fails the remove.
  [[ -n "$rm_profile" ]] && paperclip_unseed_for_profile "$rm_profile" 2>/dev/null || true
  ok "agent '$name' removed." \
     '{name:$n, removed:true}' --arg n "$name"
}

# DIVE-345: move a path aside as <path>.disabled-<ts> (reversible) if present.
_td_move_aside() {
  local p="$1" ts="$2"
  [[ -e "$p" ]] || return 0
  if mv "$p" "${p}.disabled-${ts}" 2>/dev/null; then
    step "disabled stale telegram wiring: $(basename "$p") -> $(basename "$p").disabled-${ts}"
  else
    warn "teardown: couldn't move $p aside (best-effort)"
  fi
}

# DIVE-345: strip the per-type telegram wiring left on disk when an agent's
# channel is removed (`config set channels=none`). 5dive-agent-start only ever
# ADDED telegram wiring (gated on CHANNELS=telegram) and never removed it, so a
# stale MCP tool cache / channel-state dir survived and the agent re-entered the
# telegram wait_for_message loop on the next boot despite channels=none (agy,
# 2026-06-13). We kill any running relay and move the wiring aside (reversible),
# but KEEP the connector secret (telegram-<name>.env) so re-enabling is a
# one-flag `config set channels=telegram`. `agent rm` still removes the secret
# for full teardown. Removing the per-type channel STATE dir (token/access) is
# what actually breaks the loop — a leftover codex/grok config.toml
# [mcp_servers.telegram] block is then inert (its server can't auth without the
# state), so we avoid fragile in-place TOML edits here.
teardown_telegram_wiring() {
  local name="$1" type="$2"
  local home="/home/agent-${name}"   # separate line: same-`local` ${name} would be empty
  [[ -d "$home" ]] || return 0
  local ts pidf p
  ts=$(date +%Y%m%d%H%M%S)
  # Kill any running telegram relay/bot process (bot.pid in the per-type dir).
  for pidf in \
    "$home/.gemini/channels/telegram/bot.pid" \
    "$home/.codex/channels/telegram/bot.pid" \
    "$home/.grok/channels/telegram/bot.pid" \
    "$home/.claude/channels/telegram/bot.pid" \
    "$home/.opencode/channels/telegram/bot.pid"; do
    [[ -r "$pidf" ]] || continue
    p=$(tr -dc '0-9' < "$pidf" 2>/dev/null)
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  case "$type" in
    antigravity)
      # antigravity re-exposes telegram tools from its MCP tool cache dir even
      # with no live server, so the agent keeps calling wait_for_message.
      _td_move_aside "$home/.gemini/antigravity-cli/mcp/telegram" "$ts"
      _td_move_aside "$home/.gemini/channels/telegram" "$ts" ;;
    codex)    _td_move_aside "$home/.codex/channels/telegram" "$ts" ;;
    grok)     _td_move_aside "$home/.grok/channels/telegram" "$ts" ;;
    claude)   _td_move_aside "$home/.claude/channels/telegram" "$ts" ;;
    opencode) _td_move_aside "$home/.opencode/channels/telegram" "$ts" ;;
  esac
  return 0
}

