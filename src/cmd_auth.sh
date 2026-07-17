
# -------- auth status (per type, default profile) --------

# auth_creds_present <type> [profile] — non-empty stdout if the credential
# file for this type has a usable token/key. Handles both env-file format
# (anthropic.env with CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY) and the
# JSON sentinels codex/opencode write on login. With <profile> set, checks the
# PROFILE's credential dir instead of the default home (DIVE-296: the wizard
# creates profile-scoped agents, so a default-home check wrongly reported
# "needs_login" and re-ran the whole OAuth flow even when the profile already
# had a credential).
auth_creds_present() {
  local type="$1" profile="${2:-}" sentinel="${TYPE_AUTH[$1]:-}"
  [[ -n "$sentinel" ]] || return 1
  local path="${sentinel%%:*}" key="${sentinel##*:}"
  # Profile-scoped: swap the default credential path for the profile's. The
  # jq key (for OAuth json sentinels) is unchanged.
  if [[ -n "$profile" ]]; then
    local ppath
    ppath=$(profile_type_auth_path "$profile" "$type") || ppath=""
    [[ -n "$ppath" ]] && path="$ppath"
  fi
  local sentinel_ok=0
  if [[ "$path" == "$key" ]]; then
    [[ -s "$path" ]] && sentinel_ok=1
  elif [[ -f "$path" ]]; then
    local val=""
    case "$path" in
      *.env)
        # Any non-empty KEY=... in the env file counts — user may have written
        # ANTHROPIC_API_KEY instead of CLAUDE_CODE_OAUTH_TOKEN and both are valid.
        val=$(grep -Ev '^\s*#' "$path" 2>/dev/null | grep -E '^[A-Z_]+=.+' | head -n1 || true)
        ;;
      *)
        val=$(jq -r --arg k "$key" '.env[$k] // empty' "$path" 2>/dev/null || true)
        ;;
    esac
    [[ -n "$val" ]] && sentinel_ok=1
  fi
  (( sentinel_ok )) && return 0

  # Fallback: types whose TYPE_AUTH sentinel is the OAuth state file
  # (codex) won't see an api-key written by `agent auth set`, which
  # lands in /etc/5dive/connectors/<TYPE_API_FILE>. Recognise that file as
  # equally-valid auth — matches the policy that API-key is the preferred
  # path for 3P-harness-blocked vendors (project_google_third_party_harness_policy,
  # project_anthropic_third_party_harness_policy).
  # Profile-scoped api keys live in the profile's combined.env, not the shared
  # connectors dir; check there when a profile is set.
  local api_path
  if [[ -n "$profile" ]]; then
    api_path="${AUTH_PROFILES_DIR}/${profile}/combined.env"
  else
    local api_file="${TYPE_API_FILE[$type]:-}"
    [[ -n "$api_file" ]] || return 1
    api_path="${CONNECTORS_DIR}/${api_file}"
  fi
  [[ -f "$api_path" ]] || return 1
  local api_val
  api_val=$(grep -Ev '^\s*#' "$api_path" 2>/dev/null | grep -E '^[A-Z_]+=.+' | head -n1 || true)
  [[ -n "$api_val" ]]
}

# auth_probe_one <type> [profile] — run a short CLI invocation to verify the
# stored creds still work against the provider API. Returns 0 (ok) / 1 (stale)
# / 2 (no probe configured, caller should fall back to file-presence).
#
# The probe runs as user `claude` with a 5s cap. We source the same env files
# systemd loads for 5dive-agent@.service so the CLI sees CLAUDE_CODE_OAUTH_TOKEN
# / ANTHROPIC_API_KEY / OPENAI_API_KEY — otherwise `claude --print ping` exits
# non-zero with "Not logged in" even when the stored token is perfectly valid.
# When <profile> is set, the profile's combined.env is loaded LAST so it
# overrides the shared defaults (same precedence systemd uses).
#
# claude's `--print` exit code flips when stdout isn't a TTY, so we can't rely
# on `$?` alone — instead we capture stdout+stderr and grep for known "not
# authed" patterns. A rate-limit response is a valid-but-throttled token and
# counts as ok (we want to distinguish stale creds, not provider health).
auth_probe_one() {
  local type="$1" profile="${2:-}" probe="${TYPE_PROBE[$1]:-}"
  [[ -n "$probe" ]] || return 2
  local env_src=''
  for f in /etc/5dive/connectors/anthropic.env /etc/5dive/connectors/openai.env; do
    env_src+="[ -r $f ] && set -a && . $f && set +a; "
  done
  if [[ -n "$profile" ]]; then
    local pf="${AUTH_PROFILES_DIR}/${profile}/combined.env"
    env_src+="[ -r $pf ] && set -a && . $pf && set +a; "
  fi
  local out
  out=$(sudo -u claude -i timeout 5s bash -lc "${env_src}${probe}" 2>&1 || true)
  # Known "stale creds" signals from claude's --print output. We match on
  # substrings rather than exit codes because --print flips its exit code
  # based on whether stdout is a TTY. Rate-limit / usage-limit responses
  # are NOT in here — those mean the token works, the account is throttled.
  if grep -qiE 'not logged in|please run /login|invalid api key|invalid bearer token|failed to authenticate|authentication.{0,10}failed|unauthorized|\b401\b' <<<"$out"; then
    return 1
  fi
  return 0
}

# auth_status_one <type> [--no-probe]
# States:
#   unknown       — unrecognized type
#   not_installed — CLI binary missing on disk
#   needs_login   — no credential file / empty credential file
#   stale         — creds exist but the live probe rejected them
#   ok            — creds exist AND (probe passed OR no probe configured)
#
# Pass --no-probe for callers that only want a cheap file check (e.g. the
# bulk cmd_auth_status loop, which runs before the dashboard renders and
# shouldn't block for N*5s). Set FIVEDIVE_AUTH_PROBE=1 to force a probe.
# auth_status_one <type> [--no-probe] [profile]
auth_status_one() {
  local type="$1" probe_flag="${2:-}" profile="${3:-}"
  is_known_type "$type" || { echo "unknown"; return; }
  [[ -x "${TYPE_BIN[$type]}" ]] || { echo "not_installed"; return; }
  # No sentinel configured = type doesn't require external auth (opencode ships
  # with free models). Report "ok" so the connect flow skips straight to create.
  [[ -n "${TYPE_AUTH[$type]:-}" ]] || { echo "ok"; return; }
  if ! auth_creds_present "$type" "$profile"; then
    echo "needs_login"; return
  fi
  if [[ "$probe_flag" == "--no-probe" ]]; then
    echo "ok"; return
  fi
  auth_probe_one "$type" "$profile"
  case "$?" in
    0) echo "ok" ;;
    1) echo "stale" ;;
    *) echo "ok" ;;
  esac
}

# -------- shadow-credential heal (DIVE-329) --------
#
# Bug: an agent user's ~/.claude/.credentials.json (written by an interactive
# `claude` login) takes PRECEDENCE over the CLAUDE_CODE_OAUTH_TOKEN that
# 5dive-agent@.service injects via EnvironmentFile. When that creds file's
# OAuth token expires AND its refresh token can't renew (revoked, or the
# subscription behind it was torn down), Claude Code keeps trying the dead
# creds file and 401s — even though the env-token is perfectly valid. This is
# the teal-fox failure class. The fix: for agents that DO carry an env-token,
# rename a stale/expired shadow creds file to .stale-<ts> so CC falls back to
# the env-token. Reversible (rename, not delete).
#
# Safety: we only ever touch an agent that has a VERIFIED non-empty env-token
# to fall back to, so the rename can never strand an agent on no auth. Scope is
# claude-type agents only — they're the only type that both reads
# ~/.claude/.credentials.json and authenticates via CLAUDE_CODE_OAUTH_TOKEN.
# The host `claude` Linux user is deliberately NOT in scope: it carries no
# env-token and authenticates via its own (auto-refreshing) interactive login,
# so its credentials file is load-bearing, not shadow cruft.
#
# Only a STALE file is renamed (expired / missing-expiry / unparseable). A
# still-valid creds file is left in place — it'll be healed once it expires,
# and renaming a live one would be a needless surprise. (A valid env-token
# makes renaming any shadow file safe, so widening the trigger later is a
# one-line change if we want to close the expiry window entirely.)
#
# Emits one line per affected agent on stdout (machine-readable for doctor):
#   stale  <name> <path>            (repair=0: would heal)
#   healed <name> <path> <bak>      (repair=1: renamed)
#   error  <name> <path> mv-failed  (repair=1: rename failed)
# Always returns 0; callers branch on the emitted lines.
heal_claude_shadow_creds() {
  local repair="${1:-0}"
  [[ -f "$REGISTRY" ]] || return 0
  local reg now_ms
  reg=$(registry_read 2>/dev/null) || return 0
  now_ms=$(( $(date +%s) * 1000 ))
  local name
  for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
    local type profile user home creds
    type=$(jq -r --arg n "$name" '.agents[$n].type // empty' <<<"$reg")
    [[ "$type" == "claude" ]] || continue
    user="agent-${name}"
    home="/home/${user}"
    id -u "$user" &>/dev/null || continue
    creds="${home}/.claude/.credentials.json"
    [[ -f "$creds" ]] || continue

    # Verify this agent actually has an env-token to fall back to before we
    # touch its creds file. Token lives in the profile's combined.env (when an
    # authProfile is set) else the shared connectors/anthropic.env; also accept
    # one written straight into the per-agent / per-agent-auth env file.
    profile=$(jq -r --arg n "$name" '.agents[$n].authProfile // empty' <<<"$reg")
    local -a envfiles=()
    if [[ -n "$profile" ]]; then
      envfiles+=("${AUTH_PROFILES_DIR}/${profile}/combined.env")
    else
      envfiles+=("${CONNECTORS_DIR}/anthropic.env")
    fi
    envfiles+=("${ENV_DIR}/${name}.env" "${ENV_DIR}/${name}-auth.env")
    local has_token=0 f
    for f in "${envfiles[@]}"; do
      [[ -r "$f" ]] || continue
      if grep -qE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=.+' "$f" 2>/dev/null; then
        has_token=1; break
      fi
    done
    (( has_token )) || continue   # no fallback → leave the creds file alone

    # Stale? expiresAt is epoch milliseconds. Treat expired / missing field /
    # unparseable as stale.
    local exp stale=0
    exp=$(jq -r '(.claudeAiOauth.expiresAt // .expiresAt // empty)' "$creds" 2>/dev/null || true)
    if [[ -z "$exp" || ! "$exp" =~ ^[0-9]+$ ]]; then
      stale=1
    elif (( exp < now_ms )); then
      stale=1
    fi
    (( stale )) || continue

    if (( repair )); then
      local bak="${creds}.stale-$(date +%Y%m%d%H%M%S)"
      if mv "$creds" "$bak" 2>/dev/null; then
        echo "healed ${name} ${creds} ${bak}"
      else
        echo "error ${name} ${creds} mv-failed"
      fi
    else
      echo "stale ${name} ${creds}"
    fi
  done
  return 0
}

