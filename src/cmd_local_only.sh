# ── DIVE-7557: `sudo 5dive config local-only on|off|status|check` ────────────
#
# The WRITE side of local-only mode (the read side and every refusal are in
# src/lib/local_only.sh). One command turns off everything on the box that dials
# out on its own, and `check` proves it with a live connection watch.
#
# ON, in this order:
#   1. the flag file /etc/5dive/local-only — FIRST, so the refusals hold even if
#      a later OS step fails (fail closed);
#   2. agent runtime: a drop-in on 5dive-agent@.service sets
#      LOCAL_ONLY_CLAUDE_ENV + LOCAL_MODEL_SEAT_ENV (src/lib/local_only.sh) for
#      every seat (telemetry, error reports, auto-update, feature flags), and
#      /etc/codex/managed_config.toml turns off codex's update check, analytics
#      and feedback (codex has no env knob for these; the managed layer wins
#      over each seat's own config.toml);
#   3. 5dive's own nightly self-update timer, if the owner had turned it on;
#   4. the OS: unattended-upgrades + apt timers, snap refresh (held), motd-news,
#      apport/whoopsie, ubuntu-advantage/landscape, fwupd refresh, and NTP —
#      pointed at a LAN server with --ntp=<host>, else timesyncd off.
#
# UNDO RECORD. Every change `on` makes is one line in /etc/5dive/local-only.undo,
# and `off` reverses exactly those lines and nothing else. A timer the owner had
# switched off before is never in the record, so `off` never turns it on. A
# second `on` adds only what is new.
#
# Test seams: FIVE_LOCAL_ONLY_ROOT prefixes every path this file writes, and
# systemctl/snap/ss are looked up on PATH, so the harness runs against a scratch
# tree with stubs and never touches the host.

_lo_root()  { printf '%s' "${FIVE_LOCAL_ONLY_ROOT:-}"; }
_lo_undo()  { printf '%s/etc/5dive/local-only.undo' "$(_lo_root)"; }
_lo_dropin(){ printf '%s/etc/systemd/system/5dive-agent@.service.d/5dive-local-only.conf' "$(_lo_root)"; }
_lo_codex() { printf '%s/etc/codex/managed_config.toml' "$(_lo_root)"; }
_lo_ntpconf(){ printf '%s/etc/systemd/timesyncd.conf.d/5dive-local-only.conf' "$(_lo_root)"; }
_lo_motd()  { printf '%s/etc/default/motd-news' "$(_lo_root)"; }

# Units that dial out on a stock Ubuntu server. Only an ENABLED one is touched.
LO_OS_UNITS=(
  apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
  motd-news.timer update-notifier-download.timer update-notifier-motd.timer
  apport.service whoopsie.service
  ua-timer.timer ubuntu-advantage.service landscape-client.service
  fwupd-refresh.timer snapd.snap-repair.timer
)

_lo_have() { command -v "$1" >/dev/null 2>&1; }
_lo_unit_state() { _lo_have systemctl || { printf 'absent'; return 0; }
  local s; s=$(systemctl is-enabled "$1" 2>/dev/null) || true; printf '%s' "${s:-absent}"; }
_lo_record() {   # <line> — append once
  local f; f=$(_lo_undo)
  grep -qxF -- "$1" "$f" 2>/dev/null || printf '%s\n' "$1" >> "$f"
}

# DIVE-7573: the drop-in's whole body, from the two lists in local_only.sh. D4:
# every seat on a local-only box runs a local model, so tool search is off.
_lo_dropin_body() {
  local e
  printf '%s\n' "# 5dive local-only (DIVE-7557): no telemetry, error reports, auto-update or" \
    "# feature-flag calls from the agent runtime; tool search off for local models" \
    "# (DIVE-7573). Removed by: 5dive config local-only off" \
    "[Service]"
  for e in "${LOCAL_ONLY_CLAUDE_ENV[@]}" "${LOCAL_MODEL_SEAT_ENV[@]}"; do printf 'Environment=%s\n' "$e"; done
}

# Every Claude Code seat home on the box: the agents and the claude user.
_lo_seat_homes() {
  local h
  for h in "$(_lo_root)"/home/agent-* "$(_lo_root)/home/claude"; do
    [[ -f "$h/.claude/settings.json" || -f "$h/.claude/plugins/known_marketplaces.json" ]] && printf '%s\n' "$h"
  done
  return 0
}

