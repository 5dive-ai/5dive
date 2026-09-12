#!/usr/bin/env bash
# DIVE-4340 — the converse of doctor's registry check: an OS seat with no
# registry entry.
#
# The bug: on exact-swallow 4 live seats coexisted with 12 `agent-*` users. The
# 8 orphans each kept their home AND their membership in the credential-scoping
# group, plus one unit that had been `failed` for three days — and doctor was
# green, because it only ever asked "does this registry entry have a user?".
# Worse, with the registry row already gone, `agent rm` refuses the name, so
# nothing on the box could reap them.
#
# Asserts:
#   - a box whose OS seats all have registry entries is ok
#   - an unreadable registry is UNKNOWN, never a clean bill of health
#   - an orphan account is named, and group membership makes it an ERROR
#   - an orphan that is only a stale unit is a warn, still named
#   - a live seat is never reported as an orphan
#   - --fix runs the same teardown the supported removal path runs, per orphan
#   - a --fix that could not delete the account reports error + repaired:false
#   - the marketplace enumeration grades registry seats, not /home directories
# Run: bash tests/doctor_orphan_seats_unit.sh (no root, no systemd, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/doctor-orphan-seats.XXXXXX)"
export AGENT_SHARED_GROUP="fivedive-test"
export ENV_DIR="$TMP/env"; mkdir -p "$ENV_DIR"

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_doctor.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- seams -------------------------------------------------------------------
# The three sources the check reads, and the registry it grades them against.
REG_JSON='{"agents":{"ceo":{},"devops":{}}}'
PASSWD_LINES=""; GROUP_LINES=""; UNIT_LINES=""
registry_read()             { [[ "$REG_JSON" == "UNREADABLE" ]] && return 1; printf '%s' "$REG_JSON"; }
doctor_orphan_passwd_users(){ printf '%s' "$PASSWD_LINES"; }
doctor_orphan_group_members(){ printf '%s' "$GROUP_LINES"; }
doctor_orphan_units()       { printf '%s' "$UNIT_LINES"; }
# A --fix must not touch the real box: stand in for the teardown and record it.
# NOTE: run_check is called in a command substitution, so the stub records to a
# FILE — an assignment inside that subshell would never reach these assertions.
REAP_LOG="$TMP/reaped"; : >"$REAP_LOG"; REAP_REFUSE=""; REAP_LEAVE_GROUP=""; REAP_LEAVE_UNIT=""
# ITERATION 2. The stubs MUTATE the three sources, because the verdict under
# test is now a RE-READ of those sources rather than a probe of `id -u`. A stub
# that only logged the call could not tell a reap from a no-op, which is
# precisely how iteration 1 shipped a green `repaired=true` over a survivor.
#   REAP_REFUSE      — teardown does nothing at all (non-root box)
#   REAP_LEAVE_GROUP — account deleted, credential-group membership left behind
#                      (the survivor `id -u` is structurally unable to see)
#   REAP_LEAVE_UNIT  — systemctl refused; the unit stays listed
_drop_matching() {  # <source-var> <glob>
  local var="$1" pat="$2" out="" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # shellcheck disable=SC2053
    [[ "$line" == $pat ]] && continue
    out+="${out:+$'\n'}$line"
  done <<<"${!var}"
  printf -v "$var" '%s' "$out"
}
systemctl() {
  local a nm=""
  for a in "$@"; do
    if [[ "$a" == 5dive-agent@*.service ]]; then nm="${a#5dive-agent@}"; nm="${nm%.service}"; fi
  done
  [[ -n "$nm" ]] || return 0
  if [[ "$nm" == "$REAP_REFUSE" || "$nm" == "$REAP_LEAVE_UNIT" ]]; then return 1; fi
  _drop_matching UNIT_LINES "5dive-agent@${nm}.service *"
  return 0
}
delete_agent_user() {
  local nm="$1"
  printf '%s\n' "$nm" >>"$REAP_LOG"
  [[ "$nm" == "$REAP_REFUSE" ]] && return 1
  _drop_matching PASSWD_LINES "agent-${nm}:*"
  [[ "$nm" == "$REAP_LEAVE_GROUP" ]] || _drop_matching GROUP_LINES "agent-${nm}"
  return 0
}
# Restore a fixture after a --fix has consumed it.
set_sources() { PASSWD_LINES="$1"; GROUP_LINES="$2"; UNIT_LINES="$3"; }

run_check() {
  DOCTOR_CHECKS='[]'
  doctor_check_orphan_seats "${1:-0}" >/dev/null 2>&1
  jq -c '.[] | select(.name == "orphan-seats")' <<<"$DOCTOR_CHECKS"
}

assert_row() {
  local label="$1" severity="$2" rx="$3" row
  row=$(run_check "${4:-0}")
  if jq -e --arg s "$severity" --arg rx "$rx" \
      '.category == "registry" and .severity == $s and (.message | test($rx))' \
      <<<"$row" >/dev/null; then ok_t "$label"; else bad_t "$label" "$row"; fi
}

