#!/usr/bin/env bash
# TIER: nightly — 25.3s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
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
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
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
file_secret_gate() { seed_task "$1"; IS_ROOT=1 IDUN=root cmd_task_need "$1" --type=secret --ask="drop the fixture key" --secret-key=FIXTURE_TOKEN --connector=fixture --from=creative >/dev/null 2>&1; }

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
[[ $rc -ne 0 && "$(gate_open DIVE-202)" == "open" && "$out" == *"only the gate's filer"* ]] \
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
# the lead condition (in the org above, main is BOTH creative's lead AND the coordinator,
# so T3 cannot tell the two conditions apart and grades neither of them alone).
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('pi',NULL,'grok');"
file_pi_gate() { seed_task "$1"; IS_ROOT=1 IDUN=root cmd_task_need "$1" --type=secret --ask="drop the fixture key" --secret-key=FIXTURE_TOKEN --connector=fixture --from=pi >/dev/null 2>&1; }
z_lead=$(_gate_route_reviewer pi); z_coord=$(_task_resolve_coordinator)
[[ "$z_lead" == "grok" && "$z_coord" == "main" && "$z_lead" != "$z_coord" ]] \
  && ok_t "T-2382-DISTINCT pi's lead (grok) is NOT the coordinator (main) — the coordinator arm cannot pass through the lead condition" \
  || bad_t "T-2382-DISTINCT" "lead='$z_lead' coord='$z_coord'"

# T-2382a LIVENESS / mutation-decisive: the coordinator withdraws a gate whose filer does
# NOT report to them. Only condition 4 can authorize this. Delete condition 4 from
# src/cmd_task.sh and this arm goes RED.
file_pi_gate DIVE-240
[[ "$(gate_open DIVE-240)" == "open" ]] || bad_t "T-2382a precond" "open=$(gate_open DIVE-240)"
out=$(wd DIVE-240 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-240)" == "cleared" ]] \
  && ok_t "T-2382a org coordinator withdraws a gate filed OUTSIDE their reporting line (condition 4 is live)" \
  || bad_t "T-2382a coordinator withdraw" "rc=$rc open=$(gate_open DIVE-240) out=$out"

# T-2382b/c/d: the refusal on the SAME row, from a caller who is none of the four
# (creative is neither pi's lead nor the coordinator), names each route by its RESOLVED
# value — so a reader can act on it instead of deriving "nobody can retire this".
file_pi_gate DIVE-241
out=$(wd DIVE-241 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-241)" == "open" ]] \
  && ok_t "T-2382b unauthorized caller still refused" \
  || bad_t "T-2382b still refused" "rc=$rc open=$(gate_open DIVE-241) out=$out"
[[ "$out" == *"the org coordinator (main)"* ]] \
  && ok_t "T-2382c refusal names the ORG COORDINATOR by resolved value (was omitted entirely)" \
  || bad_t "T-2382c names coordinator" "out=$out"
[[ "$out" == *"their lead (grok)"* ]] \
  && ok_t "T-2382d refusal names the LEAD by resolved value, not the bare word 'lead'" \
  || bad_t "T-2382d names lead" "out=$out"

# T-2382e: filer == holder, so the "held by" clause must be ABSENT. Grading the clause's
# presence is worthless without this arm: a build that appends it unconditionally would
# pass every arm below.
[[ "$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='DIVE-241';")" == "pi" \
   && "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident='DIVE-241';")" == "pi" ]] \
  && ok_t "T-2382e precond: DIVE-241 was filed BY its holder (gate_filed_by=assignee=pi)" \
  || bad_t "T-2382e precond" "filed_by=$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='DIVE-241';") assignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident='DIVE-241';")"
[[ "$out" == *"the gate's filer (pi)"* && "$out" != *"held by"* ]] \
  && ok_t "T-2382e no handoff -> names the filer and omits the holder clause (clause is conditional, not decorative)" \
  || bad_t "T-2382e no-handoff clause" "out=$out"

