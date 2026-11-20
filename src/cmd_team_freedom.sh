# -------- 5dive team freedom (DIVE-8853) --------
#
# lodar 2026-11-20: ONE owner control sets how much the whole team does without
# asking. The app shows it as "Team freedom": Ask me often / Balanced / YOLO.
#
#   5dive team freedom [--json]                   status: the level, or "custom" + what differs
#   sudo 5dive team freedom ask|balanced|yolo     set it: rewrites every switch below
#
# A level is a preset over switches that already exist; it owns none of them:
#
#                         ask             balanced        yolo
#   browser send          ask             allow           always
#   browser publish       ask             ask             always
#   browser pay           ask             ask             always
#   browser delete        ask             ask             always
#   email inbound gate    on (waits)      on              off (new senders go through)
#   email send gate       on (asks)       on              off (mails anyone)
#   proactive             off (Normal)    little (High)   more (Very high)
#   autonomy (claude)     standard        yolo            full
#
# ON YOLO NOTHING ASKS THE OWNER, not paying, not passwords, not deleting
# (lodar 02:05Z: "if money, passwords, steps you can't undo cannot be switched
# off thats not yolo"). There is no hard-coded floor here. Two things are not
# permissions, so no level changes them: a secret this box does not hold still
# comes from the owner by secure link, and paying draws on the agent's own
# capped wallet, so the cap is the owner's budget.
#
# `autonomy=full` is the new per-agent mode for YOLO (bin/5dive-agent-start
# holds its directive): act on your own call, money, saved logins and
# irreversible steps included, and file no approval gate for them. The old
# `autonomy=yolo` keeps its meaning (acts on its recs, still keeps hard gates),
# so agents already on it are unchanged; it is what Balanced sets.
#
# CUSTOM. The chosen level is stored; the switches stay where they are. Status
# re-reads every switch and compares: anything changed by hand since makes the
# level "custom", with the switches that differ. Setting a level again
# overwrites them. Never set = level null (the app lights nothing).
#
# Who is "the team": every agent in the registry except system seats (the
# 5dive helper) and sysadmin. Email counts only for an agent with email
# connected; autonomy only for a claude agent; the browser only when the
# browser plugin answers `approvals policy`.
#
# New agents inherit the level: cmd_agent_create takes the level's autonomy
# when no --autonomy/--yolo was given, and its proactive level once it is up.
#
# State (task_prefs, no schema change):
#   freedom.team   {"level","set_at","set_by"}

_FREEDOM_LEVELS="ask balanced yolo"
_FREEDOM_BROWSER_KINDS="send publish pay delete"

_freedom_is_root() { [[ "$EUID" == "0" ]]; }   # seam: harnesses drive it
# Every switch is changed through its own verb, in its own process: the verb
# keeps its own checks, audit line and restart, and one refusal cannot exit us.
_freedom_run() { "${FIVEDIVE_SELF:-$0}" "$@"; }   # seam: harnesses record it

_freedom_valid() { [[ " $_FREEDOM_LEVELS " == *" $1 "* ]]; }

# <level> <switch> -> the value that level gives it
_freedom_want() {
  case "$1:$2" in
    ask:browser.*)              echo ask ;;
    balanced:browser.send)      echo allow ;;
    balanced:browser.*)         echo ask ;;
    yolo:browser.*)             echo always ;;
    yolo:email.*)               echo off ;;
    *:email.*)                  echo on ;;
    ask:proactive)              echo off ;;
    balanced:proactive)         echo little ;;
    yolo:proactive)             echo more ;;
    ask:autonomy)               echo standard ;;
    balanced:autonomy)          echo yolo ;;
    yolo:autonomy)              echo full ;;
  esac
}

_freedom_label() {
  case "$1" in
    ask)      echo "Ask me often" ;;
    balanced) echo "Balanced" ;;
    yolo)     echo "YOLO" ;;
    *)        echo "Custom" ;;
  esac
}

