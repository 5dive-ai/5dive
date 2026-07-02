# -------- helpers --------

require_root() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "must run as root (try: sudo 5dive $*)"
}

is_known_type() {
  [[ -n "${TYPE_BIN[$1]+x}" ]]
}

valid_name() {
  # Linux user constraints: start with letter, <=16 chars total incl. agent- prefix (32 max)
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,15}$ ]]
}

valid_channel() {
  # Comma-separated list (DIVE-841): "telegram,dashboard" runs both channels
  # on one session. Every entry must be a known channel; empty is invalid.
  [[ -n "$1" ]] || return 1
  local IFS=',' c
  for c in $1; do
    [[ "$c" =~ ^(none|telegram|discord|dashboard)$ ]] || return 1
  done
}

valid_isolation() {
  [[ "$1" =~ ^(admin|standard|sandboxed)$ ]]
}

# Absolute path with no shell-metacharacters or control chars. The value ends
# up in a bash-sourced env file (agents.d/<name>.env), so anything exotic
# could break the parse. Existence is not checked here — the start script
# falls back to DEFAULT_WORKDIR with a warn if the path is missing at launch.
valid_workdir() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

# Sender label embedded in inter-agent message envelopes. Same shape as agent
# names, plus a few literals for non-agent senders (human typing in a TTY,
# scheduled cron, dashboard).
valid_sender_label() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

# 8-hex-char correlation id for inter-agent messages. Stable enough to grep
# scrollback for the receiver's reply window; short enough to type into a
# follow-up `agent send`. /dev/urandom keeps it process-id agnostic so two
# concurrent `agent send` calls can't collide.
gen_msg_id() {
  od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c 8
}

# When --from is omitted, infer it from $SUDO_USER. Agent users follow the
# `agent-<label>` convention, so we strip the prefix. Anything else (a real
# human ssh-ing in as `claude`, a build bot, etc.) returns empty — the caller
# then sends raw text with no envelope, preserving the pre-attribution shape.
auto_sender_from_sudo() {
  local u="${SUDO_USER:-}"
  [[ -n "$u" && "$u" == agent-* ]] || { echo ""; return; }
  echo "${u#agent-}"
}

# Same regex the marketplace plugin validates against. Telegram bot tokens
# are <bot-id>:<40-ish char secret>.
valid_telegram_token() {
  [[ "$1" =~ ^[0-9]{5,}:[A-Za-z0-9_-]{20,}$ ]]
}

# Telegram bot username (for the CoS one-tap deep link / `cos claim --suggested`).
# Telegram requires 5-32 chars, letters/digits/underscores, and a "bot" suffix
# (case-insensitive). We match that so a typo'd username fails before we poll the
# CoS queue for a child that can never appear.
valid_telegram_bot_username() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]{1,28}[Bb][Oo][Tt]$ ]]
}

# Telegram chat/user ids: numeric, optionally negative (for groups/channels).
# Bot API ids are 64-bit signed; cap at 20 chars to fence absurd input.
valid_telegram_chat_id() {
  [[ "$1" =~ ^-?[0-9]{1,20}$ ]]
}

# Comma-separated list of telegram chat/user ids. No spaces — the API arg
# allowlist forbids them anyway, and we don't want to depend on shell IFS.
valid_telegram_chat_id_list() {
  local list="$1" id
  [[ -n "$list" ]] || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    valid_telegram_chat_id "$id" || return 1
  done < <(printf '%s\n' "$list" | tr ',' '\n')
}

# Auth profile names become file/dir names under /var/lib/5dive/auth-profiles
# and also end up as AGENT_AUTH_PROFILE in the systemd env file — keep them
# filename-safe and short.
valid_profile_name() {
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

# Any printable non-space run >=10 chars. We don't pin to a specific provider
# format (Anthropic keys start with sk-ant-, OpenAI with sk-, others vary) —
# the live probe (if configured) is the real validation.
valid_api_key() {
  [[ "$1" =~ ^[[:graph:]]{10,}$ ]]
}

# Model identifier accepted by `agent config set model=`. We don't pin to a
# provider catalogue (codex/grok/gemini/claude all use different families that
# keep changing) — just a conservative charset that's safe to drop verbatim
# into a TOML "double-quoted" value or a JSON string without escaping: letters,
# digits, and ._:/-  (covers gpt-5.4, claude-opus-4-8, gemini-2.0-flash,
# provider/model forms). The CLI it feeds is the real validator.
valid_model() {
  [[ "$1" =~ ^[A-Za-z0-9._:/-]+$ ]]
}

# Short random id for non-TTY device-code sessions. 16 hex chars = 64 bits —
# plenty for a workflow that already requires root-on-host to poll.
gen_session_id() {
  head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Prompt for a secret if stdin is a terminal, otherwise return nonzero so
# callers can error out with a useful message (HTTP/exec path has no TTY).
prompt_secret() {
  local label="$1" out
  if [[ -t 0 ]]; then
    read -r -s -p "$label: " out; echo >&2
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# Inline connector writer — replaces the suid 5dive-write-connector helper.
# Writes var=value to /etc/5dive/connectors/<fname> with mode 640 root:claude.
_write_connector() {
  local fname="$1"
  [[ "$fname" =~ ^[a-zA-Z0-9_-]+\.env$ ]] || { echo "invalid connector filename: $fname" >&2; return 1; }
  local path="${CONNECTORS_DIR}/${fname}"
  cat > "$path"
  chmod 640 "$path"
  chown root:claude "$path"
}

# Write /etc/5dive/connectors/<kind>-<name>.env with correct perms.
write_channel_secret() {
  local kind="$1" name="$2" var="$3" value="$4"
  local fname="${kind}-${name}.env"
  printf '%s=%s\n' "$var" "$value" | _write_connector "$fname"
}

remove_channel_secret() {
  local kind="$1" name="$2"
  rm -f "${CONNECTORS_DIR}/${kind}-${name}.env"
}

