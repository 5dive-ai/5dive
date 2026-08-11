#!/usr/bin/env bash
# TIER: core — the gate CARD as a modelled object (DIVE-3228).
#
# WHAT THIS GRADES that gate_button_retire_unit.sh does not. That harness grades
# the RETIRE: which messages get touched, by whose token, behind which fence. This
# one grades the MODEL underneath it — the thing that made retire best-effort in
# the first place. A card used to exist only as a line in gate-notify.log, parsed
# back with awk, so nothing could answer "is this card still in that chat" without
# guessing. Every arm below is a question the log could not answer:
#
#   invariant   the partial unique index REFUSES a second live card per (task,chat)
#   mint        a confirmed human send records one; an agent-rail leg records none
#   die         a moot gate DELETES the card, and the row says so
#   receipt     a HUMAN answer STRIKES instead (their record must survive), and a
#               lead:* answer does NOT (they never acted — nothing of theirs to keep)
#   orphan      the delivering bot is gone -> nobody can edit it -> REPORTED, never
#               a silent success, because a live-looking phantom is the whole defect
#   self-heal   deleted out of band -> state=gone, not an error
#   no-retouch  a second retire over a dead card touches Telegram ZERO times
#
# Run: bash tests/gate_card_model_unit.sh   (no root, no network — all three Bot
# API primitives are stubbed; an unstubbed one is an outbound request, not a red).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-card-model.XXXXXX)

# The sourced set is an ARRAY, not a bare loop, because the egress arm at the
# bottom enumerates Bot API callers out of these SAME files. Two hand-maintained
# lists would drift, and the drift would show up as a harness that silently sends.
SRC_FILES=()
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
  SRC_FILES+=("$SRC/$f")
done
set +e

PASS=0; FAIL=0
chk() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fi
}

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506 positive allowlist: this harness drives the human-facing retire path,
# so it declares its ISOLATED db as prod. Nothing here can reach Telegram.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate >/dev/null 2>&1

CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
printf 'TELEGRAM_BOT_TOKEN=tok-marketing\n' >"$CONNECTORS_DIR/telegram-marketing.env"
# _task_gate_bot_token falls back to an AMBIENT $TELEGRAM_BOT_TOKEN when the named
# connector is missing. Inheriting one from the runner's environment would hand the
# orphan arms a token for a bot that does not exist and quietly turn "nobody can
# edit this card" into "edited with the wrong bot's token" — which is the DIVE-2073
# hazard, and here it would also make the arms pass for the wrong reason.
unset TELEGRAM_BOT_TOKEN

# All THREE egress points stubbed. DIVE-3228 added two beside the pre-existing
# one, and a harness that stubs a subset does not fail — it sends.
DELETES="$TMP/deletes"; TEXTS="$TMP/texts"; EDITS="$TMP/edits"
: >"$DELETES"; : >"$TEXTS"; : >"$EDITS"
DELETE_RESP='{"ok":true}'; TEXT_RESP='{"ok":true}'
_mirror_delete_message() { printf '%s|%s\n' "$2" "$3" >>"$DELETES"; printf '%s' "$DELETE_RESP"; }
_mirror_edit_text()      { printf '%s|%s|%s\n' "$2" "$3" "$4" >>"$TEXTS"; printf '%s' "$TEXT_RESP"; }
_mirror_edit_markup()    { printf '%s|%s\n' "$2" "$3" >>"$EDITS"; printf '%s' '{"ok":true}'; }
# The rest of the sourced modules' Bot API surface. Stubbed not because these arms
# call them, but because the egress arm below requires the surface to be CLOSED —
# see its comment for why a hand-list of "the ones we use" is the wrong shape.
_mirror_send()           { printf '%s' '{"ok":true,"result":{"message_id":1}}'; }
_gate_channel_api()      { printf '%s' '{"ok":true}'; }
reset_io() { : >"$DELETES"; : >"$TEXTS"; : >"$EDITS"; }
io_count() { cat "$DELETES" "$TEXTS" "$EDITS" 2>/dev/null | grep -c . ; }

