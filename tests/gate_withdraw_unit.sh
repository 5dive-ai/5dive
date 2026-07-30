#!/usr/bin/env bash
# DIVE-1401 isolated unit harness for `task need --withdraw`: a lead/filer path to
# cancel a still-pending gate the team itself filed but that is now MOOT (e.g. a
# secret gate for fixtures never needed). Withdrawing is NOT a grant — it must never
# write need_answer/need_answered_at (never marks a secret as provided) — so it is
# safe for the gate's FILER, the filer's routed lead/coordinator, or a human to run
# without a human tap. Genuine GRANT-clears stay human-only (cmd_task_answer).
#
# SECURITY (olivia review, iters 1+2 — both real, both fixed):
#   iter1: --from is caller-asserted; id -un==root under sudo posed as human.
#   iter2: SUDO_USER/SUDO_UID are plain env a NON-root process can forge with no real
#          sudo, so trusting auto_sender_from_sudo/_gate_sudo_uid_nonagent UNCONDITION-
#          ally was forgeable one layer down.
# Fix: _gate_withdraw_actor trusts SUDO_* ONLY at EUID==0 (real sudo sets them
# truthfully); when non-root it IGNORES SUDO_* and judges by the unspoofable real
# `id -un`. --from is attribution-only. CRUCIALLY this harness exercises the REAL
# resolver — it does NOT stub auto_sender_from_sudo/_gate_sudo_uid_nonagent; it only
# seams _gate_is_root (EUID can't be reassigned in-process) and drives real env vars
# + a real id -un override. The env-forge case (T-FORGE) sets SUDO_USER/SUDO_UID that
# WOULD grant if trusted and proves a non-root caller is still judged by id -un only.
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR — the
# live shared tasks.db is NEVER touched. Run: bash tests/gate_withdraw_unit.sh
# (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
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
task_need_notify() { :; }   # don't DM on gate filing
audit_log() { :; }          # no root-owned audit log in this harness

# ── Caller-identity seams ─────────────────────────────────────────────────────
# Only _gate_is_root is stubbed ($EUID cannot be reassigned in-process). The REAL
# auto_sender_from_sudo / _gate_sudo_uid_nonagent run against real env vars, and the
# real id -un is driven by a thin `id` override. So we test the actual resolver logic
# and the actual EUID gate, not a reimplementation of it.
IS_ROOT=0
_gate_is_root() { [[ "$IS_ROOT" == "1" ]]; }
IDUN="nobody"   # real unix login for the non-root branch (unspoofable in prod)
id() { if [[ "${1:-}" == -un ]]; then echo "$IDUN"; else command id "$@"; fi; }

# DIVE-2330: src no longer reads `id -un` — it was PATH-resolved and therefore forgeable
# by the very caller it was authorizing. This harness pins identity through its own
# `id()` stub, so bridge that pin onto the two seams the resolver DOES read. The lookup
# is DYNAMIC (`$(id -un)` at call time), so re-pointing the stub mid-file keeps working.
# Production is unaffected: nothing in src consults `id` any more, and these two
# functions are defined by src itself on every real invocation.
_PIN_UID=987654
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
_gate_passwd_stream() {
  printf '%s:x:%s:%s::/nonexistent:/bin/false\n' "$(id -un)" "$_PIN_UID" "$_PIN_UID"
  printf '%s\n' "$(</etc/passwd)"
}

# Clean slate for the SUDO_* env the real helpers read; each case sets what it needs.
unset SUDO_USER SUDO_UID

