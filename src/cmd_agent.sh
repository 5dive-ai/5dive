
# -------- agent CRUD --------

cmd_list() {
  ensure_state
  local reg
  reg=$(registry_read)
  # Enrich with live systemd state.
  local out
  out=$(echo "$reg" | jq -c '.agents')
  local enriched="{}"
  for name in $(echo "$out" | jq -r 'keys[]' 2>/dev/null); do
    local svc="5dive-agent@${name}"
    local active sub
    active=$(systemctl is-active "$svc" 2>/dev/null || true)
    sub=$(systemctl is-enabled "$svc" 2>/dev/null || true)
    enriched=$(jq -c --arg n "$name" --arg a "$active" --arg e "$sub" \
      '.[$n] = {active: $a, enabled: $e}' <<<"$enriched")
  done
  local merged
  merged=$(jq -c --arg default_wd "$DEFAULT_WORKDIR" --argjson live "$enriched" '.agents | to_entries | map({
    name: .key,
    type: .value.type,
    channels: .value.channels,
    workdir: (.value.workdir // $default_wd),
    authProfile: (.value.authProfile // null),
    botUsername: (.value.botUsername // null),
    isolation: (.value.isolation // "admin"),
    heartbeat: (.value.heartbeat // null),
    createdAt: .value.createdAt,
    active: ($live[.key].active // "unknown"),
    enabled: ($live[.key].enabled // "unknown")
  })' <<<"$reg")
  if (( JSON_MODE )); then
    echo "$merged" | jq -c '{ok:true, data: .}'
  else
    echo "$merged" | jq -r '
      if length == 0 then "no agents" else
        (["NAME","TYPE","CHANNELS","PROFILE","ACTIVE","ENABLED"] | @tsv),
        (.[] | [(.name + (if (.heartbeat.enabled // false) then " ∿" + ((.heartbeat.everyMin // 30)|tostring) + "m" else "" end)), .type, .channels, (.authProfile // "-"), .active, .enabled] | @tsv)
      end' | column -t -s $'\t'
  fi
}

# Resolve the coding-CLI version string for an agent type from its TYPE_BIN
# binary. Best-effort: returns "" if the binary is missing or doesn't answer
# --version in time. Runs as `claude` (owns the binaries + their caches) through
# a login shell so node/nvm-based CLIs (codex) inherit their PATH, capped at 5s
# so a wedged CLI can't hang `info`.
resolve_cli_version() {
  local type="$1"
  local bin="${TYPE_BIN[$type]:-}"
  [[ -n "$bin" ]] || { printf ''; return; }
  timeout 5 sudo -u claude bash -lc "$(printf '%q' "$bin") --version 2>/dev/null | head -1" 2>/dev/null || printf ''
}

# Resolve the model an agent is configured to use, read from the per-type
# runtime config the CLI actually loads (codex/grok TOML, claude/antigravity
# JSON). Best-effort: returns "" when the runtime doesn't persist a model
# (grok/antigravity fall back to the CLI's built-in pick), so callers should
# render "—"/null rather than treat empty as an error.
resolve_agent_model() {
  local type="$1" name="$2"
  local home="/home/agent-${name}"
  case "$type" in
    claude)
      sudo jq -r '.model // empty' "$home/.claude/settings.json" 2>/dev/null ;;
    codex)
      sudo sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*[^"# ])"?.*/\1/p' \
        "$home/.codex/config.toml" 2>/dev/null | head -1 ;;
    grok)
      sudo sed -nE 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*[^"# ])"?.*/\1/p' \
        "$home/.grok/config.toml" 2>/dev/null | head -1 ;;
    antigravity)
      sudo jq -r '.model // .selectedModel // empty' \
        "$home/.gemini/antigravity-cli/settings.json" 2>/dev/null ;;
    *) printf '' ;;
  esac
}

# Write the selected model into the per-type runtime config the CLI loads, so
# `config set model=` is the single uniform path the forks' /model shells out to
# (replacing each plugin's own per-runtime config write). TOML (codex/grok) and
# JSON (claude/antigravity) are handled distinctly:
#   - TOML: split at the first table header; replace an existing top-level
#     `model = ...` in the preamble, else prepend one above the first [table] —
#     so the key stays document-root-level, never binds to a [section] and never
#     duplicates (matches telegram-{codex,grok} writeConfigModel()).
#   - JSON: merge-write the top-level `.model` key, preserving every other key.
# The runtime config must already exist (every provisioned+started agent has
# one) — we refuse to create it, both because a bare new file would drop the
# other required settings and because pre-seeding codex's config.toml would make
# 5dive-agent-start skip its approval_policy/sandbox baseline. Atomic (tmp +
# rename) with the existing owner:group + 600 mode preserved.
write_runtime_model() {
  local type="$1" name="$2" model="$3"
  local home="/home/agent-${name}" file fmt
  case "$type" in
    claude)      file="$home/.claude/settings.json"; fmt=json ;;
    codex)       file="$home/.codex/config.toml";     fmt=toml ;;
    grok)        file="$home/.grok/config.toml";       fmt=toml ;;
    antigravity) file="$home/.gemini/antigravity-cli/settings.json"; fmt=json ;;
    *) fail "$E_VALIDATION" "type '$type' has no model config (can't set model=)" ;;
  esac
  [[ -f "$file" ]] \
    || fail "$E_NOT_FOUND" "no $type runtime config at $file yet — start agent '$name' once before setting model"
  local dir own
  dir=$(dirname "$file")
  own=$(stat -c '%U:%G' "$file")
  local tmp
  tmp=$(mktemp -p "$dir" .model.XXXXXX) || fail "$E_GENERIC" "mktemp failed in $dir"
  if ! MODEL_FMT="$fmt" MODEL_VAL="$model" MODEL_SRC="$file" python3 - "$tmp" <<'PY'
import os, sys, json, re
fmt, val, src, tmp = os.environ["MODEL_FMT"], os.environ["MODEL_VAL"], os.environ["MODEL_SRC"], sys.argv[1]
with open(src) as f: orig = f.read()
if fmt == "json":
    try:
        data = json.loads(orig) if orig.strip() else {}
    except ValueError:
        sys.stderr.write("existing %s is not valid JSON\n" % src); sys.exit(3)
    if not isinstance(data, dict):
        sys.stderr.write("existing %s is not a JSON object\n" % src); sys.exit(3)
    data["model"] = val
    out = json.dumps(data, indent=2) + "\n"
else:  # toml — only ever touch the preamble before the first [table] header
    m = re.search(r'^\s*\[', orig, re.M)
    head = orig if m is None else orig[:m.start()]
    tail = "" if m is None else orig[m.start():]
    line = 'model = "%s"' % val
    if re.search(r'^[ \t]*model[ \t]*=.*$', head, re.M):
        head = re.sub(r'^[ \t]*model[ \t]*=.*$', line, head, count=1, flags=re.M)
    else:
        head = line + "\n" + head
    out = head + tail
with open(tmp, "w") as f: f.write(out)
PY
  then
    rm -f "$tmp"; fail "$E_GENERIC" "failed to write model into $file"
  fi
  chown "$own" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

# Single-agent detail: registry identity/config + live systemd state, plus the
# resolved coding-CLI version and selected model. Added so each fork's /status
# reads one uniform source (cliName/cliVersion/model) instead of shelling each
# runtime's config itself — the version/model live in different files per type
# and the binaries aren't on the agent user's PATH.
cmd_info() {
  ensure_state
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent info <name> [--json]"
  require_agent "$name"

  local reg
  reg=$(registry_read)

  local svc="5dive-agent@${name}"
  local active enabled
  active=$(systemctl is-active "$svc" 2>/dev/null || true)
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null || true)

  local type
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")

  local cli_version model
  cli_version=$(resolve_cli_version "$type")
  model=$(resolve_agent_model "$type" "$name")

  local obj
  obj=$(jq -c \
    --arg n "$name" \
    --arg default_wd "$DEFAULT_WORKDIR" \
    --arg active "${active:-unknown}" \
    --arg enabled "${enabled:-unknown}" \
    --arg cliName "$type" \
    --arg cliVersion "$cli_version" \
    --arg model "$model" \
    '.agents[$n] as $a | {
      name: $n,
      type: $a.type,
      channels: ($a.channels // "none"),
      workdir: ($a.workdir // $default_wd),
      authProfile: ($a.authProfile // null),
      botUsername: ($a.botUsername // null),
      isolation: ($a.isolation // "admin"),
      heartbeat: ($a.heartbeat // null),
      createdAt: $a.createdAt,
      active: $active,
      enabled: $enabled,
      cliName: $cliName,
      cliVersion: (if $cliVersion == "" then null else $cliVersion end),
      model: (if $model == "" then null else $model end)
    }' <<<"$reg")

  if (( JSON_MODE )); then
    jq -cn --argjson d "$obj" '{ok:true, data:$d}'
  else
    jq -r '
      "name:        \(.name)",
      "type:        \(.type)",
      "cli:         \(.cliName) \(.cliVersion // "unknown")",
      "model:       \(.model // "—")",
      "channels:    \(.channels)\(if .botUsername then " (@\(.botUsername))" else "" end)",
      "profile:     \(.authProfile // "-")",
      "workdir:     \(.workdir)",
      "isolation:   \(.isolation)",
      "state:       \(.active) / \(.enabled)",
      "created:     \(.createdAt // "unknown")"
    ' <<<"$obj"
  fi
}

create_agent_user() {
  local name="$1" isolation="${2:-admin}"
  local user="agent-${name}"
  if ! id -u "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user" >/dev/null
  fi
  # Admin/standard join the claude group (shared workspace access); sandboxed stays isolated.
  local groups="systemd-journal"
  [[ "$isolation" != "sandboxed" ]] && groups="claude,systemd-journal"
  usermod -aG "$groups" "$user"
  # Only admin gets full sudo.
  if [[ "$isolation" == "admin" ]]; then
    cat > "/etc/sudoers.d/${user}" <<SUDOERS
${user} ALL=(ALL) NOPASSWD: ALL
SUDOERS
    chmod 440 "/etc/sudoers.d/${user}"
  fi
}

delete_agent_user() {
  local name="$1"
  local user="agent-${name}"
  id -u "$user" &>/dev/null || return 0
  # deluser removes the home dir; skip --remove-home to keep any per-agent
  # state the user may have in their $HOME. Home is minimal anyway since
  # configs live under /home/claude.
  deluser --quiet "$user" 2>/dev/null || true
  rm -f "/etc/sudoers.d/${user}"
}

write_agent_env() {
  local name="$1" type="$2" channels="$3" workdir="${4:-}" profile="${5:-}" isolation="${6:-admin}"
  local env_file="${ENV_DIR}/${name}.env"
  {
    printf 'AGENT_NAME=%s\n' "$name"
    printf 'AGENT_TYPE=%s\n' "$type"
    printf 'AGENT_CHANNELS=%s\n' "$channels"
    [[ -n "$workdir" ]] && printf 'AGENT_WORKDIR=%s\n' "$workdir"
    [[ -n "$profile" ]] && printf 'AGENT_AUTH_PROFILE=%s\n' "$profile"
    printf 'AGENT_ISOLATION=%s\n' "$isolation"
    # New telegram agents flow through our 5dive-plugins fork (bundled
    # hooks, richer slash commands). 5dive-agent-start reads this var to
    # build the runtime --channels arg, defaulting to claude-plugins-official
    # when unset — so existing agents created before this change keep
    # routing to the upstream plugin until manually migrated.
    [[ "$channels" == "telegram" ]] && printf 'AGENT_CHANNEL_MARKETPLACE=5dive-plugins\n'
  } > "$env_file"
  chown root:claude "$env_file"
  chmod 640 "$env_file"
}

# Point /var/lib/5dive/agents.d/<name>-auth.env at the profile's combined.env
# (systemd picks it up via EnvironmentFile=-/var/lib/5dive/agents.d/%i-auth.env).
# Empty <profile> removes the link — agent falls back to the shared
# /etc/5dive/connectors/*.env files, same as before profiles existed.
link_agent_profile() {
  local name="$1" profile="${2:-}"
  local link="${ENV_DIR}/${name}-auth.env"
  rm -f "$link"
  [[ -n "$profile" ]] || return 0
  local target="${AUTH_PROFILES_DIR}/${profile}/combined.env"
  [[ -f "$target" ]] \
    || fail "$E_NOT_FOUND" "auth profile '$profile' not configured — run: sudo 5dive agent auth set <type> --api-key=... --auth-profile=$profile"
  ln -s "$target" "$link"
}

# Write a BYO (bring-your-own) API-key credential for hermes/openclaw into
# the canonical state dir that 5dive-agent-start.sh seeds from at launch.
# Called from cmd_create (--provider=<canonical> --api-key=<key>) and
# cmd_auth_set (same flags, on already-created agents). Runs as the
# `claude` user so the resulting files land owned by claude:claude — the
# agent's start hook re-copies them into agent-<name>'s home with mode 0600.
#
# <type> hermes uses `hermes auth add <provider> --type api-key --api-key`
# which writes ~/.hermes/auth.json with the right base_url auto-resolved
# from hermes' built-in provider catalog. <type> openclaw has no scriptable
# auth-add path (paste-token requires TTY) — write auth-profiles.json
# directly with the {type:"api_key", provider, key} shape. Both binaries
# read what we write at startup; cmd_auth_set restarts every agent bound
# to the profile so the seed loop in 5dive-agent-start.sh picks up the
# new files and bounces the hermes/openclaw gateway daemon.
apply_byo_provider() {
  local type="$1" canonical="$2" api_key="$3" profile="${4:-}"
  valid_byo_provider "$canonical" \
    || fail "$E_VALIDATION" "unknown provider '$canonical' (known: ${!BYO_PROVIDER_LABEL[*]})"
  valid_api_key "$api_key" \
    || fail "$E_VALIDATION" "api key looks wrong (>=10 printable non-space chars)"
  local native
  native=$(resolve_native_provider "$type" "$canonical")
  [[ -n "$native" ]] \
    || fail "$E_VALIDATION" "$type does not support provider '$canonical' (${BYO_PROVIDER_LABEL[$canonical]})"

  case "$type" in
    hermes)   _apply_byo_hermes "$native" "$canonical" "$api_key" "$profile" ;;
    openclaw) _apply_byo_openclaw "$native" "$canonical" "$api_key" "$profile" ;;
    claude)   _apply_byo_claude "$canonical" "$api_key" "$profile" ;;
    *) fail "$E_VALIDATION" "BYO provider not supported for type '$type' (only: hermes, openclaw, claude)" ;;
  esac
}

# Claude (Claude Code) BYO custom-provider path. Unlike hermes/openclaw — which
# write native auth.json/auth-profiles.json — the claude harness reads its
# credentials and endpoint from the environment, so we upsert the override env
# vars into the auth-profile's combined.env. systemd loads that as
# EnvironmentFile=%i-auth.env *after* the shared anthropic.env (last-wins), so
# these override any default-account OAuth token that template otherwise leaks
# in. profile_set_var takes the value on stdin (keeps secrets out of argv).
_apply_byo_claude() {
  local canonical="$1" api_key="$2" profile="${3:-}"
  [[ -n "$profile" ]] \
    || fail "$E_USAGE" "claude BYO provider requires --auth-profile (custom-provider creds are profile-scoped)"
  local base_url="${CLAUDE_PROVIDER_BASEURL[$canonical]:-}"
  [[ -n "$base_url" ]] \
    || fail "$E_VALIDATION" "claude does not support provider '$canonical' (${BYO_PROVIDER_LABEL[$canonical]:-unknown}: no Anthropic-compatible endpoint)"
  step "Configuring claude BYO provider '$canonical' → ${base_url} (profile=$profile)"
  printf '%s' "$base_url"  | profile_set_var "$profile" ANTHROPIC_BASE_URL
  printf '%s' "$api_key"   | profile_set_var "$profile" ANTHROPIC_AUTH_TOKEN
  printf '%s' "${CLAUDE_PROVIDER_OPUS_MODEL[$canonical]}"   | profile_set_var "$profile" ANTHROPIC_DEFAULT_OPUS_MODEL
  printf '%s' "${CLAUDE_PROVIDER_SONNET_MODEL[$canonical]}" | profile_set_var "$profile" ANTHROPIC_DEFAULT_SONNET_MODEL
  printf '%s' "${CLAUDE_PROVIDER_HAIKU_MODEL[$canonical]}"  | profile_set_var "$profile" ANTHROPIC_DEFAULT_HAIKU_MODEL
  # Custom endpoints (esp. z.ai during peak hours) can be slow; raise the
  # client-side request timeout so long tool turns don't get cut off.
  printf '%s' "3000000" | profile_set_var "$profile" API_TIMEOUT_MS
  # Neutralize any shared-account creds the template's unconditional
  # anthropic.env EnvironmentFile= would inject ahead of our override —
  # combined.env loads last so empty values win, forcing the harness onto
  # ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL instead of OAuth-to-Anthropic.
  printf '%s' "" | profile_set_var "$profile" CLAUDE_CODE_OAUTH_TOKEN
  printf '%s' "" | profile_set_var "$profile" ANTHROPIC_API_KEY
}

_apply_byo_hermes() {
  local native="$1" canonical="$2" api_key="$3" profile="${4:-}"
  local bin="${TYPE_BIN[hermes]}"
  [[ -x "$bin" ]] || fail "$E_NOT_INSTALLED" "hermes not installed at $bin"

  # HERMES_HOME is the dir that contains auth.json/config.yaml directly —
  # `profile_type_dir` already returns that for profiled installs, matching
  # the path 5dive-agent-start.sh syncs from. Appending /.hermes here put
  # the credential one dir too deep and the per-agent seed silently no-op'd
  # (left every BYO-key hermes agent stuck on whatever auth was there at
  # create time). Default profile keeps writing to the shared dir.
  local hermes_home="/home/claude/.hermes"
  if [[ -n "$profile" ]]; then
    hermes_home="$(profile_type_dir "$profile" hermes)"
  fi

  # Kimi/Moonshot env-var path: hermes' Kimi provider reads KIMI_API_KEY from
  # ~/.hermes/.env at gateway startup; there is no `hermes auth add moonshot`
  # to populate auth.json. Write the env var into the shared dir (cmd_create
  # mirrors it into the agent-user's .env via seed_hermes_byo_env before the
  # gateway starts) and stamp a minimal auth.json so the cmd_create auth gate
  # (auth_creds_present → `-s ${TYPE_AUTH[hermes]}`) doesn't reject the agent
  # for "no credentials." `{}` is hermes' own pre-login shape.
  if [[ "$canonical" == "moonshot" ]]; then
    step "Writing hermes BYO credential for '$canonical' (KIMI_API_KEY → ${hermes_home}/.env)"
    install -d -m 0775 -o claude -g claude "$hermes_home"
    if ! sudo -u claude -H env HERMES_HOME="$hermes_home" KEY="$api_key" bash -s >&2 <<'KIMI_ENV'
set -euo pipefail
ENV_FILE="$HERMES_HOME/.env"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"
TMP=$(mktemp --tmpdir="$HERMES_HOME" .env.XXXXXX)
chmod 600 "$TMP"
grep -v '^KIMI_API_KEY=' "$ENV_FILE" > "$TMP" || true
printf 'KIMI_API_KEY=%s\n' "$KEY" >> "$TMP"
mv "$TMP" "$ENV_FILE"
AUTH_FILE="$HERMES_HOME/auth.json"
if [[ ! -s "$AUTH_FILE" ]]; then
  printf '{}\n' > "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
fi
KIMI_ENV
    then
      fail "$E_GENERIC" "hermes BYO env write failed for moonshot"
    fi
    # Point hermes at the Kimi provider so first launch doesn't hit the
    # "Hermes isn't configured yet" prompt. Non-fatal: if hermes' CLI rejects
    # the value, the agent can still run (KIMI_API_KEY is in .env) and the
    # user can pick the model via `5dive agent <name> tui`. `kimi` is an
    # alias on the upstream kimi-coding provider — see
    # plugins/model-providers/kimi-coding/__init__.py.
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.provider "$native" >&2 \
      || warn "hermes config set model.provider=$native failed (user can pick the model in TUI)"
    local model="${HERMES_PROVIDER_MODEL[$canonical]:-}"
    if [[ -n "$model" ]]; then
      sudo -u claude -H env HERMES_HOME="$hermes_home" \
        "$bin" config set model.default "$model" >&2 \
        || warn "hermes config set model.default=$model failed"
    fi
    return 0
  fi

  step "Writing hermes BYO credential for '$canonical' (native id: $native)"
  printf '%s' "$api_key" | sudo -u claude -H env HERMES_HOME="$hermes_home" \
    "$bin" auth add "$native" --type api-key --api-key "$api_key" --label "${canonical}-byo" >&2 \
    || fail "$E_GENERIC" "hermes auth add $native failed"
  sudo -u claude -H env HERMES_HOME="$hermes_home" \
    "$bin" config set model.provider "$native" >&2 \
    || warn "hermes config set model.provider=$native failed (rerun: sudo -u claude -H $bin config set model.provider $native)"
  # hermes auto-resolves model.base_url from its provider catalog when
  # model.base_url is unset — explicitly unset it so a stale openai-codex
  # value from a prior oauth login doesn't pin the agent to chatgpt.com.
  sudo -u claude -H env HERMES_HOME="$hermes_home" \
    "$bin" config set model.base_url "" >&2 2>/dev/null || true
  local model="${HERMES_PROVIDER_MODEL[$canonical]:-}"
  if [[ -n "$model" ]]; then
    sudo -u claude -H env HERMES_HOME="$hermes_home" \
      "$bin" config set model.default "$model" >&2 \
      || warn "hermes config set model.default=$model failed"
  fi
}

_apply_byo_openclaw() {
  local native="$1" canonical="$2" api_key="$3" profile="${4:-}"
  local base="/home/claude"
  if [[ -n "$profile" ]]; then
    base="$(profile_type_dir "$profile" openclaw)"
    install -d -m 2750 -o claude -g claude "$base"
  fi
  local oc_dir="${base}/.openclaw/agents/main/agent"
  install -d -m 0750 -o claude -g claude \
    "${base}/.openclaw" \
    "${base}/.openclaw/agents" \
    "${base}/.openclaw/agents/main" \
    "$oc_dir"

  local profile_id="${native}:manual"
  local auth_file="${oc_dir}/auth-profiles.json"
  step "Writing openclaw BYO auth-profiles.json for '$canonical' (native id: $native)"
  local tmp
  tmp=$(mktemp -p "$oc_dir" .auth-profiles.XXXXXX) \
    || fail "$E_GENERIC" "mktemp failed in $oc_dir"
  jq -cn --arg pid "$profile_id" --arg p "$native" --arg k "$api_key" \
    '{version:1, profiles:{($pid):{type:"api_key", provider:$p, key:$k}}}' \
    > "$tmp" \
    || { rm -f "$tmp"; fail "$E_GENERIC" "failed to write $auth_file"; }
  chown claude:claude "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$auth_file"

  # Default model lands in openclaw.json's agents.defaults.model.primary;
  # 5dive-agent-start.sh syncs it from the shared/profile copy into the
  # per-agent openclaw.json on every launch.
  local model="${OPENCLAW_PROVIDER_MODEL[$canonical]:-}"
  if [[ -n "$model" ]]; then
    local openclaw_bin="${TYPE_BIN[openclaw]}"
    sudo -u claude -H env HOME="$base" "$openclaw_bin" \
      config set agents.defaults.model.primary "$model" >&2 \
      || warn "openclaw config set agents.defaults.model.primary=$model failed"
  fi
}

cmd_create() {
  local name="" type="" channels="none" telegram_token="" discord_token="" workdir="" profile=""
  local telegram_home_channel="" telegram_allowed_users=""
  local byo_provider="" byo_api_key=""
  local skills_arg="" skills_set=0 no_skills=0 defer_auth=0
  local isolation="admin"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*)                    type="${1#--type=}" ;;
      --channels=*)                channels="${1#--channels=}" ;;
      --telegram-token=*)          telegram_token="${1#--telegram-token=}" ;;
      --telegram-home-channel=*)   telegram_home_channel="${1#--telegram-home-channel=}" ;;
      --telegram-allowed-users=*)  telegram_allowed_users="${1#--telegram-allowed-users=}" ;;
      --discord-token=*)           discord_token="${1#--discord-token=}" ;;
      --workdir=*)                 workdir="${1#--workdir=}" ;;
      --auth-profile=*)            profile="${1#--auth-profile=}" ;;
      --provider=*)                byo_provider="${1#--provider=}" ;;
      --api-key=*)                 byo_api_key="${1#--api-key=}" ;;
      --with-skills=*)             skills_arg="${1#--with-skills=}"; skills_set=1 ;;
      --no-skills)                 no_skills=1 ;;
      --defer-auth)                defer_auth=1 ;;
      --isolation=*)               isolation="${1#--isolation=}" ;;
      -*)                          fail "$E_USAGE" "unknown flag: $1" ;;
      *)                           [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent create <name> --type=<type> [--channels=none|telegram|discord] [--telegram-token=<token>] [--telegram-home-channel=<id>] [--telegram-allowed-users=<csv>] [--workdir=<path>] [--auth-profile=<name>] [--provider=<id> --api-key=<key|->] [--with-skills=<spec>[,...]] [--no-skills] [--defer-auth] [--isolation=admin|standard|sandboxed]"
  [[ -n "$type" ]] || fail "$E_USAGE" "--type is required"
  valid_name "$name" || fail "$E_VALIDATION" "invalid name (lowercase letters/digits/hyphens, start letter, <=16 chars)"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type (known: ${!TYPE_BIN[*]})"
  valid_channel "$channels" || fail "$E_VALIDATION" "invalid channels: $channels (none|telegram|discord)"
  valid_isolation "$isolation" || fail "$E_VALIDATION" "invalid --isolation (admin|standard|sandboxed)"
  if [[ -n "$workdir" ]]; then
    valid_workdir "$workdir" \
      || fail "$E_VALIDATION" "invalid --workdir (absolute path, allowed chars: letters/digits/._-/)"
  fi
  if [[ -n "$profile" ]]; then
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    if (( defer_auth )) || [[ -n "$byo_provider" ]]; then
      # "Set up later" path: the dashboard binds an auto-derived profile
      # (the slug) at create time before any auth has happened, so the
      # profile dir legitimately doesn't exist yet. Pre-create it now with
      # an empty combined.env so link_agent_profile's symlink target is
      # present (systemd's EnvironmentFile= loads the empty file as a
      # no-op) and the per-type *_HOME redirect (driven by
      # AGENT_AUTH_PROFILE in the unit env file) has a target dir for
      # first-run onboarding to write creds into.
      # Same treatment for the BYO API-key path: the dashboard's "fresh
      # account + paste key" flow names a new profile that doesn't exist
      # yet — apply_byo_provider populates the per-type dir below, and the
      # post-create auth gate accepts that as proof of auth.
      ensure_profile_dir "$profile" >/dev/null
    else
      # Non-defer path keeps the fail-fast check so a typo'd profile
      # name doesn't survive into agent state.
      [[ -f "${AUTH_PROFILES_DIR}/${profile}/combined.env" ]] \
        || fail "$E_NOT_FOUND" "auth profile '$profile' not configured — run: sudo 5dive agent auth set $type --api-key=... --auth-profile=$profile"
    fi
  fi

  if [[ "$channels" != "none" ]] && [[ "${TYPE_CHANNELS[$type]}" != "1" ]]; then
    fail "$E_VALIDATION" "type '$type' does not support channels (only: claude, codex, grok, antigravity, opencode, openclaw, hermes)"
  fi
  # codex + grok + antigravity + opencode ship a telegram bridge only — no discord build yet.
  if [[ ( "$type" == "codex" || "$type" == "grok" || "$type" == "antigravity" || "$type" == "opencode" ) && "$channels" == "discord" ]]; then
    fail "$E_VALIDATION" "type '$type' supports --channels=telegram only (no discord build)"
  fi

  # BYO API-key path for hermes/openclaw (--provider=<canonical> + --api-key=<key|->).
  # Mutually exclusive with --defer-auth: BYO is the alternative to "I'll sign in
  # later", not an add-on. The key sentinel "-" reads from stdin so the value
  # never appears in argv (and thus never in `ps`).
  if [[ -n "$byo_provider" || -n "$byo_api_key" ]]; then
    [[ "$type" == "hermes" || "$type" == "openclaw" || "$type" == "claude" ]] \
      || fail "$E_VALIDATION" "--provider/--api-key only supported for hermes/openclaw/claude (got: $type)"
    # claude BYO points the harness at an Anthropic-compatible third-party
    # endpoint and stores the override env vars in the auth-profile's
    # combined.env — so it requires a profile to scope the creds to this agent
    # (otherwise the override would have to live in the shared default
    # connector and bleed into every other claude agent).
    [[ "$type" == "claude" && -z "$profile" ]] \
      && fail "$E_USAGE" "claude BYO (--provider) requires --auth-profile=<name> (custom-provider creds are profile-scoped)"
    [[ -n "$byo_provider" && -n "$byo_api_key" ]] \
      || fail "$E_USAGE" "--provider and --api-key must be passed together"
    (( defer_auth )) \
      && fail "$E_USAGE" "--defer-auth and --provider/--api-key are mutually exclusive"
    valid_byo_provider "$byo_provider" \
      || fail "$E_VALIDATION" "unknown provider '$byo_provider' (known: ${!BYO_PROVIDER_LABEL[*]})"
    local _native
    _native=$(resolve_native_provider "$type" "$byo_provider")
    [[ -n "$_native" ]] \
      || fail "$E_VALIDATION" "$type does not support provider '$byo_provider'"
    if [[ "$byo_api_key" == "-" ]]; then
      [[ -t 0 ]] && fail "$E_USAGE" "--api-key=- expects the key on stdin, stdin is a TTY"
      byo_api_key=$(cat)
    fi
    valid_api_key "$byo_api_key" \
      || fail "$E_VALIDATION" "api key looks wrong (expected >=10 printable non-space chars)"
  fi

  # Resolve --with-skills. Default policy: when this create call is being made
  # by another agent (SUDO_USER=agent-*), preinstall the 5dive-cli skill so
  # the new agent inherits inter-agent comms knowledge — applies to every
  # supported type, since the skills CLI handles per-type install paths via
  # --agent (see SKILLS_AGENT_ID above). Humans creating from the dashboard
  # get no skills by default — they typically don't need the recursion story
  # and the skill is just context noise. --no-skills opts out of the default;
  # --with-skills="" also opts out.
  local -a skills_specs=()
  if (( no_skills )); then
    :
  elif (( skills_set )); then
    if [[ -n "$skills_arg" ]]; then
      IFS=',' read -r -a skills_specs <<<"$skills_arg"
    fi
  else
    if [[ "${SUDO_USER:-}" == agent-* ]]; then
      skills_specs=("5dive-cli")
    fi
  fi
  # Validate every spec up front so we fail before adduser/registry mutation
  # on bad input. Empty entries (trailing comma) are skipped.
  local -a skills_resolved=()
  local s pair src sk
  for s in "${skills_specs[@]+"${skills_specs[@]}"}"; do
    [[ -z "$s" ]] && continue
    pair=$(parse_skill_spec "$s")
    src="${pair% *}"
    sk="${pair#* }"
    valid_skill_source "$src" \
      || fail "$E_VALIDATION" "invalid --with-skills source in '$s' (expected owner/repo, got '$src')"
    valid_skill_id "$sk" \
      || fail "$E_VALIDATION" "invalid --with-skills id in '$s' (got '$sk')"
    skills_resolved+=("${src}:${sk}")
  done

  # Telegram/Discord need their own bot/app token per agent — two agents can't
  # share a bot (both would call getUpdates and race each other). Require the
  # token at create time so the plugin doesn't spin up with empty creds.
  if [[ "$channels" == "telegram" ]]; then
    if [[ -z "$telegram_token" ]]; then
      telegram_token=$(prompt_secret "Telegram bot token for agent '$name'") \
        || fail "$E_USAGE" "--channels=telegram requires --telegram-token=<token> (or run interactively to be prompted)"
    fi
    valid_telegram_token "$telegram_token" \
      || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
    if [[ -n "$telegram_home_channel" ]]; then
      valid_telegram_chat_id "$telegram_home_channel" \
        || fail "$E_VALIDATION" "invalid --telegram-home-channel (numeric chat id, optionally negative)"
    fi
    if [[ -n "$telegram_allowed_users" ]]; then
      valid_telegram_chat_id_list "$telegram_allowed_users" \
        || fail "$E_VALIDATION" "invalid --telegram-allowed-users (comma-separated numeric ids)"
    fi
  fi
  if [[ "$channels" == "discord" ]]; then
    [[ -n "$discord_token" ]] \
      || fail "$E_USAGE" "--channels=discord requires --discord-token=<token>"
  fi

  ensure_state
  local reg
  reg=$(registry_read)
  if jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null; then
    fail "$E_CONFLICT" "agent '$name' already exists"
  fi

  # Install-on-demand: if the requested CLI isn't on disk, try the recipe.
  if [[ ! -x "${TYPE_BIN[$type]}" ]]; then
    if [[ -n "${TYPE_INSTALL[$type]:-}" ]]; then
      step "$type not installed — installing now"
      # cmd_install emits its own ok/fail; we want install output on stderr
      # (progress) so flip JSON_MODE off for the nested call and restore.
      local prev_json="$JSON_MODE"
      JSON_MODE=0
      cmd_install "$type" >&2
      JSON_MODE="$prev_json"
    else
      fail "$E_NOT_INSTALLED" "$type is not installed and no installer is configured (expected at ${TYPE_BIN[$type]})"
    fi
  fi

  # BYO API-key path: write the credential into the shared (or profile-scoped)
  # state dir before the auth gate runs — auth_status_one then sees the
  # sentinel and lets create proceed without falling back to "needs login".
  # Must come after the install-on-demand block so the agent CLI exists
  # when apply_byo_provider shells out to `hermes auth add`.
  if [[ -n "$byo_provider" ]]; then
    apply_byo_provider "$type" "$byo_provider" "$byo_api_key" "$profile"
  fi

  # Don't create an agent that can't log in. When an auth-profile is named,
  # accept either the profile's combined.env (api-key path / claude OAuth, which
  # promote tokens via profile_set_var) or the per-type credential file written
  # by the device-code flow (codex/hermes/openclaw write only auth.json /
  # auth-profiles.json — combined.env stays empty). Skip the
  # live probe here: a slow API blip shouldn't block `agent create`.
  # --defer-auth bypasses the gate: the caller (typically the dashboard's "Set
  # up later" wizard option) is opting to finish authentication inside the
  # agent's first-run UI on tmux attach.
  if (( defer_auth )); then
    :
  elif [[ -n "$profile" ]]; then
    local _profile_authed=0
    if [[ -s "${AUTH_PROFILES_DIR}/${profile}/combined.env" ]]; then
      _profile_authed=1
    else
      local _profile_auth_path
      _profile_auth_path=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || true
      [[ -n "$_profile_auth_path" && -s "$_profile_auth_path" ]] && _profile_authed=1
    fi
    (( _profile_authed )) \
      || fail "$E_AUTH_REQUIRED" "auth profile '$profile' is empty — run: sudo 5dive agent auth login $type --auth-profile=$profile (or: sudo 5dive agent auth set $type --api-key=... --auth-profile=$profile)"
  else
    local auth
    auth=$(auth_status_one "$type" --no-probe)
    if [[ "$auth" != "ok" ]]; then
      fail "$E_AUTH_REQUIRED" "$type is not authenticated ($auth) — run: sudo 5dive agent auth login $type (or: sudo 5dive agent auth set $type --api-key=<key>)"
    fi
  fi

  step "Creating user agent-${name}"
  create_agent_user "$name" "$isolation"

  if [[ "$isolation" == "sandboxed" ]]; then
    step "Applying sandbox resource limits for agent-${name}"
    local dropin_dir="/etc/systemd/system/5dive-agent@${name}.service.d"
    mkdir -p "$dropin_dir"
    printf '[Service]\nMemoryMax=512M\nCPUQuota=50%%\n' > "${dropin_dir}/isolation.conf"
    chmod 644 "${dropin_dir}/isolation.conf"
  fi

  # claude needs the onboarding preseed + settings the channel user got at
  # provision time — otherwise first run hits the theme picker / trust dialog
  # inside tmux. hermes/openclaw don't read ~/.claude (they have their own
  # state dirs), so preseeding it for them is just dead weight; their first-
  # run prompts are handled by their own CLIs.
  if [[ "$type" == "claude" ]]; then
    step "Preseeding claude config for agent-${name}"
    preseed_claude_agent "$name" "$channels"
  elif [[ "$type" == "antigravity" ]]; then
    # antigravity needs no claude-style ~/.claude preseed (agy reads its own
    # ~/.gemini state). The default-skill seed every other type gets isn't
    # folded into a channel installer for the no-channel case, so run it
    # here unconditionally. When channels=telegram, install_channel_for_agent
    # (routed below) wires the bot token + access.json + notify-user skill on
    # top — the find-skills/5dive-cli seed below is idempotent so the overlap
    # is harmless.
    step "Preseeding antigravity default skills for agent-${name}"
    preseed_antigravity_agent "$name"

    # Seed the agy OAuth token into the agent user's runtime $HOME as root.
    # 5dive-agent-start also seeds at boot, but that path uses the agent's own
    # `sudo -n` to read the 0700 auth-profile dir — which only admin agents have
    # (standard/sandboxed get no NOPASSWD sudoers). Without seeding here a
    # non-admin agy agent boots unauthenticated and sits at the "select login
    # method" screen → the telegram bridge runs but the bot is silent (hit on a
    # customer standard-isolation create 2026-06-02). `agent create` runs as
    # root, so copy the token directly; agy is the only type whose credential is
    # a plain file (codex/grok land env/auth.json the agent can already read).
    local _agy_src _agy_home
    _agy_src=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || true
    if [[ -n "$_agy_src" ]] && [[ -s "$_agy_src" ]]; then
      _agy_home="/home/agent-${name}/.gemini/antigravity-cli"
      install -d -m 700 -o "agent-${name}" -g "agent-${name}" \
        "/home/agent-${name}/.gemini" "$_agy_home"
      if install -m 600 -o "agent-${name}" -g "agent-${name}" \
           "$_agy_src" "${_agy_home}/antigravity-oauth-token"; then
        step "Seeded agy OAuth token into agent-${name} runtime"
      fi
    fi
  fi

  # Channel registration is type-aware (see install_channel_for_agent's
  # comment above): claude installs claude-plugins-official's bun server,
  # openclaw shells out to `openclaw channels add`, hermes writes
  # ~/.hermes/.env. Each runs as agent-${name} so credentials land in that
  # user's home with correct ownership.
  case "$channels" in
    telegram)
      install_channel_for_agent "$type" telegram "$name" "$telegram_token" \
        "$telegram_home_channel" "$telegram_allowed_users" ;;
    discord)
      install_channel_for_agent "$type" discord  "$name" "$discord_token" ;;
  esac

  # Hermes BYO Kimi/Moonshot: KIMI_API_KEY lives in the agent user's
  # ~/.hermes/.env (hermes' Kimi provider reads it directly; there is no
  # `hermes auth add moonshot`). apply_byo_provider stamped it into the
  # shared dir for profile reuse; mirror it into the agent-user's .env here
  # so the gateway (started a few steps below) picks it up at first boot.
  # Runs after install_channel_for_agent so channel-token upserts can't
  # overwrite the KIMI_API_KEY line (they only touch their own var).
  if [[ "$type" == "hermes" && "$byo_provider" == "moonshot" ]]; then
    step "Seeding KIMI_API_KEY into ~/.hermes/.env for agent-${name}"
    seed_hermes_byo_env "$name" KIMI_API_KEY "$byo_api_key"
  fi

  if [[ -n "$telegram_token" ]]; then
    step "Writing telegram bot token (${CONNECTORS_DIR}/telegram-${name}.env)"
    write_channel_secret telegram "$name" TELEGRAM_BOT_TOKEN "$telegram_token"
  fi
  if [[ -n "$discord_token" ]]; then
    step "Writing discord token (${CONNECTORS_DIR}/discord-${name}.env)"
    write_channel_secret discord "$name" DISCORD_BOT_TOKEN "$discord_token"
  fi

  # Sandboxed agents can't access /home/claude/projects (not in claude group).
  # Default their workdir to their own home so the TUI starts somewhere useful.
  if [[ "$isolation" == "sandboxed" && -z "$workdir" ]]; then
    workdir="/home/agent-${name}"
  fi

  step "Writing agent env"
  write_agent_env "$name" "$type" "$channels" "$workdir" "$profile" "$isolation"
  link_agent_profile "$name" "$profile"

  # Resolve bot @username via Telegram getMe so the dashboard's agent list
  # can render a t.me/<bot> deep link without an extra round-trip per row.
  # Best-effort: a network blip here shouldn't fail agent creation — the
  # `agent telegram-info <name>` command can backfill on demand later.
  local bot_username=""
  if [[ "$channels" == "telegram" && -n "$telegram_token" ]]; then
    bot_username=$(fetch_bot_username "$telegram_token" 2>/dev/null) || bot_username=""
  fi

  step "Registering in $REGISTRY"
  jq --arg n "$name" --arg t "$type" --arg c "$channels" --arg w "$workdir" --arg p "$profile" --arg bu "$bot_username" --arg ts "$(date -Iseconds)" --arg iso "$isolation" \
    '.agents[$n] = (
      {type: $t, channels: $c, createdAt: $ts, isolation: $iso}
      + (if $w == "" then {} else {workdir: $w} end)
      + (if $p == "" then {} else {authProfile: $p} end)
      + (if $bu == "" then {} else {botUsername: $bu} end)
    )' <<<"$reg" | registry_write

  # users.sh creates /home/claude/.hermes at 2770, but `hermes auth add
  # openai-codex` (kicked off by `agent auth start hermes` before create)
  # tightens it back to 0700 when writing auth.json. The chmod 0775 in the
  # install recipe only fires on the install path — short-circuited when the
  # binary already exists, and bypassed when auth runs after install. Without
  # group-traverse the systemd unit (which runs as agent-<name> in the claude
  # group) can't reach /home/claude/.hermes/hermes-agent/venv/bin/hermes and
  # crash-loops with `binary not installed`. Repair perms unconditionally
  # right before `systemctl enable --now`, regardless of what tightened them.
  if [[ "$type" == "hermes" ]] && [[ -d /home/claude/.hermes ]]; then
    chmod 0775 /home/claude/.hermes
  fi

  # Hermes onboarding finalization. The chat CLI's first-run check
  # (_has_any_provider_configured) inspects ~/.hermes/config.yaml for an
  # explicit model.provider/base_url. Without those, every fresh hermes
  # invocation hits "It looks like Hermes isn't configured yet -- run:
  # hermes setup" and the tmux loop sits at the prompt forever. Pin the
  # values to what the device-code OAuth flow already wrote into
  # auth.json's credential_pool, so the first launch lands straight in
  # chat. Skipped when --defer-auth is set: the user opted to finish
  # setup interactively on tmux attach, and we don't know which provider
  # they'll pick. Also skipped on the BYO path — apply_byo_provider
  # already wrote model.provider/model.default for the user's chosen
  # vendor; overwriting with openai-codex here would clobber the BYO
  # choice and route the agent at chatgpt.com instead of e.g. Anthropic.
  # The pin only matters when the profile *doesn't* already carry a
  # config.yaml. If it does (BYO write, or a prior device-code login that
  # left one behind), agent-start.sh will content-sync it into the agent's
  # per-user dir — and pinning openai-codex here would land a fresher
  # config.yaml at the per-user path, beating the seed's content-diff and
  # silently routing the agent back to chatgpt.com regardless of what the
  # profile says. Matches the same skip we apply when --provider is on argv.
  local _profile_has_hermes_cfg=0
  if [[ -n "$profile" ]] \
     && [[ -s "${AUTH_PROFILES_DIR}/${profile}/hermes/config.yaml" ]]; then
    _profile_has_hermes_cfg=1
  fi
  if [[ "$type" == "hermes" ]] && (( ! defer_auth )) && [[ -z "$byo_provider" ]] \
     && (( ! _profile_has_hermes_cfg )); then
    step "Pinning hermes model.provider for agent-${name}"
    local hermes_bin="${TYPE_BIN[hermes]}"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.provider openai-codex >&2 \
      || warn "hermes config set model.provider failed — first launch may show setup prompt (rerun: sudo -u agent-${name} -H $hermes_bin config set model.provider openai-codex)"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.base_url https://chatgpt.com/backend-api/codex >&2 \
      || warn "hermes config set model.base_url failed for agent '$name'"
    sudo -u "agent-${name}" -H "$hermes_bin" config set model.default gpt-5.5 >&2 \
      || warn "hermes config set model.default failed for agent '$name'"
  fi

  # For hermes telegram/discord channels, install + start the per-user
  # hermes messaging gateway. Skipped when --defer-auth: no auth means
  # the gateway can't talk to the model. See ensure_hermes_gateway for
  # the underlying systemd-user plumbing.
  if [[ "$type" == "hermes" ]] \
      && [[ "$channels" == "telegram" || "$channels" == "discord" ]] \
      && (( ! defer_auth )); then
    ensure_hermes_gateway "$name"
  fi

  step "Enabling 5dive-agent@${name}.service"
  systemctl daemon-reload
  systemctl enable --now "5dive-agent@${name}.service" >&2

  # Install any preseeded skills. A failed install does NOT roll back the
  # agent — networks flake, the agent itself is fine, and the user can rerun
  # `5dive agent skill <name> add ...` to retry. We toggle JSON_MODE off
  # around cmd_skill_add and redirect its stdout so its own ok envelope
  # doesn't collide with this command's envelope; the failure path runs
  # under set -e because cmd_skill_add calls `fail` which exits — wrap in
  # a subshell so only the subshell exits, then catch the status.
  local installed_skills_json='[]' failed_skills_json='[]'
  if (( ${#skills_resolved[@]} > 0 )); then
    local prev_json="$JSON_MODE"
    JSON_MODE=0
    local entry pair src sk status
    for entry in "${skills_resolved[@]}"; do
      src="${entry%%:*}"
      sk="${entry##*:}"
      status=0
      ( cmd_skill_add "$name" --source="$src" --skill="$sk" ) >/dev/null || status=$?
      if (( status == 0 )); then
        installed_skills_json=$(jq -c --arg s "$src" --arg k "$sk" \
          '. + [{source:$s, skill:$k}]' <<<"$installed_skills_json")
      else
        warn "skill install failed for '$sk' from '$src' (exit $status) — agent is up; rerun: sudo 5dive agent skill $name add --source=$src --skill=$sk"
        failed_skills_json=$(jq -c --arg s "$src" --arg k "$sk" \
          '. + [{source:$s, skill:$k}]' <<<"$failed_skills_json")
      fi
    done
    JSON_MODE="$prev_json"
  fi

  # Wire paperclipai (running as user `claude`) to the new agent's auth so
  # its inner CLI-connection check stops reporting "not logged in" for this
  # type. No-op when the host-default credential location already holds a
  # real file — manual host logins win. Best-effort; never fails the create.
  paperclip_seed_for_type "$type" "$profile" 2>/dev/null || true

  local effective_workdir="${workdir:-$DEFAULT_WORKDIR}"
  ok "agent '$name' (type=$type, channels=$channels${profile:+, profile=$profile}) is running." \
     '{name:$n, type:$t, channels:$c, workdir:$w, authProfile:$p, created:true, skills:{installed:$inst, failed:$fail}}' \
     --arg n "$name" --arg t "$type" --arg c "$channels" --arg w "$effective_workdir" --arg p "${profile:-}" \
     --argjson inst "$installed_skills_json" --argjson fail "$failed_skills_json"
}

cmd_restart() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent restart <name>"
  require_agent "$name"
  systemctl restart "5dive-agent@${name}.service" >&2
  ok "agent '$name' restarted." \
     '{name:$n, action:"restart"}' --arg n "$name"
}

cmd_rm() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent rm <name>"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local rm_profile
  rm_profile=$(jq -r --arg n "$name" '.agents[$n].authProfile // empty' <<<"$reg")
  step "Stopping 5dive-agent@${name}.service"
  systemctl disable --now "5dive-agent@${name}.service" 2>/dev/null || true
  step "Removing systemd env + channel secrets"
  rm -f "${ENV_DIR}/${name}.env" "${ENV_DIR}/${name}-auth.env"
  remove_channel_secret telegram "$name"
  remove_channel_secret discord  "$name"
  step "Deleting user agent-${name}"
  delete_agent_user "$name"
  step "Updating registry"
  jq --arg n "$name" 'del(.agents[$n])' <<<"$reg" | registry_write
  # Drop any paperclip-shared symlinks pointing into this agent's profile
  # and re-seed from another agent of the same type if one remains. Best-
  # effort — never fails the remove.
  [[ -n "$rm_profile" ]] && paperclip_unseed_for_profile "$rm_profile" 2>/dev/null || true
  ok "agent '$name' removed." \
     '{name:$n, removed:true}' --arg n "$name"
}

