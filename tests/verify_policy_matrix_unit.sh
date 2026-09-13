#!/usr/bin/env bash
# DIVE-4251 isolated unit harness — verification is a CUSTOMER choice.
#
# THE 9-ARM MATRIX IS THE WHOLE TEST. Three box policies (always /
# delivered-only / never) crossed with three row states (no flag / --no-verify /
# --verify), asserted on what `task add` actually PERSISTS — the verifier column
# — not on what it printed. A notice can be right while the row is wrong.
#
#              no flag              --no-verify        --verify
#   always     grader               none               grader
#   delivered- none (deferred to    none               grader
#     only       task deliver)
#   never      none                 none               grader
#
# THE MUTATION ARM IS NOT DECORATION. The matrix above is satisfied by a `task
# add` that IGNORES the box default entirely and simply grades everything, on
# three of the nine arms — so a green matrix alone cannot tell "the policy is
# read" from "the policy happens to agree". The mutation deletes the box-default
# term from the gate (the `_vp_grants == 1` conjunct) and asserts the
# delivered-only and never arms go RED. If they stay green the matrix is
# measuring nothing, and that is reported as a FAIL of this harness.
#
# Same isolation contract as the other task harnesses: src/ sourced directly,
# STATE_DIR on a throwaway temp dir, BOX_CONFIG pointed inside it, so the live
# box's own policy is never read and the shared tasks.db is never touched.
# Run: bash tests/verify_policy_matrix_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/verify-policy-matrix.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/disk.sh lib/verify_policy.sh lib/tasks_db.sh lib/runs.sh \
         lib/actor.sh cmd_task.sh cmd_push.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
BOX_CONFIG="$TMP/box.json"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# ok_t / bad_t, never ok / fail: src/lib/output.sh owns those two names and a
# harness that redefines them breaks the very code it is grading.
PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1

# A distinct grader always exists, so an EMPTY verifier column can only mean the
# policy declined — never "no grader was available", which is a different state
# (verify_unavailable) and would make every negative arm pass for a wrong reason.
_task_default_verifier() { printf 'grader'; }
# The DIVE-969 triviality classifier is stubbed OPEN for the same reason: an arm
# must fail because of the POLICY, not because a generated title read as a chore.
_task_verify_skip_reason() { printf ''; }

set_policy() { printf '{"verify":"%s"}\n' "$1" > "$BOX_CONFIG"; }

# add_row <policy> <flag-or-empty> -> echoes the persisted verifier ('' = none)
add_row() {
  local policy="$1" flag="${2:-}" out ident
  set_policy "$policy"
  local -a args=("policy ${policy} ${flag:-none} $RANDOM" --assignee=dev2 --from=main --priority=high)
  [[ -n "$flag" ]] && args+=("$flag")
  out=$(cmd_task_add "${args[@]}" 2>/dev/null)
  # `.data.ident`, not `.ident`: ok() wraps every payload in {ok,data}. The first
  # cut read `.ident`, got empty on a SUCCESSFUL add, and every arm failed
  # identically — which is what a wrong accessor looks like from the outside.
  ident=$(jq -r '.data.ident // empty' <<<"$out" 2>/dev/null)
  [[ -n "$ident" ]] || { printf '__ADD_FAILED__(%s)' "${out:0:180}"; return 0; }
  db "SELECT COALESCE(verifier,'') FROM tasks WHERE ident=$(sqlq "$ident");"
}

expect() { # <label> <policy> <flag> <grader|none>
  local label="$1" got want="$4"
  got=$(add_row "$2" "${3:-}")
  case "$want" in
    grader) [[ "$got" == "grader" ]] && ok_t "$label" || bad_t "$label" "verifier='$got', wanted 'grader'" ;;
    none)   [[ -z "$got" ]]          && ok_t "$label" || bad_t "$label" "verifier='$got', wanted none" ;;
  esac
}