# Names of the GitHub/git marketplaces a seat still knows, comma-joined; empty = none.
_lo_seat_remote_mkts() { # <home>
  local out="" sel='to_entries[] | select((.value.source.source // "") != "directory") | .key'
  [[ -f "$1/.claude/settings.json" ]] \
    && out+=$(jq -r "(.extraKnownMarketplaces // {}) | $sel" "$1/.claude/settings.json" 2>/dev/null | tr '\n' ' ')
  [[ -f "$1/.claude/plugins/known_marketplaces.json" ]] \
    && out+=" "$(jq -r "$sel" "$1/.claude/plugins/known_marketplaces.json" 2>/dev/null | tr '\n' ' ')
  printf '%s' "$out" | tr ' ' '\n' | sort -u | grep -v '^$' | paste -sd, - 2>/dev/null || true
}

_lo_usage() {
  printf '%s\n' \
    "usage: sudo 5dive config local-only on [--ntp=<office time server>] [--no-chat]" \
    "       sudo 5dive config local-only off" \
    "            5dive config local-only status" \
    "            5dive config local-only check [--watch=<seconds>]   # default 60; 0 = no watch" \
    "" \
    "Local-only mode: nothing on this box connects outside your network. It refuses" \
    "Telegram, a2a, cloud AI models, updates and installs from the internet, and turns" \
    "off the system's own background calls (updates, crash reports, time sync)." \
    "AI models must run on your network: agent create --base-url=http://<lan-ip>:<port>/…"
}

cmd_local_only() {
  local verb="${1:-status}"; shift || true
  case "$verb" in
    on)     _lo_on "$@" ;;
    off)    _lo_off "$@" ;;
    status) _lo_check --watch=0 --status "$@" ;;
    check)  _lo_check "$@" ;;
    -h|--help|help) _lo_usage ;;
    *) fail "$E_USAGE" "unknown local-only verb '$verb' (on, off, status or check)" ;;
  esac
}

_lo_on() {
  local ntp="" chat=1 a
  for a in "$@"; do
    case "$a" in
      --ntp=*) ntp="${a#--ntp=}" ;;
      --no-chat) chat=0 ;;   # DIVE-7558: leave the office chat off
      *) fail "$E_USAGE" "unknown flag: $a (see: 5dive config local-only --help)" ;;
    esac
  done
  if [[ -n "$ntp" ]]; then
    _lo_host_is_local "$ntp" \
      || fail "$E_VALIDATION" "--ntp must be a time server on your network (a private address or a .lan/.local name), got '${ntp:0:80}'"
  fi
  require_root
  if [[ -z "$(_lo_root)" && -f "${SELF_UPDATE_PROVISIONING:-/etc/5dive/provisioning.env}" ]]; then
    fail "$E_CONFLICT" "this box is run by 5dive's cloud, so it cannot be cut off from it. Local-only mode is for a server you host yourself. Nothing changed."
  fi
  local flag; flag="$(local_only_file)"
  mkdir -p "$(dirname "$flag")" "$(dirname "$(_lo_undo)")" || fail "$E_GENERIC" "could not create $(dirname "$flag")"
  # 1. the switch, first.
  printf 'on since %s — turn off: sudo 5dive config local-only off\n' "$(date -u +%FT%TZ)" > "$flag" \
    || fail "$E_GENERIC" "could not write $flag"
  chmod 0644 "$flag" 2>/dev/null || true
  touch "$(_lo_undo)"; chmod 0600 "$(_lo_undo)" 2>/dev/null || true
  local warned=0

  # 2a. every seat's runtime env. DIVE-7573: rewritten when it differs, so a
  # box that turned the mode on before tool search was added gets it too.
  local di; di=$(_lo_dropin)
  local want; want=$(_lo_dropin_body)
  if [[ ! -f "$di" ]] || [[ "$(cat "$di" 2>/dev/null)" != "$want" ]]; then
    local had=0; [[ -f "$di" ]] && had=1
    mkdir -p "$(dirname "$di")"
    printf '%s\n' "$want" > "$di" && { (( had )) || _lo_record "file $di"; }
  fi
  # 2c. DIVE-7573 (D3): every seat's plugin marketplaces become its own
  # checkouts, so no session start refreshes them from GitHub.
  local h
  while IFS= read -r h; do
    seat_marketplaces_local "$h" on
  done < <(_lo_seat_homes)
  _lo_record "seat-marketplaces"
  # 2b. codex. An existing managed config is the owner's: never overwritten.
  local cx; cx=$(_lo_codex)
  if [[ ! -e "$cx" ]]; then
    mkdir -p "$(dirname "$cx")"
    printf '%s\n' "# 5dive local-only (DIVE-7557). Removed by: 5dive config local-only off" \
      "check_for_update_on_startup = false" "" "[analytics]" "enabled = false" "" \
      "[feedback]" "enabled = false" > "$cx" && _lo_record "file $cx"
  fi

  # 3. 5dive nightly self-update.
  if declare -F _su_nightly_is_on >/dev/null && _su_nightly_is_on; then
    _su_nightly_off >/dev/null 2>&1 && _lo_record "nightly" || { warn "could not turn off nightly self-update"; warned=1; }
  fi

  # 4. the OS.
  local u st
  for u in "${LO_OS_UNITS[@]}"; do
    st=$(_lo_unit_state "$u")
    [[ "$st" == enabled ]] || continue
    if systemctl disable --now "$u" >/dev/null 2>&1; then _lo_record "unit $u"
    else warn "could not turn off $u"; warned=1; fi
  done
  if _lo_have snap && ! grep -qxF "snap-hold" "$(_lo_undo)" 2>/dev/null; then
    if snap refresh --hold >/dev/null 2>&1; then _lo_record "snap-hold"
    else warn "could not hold snap refresh"; warned=1; fi
  fi
  local mf; mf=$(_lo_motd)
  if [[ -f "$mf" ]] && grep -q '^ENABLED=1' "$mf"; then
    sed -i 's/^ENABLED=1/ENABLED=0/' "$mf" && _lo_record "motd-news"
  fi
  if [[ -n "$ntp" ]]; then
    local nc; nc=$(_lo_ntpconf); mkdir -p "$(dirname "$nc")"
    printf '[Time]\nNTP=%s\nFallbackNTP=\n' "$ntp" > "$nc" && _lo_record "file $nc"
    _lo_have systemctl && systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
  else
    st=$(_lo_unit_state systemd-timesyncd.service)
    if [[ "$st" == enabled ]]; then
      if systemctl disable --now systemd-timesyncd.service >/dev/null 2>&1; then _lo_record "unit systemd-timesyncd.service"
      else warn "could not turn off time sync"; warned=1; fi
    fi
  fi
  _lo_have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
  # 5. DIVE-7558: the office chat, so the owner still has a chat page with the
  # hosted app out of reach. The switch is already in force when it fails (no
  # office address, no bun), and `local serve` can be re-run. DIVE-7566: but
  # then this never says plain ON and never exits 0: the owner would be left
  # with no chat and a green result (the DIVE-7560 proof run).
  local chat_failed=0
  if (( chat )) && _lo_chat_enabled; then
    if ( _lc_serve ); then _lo_record "local-chat"
    else chat_failed=1; fi
  fi

  if (( chat_failed )); then
    printf '%s\n' "Local-only mode is on, but the office chat did NOT start (the error is above), so there is no chat page yet." \
      "Fix it, then start the chat: sudo 5dive local serve --addr=<office IP>" >&2
    return "$E_GENERIC"
  fi
  printf '%s\n' "Local-only mode is ON. Nothing on this box will connect outside your network." \
    "Restart your agents once so they pick it up: sudo systemctl restart '5dive-agent@*'" \
    "Prove it any time: sudo 5dive config local-only check"
  (( warned )) && printf '%s\n' "Some system items could not be turned off (see the warnings above); check lists them."
  return 0
}

