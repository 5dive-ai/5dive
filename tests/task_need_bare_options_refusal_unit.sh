#!/usr/bin/env bash
# TIER: core
# DIVE-4462 — two things, and the order between them is the point.
#
# (1) THE SEAM. `fail()` ends in `exit`, and a harness that sources src/ and calls
#     `cmd_task_need` in its own shell dies on any refusal inside that function —
#     at rc=3, before its summary, with every later assertion SKIPPED rather than
#     passed. Measured on DIVE-4431: one new refusal aborted ten harnesses across
#     all three core-pristine shards; gate_verifier_route_unit died after 3 of 22
#     arms. That is a property of the seam, inherited by the NEXT refusal anyone
#     adds. tests/lib/gate_seam.sh runs the real function in a subshell so a
#     refusal fails its own arm instead. Arms 1-2 grade it, with a control that
#     reproduces the abort when the seam is absent.
#
# (2) THE RULE the seam had to hold first: on a gate whose RESOLVED ROUTE is the
#     paired human, `--options=A|B` is refused — those options are the buttons,
#     and a button reading "A" names no outcome. Keyed on the resolved route, not
#     the declared tier (DIVE-4431). The DIVE-4416 warn is unchanged for the agent
#     reader; arm 5 pins that, because fixtures and scripted callers legitimately
#     pass letters (DIVE-2249) and turning that warn into a refusal is what reds
#     the fleet.
#
# No root, no network, throwaway DB. Run: bash tests/task_need_bare_options_refusal_unit.sh
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
SRC="${DIVE_TEST_SRC:-$ROOT/src}"
TMP="$(mktemp -d /tmp/task-need-bare-options.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh cmd_push.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP/state"
TASKS_DIR="$STATE_DIR/tasks"
# shellcheck disable=SC2034
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
# shellcheck disable=SC2034
FIVE_VERIFY_DEFAULT=0
# shellcheck disable=SC2034
FIVE_FILING_CAP=0
set +e

tasks_db_init
db "INSERT INTO tasks (ident,title,status,priority,created_by,project_key,kind)
    VALUES ('DIVE-9101','human-route bare options','in_progress','medium','main','dive','standard'),
           ('DIVE-9102','human-route bare options, escaped','in_progress','medium','main','dive','standard'),
           ('DIVE-9103','human-route spelled options','in_progress','medium','main','dive','standard'),
           ('DIVE-9104','agent-route bare options','in_progress','medium','main','dive','standard');"

PLAIN_ASK="Ship the smaller change now, or hold for the full one?"

# ---- 1. THE SEAM: a refusal returns to the caller, it does not end the run ---
# The call below is DELIBERATELY unsubshelled — that is the shape the ten aborted
# harnesses use. Before this change it exited the process here; the marker after
# it is what proves the process survived.
SEAM_MARKER=0
cmd_task_need DIVE-9101 --type=decision --tier=2 --needs=human_tap \
  --ask="$PLAIN_ASK" --options='A|B' --recommend='A' \
  >"$TMP/seam.out" 2>"$TMP/seam.err"
SEAM_RC=$?
SEAM_MARKER=1
(( SEAM_MARKER == 1 )) \
  && ok_t "an UNSUBSHELLED refusal returned to the caller; the line after it ran (the seam holds)" \
  || bad_t "the harness never reached the line after the refusal" "unreachable by construction"
[[ "$SEAM_RC" == "3" ]] \
  && ok_t "the refusal still refuses: rc=3 is returned, not swallowed" \
  || bad_t "refusal did not return rc=3" "rc=$SEAM_RC err: $(head -2 "$TMP/seam.err")"

# ---- 2. the seam's CONTROL: without it, the same call aborts the process -----
# A green arm 1 means nothing unless the failure it prevents is reproducible. Run
# the identical shape in a child bash that does NOT source the seam, and require
# it to die at rc=3 BEFORE printing its marker.
cat > "$TMP/nomarker.sh" <<'CTL'
set -uo pipefail
ROOT="$1"; STATE="$2"
cd "$ROOT" || exit 9
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh cmd_push.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "src/$f"
done
STATE_DIR="$STATE"; TASKS_DIR="$STATE/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
FIVE_VERIFY_DEFAULT=0; FIVE_FILING_CAP=0
set +e
cmd_task_need DIVE-9101 --type=decision --tier=2 --needs=human_tap \
  --ask="Ship the smaller change now, or hold for the full one?" \
  --options='A|B' --recommend='A' >/dev/null 2>&1
echo "MARKER-REACHED"
CTL
CTL_OUT=$(bash "$TMP/nomarker.sh" "$ROOT" "$STATE_DIR" 2>/dev/null)
CTL_RC=$?
if [[ "$CTL_OUT" == *MARKER-REACHED* ]]; then
  bad_t "seam control is vacuous: the unseamed harness survived the refusal too" "rc=$CTL_RC out=$CTL_OUT"