# 1. Clean box: every OS seat is a registry seat.
PASSWD_LINES=$'agent-ceo:/home/agent-ceo\nagent-devops:/home/agent-devops'
GROUP_LINES=$'agent-ceo\nagent-devops'
UNIT_LINES=$'5dive-agent@ceo.service running'
assert_row "a box whose OS seats all have registry entries is ok" ok "no orphan agent"

# 2. Unreadable registry is UNKNOWN — an absence of complaint is not evidence.
REG_JSON="UNREADABLE"
assert_row "an unreadable registry is UNKNOWN, not clean" warn "UNKNOWN.*unreadable"
REG_JSON='{"agents":{"ceo":{},"devops":{}}}'

# 3. The reported shape: orphan accounts still in the credential group.
CRIS_HOME="$TMP/homes/agent-cris"; mkdir -p "$CRIS_HOME"
PASSWD_LINES=$'agent-ceo:/home/agent-ceo\nagent-cris:'"$CRIS_HOME"$'\nagent-mp:/home/agent-mp'
GROUP_LINES=$'agent-ceo\nagent-cris\nagent-mp'
UNIT_LINES=$'5dive-agent@codex-ivy.service failed'
assert_row "orphan accounts in the credential group are an ERROR and are named" error \
  "cris.*mp"
# The home is the half of the finding an operator can act on. Iteration 1
# collected it and never printed it (shellcheck SC2034 called it dead code).
assert_row "the orphan's home directory is named in the message" error \
  "home $CRIS_HOME"
row=$(run_check)
jq -e '.message | test("3 agent")' <<<"$row" >/dev/null \
  && ok_t "all three orphans are counted (two accounts + one unit-only)" \
  || bad_t "all three orphans are counted" "$row"
jq -e '.message | test("group " + env.AGENT_SHARED_GROUP)' <<<"$row" >/dev/null \
  && ok_t "the credential group is named in the message" \
  || bad_t "the credential group is named" "$row"
jq -e '.message | test("ceo") | not' <<<"$row" >/dev/null \
  && ok_t "a live seat is never reported as an orphan" \
  || bad_t "a live seat is never reported as an orphan" "$row"
jq -e '.fixable == true and .repaired == false' <<<"$row" >/dev/null \
  && ok_t "the row is fixable and not yet repaired" \
  || bad_t "the row is fixable and not yet repaired" "$row"

# 4. A lingering unit alone is untidy, not a credential problem: warn, still named.
PASSWD_LINES=$'agent-ceo:/home/agent-ceo'
GROUP_LINES=$'agent-ceo'
UNIT_LINES=$'5dive-agent@codex-ivy.service failed'
assert_row "a stale unit with no account is a named warn" warn "codex-ivy.*unit:failed"

# 5. --fix reaps every orphan through the supported teardown, and says so.
FIX_FIXTURE=($'agent-cris:/home/agent-cris\nagent-mp:/home/agent-mp' 'agent-cris' '')
set_sources "${FIX_FIXTURE[@]}"
REAP_REFUSE=""; : >"$REAP_LOG"
row=$(run_check 1)
jq -e '.severity == "ok" and .repaired == true and (.message | test("reaped 2 orphan"))' <<<"$row" >/dev/null \
  && ok_t "--fix reports the reap as repaired" || bad_t "--fix reports the reap as repaired" "$row"
grep -qx cris "$REAP_LOG" && grep -qx mp "$REAP_LOG" \
  && ok_t "--fix ran the teardown for each orphan (cris, mp)" \
  || bad_t "--fix ran the teardown for each orphan" "reaped='$(tr '\n' ' ' <"$REAP_LOG")'"
jq -e '.message | test("quarantin")' <<<"$row" >/dev/null \
  && ok_t "--fix quarantines homes rather than claiming a delete" \
  || bad_t "--fix quarantines homes" "$row"

# 6. A --fix that cannot finish is an error with repaired:false — never a green
#    row over a survivor, which is the whole failure this task exists for.
set_sources "${FIX_FIXTURE[@]}"
REAP_REFUSE="mp"
row=$(run_check 1)
jq -e '.severity == "error" and .repaired == false and (.message | test("could not reap 1 of 2")) and (.message | test("mp"))' <<<"$row" >/dev/null \
  && ok_t "an account that survives --fix keeps the row red" \
  || bad_t "an account that survives --fix keeps the row red" "$row"
REAP_REFUSE=""

