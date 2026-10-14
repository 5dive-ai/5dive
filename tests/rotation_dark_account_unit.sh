#!/usr/bin/env bash
# DIVE-6149: rotation could not see an account nobody is on. The destination
# fence read only fresh statusline caches of seats BOUND to an account, so an
# evacuated account stayed dark after its 5h window reset (mp, 2026-10-13: empty
# 03:00Z-06:22Z while nine walled seats piled onto mark), and every seat leaving
# a wall picked the same first destination. Arms, by the row's CHECK:
#   1  pool {A walled, B walled, C no bound seat, remembered 5h reset in the
#      past, 7d 60%}: a walled seat on A rotates to C. NEGATIVE CONTROL:
#      DARK_MUTANT=1 drops the remembered-reading branch and this arm goes red.
#   2  4 walled seats in one tick, B and C both clear: not all 4 land on one
#      account. NEGATIVE CONTROL: SPREAD_MUTANT=1 drops the spread; red.
#   3  keep: a fresh reading at the wall beats any remembered proof; a
#      remembered reading that proves nothing (5h reset ahead, 7d at the bar,
#      reset unknown) admits nothing.
#   4  balance on, live probe down: the dark account still ranks, on its
#      remembered proof.
#      TRUST_MUTANT=1 puts back the untrusted readers (a moved seat's old 100%
#      cache walls its new account); arm 2 goes red.
#   5  the supervisor's wall move arms the launcher's resume marker (WANT 4),
#      and drops it when no move happens.
#   6  DIVE-6210: the 2026-10-14 04:4x replay — a destination whose fresh cache
#      has 7d and no 5h is probed live and taken; probe down or at the wall
#      admits nothing. NEGATIVE CONTROL: PROBE_MUTANT=1; red.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rotation-dark.XXXXXX")
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

source src/lib/error_codes.sh
source src/lib/output.sh
source src/header.sh
source src/lib/actor.sh
ACCT_SRC=$(cat src/cmd_account.sh)
if [[ "${DARK_MUTANT:-0}" == 1 ]]; then
  # The mutation: the candidate fence is the pre-fix one (fresh measurement only).
  ACCT_SRC=$(sed 's/&& { account_remembered_room "$cand" || /\&\& { false || /' <<<"$ACCT_SRC")
  grep -q '&& { false || account_probed_headroom' <<<"$ACCT_SRC" || { echo "MUTANT DID NOT APPLY" >&2; exit 3; }
  echo "MUTANT: remembered-reading branch removed from rotation_live_headroom_candidates"
fi
if [[ "${PROBE_MUTANT:-0}" == 1 ]]; then
  ACCT_SRC=$(sed 's/ || account_probed_headroom "$cand"; }; }; then$/; }; }; then/' <<<"$ACCT_SRC")
  grep -q 'account_remembered_room "$cand"; }; }; then$' <<<"$ACCT_SRC" || { echo "MUTANT DID NOT APPLY" >&2; exit 3; }
  echo "MUTANT: live-probe branch removed from rotation_live_headroom_candidates (pre-DIVE-6210)"
fi
if [[ "${SPREAD_MUTANT:-0}" == 1 ]]; then
  ACCT_SRC=$(sed 's/^      candidates=$(rotation_spread_candidates "$reg" "$candidates")$/      :/' <<<"$ACCT_SRC")
  grep -q '^      :$' <<<"$ACCT_SRC" || { echo "MUTANT DID NOT APPLY" >&2; exit 3; }
  echo "MUTANT: stampede spread removed from cmd_agent_rotation_rotate"
fi
if [[ "${TRUST_MUTANT:-0}" == 1 ]]; then
  # The pre-fix readers: any bound seat's cache, including one rendered on the
  # account the seat just LEFT.
  ACCT_SRC=$(sed -e '/^account_has_live_headroom() {/,/^}/ s/account_trusted_ratelimits/account_best_ratelimits/' \
                 -e '/^account_near_wall_state() {/,/^}/ s/account_trusted_ratelimits/account_best_ratelimits/' <<<"$ACCT_SRC")
  echo "MUTANT: headroom readers take the untrusted freshest cache"
fi
source <(printf '%s\n' "$ACCT_SRC")
source src/cmd_supervisor.sh
set +e

PASS=0; FAIL=0
t() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; else
    FAIL=$((FAIL+1)); printf 'FAIL %s — expected %s, got %s\n' "$1" "$2" "$3" >&2
  fi
}

