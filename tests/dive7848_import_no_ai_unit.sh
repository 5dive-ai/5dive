#!/usr/bin/env bash
# DIVE-7848 — on a fresh self-hosted box with no AI, `sudo 5dive agent import
# marcus --as=marcus` finished with exit 0 and an agent that could not think,
# and adding the AI afterwards did not heal it: the seat was bound to an EMPTY
# per-agent account `marcus`, while `5dive init`'s AI step saves into the
# SHARED login and the DIVE-620 self-heal restarts only seats on the account
# being signed in. Graded on box fixtures through the REAL credential check
# (cmd_auth.sh auth_creds_present) and the REAL init AI step:
#   1. import at a terminal on a box with no AI runs init's AI step; a key
#      saved there is the seat's login (no deferral, no per-agent account);
#   2. import off a terminal, or "Later", marks the seat as waiting for an AI;
#      a box that already has AI is never asked and never marked;
#   3. the first AI added afterwards moves every waiting seat onto it (shared
#      login, the account just signed in), through `agent set-account`'s
#      plumbing, and only onto a login of the seat's own harness;
#   4. every sign-in path reaches that move: restart_profile_agents (each
#      login's landing), `agent auth set` and `account set` (keys).
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
# shellcheck disable=SC1091
source src/lib/registry.sh
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
# shellcheck disable=SC1091
source src/cmd_auth.sh
# shellcheck disable=SC1091
source src/cmd_agent_create.sh
# shellcheck disable=SC1091
source src/cmd_pack.sh
# shellcheck disable=SC1091
source src/cmd_init.sh
set +e
# The login added last (DIVE-7152) reads the box's login ledger as root; these
# boxes have none, as a fresh box has none.
account_default_v() { return 1; }
require_root() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
REGISTRY="$TMP/agents.json"
REGISTRY_LOCK="$TMP/registry.lock"
registry_write() { local t; t=$(cat); printf '%s\n' "$t" > "$REGISTRY"; }   # the real one chowns to root
export CONNECTORS_DIR
TYPE_AUTH[claude]="$CONNECTORS_DIR/anthropic.env:CLAUDE_CODE_OAUTH_TOKEN"
TYPE_AUTH[codex]="$TMP/codex-default/auth.json"
mkdir -p "$TMP/bin"
for _t in claude codex; do
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$_t"; chmod +x "$TMP/bin/$_t"
  TYPE_BIN[$_t]="$TMP/bin/$_t"
done
cmd_install() { printf 'INSTALL-ATTEMPTED %s\n' "$*"; return 1; }
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only"
# init's AI step runs `5dive agent auth set|login`; the shim saves what the real
# verbs save into the shared login, inside the fixture.
cat > "$TMP/bin/5dive" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  "agent auth set claude --api-key=-") printf 'ANTHROPIC_API_KEY=%s\n' "$(cat)" >> "$CONNECTORS_DIR/anthropic.env" ;;
  "agent auth login claude")           printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture\n' >> "$CONNECTORS_DIR/anthropic.env" ;;
  *) echo "shim: unexpected 5dive $*" >&2; exit 9 ;;
esac
SHIM
chmod +x "$TMP/bin/5dive"
PATH="$TMP/bin:$PATH"

MP='mp:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-mp'
KONST='konst:CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture-konst'
box() {
  rm -rf "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR" "$FIVEDIVE_CHAT_ONLY_MARK" "$STATE_DIR"/account-logins* 2>/dev/null
  mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
  printf '%s\n' '{"agents":{}}' > "$REGISTRY"
  local a
  for a in "$@"; do
    mkdir -p "$AUTH_PROFILES_DIR/${a%%:*}"
    printf '%s\n' "${a#*:}" > "$AUTH_PROFILES_DIR/${a%%:*}/combined.env"
  done
}

