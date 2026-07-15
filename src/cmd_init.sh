
# -------- 5dive init: interactive first-run wizard --------
# Orchestrates `agent install` + `agent auth` + `agent create` so a brand-new
# user can go from `curl | sudo bash` → working agent in one prompt-driven
# command. Everything it does is also reachable via the individual commands.

cmd_init() {
  # Fail fast before any prompts: every step the wizard drives (agent install /
  # create, channel wiring) is root-only — without this guard an unprivileged
  # user answers the whole questionnaire and dies mid-create instead.
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "init must run as root (sudo 5dive init)"
  if [[ ! -t 0 ]]; then
    fail "$E_USAGE" "5dive init is interactive — run it in a real terminal (not a pipe)"
  fi

  cat >&2 <<'WELCOME'

  ░█▀▀░█▀▄░▀█▀░█░█░█▀▀
  ░▀▀▄░█░█░░█░░█░█░█▀▀
  ░▀▀▀░█▀▀░▀▀▀░░▀░░▀▀▀     interactive setup

WELCOME

  # --- Step 1: pick a type ---
  local -a types=(claude codex antigravity grok hermes openclaw opencode pi)
  local -A type_desc=(
    [claude]="Anthropic's Claude — recommended"
    [codex]="OpenAI Codex"
    [antigravity]="Google Antigravity CLI"
    [grok]="xAI Grok CLI"
    [hermes]="Open-source agent — bring your own provider"
    [openclaw]="Open-source agent — bring your own provider"
    [opencode]="Open-source agent — bring your own provider"
    [pi]="Extension-based coding agent — bring your own provider"
  )
  echo "Pick an agent type:" >&2
  local i=1
  for t in "${types[@]}"; do
    printf "  %d) %-11s — %s\n" "$i" "$t" "${type_desc[$t]}" >&2
    i=$((i+1))
  done
  echo >&2
  local choice type
  while true; do
    read -r -p "  choice [1-${#types[@]}, default 1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[1-8]$ ]] && (( choice <= ${#types[@]} )); then
      type="${types[$((choice-1))]}"
      break
    fi
    echo "  invalid choice" >&2
  done
  echo "  → $type" >&2
  echo >&2

  # --- Step 2: install binary if missing ---
  echo "Checking $type CLI…" >&2
  if ! cmd_install "$type" >&2; then
    fail "$E_NOT_INSTALLED" "failed to install $type — try '5dive agent install $type' manually"
  fi
  echo >&2

  # --- Step 3: auth ---
  local auth_ok=0
  local byo_provider="" byo_key=""
  # Probe current auth state — cmd_auth_status returns 0 if any creds exist.
  if 5dive agent auth status --probe --type="$type" --json 2>/dev/null | jq -e '.ok and (.data | any(.status == "ok"))' >/dev/null 2>&1; then
    echo "✓ $type already authenticated" >&2
    auth_ok=1
  fi

  if (( auth_ok == 0 )); then
    echo "Auth for $type:" >&2
    case "$type" in
      claude)
        echo "  1) OAuth (recommended) — opens an interactive login session" >&2
        echo "  2) API key paste" >&2
        echo "  3) Custom provider — run Claude Code on a BYO Anthropic-compatible endpoint" >&2
        echo "     (OpenRouter, z.ai, DeepSeek, Moonshot)" >&2
        local auth_choice
        read -r -p "  choice [1-3, default 1]: " auth_choice
        auth_choice="${auth_choice:-1}"
        case "$auth_choice" in
          1)
            echo "  launching OAuth flow…" >&2
            5dive agent auth login claude || fail "$E_AUTH_REQUIRED" "auth failed"
            ;;
          2)
            local key
            read -r -s -p "  paste API key: " key; echo >&2
            [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
            printf '%s' "$key" | 5dive agent auth set claude --api-key=- || fail "$E_AUTH_REQUIRED" "auth failed"
            ;;
          3)
            # BYO Claude Code: run the claude harness against a third-party
            # Anthropic-compatible endpoint. Creds are wired at CREATE time via
            # --provider (Step 6) so ANTHROPIC_BASE_URL + per-tier model ids are
            # set from CLAUDE_PROVIDER_* in one shot — nothing to store now.
            local providers="${!CLAUDE_PROVIDER_BASEURL[*]}"
            echo "  Claude Code custom providers: $providers" >&2
            read -r -p "  provider [default openrouter]: " byo_provider
            byo_provider="${byo_provider:-openrouter}"
            [[ -n "${CLAUDE_PROVIDER_BASEURL[$byo_provider]:-}" ]] \
              || fail "$E_VALIDATION" "unknown provider '$byo_provider' (choose: $providers)"
            read -r -s -p "  paste $byo_provider API key: " byo_key; echo >&2
            [[ -n "$byo_key" ]] || fail "$E_VALIDATION" "empty API key"
            ;;
          *) fail "$E_VALIDATION" "invalid choice '$auth_choice'" ;;
        esac
        ;;
      codex|openclaw|antigravity|grok)
        echo "  launching interactive login for $type…" >&2
        5dive agent auth login "$type" || fail "$E_AUTH_REQUIRED" "auth failed"
        ;;
      hermes)
        local providers="openrouter anthropic openai google deepseek qwen nous minimax moonshot huggingface zai"
        echo "  hermes needs a provider + API key. Providers: $providers" >&2
        local provider
        read -r -p "  provider [default openrouter]: " provider
        provider="${provider:-openrouter}"
        local key
        read -r -s -p "  paste $provider API key: " key; echo >&2
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set hermes --api-key=- --provider="$provider" \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        ;;
      opencode)
        local providers="${!OPENCODE_PROVIDER_VAR[*]}"
        echo "  opencode needs a provider + API key. Providers: $providers" >&2
        local provider
        read -r -p "  provider [default openrouter]: " provider
        provider="${provider:-openrouter}"
        [[ -n "${OPENCODE_PROVIDER_VAR[$provider]:-}" ]] \
          || fail "$E_VALIDATION" "unknown provider '$provider' (choose: $providers)"
        local key
        read -r -s -p "  paste $provider API key: " key; echo >&2
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set opencode --api-key=- --provider="$provider" \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        ;;
      pi)
        local providers="${!PI_PROVIDER_VAR[*]}"
        echo "  pi needs a provider + API key. Providers: $providers" >&2
        local provider
        read -r -p "  provider [default anthropic]: " provider
        provider="${provider:-anthropic}"
        [[ -n "${PI_PROVIDER_VAR[$provider]:-}" ]] \
          || fail "$E_VALIDATION" "unknown pi provider '$provider' (choose: $providers)"
        local key
        read -r -s -p "  paste $provider API key: " key; echo >&2
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set pi --provider="$provider" --api-key=- \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        ;;
    esac
    echo >&2
  fi

  # --- Step 4: name ---
  local name
  read -r -p "Name your first agent [my-agent]: " name
  name="${name:-my-agent}"
  echo >&2

  # --- Step 5: pick a channel (mirrors the dashboard connect-flow) ---
  # Only claude/hermes/openclaw/pi expose telegram via `agent create --channels=`.
  # Other types fall straight through to create with channels=none.
  local channels="none"
  local telegram_token=""
  local telegram_user_id=""
  local supports_telegram=0
  case "$type" in
    claude|hermes|openclaw|pi) supports_telegram=1 ;;
  esac

  if (( supports_telegram == 1 )); then
    echo "Add a chat channel? (lets you message your agent from your phone)" >&2
    echo "  1) Skip — talk to your agent via 5dive CLI / TUI" >&2
    echo "  2) Telegram" >&2
    local ch_choice
    read -r -p "  choice [1-2, default 1]: " ch_choice
    ch_choice="${ch_choice:-1}"
    case "$ch_choice" in
      2) channels="telegram" ;;
      1) channels="none" ;;
      *) echo "  invalid choice — skipping" >&2; channels="none" ;;
    esac
    echo >&2
  fi

  local username=""
  if [[ "$channels" == "telegram" ]]; then
    echo "Get a bot token from BotFather: https://t.me/BotFather (send /newbot)" >&2
    read -r -s -p "  paste bot token: " telegram_token; echo >&2
    [[ -n "$telegram_token" ]] || fail "$E_VALIDATION" "empty bot token"
    echo >&2

    # Resolve bot @username up front (degrade silently on any failure —
    # discover still works, we just lose the tap-to-open hint).
    local getme_json
    getme_json=$(5dive agent telegram-getme --token="$telegram_token" --json 2>/dev/null || true)
    if jq -e '.ok and .data.username' <<<"$getme_json" >/dev/null 2>&1; then
      username=$(jq -r '.data.username' <<<"$getme_json")
      echo "Open Telegram → @$username → send /start. Waiting up to ~2 min…" >&2
    else
      echo "Open Telegram → your bot → send /start. Waiting up to ~2 min…" >&2
    fi

    # Long-poll for the first inbound DM so we can auto-allowlist the user
    # without a manual pair-code paste — same ~2-min budget as the
    # dashboard's discover loop. On miss, fall back to manual pair-code.
    local attempt discover_json
    for attempt in 1 2; do
      discover_json=$(5dive agent telegram-discover --token="$telegram_token" --poll-secs=60 --json 2>/dev/null || true)
      if jq -e '.ok and .data.found' <<<"$discover_json" >/dev/null 2>&1; then
        telegram_user_id=$(jq -r '.data.userId' <<<"$discover_json")
        local who
        who=$(jq -r '.data.username // .data.firstName // empty' <<<"$discover_json")
        echo "  ✓ detected${who:+ ($who)} → id $telegram_user_id" >&2
        break
      fi
      (( attempt == 1 )) && echo "  still waiting…" >&2
    done

    if [[ -z "$telegram_user_id" ]]; then
      echo "  → no DM yet. We'll create the agent now; pair after with:" >&2
      echo "       5dive agent pair $name --code=<code-from-bot>" >&2
    fi
    echo >&2
  fi

  # --- Step 5.5: pick isolation tier ---
  # Surface the privilege tier explicitly (mirrors `agent create` defaults):
  # pi is sandboxed (extensions run arbitrary code); the first agent on a fresh
  # box gets admin so the box has a fleet manager out of the gate; every other
  # agent is least-privilege standard. Any choice can be overridden here.
  local iso_default="standard"
  if [[ "$type" == "pi" ]]; then
    iso_default="sandboxed"
  elif [[ "$(registry_read 2>/dev/null | jq -r '(.agents // {}) | length' 2>/dev/null || echo 1)" == "0" ]]; then
    iso_default="admin"
  fi
  local -a iso_opts=(admin standard sandboxed)
  local -A iso_desc=(
    [admin]="full trust: can run the 5dive CLI + sudo (fleet managers, dev agents)"
    [standard]="least privilege: scoped access, cannot run the 5dive CLI"
    [sandboxed]="isolated from the shared workspace, own workdir (untrusted / extension agents)"
  )
  echo "Pick isolation:" >&2
  local iso_j=1 iso_default_idx=2 iso_t
  for iso_t in "${iso_opts[@]}"; do
    printf '  %d) %-9s  %s\n' "$iso_j" "$iso_t" "${iso_desc[$iso_t]}" >&2
    [[ "$iso_t" == "$iso_default" ]] && iso_default_idx=$iso_j
    iso_j=$((iso_j+1))
  done
  local isolation iso_choice
  while true; do
    read -r -p "  choice [1-3, default ${iso_default_idx} (${iso_default})]: " iso_choice
    iso_choice="${iso_choice:-$iso_default_idx}"
    if [[ "$iso_choice" =~ ^[1-3]$ ]]; then
      isolation="${iso_opts[$((iso_choice-1))]}"
      break
    fi
    echo "  please choose 1, 2, or 3" >&2
  done
  echo >&2

  # --- Step 6: create ---
  local -a create_args=("$name" "--type=$type" "--isolation=$isolation")
  if [[ "$channels" != "none" ]]; then
    create_args+=("--channels=$channels")
    [[ -n "$telegram_token" ]] && create_args+=("--telegram-token=$telegram_token")
    [[ -n "$telegram_user_id" ]] && create_args+=("--telegram-allowed-users=$telegram_user_id")
  fi
  echo "Creating agent '$name'…" >&2
  if [[ -n "$byo_provider" ]]; then
    # BYO Claude Code: provider + key wired at create; profile named after the
    # provider. Key on stdin so it never lands in argv/history.
    create_args+=("--provider=$byo_provider" "--api-key=-" "--auth-profile=$byo_provider")
    if ! printf '%s' "$byo_key" | 5dive agent create "${create_args[@]}" >&2; then
      fail "$E_GENERIC" "failed to create agent — see logs above"
    fi
  elif ! 5dive agent create "${create_args[@]}" >&2; then
    fail "$E_GENERIC" "failed to create agent — see logs above"
  fi
  echo >&2

  # --- Step 7: auto-pair welcome DM (claude+telegram with auto-detected id) ---
  # openclaw/hermes wire the allowlist inside `agent create` itself, so the
  # extra pair call only applies to claude — same gate the dashboard uses.
  if [[ "$type" == "claude" && "$channels" == "telegram" && -n "$telegram_user_id" ]]; then
    5dive agent pair "$name" --user-id="$telegram_user_id" >&2 || true
    echo >&2
  fi

  # --- Step 8: next steps ---
  cat >&2 <<NEXT
