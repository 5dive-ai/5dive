# -------- helpers --------

require_root() {
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "must run as root — try: sudo 5dive ${*:-${FIVE_ARGV[*]:-}}"
}

# -------- DIVE-2627: file input for the prose flags --------
#
# Every prose flag in this CLI is argv-only, so the CALLER'S SHELL assembles the
# value BEFORE the CLI is invoked. A backtick inside a double-quoted value is
# executed as command substitution and the text is silently replaced; the command
# still exits 0 and prints OK. The corruption PRECEDES argv, so nothing downstream
# — CLI, receipt, recipient — can detect it. Measured and written up in
# community/wiki/the-payload-is-corrupted-before-the-cli-is-invoked.md (DIVE-2620).
#
# The audit inverted the original priority. `--message=` is the LEAST costly
# member of the class: a mangled message is read once, by one agent. A mangled
# `--result` / `--ask` / `--body` / `--accept` is the PERMANENT record — what a
# verifier grades against, and for `--ask` what a human is paged to read — with
# no reader present at the write to notice the missing words.
#
# The fix is to keep prose OUT of argv: pass a PATH, read the bytes here. This
# COPIES council's `--context-file` precedent (council/cli.mjs, now in the
# 5dive-ai/5dive-council plugin, whose own wrapper writes prose to a temp file
# specifically to keep it out of argv). It is not a new design.
#
# NOT stdin. stdin already carries the auth token (DIVE-880); a second reader on
# that stream is a design problem, not a flag.
#
# The argv forms are NOT removed or deprecated. These are additive siblings.

# Read <path> VERBATIM into the global _PROSE_FILE_VALUE.
#
# A global rather than a printed value ON PURPOSE: `$(cat f)` strips trailing
# newlines, which is precisely the silent mutation this flag exists to stop.
# `read -r -d ''` reads to the first NUL — i.e. to EOF for text — and returns
# NON-ZERO at EOF with the full contents already assigned, so `|| true` here is
# the SUCCESS path, not a swallowed error. -r keeps backslashes literal.
#
# Refuses empty rather than recording it: every caller of this treats empty as
# "flag not given", so a silently-empty file would land the exact same
# indistinguishable-from-correct write the argv form does.
#
# DIVE-4421: `-` means STDIN, so a caller with a heredoc needs no temp file:
#   5dive agent send dev --message-file=- <<'EOF'
# The read is the SAME `read -r -d ''` as the file path below, so the two forms
# cannot drift into eating different bytes. There is no ambiguity to protect
# against: a file literally named `-` is addressable as `./-`, and every other
# flag in this CLI that takes `-` (--telegram-token) already spells it this way.
_read_prose_file() {
  local flag="$1" path="$2"
  _PROSE_FILE_VALUE=""
  [[ -n "$path" ]] || fail "$E_USAGE" "$flag needs a path: ${flag}=<file>"
  if [[ "$path" == "-" ]]; then
    IFS= read -r -d '' _PROSE_FILE_VALUE || true
    [[ -n "$_PROSE_FILE_VALUE" ]] \
      || fail "$E_VALIDATION" "$flag: stdin was empty — refusing to record an empty value (an empty stdin is indistinguishable from the flag never being passed, which is the failure mode this flag exists to remove)"
    return 0
  fi
  [[ -e "$path" ]] || fail "$E_USAGE" "$flag: no such file '$path'"
  [[ -f "$path" || -p "$path" || -c "$path" ]] \
    || fail "$E_USAGE" "$flag: '$path' is not a readable file (regular file, fifo or character device)"
  [[ -r "$path" ]] || fail "$E_PERMISSION" "$flag: cannot read '$path'"
  IFS= read -r -d '' _PROSE_FILE_VALUE < "$path" || true
  [[ -n "$_PROSE_FILE_VALUE" ]] \
    || fail "$E_VALIDATION" "$flag: '$path' is empty — refusing to record an empty value (an empty file is indistinguishable from the flag never being passed, which is the failure mode this flag exists to remove)"
}

