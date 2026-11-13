#!/usr/bin/env bash
# DIVE-8035 — `5dive people`: who may talk to each agent, the knock queue, and
# the sync that writes Telegram allowFrom, Teams allowed_users and the roles
# file FROM the tasks DB.
#
#   M1  MIGRATE ON A LIVE SHAPE — a pre-8035 store (humans without role/teams_id/
#       email, no human_access, no knocks, epoch 5769-1, one pairing-era row) is
#       migrated by tasks_db_init: columns + tables + index arrive, the row
#       survives, the epoch moves. (DIVE-2512: a fresh-DB harness never runs
#       _tasks_db_migrate, so this arm builds the old shape by hand.)
#   L1  `people ls --json` shape: {people:[], knocks:[]} on an empty box;
#   L2  (DIVE-8111) the empty list's line names Teams knocking, not "keeps access";
#   L3  (DIVE-8111) a waiting knock is listed with its answer command;
#   Z1  zero managed rows: sync writes NOTHING (files byte-identical);
#   W1  non-root write refused (E_PERMISSION) and writes nothing;
#   S1  add: the person's telegram id joins the allowed agent's allowFrom, Teams
#       id joins allowed_users with access:"knock"; another agent gains nothing;
#   S2  move to another agent: removed from the first; an UNKNOWN id and an
#       `owners` id stay; a pairing-era row's id (role NULL) is never removed;
#   S3  rm: a revoked person's ids leave every bot;
#   R1  roles.json: admin keys added under `managed`, a hand-added admin
#       survives a demote that removes the managed key;
#   O1  the owner cannot be removed or demoted;
#   K1  knock file: id printed, card sent with kn:<id>:<choice>:<nonce>, one
#       nonce per button;
#   K2  same sender again: same id, no second card;
#   K3  cap: the 6th pending knock on one agent is refused;
#   K4  answer allow: member created with access, synced into Teams, the answer
#       file dropped in the agent's teams state dir;
#   K5  answer admin: role admin, key in roles.json;
#   K6  answer no: denied, no person; a re-knock stays denied and is not re-carded;
#   K7  a seat answers only with the owner's tap proof; re-answer is a conflict;
#   K8  a seat files a knock for itself only (agent from SUDO_UID, never argv).
#   K9  a proof answers only its own button: the No/Allow nonce as admin is
#       refused, the knock stays pending, roles.json is unchanged.
#   E1  a knock answer binds to a person added by email (no twin row);
#   E2  never by the owner's email, never re-pointing a set Teams id.
#   E3  an admin record binds only on an Admin tap: Allow on an admin's email
#       makes a fresh member row and grants no admin key.
#   EM1-4 (DIVE-8315) an email knock: Allow/No card, no person, no access, the
#       answer dropped for the email channel, Admin refused, No sticks.
#   G1  the caller seat is read only under root; non-root fails closed to "-".
#
# Isolation: source src/ directly, throwaway TASKS_DB and fake homes, stubbed
# registry/send/audit, no root, no network.
# Run: bash tests/people_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-people.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh task/routing.sh task/notify.sh \
         cmd_human.sh cmd_people.sh; do
  source "$SRC/$f" 2>/dev/null
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
export AGENT_HOME_ROOT="$TMP/home"
PEOPLE_ROLES_FILE="$TMP/etc/roles.json"
JSON_MODE=1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

GA=aaaaaaaa-1111-2222-3333-444444444444   # anna's Entra id (fixture)
GK=bbbbbbbb-1111-2222-3333-444444444444   # a knocking stranger (fixture)
TG_OWNER=1234567890; TG_UNKNOWN=1234567891; TG_ANNA=1234567892; TG_PAIR=1234567893

