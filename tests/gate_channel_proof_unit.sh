#!/usr/bin/env bash
# DIVE-1305 isolated unit harness for the paired-human channel-proof clear and
# the `task clear-recs` bulk-apply-recommendations verb:
#   * _gate_channel_proof_ok verifies a chat_id against the bot's access.json
#     allowFrom (DMs only), rejecting junk / group (negative) ids.
#   * `task answer --channel-proof` clears a tier<2 gate as a HUMAN (provenance
#     human:*), but NEVER a tier-2 hard gate (money/destructive/secret/brand) —
#     that keeps its per-gate button tap.
#   * `task clear-recs` applies each eligible gate's --recommend, SKIPPING tier-2,
#     no-recommend, and lead-routed gates; --only narrows to one gate.
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR;
# the live shared tasks.db is NEVER touched. Run: bash tests/gate_channel_proof_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-cp-unit.XXXXXX)"
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
task_need_notify() { :; }
audit_log() { :; }
# Post-sudo human context: immediate caller is root (passes the DIVE-394 block).
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
prov()     { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }

# ── CP1: _gate_channel_proof_ok allowFrom semantics (REAL function) ───────────
# Point _task_owner_channel at a temp access.json holding one allowlisted DM.
ACCESS="$TMP/access.json"
printf '{"allowFrom":["555","777"],"groups":{"-100200":{}}}' > "$ACCESS"
_task_owner_channel() { TASK_CH_ACCESS="$ACCESS"; TASK_CH_TOKEN="x"; TASK_CH_TYPE="claude"; return 0; }

_gate_channel_proof_ok 555 && ok_t "CP1 allowlisted DM verifies" || bad_t "CP1 allowlisted DM verifies"
_gate_channel_proof_ok 999 ; [[ $? -ne 0 ]] && ok_t "CP1 non-allowlisted chat rejected" || bad_t "CP1 non-allowlisted rejected"
_gate_channel_proof_ok "-100200" ; [[ $? -ne 0 ]] && ok_t "CP1 group (negative) id rejected" || bad_t "CP1 group id rejected"
_gate_channel_proof_ok 'a) | .' ; [[ $? -ne 0 ]] && ok_t "CP1 non-numeric junk rejected" || bad_t "CP1 junk rejected"
_gate_channel_proof_ok "" ; [[ $? -ne 0 ]] && ok_t "CP1 empty chat rejected" || bad_t "CP1 empty rejected"

# For the answer/clear-recs cases, stub the verifier to a known-good chat (555)
# so the tier-gating + bulk-selection logic is what's under test, not plumbing.
_gate_channel_proof_ok() { [[ "$1" == "555" ]]; }

touch "$GATE_PROOF_ENFORCE"   # enforcement ON for every clear below

# ── CP2: channel-proof clears a tier-1 decision gate, provenance human:* ──────
seed_task DIVE-201
cmd_task_need DIVE-201 --type=decision --ask="pick" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
cmd_task_answer DIVE-201 --value=A --channel-proof=555 >/dev/null 2>&1
[[ "$(answered DIVE-201)" == "closed" ]] && ok_t "CP2 tier-1 decision clears via channel-proof" \
  || bad_t "CP2 tier-1 decision clears" "state=$(answered DIVE-201)"
[[ "$(prov DIVE-201)" == human:* ]] && ok_t "CP2 provenance recorded human:*" \
  || bad_t "CP2 provenance human:*" "got '$(prov DIVE-201)'"

# ── CP3: channel-proof does NOT clear a tier-2 hard gate (kept a per-gate tap) ─
seed_task DIVE-202
cmd_task_need DIVE-202 --type=decision --ask="pick" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
db "UPDATE tasks SET tier='2' WHERE ident='DIVE-202';"   # simulate a T2-floored gate
out=$(cmd_task_answer DIVE-202 --value=A --channel-proof=555 2>&1); rc=$?
[[ "$(answered DIVE-202)" == "open" && $rc -ne 0 ]] && ok_t "CP3 tier-2 gate REJECTS channel-proof (keeps per-gate tap)" \
  || bad_t "CP3 tier-2 rejects channel-proof" "rc=$rc state=$(answered DIVE-202)"

