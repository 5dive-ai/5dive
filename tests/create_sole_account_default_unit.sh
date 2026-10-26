#!/usr/bin/env bash
# DIVE-7028 — on a self-hosted box with ONE Claude login, every new seat came up
# signed out: `agent import --auth-profile=mp` was deferred anyway ("auth was
# deferred (agent is UNAUTHED)"), `hire --from-market` minted an empty profile
# named after the hire, and `team import --auth-profile=konst` left every seat
# unauthed. Graded on box fixtures through the REAL credential check
# (cmd_auth.sh auth_creds_present):
#   1. the rule (_create_sole_account): which box has "one login";
#   2. the real cmd_create, stopped where the agent user would be made, per verb
#      (agent create / plain hire, team import's create argv, the import argv);
#   3. the real cmd_import seam up to the cmd_create argv (hire --from-market
#      and team import's pack seats both run it);
#   4. on a box linked to 5dive.app chat, a seat named no channel gets the chat.
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
# The shared login lives in the fixture, never in the host's /etc/5dive.
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
MP='mp:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-mp'
KONST='konst:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-konst'
DEMO='demo-ai:ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo'

# box <profile:line>... — each arg is one account and one line of its
# combined.env (an empty line = the empty per-agent profile an import mints).
box() {
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$FIVEDIVE_CHAT_ONLY_MARK"
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  local a
  for a in "$@"; do
    mkdir -p "$AUTH_PROFILES_DIR/${a%%:*}"
    printf '%s\n' "${a#*:}" > "$AUTH_PROFILES_DIR/${a%%:*}/combined.env"
  done
}
rule() { _create_sole_account "$1" || echo none; }

echo '== 1. the rule =='
box "$MP"
eq_t "lodar's self-host box (one login, mp): a claude seat uses it" mp "$(rule claude)"
eq_t 'a codex seat never takes a claude login' none "$(rule codex)"
box "$MP" 'olivia:'
eq_t "an earlier hire's EMPTY per-agent profile is not a second login" mp "$(rule claude)"
box "$MP" "$DEMO"
eq_t 'the demo AI is not a login (DIVE-6843)' mp "$(rule claude)"
box "$MP" 'trends:ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixturedemo' "$DEMO"
eq_t 'nor the demo key saved under another name' mp "$(rule claude)"
box "$DEMO"
eq_t 'a demo-only box has no login of its own' none "$(rule claude)"
box "$MP" "$KONST"
eq_t 'two logins: nothing is picked' none "$(rule claude)"
box "$MP"
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-shared\n' > "$CONNECTORS_DIR/anthropic.env"
eq_t 'the shared login is there: seats keep using it, as before' none "$(rule claude)"
box 'mp:# CLAUDE_CODE_OAUTH_TOKEN=commented-out'
eq_t 'a commented-out token is not a login' none "$(rule claude)"

