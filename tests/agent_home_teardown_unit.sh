#!/usr/bin/env bash
# DIVE-2138 (gh#222, A-MO7SEN) isolated unit for agent-home teardown completeness.
# No root, no systemd, no network — drives the two halves against a temp
# AGENT_HOME_ROOT so nothing under the real /home is ever touched.
#
# The bug: `agent rm` deleted the user but LEFT /home/agent-<name> behind, and
# adduser RECYCLES freed uids — so the next agent created inherited a dead
# agent's uid and with it ownership of the dead agent's home, auth.json /
# credentials.toml / channel .env included. Recreating a previously-used name
# then failed PARTWAY, AFTER the agent was already registered in agents.json.
#
# Asserts:
#   rm side      - the home is moved into REAPED_DIR, root-only 0700
#   rm side      - contents survive the move (quarantine, not delete)
#   rm side      - --purge-home deletes instead, on request only
#   rm side      - a home that is NOT the conventional path is left untouched
#   rm side      - a failed disposition is reported, not swallowed
#   create side  - a leftover home owned by someone else is REFUSED
#   create side  - an absent home, and a home the user already owns, are fine
#   create side  - the refusal is ordered before the registry write
# Run: bash tests/agent_home_teardown_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-home-teardown-unit.XXXXXX)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

export AGENT_HOME_ROOT="$TMP/home"
export REAPED_DIR="$AGENT_HOME_ROOT/.5dive-reaped"
mkdir -p "$AGENT_HOME_ROOT"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
JSON_MODE=0
set +e
# cmd_agent_create.sh is sourced for the two functions under test. Its top-level
# `readonly`/assoc-array setup is inert without a command dispatch.
# shellcheck disable=SC1090
source "$SRC/cmd_agent_create.sh"

