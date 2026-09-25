# cmd_owner_ask — an agent's ask reaches its owner as ONE Telegram tap (DIVE-5001).
#
# The browser plugin (1.15.0+, DIVE-4982) stops before a send / post / pay / delete
# the owner has not allowed, writes the ask to the seat's approvals directory, and
# then runs `5dive owner-ask browser <request-file>` when the CLI has that verb.
# Until now nothing on the CLI side answered, so every ask waited for someone to
# type `sudo 5dive browser approve <id>` on the box.
#
#   1. `owner-ask browser <request-file>` (the seat's own process) hands the path to
#      ROOT over one exact-path grant (`_owner_ask`, params on stdin, no argv).
#   2. Root reads the request AS THE SEAT, mints a nonce, and REPLACES the request
#      with a root-owned copy carrying nonce_hash = sha256(nonce): a temp file in
#      the same directory, then a rename. The seat's file is never edited in
#      place. The browser trusts nonce_hash only in a file the granting uid owns,
#      so a seat cannot write a hash of its own.
#   3. Root sends the seat's paired owner — ONE Telegram id, resolved the way gate
#      delivery resolves it (DIVE-3342) — the payload line exactly as the ask
#      printed it, the screenshot, and Approve / Decline. The nonce travels only
#      inside the buttons' callback_data: `bap:<ref>:<nonce>` / `bdn:<ref>:<nonce>`
#      (ref = the 12 hex digits of the ask id, so it fits Telegram's 64 bytes
#      whatever the seat is called).
#   4. The tap reaches that seat's Telegram plugin, which pipes the callback data
#      to `5dive owner-ask tap --from=<tapper id>`. Root re-checks everything —
#      the ask is this seat's, the hash is root-owned and matches, the tapper is
#      the owner it was sent to, the nonce is unspent — and only then runs
#      `5dive browser approve <id> --human-proof=<nonce>` (or --deny).
#
# WHAT THIS DOES NOT CLAIM. The plugin process that relays the tap belongs to the
# seat, so the seat's process sees the callback data; the agent's model does not.
# That is the DIVE-916 boundary, unchanged. A seat holding a root shell can do
# anything root does here by itself. The boundary is for the seat that is NOT root:
# it cannot mint a nonce, write a trusted hash, answer another seat's ask, or reuse
# an answered one.

OWNER_ASK_TAP_TTL=86400          # an ask can be answered for a day after it was sent
OWNER_ASK_REQ_MAX=65536          # bytes of request JSON read from the seat
OWNER_ASK_SHOT_MAX=10485760      # bytes of screenshot read from the seat
OWNER_ASK_CAPTION_MAX=1000       # Telegram caps a photo caption at 1024
OWNER_ASK_TG_API="https://api.telegram.org"
OWNER_ASK_PRIV=(sudo -n /usr/local/bin/5dive _owner_ask)

# ── seams: functions, never environment, so a caller cannot redirect them ──────
_owner_ask_grant_uid() { printf '0'; }
_owner_ask_seat_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }
_owner_ask_seat_uid()  { id -u "$1" 2>/dev/null; }
_owner_ask_as_seat()   { local u="$1"; shift; runuser -u "$u" -- "$@"; }
_owner_ask_spent_dir() { printf '%s/owner-ask/spent' "${STATE_DIR:-/var/lib/5dive}"; }
# One Bot API call. The token rides curl's STDIN config, never argv, so it is not
# in the process table while root holds it (same as the browser's _connect_tg).
_owner_ask_tg() {  # <method> [curl args...]
  local method="$1"; shift
  printf 'url = "%s/bot%s/%s"\n' "$OWNER_ASK_TG_API" "$OWNER_ASK_TOKEN" "$method" \
    | curl -sS --connect-timeout 5 --max-time 20 --config - "$@" 2>/dev/null
}
# The browser's own answer. Root, with SUDO_USER naming the seat, is exactly the
# shape the browser checks the proof for (_sudo_is_seat), so the proof is verified
# a second time by the plugin that owns the grant.
_owner_ask_browser_approve() {  # <seat user> <ask id> <nonce> <deny 0|1>
  local -a a=(approve "$2" "--human-proof=$3")
  [[ "$4" == 1 ]] && a+=(--deny)
  env SUDO_USER="$1" /usr/local/bin/5dive browser "${a[@]}"
}

