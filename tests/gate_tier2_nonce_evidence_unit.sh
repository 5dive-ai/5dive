#!/usr/bin/env bash
# DIVE-1448 isolated unit harness: tier-2 gate answers require CRYPTOGRAPHIC human
# evidence regardless of need_type. Before this fix a `decision` gate floored to
# tier 2 minted NO per-gate nonce, and the answer side TRUSTED the bare --human
# provenance flag — which an agent forges via `sudo task answer --human`
# (SUDO_UID=agent). Genuine tap and forged answer produced IDENTICAL rows
# (the FUNNE-3 / DIVE-1446 incident). The fix: mint the nonce for EVERY tier>=2
# gate, and on the answer side demand a real evidence form (valid --human-proof
# nonce OR a non-agent SUDO_UID OR a routed lead-clear); a nonce-less LEGACY gate
# falls back to the DIVE-1117 provenance floor for backward-compat.
# Isolation: source src/ libs, throwaway STATE_DIR — the live shared tasks.db is
# NEVER touched. Run: bash tests/gate_tier2_nonce_evidence_unit.sh (no root, no net).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-1448-unit.XXXXXX)"

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
touch "$GATE_PROOF_ENFORCE"   # enforcement ON

# No DM on gate filing. Capture audit rows to a file so we can assert on them.
task_need_notify() { :; }
AUDIT_LOG_FILE="$TMP/audit.log"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
# RE-LAND REPAIR (DIVE-2389): this harness predates DIVE-2010. Gate rows now route
# through `_task_store_audit_log`, a FENCE that calls audit_log ONLY when TASKS_DB is
# the production store, so on a fixture DB the row is deliberately WITHHELD and both
# audit assertions became structurally unsatisfiable. They failed because the fence
# WORKS. Open it for this fixture; the stub above stays the sink.
_task_human_send_allowed() { return 0; }

# Deterministic nonce so the "valid tap" case can present the right --human-proof.
KNOWN_NONCE="deadbeefdeadbeefdeadbeefdeadbeef"
_human_nonce_mint() { printf '%s' "$KNOWN_NONCE"; }

# The DIVE-916 non-agent-SUDO_UID evidence form is controllable so each case picks
# whether the immediate (pre-sudo) caller is an agent (the forge) or not (human/box).
FAKE_NONAGENT=1   # 1 = non-agent (human), 0 = agent (forge)
_gate_sudo_uid_nonagent() { [[ "$FAKE_NONAGENT" == "1" ]]; }
# DIVE-2371: the AUTHORIZATION sites no longer ask the uid alone. They call
# `_gate_human_principal`, which requires the uid test AND a structural cgroup
# test, so the single switch above has to drive BOTH halves — otherwise every arm
# below reads the HOST's real cgroup (an agent unit here, a runner cgroup on CI),
# the tier-2 guard refuses correctly, and its pre-existing `fail 6` exits this
# unsubshelled harness at rc=6 instead of grading. Stub the READER only, exactly
# as tests/gate_cgroup_human_principal_unit.sh does; the accept/deny logic stays
# the shipped bytes. Deliberately NOT an env var the product reads — a widening
# knob on a fail-closed accept list is the forge class this row closes.
_gate_caller_cgroup() {
  if [[ "$FAKE_NONAGENT" == "1" ]]; then printf '%s' '/system.slice/shelld.service'
  else printf '%s' '/system.slice/system-5dive.slice/5dive-agent@dev.service'; fi
}
# LIVENESS, BOTH DIRECTIONS. A stub that stops being called fails CLOSED here (the
# real /proc read refuses and truncates, loudly), but a stub wired to the wrong
# SENSE fails open — so assert the negative too, before any arm leans on it.
FAKE_NONAGENT=1; _gate_human_principal \
  || { printf 'NOT OK - human-principal pin inert: FAKE_NONAGENT=1 did not read as a human principal\n'; exit 1; }
FAKE_NONAGENT=0; _gate_human_principal \
  && { printf 'NOT OK - human-principal pin inert: FAKE_NONAGENT=0 read as a human principal\n'; exit 1; }
