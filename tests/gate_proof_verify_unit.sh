#!/usr/bin/env bash
# DIVE-2062 isolated unit harness for `5dive gate-proof verify <id|DIVE-N>`
# (cmd_gate_proof's "verify" branch, cmd_task.sh). Per the DIVE-2054 verifier
# pass (dev3, 2026-07-26), this command path was reached by NO suite at all —
# genuinely unmeasured, not merely untested-on-one-side like the 5 sites that
# were reached but only ever ALLOWED. This closes that gap: drives the real
# command against a fixture TASKS_DB, on BOTH sides of the DIVE-2010/2054
# store-identity fence around its `_task_store_audit_log "gate-proof verify"`
# call (cmd_task.sh ~5334) — the nonce/signature being verified is itself
# TASKS_DB state for the task, not an independent real-world fact, so it is
# fenced (see community/wiki/audit-log-store-fence-task-need-unnotified-dive2010.md).
#
# require_root is stubbed to a no-op, mirroring tests/task_fixture_send_guard_unit.sh
# and tests/task_inbox_send_unit.sh — $EUID is read-only so this is the
# established seam, not a new one.
# Run: bash tests/gate_proof_verify_unit.sh  (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-proof-verify-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  source "$SRC/$f"
done

require_root() { :; }   # isolate from the (separate, unrelated) root requirement

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# A real key file, pre-seeded so _gate_proof_ensure_key's short-circuit
# (`[[ -s "$keyfile" ]] && return 0`) is hit — "verify" never calls that
# function itself, but _gate_closure_verify -> _gate_proof_hmac needs the key
# file to exist regardless, and provisioning one for real needs root.
GATE_PROOF_KEY="$TMP/gate-proof.key"
openssl rand -hex 32 >"$GATE_PROOF_KEY"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

# seed_answered <ident> <sig-mode: valid|invalid|absent> -> echoes the row id
# sig-mode drives the three shapes _gate_closure_verify must distinguish:
#   valid   - answered via the real cmd_task_answer path, sig recomputes clean
#   invalid - a raw-sqlite write (or tamper) that never ran through signing
#   absent  - a legacy row answered before DIVE-756 existed at all
seed_answered() {
  local ident="$1" mode="$2" tid at uid sig
  tid=$(db "INSERT INTO tasks (ident, title, status, created_by, assignee,
                                need_type, need_answer, need_answered_by)
            VALUES ($(sqlq "$ident"), 't', 'todo', 'main', 'main',
                    'decision', 'A', 'human:dev');
            SELECT last_insert_rowid();")
  at='2026-07-26 09:00:00'; uid=1000
  case "$mode" in
    valid)   sig=$(_gate_closure_sign "$tid" decision A human:dev "$at" "$uid") ;;
    invalid) sig="not-a-real-signature" ;;
    absent)  sig="" ;;
  esac
  db "UPDATE tasks SET need_answered_at=$(sqlq "$at"), need_answered_uid=${uid},
        need_answer_sig=$(sqlq_or_null "$sig") WHERE id=${tid};"
  printf '%s' "$tid"
}

# =============================================================================
# ON the prod store: the command itself, across all three signature shapes
# =============================================================================
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

seed_answered DIVE-1 valid >/dev/null
out=$(cmd_gate_proof verify DIVE-1 2>"$TMP/err1")
[[ "$(printf '%s' "$out" | jf '.data.signed')" == "present" \
   && "$(printf '%s' "$out" | jf '.data.valid')" == "true" ]] \
  && ok_t "a genuinely signed closure verifies signed=present valid=true" \
  || bad_t "valid signature" "out=$out err=$(cat "$TMP/err1")"
grep -q 'gate-proof verify.*DIVE-1.*signed=present.*valid=true' "$AUDIT_CALLS" \
  && ok_t "on-store: the verify audits ok/signed/valid in one row" \
  || bad_t "on-store audit row (valid)" "$(cat "$AUDIT_CALLS")"

: >"$AUDIT_CALLS"
seed_answered DIVE-2 invalid >/dev/null
out=$(cmd_gate_proof verify DIVE-2 2>"$TMP/err2")
[[ "$(printf '%s' "$out" | jf '.data.signed')" == "present" \
   && "$(printf '%s' "$out" | jf '.data.valid')" == "false" ]] \
  && ok_t "a tampered/never-signed sig with a value present verifies signed=present valid=false" \
  || bad_t "invalid signature" "out=$out err=$(cat "$TMP/err2")"
grep -q 'gate-proof verify.*DIVE-2.*valid=false' "$AUDIT_CALLS" \
  && ok_t "on-store: an invalid signature is audited with result=error (valid=false)" \
  || bad_t "on-store audit row (invalid)" "$(cat "$AUDIT_CALLS")"

: >"$AUDIT_CALLS"
seed_answered DIVE-3 absent >/dev/null
out=$(cmd_gate_proof verify DIVE-3 2>"$TMP/err3")
[[ "$(printf '%s' "$out" | jf '.data.signed')" == "absent" \
   && "$(printf '%s' "$out" | jf '.data.valid')" == "false" ]] \
  && ok_t "a legacy row with no stored signature verifies signed=absent valid=false" \
  || bad_t "absent signature" "out=$out err=$(cat "$TMP/err3")"
grep -q 'gate-proof verify.*DIVE-3.*signed=absent' "$AUDIT_CALLS" \
  && ok_t "on-store: a legacy unsigned row is still audited (findable, not silent)" \
  || bad_t "on-store audit row (absent)" "$(cat "$AUDIT_CALLS")"

# A task with no answered gate at all must refuse rather than fabricate a verdict.
db "INSERT INTO tasks (ident, title, status, created_by, assignee)
      VALUES ('DIVE-4','t','todo','main','main');" >/dev/null
out=$(cmd_gate_proof verify DIVE-4 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"no answered gate to verify"* ]] \
  && ok_t "an unanswered task refuses verify rather than reporting a fabricated verdict" \
  || bad_t "unanswered refusal" "rc=$rc out=$out"

# =============================================================================
# OFF the prod store: the audit row is withheld, and the withholding is
# announced — mirrors tests/heartbeat_gate_shipped_unit.sh Case 12's pattern
# for this cmd_task.sh site instead of a cmd_heartbeat.sh one.
# =============================================================================
: >"$AUDIT_CALLS"
unset _TASK_STORE_AUDIT_FENCED
export FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db"
seed_answered DIVE-5 valid >/dev/null
out=$(cmd_gate_proof verify DIVE-5 2>"$TMP/offstore.err")
[[ "$(printf '%s' "$out" | jf '.data.valid')" == "true" ]] \
  && ok_t "off-store: the command's own verdict is unaffected by the fence (fail-open on the READ side)" \
  || bad_t "off-store verdict still correct" "out=$out"
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t "off the prod store, gate-proof verify writes NO audit row" \
  || bad_t "off-store must not audit" "$(cat "$AUDIT_CALLS")"
grep -q "telemetry withheld" "$TMP/offstore.err" \
  && ok_t "the withholding is ANNOUNCED, not silent" \
  || bad_t "fence must announce" "err=$(cat "$TMP/offstore.err")"
unset _TASK_STORE_AUDIT_FENCED

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
