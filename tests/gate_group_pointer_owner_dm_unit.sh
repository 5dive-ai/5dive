#!/usr/bin/env bash
# DIVE-8803 — a gate goes to the owner's DM, not to a group the agent sits in.
#
# The telegram plugin moves last-human-chat.json on every accepted human message,
# in a DM or an allowlisted group, from ANY group member. _task_send_owner took a
# group pointer at its word, so the last word from anyone in a group carried the
# owner's gate and its buttons there (2026-11-19: a client's question for her
# owner posted to the group she had been added to).
#
# The rule graded here: a group pointer is honoured only when access.json makes
# that group the owner's room (a bound topic: home-channel or a forum seat) or
# when there is no owner DM at all. Otherwise the send takes the DM path.
#
# The transport is stubbed at `_mirror_send` and nowhere above it, so
# _task_send_gate_owner -> _task_send_owner -> _task_post_owner_target ->
# _mirror_post all run for real.
#
# RED on origin/main: B1, B2, B3, B5 (the gate and the preview name the group).
# Run: bash tests/gate_group_pointer_owner_dm_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-group-pointer.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR"
unset _5DIVE_GATE_UNDO_WINDOW_SECS

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

CHDIR="$TMP/channels"; mkdir -p "$CHDIR"
ACCESS="$CHDIR/access.json"
PTR="$CHDIR/last-human-chat.json"
TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude

