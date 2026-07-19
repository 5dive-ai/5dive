#!/usr/bin/env bash
# DIVE-1500: fixture harnesses must be physically unable to reach a paired
# human through the gate-notify send path. Unlike sibling tests this one does
# NOT stub _mirror_send — the guard under test lives inside the real one — and
# a curl trap proves no POST is ever attempted while FIVEDIVE_NOTIFY_DRYRUN is
# set (a 2026-07-19 render test DM'd the real owner via the live token).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/notify-dryrun.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"
ACCESS="$TMP/access.json"
printf '%s\n' '{"allowFrom":["999"],"groups":{"-1001":{"message_thread_id":42}}}' >"$ACCESS"
TASK_CH_TOKEN="fixture-secret-token" TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude
audit_log() { :; }

# Trap: ANY curl invocation from the notify path is a real-POST attempt — the
# incident class this guard closes. Record it; assertions fail on a non-empty log.
CURL_LOG="$TMP/curl-attempts"; : >"$CURL_LOG"
curl() { printf '%s\n' "$*" >>"$CURL_LOG"; return 7; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
mk_gate() {
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','codex','codex','standard','blocked','decision',2,'pick',datetime('now'));
      SELECT last_insert_rowid();"
}
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE id=$1;"; }

# --- dry-run ON: full owner-alert path, gate row, tap buttons ---------------
export FIVEDIVE_NOTIFY_DRYRUN=1
export FIVEDIVE_NOTIFY_DRYRUN_LOG="$TMP/dryrun.log"
gid=$(mk_gate DIVE-1)
_task_send_owner "fixture gate alert" '{"inline_keyboard":[[{"text":"A","callback_data":"tna:1:0"}]]}' "$gid" 2>/dev/null

[[ "$TASK_SEND_DELIVERED" == "1" ]] \
  && ok_t "dry-run send reports synthetic delivery" \
  || bad_t "dry-run send reports synthetic delivery" "TASK_SEND_DELIVERED=$TASK_SEND_DELIVERED"
[[ ! -s "$CURL_LOG" ]] \
  && ok_t "no real POST attempted under dry-run" \
  || bad_t "no real POST attempted under dry-run" "$(cat "$CURL_LOG")"
grep -q 'chat=999' "$FIVEDIVE_NOTIFY_DRYRUN_LOG" 2>/dev/null \
  && ok_t "would-be payload (chat) logged to dry-run log" \
  || bad_t "would-be payload (chat) logged to dry-run log" "$(cat "$FIVEDIVE_NOTIFY_DRYRUN_LOG" 2>/dev/null)"
grep -q 'markup=yes' "$FIVEDIVE_NOTIFY_DRYRUN_LOG" 2>/dev/null \
  && ok_t "reply_markup presence logged" \
  || bad_t "reply_markup presence logged"
grep -q 'fixture-secret-token' "$FIVEDIVE_NOTIFY_DRYRUN_LOG" 2>/dev/null \
  && bad_t "token must never appear in dry-run log" \
  || ok_t "token never appears in dry-run log"
[[ "$(pinged "$gid")" == "SET" ]] \
  && ok_t "downstream receipt logic still runs (gate_pinged_at stamped)" \
  || bad_t "downstream receipt logic still runs (gate_pinged_at stamped)" "$(pinged "$gid")"

# --- _mirror_post direct (the path DIVE-1499 tests don't stub) --------------
_mirror_post "fixture-secret-token" "999" "" "direct mirror" "$ACCESS" 2>/dev/null
[[ "$MIRROR_POST_DELIVERED" == "1" && ! -s "$CURL_LOG" ]] \
  && ok_t "_mirror_post honors dry-run, no POST" \
  || bad_t "_mirror_post honors dry-run, no POST" "delivered=$MIRROR_POST_DELIVERED curl=$(cat "$CURL_LOG")"

# --- truthiness: '0' is OFF, any other non-empty value is ON ----------------
resp=$(FIVEDIVE_NOTIFY_DRYRUN=true _mirror_send tok 123 "" hi "" 2>/dev/null)
[[ "$(jq -r '.dry_run // false' <<<"$resp" 2>/dev/null)" == "true" ]] \
  && ok_t "FIVEDIVE_NOTIFY_DRYRUN=true also engages the guard" \
  || bad_t "FIVEDIVE_NOTIFY_DRYRUN=true also engages the guard" "$resp"

# --- dry-run OFF: the real path must hit our curl trap (test not vacuous) ---
export FIVEDIVE_NOTIFY_DRYRUN=0
_task_send_owner "live-path probe" "" "" 2>/dev/null
[[ -s "$CURL_LOG" ]] \
  && ok_t "guard off: real send path attempts POST (trap caught it)" \
  || bad_t "guard off: real send path attempts POST (trap caught it)"
[[ "$TASK_SEND_DELIVERED" == "0" ]] \
  && ok_t "guard off + failed transport: not marked delivered" \
  || bad_t "guard off + failed transport: not marked delivered"
unset FIVEDIVE_NOTIFY_DRYRUN

# --- header.sh env-honor for the connector dir ------------------------------
got=$(env FIVEDIVE_CONNECTOR_DIR="$TMP/conn" bash -c 'source src/header.sh >/dev/null 2>&1; printf %s "$CONNECTORS_DIR"')
[[ "$got" == "$TMP/conn" ]] \
  && ok_t "FIVEDIVE_CONNECTOR_DIR overrides CONNECTORS_DIR" \
  || bad_t "FIVEDIVE_CONNECTOR_DIR overrides CONNECTORS_DIR" "got=$got"
got=$(env -u FIVEDIVE_CONNECTOR_DIR bash -c 'source src/header.sh >/dev/null 2>&1; printf %s "$CONNECTORS_DIR"')
[[ "$got" == "/etc/5dive/connectors" ]] \
  && ok_t "default CONNECTORS_DIR unchanged without override" \
  || bad_t "default CONNECTORS_DIR unchanged without override" "got=$got"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
