#!/usr/bin/env bash
# The machine-account rail is reported AVAILABLE only when its credential is there.
#
# THE DEFECT. `_gate_gh_bot_ok` asks `sudo -n -l /usr/local/bin/5dive _gh_do` — may this
# seat ROUTE through the root-only helper — and its own header says "No network, no token,
# no side effect." Callers printed that PERMISSION answer as AVAILABILITY. Measured
# 2026-09-18 on a box where /etc/5dive/connectors/github-bot.env does not exist at all:
#
#   sudo 5dive task merge-gate-selftest
#   OK — ... machine-account rail: available; anonymous rail: usable
#
# while every verb that then takes the rail fails on "machine-account credential missing
# (/etc/5dive/connectors/github-bot.env)" — `_merge_do` and `_gh_do` both. The selftest is
# the ONE surface on which an inert gate announces itself, so a false positive there is the
# most expensive one available: it is the instrument the refusals send the reader to.
#
# WHAT IS EXECUTED. The composed predicate, the operator-facing string and the selftest verb
# itself, over a stubbed `sudo` that can answer the two questions INDEPENDENTLY — permitted
# yes/no crossed with credential present/absent. That cross is the whole point: the defect is
# exactly the cell where they disagree. `_gh_bot_available`'s own file is graded in a child
# shell against a fixture connector, because its path is `readonly` and cannot be repointed
# in-process. The MUTANT reverts the predicate to the permission-only one and must show the
# false "available" again.
# DIVE-2211: name the tree this harness grades. Sourced BEFORE the cd, from BASH_SOURCE, so
# the tree named is the one this FILE lives in rather than $PWD.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
# The anon rail would otherwise reach the REAL network. Must sit AFTER grading_tree.sh,
# which clears inherited FIVE_* knobs.
export FIVE_GATE_NO_ANON=1
TMP="$(mktemp -d /tmp/selftest-bot-rail.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
ROOT="$PWD"
mkdir -p "$TMP/bin"

# --- stub sudo: the two questions, answered INDEPENDENTLY ---------------------
#   SUDO_STUB_BOT=1    -> `sudo -n -l <path> _gh_do` exits 0: this seat MAY route.
#   SUDO_STUB_PROBE=1  -> `sudo -n <path> _gh_do` (the --probe call) exits 0: the
#                         credential IS there.
# Keeping them separate is what lets the cell the defect lives in — permitted, no
# credential — be constructed at all.
cat >"$TMP/bin/sudo" <<'SUDOSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_CALLS"
if [[ "$*" == *" -l "* ]]; then
  [[ "${SUDO_STUB_BOT:-0}" == "1" ]] && exit 0
  exit 1
fi
if [[ "$*" == *"_gh_do"* ]]; then
  cat >/dev/null            # drain the NUL-separated argv the probe writes
  [[ "${SUDO_STUB_PROBE:-0}" == "1" ]] && exit 0
  exit 1
fi
printf 'sudo: a password is required\n' >&2; exit 1
SUDOSTUB
chmod +x "$TMP/bin/sudo"
export SUDO_CALLS="$TMP/sudo.calls"; : >"$SUDO_CALLS"

cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0; fi
[[ -n "${GH_STUB_STATE:-}" ]] || exit 1
printf '%s\n' "$GH_STUB_STATE"
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
AUDIT_LOG="$TMP/audit.log"
mkdir -p "$TASKS_DIR"; set +e
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- THE PERMISSION HALF IS SEAMED, and this is the correction that matters -----
# `_gate_gh_bot_ok` short-circuits on `[[ -x /usr/local/bin/5dive ]]` — a HOST fact
# that no stub in this file reaches. On a developer box the installed CLI is there
# and every cell below runs; on a CI runner it is not, and the first version of this
# file went green here and RED IN CI with 14 arms failing, because `_gate_gh_bot_ok`
# answered "no" whatever the stubbed sudo said. A harness whose central arms only run
# where the product happens to be installed has not graded them.
#
# So the permission half is a seam. That is legitimate here because it is not what
# this file is about: the defect is that permission was READ AS presence, so what has
# to be graded is the CONJUNCTION and the three strings it produces. The real
# `_gate_gh_bot_ok` — sudoers, the -x gate, the installed path — is graded by
# tests/builder_gh_rail_unit.sh, which owns it and names its own skip. P1 below still
# exercises the real one wherever the host allows, so the seam cannot hide a drift.
_gate_gh_bot_ok() { [[ "${SUDO_STUB_BOT:-0}" == "1" ]]; }

