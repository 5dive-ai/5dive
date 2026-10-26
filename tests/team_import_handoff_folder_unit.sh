#!/usr/bin/env bash
# DIVE-6991 — a team import gives the team ONE folder every member reads and writes.
#
# THE DEFECT, from the four-team QA (DIVE-6989 B4): theo could not open bo's or
# lilbro's files, because every seat's home is its own (0750, private group). The
# team fell back to /tmp, at ~6 extra rounds and two owner messages. Text can go
# in a message; an image or a video cannot.
#
# WHAT IS PINNED. A slug import driven through the real `team import` (only the
# fetch, the recorder CLI and the OS calls are replaced): the folder is made at
# one per-team path, root:team-<key> 2770 (setgid), every member is added to the
# group AND given a named + default ACL entry (a seat already running does not
# pick up a new group until it restarts), a sandboxed member also gets traverse,
# every member's instructions name the path exactly once (a re-import adds no
# second note), `team ps` prints it, and `team leave` takes both back.
#
# COVERAGE LIMIT, said plainly: no unix user or group is made here (that needs
# root), so "bo writes, theo reads" is NOT run by this file. It was run once by
# hand against real users and the real function; see the row DIVE-6991.
#
# Run: bash tests/team_import_handoff_folder_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - team_import_handoff_folder_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
         src/lib/state.sh src/lib/audit.sh src/lib/registry.sh src/lib/tasks_db.sh \
         src/lib/actor.sh src/lib/marketplace.sh src/task/routing.sh src/cmd_compose.sh \
         src/cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$f"
done
set +e

TMP="$(mktemp -d /tmp/team-import-handoff.XXXXXX)"
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
tasks_db_init

PASS=0; FAIL=0
ok_t()  { printf 'ok   - %s\n' "$1"; PASS=$((PASS+1)); }
bad_t() { printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "expected [$2], got [$3]"; fi; }

export TEAM_AUTH_PROFILE=fixture
export TEAM_TG_TOKEN='1234567890:AAAAfake-not-a-real-bot-token'
FIX="$ROOT/tests/fixtures/team-templates"

mkdir -p "$TMP/reg/teams"
cp "$FIX/index.json" "$TMP/reg/teams/index.json"
cp "$FIX/distribution.5dive.yaml" "$TMP/reg/teams/distribution.5dive.yaml"
REG_BASE="$(_teams_registry_base)"
_teams_get() {
  local rel="${1#"$REG_BASE"/}"
  [[ -f "$TMP/reg/$rel" ]] || return 1
  cp "$TMP/reg/$rel" "$2"
}

# ---- provisioning seams ----------------------------------------------------
cat >"$TMP/fake5dive" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REC"
exit 0
SH
chmod +x "$TMP/fake5dive"
export REC="$TMP/rec.log"; : > "$REC"
_compose_self()   { printf '%s' "$TMP/fake5dive"; }
ensure_state()    { :; }
ensure_state_ro() { :; }
registry_read()   { printf '%s' '{"agents":{}}'; }
PERSONA="$TMP/persona"; mkdir -p "$PERSONA"
persona_target()       { printf '%s/%s.md' "$PERSONA" "$1"; }
persona_append_block() { printf '%s' "$3" >> "$PERSONA/$1.md"; }
sudo() { if [[ "${1:-}" == "-u" ]]; then shift 2; fi; "$@"; }

# ---- OS seams: a group table, an ACL log, one sandboxed seat ---------------
OS="$TMP/os"; mkdir -p "$OS"; : > "$OS/groups"; : > "$OS/acl"; : > "$OS/traverse"; : > "$OS/chgrp"
SANDBOXED=agent-publisher
_sp_user_exists()  { [[ "$1" == agent-* ]]; }
_sp_group_exists() { grep -q "^$1:" "$OS/groups"; }
_sp_groupadd()     { printf '%s:\n' "$1" >> "$OS/groups"; }
_sp_members()      { grep "^$1:" "$OS/groups" | cut -d: -f2 | tr ',' '\n' | sed '/^$/d'; }
_sp_member_add()   { sed -i "s/^$2:\(.*\)\$/$2:\1,$1/" "$OS/groups"; }
_sp_member_del()   { sed -i "/^$2:/s/,$1\b//" "$OS/groups"; }
_sp_file_group()   { printf 'claude'; }
_sp_chgrp()        { printf '%s %s\n' "$1" "$2" >> "$OS/chgrp"; }
setfacl()          { printf '%s\n' "$*" >> "$OS/acl"; }
plugin_root_traverse_grant() { printf '%s %s\n' "$1" "$2" >> "$OS/traverse"; }
# Every roster seat is in the box group except the sandboxed one.
printf 'claude:\n' >> "$OS/groups"

WANT="$STATE_DIR/teams/distribution/handoff"
GRP=team-distribution
ROLES="$(jq -r '.agents | keys[]' <<<"$(_compose_parse "$FIX/distribution.5dive.yaml")" | sort)"
NROLES="$(grep -c . <<<"$ROLES")"
while IFS= read -r r; do
  [[ "agent-$r" == "$SANDBOXED" ]] || _sp_member_add "agent-$r" claude
