#!/usr/bin/env bash
# DIVE-5689 — a SYSTEM NOTICE is delivered to the seat and NOT mirrored into its group.
#
# THE DEFECT. `task answer` on a secret gate pings the row owner with cmd_send, and
# cmd_send mirrors every non-raw outbound into the INVOKING seat's Telegram group (and
# buzz room) under that seat's bot. On a customer box (lodar, 2026-10-06 12:13Z) the
# group read: "@agent_bot DIVE-1 secret gate provided — $EXAMPLE_API_KEY is
# set in your environment …" — a machine notice dressed as something the agent said.
#
# WHAT THIS GRADES:
#   T1 negative control: an ordinary send still mirrors to BOTH rooms;
#   T2 the fix: _5DIVE_SYSTEM_NOTICE=1 types the message into the pane and mirrors nothing;
#   T3 --raw still mirrors nothing (the pre-existing gate, unchanged);
#   T4 source pin: every task-side send in src/task/ AND src/cmd_heartbeat.sh carries
#      the marker, so a new rail added without it goes red here rather than in a
#      customer's group;
#   T5 the shipped rebalance path: build.sh bundles cmd_heartbeat.sh, so rebalance.sh
#      reaches the owner through _hb_escalate, not its own marked fallback. The REAL
#      _hb_escalate, called as rebalance.sh calls it, must mirror nothing.
# Boundaries only are stubbed (tmux, sudo, the idle probe, the two mirrors as
# RECORDERS); cmd_send's mirror decision stays real.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

TMPROOT="$(mktemp -d)"
export STATE_DIR="${TMPROOT}/state"
export FIVEDIVE_CONNECTOR_DIR="${TMPROOT}/connectors"
# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
export A2A_URGENT_LEDGER="${TMPROOT}/a2a-urgent.tsv"
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh

PASS=0; FAIL=0
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-5689}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}

TYPED="${TMPROOT}/typed.log"; MIRRORED="${TMPROOT}/mirrored.log"

# --- boundaries (same set as tests/agent_send_json_receipt_unit.sh) ----------
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { printf 'TMUX %s\n' "$*" >>"$TYPED"; return 0; }
agent_wake_for_send()    { return 0; }
agent_prompt_detectable(){ return 0; }
wait_agent_input_ready() { return 0; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '5689\n'; }
_hb_verify_submit()       { return 0; }
_hb_submit_settled()      { return 0; }
_hb_composer_scrub()      { return 0; }
_wedge_clear()            { :; }
require_agent()           { :; }
# The two mirrors are RECORDERS: the question is whether cmd_send calls them.
mirror_interagent_outbound() { printf 'telegram %s\n' "$1" >>"$MIRRORED"; }
_buzz_mirror_outbound()      { printf 'buzz %s\n' "$1" >>"$MIRRORED"; }
_agent_send_row_hint()    { :; }
_agent_body_shell_hint()  { :; }
a2a_needs_scoped()        { return 1; }
a2a_round_guard()         { return 0; }
envelope_tier()           { printf 'admin\n'; }
envelope_via()            { :; }
envelope_provenance()     { printf 'derived\n'; }
_envelope_caller()        { printf 'ops\n'; }
gen_msg_id()              { printf 'r5689\n'; }
_agent_refuse_peer_forgery() { :; }
audit_log()               { :; }
_hb_agent_idle()          { return 0; }

reset_arm() { : >"$TYPED"; : >"$MIRRORED"; rm -rf "${TMPROOT}/agent-seat_b"; : >"$A2A_URGENT_LEDGER"; }
typed_has() { grep -qF -- "$1" "$TYPED" && echo yes || echo no; }
mirrors()   { if [[ -s "$MIRRORED" ]]; then sort "$MIRRORED" | tr '\n' ',' | sed 's/,$//'; else echo none; fi; }

PING='DIVE-1 secret gate provided — $EXAMPLE_API_KEY is set in your environment from your next command.'