cmd_config() {
  # Usage: 5dive agent config <name> set <key>=<value> [<key>=<value>...]
  #   keys:
  #     channels                  (none|telegram|discord)
  #     model                     (model id for the agent's CLI — claude/codex/
  #                                grok/antigravity; written into the type's
  #                                runtime config, applied on the deferred restart)
  #     workdir                   (absolute path; tmux cwd on next launch;
  #                                value "default" or "" clears the override)
  #     telegram.token            (bot token for this agent's telegram plugin)
  #     telegram.home-channel     (hermes only — chat id the gateway posts to;
  #                                ignored by claude/openclaw)
  #     telegram.allowed-users    (csv of numeric ids allowed to DM the bot;
  #                                seeds access.json/openclaw.allowFrom/hermes env)
  #     discord.token             (bot/app token for this agent's discord plugin)
  #
  # When channels=<plugin> is being set (or a <plugin>.token is being rotated),
  # the matching install_channel_for_agent dispatch is also re-run so each
  # agent type's native state (claude access.json + plugin install, openclaw
  # channels add + allowFrom, hermes ~/.hermes/.env) lands in step with the
  # registry — same plumbing cmd_create uses, kept on a single code path.
  local name="${1:-}" verb="${2:-}"
  [[ -n "$name" && -n "$verb" ]] \
    || fail "$E_USAGE" "usage: 5dive agent config <name> set <key>=<value> [...]"
  shift 2
  [[ "$verb" == "set" ]] || fail "$E_USAGE" "only 'set' is supported"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local type
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  # env_dirty marks that we need to rewrite agents.d/<name>.env from the
  # post-update registry at the end — channels/workdir/auth-profile all live there.
  local env_dirty=0
  # profile_dirty marks that the auth symlink needs to be re-pointed.
  local profile_dirty=0
  # Channel-attach state collected from this set call. We defer the actual
  # install_channel_for_agent dispatch until after the loop so all related
  # keys (channels= and <plugin>.{token,home-channel,allowed-users}) can be
  # applied together — order in argv shouldn't matter.
  local channels_changed_to=""    # value of channels= in this call (if any)
  local new_telegram_token=""
  local new_discord_token=""
  local new_home_channel=""
  local new_allowed_users=""
  local new_model=""
  # applied_keys: names of keys that were actually changed, for the JSON payload.
  local -a applied_keys=()
  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    case "$k" in
      channels)
        valid_channel "$v" || fail "$E_VALIDATION" "invalid channels: $v"
        if [[ "$v" != "none" ]] && [[ "${TYPE_CHANNELS[$type]}" != "1" ]]; then
          fail "$E_VALIDATION" "type '$type' does not support channels"
        fi
        reg=$(jq --arg n "$name" --arg v "$v" '.agents[$n].channels = $v' <<<"$reg")
        channels_changed_to="$v"
        env_dirty=1
        applied_keys+=("channels")
        ;;
      workdir)
        if [[ -z "$v" || "$v" == "default" ]]; then
          reg=$(jq --arg n "$name" 'del(.agents[$n].workdir)' <<<"$reg")
        else
          valid_workdir "$v" \
            || fail "$E_VALIDATION" "invalid workdir (absolute path, allowed chars: letters/digits/._-/)"
          reg=$(jq --arg n "$name" --arg v "$v" '.agents[$n].workdir = $v' <<<"$reg")
        fi
        env_dirty=1
        applied_keys+=("workdir")
        ;;
      telegram.token)
        [[ "${TYPE_CHANNELS[$type]}" == "1" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support telegram channels"
        valid_telegram_token "$v" \
          || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
        new_telegram_token="$v"
        applied_keys+=("telegram.token")
        ;;
      discord.token)
        [[ "${TYPE_CHANNELS[$type]}" == "1" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support discord channels"
        [[ -n "$v" ]] || fail "$E_VALIDATION" "discord.token cannot be empty"
        new_discord_token="$v"
        applied_keys+=("discord.token")
        ;;
      telegram.home-channel)
        [[ "${TYPE_CHANNELS[$type]}" == "1" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support telegram channels"
        valid_telegram_chat_id "$v" \
          || fail "$E_VALIDATION" "telegram.home-channel must be a numeric chat id"
        new_home_channel="$v"
        applied_keys+=("telegram.home-channel")
        ;;
      telegram.allowed-users)
        [[ "${TYPE_CHANNELS[$type]}" == "1" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support telegram channels"
        valid_telegram_chat_id_list "$v" \
          || fail "$E_VALIDATION" "telegram.allowed-users must be a comma-separated list of numeric ids"
        new_allowed_users="$v"
        applied_keys+=("telegram.allowed-users")
        ;;
      model)
        # Uniform model switch — writes the selected model into the type's
        # runtime config (see write_runtime_model). Applied below, picked up by
        # the deferred restart at the end of this function. Not stored in the
        # registry: `agent info` reads the live file so a model changed via the
        # native CLI directly stays the source of truth.
        [[ -n "$v" ]] || fail "$E_VALIDATION" "model cannot be empty"
        valid_model "$v" \
          || fail "$E_VALIDATION" "invalid model '$v' (allowed chars: letters/digits/._:/-)"
        case "$type" in
          claude|codex|grok|antigravity) ;;
          *) fail "$E_VALIDATION" "type '$type' does not support 'model' config" ;;
        esac
        new_model="$v"
        applied_keys+=("model")
        ;;
      auth-profile|auth.profile)
        if [[ -z "$v" || "$v" == "default" ]]; then
          reg=$(jq --arg n "$name" 'del(.agents[$n].authProfile)' <<<"$reg")
        else
          valid_profile_name "$v" \
            || fail "$E_VALIDATION" "invalid auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
          [[ -f "${AUTH_PROFILES_DIR}/${v}/combined.env" ]] \
            || fail "$E_NOT_FOUND" "auth profile '$v' not configured — run: sudo 5dive agent auth set $type --api-key=... --auth-profile=$v"
          reg=$(jq --arg n "$name" --arg v "$v" '.agents[$n].authProfile = $v' <<<"$reg")
        fi
        env_dirty=1
        profile_dirty=1
        applied_keys+=("auth-profile")
        ;;
      *) fail "$E_USAGE" "unknown config key: $k" ;;
    esac
  done
  # Pre-flight: setting channels=<plugin> without a token in the same call
  # only works if the connector secret is already on disk (e.g. rotating
  # the allowlist without touching the token). Otherwise the gateway boots
  # without credentials and silently goes deaf — better to fail loudly here.
  if [[ -n "$channels_changed_to" && "$channels_changed_to" != "none" ]]; then
    case "$channels_changed_to" in
      telegram)
        if [[ -z "$new_telegram_token" && ! -s "${CONNECTORS_DIR}/telegram-${name}.env" ]]; then
          fail "$E_VALIDATION" \
            "channels=telegram needs telegram.token=<token> in the same set call"
        fi
        ;;
      discord)
        if [[ -z "$new_discord_token" && ! -s "${CONNECTORS_DIR}/discord-${name}.env" ]]; then
          fail "$E_VALIDATION" \
            "channels=discord needs discord.token=<token> in the same set call"
        fi
        ;;
    esac
  fi
  echo "$reg" | registry_write
  if (( env_dirty )); then
    step "Rewriting ${ENV_DIR}/${name}.env"
    local new_channels new_workdir new_profile
    new_channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
    new_workdir=$(jq -r --arg n "$name" '.agents[$n].workdir // empty' <<<"$reg")
    new_profile=$(jq -r --arg n "$name" '.agents[$n].authProfile // empty' <<<"$reg")
    write_agent_env "$name" "$type" "$new_channels" "$new_workdir" "$new_profile"
    if (( profile_dirty )); then
      step "Re-pointing ${ENV_DIR}/${name}-auth.env"
      link_agent_profile "$name" "$new_profile"
    fi
  fi
  # Channel attach / rotate: when this call touched telegram.* or discord.*
  # we need to push the new values into each type's native state dir, the
  # same way cmd_create does. install_channel_for_agent routes to the right
  # helper (install_channel_plugin_for_agent for claude — installs the
  # plugin if missing + seeds access.json with allowed_users; openclaw
  # channels add for openclaw; ~/.hermes/.env write for hermes).
  local effective_channels
  effective_channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
  if [[ -n "$new_telegram_token" ]] || \
     ( [[ "$channels_changed_to" == "telegram" ]] && [[ -n "$new_allowed_users$new_home_channel" ]] ); then
    [[ "$effective_channels" == "telegram" ]] \
      || fail "$E_VALIDATION" "telegram.* keys require channels=telegram (current: $effective_channels)"
    local token_for_install="$new_telegram_token"
    if [[ -z "$token_for_install" ]]; then
      # Token wasn't part of this call — pull the one already on disk so
      # the install helper still has something to register/seed. Falls
      # through to the connector-secret file written on the prior call.
      token_for_install=$(grep -E '^TELEGRAM_BOT_TOKEN=' "${CONNECTORS_DIR}/telegram-${name}.env" 2>/dev/null \
        | head -1 | cut -d= -f2-)
      [[ -n "$token_for_install" ]] \
        || fail "$E_NOT_FOUND" "no stored telegram token for agent '$name' — include telegram.token=<token>"
    fi
    if [[ -n "$new_telegram_token" ]]; then
      step "Writing ${CONNECTORS_DIR}/telegram-${name}.env"
      write_channel_secret telegram "$name" TELEGRAM_BOT_TOKEN "$new_telegram_token"
    fi
    step "Installing telegram channel for agent '$name' (type=$type)"
    install_channel_for_agent "$type" telegram "$name" \
      "$token_for_install" "$new_home_channel" "$new_allowed_users"
    # Hermes' messaging gateway is a separate user systemd unit from the
    # tmux loop. cmd_create wires it up only when channels=telegram|discord
    # at create time; attaching a channel post-create (channels was "none")
    # leaves the unit uninstalled, so the agent-start.sh `gateway restart`
    # at the end of this function would warn-and-skip. Install + start it
    # here (idempotent — safe if cmd_create already did it for a token
    # rotation). openclaw handles its own gateway state inside
    # install_channel_for_openclaw_agent, so no parallel hook there.
    if [[ "$type" == "hermes" ]]; then
      ensure_hermes_gateway "$name"
    fi
    # Cache the bot @handle in the registry so the dashboard's agents list
    # can render the t.me/<bot> deep link without an extra getMe roundtrip
    # (mirrors cmd_create's post-install backfill — best-effort, a network
    # blip shouldn't fail config). cmd_config already runs under the
    # registry lock so a direct in-place update is safe.
    local bu
    if bu=$(fetch_bot_username "$token_for_install" 2>/dev/null) && [[ -n "$bu" ]]; then
      reg=$(registry_read)
      jq --arg n "$name" --arg u "$bu" \
        '.agents[$n].botUsername = $u' <<<"$reg" | registry_write
    fi
  fi
  if [[ -n "$new_discord_token" ]]; then
    [[ "$effective_channels" == "discord" ]] \
      || fail "$E_VALIDATION" "discord.token requires channels=discord (current: $effective_channels)"
    step "Writing ${CONNECTORS_DIR}/discord-${name}.env"
    write_channel_secret discord "$name" DISCORD_BOT_TOKEN "$new_discord_token"
    step "Installing discord channel for agent '$name' (type=$type)"
    install_channel_for_agent "$type" discord "$name" \
      "$new_discord_token" "$new_home_channel" "$new_allowed_users"
    if [[ "$type" == "hermes" ]]; then
      ensure_hermes_gateway "$name"
    fi
  fi
  if [[ -n "$new_model" ]]; then
    step "Writing model=$new_model into $type runtime config"
    write_runtime_model "$type" "$name" "$new_model"
  fi
  # Defer the restart so the calling process (often `sudo -n 5dive agent
  # set-account` invoked from inside the agent's own bot) gets to return
  # before its service is torn down. An immediate `systemctl restart` here
  # SIGTERMs our own sudo subprocess → caller sees a spurious failure even
  # though the config write committed. systemd-run --on-active=1 --collect
  # fires the restart ~1s later as a transient unit that survives our exit.
  step "Restarting agent to apply (deferred ~1s)"
  systemd-run --on-active=1 --collect \
    /bin/systemctl restart "5dive-agent@${name}.service" >&2
  local applied_json
  applied_json=$(printf '%s\n' "${applied_keys[@]+"${applied_keys[@]}"}" | jq -R . | jq -cs '. | map(select(length > 0))')
  ok "config applied." \
     '{name:$n, applied:$a}' \
     --arg n "$name" --argjson a "$applied_json"
}

