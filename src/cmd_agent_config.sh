cmd_config() {
  # Usage: 5dive agent config <name> set <key>=<value> [<key>=<value>...]
  #   keys:
  #     channels                  (none|telegram|discord|dashboard, comma-
  #                                separable — "telegram,dashboard" runs both;
  #                                dashboard is claude-only and token-free)
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
  #     autonomy                  (claude only — standard|yolo; yolo appends the
  #                                approved "act on your recs, still honor hard
  #                                gates" directive to the system prompt so it
  #                                survives /clear. 'son-of-anton' == yolo. DIVE-499)
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
  local new_effort=""
  # DIVE-499: when set, write_agent_env stamps this as AGENT_AUTONOMY; left empty
  # it preserves the file's current value (so a non-autonomy set won't drop it).
  local _AUTONOMY_OVERRIDE=""
  local autonomy_changed=0
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
        if [[ "$type" != "claude" ]] && channel_in_list dashboard "$v"; then
          fail "$E_VALIDATION" "channels=dashboard is claude-only (agent '$name' is type $type)"
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
        # `telegram.token=-` reads the token from stdin so the secret never
        # enters argv (/proc/<pid>/cmdline, shelld's audit log, server access
        # logs). Same sentinel as `cos set --token=-`; the dashboard's exec
        # tunnel sends the token via its stdin field. DIVE-880.
        if [[ "$v" == "-" ]]; then
          [[ -t 0 ]] && fail "$E_USAGE" "telegram.token=- expects the bot token on stdin"
          v=$(cat)
          v="${v//[$'\r\n\t ']/}"
        fi
        valid_telegram_token "$v" \
          || fail "$E_VALIDATION" "telegram token format looks wrong (expected <digits>:<20+ chars>)"
        new_telegram_token="$v"
        applied_keys+=("telegram.token")
        ;;
      discord.token)
        [[ "${TYPE_CHANNELS[$type]}" == "1" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support discord channels"
        # discord.token=- — same stdin sentinel as telegram.token above.
        if [[ "$v" == "-" ]]; then
          [[ -t 0 ]] && fail "$E_USAGE" "discord.token=- expects the bot token on stdin"
          v=$(cat)
          v="${v//[$'\r\n\t ']/}"
        fi
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
      effort|effortLevel)
        # Reasoning-effort switch — claude-only (Claude Code's settings.json
        # effortLevel). Mirrors the telegram plugin's /effort: writes effortLevel
        # then restarts (deferred below). Not registry-stored — `agent info`
        # reads the live settings.json so an effort changed in-TUI stays truth.
        # Levels match the plugin's EFFORT_LEVELS; xhigh/max are Opus-only at the
        # model level but we don't gate by model here (same as the plugin picker).
        [[ "$type" == "claude" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support 'effort' config (claude only)"
        case "$v" in
          low|medium|high|xhigh|max) ;;
          *) fail "$E_VALIDATION" "invalid effort '$v' (allowed: low, medium, high, xhigh, max)" ;;
        esac
        new_effort="$v"
        applied_keys+=("effort")
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
      autonomy|--autonomy)
        # DIVE-499: per-agent autonomy mode. claude-only (the directive uses
        # --append-system-prompt); other types have no equivalent yet.
        [[ "$type" == "claude" ]] \
          || fail "$E_VALIDATION" "type '$type' does not support 'autonomy' (claude only)"
        valid_autonomy "$v" \
          || fail "$E_VALIDATION" "invalid autonomy '$v' (standard|yolo|son-of-anton)"
        _AUTONOMY_OVERRIDE="$v"
        autonomy_changed=1
        env_dirty=1
        applied_keys+=("autonomy")
        ;;
      *) fail "$E_USAGE" "unknown config key: $k" ;;
    esac
  done
  # Pre-flight: setting channels=<plugin> without a token in the same call
  # only works if the connector secret is already on disk (e.g. rotating
  # the allowlist without touching the token). Otherwise the gateway boots
  # without credentials and silently goes deaf — better to fail loudly here.
  if [[ -n "$channels_changed_to" && "$channels_changed_to" != "none" ]]; then
    # Per-entry checks — channels= is a comma-separable list (DIVE-856), so
    # "telegram,dashboard" must run the telegram token check too. dashboard
    # needs no token (the plugin reads the box connectord bearer itself).
    if channel_in_list telegram "$channels_changed_to" \
        && [[ -z "$new_telegram_token" && ! -s "${CONNECTORS_DIR}/telegram-${name}.env" ]]; then
      fail "$E_VALIDATION" \
        "channels=telegram needs telegram.token=<token> in the same set call"
    fi
    if channel_in_list discord "$channels_changed_to" \
        && [[ -z "$new_discord_token" && ! -s "${CONNECTORS_DIR}/discord-${name}.env" ]]; then
      fail "$E_VALIDATION" \
        "channels=discord needs discord.token=<token> in the same set call"
    fi
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
  # DIVE-345: removing the channel must strip the stale telegram wiring left on
  # disk, else the agent re-enters the telegram wait_for_message loop on next
  # boot despite channels=none (agy, 2026-06-13). Reversible (moves to
  # .disabled-<ts>); the connector token is kept for one-flag re-enable.
  # List-aware (DIVE-856): any channels= value that drops telegram (none,
  # or a list without it, e.g. "dashboard") strips the stale wiring.
  if [[ -n "$channels_changed_to" ]] && ! channel_in_list telegram "$channels_changed_to"; then
    local _td_type
    _td_type=$(jq -r --arg n "$name" '.agents[$n].type // empty' <<<"$reg")
    teardown_telegram_wiring "$name" "$_td_type"
  fi
  # Channel attach / rotate: when this call touched telegram.* or discord.*
  # we need to push the new values into each type's native state dir, the
  # same way cmd_create does. install_channel_for_agent routes to the right
  # helper (install_channel_plugin_for_agent for claude — installs the
  # plugin if missing + seeds access.json with allowed_users; openclaw
  # channels add for openclaw; ~/.hermes/.env write for hermes).
  #
  # A bare channels=telegram (token already on disk from a prior call) must
  # ALSO dispatch: the deferred restart below boots the session with
  # `--channels plugin:telegram@…`, and if the plugin was never staged for
  # this user the session comes up with no telegram tool and the agent
  # improvises (raw Bot-API curl — seen live on the demo box, DIVE-250).
  # The install helpers are idempotent, so re-running on an already-staged
  # agent is a cheap no-op.
  local effective_channels
  effective_channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"' <<<"$reg")
  # `-n "$new_allowed_users"`: a bare `telegram.allowed-users=` set (no token
  # rotation, no channels= change) must still re-run the dispatch — that's the
  # ONLY path that seeds access.json (via install_channel_for_agent ->
  # seed_telegram_access_allowlist). Without this the key validated, reported
  # success in applied_keys, and silently no-op'd the allowlist write. The
  # token falls back to the stored connector secret below, so no token is
  # required in the call. (Seeding is additive — it appends new ids; removing
  # an id still goes through `telegram-access set`.)
  if [[ -n "$new_telegram_token" || -n "$new_allowed_users" ]] \
      || { [[ -n "$channels_changed_to" ]] && channel_in_list telegram "$channels_changed_to"; }; then
    channel_in_list telegram "$effective_channels" \
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
  if [[ -n "$new_discord_token" ]] \
      || { [[ -n "$channels_changed_to" ]] && channel_in_list discord "$channels_changed_to"; }; then
    channel_in_list discord "$effective_channels" \
      || fail "$E_VALIDATION" "discord.token requires channels=discord (current: $effective_channels)"
    # Same bare-attach rule as telegram above (DIVE-250): channels=discord
    # without a token in this call falls back to the stored connector secret
    # (the pre-flight above guarantees one exists).
    local discord_token_for_install="$new_discord_token"
    if [[ -z "$discord_token_for_install" ]]; then
      discord_token_for_install=$(grep -E '^DISCORD_BOT_TOKEN=' "${CONNECTORS_DIR}/discord-${name}.env" 2>/dev/null \
        | head -1 | cut -d= -f2-)
      [[ -n "$discord_token_for_install" ]] \
        || fail "$E_NOT_FOUND" "no stored discord token for agent '$name' — include discord.token=<token>"
    fi
    if [[ -n "$new_discord_token" ]]; then
      step "Writing ${CONNECTORS_DIR}/discord-${name}.env"
      write_channel_secret discord "$name" DISCORD_BOT_TOKEN "$new_discord_token"
    fi
    step "Installing discord channel for agent '$name' (type=$type)"
    install_channel_for_agent "$type" discord "$name" \
      "$discord_token_for_install" "$new_home_channel" "$new_allowed_users"
    if [[ "$type" == "hermes" ]]; then
      ensure_hermes_gateway "$name"
    fi
  fi
  # DIVE-856 dashboard chat attach — the one-tap "Enable chat" path
  # (`config set channels=<current>,dashboard` via the exec tunnel). No token
  # or extra keys: the plugin reads the box connectord bearer itself, so the
  # dispatch is gated purely on channels= in this call. Idempotent like the
  # telegram/discord dispatches above.
  if [[ -n "$channels_changed_to" ]] && channel_in_list dashboard "$channels_changed_to"; then
    step "Installing dashboard channel for agent '$name' (type=$type)"
    install_channel_for_agent "$type" dashboard "$name" ""
  fi
  if [[ -n "$new_model" ]]; then
    step "Writing model=$new_model into $type runtime config"
    write_runtime_model "$type" "$name" "$new_model"
  fi
  if [[ -n "$new_effort" ]]; then
    step "Writing effortLevel=$new_effort into claude runtime config"
    write_runtime_effort "$name" "$new_effort"
  fi
  # Fail-closed gate (DIVE-250): when this call attached a channel to a
  # claude agent, the restarted session boots with `--channels
  # plugin:<ch>@<marketplace>` (see 5dive-agent-start) and comes up with NO
  # channel tool if the plugin cache isn't staged yet. The dispatch above is
  # synchronous so the cache dir should already exist; poll briefly to absorb
  # any in-flight stager, then refuse to restart into a known-deaf session
  # rather than let the agent improvise. Scoped to channels_changed_to (not
  # every config call) so e.g. `model=` on a legacy claude-plugins-official
  # telegram agent can't trip a spurious marketplace mismatch.
  if [[ "$type" == "claude" && -n "$channels_changed_to" && "$channels_changed_to" != "none" ]]; then
    # Per-entry gate (DIVE-856): every channel in the new list boots as its
    # own `--channels plugin:<ch>@<marketplace>`, so each plugin cache must
    # be staged before the restart — one missing plugin means a deaf session.
    local gate_ch gate_marketplace gate_dir gate_waited
    for gate_ch in ${channels_changed_to//,/ }; do
      case "$gate_ch" in
        telegram|dashboard) gate_marketplace="5dive-plugins" ;;
        discord)            gate_marketplace="claude-plugins-official" ;;
        *) continue ;;
      esac
      gate_dir="/home/agent-${name}/.claude/plugins/cache/${gate_marketplace}/${gate_ch}"
      gate_waited=0
      while [[ ! -d "$gate_dir" ]] && (( gate_waited < 15 )); do
        sleep 1; gate_waited=$((gate_waited + 1))
      done
      [[ -d "$gate_dir" ]] || fail "$E_GENERIC" \
        "$gate_ch plugin not staged for agent '$name' ($gate_dir missing) — refusing to restart into a session with no $gate_ch tool. Re-run: sudo 5dive agent config $name set channels=$channels_changed_to"
    done
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

