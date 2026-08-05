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
a2a_needs_scoped()           { return 1; }
sudo()                       { return 0; }
wait_agent_input_ready()     { return 0; }
mirror_interagent_outbound() { :; }
envelope_tier()              { printf 'standard\n'; }
envelope_via()               { :; }
inject_and_submit()          { return "${INJECT_RC:-0}"; }
export SUDO_USER=agent-maker

run_send_json() {
  JSON_MODE=1 INJECT_RC="$1" cmd_send ada ping --raw
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
out=$(run_send_json 0)
is 'T8 confirmed send remains sent:true' true "$(jq -r '.data.sent' <<<"$out")"
is 'T9 confirmed send omits reason' false "$(jq -r '.data | has("reason")' <<<"$out")"
out=$(run_deliver_json 0)
is 'T10 confirmed scoped delivery remains delivered:true' true "$(jq -r '.data.delivered' <<<"$out")"
is 'T11 confirmed scoped delivery omits reason' false "$(jq -r '.data | has("reason")' <<<"$out")"

printf 'agent_send_unconfirmed_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
