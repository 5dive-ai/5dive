#!/usr/bin/env bash
# DIVE-1968 isolated unit harness — gate telemetry is FENCED ON STORE IDENTITY, and
# the two records that were supposed to explain a failure can now do it.
#
# WHY THIS EXISTS. `_task_gate_delivery_log` wrote to a HARDCODED
# /var/log/5dive/notify/gate-notify.log and called audit_log, regardless of which
# task store the process was driving. A unit harness points TASKS_DB at a throwaway
# store whose `agents_org` is EMPTY, an empty org table yields an EMPTY escalation
# chain for EVERY filer, and so each fixture gate emitted a real-looking
# "no paired channel for filer X or anyone above it" row into PRODUCTION telemetry.
#
# Measured on this box before the fix: 36 distinct idents appeared in the error
# rows; 17 existed ONLY in fixture stores. The true post-DIVE-1927 production
# population is 28 rows on 2 tasks — the ticket was filed on 194 rows across 13.
# The contamination cut both ways: it inflated the blast radius AND hid the real
# residual inside it. It also manufactured the control that made the wrong
# diagnosis look decisive ("13 tasks, 194 errors, not ONE ok, and the ok rows are 6
# disjoint tasks") — a fixture ident can never record an `ok`, because it was never
# a real gate. Zero overlap was two populations in one file, not a broken rail.
#
# What is pinned here:
#   1. off the prod store: NOTHING reaches the prod log path or the audit log;
#   2. ...and the withholding is ANNOUNCED once, never silent;
#   3. an explicit FIVEDIVE_GATE_NOTIFY_LOG still captures locally (the safe case),
#      and still does NOT earn an audit row off-store;
#   4. on the prod store the rows are written exactly as before — the fence must
#      not cost the coverage it is protecting;
#   5. `task gate-escalate` records the REAL rc, so rc=2 (channel resolved, send
#      unconfirmed) is distinguishable from a genuine no-recipient failure;
#   6. the privileged re-send KEEPS the child's stderr, so the parent can say WHY.
# Run: bash tests/gate_telemetry_fence_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-fence-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_push.sh cmd_agent_pairing.sh cmd_task.sh; do
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e                       # AFTER sourcing: header.sh turns `set -e` back on, and
                             # a `set +e` placed BEFORE the sources is silently undone.
                             # That cost four probes during this ticket's diagnosis.
tasks_db_init

AUDIT_CALLS="$TMP/audit.calls"; : >"$AUDIT_CALLS"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_CALLS"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
reset() { : >"$AUDIT_CALLS"; unset _TASK_GATE_TELEMETRY_FENCED; }

# The prod log path this fence exists to protect. The test NEVER writes to the real
# one; it redirects the notion of "prod" instead, so a regression shows up as a
# missing/extra row here rather than as a line in the fleet's log.
PRODLOG="$TMP/prod-gate-notify.log"

# --- 1. OFF the prod store: no prod telemetry at all -------------------------
reset; unset FIVEDIVE_GATE_NOTIFY_LOG
export FIVEDIVE_PROD_TASKS_DB="$TMP/somewhere-else/tasks.db"   # active store != prod
_task_gate_delivery_log error "DIVE-7" "" "" "no paired channel for filer dev" 2>"$TMP/first.err" >/dev/null
OUT=$(cat "$TMP/first.err")
if [[ ! -s "$AUDIT_CALLS" ]]; then
  ok_t 'off the prod store, a gate-delivery failure writes NO audit row'
else
  bad_t 'off-store must not audit' "$(cat "$AUDIT_CALLS")"
fi
[[ "$OUT" == *"telemetry withheld"* && "$OUT" == *"DIVE-1968"* ]] \
  && ok_t 'the withholding is ANNOUNCED — a silent fence is the same defect one layer over' \
  || bad_t 'fence must announce' "out=$OUT"
# ...and only once, or every fixture gate in a suite reprints it.
# NB: run IN THIS SHELL with stderr to a file. A command substitution is a subshell,
# so the one-shot flag would not survive it — and in production this is never called
# in one. A harness that changes the scoping is testing its own scoping, not the code.
_task_gate_delivery_log error "DIVE-8" "" "" "second one" 2>"$TMP/second.err" >/dev/null
reset2=$(cat "$TMP/second.err")
[[ "$reset2" != *"telemetry withheld"* ]] \
  && ok_t 'the notice is once per process, not once per row' \
  || bad_t 'notice must be one-shot' "out=$reset2"

# --- 2. an explicit local capture file still works ---------------------------
# The SAFE case, and the one we want harnesses to use: redirect to your own file.
reset; export FIVEDIVE_GATE_NOTIFY_LOG="$TMP/harness.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"
_task_gate_delivery_log error "DIVE-7" "" "" "captured locally" >/dev/null 2>&1
if grep -q 'captured' "$FIVEDIVE_GATE_NOTIFY_LOG" && [[ ! -s "$AUDIT_CALLS" ]]; then
  ok_t 'an explicit capture file receives the row, and STILL earns no audit row off-store'
else
  bad_t 'local capture' "log=[$(cat "$FIVEDIVE_GATE_NOTIFY_LOG")] audit=[$(cat "$AUDIT_CALLS")]"
fi
# The fence must not be defeatable by pointing the override AT the prod default.
reset; export FIVEDIVE_GATE_NOTIFY_LOG="$PRODLOG"; : >"$PRODLOG"
_task_gate_delivery_log error "DIVE-7" "" "" "aimed at prod" >/dev/null 2>&1
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t 'redirecting the override at prod still earns no audit row — store identity decides, not the path' \
  || bad_t 'override must not confer prod status' "$(cat "$AUDIT_CALLS")"