# The one line an owner reads for a payload, in the browser's fixed order —
# byte-for-byte the jq in the browser's _payload_line (1.15.0). Kept identical on
# purpose: the owner must see here exactly what the ask printed on the box.
_owner_ask_payload_line() {  # <payload-json>
  jq -r 'if type != "object" then "" else
    [ (if (.to // []) | length > 0 then "to " + (.to | join(", ")) else empty end),
      (if .subject then "subject \"" + .subject + "\"" else empty end),
      (if .first_line then "\"" + .first_line + "\"" else empty end),
      (if .payee then "to " + .payee else empty end),
      (if .amount then .amount else empty end),
      (if .text then "\"" + .text + "\"" else empty end),
      (if .item then "\"" + .item + "\"" else empty end) ] | join(" · ") end' <<<"${1:-null}" 2>/dev/null
}

# The ask sentence, as the browser's _owner_ask prints it to the agent.
_owner_ask_sentence() {  # <request-json>
  local req="$1" cls site pline verb what
  cls=$(jq -r '.class // "act"' <<<"$req")
  site=$(jq -r '.site // ""' <<<"$req")
  [[ "$site" == _public ]] || site="${site%%_*}"
  pline=$(_owner_ask_payload_line "$(jq -c '.payload // {}' <<<"$req")")
  case "$cls" in
    pay) verb="pay or place an order" ;; publish) verb="post or publish" ;;
    send) verb="send a message" ;;       delete) verb="delete something" ;;
    *) verb="do something only the owner can allow" ;;
  esac
  if [[ -n "$pline" ]]; then what=": $pline"
  else what=" — the page did not show what it will ${cls/publish/post}; see the screenshot"; fi
  printf 'I am about to %s on %s%s. OK?' "$verb" "$site" "$what"
}

# WHO IS ASKED: one person, the seat's owner, on the seat's own bot — the bot
# whose plugin will relay the tap. Resolved like gate delivery (DIVE-3342): the
# human registry names the person, and the seat's access.json must already let
# them in (the registry narrows, never widens). With no registry, the seat's one
# paired DM; several paired people and no registry is refused, not broadcast —
# a nonce every one of them could spend is not bound to an owner.
# Sets OWNER_ASK_TOKEN OWNER_ASK_OWNER; on failure OWNER_ASK_WHY.
_owner_ask_owner() {  # <seat short name>
  local seat="$1" allow hid="" n
  OWNER_ASK_TOKEN="" OWNER_ASK_OWNER="" OWNER_ASK_WHY=""
  if ! _task_agent_channel "$seat"; then
    OWNER_ASK_WHY="seat agent-${seat} has no paired Telegram bot, so there is nobody to ask"; return 1
  fi
  if [[ "$TASK_CH_TYPE" != claude ]]; then
    OWNER_ASK_WHY="seat agent-${seat}'s Telegram bridge (${TASK_CH_TYPE}) cannot relay an Approve tap yet"; return 1
  fi
  allow=$(jq -r '(.allowFrom // [])[] | tostring | select(test("^[0-9]+$"))' "$TASK_CH_ACCESS" 2>/dev/null)
  if _human_registry_active; then
    hid=$(_human_owner_of_agent "$seat")
    if [[ -z "$hid" ]]; then
      n=$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null)
      [[ "${n:-0}" == 1 ]] && hid=$(db "SELECT id FROM humans LIMIT 1;" 2>/dev/null)
    fi
    [[ -n "$hid" ]] || { OWNER_ASK_WHY="no human owns seat agent-${seat} (sudo 5dive human link <human> --agent=${seat})"; return 1; }
    OWNER_ASK_OWNER=$(_human_transport_id "$hid" telegram)
    [[ "$OWNER_ASK_OWNER" =~ ^[0-9]+$ ]] || { OWNER_ASK_WHY="owner ${hid} has no Telegram id on record"; OWNER_ASK_OWNER=""; return 1; }
    grep -qxF -- "$OWNER_ASK_OWNER" <<<"$allow" \
      || { OWNER_ASK_WHY="owner ${hid} is not paired to agent-${seat}'s bot"; OWNER_ASK_OWNER=""; return 1; }
  else
    n=$(grep -c . <<<"$allow")
    if [[ "$n" != 1 ]]; then
      OWNER_ASK_WHY="agent-${seat}'s bot has ${n} paired people and no owner is named (sudo 5dive human add <id> --telegram=<id>; sudo 5dive human link <id> --agent=${seat})"
      return 1
    fi
    OWNER_ASK_OWNER="$allow"
  fi
  OWNER_ASK_TOKEN="$TASK_CH_TOKEN"
}

