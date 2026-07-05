
# -------- watch (live multi-agent dashboard) --------
#
# htop-style live view of every registered agent. Refreshes every <interval>
# seconds (default 2s) inside the alt-screen so the user's scrollback is
# preserved on quit. Pure bash + ANSI — no curses, no extra deps beyond
# what the rest of the CLI already requires (bash, jq, systemctl, tput).
#
# Keys:
#   q / Ctrl-C    quit
#   r             refresh now
#   ↑ ↓ / k j     move selection
#   ↵             attach to selected agent (sudo -u agent-<name> tmux attach).
#                 Control returns to watch when the user detaches (Ctrl-b d).

WATCH_ALT_ON=$'\033[?1049h'
WATCH_ALT_OFF=$'\033[?1049l'
WATCH_HIDE=$'\033[?25l'
WATCH_SHOW=$'\033[?25h'
WATCH_HOME=$'\033[H'
WATCH_CLR_DOWN=$'\033[J'
WATCH_CLR_EOL=$'\033[K'
WATCH_RESET=$'\033[0m'
WATCH_BOLD=$'\033[1m'
WATCH_DIM=$'\033[2m'
WATCH_REV=$'\033[7m'
WATCH_GREEN=$'\033[32m'
WATCH_RED=$'\033[31m'
WATCH_YELLOW=$'\033[33m'
WATCH_GREY=$'\033[90m'
WATCH_CYAN=$'\033[36m'

# State dot for the leading column. Mirrors cmd_list's category set.
_watch_dot() {
  case "$1" in
    active)                              printf '%s●%s' "$WATCH_GREEN"  "$WATCH_RESET" ;;
    activating|deactivating|reloading)   printf '%s●%s' "$WATCH_YELLOW" "$WATCH_RESET" ;;
    failed)                              printf '%s●%s' "$WATCH_RED"    "$WATCH_RESET" ;;
    *)                                   printf '%s○%s' "$WATCH_GREY"   "$WATCH_RESET" ;;
  esac
}

# Seconds → "1d 17h" / "5h 23m" / "12m 04s" / "23s". "-" if unknown / 0.
_watch_uptime() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] && (( s > 0 )) || { printf -- '-'; return; }
  if   (( s < 60 ));    then printf '%ds' "$s"
  elif (( s < 3600 ));  then printf '%dm %02ds' $((s/60)) $((s%60))
  elif (( s < 86400 )); then printf '%dh %02dm' $((s/3600)) $(((s%3600)/60))
  else                       printf '%dd %02dh' $((s/86400)) $(((s%86400)/3600))
  fi
}

# Bytes → "342 MiB" / "1.2 GiB". "-" for [not set] / uint64 sentinel.
_watch_mem() {
  local b="${1:-}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf -- '-'; return; }
  [[ "$b" == "18446744073709551615" ]] && { printf -- '-'; return; }
  if   (( b < 1024 ));        then printf '%d B'   "$b"
  elif (( b < 1048576 ));     then printf '%d KiB' $((b/1024))
  elif (( b < 1073741824 ));  then printf '%d MiB' $((b/1048576))
  else awk -v n="$b" 'BEGIN{printf "%.1f GiB", n/1073741824}'
  fi
}

