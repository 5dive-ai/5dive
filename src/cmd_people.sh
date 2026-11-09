# -------- 5dive people — who may talk to each agent (DIVE-8035, DIVE-8032 A) --------
#
# ONE LIST ACROSS TELEGRAM AND TEAMS. The owner decides, from the app, who may
# talk to which agent and with what role. Before this the answer lived in three
# places nobody saw together: each bot's Telegram access.json allowFrom, each
# agent's Teams config.json allowed_users, and the box roles file. Now the box
# tasks DB is the source of truth and those three are written FROM it.
#
# THE MODEL (tasks DB, root-writes only — the `humans` trust stance, DIVE-3342):
#   humans        one record per person, several identities (telegram_id,
#                 teams_id = Entra object id, email) and a role.
#   human_access  (human_id, agent) = may talk to that agent; agent '*' = all.
#                 NOT human_agents: that one means "owns that agent's gates".
#   knocks        a stranger asking to talk to an agent, held for the owner.
#
# WHAT "MANAGED" MEANS, and why it is load-bearing. `humans` already has rows
# that nobody wrote through People: pairing records a person (DIVE-4698) and
# `human add` records gate owners. Those rows keep role NULL. A People write
# always sets a role. `people sync` adds and removes ONLY managed records' ids:
# an id that belongs to a pairing-era row is treated exactly like an unknown id
# and is never removed. Without this, the first person the owner added would
# evict every colleague pairing had recorded from every bot.
#
# ADOPTION BY PRESENCE. With zero managed rows `people sync` writes nothing and
# the box behaves exactly as before this file existed.
#
# SYNC RULES (each agent):
#   Telegram access.json allowFrom: + telegram ids of managed people allowed on
#     the agent; - an id ONLY when it belongs to a managed person NOT allowed
#     there (or a person just removed). Never an unknown/pairing-era id, never an
#     id in the bot's `owners`. Groups and dmPolicy are not touched.
#   Teams config.json: allowed_users by the same rule, plus access:"knock" (the
#     Teams plugin holds a sender who is not on the list and files a knock).
#   /etc/5dive/roles.json admins: + the teams:/telegram: keys of owner and admin
#     people. The keys this verb wrote are kept under `managed`, so it only ever
#     removes what it added: a hand-added admin survives every sync.
#
# THE KNOCK. A Teams sender not on the list is held by the plugin, which runs
# `sudo -n 5dive people knock file …` (the narrow per-seat grant in
# render_standard_sudoers). The owner gets a Telegram card with Allow / Admin /
# No; each button carries `kn:<kid>:<choice>:<nonce>` with ITS OWN nonce, and the
# plugin that receives the tap runs `sudo -n 5dive people knock answer <kid>
# <choice> --proof=<nonce> --by=telegram:<uid>`. Only the three hashes are stored
# (knocks.nonce_hash = {"allow":h,"admin":h,"no":h}), and a raw nonce exists only
# in the button the owner taps (the Bot API has no history a seat could read it
# back from), so a seat cannot answer its own knock. A nonce proves only the
# choice its button names: the owner's No cannot be replayed as Admin. Root (the app's exec) answers without a proof. The answer is handed to
# the agent's Teams server as knocks/<kid>.json in its state dir (DIVE-8036).

_PEOPLE_ID_RX='^[a-z0-9][a-z0-9_-]{0,31}$'
_PEOPLE_GUID_RX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
PEOPLE_KNOCK_CAP="${FIVEDIVE_KNOCK_CAP:-5}"
[[ "$PEOPLE_KNOCK_CAP" =~ ^[1-9][0-9]*$ ]] || PEOPLE_KNOCK_CAP=5
PEOPLE_ROLES_FILE="${FIVEDIVE_ROLES_FILE:-/etc/5dive/roles.json}"

