#!/usr/bin/env bash
# DIVE-8481 — a Gemini (antigravity) login can be the login new agents use.
# A partner box (2026-11-14): the client signed in to Gemini and tapped
# "use for new employees"; the box ran `account default client-gemini:antigravity`
# and refused it (the type list was claude codex grok), and the 5dive app's
# `account default <acct>` found "no claude codex grok login". Graded on a
# scratch AUTH_PROFILES_DIR through the REAL credential readers:
#   1. `account default <acct>:antigravity` pins it;
#   2. `account default <acct>` (no type) pins it;
#   3. hires with that default: a pack that lands on antigravity, a pack that
#      does not, agent create, team import — a Gemini seat or the old rule,
#      never an error;
#   4. an upgrade changes no hire: a Gemini login the box already had is `seen`;
#      one added after the upgrade is `added`.
# Mutant: revert ACCOUNT_DEFAULT_TYPES to (claude codex grok) — arms 1-3 go red.
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
TYPE_AUTH[antigravity]="$CONNECTORS_DIR/antigravity-oauth-token"
mkdir -p "$TMP/bin"
for _t in claude codex antigravity; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"
  TYPE_BIN[$_t]="$TMP/bin/$_t"
done
cmd_install() { printf 'INSTALL-ATTEMPTED %s\n' "$*"; return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
LEDGER="$AUTH_PROFILES_DIR/.logins"
require_root() { :; }
ensure_state() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }

