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
#   4. the OS: unattended-upgrades + apt timers, snapd (masked when no snap is
#      installed, else refresh held + store offline, DIVE-7574), motd-news,
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
_lo_hosts() { printf '%s/etc/hosts' "$(_lo_root)"; }

# DIVE-7730: names an agent runtime looks up with no switch to stop it, so the
# box answers them itself (0.0.0.0 / ::) and the lookup never leaves. Measured
# on a firewalled box: openclaw 2026.10.10 resolves clawhub.ai (its plugin feed)
# at every gateway start, before and regardless of any proxy setting.
LO_HOSTS_NAMES=(clawhub.ai)
LO_HOSTS_BEGIN="# >>> 5dive local-only (DIVE-7730): names answered on this box. Removed by: 5dive config local-only off"
LO_HOSTS_END="# <<< 5dive local-only"
_lo_hosts_block() {
  local n; printf '%s\n' "$LO_HOSTS_BEGIN"
  for n in "${LO_HOSTS_NAMES[@]}"; do printf '0.0.0.0 %s\n:: %s\n' "$n" "$n"; done
  printf '%s\n' "$LO_HOSTS_END"
}
# Drop our block from the hosts file, in place (owner, mode and every other
# line kept). Prints nothing; never fails the caller.
_lo_hosts_strip() {
  local h; h=$(_lo_hosts); [[ -f "$h" ]] || return 0
  grep -qxF -- "$LO_HOSTS_BEGIN" "$h" || return 0
  local body; body=$(awk -v b="$LO_HOSTS_BEGIN" -v e="$LO_HOSTS_END" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' "$h") || return 0
  printf '%s\n' "$body" > "$h"
}

# Units that dial out on a stock Ubuntu server. Only an ENABLED one is touched.
LO_OS_UNITS=(
  apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
  motd-news.timer update-notifier-download.timer update-notifier-motd.timer
  apport.service whoopsie.service
  ua-timer.timer ubuntu-advantage.service landscape-client.service
  fwupd-refresh.timer snapd.snap-repair.timer
)

# DIVE-7574: snapd's units, masked together on a box with no snap installed.
LO_SNAPD_UNITS=(snapd.service snapd.socket snapd.seeded.service)
# A snap is installed when snapd holds a .snap file for it (read from disk, so
# asking never wakes snapd).
_lo_snaps_installed() { compgen -G "$(_lo_root)/var/lib/snapd/snaps/*.snap" >/dev/null; }

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
  for e in "${LOCAL_ONLY_CLAUDE_ENV[@]}" "${LOCAL_ONLY_HARNESS_ENV[@]}" "${LOCAL_MODEL_SEAT_ENV[@]}"; do printf 'Environment=%s\n' "$e"; done
}

# DIVE-7730: codex's managed config (the layer that wins over each seat's own
# config.toml). The first three keys were DIVE-7557. Measured in a no-network
# sandbox on codex 0.153.3: with only those, every `codex exec` still looked up
# github.com + api.github.com (a `git ls-remote` of OpenAI's plugin catalog) and
# chatgpt.com (apps and remote plugins); with the [features] table below it
# looked up nothing outside the box. 5dive's codex seats use none of these.
_LO_CODEX_MARK="# 5dive local-only (DIVE-7557). Removed by: 5dive config local-only off"
_lo_codex_body() {
  printf '%s\n' "$_LO_CODEX_MARK" \
    "check_for_update_on_startup = false" "" "[analytics]" "enabled = false" "" \
    "[feedback]" "enabled = false" "" \
    "[features]" "plugins = false" "remote_plugin = false" "apps = false" \
    "in_app_updates = false" "plugin_sharing = false"
}
_lo_codex_is_ours() { [[ "$(head -n1 "$(_lo_codex)" 2>/dev/null)" == "$_LO_CODEX_MARK" ]]; }

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
    "       sudo 5dive config local-only allow|deny teams   # your IT opens Microsoft Teams alone" \
    "            5dive config local-only status" \
    "            5dive config local-only check [--watch=<seconds>]   # default 60; 0 = no watch" \
    "" \
    "Local-only mode: nothing on this box connects outside your network. It refuses" \
    "Telegram, a2a, cloud AI models, updates and installs from the internet, and turns" \
    "off the system's own background calls (updates, crash reports, time sync)." \
    "AI models must run on your network: agent create --base-url=http://<lan-ip>:<port>/…" \
    "" \
    "allow teams: the one outside service your IT may open. Only Teams messages go out," \
    "to Microsoft; everything above stays refused. deny teams shuts it again."
}

