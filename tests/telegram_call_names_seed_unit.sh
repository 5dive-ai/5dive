#!/usr/bin/env bash
# DIVE-6701 — an agent also answers to its card name in its Telegram groups.
# `agent telegram-access seed-names [<name>]` adds `name:` from the agent's
# ~/.claude/persona.yaml to groupsCallNames ONCE: grades the add, the no-duplicate
# with a hand-set copy, the owner's removal surviving a re-run, the seat id and a
# full list, a broken access.json, and the wiring into import, config and
# self-update.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/tg-call-names-seed-unit.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
pass=0; fail=0
okk() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/src/lib/output.sh"
# shellcheck source=/dev/null
source "$ROOT/src/cmd_agent_pairing.sh"
E_USAGE=2; E_NOT_FOUND=3; E_VALIDATION=4
JSON_MODE=1
ensure_state() { :; }
REG='{"agents":{"ceo":{"type":"claude","channels":"telegram"},"olivia":{"type":"claude","channels":"telegram"},"mute":{"type":"claude","channels":"none"},"ru":{"type":"codex","channels":"telegram,discord"}}}'
registry_read() { printf '%s' "$REG"; }
STATE_DIR="$TMP/box"
# shellcheck disable=SC2034  # read by _tg_call_names_candidate
AGENT_HOME_ROOT="$TMP/home"
_tg_access_state_dir() { case "$2" in claude|codex) printf '%s/%s/tg' "$TMP/home" "$1" ;; *) return 1 ;; esac; }
# The fixture agents are not real users: run the write as the caller.
sudo() { [[ "$1" == -u ]] && shift 2; "$@"; }

persona() { mkdir -p "$TMP/home/agent-$1/.claude"; printf 'openagent: "0.2"\nid: %s\nname: %s\nrole: CEO\n' "$1" "$2" >"$TMP/home/agent-$1/.claude/persona.yaml"; }
access() { mkdir -p "$TMP/home/agent-$1/tg"; printf '%s' "$2" >"$TMP/home/agent-$1/tg/access.json"; }
names() { jq -c '.groupsCallNames // []' "$TMP/home/agent-$1/tg/access.json" 2>/dev/null || echo none; }
seed() { ( cmd_telegram_access_seed_names "$@" ) 2>"$TMP/err"; }
groups() { ( cmd_telegram_access_groups "$@" ) 2>"$TMP/err"; }

# --- a hired agent with no access.json yet gets its card name ---------------
persona ceo Tencha
out=$(seed ceo) && [[ "$(names ceo)" == '["Tencha"]' ]] \
  && okk 'the card name is added to "Also answers to"' || bad "first seed: $out / $(names ceo)"
[[ "$(jq -c '.data.seeded' <<<"$out")" == '[{"name":"ceo","added":"Tencha"}]' ]] \
  && okk 'the envelope names who got which name' || bad "envelope: $out"
grep -qx 'Tencha' "$STATE_DIR/call-names-seeded/ceo" && okk 'the offer is remembered outside access.json' || bad 'no marker'
[[ "$(jq 'has("groupsRequireMention")' "$TMP/home/agent-ceo/tg/access.json")" == false ]] \
  && okk 'the seed writes the names only, not the answer setting' || bad "seed wrote more: $(cat "$TMP/home/agent-ceo/tg/access.json")"

# --- a second run adds nothing ----------------------------------------------
cp "$TMP/home/agent-ceo/tg/access.json" "$TMP/keep"
out=$(seed ceo) && cmp -s "$TMP/keep" "$TMP/home/agent-ceo/tg/access.json" && [[ "$(jq -c .data.seeded <<<"$out")" == '[]' ]] \
  && okk 'a re-run changes nothing' || bad "re-run: $out / $(names ceo)"

# --- the owner removes it in the app: it stays removed ----------------------
groups ceo --names= >/dev/null
out=$(seed ceo) && [[ "$(names ceo)" == '[]' ]] \
  && okk 'a name the owner removed is not added back' || bad "removed came back: $(names ceo)"
# ...even when the plugin rewrites access.json with only the keys it knows.
access ceo '{"dmPolicy":"pairing","allowFrom":[],"groups":{}}'
out=$(seed ceo) && [[ "$(names ceo)" == '[]' ]] \
  && okk 'the plugin rewriting access.json does not bring it back' || bad "rewrite brought it back: $(names ceo)"

# --- already hand-set (lodar's ceo): kept, no duplicate ---------------------
rm -rf "$STATE_DIR"
access ceo '{"dmPolicy":"pairing","groups":{"-100":{"requireMention":true}},"groupsCallNames":["Janis","tencha"],"owners":["1"]}'
before=$(cat "$TMP/home/agent-ceo/tg/access.json")
out=$(seed ceo) && [[ "$(names ceo)" == '["Janis","tencha"]' ]] \
  && okk 'a hand-set copy in another case is kept, no duplicate' || bad "dup: $(names ceo)"
