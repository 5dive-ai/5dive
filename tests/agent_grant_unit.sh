#!/usr/bin/env bash
# DIVE-4183 unit harness: `agent grant <seat> <merge|push|deploy>` — the verb that
# re-renders ONE existing standard seat's managed sudoers from the CURRENT
# template.
#
# The defect this pins: `_merge_do` is unconditional in render_standard_sudoers
# (DIVE-3474), but the policy is written only by the CREATE path, so both grader
# seats — provisioned earlier — held a four-grant drop-in and `5dive task merge`
# on a row they graded PASS ran NOTHING. Five merges on 2026-09-09 became a hand
# relay to an operator.
#
# What is graded here is the DECISION half (_agent_grant_plan): which policies it
# re-renders, which it REFUSES, that it is idempotent, and that re-rendering for
# one capability never drops another. The write half is write_standard_sudoers,
# already visudo-validated and covered where it is used; it needs root and a real
# /etc/sudoers.d, so it is not what a unit harness can honestly grade.
#
# Sources the src/ libs directly — no root, no adduser, no sudo, no network. The
# seat's policy is read from a FIXTURE dir via the documented SUDOERS_D seam.
#
# Run: bash tests/agent_grant_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No 2>/dev/null — the helper's
# stderr line IS the payload when it is unreachable.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-grant-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASS=0; FAIL=0
p_ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && p_ok "$1" || bad "$1" "$3" "$2"; }

export SUDOERS_D="$TMP/sudoers.d"
mkdir -p "$SUDOERS_D"

