#!/usr/bin/env bash
# DIVE-5960: two update-night restart defects in the heartbeat tick.
#
# A. AN OFF-ROSTER SEAT NEVER TOOK ITS OWED RESTART. Claude Code reports native
#    "busy" while any background shell lives. The DIVE-4298 stray-shell reaper ran
#    only inside the heartbeat roster loop, so a seat with no heartbeat block and
#    one forgotten shell read busy to `_pending_restart_sweep` forever (teal-fox
#    seat-c: owed 120h, an 11-day-old `diff <(pandoc …)` shell, the overdue line
#    290 times a day). The tick's pending-restart pass now hands each owed seat
#    to `_hb_bg_shell_sweep` before `_pending_restart_sweep` reads busy. The reap
#    lives in cmd_heartbeat, NOT in the sweep: cmd_selfupdate is loaded by every
#    command, and a heartbeat reference from it pulled 4 modules into `whoami`.
# B. THE POLLER SWEEP FALSE-ALARMED A SEAT RESTARTED MID-SWEEP. `now` was read
#    once before a ~7s loop, so a unit that entered active after it had a
#    "future" stamp, no uptime, no restart grace, and its unlinked beacon read
#    "no beacon (poller never started)". The clock is now read per seat, after
#    the stamp.
#
# Arms (numbers are the row's acceptance criteria):
#   A1  off-roster seat, done pane + "1 shell still running" for the reaper's
#       tick threshold, owed restart: the shell is reaped by PID, the restart
#       fires, and no heartbeat block is created on the seat
#   A2  NEGATIVE: the same seat with its shell under FIVEDIVE_KEEP_ALIVE=1, and
#       again with a shell younger than the reaper's grace age: nothing reaped,
#       no restart, the overdue line stays
#   A3  NEGATIVE: a mid-turn pane (spinner) is not reaped and not restarted
#   A4  a roster seat swept by the pending-restart pass is not swept again by
#       the per-seat loop in the same tick
#   A5  cmd_selfupdate.sh names neither the reaper nor its tick threshold, so the
#       lazy loader's dep scan adds no edge from it into cmd_heartbeat
#   AM  MUTANT: the pre-fix pass (no reaper call) leaves A1's seat unrestarted
#   B4  AET 2s after the sweep's start, no beacon: no alarm (inside 120s grace)
#   B5  NEGATIVE: AET genuinely in the future of the per-seat clock still alarms
#   B6  NEGATIVE: active for 300s with no beacon still alarms "no beacon"
#   BM  MUTANT: the once-per-sweep clock re-reds B4
#
# Stubs: the pane, `claude agents --json` (via _hb_agent_native_state), the seat's
# process table, cgroups, kill, systemctl, the board (db), date for B. The real
# _hb_pending_restart_reap, _pending_restart_sweep, _hb_bg_shell_sweep, _reap_stale_shells, _hb_agent_idle,
# registry and _hb_poller_liveness_sweep run. No root, no network, no tmux.
#
#   bash tests/update_night_restart_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/update-night-restart.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/reap.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_pairing.sh cmd_supervisor.sh cmd_agent_runtime.sh cmd_heartbeat.sh \
         cmd_selfupdate.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$STATE_DIR/agents.json"; CONNECTORS_DIR="$TMP/connectors"; JSON_MODE=0
PENDING_RESTART_DIR="$TMP/pending"
mkdir -p "$TASKS_DIR" "$CONNECTORS_DIR" "$PENDING_RESTART_DIR"
IN_REGISTRY_LOCK=1   # the real registry_read/write on the temp file, no flock/root
chown() { :; }       # registry_write hands the file to root:claude; not ours to do here

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }
_hb_log() { printf '%s\n' "$*" >> "$TMP/hb.log"; }

