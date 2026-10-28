#!/usr/bin/env bash
# DIVE-7102 — on a self-hosted box, a hire never needs a token or a key typed into
# chat. On 2026-10-27 the lead hired an OpenClaw agent with Telegram and asked the
# owner for a BotFather token and then for an OpenRouter key, both pasted into
# plain app chat; the seat still never answered, because the key never reached
# the store openclaw reads. Graded here:
#   1. the rule: which logins count for openclaw/hermes (a Claude account is not
#      one) and which box key a new seat may reuse (never the demo AI);
#   2. the real cmd_create, stopped where the agent user would be made, for every
#      way a lead hires (agent create, import's argv, hermes, explicit flags);
#   3. on a box linked to 5dive.app chat, --channels=telegram with no token makes
#      the seat on the app chat and says "Connect Telegram", never refuses;
#   4. the key goes into the SEAT's own openclaw store, through openclaw's CLI,
#      on stdin (openclaw 2026.8.1+ keeps it where the boot seed never looks).
# Pure: no root, no network.  bash tests/selfhost_no_secret_in_chat_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/lib/models.sh
# shellcheck disable=SC1091
source src/lib/agent_setup.sh
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
# shellcheck disable=SC1091
source src/cmd_auth.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
TYPE_AUTH[openclaw]="$TMP/shared/.openclaw/agents/main/agent/openclaw-agent.sqlite"
TYPE_AUTH[hermes]="$TMP/shared/.hermes/auth.json"
mkdir -p "$TMP/bin"
for _t in claude codex openclaw hermes; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"
  TYPE_BIN[$_t]="$TMP/bin/$_t"
