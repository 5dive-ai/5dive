#!/usr/bin/env bash
# DIVE-4413 — WHERE DID THE GATE GO, AND WHO CAN READ IT?
#
# Two defects from one customer report (2026-09-13), both in the frame between
# "a gate was delivered" and "the filer was told":
#
#   1. A stale last-human-chat.json whose messageThreadId is NULL beat a fresh
#      access.json groups.<chat>.message_thread_id, so the ping landed in a
#      supergroup's General topic while the operator had bound topic 200.
#      Measured on teal-fox: claude-swan's pointer written 2026-06-22, the
#      binding live, DIVE-501's gate delivered as message 4308 to General.
#   2. `task need` printed `OK — <id> needs a human (decision, tier 2)` and
#      nothing about the destination — on a box with zero `humans` rows, where
#      delivery is a BROADCAST over the whole allowlist. The delivery log knew
#      (it records MIRROR_POST_CHAT); the filer's terminal did not.
#
# Grading posture. The transport is stubbed at `_mirror_send` and NOWHERE ABOVE
# it: `cmd_task_need` -> `task_need_notify` -> `_task_send_gate_owner` ->
# `_task_send_owner` -> `_task_post_owner_target` -> `_mirror_post` all run for
# real, so the end-to-end arms grade the path this change actually edits rather
# than a paraphrase of it. `_task_agent_channel` is the one resolver replaced,
# because it reads /home/agent-*/ state no unit harness may have.
#
# THE RED ARM for defect 1 is A1 — on origin/main it sends with an EMPTY thread.
# THE RED ARM for defect 2 is A6/A7 — on origin/main the ok line carries no
# destination and no broadcast warning is printed at all.
#
# Run: bash tests/gate_destination_visibility_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-destination.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# ---------------------------------------------------------------- the SWITCH is a fixture
# OWN THE PRECONDITION, DO NOT INHERIT IT (quinn, iteration 1).
#
# PART 1(a)'s warning is gated on `_task_deployment_has_channels`, which globs
# ${CONNECTORS_DIR}/telegram-*.env — defaulted in src/header.sh to
# /etc/5dive/connectors, i.e. state written by whoever installed the MACHINE and
# by nothing in this file. On a paired dev seat that glob finds eight connector
# files and A8/A9 pass; on a GitHub runner it finds none and they go red. The
# red was the visible half. The WORSE half is A10, the DIVE-1955 no-wallpaper
# control ("the warning stops once a human is named"): with the switch off it
# passes VACUOUSLY, because the warning it claims to have silenced never fired.
# A host-read predicate moves a positive arm and its negative control in
# OPPOSITE directions and only one of those directions is visible, so the arm
# that still reads green is the one that stopped grading anything.
#
# So the switch is a fixture: one connector file in a tempdir this harness
# wrote, exported BEFORE header.sh resolves CONNECTORS_DIR, and asserted ON at
# A7c ahead of every arm that depends on it — the same shape A6 already uses for
# the empty humans registry. The value of the ambient FIVEDIVE_CONNECTOR_DIR is
# irrelevant after this line, which is the property: both `bash tests/…` on a
# paired box and the same command with the var pointed anywhere else are 14/0.
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR"
printf 'TELEGRAM_BOT_TOKEN=fixture-not-a-real-token\n' >"$FIVEDIVE_CONNECTOR_DIR/telegram-fixture.env"

# THE SWEEP (same shape, rest of the harness): every other switch these arms ride
# on is already written here — the humans registry and the gate-notifier tag are
# rows in this harness's own DB (asserted at A6), the access.json and the pointer
# are files it writes per arm, and the channel resolver is stubbed. The one
# remaining inheritable input is the hold window: A11/A12 need a tier-2 gate to
# be HELD and A7a/A7b need one SENT, and this harness sets that per arm, so an
# ambient export of it would decide both. Drop it rather than read it.
unset _5DIVE_GATE_UNDO_WINDOW_SECS

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506: this harness deliberately exercises the human-send path, so declare
# its isolated DB as the prod DB (positive allowlist) to pass the fail-closed
# fixture guard. Nothing here ever leaves the tempdir.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

