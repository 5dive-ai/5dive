# -------- DIVE-7143: three narrow root verbs for a STANDARD seat ----------------
#
# A standard seat holds no general sudo, only the exact NOPASSWD lines
# render_standard_sudoers writes. Three everyday acts were still out of its
# reach, because each one ran `sudo -u agent-<peer>` or was require_root:
#
#   agent _peek <name> [--lines=N]          read a TEAMMATE's tmux pane
#   agent _skill_give <to> <skill> [--replace]
#                                           copy one of MY skills into a TEAMMATE's
#                                           skills dir, owned by them
#   heartbeat _self on|off                  enrol or pause MY OWN heartbeat
#
# Each is the _pkg_do / _self_restart shape:
#   * reachable as root only (the _gate_is_root seam); one exact sudoers line each
#   * the caller is derived from SUDO_UID (sudo stamps it), never from argv
#   * every argument is validated against a fixed shape before anything runs
#   * nothing caller-controlled is ever exec'd: tmux, tar and the placement
#     script are FIXED commands, the caller's values travel as positional args
#   * root-side audit, refusals included
#
# THE TEAMMATE RULE (_peek and _skill_give). The target must be a registered
# agent with a seat user, not the caller, not sandboxed, and share a team with
# the caller. "Share a team" is read from what the box records:
#   1. team_members: both rows under one team key (every team import since
#      DIVE-5769);
#   2. agents_org: one is the other's direct manager (`org set`);
#   3. a legacy team (a projects row with a lead and a team manifest on the box
#      but no team_members rows): both sit in the org subtree under its lead,
#      the same fallback every team surface reads (_team_members_backfill).
# Anything else is refused with one line saying which check failed.

RIGHTS_PEEK_DEFAULT=80
RIGHTS_PEEK_MAX=500
RIGHTS_SKILL_MAX_BYTES=$((5 * 1024 * 1024))
RIGHTS_SKILL_MAX_FILES=500
# The tar stream is cut here before it is even listed: 5 MiB of payload plus
# per-entry headers for the file cap stays well under it.
RIGHTS_SKILL_MAX_STREAM=$((8 * 1024 * 1024))

_rights_name_ok()  { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }
# Stricter than valid_skill_id: no leading dot or dash, so the name can never
# read as a flag to tar or mv, nor be a dot-dir.
_rights_skill_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

# SEAMS for the harness. Functions, not environment: invoking 5dive starts a
# fresh bash that defines them itself, so nothing a caller exports reaches them.
_rights_home()      { printf '/home/agent-%s' "$1"; }
_rights_seat_user() { getent passwd "agent-$1" >/dev/null 2>&1; }
# _rights_as <user> <cmd...> — run a FIXED command as <user>.
_rights_as()        { local u="$1"; shift; sudo -n -u "$u" -H -- "$@"; }

# The calling seat, from SUDO_UID. Empty (rc 1) for root itself, a non-agent
# uid, or no sudo stamp at all.
_rights_caller() {
  local uid="${SUDO_UID:-}" a
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || return 1
  a=$(_gate_uid_to_agent "$uid")
  [[ -n "$a" ]] || return 1
  printf '%s' "$a"
}

# _rights_refuse <verb> <code> <by> <msg> [args...] — audit, then fail.
_rights_refuse() {
  local verb="$1" code="$2" by="$3" msg="$4"; shift 4
  audit_log "$verb" refused "$code" -- "by=${by:-root}" "$@"
  fail "$code" "$msg"
}

# _rights_sandboxed <name> — 0 when EITHER source says sandboxed, or neither
# answered (fail closed: an unmeasured seat is not known to be safe to reach).
_rights_sandboxed() {
  local e r
  e=$(agent_env_isolation "$1"); r=$(agent_tier "$1")
  [[ "$e" == sandboxed || "$r" == sandboxed ]] && return 0
  [[ "$e" == unknown:* && "$r" == unknown:* ]] && return 0
  return 1
}

