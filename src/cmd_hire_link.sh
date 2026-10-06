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
# The slug is checked against the catalogue first, so a name that is neither a
# catalogue agent nor one the owner made gets a plain answer, and the way to
# make one.
#
# DIVE-5722: a lead makes a custom agent from what its owner needs, from chat.
#   5dive hire-link --create --name=<Name> --description=<the need>
# runs the Mini App's own create for the owner (POST /server/custom-agents):
# the lead writes the name and the description, Jev picks the skills, role,
# voice and gender, exactly as in the Mini App. It hires nothing. It prints the
# draft and its card link (5dive hire-link custom-<id>, the Mini App opened on
# its Hire card), and the hire is the owner's: a Hire tap on the card, or, by an
# admin-tier seat on the owner's clear yes in chat (DIVE-5449's rule),
#   5dive hire-link custom-<id> --hire
# the Mini App's Hire onto this box. A standard seat is refused --hire: it holds
# the root grant for this verb only to reach the box identity. These verbs live
# here, not in a new one, so a standard seat needs no new grant.
#
# Every definitive answer is ok:true with data.status:
#   ready          data.url is the link (data.channel miniapp | web)
#   made           --create: data.id/slug/name/role/skills; data.url is the card
#                  link, or null when the owner has no card (no_card prose)
#   hired          --hire: data.name is the agent on the box
#   hiring         --hire: still importing when the wait ran out; run it again
#   not_catalogue  no catalogue agent by that slug
#   not_found      custom-<id> is not an agent this box's owner made
#   no_hire_card   custom-<id>: the owner signs in on the web, which has no card for it
#   invalid        --create: the name or description was refused (data.error)
#   limit          --create: the owner's day of made agents is spent
#   tier           --hire from a standard-tier seat
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

_HIRE_LINK_CUSTOM_RE='^custom-[a-z0-9]{12}$'

cmd_hire_link() {
  local slug="" a create=0 hire=0 name="" desc="" have_name=0 have_desc=0
  for a in "$@"; do
    case "$a" in
      --json) JSON_MODE=1 ;;
      --create) create=1 ;;
      --hire) hire=1 ;;
      --name=*) name="${a#--name=}"; have_name=1 ;;
      --description=*) desc="${a#--description=}"; have_desc=1 ;;
      -h|--help)
        printf '%s\n' \
          "usage: 5dive hire-link <slug> [--json]" \
          "       5dive hire-link --create --name=<Name> --description=<what they need> [--json]" \
          "       5dive hire-link custom-<id> --hire [--json]   (admin-tier, on the owner's yes)" \
          "" \
          "  The link that hires catalogue agent <slug> in one tap, for this box's owner." \
          "  A standard-tier agent sends it to its human; an admin-tier agent hires itself" \
          "  with sudo 5dive agent import <slug> --as=<name>. Slugs: 5dive market." \
          "  --create makes a custom agent for a need no catalogue agent fits, as the Mini" \
          "  App does (its skills are picked for you), and prints the draft and its card." \
          "  Nothing is hired until the owner taps Hire on the card, or says yes to an" \
          "  admin-tier agent, which then runs --hire."
        return 0 ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *) [[ -z "$slug" ]] || fail "$E_USAGE" "one agent at a time"; slug="$a" ;;
    esac
  done
  if (( create )); then
    [[ -z "$slug" ]] || fail "$E_USAGE" "--create makes a new agent; it takes --name= and --description=, not a slug"
    (( ! hire )) || fail "$E_USAGE" "--create hires nothing: show your owner the draft, then --hire on their yes"
    (( have_name && have_desc )) || fail "$E_USAGE" "usage: 5dive hire-link --create --name=<Name> --description=<what they need>"
    HIRE_LINK_SLUG=""
    _hire_link_create "$name" "$desc" "$@"
    return 0
  fi
  (( ! have_name && ! have_desc )) || fail "$E_USAGE" "--name= and --description= go with --create"
  [[ -n "$slug" ]] || fail "$E_USAGE" "usage: 5dive hire-link <slug>   (slugs: 5dive market)"
  slug="${slug,,}"
  [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "$E_VALIDATION" "'${slug:0:40}' is not a catalogue slug"
  HIRE_LINK_SLUG="$slug"
  if (( hire )); then
    [[ "$slug" =~ $_HIRE_LINK_CUSTOM_RE ]] \
      || fail "$E_USAGE" "--hire is for an agent made with --create (custom-<id>); a catalogue agent is hired with sudo 5dive agent import $slug"
    _hire_link_hire "$slug" "$@"
    return 0
  fi

  # The catalogue check is best-effort: an unreachable index must not stop a
  # real hire, only an index that answers without the slug does. A made agent
  # (custom-<id>) is never in it; the API checks it is this owner's.
  local idx
  if [[ ! "$slug" =~ $_HIRE_LINK_CUSTOM_RE ]] && idx=$(_marketplace_index 2>/dev/null) \
     && jq -e '.packs | type == "array"' >/dev/null 2>&1 <<<"$idx"; then
    if ! jq -e --arg s "$slug" 'any(.packs[]; .slug == $s)' >/dev/null 2>&1 <<<"$idx"; then
      _hire_link_answer not_catalogue "'$slug' is not in the 5dive catalogue (5dive market lists who is). For a need no catalogue agent fits, make one: 5dive hire-link --create --name=<Name> --description=<what they need>"
      return 0
    fi
  fi

  _hire_link_token "$@" || return 0
  _hire_link_link "$slug"
}

