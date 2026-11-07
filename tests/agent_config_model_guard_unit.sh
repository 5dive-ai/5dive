#!/usr/bin/env bash
# DIVE-7895 — `agent config <seat> set model=<id>` no longer bricks a seat.
#
# THE BUG (box report 772): the set checked only the charset, wrote any id into
# settings.json and exited 0. A wrong id fails every turn with model_not_found,
# and restarts boot straight back into it, so only root hand-editing the file
# recovered the seat. A seat did this to itself.
#
#   A. a Claude login refuses what Anthropic can never serve, writing nothing
#      (a bound account, and an unbound seat on the box's own login)
#   B. aliases and claude-* ids pass on a Claude login; an unknown claude-* id
#      passes with a warning, so a new release still works
#   C. any other account takes any id; an unknown one warns with the undo, and
#      the replaced model is kept as .modelPrev
#   D. mutation: with the account check removed, arm A goes green-for-the-bug
#
# Every arm is pure or file-only: no root, no systemd, no network.
# Run: bash tests/agent_config_model_guard_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         cmd_agent.sh cmd_agent_runtime.sh cmd_agent_config.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d)
FLASH="deepseek/deepseek-v4.1-flash"
AUTH_PROFILES_DIR="$TMP/profiles"
AGENT_HOME_ROOT="$TMP/home"
STATE_DIR="$TMP/state"; CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$STATE_DIR" "$CONNECTORS_DIR"
mkprof() { # <name> <base-url or ""> <tier id or "">
  mkdir -p "$AUTH_PROFILES_DIR/$1"
  {
    [[ -n "$2" ]] && printf 'ANTHROPIC_BASE_URL=%s\nANTHROPIC_AUTH_TOKEN=sk-test\n' "$2"
    [[ -n "$3" ]] && printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\nANTHROPIC_DEFAULT_SONNET_MODEL=%s\nANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "$3" "$3" "$3"
    [[ -z "$2" ]] && printf 'CLAUDE_CODE_OAUTH_TOKEN=oat-test\n'
  } >"$AUTH_PROFILES_DIR/$1/combined.env"
}
mkprof openrouter https://openrouter.ai/api "$FLASH"
mkprof client-claude "" ""
mkprof bedrock "" ""; printf 'CLAUDE_CODE_USE_BEDROCK=1\n' >>"$AUTH_PROFILES_DIR/bedrock/combined.env"

printf '%s' '{"agents":{}}' >"$TMP/reg"
require_root() { :; }
registry_read() { cat "$TMP/reg"; }
registry_write() { cat >"$TMP/reg"; }
sudo() { while [[ "${1:-}" == -* || "${1:-}" == "$(id -un)" ]]; do [[ "$1" == "-u" ]] && shift; shift; done; "$@"; }
chown() { :; }
ensure_state() { :; }
audit_log() { :; }
write_agent_env() { :; }
link_agent_profile() { :; }
agent_profile_on_disk() { local p; p=$(registry_read | jq -r --arg n "$1" '.agents[$n].authProfile // empty'); printf '%s\t%s\n' "$p" "$p"; }
account_binding_record() { :; }
install_channel_for_agent() { :; }
systemd-run() { :; }
systemctl() { :; }
step() { :; }