# =============================================================================
# M1 — migrate a pre-8035 store
# =============================================================================
sqlite3 "$TASKS_DB" <<'SQL'
CREATE TABLE tasks (id INTEGER PRIMARY KEY);
CREATE TABLE task_prefs (key TEXT PRIMARY KEY, value TEXT, updated_at TEXT);
INSERT INTO task_prefs(key,value) VALUES ('schema_epoch','5769-1');
CREATE TABLE humans (
  id           TEXT PRIMARY KEY,
  display_name TEXT,
  telegram_id  TEXT,
  buzz_npub    TEXT,
  discord_id   TEXT,
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at   TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE human_agents (human_id TEXT NOT NULL, agent TEXT NOT NULL, PRIMARY KEY (human_id, agent));
INSERT INTO humans (id, telegram_id) VALUES ('tg-1234567893', '1234567893');
SQL
tasks_db_init >/dev/null 2>&1
M_COLS=$(sqlite3 "$TASKS_DB" "SELECT group_concat(name,',') FROM pragma_table_info('humans') WHERE name IN ('role','teams_id','email');")
M_TABS=$(sqlite3 "$TASKS_DB" "SELECT group_concat(name,',') FROM (SELECT name FROM sqlite_master WHERE name IN ('human_access','knocks','humans_teams_id_uq','knocks_one_pending') ORDER BY name);")
M_ROW=$(sqlite3 "$TASKS_DB" "SELECT id||':'||COALESCE(role,'NULL') FROM humans;")
M_EP=$(sqlite3 "$TASKS_DB" "SELECT value FROM task_prefs WHERE key='schema_epoch';")
[[ "$M_COLS" == "role,teams_id,email" && "$M_TABS" == "human_access,humans_teams_id_uq,knocks,knocks_one_pending" \
   && "$M_ROW" == "tg-1234567893:NULL" && "$M_EP" == "$_TASKS_SCHEMA_EPOCH" ]] \
  && ok_t "M1 a pre-8035 live-shape store migrates: columns, tables, indexes, row kept, epoch $M_EP" \
  || bad_t "M1 migration incomplete" "cols=$M_COLS tabs=$M_TABS row=$M_ROW epoch=$M_EP"

# =============================================================================
# fixtures: two agents, vesper (telegram + teams) and otto (telegram)
# =============================================================================
registry_read() { printf '%s' '{"agents":{"vesper":{"type":"claude","channels":"telegram"},"otto":{"type":"claude","channels":"telegram"}}}'; }
audit_log() { :; }
CARDS="$TMP/cards"; : >"$CARDS"
_task_agent_channel() { return 0; }
_task_send_owner() { printf '%s\n' "$2" >>"$CARDS"; TASK_SEND_DELIVERED=1; }
VA="$AGENT_HOME_ROOT/agent-vesper/.claude/channels/telegram/access.json"
OA="$AGENT_HOME_ROOT/agent-otto/.claude/channels/telegram/access.json"
VT="$AGENT_HOME_ROOT/agent-vesper/.claude/channels/teams/config.json"
mkdir -p "$(dirname "$VA")" "$(dirname "$OA")" "$(dirname "$VT")" "$TMP/etc"
printf '{"dmPolicy":"allowlist","allowFrom":["%s","%s","%s"],"owners":["%s"]}\n' "$TG_OWNER" "$TG_UNKNOWN" "$TG_PAIR" "$TG_OWNER" >"$VA"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"owners":["%s"]}\n' "$TG_OWNER" "$TG_OWNER" >"$OA"
printf '{"app_id":"x","tenant_id":"t","app_password":"p","port":3978}\n' >"$VT"
printf '{"check":"on","admins":["telegram:1234567899"],"members_may":[]}\n' >"$PEOPLE_ROLES_FILE"
allow_of() { jq -r '.allowFrom | join(",")' "$1"; }

# L1
L1=$(cmd_people_ls 2>&1)
[[ "$(jq -c '.data.people | map(.id)' <<<"$L1")" == '["tg-1234567893"]' && "$(jq -c '.data.knocks' <<<"$L1")" == '[]' \
   && "$(jq -r '.data.people[0].role' <<<"$L1")" == member && "$(jq -c '.data.people[0].agents' <<<"$L1")" == '[]' ]] \
  && ok_t "L1 people ls --json is {ok,data:{people:[{id,name,role,telegram,teams,email,agents}],knocks:[]}}" \
  || bad_t "L1 ls shape" "$L1"