SEND_LOG="$TMP/sends"
FAIL_CHAT=""
_mirror_send() { # <token> <chat> <thread> <text> <markup>
  printf '%s|%s\n' "$2" "$3" >>"$SEND_LOG"
  if [[ -n "$FAIL_CHAT" && "$2" == "$FAIL_CHAT" ]]; then
    printf '%s' '{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}'
  else
    printf '%s' '{"ok":true,"result":{"message_id":7}}'
  fi
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
sends() { tr '\n' ',' <"$SEND_LOG"; }

mk_gate() {
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked','decision',2,'pick',datetime('now'));
      SELECT last_insert_rowid();"
}

OWNER=5501234567
GROUP=-1002222333444

# Precondition: the humans registry is empty, so the gate path delegates to
# _task_send_owner (every partner box today). Without it B1-B3 grade nothing.
_human_registry_active \
  && bad_t "B0 precondition: humans registry must be empty" \
  || ok_t "B0 precondition: humans registry empty, gate path goes through _task_send_owner"

# ---------------------------------------------------------------- the report
# Owner in allowFrom, a plain (non-forum) group the owner added the agent to,
# and the pointer moved there by a group member's message.
printf '%s\n' "{\"dmPolicy\":\"allowlist\",\"allowFrom\":[\"$OWNER\"],\"groups\":{\"$GROUP\":{\"requireMention\":true,\"allowFrom\":[]}}}" >"$ACCESS"
printf '%s\n' "{\"chatId\":\"$GROUP\",\"messageThreadId\":null}" >"$PTR"

: >"$SEND_LOG"
g1=$(mk_gate DIVE-G1)
_task_send_gate_owner "needs you" "" "$g1" >/dev/null 2>&1
[[ "$(sends)" == "$OWNER|," ]] \
  && ok_t "B1 group pointer, owner DM exists: the gate goes to the owner's DM only (RED on main: the group)" \
  || bad_t "B1 gate went to the wrong chat" "sends=$(sends)"

[[ "${TASK_SEND_TARGETS:-}" == "$OWNER" && "${TASK_SEND_DELIVERED:-0}" == "1" ]] \
  && ok_t "B2 the receipt names the DM and the send is confirmed" \
  || bad_t "B2 wrong receipt" "targets='${TASK_SEND_TARGETS:-}' delivered='${TASK_SEND_DELIVERED:-}'"

_dest=$(_task_legacy_owner_destinations "$ACCESS")
[[ "$_dest" == *"DM $OWNER"* && "$_dest" != *"last chat this bot was talked to in"* ]] \
  && ok_t "B3 the filer's preview names the DM, not the group (RED on main)" \
  || bad_t "B3 preview still names the pointer group" "dest='$_dest'"

# The pointer's chat is unchanged on disk: the send ignores it, it does not edit it.
[[ "$(jq -r .chatId "$PTR")" == "$GROUP" ]] \
  && ok_t "B4 the pointer file is left as the plugin wrote it" \
  || bad_t "B4 pointer was rewritten" "$(cat "$PTR")"

# ---------------------------------------------------------------- no regressions
# A DM that fails still falls back to the groups (the pre-existing recovery surface).
FAIL_CHAT=$OWNER
: >"$SEND_LOG"
g2=$(mk_gate DIVE-G2)
_task_send_gate_owner "needs you" "" "$g2" >/dev/null 2>&1
[[ "$(sends)" == "$OWNER|,$GROUP|," ]] \
  && ok_t "B5 a blocked owner DM still falls back to the group (unchanged)" \
  || bad_t "B5 fallback changed" "sends=$(sends)"
FAIL_CHAT=""

# A group-only bot (no owner DM): the group is all there is, the pointer is kept.
printf '%s\n' "{\"dmPolicy\":\"allowlist\",\"allowFrom\":[],\"groups\":{\"$GROUP\":{\"requireMention\":true,\"allowFrom\":[]}}}" >"$ACCESS"
: >"$SEND_LOG"
g3=$(mk_gate DIVE-G3)
_task_send_gate_owner "needs you" "" "$g3" >/dev/null 2>&1
[[ "$(sends)" == "$GROUP|," ]] \
  && ok_t "B6 no owner DM: the group pointer still delivers (unchanged)" \
  || bad_t "B6 group-only bot lost its gate" "sends=$(sends)"

# A group bound to a topic is a declared owner room (home-channel, forum seat):
# the pointer wins over the DM, exactly as DIVE-4413 left it.
printf '%s\n' "{\"dmPolicy\":\"allowlist\",\"allowFrom\":[\"$OWNER\"],\"groups\":{\"$GROUP\":{\"message_thread_id\":\"200\",\"requireMention\":false,\"allowFrom\":[]}}}" >"$ACCESS"
: >"$SEND_LOG"
g4=$(mk_gate DIVE-G4)
_task_send_gate_owner "needs you" "" "$g4" >/dev/null 2>&1
[[ "$(sends)" == "$GROUP|200," ]] \
  && ok_t "B7 a group bound to a topic still takes the gate in that topic (unchanged)" \
  || bad_t "B7 declared home channel lost" "sends=$(sends)"
_dest=$(_task_legacy_owner_destinations "$ACCESS")
[[ "$_dest" == "chat $GROUP, topic 200 (last chat this bot was talked to in)" ]] \
  && ok_t "B8 the preview for a bound topic is unchanged" \
  || bad_t "B8 preview changed" "dest='$_dest'"

# A DM pointer is untouched.
printf '%s\n' "{\"chatId\":\"$OWNER\",\"messageThreadId\":null}" >"$PTR"
: >"$SEND_LOG"
g5=$(mk_gate DIVE-G5)
_task_send_gate_owner "needs you" "" "$g5" >/dev/null 2>&1
[[ "$(sends)" == "$OWNER|," ]] \
  && ok_t "B9 a DM pointer still sends to that DM (unchanged)" \
  || bad_t "B9 DM pointer changed" "sends=$(sends)"

# A pointer to a chat that is not allowlisted at all is still ignored.
printf '%s\n' '{"chatId":"-100999","messageThreadId":null}' >"$PTR"
: >"$SEND_LOG"
g6=$(mk_gate DIVE-G6)
_task_send_gate_owner "needs you" "" "$g6" >/dev/null 2>&1
[[ "$(sends)" != *"-100999"* ]] \
  && ok_t "B10 a pointer to a chat not in access.json is still ignored" \
  || bad_t "B10 unallowed pointer was used" "sends=$(sends)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