# --- T1: negative control — an ordinary seat-to-seat send still mirrors --------
reset_arm
( cmd_send seat_b --message="hello from a peer" ) >/dev/null 2>&1 || true
is "T1: an ordinary send reaches the pane"           "yes"                     "$(typed_has 'hello from a peer')"
is "T1: an ordinary send mirrors to group AND buzz"  "buzz seat_b,telegram seat_b" "$(mirrors)"

# --- T2: the fix — a system notice reaches the pane and mirrors nothing ---------
reset_arm
( _5DIVE_SYSTEM_NOTICE=1 cmd_send seat_b --from="lodar" --message="$PING" ) >/dev/null 2>&1 || true
is "T2: the system notice reaches the owner's pane"  "yes"  "$(typed_has 'secret gate provided')"
is "T2: the system notice mirrors to NO room"        "none" "$(mirrors)"

# --- T2b: the marker is per-call — the next ordinary send mirrors again --------
reset_arm
( cmd_send seat_b --message="after the notice" ) >/dev/null 2>&1 || true
is "T2b: the marker does not leak into the next send" "buzz seat_b,telegram seat_b" "$(mirrors)"

# --- T3: --raw keeps its pre-existing no-mirror behaviour ----------------------
reset_arm
( cmd_send seat_b --raw --message="raw ping" ) >/dev/null 2>&1 || true
is "T3: a raw send reaches the pane" "yes"  "$(typed_has 'raw ping')"
is "T3: a raw send mirrors nothing"  "none" "$(mirrors)"

# --- T4: source pin — every task-side send carries the marker ------------------
# A send line is a command, not prose inside a message string: `cmd_send "$x"`,
# `5dive agent send "$x"` or `"$_GRADER_TASK_CLI" agent send "$x"` at statement
# position, receiver a quoted variable (the prose mentions write `${x}` bare).
# Every one must carry the marker on the same line.
unmarked="$(grep -nE '(^ *|[(;&|] *|\$\( *)([A-Za-z0-9_]+=[^ ]+ +)*(cmd_send|5dive agent send|"\$_GRADER_TASK_CLI" agent send) "\$' src/task/*.sh src/cmd_heartbeat.sh \
  | grep -vE '^[^:]+:[0-9]+: *#' | grep -v '_5DIVE_SYSTEM_NOTICE=1' || true)"
total="$(grep -cE '_5DIVE_SYSTEM_NOTICE=1 ([A-Za-z0-9_]+=[^ ]+ +)*(cmd_send|5dive agent send|"\$_GRADER_TASK_CLI" agent send) "\$' src/task/*.sh src/cmd_heartbeat.sh | awk -F: '{s+=$2} END{print s}')"
is "T4: no task-side send is left unmarked" "" "$unmarked"
if (( total >= 33 )); then ok_t "T4: the pin sees the marked sends ($total)"; else bad_t "T4: the pin sees the marked sends" "only $total — the pattern stopped matching"; fi

# --- T5: the real _hb_escalate, called exactly as rebalance.sh calls it --------
# Extracted rather than sourcing all of cmd_heartbeat.sh (which defines the whole
# tick); the function body is the shipped bytes. Its two collaborators are stubbed.
_hb_log() { :; }
_hb_alert_undeliverable() { printf 'UNDELIVERABLE %s\n' "$*" >>"$MIRRORED"; }
eval "$(sed -n '/^_hb_escalate() {/,/^}/p' src/cmd_heartbeat.sh)"
if declare -F _hb_escalate >/dev/null; then ok_t "T5: _hb_escalate extracted from src/cmd_heartbeat.sh"
else bad_t "T5: _hb_escalate extracted from src/cmd_heartbeat.sh" "sed found no function body"; fi
reset_arm
_hb_escalate "rebalance" "task-engine" "rebalance" "🔀 Rebalanced un-started rows" "seat_b"
is "T5: the escalation reaches the lead's pane" "yes"  "$(typed_has 'Rebalanced un-started rows')"
is "T5: the escalation mirrors to NO room"      "none" "$(mirrors)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
