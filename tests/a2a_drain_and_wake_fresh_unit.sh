#!/usr/bin/env bash
# DIVE-4296 — two delivery defects in one subsystem, graded together.
#
# DEFECT 1: `heartbeat wake-task` hard-coded fresh=false, so a FORCED wake onto a
# seat registered `heartbeat.fresh: true` skipped the /clear the tick would have
# sent and landed the /goal under the previous turn's output (measured 2026-09-11
# 07:45Z ops, 07:49Z quinn).
# DEFECT 2: the a2a spool drained ONE message per 5-minute cron tick, so quinn's
# 15-deep spool at 07:35Z was an 80-minute backlog, and the sender's receipt said
# only "queued, delivers at its next idle" — no depth, so a seat narrates "async
# by design" at a human who has been waiting an hour.
#
# WHAT THIS GRADES:
#   A. wake-task on a fresh seat sends /clear BEFORE the goal (send order pinned);
#   B. wake-task --no-fresh does not, and a non-fresh seat does not;
#   C. a row carrying fresh=1 forces the clear even on a non-fresh seat;
#   D. a spool of N drains in ONE sweep while the seat stays idle, and each drain
#      logs the depth that is left;
#   E. a busy seat still takes at most one message per round (no second message
#      typed into the turn the first started);
#   F. the sender's queued receipt names the depth and the force verb.
#
# MUTATION (the row's own acceptance): restore the literal
#   _hb_wake "$name" "false" "$task_id" "$task_ident"
# in cmd_heartbeat_wake_task and arm A must go red. Restore the single-pass
# `for name in …; do a2a_queue_flush_one …; done` sweep and arm D must go red.
#
# Boundaries only are stubbed: tmux/systemd/sudo, the registry, the DB, the idle
# predicate and _hb_wake's best-effort enrichment clauses. cmd_heartbeat_wake_task,
# _hb_effective_fresh, _hb_wake's send order, _hb_a2a_queue_sweep,
# a2a_queue_flush_one and _a2a_queued_reason stay REAL.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
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
# shellcheck disable=SC1091
source src/cmd_heartbeat.sh

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-4296}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { local l="$1" w="$2" g="$3"; if [[ "$g" == "$w" ]]; then ok_t "$l"; else bad_t "$l" "want=[$w] got=[$g]"; fi; }

SENT="${TMPROOT}/sent.log"
LOG="${TMPROOT}/hb.log"
: >"$SENT"; : >"$LOG"

# --- boundaries -------------------------------------------------------------
require_root() { :; }
fail() { printf 'FAILCALL %s\n' "${2:-}" >&2; return 1; }
systemctl() { return 0; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { [[ "${1:-}" == "has-session" ]] && return 0; printf 'TMUX %s\n' "$*" >>"$SENT"; return 0; }
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }
# The ONE thing arm A/B/C reads: what _hb_wake typed, in order.
_hb_send_line() { printf '%s\n' "$2" >>"$SENT"; return 0; }
# _hb_wake's best-effort enrichments are not what this row changed.
_hb_loop_terminal_clause() { return 1; }
_hb_reject_fix_clause()    { return 1; }
_hb_carryover_clause()     { return 1; }
_hb_recall_cite()          { return 1; }
_hb_is_knowledge_task()    { return 1; }
_task_agent_gate_pred()    { printf '1=0\n'; }
# Registry: `ops` is a fresh seat, `codey` is not. AGENT_FRESH flips ops per arm.
registry_read() {
  printf '{"agents":{"ops":{"heartbeat":{"fresh":%s}},"codey":{"heartbeat":{"fresh":false}}}}\n' \
    "${OPS_FRESH:-true}"
}
# DB: the row is a live todo; TASK_FRESH drives the per-row override column.
db() {
  local q="$1"
  case "$q" in
    *"SELECT status FROM tasks"*)          printf 'todo\n' ;;
    *"COALESCE(fresh,'')"*)                printf '%s\n' "${TASK_FRESH:-}" ;;
    *"COALESCE(title,'')"*)                printf '\n' ;;
    *)                                     printf '\n' ;;
  esac
}
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
_hb_agent_idle() { return "${IDLE_RC:-0}"; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '4296\n'; }
_hb_verify_submit()       { return 0; }
wait_agent_input_ready()  { return 0; }
require_agent()           { :; }
mirror_interagent_outbound() { :; }
_buzz_mirror_outbound()   { :; }
a2a_needs_scoped()        { return 1; }
a2a_round_guard()         { return 0; }
envelope_tier()           { printf 'admin\n'; }
envelope_via()            { :; }
envelope_provenance()     { printf 'derived\n'; }
_envelope_caller()        { printf 'olivia\n'; }
auto_sender_from_sudo()   { printf 'olivia\n'; }
gen_msg_id()              { printf 'q4296\n'; }
_agent_refuse_peer_forgery() { :; }
audit_log()               { :; }

