#!/usr/bin/env bash
# TIER: core — 2.0s measured on the 5dive host (agent-dev seat, worktree cli-4826-dev,
#   2026-09-22): fits the 300s PR core; stated, not defaulted. No root, no network, no
#   tmux — the only slow thing a heartbeat harness normally does is the fleet probe, and
#   this one stubs it.
# Isolated unit harness for DIVE-4826's ops-notice batcher
# (_hb_ops_digest_note / _hb_ops_digest_flush in cmd_heartbeat.sh).
#
# WHAT THE ROW CHANGED, and therefore what has to be graded. Three heartbeat
# rails — 🧊 stranded-row, ⚠️ blocked-no-reason, ⏳ recurring-stall — used to
# cmd_send ops one message per row. Delivery is tmux send-keys into the live
# pane, so each became ops's NEXT USER TURN mid-row: 36 of them in 7 days.
# They now append to a spool and leave at most ONE batched notice per window.
#
# THE LOAD-BEARING ARMS ARE THE CONTROLS, not the positives. "The notice is
# batched" and "the notice was deleted" produce an identical empty send log, and
# only one of them is the fix — so every arm that asserts silence is paired with
# one that reads the spool and proves the content survived. Likewise the flush
# arms are paired with a throttle arm: "sends once" and "sends on every tick"
# both look green if you only ever call it once.
#
# Isolation contract matches tests/heartbeat_stall_sweep_unit.sh: source src/
# directly, throwaway tasks.db (STATE_DIR -> tmp), cmd_send stubbed so no tmux or
# network is touched. Run: bash tests/heartbeat_ops_digest_unit.sh (no root).
set -uo pipefail
# The corpus contract (tests/harness_rc_corpus_contract_unit.sh): HARNESS-RC must be
# printed from an EXIT trap, not only from the tail of the script, so a harness that
# dies early — a missing source, a failed tasks_db_init — still reports a code instead
# of reading as "produced no verdict".
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-ops-digest.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
SPOOL="$STATE_DIR/heartbeat-ops-digest.tsv"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() {
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  # Record the body with newlines folded, so one send is one line and a grep for
  # a phrase cannot be defeated by where the batch happened to wrap.
  printf '%s\t%s\n' "$tgt" "${msg//$'\n'/⏎}" >>"$SEND_LOG"
}
audit_log() { return 0; }
registry_read() { printf '%s' '{"agents":{}}'; }
_hb_agent_idle() { return 0; }

tasks_db_init
# The rails resolve their audience through _hb_ops_recipient, which reads the org
# chart. An empty chart resolves nobody and every "ops is told" arm goes vacuous.
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE',NULL);"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