# _rights_teammates <a> <b> — 0 when a and b share a team (rules above).
_rights_teammates() {
  local a="$1" b="$2" qa qb hit
  declare -F db >/dev/null 2>&1 || return 1
  [[ -r "${TASKS_DB:-}" ]] || return 1
  qa=$(sqlq "$a"); qb=$(sqlq "$b")
  hit=$(db "SELECT 1 FROM team_members x JOIN team_members y ON x.team = y.team
             WHERE x.agent=${qa} AND y.agent=${qb} LIMIT 1;" 2>/dev/null) || hit=""
  [[ "$hit" == 1 ]] && return 0
  hit=$(db "SELECT 1 FROM agents_org
             WHERE (name=${qa} AND reports_to=${qb}) OR (name=${qb} AND reports_to=${qa}) LIMIT 1;" 2>/dev/null) || hit=""
  [[ "$hit" == 1 ]] && return 0
  # Legacy teams: no membership rows yet, read from the org subtree under the lead.
  local key lead
  while IFS=$'\t' read -r key lead; do
    [[ -n "$key" && -n "$lead" ]] || continue
    [[ -e "${STATE_DIR:-/var/lib/5dive}/teams/${key}.5dive.yaml" ]] || continue
    hit=$(db "WITH RECURSIVE sub(n, d) AS (
                SELECT $(sqlq "$lead"), 0
                UNION SELECT o.name, sub.d + 1 FROM agents_org o JOIN sub ON o.reports_to = sub.n
                 WHERE sub.d < 64)
              SELECT COUNT(DISTINCT n) FROM sub WHERE n IN (${qa}, ${qb});" 2>/dev/null) || hit=""
    [[ "$hit" == 2 ]] && return 0
  done < <(db "SELECT p.key || char(9) || p.lead_agent FROM projects p
               WHERE COALESCE(p.lead_agent,'') <> ''
                 AND NOT EXISTS (SELECT 1 FROM team_members m WHERE m.team = p.key);" 2>/dev/null)
  return 1
}

# _rights_scope_target <verb> <caller> <target> — every refusal the two
# teammate verbs share. <caller> empty means root itself (no team scope).
_rights_scope_target() {
  local verb="$1" by="$2" to="$3" reg
  reg=$(registry_read 2>/dev/null) || reg=""
  [[ "$(jq -r --arg n "$to" '.agents[$n] != null' <<<"$reg" 2>/dev/null)" == true ]] \
    || _rights_refuse "$verb" "$E_NOT_FOUND" "$by" "refused: no agent named '$to' on this box" "target=$to"
  _rights_seat_user "$to" \
    || _rights_refuse "$verb" "$E_NOT_FOUND" "$by" "refused: '$to' has no agent-$to seat user on this box" "target=$to"
  [[ -z "$by" || "$by" != "$to" ]] \
    || _rights_refuse "$verb" "$E_VALIDATION" "$by" "refused: '$to' is you — this verb reaches a teammate, not yourself" "target=$to"
  ! _rights_sandboxed "$to" \
    || _rights_refuse "$verb" "$E_PERMISSION" "$by" "refused: '$to' is sandboxed (or its isolation is not measured), so no other seat may reach it" "target=$to"
  [[ -z "$by" ]] && return 0
  _rights_teammates "$by" "$to" \
    || _rights_refuse "$verb" "$E_PERMISSION" "$by" "refused: '$to' is not your teammate (you share no team and neither of you manages the other)" "target=$to"
}

# ── agent _peek ────────────────────────────────────────────────────────────────

cmd_agent_peek_delegated() {
  local verb="agent _peek" name="" lines="$RIGHTS_PEEK_DEFAULT" a
  local usage="usage: 5dive agent _peek <name> [--lines=N]"
  _gate_is_root || fail "$E_PERMISSION" "agent _peek is a privileged internal primitive (reachable only through its exact NOPASSWD grant). Use: 5dive agent peek <name>"
  for a in "$@"; do
    case "$a" in
      --lines=*) lines="${a#--lines=}" ;;
      -*)        fail "$E_USAGE" "$usage (unknown flag '${a:0:40}')" ;;
      *)         [[ -z "$name" ]] && name="$a" || fail "$E_USAGE" "$usage (one name only)" ;;
    esac
  done
  [[ -n "$name" ]] || fail "$E_USAGE" "$usage"
  _rights_name_ok "$name" || fail "$E_VALIDATION" "invalid agent name '${name:0:40}' (lowercase letter start, [a-z0-9-], <=32 chars)"
  [[ "$lines" =~ ^[0-9]{1,4}$ ]] && (( 10#$lines >= 1 && 10#$lines <= RIGHTS_PEEK_MAX )) \
    || fail "$E_VALIDATION" "--lines must be 1..${RIGHTS_PEEK_MAX}"
  lines=$((10#$lines))
  local by=""
  if [[ -n "${SUDO_UID:-}" ]]; then
    by=$(_rights_caller) || fail "$E_AUTH_REQUIRED" "agent _peek: caller uid ${SUDO_UID} is not an agent seat"
  fi
  _rights_scope_target "$verb" "$by" "$name"
  local cap
  cap=$(_rights_as "agent-$name" tmux capture-pane -p -J -t "agent-$name" -S "-$lines" 2>/dev/null) \
    || _rights_refuse "$verb" "$E_NOT_RUNNING" "$by" "tmux session 'agent-$name' not found (is the agent running?)" "target=$name"
  cap=$(tail -n "$lines" <<<"$cap")
  audit_log "$verb" ok 0 -- "by=${by:-root}" "target=$name" "lines=$lines"
  if (( ${JSON_MODE:-0} )); then
    jq -cn --arg n "$name" --arg c "$cap" '{ok:true, data:{name:$n, source:"tmux", lines:($c | split("\n"))}}'
  else
    printf '%s\n' "$cap"
  fi
}

# Public form: `5dive agent peek <name> [--lines=N]`. Root runs the primitive
# in-process; any other caller crosses the one sudoers line.
cmd_agent_peek() {
  [[ $# -ge 1 ]] || fail "$E_USAGE" "usage: 5dive agent peek <name> [--lines=N]"
  if _gate_is_root; then cmd_agent_peek_delegated "$@"; return; fi
  local -a j=(); (( ${JSON_MODE:-0} )) && j=(--json)
  exec sudo -n /usr/local/bin/5dive agent _peek "$@" "${j[@]}"
}

# ── agent _skill_give ──────────────────────────────────────────────────────────

# The placement half, run AS THE RECIPIENT. A fixed script: base, skill and the
# replace flag arrive as positional args, the archive on stdin. Exit 17 = the
# skill exists and --replace was not given.
read -r -d '' _RIGHTS_PLACE_SCRIPT <<'PLACE' || true
set -eu
base=$1 skill=$2 replace=$3
mkdir -p -- "$base"
cd -- "$base"
if [ -e "$skill" ] || [ -L "$skill" ]; then
  [ "$replace" = 1 ] || exit 17
fi
tmp=$(mktemp -d ".give-$skill.XXXXXX")
if ! tar -x --no-same-owner --no-same-permissions -C "$tmp" -f -; then rm -rf -- "$tmp"; exit 18; fi
chmod -R a-st,go-w -- "$tmp"
chmod 755 -- "$tmp"
if [ -e "$skill" ] || [ -L "$skill" ]; then rm -rf -- "$skill"; fi
mv -T -- "$tmp" "$skill"
PLACE

# _rights_tar_check <archive> — prints "<files> <bytes>" when every entry is a
# regular file or a directory under ./ with no '..' part; rc 1 + a reason otherwise.
_rights_tar_check() {
  local list perms size name files=0 bytes=0
  list=$(LC_ALL=C tar --list --verbose --numeric-owner --quoting-style=escape -f "$1" 2>/dev/null) \
    || { printf 'the archive could not be read'; return 1; }
  while read -r perms _ size _ _ name; do
    [[ -n "$perms" ]] || continue
    case "${perms:0:1}" in
      -) files=$((files + 1)); [[ "$size" =~ ^[0-9]+$ ]] || { printf 'unreadable size'; return 1; }
         bytes=$((bytes + size)) ;;
      d) ;;
      l) printf 'it contains a symlink (%s)' "${name%% -> *}"; return 1 ;;
      h) printf 'it contains a hard link (%s)' "${name%% link to *}"; return 1 ;;
      *) printf 'it contains a special file (%s)' "$name"; return 1 ;;
    esac
    [[ "$name" == ./* || "$name" == . ]] || { printf 'entry outside the skill (%s)' "$name"; return 1; }
    [[ "/$name/" != */../* ]] || { printf "entry with a '..' part (%s)" "$name"; return 1; }
  done <<<"$list"
  (( files >= 1 )) || { printf 'the skill has no files'; return 1; }
  printf '%s %s' "$files" "$bytes"
}

cmd_agent_skill_give_delegated() {
  local verb="agent _skill_give" to="" skill="" replace=0 a
  local usage="usage: 5dive agent _skill_give <to> <skill> [--replace]"
  _gate_is_root || fail "$E_PERMISSION" "agent _skill_give is a privileged internal primitive (reachable only through its exact NOPASSWD grant). Use: 5dive agent skill <to> give <skill>"
  for a in "$@"; do
    case "$a" in
      --replace) replace=1 ;;
      -*) fail "$E_USAGE" "$usage (unknown flag '${a:0:40}')" ;;
      *)  if [[ -z "$to" ]]; then to="$a"; elif [[ -z "$skill" ]]; then skill="$a"; else fail "$E_USAGE" "$usage"; fi ;;
    esac
  done
  [[ -n "$to" && -n "$skill" ]] || fail "$E_USAGE" "$usage"
  _rights_name_ok "$to" || fail "$E_VALIDATION" "invalid agent name '${to:0:40}' (lowercase letter start, [a-z0-9-], <=32 chars)"
  _rights_skill_ok "$skill" || fail "$E_VALIDATION" "invalid skill name '${skill:0:40}' (letters, digits, . _ -; must start with a letter or digit)"
  local by
  by=$(_rights_caller) || fail "$E_AUTH_REQUIRED" "agent _skill_give needs a calling agent seat (run it through sudo from your own seat): the skill is copied from YOUR skills dir"
  _rights_scope_target "$verb" "$by" "$to"
  local src_base src dst_base
  src_base="$(_rights_home "$by")/$(skills_install_dir "$(registry_read | jq -r --arg n "$by" '.agents[$n].type // empty')")"
  dst_base="$(_rights_home "$to")/$(skills_install_dir "$(registry_read | jq -r --arg n "$to" '.agents[$n].type // empty')")"
  src="$src_base/$skill"
  # The skill dir itself, and every directory above it, must be what it says:
  # a symlink anywhere on the way would give someone else's tree under my name.
  [[ -d "$src" && ! -L "$src" && "$(readlink -f -- "$src")" == "$src" ]] \
    || _rights_refuse "$verb" "$E_NOT_FOUND" "$by" "refused: you have no skill '$skill' (no real directory at $src; symlinks are not followed)" "to=$to" "skill=$skill"
  local work rc=0 why
  work=$(mktemp -d) || fail "$E_GENERIC" "could not make a work dir"
  # Read AS THE GIVER: tar can only pack what that seat can read, and it never
  # follows a link (it records it, and the check below refuses it).
  _rights_as "agent-$by" tar -C "$src" -cf - . 2>/dev/null | head -c "$((RIGHTS_SKILL_MAX_STREAM + 1))" >"$work/s.tar"
  local -a ps=("${PIPESTATUS[@]}")
  if (( $(stat -c %s "$work/s.tar") > RIGHTS_SKILL_MAX_STREAM )); then
    rm -rf "$work"
    _rights_refuse "$verb" "$E_VALIDATION" "$by" "refused: skill '$skill' is over the $((RIGHTS_SKILL_MAX_BYTES / 1024 / 1024)) MB limit" "to=$to" "skill=$skill"
  fi
  if (( ps[0] != 0 )); then
    rm -rf "$work"
    _rights_refuse "$verb" "$E_GENERIC" "$by" "refused: skill '$skill' could not be read as agent-$by" "to=$to" "skill=$skill"
  fi
  local counts
  if ! counts=$(_rights_tar_check "$work/s.tar"); then
    rm -rf "$work"
    _rights_refuse "$verb" "$E_VALIDATION" "$by" "refused: skill '$skill' cannot be given — $counts" "to=$to" "skill=$skill"
  fi
  local nf="${counts%% *}" nb="${counts##* }"
  if (( nf > RIGHTS_SKILL_MAX_FILES )); then
    rm -rf "$work"
    _rights_refuse "$verb" "$E_VALIDATION" "$by" "refused: skill '$skill' has $nf files (limit $RIGHTS_SKILL_MAX_FILES)" "to=$to" "skill=$skill"
  fi
  if (( nb > RIGHTS_SKILL_MAX_BYTES )); then
    rm -rf "$work"
    _rights_refuse "$verb" "$E_VALIDATION" "$by" "refused: skill '$skill' is over the $((RIGHTS_SKILL_MAX_BYTES / 1024 / 1024)) MB limit ($nb bytes)" "to=$to" "skill=$skill"
  fi
  # Place AS THE RECIPIENT: it can only write where agent-$to already could.
  _rights_as "agent-$to" bash -c "$_RIGHTS_PLACE_SCRIPT" _ "$dst_base" "$skill" "$replace" <"$work/s.tar" 2>"$work/err" || rc=$?
  why=$(head -c 300 "$work/err" 2>/dev/null) || why=""
  rm -rf "$work"
  case "$rc" in
    0) ;;
    17) _rights_refuse "$verb" "$E_CONFLICT" "$by" "refused: '$to' already has a skill '$skill' (add --replace to overwrite it)" "to=$to" "skill=$skill" ;;
    *)  _rights_refuse "$verb" "$E_GENERIC" "$by" "could not place skill '$skill' for '$to' (rc=$rc${why:+: $why})" "to=$to" "skill=$skill" ;;
  esac
  audit_log "$verb" ok 0 -- "by=$by" "to=$to" "skill=$skill" "files=$nf" "bytes=$nb" "replace=$replace"
  ok "gave skill '$skill' to '$to' ($nf files, $nb bytes)" \
     '{from:$f, to:$t, skill:$k, files:($nf|tonumber), bytes:($nb|tonumber), replaced:($r=="1")}' \
     --arg f "$by" --arg t "$to" --arg k "$skill" --arg nf "$nf" --arg nb "$nb" --arg r "$replace"
}

# Public form: `5dive agent skill <to> give <skill> [--replace]` (cmd_skill).
cmd_agent_skill_give() {
  local to="$1"; shift
  if _gate_is_root; then cmd_agent_skill_give_delegated "$to" "$@"; return; fi
  local -a j=(); (( ${JSON_MODE:-0} )) && j=(--json)
  exec sudo -n /usr/local/bin/5dive agent _skill_give "$to" "$@" "${j[@]}"
}

# ── heartbeat _self on|off ─────────────────────────────────────────────────────

# Under the registry lock: keep the seat's own cadence and fresh setting, so a
# pause and a resume do not reset what its owner chose.
_hb_self_apply() {
  local op="$1" name="$2"
  if [[ "$op" == off ]]; then cmd_heartbeat_off "$name"; return; fi
  local reg every fresh
  reg=$(registry_read)
  every=$(jq -r --arg n "$name" '.agents[$n].heartbeat.everyMin // empty' <<<"$reg" 2>/dev/null) || every=""
  fresh=$(jq -r --arg n "$name" '.agents[$n].heartbeat.fresh // false' <<<"$reg" 2>/dev/null) || fresh=false
  local -a args=("$name")
  [[ "$every" =~ ^[0-9]+$ ]] && (( every > 0 )) && args+=("--every=$every")
  [[ "$fresh" == true ]] && args+=(--fresh) || args+=(--no-fresh)
  cmd_heartbeat_on "${args[@]}"
}

cmd_heartbeat_self_delegated() {
  local verb="heartbeat _self"
  _gate_is_root || fail "$E_PERMISSION" "heartbeat _self is a privileged internal primitive (reachable only through its exact NOPASSWD grant). Use: 5dive heartbeat self on|off"
  [[ $# -eq 1 && ( "$1" == on || "$1" == off ) ]] \
    || fail "$E_USAGE" "usage: 5dive heartbeat _self on|off   (no other arguments: the seat is the sudo caller)"
  local name
  name=$(_rights_caller) || fail "$E_AUTH_REQUIRED" "heartbeat _self must be run through sudo by an agent seat"
  require_agent "$name"
  audit_log "$verb $1" ok 0 -- "by=$name"
  with_registry_lock _hb_self_apply "$1" "$name"
}

# Public form: `5dive heartbeat self on|off`.
cmd_heartbeat_self() {
  [[ $# -eq 1 && ( "$1" == on || "$1" == off ) ]] \
    || fail "$E_USAGE" "usage: 5dive heartbeat self on|off   # enrol or pause your OWN heartbeat"
  if _gate_is_root; then cmd_heartbeat_self_delegated "$1"; return; fi
  exec sudo -n /usr/local/bin/5dive heartbeat _self "$1"
}
