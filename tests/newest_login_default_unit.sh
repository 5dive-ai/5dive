#!/usr/bin/env bash
# DIVE-7152 — the login the owner added LAST is the default for every new hire
# (lodar 2026-10-28: "all new hires go to the most recent auth"). Add ChatGPT
# next to Claude and the next agent hired runs on ChatGPT; Undo puts it back;
# remove it and hires go back to Claude, never to an empty login. Graded on box
# fixtures through the REAL credential readers (account_types_authed_arr):
#   1. the rule (account_default_v) and its ledger: seeding, add, Undo, a
#      signed-out login, a token refresh, a removed account, a read-only caller;
#   2. `account default` and `account list --json`, what the app reads;
#   3. the real cmd_create, stopped where the agent user would be made;
#   4. the real cmd_import seam up to the cmd_create argv (hire, marketplace,
#      the app's one-tap hire, a partner hire);
#   5. team import's plain seats (_compose_apply_newest_login).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }; echo "HARNESS-RC=$rc"' EXIT
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
source src/cmd_account.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
# shellcheck disable=SC1091
source src/cmd_pack.sh
# shellcheck disable=SC1091
source src/cmd_compose.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
TYPE_AUTH[codex]="$CONNECTORS_DIR/codex-auth.json"
mkdir -p "$TMP/bin"
for _t in claude codex; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"
  TYPE_BIN[$_t]="$TMP/bin/$_t"
