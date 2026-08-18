#!/usr/bin/env bash
# TIER: nightly — 13.1s measured on this box: core is at 83-86% of its 300s cap
# (tests/lib/tier.sh), and the whole surface this grades is already nightly —
# push_unit.sh (11.9s) and deploy_unit.sh are the siblings. Isolated store, no
# root, no network, so the nightly sweep runs it unattended.
# DIVE-3577 — a RETIRED-but-resolved gate must still authorize the delegated act.
#
# WHY THIS EXISTS. broker_gate_check keyed the precondition on the `tasks` row's
# six need_* columns. A gate lives there only until something RETIRES it, and
# retirement (_gate_archive_and_clear_sql) moves it to gate_history and nulls all
# six. `task park` retires an ANSWERED gate that way — and parking is exactly what
# a row does while it waits for the push it was just approved for. The approval was
# therefore destroyed by the ordinary lifecycle, and push then refused verbatim:
#
#     error: no gate on DIVE-3560 — file a push-for-review gate first
#
# i.e. "approved, then archived" and "never asked" were the same observation.
# Measured on the live board: DIVE-3560's gate_history row holds approve /
# lead:ops / retired_by=park while the live row reads gateless.
#
# NOTE ON THE RECORD: the original report (and the wiki note) blamed ANSWERING the
# gate. Arm 1 is the control that refutes that — an answered, untouched gate has
# always passed. `park` is the retiring verb, and `need --withdraw` cannot even
# reach an answered gate. Fixing the wrong verb would have shipped as "works".
#
# Pinned here:
#   1. CONTROL / NON-VACUITY: answered + untouched still passes (the fixture drives
#      the real predicate, and answering alone was never the defect);
#   2. THE DEFECT: answered approval + `task park` → authorized off gate_history;
#   3. a newest archived REJECTION is not out-voted by an older archived approval;
#   4. an OPEN current gate is NOT superseded by an archived approval — it still
#      refuses, and the refusal names the archive instead of hiding it;
#   5. a row with no gate anywhere still gets the "no gate" refusal (the fallback
#      does not paper over the genuinely-unasked case);
#   6. authorization is re-applied to the archived record: a bare-agent answer in
#      the archive is refused exactly as it would be live;
#   7. the SIGNED CLOSURE verifies against the archive (require_sig=1), and a
#      tampered archived answer fails it — the archive is not a trust bypass.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/push-gate-archived.XXXXXX)" || { echo "FAIL - mktemp"; exit 1; }
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_task.sh cmd_org.sh \
         lib/self.sh; do
  [[ -f "$SRC/$f" ]] || continue
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$TMP/gate-proof.key"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
openssl rand -hex 32 > "$GATE_PROOF_KEY" 2>/dev/null || { echo "FAIL - no openssl"; exit 1; }
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Preconditions, not observables.
task_need_notify() { return 0; }
audit_log() { return 0; }
_gate_proof_enforced() { return 0; }

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

# File a push-for-review gate and answer it directly. Written to the columns so
# the case is identical on every arm and does not ride on the answer path's own
# policy checks (which are graded by the gate_* suites, not here).
plant() { # <id> [answer] [by] [sign?]
  local id="$1" answer="${2:-approve}" by="${3:-human:lodar}" sign="${4:-1}"
  ( cmd_task_need "$id" --type=approval --tier=1 \
      --ask="approve delegated push for review of branch dive-fixture" ) >/dev/null 2>&1
  local ts; ts=$(db "SELECT datetime('now');")
  local sig=""
  (( sign )) && sig=$(_gate_closure_sign "$id" approval "$answer" "$by" "$ts" 1000)
  db "UPDATE tasks
         SET need_answer=$(sqlq "$answer"), need_answered_at=$(sqlq "$ts"),
             need_answered_by=$(sqlq "$by"), need_answered_uid=1000,
             need_answer_sig=$(sqlq "$sig")
       WHERE id=${id};"
}

# The act under test, captured. Returns the refusal text (empty == authorized).
chk() { ( broker_gate_check push "$1" "T$1" "${2:-0}" ) 2>&1 | tr -d '\n'; }
park() { ( cmd_task_park "$1" --reason="awaiting delegated push" --wake=+12h ) >/dev/null 2>&1; }
hist_n() { db "SELECT COUNT(*) FROM gate_history WHERE task_id=${1};"; }

# --- 1. CONTROL: answered and untouched — always passed, still passes ---------
t1=$(addt --assignee=dev -- "fixture: answered, never retired")
plant "$t1"
r1=$(chk "$t1")
if [[ -z "$r1" ]]; then
  ok_t "control: an ANSWERED, un-retired gate authorizes (answering alone was never the defect)"
else
  bad_t "an answered live gate must authorize — the fixture is not driving the predicate" "$r1"
fi

