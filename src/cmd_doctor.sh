
# -------- doctor (health check + optional auto-repair) --------
#
# Mental model: the dashboard invokes `5dive doctor --json` periodically, and
# users hit `5dive doctor --repair` from a "fix problems" button. Each check
# reports:
#   - severity: ok | warn | error
#   - fixable:  does this check know how to repair itself?
#   - repaired: did --repair actually fix it this run?
# The envelope is always {ok:true, data:{summary,checks}} (exit 0) so the
# dashboard can render partial results even when individual checks fail.
# Use data.summary.errors to branch in CI.

# Accumulator rebuilt on every cmd_doctor invocation. Script-scope so the
# check helpers below don't need to pass it around.
DOCTOR_CHECKS='[]'
DOCTOR_REPAIR=0

# doctor_add <category> <name> <severity> <message> [fixable:true|false] [repaired:true|false]
doctor_add() {
  local category="$1" name="$2" severity="$3" message="$4"
  local fixable="${5:-false}" repaired="${6:-false}"
  DOCTOR_CHECKS=$(jq -c \
    --arg c "$category" --arg n "$name" --arg s "$severity" --arg m "$message" \
    --argjson f "$fixable" --argjson r "$repaired" \
    '. + [{category:$c, name:$n, severity:$s, message:$m, fixable:$f, repaired:$r}]' \
    <<<"$DOCTOR_CHECKS")
  [[ "$severity" != "ok" ]] && step "[$severity] $category/$name: $message"
  return 0
}

# doctor_check_cmd <name> <executable> [apt-repair-package]
# Uses the host's PATH (root). Not suitable for "is bun on user claude's
# PATH" — that needs a sudo hop; handled inline in cmd_doctor.
doctor_check_cmd() {
  local name="$1" exe="$2" pkg="${3:-}"
  if command -v "$exe" >/dev/null 2>&1; then
    doctor_add deps "$name" ok "$exe found at $(command -v "$exe")"
    return 0
  fi
  local fixable=false
  [[ -n "$pkg" ]] && fixable=true
  if (( DOCTOR_REPAIR )) && [[ -n "$pkg" ]]; then
    step "Installing $pkg (apt-get)"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >&2 \
       && command -v "$exe" >/dev/null 2>&1; then
      doctor_add deps "$name" ok "$exe installed via apt ($pkg)" true true
      return 0
    fi
    doctor_add deps "$name" error "$exe missing; apt install $pkg failed" "$fixable" false
    return 1
  fi
  doctor_add deps "$name" error "$exe not found on PATH" "$fixable" false
  return 1
}