reset_wake() { : >"$SENT"; : >"$LOG"; }
# header.sh sets -o pipefail, so a `grep | head | cut` that matches nothing
# returns non-zero and would abort the harness under set -e — which is exactly
# the state a MUTATED build is in. Swallow it: an absent line must be reported
# as a red arm, not as a dead harness.
first_line() { head -1 "$SENT" 2>/dev/null || true; }
goal_line_no() { { grep -n '^/goal ' "$SENT" | head -1 | cut -d: -f1; } 2>/dev/null || true; }
clear_line_no() { { grep -n '^/clear$' "$SENT" | head -1 | cut -d: -f1; } 2>/dev/null || true; }

# --- A: a forced wake on a FRESH seat clears first ---------------------------
# The defect verbatim: the goal must not land under the previous turn's output.
reset_wake
OPS_FRESH=true cmd_heartbeat_wake_task ops 4296 DIVE-4296
_c="$(clear_line_no)"; _g="$(goal_line_no)"
if [[ -n "$_c" && -n "$_g" ]] && (( _c < _g )); then
  ok_t "A: fresh seat — /clear is typed BEFORE the /goal"
else
  bad_t "A: fresh seat — /clear is typed BEFORE the /goal" "clear=${_c:-absent} goal=${_g:-absent}"
fi
is "A: the clear is the very first line" "/clear" "$(first_line)"
grep -q 'fresh=true' "$LOG" && ok_t "A: the log states fresh=true" \
  || bad_t "A: the log states fresh=true" "$(cat "$LOG")"

# --- B: --no-fresh, and a non-fresh seat, do not clear -----------------------
reset_wake
OPS_FRESH=true cmd_heartbeat_wake_task --no-fresh ops 4296 DIVE-4296
is "B: --no-fresh types no /clear" "" "$(clear_line_no)"
[[ -n "$(goal_line_no)" ]] && ok_t "B: --no-fresh still delivers the goal" \
  || bad_t "B: --no-fresh still delivers the goal" "no /goal line"
reset_wake
cmd_heartbeat_wake_task codey 4296 DIVE-4296
is "B: a non-fresh seat is untouched by this row" "" "$(clear_line_no)"
reset_wake
cmd_heartbeat_wake_task --fresh codey 4296 DIVE-4296
is "B: --fresh forces the clear on a non-fresh seat" "/clear" "$(first_line)"

# --- C: the row's own fresh=1 override still wins (DIVE-138) -----------------
reset_wake
OPS_FRESH=false TASK_FRESH=1 cmd_heartbeat_wake_task codey 4296 DIVE-4296
is "C: a fresh=1 row clears even on a non-fresh seat" "/clear" "$(first_line)"

# --- D: a spool of N drains in ONE sweep while the seat stays idle -----------
# The 75-minute backlog, restated as a test: 5 spooled, seat idle throughout,
# one sweep must deliver all 5 — not one and a five-minute wait.
: >"$SENT"
rm -rf "${TMPROOT}/agent-ops"
for n in 1 2 3 4 5; do IDLE_RC=1 inject_and_submit ops "spool-${n}" || true; done
is "D: five spooled" "5" "$(find "$(_a2a_queue_dir ops)" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"
: >"$SENT"; : >"$LOG"
# Called exactly as the tick calls it — `|| _hb_log`, which is also what keeps
# set -e out of the sweep (header.sh sets -o pipefail, and a seat with no spool
# directory makes the depth probe's pipeline non-zero).
IDLE_RC=0 _HB_A2A_DRAIN_POLL_SEC=0 _HB_A2A_DRAIN_BUDGET_SEC=30 _hb_a2a_queue_sweep || true
is "D: the whole spool drained in one sweep" "0" \
   "$(find "$(_a2a_queue_dir ops)" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"
