# ─────────────────────────────────────────────────────────────────────────────
# DIVE-159 — Team group setup (personal-bot model). Each telegram agent keeps
# its OWN bot. The customer makes one Telegram group (Topics on) and adds each
# agent's bot as admin. This command creates a forum topic per agent and binds
# each agent's access.json so it replies ONLY in its own topic (no @mention),
# while its private DM bot keeps working unchanged. No central listener.
#
#   5dive agent team-bot status    --group=<chat_id>             (read-only probe)
#   5dive agent team-bot provision --group=<chat_id> [--owner=<user_id>]
#
# Per-agent status:
#   ready       — bot is admin in the group and bound to its topic
#   needs_add   — bot is not in the group yet (customer must add it)
#   needs_admin — bot is in the group but not an admin (can't read messages)
#   no_token    — no telegram bot token on file for the agent
#   error       — a Telegram call failed (detail in `error`)
# provision is idempotent: re-running re-uses an agent's existing topic.
# DIVE-453 — resolve the on-box Chief-of-Staff bot token (set by `agent cos set`,
# stored in connectors/cos.env) so the CoS-native team-group flow never pastes a
# separate token. Mirrors cmd_cos.sh's resolver (TEST_TG_COS_BOT_TOKEN or
# COS_BOT_TOKEN). Prints the token to stdout; non-zero exit if none configured.
_cos_token_resolve() {
  local env_file="${COS_ENV_FILE:-/etc/5dive/connectors/cos.env}"
  [[ -r "$env_file" ]] || return 1
  local line
  line=$(grep -m1 -oE '^[[:space:]]*(TEST_TG_COS_BOT_TOKEN|COS_BOT_TOKEN)[[:space:]]*=[[:space:]]*[^[:space:]]+' "$env_file" 2>/dev/null) || return 1
  [[ -n "$line" ]] || return 1
  printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]*//'
}

# DIVE-453 — record the claim<->listener handshake: once the fleet rides the CoS
# bot (`team-group shared --use-cos`), the always-on CoS-token listener is the
# sole getUpdates consumer, so `cos claim` must read minted children from the
# spool instead of its own getUpdates (which would 409 the listener). Persist
# COS_CLAIM_SPOOL_DIR in cos.env (idempotent) — the same file claim reads the
# token from. Absent on boxes that never ran --use-cos => claim's original path.
_cos_set_claim_spool() {
  local env_file="${COS_ENV_FILE:-/etc/5dive/connectors/cos.env}"
  local spool="${COS_CLAIM_SPOOL_DIR_DEFAULT:-/var/lib/5dive/cos-claims}"
  [[ -w "$env_file" || -w "$(dirname "$env_file")" ]] || return 0
  if grep -q '^COS_CLAIM_SPOOL_DIR=' "$env_file" 2>/dev/null; then
    sed -i -E "s#^COS_CLAIM_SPOOL_DIR=.*#COS_CLAIM_SPOOL_DIR=${spool}#" "$env_file"
  else
    printf 'COS_CLAIM_SPOOL_DIR=%s\n' "$spool" >> "$env_file"
  fi
}

# DIVE-453 — `5dive agent team-group <discover|provision|shared|status> …`: the
# slim CoS-native team group. Identical to `team-bot` but rides the connected
# Chief-of-Staff bot (token resolved server-side) — the customer adds ONE bot
# (their CoS) to a Topics group as admin and every agent gets a topic, with no
# separate team-bot token to paste. Thin wrapper: inject --use-cos.
cmd_agent_team_group() {
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent team-group discover|provision|shared|status [--group=<chat_id>] [--agents=<csv>] [--owner=<user_id>]"
  local sub="$1"; shift
  cmd_agent_team_bot "$sub" --use-cos "$@"
}

