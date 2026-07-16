
# -------- 5dive init: interactive first-run wizard --------
# Orchestrates `agent install` + `agent auth` + `agent create` so a brand-new
# user can go from `curl | sudo bash` → working agent in one prompt-driven
# command. Everything it does is also reachable via the individual commands.

# The init flow deliberately stays dependency-free: these helpers use only
# Bash + ANSI sequences, fall back to numbered prompts on a dumb terminal, and
# honor NO_COLOR. DIVE-1326 benchmarks the calm, explicit first-run flows in
# Codex / Claude Code / Gemini CLI without copying any one product's chrome.
_init_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]
}

_init_welcome() {
  local cyan="" bold="" dim="" reset=""
  if _init_color_enabled; then
    cyan=$'\033[38;5;81m'; bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
  fi
  printf '\n  %s%s5dive%s\n' "$cyan" "$bold" "$reset" >&2
  printf '  %sYour AI team, running on your box.%s\n' "$bold" "$reset" >&2
  printf '  %sSet up your first agent in a few guided steps.%s\n\n' "$dim" "$reset" >&2
}

_init_section() {
  local current="$1" total="$2" title="$3" detail="${4:-}"
  local cyan="" bold="" dim="" reset=""
  if _init_color_enabled; then
    cyan=$'\033[38;5;81m'; bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
  fi
  printf '  %s%s%02d / %02d%s  %s%s%s\n' \
    "$cyan" "$bold" "$current" "$total" "$reset" "$bold" "$title" "$reset" >&2
  [[ -n "$detail" ]] && printf '  %s%s%s\n' "$dim" "$detail" "$reset" >&2
  echo >&2
}

_init_ok() {
  local green="" reset=""
  _init_color_enabled && { green=$'\033[38;5;77m'; reset=$'\033[0m'; }
  printf '  %s✓%s %s\n' "$green" "$reset" "$*" >&2
}

_init_note() {
  local dim="" reset=""
  _init_color_enabled && { dim=$'\033[2m'; reset=$'\033[0m'; }
  printf '  %s%s%s\n' "$dim" "$*" "$reset" >&2
}

_init_warn() {
  local amber="" reset=""
  _init_color_enabled && { amber=$'\033[38;5;214m'; reset=$'\033[0m'; }
  printf '  %s!%s %s\n' "$amber" "$reset" "$*" >&2
}

# _init_pick <out-var> <title> <default-1-based> <value|label|description>...
# Arrow keys + j/k move, Enter accepts, and 1-9 are fast direct shortcuts.
# TERM=dumb gets a plain numbered prompt so serial consoles remain usable.
_init_pick() {
  local out_var="$1" title="$2" default_idx="$3"; shift 3
  local -a options=("$@")
  local count="${#options[@]}" selected=$((default_idx - 1))
  (( selected >= 0 && selected < count )) || selected=0
  local spec value label description i key tail choice

  printf '  %s\n' "$title" >&2
  if [[ "${TERM:-dumb}" == "dumb" || ! -t 0 || ! -t 2 ]]; then
    i=1
    for spec in "${options[@]}"; do
      IFS='|' read -r value label description <<<"$spec"
      printf '    %d. %-18s %s\n' "$i" "$label" "$description" >&2
      i=$((i + 1))
    done
    while true; do
      read -r -p "  Choose [${default_idx}]: " choice
      choice="${choice:-$default_idx}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
        selected=$((choice - 1))
        break
      fi
      _init_warn "Choose a number from 1 to $count."
    done
  else
    local first_render=1 cyan="" bold="" dim="" reset="" shortcut_max="$count"
    local desc_width=$(( ${COLUMNS:-80} - 25 )) shown_description
    (( desc_width < 12 )) && desc_width=12
    (( shortcut_max > 9 )) && shortcut_max=9
    if _init_color_enabled; then
      cyan=$'\033[38;5;81m'; bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
    fi
    while true; do
      if (( first_render == 0 )); then
        printf '\033[%dA' "$((count + 1))" >&2
      fi
      for ((i = 0; i < count; i++)); do
        IFS='|' read -r value label description <<<"${options[$i]}"
        shown_description="$description"
        if (( ${#shown_description} > desc_width )); then
          shown_description="${shown_description:0:$((desc_width - 1))}…"
        fi
        printf '\033[2K\r' >&2
        if (( i == selected )); then
          printf '  %s%s› %-18s%s %s\n' "$cyan" "$bold" "$label" "$reset" "$shown_description" >&2
        else
          printf '    %-18s %s%s%s\n' "$label" "$dim" "$shown_description" "$reset" >&2
        fi
      done
      printf '\033[2K\r  %s↑/↓ move · Enter select · 1-%d shortcut%s\n' "$dim" "$shortcut_max" "$reset" >&2
      first_render=0

      IFS= read -r -s -n1 key || return 130
      case "$key" in
        '') break ;;
        $'\033')
          tail=""
          IFS= read -r -s -n2 -t 0.15 tail || true
          case "$tail" in
            '[A') selected=$(((selected - 1 + count) % count)) ;;
            '[B') selected=$(((selected + 1) % count)) ;;
          esac
          ;;
        k|K) selected=$(((selected - 1 + count) % count)) ;;
        j|J) selected=$(((selected + 1) % count)) ;;
        [1-9])
          if (( key <= count )); then selected=$((key - 1)); break; fi
          ;;
      esac
    done
  fi

  IFS='|' read -r value label description <<<"${options[$selected]}"
  printf -v "$out_var" '%s' "$value"
  _init_ok "$label"
  echo >&2
}

