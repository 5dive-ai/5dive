# -------- helpers --------

require_root() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "must run as root — try: sudo 5dive ${*:-${FIVE_ARGV[*]:-}}"
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
  # "none" only makes sense alone — "none,telegram" is a contradiction, so
  # any multi-entry list containing none is rejected (DIVE-856).
  [[ -n "$1" ]] || return 1
  local IFS=',' c
  for c in $1; do
    [[ "$c" =~ ^(none|telegram|discord|dashboard)$ ]] || return 1
    if [[ "$c" == "none" && "$1" != "none" ]]; then return 1; fi
  done
  return 0
}

# True when <channel> appears in the comma-separated channels <list>.
# Every consumer of AGENT_CHANNELS / registry .channels must use this instead
# of an exact string compare — "telegram,dashboard" != "telegram" silently
# broke exact-match sites when lists landed (DIVE-856).
channel_in_list() {
  local needle="$1" IFS=',' c
  for c in $2; do
    [[ "$c" == "$needle" ]] && return 0
  done
  return 1
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


# --- node discovery (DIVE-1869) ---------------------------------------------
# `sudo 5dive council|constitution|memory ...` runs with root's NON-LOGIN PATH, and on a
# 5dive host node lives under the operator's nvm (`~/.nvm/versions/node/<ver>/bin`), not in
# /usr/local/bin. So every sudo-gated node-backed op died on a bare "needs node on PATH"
# that named neither where node is nor how to fix it — and council is sudo-gated by design
# (it seals root-owned records), so this bit EVERY council init/convene run that way.
#
# Locate node ourselves and prepend its dir to PATH. Version-ordered (`sort -V`, LAST wins)
# because an nvm dir holds several releases side by side and a plain glob picks the OLDEST
# — the exact trap DIVE-1882 hit. Returns 1 (no output, no exit) when nothing is found, so
# best-effort callers can degrade quietly and hard callers can `require_node`.
#
# Split out so the version-ordering is unit-testable against a fake nvm tree (the ordering is the
# part that silently rots): echo the NEWEST executable node under <home>/.nvm/versions/node, or
# nothing. `sort -V` + `tail -1` — a plain glob is lexicographic, so v9.9.9 would beat v10.0.0.
_nvm_newest_node() {
  local home="$1" c cand=""
  [[ -d "$home/.nvm/versions/node" ]] || return 1
  while IFS= read -r c; do
    [[ -x "$c" ]] && cand="$c"
  done < <(printf '%s\n' "$home"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V)
  [[ -n "$cand" ]] || return 1
  printf '%s' "$cand"
}

ensure_node_on_path() {
  command -v node >/dev/null 2>&1 && return 0
  local d c cand="" home
  for d in /usr/local/bin /usr/bin /opt/homebrew/bin /snap/bin; do
    [[ -x "$d/node" ]] && { cand="$d"; break; }
  done
  if [[ -z "$cand" ]]; then
    # The sudo caller's own nvm first (that's whose node the operator meant), then the
    # host's primary operator, then root's.
    for home in ${SUDO_USER:+"/home/$SUDO_USER"} /home/claude /root "${HOME:-/root}"; do
      c="$(_nvm_newest_node "$home")" || continue
      [[ -n "$c" ]] && { cand="$(dirname "$c")"; break; }
    done
  fi
  [[ -n "$cand" ]] || return 1
  PATH="$cand:$PATH"; export PATH
  return 0
}

# Hard requirement: locate node or die with the EXACT remediation, never a dead end.
require_node() {
  ensure_node_on_path && return 0
  local what="${1:-this command}"
  fail "$E_NOT_INSTALLED" "$what needs node on PATH and none was found (searched /usr/local/bin, /usr/bin, and ~/.nvm/versions/node for ${SUDO_USER:-root}/claude/root). Under \`sudo\`, root's PATH does not inherit nvm. Fix it with either:
  sudo env PATH=\"\$(dirname \"\$(readlink -f \"\$(command -v node)\")\"):\$PATH\" 5dive <cmd>   # run the inner part as the user who HAS node
  sudo ln -s \"\$(command -v node)\" /usr/local/bin/node                                    # make it permanent for every sudo-gated op"
}

# ======== skill id -> path containment (DIVE-2338, generalised DIVE-2370) ========
# Moved here from cmd_skill.sh because the guard is not verb-local: cmd_pack.sh
# (_install_bundled_skill, the manifest skills[] download) and lib/agent_setup.sh
# (install_default_skill_for_agent) build the same "<install_dir>/<id>" string.
# ONE implementation on purpose — skill_id_traversal_unit T6d asserts there is no
# second copy, and DIVE-2080 is the standing lesson that fixing the visible call
# site is not fixing the class.
# Validate skill id (the directory name that will end up under the per-type
# skills dir, e.g. .claude/skills/<id>). Same character class skills.sh uses.
#
# DIVE-2338 — THE CHARACTER CLASS IS NOT THE CHECK. `^[A-Za-z0-9._-]+$` rejects a
# SLASH, which is what made it look safe, and accepts `.` and `..`, which are the whole
# traversal token. No slash is needed because the CALLER supplies the separator:
# cmd_skill_rm builds `target="$INSTALL_DIR/$SKILL"` and then `rm -rf "$target"`, so
#   SKILL=..  ->  .claude/skills/..  ->  ~/.claude       (settings, creds, projects, memory)
#   SKILL=.   ->  .claude/skills/.   ->  every installed skill
# and the verb is reachable from the dashboard exec tunnel (`skill` is allowlisted in
# 5dive-api routes/agents.ts and `..` passes AGENT_ARG_RE).
#
# `.` is a LEGITIMATE character in a skill id and simultaneously the entire attack, so a
# character-class allowlist cannot separate the two — the predicate that matters is not
# "which characters" but "can the resulting NAME escape its directory". Hence both checks
# below: refusing the two tokens is exact, and refusing any all-dots name covers `...`
# and friends that some resolvers also normalise upward.
#
# This function only decides the NAME. Containment of the resulting PATH is asserted
# separately at the use site (skill_target_within), because a name-level check cannot see
# what the name is later concatenated to. The token refusal alone would be a two-token
# BLOCKLIST — the exact shape this codebase argues against — so it is the belt, and
# skill_target_within is the braces.
valid_skill_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  # No dot-only name: covers "." ".." and any "..." a normaliser might walk up.
  [[ "$1" =~ ^\.+$ ]] && return 1
  return 0
}

# DIVE-2338 — the STRUCTURAL half, and the one that survives a future edit to the regex.
# Re-derive the concatenated path and assert it is still strictly inside the install dir.
# `readlink -m` normalises `..` without requiring the path to exist, so this is decided on
# the resolved location rather than on the spelling of the input.
# skill_target_within <base_dir> <skill_id> -> 0 if <base_dir>/<id> stays under <base_dir>
skill_target_within() {
  local base="$1" id="$2" rbase rtarget
  rbase="$(readlink -m -- "$base")"    || return 1
  rtarget="$(readlink -m -- "$base/$id")" || return 1
  [[ "$rtarget" == "$rbase"/?* ]]
}
