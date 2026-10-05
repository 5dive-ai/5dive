#!/usr/bin/env bash
# DIVE-5259 — `account set-model`: move an alias-mapping account to another model
# without its key, and move the agents that follow it.
#
# WHY THE AGENTS ARE THE POINT: create/import write the account's mapped id into
# each agent's settings.json (DIVE-5163), so a switch that rewrites only the
# account's ANTHROPIC_DEFAULT_* map moves no agent at all. The included-model
# switch in 5dive-api runs this verb on every box of an org.
#
# Arms: (1) refusals, (2) the account map (opus+sonnet move, haiku stays),
# (3) which bound agents are re-pinned and which are left, (4) restart only when
# idle, busy deferred, nothing restarted on a no-op re-run, (5) switching back,
# (6) negative controls: the same arms go red with the re-pin line or the idle
# check deleted from the function.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/state.sh lib/registry.sh lib/audit.sh cmd_auth.sh cmd_agent.sh cmd_account.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d)
FLASH="deepseek/deepseek-v4.1-flash"
PROMO="openrouter/space-bunny-alpha"
AUTH_PROFILES_DIR="$TMP/profiles"
AGENT_HOME_ROOT="$TMP/home"

require_root() { :; }
chown() { :; }
step() { :; }
warn() { :; }
registry_read() { cat "$TMP/reg"; }
# The box's own busy ledger is not here: the stub answers from a fixture file,
# one "<agent> <idle|busy|parked>" per line.
_restart_decide() {
  case "$(awk -v n="$1" '$1 == n {print $2}' "$TMP/busy")" in
    busy)   printf 'deferred busy\n' ;;
    parked) printf 'held parked\n' ;;
    *)      printf 'restart idle\n' ;;
  esac
}
# Records the agent name out of the unit name 5dive-agent@<name>.service.
systemctl() { local u="${2#*@}"; printf '%s\n' "${u%.service}" >>"$TMP/restarts"; }

mkprof() { # <name> <base-url or ""> <opus> <sonnet> <haiku>
  mkdir -p "$AUTH_PROFILES_DIR/$1"
  {
    [[ -n "$2" ]] && printf 'ANTHROPIC_BASE_URL=%s\nANTHROPIC_AUTH_TOKEN=sk-or-test\n' "$2"
    [[ -n "$3" ]] && printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "$3"
    [[ -n "$4" ]] && printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "$4"
    [[ -n "$5" ]] && printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "$5"
    [[ -z "$2" ]] && printf 'CLAUDE_CODE_OAUTH_TOKEN=oat-test\n'
  } >"$AUTH_PROFILES_DIR/$1/combined.env"
}
seat() { # <name> <model or ""> <profile> [family] [type]
  mkdir -p "$TMP/home/agent-$1/.claude"
  if [[ -n "$2" ]]; then jq -n --arg m "$2" '{model:$m, theme:"dark"}'; else jq -n '{theme:"dark"}'; fi \
    >"$TMP/home/agent-$1/.claude/settings.json"
  jq --arg n "$1" --arg p "$3" --arg f "${4:-}" --arg t "${5:-claude}" \
    '.agents[$n] = ({type:$t, authProfile:$p} + (if $f == "" then {} else {modelFamily:$f} end))' \
    "$TMP/reg" >"$TMP/reg.n" && mv "$TMP/reg.n" "$TMP/reg"
}
live() { jq -r '.model // ""' "$TMP/home/agent-$1/.claude/settings.json"; }
envv() { profile_env_value "$1" "$2"; }
run() { # <args...> -> rc; envelope in $TMP/out
  : >"$TMP/restarts"
  ( JSON_MODE=1; cmd_account_set_model "$@" ) >"$TMP/out" 2>"$TMP/err"; echo $?
}
restarted() { sort "$TMP/restarts" | tr '\n' ' ' | sed 's/ $//'; }
agent_row() { tail -1 "$TMP/out" | jq -c --arg n "$1" '.data.agents[] | select(.name == $n) | {repinned, restart}'; }

fixture() {
  rm -rf "$AUTH_PROFILES_DIR" "$TMP/home"; printf '%s' '{"agents":{}}' >"$TMP/reg"; : >"$TMP/busy"
  # The seeded account exactly as _apply_byo_claude writes it for openrouter.
  mkprof openrouter https://openrouter.ai/api "$FLASH" "$FLASH" "$FLASH"
  mkprof client-claude "" "" "" ""
  seat maya "$FLASH" openrouter sonnet                     # a partner pack import: follows
  seat old "$(model_latest sonnet)" openrouter              # pre-5163 import, no family: follows
  seat sys "$FLASH" openrouter                              # created with --provider, no family: follows
  seat pin z-ai/glm-4.6 openrouter                          # deliberate pin: left
  seat bare sonnet openrouter sonnet                        # bare alias: the map carries it
  seat hk "$FLASH" openrouter haiku                         # haiku family: its tier does not move
  seat busy "$FLASH" openrouter opus                        # follows, but mid-turn
  seat own "$(model_latest opus)" client-claude opus        # another account: untouched
  seat hermes "" openrouter "" hermes                       # not claude: skipped
  printf 'busy busy\n' >"$TMP/busy"
}

echo '== 1. refusals =='
fixture
eq_t 'no --model is a usage error' "$E_USAGE" "$(run openrouter)"
eq_t 'a family alias is refused' "$E_VALIDATION" "$(run openrouter --model=sonnet)"
eq_t 'a slug with a space is refused' "$E_VALIDATION" "$(run openrouter '--model=a b')"
eq_t 'an unknown account is not found' "$E_NOT_FOUND" "$(run nosuch --model=$PROMO)"
eq_t 'an Anthropic account (no base url) is refused' "$E_VALIDATION" "$(run client-claude --model=$PROMO)"
eq_t '... and its file is untouched' "" "$(envv client-claude ANTHROPIC_DEFAULT_OPUS_MODEL)"
eq_t 'a refusal re-pins nothing' "$FLASH" "$(live maya)"

