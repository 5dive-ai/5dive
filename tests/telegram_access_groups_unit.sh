#!/usr/bin/env bash
# DIVE-6675 — `agent telegram-access groups <name> [--answer=name|every]`, the
# box half of the app's "In groups, answer: when called by name · every message".
# Grades the read (stored key, derived value, mixed), the write (every group's
# requireMention + groupsRequireMention for groups added later, other keys kept),
# the refusals, and the dispatch in main.sh.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/tg-access-groups-unit.XXXXXX)"
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
REG='{"agents":{"olivia":{"type":"claude","channels":"telegram"},"mute":{"type":"claude","channels":"none"},"oc":{"type":"openclaw","channels":"telegram"}}}'
registry_read() { printf '%s' "$REG"; }
STATE="$TMP/state"
_tg_access_state_dir() { case "$2" in claude) printf '%s' "$STATE" ;; *) return 1 ;; esac; }
# The fixture agent is not a real user: run the write as the caller.
sudo() { [[ "$1" == -u ]] && shift 2; "$@"; }
# No bot token in the fixture: getMe is stubbed, and fails until DIVE-6729's arms.
_tg_bot_first_name() { return 1; }

run() { ( cmd_telegram_access_groups "$@" ) 2>"$TMP/err"; }
field() { jq -r ".data.$1" <<<"$out"; }

# --- read, no file yet: the plugin's own default ---------------------------
out=$(run olivia) && [[ "$(field answer)" == name && "$(field groups)" == 0 && "$(field mixed)" == false ]] \
  && okk 'no access.json reads "when called by name", 0 groups' || bad "no-file read: $out"
[[ ! -e "$STATE/access.json" ]] && okk 'a read writes nothing' || bad 'a read created access.json'

# --- read, derived from the groups when no key is stored --------------------
mkdir -p "$STATE"
cat >"$STATE/access.json" <<'J'
{"dmPolicy":"allowlist","allowFrom":["1"],"groups":{"-100":{"requireMention":false,"allowFrom":[]},"-200":{"requireMention":false,"message_thread_id":7}},"pending":{"ab":{"senderId":"9"}},"owners":["1"]}
J
out=$(run olivia) && [[ "$(field answer)" == every && "$(field groups)" == 2 && "$(field mixed)" == false ]] \
  && okk 'every group answering every message reads "every"' || bad "derived every: $out"
jq '.groups["-200"].requireMention=true' "$STATE/access.json" >"$TMP/a" && cp "$TMP/a" "$STATE/access.json"
out=$(run olivia) && [[ "$(field answer)" == name && "$(field mixed)" == true ]] \
  && okk 'groups that differ read "name", mixed' || bad "derived mixed: $out"

# --- write: every message ---------------------------------------------------
before=$(jq -c 'del(.groups)' "$STATE/access.json")
out=$(run olivia --answer=every) && [[ "$(field answer)" == every && "$(field groups)" == 2 && "$(field mixed)" == false ]] \
  && okk '--answer=every answers every, mixed cleared' || bad "write every: $out"
[[ "$(jq -c '[.groups[].requireMention]' "$STATE/access.json")" == '[false,false]' ]] \
  && okk 'every group now has requireMention false' || bad "groups after every: $(jq -c .groups "$STATE/access.json")"
[[ "$(jq '.groupsRequireMention' "$STATE/access.json")" == false ]] \
  && okk 'groupsRequireMention false, for a group added later' || bad 'groupsRequireMention not written'
[[ "$(jq -c 'del(.groups, .groupsRequireMention)' "$STATE/access.json")" == "$before" ]] \
  && okk 'every other key is kept as it was' || bad "other keys changed: $(jq -c . "$STATE/access.json")"
[[ "$(jq '.groups["-200"].message_thread_id' "$STATE/access.json")" == 7 ]] \
  && okk "a group's own fields survive" || bad 'message_thread_id lost'
tmps=("$STATE"/.access.*); [[ -e "${tmps[0]}" ]] && bad 'write left a temp file' || okk 'write leaves no temp file'

# --- the stored key outranks the groups -------------------------------------
out=$(run olivia --answer=name) && [[ "$(jq -c '[.groups[].requireMention]' "$STATE/access.json")" == '[true,true]' && "$(field answer)" == name ]] \
  && okk '--answer=name flips every group back' || bad "write name: $out"
jq '.groups["-100"].requireMention=false' "$STATE/access.json" >"$TMP/a" && cp "$TMP/a" "$STATE/access.json"
out=$(run olivia) && [[ "$(field answer)" == name && "$(field mixed)" == true ]] \
  && okk 'one group flipped on its own reads mixed under the stored answer' || bad "stored+mixed: $out"

# --- with no group yet, the choice is still kept ---------------------------
printf '{"dmPolicy":"pairing","allowFrom":[],"groups":{}}' >"$STATE/access.json"
run olivia --answer=every >/dev/null && out=$(run olivia) && [[ "$(field answer)" == every && "$(field groups)" == 0 ]] \
  && okk '"every" on a box with no group yet reads back "every"' || bad "no-group every: $out"