✓ agent '$name' is ready.

Try it out:
  5dive agent send '$name' 'hello, who are you?'
  5dive agent ask  '$name' 'what model are you?' --timeout=60
  5dive agent $name tui                # attach a terminal

NEXT

  if [[ "$channels" == "telegram" && -n "$telegram_user_id" ]]; then
    cat >&2 <<TG
From your phone:
  open Telegram → ${username:+@$username → }DM your bot directly

TG
  elif [[ "$channels" == "telegram" ]]; then
    cat >&2 <<TG
Finish Telegram pairing:
  5dive agent pair $name --code=<code-from-bot>
  (open Telegram, DM your bot — it replies with a pair code)

TG
  fi

  # Heads-up for Teams-org accounts: remote managed-settings can silently
  # override the local channel allowlist (Console-controlled). The check
  # runs as part of `5dive doctor --category=channels` after the agent boots.
  if [[ "$channels" == "telegram" ]]; then
    cat >&2 <<TEAMS
Anthropic Teams accounts:
  if your bot stays silent on incoming DMs, your org admin may need to
  allowlist this plugin in the Anthropic Console. Diagnose with:
    sudo 5dive doctor --category=channels
  Setup snippet: https://github.com/$(gh_org)/5dive-plugins#anthropic-teams-accounts

TEAMS
  fi

  cat >&2 <<MANAGE
Manage:
  5dive agent list
  5dive agent stats $name
  5dive doctor

MANAGE
}