echo '== 2. the account map =='
fixture
eq_t 'switch rc' 0 "$(run openrouter --model=$PROMO)"
eq_t 'opus tier moves' "$PROMO" "$(envv openrouter ANTHROPIC_DEFAULT_OPUS_MODEL)"
eq_t 'sonnet tier moves' "$PROMO" "$(envv openrouter ANTHROPIC_DEFAULT_SONNET_MODEL)"
eq_t 'haiku (background) tier stays' "$FLASH" "$(envv openrouter ANTHROPIC_DEFAULT_HAIKU_MODEL)"
eq_t 'the key is kept' sk-or-test "$(envv openrouter ANTHROPIC_AUTH_TOKEN)"
eq_t 'the base url is kept' https://openrouter.ai/api "$(envv openrouter ANTHROPIC_BASE_URL)"
eq_t 'one assignment per variable' 1 "$(grep -c '^ANTHROPIC_DEFAULT_OPUS_MODEL=' "$AUTH_PROFILES_DIR/openrouter/combined.env")"
eq_t 'the envelope reports the change and the previous tiers' "true $FLASH $FLASH" \
  "$(tail -1 "$TMP/out" | jq -r '[.data.changed, .data.previous.opus, .data.previous.sonnet] | map(tostring) | join(" ")')"

echo '== 3. which agents move =='
eq_t 'a sonnet-family import on the mapped id moves' "$PROMO" "$(live maya)"
eq_t 'a pre-5163 import on the claude-* id moves' "$PROMO" "$(live old)"
eq_t 'a family-less seat on the old mapping moves' "$PROMO" "$(live sys)"
eq_t 'a deliberate vendor pin is left' z-ai/glm-4.6 "$(live pin)"
eq_t 'a bare alias is left for the map' sonnet "$(live bare)"
eq_t 'a haiku-family seat stays with its (unmoved) tier' "$FLASH" "$(live hk)"
eq_t 'a busy seat is re-pinned too (only its restart waits)' "$PROMO" "$(live busy)"
eq_t 'an agent on another account is untouched' "$(model_latest opus)" "$(live own)"
eq_t 'settings.json keeps its other keys' dark "$(jq -r .theme "$TMP/home/agent-maya/.claude/settings.json")"
eq_t 'the recorded family is kept for the next account move' sonnet "$(jq -r '.agents.maya.modelFamily' "$TMP/reg")"
eq_t 'the non-claude agent is not in the report' "" "$(agent_row hermes)"

echo '== 4. restarts =='
eq_t 'every idle claude agent on the account restarts once; busy and other-account ones do not' \
  "bare hk maya old pin sys" "$(restarted)"
eq_t 'the busy seat is deferred' '{"repinned":true,"restart":"deferred"}' "$(agent_row busy)"
eq_t 'an idle re-pinned seat restarted now' '{"repinned":true,"restart":"now"}' "$(agent_row maya)"
eq_t 'a re-run on the same model: rc' 0 "$(run openrouter --model=$PROMO)"
eq_t '... changes nothing' false "$(tail -1 "$TMP/out" | jq -r .data.changed)"
eq_t '... and restarts nobody' "" "$(restarted)"

echo '== 5. switching back =='
eq_t 'back to the paid model: rc' 0 "$(run openrouter --model=$FLASH)"
eq_t 'opus tier is back' "$FLASH" "$(envv openrouter ANTHROPIC_DEFAULT_OPUS_MODEL)"
eq_t 'the import follows back' "$FLASH" "$(live maya)"
eq_t 'the pre-5163 seat follows back (now on the mapping)' "$FLASH" "$(live old)"
eq_t 'the deliberate pin is still left' z-ai/glm-4.6 "$(live pin)"
fixture; printf 'busy parked\n' >"$TMP/busy"
run openrouter --model=$PROMO >/dev/null
eq_t 'a parked seat is held, not restarted' '{"repinned":true,"restart":"held"}' "$(agent_row busy)"

echo '== 6. negative controls: the arms above see the load-bearing lines =='
fn=$(declare -f cmd_account_set_model)
grep -q 'write_runtime_model claude "\$agent" "\$want"' <<<"$fn" \
  && ok_t 'the re-pin line is present to delete' || bad_t 're-pin line not found; control is void' ''
grep -q '_restart_decide "\$agent"' <<<"$fn" \
  && ok_t 'the idle check is present to delete' || bad_t 'idle check not found; control is void' ''
eval "$(sed 's/write_runtime_model claude "\$agent" "\$want"/:/' <<<"$fn")"
fixture; run openrouter --model=$PROMO >/dev/null
[[ "$(live maya)" == "$FLASH" ]] \
  && ok_t 'CONTROL: with the re-pin deleted, the import stays on the old model (arm 3 would go red)' \
  || bad_t 'CONTROL: re-pin deletion did not change the outcome' "$(live maya)"
eval "$(sed 's/case "\$(_restart_decide "\$agent" "account \$name moved to \$model")" in/case "restart idle" in/' <<<"$fn")"
fixture; run openrouter --model=$PROMO >/dev/null
[[ " $(restarted) " == *" busy "* ]] \
  && ok_t 'CONTROL: with the idle check deleted, the busy seat is restarted mid-turn (arm 4 would go red)' \
  || bad_t 'CONTROL: idle-check deletion did not change the outcome' "$(restarted)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
