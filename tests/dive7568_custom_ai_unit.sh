#!/usr/bin/env bash
# DIVE-7568 unit: «Your own AI» on every harness, and `account test`.
#
# WHAT IS ASSERTED HERE (graded against the SHIPPED code, sourced or extracted)
#   URL.     http:// to a private IPv4 address (10/8, 172.16/12, 192.168/16,
#            127/8) is accepted with local-only OFF; public http:// and a name
#            are still refused. The /v1 shapes each format needs.
#   SAVE.    account add --provider=custom writes the one record; a key is
#            optional and a short one is accepted (no 10-character minimum);
#            claude also gets its ANTHROPIC_* vars (keyless → placeholder token);
#            an unknown harness and a public http:// address are refused.
#   RENDER.  5dive-agent-start's renderers write each harness's own config:
#            codex config.toml, hermes config set + .env, openclaw config patch,
#            pi models.json + settings.json, opencode opencode.json. The key is
#            never on argv; a re-run is idempotent; a seat of another harness is
#            not touched.
#   TEST.    account test against a stub server: ok (anthropic, chat, responses),
#            and each failure reason — unreachable, bad_key, no_such_model,
#            no_tools (text answer, and a tools refusal), wrong_format.
#   LOCAL.   with local-only on, account test / add --provider=custom to a
#            public address are refused; to an office address they pass.
#
# Fixture addresses: private ones (10.x, 172.16-31.x, 192.168.x) are the
# feature's subject and identify nothing; every PUBLIC one is an RFC 5737
# documentation address.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi; }

for f in src/header.sh src/lib/error_codes.sh src/lib/output.sh src/lib/validation.sh src/lib/local_only.sh src/cmd_account_custom.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e
export FIVE_REPORTED_FLAG="$TMP/reported"
export FIVE_LOCAL_ONLY_FILE="$TMP/local-only"   # absent → switch off

# ── URL ─────────────────────────────────────────────────────────────────────
n=0
for u in http://10.0.0.5:11434 http://172.16.0.9:8000/v1 http://172.31.255.1 http://192.168.1.20:11434/v1 http://127.0.0.2:1234 https://gpu.example.com/v1; do
  valid_base_url "$u" || { n=$((n+1)); bad_t "URL: refused $u"; }
done
for u in http://172.32.0.1 http://172.15.0.1 http://192.169.0.1 http://192.0.2.10:8000 http://198.51.100.7 http://gpu.lan:8000 "http://10.0.0.5:1/a b" http://999.1.1.1; do
  valid_base_url "$u" && { n=$((n+1)); bad_t "URL: accepted $u"; }
done
(( n == 0 )) && ok_t "URL: private IPv4 http:// accepted with local-only off; public, out-of-range and names refused (14 cases)"
eq_t "URL: openai base adds /v1 to a bare host" "http://10.0.0.5:11434/v1" "$(custom_ai_openai_url http://10.0.0.5:11434/)"
eq_t "URL: openai base keeps /v1" "http://10.0.0.5:11434/v1" "$(custom_ai_openai_url http://10.0.0.5:11434/v1)"
eq_t "URL: openai base keeps a gateway path" "https://gw.example.com/api/openai" "$(custom_ai_openai_url https://gw.example.com/api/openai/)"
eq_t "URL: anthropic base drops /v1 (the client appends /v1/messages)" "http://10.0.0.5:11434" "$(custom_ai_anthropic_url http://10.0.0.5:11434/v1/)"

