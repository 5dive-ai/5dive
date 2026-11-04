#!/usr/bin/env bash
# DIVE-7684 — the heartbeat log says what happened, not what it tried.
#
# Three defects from chill-gorge's daily report (2026-11-04), one file:
#   A. A FAILED escalation logged "sent"/"flushed to '<seat>'" and stamped the
#      throttle (stall_alerted_at / ops_digest_flushed_at) as if delivered:
#      _hb_escalate set _HB_ESCALATE_TO before the send and returned 0 either
#      way. The digest's rotated spool (.last) was then overwritten unsent by
#      the next flush.
#   B. The stall-sweep activity probe counted DISABLED seats, which have no pane
#      and read UNMEASURABLE, so the headline could never be "🛑 fleet-stall".
#   C. "[seat] due + todo X — waking" was logged before _hb_wake, so a parked
#      seat that is never woken got the line every tick.
#
# Each arm has a negative control. The product's own functions are driven
# (_hb_escalate, _hb_ops_digest_flush, _hb_stall_sweep, _hb_fleet_activity_probe,
# _hb_rebalance_sweep + the real _rebal_apply). For C, the tick's dispatch
# block is EXTRACTED VERBATIM from src/cmd_heartbeat.sh and run in a loop with
# _hb_wake stubbed, since the tick itself needs tmux/systemd.
#
# Mutation grade: HB_UNDER_TEST=<pre-fix cmd_heartbeat.sh> (and optionally
# REBAL_UNDER_TEST=<pre-fix rebalance.sh>) runs the same arms against another
# tree; on origin/main before this row they go red.
#
# Run: bash tests/heartbeat_escalation_truth_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
HB_FILE="${HB_UNDER_TEST:-$SRC/cmd_heartbeat.sh}"
REBAL_FILE="${REBAL_UNDER_TEST:-$SRC/task/rebalance.sh}"

TMP="$(mktemp -d /tmp/hb-escalation-truth.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$HB_FILE"
# shellcheck source=/dev/null
source "$REBAL_FILE"
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2

STATE_DIR="$TMP"
fixture_box_verify_policy always || exit 1
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_task_human_send_allowed() { return 0; }
audit_log() { return 0; }
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE',NULL);"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$3], got [$2]"; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then ok_t "$1"; else bad_t "$1" "no [$3] in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad_t "$1" "found [$3] in: $2"; else ok_t "$1"; fi; }

SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
SEND_OK=1
cmd_send() {
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  (( SEND_OK )) || return 1
  printf '%s\t%s\n' "$tgt" "${msg//$'\n'/ }" >>"$SEND_LOG"
}
pref() { db "SELECT COALESCE((SELECT value FROM task_prefs WHERE key='$1'),'');"; }

FLEET='{"agents":{}}'; IDLE_MAP=""
registry_read() { printf '%s' "$FLEET"; }
_hb_agent_idle() {
  local n="$1" e
  for e in $IDLE_MAP; do [[ "${e%%:*}" == "$n" ]] && return "${e##*:}"; done
  return 0
}

# ── A0. the function's own contract ──────────────────────────────────────────
SEND_OK=1; _HB_ESCALATE_TO=""
_hb_escalate "t" "task-engine" "t" "hello" "ops" 2>/dev/null; rc=$?
check "A0a negative control: a delivered send returns 0" "$rc" "0"
check "A0b negative control: ...and names the seat it reached" "$_HB_ESCALATE_TO" "ops"
SEND_OK=0
_hb_escalate "t" "task-engine" "t" "hello" "ops" 2>/dev/null; rc=$?
check "A0c a failed send returns non-zero" "$([[ $rc -ne 0 ]] && echo nonzero || echo 0)" "nonzero"
check "A0d ...and clears _HB_ESCALATE_TO, though the previous call set it to 'ops' (the rebalance/usage-limit lines read this)" "$_HB_ESCALATE_TO" ""
SEND_OK=1; _HB_ESCALATE_TO="ops"
_hb_escalate "t" "task-engine" "t" "hello" "" 2>/dev/null; rc=$?
check "A0e nothing resolving returns non-zero too" "$([[ $rc -ne 0 ]] && echo nonzero || echo 0)" "nonzero"
check "A0f ...with _HB_ESCALATE_TO empty" "$_HB_ESCALATE_TO" ""

