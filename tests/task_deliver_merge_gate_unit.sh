#!/usr/bin/env bash
# DIVE-1830 isolated unit harness for `task deliver` + the opt-in merge-gate on
# `task done`. Design (main, option A): a maker records the delivering PR via
# `task deliver --pr=<url>` (which reuses the DIVE-477 verifier handoff), and a
# task that carries a delivery_ref cannot close via `task done` until that PR is
# MERGED to main. Tasks that never declared a delivery are untouched (opt-in →
# zero regression). Isolation matches the sibling gate harnesses: source src/
# libs into a throwaway STATE_DIR — the live shared tasks.db is NEVER touched;
# `gh` is STUBBED on PATH so the gate's merge check is fully controllable.
# Run: bash tests/task_deliver_merge_gate_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/deliver-gate-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh: emits state/mergedAt from env, keyed off the -q '.field' arg. -----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal stand-in for both merge-gate calls:
#   gh pr view <url>  --json state,mergedAt        -q '.state' | -q '.mergedAt'
#   gh pr list --head <b> --state merged --json ... -q '.[0].mergedAt'
q=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    -q*) q="${1#-q}"; shift ;;
    *)  shift ;;
  esac
done
case "$q" in
  .state)          printf '%s\n' "${GH_STUB_STATE:-}" ;;
  .mergedAt|.\[0\].mergedAt|'.[0].mergedAt') printf '%s\n' "${GH_STUB_MERGED:-}" ;;
  *)               printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_STUB_STATE:-}" "${GH_STUB_MERGED:-}" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
# No DMs / root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }

seed_task()  { db "INSERT INTO tasks (ident, title, status, created_by, assignee, verifier)
                     VALUES ('$1','t','in_progress','main','$2','$3');"; }
statusof()   { db "SELECT status FROM tasks WHERE ident='$1';"; }
assigneeof() { db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident='$1';"; }
drefof()     { db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident='$1';"; }
delivof()    { db "SELECT CASE WHEN delivered_at IS NULL THEN 'no' ELSE 'yes' END FROM tasks WHERE ident='$1';"; }

PR="https://github.com/5dive-ai/5dive/pull/999"

# --- Ta: deliver on a task WITH a distinct verifier records the delivery and
#     routes to the verifier (status non-done, assignee flips to verifier). ------
seed_task DIVE-201 main dev
out=$(cmd_task_deliver DIVE-201 --pr="$PR" 2>&1); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "Ta deliver succeeds" \
  || bad_t "Ta deliver exit" "rc=$rc out=$out"
[[ "$(drefof DIVE-201)" == "$PR" && "$(delivof DIVE-201)" == "yes" ]] \
  && ok_t "Ta delivery_ref + delivered_at recorded" \
  || bad_t "Ta delivery recorded" "dref=$(drefof DIVE-201) delivered=$(delivof DIVE-201)"
[[ "$(assigneeof DIVE-201)" == "dev" && "$(statusof DIVE-201)" != "done" ]] \
  && ok_t "Ta routed to verifier (assignee=dev, status not done)" \
  || bad_t "Ta routed" "assignee=$(assigneeof DIVE-201) status=$(statusof DIVE-201)"

# --- Tb: a `task done` on a delivery_ref task whose PR is NOT merged is REFUSED
#     (non-zero, E_CONFLICT), and the task stays open. --------------------------
# DIVE-201 now sits with assignee==verifier (dev), so done reaches the merge-gate.
export GH_STUB_STATE="OPEN" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-201 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT ]] \
  && ok_t "Tb done on an unmerged delivery PR is REFUSED (E_CONFLICT)" \
  || bad_t "Tb refused rc" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$(statusof DIVE-201)" != "done" ]] \
  && ok_t "Tb the task did NOT close" \
  || bad_t "Tb not closed" "status=$(statusof DIVE-201)"
[[ "$out" == *"DIVE-1830"* ]] \
  && ok_t "Tb refusal cites the merge-gate (DIVE-1830)" \
  || bad_t "Tb message" "out=$out"

# --- Tc: same task, but gh now reports MERGED + a mergedAt → closes for real. ---
GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T10:00:00Z" \
  out=$(cmd_task_done DIVE-201 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-201)" == "done" ]] \
  && ok_t "Tc done on a MERGED delivery PR closes the task" \
  || bad_t "Tc close" "rc=$rc status=$(statusof DIVE-201) out=$out"

# --- Tc2: a task bound via the REAL `task set-branch` path (writes a `Branch:`
#     body line) and NO delivery_ref is REFUSED when gh reports no merged PR for
#     that head. Binding it through set-branch proves the gate covers the actual
#     delegated-push binding (DIVE-1462), not just a hand-written body line. -----
seed_task DIVE-210 main main
cmd_task_set_branch DIVE-210 feat/dive-210-thing >/dev/null 2>&1
[[ "$(db "SELECT body FROM tasks WHERE ident='DIVE-210';")" == *"feat/dive-210-thing"* ]] \
  || bad_t "Tc2 precond set-branch wrote the Branch: line" "body=$(db "SELECT body FROM tasks WHERE ident='DIVE-210';")"
[[ -z "$(drefof DIVE-210)" ]] || bad_t "Tc2 precond no delivery_ref" "dref=$(drefof DIVE-210)"
export GH_STUB_STATE="" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-210 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-210)" != "done" ]] \
  && ok_t "Tc2 done refused when the Branch: head has no merged PR (E_CONFLICT)" \
  || bad_t "Tc2 refused" "rc=$rc (want $E_CONFLICT) status=$(statusof DIVE-210) out=$out"
[[ "$out" == *"DIVE-1830"* && "$out" == *"feat/dive-210-thing"* ]] \
  && ok_t "Tc2 refusal cites DIVE-1830 + the branch name" \
  || bad_t "Tc2 message" "out=$out"

# --- Tc3: same Branch:-bound task, but gh now reports a merged PR for the head
#     → closes. ----------------------------------------------------------------
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-07-23T11:00:00Z"
out=$(cmd_task_done DIVE-210 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-210)" == "done" ]] \
  && ok_t "Tc3 done closes once the Branch: head has a merged PR" \
  || bad_t "Tc3 close" "rc=$rc status=$(statusof DIVE-210) out=$out"

# --- Td: regression — a task with NO delivery_ref closes on `task done` exactly
#     as before (gate does not fire; gh irrelevant). ----------------------------
# No verifier so done is a real close (verifier==assignee==main path: verifier '').
seed_task DIVE-202 main ''
GH_STUB_STATE="OPEN" GH_STUB_MERGED="" \
  out=$(cmd_task_done DIVE-202 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-202)" == "done" ]] \
  && ok_t "Td plain task (no delivery_ref) closes unchanged" \
  || bad_t "Td regression" "rc=$rc status=$(statusof DIVE-202) out=$out"

echo "-----"
printf 'task_deliver_merge_gate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
