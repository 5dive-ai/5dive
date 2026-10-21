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

# --- dispatch ---------------------------------------------------------------
grep -q 'groups)' "$ROOT/src/main.sh" && grep -q 'cmd_telegram_access_groups "\$@"' "$ROOT/src/main.sh" \
  && okk 'main.sh routes telegram-access groups' || bad 'main.sh does not route groups'
grep -q 'telegram-access groups <name> \[--answer=name|every\]' "$ROOT/src/main.sh" \
  && okk 'agent usage documents the verb' || bad 'usage line missing'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