# ── A1. stall-sweep: no stamp, no "sent" on a failed send ────────────────────
stall_tick() {  # prints the tick's log
  : >"$SEND_LOG"
  _hb_stall_sweep 2>&1 >/dev/null
}
stall_setup() {
  db "DELETE FROM tasks; DELETE FROM task_prefs;"
  ( cmd_task_add --assignee=bob -- "stranded todo" ) >/dev/null 2>&1
  db "INSERT INTO task_prefs (key,value) VALUES ('stall_first_seen_at', datetime('now','-${_HB_STALL_MIN_MINUTES} minutes','-1 minutes'));"
}
FLEET='{"agents":{"a1":{"heartbeat":{"enabled":true}}}}'; IDLE_MAP=""
stall_setup; SEND_OK=0
log=$(stall_tick)
check "A1a failed stall send: stall_alerted_at NOT written" "$(pref stall_alerted_at)" ""
has   "A1b ...the log says FAILED" "$log" "'cmd_send ops' FAILED"
has   "A1c ...and nobody (undeliverable)" "$log" "nobody (undeliverable)"
hasnt "A1d ...and there is no 'sent ... to' line" "$log" "-> sent"
log=$(stall_tick)
has   "A1e the next tick retries (unstamped), and fails honestly again" "$log" "'cmd_send ops' FAILED"
check "A1f ...still unstamped" "$(pref stall_alerted_at)" ""
SEND_OK=1
log=$(stall_tick)
check "A1g negative control: delivered stall send stamps stall_alerted_at" "$([[ -n "$(pref stall_alerted_at)" ]] && echo set || echo unset)" "set"
has   "A1h negative control: ...and the log names the seat" "$log" "to 'ops'"
check "A1i negative control: ...and ops got it" "$(cut -f1 "$SEND_LOG" | sort -u)" "ops"

# ── A2. ops-digest: no stamp, no "flushed to", notices kept ──────────────────
SPOOL="$(_hb_ops_digest_spool)"
digest_setup() {
  db "DELETE FROM task_prefs WHERE key='ops_digest_flushed_at';"
  rm -f "$SPOOL" "$SPOOL.last"
  printf '2026-11-04 01:00:00\tstranded-row\tDIVE-1\tone\n2026-11-04 02:00:00\trecurring-stall\tDIVE-2\ttwo\n' >"$SPOOL"
}
digest_setup; SEND_OK=0
# A note queued WHILE the flush is sending (after the rotate) must survive too,
# and land after the two older ones.
cmd_send_orig="$(declare -f cmd_send)"
cmd_send() { printf '2026-11-04 03:00:00\tstranded-row\tDIVE-3\tthree\n' >>"$SPOOL"; return 1; }
log=$(_hb_ops_digest_flush 2>&1 >/dev/null)
eval "$cmd_send_orig"
check "A2a failed digest send: ops_digest_flushed_at NOT written" "$(pref ops_digest_flushed_at)" ""
has   "A2b ...the log says FAILED" "$log" "'cmd_send ops' FAILED"
hasnt "A2c ...and there is no \"flushed ... to '<seat>'\" line" "$log" "to 'ops'"
check "A2d ...the notices are back in the spool, oldest first, plus the one queued mid-send" \
  "$(cut -f3 "$SPOOL" 2>/dev/null | paste -sd, -)" "DIVE-1,DIVE-2,DIVE-3"
check "A2e ...and no .last is left for the next rotate to overwrite" "$([[ -e "$SPOOL.last" ]] && echo present || echo gone)" "gone"
SEND_OK=1; : >"$SEND_LOG"
log=$(_hb_ops_digest_flush 2>&1 >/dev/null)
check "A2f negative control: delivered flush stamps ops_digest_flushed_at" "$([[ -n "$(pref ops_digest_flushed_at)" ]] && echo set || echo unset)" "set"
has   "A2g negative control: ...the log names the seat" "$log" "flushed 3 notice(s)"
has   "A2h negative control: ...to ops" "$log" "to 'ops'"
check "A2i negative control: ...and the spool rotated (empty for the next window)" "$([[ -s "$SPOOL" ]] && echo nonempty || echo empty)" "empty"

# ── A3. rebalance: "lead notified" names the lead a send reached ─────────────
db "DELETE FROM tasks; DELETE FROM task_prefs;"
_task_pref_set rebalance_pools '{"p":["x","y"]}' >/dev/null 2>&1 \
  || db "INSERT INTO task_prefs (key,value) VALUES ('rebalance_pools','{\"p\":[\"x\",\"y\"]}');"
_rebal_plan() {  # the real plan's shape: one seat line per member, then moves
  printf 'seat\tx\t5\t5\t-\tbusy\nseat\ty\t0\t0\t-\tidle\n'
  printf 'move\t1\tDIVE-1\tx\ty\tp\tlow\n'
}
_rebal_move() { return 0; }
_rebal_lead() { printf 'lead1'; }
SEND_OK=0; _HB_ESCALATE_TO="ops"   # an earlier rail in the same tick reached ops
log=$(_hb_rebalance_sweep "$(date +%s)" "" 2>&1 >/dev/null)
has   "A3a failed lead send: the rebalance line says 'lead notified: nobody'" "$log" "(lead notified: nobody)"
hasnt "A3b ...not the seat an EARLIER rail reached" "$log" "lead notified: ops"
SEND_OK=1
log=$(_hb_rebalance_sweep "$(date +%s)" "" 2>&1 >/dev/null)
has   "A3c negative control: delivered lead send names the lead" "$log" "(lead notified: lead1)"
hasnt "A3d negative control: ...and the moved list carries no marker line" "$log" "#notified"