# The seam values must survive sourcing (the src file defaults them).
[[ "$AGENT_HOME_ROOT" == "$TMP/home" ]] || { echo "BUG: harness lost AGENT_HOME_ROOT"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- test seams --------------------------------------------------------------
# Root-only teardown steps we neither can nor need to perform here. Each is a
# no-op that returns success, so the code under test proceeds exactly as it
# would on a real box; the FILESYSTEM effects are what we assert on.
setfacl()  { :; }
deluser()  { :; }
chown()    { :; }   # rootless: cannot chown, and it is not what we assert
usermod()  { :; }
# `id -u agent-<n>` must answer per-fixture, not per-CI-runner. Everything else
# delegates, so nothing else in the sourced libs changes behaviour.
declare -A FAKE_UID=()
id() {
  if [[ "${1:-}" == "-u" && -n "${2:-}" ]]; then
    if [[ -n "${FAKE_UID[$2]:-}" ]]; then printf '%s\n' "${FAKE_UID[$2]}"; return 0; fi
    return 1   # "no such user"
  fi
  command id "$@"
}
# getent is only consulted for the home path; answer from the fixture table.
declare -A FAKE_HOME=()
getent() {
  if [[ "${1:-}" == "passwd" && -n "${FAKE_HOME[${2:-}]:-}" ]]; then
    printf '%s:x:0:0::%s:/bin/bash\n' "$2" "${FAKE_HOME[$2]}"
    return 0
  fi
  return 2
}
# `fail` exits; trap it so assertions can observe the refusal instead of dying.
FAIL_MSG=""; FAIL_CODE=""
fail() { FAIL_CODE="$1"; shift; FAIL_MSG="$*"; return 97; }

seed_home() {   # seed_home <name> -> a populated home with a credential in it
  local h="$AGENT_HOME_ROOT/agent-$1"
  mkdir -p "$h/.codex"
  printf '{"token":"placeholder"}\n' > "$h/.codex/auth.json"
  printf 'work\n' > "$h/notes.txt"
  printf '%s' "$h"
}

# =============================================================================
# rm side
# =============================================================================

# 1+2. default = quarantine, contents preserved
h=$(seed_home kimi); FAKE_UID[agent-kimi]=1006; FAKE_HOME[agent-kimi]="$h"
delete_agent_user kimi >/dev/null 2>&1
[[ ! -e "$h" ]] \
  && ok_t "agent rm removes the home from its original path (the leak)" \
  || bad_t "home survived at its original path" "$h still exists"
q="${_RM_HOME_DISPOSITION#quarantined:}"
[[ "$_RM_HOME_DISPOSITION" == quarantined:* && -d "$q" ]] \
  && ok_t "the home is quarantined under REAPED_DIR, and the path is reported" \
  || bad_t "no quarantine path reported" "disposition=$_RM_HOME_DISPOSITION"
[[ -s "$q/.codex/auth.json" && -s "$q/notes.txt" ]] \
  && ok_t "quarantine PRESERVES contents (it is a move, not a delete)" \
  || bad_t "contents lost in the move" "$(ls -R "$q" 2>&1 | head)"

# 3. root-only perms: a recycled uid must not be able to read what it inherits.
#    (chown is stubbed out rootless; the MODE is the half we can assert, and it
#    is the half that stops traversal by a non-owner in either case.)
mode=$(stat -c '%a' "$q" 2>/dev/null)
[[ "$mode" == "700" ]] \
  && ok_t "quarantined home is 0700 (unreadable by a recycled uid)" \
  || bad_t "quarantined home is not 0700" "mode=$mode"
rmode=$(stat -c '%a' "$REAPED_DIR" 2>/dev/null)
[[ "$rmode" == "700" ]] \
  && ok_t "REAPED_DIR itself is 0700" \
  || bad_t "REAPED_DIR is not 0700" "mode=$rmode"

# 4. --purge-home deletes, and ONLY on request
h=$(seed_home devin); FAKE_UID[agent-devin]=1007; FAKE_HOME[agent-devin]="$h"
delete_agent_user devin 1 >/dev/null 2>&1
[[ ! -e "$h" && "$_RM_HOME_DISPOSITION" == "purged" ]] \
  && ok_t "--purge-home deletes the home outright" \
  || bad_t "--purge-home did not purge" "exists=$([[ -e $h ]] && echo y || echo n) disp=$_RM_HOME_DISPOSITION"
# and the quarantine path was NOT used for the purged agent
[[ -z "$(find "$REAPED_DIR" -maxdepth 1 -name 'devin-*' 2>/dev/null)" ]] \
  && ok_t "--purge-home does not also leave a quarantine copy" \
  || bad_t "purge left a quarantined copy behind" "$(ls "$REAPED_DIR")"

# 5. a home that is NOT the conventional path is left ALONE (guard against the
#    recursive chown / rm -rf ever pointing at /home/claude, /, or a symlink)
custom="$TMP/elsewhere/notahome"
mkdir -p "$custom"; printf 'keep\n' > "$custom/keep.txt"
FAKE_UID[agent-odd]=1008; FAKE_HOME[agent-odd]="$custom"
delete_agent_user odd >/dev/null 2>&1
[[ -s "$custom/keep.txt" && "$_RM_HOME_DISPOSITION" == "left-in-place" ]] \
  && ok_t "a non-conventional home is left untouched and reported" \
  || bad_t "guard did not hold for a non-conventional home" "disp=$_RM_HOME_DISPOSITION exists=$([[ -e $custom/keep.txt ]] && echo y || echo n)"

# 5b. a SYMLINK at the conventional path is refused too (mv would move the link,
#     a recursive chown would follow it)
ln -s "$TMP/elsewhere" "$AGENT_HOME_ROOT/agent-linky"
FAKE_UID[agent-linky]=1009; FAKE_HOME[agent-linky]="$AGENT_HOME_ROOT/agent-linky"
delete_agent_user linky >/dev/null 2>&1
[[ -L "$AGENT_HOME_ROOT/agent-linky" && "$_RM_HOME_DISPOSITION" == "left-in-place" ]] \
  && ok_t "a symlinked home is refused, not followed" \
  || bad_t "symlink guard did not hold" "disp=$_RM_HOME_DISPOSITION"

# 6. a FAILED disposition is reported, never silently swallowed. Make the move
#    impossible by making REAPED_DIR's parent unwritable for a moment.
h=$(seed_home stuck); FAKE_UID[agent-stuck]=1010; FAKE_HOME[agent-stuck]="$h"
rm -rf "$REAPED_DIR"
chmod 0500 "$AGENT_HOME_ROOT"
delete_agent_user stuck >/dev/null 2>&1
disp_failed="$_RM_HOME_DISPOSITION"
chmod 0755 "$AGENT_HOME_ROOT"
if [[ "$(command id -u)" == "0" ]]; then
  printf 'skip - failed-disposition arm (running as root: 0500 does not deny root)\n'
else
  [[ "$disp_failed" == "failed" && -d "$h" ]] \
    && ok_t "a home that could NOT be moved reports 'failed' and stays put" \
    || bad_t "failed move not reported" "disp=$disp_failed exists=$([[ -d $h ]] && echo y || echo n)"
fi

# 7. no user at all => nothing to do, and nothing claimed
_RM_HOME_DISPOSITION="sentinel"
delete_agent_user ghost >/dev/null 2>&1
[[ "$_RM_HOME_DISPOSITION" == "absent" ]] \
  && ok_t "removing a non-existent user reports 'absent', not a stale value" \
  || bad_t "disposition not reset for an absent user" "disp=$_RM_HOME_DISPOSITION"

# =============================================================================
# create side
# =============================================================================

# 8. THE REFUSAL: home exists, owned by a uid that is not this agent's user.
#    This is A-MO7SEN's box state (/home/agent-kimi owned by agent-builder).
mkdir -p "$AGENT_HOME_ROOT/agent-kimi"
FAIL_MSG=""; FAIL_CODE=""
unset 'FAKE_UID[agent-kimi]'          # the name no longer resolves (removed)
agent_home_conflict_check kimi >/dev/null 2>&1
[[ "$FAIL_CODE" == "$E_CONFLICT" ]] \
  && ok_t "create REFUSES a leftover home not owned by the new agent's user" \
  || bad_t "create did not refuse a leftover home" "code=$FAIL_CODE msg=$FAIL_MSG"
# The message must name the uid: on the reported box the owner did not resolve
# to a name at all (uid 1006, no such user), so a name-only message says nothing.
[[ "$FAIL_MSG" == *"uid "* && "$FAIL_MSG" == *"$AGENT_HOME_ROOT/agent-kimi"* ]] \
  && ok_t "the refusal names the offending path AND the owning uid" \
  || bad_t "refusal message is not actionable" "msg=$FAIL_MSG"

# 9. no home at all => silent pass (the ordinary create)
FAIL_MSG=""; FAIL_CODE=""
agent_home_conflict_check brandnew >/dev/null 2>&1
[[ -z "$FAIL_CODE" ]] \
  && ok_t "a create with no existing home is not blocked" \
  || bad_t "blocked a clean create" "code=$FAIL_CODE msg=$FAIL_MSG"

# 10. home exists AND the user already owns it => re-provision, not a leftover
mkdir -p "$AGENT_HOME_ROOT/agent-mine"
FAKE_UID[agent-mine]=$(stat -c '%u' "$AGENT_HOME_ROOT/agent-mine")
FAIL_MSG=""; FAIL_CODE=""
agent_home_conflict_check mine >/dev/null 2>&1
[[ -z "$FAIL_CODE" ]] \
  && ok_t "a home already owned by the agent's own user is not a conflict" \
  || bad_t "blocked a legitimate re-provision" "code=$FAIL_CODE msg=$FAIL_MSG"

# 11. existing user, home owned by someone ELSE (the half-created shape) => refuse
mkdir -p "$AGENT_HOME_ROOT/agent-half"
FAKE_UID[agent-half]=999999   # user resolves, but does not own the directory
FAIL_MSG=""; FAIL_CODE=""
agent_home_conflict_check half >/dev/null 2>&1
[[ "$FAIL_CODE" == "$E_CONFLICT" ]] \
  && ok_t "an existing user whose home belongs to another uid is refused" \
  || bad_t "half-created shape was allowed through" "code=$FAIL_CODE"

# 12. ORDERING (structural, and labelled as such): the reported bug is not that
#     create failed — it is that it failed AFTER registering the agent. Assert
#     the check is invoked before the registry write and before the user is made.
#     Read from source: the property is about call ORDER in cmd_create, which no
#     single-function invocation can observe.
ln_chk=$(grep -n '^  agent_home_conflict_check "\$name"' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
ln_reg=$(grep -n 'registry_write' "$SRC/cmd_agent_create.sh" | awk -F: '$1 > 0 {print $1}' | tail -1)
ln_usr=$(grep -n '^  create_agent_user "\$name"' "$SRC/cmd_agent_create.sh" | head -1 | cut -d: -f1)
if [[ -n "$ln_chk" && -n "$ln_reg" && -n "$ln_usr" ]]; then
  (( ln_chk < ln_usr && ln_chk < ln_reg )) \
    && ok_t "cmd_create runs the home check BEFORE create_agent_user and the registry write" \
    || bad_t "home check is not ordered first" "check=$ln_chk user=$ln_usr registry=$ln_reg"
else
  bad_t "could not locate the ordering anchors in cmd_create" \
        "check=$ln_chk user=$ln_usr registry=$ln_reg (did a call site get renamed?)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