cmd_local_only() {
  local verb="${1:-status}"; shift || true
  case "$verb" in
    on)     _lo_on "$@" ;;
    off)    _lo_off "$@" ;;
    status) _lo_check --watch=0 --status "$@" ;;
    check)  _lo_check "$@" ;;
    allow)  _lo_allow on "$@" ;;    # DIVE-7658
    deny)   _lo_allow off "$@" ;;
    -h|--help|help) _lo_usage ;;
    *) fail "$E_USAGE" "unknown local-only verb '$verb' (on, off, status, check, allow or deny)" ;;
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
  # One we wrote (it starts with our marker) is brought up to date, so a box
  # that turned the mode on before DIVE-7730 loses its plugin-catalog lookups.
  local cx; cx=$(_lo_codex)
  if [[ ! -e "$cx" ]]; then
    mkdir -p "$(dirname "$cx")"
    _lo_codex_body > "$cx" && _lo_record "file $cx"
  elif _lo_codex_is_ours && [[ "$(cat "$cx" 2>/dev/null)" != "$(_lo_codex_body)" ]]; then
    _lo_codex_body > "$cx"
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
  # DIVE-7574 (N3): holding refreshes was not enough. Any wake of snapd (a
  # `snap` command, or snapd.seeded at every boot) made it ask the Snap Store
  # for its catalog: 141-144 blocked lookups each time in the DIVE-7560 run 3.
  # No snap installed: snapd has nothing to do, so it is masked (never started,
  # not even at boot). Snaps installed: snapd's own offline mode, plus the hold.
  if _lo_have snap || [[ -d "$(_lo_root)/var/lib/snapd" ]]; then
    if ! _lo_snaps_installed; then
      if ! grep -qxF "snapd-mask" "$(_lo_undo)" 2>/dev/null; then
        if systemctl mask --now "${LO_SNAPD_UNITS[@]}" >/dev/null 2>&1; then _lo_record "snapd-mask"
        else warn "could not turn off snapd"; warned=1; fi
      fi
    else
      if ! grep -qxF "snap-hold" "$(_lo_undo)" 2>/dev/null; then
        if snap refresh --hold >/dev/null 2>&1; then _lo_record "snap-hold"
        else warn "could not hold snap refresh"; warned=1; fi
      fi
      if ! grep -qxF "snap-offline" "$(_lo_undo)" 2>/dev/null; then
        if snap set system store.access=offline >/dev/null 2>&1; then _lo_record "snap-offline"
        else warn "could not put snapd offline"; warned=1; fi
      fi
    fi
  fi
  # 3c. DIVE-7730: names with no switch (LO_HOSTS_NAMES) answered on the box.
  local hf; hf=$(_lo_hosts)
  mkdir -p "$(dirname "$hf")"; [[ -e "$hf" ]] || : > "$hf"
  _lo_hosts_strip; _lo_hosts_block >> "$hf" && _lo_record "hosts"
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