sends()   { local n; n=$(wc -l <"$SEND_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
spooled() { local n; n=$(wc -l <"$SPOOL" 2>/dev/null); printf '%s' "${n:-0}"; }
reset_all() {
  db "DELETE FROM tasks; DELETE FROM task_prefs;"
  : >"$SEND_LOG"; rm -f "$SPOOL" "$SPOOL.last"
}

# =============================================================================
# A — a note is QUEUED, never typed into a live seat
# =============================================================================
reset_all
_hb_ops_digest_note "stranded-row" "DIVE-1" "🧊 Stranded 3d: DIVE-1 sat todo on 'dev'"
[[ "$(sends)" == "0" ]] \
  && ok_t "A1 a queued notice produces ZERO live sends — that is the whole change (DIVE-4826)" \
  || bad_t "A1 the rail still sends live" "$(cat "$SEND_LOG")"
# The control for A1: silence is only correct if the notice still EXISTS.
[[ "$(spooled)" == "1" ]] && grep -q 'Stranded 3d: DIVE-1' "$SPOOL" \
  && ok_t "A1 CONTROL: ...and the notice is not lost — its full text is on the spool" \
  || bad_t "A1 the notice vanished instead of being batched" "spool=[$(cat "$SPOOL" 2>/dev/null)]"
# The class is its own column, so a later grep for a class cannot be satisfied by
# a different rail whose prose happens to contain the word.
[[ "$(cut -f2 "$SPOOL")" == "stranded-row" ]] \
  && ok_t "A2 the class is a structured column, not a substring of the prose" \
  || bad_t "A2 class column wrong" "$(cut -f2 "$SPOOL")"

# --- A3: all three rails share the spool and stay silent
_hb_ops_digest_note "blocked-no-reason" "task-engine" "⚠️ Blocked with no live reason: DIVE-2"
_hb_ops_digest_note "recurring-stall"   "DIVE-3"      "⏳ Recurring beat stalled: DIVE-3"
[[ "$(sends)" == "0" && "$(spooled)" == "3" ]] \
  && ok_t "A3 all three ops rails batch, and none of them sends" \
  || bad_t "A3 mixed rails" "sends=$(sends) spooled=$(spooled)"

# =============================================================================
# B — the flush: ONE message, everything in it, and only once per window
# =============================================================================
_hb_ops_digest_flush
[[ "$(sends)" == "1" ]] \
  && ok_t "B1 a flush delivers exactly ONE message for all three notices" \
  || bad_t "B1 wrong send count" "$(cat "$SEND_LOG")"
[[ "$(cut -f1 "$SEND_LOG")" == "ops" ]] \
  && ok_t "B1 ...to the seat the org chart names for this job" \
  || bad_t "B1 wrong recipient" "$(cut -f1 "$SEND_LOG")"
_b=$(cut -f2 "$SEND_LOG")
grep -q 'DIVE-1' <<<"$_b" && grep -q 'DIVE-2' <<<"$_b" && grep -q 'DIVE-3' <<<"$_b" \
  && ok_t "B2 every batched notice's text is IN the message — batching is not truncation" \
  || bad_t "B2 a notice was dropped from the batch" "$_b"
grep -q '3 notice(s)' <<<"$_b" \
  && ok_t "B3 the header states the count, so a reader can tell a quiet day from a lost rail" \
  || bad_t "B3 no count in the header" "$_b"
grep -q 'stranded-row×1' <<<"$_b" && grep -q 'recurring-stall×1' <<<"$_b" \
  && ok_t "B4 ...and the per-class breakdown, which is what makes it triageable at a glance" \
  || bad_t "B4 no class breakdown" "$_b"

# --- B5: THE THROTTLE. Without it this is the old behaviour with extra steps.
: >"$SEND_LOG"
_hb_ops_digest_note "stranded-row" "DIVE-4" "🧊 Stranded 3d: DIVE-4"
_hb_ops_digest_flush
[[ "$(sends)" == "0" ]] \
  && ok_t "B5 THROTTLE: a second flush inside the window sends nothing, however many notices arrived" \
  || bad_t "B5 flushed twice in one window" "$(cat "$SEND_LOG")"
[[ "$(spooled)" == "1" ]] \
  && ok_t "B5 CONTROL: ...and the held-back notice is still queued for the next batch, not discarded" \
  || bad_t "B5 the throttled notice was lost" "spool=[$(cat "$SPOOL" 2>/dev/null)]"

# --- B6: POSITIVE CONTROL for B5 — once the window has elapsed it does fire.
#     B5 alone passes just as well if the flush is broken outright.
db "UPDATE task_prefs SET value=datetime('now','-${_HB_OPS_DIGEST_HOURS} hours','-1 hour') WHERE key='ops_digest_flushed_at';"
_hb_ops_digest_flush
[[ "$(sends)" == "1" ]] && grep -q 'DIVE-4' "$SEND_LOG" \
  && ok_t "B6 POSITIVE CONTROL: past the window the next batch goes out, carrying the held notice" \
  || bad_t "B6 flush never recovers" "$(cat "$SEND_LOG")"

# --- B7: an empty spool is SILENT. A daily "nothing happened" is the same
#     interrupt this row exists to delete.
: >"$SEND_LOG"
db "UPDATE task_prefs SET value=datetime('now','-99 hours') WHERE key='ops_digest_flushed_at';"
_hb_ops_digest_flush
[[ "$(sends)" == "0" ]] \
  && ok_t "B7 an empty spool sends nothing — no daily 'all quiet' turn" \
  || bad_t "B7 sent on an empty spool" "$(cat "$SEND_LOG")"

# --- B8: ROTATION. The flushed notices leave the live spool (so the next batch
#     is not a re-send of this one) but remain readable on disk.
reset_all
_hb_ops_digest_note "stranded-row" "DIVE-5" "🧊 Stranded 9d: DIVE-5"
_hb_ops_digest_flush
[[ ! -s "$SPOOL" ]] && [[ -s "$SPOOL.last" ]] && grep -q 'DIVE-5' "$SPOOL.last" \
  && ok_t "B8 ROTATION: the batch leaves the live spool and is kept in .last, not deleted" \
  || bad_t "B8 rotation wrong" "live=[$(cat "$SPOOL" 2>/dev/null)] last=[$(cat "$SPOOL.last" 2>/dev/null)]"
: >"$SEND_LOG"
db "UPDATE task_prefs SET value=datetime('now','-99 hours') WHERE key='ops_digest_flushed_at';"
_hb_ops_digest_note "stranded-row" "DIVE-6" "🧊 Stranded 9d: DIVE-6"
_hb_ops_digest_flush
_b=$(cut -f2 "$SEND_LOG")
grep -q 'DIVE-6' <<<"$_b" && ! grep -q 'DIVE-5' <<<"$_b" \
  && ok_t "B8 ...so the next batch carries only what is new, never a re-send of the last one" \
  || bad_t "B8 batch repeated a delivered notice" "$_b"

# =============================================================================
# C — the message survives the spool intact
# =============================================================================
# The live rails' texts carry newlines, tabs and backticks. A spool line that is
# not escaped turns one notice into two, or eats the next one's class column.
reset_all
_hb_ops_digest_note "stranded-row" "DIVE-7" $'🧊 line one\nline two\tafter a tab — `5dive task park --wake=`'
[[ "$(spooled)" == "1" ]] \
  && ok_t "C1 a multi-line notice is ONE spool line (a raw newline would split it in two)" \
  || bad_t "C1 spool line count wrong" "$(cat -A "$SPOOL")"
[[ "$(cut -f2 "$SPOOL")" == "stranded-row" && "$(cut -f3 "$SPOOL")" == "DIVE-7" ]] \
  && ok_t "C1 ...and an embedded tab does not shift the class/subject columns" \
  || bad_t "C1 columns shifted" "$(cat "$SPOOL")"
_hb_ops_digest_flush
_b=$(cut -f2 "$SEND_LOG")
grep -q 'line one⏎line two' <<<"$_b" && grep -q '5dive task park --wake=' <<<"$_b" \
  && ok_t "C2 ...and the newline and the remedy verb are restored verbatim in the batch" \
  || bad_t "C2 message did not round-trip" "$_b"
# A literal backslash must not be re-interpreted by the %b render on the way out.
reset_all
_hb_ops_digest_note "stranded-row" "DIVE-8" 'a path C:\new\table and a \t that is prose'
_hb_ops_digest_flush
grep -q 'C:\\new\\table' "$SEND_LOG" \
  && ok_t "C3 a literal backslash round-trips — the render does not re-escape prose" \
  || bad_t "C3 backslash mangled" "$(cut -f2 "$SEND_LOG")"

# =============================================================================
# D — bounded output, and the two failure modes that must not lose a notice
# =============================================================================
reset_all
_HB_OPS_DIGEST_MAX_INLINE=2
for i in 1 2 3 4 5; do _hb_ops_digest_note "stranded-row" "DIVE-B$i" "🧊 body $i"; done
_hb_ops_digest_flush
_b=$(cut -f2 "$SEND_LOG")
grep -q 'body 1' <<<"$_b" && grep -q 'body 2' <<<"$_b" && ! grep -q 'body 3' <<<"$_b" \
  && ok_t "D1 the batch renders at most MAX_INLINE notices in full — a digest with no bound is the wall it replaced" \
  || bad_t "D1 inline cap not applied" "$_b"
grep -q '3 more' <<<"$_b" && grep -q "$SPOOL.last" <<<"$_b" \
  && ok_t "D1 ...and names the remainder count AND where to read it, so nothing is silently dropped" \
  || bad_t "D1 remainder not named" "$_b"
grep -q '5 notice(s)' <<<"$_b" \
  && ok_t "D1 ...while the header still counts all five, not the two it rendered" \
  || bad_t "D1 header counted the rendered subset" "$_b"
_HB_OPS_DIGEST_MAX_INLINE=20

# --- D2: an UNWRITABLE spool must not delete the surfacing. One noisy live turn
#     is a worse day; a silently dropped stall notice is a worse product.
reset_all
_saved_state="$STATE_DIR"
STATE_DIR="/proc/nonexistent-$$"
_hb_ops_digest_note "stranded-row" "DIVE-9" "🧊 Stranded 4d: DIVE-9"
STATE_DIR="$_saved_state"
[[ "$(sends)" == "1" ]] && grep -q 'DIVE-9' "$SEND_LOG" \
  && ok_t "D2 an unwritable spool FALLS BACK to a live send — the notice is never lost to a disk fault" \
  || bad_t "D2 notice lost when the spool could not be written" "$(cat "$SEND_LOG")"

# --- D3: no recipient on the chart -> audited, not crashed, and not sent to a
#     guessed seat. Mirrors _hb_escalate's contract (DIVE-4554).
reset_all
db "DELETE FROM agents_org;"
_hb_ops_digest_note "stranded-row" "DIVE-10" "🧊 Stranded 4d: DIVE-10"
_hb_ops_digest_flush
_rc=$?
[[ "$_rc" == "0" && "$(sends)" == "0" ]] \
  && ok_t "D3 an empty org chart makes the batch undeliverable — audited, never sent to a guessed seat" \
  || bad_t "D3 wrong behaviour with no recipient" "rc=$_rc sends=$(sends)"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE',NULL);"

# =============================================================================
# E — END TO END through the real sweep, which is the arm that would catch a
#     rail being rewired back to a live send.
# =============================================================================
reset_all
e=$(addt --assignee=dev -- "stranded row")
ebusy=$(addt --assignee=dev -- "what dev is actually doing")
db "UPDATE tasks SET status='in_progress' WHERE id=${ebusy};"
db "UPDATE tasks SET created_at=datetime('now','-${_HB_STRANDED_HOURS} hours','-1 hour') WHERE id=${e};"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(sends)" == "0" ]] \
  && ok_t "E1 a REAL sweep over a genuinely stranded row produces no live turn" \
  || bad_t "E1 the sweep still sends live" "$(cat "$SEND_LOG")"
grep -q $'\tstranded-row\t' "$SPOOL" \
  && ok_t "E1 CONTROL: ...because the notice went to the batch, not because the rail is dead" \
  || bad_t "E1 the sweep surfaced nothing at all" "spool=[$(cat "$SPOOL" 2>/dev/null)]"
_hb_ops_digest_flush
grep -q 'Stranded' "$SEND_LOG" && [[ "$(sends)" == "1" ]] \
  && ok_t "E2 ...and the flush delivers it as one batched message" \
  || bad_t "E2 batch did not carry the swept notice" "$(cat "$SEND_LOG")"

# =============================================================================
# F — THE FLUSH IS WIRED INTO THE TICK, AND RUNS AFTER THE SWEEPS THAT FEED IT
#
# Without this section every arm above is satisfied by a batcher NOTHING CALLS.
# Delete `_hb_ops_digest_flush` from cmd_heartbeat_tick and A-E all stay green
# while the ops rail goes permanently silent — one live turn per row replaced by
# no turn ever, which is the silent-drop this row exists to avoid, not the fix it
# claims. A and E prove the notice is batched rather than deleted; F is the arm
# that proves the batch is ever delivered.
#
# READ FROM `declare -f`, NOT FROM THE FILE. The parsed function body is the code
# bash will actually run, and it has no comments in it — a grep over the source
# would match this rail's own explanatory comment block at the call site and stay
# green over a deleted call, which is precisely the vacuous pass being closed here.
# =============================================================================
_tick_body=$(declare -f cmd_heartbeat_tick 2>/dev/null)
[[ -n "$_tick_body" ]] \
  && ok_t "F0/PRECONDITION: cmd_heartbeat_tick is defined — the arms below read real parsed code" \
  || bad_t "F0/PRECONDITION: tick not defined" "F1/F2 would be vacuous"
_sweep_at=$(grep -n '_hb_stall_sweep' <<<"$_tick_body" | head -1 | cut -d: -f1)
[[ -n "$_sweep_at" ]] \
  && ok_t "F0/PRECONDITION: ...and it calls _hb_stall_sweep — the producer the ordering arm is anchored on" \
  || bad_t "F0/PRECONDITION: tick does not call _hb_stall_sweep" "the ordering arm below would be vacuous"
_flush_at=$(grep -n '_hb_ops_digest_flush' <<<"$_tick_body" | head -1 | cut -d: -f1)
[[ -n "$_flush_at" ]] \
  && ok_t "F1 the tick CALLS _hb_ops_digest_flush — a spool nothing drains is a deleted notice, not a batched one" \
  || bad_t "F1 the batcher is never drained by the tick" "the spool would grow forever and ops would hear nothing"
[[ -n "$_flush_at" && -n "$_sweep_at" && "$_flush_at" -gt "$_sweep_at" ]] \
  && ok_t "F2 ...and it runs AFTER _hb_stall_sweep, so notices raised by THIS tick ride out now instead of waiting a full window" \
  || bad_t "F2 flush does not follow the sweep that feeds it" "sweep@${_sweep_at:-none} flush@${_flush_at:-none}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
