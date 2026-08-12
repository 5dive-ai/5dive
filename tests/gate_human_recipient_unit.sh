#!/usr/bin/env bash
# DIVE-3342: a gate's human recipient is the person who may CLEAR it — never
# whoever last DM'd the bot, and never "everyone in allowFrom".
#
# THE FIXTURE IS THE POINT. The reported defect cannot be reproduced on a
# single-human box: with one id in allowFrom, the last-human-chat pointer and the
# broadcast fallback both resolve to that one person and every assertion passes on
# the OLD code. So this harness runs a TWO-human fixture (chat 1234567890 and
# 111000111) where the last-DM pointer names the human who is NOT an allowed
# clearer of the gate, and asserts that human is not messaged. Arm 1 is that
# negative control; it is the arm that fails on origin/main.
#
# Run: bash tests/gate_human_recipient_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null` — that hardening would swallow the helper's
# own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-human.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh \
         task/routing.sh task/notify.sh cmd_task.sh; do
  source "$SRC/$f" 2>/dev/null || source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506: this harness exercises the human-send path, so declare its isolated
# DB as the prod DB (positive allowlist) to pass the fail-closed fixture guard.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

# Reserved fakes only (CLAUDE.md): telegram ids are the documented 1234567890
# shape, never a real chat.
CHAT_CLEARER=1234567890      # the human who owns the gate's reviewer
CHAT_BYSTANDER=111000111     # paired to the same bot, owns nothing
CHAT_THIRD=1234500003        # a third paired human, named only by an explicit stamp
ACCESS="$TMP/access.json"
printf '%s\n' "{\"allowFrom\":[\"${CHAT_CLEARER}\",\"${CHAT_BYSTANDER}\",\"${CHAT_THIRD}\"],\"groups\":{\"-1001\":{\"message_thread_id\":42}}}" >"$ACCESS"
# The last-DM pointer names the BYSTANDER — exactly the state the customer box was
# in, written by ordinary inbound traffic and not by anything about the gate.
printf '%s\n' "{\"chatId\":\"${CHAT_BYSTANDER}\"}" >"$TMP/last-human-chat.json"
TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
_mirror_send() {
  printf '%s\n' "$2" >>"$SEND_LOG"
  printf '%s' '{"ok":true,"result":{"message_id":777}}'
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
audit_log() { :; }
warn() { printf 'warn: %s\n' "$*" >>"$TMP/warns"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
sends() { tr '\n' ',' <"$SEND_LOG"; }
# The delivery log backslash-escapes spaces in `detail=`, so a multi-word phrase
# has to be matched against the unescaped text — grepping the raw line silently
# never matches, which would make every "recorded the reason" arm vacuous.
logged() { tr -d '\\' <"$FIVEDIVE_GATE_NOTIFY_LOG" | grep -q "$1"; }

mk_gate() { # <ident> <filer> [reviewer]
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at,gate_filed_by,routed_reviewer)
      VALUES ($(sqlq "$1"),'gate','high',$(sqlq "$2"),$(sqlq "$2"),'standard','blocked','decision',1,'pick',datetime('now'),$(sqlq "$2"),$(sqlq "${3:-}"));
      SELECT last_insert_rowid();"
}
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE id=$1;"; }

# ---------------------------------------------------------------- registry OFF
# Before anything else: with no human accounts the delivery path must be its
# pre-DIVE-3342 self. Every host today is a single-human host and this arm is what
# stops the fix from being a silent behaviour change for all of them. It is also
# the anti-deletion arm: "always refuse unless a human is linked" would pass every
# arm below and break every live box.
g0=$(mk_gate DIVE-H0 dev3 main)
_task_send_gate_owner "legacy" "" "$g0"
if grep -qx "$CHAT_BYSTANDER" "$SEND_LOG" && [[ "$TASK_SEND_DELIVERED" == "1" ]]; then
  ok_t "empty registry keeps the legacy pointer path (delivers to the last-DM chat)"
else
  bad_t "empty registry must not change behaviour" "sends=$(sends) delivered=$TASK_SEND_DELIVERED"
fi

# ----------------------------------------------------------------- registry ON
db "INSERT INTO humans (id,display_name,telegram_id) VALUES ('clearer','Clearer','${CHAT_CLEARER}');
    INSERT INTO humans (id,display_name,telegram_id) VALUES ('bystander','Bystander','${CHAT_BYSTANDER}');
    INSERT INTO humans (id,display_name,telegram_id) VALUES ('third','Third','${CHAT_THIRD}');
    INSERT INTO agents_org (name) VALUES ('main');
    INSERT INTO agents_org (name,reports_to) VALUES ('dev3','main');
    INSERT INTO human_agents (human_id,agent) VALUES ('clearer','main');"

# ARM 1 — THE NEGATIVE CONTROL. Two humans on one bot; the pointer names the
# bystander; the gate's reviewer (main) is owned by the clearer. The bystander
# must not be messaged, and this is the assertion that fails before the fix.
: >"$SEND_LOG"
g1=$(mk_gate DIVE-H1 dev3 main)
_task_send_gate_owner "who clears this" "" "$g1"
if grep -qx "$CHAT_CLEARER" "$SEND_LOG" && ! grep -qx "$CHAT_BYSTANDER" "$SEND_LOG"; then
  ok_t "gate goes to the reviewer's human owner, NOT the last-DM pointer's human"
else
  bad_t "recipient came from bot traffic, not from who may clear" "sends=$(sends)"
fi
[[ "$(pinged "$g1")" == "SET" ]] \
  && ok_t "a delivered gate still stamps its receipt" \
  || bad_t "receipt not stamped" "pinged=$(pinged "$g1")"

# ARM 2 — the stamped owner is the record and beats live re-resolution. A chart
# edit after filing must not move a live gate to a different person.
: >"$SEND_LOG"
g2=$(mk_gate DIVE-H2 dev3 main)
# 'third' is neither what the pointer names (bystander) nor what the resolver would
# pick (clearer, via reviewer main) — so this arm cannot pass by coincidence.
db "UPDATE tasks SET human_owner='third' WHERE id=${g2};"
_task_send_gate_owner "stamped" "" "$g2"
grep -qx "$CHAT_THIRD" "$SEND_LOG" && ! grep -qx "$CHAT_CLEARER" "$SEND_LOG" && ! grep -qx "$CHAT_BYSTANDER" "$SEND_LOG" \
  && ok_t "an explicitly stamped owner wins over the resolver" \
  || bad_t "stamped owner ignored" "sends=$(sends)"

# ARM 3 — NO BROADCAST. Nobody owns this gate's clearers (unlinked agents, and two
# humans on record so the sole-human arm is off): it must reach NOBODY and say why,
# rather than paging both people the way the allowFrom fan-out did.
: >"$SEND_LOG"
g3=$(mk_gate DIVE-H3 loner)
_task_send_gate_owner "unowned" "" "$g3"
if [[ ! -s "$SEND_LOG" && "$TASK_SEND_DELIVERED" != "1" && "$TASK_SEND_FAILED" == "1" ]]; then
  ok_t "an unresolved recipient is NOT broadcast to the allowlist"
else
  bad_t "unresolved gate reached somebody" "sends=$(sends) delivered=$TASK_SEND_DELIVERED failed=$TASK_SEND_FAILED"
fi
[[ "$(pinged "$g3")" == "NULL" ]] \
  && ok_t "an undelivered gate leaves its receipt unstamped (stays on the agent rail)" \
  || bad_t "undelivered gate stamped as pinged" "pinged=$(pinged "$g3")"
logged "no human owns this gate's clearers" \
  && ok_t "the delivery log records WHY nobody was paged" \
  || bad_t "silent non-delivery" "$(tr '\n' ' ' <"$FIVEDIVE_GATE_NOTIFY_LOG")"

# ARM 4 — a record is an IDENTITY, not a grant. The owner resolves, but their chat
# is not in THIS bot's allowFrom: hold it, never substitute whoever is.
: >"$SEND_LOG"
db "INSERT INTO humans (id,display_name,telegram_id) VALUES ('offbot','Off Bot','1234509876');
    INSERT INTO agents_org (name) VALUES ('quinn');
    INSERT INTO human_agents (human_id,agent) VALUES ('offbot','quinn');"
g4=$(mk_gate DIVE-H4 quinn quinn)
_task_send_gate_owner "not paired here" "" "$g4"
if [[ ! -s "$SEND_LOG" ]] && logged 'not paired to this bot'; then
  ok_t "an owner absent from allowFrom is held, not swapped for whoever is present"
else
  bad_t "registry widened the audience" "sends=$(sends)"
fi

# ARM 5 — a mixed-owner BATCH is refused rather than delivered to everyone in it.
# The rendered text already names every row, so "send it to each owner" would page
# each person with the others' gates — the reported harm, one layer up.
: >"$SEND_LOG"
g5=$(mk_gate DIVE-H5 dev3 main)
db "UPDATE tasks SET human_owner='bystander' WHERE id=${g5};"
g6=$(mk_gate DIVE-H6 dev3 main)
_task_send_gate_owner "batch" "" "${g5},${g6}"
if [[ ! -s "$SEND_LOG" ]] && logged 'batch spans more than one human owner'; then
  ok_t "a batch spanning two owners is refused, not sent to both"
else
  bad_t "mixed batch delivered" "sends=$(sends)"
fi
# ...and the partition helper is what lets a caller re-render it per owner.
part=$(_human_gate_ids_by_owner "${g5},${g6}" | tr '\n' ';')
[[ "$part" == *"bystander	${g5};"* && "$part" == *"clearer	${g6};"* ]] \
  && ok_t "_human_gate_ids_by_owner splits the batch by person" \
  || bad_t "partition wrong" "$part"

# ARM 6 — the sole-human arm. One person on record is the only possible clearer, so
# a link is ceremony there; with two rows it must stay off (arm 3 proves that).
: >"$SEND_LOG"
db "DELETE FROM human_agents; DELETE FROM humans WHERE id<>'clearer';"
g7=$(mk_gate DIVE-H7 nobody)
_task_send_gate_owner "sole" "" "$g7"
grep -qx "$CHAT_CLEARER" "$SEND_LOG" \
  && ok_t "a one-person registry resolves without an explicit link" \
  || bad_t "sole-human arm did not fire" "sends=$(sends)"
_human_gate_recipient "$g7" >/dev/null
[[ "$HUMAN_RECIPIENT_ID" == "clearer" && "$HUMAN_RECIPIENT_BASIS" == "sole human on record" ]] \
  && ok_t "the basis names the arm that answered" \
  || bad_t "basis wrong" "$HUMAN_RECIPIENT_BASIS"

printf -- '-----\ngate_human_recipient_unit: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
