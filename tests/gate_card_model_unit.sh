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

# DIVE-3228 — DO NOT WRITE TO THE REAL FLEET AUDIT LOG.
# `_task_store_audit_log` is fenced on STORE IDENTITY, and this harness declares
# its own fixture DB as prod (the DIVE-1506 allowlist, needed to drive the
# human-facing path at all) — so that fence reads TRUE here and every audit row
# lands in /var/log/5dive/agent-audit.log for real. Measured: an earlier cut of
# this suite put 235 fixture rows (DIVE-C5..C8) into the production audit log,
# which is the exact DIVE-1968 contamination a whole ticket was spent removing.
# Stubbing `audit_log` is the established isolation (see gate_answer_audit_unit),
# and the offset arm below proves it holds rather than assuming it.
_REAL_AUDIT_BASE=/var/log/5dive/agent-audit.log
_MINE_AUDIT_BEFORE=0
[[ -r "$_REAL_AUDIT_BASE" ]] && _MINE_AUDIT_BEFORE=$(grep -c 'task=DIVE-C[0-9]' "$_REAL_AUDIT_BASE" 2>/dev/null || echo 0)
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

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

# ------------------------------------------------- unreadable (DIVE-9345) ---
# A standard seat closes a gate whose card went out on ANOTHER live seat's bot.
# The connector file exists but this uid may not read it (root:claude-keys 0640 on
# a box). That is not a torn-down agent: the card must stay live and go to root.
# Root ignores file modes, so under a root runner the unreadable file is modelled
# by the token reader instead — the arm still grades the hand-off, not chmod.
printf 'TELEGRAM_BOT_TOKEN=tok-ceo\n' >"$CONNECTORS_DIR/telegram-ceo.env"
chmod 000 "$CONNECTORS_DIR/telegram-ceo.env"
if [[ $EUID -eq 0 ]]; then
  eval "$(declare -f _task_gate_bot_token | sed '1s/_task_gate_bot_token/_real_task_gate_bot_token/')"
  _task_gate_bot_token() { [[ "${1:-}" == ceo ]] && return 0; _real_task_gate_bot_token "$@"; }
fi
eval "$(declare -f _gate_is_root | sed '1s/_gate_is_root/_real_gate_is_root/')"
_gate_is_root() { return 1; }
HANDOFF="$TMP/handoff"; : >"$HANDOFF"; HANDOFF_RC=0; HANDOFF_ERR=""
_task_gate_card_root_retire() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$HANDOFF"; printf '%s' "$HANDOFF_ERR"; return "$HANDOFF_RC"; }
TID9=$(mk_task DIVE-C9)
_task_gate_card_record "DIVE-C9" "1234567890" "3474" "ceo"
# The caller's OWN bot token in its env must not stand in for ceo's: a message id
# edited through the wrong bot reads "not found" and would mark a live card gone.
export TELEGRAM_BOT_TOKEN=tok-caller
DELETE_RESP='{"ok":false,"description":"Bad Request: message to delete not found"}'
reset_io; : >"$AUDIT_CALLS"
out=$(_task_gate_card_apply DIVE-C9 die "withdrawn" 2>&1)
unset TELEGRAM_BOT_TOKEN
DELETE_RESP='{"ok":true}'
chk "unreadable: no Bot API call from this seat (not even with its own env token)" "0" "$(io_count)"
chk "unreadable: the card is NOT marked orphaned — it stays live" "live" "$(card_state "$TID9")"
chk "unreadable: the retire is handed to root, once, with the task and mode" "DIVE-C9|die|withdrawn" "$(cat "$HANDOFF")"
chk "unreadable: the hand-off is audited on the privileged path" "1" \
    "$(grep -c 'gate card retire ok .*path=privileged-retire' "$AUDIT_CALLS")"
chk "unreadable: and NOTHING calls it gone" "0" "$(grep -c 'cannot be edited by anyone' <<<"$out")"

# The root side failed (an old box without the sudoers line, say). The card still
# stays LIVE — a later pass can retire it — and the miss is reported, not swallowed.
TID10=$(mk_task DIVE-C10)
_task_gate_card_record "DIVE-C10" "1234567890" "3475" "ceo"
: >"$HANDOFF"; HANDOFF_RC=1; HANDOFF_ERR="sudo: a password is required"
reset_io; : >"$AUDIT_CALLS"
out=$(_task_gate_card_apply DIVE-C10 die "withdrawn" 2>&1)
HANDOFF_RC=0; HANDOFF_ERR=""
chk "hand-off failed: the card stays live, never orphaned" "live" "$(card_state "$TID10")"
chk "hand-off failed: the row says why" "1" \
    "$(db "SELECT COUNT(*) FROM gate_cards WHERE task_id=$TID10 AND last_error LIKE '%root retire failed%password%';")"
chk "hand-off failed: an error audit row" "1" "$(grep -c 'gate card retire error .*path=privileged-retire' "$AUDIT_CALLS")"
chk "hand-off failed: and a warn" "1" "$(grep -c 'root-side retire failed' <<<"$out")"