# Each cell is just the two stub answers. The predicate deliberately holds NO state
# between calls — see T6, which is the arm that pins that.
cell() { export SUDO_STUB_BOT="$1" SUDO_STUB_PROBE="$2"; }

# P1: the real predicate, wherever this host can run it. Named, not silent, so a
# runner that cannot reach it says so instead of reporting a green it did not earn.
if [[ -x /usr/local/bin/5dive ]]; then
  ( unset -f _gate_gh_bot_ok; source "$SRC/task/gate_evidence.sh" 2>/dev/null
    export SUDO_STUB_BOT=1; _gate_gh_bot_ok ) \
    && ok_t "P1 the REAL _gate_gh_bot_ok answers yes through the stubbed sudo on this host (the seam below is a stand-in for this, not a divergence from it)" \
    || bad_t "P1 real predicate" "the real _gate_gh_bot_ok said no with the grant stubbed yes"
else
  ok_t "P1 SKIPPED-BY-DESIGN: /usr/local/bin/5dive is not executable here, so the real _gate_gh_bot_ok cannot be exercised; tests/builder_gh_rail_unit.sh owns that predicate and names the same limit"
fi

# --- 1. THE CROSS ------------------------------------------------------------
cell 1 1
_gate_gh_bot_present && ok_t "T1 permitted + credential present -> the rail IS present" || bad_t "T1" ""
[[ "$(_gate_gh_bot_state)" == "available" ]] \
  && ok_t "T1a ...and reads 'available'" || bad_t "T1a" "got [$(_gate_gh_bot_state)]"

cell 1 0
! _gate_gh_bot_present \
  && ok_t "T2 THE DEFECT'S CELL: permitted but NO credential -> the rail is NOT present" || bad_t "T2" ""
st="$(_gate_gh_bot_state)"
[[ "$st" != "available" ]] \
  && ok_t "T2a ...and it does NOT read 'available' — this is the exact string the box printed over an absent connector" \
  || bad_t "T2a the defect, live" "got [$st]"
[[ "$st" == *"credential absent"* ]] \
  && ok_t "T2b ...it says the credential is absent" || bad_t "T2b" "got [$st]"
[[ "$st" == *"github-bot.env"* && "$st" == *"5dive secret write"* ]] \
  && ok_t "T2c ...and names the file and the command that fixes it, so the state is a provisioning step with a name" \
  || bad_t "T2c" "got [$st]"
[[ "$st" != *"not permitted"* ]] \
  && ok_t "T2d ...and does NOT say 'not permitted on this seat', which is a different box and a different remedy" \
  || bad_t "T2d three states must stay three" "got [$st]"

cell 0 0
! _gate_gh_bot_present && ok_t "T3 not permitted -> not present" || bad_t "T3" ""
[[ "$(_gate_gh_bot_state)" == "not permitted on this seat" ]] \
  && ok_t "T3a ...and the seat-level string is unchanged from before this fix" || bad_t "T3a" "got [$(_gate_gh_bot_state)]"

cell 0 1
! _gate_gh_bot_present \
  && ok_t "T4 a credential this seat may not reach is still not a rail FOR THIS SEAT (the conjunction, in the other direction)" \
  || bad_t "T4" ""
[[ "$(_gate_gh_bot_state)" == "not permitted on this seat" ]] \
  && ok_t "T4a ...and permission is reported first, because it is the one the operator can see for themselves" \
  || bad_t "T4a" ""

# --- 2. THE PROBE IS ASKED AT ALL, AND ONLY AS A PROBE -----------------------
cell 1 0
: >"$SUDO_CALLS"; _gate_gh_bot_present
grep -q '_gh_do' "$SUDO_CALLS" \
  && ok_t "T5 the presence question IS asked — a sudo call to _gh_do, which is the half that did not exist before" \
  || bad_t "T5 probe must be asked" "$(cat "$SUDO_CALLS")"
[[ "$(grep -c -- '--probe' "$SUDO_CALLS")" == "0" ]] \
  && ok_t "T5a ...with the sentinel on STDIN, never in the argv, so it cannot reach gh even by accident" \
  || bad_t "T5a probe must not be an argv flag" "$(cat "$SUDO_CALLS")"
[[ "$(grep -c '_gh_do' "$SUDO_CALLS")" == "1" ]] \
  && ok_t "T5b ...exactly one probe per answer" || bad_t "T5b" "calls=[$(cat "$SUDO_CALLS")]"
