#!/usr/bin/env bash
# DIVE-6788 — a seat we pinned to a model follows each Claude release.
#
# Every hire asking for "sonnet" or "haiku" was pinned at birth to the id
# model_latest held that day, and the catalogue missed the 5.5 releases for a
# week: a partner's seats were still on claude-sonnet-5. Two halves are graded here:
#   1. the create path lands on the current id with the effort it asked for
#      (the REAL preseed_claude_agent, stubbed at its writes);
#   2. `agent _float_models` (run by every self-update) moves a booted seat on a
#      current or previous default id to the bare family alias, keeps the level
#      it ran at, and leaves alone what it must: a never-booted config dir, an
#      alias-mapping account (DIVE-5163), an id somebody chose, a seat whose
#      recorded family says otherwise, a non-claude seat.
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT=$PWD
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { [[ "$2" == "$3" ]] && ok "$1" || no "$1 (got '$2', want '$3')"; }

# shellcheck disable=SC1091
source "$ROOT/src/header.sh"; set +eu
E_GENERIC="${E_GENERIC:-1}"
# shellcheck disable=SC1091
source "$ROOT/src/lib/validation.sh"
# shellcheck disable=SC1091
source "$ROOT/src/lib/models.sh"
# shellcheck disable=SC1091
source "$ROOT/src/lib/agent_setup.sh"
SONNET=$(model_latest sonnet); HAIKU=$(model_latest haiku)

echo "== 1. create: 'sonnet' lands on the current id with the asked effort =="
is "catalogue sonnet is 5.5"  "$SONNET" "claude-sonnet-5-5"
is "catalogue haiku is 5.5"   "$HAIKU"  "claude-haiku-5-5"
want=$(resolve_model_for_profile sonnet "")
is "Anthropic account resolves sonnet to the current id" "$want" "$SONNET"
agent="float-ci-${BASHPID}"
cap="$TMP/create.json"
fail() { [[ "$*" == *"agent home missing: /home/agent-${agent}"* ]] && return 0; printf 'unexpected fail(): %s\n' "$*" >&2; return 1; }
sudo() { if [[ "$*" == *"tee /home/agent-${agent}/.claude/settings.json"* ]]; then cat >"$cap"; elif [[ "$*" == *'tee '* ]]; then cat >/dev/null; fi; return 0; }
chmod() { :; }; step() { :; }; install_default_skill_for_agent() { :; }
preseed_claude_agent "$agent" none "$want" xhigh
is "settings.json model"      "$(jq -r .model "$cap")" "$SONNET"
is "per-model effort for it"  "$(jq -r --arg s "$SONNET" '.modelSettings[$s].effortLevel' "$cap")" "xhigh"
unset -f sudo chmod fail

echo "== 2. agent _float_models =="
fail() { printf 'FAIL(%s) %s\n' "$1" "$2" >&2; exit "${1:-1}"; }
E_USAGE=2
sed -n '/^cmd_agent_float_models()/,/^}/p' "$ROOT/src/cmd_agent.sh" >"$TMP/fn.sh"
is "function extracted" "$(grep -c '^cmd_agent_float_models()' "$TMP/fn.sh")" "1"
# shellcheck disable=SC1091
source "$TMP/fn.sh"
require_root() { :; }; warn() { :; }
msg=""; ok() { msg="$*"; }
export AGENT_HOME_ROOT="$TMP/home" AUTH_PROFILES_DIR="$TMP/profiles"
mkdir -p "$AUTH_PROFILES_DIR/or-acct" "$AUTH_PROFILES_DIR/claude-acct"
printf 'ANTHROPIC_BASE_URL=https://openrouter.ai/api\nANTHROPIC_DEFAULT_SONNET_MODEL=deepseek/deepseek-v4.1-flash\n' >"$AUTH_PROFILES_DIR/or-acct/combined.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=x\n' >"$AUTH_PROFILES_DIR/claude-acct/combined.env"
seat() {  # seat <name> <booted 0|1> <settings json>
  mkdir -p "$AGENT_HOME_ROOT/agent-$1/.claude"
  if [[ "$2" == 1 ]]; then echo '{"migrationVersion":14}' >"$AGENT_HOME_ROOT/agent-$1/.claude.json"
  else echo '{"hasCompletedOnboarding":true}' >"$AGENT_HOME_ROOT/agent-$1/.claude.json"; fi
  printf '%s\n' "$3" >"$AGENT_HOME_ROOT/agent-$1/.claude/settings.json"
  cp "$AGENT_HOME_ROOT/agent-$1/.claude/settings.json" "$TMP/$1.before"
}
S() { cat "$AGENT_HOME_ROOT/agent-$1/.claude/settings.json"; }
same() { cmp -s "$TMP/$1.before" "$AGENT_HOME_ROOT/agent-$1/.claude/settings.json" && echo same || echo changed; }
seat pinned   1 '{"model":"claude-sonnet-5","effortLevel":"high","x":1}'
seat acct    1 '{"model":"claude-sonnet-5","effortLevel":"high"}'
seat orseat  1 '{"model":"claude-sonnet-5","effortLevel":"high"}'
seat fresh   0 "{\"model\":\"$SONNET\",\"effortLevel\":\"high\"}"
seat chosen  1 '{"model":"claude-sonnet-4-5","effortLevel":"high"}'
seat haiku   1 "{\"model\":\"claude-haiku-4-5-20251001\",\"effortLevel\":\"high\",\"modelSettings\":{\"claude-haiku-4-5-20251001\":{\"effortLevel\":\"low\"},\"$HAIKU\":{\"effortLevel\":\"high\"}}}"
seat newhire 1 "{\"model\":\"$SONNET\",\"effortLevel\":\"high\",\"modelSettings\":{\"$SONNET\":{\"effortLevel\":\"xhigh\"}}}"
seat famdiff 1 '{"model":"claude-sonnet-5","effortLevel":"high"}'
seat floats  1 '{"model":"sonnet","effortLevel":"high"}'
seat codex   1 '{"model":"claude-sonnet-5"}'
registry_read() { jq -n '{agents:{
  pinned:{type:"claude"}, acct:{type:"claude",authProfile:"claude-acct",modelFamily:"sonnet"},
  orseat:{type:"claude",authProfile:"or-acct"}, fresh:{type:"claude"}, chosen:{type:"claude"},
  haiku:{type:"claude"}, newhire:{type:"claude",modelFamily:"sonnet"},
  famdiff:{type:"claude",modelFamily:"opus"}, floats:{type:"claude"}, codex:{type:"codex"}}}'; }