# One snapshot of all agents → JSON array. One systemctl show per agent;
# fine for the typical 1-10 range. If it ever bottlenecks we can swap in a
# single Python helper that batches the showed properties.
_watch_snapshot() {
  local reg now name svc props
  reg=$(registry_read)
  now=$(date +%s)
  local rows=""
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    svc="5dive-agent@${name}.service"
    props=$(systemctl show "$svc" \
      --property=ActiveState,SubState,NRestarts,ActiveEnterTimestamp,MemoryCurrent \
      --no-page 2>/dev/null || true)
    local active sub restarts ts_str mem
    active=$(awk   -F= '/^ActiveState=/{print $2}'         <<<"$props")
    sub=$(awk      -F= '/^SubState=/{print $2}'            <<<"$props")
    restarts=$(awk -F= '/^NRestarts=/{print $2}'           <<<"$props")
    ts_str=$(awk   -F= '/^ActiveEnterTimestamp=/{print $2}' <<<"$props")
    mem=$(awk      -F= '/^MemoryCurrent=/{print $2}'       <<<"$props")
    local uptime=0
    if [[ -n "$ts_str" && "$ts_str" != "n/a" && "$active" == "active" ]]; then
      local since
      since=$(date -d "$ts_str" +%s 2>/dev/null || echo "")
      [[ -n "$since" ]] && uptime=$((now - since))
    fi
    local type channels bot
    type=$(jq     -r --arg n "$name" '.agents[$n].type'                  <<<"$reg")
    channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'    <<<"$reg")
    bot=$(jq      -r --arg n "$name" '.agents[$n].botUsername // empty'  <<<"$reg")
    rows+=$(jq -cn \
      --arg name "$name" --arg type "$type" --arg channels "$channels" --arg bot "$bot" \
      --arg active "${active:-unknown}" --arg sub "${sub:-}" \
      --arg restarts "${restarts:-0}" --arg uptime "$uptime" --arg mem "${mem:-}" \
      '{name:$name, type:$type, channels:$channels, botUsername:$bot,
        active:$active, sub:$sub,
        restarts:($restarts|tonumber? // 0),
        uptime:($uptime|tonumber? // 0),
        mem:$mem}')
    rows+=$'\n'
  done
  printf '%s' "$rows" | jq -s -c '.'
}

# Visible width — strip ANSI before counting so padding stays correct.
_watch_visible_len() {
  local s="$1"
  s=$(printf '%s' "$s" | sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g')
  printf '%d' "${#s}"
}
_watch_pad_right() {
  local s="$1" w="$2" cur
  cur=$(_watch_visible_len "$s")
  if (( cur >= w )); then printf '%s' "$s"; return; fi
  printf '%s%*s' "$s" $((w - cur)) ""
}
# Truncate to N visible chars (assumes input has no embedded ANSI — color
# is added around the cell after truncation).
_watch_truncate() {
  local s="$1" w="$2"
  if (( ${#s} <= w )); then printf '%s' "$s"; return; fi
  printf '%s…' "${s:0:w-1}"
}

# Budget-pressure line (DIVE-1019). Reads the cheap state cache the heartbeat's
# budget sweep refreshes — NO transcript scan on the 2s frame. Empty string when
# no agent is over its soft cap / ceiling. Colored ⛔ (ceiling) / ⚠ (soft cap).
_watch_budget_line() {
  local f="${STATE_DIR}/usage-budget-state.json"
  [[ -s "$f" ]] || return 0
  local parts
  parts=$(jq -r '
    (.agents // {}) | to_entries
    | map(select(.value.state=="hard" or .value.state=="soft"))
    | sort_by(if .value.state=="hard" then 0 else 1 end)
    | .[] | (if .value.state=="hard" then "HARD " else "SOFT " end) + .key' \
    "$f" 2>/dev/null) || return 0
  [[ -n "$parts" ]] || return 0
  local out="" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local nm="${line#* }"
    if [[ "$line" == HARD* ]]; then out+="${WATCH_RED}⛔ ${nm}${WATCH_RESET}  "
    else                            out+="${WATCH_YELLOW}⚠ ${nm}${WATCH_RESET}  "; fi
  done <<<"$parts"
  printf '%s' "${WATCH_DIM}budget:${WATCH_RESET} ${out}"
}

# Render one frame to stdout. Cursor-home + clear-eol per line + clear-down
# at the end → no flicker.
_watch_render() {
  local data="$1" selected="$2" interval="$3"
  local cols
  cols=$(tput cols 2>/dev/null || echo 100)

  local total active failed
  total=$(jq  'length' <<<"$data")
  active=$(jq '[.[] | select(.active == "active")] | length' <<<"$data")
  failed=$(jq '[.[] | select(.active == "failed")] | length' <<<"$data")

  local now_str
  now_str=$(date '+%Y-%m-%d %H:%M:%S')

  # Buffer the whole frame, then write once — single syscall avoids tearing.
  local out=""
  out+="$WATCH_HOME"

  local title
  title=$(printf '%s5dive watch%s · %d agents · %s%d active%s · %s%d failed%s' \
    "$WATCH_BOLD$WATCH_CYAN" "$WATCH_RESET" "$total" \
    "$WATCH_GREEN" "$active" "$WATCH_RESET" \
    "$WATCH_RED" "$failed" "$WATCH_RESET")
  local title_len ts_len pad
  title_len=$(_watch_visible_len "$title")
  ts_len=${#now_str}
  pad=$((cols - title_len - ts_len))
  (( pad < 1 )) && pad=1
  out+="${title}$(printf '%*s' "$pad" '')${WATCH_DIM}${now_str}${WATCH_RESET}${WATCH_CLR_EOL}"$'\n'
  local budget_line
  budget_line=$(_watch_budget_line)
  if [[ -n "$budget_line" ]]; then
    out+="${budget_line}${WATCH_CLR_EOL}"$'\n'
  fi
  out+="${WATCH_CLR_EOL}"$'\n'

  out+="${WATCH_DIM}    NAME              TYPE     CHANNEL                  UPTIME    RESTART    MEMORY${WATCH_RESET}${WATCH_CLR_EOL}"$'\n'

  if (( total == 0 )); then
    out+="${WATCH_CLR_EOL}"$'\n'
    out+="    ${WATCH_DIM}no agents — try: ${WATCH_RESET}${WATCH_CYAN}5dive agent create my-agent --type=claude${WATCH_RESET}${WATCH_CLR_EOL}"$'\n'
  else
    local i=0
    local count
    count=$(jq 'length' <<<"$data")
    while (( i < count )); do
      local row name type channels bot up_secs restarts mem_b active
      row=$(jq -c --argjson i "$i" '.[$i]' <<<"$data")
      name=$(jq      -r '.name'                  <<<"$row")
      type=$(jq      -r '.type'                  <<<"$row")
      channels=$(jq  -r '.channels'              <<<"$row")
      bot=$(jq       -r '.botUsername // empty'  <<<"$row")
      up_secs=$(jq   -r '.uptime'                <<<"$row")
      restarts=$(jq  -r '.restarts'              <<<"$row")
      mem_b=$(jq     -r '.mem'                   <<<"$row")
      active=$(jq    -r '.active'                <<<"$row")

      local chan_disp="$channels"
      [[ -n "$bot" && "$channels" == "telegram" ]] && chan_disp="telegram (@${bot})"
      [[ "$channels" == "none" ]] && chan_disp="-"

      local up_disp mem_disp dot
      up_disp=$(_watch_uptime "$up_secs")
      mem_disp=$(_watch_mem    "$mem_b")
      dot=$(_watch_dot         "$active")

      local name_cell type_cell chan_cell up_cell rs_cell cell
      name_cell=$(_watch_pad_right "$(_watch_truncate "$name"      16)" 16)
      type_cell=$(_watch_pad_right "$(_watch_truncate "$type"       8)"  8)
      chan_cell=$(_watch_pad_right "$(_watch_truncate "$chan_disp" 24)" 24)
      up_cell=$(_watch_pad_right   "$up_disp"  9)
      rs_cell=$(printf '%7d  ' "$restarts")
      cell="${name_cell}  ${type_cell} ${chan_cell} ${up_cell} ${rs_cell}${mem_disp}"

      if (( i == selected )); then
        out+=" ${dot} ${WATCH_REV}${cell}${WATCH_RESET}${WATCH_CLR_EOL}"$'\n'
      else
        out+=" ${dot} ${cell}${WATCH_CLR_EOL}"$'\n'
      fi
      ((i++)) || true
    done
  fi

  out+="${WATCH_CLR_EOL}"$'\n'
  local foot_left foot_right fl_len fr_len fpad
  foot_left="${WATCH_DIM}↑↓ select · ↵ attach · r refresh · q quit${WATCH_RESET}"
  foot_right="${WATCH_DIM}refresh: ${interval}s${WATCH_RESET}"
  fl_len=$(_watch_visible_len "$foot_left")
  fr_len=$(_watch_visible_len "$foot_right")
  fpad=$((cols - fl_len - fr_len))
  (( fpad < 1 )) && fpad=1
  out+="${foot_left}$(printf '%*s' "$fpad" '')${foot_right}${WATCH_CLR_EOL}"

  # Wipe everything beneath in case the previous frame was taller.
  out+="${WATCH_CLR_DOWN}"

  printf '%s' "$out"
}

cmd_watch() {
  local interval=2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval=*) interval="${1#--interval=}" ;;
      -h|--help)
        cat >&2 <<HELP
usage: 5dive watch [--interval=N]
  Live multi-agent dashboard. ↑↓ select, ↵ attach, r refresh, q quit.
HELP
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  [[ "$interval" =~ ^[0-9]+$ ]] && (( interval >= 1 && interval <= 60 )) \
    || fail "$E_VALIDATION" "--interval must be 1-60 seconds"
  ensure_state

  # Need a TTY for the alt-screen + arrow-key reads to make sense. CI / pipes
  # get a clear error instead of garbled output.
  [[ -t 1 && -t 0 ]] || fail "$E_USAGE" "5dive watch requires a TTY (try running it directly, not piped)"

  local selected=0
  local quit=0

  _watch_teardown() {
    printf '%s%s%s' "$WATCH_SHOW" "$WATCH_RESET" "$WATCH_ALT_OFF"
  }
  trap '_watch_teardown; exit 130' INT TERM
  trap '_watch_teardown' EXIT
  printf '%s%s' "$WATCH_ALT_ON" "$WATCH_HIDE"

  while (( ! quit )); do
    local snap count
    snap=$(_watch_snapshot)
    count=$(jq 'length' <<<"$snap")
    (( count == 0 )) && selected=0
    (( selected >= count && count > 0 )) && selected=$((count - 1))
    (( selected < 0 )) && selected=0

    _watch_render "$snap" "$selected" "$interval"

    # Drain input within the refresh window. read returns non-zero on
    # timeout, which we use as the "tick" trigger.
    local tick_end
    tick_end=$(( $(date +%s) + interval ))
    while (( $(date +%s) < tick_end )); do
      local remaining=$(( tick_end - $(date +%s) ))
      (( remaining <= 0 )) && break
      local key=""
      if IFS= read -rsn1 -t "$remaining" key; then
        case "$key" in
          q|Q) quit=1; break ;;
          r|R) break ;;
          j|J) (( count > 0 && selected < count - 1 )) && ((selected++)) ;;
          k|K) (( selected > 0 ))                      && ((selected--)) ;;
          $'\x1b')
            # Arrow keys: ESC [ A (up) / B (down). Short timeouts so a bare
            # ESC press doesn't hang.
            local rest1 rest2
            read -rsn1 -t 0.05 rest1 || true
            read -rsn1 -t 0.05 rest2 || true
            if [[ "$rest1" == "[" ]]; then
              case "$rest2" in
                A) (( selected > 0 ))                      && ((selected--)) ;;
                B) (( count > 0 && selected < count - 1 )) && ((selected++)) ;;
              esac
            fi ;;
          ""|$'\n'|$'\r')
            (( count > 0 )) || continue
            local target
            target=$(jq -r --argjson i "$selected" '.[$i].name' <<<"$snap")
            [[ -n "$target" && "$target" != "null" ]] || continue
            # Leave alt screen so tmux attach sees the user's real terminal.
            # Re-enter when the user detaches.
            _watch_teardown
            sudo -u "agent-${target}" tmux attach -t "agent-${target}" || true
            printf '%s%s' "$WATCH_ALT_ON" "$WATCH_HIDE"
            break ;;
        esac
        # Re-render after a key for snappy navigation feedback.
        _watch_render "$snap" "$selected" "$interval"
      fi
    done
  done
}

