# -------- 5dive partner hire (DIVE-5168) --------
#
# A partner client's persona agent (an `agent-<name>` seat on a partner box, lite
# Telegram profile, NOT root) hires a colleague from chat: "hire Galina".
#
# WHY NOT `5dive hire`. That verb is root-only and creates the seat LOCALLY, from
# the open market. On a partner box both halves are wrong: the colleague must come
# from the PARTNER's catalogue (its private registry, which this box cannot browse
# on its own), and the hire must land in the partner's RECORD — the partner's
# `GET agents` is what the partner's cabinet reads, and a seat created behind the
# API's back never appears there. So this verb creates nothing on the box. It asks
# 5dive-api to run the same partner path `POST /accounts/<id>/agents` runs, and the
# API installs the pack back onto this box through the ordinary box channel.
#
# AUTHORITY. The request is authenticated with the BOX's identity — the
# CONNECTORD_TOKEN in /etc/5dive/connectord.env (0640 root:claude). Standard and
# admin seats are in group `claude` and read it directly; a sandboxed seat is not
# and cannot, and that is the intended boundary: no sudo, no sudoers entry, no new
# privilege class. The API decides whether the box is a partner box and what the
# partner's catalogue holds; this side only validates the shape of what it sends.
#
# THE TOKEN NEVER TOUCHES ARGV. The existing box->API callers pass it as
# `-H "authorization: Bearer $token"`, which puts the credential in curl's argv,
# readable by every process on the box through /proc/<pid>/cmdline. Here the
# header goes in on curl's STDIN (`-H @-`), so `ps` shows `-H @-` and nothing else.
# tests/partner_hire_unit.sh asserts it against a stub that records its argv.

# Where the box identity lives. FIVE_CONNECTORD_ENV is the harness seam; nothing
# on a box sets it.
_partner_connectord_env() { printf '%s' "${FIVE_CONNECTORD_ENV:-/etc/5dive/connectord.env}"; }

# The API this box talks to — the same resolution every other box->API caller in
# this CLI uses (task/notify.sh, hooks/push-notify.sh, cmd_pack.sh's
# _oa_api_base): FIVE_API_BASE, else production. provisioning.env carries no API
# base, so there is nothing more authoritative on the box to read.
_partner_api_base() { local b="${FIVE_API_BASE:-https://api.5dive.com}"; printf '%s' "${b%/}"; }

_partner_usage() {
  cat <<'EOF'
usage: 5dive partner hire <pack> [--as=<name>] [--json]

On a PARTNER box, hire a colleague from the partner's catalogue through the
partner path: the partner's catalogue only, the same account, and the new agent
shows up in the partner's list of agents. Runs as any agent seat that can read
the box identity (/etc/5dive/connectord.env) — no root, no sudo.

  <pack>       the colleague's pack slug, as the partner's catalogue names it.
               Case-folded ("Galina" -> galina); [a-z0-9][a-z0-9_-]{0,63}.
  --as=<name>  the new agent's name (default: the API picks one from the pack).
               [a-z][a-z0-9-]{1,15}.

Exit status: 0 hiring started · 3 invalid pack/name · 4 not in this partner's
catalogue · 5 name taken / box not ready · 6 box identity refused ·
8 box unreachable from the API · 10 not a partner box, or this seat cannot read
the box identity · 11 API timeout · 1 anything else.

On an ordinary (non-partner) box use `5dive hire`.
EOF
}