# -------- post-reauth agent restart (DIVE-383) --------
#
# The OAuth token a re-auth writes into combined.env (profile) /
# connectors/anthropic.env (default), and the per-type credential files the
# device-flow CLIs write under the profile dir, are only read by
# 5dive-agent@.service at BOOT — combined.env via EnvironmentFile, the
# credential files via 5dive-agent-start.sh's seed step. A RUNNING agent keeps
# its stale (usually expired) token until it restarts, so re-login "doesn't
# help" and the 401 persists — it looks like re-auth handed back the same dead
# cred. This is the recurring boot-cred trap (DIVE-383), the same lesson as
# DIVE-380's restart-after-auth. So after any successful token write we:
#   1. heal a stale shadow ~/.claude/.credentials.json that would otherwise
#      take precedence over the fresh env token (DIVE-329), then
#   2. restart every agent bound to the affected profile so the fresh
#      credential is actually picked up.
#
# <profile> empty => agents on the DEFAULT profile (registry .authProfile
# unset/empty), which read the shared connectors/anthropic.env. When no agent
# is bound yet (e.g. re-auth during `agent create`), this is a quiet no-op.
#
# Requires root (systemctl). Callers in the auth-finalize paths already run as
# root (require_root / the API invokes the CLI as root). Always returns 0 so a
# restart hiccup never fails an otherwise-successful login.
# DIVE-1188: make a profile's file-based seed credentials (codex/grok auth.json)
# group-readable so `5dive-agent-start` can seed them into an agent home WITHOUT
# sudo. Standard-isolation agents get NO passwordless-sudo rule, so the old
# `sudo -n cat` seed silently bailed and the agent booted unauthenticated. The
# codex/grok CLIs write these 0600 owned by claude; agents all run in the claude
# group over a group-traversable profile path (dirs are 2750 g=claude), so a
# 0640 g=claude file is directly readable. Mirrors the 0640 root:claude posture
# already used for opencode connector env files. Root-only (chmod on a
# claude-owned file); no-op when the file is absent. Does NOT widen sudo.
normalize_profile_seed_perms() {
  local profile="${1:-}"
  [[ -n "$profile" ]] || return 0
  local type path
  for type in codex grok; do
    path=$(profile_type_auth_path "$profile" "$type" 2>/dev/null) || continue
    [[ -n "$path" && -f "$path" ]] || continue
    chmod 0640 "$path" 2>/dev/null || true
  done
}

restart_profile_agents() {
  local profile="${1:-}"
  # DIVE-1188: normalize seed-cred perms before the agents boot so the very
  # next start reads the fresh token without sudo.
  normalize_profile_seed_perms "$profile"
  [[ -f "$REGISTRY" ]] || return 0
  local reg
  reg=$(registry_read 2>/dev/null) || return 0

  # Heal stale shadow creds first so the just-written env token is honored the
  # instant the agent comes back up. Gated + reversible (rename, not delete).
  local heal line
  heal=$(heal_claude_shadow_creds 1 2>/dev/null || true)
  if [[ -n "$heal" ]]; then
    while IFS= read -r line; do
      case "$line" in
        healed*) step "Healed stale shadow creds: ${line#healed }" ;;
        error*)  warn "shadow-creds heal failed: ${line#error }" ;;
      esac
    done <<<"$heal"
  fi

  local sel
  if [[ -n "$profile" ]]; then
    sel='[.agents | to_entries[] | select(.value.authProfile == $p) | .key]'
  else
    sel='[.agents | to_entries[] | select((.value.authProfile // "") == "") | .key]'
  fi
  local agents n
  agents=$(jq -c --arg p "$profile" "$sel" <<<"$reg")

  # DIVE-620 self-heal: an imported agent broken before FIX A has NO authProfile
  # binding and NO agents.d/<name>-auth.env symlink, so the select above (keyed on
  # authProfile == $profile) misses it and a re-auth never restarts it. When the
  # re-auth profile equals an agent's own NAME and that agent's registry
  # authProfile is unset/empty, it's almost certainly such an orphaned import:
  # create its missing symlink to the now-populated combined.env and fold it into
  # the restart set. Scoped to name == profile so agents on other profiles are
  # untouched.
  if [[ -n "$profile" ]]; then
    local orphan
    orphan=$(jq -r --arg p "$profile" \
      'if (.agents | has($p)) and ((.agents[$p].authProfile // "") == "") then "yes" else "no" end' \
      <<<"$reg" 2>/dev/null)
    if [[ "$orphan" == "yes" ]] && id "agent-${profile}" >/dev/null 2>&1; then
      step "Self-healing imported agent '$profile' (no auth-profile binding) — linking + restarting"
      link_agent_profile "$profile" "$profile"
      agents=$(jq -c --arg p "$profile" '. + [$p] | unique' <<<"$agents")
    fi
  fi

  n=$(jq -r 'length' <<<"$agents" 2>/dev/null || echo 0)
  if (( n == 0 )); then
    step "No running agent bound${profile:+ to account '$profile'} — skipping restart"
    return 0
  fi

  step "Restarting $n agent(s) to load the fresh token (DIVE-383)"
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    systemctl restart "5dive-agent@${agent}.service" >&2 2>&1 \
      || warn "restart of agent '$agent' failed — check journalctl -u 5dive-agent@${agent}"
  done < <(jq -r '.[]' <<<"$agents")
  return 0
}

cmd_auth_status() {
  # Default: skip the live probe so the bulk status call stays fast (<100ms).
  # --probe runs a real `<cli> --print ping` for each installed type and
  # surfaces "stale" when the stored creds no longer work. FIVEDIVE_AUTH_PROBE
  # lets the API layer opt in once without parsing cli args.
  local probe_flag="--no-probe"
  local t=""
  local profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --probe)         probe_flag="" ;;
      --no-probe)      probe_flag="--no-probe" ;;
      --type=*)        t="${1#--type=}" ;;
      --auth-profile=*) profile="${1#--auth-profile=}" ;;
      -*)              fail "$E_USAGE" "unknown flag: $1" ;;
      *)               [[ -z "$t" ]] && t="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  # DIVE-296: --auth-profile scopes the check to one profile, so it only makes
  # sense for a single type. Guard rather than silently checking the default.
  [[ -n "$profile" && -z "$t" ]] \
    && fail "$E_USAGE" "--auth-profile requires --type=<type>"
  [[ -z "$probe_flag" && "${FIVEDIVE_AUTH_PROBE:-}" == "0" ]] && probe_flag="--no-probe"
  [[ "$probe_flag" == "--no-probe" && "${FIVEDIVE_AUTH_PROBE:-}" == "1" ]] && probe_flag=""

  local types=()
  if [[ -n "$t" ]]; then
    is_known_type "$t" || fail "$E_NOT_FOUND" "unknown type: $t"
    types=("$t")
  else
    types=("${!TYPE_BIN[@]}")
  fi

  local out="{"
  local first=1
  for type in "${types[@]}"; do
    local s
    s=$(auth_status_one "$type" "$probe_flag" "$profile")
    if (( first )); then first=0; else out+=","; fi
    out+="\"$type\":\"$s\""
  done
  out+="}"
  if (( JSON_MODE )); then
    echo "$out" | jq -c '{ok:true, data: .}'
  else
    echo "$out" | jq -r 'to_entries[] | "\(.key): \(.value)"' | sort
  fi
}

cmd_install() {
  local type="" upgrade=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upgrade|--force|-u) upgrade=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1 (usage: 5dive agent install <type> [--upgrade])" ;;
      *) if [[ -z "$type" ]]; then type="$1"; else fail "$E_USAGE" "unexpected argument: $1"; fi ;;
    esac
    shift
  done
  [[ -n "$type" ]] || fail "$E_USAGE" "usage: 5dive agent install <type> [--upgrade]"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  local bin="${TYPE_BIN[$type]}"
  if [[ -x "$bin" && $upgrade -eq 0 ]]; then
    ok "$type already installed at $bin (pass --upgrade to force a reinstall)" \
       '{type:$t, bin:$b, installed:true, alreadyInstalled:true, upgraded:false}' \
       --arg t "$type" --arg b "$bin"
    return 0
  fi
  local recipe="${TYPE_INSTALL[$type]:-}"
  [[ -n "$recipe" ]] || fail "$E_NOT_INSTALLED" "no installer configured for '$type' — please install $bin manually"
  local existed=0; [[ -x "$bin" ]] && existed=1
  # DIVE-1189: --upgrade sets FORCE_INSTALL=1 so recipes that self-guard on an
  # existing binary (e.g. codex's `-x` check) reinstall @latest in place instead
  # of no-oping. The provisioning path (cmd_agent_create) calls us WITHOUT the
  # flag, so FORCE_INSTALL stays unset there and install-if-missing is unchanged.
  local prelude=""
  if [[ $upgrade -eq 1 ]]; then
    prelude="export FORCE_INSTALL=1; "
    step "Upgrading $type (as user 'claude')"
  else
    step "Installing $type (as user 'claude')"
  fi
  # -i loads claude's login env (nvm, XDG redirects, etc.)
  sudo -u claude -i bash -lc "${prelude}${recipe}" >&2
  # DIVE-901: some installers finish async or drop the binary via a late
  # rename — give the bin a short grace before declaring failure. Only sleeps
  # on the would-have-failed path; the happy path pays nothing.
  local _waited=0
  while [[ ! -x "$bin" && $_waited -lt 10 ]]; do sleep 1; _waited=$((_waited + 1)); done
  if [[ -x "$bin" ]]; then
    local verb="installed" ujson=false
    [[ $upgrade -eq 1 ]] && ujson=true
    [[ $existed -eq 1 && $upgrade -eq 1 ]] && verb="upgraded"
    ok "$type $verb at $bin" \
       '{type:$t, bin:$b, installed:true, alreadyInstalled:false, upgraded:$u}' \
       --arg t "$type" --arg b "$bin" --argjson u "$ujson"
  else
    fail "$E_GENERIC" "$type install reported success but $bin still missing — investigate manually"
  fi
}

# ---- auth profile helpers ----
#
# A profile is a directory /var/lib/5dive/auth-profiles/<name>/ containing:
#   - combined.env      — key=value pairs merged into the agent's systemd env
#                         (CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, OPENAI_API_KEY,
#                         etc.). systemd EnvironmentFile reads it as root before
#                         drop-priv, so mode 0600 root:root is fine.
#   - <type>/           — optional per-type CLI config dir (e.g. claude/ used as
#                         CLAUDE_CONFIG_DIR) for profiles created via `auth login
#                         --profile=<name>` or the device-code flow.
#
# Per-agent binding: 5dive-agent@<name>.service reads
# /var/lib/5dive/agents.d/<name>-auth.env — a symlink to the profile's
# combined.env when the agent opted into a profile, missing otherwise.
ensure_profile_dir() {
  local name="$1"
  valid_profile_name "$name" || fail "$E_VALIDATION" "invalid profile name '$name' (lowercase letters/digits/_-, start letter, <=32 chars)"
  require_root
  local dir="${AUTH_PROFILES_DIR}/${name}"
  mkdir -p "$dir"
  chown root:claude "${AUTH_PROFILES_DIR}" "$dir"
  chmod 2750 "${AUTH_PROFILES_DIR}" "$dir"
  local env_file="${dir}/combined.env"
  [[ -f "$env_file" ]] || : > "$env_file"
  # 0640 root:claude so agent users (all in group `claude`) can read the
  # file directly when systemd loads it via EnvironmentFile, AND so the live
  # auth probe (running as user `claude`) can source it to validate creds.
  # Same exposure as /etc/5dive/connectors/anthropic.env — if one profile's
  # token leaks to another agent user, they already shared the box.
  chown root:claude "$env_file"
  chmod 640 "$env_file"
  echo "$dir"
}

