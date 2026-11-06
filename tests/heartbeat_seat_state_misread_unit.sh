#!/usr/bin/env bash
# DIVE-7807 unit: two heartbeat misreadings of a seat's state.
#
#   A (teal-fox) — the a2a spool drained into a seat whose AI account refused
#     every turn (402 out of credit), and the sweep logged each one "delivered".
#     The seat was IDLE a second after each refusal, which was the only gate.
#     Now the seat's own transcript reading (seat_turn_trouble, DIVE-7118) holds
#     the spool while it reports a refusal since the seat last started.
#   B (chill-gorge) — the stall clock never moved for rows that started and
#     closed between two ticks, so "fleet-idle 75m" covered five closed rows.
#     Now the clock starts at the latest row movement on the board.
#
# Arms, as the row names them:
#   A1 refused turn after the seat's start: the sweep keeps the .msg, types
#      nothing, logs "held" (once), never "delivered".
#   A2 negative controls: the refusal BEFORE the seat's start, and no refusal at
#      all, both deliver as before.
#   A3 mutation: drop the gate and A1 goes red.
#   B1 clock at now-75m, a stranded todo, another row closed 7m ago with NO
#      started_at: no alert, the clock reads ~7m.
#   B2 negative control: no row movement since the clock started still alerts
#      "idle 75m".
#   B3 mutation: drop the clock move and B1 goes red.
#
# Real code under test: a2a_queue_flush_one, _a2a_spool_held, _hb_a2a_queue_sweep,
# seat_turn_trouble (the transcript parse), _hb_stall_sweep. Stubbed boundaries
# only: tmux/typing, sudo, systemctl, the idle predicate, cmd_send, the registry.
# Run: bash tests/heartbeat_seat_state_misread_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-/nonexistent-7807}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-7807.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/seat_refusal.sh cmd_task.sh cmd_org.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2

STATE_DIR="$TMP"
fixture_box_verify_policy always || exit 1
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
DIGEST_SPOOL="$STATE_DIR/heartbeat-ops-digest.tsv"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { if [[ "$3" == "$2" ]]; then ok_t "$1"; else bad_t "$1" "want=[$2] got=[$3]"; fi; }

# --- boundaries ---------------------------------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"; : >"$DIGEST_SPOOL"
HBLOG="$TMP/hb.log"; : >"$HBLOG"
TYPED="$TMP/typed"; : >"$TYPED"
cmd_send() {
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"
}
audit_log() { return 0; }
_hb_log() { printf '%s\n' "$*" >>"$HBLOG"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  [[ "${a[0]:-}" == "-u" ]] && a=("${a[@]:2}")
  "${a[@]}"
}
systemctl() { return 0; }                          # every seat's unit is active
_hb_agent_idle() { return 0; }                     # the seat is idle: the old gate passes
_a2a_queue_dir() { printf '%s\n' "$TMP/agent-${1}/.5dive/a2a-queue"; }
inject_and_submit() { printf '%s\t%s\n' "$1" "$2" >>"$TYPED"; return 0; }
FLEET='{"agents":{"seat-a":{"heartbeat":{"enabled":true}}}}'
registry_read() { printf '%s' "$FLEET"; }
agent_type() { printf 'claude-code\n'; }
STARTED=$(( $(date +%s) - 600 ))                   # the seat started 10 min ago
seat_started_epoch() { printf '%s\n' "$STARTED"; }
export SEAT_TRANSCRIPT_ROOT="$TMP/tx" SEAT_STOP_STAMP_DIR="$TMP/stamps" HERMES_AGENT_DIR="$TMP/no-hermes"
mkdir -p "$SEAT_TRANSCRIPT_ROOT/proj" "$SEAT_STOP_STAMP_DIR"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# transcript <refusal-epoch|none>: a turn refused by the account at that time.
transcript() {
  local f="$SEAT_TRANSCRIPT_ROOT/proj/s.jsonl" t="$1"
  : >"$f"
  [[ "$t" == none ]] && t=$(( $(date +%s) - 60 ))
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n' "$(iso "$t")" >>"$f"
  if [[ "$1" == none ]]; then
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"done"}]}}\n' "$(iso "$((t+1))")" >>"$f"
  else
    printf '{"type":"assistant","timestamp":"%s","isApiErrorMessage":true,"error":"billing_error","message":{"content":[{"type":"text","text":"API Error: 402 This request would exceed your available credits"}]}}\n' "$(iso "$((t+1))")" >>"$f"
  fi
}
spool() { local d; d="$(_a2a_queue_dir seat-a)"; rm -rf "$d"; mkdir -p "$d"; printf 'peer says hi\n' >"$d/0001.msg"; }
spooled() { find "$(_a2a_queue_dir seat-a)" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' '; }
reset_a() { spool; : >"$TYPED"; : >"$HBLOG"; rm -f "$STATE_DIR"/a2a-spool-held.*; }
run_a() {
  reset_a
  _hb_a2a_queue_sweep
  A_LEFT=$(spooled); A_TYPED=$(wc -l <"$TYPED" | tr -d ' ')
  A_HELD=$(grep -c 'spool held' "$HBLOG"); A_DELIV=$(grep -c 'delivered 1 queued' "$HBLOG")
}