# ============================ A. the owed restart ============================
SEAT=cee
UNIT="5dive-agent@${SEAT}.service"
PANE_DONE=$(cat <<'PANE'
✻ Worked for 2m 4s · done 3:12 PM · 1 shell still running

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
PANE
)
PANE_BUSY=$(cat <<'PANE'
● Answering the owner on Telegram · 10s
✶ Spelunking… (1m 55s · ↓ 6.4k tokens)

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
PANE
)
FIXTURE_PANE="$PANE_DONE"
SHELL_CMD=""; SHELL_AGE=0
_hb_pane_capture()       { printf '%s\n' "$FIXTURE_PANE"; }
_hb_claude_pid()         { printf '4242'; }
_agent_dispatcher_turn_state() { return 1; }
db()   { echo 0; }                 # the board: no in_progress row (seat-c, last close 10d ago)
sqlq() { printf "'%s'" "$1"; }
sleep() { :; }
id()   { [[ "${1:-}" == -u ]] && { printf '1001\n'; return 0; }; command id "$@"; }
shell_alive() { [[ -n "$SHELL_CMD" ]] && ! grep -qx 5151 "$TMP/killed" 2>/dev/null; }
# Claude Code: busy while the session is mid-turn OR any background shell lives.
_hb_agent_native_state() {
  if ! _hb_pane_turn_ended "$FIXTURE_PANE" || shell_alive; then printf busy; else printf idle; fi
}
_reap_seat_table() {
  printf '4242\t1\t999999\t/home/agent-%s/.local/bin/claude --dangerously-skip-permissions\n' "$SEAT"
  shell_alive && printf '5151\t4242\t%s\t%s\n' "$SHELL_AGE" "$SHELL_CMD"
  return 0
}
_REAP_UNIT_CGROUP_CMD=_t_unit_cg; _t_unit_cg() { printf '/system.slice/%s' "$1"; }
_REAP_CGROUP_CMD=_t_pid_cg;       _t_pid_cg()  { printf '0::/system.slice/%s\n' "$UNIT"; }
kill() {
  case "$1" in
    -0) grep -qx "$2" "$TMP/killed" 2>/dev/null && return 1; return 0 ;;
    -TERM|-KILL) printf '%s\n' "$2" >> "$TMP/killed" ;;
  esac
}
systemctl() {
  case "$1" in
    is-active) return 0 ;;
    show) printf 'Mon 2026-09-29 00:00:00 UTC\n' ;;
    restart) printf '%s\n' "$2" >> "$TMP/restarts" ;;
  esac
}