_people_usage() {
  cat <<USAGE
5dive people — who may talk to each agent, across Telegram and Teams (DIVE-8035)

  5dive people ls                                   # everyone + waiting knocks
  5dive people add <id> --name=<text> [--telegram=<id>] [--teams=<entra object id>]
                        [--email=<addr>] [--role=owner|admin|member] [--agents=a,b|*]
  5dive people set <id> [--role=admin|member] [--agents=a,b|*] [--name=] [--email=]
                        [--telegram=] [--teams=]
  5dive people rm <id>                              # the owner cannot be removed
  5dive people sync                                 # rewrite Telegram/Teams/roles from the list
  5dive people knock file --agent=<a> --channel=teams|telegram --sender=<id>
                          [--name=<text>] [--email=<addr>]
  5dive people knock answer <knock id> allow|admin|no [--by=<channel:id>] [--proof=<nonce>]

  Allow = chat and give work. Admin = also pay, delete, change settings.
  READS (ls) — any agent. WRITES — root. A seat may run only \`knock file\` (for
  its own agent) and \`knock answer\` with the owner's tap proof, through sudo.
  Add --json for {ok,data}. With nobody added, nothing changes on this box.
USAGE
}

cmd_people() {
  [[ $# -gt 0 ]] || { _people_usage; mark_reported; exit "$E_USAGE"; }
  local sub="$1"; shift
  case "$sub" in
    ls|list)        cmd_people_ls "$@" ;;
    add)            cmd_people_write add "$@" ;;
    set)            cmd_people_write set "$@" ;;
    rm|remove)      cmd_people_rm "$@" ;;
    sync)           cmd_people_sync "$@" ;;
    knock)          cmd_people_knock "$@" ;;
    -h|--help|help) _people_usage ;;
    *) fail "$E_USAGE" "unknown people command: $sub (try: 5dive people --help)" ;;
  esac
}

# -------- helpers --------

_people_clean_text() {  # <text> <max> — one line, no control chars, capped
  local t="$1" max="$2"
  t=$(printf '%s' "$t" | tr -d '\000-\037\177')
  printf '%s' "${t:0:$max}"
}
_people_check_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ && ${#1} -le 120 ]] \
    || fail "$E_VALIDATION" "bad email '$1'"
}
_people_check_teams() {
  [[ "$1" =~ $_PEOPLE_GUID_RX ]] \
    || fail "$E_VALIDATION" "bad Teams id '$1' — the person's Entra object id (a GUID)"
}
_people_check_telegram() {
  [[ "$1" =~ ^[0-9]{1,20}$ ]] || fail "$E_VALIDATION" "bad telegram id '$1' — a numeric user id"
}
_people_agent_exists() {
  local reg; reg=$(registry_read 2>/dev/null) || return 1
  jq -e --arg n "$1" '(.agents // {})[$n] != null' <<<"$reg" >/dev/null 2>&1
}
_people_in_use() {
  [[ "$(db "SELECT 1 FROM humans WHERE role IS NOT NULL LIMIT 1;" 2>/dev/null)" == "1" ]]
}
# The seat a sudo caller is: empty for root itself (the app), "-" for a caller
# that is not a seat. SUDO_UID is only sound under a REAL root euid (DIVE-1413:
# below EUID 0 it is a plain env var), and sudo stamps it on the transition, so
# a non-root caller fails CLOSED to "-" — never to empty, which means "root, no
# proof needed". Both callers already refuse non-root; this keeps the read sound
# on its own.
_people_caller_seat() {
  _gate_is_root || { printf '%s' "-"; return 0; }
  local ruid="${SUDO_UID:-}" who=""
  [[ "$ruid" =~ ^[0-9]+$ && "$ruid" != 0 ]] || return 0
  who=$(actor_uid_to_name "$ruid" 2>/dev/null)
  case "$who" in
    agent-*) printf '%s' "${who#agent-}" ;;
    claude)  printf 'claude' ;;
    *)       printf '%s' "-" ;;   # a sudo caller that is not a seat
  esac
}
_people_home_of() {  # <agent>
  if [[ "$1" == claude ]]; then printf '%s/claude' "${AGENT_HOME_ROOT:-/home}"
  else printf '%s/agent-%s' "${AGENT_HOME_ROOT:-/home}" "$1"; fi
}
# Replace a person's access set. <id> <agents csv|*|"">
_people_set_access() {
  local id="$1" list="$2" a
  local sql="DELETE FROM human_access WHERE human_id=$(sqlq "$id");"
  if [[ "$list" == "*" ]]; then
    sql+="INSERT INTO human_access(human_id,agent) VALUES ($(sqlq "$id"),'*');"
  else
    local -a ags=(); IFS=',' read -ra ags <<<"$list"
    for a in "${ags[@]}"; do
      a="${a//[[:space:]]/}"; [[ -n "$a" ]] || continue
      sql+="INSERT OR IGNORE INTO human_access(human_id,agent) VALUES ($(sqlq "$id"),$(sqlq "$a"));"
    done
  fi
  db "BEGIN; ${sql} COMMIT;"
}
_people_check_agents() {  # <csv|*>
  [[ "$1" == "*" || -z "$1" ]] && return 0
  local -a ags=(); local a; IFS=',' read -ra ags <<<"$1"
  for a in "${ags[@]}"; do
    a="${a//[[:space:]]/}"; [[ -n "$a" ]] || continue
    valid_sender_label "$a" || fail "$E_VALIDATION" "bad agent name '$a'"
    _people_agent_exists "$a" || fail "$E_NOT_FOUND" "no agent named '$a'"
  done
}
_people_person_json() {  # <id>
  local rows
  rows=$(dbfmt -json "SELECT h.id, h.display_name AS name, COALESCE(h.role,'member') AS role,
      h.telegram_id AS telegram, h.teams_id AS teams, h.email,
      (SELECT group_concat(agent, ',') FROM (SELECT agent FROM human_access a WHERE a.human_id=h.id ORDER BY agent)) AS agents
    FROM humans h WHERE h.id=$(sqlq "$1");")
  jq -c '.[0] | .agents = (if .role == "owner" then ["*"] else ((.agents // "") | split(",") | map(select(length>0))) end)' <<<"${rows:-[]}"
}

# -------- ls --------

cmd_people_ls() {
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive people ls"
  local people knocks
  people=$(dbfmt -json "SELECT h.id, h.display_name AS name, COALESCE(h.role,'member') AS role,
      h.telegram_id AS telegram, h.teams_id AS teams, h.email,
      (SELECT group_concat(agent, ',') FROM (SELECT agent FROM human_access a WHERE a.human_id=h.id ORDER BY agent)) AS agents
    FROM humans h
    ORDER BY CASE COALESCE(h.role,'member') WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, h.id;")
  knocks=$(dbfmt -json "SELECT id, agent, channel, name, email, created_at FROM knocks
    WHERE status='pending' ORDER BY created_at, id;")
  people=$(jq -c 'map(.agents = (if .role == "owner" then ["*"] else ((.agents // "") | split(",") | map(select(length>0))) end))' <<<"${people:-[]}")
  [[ -n "$knocks" ]] || knocks="[]"
  if (( JSON_MODE )); then
    jq -cn --argjson p "$people" --argjson k "$knocks" '{ok:true, data:{people:$p, knocks:$k}}'
    return 0
  fi
  if [[ "$people" == "[]" ]]; then
    echo "(nobody on the list — every agent keeps its current Telegram and Teams access; add someone with: sudo 5dive people add <id> --name=<name> --agents=<agent>)"
  else
    jq -r '.[] | [.id, (.name // ""), .role,
                  (if .telegram then "telegram" else "" end) + (if .teams then (if .telegram then "+" else "" end) + "teams" else "" end),
                  (.agents | if length == 0 then "-" else join(",") end)] | @tsv' <<<"$people" \
      | { printf 'id\tname\trole\tchannels\tagents\n'; cat; } | column -t -s $'\t'
  fi
  if [[ "$knocks" != "[]" ]]; then
    echo; echo "Wants to talk to your agents:"
    jq -r '.[] | "  #\(.id) \(.name // "someone") → \(.agent) (\(.channel)\(if .email then ", " + .email else "" end))"' <<<"$knocks"
  fi
}

# -------- add / set --------

cmd_people_write() {
  local mode="$1"; shift
  require_root "people $mode"
  tasks_db_init
  local id="" name="" tg="" teams="" email="" role="" agents=""
  local name_set=0 tg_set=0 teams_set=0 email_set=0 role_set=0 agents_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*)     name=$(_people_clean_text "${1#*=}" 80); name_set=1 ;;
      --telegram=*) tg="${1#*=}";     tg_set=1 ;;
      --teams=*)    teams="${1#*=}"; teams="${teams,,}"; teams="${teams#teams:}"; teams_set=1 ;;
      --email=*)    email="${1#*=}"; email="${email,,}"; email_set=1 ;;
      --role=*)     role="${1#*=}";   role_set=1 ;;
      --agents=*)   agents="${1#*=}"; agents_set=1 ;;
      -*)           fail "$E_USAGE" "unknown flag: $1" ;;
      *)            [[ -z "$id" ]] && id="$1" || fail "$E_USAGE" "unexpected arg: $1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || fail "$E_USAGE" "usage: 5dive people $mode <id> [--name=] [--telegram=] [--teams=] [--email=] [--role=] [--agents=]"
  [[ "$id" =~ $_PEOPLE_ID_RX ]] || fail "$E_VALIDATION" "bad person id '$id' — lowercase slug, e.g. 'anna'"
  (( tg_set ))    && [[ -n "$tg" ]]    && _people_check_telegram "$tg"
  (( teams_set )) && [[ -n "$teams" ]] && _people_check_teams "$teams"
  (( email_set )) && [[ -n "$email" ]] && _people_check_email "$email"
  if (( role_set )); then
    case "$role" in owner|admin|member) ;; *) fail "$E_VALIDATION" "bad role '$role' — owner, admin or member" ;; esac
  fi
  (( agents_set )) && _people_check_agents "$agents"

  local existed cur_role
  existed=$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$id");")
  cur_role=$(db "SELECT COALESCE(role,'') FROM humans WHERE id=$(sqlq "$id");")
  if [[ "$mode" == set ]]; then
    [[ -n "$existed" ]] || fail "$E_NOT_FOUND" "no person '$id' (add them first: sudo 5dive people add $id --name=…)"
  fi
  # The owner row is the box's anchor: it cannot be demoted (nor removed, below).
  if [[ "$cur_role" == owner ]] && (( role_set )) && [[ "$role" != owner ]]; then
    fail "$E_CONFLICT" "'$id' is the owner — the owner cannot be demoted"
  fi
  if [[ "$mode" == set && "$role" == owner && "$cur_role" != owner ]]; then
    fail "$E_VALIDATION" "set cannot make someone the owner; the owner is named with: sudo 5dive people add <id> --role=owner"
  fi

  # One identity, one person: the same reasoning `human add` enforces, now for
  # the Teams id too (a unique index backs it).
  local clash
  if (( tg_set )) && [[ -n "$tg" ]]; then
    clash=$(db "SELECT id FROM humans WHERE telegram_id=$(sqlq "$tg") AND id<>$(sqlq "$id") LIMIT 1;")
    [[ -z "$clash" ]] || fail "$E_CONFLICT" "telegram id $tg is already on '$clash'"
  fi
  if (( teams_set )) && [[ -n "$teams" ]]; then
    clash=$(db "SELECT id FROM humans WHERE teams_id=$(sqlq "$teams") AND id<>$(sqlq "$id") LIMIT 1;")
    [[ -z "$clash" ]] || fail "$E_CONFLICT" "Teams id $teams is already on '$clash'"
  fi

  # A person whose telegram/teams id is replaced loses access by the OLD id too.
  local old_tg="" old_teams=""
  if [[ -n "$existed" && -n "$cur_role" ]]; then
    (( tg_set ))    && old_tg=$(db "SELECT COALESCE(telegram_id,'') FROM humans WHERE id=$(sqlq "$id");")
    (( teams_set )) && old_teams=$(db "SELECT COALESCE(teams_id,'') FROM humans WHERE id=$(sqlq "$id");")
    [[ "$old_tg" == "$tg" ]] && old_tg=""
    [[ "$old_teams" == "$teams" ]] && old_teams=""
  fi

  # Every People write leaves a role: that is what makes the record MANAGED
  # (see the header). Default member; an existing role is kept unless changed.
  local new_role="${role:-${cur_role:-member}}"
  db "INSERT OR IGNORE INTO humans (id) VALUES ($(sqlq "$id"));
      UPDATE humans SET role=$(sqlq "$new_role"), updated_at=datetime('now') WHERE id=$(sqlq "$id");"
  (( name_set ))  && db "UPDATE humans SET display_name=$(sqlq_or_null "$name") WHERE id=$(sqlq "$id");"
  (( tg_set ))    && db "UPDATE humans SET telegram_id=$(sqlq_or_null "$tg") WHERE id=$(sqlq "$id");"
  (( teams_set )) && db "UPDATE humans SET teams_id=$(sqlq_or_null "$teams") WHERE id=$(sqlq "$id");"
  (( email_set )) && db "UPDATE humans SET email=$(sqlq_or_null "$email") WHERE id=$(sqlq "$id");"
  (( agents_set )) && _people_set_access "$id" "$agents"

  audit_log "people $mode" ok 0 -- "person=$id" "role=$new_role" \
    "agents=$( (( agents_set )) && echo "${agents:-(none)}" || echo '(unchanged)')" \
    "by_claimed=${SUDO_USER:-root}"

  PEOPLE_REVOKED_TG="$old_tg" PEOPLE_REVOKED_TEAMS="$old_teams" _people_sync_run >/dev/null

  if (( JSON_MODE )); then
    jq -cn --argjson p "$(_people_person_json "$id")" '{ok:true, data:$p}'
  else
    ok "$id: $new_role$( (( agents_set )) && echo ", talks to ${agents:-nobody}")"
  fi
}

# -------- rm --------

cmd_people_rm() {
  require_root "people rm"
  tasks_db_init
  [[ $# -eq 1 ]] || fail "$E_USAGE" "usage: 5dive people rm <id>"
  local id="$1" row role tg teams
  row=$(db "SELECT COALESCE(role,'')||x'1f'||COALESCE(telegram_id,'')||x'1f'||COALESCE(teams_id,'') FROM humans WHERE id=$(sqlq "$id");")
  [[ -n "$row" ]] || fail "$E_NOT_FOUND" "no person '$id'"
  IFS=$'\x1f' read -r role tg teams <<<"$row"
  [[ "$role" != owner ]] || fail "$E_CONFLICT" "'$id' is the owner — the owner cannot be removed"
  db "BEGIN;
      DELETE FROM human_access WHERE human_id=$(sqlq "$id");
      DELETE FROM human_agents WHERE human_id=$(sqlq "$id");
      DELETE FROM humans WHERE id=$(sqlq "$id");
      COMMIT;"
  audit_log "people rm" ok 0 -- "person=$id" "by_claimed=${SUDO_USER:-root}"
  # A removed MANAGED person's ids leave every bot and agent; a pairing-era row
  # (role NULL) was never granted by People, so People does not revoke it.
  if [[ -n "$role" ]]; then
    PEOPLE_REVOKED_TG="$tg" PEOPLE_REVOKED_TEAMS="$teams" _people_sync_run >/dev/null
  fi
  ok "removed $id" '{removed:$i}' --arg i "$id"
}

# -------- sync --------

cmd_people_sync() {
  require_root "people sync"
  tasks_db_init
  [[ $# -eq 0 ]] || fail "$E_USAGE" "usage: 5dive people sync"
  local out; out=$(_people_sync_run)
  if (( JSON_MODE )); then
    jq -c '{ok:true, data:.}' <<<"$out"
  else
    local n; n=$(jq -r '.changed | length' <<<"$out")
    if [[ "$(jq -r '.in_use' <<<"$out")" != true && "$n" == 0 ]]; then
      ok "nobody on the list — nothing written"
    else
      ok "synced: $n file(s) changed$( (( n )) && printf '\n%s' "$(jq -r '.changed[] | "  " + .' <<<"$out")")"
    fi
  fi
}

# Prints {in_use, changed:[paths]}. Env: PEOPLE_REVOKED_TG / PEOPLE_REVOKED_TEAMS
# (ids of a person just removed or re-identified: dropped even though no
# managed row holds them any more).
_people_sync_run() {
  local people agents reg in_use=false
  _people_in_use && in_use=true
  if [[ "$in_use" != true && -z "${PEOPLE_REVOKED_TG:-}" && -z "${PEOPLE_REVOKED_TEAMS:-}" ]]; then
    # Zero managed rows: write nothing, so the box is exactly as it was. The one
    # exception is the roles file's own `managed` keys, cleaned below by python
    # when the last managed admin goes (rm passes the revoked ids).
    jq -cn '{in_use:false, changed:[]}'
    return 0
  fi
  people=$(dbfmt -json "SELECT h.id, h.role, h.telegram_id AS telegram, h.teams_id AS teams,
      (SELECT group_concat(agent, ',') FROM human_access a WHERE a.human_id=h.id) AS agents
    FROM humans h WHERE h.role IS NOT NULL;")
  reg=$(registry_read 2>/dev/null) || reg='{}'
  agents=$(jq -c '[(.agents // {}) | to_entries[] | {name:.key, type:(.value.type // ""), channels:(.value.channels // "")}]' <<<"$reg" 2>/dev/null) || agents='[]'
  local home_root="${AGENT_HOME_ROOT:-/home}"
  PEOPLE_JSON="${people:-[]}" AGENTS_JSON="$agents" HOME_ROOT="$home_root" \
  ROLES_FILE="$PEOPLE_ROLES_FILE" REVOKED_TG="${PEOPLE_REVOKED_TG:-}" REVOKED_TEAMS="${PEOPLE_REVOKED_TEAMS:-}" \
  IN_USE="$in_use" python3 - <<'PY'
import json, os, tempfile

people = json.loads(os.environ['PEOPLE_JSON'] or '[]')
agents = json.loads(os.environ['AGENTS_JSON'] or '[]')
home_root = os.environ['HOME_ROOT']
roles_file = os.environ['ROLES_FILE']
revoked_tg = {x for x in [os.environ.get('REVOKED_TG', '')] if x}
revoked_teams = {x.lower() for x in [os.environ.get('REVOKED_TEAMS', '')] if x}
changed = []

def allowed_on(p, agent):
    if p.get('role') == 'owner':
        return True
    ags = [a for a in (p.get('agents') or '').split(',') if a]
    return '*' in ags or agent in ags

def write_like(path, data, mode=None, owner_of=None):
    """Atomic write keeping the existing file's owner and mode (or those given)."""
    d = os.path.dirname(path)
    try:
        st = os.stat(path)
        uid, gid, m = st.st_uid, st.st_gid, st.st_mode & 0o777
    except FileNotFoundError:
        ref = os.stat(owner_of or d)
        uid, gid, m = ref.st_uid, ref.st_gid, (mode or 0o600)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.people.', suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.chmod(tmp, m)
    try:
        os.chown(tmp, uid, gid)
    except PermissionError:
        pass  # non-root harness: the file is already ours
    os.replace(tmp, path)
    changed.append(path)

def merge_ids(current, agent, key, norm, revoked, protect=()):
    allow = {norm(p[key]) for p in people if p.get(key) and allowed_on(p, agent)}
    deny = {norm(p[key]) for p in people if p.get(key) and not allowed_on(p, agent)} | revoked
    deny -= allow
    deny -= {norm(x) for x in protect}
    out = [x for x in current if norm(x) not in deny]
    have = {norm(x) for x in out}
    out += sorted(x for x in allow if x not in have)
    return out

def home_of(name):
    return os.path.join(home_root, 'claude' if name == 'claude' else f'agent-{name}')

TG_DIR = {'claude': '.claude', 'codex': '.codex', 'grok': '.grok', 'pi': '.pi', 'antigravity': '.gemini'}

for a in agents:
    name, typ, channels = a['name'], a['type'], ',' + a['channels'] + ','
    home = home_of(name)
    # Telegram
    if ',telegram,' in channels and typ in TG_DIR:
        path = os.path.join(home, TG_DIR[typ], 'channels', 'telegram', 'access.json')
        try:
            with open(path) as f:
                acc = json.load(f)
        except (FileNotFoundError, ValueError):
            acc = None
        if isinstance(acc, dict):
            cur = [str(x) for x in (acc.get('allowFrom') or [])]
            owners = [str(x) for x in (acc.get('owners') or []) if isinstance(x, (str, int))]
            new = merge_ids(cur, name, 'telegram', str, revoked_tg, protect=owners)
            if new != cur:
                acc['allowFrom'] = new
                write_like(path, acc)
    # Teams: an agent is Teams-connected when its config.json exists.
    path = os.path.join(home, '.claude', 'channels', 'teams', 'config.json')
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (FileNotFoundError, ValueError):
        cfg = None
    if isinstance(cfg, dict):
        cur = [str(x) for x in (cfg.get('allowed_users') or [])]
        new = merge_ids(cur, name, 'teams', lambda s: s.lower(), revoked_teams)
        nc = dict(cfg)
        nc['allowed_users'] = new
        if os.environ.get('IN_USE') == 'true':
            nc['access'] = 'knock'
        if nc != cfg:
            write_like(path, nc)

# Roles file: admins = hand-added ∪ owner/admin people's keys; `managed` = the
# keys this verb added, so a hand-added admin is never removed by a sync.
desired = set()
for p in people:
    if p.get('role') in ('owner', 'admin'):
        if p.get('teams'):
            desired.add('teams:' + p['teams'].lower())
        if p.get('telegram'):
            desired.add('telegram:' + str(p['telegram']))
try:
    with open(roles_file) as f:
        roles = json.load(f)
    if not isinstance(roles, dict):
        roles = None
except FileNotFoundError:
    roles = {}
except ValueError:
    roles = None  # a broken roles file is refused, never overwritten (teams bin stance)
if roles is not None:
    admins = [str(x).lower() for x in (roles.get('admins') or [])]
    managed = {str(x).lower() for x in (roles.get('managed') or [])}
    hand = [x for x in admins if x not in managed]
    new_admins = list(dict.fromkeys(hand + sorted(desired)))
    new_managed = sorted(desired - set(hand))
    nr = dict(roles)
    nr.setdefault('check', 'on')
    nr['admins'] = new_admins
    nr['managed'] = new_managed
    exists = os.path.exists(roles_file)
    if (exists and nr != roles) or (not exists and (new_admins or new_managed)):
        os.makedirs(os.path.dirname(roles_file), exist_ok=True)
        write_like(roles_file, nr, mode=0o644)

print(json.dumps({'in_use': os.environ.get('IN_USE') == 'true', 'changed': changed}))
PY
}

# -------- knocks --------

cmd_people_knock() {
  [[ $# -gt 0 ]] || fail "$E_USAGE" "usage: 5dive people knock file|answer …"
  local sub="$1"; shift
  case "$sub" in
    file)   cmd_people_knock_file "$@" ;;
    answer) cmd_people_knock_answer "$@" ;;
    *) fail "$E_USAGE" "unknown knock command: $sub (file|answer)" ;;
  esac
}

cmd_people_knock_file() {
  _gate_is_root || fail "$E_PERMISSION" "knock file runs as root (a seat reaches it with: sudo 5dive people knock file …)"
  tasks_db_init
  local agent="" channel="" sender="" name="" email=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent=*)   agent="${1#*=}" ;;
      --channel=*) channel="${1#*=}" ;;
      --sender=*)  sender="${1#*=}" ;;
      --name=*)    name=$(_people_clean_text "${1#*=}" 80) ;;
      --email=*)   email="${1#*=}"; email="${email,,}" ;;
      *) fail "$E_USAGE" "unknown arg: $1" ;;
    esac
    shift
  done
  # A seat files only for ITSELF: the agent comes from SUDO_UID, never trusted
  # from argv, so an agent cannot page the owner in another agent's name.
  local seat; seat=$(_people_caller_seat)
  [[ "$seat" != "-" ]] || fail "$E_AUTH_REQUIRED" "knock file caller uid ${SUDO_UID} is not an agent seat"
  if [[ -n "$seat" ]]; then
    [[ -z "$agent" || "$agent" == "$seat" ]] || fail "$E_PERMISSION" "a seat files knocks for itself only (you are $seat)"
    agent="$seat"
  fi
  [[ -n "$agent" && -n "$channel" && -n "$sender" ]] \
    || fail "$E_USAGE" "usage: 5dive people knock file --agent=<a> --channel=teams|telegram --sender=<id> [--name=] [--email=]"
  valid_sender_label "$agent" || fail "$E_VALIDATION" "bad agent name '$agent'"
  _people_agent_exists "$agent" || fail "$E_NOT_FOUND" "no agent named '$agent'"
  case "$channel" in
    teams)    sender="${sender,,}"; _people_check_teams "$sender" ;;
    telegram) _people_check_telegram "$sender" ;;
    *) fail "$E_VALIDATION" "bad channel '$channel' — teams or telegram" ;;
  esac
  [[ -z "$email" ]] || _people_check_email "$email"

  local col=teams_id; [[ "$channel" == telegram ]] && col=telegram_id
  # Already allowed (a race with an answer, or added from the app): no knock.
  local hid
  hid=$(db "SELECT h.id FROM humans h WHERE h.${col}=$(sqlq "$sender") AND h.role IS NOT NULL
             AND (h.role='owner' OR EXISTS (SELECT 1 FROM human_access a WHERE a.human_id=h.id AND a.agent IN ('*',$(sqlq "$agent"))))
           LIMIT 1;")
  if [[ -n "$hid" ]]; then
    _people_knock_out "" allowed 0 "$hid"; return 0
  fi
  # One knock per sender: a pending one is returned, not re-carded; a denied
  # one stays denied (the owner said no — re-knocking must not re-page them).
  local prev
  prev=$(db "SELECT id||x'1f'||status FROM knocks WHERE agent=$(sqlq "$agent") AND channel=$(sqlq "$channel")
              AND sender_id=$(sqlq "$sender") AND status IN ('pending','denied')
            ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, id DESC LIMIT 1;")
  if [[ -n "$prev" ]]; then
    _people_knock_out "${prev%%$'\x1f'*}" "${prev#*$'\x1f'}" 0 ""; return 0
  fi
  # The cap: an agent talked into a loop cannot flood the owner.
  local n; n=$(db "SELECT COUNT(*) FROM knocks WHERE agent=$(sqlq "$agent") AND status='pending';")
  (( n < PEOPLE_KNOCK_CAP )) \
    || fail "$E_CONFLICT" "$agent already has $n people waiting for the owner (cap $PEOPLE_KNOCK_CAP) — this one is not filed"

  # One nonce PER CHOICE: a proof answers only the button it rode on.
  local n_allow n_admin n_no hashes kid
  n_allow=$(_human_nonce_mint) && n_admin=$(_human_nonce_mint) && n_no=$(_human_nonce_mint) \
    || fail "$E_GENERIC" "could not mint a knock proof"
  hashes=$(jq -cn --arg a "$(_human_nonce_sha "$n_allow")" --arg d "$(_human_nonce_sha "$n_admin")" \
             --arg n "$(_human_nonce_sha "$n_no")" '{allow:$a, admin:$d, no:$n}') \
    || fail "$E_GENERIC" "could not record a knock proof"
  kid=$(db "INSERT INTO knocks (agent, channel, sender_id, name, email, nonce_hash)
            VALUES ($(sqlq "$agent"), $(sqlq "$channel"), $(sqlq "$sender"), $(sqlq_or_null "$name"),
                    $(sqlq_or_null "$email"), $(sqlq "$hashes"));
            SELECT last_insert_rowid();")
  [[ "$kid" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "knock was not recorded"
  audit_log "people knock file" ok 0 -- "knock=$kid" "agent=$agent" "channel=$channel" "by_claimed=${SUDO_USER:-root}"
  local carded=0
  _people_knock_card "$kid" "$agent" "$channel" "$name" "$email" "$n_allow" "$n_admin" "$n_no" && carded=1
  _people_knock_out "$kid" pending "$carded" ""
}

_people_knock_out() {  # <kid> <status> <carded> <human>
  if (( JSON_MODE )); then
    jq -cn --arg k "$1" --arg s "$2" --arg c "$3" --arg h "$4" \
      '{ok:true, data:{id:(($k|select(length>0)|tonumber) // null), status:$s, carded:($c=="1"), human:(($h|select(length>0)) // null)}}'
  elif [[ -n "$1" ]]; then
    printf '%s\n' "$1"
  else
    printf 'allowed\n'
  fi
}

_people_html() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

# The owner card on Telegram. Sent through the agent's own bot when it has one,
# else the box's gate notifier — the path gate alerts take (_task_send_owner).
# rc 0 = delivered. Never fails the knock: an undelivered card still shows in
# the app's Team tab.
_people_knock_card() {  # <kid> <agent> <channel> <name> <email> <nonce allow> <nonce admin> <nonce no>
  local kid="$1" agent="$2" channel="$3" who="${4:-Someone}" email="$5"
  local n_allow="$6" n_admin="$7" n_no="$8"
  _task_agent_channel "$agent" 2>/dev/null \
    || { local nt; nt=$(_task_resolve_gate_notifier 2>/dev/null) && [[ -n "$nt" ]] && _task_agent_channel "$nt" 2>/dev/null; } \
    || return 1
  local where="Teams"; [[ "$channel" == telegram ]] && where="Telegram"
  local ag="${agent^}"
  local plain="${who} wants to talk to ${ag}${email:+ · ${email}} · in ${where}"$'\n\n'"Allow = chat and give work. Admin = also pay, delete, change settings."
  local text
  text="<b>$(_people_html "$who")</b> wants to talk to ${ag}${email:+ · $(_people_html "$email")} · in ${where}"$'\n\n'"Allow = chat and give work. Admin = also pay, delete, change settings."
  local markup
  markup=$(jq -cn --arg k "$kid" --arg a "$n_allow" --arg d "$n_admin" --arg n "$n_no" '{inline_keyboard:[[
      {text:"Allow", callback_data:("kn:"+$k+":allow:"+$a)},
      {text:"Admin", callback_data:("kn:"+$k+":admin:"+$d)},
      {text:"No",    callback_data:("kn:"+$k+":no:"+$n)}]]}')
  _task_send_owner "$text" "$markup" "" "$plain" >/dev/null 2>&1 || true
  [[ "${TASK_SEND_DELIVERED:-0}" == 1 ]]
}

# A free slug for a new person, from the email, the name, or the channel id.
_people_new_id() {  # <email> <name> <channel> <sender>
  local base="" cand n=2
  [[ -n "$1" ]] && base="${1%%@*}"
  [[ -z "$base" && -n "$2" ]] && base="$2"
  base=$(printf '%s' "${base,,}" | tr -c 'a-z0-9_-' '-' | sed -E 's/-+/-/g; s/^[-_]+//; s/-+$//')
  base="${base:0:28}"
  if [[ ! "$base" =~ $_PEOPLE_ID_RX ]]; then
    if [[ "$3" == telegram ]]; then base="tg-$4"; else base="teams-${4:0:8}"; fi
    base="${base:0:28}"
  fi
  cand="$base"
  while [[ -n "$(db "SELECT 1 FROM humans WHERE id=$(sqlq "$cand");")" ]]; do
    cand="${base}-${n}"; n=$((n+1))
  done
  printf '%s' "$cand"
}

cmd_people_knock_answer() {
  _gate_is_root || fail "$E_PERMISSION" "knock answer runs as root (the app, or a seat's plugin through sudo with the owner's tap proof)"
  tasks_db_init
  local kid="" choice="" by="" proof=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by=*)    by=$(_people_clean_text "${1#*=}" 64) ;;
      --proof=*) proof="${1#*=}" ;;
      -*) fail "$E_USAGE" "unknown flag: $1" ;;
      *) if [[ -z "$kid" ]]; then kid="$1"; elif [[ -z "$choice" ]]; then choice="$1"; else fail "$E_USAGE" "unexpected arg: $1"; fi ;;
    esac
    shift
  done
  [[ "$kid" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "usage: 5dive people knock answer <knock id> allow|admin|no [--by=] [--proof=]"
  case "$choice" in allow|admin|no) ;; *) fail "$E_USAGE" "answer is allow, admin or no" ;; esac
  local row
  row=$(db "SELECT agent||x'1f'||channel||x'1f'||sender_id||x'1f'||COALESCE(name,'')||x'1f'||COALESCE(email,'')||x'1f'||status||x'1f'||COALESCE(nonce_hash,'')
            FROM knocks WHERE id=${kid};")
  [[ -n "$row" ]] || fail "$E_NOT_FOUND" "no knock #$kid"
  local agent channel sender name email status nhash
  IFS=$'\x1f' read -r agent channel sender name email status nhash <<<"$row"
  # A seat answers only with the owner's tap proof FOR THE CHOICE GIVEN: each
  # button carries its own nonce, so the No (or Allow) button's nonce never
  # proves Admin. A stored hash that is not the per-choice object matches
  # nothing. Root (the app) needs none.
  local seat; seat=$(_people_caller_seat)
  if [[ -n "$seat" ]]; then
    local want; want=$(jq -r --arg c "$choice" 'if type=="object" then (.[$c] // "") else "" end' <<<"$nhash" 2>/dev/null)
    [[ "$proof" =~ ^[0-9a-f]{32}$ && "$want" =~ ^[0-9a-f]{64}$ && "$(_human_nonce_sha "$proof")" == "$want" ]] \
      || fail "$E_PERMISSION" "a seat answers a knock only with the owner's tap proof for that answer"
  fi
  [[ "$status" == pending ]] || fail "$E_CONFLICT" "knock #$kid is already answered ($status)"

  local hid="" new_status=denied
  [[ -z "$by" ]] && by="${SUDO_USER:-root}"
  if [[ "$choice" != no ]]; then
    new_status=allowed
    local col=teams_id; [[ "$channel" == telegram ]] && col=telegram_id
    hid=$(db "SELECT id FROM humans WHERE ${col}=$(sqlq "$sender") LIMIT 1;")
    # Someone added in the app by name + email has no id on this channel yet:
    # their first knock binds to that record instead of making a second one.
    # Only a record with NO id on this channel (an identity is never re-pointed)
    # and never the owner's (an owner tap of Allow must not mint a second owner
    # identity from an email the knocking server reported). An admin record
    # binds only on an Admin tap: the bind keeps the record's role, so binding
    # it on Allow ("chat and give work") would grant admin by email alone; on
    # Allow that knock becomes a fresh member row instead.
    if [[ -z "$hid" && -n "$email" ]]; then
      local skip="'owner'"; [[ "$choice" == admin ]] || skip="'owner','admin'"
      hid=$(db "SELECT id FROM humans WHERE lower(email)=lower($(sqlq "$email")) AND ${col} IS NULL
                  AND COALESCE(role,'') NOT IN (${skip}) ORDER BY (role IS NULL), id LIMIT 1;")
      [[ -z "$hid" ]] || db "UPDATE humans SET ${col}=$(sqlq "$sender"), updated_at=datetime('now') WHERE id=$(sqlq "$hid");"
    fi
    if [[ -z "$hid" ]]; then
      hid=$(_people_new_id "$email" "$name" "$channel" "$sender")
      db "INSERT INTO humans (id, display_name, ${col}, email, role)
          VALUES ($(sqlq "$hid"), $(sqlq_or_null "$name"), $(sqlq "$sender"), $(sqlq_or_null "$email"), 'member');"
    fi
    local cur; cur=$(db "SELECT COALESCE(role,'') FROM humans WHERE id=$(sqlq "$hid");")
    local nr="$cur"
    [[ -z "$nr" ]] && nr=member
    [[ "$choice" == admin && "$cur" != owner ]] && nr=admin
    db "UPDATE humans SET role=$(sqlq "$nr"),
          display_name=COALESCE(display_name, $(sqlq_or_null "$name")),
          email=COALESCE(email, $(sqlq_or_null "$email")), updated_at=datetime('now')
        WHERE id=$(sqlq "$hid");
        INSERT OR IGNORE INTO human_access (human_id, agent) VALUES ($(sqlq "$hid"), $(sqlq "$agent"));"
  fi
  # The status flip is the claim: two concurrent answers, one wins.
  local won
  won=$(db "UPDATE knocks SET status=$(sqlq "$new_status"), answered_at=datetime('now'),
              answered_by=$(sqlq "$by"), human_id=$(sqlq_or_null "$hid")
            WHERE id=${kid} AND status='pending'; SELECT changes();")
  [[ "$won" == 1 ]] || fail "$E_CONFLICT" "knock #$kid was answered meanwhile"
  audit_log "people knock answer" ok 0 -- "knock=$kid" "agent=$agent" "answer=$choice" "person=${hid:-none}" "by_claimed=$by"
  _people_sync_run >/dev/null
  _people_knock_drop "$kid" "$agent" "$channel" "$sender" "$name" "$choice" "$hid"
  if (( JSON_MODE )); then
    jq -cn --arg k "$kid" --arg s "$new_status" --arg a "$agent" --arg h "$hid" --arg c "$choice" \
      '{ok:true, data:{id:($k|tonumber), status:$s, answer:$c, agent:$a, person:(($h|select(length>0)) // null)}}'
  else
    ok "knock #$kid: $choice${hid:+ ($hid may talk to $agent)}"
  fi
}

# Hand the answer to the agent's Teams server: knocks/<kid>.json in its state
# dir, owned by the seat (the server watches the dir; DIVE-8036). Only for a
# Teams knock on a Teams-connected agent; a Telegram knock is let in by sync.
_people_knock_drop() {  # <kid> <agent> <channel> <sender> <name> <choice> <person>
  [[ "$3" == teams ]] || return 0
  local dir; dir="$(_people_home_of "$2")/.claude/channels/teams"
  [[ -d "$dir" ]] || return 0
  local owner; owner=$(stat -c '%u:%g' "$dir" 2>/dev/null) || return 0
  mkdir -p "$dir/knocks" && chmod 0700 "$dir/knocks" && chown "$owner" "$dir/knocks" 2>/dev/null
  local tmp; tmp=$(mktemp "$dir/knocks/.k.XXXXXX") || return 0
  jq -n --arg k "$1" --arg a "$2" --arg s "$4" --arg n "$5" --arg c "$6" --arg p "$7" \
    '{id:($k|tonumber), agent:$a, channel:"teams", sender:$s, name:(($n|select(length>0)) // null),
      answer:$c, person:(($p|select(length>0)) // null), answered_at:(now|todate)}' >"$tmp"
  chmod 0600 "$tmp"; chown "$owner" "$tmp" 2>/dev/null
  mv -f "$tmp" "$dir/knocks/$1.json"
}
