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
  # MIRROR_CHUNKS: how many messages a long mirror may span (each up to
  # max_chars). Default 1 = the original single-message crop. When a body
  # overflows, chunks 2..N are labelled "(cont. i/N)" so the group reads as
  # one continued message; only what exceeds the LAST chunk is cropped with
  # the (+N chars) counter, so the flood ceiling stays bounded at
  # max_chunks * max_chars regardless of how much an agent pastes.
  local max_chunks="${MIRROR_CHUNKS:-1}"
  [[ "$max_chunks" =~ ^[0-9]+$ ]] && (( max_chunks >= 1 )) || max_chunks=1
  if (( ${#trimmed} <= max_chars )); then
    _mirror_post "$token" "$group_chat_id" "$thread_id" \
      "$(printf '%s\n%s' "$to_label" "$trimmed")" "$access_file"
  else
    local _total=${#trimmed} _off=0 _idx=1 _chunk _label _overflow _nchunks
    # DIVE-2265: a zero/negative width slices an EMPTY chunk, so _off never
    # advances. The loop still terminates (_idx increments regardless), but it
    # posts max_chunks BLANK messages to the group. Nothing is deliverable under
    # that config, so deliver nothing rather than a wall of empties.
    if (( max_chars <= 0 )); then
      printf 'mirror: MIRROR_MAX_BODY_CHARS=%s is not a usable width — nothing mirrored\n' \
        "$max_chars" >&2
      return 0
    fi
    # DIVE-2265: the denominator must be the number of chunks this body ACTUALLY
    # produces, not the configured ceiling. With MIRROR_CHUNKS=5 and a 2-chunk
    # body the old label read "(cont. 2/5)" and the reader waited for a third
    # part that never arrives. It is constant for the whole message, so compute
    # it ONCE here — computing it inside the loop is what invites the
    # per-iteration mistake this is fixing.
    _nchunks=$(( (_total + max_chars - 1) / max_chars ))
    (( _nchunks > max_chunks )) && _nchunks=$max_chunks
    while (( _off < _total && _idx <= max_chunks )); do
      _chunk="${trimmed:$_off:$max_chars}"
      _off=$(( _off + ${#_chunk} ))
      _label="$to_label"
      (( _idx > 1 )) && _label="${to_label} (cont. ${_idx}/${_nchunks})"
      _overflow=""
      if (( _idx == max_chunks && _off < _total )); then
        _overflow=" (+$(( _total - _off )) chars)"
      fi
      _mirror_post "$token" "$group_chat_id" "$thread_id" \
        "$(printf '%s\n%s%s' "$_label" "$_chunk" "$_overflow")" "$access_file"
      _idx=$(( _idx + 1 ))
    done
  fi
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
  # DIVE-1500: physical dry-run guard. Every owner/gate/mirror notify funnels
  # through this one POST, so honoring FIVEDIVE_NOTIFY_DRYRUN here makes a
  # fixture harness UNABLE to reach a paired human even on paths its stubs
  # miss (a 2026-07-19 render test DM'd the real owner through the live
  # connector token). Logs the would-be payload (never the token) and emits a
  # synthetic ok so delivery receipts/stamping still exercise downstream logic.
  if [[ -n "${FIVEDIVE_NOTIFY_DRYRUN:-}" && "${FIVEDIVE_NOTIFY_DRYRUN}" != "0" ]]; then
    local dry_line
    dry_line=$(printf 'notify-dryrun chat=%s thread=%s markup=%s text=%q' \
      "$chat" "${thread:-none}" "$([[ -n "$reply_markup" ]] && echo yes || echo no)" "$text")
    if [[ -n "${FIVEDIVE_NOTIFY_DRYRUN_LOG:-}" ]]; then
      printf '%s\n' "$dry_line" >>"$FIVEDIVE_NOTIFY_DRYRUN_LOG" 2>/dev/null || true
    fi
    printf '%s\n' "$dry_line" >&2 || true
    printf '%s' '{"ok":true,"dry_run":true,"result":{"message_id":0}}'
    return 0
  fi
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
#
# DIVE-1528: CODEX's composer marker "›" (U+203A, its "gpt-… · <cwd>" status
# footer accompanies the same box) was in _hb_idle_marker (DIVE-1211) — whose
# comment even says it "Mirrors wait_agent_input_ready" — but was NEVER added
# HERE, so every send to an IDLE codex agent (andy) timed out at 45s and printed
# the false "input prompt not detected — best-effort (may be lost)" warning, and
# inject_and_submit then ran against a pane it wrongly treated as mid-boot. Add
# "›" so codex is detected like every other TUI. Collision-free (only codex draws
# "›"; claude "❯"; antigravity its footer), so it stays type-agnostic. Keep this
# set in lockstep with _hb_idle_marker (cmd_heartbeat.sh) — they must not drift.
# devin does NOT get a glyph. Its composer is ❭ (U+276D), two codepoints from
# claude's ❯ (U+276F) and near-identical in most fonts — but worse, devin uses
# the SAME glyph for menu selections, so its workspace-trust dialog reads
# '❭ 1 Yes, trust <path>'. A glyph match there would report a credential/menu
# prompt as a chat composer and type into it — the gh#214 failure from the
# other end. Its composer placeholders are matched instead: 'Ask Devin' when
# idle, 'Guide Devin' mid-turn. Both are prose, so no codepoint collision is
# possible and a menu row cannot match. Fixtures: heartbeat_idle_marker_unit.
# The marker set lives in one PURE predicate (_agent_pane_input_ready) so it can
# be unit-tested against real pane samples with NO tmux — and a future TUI's
# marker is added in exactly one place. The readiness set is a SUPERSET of the
# _hb_idle_marker table (it also tolerates the mid-turn "esc to cancel", which a
# readiness — not idle — probe accepts); heartbeat_idle_marker_unit.sh asserts
# every idle marker is also a readiness marker, so the two can never drift again.
_agent_pane_input_ready() {
  grep -qE '❯|›|Ask Devin|Guide Devin|\? for shortcuts|esc to cancel' <<<"${1:-}"
}
# DIVE-2277: the types whose prompt is DETECTABLE — exactly the types with a marker
# in _agent_pane_input_ready above. KEEP IN LOCKSTEP with that predicate.
#
# WHY A LIST AND NOT ANOTHER MARKER. opencode and pi present no detectable prompt at
# all, so the poll below could never succeed for them: it ran the full 45s, returned 1,
# and the caller sent anyway. The wait was PROVABLY DEAD TIME — same send, 45s later,
# plus a false "input prompt not detected" warning. Measured on the council-demo box:
# 49s per send to root(opencode)/dario(pi) against 2-3s to a grok control doing the
# identical operation, deterministic across trials.
#
# Adding a third marker was the obvious move and is the wrong one. DIVE-348 added
# antigravity's footer, DIVE-1528 added codex's "›" — each fixed one harness and left
# the next one to pay 45s until somebody noticed. opencode and pi are the third and
# fourth. This inverts the default instead: a type we cannot detect does not wait.
# A NEW harness type therefore costs nothing by default, and the tax cannot silently
# reappear on harness number five.
# GROK IS VERIFIED, NOT INFERRED (olivia's review, DIVE-2277). It was first added
# here on timing alone (2-3s control vs 49s), which is weak — and _hb_idle_marker in
# cmd_heartbeat.sh appears to contradict it, returning EMPTY for grok with the comment
# "grok/opencode/unknown: byte-stability alone". Settled against a live pane on the
# council-demo box 2026-07-29: agent-creative (grok) renders U+276F "â¯" in its
# composer (2 occurrences) and _agent_pane_input_ready MATCHES that pane.
#
# The two tables are NOT in conflict; they answer different questions. This set asks
# "can we ever detect an input prompt" — grok: yes. _hb_idle_marker asks "is there a
# reliable AT-REST idle glyph" — a stricter bar grok has not been verified against.
# Leave _hb_idle_marker alone; a marker that is present in the composer is not thereby
# proven to be a trustworthy at-rest signal.
declare -A _AGENT_PROMPT_DETECTABLE=(
  [claude]=1 [codex]=1 [devin]=1 [antigravity]=1 [grok]=1
)

# DIVE-2385 (iteration 2) — extracted verbatim out of wait_agent_input_ready so the
# WAKE path can tell apart the TWO reasons that function returns 0: "the prompt
# rendered" and "this runtime has no prompt to detect". Both are `return 0` there
# and always were; only the wake path needs to distinguish them, and it must read
# the SAME table rather than a second copy that can drift.
#
# An UNKNOWN type (empty lookup) counts as detectable deliberately: paying a bounded
# wait beats skipping a real readiness check on a type we have not classified.
agent_prompt_detectable() {
  local _atype; _atype=$(agent_type "$1" 2>/dev/null || true)
  [[ -z "$_atype" || -n "${_AGENT_PROMPT_DETECTABLE[$_atype]+x}" ]]
}

wait_agent_input_ready() {
  local name="$1" timeout="${2:-45}"
  local user="agent-${name}" waited=0 pane
  # Skip the poll for a harness with no marker. Returns 0 (proceed) rather than 1:
  # for these types the 1 never meant "not ready", it meant "undetectable", and the
  # warning it triggered was false — DIVE-348 called that warning out by name.
  #
  # ONLY rc 1 means "undetectable". This test used to be an inline [[ ]] that could
  # not fail; a function CALL can (unavailable, extracted without its helper, a
  # future error path), and `|| return 0` would have turned the predicate's own
  # breakage into a blanket skip of the readiness check for EVERY agent — fail-open
  # in the worst direction, and silent. Measured: extracting this function without
  # its new helper made claude and codex skip the poll in 0s. Anything other than a
  # clean 1 falls through to the poll, which is the same call the UNKNOWN-type case
  # already makes: pay a bounded wait rather than skip a real check.
  local _det=0; agent_prompt_detectable "$name" || _det=$?
  (( _det == 1 )) && return 0
  while (( waited < timeout )); do
    pane=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
    _agent_pane_input_ready "$pane" && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

# DIVE-2137 (gh#214, reported by A-MO7SEN) — CREDENTIAL-PROMPT GUARD.
#
# `send`/`ask`/`_deliver` all assume the target pane is parked at a CHAT input.
# They check that something is ready to receive keystrokes (_agent_pane_input_ready)
# but never what that something IS. When the agent booted unauthenticated it sits
# on its login menu instead, and every marker above still matches — codex draws
# its "›" composer glyph on the API-key entry screen exactly as it does in chat.
# So an ordinary inter-agent message is typed into the credential field and
# SUBMITTED: the message body becomes the agent's stored API key (codex writes it
# straight to auth.json). Silent in both directions — the caller gets `delivered`,
# and the agent is now authenticated with a garbage secret.
#
# Fail-CLOSED is the whole point (a best-effort "warn and type anyway" is what
# made this reachable): we refuse and return a hard error rather than risk
# writing a peer's message into a secret store.
#
# PROVENANCE OF THE FINGERPRINTS — deliberately not invented. Every string below
# was read out of a shipped binary on a real box, verbatim:
#   codex   `.../@openai/codex-linux-x64/vendor/.../bin/codex` (strings)
#             "Sign in with ChatGPT" / "Sign in with Device Code"
#             "Provide your own API key" / "Pay for what you use"
#             "Paste or type your API key below. It will be stored locally in auth.json."
#             "Detected OPENAI_API_KEY environment variable."
#   claude  `~/.local/share/claude/versions/2.1.220` (strings)
#             "Claude account with subscription" / "Anthropic Console account"
# The codex pair independently CONFIRMS the two rows A-MO7SEN quoted from his own
# pane in gh#214. Strings we could NOT confirm against a shipped artifact (e.g.
# "Select login method", "Enter your API key") are deliberately NOT matched here —
# see tests/agent_send_credential_guard_unit.sh, which records that gap rather
# than papering over it.
#
# TWO TIERS, because where a string appears carries as much signal as the string:
#  1. LOGIN MENU — matched anywhere in the pane, but only on a CO-OCCURRING PAIR
#     of verbatim menu rows. A single row is not enough: agents talk about auth
#     constantly, and a one-line whole-pane match would refuse legitimate traffic.
#     (Measured, not assumed: while building this, a scan of live panes on this
#     box matched "api key" and "sign in" inside MY OWN chat pane — ordinary work
#     text. The pair requirement is what that observation bought.)
#  2. SECRET ENTRY FIELD — matched only in the LIVE PROMPT REGION (last 15 lines),
#     never in scrollback, so quoting a past login screen in chat can't trip it.
#     Includes a narrow generic rule for TUIs we have no sample of: a lone
#     "Password:" / "API key:" / "Token:" label with NOTHING after the colon,
#     which is a field awaiting input and essentially never prose.
_agent_pane_credential_prompt() {
  local pane="${1:-}" tail_region
  [[ -n "$pane" ]] || return 1

  # Tier 1 — login/auth MENU (co-occurring verbatim rows, anywhere in the pane).
  grep -qF 'Sign in with ChatGPT' <<<"$pane" \
    && grep -qF 'Provide your own API key' <<<"$pane" && return 0
  grep -qF 'Sign in with ChatGPT' <<<"$pane" \
    && grep -qF 'Sign in with Device Code' <<<"$pane" && return 0
  grep -qF 'Claude account with subscription' <<<"$pane" \
    && grep -qF 'Anthropic Console account' <<<"$pane" && return 0

  # Tier 2 — SECRET ENTRY FIELD, live prompt region only.
  tail_region="$(tail -n 15 <<<"$pane")"
  grep -qF 'Paste or type your API key' <<<"$tail_region" && return 0
  grep -qF 'Detected OPENAI_API_KEY environment variable.' <<<"$tail_region" && return 0
  grep -qE '^[[:space:]]*[>❯›*-]?[[:space:]]*(Password|Passphrase|API [Kk]ey|Api [Kk]ey|Token|Secret)[[:space:]]*:[[:space:]]*$' \
    <<<"$tail_region" && return 0

  return 1
}

# Boot-time breadcrumb left by the credential seed in `5dive-agent-start` when it
# could not read its source (DIVE-2137 defect A — see that script). Best-effort:
# printing nothing just means the refusal below carries no root-cause hint.
_agent_cred_seed_failure() {
  local name="$1"
  sudo -u "agent-${name}" cat "/home/agent-${name}/.5dive-cred-seed-failed" 2>/dev/null | head -1 || true
}

# Capture the target pane and decide whether typing into it is safe.
# 0 = safe to type, 1 = REFUSE (pane is a credential/login surface).
# Escape hatch for an operator who genuinely means to type into a login screen:
# FIVE_ALLOW_CREDENTIAL_PANE=1. Named in the refusal message so it is findable.
_agent_pane_safe_to_type() {
  local name="$1" pane
  [[ "${FIVE_ALLOW_CREDENTIAL_PANE:-0}" == "1" ]] && return 0
  pane=$(sudo -u "agent-${name}" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
  _agent_pane_credential_prompt "$pane" && return 1
  return 0
}

# Shared refusal text for the three inject sites, so the message can't drift.
_agent_credential_refusal_msg() {
  local name="$1" why
  why="$(_agent_cred_seed_failure "$name")"
  local m="refused to send: agent '${name}' is parked on a CREDENTIAL/LOGIN prompt, not a chat input"
  m+=" — typing there would store the message body as its API key (DIVE-2137, gh#214)."
  if [[ -n "$why" ]]; then
    m+=" Root cause at boot: ${why}"
  else
    m+=" The agent most likely booted unauthenticated; check its credential seed."
  fi
  m+=" Fix the credential (5dive agent auth ...) and restart it, then resend."
  m+=" To type into the prompt on purpose: FIVE_ALLOW_CREDENTIAL_PANE=1."
  printf '%s\n' "$m"
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
  # DIVE-2137: the ONE choke point every typed send funnels through (cmd_send,
  # cmd_ask, _deliver). The guard lives here rather than at the three call sites
  # for the same reason the readiness marker set was collapsed into one predicate
  # in DIVE-1528 — a per-site copy is a per-site drift. Distinct rc 3 so callers
  # can tell "refused, nothing was typed" from rc 1 "typed but maybe unsubmitted".
  _agent_pane_safe_to_type "$name" || return 3
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

# _ask_accumulate <transcript-file> — reassemble a scrolling stream from repeated
# screen snapshots. Reads one snapshot on stdin, folds it into the transcript,
# prints the whole transcript. DIVE-1901: a full-screen TUI is an alternate-screen
# pane with NO scrollback, so a snapshot is all we can ever have; the history has
# to be built by us, one frame at a time.
#
# Frames overlap heavily (a screen mostly repeats between polls), so appending
# blindly would duplicate everything. We align the new frame against the tail of
# the transcript and keep only what is past the alignment — the standard
# screen-scraper reassembly.
#
# The alignment is DELIBERATELY not an exact suffix/prefix match. A TUI redraws
# lines IN PLACE (a spinner, a token counter, a "● Thinking…" line that becomes
# the answer), so consecutive frames rarely agree exactly and an exact-match fold
# falls all the way through to "append the whole frame" — which double-counts the
# question echo and the answer, and leaves the marker sitting in the transcript
# twice. So we score every candidate overlap and take the best one that mostly
# agrees (>= half its lines), preferring the longest on a tie, and let the NEW
# render of the shared region replace the old one so in-place updates settle to
# their final text. If nothing aligns we anchor on the frame's first line if it
# is still in the transcript tail, and only if THAT fails do we append the frame
# whole — a duplicated line is recoverable, a lost vote is not.
#
# NB the python is passed with `-c`, NOT a `python3 - <<HEREDOC`. With `-` the
# interpreter reads its PROGRAM from stdin, which silently replaces the piped
# frame — `sys.stdin.read()` then returns nothing and every capture looks empty.
# Same shape as the bug this function exists to fix, so it is worth naming.
_ask_accumulate() {
  local f="$1"
  python3 -c '
import sys, pathlib
p = pathlib.Path(sys.argv[1])
old = p.read_text().split("\n") if p.exists() else []
if old and old[-1] == "":
    old.pop()
new = sys.stdin.read().split("\n")
while new and not new[-1].strip():   # drop the pane s blank bottom padding
    new.pop()

def fold(old, new):
    if not new:
        return old
    if not old:
        return list(new)
    limit = min(len(old), len(new))
    best_k, best_score = 0, None
    for k in range(1, limit + 1):
        same = sum(1 for a, b in zip(old[-k:], new[:k]) if a == b)
        if same < 2 or same * 2 < k:      # needs real, majority agreement
            continue
        score = (same / k, k)             # ratio first, then prefer the longer overlap
        if best_score is None or score > best_score:
            best_score, best_k = score, k
    if best_k == 0:
        # Nothing aligned as a block. Last chance: the frame s first real line may
        # still be sitting in the transcript tail (the pane scrolled hard, or was
        # redrawn from a different top line) — splice there.
        anchor = next((l for l in new if l.strip()), None)
        if anchor is not None:
            for i in range(len(old) - 1, max(-1, len(old) - limit - 1), -1):
                if old[i] == anchor:
                    best_k = len(old) - i
                    break
    if best_k == 0:
        return old + new                  # never drop a frame
    return old[:len(old) - best_k] + new  # the newest render of the shared region wins

out = fold(old, new)
p.write_text("\n".join(out) + ("\n" if out else ""))
sys.stdout.write("\n".join(out))
' "$f"
}

# _ask_reply_window <baseline-file> <sent-message-file> <msg-id> — turn the
# accumulated transcript on stdin into JUST what the seat said. Three subtractions,
# in order, none of which needs a per-harness signature list:
#
#  1. SLICE. Keep only what follows the LAST line carrying our `id=<msg-id>`,
#     stopping before the next `[5dive-msg` marker (so a message another agent
#     sends the seat mid-wait can never be read as our reply). The marker line
#     itself is kept for step 2 and dropped at the end — it is the anchor the echo
#     consumer needs, since a wrapped question begins ON that line. With an empty
#     msg-id (the scoped `_capture` path, which slices privileged-side) the whole
#     input is the window.
#  2. ECHO. The receiving CLI echoes the question back before answering, wrapped
#     across as many lines as the pane is narrow — those lines are OUR text, not a
#     reply, and returning them is a fabricated answer. We consume them by walking
#     the sent message ONCE, IN ORDER: each leading line must appear in the message
#     at (or just after) where the previous one ended. That ordering is what makes
#     "reply with exactly this: <X>" work — the echoed X consumes the message s
#     copy of X, so the seat s own X, having nothing left to match, survives.
#  3. CHROME. Any line already on the pane immediately before we injected is
#     furniture by construction — prompt, separators, footer, usage counter,
#     whatever this TUI draws. Exact match over the whole baseline, plus a
#     NORMALISED match (digits and day/month/am-pm tokens folded) over the
#     baseline s bottom region, because the footer counters change between the
#     baseline and the reply ("used 43% of your weekly limit", "Sonnet 5 5h: 12%")
#     and an exact compare lets them through as though the seat had said them.
#     Normalisation is limited to the bottom region and to lines with real words,
#     so a numeric reply can never be normalised into a chrome match.
#
# What is left is what the SEAT produced. Empty output means we have not captured
# a reply yet — never a reply.
_ask_reply_window() {
  local base="$1" msgf="$2" mid="$3" do_slice="${4:-1}" unfenced="${5:-0}"
  python3 -c '
import sys, pathlib, re
base_p, msg_p, mid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
do_slice = sys.argv[4] == "1"
allow_unfenced = sys.argv[5] == "1"
GLYPH = re.compile(r"^[>│┊|●⏺·⎿└╰\s]+")
lines = sys.stdin.read().split("\n")

# --- 0. the FENCE: if the seat wrapped its reply in our markers, that block IS
# the reply, and no scraping heuristic can beat it. Chrome, status lines and the
# question echo are all outside it by construction, and it needs no per-harness
# knowledge at all.
#
# The marker lines are matched EXACTLY, not by substring, and that is the whole
# defence against the prompt echo. The reply-format instruction is part of the
# prompt, so the echo ALWAYS carries a marker pair of its own — there are two
# pairs in the pane on every ask, and the extractor has to reject one of them.
#
# The first version leaned on the two markers being ADJACENT in the instruction,
# so an echoed pair would enclose nothing and be skipped for having an empty
# body. That defence dies on WRAP: a composer breaking the line between them
# isolates the opening marker on a line of its own, at which point a substring
# test cannot tell the echo from a real reply. Measured on a live antigravity
# seat at 2811 chars (DIVE-1901 iteration 1) — short asks passed, long ones came
# back with the footer, because only the long ones wrap there.
#
# Exact matching removes the guess: a real marker line carries the marker and
# NOTHING else (that is what the instruction asks for), while the echoed
# instruction always has prose beside at least one of its markers. So the echo
# can never qualify, whatever the wrap does, and this no longer depends on
# adjacency, on wrap width, or on whether the reply happens to sit above or
# below the composer in the pane — the live capture says it does not.
if mid:
    op, cl = "<5dive-r:" + mid + ">", "</5dive-r:" + mid + ">"
    def is_marker(l, m):
        # Decide whether this line IS the marker m and nothing else. The test
        # cannot be a glyph LIST — the first draft used one and a pane whose
        # bullet was not in it fell straight through to the fallback, which is a
        # per-harness signature smuggled in by the back door. So the rule is on
        # SHAPE: a TUI prefixes and suffixes lines with punctuation, box glyphs
        # and space, never with WORDS, while the echoed instruction always has
        # prose beside its markers. Strip leading non-word decoration, then
        # require the marker with nothing word-like left on either side.
        core = re.sub(r"^[^\w<]+", "", l.strip())
        if not core.startswith(m):
            return False
        return not re.search(r"\w", core[len(m):])
    # LOCAL PATCH: same-line fence — "<5dive-r:id> answer </5dive-r:id>" on one
    # line. Both unique markers present and closed, so it is a completed fence,
    # not a scrape. The echoed instruction has the markers ADJACENT (empty
    # inner text) and is skipped; an unfinished reply has no closing marker and
    # cannot match. Scan newest-first so a retry beats an earlier answer.
    for _l in reversed(lines):
        if op in _l and cl in _l:
            _inner = _l.split(op, 1)[1].split(cl, 1)[0].strip()
            if _inner:
                sys.stdout.write(_inner)
                sys.exit(0)

    opens = [i for i, l in enumerate(lines) if is_marker(l, op)]
    started = False
    for i in reversed(opens):
        body = []
        for l in lines[i + 1:]:
            if cl in l:
                # An embedded closing marker (prose on the same line) means this
                # block is the echoed instruction, not a reply: reject the whole
                # block rather than returning the instruction text as an answer.
                real = [b for b in body if b.strip()]
                if real:
                    started = True
                if is_marker(l, cl) and real:
                    # Dedent by the common indent the TUI added, so relative
                    # indentation inside a multi-line reply survives.
                    pad = min(len(b) - len(b.lstrip()) for b in real)
                    sys.stdout.write("\n".join(b[pad:].rstrip() for b in body).strip("\n"))
                    sys.exit(0)
                break
            if op in l or "[5dive-msg" in l:
                break
            body.append(l)
        if [b for b in body if b.strip()]:
            started = True          # opened and produced content, but never closed

    # --- 0b. the INLINE fence (DIVE-2216). The exact-line rule above is right
    # for what it defends, but it also rejects a REAL reply from a harness that
    # does not put the markers on lines of their own. Grok emits, verbatim:
    #
    #     <5dive-r:ID> ALIVE </5dive-r:ID>              (both markers, one line)
    #     ... VERDICT: insufficient </5dive-r:ID>       (closer beside the prose)
    #
    # Fence present, content present, and 0.16.32 harvested NOTHING from either —
    # so a grok seat was a SILENT ABSTAIN on every fenced ask, council ballots
    # included. That is the failure mode this whole rail exists to remove.
    #
    # The discriminator that lets the strictness go without letting the ECHO back
    # in is not the layout, it is the CONTENT. The echoed instruction carries the
    # two markers ADJACENT (`<5dive-r:ID></5dive-r:ID>` — that is how the hint is
    # written, deliberately), so the text between its markers is empty BY
    # CONSTRUCTION, however the composer wraps it and whichever side the prose
    # lands on. A real reply always has something between them. So: accept an
    # inline pair only when what sits between the markers is non-empty, and the
    # echo remains unreturnable — including the wrapped shape that broke the
    # adjacency defence in DIVE-1901 iteration 1 (opening marker isolated on its
    # own line by a line break, closing marker leading the next), which lands here
    # with an empty body and is still dropped.
    #
    # Two narrower rules on top, for the same reason:
    #   - a line with the opening marker but NO closer only opens a block if the
    #     marker STARTS it (TUI decoration allowed, words not) — prose before the
    #     opening marker is the signature of the echo;
    #   - an unclosed block still returns nothing, so a mid-write frame keeps the
    #     rail polling exactly as before.
    # This runs only after the strict pass has found nothing, so no seat that
    # works today changes behaviour.
    def wordy(s):
        # Is there CONTENT here, as opposed to what the TUI drew? Same shape rule
        # the strict matcher uses: decoration is punctuation, box glyphs and
        # space, never words. This is load-bearing — the first draft asked only
        # for non-whitespace, and the wrapped echo came back as "▌", its own
        # gutter glyph, which would have reopened DIVE-1901 through the new path.
        return bool(re.sub(r"^[^\w<]+", "", s.strip()))
    for i in reversed([i for i, l in enumerate(lines) if op in l]):
        head_l = lines[i]
        a = head_l.index(op) + len(op)
        if cl in head_l[a:]:
            # Complete pair on ONE line. Empty between => the echo, never a reply.
            # Plain strip is right HERE and only here: a TUI draws its decoration
            # at the START of a line, so anything sitting between two markers
            # mid-line was put there by the seat.
            between = head_l[a:head_l.index(cl, a)].strip()
            if between:
                sys.stdout.write(between)
                sys.exit(0)
            continue
        if not re.sub(r"^[^\w<]+", "", head_l.strip()).startswith(op):
            continue                # words before the marker: the echo, not a reply
        lead = head_l[a:].strip()   # content the seat put after the opening marker
        body = []
        for l in lines[i + 1:]:
            if op in l or "[5dive-msg" in l:
                break
            if cl in l:
                pre = l[:l.index(cl)]
                blk = body + ([pre] if wordy(pre) else [])
                real = [b for b in blk if b.strip()]
                if not (lead or [b for b in blk if wordy(b)]):
                    break           # fence closed around nothing: the echo again
                pad = min((len(b) - len(b.lstrip()) for b in real), default=0)
                out = ([lead] if lead else []) + [b[pad:].rstrip() for b in blk]
                sys.stdout.write("\n".join(out).strip("\n"))
                sys.exit(0)
            body.append(l)

    # FENCE-ONLY (DIVE-1901 iteration 2). Everything this ticket has ever caught
    # fabricating came from the scraping fallback below, never from the fence:
    # 0.14.7 returned the token PLUS the footer on antigravity and PURE BOX-DRAWING
    # on opencode; 0.15.1 returned "Gemini 3.6 Flash - high" on a long antigravity
    # ask. The live scrollback for that last one shows why, and it is not a parsing
    # bug: three successive renders caught the seat MID-WRITE ("<5dive-r:" then
    # "ing..." on the next frame), so the rail settled on a transient chrome render
    # while the answer was still being typed, and the fence completed afterwards.
    #
    # No amount of chrome subtraction fixes that. A scrape cannot tell "furniture
    # that happened to hold still" from "an answer", because at the moment it looks
    # they are the same thing: text on a screen that is not changing. The fence
    # CAN - an unclosed fence is unambiguously not finished.
    #
    # So the fallback is not a safety net, it is the fabrication path, and it is
    # deleted rather than hardened. When a fence was asked for we return the fenced
    # reply or NOTHING, and nothing becomes a loud timeout that says what it saw.
    # That is this ticket own instruction: a visible error beats a false abstain.
    # --allow-unfenced restores best-effort scraping for a caller that knowingly
    # wants it against a seat that cannot follow the instruction.
    if not allow_unfenced:
        sys.exit(0)

# --- 1. slice to our reply window (marker line inclusive) -------------------
if mid and do_slice:
    tag = "id=" + mid
    start = None
    for i, l in enumerate(lines):
        if tag in l:
            start = i
    if start is None:
        sys.exit(0)                       # marker not seen yet -> no window, no reply
    win = [lines[start]]
    for l in lines[start + 1:]:
        if "[5dive-msg" in l:
            break
        win.append(l)
else:
    win = [l for l in lines if "[5dive-msg" not in l]

# --- 2. consume the question echo ------------------------------------------
msg = re.sub(r"\s+", " ", msg_p.read_text() if msg_p.exists() else "").strip()

pos = 0
if mid and do_slice and win:
    head = win.pop(0)                     # the marker line: its tail is the start of the echo
    frag = re.sub(r"\s+", " ", head.split("]", 1)[1] if "]" in head else "").strip()
    if len(frag) >= 2:
        j = msg.find(frag)
        if j >= 0:
            pos = j + len(frag)
while win:
    frag = re.sub(r"\s+", " ", GLYPH.sub("", win[0])).strip()
    if len(frag) < 2:
        win.pop(0)                        # blank / bare glyph inside the echo block
        continue
    j = msg.find(frag, pos)
    if j < 0 or j - pos > 4:              # not the next thing we sent -> the echo is over
        break
    pos = j + len(frag)
    win.pop(0)

# --- 3. subtract the pane s own furniture -----------------------------------
# Furniture is anchored to the BOTTOM of the pane, so only the the baseline bottom
# region is the chrome list. Subtracting the whole baseline looks stronger and is
# actually worse: it also deletes a genuine reply that happens to repeat text
# still on screen (measured — a second identical ask returned only a status line
# because the seats answer matched the same answer from the first ask).
raw = [l for l in (base_p.read_text().split("\n") if base_p.exists() else "")][-20:]
exact = {l.strip() for l in raw if l.strip()}
DIGITS, WS, ALPHA = re.compile(r"\d+"), re.compile(r"\s+"), re.compile(r"[A-Za-z]")
TIMEISH = re.compile(r"\b(?:mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\b[ap]m\b", re.I)
def norm(s):
    return WS.sub(" ", TIMEISH.sub("@", DIGITS.sub("#", s))).strip().lower()
def wordy(s):
    return len(ALPHA.findall(s)) >= 4
# Dynamic counters live in the footer, so the fuzzy set is the baseline s bottom
# region only. Older conversation text stays on exact-match, where a reply that
# happens to repeat it is at worst dropped (a loud timeout), never fabricated.
fuzzy = {norm(l.strip()) for l in raw if l.strip() and wordy(l)}
RULE = re.compile("^[\\s─-╿▀-▟=_~*#.-]*$")
# An in-progress indicator ("esc to interrupt", "Ctrl+C to cancel") is drawn only
# WHILE the seat is thinking, so it is absent from the baseline and survives the
# subtraction above. Matched by SHAPE — <key> ... interrupt/cancel/stop — rather
# than by a per-harness string, because every TUI spinner is a self-describing
# interrupt control and none of them is a reply.
PROGRESS = re.compile(r"\b(?:esc|escape|ctrl[\s+-]*c)\b[^|]{0,32}?\b(?:interrupt|cancel|stop)\b", re.I)
out = []
for line in win:
    s = line.strip()
    if not s or s in exact or RULE.match(s) or "[5dive-msg" in s or PROGRESS.search(s):
        continue
    if wordy(s) and norm(s) in fuzzy:
        continue
    out.append(line)
sys.stdout.write("\n".join(out))
' "$base" "$msgf" "$mid" "$do_slice" "$unfenced"
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
  local s="${SUDO_USER#agent-}" _caller=""
  if [[ "${SUDO_USER:-}" == agent-* ]]; then _caller="$s"; else s="human"; fi
  # DIVE-2210: ALWAYS stamped, never conditional. A non-agent caller gets
  # tier=unknown:no-caller rather than a clean envelope with the field missing.
  local tier
  tier="$(envelope_tier "$_caller")"

  # Provenance envelope, mirroring cmd_send's [5dive-msg ...] header format.
  # Field order matches cmd_send: from, id, tier.
  local header="[5dive-msg from=${s}"
  [[ -n "$msgid" ]] && header+=" id=${msgid}"
  header+=" tier=${tier}"
  header+="]"
  local payload="${header} ${message}"

  # Same boot-race guard as cmd_send, then deliver by REUSING the literal-inject
  # primitive. The message is passed to send-keys with `-l --` (literal) and is
  # never interpreted as a command.
  if ! wait_agent_input_ready "$target"; then
    step "agent '$target' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
  fi
  local _rc=0
  inject_and_submit "$target" "$payload" || _rc=$?
  if (( _rc == 3 )); then
    fail "$E_AUTH_REQUIRED" "$(_agent_credential_refusal_msg "$target")"
  elif (( _rc != 0 )); then
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

  # DIVE-1931: fold this frame into a transcript BEFORE slicing, so the marker
  # survives scroll-off.
  #
  # `-S` is not a window we can rely on: a full-screen TUI is an alternate-screen
  # pane, whose scrollback is per-harness and often absent (DIVE-1901), so this
  # capture is frequently just the ~24 visible lines. A single point-in-time read
  # therefore loses the `id=<after-id>` line the moment a long reply pushes it off
  # screen — and with the anchor gone the awk below matches nothing and returns
  # EMPTY while the seat has answered. The direct path already solves this by
  # accumulating frames; the caller cannot do that here because the slice happens
  # on the far side of the sudo boundary and empty is all it ever sees.
  #
  # So the accumulation moves in here, and the bound stays privileged-side —
  # which is the point. This does NOT widen the read surface: the output is still
  # only "after MY marker, before the next [5dive-msg", and every line in the
  # transcript is a line this same caller was already handed by an earlier
  # `_capture` in its own poll loop. Folding frames is something the caller could
  # have done itself with the returns it already had; doing it here is what lets
  # the SLICE still be applied to them. What a caller cannot get remains exactly
  # what it could not get before: anything preceding its own marker (the awk only
  # starts printing after it), anything past the next message boundary, and any
  # window whose id it did not mint (gen_msg_id is 4-byte urandom).
  #
  # Keyed by (caller uid, target, marker) so concurrent asks — a convene fans out
  # ballots in parallel — never share a transcript, and one caller cannot feed
  # frames into another's. Root-owned and owner-only: the transcript itself is
  # never emitted, only the slice of it. (Under /var/lib/5dive, which is 2750,
  # the dir inherits the setgid bit and reads 2700 — group and other still have
  # no bits, which is the property that matters.)
  local acc_dir="${FIVE_CAPTURE_ACC_DIR:-/var/lib/5dive/capture-acc}"
  local uid_key="${SUDO_UID:-0}"
  # SUDO_UID is only meaningful because we are EUID 0 here (require_root above);
  # validate anyway so the key can never be anything but a filename component.
  [[ "$uid_key" =~ ^[0-9]{1,10}$ ]] || uid_key="0"
  local acc_file=""
  if mkdir -p "$acc_dir" 2>/dev/null && chmod 700 "$acc_dir" 2>/dev/null; then
    # Bound the store: a transcript outlives at most one ask (`--timeout` is
    # minutes), so anything untouched for an hour is abandoned. Without this the
    # dir grows one file per ask, forever.
    find "$acc_dir" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true
    acc_file="${acc_dir}/${uid_key}.${target}.${after_id}"
    if : >> "$acc_file" 2>/dev/null; then
      chmod 600 "$acc_file" 2>/dev/null || true
    else
      acc_file=""
    fi
  fi
  # Fail OPEN to the old single-frame behaviour if the store is unavailable: a
  # read-only /var/lib must degrade `ask` to the pre-DIVE-1931 capture, not
  # break it.
  if [[ -n "$acc_file" ]]; then
    capture=$(_ask_accumulate "$acc_file" <<<"$capture")
  fi

  # Slice: lines AFTER the first line containing id=<after-id>, stopping BEFORE
  # the next [5dive-msg marker (bounds the read to a single reply window). Empty
  # output if the marker has not been seen yet — the caller (`ask`) polls until the
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

# DIVE-2281 — the ENVELOPE's sender, and deliberately NOT a change to
# auto_sender_from_sudo.
#
# THE GAP: auto_sender_from_sudo resolves from $SUDO_USER, which is set only when the
# caller reached the CLI THROUGH sudo. The scoped a2a path always does
# (`a2a_needs_scoped` execs `sudo -n … agent _deliver`); a full-trust NOPASSWD:ALL
# agent running `5dive agent send` as ITSELF does not, so it resolved to "". An empty
# sender skips the envelope block below ENTIRELY — so the message arrived with NO
# `[5dive-msg …]` header at all, not `tier=unknown:no-caller`. Measured against a live
# pane: the receiver showed `❯ <message>` with zero occurrences of `5dive-msg`. An
# unenveloped inject is byte-indistinguishable from the paired HUMAN typing into that
# pane, which is how a DIVE-2279 gate answer could be "announced by a message claiming
# from=main" and be unattributable.
#
# WHY THIS IS A SEPARATE HELPER AND NOT A FIX TO auto_sender_from_sudo: that function
# is the SHARED ACTOR RESOLVER for the whole task system — 12 call sites, including
# _gate_withdraw_actor and the objective/task actor paths. Changing it changes WHO THE
# CLI THINKS YOU ARE everywhere, not just on the wire. Measured, when attempted:
# 9 harnesses that pass on main went red, because on this host the caller genuinely IS
# an agent-* user and every one of those paths started resolving an identity where it
# previously resolved none. The envelope gap does not justify moving the actor model,
# so the fallback lives HERE, where its blast radius is the wire format.
#
# $EUID, never `id -un`: `id` resolves through the caller's PATH and is forgeable by an
# agent controlling its own environment (olivia, DIVE-1401 — caught exactly that in an
# earlier cut of this fix). $EUID is a bash builtin; resolution is pure bash over
# /etc/passwd, so no external command is consulted.
#
# NO ENV OVERRIDE for the passwd path, deliberately: this value feeds envelope_tier
# below, so an env-settable source would be a NEW forgery vector in the one field the
# design treats as unforgeable. Tests assert BOTH real branches (agent runner -> label,
# non-agent runner -> empty) rather than mocking either, so nothing is skipped.
#
# NOT FIXED HERE, and not implied to be: $SUDO_USER is a plain env var that nothing
# sanitises below root, so a caller can still choose the name auto_sender_from_sudo
# returns. That is pre-existing, live on main, and means `tier=` is not the
# "unforgeable field" lib/registry.sh claims. It is DIVE-2330's, which owns the same
# vector where it feeds AUTHORIZATION rather than display.
_envelope_sender_fallback() {
  local want="$EUID" name _x uid
  [[ "$want" =~ ^[0-9]+$ ]] || { printf ''; return; }
  while IFS=: read -r name _x uid _; do
    [[ "$uid" == "$want" ]] || continue
    [[ "$name" == agent-* ]] || { printf ''; return; }
    printf '%s' "${name#agent-}"; return
  done < /etc/passwd
  printf ''
}

# DIVE-2281 — WHO the envelope says you are. The PRECEDENCE is the security property,
# so it lives here once instead of being re-composed at each call site.
#
# $EUID FIRST, $SUDO_USER SECOND, and that order is the entire point. Both answer "who
# is calling"; only one is unforgeable BY THE CALLER:
#   * $EUID is a bash builtin reflecting the kernel's view of the process. A caller
#     cannot lie about it without already being that user.
#   * $SUDO_USER is A PLAIN ENVIRONMENT VARIABLE. On the SCOPED path sudo sets it under
#     env_reset, so it is trustworthy THERE. On the DIRECT path nothing sanitises it, so
#     a full-trust agent can simply export it.
#
# The first cut asked SUDO_USER first and fell back to EUID, i.e. it preferred the
# FORGEABLE source over the unforgeable one. MEASURED on this host, real EUID=agent-main
# with SUDO_USER=agent-olivia exported:
#     caller resolved to 'olivia'  ->  envelope would read from=olivia at olivia's tier
# and since this change is what MINTS an envelope on the direct path at all, that
# ordering would have newly created a FORGEABLE envelope where there was previously NO
# envelope — and a reader trusts an envelope more than its absence. Different failure
# from the one being closed, introduced by the fix for it. Caught by dev on review.
#
# THE SCOPED PATH IS INDIFFERENT TO THE ORDER, which is why the swap costs nothing:
# `_deliver` runs as root, EUID=0 resolves to `root` in /etc/passwd, `root` is not
# `agent-*`, so the EUID branch returns empty and SUDO_USER — written by sudo, not by
# the caller — still answers. Measured: EUID=0 + SUDO_USER=agent-main still yields 'main'.
#
# NOT CLOSED: $SUDO_USER remains forgeable wherever it is still consulted, which is now
# only the root/_deliver path where sudo wrote it. DIVE-2330 owns that vector where it
# feeds AUTHORIZATION rather than display.
_envelope_caller() {
  local who
  who="$(_envelope_sender_fallback)"
  [[ -n "$who" ]] || who="$(auto_sender_from_sudo)"
  printf '%s' "$who"
}

# DIVE-2385 — WAKE-THEN-SEND, so deferred work does not depend on the recipient
# being awake at the instant the scheduler fires.
#
# `agent send` needs the target to have a LIVE tmux session. Send to an agent that
# simply is not running and it fails in ~190ms with E_NOT_RUNNING: no queue, no
# retry, no persistence. Survivable when a human is watching a terminal; load-
# bearing when the caller is SYSTEMD.
#
# MEASURED, 2026-07-30 (marketing). An approved blog post was scheduled the
# documented way — a transient unit whose ExecStart was
#   systemd-run --on-calendar=... 5dive agent send marketing '<publish pointer>'
# The timer fired exactly on time at 23:45:02 UTC and the unit died on the spot
# (status=8) because marketing was asleep. Three properties then compounded: the
# message was dropped unqueued and unalarmed; a one-shot .timer is CONSUMED once
# it fires, so there was no second attempt; and the only surviving evidence was a
# .service in `failed` state under /run/systemd/transient/, a path nobody greps.
# The approved post silently did not publish. It was caught 17 minutes later
# because an unrelated cron woke marketing and a same-day guard tripped over the
# uncommitted .mdx — luck, not a mechanism. This is NOT the known
# transient-units-die-on-reboot caveat: the host had been up 7+ weeks. It needs
# nothing to go wrong except the target being asleep at one instant.
#
# WHY OPT-IN AND NOT THE NEW DEFAULT. E_NOT_RUNNING is load-bearing elsewhere
# precisely BECAUSE it is a sub-second failure: _task_need_route_deliver
# (DIVE-2011) polls a detached send's own rc for exactly this shape to decide
# whether a gate handoff was observed to fail, and it can only do that because a
# dead session is decided long before the 45s readiness wait. Waking on every
# send would turn those observed failures into a 30s+ boot wait and then report
# them as delivered — re-manufacturing the DIVE-1968 mis-measurement in the one
# rail that was cleaned up. So the default path keeps its rc and its latency byte
# for byte, and a caller that is scheduling DEFERRED work asks for the wake.
#
# REFUSES on desiredState=stopped. That field is the operator's recorded intent
# (cmd_stop writes it; the supervisor reads it when it decides whether a dead unit
# is a crash or a deliberate stop), so waking past it would let a scheduler
# override a human's explicit stop — and the supervisor would then be entitled to
# stop the agent back, mid-turn. ABSENT is NOT stopped (DIVE-2318: unknown is not
# a negative): an agent that has never been start/stop'd through the CLI carries
# no field at all, which is the common case, so absent wakes.
#
# It never reports a send it did not make: if the unit starts but no session
# appears inside the budget, the caller still gets E_NOT_RUNNING — with the reason
# named, rather than the bare "is the agent running?" that was true but useless to
# a systemd unit.
#
# ONE DEADLINE, NOT TWO STACKED ONES (iteration 2). Waking and then waiting for the
# prompt are two waits on the same send, and a caller sizing a systemd
# TimeoutStartSec should not have to discover that by adding 60 and 45 out of two
# different functions. AGENT_WAKE_BUDGET_SECS is the ONLY number a scheduler needs:
# the wake half spends what it needs (capped at 60 so a hung session-appear cannot
# starve the readiness wait of the 45s it had), records it in AGENT_WAKE_ELAPSED, and
# the readiness wait gets the REMAINDER. A fast wake therefore buys the prompt more
# time rather than throwing it away, and the pair can never exceed the budget.
AGENT_WAKE_BUDGET_SECS="${AGENT_WAKE_BUDGET_SECS:-105}"
AGENT_WAKE_FAIL_REASON=""
AGENT_WAKE_ELAPSED=0
agent_wake_for_send() {
  local name="$1" timeout="${2:-60}"
  AGENT_WAKE_FAIL_REASON=""
  AGENT_WAKE_ELAPSED=0
  local desired
  desired=$(registry_read | jq -r --arg n "$name" '.agents[$n].desiredState // ""' 2>/dev/null) || desired=""
  if [[ "$desired" == "stopped" ]]; then
    AGENT_WAKE_FAIL_REASON="agent '$name' is stopped by operator intent (desiredState=stopped), so --wake will not start it; clear that intent with '5dive agent start $name' if it is stale"
    return 1
  fi
  if ! systemctl start "5dive-agent@${name}.service" >&2; then
    AGENT_WAKE_FAIL_REASON="systemctl start 5dive-agent@${name}.service failed"
    return 1
  fi
  local waited=0
  while (( waited < timeout )); do
    if sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null; then
      AGENT_WAKE_ELAPSED="$waited"
      return 0
    fi
    sleep 1; waited=$((waited+1))
  done
  AGENT_WAKE_ELAPSED="$waited"
  AGENT_WAKE_FAIL_REASON="started 5dive-agent@${name}.service but its tmux session did not appear within ${timeout}s"
  return 1
}

# DIVE-2385 (iteration 2) — ON THE WAKE PATH, READINESS IS FATAL.
#
# The default path's readiness wait is deliberately NON-fatal: on timeout it warns
# and delivers best-effort, because a busy-but-healthy agent that never parks at a
# prompt should still get its message. That is the right trade for a caller who is
# watching a terminal. It is the WRONG trade for the only caller --wake exists for.
#
# THE DEFECT THIS REMOVES, and it was introduced by --wake itself. `wait_agent_input_ready`
# is a tail that cmd_send already had; adding a new ENTRY into that tail silently
# inherited its best-effort contract. agent_wake_for_send returns the instant
# `tmux has-session` succeeds — the EARLIEST moment of a cold boot, long before the
# TUI renders an input prompt. On a cold boot slower than the readiness budget —
# the common cold-boot outcome — the old code warned, fired keystrokes into a
# booting TUI (which its own comment says are dropped and the message lost), and
# then ended at `sent:true`, exit 0. That is strictly WORSE than the incident this
# ticket was filed for: there, the send failed in 190ms and left a unit in `failed`
# state that something could see. A scheduler with no reader needs a truthful rc far
# more than a delivered-maybe keystroke, and the hard rc is precisely what puts the
# transient unit into failed state where it is observable at all.
#
# Gated on `woken` by its caller, so the DEFAULT path keeps its behaviour, its
# warning and its best-effort delivery byte for byte.
#
# THE HOLE THIS DOES NOT CLOSE, named rather than papered over. For a runtime with
# no prompt marker (anything outside _AGENT_PROMPT_DETECTABLE — see
# agent_prompt_detectable) readiness is not slow, it is UNOBSERVABLE: the poll is
# skipped and 0 means "nothing to detect", never "ready". Failing there would refuse
# every delivery that would in fact have worked; passing silently would re-create
# exactly the green-on-a-dropped-message this function exists to remove. So it
# proceeds and SAYS SO — on stderr, and as ready:"unprovable" in the --json payload,
# so a scheduler can tell a proven delivery from an assumed one instead of reading
# one `sent:true` for both.
#
# It computes the remaining deadline ITSELF, from AGENT_WAKE_ELAPSED, rather than
# taking it from the caller. One function owns the budget arithmetic, so there is no
# second place for a plain 45 to reappear and quietly double the worst case back to
# 105+45.
AGENT_WAKE_READY=""
agent_wake_gate_ready() {
  local name="$1"
  local budget=$(( AGENT_WAKE_BUDGET_SECS - AGENT_WAKE_ELAPSED ))
  (( budget > 0 )) || budget=1
  if ! agent_prompt_detectable "$name"; then
    AGENT_WAKE_READY="unprovable"
    step "agent '$name' woke, but this runtime has no detectable input prompt — delivering WITHOUT proof it is ready (reported as ready=unprovable)"
    return 0
  fi
  if ! wait_agent_input_ready "$name" "$budget"; then
    fail "$E_NOT_RUNNING" "woke agent '$name' but its input prompt never rendered within ${budget}s — refusing to type into a booting TUI and report a send that would be lost. --wake budgets ${AGENT_WAKE_BUDGET_SECS}s in total for the wake and this wait; size a scheduler's timeout against that."
  fi
  AGENT_WAKE_READY="proven"
}

cmd_send() {
  local name="" message="" from="" from_set=0 raw=0 wake=0
  local reply_to_chat="" reply_to_msg=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message=*)        message="${1#--message=}" ;;
      --from=*)           from="${1#--from=}"; from_set=1 ;;
      --raw)              raw=1 ;;
      --wake)             wake=1 ;;
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
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent send <name> <text...> | --message=<text> [--from=<sender>] [--raw] [--wake] [--reply-to-chat=<id> [--reply-to-msg=<id>]]"
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
  # DIVE-2385: --wake starts a systemd unit, which a scoped a2a caller cannot do —
  # its whole grant is `/usr/local/bin/5dive agent _deliver *`, and _deliver
  # deliberately carries no lifecycle powers. REFUSE rather than exec into
  # `_deliver` and drop the flag: a silently-ignored --wake is the same lost
  # message the flag exists to prevent, with an exit 0 printed over it. Checked
  # BEFORE the exec for that reason.
  if (( wake )) && a2a_needs_scoped "$name"; then
    fail "$E_PERMISSION" "--wake starts the target's systemd unit and needs admin/root; this caller only holds the scoped a2a delivery grant. Re-run via sudo, or schedule the work as a task row instead."
  fi
  if a2a_needs_scoped "$name"; then
    exec sudo -n /usr/local/bin/5dive agent _deliver "$name" "$message"
  fi

  require_agent "$name"
  local woken=0
  # Reset at entry, like AGENT_WAKE_FAIL_REASON and AGENT_WAKE_ELAPSED do in
  # agent_wake_for_send. Today cmd_send has exactly one in-process caller (main.sh's
  # dispatch), so a stale value cannot be reached — but `ready` is a claim about what
  # this send PROVED, and a claim carried over from a previous call is a false one.
  # That is the defect class this ticket is about; do not leave it to a call-count.
  AGENT_WAKE_READY=""
  if ! sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null; then
    # DIVE-2385: default behaviour is unchanged — same code, same message, same
    # sub-second latency that _task_need_route_deliver's rc poll depends on.
    (( wake )) \
      || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"
    step "agent '$name' is not running — starting it to deliver (--wake)"
    agent_wake_for_send "$name" \
      || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found and --wake could not bring it up: ${AGENT_WAKE_FAIL_REASON}"
    woken=1
  fi

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
      # DIVE-2281: EUID first (see _envelope_caller). Without any derivation here the
      # envelope is skipped entirely and the inject is indistinguishable from a human.
      sender="$(_envelope_caller)"
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
      # spoofable --from label), so it holds even if from= is forged.
      # DIVE-2210: and stamped UNCONDITIONALLY. This is the exact fail-open the
      # ticket is about — `--from=community` with no sudo caller used to render
      # `[5dive-msg from=community id=...]`, byte-identical to a legitimate
      # untiered send, so the forgeable field survived and the unforgeable one
      # silently vanished. Now it reads tier=unknown:no-caller.
      local _caller _tier=""
      # DIVE-2281: same resolver as the sender above, so from= and tier= cannot
      # disagree, and the tier stops reading unknown:no-caller on the direct path.
      _caller="$(_envelope_caller)"
      _tier="$(envelope_tier "$_caller")"
      local header="[5dive-msg from=${sender} id=${msg_id}"
      header+=" tier=${_tier}"
      [[ -n "$reply_to_chat" ]] && header+=" reply-to-chat=${reply_to_chat}"
      [[ -n "$reply_to_msg" ]] && header+=" reply-to-msg=${reply_to_msg}"
      header+="]"
      payload="${header} ${message}"
    fi
  fi

  # Don't fire keystrokes into a still-booting TUI — they'd be dropped and the
  # message lost. Wait for the input prompt to render (fast no-op when already
  # up). On timeout we still send best-effort and warn, rather than hang.
  #
  # DIVE-2385 (iteration 2): the WAKE path takes a different branch, because on it
  # "still booting" is the EXPECTED state rather than a surprise, and its caller is
  # a scheduler that will never read the warning. See agent_wake_gate_ready. The
  # elif keeps the default branch — its condition, its message, its best-effort
  # fallthrough — exactly as it was.
  if (( woken )); then
    agent_wake_gate_ready "$name"
  elif ! wait_agent_input_ready "$name"; then
    step "agent '$name' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
  fi

  local _rc=0
  inject_and_submit "$name" "$payload" || _rc=$?
  if (( _rc == 3 )); then
    fail "$E_AUTH_REQUIRED" "$(_agent_credential_refusal_msg "$name")"
  elif (( _rc != 0 )); then
    step "agent '$name': payload may not have submitted — pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)"
  fi

  # Mirror the outbound into the sender's group chat (best-effort). Gated on a
  # real envelope: a raw/anonymous send has no sender identity to mirror under.
  (( raw )) || mirror_interagent_outbound "$name" "$message"

  # DIVE-2385: `woken` distinguishes "delivered to a live agent" from "started the
  # agent in order to deliver". A scheduled caller that logs this line can tell,
  # after the fact, that its wake was needed — the fact the failed transient unit
  # could not tell anyone.
  #
  # `ready` appears on the WAKE path only, and exists so `sent:true` does not have to
  # carry two different meanings. "proven" = the input prompt was observed before a
  # key was typed. "unprovable" = this runtime has no prompt marker, so the delivery
  # is an assumption. A scheduler that treats those the same is making the exact
  # mistake this ticket is about.
  ok "sent to agent '$name'." \
     '{name:$n, sent:true, bytes:($p|length), woken:($w=="1"), ready:($rd|select(length>0)), from:($s|select(length>0)), msg_id:($i|select(length>0)), reply_to_chat:($rc|select(length>0)), reply_to_msg:($rm|select(length>0))}' \
     --arg n "$name" --arg p "$payload" --arg s "$sender" --arg i "$msg_id" --arg rc "$reply_to_chat" --arg rm "$reply_to_msg" --arg w "$woken" --arg rd "$AGENT_WAKE_READY"
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
  local timeout=120 idle=5 poll=2 buf_lines=2000 allow_unfenced=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message=*)        message="${1#--message=}" ;;
      --from=*)           from="${1#--from=}"; from_set=1 ;;
      --reply-to-chat=*)  reply_to_chat="${1#--reply-to-chat=}" ;;
      --reply-to-msg=*)   reply_to_msg="${1#--reply-to-msg=}" ;;
      --timeout=*)        timeout="${1#--timeout=}" ;;
      --idle-secs=*)      idle="${1#--idle-secs=}" ;;
      --allow-unfenced)   allow_unfenced=1 ;;
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
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent ask <name> <text...> [--from=<sender>] [--reply-to-chat=<id> [--reply-to-msg=<id>]] [--timeout=120] [--idle-secs=5] [--poll-secs=2] [--allow-unfenced]"
  # DIVE-1901: --allow-unfenced re-enables pane scraping, which is the path that
  # has fabricated every bad reply this ticket has caught. It exists for a seat
  # that genuinely cannot follow the reply-format instruction — never for a
  # BALLOT. A council convene must not be able to opt back into a rail that can
  # return furniture as a vote, and "everyone just sets the flag" is the obvious
  # way this fix decays, so the governance path refuses it in code rather than by
  # convention. A seat that cannot fence must surface as a loud capture failure
  # (abstainKind=capture-failed), which convene already records distinguishably
  # from a real abstention.
  if (( allow_unfenced )) && [[ "$from" == council* ]]; then
    fail "$E_VALIDATION" "--allow-unfenced is refused on a council ask: a ballot may never fall back to pane scraping (it is the path that returns furniture as a vote). A seat that cannot fence must record as a CAPTURE FAILURE, not as an abstention."
  fi
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

  # DIVE-1901: snapshot the pane BEFORE injecting. Two uses, both load-bearing:
  # the baseline is the chrome list (everything already on screen is furniture,
  # for whatever TUI this seat runs), and acc_file is where the scrolling
  # transcript gets rebuilt frame by frame because an alternate-screen pane has
  # no scrollback to read back. Both live in a per-ask temp dir so concurrent
  # asks — a convene dispatches ballots in parallel — cannot share state.
  local ask_tmp baseline_file acc_file msg_file
  ask_tmp="$(mktemp -d)" || fail "$E_GENERIC" "ask: could not create a work dir"
  # shellcheck disable=SC2064
  trap "rm -rf '$ask_tmp'" RETURN
  baseline_file="$ask_tmp/baseline"; acc_file="$ask_tmp/acc"; msg_file="$ask_tmp/msg"
  : > "$acc_file"

  # DIVE-1901: ask the seat to FENCE its reply. Scraping a pane is guesswork —
  # every TUI draws status lines ("✻ Worked for 4s"), spinners and footers that a
  # heuristic has to tell apart from an answer, and getting that wrong on a
  # council ballot fabricates a vote. A fence removes the guess: whatever is
  # between the two markers is the reply, in any harness, with no per-TUI
  # signature list. Seats that ignore the instruction fall back to the heuristic
  # window below, so this is strictly additive.
  # The two markers are written ADJACENT here on purpose: the receiving CLI echoes
  # this instruction back, and an echo whose markers have nothing between them is
  # skipped by the extractor instead of being read as an empty reply.
  local ask_message="${message} [reply-format] Put your answer between these two marker lines: <5dive-r:${msg_id}></5dive-r:${msg_id}> — the opening marker alone on one line, your answer next, the closing marker alone on the last line."
  printf '%s' "$ask_message" > "$msg_file"
  sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p 2>/dev/null > "$baseline_file" || : > "$baseline_file"

  if (( use_scoped )); then
    # Inject via the scoped delivery grant, carrying our fresh marker id.
    # _deliver validates the target + running session and builds the provenance
    # header (from=<caller> id=<msg_id> tier=standard). sudo -n = fail-closed.
    # A standard ask is peer-to-peer, so (like send) it carries no --reply-to
    # channel plumbing.
    # DIVE-2137: capture _deliver's stderr instead of letting it vanish. The
    # credential-prompt refusal (E_AUTH_REQUIRED=6) is raised INSIDE _deliver, so
    # a blanket "missing grant?" here would relabel a fail-closed secret guard as
    # a provisioning problem — the caller would go re-provision the agent and
    # resend, straight back into the prompt. Pass rc 6 and its message through.
    local _derr _drc=0
    _derr=$(sudo -n /usr/local/bin/5dive agent _deliver --id="$msg_id" "$name" "$ask_message" 2>&1 >/dev/null) || _drc=$?
    if (( _drc == E_AUTH_REQUIRED )); then
      fail "$E_AUTH_REQUIRED" "${_derr#*: }"
    elif (( _drc != 0 )); then
      fail "$E_GENERIC" "scoped delivery to '$name' failed (missing _deliver grant? re-provision the agent)${_derr:+ — $_derr}"
    fi
  else
    require_agent "$name"
    sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null \
      || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"
    # DIVE-2210: `ask`'s direct-inject path carried NO tier field at all — it was
    # never added when DIVE-1064 stamped `send` and `_deliver`. An envelope with
    # no tier= is exactly the ambiguity this ticket closes, so `ask` now stamps
    # the same field from the same resolver. (The scoped branch above already
    # inherits it: `_deliver` builds that envelope.)
    # DIVE-2281: resolve the caller ONCE, with the same fallback, so from= and tier=
    # describe the same process. Previously this recomputed auto_sender_from_sudo
    # inline, so a direct-path send could show a real from= beside
    # tier=unknown:no-caller — two fields disagreeing about one sender.
    local _dcaller; _dcaller="$(_envelope_caller)"
    local header="[5dive-msg from=${sender} id=${msg_id} tier=$(envelope_tier "$_dcaller")"
    [[ -n "$reply_to_chat" ]] && header+=" reply-to-chat=${reply_to_chat}"
    [[ -n "$reply_to_msg" ]] && header+=" reply-to-msg=${reply_to_msg}"
    header+="]"
    local payload="${header} ${ask_message}"
    # Same boot-race guard as cmd_send: wait for the input prompt before sending
    # so a freshly-(re)started target doesn't silently drop the question.
    if ! wait_agent_input_ready "$name"; then
      step "agent '$name' input prompt not detected after 45s — sending best-effort (may be lost if still booting)"
    fi
    local _rc=0
    inject_and_submit "$name" "$payload" || _rc=$?
    if (( _rc == 3 )); then
      fail "$E_AUTH_REQUIRED" "$(_agent_credential_refusal_msg "$name")"
    elif (( _rc != 0 )); then
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
      # DIVE-1931: _capture now accumulates frames on ITS side of the boundary
      # before slicing, so the marker survives scroll-off here exactly as it does
      # on the direct path — the window it returns is cumulative, not a single
      # point-in-time read. The fold below is kept because folding a superset of
      # what we already hold is idempotent, and it keeps acc_file populated for
      # the timeout diagnostics and the forensic dump.
      slice=$(sudo -n /usr/local/bin/5dive agent _capture "$name" --after-id="$msg_id" --buffer-lines="$buf_lines" 2>/dev/null) || true
      slice=$(_ask_accumulate "$acc_file" <<<"$slice")
      # Already sliced privileged-side, so re-slicing at the marker is off — but
      # the FENCE still runs (it is keyed on the msg id, not on the slice), so a
      # scoped-sudo caller gets the same chrome-proof extraction as everyone else.
      slice=$(_ask_reply_window "$baseline_file" "$msg_file" "$msg_id" 0 "$allow_unfenced" <<<"$slice")
    else
      # DIVE-1901: capture the VISIBLE pane and accumulate across polls.
      #
      # The old read was `capture-pane -S -${buf_lines}` sliced at the marker,
      # and it failed two ways, both measured on a CLAUDE agent (this was never
      # an agy/opencode-only bug — every full-screen TUI is affected):
      #
      #  A. A full-screen TUI runs in tmux's ALTERNATE SCREEN, which has NO
      #     SCROLLBACK. `-S -5000` returns the same ~24 visible lines as no -S
      #     at all, so buf_lines=2000 is INERT: it reports a 2000-line window and
      #     delivers a screenful, with no signal it was clamped. Once the
      #     `id=<msg_id>` echo scrolls off — which any long message does — the
      #     marker is unrecoverable, the slice is empty, and `ask` times out
      #     while the seat HAS answered. Accumulating fixes this: we record the
      #     marker while it is on screen and keep it after it scrolls away, which
      #     is what a human running capture-pane by hand does implicitly.
      #  B. See the chrome subtraction below.
      #
      # Non-alt-screen harnesses (codex) keep real scrollback, so accumulating
      # visible frames is correct for both and needs no per-harness signatures.
      #  B. The idle test used to be "the slice is non-empty and unchanged for
      #     ${idle}s", which a STATIC TUI FOOTER satisfies before the seat has
      #     typed a single character — measured: a short ask returned exit 0 in
      #     9s carrying the usage-limit line, the separators, the empty prompt
      #     and the model footer as though they were the reply. For a council
      #     ballot that does not lose a vote, it FABRICATES one. _ask_reply_window
      #     subtracts the question echo and the pane's own furniture, so a slice
      #     is non-empty only once the SEAT has produced something.
      capture=$(sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -S "-${buf_lines}" 2>/dev/null) || true
      slice=$(_ask_accumulate "$acc_file" <<<"$capture")
      slice=$(_ask_reply_window "$baseline_file" "$msg_file" "$msg_id" 1 "$allow_unfenced" <<<"$slice")
    fi

    if [[ "$slice" != "$prev_slice" ]]; then
      last_change=$now
      prev_slice="$slice"
    fi

    if (( now - start >= timeout )); then
      # DIVE-1901 iteration 2: say WHAT was seen, not just that nothing settled.
      # A timeout with the fence half-written is a different fault from a timeout
      # with no marker at all (seat ignored the format, or never got the message),
      # and the two need different fixes. Guessing between them cost a round trip.
      local diag=""
      if grep -qF "<5dive-r:${msg_id}>" "$acc_file" 2>/dev/null; then
        diag=" — the reply fence was OPENED but never completed, so nothing was returned rather than returning the pane's furniture; the seat may still be writing, or its reply scrolled past between polls (try a smaller --poll-secs)"
      elif grep -qF "id=${msg_id}" "$acc_file" 2>/dev/null; then
        diag=" — the question was DELIVERED (marker seen in the pane) but the seat never emitted the reply fence; it may have ignored or reformatted the [reply-format] instruction"
      else
        diag=" — the question marker was never seen in the pane at all, so this is a DELIVERY failure, not a capture one (check the submit race / input-prompt warning above)"
      fi
      if [[ -n "${FIVE_ASK_DEBUG_DIR:-}" ]] && mkdir -p "$FIVE_ASK_DEBUG_DIR" 2>/dev/null; then
        cp -f "$baseline_file" "${FIVE_ASK_DEBUG_DIR}/${msg_id}.baseline" 2>/dev/null || true
        cp -f "$acc_file"      "${FIVE_ASK_DEBUG_DIR}/${msg_id}.transcript" 2>/dev/null || true
      fi
      fail "$E_TIMEOUT" "no idle reply from '$name' within ${timeout}s (msg_id=${msg_id})${diag}"
    fi
    if [[ -n "$slice" ]] && (( now - last_change >= idle )); then
      reply="$slice"
      break
    fi
  done

  # DIVE-1901 iteration 2: an OPT-IN forensic dump. The live antigravity failure
  # could not be reproduced from a pane dumped minutes later — an alt-screen TUI
  # overwrites, so the frame the extractor actually settled on was already gone,
  # and a sweep of every 24-line window in that 200-line scrollback reproduced
  # nothing. Guessing at the missing frame is how this ticket burned an iteration.
  # With FIVE_ASK_DEBUG_DIR set, the rail keeps exactly what it saw — the
  # baseline, the accumulated transcript, and the slice it returned — so the next
  # occurrence pins itself instead of needing a re-run to reconstruct.
  if [[ -n "${FIVE_ASK_DEBUG_DIR:-}" ]] && mkdir -p "$FIVE_ASK_DEBUG_DIR" 2>/dev/null; then
    cp -f "$baseline_file" "${FIVE_ASK_DEBUG_DIR}/${msg_id}.baseline" 2>/dev/null || true
    cp -f "$acc_file"      "${FIVE_ASK_DEBUG_DIR}/${msg_id}.transcript" 2>/dev/null || true
    printf '%s' "$reply"  > "${FIVE_ASK_DEBUG_DIR}/${msg_id}.reply" 2>/dev/null || true
    step "ask: forensic dump written to ${FIVE_ASK_DEBUG_DIR}/${msg_id}.{baseline,transcript,reply}"
  fi

  if (( JSON_MODE )); then
    # DIVE-1901: the omit-empty key MUST NOT be `k:($v|select(length>0))`. When $v
    # is empty that yields jq's `empty`, which propagates out of the surrounding
    # object construction, so jq prints NOTHING and exits 0 — and `agent ask
    # --json` has no --reply-to-chat on the a2a/council path, so it returned an
    # EMPTY DOCUMENT on every successful ask. `council convene` does
    # JSON.parse(stdout) on that, throws, and catches straight into an ABSTAIN.
    # That is a second, independent cause of the reported "the seat answers, the
    # rail returns nothing" — and it fires even when the capture is perfect.
    # Merging an object that is `{}` when the value is empty omits the key
    # without ever producing `empty`.
    jq -cn --arg n "$name" --arg s "$sender" --arg i "$msg_id" --arg r "$reply" \
      --arg rc "$reply_to_chat" --arg rm "$reply_to_msg" \
      '{ok:true, data:({name:$n, from:$s, msg_id:$i, reply:$r}
        + (if ($rc|length) > 0 then {reply_to_chat:$rc} else {} end)
        + (if ($rm|length) > 0 then {reply_to_msg:$rm} else {} end))}'
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