cmd_agent_team_bot() {
  local sub="" group="" owner="" agents_filter="" token="" off="" use_cos="" cos_token=""
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive agent team-bot status|provision|shared|intercom|discover --group=<chat_id> [--owner=<user_id>]"
  sub="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --group=*) group="${1#--group=}" ;;
      --owner=*) owner="${1#--owner=}" ;;
      --agents=*) agents_filter="${1#--agents=}" ;;
      --token=*) token="${1#--token=}" ;;
      --use-cos) use_cos=1 ;;
      --off) off=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  case "$sub" in status|provision|shared|intercom|discover|refresh-listener) ;; *) fail "$E_USAGE" "unknown team-bot command: $sub (status|provision|shared|intercom|discover|refresh-listener)" ;; esac

  # DIVE-1095 — `refresh-listener`: re-materialize /opt/5dive/team-bot-listener.ts
  # from the current bundle and restart the service, so listener-only fixes (e.g.
  # DIVE-1093's tap handling) self-deploy on nightly host-updates — which install
  # the fresh binary + restart agents but never rewrote the listener TS. No args,
  # no token, guarded on the unit file => a clean no-op on boxes with no shared
  # team-bot. Called by 5dive-host-updates.sh (nightly) and reused for on-demand.
  if [[ "$sub" == "refresh-listener" ]]; then
    ensure_state
    if [[ -f /etc/systemd/system/5dive-team-bot-listener.service ]]; then
      _team_bot_install_listener
      ok "shared team-bot listener refreshed" '{listener_refreshed:true}'
    else
      ok "no shared team-bot listener on this box — nothing to refresh" '{listener_refreshed:false}'
    fi
    return
  fi

  # DIVE-453 — CoS-native team group (`5dive agent team-group …`). Instead of a
  # separately-pasted shared bot token, ride the already-connected Chief-of-Staff
  # bot: resolve its token server-side from connectors/cos.env (set by `agent cos
  # set`) and feed it into the same discover/provision/shared machinery. The token
  # never leaves the box — the slim dashboard surface only ever sends `--use-cos`.
  if [[ -n "$use_cos" ]]; then
    cos_token=$(_cos_token_resolve) || true
    [[ -n "$cos_token" ]] || fail "$E_NOT_FOUND" "no Chief of Staff connected on this box — connect one first (agent cos set), then set up the team group"
    # discover + shared route through $token; provision picks up $cos_token below.
    token="$cos_token"
  fi

  # `discover` (DIVE-247) = find the team group with the bot itself — no
  # --group needed (that id is exactly what it returns). Handled before the
  # --group validation below.
  if [[ "$sub" == "discover" ]]; then
    ensure_state
    _team_bot_do_discover "$token"
    return
  fi

  [[ "$group" =~ ^-?[0-9]+$ ]] || fail "$E_VALIDATION" "--group must be a Telegram chat id (negative for supergroups)"
  [[ -z "$owner" || "$owner" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--owner must be a numeric Telegram user id"
  ensure_state

  # `shared` = the shared-team-bot path for agents WITHOUT their own bot. The
  # customer pastes ONE bot token; each selected no-bot agent gets a forum topic
  # and runs the telegram plugin in send-only mode against that token, while a
  # single listener routes inbound topic->agent. Self-contained handler.
  if [[ "$sub" == "shared" ]]; then
    # DIVE-453: with --use-cos this is the moment the fleet starts riding the
    # CoS bot, so the CoS-token listener becomes the SOLE getUpdates consumer.
    # Persist the claim-spool handshake BEFORE the listener restart inside
    # _team_bot_do_shared, so `cos claim` (which reads cos.env) never races a
    # CoS-owned listener with no spool set. Written to cos.env (where claim
    # already reads the token); absent on boxes that never ran --use-cos =>
    # claim's original direct-getUpdates path (main's backward-compat).
    [[ -n "$use_cos" ]] && _cos_set_claim_spool
    if [[ -n "$use_cos" ]]; then
      # DIVE-195 + DIVE-453: the CoS team group also gets a shared intercom
      # topic so inter-agent comms mirror there automatically (the mirror
      # already handles send-only shared-bot agents). Capture shared's result,
      # create the intercom topic best-effort (output suppressed so we still
      # emit a single JSON envelope — the per-agent relay is the real success),
      # then print shared's result. No per-agent wiring needed: the mirror reads
      # each agent's group from access.json, which _team_bot_do_shared just set.
      local _shared_out _shared_rc=0
      _shared_out=$(_team_bot_do_shared "$group" "$owner" "$agents_filter" "$token") || _shared_rc=$?
      (( _shared_rc == 0 )) && { _team_bot_do_intercom "$group" "" >/dev/null 2>&1 || true; }
      printf '%s\n' "$_shared_out"
      return "$_shared_rc"
    fi
    _team_bot_do_shared "$group" "$owner" "$agents_filter" "$token"
    return
  fi

  # `intercom` (DIVE-195) = one dedicated topic in the team group where all
  # inter-agent chatter is mirrored (consolidated, not scattered per-agent).
  # Creates the topic + records it; the mirror (mirror_interagent_outbound)
  # then routes there. --off removes it.
  if [[ "$sub" == "intercom" ]]; then
    _team_bot_do_intercom "$group" "$off"
    return
  fi

  # Build {agent: {token, type, stateDir, threadId}} for every eligible telegram
  # agent. Token + state-dir resolution stays server-side; the dashboard only
  # ever sees the resulting status, never a bot token.
  local reg; reg=$(registry_read)
  local agents_json="{}"
  local name type token state_dir tt
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -n "$agents_filter" ]] && [[ ",${agents_filter}," != *",${name},"* ]]; then continue; fi
    # Skip agents wired send-only on the shared team bot — they're relayed, not
    # personal-bot members, and surface in the `relay` list below instead.
    if grep -q '^TELEGRAM_SEND_ONLY=1' "${CONNECTORS_DIR}/telegram-${name}.env" 2>/dev/null; then continue; fi
    type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    token=$(_team_bot_token "$name")
    state_dir=$(_tg_access_state_dir "agent-${name}" "$type" 2>/dev/null || echo "")
    tt=$(jq -c --arg n "$name" '.agents[$n].teamTopic // null' <<<"$reg")
    agents_json=$(jq -c --arg n "$name" --arg tok "$token" --arg ty "$type" --arg sd "$state_dir" --argjson tt "$tt" \
      '.[$n] = {token:$tok, type:$ty, stateDir:$sd, teamTopic:$tt}' <<<"$agents_json")
  done < <(_team_bot_agent_list)

  # Relay list = agents WITHOUT a personal bot (or already wired send-only on the
  # shared team bot). Computed from local state only (no Telegram calls) so the
  # card can render the shared-bot section. status/provision both report it.
  local relay; relay=$(_team_bot_relay_status "$group")

  # Only error when there's nothing at all to show — no personal-bot agents AND
  # no relay candidates. (A customer may have only no-bot agents.)
  if [[ "$agents_json" == "{}" && "$relay" == "[]" ]]; then
    fail "$E_NOT_FOUND" "no telegram agents to add to a team group"
  fi

  # Heavy lifting in Python: Telegram getMe/getChatMember/createForumTopic +
  # atomic access.json merge (root writes then chowns to agent-<name>). Emits a
  # results JSON array on stdout. teamTopic registry updates come back as a side
  # channel (RESULTS_FILE) so we can persist them under the registry lock.
  # DIVE-453: with --use-cos, provision creates topics through the Chief-of-Staff
  # bot (resolved above) instead of the separate shared team-bot token.
  local team_token=""
  if [[ -n "$cos_token" ]]; then team_token="$cos_token"
  elif [[ -r /etc/5dive/team-bot.token ]]; then team_token=$(cat /etc/5dive/team-bot.token 2>/dev/null); fi
  local reg_updates_file; reg_updates_file=$(mktemp)
  local results
  results=$(MODE="$sub" GROUP="$group" OWNER="$owner" AGENTS="$agents_json" TEAM_BOT_TOKEN="$team_token" REG_UPDATES_FILE="$reg_updates_file" python3 - <<'PY'
import json, os, re, tempfile, pwd, urllib.parse, urllib.request

MODE  = os.environ['MODE']
GROUP = os.environ['GROUP']
OWNER = os.environ.get('OWNER') or ''
TEAM  = os.environ.get('TEAM_BOT_TOKEN') or ''
AGENTS = json.loads(os.environ['AGENTS'])

def tg(token, method, **params):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}

# First pass: identify each bot + its membership; find a topic-manager bot.
info = {}
manager_token = None
for name, a in AGENTS.items():
    rec = {"agent": name, "status": "error", "botUsername": None, "threadId": None}
    info[name] = rec
    token = a.get("token") or ""
    if not token:
        rec["status"] = "no_token"; continue
    me = tg(token, "getMe")
    if not me.get("ok"):
        rec["error"] = me.get("description", "getMe failed"); continue
    bot_id = me["result"]["id"]
    rec["botUsername"] = me["result"].get("username")
    rec["_token"] = token
    rec["_botId"] = bot_id
    m = tg(token, "getChatMember", chat_id=GROUP, user_id=bot_id)
    if not m.get("ok"):
        # Not a member → Telegram returns ok:false ("user not found" / "chat not found").
        rec["status"] = "needs_add"; continue
    st = m["result"].get("status")
    if st in ("administrator", "creator"):
        rec["status"] = "admin_ok"  # provisional; topic binding decided below
        # Only a bot that can actually manage topics qualifies as the topic
        # creator (creators implicitly can, even without the flag set).
        if (m["result"].get("can_manage_topics") or st == "creator") and manager_token is None:
            manager_token = token
    elif st in ("member", "restricted"):
        rec["status"] = "needs_admin"
    else:  # left / kicked
        rec["status"] = "needs_add"

# Fleet fallback: the shared team bot is the group's topic janitor (customers
# have no such file — they rely on an agent bot with Manage Topics instead).
if manager_token is None and TEAM:
    me = tg(TEAM, "getMe")
    if me.get("ok"):
        mm = tg(TEAM, "getChatMember", chat_id=GROUP, user_id=me["result"]["id"])
        if mm.get("ok") and mm["result"].get("status") in ("administrator", "creator") and mm["result"].get("can_manage_topics"):
            manager_token = TEAM

