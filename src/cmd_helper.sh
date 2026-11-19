# -------- 5dive helper (DIVE-8819) --------
#
# Every paid 5dive server gets one "5dive" helper seat, role "Help & setup". It
# says hi once, answers how-to questions in two lines and suggests hires. It is
# not a hire: the registry marks it `system: "helper"`, `agent list --json`
# reports that field, and the plan's agent count (5dive-api plan-agent-cap) and
# My team skip any seat that carries it.
#
#   5dive helper ensure      root: build the seat if this box should have one (idempotent)
#   5dive helper status      eligible / seat / built / greeted, for a person or --json
#   (heartbeat tick)         _helper_tick: build it once, then greet once
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
# removes the seat, it is not built again. <state>/helper/greeted is claimed
# (noclobber) BEFORE the greeting is sent and dropped again only if the send
# fails, so a restart, a second tick or an update never greets twice.
#
# THE GREETING waits for an owner: the seat is running and the box has at least
# one hire (an unclaimed spare has none). It reads GET /helper/handover with the
# box token. 200 = the owner already said what the business does: skip the
# question and suggest 1-2 hires. 404 = ask the one question. Anything else is
# retried next tick, at most HELPER_HANDOVER_TRIES times, then it asks.

HELPER_AGENT="${HELPER_AGENT:-helper}"
HELPER_ACCOUNT="demo-ai"            # = CREATE_DEMO_AI_ACCOUNT (cmd_agent_create.sh)
HELPER_SYSTEM="helper"              # the registry/list marker every count skips
HELPER_UNIT="5dive-helper-ensure"
HELPER_HANDOVER_TRIES="${HELPER_HANDOVER_TRIES:-12}"
HELPER_BUILD_TRIES="${HELPER_BUILD_TRIES:-6}"   # a build that keeps failing stops after this many ticks

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

What you never do:
- Never take a job, never claim one, and never say "On it". If the owner asks you to do work, say which agent to hire for it.
- Never build, edit, restart or remove agents, and never change the server.
- Never say you messaged them first, and never talk about AI budgets, keys or limits.
EOF
}

# The one-time greeting, sent to the seat as a notice it turns into ONE message.
# <business> empty = the owner was never asked: ask the one question.
_helper_greeting() {
  local business="$1" suggested="$2"
  if [[ -n "$business" ]]; then
    printf '%s\n' "Send your owner your first and only welcome message now, where you normally talk to them. They already told 5dive what their business does: \"${business}\". Do not ask about it again."
    printf '%s\n' "Say hi as 5dive, then suggest one or two agents to hire for that business${suggested:+ (5dive suggested: ${suggested})}, a few words each on why. At most 50 words. Do not start any work."
  else
    printf '%s\n' "Send your owner your first and only welcome message now, where you normally talk to them."
    printf '%s\n' "Say hi as 5dive, say in a few words that you help them set up and choose agents, and ask one question: what does your business do? At most 40 words. Do not start any work."
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

# Claim, send, and roll the claim back only when the send failed.
_helper_greet() {
  local d tries=0 h="" rc=0 business="" suggested="" msg
  d=$(_helper_dir)
  h=$(_helper_handover) || rc=$?
  if (( rc == 1 )); then
    read -r tries 2>/dev/null <"$d/handover-tries" || tries=0
    [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
    tries=$((tries + 1)); printf '%s\n' "$tries" >"$d/handover-tries"
    (( tries < HELPER_HANDOVER_TRIES )) && return 1
  fi
  (( rc == 0 )) && IFS=$'\t' read -r business suggested <<<"$h"
  msg=$(_helper_greeting "$business" "$suggested")
  ( set -o noclobber; date -u +%FT%TZ >"$d/greeted" ) 2>/dev/null || return 0
  if ! "$(_helper_self)" agent _deliver --system-notice "$HELPER_AGENT" "$msg" >/dev/null 2>&1; then
    rm -f "$d/greeted"; return 1
  fi
  rm -f "$d/handover-tries"
  printf 'greeted (%s)\n' "$([[ -n "$business" ]] && echo 'from the handover' || echo 'asked the question')"
}

# The heartbeat's step. Prints one line when it did something, nothing otherwise.
_helper_tick() {
  local d reg seat
  d=$(_helper_dir)
  [[ -e "$d/greeted" ]] && return 0
  _helper_box_eligible || return 0
  mkdir -p "$d" 2>/dev/null || return 1
  reg="${1:-$(registry_read 2>/dev/null)}"
  seat=$(_helper_seat "$reg")
  case "$seat" in
    taken) return 0 ;;
    none)
      [[ -e "$d/built" ]] && return 0   # built once and the owner removed it
      _helper_build_spent && return 0
      if systemd-run --unit="$HELPER_UNIT" --collect --quiet \
           "$(_helper_self)" helper ensure >/dev/null 2>&1; then
        printf 'building the helper seat (unit %s)\n' "$HELPER_UNIT"
      fi
      return 0 ;;
  esac
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

_helper_build() {
  local d f self
  d=$(_helper_dir); self=$(_helper_self)
  local n=0; read -r n 2>/dev/null <"$d/build-tries" || n=0; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' $((n + 1)) >"$d/build-tries"
  "$self" agent create "$HELPER_AGENT" --type=claude --auth-profile="$HELPER_ACCOUNT" \
      --channels=dashboard --isolation=standard --no-heartbeat --no-team-bot </dev/null >&2 \
    || return 1
  lazy_need persona_install_doc
  f=$(mktemp) || return 1
  _helper_persona >"$f"
  persona_install_doc "$HELPER_AGENT" claude "$f" >&2 || { rm -f "$f"; return 1; }
  rm -f "$f"
  with_registry_lock _helper_mark || return 1
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
    mine)  ok "the helper seat is here" '{state:"present"}'; return 0 ;;
    taken) ok "no helper: an agent of yours is already named ${HELPER_AGENT}" '{state:"name-taken"}'; return 0 ;;
  esac
  [[ -e "$d/built" ]] && { ok "no helper: it was removed, so it stays removed" '{state:"removed"}'; return 0; }
  _helper_build || fail "$E_GENERIC" "could not build the helper seat (re-run: sudo 5dive helper ensure)"
  ok "built the helper seat '${HELPER_AGENT}' (5dive, Help & setup)" '{state:"built"}'
}

cmd_helper_status() {
  local d reg seat eligible=false built=false greeted=false
  d=$(_helper_dir)
  _helper_box_eligible && eligible=true
  [[ -e "$d/built" ]] && built=true
  [[ -e "$d/greeted" ]] && greeted=true
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
    *) fail "$E_USAGE" "usage: 5dive helper ensure|status [--json]" ;;
  esac
}
