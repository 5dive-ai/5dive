# --- grok (DIVE-7066) ----------------------------------------------------------
# The server OWNER's own opt-in to Grok agents. `agent create --type=grok`
# refuses unless /etc/5dive/arm/grok-unfreeze exists (cmd_agent_create.sh,
# DIVE-1221/3185). Managed provisioning writes that marker for our fleet; a
# self-hosted box had no sanctioned way to get it, so Grok was managed-only.
# lodar (2026-10-27, Yes tap) sanctioned an owner writing it here, after ONE
# plain warning, because the xAI upload path is still live (the per-turn
# memory.tar.gz) and the owner must accept that knowingly.
#
# `enable` asks y/N on a terminal and nowhere else: no --yes, no env bypass, and
# an agent seat (agent-*) is refused even on a terminal. Like the marker itself
# this is a SPEED BUMP, not a security boundary — root can write the file by
# hand — what it buys is that an agent cannot click through the warning for the
# owner by accident or by habit. `disable` removes the marker; the guard keys on
# PRESENCE, and it gates CREATE only, so Grok agents already made keep running.
#
# FIVE_GROK_ARM_MARKER is the same test seam the create guard reads.
GROK_ENABLE_CMD="sudo 5dive grok enable"
GROK_WARNING="Grok's tool sends your agent's notes and chat turns to xAI after every turn."

_grok_marker() { printf '%s' "${FIVE_GROK_ARM_MARKER:-/etc/5dive/arm/grok-unfreeze}"; }
_grok_on_tty() { [[ -t 0 ]]; }   # seam for the harness

cmd_grok() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    enable)  cmd_grok_enable "$@" ;;
    disable) cmd_grok_disable "$@" ;;
    status)  cmd_grok_status "$@" ;;
    ""|-h|--help|help)
      printf '%s\n' "usage: 5dive grok enable | disable | status" \
        "  enable   let this server make Grok agents (asks you to confirm a warning first)" \
        "  disable  stop making new Grok agents (existing ones keep running)" \
        "  status   say whether Grok agents can be made here" ;;
    *) fail "$E_USAGE" "unknown grok command: $sub (enable | disable | status)" ;;
  esac
}

cmd_grok_status() {
  local m; m=$(_grok_marker)
  if [[ -e "$m" ]]; then
    ok "Grok is on: this server can make Grok agents" '{enabled:true}'
  else
    ok "Grok is off. To turn it on, run: $GROK_ENABLE_CMD" '{enabled:false}'
  fi
}

cmd_grok_enable() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "grok enable takes no options — it asks you to confirm instead"
  require_root grok enable
  local m; m=$(_grok_marker)
  if [[ -e "$m" ]]; then ok "Grok is already on" '{enabled:true}'; return 0; fi
  local who; who=$(actor_routing_agent) || who=""
  [[ -z "$who" ]] || fail "$E_PERMISSION" "only the server owner can turn Grok on. Ask them to run: $GROK_ENABLE_CMD"
  _grok_on_tty || fail "$E_PERMISSION" "turning Grok on needs the server owner to confirm at a terminal. Run: $GROK_ENABLE_CMD"
  printf 'Warning: %s\n' "$GROK_WARNING" >&2
  printf 'Turn Grok on for this server? [y/N] ' >&2
  local ans=""; IFS= read -r ans || true
  case "$ans" in
    y|Y|yes|YES|Yes) ;;
    *) ok "Grok stays off" '{enabled:false}'; return 0 ;;
  esac
  mkdir -p "$(dirname "$m")" || fail "$E_GENERIC" "cannot create $(dirname "$m")"
  printf 'owner opt-in via 5dive grok enable (DIVE-7066) %s\n' "$(date -u +%FT%TZ)" >"$m" \
    || fail "$E_GENERIC" "cannot write $m"
  ok "Grok is on: you can now make Grok agents" '{enabled:true}'
}

cmd_grok_disable() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "grok disable takes no options"
  require_root grok disable
  local m; m=$(_grok_marker)
  if [[ ! -e "$m" ]]; then ok "Grok is already off" '{enabled:false}'; return 0; fi
  rm -f "$m" || fail "$E_GENERIC" "cannot remove $m"
  ok "Grok is off: no new Grok agents. Grok agents you already have keep running." '{enabled:false}'
}