# --- DIVE-6684: --names, the names it also answers to ---------------------
cat >"$STATE/access.json" <<'J'
{"dmPolicy":"pairing","allowFrom":[],"groups":{"-100":{"requireMention":true}},"groupsRequireMention":true,"owners":["1"]}
J
before=$(jq -c 'del(.groupsCallNames)' "$STATE/access.json")
out=$(run olivia --names='Оля, Liv ,奥利维亚,оля,Mary  Ann') && [[ "$(jq -c .data.names <<<"$out")" == '["Оля","Liv","奥利维亚","Mary Ann"]' ]] \
  && okk '--names writes the list: trimmed, any script, a repeat dropped' || bad "write names: $out"
[[ "$(jq -c .groupsCallNames "$STATE/access.json")" == '["Оля","Liv","奥利维亚","Mary Ann"]' ]] \
  && okk 'groupsCallNames stored as the names, unescaped' || bad "stored: $(jq -c .groupsCallNames "$STATE/access.json")"
grep -q '奥利维亚' "$STATE/access.json" && okk 'non-Latin names are kept as text, not \u escapes' || bad 'names escaped in access.json'
[[ "$(jq -c 'del(.groupsCallNames, .groupsCallNamesComplete)' "$STATE/access.json")" == "$before" ]] \
  && okk '--names alone leaves the answer and the groups as they were' || bad "names touched other keys: $(jq -c . "$STATE/access.json")"
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Оля","Liv","奥利维亚","Mary Ann"]' && "$(field answer)" == name ]] \
  && okk 'the read returns names beside answer, groups and mixed' || bad "read names: $out"
out=$(run olivia --answer=every --names=Liv) && [[ "$(field answer)" == every && "$(jq -c .data.names <<<"$out")" == '["Liv"]' ]] \
  && okk '--answer and --names in one write' || bad "both: $out"
jq '.groupsCallNames += [".*", 7]' "$STATE/access.json" >"$TMP/a" && cp "$TMP/a" "$STATE/access.json"
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Liv"]' ]] \
  && okk 'a hand-edited pattern on the list is not read back as a name' || bad "read filter: $out"
out=$(run olivia --names=) && [[ "$(jq -c .data.names <<<"$out")" == '[]' && "$(jq -c .groupsCallNames "$STATE/access.json")" == '[]' ]] \
  && okk 'an empty --names= stores an empty list' || bad "clear: $out"
cp "$STATE/access.json" "$TMP/keep"
for badnames in '.*' 'a' 'a -' '- a' 'Liv a' 'Liv-' 'Liv2' 'Оля|Ольга' "$(printf 'x%.0s' {1..33})" 'A1,B2' "$(seq -s, -f 'Name%g' 1 11 | tr 0-9 a-j)"; do
  run olivia --names="$badnames" >/dev/null && bad "accepted --names=$badnames" \
    || { grep -q 'names: ' "$TMP/err" && cmp -s "$TMP/keep" "$STATE/access.json" || bad "bad names wrote or said nothing: $badnames $(cat "$TMP/err")"; }
done
cmp -s "$TMP/keep" "$STATE/access.json" && okk 'a bad name, a pattern or 11 names are refused and nothing is written' || bad 'refused names changed the file'
run olivia --names='Liv' --answer=all >/dev/null; cmp -s "$TMP/keep" "$STATE/access.json" && okk 'a bad --answer with --names writes nothing' || bad 'bad answer + names wrote'

# --- DIVE-6729: "Answers to" is every name, the bot-name word too -----------
cat >"$STATE/access.json" <<'J'
{"dmPolicy":"pairing","allowFrom":[],"groups":{"-100":{"requireMention":true}},"groupsRequireMention":true,"groupsCallNames":["Matcha","janis"]}
J
_tg_bot_first_name() { printf "Janis's matcha assistant"; }
before=$(cat "$STATE/access.json")
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Janis","Matcha"]' && "$(field namesComplete)" == true ]] \
  && okk 'a read lists the bot-name word first, then the extras, a repeat of it dropped' || bad "read with bot word: $out"
[[ "$(cat "$STATE/access.json")" == "$before" ]] && okk 'that read writes nothing' || bad 'read with bot word wrote'
_tg_bot_first_name() { printf '🤖 Оливия | Sales'; }
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Оливия","Matcha","janis"]' ]] \
  && okk "the bot word is the plugin's: the first run of letters" || bad "first run: $out"
_tg_bot_first_name() { printf '🤖 X'; }
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Matcha","janis"]' && "$(field namesComplete)" == true ]] \
  && okk 'a bot name with no word of 2+ letters adds nothing' || bad "no word: $out"
_tg_bot_first_name() { return 1; }
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == null && "$(field namesComplete)" == false ]] \
  && okk 'getMe down and the list never saved: names null, so no caller saves it without the bot word' || bad "getMe down: $out"