# Attach the invoker's terminal to the agent's tmux session. The systemd unit
# runs tmux as user `agent-<name>`, so we sudo into that user to reach the
# right server socket. exec hands the TTY off for the whole attach — --json is
# a no-op here.
cmd_tui() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent <name> tui"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  exec sudo -u "agent-${name}" tmux attach -t "agent-${name}"
}

cmd_types() {
  local arr="[]"
  for type in "${!TYPE_BIN[@]}"; do
    local bin="${TYPE_BIN[$type]}"
    local installed=false
    [[ -x "$bin" ]] && installed=true
    local channels=false
    [[ "${TYPE_CHANNELS[$type]}" == "1" ]] && channels=true
    arr=$(jq -c \
      --arg n "$type" --arg b "$bin" \
      --argjson i "$installed" --argjson c "$channels" \
      '. + [{name:$n, bin:$b, installed:$i, channels:$c}]' <<<"$arr")
  done
  if (( JSON_MODE )); then
    jq -c '{ok:true, data: .}' <<<"$arr"
  else
    jq -r '.[] | "\(.name) bin=\(.bin) installed=\(if .installed then "ok" else "missing" end) channels=\(if .channels then "yes" else "no" end)"' <<<"$arr" | sort
  fi
}

# Single getUpdates long-poll round against a Telegram bot token. Returns
# JSON `{found:bool, userId, chatId, username, firstName}` on stdout — the
# dashboard wraps this in a re-call loop so it can show a "send /start to
# your bot" UI and react the moment the user does. Each call clears any
# webhook first (getUpdates is incompatible with a registered webhook), then
# blocks for up to <poll_secs> waiting for an update. <poll_secs> is capped
# below the upstream exec timeout so the HTTP layer doesn't kill the call
# mid-poll. Pure curl + jq — no extra deps.
cmd_telegram_discover() {
  local token="" agent="" poll_secs=50
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token=*)      token="${1#--token=}" ;;
      --agent=*)      agent="${1#--agent=}" ;;
      --poll-secs=*)  poll_secs="${1#--poll-secs=}" ;;
      -*)             fail "$E_USAGE" "unknown flag: $1" ;;
      *)              fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  # --agent=<name>: lookup the bot token from the agent's telegram connector
  # env file. Lets the dashboard discover-for-this-agent without having to
  # round-trip the token through the browser.
  if [[ -n "$agent" ]]; then
    [[ -z "$token" ]] \
      || fail "$E_USAGE" "--agent and --token are mutually exclusive"
    local env_file="${CONNECTORS_DIR}/telegram-${agent}.env"
    [[ -r "$env_file" ]] \
      || fail "$E_NOT_FOUND" "no telegram connector for agent '$agent' (looked at $env_file)"
    token=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$env_file" 2>/dev/null \
            | head -1 | cut -d= -f2-)
    [[ -n "$token" ]] \
      || fail "$E_NOT_FOUND" "no TELEGRAM_BOT_TOKEN in $env_file"
  fi
  [[ -n "$token" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-discover {--token=<bot-token>|--agent=<name>} [--poll-secs=N]"
  valid_telegram_token "$token" \
    || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
  [[ "$poll_secs" =~ ^[0-9]+$ ]] && (( poll_secs >= 1 && poll_secs <= 90 )) \
    || fail "$E_VALIDATION" "--poll-secs must be 1..90"

  # deleteWebhook + drop_pending_updates clears any existing webhook AND
  # discards stale updates so the first message we surface is one the user
  # actually just sent (not one queued from a prior session). Best-effort —
  # if Telegram returns non-200 we still try getUpdates; the caller will
  # just see found:false and re-poll.
  curl -sS -m 10 -o /dev/null \
    --data-urlencode "drop_pending_updates=true" \
    "https://api.telegram.org/bot${token}/deleteWebhook" || true

  # Long-poll. timeout=N tells Telegram to hold the connection open for up
  # to N seconds waiting for an update, returning earlier if one arrives.
  # curl's max-time is set just above so the socket survives the wait.
  local resp
  resp=$(curl -sS -m "$((poll_secs + 5))" \
    --data-urlencode "timeout=${poll_secs}" \
    --data-urlencode "limit=1" \
    --data-urlencode "allowed_updates=[\"message\"]" \
    "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null || true)

  # Empty / non-JSON response → treat as no message yet (dashboard re-polls).
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    ok "" '{found:false}'
    return
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    fail "$E_GENERIC" "telegram: $desc"
  fi
  local count
  count=$(jq -r '.result | length' <<<"$resp")
  if [[ "$count" == "0" ]]; then
    ok "" '{found:false}'
    return
  fi

  # Pull the message's `from` (user) + `chat`. For private DMs they're the
  # same numeric id, but allowing them to differ keeps groups working too.
  local user_id chat_id username first_name
  user_id=$(jq -r '.result[0].message.from.id // empty' <<<"$resp")
  chat_id=$(jq -r '.result[0].message.chat.id // empty' <<<"$resp")
  username=$(jq -r '.result[0].message.from.username // empty' <<<"$resp")
  first_name=$(jq -r '.result[0].message.from.first_name // empty' <<<"$resp")
  [[ -n "$user_id" && -n "$chat_id" ]] \
    || fail "$E_GENERIC" "telegram update missing from.id or chat.id"

  ok "discovered chat $chat_id (user $user_id)" \
     '{found:true, userId:$u, chatId:$c, username:$un, firstName:$fn}' \
     --arg u "$user_id" --arg c "$chat_id" --arg un "$username" --arg fn "$first_name"
}

# Token -> bot username via Telegram getMe. Returns username on stdout (exit 0)
# or empty (exit 1) on any failure (network, malformed response, missing
# username). Used by cmd_create and cmd_telegram_info to backfill the cached
# username in the registry; failures are non-fatal — callers degrade to
# "telegram" text without the @handle link.
fetch_bot_username() {
  local token="$1"
  local resp
  resp=$(curl -sS -m 10 \
    "https://api.telegram.org/bot${token}/getMe" 2>/dev/null) || return 1
  jq -e . >/dev/null 2>&1 <<<"$resp" || return 1
  [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == "true" ]] || return 1
  local username
  username=$(jq -r '.result.username // empty' <<<"$resp")
  [[ -n "$username" ]] || return 1
  echo "$username"
}

# Fast bot-identity lookup. The dashboard fires this once when the user
# reaches the "discovering chat" step so the "open Telegram and send /start"
# instruction can render a t.me/<botusername> deep link rather than a plain
# text mention. Token never leaves the server.
cmd_telegram_getme() {
  local token=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token=*) token="${1#--token=}" ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$token" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-getme --token=<bot-token>"
  valid_telegram_token "$token" \
    || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"

  local resp
  resp=$(curl -sS -m 10 \
    "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true)

  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    fail "$E_GENERIC" "telegram api unreachable"
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    fail "$E_GENERIC" "telegram: $desc"
  fi

  local bot_id username first_name
  bot_id=$(jq -r '.result.id // empty' <<<"$resp")
  username=$(jq -r '.result.username // empty' <<<"$resp")
  first_name=$(jq -r '.result.first_name // empty' <<<"$resp")
  [[ -n "$username" ]] \
    || fail "$E_GENERIC" "telegram getMe missing username"

  ok "bot @$username" \
     '{botId:$id, username:$un, firstName:$fn}' \
     --arg id "$bot_id" --arg un "$username" --arg fn "$first_name"
}

# Name-based bot identity lookup. Reads the agent's stored telegram token
# server-side (so the dashboard never sees raw bot tokens), calls getMe,
# and caches the result under .agents.<name>.botUsername in the registry.
# Subsequent calls hit the cache and return without touching Telegram. Used
# by the dashboard's agents page to backfill @handles for agents created
# before botUsername-on-create was wired up. --refresh forces a re-fetch.
cmd_telegram_info() {
  local name=""
  local refresh=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --refresh) refresh=1 ;;
      -*)        fail "$E_USAGE" "unknown flag: $1" ;;
      *)         [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-info <name> [--refresh]"
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local channels
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ "$channels" == "telegram" ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-info only applies to telegram"

  if (( ! refresh )); then
    local cached
    cached=$(jq -r --arg n "$name" '.agents[$n].botUsername // empty' <<<"$reg")
    if [[ -n "$cached" ]]; then
      ok "bot @$cached" \
         '{username:$un, cached:true}' \
         --arg un "$cached"
      return 0
    fi
  fi

  local token_env="${CONNECTORS_DIR}/telegram-${name}.env"
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] \
    || fail "$E_AUTH_REQUIRED" "no telegram bot token for agent '$name' (expected ${token_env})"

  local username
  username=$(fetch_bot_username "$token" 2>/dev/null) \
    || fail "$E_GENERIC" "telegram getMe failed (network or invalid token)"

  # Cache to registry so the next list/info call avoids the Telegram round-trip.
  with_registry_lock _persist_bot_username "$name" "$username"

  ok "bot @$username" \
     '{username:$un, cached:false}' \
     --arg un "$username"
}