# SHORT-CIRCUIT: a seat that may not route is not asked about a credential it could
# not use. This is what makes the conjunction an AND rather than two reports.
cell 0 1
: >"$SUDO_CALLS"; _gate_gh_bot_present
[[ "$(grep -c '_gh_do' "$SUDO_CALLS")" == "0" ]] \
  && ok_t "T5c SHORT-CIRCUIT: with no permission the probe is not asked at all — no wasted sudo, and no question about a rail this seat cannot use" \
  || bad_t "T5c" "calls=[$(cat "$SUDO_CALLS")]"

# T6 PINS THE ABSENCE OF CACHING, and it is here because the first version of this fix
# memoised the answer in a process-scoped variable. That looks free — neither half changes
# under a running command — and it silently broke tests/builder_gh_rail_unit.sh, which walks
# several seats in ONE process under different stubbed sudos: the first cell's answer was
# returned for the second and a reachable builder read as unreachable. Two sudo forks on a
# refusal path are cheaper to own than a predicate whose answer depends on when it was first
# called.
cell 1 0
! _gate_gh_bot_present || bad_t "T6 setup" "expected the absent cell"
cell 1 1
_gate_gh_bot_present \
  && ok_t "T6 NO CACHING: the same process answers 'absent' then 'present' as the environment changes — nothing is carried between calls" \
  || bad_t "T6 stale cached answer" "the absent cell's answer survived into the present one"
cell 1 0
! _gate_gh_bot_present \
  && ok_t "T6a ...and back again, so the walk is real in both directions" || bad_t "T6a" ""

# --- 3. _gate_gh_reachable ---------------------------------------------------
cell 1 1
_gate_gh_reachable "" && ok_t "T7 reachable with the bot rail actually present" || bad_t "T7" ""
cell 1 0
! _gate_gh_reachable "" \
  && ok_t "T8 NOT reachable on permission alone — 'some way to ask GitHub exists' was false on a box with no connector (anon disabled here)" \
  || bad_t "T8" ""
cell 1 0
_gate_gh_reachable "a-token" \
  && ok_t "T8a ...while a caller that HOLDS a token is still reachable: the token arm is untouched" || bad_t "T8a" ""

# --- 4. THE VERB ITSELF ------------------------------------------------------
cell 1 0
export GH_STUB_STATE=MERGED
out=$(cmd_task_merge_gate_selftest 2>&1); rc=$?
[[ "$out" == *"machine-account rail: permitted, but credential absent"* ]] \
  && ok_t "T9 THE TITLED DEFECT: merge-gate-selftest no longer prints 'machine-account rail: available' over an absent credential" \
  || bad_t "T9 selftest string" "rc=$rc out=[${out:0:400}]"
[[ "$out" != *"machine-account rail: available"* ]] \
  && ok_t "T9a ...the false string is absent from the whole line" || bad_t "T9a" "${out:0:400}"
cell 1 1
out=$(cmd_task_merge_gate_selftest 2>&1)
[[ "$out" == *"machine-account rail: available"* ]] \
  && ok_t "T9b POSITIVE CONTROL: with the credential present it DOES read available — the fix narrows the claim, it does not delete it" \
  || bad_t "T9b" "${out:0:400}"

# --- 5. ONE STRING, TWO PRINTERS --------------------------------------------
[[ "$(grep -c '_gate_gh_bot_state' "$ROOT/src/task/gate_evidence.sh")" -ge 2 \
   && "$(grep -c '_gate_gh_bot_state' "$ROOT/src/task/delivery.sh")" -ge 1 ]] \
  && ok_t "T10 the selftest and the DIVE-2318 refusal print the SAME helper — a refusal that contradicts the instrument it recommends is worse than either being wrong alone" \
  || bad_t "T10 shared string" ""
[[ "$(grep -c "_gate_gh_bot_ok && printf 'available'" "$ROOT/src/task/gate_evidence.sh")" == "0" ]] \
  && ok_t "T10a ...and the refusal's own inline copy of the old predicate is gone" || bad_t "T10a" ""

