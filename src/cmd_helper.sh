# -------- 5dive helper (DIVE-8819) --------
#
# Every paid 5dive server gets one "5dive" helper seat, role "Help & setup". It
# says hi once, answers how-to questions in two lines and suggests hires. It is
# not a hire: the registry marks it `system: "helper"`, `agent list --json`
# reports that field, and the plan's agent count (5dive-api plan-agent-cap) and
# My team skip any seat that carries it.
#
#   5dive helper ensure      root: build the seat if this box should have one (idempotent)
#   5dive helper status      eligible / seat / built / welcomed, for a person or --json
#   (heartbeat tick)         _helper_tick: build it once, then welcome the owner once
#
# WHICH BOXES. A box that holds the demo AI account (demo-ai): the account a
# paid my.5dive server is built with (5dive-api fivedive-box-key.ts). Self-hosted
# and partner boxes have none, so they never get a helper. The seat runs on that
# account and is its only user: an agent cannot build an agent on it (DIVE-6843),
# and the helper is a standard seat, so it has no sudo to try with.
#
# WHEN. The heartbeat tick (root, every 5 minutes on every managed box) calls
# _helper_tick, which is one stat once the greeting is out. A new server gets the
# seat within a tick of its demo account landing; an existing one within a tick
# of the nightly update that brings this CLI. The build runs detached in a
# transient unit with a fixed name, so a slow create never holds the tick, and
# two ticks cannot build it twice (systemd refuses a second unit of that name).
#
# ONCE. <state>/helper/built is written when the seat is built: if the owner
# removes the seat, it is not built again. <state>/helper/welcomed is claimed
# (noclobber) BEFORE the welcome is posted and dropped again only if the post
# fails, so a restart, a second tick or an update never welcomes twice.
#
# THE WELCOME waits for an owner: the seat is running and the box has at least
# one hire (an unclaimed spare has none). It reads GET /helper/handover with the
# box token. 200 = the owner already said what the business does: name it and
# suggest 1-2 hires. 404 = ask the one question. Anything else is retried next
# tick, at most HELPER_HANDOVER_TRIES times, then it asks.
#
# DIVE-8850: the BOX posts the welcome, as the helper, into the owner's app chat
# (POST /server/messages/event, the route the seat's own replies take). 0.138.0
# handed the seat a notice and let the model choose to reply: on one box in
# three it answered in its own terminal and the owner never saw it. The text is
# fixed here, so no model sits between the tick and the owner's app. A sealed
# chat (the owner already paired a device) gets it sealed by root, as the
# helper. One reply_key, so a post the API stored but whose answer was lost is
# not stored twice on the retry.
#
# 0.138.0 BOXES left <state>/helper/greeted (the notice went in, the reply may
# not have) and no `welcomed`, so the tick runs again there. Any box is welcomed
# unless the seat's own transcript shows it already called the app's reply tool
# (it answered that notice, or the owner wrote to it first): that is the one
# record on the box of a message it got out.

HELPER_AGENT="${HELPER_AGENT:-helper}"
HELPER_ACCOUNT="demo-ai"            # = CREATE_DEMO_AI_ACCOUNT (cmd_agent_create.sh)
HELPER_SYSTEM="helper"              # the registry/list marker every count skips
HELPER_UNIT="5dive-helper-ensure"
HELPER_HANDOVER_TRIES="${HELPER_HANDOVER_TRIES:-12}"
HELPER_BUILD_TRIES="${HELPER_BUILD_TRIES:-6}"   # a build that keeps failing stops after this many ticks
HELPER_REPLY_TOOL="mcp__plugin_dashboard_dashboard__reply"   # the seat's app reply (dashboard@5dive-plugins)
HELPER_REPLY_KEY="helper-welcome"   # /server/messages/event dedupes a retry on it (DIVE-7713)

_helper_dir()  { printf '%s/helper' "${HELPER_STATE_DIR:-$STATE_DIR}"; }
_helper_self() { printf '%s' "${FIVEDIVE_SELF_BIN:-/usr/local/bin/5dive}"; }

# The box should have a helper: it holds the demo AI account.
_helper_box_eligible() {
  [[ -n "${AUTH_PROFILES_DIR:-}" && -s "${AUTH_PROFILES_DIR}/${HELPER_ACCOUNT}/combined.env" ]]
}