# ── DIVE-7658: `allow|deny teams` — the firm's IT opens Microsoft Teams alone ──
# The box stays local-only: every other refusal holds. The teams plugin reads
# the same file at connect and on every message, so `deny` shuts it at once
# (the next message is refused, no reply goes out) without a restart.
_lo_allow() {   # on|off <name>
  local want="$1"; shift
  local name="${1:-}"
  [[ -n "$name" && $# -eq 1 ]] || fail "$E_USAGE" "usage: sudo 5dive config local-only allow|deny teams"
  [[ " ${LO_ALLOWABLE[*]} " == *" $name "* ]] \
    || fail "$E_VALIDATION" "only Microsoft Teams can be opened on a local-only box (got '${name:0:40}'): sudo 5dive config local-only allow teams"
  require_root
  local f; f=$(local_only_allow_file)
  if [[ "$want" == on ]]; then
    local_only_on || fail "$E_CONFLICT" "local-only mode is off, so Teams is not blocked here. Nothing changed."
    mkdir -p "$(dirname "$f")" || fail "$E_GENERIC" "could not create $(dirname "$f")"
    grep -qxF -- "$name" "$f" 2>/dev/null || printf '%s\n' "$name" >> "$f" || fail "$E_GENERIC" "could not write $f"
    chmod 0644 "$f" 2>/dev/null || true
    printf '%s\n' "Microsoft Teams is OPEN on this local-only box. Only Teams messages go out, to Microsoft; everything else stays offline." \
      "Connect an agent: sudo 5dive agent teams connect <agent> --app-id=<id> --tenant-id=<id> --endpoint=https://<address your IT publishes>" \
      "Shut it again: sudo 5dive config local-only deny teams"
  else
    if [[ -f "$f" ]]; then
      local rest; rest=$(grep -vxF -- "$name" "$f" || true)
      if [[ -n "$rest" ]]; then printf '%s\n' "$rest" > "$f"; else rm -f -- "$f"; fi
    fi
    printf '%s\n' "Microsoft Teams is SHUT. Agents refuse Teams messages from now on and send none."
  fi
  return 0
}

_lo_off() {
  (( $# == 0 )) || fail "$E_USAGE" "local-only off takes no flags"
  require_root
  local flag; flag="$(local_only_file)"
  local f; f=$(_lo_undo)
  local kind rest chat_kept=0
  if [[ -f "$f" ]]; then
    # Reverse order: the last change is undone first.
    while IFS=' ' read -r kind rest; do
      case "$kind" in
        unit)      systemctl enable --now "$rest" >/dev/null 2>&1 || warn "could not turn $rest back on" ;;
        snap-hold) snap refresh --unhold >/dev/null 2>&1 || warn "could not release the snap hold" ;;
        snap-offline) snap unset system store.access >/dev/null 2>&1 || warn "could not put snapd back online" ;;
        snapd-mask) { systemctl unmask "${LO_SNAPD_UNITS[@]}" && systemctl start snapd.socket; } >/dev/null 2>&1 \
                      || warn "could not turn snapd back on" ;;
        motd-news) [[ -f "$(_lo_motd)" ]] && sed -i 's/^ENABLED=0/ENABLED=1/' "$(_lo_motd)" ;;
        hosts)     _lo_hosts_strip ;;
        nightly)   declare -F _su_nightly_on >/dev/null && { _su_nightly_on >/dev/null 2>&1 || warn "could not turn nightly self-update back on"; } ;;
        file)      rm -f -- "$rest" ;;
        # DIVE-7598 (5): the office chat stays ON. It listens on the office
        # address only (_lc_lan_addr never picks a public one), so going online
        # for a Claude subscription exposes nothing, and stopping it left the
        # owner with no chat page. Stop it by hand: sudo 5dive local serve --stop
        local-chat) chat_kept=1 ;;
        seat-marketplaces)
          local h; while IFS= read -r h; do seat_marketplaces_local "$h" off; done < <(_lo_seat_homes) ;;
      esac
    done < <(tac "$f")
    rm -f -- "$f"
  fi
  _lo_have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
  _lo_have systemctl && [[ -z "$(_lo_root)" ]] && systemctl try-restart systemd-timesyncd >/dev/null 2>&1 || true
  rm -f -- "$flag"
  rm -f -- "$(local_only_allow_file)"   # DIVE-7658: the next `on` starts fully offline
  printf '%s\n' "Local-only mode is OFF. Everything it turned off is back as it was." \
    "Restart your agents once so they pick it up: sudo systemctl restart '5dive-agent@*'"
  (( chat_kept )) && printf '%s\n' "The office chat is still on, reachable from your network only. Stop it: sudo 5dive local serve --stop"
  return 0
}

# One line per item: "ok    <item>  <state>" or "LEAK  <item>  <state>".
# DIVE-7658: `_lo_proc_is_teams <ss process field>` — 0 when every pid in it is
# a teams plugin server (its working directory is the plugin, named teams).
# /proc is read under FIVE_LOCAL_ONLY_ROOT (the harness's seam); the link's
# target is taken as it is.
_lo_proc_is_teams() {
  local field="$1" pid cwd n=0
  [[ "$field" == *pid=* ]] || return 1
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    cwd=$(readlink "$(_lo_root)/proc/$pid/cwd" 2>/dev/null) || return 1
    [[ -f "$cwd/server.ts" ]] && grep -qE '"name"[[:space:]]*:[[:space:]]*"teams"' "$cwd/.claude-plugin/plugin.json" 2>/dev/null || return 1
    n=$((n + 1))
  done < <(grep -oE 'pid=[0-9]+' <<<"$field" | cut -d= -f2)
  (( n > 0 ))
}

