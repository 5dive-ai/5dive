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

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-home-teardown-unit.XXXXXX)"

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

# ---------------------------------------------------------------------------
# DIVE-4340: the user half of the teardown, when it does NOT succeed.
#
# `deluser` used to run as `deluser ... 2>/dev/null || true`, so a teardown that
# could not delete the account was indistinguishable from one that did — and the
# caller dropped the registry row either way, which is how 8 accounts on
# exact-swallow ended up on a box with no command able to reach them. The
# verdict must be "is the account still there afterwards", not deluser's rc.
# ---------------------------------------------------------------------------
DELUSER_RC=0
id()      { if [[ "${1:-}" == "-u" ]]; then [[ "${2:-}" == "agent-zombie" ]] && { echo 4242; return 0; }; return 1; fi; command id "$@"; }
getent()  { [[ "${1:-}" == passwd ]] && { printf 'agent-zombie:x:4242:4242::%s/agent-zombie:/bin/bash\n' "$AGENT_HOME_ROOT"; return 0; }; return 1; }
deluser() { printf 'deluser: /usr/sbin/deluser must be run as root\n' >&2; return "$DELUSER_RC"; }
setfacl() { return 0; }
capability_forget_agent() { return 0; }
AUDITED=""
audit_log() { AUDITED="$*"; return 0; }

# A deluser that fails and leaves the account behind.
DELUSER_RC=1
mkdir -p "$AGENT_HOME_ROOT/agent-zombie"
_RM_USER_DISPOSITION=""
# Run it in THIS shell: a command substitution would take the disposition and
# the audit row into a subshell, and the assertions below would read neither.
delete_agent_user zombie >/dev/null 2>"$TMP/zombie.err"
err=$(cat "$TMP/zombie.err")
[[ "$_RM_USER_DISPOSITION" == "present" ]] \
  && ok_t "a surviving account is reported as user disposition 'present'" \
  || bad_t "a surviving account is reported as 'present'" "disposition='$_RM_USER_DISPOSITION'"
grep -qi "SURVIVED" <<<"$err" \
  && ok_t "the survivor is loud on stderr, not swallowed" \
  || bad_t "the survivor is loud on stderr" "$err"
grep -qi "group" <<<"$err" \
  && ok_t "the warning names the credential group the account still belongs to" \
  || bad_t "the warning names the credential group" "$err"
grep -q "doctor" <<<"$err" \
  && ok_t "the warning names the command that can still reap it" \
  || bad_t "the warning names the reap path" "$err"
[[ "$AUDITED" == *os-teardown-incomplete* && "$AUDITED" == *agent-zombie* ]] \
  && ok_t "the reason the teardown could not finish is written to the audit log" \
  || bad_t "the reason is written to the audit log" "audited='$AUDITED'"

# The same code path when the account really is gone: no warning, no audit row.
id() { if [[ "${1:-}" == "-u" ]]; then return 1; fi; command id "$@"; }
AUDITED=""; _RM_USER_DISPOSITION=""
delete_agent_user zombie >/dev/null 2>"$TMP/zombie2.err"
[[ "$_RM_USER_DISPOSITION" == "absent" && -z "$AUDITED" ]] \
  && ok_t "an account that is already gone is 'absent' and writes no audit row" \
  || bad_t "an already-gone account is 'absent'" "disposition='$_RM_USER_DISPOSITION' audited='$AUDITED'"