_persist_bot_username() {
  local name="$1" username="$2"
  local reg
  reg=$(registry_read)
  jq --arg n "$name" --arg u "$username" \
    '.agents[$n].botUsername = $u' <<<"$reg" | registry_write
}

# Read ~/.claude/channels/telegram/access.json for a claude-type agent. Used
# by the dashboard's access-control modal to render the current allowlist /
# groups / dmPolicy. Returns the parsed JSON in `data`. If the file doesn't
# exist yet (plugin hasn't persisted state), returns the same defaults the
# plugin would write on first run.
# Resolve the telegram-plugin state dir (where access.json lives) for an agent
# by type. claude, codex and grok each store it under ~/.<type>/channels/telegram/
# — the home subdir name matches the agent type, and all use the same
# access.json schema {dmPolicy, allowFrom, groups}. Echoes the dir on success;
# returns nonzero for types that have no telegram access.json (openclaw/hermes
# manage approvals through their own tooling, not this file). antigravity is the
# odd one out: its home subdir is ~/.gemini (not ~/.antigravity) because agy
# reuses Google's ~/.gemini parent, so it gets an explicit branch.
_tg_access_state_dir() {
  local user="$1" type="$2"
  case "$type" in
    claude|codex|grok) printf '/home/%s/.%s/channels/telegram' "$user" "$type" ;;
    antigravity)       printf '/home/%s/.gemini/channels/telegram' "$user" ;;
    *) return 1 ;;
  esac
}