# Z1 — the only row is pairing-era (role NULL): nothing is managed, nothing written
SUM0=$(cat "$VA" "$OA" "$VT" "$PEOPLE_ROLES_FILE" | sha256sum)
Z1=$(require_root() { :; }; cmd_people_sync 2>&1)
[[ "$(cat "$VA" "$OA" "$VT" "$PEOPLE_ROLES_FILE" | sha256sum)" == "$SUM0" && "$(jq -r '.data.in_use' <<<"$Z1")" == false ]] \
  && ok_t "Z1 zero managed people: sync writes nothing (byte-identical)" \
  || bad_t "Z1 sync touched files with nobody managed" "$Z1"

# W1 — non-root write refused
( unset FIVE_ARGV; cmd_people_write add mallory --name=M --agents=vesper ) >/dev/null 2>&1; W1RC=$?
[[ "$W1RC" == "$E_PERMISSION" && -z "$(db "SELECT 1 FROM humans WHERE id='mallory';")" ]] \
  && ok_t "W1 non-root people add is refused (rc $W1RC) and writes nothing" \
  || bad_t "W1 non-root write" "rc=$W1RC"

require_root() { :; }
_gate_is_root() { return 0; }

# S1
( cmd_people_write add anna --name="Anna P" --telegram=$TG_ANNA --teams=$GA --email=user@example.com --agents=vesper ) >/dev/null 2>&1
[[ "$(allow_of "$VA")" == "$TG_OWNER,$TG_UNKNOWN,$TG_PAIR,$TG_ANNA" && "$(allow_of "$OA")" == "$TG_OWNER" \
   && "$(jq -c '[.allowed_users, .access]' "$VT")" == "[[\"$GA\"],\"knock\"]" && "$(jq -r .app_password "$VT")" == p ]] \
  && ok_t "S1 add: telegram id joins vesper only; Teams allowed_users gains the id with access:knock, other keys kept" \
  || bad_t "S1 add sync" "vesper=$(allow_of "$VA") otto=$(allow_of "$OA") teams=$(jq -c . "$VT")"

# S2 — move anna to otto; also a managed member whose id is in vesper's owners
( cmd_people_write add bob --name=Bob --telegram=$TG_OWNER --agents=otto ) >/dev/null 2>&1
( cmd_people_write set anna --agents=otto ) >/dev/null 2>&1
[[ "$(allow_of "$VA")" == "$TG_OWNER,$TG_UNKNOWN,$TG_PAIR" && "$(allow_of "$OA")" == "$TG_OWNER,$TG_ANNA" \
   && "$(jq -c '.allowed_users' "$VT")" == '[]' ]] \
  && ok_t "S2 revoke: anna leaves vesper (Telegram + Teams); unknown id, owners id and pairing-era id stay" \
  || bad_t "S2 remove rules" "vesper=$(allow_of "$VA") otto=$(allow_of "$OA") teams=$(jq -c . "$VT")"

# S3
( cmd_people_rm anna ) >/dev/null 2>&1
[[ "$(allow_of "$OA")" == "$TG_OWNER" && -z "$(db "SELECT 1 FROM humans WHERE id='anna';")" ]] \
  && ok_t "S3 rm: a removed person's telegram id leaves every bot" \
  || bad_t "S3 rm" "otto=$(allow_of "$OA")"

# R1
( cmd_people_write add cara --name=Cara --teams=$GA --role=admin --agents='*' ) >/dev/null 2>&1
R1A=$(jq -c '[.admins, .managed]' "$PEOPLE_ROLES_FILE")
( cmd_people_write set cara --role=member ) >/dev/null 2>&1
R1B=$(jq -c '[.admins, .managed, .check]' "$PEOPLE_ROLES_FILE")
[[ "$R1A" == "[[\"telegram:1234567899\",\"teams:$GA\"],[\"teams:$GA\"]]" && "$R1B" == '[["telegram:1234567899"],[],"on"]' ]] \
  && ok_t "R1 roles.json: admin key added under managed; demote removes it; hand-added admin survives" \
  || bad_t "R1 roles" "after-admin=$R1A after-demote=$R1B"
( cmd_people_rm cara ) >/dev/null 2>&1