# profile_type_dir <profile> <type> — per-type state dir under a profile.
# Side effect: creates the dir mode 2750 owner=claude. Idempotent. Used as
# the redirect target for whichever env var the type honours (CODEX_HOME,
# HERMES_HOME, CLAUDE_CONFIG_DIR, or HOME for openclaw).
profile_type_dir() {
  local profile="$1" type="$2"
  [[ -n "$profile" ]] || fail "$E_GENERIC" "profile_type_dir: empty profile"
  is_known_type "$type" || fail "$E_GENERIC" "profile_type_dir: unknown type '$type'"
  local dir="${AUTH_PROFILES_DIR}/${profile}/${type}"
  install -d -m 2750 -o claude -g claude "$dir" 2>/dev/null || true
  echo "$dir"
}

# profile_type_env <profile> <type> — emits the KEY=VALUE env fragment that
# scopes the type's credential storage to the profile dir. Empty when profile
# is empty (default profile keeps writing to the shared /home/claude/.<type>).
# Designed for `env $(profile_type_env ...) <login_cmd>` plumbing.
profile_type_env() {
  local profile="$1" type="$2"
  [[ -n "$profile" ]] || return 0
  local dir
  dir=$(profile_type_dir "$profile" "$type")
  case "$type" in
    claude)            printf 'CLAUDE_CONFIG_DIR=%s' "$dir" ;;
    codex)             printf 'CODEX_HOME=%s' "$dir" ;;
    hermes)            printf 'HERMES_HOME=%s' "$dir" ;;
    # openclaw's resolveStateDir uses $HOME/.openclaw. HOME redirect is the
    # only handle. antigravity (writes ~/.gemini/antigravity-cli/) and grok
    # (writes ~/.grok/) are the same shape — no per-tool *_HOME var to use.
    openclaw|antigravity|grok) printf 'HOME=%s' "$dir" ;;
    *) return 1 ;;
  esac
}

# profile_type_auth_path <profile> <type> — absolute path to the credential
# sentinel for (profile, type). Empty profile returns TYPE_AUTH's shared
# default; non-empty returns the per-profile path corresponding to the
# state-root redirect that profile_type_env installs.
profile_type_auth_path() {
  local profile="$1" type="$2"
  if [[ -z "$profile" ]]; then
    echo "${TYPE_AUTH[$type]:-}"
    return
  fi
  local dir="${AUTH_PROFILES_DIR}/${profile}/${type}"
  case "$type" in
    codex)    echo "${dir}/auth.json" ;;
    hermes)   echo "${dir}/auth.json" ;;
    # openclaw/antigravity/grok use HOME redirect so the credential lives
    # at the same relative path each tool would write under a real $HOME.
    openclaw)    echo "${dir}/.openclaw/agents/main/agent/auth-profiles.json" ;;
    antigravity) echo "${dir}/.gemini/antigravity-cli/antigravity-oauth-token" ;;
    grok)        echo "${dir}/.grok/auth.json" ;;
    # claude detection in cmd_auth_poll is log-grep-based, not file-mtime —
    # this entry is here for completeness/symmetry.
    claude)   echo "${dir}/.credentials.json" ;;
    *) return 1 ;;
  esac
}

# paperclip_seed_for_type <type> <profile> — wire the host-default credential
# location (the path the `claude` Linux user reads) to a profile's credential
# file, so paperclipai (which runs as user `claude`) and any other host-level
# CLI invocation picks up the same auth as the agent does.
#
# Symlinks for codex/hermes/openclaw (file-based auth); env-file write
# for claude (token-via-env). Each per-type case skips when the host-default
# already holds a real (non-symlink) credential — manual host-level logins
# always win over the auto-seed. opencode has no auth and is a no-op.
#
# Idempotent: re-running with the same (type, profile) is a no-op; with a
# different profile, replaces the symlink so paperclip follows the new agent.
paperclip_seed_for_type() {
  local type="$1" profile="$2"
  [[ -n "$type" && -n "$profile" ]] || return 0
  local pdir="${AUTH_PROFILES_DIR}/${profile}/${type}"
  [[ -d "$pdir" ]] || return 0
  # Service-level fixups (PATH, sandbox env vars) are independent of which
  # type triggered the seed — write them once per call and let
  # _paperclip_ensure_runtime_drop_in skip the restart when content matches.
  _paperclip_ensure_runtime_drop_in
  case "$type" in
    codex|hermes)
      local src="${pdir}/auth.json"
      [[ -e "$src" ]] || return 0
      install -d -m 2770 -o claude -g claude "/home/claude/.${type}"
      _paperclip_link_file "$src" "/home/claude/.${type}/auth.json"
      # hermes also pins model.provider/base_url/default in config.yaml;
      # without it the host CLI lands at the "hermes setup" first-run prompt.
      if [[ "$type" == "hermes" && -e "${pdir}/config.yaml" ]]; then
        _paperclip_link_file "${pdir}/config.yaml" "/home/claude/.hermes/config.yaml"
      fi
      # codex needs an explicit sandbox/approval config to skip its first-run
      # trust prompt and the bubblewrap-fallback path that makes paperclip's
      # "respond with hello" probe time out. Mirrors the per-agent config
      # 5dive-agent-start.sh writes for codex agents, but keyed on /home/
      # claude (paperclipai.service's WorkingDirectory).
      if [[ "$type" == "codex" ]]; then
        local cfg=/home/claude/.codex/config.toml
        cat > "$cfg" <<'TOML'
approval_policy = "never"
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false

[projects."/home/claude"]
trust_level = "trusted"
TOML
        chown claude:claude "$cfg"
        chmod 0600 "$cfg"
      fi
      ;;
    openclaw)
      local osrc="${pdir}/.openclaw"
      local oauth="${osrc}/agents/main/agent/auth-profiles.json"
      [[ -e "$oauth" ]] || return 0
      install -d -m 2770 -o claude -g claude \
        /home/claude/.openclaw \
        /home/claude/.openclaw/agents \
        /home/claude/.openclaw/agents/main \
        /home/claude/.openclaw/agents/main/agent
      _paperclip_link_file "$oauth" "/home/claude/.openclaw/agents/main/agent/auth-profiles.json"
      [[ -e "${osrc}/openclaw.json" ]] \
        && _paperclip_link_file "${osrc}/openclaw.json" "/home/claude/.openclaw/openclaw.json"
      ;;
    claude)
      # claude reads CLAUDE_CODE_OAUTH_TOKEN from env, not a file — copy the
      # token from the profile's combined.env into the anthropic.env that
      # paperclipai.service already loads via EnvironmentFile=. Skip when
      # anthropic.env already has any auth var (preserves manual host login).
      local pcombined="${AUTH_PROFILES_DIR}/${profile}/combined.env"
      [[ -s "$pcombined" ]] || return 0
      local target="${CONNECTORS_DIR}/anthropic.env"
      if [[ -s "$target" ]] \
          && grep -qE '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=' "$target"; then
        return 0
      fi
      local line
      line=$(grep -E '^(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY)=' "$pcombined" | head -1 || true)
      [[ -n "$line" ]] || return 0
      install -d -m 0750 -o root -g claude "$CONNECTORS_DIR"
      printf '%s\n' "$line" > "$target"
      chown root:claude "$target"
      chmod 0640 "$target"
      # Restart paperclipai so the new env var lands in its process. CLIs
      # invoked per-call (codex/hermes/openclaw) pick up new symlinks
      # without a restart, so we only restart for claude's env-var path.
      systemctl is-active --quiet paperclipai 2>/dev/null \
        && systemctl restart paperclipai >/dev/null 2>&1 || true
      ;;
    opencode|*) return 0 ;;
  esac
  return 0
}

# Internal helper: replace <link> with a symlink to <src>, but only when the
# current target is missing or already a symlink (never clobber a real file).
_paperclip_link_file() {
  local src="$1" link="$2"
  [[ -e "$link" && ! -L "$link" ]] && return 0
  ln -sfn "$src" "$link"
  chown -h claude:claude "$link" 2>/dev/null || true
}

# Internal helper: keep a 5dive-managed drop-in for paperclipai.service that
# patches PATH so paperclip's hello probes can find the agent binaries:
#   PATH — base unit's PATH omits /home/claude/.local/bin, so `claude`
#          (lives there) isn't found.
# Idempotent: skips the daemon-reload + restart when on-disk content matches
# what we'd write.
_paperclip_ensure_runtime_drop_in() {
  systemctl list-unit-files paperclipai.service >/dev/null 2>&1 || return 0
  local dir=/etc/systemd/system/paperclipai.service.d
  local conf="${dir}/5dive.conf"
  install -d -m 0755 "$dir"
  local desired
  desired=$(cat <<'CONF'
[Service]
Environment=PATH=/home/claude/.local/bin:/home/claude/.nvm/versions/node/v24/bin:/home/claude/.bun/bin:/usr/local/bin:/usr/bin
CONF
)
  if [[ -f "$conf" ]] && [[ "$(cat "$conf")" == "$desired" ]]; then
    return 0
  fi
  printf '%s\n' "$desired" > "$conf"
  chmod 0644 "$conf"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl is-active --quiet paperclipai 2>/dev/null \
    && systemctl restart paperclipai >/dev/null 2>&1 || true
}

