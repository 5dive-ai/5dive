#!/usr/bin/env bash
# DIVE-7615 — an Antigravity agent whose Google account fails Google's age check
# says so, instead of reading "Connected" and never answering.
#
# Live box arm 2026-11-03 (DIVE-7606, 5dive v0.116.1, agy 1.4.12): the Google
# sign-in reached ok, the hire ran, and agy answered every message with
# "Eligibility check failed: Your current account is not eligible for
# Antigravity. To use Antigravity you must be 18 years old or older…".
# `agent health` read auth=ok refusal=null and `agent ask` said "the composer
# still holds unsent text". tests/fixtures/dive7615-agy/eligibility.pane is that
# box's pane, byte for byte (12-agent-pane-after-ask1.txt); reply.pane is a real
# agy reply (DIVE-1901's frame3-complete.txt), the control.
#
#   H1  seat_turn_trouble (agent info, auth status, ask): refused + the plain words
#   H2  the agent list / health snapshot (python): auth refused + the plain words
#   A1  ask's unconfirmed path reads the refusal
#   A2  ask's refused receipt: reason is the plain words, refused:true, sent:false
#   A3  ask's timeout clause: the plain words, from the pane alone
#   A4  wiring: both unconfirmed ask sites consult the refusal first
#   C1  control: a normal agy reply is no refusal (shell, python, ask)
#   C2  control: the same words on a Claude seat's screen are not read
#   C3  control: a question QUOTING the words is not a refusal
#
# Offline: fixture panes through SEAT_PANE_DIR; no tmux, no sudo.
#   bash tests/agy_eligibility_refusal_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh 2>/dev/null || true
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh
# shellcheck disable=SC1091
source src/lib/seat_refusal.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

PLAIN="This Google account can't use Antigravity yet: Google needs to verify the account holder is 18+. Verify it at myaccount.google.com, or sign in with another account."
FIX=tests/fixtures/dive7615-agy
TMP=$(mktemp -d)
export SEAT_PANE_DIR="$TMP/panes" SEAT_TRANSCRIPT_ROOT="$TMP/transcripts" SEAT_STOP_STAMP_DIR="$TMP/stamps" \
       AGENT_HOME_ROOT="$TMP/home" ASK_REFUSAL_TRIES=1
mkdir -p "$SEAT_PANE_DIR" "$SEAT_TRANSCRIPT_ROOT/p" "$SEAT_STOP_STAMP_DIR" "$TMP/home/agent-qa7615agy" "$TMP/profiles" "$TMP/sudoers" "$TMP/connectors"
SEAT_TYPE=antigravity
agent_type() { printf '%s\n' "$SEAT_TYPE"; }
seat_started_epoch() { echo 0; }
pane() { cp "$1" "$SEAT_PANE_DIR/qa7615agy.pane"; }

PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/ { emit=1; next } /^# __5DIVE_AGENT_LIST_PY_END__$/ { exit } emit { print }' src/cmd_agent.sh > "$PY"
snap_agent() { # <type>
  printf '{"agents":{"qa7615agy":{"type":"%s","channels":"none","workdir":"/work","isolation":"admin","heartbeat":{"enabled":false},"createdAt":"2026-11-03T10:23:00Z"}}}\n' "$1" > "$TMP/agents.json"
  python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$TMP/home" "$TMP/sudoers" /default 2>/dev/null \
    | jq -r '.[0].health.auth | "\(.state)|\(.refusal)"'
}

echo '== the refused pane (the live box, byte for byte) =='
pane "$FIX/eligibility.pane"
eq_t "H1 seat_turn_trouble reads refused, in the owner's words" "refused	$PLAIN" "$(seat_turn_trouble qa7615agy 0)"
H2=$(snap_agent antigravity)
[[ "$H2" == "refused|$PLAIN" ]] && ok_t "H2 the health snapshot reads auth refused with the plain words" \
  || bad_t "H2 the health snapshot reads auth refused with the plain words" "got [$H2]"
eq_t "A1 ask's unconfirmed path reads the refusal" "$PLAIN" "$(_ask_unconfirmed_refusal qa7615agy 31b9b469)"
R=$(JSON_MODE=1 _agent_ask_refused qa7615agy ask 31b9b469 "$PLAIN")
eq_t "A2 the refused receipt carries the plain words as its reason" "$PLAIN|true|false" \
  "$(jq -r '"\(.data.reason)|\(.data.refused)|\(.data.sent)"' <<<"$R")"
P=$(JSON_MODE=0 _agent_ask_refused qa7615agy ask 31b9b469 "$PLAIN")
grep -qF "unsent text" <<<"$P" && bad_t "A2b the prose no longer blames the composer" "$P" || ok_t "A2b the prose no longer blames the composer"
D=$(_ask_timeout_diag 31b9b469 "$FIX/eligibility.pane" 0 0 "")
grep -qF "$PLAIN" <<<"$D" && ok_t "A3 the timeout clause says it in the owner's words, from the pane alone" \
  || bad_t "A3 the timeout clause says it in the owner's words, from the pane alone" "$D"
n=$(grep -c 'if _refused=$(_ask_unconfirmed_refusal "$name" "$msg_id")' src/cmd_agent_runtime.sh)
eq_t "A4 both unconfirmed ask sites (direct and scoped) consult the refusal first" 2 "$n"

echo '== controls =='
pane "$FIX/reply.pane"
seat_turn_trouble qa7615agy 0 >/dev/null; eq_t "C1 a normal agy reply: seat_turn_trouble reads nothing" 1 "$?"
eq_t "C1b ...the health snapshot's refusal stays null" null "$(snap_agent antigravity | cut -d'|' -f2)"
_ask_unconfirmed_refusal qa7615agy 5d7d77e6 >/dev/null; eq_t "C1c ...and ask keeps its unconfirmed receipt" 1 "$?"
D=$(_ask_timeout_diag 5d7d77e6 "$FIX/reply.pane" 0 0 "")
grep -qiF "refused" <<<"$D" && bad_t "C1d ...and the timeout clause names no refusal" "$D" || ok_t "C1d ...and the timeout clause names no refusal"

pane "$FIX/eligibility.pane"; SEAT_TYPE=claude
seat_turn_trouble qa7615agy 0 >/dev/null; eq_t "C2 a Claude seat with the same words on screen: not read" 1 "$?"
eq_t "C2b ...nor by the health snapshot" null "$(snap_agent claude | cut -d'|' -f2)"
SEAT_TYPE=antigravity

printf '%s\n' '> [5dive-msg from=ask id=aa11bb22 tier=standard] what does "Eligibility check failed: not eligible for Antigravity" mean?' \
  '' '  It means the Google account has not verified its age.' '' '>' > "$SEAT_PANE_DIR/qa7615agy.pane"
seat_turn_trouble qa7615agy 0 >/dev/null; eq_t "C3 a question quoting the words is not a refusal" 1 "$?"
eq_t "C3b ...nor in the health snapshot" null "$(snap_agent antigravity | cut -d'|' -f2)"

_syn=""; for f in src/cmd_agent.sh src/cmd_agent_runtime.sh src/lib/seat_refusal.sh; do bash -n "$f" 2>/dev/null || _syn+=" $f"; done
eq_t "S1 the touched files parse" "" "$_syn"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
