# -------- agent first-job (DIVE-5874) --------
#
# "First job at hire": the owner picks a small first job in the Mini App right
# after hiring, and the agent's answer is waiting as its FIRST Telegram message.
# The API stores the job and, holding this box's key for one call, execs
#
#   sudo 5dive agent first-job <name> --token=<t> --job-b64=<b64>
#
# over shelld. That exec has a short deadline and the job takes minutes, so this
# verb only records it and starts a transient unit (same reasoning as the
# detached installs, DIVE-4973: systemd-run hands the job to PID 1, out of
# shelld's cgroup). The unit runs `agent _first_job_run`, which asks the agent
# through the ordinary `agent ask` rail, drops the reply where the Telegram
# plugin looks for it (STATE_DIR/first-reply.json, answered on the owner's
# /start fj-<token>), and tells the API it is done with the box token.
#
# Nothing here calls an LLM of 5dive's own: the prompt is the static template
# below and the job runs on the agent's own AI, on the customer's box.
#
#   agent first-job <name> --token=<t> --job-b64=<b64>   record + start; idempotent per token
#   agent first-job status <name> --json                  the plugin's /start + second-message stamps
#   agent _first_job_run <name> <token>                   (internal) the unit's body

FIRST_JOB_DIR="${FIRST_JOB_DIR:-$STATE_DIR/first-jobs}"
# The ask's own bound (contract: 1200s) plus the done POST's retries. A hung ask
# ends the unit rather than leaving a job "running" forever.
FIRST_JOB_ASK_TIMEOUT="${FIRST_JOB_ASK_TIMEOUT:-1200}"
FIRST_JOB_MAX_SEC="${FIRST_JOB_MAX_SEC:-1800}"

# Harness seams. Nothing on a box sets these.
_first_job_self()   { printf '%s' "${FIVE_FIRST_JOB_SELF:-/usr/local/bin/5dive}"; }
_first_job_is_root() { (( EUID == 0 )); }

_first_job_valid_token() { [[ "${1:-}" =~ ^[A-Za-z0-9_-]{22}$ ]]; }

# The agent's unix user and home. A hired agent is always agent-<name>; passwd
# wins over the conventional path so a moved home still resolves.
_first_job_user() { printf 'agent-%s' "$1"; }
_first_job_home() {
  local h=""
  if [[ -n "${AGENT_HOME_ROOT:-}" ]]; then printf '%s/agent-%s' "$AGENT_HOME_ROOT" "$1"; return 0; fi
  h=$(getent passwd "agent-$1" 2>/dev/null | cut -d: -f6) || h=""
  printf '%s' "${h:-/home/agent-$1}"
}
_first_job_tg_dir() { printf '%s/.claude/channels/telegram' "$(_first_job_home "$1")"; }

# Run <cmd> as the agent when we are root (same rule as _agent_avatar_as): the
# Telegram state dir is agent-owned, so the agent can swap any component for a
# link, and as the agent a link reaches nothing it could not reach already.
_first_job_as() { # <name> <cmd...>
  local name="$1"; shift
  if _first_job_is_root; then
    command -v runuser >/dev/null 2>&1 || { printf 'runuser not found; refusing to touch agent-%s as root\n' "$name" >&2; return 1; }
    runuser -u "$(_first_job_user "$name")" -- "$@"
  else
    "$@"
  fi
}

_first_job_agent_known() { # <name>
  [[ -r "$REGISTRY" ]] || return 1
  jq -e --arg n "$1" '.agents[$n] != null' "$REGISTRY" >/dev/null 2>&1
}

_first_job_state() { printf '%s/%s.json' "$FIRST_JOB_DIR" "$1"; }