# paperclip_unseed_for_profile <profile> — drop any /home/claude/.* symlinks
# pointing into this profile (called from cmd_rm so a deleted agent doesn't
# leave paperclip wedged on a vanished credential file). Best-effort; never
# fails the parent command. Re-seeds from another agent of the same type
# when one exists, so paperclip stays connected as long as any agent is up.
paperclip_unseed_for_profile() {
  local profile="$1"
  [[ -n "$profile" ]] || return 0
  local pdir="${AUTH_PROFILES_DIR}/${profile}"
  local link target
  while IFS= read -r -d '' link; do
    target=$(readlink "$link" 2>/dev/null || true)
    [[ "$target" == "$pdir/"* ]] && rm -f "$link"
  done < <(find /home/claude/.codex /home/claude/.hermes /home/claude/.openclaw \
              -maxdepth 6 -type l -print0 2>/dev/null)
  # Re-seed each type that just lost its source from the first remaining
  # agent of that type (registry is the source of truth).
  local reg
  reg=$(registry_read 2>/dev/null) || return 0
  local t fallback_profile
  for t in codex hermes openclaw claude; do
    fallback_profile=$(jq -r --arg t "$t" '
      .agents | to_entries | map(select(.value.type == $t and (.value.authProfile // "") != ""))
      | .[0].value.authProfile // empty' <<<"$reg")
    [[ -n "$fallback_profile" ]] && paperclip_seed_for_type "$t" "$fallback_profile"
  done
}

# paperclip_seed_all_from_registry — backfill the host-default credential
# locations from whatever agents already exist. Safe to run anytime; called
# from update.sh so existing customer VMs auto-fix on the next install.sh
# bash run, and from cmd_create to wire each fresh agent without per-type
# branching at the call site.
paperclip_seed_all_from_registry() {
  local reg
  reg=$(registry_read 2>/dev/null) || return 0
  local t profile
  for t in codex hermes openclaw claude; do
    profile=$(jq -r --arg t "$t" '
      .agents | to_entries | map(select(.value.type == $t and (.value.authProfile // "") != ""))
      | .[0].value.authProfile // empty' <<<"$reg")
    [[ -n "$profile" ]] && paperclip_seed_for_type "$t" "$profile"
  done
}

# profile_set_var <profile> <VAR> <VALUE> — idempotent KEY=VALUE upsert in
# combined.env. Value comes via stdin to keep it out of argv. If <profile>
# is empty, writes to the default-profile connector file via the system
# helper (preserves perms + filename validation).
profile_set_var() {
  local profile="$1" var="$2" file default_default_env
  if [[ -z "$profile" ]]; then
    fail "$E_GENERIC" "profile_set_var: no default-profile path (caller must use write_default_connector)"
  fi
  local dir
  dir=$(ensure_profile_dir "$profile")
  file="${dir}/combined.env"
  local value
  value=$(cat)
  local tmp
  tmp=$(mktemp "${file}.XXXXXX")
  grep -v "^${var}=" "$file" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$var" "$value" >> "$tmp"
  chown root:claude "$tmp"
  chmod 640 "$tmp"
  mv "$tmp" "$file"
}

# write_default_connector <filename.env> <VAR> <VALUE> — replaces any prior
# entries for <VAR> in /etc/5dive/connectors/<filename.env>, then rewrites
# with correct perms. Value via stdin.
write_default_connector() {
  local fname="$1" var="$2" value path existing
  value=$(cat)
  path="/etc/5dive/connectors/${fname}"
  existing=""
  if [[ -f "$path" ]]; then
    existing=$(grep -v "^${var}=" "$path" 2>/dev/null || true)
  fi
  { [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '%s=%s\n' "$var" "$value"; } \
    | _write_connector "$fname"
}

# pi_provider_var <provider> — resolve pi's native env var for a provider id
# (default anthropic). Non-zero + empty stdout for an unknown/not-yet-wired
# provider so callers can surface the known set. Backs both `auth set pi
# --provider` and the create-path --provider/--api-key flow. DIVE-1200.
pi_provider_var() {
  local p="${1:-anthropic}"
  local v="${PI_PROVIDER_VAR[$p]:-}"
  [[ -n "$v" ]] || return 1
  echo "$v"
}

# pi_apply_provider_key <provider> <api_key> [profile] — write pi's per-provider
# API key into the profile's combined.env (isolated to agents on that profile)
# or the shared pi.env connector (default profile). pi reads the var straight
# from its environment, so systemd's EnvironmentFile injection is all that's
# needed — no ~/.pi/agent/auth.json write. Requires root (connector/profile
# writes). Shared by cmd_auth_set and cmd_agent_create. DIVE-1200.
pi_apply_provider_key() {
  local provider="${1:-anthropic}" api_key="$2" profile="${3:-}"
  local var
  var=$(pi_provider_var "$provider") \
    || fail "$E_VALIDATION" "pi provider '$provider' not supported (known: ${!PI_PROVIDER_VAR[*]})"
  require_root
  if [[ -z "$profile" ]]; then
    step "Writing ${var} to /etc/5dive/connectors/${TYPE_API_FILE[pi]}"
    printf '%s' "$api_key" | write_default_connector "${TYPE_API_FILE[pi]}" "$var"
  else
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    ensure_profile_dir "$profile" >/dev/null
    step "Writing ${var} to auth profile '${profile}'"
    printf '%s' "$api_key" | profile_set_var "$profile" "$var"
  fi
}

# opencode_provider_var <provider> — resolve an OpenCode provider to the native
# environment variable consumed by the CLI. The default preserves the historical
# provider-less `auth set opencode` behavior.
opencode_provider_var() {
  local provider="${1:-openai}"
  local var="${OPENCODE_PROVIDER_VAR[$provider]:-}"
  [[ -n "$var" ]] || return 1
  echo "$var"
}

# opencode_apply_provider_key <provider> <api_key> [profile] — write the
# provider's native environment variable into the shared connector or an auth
# profile. OpenCode consumes OPENAI_API_KEY / OPENROUTER_API_KEY directly; no
# endpoint override or auth.json mutation is required. Shared by auth-set and
# agent-create so both paths route a key identically. DIVE-1206.
opencode_apply_provider_key() {
  local provider="${1:-openai}" api_key="$2" profile="${3:-}"
  local var
  var=$(opencode_provider_var "$provider") \
    || fail "$E_VALIDATION" "opencode provider '$provider' not supported (known: ${!OPENCODE_PROVIDER_VAR[*]})"
  require_root
  if [[ -z "$profile" ]]; then
    step "Writing ${var} to /etc/5dive/connectors/${TYPE_API_FILE[opencode]}"
    printf '%s' "$api_key" | write_default_connector "${TYPE_API_FILE[opencode]}" "$var"
  else
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    ensure_profile_dir "$profile" >/dev/null
    step "Writing ${var} to auth profile '${profile}'"
    printf '%s' "$api_key" | profile_set_var "$profile" "$var"
  fi
}

# OpenCode persists its default as provider_id/model_id. Keep the small merge
# primitive separate so the preservation contract can be unit-tested without a
# real agent user or /home write.
_opencode_merge_model_config() {
  local model_id="$1"
  jq --arg m "$model_id" '.model=$m'
}

# opencode_catalog <provider-var> <api-key> — list the models OpenCode can
# actually resolve for the authenticated provider (openrouter/openai), one
# `provider/model_id` per line. OpenCode only enumerates providers whose
# credential is present in the environment, so the key must be injected; the
# catalog itself comes from models.dev (no completion is charged — this is a
# metadata read). HOME is thrown away so a root create can't pollute a real
# home. OPENCODE_BIN overrides the binary for unit tests. Returns non-zero (and
# emits nothing) when the binary is missing or enumeration fails offline.
opencode_catalog() {
  local var="$1" key="$2"
  local ocbin="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || echo /home/claude/.local/bin/opencode)}"
  [[ -x "$ocbin" ]] || return 1
  local h; h=$(mktemp -d) || return 1
  HOME="$h" env "${var}=${key}" "$ocbin" models 2>/dev/null; local rc=$?
  rm -rf "$h"
  return "$rc"
}

# opencode_validate_model_or_fail <provider> <model_id> <api-key> — reject a
# --model that OpenCode's catalog does not carry. DIVE-1395: OpenCode silently
# ignores an unresolvable pinned model and falls back to an unrelated default
# (e.g. an image model that returns "No endpoints found that support tool use"),
# so a create-time typo/stale-slug produced an agent that could not run tools.
# Best-effort and fail-OPEN: validation only bites when we can actually
# enumerate (key present + catalog reachable + non-empty). A models.dev outage,
# a missing key, or catalog lag skips the check so create is never blocked on a
# transient — we only hard-fail on a slug we positively know is absent.
opencode_validate_model_or_fail() {
  local provider="$1" model_id="$2" api_key="${3:-}"
  [[ -n "$api_key" ]] || return 0
  local var; var=$(opencode_provider_var "$provider") || return 0
  local catalog; catalog=$(opencode_catalog "$var" "$api_key") || return 0
  [[ -n "$catalog" ]] || return 0
  grep -qxF "$model_id" <<<"$catalog" && return 0
  local sugg; sugg=$(grep -F "${model_id%/*}/" <<<"$catalog" | head -5 \
    | awk 'NR>1{printf ", "}{printf "%s", $0}')
  fail "$E_VALIDATION" "opencode has no model '$model_id' for provider '$provider'. A fresh agent would silently fall back to an unrelated default that may not support tool use.${sugg:+ Close matches: $sugg.} Run 'opencode models' for the full list."
}

# opencode_apply_model_default <agent-name> <provider> <model> [api-key] — pin
# the new agent's default in ~/.config/opencode/opencode.json. The create CLI
# accepts provider and model separately, while OpenCode requires
# provider_id/model_id; tolerate an already-prefixed model as well. When the
# provider api-key is supplied (DIVE-1395) the slug is validated against
# OpenCode's live catalog first, so an unresolvable model fails create loudly
# instead of degrading the agent to a non-tool default. Idempotent and
# merge-safe: only the model key is overwritten. DIVE-1206.
opencode_apply_model_default() {
  local name="$1" provider="$2" model="$3" api_key="${4:-}"
  local home="/home/agent-${name}" dir sf model_id cur='{}' tmp
  dir="${home}/.config/opencode"; sf="${dir}/opencode.json"
  if [[ "$model" == "$provider/"* ]]; then
    model_id="$model"
  else
    model_id="${provider}/${model}"
  fi
  opencode_validate_model_or_fail "$provider" "$model_id" "$api_key"
  install -d -m 700 -o "agent-${name}" -g "agent-${name}" \
    "${home}/.config" "$dir" 2>/dev/null \
    || { warn "opencode model-pin: could not create $dir (skipping --model default)"; return 0; }
  [[ -s "$sf" ]] && cur=$(cat "$sf" 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$cur" || cur='{}'
  tmp=$(mktemp --tmpdir="$dir" opencode.XXXXXX) \
    || { warn "opencode model-pin: mktemp failed"; return 0; }
  if _opencode_merge_model_config "$model_id" <<<"$cur" >"$tmp"; then
    chmod 600 "$tmp"; chown "agent-${name}:agent-${name}" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$sf"
    step "Pinned opencode default model for agent-${name}: ${model_id}"
  else
    rm -f "$tmp"; warn "opencode model-pin: jq merge failed (skipping --model default)"
  fi
}

# pi_catalog <provider> <env-var> <api-key> — emit pi's model ids for <provider>,
# one per line, exact-matchable. pi has no `models` subcommand; `--list-models`
# prints a whitespace table (provider / model / context / …) of the AUTHED
# providers only, so the key must be injected. We keep the rows whose provider
# column equals <provider> and print the model column with pi's leading "~"
# alias marker stripped (e.g. "~google/gemini-flash-latest" -> the printed slug),
# which naturally drops the header and the "No models available" line. The model
# ids carry no spaces, so awk's default field split is safe. HOME is thrown away
# so a root create can't pollute a real home. PI_BIN overrides the binary for
# unit tests. Non-zero (and empty) when the binary is missing or enumeration
# fails offline — the caller fails OPEN on that. DIVE-1402.
pi_catalog() {
  local provider="$1" var="$2" key="$3"
  local pibin="${PI_BIN:-$(command -v pi 2>/dev/null || echo /home/claude/.local/bin/pi)}"
  [[ -x "$pibin" ]] || return 1
  local h; h=$(mktemp -d) || return 1
  HOME="$h" env "${var}=${key}" "$pibin" --list-models 2>/dev/null \
    | awk -v p="$provider" '$1==p { sub(/^~/, "", $2); print $2 }'
  local rc=${PIPESTATUS[0]}
  rm -rf "$h"
  return "$rc"
}

# pi_validate_model_or_fail <provider> <model> <api-key> — reject a --model that
# pi's registry does not carry for <provider>. DIVE-1402 (pi twin of DIVE-1395):
# pi_apply_model_default pinned any slug into settings.json blindly, so a stale
# or misspelled model (e.g. the reported `google/gemini-2.0-flash-lite-001`,
# which pi lacks — it carries `google/gemini-2.5-flash-lite`) left the agent
# booting without the intended model. Best-effort and fail-OPEN: it only bites
# when we can actually enumerate (key present + catalog reachable + non-empty),
# so a missing key or an offline `pi --list-models` never blocks create. pi
# accepts a "<slug>:<thinking>" suffix, so we compare on the slug alone.
pi_validate_model_or_fail() {
  local provider="$1" model="$2" api_key="${3:-}"
  [[ -n "$api_key" ]] || return 0
  local var; var=$(pi_provider_var "$provider") || return 0
  local slug="${model%%:*}"
  local catalog; catalog=$(pi_catalog "$provider" "$var" "$api_key") || return 0
  [[ -n "$catalog" ]] || return 0
  grep -qxF "$slug" <<<"$catalog" && return 0
  local sugg; sugg=$(grep -F "${slug%%/*}/" <<<"$catalog" | head -5 \
    | awk 'NR>1{printf ", "}{printf "%s", $0}')
  fail "$E_VALIDATION" "pi has no model '$slug' for provider '$provider'. A fresh agent would boot without the pinned model (no runnable default).${sugg:+ Close matches: $sugg.} Run 'pi --list-models $provider' for the full list."
}

# pi_apply_model_default <agent-name> <provider> <model> [api-key] — pin a pi
# agent's default provider+model by merging {defaultProvider,defaultModel} into
# its ~/.pi/agent/settings.json. pi reads these at startup, so the agent boots
# onto the chosen model with no interactive /model step (pi has no PI_MODEL env
# var, so this is the only launch-time model-pin surface). When the provider
# api-key is supplied (DIVE-1402) the slug is validated against pi's live
# registry first, so an unresolvable model fails create loudly instead of
# pinning a dead default. Idempotent: preserves any other settings keys,
# overwrites only the two model fields. Runs as root at create time (owns the
# write to the agent user's home); file ends up owned by agent-<name> at 0600
# like pi's own settings writes. DIVE-1205.
pi_apply_model_default() {
  local name="$1" provider="$2" model="$3" api_key="${4:-}"
  pi_validate_model_or_fail "$provider" "$model" "$api_key"
  local home="/home/agent-${name}" dir sf
  dir="${home}/.pi/agent"; sf="${dir}/settings.json"
  install -d -m 700 -o "agent-${name}" -g "agent-${name}" \
    "${home}/.pi" "$dir" 2>/dev/null \
    || { warn "pi model-pin: could not create $dir (skipping --model default)"; return 0; }
  local cur='{}'
  [[ -s "$sf" ]] && cur=$(cat "$sf" 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$cur" || cur='{}'
  local tmp
  tmp=$(mktemp --tmpdir="$dir" settings.XXXXXX) || { warn "pi model-pin: mktemp failed"; return 0; }
  if jq --arg p "$provider" --arg m "$model" \
       '.defaultProvider=$p | .defaultModel=$m' <<<"$cur" >"$tmp"; then
    chmod 600 "$tmp"; chown "agent-${name}:agent-${name}" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$sf"
    step "Pinned pi default model for agent-${name}: ${provider}/${model}"
  else
    rm -f "$tmp"; warn "pi model-pin: jq merge failed (skipping --model default)"
  fi
}

# cmd_auth_set — API-key path that bypasses the browser/OAuth flow. Some
# users prefer pasting a key; also the only option for ANTHROPIC_API_KEY /
# Vertex / Bedrock style auth where there's no device-code flow.
#
# Usage:
#   5dive agent auth set <type> --api-key=<key> [--auth-profile=<name>]
#   echo -n "<key>" | 5dive agent auth set <type> --api-key=- [--auth-profile=<name>]
#
# The "-" sentinel reads the key from stdin — use that from the API layer
# so the key never touches process argv (and thus never shows up in `ps`).
cmd_auth_set() {
  local type="" api_key="" profile="" byo_provider=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-key=*)       api_key="${1#--api-key=}" ;;
      --auth-profile=*)  profile="${1#--auth-profile=}" ;;
      --provider=*)      byo_provider="${1#--provider=}" ;;
      -*)                fail "$E_USAGE" "unknown flag: $1" ;;
      *)                 [[ -z "$type" ]] && type="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$type" ]] || fail "$E_USAGE" "usage: 5dive agent auth set <type> --api-key=<key> [--auth-profile=<name>] [--provider=<id>]"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  [[ -n "$api_key" ]] || fail "$E_USAGE" "--api-key=<key> required (use --api-key=- to read from stdin)"

  if [[ "$api_key" == "-" ]]; then
    [[ -t 0 ]] && fail "$E_USAGE" "--api-key=- expects the key on stdin, stdin is a TTY"
    api_key=$(cat)
  fi
  valid_api_key "$api_key" \
    || fail "$E_VALIDATION" "api key looks wrong (expected >=10 printable non-space chars)"

  # pi path: multi-provider, API-key only (no OAuth). --provider selects which
  # vendor's key this is (default anthropic); the key is injected as pi's native
  # per-provider env var. Distinct from the hermes/openclaw/claude BYO block
  # below (which writes native auth.json/endpoint overrides) — pi just needs the
  # env var. DIVE-1200.
  if [[ "$type" == "pi" ]]; then
    local pi_provider="${byo_provider:-anthropic}"
    pi_apply_provider_key "$pi_provider" "$api_key" "$profile"
    # Reload the key into any running agents that consume it (mirrors the BYO
    # block's restart, and restart_profile_agents' DIVE-383 boot-cred lesson).
    local _affected _agent
    if [[ -n "$profile" ]]; then
      _affected=$(registry_read | jq -r --arg p "$profile" \
        '.agents | to_entries[] | select(.value.authProfile == $p and .value.type == "pi") | .key')
    else
      _affected=$(registry_read | jq -r \
        '.agents | to_entries[] | select((.value.authProfile // "") == "" and .value.type == "pi") | .key')
    fi
    while IFS= read -r _agent; do
      [[ -n "$_agent" ]] || continue
      step "Restarting 5dive-agent@${_agent}.service"
      systemctl restart "5dive-agent@${_agent}.service" >&2 2>&1 \
        || warn "restart of agent '$_agent' failed — check journalctl -u 5dive-agent@${_agent}"
    done <<<"$_affected"
    ok "api key stored for pi/${pi_provider}${profile:+ (profile=$profile)}" \
       '{type:$t, provider:$pr, profile:$p}' \
       --arg t "pi" --arg pr "$pi_provider" --arg p "${profile:-}"
    return
  fi

  # OpenCode is multi-provider. Its supported providers use native environment
  # variables, so select the target from --provider instead of forcing every key
  # into OPENAI_API_KEY. With no flag, retain the legacy OpenAI default.
  if [[ "$type" == "opencode" ]]; then
    local opencode_provider="${byo_provider:-openai}"
    opencode_apply_provider_key "$opencode_provider" "$api_key" "$profile"
    ok "api key stored for opencode/${opencode_provider}${profile:+ (profile=$profile)}" \
       '{type:$t, provider:$pr, profile:$p}' \
       --arg t "opencode" --arg pr "$opencode_provider" --arg p "${profile:-}"
    return
  fi

  # BYO path for hermes/openclaw: --provider=<canonical> picks which vendor's
  # api-key this is. Routes through apply_byo_provider, which writes into the
  # agent CLI's native state dir (hermes auth.json / openclaw auth-profiles.json)
  # rather than the env-var-style anthropic.env path the claude family uses.
  if [[ -n "$byo_provider" ]]; then
    [[ "$type" == "hermes" || "$type" == "openclaw" || "$type" == "claude" ]] \
      || fail "$E_VALIDATION" "--provider only supported for hermes/openclaw/claude (got: $type — drop --provider for env-var-style types)"
    # claude BYO writes the endpoint+model overrides into the profile's
    # combined.env, so it needs a profile (see _apply_byo_claude).
    [[ "$type" == "claude" && -z "$profile" ]] \
      && fail "$E_USAGE" "claude BYO (--provider) requires --auth-profile=<name> (custom-provider creds are profile-scoped)"
    require_root
    if [[ -n "$profile" ]]; then
      valid_profile_name "$profile" \
        || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
      ensure_profile_dir "$profile" >/dev/null
      # hermes/openclaw seed a per-type credential dir; claude stores its
      # override env vars directly in combined.env, so skip that step for it.
      [[ "$type" == "claude" ]] || profile_type_dir "$profile" "$type" >/dev/null
    fi
    apply_byo_provider "$type" "$byo_provider" "$api_key" "$profile"

    # Restart any running agents that consume this credential so the new
    # provider takes effect immediately. Without this, hermes/openclaw
    # gateways stay on the stale model.provider cached in memory at
    # startup (see 5dive-agent-start.sh's gateway-restart leg) and the
    # operator has to know to manually `agent restart` after every BYO
    # key swap. Match cmd_account_rename's restart loop semantics.
    local _affected
    if [[ -n "$profile" ]]; then
      _affected=$(registry_read | jq -r --arg p "$profile" \
        '.agents | to_entries[] | select(.value.authProfile == $p) | .key')
    else
      _affected=$(registry_read | jq -r \
        '.agents | to_entries[] | select((.value.authProfile // "") == "") | .key')
    fi
    local _agent
    while IFS= read -r _agent; do
      [[ -n "$_agent" ]] || continue
      step "Restarting 5dive-agent@${_agent}.service"
      systemctl restart "5dive-agent@${_agent}.service" >&2 2>&1 \
        || warn "restart of agent '$_agent' failed — check journalctl -u 5dive-agent@${_agent}"
    done <<<"$_affected"

    ok "api key stored for $type/$byo_provider${profile:+ (profile=$profile)}" \
       '{type:$t, provider:$pr, profile:$p}' \
       --arg t "$type" --arg pr "$byo_provider" --arg p "${profile:-}"
    return
  fi

  # Env-var-style path (claude/codex/opencode). hermes/openclaw fall
  # off the bottom because they're not in TYPE_API_FILE — by design: their
  # credentials live in native state dirs, not env files. Pass --provider
  # to route those through apply_byo_provider above.
  local var="${TYPE_API_VAR[$type]}" fname="${TYPE_API_FILE[$type]}"
  case "$type" in
    claude)
      if [[ "$api_key" =~ ^sk-ant-oat01- ]]; then
        var="CLAUDE_CODE_OAUTH_TOKEN"
      fi ;;
  esac
  [[ -n "$var" && -n "$fname" ]] \
    || fail "$E_GENERIC" "no api-key target configured for type '$type' (hermes/openclaw require --provider=<id>)"

  require_root
  if [[ -z "$profile" ]]; then
    step "Writing ${var} to /etc/5dive/connectors/${fname}"
    printf '%s' "$api_key" | write_default_connector "$fname" "$var"
  else
    step "Writing ${var} to auth profile '${profile}'"
    printf '%s' "$api_key" | profile_set_var "$profile" "$var"
  fi

  ok "api key stored for $type${profile:+ (profile=$profile)}" \
     '{type:$t, var:$v, profile:$p}' \
     --arg t "$type" --arg v "$var" --arg p "${profile:-}"
}

cmd_auth_login() {
  local type="" profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth-profile=*) profile="${1#--auth-profile=}" ;;
      -*)               fail "$E_USAGE" "unknown flag: $1" ;;
      *)                [[ -z "$type" ]] && type="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$type" ]] || fail "$E_USAGE" "usage: 5dive agent auth login <type> [--auth-profile=<name>]"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  local bin="${TYPE_BIN[$type]}"
  [[ -x "$bin" ]] || fail "$E_NOT_INSTALLED" "$type not installed at $bin"
  if [[ -n "$profile" ]]; then
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    require_root
    ensure_profile_dir "$profile" >/dev/null
    profile_type_dir "$profile" "$type" >/dev/null
  fi
  # `auth login` is a TTY handoff (exec replaces this process), so JSON output
  # is not meaningful here. We proceed regardless of JSON_MODE — the caller
  # gets whatever the underlying login tool emits, plus the process exit code.
  # For non-TTY / dashboard flows, use `auth start|poll|submit|cancel` instead.
  echo "Launching '$type' interactive login as user 'claude'${profile:+ (profile=$profile)}..." >&2

  # When profile is set, redirect the type's state-root env var so the
  # interactive login lands in the per-profile dir — same plumbing the
  # device-code flow uses (profile_type_env). Empty when no profile, in
  # which case the legacy shared /home/claude/.<type> remains the target.
  local extra_env=""
  if [[ -n "$profile" ]]; then
    extra_env=$(profile_type_env "$profile" "$type") \
      || fail "$E_GENERIC" "profile_type_env: no plumbing for type '$type'"
  fi

  case "$type" in
    claude)
      # claude setup-token only displays the token on stdout — it doesn't
      # write anywhere on disk. Without capture, the wrapper has no way to
      # promote the token into combined.env (profile case) or anthropic.env
      # (default case), so `5dive account show` reports types=- even after
      # a successful login. Use `script(1)` to tee stdout to a log file
      # while keeping the interactive TTY working, then post-process with
      # extract_claude_token (shared with the device-code flow).
      #
      # CLAUDE_CONFIG_DIR (passed via $extra_env when profile is set)
      # overrides claude's default ~/.claude location for config; the
      # token itself isn't persisted by claude anywhere — only printed.
      require_root
      local log rc=0
      log=$(sudo -u claude mktemp /tmp/5dive-claude-login.XXXXXX.log)
      sudo -u claude -i env $extra_env script -fq -c "$bin setup-token" "$log" || rc=$?
      local tok=""
      tok=$(extract_claude_token "$log" 2>/dev/null || true)
      # Token transited through this file — shred so it doesn't linger.
      sudo -u claude shred -u "$log" 2>/dev/null || sudo -u claude rm -f "$log"
      if [[ -z "$tok" ]]; then
        (( rc != 0 )) \
          && fail "$E_GENERIC" "claude setup-token exited with code $rc"
        fail "$E_GENERIC" "no OAuth token found in setup-token output — login may have been cancelled"
      fi
      if [[ -n "$profile" ]]; then
        step "Writing CLAUDE_CODE_OAUTH_TOKEN to auth profile '${profile}'"
        printf '%s' "$tok" | profile_set_var "$profile" "CLAUDE_CODE_OAUTH_TOKEN"
      else
        step "Writing CLAUDE_CODE_OAUTH_TOKEN to /etc/5dive/connectors/anthropic.env"
        printf '%s' "$tok" | write_default_connector "anthropic.env" "CLAUDE_CODE_OAUTH_TOKEN"
      fi
      # DIVE-383: a fresh token only reaches a running agent on restart.
      restart_profile_agents "$profile"
      ok "claude OAuth token stored${profile:+ (profile=$profile)}" \
         '{type:$t, var:$v, profile:$p}' \
         --arg t "claude" --arg v "CLAUDE_CODE_OAUTH_TOKEN" --arg p "${profile:-}"
      return ;;
    hermes)
      # hermes signs in to OpenAI via its own device-code flow. Run it
      # interactively so the user can see the URL/code and Ctrl+C cleanly.
      exec sudo -u claude -i env $extra_env "$bin" auth add openai-codex ;;
    openclaw)
      # openclaw runs the same OpenAI /codex/device flow as hermes, but it
      # routes through `models auth login`. openclaw 2026.6.6 renamed the
      # flags (DIVE-297): provider id is now `openai` (was `openai-codex`)
      # and the device method is the boolean `--device-code` (was `--method
      # device-code`); the old form fails "No provider plugins found" before
      # any prompt. --provider + --device-code skip the @clack/prompts pickers,
      # and --set-default applies the provider's default model so no follow-on
      # `models set` is needed. DISPLAY=:0 forces isRemote=false in
      # infra/remote-env.ts so the user-code prints inline (else openclaw
      # redacts it as "[shown on the local device only]").
      # Profile-scoped: extra_env is HOME=<profile_dir>/openclaw, so
      # resolveStateDir lands at $HOME/.openclaw inside the profile dir.
      if [[ -n "$extra_env" ]]; then
        local oc_home
        oc_home=$(profile_type_dir "$profile" "$type")
        install -d -m 2750 -o claude -g claude \
          "${oc_home}/.openclaw" \
          "${oc_home}/.openclaw/agents" \
          "${oc_home}/.openclaw/agents/main" \
          "${oc_home}/.openclaw/agents/main/agent" 2>/dev/null || true
      fi
      exec sudo -u claude -i env DISPLAY=:0 $extra_env "$bin" \
        models auth login --provider openai --device-code --set-default ;;
    codex)
      # codex's plain `login` starts an interactive browser OAuth with a
      # localhost:1455 callback server — broken on a remote/headless box (codex
      # itself prints "On a remote or headless machine? Use codex login
      # --device-auth instead."). --device-auth prints a URL + one-time code and
      # the CLI polls OpenAI itself, so the same flow works over SSH with no
      # local browser — same shape grok/hermes use and the dashboard
      # device-code flow already drives (cmd_auth_start). DIVE-1178.
      # CODEX_HOME (when profiled) overrides /etc/profile.d's default.
      exec sudo -u claude -i env $extra_env bash -lc 'codex login --device-auth' ;;
    antigravity)
      # agy has no `auth login` subcommand — OAuth fires automatically the
      # first time the binary needs a token. Use the interactive TUI
      # (`--prompt-interactive ping`) rather than `--print ping`: print mode
      # caps the OAuth wait at 30s, but the interactive TUI waits indefinitely
      # for the pasted code. Run directly at the terminal here, the user picks
      # "Google OAuth", opens the printed URL, and pastes the authorization
      # code — no 30s race.
      exec sudo -u claude -i env $extra_env bash -lc 'agy --prompt-interactive ping' ;;
    grok)
      # grok has both an interactive UI OAuth (localhost callback, no good
      # for headless VMs) and a dedicated --device-auth flag (URL + 4-dash-4
      # user code, CLI polls). Use --device-auth so the same flow works
      # whether we're invoked from a real TTY or via the tmux+script(1)
      # bridge that powers the dashboard's device-code flow.
      exec sudo -u claude -i env $extra_env bash -lc 'grok login --device-auth' ;;
    opencode) exec sudo -u claude -i bash -lc 'opencode auth login' ;;
  esac
}