# Run the withdraw under a chosen identity context. Usage:
#   wd <ident> ROOT|NONROOT [SUDO_USER=..] [SUDO_UID=..] [IDUN=..]
# Sets IS_ROOT + env + id-un override for THIS call only, then restores.
wd() {
  local ident="$1" mode="$2"; shift 2
  local _su="" _sd="" _idun="nobody" kv
  for kv in "$@"; do case "$kv" in SU=*) _su="${kv#SU=}";; SD=*) _sd="${kv#SD=}";; ID=*) _idun="${kv#ID=}";; esac; done
  local _oIS="$IS_ROOT" _oID="$IDUN"
  [[ "$mode" == ROOT ]] && IS_ROOT=1 || IS_ROOT=0
  IDUN="$_idun"
  if [[ -n "$_su" ]]; then export SUDO_USER="$_su"; else unset SUDO_USER; fi
  if [[ -n "$_sd" ]]; then export SUDO_UID="$_sd"; else unset SUDO_UID; fi
  cmd_task_need "$ident" --withdraw "${WD_EXTRA[@]}" 2>&1
  local rc=$?
  IS_ROOT="$_oIS"; IDUN="$_oID"; unset SUDO_USER SUDO_UID
  return $rc
}
WD_EXTRA=()

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
gate_open() { db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 'open' WHEN need_type IS NULL THEN 'cleared' ELSE 'answered' END FROM tasks WHERE ident='$1';"; }
statusof()  { db "SELECT status FROM tasks WHERE ident='$1';"; }
provby()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
ansat()     { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }

# Org: main=coordinator, creative reports to main (so its lead+coord is main); grok
# is a peer with no authority. File the gate as creative via --from (attribution).
db "CREATE TABLE IF NOT EXISTS agents_org (name TEXT PRIMARY KEY, role TEXT, title TEXT, reports_to TEXT);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','coordinator',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('creative',NULL,'main');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('grok',NULL,NULL);"
file_secret_gate() { seed_task "$1"; IS_ROOT=1 IDUN=root cmd_task_need "$1" --type=secret --ask="drop the fixture key" --from=creative >/dev/null 2>&1; }

# ── Root/sudo branch (agents commonly run `sudo 5dive ...`, EUID 0, SUDO_USER set) ──
# T1: the FILER (real SUDO_USER=agent-creative) withdraws its own secret gate. Gate
#     clears, task back to todo, and NO grant is recorded (answered_at/by stay empty).
file_secret_gate DIVE-201
[[ "$(gate_open DIVE-201)" == "open" && "$(statusof DIVE-201)" == "blocked" ]] \
  || bad_t "T1 precond" "open=$(gate_open DIVE-201) status=$(statusof DIVE-201)"
out=$(wd DIVE-201 ROOT SU=agent-creative); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-201)" == "cleared" && "$(statusof DIVE-201)" == "todo" ]] \
  && ok_t "T1 filer (real SUDO_USER) withdraws own secret gate -> cleared + todo" \
  || bad_t "T1 filer withdraw" "rc=$rc open=$(gate_open DIVE-201) status=$(statusof DIVE-201) out=$out"
[[ -z "$(ansat DIVE-201)" && -z "$(provby DIVE-201)" ]] \
  && ok_t "T1 NO grant recorded (answered_at + by stay empty — not a secret-provided)" \
  || bad_t "T1 no grant" "ansat='$(ansat DIVE-201)' provby='$(provby DIVE-201)'"

# T2: an unrelated agent (SUDO_USER=agent-grok) is REFUSED.
file_secret_gate DIVE-202
out=$(wd DIVE-202 ROOT SU=agent-grok); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-202)" == "open" && "$out" == *"only the gate's holder"* ]] \
  && ok_t "T2 unrelated agent REFUSED (gate untouched, actionable msg)" \
  || bad_t "T2 unrelated refused" "rc=$rc open=$(gate_open DIVE-202) out=$out"

# T3: the org lead/coordinator (SUDO_USER=agent-main) may withdraw creative's gate.
file_secret_gate DIVE-203
out=$(wd DIVE-203 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-203)" == "cleared" ]] \
  && ok_t "T3 org lead/coordinator withdraws a filer's gate" \
  || bad_t "T3 lead withdraw" "rc=$rc open=$(gate_open DIVE-203) out=$out"

# T5: a genuine human via sudo (EUID0, no SUDO_USER agent, non-agent SUDO_UID=0=root).
file_secret_gate DIVE-205
out=$(wd DIVE-205 ROOT SD=0); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-205)" == "cleared" ]] \
  && ok_t "T5 human via sudo (non-agent SUDO_UID) withdraws any pending gate" \
  || bad_t "T5 human sudo withdraw" "rc=$rc open=$(gate_open DIVE-205) out=$out"

# ── Non-root branch (agent runs 5dive directly, EUID != 0; SUDO_* untrusted) ───────
# Tnr1: the filer running directly (real id -un=agent-creative) still clears.
file_secret_gate DIVE-220
out=$(wd DIVE-220 NONROOT ID=agent-creative); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-220)" == "cleared" ]] \
  && ok_t "Tnr1 filer direct (non-root, id-un) withdraws own gate" \
  || bad_t "Tnr1 filer direct" "rc=$rc open=$(gate_open DIVE-220) out=$out"
# Tnr2: an unrelated agent direct (id -un=agent-grok) is REFUSED.
file_secret_gate DIVE-221
out=$(wd DIVE-221 NONROOT ID=agent-grok); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-221)" == "open" ]] \
  && ok_t "Tnr2 unrelated agent direct REFUSED" \
  || bad_t "Tnr2 unrelated direct" "rc=$rc open=$(gate_open DIVE-221) out=$out"