# ── CP4: channel-proof satisfies the evidence rule for a tier-1 approval gate ──
seed_task DIVE-203
cmd_task_need DIVE-203 --type=approval --ask="ship it?" --recommend=approved --tier=1 >/dev/null 2>&1
cmd_task_answer DIVE-203 --value=approved --channel-proof=555 >/dev/null 2>&1
[[ "$(answered DIVE-203)" == "closed" ]] && ok_t "CP4 tier-1 approval clears via channel-proof under enforce" \
  || bad_t "CP4 tier-1 approval clears" "state=$(answered DIVE-203)"

# ── CP5: clear-recs bulk — applies recs to tier<2, skips tier-2/no-rec/routed ──
seed_task DIVE-301; cmd_task_need DIVE-301 --type=decision --ask=q --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
seed_task DIVE-302; cmd_task_need DIVE-302 --type=approval --ask=q --recommend=approved --tier=1 >/dev/null 2>&1
seed_task DIVE-303; cmd_task_need DIVE-303 --type=decision --ask=q --options="A|B" --tier=1 >/dev/null 2>&1   # no recommend -> skip
seed_task DIVE-304; cmd_task_need DIVE-304 --type=approval --ask=q --recommend=approved --tier=2 >/dev/null 2>&1  # explicit tier2 hard gate -> skip
seed_task DIVE-305; cmd_task_need DIVE-305 --type=approval --ask=q --recommend=approved --tier=1 >/dev/null 2>&1
db "UPDATE tasks SET routed_reviewer='marcus' WHERE ident='DIVE-305';"                                        # lead-routed -> skip

cmd_task_clear_recs --channel-proof=555 >/dev/null 2>&1
[[ "$(answered DIVE-301)" == "closed" ]] && ok_t "CP5 clears tier-1 decision"  || bad_t "CP5 tier-1 decision" "$(answered DIVE-301)"
[[ "$(answered DIVE-302)" == "closed" ]] && ok_t "CP5 clears tier-1 approval"  || bad_t "CP5 tier-1 approval" "$(answered DIVE-302)"
[[ "$(answered DIVE-303)" == "open"   ]] && ok_t "CP5 SKIPS no-recommend gate" || bad_t "CP5 skip no-rec" "$(answered DIVE-303)"
[[ "$(answered DIVE-304)" == "open"   ]] && ok_t "CP5 SKIPS tier-2 hard gate"  || bad_t "CP5 skip tier-2" "$(answered DIVE-304)"
[[ "$(answered DIVE-305)" == "open"   ]] && ok_t "CP5 SKIPS lead-routed gate"  || bad_t "CP5 skip routed" "$(answered DIVE-305)"

# ── CP6: clear-recs --only targets exactly one gate ──────────────────────────
seed_task DIVE-401; cmd_task_need DIVE-401 --type=decision --ask=q --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
seed_task DIVE-402; cmd_task_need DIVE-402 --type=decision --ask=q --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
cmd_task_clear_recs --channel-proof=555 --only=DIVE-401 >/dev/null 2>&1
[[ "$(answered DIVE-401)" == "closed" && "$(answered DIVE-402)" == "open" ]] \
  && ok_t "CP6 --only clears just the named gate" || bad_t "CP6 --only scope" "401=$(answered DIVE-401) 402=$(answered DIVE-402)"

# ── CP7: clear-recs rejects an unverified channel-proof ──────────────────────
seed_task DIVE-501; cmd_task_need DIVE-501 --type=decision --ask=q --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
out=$(cmd_task_clear_recs --channel-proof=999 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-501)" == "open" ]] && ok_t "CP7 bad channel-proof rejected, nothing cleared" \
  || bad_t "CP7 bad channel-proof rejected" "rc=$rc state=$(answered DIVE-501)"

printf '\ngate_channel_proof_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
