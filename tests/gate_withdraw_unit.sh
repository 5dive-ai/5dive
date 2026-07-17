#!/usr/bin/env bash
# DIVE-1401 isolated unit harness for `task need --withdraw`: a lead/filer path to
# cancel a still-pending gate the team itself filed but that is now MOOT (e.g. a
# secret gate for fixtures never needed). Withdrawing is NOT a grant — it must never
# write need_answer/need_answered_at (never marks a secret as provided) — so it is
# safe for the gate's FILER, the filer's routed lead/coordinator, or a human to run
# without a human tap. Genuine GRANT-clears stay human-only (cmd_task_answer).
#
# SECURITY (olivia review, DIVE-1401): authorization binds to the TRUSTED caller
# identity, NEVER to --from (caller-asserted) and NEVER to `id -un != agent-*` (the
# one-sudo forge). The trusted agent id is auto_sender_from_sudo (SUDO_USER, survives
# sudo); a genuine human is a non-agent SUDO_UID (_gate_sudo_uid_nonagent), mirroring
# cmd_task_answer. This harness stubs those two trust primitives so it can drive the
# caller identity independently of --from, and explicitly exercises BOTH bypasses:
#   (a) an unauthorized agent passing --from=<filer> is still REFUSED, and
#   (b) an agent under sudo (root uid) is NOT treated as human.
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

# ── Controlled caller identity ───────────────────────────────────────────────
# CALLER_AGENT: the TRUSTED agent name resolved from SUDO_USER/id-un (empty = the
#   caller is not an agent — a human/root/dashboard path). Stubs the exact primitive
#   the withdraw auth uses, so --from can be set independently to prove it's ignored.
# CALLER_HUMAN: 1 iff the caller is a genuine non-agent SUDO_UID (a real human path).
#   An agent that merely `sudo`s (root uid, but SUDO_UID=its agent uid) is NOT human.
CALLER_AGENT=""
CALLER_HUMAN=0
auto_sender_from_sudo() { printf '%s' "$CALLER_AGENT"; }
_gate_sudo_uid_nonagent() { [[ "$CALLER_HUMAN" == "1" ]]; }
# Belt-and-suspenders: the auth's id-un fallback only runs when auto_sender is empty;
# keep it non-agent so it never accidentally grants an agent identity in the harness.
id() { if [[ "${1:-}" == -un ]]; then echo "root"; else command id "$@"; fi; }

# Filing a gate resolves assignee via task_actor("$from"); pass --from so the FILER
# of record is deterministic regardless of the trusted-caller stubs above.
seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
gate_open() { db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 'open' WHEN need_type IS NULL THEN 'cleared' ELSE 'answered' END FROM tasks WHERE ident='$1';"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
provby()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
ansat()     { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }

# Org chart: main=coordinator, creative reports to main. So creative's routed lead
# (and the org coordinator) is main; grok reports nowhere (a peer with no authority).
db "CREATE TABLE IF NOT EXISTS agents_org (name TEXT PRIMARY KEY, role TEXT, title TEXT, reports_to TEXT);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','coordinator',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('creative',NULL,'main');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('grok',NULL,NULL);"

file_secret_gate() { seed_task "$1"; CALLER_AGENT="creative" CALLER_HUMAN=0 cmd_task_need "$1" --type=secret --ask="drop the fixture key" --from=creative >/dev/null 2>&1; }

# --- T1: the FILER withdraws its own still-pending secret gate --------------------
#     Gate clears, task returns to todo, and — critically — need_answer/answered_at
#     stay NULL and need_answered_by stays empty: NO secret is recorded as provided.
file_secret_gate DIVE-201
[[ "$(gate_open DIVE-201)" == "open" && "$(statusof DIVE-201)" == "blocked" ]] \
  || bad_t "T1 precond: secret gate filed + task blocked" "open=$(gate_open DIVE-201) status=$(statusof DIVE-201)"
out=$(CALLER_AGENT="creative" CALLER_HUMAN=0 cmd_task_need DIVE-201 --withdraw 2>&1); rc=$?
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
file_secret_gate DIVE-202
out=$(CALLER_AGENT="grok" CALLER_HUMAN=0 cmd_task_need DIVE-202 --withdraw 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-202)" == "open" ]] \
  && ok_t "T2 non-filer/non-lead agent REFUSED (gate untouched)" \
  || bad_t "T2 unrelated agent refused" "rc=$rc open=$(gate_open DIVE-202) out=$out"
[[ "$out" == *"only the gate's filer"* ]] \
  && ok_t "T2 refusal carries an actionable message" \
  || bad_t "T2 actionable message" "out=$out"

# --- T3: the org LEAD / coordinator (main) may withdraw creative's gate -----------
file_secret_gate DIVE-203
out=$(CALLER_AGENT="main" CALLER_HUMAN=0 cmd_task_need DIVE-203 --withdraw 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-203)" == "cleared" && "$(statusof DIVE-203)" == "todo" ]] \
  && ok_t "T3 org lead/coordinator withdraws a filer's gate" \
  || bad_t "T3 lead withdraw" "rc=$rc open=$(gate_open DIVE-203) status=$(statusof DIVE-203) out=$out"

# --- T4: an already-ANSWERED gate cannot be withdrawn (only need_answered_at NULL) -
seed_task DIVE-204
CALLER_AGENT="creative" cmd_task_need DIVE-204 --type=decision --ask="pick lane" --options="A|B" --recommend="A" --tier=1 --from=creative >/dev/null 2>&1
CALLER_AGENT="creative" cmd_task_answer DIVE-204 --value=A >/dev/null 2>&1   # tier-1 decision: agent-clearable
[[ "$(gate_open DIVE-204)" == "answered" ]] || bad_t "T4 precond answered" "open=$(gate_open DIVE-204)"
out=$(CALLER_AGENT="creative" CALLER_HUMAN=0 cmd_task_need DIVE-204 --withdraw 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"already answered"* ]] \
  && ok_t "T4 answered gate refuses --withdraw (only a pending gate)" \
  || bad_t "T4 answered gate refused" "rc=$rc out=$out"