results = []
reg_updates = {}  # name -> {threadId, chatId}
for name, rec in info.items():
    out = {"agent": rec["agent"], "botUsername": rec.get("botUsername"),
           "status": rec["status"], "threadId": rec.get("threadId")}
    if rec.get("error"): out["error"] = rec["error"]

    if rec["status"] != "admin_ok":
        # not bound; surface as-is (needs_add / needs_admin / no_token / error)
        out["status"] = rec["status"] if rec["status"] != "admin_ok" else "ready"
        results.append(out); continue

    a = AGENTS[name]
    existing = a.get("teamTopic") or {}
    thread = existing.get("threadId") if existing.get("chatId") == int(GROUP) else None

    if MODE == "status":
        out["status"] = "ready" if thread else "needs_topic"
        out["threadId"] = thread
        results.append(out); continue

    # provision: create the topic if missing, then wire access.json.
    if not thread:
        if not manager_token:
            out["status"] = "error"; out["error"] = "no admin bot can manage topics"
            results.append(out); continue
        cf = tg(manager_token, "createForumTopic", chat_id=GROUP, name=name)
        if not cf.get("ok"):
            out["status"] = "error"; out["error"] = cf.get("description", "createForumTopic failed")
            results.append(out); continue
        thread = cf["result"]["message_thread_id"]

    # Merge the group entry into the agent's access.json (root writes + chowns).
    sd = a.get("stateDir") or ""
    if sd:
        path = os.path.join(sd, "access.json")
        try:
            acc = json.load(open(path)) if os.path.exists(path) else {}
        except Exception:
            acc = {}
        acc.setdefault("dmPolicy", "pairing")
        acc.setdefault("allowFrom", [])
        acc.setdefault("groups", {})
        acc.setdefault("pending", {})
        entry = {"requireMention": False,
                 "allowFrom": [OWNER] if OWNER else [],
                 "message_thread_id": int(thread)}
        acc["groups"][GROUP] = entry
        os.makedirs(sd, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=sd)
        with os.fdopen(fd, "w") as f:
            json.dump(acc, f, indent=2)
        try:
            u = pwd.getpwnam("agent-" + name)
            os.chown(tmp, u.pw_uid, u.pw_gid); os.chmod(tmp, 0o600)
            os.replace(tmp, path); os.chown(path, u.pw_uid, u.pw_gid)
        except KeyError:
            os.replace(tmp, path)

    reg_updates[name] = {"threadId": int(thread), "chatId": int(GROUP)}
    out["status"] = "ready"; out["threadId"] = int(thread)
    if rec.get("botUsername"):
        out["topicLink"] = f"https://t.me/{rec['botUsername']}"  # opens the bot; topic deep-links are client-built
    results.append(out)

with open(os.environ.get("REG_UPDATES_FILE", "/dev/null"), "w") as f:
    json.dump(reg_updates, f)

print(json.dumps(results))
PY
)
  local rc=$?
  [[ $rc -eq 0 && -n "$results" ]] || fail "$E_GENERIC" "team-bot $sub failed"

  # Persist teamTopic registry updates under the lock (provision only).
  if [[ "$sub" == "provision" && -s "$reg_updates_file" ]]; then
    with_registry_lock _team_bot_persist_topics "$reg_updates_file"
  fi
  rm -f "$reg_updates_file"

  local ready total
  ready=$(jq '[.[] | select(.status=="ready")] | length' <<<"$results")
  total=$(jq 'length' <<<"$results")
  # Intercom topic (DIVE-195) for this group, if configured — so the card can
  # show "intercom on" + a link.
  local intercom
  intercom=$(jq -c --arg g "$group" 'if (.intercomTopic.chatId|tostring) == $g then .intercomTopic else null end' <<<"$(registry_read)")
  ok "team-bot $sub: $ready/$total agents ready in group $group" \
     '{group:$g, agents:$a, relay:$r, intercom:$ic}' \
     --arg g "$group" --argjson a "$results" --argjson r "$relay" --argjson ic "$intercom"
}