# Tnr3: a real human on the box direct (id -un=claude, non-agent) clears.
file_secret_gate DIVE-222
out=$(wd DIVE-222 NONROOT ID=claude); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-222)" == "cleared" ]] \
  && ok_t "Tnr3 human-on-box direct (non-agent id-un) withdraws" \
  || bad_t "Tnr3 human direct" "rc=$rc open=$(gate_open DIVE-222) out=$out"

# ── T-FORGE: the iter-2 bug, exercised end-to-end against the REAL resolver ────────
# A non-root agent (real id -un=agent-grok) forges the env that WOULD grant if trusted:
# SUDO_USER=agent-creative (auto_sender_from_sudo would return the FILER) and
# SUDO_UID=0 (_gate_sudo_uid_nonagent would return TRUE/human). Because EUID != 0 the
# resolver ignores both and judges by id -un=agent-grok -> REFUSED. This is exactly
# olivia's proof; before the EUID gate it was accepted.
file_secret_gate DIVE-230
out=$(wd DIVE-230 NONROOT SU=agent-creative SD=0 ID=agent-grok); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-230)" == "open" ]] \
  && ok_t "T-FORGE non-root env-forge (SUDO_USER=filer + SUDO_UID=non-agent) REFUSED — SUDO_* ignored when not root" \
  || bad_t "T-FORGE env forge refused" "rc=$rc open=$(gate_open DIVE-230) out=$out"
# Sanity: the SAME forged SUDO_USER=agent-creative, once EUID IS 0 (real sudo would
# have set it truthfully), correctly authorizes the filer — proving the refusal above
# is the EUID gate, not a blanket block.
file_secret_gate DIVE-231
out=$(wd DIVE-231 ROOT SU=agent-creative ID=agent-grok); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-231)" == "cleared" ]] \
  && ok_t "T-FORGE-sanity same SUDO_USER at EUID0 authorizes filer (refusal was the EUID gate)" \
  || bad_t "T-FORGE sanity" "rc=$rc open=$(gate_open DIVE-231) out=$out"

