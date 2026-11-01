# DIVE-7478: a new agent greets its owner the moment Telegram is connected, and
# shows "typing" while its session boots.
#
# WHY. Every bridge that reads the bot (the telegram plugin and its codex/grok/
# agy/opencode/pi forks) runs INSIDE the agent's session. Between Connect and the
# session's first poll nothing reads the bot, so the owner's /start and "hey"
# land in a void for ~40 s (lodar, 2026-11-01: /start, "hey" x3, then the
# greeting). The box already knows who will write: the owner's id is seeded into
# access.json at create/attach. So the box itself, not the session, sends the
# greeting at once and keeps "typing" up until the bridge is polling.
#
# HOW, and what it must never do:
# - It never CONSUMES an update. An owner who has not pressed Start cannot be
#   messaged first (403); for them it peeks getUpdates with no offset, which
#   leaves every update queued for the bridge, and greets on their first message.
# - It stops peeking the moment the bridge holds the poll slot (bot.heartbeat
#   newer than this run), so it is never a second getUpdates consumer.
# - It writes connect-greeted.json in the channel state dir. The bridges read it
#   and do not greet the same chat again (one greeting per chat, DIVE-5411).
# - Best-effort throughout: a failure here never fails the attach.
# openclaw and hermes are not covered: their own gateway daemon answers at once.

TG_CONNECT_GREET_MAX_SEC="${TG_CONNECT_GREET_MAX_SEC:-90}"
TG_CONNECT_GREET_TICK="${TG_CONNECT_GREET_TICK:-1}"
TG_CONNECT_TYPING_EVERY="${TG_CONNECT_TYPING_EVERY:-4}"
TG_CONNECT_PEEK_EVERY="${TG_CONNECT_PEEK_EVERY:-2}"
TG_CONNECT_GREETED_FILE="connect-greeted.json"

_tgcg_api()  { printf '%s' "${FIVE_TG_API_BASE:-https://api.telegram.org}"; }
_tgcg_self() { printf '%s' "${FIVE_TG_GREET_SELF:-/usr/local/bin/5dive}"; }
_tgcg_now_ms() { date +%s%3N; }
_tgcg_is_root() { (( EUID == 0 )); }

# _tgcg_call <token> <method> [json] — the response body on stdout. The token
# goes to curl through a config on stdin, never argv (ps shows argv to anyone).
_tgcg_call() {
  local token="$1" method="$2" body="${3:-}"
  local -a args=(-sS -m 10 -K -)
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  printf 'url = "%s/bot%s/%s"\n' "$(_tgcg_api)" "$token" "$method" \
    | curl "${args[@]}" 2>/dev/null
}

# _tgcg_owners <access.json> — the private-chat ids to greet: `owners` when set,
# else allowFrom, kept only when allowlisted and a positive id (groups are negative).
_tgcg_owners() {
  jq -r '(.allowFrom // []) as $a | ((.owners // $a) | map(tostring))[]
         | select(. as $o | ($a | map(tostring) | index($o)) != null)
         | select(test("^[1-9][0-9]*$"))' "$1" 2>/dev/null | awk '!seen[$0]++'
}

# _tgcg_persona <home> <type> <lang> — "<name>\t<welcome>" from the agent's
# persona.yaml (Bun's YAML parser, as the plugin reads it); empty when none.
_tgcg_persona() {
  local home="$1" type="$2" lang="$3" f="" d bun
  for d in "$home/.claude" "$home/.${type}"; do
    [[ -f "$d/persona.yaml" ]] && { f="$d/persona.yaml"; break; }
  done
  [[ -n "$f" ]] || return 0
  bun=$(command -v bun 2>/dev/null) || return 0
  PERSONA_FILE="$f" PERSONA_LANG="$lang" timeout 10 "$bun" -e '
    try {
      const p = Bun.YAML.parse(await Bun.file(process.env.PERSONA_FILE).text()) ?? {}
      const s = v => (typeof v === "string" ? v.trim().replace(/[\t\n]+/g, " ") : "")
      const w = p?.ext?.["5dive"]?.welcome?.[process.env.PERSONA_LANG]
      process.stdout.write(`${s(p.name)}\t${typeof w === "string" ? w.trim() : ""}`)
    } catch {}' 2>/dev/null || true
}

# _tgcg_text <lang> <name> <about> <welcome> — the plugin's /start greeting
# (lite.ts startGreeting: the pack welcome, else liteGreeting) plus one line
# saying the agent is still starting.
_tgcg_text() {
  jq -rn --arg lang "$1" --arg n "$2" --arg a "$3" --arg w "$4" '
    {
      en: {hi: "Hi, I'\''m \($n).", anon: "Hi!", ask: "Tell me what you need, and I will get on it.",
           boot: "I'\''m starting up, ready in about 30 seconds."},
      ru: {hi: "Здравствуйте, я \($n).", anon: "Здравствуйте!", ask: "Напишите, что нужно сделать, и я возьмусь.",
           boot: "Я запускаюсь, буду на связи примерно через 30 секунд."}
    }[$lang] as $g
    | ($n | gsub("^\\s+|\\s+$"; "")) as $n
    | ($a | gsub("^\\s+|\\s+$"; "")) as $a
    | (if ($a != "" and $n != "" and ($a | test("^\\p{Ll}"))) then "\($n) \($a)" else $a end) as $a
    | (if ($a != "" and ($a | test("[.!?…]$") | not)) then "\($a)." else $a end) as $a
    | (if $a != "" then ($a[0:1] | ascii_upcase) + $a[1:] else "" end) as $a
    | (if $w != "" then $w
       else ((if $n != "" then $g.hi else $g.anon end) + (if $a != "" then "\n\($a)" else "" end) + "\n\n" + $g.ask)
       end) + "\n\n" + $g.boot'
}