# ══ DIVE-2382 PRINCIPAL REPLACE — the authorization site reads the FILER OF RECORD ══
# Approved by olivia (org coordinator); shape ruled by main. The site used to authorize on
# COALESCE(assignee,'') and now reads COALESCE(NULLIF(gate_filed_by,''),NULLIF(created_by,''),'').
# It was wrong in BOTH directions, so the suite must grade BOTH. The pair below is what
# makes this a NARROWING rather than a widening — an additive fifth authorizer would pass
# arm P1 and FAIL arm P2, and P2 is the one that was green before this change.
#
# Every arm PERFORMS a withdraw as a DISTINCT agent: filer=pi, holder=creative,
# filer's lead=grok, coordinator=main, human. A fixture that shares one name across two
# routes tests their union and neither (see T-2382-DISTINCT).
handoff_gate() {   # pi files it, then the row is REASSIGNED to creative
  file_pi_gate "$1"
  db "UPDATE tasks SET assignee='creative' WHERE ident='$1';"
}
handoff_gate DIVE-250
[[ "$(db "SELECT COALESCE(gate_filed_by,'')||'/'||COALESCE(assignee,'') FROM tasks WHERE ident='DIVE-250';")" == "pi/creative" ]] \
  && ok_t "T-2382-P precond: filer-of-record (pi) and holder (creative) are DISTINCT on the handoff row" \
  || bad_t "T-2382-P precond" "$(db "SELECT COALESCE(gate_filed_by,'')||'/'||COALESCE(assignee,'') FROM tasks WHERE ident='DIVE-250';")"

# P1 — UNDER-PERMISSIVE half, RED before this change: the agent who actually filed the
# gate can retire their own ask after the row was handed off.
out=$(wd DIVE-250 ROOT SU=agent-pi); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-250)" == "cleared" ]] \
  && ok_t "T-2382-P1 the FILER OF RECORD withdraws their own ask after a handoff (was REFUSED before the replace)" \
  || bad_t "T-2382-P1 filer withdraw" "rc=$rc open=$(gate_open DIVE-250) out=$out"

# P2 — OVER-PERMISSIVE half, GREEN before this change and it MUST FLIP. This is the arm
# that makes the suite grade a narrowing: a build that merely ADDED gate_filed_by as a
# fifth authorizer leaves this passing-as-authorized, i.e. passes on a widening.
handoff_gate DIVE-251
out=$(wd DIVE-251 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-251)" == "open" ]] \
  && ok_t "T-2382-P2 the reassigned HOLDER can NO LONGER retire a question they never asked (the DIVE-2133 shape; flipped by the replace)" \
  || bad_t "T-2382-P2 holder refused" "rc=$rc open=$(gate_open DIVE-251) out=$out"
[[ "$out" == *"the gate's filer (pi)"* && "$out" == *"held by creative"* && "$out" == *"does NOT authorize"* ]] \
  && ok_t "T-2382-P3 the refused holder is TOLD they hold it and that holding does not authorize (not omitted from the list)" \
  || bad_t "T-2382-P3 holder told why" "out=$out"

# P4 — the LEAD route follows the PRINCIPAL. grok is pi's lead and NOT creative's; before
# the replace this was refused, because the lead was resolved from the holder. Leaving it
# on the holder would have left a second copy of the same defect one rung up.
handoff_gate DIVE-252
out=$(wd DIVE-252 ROOT SU=agent-grok); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-252)" == "cleared" ]] \
  && ok_t "T-2382-P4 the FILER's lead (grok) withdraws; the lead route moved with the principal" \
  || bad_t "T-2382-P4 filer lead withdraw" "rc=$rc open=$(gate_open DIVE-252) out=$out"

# P5/P6 — the two FILER-INDEPENDENT routes still work on the same handoff shape, which is
# what guarantees no gate can be left with no authorizer.
handoff_gate DIVE-253
out=$(wd DIVE-253 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-253)" == "cleared" ]] \
  && ok_t "T-2382-P5 coordinator withdraws a handed-off gate (filer-independent route survives the replace)" \
  || bad_t "T-2382-P5 coordinator handoff" "rc=$rc open=$(gate_open DIVE-253) out=$out"
handoff_gate DIVE-254
out=$(wd DIVE-254 ROOT SD=0); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-254)" == "cleared" ]] \
  && ok_t "T-2382-P6 human withdraws a handed-off gate (filer-independent route survives the replace)" \
  || bad_t "T-2382-P6 human handoff" "rc=$rc open=$(gate_open DIVE-254) out=$out"

