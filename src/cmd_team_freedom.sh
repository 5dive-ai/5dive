# -------- 5dive team freedom (DIVE-8853, per agent since DIVE-8872) --------
#
# lodar 2026-11-20: ONE owner control sets how much an agent does without
# asking. The app shows it on each agent's page, next to Proactive, as
# "Team freedom": Ask me often / Balanced / YOLO. 05:19Z (DIVE-8872): "this
# could be by agent not by server", so the level is stored per agent.
#
#   5dive team freedom [--agent=<name>] [--json]          status: per agent, the level or "custom" + what differs
#   sudo 5dive team freedom ask|balanced|yolo --agent=<n>  set one agent
#   sudo 5dive team freedom ask|balanced|yolo              set every agent (DIVE-8853's form, kept)
#
# A level is a preset over switches that already exist; it owns none of them:
#
#                         ask             balanced        yolo
#   browser send          ask             allow           always     } ONE browser per box:
#   browser publish       ask             ask             always     } see "The browser" below
#   browser pay           ask             ask             always     }
#   browser delete        ask             ask             always     }
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
# `autonomy=full` is the per-agent mode for YOLO (bin/5dive-agent-start holds
# its directive): act on your own call, money, saved logins and irreversible
# steps included, and file no approval gate for them. `autonomy=yolo` keeps its
# meaning (acts on its recs, still keeps hard gates); it is what Balanced sets.
#
# PER AGENT: email gates, Proactive and autonomy are each agent's own, so each
# follows that agent's level. THE BROWSER is the one box-wide switch: one
# browser plugin, one owner policy, no notion of which agent is acting. It
# follows the MOST CAREFUL level any agent is on (ask < balanced < yolo): one
# agent on YOLO must not stop paying asks for every other agent on the box.
# So the browser asks stop only once every agent is on YOLO. It is reported
# beside the agents, never as part of one agent's level, and there is no
# team-level setting to hold it (DIVE-8872 body).
#
# CUSTOM. The chosen level is stored; the switches stay where they are. Status
# re-reads every switch and compares: anything changed by hand since makes that
# agent "custom", with the switches that differ. Setting a level again
# overwrites them. Never set = level null unless the switches already match one.
#
# Who is "the team": every agent in the registry except system seats (the
# 5dive helper) and sysadmin. Email counts only for an agent with email
# connected; autonomy only for a claude agent; the browser only when the
# browser plugin answers `approvals policy`.
#
# NEW AGENTS start on Balanced once Team freedom has been used on this box
# (any level stored). Before that, nothing changes: a new agent keeps today's
# defaults, so the CLI moves nobody while the app control is still dark.
# cmd_agent_create takes Balanced's autonomy when no --autonomy/--yolo was
# given, and stores the level + sets Proactive once the agent is up.
#
# State (task_prefs, no schema change):
#   freedom.agent.<name>   {"level","set_at","set_by"}
#   freedom.team           DIVE-8853's whole-team level, read only as the level
#                          of an agent with no key of its own; the set-everyone
#                          form replaces it with per-agent keys

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

_freedom_rank() { case "$1" in ask) echo 0 ;; balanced) echo 1 ;; yolo) echo 2 ;; esac; }