# --- 2. THE DEFECT: park retires the approval; the act must still authorize ---
t2=$(addt --assignee=dev -- "fixture: answered then parked")
plant "$t2"
park "$t2"
# Prove the PRECONDITION of the defect, not just its symptom: the live row is
# gateless and the approval is in the archive. Without this the arm could pass
# because park silently no-op'd (it refuses without --wake, which is how a first
# draft of this harness "passed" against the unfixed tree).
live_gate=$(db "SELECT COALESCE(need_type,'')||COALESCE(need_answer,'')||COALESCE(need_answered_by,'') FROM tasks WHERE id=${t2};")
if [[ -z "$live_gate" && "$(hist_n "$t2")" == "1" ]]; then
  ok_t "precondition: park left the live row gateless and archived exactly one gate"
else
  bad_t "park must retire the answered gate into gate_history" "live='${live_gate}' hist=$(hist_n "$t2")"
fi
arch=$(db "SELECT COALESCE(need_answer,'')||'|'||COALESCE(need_answered_by,'')||'|'||COALESCE(retired_by,'') FROM gate_history WHERE task_id=${t2};")
if [[ "$arch" == "approve|human:lodar|park" ]]; then
  ok_t "precondition: the archive carries the answer, the answerer and the retiring verb ($arch)"
else
  bad_t "the archive must preserve the approval" "got='$arch'"
fi
r2=$(chk "$t2")
if [[ -z "$r2" ]]; then
  ok_t "THE DEFECT: an approval retired by park still authorizes the delegated act"
else
  bad_t "a parked-away approval must still authorize — this is DIVE-3577" "$r2"
fi

# --- 3. a newer archived REJECTION is not out-voted by an older approval ------
t3=$(addt --assignee=dev -- "fixture: approved, then rejected, both archived")
plant "$t3" approve
park "$t3"
( cmd_task_start "$t3" ) >/dev/null 2>&1
plant "$t3" "no — rejected, do not push"
park "$t3"
r3=$(chk "$t3")
if [[ "$r3" == *REJECTED* ]]; then
  ok_t "the NEWEST archived gate decides: a later rejection is not out-voted by an older approval"
else
  bad_t "digging past a rejection to an older approval is a bypass" "hist=$(hist_n "$t3") got='$r3'"
fi

# --- 4. an OPEN current gate supersedes the archive, and says so -------------
t4=$(addt --assignee=dev -- "fixture: approved, then a fresh gate re-filed over it")
plant "$t4"
( cmd_task_need "$t4" --type=approval --tier=1 --ask="a SECOND question" ) >/dev/null 2>&1
r4=$(chk "$t4")
if [[ "$r4" == *"is OPEN"* ]]; then
  ok_t "an OPEN current gate still refuses — an archived approval does not answer a live question"
else
  bad_t "a live unanswered gate must not be satisfied from the archive" "$r4"
fi
if [[ "$r4" == *"gate-history"* ]]; then
  ok_t "and the refusal POINTS AT the archived resolution instead of hiding it"
else
  bad_t "the OPEN refusal should name the earlier resolved gate" "$r4"
fi

# --- 5. no gate anywhere: the original refusal survives ----------------------
t5=$(addt --assignee=dev -- "fixture: never gated at all")
r5=$(chk "$t5")
if [[ "$r5" == *"no gate on"* && "$(hist_n "$t5")" == "0" ]]; then
  ok_t "a row that never had a gate still gets 'no gate' (the fallback invents nothing)"
else
  bad_t "the genuinely-unasked case must keep refusing" "hist=$(hist_n "$t5") got='$r5'"
fi

# --- 6. authorization is re-applied to the archived record ------------------
t6=$(addt --assignee=dev -- "fixture: archived approval answered by a bare agent")
plant "$t6" approve "dev"
park "$t6"
r6=$(chk "$t6")
if [[ "$r6" == *"not cleared by an authority"* ]]; then
  ok_t "a bare-agent answer in the ARCHIVE is refused exactly as it would be live"
else
  bad_t "reading from the archive must not skip the provenance arms" "$r6"
fi

# --- 7. the signed closure verifies against the archive, and detects tamper --
t7=$(addt --assignee=dev -- "fixture: signed approval, parked")
plant "$t7" approve "human:lodar"
park "$t7"
r7=$(chk "$t7" 1)
if [[ -z "$r7" ]]; then
  ok_t "require_sig=1: the signed closure verifies against the ARCHIVED gate"
else
  bad_t "the closure is keyed on fields gate_history preserves; it must verify" "$r7"
fi
# The same arm's negative control: without it, a signature check that always
# returned true would look identical above.
db "UPDATE gate_history SET need_answer='approve EVERYTHING' WHERE task_id=${t7};"
r7b=$(chk "$t7" 1)
if [[ "$r7b" == *"no valid signed closure"* ]]; then
  ok_t "negative control: a TAMPERED archived answer fails the closure check"
else
  bad_t "a hand-edited gate_history row must not authorize a privileged write" "$r7b"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