# O1
( cmd_people_write add lodar --name=Owner --telegram=1234567898 --role=owner ) >/dev/null 2>&1
( cmd_people_rm lodar ) >/dev/null 2>&1; O1A=$?
( cmd_people_write set lodar --role=member ) >/dev/null 2>&1; O1B=$?
[[ "$O1A" == "$E_CONFLICT" && "$O1B" == "$E_CONFLICT" && "$(db "SELECT role FROM humans WHERE id='lodar';")" == owner \
   && "$(cmd_people_ls | jq -r '.data.people[0].id + ":" + (.data.people[0].agents|join(","))')" == "lodar:*" ]] \
  && ok_t "O1 the owner cannot be removed or demoted, sorts first, talks to every agent" \
  || bad_t "O1 owner guard" "rm=$O1A set=$O1B"

# =============================================================================
# knocks
# =============================================================================
K1=$( cmd_people_knock_file --agent=vesper --channel=teams --sender=$GK --name="Kim Stranger" --email=user@example.com 2>&1 )
KID=$(jq -r '.data.id' <<<"$K1")
CB=$(jq -r '.inline_keyboard[0][0].callback_data' "$CARDS" 2>/dev/null)
NONCE="${CB##*:}"
CB_AD=$(jq -r '.inline_keyboard[0][1].callback_data' "$CARDS" 2>/dev/null); NONCE_AD="${CB_AD##*:}"
CB_NO=$(jq -r '.inline_keyboard[0][2].callback_data' "$CARDS" 2>/dev/null); NONCE_NO="${CB_NO##*:}"
[[ "$KID" =~ ^[0-9]+$ && "$(jq -r .data.status <<<"$K1")" == pending && "$CB" =~ ^kn:${KID}:allow:[0-9a-f]{32}$ \
   && "$CB_AD" =~ ^kn:${KID}:admin:[0-9a-f]{32}$ && "$CB_NO" =~ ^kn:${KID}:no:[0-9a-f]{32}$ \
   && "$NONCE" != "$NONCE_AD" && "$NONCE" != "$NONCE_NO" && "$NONCE_AD" != "$NONCE_NO" \
   && "$(jq -r '[.inline_keyboard[0][].text]|join("/")' "$CARDS")" == "Allow/Admin/No" \
   && -z "$(db "SELECT 1 FROM knocks WHERE instr(nonce_hash, $(sqlq "$NONCE"))
                OR instr(nonce_hash, $(sqlq "$NONCE_AD")) OR instr(nonce_hash, $(sqlq "$NONCE_NO"));")" ]] \
  && ok_t "K1 knock file: id $KID, owner card Allow/Admin/No, each button its own kn:<id>:<choice>:<nonce>, only hashes stored" \
  || bad_t "K1 knock file" "out=$K1 cb=$CB"

K2=$( cmd_people_knock_file --agent=vesper --channel=teams --sender=${GK^^} 2>&1 )
[[ "$(jq -r .data.id <<<"$K2")" == "$KID" && "$(wc -l <"$CARDS")" == 1 ]] \
  && ok_t "K2 dedupe: the same sender (any case) gets the same knock, no second card" \
  || bad_t "K2 dedupe" "out=$K2 cards=$(wc -l <"$CARDS")"

# L2/L3 (DIVE-8111) — the words a self-hoster with no Telegram reads. The empty
# list no longer claims every agent keeps its Teams access while a new Teams
# connection holds a stranger; a waiting knock names the answer command.
L2=$( TASKS_DB="$TMP/empty-l2.db"; JSON_MODE=0; cmd_people_ls 2>&1 )
[[ "$L2" == *"nobody on the list yet"* && "$L2" == *"A new Teams connection lets in only people you add"* \
   && "$L2" != *"keeps its current Telegram and Teams access"* ]] \
  && ok_t "L2 empty list: says a new Teams connection holds anyone not added (not 'keeps its Teams access')" \
  || bad_t "L2 empty words" "$L2"
L3=$( JSON_MODE=0; cmd_people_ls 2>&1 )
[[ "$L3" == *"#$KID Kim Stranger → vesper (teams, user@example.com)"* \
   && "$L3" == *"Answer: sudo 5dive people knock answer <number> allow"* ]] \
  && ok_t "L3 a waiting knock is listed with the command that answers it" \
  || bad_t "L3 knock words" "$L3"

