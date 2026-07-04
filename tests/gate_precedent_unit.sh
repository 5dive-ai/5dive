#!/usr/bin/env bash
# OSS-11 (DIVE-976) isolated unit harness for decision-memory precedent prefill.
# Two halves:
#   * _gate_ask_shape() normalizer — idents/dates/amounts/hosts/nums/quoted-names
#     collapse to typed placeholders; different targets => same shape; the shape
#     key is what precedent matching keys on.
#   * cmd_task_need precedent prefill + the DIVE-916 SAFETY INVARIANT: prefill
#     fills a BLANK recommend only (never overrides a filer rec), from an equal-
#     or-higher tier precedent, of the SAME need_type — and it NEVER mutates tier
#     nor auto-answers the gate (the clear path is untouched).
# Isolation matches the sibling harnesses: source src/ libs against a throwaway
# STATE_DIR; the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_precedent_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-precedent-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }

tasks_db_init

# Capture the citation task need hands the notifier (arg 9) instead of DMing.
NOTIFY_CITE=""
task_need_notify() { NOTIFY_CITE="${9:-}"; }
audit_log() { :; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
# Seed an ALREADY-ANSWERED precedent gate directly (bypasses the human-only clear
# path — we only need the row a lookup would find).
seed_precedent() { # <ident> <type> <tier> <shape> <answer>
  seed_task "$1"
  db "UPDATE tasks SET need_type='$2', tier=$3, ask_shape=$(sqlq "$4"),
        need_answer=$(sqlq "$5"), need_answered_at=datetime('now'),
        need_answered_by='human:mark', status='todo' WHERE ident='$1';"
}
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# ============================ shape normalizer ============================
eq_t "shape: idents collapse"            "$(_gate_ask_shape 'Deploy DIVE-100 and OSS-3 now')" \
                                         "deploy <ident> and <ident> now"
eq_t "shape: different targets => same"  "$(_gate_ask_shape 'teardown box alpha-7')" \
                                         "$(_gate_ask_shape 'teardown box beta-9')"
eq_t "shape: bare integers => <num>"     "$(_gate_ask_shape 'scale to 12 workers')" \
                                         "scale to <num> workers"
eq_t "shape: dollar amount => <amount>"  "$(_gate_ask_shape 'approve spend of $2,500 now')" \
                                         "approve spend of <amount> now"
eq_t "shape: ISO date => <date>"         "$(_gate_ask_shape 'ship on 2026-07-04')" \
                                         "ship on <date>"
eq_t "shape: host => <host>"             "$(_gate_ask_shape 'point dns at api.5dive.com')" \
                                         "point dns at <host>"
eq_t "shape: quoted name => <name>"      "$(_gate_ask_shape 'rename to "Prod East" cluster')" \
                                         "rename to <name> cluster"
# decimal must NOT be swallowed by the host rule (final label is numeric)
eq_t "shape: decimal => <num>"           "$(_gate_ask_shape 'bump to 3.5x budget')" \
                                         "bump to <num>x budget"

# ==================== precedent prefill + invariants =====================
# P0: matching precedent prefills a BLANK recommend + sets precedent_ref + cites.
SHAPE_PROD="$(_gate_ask_shape 'deploy DIVE-100 to prod')"
seed_precedent DIVE-1000 decision 1 "$SHAPE_PROD" yes
PREC_ID="$(db "SELECT id FROM tasks WHERE ident='DIVE-1000';")"
seed_task DIVE-1001
NOTIFY_CITE=""
cmd_task_need DIVE-1001 --type=decision --ask="deploy DIVE-100 to prod" --options="yes|no" >/dev/null 2>&1
eq_t "prefill: blank recommend filled from precedent" "$(field DIVE-1001 recommend)" "yes"
eq_t "prefill: precedent_ref recorded"                "$(field DIVE-1001 precedent_ref)" "$PREC_ID"
if [[ -n "$NOTIFY_CITE" ]]; then ok_t "prefill: citation handed to notifier"; else bad_t "prefill: citation handed to notifier" "empty"; fi

# INV1: prefill NEVER mutates tier (decision defaults to tier 1, unchanged).
eq_t "invariant: tier not mutated by prefill" "$(field DIVE-1001 tier)" "1"

# INV2: fill-blank-ONLY — an explicit filer recommend is never overridden.
seed_task DIVE-1002
cmd_task_need DIVE-1002 --type=decision --ask="deploy DIVE-200 to prod" --options="yes|no" --recommend="no" >/dev/null 2>&1
eq_t "invariant: filer recommend not overridden" "$(field DIVE-1002 recommend)" "no"

# INV3: different need_type NEVER matches (approval gate, same shape, no prefill).
seed_task DIVE-1003
cmd_task_need DIVE-1003 --type=approval --ask="deploy DIVE-300 to prod" >/dev/null 2>&1
eq_t "invariant: cross-type never matches (recommend blank)" "$(field DIVE-1003 recommend)" "∅"
eq_t "invariant: cross-type never matches (precedent_ref null)" "$(field DIVE-1003 precedent_ref)" "∅"

# INV4: tier(P) >= tier(G) — a lower-tier precedent can't prefill a higher gate.
SHAPE_LOW="$(_gate_ask_shape 'rotate the DIVE-1 worker pool')"
seed_precedent DIVE-1010 decision 0 "$SHAPE_LOW" yes
seed_task DIVE-1011
cmd_task_need DIVE-1011 --type=decision --ask="rotate the DIVE-2 worker pool" --options="yes|no" >/dev/null 2>&1
eq_t "invariant: lower-tier precedent rejected (blank)" "$(field DIVE-1011 recommend)" "∅"

# INV5: precedent NEVER auto-answers — an approval gate stays blocked/unanswered
# even when a matching precedent prefills its recommend (the clear path is untouched).
SHAPE_APP="$(_gate_ask_shape 'grant DIVE-50 admin access')"
seed_precedent DIVE-1020 approval 2 "$SHAPE_APP" approved
seed_task DIVE-1021
cmd_task_need DIVE-1021 --type=approval --ask="grant DIVE-60 admin access" >/dev/null 2>&1
eq_t "invariant: precedent prefills approval rec"      "$(field DIVE-1021 recommend)" "approved"
eq_t "invariant: precedent does NOT auto-answer"       "$(field DIVE-1021 need_answered_at)" "∅"
eq_t "invariant: gate still blocked (needs human)"     "$(field DIVE-1021 status)" "blocked"

# INV6: decision option-mismatch — precedent cites but does NOT prefill a rec that
# isn't one of THIS gate's options (a shown rec must map to a real option).
SHAPE_PICK="$(_gate_ask_shape 'pick a region for DIVE-70')"
seed_precedent DIVE-1030 decision 1 "$SHAPE_PICK" yes
seed_task DIVE-1031
cmd_task_need DIVE-1031 --type=decision --ask="pick a region for DIVE-80" --options="approve|reject" >/dev/null 2>&1
eq_t "invariant: option-mismatch skips prefill" "$(field DIVE-1031 recommend)" "∅"
eq_t "invariant: option-mismatch still cites"   "$(field DIVE-1031 precedent_ref)" "$(db "SELECT id FROM tasks WHERE ident='DIVE-1030';")"

echo "-------------------------------------"
echo "gate_precedent_unit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