# -------- non-TTY device-code flow (dashboard-driven) --------
#
# Lifecycle:
#   start   -> spawn the CLI's device-code login (claude setup-token / codex
#              login --device-auth / ...) in a detached tmux session owned by
#              `claude`, teed through script(1) into login.log so we can grep
#              OAuth URL / one-time code / success markers. Returns a session id.
#   poll    -> report state (pending_url|awaiting_code|ok|expired|error). The
#              dashboard calls this on a timer and displays whatever fields
#              are populated (url + optional code while awaiting_code, error on
#              error).
#   submit  -> claude only: feed the user-pasted callback code into the
#              tmux session. codex/hermes/openclaw don't have a submit
#              step — the CLI polls OpenAI itself and writes its credential
#              file on success, which poll detects via file mtime.
#   cancel  -> kill the tmux session.
#
# Wired for: claude (Anthropic setup-token, url + pasted callback code) and
# codex/hermes/openclaw (OpenAI /codex/device device-auth, url + displayed
# one-time code, no callback paste, mtime-based success detection on each
# CLI's credential file). opencode still falls back to TTY `auth login` or
# `auth set --api-key`.

require_auth_session_root() {
  require_root
  mkdir -p "$AUTH_SESSIONS_DIR"
  chown root:claude "$AUTH_SESSIONS_DIR"
  chmod 2750 "$AUTH_SESSIONS_DIR"
}

