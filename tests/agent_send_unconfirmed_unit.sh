#!/usr/bin/env bash
# DIVE-2362 — a submit race must not end in a positive machine receipt.
#
# inject_and_submit rc=1 means the text was typed but the pane still looked
# idle after every Enter retry. The payload may have landed, so this is not a
# hard command failure; it is also not evidence for sent:true/delivered:true.
# Exercise the real cmd_send and cmd_deliver functions with only tmux, registry,
# and identity boundaries stubbed. Both JSON and the final prose line are part
# of the contract because callers automate the former and people trust the
# latter.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    ok_t "$label"
  else
    bad_t "$label" "want=[$want] got=[$got]"
  fi
}

# External boundaries only. The two command functions and output renderer stay
# real, so mutating either receipt boolean or the prose summary makes this red.
require_root()               { :; }
require_agent()              { :; }
a2a_needs_scoped()           { [[ "${USE_SCOPED:-0}" == 1 ]]; }
sudo() {
  if [[ "$*" == *"--json agent _deliver"* ]]; then
    if [[ "${INJECT_RC:-0}" == 1 ]]; then
      printf '%s\n' '{"ok":true,"data":{"delivered":false,"reason":"pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)"}}'
    else
      printf '%s\n' '{"ok":true,"data":{"delivered":true}}'
    fi
  fi
  return 0
}
wait_agent_input_ready()     { return 0; }
mirror_interagent_outbound() { :; }
envelope_tier()              { printf 'standard\n'; }
envelope_via()               { :; }
inject_and_submit() {
  [[ "${SET_READY:-0}" == 1 ]] && AGENT_WAKE_READY=proven
  return "${INJECT_RC:-0}"
}
auto_sender_from_sudo()      { printf 'maker\n'; }
_envelope_caller()           { printf 'maker\n'; }
gen_msg_id()                 { printf 'feed2362\n'; }
export SUDO_USER=agent-maker

run_send_json() {
  JSON_MODE=1 INJECT_RC="$1" cmd_send ada ping --raw
}
run_send_confirmed_json() {
  JSON_MODE=1 INJECT_RC=0 SET_READY=1 cmd_send ada ping --from=maker --reply-to-chat=123 --reply-to-msg=1
}
run_deliver_json() {
  JSON_MODE=1 INJECT_RC="$1" cmd_deliver ada ping
}
run_send_text() {
  JSON_MODE=0 INJECT_RC="$1" cmd_send ada ping --raw
}
run_deliver_text() {
  JSON_MODE=0 INJECT_RC="$1" cmd_deliver ada ping
}
run_ask_json() {
  JSON_MODE=1 INJECT_RC="$1" USE_SCOPED="$2" cmd_ask ada ping --from=maker --timeout=1 --poll-secs=1
}
run_ask_text() {
  JSON_MODE=0 INJECT_RC="$1" USE_SCOPED="$2" cmd_ask ada ping --from=maker --timeout=1 --poll-secs=1
}

out=$(run_send_json 1)
is 'T1 send rc=1 keeps the envelope usable' true "$(jq -r '.ok' <<<"$out")"
is 'T2 send rc=1 reports sent:false' false "$(jq -r '.data.sent' <<<"$out")"
is 'T3 send rc=1 carries the shared reason' \
  'pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)' \
  "$(jq -r '.data.reason' <<<"$out")"

out=$(run_deliver_json 1)
is 'T4 scoped delivery rc=1 reports delivered:false' false "$(jq -r '.data.delivered' <<<"$out")"
is 'T5 scoped delivery rc=1 carries the same reason' \
  'pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)' \
  "$(jq -r '.data.reason' <<<"$out")"

out=$(run_send_text 1)
if [[ "$out" == *"OK — send to agent 'ada' is unconfirmed"* ]]; then
  ok_t 'T6 send rc=1 final prose carries the doubt'
else
  bad_t 'T6 send rc=1 final prose still looks successful' "$out"
fi
out=$(run_deliver_text 1)
if [[ "$out" == *"OK — delivery to agent 'ada' is unconfirmed"* ]]; then
  ok_t 'T7 scoped delivery rc=1 final prose carries the doubt'
else
  bad_t 'T7 scoped delivery rc=1 final prose still looks successful' "$out"
fi

# Positive controls: a confirmed submit keeps the existing public contract and
# does not grow a misleading empty reason field.
out=$(run_send_confirmed_json)
is 'T8 confirmed send remains sent:true' true "$(jq -r '.data.sent' <<<"$out")"
is 'T9 confirmed send omits reason' false "$(jq -r '.data | has("reason")' <<<"$out")"
out=$(run_deliver_json 0)
is 'T10 confirmed scoped delivery remains delivered:true' true "$(jq -r '.data.delivered' <<<"$out")"
is 'T11 confirmed scoped delivery omits reason' false "$(jq -r '.data | has("reason")' <<<"$out")"

# Ask has two dispatch paths. A direct caller invokes inject_and_submit here;
# a standard/scoped caller receives _deliver's non-fatal delivered:false JSON.
# Both must stop before reply polling and surface the same receipt.
out=$(run_ask_json 1 0)
is 'T12 direct ask rc=1 reports sent:false' false "$(jq -r '.data.sent' <<<"$out")"
is 'T13 direct ask rc=1 carries the shared reason' \
  'pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)' \
  "$(jq -r '.data.reason' <<<"$out")"
out=$(run_ask_json 1 1)
is 'T14 scoped ask propagates _deliver sent:false' false "$(jq -r '.data.sent' <<<"$out")"
is 'T15 scoped ask carries the shared reason' \
  'pane still shows an unsent paste buffer after retries (large-paste submit race, DIVE-147)' \
  "$(jq -r '.data.reason' <<<"$out")"
out=$(run_ask_text 1 0)
if [[ "$out" == *"OK — question to agent 'ada' is unconfirmed"* ]]; then
  ok_t 'T16 direct ask rc=1 final prose carries the doubt'
else
  bad_t 'T16 direct ask rc=1 final prose still looks successful' "$out"
fi
out=$(run_ask_text 1 1)
if [[ "$out" == *"OK — question to agent 'ada' is unconfirmed"* ]]; then
  ok_t 'T17 scoped ask rc=1 final prose carries the doubt'
else
  bad_t 'T17 scoped ask rc=1 final prose still looks successful' "$out"
fi

# Approval condition: the rc=0 renderer itself stays the old expression. This
# is intentionally source-level because the promise is byte compatibility, not
# merely an equivalent boolean after a jq rewrite.
SRC=src/cmd_agent_runtime.sh
if grep -Fq "'{name:\$n, sent:true, bytes:(\$p|length), woken:(\$w==\"1\"), ready:(\$rd|select(length>0)), from:(\$s|select(length>0)), msg_id:(\$i|select(length>0)), reply_to_chat:(\$rc|select(length>0)), reply_to_msg:(\$rm|select(length>0))}'" "$SRC"; then
  ok_t 'T18 confirmed send keeps the pre-DIVE-2362 renderer byte-for-byte'
else
  bad_t 'T18 confirmed send renderer changed' 'rc=0 must stay on the original expression'
fi
if grep -Fq "'{name:\$n, delivered:true, from:\$s, tier:(\$t|select(length>0))}'" "$SRC"; then
  ok_t 'T19 confirmed scoped delivery keeps the pre-DIVE-2362 renderer byte-for-byte'
else
  bad_t 'T19 confirmed scoped delivery renderer changed' 'rc=0 must stay on the original expression'
fi

printf 'agent_send_unconfirmed_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