# <reg> -> mine | taken | none. `taken` = an agent of the owner's own already has
# the name; the helper then leaves it alone for good.
_helper_seat() {
  jq -r --arg n "$HELPER_AGENT" --arg s "$HELPER_SYSTEM" '
    .agents[$n] as $a
    | if $a == null then "none" elif ($a.system // "") == $s then "mine" else "taken" end' <<<"$1" 2>/dev/null \
    || printf 'none'
}

# <reg> -> the number of agents that are not system seats (the owner's hires).
_helper_hires() {
  jq -r '[.agents // {} | to_entries[] | select((.value.system // "") == "" and .key != "sysadmin")] | length' <<<"$1" 2>/dev/null \
    || printf '0'
}

_helper_running() {
  [[ "$(systemctl is-active "5dive-agent@${HELPER_AGENT}.service" 2>/dev/null)" == "active" ]]
}

# What the seat is. Prepended to its CLAUDE.md; the lines are lodar's rules
# (DIVE-8740 / DIVE-8819) and do not change without him.
_helper_persona() {
  cat <<'EOF'
# You are 5dive: Help & setup

You are the 5dive helper on this server. You are not one of the owner's hired agents. You help the owner set up and use 5dive.

What you do:
- Answer how-to questions about 5dive in at most two short lines, in plain words, in the owner's language.
- When it fits, suggest one or two agents to hire from the Hire screen, and say in a few words why each one fits this business. The owner hires them there, the normal way.
- Telegram: the owner connects any agent, you too, by tapping the plane icon next to it in My team.

Your first message:
- 5dive already sent the owner your welcome for you: hi, and what does your business do (or, if they told 5dive already, one or two agents to hire). Never send another welcome. When they answer, suggest one or two agents.

What you never do:
- Never take a job, never claim one, and never say "On it". If the owner asks you to do work, say which agent to hire for it.
- Never build, edit, restart or remove agents, and never change the server.
- Never say you messaged them first, and never talk about AI budgets, keys or limits.
EOF
}

# _helper_cap <id> -> Theo (an agent id from the helper's fact sheet is its first name).
_helper_cap() { printf '%s' "${1^}"; }

# The one welcome, posted as the helper. <business> empty = the owner was never
# asked: ask the one question. <suggested> = "theo, dude" (at most two ids).
_helper_greeting() {
  local business="$1" suggested="$2" a b hire=""
  if [[ -z "$business" ]]; then
    printf '%s' "Hi, I'm 5dive, your helper on this server. I help you set up 5dive and choose your agents. What does your business do?"
    return 0
  fi
  (( ${#business} > 120 )) && business="${business:0:119}…"
  IFS=', ' read -r a b <<<"$suggested"
  [[ -n "$a" ]] && hire="$(_helper_cap "$a")${b:+ or $(_helper_cap "$b")}"
  if [[ -n "$hire" ]]; then
    printf '%s' "Hi, I'm 5dive, your helper on this server. For your business (${business}), a good first hire is ${hire}: find them on the Hire screen. Ask me anything about setting up."
  else
    printf '%s' "Hi, I'm 5dive, your helper on this server. You told me about your business: ${business}. Tell me what you want done first, and I'll suggest who to hire."
  fi
}

# GET /helper/handover with the box token. Prints "<business>\t<slug, slug>" and
# rc 0 on 200, rc 3 on 404 (never asked), rc 1 on anything else (retry).
_helper_handover() {
  lazy_need _partner_box_token _partner_api_base
  local tok url body http
  tok=$(_partner_box_token 2>/dev/null) || return 1
  url="$(_partner_api_base)/helper/handover"
  body=$(mktemp) || return 1
  # The bearer rides stdin (`-H @-`), never argv (DIVE-5168).
  http=$(printf 'Authorization: Bearer %s\n' "$tok" \
           | curl -sS --max-time 15 "$url" -H @- -o "$body" -w '%{http_code}' 2>/dev/null) || http=000
  case "$http" in
    200) jq -r '[(.business // "" | tostring | gsub("[\\t\\r\\n]+"; " ") | .[0:300]),
                 ([.suggested // [] | .[] | strings | select(test("^[a-z0-9][a-z0-9_-]{0,63}$"))][0:2] | join(", "))] | @tsv' \
           "$body" 2>/dev/null; local rc=$?; rm -f "$body"; return $(( rc == 0 ? 0 : 1 )) ;;
    404) rm -f "$body"; return 3 ;;
    *)   rm -f "$body"; return 1 ;;
  esac
}

# _helper_post <text> — root: post <text> into the owner's app chat AS the
# helper. rc 0 only when the API stored it.
_helper_post() {
  local text="$1" tok base body out code live side env
  lazy_need _dash_relay_call _dash_relay_api_base _dash_relay_token
  tok=$(_dash_relay_token 2>/dev/null) || return 1
  [[ -n "$tok" ]] || return 1
  base=$(_dash_relay_api_base) || return 1
  body=$(jq -nc --arg a "$HELPER_AGENT" --arg b "$text" --arg k "$HELPER_REPLY_KEY" \
           '{agent:$a, body:$b, metadata:{reply_key:$k}}') || return 1
  out=$( (_dash_relay_call POST "${base}/server/messages/event" "$body" "$tok" 20) 2>/dev/null ) || return 1
  code="${out%%$'\n'*}"
  [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0
  # 409 = the chat is sealed (the owner paired a device): root seals it as the
  # helper, in the DM conversation every sealed chat post uses ("dashboard").
  [[ "$code" == 409 ]] || return 1
  lazy_need _chat_e2e_live _chat_e2e_run
  live=$(_chat_e2e_live)
  [[ -f "$live/box.jwk" ]] || return 1
  side=$(mktemp) || return 1
  env=$(jq -nc --arg t "$text" --arg m "b-${HELPER_REPLY_KEY}" '{op:"seal", conv:"dashboard", m:$m, msg:{text:$t}}' \
          | (_chat_e2e_run call "$live" "$side" "$HELPER_AGENT") 2>/dev/null | jq -c '.env // empty' 2>/dev/null) || env=""
  rm -f "$side"
  [[ -n "$env" ]] || return 1
  body=$(jq -nc --arg a "$HELPER_AGENT" --arg b "$env" --arg k "$HELPER_REPLY_KEY" \
           '{agent:$a, body:$b, metadata:{chat_id:"dashboard", reply_key:$k, e2e:{v:1}}}') || return 1
  out=$( (_dash_relay_call POST "${base}/server/messages/event" "$body" "$tok" 20) 2>/dev/null ) || return 1
  [[ "${out%%$'\n'*}" =~ ^2[0-9][0-9]$ ]]
}

# The seat already got a message out to the app: its transcript holds a call to
# the app's reply tool (a 0.138.0 notice it answered, or the owner wrote first).
_helper_seat_replied() {
  local home f
  home="${HELPER_SEAT_HOME:-$(getent passwd "agent-${HELPER_AGENT}" 2>/dev/null | cut -d: -f6)}"
  home="${home:-/home/agent-${HELPER_AGENT}}"
  for f in "$home"/.claude/projects/*/*.jsonl; do
    [[ -f "$f" ]] || continue
    grep -qF "\"name\":\"${HELPER_REPLY_TOOL}\"" -- "$f" 2>/dev/null && return 0
  done
  return 1
}

# Claim, post, and roll the claim back only when the post failed.
_helper_greet() {
  local d tries=0 h="" rc=0 business="" suggested="" msg
  d=$(_helper_dir)
  if _helper_seat_replied; then
    ( set -o noclobber; printf '%s the seat already wrote in the app\n' "$(date -u +%FT%TZ)" >"$d/welcomed" ) 2>/dev/null
    printf 'no welcome: the helper already wrote to the owner in the app\n'
    return 0
  fi
  h=$(_helper_handover) || rc=$?
  if (( rc == 1 )); then
    read -r tries 2>/dev/null <"$d/handover-tries" || tries=0
    [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
    tries=$((tries + 1)); printf '%s\n' "$tries" >"$d/handover-tries"
    (( tries < HELPER_HANDOVER_TRIES )) && return 1
  fi
  (( rc == 0 )) && IFS=$'\t' read -r business suggested <<<"$h"
  msg=$(_helper_greeting "$business" "$suggested")
  ( set -o noclobber; date -u +%FT%TZ >"$d/welcomed" ) 2>/dev/null || return 0
  if ! _helper_post "$msg"; then
    rm -f "$d/welcomed"; return 1
  fi
  rm -f "$d/handover-tries"
  printf 'welcomed the owner in the app (%s)\n' "$([[ -n "$business" ]] && echo 'from the handover' || echo 'asked the question')"
}

# The heartbeat's step. Prints one line when it did something, nothing otherwise.
_helper_tick() {
  local d reg seat
  d=$(_helper_dir)
  [[ -e "$d/welcomed" ]] && return 0
  _helper_box_eligible || return 0
  mkdir -p "$d" 2>/dev/null || return 1
  reg="${1:-$(registry_read 2>/dev/null)}"
  seat=$(_helper_seat "$reg")
  case "$seat" in
    taken) return 0 ;;
    none) [[ -e "$d/built" ]] && return 0 ;;   # built once and the owner removed it
  esac
  # No seat yet, or a seat whose build stopped half way (marked, no persona):
  # `helper ensure` creates what is missing and finishes the rest.
  if [[ ! -e "$d/built" ]]; then
    _helper_build_spent && return 0
    if systemd-run --unit="$HELPER_UNIT" --collect --quiet \
         "$(_helper_self)" helper ensure >/dev/null 2>&1; then
      printf 'building the helper seat (unit %s)\n' "$HELPER_UNIT"
    fi
    return 0
  fi
  (( $(_helper_hires "$reg") > 0 )) || return 0
  _helper_running || return 0
  _helper_greet
}

# <state>/helper/build-tries: one per attempt, so a box where the create keeps
# failing stops trying after HELPER_BUILD_TRIES ticks instead of every 5 minutes.
_helper_build_spent() {
  local n=0
  read -r n 2>/dev/null <"$(_helper_dir)/build-tries" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n >= HELPER_BUILD_TRIES ))
}

# <seat> = none | mine. The system mark goes on right after the create, so a
# build that stops later (persona, restart) still leaves a seat that is not a
# hire and reads `mine`; the next tick finishes it (no `built` yet).
_helper_build() {
  local seat="$1" d f self
  d=$(_helper_dir); self=$(_helper_self)
  local n=0; read -r n 2>/dev/null <"$d/build-tries" || n=0; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' $((n + 1)) >"$d/build-tries"
  if [[ "$seat" == none ]]; then
    "$self" agent create "$HELPER_AGENT" --type=claude --auth-profile="$HELPER_ACCOUNT" \
        --channels=dashboard --isolation=standard --no-heartbeat --no-team-bot </dev/null >&2 \
      || return 1
  fi
  with_registry_lock _helper_mark || return 1
  lazy_need persona_install_doc
  f=$(mktemp) || return 1
  _helper_persona >"$f"
  persona_install_doc "$HELPER_AGENT" claude "$f" >&2 || { rm -f "$f"; return 1; }
  rm -f "$f"
  date -u +%FT%TZ >"$d/built"
  "$self" agent restart "$HELPER_AGENT" </dev/null >/dev/null 2>&1 || true
}

_helper_mark() {
  local reg
  reg=$(registry_read) || return 1
  jq --arg n "$HELPER_AGENT" --arg s "$HELPER_SYSTEM" \
     '.agents[$n] += {system: $s, displayName: "5dive", role: "Help & setup"}' <<<"$reg" | registry_write
}

cmd_helper_ensure() {
  require_root "helper ensure"
  local d reg seat
  d=$(_helper_dir); mkdir -p "$d"
  _helper_box_eligible || { ok "no helper: this box has no demo AI account" '{state:"not-eligible"}'; return 0; }
  reg=$(registry_read)
  seat=$(_helper_seat "$reg")
  case "$seat" in
    mine)  [[ -e "$d/built" ]] && { ok "the helper seat is here" '{state:"present"}'; return 0; } ;;
    taken) ok "no helper: an agent of yours is already named ${HELPER_AGENT}" '{state:"name-taken"}'; return 0 ;;
    none)  [[ -e "$d/built" ]] && { ok "no helper: it was removed, so it stays removed" '{state:"removed"}'; return 0; } ;;
  esac
  _helper_build "$seat" || fail "$E_GENERIC" "could not build the helper seat (re-run: sudo 5dive helper ensure)"
  ok "built the helper seat '${HELPER_AGENT}' (5dive, Help & setup)" '{state:"built"}'
}

cmd_helper_status() {
  local d reg seat eligible=false built=false greeted=false
  d=$(_helper_dir)
  _helper_box_eligible && eligible=true
  [[ -e "$d/built" ]] && built=true
  [[ -e "$d/welcomed" ]] && greeted=true
  reg=$(registry_read 2>/dev/null) || reg='{}'
  seat=$(_helper_seat "$reg")
  ok "helper: eligible=$eligible seat=$seat built=$built greeted=$greeted" \
     '{eligible:$e, seat:$s, built:$b, greeted:$g, agent:$n}' \
     --argjson e "$eligible" --arg s "$seat" --argjson b "$built" --argjson g "$greeted" --arg n "$HELPER_AGENT"
}

cmd_helper() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    ensure) cmd_helper_ensure "$@" ;;
    status) cmd_helper_status "$@" ;;
    help|-h|--help)
      cat <<'EOF'
usage: 5dive helper ensure|status [--json]

The "5dive" Help & setup seat on a paid 5dive server. It is not a hire.

  5dive helper status   is this box eligible, is the seat here, built, welcomed
  5dive helper ensure   root: build the seat if this box should have one
EOF
      ;;
    *) fail "$E_USAGE" "usage: 5dive helper ensure|status [--json]" ;;
  esac
}