_init_text() {
  local out_var="$1" label="$2" default_value="${3:-}" value
  if [[ -n "$default_value" ]]; then
    read -r -p "  › $label [$default_value]: " value
    value="${value:-$default_value}"
  else
    read -r -p "  › $label: " value
  fi
  printf -v "$out_var" '%s' "$value"
}

# Character-at-a-time masked input gives visible feedback for paste and typing
# without ever echoing the secret. Backspace and Ctrl-U behave like a shell.
_init_secret() {
  local out_var="$1" label="$2" value="" char
  local LC_ALL=C
  printf '  › %s: ' "$label" >&2
  while IFS= read -r -s -n1 char; do
    [[ -z "$char" ]] && break
    case "$char" in
      $'\177'|$'\b')
        if [[ -n "$value" ]]; then
          value="${value%?}"
          printf '\b \b' >&2
        fi
        ;;
      $'\025')
        while [[ -n "$value" ]]; do value="${value%?}"; printf '\b \b' >&2; done
        ;;
      *) value+="$char"; printf '*' >&2 ;;
    esac
  done
  echo >&2
  printf -v "$out_var" '%s' "$value"
}

_init_review_row() {
  printf '    %-14s %s\n' "$1" "$2" >&2
}

# Verbose vs. quiet sub-step output. `5dive init` drives noisy sub-processes —
# the CLI install, `agent create`, the pairing call — whose raw stdout/stderr
# (installer progress, marketplace refresh chatter, `==>` create logs, the
# expected-pending self-check warnings) leak into the otherwise-clean wizard.
# Default (verbose) keeps streaming them, which is useful when a first run
# breaks. Under `--quiet`/`--demo` they are redirected to a per-run log and the
# user sees only a spinner + a ✓/✗ line, with the log path surfaced solely on
# failure. DIVE-1352.
_INIT_QUIET=0
_INIT_LOG=""