# --- 6. THE ROOT-SIDE PROBE --------------------------------------------------
# `_GH_BOT_ENV` is readonly, so the only way to execute `_gh_bot_available` against a
# fixture is to source a COPY of its file with the path rewritten. The rewrite is asserted,
# so this cannot silently grade a mangled file.
CG="$TMP/cmd_gh_fixture.sh"
FIX="$TMP/github-bot.env"
sed "s#^readonly _GH_BOT_ENV=.*#readonly _GH_BOT_ENV=\"$FIX\"#" "$ROOT/src/cmd_gh.sh" > "$CG"
[[ "$(grep -c "^readonly _GH_BOT_ENV=\"$FIX\"$" "$CG")" == "1" ]] \
  && ok_t "T11 the fixture copy repoints _GH_BOT_ENV exactly once" || bad_t "T11 rewrite" ""
probe_says() { bash -c '
    set -uo pipefail
    source "$1" 2>/dev/null
    _gh_bot_available && echo present || echo absent' _ "$CG"; }
rm -f "$FIX"
[[ "$(probe_says)" == "absent" ]] \
  && ok_t "T11a no connector file -> absent (the box this was measured on)" || bad_t "T11a" "got [$(probe_says)]"
printf 'SOMETHING_ELSE=1\n' >"$FIX"
[[ "$(probe_says)" == "absent" ]] \
  && ok_t "T11b a connector file that does NOT carry the key -> absent" || bad_t "T11b" "got [$(probe_says)]"
printf 'GH_BOT_TOKEN=ghp_fixture\n' >"$FIX"
[[ "$(probe_says)" == "present" ]] \
  && ok_t "T11c ...and with the key -> present, so the probe can answer both ways" || bad_t "T11c" "got [$(probe_says)]"

# The probe branch must be first-position-only, must not reach gh, and must mark itself
# reported — a silent non-zero is what the DIVE-2598 backstop reports as a CLI bug, and
# this one is a VERDICT.
awk '/^cmd_gh_do\(\) \{/{i=1} i&&/--probe/{p=NR} i&&/--identity=reviewer/{r=NR} i&&/^\}/{i=0}
     END{exit !(p && r && p < r)}' "$ROOT/src/cmd_gh.sh" \
  && ok_t "T12 the probe sentinel is read before the identity sentinel, in first position, inside cmd_gh_do" \
  || bad_t "T12 probe placement" ""
awk '/"\$\{args\[0\]\}" == "--probe"/{i=1} i&&/mark_reported/{m=1} i&&/^  fi$/{i=0} END{exit !m}' "$ROOT/src/cmd_gh.sh" \
  && ok_t "T12a ...and its negative answer calls mark_reported, so a 'no' is not reported as an unexplained CLI crash" \
  || bad_t "T12a probe must mark_reported" ""

# --- 7. MUTANT: the permission-only predicate, back --------------------------
MUT="$TMP/gate_evidence_mut.sh"
cp "$ROOT/src/task/gate_evidence.sh" "$MUT"
perl -0pi -e 's/^  _gate_gh_bot_present && return 0$/  _gate_gh_bot_ok && return 0/m' "$MUT"
perl -0pi -e 's/^  if _gate_gh_bot_present; then printf .available.; return 0; fi$/  if _gate_gh_bot_ok; then printf \x27available\x27; return 0; fi/m' "$MUT"
mdiff=$(diff "$ROOT/src/task/gate_evidence.sh" "$MUT" | grep -c '^[<>]')
[[ "$mdiff" == "4" ]] \
  && ok_t "M0 MUTANT reverts both uses to the permission-only predicate — exactly two lines, four diff lines" \
  || bad_t "M0 differential" "changed=$mdiff"
bash -n "$MUT" && ok_t "M0a ...and is still valid bash" || bad_t "M0a" ""
( source "$MUT" 2>/dev/null
  # re-seam: sourcing the mutant reinstated the real, host-dependent predicate
  _gate_gh_bot_ok() { [[ "${SUDO_STUB_BOT:-0}" == "1" ]]; }
  export SUDO_STUB_BOT=1 SUDO_STUB_PROBE=0
  [[ "$(_gate_gh_bot_state)" == "available" ]] ) \
  && ok_t "M1 MUTANT — T2a is RED on it: permitted-with-no-credential reads 'available' again. The defect, live." \
  || bad_t "M1 mutant must reproduce the defect" ""
( source "$MUT" 2>/dev/null
  _gate_gh_bot_ok() { [[ "${SUDO_STUB_BOT:-0}" == "1" ]]; }
  export SUDO_STUB_BOT=1 SUDO_STUB_PROBE=1
  [[ "$(_gate_gh_bot_state)" == "available" ]] ) \
  && ok_t "M2 ...while the credential-present cell reads the same on the mutant, so it differs in exactly the defect's cell (T1a green on it)" \
  || bad_t "M2" ""

printf -- '-----\n'
printf 'merge_gate_selftest_bot_rail: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