# _hire_link_token <argv...> — the box identity into HIRE_LINK_TOKEN. Returns 1
# after answering when there is none. DIVE-5690: a standard seat cannot read it
# and re-runs the whole verb as root through its exact-path grant.
_hire_link_token() {
  local env_file
  HIRE_LINK_TOKEN=""
  env_file=$(_tg_app_env_file)
  if [[ ! -e "$env_file" ]]; then
    _hire_link_answer unavailable "this box has no 5dive account, so there is no hire link: the owner adds agents with 5dive agent import ${HIRE_LINK_SLUG:-<slug>}"
    return 1
  fi
  [[ -r "$env_file" ]] || box_identity_elevate hire-link "$@"
  [[ -r "$env_file" ]] || fail "$E_PERMISSION" "this seat cannot read the box identity ($env_file); ask your lead for the link"
  HIRE_LINK_TOKEN=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$env_file" | head -1)
  if [[ -z "$HIRE_LINK_TOKEN" ]]; then
    _hire_link_answer unavailable "this box has no 5dive account identity (no CONNECTORD_TOKEN)"
    return 1
  fi
}

# _hire_link_call <METHOD> <path> [json body] — one box-authed API call; the
# answer in HIRE_LINK_CODE (empty: no answer) and HIRE_LINK_BODY.
_hire_link_call() {
  local out
  local -a data=()
  [[ -n "${3:-}" ]] && data=(-H 'content-type: application/json' --data-binary "$3")
  out=$(printf 'header = "authorization: Bearer %s"\n' "$HIRE_LINK_TOKEN" \
    | curl -sS --max-time 20 -K - -X "$1" "${data[@]}" -w '\n%{http_code}' "$(_tg_app_api)$2" 2>/dev/null) || out=""
  HIRE_LINK_CODE="${out##*$'\n'}"; HIRE_LINK_BODY="${out%$'\n'*}"
  [[ "$HIRE_LINK_CODE" =~ ^[0-9]{3}$ ]] || { HIRE_LINK_CODE=""; HIRE_LINK_BODY=""; }
}

_hire_link_err() { jq -r '.error // empty' <<<"$HIRE_LINK_BODY" 2>/dev/null || true; }

# _hire_link_lookup <slug> — the link for <slug> into HIRE_LINK_STATUS /
# HIRE_LINK_URL / HIRE_LINK_CHANNEL / HIRE_LINK_PROSE, answering nothing.
_hire_link_lookup() {
  local slug="$1" url channel err
  HIRE_LINK_URL=""; HIRE_LINK_CHANNEL=""
  _hire_link_call POST /server/telegram/hire-link "$(jq -nc --arg s "$slug" '{slug:$s}')"
  url=$(jq -r '.url // empty' <<<"$HIRE_LINK_BODY" 2>/dev/null || true)
  channel=$(jq -r '.channel // empty' <<<"$HIRE_LINK_BODY" 2>/dev/null || true)
  err=$(_hire_link_err)
  case "$HIRE_LINK_CODE" in
    200)
      if [[ "$channel" == miniapp && "$url" =~ ^https://t\.me/[A-Za-z0-9_]+\?startapp=agent-${slug}$ ]] \
         || [[ "$channel" == web && ! "$slug" =~ $_HIRE_LINK_CUSTOM_RE && "$url" =~ ^https://[A-Za-z0-9.-]+/dashboard/agents/new$ ]]; then
        HIRE_LINK_STATUS=ready; HIRE_LINK_URL="$url"; HIRE_LINK_CHANNEL="$channel"; HIRE_LINK_PROSE="$url"
      else
        HIRE_LINK_STATUS=error; HIRE_LINK_PROSE="5dive answered without a usable hire link"
      fi ;;
    403) if [[ "$err" == partner_box ]]; then
           HIRE_LINK_STATUS=partner_box; HIRE_LINK_PROSE="this box's owner hires in their partner's app, not with a 5dive link"
         else
           HIRE_LINK_STATUS=error; HIRE_LINK_PROSE="5dive refused this box (${err:-403})"
         fi ;;
    404) HIRE_LINK_STATUS=not_found; HIRE_LINK_PROSE="'$slug' is not an agent this box's owner made (5dive hire-link --create makes one)" ;;
    409) if [[ "$err" == no_hire_card ]]; then
           HIRE_LINK_STATUS=no_hire_card
           HIRE_LINK_PROSE="your owner signs in to 5dive on the web, which has no Hire card for a made agent; an admin-tier agent hires it on their yes (5dive hire-link $slug --hire)"
         else
           HIRE_LINK_STATUS=error; HIRE_LINK_PROSE="5dive refused the link (${err:-409})"
         fi ;;
    *) HIRE_LINK_STATUS=error; HIRE_LINK_PROSE="could not get a hire link from 5dive (${HIRE_LINK_CODE:-no answer}); try again shortly" ;;
  esac
}

