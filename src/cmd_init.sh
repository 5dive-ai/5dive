
# -------- 5dive init: interactive first-run wizard --------
# Orchestrates `agent install` + `agent auth` + `agent create` so a brand-new
# user can go from `curl | sudo bash` → working agent in one prompt-driven
# command. Everything it does is also reachable via the individual commands.

cmd_init() {
  if [[ ! -t 0 ]]; then
    fail "$E_USAGE" "5dive init is interactive — run it in a real terminal (not a pipe)"
  fi

  cat >&2 <<'WELCOME'

  ░█▀▄░▒█▀▄░▀█▀░█░▒█░█▀▀
  ░█░█░░█░█░░█░░▒█░▒█░█▀▀
  ░█▀▀░░█▀▀░▀▀▀░░▀▀▀░▀▀▀     interactive setup

WELCOME

  # --- Step 1: pick a type ---
  local -a types=(claude codex gemini hermes openclaw opencode)
  local -A type_desc=(
    [claude]="Anthropic's Claude — recommended"
    [codex]="OpenAI Codex"
    [gemini]="Google Gemini CLI"
    [hermes]="Open-source agent — bring your own provider"
    [openclaw]="Open-source agent — bring your own provider"
    [opencode]="Open-source agent backed by OpenAI key"
  )
  echo "Pick an agent type:" >&2
  local i=1
  for t in "${types[@]}"; do
    printf "  %d) %-9s — %s\n" "$i" "$t" "${type_desc[$t]}" >&2
    i=$((i+1))
  done
  echo >&2
  local choice type
  while true; do
    read -r -p "  choice [1-${#types[@]}, default 1]: " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[1-6]$ ]] && (( choice <= ${#types[@]} )); then
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
        local auth_choice
        read -r -p "  choice [1-2, default 1]: " auth_choice
        auth_choice="${auth_choice:-1}"
        if [[ "$auth_choice" == "1" ]]; then
          echo "  launching OAuth flow…" >&2
          5dive agent auth login claude || fail "$E_AUTH_REQUIRED" "auth failed"
        else
          local key
          read -r -s -p "  paste API key: " key; echo >&2
          [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
          printf '%s' "$key" | 5dive agent auth set claude --api-key=- || fail "$E_AUTH_REQUIRED" "auth failed"
        fi
        ;;
      codex|gemini|openclaw)
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
        local key
        read -r -s -p "  paste OpenAI API key: " key; echo >&2
        [[ -n "$key" ]] || fail "$E_VALIDATION" "empty API key"
        printf '%s' "$key" | 5dive agent auth set opencode --api-key=- \
          || fail "$E_AUTH_REQUIRED" "auth failed"
        ;;
    esac
    echo >&2
  fi

  # --- Step 4: name + create ---
  local name
  read -r -p "Name your first agent [my-agent]: " name
  name="${name:-my-agent}"
  echo "Creating agent '$name'…" >&2
  if ! 5dive agent create "$name" --type="$type" >&2; then
    fail "$E_GENERIC" "failed to create agent — see logs above"
  fi
  echo >&2

  # --- Step 5: next steps ---
  cat >&2 <<NEXT
✓ agent '$name' is ready.

Try it out:
  5dive agent send '$name' 'hello, who are you?'
  5dive agent ask  '$name' 'what model are you?' --timeout=60
  5dive agent $name tui                # attach a terminal
  5dive ui                              # web dashboard

Manage:
  5dive agent list
  5dive agent stats $name
  5dive doctor

NEXT
}