done <<<"$ROLES"

# ============ 0. PRECONDITIONS ==============================================
if [[ "$NROLES" == 7 ]] && grep -qx "publisher" <<<"$ROLES"; then
  ok_t 'H0 the distribution fixture has its seven roles, publisher among them'
else
  bad_t 'H0 precondition failed — every arm below is vacuous' "roles=$NROLES"
fi
eq_t 'H0b a long key is cut to the 32-character group cap' 32 \
     "$(_team_handoff_group "a-very-long-team-template-slug-name-here" | wc -c | tr -d ' ' | awk '{print $1-0}')"
[[ "$(_team_handoff_group "a-very-long-team-template-slug-name-here")" != "$(_team_handoff_group "a-very-long-team-template-slug-name-there")" ]] \
  && ok_t 'H0c two long keys with one prefix get two groups' || bad_t 'H0c two long keys collided into one group' ''

# ============ 1. a fresh-box import BY SLUG makes the folder ================
cmd_team import distribution >"$TMP/import.out" 2>&1
if [[ -d "$WANT" ]]; then ok_t 'H1 the team folder exists at the per-team path'
else bad_t 'H1 no team folder after a slug import' "$(tail -5 "$TMP/import.out")"; fi
eq_t 'H1b it is setgid 2770' 2770 "$(stat -c %a "$WANT" 2>/dev/null)"
eq_t 'H1c it is given to the team group' "$GRP $WANT" "$(cat "$OS/chgrp")"
grep -qF "team folder: $WANT" "$TMP/import.out" \
  && ok_t 'H1d the import output names it' || bad_t 'H1d the import output does not name the folder' "$(grep -i folder "$TMP/import.out")"
eq_t "H1e all $NROLES members are in $GRP" "$NROLES" "$(_sp_members "$GRP" | grep -c .)"
grep -qxF -- "-m d:g:${GRP}:rwx,d:m::rwx $WANT" "$OS/acl" \
  && ok_t 'H1f new files default to group rwx (no umask lock-out)' || bad_t 'H1f no default group ACL' "$(head -3 "$OS/acl")"
acl_ok=0; acl_miss=""
while IFS= read -r r; do
  if grep -qxF -- "-R -m u:agent-${r}:rwX $WANT" "$OS/acl" && grep -qxF -- "-R -d -m u:agent-${r}:rwx $WANT" "$OS/acl"; then
    acl_ok=$((acl_ok+1)); else acl_miss+=" $r"; fi
done <<<"$ROLES"
eq_t "H1g every member gets a named + default ACL entry (works without a restart)" "$NROLES" "$acl_ok"
[[ -z "$acl_miss" ]] || bad_t 'H1h members with no ACL entry' "$acl_miss"
eq_t 'H1i only the sandboxed seat is given traverse on the state dir' "$SANDBOXED $WANT" "$(cat "$OS/traverse")"

# ============ 2. every member is told the path, once ========================
named=0; missing=""
while IFS= read -r r; do
  if grep -qF "\`$WANT\`" "$PERSONA/$r.md" 2>/dev/null; then named=$((named+1)); else missing+=" $r"; fi
done <<<"$ROLES"
eq_t "H2 all $NROLES members' instructions name the team folder" "$NROLES" "$named"
[[ -z "$missing" ]] || bad_t 'H2b members with no folder line' "$missing"

: > "$REC"
cmd_team import distribution >"$TMP/reimport.out" 2>&1
eq_t 'H2c a re-import adds no second note' "$NROLES" "$(cat "$PERSONA"/*.md | grep -c '^## Team folder')"
eq_t 'H2d and adds nobody to the group twice' "$NROLES" "$(_sp_members "$GRP" | sort -u | grep -c .)"

# ============ 3. team ps shows it ===========================================
out=$(cmd_team ps distribution 2>/dev/null)
grep -qxF "FOLDER      $WANT" <<<"$out" \
  && ok_t 'H3 team ps <slug> prints the folder' || bad_t 'H3 team ps does not print the folder' "$(head -3 <<<"$out")"
JSON_MODE=1
eq_t 'H3b team ps --json carries it as .folder' "$WANT" \
     "$(cmd_team ps distribution 2>/dev/null | jq -r '.. | objects | .folder? // empty' 2>/dev/null | head -1)"
JSON_MODE=0

# ============ 4. team leave takes it back ===================================
LEAVER=$(grep -vx "$(_team_installed_lead distribution)" <<<"$ROLES" | head -1)
: > "$OS/acl"
_team_handoff_revoke distribution "$LEAVER"
_sp_is_member "agent-$LEAVER" "$GRP" && bad_t 'H4 the leaver is still in the group' "$(grep "^$GRP:" "$OS/groups")" \
  || ok_t 'H4 the leaver is out of the group'
grep -qxF -- "-R -x u:agent-${LEAVER},d:u:agent-${LEAVER} $WANT" "$OS/acl" \
  && ok_t 'H4b and his ACL entries are removed' || bad_t 'H4b his ACL entries stay' "$(cat "$OS/acl")"