cmd_telegram_access_get() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access get <name>"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ "$channels" == "telegram" ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local raw
  raw=$(sudo -u "$user" cat "$access" 2>/dev/null || true)
  if [[ -z "$raw" ]] || ! jq -e . >/dev/null 2>&1 <<<"$raw"; then
    raw='{"dmPolicy":"pairing","allowFrom":[],"groups":{}}'
  fi
  ok "" '{access: $a, botUsername: $u}' \
     --argjson a "$raw" \
     --arg u "$(jq -r --arg n "$name" '.agents[$n].botUsername // ""' <<<"$reg")"
}

# Write the telegram access.json for a claude/codex/grok agent (path resolved
# by type via _tg_access_state_dir — all three share the same schema).
# The new JSON body comes in on stdin (the dashboard sends it via the
# `stdin` field on /server/agents/exec so it never lands in argv).
#
# Schema validated server-side: dmPolicy in {pairing,allowlist,disabled},
# allowFrom = array of numeric-string ids, groups = object keyed by chat id
# whose values are {requireMention: bool, allowFrom: string[]}. Any keys we
# don't expose (pending, mentionPatterns, replyToMode, textChunkLimit,
# chunkMode, ackReaction) are merged from the existing file rather than
# clobbered, so opaque settings the dashboard hasn't surfaced survive a
# save. Plugin re-reads on every inbound message — no agent restart needed.
cmd_telegram_access_set() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent telegram-access set <name>  (JSON body on stdin)"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ "$channels" == "telegram" ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-access only applies to telegram"
  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-access supports claude, codex, grok and antigravity agents (got type=$type)"

  local body
  body=$(cat)
  [[ -n "$body" ]] || fail "$E_USAGE" "telegram-access set expects JSON on stdin"
  jq -e . >/dev/null 2>&1 <<<"$body" \
    || fail "$E_VALIDATION" "stdin is not valid JSON"

  step "Updating telegram access for agent '$name'"
  # Validation + atomic write live in the same python step so a bad shape
  # exits non-zero before we touch the file. STATE is the agent's plugin
  # state dir; PATCH is the dashboard's proposed {dmPolicy, allowFrom,
  # groups} blob. Unknown keys in the existing file (pending,
  # mentionPatterns, replyToMode, textChunkLimit, chunkMode, ackReaction)
  # survive the merge — only the three dashboard-owned keys are replaced.
  local script
  script=$(cat <<'PY'
import json, os, re, sys, tempfile

ID_RE = re.compile(r"^-?[0-9]+$")
state = os.environ['STATE']
try:
    patch = json.loads(os.environ['PATCH'])
except json.JSONDecodeError as e:
    print(f"invalid JSON: {e}", file=sys.stderr); sys.exit(2)

def bad(msg):
    print(msg, file=sys.stderr); sys.exit(2)

if not isinstance(patch, dict):
    bad("top-level must be an object")
if patch.get('dmPolicy') not in ('pairing', 'allowlist', 'disabled'):
    bad("dmPolicy must be one of pairing|allowlist|disabled")
allow = patch.get('allowFrom')
if not isinstance(allow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in allow):
    bad("allowFrom must be an array of numeric-string ids")
groups = patch.get('groups')
if not isinstance(groups, dict):
    bad("groups must be an object")
for gid, gcfg in groups.items():
    if not ID_RE.match(gid):
        bad(f"group key '{gid}' is not numeric")
    if not isinstance(gcfg, dict):
        bad(f"group '{gid}' value must be an object")
    if 'requireMention' in gcfg and not isinstance(gcfg['requireMention'], bool):
        bad(f"group '{gid}'.requireMention must be a boolean")
    if 'allowFrom' in gcfg:
        gallow = gcfg['allowFrom']
        if not isinstance(gallow, list) or not all(isinstance(s, str) and ID_RE.match(s) for s in gallow):
            bad(f"group '{gid}'.allowFrom must be an array of numeric-string ids")

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        existing = json.load(f)
except FileNotFoundError:
    existing = {}

merged = dict(existing)
for k in ('dmPolicy', 'allowFrom', 'groups'):
    merged[k] = patch[k]

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(merged, f, indent=2)
os.replace(tmp, path)
PY
)
  local err
  if ! err=$(sudo -u "$user" env STATE="$state_dir" PATCH="$body" python3 -c "$script" 2>&1 >/dev/null); then
    fail "$E_VALIDATION" "${err:-telegram access.json write failed for agent '$name'}"
  fi

  ok "telegram access updated for '$name'" \
     '{name:$n, updated:true}' \
     --arg n "$name"
}