# ── B. the probe counts ENABLED seats only ───────────────────────────────────
FLEET='{"agents":{"e1":{"heartbeat":{"enabled":true}},"e2":{"heartbeat":{"enabled":true}},
  "d1":{"heartbeat":{"enabled":false}},"d2":{"heartbeat":{"enabled":false}},"d3":{"heartbeat":{}}}}'
IDLE_MAP="d1:2 d2:2 d3:2"   # a disabled seat has no pane: the real probe reads 2
_hb_fleet_activity_probe 0
check "B1 2 enabled idle + 3 disabled: _HB_ACT_CHECKED=2" "$_HB_ACT_CHECKED" "2"
check "B2 ...and _HB_ACT_UNKNOWN=0" "$_HB_ACT_UNKNOWN" "0"
stall_setup; SEND_OK=1
stall_tick >/dev/null
hdr=$(cut -f2 "$SEND_LOG" | grep -o '🛑 fleet-stall\|❓ possible fleet-stall (UNPROVEN)' | head -1)
check "B3 ...so the headline is '🛑 fleet-stall'" "$hdr" "🛑 fleet-stall"
IDLE_MAP="d1:2 d2:2 d3:2 e2:2"   # one ENABLED seat unmeasurable
_hb_fleet_activity_probe 0
check "B4 negative control: an unmeasurable ENABLED seat is still counted unknown" "$_HB_ACT_UNKNOWN" "1"
stall_setup
stall_tick >/dev/null
hdr=$(cut -f2 "$SEND_LOG" | grep -o '🛑 fleet-stall\|❓ possible fleet-stall (UNPROVEN)' | head -1)
check "B5 negative control: ...and the headline stays a question (DIVE-2244)" "$hdr" "❓ possible fleet-stall (UNPROVEN)"

# ── C. "— waking" only for a seat that woke ──────────────────────────────────
# The dispatch block, verbatim: from the line before DIVE-4409's rc comment to
# the end of the wake loop body. The same bounds hold on the pre-fix tree, where
# that line IS the "waking" log, so the mutation run grades the same block.
start=$(grep -n '# DIVE-4409: rc is initialised, never assumed' "$HB_FILE" | head -1 | cut -d: -f1)
end=$(awk -v s="$start" 'NR>s && /^  done < <\(jq -r .\.agents \| to_entries$/ {print NR; exit}' "$HB_FILE")
if [[ -n "$start" && -n "$end" ]]; then
  BLOCK=$(sed -n "$((start-1)),$((end-1))p" "$HB_FILE")
  ok_t "C0 the dispatch block extracted (lines $((start-1))-$((end-1)))"
else
  BLOCK=""; bad_t "C0 the dispatch block extracted" "start=[$start] end=[$end]"
fi
WAKE_RC=0
_hb_wake() { return "$WAKE_RC"; }
with_registry_lock() { "$@"; }
_hb_wake_budget_inc() { :; }; _hb_clear_active_defer() { :; }
_hb_mark_run() { echo 1; }; _hb_claim_task() { return 0; }; _hb_nudge_enforce() { :; }
dispatch() {  # <wake rc> — prints the log of one pass over one due seat
  WAKE_RC="$1"
  local name=seat1 eff_fresh=true task_id=7 task_ident=DIVE-7 today=2026-11-04 now=0
  local sk_parked=0 woke=0 sk_fail=0 starved=0
  eval "for name in seat1; do
$BLOCK
done" 2>&1
  printf 'COUNTERS parked=%s woke=%s fail=%s\n' "$sk_parked" "$woke" "$sk_fail" >&2
}
log=$(dispatch "$_HB_WAKE_RC_PARKED" 2>&1)
check "C1 a parked seat (wake rc=$_HB_WAKE_RC_PARKED) prints no '— waking' line" "$(grep -c -- '— waking' <<<"$log")" "0"
has   "C2 ...and is still counted parked-skipped" "$log" "parked=1 woke=0"
log=$(dispatch 0 2>&1)
check "C3 negative control: a seat that woke prints '— waking' exactly once" "$(grep -c -- '— waking' <<<"$log")" "1"
has   "C4 negative control: ...and is counted woke" "$log" "woke=1"
log=$(dispatch 1 2>&1)
check "C5 a failed wake prints no '— waking' either" "$(grep -c -- '— waking' <<<"$log")" "0"
has   "C6 ...and its failure line names the task" "$log" "due + todo DIVE-7 — wake failed"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