# Boundaries this harness does not own: root, the registry FILE (real reads and
# writes, so each move is seen by the next seat), cmd_config's bounce, and where
# seat homes and account records live. The headroom READERS are real.
REG="$TMP/agents.json"
AUTH_PROFILES_DIR="$TMP/profiles"
HOMES="$TMP/home"
require_root()   { :; }
ensure_state()   { :; }
ensure_state_ro(){ :; }
registry_read()  { cat "$REG"; }
registry_write() { cat >"$REG.tmp" && mv "$REG.tmp" "$REG"; }
cmd_config() {   # <name> set auth-profile=<target> — and the binding event's time
  local n="$1" v="${3#auth-profile=}"
  registry_read | jq --arg n "$n" --arg v "$v" '.agents[$n].authProfile = $v' | registry_write
  mkdir -p "$TMP/bind"; date +%s >"$TMP/bind/$n"
}
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
usage_agent_home() { printf '%s/agent-%s\n' "$HOMES" "$1"; }
account_binding_since() { cat "$TMP/bind/$1" 2>/dev/null; }
_ROTATION_PROBE_CMD=false     # the live probe is down: no network in a harness
_SUP_RESUME_HOME_ROOT="$HOMES"

NOW=$(date +%s)
PAST=$((NOW - 3600)); AHEAD=$((NOW + 86400)); RESET=$((NOW + 6420))

# cache <seat> <5h%> <5h reset> <7d%> <7d reset> [age-secs] — a seat's statusline.
cache() {
  local d="$HOMES/agent-$1/.claude"
  mkdir -p "$d"
  jq -cn --argjson f "$2" --argjson fr "$3" --argjson s "$4" --argjson sr "$5" \
    '{rate_limits:{five_hour:{used_percentage:$f, resets_at:$fr}, seven_day:{used_percentage:$s, resets_at:$sr}}}' \
    >"$d/statusline-last.json"
  touch -d "@$((NOW - ${6:-0}))" "$d/statusline-last.json"
}
# remember <account> <5h%> <5h reset> <7d%> <7d reset> <asOf> — usage.json.
remember() {
  mkdir -p "$AUTH_PROFILES_DIR/$1"
  jq -cn --argjson f "$2" --argjson fr "$3" --argjson s "$4" --argjson sr "$5" --argjson at "$6" \
    '{fiveHour:{pct:$f, resetsAt:$fr}, sevenDay:{pct:$s, resetsAt:$sr}, asOf:$at, source:"pub", remembered:false}' \
    >"$AUTH_PROFILES_DIR/$1/usage.json"
}
fresh_fixture() { rm -rf "$HOMES" "$AUTH_PROFILES_DIR" "$TMP/bind"; mkdir -p "$HOMES" "$AUTH_PROFILES_DIR"; }
# seed <json-of-seats> — registry; every rotating seat pools A B C in that order.
seed() {
  jq -cn --argjson s "$1" '{agents: ($s | with_entries(.value = ({type:"claude", channels:"none",
      rotation:{enabled:true, accounts:["A","B","C"], cooldowns:{}}} * .value)))}' >"$REG"
}
wall() ( JSON_MODE=1 cmd_agent_rotation_rotate "$1" "--wall=$RESET" 2>/dev/null )
bound() { jq -r --arg n "$1" '.agents[$n].authProfile' "$REG"; }
J() { jq -r "$2" <<<"$1" 2>/dev/null; }

# ── 1: the dark account with remembered room is a destination ───────────────
# A and B are walled and measured so by bound seats; C has nobody on it and its
# last reading (taken 4h ago, before its 5h reset) says 100% 5h / 60% 7d.
fresh_fixture
cache walla 100 "$RESET" 70 "$AHEAD"
cache wallb 100 "$RESET" 40 "$AHEAD"
remember C 100 "$PAST" 60 "$AHEAD" $((NOW - 14400))
seed '{"seat1":{"authProfile":"A"}, "walla":{"authProfile":"A"}, "wallb":{"authProfile":"B"}}'
OUT=$(wall seat1)
t "1 a walled seat on A rotates" "true" "$(J "$OUT" '.data.rotated')"
t "1 it lands on C, the account nobody is on" "C" "$(bound seat1)"
t "1 B, measured at its wall, is not the target" "true" "$(J "$OUT" '.data.to != "B"')"