# _tgcg_lang <language_code> — the two languages the plugin speaks.
_tgcg_lang() { [[ "${1:-}" == ru* ]] && printf 'ru' || printf 'en'; }

# _tgcg_as_user <user> <cmd...> — run as the seat. The state dir is the agent's
# own, so root never writes there: a symlink planted in it cannot point a root
# write anywhere else.
_tgcg_as_user() {
  local u="$1"; shift
  if _tgcg_is_root; then runuser -u "$u" -- "$@"; else "$@"; fi
}

# _tgcg_put <user> <dir> <file> — stdin to <dir>/<file>, 0600, atomically, as <user>.
_tgcg_put() {
  # shellcheck disable=SC2016 # $1/$2 belong to the inner sh
  _tgcg_as_user "$1" sh -c 'umask 077; t=$(mktemp "$1/.$2.XXXXXX") && cat >"$t" && mv -f "$t" "$1/$2"' _ "$2" "$3"
}

# _tgcg_mark <user> <state_dir> <bot_id> <started_ms> <chat...> — record who was greeted.
_tgcg_mark() {
  local user="$1" dir="$2" bot="$3" at="$4"; shift 4
  jq -cn --arg b "$bot" --argjson at "$at" '{botId: $b, at: $at, chats: $ARGS.positional}' --args "$@" \
    | _tgcg_put "$user" "$dir" "$TG_CONNECT_GREETED_FILE" 2>/dev/null || true
  # The claude plugin's boot greeting (DIVE-5411) records the bot it greeted for
  # here; a plugin that predates connect-greeted.json then skips its boot arm.
  printf '%s\n' "$bot" | _tgcg_put "$user" "$dir" boot-greeted 2>/dev/null || true
}

# _tgcg_bridge_up <state_dir> <started_s> — the session's bridge holds the poll
# slot: its heartbeat was bumped after this run started.
_tgcg_bridge_up() {
  local hb
  hb=$(stat -c %Y "$1/bot.heartbeat" 2>/dev/null) || return 1
  (( hb >= $2 ))
}