# ---------------------------------------------------------------------------
# The import seam: the real cmd_import up to and just past cmd_create.
# ---------------------------------------------------------------------------
printf '%s\n' '{"packFormat":1,"agentName":"marcus","config":{"type":"claude"},"includes":{"memory":false}}' > "$TMP/manifest.json"
: > "$TMP/marcus.tar.gz"
export DIVE7848_FIXTURE="$TMP/manifest.json"
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$DIVE7848_FIXTURE" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
# cmd_create records its argv and registers the seat as the real one would;
# the import is stopped right after its marker write (the next step reads the
# model family), so the graded state is the argv and the registry.
TTY=0
_import_can_ask_ai() { (( TTY )) && (( ! ${JSON_MODE:-0} )) && [[ -z "${FIVEDIVE_NO_PROMPT:-}" ]]; }
imported() { # <label> <stdin> <args>... — "argv: …" then "mark: true|-"
  local label="$1" rec="$TMP/$1.argv" in="$2"; shift 2
  rm -f "$rec" "$TMP/created"
  (
    cmd_create() {
      printf '%s\n' "$@" > "$rec"
      printf '%s' "${FIVEDIVE_CREATE_AWAITS_AI:-unset}" > "$rec.awaits"
      local p=""; p=$(printf '%s\n' "$@" | sed -n 's/^--auth-profile=//p' | head -1)
      local r; r=$(registry_read)
      jq --arg n "$1" --arg p "$p" '.agents[$n] = ({type:"claude"} + (if $p == "" then {} else {authProfile:$p} end))' <<<"$r" | registry_write
      : > "$TMP/created"; return 0
    }
    model_latest() { [[ -f "$TMP/created" ]] && exit 0; return 1; }
    printf '%b' "$in" | cmd_import "$TMP/marcus.tar.gz" "$@"
  ) >"$TMP/$label.out" 2>&1
  [[ -f "$rec" ]] || { echo "(cmd_create not reached)"; [[ -n "${DEBUG7848:-}" ]] && cat "$TMP/$label.out" >&2; return; }
  local prof defer byo
  prof=$(grep -m1 '^--auth-profile=' "$rec" || echo '(shared login)')
  defer=$(grep -qx -- '--defer-auth' "$rec" && echo defer || echo now)
  byo=$(grep -m1 '^--provider=' "$rec" || true)
  printf '%s %s%s mark=%s' "$prof" "$defer" "${byo:+ $byo}" "$(jq -r '.agents.marcus.awaitsAi // "-"' "$REGISTRY")"
}

echo '== 1. import at a terminal, box with no AI: init'"'"'s AI step runs first =='
box; TTY=1
eq_t 'an Anthropic key typed at the step: the seat is on it, signed in, nothing waits' \
  '(shared login) now mark=-' "$(imported key '1\n2\nsk-ant-api03-fixturekey\n' --as=marcus)"
grep -q 'This server has no AI for Claude Code yet' "$TMP/key.out" \
  && ok_t 'the owner is told why before the step' || bad_t 'no "no AI" line before the step' "$(head -5 "$TMP/key.out")"
grep -q 'How should Claude Code authenticate?' "$TMP/key.out" \
  && ok_t "it is init's own step (same question)" || bad_t "init's AI step did not run" "$(cat "$TMP/key.out")"
grep -q '^ANTHROPIC_API_KEY=sk-ant-api03-fixturekey$' "$CONNECTORS_DIR/anthropic.env" 2>/dev/null \
  && ok_t "the key went where init puts it (the shared login)" || bad_t 'key not in the shared login' ''
box; TTY=1
eq_t 'Sign in with Claude at the step: the seat is on the sign-in' \
  '(shared login) now mark=-' "$(imported oauth '1\n1\n' --as=marcus)"
box; TTY=1
eq_t 'a custom provider at the step: the import carries it as its own --provider/--api-key' \
  '--auth-profile=marcus now --provider=openrouter mark=-' "$(imported byo '1\n3\n1\nsk-or-v1-fixturekey\n' --as=marcus)"