else
  [[ "$CTL_RC" == "3" ]] \
    && ok_t "control reproduces the abort: without the seam the same call kills the process at rc=3 before its marker" \
    || bad_t "control died for the wrong reason" "rc=$CTL_RC out=$CTL_OUT"
fi

# ---- 3. the rule itself: the refusal names the buttons, not the tier ---------
ERR=$(cat "$TMP/seam.err" 2>/dev/null)
case "$ERR" in
  *'single character'*'buttons'*|*'buttons'*) ok_t "the refusal explains that the options ARE the buttons the person taps" ;;
  *) bad_t "refusal message does not explain the buttons" "stderr: $(printf '%s' "$ERR" | head -3)" ;;
esac
case "$ERR" in
  *'--ask-ok'*) ok_t "the refusal offers the documented --ask-ok escape (a gate must never become unfileable, DIVE-2216)" ;;
  *) bad_t "refusal offers no --ask-ok escape" "stderr: $(printf '%s' "$ERR" | head -3)" ;;
esac
NFILED=$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-9101' AND need_type IS NOT NULL;" 2>/dev/null)
[[ "${NFILED:-0}" == "0" ]] \
  && ok_t "the refused gate did not file (the refusal is real, not cosmetic)" \
  || bad_t "a refused gate landed on the row anyway" "need_type rows=${NFILED:-<none>}"

# ---- 4. --ask-ok files it anyway, unchanged, to the same person --------------
cmd_task_need DIVE-9102 --type=decision --tier=2 --needs=human_tap \
  --ask="$PLAIN_ASK" --options='A|B' --recommend='A' \
  --ask-ok="the two arms are named in the customer ticket he is holding" \
  >"$TMP/escape.out" 2>"$TMP/escape.err"
ESC_RC=$?
[[ "$ESC_RC" == "0" ]] \
  && ok_t "--ask-ok files the same gate anyway (the escape is declared, not inferred)" \
  || bad_t "--ask-ok did not file the gate" "rc=$ESC_RC err: $(head -3 "$TMP/escape.err")"
case "$(cat "$TMP/escape.err" 2>/dev/null)" in
  *'ACCEPTED and RECORDED'*) ok_t "the escape is recorded, so the exception is countable" ;;
  *) bad_t "the escape left no recorded line" "stderr: $(head -3 "$TMP/escape.err")" ;;
esac
ESC_N=$(db "SELECT COUNT(*) FROM tasks WHERE ident='DIVE-9102' AND need_options='A|B';" 2>/dev/null)
[[ "${ESC_N:-0}" == "1" ]] \
  && ok_t "the escaped gate landed with its options unchanged" \
  || bad_t "the escaped gate did not land" "matched=${ESC_N:-<none>}"

# ---- 5. DIVE-4416 IS PRESERVED: the agent reader still gets a WARN ----------
# Same bare options, no tier-2 and no declared human capability, so the resolved
# route is an agent. This is the arm that must never become a refusal: 46 fixtures
# under tests/ and DIVE-2249's scripted callers file letters on purpose.
cmd_task_need DIVE-9104 --type=decision \
  --ask="$PLAIN_ASK" --options='A|B' --recommend='A' \
  >"$TMP/agent.out" 2>"$TMP/agent.err"
AG_RC=$?
[[ "$AG_RC" == "0" ]] \
  && ok_t "an agent-routed gate with bare options still FILES (warn, never fail — DIVE-4416 preserved)" \
  || bad_t "the refusal leaked onto the agent reader" "rc=$AG_RC err: $(head -3 "$TMP/agent.err")"
case "$(cat "$TMP/agent.err" 2>/dev/null)" in
  *'single character'*) ok_t "the agent reader still gets the DIVE-4416 warning" ;;
  *) bad_t "the DIVE-4416 warning stopped firing for the agent reader" "stderr: $(head -3 "$TMP/agent.err")" ;;
esac

# ---- 6. no false positive: spelled-out options file on a human route ---------
cmd_task_need DIVE-9103 --type=decision --tier=2 --needs=human_tap \
  --ask="$PLAIN_ASK" \
  --options='ship the smaller change now|hold for the full one' \
  --recommend='ship the smaller change now' \
  >"$TMP/spelled.out" 2>"$TMP/spelled.err"
SP_RC=$?
[[ "$SP_RC" == "0" ]] \
  && ok_t "spelled-out options file cleanly on a human route (no false positive)" \
  || bad_t "spelled-out options were refused" "rc=$SP_RC err: $(head -3 "$TMP/spelled.err")"

echo
printf 'DIVE-4462 bare-option refusal + gate seam: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
