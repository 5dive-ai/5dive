#!/usr/bin/env bash
# DIVE-5163 — a family alias resolves against the ACCOUNT the agent is bound to.
#
# THE BUG: every partner pack carries config.model "sonnet". The import path
# resolved it with resolve_model_alias -> claude-sonnet-5 whatever the account,
# and Claude Code sends a full id past the account's ANTHROPIC_DEFAULT_* map. On
# a partner box bound to the seeded OpenRouter account (every tier mapped to
# deepseek/deepseek-v4.1-flash) OpenRouter billed real Claude Sonnet 5 at API
# price: maya burned 91% of a $6/week budget in ~8 chats.
#
# Arms: (1) the resolver per account shape, (2) the REAL cmd_import on a seeded
# OpenRouter binding and on an Anthropic one, (3) the REAL cmd_config
# auth-profile switch both ways plus the same-account heal and a deliberate pin.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         cmd_agent.sh cmd_agent_runtime.sh cmd_agent_config.sh cmd_pack.sh; do
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
mkprof() { # <name> <base-url or ""> <opus> <sonnet> <haiku>
  mkdir -p "$AUTH_PROFILES_DIR/$1"
  {
    [[ -n "$2" ]] && printf 'ANTHROPIC_BASE_URL=%s\nANTHROPIC_AUTH_TOKEN=sk-test\n' "$2"
    [[ -n "$3" ]] && printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "$3"
    [[ -n "$4" ]] && printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "$4"
    [[ -n "$5" ]] && printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "$5"
    [[ -z "$2" ]] && printf 'CLAUDE_CODE_OAUTH_TOKEN=oat-test\n'
  } >"$AUTH_PROFILES_DIR/$1/combined.env"
}
# The seeded partner account, exactly as _apply_byo_claude writes it for openrouter.
mkprof openrouter https://openrouter.ai/api "$FLASH" "$FLASH" "$FLASH"
# A client's own Claude subscription (DIVE-5118): no base url.
mkprof client-claude "" "" "" ""
# A client's own DeepSeek: a direct vendor with a per-tier map.
mkprof client-deepseek https://api.deepseek.com/anthropic deepseek-v4-pro deepseek-chat deepseek-chat
# A leftover map with no base url is still an Anthropic account.
mkprof stale-map "" "$FLASH" "$FLASH" "$FLASH"
# A map whose entry is itself an alias (the --provider --model=sonnet shape).
mkprof alias-map https://openrouter.ai/api sonnet sonnet sonnet

echo '== 1. resolver per account shape =='
eq_t 'sonnet on the seeded OpenRouter account -> the account mapping' "$FLASH" "$(resolve_model_for_profile sonnet openrouter)"
eq_t 'opus on the seeded OpenRouter account -> the account mapping'   "$FLASH" "$(resolve_model_for_profile opus openrouter)"
eq_t 'sonnet on a client Claude account -> the current claude id (DIVE-506)' "$(model_latest sonnet)" "$(resolve_model_for_profile sonnet client-claude)"
eq_t 'sonnet with no account -> the current claude id' "$(model_latest sonnet)" "$(resolve_model_for_profile sonnet '')"
eq_t 'sonnet on a direct DeepSeek account -> its sonnet tier' deepseek-chat "$(resolve_model_for_profile sonnet client-deepseek)"
eq_t 'a map with no base url is ignored' "$(model_latest sonnet)" "$(resolve_model_for_profile sonnet stale-map)"
eq_t 'a map entry that is itself an alias is ignored (never written bare)' "$(model_latest sonnet)" "$(resolve_model_for_profile sonnet alias-map)"
eq_t 'fable has no tier variable, so it resolves as before' "$(model_latest fable)" "$(resolve_model_for_profile fable openrouter)"
eq_t 'a full vendor id passes through' z-ai/glm-4.6 "$(resolve_model_for_profile z-ai/glm-4.6 openrouter)"
eq_t 'a pinned claude id passes through' claude-opus-4-8 "$(resolve_model_for_profile claude-opus-4-8 openrouter)"
eq_t 'model_family_of reads the current id' sonnet "$(model_family_of "$(model_latest sonnet)")"
eq_t 'model_family_of reads a bare alias' haiku "$(model_family_of haiku)"
eq_t 'model_family_of is empty for a vendor slug' "" "$(model_family_of "$FLASH")"