# Drop a pending pairing entry without approving it. The dashboard's inbox
# UI calls this when the operator clicks "Ignore" on a stranger's DM —
# removes the code from access.json's pending map so it stops showing in
# the modal, but does NOT add the senderId to allowFrom. The plugin will
# re-prompt with a fresh code if the same sender messages again.
cmd_telegram_pending_ignore() {
  local name="" code=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$code" ]]; then code="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$code" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-pending-ignore <name> <code>"
  [[ "$code" =~ ^[A-Za-z0-9]{4,16}$ ]] \
    || fail "$E_VALIDATION" "invalid code format"
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  [[ "$channels" == "telegram" ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-pending-ignore only applies to telegram"

  local user="agent-${name}"
  local state_dir
  state_dir=$(_tg_access_state_dir "$user" "$type") \
    || fail "$E_VALIDATION" "telegram-pending-ignore supports claude, codex, grok and antigravity agents (got type=$type)"
  local access="${state_dir}/access.json"
  local err
  err=$(sudo -u "$user" env ACCESS="$access" CODE="$code" python3 - <<'PY' 2>&1 >/dev/null
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print("access.json not found — nothing pending", file=sys.stderr); sys.exit(2)

pending = data.get('pending') or {}
if code not in pending:
    print(f"code '{code}' is not pending", file=sys.stderr); sys.exit(2)
pending.pop(code, None)
data['pending'] = pending

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
  ) || fail "$E_PAIRING" "${err:-pending-ignore failed}"

  ok "ignored pending pairing '$code' for '$name'" \
     '{name:$n, code:$c, ignored:true}' \
     --arg n "$name" --arg c "$code"
}

# Resolve a Telegram chat reference — either a public @handle or a numeric
# chat id — to its full identity (id, displayName, type, isBot) via the
# agent's own bot token calling getChat. Used by the dashboard's
# add-allowlist UX (paste @handle instead of digging up an id) AND by the
# load-time name enrichment (turn cryptic ids in allowFrom into "Mark ·
# @lodar"). Token stays server-side. Returned id can then be written into
# allowFrom by the regular telegram-access set path — no schema change.
cmd_telegram_resolve_handle() {
  local name="" handle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -[0-9]*) # leading-minus numeric — a group/channel id, not a flag
        if [[ -z "$name" ]]; then name="$1"
        elif [[ -z "$handle" ]]; then handle="$1"
        else fail "$E_USAGE" "extra arg: $1"; fi ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  if [[ -z "$name" ]]; then name="$1"
          elif [[ -z "$handle" ]]; then handle="$1"
          else fail "$E_USAGE" "extra arg: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$handle" ]] \
    || fail "$E_USAGE" "usage: 5dive agent telegram-resolve-handle <name> <@handle|chat_id>"
  # Note on arg parsing: a leading '-' on the handle arg (e.g. group id
  # -100123…) would normally match the -* flag glob and error out. The
  # case branch above handles this by accepting -[0-9]* positionally.
  # Normalise: accept "@foo", "foo", or a numeric chat id. Anything else is
  # rejected. Numeric ids may be negative for groups/channels.
  local lookup
  if [[ "$handle" =~ ^-?[0-9]{1,20}$ ]]; then
    # Numeric id — pass through verbatim. getChat accepts these for chats
    # the bot can see (users who've messaged it, groups it's in, public
    # channels). Failures map to NOT_FOUND below.
    lookup="$handle"
  else
    handle="${handle#@}"
    [[ "$handle" =~ ^[A-Za-z][A-Za-z0-9_]{3,31}$ ]] \
      || fail "$E_VALIDATION" "invalid handle (expected 5-32 chars, letters/digits/underscore, or a numeric id)"
    lookup="@${handle}"
  fi
  ensure_state
  local reg type channels
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  case "$type" in
    claude|codex|grok|antigravity) ;;
    *) fail "$E_VALIDATION" "telegram-resolve-handle supports claude, codex, grok and antigravity agents (got type=$type)" ;;
  esac
  [[ "$channels" == "telegram" ]] \
    || fail "$E_VALIDATION" "agent '$name' has channels=$channels — telegram-resolve-handle only applies to telegram"

  local token_env="${CONNECTORS_DIR}/telegram-${name}.env"
  local token
  token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$token" ]] \
    || fail "$E_AUTH_REQUIRED" "no telegram bot token for agent '$name' (expected ${token_env})"

  local resp
  resp=$(curl -sS -m 10 --get \
    --data-urlencode "chat_id=${lookup}" \
    "https://api.telegram.org/bot${token}/getChat" 2>/dev/null || true)
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    fail "$E_GENERIC" "telegram api unreachable"
  fi
  if [[ "$(jq -r '.ok' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    local desc
    desc=$(jq -r '.description // "telegram api error"' <<<"$resp" 2>/dev/null)
    # getChat returns "Bad Request: chat not found" for unknown handles; map
    # to NOT_FOUND so the dashboard can show a friendly "no such bot" message.
    case "$desc" in
      *"chat not found"*|*"chat_id is empty"*) fail "$E_NOT_FOUND" "telegram: $desc" ;;
      *) fail "$E_GENERIC" "telegram: $desc" ;;
    esac
  fi

  # Per Bot API: getChat returns a Chat object (not User), which has no
  # is_bot field — that lives on User and is only delivered with inbound
  # messages. We derive isBot from the handle convention: Telegram requires
  # all bot usernames to end in "bot" at registration (case-insensitive),
  # so the suffix is a reliable signal for type=private chats.
  #
  # Chat objects: users/bots have first_name + optional last_name + optional
  # username. Groups/supergroups/channels have title + optional username.
  # We read both branches and prefer whichever populates.
  local chat_id chat_type username first_name last_name title
  chat_id=$(jq -r '.result.id // empty'         <<<"$resp")
  chat_type=$(jq -r '.result.type // empty'     <<<"$resp")
  username=$(jq -r '.result.username // empty'  <<<"$resp")
  first_name=$(jq -r '.result.first_name // empty' <<<"$resp")
  last_name=$(jq -r '.result.last_name // empty'   <<<"$resp")
  title=$(jq -r '.result.title // empty'        <<<"$resp")
  [[ -n "$chat_id" ]] \
    || fail "$E_GENERIC" "telegram getChat returned no id"

  local is_bot=false
  if [[ "$chat_type" == "private" ]] && [[ "${username,,}" == *bot ]]; then
    is_bot=true
  fi

  # Compose displayName by chat type. Falls back through: title (group/channel)
  # → first+last (user/bot) → @username → @handle from input → numeric id.
  local display="$title"
  if [[ -z "$display" ]]; then
    display="$first_name"
    [[ -n "$last_name" ]] && display="${display:+$display }${last_name}"
  fi
  if [[ -z "$display" ]]; then
    if [[ -n "$username" ]]; then display="@${username}"
    elif [[ -n "${handle:-}" ]]; then display="@${handle}"
    else display="$chat_id"
    fi
  fi

  local label="$display"
  [[ -n "$username" && "$display" != "@${username}" ]] && label="$display · @${username}"

  ok "resolved $label → $chat_id" \
     '{id:$id, isBot:($b == "true"), type:$t, username:$u, displayName:$d}' \
     --arg id "$chat_id" \
     --arg b  "$is_bot" \
     --arg t  "$chat_type" \
     --arg u  "$username" \
     --arg d  "$display"
}

