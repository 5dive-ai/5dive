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

# ---------------------------------------------------------------------------
# 7. DIVE-4557: `agent grant <name> root` — the CONFERRAL path.
#
#    Different contract from sections 1-6, and the differences are the point:
#    this one MINTS where the standard re-render refuses to, it WIDENS on
#    purpose, and it must not silently overwrite a policy this CLI did not write
#    unless doing so changes nothing about what the seat can do.
# ---------------------------------------------------------------------------
echo "7. grant root — conferral, not re-render"
root_state() { local p; p=$(_agent_grant_root_plan "$1"); printf '%s' "${p%%|*}"; }

rm -f "$SUDOERS_D/agent-newbie"
is "no policy at all -> update (root MINTS; the standard verb refuses here)" \
   "$(root_state agent-newbie)" "update"
is "  and the standard verb still refuses the same input" \
   "$(plan_state agent-newbie merge)" "refuse"

seat "$(render_standard_sudoers agent-quinn 0 0)" agent-quinn
is "a managed cli-scoped seat -> update (widening is what the verb is for)" \
   "$(root_state agent-quinn)" "update"
seat "$(printf '%s\n%s\n' '# Managed by 5dive (DIVE-1002/1088). Fleet-management scope for admin agent agent-adm.' 'agent-adm ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *')" agent-adm
is "a managed cli-root (admin) seat -> update" "$(root_state agent-adm)" "update"

seat "$(render_root_sudoers agent-rooty)" agent-rooty
is "the managed root policy, byte for byte -> current (idempotent)" \
   "$(root_state agent-rooty)" "current"

# The pre-DIVE-1002 hand-written drop-in every legacy seat on this host carries.
# It is ALREADY root-all, so replacing it widens nothing — but it must not read
# as `current`, because `current` means "no write" and would leave the file
# unmanaged and the label still disagreeing.
seat 'agent-old ALL=(ALL) NOPASSWD: ALL' agent-old
is "hand-written root-all -> adopt, NOT current" "$(root_state agent-old)" "adopt"

# A foreign policy that is NARROWER than root is the one input we refuse: taking
# it would DELETE an operator's file rather than widen it.
seat "$(legacy_policy agent-hand2 | sed '1s/^# Managed by 5dive.*/# hand-written by an operator/')" agent-hand2
is "hand-written NARROWER policy -> refuse" "$(root_state agent-hand2)" "refuse"
seat "$(printf '%s\n' '# operator policy' 'agent-cust ALL=(root) NOPASSWD: /bin/systemctl restart caddy')" agent-cust
is "hand-written custom policy -> refuse" "$(root_state agent-cust)" "refuse"

# The rendered text IS root, classifies as root-all, and implies beyond-admin —
# the three facts the label stamp depends on. Grading the renderer rather than
# the writer keeps this harness root-free.
is "the rendered policy grants ALL=(ALL) NOPASSWD: ALL" \
   "$(render_root_sudoers agent-rooty | grep -cE '^agent-rooty ALL=\(ALL\) NOPASSWD: ALL$')" "1"
is "  carries the managed header (so a later run recognises its own file)" \
   "$(render_root_sudoers agent-rooty | head -1 | grep -c '^# Managed by 5dive ')" "1"
is "  classifies as root-all" \
   "$(render_root_sudoers agent-rooty | classify_sudo_grant | cut -d'|' -f1)" "root-all"
is "  whose implied label is exactly what the verb stamps" \
   "$(isolation_implied_by_grant "$(render_root_sudoers agent-rooty | classify_sudo_grant | cut -d'|' -f1)")" "beyond-admin"

# ---------------------------------------------------------------------------
# 8. Non-vacuity for section 7: revert the adopt/refuse split and the two
#    hand-written inputs stop being told apart.
# ---------------------------------------------------------------------------
echo "8. mutation — the adopt/refuse split is what section 7 grades"
sed 's/^    if \[\[ "\$cls" == "root-all" \]\]; then$/    if [[ "$cls" == "NEVERMATCH2" ]]; then/' \
  "$SRC/cmd_agent_create.sh" > "$MUT/cmd_agent_create_root.sh"