# _partner_refuse <exit-code> <reason> <http> <message…> — fail(), plus the API's
# machine code. fail() emits {ok:false,error:{code,class,message}}; a caller that
# branches on WHY a hire was refused (catalogue vs name taken) needs the reason the
# API gave, not only the exit class it was folded into, so it rides as
# error.reason (and error.http when the API answered at all).
_partner_refuse() {
  local code="$1" reason="$2" http="$3"; shift 3
  local msg="$*"
  if (( JSON_MODE )); then
    jq -cn --argjson c "$code" --arg cl "$(err_class_for "$code")" --arg m "$msg" \
           --arg r "$reason" --arg h "$http" \
      '{ok:false, error:({code:$c, class:$cl, message:$m}
                         + (if $r == "" then {} else {reason:$r} end)
                         + (if $h == "" then {} else {http:($h | tonumber? // $h)} end))}'
  fi
  echo "error: $msg" >&2
  mark_reported
  exit "$code"
}

# _partner_box_token — the box's CONNECTORD_TOKEN on stdout. Same read as
# task/notify.sh's _task_mint_drop_link: an inherited CONNECTORD_TOKEN wins, else
# the `CONNECTORD_TOKEN=` line of the connectord env file.
#   rc 0  token printed
#   rc 1  the file exists and this seat cannot read it (sandboxed seat)
#   rc 2  no file / no token line (not a managed 5dive box)
_partner_box_token() {
  local f t=""
  if [[ -n "${CONNECTORD_TOKEN:-}" ]]; then printf '%s' "$CONNECTORD_TOKEN"; return 0; fi
  f=$(_partner_connectord_env)
  if [[ -e "$f" && ! -r "$f" ]]; then return 1; fi
  [[ -r "$f" ]] || return 2
  t=$(sed -n 's/^CONNECTORD_TOKEN=//p' "$f" 2>/dev/null | head -n 1) || t=""
  t="${t%$'\r'}"; t="${t#\"}"; t="${t%\"}"; t="${t#\'}"; t="${t%\'}"
  [[ -n "$t" ]] || return 2
  printf '%s' "$t"
}

cmd_partner() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    hire) cmd_partner_hire "$@" ;;
    ""|-h|--help|help) _partner_usage ;;
    *) fail "$E_USAGE" "unknown partner subcommand: $sub (usage: 5dive partner hire <pack> [--as=<name>] [--json])" ;;
  esac
}