# Interactive pairing for a telegram- or discord-enabled claude-family agent.
# Two paths:
#   --code=<code>     classic: user DMs bot, bot replies with "pair <code>",
#                     dashboard pastes that here. We pop <code> from access.json's
#                     pending map, add the senderId to allowFrom, drop
#                     approved/<senderId>.
#   --user-id=<id>    auto: caller already discovered the chat (via
#                     cmd_telegram_discover or out-of-band) and wants to seed
#                     access.json directly. Skips the code roundtrip — writes
#                     allowFrom/approved with the supplied id immediately.
#                     For private DMs chat_id == user_id, so --chat-id is
#                     optional.
#
# Telegram and Discord plugins use the same access.json schema + approved/
# dir layout, so the JSON patch is identical — only the paths, token env
# var, and welcome-delivery mechanism differ.
cmd_pair() {
  local name="" precode="" preuser="" prechat=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code=*)     precode="${1#--code=}" ;;
      --user-id=*)  preuser="${1#--user-id=}" ;;
      --chat-id=*)  prechat="${1#--chat-id=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent pair <name> [--code=<code> | --user-id=<id> [--chat-id=<id>]]"
  if [[ -n "$precode" && -n "$preuser" ]]; then
    fail "$E_USAGE" "--code and --user-id are mutually exclusive"
  fi
  if [[ -n "$preuser" ]]; then
    valid_telegram_chat_id "$preuser" \
      || fail "$E_VALIDATION" "invalid --user-id (numeric, optionally negative)"
    if [[ -n "$prechat" ]]; then
      valid_telegram_chat_id "$prechat" \
        || fail "$E_VALIDATION" "invalid --chat-id (numeric, optionally negative)"
    else
      # Private DM convention: chat_id matches user_id. Groups need explicit --chat-id.
      prechat="$preuser"
    fi
  fi
  ensure_state
  local reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  local type channels
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  channels=$(jq -r --arg n "$name" '.agents[$n].channels' <<<"$reg")
  case "$channels" in
    telegram|discord) ;;
    *) fail "$E_VALIDATION" "agent '$name' has channels=$channels — pairing only applies to telegram or discord" ;;
  esac
  # cmd_pair applies to claude, codex, grok and antigravity — their
  # telegram/discord plugins use a code-roundtrip (user DMs bot, bot replies with a code,
  # dashboard pastes the code back to seed access.json) and share the same
  # access.json schema + path layout (~/.<type>/channels/<channel>/). openclaw
  # and hermes are token-only: the bot token alone is enough to authorise the
  # agent, and inbound user approvals flow through openclaw's own `pairing`
  # subcommand rather than this code path.
  case "$type" in
    claude|codex|grok|antigravity) ;;
    openclaw|hermes)
      fail "$E_VALIDATION" "type=$type doesn't use pair codes — the bot token configured at create time is sufficient. To approve specific Telegram/Discord users for an openclaw agent, run: sudo -u agent-${name} openclaw pairing list" ;;
    *)
      fail "$E_VALIDATION" "pairing only applies to claude, codex, grok and antigravity agents (got type=$type)" ;;
  esac

  local user="agent-${name}"
  local access="/home/${user}/.${type}/channels/${channels}/access.json"
  local token_env token_var
  case "$channels" in
    telegram) token_env="${CONNECTORS_DIR}/telegram-${name}.env"; token_var="TELEGRAM_BOT_TOKEN" ;;
    discord)  token_env="${CONNECTORS_DIR}/discord-${name}.env";  token_var="DISCORD_BOT_TOKEN"  ;;
  esac

  local bot_token
  bot_token=$(sed -n "s/^${token_var}=//p" "$token_env" 2>/dev/null | head -1 || true)
  [[ -n "$bot_token" ]] \
    || fail "$E_AUTH_REQUIRED" "no bot token for agent '$name' — run: sudo 5dive agent config $name set ${channels}.token=<token>"

  # Auto-pair path: caller already knows the (user_id, chat_id) — typically
  # because cmd_telegram_discover surfaced them from getUpdates. Seed
  # access.json directly without waiting for the plugin: the plugin only
  # writes access.json when it has state to persist (a pending pairing
  # entry, etc.), so on a freshly-created agent that's never received a
  # message the file may never appear. Writing it ourselves means the
  # plugin reads our allowFrom on first message — same end state as the
  # code-roundtrip path, no race with a pending entry.
  if [[ -n "$preuser" ]]; then
    local chat_id="$prechat"
    local state_dir="/home/${user}/.${type}/channels/${channels}"
    sudo -u "$user" env SENDER="$preuser" CHAT="$chat_id" STATE="$state_dir" python3 - <<'PY' >&2 \
      || fail "$E_PAIRING" "auto-pair seed failed"
import json, os, tempfile

state = os.environ['STATE']
sender = os.environ['SENDER']
chat = os.environ['CHAT']

os.makedirs(state, mode=0o700, exist_ok=True)
path = os.path.join(state, 'access.json')

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)
data['allowFrom'] = allow