# The pre-DIVE-3474 grader policy, VERBATIM in shape: the managed header plus the
# four grants agent-quinn actually held on poke-two (measured 2026-09-09 20:00Z).
# Written out rather than generated, because generating it from today's template
# is exactly the drift this harness exists to catch.
legacy_policy() {
  cat <<EOF
# Managed by 5dive (DIVE-1065/1074). Scoped inter-agent a2a grants for standard agent $1.
$1 ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _deliver *
$1 ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _capture *
$1 ALL=(root) NOPASSWD: /usr/local/bin/5dive _audit_append
$1 ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _self_restart
$1 ALL=(root) NOPASSWD: /usr/local/bin/5dive _task_answer
EOF
}
seat() { printf '%s' "$1" > "$SUDOERS_D/$2"; }
plan_state()  { local p; p=$(_agent_grant_plan "$1" "$2"); printf '%s' "${p%%|*}"; }
plan_axes()   { local p; p=$(_agent_grant_plan "$1" "$2"); p="${p#*|}"; printf '%s|%s' "${p%%|*}" "$(p2="${p#*|}"; printf '%s' "${p2%%|*}")"; }

# ---------------------------------------------------------------------------
# 1. The shipped defect: a pre-DIVE-3474 grader seat is missing _merge_do, and
#    the plan says re-render.
# ---------------------------------------------------------------------------
echo "1. a pre-DIVE-3474 grader seat"
seat "$(legacy_policy agent-quinn)" agent-quinn
is "legacy policy really lacks the merge grant" \
   "$(grep -c '5dive _merge_do' "$SUDOERS_D/agent-quinn")" "0"
is "grant merge   -> update" "$(plan_state agent-quinn merge)" "update"
is "  and neither broker axis is invented" "$(plan_axes agent-quinn merge)" "0|0"
is "the rendered policy DOES carry the merge grant" \
   "$(render_standard_sudoers agent-quinn 0 0 | grep -cE '^agent-quinn ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _merge_do$')" "1"

# ---------------------------------------------------------------------------
# 2. Idempotence — a second run is a no-op with exit 0, not a second write.
# ---------------------------------------------------------------------------
echo "2. idempotence"
seat "$(render_standard_sudoers agent-quinn 0 0)" agent-quinn
is "already-rendered seat -> current" "$(plan_state agent-quinn merge)" "current"
seat "$(render_standard_sudoers agent-bldr 1 0)" agent-bldr
is "already-pushing seat, grant push -> current" "$(plan_state agent-bldr push)" "current"

# ---------------------------------------------------------------------------
# 3. Re-rendering for one capability must never DROP another. The two
#    conditional broker grants are read back from the enforced file.
# ---------------------------------------------------------------------------
echo "3. the other axes survive the re-render"
# A builder that holds push but predates the merge grant.
seat "$(render_standard_sudoers agent-bldr 1 0 | grep -v '5dive _merge_do$')" agent-bldr
is "push-holder, grant merge -> update" "$(plan_state agent-bldr merge)" "update"
is "  and can_push is PRESERVED, can_deploy stays off" "$(plan_axes agent-bldr merge)" "1|0"
seat "$(render_standard_sudoers agent-dep 0 1 | grep -v '5dive _merge_do$')" agent-dep
is "deploy-holder, grant merge -> preserves deploy" "$(plan_axes agent-dep merge)" "0|1"
seat "$(legacy_policy agent-bldr2)" agent-bldr2
is "grant push turns exactly its own axis on" "$(plan_axes agent-bldr2 push)" "1|0"
is "grant deploy turns exactly its own axis on" "$(plan_axes agent-bldr2 deploy)" "0|1"

# ---------------------------------------------------------------------------
# 4. Refusals. Every one of these is a policy this CLI did NOT author, so
#    re-rendering from the template would REPLACE it, not extend it.
# ---------------------------------------------------------------------------
echo "4. refusals — never widen, never overwrite a foreign policy"
is "no policy file at all -> refuse" "$(plan_state agent-ghost merge)" "refuse"
# Verbatim write_admin_sudoers output: a MANAGED file that is nonetheless not
# ours to re-render — so this input reaches, and grades, the class guard rather
# than stopping at the managed-header one above it.
seat "$(printf '%s\n%s\n' '# Managed by 5dive (DIVE-1002/1088). Fleet-management scope for admin agent agent-adm.' 'agent-adm ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *')" agent-adm
is "cli-root (admin) policy -> refuse" "$(plan_state agent-adm merge)" "refuse"
seat 'agent-old ALL=(ALL) NOPASSWD: ALL' agent-old
is "root-all legacy policy -> refuse" "$(plan_state agent-old merge)" "refuse"
seat "$(legacy_policy agent-hand | sed '1s/^# Managed by 5dive.*/# hand-written by an operator/')" agent-hand
is "no managed header -> refuse" "$(plan_state agent-hand merge)" "refuse"
seat "$(legacy_policy agent-extra; echo 'agent-extra ALL=(root) NOPASSWD: /bin/systemctl')" agent-extra
is "extra entries this CLI did not write -> refuse" "$(plan_state agent-extra merge)" "refuse"
is "  (and the extra really classifies as extra)" \
   "$(printf '%s\n' "$(cat "$SUDOERS_D/agent-extra")" | classify_sudo_grant | awk -F'|' '{print $3}')" "1"

# ---------------------------------------------------------------------------
# 5. The verb itself: root-only, and it refuses an unknown capability.
#    fail() exits, so each call is graded in a subshell by its exit code.
# ---------------------------------------------------------------------------
echo "5. cmd_agent_grant guards"
# shellcheck source=/dev/null
if [[ "$EUID" -ne 0 ]]; then
  ( source "$SRC/cmd_agent_create.sh"; cmd_agent_grant quinn merge ) >/dev/null 2>&1
  is "non-root caller -> E_PERMISSION" "$?" "$E_PERMISSION"
else
  p_ok "non-root caller -> SKIPPED (harness is running as root)"
fi
( source "$SRC/cmd_agent_create.sh"; cmd_agent_grant quinn ) >/dev/null 2>&1
rc_args=$?
( source "$SRC/cmd_agent_create.sh"; cmd_agent_grant quinn everything ) >/dev/null 2>&1
rc_cap=$?
if [[ "$EUID" -ne 0 ]]; then
  # As a non-root caller the root guard fires FIRST, which is the correct order:
  # both still refuse, and neither reaches a write.
  is "missing capability arg -> refused (non-zero)" "$([[ $rc_args -ne 0 ]] && echo refused)" "refused"
  is "unknown capability     -> refused (non-zero)" "$([[ $rc_cap -ne 0 ]] && echo refused)" "refused"
else
  is "missing capability arg -> E_USAGE" "$rc_args" "$E_USAGE"
  is "unknown capability     -> E_USAGE" "$rc_cap" "$E_USAGE"
fi

# ---------------------------------------------------------------------------
# 6. Non-vacuity. Revert the cli-scoped guard and the admin/root-all refusals
#    must turn into re-renders — i.e. section 4 is grading THAT line, not
#    passing because every input happens to refuse.
# ---------------------------------------------------------------------------
echo "6. mutation — the class guard is what section 4 grades"
MUT="$TMP/mut"; mkdir -p "$MUT"
sed 's/^  if \[\[ "\$cls" != "cli-scoped" \]\]; then$/  if [[ "$cls" == "NEVERMATCH" ]]; then/' \
  "$SRC/cmd_agent_create.sh" > "$MUT/cmd_agent_create.sh"
if grep -q 'NEVERMATCH' "$MUT/cmd_agent_create.sh"; then
  mut_adm=$( set +u; source "$MUT/cmd_agent_create.sh" >/dev/null 2>&1; p=$(_agent_grant_plan agent-adm merge); printf '%s' "${p%%|*}" )
  is "(mutant) class guard reverted -> the admin policy is no longer refused" \
     "$([[ "$mut_adm" != "refuse" ]] && echo "not-refused" || echo "refuse")" "not-refused"
else
  bad "(mutant) mutation did not apply — section 4's grade is vacuous" "guard reverted" "unchanged"
fi

echo
printf 'agent_grant_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
