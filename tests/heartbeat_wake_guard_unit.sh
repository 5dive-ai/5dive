#!/usr/bin/env bash
# DIVE-1475 isolated unit harness for the _hb_wake status guard.
#
# The heartbeat tick's picker only ever hands _hb_wake a live todo, but the
# direct `heartbeat wake-task` verb (and any looping/buggy caller — e.g. a test
# harness walking ascending ids against the live host) can pass a done,
# cancelled, or nonexistent id. Without a guard every such call injects a bogus
# /goal into a real agent pane (the 2026-07-19 "dispatcher walking low ids blind
# to status" incident). This exercises the guard on a throwaway tasks.db with the
# pane-injection + systemd calls stubbed — never touches a live pane or the shared
# board. Asserts: a todo still injects its /goal; a done/cancelled/nonexistent/
# non-numeric id injects NOTHING and logs a skip.
# Run: bash tests/heartbeat_wake_guard_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-wakeguard-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; asserts below deliberately probe states

tasks_db_init

INJECTED="$TMP/injected"; : >"$INJECTED"
LOG="$TMP/log"; : >"$LOG"

# --- Stubs: keep _hb_wake hermetic (no systemd, no tmux, no live pane) --------
systemctl()        { return 0; }                       # is-active --quiet -> active, skip start
sudo()             { return 0; }                        # `sudo -u agent tmux has-session` -> ok
sleep()            { :; }
_hb_send_line()    { printf '%s\n' "$2" >>"$INJECTED"; return 0; }   # record injected text
_hb_log()          { printf '%s\n' "$*" >>"$LOG"; }
_hb_recall_cite()  { echo ""; }                         # skip memory search
_hb_is_knowledge_task() { return 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk() {  # mk <title> <status> -> row id
  local title="$1" status="${2:-todo}"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$title"), '', 'medium', 'main', 'main', 'standard', $(sqlq "$status"));
      SELECT last_insert_rowid();"
}

injected_count() { grep -c '/goal Task' "$INJECTED" 2>/dev/null || true; }  # grep -c prints 0 + exits 1 on no match; || true swallows the exit without a second line

# --- Case 1: a real todo still injects its /goal (guard must not regress) ------
T=$(mk "live todo" todo)
before=$(injected_count)
_hb_wake main false "$T" "DIVE-$T" >/dev/null 2>&1
after=$(injected_count)
if (( after == before + 1 )) && grep -q "/goal Task DIVE-$T " "$INJECTED"; then
  ok_t "todo id=$T injects its /goal (guard lets actionable work through)"
else
  bad_t "todo must still inject /goal" "before=$before after=$after id=$T"
fi

# --- Case 2: a done task injects NOTHING and logs a skip -----------------------
D=$(mk "already done" done)
before=$(injected_count)
_hb_wake main false "$D" "DIVE-$D" >/dev/null 2>&1
after=$(injected_count)
if (( after == before )) && grep -q "wake skipped — DIVE-$D is done" "$LOG"; then
  ok_t "done id=$D injects no /goal + logs skip"
else
  bad_t "done task must not inject" "before=$before after=$after id=$D; log: $(tail -1 "$LOG")"
fi

# --- Case 3: a cancelled task injects NOTHING ---------------------------------
C=$(mk "cancelled" cancelled)
before=$(injected_count)
_hb_wake main false "$C" "DIVE-$C" >/dev/null 2>&1
after=$(injected_count)
(( after == before )) && ok_t "cancelled id=$C injects no /goal" \
                      || bad_t "cancelled task must not inject" "before=$before after=$after"

# --- Case 4: a nonexistent id injects NOTHING (the DIVE-1 case) ----------------
before=$(injected_count)
_hb_wake main false 999999 "DIVE-999999" >/dev/null 2>&1
after=$(injected_count)
if (( after == before )) && grep -q "wake skipped — DIVE-999999 is nonexistent" "$LOG"; then
  ok_t "nonexistent id injects no /goal + logs skip (the DIVE-1 case)"
else
  bad_t "nonexistent id must not inject" "before=$before after=$after; log: $(tail -1 "$LOG")"
fi

# --- Case 5: a non-numeric id injects NOTHING (defensive) ---------------------
before=$(injected_count)
_hb_wake main false "not-a-number" "DIVE-x" >/dev/null 2>&1
after=$(injected_count)
(( after == before )) && ok_t "non-numeric id injects no /goal" \
                      || bad_t "non-numeric id must not inject" "before=$before after=$after"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