if grep -q 'NEVERMATCH2' "$MUT/cmd_agent_create_root.sh"; then
  mut_old=$( set +u; source "$MUT/cmd_agent_create_root.sh" >/dev/null 2>&1; p=$(_agent_grant_root_plan agent-old); printf '%s' "${p%%|*}" )
  is "(mutant) root-all arm reverted -> the legacy drop-in is no longer adopted" \
     "$([[ "$mut_old" != "adopt" ]] && echo "not-adopted" || echo "adopt")" "not-adopted"
else
  bad "(mutant) mutation did not apply — section 7's adopt grade is vacuous" "arm reverted" "unchanged"
fi

# ---------------------------------------------------------------------------
# 9. The fourth label must be RANKED, not defaulted. _hb_tier_rank's fallback is
#    0 — the bucket that never blocks an auto-wake — so an unranked new tier
#    fails OPEN and the guard reads as passing.
# ---------------------------------------------------------------------------
echo "9. beyond-admin is ranked above admin, not defaulted to 0"
rank_src=$(sed -n '/^_hb_tier_rank() {/,/^}/p' "$SRC/cmd_heartbeat.sh")
if [[ -n "$rank_src" ]]; then
  ( eval "$rank_src"
    is "beyond-admin outranks admin" \
       "$([[ "$(_hb_tier_rank beyond-admin)" -gt "$(_hb_tier_rank admin)" ]] && echo yes || echo no)" "yes"
    is "  and is not the unknown bucket" "$(_hb_tier_rank beyond-admin)" "4"
    printf '%d %d\n' "$PASS" "$FAIL" > "$TMP/rank.counts" )
  read -r PASS FAIL < "$TMP/rank.counts"
else
  bad "_hb_tier_rank not extractable from cmd_heartbeat.sh" "the function" "nothing"
fi

# ---------------------------------------------------------------------------
# 10. DIVE-4557 iteration 2: `agent grant` is a REGISTRY WRITER, so it must hold
#     the registry lock like every other mutating arm in main.sh.
#
#     What changed at 1a1e69c2: before it, `grant` touched sudoers only. The root
#     path stamps the isolation label, and `_agent_stamp_isolation` is an unlocked
#     read-modify-write (`registry_read | jq | registry_write`). registry_write is
#     atomic PER WRITE but takes no lock — the lock is the caller's job, and
#     src/main.sh says so in a comment above the switch.
#
#     The lock is COOPERATIVE, so an unlocked writer does not merely risk losing
#     its own write; it defeats the writers that honour it. Both directions are
#     forced here deterministically — a locked concurrent writer is made to land
#     inside the stamp's read/write window, rather than raced for:
#
#       (a) the grant clobbers the other writer  -> wake.idleSince LOST
#       (b) the other writer reverts the grant   -> sudoers root-all on disk,
#           registry label `admin`, i.e. the DIVE-2079 disagreement this verb
#           exists to abolish, on a seat holding unrestricted root.
#
#     Graded through the REAL dispatch arm, lifted out of src/main.sh, so the
#     grade tracks what ships rather than a re-typed copy of it. Section 11 is
#     its mutant: strip `with_registry_lock` from that lifted text and both
#     assertions must fail.
#
#     Root-free: only require_root and chown are stubbed (the harness is not
#     root); visudo, write_root_sudoers, registry_read/registry_write and the
#     stamp are the shipped ones, against a fixture STATE_DIR and SUDOERS_D.
# ---------------------------------------------------------------------------
echo "10. the registry lock — a concurrent locked writer forced into the window"

IL_DIR="$TMP/lock"
IL_STAMP="2026-09-15T12:00:00Z"
IL_WAIT_TICKS=40           # 40 x 0.05s = 2s; a BLOCKED writer never appears in it