echo '== 2. real cmd_import: what reaches the settings write, and the recorded family =='
# The settings merge lives in /home/agent-<as>, out of reach here; the model the
# import carries into it is the same $model _pack_unapplied_on is handed, so
# that seam records it. cmd_create succeeds without side effects.
printf '%s\n' '{"packFormat":1,"agentName":"maya","config":{"type":"claude","model":"sonnet"},"includes":{"memory":false}}' >"$TMP/manifest.json"
: >"$TMP/fixture.tar.gz"
printf '%s' '{"agents":{}}' >"$TMP/reg"
require_root() { :; }
registry_read() { cat "$TMP/reg"; }
registry_write() { cat >"$TMP/reg"; }
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$TMP/manifest.json" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
_pack_unapplied_on() { printf '%s' "$2" >"$TMP/model.seen"; }
is_known_type() { [[ "$1" == claude ]]; }
step() { :; }
warn() { :; }
cmd_create() {
  local a; for a in "$@"; do [[ "$a" == --model=* ]] && printf '%s' "${a#--model=}" >"$TMP/create.model"; done
  jq --arg n "$1" '.agents[$n] = {type:"claude"}' <<<"$(cat "$TMP/reg")" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
  return 0
}
import_as() { # <as> <profile>
  rm -f "$TMP/model.seen" "$TMP/create.model"
  ( cmd_import "$TMP/fixture.tar.gz" --as="$1" --auth-profile="$2" ) >/dev/null 2>"$TMP/import.err"
  cat "$TMP/model.seen" 2>/dev/null
}
eq_t 'seeded OpenRouter binding: pack sonnet lands as the account mapping (RED on main: claude-sonnet-5)' \
  "$FLASH" "$(import_as maya openrouter)"
eq_t 'the imported agent remembers the family it asked for' sonnet \
  "$(jq -r '.agents.maya.modelFamily // ""' "$TMP/reg")"
[[ ! -e "$TMP/create.model" ]] \
  && ok_t 'a non-BYO import still passes no --model to create' \
  || bad_t 'a non-BYO import forwarded --model to create' "$(cat "$TMP/create.model")"
eq_t 'client Claude binding: pack sonnet lands as the current claude id' \
  "$(model_latest sonnet)" "$(import_as rex client-claude)"
printf '%s\n' '{"packFormat":1,"agentName":"pin","config":{"type":"claude","model":"z-ai/glm-4.6"},"includes":{"memory":false}}' >"$TMP/manifest.json"
eq_t 'a pack that pins a vendor id keeps it on OpenRouter' z-ai/glm-4.6 "$(import_as pin openrouter)"
eq_t 'a pinned pack records no family' "" "$(jq -r '.agents.pin.modelFamily // ""' "$TMP/reg")"
# DIVE-7786: a CUSTOM pack carries the slug its source account resolved.
printf '%s\n' '{"packFormat":1,"agentName":"mira","config":{"type":"claude","model":"'"$FLASH"'"},"includes":{"memory":false}}' >"$TMP/manifest.json"
eq_t 'custom pack slug onto the account that maps sonnet to it: kept' "$FLASH" "$(import_as mira openrouter)"
eq_t '... and its family is recorded, so a later account move can follow it' sonnet \
  "$(jq -r '.agents.mira.modelFamily // ""' "$TMP/reg")"
eq_t 'custom pack slug onto a Claude login: lands as Sonnet, not a dead id' \
  "$(model_latest sonnet)" "$(import_as mira2 client-claude)"
eq_t '... with the family recorded' sonnet "$(jq -r '.agents.mira2.modelFamily // ""' "$TMP/reg")"