echo '== 2. real cmd_create, stopped before the agent user =='
require_root() { :; }
ensure_state() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
actor_routing_agent() { return 1; }
step() { printf 'STEP: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
create_agent_user() { printf 'REACHED profile=%s defer=%s channels=%s\n' "$profile" "$defer_auth" "$channels"; exit 0; }
# made <args>... — what create was about to build, or the refusal it gave.
made() {
  local out; out=$( ( cmd_create "$@" ) 2>&1 )
  [[ -n "${DBG:-}" ]] && printf "%s\n" "$out" >&2
  printf '%s' "$out" > "$TMP/last.log"
  grep -m1 '^REACHED ' <<<"$out" | sed 's/^REACHED //' || true
  grep -q '^REACHED ' <<<"$out" || grep -m1 -oE 'not authenticated|not configured|is empty' <<<"$out" || echo '(refused)'
}

box "$MP"
eq_t 'agent create / hire marcus, no account named: signed in on mp' \
  'profile=mp defer=0 channels=none' "$(made marcus --type=claude)"
grep -qF "one signed-in AI account 'mp'" "$TMP/last.log" \
  && ok_t 'create says which account it used' || bad_t 'create did not name the account' "$(cat "$TMP/last.log")"
eq_t "main's import (--auth-profile=mp, which import always defers): used, not deferred" \
  'profile=mp defer=0 channels=dashboard' "$(made olivia --type=claude --channels=dashboard --auth-profile=mp --defer-auth)"
grep -q 'deferred' "$TMP/last.log" \
  && bad_t 'a deferral was still reported' "$(cat "$TMP/last.log")" || ok_t 'no "deferred" anywhere in its output'
eq_t 'a team template (defer_auth, no account) on a one-login box: signed in on mp' \
  'profile=mp defer=0 channels=none' "$(made scout --type=claude --defer-auth)"
eq_t "the dashboard's set-up-later (an EMPTY named profile) still defers" \
  'profile=marcus defer=1 channels=none' "$(made marcus --type=claude --auth-profile=marcus --defer-auth)"

box "$MP" "$KONST"
eq_t 'two logins, account named (cqa5, --auth-profile=konst): honoured, not deferred' \
  'profile=konst defer=0 channels=none' "$(made dev --type=claude --auth-profile=konst --defer-auth)"
eq_t 'two logins, no account, deferred: still asks (stays deferred, no account picked)' \
  'profile= defer=1 channels=none' "$(made dev --type=claude --defer-auth)"
eq_t 'two logins, no account, not deferred: still refused' \
  'not authenticated' "$(made dev --type=claude)"

box "$MP"
mapfile -t TARGS < <(_compose_create_args '{"type":"claude","channels":"none","defer_auth":true,"auth_profile":"mp"}' marcus "$TMP")
eq_t 'team import seat (create argv from the template, defer_auth + mp): signed in' \
  'profile=mp defer=0 channels=none' "$(made "${TARGS[@]}")"

echo '== 3. real cmd_import seam (hire --from-market, team import pack seats) =='
printf '%s\n' '{"packFormat":1,"agentName":"marcus","config":{"type":"claude"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/marcus.tar.gz"
export DIVE7028_FIXTURE="$TMP/manifest.json"
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE7028_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
imported() { # <label> <args>... — the account and channel argv cmd_import built
  local rec="$TMP/$1.argv"; shift
  rm -f "$rec"
  ( cmd_create() { printf '%s\n' "$@" > "$rec"; return 1; }; cmd_import "$TMP/marcus.tar.gz" "$@" ) >/dev/null 2>&1
  [[ -f "$rec" ]] || { echo "(cmd_create not reached)"; return; }
  printf '%s %s' "$(grep -m1 '^--auth-profile=' "$rec")" "$(grep -m1 '^--channels=' "$rec" || echo '(no channels)')"
}

box "$MP"
eq_t "Olivia's \"hire marcus\" (import --as=marcus, no account): binds mp, not a new empty profile" \
  '--auth-profile=mp (no channels)' "$(imported olivia --as=marcus)"
eq_t 'an explicit account is never overridden' \
  '--auth-profile=konst (no channels)' "$(imported explicit --as=marcus --auth-profile=konst)"
eq_t 'a BYO key keeps the per-agent profile' \
  '--auth-profile=marcus (no channels)' "$(imported byo --as=marcus --provider=openrouter --api-key=sk-or-v1-x)"
box "$MP" "$KONST"
eq_t 'two logins: the per-agent profile (sign in later) stays' \
  '--auth-profile=marcus (no channels)' "$(imported two --as=marcus)"
grep -q -- '--defer-auth' "$TMP/two.argv" \
  && ok_t 'and that import still defers' || bad_t 'two-login import lost --defer-auth' "$(cat "$TMP/two.argv")"
grep -qE 'cmd_import "\$slug" --as="\$name"' src/cmd_hire.sh \
  && ok_t 'hire --from-market runs cmd_import' || bad_t 'hire --from-market no longer goes through cmd_import' ''

echo '== 4. a box linked to 5dive.app chat =='
box "$MP"; : > "$FIVEDIVE_CHAT_ONLY_MARK"
eq_t 'a new claude seat with no --channels gets the chat' \
  'profile=mp defer=0 channels=dashboard' "$(made marcus --type=claude)"
eq_t 'an explicit --channels=none is kept' \
  'profile=mp defer=0 channels=none' "$(made marcus --type=claude --channels=none)"
rm -f "$FIVEDIVE_CHAT_ONLY_MARK"
eq_t 'an unlinked box: no channel, as before' \
  'profile=mp defer=0 channels=none' "$(made marcus --type=claude)"

echo
printf 'DIVE-7028 one-login box signs new seats in: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