# --- A1 ------------------------------------------------------------------------
transcript "$(( $(date +%s) - 120 ))"
run_a
is "A1 refused turn after the seat's start: the .msg stays spooled" "1" "$A_LEFT"
is "A1 ...nothing is typed into the seat"                            "0" "$A_TYPED"
is "A1 ...the log says held"                                         "1" "$A_HELD"
is "A1 ...and never delivered"                                       "0" "$A_DELIV"
grep -q "seat-a: spool held, the seat's AI account refused its last turn (refused)" "$HBLOG" \
  && ok_t "A1 ...the held line names the seat and the class" || bad_t "A1 held line" "$(cat "$HBLOG")"
# A second tick on the same refusal holds again and does NOT log again.
: >"$HBLOG"; _hb_a2a_queue_sweep
is "A1 second tick: still spooled"                 "1" "$(spooled)"
is "A1 second tick: held logged once per refusal"  "0" "$(grep -c 'spool held' "$HBLOG")"

# --- A2 ------------------------------------------------------------------------
transcript "$(( STARTED - 300 ))"                  # refused BEFORE the seat (re)started
run_a
is "A2 refusal before the seat's start: delivered" "0" "$A_LEFT"
is "A2 ...typed once"                              "1" "$A_TYPED"
is "A2 ...logged delivered, not held"              "1:0" "${A_DELIV}:${A_HELD}"
transcript none
run_a
is "A2 no refusal at all: delivered"               "0:1:1" "${A_LEFT}:${A_TYPED}:${A_DELIV}"

# --- A3 ------------------------------------------------------------------------
transcript "$(( $(date +%s) - 120 ))"
(
  _a2a_spool_held() { return 1; }                  # MUTATION: the gate is dropped
  run_a
  [[ "$A_LEFT" == 1 && "$A_TYPED" == 0 && "$A_DELIV" == 0 ]] && exit 1 || exit 0
) && ok_t "A3 mutation: without the gate A1's fixture delivers into the refused seat (A1 goes red)" \
  || bad_t "A3 mutation stayed green: A1 does not grade the gate" ""

# --- B -------------------------------------------------------------------------
tasks_db_init
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE',NULL);"
FLEET='{"agents":{}}'                               # empty fleet: activity probe unavailable
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
clock() { db "SELECT value FROM task_prefs WHERE key='stall_first_seen_at';"; }
clock_age_min() { echo $(( ( $(date -u +%s) - $(date -u -d "$(clock)" +%s) ) / 60 )); }
reset_b() {
  db "DELETE FROM tasks; DELETE FROM loop_runs; DELETE FROM task_prefs;"
  : >"$SEND_LOG"; rm -f "$DIGEST_SPOOL" "$DIGEST_SPOOL.last"
  addt --assignee=bob -- "stranded todo" >/dev/null
  db "INSERT INTO task_prefs (key,value) VALUES ('stall_first_seen_at', datetime('now','-75 minutes'));"
}
moved_row() {   # closed 7 min ago with NO started_at (chill-gorge's DIVE-1092 shape)
  local m; m=$(addt --assignee=bob -- "closed between ticks")
  db "UPDATE tasks SET status='done', started_at=NULL, done_at=datetime('now','-7 minutes') WHERE id=${m};"
}
stall_sends() { grep -c 'fleet-stall' "$SEND_LOG"; }

reset_b; moved_row
_hb_stall_sweep >/dev/null 2>&1
is "B1 a row closed 7m ago (no started_at): no stall alert" "0" "$(stall_sends)"
age=$(clock_age_min)
[[ "$age" =~ ^[0-9]+$ ]] && (( age >= 6 && age <= 8 )) \
  && ok_t "B1 ...the clock moved to the row's close (~7m, read ${age}m)" \
  || bad_t "B1 clock did not move to the last row movement" "clock=$(clock) age=${age}m"

reset_b
_hb_stall_sweep >/dev/null 2>&1
grep -q 'idle 75m' "$SEND_LOG" \
  && ok_t "B2 no movement since the clock started: still alerts 'idle 75m'" \
  || bad_t "B2 negative control lost the alert" "$(cat "$SEND_LOG")"

(
  # MUTATION: _hb_stall_sweep with the clock move removed.
  eval "$(sed -n '/^_hb_stall_sweep() {/,/^}/p' "$SRC/cmd_heartbeat.sh" \
          | sed '/if \[\[ -n "\$_last_move" && "\$_last_move" > "\$first_seen" \]\]; then/,/^    fi$/d')"
  reset_b; moved_row
  _hb_stall_sweep >/dev/null 2>&1
  [[ "$(stall_sends)" == 0 ]] && exit 1 || exit 0
) && ok_t "B3 mutation: without the clock move B1's fixture alerts (B1 goes red)" \
  || bad_t "B3 mutation stayed green: B1 does not grade the clock move" ""

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
