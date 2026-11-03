#!/usr/bin/env bash
# DIVE-7626 — a codex seat that hits its usage cap resumes by itself when the
# cap lifts.
#
# THE ROW, measured on leo 2026-11-03: the heartbeat woke the seat with
# fresh=true at 11:20:28Z, the dispatcher opened a NEW rollout, and its only
# turn was refused 6s later ("try again at 1:25 PM"). Three defects held the
# seat dead until a human forced a wake at 13:44Z:
#   1. `_hb_agent_idle` scraped a dispatcher seat's PANE (a log stream, no
#      composer) and read it working forever — `wake-task` was refused as
#      "mid-turn" before and after `agent restart`.
#   2. The new rollout carried no rate-limit reading, so the reset time was
#      `unknown` and the park took the rolling 6h cap. The previous rollout had
#      the reset to the second; the refusal printed it to the minute.
#   3. Once the reset passed, the supervisor's observation is no longer
#      `quota-exhausted`, so DIVE-4328's un-park (keyed on that class) could
#      never fire on a codex seat: nothing re-dispatched the row.
#
# Pure / fixture-only: no tmux, no root, no network, no live registry.
# Run: bash tests/dive7626_codex_cap_resume_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive7626.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/quota_wall.sh lib/codex_quota.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_account.sh \
         cmd_agent_runtime.sh cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
US=$'\037'
field() { local n="$1"; tr "$US" '\n' | sed -n "${n}p"; }
export TZ=UTC   # codex prints the reset in the host zone; pin it

# The real numbers from leo's rollouts.
RESET=1793712313     # 2026-11-03 13:25:13Z, primary resets_at in the 10:43 rollout
REFUSED=1793704834   # 11:20:34Z, the refused turn's task_complete
READ_AT=1793702652   # the older rollout's last reading
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
tc() {  # <epoch> <p_used> <p_reset> <s_used> <s_reset>
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus"}}}\n' \
    "$(iso "$1")" "$2" "$3" "$4" "$5"
}
tc_premium() {
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n' "$(iso "$1")"
}
done_ok() { printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ok"}}\n' "$(iso "$1")"; }
done_wall() {  # <epoch> <printed time>  — leo's refusal, verbatim shape
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"task_complete","error":{"message":"You\\u2019ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at %s.","codex_error_info":"usage_limit_exceeded"}}}\n' \
    "$(iso "$1")" "$2"
}
HOMEX="$TMP/home/leo"
rollout() {  # <name> <mtime-epoch>; stdin -> the file
  local d="$HOMEX/.codex/sessions/2026/11/03"; mkdir -p "$d"
  cat >"$d/$1.jsonl"; touch -d "@$2" "$d/$1.jsonl"
}
fresh_seat() { rm -rf "$HOMEX"; }

# ── 1. the reader: the reset time survives a fresh rollout ──────────────────
fresh_seat
{ tc $(( READ_AT - 600 )) 80 "$RESET" 30 1793783910; tc "$READ_AT" 99 "$RESET" 34 1793783910; done_ok "$READ_AT"; } \
  | rollout rollout-older $(( READ_AT + 5 ))
{ tc_premium "$REFUSED"; done_wall "$REFUSED" "1:25 PM"; } | rollout rollout-newest $(( REFUSED + 1 ))
M=$(codex_quota_read "$HOMEX")
SNAP_RESET=$(jq -r '.snapshot.primary.resetsAt // empty' <<<"$M")
OLDER=$(jq -r '.snapshot.olderFile // empty' <<<"$M")
[[ "$SNAP_RESET" == "$RESET" && "$OLDER" == *rollout-older.jsonl ]] \
  && ok_t "a refused turn in a FRESH rollout borrows the last reading from the older one (reset ${RESET})" \
  || bad_t "the older rollout's reading was not found" "snapshot=$(jq -c .snapshot <<<"$M")"
RA=$(jq -r '.lastTurn.retryAt // empty' <<<"$M")
[[ "$RA" == "1793712360" ]] \
  && ok_t "the refusal's own 'try again at 1:25 PM' is read as the END of that minute (13:26:00Z)" \
  || bad_t "the printed retry time was not parsed" "retryAt='$RA' lastTurn=$(jq -c .lastTurn <<<"$M")"

ST=$(codex_quota_state "$M" $(( RESET - 3600 )))
[[ "$(field 1 <<<"$ST")" == exhausted && "$(field 4 <<<"$ST")" == "$RESET" ]] \
  && ok_t "before the reset: exhausted, resets at the reading's own epoch (not unknown)" \
  || bad_t "before the reset the wall had no time" "$(tr "$US" '|' <<<"$ST")"