# Merge <jq-object-expr> into the state file (root-owned dir, atomic).
_first_job_state_merge() { # <token> <expr> [jq args...]
  local f; f=$(_first_job_state "$1"); local expr="$2"; shift 2
  [[ -f "$f" ]] || return 1
  jq -c "$@" ". + ($expr)" "$f" >"$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

# The static prompt (contract text, English; the agent answers in the owner's
# language when it knows it).
_first_job_prompt() { # <job>
  printf 'Your new owner just hired you and picked your first job: «%s». Do it now and keep it small: one page, one short list or one short plan. If you need something you don'"'"'t have (a link, a name), make a sensible assumption, say which, and do the job anyway. Your answer is sent to your owner in Telegram as your first message to them, so write it as that message: start with the result, no preamble.\n' "$1"
}

cmd_agent_first_job() {
  if [[ "${1:-}" == "status" && $# -ge 2 && "${2:-}" != -* ]]; then
    shift; cmd_agent_first_job_status "$@"; return
  fi
  local usage="usage: 5dive agent first-job <name> --token=<token> --job-b64=<base64>  |  first-job status <name> --json"
  local name="" token="" b64=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) printf '%s\n' "$usage"; return 0 ;;
      --token=*)   token="${1#--token=}" ;;
      --token)     [[ $# -ge 2 ]] || fail "$E_USAGE" "$usage"; token="$2"; shift ;;
      --job-b64=*) b64="${1#--job-b64=}" ;;
      --job-b64)   [[ $# -ge 2 ]] || fail "$E_USAGE" "$usage"; b64="$2"; shift ;;
      -*) fail "$E_USAGE" "unknown flag: $1 ($usage)" ;;
      *)  [[ -z "$name" ]] || fail "$E_USAGE" "unexpected argument: $1 ($usage)"; name="$1" ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$token" && -n "$b64" ]] || fail "$E_USAGE" "$usage"
  require_root
  valid_name "$name" || fail "$E_VALIDATION" "invalid agent name '$name'"
  # 22 chars of base64url (16 random bytes): it rides in a unit name and in a
  # Telegram start payload (fj-<token>), so nothing else may pass.
  _first_job_valid_token "$token" || fail "$E_VALIDATION" "invalid first-job token: expected 22 characters of [A-Za-z0-9_-]"
  _first_job_agent_known "$name" || fail "$E_NOT_FOUND" "no agent named '$name'"

  # The job text: standard or url-safe base64 of UTF-8. The API caps it at 300
  # characters; 1200 bytes covers that in any script.
  [[ ${#b64} -le 1700 && "$b64" =~ ^[A-Za-z0-9+/_=-]+$ ]] || fail "$E_VALIDATION" "invalid --job-b64: not base64"
  local std="${b64//-/+}"; std="${std//_//}"
  while (( ${#std} % 4 )); do std+="="; done
  local job="" drc=0
  job=$(printf '%s' "$std" | base64 -d 2>/dev/null) || drc=$?
  (( drc == 0 )) || fail "$E_VALIDATION" "invalid --job-b64: does not decode"
  job="${job#"${job%%[![:space:]]*}"}"; job="${job%"${job##*[![:space:]]}"}"
  [[ -n "$job" ]] || fail "$E_VALIDATION" "the first job is empty"
  # Counted in BYTES: shelld's exec runs in the C locale, where ${#job} of a
  # 300-character Cyrillic job is 600, so a character cap here would refuse it.
  (( $(printf '%s' "$job" | wc -c) <= 1200 )) || fail "$E_VALIDATION" "the first job is too long (over 1200 bytes)"
  [[ "$job" != *[[:cntrl:]]* ]] || fail "$E_VALIDATION" "the first job contains control characters"

  install -d -m 0700 "$FIRST_JOB_DIR" 2>/dev/null || mkdir -p "$FIRST_JOB_DIR" \
    || fail "$E_GENERIC" "could not create $FIRST_JOB_DIR"
  local st; st=$(_first_job_state "$token")
  # Idempotent per token: the API retries a tap it could not confirm, and a
  # second call must never run the job twice. noclobber makes the create the
  # lock, so two racing calls cannot both start a unit.
  local rec
  rec=$(jq -cn --arg t "$token" --arg n "$name" --arg j "$job" --arg s "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{token:$t, name:$n, job:$j, status:"running", createdAt:$s}')
  if ! ( umask 077; set -o noclobber; printf '%s\n' "$rec" >"$st" ) 2>/dev/null; then
    [[ -e "$st" ]] || fail "$E_GENERIC" "could not write $st"
    printf '{"ok":true,"already":true}\n'
    return 0
  fi

  local unit="5dive-first-job-${token:0:12}"
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  # A system unit without User= gets no HOME; the CLI's `set -u` paths expect one.
  local -a env=(--setenv=PATH="$PATH" --setenv=HOME=/root)
  [[ -n "${FIVE_API_BASE:-}" ]] && env+=(--setenv=FIVE_API_BASE="$FIVE_API_BASE")
  if ! systemd-run --quiet --collect --unit="$unit" \
         --property=RuntimeMaxSec="$FIRST_JOB_MAX_SEC" "${env[@]}" \
         -- "$(_first_job_self)" agent _first_job_run "$name" "$token" >/dev/null 2>&1; then
    # Nothing ran: drop the record so the API's retry can start it.
    rm -f "$st"
    fail "$E_GENERIC" "could not start the first-job unit ($unit) — systemd-run refused it"
  fi
  printf '{"ok":true}\n'
}

# _first_job_ask <name> <prompt-file> — the reply on stdout, rc 0; or the reason
# on stdout, rc 1. A just-hired agent may still be booting, so a send that never
# reached its pane (not running, or the ask's fast delivery failure) is retried;
# a real reply timeout is not — it already waited the full bound.
_first_job_ask() {
  local name="$1" pf="$2" out="" rc t0 n=0 msg=""
  local max="${FIRST_JOB_ASK_ATTEMPTS:-4}" pause="${FIRST_JOB_ASK_RETRY_SLEEP:-30}"
  while :; do
    n=$((n + 1)); t0=$SECONDS; rc=0
    out=$("$(_first_job_self)" --json agent ask "$name" --message-file="$pf" \
            --timeout="$FIRST_JOB_ASK_TIMEOUT" --from=first-job 2>/dev/null) || rc=$?
    if (( rc == 0 )); then
      msg=$(jq -r '.data.reply // empty' <<<"$out" 2>/dev/null) || msg=""
      [[ -n "${msg//[[:space:]]/}" ]] && { printf '%s' "$msg"; return 0; }
      printf 'the agent answered with an empty reply'; return 1
    fi
    msg=$(jq -r '.error.message // empty' <<<"$out" 2>/dev/null) || msg=""
    if (( n < max )) && { (( rc == E_NOT_RUNNING )) || (( rc == E_TIMEOUT && SECONDS - t0 < 300 )); }; then
      sleep "$pause"; continue
    fi
    printf '%s' "${msg:-agent ask failed (exit $rc)}"; return 1
  done
}

# _first_job_post_done <body> — POST /server/first-jobs/done with the box token.
# 3 attempts with back-off; a 4xx other than 408/429 is an answer, not a blip.
# Sets _FJ_HTTP to the last status seen.
_FJ_HTTP=""
_first_job_post_done() {
  local body="$1" tok="" trc=0 url http="" i=0
  local -a pauses
  read -r -a pauses <<<"${FIRST_JOB_POST_BACKOFF:-5 20}"
  tok=$(_partner_box_token) || trc=$?
  (( trc == 0 )) || { _FJ_HTTP="no-token"; return 1; }
  url="$(_partner_api_base)/server/first-jobs/done"
  while :; do
    # The bearer goes in on STDIN (`-H @-`), never argv — DIVE-5168's rule.
    http=$(printf 'Authorization: Bearer %s\n' "$tok" \
             | curl -sS --max-time 20 -X POST "$url" -H @- \
                 -H 'Content-Type: application/json' --data-binary "$body" \
                 -o /dev/null -w '%{http_code}' 2>/dev/null) || true
    _FJ_HTTP="${http:-000}"
    case "$_FJ_HTTP" in
      2??) return 0 ;;
      408|429) ;;
      4??) return 1 ;;
    esac
    (( i < ${#pauses[@]} )) || return 1
    sleep "${pauses[$i]}"; i=$((i + 1))
  done
}

cmd_agent_first_job_run() {
  local usage="usage: 5dive agent _first_job_run <name> <token>"
  [[ "${1:-}" == -h || "${1:-}" == --help ]] && { printf '%s\n' "$usage"; return 0; }
  [[ $# -eq 2 ]] || fail "$E_USAGE" "$usage"
  local name="$1" token="$2"
  require_root
  valid_name "$name" || fail "$E_VALIDATION" "invalid agent name '$name'"
  _first_job_valid_token "$token" || fail "$E_VALIDATION" "invalid first-job token"
  local st; st=$(_first_job_state "$token")
  [[ -f "$st" ]] || fail "$E_NOT_FOUND" "no first job recorded for this token"
  local job; job=$(jq -r '.job // empty' "$st" 2>/dev/null) || job=""
  [[ -n "$job" ]] || fail "$E_GENERIC" "the first-job record has no job"

  local pf ok=0 reply="" err=""
  pf=$(mktemp "$FIRST_JOB_DIR/.prompt.XXXXXX") || fail "$E_GENERIC" "could not create a prompt file"
  _first_job_prompt "$job" >"$pf"
  if reply=$(_first_job_ask "$name" "$pf"); then ok=1; else err="$reply"; reply=""; fi
  rm -f "$pf"

  if (( ok )); then
    # Written AS the agent, 0600, tmp + mv: the plugin polls for this file and
    # must never read half of it.
    local dir; dir=$(_first_job_tg_dir "$name")
    # shellcheck disable=SC2016
    if ! jq -cn --arg t "$token" --arg x "$reply" --arg a "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{token:$t, text:$x, at:$a}' \
         | _first_job_as "$name" /bin/bash -c 'umask 077; mkdir -p -- "$1" || exit 1
             t=$(mktemp "$1/.first-reply.XXXXXX") || exit 1
             cat >"$t" && chmod 600 "$t" && mv -f -- "$t" "$1/first-reply.json" || { rm -f -- "$t"; exit 1; }' _ "$dir"; then
      ok=0; err="could not store the reply for the agent's Telegram bot"
    fi
  fi

  local body bot=""
  if (( ok )); then
    bot=$(jq -r --arg n "$name" '.agents[$n].botUsername // empty' "$REGISTRY" 2>/dev/null) || bot=""
    # Omitted rather than sent empty or malformed: with no bot the API's notice
    # opens the Mini App instead.
    [[ "$bot" =~ ^[A-Za-z0-9_]{5,32}$ ]] || bot=""
    body=$(jq -cn --arg t "$token" --arg b "$bot" '{token:$t, ok:true} + (if $b == "" then {} else {botUsername:$b} end)')
  else
    err="${err:0:300}"
    body=$(jq -cn --arg t "$token" --arg e "$err" '{token:$t, ok:false, error:$e}')
  fi

  local posted=false
  _first_job_post_done "$body" && posted=true
  _first_job_state_merge "$token" \
    '{status:(if $ok == "1" then "done" else "failed" end), finishedAt:$f, posted:$p, http:$h}
     + (if $e == "" then {} else {error:$e} end)' \
    --arg ok "$ok" --arg f "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson p "$posted" \
    --arg h "$_FJ_HTTP" --arg e "$err" || true
  [[ "$posted" == true ]] || fail "$E_GENERIC" "first job ${token:0:12}: the done report did not reach the 5dive API (last HTTP ${_FJ_HTTP})"
  (( ok )) || fail "$E_GENERIC" "first job ${token:0:12} failed: $err"
  return 0
}

# `first-job status <name> --json` — what the plugin stamped: {token,startAt,
# secondAt}, or {} when it has stamped nothing. The API matches the token
# against its own row, so a stale file from an earlier job is harmless.
cmd_agent_first_job_status() {
  local usage="usage: 5dive agent first-job status <name> --json"
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) printf '%s\n' "$usage"; return 0 ;;
      --json) JSON_MODE=1 ;;
      -*) fail "$E_USAGE" "unknown flag: $1 ($usage)" ;;
      *)  [[ -z "$name" ]] || fail "$E_USAGE" "unexpected argument: $1 ($usage)"; name="$1" ;;
    esac
    shift
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "$usage"
  require_root
  valid_name "$name" || fail "$E_VALIDATION" "invalid agent name '$name'"
  _first_job_agent_known "$name" || fail "$E_NOT_FOUND" "no agent named '$name'"
  local f raw=""
  f="$(_first_job_tg_dir "$name")/first-reply.state.json"
  # Read as the agent and bounded: the file is agent-written.
  raw=$(_first_job_as "$name" head -c 4096 -- "$f" 2>/dev/null) || raw=""
  # Slurped, so empty or several documents read as {} rather than as nothing.
  jq -cs 'def ts: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9:]+)$") then . else null end;
         (if length == 1 then .[0] else null end) |
         if type == "object" and (.token | type) == "string" and (.token | test("^[A-Za-z0-9_-]{22}$"))
         then {token, startAt: (.startAt | ts), secondAt: (.secondAt | ts)} else {} end' \
    <<<"$raw" 2>/dev/null || printf '{}\n'
}