is "D: five delivered"    "5" "$_HB_A2A_FLUSHED"
is "D: in send order"     "1" "$(grep -c 'spool-1' "$SENT" || true)"
_d1="$(grep -c 'still spooled' "$LOG" || true)"
is "D: every drain logs the remaining depth" "5" "$_d1"
grep -q '4 still spooled' "$LOG" && ok_t "D: the depth logged is the depth AFTER the drain" \
  || bad_t "D: the depth logged is the depth AFTER the drain" "$(cat "$LOG")"

# --- E: a BUSY seat still takes nothing, and the pass stays bounded ----------
: >"$SENT"; : >"$LOG"
rm -rf "${TMPROOT}/agent-ops"
for n in 1 2 3; do IDLE_RC=1 inject_and_submit ops "busy-${n}" || true; done
: >"$SENT"
IDLE_RC=1 _HB_A2A_DRAIN_POLL_SEC=0 _HB_A2A_DRAIN_BUDGET_SEC=1 _hb_a2a_queue_sweep || true
is "E: a busy seat is never typed into" "0" "$(grep -c -- 'send-keys' "$SENT" 2>/dev/null || true)"
is "E: nothing delivered"               "0" "$_HB_A2A_FLUSHED"
is "E: the spool is intact"             "3" "$(find "$(_a2a_queue_dir ops)" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')"
grep -q 'drain budget' "$LOG" && ok_t "E: the pass gives up on its budget and says so" \
  || bad_t "E: the pass gives up on its budget and says so" "$(cat "$LOG")"

# --- F: the sender's receipt names the depth --------------------------------
# "queued" alone is what let a 15-deep backlog be narrated as async-by-design.
r1="$(_a2a_queued_reason 1)"
r9="$(_a2a_queued_reason 9)"
r0="$(_a2a_queued_reason)"
[[ "$r0" == *"queued, delivers at its next idle or wake"* ]] \
  && ok_t "F: the pre-4296 sentence is preserved for callers that match it" \
  || bad_t "F: the pre-4296 sentence is preserved" "$r0"
[[ "$r0" != *"spool"* ]] && ok_t "F: no depth is invented when none was measured" \
  || bad_t "F: no depth is invented when none was measured" "$r0"
[[ "$r1" == *"#1 in that seat's spool"* ]] && ok_t "F: depth 1 is named" || bad_t "F: depth 1 is named" "$r1"
[[ "$r1" != *"ahead of it"* ]] && ok_t "F: depth 1 claims nothing ahead of it" \
  || bad_t "F: depth 1 claims nothing ahead of it" "$r1"
[[ "$r9" == *"#9 in that seat's spool"* && "$r9" == *"8 ahead of it"* ]] \
  && ok_t "F: depth 9 names the 8 ahead" || bad_t "F: depth 9 names the 8 ahead" "$r9"
[[ "$r9" == *"wake-task"* ]] && ok_t "F: the receipt names the force verb" \
  || bad_t "F: the receipt names the force verb" "$r9"
# End to end through cmd_send: the depth on the receipt is the live spool depth.
rm -rf "${TMPROOT}/agent-ops"
for n in 1 2; do IDLE_RC=1 inject_and_submit ops "prior-${n}" || true; done
out="$(IDLE_RC=1 JSON_MODE=1 cmd_send ops --message="third in line" 2>/dev/null)"
is "F: cmd_send still reports queued:true" "true" "$(jq -r '.data.queued' <<<"$out")"
[[ "$(jq -r '.data.reason' <<<"$out")" == *"#3 in that seat's spool"* ]] \
  && ok_t "F: cmd_send's receipt carries the live depth" \
  || bad_t "F: cmd_send's receipt carries the live depth" "$(jq -r '.data.reason' <<<"$out")"

# --- G: source control — the literal is gone ---------------------------------
grep -q '_hb_wake "$name" "false"' src/cmd_heartbeat.sh \
  && bad_t "G: wake-task no longer hard-codes fresh=false" "the literal is back" \
  || ok_t "G: wake-task no longer hard-codes fresh=false"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