_freedom_pref() {  # <key> -> the stored {"level",...} object, or {}
  local s
  tasks_db_init >/dev/null 2>&1 || true
  s=$(db "SELECT value FROM task_prefs WHERE key=$(sqlq "$1");" 2>/dev/null)
  jq -e 'type=="object" and (.level|type=="string")' <<<"$s" >/dev/null 2>&1 && printf '%s' "$s" || printf '{}'
}
# One agent's stored level object: its own key, else DIVE-8853's team level.
_freedom_saved() {  # <name>
  local s; s=$(_freedom_pref "freedom.agent.$1")
  [[ "$s" == '{}' ]] && s=$(_freedom_pref freedom.team)
  printf '%s' "$s"
}
_freedom_save() {  # <name> <level> <by>
  local v
  v=$(jq -cn --arg l "$2" --arg by "$3" --arg at "$(date -u +%FT%TZ)" '{level:$l, set_at:$at, set_by:$by}')
  db "INSERT INTO task_prefs (key, value, updated_at) VALUES ($(sqlq "freedom.agent.$1"), $(sqlq "$v"), datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
}
# One agent's saved level, or nothing when the owner never chose one.
_freedom_level() { jq -r '.level // empty' <<<"$(_freedom_saved "$1")"; }
# Has Team freedom ever been set on this box? (New agents start on Balanced only then.)
_freedom_used() {
  tasks_db_init >/dev/null 2>&1 || true
  [[ "$(db "SELECT count(*) FROM task_prefs WHERE key='freedom.team' OR key LIKE 'freedom.agent.%';" 2>/dev/null)" =~ ^[1-9] ]]
}