# ---------------------------------------------------------------------------
# DIVE-4340 iteration 2 — NO PASSWD ENTRY IS NOT NOTHING LEFT TO DO.
#
# `deluser` drops a user from every group, so the account and its membership in
# the shared credential group normally die together. They come apart in exactly
# the cases this row exists for: a half-run teardown, a hand-edited group file,
# a removal that was not `agent rm`. Iteration 1 returned at the `id -u` guard
# for such a name, left the membership standing, and let doctor --fix report the
# seat reaped. The membership is the more dangerous half — that group is what
# this box scopes its shared credentials to.
# ---------------------------------------------------------------------------
export AGENT_SHARED_GROUP="fivedive-test"
# The membership list lives in a FILE, not a variable: the code under test runs
# gpasswd inside a command substitution (it keeps the tool's own words for the
# audit row), so a stub that mutated a shell variable would lose the mutation to
# the subshell and the harness would grade its own seam instead of the product.
GROUP_FILE="$TMP/group.members"
GPASSWD_WORKS=1
set_members() { printf '%s' "$1" >"$GROUP_FILE"; }
get_members() { cat "$GROUP_FILE" 2>/dev/null; }
getent() {
  if [[ "${1:-}" == "group" ]]; then
    printf '%s:x:9999:%s\n' "$2" "$(get_members)"; return 0
  fi
  return 2   # no passwd entry for anyone in this block
}
gpasswd() {   # gpasswd -d <user> <group>
  (( GPASSWD_WORKS )) || { printf 'gpasswd: Permission denied.\n' >&2; return 1; }
  local u="$2" out="" m; local -a _m=()
  IFS=',' read -ra _m <<<"$(get_members)"
  for m in "${_m[@]}"; do [[ "$m" == "$u" ]] && continue; out+="${out:+,}$m"; done
  set_members "$out"; return 0
}

set_members "agent-ghost,agent-ceo"
AUDITED=""; _RM_GROUP_DISPOSITION=""
delete_agent_user ghost >/dev/null 2>"$TMP/ghost.err"
[[ "$_RM_GROUP_DISPOSITION" == "dropped" && ",$(get_members)," != *,agent-ghost,* ]] \
  && ok_t "a name with NO passwd entry still has its credential-group membership dropped" \
  || bad_t "group membership dropped for a passwd-less name" "disp='$_RM_GROUP_DISPOSITION' members='$(get_members)'"
[[ -z "$AUDITED" ]] \
  && ok_t "a successful group drop writes no teardown-failure audit row" \
  || bad_t "a successful group drop is silent" "audited='$AUDITED'"

# A refused drop (the non-root box) must be LOUD and audited, never silent.
set_members "agent-ghost,agent-ceo"; GPASSWD_WORKS=0
AUDITED=""; _RM_GROUP_DISPOSITION=""
delete_agent_user ghost >/dev/null 2>"$TMP/ghost2.err"
err=$(cat "$TMP/ghost2.err")
[[ "$_RM_GROUP_DISPOSITION" == "present" ]] \
  && ok_t "a membership that survives the drop is reported as 'present'" \
  || bad_t "a surviving membership is 'present'" "disp='$_RM_GROUP_DISPOSITION'"
grep -qi "STILL a member" <<<"$err" && grep -q "fivedive-test" <<<"$err" \
  && ok_t "the surviving membership is loud on stderr and names the group" \
  || bad_t "the surviving membership is loud and names the group" "$err"
[[ "$AUDITED" == *os-teardown-incomplete* && "$AUDITED" == *agent-ghost* ]] \
  && ok_t "a membership that could not be dropped is written to the audit log" \
  || bad_t "the surviving membership is audited" "audited='$AUDITED'"

# Negative control: a name that was never in the group does nothing at all —
# this check must not fire on every clean removal.
set_members "agent-ceo"; GPASSWD_WORKS=1
AUDITED=""; _RM_GROUP_DISPOSITION=""
delete_agent_user nosuch >/dev/null 2>"$TMP/ghost3.err"
[[ "$_RM_GROUP_DISPOSITION" == "absent" && -z "$AUDITED" && ! -s "$TMP/ghost3.err" ]] \
  && ok_t "a name that was never a group member is 'absent', silent, unaudited" \
  || bad_t "a non-member is silent" "disp='$_RM_GROUP_DISPOSITION' audited='$AUDITED' err='$(cat "$TMP/ghost3.err")'"

unset -f gpasswd
unset -f id getent deluser setfacl capability_forget_agent audit_log

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
