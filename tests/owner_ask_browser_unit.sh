#!/usr/bin/env bash
# DIVE-5001: `5dive owner-ask` — a browser ask answered by ONE Telegram tap.
#
# Grades the root half (_owner_ask deliver / tap) through its seams: no root, no
# Telegram, no browser. The acceptance arms the row names:
#   (a) nonce_hash is written by a REPLACE (temp file + rename), the seat's file
#       untouched;
#   (b) the right proof answers, a wrong or replayed one is refused;
#   (c) an ask whose hash is not in a grant-uid-owned file is "never delivered";
#   (d) the button is bound to the owner's Telegram id.
# Then three mutants, each re-sourcing a copy of the verb with one guard removed,
# prove the arm that owns that guard goes red without it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/owner-ask.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$STATE_DIR" "$TASKS_DIR" "$FIVEDIVE_CONNECTOR_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh \
  cmd_agent_pairing.sh cmd_agent_create.sh cmd_owner_ask.sh; do
  source "$SRC/$f"
done
set +e
tasks_db_init >/dev/null 2>&1
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }
is(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
has(){ [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 (no '$3' in: ${2:0:300})"; }

# Telegram ids: the reserved fake, and a short stand-in for "somebody else".
ME=$(id -u); OWNER=1234567890; OTHER=42
# ── the box, in $TMP ─────────────────────────────────────────────────────────
seat_box() {  # <seat short name> <allowFrom json array>
  local s="$1"
  mkdir -p "$TMP/home/agent-$s/.5dive/browser-approvals" "$TMP/home/agent-$s/.claude/channels/telegram"
  chmod 700 "$TMP/home/agent-$s/.5dive/browser-approvals"
  printf 'TELEGRAM_BOT_TOKEN=111:tok-%s\n' "$s" >"$FIVEDIVE_CONNECTOR_DIR/telegram-$s.env"
  jq -n --argjson a "$2" '{dmPolicy:"allowlist", allowFrom:$a}' >"$TMP/home/agent-$s/.claude/channels/telegram/access.json"
}
seat_box ops "[\"$OWNER\"]"
seat_box mkt "[\"$OWNER\"]"
AD="$TMP/home/agent-ops/.5dive/browser-approvals"
_tg_access_state_dir() { printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2"; }
_owner_ask_seat_home() { printf '%s/home/%s' "$TMP" "$1"; }
_owner_ask_seat_uid()  { printf '%s' "$ME"; }
_owner_ask_as_seat()   { shift; "$@"; }
GRANT_UID=999999
_owner_ask_grant_uid() { printf '%s' "$GRANT_UID"; }
TG_OK=true
_owner_ask_tg() { { printf 'METHOD %s\n' "$1"; shift; printf 'ARG %s\n' "$@"; } >>"$TMP/tg.log"; printf '{"ok":%s}\n' "$TG_OK"; }
_owner_ask_browser_approve() { printf '%s|%s|%s|%s\n' "$@" >>"$TMP/approve.log"; printf 'approved: %s\n' "$2"; }

new_ask() {  # <seat> <ref> [screenshot] -> path
  local s="$1" ref="$2" shot="${3:-}" d="$TMP/home/agent-$1/.5dive/browser-approvals"
  jq -n --arg id "agent-$s-$ref" --arg seat "agent-$s" --arg shot "$shot" '{id:$id, seat:$seat, site:"google.com",
     hash:"h", steps:[{a:1},{a:2},{a:3}], class:"send", label:"Send", step:"3", page:"", screenshot:$shot, asked_at:1,
     payload:{to:["a@example.com"], subject:"Q3 numbers", first_line:"Hi both, figures attached"}}' >"$d/agent-$s-$ref.json"
  printf '%s/agent-%s-%s.json' "$d" "$s" "$ref"
}
deliver() { ( _owner_ask_deliver "$1" "$2" ) 2>&1; }
tap()     { ( _owner_ask_tap "$1" "$2" "$3" ) 2>&1; }
cb()      { grep -o "\"callback_data\":\"$1:[^\"]*\"" "$TMP/tg.log" | tail -1 | sed 's/.*:"\(.*\)"/\1/'; }

echo "0. the grant"
SUD=$(render_standard_sudoers agent-tap 0 0)
is 'exact-path _owner_ask grant rendered once' "$(grep -cE '^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _owner_ask$' <<<"$SUD")" 1
is 'the _owner_ask grant has no wildcard' "$(grep '_owner_ask' <<<"$SUD" | grep -c '\*')" 0
is 'the rendered standard policy still classifies as cli-scoped' "$(printf '%s\n' "$SUD" | classify_sudo_grant 2>/dev/null | head -1 | cut -d' ' -f1)" \
   "$(render_standard_sudoers agent-tap 0 0 | grep -v _owner_ask | classify_sudo_grant 2>/dev/null | head -1 | cut -d' ' -f1)"

echo "1. (a) deliver: a root-owned replace, the seat's file untouched"
REQ=$(new_ask ops 0123456789ab)
ln "$REQ" "$TMP/seat-original"; ORIG_INO=$(stat -c %i "$REQ"); ORIG_SUM=$(sha256sum <"$REQ")
: >"$TMP/tg.log"
OUT=$(deliver ops "$REQ"); RC=$?
is  'deliver exits 0' "$RC" 0
has 'deliver prints one line for the browser to show' "$OUT" 'sent to the owner on Telegram'
[[ "$(stat -c %i "$REQ")" != "$ORIG_INO" ]] && ok 'the request is a NEW inode (renamed in, not written in place)' || bad 'the request is a NEW inode'
is  "the seat's own file is byte-identical" "$(sha256sum <"$TMP/seat-original")" "$ORIG_SUM"
is  "the seat's own file carries no hash" "$(jq -r '.nonce_hash // "none"' "$TMP/seat-original")" none
is  'the replacement is owned by the writer (root in production)' "$(stat -c %u "$REQ")" "$ME"
is  'the replacement is 0644, readable by the seat' "$(stat -c %a "$REQ")" 644
H=$(jq -r .nonce_hash "$REQ")
[[ "$H" =~ ^[0-9a-f]{64}$ ]] && ok 'nonce_hash is a sha256' || bad "nonce_hash is a sha256 ($H)"
is  'the request records the owner it went to' "$(jq -r .owner_telegram "$REQ")" "$OWNER"
is  'no temp file is left behind' "$(find "$AD" -name '.owner-ask.*' | wc -l)" 0
is  'every original field survives' "$(jq -c 'del(.nonce_hash,.owner_telegram,.delivered_at,.delivered_by)' "$REQ")" "$(jq -c . "$TMP/seat-original")"
TGL=$(cat "$TMP/tg.log")
has 'sent as a text message when there is no screenshot' "$TGL" 'METHOD sendMessage'
has 'sent to the owner id' "$TGL" "chat_id=$OWNER"
has 'the payload line exactly as the ask prints it' "$TGL" \
    'I am about to send a message on google.com: to a@example.com · subject "Q3 numbers" · "Hi both, figures attached". OK?'
BAP=$(cb bap); BDN=$(cb bdn); NONCE=${BAP##*:}
[[ "$BAP" =~ ^bap:0123456789ab:[0-9a-f]{32}$ ]] && ok 'Approve callback is bap:<ref>:<nonce>' || bad "Approve callback ($BAP)"
[[ "$BDN" == "bdn:${BAP#bap:}" ]] && ok 'Decline carries the same ref and nonce' || bad "Decline callback ($BDN)"
(( ${#BAP} <= 64 )) && ok 'callback_data fits Telegram 64 bytes' || bad "callback_data fits 64 bytes (${#BAP})"
is  'the button nonce hashes to the stored nonce_hash' "$(_human_nonce_sha "$NONCE")" "$H"
[[ "$(cat "$REQ")" != *"$NONCE"* ]] && ok 'the raw nonce is not in the request file' || bad 'the raw nonce is not in the request file'

echo "1b. deliver refusals"
GRANT_UID=$ME
OUT=$(deliver ops "$REQ"); RC=$?
is  'a second deliver of a delivered ask is a conflict' "$RC" "$E_CONFLICT"
GRANT_UID=999999
R2=$(new_ask ops 00000000000b); OUT=$(deliver ops "$TMP/elsewhere/agent-ops-00000000000b.json"); RC=$?
is  'a path outside the seat approvals dir is refused' "$RC" "$E_VALIDATION"
jq '.id="agent-ops-x-00000000000c"|.seat="agent-ops-x"' "$R2" >"$AD/agent-ops-x-00000000000c.json"
OUT=$(deliver ops "$AD/agent-ops-x-00000000000c.json"); RC=$?
is  "an ask named for another seat (agent-ops-x) in this seat's dir is refused" "$RC" "$E_VALIDATION"
ln -s "$R2" "$AD/agent-ops-00000000000d.json"
OUT=$(deliver ops "$AD/agent-ops-00000000000d.json"); RC=$?
is  'a symlinked request is refused' "$RC" "$E_NOT_FOUND"
seat_box two "[\"$OWNER\",\"$OTHER\"]"
R3=$(new_ask two 00000000000e); S3=$(sha256sum <"$R3")
OUT=$(deliver two "$R3"); RC=$?
is  'two paired people and no named owner: refused, not broadcast' "$RC" "$E_AUTH_REQUIRED"
is  '  ...and the ask is untouched' "$(sha256sum <"$R3")" "$S3"
TG_OK=false; : >"$TMP/tg.log"
R4=$(new_ask ops 00000000000f); OUT=$(deliver ops "$R4"); RC=$?; TG_OK=true
[[ $RC != 0 ]] && ok 'Telegram refusing the message fails the deliver' || bad 'Telegram refusing the message fails the deliver'
is  '  ...and no hash is left standing that nobody holds' "$(jq -r '.nonce_hash // "none"' "$R4")" none
OUT=$(deliver ops "$R4"); RC=$?
is  '  ...so a later deliver can try again' "$RC" 0

echo "1c. the screenshot"
printf '\x89PNG\r\n\x1a\nxxxx' >"$TMP/page.png"; printf 'root:x:0:0\n' >"$TMP/not-a-png"
: >"$TMP/tg.log"; R5=$(new_ask ops 000000000010 "$TMP/page.png"); deliver ops "$R5" >/dev/null
TGL=$(cat "$TMP/tg.log")
has 'a PNG screenshot is sent as the photo' "$TGL" 'METHOD sendPhoto'
has '  ...with the ask as its caption' "$TGL" 'caption=🛑 ops is waiting for your OK'
: >"$TMP/tg.log"; R6=$(new_ask ops 000000000011 "$TMP/not-a-png"); deliver ops "$R6" >/dev/null
TGL=$(cat "$TMP/tg.log")
[[ "$TGL" == *'METHOD sendMessage'* && "$TGL" != *'photo=@'* ]] && ok 'a screenshot that is not a PNG is never uploaded' || bad 'a non-PNG screenshot is never uploaded'

echo "2. (b)(c)(d) the tap"
GRANT_UID=$ME
: >"$TMP/approve.log"
OUT=$(tap ops "bap:0123456789ab:0123456789abcdef0123456789abcdef" "$OWNER"); RC=$?
is  '(b) a wrong nonce is refused' "$RC" "$E_PERMISSION"
is  '  ...and the browser is never called' "$(wc -l <"$TMP/approve.log")" 0
OUT=$(tap ops "$BAP" "$OTHER"); RC=$?
is  '(d) a tap from anyone but the owner it was sent to is refused' "$RC" "$E_PERMISSION"
OUT=$(tap mkt "$BAP" "$OWNER"); RC=$?
is  '(d) a second seat relaying the same button finds nothing to answer' "$RC" "$E_NOT_FOUND"
GRANT_UID=999999
OUT=$(tap ops "$BAP" "$OWNER"); RC=$?
is  '(c) a hash not in a grant-uid file cannot be answered' "$RC" "$E_PERMISSION"
has '  ...it reads as never delivered' "$OUT" 'never delivered to the owner'
GRANT_UID=$ME
is  '  ...and none of those reached the browser' "$(wc -l <"$TMP/approve.log")" 0
OUT=$(tap ops "$BAP" "$OWNER"); RC=$?
is  '(b) the right proof from the owner answers' "$RC" 0
is  '  ...as browser approve <id> --human-proof=<nonce>, for this seat' "$(cat "$TMP/approve.log")" "agent-ops|agent-ops-0123456789ab|$NONCE|0"
OUT=$(tap ops "$BAP" "$OWNER"); RC=$?
is  '(b) the same tap replayed is refused' "$RC" "$E_CONFLICT"
OUT=$(tap ops "$BDN" "$OWNER"); RC=$?
is  '(b) Decline after Approve is the same spent nonce: refused' "$RC" "$E_CONFLICT"
is  '  ...the browser was called exactly once' "$(wc -l <"$TMP/approve.log")" 1
: >"$TMP/tg.log"; R7=$(new_ask ops 000000000012); GRANT_UID=999999; deliver ops "$R7" >/dev/null; GRANT_UID=$ME
BDN7=$(cb bdn); : >"$TMP/approve.log"
OUT=$(tap ops "$BDN7" "$OWNER"); RC=$?
is  'Decline answers with --deny' "$(cat "$TMP/approve.log")" "agent-ops|agent-ops-000000000012|${BDN7##*:}|1"
: >"$TMP/tg.log"; R8=$(new_ask ops 000000000013); GRANT_UID=999999; deliver ops "$R8" >/dev/null; GRANT_UID=$ME
BAP8=$(cb bap); jq '.delivered_at = 1000' "$R8" >"$R8.t" && mv "$R8.t" "$R8"
OUT=$(tap ops "$BAP8" "$OWNER"); RC=$?
is  'an ask older than a day cannot be answered' "$RC" "$E_PERMISSION"
OUT=$(tap ops "bap:0123456789ab;rm -rf /" "$OWNER"); RC=$?
is  'callback data that is not bap/bdn:<ref>:<nonce> is refused' "$RC" "$E_VALIDATION"

echo "3. (d) with a human registry: the named owner, and only if paired"
db "INSERT INTO humans(id,telegram_id) VALUES('pat','$OTHER'),('lee','$OWNER');" >/dev/null
db "INSERT INTO human_agents(human_id,agent) VALUES('pat','two');" >/dev/null
: >"$TMP/tg.log"; GRANT_UID=999999
OUT=$(deliver two "$R3"); RC=$?
is  'the registry owner is asked even when the bot has two paired people' "$RC" 0
has '  ...on their id alone' "$(cat "$TMP/tg.log")" "chat_id=$OTHER"
[[ "$(cat "$TMP/tg.log")" != *"chat_id=$OWNER"* ]] && ok '  ...and nobody else' || bad '  ...and nobody else'
db "DELETE FROM human_agents; INSERT INTO human_agents(human_id,agent) VALUES('pat','ops');" >/dev/null
R9=$(new_ask ops 000000000014); OUT=$(deliver ops "$R9"); RC=$?
is  'a registry owner not paired to the seat bot is refused (the registry narrows, never widens)' "$RC" "$E_AUTH_REQUIRED"
db "DELETE FROM human_agents; DELETE FROM humans;" >/dev/null

echo "4. the caller half and the privileged door"
sudo(){
  if [[ "$2" == "-l" ]]; then [[ -n "${GRANTED:-}" && "$4" == "_owner_ask" ]]; return; fi
  printf '%s\n' "$*" >>"$TMP/sudo.log"
  python3 -c 'import sys; b=sys.stdin.buffer.read(); print(b.count(b"\0")); sys.stdout.write(b.decode().replace("\0","|"))' >"$TMP/wire"
}
: >"$TMP/sudo.log"; GRANTED=
( cmd_owner_ask browser "$REQ" ) >/dev/null 2>&1; RC=$?
is  'a seat without the grant: refused, nothing run as root' "$RC:$(wc -l <"$TMP/sudo.log")" "$E_PERMISSION:0"
GRANTED=1
( cmd_owner_ask browser "$REQ" ) >/dev/null 2>&1
is  'browser -> exactly the exact-path primitive' "$(cat "$TMP/sudo.log")" '-n /usr/local/bin/5dive _owner_ask'
is  '  ...with the op and the path on NUL stdin' "$(head -1 "$TMP/wire")" 2
: >"$TMP/sudo.log"
( printf '%s\n' "$BAP" | cmd_owner_ask tap --from="$OWNER" ) >/dev/null 2>&1
[[ -s "$TMP/sudo.log" && "$(cat "$TMP/sudo.log")" != *"$NONCE"* ]] && ok 'tap: the nonce is never in argv' || bad 'tap: the nonce is never in argv'
has '  ...it travels on stdin' "$(cat "$TMP/wire")" "$BAP"
unset -f sudo
_gate_is_root(){ return 1; }
( printf 'deliver\0%s\0' "$REQ" | cmd_owner_ask_priv ) >/dev/null 2>&1; RC=$?
is  '_owner_ask refuses a non-root caller' "$RC" "$E_PERMISSION"
_gate_is_root(){ return 0; }
( printf 'deliver\0%s\0' "$REQ" | SUDO_UID=0 cmd_owner_ask_priv ) >/dev/null 2>&1; RC=$?
is  '_owner_ask refuses a caller that is not an agent seat' "$RC" "$E_AUTH_REQUIRED"

echo "5. mutants: each guard, removed, turns its arm red"
arm_replay() {  # green = replay refused
  : >"$TMP/tg.log"; GRANT_UID=999999; local r; r=$(new_ask ops 0000000000a1); ( _owner_ask_deliver ops "$r" ) >/dev/null 2>&1
  GRANT_UID=$ME; local b; b=$(cb bap)
  ( _owner_ask_tap ops "$b" "$OWNER" ) >/dev/null 2>&1 || return 1
  ! ( _owner_ask_tap ops "$b" "$OWNER" ) >/dev/null 2>&1
}
arm_owner() {  # green = a stranger's tap refused, the owner's accepted
  : >"$TMP/tg.log"; GRANT_UID=999999; local r; r=$(new_ask ops 0000000000a2); ( _owner_ask_deliver ops "$r" ) >/dev/null 2>&1
  GRANT_UID=$ME; local b; b=$(cb bap)
  ! ( _owner_ask_tap ops "$b" "$OTHER" ) >/dev/null 2>&1 && ( _owner_ask_tap ops "$b" "$OWNER" ) >/dev/null 2>&1
}
arm_inplace() {  # green = the seat's inode keeps its bytes
  GRANT_UID=999999; local r s; r=$(new_ask ops 0000000000a3); ln "$r" "$TMP/orig-a3"; s=$(sha256sum <"$r")
  ( _owner_ask_deliver ops "$r" ) >/dev/null 2>&1
  [[ "$(sha256sum <"$TMP/orig-a3")" == "$s" && "$(jq -r '.nonce_hash // ""' "$r")" =~ ^[0-9a-f]{64}$ ]]
}
reset_arms() { rm -rf "$TMP/orig-a3" "$AD"/agent-ops-0000000000a*.json "$(_owner_ask_spent_dir)"; }
mutant() {  # <label> <sed expr> <arm>
  local m="$TMP/mutant.sh"
  sed "$2" "$SRC/cmd_owner_ask.sh" >"$m"
  if cmp -s "$m" "$SRC/cmd_owner_ask.sh"; then bad "mutant $1: the sed did not change the source"; return; fi
  reset_arms
  ( source "$m"
    _owner_ask_seat_home() { printf '%s/home/%s' "$TMP" "$1"; }
    _owner_ask_seat_uid()  { printf '%s' "$ME"; }
    _owner_ask_as_seat()   { shift; "$@"; }
    _owner_ask_grant_uid() { printf '%s' "$GRANT_UID"; }
    _owner_ask_tg() { { printf 'METHOD %s\n' "$1"; shift; printf 'ARG %s\n' "$@"; } >>"$TMP/tg.log"; printf '{"ok":true}\n'; }
    _owner_ask_browser_approve() { printf 'x\n' >>"$TMP/approve.log"; }
    "$3" ) && bad "mutant $1: its arm stayed green" || ok "mutant $1: its arm goes red"
}
reset_arms; arm_replay  && ok 'control: replay arm is green on the real verb'  || bad 'control: replay arm on the real verb'
reset_arms; arm_owner   && ok 'control: owner arm is green on the real verb'   || bad 'control: owner arm on the real verb'
reset_arms; arm_inplace && ok 'control: in-place arm is green on the real verb' || bad 'control: in-place arm on the real verb'
mutant 'no spent-nonce record' 's|mkdir -- "$spent/$(_human_nonce_sha "$nonce")" 2>/dev/null|true|' arm_replay
mutant 'no owner binding' 's|\[\[ "$(jq -r .\.owner_telegram // "". <<<"$req")" == "$from" \]\]|true|; s|_owner_ask_owner "$seat" \&\& \[\[ "$OWNER_ASK_OWNER" == "$from" \]\]|true|' arm_owner
mutant 'write in place' 's|chmod 0644 "$tmp" \&\& mv -fT -- "$tmp" "$base"|cat "$tmp" >"$base"|' arm_inplace

echo
echo "owner_ask_browser_unit: $P passed, $F failed"
(( F == 0 ))