# ── 2: four walled seats in one tick spread ─────────────────────────────────
# B is clear (a bound seat measured 10% a minute ago), C is dark with
# remembered room. Each move re-points the registry, as under the lock. Each
# walled seat carries the 100% cache it rendered on A (rendered 30s ago, before
# its move): on its new account that cache must not read as a wall.
fresh_fixture
cache walla 100 "$RESET" 70 "$AHEAD"
for s in s1 s2 s3 s4; do cache "$s" 100 "$RESET" 70 "$AHEAD" 30; done
cache onb 10 "$RESET" 20 "$AHEAD" 60
remember C 90 "$PAST" 30 "$AHEAD" $((NOW - 14400))
seed '{"s1":{"authProfile":"A"}, "s2":{"authProfile":"A"}, "s3":{"authProfile":"A"},
       "s4":{"authProfile":"A"}, "walla":{"authProfile":"A"}, "onb":{"authProfile":"B"}}'
for s in s1 s2 s3 s4; do wall "$s" >/dev/null; done
DIST=$(jq -c '[.agents | to_entries[] | select(.key | test("^s[0-9]$")) | .value.authProfile] | group_by(.) | map({(.[0]): length}) | add' "$REG")
echo "   distribution: $DIST"
t "2 every walled seat moved off A" "0" "$(jq -r '.A // 0' <<<"$DIST")"
t "2 not all four on one account" "true" "$(jq -r '(.B // 0) < 4 and (.C // 0) < 4' <<<"$DIST")"
t "2 seats bound end even (B 1+2, C 2)" "2:2" "$(jq -r '"\(.B // 0):\(.C // 0)"' <<<"$DIST")"

# ── 3: keep — a fresh wall beats a remembered proof; no proof admits nothing ──
fresh_fixture
cache walla 100 "$RESET" 70 "$AHEAD"
cache onc 95 "$RESET" 60 "$AHEAD" 30           # fresh, at the wall
remember C 100 "$PAST" 60 "$AHEAD" $((NOW - 14400))
seed '{"seat1":{"authProfile":"A"}, "walla":{"authProfile":"A"}, "onc":{"authProfile":"C"}}'
OUT=$(wall seat1)
t "3 a fresh at-wall reading beats the remembered proof" "false:A" "$(J "$OUT" '.data.rotated'):$(bound seat1)"
check_room() { account_remembered_room C && echo yes || echo no; }
fresh_fixture
remember C 100 "$AHEAD" 10 "$AHEAD" $((NOW - 600));  t "3 5h reset still ahead: no proof" "no" "$(check_room)"
remember C 100 "$PAST" 92 "$AHEAD" $((NOW - 600));   t "3 7d at the bar, reset ahead: no proof" "no" "$(check_room)"
remember C 100 "$PAST" 99 "$PAST" $((NOW - 600));    t "3 both windows reset: proof" "yes" "$(check_room)"
mkdir -p "$AUTH_PROFILES_DIR/C"
echo '{"fiveHour":{"pct":0,"resetsAt":null},"sevenDay":{"pct":10,"resetsAt":null},"asOf":1}' >"$AUTH_PROFILES_DIR/C/usage.json"
t "3 resets unknown: no proof" "no" "$(check_room)"
rm -f "$AUTH_PROFILES_DIR/C/usage.json";             t "3 never read: no proof" "no" "$(check_room)"
# A stale bound-seat cache is a remembered reading too, and the newest wins:
cache onc 100 "$PAST" 50 "$AHEAD" 7200
remember C 100 "$AHEAD" 50 "$AHEAD" $((NOW - 14400))
seed '{"onc":{"authProfile":"C"}}'
t "3 a stale seat cache newer than the record proves room" "yes" "$(check_room)"

# ── 4: balance on, probe down — the dark account still ranks ────────────────
fresh_fixture
cache walla 100 "$RESET" 70 "$AHEAD"
cache onb 50 "$RESET" 80 "$AHEAD" 60
remember C 100 "$PAST" 30 "$AHEAD" $((NOW - 14400))
seed '{"seat1":{"authProfile":"A", "rotation":{"balance":true}}, "walla":{"authProfile":"A"}, "onb":{"authProfile":"B"}}'
OUT=$(wall seat1)
t "4 balance: the dark account (5h ~0, 7d 30) wins over B (5h 50, 7d 80)" "C" "$(bound seat1)"
t "4 balance: its derived reading says 5h 0, remembered" "0:true" \
  "$(J "$(account_balance_reading C)" '"\(.fiveHourPct):\(.remembered)"')"

# ── 5: the supervisor's wall move resumes the walled turn ───────────────────
SID=0b6f1c2e-1111-4a2b-9c3d-123456789abc
transcript() {
  mkdir -p "$HOMES/agent-$1/.claude/projects/-home-x" "$HOMES/agent-$1/.claude/projects/-home-x/$SID/subagents"
  : >"$HOMES/agent-$1/.claude/projects/-home-x/$SID.jsonl"
  touch -d "@$((NOW - 60))" "$HOMES/agent-$1/.claude/projects/-home-x/$SID.jsonl"
  : >"$HOMES/agent-$1/.claude/projects/-home-x/$SID/subagents/agent-a1.jsonl"   # newer, not a session
}
MK() { printf '%s/agent-%s/.claude/channels/telegram/resume-next' "$HOMES" "$1"; }
fresh_fixture
cache walla 100 "$RESET" 70 "$AHEAD"
remember C 100 "$PAST" 60 "$AHEAD" $((NOW - 14400))
transcript chat
mkdir -p "$HOMES/agent-chat/.claude/channels/telegram"
echo '{"lastInboundAt":200,"lastReplyAt":100}' >"$HOMES/agent-chat/.claude/channels/telegram/silence.json"
seed '{"chat":{"authProfile":"A"}, "walla":{"authProfile":"A"}}'
_sup_quota_rotate chat; rc=$?
t "5 the supervisor rotate moves the walled seat" "0:C" "$rc:$(bound chat)"
t "5 it armed the resume marker with the session id" "$SID" "$(sed -n 1p "$(MK chat)" 2>/dev/null)"
t "5 an unanswered inbound: the first prompt replies to it" "continue and reply to the latest message" "$(sed -n 2p "$(MK chat)" 2>/dev/null)"
t "5 the marker is the seat's, mode 600" "600" "$(stat -c %a "$(MK chat)" 2>/dev/null)"
# no unanswered inbound -> bare continue
rm -f "$(MK chat)"
echo '{"lastInboundAt":100,"lastReplyAt":200}' >"$HOMES/agent-chat/.claude/channels/telegram/silence.json"
seed '{"chat":{"authProfile":"A"}, "walla":{"authProfile":"A"}}'
_sup_quota_rotate chat
t "5 nothing unanswered: a bare continue" "continue" "$(sed -n 2p "$(MK chat)" 2>/dev/null)"
# no move -> the marker it armed is dropped
rm -f "$(MK chat)" "$AUTH_PROFILES_DIR/C/usage.json"
seed '{"chat":{"authProfile":"A"}, "walla":{"authProfile":"A"}}'
_sup_quota_rotate chat; rc=$?
t "5 no destination: no move" "1:A" "$rc:$(bound chat)"
t "5 no move: no marker left behind" "absent" "$([[ -e "$(MK chat)" ]] && echo present || echo absent)"
# a marker the seat's own plugin armed is left alone
printf 'ffffffff-ffff-ffff-ffff-ffffffffffff\ncontinue\n' >"$(MK chat)"
_sup_quota_rotate chat
t "5 a plugin-armed marker is never overwritten or removed" "ffffffff-ffff-ffff-ffff-ffffffffffff" "$(sed -n 1p "$(MK chat)" 2>/dev/null)"
# a non-claude seat gets no marker
rm -f "$(MK chat)"
seed '{"chat":{"authProfile":"A", "type":"codex"}}'
t "5 a codex seat: nothing armed" "" "$(_sup_arm_wall_resume chat)"

# ── 6: DIVE-6210 — a destination whose fresh cache has 7d and NO 5h ─────────
# Replay of 2026-10-14 04:43-04:53Z: mark (A) walled, its seats measured at 100%
# 5h; mp-team (B) had seats on it whose freshest cache (ads, 04:42:27Z) carried
# seven_day 69% and no five_hour block, the rest null or 40 minutes old;
# chemmonitor (C) dark, remembered at 100% 7d. The heartbeat's call is
# --if-current-near-wall --require-live-headroom. Pre-fix: "no eligible
# account", and lodar moved the seats by hand. NEGATIVE CONTROL: PROBE_MUTANT=1
# drops the probe branch and the move arms go red.
cache7() {   # <seat> <7d%> <7d reset> <age> — the shape ads rendered: no five_hour
  local d="$HOMES/agent-$1/.claude"; mkdir -p "$d"
  jq -cn --argjson s "$2" --argjson sr "$3" '{rate_limits:{seven_day:{used_percentage:$s, resets_at:$sr}}}' \
    >"$d/statusline-last.json"
  touch -d "@$((NOW - $4))" "$d/statusline-last.json"
}
PROBES="$TMP/probes"
probe_up() {   # the provider's answer, per account; every call is counted
  echo "$1" >>"$PROBES"
  case "$1" in
    A) printf 'HTTP/2 429\r\nanthropic-ratelimit-unified-5h-utilization: 1.0\r\nanthropic-ratelimit-unified-7d-utilization: 0.34\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n' "$RESET" "$AHEAD" ;;
    B) printf 'HTTP/2 200\r\nanthropic-ratelimit-unified-5h-utilization: %s\r\nanthropic-ratelimit-unified-7d-utilization: 0.69\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n' "${B5H:-0.12}" "$RESET" "$AHEAD" ;;
    C) printf 'HTTP/2 429\r\nanthropic-ratelimit-unified-5h-utilization: 0.0\r\nanthropic-ratelimit-unified-7d-utilization: 1.0\r\nanthropic-ratelimit-unified-5h-reset: %s\r\nanthropic-ratelimit-unified-7d-reset: %s\r\n' "$RESET" "$AHEAD" ;;
  esac
}
replay_0443() {
  fresh_fixture; : >"$PROBES"; mkdir -p "$AUTH_PROFILES_DIR"/{A,B,C}   # every real profile has its dir
  for s in seat1 seat2 seat3 seat4; do cache "$s" 100 "$RESET" 34 "$AHEAD" 120; done
  cache7 ads 69 "$AHEAD" 60
  cache7 marketing 68 "$AHEAD" 2600
  mkdir -p "$HOMES/agent-creative/.claude"; echo '{"rate_limits":null}' >"$HOMES/agent-creative/.claude/statusline-last.json"
  remember C 0 "$PAST" 100 "$AHEAD" $((NOW - 20000))
  seed '{"seat1":{"authProfile":"A"}, "seat2":{"authProfile":"A"}, "seat3":{"authProfile":"A"},
         "seat4":{"authProfile":"A"}, "ads":{"authProfile":"B"}, "marketing":{"authProfile":"B"},
         "creative":{"authProfile":"B"}}'
}
boundary() ( JSON_MODE=1 cmd_agent_rotation_rotate "$1" --if-current-near-wall --require-live-headroom 2>/dev/null )