_tg_bot_first_name() { printf "Janis's matcha assistant"; }
out=$(run olivia --names='Matcha') && [[ "$(jq -c .data.names <<<"$out")" == '["Matcha"]' && "$(field namesComplete)" == true ]] \
  && okk 'a write without the bot word answers the list as written' || bad "write without bot word: $out"
[[ "$(jq -c '[.groupsCallNames, .groupsCallNamesComplete]' "$STATE/access.json")" == '[["Matcha"],true]' ]] \
  && okk 'access.json holds the whole list and groupsCallNamesComplete' || bad "stored: $(jq -c . "$STATE/access.json")"
out=$(run olivia) && [[ "$(jq -c .data.names <<<"$out")" == '["Matcha"]' ]] \
  && okk 'once saved, a read no longer adds the bot word' || bad "read after save: $out"
_tg_bot_first_name() { return 1; }
out=$(run olivia) && [[ "$(field namesComplete)" == true ]] \
  && okk 'once saved, the list is whole even with getMe down' || bad "saved + getMe down: $out"
out=$(run olivia --answer=every) && [[ "$(jq -c .groupsCallNames "$STATE/access.json")" == '["Matcha"]' && "$(jq .groupsCallNamesComplete "$STATE/access.json")" == true ]] \
  && okk '--answer alone keeps the saved list and its flag' || bad "answer kept list: $(jq -c . "$STATE/access.json")"
out=$(run olivia --names=) && [[ "$(jq -c .data.names <<<"$out")" == '[]' && "$(field namesComplete)" == true ]] \
  && said=$( JSON_MODE=0; run olivia ) && [[ "$said" == *'answers to no name, only an @mention or a reply'* ]] \
  && okk 'an empty list is allowed and says only an @mention or a reply wakes it' || bad "empty list: $out $(cat "$TMP/err")"
printf '{"groups":{},"groupsCallNames":["Liv"]}' >"$STATE/access.json"
NAMES_ADD=Tencha STATE="$STATE" python3 -c "$(_tg_group_answer_py)" >/dev/null
[[ "$(jq -c '[.groupsCallNames, has("groupsCallNamesComplete")]' "$STATE/access.json")" == '[["Liv","Tencha"],false]' ]] \
  && okk 'the card-name seed adds to the extras and does not mark the list whole' || bad "seed: $(jq -c . "$STATE/access.json")"
_tg_bot_first_name() { return 1; }

# --- refusals ---------------------------------------------------------------
cp "$STATE/access.json" "$TMP/keep"
run olivia --answer=all >/dev/null && bad 'accepted --answer=all' \
  || { grep -q 'name (when called by name) or every' "$TMP/err" && okk 'a bad --answer is refused and says the two values' || bad "bad-answer msg: $(cat "$TMP/err")"; }
cmp -s "$TMP/keep" "$STATE/access.json" && okk 'a refused write touches nothing' || bad 'refused write changed the file'
run nobody >/dev/null && bad 'accepted an unknown agent' || okk 'an unknown agent is refused'
run mute >/dev/null && bad 'accepted an agent without telegram' || okk 'an agent without telegram is refused'
run oc >/dev/null && bad 'accepted an openclaw agent' || okk 'a type with no access.json is refused'
printf 'not json' >"$STATE/access.json"
run olivia --answer=every >/dev/null && bad 'wrote over a broken access.json' || okk 'a broken access.json is refused, not overwritten'
[[ "$(cat "$STATE/access.json")" == 'not json' ]] && okk 'the broken file is left as it was' || bad 'broken file replaced'

# --- a failure with no message names what failed: read or write -----------
sudo() { return 1; }
run olivia >/dev/null; grep -qF "telegram access.json read failed for agent 'olivia'" "$TMP/err" \
  && okk 'a silent read failure says "read failed"' || bad "read failure msg: $(cat "$TMP/err")"
run olivia --answer=every >/dev/null; grep -qF "telegram access.json write failed for agent 'olivia'" "$TMP/err" \
  && okk 'a silent write failure says "write failed", not "writeevery"' || bad "write failure msg: $(cat "$TMP/err")"
sudo() { [[ "$1" == -u ]] && shift 2; "$@"; }

# --- dispatch ---------------------------------------------------------------
grep -q 'groups)' "$ROOT/src/main.sh" && grep -q 'cmd_telegram_access_groups "\$@"' "$ROOT/src/main.sh" \
  && okk 'main.sh routes telegram-access groups' || bad 'main.sh does not route groups'
grep -q 'telegram-access groups <name> \[--answer=name|every\]' "$ROOT/src/main.sh" \
  && okk 'agent usage documents the verb' || bad 'usage line missing'
grep -q 'telegram-access groups <name> \[--answer=name|every\] \[--names=' "$ROOT/src/main.sh" \
  && okk 'agent usage documents --names' || bad 'usage line lacks --names'
grep -qF '" $* " == *" --names="*' "$ROOT/src/main.sh" && okk 'a --names write is audited' || bad '--names write not audited'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
