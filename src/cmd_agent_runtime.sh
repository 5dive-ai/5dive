# Shared: resolve a registry entry or die. Echo nothing on success; used for
# presence checks in the lifecycle commands below.
require_agent() {
  local name="$1"
  ensure_state_ro   # presence check is read-only; must work for non-root agents
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
}

# Resolve an agent's type from the registry. Used by the skill subcommands so
# the per-type SKILLS_AGENT_ID / SKILLS_INSTALL_DIR maps drive --agent and
# the post-install verification path. Caller should `require_agent` first;
# returns empty string if the agent isn't registered.
agent_type() {
  local name="$1"
  registry_read | jq -r --arg n "$name" '.agents[$n].type // empty'
}

cmd_start() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent start <name>"
  require_agent "$name"
  systemctl start "5dive-agent@${name}.service" >&2
  # DIVE-857 prereq (b): record the operator's intent so the supervisor can
  # tell a crashed unit from a deliberate stop without inference.
  local reg; reg=$(registry_read)
  reg=$(jq --arg n "$name" '.agents[$n].desiredState = "running"' <<<"$reg") \
    && echo "$reg" | registry_write
  ok "agent '$name' started." \
     '{name:$n, action:"start"}' --arg n "$name"
}

cmd_stop() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent stop <name>"
  require_agent "$name"
  systemctl stop "5dive-agent@${name}.service" >&2
  local reg; reg=$(registry_read)
  reg=$(jq --arg n "$name" '.agents[$n].desiredState = "stopped"' <<<"$reg") \
    && echo "$reg" | registry_write
  ok "agent '$name' stopped." \
     '{name:$n, action:"stop"}' --arg n "$name"
}

