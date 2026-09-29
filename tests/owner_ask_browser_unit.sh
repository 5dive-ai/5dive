#!/usr/bin/env bash
# DIVE-4982 part B — the owner answers a browser ask from Telegram.
#
# A browser act that would send, pay, publish or delete stops with exit 73 and
# writes an ask to <seat home>/.5dive/browser-approvals/<seat>-<12hex>.json. There
# was no way to answer it from Telegram, and the seat approved its own ask.
# `5dive owner-ask browser` now mints a nonce, writes its sha256 into the request
# as root (temp + rename) and sends the owner Approve `bap:<12hex>:<nonce>` /
# Decline `bdn:…`; `5dive owner-ask tap` (run by the team-bot listener) checks the
# tapper against the owner, checks the proof, runs `browser approve` (or --deny),
# spends the nonce and wakes the seat.
#
# Arms: (a) browser writes a 64-hex nonce_hash by rename (reading the old request as
# the seat, under a temp name it cannot plant) and composes callback data
# <= 64 bytes for a long seat name; (b) bap -> approve with the proof, bdn -> deny;
# (c) a non-owner tap is refused and logged; (d) a replayed tap is refused;
# (e) MUTANT: the owner check removed -> (c)'s detector goes red; (f) the listener
# routes bap/bdn to `owner-ask tap`; (g) with the human registry in use only the
# seat's owner counts; CI control: no sudo, no /usr/local/bin/5dive; LIVE: a request
# the real browser plugin wrote on this box resolves through the real passwd.
#
# Run: bash tests/owner_ask_browser_unit.sh (no root, no network).
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/owner-ask-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh \
         task/routing.sh task/notify.sh cmd_task.sh cmd_owner_ask.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f" 2>/dev/null || source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- fixtures: two seats, their bots, their approvals dirs --------------------
OWNER=1111111111 BYSTANDER=2222222222 STRANGER=9999999999
ME_UID=$(id -u) ME_GID=$(id -g)
SEAT=agent-claude-annapriva-longnamex    # 32 characters, the longest a user name gets
OTHER=agent-dev
: > "$TMP/passwd"
for u in "$SEAT" "$OTHER"; do
  mkdir -p "$TMP/home/$u/.5dive/browser-approvals"
  printf '%s:x:%s:%s::%s/home/%s:/bin/bash\n' "$u" "$ME_UID" "$ME_GID" "$TMP" "$u" >> "$TMP/passwd"