# 6b. THE ITERATION-1 DEFECT, graded directly. The teardown deletes the passwd
#     entry and leaves the credential-group membership behind. `id -u` reports
#     the seat gone; the group source still lists it. Iteration 1 asked `id -u`
#     and printed "ok / repaired=true — accounts deleted (group membership with
#     them)". The re-read is the only thing that can see this.
set_sources "${FIX_FIXTURE[@]}"
REAP_LEAVE_GROUP="cris"
row=$(run_check 1)
jq -e '.severity == "error" and .repaired == false and (.message | test("cris"))' <<<"$row" >/dev/null \
  && ok_t "a survivor id -u cannot see (group membership only) keeps the row red" \
  || bad_t "a group-only survivor keeps the row red" "$row"
jq -e '.message | test("group " + env.AGENT_SHARED_GROUP)' <<<"$row" >/dev/null \
  && ok_t "the surviving membership names the credential group, not a generic failure" \
  || bad_t "the surviving membership names the credential group" "$row"
REAP_LEAVE_GROUP=""

# 6c. GROUP-ONLY orphan, whole-loop: no passwd entry at all, so the teardown's
#     own `id -u` guard is the thing that must not decide the verdict.
set_sources '' 'agent-ghost' ''
REAP_LEAVE_GROUP="ghost"
row=$(run_check 1)
jq -e '.severity == "error" and .repaired == false and (.message | test("ghost"))' <<<"$row" >/dev/null \
  && ok_t "a group-only orphan whose membership survives --fix is error, not a green reap" \
  || bad_t "a group-only orphan that survives --fix is error" "$row"
REAP_LEAVE_GROUP=""
set_sources '' 'agent-ghost' ''
row=$(run_check 1)
jq -e '.severity == "ok" and .repaired == true' <<<"$row" >/dev/null \
  && ok_t "a group-only orphan whose membership IS dropped reports repaired" \
  || bad_t "a group-only orphan that is really reaped reports repaired" "$row"

# 6d. UNIT-ONLY orphan — codex-ivy's shape, this row's own evidence
#     (5dive-agent@codex-ivy.service, failed since 2026-09-08). A refused
#     systemctl left the unit exactly where it was while --fix said
#     "units cleared".
set_sources '' '' $'5dive-agent@codex-ivy.service failed'
REAP_LEAVE_UNIT="codex-ivy"
row=$(run_check 1)
jq -e '.severity == "error" and .repaired == false and (.message | test("codex-ivy"))' <<<"$row" >/dev/null \
  && ok_t "a unit that survives --fix is error, never a green 'units cleared'" \
  || bad_t "a surviving unit keeps the row red" "$row"
REAP_LEAVE_UNIT=""
set_sources '' '' $'5dive-agent@codex-ivy.service failed'
row=$(run_check 1)
jq -e '.severity == "ok" and .repaired == true and (.message | test("re-read"))' <<<"$row" >/dev/null \
  && ok_t "a unit that IS cleared reports repaired, and says the verdict is a re-read" \
  || bad_t "a cleared unit reports repaired" "$row"
set_sources $'agent-ceo:/home/agent-ceo' 'agent-ceo' ''

# 7. The marketplace enumeration grades registry seats, not /home directories.
HOMES="$TMP/homes"
mkdir -p "$HOMES/agent-ceo/.claude/plugins/marketplaces/5dive-plugins" \
         "$HOMES/agent-ghost/.claude/plugins/marketplaces/5dive-plugins"
DOCTOR_CHECKS='[]'
REF=0000000000000000000000000000000000000000
doctor_check_marketplace_clones "$HOMES" "$REF" ".claude/plugins/marketplaces/5dive-plugins" "ceo devops" >/dev/null 2>&1
row=$(jq -c '.[] | select(.name == "marketplace-freshness")' <<<"$DOCTOR_CHECKS")
# Assert the LABEL, not the bare name: `agent-ghost` also appears in the
# UNKNOWN bucket on origin/main, so test("agent-ghost") passed there for the
# wrong reason and would keep passing with the filter deleted.
jq -e '.message | test("not a live seat[^|]*agent-ghost")' <<<"$row" >/dev/null \
  && ok_t "an orphan home is named as not-a-live-seat, not counted as a stale clone" \
  || bad_t "an orphan home is named as not-a-live-seat" "$row"
jq -e '.message | test("of 1 ")' <<<"$row" >/dev/null \
  && ok_t "only the registry-backed home is counted in the total" \
  || bad_t "only the registry-backed home is counted in the total" "$row"
DOCTOR_CHECKS='[]'
doctor_check_marketplace_clones "$HOMES" "$REF" ".claude/plugins/marketplaces/5dive-plugins" >/dev/null 2>&1
jq -e '.[0].message | test("of 2 ") and (test("not a live seat") | not)' <<<"$DOCTOR_CHECKS" >/dev/null \
  && ok_t "an empty seat list means do-not-filter (old behaviour preserved)" \
  || bad_t "an empty seat list means do-not-filter" "$(jq -c '.[0]' <<<"$DOCTOR_CHECKS")"

echo
echo "doctor_orphan_seats_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
