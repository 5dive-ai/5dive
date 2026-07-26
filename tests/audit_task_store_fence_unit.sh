#!/usr/bin/env bash
# DIVE-2010 isolated unit harness — `task need`'s "unnotified" row is fenced on
# STORE IDENTITY, not on $EUID.
#
# WHY THIS EXISTS. cmd_task_need's rc=3 (filed, answerable, but nobody was
# pinged) branch used to be `[[ ... && $EUID -eq 0 ]] && audit_log ... || true`
# — an EUID gate that predates _emit_audit_line's non-root privileged fallback
# (DIVE-1989) and carried NO store-identity fence at all. Measured on this box:
# a 41-suite run (some executed as root) produced 6 real rows in the fleet audit
# log — "task need unnotified" on fixture idents DIVE-1, DIVE-2 x2, DIVE-3 x2,
# DIVE-4, filer=dev — from exactly this one call site. _task_gate_delivery_log
# already carried a store-identity fence for its own audit_log call (DIVE-1968);
# this call site had none. Fixed by dropping the $EUID condition and routing
# through _task_store_audit_log, a small reusable wrapper around
# _task_human_send_allowed (the same STORE IDENTITY primitive DIVE-1968 uses).
#
# What is pinned here:
#   1. off the prod store: cmd_task_need's rc=3 path writes NO audit row;
#   2. ...and the withholding is ANNOUNCED once (never silent — DIVE-1968
#      assertion 2: a silent fence is the same fail-open shape as no fence);
#   3. on the prod store: the row is written exactly as before — the fence
#      must not cost the coverage it is protecting;
#   4. the real fleet audit log is never touched by this suite, regardless of
#      which case runs or which $EUID this suite happens to run under.
# Run: bash tests/audit_task_store_fence_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/audit-task-store-fence.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

# Suite guard: remember the REAL log's length up front, so the check at the
# bottom fails if THIS run grew it — a regression here would otherwise sail
# past every other assertion while quietly writing to production (same shape
# as tests/audit_nonroot_unit.sh's guard).
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
# Force rc=3 (filed, answerable, nobody pinged) deterministically, independent
# of whatever channel config happens to be on this box.
task_need_notify() { return 3; }
reset() { : >"$AUDIT_CALLS"; unset _TASK_STORE_AUDIT_FENCED; }

# --- 1. OFF the prod store: no audit row -------------------------------------
reset
export FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db"   # active store != prod
t=$(addt --assignee=dev -- "fixture gate task")
# NB: run IN THIS SHELL, not inside a `$(...)` command substitution — that would
# fork a subshell and the one-shot _TASK_STORE_AUDIT_FENCED flag set inside it
# would never survive back to this process (mirrors the same caveat in
# tests/gate_telemetry_fence_unit.sh). In production this is never called in one.
cmd_task_need "$t" --type=decision --options="X|Y" --ask="pick" 2>"$TMP/first.err" >/dev/null
if [[ ! -s "$AUDIT_CALLS" ]]; then
  ok_t "off the prod store, an unnotified gate writes NO audit row"
else
  bad_t "off-store must not audit" "$(cat "$AUDIT_CALLS")"
fi
ERR1=$(cat "$TMP/first.err")
[[ "$ERR1" == *"telemetry withheld"* && "$ERR1" == *"DIVE-2010"* ]] \
  && ok_t "the withholding is ANNOUNCED, not silent" \
  || bad_t "fence must announce" "err=$ERR1"

# ...and only once per process, or every fixture gate in a suite reprints it.
t2=$(addt --assignee=dev -- "second fixture gate task")
cmd_task_need "$t2" --type=decision --options="X|Y" --ask="pick" 2>"$TMP/second.err" >/dev/null
ERR2=$(cat "$TMP/second.err")
[[ "$ERR2" != *"telemetry withheld"* ]] \
  && ok_t "the notice is one-shot per process, not once per row" \
  || bad_t "notice must be one-shot" "err=$ERR2"

# --- 2. ON the prod store: unchanged behaviour -------------------------------
reset
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"   # active store IS declared prod
t3=$(addt --assignee=dev -- "on-store fixture gate task")
t3_ident=$(db "SELECT ident FROM tasks WHERE id=$t3;")
cmd_task_need "$t3" --type=decision --options="X|Y" --ask="pick" >/dev/null 2>&1
# DIVE-2010 review (main): assert the SHAPE of the row, not the identity of
# whoever runs the suite. `filer=` comes from task_actor(), which resolves to
# the CALLER's own identity (dev2 -> dev here, but "main" on main's box, and
# neither in CI) — hardcoding "filer=dev" is exactly the DIVE-1919 defect, a
# harness asserting a fact about its own host rather than about the code.
LINE=$(grep '^task need unnotified' "$AUDIT_CALLS")
if [[ "$LINE" == *"task=${t3_ident} type=decision"* && "$LINE" =~ filer=[^[:space:]]+ ]]; then
  ok_t "on the prod store the unnotified-gate audit row is written exactly as before (ident + a filer field, any actor)"
else
  bad_t "on-store row must still be written" "line=[$LINE] audit=[$(cat "$AUDIT_CALLS")]"
fi

# --- 3. SUITE GUARD: this file must never reach production telemetry --------
REALLOG_NOW=0
[[ -r "$REALLOG" ]] && REALLOG_NOW=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)
if [[ "$REALLOG_NOW" == "$REALLOG_OFFSET" ]]; then
  ok_t "this run appended nothing to the production audit log"
else
  bad_t "this run appended nothing to the production audit log" \
        "grew from $REALLOG_OFFSET to $REALLOG_NOW bytes"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