ST=$(codex_quota_state "$M" $(( RESET + 60 )))
[[ "$(field 1 <<<"$ST")" == recovered && "$(field 4 <<<"$ST")" == "$RESET" ]] \
  && ok_t "after the reset: recovered (capacity back, no turn run since)" \
  || bad_t "after the reset the seat did not read recovered" "$(tr "$US" '|' <<<"$ST")"

# The supervisor join: what is actually written to the observation.
IFS=$'\x1f' read -r JDL JEP JW <<<"$(_sup_codex_quota_join "$M" $(( RESET - 3600 )) "" unknown "" "")"
[[ "$JDL" == live && "$JEP" == "$RESET" ]] \
  && ok_t "supervisor join before the reset: live + ${RESET} (the park keys to it, not to the 6h cap)" \
  || bad_t "join before reset" "dl=$JDL ep=$JEP"
IFS=$'\x1f' read -r JDL JEP JW <<<"$(_sup_codex_quota_join "$M" $(( RESET + 600 )) "" unknown "" "")"
[[ "$JDL" == lapsed && "$JEP" == "$RESET" ]] \
  && ok_t "supervisor join after the reset: lapsed + ${RESET}" \
  || bad_t "join after reset" "dl=$JDL ep=$JEP"

# The pre-fix shape, as a control: the newest rollout ALONE has no time.
ST=$(CODEX_QUOTA_OLDER_ROLLOUTS=0; M0=$(codex_quota_read "$HOMEX"); jq -c 'del(.lastTurn.retryAt)' <<<"$M0" \
       | { read -r m; codex_quota_state "$m" $(( RESET - 3600 )); })
[[ "$(field 1 <<<"$ST")" == exhausted && -z "$(field 4 <<<"$ST")" ]] \
  && ok_t "[control] the newest rollout alone, without the printed time, has NO reset (the leo shape)" \
  || bad_t "control: the fresh rollout alone should carry no time" "$(tr "$US" '|' <<<"$ST")"

# Printed time alone (no older rollout at all) still dates the wall.
fresh_seat
{ tc_premium "$REFUSED"; done_wall "$REFUSED" "1:25 PM"; } | rollout rollout-only $(( REFUSED + 1 ))
ST=$(codex_quota_state "$(codex_quota_read "$HOMEX")" $(( RESET - 3600 )))
[[ "$(field 1 <<<"$ST")" == exhausted && "$(field 4 <<<"$ST")" == 1793712360 ]] \
  && ok_t "no older rollout: the printed 'try again at' alone dates the wall" \
  || bad_t "the printed time alone did not date the wall" "$(tr "$US" '|' <<<"$ST")"

# Same-minute print: refused at 13:25:05, reset 13:25:13, printed "1:25 PM".
fresh_seat
{ tc_premium 1793712305; done_wall 1793712305 "1:25 PM"; } | rollout rollout-edge 1793712306
RA=$(codex_quota_read "$HOMEX" | jq -r '.lastTurn.retryAt // empty')
[[ "$RA" == 1793712360 ]] \
  && ok_t "a print of the refusal's own minute is TODAY's reset, not tomorrow's" \
  || bad_t "same-minute print resolved to the wrong day" "retryAt=$RA"

# The dated form codex prints for a reset on another day.
fresh_seat
{ tc_premium "$REFUSED"; done_wall "$REFUSED" "Nov 5th, 2026 9:00 AM"; } | rollout rollout-dated $(( REFUSED + 1 ))
RA=$(codex_quota_read "$HOMEX" | jq -r '.lastTurn.retryAt // empty')
[[ "$RA" == "$(( $(date -u -d '2026-11-05 09:00' +%s) + 60 ))" ]] \
  && ok_t "the dated print 'Nov 5th, 2026 9:00 AM' resolves to that day" \
  || bad_t "dated print" "retryAt=$RA"

# A served turn never reaches into older rollouts (a healthy seat reads as before).
fresh_seat
{ tc "$READ_AT" 99 "$RESET" 34 1793783910; } | rollout rollout-older $(( READ_AT + 5 ))
{ tc_premium "$REFUSED"; done_ok "$REFUSED"; } | rollout rollout-newest $(( REFUSED + 1 ))
M=$(codex_quota_read "$HOMEX")
[[ "$(jq -r '.snapshot' <<<"$M")" == null ]] \
  && ok_t "[control] a SERVED newest turn does not borrow an older reading" \
  || bad_t "a served turn borrowed an older reading" "$(jq -c .snapshot <<<"$M")"