# ── SAVE ────────────────────────────────────────────────────────────────────
require_root() { :; }
step() { :; }
ensure_profile_dir() { :; }
profile_env_value() { echo ""; }
registry_read() { echo '{"agents":{}}'; }
systemctl() { :; }
profile_set_var() { printf '%s %s=%s|argv=%s\n' "$1" "$2" "$(cat)" "$*" >> "$TMP/prof"; }
_apply_byo_claude() { printf 'CLAUDE %s\n' "$*" >> "$TMP/claude"; }
JSON_MODE=1
: > "$TMP/prof"; : > "$TMP/claude"
out=$(printf 'abc' | cmd_account_add_custom office --provider=custom --base-url=http://192.168.1.20:11434 --model=qwen3:32b --harness=pi --api-key=- 2>&1)
eq_t "SAVE: a 3-character key is accepted (JSON ok)" "true" "$(jq -r .ok <<<"$out" 2>/dev/null)"
grep -qx 'office FIVEDIVE_CUSTOM_API_KEY=abc|argv=office FIVEDIVE_CUSTOM_API_KEY' "$TMP/prof" \
  && ok_t "SAVE: the key lands in the account from stdin, never argv" || bad_t "SAVE: key write wrong: $(cat "$TMP/prof")"
grep -qx 'office FIVEDIVE_CUSTOM_HARNESS=pi|argv=office FIVEDIVE_CUSTOM_HARNESS' "$TMP/prof" \
  && grep -qx 'office FIVEDIVE_CUSTOM_BASE_URL=http://192.168.1.20:11434|argv=office FIVEDIVE_CUSTOM_BASE_URL' "$TMP/prof" \
  && grep -qx 'office FIVEDIVE_CUSTOM_MODEL=qwen3:32b|argv=office FIVEDIVE_CUSTOM_MODEL' "$TMP/prof" \
  && ok_t "SAVE: harness, address and model are recorded" || bad_t "SAVE: record incomplete: $(cat "$TMP/prof")"
[[ ! -s "$TMP/claude" ]] && ok_t "SAVE: a pi account writes no claude vars" || bad_t "SAVE: pi wrote claude vars"
: > "$TMP/prof"
out=$(cmd_account_add_custom office2 --provider=custom --base-url=http://10.0.0.5:11434/v1 --model=llama3.3 --harness=claude </dev/null 2>&1)
eq_t "SAVE: no key at all is accepted" "false" "$(jq -r .data.hasKey <<<"$out" 2>/dev/null)"
eq_t "SAVE: claude gets the anthropic base (no /v1) and a placeholder token" \
  "CLAUDE custom no-key-required office2 llama3.3 http://10.0.0.5:11434" "$(cat "$TMP/claude")"
out=$( (cmd_account_add_custom o3 --provider=custom --base-url=http://10.0.0.5 --model=m --harness=gemini) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--harness must be one of"* ]] && ok_t "SAVE: an unknown harness is refused" || bad_t "SAVE: unknown harness rc=$rc $out"
out=$( (cmd_account_add_custom o3 --provider=custom --base-url=http://203.0.113.9:8000 --model=m --harness=pi) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"invalid --base-url"* ]] && ok_t "SAVE: a public http:// address is refused" || bad_t "SAVE: public http rc=$rc $out"
out=$( (cmd_account_add_custom o3 --provider=custom --base-url=http://10.0.0.5 --harness=pi) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--model=<name> is required"* ]] && ok_t "SAVE: no model is refused" || bad_t "SAVE: no model rc=$rc $out"

# ── HINT (DIVE-7659): the "New agent" line is the office panel's own call ────
# agent create defaults to channels=none; the hint must add --channels=dashboard
# (cmd_local_panel.sh agent-add) for a harness with a web chat, and never for one
# without (pi, opencode take no chat channel).
JSON_MODE=0
out=$( (cmd_account_add_custom office-ai --provider=custom --base-url=http://192.168.1.20:11434 --model=m --harness=claude </dev/null) 2>&1)
[[ "$out" == *"New agent: sudo 5dive agent create <name> --type=claude --auth-profile=office-ai --channels=dashboard"* ]] \
  && ok_t "HINT: a claude account's hint is the office panel's call (--auth-profile + --channels=dashboard)" || bad_t "HINT: claude hint wrong: $out"
out=$( (cmd_account_add_custom office-pi --provider=custom --base-url=http://192.168.1.20:11434 --model=m --harness=pi </dev/null) 2>&1)
[[ "$out" == *"--type=pi --auth-profile=office-pi"* && "$out" != *"--channels="* ]] \
  && ok_t "HINT: a pi account's hint has no chat channel" || bad_t "HINT: pi hint wrong: $out"
panel_call=$(grep -o 'agent create "\$name" --type="\$h" --auth-profile="\$acct" --channels=dashboard' src/cmd_local_panel.sh)
[[ -n "$panel_call" ]] && ok_t "HINT: the office panel still makes that call (cmd_local_panel.sh agent-add)" || bad_t "HINT: the panel's agent-add call moved; re-check the hint"
usb=$(sed -n '/^### No internet at all: install from a USB stick/,/^### /p' docs/guide.md)
[[ "$usb" == *"sudo 5dive agent create <name> --type=claude --auth-profile=office-ai --channels=dashboard"* && "$usb" != *"--type=claude --base-url="* ]] \
  && ok_t "HINT: the guide's USB section adds the agent with --auth-profile and the office chat" || bad_t "HINT: guide USB add-agent line wrong"
JSON_MODE=1

# ── PARKED (quinn it2: --replace must not wake a parked agent) ───────────────
# `systemctl restart` on a stopped unit STARTS it (DIVE-4399). Only the exact
# desiredState "stopped" skips; absent, null or any other value restarts (an
# unknown must not freeze an agent on the old address).
profile_env_value() { echo "http://10.0.0.1:11434"; }
registry_read() { echo '{"agents":{"katya":{"authProfile":"office","desiredState":"stopped"},"nova":{"authProfile":"office","desiredState":"running"},"ivy":{"authProfile":"office"},"zed":{"authProfile":"office","desiredState":"Stopped"},"rex":{"authProfile":"other","desiredState":"running"}}}'; }
systemctl() { echo "$*" >> "$TMP/sysctl"; }
mkdir -p "$TMP/profiles/office"; AUTH_PROFILES_DIR="$TMP/profiles"
: > "$TMP/sysctl"
out=$( (cmd_account_add_custom office --provider=custom --base-url=http://10.0.0.5:11434 --model=m --harness=pi --replace </dev/null) 2>&1); rc=$?
eq_t "PK1 --replace saves (rc 0)" "0" "$rc"
eq_t "PK2 --replace restarts the running, unknown-state and non-exact agents on the account, and only those" \
  "restart 5dive-agent@ivy.service|restart 5dive-agent@nova.service|restart 5dive-agent@zed.service" "$(sort "$TMP/sysctl" | paste -sd'|')"
grep -q katya "$TMP/sysctl" && bad_t "PK3 the parked agent was restarted (woken)" || ok_t "PK3 the parked agent (desiredState=stopped) is left down"
: > "$TMP/sysctl"
out=$( (cmd_account_add_custom office --provider=custom --base-url=http://10.0.0.5:11434 --model=m --harness=pi </dev/null) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--replace"* && ! -s "$TMP/sysctl" ]] && ok_t "PK4 control: without --replace a moved account is refused and nothing restarts" || bad_t "PK4 rc=$rc $out"
profile_env_value() { echo ""; }
registry_read() { echo '{"agents":{}}'; }
systemctl() { :; }

# ── RENDER ──────────────────────────────────────────────────────────────────
START=bin/5dive-agent-start
blk="$(sed -n '/^# >>> custom-ai renderers (DIVE-7568) >>>$/,/^# <<< custom-ai renderers (DIVE-7568) <<<$/p' "$START")"
[[ -n "$blk" ]] || { echo "FATAL - could not extract the renderer block from $START"; exit 1; }
eval "$blk"
grep -q '^\[\[ "\$TYPE" == hermes \]\] || custom_ai_apply "\$TYPE"$' "$START" \
  && grep -q '^  custom_ai_apply hermes$' "$START" \
  && ok_t "RENDER: the start script calls the renderer (hermes before its gateway restart, the rest before launch)" \
  || bad_t "RENDER: the start script does not call custom_ai_apply"
export FIVEDIVE_CUSTOM_BASE_URL=http://192.168.1.20:11434 FIVEDIVE_CUSTOM_MODEL=qwen3:32b FIVEDIVE_CUSTOM_API_KEY=sk-local-1

# codex
H="$TMP/codex"; mkdir -p "$H/.codex"
printf 'model = "gpt-5.5"\napproval_policy = "never"\n\n[projects."/w"]\ntrust_level = "trusted"\n' > "$H/.codex/config.toml"
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=codex custom_ai_apply codex
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=codex custom_ai_apply codex
cfg="$H/.codex/config.toml"
eq_t "RENDER codex: model_provider + model at the top" 'model_provider = "fivedive-custom"|model = "qwen3:32b"' "$(head -2 "$cfg" | paste -sd'|')"
eq_t "RENDER codex: one provider table after two starts" "1" "$(grep -c '^\[model_providers.fivedive-custom\]$' "$cfg")"
eq_t "RENDER codex: the old model line is gone" "1" "$(grep -c '^model = ' "$cfg")"
grep -q '^base_url = "http://192.168.1.20:11434/v1"$' "$cfg" && grep -q '^wire_api = "responses"$' "$cfg" \
  && grep -q '^env_key = "FIVEDIVE_CUSTOM_API_KEY"$' "$cfg" && grep -q '^\[projects."/w"\]$' "$cfg" && grep -q '^approval_policy = "never"$' "$cfg" \
  && ! grep -q 'sk-local-1' "$cfg" \
  && ok_t "RENDER codex: base_url /v1, responses, env_key names the variable (key not in the file), other settings kept" \
  || bad_t "RENDER codex: $(cat "$cfg")"
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=codex FIVEDIVE_CUSTOM_API_KEY="" custom_ai_apply codex
! grep -q '^env_key' "$cfg" && ok_t "RENDER codex: a keyless server gets no env_key" || bad_t "RENDER codex: env_key with no key"

# hermes
H="$TMP/hermes"; mkdir -p "$H/.hermes"
cat > "$TMP/hermes-bin" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERMES_LOG"
EOF
chmod +x "$TMP/hermes-bin"
export HERMES_LOG="$TMP/hermes.log"; : > "$HERMES_LOG"
printf 'OTHER=1\nFIVEDIVE_CUSTOM_API_KEY=old\n' > "$H/.hermes/.env"
HOME="$H" BIN="$TMP/hermes-bin" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
eq_t "RENDER hermes: custom provider, /v1 base, model, key by reference" \
  'config set model.provider custom|config set model.base_url http://192.168.1.20:11434/v1|config set model.default qwen3:32b|config set model.api_key ${FIVEDIVE_CUSTOM_API_KEY}' \
  "$(paste -sd'|' "$HERMES_LOG")"
eq_t "RENDER hermes: the key is in the seat's .env, replaced, others kept" "OTHER=1|FIVEDIVE_CUSTOM_API_KEY=sk-local-1" "$(paste -sd'|' "$H/.hermes/.env")"
! grep -q sk-local-1 "$HERMES_LOG" && ok_t "RENDER hermes: the key is never on argv" || bad_t "RENDER hermes: key on argv"
# DIVE-7730: local-only turns hermes' update check and models.dev catalog off;
# off again puts them back only when the catalog still carries our address.
grep -q 'models_dev' "$HERMES_LOG" && bad_t "RENDER hermes: catalog touched with local-only off" || ok_t "RENDER hermes: local-only off and no mark → catalog and update check untouched"
LOF="$TMP/local-only-flag"; : > "$LOF"; : > "$HERMES_LOG"
HOME="$H" BIN="$TMP/hermes-bin" FIVE_LOCAL_ONLY_FILE="$LOF" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
grep -qx 'config set updates.check false' "$HERMES_LOG" && grep -qx 'config set models_dev.url http://127.0.0.1:9/' "$HERMES_LOG" \
  && grep -qx 'config set model_catalog.enabled false' "$HERMES_LOG" \
  && ok_t "RENDER hermes: local-only on → update check, model catalog off, models.dev pointed at a closed local port" || bad_t "RENDER hermes: local-only on: $(paste -sd'|' "$HERMES_LOG")"
eq_t "RENDER hermes: local-only on → web calls go to a closed local port except the office AI and this box" \
  "OTHER=1|FIVEDIVE_CUSTOM_API_KEY=sk-local-1|HTTPS_PROXY=http://127.0.0.1:9|HTTP_PROXY=http://127.0.0.1:9|NO_PROXY=192.168.1.20,localhost,127.0.0.1,::1" \
  "$(paste -sd'|' "$H/.hermes/.env")"
HOME="$H" BIN="$TMP/hermes-bin" FIVE_LOCAL_ONLY_FILE="$LOF" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
eq_t "RENDER hermes: a second local-only start writes the proxy lines once" "1|1" \
  "$(grep -c '^HTTPS_PROXY=' "$H/.hermes/.env")|$(grep -c '^NO_PROXY=' "$H/.hermes/.env")"
rm -f "$LOF"; printf 'models_dev:\n  url: http://127.0.0.1:9/\nupdates:\n  check: false\n' > "$H/.hermes/config.yaml"; : > "$HERMES_LOG"
HOME="$H" BIN="$TMP/hermes-bin" FIVE_LOCAL_ONLY_FILE="$LOF" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
grep -qx 'config set models_dev.url ' "$HERMES_LOG" && grep -qx 'config set updates.check true' "$HERMES_LOG" \
  && grep -qx 'config set model_catalog.enabled true' "$HERMES_LOG" \
  && ok_t "RENDER hermes: local-only off → our catalog address removed, update check and model catalog back on" || bad_t "RENDER hermes: off with mark: $(paste -sd'|' "$HERMES_LOG")"
eq_t "RENDER hermes: local-only off → our proxy lines and their NO_PROXY gone, the rest kept" "OTHER=1|FIVEDIVE_CUSTOM_API_KEY=sk-local-1" "$(paste -sd'|' "$H/.hermes/.env")"
printf 'OTHER=1\nNO_PROXY=corp.lan\n' > "$H/.hermes/.env"
HOME="$H" BIN="$TMP/hermes-bin" FIVE_LOCAL_ONLY_FILE="$LOF" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
grep -qx 'NO_PROXY=corp.lan' "$H/.hermes/.env" && ok_t "RENDER hermes: an owner's own NO_PROXY is kept when the mode is off" || bad_t "RENDER hermes: owner NO_PROXY lost"
printf 'models_dev:\n  url: https://mirror.corp/api.json\n' > "$H/.hermes/config.yaml"; : > "$HERMES_LOG"
HOME="$H" BIN="$TMP/hermes-bin" FIVE_LOCAL_ONLY_FILE="$LOF" FIVEDIVE_CUSTOM_HARNESS=hermes custom_ai_apply hermes
! grep -q 'models_dev\|updates' "$HERMES_LOG" && ok_t "RENDER hermes: local-only off keeps an owner's own catalog mirror" || bad_t "RENDER hermes: mirror touched"
rm -f "$H/.hermes/config.yaml"

# openclaw
cat > "$TMP/openclaw-bin" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$OC_LOG.argv"; cat > "$OC_LOG.stdin"
EOF
chmod +x "$TMP/openclaw-bin"; export OC_LOG="$TMP/oc"
HOME="$TMP" CUSTOM_AI_OPENCLAW_BIN="$TMP/openclaw-bin" FIVEDIVE_CUSTOM_HARNESS=openclaw custom_ai_apply openclaw
eq_t "RENDER openclaw: patched through its own CLI on stdin" "config patch --stdin" "$(cat "$OC_LOG.argv")"
eq_t "RENDER openclaw: provider + primary model" \
  'http://192.168.1.20:11434/v1|openai-completions|sk-local-1|qwen3:32b|fivedive-custom/qwen3:32b|merge' \
  "$(jq -r '[.models.providers["fivedive-custom"] | .baseUrl, .api, .apiKey, .models[0].id] + [.agents.defaults.model.primary, .models.mode] | join("|")' "$OC_LOG.stdin")"
eq_t "RENDER openclaw: a slow office AI gets 30 min for its first words, not openclaw's 300 s (DIVE-7730)" "1800" \
  "$(jq -r '.models.providers["fivedive-custom"].timeoutSeconds' "$OC_LOG.stdin")"
# DIVE-7730: local-only turns the hosted catalog and the update hint off; off
# puts them back only when both are still off.
eq_t "RENDER openclaw: local-only off, nothing written before → catalog and update hint untouched" "null|null" \
  "$(jq -r '[.models.catalogRefresh, .update] | map(tostring) | join("|")' "$OC_LOG.stdin")"
LOF="$TMP/local-only-flag"; : > "$LOF"
HOME="$TMP" FIVE_LOCAL_ONLY_FILE="$LOF" CUSTOM_AI_OPENCLAW_BIN="$TMP/openclaw-bin" FIVEDIVE_CUSTOM_HARNESS=openclaw custom_ai_apply openclaw
eq_t "RENDER openclaw: local-only on → hosted catalog refresh and start-time update check off" "false|false|fivedive-custom/qwen3:32b" \
  "$(jq -r '[.models.catalogRefresh.enabled, .update.checkOnStart, .agents.defaults.model.primary] | map(tostring) | join("|")' "$OC_LOG.stdin")"
eq_t "RENDER openclaw: local-only on → the gateway's web calls go to a closed local port except the office AI and this box" \
  "http://127.0.0.1:9|http://127.0.0.1:9|192.168.1.20,localhost,127.0.0.1,::1|1" "${HTTPS_PROXY:-}|${HTTP_PROXY:-}|${NO_PROXY:-}|${NODE_USE_ENV_PROXY:-}"
unset HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_USE_ENV_PROXY
rm -f "$LOF"; mkdir -p "$TMP/.openclaw"; printf '{"models":{"catalogRefresh":{"enabled":false}},"update":{"checkOnStart":false}}' > "$TMP/.openclaw/openclaw.json"
HOME="$TMP" FIVE_LOCAL_ONLY_FILE="$LOF" CUSTOM_AI_OPENCLAW_BIN="$TMP/openclaw-bin" FIVEDIVE_CUSTOM_HARNESS=openclaw custom_ai_apply openclaw
eq_t "RENDER openclaw: local-only off → both back on" "true|true" "$(jq -r '[.models.catalogRefresh.enabled, .update.checkOnStart] | map(tostring) | join("|")' "$OC_LOG.stdin")"
eq_t "RENDER openclaw: local-only off → no proxy exported" "|" "${HTTPS_PROXY:-}|${NODE_USE_ENV_PROXY:-}"
printf '{"update":{"checkOnStart":false}}' > "$TMP/.openclaw/openclaw.json"
HOME="$TMP" FIVE_LOCAL_ONLY_FILE="$LOF" CUSTOM_AI_OPENCLAW_BIN="$TMP/openclaw-bin" FIVEDIVE_CUSTOM_HARNESS=openclaw custom_ai_apply openclaw
eq_t "RENDER openclaw: local-only off keeps an owner's own update-check choice" "null" "$(jq -c '.update' "$OC_LOG.stdin")"
rm -rf "$TMP/.openclaw"

# pi
H="$TMP/pi"; mkdir -p "$H/.pi/agent"; printf '{"theme":"dark","defaultModel":"x"}' > "$H/.pi/agent/settings.json"
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=pi custom_ai_apply pi
eq_t "RENDER pi: models.json provider (key by variable name)" \
  'http://192.168.1.20:11434/v1|openai-completions|FIVEDIVE_CUSTOM_API_KEY|qwen3:32b' \
  "$(jq -r '.providers["fivedive-custom"] | [.baseUrl, .api, .apiKey, .models[0].id] | join("|")' "$H/.pi/agent/models.json")"
eq_t "RENDER pi: settings default, other settings kept" 'fivedive-custom|qwen3:32b|dark' \
  "$(jq -r '[.defaultProvider, .defaultModel, .theme] | join("|")' "$H/.pi/agent/settings.json")"

# opencode
H="$TMP/oc-home"; mkdir -p "$H/.config/opencode"; printf '{"provider":{"openai":{}},"theme":"x"}' > "$H/.config/opencode/opencode.json"
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=opencode custom_ai_apply opencode
f="$H/.config/opencode/opencode.json"
eq_t "RENDER opencode: openai-compatible provider, env key, model" \
  '@ai-sdk/openai-compatible|http://192.168.1.20:11434/v1|{env:FIVEDIVE_CUSTOM_API_KEY}|qwen3:32b|fivedive-custom/qwen3:32b|x|true' \
  "$(jq -r '[(.provider["fivedive-custom"] | .npm, .options.baseURL, .options.apiKey, (.models|keys[0])), .model, .theme, (.provider|has("openai"))] | map(tostring) | join("|")' "$f")"

# mismatch: a pi account bound to a codex seat writes nothing
H="$TMP/mismatch"; mkdir -p "$H/.codex"; printf 'model = "gpt-5.5"\n' > "$H/.codex/config.toml"
HOME="$H" FIVEDIVE_CUSTOM_HARNESS=pi custom_ai_apply codex
eq_t "RENDER: a seat of another harness is not touched" 'model = "gpt-5.5"' "$(cat "$H/.codex/config.toml")"
# a value that would break the config file is skipped with a warning
H="$TMP/bad"; mkdir -p "$H/.codex"; : > "$H/.codex/config.toml"
w=$(HOME="$H" FIVEDIVE_CUSTOM_HARNESS=codex FIVEDIVE_CUSTOM_MODEL='m"x' custom_ai_apply codex 2>&1)
[[ ! -s "$H/.codex/config.toml" && "$w" == *skipped* ]] && ok_t "RENDER: a model with a quote is skipped, not written" || bad_t "RENDER: bad value written: $w"
unset FIVEDIVE_CUSTOM_BASE_URL FIVEDIVE_CUSTOM_MODEL FIVEDIVE_CUSTOM_API_KEY

# ── TEST (stub server) ──────────────────────────────────────────────────────
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
log = open(sys.argv[2], "a")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        req = json.loads(self.rfile.read(n) or b"{}")
        auth = self.headers.get("authorization") or ""
        log.write("%s %s %s\n" % (self.path, auth, self.headers.get("x-api-key") or "")); log.flush()
        mode, _, route = self.path.lstrip("/").partition("/")
        route = "/" + route
        m = req.get("model", "")
        routes = {"both": ["/v1/messages", "/v1/chat/completions", "/v1/responses"],
                  "chatonly": ["/v1/chat/completions"]}[mode]
        if route not in routes:
            return self.send(404, {"error": "404 page not found"})
        if auth == "Bearer wrong-key":
            return self.send(401, {"error": {"message": "invalid api key"}})
        if m == "missing":
            return self.send(404, {"error": {"message": 'model "missing" not found, try pulling it first'}})
        if m == "notools":
            return self.send(400, {"error": {"message": "registry.ollama.ai/library/notools does not support tools"}})
        tool = m != "texty"
        if route == "/v1/messages":
            c = [{"type": "tool_use", "id": "t1", "name": "add", "input": {"a": 2, "b": 3}}] if tool else [{"type": "text", "text": '{"name":"add"}'}]
            return self.send(200, {"type": "message", "role": "assistant", "content": c})
        if route == "/v1/responses":
            o = [{"type": "function_call", "name": "add", "arguments": "{}"}] if tool else [{"type": "message", "content": []}]
            return self.send(200, {"object": "response", "output": o})
        msg = {"role": "assistant", "content": None, "tool_calls": [{"type": "function", "function": {"name": "add", "arguments": "{}"}}]} if tool else {"role": "assistant", "content": '<tool_call>{"name":"add"}</tool_call>'}
        return self.send(200, {"choices": [{"message": msg}]})
s = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$TMP/stub.py" "$TMP/port" "$TMP/req.log" & SRV_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP/port" ]] && break; sleep 0.1; done
P=$(cat "$TMP/port" 2>/dev/null)
[[ -n "$P" ]] || { echo "FATAL - stub server did not start"; exit 1; }
CUSTOM_AI_TEST_TIMEOUT=10
at() {   # <base> <model> <harness> [key] → "envelope.ok|data.ok|data.format|data.reason|rc"
  # The app parses the envelope's data (DIVE-7569); a probe that ran is a result,
  # so the envelope is ok:true and rc 0 even on a NOT OK verdict.
  local o rc
  o=$( (JSON_MODE=1; printf '%s' "${4:-}" | cmd_account_test --base-url="$1" --model="$2" --harness="$3" --api-key=-) 2>/dev/null); rc=$?
  printf '%s|%s' "$(jq -r '[.ok, .data.ok, .data.format, .data.reason] | map(tostring) | join("|")' <<<"$o" 2>/dev/null)" "$rc"
}
B="http://127.0.0.1:$P/both/v1"; C="http://127.0.0.1:$P/chatonly/v1"
eq_t "TEST: claude on a server that speaks both → ok, anthropic" "true|true|anthropic|null|0" "$(at "$B" good claude)"
eq_t "TEST: pi → ok, openai" "true|true|openai|null|0" "$(at "$B" good pi)"
eq_t "TEST: codex → ok, openai (Responses API)" "true|true|openai|null|0" "$(at "$B" good codex)"
eq_t "TEST: nothing listening → unreachable" "true|false|null|unreachable|0" "$(at "http://127.0.0.1:9/v1" good hermes)"
eq_t "TEST: a refused key → bad_key" "true|false|null|bad_key|0" "$(at "$B" good opencode wrong-key)"
eq_t "TEST: an unknown model → no_such_model" "true|false|null|no_such_model|0" "$(at "$B" missing openclaw)"
eq_t "TEST: a tool call written as text (qwen3:4b, DIVE-7560) → no_tools" "true|false|openai|no_tools|0" "$(at "$B" texty pi)"
eq_t "TEST: a model that refuses tools → no_tools" "true|false|openai|no_tools|0" "$(at "$B" notools hermes)"
eq_t "TEST: claude on an OpenAI-only server → wrong_format, format openai" "true|false|openai|wrong_format|0" "$(at "$C" good claude)"
eq_t "TEST: codex on a chat-only server → wrong_format, format openai" "true|false|openai|wrong_format|0" "$(at "$C" good codex)"
eq_t "TEST: hermes on the same chat-only server → ok" "true|true|openai|null|0" "$(at "$C" good hermes)"
: > "$TMP/req.log"; at "$B" good claude sk-local-9 >/dev/null
grep -q '^/both/v1/messages Bearer sk-local-9 sk-local-9$' "$TMP/req.log" \
  && ok_t "TEST: the key reaches the server as a header (anthropic: x-api-key + bearer)" || bad_t "TEST: key header: $(cat "$TMP/req.log")"
out=$( (JSON_MODE=1; cmd_account_test --base-url=http://203.0.113.9/v1 --model=m --harness=pi </dev/null) 2>&1); rc=$?
[[ $rc -eq $E_VALIDATION && "$out" == *"invalid --base-url"* ]] && ok_t "TEST: a public http:// address is refused before any request" || bad_t "TEST: public http rc=$rc $out"
for u in "http://127.0.0.1:$P/both/v1?x=1" "http://127.0.0.1:$P/both/v1#f"; do
  out=$( (JSON_MODE=1; cmd_account_test --base-url="$u" --model=good --harness=codex </dev/null) 2>&1); rc=$?
  [[ $rc -eq $E_VALIDATION && "$out" == *"no ? or #"* ]] && ok_t "TEST: a ? or # in the address is refused (${u##*v1})" || bad_t "TEST: ?/# rc=$rc $out"
done
out=$( (JSON_MODE=1; cmd_account_add_custom o4 --provider=custom --base-url="http://127.0.0.1:1/v1?x=1" --model=m --harness=pi </dev/null) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"no ? or #"* ]] && ok_t "SAVE: a ? in the address is refused" || bad_t "SAVE: ? rc=$rc $out"
out=$( (JSON_MODE=0; printf '' | cmd_account_test --base-url=http://127.0.0.1:9/v1 --model=m --harness=pi --api-key=-) 2>/dev/null); rc=$?
[[ $rc -eq 0 && "$out" == "NOT OK (unreachable) — "* ]] && ok_t "TEST: text mode prints NOT OK (reason) and exits 0 (a probe that ran is a result)" || bad_t "TEST: text rc=$rc $out"

# ── LOCAL ───────────────────────────────────────────────────────────────────
: > "$FIVE_LOCAL_ONLY_FILE"
out=$( (local_only_gate account test --base-url=https://api.example.com/v1 --model=m --harness=pi) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"local-only mode is on"* ]] && ok_t "LOCAL: account test to an outside server is refused" || bad_t "LOCAL: test outside rc=$rc $out"
out=$( (local_only_gate account add o --provider=custom --base-url=https://api.example.com/v1 --model=m --harness=pi) 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"local-only mode is on"* ]] && ok_t "LOCAL: account add --provider=custom to an outside server is refused" || bad_t "LOCAL: add outside rc=$rc $out"
( local_only_gate account test --base-url=http://gpu.lan:11434 --model=m --harness=pi ) >/dev/null 2>&1 \
  && ( local_only_gate account add o --provider=custom --base-url=http://10.0.0.5:11434 --model=m --harness=pi ) >/dev/null 2>&1 \
  && ( local_only_gate account add plain ) >/dev/null 2>&1 \
  && ok_t "LOCAL: office addresses pass, and a plain account add is untouched" || bad_t "LOCAL: an office address was refused"
rm -f "$FIVE_LOCAL_ONLY_FILE"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