echo "── the 9-arm matrix ─────────────────────────────────────────────"
expect "always     + no flag     -> grader" always         ""           grader
expect "always     + --no-verify -> none"   always         --no-verify  none
expect "always     + --verify    -> grader" always         --verify     grader
expect "delivered- + no flag     -> none"   delivered-only ""           none
expect "delivered- + --no-verify -> none"   delivered-only --no-verify  none
expect "delivered- + --verify    -> grader" delivered-only --verify     grader
expect "never      + no flag     -> none"   never          ""           none
expect "never      + --no-verify -> none"   never          --no-verify  none
expect "never      + --verify    -> grader" never          --verify     grader

echo "── unset means delivered-only, through the real add/deliver path ─"
printf '{}\n' > "$BOX_CONFIG"
_u=$(cmd_task_add "unset default flow $RANDOM" --assignee=dev2 --from=main --priority=high 2>/dev/null)
_ui=$(jq -r '.data.ident // empty' <<<"$_u")
_uv_before=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE ident=$(sqlq "$_ui");")
FIVE_DELIVER_NO_REACH_PROBE=1
_ud=$( ( actor_seam_as dev2; cmd_task_start "$_ui" >/dev/null 2>&1; cmd_task_deliver "$_ui" --pr='https://github.com/o/r/pull/2' ) 2>&1)
_uv_after=$(db "SELECT COALESCE(verifier,'') FROM tasks WHERE ident=$(sqlq "$_ui");")
if [[ "$(box_verify_policy)" == "delivered-only" && -z "$_uv_before" && "$_uv_after" == "grader" ]]; then
  ok_t "unset policy defers a standard row at add, then attaches its grader at delivery"
else
  bad_t "unset policy follows delivered-only through add and delivery" \
        "policy=$(box_verify_policy) before='$_uv_before' after='$_uv_after' out=${_ud:0:180}"
fi

echo "── the override is PERSISTED, not just consumed ─────────────────"
set_policy never
_o=$(cmd_task_add "forced row $RANDOM" --assignee=dev2 --from=main --priority=high --verify 2>/dev/null)
_i=$(jq -r '.data.ident // empty' <<<"$_o")
_f=$(db "SELECT COALESCE(verify_forced,0) FROM tasks WHERE ident=$(sqlq "$_i");")
[[ "$_f" == "1" ]] && ok_t "--verify writes verify_forced=1 (survives task add)" \
  || bad_t "--verify writes verify_forced=1" "verify_forced='$_f'"

echo "── contradictory flags are refused, not silently ordered ────────"
_c=$(cmd_task_add "contradiction $RANDOM" --assignee=dev2 --from=main --verify --no-verify 2>&1)
[[ "$_c" == *"contradict"* ]] && ok_t "--verify + --no-verify is refused" \
  || bad_t "--verify + --no-verify is refused" "got: ${_c:0:160}"

echo "── delivered-only ATTACHES at task deliver (the deferral lands) ──"
set_policy delivered-only
_o=$(cmd_task_add "deferred row $RANDOM" --assignee=dev2 --from=main --priority=high 2>/dev/null)
_i=$(jq -r '.data.ident // empty' <<<"$_o")
db "UPDATE tasks SET delivery_ref='https://github.com/o/r/pull/1' WHERE ident=$(sqlq "$_i");" >/dev/null
_id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$_i");")
if _task_verify_grants "$_id"; then ok_t "delivered-only grants a grader once a delivery is bound"
else bad_t "delivered-only grants a grader once a delivery is bound" "resolver still refuses with delivery_ref set"; fi
db "UPDATE tasks SET delivery_ref=NULL WHERE id=${_id};" >/dev/null
if _task_verify_grants "$_id"; then bad_t "delivered-only refuses while UNBOUND" "resolver granted with no delivery_ref"
else ok_t "delivered-only refuses while UNBOUND"; fi

