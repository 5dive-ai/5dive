#!/usr/bin/env bash
# DIVE-1401 isolated unit harness for `task need --withdraw`: a lead/filer path to
# cancel a still-pending gate the team itself filed but that is now MOOT (e.g. a
# secret gate for fixtures never needed). Withdrawing is NOT a grant — it must never
# write need_answer/need_answered_at (never marks a secret as provided) — so it is
# safe for the gate's FILER, the filer's routed lead/coordinator, or a human to run
# without a human tap. Genuine GRANT-clears stay human-only (cmd_task_answer).
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR — the
# live shared tasks.db is NEVER touched. Run: bash tests/gate_withdraw_unit.sh
# (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-withdraw-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Don't DM on gate filing; no root-owned audit log in this harness.
task_need_notify() { :; }
audit_log() { :; }

# The immediate caller identity (`id -un`) is overridable so we can simulate an
# agent caller vs. a human-on-box login. Default: an agent (so the human carve-out
# never masks the filer/lead authorization we mean to test).
FAKE_CALLER="agent-grok"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

# Org chart: main=coordinator, creative reports to main. So creative's routed lead
# (and the org coordinator) is main; grok reports nowhere (a peer with no authority).
db "CREATE TABLE IF NOT EXISTS agents_org (name TEXT PRIMARY KEY, role TEXT, title TEXT, reports_to TEXT);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','coordinator',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('creative',NULL,'main');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('grok',NULL,NULL);"

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
gate_open() { db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 'open' WHEN need_type IS NULL THEN 'cleared' ELSE 'answered' END FROM tasks WHERE ident='$1';"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
provby()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
ansat()     { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }

# --- T1: the FILER withdraws its own still-pending secret gate --------------------
#     Gate clears, task returns to todo, and — critically — need_answer/answered_at
#     stay NULL and need_answered_by stays empty: NO secret is recorded as provided.
seed_task DIVE-201
cmd_task_need DIVE-201 --type=secret --ask="drop the fixture key" --from=creative >/dev/null 2>&1
[[ "$(gate_open DIVE-201)" == "open" && "$(statusof DIVE-201)" == "blocked" ]] \
  || bad_t "T1 precond: secret gate filed + task blocked" "open=$(gate_open DIVE-201) status=$(statusof DIVE-201)"
FAKE_CALLER="agent-creative"
out=$(cmd_task_need DIVE-201 --withdraw --from=creative 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-201)" == "cleared" ]] \
  && ok_t "T1 filer withdraws its own pending secret gate (cleared)" \
  || bad_t "T1 filer withdraw clears gate" "rc=$rc open=$(gate_open DIVE-201) out=$out"
[[ "$(statusof DIVE-201)" == "todo" ]] \
  && ok_t "T1 task unblocked back to todo" \
  || bad_t "T1 unblocked to todo" "status=$(statusof DIVE-201)"
[[ -z "$(ansat DIVE-201)" && -z "$(provby DIVE-201)" ]] \
  && ok_t "T1 NO grant recorded (need_answered_at + by stay empty — not a secret-provided)" \
  || bad_t "T1 no grant recorded" "ansat='$(ansat DIVE-201)' provby='$(provby DIVE-201)'"

# --- T2: an unrelated agent (not filer, not lead, not coordinator) is REFUSED -----
seed_task DIVE-202
cmd_task_need DIVE-202 --type=secret --ask="drop the fixture key" --from=creative >/dev/null 2>&1
FAKE_CALLER="agent-grok"
out=$(cmd_task_need DIVE-202 --withdraw --from=grok 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-202)" == "open" ]] \
  && ok_t "T2 non-filer/non-lead agent REFUSED (gate untouched)" \
  || bad_t "T2 unrelated agent refused" "rc=$rc open=$(gate_open DIVE-202) out=$out"
[[ "$out" == *"only the gate's filer"* ]] \
  && ok_t "T2 refusal carries an actionable message" \
  || bad_t "T2 actionable message" "out=$out"

# --- T3: the org LEAD / coordinator (main) may withdraw creative's gate -----------
seed_task DIVE-203
cmd_task_need DIVE-203 --type=secret --ask="drop the fixture key" --from=creative >/dev/null 2>&1
FAKE_CALLER="agent-main"
out=$(cmd_task_need DIVE-203 --withdraw --from=main 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-203)" == "cleared" && "$(statusof DIVE-203)" == "todo" ]] \
  && ok_t "T3 org lead/coordinator withdraws a filer's gate" \
  || bad_t "T3 lead withdraw" "rc=$rc open=$(gate_open DIVE-203) status=$(statusof DIVE-203) out=$out"

# --- T4: an already-ANSWERED gate cannot be withdrawn (only need_answered_at NULL) -
seed_task DIVE-204
cmd_task_need DIVE-204 --type=decision --ask="pick lane" --options="A|B" --recommend="A" --tier=1 --from=creative >/dev/null 2>&1
cmd_task_answer DIVE-204 --value=A >/dev/null 2>&1   # tier-1 decision: agent-clearable
[[ "$(gate_open DIVE-204)" == "answered" ]] || bad_t "T4 precond answered" "open=$(gate_open DIVE-204)"
FAKE_CALLER="agent-creative"
out=$(cmd_task_need DIVE-204 --withdraw --from=creative 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"already answered"* ]] \
  && ok_t "T4 answered gate refuses --withdraw (only a pending gate)" \
  || bad_t "T4 answered gate refused" "rc=$rc out=$out"

# --- T5: a HUMAN caller (non-agent unix id) may always withdraw -------------------
seed_task DIVE-205
cmd_task_need DIVE-205 --type=manual --ask="do the manual step" --from=creative >/dev/null 2>&1
FAKE_CALLER="root"
out=$(cmd_task_need DIVE-205 --withdraw 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-205)" == "cleared" ]] \
  && ok_t "T5 human caller withdraws any pending gate" \
  || bad_t "T5 human withdraw" "rc=$rc open=$(gate_open DIVE-205) out=$out"

# --- T6: --withdraw refuses to be combined with re-file flags ---------------------
seed_task DIVE-206
cmd_task_need DIVE-206 --type=secret --ask="drop key" --from=creative >/dev/null 2>&1
FAKE_CALLER="agent-creative"
out=$(cmd_task_need DIVE-206 --withdraw --type=secret --ask="x" --from=creative 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-206)" == "open" && "$out" == *"no other gate flags"* ]] \
  && ok_t "T6 --withdraw + gate flags refused (shape stays honest)" \
  || bad_t "T6 withdraw + flags refused" "rc=$rc open=$(gate_open DIVE-206) out=$out"

# --- T7: --withdraw on a task with NO gate is a clean conflict, not a silent no-op -
seed_task DIVE-207
FAKE_CALLER="agent-creative"
out=$(cmd_task_need DIVE-207 --withdraw --from=creative 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"no gate to withdraw"* ]] \
  && ok_t "T7 no-gate task refuses --withdraw" \
  || bad_t "T7 no-gate refused" "rc=$rc out=$out"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