CHDIR="$TMP/channels"; mkdir -p "$CHDIR"
ACCESS="$CHDIR/access.json"
PTR="$CHDIR/last-human-chat.json"
TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
_mirror_send() { # <token> <chat> <thread> <text> <markup>
  printf '%s|%s\n' "$2" "$3" >>"$SEND_LOG"
  printf '%s' '{"ok":true,"result":{"message_id":4308}}'
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

mk_gate() {
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked','decision',2,'pick',datetime('now'));
      SELECT last_insert_rowid();"
}

# ---------------------------------------------------------------- teal-fox shape
# access.json binds the group to topic 200; the pointer names the same group with
# messageThreadId null. Byte-for-byte the state read off claude-swan.
printf '%s\n' '{"dmPolicy":"pairing","allowFrom":["8315771142"],"groups":{"-1003797470983":{"message_thread_id":"200","allowFrom":[],"requireMention":false}}}' >"$ACCESS"
printf '%s\n' '{"chatId":"-1003797470983","messageThreadId":null}' >"$PTR"

: >"$SEND_LOG"
g1=$(mk_gate DIVE-D1)
_task_send_owner "needs you" "" "$g1" >/dev/null 2>&1
grep -q '^-1003797470983|200$' "$SEND_LOG" \
  && ok_t "A1 a NULL pointer thread falls back to the group's bound topic (RED on main: sends to General)" \
  || bad_t "A1 gate landed in the wrong room" "sends=$(tr '\n' ',' <"$SEND_LOG")"

[[ "${TASK_SEND_TARGETS:-}" == "-1003797470983:200" ]] \
  && ok_t "A2 TASK_SEND_TARGETS records chat AND topic" \
  || bad_t "A2 targets not recorded" "TASK_SEND_TARGETS='${TASK_SEND_TARGETS:-}'"

[[ "$(_task_send_targets_note)" == "chat -1003797470983, topic 200" ]] \
  && ok_t "A3 the receipt renders as prose a person can read" \
  || bad_t "A3 bad receipt prose" "$(_task_send_targets_note)"

# A pointer that DOES carry a thread is authoritative — the fallback must only
# fill an absence, never override an observed topic.
printf '%s\n' '{"chatId":"-1003797470983","messageThreadId":"7"}' >"$PTR"
: >"$SEND_LOG"
g2=$(mk_gate DIVE-D2)
_task_send_owner "needs you" "" "$g2" >/dev/null 2>&1
grep -q '^-1003797470983|7$' "$SEND_LOG" \
  && ok_t "A4 an explicit pointer thread still wins (no regression)" \
  || bad_t "A4 explicit pointer thread overridden" "sends=$(tr '\n' ',' <"$SEND_LOG")"

# The untopiced group is the one the customer called the wrong room: the preview
# must NAME that absence rather than print a bare chat id.
printf '%s\n' '{"dmPolicy":"pairing","allowFrom":[],"groups":{"-1009":{"allowFrom":[],"requireMention":false}}}' >"$ACCESS"
rm -f "$PTR"
_dest=$(_task_legacy_owner_destinations "$ACCESS")
[[ "$_dest" == *"group -1009"* && "$_dest" == *"lands in General"* ]] \
  && ok_t "A5 the broadcast preview names a group with NO topic bound" \
  || bad_t "A5 preview hid the missing topic" "$_dest"

# ------------------------------------------------------- end-to-end through need
# Only the channel resolver is replaced (it reads /home/agent-*/ state a unit
# harness has no access to). Everything from cmd_task_need down is the real path.
_task_agent_channel() { TASK_CH_TOKEN=x; TASK_CH_ACCESS="$ACCESS"; TASK_CH_TYPE=claude; return 0; }
_task_owner_channel() { _task_agent_channel ""; }
printf '%s\n' '{"dmPolicy":"pairing","allowFrom":["8315771142"],"groups":{"-1003797470983":{"message_thread_id":"200","allowFrom":[],"requireMention":false}}}' >"$ACCESS"
printf '%s\n' '{"chatId":"-1003797470983","messageThreadId":null}' >"$PTR"

db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-901','a customer flow decision','high','dev','dev','standard','todo');"
[[ "$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null || echo 0)" == "0" ]] \
  && ok_t "A6 precondition: zero human accounts, so delivery takes the legacy broadcast path" \
  || bad_t "A6 precondition broken — the registry is not empty" "$(db "SELECT COUNT(*) FROM humans;")"

: >"$SEND_LOG"
# _5DIVE_GATE_UNDO_WINDOW_SECS=0 puts this gate on the IMMEDIATE path, where a
# real send happens inside the call and the OK line can carry a RECEIPT.
out=$(_5DIVE_GATE_UNDO_WINDOW_SECS=0 cmd_task_need DIVE-901 --type=decision --ask="pick one" 2>"$TMP/e901.err")
err=$(<"$TMP/e901.err")
grep -q '^-1003797470983|200$' "$SEND_LOG" \
  && ok_t "A7a the gate really went out, into the bound topic, through the unstubbed send path" \
  || bad_t "A7a no send reached the transport" "sends=$(tr '\n' ',' <"$SEND_LOG")"
grep -q 'delivered to chat -1003797470983, topic 200' <<<"$out" \
  && ok_t "A7b the ok line names WHERE the ping landed (RED on main: no destination at all)" \
  || bad_t "A7b filer was not told the destination" "out=$out"
_task_deployment_has_channels \
  && ok_t "A7c precondition: this deployment HAS a channel, so the broadcast warning's switch is provably ON (fixture, not the box)" \
  || bad_t "A7c precondition broken — no telegram-*.env in the fixture connector dir" "CONNECTORS_DIR=$CONNECTORS_DIR contents=$(ls -A "$CONNECTORS_DIR" 2>&1 | tr '\n' ' ')"
grep -q 'no human accounts on this box' <<<"$err" && grep -q 'BROADCAST' <<<"$err" \
  && ok_t "A8 an empty humans registry warns that the ask is readable by everyone on that chat" \
  || bad_t "A8 no broadcast warning" "err=$err"
grep -q '5dive human add' <<<"$err" \
  && ok_t "A9 the warning names the remedy, not just the problem" \
  || bad_t "A9 warning has no remedy" "err=$err"

# A resolved registry must go SILENT — a warning that fires where nothing is
# unresolved is wallpaper (DIVE-1955), and this one's whole job is onboarding.
db "INSERT INTO humans (id,display_name) VALUES ('lodar','lodar');" 2>/dev/null \
  || db "INSERT INTO humans (id) VALUES ('lodar');" 2>/dev/null
if [[ "$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null || echo 0)" -gt 0 ]]; then
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
      VALUES ('DIVE-902','another decision','high','dev','dev','standard','todo');"
  cmd_task_need DIVE-902 --type=decision --ask="pick one" >/dev/null 2>"$TMP/e902.err"
  grep -q 'no human accounts on this box' "$TMP/e902.err" \
    && bad_t "A10 the broadcast warning must stop once a human is named" "$(<"$TMP/e902.err")" \
    || ok_t "A10 the broadcast warning stops once a human is named (not wallpaper)"
else
  bad_t "A10 could not seed a humans row — arm did not run" "humans table shape changed"
fi

# The HELD path — tier 2, the only tier whose ping rings a phone, so the shape
# the customer actually hit. No send happens inside the call, so the OK line must
# carry a PLAN and must not claim a delivery that has not occurred yet. On a
# re-nag loop a stale receipt from the previous gate would surface here as a
# confident wrong chat, which is why TASK_SEND_TARGETS is reset per gate.
db "DELETE FROM humans;" 2>/dev/null
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-903','a spend decision','high','dev','dev','standard','todo');"
: >"$SEND_LOG"
out3=$(cmd_task_need DIVE-903 --type=decision --tier=2 --ask="pick one" 2>"$TMP/e903.err")
if [[ -s "$SEND_LOG" ]]; then
  bad_t "A11 precondition: a tier-2 gate must be HELD, not sent inside the call" "sends=$(tr '\n' ',' <"$SEND_LOG")"
else
  grep -q 'delivered to' <<<"$out3" \
    && bad_t "A11 a held gate must NOT claim a delivery that has not happened" "out=$out3" \
    || ok_t "A11 a held gate does not claim a delivery"
  grep -q 'held by the undo window' <<<"$out3" && grep -q 'topic 200' <<<"$out3" \
    && ok_t "A12 a held gate names the destination it WILL go to (RED on main: silent)" \
    || bad_t "A12 held gate gave the filer no destination" "out=$out3"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
