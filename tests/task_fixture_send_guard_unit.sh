#!/usr/bin/env bash
# DIVE-1506: fail-closed fixture-send guard. Proves the DIVE-1500 bar on the two legs it missed —
# a gate alert (task_need_notify) and an /inbox digest (_task_inbox_send) can NEVER reach a paired
# human from a non-prod (e2e/fixture) task DB, and STILL work from the prod DB. This is the leg that
# leaked: council_gate_e2e's `task need` DM'd fixture gates (dive1-4) to lodar because the DB was
# isolated but the send path was not. The guard is a POSITIVE prod-DB allowlist (blocklists rot).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/fixture-guard.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

ACCESS="$TMP/access.json"
printf '{"allowFrom":["433634012"]}' >"$ACCESS"

# Resolve a (fake) owner channel so the ONLY thing standing between a send and the human is the
# guard — not a missing channel. The real _task_send_owner runs (NOT stubbed); we stub the layer
# BELOW it (_task_post_owner_target) to RECORD any real send attempt, so a recorded send == a leak.
_task_owner_channel() { TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS"; return 0; }
require_root() { return 0; }  # isolate the fixture guard from the (separate) root requirement
SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
_task_post_owner_target() { # record the attempt + report delivered, like a live send would
  printf '%s\n' "${7:-$2}" >>"$SEND_LOG"
  TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="901"
}
nsends() { local n; n=$(wc -l < "$SEND_LOG" 2>/dev/null); printf '%s' "${n//[[:space:]]/}"; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# A filed gate to notify on (direct insert — the cmd_* helpers exit on success).
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at)
    VALUES ('DIVE-3','fixture gate','high','dev','dev','standard','blocked','decision',2,'ship it?','A|B','A',datetime('now'));" >/dev/null 2>&1
gid="DIVE-3"

# ---- 1) NON-PROD DB (default): the human send is REFUSED, fail-closed ---------------------------
unset FIVEDIVE_PROD_TASKS_DB
_task_human_send_allowed; rc=$?
[[ "$rc" != "0" ]] && ok "guard: a non-prod TASKS_DB is NOT allowed to send to a human" || no "guard allowed a non-prod DB (leak)"

: >"$SEND_LOG"; TASK_SEND_DELIVERED=0; TASK_SEND_FAILED=0
_task_send_owner "fixture digest" "" "$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$gid");")"
[[ "$(nsends)" == "0" && "$TASK_SEND_DELIVERED" == "0" && "$TASK_SEND_FAILED" == "1" ]] \
  && ok "_task_send_owner: NO send reaches the human from a fixture DB (delivered=0, failed=1)" \
  || no "_task_send_owner leaked from a fixture DB (nsends=$(nsends) delivered=$TASK_SEND_DELIVERED)"

: >"$SEND_LOG"
task_need_notify "$gid" decision "ship it?" "A|B" "A" >/dev/null 2>&1
[[ "$(nsends)" == "0" ]] \
  && ok "task_need_notify: fixture gate never DMs the human (the leaked leg — now closed)" \
  || no "task_need_notify leaked a fixture gate to the human (nsends=$(nsends))"

out=$(_task_inbox_send "433634012" "need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')" "created_at" 2>&1); rc=$?
[[ "$rc" != "0" && "$out" == *"1506"* ]] \
  && ok "task inbox --send: refuses on a fixture DB with a clear DIVE-1506 message" \
  || no "inbox --send did not fail-closed on a fixture DB (rc=$rc out=$out)"

# ---- 2) PROD-declared DB: the same sends WORK (guard is an allowlist, not a global off-switch) ---
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
_task_human_send_allowed; rc=$?
[[ "$rc" == "0" ]] && ok "guard: the declared prod TASKS_DB IS allowed to send" || no "guard blocked the prod DB (would break real gates)"

: >"$SEND_LOG"; TASK_SEND_DELIVERED=0; TASK_SEND_FAILED=0
_task_send_owner "prod digest" "" "$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$gid");")"
[[ "$(nsends)" == "1" && "$TASK_SEND_DELIVERED" == "1" ]] \
  && ok "_task_send_owner: a real gate on the prod DB still reaches the human" \
  || no "guard broke the legitimate prod send path (nsends=$(nsends) delivered=$TASK_SEND_DELIVERED)"

# ---- 3) explicit test opt-out forces refuse even IF the path looked prod (belt-and-suspenders) --
COUNCIL_MOCK=1 _task_human_send_allowed; rc=$?
[[ "$rc" != "0" ]] && ok "guard: COUNCIL_MOCK forces refuse regardless of DB path" || no "COUNCIL_MOCK did not force refuse"
FIVEDIVE_NO_HUMAN_SEND=1 _task_human_send_allowed; rc=$?
[[ "$rc" != "0" ]] && ok "guard: FIVEDIVE_NO_HUMAN_SEND forces refuse" || no "FIVEDIVE_NO_HUMAN_SEND did not force refuse"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