# ── 2. a dispatcher seat reads its turn state from health.json ──────────────
DISP="$TMP/disp"; mkdir -p "$DISP/inbox"
_agent_delivery_inbox() { printf '%s\n' "$DISP/inbox"; }
_hb_agent_native_state() { return 1; }              # codex: no claude agents --json
PANE_CALLS="$TMP/pane.calls"
_hb_agent_pane_idle() { printf x >>"$PANE_CALLS"; return 1; }   # the log-stream pane: "working" forever
health() {  # <updatedAt-epoch> <active-json> [queueDepth]
  printf '{"schema":1,"bridge":"codex-dispatcher","heartbeatMs":15000,"updatedAt":"%s","queueDepth":%s,"active":%s,"lastSession":{"reason":"a new task (5dive)"}}\n' \
    "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z)" "${3:-0}" "$2" >"$DISP/health.json"
}
NOWS=$(date -u +%s)
: >"$PANE_CALLS"; health "$NOWS" null
_hb_agent_idle leo 0; rc=$?
[[ "$rc" == 0 && ! -s "$PANE_CALLS" ]] \
  && ok_t "a dispatcher seat whose last turn ENDED (refused) reads IDLE, from health.json, not the pane" \
  || bad_t "an idle dispatcher seat did not read idle" "rc=$rc pane_calls=$(cat "$PANE_CALLS")"
: >"$PANE_CALLS"; health "$NOWS" '{"turnId":"t1","source":"agent"}'
_hb_agent_idle leo 0; rc=$?
[[ "$rc" == 1 ]] \
  && ok_t "a turn in flight reads BUSY (an answer in flight is never typed over)" \
  || bad_t "an active turn read idle" "rc=$rc"
: >"$PANE_CALLS"; health "$NOWS" null 0; : >"$DISP/inbox/m1.json"
_hb_agent_idle leo 0; rc=$?; rm -f "$DISP/inbox/m1.json"
[[ "$rc" == 1 ]] \
  && ok_t "an undrained inbox message reads BUSY" \
  || bad_t "a pending inbox message read idle" "rc=$rc"
# After `agent restart`: the dispatcher reboots with nothing active.
: >"$PANE_CALLS"; health "$NOWS" null
_hb_agent_idle leo 0; rc=$?
[[ "$rc" == 0 ]] \
  && ok_t "after agent restart (fresh record, no active turn, empty queue) the seat reads idle" \
  || bad_t "a restarted idle dispatcher seat read busy" "rc=$rc"
# A stale record is no reading: the old pane path decides, exactly as before.
: >"$PANE_CALLS"; health $(( NOWS - 3600 )) null
_hb_agent_idle leo 0; rc=$?
[[ "$rc" == 1 && -s "$PANE_CALLS" ]] \
  && ok_t "[control] a STALE record is no reading: falls through to the pane probe" \
  || bad_t "a stale record was trusted" "rc=$rc pane_calls=$(cat "$PANE_CALLS")"
# A pane seat (no dispatcher) never consults it.
_agent_delivery_inbox() { return 1; }
: >"$PANE_CALLS"
_hb_agent_idle leo 0; rc=$?
[[ "$rc" == 1 && -s "$PANE_CALLS" ]] \
  && ok_t "[control] a seat with no dispatcher keeps the pane probe" \
  || bad_t "a pane seat skipped its pane probe" "rc=$rc"