done
cmd_install() { printf 'INSTALL-ATTEMPTED %s\n' "$*"; return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
LEDGER="$AUTH_PROFILES_DIR/.logins"

fresh_box() { rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"; mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"; }
claude_login() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-%s\n' "$1" > "$AUTH_PROFILES_DIR/$1/combined.env"; }
chatgpt_login() {
  mkdir -p "$AUTH_PROFILES_DIR/$1/codex"; : > "$AUTH_PROFILES_DIR/$1/combined.env"
  printf '{"tokens":{"access_token":"fixture"}}\n' > "$AUTH_PROFILES_DIR/$1/codex/auth.json"
}
# age <account> <type> <seconds> — move a ledger line back in time, so the next
# login added sorts after it (the ledger stamps to the second).
age() { awk -v a="$1" -v t="$2" -v d="$3" 'BEGIN{FS=OFS="\t"} $2==a && $3==t {$1-=d} 1' "$LEDGER" > "$LEDGER.x" && mv "$LEDGER.x" "$LEDGER"; }
pick() { if account_default_v "${1:-}"; then printf '%s:%s' "$ACCOUNT_DEFAULT_ACCOUNT" "$ACCOUNT_DEFAULT_TYPE"; else echo none; fi; }
line() { awk -v a="$1" -v t="$2" 'BEGIN{FS="\t"} $2==a && $3==t {print $1" "$4}' "$LEDGER"; }

echo '== 1. the rule =='
fresh_box; claude_login mp
eq_t 'a box that already had Claude before this shipped: no default, hires keep their rules' none "$(pick)"
eq_t '...and its login is written down as one it already had' seen "$(line mp claude | cut -d' ' -f2)"
chatgpt_login gpt; age mp claude 100
eq_t 'the owner adds ChatGPT: new hires go to it' gpt:codex "$(pick)"
eq_t '...a claude hire still finds no newer claude login' none "$(pick claude)"
claude_login konst; age gpt codex 50
eq_t 'a second Claude added for headroom: the same rule, it is the default' konst:claude "$(pick)"
eq_t '...and a codex hire still goes to ChatGPT' gpt:codex "$(pick codex)"
claude_login demo-ai
eq_t 'the demo AI turning up later never becomes the default' konst:claude "$(pick)"
eq_t '...and is not even written down' '' "$(line demo-ai claude)"
mv "$AUTH_PROFILES_DIR/konst/combined.env" "$TMP/konst.env"; mkdir -p "$AUTH_PROFILES_DIR/konst"
printf '# signed out\n' > "$AUTH_PROFILES_DIR/konst/combined.env"
eq_t 'the newest login signs out: the next newest that works, never the empty one' gpt:codex "$(pick)"
_konst_ts=$(line konst claude)
mv "$TMP/konst.env" "$AUTH_PROFILES_DIR/konst/combined.env"
eq_t 'its file back (a token refresh, a re-sign-in): the default again' konst:claude "$(pick)"
eq_t '...on its OLD stamp, so a refresh never re-adds a login' "$_konst_ts" "$(line konst claude)"
rm -rf "$AUTH_PROFILES_DIR/konst"
eq_t 'the newest account removed: back to ChatGPT' gpt:codex "$(pick)"
eq_t '...and its line is gone, so the same name added again counts as new' '' "$(line konst claude)"
rm -rf "$AUTH_PROFILES_DIR/gpt"
eq_t 'ChatGPT removed too: no default, hires land on Claude by their own rules' none "$(pick)"
chatgpt_login gpt
eq_t 'ChatGPT added again under the same name: it is new again' gpt:codex "$(pick)"
_before=$(cat "$LEDGER")
chmod a-w "$AUTH_PROFILES_DIR"; chatgpt_login gpt2 2>/dev/null
if [[ ! -d "$AUTH_PROFILES_DIR/gpt2" ]]; then
  chmod u+w "$AUTH_PROFILES_DIR"; chatgpt_login gpt2; chmod a-w "$AUTH_PROFILES_DIR"
fi
_ro=$(pick)
chmod u+w "$AUTH_PROFILES_DIR"
[[ -w "$TMP" ]] && [[ "$(id -u)" != 0 ]] && {
  eq_t 'a caller that cannot write the ledger gets the same answer' gpt2:codex "$_ro"
  eq_t '...and writes nothing' "$_before" "$(cat "$LEDGER")"
}
rm -rf "$AUTH_PROFILES_DIR/gpt2"
fresh_box
eq_t 'a brand-new box with no AI yet: nothing to pick' none "$(pick)"
claude_login mp
eq_t "its owner's first login is added, so it is the default" mp:claude "$(pick)"

echo '== 2. what the app reads: account default, account list =='
require_root() { :; }
ensure_state() { :; }
registry_read() { printf '%s\n' '{"agents":{"old":{"type":"claude","authProfile":"mp"}}}'; }
fresh_box; claude_login mp; pick >/dev/null; chatgpt_login gpt; age mp claude 100
JSON_MODE=1
_d=$( ( cmd_account_default ) 2>/dev/null)
eq_t 'account default --json names the login and its harness' 'gpt codex' "$(jq -r '.data | "\(.account) \(.type)"' <<<"$_d")"
_l=$( ( cmd_account_list ) 2>/dev/null)
eq_t "account list --json marks that row, and only it" 'gpt=codex' "$(jq -r '.data[] | select(.default) | "\(.name)=\(.default)"' <<<"$_l")"
eq_t '...and the agent already on Claude stays listed on mp' 'old' "$(jq -r '.data[] | select(.name=="mp") | .agents | join(",")' <<<"$_l")"
_d=$( ( cmd_account_default --undo=gpt:codex ) 2>/dev/null)
eq_t 'Undo: no login is the default, hires go back to Claude' null "$(jq -c '.data' <<<"$_d")"
eq_t '...ChatGPT stays signed in and on the list' 'undone' "$(line gpt codex | cut -d' ' -f2)"
_d=$( ( cmd_account_default --undo=gpt:codex ) 2>/dev/null)
eq_t 'a second tap on Undo is a no-op' null "$(jq -c '.data' <<<"$_d")"
_d=$( ( cmd_account_default --undo=nobody:codex ) 2>&1)
grep -q 'holds no codex login' <<<"$_d" && ok_t 'Undo of a login the box does not hold is refused' || bad_t 'Undo of a missing login' "$_d"
_d=$( ( cmd_account_default --undo=gpt ) 2>&1)
grep -q 'usage: 5dive account default --undo' <<<"$_d" && ok_t 'Undo with no type is refused with its usage' || bad_t 'Undo with no type' "$_d"
chatgpt_login gpt3
_d=$( ( cmd_account_default ) 2>/dev/null)
eq_t 'a login added after an Undo is the default again' 'gpt3' "$(jq -r '.data.account' <<<"$_d")"
JSON_MODE=0

echo '== 3. real cmd_create, stopped before the agent user =='
actor_routing_agent() { return 1; }
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
create_agent_user() { printf 'REACHED type=%s profile=%s defer=%s\n' "$type" "$profile" "$defer_auth"; exit 0; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
made() {
  local out; out=$( ( cmd_create "$@" ) 2>&1 )
  printf '%s' "$out" > "$TMP/last.log"
  grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || grep -m1 -oE 'not authenticated|not configured|is empty' <<<"$out" || echo '(refused)'
}
fresh_box; claude_login mp; pick >/dev/null; claude_login konst; chatgpt_login gpt; age konst claude 100
eq_t 'agent create --type=codex, no account: the ChatGPT login' 'type=codex profile=gpt defer=0' "$(made pixel --type=codex)"
grep -qF "the codex login added last" "$TMP/last.log" && ok_t 'create says which login it used' || bad_t 'create did not say' "$(cat "$TMP/last.log")"
eq_t 'agent create --type=claude on two Claude logins: the one added last (refused before)' \
  'type=claude profile=konst defer=0' "$(made dev --type=claude)"
eq_t 'an explicit --auth-profile still wins' 'type=claude profile=mp defer=0' "$(made dev --type=claude --auth-profile=mp)"
eq_t 'a deferred hire with no account (a team template) gets it too' 'type=claude profile=konst defer=0' "$(made dev --type=claude --defer-auth)"

echo '== 4. real cmd_import seam (hire, marketplace, one-tap, partner) =='
printf '%s\n' '{"packFormat":1,"agentName":"marcus","config":{"type":"claude","model":"opus","effort":"high"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/marcus.tar.gz"
export DIVE7152_FIXTURE="$TMP/manifest.json"
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE7152_FIXTURE" "$2/manifest.json"; }
LANDS="claude codex"
_pack_harness_targets() { printf '%s\n' $LANDS; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
# The model and effort are cmd_import's own locals (it writes them to the seat
# after create), read through bash's dynamic scope from the stub.
imported() { # <label> <args>... — the harness, account, model and effort cmd_import built
  local rec="$TMP/$1.argv"; shift
  rm -f "$rec"
  ( cmd_create() { printf '%s\n' "$@" "model=${model:-}" "effort=${effort:-}" > "$rec"; return 1; }
    cmd_import "$TMP/marcus.tar.gz" "$@" ) >/dev/null 2>&1
  [[ -f "$rec" ]] || { echo "(cmd_create not reached)"; return; }
  printf '%s %s %s %s' "$(grep -m1 '^--type=' "$rec")" "$(grep -m1 '^--auth-profile=' "$rec")" \
    "$(grep -m1 '^model=' "$rec")" "$(grep -m1 '^effort=' "$rec")"
}
fresh_box; claude_login mp; pick >/dev/null; chatgpt_login gpt; age mp claude 100
eq_t 'a Claude pack hired after ChatGPT was added runs on ChatGPT; its Claude pins are dropped' \
  '--type=codex --auth-profile=gpt model= effort=' "$(imported one-tap --as=marcus)"
eq_t 'an explicit --type=claude keeps Claude (the old rule binds the one Claude login)' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported typed --as=marcus --type=claude)"
eq_t 'an explicit account is never overridden (a pick on the hire screen)' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported picked --as=marcus --auth-profile=mp)"
LANDS="claude"
eq_t 'a pack that lands only on Claude stays on Claude' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported claude-only --as=marcus)"
LANDS="claude codex"
JSON_MODE=1; ( cmd_account_default --undo=gpt:codex ) >/dev/null 2>&1; JSON_MODE=0
eq_t 'after Undo the next hire lands on Claude' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported undone --as=marcus)"
rm -rf "$AUTH_PROFILES_DIR/gpt"; chatgpt_login gpt
rm -rf "$AUTH_PROFILES_DIR/gpt"
eq_t 'ChatGPT removed: the hire lands on Claude, not on the removed login' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported removed --as=marcus)"