done
LIVE_PASSWD=0 AS_ROOT=1 GRANTER="$ME_UID"   # the harness is the "root" that writes
# Seams over src/cmd_owner_ask.sh — a function so the MUTANT arm can re-install them
# after it sources its own copy of the file.
seams() {
  _owner_ask_passwd() {
    (( LIVE_PASSWD )) && { getent passwd "$@"; return; }
    if (( $# )); then grep "^$1:" "$TMP/passwd"; else cat "$TMP/passwd"; fi
  }
  _owner_ask_is_root() { (( AS_ROOT )); }
  _owner_ask_granter_uid() { printf '%s' "$GRANTER"; }
  _owner_ask_post_photo() { cp -- "$5" "$TMP/photo.$2"; printf '%s %s\n' "$2" "$4" >> "$TMP/photos"; }
  # Emulates the CLI the tap runs: 5dive-browser's approve (--deny removes the ask,
  # approve writes a grant) and agent send. Records the exact argv.
  _owner_ask_run() {
    shift
    printf '%s\n' "$*" >> "$TMP/run.log"
    if [[ "$1 $2" == "browser approve" ]]; then
      local d; d=$(_owner_ask_dir_of "${3%-*}")
      if [[ "${5:-}" == --deny ]]; then rm -f -- "$d/$3.json"; else printf '{}' > "$d/$3.granted"; fi
    fi
  }
}
seams
approves() { grep '^browser approve' "$TMP/run.log"; }
wakes() { grep '^agent send' "$TMP/run.log"; }

CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
_tg_access_state_dir() { printf '%s/chan/%s/%s' "$TMP" "$1" "$2"; }
mkdir -p "$TMP/chan/$SEAT/claude"
printf 'TELEGRAM_BOT_TOKEN=123:fake\n' > "$CONNECTORS_DIR/telegram-${SEAT#agent-}.env"
printf '{"allowFrom":["%s","%s"],"groups":{}}\n' "$OWNER" "$BYSTANDER" > "$TMP/chan/$SEAT/claude/access.json"
# $OTHER has no bot at all.

SENDS="$TMP/sends.jsonl"; : > "$SENDS"
_mirror_send() {
  jq -cn --arg chat "$2" --arg th "$3" --arg text "$4" --arg mk "${5:-}" '{chat:$chat, thread:$th, text:$text, markup:$mk}' >> "$SENDS"
  printf '%s' '{"ok":true,"result":{"message_id":77}}'
}
_mirror_log_button_reject() { :; }
_mirror_follow_migration() { :; }
# CI is pristine: no sudo grant and no /usr/local/bin/5dive. Every root-path arm
# must reach neither; the one non-root arm must fail soft on it.
sudo() { printf '%s\n' "$*" >> "$TMP/sudo.log"; return 1; }
: > "$TMP/sudo.log" "$TMP/run.log" "$TMP/photos"

printf '\x89PNG\r\n\x1a\n-fixture-' > "$TMP/home/$SEAT/page.png"
mkreq() { # <seat> <hex> [asked_at] -> path
  local d; d=$(_owner_ask_dir_of "$1")
  jq -n --arg id "$1-$2" --arg s "$1" --argjson at "${3:-$(date +%s)}" --arg shot "$TMP/home/$1/page.png" \
    '{id:$id, seat:$s, site:"mail.google.com", hash:"abc", steps:[{op:"click"}], class:"send", label:"Send",
      step:"2", page:"https://mail.google.com/", screenshot:$shot, asked_at:$at,
      payload:{to:["ann@example.com","bob@example.com"], subject:"Q3 numbers", first_line:"Hi both\u202e, figures attached"}}' \
    > "$d/$1-$2.json"
  printf '%s' "$d/$1-$2.json"
}
browser() { ( JSON_MODE=1 _owner_ask_browser "$@" ) 2>"$TMP/err"; }
tap() { # <data> <uid> — prints the JSON; the audit args the EXIT trap would log land in $TMP/audit
  ( trap 'printf "%s\n" "${AUDIT_ARGS[@]}" > "$TMP/audit"' EXIT; JSON_MODE=1 _owner_ask_tap "$1" "--tap-uid=$2" ) 2>"$TMP/err"
}
last_send() { tail -1 "$SENDS"; }
cb() { last_send | jq -r --argjson i "$1" '.markup | fromjson | .inline_keyboard[0][$i].callback_data'; }

echo "# (a) owner-ask browser: the proof as root, by rename, and the buttons"
H1=0123456789ab
R1=$(mkreq "$SEAT" "$H1")
ino_before=$(stat -c %i "$R1")
out=$(browser "$R1"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.sent' <<<"$out")" == true ]] \
  && ok_t "a1 the ask is sent (rc 0, sent:true)" || bad_t "a1 the ask is sent" "rc=$rc out=$out err=$(cat "$TMP/err")"
nh=$(jq -r '.nonce_hash // ""' "$R1")
[[ "$nh" =~ ^[0-9a-f]{64}$ ]] && ok_t "a2 the request carries a 64-hex nonce_hash" || bad_t "a2 nonce_hash" "$nh"
[[ "$(stat -c %i "$R1")" != "$ino_before" && "$(stat -c %a "$R1")" == 644 ]] \
  && ok_t "a3 the request was replaced by rename (new inode, 0644), not written in place" \
  || bad_t "a3 replaced by rename" "inode $ino_before -> $(stat -c %i "$R1"), mode $(stat -c %a "$R1")"
A=$(cb 0) D=$(cb 1)
[[ "$A" =~ ^bap:${H1}:([0-9a-f]{32})$ ]] && NONCE1="${BASH_REMATCH[1]}" || NONCE1=""
[[ -n "$NONCE1" && "$D" == "bdn:${H1}:${NONCE1}" ]] \
  && ok_t "a4 Approve is bap:<12hex>:<nonce>, Decline is bdn: with the same nonce" || bad_t "a4 button data" "$A | $D"
(( ${#A} <= 64 && ${#D} <= 64 )) && ok_t "a5 callback data is ${#A} bytes for a ${#SEAT}-char seat (cap 64)" \
  || bad_t "a5 callback data fits 64 bytes" "${#A} / ${#D}"
[[ "$(_human_nonce_sha "$NONCE1")" == "$nh" ]] && ok_t "a6 sha256(the button's nonce) == nonce_hash" || bad_t "a6 hash matches" "$nh"
txt=$(last_send | jq -r .text)
[[ "$txt" == *"to: ann@example.com, bob@example.com"* && "$txt" == *'subject: Q3 numbers'* && "$txt" == *'first line: Hi both , figures attached'* \
   && "$txt" == *"id: $SEAT-$H1"* ]] \
  && ok_t "a7 the owner reads the payload (bidi mark stripped), the step and the id" || bad_t "a7 message text" "$txt"
[[ "$txt" != *"$NONCE1"* && "$out" != *"$NONCE1"* && "$(cat "$TMP/err")" != *"$NONCE1"* ]] \
  && ok_t "a8 the raw nonce is only in the buttons — not in the text, stdout or stderr" || bad_t "a8 nonce leaked"
[[ "$(jq -sr 'map(.chat) | sort | join(",")' "$SENDS")" == "$(printf '%s\n' "$OWNER" "$BYSTANDER" | sort | paste -sd,)" ]] \
  && ok_t "a9 no registry: sent to the users paired to the seat's bot (allowFrom), as gate alerts are" \
  || bad_t "a9 recipients" "$(jq -sc 'map(.chat)' "$SENDS")"
grep -qx "$OWNER 77" "$TMP/photos" && [[ "$(head -c 8 "$TMP/photo.$OWNER" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] \
  && ok_t "a10 the screenshot follows, as a reply to the ask" || bad_t "a10 screenshot" "$(cat "$TMP/photos")"

R2=$(mkreq "$OTHER" aaaaaaaaaaaa)
out=$(browser "$R2"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.sent' <<<"$out")" == false && "$(jq -r '.data.reason' <<<"$out")" == *"no paired Telegram channel"* \
   && "$(jq -r '.nonce_hash // "none"' "$R2")" == none ]] \
  && ok_t "a11 no owner route: nothing sent, nothing written, and it says why (rc 0)" || bad_t "a11 no route" "rc=$rc $out"
out=$(SUDO_USER="$OTHER" browser "$R1"); rc=$?
[[ $rc == "$E_PERMISSION" ]] && ok_t "a12 a seat cannot send another seat's ask" || bad_t "a12 cross-seat" "rc=$rc $out"
cp "$R1" "$TMP/stray-$H1.json"
out=$(browser "$TMP/stray-$H1.json"); rc=$?
[[ $rc != 0 ]] && ok_t "a13 a file outside the seat's approvals dir is refused" || bad_t "a13 stray file" "rc=$rc $out"
# The seat owns the directory, so it can swap the request for a link at any moment:
# root must read it AS THE SEAT, and write under a name the seat cannot plant first.
orig_cat_as=$(declare -f _owner_ask_cat_as)
_owner_ask_cat_as() { printf '%s %s\n' "$1" "$2" >> "$TMP/catas"; cat -- "$2"; }
mv() { printf '%s\n' "$*" >> "$TMP/mv"; command mv "$@"; }
: > "$TMP/catas"; : > "$TMP/mv"
H2=0f0f0f0f0f0f; R2b=$(mkreq "$SEAT" "$H2")
browser "$R2b" >/dev/null
grep -qx "$SEAT $SEAT-$H2.json" "$TMP/catas" \
  && ok_t "a14 the old request is read as the seat, not opened by root" || bad_t "a14 read as the seat" "$(cat "$TMP/catas")"
grep -qE "^-fT -- \.$SEAT-$H2\.owner-ask\.[0-9a-f]{32} $SEAT-$H2\.json$" "$TMP/mv" \
  && ok_t "a15 the temp name carries a fresh 32-hex nonce (the seat cannot pre-plant it)" || bad_t "a15 temp name" "$(cat "$TMP/mv")"
unset -f mv; eval "$orig_cat_as"

echo "# (c) a non-owner tap is refused, and the refusal is logged"
: > "$TMP/run.log"
out=$(tap "bap:${H1}:${NONCE1}" "$STRANGER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *"only the box owner"* && -z "$(approves)" ]] \
  && ok_t "c1 a stranger's tap is refused and approves nothing" || bad_t "c1 stranger refused" "rc=$rc $out approves=$(approves)"
grep -q "^refused=only the box owner" "$TMP/audit" && grep -q "^tap_uid=$STRANGER" "$TMP/audit" && ! grep -q "$NONCE1" "$TMP/audit" \
  && ok_t "c2 the audit row names the tapper and the reason, never the nonce" || bad_t "c2 audit" "$(cat "$TMP/audit")"
[[ "$(jq -r '.nonce_hash // ""' "$R1")" == "$nh" ]] && ok_t "c3 the refused tap leaves the proof live for the owner" || bad_t "c3 proof kept"

echo "# (b) the owner's taps: bap approves with the proof, bdn denies"
out=$(tap "bap:${H1}:${NONCE1}" "$OWNER"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.result' <<<"$out")" == approved && "$(jq -r '.data.id' <<<"$out")" == "$SEAT-$H1" ]] \
  && ok_t "b1 bap from the owner -> approved" || bad_t "b1 approve" "rc=$rc $out err=$(cat "$TMP/err")"
[[ "$(approves)" == "browser approve $SEAT-$H1 --human-proof=$NONCE1" ]] \
  && ok_t "b2 it ran browser approve <full id> --human-proof=<nonce>" || bad_t "b2 approve argv" "$(approves)"
grep -q "^agent send ${SEAT#agent-} --message=.*APPROVED.*$SEAT-$H1.*--approved=$SEAT-$H1" <<<"$(wakes)" \
  && ok_t "b3 the seat is woken with the id and --approved=<id>" || bad_t "b3 wake" "$(wakes)"
[[ "$(jq -r '.nonce_hash // "spent"' "$R1")" == spent && "$(jq -r '.owner_answer' "$R1")" == approved ]] \
  && ok_t "b4 the proof is spent (nonce_hash removed, owner_answer recorded)" || bad_t "b4 spent" "$(jq -c . "$R1")"

H3=bbbbbbbbbbbb; R3=$(mkreq "$SEAT" "$H3"); browser "$R3" >/dev/null
N3=$(cb 0); N3="${N3##*:}"
: > "$TMP/run.log"
out=$(tap "bdn:${H3}:${N3}" "$OWNER"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.result' <<<"$out")" == declined && "$(approves)" == "browser approve $SEAT-$H3 --human-proof=$N3 --deny" && ! -e "$R3" ]] \
  && ok_t "b5 bdn from the owner -> browser approve --deny, and the ask is gone" || bad_t "b5 deny" "rc=$rc $out approves=$(approves)"
grep -q "DECLINED.*$SEAT-$H3" <<<"$(wakes)" && ok_t "b6 the seat is told it was declined" || bad_t "b6 decline wake" "$(wakes)"

echo "# (d) replays and stale buttons"
: > "$TMP/run.log"
out=$(tap "bap:${H1}:${NONCE1}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *"already answered"* && -z "$(approves)" ]] \
  && ok_t "d1 the same tap again is refused: the button is spent" || bad_t "d1 replay" "rc=$rc $out"
rm -f -- "$R1" "${R1%.json}.granted"     # the act ran and consumed its grant
out=$(tap "bap:${H1}:${NONCE1}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *"no pending ask"* ]] \
  && ok_t "d2 a tap after the act spent the ask is refused" || bad_t "d2 after spend" "rc=$rc $out"
out=$(tap "bdn:${H3}:${N3}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && -z "$(approves)" ]] && ok_t "d3 a tap after a decline is refused" || bad_t "d3 after deny" "rc=$rc $out"
H4=cccccccccccc; R4=$(mkreq "$SEAT" "$H4"); browser "$R4" >/dev/null
old=$(cb 0); old="${old##*:}"
browser "$R4" >/dev/null                      # a second send re-mints
out=$(tap "bap:${H4}:${old}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *stale* && -z "$(approves)" ]] \
  && ok_t "d4 a button from before a re-send is stale and refused" || bad_t "d4 stale" "rc=$rc $out"
H5=dddddddddddd; R5=$(mkreq "$SEAT" "$H5" $(( $(date +%s) - OWNER_ASK_TTL - 5 ))); browser "$R5" >/dev/null
n5=$(cb 0); n5="${n5##*:}"
out=$(tap "bap:${H5}:${n5}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *expired* && -z "$(approves)" ]] \
  && ok_t "d5 an ask older than the browser's 30-minute TTL is refused" || bad_t "d5 expired" "rc=$rc $out"
H6=eeeeeeeeeeee; R6=$(mkreq "$SEAT" "$H6"); browser "$R6" >/dev/null
n6=$(cb 0); n6="${n6##*:}"
jq . "$R6" > "$TMP/seatcopy" && rm -f "$R6" && cat "$TMP/seatcopy" > "$R6"
GRANTER=0                                      # now only a root-owned request is trusted
out=$(tap "bap:${H6}:${n6}" "$OWNER"); rc=$?
[[ $rc == "$E_PERMISSION" && "$(jq -r '.error.message' <<<"$out")" == *"no owner proof"* && -z "$(approves)" ]] \
  && ok_t "d6 a request the seat rewrote (not owned by the granting uid) is not trusted" || bad_t "d6 seat-owned request" "rc=$rc $out"
GRANTER="$ME_UID"

echo "# (g) with the human registry in use, only the seat's owner counts"
db "INSERT INTO humans (id, display_name, telegram_id) VALUES ('h-own','Owner',$(sqlq "$OWNER")), ('h-by','By',$(sqlq "$BYSTANDER"));"
db "INSERT INTO human_agents (human_id, agent) VALUES ('h-own', $(sqlq "${SEAT#agent-}"));"
: > "$SENDS"
H7=ffffffffffff; R7=$(mkreq "$SEAT" "$H7"); browser "$R7" >/dev/null
n7=$(cb 0); n7="${n7##*:}"
[[ "$(jq -sr 'map(.chat) | join(",")' "$SENDS")" == "$OWNER" ]] \
  && ok_t "g1 sent to the linked owner only, not to every paired user" || bad_t "g1 registry send" "$(jq -sc 'map(.chat)' "$SENDS")"
out=$(tap "bap:${H7}:${n7}" "$BYSTANDER"); rc=$?
[[ $rc == "$E_PERMISSION" && -z "$(approves)" ]] && ok_t "g2 a paired bystander's tap is refused" || bad_t "g2 bystander" "rc=$rc $out"
out=$(tap "bap:${H7}:${n7}" "$OWNER"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.result' <<<"$out")" == approved ]] && ok_t "g3 the owner's tap approves" || bad_t "g3 owner" "rc=$rc $out"
db "DELETE FROM human_agents; DELETE FROM humans;"

echo "# (e) MUTANT: the owner check removed must let a stranger approve (so c1 goes red)"
MUT="$TMP/cmd_owner_ask.mutant.sh"
grep -v 'grep -qxF -- "\$uid" <<<"\$OA_OWNER_TG"' "$SRC/cmd_owner_ask.sh" > "$MUT"
if cmp -s "$MUT" "$SRC/cmd_owner_ask.sh"; then
  bad_t "e1 mutant applies" "the owner-check line was not found; the mutant arm is ungraded"
else
  H8=0a0a0a0a0a0a; R8=$(mkreq "$SEAT" "$H8"); browser "$R8" >/dev/null
  n8=$(cb 0); n8="${n8##*:}"
  : > "$TMP/run.log"
  # shellcheck source=/dev/null
  out=$( ( source "$MUT"; seams; JSON_MODE=1 _owner_ask_tap "bap:${H8}:${n8}" "--tap-uid=$STRANGER" ) 2>/dev/null ); rc=$?
  [[ $rc == 0 && -n "$(approves)" ]] \
    && ok_t "e1 MUTANT: without the owner check a stranger's tap approves — c1 would be red, as it must" \
    || bad_t "e1 MUTANT not caught" "the mutant still refused the stranger (rc=$rc $out): the arm grades nothing"
fi

echo "# (f) the team-bot listener carries bap/bdn to owner-ask tap"
L="$SRC/cmd_agent_teambot.sh"
re=$(sed -n 's|^const OWNER_ASK_RE = /\(.*\)/$|\1|p' "$L")
if [[ -n "$re" ]]; then
  [[ "bap:${H1}:${NONCE1}" =~ $re && "bdn:${H1}:${NONCE1}" =~ $re && ! "tna:12:approved:${NONCE1}" =~ $re && ! "bap:${H1}:${NONCE1}x" =~ $re ]] \
    && ok_t "f1 OWNER_ASK_RE takes bap:/bdn: buttons and nothing else" || bad_t "f1 regex" "$re"
else
  bad_t "f1 OWNER_ASK_RE found in the listener" "no 'const OWNER_ASK_RE = /…/' line in $L"
fi
grep -qF "'owner-ask', 'tap', data, \`--tap-uid=\${tapUid}\`" "$L" \
  && ok_t "f2 the listener runs 5dive owner-ask tap <data> --tap-uid=<tapper>" || bad_t "f2 listener call" "not found in $L"
body=$(sed -n '/^async function handleCallback/,/^}/p' "$L")
[[ -n "$body" && "$(grep -n 'OWNER_ASK_RE.test' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'TNA_RE.exec' <<<"$body" | cut -d: -f1)" ]] \
  && ok_t "f3 handleCallback routes bap/bdn before the tna: parser" || bad_t "f3 routing order" "$body"

echo "# CI control: no sudo grant, no installed CLI"
[[ ! -s "$TMP/sudo.log" ]] && ok_t "x1 every root-path arm above ran without sudo or /usr/local/bin/5dive" \
  || bad_t "x1 root path shelled out" "$(cat "$TMP/sudo.log")"
AS_ROOT=0
H9=1b1b1b1b1b1b; R9=$(mkreq "$SEAT" "$H9")
out=$(browser "$R9"); rc=$?
[[ $rc == 0 && "$(jq -r '.data.sent' <<<"$out")" == false && "$(jq -r '.data.reason' <<<"$out")" == *"no sudo grant"* \
   && "$(cat "$TMP/sudo.log")" == "-n -l 5dive owner-ask browser $R9" ]] \
  && ok_t "x2 a seat with no sudo grant: probed once, nothing sent, it says why (rc 0)" || bad_t "x2 no sudo" "rc=$rc $out sudo=$(cat "$TMP/sudo.log")"
AS_ROOT=1

echo "# LIVE: a request the real browser plugin wrote on this box, through the real passwd"
me=$(id -un)
live=""
if [[ "$me" == agent-* ]]; then
  LIVE_PASSWD=1
  d=$(_owner_ask_dir_of "$me")
  live=$(ls -1t "$d"/"$me"-*.json 2>/dev/null | grep -E "/${me}-[0-9a-f]{12}\.json$" | head -1)
fi
if [[ -n "$live" ]]; then
  lh="${live##*-}"; lh="${lh%.json}"
  ( _owner_ask_load "$live" ) >/dev/null 2>&1 \
    && ok_t "L1 $live (written by the installed plugin) validates against getent passwd" || bad_t "L1 live request" "$( (_owner_ask_load "$live") 2>&1)"
  ( _owner_ask_find "$lh" && [[ "$OA_DIR/$OA_ID.json" == "$live" ]] ) >/dev/null 2>&1 \
    && ok_t "L2 its 12-hex tail resolves back to that file over the live passwd" || bad_t "L2 live find" "$lh"
else
  printf 'skip - L1/L2: no browser ask on this box for %s (CI, or the plugin never stopped here)\n' "$me"
fi
LIVE_PASSWD=0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
