# -------- 5dive owner-ask — the owner answers a browser ask from Telegram (DIVE-4982) --------
#
# THE GAP. A browser act that would send, pay, publish or delete stops with exit 73
# and writes an ask to the seat's ~/.5dive/browser-approvals/<id>.json
# (5dive-browser 1.15.0). The only yes was `sudo 5dive browser approve <id>`, a
# shell command, and an owner on Telegram has no shell. Measured 2026-09-25: an
# owner-ordered send stopped at 73, the owner had no way to answer it, and the
# seat ran the approve itself and was granted.
#
# Part B of three. Part A (5dive-browser) writes the payload into the request and
# refuses a seat's approve without the owner's proof; part C (5dive-plugins) relays
# the tap from per-agent bridges. This part:
#
#   owner-ask browser <request-file>   run by the browser plugin after the stop.
#       Mints a nonce, writes its sha256 into the request AS ROOT, and sends the
#       owner the payload with Approve `bap:<12hex>:<nonce>` and Decline
#       `bdn:<12hex>:<nonce>` (49 bytes; a full id would overflow Telegram's 64).
#   owner-ask tap <data> --tap-uid=<id>   run by the team-bot listener on a tap.
#       Resolves the LIVE request, refuses any tapper who is not the owner, checks
#       the proof, runs `browser approve` (or --deny), spends the nonce and wakes
#       the seat. Nothing is taken from the tapped payload but the proof itself.
#
# ONE ROUTING TABLE. Who the owner is comes from _owner_ask_route: the seat's bot
# and access.json, narrowed by the human registry when it is in use — the lookup
# gate alerts use, and the send goes through _task_send_gate_owner. The tap is
# checked against the SAME function, so the person the ask reached and the person
# whose tap counts cannot drift apart.
#
# WHY ROOT, AND WHY TEMP + RENAME. 5dive-browser trusts nonce_hash only in a
# request the granting uid (root) owns: the request sits in the seat's own
# directory, and a seat-owned file could carry a hash the seat planted. A write in
# place keeps the seat's ownership, so every tap would be refused. The request is
# rewritten as a new root-owned file and renamed over the old one, from INSIDE the
# directory after checking where `cd` landed (the seat owns it and could swap a
# path component for a link). The old request is READ AS THE SEAT: the seat can
# swap it for a link to any file, and root following that link would copy what
# it names into a 0644 file in the seat's directory. The temp file's name carries
# a fresh nonce, so the seat cannot plant it first (noclobber opens an existing
# non-regular file, e.g. a link to a device, without O_EXCL); it is created
# O_EXCL with its final mode (no chmod to follow a link), and `mv -T` renames a
# link rather than writing through it or into it.

# 5dive-browser's APPROVAL_TTL: an ask the owner has not answered in this long is dead.
OWNER_ASK_TTL=1800
OA_ID="" OA_SEAT="" OA_DIR="" OA_HEX=""
OA_ROUTE_WHY="" OA_OWNER_HID="" OA_OWNER_TG=""

_owner_ask_usage() {
  cat <<'EOF'
5dive owner-ask — the owner answers a browser ask from Telegram (DIVE-4982)

  5dive owner-ask browser <request-file>
      Send the ask the browser plugin wrote (<seat home>/.5dive/browser-approvals/
      <seat>-<12 hex>.json) to the box owner, with the payload, the screenshot and
      Approve / Decline. Writes the proof's sha256 into the request as root. With no
      route to the owner it sends nothing and says why (exit 0).
  5dive owner-ask tap <bap|bdn>:<12 hex>:<32 hex> --tap-uid=<telegram user id>
      Root. Apply the owner's tap: approve (bap) or decline (bdn) that ask through
      `5dive browser approve`, and wake the seat. Any other tapper is refused.
EOF
}

# Seams: harnesses drive these instead of the box.
_owner_ask_is_root() { [[ $EUID -eq 0 ]]; }
_owner_ask_passwd() { getent passwd "$@"; }
# The uid a trusted request is owned by — the uid that grants (5dive-browser _grant_uid).
_owner_ask_granter_uid() { printf '0'; }