approved = os.path.join(state, 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=state, prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Auto-paired user {sender} (chat {chat})")
PY

    if [[ "$channels" == "telegram" ]]; then
      send_welcome_message "$chat_id" "$bot_token" "$name" "$type"
    fi
    ok "agent '$name' paired with chat $chat_id." \
       '{name:$n, channels:$ch, chatId:$c, paired:true}' \
       --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
    return
  fi

  # Pair-code path: the bot writes access.json with a pending entry when the
  # user DMs it, so wait for that before trying to consume the code. Cold
  # start can take ~45s on a fresh box (skill preinstalls + plugin install
  # run during agent startup), so wait 90s.
  step "Waiting for $channels plugin on agent '$name'..."
  local waited=0
  for _ in $(seq 1 90); do
    if sudo -u "$user" test -f "$access" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done
  sudo -u "$user" test -f "$access" 2>/dev/null \
    || fail "$E_TIMEOUT" "$access not found after 90s. Is the agent running? (systemctl status 5dive-agent@${name})"

  # Interactive INTRO is only shown to a human at a TTY. JSON callers must
  # pass --code=<code>; the non-precode path is unreachable over the API.
  if [[ -z "$precode" && "$JSON_MODE" == "0" ]]; then
    local app_label example_code
    case "$channels" in
      telegram) app_label="Telegram"; example_code="d13dc3" ;;
      discord)  app_label="Discord";  example_code="a4f2b1" ;;
    esac
    cat >&2 <<INTRO
Open $app_label and send any message to your bot. The bot will reply with
something like:

    Pairing required — run in Claude Code:
    /${channels}:access pair ${example_code}

Paste the reply (or just the code) below.

INTRO
  fi

  # Either prompt interactively (TTY) or consume --code once (exec path).
  local msg code chat_id tries_left=5
  [[ -n "$precode" ]] && tries_left=1
  while (( tries_left-- > 0 )); do
    if [[ -n "$precode" ]]; then
      msg="$precode"
    else
      read -r -p "Paste: " msg
    fi

    # grep with no match is expected when the user pastes just the bare code.
    code=$(printf '%s' "$msg" \
      | grep -oE 'pair[[:space:]]+[A-Za-z0-9]+' \
      | head -1 | awk '{print $2}' || true)
    if [[ -z "$code" ]]; then
      code=$(printf '%s' "$msg" | tr -d '[:space:]')
    fi
    if [[ ! "$code" =~ ^[A-Za-z0-9]{4,16}$ ]]; then
      warn "Could not extract a pair code from that. Paste the full bot reply or just the code."
      [[ -n "$precode" ]] && fail "$E_VALIDATION" "invalid --code=<code>"
      continue
    fi

    if chat_id=$(sudo -u "$user" env CODE="$code" ACCESS="$access" python3 - <<'PY'
import json, os, sys, tempfile

path = os.environ['ACCESS']
code = os.environ['CODE']

with open(path) as f:
    data = json.load(f)

pending = data.get('pending') or {}
entry = pending.pop(code, None)
if entry is None:
    print(f"Pair code '{code}' is not pending. Message the bot within the "
          "last hour, then retry.", file=sys.stderr)
    sys.exit(2)

sender = str(entry.get('senderId', '')).strip()
chat = str(entry.get('chatId', '')).strip()
if not sender:
    print("Pending entry missing senderId", file=sys.stderr)
    sys.exit(3)

allow = list(data.get('allowFrom') or [])
if sender not in allow:
    allow.append(sender)

data['allowFrom'] = allow
data['pending'] = pending

approved = os.path.join(os.path.dirname(path), 'approved')
os.makedirs(approved, mode=0o700, exist_ok=True)
with open(os.path.join(approved, sender), 'w') as f:
    f.write(chat)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.access.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
print(f"Paired user {sender}", file=sys.stderr)
print(chat)
PY
    ); then
      if [[ -n "$chat_id" ]]; then
        break
      fi
      warn "Pairing returned no chat id. Try again."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing failed"
    else
      warn "That code isn't pending. Message the bot first, then paste the reply."
      [[ -n "$precode" ]] && fail "$E_PAIRING" "pairing code not pending"
    fi
  done

  [[ -n "${chat_id:-}" ]] || fail "$E_PAIRING" "exhausted retries without a successful pairing"

  # Telegram: CLI sends a welcome DM via Telegram's HTTP API.
  # Discord: the plugin's channel server polls approved/<senderId> and sends
  # its own "you're in" DM through the gateway — we don't need (and don't
  # have) a simple HTTP send path here.
  if [[ "$channels" == "telegram" ]]; then
    send_welcome_message "$chat_id" "$bot_token" "$name"
  fi
  ok "agent '$name' paired with chat $chat_id." \
     '{name:$n, channels:$ch, chatId:$c, paired:true}' \
     --arg n "$name" --arg ch "$channels" --arg c "$chat_id"
}

# One-shot "it works" DM after a successful pairing — labelled with the agent
# name + type so users running many bots can tell them apart. Token goes via
# URL-encoded POST body (not argv) so it doesn't show up in `ps`. Copy is
# per-type: claude surfaces its model/effort + voice (Claude-plugin features);
# codex/grok drop those lines since they're Claude-specific (and reading
# claude's settings.local.json would render wrong values for them).
send_welcome_message() {
  local chat_id="$1" bot_token="$2" agent_name="${3:-}" agent_type="${4:-claude}" text

  # FIVE_DOMAIN is the host's public subdomain (e.g. agent.example.com),
  # set during provisioning. Folded into the message only when present so
  # self-hosted boxes / dev VMs don't surface a half-rendered URL.
  local domain=""
  if [[ -r /etc/5dive/provisioning.env ]]; then
    domain=$(sed -n 's/^FIVE_DOMAIN=//p' /etc/5dive/provisioning.env 2>/dev/null | head -1)
  fi
  local live_line=""
  if [[ -n "$domain" ]]; then
    live_line=" Anything you build goes live at https://${domain} ready to share, or ask me to add your own domain."
  fi

  # "'<name>', " when we know the agent name, else "" → "I'm your X agent."
  local name_q=""
  [[ -n "$agent_name" ]] && name_q="'${agent_name}', "

  case "$agent_type" in
    codex|grok|antigravity)
      local kind
      if [[ "$agent_type" == "codex" ]]; then kind="Codex agent (OpenAI Codex)"
      elif [[ "$agent_type" == "antigravity" ]]; then kind="Antigravity agent (Google Gemini)"
      else kind="Grok agent (xAI Grok)"; fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your ${kind}.

Here 24/7, ready to pick up where we left off. Send text, photos, or files.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
    *)
      # Read the agent's REAL model/effort from its own settings.json (where the
      # per-agent default — opus — is seeded). Fall back to the base claude user
      # and the legacy shared projects file. Never surface a raw "default"
      # placeholder: if we can't read a concrete model, show a generic line.
      local model="" effort="" f
      local candidates=()
      [[ -n "$agent_name" ]] && candidates+=("/home/agent-${agent_name}/.claude/settings.json")
      candidates+=("/home/claude/.claude/settings.json" "/home/claude/projects/.claude/settings.local.json")
      for f in "${candidates[@]}"; do
        [[ -r "$f" ]] || continue
        model=$(jq -r '.model // empty' "$f" 2>/dev/null)
        effort=$(jq -r '.effortLevel // empty' "$f" 2>/dev/null)
        [[ -n "$model" ]] && break
      done
      local model_line="Model and effort are switchable anytime, just ask."
      if [[ -n "$model" && "$model" != "default" ]]; then
        if [[ -n "$effort" && "$effort" != "default" ]]; then
          model_line="Running ${model} at ${effort} effort. Switchable anytime, just ask."
        else
          model_line="Running ${model}. Switchable anytime, just ask."
        fi
      fi
      text=$(cat <<EOF
👋 We're connected! I'm ${name_q}your Claude agent.

${model_line}

Here 24/7 with memory. Send text, photos, or files, or ask for voice if you'd rather talk.

Tell me what to build: app, site, bot, report, campaign. Consider it shipped.${live_line} Need more hands? Siblings on demand, working in parallel.
EOF
)
      ;;
  esac

  curl -sS -o /dev/null \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${text}" \
    "https://api.telegram.org/bot${bot_token}/sendMessage" \
    && echo "Sent welcome message to chat ${chat_id}" >&2 \
    || warn "Failed to send welcome message"
}

# -------- lifecycle / inspection (start, stop, logs, send, clone, stats) --------

# Shared: resolve a registry entry or die. Echo nothing on success; used for
# presence checks in the lifecycle commands below.
require_agent() {
  local name="$1"
  ensure_state
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
  ok "agent '$name' started." \
     '{name:$n, action:"start"}' --arg n "$name"
}

cmd_stop() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent stop <name>"
  require_agent "$name"
  systemctl stop "5dive-agent@${name}.service" >&2
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

  local trimmed
  trimmed=$(printf '%s' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n "$trimmed" ]] || return 0

  # Resolve the receiver's @botUsername for a tappable mention; fall back to
  # the bare agent name if the registry has no cached username.
  local bot to_label
  bot=$(jq -r --arg n "$receiver" '.agents[$n].botUsername // empty' <<<"$reg" 2>/dev/null)
  if [[ -n "$bot" ]]; then to_label="@${bot}"; else to_label="@${receiver}"; fi

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

# POST a mirror message, threading into message_thread_id when set. Auto-follows
# a group→supergroup migration: once a group is upgraded (which is also how it
# gains forum topics), Telegram rejects sends to the old basic-group id with
# parameters.migrate_to_chat_id. On that error we rewrite the stored group id
# and retry once against the new supergroup id, so the mirror self-heals instead
# of silently dying. Best-effort throughout — a mirror post is never load-bearing.
_mirror_post() {
  local token="$1" chat="$2" thread="$3" text="$4" access_file="$5"
  local resp
  resp=$(_mirror_send "$token" "$chat" "$thread" "$text")
  [[ -n "$resp" ]] || return 0
  [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" == "true" ]] && return 0

  local new_chat
  new_chat=$(jq -r '.parameters.migrate_to_chat_id // empty' <<<"$resp" 2>/dev/null)
  if [[ -n "$new_chat" && "$new_chat" != "$chat" ]]; then
    _mirror_follow_migration "$access_file" "$chat" "$new_chat"
    _mirror_send "$token" "$new_chat" "$thread" "$text" >/dev/null 2>&1 || true
  fi
}

_mirror_send() {
  local token="$1" chat="$2" thread="$3" text="$4"
  if [[ -n "$thread" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "message_thread_id=${thread}" \
      --data-urlencode "text=${text}" 2>/dev/null
  else
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
      --data-urlencode "chat_id=${chat}" \
      --data-urlencode "text=${text}" 2>/dev/null
  fi
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
# that never draw "❯" shouldn't wedge inter-agent sends).
wait_agent_input_ready() {
  local name="$1" timeout="${2:-45}"
  local user="agent-${name}" waited=0 pane
  while (( waited < timeout )); do
    pane=$(sudo -u "$user" tmux capture-pane -p -t "agent-${name}" 2>/dev/null || true)
    grep -q '❯' <<<"$pane" && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

# Inject a message into the agent's tmux session. Uses send-keys -l so the text
# is literal (no tmux keybinding interpretation), followed by a separate Enter.
# Not exposed via /agents/exec: arbitrary text won't pass the API arg regex, so
# this is CLI + direct-shelld only.
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
      local header="[5dive-msg from=${sender} id=${msg_id}"
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

  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$payload"
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter

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

  require_agent "$name"
  sudo -u "agent-${name}" tmux has-session -t "agent-${name}" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "tmux session 'agent-${name}' not found (is the agent running?)"

  # Resolve sender — ask always wraps because we need a marker to slice the
  # reply window. Fall back to a literal "ask" if neither --from nor SUDO_USER
  # gives us anything; at worst the receiver sees from=ask, which is
  # informative ("a script asked me, not a peer agent").
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

  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" -l -- "$payload"
  sudo -u "agent-${name}" tmux send-keys -t "agent-${name}" Enter

  # Mirror the outbound into the sender's group chat (best-effort). ask always
  # wraps, so there's always a sender identity to mirror under.
  mirror_interagent_outbound "$name" "$message"

  local start now last_change reply="" prev_slice="" capture slice
  start=$(date +%s)
  last_change=$start
  while :; do
    sleep "$poll"
    now=$(date +%s)
    capture=$(sudo -u "agent-${name}" tmux capture-pane -t "agent-${name}" -p -S "-${buf_lines}" 2>/dev/null) || true
    # Everything after the first line containing our marker. The receiver's
    # CLI typically echoes the user input once, so the slice begins right
    # after that echo and grows as the receiver responds.
    slice=$(awk -v id="id=${msg_id}" 'found {print} index($0, id) {found=1}' <<<"$capture")

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
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *)  [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent stats <name> [--json]"
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
  if [[ "$active" == "active" ]]; then
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