echo '== 3. real cmd_config: the account switch re-derives the model =='
# cmd_pack.sh redefines nothing cmd_config needs, but the import stubs above
# must not leak: re-source the config path's own dependencies.
source "$SRC/cmd_agent.sh"; source "$SRC/cmd_agent_config.sh"
AGENT_HOME_ROOT="$TMP/home"
STATE_DIR="$TMP/state"; CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$STATE_DIR" "$CONNECTORS_DIR"
sudo() { while [[ "${1:-}" == -* || "${1:-}" == "$(id -un)" ]]; do [[ "$1" == "-u" ]] && shift; shift; done; "$@"; }
chown() { :; }
ensure_state() { :; }
audit_log() { :; }
write_agent_env() { :; }
link_agent_profile() { :; }
# DIVE-7747: the env and link writers above are no-ops, so the move's read-back
# is told they landed on the registry's account (this harness grades the model).
agent_profile_on_disk() { local p; p=$(registry_read | jq -r --arg n "$1" '.agents[$n].authProfile // empty'); printf '%s\t%s\n' "$p" "$p"; }
account_binding_record() { :; }
install_channel_for_agent() { :; }
systemd-run() { printf 'restart\n' >>"$TMP/restarts"; }
systemctl() { :; }
seat() { # <name> <model> <profile> [family]
  mkdir -p "$TMP/home/agent-$1/.claude"
  jq -n --arg m "$2" '{model:$m, permissions:{defaultMode:"bypassPermissions"}}' >"$TMP/home/agent-$1/.claude/settings.json"
  jq --arg n "$1" --arg p "$3" --arg f "${4:-}" \
    '.agents[$n] = ({type:"claude", channels:"none", authProfile:$p} + (if $f == "" then {} else {modelFamily:$f} end))' \
    "$TMP/reg" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
}
live() { jq -r '.model' "$TMP/home/agent-$1/.claude/settings.json"; }
set_acct() { ( JSON_MODE=1; cmd_config "$1" set "auth-profile=$2" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }

seat maya "$FLASH" openrouter sonnet
rc=$(set_acct maya client-claude)
eq_t 'connecting own Claude: rc' 0 "$rc"
eq_t 'connecting own Claude gives real Sonnet' "$(model_latest sonnet)" "$(live maya)"
rc=$(set_acct maya openrouter)
eq_t 'going back to the seeded account gives DeepSeek again' "$FLASH" "$(live maya)"
rc=$(set_acct maya client-deepseek)
eq_t 'a client DeepSeek account gives its own sonnet tier' deepseek-chat "$(live maya)"

# A pre-fix import: claude-sonnet-5 on the seeded account, no recorded family.
seat old "$(model_latest sonnet)" openrouter
rc=$(set_acct old openrouter)
eq_t 'the same-account re-set heals a pre-fix partner seat (the one-off)' "$FLASH" "$(live old)"

# A deliberate pin survives a switch onto an account that can run it.
seat pinned z-ai/glm-4.6 openrouter sonnet
set_acct pinned client-deepseek >/dev/null
eq_t 'a deliberate vendor pin is not overwritten by a switch' z-ai/glm-4.6 "$(live pinned)"
# DIVE-7786: ...but a Claude login can never run it, so there it becomes Sonnet.
step() { printf '%s\n' "$*" >&2; }
set_acct pinned client-claude >/dev/null
step() { :; }
eq_t 'a vendor pin moved onto a Claude login becomes Sonnet (RED before 7786)' "$(model_latest sonnet)" "$(live pinned)"
grep -q "is not a Claude model" "$TMP/err" \
  && ok_t '... and the step says why' || bad_t 'the floor printed no step' "$(cat "$TMP/err")"

# A bare alias already follows the account on its own: left alone.
seat bare sonnet openrouter
set_acct bare client-claude >/dev/null
eq_t 'a bare alias is left for Claude Code to map' sonnet "$(live bare)"

# 5dive's own boxes: Anthropic -> Anthropic changes nothing.
seat own "$(model_latest opus)" client-claude
before=$(sha256sum <"$TMP/home/agent-own/.claude/settings.json")
set_acct own default >/dev/null
[[ "$(sha256sum <"$TMP/home/agent-own/.claude/settings.json")" == "$before" ]] \
  && ok_t 'an Anthropic-to-Anthropic switch leaves settings.json byte-identical' \
  || bad_t 'an Anthropic-to-Anthropic switch touched settings.json' "$(live own)"

# An explicit model= in the same call wins over the re-derive.
seat both "$FLASH" openrouter sonnet
( JSON_MODE=1; cmd_config both set auth-profile=client-claude model=haiku ) >/dev/null 2>&1
eq_t 'an explicit model= in the same call wins' haiku "$(live both)"
eq_t '... and becomes the remembered family' haiku "$(jq -r '.agents.both.modelFamily // ""' "$TMP/reg")"
( JSON_MODE=1; cmd_config both set model=z-ai/glm-4.6 ) >/dev/null 2>&1
eq_t 'setting a pinned id forgets the family' "" "$(jq -r '.agents.both.modelFamily // ""' "$TMP/reg")"

echo '== 3b. DIVE-7786: a seat with no recorded family on the seeded slug =='
# alert-vale's mira: a custom pack on the seeded account, modelFamily null, and a
# registry `model` stamped with the same slug.
seat mira "$FLASH" openrouter
jq --arg m "$FLASH" '.agents.mira.model = $m' "$TMP/reg" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
rc=$(set_acct mira client-claude)
eq_t 'connecting own Claude: rc' 0 "$rc"
eq_t 'the slug is read back through the old account map: real Sonnet (RED before 7786)' "$(model_latest sonnet)" "$(live mira)"
eq_t '... the family is recorded' sonnet "$(jq -r '.agents.mira.modelFamily // ""' "$TMP/reg")"
eq_t '... and the registry model matches settings.json (RED before 7786)' "$(live mira)" "$(jq -r '.agents.mira.model // ""' "$TMP/reg")"
set_acct mira openrouter >/dev/null
eq_t 'moved back onto the seeded account: its mapped id again' "$FLASH" "$(live mira)"
eq_t '... registry model follows' "$FLASH" "$(jq -r '.agents.mira.model // ""' "$TMP/reg")"
# A seat with no registry model never grows one.
seat nomodel "$FLASH" openrouter
set_acct nomodel client-claude >/dev/null
eq_t 'a seat with no registry model gets none' false "$(jq -r '.agents.nomodel | has("model")' "$TMP/reg")"
# The speed verb (`config set model=sonnet effort=high`) also syncs the registry.
seat speedy "$FLASH" client-claude
jq --arg m "$FLASH" '.agents.speedy.model = $m' "$TMP/reg" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
( JSON_MODE=1; cmd_config speedy set model=sonnet effort=high ) >/dev/null 2>&1
eq_t 'speed verb: settings.json reads sonnet' sonnet "$(live speedy)"
eq_t 'speed verb: the registry model matches (RED before 7786)' sonnet "$(jq -r '.agents.speedy.model // ""' "$TMP/reg")"
# Deliberate Claude pins stay.
seat opuspin claude-opus-5-5 openrouter
set_acct opuspin client-claude >/dev/null
eq_t 'a seat pinned to claude-opus-5-5 stays on it' claude-opus-5-5 "$(live opuspin)"
seat oldpin claude-opus-4-1-20250805 client-deepseek
set_acct oldpin client-claude >/dev/null
eq_t 'an older claude id somebody chose stays on a Claude login' claude-opus-4-1-20250805 "$(live oldpin)"
seat aliaspin 'opus[1m]' openrouter
set_acct aliaspin client-claude >/dev/null
eq_t 'a bare alias with a suffix stays' 'opus[1m]' "$(live aliaspin)"
# An unknown account is never assumed to be a Claude login.
seat ghost "$FLASH" openrouter
set_acct ghost no-such-account >/dev/null
eq_t 'a move to an account with no folder leaves the slug' "$FLASH" "$(live ghost)"
# A Bedrock account takes its own ids.
mkprof bedrock "" "" "" ""; printf 'CLAUDE_CODE_USE_BEDROCK=1\n' >>"$AUTH_PROFILES_DIR/bedrock/combined.env"
seat br us.anthropic.claude-sonnet-4-5-v1:0 client-claude
set_acct br bedrock >/dev/null
eq_t 'a Bedrock account is not floored' us.anthropic.claude-sonnet-4-5-v1:0 "$(live br)"
eq_t 'a stale map with no base url is still a Claude login' 0 "$(profile_is_anthropic_login stale-map; echo $?)"

echo '== 4. create path wiring =='

csrc=$(<"$SRC/cmd_agent_create.sh")
[[ "$csrc" == *'_claude_create_model=$(resolve_model_for_profile "$_claude_create_model" "$profile")'* ]] \
  && ok_t 'agent create resolves a family alias against its bound account' \
  || bad_t 'agent create no longer resolves the alias per account' ''
[[ "$csrc" == *'modelFamily: $mf'* ]] \
  && ok_t 'agent create records the family' || bad_t 'agent create does not record the family' ''

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
