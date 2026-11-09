#!/usr/bin/env bash
# DIVE-7972 (DIVE-7963 finding #2) — the team-bot listener refuses outside text.
#
# The shared team-bot listener (root, src/cmd_agent_teambot.sh) dropped a message
# into an agent's relay-in when it was not from a bot and its thread id was mapped.
# Nothing checked the chat or the sender, so a stranger in the team group, or
# anyone who added the team bot to their own supergroup and posted in a thread
# with a matching id, reached a sudo agent as its owner.
#
# Arms (the gate block is cut out of the embedded listener and run on bun):
#   (a) the owner in the team group, in the agent's thread, gets through;
#   (b) a stranger in the team group is refused;
#   (c) the owner's id in a FOREIGN supergroup with the same thread id is refused;
#   (d) a lane with no registered chat id, or an agent with no allowFrom, refuses
#       everyone (fail closed); the agent-level allowFrom is the fallback when the
#       group entry's list is empty; a sender with no id is refused;
#   (e) the poll loop runs the gate BEFORE rate-limit and drop, and the listener
#       still transpiles;
#   (f) MUTANT: the gate's chat check removed -> (c) would go green for the
#       attacker, so (c)'s detector is live.
#
# Run: bash tests/team_bot_sender_gate_unit.sh (no root, no network). Needs bun.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
L=src/cmd_agent_teambot.sh
TMP="$(mktemp -d /tmp/team-sender-gate.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
BUN=$(command -v bun) || { echo "FAIL bun is required" >&2; exit 1; }

sed -n '/^\/\/ --- team-sender-gate (DIVE-7972) ---$/,/^\/\/ --- end team-sender-gate ---$/p' "$L" > "$TMP/gate.ts"
[[ -s "$TMP/gate.ts" ]] || { bad_t "gate block found in the listener" "no team-sender-gate markers in $L"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# One verdict per line: <name> <ok|no>. Fixtures: team group -100111, owner 433, stranger 999.
run_arms() {  # $1 = gate source file
  cat "$1" - > "$TMP/run.ts" <<'TS'
const TEAM = -100111, FOREIGN = -100999, OWNER = 433, STRANGER = 999
const lane = { chatId: TEAM }
const acc = { allowFrom: ['433'], groups: { [String(TEAM)]: { allowFrom: ['433'], message_thread_id: 7 } } }
const m = (chat: number, from: number | undefined) => ({ chat: { id: chat }, from: from == null ? {} : { id: from }, message_thread_id: 7 })
const v = (name: string, r: { ok: boolean }) => console.log(`${name} ${r.ok ? 'ok' : 'no'}`)
v('owner_team', teamSenderAllowed(lane, m(TEAM, OWNER), acc))
v('stranger_team', teamSenderAllowed(lane, m(TEAM, STRANGER), acc))
v('owner_foreign', teamSenderAllowed(lane, m(FOREIGN, OWNER), acc))
v('stranger_foreign', teamSenderAllowed(lane, m(FOREIGN, STRANGER), acc))
v('no_lane_chat', teamSenderAllowed({ chatId: null }, m(TEAM, OWNER), acc))
v('no_access', teamSenderAllowed(lane, m(TEAM, OWNER), {}))
v('empty_lists', teamSenderAllowed(lane, m(TEAM, OWNER), { allowFrom: [], groups: { [String(TEAM)]: { allowFrom: [] } } }))
v('fallback_owner', teamSenderAllowed(lane, m(TEAM, OWNER), { allowFrom: ['433'], groups: { [String(TEAM)]: { allowFrom: [] } } }))
v('fallback_stranger', teamSenderAllowed(lane, m(TEAM, STRANGER), { allowFrom: ['433'], groups: { [String(TEAM)]: { allowFrom: [] } } }))
v('no_sender', teamSenderAllowed(lane, m(TEAM, undefined), acc))
v('string_chat', teamSenderAllowed(lane, { chat: { id: String(TEAM) }, from: { id: OWNER } }, acc))
TS
  "$BUN" run "$TMP/run.ts" 2>&1
}
got() { awk -v k="$1" '$1==k{print $2}' <<<"$OUT"; }

OUT=$(run_arms "$TMP/gate.ts")
echo "# (a)-(d) the gate"
[[ $(got owner_team) == ok ]] && ok_t "a1 the owner in the team group gets through" || bad_t "a1 owner refused" "$OUT"
[[ $(got stranger_team) == no ]] && ok_t "b1 a stranger in the team group is refused" || bad_t "b1 stranger passed" "$OUT"
[[ $(got owner_foreign) == no && $(got stranger_foreign) == no ]] \
  && ok_t "c1 a foreign supergroup with the same thread id is refused, even for the owner's id" || bad_t "c1 foreign group passed" "$OUT"
[[ $(got no_lane_chat) == no ]] && ok_t "d1 a lane with no registered team group refuses everyone" || bad_t "d1" "$OUT"
[[ $(got no_access) == no && $(got empty_lists) == no ]] && ok_t "d2 no allowFrom anywhere = nobody (fail closed)" || bad_t "d2" "$OUT"
[[ $(got fallback_owner) == ok && $(got fallback_stranger) == no ]] \
  && ok_t "d3 an empty group list falls back to the agent's own allowFrom, and only that" || bad_t "d3" "$OUT"
[[ $(got no_sender) == no && $(got string_chat) == no ]] && ok_t "d4 no sender id, or a non-numeric chat id, is refused" || bad_t "d4" "$OUT"

echo "# (e) the poll loop"
loop=$(sed -n '/^while (!shuttingDown) {/,/^}/p' "$L")
g=$(grep -n 'teamSenderAllowed(lane, msg' <<<"$loop" | head -1 | cut -d: -f1)
r=$(grep -n 'rateOk(agent, now)' <<<"$loop" | head -1 | cut -d: -f1)
d=$(grep -n '^    drop($' <<<"$loop" | head -1 | cut -d: -f1)
[[ -n "$g" && -n "$r" && -n "$d" && $g -lt $r && $g -lt $d ]] \
  && ok_t "e1 the loop runs the gate before the rate limit and the drop" || bad_t "e1 order" "gate=$g rate=$r drop=$d"
after_gate=$(grep -A3 'teamSenderAllowed(lane, msg' <<<"$loop")
grep -q 'continue' <<<"$after_gate" \
  && ok_t "e2 a refused message is skipped (continue), not delivered" || bad_t "e2" "no continue after the verdict"
sed -n "/^  cat > \/opt\/5dive\/team-bot-listener.ts <<'LISTENER_TS'$/,/^LISTENER_TS$/p" "$L" | sed '1d;$d' > "$TMP/listener.ts"
if "$BUN" build --target=bun --no-bundle "$TMP/listener.ts" > /dev/null 2> "$TMP/build.err"; then
  ok_t "e3 the embedded listener still transpiles"
else
  bad_t "e3 listener does not transpile" "$(head -5 "$TMP/build.err")"
fi

echo "# (f) MUTANT: the chat check removed"
sed 's/if (typeof chatId !== .number. || chatId !== lane.chatId) return.*$/\/\/ mutant: chat check removed/' "$TMP/gate.ts" > "$TMP/mutant.ts"
if cmp -s "$TMP/gate.ts" "$TMP/mutant.ts"; then
  bad_t "f1 mutant applied" "the chat-check line was not found; the mutant arm grades nothing"
else
  OUT=$(run_arms "$TMP/mutant.ts")
  [[ $(got owner_foreign) == ok ]] \
    && ok_t "f1 MUTANT: without the chat check the foreign group passes — c1 would be red, as it must" \
    || bad_t "f1 mutant not caught" "$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
