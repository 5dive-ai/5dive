# ── DIVE-5396: `5dive hire-link <slug>` — the link a lead sends to hire someone ─
#
# Asked "hire Marcus", a STANDARD-tier agent cannot run `agent import` (it needs
# root), so it sends the owner a link and the owner hires in one tap. This
# prints that link; the agent never builds a URL by hand. DIVE-5449: an
# ADMIN-tier agent hires itself instead — on a box that is up, the Mini App's
# Hire is exactly `agent import <slug> --as= --isolation= --auth-profile=`
# (5dive-frontend hireCalls), so `sudo 5dive agent import` is the same hire; only
# the new agent's own Telegram bot still needs the owner's tap (Connect on its
# row in the Mini App). Neither path bills: Stars are sold only when there is
# no box yet.
#
# Which link is the API's call (POST /server/telegram/hire-link, box-authed with
# this box's connectord token): an owner who signs in with Telegram gets
# https://t.me/<bot>?startapp=agent-<slug>, which opens the Mini App on that
# agent's Hire card in the account this box belongs to; a web owner gets the
# dashboard's new-agent page (the Mini App would open a different account). A
# partner's box hires in the partner's own app, which 5dive has no link for.
#
# The slug is checked against the catalogue first, so a custom agent gets a
# plain answer: the Mini App has no custom-agent tile, so it is made on the web.
#
# Every definitive answer is ok:true with data.status:
#   ready          data.url is the link (data.channel miniapp | web)
#   not_catalogue  no catalogue agent by that slug
#   partner_box    hire in the partner's app
#   unavailable    no box identity (a self-hosted box)
#   error          the API could not be reached or said something unexpected

_hire_link_answer() { # <status> <prose> [url] [channel]
  if (( ${JSON_MODE:-0} )); then
    ok "$2" '{status:$s, url:(if $u == "" then null else $u end), channel:(if $c == "" then null else $c end), slug:$g}' \
      --arg s "$1" --arg u "${3:-}" --arg c "${4:-}" --arg g "$HIRE_LINK_SLUG"
  elif [[ "$1" == ready ]]; then
    printf '%s\n' "$3"
  else
    printf '%s\n' "$2"
  fi
}

cmd_hire_link() {
  local slug="" a
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      -h|--help)
        printf '%s\n' \
          "usage: 5dive hire-link <slug> [--json]" \
          "" \
          "  The link that hires catalogue agent <slug> in one tap, for this box's owner." \
          "  A standard-tier agent sends it to its human; an admin-tier agent hires itself" \
          "  with sudo 5dive agent import <slug> --as=<name>. Slugs: 5dive market."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$slug" ]] || fail "$E_USAGE" "one agent at a time"; slug="$a" ;;
    esac
  done
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive hire-link <slug>   (slugs: 5dive market)"
  slug="${slug,,}"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "$E_VALIDATION" "'${slug:0:40}' is not a catalogue slug"
  HIRE_LINK_SLUG="$slug"

  # The catalogue check is best-effort: an unreachable index must not stop a
  # real hire, only an index that answers without the slug does.
  local idx
  if idx=$(_marketplace_index 2>/dev/null) && jq -e '.packs | type == "array"' >/dev/null 2>&1 <<<"$idx"; then
    if ! jq -e --arg s "$slug" 'any(.packs[]; .slug == $s)' >/dev/null 2>&1 <<<"$idx"; then
      _hire_link_answer not_catalogue "'$slug' is not in the 5dive catalogue (5dive market lists who is). A custom agent has no Mini App tile: your human makes it on the web dashboard, Agents, New agent, Custom."
      return 0
    fi
  fi

  local env_file token=""
  env_file=$(_tg_app_env_file)
  if [[ ! -e "$env_file" ]]; then
    _hire_link_answer unavailable "this box has no 5dive account, so there is no hire link: the owner adds agents with 5dive agent import $slug"
    return 0
  fi
  [[ -r "$env_file" ]] || fail "$E_PERMISSION" "this seat cannot read the box identity ($env_file); ask your lead for the link"
  token=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  if [[ -z "$token" ]]; then
    _hire_link_answer unavailable "this box has no 5dive account identity (no CONNECTORD_TOKEN)"
    return 0
  fi

  local out code body url channel err
  out=$(printf 'header = "authorization: Bearer %s"\n' "$token" \
    | curl -sS --max-time 12 -K - -X POST -H 'content-type: application/json' \
        -w '\n%{http_code}' --data-binary "$(jq -nc --arg s "$slug" '{slug:$s}')" \
        "$(_tg_app_api)/server/telegram/hire-link" 2>/dev/null) || out=""
  token=""
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  url=$(jq -r '.url // empty' <<<"$body" 2>/dev/null || true)
  channel=$(jq -r '.channel // empty' <<<"$body" 2>/dev/null || true)
  err=$(jq -r '.error // empty' <<<"$body" 2>/dev/null || true)
  case "$code" in
    200)
      if [[ "$channel" == miniapp && "$url" =~ ^https://t\.me/[A-Za-z0-9_]+\?startapp=agent-${slug}$ ]] \
         || [[ "$channel" == web && "$url" =~ ^https://[A-Za-z0-9.-]+/dashboard/agents/new$ ]]; then
        _hire_link_answer ready "$url" "$url" "$channel"
      else
        _hire_link_answer error "5dive answered without a usable hire link"
      fi ;;
    403) if [[ "$err" == partner_box ]]; then
           _hire_link_answer partner_box "this box's owner hires in their partner's app, not with a 5dive link"
         else
           _hire_link_answer error "5dive refused this box (${err:-403})"
         fi ;;
    *) _hire_link_answer error "could not get a hire link from 5dive (${code:-no answer}); try again shortly" ;;
  esac
}