_freedom_saved() {
  local s
  tasks_db_init >/dev/null 2>&1 || true
  s=$(db "SELECT value FROM task_prefs WHERE key='freedom.team';" 2>/dev/null)
  jq -e 'type=="object" and (.level|type=="string")' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '{}'
}
_freedom_save() {  # <level> <by>
  local v
  v=$(jq -cn --arg l "$1" --arg by "$2" --arg at "$(date -u +%FT%TZ)" '{level:$l, set_at:$at, set_by:$by}')
  db "INSERT INTO task_prefs (key, value, updated_at) VALUES ('freedom.team', $(sqlq "$v"), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
}
# The saved level, or nothing when the owner never chose one.
_freedom_level() { jq -r '.level // empty' <<<"$(_freedom_saved)"; }

# The team: name<TAB>type, one per line.
_freedom_team() {
  registry_read 2>/dev/null | jq -r '.agents // {} | to_entries[]
    | select((.value.system // "") == "" and .key != "sysadmin")
    | "\(.key)\t\(.value.type // "claude")"' 2>/dev/null
}

_freedom_autonomy_now() {  # <name>
  local a=""
  [[ -r "${ENV_DIR}/$1.env" ]] && a=$(sed -n 's/^AGENT_AUTONOMY=//p' "${ENV_DIR}/$1.env" | head -1)
  case "${a,,}" in ""|standard) echo standard ;; yolo|son-of-anton) echo yolo ;; *) echo "${a,,}" ;; esac
}

_freedom_email_cfg() { printf '%s/agent-%s/.claude/channels/email/config.json' "${AGENT_HOME_ROOT:-/home}" "$1"; }
# <name> -> "inbound send" as on|off, or nothing when it has no email.
_freedom_email_now() {
  local cfg; cfg=$(_freedom_email_cfg "$1")
  [[ -r "$cfg" ]] || return 0
  jq -r 'select(.address and .mode and .smtp)
    | "\(if .approve_inbound == false then "off" else "on" end) \(if .approve_new == false then "off" else "on" end)"' "$cfg" 2>/dev/null
}

_freedom_proactive_now() {  # <name>
  _freedom_run agent proactive "$1" --json 2>/dev/null | jq -r '.data.level // empty' 2>/dev/null
}

# The browser's four answers as JSON, or nothing (no browser, or one too old).
_freedom_browser_now() {
  local out
  out=$(_freedom_run browser approvals policy --json 2>/dev/null) || return 0
  out=$(printf '%s' "$out" | sed -n '/{/,$p')
  jq -ce 'select(.pay and .publish and .send and .delete) | {pay, publish, send, delete}' <<<"$out" 2>/dev/null || true
}

# Every switch the team has, as JSON lines {switch, agent, now}.
_freedom_snapshot() {
  local b k n t v e_in e_send
  b=$(_freedom_browser_now)
  if [[ -n "$b" ]]; then
    for k in $_FREEDOM_BROWSER_KINDS; do
      jq -cn --arg s "browser.$k" --arg v "$(jq -r --arg k "$k" '.[$k]' <<<"$b")" '{switch:$s, agent:null, now:$v}'
    done
  fi
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" ]] || continue
    v=$(_freedom_proactive_now "$n")
    [[ -n "$v" ]] && jq -cn --arg a "$n" --arg v "$v" '{switch:"proactive", agent:$a, now:$v}'
    [[ "$t" == claude ]] && jq -cn --arg a "$n" --arg v "$(_freedom_autonomy_now "$n")" '{switch:"autonomy", agent:$a, now:$v}'
    read -r e_in e_send <<<"$(_freedom_email_now "$n")"
    if [[ -n "$e_in" ]]; then
      jq -cn --arg a "$n" --arg v "$e_in" '{switch:"email.inbound", agent:$a, now:$v}'
      jq -cn --arg a "$n" --arg v "$e_send" '{switch:"email.send", agent:$a, now:$v}'
    fi
  done <<<"$(_freedom_team)"
}