grep -q 'Team folder' "$PERSONA/$LEAVER.md" && bad_t 'H4c the note is still in his instructions' '' \
  || ok_t 'H4c and the note is out of his instructions'
eq_t 'H4d the rest of the team keep theirs' "$((NROLES-1))" "$(cat "$PERSONA"/*.md | grep -c '^## Team folder')"

# ============ 5. NEGATIVE CONTROL: a bare `up` makes no folder ==============
rm -rf "$STATE_DIR/teams"
cmd_compose_up -f "$FIX/distribution.5dive.yaml" >/dev/null 2>&1
[[ ! -e "$STATE_DIR/teams/distribution/handoff" ]] \
  && ok_t 'H5 NEGATIVE CONTROL: up -f (no team) makes no team folder' || bad_t 'H5 a bare up made a team folder' ''

# ============ R1. AS ROOT ONLY: bo writes, theo reads, on real users =========
# CI's root-arms job runs this with HO_REQUIRE_ROOT_ARM=1 (a skip is then a red);
# the runner is disposable, so useradd and groupadd are safe there, and never on a
# shared box. The REAL function runs in a fresh shell (none of the seams above).
# theo's process starts BEFORE the folder exists, so it never holds the new group:
# only the ACL can let it in. bo writes under umask 077, the worst a maker can.
if [[ $EUID -ne 0 ]]; then
  if [[ "${HO_REQUIRE_ROOT_ARM:-0}" == 1 ]]; then bad_t "R1 root arm required but not root" "EUID=$EUID"
  else printf 'skip - R1 root arm (not root; CI root-arms runs it with HO_REQUIRE_ROOT_ARM=1)\n'; fi
else
  unset -f sudo setfacl
  RB=agent-ho6991bo; RT=agent-ho6991theo; RBOX=ho6991box; RKEY=ho6991team
  trap 'rc=$?; pkill -KILL -u '"$RT"' 2>/dev/null; userdel '"$RB"' 2>/dev/null; userdel '"$RT"' 2>/dev/null; groupdel '"$RBOX"' 2>/dev/null; groupdel team-'"$RKEY"' 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
  chmod o+x "$TMP"
  groupadd "$RBOX" && useradd -M -s /bin/bash -G "$RBOX" "$RB" && useradd -M -s /bin/bash "$RT"
  RS="$TMP/rstate"; mkdir -p "$RS"; chgrp "$RBOX" "$RS"; chmod 2750 "$RS"
  RDIR="$RS/teams/$RKEY/handoff"
  mkdir -p "$TMP/to"; chown "$RT" "$TMP/to"   # theo's own output, outside the folder
  # theo, already running: waits for bo's file, reads it, then adds a line.
  sudo -u "$RT" bash -c 'for i in $(seq 100); do [[ -e "$1" ]] && break; sleep 0.1; done
                         sleep 0.2; cat "$1" > "$2.read" 2>"$2.err"; echo "theo was here" >> "$1" 2>>"$2.err"; echo $? > "$2.rc"' \
    _ "$RDIR/bo.png" "$TMP/to/theo" 2>/dev/null &
  sleep 0.3
  got=$(env -i PATH="$PATH" STATE_DIR="$RS" bash -c '
          for f in src/lib/error_codes.sh src/lib/output.sh src/header.sh src/lib/validation.sh \
                   src/lib/plugin_seats.sh src/cmd_compose.sh; do source "$f"; done; set +e
          _team_handoff_ensure "$1" "$2" "$3"' _ "$RKEY" "${RB#agent-}" "${RT#agent-}" 2>"$TMP/ensure.err")
  eq_t 'R1 the real function makes the folder and prints its path' "$RDIR" "$got"
  sudo -u "$RB" bash -c 'umask 077; printf "PNG-bytes" > "$1"' _ "$RDIR/bo.png"; brc=$?
  eq_t 'R1b bo writes a file there (umask 077)' 0 "$brc"
  wait
  eq_t 'R1c theo, running since before the grant, reads it without a permission error' "PNG-bytes" "$(cat "$TMP/to/theo.read" 2>/dev/null)"
  eq_t 'R1d and can write to it too' 0 "$(cat "$TMP/to/theo.rc" 2>/dev/null)"
  eq_t 'R1e the file belongs to the team group (setgid)' "team-$RKEY" "$(stat -c %G "$RDIR/bo.png" 2>/dev/null)"
  eq_t 'R1f nothing on stderr from theo' '' "$(cat "$TMP/to/theo.err" 2>/dev/null)"
  id -nG "$RT" | grep -qw "team-$RKEY" && ok_t 'R1g both are in the team group for their next start' \
    || bad_t 'R1g theo is not in the team group' "$(id -nG "$RT")"
  [[ -s "$TMP/ensure.err" ]] && bad_t 'R1h ensure warned' "$(cat "$TMP/ensure.err")" || ok_t 'R1h ensure ran with no warning'
fi

SUMMARY_PRINTED=1
printf '\n%s\n' "team_import_handoff_folder_unit: pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