grep -qx -- '--api-key=sk-or-v1-fixturekey' "$TMP/byo.argv" \
  && ok_t 'and its key' || bad_t 'custom provider key not forwarded' "$(cat "$TMP/byo.argv")"
box; TTY=1
eq_t '"Later": the per-agent account as before, and the seat waits for an AI' \
  '--auth-profile=marcus defer mark=true' "$(imported later '2\n' --as=marcus)"
grep -q "starts by itself when you add one" "$TMP/later.out" \
  && ok_t 'and the owner is told it starts by itself' || bad_t 'no "starts by itself" line' "$(tail -5 "$TMP/later.out")"
box; TTY=1
# A sign-in that fails inside init's step ends the step, not the import.
cat > "$TMP/bin/5dive" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
eq_t 'a sign-in that fails: the import still lands, and the seat waits' \
  '--auth-profile=marcus defer mark=true' "$(imported fails '1\n1\n' --as=marcus)"
cat > "$TMP/bin/5dive" <<'SHIM'
#!/usr/bin/env bash
case "$*" in
  "agent auth set claude --api-key=-") printf 'ANTHROPIC_API_KEY=%s\n' "$(cat)" >> "$CONNECTORS_DIR/anthropic.env" ;;
  "agent auth login claude")           printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-fixture\n' >> "$CONNECTORS_DIR/anthropic.env" ;;
  *) echo "shim: unexpected 5dive $*" >&2; exit 9 ;;
esac
SHIM

echo '== 2. off a terminal, and boxes that already have AI =='
box; TTY=0
eq_t 'no terminal (the lead hires from chat): no prompt, the seat waits' \
  '--auth-profile=marcus defer mark=true' "$(imported notty '1\n2\nsk-ant-api03-x\n' --as=marcus)"
grep -q 'How should' "$TMP/notty.out" && bad_t 'prompted off a terminal' '' || ok_t 'and nothing is asked'
eq_t "...and create is told the seat waits for an AI (its self-check's advice reads this)" 1 "$(cat "$TMP/notty.argv.awaits")"
box; TTY=1; JSON_MODE=1
eq_t '--json at a terminal: never prompts, the seat waits' \
  '--auth-profile=marcus defer mark=true' "$(imported json '1\n2\nsk-ant-api03-x\n' --as=marcus)"
JSON_MODE=0
box "$MP" "$KONST"; TTY=1
eq_t 'two logins on the box (it has AI, the owner picks): not asked, not marked (NEGATIVE CONTROL)' \
  '--auth-profile=marcus defer mark=-' "$(imported two '1\n2\nsk-ant-api03-x\n' --as=marcus)"
eq_t '...and create is NOT told it waits (NEGATIVE CONTROL)' 0 "$(cat "$TMP/two.argv.awaits")"
box "$MP"; TTY=1
eq_t "one login: its seat, as DIVE-7028 made it (create signs it in there; NEGATIVE CONTROL)" \
  '--auth-profile=mp defer mark=-' "$(imported one '1\n' --as=marcus)"
box; printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-x\n' > "$CONNECTORS_DIR/anthropic.env"; TTY=1
eq_t "init's shared login: its seat, as DIVE-7118 made it (NEGATIVE CONTROL)" \
  '(shared login) now mark=-' "$(imported shared '1\n' --as=marcus)"
box; TTY=1
eq_t 'an explicit --auth-profile is never second-guessed' \
  '--auth-profile=konst defer mark=-' "$(imported explicit '1\n' --as=marcus --auth-profile=konst)"