# Path to a session's dir, or die if unknown. Session ids are lowercase hex,
# so the regex rejects path traversal attempts cleanly.
auth_session_dir() {
  local sid="$1"
  [[ "$sid" =~ ^[0-9a-f]{16}$ ]] \
    || fail "$E_VALIDATION" "invalid session id"
  local dir="${AUTH_SESSIONS_DIR}/${sid}"
  [[ -d "$dir" ]] \
    || fail "$E_NOT_FOUND" "no such auth session: $sid"
  echo "$dir"
}

# Extract the OAuth URL from a claude setup-token PTY log. claude v2.1.119
# emits the URL in two places:
#   1. as the target of an OSC 8 hyperlink escape: `ESC]8;id=<id>;<URL>BEL<text>ESC]8;;BEL`
#      — this is the clean, unwrapped form.
#   2. as the visible `<text>`, hard-wrapped across ~6 lines with CSI
#      cursor-forward escapes between fragments.
#
# We prefer (1) because it's contiguous. Python does the scan — awk and
# grep both had edge cases on the OSC delimiter (BEL isn't easy to express
# portably, and earlier grep attempts stopped mid-URL at embedded CSI
# escapes inserted by the animation frame).
extract_claude_url() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  python3 - "$log" <<'PY' 2>/dev/null || true
import re, sys
data = open(sys.argv[1], 'rb').read()
# OSC 8 hyperlink: ESC ] 8 ; <params> ; <URL> BEL <text> ESC ] 8 ; ; BEL
# <URL> ends at the BEL (\x07) that precedes the visible text.
m = re.search(rb'\x1b\]8;[^;]*;(https://claude\.com/[^\x07]+)\x07', data)
if m:
    print(m.group(1).decode('utf-8', 'replace'))
    sys.exit(0)
# Fallback: strip CSI + BEL + CR, then scan for a plain URL. Covers
# future claude versions that drop the OSC 8 wrapper.
clean = re.sub(rb'\x1b\[[0-9;]*[A-Za-z]', b'', data)
clean = re.sub(rb'[\x07\r]', b'', clean)
m = re.search(rb'https://claude\.com/[A-Za-z0-9._~:/?#=&%+_-]{20,600}', clean)
if m:
    print(m.group(0).decode('utf-8', 'replace'))
PY
}

# Pull the long-lived OAuth token out of the login log after the user has
# pasted their callback code. claude setup-token prints the literal token
# on success; grep returns the last match (tolerant of noisy output).
extract_claude_token() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE 'sk-ant-oat01-[A-Za-z0-9_-]+' \
    | tail -1 | sed 's/Store$//'
}

# grok login --device-auth prints `https://accounts.x.ai/oauth2/device?user_code=
# <4-dash-4>` as the device URL plus a separately-displayed user code in the
# same `<4-dash-4>` format (e.g. `XJ9P-ZW8T`). Strip CSI escapes first since
# grok renders the code in a colored block. The URL is the canonical anchor;
# code is a friendly fallback for users who want to type instead of click.
extract_grok_url() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE 'https://accounts\.x\.ai/oauth2/device\?[A-Za-z0-9._~:/?#=&%+_-]+' \
    | head -1
}

extract_grok_code() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  # 4-dash-4 uppercase-alphanumeric. Codex uses 4-dash-5, so we can't share
  # extract_codex_code — different anchor lengths reject the wrong shape.
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE '\b[0-9A-Z]{4}-[0-9A-Z]{4}\b' \
    | head -1
}