for i in 1 2 3 4; do
  cmd_people_knock_file --agent=vesper --channel=teams --sender="cccccccc-1111-2222-3333-00000000000$i" >/dev/null 2>&1
done
( cmd_people_knock_file --agent=vesper --channel=teams --sender=dddddddd-1111-2222-3333-444444444444 ) >/dev/null 2>&1; K3RC=$?
[[ "$K3RC" == "$E_CONFLICT" && "$(db "SELECT COUNT(*) FROM knocks WHERE agent='vesper' AND status='pending';")" == 5 \
   && "$(cmd_people_ls | jq '.data.knocks | length')" == 5 ]] \
  && ok_t "K3 cap: the 6th pending knock on one agent is refused (rc $K3RC); ls lists the 5" \
  || bad_t "K3 cap" "rc=$K3RC"

# K7 first half — a seat without the proof is refused (before K4 answers it)
actor_uid_to_name() { printf 'agent-vesper'; }
( SUDO_UID=4321 cmd_people_knock_answer "$KID" admin ) >/dev/null 2>&1; K7A=$?
( SUDO_UID=4321 cmd_people_knock_answer "$KID" admin --proof=00000000000000000000000000000000 ) >/dev/null 2>&1; K7B=$?

# K9 — a proof answers only its own button: the owner's No (or Allow) nonce
# replayed as admin is refused, the knock stays pending, roles.json untouched.
R9=$(cat "$PEOPLE_ROLES_FILE" 2>/dev/null)
( SUDO_UID=4321 cmd_people_knock_answer "$KID" admin --proof="$NONCE_NO" ) >/dev/null 2>&1; K9A=$?
( SUDO_UID=4321 cmd_people_knock_answer "$KID" admin --proof="$NONCE" ) >/dev/null 2>&1; K9B=$?
( SUDO_UID=4321 cmd_people_knock_answer "$KID" allow --proof="$NONCE_NO" ) >/dev/null 2>&1; K9C=$?
[[ "$K9A" == "$E_PERMISSION" && "$K9B" == "$E_PERMISSION" && "$K9C" == "$E_PERMISSION" \
   && "$(db "SELECT status FROM knocks WHERE id=$KID;")" == pending \
   && "$(cat "$PEOPLE_ROLES_FILE" 2>/dev/null)" == "$R9" ]] \
  && ok_t "K9 a seat cannot replay the No or Allow button's nonce as admin (or No's as allow); knock stays pending, roles.json unchanged" \
  || bad_t "K9 proof bound to choice" "no-as-admin=$K9A allow-as-admin=$K9B no-as-allow=$K9C status=$(db "SELECT status FROM knocks WHERE id=$KID;")"

K4=$( SUDO_UID=4321 cmd_people_knock_answer "$KID" allow --proof="$NONCE" --by=telegram:1234567898 2>&1 )
K4P=$(jq -r .data.person <<<"$K4")
DROP="$AGENT_HOME_ROOT/agent-vesper/.claude/channels/teams/knocks/$KID.json"
[[ "$(jq -r .data.status <<<"$K4")" == allowed && "$K4P" == user \
   && "$(db "SELECT role||':'||teams_id||':'||display_name FROM humans WHERE id='user';")" == "member:$GK:Kim Stranger" \
   && "$(db "SELECT agent FROM human_access WHERE human_id='user';")" == vesper \
   && "$(jq -c '.allowed_users' "$VT")" == "[\"$GK\"]" \
   && "$(jq -r '.answer + ":" + .sender + ":" + .person' "$DROP" 2>/dev/null)" == "allow:$GK:user" ]] \
  && ok_t "K4 answer allow: member created with access, synced into Teams, knocks/$KID.json dropped for the server" \
  || bad_t "K4 answer allow" "out=$K4 drop=$(cat "$DROP" 2>/dev/null)"

( SUDO_UID=4321 cmd_people_knock_answer "$KID" allow --proof="$NONCE" ) >/dev/null 2>&1; K7C=$?
[[ "$K7A" == "$E_PERMISSION" && "$K7B" == "$E_PERMISSION" && "$K7C" == "$E_CONFLICT" ]] \
  && ok_t "K7 a seat needs the owner's tap proof (none/wrong refused); an answered knock cannot be re-answered" \
  || bad_t "K7 seat proof" "none=$K7A wrong=$K7B again=$K7C"
