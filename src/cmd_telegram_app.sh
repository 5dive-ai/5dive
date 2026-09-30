# ── DIVE-5185: `5dive telegram-app link` — an existing customer's way into the
# my.5dive.ai Mini App, from their own agent's bot ─────────────────────────────
#
# The telegram plugin's /app command runs this with the id of the Telegram user
# who tapped it. We ask 5dive-api for a one-time Mini App link (box-authed with
# this box's connectord token) that signs THAT Telegram user into the box
# owner's EXISTING 5dive account, the one the dashboard shows. The link is bound
# to that id and lasts 15 minutes; the API refuses a partner box.
#
# The box vouches for the tapper, so this verb checks it first: the id must be
# in the calling seat's own Telegram allowlist (access.json allowFrom), the list
# the plugin already gates every DM on. A seat cannot ask for a link for a chat
# it does not answer.
#
# `5dive config telegram-app=off` turns the button off for the whole box.
#
# Every definitive answer is ok:true with data.status, so the plugin's runner
# (which escalates to sudo on ok:false) asks for root ONLY when the token file
# is unreadable as the seat:
#   ready          data.url is the link
#   off            the box turned the button off
#   not_paired     the id is not in this seat's allowlist
#   partner_box    a partner box; its bot has the partner's own account button
#   unavailable    no box identity (self-hosted), or the Mini App is not live
#   other_telegram the owner's account is linked to a different Telegram
#   taken          that Telegram belongs to another 5dive account
#   error          the API could not be reached or said something unexpected

_tg_app_api() { local b="${FIVE_API_BASE:-https://api.5dive.com}"; printf '%s' "${b%/}"; }
_tg_app_env_file() { printf '%s' "${FIVEDIVE_CONNECTORD_ENV:-/etc/5dive/connectord.env}"; }
# The seat asking: the sudo caller, else whoever runs it.
_tg_app_caller() { printf '%s' "${SUDO_USER:-$(id -un 2>/dev/null)}"; }
_tg_app_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }
_tg_app_box_setting() { jq -r '.telegram_app // "on"' <<<"$(_box_config_read)" 2>/dev/null || printf on; }

# The caller's allowlist, over every agent type's channel dir (the same set
# _tg_access_state_dir resolves; antigravity keeps its under ~/.gemini).
_tg_app_paired() { # <user> <telegram id>
  local home f d
  home=$(_tg_app_home "$1"); [[ -n "$home" ]] || return 1
  for d in .claude .codex .grok .pi .gemini .opencode; do
    f="$home/$d/channels/telegram/access.json"
    [[ -r "$f" ]] || continue
    jq -e --arg id "$2" '(.allowFrom // []) | map(tostring) | index($id) != null' "$f" >/dev/null 2>&1 && return 0
  done
  return 1
}

# <token> <json body> -> "<http status> <body>" on stdout. The token goes to curl
# on stdin as a config line, never argv (the shape the partner plugin's sysadmin notify uses).
_tg_app_post() {
  printf 'header = "authorization: Bearer %s"\n' "$1" \
    | curl -sS --max-time 12 -K - -X POST -H 'content-type: application/json' \
        -w '\n%{http_code}' --data-binary "$2" "$(_tg_app_api)/server/telegram/link-code" 2>/dev/null
}

_tg_app_answer() { # <status> <prose> [url]
  ok "$2" '{status:$s, url:(if $u == "" then null else $u end)}' --arg s "$1" --arg u "${3:-}"
}

cmd_telegram_app() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    link) ;;
    -h|--help|"")
      printf '%s\n' \
        "usage: 5dive telegram-app link --telegram-id=<id> [--json]" \
        "" \
        "  A one-time link (15 minutes) that opens the 5dive Mini App in Telegram," \
        "  signed into this box owner's 5dive account, for that Telegram user only." \
        "  The id must be in the calling seat's Telegram allowlist. The telegram" \
        "  plugin's /app command runs this. Turn it off box-wide with" \
        "  '5dive config telegram-app=off'."
      return 0 ;;
    *) fail "$E_USAGE" "usage: 5dive telegram-app link --telegram-id=<id> [--json]" ;;
  esac

  local tid=""
  while (( $# )); do
    case "$1" in
      --telegram-id=*) tid="${1#*=}" ;;
      --json) JSON_MODE=1 ;;
      *) fail "$E_USAGE" "unknown flag: $1" ;;
    esac
    shift
  done
  [[ "$tid" =~ ^[1-9][0-9]{4,15}$ ]] || fail "$E_VALIDATION" "--telegram-id takes a Telegram user id (digits) — got '${tid:0:20}'"

  if [[ "$(_tg_app_box_setting)" == off ]]; then
    _tg_app_answer off "the Telegram app button is off on this box (5dive config telegram-app=on turns it back on)"
    return 0
  fi
  local caller; caller=$(_tg_app_caller)
  if ! _tg_app_paired "$caller" "$tid"; then
    _tg_app_answer not_paired "Telegram user ${tid} is not in ${caller}'s Telegram allowlist"
    return 0
  fi

  local env_file token=""
  env_file=$(_tg_app_env_file)
  if [[ ! -e "$env_file" ]]; then
    _tg_app_answer unavailable "this box has no 5dive account identity (no ${env_file})"
    return 0
  fi
  # Exists but unreadable as this seat: the one answer that asks for root.
  [[ -r "$env_file" ]] || fail "$E_PERMISSION" "reading this box's identity needs root: sudo 5dive telegram-app link"
  token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  if [[ -z "$token" ]]; then
    _tg_app_answer unavailable "this box has no 5dive account identity (no CONNECTORD_TOKEN)"
    return 0
  fi

  local out code body err url
  out=$(_tg_app_post "$token" "$(jq -nc --arg t "$tid" '{telegramId:$t}')") || out=""
  token=""
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  err=$(jq -r '.error // empty' <<<"$body" 2>/dev/null || true)
  url=$(jq -r '.url // empty' <<<"$body" 2>/dev/null || true)
  case "$code" in
    200)
      if [[ "$url" =~ ^https://t\.me/[A-Za-z0-9_]+\?startapp=link_[A-Za-z0-9_-]+$ ]]; then
        _tg_app_answer ready "open within 15 minutes: $url" "$url"
      else
        _tg_app_answer error "5dive answered without a usable link"
      fi ;;
    403) [[ "$err" == partner_box ]] && _tg_app_answer partner_box "a partner box: its bot carries the partner's own account button" \
           || _tg_app_answer error "5dive refused this box (${err:-403})" ;;
    409) case "$err" in
           account_has_other_telegram) _tg_app_answer other_telegram "this 5dive account is linked to a different Telegram account" ;;
           telegram_taken) _tg_app_answer taken "Telegram user ${tid} belongs to another 5dive account" ;;
           *) _tg_app_answer error "5dive refused the link (${err:-409})" ;;
         esac ;;
    503) _tg_app_answer unavailable "the 5dive Telegram app is not available yet" ;;
    *)   _tg_app_answer error "could not reach 5dive (${code:-no answer})" ;;
  esac
}