mk_task() { # <ident> -> id
  db "INSERT INTO tasks (ident,title,status,need_type,tier,ask,ask_shape)
      VALUES ('$1','t','blocked','approval',1,'ship it?','ship it');" >/dev/null 2>&1
  db "SELECT id FROM tasks WHERE ident='$1';"
}
card_state() { db "SELECT state FROM gate_cards WHERE task_id=$1 ORDER BY id DESC LIMIT 1;"; }
live_n() { db "SELECT COUNT(*) FROM gate_cards WHERE task_id=$1 AND state='live';"; }

# ---------------------------------------------------------------- mint ------
TID=$(mk_task DIVE-C1)
_task_gate_card_record "DIVE-C1" "1234567890" "500" "marketing"
chk "mint: a confirmed human send records exactly one live card" "1" "$(live_n "$TID")"
chk "mint: it carries the DELIVERING bot, not the caller" "marketing" \
    "$(db "SELECT via FROM gate_cards WHERE task_id=$TID;")"

# An agent-rail leg is a handoff to an agent inbox, NOT a card in a human's chat.
# Recording one would make the digest's buzz count claim a phone rang when it did not.
_task_gate_card_record "DIVE-C1" "agent:main" "501" "marketing"
chk "mint: an agent-rail delivery records NO card" "1" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE task_id=$TID;")"
# A delivery with no resolvable bot cannot ever be edited, so it is not modelled
# as a live card — that would be minting a known-orphan.
_task_gate_card_record "DIVE-C1" "1234567890" "502" "none"
chk "mint: a delivery with no via records NO card" "1" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE task_id=$TID;")"

# The re-nag batches several gates into ONE message, so `tasks=` is a comma list
# and every ident in it needs its own card row pointing at that shared message.
# Exercises the comma split directly — the path where a botched IFS would either
# drop every card but the first or record one card named "DIVE-X,DIVE-Y".
TIDM1=$(mk_task DIVE-M1); TIDM2=$(mk_task DIVE-M2)
_task_gate_card_record "DIVE-M1,DIVE-M2" "999" "1500" "marketing"
chk "batched re-nag: each ident in the comma list gets its own card" "1 1" \
    "$(live_n "$TIDM1") $(live_n "$TIDM2")"
chk "batched re-nag: both point at the one message that was actually sent" "1500 1500" \
    "$(db "SELECT message_id FROM gate_cards WHERE task_id=$TIDM1;") $(db "SELECT message_id FROM gate_cards WHERE task_id=$TIDM2;")"
chk "batched re-nag: and no card is named after the whole list" "0" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE ident LIKE '%,%';")"

# ------------------------------------------------------------- invariant ----
# The index is the enforcement. A second send into the same chat must not be able
# to leave two live cards behind — that IS the four-DMs-in-three-minutes shape.
db "INSERT INTO gate_cards (task_id,ident,gate_epoch,chat_id,message_id,via,state)
    VALUES ($TID,'DIVE-C1',9,'1234567890','999','marketing','live');" >/dev/null 2>&1
chk "invariant: the DB REFUSES a second live card for one (task,chat)" "1" "$(live_n "$TID")"
# ...and the refusal is the INDEX, not luck: the same insert in another chat is fine.
db "INSERT INTO gate_cards (task_id,ident,gate_epoch,chat_id,message_id,via,state)
    VALUES ($TID,'DIVE-C1',9,'555','999','marketing','live');" >/dev/null 2>&1
chk "invariant: liveness — a DIFFERENT chat CAN hold its own live card" "2" "$(live_n "$TID")"
db "DELETE FROM gate_cards WHERE chat_id='555';" >/dev/null 2>&1

# The legitimate second send supersedes rather than being refused: a second
# message really IS in that chat, and a model tidier than reality is the defect.
_task_gate_card_record "DIVE-C1" "1234567890" "600" "marketing"
chk "mint: a genuine re-send supersedes the old card and stays single-live" "1" "$(live_n "$TID")"
chk "mint: and the live one is the NEW message" "600" \
    "$(db "SELECT message_id FROM gate_cards WHERE task_id=$TID AND state='live';")"
chk "mint: the displaced card is kept, marked superseded (the buzz it cost is real)" "1" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE task_id=$TID AND state='superseded';")"

# ------------------------------------------------------------------ die -----
reset_io
_task_gate_card_apply DIVE-C1 die "withdrawn by dev2"
chk "die: a moot gate DELETES the card" "1234567890|600" "$(cat "$DELETES")"
chk "die: and the row records it as deleted" "deleted" "$(card_state "$TID")"
chk "die: no live card remains" "0" "$(live_n "$TID")"