unset -f actor_uid_to_name; source "$SRC/lib/actor.sh" 2>/dev/null; _gate_is_root() { return 0; }

# K5 — admin
K5ID=$(db "SELECT id FROM knocks WHERE sender_id='cccccccc-1111-2222-3333-000000000001';")
( cmd_people_knock_answer "$K5ID" admin ) >/dev/null 2>&1
K5P=$(db "SELECT human_id FROM knocks WHERE id=$K5ID;")
[[ "$(db "SELECT role FROM humans WHERE id=$(sqlq "$K5P");")" == admin \
   && "$(jq -r '.admins | index("teams:cccccccc-1111-2222-3333-000000000001") != null' "$PEOPLE_ROLES_FILE")" == true ]] \
  && ok_t "K5 answer admin: role admin and the Teams key lands in roles.json" \
  || bad_t "K5 answer admin" "person=$K5P roles=$(cat "$PEOPLE_ROLES_FILE")"

# K6 — no
K6ID=$(db "SELECT id FROM knocks WHERE sender_id='cccccccc-1111-2222-3333-000000000002';")
NH=$(db "SELECT COUNT(*) FROM humans;")
( cmd_people_knock_answer "$K6ID" no ) >/dev/null 2>&1
C0=$(wc -l <"$CARDS")
K6R=$(cmd_people_knock_file --agent=vesper --channel=teams --sender=cccccccc-1111-2222-3333-000000000002 2>&1)
[[ "$(db "SELECT status FROM knocks WHERE id=$K6ID;")" == denied && "$(db "SELECT COUNT(*) FROM humans;")" == "$NH" \
   && "$(jq -r '.data.status + ":" + (.data.id|tostring)' <<<"$K6R")" == "denied:$K6ID" && "$(wc -l <"$CARDS")" == "$C0" \
   && "$(jq -r .answer "$AGENT_HOME_ROOT/agent-vesper/.claude/channels/teams/knocks/$K6ID.json" 2>/dev/null)" == no ]] \
  && ok_t "K6 answer no: denied, nobody added, answer file says no; a re-knock stays denied, no new card" \
  || bad_t "K6 answer no" "re=$K6R"

# K8 — a seat files for itself only
actor_uid_to_name() { printf 'agent-otto'; }
( SUDO_UID=4321 cmd_people_knock_file --agent=vesper --channel=telegram --sender=1234567870 ) >/dev/null 2>&1; K8A=$?
K8B=$( SUDO_UID=4321 cmd_people_knock_file --channel=telegram --sender=1234567870 2>&1 )
[[ "$K8A" == "$E_PERMISSION" && "$(db "SELECT agent FROM knocks WHERE id=$(jq -r .data.id <<<"$K8B");")" == otto ]] \
  && ok_t "K8 a seat cannot knock in another agent's name; its own agent comes from SUDO_UID" \
  || bad_t "K8 seat scope" "other=$K8A own=$K8B"

# E1 — a person added in the app by email binds on their first knock (no twin)
( cmd_people_write add eve --name=Eve --email=user2@example.com --agents=vesper ) >/dev/null 2>&1
GE=eeeeeeee-1111-2222-3333-444444444444
NE=$(db "SELECT COUNT(*) FROM humans;")
E1K=$(cmd_people_knock_file --agent=otto --channel=teams --sender=$GE --name="Eve E" --email=user2@example.com 2>&1 | jq -r .data.id)
E1=$( cmd_people_knock_answer "$E1K" allow 2>&1 )
[[ "$(jq -r .data.person <<<"$E1")" == eve && "$(db "SELECT COUNT(*) FROM humans;")" == "$NE" \
   && "$(db "SELECT role||':'||teams_id||':'||display_name FROM humans WHERE id='eve';")" == "member:$GE:Eve" \
   && "$(db "SELECT group_concat(agent, ',') FROM (SELECT agent FROM human_access WHERE human_id='eve' ORDER BY agent);")" == "otto,vesper" ]] \
  && ok_t "E1 knock answer binds to the person added by email: no second row, Teams id set, access added" \
  || bad_t "E1 email bind" "out=$E1 rows=$(db "SELECT COUNT(*) FROM humans;") vs $NE"