echo '== 5. team import: plain seats =='
fresh_box; claude_login mp; pick >/dev/null; chatgpt_login gpt; age mp claude 100
SPEC='{"agents":{"lead":{"type":"claude","model":"opus","effort":"high"},"own":{"type":"claude","auth_profile":"mp"},"packed":{"pack":"olivia"},"pixel":{"type":"claude","prefer_type":"codex"},"oc":{"type":"openclaw"}}}'
_s=$(_compose_apply_newest_login "$SPEC")
eq_t 'a plain Claude seat moves to ChatGPT with the login, its pins dropped' \
  '{"type":"codex","auth_profile":"gpt"}' "$(jq -c '.agents.lead' <<<"$_s")"
eq_t 'a seat that names its account keeps it' '{"type":"claude","auth_profile":"mp"}' "$(jq -c '.agents.own' <<<"$_s")"
eq_t 'a pack seat is left to the import (it knows where its pack lands)' '{"pack":"olivia"}' "$(jq -c '.agents.packed' <<<"$_s")"
eq_t "a seat's prefer_type is left to prefer_type" '{"type":"claude","prefer_type":"codex"}' "$(jq -c '.agents.pixel' <<<"$_s")"
eq_t 'a harness that cannot run on the login is left alone' '{"type":"openclaw"}' "$(jq -c '.agents.oc' <<<"$_s")"
rm -rf "$AUTH_PROFILES_DIR/gpt"
eq_t 'with no login added, the spec is unchanged' "$(jq -c . <<<"$SPEC")" "$(_compose_apply_newest_login "$SPEC" | jq -c .)"
grep -q '_compose_apply_newest_login "\$spec"' src/cmd_compose.sh \
  && ok_t 'team import runs it' || bad_t 'team import does not run _compose_apply_newest_login' ''

echo
printf 'DIVE-7152 new hires go to the login added last: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