# journalctl for the agent's unit, or a tmux scrollback capture with --tmux.
# --follow streams until the caller hangs up; in the /agents/exec path the
# shelld timeout caps this, so the dashboard should prefer the WS session for
# true follow.
#
# JSON output:
#   --tmux     -> {ok:true, data:{name, source:"tmux",    lines:[...]}}
#   default    -> {ok:true, data:{name, source:"journal", lines:[...]}}
#   --follow   -> NDJSON, one {line:"..."} per event on stdout. (Not wrapped
#                 in an envelope because it is an unbounded stream; consumers
#                 watch exit code for the envelope-less failure signal.)
cmd_logs() {
  local name="" follow=0 lines=200 tmux_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --follow|-f) follow=1 ;;
      --lines=*)   lines="${1#--lines=}" ;;
      --tmux)      tmux_mode=1 ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent logs <name> [--follow] [--lines=N] [--tmux]"
  [[ "$lines" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "invalid --lines (must be a positive integer)"
  require_agent "$name"

  if (( tmux_mode )); then
    local capture
    capture=$(sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -S "-${lines}" 2>/dev/null) \
      || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"
    if (( JSON_MODE )); then
      jq -Rn --arg n "$name" \
        '{ok:true, data:{name:$n, source:"tmux", lines:[inputs]}}' <<<"$capture"
    else
      printf '%s\n' "$capture"
    fi
    return 0
  fi

  local args=(-u "5dive-agent@${name}.service" --no-pager -n "$lines")
  (( follow )) && args+=(-f)

  if (( JSON_MODE )); then
    if (( follow )); then
      # NDJSON stream; no envelope. Each line becomes one JSON object.
      journalctl "${args[@]}" | jq -Rc '{line: .}'
    else
      journalctl "${args[@]}" \
        | jq -Rn --arg n "$name" '{ok:true, data:{name:$n, source:"journal", lines:[inputs]}}'
    fi
  else
    journalctl "${args[@]}"
  fi
}

# Sender-side group mirror for inter-agent traffic. Posts "@<receiver>\n<body>"
# into the SENDER's Telegram group via the SENDER's own bot, so the operator
# sees agent-to-agent messages under the correct sender identity — canonical
# group "call" style (each bot addresses the @recipient).
#
# This lives in the CLI rather than a hook on purpose: here we have the fully
# expanded message body. The old sender-side PreToolUse Bash mirror only saw
# the pre-expansion command string and choked on heredoc bodies
# (`"$(cat <<EOF…EOF)"`), which is why it was moved receiver-side. Doing it in
# the command itself sidesteps that entirely.
#
# Best-effort and self-gating: returns 0 (never blocks/fails the send) when not
# invoked by an agent, when the sender has no bot token, or when no group is
# configured. The receiver's reply rides the same path — when the receiver
# answers via `5dive agent send <original-sender>`, that call posts the reply
# payload under the receiver's bot, completing the two-sided "call" view.
mirror_interagent_outbound() {
  local receiver="$1" body="$2"

  # Only a real agent (SUDO_USER=agent-<x>) has a bot identity to post under.
  local invoker="${SUDO_USER:-}"
  [[ -n "$invoker" && "$invoker" == agent-* ]] || return 0
  local invoker_name="${invoker#agent-}"

  local token_file="${CONNECTORS_DIR}/telegram-${invoker_name}.env"
  [[ -r "$token_file" ]] || return 0
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_file" | head -1)
  [[ -n "$token" ]] || return 0

  # access.json lives under ~/.<type>/channels/telegram/ — resolve the
  # invoker's type so codex/grok agents mirror too, not just claude. Bail
  # quietly for token-only types (openclaw/hermes) with no access.json.
  local reg
  reg=$(registry_read)
  local invoker_type
  invoker_type=$(jq -r --arg n "$invoker_name" '.agents[$n].type // empty' <<<"$reg" 2>/dev/null)
  local access_dir
  access_dir=$(_tg_access_state_dir "$invoker" "$invoker_type") || return 0
  local access_file="${access_dir}/access.json"
  [[ -r "$access_file" ]] || return 0
  local group_chat_id
  group_chat_id=$(jq -r '(.groups // {}) | keys | .[0] // empty' "$access_file" 2>/dev/null)
  [[ -n "$group_chat_id" ]] || return 0

  # Optional forum-topic routing: if the group entry carries a
  # message_thread_id, post into that topic (e.g. a dedicated "#5dive" thread)
  # instead of the supergroup's General channel.
  local thread_id
  thread_id=$(jq -r --arg g "$group_chat_id" '.groups[$g].message_thread_id // empty' "$access_file" 2>/dev/null)

  # DIVE-195 intercom: if a fleet intercom topic is set and this agent belongs to
  # that group, consolidate inter-agent chatter into the intercom topic —
  # overriding the first-sorted group picked above (an agent can be in several
  # groups, including stale ones, so don't rely on keys[0] matching). Single
  # source of truth = registry .intercomTopic {threadId, chatId}.
  local intercom_chat intercom_thread
  intercom_chat=$(jq -r '.intercomTopic.chatId // empty' <<<"$reg" 2>/dev/null)
  intercom_thread=$(jq -r '.intercomTopic.threadId // empty' <<<"$reg" 2>/dev/null)
  if [[ -n "$intercom_thread" ]] && \
     jq -e --arg g "$intercom_chat" '(.groups // {}) | has($g)' "$access_file" >/dev/null 2>&1; then
    group_chat_id="$intercom_chat"
    thread_id="$intercom_thread"
  fi

  local trimmed
  trimmed=$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n "$trimmed" ]] || return 0

  # Resolve the receiver's @botUsername for a tappable mention; fall back to
  # the bare agent name if the registry has no cached username.
  local bot to_label
  bot=$(jq -r --arg n "$receiver" '.agents[$n].botUsername // empty' <<<"$reg" 2>/dev/null)
  if [[ -n "$bot" ]]; then to_label="@${bot}"; else to_label="@${receiver}"; fi

  # DIVE-195: shared-bot (send-only) agents all post under ONE bot identity, so
  # the intercom can't tell who sent it. Prepend the sender's name for those.
  # Personal-bot agents post under their own bot (name + avatar), so leave clean.
  if grep -q '^TELEGRAM_SEND_ONLY=1' "$token_file" 2>/dev/null; then
    to_label="${invoker_name} to ${to_label}"
  fi

  local max_chars="${MIRROR_MAX_BODY_CHARS:-800}"
  local body_disp overflow=""
  if (( ${#trimmed} > max_chars )); then
    body_disp="${trimmed:0:$((max_chars - 1))}…"
    overflow=" (+$(( ${#trimmed} - max_chars )) chars)"
  else
    body_disp="$trimmed"
  fi

  local mirror_text
  mirror_text=$(printf '%s\n%s%s' "$to_label" "$body_disp" "$overflow")
  _mirror_post "$token" "$group_chat_id" "$thread_id" "$mirror_text" "$access_file"
}

# Result globals consumed by load-bearing callers such as task gate delivery.
# _mirror_post remains best-effort/return-0 for its many historical callers, but
# these fields make the Bot API acknowledgement observable instead of treating a
# curl exit (or an empty response) as delivery. DIVE-1490.
MIRROR_POST_DELIVERED=0
MIRROR_POST_MESSAGE_ID=""
MIRROR_POST_CHAT=""
MIRROR_POST_ERROR=""

# POST a mirror message, threading into message_thread_id when set. Auto-follows
# a group→supergroup migration: once a group is upgraded (which is also how it
# gains forum topics), Telegram rejects sends to the old basic-group id with
# parameters.migrate_to_chat_id. On that error we rewrite the stored group id
# and retry once against the new supergroup id, so the mirror self-heals instead
# of silently dying. Best-effort throughout — a mirror post is never load-bearing.
_mirror_post() {
  local token="$1" chat="$2" thread="$3" text="$4" access_file="$5" reply_markup="${6:-}"
  MIRROR_POST_DELIVERED=0
  MIRROR_POST_MESSAGE_ID=""
  MIRROR_POST_CHAT="$chat"
  MIRROR_POST_ERROR=""

  local resp ok mid
  # A transport failure is an ordinary negative delivery receipt, not a reason
  # to trip the caller's `set -e`. Preserve any response body curl produced,
  # then let the structured receipt/fallback path below handle the miss.
  resp=$(_mirror_send "$token" "$chat" "$thread" "$text" "$reply_markup") || resp="${resp:-}"
  ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
  if [[ "$ok" == "true" ]]; then
    mid=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null) || mid=""
    if [[ -n "$mid" ]]; then
      MIRROR_POST_DELIVERED=1 MIRROR_POST_MESSAGE_ID="$mid"
      return 0
    fi
    ok=false
    MIRROR_POST_ERROR="Bot API returned ok:true without message_id"
  fi

  local new_chat
  new_chat=$(jq -r '.parameters.migrate_to_chat_id // empty' <<<"$resp" 2>/dev/null)
  if [[ -n "$new_chat" && "$new_chat" != "$chat" ]]; then
    _mirror_follow_migration "$access_file" "$chat" "$new_chat"
    chat="$new_chat" MIRROR_POST_CHAT="$new_chat"
    resp=$(_mirror_send "$token" "$chat" "$thread" "$text" "$reply_markup") || resp="${resp:-}"
    ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
    if [[ "$ok" == "true" ]]; then
      mid=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null) || mid=""
      if [[ -n "$mid" ]]; then
        MIRROR_POST_DELIVERED=1 MIRROR_POST_MESSAGE_ID="$mid"
        return 0
      fi
      ok=false
      MIRROR_POST_ERROR="Bot API returned ok:true without message_id"
    fi
  fi

  # DIVE-117: the send failed for a non-migration reason. A button-bearing send
  # can be rejected for the keyboard alone (a reply_markup Telegram dislikes)
  # while the plain text would deliver. The text alert is load-bearing
  # (DIVE-105), so retry once WITHOUT the keyboard — the ping must never be lost
  # to a button problem.
  # DIVE-1338: the retry above USED to swallow the error resp, so a human got a
  # no-button ping and we never learned WHY Telegram rejected the keyboard (this
  # is lodar's recurring DIVE-1320 no-button, systemic across every gate whose
  # keyboard-send is rejected). Before the fallback, capture the actual rejection
  # (error_code + description) so the reason is finally visible and STEP 2 can
  # root-cause it. Only log when a keyboard was in play — a plain-text failure is
  # a different (delivery) problem, not a button one.
  if [[ -n "$reply_markup" ]]; then
    _mirror_log_button_reject "$chat" "$thread" "$reply_markup" "$resp"
    resp=$(_mirror_send "$token" "$chat" "$thread" "$text" "") || resp="${resp:-}"
    ok=$(jq -r '.ok // false' <<<"$resp" 2>/dev/null) || ok=false
    if [[ "$ok" == "true" ]]; then
      mid=$(jq -r '.result.message_id // empty' <<<"$resp" 2>/dev/null) || mid=""
      if [[ -n "$mid" ]]; then
        MIRROR_POST_DELIVERED=1 MIRROR_POST_MESSAGE_ID="$mid"
        return 0
      fi
      ok=false
      MIRROR_POST_ERROR="Bot API returned ok:true without message_id"
    fi
  fi

  if [[ -n "$MIRROR_POST_ERROR" ]]; then
    :
  elif [[ -n "$resp" ]]; then
    MIRROR_POST_ERROR=$(jq -r '
      "error_code=" + ((.error_code // "?")|tostring) +
      " description=" + ((.description // "unknown Bot API rejection")|tostring)
    ' <<<"$resp" 2>/dev/null) || MIRROR_POST_ERROR="malformed Bot API response"
  else
    MIRROR_POST_ERROR="transport failure: empty Bot API response"
  fi
  return 0
}

# DIVE-1338: emit ONE diagnostic line when a button-bearing gate ping is rejected
# by Telegram, so the swallowed reply_markup rejection is finally observable. We
# record error_code + description (the two fields Telegram returns on a 400) plus
# the reply_markup byte-length (the prime suspect for the 64-byte callback_data /
# oversized-keyboard classes of rejection) and the chat/thread it targeted. Best-
# effort and totally silent on failure: this runs on the gate-notify path AFTER
# the DB UPDATE already committed, so it must never fail the caller.
# DIVE-1344/1345: writes to the group-writable /var/log/5dive/notify subdir
# (audit_init ensures it 2770). The gate mirror fires AS THE AGENT (group claude,
# NOT root), so the old parent-dir write (2750) ALWAYS failed and the line was
# lost to the stderr fallback — the file was never created. Falls back to stderr
# on a CLI-only / OSS box where the dir isn't provisioned.
_mirror_log_button_reject() {
  local chat="$1" thread="$2" reply_markup="$3" resp="$4"
  local ec desc
  ec=$(jq -r '.error_code // "?"' <<<"$resp" 2>/dev/null) || ec="?"
  desc=$(jq -r '.description // "?"' <<<"$resp" 2>/dev/null) || desc="?"
  local line
  line=$(printf 'gate-button-reject chat=%s thread=%s rm_bytes=%s error_code=%s description=%q' \
           "$chat" "${thread:-none}" "${#reply_markup}" "$ec" "$desc")
  local logf="/var/log/5dive/notify/gate-notify.log"
  # umask 0002 so a freshly created file is group-writable (664) and EVERY agent
  # (all group claude) can append, not just its creator; chmod g+w best-effort
  # upgrades a 644 file a prior root-context write may have left behind.
  if ( umask 0002; : >>"$logf" ) 2>/dev/null; then
    chmod g+w "$logf" 2>/dev/null || true
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')" "$line" >>"$logf" 2>/dev/null || true
  else
    printf '[5dive] %s\n' "$line" >&2 2>/dev/null || true
  fi
}

# Optional 5th arg reply_markup: a Telegram inline_keyboard JSON string. When
# present it's attached so the message carries tap buttons (DIVE-117). Empty =
# a plain text send (unchanged). Built as an arg array so thread + reply_markup
# compose without duplicating the curl call.
_mirror_send() {
  local token="$1" chat="$2" thread="$3" text="$4" reply_markup="${5:-}"
  local args=(--data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}")
  [[ -n "$thread" ]] && args+=(--data-urlencode "message_thread_id=${thread}")
  [[ -n "$reply_markup" ]] && args+=(--data-urlencode "reply_markup=${reply_markup}")
  # Bounded so a hung/slow Telegram API can't wedge the FOREGROUND callers
  # (task_need_notify runs this after the gate UPDATE has already committed;
  # mirror_interagent_outbound likewise). --connect-timeout caps the TCP/TLS
  # handshake, --max-time the whole request (DIVE-115).
  curl -s --connect-timeout 5 --max-time 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" "${args[@]}" 2>/dev/null
}

# Rename a migrated group's key (old→new) in access.json, preserving the policy
# value (incl. message_thread_id) and the file's owner/mode. Runs as root (the
# mirror only fires under sudo), so chowning back to the agent owner is required
# — otherwise the plugin, running as the agent user, could no longer write it.
_mirror_follow_migration() {
  local access_file="$1" old="$2" new="$3"
  local tmp="${access_file}.migrate.$$" owner
  owner=$(stat -c '%U:%G' "$access_file" 2>/dev/null)
  jq --arg o "$old" --arg n "$new" '
    if (.groups // {}) | has($o)
    then (.groups[$n] = .groups[$o]) | del(.groups[$o])
    else . end
  ' "$access_file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  [[ -n "$owner" ]] && chown "$owner" "$tmp" 2>/dev/null
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$access_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# Wait until the agent's TUI has rendered its input prompt and can actually
# receive keystrokes. A freshly (re)started agent takes ~15-30s to boot Claude
# + its plugins/MCP servers; a send-keys before the input box exists is
# silently dropped and the message is LOST (the recurring "my ping never
# arrived after a restart" bug). We poll the pane for the prompt marker "❯",
# which Claude renders once the input box is up (present whether idle OR
# mid-generation — Claude queues typed input — so we don't needlessly block on
# a busy agent). Best-effort + bounded: returns 0 as soon as it's ready, 1 on
# timeout (caller still sends — better to try than to hang forever, and TUIs
# that never draw the marker shouldn't wedge inter-agent sends).
#
# DIVE-348: "❯" is CLAUDE's marker. antigravity (agy) never renders it, so the
# old grep always timed out for agy → a needless 45s wait per send AND a false
# "input prompt not detected — best-effort (may be lost)" warning, even though
# the send actually landed (marketing hit this). antigravity's input box shows
# "? for shortcuts" (idle) or "esc to cancel" (mid-turn) in its footer — both
# appear ONLY once the box is rendered, so they're safe ready-signals. The
# markers are TUI-specific and don't collide (claude never shows the antigravity
# footer; antigravity never shows ❯), so OR-ing them needs no type plumbing and
# can't false-positive across types.
wait_agent_input_ready() {
  local name="$1" timeout="${2:-45}"
  local user="agent-${name}" waited=0 pane
  while (( waited < timeout )); do
    pane=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
    grep -qE '❯|\? for shortcuts|esc to cancel' <<<"$pane" && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

# Inject a payload into the agent's tmux pane and SUBMIT it, robust against the
# TUI's bracketed-paste handling (DIVE-147). A large/multiline `send-keys -l` is
# absorbed by the TUI as a bracketed PASTE — the prompt shows
# "❯ [Pasted text #N +M lines]" — and a single trailing Enter races into / is
# swallowed by the paste, so the turn never starts and the message is SILENTLY
# DROPPED (small single-paragraph nudges usually submit, which is why the bug is
# size/linecount-correlated and intermittent). Strategy: type the body, pause so
# the paste commits, send Enter, then CONFIRM the pane left the pasted-but-unsent
# state — retrying the Enter a few times before giving up. Best-effort + bounded:
# returns 0 once submission is confirmed (or there was no paste buffer to begin
# with — small msgs / non-Claude TUIs that don't show the placeholder), 1 if it
# still looks unsubmitted after retries. The "[Pasted text #" marker is Claude's
# input-buffer rendering; other runtimes just fall through the fast path.
#
# DIVE-1325: the Claude fast path above relied on the "[Pasted text #N]"
# placeholder to know an Enter still needs re-sending — but a codex/grok/agy/
# opencode TUI renders the paste INLINE with no such placeholder, so `grep`
# never matched and the loop returned success after a SINGLE Enter fired only
# 0.3s after the burst. On codex that Enter races the paste-commit and is
# swallowed (the input lands in the composer but never submits), so the send is
# silently dropped and the agent sits deaf — the root cause behind the known
# deaf-codex behaviour. For non-claude TUIs we now mirror _hb_send_line's
# DIVE-1217 fix: let the paste settle, Enter, then CONFIRM the composer left
# idle (turn actually started) via _hb_agent_idle, re-sending a few times before
# giving up. (Enter and C-m are byte-identical `\r` to tmux, so the earlier
# manual-C-m workaround was really the settle+confirm, not a different key.)
inject_and_submit() {
  local name="$1" payload="$2" tries=0 pane
  local user="agent-${name}"   # separate stmt: ${name} in the same line aborts under set -u (silent msg drop)
  sudo -u "$user" tmux send-keys -t "agent-${name}" -l -- "$payload"
  # Let the TUI finish ingesting the (possibly bracketed-paste) payload before the
  # Enter, so the newline isn't bundled into the paste sequence.
  sleep 0.3
  # Non-claude TUIs: no paste placeholder to poll — confirm via idle-state instead.
  if [[ -z "$(_hb_claude_pid "$name")" ]]; then
    sleep 0.4
    while (( tries < 5 )); do
      sudo -u "$user" tmux send-keys -t "agent-${name}" Enter
      sleep 0.5
      # idle()==0 means the Enter did NOT take (still parked at the composer) ->
      # retry; any other state (busy/blocked/unknown) means the turn started.
      _hb_agent_idle "$name" 0.4 || return 0
      tries=$((tries+1))
    done
    return 1
  fi
  while (( tries < 5 )); do
    sudo -u "$user" tmux send-keys -t "agent-${name}" Enter
    sleep 0.4
    pane=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
    # Submitted once the unsubmitted-paste placeholder clears from the prompt.
    # (We only re-send Enter while it's still showing, so a message that already
    # submitted never gets stray extra Enters.)
    grep -q '\[Pasted text #[0-9]' <<<"$pane" || return 0
    tries=$((tries+1))
  done
  return 1
}

# DIVE-1065: privileged inter-agent delivery primitive. Hidden subcommand
# (`5dive agent _deliver <target> <message>`) run as ROOT via a per-agent scoped
# sudoers grant (write_standard_sudoers) so a standard-isolation agent can talk
# to peers in real time WITHOUT broad root. `cmd_send` re-execs into it for a
# non-root agent caller.
#
# This is the ONE 5dive subcommand a standard agent may run as root, so it MUST
# uphold the write_admin_sudoers invariant: it NEVER execs caller-controlled
# input. It does exactly one thing — a LITERAL tmux inject (via inject_and_submit,
# i.e. `send-keys -l --`) of a provenance-wrapped message into a validated,
# registered target's pane. No eval / sh -c / printf-format ever touches the
# message, so the `*` wildcard the sudoers grant places on its arguments cannot
# become an agent->root vector: the worst a caller can do is inject text into a
# peer's pane, which is precisely the sanctioned capability. Sender + tier are
# derived from the REAL sudo caller (SUDO_USER), never a spoofable flag.
cmd_deliver() {
  require_root "agent _deliver"
  local msgid=""
  local -a _pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id=*) msgid="${1#--id=}" ;;
      --)     shift; _pos+=("$@"); break ;;
      *)      _pos+=("$1") ;;
    esac
    shift
  done
  local target="${_pos[0]:-}"
  local message=""
  (( ${#_pos[@]} > 1 )) && message="${_pos[*]:1}"
  [[ -n "$target" ]]  || fail "$E_USAGE" "usage: 5dive agent _deliver [--id=<id>] <target> <message>"
  [[ -n "$message" ]] || fail "$E_USAGE" "message is empty"
  # DIVE-1074: optional marker id (passed by `ask`) so the caller can later slice
  # its reply window via `_capture --after-id`. Validated literal ([A-Za-z0-9]),
  # same no-exec invariant as the message — it only lands in the injected header.
  if [[ -n "$msgid" ]]; then
    [[ "$msgid" =~ ^[A-Za-z0-9]{1,32}$ ]] \
      || fail "$E_VALIDATION" "invalid --id (expected [A-Za-z0-9], <=32 chars)"
  fi
  # Target must be a well-formed agent label AND a registered agent — no path to
  # inject into an arbitrary or unmanaged tmux session.
  [[ "$target" =~ ^[a-z][a-z0-9-]{0,31}$ ]] \
    || fail "$E_VALIDATION" "invalid target '$target' (lowercase letter start, [a-z0-9-], <=32 chars)"
  require_agent "$target"
  sudo -u "agent-${target}" tmux has-session -t "agent-${target}" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "tmux session 'agent-${target}' not found (is the agent running?)"

  # Sender + tier from the real sudo caller (agent-X -> X). A non-agent caller
  # (direct root / human) records as "human"; tier is empty unless the sender is
  # a registered agent. Mirrors auto_sender_from_sudo + the DIVE-1064 tier stamp.
  local s="${SUDO_USER#agent-}"
  [[ "${SUDO_USER:-}" == agent-* ]] || s="human"
  local tier=""
  tier="$(registry_read | jq -r --arg n "$s" '.agents[$n].isolation // empty' 2>/dev/null)"

  # Provenance envelope, mirroring cmd_send's [5dive-msg ...] header format.
  # Field order matches cmd_send: from, id, tier.
  local header="[5dive-msg from=${s}"
  [[ -n "$msgid" ]] && header+=" id=${msgid}"
  [[ -n "$tier" ]] && header+=" tier=${tier}"
  header+="]"
  local payload="${header} ${message}"

  # Same boot-race guard as cmd_send, then deliver by REUSING the literal-inject
  # primitive. The message is passed to send-keys with `-l --` (literal) and is
  # never interpreted as a command.
  if ! wait_agent_input_ready "$target"; then
    step "agent '$target' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
  fi
  if ! inject_and_submit "$target" "$payload"; then
    step "agent '$target': payload may not have submitted — pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)"
  fi
  ok "delivered to agent '$target'." \
     '{name:$n, delivered:true, from:$s, tier:($t|select(length>0))}' \
     --arg n "$target" --arg s "$s" --arg t "$tier"
}

# DIVE-1074: privileged inter-agent READ primitive — the read half of `ask` for a
# standard-isolation agent (which has no broad sudo, so it cannot run the
# `sudo -u agent-X tmux capture-pane` that `ask`'s reply-read needs). Hidden
# subcommand run as ROOT via a per-agent scoped sudoers grant (write_standard_sudoers),
# the sibling of `_deliver`. Same standing invariant: single-purpose, NEVER execs
# caller-controlled input (all args are validated literals; no eval/sh -c).
#
# It emits ONLY the reply window for ONE question: the pane lines AFTER the line
# carrying `id=<after-id>` and strictly BEFORE the next `[5dive-msg` marker line
# (or end of pane). Bounding to the next marker is a deliberate hardening over a
# naive "everything after the marker": an unbounded read would let a standard
# caller pass an OLD marker id and read a peer's LATER pane activity (its replies
# to other agents, its work output, secrets). With the bound, a caller reads at
# most one reply window per marker; and since `ask` mints fresh 4-byte-urandom
# ids (gen_msg_id), a caller can only realistically target replies to questions
# it actually asked. It can NEVER read content before its marker.
cmd_capture() {
  require_root "agent _capture"
  local after_id="" buf_lines=2000
  local -a _pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --after-id=*)     after_id="${1#--after-id=}" ;;
      --buffer-lines=*) buf_lines="${1#--buffer-lines=}" ;;
      --)               shift; _pos+=("$@"); break ;;
      *)                _pos+=("$1") ;;
    esac
    shift
  done
  local target="${_pos[0]:-}"
  [[ -n "$target" ]]   || fail "$E_USAGE" "usage: 5dive agent _capture <target> --after-id=<id> [--buffer-lines=N]"
  [[ -n "$after_id" ]] || fail "$E_USAGE" "--after-id is required"
  [[ "$target" =~ ^[a-z][a-z0-9-]{0,31}$ ]] \
    || fail "$E_VALIDATION" "invalid target '$target' (lowercase letter start, [a-z0-9-], <=32 chars)"
  [[ "$after_id" =~ ^[A-Za-z0-9]{1,32}$ ]] \
    || fail "$E_VALIDATION" "invalid --after-id (expected [A-Za-z0-9], <=32 chars)"
  [[ "$buf_lines" =~ ^[0-9]{1,6}$ ]] \
    || fail "$E_VALIDATION" "--buffer-lines must be a positive integer"
  require_agent "$target"
  sudo -u "agent-${target}" tmux has-session -t "agent-${target}" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "tmux session 'agent-${target}' not found (is the agent running?)"

  local capture
  capture=$(sudo -u "agent-${target}" tmux capture-pane -t "agent-${target}" -p -S "-${buf_lines}" 2>/dev/null) || true
  # Slice: lines AFTER the first line containing id=<after-id>, stopping BEFORE
  # the next [5dive-msg marker (bounds the read to a single reply window). Empty
  # output if the marker isn't present yet — the caller (`ask`) polls until the
  # reply appears and stabilises.
  awk -v id="id=${after_id}" '
    found && index($0, "[5dive-msg") { exit }
    found                           { print }
    index($0, id)                   { found=1 }
  ' <<<"$capture"
}

# DIVE-1088: hidden privileged service-lifecycle primitive — the sanctioned
# replacement for a raw `sudo systemctl <verb> 5dive-<unit>` grant. sudo-rs (the
# default sudo on Ubuntu 26.04) rejects wildcards inside command arguments, so the
# old admin sudoers `systemctl restart 5dive-agent@*` / `5dive-*.service` lines
# broke `agent create` there. This helper carries the SAME scope those lines had
# (start|stop|restart of a 5dive-owned unit ONLY) but enforces it in code, and is
# reached via the admin's existing whole-CLI grant (`/usr/local/bin/5dive *`) — no
# new sudoers wildcard. Standing invariant (mirrors _deliver/_capture): single-
# purpose, runs a FIXED `systemctl --no-pager <verb> <validated-unit>`, and NEVER
# execs caller-controlled input (no eval / sh -c / pager) — so it cannot become an
# agent->root escape. Not advertised (underscore prefix).
cmd_svc() {
  require_root "agent _svc"
  local action="${1:-}" unit="${2:-}"
  case "$action" in
    start|stop|restart) ;;
    *) fail "$E_USAGE" "usage: 5dive agent _svc <start|stop|restart> <5dive-unit>" ;;
  esac
  [[ -n "$unit" ]] || fail "$E_USAGE" "unit is required"
  # 5dive-owned units only: a templated agent unit (5dive-agent@<name>) or a plain
  # 5dive-<name> service, optional .service suffix. No slash, space, or shell
  # metacharacter can pass, and it must start with the literal `5dive-` prefix so
  # it can neither escape the 5dive scope nor be read as a systemctl option/flag.
  # This exactly matches the scope of the retired `5dive-agent@*` / `5dive-*.service`
  # sudoers lines. The unit is passed to systemctl as a single argv (no shell).
  [[ "$unit" =~ ^5dive-(agent@)?[A-Za-z0-9_.-]+(\.service)?$ ]] \
    || fail "$E_VALIDATION" "refusing non-5dive or malformed unit '$unit' (expected 5dive-agent@<name> or 5dive-<name>[.service])"
  systemctl --no-pager "$action" "$unit" >&2
  ok "service '$unit' ${action}ed." '{unit:$u, action:$a}' --arg u "$unit" --arg a "$action"
}

# Inject a message into the agent's tmux session. Uses inject_and_submit so the
# text is delivered literally AND actually submitted (bracketed-paste safe).
# Not exposed via /agents/exec: arbitrary text won't pass the API arg regex, so
# this is CLI + direct-shelld only.
# DIVE-1337: decide whether an inter-agent send/ask must self-elevate through the
# scoped `_deliver`/`_capture` primitives instead of the direct `sudo -u agent-X
# tmux` path. The discriminator is CAPABILITY, not the isolation tier label: the
# direct path needs broad `sudo -u <other-user>`, which only a full-trust
# (NOPASSWD:ALL) caller has. Scoped-sudo OSS agents cannot run `sudo -u agent-X`
#   * `standard` — grant is exactly `5dive agent _deliver`/`_capture`;
#   * `admin`    — grant is `/usr/local/bin/5dive *` (the whole CLI as root, but
#                  runas root only, so NOT `sudo -u`).
# so for them the direct path fails with "a password is required", which the
# has-session check downstream MIS-REPORTS as "session not found". Both, however,
# CAN reach `sudo 5dive agent _deliver` (standard via its explicit grant, admin via
# the whole-CLI grant), so route them there.
#
# Previously the gate was `isolation == standard`, which left OSS `admin` agents on
# the broken direct path — and on every fresh OSS box the bootstrap first agent is
# `admin`, so a2a was silently dead between the two commonest agents (DIVE-1337).
# Probing the real sudo capability auto-adapts with no tier list to maintain:
# managed-host agents (NOPASSWD:ALL, internal-box posture) keep the direct path and
# its --from/--reply-to channel plumbing; every scoped OSS agent self-elevates.
# `sudo -n` never prompts (fail-closed). Root callers (EUID 0, e.g. `_deliver`
# itself) always take the direct path.
a2a_needs_scoped() {
  local target="$1"
  [[ $EUID -eq 0 ]] && return 1
  # Can this caller `sudo -u` the target's user directly (what the direct tmux path
  # needs)? If yes, use the direct path; if denied, self-elevate via _deliver.
  sudo -n -u "agent-${target}" true 2>/dev/null && return 1
  return 0
}

cmd_send() {
  local name="" message="" from="" from_set=0 raw=0
  local reply_to_chat="" reply_to_msg=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message=*)        message="${1#--message=}" ;;
      --from=*)           from="${1#--from=}"; from_set=1 ;;
      --raw)              raw=1 ;;
      --reply-to-chat=*)  reply_to_chat="${1#--reply-to-chat=}" ;;
      --reply-to-msg=*)   reply_to_msg="${1#--reply-to-msg=}" ;;
      --)                 shift; positional+=("$@"); break ;;
      -*)                 fail "$E_USAGE" "unknown flag: $1" ;;
      *)                  positional+=("$1") ;;
    esac
    shift
  done
  if [[ ${#positional[@]} -gt 0 ]]; then
    name="${positional[0]}"
    positional=("${positional[@]:1}")
  fi
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent send <name> <text...> | --message=<text> [--from=<sender>] [--raw] [--reply-to-chat=<id> [--reply-to-msg=<id>]]"
  if [[ -z "$message" && ${#positional[@]} -gt 0 ]]; then
    message="${positional[*]}"
  fi
  [[ -n "$message" ]] || fail "$E_USAGE" "message is empty"

  # DIVE-1065: a standard-isolation agent has no broad sudo, so it cannot run the
  # direct `sudo -u agent-X tmux` inject this function uses below. Route a
  # non-root agent caller through the privileged, tightly-scoped `_deliver`
  # primitive instead (granted by write_standard_sudoers: NOPASSWD on exactly
  # `/usr/local/bin/5dive agent _deliver *`). Admins/root fall through to the
  # direct-inject path unchanged. We hand off ONLY the resolved target + message:
  # `_deliver` derives sender/tier from the real sudo caller and deliberately
  # does not carry --from/--reply-to-chat (a standard send is peer-to-peer, with
  # no channel plumbing). Absolute path so it matches the sudoers rule exactly.
  # DIVE-1065/1337: route a scoped-sudo agent's send through the scoped _deliver
  # grant (admin OR standard on OSS — see a2a_needs_scoped). Full-trust
  # (NOPASSWD:ALL) and root/internal callers keep the direct path below (and their
  # --from/--reply-to-chat plumbing). A scoped a2a send is peer-to-peer, so it
  # carries no channel plumbing. sudo -n = fail-closed, never prompts.
  if a2a_needs_scoped "$name"; then
    exec sudo -n /usr/local/bin/5dive agent _deliver "$name" "$message"
  fi

  require_agent "$name"
  sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"

  # Optional reply-target hint. If present, it tells the receiver: "the user is
  # reachable in this chat — reply there directly via your own bot rather than
  # back through me." --raw skips wrapping entirely, so combining the two has
  # nowhere to put the hint.
  if [[ -n "$reply_to_chat" || -n "$reply_to_msg" ]]; then
    (( ! raw )) || fail "$E_USAGE" "--raw cannot be combined with --reply-to-chat/--reply-to-msg"
  fi
  # --raw + --from is contradictory: --raw means "no envelope, no metadata"
  # (for piping pre-formatted prompts), so claiming a sender identity has
  # nowhere to land. The sender-side outbound mirror also gates on (!raw) —
  # if --raw silently strips the [5dive-msg from=X] envelope while --from
  # suggests "this is from me", the mirror would skip with no warning and
  # the operator would see neither side of the conversation. Force the
  # caller to pick one: identify yourself (and accept the envelope) or send
  # raw (and accept anonymity).
  if (( raw && from_set )); then
    fail "$E_USAGE" "--raw cannot be combined with --from (raw mode strips the envelope that carries sender identity)"
  fi
  if [[ -n "$reply_to_chat" ]]; then
    valid_telegram_chat_id "$reply_to_chat" \
      || fail "$E_VALIDATION" "invalid --reply-to-chat (expected numeric chat id, optionally negative)"
  fi
  if [[ -n "$reply_to_msg" ]]; then
    [[ -n "$reply_to_chat" ]] \
      || fail "$E_USAGE" "--reply-to-msg requires --reply-to-chat"
    [[ "$reply_to_msg" =~ ^[0-9]{1,20}$ ]] \
      || fail "$E_VALIDATION" "invalid --reply-to-msg (expected positive integer)"
  fi

  # Wrap with [5dive-msg from=<sender> id=<id> ...] when this is an inter-agent
  # send, so the receiver can see who's pinging it and reply by name. --raw
  # opts out (useful when piping prompts that already format themselves).
  # --from explicitly empty (`--from=`) also opts out — unless --reply-to-chat
  # is set, in which case we force-wrap (synthetic sender "human") so the hint
  # actually reaches the receiver.
  local payload="$message" sender="" msg_id=""
  if (( ! raw )); then
    if (( from_set )); then
      sender="$from"
    else
      sender="$(auto_sender_from_sudo)"
    fi
    if [[ -z "$sender" && -n "$reply_to_chat" ]]; then
      sender="human"
    fi
    if [[ -n "$sender" ]]; then
      valid_sender_label "$sender" \
        || fail "$E_VALIDATION" "invalid --from label '$sender' (lowercase letter start, [a-z0-9-], <=32 chars)"
      msg_id="$(gen_msg_id)"
      # DIVE-1064: stamp the sender's isolation tier so a receiver can down-trust
      # a lower-privilege peer. Derived from the REAL sudo caller (not the
      # spoofable --from label), so it holds even if from= is forged. Omitted
      # when there's no agent caller (human/root) or no recorded tier.
      local _caller _tier=""
      _caller="$(auto_sender_from_sudo)"
      [[ -n "$_caller" ]] && _tier="$(registry_read | jq -r --arg n "$_caller" '.agents[$n].isolation // empty' 2>/dev/null)"
      local header="[5dive-msg from=${sender} id=${msg_id}"
      [[ -n "$_tier" ]] && header+=" tier=${_tier}"
      [[ -n "$reply_to_chat" ]] && header+=" reply-to-chat=${reply_to_chat}"
      [[ -n "$reply_to_msg" ]] && header+=" reply-to-msg=${reply_to_msg}"
      header+="]"
      payload="${header} ${message}"
    fi
  fi

  # Don't fire keystrokes into a still-booting TUI — they'd be dropped and the
  # message lost. Wait for the input prompt to render (fast no-op when already
  # up). On timeout we still send best-effort and warn, rather than hang.
  if ! wait_agent_input_ready "$name"; then
    step "agent '$name' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
  fi

  if ! inject_and_submit "$name" "$payload"; then
    step "agent '$name': payload may not have submitted — pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)"
  fi

  # Mirror the outbound into the sender's group chat (best-effort). Gated on a
  # real envelope: a raw/anonymous send has no sender identity to mirror under.
  (( raw )) || mirror_interagent_outbound "$name" "$message"

  ok "sent to agent '$name'." \
     '{name:$n, sent:true, bytes:($p|length), from:($s|select(length>0)), msg_id:($i|select(length>0)), reply_to_chat:($rc|select(length>0)), reply_to_msg:($rm|select(length>0))}' \
     --arg n "$name" --arg p "$payload" --arg s "$sender" --arg i "$msg_id" --arg rc "$reply_to_chat" --arg rm "$reply_to_msg"
}

# Synchronous send + wait — the inter-agent counterpart to cmd_send. Drops the
# wrapped envelope into the receiver's tmux, then polls capture-pane until the
# scrollback after our marker line stops growing for --idle-secs (or
# --timeout fires). Returns just the reply body, not the receiver's prompt
# echo. Idle-by-stability is intentionally dumb: receiver CLIs don't all emit
# a clean "I'm done" sentinel, and trying to detect per-CLI idle prompts is
# brittle. A noisy receiver (e.g. one printing progress every second forever)
# will keep us awake until --timeout — that's correct behaviour.
cmd_ask() {
  local name="" message="" from="" from_set=0
  local reply_to_chat="" reply_to_msg=""
  local timeout=120 idle=5 poll=2 buf_lines=2000
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message=*)        message="${1#--message=}" ;;
      --from=*)           from="${1#--from=}"; from_set=1 ;;
      --reply-to-chat=*)  reply_to_chat="${1#--reply-to-chat=}" ;;
      --reply-to-msg=*)   reply_to_msg="${1#--reply-to-msg=}" ;;
      --timeout=*)        timeout="${1#--timeout=}" ;;
      --idle-secs=*)      idle="${1#--idle-secs=}" ;;
      --poll-secs=*)      poll="${1#--poll-secs=}" ;;
      --buffer-lines=*)   buf_lines="${1#--buffer-lines=}" ;;
      --)                 shift; positional+=("$@"); break ;;
      -*)                 fail "$E_USAGE" "unknown flag: $1" ;;
      *)                  positional+=("$1") ;;
    esac
    shift
  done
  if [[ ${#positional[@]} -gt 0 ]]; then
    name="${positional[0]}"
    positional=("${positional[@]:1}")
  fi
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent ask <name> <text...> [--from=<sender>] [--reply-to-chat=<id> [--reply-to-msg=<id>]] [--timeout=120] [--idle-secs=5] [--poll-secs=2]"
  if [[ -z "$message" && ${#positional[@]} -gt 0 ]]; then
    message="${positional[*]}"
  fi
  [[ -n "$message" ]] || fail "$E_USAGE" "message is empty"
  for n in "$timeout" "$idle" "$poll" "$buf_lines"; do
    [[ "$n" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "timeout/idle/poll/buffer-lines must be positive integers"
  done
  (( poll >= 1 )) || fail "$E_VALIDATION" "--poll-secs must be >= 1"

  if [[ -n "$reply_to_chat" ]]; then
    valid_telegram_chat_id "$reply_to_chat" \
      || fail "$E_VALIDATION" "invalid --reply-to-chat (expected numeric chat id, optionally negative)"
  fi
  if [[ -n "$reply_to_msg" ]]; then
    [[ -n "$reply_to_chat" ]] \
      || fail "$E_USAGE" "--reply-to-msg requires --reply-to-chat"
    [[ "$reply_to_msg" =~ ^[0-9]{1,20}$ ]] \
      || fail "$E_VALIDATION" "invalid --reply-to-msg (expected positive integer)"
  fi

  # DIVE-1074/1337: a scoped-sudo agent (OSS admin OR standard) has no broad
  # `sudo -u`, so it can't run the direct `sudo -u agent-X tmux` inject+capture that
  # `ask` uses below. Route it through the scoped primitives instead:
  # `_deliver --id` (inject carrying a marker) + `_capture --after-id` (bounded
  # reply read). Same capability probe as cmd_send. Full-trust/root keep the direct
  # path unchanged.
  local use_scoped=0
  a2a_needs_scoped "$name" && use_scoped=1

  # Resolve sender — ask always wraps because we need a marker to slice the reply
  # window. On the scoped path `_deliver` re-derives the sender + tier from the
  # real sudo caller, so this local `sender` is only for this command's JSON
  # summary. Fall back to a literal "ask" if we can't infer one.
  local sender msg_id
  if (( from_set )); then
    sender="$from"
  else
    sender="$(auto_sender_from_sudo)"
  fi
  [[ -n "$sender" ]] || sender="ask"
  valid_sender_label "$sender" \
    || fail "$E_VALIDATION" "invalid --from label '$sender' (lowercase letter start, [a-z0-9-], <=32 chars)"
  msg_id="$(gen_msg_id)"

  if (( use_scoped )); then
    # Inject via the scoped delivery grant, carrying our fresh marker id.
    # _deliver validates the target + running session and builds the provenance
    # header (from=<caller> id=<msg_id> tier=standard). sudo -n = fail-closed.
    # A standard ask is peer-to-peer, so (like send) it carries no --reply-to
    # channel plumbing.
    if ! sudo -n /usr/local/bin/5dive agent _deliver --id="$msg_id" "$name" "$message"; then
      fail "$E_GENERIC" "scoped delivery to '$name' failed (missing _deliver grant? re-provision the agent)"
    fi
  else
    require_agent "$name"
    sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null \
      || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"
    local header="[5dive-msg from=${sender} id=${msg_id}"
    [[ -n "$reply_to_chat" ]] && header+=" reply-to-chat=${reply_to_chat}"
    [[ -n "$reply_to_msg" ]] && header+=" reply-to-msg=${reply_to_msg}"
    header+="]"
    local payload="${header} ${message}"
    # Same boot-race guard as cmd_send: wait for the input prompt before sending
    # so a freshly-(re)started target doesn't silently drop the question.
    if ! wait_agent_input_ready "$name"; then
      step "agent '$name' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
    fi
    if ! inject_and_submit "$name" "$payload"; then
      step "agent '$name': question may not have submitted — pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)"
    fi
  fi

  # Mirror the outbound into the sender's group chat (best-effort). Unprivileged
  # (runs as the caller), so it's safe on both paths.
  mirror_interagent_outbound "$name" "$message"

  local start now last_change reply="" prev_slice="" capture slice
  start=$(date +%s)
  last_change=$start
  while :; do
    sleep "$poll"
    now=$(date +%s)
    if (( use_scoped )); then
      # Scoped bounded read: _capture returns ONLY our reply window, already
      # sliced (after our marker, up to the next marker). sudo -n = fail-closed.
      slice=$(sudo -n /usr/local/bin/5dive agent _capture "$name" --after-id="$msg_id" --buffer-lines="$buf_lines" 2>/dev/null) || true
    else
      capture=$(sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -S "-${buf_lines}" 2>/dev/null) || true
      # Everything after the first line containing our marker. The receiver's
      # CLI typically echoes the user input once, so the slice begins right
      # after that echo and grows as the receiver responds.
      slice=$(awk -v id="id=${msg_id}" 'found {print} index($0, id) {found=1}' <<<"$capture")
    fi

    if [[ "$slice" != "$prev_slice" ]]; then
      last_change=$now
      prev_slice="$slice"
    fi

    if (( now - start >= timeout )); then
      fail "$E_TIMEOUT" "no idle reply from '$name' within ${timeout}s (msg_id=${msg_id})"
    fi
    if [[ -n "$slice" ]] && (( now - last_change >= idle )); then
      reply="$slice"
      break
    fi
  done

  if (( JSON_MODE )); then
    jq -Rn --arg n "$name" --arg s "$sender" --arg i "$msg_id" --arg r "$reply" \
      --arg rc "$reply_to_chat" --arg rm "$reply_to_msg" \
      '{ok:true, data:{name:$n, from:$s, msg_id:$i, reply:$r, reply_to_chat:($rc|select(length>0)), reply_to_msg:($rm|select(length>0))}}'
  else
    printf '%s\n' "$reply"
  fi
}

# Create a new agent with the same type (and by default the same workdir) as an
# existing one. Channels default to none unless the caller provides a fresh
# token — two agents can't share a telegram/discord bot.
cmd_clone() {
  local src="" dst="" override_channels="" channels_set=0
  local telegram_token="" discord_token="" override_workdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --channels=*)        override_channels="${1#--channels=}"; channels_set=1 ;;
      --telegram-token=*)  telegram_token="${1#--telegram-token=}" ;;
      --discord-token=*)   discord_token="${1#--discord-token=}" ;;
      --workdir=*)         override_workdir="${1#--workdir=}" ;;
      -*)                  fail "$E_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$src" ]]; then src="$1"
        elif [[ -z "$dst" ]]; then dst="$1"
        else fail "$E_USAGE" "extra arg: $1"
        fi ;;
    esac
    shift
  done
  [[ -n "$src" && -n "$dst" ]] \
    || fail "$E_USAGE" "usage: 5dive agent clone <src> <dst> [--channels=...] [--telegram-token=...] [--discord-token=...] [--workdir=...]"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$src" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "source agent '$src' does not exist"
  if jq -e --arg n "$dst" '.agents[$n] != null' <<<"$reg" >/dev/null; then
    fail "$E_CONFLICT" "destination agent '$dst' already exists"
  fi

  local src_type src_channels src_workdir src_profile
  src_type=$(jq     -r --arg n "$src" '.agents[$n].type'              <<<"$reg")
  src_channels=$(jq -r --arg n "$src" '.agents[$n].channels // "none"' <<<"$reg")
  src_workdir=$(jq  -r --arg n "$src" '.agents[$n].workdir // empty'  <<<"$reg")
  src_profile=$(jq  -r --arg n "$src" '.agents[$n].authProfile // empty' <<<"$reg")

  local new_channels
  if (( channels_set )); then
    new_channels="$override_channels"
  elif [[ "$src_channels" != "none" && -z "$telegram_token" && -z "$discord_token" ]]; then
    warn "source has channels=$src_channels but no --${src_channels}-token provided — clone defaults to channels=none"
    new_channels="none"
  else
    new_channels="$src_channels"
  fi

  local new_workdir="${override_workdir:-$src_workdir}"

  local -a args=("$dst" "--type=${src_type}" "--channels=${new_channels}")
  [[ -n "$new_workdir" ]]    && args+=("--workdir=${new_workdir}")
  [[ -n "$src_profile" ]]    && args+=("--auth-profile=${src_profile}")
  [[ -n "$telegram_token" ]] && args+=("--telegram-token=${telegram_token}")
  [[ -n "$discord_token" ]]  && args+=("--discord-token=${discord_token}")
  step "Cloning '$src' -> '$dst' (type=$src_type, channels=$new_channels)"
  # cmd_create emits its own ok/fail envelope, which becomes the clone's
  # output too — dashboards parse exactly one envelope.
  cmd_create "${args[@]}"
}