# E2 — never re-point an identity, never bind to the owner by email
( cmd_people_write set lodar --email=user3@example.com ) >/dev/null 2>&1
GF=ffffffff-1111-2222-3333-444444444444
E2A=$(cmd_people_knock_file --agent=otto --channel=teams --sender=$GF --email=user3@example.com 2>&1 | jq -r .data.id)
E2P=$( cmd_people_knock_answer "$E2A" allow 2>&1 | jq -r .data.person )
GG=99999999-1111-2222-3333-444444444444
E2B=$(cmd_people_knock_file --agent=otto --channel=teams --sender=$GG --email=user2@example.com 2>&1 | jq -r .data.id)
E2Q=$( cmd_people_knock_answer "$E2B" allow 2>&1 | jq -r .data.person )
[[ -n "$E2P" && "$E2P" != lodar && "$(db "SELECT COALESCE(teams_id,'')||':'||role FROM humans WHERE id='lodar';")" == ":owner" \
   && -n "$E2Q" && "$E2Q" != eve && "$(db "SELECT teams_id FROM humans WHERE id='eve';")" == "$GE" ]] \
  && ok_t "E2 the owner's email and a person who already has a Teams id are never bound by a knock" \
  || bad_t "E2 bind limits" "owner-knock=$E2P eve-knock=$E2Q"

# E3 — Allow on an admin's email never grants admin; Admin on it binds
( cmd_people_write add ada --name=Ada --email=user4@example.com --role=admin --agents=vesper ) >/dev/null 2>&1
GH=abababab-1111-2222-3333-444444444444
E3A=$(cmd_people_knock_file --agent=otto --channel=teams --sender=$GH --email=user4@example.com 2>&1 | jq -r .data.id)
E3P=$( cmd_people_knock_answer "$E3A" allow 2>&1 | jq -r .data.person )
GI=cdcdcdcd-1111-2222-3333-444444444444
E3B=$(cmd_people_knock_file --agent=vesper --channel=teams --sender=$GI --email=user4@example.com 2>&1 | jq -r .data.id)
E3Q=$( cmd_people_knock_answer "$E3B" admin 2>&1 | jq -r .data.person )
[[ -n "$E3P" && "$E3P" != ada && "$(db "SELECT role FROM humans WHERE id=$(sqlq "$E3P");")" == member \
   && "$(jq -r --arg k "teams:$GH" '(.admins // []) | index($k) // "none"' "$PEOPLE_ROLES_FILE" 2>/dev/null)" == none \
   && "$E3Q" == ada && "$(db "SELECT role||':'||teams_id FROM humans WHERE id='ada';")" == "admin:$GI" ]] \
  && ok_t "E3 Allow on an admin's email makes a fresh member (no admin key); Admin on it binds the admin record" \
  || bad_t "E3 admin bind" "allow=$E3P role=$(db "SELECT role FROM humans WHERE id=$(sqlq "$E3P");") admin=$E3Q ada=$(db "SELECT role||':'||COALESCE(teams_id,'') FROM humans WHERE id='ada';")"