# Keep an unhooked handle on the shipped writer before the instrument shadows it.
eval "registry_write_real() $(declare -f registry_write | tail -n +2)"

require_root() { :; }      # the harness is not root
chown()        { :; }      # ... so ensure_state/registry_write/write_root_sudoers chowns are no-ops

il_wait_for() {            # bounded wait; 0 = marker appeared, 1 = timed out
  local f="$1" i=0
  while (( i < IL_WAIT_TICKS )); do
    [[ -e "$f" ]] && return 0
    sleep 0.05; i=$((i+1))
  done
  return 1
}

# Models cmd_heartbeat.sh's `_hb_autosleep_arm`: a read-modify-write of a
# DIFFERENT field on the SAME seat, taken under the lock, as all 45 heartbeat
# call sites take it.
il_hb_arm() {
  registry_read \
    | jq --arg t "$IL_STAMP" '.agents.sysop.wake.idleSince = $t' \
    | registry_write_real
}

# Direction (b): read under the lock BEFORE the grant's write, write back after
# it — the shape of any heartbeat tick that straddles an unlocked stamp.
il_hb_read_then_write() {
  local snap; snap="$(registry_read)"
  : > "$IL_DIR/hb.read"
  il_wait_for "$IL_DIR/grant.write.done" || true
  printf '%s' "$snap" \
    | jq --arg t "$IL_STAMP" '.agents.sysop.wake.idleSince = $t' \
    | registry_write_real
}

# `exec 200>&-` models a SEPARATE process: a background subshell inherits the
# grant's open lock fd, and an inherited copy keeps the lock alive after the
# grant's subshell exits — the writer would then block on a lock nobody holds.
il_spawn_other() {
  ( exec 200>&-
    IN_REGISTRY_LOCK=0
    with_registry_lock "$1" >/dev/null 2>&1
    : > "$IL_DIR/other.done" ) &
}

# The instrument: the grant's own registry_write, delayed until the concurrent
# writer has landed. $body is the snapshot the stamp ALREADY read, so letting the
# other writer run here is precisely "between the read and the write".
registry_write() {
  local body; body="$(cat)"
  if [[ -n "${IL_MODE:-}" && ! -e "$IL_DIR/hook.fired" ]]; then
    : > "$IL_DIR/hook.fired"
    [[ "$IL_MODE" == "a" ]] && { il_spawn_other il_hb_arm; il_wait_for "$IL_DIR/other.done" || true; }
  fi
  printf '%s' "$body" | registry_write_real
  [[ -n "${IL_MODE:-}" ]] && : > "$IL_DIR/grant.write.done"
  return 0
}

il_fixture() {
  rm -rf "$IL_DIR"; mkdir -p "$IL_DIR/agents.d"
  STATE_DIR="$IL_DIR"; REGISTRY="$IL_DIR/agents.json"
  ENV_DIR="$IL_DIR/agents.d"; REGISTRY_LOCK="$IL_DIR/registry.lock"
  # ensure_state (which with_registry_lock calls) also provisions the task store;
  # TASKS_DIR is derived in lib/tasks_db.sh, which this harness does not source,
  # so point it at the fixture the way cmd_selfcheck's own fixtures do.
  TASKS_DIR="$IL_DIR/tasks"
  : > "$REGISTRY_LOCK"
  jq -n '{schemaVersion:1, agents:{sysop:{isolation:"admin", wake:{}}}}' > "$REGISTRY"
  printf 'AGENT_ISOLATION=admin\n' > "$ENV_DIR/sysop.env"
  rm -f "$SUDOERS_D/agent-sysop"
}