# antigravity prints `Authentication required. Please visit the URL to log in:`
# followed by a Google OAuth URL with redirect_uri=antigravity.google/oauth-
# callback on a single (possibly wrapped) line, then a "Or, paste the
# authorization code here and press Enter" prompt. The URL anchor is the
# accounts.google.com prefix; we accept both /o/oauth2/auth and /o/oauth2/v2/auth.
extract_antigravity_url() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE 'https://accounts\.google\.com/o/oauth2/(v2/)?auth\?[A-Za-z0-9._~:/?#=&%+_-]{40,2000}' \
    | head -1
}

# codex login --device-auth prints a static device URL plus a one-time code
# like `06LC-O1CRK`. Both are wrapped in CSI color escapes, so strip those
# first. The URL is currently hard-coded but we still parse it so a future
# codex release that personalises it keeps working without a CLI change.
extract_codex_url() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE 'https://auth\.openai\.com/codex/device[A-Za-z0-9._~:/?#=&%+-]*' \
    | head -1
}

extract_codex_code() {
  local log="$1"
  [[ -s "$log" ]] || return 1
  # Match the 4-dash-5 uppercase-alphanumeric pattern that codex prints as
  # the one-time code. Anchors to word boundaries to avoid hex snippets.
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r//g' "$log" \
    | grep -oE '\b[0-9A-Z]{4}-[0-9A-Z]{5}\b' \
    | head -1
}

cmd_auth_start() {
  local type="" profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth-profile=*) profile="${1#--auth-profile=}" ;;
      -*)               fail "$E_USAGE" "unknown flag: $1" ;;
      *)                [[ -z "$type" ]] && type="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$type" ]] || fail "$E_USAGE" "usage: 5dive agent auth start <type> [--auth-profile=<name>]"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  case "$type" in
    claude|hermes|openclaw|codex|antigravity|grok) ;;
    *) fail "$E_VALIDATION" "device-code flow supports claude/hermes/openclaw/codex/antigravity/grok. Use 'auth set --api-key' or 'auth login' for $type." ;;
  esac
  local bin="${TYPE_BIN[$type]}"
  [[ -x "$bin" ]] || fail "$E_NOT_INSTALLED" "$type not installed at $bin"
  if [[ -n "$profile" ]]; then
    valid_profile_name "$profile" \
      || fail "$E_VALIDATION" "invalid --auth-profile (lowercase letters/digits/_-, start letter, <=32 chars)"
    ensure_profile_dir "$profile" >/dev/null
    # Pre-create the per-type state dir so the device-flow CLI has somewhere
    # to land its credential file. profile_type_env below points the right
    # env var at this dir per type.
    profile_type_dir "$profile" "$type" >/dev/null
  fi

  require_auth_session_root
  local sid dir
  sid=$(gen_session_id)
  dir="${AUTH_SESSIONS_DIR}/${sid}"
  mkdir -p "$dir"
  chown claude:claude "$dir"
  chmod 2750 "$dir"

  local log="${dir}/login.log"
  : > "$log"
  chown claude:claude "$log"
  chmod 640 "$log"

  # For codex, the success signal is a fresh credential file
  # (~/.codex/auth.json) — record the file's current mtime so poll can tell
  # a pre-existing login apart from the one this session produced. Missing
  # file ⇒ baseline 0, which any write beats. When profile is set, the
  # sentinel lives under the per-profile state dir (profile_type_auth_path),
  # not the shared /home/claude/.<type>.
  local auth_baseline=0
  case "$type" in
    codex|hermes|openclaw|antigravity|grok)
      local sentinel
      sentinel=$(profile_type_auth_path "$profile" "$type")
      if [[ -n "$sentinel" && -f "$sentinel" ]]; then
        auth_baseline=$(stat -c %Y "$sentinel" 2>/dev/null || echo 0)
      fi
      ;;
  esac

  jq -n --arg t "$type" --arg p "$profile" --arg s "pending_url" \
        --arg ts "$(date -Iseconds)" --arg sid "$sid" \
        --argjson ab "$auth_baseline" '{
    sessionId: $sid, type: $t, profile: $p, state: $s,
    url: null, code: null, error: null,
    authBaselineMtime: $ab,
    createdAt: $ts, updatedAt: $ts
  }' > "${dir}/meta.json"
  chmod 640 "${dir}/meta.json"
  chown claude:claude "${dir}/meta.json"

  # tmux session owned by `claude` so it shares the existing nvm/PATH setup
  # and any captured tokens end up in a path we can read back. Name includes
  # the sid so parallel sessions don't collide.
  local session="auth-${sid}"
  # Each session gets its own tmux socket under the session dir. Lets us
  # send-keys later without guessing which tmux server hosts it.
  local sock="${dir}/tmux.sock"

  # If profile set, redirect the type's state-root env var (CLAUDE_CONFIG_DIR /
  # CODEX_HOME / HERMES_HOME / HOME for openclaw) so the device-flow CLI
  # writes its credential file into the profile dir instead of the shared
  # /home/claude/.<type>. Two agents on different profiles can then re-auth
  # independently without overwriting each other. For claude, the extracted
  # token is also promoted into combined.env for systemd; for the others, the
  # credential file under the profile dir is the durable artifact and
  # 5dive-agent-start.sh seeds the agent's $HOME/.<type> from there.
  local extra_env=""
  if [[ -n "$profile" ]]; then
    extra_env=$(profile_type_env "$profile" "$type") \
      || fail "$E_GENERIC" "profile_type_env: no plumbing for type '$type'"
  fi
  # The CLI invocation differs per family: claude-setup-token prints a URL
  # and waits for a pasted callback code; codex prints a URL + one-time code
  # and polls the OAuth endpoint itself, so there's no submit step.
  local login_cmd preseed=""
  case "$type" in
    codex)  login_cmd="$bin login --device-auth" ;;
    antigravity)
      # agy's print mode (`--print ping`) hard-caps the interactive OAuth wait
      # at 30s ("Print mode: auth timed out") — far too short for a human to
      # finish Google sign-in and paste the code back through the dashboard.
      # The session dies, no antigravity-oauth-token is written, and
      # `agent create` then correctly rejects the empty profile. So drive auth
      # through the INTERACTIVE TUI instead (`--prompt-interactive ping`),
      # which waits indefinitely for the pasted authorization code. The TUI
      # first shows a login-method menu (Google OAuth pre-selected) and renders
      # the OAuth URL inside the TUI rather than the script log — cmd_auth_poll
      # presses Enter to pick the method and scrapes the URL from the pane (see
      # the antigravity branch there + the wide pane in the spawn below).
      login_cmd="$bin --prompt-interactive ping" ;;
    grok)
      # `grok login --device-auth` prints accounts.x.ai/oauth2/device + a
      # 4-dash-4 user code, polls the device-auth endpoint itself, and
      # writes ~/.grok/auth.json on success. Same UX shape as codex's
      # --device-auth (URL + displayed code, no callback paste).
      login_cmd="$bin login --device-auth" ;;
    hermes)
      # hermes auth add openai-codex prints a URL + one-time code (codex-style
      # device-auth via OpenAI), polls itself, then writes ~/.hermes/auth.json
      # on success. Same UX shape as codex from the wizard's POV.
      login_cmd="$bin auth add openai-codex" ;;
    openclaw)
      # openclaw routes the same OpenAI /codex/device flow through
      # `models auth login`. 2026.6.6 flag rename (DIVE-297): --provider openai
      # (was openai-codex) + --device-code (was --method device-code), else it
      # fails "No provider plugins found" before any prompt. --provider +
      # --device-code short-circuit the @clack/prompts pickers so no
      # interactive prompts appear before the URL+code print. --set-default
      # applies the provider's default model. DISPLAY=:0 forces
      # isRemoteEnvironment() to return false so the user-code is logged
      # inline (otherwise infra/remote-env.ts treats headless Linux as
      # remote and openclaw redacts the code as "[shown on the local
      # device only]"). The opener falls through to "Open manually:" since
      # there's no real X server, which is exactly what we want.
      preseed='export DISPLAY=:0; '
      # When profile-scoped, openclaw's HOME is empty — pre-create the
      # nested state dirs so resolveAgentDir + upsertAuthProfile can write
      # auth-profiles.json without first-run mkdir races.
      if [[ -n "$profile" ]]; then
        local oc_home
        oc_home=$(profile_type_dir "$profile" "$type")
        install -d -m 2750 -o claude -g claude \
          "${oc_home}/.openclaw" \
          "${oc_home}/.openclaw/agents" \
          "${oc_home}/.openclaw/agents/main" \
          "${oc_home}/.openclaw/agents/main/agent" 2>/dev/null || true
      fi
      login_cmd="$bin models auth login --provider openai --device-code --set-default" ;;
    *)      login_cmd="$bin setup-token" ;;
  esac

  step "Starting device-code session $sid for $type${profile:+ (profile=$profile)}"
  # script(1) gives us a PTY so the CLI renders normally; -f flushes after
  # every write so the poll loop sees the URL/code seconds after they print.
  # bash -lc (login shell) sources /etc/profile.d/5dive-shared-configs.sh, so
  # CODEX_HOME points at /home/claude/.codex and the auth.json lands in the
  # shared location every agent-<name> login shell already reads.
  #
  # antigravity renders its OAuth URL inside the interactive TUI (alt-screen),
  # so cmd_auth_poll scrapes it via `tmux capture-pane` rather than $log. The
  # URL is ~650 chars; a normal-width pane hard-wraps it and the scrape would
  # truncate. Give agy a very wide pane so the whole URL stays on one logical
  # line. Other types print the URL to $log, where pane width is irrelevant.
  local pane_width=200
  [[ "$type" == "antigravity" ]] && pane_width=700
  sudo -u claude -H bash -lc "
    ${preseed}
    tmux -S '$sock' new-session -d -s '$session' -x $pane_width -y 50 \
      'env $extra_env script -q -f -c \"$login_cmd\" $log'
  " >&2 || fail "$E_GENERIC" "failed to spawn tmux session"

  ok "device-code session started" \
     '{sessionId:$s, type:$t, profile:$p, state:"pending_url"}' \
     --arg s "$sid" --arg t "$type" --arg p "${profile:-}"
}