# ── Shape / lifecycle guards (identity-independent; run as an authorized caller) ──
# T4: an already-ANSWERED gate cannot be withdrawn.
seed_task DIVE-204
IS_ROOT=1 IDUN=root cmd_task_need DIVE-204 --type=decision --ask="pick lane" --options="A|B" --recommend="A" --tier=1 --from=creative >/dev/null 2>&1
IS_ROOT=1 IDUN=root cmd_task_answer DIVE-204 --value=A --human >/dev/null 2>&1
[[ "$(gate_open DIVE-204)" == "answered" ]] || bad_t "T4 precond answered" "open=$(gate_open DIVE-204)"
out=$(wd DIVE-204 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$out" == *"already answered"* ]] \
  && ok_t "T4 answered gate refuses --withdraw (only a pending gate)" \
  || bad_t "T4 answered refused" "rc=$rc out=$out"
# T6: --withdraw refuses to be combined with re-file flags.
file_secret_gate DIVE-206
WD_EXTRA=(--type=secret --ask=x); out=$(wd DIVE-206 ROOT SU=agent-creative); rc=$?; WD_EXTRA=()
[[ $rc -ne 0 && "$(gate_open DIVE-206)" == "open" && "$out" == *"no other gate flags"* ]] \
  && ok_t "T6 --withdraw + gate flags refused (shape stays honest)" \
  || bad_t "T6 withdraw+flags" "rc=$rc open=$(gate_open DIVE-206) out=$out"
# T7: --withdraw on a task with NO gate is a clean conflict, not a silent no-op.
seed_task DIVE-207
out=$(wd DIVE-207 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$out" == *"no gate to withdraw"* ]] \
  && ok_t "T7 no-gate task refuses --withdraw" \
  || bad_t "T7 no-gate" "rc=$rc out=$out"

# ── DIVE-2382: the refusal must name EVERY identity the authorizing block walked ──
# The shipped text named "the gate's filer, their lead, or a human" and dropped the ORG
# COORDINATOR — condition 4, which does not consult the filer at all. So a coordinator
# who WAS authorized read a message saying they were not, and two agents independently
# concluded from that text that a gate could never be retired. Both were wrong.
#
# Grading note, and it is the whole point: an assertion that merely greps the word
# "coordinator" in the message PASSES on a build where condition 4 was deleted and the
# text left behind — the exact shape that shipped. So the message arms are paired with a
# LIVENESS arm that actually withdraws AS the coordinator, which goes RED on that
# mutation, and with a DISTINCTNESS arm proving the coordinator is not reachable through
# the lead condition (in the org above, main is BOTH creative's lead and the coordinator,
# so T3 cannot tell the two conditions apart and grades neither of them alone).
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('pi',NULL,'grok');"
file_pi_gate() { seed_task "$1"; IS_ROOT=1 IDUN=root cmd_task_need "$1" --type=secret --ask="drop the fixture key" --from=pi >/dev/null 2>&1; }
z_lead=$(_gate_route_reviewer pi); z_coord=$(_task_resolve_coordinator)
[[ "$z_lead" == "grok" && "$z_coord" == "main" && "$z_lead" != "$z_coord" ]] \
  && ok_t "T-2382-DISTINCT pi's lead (grok) is NOT the coordinator (main) — the coordinator arm cannot pass through the lead condition" \
  || bad_t "T-2382-DISTINCT" "lead='$z_lead' coord='$z_coord'"

# T-2382a LIVENESS / mutation-decisive: the coordinator withdraws a gate held by an agent
# who does NOT report to them. Only condition 4 can authorize this. Delete condition 4
# from src/cmd_task.sh and this arm goes RED.
file_pi_gate DIVE-240
[[ "$(gate_open DIVE-240)" == "open" ]] || bad_t "T-2382a precond" "open=$(gate_open DIVE-240)"
out=$(wd DIVE-240 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-240)" == "cleared" ]] \
  && ok_t "T-2382a org coordinator withdraws a gate held OUTSIDE their reporting line (condition 4 is live)" \
  || bad_t "T-2382a coordinator withdraw" "rc=$rc open=$(gate_open DIVE-240) out=$out"

# T-2382b/c/d: the refusal on the SAME row, from a caller who is none of the four
# (creative is neither pi's lead nor the coordinator), names each route by its RESOLVED
# value — so a reader can act on it instead of deriving "nobody can retire this".
file_pi_gate DIVE-241
out=$(wd DIVE-241 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-241)" == "open" ]] \
  && ok_t "T-2382b unauthorized caller still refused (the fix is the message, not the policy)" \
  || bad_t "T-2382b still refused" "rc=$rc open=$(gate_open DIVE-241) out=$out"
[[ "$out" == *"the org coordinator (main)"* ]] \
  && ok_t "T-2382c refusal names the ORG COORDINATOR by resolved value (was omitted entirely)" \
  || bad_t "T-2382c names coordinator" "out=$out"
[[ "$out" == *"their lead (grok)"* ]] \
  && ok_t "T-2382d refusal names the LEAD by resolved value, not the bare word 'lead'" \
  || bad_t "T-2382d names lead" "out=$out"

# T-2382e: on a row where nothing was handed off, holder IS the filer-of-record — the
# "filed by" clause must NOT appear. Grading the clause's presence is worthless without
# this arm: a build that appends it unconditionally would pass every arm below.
[[ "$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='DIVE-241';")" == "pi" ]] \
  && ok_t "T-2382e precond: DIVE-241 was filed BY its holder (gate_filed_by=assignee=pi)" \
  || bad_t "T-2382e precond" "gate_filed_by=$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='DIVE-241';")"
[[ "$out" == *"holder (assignee pi)"* && "$out" != *"filed by"* ]] \
  && ok_t "T-2382e no handoff -> refusal names the holder and omits the filer clause (clause is conditional, not decorative)" \
  || bad_t "T-2382e no-handoff clause" "out=$out"

# T-2382f HANDOFF (DIVE-1945's case): pi files, the row is then reassigned to creative, so
# withdraw rights MOVE to creative and pi — who actually filed it — no longer holds them.
# The old text called creative "the gate's filer", naming as filer someone who never filed
# it, and gave pi no hint their own ask had left them.
file_pi_gate DIVE-242
db "UPDATE tasks SET assignee='creative' WHERE ident='DIVE-242';"   # what a reassign does
out=$(wd DIVE-242 ROOT SU=agent-grok); rc=$?
[[ $rc -ne 0 && "$out" == *"holder (assignee creative)"* && "$out" == *"filed by pi"* ]] \
  && ok_t "T-2382f handoff -> refusal names the HOLDER (creative) and the FILER-OF-RECORD (pi) separately" \
  || bad_t "T-2382f handoff naming" "rc=$rc out=$out"

# T-2382g the DIVE-2106 shape: a carrier row with NO gate_filed_by, created by someone who
# is not the holder. This is the row two agents read the old refusal on and concluded
# nobody could ever retire it. The message must now fall back to created_by AND name the
# coordinator, which is who could in fact have retired it all along.
file_pi_gate DIVE-243
db "UPDATE tasks SET gate_filed_by=NULL WHERE ident='DIVE-243';"    # legacy / auto-created row
out=$(wd DIVE-243 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$out" == *"filed by main"* && "$out" == *"the org coordinator (main)"* ]] \
  && ok_t "T-2382g no gate_filed_by -> falls back to created_by AND still names the coordinator (the DIVE-2106 dead-end)" \
  || bad_t "T-2382g legacy row naming" "rc=$rc out=$out"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