# -> "<registry label>|<the other writer's field>|<enforced sudo class>"
il_run() {
  local disp="$1" mode="$2"
  il_fixture
  IL_MODE="$mode"
  if [[ "$mode" == "b" ]]; then
    il_spawn_other il_hb_read_then_write
    il_wait_for "$IL_DIR/hb.read" || true
  fi
  "$disp" sysop root >/dev/null 2>&1
  il_wait_for "$IL_DIR/other.done" || true
  IL_MODE=""
  printf '%s|%s|%s' \
    "$(jq -r '.agents.sysop.isolation // "MISSING"' "$REGISTRY")" \
    "$(jq -r '.agents.sysop.wake.idleSince // "LOST"' "$REGISTRY")" \
    "$(classify_sudo_grant < "$SUDOERS_D/agent-sysop" 2>/dev/null | cut -d'|' -f1)"
}

# The arm as it ships, lifted out of src/main.sh rather than re-typed.
il_arm_src=$(sed -n '/^        grant)$/,/;;$/p' "$SRC/main.sh")
il_build() {   # $1 = fn name, $2 = arm text
  printf '%s() {\n  case "grant" in\n%s\n  esac\n}\n' "$1" "$2" > "$TMP/$1.sh"
  # shellcheck source=/dev/null
  source "$TMP/$1.sh"
}

if [[ -z "$il_arm_src" ]] || ! grep -q 'cmd_agent_grant' <<<"$il_arm_src"; then
  bad "the grant arm is extractable from src/main.sh" "the dispatch arm" "nothing usable"
else
  il_build il_dispatch_shipped "$il_arm_src"

  il_a=$(il_run il_dispatch_shipped a)
  is "(a) other writer lands mid-window: its field SURVIVES" "$(cut -d'|' -f2 <<<"$il_a")" "$IL_STAMP"
  is "(a)   ... and the grant's own label survives too"      "$(cut -d'|' -f1 <<<"$il_a")" "beyond-admin"

  il_b=$(il_run il_dispatch_shipped b)
  is "(b) heartbeat reads before / writes after: label SURVIVES" "$(cut -d'|' -f1 <<<"$il_b")" "beyond-admin"
  is "(b)   ... and its own field is not lost either"           "$(cut -d'|' -f2 <<<"$il_b")" "$IL_STAMP"
  is "(b)   ... so the enforced grant and the label AGREE" \
     "$(cls=$(cut -d'|' -f3 <<<"$il_b"); lbl=$(cut -d'|' -f1 <<<"$il_b")
        [[ "$cls" == "root-all" && "$(isolation_implied_by_grant "$cls")" == "$lbl" ]] && echo agree || echo "DISAGREE($cls vs $lbl)")" \
     "agree"

  # -------------------------------------------------------------------------
  # 11. Non-vacuity: strip `with_registry_lock` from the SAME lifted text and
  #     both directions must break — otherwise section 10 is grading nothing.
  # -------------------------------------------------------------------------
  echo "11. mutation — the lock is what section 10 grades"
  il_mut_src=${il_arm_src/with_registry_lock cmd_agent_grant/cmd_agent_grant}
  if [[ "$il_mut_src" == "$il_arm_src" ]] || grep -q 'with_registry_lock' <<<"$il_mut_src"; then
    bad "(mutant) mutation did not apply — section 10's grade is vacuous" "lock removed" "unchanged"
  else
    il_build il_dispatch_unlocked "$il_mut_src"
    il_ma=$(il_run il_dispatch_unlocked a)
    is "(mutant a) unlocked grant CLOBBERS the concurrent writer" \
       "$(cut -d'|' -f2 <<<"$il_ma")" "LOST"
    il_mb=$(il_run il_dispatch_unlocked b)
    is "(mutant b) the heartbeat REVERTS the grant's label" \
       "$(cut -d'|' -f1 <<<"$il_mb")" "admin"
    is "(mutant b)   ... leaving root on disk and \`admin\` in the registry" \
       "$(cut -d'|' -f3 <<<"$il_mb")" "root-all"
  fi
fi
unset -f registry_write registry_read 2>/dev/null; true

echo
printf 'agent_grant_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