cmd_auth_poll() {
  local sid="${1:-}"
  [[ -n "$sid" ]] || fail "$E_USAGE" "usage: 5dive agent auth poll <session_id>"
  local dir
  dir=$(auth_session_dir "$sid")
  local meta="${dir}/meta.json"
  local log="${dir}/login.log"
  local sock="${dir}/tmux.sock"
  local session="auth-${sid}"

  local state type profile
  state=$(jq -r '.state' "$meta")
  type=$(jq -r '.type' "$meta")
  profile=$(jq -r '.profile' "$meta")

  # Terminal states are returned as-is; don't reprobe.
  case "$state" in
    ok|expired|error) : ;;
    *)
      # Still running? If the tmux session is gone and we never reached ok,
      # mark expired so the dashboard stops polling.
      local alive=1
      sudo -u claude tmux -S "$sock" has-session -t "$session" 2>/dev/null \
        || alive=0

      if [[ "$state" == "pending_url" ]]; then
        case "$type" in
          codex|hermes|openclaw)
            # codex, hermes, and openclaw all go through OpenAI's
            # /codex/device endpoint and print a URL + a one-time code.
            # Wait until both are visible before advancing so the dashboard
            # never renders one without the other. The extractors are
            # URL/code-shape based, not vendor-specific, so they work for
            # all three (openclaw renders the URL/code via @clack/prompts
            # note, but stripping CSI escapes leaves the URL + 4-5 alnum
            # code intact).
            local url code_display
            url=$(extract_codex_url "$log" || true)
            code_display=$(extract_codex_code "$log" || true)
            if [[ -n "$url" && -n "$code_display" ]]; then
              state="awaiting_code"
              jq --arg u "$url" --arg c "$code_display" --arg s "$state" \
                 --arg ts "$(date -Iseconds)" \
                 '.url = $u | .code = $c | .state = $s | .updatedAt = $ts' "$meta" \
                 > "${meta}.tmp" && mv "${meta}.tmp" "$meta"
            fi
            ;;
          antigravity)
            # agy runs as an interactive TUI (no 30s print-mode cap). It first
            # shows a login-method menu with "Google OAuth" pre-selected, then
            # — once that's chosen — renders the OAuth URL + a "paste the
            # authorization code" prompt INSIDE the TUI (not $log). So scrape
            # the live pane: press Enter once to dismiss the menu, then pull the
            # URL out. The pane is spawned wide (cmd_auth_start) so the
            # ~650-char URL isn't wrapped/truncated. capture-pane -J rejoins
            # soft-wrapped lines; -S -400 includes scrollback in case the menu
            # has scrolled the URL up.
            local pane="${dir}/pane.txt"
            sudo -u claude tmux -S "$sock" capture-pane -p -J -S -400 \
              -t "$session" > "$pane" 2>/dev/null || true
            # Select "Google OAuth" exactly once, only while the menu is shown.
            if [[ ! -e "${dir}/.oauth_selected" ]] \
               && grep -qiE 'select login method|google oauth' "$pane"; then
              sudo -u claude tmux -S "$sock" send-keys -t "$session" Enter 2>/dev/null || true
              : > "${dir}/.oauth_selected"
            fi
            local url
            url=$(extract_antigravity_url "$pane" || true)
            if [[ -n "$url" ]]; then
              state="awaiting_code"
              jq --arg u "$url" --arg s "$state" --arg ts "$(date -Iseconds)" \
                '.url = $u | .state = $s | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
            fi
            ;;
          grok)
            # codex-style: URL + displayed code, CLI polls. Advance once
            # both have appeared so the dashboard never renders one without
            # the other.
            local url code_display
            url=$(extract_grok_url "$log" || true)
            code_display=$(extract_grok_code "$log" || true)
            if [[ -n "$url" && -n "$code_display" ]]; then
              state="awaiting_code"
              jq --arg u "$url" --arg c "$code_display" --arg s "$state" \
                 --arg ts "$(date -Iseconds)" \
                 '.url = $u | .code = $c | .state = $s | .updatedAt = $ts' "$meta" \
                 > "${meta}.tmp" && mv "${meta}.tmp" "$meta"
            fi
            ;;
          *)
            local url
            url=$(extract_claude_url "$log" || true)
            if [[ -n "$url" ]]; then
              state="awaiting_code"
              jq --arg u "$url" --arg s "$state" --arg ts "$(date -Iseconds)" \
                '.url = $u | .state = $s | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
            fi
            ;;
        esac
      fi

      if [[ "$state" == "awaiting_code" || "$state" == "submitted" ]]; then
        case "$type" in
          codex|hermes|openclaw|antigravity|grok)
            # All five signal success by writing a credential file:
            #   codex       — ~/.codex/auth.json     (CLI polls OpenAI itself)
            #   hermes      — ~/.hermes/auth.json    (CLI polls OpenAI itself)
            #   openclaw    — ~/.openclaw/agents/main/agent/auth-profiles.json
            #                 (CLI polls OpenAI itself, then upsertAuthProfile
            #                 writes the file synchronously before exit)
            #   antigravity — ~/.gemini/antigravity-cli/antigravity-oauth-token
            #                 (Google OAuth callback or pasted code; mtime
            #                 bumps once token_storage's file fallback writes
            #                 the bare token blob, mode 0600)
            #   grok        — ~/.grok/auth.json
            #                 (CLI polls xAI's device-auth endpoint, writes
            #                 auth.json on token receipt)
            # When this session is profile-scoped, the credential lands under
            # the per-profile state dir (profile_type_auth_path) instead of
            # the shared ~/.<type>. We mtime the sentinel against the
            # baseline captured at session start so a pre-existing login
            # can't masquerade as success.
            local sentinel baseline current
            sentinel=$(profile_type_auth_path "$profile" "$type")
            baseline=$(jq -r '.authBaselineMtime // 0' "$meta")
            current=0
            if [[ -f "$sentinel" ]]; then
              current=$(stat -c %Y "$sentinel" 2>/dev/null || echo 0)
            fi
            if (( current > baseline )); then
              sudo -u claude tmux -S "$sock" kill-session -t "$session" 2>/dev/null || true
              state="ok"
              jq --arg s "$state" --arg ts "$(date -Iseconds)" \
                '.state = $s | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
              # DIVE-383: the fresh credential file is seeded into the agent's
              # $HOME at boot, so a running agent needs a restart to load it.
              restart_profile_agents "$profile"
            elif (( ! alive )); then
              # CLI quit without producing a fresh credential file — the user
              # cancelled, the OAuth window expired, or the CLI errored out
              # before writing creds.
              state="error"
              jq --arg s "$state" --arg e "$type exited without writing $sentinel (cancelled, expired, bad code, or failed)" \
                 --arg ts "$(date -Iseconds)" \
                 '.state = $s | .error = $e | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
            fi
            ;;
          *)
            local tok
            tok=$(extract_claude_token "$log" || true)
            if [[ -n "$tok" ]]; then
              # Promote the captured token into its destination + tear down the
              # tmux session. Safe to re-run if the user hits poll again.
              if [[ -n "$profile" ]]; then
                printf '%s' "$tok" | profile_set_var "$profile" "CLAUDE_CODE_OAUTH_TOKEN"
              else
                printf '%s' "$tok" | write_default_connector "anthropic.env" "CLAUDE_CODE_OAUTH_TOKEN"
              fi
              sudo -u claude tmux -S "$sock" kill-session -t "$session" 2>/dev/null || true
              state="ok"
              jq --arg s "$state" --arg ts "$(date -Iseconds)" \
                '.state = $s | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
              # DIVE-383: a fresh token only reaches a running agent on restart.
              restart_profile_agents "$profile"
            elif (( ! alive )); then
              # tmux session died before we saw a token — usually means the user
              # pasted a bad code and claude exited non-zero.
              state="error"
              jq --arg s "$state" --arg e "login process exited without writing a token (bad callback code?)" \
                 --arg ts "$(date -Iseconds)" \
                 '.state = $s | .error = $e | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
                && mv "${meta}.tmp" "$meta"
            fi
            ;;
        esac
      fi

      if [[ "$state" == "pending_url" && "$alive" == "0" ]]; then
        state="error"
        jq --arg s "$state" --arg e "login process exited before printing an OAuth URL" \
           --arg ts "$(date -Iseconds)" \
           '.state = $s | .error = $e | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
          && mv "${meta}.tmp" "$meta"
      fi
      ;;
  esac

  if (( JSON_MODE )); then
    jq -c '{ok:true, data: .}' "$meta"
  else
    jq -r '"sessionId: \(.sessionId)\ntype:      \(.type)\nprofile:   \(.profile // "-")\nstate:     \(.state)\nurl:       \(.url // "-")\ncode:      \(.code // "-")\nerror:     \(.error // "-")\nupdatedAt: \(.updatedAt)"' "$meta"
  fi
}

cmd_auth_submit() {
  local sid="" code=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --code=*) code="${1#--code=}" ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        [[ -z "$sid" ]] && sid="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$sid" && -n "$code" ]] \
    || fail "$E_USAGE" "usage: 5dive agent auth submit <session_id> --code=<callback-code>"

  # Callback code is URL-safe base64 (`[A-Za-z0-9_-]+`), optional `#fragment`.
  # Allow `/` and `.` so future provider shapes pass; we still refuse spaces,
  # quotes, backticks etc. so tmux send-keys -l never sees something wild.
  [[ "$code" =~ ^[A-Za-z0-9._/-]+#?[A-Za-z0-9._/-]*$ ]] \
    || fail "$E_VALIDATION" "callback code contains unexpected characters"

  local dir
  dir=$(auth_session_dir "$sid")
  local meta="${dir}/meta.json"
  local sock="${dir}/tmux.sock"
  local session="auth-${sid}"

  local state type
  state=$(jq -r '.state' "$meta")
  type=$(jq -r '.type' "$meta")
  # codex/hermes/grok never ask for a pasted callback — the CLI polls the
  # OAuth endpoint on its own and writes auth.json. Submitting here would
  # wedge keystrokes into a prompt that doesn't exist. antigravity DOES
  # accept a pasted code at its "Or, paste the authorization code here"
  # prompt, so the submit step IS valid for it.
  case "$type" in
    codex|hermes|grok) fail "$E_VALIDATION" "$type device-auth has no submit step — keep polling until state=ok or state=error" ;;
  esac
  case "$state" in
    awaiting_code|submitted) ;;   # submitted -> retry after a rejected code
    pending_url)                  fail "$E_VALIDATION" "session not yet awaiting a code — poll until url is populated" ;;
    ok|expired|error)             fail "$E_VALIDATION" "session already in terminal state: $state" ;;
    *)                            fail "$E_VALIDATION" "session in unexpected state: $state" ;;
  esac

  sudo -u claude tmux -S "$sock" has-session -t "$session" 2>/dev/null \
    || fail "$E_NOT_RUNNING" "login tmux session is gone — start a new auth session"

  step "Submitting code to session $sid"
  # If claude left a half-typed retry prompt on screen from a prior rejected
  # code, send C-u first to clear the line so we don't paste onto tail of
  # the previous attempt.
  sudo -u claude tmux -S "$sock" send-keys -t "$session" C-u 2>/dev/null || true
  sudo -u claude tmux -S "$sock" send-keys -t "$session" -l -- "$code"
  sudo -u claude tmux -S "$sock" send-keys -t "$session" Enter

  jq --arg s "submitted" --arg ts "$(date -Iseconds)" \
     '.state = $s | .updatedAt = $ts' "$meta" > "${meta}.tmp" \
    && mv "${meta}.tmp" "$meta"

  ok "code submitted — poll for final state" \
     '{sessionId:$s, state:"submitted"}' --arg s "$sid"
}

cmd_auth_cancel() {
  local sid="${1:-}"
  [[ -n "$sid" ]] || fail "$E_USAGE" "usage: 5dive agent auth cancel <session_id>"
  local dir
  dir=$(auth_session_dir "$sid")
  local meta="${dir}/meta.json"
  local sock="${dir}/tmux.sock"
  local session="auth-${sid}"

  sudo -u claude tmux -S "$sock" kill-session -t "$session" 2>/dev/null || true
  jq --arg s "expired" --arg ts "$(date -Iseconds)" \
     '.state = (if (.state == "ok") then "ok" else $s end) | .updatedAt = $ts' "$meta" \
     > "${meta}.tmp" && mv "${meta}.tmp" "$meta"

  ok "session cancelled" \
     '{sessionId:$s, state:"expired"}' --arg s "$sid"
}