# The team: name<TAB>type, one per line.
_freedom_team() {
  registry_read 2>/dev/null | jq -r '.agents // {} | to_entries[]
    | select((.value.system // "") == "" and .key != "sysadmin")
    | "\(.key)\t\(.value.type // "claude")"' 2>/dev/null
}
_freedom_type_of() {  # <name> -> its type when it is on the team, else nothing
  local n t
  while IFS=$'\t' read -r n t; do [[ "$n" == "$1" ]] && { echo "$t"; return 0; }; done <<<"$(_freedom_team)"
  return 0
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

# One agent's own switches, as JSON lines {switch, agent, now}.
_freedom_snapshot_agent() {  # <name> <type>
  local n="$1" t="$2" v e_in e_send
  v=$(_freedom_proactive_now "$n")
  [[ -n "$v" ]] && jq -cn --arg a "$n" --arg v "$v" '{switch:"proactive", agent:$a, now:$v}'
  [[ "$t" == claude ]] && jq -cn --arg a "$n" --arg v "$(_freedom_autonomy_now "$n")" '{switch:"autonomy", agent:$a, now:$v}'
  read -r e_in e_send <<<"$(_freedom_email_now "$n")"
  if [[ -n "$e_in" ]]; then
    jq -cn --arg a "$n" --arg v "$e_in" '{switch:"email.inbound", agent:$a, now:$v}'
    jq -cn --arg a "$n" --arg v "$e_send" '{switch:"email.send", agent:$a, now:$v}'
  fi
  return 0
}
# The browser's switches, as JSON lines {switch, agent:null, now}. <browser json>
_freedom_snapshot_browser() {
  local k
  [[ -n "$1" ]] || return 0
  for k in $_FREEDOM_BROWSER_KINDS; do
    jq -cn --arg s "browser.$k" --arg v "$(jq -r --arg k "$k" '.[$k]' <<<"$1")" '{switch:$s, agent:null, now:$v}'
  done
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

# The level the box-wide browser follows: the most careful level any agent is
# on, or nothing when no agent has one.
_freedom_browser_level() {
  local n t l best=""
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" ]] || continue
    l=$(_freedom_level "$n"); [[ -n "$l" ]] || continue
    [[ -z "$best" || "$(_freedom_rank "$l")" -lt "$(_freedom_rank "$best")" ]] && best="$l"
  done <<<"$(_freedom_team)"
  printf '%s' "$best"
}

# One agent's status as JSON {agent, level, label, set_level, set_at, set_by, differs}.
_freedom_agent_status() {  # <name> <type>
  local n="$1" saved level snap differs='[]' match="" l
  saved=$(_freedom_saved "$n"); level=$(jq -r '.level // empty' <<<"$saved")
  snap=$(_freedom_snapshot_agent "$n" "$2")
  if [[ -n "$level" ]]; then
    differs=$(_freedom_differs "$level" "$snap")
    if [[ "$(jq length <<<"$differs")" == 0 ]]; then match="$level"; else match=custom; fi
  else
    # Never chosen: a level shows only when every switch already matches it,
    # the shared browser included (an untouched agent on the box default
    # browser, where sending goes ahead, is not "Ask me often").
    snap+=$'\n'"$(_freedom_snapshot_browser "$(_freedom_browser_now)")"
    for l in $_FREEDOM_LEVELS; do
      [[ "$(_freedom_differs "$l" "$snap" | jq length)" == 0 ]] && { match="$l"; break; }
    done
  fi
  jq -cn --arg a "$n" --arg m "$match" --arg lb "${match:+$(_freedom_label "$match")}" --arg sl "$level" \
    --argjson s "$saved" --argjson d "$differs" \
    '{agent:$a, level:(($m|select(length>0)) // null), label:(($lb|select(length>0)) // null),
      set_level:(($sl|select(length>0)) // null), set_at:$s.set_at, set_by:$s.set_by, differs:$d}'
}

# The browser's status as JSON {level, differs}; level null = no agent has a
# level (or no browser), so the browser is left as it is.
_freedom_browser_status() {
  local b bl differs='[]'
  b=$(_freedom_browser_now); bl=$(_freedom_browser_level)
  [[ -n "$b" && -n "$bl" ]] && differs=$(_freedom_differs "$bl" "$(_freedom_snapshot_browser "$b")")
  [[ -n "$b" ]] || bl=""
  jq -cn --arg l "$bl" --argjson d "$differs" '{level:(($l|select(length>0)) // null), differs:$d}'
}

_freedom_status() {  # [<agent>]
  local only="$1" n t agents=() a browser
  if [[ -n "$only" ]]; then
    t=$(_freedom_type_of "$only")
    [[ -n "$t" ]] || fail "$E_NOT_FOUND" "'$only' is not on the team (system seats and sysadmin have no Team freedom): 5dive agent list"
    a=$(_freedom_agent_status "$only" "$t"); browser=$(_freedom_browser_status)
    if (( JSON_MODE )); then
      ok "" '$a + {browser:$b, levels:["ask","balanced","yolo"]}' --argjson a "$a" --argjson b "$browser"
      return 0
    fi
    _freedom_print_agent "$a"
    _freedom_print_browser "$browser"
    return 0
  fi
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" ]] && agents+=("$(_freedom_agent_status "$n" "$t")")
  done <<<"$(_freedom_team)"
  browser=$(_freedom_browser_status)
  local all; all=$(printf '%s\n' "${agents[@]}" | jq -cs 'map(select(. != null))')
  if (( JSON_MODE )); then
    # The team summary keeps DIVE-8853's top-level shape: one level when every
    # agent (and the browser) is on it, else custom with every difference.
    ok "" '($all | map(.level) | unique) as $ls
      | (if ($ls|length)==1 and $ls[0] != null and $ls[0] != "custom" and ($b.differs|length)==0 then $ls[0]
         elif ($ls == [null]) or ($ls|length)==0 then null else "custom" end) as $m
      | {level:$m,
         label:(if $m=="ask" then "Ask me often" elif $m=="balanced" then "Balanced" elif $m=="yolo" then "YOLO" elif $m=="custom" then "Custom" else null end),
         set_level:($all | map(.set_level) | unique | if length==1 then .[0] else null end),
         differs:($b.differs + ($all | map(.differs[]))),
         agents:$all, browser:$b, levels:["ask","balanced","yolo"]}' \
      --argjson all "$all" --argjson b "$browser"
    return 0
  fi
  if [[ "$(jq length <<<"$all")" == 0 ]]; then echo "Team freedom: no agents on the team yet."; return 0; fi
  jq -c '.[]' <<<"$all" | while IFS= read -r a; do _freedom_print_agent "$a"; done
  _freedom_print_browser "$browser"
}
_freedom_print_agent() {  # <agent status json>
  local a="$1" n m sl
  n=$(jq -r .agent <<<"$a"); m=$(jq -r '.level // empty' <<<"$a"); sl=$(jq -r '.set_level // empty' <<<"$a")
  if [[ -z "$m" ]]; then
    echo "$n: not set. Pick one: sudo 5dive team freedom ask|balanced|yolo --agent=$n"
  elif [[ "$m" == custom ]]; then
    echo "$n: Custom (set to $(_freedom_label "$sl"), then changed by hand):"
    jq -r '.differs[] | "  \(.switch): \(.now), \(.want) on this level"' <<<"$a"
    echo "  Setting a level again overwrites these."
  else
    echo "$n: $(_freedom_label "$m")"
  fi
}
_freedom_print_browser() {  # <browser status json>
  local bl; bl=$(jq -r '.level // empty' <<<"$1")
  [[ -n "$bl" ]] || return 0
  echo "Browser (one for the whole box, follows the most careful agent): $(_freedom_label "$bl")"
  jq -r '.differs[] | "  \(.switch): \(.now), \(.want) on this level"' <<<"$1"
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
  return 0
}

# Bring the box-wide browser to the most careful agent's level. Echoes ok/fail.
_freedom_apply_browser() {
  local b bl k pairs=()
  b=$(_freedom_browser_now); bl=$(_freedom_browser_level)
  [[ -n "$b" && -n "$bl" ]] || return 0
  for k in $_FREEDOM_BROWSER_KINDS; do
    [[ "$(jq -r --arg k "$k" '.[$k]' <<<"$b")" == "$(_freedom_want "$bl" "browser.$k")" ]] \
      || pairs+=("$k=$(_freedom_want "$bl" "browser.$k")")
  done
  (( ${#pairs[@]} )) || return 0
  if _freedom_run browser approvals policy set "${pairs[@]}" >/dev/null 2>&1; then echo "ok browser ${pairs[*]}"
  else echo "fail browser ${pairs[*]}"; fi
}

_freedom_set() {  # <level> [<agent>]
  local level="$1" only="$2" res="" n t by
  local who="${only:+ --agent=$only}"
  _freedom_is_root || fail "$E_PERMISSION" "only the owner sets team freedom: sudo 5dive team freedom $level$who"
  by="${SUDO_USER:-$(id -un)}"
  if [[ -n "$only" ]]; then
    t=$(_freedom_type_of "$only")
    [[ -n "$t" ]] || fail "$E_NOT_FOUND" "'$only' is not on the team (system seats and sysadmin have no Team freedom): 5dive agent list"
    _freedom_save "$only" "$level" "$by"
    res+="$(_freedom_apply_agent "$level" "$only" "$t")"$'\n'
  else
    while IFS=$'\t' read -r n t; do
      [[ -n "$n" ]] || continue
      _freedom_save "$n" "$level" "$by"
      res+="$(_freedom_apply_agent "$level" "$n" "$t")"$'\n'
    done <<<"$(_freedom_team)"
    db "DELETE FROM task_prefs WHERE key='freedom.team';" >/dev/null 2>&1 || true
  fi
  res+="$(_freedom_apply_browser)"$'\n'
  local changed failed bl
  # jq filters, not grep: a clean set has no `fail` line (a re-set no `ok`
  # line), and a grep that matches nothing would end the run under errexit.
  changed=$(jq -Rcs 'split("\n") | map(select(startswith("ok ")) | .[3:])' <<<"$res")
  failed=$(jq -Rcs 'split("\n") | map(select(startswith("fail ")) | .[5:])' <<<"$res")
  local whom="${only:-Your team}"
  if [[ "$(jq length <<<"$failed")" != 0 ]]; then
    fail "$E_GENERIC" "team freedom for ${only:-the team} is $(_freedom_label "$level"), but these did not change: $(jq -r 'join("; ")' <<<"$failed"). Status shows them as custom until they do."
  fi
  local line
  case "$level" in
    ask)      line="$whom asks you before sending, posting, paying or deleting, and new email senders wait for you." ;;
    balanced) line="$whom sends on its own and acts on its own calls; posting, paying and deleting still ask you." ;;
    yolo)     line="Nothing from $whom asks you any more: not paying, not passwords, not deleting. Paying still stops at the wallet cap." ;;
  esac
  bl=$(_freedom_browser_level)
  if [[ -n "$only" && -n "$bl" && "$bl" != "$level" && -n "$(_freedom_browser_now)" ]]; then
    line+=" The browser is shared by the whole box and stays on $(_freedom_label "$bl"), the most careful agent's level."
  fi
  ok "Team freedom${only:+ for $only}: $(_freedom_label "$level"). $line" \
    '{level:$l, label:$lb, agent:(($a|select(length>0)) // null), browser_level:(($bl|select(length>0)) // null), changed:$c, failed:[]}' \
    --arg l "$level" --arg lb "$(_freedom_label "$level")" --arg a "$only" --arg bl "$bl" --argjson c "$changed"
}

# cmd_agent_create: the level a new agent starts on. Balanced once Team freedom
# has been used on this box; nothing before that (today's defaults stand).
_freedom_new_agent_level() { _freedom_used && echo balanced; return 0; }
# cmd_agent_create: the autonomy a new claude agent takes from its starting level.
_freedom_new_agent_autonomy() {  # <type>
  local level; level=$(_freedom_new_agent_level 2>/dev/null)
  [[ -n "$level" && "$1" == claude ]] && _freedom_want "$level" autonomy
  return 0
}
# cmd_agent_create, once the agent is up: store its level, set its Proactive,
# and bring the shared browser to the most careful level. Best-effort: a miss
# is one switch shown as custom, not a failed create.
_freedom_new_agent_inherit() {  # <name>
  local level want; level=$(_freedom_new_agent_level 2>/dev/null)
  [[ -n "$level" ]] || return 0
  [[ -n "$(_freedom_type_of "$1")" ]] || return 0
  _freedom_save "$1" "$level" "new agent" >/dev/null 2>&1 || true
  want=$(_freedom_want "$level" proactive)
  if [[ "$want" != off ]]; then
    _freedom_run agent proactive "$1" "$want" >/dev/null 2>&1 \
      || warn "'$1' did not take Balanced's proactive level ($want); set it with: sudo 5dive agent proactive $1 $want"
  fi
  [[ "$(_freedom_apply_browser)" != fail* ]] \
    || warn "the browser did not follow '$1''s level; see: 5dive team freedom"
  return 0
}

cmd_team_freedom() {
  local verb="" agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) JSON_MODE=1 ;;
      --agent=*) agent="${1#--agent=}" ;;
      --agent) [[ $# -ge 2 ]] || fail "$E_USAGE" "--agent needs a name: --agent=<name>"; agent="$2"; shift ;;
      -h|--help|help) verb=help ;;
      *) [[ -z "$verb" ]] && verb="$1" || fail "$E_USAGE" "one level at a time: ask|balanced|yolo" ;;
    esac
    shift
  done
  [[ -z "$agent" || "$agent" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail "$E_USAGE" "not an agent name: $agent"
  case "$verb" in
    help)
      cat <<'HELP'
5dive team freedom [--agent=<name>] [--json]        each agent's level: Ask me often / Balanced / YOLO,
                                                    or Custom (a switch was changed by hand) with what differs
sudo 5dive team freedom ask|balanced|yolo --agent=<name>   set one agent
sudo 5dive team freedom ask|balanced|yolo                  set every agent
  ask       asks before sending, posting, paying and deleting; new email senders wait
  balanced  sends on its own and acts on its own calls; posting, paying, deleting still ask
  yolo      nothing asks: not paying, not passwords, not deleting (wallet caps still hold)
The browser is one for the whole box: it follows the most careful agent's level.
New agents start on Balanced once Team freedom has been used on this box.
HELP
      return 0 ;;
    ""|status) _freedom_status "$agent" ;;
    ask|balanced|yolo) _freedom_set "$verb" "$agent" ;;
    *) fail "$E_USAGE" "unknown level: $verb (ask|balanced|yolo|status|help)" ;;
  esac
}