done
cmd_install() { printf 'INSTALL-ATTEMPTED %s\n' "$*"; return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"

OR_KEY='sk-or-v1-fixture-lead-key-0123456789'
DEMO_KEY='sk-or-v1-fixture-demo-key-0123456789'
ANT_KEY='sk-ant-api03-fixture-0123456789'
# The lead's account on the QA box: a Claude account set up with
# --provider=openrouter, so its key is ANTHROPIC_AUTH_TOKEN under OpenRouter's URL.
ORTEST="or-test:ANTHROPIC_BASE_URL=https://openrouter.ai/api|ANTHROPIC_AUTH_TOKEN=$OR_KEY"
DEMO="demo-ai:ANTHROPIC_BASE_URL=https://openrouter.ai/api|ANTHROPIC_AUTH_TOKEN=$DEMO_KEY"
EMERG="emergency-api:ANTHROPIC_API_KEY=$ANT_KEY"
OAUTH='mp:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fixture-mp-token'

# box <account:LINE|LINE>... — each arg is one account and its combined.env lines.
box() {
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$FIVEDIVE_CHAT_ONLY_MARK" "$TMP/shared"
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  local a
  for a in "$@"; do
    mkdir -p "$AUTH_PROFILES_DIR/${a%%:*}"
    tr '|' '\n' <<<"${a#*:}" > "$AUTH_PROFILES_DIR/${a%%:*}/combined.env"
  done
  # The demo key is always in its connector file on a managed box. It must never
  # be what a new seat gets.
  printf 'OPENROUTER_API_KEY=%s\n' "$DEMO_KEY" > "$CONNECTORS_DIR/openrouter.env"
}
pick() { # <type> [account...] — "<account> <provider> <key>" or none
  if _create_box_api_key "$@"; then
    printf '%s %s %s' "$_CREATE_REUSE_ACCOUNT" "$_CREATE_REUSE_PROVIDER" "$_CREATE_REUSE_KEY"
  else
    echo none
  fi
}
login() { _create_api_type_login "$@" && echo yes || echo no; }

echo '== 1. the rule =='
box "$ORTEST" "$DEMO"
eq_t "a Claude account holding an OpenRouter key is not an openclaw login" no "$(login openclaw or-test)"
auth_creds_present openclaw or-test >/dev/null 2>&1 \
  && ok_t "(why: auth_creds_present's account fallback DOES call it one — the false green this replaces)" \
  || ok_t "(auth_creds_present no longer reads a Claude account as an openclaw login)"
eq_t "nor a hermes login" no "$(login hermes or-test)"
eq_t "the lead's OpenRouter key is reused for openclaw" "or-test openrouter $OR_KEY" "$(pick openclaw)"
eq_t "and for hermes" "or-test openrouter $OR_KEY" "$(pick hermes)"
box "$DEMO"
eq_t "a box whose only AI is the demo: nothing (the demo account and its connector file are never read)" none "$(pick openclaw)"
box "$DEMO" "trends:ANTHROPIC_BASE_URL=https://openrouter.ai/api|ANTHROPIC_AUTH_TOKEN=$DEMO_KEY"
eq_t "the demo key saved under another account name: still not reused" none "$(pick openclaw)"
box "$EMERG"
eq_t "an Anthropic API key account (emergency-api) is reused as anthropic" "emergency-api anthropic $ANT_KEY" "$(pick openclaw)"
box "$OAUTH" "mp2:ANTHROPIC_API_KEY=sk-ant-oat01-fixture-oauth-in-key-slot"
eq_t "a Claude sign-in token is not an API key" none "$(pick openclaw)"
box "$EMERG" "$ORTEST"
eq_t "two keys, none preferred: the first account by name" "emergency-api anthropic $ANT_KEY" "$(pick openclaw)"
eq_t "the caller's own account is tried first" "or-test openrouter $OR_KEY" "$(pick openclaw "" or-test)"
box "$ORTEST" "zai:ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic|ANTHROPIC_AUTH_TOKEN=zai-fixture-0123456789"
eq_t "a key behind another vendor's URL is not taken for OpenRouter or Anthropic" "or-test openrouter $OR_KEY" "$(pick openclaw zai)"
# DIVE-7186: `5dive init` with an Anthropic API key saves it to the default
# Claude login (connectors/anthropic.env), in no account. That is a key the box holds.
INIT_KEY='sk-ant-api03-fixture-init-0123456789'
initkey() { printf '%s\n' "$@" > "$CONNECTORS_DIR/anthropic.env"; }
box "$DEMO"; initkey "ANTHROPIC_API_KEY=$INIT_KEY"
eq_t "the key saved at 5dive init is reused (no account)" " anthropic $INIT_KEY" "$(pick openclaw)"
eq_t "...for hermes too" " anthropic $INIT_KEY" "$(pick hermes)"
box "$ORTEST"; initkey "ANTHROPIC_API_KEY=$INIT_KEY"
eq_t "a named account still comes first" "or-test openrouter $OR_KEY" "$(pick openclaw)"
box; rm -rf "$AUTH_PROFILES_DIR"; initkey "ANTHROPIC_API_KEY=\"$INIT_KEY\""
eq_t "a box with no accounts at all: the init key, quotes stripped" " anthropic $INIT_KEY" "$(pick openclaw)"
box "$DEMO"; initkey 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fixture-signin'
eq_t "a Claude sign-in at init is not a key" none "$(pick openclaw)"
box "$DEMO"; initkey 'ANTHROPIC_API_KEY=sk-ant-oat01-fixture-oauth-in-key-slot'
eq_t "nor a sign-in token in the key slot" none "$(pick openclaw)"
box "$DEMO"; initkey 'ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic' "ANTHROPIC_API_KEY=$INIT_KEY"
eq_t "nor a key behind another vendor's URL" none "$(pick openclaw)"
box "$DEMO"; initkey "ANTHROPIC_API_KEY=$DEMO_KEY"
eq_t "nor the demo key copied into it" none "$(pick openclaw)"
box "$DEMO"
mkdir -p "$AUTH_PROFILES_DIR/theo-or/openclaw/.openclaw/agents/main/agent"
printf 'SQLite format 3\000x' > "$AUTH_PROFILES_DIR/theo-or/openclaw/.openclaw/agents/main/agent/openclaw-agent.sqlite"
eq_t "an account with its own openclaw store is an openclaw login" yes "$(login openclaw theo-or)"
mkdir -p "$AUTH_PROFILES_DIR/ada/hermes"; printf '{}\n' > "$AUTH_PROFILES_DIR/ada/hermes/auth.json"
eq_t "an empty hermes auth.json is not a hermes login" no "$(login hermes ada)"
printf '{"credential_pool":{"openrouter":[{"label":"x"}]}}\n' > "$AUTH_PROFILES_DIR/ada/hermes/auth.json"
eq_t "a filled one is" yes "$(login hermes ada)"

echo '== 2. real cmd_create, stopped before the agent user =='
require_root() { :; }
ensure_state() { :; }
registry_read() { printf '%s\n' '{"agents":{"olivia":{"type":"claude","authProfile":"or-test"}}}'; }
actor_routing_agent() { return 1; }
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
# The real write lands in the account's own <type>/ store; stand in for it so
# create's post-write auth gate sees what it would see.
apply_byo_provider() {
  printf 'APPLY type=%s provider=%s key=%s profile=%s\n' "$1" "$2" "$3" "$4" >&2
  local f
  f=$(profile_type_auth_path "$4" "$1"); mkdir -p "$(dirname "$f")"; printf 'stored\n' > "$f"
}
create_agent_user() { printf 'REACHED profile=%s defer=%s channels=%s byo=%s\n' "$profile" "$defer_auth" "$channels" "$byo_provider"; exit 0; }
made() {
  local out; out=$( ( cmd_create "$@" ) 2>&1 )
  printf '%s' "$out" > "$TMP/last.log"
  grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || { grep -m1 -oE 'needs --telegram-token[^ ]*|not authenticated|not configured|is empty' <<<"$out" || echo '(refused)'; }
}
applied() { grep -m1 '^APPLY ' "$TMP/last.log" | sed 's/^APPLY //' || true; }

box "$ORTEST" "$DEMO"
eq_t "agent create theo --type=openclaw: runs on the box's OpenRouter key, in its own account" \
  'profile=theo defer=0 channels=none byo=openrouter' "$(made theo --type=openclaw)"
eq_t "...through the --provider/--api-key path with the lead's key" \
  "type=openclaw provider=openrouter key=$OR_KEY profile=theo" "$(applied)"
grep -qF "reusing the OpenRouter key this box already holds (account 'or-test')" "$TMP/last.log" \
  && ok_t "create says which key it reused" || bad_t "create did not say which key it reused" "$(grep STEP "$TMP/last.log" | head -5)"
grep -v '^APPLY ' "$TMP/last.log" | grep -qF "$OR_KEY" \
  && bad_t "the key value was printed" "$(grep -F "$OR_KEY" "$TMP/last.log" | grep -v '^APPLY ' | head -2)" \
  || ok_t "the key value is never printed"
box "$ORTEST" "$DEMO"   # fresh box: a stubbed write above leaves a login behind
eq_t "the import argv (hire --from-market: --auth-profile=<as> --defer-auth): not deferred, key reused" \
  'profile=theo defer=0 channels=none byo=openrouter' "$(made theo --type=openclaw --auth-profile=theo --defer-auth)"
box "$ORTEST" "$DEMO"   # fresh box: a stubbed write above leaves a login behind
eq_t "a hermes hire the same way" \
  'profile=ada defer=0 channels=none byo=openrouter' "$(made ada --type=hermes --auth-profile=ada --defer-auth)"
box "$ORTEST" "$DEMO"   # fresh box: a stubbed write above leaves a login behind
eq_t "naming the lead's Claude account for openclaw (the QA's auth-profile=or-test): its key, kept in that account" \
  'profile=or-test defer=0 channels=none byo=openrouter' "$(made theo --type=openclaw --auth-profile=or-test)"
box "$ORTEST" "$DEMO"   # fresh box: a stubbed write above leaves a login behind
eq_t "an explicit --provider/--api-key wins" \
  'profile=theo defer=0 channels=none byo=anthropic' "$(made theo --type=openclaw --auth-profile=theo --provider=anthropic --api-key=sk-ant-api03-explicit-0123)"
eq_t "...with exactly the key it was given" \
  'type=openclaw provider=anthropic key=sk-ant-api03-explicit-0123 profile=theo' "$(applied)"
mkdir -p "$AUTH_PROFILES_DIR/theo-or/openclaw/.openclaw/agents/main/agent"
printf 'SQLite format 3\000x' > "$AUTH_PROFILES_DIR/theo-or/openclaw/.openclaw/agents/main/agent/openclaw-agent.sqlite"
: > "$AUTH_PROFILES_DIR/theo-or/combined.env"
eq_t "an account that already holds an openclaw login is used as given" \
  'profile=theo-or defer=0 channels=none byo=' "$(made theo --type=openclaw --auth-profile=theo-or)"
eq_t "a claude seat never takes this path" \
  'profile=or-test defer=0 channels=none byo=' "$(made marcus --type=claude --auth-profile=or-test)"
box "$DEMO"; initkey "ANTHROPIC_API_KEY=$INIT_KEY"
eq_t "DIVE-7185's box (init on an Anthropic API key, OpenClaw hired by import): the init key, in the seat's own account" \
  'profile=theo defer=0 channels=none byo=anthropic' "$(made theo --type=openclaw --auth-profile=theo --defer-auth)"
eq_t "...applied with that key" "type=openclaw provider=anthropic key=$INIT_KEY profile=theo" "$(applied)"
grep -qF "reusing the Anthropic key this box already holds (the one saved at setup)" "$TMP/last.log" \
  && ok_t "create says it reused the key saved at setup" || bad_t "create did not name the setup key" "$(grep STEP "$TMP/last.log" | head -5)"
box "$DEMO"
eq_t "a demo-only box: the hire stays deferred (sign in later), the demo key is not handed over" \
  'profile=theo defer=1 channels=none byo=' "$(made theo --type=openclaw --auth-profile=theo --defer-auth)"
[[ -z "$(applied)" ]] && ok_t "...and nothing was applied" || bad_t "a key was applied on a demo-only box" "$(applied)"

echo '== 3. --channels=telegram on a box linked to 5dive.app chat =='
box "$ORTEST"; : > "$FIVEDIVE_CHAT_ONLY_MARK"
eq_t "a claude hire with Telegram and no token: made on the app chat, not refused" \
  'profile=or-test defer=0 channels=dashboard byo=' "$(made marcus --type=claude --auth-profile=or-test --channels=telegram)"
box "$ORTEST"; : > "$FIVEDIVE_CHAT_ONLY_MARK"   # fresh: the arm above wrote nothing, but stay independent
eq_t "an openclaw hire with Telegram and no token: made, its key reused" \
  'profile=theo defer=0 channels=none byo=openrouter' "$(made theo --type=openclaw --channels=telegram)"
eq_t "telegram,dashboard keeps the chat once" \
  'profile=or-test defer=0 channels=dashboard byo=' "$(made marcus --type=claude --auth-profile=or-test --channels=telegram,dashboard)"
eq_t "a token that IS given is used (no tap needed)" \
  'profile=or-test defer=0 channels=telegram byo=' "$(made marcus --type=claude --auth-profile=or-test --channels=telegram --telegram-token=123456:ABCDEFGHIJKLMNOPQRSTUVWX)"
rm -f "$FIVEDIVE_CHAT_ONLY_MARK"
eq_t "a box not linked to 5dive.app chat still needs the token, as before" \
  'needs --telegram-token=<token>' "$(made marcus --type=claude --auth-profile=or-test --channels=telegram </dev/null)"
cs=$(declare -f cmd_create)
grep -qF 'the owner taps \"Connect Telegram\" next to $name in My team on 5dive.app' <<<"$cs" \
  && grep -qF 'if (( tg_by_tap )); then' <<<"$cs" \
  && ok_t "create's last step names the Connect Telegram tap, only when it deferred Telegram" \
  || bad_t "the Connect Telegram line is missing or unguarded" ""
grep -qF 'telegramConnect:' <<<"$cs" && ok_t "the JSON envelope carries telegramConnect" || bad_t "no telegramConnect in the envelope" ""

echo '== 4. the key lands in the seat'"'"'s own openclaw store =='
SEATS="$TMP/home"; mkdir -p "$SEATS/agent-theo"
REC="$TMP/oc-rec"; mkdir -p "$REC"
# The fake openclaw records what it was asked and with what HOME; `list` answers
# like openclaw does after a write.
cat > "$TMP/bin/oc" <<'OC'
#!/usr/bin/env bash
if [[ " $* " == *" paste-api-key "* ]]; then
  printf '%s\n' "$*" > "$OC_REC/argv"; printf '%s\n' "$HOME" > "$OC_REC/home"; cat > "$OC_REC/stdin"
  [[ "${OC_FAIL:-0}" == 1 ]] && exit 1
  printf 'listed\n' > "$OC_REC/listed"
elif [[ " $* " == *" list "* ]]; then
  [[ -f "$OC_REC/listed" && "${OC_HIDE:-0}" != 1 ]] && printf -- '- openrouter:manual [openrouter/api_key]\n'
fi
exit 0
OC
chmod +x "$TMP/bin/oc"
printf '#!/bin/sh\nexec "$@"\n' > "$TMP/bin/node"; chmod +x "$TMP/bin/node"
export OC_REC="$REC"
sudo() { # sudo -u <user> -H env K=V... cmd... — record the user, run the rest
  [[ "$1" == -u ]] || return 9
  printf '%s\n' "$2" >> "$REC/sudo-users"; shift 3; "$@"
}
seat_paste() { ( TYPE_BIN[openclaw]="$TMP/bin/oc"; OPENCLAW_SEAT_NODE="$TMP/bin/node" AGENT_HOME_ROOT="$SEATS" \
  paste_openclaw_key_into_seat "$@" ) 2>&1; }
out=$(seat_paste theo openrouter "$OR_KEY")
eq_t "the key reaches openclaw on stdin" "$OR_KEY" "$(cat "$REC/stdin" 2>/dev/null)"
grep -qF "$OR_KEY" "$REC/argv" 2>/dev/null && bad_t "the key was on argv" "$(cat "$REC/argv")" || ok_t "never on argv"
eq_t "as the seat, in the seat's own home" "agent-theo $SEATS/agent-theo" "$(head -1 "$REC/sudo-users") $(cat "$REC/home" 2>/dev/null)"
grep -qF 'models auth --agent main paste-api-key --provider openrouter --profile-id openrouter:manual' "$REC/argv" 2>/dev/null \
  && ok_t "through openclaw's own CLI (models auth paste-api-key), never a hand-written store" \
  || bad_t "unexpected openclaw call" "$(cat "$REC/argv" 2>/dev/null)"
grep -q '^WARN' <<<"$out" && bad_t "a clean write warned" "$out" || ok_t "a write openclaw lists back is quiet"
rm -f "$REC"/*; out=$(OC_HIDE=1 seat_paste theo openrouter "$OR_KEY")
grep -qF 'does not list' <<<"$out" && ok_t "a write openclaw does not list back is said" || bad_t "an unlisted write was silent" "$out"
rm -f "$REC"/*; out=$(OC_FAIL=1 seat_paste theo openrouter "$OR_KEY"); rc=$?
(( rc == 0 )) && grep -qF 'boot with no AI key' <<<"$out" \
  && ok_t "a failed write warns and never fails the create" || bad_t "a failed write" "rc=$rc $out"
rm -f "$REC"/*; out=$(seat_paste ghost openrouter "$OR_KEY")
[[ ! -e "$REC/argv" ]] && ok_t "no seat home: nothing is run" || bad_t "ran for a missing seat" "$(cat "$REC/argv")"

cl=$(grep -n 'seed_openclaw_state_into_seat "\$name" "\$profile"' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
pl=$(grep -n 'paste_openclaw_key_into_seat "\$name"' src/cmd_agent_create.sh | head -1 | cut -d: -f1)
[[ -n "$cl" && -n "$pl" ]] && (( pl > cl && pl - cl < 8 )) \
  && ok_t "create writes the key into the seat right after its seed (line $pl)" || bad_t "create does not paste the key after the seed" "seed=$cl paste=$pl"
grep -qF 'paste_openclaw_key_into_seat "$_agent" "$(resolve_native_provider openclaw "$byo_provider")" "$api_key"' src/cmd_auth.sh \
  && ok_t "agent auth set openclaw --provider writes it into every seat on that account" || bad_t "auth set does not paste into the seats" ""

echo
printf 'DIVE-7102 hires never need a secret in chat: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