seat() { # <name> <model> <profile or ""> [settings env json]
  mkdir -p "$TMP/home/agent-$1/.claude"
  jq -n --arg m "$2" --argjson e "${4:-null}" \
    '{model:$m, permissions:{defaultMode:"bypassPermissions"}} + (if $e == null then {} else {env:$e} end)' \
    >"$TMP/home/agent-$1/.claude/settings.json"
  jq --arg n "$1" --arg p "$3" \
    '.agents[$n] = ({type:"claude", channels:"none"} + (if $p == "" then {} else {authProfile:$p} end))' \
    "$TMP/reg" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
}
live() { jq -r '.model' "$TMP/home/agent-$1/.claude/settings.json"; }
prev() { jq -r --arg n "$1" '.agents[$n].modelPrev // ""' "$TMP/reg"; }
set_model() { ( JSON_MODE=1; cmd_config "$1" set "model=$2" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }
snap() { sha256sum "$TMP/home/agent-$1/.claude/settings.json" "$TMP/reg" | cut -d' ' -f1 | paste -sd: -; }

echo '== A. a Claude login refuses a model Anthropic cannot serve =='
seat cl claude-opus-5-5 client-claude
before=$(snap cl)
rc=$(set_model cl deepseek-xyz-invalid)
[[ "$rc" != 0 ]] && ok_t 'A1 Claude-login seat, model=deepseek-xyz-invalid: refused (RED before 7895: rc 0)' \
  || bad_t 'A1 the bad id was accepted' "rc=$rc"
eq_t 'A1 settings.json and the registry are byte-identical' "$before" "$(snap cl)"
grep -q 'is not a Claude model' "$TMP/err" && grep -q 'opus, sonnet' "$TMP/err" \
  && ok_t 'A1 the error names the families to use instead' || bad_t 'A1 error text' "$(cat "$TMP/err")"
rc=$(set_model cl not-a-real-model)
eq_t 'A2 the report'"'"'s own repro id is refused too (non-zero)' 1 "$(( rc != 0 ))"
rc=$(set_model cl "$FLASH")
eq_t 'A3 a vendor slug on a Claude login is refused' 1 "$(( rc != 0 ))"
eq_t 'A3 ...and the seat keeps its model' claude-opus-5-5 "$(live cl)"
rc=$(set_model cl foo)
eq_t 'A4 a bare word that is no alias is refused' 1 "$(( rc != 0 ))"

# teal-fox's shape: a seat bound to no account runs on the box's own Claude login.
seat tf opus ""
before=$(snap tf)
rc=$(set_model tf deepseek-xyz-invalid)
eq_t 'A5 unbound seat on the box login: refused' 1 "$(( rc != 0 ))"
eq_t 'A5 ...nothing written' "$before" "$(snap tf)"

echo '== B. what a Claude login accepts =='
for m in sonnet claude-opus-5-5 opusplan default haiku claude-opus-4-8; do
  seat okb claude-sonnet-5-5 client-claude
  rc=$(set_model okb "$m")
  [[ "$rc" == 0 && "$(live okb)" == "$m" && ! -s "$TMP/err" ]] \
    && ok_t "B model=$m accepted with no warning" || bad_t "B model=$m" "rc=$rc live=$(live okb) err=$(cat "$TMP/err")"
done
seat nb claude-sonnet-5-5 client-claude
rc=$(set_model nb claude-opus-9-9)
eq_t 'B an unknown claude-* id (a future release) is accepted' 0 "$rc"
eq_t 'B ...and written' claude-opus-9-9 "$(live nb)"
grep -q 'does not know yet' "$TMP/err" && grep -q 'Undo: 5dive agent config nb set model=claude-sonnet-5-5' "$TMP/err" \
  && ok_t 'B ...with a warning naming the undo' || bad_t 'B warning' "$(cat "$TMP/err")"

echo '== C. any other account: accepted, warned, undo recorded =='
seat or "$FLASH" openrouter
rc=$(set_model or not-a-real-model)
eq_t 'C1 OpenRouter seat, model=not-a-real-model: rc 0' 0 "$rc"
eq_t 'C1 ...written' not-a-real-model "$(live or)"
grep -q 'not a model 5dive knows' "$TMP/err" && grep -q "Undo: 5dive agent config or set model=$FLASH" "$TMP/err" \
  && ok_t 'C1 ...with a loud warning and the exact undo' || bad_t 'C1 warning' "$(cat "$TMP/err")"
eq_t 'C1 ...and the previous model is recorded as modelPrev' "$FLASH" "$(prev or)"
rc=$(set_model or "$FLASH")
eq_t 'C2 the undo works' "$FLASH" "$(live or)"
[[ ! -s "$TMP/err" ]] && ok_t 'C2 the account'"'"'s own mapped id raises no warning' || bad_t 'C2 warned' "$(cat "$TMP/err")"
eq_t 'C2 modelPrev now holds the id it replaced' not-a-real-model "$(prev or)"
seat br us.anthropic.claude-sonnet-4-5-v1:0 bedrock
rc=$(set_model br us.anthropic.claude-opus-4-1-v1:0)
eq_t 'C3 a Bedrock account takes its own ids' 0 "$rc"
seat ur opus "" '{"ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic"}'
rc=$(set_model ur deepseek-chat)
eq_t 'C4 an unbound seat whose settings.json routes elsewhere is not a Claude login' 0 "$rc"
printf 'ANTHROPIC_BASE_URL=https://openrouter.ai/api\n' >"$CONNECTORS_DIR/anthropic.env"
seat uc opus ""
rc=$(set_model uc z-ai/glm-4.6)
eq_t 'C5 an unbound seat on a box whose connector points elsewhere: accepted' 0 "$rc"
rm -f "$CONNECTORS_DIR/anthropic.env"
seat mv claude-opus-5-5 client-claude
( JSON_MODE=1; cmd_config mv set auth-profile=openrouter model=z-ai/glm-4.6 ) >"$TMP/out" 2>"$TMP/err"
eq_t 'C6 auth-profile= in the same call is the account checked' z-ai/glm-4.6 "$(live mv)"

echo '== D. mutation: without the account check, A1 is accepted again =='
eval "_orig_login() $(declare -f claude_seat_on_anthropic_login | tail -n +2)"
claude_seat_on_anthropic_login() { return 1; }
seat mu claude-opus-5-5 client-claude
rc=$(set_model mu deepseek-xyz-invalid)
eq_t 'D the check removed: the bad id lands (so arm A bites)' "0 deepseek-xyz-invalid" "$rc $(live mu)"
eval "claude_seat_on_anthropic_login() $(declare -f _orig_login | tail -n +2)"
seat mu claude-opus-5-5 client-claude
rc=$(set_model mu deepseek-xyz-invalid)
eq_t 'D restored: refused again' 1 "$(( rc != 0 ))"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
