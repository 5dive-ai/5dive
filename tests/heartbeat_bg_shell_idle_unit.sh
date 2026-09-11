#!/usr/bin/env bash
# DIVE-4298 unit harness: a finished turn with background shells alive is IDLE.
#
# Claude Code reports native status `busy` while ANY background shell it launched
# is still alive, including long after the turn ended. `_hb_agent_idle` used to
# return 1 on that word alone, so a seat whose turn was over read as mid-turn for
# as long as an orphaned child lived (measured 1h20m on quinn, 2026-09-11) and
# could take no task. These arms grade the three halves of the fix:
#   (a) the pane matchers tell a done status line from a spinner one;
#   (b) _hb_agent_idle classifies native-busy + done pane as IDLE, and
#       native-busy + mid-turn pane as BUSY;
#   (c) _hb_bg_shell_sweep asks the reaper after _HB_DONE_SHELL_REAP_TICKS ticks;
#   (d) MUTATION: restore "native busy is authoritative" and (b)'s first arm reds.
# Plus the lane-accounting half: a DELIVERED row is not actionable by its maker.
# Run: bash tests/heartbeat_bg_shell_idle_unit.sh   (no root, no network, no tmux)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- Fixtures: real `tmux capture-pane` shapes ---------------------------------
# DONE, with orphaned shells — the exact line lodar read on quinn at 08:12Z.
PANE_DONE=$(cat <<'PANE'
● Re-cutting the three mutation controls at main
  ⎿  $ bash tests/ask_cmd_wiring_unit.sh
     (12 lines)

✻ Worked for 9m 11s · done 8:09 AM · 2 shells still running

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  Opus 5 5h: 41% 7d: 52%
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
PANE
)
# DONE, no background shells left.
PANE_DONE_CLEAN=${PANE_DONE/ · 2 shells still running/}
# MID-TURN. Note the composer is ALSO an empty ❯ — Claude Code lets you type
# while it works, which is why the glyph alone can never be the discriminator.
PANE_BUSY=$(cat <<'PANE'
● Re-cutting the three mutation controls at main · 10s
  ⎿  $ cd /home/agent-quinn/wt-4277main && bash tests/ask_cmd_wiring_unit.sh
     echo … (10s · 8 lines)
     (ctrl+b ctrl+b (twice) to run in background)

✶ Spelunking… (1m 55s · ↓ 6.4k tokens)
  ⎿  Tip: Use /btw to ask a quick side question without interrupting Claude's current work

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  Opus 5 5h: 41% 7d: 52%
PANE
)
# A DONE line still on screen while a NEW turn runs: the status line is the
# spinner's, so "the string is somewhere in the pane" must not be enough.
PANE_BUSY_STALE_DONE=$(cat <<'PANE'
✻ Worked for 9m 11s · done 8:09 AM · 2 shells still running

● Picking up the next row
✶ Spelunking… (14s · ↓ 1.2k tokens)

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
PANE
)

# --- (a) pane matchers ---------------------------------------------------------
_hb_pane_turn_ended "$PANE_DONE"  && ok_t "done pane: turn ended" || bad_t "done pane read as mid-turn"
_hb_pane_turn_ended "$PANE_BUSY"  && bad_t "mid-turn pane read as done" || ok_t "mid-turn pane: still working"
_hb_pane_turn_ended "$PANE_BUSY_STALE_DONE" \
  && bad_t "a stale done line above a live spinner read as done" \
  || ok_t "stale done line above a live spinner: still working (status line, not substring)"
[[ "$(_hb_pane_bg_shells "$PANE_DONE")" == "2" ]] \
  && ok_t "done pane names 2 background shells" || bad_t "bg shell count" "got '$(_hb_pane_bg_shells "$PANE_DONE")'"
[[ -z "$(_hb_pane_bg_shells "$PANE_DONE_CLEAN")" ]] \
  && ok_t "clean done pane names no background shells" || bad_t "clean pane should name none" "got '$(_hb_pane_bg_shells "$PANE_DONE_CLEAN")'"

# --- (b) _hb_agent_idle classification ----------------------------------------
FIXTURE_PANE="$PANE_DONE"
_hb_pane_capture()       { printf '%s\n' "$FIXTURE_PANE"; }
_hb_agent_native_state() { printf 'busy'; }
_hb_claude_pid()         { printf '4242'; }
sleep()                  { :; }   # the byte-stability gap; the fixture never changes

_hb_agent_idle quinn 0; rc=$?
[[ $rc -eq 0 ]] && ok_t "native busy + done pane -> IDLE (rc 0)" || bad_t "native busy + done pane" "rc=$rc, want 0"
[[ "${_HB_IDLE_BG_SHELLS:-}" == "2" ]] \
  && ok_t "_HB_IDLE_BG_SHELLS=2 for the log line" || bad_t "_HB_IDLE_BG_SHELLS" "got '${_HB_IDLE_BG_SHELLS:-}'"

FIXTURE_PANE="$PANE_BUSY"
_hb_agent_idle quinn 0; rc=$?
[[ $rc -eq 1 ]] && ok_t "native busy + mid-turn pane -> BUSY (rc 1)" || bad_t "native busy + mid-turn pane" "rc=$rc, want 1"

FIXTURE_PANE="$PANE_DONE"
_hb_agent_native_state() { printf 'blocked:permission prompt'; }
_hb_agent_idle quinn 0; rc=$?
[[ $rc -eq 3 ]] && ok_t "blocked still wins over a done pane (rc 3)" || bad_t "blocked classification" "rc=$rc, want 3"
_hb_agent_native_state() { printf 'busy'; }