cmd_agent_float_models; rc=$?
first=$msg
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
is "exits 0"                         "$rc" "0"
is "count reported"                  "$first" "moved 4 agent(s) onto their model family alias"
is "sonnet-5 seat floats"            "$(S pinned | jq -r .model)" "sonnet"
is "...at the level it ran at (id key)"    "$(S pinned | jq -r --arg s "$SONNET" '.modelSettings[$s].effortLevel')" "high"
is "...and under the alias key"      "$(S pinned | jq -r '.modelSettings.sonnet.effortLevel')" "high"
is "...top-level and other keys kept" "$(S pinned | jq -c '[.effortLevel, .x]')" '["high",1]'
is "...and what Claude Code reads is high" "$(S pinned | jq -r --argjson a "$(models_json)" "$MODEL_EFFORT_JQ"'effective_effort($a)')" "high"
is "Anthropic profile seat floats"   "$(S acct | jq -r .model)" "sonnet"
is "OpenRouter-mapped seat untouched" "$(same orseat)" "same"
is "never-booted config dir untouched" "$(same fresh)" "same"
is "a chosen id untouched"           "$(same chosen)" "same"
is "haiku-4.5 seat floats"           "$(S haiku | jq -r .model)" "haiku"
is "...keeping the level it RAN at, not the healed key's" "$(S haiku | jq -r --arg h "$HAIKU" '.modelSettings[$h].effortLevel')" "low"
is "new hire on the current id floats" "$(S newhire | jq -r .model)" "sonnet"
is "...its /effort choice carried to the alias key" "$(S newhire | jq -r '.modelSettings.sonnet.effortLevel')" "xhigh"
is "recorded family disagrees: untouched" "$(same famdiff)" "same"
is "already on the alias: untouched" "$(same floats)" "same"
is "codex seat untouched"            "$(same codex)" "same"
is "mode 600 kept"                   "$(stat -c %a "$AGENT_HOME_ROOT/agent-pinned/.claude/settings.json")" "600"
for n in pinned haiku; do cp "$AGENT_HOME_ROOT/agent-$n/.claude/settings.json" "$TMP/$n.before"; done
ok() { msg="$*"; }
cmd_agent_float_models
second=$msg
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
is "second pass moves nothing"       "$second" "moved 0 agent(s) onto their model family alias"
is "second pass does not rewrite"    "$(same pinned)/$(same haiku)" "same/same"

echo "== 3. wiring =="
grep -q '_float_models)' "$ROOT/src/main.sh" && grep -q 'cmd_agent_float_models "\$@"' "$ROOT/src/main.sh" \
  && ok "agent _float_models dispatches" || no "agent _float_models not dispatched in main.sh"
grep -q '"\$BIN_DIR/5dive" agent _float_models' "$ROOT/install.sh" \
  && ok "installer runs the move on every update" || no "installer does not run the move"
grep -q "grep -q 'cmd_agent_float_models' \"\$BIN_DIR/5dive\"" "$ROOT/install.sh" \
  && ok "installer skips a bundle that predates the verb" || no "installer would warn on every older bundle"
h=$(grep -n 'agent _heal_effort >/dev/null' "$ROOT/install.sh" | cut -d: -f1)
f=$(grep -n 'agent _float_models >/dev/null' "$ROOT/install.sh" | cut -d: -f1)
[[ -n "$h" && -n "$f" && "$f" -gt "$h" ]] && ok "the move runs after the effort heal" || no "the move must run after the effort heal (h=$h f=$f)"

echo "-----"
echo "model_float_unit: $pass passed, $fail failed"
(( fail == 0 ))
