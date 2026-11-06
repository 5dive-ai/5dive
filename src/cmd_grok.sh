# --- grok (DIVE-7066, DIVE-7802) ---------------------------------------------
# Grok agents are ON by default on every server (lodar 2026-11-06, DIVE-7802:
# "dont gate it" — owners have no terminal, so an opt-in step they had to type
# was a wall). This replaces DIVE-7066's owner opt-in (enable wrote
# /etc/5dive/arm/grok-unfreeze after a y/N). That marker is no longer read.
#
# What stays: the warning, as a note on every Grok create (cmd_agent_create.sh),
# and the owner's OPT-OUT. `disable` writes an off marker that `agent create`,
# `agent switch --to=grok` and `5dive init` respect; `enable` removes it. The
# xAI upload path is still live (the per-turn memory.tar.gz) — that is why the
# note and the off switch exist. Both gate CREATE/SWITCH only: Grok agents
# already made keep running after `disable`.
#
# FIVE_GROK_OFF_MARKER is a test seam (the harness pins it), not a control.
GROK_WARNING="Grok's tool sends your agent's notes and chat turns to xAI after every turn."
GROK_ENABLE_CMD="sudo 5dive grok enable"

_grok_off_marker() { printf '%s' "${FIVE_GROK_OFF_MARKER:-/etc/5dive/arm/grok-off}"; }
# The one predicate create, switch and init read: on unless the owner turned it off.
grok_is_on() { [[ ! -e "$(_grok_off_marker)" ]]; }
GROK_OFF_MSG="Grok is turned off on this server (the owner turned it off). To turn it back on: $GROK_ENABLE_CMD"

cmd_grok() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    enable)  cmd_grok_enable "$@" ;;
    disable) cmd_grok_disable "$@" ;;
    status)  cmd_grok_status "$@" ;;
    ""|-h|--help|help)
      printf '%s\n' "usage: 5dive grok enable | disable | status" \
        "  Grok agents are on by default. $GROK_WARNING" \
        "  disable  stop making new Grok agents here (existing ones keep running)" \
        "  enable   undo disable" \
        "  status   say whether Grok agents can be made here" ;;
    *) fail "$E_USAGE" "unknown grok command: $sub (enable | disable | status)" ;;
  esac
}

cmd_grok_status() {
  if grok_is_on; then
    ok "Grok is on: this server can make Grok agents. $GROK_WARNING" '{enabled:true}'
  else
    ok "Grok is off: the owner turned it off. To turn it back on, run: $GROK_ENABLE_CMD" '{enabled:false}'
  fi
}

cmd_grok_enable() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "grok enable takes no options"
  local m; m=$(_grok_off_marker)
  # Posts and guides still quote `sudo 5dive grok enable` (the DIVE-7066 step), so
  # on a server where Grok is on it must stay a harmless yes, from any seat.
  if [[ ! -e "$m" ]]; then ok "Grok is already on" '{enabled:true}'; return 0; fi
  require_root grok enable
  # Off is the owner's own choice; an agent seat does not undo it for them.
  local who; who=$(actor_routing_agent) || who=""
  [[ -z "$who" ]] || fail "$E_PERMISSION" "the server owner turned Grok off; only they can turn it back on"
  rm -f "$m" || fail "$E_GENERIC" "cannot remove $m"
  ok "Grok is on: you can make Grok agents again. $GROK_WARNING" '{enabled:true}'
}

cmd_grok_disable() {
  [[ $# -eq 0 ]] || fail "$E_USAGE" "grok disable takes no options"
  require_root grok disable
  local m; m=$(_grok_off_marker)
  if [[ -e "$m" ]]; then ok "Grok is already off" '{enabled:false}'; return 0; fi
  mkdir -p "$(dirname "$m")" || fail "$E_GENERIC" "cannot create $(dirname "$m")"
  printf 'owner opt-out via 5dive grok disable (DIVE-7802) %s\n' "$(date -u +%FT%TZ)" >"$m" \
    || fail "$E_GENERIC" "cannot write $m"
  ok "Grok is off: no new Grok agents. Grok agents you already have keep running." '{enabled:false}'
}