# DIVE-7826: `_lo_proxy_is_teams <ss process field> <local addr:port>` — 0 when
# the connection is Microsoft reaching the Teams endpoint through this box's
# Caddy: the process is caddy, on its web port (443/80), and `agent teams
# connect` published a teams-<agent> route in the Caddyfile. Inbound to that
# route is the Teams traffic IT allowed, not the box dialing out.
_lo_caddyfile() { printf '%s/etc/caddy/Caddyfile' "$(_lo_root)"; }
_lo_proxy_is_teams() {
  local field="$1" lport="${2##*:}"
  [[ "$field" == *'(("caddy",'* ]] || return 1
  [[ "$lport" == 443 || "$lport" == 80 ]] || return 1
  grep -qE '^[[:space:]]*# 5dive-route:begin teams-[A-Za-z0-9_-]+ port=[0-9]+ ' "$(_lo_caddyfile)" 2>/dev/null
}

_lo_line() { printf '%-5s %-34s  %s\n' "$1" "$2" "$3"; }   # DIVE-7579 (m2): two spaces always (the panel splits on them)

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
  # DIVE-7658: the one service the firm's IT may open. Not a LEAK: it was asked for.
  if local_only_allows teams; then _lo_line ok "Microsoft Teams" "open (your IT allowed it)"
  else _lo_line ok "Microsoft Teams" shut; fi
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
  if [[ -f "$(_lo_codex)" ]] && grep -q 'check_for_update_on_startup *= *false' "$(_lo_codex)" \
     && grep -q '^plugins *= *false' "$(_lo_codex)"; then
    _lo_line ok "codex update check, analytics, plugin catalog" off
  else _lo_line LEAK "codex update check, analytics, plugin catalog" on; bad=1; fi
  if [[ -f "$(_lo_hosts)" ]] && grep -qxF -- "$LO_HOSTS_BEGIN" "$(_lo_hosts)"; then
    _lo_line ok "openclaw plugin feed (clawhub.ai)" "answered on this box"
  else _lo_line LEAK "openclaw plugin feed (clawhub.ai)" "looked up outside"; bad=1; fi
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
  if grep -qxF snapd-mask "$(_lo_undo)" 2>/dev/null; then
    _lo_line ok "snapd (no snaps installed)" off
  elif _lo_have snap; then
    if grep -qxF snap-hold "$(_lo_undo)" 2>/dev/null; then _lo_line ok "snap auto-refresh" held
    else _lo_line LEAK "snap auto-refresh" on; bad=1; fi
    # DIVE-7574: the catalog fetch at every snapd wake.
    if grep -qxF snap-offline "$(_lo_undo)" 2>/dev/null; then _lo_line ok "snap store" offline
    else _lo_line LEAK "snap store" online; bad=1; fi
  fi
  if [[ -f "$(_lo_motd)" ]] && grep -q '^ENABLED=1' "$(_lo_motd)"; then
    _lo_line LEAK "motd-news" on; bad=1
  fi
  (( status_only )) && return 0

  if (( watch > 0 )); then
    _lo_have ss || fail "$E_NOT_INSTALLED" "check needs 'ss' (iproute2) to watch connections"
    printf '\nWatching connections for %ss (anything that is not this box or your network counts)...\n' "$watch"
    local -A seen=() teams_seen=()
    local teams_open=0; local_only_allows teams && teams_open=1
    local i line laddr peer host proc tick="${FIVE_LOCAL_ONLY_TICK:-1}"
    for (( i = 0; i < watch; i++ )); do
      while IFS= read -r line; do
        # Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
        read -r _ st _ _ laddr peer proc <<<"$line"
        case "$st" in ESTAB|SYN-SENT|SYN-RECV) ;; *) continue ;; esac
        host="${peer%:*}"; host="${host#[}"; host="${host%]}"; host="${host%%%*}"
        [[ -n "$host" && "$host" != "*" ]] || continue
        _lo_host_is_local "$host" && continue
        # DIVE-7658: with Teams open, the teams plugin's own connections are
        # the allowed ones (it sends only to Microsoft's hosts, plugin hosts.ts).
        if (( teams_open )) && { _lo_proc_is_teams "${proc:-}" || _lo_proxy_is_teams "${proc:-}" "$laddr"; }; then
          teams_seen["$peer"]=1; continue
        fi
        seen["$peer ${proc:-}"]=1
      done < <(ss -tunpH 2>/dev/null)
      (( tick > 0 )) && sleep "$tick"
    done
    (( ${#teams_seen[@]} )) && printf 'ok    Microsoft Teams (your IT allowed it): %s connection(s)\n' "${#teams_seen[@]}"
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