FAKE_NONAGENT=1
# Keep the CALLER a non-agent so the DIVE-394 caller-uid block never masks the
# result. DIVE-2601: this was an `id -un` stub, which the derivation has not read
# since DIVE-2330 — measured at ZERO calls here, so the caller's agent-ness was
# decided by whoever ran the suite. uid 0 is root everywhere and no agent claims it.
_PIN_UID=0
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
# LIVENESS FIRST, and this is the arm iteration 2 was missing. The unclaimed check
# below FAILS OPEN: an unsourced lib/actor.sh, a renamed resolver, a typo — every one
# of them arrives as '', which IS the pass value. Measured: this file omitted
# lib/actor.sh from the source list above, so `_gate_uid_to_agent` was
# command-not-found, `_pin_check` was unconditionally empty, and the check was
# asserting that the empty string is empty. It could not fail, and the eleven arms
# below ran with the product's actor derivation missing underneath them.
# The probe pins a SYNTHETIC passwd row in a subshell, so the POSITIVE case holds on
# any host — including a CI runner where no agent-* account exists.
_probe="$(
  _gate_passwd_stream() { printf 'agent-probe:x:424242:424242::/nonexistent:/bin/false\n'; }
  _gate_uid_to_agent 424242
)"
[[ "$_probe" == "probe" ]] \
  || { printf 'NOT OK - the identity resolver is not live: _gate_uid_to_agent returned %s for a synthetic agent-probe row (expected probe). Is lib/actor.sh in the source list?\n' "'$_probe'"; exit 1; }
_pin_check="$(_gate_uid_to_agent "$(_gate_caller_uid)")"
[[ -z "$_pin_check" ]] \
  || { printf 'NOT OK - identity pin is inert: uid %s resolved to agent %s, expected a NON-agent caller\n' "$_PIN_UID" "'$_pin_check'"; exit 1; }

