#!/usr/bin/env bash
# TIER: core
#
# DIVE-9373 — `agent send` / `_deliver` must not exit 12 "typed but NOT
# submitted" when the target seat's transcript shows the message landed.
#
# Measured 2026-11-26 on a box: `agent send <qa-seat>` exited 12 at 03:18:06Z
# while the seat's transcript opened with that exact message at 03:18:05.290Z
# and the run went ahead. An exit-code caller (ship-watch.sh) re-sends, so the
# seat runs the job twice. The only witness was the PANE (the composer still
# showed text after two Enters); the transcript was never asked.
#
# What runs REAL here: cmd_send, cmd_deliver, inject_and_submit,
# _agent_send_landed, and the heartbeat's _hb_landed_mark / _hb_landed_check /
# _hb_landed_needle / _hb_transcript_newest. What is faked: tmux (sudo is a
# function), the pane readers (the composer ALWAYS reads unsent — the false
# negative under test), and a transcript store under $TMP that the fake Enter
# appends to, per arm.
#
#   L arms — the transcript proves the landing: exit 0, sent:true / delivered:true
#   N arms — negative controls: exit 12, sent:false, the DIVE-4246 reason, as today
#   M arm  — the pre-fix tree (inject_and_submit from origin/main f1aa1c57,
#            carried verbatim minus comments) on the L1 input: exit 12. Shows
#            the L arms are red without this change.
#
# Reserved-fake values only: seat 'seatx' does not exist; no live pane or
# transcript is touched.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/send-landed.XXXXXX)
A2A_ROUND_LEDGER="$TMP/ledger"; export A2A_ROUND_LEDGER
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "src/$f"
done
set +e
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { if [[ "$3" == "$2" ]]; then ok_t "$1"; else bad_t "$1" "want=[$2] got=[$3]"; fi; }

REASON='the composer still holds unsent text after two Enters — the payload was typed but the submit could not be verified (DIVE-4246; was the DIVE-147 paste-placeholder poll)'
PAYLOAD='DAILY-REPORT trigger 9373: run the nightly QA sweep over every seat and post the summary'

# ---- the fake transcript store ------------------------------------------------
ROOT="$TMP/projects"; PROJ="$ROOT/-home-seatx"
_HB_TRANSCRIPT_ROOT="$ROOT"; _HB_LANDED_WAIT_SEC=0; _HB_LANDED_POLL_SEC=0; _AGENT_SEND_LANDED_SEC=0
OLD="$PROJ/aaaa-old.jsonl"; NEW="$PROJ/bbbb-new.jsonl"
rec_user()   { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
rec_tool()   { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_1",content:$t}]}}'; }
rec_asst()   { jq -cn '{type:"assistant",message:{role:"assistant",content:"working"}}'; }
rec_clear()  { jq -cn '{type:"user",message:{role:"user",content:"<command-name>/clear</command-name>"}}'; }
rec_meta()   { jq -cn --arg t "$1" '{type:"user",isMeta:true,message:{role:"user",content:$t}}'; }
reset_store() {
  rm -rf "$ROOT"; mkdir -p "$PROJ"
  { rec_user 'an earlier, unrelated turn'; rec_asst; } >"$OLD"
  touch -d '-1 hour' "$OLD"
}
# LAND: what the first Enter does to the store.
#   same      — appends a user record carrying the payload to the SAME file
#   tool      — appends only a tool_result that quotes the payload (+ noise)
#   nothing   — appends nothing
#   noise     — appends records, none carrying the payload
#   rotate    — a new session file whose first record is something else
#   rotate-in — a new session file opened BY the payload (meta + payload)
#   clear-in  — a new session file: /clear, then the payload
#   rotate-late — a new file that opens with another message; payload second
land() {
  local PAYLOAD; PAYLOAD=$(cat "$TYPED")
  case "${LAND:-nothing}" in
    same)      rec_user "$PAYLOAD" >>"$OLD" ;;
    tool)      { rec_asst; rec_tool "grep hit: $PAYLOAD"; } >>"$OLD" ;;
    nothing)   : ;;
    noise)     { rec_asst; rec_tool 'ls output'; } >>"$OLD" ;;
    rotate)    rec_user 'a restart resumed something else' >"$NEW" ;;
    rotate-in) { rec_meta 'Caveat: local command output'; rec_user "$PAYLOAD"; } >"$NEW" ;;
    clear-in)  { rec_clear; rec_user "$PAYLOAD"; } >"$NEW" ;;
    rotate-late) { rec_user 'another sender got there first'; rec_asst; rec_user "$PAYLOAD"; } >"$NEW" ;;
  esac
  [[ -f "$NEW" ]] && touch "$NEW"
}