# --- 3. ON the prod store: unchanged behaviour -------------------------------
# The fence is worthless if it also silences the real fleet. Declare the ACTIVE
# store to be prod and assert the row comes back.
reset; unset FIVEDIVE_GATE_NOTIFY_LOG
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
OUT=$(_task_gate_delivery_log error "DIVE-1956" "" "" "real production failure" 2>&1)
if grep -q 'gate delivery' "$AUDIT_CALLS" && [[ "$OUT" != *"telemetry withheld"* ]]; then
  ok_t 'on the prod store the audit row is written exactly as before — no coverage lost'
else
  bad_t 'prod store must still audit' "audit=[$(cat "$AUDIT_CALLS")] out=$OUT"
fi

# --- 4. the escalate audit row carries the REAL rc ---------------------------
# It was a hardcoded `1`, so rc=2 (a channel resolved, the Bot API send was simply
# not confirmed) and a genuine no-recipient failure were indistinguishable in the
# only durable record — while the message asserted the second reading either way.
reset
seed_gate() { db "DELETE FROM tasks WHERE ident='$1';
  INSERT INTO tasks (ident,title,body,status,created_by,assignee,need_type,ask)
  VALUES ('$1','t','','in_progress','dev','main','decision','why');"; }
seed_gate ESC-1
task_need_notify() { TASK_SEND_DELIVERED=0; return 0; }   # resolved, NOT confirmed => rc 2
# $EUID is READONLY, so the verb was untestable until it went through this seam.
_gate_is_root() { return 0; }
out=$(cmd_task_gate_escalate ESC-1 2>&1); rc=$?
if grep -q 'rc=2' "$AUDIT_CALLS"; then
  ok_t 'gate-escalate audits the REAL rc (2 = resolved-but-unconfirmed), not a literal 1'
else
  bad_t 'audit rc must be real' "audit=[$(cat "$AUDIT_CALLS")] out=$out rc=$rc"
fi
[[ "$out" == *UNVERIFIED* ]] \
  && ok_t 'and the message says UNVERIFIED rather than asserting nobody was reachable' \
  || bad_t 'rc=2 message' "out=$out"

# --- 5. the privileged re-send keeps the child's REASON ----------------------
# `>/dev/null 2>&1` discarded it, so the parent could only ever say FAILED — and a
# whole diagnosis round went into guessing whether sudo had refused the invocation
# or gate-escalate had returned non-zero for its own reason. The child prints it.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo: a password is required\n' >&2
exit 1
STUB
chmod +x "$TMP/bin/sudo"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/5dive"; chmod +x "$TMP/bin/5dive"
PATH="$TMP/bin:$PATH" _task_gate_escalate_via_sudo DIVE-1 "nonce" ; vrc=$?
if [[ $vrc -ne 0 && "$TASK_GATE_ESCALATE_ERR" == *"password is required"* ]]; then
  ok_t 'the privileged re-send keeps the child stderr — the parent can say WHY, not only THAT'
else
  bad_t 'child reason must survive' "rc=$vrc err=[$TASK_GATE_ESCALATE_ERR]"
fi
# stdout stays discarded (it is the ok/JSON envelope, not a reason).
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'OK envelope on stdout\n'
exit 0
STUB
chmod +x "$TMP/bin/sudo"
PATH="$TMP/bin:$PATH" _task_gate_escalate_via_sudo DIVE-1 "nonce"; vrc2=$?
[[ $vrc2 -eq 0 && -z "$TASK_GATE_ESCALATE_ERR" ]] \
  && ok_t 'a successful re-send returns 0 and leaves no spurious reason behind' \
  || bad_t 'success path' "rc=$vrc2 err=[$TASK_GATE_ESCALATE_ERR]"

# --- 6. DIVE-1500 dryrun is honoured as a SECONDARY quarantine signal ---------
# Reusing that vocabulary rather than minting a rival one. It is deliberately NOT
# the primary: an opt-in fence is a fence you have to remember, and "four harnesses
# set it, the rest do not" is the defect being removed.
reset; unset FIVEDIVE_GATE_NOTIFY_LOG
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"        # store says prod...
export FIVEDIVE_NOTIFY_DRYRUN=1                  # ...but dryrun quarantines anyway
_task_gate_delivery_log error "DIVE-1956" "" "" "dryrun" >/dev/null 2>&1
[[ ! -s "$AUDIT_CALLS" ]] \
  && ok_t 'FIVEDIVE_NOTIFY_DRYRUN quarantines telemetry even ON the prod store (DIVE-1500 vocabulary reused)' \
  || bad_t 'dryrun secondary' "$(cat "$AUDIT_CALLS")"
unset FIVEDIVE_NOTIFY_DRYRUN

# --- 7. the two empty-chain shapes are DISTINGUISHED in the detail -----------
# Three unrelated causes produced one indistinguishable message, which is why 28
# real rows sat unreadable under ~840 fixture ones.
db "DELETE FROM agents_org;" >/dev/null 2>&1
db "INSERT INTO agents_org (name, reports_to) VALUES ('boss', NULL), ('worker','boss');" >/dev/null 2>&1
shape_case() { # <expect> <filer> <why>
  local got; got=$(_task_filer_chain_shape "$2")
  [[ "$got" == "$1" ]] && ok_t "chain shape: $3" || bad_t "chain shape: $3" "want [$1] got [$got]"
}
shape_case 'absent-from-org' 'ghost'  'a filer with NO agents_org row at all (the largest real shape, 13 of 28)'
shape_case 'top-of-org'      'boss'   'a filer who IS in the chart with no manager (real, and only 1 of 28)'
shape_case 'no-chain'        'worker' 'in the chart WITH a manager — the shape nobody named'
shape_case 'no-filer'        ''       'no filer at all is its own answer, not silence'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