cmd_stats() {
  local name="" all=0 want_health=-1   # want_health: -1=unset (default by mode)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1 ;;
      --health) want_health=1 ;;
      --no-health) want_health=0 ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done

  # The stall-health probe scrapes each agent's live tmux pane (one
  # `capture-pane` per agent) — the dominant, non-scaling cost when the
  # dashboard polls `stats --all` every 30s (N captures + N systemctl on a
  # 2-CPU box pegs CPU and blows the exec timeout). So it's OPT-IN: single
  # `stats <name>` keeps it (the detail screen wants the stall banner), but
  # `stats --all` skips it by default. Force a fleet sweep with `--all
  # --health`; suppress on a single agent with `--no-health`. (DIVE-326)
  if (( want_health == -1 )); then
    if (( all )); then want_health=0; else want_health=1; fi
  fi

  # Batched form: `stats --all` emits every agent's stats object in ONE
  # invocation so the dashboard/mobile collapse N per-agent box execs into a
  # single one (the box shell rate-limit is shared across all of a user's exec
  # traffic, so N calls every few seconds trip it). Reuses the single-agent path
  # per agent (no duplicated gather), JSON-only since it's a machine endpoint.
  # (DIVE-206)
  if (( all )); then
    [[ -z "$name" ]] || fail "$E_USAGE" "stats --all takes no name"
    local _reg _names _arr="[]" _n _d
    _reg=$(registry_read)
    _names=$(jq -r '.agents | keys[]' <<<"$_reg" 2>/dev/null || true)
    local _hflag="--no-health"; (( want_health )) && _hflag="--health"
    for _n in $_names; do
      # Subshell isolates the forced JSON_MODE; unwrap the single-agent `.data`.
      # Pass the resolved health pref so the per-agent gather honors --all's
      # default (no pane scrape) unless the caller asked for --all --health.
      _d=$(JSON_MODE=1; cmd_stats "$_n" "$_hflag" 2>/dev/null | jq -c '.data' 2>/dev/null) || continue
      [[ -n "$_d" && "$_d" != "null" ]] || continue
      _arr=$(jq -c --argjson d "$_d" '. + [$d]' <<<"$_arr")
    done
    printf '{"ok":true,"data":%s}\n' "$_arr"
    return 0
  fi

  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent stats <name> [--json] [--no-health] | stats --all [--health] --json"
  require_agent "$name"

  local reg
  reg=$(registry_read)

  local svc="5dive-agent@${name}.service"
  # One shell-out for all systemd fields we care about.
  local props
  props=$(systemctl show "$svc" \
    --property=ActiveState,SubState,Result,NRestarts,ActiveEnterTimestamp,ExecMainStartTimestamp,ExecMainStatus,ExecMainExitTimestamp \
    --no-page 2>/dev/null || true)
  local active sub result restarts active_ts main_ts exit_status exit_ts
  active=$(awk     -F= '/^ActiveState=/{print $2}'              <<<"$props")
  sub=$(awk        -F= '/^SubState=/{print $2}'                 <<<"$props")
  result=$(awk     -F= '/^Result=/{print $2}'                   <<<"$props")
  restarts=$(awk   -F= '/^NRestarts=/{print $2}'                <<<"$props")
  active_ts=$(awk  -F= '/^ActiveEnterTimestamp=/{print $2}'     <<<"$props")
  main_ts=$(awk    -F= '/^ExecMainStartTimestamp=/{print $2}'   <<<"$props")
  exit_status=$(awk -F= '/^ExecMainStatus=/{print $2}'          <<<"$props")
  exit_ts=$(awk    -F= '/^ExecMainExitTimestamp=/{print $2}'    <<<"$props")

  local type channels created workdir
  type=$(jq     -r --arg n "$name" '.agents[$n].type'                      <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'        <<<"$reg")
  created=$(jq  -r --arg n "$name" '.agents[$n].createdAt // empty'        <<<"$reg")
  workdir=$(jq  -r --arg n "$name" --arg d "$DEFAULT_WORKDIR" '.agents[$n].workdir // $d' <<<"$reg")

  # Best-effort health: the bare systemd state says "active" even when the
  # agent is wedged at a rate-limit menu or a login screen. Scrape the live
  # pane for those banners (mirrors the telegram plugin's detectStallCause) so
  # the dashboard can surface a stall the operator would otherwise only learn
  # via Telegram. Empty/`null` when running clean or when we can't read the
  # pane (e.g. not root). Only meaningful while active.
  local health="null"
  if (( want_health )) && [[ "$active" == "active" ]]; then
    local pane
    pane=$(sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -S -40 2>/dev/null | tail -c 4000 || true)
    if [[ -n "$pane" ]]; then
      if grep -qiE "session limit|usage limit|hit your (usage|session) limit|rate limit|/rate-limit-options" <<<"$pane"; then
        local reset; reset=$(grep -oiE "resets?[^|]*" <<<"$pane" | head -1 | tr -s ' ' | sed 's/[[:space:]]*$//')
        health=$(jq -cn --arg d "${reset:-no reset time shown}" '{cause:"rate_limited", detail:$d}')
      elif grep -qiE "(sign ?in|log ?in|authenticate|re-?authenticate|enter your api key)" <<<"$pane"; then
        health=$(jq -cn '{cause:"auth", detail:"sitting at a login screen — re-auth needed"}')
      fi
    fi
  fi

  if (( JSON_MODE )); then
    jq -cn \
      --arg name "$name" --arg type "$type" --arg channels "$channels" \
      --arg created "$created" --arg workdir "$workdir" \
      --arg active "$active" --arg sub "$sub" --arg result "$result" \
      --arg restarts "${restarts:-0}" --arg active_ts "$active_ts" \
      --arg main_ts "$main_ts" --arg exit_status "${exit_status:-}" --arg exit_ts "$exit_ts" \
      --argjson health "$health" '{
        ok:true, data:{
          name: $name, type: $type, channels: $channels,
          createdAt: $created, workdir: $workdir,
          active: $active, sub: $sub, result: $result,
          restarts: ($restarts | tonumber? // 0),
          activeEnter: $active_ts,
          execMainStart: $main_ts,
          execMainStatus: ($exit_status | tonumber? // null),
          execMainExit: $exit_ts,
          health: $health
        }
      }'
  else
    echo "name:         $name"
    echo "type:         $type"
    echo "channels:     $channels"
    echo "workdir:      $workdir"
    echo "created:      ${created:-unknown}"
    echo "state:        ${active:-unknown} (${sub:-unknown})"
    echo "result:       ${result:-unknown}"
    echo "restarts:     ${restarts:-0}"
    echo "active since: ${active_ts:-never}"
    echo "last start:   ${main_ts:-never}"
    echo "last exit:    ${exit_ts:-never} (status=${exit_status:-?})"
    if [[ "$health" != "null" ]]; then
      echo "health:       $(jq -r '"\(.cause) — \(.detail)"' <<<"$health")"
    fi
  fi
}