fresh_box() { rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"; mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"; }
claude_login() { mkdir -p "$AUTH_PROFILES_DIR/$1"; printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-%s\n' "$1" > "$AUTH_PROFILES_DIR/$1/combined.env"; }
# Where `agent auth start antigravity --auth-profile=<acct>` lands the token
# (profile_type_auth_path: HOME redirect under <acct>/antigravity).
gemini_login() {
  local d="$AUTH_PROFILES_DIR/$1/antigravity/.gemini/antigravity-cli"
  mkdir -p "$d"; [[ -f "$AUTH_PROFILES_DIR/$1/combined.env" ]] || : > "$AUTH_PROFILES_DIR/$1/combined.env"
  printf '{"access_token":"fixture-%s"}\n' "$1" > "$d/antigravity-oauth-token"
}
age() { awk -v a="$1" -v t="$2" -v d="$3" 'BEGIN{FS=OFS="\t"} $2==a && $3==t {$1-=d} 1' "$LEDGER" > "$LEDGER.x" && mv "$LEDGER.x" "$LEDGER"; }
pick() { if account_default_v "${1:-}"; then printf '%s:%s' "$ACCOUNT_DEFAULT_ACCOUNT" "$ACCOUNT_DEFAULT_TYPE"; else echo none; fi; }
line() { awk -v a="$1" -v t="$2" 'BEGIN{FS="\t"} $2==a && $3==t {print $1" "$4}' "$LEDGER"; }
cli() { ( "$@" ) 2>&1; printf '\nRC=%s' "$?"; }

fresh_box; gemini_login client-gemini
account_types_authed_arr client-gemini
eq_t 'fixture: the real reader sees the Gemini login as antigravity' antigravity "${ACCOUNT_TYPES_AUTHED[*]}"

echo '== 1. account default <acct>:antigravity (what the partner app sends) =='
# The partner box: the shared demo AI only, then the client's Gemini.
fresh_box; claude_login demo-ai; pick >/dev/null; gemini_login client-gemini
JSON_MODE=1
_o=$(cli cmd_account_default client-gemini:antigravity)
eq_t 'exits 0' 'RC=0' "${_o##*$'\n'}"
eq_t '...and answers it, pinned' 'client-gemini antigravity true' \
  "$(jq -r '.data | "\(.account) \(.type) \(.pinned)"' <<<"${_o%$'\n'RC=*}" 2>/dev/null)"
_o=$(cli cmd_account_default)
eq_t 'account default --json then names it, pinned' 'client-gemini antigravity true' \
  "$(jq -r '.data | "\(.account) \(.type) \(.pinned)"' <<<"${_o%$'\n'RC=*}" 2>/dev/null)"
_l=$( ( cmd_account_list ) 2>/dev/null)
eq_t 'account list --json marks that row default=antigravity, pinned' 'client-gemini=antigravity:true' \
  "$(jq -r '.data[] | select(.default) | "\(.name)=\(.default):\(.pinned)"' <<<"$_l")"

echo '== 2. account default <acct> with no type (what the 5dive app sends) =='
fresh_box; claude_login demo-ai; pick >/dev/null; gemini_login client-gemini
_o=$(cli cmd_account_default client-gemini)
eq_t 'exits 0 on an account holding only Gemini' 'RC=0' "${_o##*$'\n'}"
eq_t '...and pins its Gemini login' 'client-gemini antigravity true' \
  "$(jq -r '.data | "\(.account) \(.type) \(.pinned)"' <<<"${_o%$'\n'RC=*}" 2>/dev/null)"
claude_login both; gemini_login both
_o=$(cli cmd_account_default both)
eq_t 'an account holding Claude AND Gemini: Claude first, Gemini last in the no-type order' 'both claude' \
  "$(jq -r '.data | "\(.account) \(.type)"' <<<"${_o%$'\n'RC=*}" 2>/dev/null)"
_o=$(cli cmd_account_default --undo=client-gemini:antigravity)
eq_t 'Undo of a Gemini login is accepted too' 'RC=0' "${_o##*$'\n'}"
JSON_MODE=0
_o=$(cli cmd_account_default client-gemini:bogus)
grep -q 'type: claude codex grok antigravity' <<<"$_o" && ok_t 'the usage line lists antigravity' || bad_t 'usage line' "$_o"

echo '== 3. hires with a Gemini default =='
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
actor_routing_agent() { return 1; }
printf '%s\n' '{"packFormat":1,"agentName":"marcus","config":{"type":"claude","model":"opus","effort":"high"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/marcus.tar.gz"
export DIVE8481_FIXTURE="$TMP/manifest.json"
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE8481_FIXTURE" "$2/manifest.json"; }
LANDS="antigravity claude codex"
_pack_harness_targets() { printf '%s\n' $LANDS; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
imported() { # <label> <args>... — the harness, account, model and effort cmd_import built, or its error
  local rec="$TMP/$1.argv" out; shift
  rm -f "$rec"
  out=$( ( cmd_create() { printf '%s\n' "$@" "model=${model:-}" "effort=${effort:-}" > "$rec"; return 1; }
    cmd_import "$TMP/marcus.tar.gz" "$@" ) 2>&1)
  [[ -f "$rec" ]] || { echo "(cmd_create not reached) $(grep -m1 -iE 'error|fail' <<<"$out")"; return; }
  printf '%s %s %s %s' "$(grep -m1 '^--type=' "$rec")" "$(grep -m1 '^--auth-profile=' "$rec")" \
    "$(grep -m1 '^model=' "$rec")" "$(grep -m1 '^effort=' "$rec")"
}
fresh_box; claude_login mp; pick >/dev/null; gemini_login client-gemini
JSON_MODE=1; ( cmd_account_default client-gemini:antigravity ) >/dev/null 2>&1; JSON_MODE=0
eq_t 'a one-tap pack hire that lands on Gemini runs on the Gemini login; Claude pins dropped' \
  '--type=antigravity --auth-profile=client-gemini model= effort=' "$(imported gem --as=marcus)"
LANDS="claude codex"
eq_t 'a pack that cannot land on Gemini skips it and keeps its own rule (the one Claude login), no error' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported nogem --as=marcus)"
LANDS="antigravity claude codex"
eq_t 'an explicit --type=claude is never moved onto Gemini' \
  '--type=claude --auth-profile=mp model=opus effort=high' "$(imported typed --as=marcus --type=claude)"
create_agent_user() { printf 'REACHED type=%s profile=%s\n' "$type" "$profile"; exit 0; }
made() { local out; out=$( ( cmd_create "$@" ) 2>&1 ); grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || printf '(refused) %s' "$(tail -n1 <<<"$out")"; }
eq_t 'agent create --type=antigravity with no account: the Gemini default' \
  'type=antigravity profile=client-gemini' "$(made gemma --type=antigravity)"
eq_t 'agent create --type=claude with no account: not the Gemini login' \
  'type=claude profile=mp' "$(made dev --type=claude)"
SPEC='{"agents":{"lead":{"type":"claude","model":"opus"}}}'
eq_t 'team import: a plain Claude seat is left on its own rule (it never moves onto Gemini)' \
  "$(jq -c . <<<"$SPEC")" "$(_compose_apply_newest_login "$SPEC" | jq -c .)"
claude_login konst; age client-gemini antigravity 100
JSON_MODE=1; ( cmd_account_default --clear ) >/dev/null 2>&1; JSON_MODE=0
gemini_login gem2
eq_t 'Gemini added after a second Claude: it is the newest login' gem2:antigravity "$(pick)"
eq_t '...team import still moves its plain seat to the Claude added before it, as before DIVE-8481' \
  '{"type":"claude","model":"opus","auth_profile":"konst"}' "$(_compose_apply_newest_login "$SPEC" | jq -c .agents.lead)"
LANDS="claude codex"
eq_t '...and a pack that cannot land on Gemini goes to that Claude too' \
  '--type=claude --auth-profile=konst model=opus effort=high' "$(imported nogem2 --as=marcus)"
LANDS="antigravity claude codex"

echo '== 4. an upgrade changes no hire =='
# A ledger written by a CLI that counted only claude codex grok: Claude seen.
fresh_box; claude_login mp; gemini_login client-gemini
printf '1700000000\tmp\tclaude\tseen\n' > "$LEDGER"
eq_t 'a Gemini login the box already had is not a new default after the upgrade' none "$(pick)"
eq_t '...it is written down as seen' seen "$(line client-gemini antigravity | cut -d' ' -f2)"
grep -qP '^\d+\t\*\tantigravity\ttracked$' "$LEDGER" && ok_t '...and the ledger records that it counts Gemini now' \
  || bad_t 'no tracked line' "$(cat "$LEDGER")"
gemini_login gem-new
eq_t 'a Gemini login added after the upgrade is the default' gem-new:antigravity "$(pick)"
eq_t '...stamped added' added "$(line gem-new antigravity | cut -d' ' -f2)"
_before=$(grep -c tracked "$LEDGER")
pick >/dev/null; pick >/dev/null
eq_t 'the tracked line is written once, not per read' "$_before" "$(grep -c tracked "$LEDGER")"
# An older CLI reading the new ledger skips the tracked line (state not seen|added|undone).
_old=$(while IFS=$'\t' read -r ts acct t state; do case "$state" in seen|added|undone) echo "$acct";; esac; done <"$LEDGER" | sort | tr '\n' ' ')
eq_t "an older CLI's parse keeps only the login lines" 'client-gemini gem-new mp ' "$_old"
fresh_box; gemini_login client-gemini
eq_t 'a fresh box (no ledger): its Gemini login is seen, like every other' none "$(pick)"
gemini_login gem-new
eq_t '...and the next Gemini login added is the default' gem-new:antigravity "$(pick)"

echo
printf 'DIVE-8481 Gemini as the login new agents use: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