# <level> <snapshot> -> JSON array of {switch, agent, want, now} that differ.
_freedom_differs() {
  local level="$1" line s want out=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    s=$(jq -r .switch <<<"$line")
    want=$(_freedom_want "$level" "$s")
    out+=("$(jq -c --arg w "$want" '. + {want:$w} | select(.want != .now)' <<<"$line")")
  done <<<"$2"
  printf '%s\n' "${out[@]}" | jq -cs 'map(select(. != null))'
}

_freedom_status() {
  local saved level snap differs l match=""
  saved=$(_freedom_saved); level=$(jq -r '.level // empty' <<<"$saved")
  snap=$(_freedom_snapshot)
  if [[ -n "$level" ]]; then
    differs=$(_freedom_differs "$level" "$snap")
    [[ "$(jq length <<<"$differs")" == 0 ]] || match=custom
    [[ -n "$match" ]] || match="$level"
  else
    # Never chosen: a level shows only when every switch already matches it.
    differs='[]'
    for l in $_FREEDOM_LEVELS; do
      [[ "$(_freedom_differs "$l" "$snap" | jq length)" == 0 ]] && { match="$l"; break; }
    done
  fi
  if (( JSON_MODE )); then
    ok "" '{level:(($m|select(length>0)) // null), label:(($lb|select(length>0)) // null), set_level:(($sl|select(length>0)) // null), set_at:$s.set_at, set_by:$s.set_by, differs:$d, levels:["ask","balanced","yolo"]}' \
      --arg m "$match" --arg lb "${match:+$(_freedom_label "$match")}" --arg sl "$level" \
      --argjson s "$saved" --argjson d "$differs"
    return 0
  fi
  if [[ -z "$level" && -z "$match" ]]; then
    echo "Team freedom: not set. Pick one: sudo 5dive team freedom ask|balanced|yolo"
  elif [[ "$match" == custom ]]; then
    echo "Team freedom: Custom (set to $(_freedom_label "$level"), then changed by hand):"
    jq -r '.[] | "  \(.switch)\(if .agent then " (\(.agent))" else "" end): \(.now), \(.want) on this level"' <<<"$differs"
    echo "Setting a level again overwrites these."
  else
    echo "Team freedom: $(_freedom_label "$match")"
  fi
}

# Apply <level> to one agent's own switches. Echoes "ok <what>" / "fail <what>".
_freedom_apply_agent() {  # <level> <name> <type>
  local level="$1" n="$2" t="$3" want now e_in e_send
  want=$(_freedom_want "$level" proactive); now=$(_freedom_proactive_now "$n")
  if [[ -n "$now" && "$now" != "$want" ]]; then
    if _freedom_run agent proactive "$n" "$want" >/dev/null 2>&1; then echo "ok proactive $n $want"; else echo "fail proactive $n $want"; fi
  fi
  if [[ "$t" == claude ]]; then
    want=$(_freedom_want "$level" autonomy); now=$(_freedom_autonomy_now "$n")
    if [[ "$now" != "$want" ]]; then
      if _freedom_run agent config "$n" set "autonomy=$want" >/dev/null 2>&1; then echo "ok autonomy $n $want"; else echo "fail autonomy $n $want"; fi
    fi
  fi
  read -r e_in e_send <<<"$(_freedom_email_now "$n")"
  if [[ -n "$e_in" ]]; then
    want=$(_freedom_want "$level" email.inbound)
    if [[ "$e_in" != "$want" ]]; then
      if _freedom_run email gate "$n" inbound "$want" >/dev/null 2>&1; then echo "ok email.inbound $n $want"; else echo "fail email.inbound $n $want"; fi
    fi
    if [[ "$e_send" != "$want" ]]; then
      if _freedom_run email gate "$n" send "$want" >/dev/null 2>&1; then echo "ok email.send $n $want"; else echo "fail email.send $n $want"; fi
    fi
  fi
}