# P7 — olivia's AMENDMENT, and the arm that pins it. The authorization shape stops at
# created_by; it does NOT end on `assignee` the way :6154's display shape does. If it did,
# a row with BOTH gate_filed_by and created_by empty would silently RE-ADMIT the holder —
# the exact route being removed. Constructed by emptying both columns on a handoff row.
handoff_gate DIVE-255
db "UPDATE tasks SET gate_filed_by=NULL, created_by=NULL WHERE ident='DIVE-255';"
out=$(wd DIVE-255 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$(gate_open DIVE-255)" == "open" ]] \
  && ok_t "T-2382-P7 filer AND created_by empty -> the HOLDER is still refused (authorization does not fall back to assignee)" \
  || bad_t "T-2382-P7 no assignee fallback" "rc=$rc open=$(gate_open DIVE-255) out=$out"
# P8/P9 get their OWN rows on purpose. Reading them off P7's row made them CASCADE:
# under a mutation where the holder is authorized, P7's withdraw SUCCEEDS, so $out holds a
# success payload and the row has no gate left — P8 and P9 then red as consequences of P7
# rather than as independent signals, and three reds read as three findings when they are
# one. Each arm now constructs its own row.
handoff_gate DIVE-256
db "UPDATE tasks SET gate_filed_by=NULL, created_by=NULL WHERE ident='DIVE-256';"
out=$(wd DIVE-256 ROOT SU=agent-grok); rc=$?   # grok: not the holder, so refused either way
[[ $rc -ne 0 && "$out" == *"the gate's filer (unrecorded)"* ]] \
  && ok_t "T-2382-P8 an unresolvable principal renders as 'unrecorded', a stated absence rather than a '?' placeholder" \
  || bad_t "T-2382-P8 unrecorded" "rc=$rc out=$out"
# P9 — the gate is still retirable, which is why removing the assignee rung costs nothing:
# conditions 1 and 4 never consult the filer. Reachable by CONFIGURATION, not by data.
handoff_gate DIVE-257
db "UPDATE tasks SET gate_filed_by=NULL, created_by=NULL WHERE ident='DIVE-257';"
out=$(wd DIVE-257 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 && "$(gate_open DIVE-257)" == "cleared" ]] \
  && ok_t "T-2382-P9 an all-empty row is STILL retirable by the coordinator (no gate is left with no authorizer)" \
  || bad_t "T-2382-P9 still retirable" "rc=$rc open=$(gate_open DIVE-257) out=$out"

# T-2382g the DIVE-2106 shape: a carrier row with NO gate_filed_by, created by someone who
# is not the holder. This is the row two agents read the old refusal on and concluded
# nobody could ever retire it. The principal now falls back to created_by — so on the
# EXISTING population (gate_filed_by empty in 965 of 990 live rows) the authorizer is the
# CREATOR, a proxy for the filer, not the filer itself. Stated so nobody reads uniform
# filer semantics across the whole board.
file_pi_gate DIVE-243
db "UPDATE tasks SET gate_filed_by=NULL, created_by='main' WHERE ident='DIVE-243';"
out=$(wd DIVE-243 ROOT SU=agent-creative); rc=$?
[[ $rc -ne 0 && "$out" == *"the gate's filer (main)"* && "$out" == *"the org coordinator (main)"* ]] \
  && ok_t "T-2382g no gate_filed_by -> principal falls back to created_by AND the coordinator is still named (the DIVE-2106 dead-end)" \
  || bad_t "T-2382g legacy row naming" "rc=$rc out=$out"
out=$(wd DIVE-243 ROOT SU=agent-main); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "T-2382g-live the created_by proxy actually authorizes on a legacy row (not just rendered)" \
  || bad_t "T-2382g-live" "rc=$rc out=$out"

# ── DIVE-2382 red-team: --from is ATTRIBUTION ONLY on this path ────────────────────
# main's acceptance criterion. _gate_withdraw_actor judges by EUID-gated SUDO_* or the
# real id -un and NEVER by --from, so an unauthorized agent naming the filer must still
# be refused. Asserted here rather than left to the code comment.
handoff_gate DIVE-260
WD_EXTRA=(--from=pi); out=$(wd DIVE-260 NONROOT ID=agent-creative); rc=$?; WD_EXTRA=()
[[ $rc -ne 0 && "$(gate_open DIVE-260)" == "open" ]] \
  && ok_t "T-2382-R1 --from=<filer> spoof by an unauthorized agent REFUSED (--from is attribution, never authorization)" \
  || bad_t "T-2382-R1 from-spoof refused" "rc=$rc open=$(gate_open DIVE-260) out=$out"
handoff_gate DIVE-261
WD_EXTRA=(--from=pi); out=$(wd DIVE-261 ROOT SU=agent-creative); rc=$?; WD_EXTRA=()
[[ $rc -ne 0 && "$(gate_open DIVE-261)" == "open" ]] \
  && ok_t "T-2382-R2 same spoof at EUID0 with a real SUDO_USER of the HOLDER still REFUSED" \
  || bad_t "T-2382-R2 from-spoof root refused" "rc=$rc open=$(gate_open DIVE-261) out=$out"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