# ── 3. the tick re-dispatches the held row once the reset has passed ────────
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()      { cat "$REGISTRY"; }
registry_write()     { cat > "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
_hb_pane_fingerprint() { echo "fp"; }
_hb_pane_capture()   { printf '%s\n' "codex-dispatcher: started 5dive-1 source=agent"; }
cmd_send()           { :; }
_hb_claude_started() { echo ""; }
_hb_agent_idle()     { return 0; }   # section 2 proved the dispatcher reads idle
ESC_LOG="$TMP/escalated"; WAKE_LOG="$TMP/woke"; SEND_LOG="$TMP/sent"
cmd_task_escalate()  { printf '%s\n' "$1" >>"$ESC_LOG"; }
_hb_send_line()      { printf '%s\n' "$2" >>"$SEND_LOG"; return 0; }
_hb_wake()           { printf '%s %s\n' "$1" "$3" >>"$WAKE_LOG"; return 0; }
spies_reset() { : >"$ESC_LOG"; : >"$WAKE_LOG"; : >"$SEND_LOG"; }
woke() { [[ -s "$WAKE_LOG" ]]; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
row()   { db "SELECT status FROM tasks WHERE id=$1;"; }
age_m() { db "SELECT CAST((julianday('now') - julianday(started_at)) * 1440 AS INTEGER) FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks; DELETE FROM supervisor_events;"; }
# One observation, shaped like the real column (codexQuota rides in signals).
obs() {  # <cls> <deadline-state> <epoch> <codex-last-turn-error|"">
  local err_json=null; [[ -n "$4" ]] && err_json="\"$4\""
  db "INSERT INTO supervisor_events (ts, agent, event, classification, cause, signals)
      VALUES (datetime('now'), 'leo', 'observe', $(sqlq "$1"), $(sqlq "$1"),
        '{\"signals\":{\"quotaDeadline\":\"$2\",\"quotaDeadlineEpoch\":$3,\"codexQuota\":{\"source\":\"codex-rollout\",\"lastTurn\":{\"at\":1,\"error\":${err_json}}}}}');"
}
held_row() {  # <minutes-old>
  local id; id=$(addt --assignee=leo -- "the /enterprise office pictures")
  _hb_claim_task leo "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-$1 minutes') WHERE id=${id};"
  printf '%s' "$id"
}
NOW=$(date -u +%s)

# Reset still ahead: the claim is HELD, nothing is woken.
reset_all; spies_reset
obs quota-exhausted live $(( NOW + 3600 )) usage_limit_exceeded
T=$(held_row 140)
_hb_reclaim leo 30 >/dev/null 2>&1
{ [[ "$(row "$T")" == in_progress ]] && ! woke; } \
  && ok_t "reset 1h ahead: the claim is HELD and nothing is woken" \
  || bad_t "the seat was woken or reaped before its reset" "row=$(row "$T") woke=$(cat "$WAKE_LOG")"

# THE ROW: the reset passed, the newest observation is no longer quota-exhausted
# (it reads `stuck`/no-progress at leo's 13:30Z tick), and the rollout's newest
# turn is still the refusal. The tick must un-park and wake.
obs stuck lapsed $(( NOW - 300 )) usage_limit_exceeded
_hb_reclaim leo 30 >/dev/null 2>&1
A=$(age_m "$T")
{ [[ "$(row "$T")" == in_progress ]] && (( A < 5 )); } \
  && ok_t "reset passed: claim kept and its clock re-stamped (${A}m, was 140m) — not reaped on the walled age" \
  || bad_t "the held row was not re-stamped" "row=$(row "$T") age=${A}m"
grep -q "^leo ${T}\$" "$WAKE_LOG" \
  && ok_t "reset passed: the tick RE-DISPATCHED the in_progress row (wake onto row ${T})" \
  || bad_t "nothing re-dispatched the row after the reset" "wake log: $(tr '\n' ' ' <"$WAKE_LOG")"
spies_reset
_hb_reclaim leo 30 >/dev/null 2>&1
{ ! woke && [[ "$(row "$T")" == in_progress ]] && [[ ! -s "$ESC_LOG" ]]; } \
  && ok_t "next tick: no second wake, no reap, no escalation (the re-stamp is the latch)" \
  || bad_t "the un-park re-fired or the row was reaped" "woke=$(cat "$WAKE_LOG") row=$(row "$T")"

# Controls: a lapsed observation whose newest turn was SERVED is not this shape.
reset_all; spies_reset
obs stuck lapsed $(( NOW - 300 )) ""
T=$(held_row 140)
_hb_reclaim leo 30 >/dev/null 2>&1
! woke \
  && ok_t "[control] lapsed, but the newest turn was served: no un-park wake (the ordinary rules own it)" \
  || bad_t "a served-turn observation woke the seat" "$(cat "$WAKE_LOG")"
# A row claimed AFTER the reset was never walled and keeps its clock.
reset_all; spies_reset
obs stuck lapsed $(( NOW - 3600 )) usage_limit_exceeded
T=$(held_row 10)
_hb_reclaim leo 30 >/dev/null 2>&1
{ ! woke && (( $(age_m "$T") >= 9 )); } \
  && ok_t "[control] a row claimed after the reset is not re-stamped or re-woken" \
  || bad_t "a post-reset claim was treated as walled" "age=$(age_m "$T") woke=$(cat "$WAKE_LOG")"

# ── 4. the prefetched record carries the two new fields ─────────────────────
grep -q "codexQuota.lastTurn.error" <<<"$(declare -f _hb_reclaim)" \
  && ok_t "the reclaim's one-query prefetch carries the codex last-turn error" \
  || bad_t "the prefetch does not carry the codex last-turn error" "the un-park would only ever see the 2-arg path"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