# Refuse `--x` and `--x-file` together. They are two answers to the same
# question; picking one silently is how a caller records the one they did not
# mean — the same class of defect as the corruption above, one layer up.
# $1 = the flag being applied now, $2 = the source that already set it (empty if none).
#
# The SAME flag repeated keeps its old last-wins behaviour and is deliberately NOT
# refused. The ticket's rule is "add alongside, do not change the argv forms", and
# `--result=a --result=b` has always taken b; turning that into a hard error would
# be a silent behaviour change shipped inside an additive one, reaching callers
# across the whole fleet that this ticket never looked at. Only the NEW ambiguity —
# inline against file — is refused, and it has no callers yet.
_prose_flag_dupe() {
  [[ "$1" != "$2" ]] || return 0
  [[ -z "$2" ]] \
    || fail "$E_USAGE" "$1 conflicts with $2 — pass the prose exactly once, either inline or from a file."
}

is_known_type() {
  [[ -n "${TYPE_BIN[$1]+x}" ]]
}

# DIVE-5370: names a key pasted through a secret gate may take in tools.sh.
# That file is every agent's BASH_ENV, so `export PATH='<key>'` there breaks the
# next command of every seat on the box (`git: command not found`), and
# `export HTTPS_PROXY='<key>'` or NODE_TLS_REJECT_UNAUTHORIZED takes out (or
# silently weakens) curl, git, gh and npm the same way. Nothing undoes it short
# of a hand edit as root. A denylist kept missing members of that class, so this
# is an ALLOWLIST: a name is accepted only when it is
#   * a credential name: it ends in _KEY, _TOKEN, _SECRET or _PASSWORD (which
#     covers _API_KEY and _ACCESS_TOKEN), or
#   * a tools-catalog variable that does not (cmd_tool.sh's TOOL_ENV; the
#     catalog arm of tests/secret_tools_connector_unit.sh keeps the two in sync)
# and it is refused even then under a prefix some program reads as its own
# (GIT_*, SSH_*, NODE_*, NPM_CONFIG_*, ...) or one each seat gets from its own
# EnvironmentFiles (ANTHROPIC_*/OPENAI_*/TELEGRAM_*/AGENT_*, the pi provider
# keys): those also end in _KEY/_TOKEN, and a shared export would quietly
# override every seat's own value.
# Returns 0 when NAME is refused. A plain connector file is not sourced by bash,
# so the check applies to --connector=tools only.
TOOLS_VAR_CATALOG_EXTRA=(AD_ACCOUNT_ID BITRIX24_WEBHOOK_URL AMOCRM_DOMAIN)
_tools_var_reserved() {
  local n="${1:-}" v
  case "$n" in
    BASH_*|LD_*|LC_*|GIT_*|SSH_*|SUDO_*|XDG_*|DBUS_*|SYSTEMD_*|GCONV_*) return 0 ;;
    NODE_*|NPM_CONFIG_*|PIP_*|SSL_*|CURL_*|REQUESTS_*|JAVA_*|PYTHON*|PERL*|RUBY*) return 0 ;;
    ANTHROPIC_*|CLAUDE_*|OPENAI_*|GEMINI_*|GOOGLE_*|CODEX_*|HERMES_*|OPENCODE_*) return 0 ;;
    AGENT_*|TELEGRAM_*|DISCORD_*|FIVEDIVE_*|BUZZ_*) return 0 ;;
  esac
  # pi's provider keys sit in the shared pi.env and in a seat's auth profile.
  for v in "${PI_PROVIDER_VAR[@]}"; do [[ "$n" == "$v" ]] && return 0; done
  case "$n" in
    ?*_KEY|?*_TOKEN|?*_SECRET|?*_PASSWORD) return 1 ;;
  esac
  for v in "${TOOLS_VAR_CATALOG_EXTRA[@]}"; do [[ "$n" == "$v" ]] && return 1; done
  return 0 # not a credential name: refused
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
    [[ "$c" =~ ^(none|telegram|discord|dashboard|buzz)$ ]] || return 1
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
# DIVE-5133: the lite profile's /account button target. Same shape the
# telegram plugin accepts (liteAccountUrl: https:// or tg://, no whitespace), and
# nothing that could end the .env line or be read back as a second key.
valid_telegram_account_url() {
  (( ${#1} <= 512 )) && [[ "$1" =~ ^(https|tg)://[^[:space:]\"\'\`]+$ ]]
}

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
# Writes var=value to /etc/5dive/connectors/<fname> with mode 640, group
# claude-keys (DIVE-5690: not `claude`, which every standard seat is in).
_write_connector() {
  local fname="$1"
  [[ "$fname" =~ ^[a-zA-Z0-9_-]+\.env$ ]] || { echo "invalid connector filename: $fname" >&2; return 1; }
  local path="${CONNECTORS_DIR}/${fname}"
  cat > "$path"
  chmod 640 "$path"
  chown root "$path"
  secret_file_secure "$path"
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

# -------- DIVE-5430: `caddy validate` with caddy.service's own environment --------
#
# A Caddyfile can read values the unit loads from its EnvironmentFile: a box that
# gets certificates by DNS challenge writes `dns cloudflare {env.CF_API_TOKEN}`
# and keeps the token in /etc/caddy/cf-dns.env. A bare `caddy validate` runs
# without that file, so it fails even on the unmodified Caddyfile (`API token ''
# appears invalid`) and every route this CLI adds is rolled back. These load the
# unit's files first, in a subshell, as KEY=VALUE data: parsed, never sourced.

# caddy_env_files — the EnvironmentFile paths systemd gives caddy.service, one a line.
caddy_env_files() {
  command -v systemctl >/dev/null 2>&1 || return 0
  # `/etc/caddy/cf-dns.env (ignore_errors=no) /other.env (ignore_errors=yes)`
  systemctl show -p EnvironmentFiles --value caddy 2>/dev/null | tr ' ' '\n' | grep '^/' || true
}

# _caddy_env_load <file> — export each KEY=VALUE line, the way systemd reads it.
_caddy_env_load() {
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    export "$k=$v"
  done <"$1"
}

# caddy_validate <caddyfile> [<caddy-bin>] — validate as the running unit would
# see the file. Returns validate's rc; validate's own output is passed through.
caddy_validate() {
  local cf="$1" bin="${2:-caddy}"
  (
    while IFS= read -r f; do
      if [[ -r "$f" ]]; then _caddy_env_load "$f"; fi
    done < <(caddy_env_files)
    "$bin" validate --config "$cf" --adapter caddyfile
  )
}

# caddy_validate_why <output> — the one line of validate's output that says why:
# `Error: …` (older Caddy) or the error log line's msg (2.11 logs it as JSON),
# kept to its last 300 characters, where the cause is.
caddy_validate_why() {
  local why
  why=$(grep -E '^Error:' <<<"$1" | tail -n 1) || why=""
  [[ -n "$why" ]] || why=$(grep -F '"level":"error"' <<<"$1" | tail -n 1 | sed -n 's/.*"msg":"\(\([^"\\]\|\\.\)*\)".*/\1/p') || why=""
  [[ -n "$why" ]] || why=$(grep -v '^[[:space:]]*$' <<<"$1" | tail -n 1) || why=""
  (( ${#why} <= 300 )) || why="…${why: -300}"
  printf '%s' "$why"
}

# DIVE-5664: `--connector=project-<app>` puts one variable into an app's own env
# file, so an agent never receives a key under a made-up tools name and copies it
# into the app by hand (the exact-swallow maps key, 2026-10-06). Any KEY name is
# fine: only that app reads the file, unlike tools.sh, which every seat sources.
# Hardcoded like CONNECTORS_DIR: a caller must not move where a secret lands.
SECRET_PROJECTS_DIR="/home/claude/projects"

# _secret_project_file <connector> — print the env file a project-<app> connector
# writes, or print why not and return 1. Read-only, so `task need` can refuse a
# link whose answer would have nowhere to land. <app> is the connector's own
# charset (no dots or slashes), so it cannot climb out of the projects folder.
# .env.local when it exists (Next.js, Vite), else .env, which every loader reads.
_secret_project_file() {
  local app="${1#project-}" d
  d="${SECRET_PROJECTS_DIR}/${app}"
  if [[ -z "$app" || ! -d "$d" || -L "$d" ]]; then
    printf 'no project folder %s (a real folder, not a link)' "$d"; return 1
  fi
  if [[ "$(stat -c %u "$d" 2>/dev/null)" == 0 ]]; then
    printf '%s is owned by root; a project secret is written as the folder owner' "$d"; return 1
  fi
  if [[ -e "$d/.env.local" || -L "$d/.env.local" ]]; then printf '%s/.env.local' "$d"
  else printf '%s/.env' "$d"; fi
}

# -------- who may read a key on this box (DIVE-5690) --------
#
# Group `claude` is the box's shared WORKSPACE group. Every standard and admin
# seat is in it, because the registry, the a2a ledger, the audit log and the
# shared checkouts are scoped to it. Until DIVE-5690 it was also the group of
# every secret under /etc/5dive. So a standard seat, including a third-party
# pack a customer hires from the marketplace, could `cat` the owner's Anthropic
# login, the OpenRouter key, the box identity (connectord.env: CONNECTORD_TOKEN,
# AUTOMATION_TOKEN) and every other agent's bot token.
#
# The secrets now carry their own group, SECRETS_GROUP (claude-keys):
#   members  the `claude` user and every admin or beyond-admin seat. Both can
#            already run the whole CLI as root, so the group gives them nothing
#            new. Standard and sandboxed seats are never members.
#   files    every regular file directly in the connectors dir except tools.sh,
#            plus connectord.env. Only a file whose group is `claude` is moved;
#            a root:root 600 file is already tighter and is left alone.
#   ACLs     u:claude:r on each moved file that group claude could read. A
#            process running as `claude` (the
#            dashboard's shelld rotating its token, the prod API on our own
#            host) took its groups when it started, and would lose the read
#            until a restart if it relied on the new group alone.
#            u:agent-<x>:r on telegram-<x>.env and discord-<x>.env, so a seat
#            still reads its OWN channel token (the unit hands it that value
#            anyway, through EnvironmentFile).
# profiles every account login, auth-profiles/<p>/combined.env, under the same
#            posture. Its seat readers are exactly the seats whose
#            agents.d/<x>-auth.env links to it (systemd reads it as root either
#            way), and the reconcile re-derives them every tick, so a seat moved
#            to another account loses the read of the old one. agents.d/<x>.env
#            carries only AGENT_* metadata and stays group claude.
# tools.sh stays root:claude 640. It is every seat's BASH_ENV by design
# (DIVE-5366), and a key an agent asks its owner for lands there (DIVE-5370).
#
# What this does NOT take away: the values the agent unit's EnvironmentFile
# lines put in a seat's environment. systemd reads those files as root, so a
# seat on the owner's Anthropic login holds that login in its own environment.
#
# Every writer that used to stamp root:claude on a secret now calls
# secret_file_secure. The reconcile runs on install/upgrade and on every root
# heartbeat tick, because one writer lives outside this repo: 5dive-api's shelld
# rewrites connectord.env as root:claude 640 when it rotates its token.

SECRETS_GROUP="${FIVEDIVE_SECRETS_GROUP:-claude-keys}"

# The workspace group the keys are moving OFF (create_agent_user's seam).
_sp_shared_group()   { printf '%s' "${AGENT_SHARED_GROUP:-claude}"; }
_sp_connectord_env() { printf '%s' "${FIVEDIVE_CONNECTORD_ENV:-/etc/5dive/connectord.env}"; }
_sp_connectors_dir() { printf '%s' "${CONNECTORS_DIR:-${FIVEDIVE_CONNECTOR_DIR:-/etc/5dive/connectors}}"; }
_sp_profiles_dir()   { printf '%s' "${AUTH_PROFILES_DIR:-/var/lib/5dive/auth-profiles}"; }
_sp_env_dir()        { printf '%s' "${ENV_DIR:-/var/lib/5dive/agents.d}"; }

# OS seams. The harness redefines these; nothing on a box does.
_sp_group_exists() { getent group "$1" >/dev/null 2>&1; }
_sp_groupadd()     { groupadd --system "$1" >/dev/null 2>&1; }
_sp_members()      { getent group "$1" 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | sed '/^$/d'; }
_sp_member_add()   { gpasswd -a "$1" "$2" >/dev/null 2>&1; }
_sp_member_del()   { gpasswd -d "$1" "$2" >/dev/null 2>&1; }
_sp_user_exists()  { id -u "$1" >/dev/null 2>&1; }
_sp_file_group()   { stat -c %G "$1" 2>/dev/null; }
_sp_mode()         { stat -c %a "$1" 2>/dev/null; }
_sp_chgrp()        { chgrp "$1" "$2"; }
_sp_chmod()        { chmod "$1" "$2"; }
_sp_setfacl()      { command -v setfacl >/dev/null 2>&1 && setfacl -m "$1" "$2" 2>/dev/null; }
_sp_unsetfacl()    { command -v setfacl >/dev/null 2>&1 && setfacl -x "$1" "$2" 2>/dev/null; }
# The named users on a file's ACL, one per line (not the owner entry).
_sp_acl_users()    { command -v getfacl >/dev/null 2>&1 && getfacl -cp "$1" 2>/dev/null | sed -n 's/^user:\([^:][^:]*\):.*/\1/p'; }

_sp_is_member() { _sp_members "$2" | grep -qxF "$1"; }
_sp_group_readable() { [[ "$1" =~ ^[0-7]+$ ]] && (( (8#$1 & 8#040) )); }

# An account login: <profiles dir>/<p>/combined.env, one level deep.
_sp_is_profile_env() {
  local d; d=$(_sp_profiles_dir)
  [[ "$1" == "$d"/*/combined.env && "${1#"$d"/}" != */*/* ]]
}

# _sp_profile_seats <combined.env> — the seats bound to this login: each
# agents.d/<x>-auth.env that is a symlink to it. Prints <x>, one per line.
_sp_profile_seats() {
  local f="$1" l t
  for l in "$(_sp_env_dir)"/*-auth.env; do
    [[ -L "$l" ]] || continue
    t=$(readlink "$l") || continue
    [[ "$t" == "$f" ]] || [[ "$(readlink -f "$l")" == "$(readlink -f "$f")" ]] || continue
    l="${l##*/}"
    printf '%s\n' "${l%-auth.env}"
  done
}

# _sp_profile_readers_sync <combined.env> — the seat readers of one login are
# exactly its bound seats: add the missing, drop any agent-* that is no longer
# bound. `claude` is secret_file_secure's to keep. Counts changes in SP_ACL.
_sp_profile_readers_sync() {
  local f="$1" want have u
  want=$(_sp_profile_seats "$f" | sed 's/^/agent-/')
  have=$(_sp_acl_users "$f")
  while IFS= read -r u; do
    [[ -n "$u" ]] && _sp_user_exists "$u" || continue
    grep -qxF "$u" <<<"$have" && continue
    _sp_setfacl "u:${u}:r" "$f" && SP_ACL=$(( ${SP_ACL:-0} + 1 ))
  done <<<"$want"
  while IFS= read -r u; do
    # A bare uid is a deleted seat's entry: a new account given that uid
    # would inherit the read, so it goes too.
    [[ "$u" == agent-* || "$u" =~ ^[0-9]+$ ]] || continue
    grep -qxF "$u" <<<"$want" && continue
    _sp_unsetfacl "u:${u}" "$f" && SP_ACL=$(( ${SP_ACL:-0} + 1 ))
  done <<<"$have"
  return 0
}

# The group a secret is written with: SECRETS_GROUP, created on first use. A box
# where it cannot be created keeps the old group, so nobody who reads a key
# today is locked out by a failed groupadd; the next reconcile retries.
secrets_group() {
  if _sp_group_exists "$SECRETS_GROUP" || { _sp_groupadd "$SECRETS_GROUP" && _sp_group_exists "$SECRETS_GROUP"; }; then
    printf '%s' "$SECRETS_GROUP"
  else
    _sp_shared_group
  fi
}

# secret_file_secure <path> — the posture for one secret file: root:SECRETS_GROUP,
# no world bits, readable by `claude`, and by agent-<x> when it is x's own
# channel token, or by the seats bound to it when it is an account login
# (combined.env). Symlinks are never followed (chgrp would act on the target).
# tools.sh is refused here so no caller can lock every seat out of BASH_ENV.
secret_file_secure() {
  local f="$1" g base u mode
  [[ -f "$f" && ! -L "$f" ]] || return 0
  base="${f##*/}"
  [[ "$base" != tools.sh ]] || return 0
  mode=$(_sp_mode "$f") || mode=600
  g=$(secrets_group)
  _sp_chgrp "$g" "$f" || return 1
  _sp_chmod o-rwx "$f" || return 1
  [[ "$g" != "$(_sp_shared_group)" ]] || return 0
  # The ACLs only keep a read that group claude HAD. A 600 root:claude file
  # (a key nobody but root reads) must not gain a reader by being moved.
  _sp_group_readable "$mode" || return 0
  _sp_user_exists claude && _sp_setfacl u:claude:r "$f"
  if _sp_is_profile_env "$f"; then
    _sp_profile_readers_sync "$f"
    return 0
  fi
  if [[ "$base" =~ ^(telegram|discord)-([a-z0-9][a-z0-9_-]*)\.env$ ]]; then
    u="agent-${BASH_REMATCH[2]}"
    _sp_user_exists "$u" && _sp_setfacl "u:${u}:r" "$f"
  fi
  return 0
}

# secrets_member_sync <user> <isolation> — one seat's membership follows its
# tier: admin and beyond-admin are members, everything else is not. Called by
# create_agent_user (so a re-create at a new tier moves it) and the reconcile.
secrets_member_sync() {
  local user="$1" iso="$2" g
  case "$iso" in
    admin|beyond-admin)
      g=$(secrets_group)
      [[ "$g" != "$(_sp_shared_group)" ]] || return 0
      _sp_is_member "$user" "$g" || _sp_member_add "$user" "$g" ;;
    *)
      _sp_group_exists "$SECRETS_GROUP" || return 0
      _sp_is_member "$user" "$SECRETS_GROUP" || return 0
      _sp_member_del "$user" "$SECRETS_GROUP" ;;
  esac
}

# secrets_posture_reconcile [--quiet] [<registry json>] — idempotent, root.
# Prints one summary line unless --quiet; with --quiet it prints only when it
# changed something. Sets SP_MOVED / SP_ADDED / SP_DROPPED for callers.
secrets_posture_reconcile() {
  local quiet=0 reg="" g d f name iso
  [[ "${1:-}" == --quiet ]] && { quiet=1; shift; }
  reg="${1:-}"
  SP_MOVED=0 SP_ADDED=0 SP_DROPPED=0 SP_ACL=0
  g=$(secrets_group)
  if [[ "$g" == "$(_sp_shared_group)" ]]; then
    warn "could not create group ${SECRETS_GROUP}; every seat in group $(_sp_shared_group) can still read this box's keys (DIVE-5690)"
    return 1
  fi

  # Members. The registry decides tier; an unreadable registry removes nobody.
  if _sp_user_exists claude && ! _sp_is_member claude "$g"; then
    _sp_member_add claude "$g" && SP_ADDED=$((SP_ADDED + 1))
  fi
  [[ -n "$reg" ]] || reg=$(registry_read 2>/dev/null) || reg=""
  if [[ -n "$reg" ]]; then
    while IFS=$'\t' read -r name iso; do
      [[ -n "$name" ]] || continue
      _sp_user_exists "agent-${name}" || continue
      if [[ "$iso" == admin || "$iso" == beyond-admin ]]; then
        _sp_is_member "agent-${name}" "$g" && continue
        _sp_member_add "agent-${name}" "$g" && SP_ADDED=$((SP_ADDED + 1))
      else
        _sp_is_member "agent-${name}" "$g" || continue
        _sp_member_del "agent-${name}" "$g" && SP_DROPPED=$((SP_DROPPED + 1))
      fi
    done < <(jq -r '.agents // {} | to_entries[] | [.key, (.value.isolation // "standard")] | @tsv' <<<"$reg" 2>/dev/null)
  fi

  command -v setfacl >/dev/null 2>&1 \
    || (( quiet )) || warn "setfacl is not installed (package acl): a process already running as claude cannot read the moved keys until it restarts (DIVE-5690)"
  # Files. Only what still carries group `claude` moves, so a tick with nothing
  # to do costs one stat per file.
  d=$(_sp_connectors_dir)
  for f in "$d"/* "$(_sp_connectord_env)"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    [[ "$f" != "$d/tools.sh" ]] || continue
    [[ "$(_sp_file_group "$f")" == "$(_sp_shared_group)" ]] || continue
    secret_file_secure "$f" && SP_MOVED=$((SP_MOVED + 1))
  done
  # Account logins. A moved one is re-read every tick: binding a seat to an
  # account, or moving it off one, changes who may read it without touching
  # the file.
  for f in "$(_sp_profiles_dir)"/*/combined.env; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    case "$(_sp_file_group "$f")" in
      "$(_sp_shared_group)") secret_file_secure "$f" && SP_MOVED=$((SP_MOVED + 1)) ;;
      "$g") _sp_group_readable "$(_sp_mode "$f")" && _sp_profile_readers_sync "$f" ;;
    esac
  done

  if (( ! quiet )) || (( SP_MOVED + SP_ADDED + SP_DROPPED + SP_ACL > 0 )); then
    printf 'secrets posture (DIVE-5690): %d file(s) moved to group %s, %d member(s) added, %d dropped, %d login reader(s) changed\n' \
      "$SP_MOVED" "$g" "$SP_ADDED" "$SP_DROPPED" "$SP_ACL"
  fi
  return 0
}

cmd_secrets_posture() {
  require_root "_secrets_posture"
  [[ $# -le 1 && ( $# -eq 0 || "$1" == --quiet ) ]] || fail "$E_USAGE" "usage: 5dive _secrets_posture [--quiet]"
  secrets_posture_reconcile "$@"
}

# box_identity_elevate <verb> [args...] — the box-identity verbs a standard seat
# still runs (partner hire, hire-link) re-run themselves as root through an
# exact-path NOPASSWD grant once connectord.env is closed to the seat. The token
# never reaches the seat. Returns (does nothing) when the seat can read the file,
# when there is no file, when already root, or when sudo does not grant this
# exact command (a sandboxed seat, a seat whose sudoers predate the grant): the
# verb's own refusal then answers as before. `sudo -l` asks first, so a missing
# grant never turns into a password prompt or a bare sudo error.
box_identity_elevate() {
  local f; f=$(_sp_connectord_env)
  (( EUID != 0 )) || return 0
  [[ -e "$f" && ! -r "$f" ]] || return 0
  local -a cmd=(/usr/local/bin/5dive "$@")   # the exact path the grant names
  (( ${JSON_MODE:-0} )) && cmd+=(--json)
  sudo -n -l "${cmd[@]}" >/dev/null 2>&1 || return 0
  exec sudo -n "${cmd[@]}"
}
