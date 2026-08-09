#!/usr/bin/env bash
# DIVE-2760 isolated unit harness — `task answer` must SAY SO when it stores an
# unsigned gate closure.
#
# WHY THIS EXISTS. The closure-signing block in `cmd_task_answer` is best-effort
# by design: a box that cannot sign stores an empty `need_answer_sig` and the
# answer never fails on it. That posture is right for the WRITE — losing a
# human's answer because a box cannot sign would be worse — but it was
# implemented as "never says anything", and those are different. The result:
# `task answer` reports OK, and `broker_gate_check ... require_sig=1` refuses the
# task LATER, in a different command, on a DIFFERENT agent, with a message about
# tampering. Measured cost before this fix: three delegated-push round-trips lost
# on DIVE-2743 / DIVE-2599 / DIVE-2798, the last a release blocker.
#
# The property that makes the silence expensive, and that arm 3 pins: the
# signature is minted by the ANSWERER and nothing re-signs at act time, so the
# agent that gets refused is not the agent that could have prevented it. A notice
# that fired on the actor would be too late; this one fires on the answerer.
#
# What is pinned here:
#   1. UNSIGNED -> LOUD: when the closure mints empty, stderr names the state,
#      the cause, the downstream consequence and the remedy;
#   2. POSITIVE CONTROL: with a signature present the same path prints NOTHING.
#      Without this arm a notice printed unconditionally would score arm 1 green;
#   3. the notice names the ANSWERER-vs-ACTOR asymmetry and the ident, so a
#      reader can act on it without already knowing the mechanism;
#   4. WARN, NOT FAIL: the answer still LANDS (need_answered_at set) and the
#      command still exits 0 — a gate no broker will require_sig on must not lose
#      its answer over an empty column;
#   5. the notice goes to STDERR, so `--json` consumers are not corrupted by it.
#
# NOT COVERED, deliberately: the `secret` write branch. The notice sits AFTER the
# secret/non-secret if/else, so it is branch-independent by construction, and
# answering a secret gate needs the human-evidence path (a nonce or a lead-clear
# seat) — a fixture elaborate enough that it would be measuring itself.
#
# The unsignable box is simulated by stubbing `sudo` (and, if this runs as root,
# `_gate_closure_sign`) — the ENVIRONMENT, not the subject. The code under test
# is the real `cmd_task_answer`.
# Run: bash tests/gate_unsigned_closure_notice_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades. No `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-unsigned-notice.XXXXXX)"
FAILURES=()
cleanup() {
  local rc="$1"
  if [[ "${FAIL:-0}" -gt 0 || "$rc" -ne 0 ]]; then
    printf '\n=== FAILURE: TMP preserved for inspection: %s ===\n' "$TMP" >&2
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
      printf -- '--- failing assertions ---\n' >&2
      printf '%s\n' "${FAILURES[@]}" >&2
    fi
    for f in "$TMP"/*.out "$TMP"/*.err; do
      [[ -s "$f" ]] || continue
      printf -- '--- %s ---\n' "$f" >&2
      cat "$f" >&2
    done
  else
    rm -rf "$TMP"
  fi
}
trap 'rc=$?; cleanup "$rc"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # AFTER sourcing: header.sh turns `set -e` back on.
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() {
  FAIL=$((FAIL+1))
  printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"
  FAILURES+=("FAIL - $1"$'\n'"   ${2:-}")
}
addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

# Preconditions, not observables. The audit log and the channel ping are other
# harnesses' subjects; keep them out of this one entirely.
audit_log() { :; }
_task_store_audit_log() { :; }
task_need_notify() { return 0; }
_gate_proof_enforced() { return 0; }
_task_gate_retire_buttons() { return 0; }

nat() { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE id=${1};"; }
sig() { db "SELECT COALESCE(need_answer_sig,'')  FROM tasks WHERE id=${1};"; }

# --- the two boxes -----------------------------------------------------------
# CANNOT sign: `sudo -n 5dive gate-proof sign` is denied (the cli-scoped seat).
# Both branches are covered so the arm measures the same thing whatever $EUID
# this suite runs under — under root the in-process mint is the one that fires.
unsignable_box() {
  sudo() { return 1; }
  _gate_closure_sign() { return 1; }
  _gate_proof_ensure_key() { return 0; }
}
# CAN sign. The code only tests the mint for emptiness, so any non-empty string
# is a faithful stand-in for a real signature here.
signable_box() {
  sudo() { printf 'sig-fixture-not-a-real-signature\n'; }
  _gate_closure_sign() { printf 'sig-fixture-not-a-real-signature\n'; }
  _gate_proof_ensure_key() { return 0; }
}

mkgate() {   # mkgate <label> -> task id with an open tier-1 decision gate
  local t; t=$(addt --assignee=dev -- "$1")
  cmd_task_need "$t" --type=decision --options="A|B" --recommend="A" \
    --ask="pick one" --tier=1 >/dev/null 2>&1
  printf '%s' "$t"
}

# --- 1+3+4. UNSIGNED -> loud, and the answer still lands ---------------------
unsignable_box
t1=$(mkgate "fixture unsignable box")
cmd_task_answer "$t1" --value="B" --human >"$TMP/unsigned.out" 2>"$TMP/unsigned.err"
RC1=$?
ERR1=$(cat "$TMP/unsigned.err")

if [[ -z "$(sig "$t1")" ]]; then
  ok_t "liveness: the fixture box really did store an EMPTY signature"
else
  bad_t "the unsignable arm signed anyway — nothing below measures the fix" \
        "sig='$(sig "$t1")'"
fi
if [[ -n "$(nat "$t1")" && "$RC1" == "0" ]]; then
  ok_t "the answer LANDS and the command exits 0 (warn, not fail)"
else
  bad_t "an unsigned closure must not cost the answer or the exit code" \
        "rc=$RC1 at='$(nat "$t1")'"
fi
if [[ "$ERR1" == *UNSIGNED* ]]; then
  ok_t "stderr names the state: the closure was stored UNSIGNED"
else
  bad_t "an unsigned closure was stored SILENTLY — this is the whole defect" \
        "stderr='$ERR1'"
fi
if [[ "$ERR1" == *"$t1"* ]] || [[ "$ERR1" == *DIVE-* ]]; then
  ok_t "the notice names the gate it is about"
else
  bad_t "the notice must name the ident, or it cannot be acted on" "stderr='$ERR1'"
fi
if [[ "$ERR1" == *"why:"* && "$ERR1" == *"gate-proof sign"* ]]; then
  ok_t "the notice names the CAUSE (which signing path came back empty)"
else
  bad_t "notice must say why the mint was empty" "stderr='$ERR1'"
fi
if [[ "$ERR1" == *"REFUSED"* && "$ERR1" == *"no valid signed closure"* ]]; then
  ok_t "the notice names the DOWNSTREAM CONSEQUENCE in the broker's own words"
else
  bad_t "notice must name the later refusal, in the text the reader will meet" \
        "stderr='$ERR1'"
fi
# The asymmetry is the reason the silence was expensive: the refusal lands on
# someone who could not have prevented it.
if [[ "$ERR1" == *"ANSWERER, not by the agent acting on it"* ]]; then
  ok_t "the notice names the ANSWERER-vs-ACTOR asymmetry"
else
  bad_t "notice must say the signature is the answerer's, not the actor's" \
        "stderr='$ERR1'"
fi
if [[ "$ERR1" == *"fix:"* && "$ERR1" == *"re-answered"* ]]; then
  ok_t "the notice names the REMEDY (a different answerer)"
else
  bad_t "notice must name a remedy" "stderr='$ERR1'"
fi
# The remedy that looks direct is the one that must not be taken.
if [[ "$ERR1" == *"Do NOT grant"* && "$ERR1" == *"cli-scoped"* ]]; then
  ok_t "the notice forecloses the NOPASSWD grant (it forges any closure)"
else
  bad_t "notice must foreclose granting cli-scoped seats gate-proof sign" \
        "stderr='$ERR1'"
fi

# --- 5. the notice is on STDERR, so --json stdout stays parseable ------------
if [[ "$(cat "$TMP/unsigned.out")" != *UNSIGNED* ]]; then
  ok_t "the notice does not reach stdout (--json output stays clean)"
else
  bad_t "the notice leaked into stdout and would corrupt a --json consumer" \
        "stdout='$(cat "$TMP/unsigned.out")'"
fi

# --- 2. POSITIVE CONTROL: a signable box prints NOTHING ----------------------
# Without this arm, a notice printed unconditionally scores every assertion
# above green.
signable_box
t2=$(mkgate "fixture signable box")
cmd_task_answer "$t2" --value="B" --human >"$TMP/signed.out" 2>"$TMP/signed.err"
RC2=$?
ERR2=$(cat "$TMP/signed.err")

if [[ -n "$(sig "$t2")" ]]; then
  ok_t "control liveness: the signable box really did store a signature"
else
  bad_t "the control arm stored no signature, so its silence proves nothing" \
        "sig='$(sig "$t2")'"
fi
if [[ "$ERR2" != *UNSIGNED* && "$ERR2" != *"gate-proof sign"* ]]; then
  ok_t "a SIGNED closure prints no unsigned-closure notice"
else
  bad_t "the notice fired on a signed closure — it is unconditional, not keyed" \
        "stderr='$ERR2'"
fi
if [[ -n "$(nat "$t2")" && "$RC2" == "0" ]]; then
  ok_t "the control answer lands and exits 0 (the arms differ only in signing)"
else
  bad_t "control arm did not complete; the comparison is not paired" \
        "rc=$RC2 at='$(nat "$t2")'"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
