
# -------- accounts (top-level noun over auth profiles) --------
#
# An "account" is the user-facing name for an auth profile. Storage and
# helpers live above (AUTH_PROFILES_DIR, ensure_profile_dir,
# profile_type_auth_path, link_agent_profile). These commands give it a
# first-class CLI surface so users don't have to think in terms of the
# split `agent auth set/start/login --auth-profile=<name>` verbs. The
# legacy `agent auth ...` commands keep working unchanged for back-compat
# and for the dashboard's device-code flow.

# account_agents_bound <name> — emit a JSON array of agent names whose
# registry .authProfile equals <name>. Empty array if none. Used by list,
# show, rename (to recover affected agents) and remove (refusal payload).
account_agents_bound() {
  local name="$1"
  ensure_state_ro
  registry_read | jq -c --arg p "$name" \
    '[.agents | to_entries[] | select(.value.authProfile == $p) | .key]'
}

# account_types_authed <name> — JSON array of types whose credential
# sentinel exists under the profile dir. Mirrors auth_creds_present but
# scoped to a specific profile (no shared-config fallback).
account_types_authed() {
  local name="$1" type path out="[]"
  for type in "${!TYPE_BIN[@]}"; do
    path=$(profile_type_auth_path "$name" "$type" 2>/dev/null) || continue
    [[ -n "$path" && -s "$path" ]] || continue
    out=$(jq -c --arg t "$type" '. + [$t]' <<<"$out")
  done
  # Also surface env-var-only credentials (api keys written by `auth set`)
  # — combined.env carries them without a per-type credential file.
  local env_file="${AUTH_PROFILES_DIR}/${name}/combined.env"
  if [[ -s "$env_file" ]]; then
    for type in "${!TYPE_API_VAR[@]}"; do
      local var="${TYPE_API_VAR[$type]}"
      if grep -q "^${var}=" "$env_file" 2>/dev/null \
         || ([[ "$type" == "claude" ]] && grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" "$env_file" 2>/dev/null); then
        # Dedup: skip if already added via per-type sentinel above.
        if ! jq -e --arg t "$type" 'index($t) != null' <<<"$out" >/dev/null; then
          out=$(jq -c --arg t "$type" '. + [$t]' <<<"$out")
        fi
      fi
    done
  fi
  echo "$out"
}

# account_signin_detail <name> <type> — per-(profile, type) sign-in detail
# for the new-agent wizard's "Which sign-in?" tile. Emits {provider, model,
# signedInAt} JSON; any field that can't be cheaply extracted comes back
# null. Returns "{}" (not failure) when the type isn't signed into the
# profile, so callers can ignore missing detail without conditional plumbing.
#
# hermes: active provider is config.yaml model.provider (the value the
# gateway loads at startup). credential_pool keys is only a fallback for
# pre-config-write profiles — its insertion order is not a source of
# truth, so reading `keys | first` makes the dashboard badge lie when
# a user adds a second credential (codex stays first, badge stays
# codex, even after model.provider flips to openrouter). openclaw:
# first profile's provider from auth-profiles.json. Everything else
# just gets a signedInAt mtime so the tile can at least show *when*
# the user signed in.
account_signin_detail() {
  local name="$1" type="$2"
  local profile_dir="${AUTH_PROFILES_DIR}/${name}"
  local auth_path provider=null model=null signed_at=null credentials='[]'
  case "$type" in
    hermes)
      auth_path="${profile_dir}/hermes/auth.json"
      [[ -s "$auth_path" ]] || { echo "{}"; return; }
      signed_at=$(jq -c '.updated_at // null' "$auth_path" 2>/dev/null) || signed_at=null
      # Every key in credential_pool is a separately-usable sign-in within
      # this profile. The dashboard renders one row per credential in the
      # Switch account modal so users can flip between providers that
      # share an auth-profile without re-running the sign-in wizard.
      credentials=$(jq -c '(.credential_pool // {}) | keys' "$auth_path" 2>/dev/null) \
        || credentials='[]'
      local cfg="${profile_dir}/hermes/config.yaml"
      if [[ -s "$cfg" ]]; then
        # Parse the `provider:` line scoped to the `model:` block — a top-
        # level grep would also match `model.providers:` / nested provider
        # entries elsewhere in the file.
        local provider_line
        provider_line=$(awk '
          /^model:/ { in_model=1; next }
          in_model && /^[^[:space:]]/ { in_model=0 }
          in_model && /^[[:space:]]+provider:/ {
            sub(/^[[:space:]]+provider:[[:space:]]*/, "")
            sub(/^["'\'']/, ""); sub(/["'\'']$/, "")
            print; exit
          }
        ' "$cfg" 2>/dev/null)
        [[ -n "$provider_line" ]] && provider=$(jq -cn --arg p "$provider_line" '$p')
        local default_line
        default_line=$(grep -E '^[[:space:]]*default:' "$cfg" 2>/dev/null | head -1 \
          | sed -E 's/^[[:space:]]*default:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')
        [[ -n "$default_line" ]] && model=$(jq -cn --arg m "$default_line" '$m')
      fi
      # Fall back to the first credential-pool key only if config.yaml
      # didn't yield a provider (cold profile or pre-config-write state).
      if [[ "$provider" == "null" ]]; then
        provider=$(jq -c '(.credential_pool // {}) | keys | first // null' \
          "$auth_path" 2>/dev/null) || provider=null
      fi
      ;;
    openclaw)
      auth_path="${profile_dir}/openclaw/.openclaw/agents/main/agent/auth-profiles.json"
      [[ -s "$auth_path" ]] || { echo "{}"; return; }
      provider=$(jq -c '
        (.profiles // {}) | [.[]?.provider?] | map(select(.!=null)) | first // null
      ' "$auth_path" 2>/dev/null) || provider=null
      credentials=$(jq -c '
        (.profiles // {}) | [.[]?.provider?] | map(select(.!=null)) | unique
      ' "$auth_path" 2>/dev/null) || credentials='[]'
      local mtime
      mtime=$(date -u -r "$auth_path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      [[ -n "$mtime" ]] && signed_at=$(jq -cn --arg s "$mtime" '$s')
      ;;
    *)
      auth_path=$(profile_type_auth_path "$name" "$type" 2>/dev/null) || true
      [[ -n "$auth_path" && -s "$auth_path" ]] || { echo "{}"; return; }
      local mtime
      mtime=$(date -u -r "$auth_path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
      [[ -n "$mtime" ]] && signed_at=$(jq -cn --arg s "$mtime" '$s')
      ;;
  esac
  jq -cn --argjson p "$provider" --argjson m "$model" --argjson s "$signed_at" \
        --argjson c "$credentials" \
    '{provider:$p, model:$m, signedInAt:$s, credentials:$c}'
}

# Iterate every profile dir on disk. Skips entries that don't have a
# combined.env (incomplete state from an interrupted setup).
account_each() {
  [[ -d "$AUTH_PROFILES_DIR" ]] || return 0
  local d
  for d in "${AUTH_PROFILES_DIR}"/*/; do
    [[ -d "$d" && -f "${d}combined.env" ]] || continue
    basename "$d"
  done
}

cmd_account_list() {
  ensure_state_ro
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive account list"
  local rows="[]" name types agents signins t detail
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    types=$(account_types_authed "$name")
    agents=$(account_agents_bound "$name")
    # Build per-type signin details so the new-agent wizard's profile tiles
    # can show "Anthropic · claude-sonnet-4-5 · signed in May 12" instead of
    # all three orphan profiles reading identically as "Not used yet".
    signins="{}"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      detail=$(account_signin_detail "$name" "$t")
      [[ "$detail" != "{}" ]] || continue
      signins=$(jq -c --arg k "$t" --argjson v "$detail" '. + {($k):$v}' <<<"$signins")
    done < <(jq -r '.[]' <<<"$types" 2>/dev/null)
    rows=$(jq -c --arg n "$name" --argjson t "$types" --argjson a "$agents" --argjson s "$signins" \
      '. + [{name:$n, types:$t, agents:$a, signins:$s}]' <<<"$rows")
  done < <(account_each)
  if (( JSON_MODE )); then
    echo "$rows" | jq -c '{ok:true, data: .}'
  else
    echo "$rows" | jq -r '
      def fmt(a): if (a | length) == 0 then "-" else (a | join(",")) end;
      if length == 0 then "no accounts" else
        (["NAME","TYPES","AGENTS"] | @tsv),
        (.[] | [.name, fmt(.types), (.agents | length | tostring)] | @tsv)
      end' | column -t -s $'\t'
  fi
}

# usage_agent_home <agent> — resolve the agent user's home dir (where its
# statusline cache lives) from passwd, falling back to /home/agent-<name>.
usage_agent_home() {
  local agent="$1" home
  home=$(getent passwd "agent-${agent}" 2>/dev/null | cut -d: -f6)
  [[ -n "$home" ]] && { printf '%s\n' "$home"; return; }
  printf '/home/agent-%s\n' "$agent"
}

# usage_read_ratelimits <agent> — emit a compact JSON object
#   {asOf, fiveHourPct, fiveResetsAt, sevenDayPct, sevenResetsAt}
# from the agent's statusline cache (the JSON Claude Code hands its
# statusline, mirrored to ~/.claude/statusline-last.json by statusline.sh).
# asOf is the cache file's mtime (epoch) — the cache carries no own timestamp,
# and mtime is when the live limits were last observed. Emits nothing when
# there's no readable cache or no rate_limits block: an agent that hasn't
# rendered its statusline since boot, or a non-claude type whose CLI doesn't
# surface Anthropic 5h/7d limits.
usage_read_ratelimits() {
  local agent="$1" cache mtime
  cache="$(usage_agent_home "$agent")/.claude/statusline-last.json"
  [[ -s "$cache" ]] || return 0
  mtime=$(stat -c %Y "$cache" 2>/dev/null) || return 0
  jq -c --argjson at "$mtime" '
    (.rate_limits // {}) as $r
    | ($r.five_hour // {}) as $f
    | ($r.seven_day // {}) as $s
    | if ($f.used_percentage == null and $s.used_percentage == null)
      then empty
      else {
        asOf: $at,
        fiveHourPct:   ($f.used_percentage // null),
        fiveResetsAt:  ($f.resets_at // null),
        sevenDayPct:   ($s.used_percentage // null),
        sevenResetsAt: ($s.resets_at // null)
      } end' "$cache" 2>/dev/null
}

# account_best_ratelimits <account> — freshest statusline rate-limit JSON across
# the account's bound agents (same selection cmd_account_usage uses), or empty
# when no bound agent has a readable cache. Emits the usage_read_ratelimits shape
# ({asOf, fiveHourPct, ...}). Caller must be root to read sibling agent homes.
account_best_ratelimits() {
  local account="$1" agents agent rl at best best_at=-1
  agents=$(account_agents_bound "$account")
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    rl=$(usage_read_ratelimits "$agent") || continue
    [[ -n "$rl" ]] || continue
    at=$(jq -r '.asOf // -1' <<<"$rl")
    if [[ "$at" =~ ^[0-9]+$ ]] && (( at > best_at )); then
      best_at=$at; best="$rl"
    fi
  done < <(jq -r '.[]' <<<"$agents")
  printf '%s' "${best:-}"
}

# account_has_live_headroom <account> — exit 0 when the account's FRESHEST cache
# was rendered recently (within HEADROOM_FRESH_SECS) AND both observed windows
# are below HEADROOM_MAX_PCT. Used by rotation to override a STALE cooldown: if
# an agent on that account rendered a low-usage statusline minutes ago, the
# account genuinely has capacity regardless of a leftover cooldown epoch. A
# missing/old/high cache → non-zero (don't override — fail safe to the cooldown).
HEADROOM_FRESH_SECS="${HEADROOM_FRESH_SECS:-600}"   # 10 min
HEADROOM_MAX_PCT="${HEADROOM_MAX_PCT:-90}"
account_has_live_headroom() {
  local account="$1" rl now
  rl=$(account_best_ratelimits "$account")
  [[ -n "$rl" ]] || return 1
  now=$(date +%s)
  jq -e --argjson now "$now" --argjson fresh "$HEADROOM_FRESH_SECS" \
        --argjson max "$HEADROOM_MAX_PCT" '
    # Fresh: cache mtime within the window. 5h must be present and under max;
    # 7d may be null (not always surfaced) but if present must also be under max.
    (.asOf != null and ($now - .asOf) <= $fresh)
    and (.fiveHourPct != null and .fiveHourPct < $max)
    and (.sevenDayPct == null or .sevenDayPct < $max)
  ' <<<"$rl" >/dev/null 2>&1
}

# `account usage` — per-account snapshot of Anthropic 5h / 7d limit usage,
# backing the dashboard Switch-account modal dots and Telegram /account +
# /usage. For each account we read the FRESHEST statusline cache across its
# bound agents (an account is shared by several agents; whichever rendered
# most recently carries the truest live numbers). usage is null when no
# bound agent has a readable cache. Needs root to read sibling agents' 0750
# home dirs — dashboard and telegram both call via `sudo -n 5dive account usage`.
cmd_account_usage() {
  ensure_state
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive account usage"
  require_root
  local rows="[]" name agents agent rl at best best_at src usage
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    agents=$(account_agents_bound "$name")
    best=""; best_at=-1; src=""
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      rl=$(usage_read_ratelimits "$agent") || continue
      [[ -n "$rl" ]] || continue
      at=$(jq -r '.asOf // -1' <<<"$rl")
      if [[ "$at" =~ ^[0-9]+$ ]] && (( at > best_at )); then
        best_at=$at; best="$rl"; src="$agent"
      fi
    done < <(jq -r '.[]' <<<"$agents")
    if [[ -n "$best" ]]; then
      usage=$(jq -c --arg src "$src" '{
        fiveHour: (if .fiveHourPct == null then null
                   else {pct: .fiveHourPct, resetsAt: .fiveResetsAt} end),
        sevenDay: (if .sevenDayPct == null then null
                   else {pct: .sevenDayPct, resetsAt: .sevenResetsAt} end),
        asOf: .asOf, source: $src}' <<<"$best")
    else
      usage="null"
    fi
    rows=$(jq -c --arg n "$name" --argjson a "$agents" --argjson u "$usage" \
      '. + [{name:$n, agents:$a, usage:$u}]' <<<"$rows")
  done < <(account_each)
  if (( JSON_MODE )); then
    echo "$rows" | jq -c '{ok:true, data: .}'
  else
    echo "$rows" | jq -r '
      def p(x): if x == null then "-" else ((x.pct | floor | tostring) + "%") end;
      if length == 0 then "no accounts" else
        (["ACCOUNT","5H","7D","SOURCE"] | @tsv),
        (.[] | [.name, p(.usage.fiveHour), p(.usage.sevenDay),
                (.usage.source // "-")] | @tsv)
      end' | column -t -s $'\t'
  fi
}

cmd_account_show() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive account show <name>"
  valid_profile_name "$name" \
    || fail "$E_VALIDATION" "invalid account name (lowercase letters/digits/_-, start letter, <=32 chars)"
  [[ -d "${AUTH_PROFILES_DIR}/${name}" ]] \
    || fail "$E_NOT_FOUND" "no account named '$name'"
  local types agents env_keys env_file="${AUTH_PROFILES_DIR}/${name}/combined.env"
  types=$(account_types_authed "$name")
  agents=$(account_agents_bound "$name")
  if [[ -s "$env_file" ]]; then
    env_keys=$(grep -oE '^[A-Z_][A-Z0-9_]*' "$env_file" 2>/dev/null | sort -u | jq -R . | jq -cs '.')
  else
    env_keys="[]"
  fi
  if (( JSON_MODE )); then
    jq -cn --arg n "$name" --argjson t "$types" --argjson a "$agents" --argjson e "$env_keys" \
      '{ok:true, data:{name:$n, types:$t, agents:$a, envKeys:$e}}'
  else
    local fmt='if length == 0 then "-" else join(", ") end'
    echo "name:    $name"
    echo "types:   $(jq -r "$fmt" <<<"$types")"
    echo "agents:  $(jq -r "$fmt" <<<"$agents")"
    echo "envKeys: $(jq -r "$fmt" <<<"$env_keys")"
  fi
}

cmd_account_add() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive account add <name>"
  valid_profile_name "$name" \
    || fail "$E_VALIDATION" "invalid account name (lowercase letters/digits/_-, start letter, <=32 chars)"
  # "default" is the magic value `agent config set auth-profile=default`
  # uses to clear an agent's binding — reject it as an account name so the
  # two meanings can't collide.
  [[ "$name" != "default" ]] \
    || fail "$E_VALIDATION" "'default' is reserved (clears an agent's account binding)"
  require_root
  if [[ -d "${AUTH_PROFILES_DIR}/${name}" ]]; then
    ok "account '$name' already exists" \
       '{name:$n, created:false, alreadyExisted:true}' --arg n "$name"
    return 0
  fi
  ensure_profile_dir "$name" >/dev/null
  ok "account '$name' created. Sign in with: sudo 5dive account login $name --type=<type>" \
     '{name:$n, created:true, alreadyExisted:false}' --arg n "$name"
}

cmd_account_rename() {
  local old="${1:-}" new="${2:-}"
  [[ -n "$old" && -n "$new" ]] || fail "$E_USAGE" "usage: 5dive account rename <old> <new>"
  valid_profile_name "$old" \
    || fail "$E_VALIDATION" "invalid old account name"
  valid_profile_name "$new" \
    || fail "$E_VALIDATION" "invalid new account name (lowercase letters/digits/_-, start letter, <=32 chars)"
  [[ "$new" != "default" ]] \
    || fail "$E_VALIDATION" "'default' is reserved (clears an agent's account binding)"
  [[ "$old" != "$new" ]] || fail "$E_VALIDATION" "old and new names are the same"
  require_root
  ensure_state
  [[ -d "${AUTH_PROFILES_DIR}/${old}" ]] \
    || fail "$E_NOT_FOUND" "no account named '$old'"
  [[ ! -e "${AUTH_PROFILES_DIR}/${new}" ]] \
    || fail "$E_CONFLICT" "account '$new' already exists"

  local affected
  affected=$(account_agents_bound "$old")

  step "Renaming account dir '$old' -> '$new'"
  mv "${AUTH_PROFILES_DIR}/${old}" "${AUTH_PROFILES_DIR}/${new}"

  # Update registry .authProfile fields and re-point each agent's symlink.
  if [[ "$(jq -r 'length' <<<"$affected")" -gt 0 ]]; then
    step "Updating registry bindings ($(jq -r 'length' <<<"$affected") agent(s))"
    local reg
    reg=$(registry_read)
    reg=$(jq --arg old "$old" --arg new "$new" \
      '.agents = (.agents | with_entries(if .value.authProfile == $old then .value.authProfile = $new else . end))' \
      <<<"$reg")
    echo "$reg" | registry_write

    local agent
    while IFS= read -r agent; do
      [[ -n "$agent" ]] || continue
      step "Re-pointing ${ENV_DIR}/${agent}-auth.env"
      link_agent_profile "$agent" "$new"
      step "Restarting 5dive-agent@${agent}.service"
      systemctl restart "5dive-agent@${agent}.service" >&2 2>&1 || \
        warn "restart of agent '$agent' failed — check journalctl -u 5dive-agent@${agent}"
    done < <(jq -r '.[]' <<<"$affected")
  fi

  ok "account renamed '$old' -> '$new'" \
     '{old:$o, new:$n, agents:$a}' \
     --arg o "$old" --arg n "$new" --argjson a "$affected"
}

cmd_account_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive account remove <name>"
  valid_profile_name "$name" \
    || fail "$E_VALIDATION" "invalid account name"
  require_root
  ensure_state
  [[ -d "${AUTH_PROFILES_DIR}/${name}" ]] \
    || fail "$E_NOT_FOUND" "no account named '$name'"

  local agents
  agents=$(account_agents_bound "$name")
  if [[ "$(jq -r 'length' <<<"$agents")" -gt 0 ]]; then
    local list
    list=$(jq -r 'join(", ")' <<<"$agents")
    if (( JSON_MODE )); then
      jq -cn --arg n "$name" --argjson a "$agents" --argjson c "$E_CONFLICT" \
        '{ok:false, error:{code:$c, class:"conflict",
          message:("account \($n) is in use by: " + ($a | join(", "))),
          details:{agents:$a}}}'
      echo "error: account '$name' is in use by: $list" >&2
      exit "$E_CONFLICT"
    fi
    fail "$E_CONFLICT" "account '$name' is in use by: $list — rebind or remove those agents first"
  fi

  step "Deleting account dir ${AUTH_PROFILES_DIR}/${name}"
  rm -rf "${AUTH_PROFILES_DIR:?}/${name}"
  ok "account '$name' removed" \
     '{name:$n, removed:true}' --arg n "$name"
}

# `account login <name> --type=<type>` — TTY shortcut. Reorders args and
# hands off to cmd_auth_login, which exec's the underlying CLI's interactive
# device-code/OAuth flow. For non-TTY/dashboard use, the device-code lifecycle
# stays under `agent auth start|poll|submit|cancel --auth-profile=<name>`.
cmd_account_login() {
  local name="" type=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type=*) type="${1#--type=}" ;;
      -*)       fail "$E_USAGE" "unknown flag: $1" ;;
      *)        [[ -z "$name" ]] && name="$1" || fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$type" ]] \
    || fail "$E_USAGE" "usage: 5dive account login <name> --type=<type>"
  valid_profile_name "$name" \
    || fail "$E_VALIDATION" "invalid account name"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  cmd_auth_login --auth-profile="$name" "$type"
}

cmd_agent_set_account() {
  local agent="${1:-}" account="${2:-}"
  [[ -n "$agent" && -n "$account" ]] \
    || fail "$E_USAGE" "usage: 5dive agent set-account <agent> <account|default>"
  cmd_config "$agent" set "auth-profile=${account}"
}

# ---------------------------------------------------------------------------
# `agent rotation` — opt-in multi-account auto-rotation.
#
# Lets an agent be bound to an ORDERED list of accounts and auto-swap to the
# next eligible one when it hits a usage limit (driven by the rate-limit
# recovery path — see Phase 2). Default OFF; never rotates into a cooling
# account; if none are eligible the caller falls back to wait-for-reset.
#
# State lives in the registry under .agents[<name>].rotation:
#   { enabled: bool, accounts: [ordered profile names], cooldowns: {profile: epoch} }
# The agent's ACTIVE account stays .agents[<name>].authProfile (single source
# of truth). `rotate` just selects the next eligible profile and re-points it
# through cmd_config, reusing the exact set-account plumbing (env rewrite,
# auth-symlink re-point, deferred restart).
#
# Mutating subcommands run under the registry lock; `get` is read-only. The
# get/set/rotate/cooldown/clear-cooldown routing lives in main.sh's `agent`
# dispatcher (mirrors how `auth` and `telegram-access` are routed inline).

# rotation_require_agent <name> — emit the registry JSON, failing if the agent
# is unknown. Caller captures stdout.
rotation_require_agent() {
  local name="$1" reg
  reg=$(registry_read)
  jq -e --arg n "$name" '.agents[$n] != null' <<<"$reg" >/dev/null \
    || fail "$E_NOT_FOUND" "no agent named '$name'"
  printf '%s' "$reg"
}

cmd_agent_rotation_get() {
  local name="${1:-}"
  [[ -n "$name" ]] || fail "$E_USAGE" "usage: 5dive agent rotation get <agent>"
  ensure_state
  local reg active rot
  reg=$(rotation_require_agent "$name")
  active=$(jq -r --arg n "$name" '.agents[$n].authProfile // ""' <<<"$reg")
  rot=$(jq -c --arg n "$name" \
    '.agents[$n].rotation // {enabled:false, accounts:[], cooldowns:{}}' <<<"$reg")
  if (( JSON_MODE )); then
    jq -cn --arg a "$active" --argjson r "$rot" '{ok:true, data:{
      active:$a,
      enabled:($r.enabled // false),
      allAccounts:($r.allAccounts // false),
      accounts:($r.accounts // []),
      cooldowns:($r.cooldowns // {}),
      lastSet:($r.lastSet // null)
    }}'
  else
    local now; now=$(date +%s)
    echo "agent:    $name"
    echo "active:   ${active:--}"
    echo "rotation: $(jq -r '.enabled // false' <<<"$rot")"
    # allAccounts is the "use every eligible profile" sentinel — show it as the
    # pool rather than the (empty) explicit list.
    if [[ "$(jq -r '.allAccounts // false' <<<"$rot")" == "true" ]]; then
      echo "accounts: all (every eligible profile)"
    else
      echo "accounts: $(jq -r '(.accounts // []) | if length==0 then "-" else join(", ") end' <<<"$rot")"
    fi
    # only surface still-active cooldowns; expired ones are noise.
    jq -r --argjson now "$now" '(.cooldowns // {}) | to_entries[]
      | select(.value > $now) | "  cooling: \(.key) until \(.value)"' <<<"$rot" 2>/dev/null || true
    # Last toggle provenance (DIVE-126) — helps diagnose a concurrent-toggle war.
    jq -r '(.lastSet // empty)
      | "last set: \(.toEnabled) (was \(.fromEnabled)) by \(.by) at \(.at)"' <<<"$rot" 2>/dev/null || true
  fi
}

cmd_agent_rotation_set() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] \
    || fail "$E_USAGE" "usage: 5dive agent rotation set <agent> [--enabled=true|false] [--accounts=a,b,c]"
  require_root
  ensure_state
  local set_enabled="" set_accounts="" accounts_provided=0 a
  for a in "$@"; do
    case "$a" in
      --enabled=*)  set_enabled="${a#--enabled=}" ;;
      --accounts=*) set_accounts="${a#--accounts=}"; accounts_provided=1 ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  [[ -n "$set_enabled" || $accounts_provided -eq 1 ]] \
    || fail "$E_USAGE" "nothing to set — pass --enabled= and/or --accounts="
  local reg type
  reg=$(rotation_require_agent "$name")
  type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
  # DIVE-126: capture the prior enabled-state + the writer BEFORE applying, so a
  # concurrent-toggle war (two agents/dashboards flipping enabled, last-write-
  # wins under the registry lock) is self-diagnosing — `rotation get` then shows
  # who last set it and the transition. Writer precedence mirrors audit_log.
  local rot_prior_enabled rot_writer rot_set_ts
  rot_prior_enabled=$(jq -c --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg")
  rot_writer="${FIVEDIVE_AUDIT_USER:-${SUDO_USER:-${USER:-unknown}}}"
  rot_set_ts=$(date -Iseconds)
  if [[ -n "$set_enabled" ]]; then
    case "$set_enabled" in true|false) ;; *) fail "$E_VALIDATION" "--enabled must be true or false" ;; esac
  fi
  # Parse the account spec. `--accounts=all` is the sentinel for "use every
  # eligible (same-type) profile, auto-including ones added later" — we store an
  # allAccounts flag and an EMPTY explicit list, then resolve the live pool at
  # rotate-time (see cmd_agent_rotation_rotate). Otherwise it's an ordered list
  # (dedup, preserve order); each entry must be a configured profile that
  # carries a credential for THIS agent's type — rotating to an account the
  # agent can't authenticate as is a footgun.
  local accounts_json="[]" all_accounts="false"
  if (( accounts_provided )) && [[ "${set_accounts,,}" == "all" ]]; then
    all_accounts="true"
  elif (( accounts_provided )) && [[ -n "$set_accounts" ]]; then
    local -a arr=(); IFS=',' read -ra arr <<<"$set_accounts"
    local acct seen=""
    for acct in "${arr[@]}"; do
      acct="${acct//[[:space:]]/}"
      [[ -n "$acct" ]] || continue
      valid_profile_name "$acct" \
        || fail "$E_VALIDATION" "invalid account name in --accounts: '$acct'"
      [[ -f "${AUTH_PROFILES_DIR}/${acct}/combined.env" ]] \
        || fail "$E_NOT_FOUND" "account '$acct' not configured"
      jq -e --arg t "$type" 'index($t) != null' \
        <<<"$(account_types_authed "$acct")" >/dev/null \
        || fail "$E_VALIDATION" "account '$acct' has no $type credential — rotation needs same-type accounts"
      case ",$seen," in *",$acct,"*) continue ;; esac
      seen="${seen:+$seen,}$acct"
      accounts_json=$(jq -c --arg a "$acct" '. + [$a]' <<<"$accounts_json")
    done
  fi
  # Ensure the rotation object exists, then apply the requested fields.
  reg=$(jq --arg n "$name" \
    '.agents[$n].rotation = (.agents[$n].rotation // {enabled:false, accounts:[], cooldowns:{}})' <<<"$reg")
  if [[ -n "$set_enabled" ]]; then
    reg=$(jq --arg n "$name" --argjson e "$set_enabled" '.agents[$n].rotation.enabled = $e' <<<"$reg")
  fi
  if (( accounts_provided )); then
    reg=$(jq --arg n "$name" --argjson a "$accounts_json" --argjson all "$all_accounts" \
      '.agents[$n].rotation.accounts = $a | .agents[$n].rotation.allAccounts = $all' <<<"$reg")
    # Cooldown pruning only applies to an explicit list — drop cooldowns for
    # accounts no longer in it. Under allAccounts the pool is dynamic (resolved
    # at rotate-time), so we keep every cooldown; expired ones are ignored then.
    if [[ "$all_accounts" != "true" ]]; then
      reg=$(jq --arg n "$name" '
        (.agents[$n].rotation.cooldowns // {}) as $c
        | (.agents[$n].rotation.accounts // []) as $acc
        | .agents[$n].rotation.cooldowns =
            reduce $acc[] as $k ({}; if $c[$k] != null then .[$k] = $c[$k] else . end)' <<<"$reg")
    fi
  fi
  # Stamp the last-writer + enabled transition onto the rotation object so the
  # next reader can see who toggled it and from what (DIVE-126). toEnabled is
  # read from the just-applied state above.
  reg=$(jq --arg n "$name" --arg by "$rot_writer" --arg at "$rot_set_ts" \
    --argjson from "$rot_prior_enabled" \
    '.agents[$n].rotation.lastSet = {
       by: $by, at: $at,
       fromEnabled: $from,
       toEnabled: (.agents[$n].rotation.enabled // false)
     }' <<<"$reg")
  echo "$reg" | registry_write
  local out_enabled out_accounts out_all
  out_enabled=$(jq -c --arg n "$name" '.agents[$n].rotation.enabled' <<<"$reg")
  out_accounts=$(jq -c --arg n "$name" '.agents[$n].rotation.accounts' <<<"$reg")
  out_all=$(jq -c --arg n "$name" '.agents[$n].rotation.allAccounts // false' <<<"$reg")
  ok "rotation config updated for '$name'" \
     '{name:$n, enabled:$e, allAccounts:$all, accounts:$a}' \
     --arg n "$name" --argjson e "$out_enabled" --argjson all "$out_all" --argjson a "$out_accounts"
}

# rotation_eligible_accounts <type> — JSON array of every configured profile
# that carries a credential for <type>, in account_each (alphabetical) order.
# Resolves the live pool for an allAccounts rotation, so profiles added after
# the agent was configured automatically join the rotation.
rotation_eligible_accounts() {
  local type="$1" out="[]" acct
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    jq -e --arg t "$type" 'index($t) != null' \
      <<<"$(account_types_authed "$acct")" >/dev/null 2>&1 \
      && out=$(jq -c --arg a "$acct" '. + [$a]' <<<"$out")
  done < <(account_each)
  printf '%s' "$out"
}

cmd_agent_rotation_rotate() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] \
    || fail "$E_USAGE" "usage: 5dive agent rotation rotate <agent> [--cooldown-current=<epoch>]"
  require_root
  ensure_state
  local cooldown_current="" a
  for a in "$@"; do
    case "$a" in
      --cooldown-current=*) cooldown_current="${a#--cooldown-current=}" ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  local reg enabled current
  reg=$(rotation_require_agent "$name")
  enabled=$(jq -r --arg n "$name" '.agents[$n].rotation.enabled // false' <<<"$reg")
  current=$(jq -r --arg n "$name" '.agents[$n].authProfile // ""' <<<"$reg")
  [[ "$enabled" == "true" ]] \
    || fail "$E_VALIDATION" "rotation not enabled for '$name' (enable: 5dive agent rotation set $name --enabled=true)"
  # Cool down the account we're leaving (the one that just hit its limit), so
  # we don't bounce straight back to it. Persist immediately — even if no
  # eligible target exists, the cooldown should stick for the next attempt.
  if [[ -n "$cooldown_current" && -n "$current" ]]; then
    [[ "$cooldown_current" =~ ^[0-9]+$ ]] \
      || fail "$E_VALIDATION" "--cooldown-current must be an epoch (seconds)"
    reg=$(jq --arg n "$name" --arg c "$current" --argjson u "$cooldown_current" '
      .agents[$n].rotation = (.agents[$n].rotation // {enabled:false, accounts:[], cooldowns:{}})
      | .agents[$n].rotation.cooldowns[$c] = $u' <<<"$reg")
    echo "$reg" | registry_write
  fi
  # Resolve the pool: under allAccounts it's every eligible same-type profile
  # (computed live so newly-added accounts join automatically), otherwise the
  # stored ordered list. Then pick the first entry that isn't the current
  # account and isn't still cooling. Order == preference.
  local allflag type pool now cd candidates target tier cooling_target=0
  allflag=$(jq -r --arg n "$name" '.agents[$n].rotation.allAccounts // false' <<<"$reg")
  if [[ "$allflag" == "true" ]]; then
    type=$(jq -r --arg n "$name" '.agents[$n].type' <<<"$reg")
    pool=$(rotation_eligible_accounts "$type")
  else
    pool=$(jq -c --arg n "$name" '.agents[$n].rotation.accounts // []' <<<"$reg")
  fi
  now=$(date +%s)
  cd=$(jq -c --arg n "$name" '.agents[$n].rotation.cooldowns // {}' <<<"$reg")
  # Candidate accounts = the pool minus the one we're leaving, in preference order.
  # -n (null input) is REQUIRED: this filter reads only from --argjson, never stdin.
  # Without it jq blocks on / consumes stdin — and when the rotate runs from the
  # StopFailure hook (empty stdin) it processes zero inputs and emits an empty
  # string, which then crashes Tier-1's `--argjson c ""` with "invalid JSON text".
  # That abort left the agent parked on the just-cooled account = no rotation.
  candidates=$(jq -cn --arg cur "$current" --argjson acc "$pool" '[ $acc[] | select(. != $cur) ]')

  # Tier 1 — a candidate that isn't cooling. The common case; preference order wins.
  target=$(jq -rn --argjson now "$now" --argjson c "$candidates" --argjson cd "$cd" \
    '([ $c[] | select(($cd[.] // 0) <= $now) ] | first) // ""')
  tier=1

  # Tier 2 — STALE-COOLDOWN RECOVERY (DIVE-55). Every candidate looks like it's
  # cooling, but a cooldown is just a scraped reset epoch and can be wrong (set
  # too late, or the account's window already reset). If an agent on a candidate
  # rendered a low-usage statusline in the last few minutes, that account really
  # has capacity — so override the stale cooldown and rotate there. We clear its
  # cooldown so the resume doesn't then sit waiting on the bogus epoch.
  if [[ -z "$target" ]]; then
    local cand
    while IFS= read -r cand; do
      [[ -n "$cand" ]] || continue
      if account_has_live_headroom "$cand"; then
        target="$cand"; tier=2
        reg=$(jq --arg n "$name" --arg a "$cand" 'del(.agents[$n].rotation.cooldowns[$a])' <<<"$reg")
        echo "$reg" | registry_write
        break
      fi
    done < <(jq -r '.[]' <<<"$candidates")
  fi

  # Tier 3 — SOONEST-FREEING (DIVE-55). All candidates are genuinely cooling.
  # Rather than park on the account we just left (which we cooled to the LATEST
  # reset), jump to whichever candidate frees first — but ONLY if it frees sooner
  # than staying put would. current_cd is what we just cooled the leaving account
  # to (or its stored cooldown); rotating to something that frees later would be
  # strictly worse and could thrash, so we decline and let the resume wait here.
  if [[ -z "$target" ]]; then
    local current_cd soonest soonest_cd
    if [[ "$cooldown_current" =~ ^[0-9]+$ ]]; then
      current_cd="$cooldown_current"
    else
      current_cd=$(jq -rn --arg cur "$current" --argjson cd "$cd" '($cd[$cur] // 0)')
    fi
    soonest=$(jq -rn --argjson c "$candidates" --argjson cd "$cd" \
      '([ $c[] | {a:., u:($cd[.] // 0)} ] | sort_by(.u) | first | .a) // ""')
    soonest_cd=$(jq -rn --arg a "$soonest" --argjson cd "$cd" '($cd[$a] // 0)')
    if [[ -n "$soonest" ]] && (( soonest_cd < current_cd )); then
      target="$soonest"; tier=3; cooling_target=1
    fi
  fi

  if [[ -z "$target" ]]; then
    if (( JSON_MODE )); then
      ok "" '{rotated:false, from:$f, to:null, reason:"no eligible account (all cooling later than current, or none configured)"}' \
         --arg f "$current"
    else
      echo "OK — no eligible account to rotate to (all cooling later than current / none configured)"
    fi
    return 0
  fi
  # Re-point via the existing set-account plumbing. We already hold the
  # registry lock and cmd_config reads/writes the registry directly (safe
  # under the lock); it also fires the deferred restart. Silence its own
  # stdout so we emit a single clean envelope. `tier`/`coolingTarget` are
  # surfaced for observability (3 + coolingTarget=true means we rotated to a
  # still-cooling-but-sooner account; the resume waits on its reset).
  cmd_config "$name" set "auth-profile=${target}" >/dev/null
  ok "rotated '$name': ${current:--} -> ${target}" \
     '{rotated:true, from:$f, to:$t, tier:$tier, coolingTarget:$ct}' \
     --arg f "$current" --arg t "$target" --argjson tier "$tier" \
     --argjson ct "$( ((cooling_target)) && echo true || echo false )"
}

cmd_agent_rotation_cooldown() {
  local name="${1:-}" account="${2:-}"
  [[ -n "$name" && -n "$account" ]] \
    || fail "$E_USAGE" "usage: 5dive agent rotation cooldown <agent> <account> --until=<epoch>"
  shift 2
  require_root
  ensure_state
  local until="" a
  for a in "$@"; do
    case "$a" in
      --until=*) until="${a#--until=}" ;;
      *) fail "$E_USAGE" "unknown flag: $a" ;;
    esac
  done
  [[ "$until" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--until=<epoch seconds> required"
  valid_profile_name "$account" || fail "$E_VALIDATION" "invalid account name"
  local reg
  reg=$(rotation_require_agent "$name")
  reg=$(jq --arg n "$name" --arg a "$account" --argjson u "$until" '
    .agents[$n].rotation = (.agents[$n].rotation // {enabled:false, accounts:[], cooldowns:{}})
    | .agents[$n].rotation.cooldowns[$a] = $u' <<<"$reg")
  echo "$reg" | registry_write
  ok "cooldown set: '$account' until $until" \
     '{name:$n, account:$a, until:$u}' --arg n "$name" --arg a "$account" --argjson u "$until"
}

cmd_agent_rotation_clear_cooldown() {
  local name="${1:-}" account="${2:-}"
  [[ -n "$name" ]] \
    || fail "$E_USAGE" "usage: 5dive agent rotation clear-cooldown <agent> [<account>]"
  require_root
  ensure_state
  local reg
  reg=$(rotation_require_agent "$name")
  if [[ -n "$account" ]]; then
    valid_profile_name "$account" || fail "$E_VALIDATION" "invalid account name"
    reg=$(jq --arg n "$name" --arg a "$account" '
      if .agents[$n].rotation.cooldowns then
        .agents[$n].rotation.cooldowns |= del(.[$a])
      else . end' <<<"$reg")
  else
    reg=$(jq --arg n "$name" '
      if .agents[$n].rotation then .agents[$n].rotation.cooldowns = {} else . end' <<<"$reg")
  fi
  echo "$reg" | registry_write
  ok "cooldown cleared for '$name'${account:+ ($account)}" \
     '{name:$n, account:$a}' --arg n "$name" --arg a "${account:-}"
}

# `account set-active-provider <profile> <type> <provider>` — flip which
# credential in a profile's credential_pool the gateway uses, without
# rerunning the sign-in flow. Driven by the Switch account modal when
# the user picks a dormant provider that already lives in the same
# profile's pool (e.g. switching from openrouter back to openai-codex
# after both have been signed in). hermes-only for now — openclaw's
# active provider lives in openclaw.json under agents.defaults.model
# and needs a separate flip path.
cmd_account_set_active_provider() {
  local profile="${1:-}" type="${2:-}" provider="${3:-}"
  [[ -n "$profile" && -n "$type" && -n "$provider" ]] \
    || fail "$E_USAGE" "usage: 5dive account set-active-provider <profile> <type> <provider>"
  valid_profile_name "$profile" \
    || fail "$E_VALIDATION" "invalid profile name"
  is_known_type "$type" || fail "$E_NOT_FOUND" "unknown type: $type"
  [[ "$type" == "hermes" ]] \
    || fail "$E_VALIDATION" "set-active-provider currently supports type=hermes only"
  require_root
  local prof_hermes="${AUTH_PROFILES_DIR}/${profile}/hermes"
  local auth_path="${prof_hermes}/auth.json"
  [[ -s "$auth_path" ]] \
    || fail "$E_NOT_FOUND" "no hermes auth for profile '$profile'"
  # Confirm the credential exists in the pool before touching anything —
  # the gateway will silently re-fall-back to its existing model.provider
  # if config.yaml names a missing credential, which would surface as a
  # ghost "switched but nothing changed" experience.
  jq -e --arg p "$provider" '(.credential_pool // {}) | has($p)' "$auth_path" >/dev/null 2>&1 \
    || fail "$E_NOT_FOUND" "provider '$provider' not in profile '$profile' credential_pool — sign in with it first"

  local bin="${TYPE_BIN[hermes]}"
  [[ -x "$bin" ]] || fail "$E_NOT_INSTALLED" "hermes not installed at $bin"
  step "Pinning hermes model.provider=${provider} on profile '${profile}'"
  sudo -u claude -H env HERMES_HOME="$prof_hermes" \
    "$bin" config set model.provider "$provider" >&2 \
    || fail "$E_GENERIC" "hermes config set model.provider=$provider failed"
  # base_url left for hermes to auto-resolve from its provider catalog;
  # explicitly unset so a stale value from a previous provider doesn't
  # pin the gateway at the wrong endpoint.
  sudo -u claude -H env HERMES_HOME="$prof_hermes" \
    "$bin" config set model.base_url "" >&2 2>/dev/null || true
  local model="${HERMES_PROVIDER_MODEL[$provider]:-}"
  if [[ -n "$model" ]]; then
    sudo -u claude -H env HERMES_HOME="$prof_hermes" \
      "$bin" config set model.default "$model" >&2 \
      || warn "hermes config set model.default=$model failed"
  fi

  # Restart every agent bound to this profile so the start-hook seeds the
  # new config.yaml and bounces the gateway. Same loop shape as cmd_auth_set.
  local affected
  affected=$(registry_read | jq -r --arg p "$profile" \
    '.agents | to_entries[] | select(.value.authProfile == $p) | .key')
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    step "Restarting 5dive-agent@${agent}.service"
    systemctl restart "5dive-agent@${agent}.service" >&2 2>&1 \
      || warn "restart of agent '$agent' failed — check journalctl -u 5dive-agent@${agent}"
  done <<<"$affected"

  ok "active provider set to '$provider' on profile '$profile'" \
     '{profile:$p, type:$t, provider:$pr}' \
     --arg p "$profile" --arg t "$type" --arg pr "$provider"
}