# ---- boundaries ---------------------------------------------------------------
ENTERS="$TMP/enters"; TYPED="$TMP/typed"
sudo() {
  # strip `-n` / `-u <user>`; run store reads for real, fake every tmux call.
  while [[ "${1:-}" == -* ]]; do
    case "$1" in -u) shift 2 ;; *) shift ;; esac
  done
  if [[ "${1:-}" == tmux ]]; then
    # what was really typed (cmd_deliver frames the message): the fake seat
    # records THAT, the way Claude Code would.
    [[ "${*: -2:1}" == -- ]] && printf '%s' "${*: -1}" >>"$TYPED"
    if [[ "$*" == *" Enter" ]]; then
      local n; n=$(( $(cat "$ENTERS" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$ENTERS"
      (( n == 1 )) && land
    fi
    return 0
  fi
  "$@"
}
require_root()               { :; }
require_agent()              { :; }
a2a_needs_scoped()           { return 1; }
wait_agent_input_ready()     { return 0; }
mirror_interagent_outbound() { :; }
envelope_tier()              { printf 'standard\n'; }
envelope_via()               { :; }
envelope_provenance()        { printf 'unclaimed\n'; }
actor_routing_agent()        { return 1; }
auto_sender_from_sudo()      { printf 'maker\n'; }
_envelope_caller()           { printf 'maker\n'; }
gen_msg_id()                 { printf 'feed9373\n'; }
_a2a_queue_depth()           { printf '0\n'; }
_agent_delivery_inbox()      { return 1; }
_a2a_should_queue()          { return 1; }
_agent_pane_safe_to_type()   { return 0; }
_hb_claude_pid()             { printf '4242\n'; }
_hb_composer_scrub()         { return 0; }
# The false negative under test: the composer ALWAYS reads as holding the text.
_hb_submit_settled()         { _HB_COMPOSER_UNSENT="$PAYLOAD"; return 1; }
CLEARED="$TMP/cleared"
_hb_composer_clear()         { echo 1 >"$CLEARED"; return 0; }
export SUDO_USER=agent-maker

# run <site> <LAND> — prints "<rc>\t<json>"
run() {
  local site="$1" out rc=0
  reset_store; rm -f "$NEW" "$ENTERS" "$CLEARED" "$TYPED"; _wedge_clear seatx
  if [[ "$site" == send ]]; then
    out=$(LAND="$2" JSON_MODE=1 cmd_send seatx "$PAYLOAD" --raw 2>"$TMP/err") || rc=$?
  else
    out=$(LAND="$2" JSON_MODE=1 cmd_deliver seatx "$PAYLOAD" 2>"$TMP/err") || rc=$?
  fi
  printf '%s\t%s' "$rc" "$out"
}
key() { [[ "$1" == send ]] && echo sent || echo delivered; }
wedged() { [[ -f "$(_wedge_dir)/seatx" ]] && echo yes || echo no; }

for site in send deliver; do
  k=$(key "$site")
  # ---- L: the transcript proves it landed
  for lm in same rotate-in clear-in; do
    r=$(run "$site" "$lm"); rc="${r%%$'\t'*}"; out="${r#*$'\t'}"
    is "L $site [$lm]: exits 0" 0 "$rc"
    is "L $site [$lm]: receipt $k:true" true "$(jq -r ".data.$k" <<<"$out")"
    is "L $site [$lm]: no unconfirmed reason" false "$(jq -r '.data|has("reason")' <<<"$out")"
    is "L $site [$lm]: no wedge mark left for a landed message" no "$(wedged)"
    is "L $site [$lm]: the composer was not cleared under a landed message" no "$([[ -f "$CLEARED" ]] && echo yes || echo no)"
    grep -q 'transcript shows it landed' "$TMP/err" \
      && ok_t "L $site [$lm]: stderr names the transcript as the witness" \
      || bad_t "L $site [$lm]: stderr names the transcript as the witness" "$(cat "$TMP/err")"
  done
  # ---- N: negative controls — exactly today's exit 12 receipt
  for lm in nothing tool noise rotate rotate-late; do
    r=$(run "$site" "$lm"); rc="${r%%$'\t'*}"; out="${r#*$'\t'}"
    is "N $site [$lm]: exits E_UNCONFIRMED (12)" 12 "$rc"
    is "N $site [$lm]: receipt $k:false" false "$(jq -r ".data.$k" <<<"$out")"
    is "N $site [$lm]: carries the DIVE-4246 reason" "$REASON" "$(jq -r '.data.reason' <<<"$out")"
    is "N $site [$lm]: residual handling still runs (wedge mark)" yes "$(wedged)"
    is "N $site [$lm]: residual handling still runs (composer cleared)" yes "$([[ -f "$CLEARED" ]] && echo yes || echo no)"
  done
done

# ---- N: no readable transcript at mark time = cannot tell = exit 12
reset_store; rm -rf "$ROOT"; rm -f "$ENTERS"
rc=0; out=$(LAND=nothing JSON_MODE=1 cmd_send seatx "$PAYLOAD" --raw 2>/dev/null) || rc=$?
is "N send [no transcript store]: exits 12" 12 "$rc"
is "N send [no transcript store]: sent:false" false "$(jq -r '.data.sent' <<<"$out")"
# ---- N: a payload too short for a distinctive needle cannot be claimed
reset_store; rm -f "$ENTERS"
SHORT='ok go'
_hb_submit_settled() { _HB_COMPOSER_UNSENT="$SHORT"; return 1; }
rec_user "$SHORT" >>"$OLD"   # even with the text already in the transcript
rc=0; out=$(LAND=nothing JSON_MODE=1 cmd_send seatx "$SHORT" --raw 2>/dev/null) || rc=$?
is "N send [needle below floor]: exits 12, never a guess" 12 "$rc"
_hb_submit_settled() { _HB_COMPOSER_UNSENT="$PAYLOAD"; return 1; }

# ---- M: the pre-fix inject_and_submit (origin/main f1aa1c57) on the L1 input
_REAL_IAS="$(declare -f inject_and_submit)"
inject_and_submit() {
  local name="$1" payload="$2"
  local user="agent-${name}"
  while [[ "$payload" == *$'\n' || "$payload" == *$'\r' ]]; do payload="${payload%?}"; done
  local _inbox _drc=0
  if _inbox="$(_agent_delivery_inbox "$name")"; then return 0; fi
  if _a2a_should_queue "$name" "$payload"; then _a2a_queue_put "$name" "$payload" "${_A2A_GUARD:-}" && return 4; fi
  _agent_pane_safe_to_type "$name" || return 3
  sudo -u "$user" tmux send-keys -t "agent-${name}" C-u 2>/dev/null || return 1
  [[ -n "$(_hb_claude_pid "$name")" ]] && { _hb_composer_scrub "$name" || true; }
  _WAKE_HEAD=""; _WAKE_BODY="$payload"
  [[ "${_WAKE_VOUCH:-0}" == "1" && -n "$(_hb_claude_pid "$name")" ]] && _wake_split "$payload"
  local -a _parts=("$_WAKE_BODY"); local _pi
  [[ -n "$_WAKE_HEAD" ]] && _parts=("$_WAKE_HEAD" "$_WAKE_BODY")
  for _pi in "${!_parts[@]}"; do
    (( _pi == 0 )) || sleep "${_WAKE_TYPED_GAP_SEC:-0.3}"
    sudo -u "$user" tmux send-keys -t "agent-${name}" -l -- "${_parts[_pi]}"
  done
  sleep 0.3
  sudo -u "$user" tmux send-keys -t "agent-${name}" Enter
  _hb_submit_settled "$name" && { _wedge_clear "$name"; return 0; }
  sleep "${_HB_SUBMIT_RETRY_SEC:-0.5}"
  sudo -u "$user" tmux send-keys -t "agent-${name}" Enter
  _hb_submit_settled "$name" && { _wedge_clear "$name"; return 0; }
  local _ias_left="${_HB_COMPOSER_UNSENT}"
  _wedge_mark "$name" "${#_ias_left}" "$_ias_left" "residual"
  if _hb_composer_clear "$name"; then _wedge_mark "$name" "${#_ias_left}" "$_ias_left" "cleared"; fi
  return 1
}
r=$(run send same); rc="${r%%$'\t'*}"
is "M pre-fix tree, transcript shows the payload landed: exits 12 (the defect)" 12 "$rc"
eval "$_REAL_IAS"

# ---- DIVE-9484: the record reaches disk LATE ----------------------------------
# Measured on a box 2026-11-27: the payload's user record was followed by
# `api-request` 1.1 s / 2.1 s later, and exit 12 fired at the same second. The
# record is written after the seat's prompt hooks, so ONE read at +1 s loses the
# race. Here the store is appended LATE_AT virtual seconds after the second Enter
# failed: a fake `sleep` advances a clock that only runs once both Enters are
# spent, so timing is exact and the arm costs no wall time. Real defaults:
# first read at +1 s, then every 0.5 s, 4 re-reads (~3 s in all).
VCLK="$TMP/vclk"; LATE_DONE="$TMP/late-done"; LATE_AT=99
sleep() {
  [[ "$(cat "$ENTERS" 2>/dev/null || echo 0)" -ge 2 ]] || return 0
  local t; t=$(awk -v a="$(cat "$VCLK" 2>/dev/null || echo 0)" -v b="$1" 'BEGIN{print a+b}')
  echo "$t" >"$VCLK"
  if [[ ! -f "$LATE_DONE" ]] && awk -v t="$t" -v at="$LATE_AT" 'BEGIN{exit !(t>=at)}'; then
    rec_user "$(cat "$TYPED")" >>"$OLD"; touch "$LATE_DONE"
  fi
}
late() { # <LATE_AT> -> "<rc>\t<json>"; stderr in $TMP/err
  rm -f "$VCLK" "$LATE_DONE"; LATE_AT="$1"
  _HB_LANDED_WAIT_SEC=1 _HB_LANDED_POLL_SEC=0.5 _HB_LANDED_RETRIES=4 run send nothing
}
r=$(late 1.5); rc="${r%%$'\t'*}"; out="${r#*$'\t'}"
is "F1 record lands 1.5 s after the 2nd Enter failed: exits 0" 0 "$rc"
is "F1 ...receipt sent:true" true "$(jq -r '.data.sent' <<<"$out")"
is "F1 ...no wedge mark for a message that landed" no "$(wedged)"
grep -q 'transcript shows it landed:.*on re-read' "$TMP/err" \
  && ok_t "F1 ...the step names the receipt, and that it came on a re-read" \
  || bad_t "F1 ...the step names the receipt, and that it came on a re-read" "$(cat "$TMP/err")"
r=$(late 2.5); rc="${r%%$'\t'*}"
is "F2 record lands 2.5 s after (inside the ~3 s deadline): exits 0" 0 "$rc"
# negative controls: the deadline is BOUNDED and a real miss still exits 12
r=$(late 99); rc="${r%%$'\t'*}"; out="${r#*$'\t'}"
is "F3 a payload that never reaches the transcript: still exits 12" 12 "$rc"
is "F3 ...sent:false with the machine-stable DIVE-4246 reason" "$REASON" "$(jq -r '.data.reason' <<<"$out")"
is "F3 ...the wait is bounded: 1 s + 4 x 0.5 s = 3 s of re-reads, then it gives up" 3 "$(cat "$VCLK")"
grep -q 'neither did the seat.s transcript: transcript aaaa-old.jsonl gained no bytes since byte [0-9]* (5 read(s))' "$TMP/err" \
  && ok_t "F3 ...exit 12 names the receipt arm that missed (no bytes since byte N, 5 reads)" \
  || bad_t "F3 ...exit 12 names the receipt arm that missed (no bytes since byte N, 5 reads)" "$(cat "$TMP/err")"
rm -f "$VCLK" "$LATE_DONE"; LATE_AT=99
r=$(_HB_LANDED_WAIT_SEC=1 _HB_LANDED_POLL_SEC=0.5 run send noise); rc="${r%%$'\t'*}"
is "F4 transcript grew with no payload record: exits 12" 12 "$rc"
grep -q 'no non-tool_result user record since byte [0-9]* carries this payload' "$TMP/err" \
  && ok_t "F4 ...exit 12 names the 'no matching user record since byte N' arm" \
  || bad_t "F4 ...exit 12 names the 'no matching user record since byte N' arm" "$(cat "$TMP/err")"
r=$(_HB_LANDED_WAIT_SEC=1 _HB_LANDED_POLL_SEC=0.5 run send rotate); rc="${r%%$'\t'*}"
is "F5 a new session that is not this payload: exits 12" 12 "$rc"
grep -q 'the session rotated to bbbb-new.jsonl and its first user record is not this payload' "$TMP/err" \
  && ok_t "F5 ...exit 12 names the rotation arm" \
  || bad_t "F5 ...exit 12 names the rotation arm" "$(cat "$TMP/err")"
# M: the base tree's _hb_landed_check (origin/main a6ff36e6: ONE read at +1 s,
# carried verbatim minus comments and logs) on the F1 input exits 12.
_REAL_LC="$(declare -f _hb_landed_check)"
_hb_landed_check() {
  local name="$1" text="$2" now_file now_size needle tail_rc=0
  _HB_LANDED_EVIDENCE=""
  needle=$(_hb_landed_needle "$text") || return 1
  [[ -z "$_HB_LANDED_FILE" || -z "$_HB_LANDED_SIZE" ]] && return 1
  sleep "${_HB_LANDED_WAIT_SEC:-1}"
  now_file=$(_hb_transcript_newest "$name")
  [[ "$now_file" != "$_HB_LANDED_FILE" ]] && return 1
  now_size=$(sudo -n -u "agent-${name}" stat -c %s "$_HB_LANDED_FILE" 2>/dev/null) || now_size=""
  if ! [[ "$now_size" =~ ^[0-9]+$ ]] || (( now_size <= _HB_LANDED_SIZE )); then return 1; fi
  sudo -n -u "agent-${name}" tail -c "+$(( _HB_LANDED_SIZE + 1 ))" "$_HB_LANDED_FILE" 2>/dev/null \
    | grep -a '"type"[[:space:]]*:[[:space:]]*"user"' \
    | grep -av -e '"type"[[:space:]]*:[[:space:]]*"tool_result"' -e '"tool_use_id"' \
    | grep -aqF -- "$needle" || tail_rc=1
  (( tail_rc != 0 )) && return 1
  _HB_LANDED_EVIDENCE="$(basename "$_HB_LANDED_FILE") gained a user record carrying this payload ('${needle:0:40}') after byte ${_HB_LANDED_SIZE}"
  return 0
}
r=$(late 1.5); rc="${r%%$'\t'*}"
is "M2 base-tree landed check (one read at +1 s) on the F1 input: exits 12 (the defect)" 12 "$rc"
eval "$_REAL_LC"
unset -f sleep

printf 'agent_send_landed_transcript_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