# NO RE-TOUCH. The old code re-read the log on every close, so a second retire
# re-edited a message already gone. Six call sites can fire over one gate.
reset_io
_task_gate_card_apply DIVE-C1 die "superseded by a re-filed gate"
chk "no-retouch: a second retire over a dead card touches Telegram ZERO times" "0" "$(io_count)"

# -------------------------------------------------------------- receipt -----
TID2=$(mk_task DIVE-C2)
_task_gate_card_record "DIVE-C2" "1234567890" "700" "marketing"
reset_io
_task_gate_card_apply DIVE-C2 settle "answered by human:lodar" "human:lodar"
chk "receipt: a HUMAN answer does NOT delete the card" "" "$(cat "$DELETES")"
chk "receipt: it strikes it instead" "1" "$(grep -c '1234567890|700' "$TEXTS")"
chk "receipt: and the row says struck, not deleted" "struck" "$(card_state "$TID2")"
# Main's ruling ii: a struck card must READ as a receipt. Present-tense phrasing
# on a card that has stopped tracking its row is the same lie as a phantom card.
chk "receipt: names the decision, past tense" "1" "$(grep -c 'answered' "$TEXTS")"
chk "receipt: says it is a receipt and no longer tracks the task" "1" \
    "$(grep -c 'receipt' "$TEXTS")"
chk "receipt: does NOT read as a live ask" "0" "$(grep -ci 'Resolve:' "$TEXTS")"

# A lead-clear is not a human acting. There is no record of theirs to preserve,
# so the card dies like any other moot gate.
TID3=$(mk_task DIVE-C3)
_task_gate_card_record "DIVE-C3" "1234567890" "800" "marketing"
reset_io
_task_gate_card_apply DIVE-C3 die "answered by lead:main" "lead:main"
chk "receipt: a lead:* answer DELETES (nobody human acted)" "1234567890|800" "$(cat "$DELETES")"

# --------------------------------------------------------------- orphan -----
# The delivering agent was torn down, so NO seat can edit this card. It is still
# in the chat. Reporting it is the point: a phantom nobody names is the defect.
TID4=$(mk_task DIVE-C4)
db "INSERT INTO gate_cards (task_id,ident,gate_epoch,chat_id,message_id,via,state)
    VALUES ($TID4,'DIVE-C4',1,'1234567890','900','ghostbot','live');" >/dev/null 2>&1
reset_io
out=$(_task_gate_card_apply DIVE-C4 die "withdrawn" 2>&1)
chk "orphan: no token for the delivering bot means NO Bot API call" "0" "$(io_count)"
chk "orphan: the card is marked orphaned, not quietly deleted" "orphaned" "$(card_state "$TID4")"
chk "orphan: and it WARNS (a live-looking phantom must be reported)" "1" \
    "$(grep -c 'cannot be edited by anyone' <<<"$out")"
chk "orphan: the row keeps why, for whoever reads it later" "1" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE id=(SELECT MAX(id) FROM gate_cards WHERE task_id=$TID4) AND last_error LIKE '%ghostbot%';")"

# ------------------------------------------------------------ self-heal -----
# They cleared their chat. Telegram says the message is not there. That is the end
# state, not a failure, and the next state change may mint a fresh card.
TID5=$(mk_task DIVE-C5)
_task_gate_card_record "DIVE-C5" "1234567890" "1000" "marketing"
DELETE_RESP='{"ok":false,"description":"Bad Request: message to delete not found"}'
reset_io
_task_gate_card_apply DIVE-C5 die "withdrawn"
chk "self-heal: an out-of-band delete reads as gone, not as an error" "gone" "$(card_state "$TID5")"
chk "self-heal: and it does NOT fall through to a text strike" "0" "$(grep -c . "$TEXTS")"
DELETE_RESP='{"ok":true}'