echo "== 2b. create's self-check gives a waiting seat the right advice =="
# The real line cmd_create's self-check prints for a deferred-auth seat (it
# calls selfcheck_deferred_auth_issue; asserted below so the arms grade it).
aw=$(FIVEDIVE_CREATE_AWAITS_AI=1 selfcheck_deferred_auth_issue claude marcus)
[[ "$aw" == *'--auth-profile=marcus'* || "$aw" == *'auth login'* ]] \
  && bad_t 'a waiting seat is told to log in on its own account' "$aw" \
  || ok_t 'a waiting seat is not told `auth login … --auth-profile=marcus`'
[[ "$aw" == *'starts by itself'* && "$aw" == *'sudo 5dive init'* ]] \
  && ok_t '...it is told it starts by itself once an AI is added (sudo 5dive init)' || bad_t 'waiting-seat advice' "$aw"
pl=$(FIVEDIVE_CREATE_AWAITS_AI=0 selfcheck_deferred_auth_issue claude marcus)
[[ "$pl" == *'sudo 5dive agent auth login claude --auth-profile=marcus'* ]] \
  && ok_t 'a plain --defer-auth seat still gets its login line (CONTROL)' || bad_t 'plain --defer-auth advice' "$pl"
pl=$(unset FIVEDIVE_CREATE_AWAITS_AI; selfcheck_deferred_auth_issue claude marcus)
[[ "$pl" == *'--auth-profile=marcus'* ]] \
  && ok_t '...and so does one created with no word from import (CONTROL)' || bad_t 'unset advice' "$pl"
grep -qF '_hc_issues+=("$(selfcheck_deferred_auth_issue "$type" "$profile")")' src/cmd_agent_create.sh \
  && ok_t "create's self-check prints that line for a deferred-auth seat" || bad_t "create's self-check no longer calls selfcheck_deferred_auth_issue" ''
grep -qF '( FIVEDIVE_CREATE_AWAITS_AI="$awaits_ai" cmd_create "${cargs[@]}" )' src/cmd_pack.sh \
  && ok_t 'import passes its awaits-AI verdict to create' || bad_t 'import no longer tells create' ''

echo '== 3. the first AI added afterwards moves every waiting seat =='
MOVES="$TMP/moves"
cmd_config() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$MOVES"; local r; r=$(registry_read)
  local v="${3#auth-profile=}"
  if [[ "$v" == default ]]; then jq --arg n "$1" 'del(.agents[$n].authProfile)' <<<"$r" | registry_write
  else jq --arg n "$1" --arg v "$v" '.agents[$n].authProfile = $v' <<<"$r" | registry_write; fi; }
waiting() { # <agent:type:profile>... — seats an import left waiting
  printf '%s\n' '{"agents":{}}' > "$REGISTRY"; : > "$MOVES"
  local a n t p r
  for a in "$@"; do
    IFS=: read -r n t p <<<"$a"
    mkdir -p "$AUTH_PROFILES_DIR/$p"; : >> "$AUTH_PROFILES_DIR/$p/combined.env"
    r=$(registry_read)
    jq --arg n "$n" --arg t "$t" --arg p "$p" '.agents[$n] = {type:$t, authProfile:$p, awaitsAi:true}' <<<"$r" | registry_write
  done
}
marks() { jq -r '[.agents | to_entries[] | select(.value.awaitsAi == true) | .key] | join(",")' "$REGISTRY"; }
moves() { tr '\n' ';' < "$MOVES"; }

box; waiting marcus:claude:marcus olivia:claude:olivia
adopt_ai_waiting_agents "" >/dev/null 2>&1
eq_t 'no AI yet: nothing moves, both still wait' '' "$(moves)"
eq_t '...and keep their mark' 'marcus,olivia' "$(marks)"

box; waiting marcus:claude:marcus olivia:claude:olivia
printf 'ANTHROPIC_API_KEY=sk-ant-api03-x\n' > "$CONNECTORS_DIR/anthropic.env"
adopt_ai_waiting_agents "" >/dev/null 2>&1
eq_t "5dive init's shared login: every waiting seat moves onto it" \
  'marcus set auth-profile=default;olivia set auth-profile=default;' "$(moves)"