_owner_ask_user_field() { # <user> <passwd field number>
  _owner_ask_passwd "$1" 2>/dev/null | awk -F: -v u="$1" -v f="$2" '$1 == u { print $f; exit }'
}

# The approvals directory of <user>, exactly as 5dive-browser's _approval_dir builds it.
_owner_ask_dir_of() {
  local home; home=$(_owner_ask_user_field "$1" 6)
  [[ -n "$home" ]] || return 1
  printf '%s/.5dive/browser-approvals' "$home"
}

# _owner_ask_load <request-file> — sets OA_ID / OA_SEAT / OA_HEX / OA_DIR, or fails.
_owner_ask_load() {
  local f="$1" abs dir base want
  abs=$(realpath -e -- "$f" 2>/dev/null) || fail "$E_NOT_FOUND" "no such request file: $f"
  dir="${abs%/*}" base="${abs##*/}"
  [[ "$base" =~ ^(agent-[a-z0-9][a-z0-9._-]*)-([0-9a-f]{12})\.json$ ]] \
    || fail "$E_VALIDATION" "not a browser ask: $base (want <seat>-<12 hex>.json)"
  OA_SEAT="${BASH_REMATCH[1]}" OA_HEX="${BASH_REMATCH[2]}" OA_ID="${base%.json}"
  want=$(_owner_ask_dir_of "$OA_SEAT") && want=$(realpath -e -- "$want" 2>/dev/null) \
    || fail "$E_NOT_FOUND" "seat $OA_SEAT has no browser-approvals directory on this box"
  [[ "$dir" == "$want" ]] || fail "$E_VALIDATION" "$abs is not in ${OA_SEAT}'s approvals directory ($want)"
  [[ "$(stat -c %u -- "$want")" == "$(_owner_ask_user_field "$OA_SEAT" 3)" ]] \
    || fail "$E_VALIDATION" "$want is not owned by $OA_SEAT"
  [[ -f "$abs" && ! -L "$abs" ]] || fail "$E_VALIDATION" "$abs is not a regular file"
  OA_DIR="$want"
  jq -e --arg id "$OA_ID" --arg s "$OA_SEAT" '.id == $id and .seat == $s' "$abs" >/dev/null 2>&1 \
    || fail "$E_VALIDATION" "$abs does not describe ask $OA_ID of $OA_SEAT"
}

# _owner_ask_find <12 hex> — the one pending ask with that tail, on any seat. Sets
# OA_*; 1 when there is none or more than one.
_owner_ask_find() {
  local hex="$1" u home f n=0 hit=""
  while IFS=: read -r u _ _ _ _ home _; do
    [[ "$u" == agent-* && -n "$home" ]] || continue
    f="$home/.5dive/browser-approvals/${u}-${hex}.json"
    [[ -f "$f" && ! -L "$f" ]] || continue
    n=$((n + 1)); hit="$f"
  done < <(_owner_ask_passwd 2>/dev/null)
  (( n == 1 )) || return 1
  ( _owner_ask_load "$hit" ) >/dev/null 2>&1 || return 1
  _owner_ask_load "$hit"
}

# _owner_ask_rewrite <jq filter> [jq args…] — replace the request with a root-owned
# copy passed through <filter>. See the header for why each step has this shape.
_owner_ask_rewrite() {
  local filter="$1"; shift
  local uid salt
  uid=$(_owner_ask_user_field "$OA_SEAT" 3)
  salt=$(_human_nonce_mint) || return 1
  (
    cd -- "$OA_DIR" 2>/dev/null || exit 1
    [[ "$(pwd -P)" == "$OA_DIR" && -n "$uid" && "$(stat -c %u .)" == "$uid" ]] || exit 1
    cur="${OA_ID}.json" tmp=".${OA_ID}.owner-ask.${salt}"
    [[ -f "$cur" && ! -L "$cur" ]] || exit 1
    body=$(_owner_ask_cat_as "$OA_SEAT" "$cur" 2>/dev/null) || exit 1
    umask 022; set -C
    jq "$@" "$filter" <<<"$body" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; exit 1; }
    mv -fT -- "$tmp" "$cur"
  )
}