# fail, after removing this call's temp files. Not an EXIT trap: main.sh owns
# that one, and replacing it would drop the audit line.
OWNER_ASK_CLEAN=""
_owner_ask_fail() {
  local f
  for f in $OWNER_ASK_CLEAN; do rm -f -- "$f"; done
  fail "$@"
}

# The request directory, pinned: cd -P into it and check that what we are IN is
# owned by the seat. Every later file operation is relative to that inode, so a
# seat that swaps a path component for a symlink after this check moves nothing.
_owner_ask_pin_dir() {  # <seat user> <seat uid>
  local home; home=$(_owner_ask_seat_home "$1")
  [[ -n "$home" ]] || fail "$E_NOT_FOUND" "owner-ask: no home for $1"
  cd -P -- "$home/.5dive/browser-approvals" 2>/dev/null \
    || fail "$E_NOT_FOUND" "owner-ask: $1 has no browser approvals directory"
  [[ "$(stat -c %u . 2>/dev/null)" == "$2" ]] \
    || fail "$E_PERMISSION" "owner-ask: $1's approvals directory is not owned by $1"
  OWNER_ASK_DIR_PATH="$home/.5dive/browser-approvals"
}

_owner_ask_deliver() {  # <seat short name> <request-file>
  local seat="$1" path="$2" user="agent-$1" uid base id req shot="" tmp nonce hash sentence text kb resp label ref
  uid=$(_owner_ask_seat_uid "$user")
  [[ "$uid" =~ ^[0-9]+$ ]] || fail "$E_NOT_FOUND" "owner-ask: no seat $user"
  _owner_ask_pin_dir "$user" "$uid"
  base="${path##*/}"
  [[ "$path" == "$OWNER_ASK_DIR_PATH/$base" ]] \
    || fail "$E_VALIDATION" "owner-ask: $path is not in $user's approvals directory"
  # Exactly <this seat>-<12 hex>.json — the same id a tap rebuilds from the seat
  # and the button's ref, so a seat cannot file an ask under another seat's name.
  [[ "$base" == "$user-"* && "${base#"$user-"}" =~ ^([0-9a-f]{12})\.json$ ]] \
    || fail "$E_VALIDATION" "owner-ask: $base is not one of $user's asks"
  ref="${BASH_REMATCH[1]}"; id="${base%.json}"
  [[ -f "$base" && ! -L "$base" ]] || fail "$E_NOT_FOUND" "owner-ask: no pending ask $id"
  if [[ "$(stat -c %u -- "$base")" == "$(_owner_ask_grant_uid)" ]] \
     && jq -e '(.nonce_hash // "") | test("^[0-9a-f]{64}$")' "$base" >/dev/null 2>&1; then
    fail "$E_CONFLICT" "owner-ask: ask $id was already sent to the owner"
  fi
  [[ "$(stat -c %u -- "$base")" == "$uid" ]] || fail "$E_PERMISSION" "owner-ask: ask $id is not $user's file"

  # READ AS THE SEAT: the seat chose these paths, so root must not be the one who
  # opens them — a request or a screenshot swapped for a symlink to a root-only
  # file then reads as a refusal, not as that file's contents on Telegram.
  req=$(_owner_ask_as_seat "$user" head -c "$OWNER_ASK_REQ_MAX" -- "$OWNER_ASK_DIR_PATH/$base" 2>/dev/null \
        | jq -c 'if type == "object" then . else error("not an object") end' 2>/dev/null) \
    || fail "$E_VALIDATION" "owner-ask: ask $id is not a readable request"
  [[ "$(jq -r '.id // ""' <<<"$req")" == "$id" && "$(jq -r '.seat // ""' <<<"$req")" == "$user" ]] \
    || fail "$E_VALIDATION" "owner-ask: ask $id does not name itself and its seat"

  _owner_ask_owner "$seat" || fail "$E_AUTH_REQUIRED" "owner-ask: not sent — $OWNER_ASK_WHY. The ask still waits for sudo 5dive browser approve $id."

  local sp; sp=$(jq -r '.screenshot // ""' <<<"$req")
  if [[ -n "$sp" ]]; then
    shot=$(mktemp) || fail "$E_GENERIC" "owner-ask: no temp file"
    OWNER_ASK_CLEAN="$shot"
    _owner_ask_as_seat "$user" head -c "$OWNER_ASK_SHOT_MAX" -- "$sp" >"$shot" 2>/dev/null || : >"$shot"
    [[ "$(head -c 8 "$shot" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]] || { rm -f -- "$shot"; shot=""; }
  fi

  nonce=$(_human_nonce_mint) || _owner_ask_fail "$E_GENERIC" "owner-ask: could not mint a nonce; nothing was sent"
  hash=$(_human_nonce_sha "$nonce")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || _owner_ask_fail "$E_GENERIC" "owner-ask: could not hash the nonce; nothing was sent"

  # THE REPLACE: a root-owned temp file beside the request, then one rename. The
  # hash is in place BEFORE the owner can tap, and the seat's file is never
  # opened for writing. -T: a request path swapped for a directory is refused,
  # never moved into.
  tmp=$(mktemp ".owner-ask.XXXXXX") || _owner_ask_fail "$E_GENERIC" "owner-ask: cannot write in $OWNER_ASK_DIR_PATH"
  OWNER_ASK_CLEAN="$shot $OWNER_ASK_DIR_PATH/$tmp"
  jq -c --arg h "$hash" --arg o "$OWNER_ASK_OWNER" --argjson at "$(date +%s)" \
     '. + {nonce_hash:$h, owner_telegram:$o, delivered_at:$at, delivered_by:"5dive owner-ask"}' <<<"$req" >"$tmp" \
    && chmod 0644 "$tmp" && mv -fT -- "$tmp" "$base" \
    || _owner_ask_fail "$E_GENERIC" "owner-ask: could not write the owner's proof into ask $id; nothing was sent"
  tmp=""; OWNER_ASK_CLEAN="$shot"

  label="${seat}"
  sentence=$(_owner_ask_sentence "$req")
  text="🛑 ${label} is waiting for your OK:"$'\n\n'"\"${sentence}\""$'\n\n'"Approve lets it do exactly this, once. Decline cancels it."
  kb=$(jq -nc --arg a "bap:${ref}:${nonce}" --arg d "bdn:${ref}:${nonce}" \
        '{inline_keyboard:[[{text:"✅ Approve",callback_data:$a},{text:"🚫 Decline",callback_data:$d}]]}')
  if [[ -n "$shot" ]]; then
    (( ${#text} <= OWNER_ASK_CAPTION_MAX )) || text="${text:0:$((OWNER_ASK_CAPTION_MAX - 1))}…"
    resp=$(_owner_ask_tg sendPhoto -F "chat_id=$OWNER_ASK_OWNER" -F "photo=@$shot;type=image/png" \
             -F "caption=$text" -F "reply_markup=$kb")
  else
    resp=$(_owner_ask_tg sendMessage --data-urlencode "chat_id=$OWNER_ASK_OWNER" \
             --data-urlencode "text=$text" --data-urlencode "reply_markup=$kb")
  fi
  if [[ "$(jq -r '.ok // false' <<<"$resp" 2>/dev/null)" != true ]]; then
    # Nobody holds this nonce, so its hash must not stand: put the ask back as the
    # seat had it (root-owned, no hash — the browser reads that as "never
    # delivered"), which also lets a later call try again.
    tmp=$(mktemp ".owner-ask.XXXXXX") \
      && jq -c 'del(.nonce_hash, .owner_telegram, .delivered_at, .delivered_by)' <<<"$req" >"$tmp" \
      && chmod 0644 "$tmp" && mv -fT -- "$tmp" "$base"; tmp=""
    audit_log "owner-ask deliver" error 0 -- "seat=$user" "ask=$id" "reason=telegram refused the message" 2>/dev/null || true
    _owner_ask_fail "$E_GENERIC" "owner-ask: Telegram did not take the message, so the owner was not asked. The ask still waits for sudo 5dive browser approve $id."
  fi
  [[ -n "$shot" ]] && rm -f -- "$shot"
  audit_log "owner-ask deliver" ok 0 -- "seat=$user" "ask=$id" "owner_telegram=$OWNER_ASK_OWNER" 2>/dev/null || true
  printf 'sent to the owner on Telegram — one tap on Approve or Decline answers ask %s\n' "$id"
}

_owner_ask_tap() {  # <seat short name> <callback data> <tapper telegram id>
  local seat="$1" data="$2" from="$3" user="agent-$1" uid op ref nonce id base req fd owner_of_file at deny=0 spent rc=0 out
  [[ "$data" =~ ^(bap|bdn):([0-9a-f]{12}):([0-9a-f]{32})$ ]] \
    || fail "$E_VALIDATION" "owner-ask: that is not an Approve/Decline button"
  op="${BASH_REMATCH[1]}" ref="${BASH_REMATCH[2]}" nonce="${BASH_REMATCH[3]}"
  [[ "$op" == bdn ]] && deny=1
  [[ "$from" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "owner-ask: the tap names no Telegram user"
  uid=$(_owner_ask_seat_uid "$user")
  [[ "$uid" =~ ^[0-9]+$ ]] || fail "$E_NOT_FOUND" "owner-ask: no seat $user"
  # THIS SEAT'S ask only: the path is built from the calling seat, never taken
  # from the tap, so a second seat relaying the same button finds nothing.
  _owner_ask_pin_dir "$user" "$uid"
  id="$user-$ref"; base="$id.json"
  [[ -f "$base" ]] \
    || fail "$E_NOT_FOUND" "owner-ask: ask $id is not live on $user (already answered, withdrawn, or never asked)"
  # One open, then every check on what was OPENED (its owner via /proc), so a
  # rename after the check cannot swap in a file of the seat's own.
  # (Braces: a redirect written on `exec` itself would silence stderr for good.)
  { exec {fd}<"$base"; } 2>/dev/null \
    || fail "$E_NOT_FOUND" "owner-ask: ask $id is not live on $user (already answered, withdrawn, or never asked)"
  owner_of_file=$(stat -L -c %u "/proc/self/fd/$fd" 2>/dev/null)
  req=$(head -c "$OWNER_ASK_REQ_MAX" <&"$fd" | jq -c 'if type == "object" then . else error("x") end' 2>/dev/null) || req=""
  exec {fd}<&-
  [[ "$owner_of_file" == "$(_owner_ask_grant_uid)" ]] \
    || fail "$E_PERMISSION" "owner-ask: ask $id was never delivered to the owner, so a tap cannot answer it"
  [[ -n "$req" && "$(jq -r '.id // ""' <<<"$req")" == "$id" ]] \
    || fail "$E_VALIDATION" "owner-ask: ask $id is not a readable request"
  _gate_proof_ct_equal "$(_human_nonce_sha "$nonce")" "$(jq -r '.nonce_hash // ""' <<<"$req")" \
    || fail "$E_PERMISSION" "owner-ask: that button is not the one sent for ask $id"
  # BOUND TO THE OWNER: the tapper is the person it was sent to, and is still the
  # seat's owner now.
  [[ "$(jq -r '.owner_telegram // ""' <<<"$req")" == "$from" ]] \
    || fail "$E_PERMISSION" "owner-ask: ask $id was sent to someone else; only they can answer it"
  _owner_ask_owner "$seat" && [[ "$OWNER_ASK_OWNER" == "$from" ]] \
    || fail "$E_PERMISSION" "owner-ask: $from is no longer agent-${seat}'s owner${OWNER_ASK_WHY:+ ($OWNER_ASK_WHY)}"
  at=$(jq -r '.delivered_at // 0' <<<"$req")
  [[ "$at" =~ ^[0-9]+$ ]] && (( at + OWNER_ASK_TAP_TTL > $(date +%s) )) \
    || fail "$E_PERMISSION" "owner-ask: ask $id is more than a day old; the agent must ask again"
  # ONCE: mkdir is atomic, so two taps (or a tap and a replay) cannot both pass.
  spent=$(_owner_ask_spent_dir)
  mkdir -p -- "$spent" && chmod 700 "$spent" || fail "$E_GENERIC" "owner-ask: cannot record the answer"
  mkdir -- "$spent/$(_human_nonce_sha "$nonce")" 2>/dev/null \
    || fail "$E_CONFLICT" "owner-ask: ask $id was already answered"
  out=$(_owner_ask_browser_approve "$user" "$id" "$nonce" "$deny" 2>&1) || rc=$?
  audit_log "owner-ask tap" "$([[ $rc == 0 ]] && echo ok || echo error)" "$rc" -- \
    "seat=$user" "ask=$id" "answer=$([[ $deny == 1 ]] && echo deny || echo approve)" "tapper=$from" 2>/dev/null || true
  printf '%s\n' "$out"
  return "$rc"
}

# `_owner_ask` — the privileged half, reachable through one exact-path NOPASSWD
# grant. Operation and arguments arrive NUL-separated on stdin; the calling seat
# is SUDO_UID's, never an argument.
cmd_owner_ask_priv() {
  _gate_is_root || fail "$E_PERMISSION" "_owner_ask is a privileged internal primitive (reachable only through its exact-path grant)."
  local -a w=(); local a
  while IFS= read -r -d '' a; do w+=("$a"); done
  local ruid="${SUDO_UID:-}" seat
  [[ "$ruid" =~ ^[0-9]+$ && "$ruid" != 0 ]] || fail "$E_AUTH_REQUIRED" "_owner_ask must be reached through sudo from an agent seat."
  seat=$(_gate_uid_to_agent "$ruid")
  [[ -n "$seat" ]] || fail "$E_AUTH_REQUIRED" "_owner_ask: uid $ruid is not an agent seat."
  tasks_db_init >/dev/null 2>&1 || true
  case "${w[0]:-}" in
    deliver) (( ${#w[@]} == 2 )) || fail "$E_USAGE" "_owner_ask deliver <request-file>"
             _owner_ask_deliver "$seat" "${w[1]}" ;;
    tap)     (( ${#w[@]} == 3 )) || fail "$E_USAGE" "_owner_ask tap <callback-data> <telegram user id>"
             _owner_ask_tap "$seat" "${w[1]}" "${w[2]}" ;;
    *) fail "$E_USAGE" "_owner_ask: deliver or tap" ;;
  esac
}

_owner_ask_usage() {
  cat <<'USAGE'
5dive owner-ask — hand an agent's ask to its owner as one Telegram tap

  5dive owner-ask browser <request-file>
      Run by the browser plugin after it writes an ask. Sends the seat's owner the
      ask (payload line + screenshot) with Approve / Decline, and writes the proof
      the tap will carry into the request as root. Prints one line on success.
  echo '<callback data>' | 5dive owner-ask tap --from=<telegram user id>
      Run by the seat's Telegram plugin when the owner taps bap:/bdn:. Answers the
      ask with 5dive browser approve <id> --human-proof=<nonce> (or --deny).
      The callback data is read from stdin so the nonce is never in argv.
USAGE
}

# The caller half. Always goes through the exact-path grant, even for an admin
# seat whose grant is wider, so every seat takes the same checked path.
_owner_ask_call() {
  if ! "${OWNER_ASK_PRIV[0]}" -n -l "${OWNER_ASK_PRIV[@]:2}" >/dev/null 2>&1; then
    fail "$E_PERMISSION" "this seat has no grant to reach its owner (_owner_ask). The ask still waits for sudo 5dive browser approve on the box."
  fi
  printf '%s\0' "$@" | "${OWNER_ASK_PRIV[@]}"
}

cmd_owner_ask() {
  case "${1:-}" in
    browser)
      shift
      [[ $# == 1 && -n "$1" && "$1" != -* ]] || fail "$E_USAGE" "usage: 5dive owner-ask browser <request-file>"
      _owner_ask_call deliver "$1" ;;
    tap)
      shift
      local from="" data=""
      while (($#)); do
        case "$1" in
          --from=*) from="${1#*=}" ;;
          *) fail "$E_USAGE" "usage: echo '<callback data>' | 5dive owner-ask tap --from=<telegram user id>" ;;
        esac; shift
      done
      [[ -n "$from" ]] || fail "$E_USAGE" "usage: echo '<callback data>' | 5dive owner-ask tap --from=<telegram user id>"
      IFS= read -r data || [[ -n "$data" ]] || fail "$E_USAGE" "owner-ask tap: no callback data on stdin"
      _owner_ask_call tap "$data" "$from" ;;
    -h|--help|help|"") _owner_ask_usage ;;
    *) fail "$E_USAGE" "unknown owner-ask target: $1 (browser | tap)" ;;
  esac
}