echo "── MUTATION: delete the box-default term from task add's gate ────"
# Re-source crud.sh with the `_vp_grants == 1` conjunct removed. If the matrix
# above is really measuring the policy, the delivered-only and never arms must
# now attach a grader.
MUT="$TMP/crud_mutant.sh"
sed 's/&& \$_vp_grants == 1 \\//' "$SRC/task/crud.sh" > "$MUT"
if ! cmp -s "$MUT" "$SRC/task/crud.sh"; then
  # shellcheck source=/dev/null
  source "$MUT"
  _task_default_verifier() { printf 'grader'; }
  _task_verify_skip_reason() { printf ''; }
  _m1=$(add_row delivered-only ""); _m2=$(add_row never "")
  if [[ "$_m1" == "grader" && "$_m2" == "grader" ]]; then
    ok_t "mutant reds both policy arms (the matrix is load-bearing)"
  else
    bad_t "mutant reds both policy arms" "delivered-only='$_m1' never='$_m2' — the matrix would pass against a task add that ignores the box default"
  fi
else
  bad_t "mutation applied" "the sed found nothing to remove — the gate has been renamed; update this harness"
fi

echo "── the surface that writes it: 5dive config ─────────────────────"
# require_root is stubbed: the harness cannot be root, and what is under test is
# the read/write/validate contract, not the privilege check (which is one line
# and is exercised for real by the CLI on every set).
source "$SRC/cmd_box_config.sh"
require_root() { return 0; }
JSON_MODE=0
rm -f "$BOX_CONFIG"
_p=$(box_verify_policy)
_r=$(cmd_box_config 2>&1)
[[ "$_p" == "delivered-only" && "$_r" == *"verify = delivered-only (unset — defaulting to 'delivered-only')"* ]] \
  && ok_t "config with no box file resolves delivered-only and says it is the unset default" \
  || bad_t "config with no box file resolves delivered-only and says unset" "policy=$_p output=${_r:0:200}"

printf '{}\n' > "$BOX_CONFIG"
_p=$(box_verify_policy)
_r=$(cmd_box_config 2>&1)
[[ "$_p" == "delivered-only" && "$_r" == *"verify = delivered-only (unset — defaulting to 'delivered-only')"* ]] \
  && ok_t "config with no verify key resolves delivered-only and says it is the unset default" \
  || bad_t "config with no verify key resolves delivered-only and says unset" "policy=$_p output=${_r:0:200}"
_r=$(cmd_box_config verify=bogus 2>&1)
[[ "$_r" == *"always, delivered-only, never"* ]]   && ok_t "an out-of-range value is refused and the legal set is named"   || bad_t "an out-of-range value is refused" "got: ${_r:0:200}"
cmd_box_config verify=never >/dev/null 2>&1
[[ "$(box_verify_policy)" == "never" ]]   && ok_t "config verify=never round-trips through the file"   || bad_t "config verify=never round-trips" "box_verify_policy=$(box_verify_policy)"
_r=$(cmd_box_config unknown=1 2>&1)
[[ "$_r" == *"unknown box setting"* ]]   && ok_t "an unknown key is refused rather than silently stored"   || bad_t "an unknown key is refused" "got: ${_r:0:200}"
# The fleet kill-switch and the box file must not be two separately-consulted
# rails: FIVE_VERIFY_DEFAULT=0 has to win, or a box.json saying `always` would
# quietly resurrect grading on a fleet that had turned it off.
printf '{"verify":"always"}\n' > "$BOX_CONFIG"
[[ "$(FIVE_VERIFY_DEFAULT=0 box_verify_policy)" == "never" ]]   && ok_t "FIVE_VERIFY_DEFAULT=0 still wins over a box file saying 'always'"   || bad_t "FIVE_VERIFY_DEFAULT=0 wins over the box file" "got $(FIVE_VERIFY_DEFAULT=0 box_verify_policy)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
[[ "$FAILN" -eq 0 ]]