# _owner_ask_route <agent name> — who owns this seat's asks, and on which bot.
# Sets TASK_CH_* (the seat's channel), OA_OWNER_HID (registry only) and OA_OWNER_TG
# (the owner's Telegram ids, one per line). 1 with OA_ROUTE_WHY when there is nobody.
# With the registry in use it is the one person the seat's gates belong to (linked
# up the org chart, or the sole human on record), and only if that person is paired
# to the seat's bot; without it, the users paired to that bot (access.json allowFrom),
# the people _task_send_owner DMs.
_owner_ask_route() {
  local name="$1" chat
  OA_ROUTE_WHY="" OA_OWNER_HID="" OA_OWNER_TG=""
  if ! _task_agent_channel "$name"; then
    OA_ROUTE_WHY="seat ${name} has no paired Telegram channel (no bot token or access.json)"
    return 1
  fi
  if _human_registry_active; then
    OA_OWNER_HID=$(_human_owner_of_agent "$name")
    if [[ -z "$OA_OWNER_HID" && "$(db "SELECT COUNT(*) FROM humans;" 2>/dev/null)" == "1" ]]; then
      OA_OWNER_HID=$(db "SELECT id FROM humans LIMIT 1;" 2>/dev/null)
    fi
    if [[ -z "$OA_OWNER_HID" ]]; then
      OA_ROUTE_WHY="no human owns seat ${name} (sudo 5dive human link <human> --agent=${name})"
      return 1
    fi
    chat=$(_human_transport_id "$OA_OWNER_HID" telegram)
    if [[ -z "$chat" ]]; then
      OA_ROUTE_WHY="owner ${OA_OWNER_HID} has no telegram id on record (sudo 5dive human add ${OA_OWNER_HID} --telegram=<chat id>)"
      return 1
    fi
    if ! jq -e --arg c "$chat" '(.allowFrom // []) | index($c) != null' "$TASK_CH_ACCESS" >/dev/null 2>&1; then
      OA_ROUTE_WHY="owner ${OA_OWNER_HID} is not paired to ${name}'s bot"
      return 1
    fi
    OA_OWNER_TG="$chat"
  else
    OA_OWNER_TG=$(jq -r '(.allowFrom // [])[] | tostring' "$TASK_CH_ACCESS" 2>/dev/null)
    if [[ -z "$OA_OWNER_TG" ]]; then
      OA_ROUTE_WHY="nobody is paired to ${name}'s bot (access.json allowFrom is empty)"
      return 1
    fi
  fi
}