replay_0443
t "6 the replayed snapshot: B reads 7d-only, so it is unmeasured" "unmeasured" "$(account_near_wall_state B)"
_ROTATION_PROBE_CMD=probe_up
OUT=$(boundary seat1)
t "6 a walled seat at its boundary rotates" "true" "$(J "$OUT" '.data.rotated')"
t "6 it lands on mp-team (B), which the probe says has 5h room" "B" "$(bound seat1)"
t "6 the probe reading is remembered on B (source=probe)" "probe:12" \
  "$(jq -r '"\(.source):\(.fiveHour.pct)"' "$AUTH_PROFILES_DIR/B/usage.json" 2>/dev/null)"
for s in seat2 seat3 seat4; do boundary "$s" >/dev/null; done
t "6 every walled seat left A" "B,B,B,B" \
  "$(jq -r '[.agents.seat1, .agents.seat2, .agents.seat3, .agents.seat4 | .authProfile] | join(",")' "$REG")"
t "6 B was probed once; the next three read the remembered probe" "1" "$(grep -c '^B$' "$PROBES")"
t "6 C (7d at 100%) is probed and never a destination" "true" "$(grep -q '^C$' "$PROBES" && echo true)"
t "6 A, the account being left, is never probed" "0" "$(grep -c '^A$' "$PROBES")"

# keep: no answer is no verdict, and a probe at the wall admits nothing
replay_0443; _ROTATION_PROBE_CMD=false
OUT=$(boundary seat1)
t "6 probe down: unmeasured stays no destination (never 0%)" "false:A" "$(J "$OUT" '.data.rotated'):$(bound seat1)"
replay_0443; _ROTATION_PROBE_CMD=probe_up; B5H=0.95
OUT=$(boundary seat1)
t "6 the probe says B is at its 5h wall: no move" "false:A" "$(J "$OUT" '.data.rotated'):$(bound seat1)"
unset B5H
# keep: a fresh numeric 5h reading decides without a probe
replay_0443; _ROTATION_PROBE_CMD=probe_up
cache ads 10 "$RESET" 69 "$AHEAD" 60
boundary seat1 >/dev/null
t "6 B measured fresh at 10% 5h: moves with no probe of B" "B:0" "$(bound seat1):$(grep -c '^B$' "$PROBES")"
_ROTATION_PROBE_CMD=false

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