# The office chat step runs on a real box only; FIVE_LOCAL_ONLY_CHAT=1 lets the
# harness run it under FIVE_LOCAL_ONLY_ROOT with _lc_serve stubbed.
_lo_chat_enabled() { [[ -z "$(_lo_root)" || "${FIVE_LOCAL_ONLY_CHAT:-}" == 1 ]]; }

_lo_off() {
  (( $# == 0 )) || fail "$E_USAGE" "local-only off takes no flags"
  require_root
  local flag; flag="$(local_only_file)"
  local f; f=$(_lo_undo)
  local kind rest
  if [[ -f "$f" ]]; then
    # Reverse order: the last change is undone first.
    while IFS=' ' read -r kind rest; do
      case "$kind" in
        unit)      systemctl enable --now "$rest" >/dev/null 2>&1 || warn "could not turn $rest back on" ;;
        snap-hold) snap refresh --unhold >/dev/null 2>&1 || warn "could not release the snap hold" ;;
        motd-news) [[ -f "$(_lo_motd)" ]] && sed -i 's/^ENABLED=0/ENABLED=1/' "$(_lo_motd)" ;;
        nightly)   declare -F _su_nightly_on >/dev/null && { _su_nightly_on >/dev/null 2>&1 || warn "could not turn nightly self-update back on"; } ;;
        file)      rm -f -- "$rest" ;;
        local-chat) ( _lc_serve_stop ) >/dev/null 2>&1 || warn "could not stop the office chat" ;;
        seat-marketplaces)
          local h; while IFS= read -r h; do seat_marketplaces_local "$h" off; done < <(_lo_seat_homes) ;;
      esac
    done < <(tac "$f")
    rm -f -- "$f"
  fi
  _lo_have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
  _lo_have systemctl && [[ -z "$(_lo_root)" ]] && systemctl try-restart systemd-timesyncd >/dev/null 2>&1 || true
  rm -f -- "$flag"
  printf '%s\n' "Local-only mode is OFF. Everything it turned off is back as it was." \
    "Restart your agents once so they pick it up: sudo systemctl restart '5dive-agent@*'"
}