# scenario <registry-json> <shell cmd> <shell age s> <pane>
scenario() {
  printf '%s\n' "$1" > "$REGISTRY"
  SHELL_CMD="$2"; SHELL_AGE="$3"; FIXTURE_PANE="$4"
  rm -f "$TMP/killed" "$TMP/restarts" "$TMP/hb.log" "$PENDING_RESTART_DIR"/*
  printf 'marked_at=%s\nreason=telegram plugin 0.5.92\n' "$(( $(command date +%s) - 120*3600 ))" \
    > "$PENDING_RESTART_DIR/$SEAT"
}
sweep() { _hb_pending_restart_reap; _pending_restart_sweep; }   # the tick's order (A5 pins it)
restarted() { grep -qxF "$UNIT" "$TMP/restarts" 2>/dev/null; }
reaped()    { grep -qx 5151 "$TMP/killed" 2>/dev/null; }
hblog()     { cat "$TMP/hb.log" 2>/dev/null; }
OFF_ROSTER='{"agents":{"cee":{"type":"claude","desiredState":"running"}}}'
STRAY='/bin/bash -c diff <(pandoc a.md) <(pandoc b.md) | head -30'
ELEVEN_DAYS=950400

# --- A1: the off-roster seat is reaped, then bounced -------------------------
scenario "$OFF_ROSTER" "$STRAY" "$ELEVEN_DAYS" "$PANE_DONE"
sweep
! reaped && ! restarted && has "$(hblog)" "STILL not idle" \
  && ok_t "A1a: tick 1 — below the reaper's ${_HB_DONE_SHELL_REAP_TICKS}-tick threshold: nothing reaped, overdue line logged" \
  || bad_t "A1a: tick 1" "reaped=$(reaped && echo y) restarted=$(restarted && echo y) log: $(hblog)"
cnt=$(jq -r '.agents.cee.doneShells.n // "none"' "$REGISTRY")
[[ "$(jq -r '.agents.cee.heartbeat // "none"' "$REGISTRY")" == none && "$cnt" == 1 ]] \
  && ok_t "A1b: the done-shell tick is counted at .agents.cee.doneShells, no heartbeat block created" \
  || bad_t "A1b: counter location" "$(cat "$REGISTRY")"
sweep; t2=$(restarted && echo y)
sweep
reaped && has "$(hblog)" "reaped 1 stale agent shell" \
  && ok_t "A1c: tick 2 — the 11-day-old stray shell (pid 5151) is reaped by PID" \
  || bad_t "A1c: the stray shell was not reaped" "log: $(hblog)"
restarted && has "$(hblog)" "bouncing for the deferred payload update" \
  && ok_t "A1d: the owed restart fires once the shell is gone (tick 2: ${t2:-n}, by tick 3: y)" \
  || bad_t "A1d: the owed restart never fired" "log: $(hblog)"
[[ ! -f "$PENDING_RESTART_DIR/$SEAT" ]] && [[ "$(jq -r '.agents.cee | has("heartbeat") or has("doneShells")' "$REGISTRY")" == false ]] \
  && ok_t "A1e: the marker is cleared and the seat's registry entry is left as it was found" \
  || bad_t "A1e: leftovers" "marker=$(ls "$PENDING_RESTART_DIR") reg=$(cat "$REGISTRY")"

# --- A2: the reaper's own guards still decide what dies ----------------------
scenario "$OFF_ROSTER" '/bin/bash -c FIVEDIVE_KEEP_ALIVE=1 npm run watch' "$ELEVEN_DAYS" "$PANE_DONE"
sweep; sweep; sweep
! reaped && ! restarted && has "$(hblog)" "STILL not idle" \
  && ok_t "A2a: NEGATIVE — a FIVEDIVE_KEEP_ALIVE=1 shell is not reaped, the seat is not restarted, the overdue line stays" \
  || bad_t "A2a: keep-alive shell" "reaped=$(reaped && echo y) restarted=$(restarted && echo y) log: $(hblog)"
scenario "$OFF_ROSTER" "$STRAY" $(( _REAP_MIN_AGE_DEFAULT - 60 )) "$PANE_DONE"
sweep; sweep; sweep
! reaped && ! restarted && has "$(hblog)" "STILL not idle" \
  && ok_t "A2b: NEGATIVE — a shell younger than the ${_REAP_MIN_AGE_DEFAULT}s grace age is not reaped, the seat is not restarted" \
  || bad_t "A2b: young shell" "reaped=$(reaped && echo y) restarted=$(restarted && echo y) log: $(hblog)"

# --- A3: a mid-turn seat (a row-less Telegram turn) is left alone ------------
scenario "$OFF_ROSTER" "$STRAY" "$ELEVEN_DAYS" "$PANE_BUSY"
sweep; sweep; sweep
! reaped && ! restarted && has "$(hblog)" "STILL not idle" \
  && ok_t "A3: NEGATIVE — a mid-turn pane is neither reaped nor restarted (native busy is never read as idle)" \
  || bad_t "A3: mid-turn seat" "reaped=$(reaped && echo y) restarted=$(restarted && echo y) log: $(hblog)"

# --- A4: one sweep per seat per tick -------------------------------------------
scenario '{"agents":{"cee":{"type":"claude","heartbeat":{"enabled":true}}}}' "$STRAY" "$ELEVEN_DAYS" "$PANE_DONE"
sweep
has "${_PR_BG_SWEPT:-}" " cee " && [[ "$(jq -r '.agents.cee.heartbeat.doneShells.n' "$REGISTRY")" == 1 ]] \
  && ok_t "A4a: a roster seat's tick is counted under its heartbeat block, and the pass records it as swept" \
  || bad_t "A4a: roster seat" "swept='${_PR_BG_SWEPT:-}' reg=$(cat "$REGISTRY")"
LOOPLINE=$(grep -nE '^ +\[\[ " \$\{_PR_BG_SWEPT:-\} " == \*" \$\{name\} "\* \]\] \|\| _hb_bg_shell_sweep "\$name" \|\| true$' "$SRC/cmd_heartbeat.sh")
BARE=$(awk '/^cmd_heartbeat_tick\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh" | grep -cE '^ +_hb_bg_shell_sweep "\$name" \|\| true$')
[[ -n "$LOOPLINE" && "$BARE" == 0 ]] \
  && ok_t "A4b: the per-seat loop skips a seat the pending-restart pass already swept (no double tick)" \
  || bad_t "A4b: per-seat loop guard" "guarded='$LOOPLINE' unguarded=$BARE"

# --- A5: the reap stays out of the module every command loads -----------------
_a5=$(grep -A1 -E '^  _hb_pending_restart_reap \|\| true$' "$SRC/cmd_heartbeat.sh" || true)
! grep -nE '_hb_bg_shell_sweep|_HB_DONE_SHELL_REAP_TICKS|_PR_BG_SWEPT' "$SRC/cmd_selfupdate.sh" >/dev/null \
  && grep -qE '^  _pending_restart_sweep \|\| _hb_log ' <<<"$_a5" \
  && ok_t "A5: cmd_selfupdate.sh names no reaper token, and the tick reaps on the line before its sweep" \
  || bad_t "A5: reaper reference in cmd_selfupdate.sh, or the tick does not reap right before the sweep" \
       "$(grep -nE '_hb_bg_shell_sweep|_HB_DONE_SHELL_REAP_TICKS|_PR_BG_SWEPT' "$SRC/cmd_selfupdate.sh")"

# --- AM: MUTANT — the pre-fix pass -------------------------------------------
eval "$(awk '/^_hb_pending_restart_reap\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh" \
  | sed -e 's/^    _hb_bg_shell_sweep "\$name" || true$/    :/')"
has "$(declare -f _hb_pending_restart_reap)" '_hb_bg_shell_sweep "$name"' \
  && bad_t "AM0: (anchor) the mutation did not land" "the sed pattern no longer matches src/cmd_heartbeat.sh" \
  || ok_t "AM0: (anchor) the reaper call is gone from the evaluated pass"
scenario "$OFF_ROSTER" "$STRAY" "$ELEVEN_DAYS" "$PANE_DONE"
sweep; sweep; sweep
! reaped && ! restarted \
  && ok_t "AM1: MUTANT (pre-fix): A1's seat keeps its shell and is never restarted — A1 goes red" \
  || bad_t "AM1: mutant must strand the seat" "reaped=$(reaped && echo y) restarted=$(restarted && echo y)"
eval "$(awk '/^_hb_pending_restart_reap\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")"

# ===================== B. the poller sweep's per-seat clock ==================
unset -f systemctl kill sleep
T0=1791593753   # the sweep's start
seat_dir="$TMP/home/agent-alpha/.claude/channels/telegram"
mkdir -p "$seat_dir"
printf '{"dmPolicy":"allowlist","allowFrom":["1234567890"]}\n' > "$seat_dir/access.json"
printf 'TELEGRAM_BOT_TOKEN=tok-alpha\n' > "$CONNECTORS_DIR/telegram-alpha.env"
_tg_access_state_dir() { printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2"; }
_task_resolve_coordinator() { printf ''; }
_gate_channel_api() { printf '%s\n' "$*" >> "$TMP/api.log"; }
cmd_send() { :; }
AET_EPOCH=0
systemctl() { case "$1" in is-active) return 0 ;; show) printf '@%s\n' "$AET_EPOCH" ;; esac; }
# The first `date +%s` is the sweep's own; every later one is 3s on — the seat
# was 24th in a 7s loop. `date -d @N +%s` resolves through the real binary.
date() {
  if [[ "${1:-}" == +%s ]]; then
    if [[ -f "$TMP/clock.started" ]]; then echo $(( T0 + 3 )); else : > "$TMP/clock.started"; echo "$T0"; fi
  else command date "$@"; fi
}
ptick() { # <aet epoch>
  AET_EPOCH="$1"
  rm -f "$TMP/clock.started" "$TMP/hb.log" "$TMP/api.log" "$STATE_DIR/poller-liveness.alarmed" "$seat_dir/bot.heartbeat"
  _hb_poller_liveness_sweep
}
printf '{"agents":{"alpha":{"type":"claude"}}}\n' > "$REGISTRY"

ptick $(( T0 + 2 ))
! has "$(hblog)" "DEAD" && [[ ! -s "$TMP/api.log" ]] \
  && ok_t "B4: a unit that entered active 2s after the sweep started, beacon unlinked: no alarm (inside the 120s grace)" \
  || bad_t "B4: restarted-mid-sweep seat alarmed" "log: $(hblog) api: $(cat "$TMP/api.log" 2>/dev/null)"
ptick $(( T0 + 600 ))
has "$(hblog)" "DEAD: alpha: no beacon (poller never started)" \
  && ok_t "B5: NEGATIVE — a stamp in the future of the per-seat clock (real skew) still gets no grace and alarms" \
  || bad_t "B5: skewed stamp was graced" "log: $(hblog)"
ptick $(( T0 - 300 ))
has "$(hblog)" "DEAD: alpha: no beacon (poller never started)" \
  && ok_t "B6: NEGATIVE — a unit active for 300s with no beacon still alarms 'no beacon'" \
  || bad_t "B6: long-active beaconless seat did not alarm" "log: $(hblog)"

eval "$(awk '/^_hb_poller_liveness_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh" \
  | sed -e 's/^    seat_now=\$(date +%s)$/    seat_now=$now/')"
has "$(declare -f _hb_poller_liveness_sweep)" 'seat_now=$now' \
  && ok_t "BM0: (anchor) the once-per-sweep clock is back in the evaluated sweep" \
  || bad_t "BM0: (anchor) mutation did not land" "the sed pattern no longer matches src/cmd_heartbeat.sh"
ptick $(( T0 + 2 ))
has "$(hblog)" "DEAD: alpha: no beacon (poller never started)" \
  && ok_t "BM1: MUTANT (one clock per sweep): B4's seat alarms 'no beacon' — the teal-fox false page, B4 goes red" \
  || bad_t "BM1: mutant must reproduce the false alarm" "log: $(hblog)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