# The ask as the owner reads it: who, what, on which site, and the payload the
# page showed. Every value is the seat's, so control and format characters go and
# each line is capped; the message is sent as plain text (no parse_mode).
_owner_ask_text() { # <request json> <agent name>
  jq -r --arg n "$2" --argjson ttl "$OWNER_ASK_TTL" '
    def c: tostring | gsub("[\\p{Cc}\\p{Cf}]"; " ") | if length > 200 then .[0:200] + "…" else . end;
    (.payload // {}) as $p
    | ({send: "send a message", pay: "pay or place an order", publish: "post or publish", delete: "delete something"}[.class // ""]
       // "do something only you can allow") as $verb
    | [ "🌐 \($n | c) asks: \($verb) on \(.site // "?" | c)" ]
      + [ ($p | to_entries[] | select(.value != null and .value != "")
             | "\({first_line: "first line"}[.key] // .key | c): \(.value | if type == "array" then map(tostring) | join(", ") else . end | c)") ]
      + (if ($p | length) == 0 then ["(the page did not show what it will do — see the screenshot)"] else [] end)
      + [ "step \(.step // "?" | c): button \"\(.label // "" | c)\"",
          "id: \(.id)",
          "Approve runs exactly these steps, once, within \($ttl / 60 | floor) minutes. Decline drops the ask." ]
    | join("\n")' <<<"$1" 2>/dev/null
}

# The screenshot follows the ask, best-effort. Read AS THE SEAT (the path is the
# seat's to name, so root must not open it on the seat's behalf) and sent only if
# it is a PNG.
_owner_ask_cat_as() { # <user> <path>
  if [[ $EUID -eq 0 ]]; then runuser -u "$1" -- cat -- "$2"; else cat -- "$2"; fi
}
_owner_ask_post_photo() { # <token> <chat> <thread> <reply-to> <file> <caption>
  local -a a=(-F "chat_id=$2" -F "caption=$6" -F "photo=@$5;type=image/png")
  [[ -n "$3" ]] && a+=(-F "message_thread_id=$3")
  [[ -n "$4" ]] && a+=(-F "reply_to_message_id=$4")
  curl -fsS --max-time 20 "${a[@]}" "https://api.telegram.org/bot$1/sendPhoto" >/dev/null 2>&1
}
_owner_ask_screenshot() { # <request json>
  local shot tmp t i=0 chat thread mid
  [[ -z "${FIVEDIVE_NOTIFY_DRYRUN:-}" || "${FIVEDIVE_NOTIFY_DRYRUN}" == "0" ]] || return 0
  shot=$(jq -r '.screenshot // ""' <<<"$1" 2>/dev/null)
  [[ "$shot" == /* ]] || return 0
  tmp=$(mktemp) || return 0
  if _owner_ask_cat_as "$OA_SEAT" "$shot" 2>/dev/null | head -c 10485760 > "$tmp" \
     && [[ "$(head -c 8 "$tmp" | od -An -tx1 | tr -d ' \n')" == 89504e470d0a1a0a ]]; then
    local -a mids=()
    IFS=',' read -r -a mids <<<"${TASK_SEND_MESSAGE_IDS:-}"
    local IFS=','
    for t in ${TASK_SEND_TARGETS:-}; do
      chat="${t%%:*}" thread=""; [[ "$t" == *:* ]] && thread="${t#*:}"
      mid="${mids[$i]:-}"; i=$((i + 1))
      _owner_ask_post_photo "$TASK_CH_TOKEN" "$chat" "$thread" "$mid" "$tmp" "the page before the step — $OA_ID" || true
    done
  fi
  rm -f -- "$tmp"
}

# A seat's own run of `owner-ask browser` re-runs itself as root through the seat's
# sudo grant. 1 when the seat has none (a standard seat): the ask then stays on the shell.
_owner_ask_escalate() { # <abs request file>
  local -a j=()
  (( JSON_MODE )) && j=(--json)
  sudo -n -l 5dive owner-ask browser "$1" >/dev/null 2>&1 || return 1
  exec sudo -n 5dive "${j[@]}" owner-ask browser "$1"
}

_owner_ask_not_sent() { # <reason>
  if (( JSON_MODE )); then
    jq -cn --arg id "$OA_ID" --arg r "$1" '{ok:true, data:{sent:false, id:$id, reason:$r}}'
  else
    printf 'not sent to the owner: %s\n' "$1"
  fi
  return 0
}

_owner_ask_browser() {
  local f="" a
  for a in "$@"; do
    case "$a" in
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$f" ]] || fail "$E_USAGE" "usage: 5dive owner-ask browser <request-file>"; f="$a" ;;
    esac
  done
  [[ -n "$f" ]] || fail "$E_USAGE" "usage: 5dive owner-ask browser <request-file>"
  if ! _owner_ask_is_root; then
    local abs; abs=$(realpath -e -- "$f" 2>/dev/null) || fail "$E_NOT_FOUND" "no such request file: $f"
    _owner_ask_escalate "$abs" \
      || _owner_ask_not_sent "the owner's proof is written as root and this seat has no sudo grant for owner-ask; the ask stays on the shell (sudo 5dive browser approve <id>)"
    return 0
  fi
  _owner_ask_load "$f"
  # A seat asks for itself. sudo stamps SUDO_USER truthfully at EUID 0.
  if [[ "${SUDO_USER:-}" == agent-* && "$SUDO_USER" != "$OA_SEAT" ]]; then
    fail "$E_PERMISSION" "$SUDO_USER cannot send ${OA_SEAT}'s ask"
  fi
  local name="${OA_SEAT#agent-}"
  _owner_ask_route "$name" || { _owner_ask_not_sent "$OA_ROUTE_WHY"; return 0; }

  local nonce hash body text markup
  nonce=$(_human_nonce_mint) || { _owner_ask_not_sent "could not mint the owner's proof"; return 0; }
  hash=$(_human_nonce_sha "$nonce")
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { _owner_ask_not_sent "could not hash the owner's proof"; return 0; }
  # The hash lands BEFORE the send, so a tap can never arrive ahead of it. A send
  # that then fails leaves a hash whose nonce nobody holds, which refuses nothing
  # the owner can do from the shell.
  _owner_ask_rewrite '. + {nonce_hash: $h, owner_asked_at: $at}' --arg h "$hash" --argjson at "$(date +%s)" \
    || { _owner_ask_not_sent "could not write the owner's proof into $OA_DIR/$OA_ID.json"; return 0; }
  # Read back as the seat, like the rewrite: the seat can swap the file again.
  body=$(_owner_ask_cat_as "$OA_SEAT" "$OA_DIR/$OA_ID.json" 2>/dev/null)
  text=$(_owner_ask_text "$body" "$name")
  [[ -n "$text" ]] || text="🌐 ${name} asks for your approval — id: ${OA_ID}"
  markup=$(jq -cn --arg a "bap:${OA_HEX}:${nonce}" --arg d "bdn:${OA_HEX}:${nonce}" \
    '{inline_keyboard: [[{text: "✅ Approve", callback_data: $a}, {text: "❌ Decline", callback_data: $d}]]}')
  _task_send_gate_owner "$text" "$markup" "" "$OA_OWNER_HID"
  if [[ "${TASK_SEND_DELIVERED:-0}" != "1" ]]; then
    _owner_ask_not_sent "the Telegram send to the owner was not confirmed"
    return 0
  fi
  _owner_ask_screenshot "$body"
  if (( JSON_MODE )); then
    jq -cn --arg id "$OA_ID" --arg t "${TASK_SEND_TARGETS:-}" '{ok:true, data:{sent:true, id:$id, targets:$t}}'
  else
    printf 'sent to the owner on Telegram with Approve / Decline (%s) — their tap answers it; nothing runs before then.\n' "${TASK_SEND_TARGETS:-}"
  fi
}

# A refused tap is logged (the audit row carries the reason, never the nonce) and
# answered with the reason, which the listener shows the tapper.
_owner_ask_refuse() { # <reason>
  AUDIT_ARGS+=("refused=$1")
  fail "$E_PERMISSION" "$1"
}

_owner_ask_run() { # <seconds> <5dive args…> — the CLI, from root, as the row it answers says
  local t="$1"; shift
  timeout "$t" sudo -n 5dive "$@"
}
_owner_ask_browser_approve() { # <id> <nonce> [--deny]
  _owner_ask_run 20 browser approve "$1" "--human-proof=$2" ${3:+"$3"}
}
_owner_ask_wake() { # <agent name> <message>
  _owner_ask_run 15 agent send "$1" "--message=$2" >/dev/null 2>&1
}

_owner_ask_tap() {
  local data="" uid="" a
  for a in "$@"; do
    case "$a" in
      --tap-uid=*) uid="${a#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$data" ]] || fail "$E_USAGE" "usage: 5dive owner-ask tap <bap|bdn>:<12 hex>:<32 hex> --tap-uid=<id>"; data="$a" ;;
    esac
  done
  [[ "$data" =~ ^(bap|bdn):([0-9a-f]{12}):([0-9a-f]{32})$ ]] \
    || fail "$E_VALIDATION" "not an owner-ask button (want bap|bdn:<12 hex>:<32 hex>)"
  local kind="${BASH_REMATCH[1]}" hex="${BASH_REMATCH[2]}" nonce="${BASH_REMATCH[3]}"
  AUDIT_ARGS=("button=${kind}:${hex}" "tap_uid=${uid}")
  [[ "$uid" =~ ^-?[0-9]{1,20}$ ]] || fail "$E_USAGE" "--tap-uid=<telegram user id> is required"
  _owner_ask_is_root || fail "$E_PERMISSION" "owner-ask tap runs as root (sudo 5dive owner-ask tap …)"

  # One tap at a time: the check and the spend below must not interleave.
  local lock="${STATE_DIR:-/var/lib/5dive}/owner-ask.lock" fd
  exec {fd}>>"$lock" && flock -w 10 "$fd" || fail "$E_GENERIC" "cannot take $lock"

  _owner_ask_find "$hex" \
    || _owner_ask_refuse "no pending ask ${hex}: it was already answered, spent or expired — nothing was authorised"
  AUDIT_ARGS+=("id=${OA_ID}")
  local name="${OA_SEAT#agent-}" req="$OA_DIR/$OA_ID.json"
  _owner_ask_route "$name" || _owner_ask_refuse "no owner route for ${name}: ${OA_ROUTE_WHY}"
  grep -qxF -- "$uid" <<<"$OA_OWNER_TG" || _owner_ask_refuse "only the box owner can answer ask ${OA_ID}"

  local want asked
  [[ "$(stat -c %u -- "$req" 2>/dev/null)" == "$(_owner_ask_granter_uid)" ]] \
    || _owner_ask_refuse "ask ${OA_ID} carries no owner proof (it was never sent to the owner)"
  want=$(jq -r '.nonce_hash // ""' "$req" 2>/dev/null)
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || _owner_ask_refuse "ask ${OA_ID} was already answered — this button is spent"
  _gate_proof_ct_equal "$(_human_nonce_sha "$nonce")" "$want" \
    || _owner_ask_refuse "this button is stale: a newer ask for ${OA_ID} replaced it"
  asked=$(jq -r '.asked_at // 0 | floor' "$req" 2>/dev/null)
  [[ "$asked" =~ ^[0-9]+$ ]] && (( asked + OWNER_ASK_TTL > $(date +%s) )) \
    || _owner_ask_refuse "ask ${OA_ID} expired — nothing was authorised; ask again"

  local answer="approved" out
  [[ "$kind" == bdn ]] && answer="declined"
  if [[ "$answer" == approved ]]; then
    out=$(_owner_ask_browser_approve "$OA_ID" "$nonce" 2>&1) || fail "$E_GENERIC" "browser approve failed for ${OA_ID}: ${out##*$'\n'}"
    # Spent: the grant is written, so this proof must not grant twice.
    _owner_ask_rewrite 'del(.nonce_hash) + {owner_answer: $a, owner_answered_at: $at}' \
      --arg a "$answer" --argjson at "$(date +%s)" || warn "ask ${OA_ID}: could not mark the proof spent"
    _owner_ask_wake "$name" "The owner APPROVED browser ask ${OA_ID} on Telegram. Re-run the waiting act with --approved=${OA_ID}." \
      || warn "could not wake ${name}"
  else
    # --deny removes the request, and the proof with it.
    out=$(_owner_ask_browser_approve "$OA_ID" "$nonce" --deny 2>&1) || fail "$E_GENERIC" "browser approve --deny failed for ${OA_ID}: ${out##*$'\n'}"
    if [[ -f "$req" ]]; then
      _owner_ask_rewrite 'del(.nonce_hash) + {owner_answer: $a, owner_answered_at: $at}' \
        --arg a "$answer" --argjson at "$(date +%s)" || warn "ask ${OA_ID}: could not mark the proof spent"
    fi
    _owner_ask_wake "$name" "The owner DECLINED browser ask ${OA_ID} on Telegram. Do not re-run it." \
      || warn "could not wake ${name}"
  fi
  AUDIT_ARGS+=("answer=${answer}")
  ok "${answer}: ${OA_ID}" '{result: $r, id: $id, seat: $s}' --arg r "$answer" --arg id "$OA_ID" --arg s "$OA_SEAT"
}

cmd_owner_ask() {
  [[ $# -gt 0 ]] || { _owner_ask_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    browser) _owner_ask_browser "$@" ;;
    tap) _owner_ask_tap "$@" ;;
    -h|--help|help) _owner_ask_usage ;;
    *) fail "$E_USAGE" "usage: 5dive owner-ask browser|tap (try: 5dive owner-ask --help)" ;;
  esac
}