# One line per item: "ok    <item>  <state>" or "LEAK  <item>  <state>".
_lo_line() { printf '%-5s %-34s %s\n' "$1" "$2" "$3"; }

_lo_check() {
  local watch=60 status_only=0 a
  for a in "$@"; do
    case "$a" in
      --watch=*) watch="${a#--watch=}" ;;
      --status)  status_only=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a (see: 5dive config local-only --help)" ;;
    esac
  done
  [[ "$watch" =~ ^[0-9]+$ ]] && (( watch <= 3600 )) || fail "$E_VALIDATION" "--watch takes seconds, 0 to 3600"
  local bad=0 u st
  if local_only_on; then _lo_line ok "local-only switch" on
  else _lo_line LEAK "local-only switch" off; bad=1; fi
  if [[ -f "$(_lo_dropin)" ]]; then _lo_line ok "agent runtime background calls" off
  else _lo_line LEAK "agent runtime background calls" on; bad=1; fi
  # DIVE-7573 (D3): a seat that still names a GitHub marketplace looks it up at
  # every start.
  local h rm
  while IFS= read -r h; do
    rm=$(_lo_seat_remote_mkts "$h")
    if [[ -n "$rm" ]]; then _lo_line LEAK "plugin catalog refresh ($(basename "$h"))" "$rm"; bad=1
    else _lo_line ok "plugin catalog refresh ($(basename "$h"))" "local copy"; fi
  done < <(_lo_seat_homes)
  if [[ -f "$(_lo_codex)" ]] && grep -q 'check_for_update_on_startup *= *false' "$(_lo_codex)"; then
    _lo_line ok "codex update check + analytics" off
  else _lo_line LEAK "codex update check + analytics" on; bad=1; fi
  if declare -F _su_nightly_is_on >/dev/null && _su_nightly_is_on; then
    _lo_line LEAK "5dive nightly self-update" on; bad=1
  else _lo_line ok "5dive nightly self-update" off; fi
  for u in "${LO_OS_UNITS[@]}" systemd-timesyncd.service; do
    st=$(_lo_unit_state "$u")
    if [[ "$u" == systemd-timesyncd.service && -f "$(_lo_ntpconf)" ]]; then
      _lo_line ok "time sync" "office server $(sed -n 's/^NTP=//p' "$(_lo_ntpconf)")"; continue
    fi
    case "$st" in
      enabled) _lo_line LEAK "$u" on; bad=1 ;;
      absent|not-found) ;;            # not installed: nothing to say
      *) _lo_line ok "$u" off ;;
    esac
  done
  if _lo_have snap; then
    if grep -qxF snap-hold "$(_lo_undo)" 2>/dev/null; then _lo_line ok "snap auto-refresh" held
    else _lo_line LEAK "snap auto-refresh" on; bad=1; fi
  fi
  if [[ -f "$(_lo_motd)" ]] && grep -q '^ENABLED=1' "$(_lo_motd)"; then
    _lo_line LEAK "motd-news" on; bad=1
  fi
  (( status_only )) && return 0

  if (( watch > 0 )); then
    _lo_have ss || fail "$E_NOT_INSTALLED" "check needs 'ss' (iproute2) to watch connections"
    printf '\nWatching connections for %ss (anything that is not this box or your network counts)...\n' "$watch"
    local -A seen=()
    local i line peer host proc tick="${FIVE_LOCAL_ONLY_TICK:-1}"
    for (( i = 0; i < watch; i++ )); do
      while IFS= read -r line; do
        # Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
        read -r _ st _ _ _ peer proc <<<"$line"
        case "$st" in ESTAB|SYN-SENT|SYN-RECV) ;; *) continue ;; esac
        host="${peer%:*}"; host="${host#[}"; host="${host%]}"; host="${host%%%*}"
        [[ -n "$host" && "$host" != "*" ]] || continue
        _lo_host_is_local "$host" && continue
        seen["$peer ${proc:-}"]=1
      done < <(ss -tunpH 2>/dev/null)
      (( tick > 0 )) && sleep "$tick"
    done
    if (( ${#seen[@]} )); then
      printf 'LEAK  outside connections seen: %s\n' "${#seen[@]}"
      printf '      %s\n' "${!seen[@]}" | sort
      bad=1
    else
      printf 'ok    no outside connections in %ss\n' "$watch"
    fi
  fi
  if (( bad )); then printf '\nNOT fully local — fix the LEAK lines above.\n'; mark_reported; return 1; fi
  printf '\nFully local: nothing on this box is connecting outside your network.\n'
  return 0
}