cmd_partner_hire() {
  local pack="" name="" a
  while [[ $# -gt 0 ]]; do
    a="$1"; shift
    case "$a" in
      -h|--help) _partner_usage; return 0 ;;
      --json) JSON_MODE=1 ;;
      --as=*) name="${a#--as=}" ;;
      --as)
        [[ $# -gt 0 ]] || fail "$E_USAGE" "--as needs a name: 5dive partner hire <pack> --as=<name>"
        name="$1"; shift ;;
      --) [[ $# -gt 0 && -z "$pack" ]] && { pack="$1"; shift; }
          [[ $# -eq 0 ]] || fail "$E_USAGE" "unexpected argument: $1 (usage: 5dive partner hire <pack> [--as=<name>] [--json])" ;;
      -*) fail "$E_USAGE" "unknown flag: $a" ;;
      *)
        [[ -z "$pack" ]] || fail "$E_USAGE" "unexpected argument: $a (usage: 5dive partner hire <pack> [--as=<name>] [--json])"
        pack="$a" ;;
    esac
  done
  [[ -n "$pack" ]] || fail "$E_USAGE" "usage: 5dive partner hire <pack> [--as=<name>] [--json]"

  # Validate BEFORE anything leaves the box. A person says "Galina"; catalogue
  # slugs are lowercase, so the pack is case-folded. The name is not: it becomes a
  # Linux user, and silently rewriting what someone asked to be called is worse
  # than refusing it.
  pack="${pack,,}"
  [[ "$pack" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] \
    || _partner_refuse "$E_VALIDATION" invalid_pack "" "invalid pack '$pack': a pack slug is lowercase letters, digits, '-' or '_' (at most 64)"
  if [[ -n "$name" ]]; then
    [[ "$name" =~ ^[a-z][a-z0-9-]{1,15}$ ]] \
      || _partner_refuse "$E_VALIDATION" invalid_name "" "invalid name '$name': 2-16 characters, lowercase letters, digits and '-', starting with a letter"
  fi

  local token="" trc=0
  token=$(_partner_box_token) || trc=$?
  case "$trc" in
    0) ;;
    1) _partner_refuse "$E_PERMISSION" no_box_identity "" \
         "this seat cannot reach the box's identity ($(_partner_connectord_env) is not readable by $(id -un 2>/dev/null || echo this user)) — hiring from chat needs a non-sandboxed seat on a partner box" ;;
    *) _partner_refuse "$E_NOT_FOUND" no_box_identity "" \
         "this seat cannot reach the box's identity (no CONNECTORD_TOKEN in $(_partner_connectord_env)) — hiring from chat needs a non-sandboxed seat on a partner box; on a self-hosted box use \`5dive hire\`" ;;
  esac

  local body url resp="" crc=0 http rbody
  if [[ -n "$name" ]]; then
    body=$(jq -cn --arg p "$pack" --arg n "$name" '{pack:$p, name:$n}')
  else
    body=$(jq -cn --arg p "$pack" '{pack:$p}')
  fi
  url="$(_partner_api_base)/server/partner/agents"
  # The bearer goes in on STDIN (`-H @-`), never argv — see the header.
  resp=$(printf 'Authorization: Bearer %s\n' "$token" \
           | curl -sS --max-time 30 -X POST "$url" -H @- \
               -H 'Content-Type: application/json' --data-binary "$body" \
               -w '\n%{http_code}' 2>/dev/null) || crc=$?
  token=""
  http="${resp##*$'\n'}"
  if [[ "$resp" == *$'\n'* ]]; then rbody="${resp%$'\n'*}"; else rbody=""; fi
  if [[ ! "$http" =~ ^[0-9]{3}$ || "$http" == 000 ]]; then
    (( crc == 28 )) && _partner_refuse "$E_TIMEOUT" timeout "" "the 5dive API at $(_partner_api_base) did not answer in 30s — the hire was not confirmed; check the partner's agent list before retrying"
    _partner_refuse "$E_GENERIC" unreachable "" "could not reach the 5dive API at $(_partner_api_base) (curl exit $crc) — nothing was hired"
  fi

  local rcode rerr
  rcode=$(printf '%s' "$rbody" | jq -r '.code // empty' 2>/dev/null) || rcode=""
  rerr=$(printf '%s' "$rbody" | jq -r '.error // empty' 2>/dev/null) || rerr=""

  case "$http" in
    200|201|202)
      local rname rpack rstatus
      rname=$(printf '%s' "$rbody" | jq -r '.name // empty' 2>/dev/null) || rname=""
      rpack=$(printf '%s' "$rbody" | jq -r '.pack // empty' 2>/dev/null) || rpack=""
      rstatus=$(printf '%s' "$rbody" | jq -r '.status // empty' 2>/dev/null) || rstatus=""
      [[ -n "$rname" ]] || rname="${name:-$pack}"
      [[ -n "$rpack" ]] || rpack="$pack"
      [[ -n "$rstatus" ]] || rstatus="installing"
      ok "Hiring $rname ($rpack) — they will appear in a minute." \
         '{name:$n, pack:$p, status:$s}' --arg n "$rname" --arg p "$rpack" --arg s "$rstatus"
      return 0 ;;
    400)
      case "$rcode" in
        not_in_catalog) _partner_refuse "$E_NOT_FOUND" "$rcode" "$http" "$pack is not in this partner's catalogue" ;;
        invalid_name)   _partner_refuse "$E_VALIDATION" "$rcode" "$http" "the API refused the name${name:+ '$name'}${rerr:+: $rerr}" ;;
        invalid_pack)   _partner_refuse "$E_VALIDATION" "$rcode" "$http" "the API refused the pack '$pack'${rerr:+: $rerr}" ;;
        *)              _partner_refuse "$E_VALIDATION" "${rcode:-bad_request}" "$http" "the API refused the request${rerr:+: $rerr}" ;;
      esac ;;
    401)
      _partner_refuse "$E_AUTH_REQUIRED" "${rcode:-unauthorized}" "$http" "the 5dive API did not accept this box's identity — the box token may have just been rotated; nothing was hired" ;;
    403)
      if [[ "$rcode" == not_a_partner_box ]]; then
        _partner_refuse "$E_PERMISSION" "$rcode" "$http" "this box is not a partner box — use \`5dive hire\`"
      fi
      _partner_refuse "$E_PERMISSION" "${rcode:-forbidden}" "$http" "the 5dive API refused the hire${rerr:+: $rerr}" ;;
    409)
      case "$rcode" in
        agent_exists)  _partner_refuse "$E_CONFLICT" "$rcode" "$http" "that agent name${name:+ ($name)} is already taken on this box — pick another with --as=<name>" ;;
        box_not_ready) _partner_refuse "$E_CONFLICT" "$rcode" "$http" "this box is not ready to take a new agent yet — try again in a few minutes" ;;
        *)             _partner_refuse "$E_CONFLICT" "${rcode:-conflict}" "$http" "the API refused the hire${rerr:+: $rerr}" ;;
      esac ;;
    502)
      _partner_refuse "$E_NOT_RUNNING" "${rcode:-box_unreachable}" "$http" "the 5dive API could not reach this box to install ${name:-$pack} — nothing was hired; try again in a minute" ;;
    503)
      _partner_refuse "$E_GENERIC" "${rcode:-catalog_unavailable}" "$http" "the partner's catalogue is unavailable right now — nothing was hired; try again in a minute" ;;
    *)
      _partner_refuse "$E_GENERIC" "${rcode:-http_$http}" "$http" "the 5dive API answered HTTP $http${rerr:+: $rerr} — nothing was confirmed hired" ;;
  esac
}