# --- T5: a genuine HUMAN caller (non-agent SUDO_UID) may always withdraw ----------
seed_task DIVE-205
CALLER_AGENT="creative" cmd_task_need DIVE-205 --type=manual --ask="do the manual step" --from=creative >/dev/null 2>&1
out=$(CALLER_AGENT="" CALLER_HUMAN=1 cmd_task_need DIVE-205 --withdraw 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-205)" == "cleared" ]] \
  && ok_t "T5 genuine human caller (non-agent SUDO_UID) withdraws any pending gate" \
  || bad_t "T5 human withdraw" "rc=$rc open=$(gate_open DIVE-205) out=$out"

# --- T6: --withdraw refuses to be combined with re-file flags ---------------------
file_secret_gate DIVE-206
out=$(CALLER_AGENT="creative" CALLER_HUMAN=0 cmd_task_need DIVE-206 --withdraw --type=secret --ask="x" 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-206)" == "open" && "$out" == *"no other gate flags"* ]] \
  && ok_t "T6 --withdraw + gate flags refused (shape stays honest)" \
  || bad_t "T6 withdraw + flags refused" "rc=$rc open=$(gate_open DIVE-206) out=$out"

# --- T7: --withdraw on a task with NO gate is a clean conflict, not a silent no-op -
seed_task DIVE-207
out=$(CALLER_AGENT="creative" CALLER_HUMAN=0 cmd_task_need DIVE-207 --withdraw 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"no gate to withdraw"* ]] \
  && ok_t "T7 no-gate task refuses --withdraw" \
  || bad_t "T7 no-gate refused" "rc=$rc out=$out"

# ── SECURITY REGRESSIONS (olivia review) ─────────────────────────────────────────
# --- T8: BYPASS #1 — --from is caller-asserted. An UNAUTHORIZED agent (grok) that
#     passes --from=<filer> must STILL be REFUSED. Auth reads the trusted identity
#     (CALLER_AGENT=grok), never --from. This case did not exist before the fix and
#     is exactly the impersonation olivia flagged.
file_secret_gate DIVE-208
out=$(CALLER_AGENT="grok" CALLER_HUMAN=0 cmd_task_need DIVE-208 --withdraw --from=creative 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-208)" == "open" ]] \
  && ok_t "T8 unauthorized agent spoofing --from=<filer> is REFUSED (auth ignores --from)" \
  || bad_t "T8 --from spoof refused" "rc=$rc open=$(gate_open DIVE-208) out=$out"
# And a lead/coordinator impersonation via --from is equally powerless.
file_secret_gate DIVE-209
out=$(CALLER_AGENT="grok" CALLER_HUMAN=0 cmd_task_need DIVE-209 --withdraw --from=main 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-209)" == "open" ]] \
  && ok_t "T8b unauthorized agent spoofing --from=<coordinator> is REFUSED" \
  || bad_t "T8b --from coordinator spoof refused" "rc=$rc open=$(gate_open DIVE-209) out=$out"

# --- T9: BYPASS #2 — sudo != human. An agent that runs under `sudo` has id -un=root
#     but SUDO_UID=its own agent uid, so _gate_sudo_uid_nonagent is FALSE (CALLER_HUMAN=0)
#     while its trusted identity stays the agent (grok). It must be treated as the
#     agent (unauthorized here), NOT as a human. This is the one-sudo forge.
file_secret_gate DIVE-210
out=$(CALLER_AGENT="grok" CALLER_HUMAN=0 cmd_task_need DIVE-210 --withdraw 2>&1); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-210)" == "open" ]] \
  && ok_t "T9 agent under sudo (root uid, agent SUDO_UID) is NOT human — REFUSED" \
  || bad_t "T9 sudo-agent not human" "rc=$rc open=$(gate_open DIVE-210) out=$out"
# Sanity: the SAME flow, once the caller is genuinely the coordinator identity, DOES
# clear — proving T9's refusal is the human/authority check, not a blanket block.
file_secret_gate DIVE-211
out=$(CALLER_AGENT="main" CALLER_HUMAN=0 cmd_task_need DIVE-211 --withdraw 2>&1); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-211)" == "cleared" ]] \
  && ok_t "T9b coordinator identity (not via sudo-human) still clears — refusal was authority, not a block" \
  || bad_t "T9b coordinator clears" "rc=$rc open=$(gate_open DIVE-211) out=$out"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