_hire_link_link() {
  _hire_link_lookup "$1"
  HIRE_LINK_TOKEN=""
  _hire_link_answer "$HIRE_LINK_STATUS" "$HIRE_LINK_PROSE" "$HIRE_LINK_URL" "$HIRE_LINK_CHANNEL"
}

# _hire_link_create <name> <description> <argv...> — DIVE-5722's draft.
_hire_link_create() {
  local name="$1" desc="$2"; shift 2
  _hire_link_token "$@" || return 0
  _hire_link_call POST /server/custom-agents "$(jq -nc --arg n "$name" --arg d "$desc" '{name:$n, description:$d}')"
  local err; err=$(_hire_link_err)
  case "$HIRE_LINK_CODE" in
    201) ;;
    400) HIRE_LINK_TOKEN=""
         _hire_link_made_answer invalid "5dive refused the ${err#invalid_} (${err:-400}): a name is 1-32 letters, digits, spaces, dots or dashes; a description 10-600 characters of the owner's need" "$err"
         return 0 ;;
    403) HIRE_LINK_TOKEN=""
         if [[ "$err" == partner_box ]]; then
           _hire_link_made_answer partner_box "this box's owner makes and hires agents in their partner's app, not from chat"
         else
           _hire_link_made_answer error "5dive refused this box (${err:-403})"
         fi
         return 0 ;;
    429) HIRE_LINK_TOKEN=""
         _hire_link_made_answer limit "your owner has made as many agents today as 5dive allows; try again tomorrow, or reuse one they made (Mini App, Hire)"
         return 0 ;;
    *)   HIRE_LINK_TOKEN=""
         _hire_link_made_answer error "could not make the agent on 5dive (${HIRE_LINK_CODE:-no answer}${err:+ $err}); try again shortly"
         return 0 ;;
  esac
  local made="$HIRE_LINK_BODY" id
  id=$(jq -r '.id // empty' <<<"$made" 2>/dev/null || true)
  if [[ ! "custom-$id" =~ $_HIRE_LINK_CUSTOM_RE ]]; then
    HIRE_LINK_TOKEN=""
    _hire_link_made_answer error "5dive answered without the agent it made"
    return 0
  fi
  HIRE_LINK_SLUG="custom-$id"
  _hire_link_lookup "$HIRE_LINK_SLUG"
  HIRE_LINK_TOKEN=""
  local role skills card next
  role=$(jq -r '.role // "Assistant"' <<<"$made")
  skills=$(jq -r '(.skills // []) | join(", ")' <<<"$made")
  if [[ "$HIRE_LINK_STATUS" == ready ]]; then
    card="Card: $HIRE_LINK_URL"
    next="Nothing is hired yet. Show your owner this draft and the card. Standard-tier: they tap Hire on it. Admin-tier: only on their clear yes, run 5dive hire-link $HIRE_LINK_SLUG --hire"
  else
    card="Card: none ($HIRE_LINK_PROSE)"
    next="Nothing is hired yet. Show your owner this draft. Admin-tier: only on their clear yes, run 5dive hire-link $HIRE_LINK_SLUG --hire"
  fi
  if (( ${JSON_MODE:-0} )); then
    ok "made $HIRE_LINK_SLUG" \
      '{status:"made", id:$a.id, slug:$s, name:$a.name, role:$a.role, skills:($a.skills // []), cardImage:$a.cardUrl,
        url:(if $u == "" then null else $u end), channel:(if $c == "" then null else $c end), linkStatus:$l, next:$x}' \
      --argjson a "$made" --arg s "$HIRE_LINK_SLUG" --arg u "$HIRE_LINK_URL" --arg c "$HIRE_LINK_CHANNEL" \
      --arg l "$HIRE_LINK_STATUS" --arg x "$next"
  else
    printf 'Draft: %s — %s\nSkills: %s\n%s\n%s\n' "$(jq -r '.name' <<<"$made")" "$role" "${skills:-the generalist kit}" "$card" "$next"
  fi
}