# --- (c) the reaper fires on the done line, not the active-defer counter -------
LOGGED=""
# The tick counter is FILE-backed, not a shell variable: the sweep reads it
# through `cnt=$(with_registry_lock _hb_mark_done_shells ...)`, i.e. inside a
# command substitution, so a variable increment would be lost in the subshell and
# the counter could never reach the threshold. In production this stub's place is
# taken by the registry, which is a file for the same reason.
TICKF=$(mktemp); printf '0' > "$TICKF"
with_registry_lock()   { "$@"; }
_hb_mark_done_shells() { local n; n=$(( $(cat "$TICKF") + 1 )); printf '%s' "$n" > "$TICKF"; printf '%s' "$n"; }
_hb_clear_done_shells(){ printf '0' > "$TICKF"; }
# File-backed for the same subshell reason: the sweep reads the reaper through
# `reaped=$(_reap_stale_shells ...)`.
REAPF=$(mktemp); : > "$REAPF"
_reap_stale_shells()   { printf '%s\n' "$*" >> "$REAPF"; printf '1'; }
reap_calls()  { grep -c . "$REAPF"; }
reap_reason() { cat "$REAPF"; }
_hb_log()              { LOGGED="${LOGGED}$1"$'\n'; }

FIXTURE_PANE="$PANE_DONE"
_hb_bg_shell_sweep quinn
[[ "$(reap_calls)" -eq 0 ]] && ok_t "tick 1 of done+shells: no reap yet (threshold ${_HB_DONE_SHELL_REAP_TICKS})" \
  || bad_t "reaped on the first tick" "calls=$(reap_calls)"
_hb_bg_shell_sweep quinn
[[ "$(reap_calls)" -eq 1 ]] && ok_t "tick 2 of done+shells: _reap_stale_shells called" \
  || bad_t "reaper not called at the threshold" "calls=$(reap_calls)"
grep -q 'DIVE-4298' <<<"$(reap_reason)" && ok_t "the reap names its reason" || bad_t "reap reason" "got '$(reap_reason)'"
grep -q 'background shell' <<<"$LOGGED" && ok_t "the tick log names the background shells" || bad_t "log line" "got '$LOGGED'"

_hb_clear_done_shells; : > "$REAPF"
FIXTURE_PANE="$PANE_BUSY"
_hb_bg_shell_sweep quinn; _hb_bg_shell_sweep quinn
[[ "$(reap_calls)" -eq 0 ]] && ok_t "a mid-turn pane is never swept" || bad_t "swept a working seat" "calls=$(reap_calls)"
_hb_clear_done_shells; : > "$REAPF"
FIXTURE_PANE="$PANE_DONE_CLEAN"
_hb_bg_shell_sweep quinn; _hb_bg_shell_sweep quinn
[[ "$(reap_calls)" -eq 0 ]] && ok_t "a done pane with no shells is never swept" || bad_t "swept a clean seat" "calls=$(reap_calls)"

# --- (d) MUTATION: restore "native busy is authoritative" ----------------------
# The arm that must red is (b)'s first one. Re-cut _hb_agent_idle's native case
# the way it shipped before this change and re-run that single classification.
_hb_agent_idle_mutant() {
  local name="$1"
  case "$(_hb_agent_native_state "$name")" in
    idle) return 0 ;;
    busy) return 1 ;;
  esac
  return 2
}
FIXTURE_PANE="$PANE_DONE"
_hb_agent_idle_mutant quinn; rc=$?
[[ $rc -eq 1 ]] && ok_t "MUTATION control: the old code reds arm (b) — done pane reads BUSY" \
  || bad_t "mutation control did not red" "rc=$rc — the arm does not grade the fix"

# --- lane accounting: a DELIVERED row is not actionable by its maker ----------
if command -v sqlite3 >/dev/null 2>&1; then
  TDB=$(mktemp -d)/t.db
  sqlite3 "$TDB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, assignee TEXT, kind TEXT,
      status TEXT, parked_at TEXT, handoff_delivered_at TEXT, handoff_rejected_at TEXT);
    INSERT INTO tasks (id,assignee,kind,status,parked_at,handoff_delivered_at,handoff_rejected_at) VALUES
      (1,'dev2','standard','todo',NULL,NULL,NULL),
      (2,'dev2','standard','in_progress',NULL,NULL,NULL),
      (3,'dev2','standard','in_progress',NULL,'2026-09-11 07:00:00',NULL),
      (4,'dev2','standard','in_progress',NULL,'2026-09-11 07:00:00','2026-09-11 06:00:00'),
      (5,'dev2','standard','in_progress',NULL,'2026-09-11 07:00:00','2026-09-11 08:00:00'),
      (6,'dev2','standard','done',NULL,NULL,NULL);" 2>/dev/null
  # Grade the SHIPPED predicate, extracted verbatim from src/task/routing.sh.
  WHERE=$(sed -n '/^_task_lane_actionable() {/,/^}/p' src/task/routing.sh \
          | sed -n '/SELECT COUNT/,/;"/p' | sed 's/\$(sqlq "\$1")/'"'"'dev2'"'"'/' \
          | sed 's/^ *db "//' | sed 's/;".*$/;/')
  n=$(sqlite3 "$TDB" "$WHERE" 2>/dev/null)
  # rows 1,2 actionable; 3 delivered-awaiting-grade; 4 delivered AFTER an older
  # reject (still with the verifier); 5 rejected back to the maker -> actionable.
  [[ "$n" == "3" ]] && ok_t "lane actionable = 3 (todo + in_progress + rejected-back; delivered rows excluded)" \
    || bad_t "lane actionable count" "got '$n', want 3 — predicate: $WHERE"
  rm -rf "$(dirname "$TDB")"
else
  ok_t "SKIP lane-actionable arm (no sqlite3)"
fi

rm -f "$TICKF" "$REAPF"
printf '\n%s\n' "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