# _init_run <label> <command...>
# Owns the whole label lifecycle (leading note / spinner + trailing ✓/✗) so
# call sites don't print their own. Inherits this function's stdin, so a caller
# may pipe a secret in: `printf %s "$key" | _init_run "…" 5dive agent create …`.
_init_run() {
  local label="$1"; shift
  local rc=0
  if (( _INIT_QUIET == 0 )); then
    _init_note "$label…"
    "$@" >&2 || rc=$?
    if (( rc == 0 )); then _init_ok "$label"; else _init_warn "$label failed"; fi
    return "$rc"
  fi
  # Quiet: run in the background, animate a spinner, capture output to the log.
  local frames='|/-\' fi=0
  local cyan="" dim="" reset=""
  _init_color_enabled && { cyan=$'\033[38;5;81m'; dim=$'\033[2m'; reset=$'\033[0m'; }
  "$@" >>"$_INIT_LOG" 2>&1 &
  local pid=$!
  printf '\033[?25l' >&2
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s%s%s ' "$cyan" "${frames:fi:1}" "$reset" "$dim" "$label" "$reset" >&2
    fi=$(( (fi + 1) % ${#frames} ))
    sleep 0.1
  done
  wait "$pid" || rc=$?
  printf '\033[?25h\033[2K\r' >&2
  if (( rc == 0 )); then _init_ok "$label"; else _init_warn "$label failed — see $_INIT_LOG"; fi
  return "$rc"
}

cmd_init() {
  # --- Flags: --quiet/--demo suppress sub-process noise (see _init_run) ---
  local _arg
  for _arg in "$@"; do
    case "$_arg" in
      --quiet|--demo) _INIT_QUIET=1 ;;
      -h|--help)
        cat >&2 <<'USAGE'
5dive init [--quiet]
  Interactive first-run wizard: install a runtime, authenticate, and create
  your first agent.
  --quiet, --demo   Hide install/create sub-process output behind a spinner
                    (a clean capture for demos); full logs go to
                    /tmp/5dive-init-<ts>.log. Default streams everything.
USAGE
        return 0 ;;
      *) fail "$E_USAGE" "unknown flag '$_arg' (see: 5dive init --help)" ;;
    esac
  done
  if (( _INIT_QUIET == 1 )); then
    _INIT_LOG="/tmp/5dive-init-$(date +%Y%m%d-%H%M%S)-$$.log"
    : > "$_INIT_LOG" 2>/dev/null || _INIT_LOG="/tmp/5dive-init-$$.log"
  fi

  # Fail fast before any prompts: every step the wizard drives (agent install /
  # create, channel wiring) is root-only — without this guard an unprivileged
  # user answers the whole questionnaire and dies mid-create instead.
  [[ $EUID -eq 0 ]] || fail "$E_PERMISSION" "init must run as root (sudo 5dive init)"
  if [[ ! -t 0 ]]; then
    fail "$E_USAGE" "5dive init is interactive — run it in a real terminal (not a pipe)"
  fi

  _init_welcome
  _init_section 1 4 "Choose a runtime" \
    "Pick the coding agent that will power your first teammate."

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
  local -A type_label=(
    [claude]="Claude Code"
    [codex]="Codex"
    [antigravity]="Antigravity"
    [grok]="Grok"
    [hermes]="Hermes"
    [openclaw]="OpenClaw"
    [opencode]="OpenCode"
    [pi]="Pi"
  )
  local -a type_menu=()
  local t
  for t in "${types[@]}"; do
    type_menu+=("$t|${type_label[$t]}|${type_desc[$t]}")
  done
  local type
  _init_pick type "Pick an agent type:" 1 "${type_menu[@]}"

  # --- Step 2: install binary if missing ---
  _init_section 2 4 "Connect ${type_label[$type]}" \
    "Use an existing sign-in, an interactive login, or your own provider key."
  if ! _init_run "Setting up the ${type_label[$type]} CLI" cmd_install "$type"; then
    fail "$E_NOT_INSTALLED" "failed to install $type — try '5dive agent install $type' manually"
  fi
  echo >&2

  # --- Step 3: auth ---
  local auth_ok=0 auth_summary="Existing credentials"
  local byo_provider="" byo_key="" pi_model="" pi_provider="" pi_key=""
  # Probe current auth state — cmd_auth_status returns 0 if any creds exist.
  if 5dive agent auth status --probe --type="$type" --json 2>/dev/null | jq -e '.ok and (.data | any(.status == "ok"))' >/dev/null 2>&1; then
    _init_ok "${type_label[$type]} is already authenticated"
    auth_ok=1
  fi

  if (( auth_ok == 0 )); then
    case "$type" in
      claude)
        local auth_choice
        _init_pick auth_choice "How should Claude Code authenticate?" 1 \
          "oauth|Sign in with Claude|Recommended · use your Claude subscription" \
          "api-key|Anthropic API key|Usage-based billing from Anthropic Console" \
          "custom|Custom provider|OpenRouter, z.ai, DeepSeek, or Moonshot"
        case "$auth_choice" in
          oauth)
            _init_note "Opening Claude's interactive sign-in…"
            5dive agent auth login claude || fail "$E_AUTH_REQUIRED" "auth failed"
            auth_summary="Claude sign-in"
            ;;
          api-key)
            local key
            _init_secret key "Anthropic API key"
            [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
            printf '%s' "$key" | 5dive agent auth set claude --api-key=- || fail "$E_AUTH_REQUIRED" "auth failed"
            _init_ok "Anthropic API key saved"
            auth_summary="Anthropic API key"
            ;;
          custom)
            # BYO Claude Code: run the claude harness against a third-party
            # Anthropic-compatible endpoint. Creds are wired at CREATE time via
            # --provider (Step 6) so ANTHROPIC_BASE_URL + per-tier model ids are
            # set from CLAUDE_PROVIDER_* in one shot — nothing to store now.
            _init_pick byo_provider "Choose a custom provider:" 1 \
              "openrouter|OpenRouter|Broad model catalog · recommended" \
              "zai|z.ai|GLM models over Anthropic-compatible API" \
              "deepseek|DeepSeek|DeepSeek models over Anthropic-compatible API" \
              "moonshot|Moonshot|Kimi models over Anthropic-compatible API"
            [[ -n "${CLAUDE_PROVIDER_BASEURL[$byo_provider]:-}" ]] \
              || fail "$E_VALIDATION" "unknown provider '$byo_provider'"
            _init_secret byo_key "${byo_provider} API key"
            [[ -n "$byo_key" ]] || fail "$E_VALIDATION" "empty API key"
            auth_summary="$byo_provider API key"
            ;;
          *) fail "$E_VALIDATION" "invalid auth choice '$auth_choice'" ;;
        esac
        ;;
      codex)
        local auth_choice
        _init_pick auth_choice "How should Codex authenticate?" 1 \
          "chatgpt|Sign in with ChatGPT|Use a one-time device code · recommended" \
          "api-key|OpenAI API key|Usage-based API billing"
        case "$auth_choice" in
          chatgpt)
            _init_note "Opening Codex device-code sign-in…"
            5dive agent auth login codex || fail "$E_AUTH_REQUIRED" "auth failed"
            auth_summary="ChatGPT sign-in"
            ;;
          api-key)
            local key
            _init_secret key "OpenAI API key"
            [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
            printf '%s' "$key" | 5dive agent auth set codex --api-key=- \
              || fail "$E_AUTH_REQUIRED" "auth failed"
            _init_ok "OpenAI API key saved"
            auth_summary="OpenAI API key"
            ;;
        esac
        ;;
      openclaw|antigravity|grok)
        _init_note "Opening ${type_label[$type]}'s interactive sign-in…"
        5dive agent auth login "$type" || fail "$E_AUTH_REQUIRED" "auth failed"
        auth_summary="Interactive sign-in"
        ;;
      hermes)
        local provider
        _init_pick provider "Choose a provider for Hermes:" 1 \
          "openrouter|OpenRouter|Broad model catalog · recommended" \
          "anthropic|Anthropic|Claude models" \
          "openai|OpenAI|GPT models" \
          "google|Google|Gemini models" \
          "deepseek|DeepSeek|DeepSeek models" \
          "qwen|Qwen|Qwen models" \
          "nous|Nous|Nous-hosted models" \
          "minimax|MiniMax|MiniMax models" \
          "moonshot|Moonshot|Kimi models" \
          "huggingface|Hugging Face|Hosted open models" \
          "zai|z.ai|GLM models"
        local key
        _init_secret key "$provider API key"
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set hermes --api-key=- --provider="$provider" \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        _init_ok "$provider credentials saved"
        auth_summary="$provider API key"
        ;;
      opencode)
        local provider
        _init_pick provider "Choose a provider for OpenCode:" 1 \
          "openrouter|OpenRouter|Broad model catalog · recommended" \
          "openai|OpenAI|GPT models"
        [[ -n "${OPENCODE_PROVIDER_VAR[$provider]:-}" ]] \
          || fail "$E_VALIDATION" "unknown provider '$provider'"
        local key
        _init_secret key "$provider API key"
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set opencode --api-key=- --provider="$provider" \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        _init_ok "$provider credentials saved"
        auth_summary="$provider API key"
        ;;
      pi)
        local provider
        _init_pick provider "Choose a provider for Pi:" 1 \
          "anthropic|Anthropic|Claude models · recommended" \
          "openrouter|OpenRouter|Broad model catalog" \
          "openai|OpenAI|GPT models" \
          "google|Google|Gemini models" \
          "deepseek|DeepSeek|DeepSeek models" \
          "moonshotai|Moonshot AI|Kimi models" \
          "kimi-coding|Kimi Coding|Kimi coding models" \
          "zai|z.ai|GLM models" \
          "minimax|MiniMax|MiniMax models"
        [[ -n "${PI_PROVIDER_VAR[$provider]:-}" ]] \
          || fail "$E_VALIDATION" "unknown pi provider '$provider'"
        # openrouter is a multi-model gateway — pi can't route without an explicit
        # model, so require one here and pin it at create via --model.
        if [[ "$provider" == "openrouter" ]]; then
          _init_note "OpenRouter routes many models; enter the exact model slug."
          _init_text pi_model "Model (for example anthropic/claude-sonnet-4)"
          [[ -n "$pi_model" ]] || fail "$E_VALIDATION" "openrouter needs a model (none given)"
        fi
        # Defer the key to `agent create` (below) so it takes the SAME wiring
        # path as `agent create --provider/--api-key`: pi_apply_provider_key
        # persists the key to the agent's connector AND pi_apply_model_default
        # sets defaultProvider + defaultModel. The early `auth set` path wrote
        # the key to the default connector but left the created agent with
        # defaultProvider="" → pi errored "No API key found for the selected
        # model" on openrouter. DIVE-1269.
        pi_provider="$provider"
        _init_secret pi_key "$provider API key"
        [[ -n "$pi_key" ]] || fail "$E_VALIDATION" "empty API key"
        auth_summary="$provider API key"
        ;;
    esac
    echo >&2
  fi

  # --- Step 4: name ---
  _init_section 3 4 "Shape your agent" \
    "Choose its name, where you can reach it, and how much access it receives."
  local name
  while true; do
    _init_text name "Agent name" "my-agent"
    valid_name "$name" && break
    _init_warn "Use lowercase letters, numbers, and hyphens; start with a letter (max 16)."
  done
  _init_ok "Your agent will be named $name"
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
    local ch_choice
    _init_pick ch_choice "Where do you want to talk to $name?" 1 \
      "cli|Terminal only|Use the 5dive CLI or attach to its TUI" \
      "telegram|Telegram|Message your agent from your phone"
    case "$ch_choice" in
      telegram) channels="telegram" ;;
      cli) channels="none" ;;
      *) fail "$E_VALIDATION" "invalid channel choice '$ch_choice'" ;;
    esac
  fi

  local username=""
  if [[ "$channels" == "telegram" ]]; then
    _init_note "Create a bot with @BotFather first: https://t.me/BotFather (send /newbot)"
    _init_secret telegram_token "Telegram bot token"
    [[ -n "$telegram_token" ]] || fail "$E_VALIDATION" "empty bot token"
    _init_ok "Telegram token captured"
    echo >&2

    # Resolve bot @username up front (degrade silently on any failure —
    # discover still works, we just lose the tap-to-open hint).
    local getme_json
    getme_json=$(5dive agent telegram-getme --token="$telegram_token" --json 2>/dev/null || true)
    if jq -e '.ok and .data.username' <<<"$getme_json" >/dev/null 2>&1; then
      username=$(jq -r '.data.username' <<<"$getme_json")
      _init_note "Open Telegram → @$username → send /start. Waiting up to ~2 min…"
    else
      _init_note "Open Telegram → your bot → send /start. Waiting up to ~2 min…"
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
        _init_ok "Telegram connected${who:+ ($who)}"
        break
      fi
      (( attempt == 1 )) && _init_note "Still waiting for /start…"
    done

    if [[ -z "$telegram_user_id" ]]; then
      _init_warn "No message yet; you can pair after setup."
      _init_note "5dive agent pair $name --code=<code-from-bot>"
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
  local iso_j=1 iso_default_idx=2 iso_t
  for iso_t in "${iso_opts[@]}"; do
    [[ "$iso_t" == "$iso_default" ]] && iso_default_idx=$iso_j
    iso_j=$((iso_j+1))
  done
  local isolation
  _init_pick isolation "Pick isolation:" "$iso_default_idx" \
    "admin|Admin|${iso_desc[admin]}" \
    "standard|Standard|${iso_desc[standard]}" \
    "sandboxed|Sandboxed|${iso_desc[sandboxed]}"

  # --- Step 5.75: review before the irreversible create ---
  _init_section 4 4 "Review and create" \
    "Nothing below is secret. Confirm the setup before 5dive creates the agent."
  _init_review_row "Agent" "$name"
  _init_review_row "Runtime" "${type_label[$type]}"
  _init_review_row "Credentials" "$auth_summary"
  _init_review_row "Isolation" "$isolation"
  if [[ "$channels" == "telegram" ]]; then
    _init_review_row "Channel" "Telegram${username:+ (@$username)}"
  else
    _init_review_row "Channel" "Terminal only"
  fi
  [[ -n "$pi_model" ]] && _init_review_row "Model" "$pi_model"
  echo >&2

  local create_choice
  _init_pick create_choice "Ready to create $name?" 1 \
    "create|Create agent|Install configuration and start the agent" \
    "cancel|Cancel setup|Exit without creating an agent"
  if [[ "$create_choice" == "cancel" ]]; then
    _init_note "Setup cancelled. No agent was created."
    return 0
  fi

  # --- Step 6: create ---
  local -a create_args=("$name" "--type=$type" "--isolation=$isolation")
  # pi + a gateway provider (openrouter) needs its model pinned at create -> pi_apply_model_default.
  [[ -n "$pi_model" ]] && create_args+=("--model=$pi_model")
  if [[ "$channels" != "none" ]]; then
    create_args+=("--channels=$channels")
    [[ -n "$telegram_token" ]] && create_args+=("--telegram-token=$telegram_token")
    [[ -n "$telegram_user_id" ]] && create_args+=("--telegram-allowed-users=$telegram_user_id")
  fi
  local create_rc=0
  if [[ -n "$byo_provider" ]]; then
    # BYO Claude Code: provider + key wired at create; profile named after the
    # provider. Key on stdin so it never lands in argv/history.
    create_args+=("--provider=$byo_provider" "--api-key=-" "--auth-profile=$byo_provider")
    printf '%s' "$byo_key" | _init_run "Creating $name" 5dive agent create "${create_args[@]}" || create_rc=$?
  elif [[ -n "$pi_provider" ]]; then
    # pi BYO: provider + key (+ model for gateways like openrouter, already
    # appended above) wired at create so it runs pi_apply_provider_key AND
    # pi_apply_model_default — same path `agent create --provider` uses, so the
    # agent boots with defaultProvider set and the key persisted. Key on stdin
    # so it never lands in argv/history. DIVE-1269.
    create_args+=("--provider=$pi_provider" "--api-key=-")
    printf '%s' "$pi_key" | _init_run "Creating $name" 5dive agent create "${create_args[@]}" || create_rc=$?
  else
    _init_run "Creating $name" 5dive agent create "${create_args[@]}" || create_rc=$?
  fi
  if (( create_rc != 0 )); then
    if (( _INIT_QUIET )); then
      fail "$E_GENERIC" "failed to create agent — see $_INIT_LOG"
    else
      fail "$E_GENERIC" "failed to create agent — see logs above"
    fi
  fi
  echo >&2

  # --- Step 7: auto-pair welcome DM (claude+telegram with auto-detected id) ---
  # openclaw/hermes wire the allowlist inside `agent create` itself, so the
  # extra pair call only applies to claude — same gate the dashboard uses.
  if [[ "$type" == "claude" && "$channels" == "telegram" && -n "$telegram_user_id" ]]; then
    _init_run "Pairing $name with Telegram" 5dive agent pair "$name" --user-id="$telegram_user_id" || true
    echo >&2
  fi

  # --- Step 8: next steps ---
  echo >&2
  _init_ok "$name is ready"
  _init_note "Your first teammate is running. Start with one of these:"
  cat >&2 <<NEXT

    5dive agent send '$name' 'hello, who are you?'
    5dive agent ask  '$name' 'what model are you?' --timeout=60
    5dive agent $name tui

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
  Manage your team:
    5dive agent list
    5dive agent stats $name
    5dive doctor

MANAGE
}