_hire_link_made_answer() { # <status> <prose> [error]
  if (( ${JSON_MODE:-0} )); then
    ok "$2" '{status:$s, error:(if $e == "" then null else $e end), message:$m}' --arg s "$1" --arg e "${3:-}" --arg m "$2"
  else
    printf '%s\n' "$2"
  fi
}

# _hire_link_may_hire — 0 when the seat asking is admin-tier (or no seat: root,
# a person). Behind sudo the asker is SUDO_USER: a standard seat reaches root
# here only through its hire-link grant, which is for the box identity, not this.
_hire_link_may_hire() {
  local who
  if (( EUID == 0 )); then who="${SUDO_USER:-}"; else who=$(id -un 2>/dev/null || true); fi
  [[ -z "$who" || "$who" == root || "$who" == claude ]] && return 0
  actor_registry_agent "$who"
  case "$ACTOR_TIER" in admin|beyond-admin) return 0 ;; esac
  # Not an agent at all (a person on the box): the registry says so; an agent-*
  # name whose tier could not be read is not trusted with a hire.
  [[ -z "$ACTOR_AGENT" && "$ACTOR_TIER" == unknown:unregistered && "$who" != agent-* ]] && return 0
  return 1
}

# _hire_link_hire custom-<id> <argv...> — the Mini App's Hire onto this box,
# then wait for the import (~90 s) the way the Mini App polls.
_hire_link_hire() {
  local slug="$1"; shift
  local id="${slug#custom-}"
  if ! _hire_link_may_hire; then
    _hire_link_made_answer tier "only an admin-tier agent hires from chat; send your owner the card instead (5dive hire-link $slug) and they tap Hire"
    return 0
  fi
  _hire_link_token "$@" || return 0
  _hire_link_call POST "/server/custom-agents/$id/hire"
  local waited=0 wait_max="${HIRE_LINK_WAIT_S:-300}" step="${HIRE_LINK_POLL_S:-5}" state err
  while :; do
    state=$(jq -r '.state // empty' <<<"$HIRE_LINK_BODY" 2>/dev/null || true)
    [[ "$HIRE_LINK_CODE" =~ ^20[02]$ && "$state" == hiring ]] || break
    (( waited < wait_max )) || break
    sleep "$step"; waited=$(( waited + step ))
    _hire_link_call GET "/server/custom-agents/$id/hire"
  done
  HIRE_LINK_TOKEN=""
  err=$(_hire_link_err)
  local agent; agent=$(jq -r '.name // empty' <<<"$HIRE_LINK_BODY" 2>/dev/null || true)
  if [[ "$state" == hired && "$agent" =~ ^[a-z][a-z0-9-]{0,15}$ ]]; then
    if (( ${JSON_MODE:-0} )); then
      ok "hired $agent" '{status:"hired", slug:$s, name:$n}' --arg s "$slug" --arg n "$agent"
    else
      printf 'Hired: %s is on the team. Its own Telegram bot is your owner'"'"'s Connect tap (Mini App, Team).\n' "$agent"
    fi
    return 0
  fi
  case "$HIRE_LINK_CODE:$state" in
    20[02]:hiring) _hire_link_made_answer hiring "still importing $slug onto the box; run the same command again in a minute to check (it joins the running hire)" ;;
    403:*) if [[ "$err" == partner_box ]]; then
             _hire_link_made_answer partner_box "this box's owner hires in their partner's app, not from chat"
           else _hire_link_made_answer error "5dive refused this box (${err:-403})"; fi ;;
    404:*) _hire_link_made_answer not_found "'$slug' is not an agent this box's owner made" ;;
    *:failed|50[23]:*) _hire_link_made_answer error "the hire failed: $(jq -r '.message // .error // "no reason given"' <<<"$HIRE_LINK_BODY" 2>/dev/null)" "${err:-hire_failed}" ;;
    *) _hire_link_made_answer error "could not hire $slug (${HIRE_LINK_CODE:-no answer}); try again shortly" ;;
  esac
}