_freedom_set() {
  local level="$1" b k pairs=() res="" n t
  _freedom_is_root || fail "$E_PERMISSION" "only the owner sets team freedom: sudo 5dive team freedom $level"
  _freedom_save "$level" "${SUDO_USER:-$(id -un)}"
  b=$(_freedom_browser_now)
  if [[ -n "$b" ]]; then
    for k in $_FREEDOM_BROWSER_KINDS; do
      [[ "$(jq -r --arg k "$k" '.[$k]' <<<"$b")" == "$(_freedom_want "$level" "browser.$k")" ]] \
        || pairs+=("$k=$(_freedom_want "$level" "browser.$k")")
    done
    if (( ${#pairs[@]} )); then
      if _freedom_run browser approvals policy set "${pairs[@]}" >/dev/null 2>&1; then res+="ok browser ${pairs[*]}"$'\n'
      else res+="fail browser ${pairs[*]}"$'\n'; fi
    fi
  fi
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" ]] || continue
    res+="$(_freedom_apply_agent "$level" "$n" "$t")"$'\n'
  done <<<"$(_freedom_team)"
  local changed failed
  # jq filters, not grep: a clean set has no `fail` line (a re-set no `ok`
  # line), and a grep that matches nothing would end the run under errexit.
  changed=$(jq -Rcs 'split("\n") | map(select(startswith("ok ")) | .[3:])' <<<"$res")
  failed=$(jq -Rcs 'split("\n") | map(select(startswith("fail ")) | .[5:])' <<<"$res")
  if [[ "$(jq length <<<"$failed")" != 0 ]]; then
    fail "$E_GENERIC" "team freedom is $(_freedom_label "$level"), but these did not change: $(jq -r 'join("; ")' <<<"$failed"). Status shows them as custom until they do."
  fi
  local line
  case "$level" in
    ask)      line="Your team asks you before sending, posting, paying or deleting, and new email senders wait for you." ;;
    balanced) line="Your team sends on its own and acts on its own calls; posting, paying and deleting still ask you." ;;
    yolo)     line="Nothing asks you any more: not paying, not passwords, not deleting. Paying still stops at each agent's wallet cap." ;;
  esac
  ok "Team freedom: $(_freedom_label "$level"). $line" \
    '{level:$l, label:$lb, changed:$c, failed:[]}' \
    --arg l "$level" --arg lb "$(_freedom_label "$level")" --argjson c "$changed"
}

# cmd_agent_create: the autonomy a new claude agent takes from the team level
# (nothing when no level is set, or the type has no autonomy).
_freedom_new_agent_autonomy() {  # <type>
  local level; level=$(_freedom_level 2>/dev/null)
  [[ -n "$level" && "$1" == claude ]] && _freedom_want "$level" autonomy
  return 0
}
# cmd_agent_create, once the agent is up: its proactive level from the team
# level. Best-effort: a miss is one switch shown as custom, not a failed create.
_freedom_new_agent_inherit() {  # <name>
  local level want; level=$(_freedom_level 2>/dev/null)
  [[ -n "$level" ]] || return 0
  want=$(_freedom_want "$level" proactive)
  [[ "$want" == off ]] && return 0
  _freedom_run agent proactive "$1" "$want" >/dev/null 2>&1 \
    || warn "'$1' did not take the team's proactive level ($want); set it with: sudo 5dive agent proactive $1 $want"
  return 0
}

cmd_team_freedom() {
  local verb=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) JSON_MODE=1 ;;
      -h|--help|help) verb=help ;;
      *) [[ -z "$verb" ]] && verb="$1" || fail "$E_USAGE" "one level at a time: ask|balanced|yolo" ;;
    esac
    shift
  done
  case "$verb" in
    help)
      cat <<'HELP'
5dive team freedom [--json]                 the team's level: Ask me often / Balanced / YOLO, or Custom
                                            (a switch was changed by hand since) with what differs
sudo 5dive team freedom ask|balanced|yolo   set it for the whole team; new agents take it too
  ask       asks before sending, posting, paying and deleting; new email senders wait
  balanced  sends on its own and acts on its own calls; posting, paying, deleting still ask
  yolo      nothing asks: not paying, not passwords, not deleting (wallet caps still hold)
HELP
      return 0 ;;
    ""|status) _freedom_status ;;
    ask|balanced|yolo) _freedom_set "$verb" ;;
    *) fail "$E_USAGE" "unknown level: $verb (ask|balanced|yolo)" ;;
  esac
}