# cmd_agent_tg_connect_greet <name> — hidden root primitive, the transient unit's
# body. Prints one JSON line of what it did (the unit's journal keeps it).
cmd_agent_tg_connect_greet() {
  local name="${1:-}"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "$E_USAGE" "usage: 5dive agent _tg_connect_greet <name>"
  local reg type user home dir token bot_id
  ensure_state
  reg=$(registry_read)
  type=$(jq -r --arg n "$name" '.agents[$n].type // empty' <<<"$reg")
  [[ -n "$type" ]] || fail "$E_NOT_FOUND" "no agent named '$name'"
  user="agent-${name}"
  home="${AGENT_HOME_ROOT:-/home}/${user}"
  dir=$(_tg_access_state_dir "$user" "$type") || fail "$E_VALIDATION" "type '$type' has no telegram bridge state dir"
  [[ "${AGENT_HOME_ROOT:-/home}" == /home ]] || dir="${home}${dir#"/home/${user}"}"
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "${CONNECTORS_DIR}/telegram-${name}.env" 2>/dev/null | head -1)
  [[ -n "$token" ]] || token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$dir/.env" 2>/dev/null | head -1)
  [[ "$token" =~ ^([0-9]+): ]] || fail "$E_NOT_FOUND" "no telegram token for '$name'"
  bot_id="${BASH_REMATCH[1]}"

  local -a owners=()
  mapfile -t owners < <(_tgcg_owners "$dir/access.json")
  (( ${#owners[@]} )) || { printf '{"greeted":[],"why":"no owner id in access.json"}\n'; return 0; }

  local started_s started_ms
  started_s=$(date +%s); started_ms=$(_tgcg_now_ms)
  local me bot_name about persona p_name p_welcome_en p_welcome_ru
  # Every call is `|| …`: the binary runs under set -e, and a network blip must
  # cost one send, never the run.
  me=$(_tgcg_call "$token" getMe) || me=""
  bot_name=$(jq -r '.result.first_name // empty' <<<"$me" 2>/dev/null) || bot_name=""
  about=$(jq -r '.result.short_description // empty' <<<"$(_tgcg_call "$token" getMyShortDescription)" 2>/dev/null) || about=""
  persona=$(_tgcg_persona "$home" "$type" en); p_name="${persona%%$'\t'*}"; p_welcome_en="${persona#*$'\t'}"
  [[ "$persona" == *$'\t'* ]] || { p_name=""; p_welcome_en=""; }
  persona=$(_tgcg_persona "$home" "$type" ru); p_welcome_ru="${persona#*$'\t'}"
  [[ "$persona" == *$'\t'* ]] || p_welcome_ru=""
  [[ -n "$p_name" ]] && bot_name="$p_name"

  local -A greeted=() pending=()
  local o resp text lang
  _tgcg_greet() { # <chat> <lang> — 0 sent, 1 not
    local w="$p_welcome_en"; [[ "$2" == ru ]] && w="$p_welcome_ru"
    text=$(_tgcg_text "$2" "$bot_name" "$about" "$w") || return 1
    resp=$(_tgcg_call "$token" sendMessage "$(jq -cn --arg c "$1" --arg t "$text" '{chat_id: ($c|tonumber), text: $t}')") || return 1
    [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == true ]]
  }
  for o in "${owners[@]}"; do
    if _tgcg_greet "$o" en; then greeted[$o]=1
    else pending[$o]=1   # 403 until they press Start: greet on their first message
    fi
  done
  (( ${#greeted[@]} )) && _tgcg_mark "$user" "$dir" "$bot_id" "$started_ms" "${!greeted[@]}"

  local tick=0 peek_ok=1 ups uid from lc
  local -A seen=()
  while (( $(date +%s) - started_s < TG_CONNECT_GREET_MAX_SEC )); do
    _tgcg_bridge_up "$dir" "$started_s" && break
    if (( tick % TG_CONNECT_TYPING_EVERY == 0 )); then
      for o in "${!greeted[@]}"; do
        _tgcg_call "$token" sendChatAction "{\"chat_id\":$o,\"action\":\"typing\"}" >/dev/null || true
      done
    fi
    if (( peek_ok && ${#pending[@]} && tick % TG_CONNECT_PEEK_EVERY == 0 )); then
      # No offset: nothing is confirmed, the bridge still gets every update.
      ups=$(_tgcg_call "$token" getUpdates '{"timeout":0,"limit":100}') || ups=""
      if [[ "$(jq -r '.ok // false' <<<"$ups" 2>/dev/null)" != true ]]; then
        peek_ok=0   # a webhook or another poller holds the bot: leave it alone
      else
        while IFS=$'\t' read -r uid from lc; do
          [[ -n "${seen[$uid]:-}" ]] && continue
          seen[$uid]=1
          [[ -n "${pending[$from]:-}" ]] || continue
          _tgcg_bridge_up "$dir" "$started_s" && break 2
          lang=$(_tgcg_lang "$lc")
          if _tgcg_greet "$from" "$lang"; then
            unset "pending[$from]"; greeted[$from]=1
            _tgcg_mark "$user" "$dir" "$bot_id" "$started_ms" "${!greeted[@]}"
            _tgcg_call "$token" sendChatAction "{\"chat_id\":$from,\"action\":\"typing\"}" >/dev/null || true
          fi
        done < <(jq -r '.result[] | select(.message.chat.type == "private")
                        | "\(.update_id)\t\(.message.from.id)\t\(.message.from.language_code // "")"' <<<"$ups" 2>/dev/null)
      fi
    fi
    sleep "$TG_CONNECT_GREET_TICK"
    tick=$((tick + 1))
  done
  local up=false; _tgcg_bridge_up "$dir" "$started_s" && up=true
  jq -cn --argjson up "$up" --argjson s "$(( $(date +%s) - started_s ))" \
    '{greeted: $ARGS.positional, bridgeUp: $up, seconds: $s}' --args "${!greeted[@]}"
}

# _tg_connect_greet_launch <name> <type> — start the greeter as a transient unit
# (DIVE-4973's pattern: systemd-run hands it to PID 1, so the exec that attached
# the bot can return, and the seat restart does not kill it). Best-effort.
_tg_connect_greet_launch() {
  local name="$1" type="$2"
  [[ "${FIVE_TG_CONNECT_GREET:-1}" == 1 ]] || return 0
  _tg_access_state_dir "agent-${name}" "$type" >/dev/null 2>&1 || return 0
  _tgcg_is_root || return 0
  local unit="5dive-tg-greet-${name}"
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  local -a env=(--setenv=PATH="$PATH" --setenv=HOME=/root)
  [[ -n "${FIVE_TG_API_BASE:-}" ]] && env+=(--setenv=FIVE_TG_API_BASE="$FIVE_TG_API_BASE")
  if command -v systemd-run >/dev/null 2>&1 \
     && systemd-run --quiet --collect --unit="$unit" \
          --property=RuntimeMaxSec=$(( TG_CONNECT_GREET_MAX_SEC + 30 )) "${env[@]}" \
          -- "$(_tgcg_self)" agent _tg_connect_greet "$name" >/dev/null 2>&1; then
    step "Greeting the owner on Telegram while '$name' starts (unit $unit)"
  else
    warn "could not start the Telegram connect greeting for '$name' — the agent greets on its first poll instead"
  fi
  return 0
}