# EM1-EM3 — DIVE-8315: an email knock is about one outgoing mail's recipient.
# The card has Allow / No only; Allow and No touch nobody's access (a person row
# would switch the box into managed People mode and rewrite every Telegram and
# Teams allowlist); the answer lands in the agent's email state dir; Admin is
# refused. (Addresses are @example.com: the fixture rule.)
mkdir -p "$AGENT_HOME_ROOT/agent-otto/.claude/channels/email"
NH0=$(db "SELECT COUNT(*) FROM humans;"); NA0=$(db "SELECT COUNT(*) FROM human_access;")
ROLES0=$(cat "$PEOPLE_ROLES_FILE" 2>/dev/null | md5sum)
: >"$CARDS"
EMK=$(cmd_people_knock_file --agent=otto --channel=email --sender=User5@Example.com 2>&1)
EMID=$(jq -r .data.id <<<"$EMK")
EMCB=$(jq -r '.inline_keyboard[0][0].callback_data' "$CARDS" 2>/dev/null)
EMTXT=$(jq -r '[.inline_keyboard[0][].text]|join("/")' "$CARDS" 2>/dev/null)
[[ "$EMID" =~ ^[0-9]+$ && "$(jq -r .data.status <<<"$EMK")" == pending && "$EMCB" =~ ^kn:${EMID}:allow:[0-9a-f]{32}$ \
   && "$EMTXT" == "Allow/No" && "$(db "SELECT sender_id||':'||email FROM knocks WHERE id=$EMID;")" == "user5@example.com:user5@example.com" ]] \
  && ok_t "EM1 email knock: filed on the lower-cased address, owner card Allow/No (no Admin)" \
  || bad_t "EM1 email knock" "out=$EMK cards=$EMTXT"
( cmd_people_knock_answer "$EMID" admin ) >/dev/null 2>&1; EMADM=$?
EMA=$( cmd_people_knock_answer "$EMID" allow 2>&1 )
EMDROP="$AGENT_HOME_ROOT/agent-otto/.claude/channels/email/knocks/$EMID.json"
[[ "$EMADM" == "$E_VALIDATION" && "$(jq -r .data.status <<<"$EMA")" == allowed && "$(jq -r .data.person <<<"$EMA")" == null \
   && "$(db "SELECT COUNT(*) FROM humans;")" == "$NH0" && "$(db "SELECT COUNT(*) FROM human_access;")" == "$NA0" \
   && "$(cat "$PEOPLE_ROLES_FILE" 2>/dev/null | md5sum)" == "$ROLES0" \
   && "$(jq -c '[.channel, .sender, .answer]' "$EMDROP" 2>/dev/null)" == '["email","user5@example.com","allow"]' ]] \
  && ok_t "EM2 email Allow: no person, no access, roles untouched; Admin refused (rc $EMADM); answer dropped for the email channel" \
  || bad_t "EM2 email allow" "adm=$EMADM out=$EMA humans=$(db "SELECT COUNT(*) FROM humans;")/$NH0 drop=$(cat "$EMDROP" 2>/dev/null)"
EMN=$(cmd_people_knock_file --agent=otto --channel=email --sender=user6@example.com 2>&1 | jq -r .data.id)
EMNO=$( cmd_people_knock_answer "$EMN" no 2>&1 )
EMRE=$( cmd_people_knock_file --agent=otto --channel=email --sender=user6@example.com 2>&1 )
[[ "$(jq -r .data.status <<<"$EMNO")" == denied && "$(jq -r .data.status <<<"$EMRE")" == denied && "$(jq -r .data.id <<<"$EMRE")" == "$EMN" \
   && "$(jq -r .answer "$AGENT_HOME_ROOT/agent-otto/.claude/channels/email/knocks/$EMN.json" 2>/dev/null)" == no \
   && "$(db "SELECT COUNT(*) FROM humans;")" == "$NH0" ]] \
  && ok_t "EM3 email No: denied, dropped as no, a re-knock on that address stays denied, still no person" \
  || bad_t "EM3 email no" "no=$EMNO re=$EMRE"
( cmd_people_knock_file --agent=otto --channel=email --sender=not-an-address ) >/dev/null 2>&1; EMBAD=$?
[[ "$EMBAD" == "$E_VALIDATION" ]] && ok_t "EM4 a bad address is refused (rc $EMBAD)" || bad_t "EM4 bad address" "rc=$EMBAD"

# G1 — the caller seat is read only under a real root euid: below it SUDO_UID is a
# plain env var, so a non-root caller fails CLOSED to "-" (never "" = root/app).
G1=$( _gate_is_root() { return 1; }; SUDO_UID=4321 _people_caller_seat )
G1R=$( SUDO_UID=4321 _people_caller_seat )
[[ "$G1" == "-" && "$G1R" == otto ]] \
  && ok_t "G1 caller seat: non-root fails closed to '-', root reads the sudo-stamped seat" \
  || bad_t "G1 caller seat" "nonroot='$G1' root='$G1R'"

echo "-----"
echo "people_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