seed()    { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
answered(){ db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provby()  { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
nhash()   { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }

# --- T1: a tier-2 decision gate now MINTS a per-gate nonce (it did not before). ---
seed DIVE-201
cmd_task_need DIVE-201 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
[[ -n "$(nhash DIVE-201)" ]] \
  && ok_t "T1 tier-2 decision gate mints a per-gate human nonce" \
  || bad_t "T1 nonce minted on tier-2 decision" "human_nonce_hash empty"

# --- T2: THE FORGE — an agent's `sudo task answer --human` (SUDO_UID=agent, no
#     nonce) on the same gate is REFUSED. This is the FUNNE-3 / DIVE-1446 hole. ----
FAKE_NONAGENT=0
out=$(cmd_task_answer DIVE-201 --value=A --human 2>&1); rc=$?
[[ "$(answered DIVE-201)" == "open" && $rc -ne 0 ]] \
  && ok_t "T2 forged agent --human (no nonce) on tier-2 decision REFUSED" \
  || bad_t "T2 forge refused" "rc=$rc state=$(answered DIVE-201) out=$out"
# RE-LAND REPAIR (DIVE-2389): this asserted the event name `task answer gate`. A
# forged `--human` with no nonce takes the (( human )) arm, and DIVE-2233 split that
# arm's telemetry onto its OWN event, `task answer t2-human-evidence`. MEASURED at
# this exact point: the row IS written and DOES carry tier=2 and the error verdict —
# `task answer t2-human-evidence error 0 -- task=DIVE-201 type=decision tier=2
# nonce_valid=0 sudo_nonagent=0 human_proof=absent`. So the coverage this arm exists
# to demand is present; only the name it was written against moved. Accept either,
# because both are honest names for "a tier-2 refusal was audited".
grep -qE 'answer (gate|t2-human-evidence).*error.*tier=2' "$AUDIT_LOG_FILE" \
  && ok_t "T2 refusal wrote an audit row (forensics trail)" \
  || bad_t "T2 audit row on refusal" "no error row in $AUDIT_LOG_FILE"

# --- T3: the genuine plugin TAP forwards the nonce as --human-proof (SUDO_UID still
#     agent) — accepted, recorded human:*. DIVE-525: a real tap is never blocked. --
out=$(cmd_task_answer DIVE-201 --value=A --human --human-proof="$KNOWN_NONCE" 2>&1); rc=$?
[[ "$(answered DIVE-201)" == "closed" && $rc -eq 0 ]] \
  && ok_t "T3 valid --human-proof nonce on tier-2 decision CLEARS (the real tap)" \
  || bad_t "T3 valid nonce clears" "rc=$rc state=$(answered DIVE-201) out=$out"
case "$(provby DIVE-201)" in human:*) ok_t "T3 provenance recorded human:*" ;; *) bad_t "T3 provenance human:*" "got '$(provby DIVE-201)'" ;; esac

# --- T4: a WRONG nonce (agent guessing) is refused. --------------------------------
seed DIVE-202
cmd_task_need DIVE-202 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
FAKE_NONAGENT=0
out=$(cmd_task_answer DIVE-202 --value=A --human --human-proof="00000000000000000000000000000000" 2>&1); rc=$?
[[ "$(answered DIVE-202)" == "open" && $rc -ne 0 ]] \
  && ok_t "T4 wrong --human-proof nonce REFUSED" \
  || bad_t "T4 wrong nonce refused" "rc=$rc state=$(answered DIVE-202) out=$out"

# --- T5: the dashboard/human-on-box path (non-agent SUDO_UID, no nonce) CLEARS. ----
seed DIVE-203
cmd_task_need DIVE-203 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
FAKE_NONAGENT=1
cmd_task_answer DIVE-203 --value=A --human >/dev/null 2>&1
[[ "$(answered DIVE-203)" == "closed" ]] \
  && ok_t "T5 dashboard principal (non-agent uid + shelld cgroup) clears tier-2 decision" \
  || bad_t "T5 dashboard principal clears" "still $(answered DIVE-203)"

# --- T5b: DIVE-2371, THE FORGE THIS ROW CLOSES, on the AUTHORIZATION path. Same
#     non-agent uid as T5 — only the cgroup differs — so the gate must REFUSE.
#     Without this arm T5's green is satisfied by the uid half ALONE and the
#     structural half is unpinned here: gate_cgroup_human_principal_unit.sh grades
#     the predicate in isolation, nothing graded it through cmd_task_answer. This
#     is the arm that reds if someone reverts _gate_human_principal to the uid test.
#     Subshelled via $( ) because the refusal is a `fail 6` exit BY DESIGN.
seed DIVE-290
cmd_task_need DIVE-290 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
FAKE_NONAGENT=1
_cg_saved=$(declare -f _gate_caller_cgroup)
_gate_caller_cgroup() { printf '%s' '/system.slice/system-5dive.slice/5dive-agent@dev.service'; }
out=$(cmd_task_answer DIVE-290 --value=A --human 2>&1); rc=$?
[[ "$(answered DIVE-290)" == "open" && $rc -ne 0 ]] \
  && ok_t "T5b agent CGROUP with a non-agent uid is REFUSED (the bare --human tier-2 forge)" \
  || bad_t "T5b agent cgroup refused" "rc=$rc state=$(answered DIVE-290) out=$out — structural half not reached on the answer path"
eval "$_cg_saved"

# --- T6: BACKWARD-COMPAT — a LEGACY tier-2 decision with NO stored nonce falls back
#     to the DIVE-1117 provenance floor: a real human --human tap still clears even
#     though its original message carried no nonce (an in-flight pre-fix gate). -----
seed DIVE-204
cmd_task_need DIVE-204 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
db "UPDATE tasks SET human_nonce_hash=NULL WHERE ident='DIVE-204';"   # simulate a pre-DIVE-1448 row
FAKE_NONAGENT=0   # plugin tap = agent SUDO_UID, no nonce available on the old message
cmd_task_answer DIVE-204 --value=A --human >/dev/null 2>&1
[[ "$(answered DIVE-204)" == "closed" ]] \
  && ok_t "T6 legacy nonce-less tier-2 gate: --human tap clears (provenance fallback)" \
  || bad_t "T6 legacy fallback clears" "still $(answered DIVE-204)"

# --- T7: legacy fallback still rejects a NON-human (no --human) agent answer. -------
seed DIVE-205
cmd_task_need DIVE-205 --type=decision --ask="ship it?" --options="A|B" --recommend="A" --tier=2 --rubber-stamp-ok="fixture: this case needs a real hard-human tier-2 gate to grade; DIVE-2848 caps the hand-typed shape" >/dev/null 2>&1
db "UPDATE tasks SET human_nonce_hash=NULL WHERE ident='DIVE-205';"
FAKE_NONAGENT=0
out=$(cmd_task_answer DIVE-205 --value=A 2>&1); rc=$?
[[ "$(answered DIVE-205)" == "open" && $rc -ne 0 ]] \
  && ok_t "T7 legacy nonce-less gate still refuses a non-human agent answer" \
  || bad_t "T7 legacy non-human refused" "rc=$rc state=$(answered DIVE-205) out=$out"

# --- T8: audit trail exists for an ordinary (tier-1) decision answer — the DIVE-1448
#     (b) gap: decision answers previously left NO audit row at all. ---------------
: > "$AUDIT_LOG_FILE"
seed DIVE-206
cmd_task_need DIVE-206 --type=decision --ask="pick lane" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
FAKE_NONAGENT=0
cmd_task_answer DIVE-206 --value=A >/dev/null 2>&1
[[ "$(answered DIVE-206)" == "closed" ]] \
  && ok_t "T8 tier-1 decision answer still clears (agent-clearable, unchanged)" \
  || bad_t "T8 tier-1 decision clears" "still $(answered DIVE-206)"
grep -q 'answer gate.*type=decision' "$AUDIT_LOG_FILE" \
  && ok_t "T8 tier-1 decision answer now writes an audit row (DIVE-1448 (b))" \
  || bad_t "T8 decision audit row" "no decision row in $AUDIT_LOG_FILE"

echo "-----"
printf 'gate_tier2_nonce_evidence_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