# ---------------------------------------------------- delete refused --------
# Past 48h Telegram refuses the delete. The card must still reach a dead state,
# via a visible strike, and the reason must be recorded rather than swallowed.
TID6=$(mk_task DIVE-C6)
_task_gate_card_record "DIVE-C6" "1234567890" "1100" "marketing"
DELETE_RESP='{"ok":false,"description":"Bad Request: message can'"'"'t be deleted"}'
reset_io
_task_gate_card_apply DIVE-C6 die "withdrawn"
chk "delete-refused: falls back to a visible strike" "1" "$(grep -c '1234567890|1100' "$TEXTS")"
chk "delete-refused: and the card ends struck, not left live" "struck" "$(card_state "$TID6")"
chk "delete-refused: the struck text says the gate is closed" "1" "$(grep -c 'closed' "$TEXTS")"
DELETE_RESP='{"ok":true}'

# ------------------------------------------------------ strike failure ------
# BOTH refused. This is the only shape that genuinely leaves a live-looking card,
# and it is the one that must report. A silent ok here is today's bug.
TID7=$(mk_task DIVE-C7)
_task_gate_card_record "DIVE-C7" "1234567890" "1200" "marketing"
DELETE_RESP='{"ok":false,"description":"Bad Request: message can'"'"'t be deleted"}'
TEXT_RESP='{"ok":false,"description":"Bad Request: chat not found"}'
reset_io
out=$(_task_gate_card_apply DIVE-C7 die "withdrawn" 2>&1)
chk "strike-failure: the card is NOT claimed retired" "live" "$(card_state "$TID7")"
chk "strike-failure: and it WARNS that the gate may still show" "1" \
    "$(grep -c 'may still read as a live gate' <<<"$out")"
DELETE_RESP='{"ok":true}'; TEXT_RESP='{"ok":true}'

# ----------------------------------------------------------- the fence ------
# Same rail as the send whose message it edits: a non-prod store makes ZERO calls.
TID8=$(mk_task DIVE-C8)
_task_gate_card_record "DIVE-C8" "1234567890" "1300" "marketing"
reset_io
( FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else.db" _task_gate_card_apply DIVE-C8 die "withdrawn" ) >/dev/null 2>&1
chk "fence: a non-prod store makes ZERO Bot API calls" "0" "$(io_count)"
# ...and the fence is not vacuous — the SAME input under the real store does act.
reset_io
_task_gate_card_apply DIVE-C8 die "withdrawn"
chk "fence: liveness — the same input under the prod store DOES delete" "1234567890|1300" "$(cat "$DELETES")"

# ------------------------------------------------------- egress surface -----
# SELF-ENFORCING, and that is the whole point (main, DIVE-3228). Re-stubbing the
# three primitives we know about fixes today and nothing else: the next person to
# add a fourth gets the same silent outbound request from a unit harness, and it
# still will not surface as a failing assertion. A hand-list under-counts BY
# CONSTRUCTION the moment someone adds to it — the same shape as a parity comment
# naming four forks when there were seven.
#
# So enumerate the surface out of the sourced modules themselves and require it to
# be CLOSED. Add a Bot API caller to cmd_task.sh or cmd_agent_runtime.sh and this
# arm goes red until it is stubbed here, without anyone remembering to update a list.
egress=$(awk '/^[_a-zA-Z][_a-zA-Z0-9]*\(\)[[:space:]]*\{/{fn=$1; sub(/\(\).*/,"",fn)}
              /api\.telegram\.org/{if(fn!="")print fn}' "${SRC_FILES[@]}" 2>/dev/null | sort -u)
# NON-VACUITY. Without this, a rename of the primitives (or an awk that stops
# matching) makes the arm above green forever while the surface is wide open —
# a check that passes because it found nothing is the failure mode being fixed.
chk "egress: the enumeration actually found Bot API callers (not vacuous)" "yes" \
    "$([[ "$(grep -c . <<<"$egress")" -ge 3 ]] && echo yes || echo no)"
unstubbed=""
while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  # A STUBBED function's live definition cannot still contain the endpoint. This
  # reads the definition in force RIGHT NOW, so it catches a stub that a later
  # section overwrote by re-sourcing — which is exactly how the near miss happened.
  if declare -f "$fn" 2>/dev/null | grep -q 'api\.telegram\.org'; then
    unstubbed="$unstubbed $fn"
  fi
done <<<"$egress"
chk "egress: EVERY Bot API caller in the sourced modules is stubbed" "" "$unstubbed"

printf -- '-----\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