# Helpers for cmd_agent_team_bot (kept module-local).
_team_bot_agent_list() {
  jq -r '.agents | to_entries[]
    | select(.value.channels=="telegram")
    | select(.value.type=="claude" or .value.type=="codex" or .value.type=="grok" or .value.type=="antigravity")
    | .key' <<<"$(registry_read)"
}
_team_bot_token() {
  sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "${CONNECTORS_DIR}/telegram-${1}.env" 2>/dev/null | head -1
}
_team_bot_persist_topics() {
  local updates_file="$1" reg
  reg=$(registry_read)
  reg=$(jq --slurpfile u "$updates_file" '
    .agents as $a
    | reduce ($u[0] | to_entries[]) as $e (.;
        if .agents[$e.key] != null
        then .agents[$e.key].teamTopic = $e.value
        else . end)
  ' <<<"$reg")
  registry_write <<<"$reg"
}

# ─────────────────────────────────────────────────────────────────────────────
# DIVE-159 — shared-team-bot path (agents WITHOUT their own bot).
#
# An agent with no personal Telegram bot can still live in the team group by
# routing through ONE shared bot: the agent runs the telegram plugin in
# send-only mode against the shared token (never polls — Telegram allows a
# single getUpdates consumer per token), and a single listener daemon maps each
# inbound topic message back to the right agent's relay-in/. This is the hybrid
# completion of the personal-bot card: personal-bot agents join with their own
# bot; no-bot agents route through the shared bot. The two never overlap.
# ─────────────────────────────────────────────────────────────────────────────

# Relay candidates = plugin-capable agents that either have NO personal bot
# (channels != telegram) or are already wired send-only on the shared bot.
# Echoes one agent name per line.
_team_bot_relay_agent_list() {
  local reg name ch
  reg=$(registry_read)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if grep -q '^TELEGRAM_SEND_ONLY=1' "${CONNECTORS_DIR}/telegram-${name}.env" 2>/dev/null; then
      echo "$name"; continue
    fi
    ch=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
    # Membership check, not equality: "telegram,dashboard" is a personal bot
    # too and must never be flipped to the shared send-only relay (DIVE-856).
    channel_in_list telegram "$ch" || echo "$name"
  done < <(jq -r '.agents | to_entries[]
    | select(.value.type=="claude" or .value.type=="codex" or .value.type=="grok" or .value.type=="antigravity")
    | .key' <<<"$reg")
}

# Relay status array for the dashboard — local state only, no Telegram calls.
# Per agent: "relayed" (wired send-only + topic bound to this group) or
# "no_bot" (eligible, not yet relayed).
_team_bot_relay_status() {
  local group="$1" reg out name tt sendonly ttchat ttthread status threadId
  reg=$(registry_read)
  out="[]"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tt=$(jq -c --arg n "$name" '.agents[$n].teamTopic // null' <<<"$reg")
    sendonly=0
    grep -q '^TELEGRAM_SEND_ONLY=1' "${CONNECTORS_DIR}/telegram-${name}.env" 2>/dev/null && sendonly=1
    status="no_bot"; threadId="null"
    if [[ "$tt" != "null" ]]; then
      ttchat=$(jq -r '.chatId' <<<"$tt")
      ttthread=$(jq -r '.threadId' <<<"$tt")
      if [[ "$ttchat" == "$group" && "$sendonly" == "1" ]]; then
        status="relayed"; threadId="$ttthread"
      fi
    fi
    out=$(jq -c --arg n "$name" --arg s "$status" --argjson th "$threadId" \
      '. + [{agent:$n, status:$s, threadId:$th}]' <<<"$out")
  done < <(_team_bot_relay_agent_list)
  printf '%s' "$out"
}

# Force a relay agent's connector env to the shared token + send-only, preserving
# any unrelated keys. root:claude 640 (same as install_channel writes).
_team_bot_write_sendonly_env() {
  local name="$1" token="$2" tmp
  local ef="${CONNECTORS_DIR}/telegram-${name}.env"   # separate stmt: ${name} aborts under set -u if same line
  mkdir -p "$CONNECTORS_DIR"
  tmp=$(mktemp)
  { printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token"
    printf 'TELEGRAM_SEND_ONLY=1\n'
    [[ -f "$ef" ]] && grep -vE '^(TELEGRAM_BOT_TOKEN|TELEGRAM_SEND_ONLY)=' "$ef" 2>/dev/null
  } > "$tmp"
  chown root:claude "$tmp" 2>/dev/null || true
  chmod 640 "$tmp"
  mv "$tmp" "$ef"
}

# Persist channels=telegram + teamTopic for each relayed agent (under reg lock).
_team_bot_persist_shared() {
  local updates_file="$1" reg
  reg=$(registry_read)
  reg=$(jq --slurpfile u "$updates_file" '
    .agents as $a
    | reduce ($u[0] | to_entries[]) as $e (.;
        if .agents[$e.key] != null
        then .agents[$e.key].teamTopic = $e.value
           # keep a DIVE-856 default dashboard channel alongside the relay
           | .agents[$e.key].channels =
               (if ((.agents[$e.key].channels // "none") | split(",") | index("dashboard"))
                then "telegram,dashboard" else "telegram" end)
        else . end)
  ' <<<"$reg")
  registry_write <<<"$reg"
}

# `5dive agent team-bot intercom --group=<id> [--off]` (DIVE-195)
# Create (idempotent) one dedicated "intercom" topic in the team group + record
# it fleet-wide in the registry as .intercomTopic, so mirror_interagent_outbound
# consolidates all inter-agent chatter there. --off removes it.
_team_bot_do_intercom() {
  local group="$1" off="$2"
  local reg; reg=$(registry_read)

  if [[ "$off" == "1" ]]; then
    local tt; tt=$(jq -c '.intercomTopic // null' <<<"$reg")
    with_registry_lock _team_bot_clear_intercom
    if [[ "$tt" != "null" ]]; then
      local th tc team_token=""
      th=$(jq -r '.threadId' <<<"$tt"); tc=$(jq -r '.chatId' <<<"$tt")
      [[ -r /etc/5dive/team-bot.token ]] && team_token=$(cat /etc/5dive/team-bot.token 2>/dev/null)
      [[ -n "$team_token" && -n "$th" ]] && \
        curl -s "https://api.telegram.org/bot${team_token}/deleteForumTopic" \
          -d chat_id="$tc" -d message_thread_id="$th" >/dev/null 2>&1 || true
    fi
    ok "intercom topic removed for group $group" '{group:$g, intercom:null}' --arg g "$group"
    return
  fi

  # Idempotent: reuse an existing intercom topic already bound to THIS group.
  local existing_chat existing_thread
  existing_chat=$(jq -r '.intercomTopic.chatId // empty' <<<"$reg")
  existing_thread=$(jq -r '.intercomTopic.threadId // empty' <<<"$reg")
  if [[ -n "$existing_thread" && "$existing_chat" == "$group" ]]; then
    ok "intercom topic already set (thread $existing_thread)" \
       '{group:$g, intercom:{threadId:$th, chatId:($g|tonumber)}}' \
       --arg g "$group" --argjson th "$existing_thread"
    return
  fi

  # Find a topic-manager bot (an agent bot that is admin w/ can_manage_topics,
  # or the team-bot fallback) and create the topic. Token resolution stays
  # server-side; the dashboard only sees the resulting thread id.
  local agents_json="{}" name tok
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    tok=$(_team_bot_token "$name")
    [[ -n "$tok" ]] && agents_json=$(jq -c --arg n "$name" --arg t "$tok" '.[$n]=$t' <<<"$agents_json")
  done < <(_team_bot_agent_list)
  local team_token=""; [[ -r /etc/5dive/team-bot.token ]] && team_token=$(cat /etc/5dive/team-bot.token 2>/dev/null)

  local reg_updates_file; reg_updates_file=$(mktemp)
  local result
  result=$(GROUP="$group" AGENTS="$agents_json" TEAM_BOT_TOKEN="$team_token" REG_UPDATES_FILE="$reg_updates_file" python3 - <<'PY'
import json, os, urllib.parse, urllib.request, urllib.error

GROUP = os.environ['GROUP']
TEAM  = os.environ.get('TEAM_BOT_TOKEN') or ''
AGENTS = json.loads(os.environ['AGENTS'])

def tg(token, method, **p):
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(p).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}

def can_manage(tok):
    me = tg(tok, "getMe")
    if not me.get("ok"):
        return False
    m = tg(tok, "getChatMember", chat_id=GROUP, user_id=me["result"]["id"])
    return (m.get("ok") and m["result"].get("status") in ("administrator", "creator")
            and (m["result"].get("can_manage_topics") or m["result"].get("status") == "creator"))

manager = None
for name, tok in AGENTS.items():
    if can_manage(tok):
        manager = tok; break
if manager is None and TEAM and can_manage(TEAM):
    manager = TEAM
if not manager:
    print(json.dumps({"ok": False, "error": "no admin bot can manage topics in this group"})); raise SystemExit(0)

cf = tg(manager, "createForumTopic", chat_id=GROUP, name="intercom")
if not cf.get("ok"):
    print(json.dumps({"ok": False, "error": cf.get("description", "createForumTopic failed")})); raise SystemExit(0)
thread = cf["result"]["message_thread_id"]
with open(os.environ.get("REG_UPDATES_FILE", "/dev/null"), "w") as f:
    json.dump({"threadId": int(thread), "chatId": int(GROUP)}, f)
print(json.dumps({"ok": True, "threadId": int(thread)}))
PY
)
  local rc=$?
  if [[ $rc -ne 0 || -z "$result" ]]; then rm -f "$reg_updates_file"; fail "$E_GENERIC" "team-bot intercom failed"; fi
  if [[ "$(jq -r '.ok // false' <<<"$result")" != "true" ]]; then
    local err; err=$(jq -r '.error // "intercom failed"' <<<"$result"); rm -f "$reg_updates_file"
    fail "$E_GENERIC" "$err"
  fi
  with_registry_lock _team_bot_persist_intercom "$reg_updates_file"
  rm -f "$reg_updates_file"
  local thread; thread=$(jq -r '.threadId' <<<"$result")
  ok "intercom topic created (thread $thread) in group $group" \
     '{group:$g, intercom:{threadId:$th, chatId:($g|tonumber)}}' \
     --arg g "$group" --argjson th "$thread"
}

_team_bot_persist_intercom() {
  local updates_file="$1" reg upd
  reg=$(registry_read)
  upd=$(cat "$updates_file")
  reg=$(jq --argjson u "$upd" '.intercomTopic = $u' <<<"$reg")
  registry_write <<<"$reg"
}
_team_bot_clear_intercom() {
  local reg; reg=$(registry_read)
  reg=$(jq 'del(.intercomTopic)' <<<"$reg")
  registry_write <<<"$reg"
}

# Resolve a bun binary usable by a root-run systemd unit. The listener has no
# deps (raw fetch) so any bun works; prefer the system one, fall back to the
# claude user's nvm/bun install.
_team_bot_resolve_bun() {
  local c
  for c in /usr/local/bin/bun /home/claude/.bun/bin/bun; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  c=$(sudo -u claude -i bash -lc 'command -v bun' 2>/dev/null | tail -1)
  [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  printf '/usr/local/bin/bun'
}

# Install (idempotently) the single getUpdates consumer of the shared team bot.
# The listener source is embedded so the CLI is self-contained on any box.
_team_bot_install_listener() {
  mkdir -p /opt/5dive
  cat > /opt/5dive/team-bot-listener.ts <<'LISTENER_TS'
#!/usr/bin/env bun
/**
 * 5dive team-bot listener (DIVE-159).
 *
 * The SINGLE getUpdates consumer of the shared team-bot token. Telegram allows
 * exactly one getUpdates consumer per token — a second poller = 409 = dead
 * channel for the whole fleet — so this runs as ONE systemd unit (Restart=on-
 * failure, single instance) which structurally enforces the singleton.
 *
 * Flow: long-poll getUpdates -> for each message in a forum topic, map
 * message_thread_id -> agent via the registry's teamTopic.threadId -> atomically
 * drop a JSON inbound file into that agent's relay-in/. The agent's telegram
 * plugin (TELEGRAM_SEND_ONLY=1) watches relay-in/, emits the normal channel
 * notification, and replies into the topic via the shared token.
 *
 * No external deps (raw fetch) to keep this a tiny, self-contained unit.
 */
import { readFileSync, writeFileSync, mkdirSync, renameSync, chownSync } from 'fs'
import { join } from 'path'
import { execFileSync } from 'child_process'

const TOKEN_FILE = process.env.TEAM_BOT_TOKEN_FILE ?? '/etc/5dive/team-bot.token'
const REGISTRY = process.env.FIVE_REGISTRY ?? '/var/lib/5dive/agents.json'
const OFFSET_FILE = process.env.TEAM_BOT_OFFSET_FILE ?? '/var/lib/5dive/team-bot.offset'
const HOME_ROOT = process.env.AGENT_HOME_ROOT ?? '/home'
const POLL_TIMEOUT = 30 // getUpdates long-poll seconds
// Loop/abuse guard: cap inbound drops per agent within a sliding window.
const RATE_MAX = 30
const RATE_WINDOW_MS = 10_000
// DIVE-453: when this listener owns the CoS (manager) bot token it is ALSO the
// sole consumer of managed_bot updates — so `cos claim` can no longer getUpdates
// on the same token (a second poller = 409). We spool each minted-child event to
// a file keyed by username; cos-claim reads + consumes it instead of polling.
const CLAIM_SPOOL_DIR = process.env.COS_CLAIM_SPOOL_DIR ?? '/var/lib/5dive/cos-claims'

const token = readFileSync(TOKEN_FILE, 'utf8').trim()
if (!token) {
  process.stderr.write('team-bot-listener: empty token at ' + TOKEN_FILE + '\n')
  process.exit(1)
}
const API = `https://api.telegram.org/bot${token}`

// Persisted update offset — a restart must never re-deliver. offset = last+1.
function loadOffset(): number {
  try {
    return parseInt(readFileSync(OFFSET_FILE, 'utf8').trim(), 10) || 0
  } catch {
    return 0
  }
}
function saveOffset(o: number): void {
  const tmp = `${OFFSET_FILE}.tmp`
  writeFileSync(tmp, String(o))
  renameSync(tmp, OFFSET_FILE) // atomic
}

// thread_id -> agent name, rebuilt each poll from the registry (tiny file, cheap).
function threadMap(): Map<number, string> {
  const m = new Map<number, string>()
  try {
    const reg = JSON.parse(readFileSync(REGISTRY, 'utf8'))
    for (const [name, a] of Object.entries<any>(reg.agents ?? {})) {
      const t = a?.teamTopic?.threadId
      if (typeof t === 'number') m.set(t, name)
    }
  } catch (e) {
    process.stderr.write(`team-bot-listener: registry read failed: ${e}\n`)
  }
  return m
}

// Cache agent-<name> uid/gid so dropped files are owned by the agent (which runs
// the plugin as agent-<name> and must read + delete them). Listener runs as root.
const idCache = new Map<string, { uid: number; gid: number } | null>()
function agentIds(agent: string): { uid: number; gid: number } | null {
  if (idCache.has(agent)) return idCache.get(agent)!
  let ids: { uid: number; gid: number } | null = null
  try {
    const user = `agent-${agent}`
    const uid = parseInt(execFileSync('id', ['-u', user]).toString().trim(), 10)
    const gid = parseInt(execFileSync('id', ['-g', user]).toString().trim(), 10)
    if (uid > 0 && gid > 0) ids = { uid, gid }
  } catch {}
  idCache.set(agent, ids)
  return ids
}

function relayInDir(agent: string): string {
  return join(HOME_ROOT, `agent-${agent}`, '.claude', 'channels', 'telegram', 'relay-in')
}

// Sliding-window rate limit per agent.
const hits = new Map<string, number[]>()
function rateOk(agent: string, now: number): boolean {
  const arr = (hits.get(agent) ?? []).filter(t => now - t < RATE_WINDOW_MS)
  if (arr.length >= RATE_MAX) {
    hits.set(agent, arr)
    return false
  }
  arr.push(now)
  hits.set(agent, arr)
  return true
}

let dropSeq = 0
function drop(agent: string, payload: Record<string, unknown>, now: number): void {
  const dir = relayInDir(agent)
  const ids = agentIds(agent)
  try {
    mkdirSync(dir, { recursive: true })
    if (ids) chownSync(dir, ids.uid, ids.gid)
  } catch {}
  const id = `${now}-${process.pid}-${dropSeq++}`
  const tmp = join(dir, `.${id}.tmp`)
  const fin = join(dir, `${id}.json`)
  // temp -> rename so the plugin watcher (reads only *.json) never sees a partial.
  writeFileSync(tmp, JSON.stringify({ id, ...payload }))
  try {
    if (ids) chownSync(tmp, ids.uid, ids.gid)
  } catch {}
  renameSync(tmp, fin)
}

// Spool a minted-child managed_bot event for `cos claim` to consume. Atomic
// temp -> rename, keyed by username so claim can match its target. Runs as root;
// claim reads as root (create path) or via the dashboard's sudo, then deletes.
function spoolClaim(child: { botId: number; username: string; ownerId: number }): void {
  try {
    mkdirSync(CLAIM_SPOOL_DIR, { recursive: true })
    const fin = join(CLAIM_SPOOL_DIR, `${child.username}.json`)
    const tmp = join(CLAIM_SPOOL_DIR, `.${child.username}.${process.pid}.tmp`)
    writeFileSync(tmp, JSON.stringify({ ...child, ts: Date.now() }))
    renameSync(tmp, fin)
  } catch (e) {
    process.stderr.write(`team-bot-listener: spoolClaim failed: ${e}\n`)
  }
}

async function tg(method: string, params: Record<string, unknown>): Promise<any> {
  const res = await fetch(`${API}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(params),
  })
  return res.json()
}

// DIVE-1093: tap-to-answer for a human gate, in shared team-bot mode. The `tna:`
// inline button lands as `tna:<taskId>:<token>[:<nonce>]` (see plugins/telegram/
// tna.ts — the source-of-truth the per-agent bridges use). Because every bridge
// is TELEGRAM_SEND_ONLY (no poller), THIS root listener is the only consumer of
// the tap, so it must answer the gate itself — otherwise approval/secret/manual
// gates are unanswerable from Telegram (GH 5dive#13 part 3).
const TNA_RE = /^tna:(\d+):([^:]+)(?::([0-9a-f]{32}))?$/

// Inlined twin of resolveTnaAnswer() from plugins/telegram/tna.ts — the small,
// stable gate-type decision matrix (keep in sync with that source-of-truth). The
// answer VALUE is always resolved from the LIVE gate, never the tapped payload.
function resolveTnaAnswer(task: any, token: string): any {
  if (!task || !task.need_type) return { kind: 'nogate' }
  if (task.need_answered_at) {
    const prior = task.need_type === 'secret' ? '(provided)' : (task.need_answer ?? '—')
    return { kind: 'already', prior }
  }
  if (task.need_type === 'decision') {
    const opts = String(task.need_options ?? '').split('|').map((s: string) => s.trim()).filter(Boolean)
    const value = opts[Number(token)]
    if (value !== undefined) return { kind: 'answer', answerArgs: [`--value=${value}`], ack: value }
  } else if (task.need_type === 'approval') {
    if (token === 'approved' || token === 'denied') return { kind: 'answer', answerArgs: [`--value=${token}`], ack: token }
  } else if (task.need_type === 'secret') {
    if (token === 'provided') return { kind: 'answer', answerArgs: [], ack: 'provided' }
  } else if (task.need_type === 'manual') {
    if (token === 'done') return { kind: 'answer', answerArgs: ['--value=done'], ack: 'done' }
  }
  return { kind: 'invalid' }
}

// Run the 5dive CLI. Via `sudo -n` so SUDO_UID is root (a non-agent uid) — that
// alone satisfies the hard-gate human-evidence check (DIVE-916/950 form c); we
// ALSO forward the per-gate --human-proof nonce (form a) when the tap carried
// one. Returns the parsed --json object, or {ok:false} on any failure.
function five(args: string[]): any {
  try {
    const out = execFileSync('sudo', ['-n', '5dive', '--json', ...args], { timeout: 8000 }).toString()
    return JSON.parse(out)
  } catch {
    return { ok: false }
  }
}

async function ackCallback(id: string, text: string): Promise<void> {
  try {
    await tg('answerCallbackQuery', { callback_query_id: id, text })
  } catch {}
}

// Fully fail-soft, mirroring the bridge's `tna:` handler: any stale/deleted task
// or CLI error just acks the tap (clears Telegram's spinner) and never throws.
async function handleCallback(cq: any): Promise<void> {
  const cbId = String(cq.id)
  const m = TNA_RE.exec(String(cq.data ?? ''))
  if (!m) {
    await ackCallback(cbId, '')
    return
  }
  const taskId = m[1]!
  const token = m[2]!
  const humanProof = m[3]
  // Re-read the LIVE gate: a dashboard/CLI answer or a double-tap between ping
  // and tap must not double-answer.
  const task = five(['task', 'show', taskId])?.data?.task
  const r = resolveTnaAnswer(task, token)
  if (r.kind === 'nogate') {
    await ackCallback(cbId, 'This task no longer has a gate.')
    return
  }
  if (r.kind === 'already') {
    await ackCallback(cbId, `Already answered: ${r.prior}`)
    return
  }
  if (r.kind === 'invalid') {
    await ackCallback(cbId, 'That option is no longer valid.')
    return
  }
  const extra: string[] = []
  if (task?.need_type === 'approval' || task?.need_type === 'secret' || task?.need_type === 'manual') {
    extra.push('--human')
    if (humanProof) extra.push(`--human-proof=${humanProof}`)
  }
  const ans = five(['task', 'answer', taskId, ...r.answerArgs, ...extra])
  if (ans?.ok) {
    await ackCallback(cbId, `Answered: ${r.ack}`)
  } else {
    await ackCallback(cbId, "Couldn't apply — answer from the dashboard or on-box.")
    process.stderr.write(`team-bot-listener: tna answer failed for task ${taskId} (${token})\n`)
  }
}

let offset = loadOffset()
process.stderr.write(`team-bot-listener: starting (offset=${offset})\n`)

let shuttingDown = false
for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => {
    shuttingDown = true
    process.stderr.write('team-bot-listener: shutting down\n')
    process.exit(0)
  })
}

while (!shuttingDown) {
  let data: any
  try {
    data = await tg('getUpdates', {
      offset,
      timeout: POLL_TIMEOUT,
      // DIVE-1093: subscribe to callback_query too. As the SOLE getUpdates
      // consumer of the shared token, if we don't fetch tap callbacks nobody
      // does (per-agent bridges are TELEGRAM_SEND_ONLY = no poller) — so the
      // `tna:` approval-button taps were silently dropped and human gates were
      // unanswerable from Telegram in team-bot mode (GH 5dive#13 part 3).
      allowed_updates: ['message', 'managed_bot', 'callback_query'],
    })
  } catch (e) {
    process.stderr.write(`team-bot-listener: getUpdates failed: ${e}\n`)
    await new Promise(r => setTimeout(r, 3000))
    continue
  }
  if (!data?.ok) {
    process.stderr.write(`team-bot-listener: getUpdates not ok: ${JSON.stringify(data)}\n`)
    await new Promise(r => setTimeout(r, 3000))
    continue
  }

  const updates: any[] = data.result ?? []
  if (updates.length === 0) continue

  const map = threadMap()
  const now = Date.now()
  for (const u of updates) {
    offset = Math.max(offset, u.update_id + 1)
    // managed_bot: a child the CoS minted via deep link. Spool it for `cos claim`.
    const mb = u.managed_bot ?? u.message?.managed_bot_created
    if (mb?.bot?.id) {
      spoolClaim({
        botId: mb.bot.id,
        username: mb.bot.username,
        ownerId: (mb.user ?? u.message?.from)?.id ?? 0,
      })
      continue
    }
    // DIVE-1093: a tapped inline button (human-gate answer). We're the sole
    // poller, so no per-agent bridge will pick it up. Skip taps from bots.
    if (u.callback_query) {
      if (!u.callback_query.from?.is_bot) await handleCallback(u.callback_query)
      continue
    }
    const msg = u.message
    if (!msg) continue
    if (msg.from?.is_bot) continue
    const threadId = msg.message_thread_id
    if (threadId == null) continue
    const agent = map.get(threadId)
    if (!agent) continue
    if (!rateOk(agent, now)) {
      process.stderr.write(`team-bot-listener: rate-limited ${agent} (thread ${threadId})\n`)
      continue
    }
    const text = msg.text ?? msg.caption ?? ''
    drop(
      agent,
      {
        chat_id: String(msg.chat.id),
        message_thread_id: String(threadId),
        message_id: String(msg.message_id),
        content: text,
        user: msg.from?.username ?? String(msg.from?.id ?? 'team'),
        user_id: String(msg.from?.id ?? ''),
        ts: new Date((msg.date ?? 0) * 1000).toISOString(),
      },
      now,
    )
  }
  saveOffset(offset)
}
LISTENER_TS
  chown root:root /opt/5dive/team-bot-listener.ts
  chmod 644 /opt/5dive/team-bot-listener.ts

  local bun_bin; bun_bin=$(_team_bot_resolve_bun)
  cat > /etc/systemd/system/5dive-team-bot-listener.service <<UNIT
[Unit]
Description=5dive team-bot listener (DIVE-159 — single getUpdates consumer of the shared team bot)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
Group=root
ExecStart=${bun_bin} /opt/5dive/team-bot-listener.ts
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >&2 2>/dev/null || true
  systemctl enable 5dive-team-bot-listener.service >&2 2>/dev/null || true
  # Restart picks up the (possibly updated) token + source. Singleton by unit.
  systemctl restart 5dive-team-bot-listener.service >&2 2>/dev/null || true
}

# `5dive agent team-bot shared --group --token --agents [--owner]`
# Relay the listed no-bot agents through one shared bot. Idempotent: re-running
# reuses each agent's existing topic.
# DIVE-247 — find the team group without the manual id hunt. Telegram's UI
# never shows a group's chat id, and the Bot API can't create groups or add
# bots to them — a human does that once. But the moment a human adds the bot,
# its pending updates (my_chat_member / messages) carry the chat id. Read them
# WITHOUT acking an offset so nothing is consumed (the listener still sees
# them later). getUpdates 409s only against another poller on the SAME token,
# so skip the poll when our listener is live on this token and fall back to
# groups already recorded in the registry (teamTopic/intercom chat ids).
# Enriches each candidate with getChat + getChatMember so the dashboard can
# show exactly what's missing (forum off / not admin / no Manage Topics).
_team_bot_do_discover() {
  local token="$1"
  [[ -n "$token" ]] || fail "$E_USAGE" "team-bot discover requires --token=<shared bot token>"
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail "$E_VALIDATION" "--token does not look like a Telegram bot token"

  local saved_token="" listener_live=0
  [[ -r /etc/5dive/team-bot.token ]] && saved_token=$(cat /etc/5dive/team-bot.token 2>/dev/null)
  if [[ -n "$saved_token" && "$saved_token" == "$token" ]] \
     && systemctl is-active --quiet 5dive-team-bot-listener.service 2>/dev/null; then
    listener_live=1
  fi

  local reg known
  reg=$(registry_read)
  known=$(jq -c '[(.agents | to_entries[] | .value.teamTopic.chatId // empty), (.intercomTopic.chatId // empty)] | unique' <<<"$reg")

  local result
  result=$(TOKEN="$token" LISTENER_LIVE="$listener_live" KNOWN="$known" python3 - <<'PY'
import json, os, urllib.parse, urllib.request, urllib.error

TOKEN = os.environ['TOKEN']
LIVE  = os.environ.get('LISTENER_LIVE') == '1'
KNOWN = json.loads(os.environ.get('KNOWN') or '[]')

def tg(method, **p):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    data = urllib.parse.urlencode(p).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}

me = tg("getMe")
if not me.get("ok"):
    print(json.dumps({"ok": False, "error": me.get("description", "bot token invalid")}))
    raise SystemExit(0)
bot_id = me["result"]["id"]
bot_username = me["result"].get("username")

chat_ids = []
def add(cid):
    if cid not in chat_ids:
        chat_ids.append(cid)

if not LIVE:
    # No offset param = peek, not consume: Telegram only discards updates once
    # a HIGHER offset is acked, so the listener still gets everything.
    up = tg("getUpdates", timeout=0,
            allowed_updates='["my_chat_member","message","chat_member"]')
    if up.get("ok"):
        for u in up.get("result", []):
            for k in ("my_chat_member", "message", "chat_member"):
                c = (u.get(k) or {}).get("chat") or {}
                if c.get("type") in ("group", "supergroup"):
                    add(int(c["id"]))
for cid in KNOWN:
    add(int(cid))

groups = []
for cid in chat_ids:
    g = tg("getChat", chat_id=cid)
    if not g.get("ok"):
        continue  # kicked since, or the id migrated — not usable, skip
    info = g["result"]
    mm = tg("getChatMember", chat_id=cid, user_id=bot_id)
    st = (mm.get("result") or {}).get("status", "left") if mm.get("ok") else "left"
    if st in ("left", "kicked"):
        continue
    can_topics = bool((mm.get("result") or {}).get("can_manage_topics")) or st == "creator"
    is_admin = st in ("administrator", "creator")
    groups.append({
        "id": str(info["id"]),
        "title": info.get("title") or str(info["id"]),
        "isForum": bool(info.get("is_forum")),
        "isAdmin": is_admin,
        "canManageTopics": can_topics,
        "ready": bool(info.get("is_forum")) and is_admin and can_topics,
    })

print(json.dumps({"ok": True, "botUsername": bot_username, "groups": groups}))
PY
)
  [[ -n "$result" ]] || fail "$E_GENERIC" "team-bot discover failed"
  if [[ "$(jq -r '.ok // false' <<<"$result")" != "true" ]]; then
    fail "$E_GENERIC" "$(jq -r '.error // "discover failed"' <<<"$result")"
  fi
  local n bot_username groups
  n=$(jq '.groups | length' <<<"$result")
  bot_username=$(jq -r '.botUsername // ""' <<<"$result")
  groups=$(jq -c '.groups' <<<"$result")
  ok "team-bot discover: $n group(s) found" '{botUsername:$b, groups:$g}' \
     --arg b "$bot_username" --argjson g "$groups"
}

_team_bot_do_shared() {
  local group="$1" owner="$2" agents_filter="$3" token="$4"
  [[ -n "$token" ]] || fail "$E_USAGE" "team-bot shared requires --token=<shared bot token>"
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || fail "$E_VALIDATION" "--token does not look like a Telegram bot token"
  [[ -n "$agents_filter" ]] || fail "$E_USAGE" "team-bot shared requires --agents=<name[,name...]>"

  local reg; reg=$(registry_read)
  local candidates; candidates=$(_team_bot_relay_agent_list)

  # Resolve requested names against relay candidates — never touch a personal-bot
  # agent or an unknown/unsupported one.
  local targets_json="{}" name type sd tt
  local -a req
  IFS=',' read -ra req <<<"$agents_filter"
  for name in "${req[@]}"; do
    name="${name// /}"
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<<"$candidates" \
      || fail "$E_VALIDATION" "agent '$name' is not a no-bot relay candidate (already has its own bot, unknown, or its type has no telegram plugin)"
    type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    sd=$(_tg_access_state_dir "agent-${name}" "$type" 2>/dev/null || echo "")
    tt=$(jq -c --arg n "$name" '.agents[$n].teamTopic // null' <<<"$reg")
    targets_json=$(jq -c --arg n "$name" --arg ty "$type" --arg sd "$sd" --argjson tt "$tt" \
      '.[$n]={type:$ty, stateDir:$sd, teamTopic:$tt}' <<<"$targets_json")
  done
  [[ "$targets_json" != "{}" ]] || fail "$E_NOT_FOUND" "no relay-eligible agents in --agents"

  # 1) Persist the shared token (root-only) — the listener reads it from here.
  mkdir -p /etc/5dive
  ( umask 077; printf '%s\n' "$token" > /etc/5dive/team-bot.token )
  chown root:root /etc/5dive/team-bot.token
  chmod 600 /etc/5dive/team-bot.token
  # Also persist the team group (+owner) so `agent create` can auto-attach
  # future no-bot agents to this group without re-asking (DIVE-248).
  ( umask 077; jq -n --arg g "$group" --arg o "$owner" \
      '{group:$g, owner:(if $o=="" then null else $o end)}' > /etc/5dive/team-bot.json )
  chown root:root /etc/5dive/team-bot.json
  chmod 600 /etc/5dive/team-bot.json

  # 2) Telegram: verify the shared bot can manage topics, create a topic per
  #    agent (reusing an existing one), and wire each access.json.
  local reg_updates_file; reg_updates_file=$(mktemp)
  local results
  results=$(GROUP="$group" OWNER="$owner" TOKEN="$token" AGENTS="$targets_json" REG_UPDATES_FILE="$reg_updates_file" python3 - <<'PY'
import json, os, tempfile, pwd, urllib.parse, urllib.request, urllib.error

GROUP  = os.environ['GROUP']
OWNER  = os.environ.get('OWNER') or ''
TOKEN  = os.environ['TOKEN']
AGENTS = json.loads(os.environ['AGENTS'])

def tg(method, **params):
    url = f"https://api.telegram.org/bot{TOKEN}/{method}"
    data = urllib.parse.urlencode(params).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "description": str(e)}

def bail(status, **extra):
    out = [dict(agent=n, status=status, threadId=None, **extra) for n in AGENTS]
    with open(os.environ.get("REG_UPDATES_FILE", "/dev/null"), "w") as f:
        f.write("{}")
    print(json.dumps(out))
    raise SystemExit(0)

me = tg("getMe")
if not me.get("ok"):
    bail("error", error=me.get("description", "shared bot token invalid"))
bot_id = me["result"]["id"]

mm = tg("getChatMember", chat_id=GROUP, user_id=bot_id)
ok_admin = (mm.get("ok") and mm["result"].get("status") in ("administrator", "creator")
            and (mm["result"].get("can_manage_topics") or mm["result"].get("status") == "creator"))
if not ok_admin:
    bail("needs_shared_admin")

results = []
reg_updates = {}
for name, a in AGENTS.items():
    out = {"agent": name, "status": "error", "threadId": None}
    existing = a.get("teamTopic") or {}
    thread = existing.get("threadId") if existing.get("chatId") == int(GROUP) else None
    if not thread:
        cf = tg("createForumTopic", chat_id=GROUP, name=name)
        if not cf.get("ok"):
            out["error"] = cf.get("description", "createForumTopic failed")
            results.append(out); continue
        thread = cf["result"]["message_thread_id"]

    sd = a.get("stateDir") or ""
    if sd:
        path = os.path.join(sd, "access.json")
        try:
            acc = json.load(open(path)) if os.path.exists(path) else {}
        except Exception:
            acc = {}
        acc.setdefault("dmPolicy", "pairing")
        acc.setdefault("allowFrom", [])
        acc.setdefault("groups", {})
        acc.setdefault("pending", {})
        acc["groups"][GROUP] = {"requireMention": False,
                                "allowFrom": [OWNER] if OWNER else [],
                                "message_thread_id": int(thread)}
        os.makedirs(sd, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=sd)
        with os.fdopen(fd, "w") as f:
            json.dump(acc, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
        # The plugin runs as the agent and must OWN its telegram state dir +
        # create relay-in/ for the SEND_ONLY inbound watcher. os.makedirs above
        # created any missing parents as root (no-bot agents have no prior
        # telegram dir), so chown the tree + pre-make relay-in — otherwise the
        # watcher trips on a root-owned dir at mkdirSync and never registers.
        try:
            u = pwd.getpwnam("agent-" + name)
            relay_in = os.path.join(sd, "relay-in")
            os.makedirs(relay_in, exist_ok=True)
            for d in (os.path.dirname(sd), sd, relay_in):
                try:
                    os.chown(d, u.pw_uid, u.pw_gid)
                except OSError:
                    pass
            os.chmod(relay_in, 0o700)
            os.chown(path, u.pw_uid, u.pw_gid)
        except KeyError:
            pass

    reg_updates[name] = {"threadId": int(thread), "chatId": int(GROUP)}
    out["status"] = "relayed"; out["threadId"] = int(thread)
    results.append(out)

with open(os.environ.get("REG_UPDATES_FILE", "/dev/null"), "w") as f:
    json.dump(reg_updates, f)
print(json.dumps(results))
PY
)
  local rc=$?
  if [[ $rc -ne 0 || -z "$results" ]]; then rm -f "$reg_updates_file"; fail "$E_GENERIC" "team-bot shared failed"; fi

  # 3) For each agent that got a topic: enable the telegram plugin (send-only)
  #    + regenerate its systemd env with channels=telegram.
  local -a wired
  while IFS= read -r name; do [[ -n "$name" ]] && wired+=("$name"); done \
    < <(jq -r '.[] | select(.status=="relayed") | .agent' <<<"$results")

  local ef wd pf iso cur_ch new_ch
  for name in "${wired[@]}"; do
    type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    step "Enabling telegram (send-only) for $name"
    install_channel_for_agent "$type" telegram "$name" "$token" "" "" || true
    _team_bot_write_sendonly_env "$name" "$token"
    ef="${ENV_DIR}/${name}.env"
    wd=$(sed -n 's/^AGENT_WORKDIR=//p' "$ef" 2>/dev/null | head -1)
    pf=$(sed -n 's/^AGENT_AUTH_PROFILE=//p' "$ef" 2>/dev/null | head -1)
    iso=$(sed -n 's/^AGENT_ISOLATION=//p' "$ef" 2>/dev/null | head -1); iso="${iso:-admin}"
    # Keep a DIVE-856 default dashboard channel alongside the relay —
    # mirrors _team_bot_persist_shared's registry merge.
    cur_ch=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
    new_ch="telegram"
    channel_in_list dashboard "$cur_ch" && new_ch="telegram,dashboard"
    write_agent_env "$name" "$type" "$new_ch" "$wd" "$pf" "$iso"
  done

  # 4) Persist channels=telegram + teamTopic (under the registry lock).
  if [[ -s "$reg_updates_file" ]]; then
    with_registry_lock _team_bot_persist_shared "$reg_updates_file"
  fi
  rm -f "$reg_updates_file"

  # 5) Install + (re)start the single listener.
  if [[ ${#wired[@]} -gt 0 ]]; then
    _team_bot_install_listener
  fi

  # 6) Restart each wired agent so it loads the send-only plugin.
  for name in "${wired[@]}"; do
    step "Restarting 5dive-agent@${name}"
    systemctl restart "5dive-agent@${name}.service" >&2 2>/dev/null || true
  done

  local ready total
  ready=$(jq '[.[] | select(.status=="relayed")] | length' <<<"$results")
  total=$(jq 'length' <<<"$results")
  ok "team-bot shared: $ready/$total agents relayed in group $group" \
     '{group:$g, relay:$a}' --arg g "$group" --argjson a "$results"
}