# The torn-down case through the SAME non-root caller: no file, no seat user ->
# still orphaned, and root is NOT asked (it could not do better).
TID11=$(mk_task DIVE-C11)
db "INSERT INTO gate_cards (task_id,ident,gate_epoch,chat_id,message_id,via,state)
    VALUES ($TID11,'DIVE-C11',1,'1234567890','3476','ghostbot','live');" >/dev/null 2>&1
: >"$HANDOFF"; reset_io
_task_gate_card_apply DIVE-C11 die "withdrawn" >/dev/null 2>&1
chk "torn down (non-root caller): still orphaned" "orphaned" "$(card_state "$TID11")"
chk "torn down (non-root caller): root is not asked" "" "$(cat "$HANDOFF")"

# ---- the root side: cmd_gate_card_retire_delegated ----
# Run in subshells: `fail` exits. The seat comes from SUDO_UID, never stdin.
# Numeric idents: the primitive accepts only a real PREFIX-NNN ident, so a
# DIVE-Cnn fixture would be refused by validation and pass the refusal arms for
# the wrong reason. Each refusal arm also checks the reason it printed.
_gate_is_root() { return 0; }
_gate_uid_to_agent() { [[ "$1" == 2001 ]] && printf lilbro; [[ "$1" == 2002 ]] && printf mallory; }
mk_open() { # <ident> <filer> -> id   (an OPEN approval gate)
  db "INSERT INTO tasks (ident,title,status,need_type,tier,ask,ask_shape,gate_filed_by)
      VALUES ('$1','t','blocked','approval',1,'ship it?','ship it','$2');" >/dev/null 2>&1
  db "SELECT id FROM tasks WHERE ident='$1';"
}
TID12=$(mk_open DIVE-990012 lilbro)
_task_gate_card_record "DIVE-990012" "1234567890" "3477" "marketing"
reset_io
out=$( export SUDO_UID=2002; printf 'DIVE-990012\ndie\nhijack\n' | cmd_gate_card_retire_delegated 2>&1 )
chk "root side: an OPEN gate's card is refused to a seat that did not file it" "live" "$(card_state "$TID12")"
chk "root side: refused for THAT reason" "1" "$(grep -c 'still open and was filed by lilbro, not mallory' <<<"$out")"
chk "root side: and no Bot API call" "0" "$(io_count)"
( export SUDO_UID=2001; printf 'DIVE-990012\ndie\nsuperseded by a re-filed gate\n' | cmd_gate_card_retire_delegated ) >/dev/null 2>&1
chk "root side: the FILER may retire its own open gate's card (the re-file path)" "deleted" "$(card_state "$TID12")"

TID13=$(mk_task DIVE-990013)
db "UPDATE tasks SET need_answered_at=datetime('now'), need_answered_by='lead:main', need_answer='approve' WHERE id=$TID13;" >/dev/null
_task_gate_card_record "DIVE-990013" "1234567890" "3478" "marketing"
reset_io
out=$( export SUDO_UID=2002; printf 'DIVE-990013\nsettle\nanswered\n' | cmd_gate_card_retire_delegated 2>&1 )
chk "root side: settle with no HUMAN answer on the row is refused" "live" "$(card_state "$TID13")"
chk "root side: refused for THAT reason" "1" "$(grep -c 'carries no human answer' <<<"$out")"
( export SUDO_UID=2002; printf 'DIVE-990013\ndie\nanswered by lead:main\n' | cmd_gate_card_retire_delegated ) >/dev/null 2>&1
chk "root side: any seat may retire a CLOSED gate's card" "deleted" "$(card_state "$TID13")"
out=$( unset SUDO_UID; printf 'DIVE-990013\ndie\nx\n' | cmd_gate_card_retire_delegated 2>&1 )
chk "root side: refuses with no sudo caller" "1" "$(grep -c 'requires sudo from an agent seat' <<<"$out")"

eval "$(declare -f _real_gate_is_root | sed '1s/_real_gate_is_root/_gate_is_root/')"

# ---- isolation: nothing from this suite reached the real fleet audit log ----
# Counted BY THIS SUITE'S OWN FIXTURE IDENTS, not by the file's byte offset.
# gate_answer_audit_unit's section-5 arm uses an offset on
# /var/log/5dive/agent-audit.log, and on this box that is a shared file every
# agent writes to continuously — so it reds whenever anyone else acts during the
# run, whatever the cause. Measured 2026-08-11: it failed twice in sweeps while
# passing 6/6 standalone, and a control/treatment pair (one unrelated line
# appended mid-run by another process) reproduces the failure exactly. An ident
# filter measures "did I write" instead of "did the file grow", which is the
# question actually being asked.
_REAL_AUDIT=/var/log/5dive/agent-audit.log
_mine_before="${_MINE_AUDIT_BEFORE:-0}"
_mine_after=0
[[ -r "$_REAL_AUDIT" ]] && _mine_after=$(grep -c 'task=DIVE-C[0-9]' "$_REAL_AUDIT" 2>/dev/null || echo 0)
chk "isolation: this suite wrote NO fixture rows to the real fleet audit log" \
    "$_mine_before" "$_mine_after"

printf -- '-----\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
