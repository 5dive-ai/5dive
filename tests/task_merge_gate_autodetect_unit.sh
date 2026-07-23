#!/usr/bin/env bash
# DIVE-1835 isolated unit harness for the MANDATORY auto-detect merge-gate.
# The DIVE-1830 gate only fired when the maker DECLARED a binding
# (delivery_ref / Branch:); 8 code-tasks closed with NEITHER and slipped past it.
# This gate auto-detects an OPEN unmerged PR whose TITLE or HEAD-BRANCH names the
# ident (never the body), is FAIL-OPEN (gh outage/timeout/absence never blocks a
# close), and honours `task done --force-merge-gate` as an audited escape.
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh is STUBBED on PATH.
# Run: bash tests/task_merge_gate_autodetect_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-autodetect-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- stub gh: answers `pr list` from env-driven fixtures, records argv. --------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*" >>"$GH_ARGS_LOG"
if [[ "$1" == "auth" && "$2" == "token" ]]; then printf '%s\n' "${GH_STUB_AUTH_TOKEN:-}"; exit 0; fi
# `pr list ... --json ...`: emit the fixture JSON array, let the caller's -q jq run.
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  # honour a simulated hang so the gate's `timeout 5s` can be exercised.
  [[ -n "${GH_STUB_HANG:-}" ]] && sleep "$GH_STUB_HANG"
  # find the -q expression to evaluate against the fixture with real jq.
  expr='.'; while [[ $# -gt 0 ]]; do case "$1" in -q) expr="$2"; shift 2;; -q*) expr="${1#-q}"; shift;; *) shift;; esac; done
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$expr" 2>/dev/null
  exit 0
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
task_need_notify() { :; }
# capture audit calls instead of touching the real log.
AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }
export GH_STUB_AUTH_TOKEN="tok"

seed()     { db "INSERT INTO tasks (ident, title, status, created_by, assignee)
                   VALUES ('$1','t','in_progress','main','main');"; }
statusof() { db "SELECT status FROM tasks WHERE ident='$1';"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- T1: an OPEN PR whose TITLE names the ident BLOCKS the no-binding close. ---
seed DIVE-901
export GH_STUB_PRLIST='[{"number":901,"headRefName":"feat/x","title":"DIVE-901 add thing"}]'
out=$(cmd_task_done DIVE-901 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-901)" != "done" ]] \
  && ok_t "T1 open PR naming the ident in its TITLE blocks the close" \
  || bad_t "T1 title match blocks" "rc=$rc status=$(statusof DIVE-901) out=$out"

# --- T2: an OPEN PR whose HEAD BRANCH names the ident BLOCKS (title doesn't). --
seed DIVE-902
export GH_STUB_PRLIST='[{"number":902,"headRefName":"feat/DIVE-902-fix","title":"unrelated title"}]'
out=$(cmd_task_done DIVE-902 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-902)" != "done" ]] \
  && ok_t "T2 open PR naming the ident in its HEAD BRANCH blocks the close" \
  || bad_t "T2 branch match blocks" "rc=$rc status=$(statusof DIVE-902) out=$out"

# --- T3: a PR that mentions the ident ONLY in its BODY does NOT block. ---------
#     (the fixture has no ident in title/headRefName -> client-side filter drops it)
seed DIVE-903
export GH_STUB_PRLIST='[{"number":903,"headRefName":"feat/other","title":"follow-up work"}]'
out=$(cmd_task_done DIVE-903 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-903)" == "done" ]] \
  && ok_t "T3 body-only mention (no title/branch match) closes normally" \
  || bad_t "T3 body-only does not block" "rc=$rc status=$(statusof DIVE-903) out=$out"

# --- T4: no matching PR at all -> a legitimate no-code close proceeds. ---------
seed DIVE-904
export GH_STUB_PRLIST='[]'
out=$(cmd_task_done DIVE-904 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-904)" == "done" ]] \
  && ok_t "T4 no matching PR => research/docs/no-code close proceeds" \
  || bad_t "T4 no-match closes" "rc=$rc status=$(statusof DIVE-904) out=$out"

# --- T5 (FAIL-OPEN): a slow gh (past the 5s timeout) must NOT block the close. -
seed DIVE-905
export GH_STUB_PRLIST='[{"number":905,"headRefName":"feat/DIVE-905","title":"DIVE-905 thing"}]'
export GH_STUB_HANG=7   # > the gate's `timeout 5s` -> killed -> empty -> fail-open
out=$(cmd_task_done DIVE-905 2>&1); rc=$?
unset GH_STUB_HANG
[[ $rc -eq 0 && "$(statusof DIVE-905)" == "done" ]] \
  && ok_t "T5 fail-open: a gh that hangs past the timeout does NOT block the fleet" \
  || bad_t "T5 fail-open on timeout" "rc=$rc status=$(statusof DIVE-905) out=$out"

# (gh-absent fail-open is the trivial `command -v gh` guard; not unit-tested here
#  because removing gh from PATH also removes sqlite3/date the close itself needs.)

# --- T7 (override): --force-merge-gate closes despite a blocking PR, AUDITED. --
seed DIVE-907
export GH_STUB_PRLIST='[{"number":907,"headRefName":"feat/DIVE-907","title":"DIVE-907 thing"}]'
: >"$AUDIT_CALLS"
out=$(cmd_task_done DIVE-907 --force-merge-gate 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof DIVE-907)" == "done" ]] \
  && ok_t "T7 --force-merge-gate overrides a blocking PR and closes" \
  || bad_t "T7 override closes" "rc=$rc status=$(statusof DIVE-907) out=$out"
grep -q 'task.force-merge-gate.*DIVE-907.*override_pr=907' "$AUDIT_CALLS" \
  && ok_t "T7 the forced close is written to the audit log with the overridden PR #" \
  || bad_t "T7 override audited" "audit=$(cat "$AUDIT_CALLS")"

# --- T8: a DECLARED-binding task is handled by the DIVE-1830 path, NOT this one
#     (auto-detect must be skipped when a delivery_ref exists — no double gate). -
seed DIVE-908
db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/908', delivered_at=datetime('now') WHERE ident='DIVE-908';"
export GH_STUB_PRLIST='[]'   # auto-detect would find nothing; DIVE-1830 gate must still run
export GH_STUB_STATE="" GH_STUB_MERGED=""
out=$(cmd_task_done DIVE-908 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && "$(statusof DIVE-908)" != "done" ]] \
  && ok_t "T8 declared delivery_ref still gated by the DIVE-1830 (fail-closed) path" \
  || bad_t "T8 declared path intact" "rc=$rc status=$(statusof DIVE-908) out=$out"

echo "-----"
printf 'task_merge_gate_autodetect_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