[[ "$(cat "$TMP/home/agent-ceo/tg/access.json")" == "$before" ]] && okk 'nothing to add writes nothing' || bad 'file rewritten with nothing added'
grep -qx 'Tencha' "$STATE_DIR/call-names-seeded/ceo" && okk 'the offer is still remembered' || bad 'no marker after a no-op offer'

# --- added beside the owner's own names, in any script ----------------------
persona ru 'Тенча'
access ru '{"groupsCallNames":["Liv"]}'
out=$(seed ru) && [[ "$(names ru)" == '["Liv","Тенча"]' ]] \
  && okk 'a Cyrillic card name is added after the owner'"'"'s own' || bad "ru: $(names ru)"
grep -q 'Тенча' "$TMP/home/agent-ru/tg/access.json" && okk 'kept as text, not \u escapes' || bad 'escaped'

# --- not offered: the seat id, no persona, a full list, not a name ---------
persona olivia Olivia; access olivia '{}'
seed olivia >/dev/null; [[ "$(names olivia)" == '[]' ]] && okk 'the seat id is not a name' || bad "seat id seeded: $(names olivia)"
rm -rf "$STATE_DIR" "$TMP/home/agent-olivia/.claude"
seed olivia >/dev/null; [[ "$(names olivia)" == '[]' && ! -e "$STATE_DIR/call-names-seeded/olivia" ]] \
  && okk 'no persona, nothing seeded or remembered' || bad 'seeded with no persona'
persona olivia 'Liv'; access olivia "{\"groupsCallNames\":$(jq -nc '[range(10)] | map("Name" + ("abcdefghij"[.:.+1]))')}"
seed olivia >/dev/null; [[ "$(jq length <<<"$(names olivia)")" == 10 && "$(names olivia)" != *Liv* ]] \
  && okk 'a full list of 10 is left as it is' || bad "full list: $(names olivia)"
rm -rf "$STATE_DIR"; persona olivia 'R2-D2'; access olivia '{}'
seed olivia >/dev/null; [[ "$(names olivia)" == '[]' ]] && okk 'a card name that is not a name is skipped' || bad "R2-D2: $(names olivia)"

# --- the whole box: Telegram agents only ------------------------------------
rm -rf "$STATE_DIR" "${TMP:?}/home"
persona ceo Tencha; persona mute Echo; persona ru Тенча
out=$(seed) && [[ "$(jq -c '[.data.seeded[].name]' <<<"$out")" == '["ceo","ru"]' && "$(jq .data.checked <<<"$out")" == 3 ]] \
  && okk 'a bare run seeds every Telegram agent, 3 checked' || bad "box run: $out"
[[ ! -e "$TMP/home/agent-mute/tg" ]] && okk 'an agent with no Telegram is not touched' || bad 'mute touched'
seed nobody >/dev/null && bad 'accepted an unknown agent' || okk 'an unknown agent is refused'

# --- a broken access.json: warned, not overwritten, offered again later ----
rm -rf "$STATE_DIR"; access ceo 'not json'
seed ceo >/dev/null
[[ "$(cat "$TMP/home/agent-ceo/tg/access.json")" == 'not json' && ! -e "$STATE_DIR/call-names-seeded/ceo" ]] \
  && okk 'a broken access.json is left as it was and the name is offered again next time' || bad 'broken file overwritten or remembered'
grep -q "could not seed the names 'ceo' answers to" "$TMP/err" && okk 'and the failure is said' || bad "no warning: $(cat "$TMP/err")"

# --- wiring -----------------------------------------------------------------
grep -qF '_tg_call_names_seed "$as" "$type"' "$ROOT/src/cmd_pack.sh" && grep -qF 'rm -f "$(_tg_call_names_marker "$as")"' "$ROOT/src/cmd_pack.sh" \
  && okk 'agent import seeds the card name, fresh marker' || bad 'import does not seed'
grep -qF '_tg_call_names_seed "$name" "$type"' "$ROOT/src/cmd_agent_config.sh" \
  && okk 'attaching a bot later seeds it too' || bad 'config does not seed'
grep -qF 'agent telegram-access seed-names' "$ROOT/src/cmd_selfupdate.sh" \
  && okk 'self-update backfills agents hired before' || bad 'self-update does not backfill'
grep -qF 'cmd_telegram_access_seed_names "$@"' "$ROOT/src/main.sh" && grep -qF 'telegram-access seed-names [<name>]' "$ROOT/src/main.sh" \
  && okk 'main.sh routes and documents seed-names' || bad 'seed-names not routed'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