cmd_doctor() {
  require_root
  local filter=""
  DOCTOR_REPAIR=0
  DOCTOR_CHECKS='[]'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repair)     DOCTOR_REPAIR=1 ;;
      --category=*) filter="${1#--category=}" ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            fail "$E_USAGE" "extra arg: $1" ;;
    esac
    shift
  done
  case "$filter" in
    ""|deps|types|auth|creds|registry|shelld|channels|memory) ;;
    *) fail "$E_USAGE" "unknown --category (deps|types|auth|creds|registry|shelld|channels|memory)" ;;
  esac

  local run_deps=0 run_types=0 run_auth=0 run_creds=0 run_registry=0 run_shelld=0 run_channels=0 run_memory=0
  [[ -z "$filter" || "$filter" == "deps"     ]] && run_deps=1
  [[ -z "$filter" || "$filter" == "types"    ]] && run_types=1
  [[ -z "$filter" || "$filter" == "auth"     ]] && run_auth=1
  [[ -z "$filter" || "$filter" == "creds"    ]] && run_creds=1
  [[ -z "$filter" || "$filter" == "registry" ]] && run_registry=1
  [[ -z "$filter" || "$filter" == "shelld"   ]] && run_shelld=1
  [[ -z "$filter" || "$filter" == "channels" ]] && run_channels=1
  [[ -z "$filter" || "$filter" == "memory"   ]] && run_memory=1

  # --- deps ---
  if (( run_deps )); then
    # /dev/null must be the character device. An agent with sudo (admin
    # isolation) can clobber it — e.g. `tmux -S /dev/null` unlinks it — which
    # crash-loops EVERY agent on the box (teal-fox 2026-06-03). Checked first
    # so --repair fixes it before other checks that redirect to /dev/null run.
    # 5dive-agent-start also self-heals this on each start.
    if [[ -c /dev/null ]]; then
      doctor_add deps devnull ok "/dev/null is a character device"
    elif (( DOCTOR_REPAIR )); then
      step "Recreating /dev/null device node"
      if sudo sh -c 'rm -f /dev/null && mknod /dev/null c 1 3 && chmod 666 /dev/null && chown root:root /dev/null' \
         && [[ -c /dev/null ]]; then
        doctor_add deps devnull ok "/dev/null recreated as character device" true true
      else
        doctor_add deps devnull error "/dev/null not a char device and repair failed (run: sudo mknod /dev/null c 1 3 && sudo chmod 666 /dev/null)" true false
      fi
    else
      doctor_add deps devnull error "/dev/null is not a character device — every agent crash-loops (fix: sudo 5dive doctor --repair)" true false
    fi

    doctor_check_cmd tmux      tmux      tmux
    doctor_check_cmd jq        jq        jq
    doctor_check_cmd python3   python3   python3
    doctor_check_cmd curl      curl      curl
    doctor_check_cmd sqlite3   sqlite3   sqlite3
    doctor_check_cmd sudo      sudo
    doctor_check_cmd systemctl systemctl
    doctor_check_cmd journalctl journalctl

    # bun is needed by the telegram plugin runtime. Checked via the agent
    # user's login shell (which sources /etc/profile.d/5dive-shared-configs.sh
    # + nvm), i.e. the same environment systemd ends up with. Falls back to
    # checking user `claude` if no agents exist yet.
    local bun_user="claude"
    if [[ -f "$REGISTRY" ]]; then
      local first_agent
      first_agent=$(jq -r '.agents | keys[0] // empty' "$REGISTRY" 2>/dev/null)
      [[ -n "$first_agent" ]] && id -u "agent-${first_agent}" &>/dev/null \
        && bun_user="agent-${first_agent}"
    fi
    local bun_path
    bun_path=$(sudo -u "$bun_user" -i bash -lc 'command -v bun' 2>/dev/null || true)
    if [[ -n "$bun_path" ]]; then
      doctor_add deps bun ok "bun at $bun_path (checked as $bun_user)"
    elif (( DOCTOR_REPAIR )); then
      step "Installing bun for user claude"
      if sudo -u claude -i bash -lc 'curl -fsSL https://bun.sh/install | bash' >&2 \
         && sudo -u "$bun_user" -i bash -lc 'command -v bun' >/dev/null 2>&1; then
        doctor_add deps bun ok "bun installed for user claude" true true
      else
        doctor_add deps bun error "bun install failed (telegram plugin won't start)" true false
      fi
    else
      doctor_add deps bun error "bun not on PATH for $bun_user (telegram plugin requires it)" true false
    fi

    # nvm + node + npm (node-based CLIs like codex depend on these)
    if [[ -s /home/claude/.nvm/nvm.sh ]]; then
      doctor_add deps nvm ok "/home/claude/.nvm/nvm.sh present"
    else
      doctor_add deps nvm error "/home/claude/.nvm/nvm.sh missing (codex won't run)" false false
    fi
    local node_ver npm_ver
    node_ver=$(sudo -u claude -i bash -lc 'node --version' 2>/dev/null || true)
    npm_ver=$(sudo -u claude -i bash -lc 'npm --version' 2>/dev/null || true)
    [[ -n "$node_ver" ]] \
      && doctor_add deps node ok "node $node_ver (via nvm)" \
      || doctor_add deps node error "node not available for user claude" false false
    [[ -n "$npm_ver" ]] \
      && doctor_add deps npm  ok "npm $npm_ver (via nvm)" \
      || doctor_add deps npm  error "npm not available for user claude" false false

    # 5dive shared helpers that every agent create/start depends on.
    for f in /usr/local/bin/5dive-agent-start; do
      if [[ -x "$f" ]]; then
        doctor_add deps "$(basename "$f")" ok "$f present"
      else
        doctor_add deps "$(basename "$f")" error "$f missing or not executable (rerun install.sh)" false false
      fi
    done
    # The StopFailure (rate-limit DM) and PreToolUse (AskUserQuestion/ExitPlanMode)
    # hooks used to be standalone scripts under /usr/local/lib/5dive checked here
    # via $STOP_FAILURE_HOOK / $PRETOOL_TELEGRAM_HOOK. They now ship bundled inside
    # the telegram plugin (per-agent, no fixed path), so those vars were removed —
    # the stale checks were left referencing them and crashed `doctor --json` with
    # an unbound-variable error under `set -u`. Dropped; nothing standalone to probe.
    local resume_helper="/usr/local/lib/5dive/resume-after-reset.sh"
    if [[ -x "$resume_helper" ]]; then
      doctor_add deps resume-after-reset ok "$resume_helper present"
    else
      doctor_add deps resume-after-reset warn "$resume_helper missing — agents won't auto-resume when usage limit resets" false false
    fi
  fi

  # --- type binaries ---
  if (( run_types )); then
    local type
    for type in "${!TYPE_BIN[@]}"; do
      local bin="${TYPE_BIN[$type]}"
      local recipe="${TYPE_INSTALL[$type]:-}"
      if [[ -x "$bin" ]]; then
        doctor_add types "$type" ok "$bin installed"
        continue
      fi
      if (( DOCTOR_REPAIR )) && [[ -n "$recipe" ]]; then
        step "Installing $type CLI"
        if sudo -u claude -i bash -lc "$recipe" >&2 && [[ -x "$bin" ]]; then
          doctor_add types "$type" ok "$type installed at $bin" true true
        else
          doctor_add types "$type" error "$type install recipe failed" true false
        fi
      elif [[ -n "$recipe" ]]; then
        doctor_add types "$type" warn "$bin missing (run with --repair to auto-install)" true false
      else
        doctor_add types "$type" warn "$bin missing (no automated installer for $type)" false false
      fi
    done
  fi

  # --- auth (live probe for installed types) ---
  if (( run_auth )); then
    local type status
    for type in "${!TYPE_BIN[@]}"; do
      [[ -x "${TYPE_BIN[$type]}" ]] || continue
      status=$(auth_status_one "$type")
      case "$status" in
        ok)
          doctor_add auth "$type" ok "live probe succeeded" ;;
        needs_login)
          doctor_add auth "$type" error "no credentials on file — run: sudo 5dive agent auth login $type" false false ;;
        stale)
          doctor_add auth "$type" error "credentials rejected by provider — re-auth required" false false ;;
        not_installed)
          : ;;  # already flagged by types/
        *)
          doctor_add auth "$type" warn "status=$status" false false ;;
      esac
    done
  fi

  # --- claude shadow-credential heal (DIVE-329) ---
  #
  # A leftover ~/.claude/.credentials.json in an agent's config dir takes
  # precedence over the CLAUDE_CODE_OAUTH_TOKEN that systemd injects. Once that
  # file's OAuth token expires and can't refresh, Claude Code 401s on the dead
  # file even though the env-token is valid (teal-fox class). heal_claude_shadow_creds
  # (cmd_auth.sh) renames a stale shadow file to .stale-<ts> so CC falls back to
  # the env-token — but ONLY for agents that carry a verified env-token, so it
  # can never strand an agent. --repair renames; otherwise we just warn. This is
  # file-only (no network), so it's safe to run on every soft-update tick.
  if (( run_creds )); then
    local heal_out
    heal_out=$(heal_claude_shadow_creds "$DOCTOR_REPAIR")
    if [[ -z "$heal_out" ]]; then
      doctor_add creds shadow-credentials ok "no stale ~/.claude/.credentials.json shadowing an env-token"
    else
      local hline verb nm bak
      while IFS= read -r hline; do
        [[ -n "$hline" ]] || continue
        verb=$(awk '{print $1}' <<<"$hline")
        nm=$(awk '{print $2}'   <<<"$hline")
        case "$verb" in
          healed)
            bak=$(awk '{print $4}' <<<"$hline")
            doctor_add creds "agent:$nm" ok \
              "renamed stale shadow creds -> $(basename "$bak"); CC now falls back to the env-token" true true ;;
          stale)
            doctor_add creds "agent:$nm" warn \
              "stale ~/.claude/.credentials.json shadows the env-token (expired/unrenewable) — will 401 as it ages; run with --repair to neutralize it" true false ;;
          error)
            doctor_add creds "agent:$nm" error \
              "stale shadow creds present but rename failed (check perms on /home/agent-$nm/.claude)" true false ;;
        esac
      done <<<"$heal_out"
    fi
  fi

  # --- registry + per-agent state ---
  if (( run_registry )); then
    if [[ ! -f "$REGISTRY" ]]; then
      if (( DOCTOR_REPAIR )); then
        ensure_state
        doctor_add registry file ok "initialized empty $REGISTRY" true true
      else
        doctor_add registry file error "$REGISTRY missing (run with --repair to init)" true false
      fi
    elif ! jq -e '.agents | type == "object"' "$REGISTRY" >/dev/null 2>&1; then
      doctor_add registry file error "$REGISTRY unparseable or missing .agents object (manual fix required)" false false
    else
      doctor_add registry file ok "$REGISTRY intact"
      local schema_v
      schema_v=$(jq -r '.schemaVersion // 0' "$REGISTRY" 2>/dev/null || echo 0)
      if (( schema_v == REGISTRY_SCHEMA_VERSION )); then
        doctor_add registry schema ok "schemaVersion=$schema_v (current)"
      elif (( schema_v < REGISTRY_SCHEMA_VERSION )); then
        if (( DOCTOR_REPAIR )); then
          ensure_state   # stamps the current version in place
          doctor_add registry schema ok "migrated schemaVersion $schema_v -> $REGISTRY_SCHEMA_VERSION" true true
        else
          doctor_add registry schema warn "schemaVersion=$schema_v (expected $REGISTRY_SCHEMA_VERSION) — run with --repair" true false
        fi
      else
        doctor_add registry schema error "schemaVersion=$schema_v is newer than this CLI ($REGISTRY_SCHEMA_VERSION) — upgrade 5dive" false false
      fi
      local reg
      reg=$(registry_read)
      local name
      for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
        local type env_file user
        type=$(jq -r --arg n "$name" '.agents[$n].type // empty' <<<"$reg")
        env_file="${ENV_DIR}/${name}.env"
        user="agent-${name}"
        if ! is_known_type "$type"; then
          doctor_add registry "agent:$name" error "unknown type '$type' in registry" false false
          continue
        fi
        if ! id -u "$user" &>/dev/null; then
          doctor_add registry "agent:$name" error "user $user missing (orphan registry entry — rm manually)" false false
          continue
        fi
        if [[ ! -f "$env_file" ]]; then
          if (( DOCTOR_REPAIR )); then
            local channels workdir profile
            channels=$(jq -r --arg n "$name" '.agents[$n].channels // "none"'    <<<"$reg")
            workdir=$(jq  -r --arg n "$name" '.agents[$n].workdir // empty'      <<<"$reg")
            profile=$(jq  -r --arg n "$name" '.agents[$n].authProfile // empty'  <<<"$reg")
            write_agent_env "$name" "$type" "$channels" "$workdir" "$profile"
            link_agent_profile "$name" "$profile"
            doctor_add registry "agent:$name" ok "recreated $env_file" true true
          else
            doctor_add registry "agent:$name" error "$env_file missing (run with --repair)" true false
          fi
        else
          doctor_add registry "agent:$name" ok "entry + user + env file all present"
        fi
      done
    fi
  fi

  # --- channels: managed-settings allowlist + per-agent registration health ---
  #
  # Two failure modes we surface here:
  #   1. /etc/claude-code/managed-settings.json missing or missing the
  #      telegram@5dive-plugins entry — the local self-hosted case. Install.sh
  #      writes this on first install; flag if it's been hand-edited away.
  #   2. Claude logs "Channel notifications skipped: plugin telegram@5dive-plugins
  #      is not on the approved channels allowlist" — strong signal the agent
  #      is on a Teams org whose admin hasn't allowlisted us via remote
  #      managed-settings (remote overrides local). Linked from README.
  if (( run_channels )); then
    local ms=/etc/claude-code/managed-settings.json
    if [[ ! -f "$ms" ]]; then
      doctor_add channels managed-settings warn \
        "$ms missing — rerun install.sh, or expect channel-skipped errors" false false
    elif ! jq -e '.channelsEnabled == true' "$ms" >/dev/null 2>&1; then
      doctor_add channels managed-settings error \
        "$ms missing channelsEnabled:true (Claude Code 2.1.150+ requires this; allowlist is otherwise inert)" false false
    elif ! jq -e '.allowedChannelPlugins | any(.plugin == "telegram" and .marketplace == "5dive-plugins")' "$ms" >/dev/null 2>&1; then
      doctor_add channels managed-settings warn \
        "$ms doesn't list telegram@5dive-plugins — local channel allowlist won't permit the fork" false false
    else
      doctor_add channels managed-settings ok "$ms has channelsEnabled + telegram@5dive-plugins allowlisted"
    fi

    # Per-agent: read the MOST RECENT MCP log for the telegram plugin and
    # check whether the last channel-registration event was "registered" or
    # "skipped". The log path is per-user, per-cwd (slashes → dashes):
    #   ~/.cache/claude-cli-nodejs/<cwd-dashed>/mcp-logs-plugin-telegram-*/*.jsonl
    # We glob the plugin dir to stay tolerant of marketplace name changes.
    # "Skipped" almost always means a Teams-org remote managed-settings is
    # overriding the local allowlist — admin action required; we link docs.
    if [[ -f "$REGISTRY" ]]; then
      local reg name channels
      reg=$(registry_read 2>/dev/null || echo '{"agents":{}}')
      for name in $(jq -r '.agents | keys[]' <<<"$reg" 2>/dev/null); do
        channels=$(jq -r --arg n "$name" '.agents[$n].channels // ""' <<<"$reg")
        [[ "$channels" == *telegram* ]] || continue
        local user="agent-${name}"
        id -u "$user" &>/dev/null || continue
        # Latest jsonl across any telegram-plugin mcp-logs dir for this user.
        local latest
        latest=$(sudo -u "$user" bash -lc \
          'ls -1t "$HOME"/.cache/claude-cli-nodejs/*/mcp-logs-plugin-telegram-*/*.jsonl 2>/dev/null | head -1' \
          2>/dev/null)
        if [[ -z "$latest" ]]; then
          doctor_add channels "agent:$name" warn \
            "no telegram MCP logs found for $user (agent never started? channel not actually attached?)" false false
          continue
        fi
        # Look at the LAST occurrence of either event — agents may have
        # registered earlier then been told to skip, or vice versa.
        local last_event
        last_event=$(sudo -u "$user" grep -E 'Channel notifications (registered|skipped|.*not on the approved channels allowlist)' "$latest" 2>/dev/null | tail -1)
        if [[ "$last_event" == *"not on the approved channels allowlist"* ]]; then
          doctor_add channels "agent:$name" error \
            "claude logged 'Channel notifications skipped' — likely on an Anthropic Teams org. Org admin must allowlist telegram@5dive-plugins via console. See: https://github.com/$(gh_org)/5dive-plugins#anthropic-teams-accounts" \
            false false
        elif [[ "$last_event" == *"registered"* ]]; then
          doctor_add channels "agent:$name" ok "channel registered (latest MCP log: $(basename "$latest"))"
        else
          doctor_add channels "agent:$name" warn \
            "no channel-registration event found in latest MCP log $(basename "$latest") — restart the agent to refresh" false false
        fi

        # Plugin-version drift: Claude loads plugins once at launch, so an
        # agent that's been running since before the last `plugin update` is
        # still executing the OLD telegram plugin in memory (and its old hooks)
        # even though the on-disk cache is newer. This is the recurring
        # "/account mis-gated, /status missing the 5dive line, stale stop-hook"
        # class of bug. We detect it WITHOUT introspecting process memory: if
        # installed_plugins.json was modified AFTER the agent's claude process
        # started, the running code predates the update. --repair restarts the
        # agent (deferred) to load the fresh version.
        local manifest_f="/home/${user}/.claude/plugins/installed_plugins.json"
        if [[ -f "$manifest_f" ]]; then
          local ondisk_ver plug_mtime cpid
          ondisk_ver=$(jq -r '.plugins["telegram@5dive-plugins"][0].version // empty' "$manifest_f" 2>/dev/null)
          plug_mtime=$(stat -c %Y "$manifest_f" 2>/dev/null || echo 0)
          # Oldest (longest-running) claude process for this user = the
          # persistent session, not a transient hook subprocess. Pick max
          # elapsed-time among matches.
          cpid=$(pgrep -u "$user" -f 'claude' 2>/dev/null \
                 | while read -r p; do echo "$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ') $p"; done \
                 | sort -rn | awk 'NR==1{print $2}')
          if [[ -n "$cpid" && -n "$ondisk_ver" ]]; then
            local etimes start_epoch now_epoch
            etimes=$(ps -o etimes= -p "$cpid" 2>/dev/null | tr -d ' ')
            now_epoch=$(date +%s)
            if [[ "$etimes" =~ ^[0-9]+$ ]]; then
              start_epoch=$((now_epoch - etimes))
              if [[ "$plug_mtime" -gt "$start_epoch" ]]; then
                if (( DOCTOR_REPAIR )); then
                  if systemd-run --on-active=1 --collect \
                       /bin/systemctl restart "5dive-agent@${name}.service" >/dev/null 2>&1; then
                    doctor_add channels "agent:$name plugin-version" warn \
                      "was running a stale telegram plugin (on-disk $ondisk_ver, loaded before last update) — restart scheduled to load it" true true
                  else
                    doctor_add channels "agent:$name plugin-version" warn \
                      "running a stale telegram plugin (on-disk $ondisk_ver) — auto-restart failed; run: systemctl restart 5dive-agent@${name}.service" true false
                  fi
                else
                  doctor_add channels "agent:$name plugin-version" warn \
                    "running a stale telegram plugin — on-disk is $ondisk_ver but the agent loaded an older build at launch. Restart to apply: systemctl restart 5dive-agent@${name}.service (or 5dive doctor --repair)" true false
                fi
              else
                doctor_add channels "agent:$name plugin-version" ok "telegram plugin $ondisk_ver loaded (running matches on-disk)"
              fi
            fi
          fi
        fi
      done
    fi
  fi

  # --- shelld reachability (managed platform only) ---
  if (( run_shelld )); then
    if [[ ! -f /etc/5dive/provisioning.env ]]; then
      doctor_add shelld service ok "self-hosted install — shelld only runs on the managed platform"
    else
      local shelld_active
      shelld_active=$(systemctl is-active shelld 2>/dev/null || true)
      if [[ "$shelld_active" == "active" ]]; then
        doctor_add shelld service ok "shelld.service active"
      elif (( DOCTOR_REPAIR )); then
        step "Restarting shelld"
        if systemctl restart shelld >&2 \
           && [[ "$(systemctl is-active shelld 2>/dev/null)" == "active" ]]; then
          doctor_add shelld service ok "shelld restarted" true true
        else
          doctor_add shelld service error "shelld restart failed (check: journalctl -u shelld)" true false
        fi
      else
        doctor_add shelld service error "shelld.service not active (state=$shelld_active)" true false
      fi

      local health_code
      health_code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 \
        http://127.0.0.1:3101/shell/health 2>/dev/null || echo "000")
      if [[ "$health_code" == "200" ]]; then
        doctor_add shelld health ok "http://127.0.0.1:3101/shell/health -> 200"
      else
        doctor_add shelld health error "shelld health endpoint returned $health_code (expected 200)" false false
      fi
    fi
  fi

  # --- memory hygiene (DIVE-991) ---
  # Scans every agent's per-user memory store (0600, readable here since doctor
  # is root) plus the shared wiki for index drift, dangling [[links]], stale
  # source refs, and near-duplicates. Findings roll up as one doctor check per
  # store (kept coarse so a rotting store doesn't flood the dashboard with rows);
  # `5dive memory doctor --json` gives the itemized list. Non-fatal: a scan
  # failure (e.g. no python) degrades to a single warn, never aborts doctor.
  if (( run_memory )); then
    local mem_roots=() code_root=""
    for d in /home/claude/projects/5dive /home/claude/projects; do
      [[ -d "$d" ]] && { code_root="$d"; break; }
    done
    # Wiki (shared) + every agent home's memory stores.
    local wd
    for wd in /home/claude/projects/5dive/community/wiki; do
      [[ -d "$wd" ]] && mem_roots+=("$wd")
    done
    local home
    for home in /home/claude /home/agent-*; do
      [[ -d "$home/.claude/projects" ]] || continue
      local md
      for md in "$home"/.claude/projects/*/memory; do
        [[ -d "$md" ]] && mem_roots+=("$md")
      done
    done
    if (( ${#mem_roots[@]} == 0 )); then
      doctor_add memory stores warn "no memory stores found under /home/*/.claude/projects/*/memory"
    elif ! command -v python3 >/dev/null 2>&1; then
      doctor_add memory scan warn "python3 unavailable — memory hygiene scan skipped"
    else
      local mem_json=""
      mem_json=$(_memory_scan_json "$code_root" "${mem_roots[@]}" 2>/dev/null) || mem_json=""
      if [[ -z "$mem_json" ]] || ! jq -e '.stores' >/dev/null 2>&1 <<<"$mem_json"; then
        doctor_add memory scan warn "hygiene scan produced no parseable output"
      else
        # One row per store: ok when clean, else severity = worst finding with a
        # by-kind tally. The scanner's own roster is authoritative for store
        # names (single-sourced with the finding labels), so stores with zero
        # findings still report ok and the dashboard shows full coverage.
        local store_lines
        store_lines=$(jq -r '
          (.stores | unique) as $all |
          (.findings | group_by(.store) | map({key:.[0].store, value:.}) | from_entries) as $bys |
          $all[] |
          . as $s | ($bys[$s] // []) as $fs |
          {
            store: $s,
            errors: ([$fs[]|select(.severity=="error")]|length),
            warns:  ([$fs[]|select(.severity=="warn")]|length),
            tally:  ($fs | group_by(.kind) | map("\(length) \(.[0].kind)") | join(", "))
          } | @base64
        ' <<<"$mem_json")
        local line
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          local rec store errors warns tally sev msg
          rec=$(base64 -d <<<"$line")
          store=$(jq -r '.store' <<<"$rec")
          errors=$(jq -r '.errors' <<<"$rec")
          warns=$(jq -r '.warns' <<<"$rec")
          tally=$(jq -r '.tally' <<<"$rec")
          if (( errors > 0 )); then sev=error
          elif (( warns > 0 )); then sev=warn
          else sev=ok; fi
          if [[ "$sev" == ok ]]; then
            msg="clean"
          else
            msg="$tally (see: 5dive memory doctor --json)"
          fi
          doctor_add memory "$store" "$sev" "$msg"
        done <<<"$store_lines"
      fi
    fi
  fi

  # --- summary + output ---
  local summary
  summary=$(jq -c '{
    total:    length,
    passed:   [.[] | select(.severity == "ok")]    | length,
    warnings: [.[] | select(.severity == "warn")]  | length,
    errors:   [.[] | select(.severity == "error")] | length,
    repaired: [.[] | select(.repaired == true)]    | length
  }' <<<"$DOCTOR_CHECKS")

  local payload
  payload=$(jq -cn --argjson checks "$DOCTOR_CHECKS" --argjson summary "$summary" \
    '{summary: $summary, checks: $checks}')

  if (( JSON_MODE )); then
    jq -c '{ok:true, data: .}' <<<"$payload"
  else
    jq -r '
      .checks | group_by(.category) | .[] as $g |
      "── \($g[0].category) ──",
      ($g[] | "  [\(.severity)] \(.name): \(.message)\(if .repaired then " (repaired)" else "" end)"),
      ""
    ' <<<"$payload"
    jq -r '.summary |
      "summary: \(.total) checks, \(.passed) ok, \(.warnings) warn, \(.errors) error" +
      (if .repaired > 0 then ", \(.repaired) repaired" else "" end)
    ' <<<"$payload"
  fi
  # Always exit 0 — the envelope carries the real state via summary.errors.
  # Matches `auth status` (also informational). CI branches on the payload.
  return 0
}