eq_t '...and stops waiting' '' "$(marks)"
eq_t '...with no account binding (the shared login)' '-' "$(jq -r '.agents.marcus.authProfile // "-"' "$REGISTRY")"

box "$KONST"; waiting marcus:claude:marcus
adopt_ai_waiting_agents konst >/dev/null 2>&1
eq_t 'an account signed in (`account login konst`): the seat moves onto it' \
  'marcus set auth-profile=konst;' "$(moves)"

box "$KONST" "$MP"; waiting marcus:claude:marcus
adopt_ai_waiting_agents mp >/dev/null 2>&1
eq_t 'two accounts: the one that just landed wins' 'marcus set auth-profile=mp;' "$(moves)"

box; waiting marcus:claude:marcus
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-own\n' > "$AUTH_PROFILES_DIR/marcus/combined.env"
adopt_ai_waiting_agents marcus >/dev/null 2>&1
eq_t 'the seat signed in on its own account (the old per-agent line): no move' '' "$(moves)"
eq_t '...and it stops waiting' '' "$(marks)"

box "$KONST"; waiting pat:codex:pat
adopt_ai_waiting_agents konst >/dev/null 2>&1
eq_t 'a Codex seat is never moved onto a Claude login (NEGATIVE CONTROL)' '' "$(moves)"
eq_t '...it keeps waiting' 'pat' "$(marks)"

box "$KONST"; waiting marcus:claude:marcus
r=$(registry_read); jq '.agents.ada = {type:"claude", authProfile:"ada"}' <<<"$r" | registry_write
mkdir -p "$AUTH_PROFILES_DIR/ada"
adopt_ai_waiting_agents konst >/dev/null 2>&1
eq_t 'a seat not marked (deferred on purpose elsewhere) is never moved (NEGATIVE CONTROL)' \
  'marcus set auth-profile=konst;' "$(moves)"

echo '== 4. every sign-in path reaches the move =='
box; waiting marcus:claude:marcus
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-x\n' > "$CONNECTORS_DIR/anthropic.env"
normalize_profile_seed_perms() { :; }
heal_claude_shadow_creds() { :; }
systemctl() { :; }
restart_profile_agents "" >/dev/null 2>&1
eq_t 'a sign-in landing (restart_profile_agents, every login path) moves the waiting seat' \
  'marcus set auth-profile=default;' "$(moves)"
box "$KONST"; waiting marcus:claude:marcus
restart_profile_agents konst >/dev/null 2>&1
eq_t '...and an account sign-in landing moves it onto that account' 'marcus set auth-profile=konst;' "$(moves)"
eq_t '`agent auth set <type> --auth-profile=x` names x' 'x' "$(_ai_arg_account claude --api-key=- --auth-profile=x)"
eq_t '`agent auth set <type>` names the shared login, not the type' '' "$(_ai_arg_account claude --api-key=-)"
eq_t '`account set <name>` names the account' 'konst' "$(_ai_arg_account --positional konst --type=claude --api-key=-)"
grep -qF 'cmd_auth_set "$@" && adopt_ai_waiting_agents "$(_ai_arg_account "$@")"' src/main.sh \
  && ok_t '`agent auth set` (a key, init'"'"'s key step) runs the move' || bad_t '`agent auth set` does not run the move' ''
grep -qF 'with_registry_lock cmd_account_set "$@" && adopt_ai_waiting_agents "$(_ai_arg_account --positional "$@")"' src/main.sh \
  && ok_t '`account set` (the app'"'"'s secure key page) runs the move' || bad_t '`account set` does not run the move' ''
grep -qF '_init_ai_step "$type" "${type_label[$type]}"' src/cmd_init.sh \
  && ok_t "5dive init runs the same AI step the import runs" || bad_t 'init no longer calls _init_ai_step' ''

echo
printf 'DIVE-7848 import on a box with no AI works in either order: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
