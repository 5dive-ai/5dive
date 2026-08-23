#!/usr/bin/env bash
# DIVE-3499 — the sender-visible handoff receipt on the ROUTING verbs.
#
# WHAT THIS GRADES, and why each arm is here rather than a smaller set:
#
#  A. The receipt exists on all three routing verbs (reject / assign / set-body)
#     and names all THREE facts — owner, queue position, next wake. Fewer than
#     three is not a partial pass: the sender's residual question is whichever
#     one is missing, and that is the ping this row exists to delete.
#  B. It reaches the CALLER on STDOUT. A receipt only the recipient can see, or
#     one on stderr behind a 2>/dev/null, removes nothing. Every arm captures
#     stdout ALONE (2>/dev/null on the call) so a line that landed on stderr
#     reads as absent, not as a pass.
#  C. The queue position is the DISPATCHER'S order, not a COUNT(*). Graded by
#     building a board where the two differ (a high-priority row inserted last)
#     and asserting the receipt tracks _hb_pick_tasks, not insertion order.
#  D. THE HARD CONSTRAINT (lodar, 2026-08-16 16:47Z): additive only — the verb
#     must still exit 0, and change nothing, when the receipt cannot be computed.
#     Graded by breaking each of the receipt's three inputs in turn (the picker,
#     the board, the registry) and asserting rc=0 AND the row still moved.
#
# Runs against a REAL sqlite board in a throwaway STATE_DIR — never the live
# shared board. No root, no network.
# Run: bash tests/routing_receipt_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/routing-receipt-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/agents.json"
# The receipt is HUMAN output by design (a stray line would corrupt the JSON
# object `ok` emits), so this harness must run in human mode or it grades
# nothing. Arm J asserts the JSON contract is untouched, with JSON_MODE flipped.
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# mk <title> <assignee> <priority> [status] -> row id
mk() {
  local title="$1" who="$2" prio="${3:-medium}" status="${4:-todo}"
  db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
      VALUES ($(sqlq "$title"), '', $(sqlq "$prio"), $(sqlq "$who"), 'main', 'standard', $(sqlq "$status"));
      SELECT last_insert_rowid();"
}
ident_of() { db "SELECT ident FROM tasks WHERE id=$1;"; }
status_of() { db "SELECT status FROM tasks WHERE id=$1;"; }
assignee_of() { db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=$1;"; }

# Heartbeat state for a seat. reg <name> <enabled> <everyMin> <lastRunAt-epoch>
#
# Writes the WHOLE roster every time, not just the named seat: the registry is
# also what `_task_require_lane` reads, so a one-seat file would make `assign`
# refuse every other name in this harness for an unrelated reason and the receipt
# arms would grade nothing while still looking like they ran.
_RR_SEATS=(main dev2 dev3 quinn)
reg() {
  local target="$1" enabled="$2" every="$3" last="$4" body="" s
  for s in "${_RR_SEATS[@]}"; do
    [[ -n "$body" ]] && body+=","
    if [[ "$s" == "$target" ]]; then
      body+=$(printf '"%s":{"heartbeat":{"enabled":%s,"everyMin":%s,"lastRunAt":%s}}' \
                "$s" "$enabled" "$every" "$last")
    else
      body+=$(printf '"%s":{"heartbeat":{"enabled":false,"everyMin":30,"lastRunAt":0}}' "$s")
    fi
  done
  printf '{"agents":{%s}}\n' "$body" >"$REGISTRY"
}
reg main false 30 0   # seed the roster before the first lane check runs

# has_all_three <captured-stdout> -> 0 if the receipt named owner+position+wake
has_all_three() {
  local out="$1" who="$2"
  grep -q "^handoff: ${who} " <<<"$out" \
    && grep -q 'queue position:' <<<"$out" \
    && grep -q 'next wake:' <<<"$out"
}

echo "── A/B: the receipt exists, on stdout, on each routing verb ─────────────"

# --- reject ------------------------------------------------------------------
reg dev2 false 30 0
R1=$(mk "receipt on reject" quinn high)
db "UPDATE tasks SET maker_agent='dev2', verifier='quinn', iteration=1,
      handoff_delivered_at=datetime('now'), status='todo' WHERE id=${R1};"
I1=$(ident_of "$R1")
ACTOR_OVERRIDE=quinn TASK_ACTOR=quinn \
  OUT=$(cmd_task_reject "$I1" --feedback="needs another pass" 2>/dev/null)
if has_all_three "$OUT" dev2; then
  ok_t "reject prints a receipt naming owner + queue position + next wake on stdout"
else
  bad_t "reject receipt missing a fact (or landed on stderr)" "$OUT"
fi
[[ "$(assignee_of "$R1")" == "dev2" ]] \
  && ok_t "reject still bounced the row to the maker" \
  || bad_t "reject did not bounce the row" "assignee=$(assignee_of "$R1")"

# --- assign ------------------------------------------------------------------
R2=$(mk "receipt on assign" main medium)
I2=$(ident_of "$R2")
OUT=$(cmd_task_assign "$I2" dev2 2>/dev/null)
if has_all_three "$OUT" dev2; then
  ok_t "assign prints a receipt naming all three facts on stdout"
else
  bad_t "assign receipt missing a fact (or landed on stderr)" "$OUT"
fi
[[ "$(assignee_of "$R2")" == "dev2" ]] \
  && ok_t "assign still moved the row" \
  || bad_t "assign did not move the row" "assignee=$(assignee_of "$R2")"

# --- set-body ----------------------------------------------------------------
# The measured case this row was filed on: work handed over by a BODY WRITE, the
# row already owned by the recipient, and the sender pinging anyway.
R3=$(mk "receipt on set-body" dev2 medium)
I3=$(ident_of "$R3")
OUT=$(cmd_task_set_body "$I3" --append "triage: both arms fail on the ancestry check" 2>/dev/null)
if has_all_three "$OUT" dev2; then
  ok_t "set-body prints a receipt naming all three facts on stdout"
else
  bad_t "set-body receipt missing a fact (or landed on stderr)" "$OUT"
fi
grep -q 'ancestry check' <<<"$(db "SELECT body FROM tasks WHERE id=${R3};")" \
  && ok_t "set-body still wrote the body" \
  || bad_t "set-body did not write the body"

echo "── C: the queue position is the DISPATCHER'S order, not a COUNT(*) ──────"

# dev3's board, built so insertion order and dispatch order DISAGREE: the
# high-priority row is inserted LAST, so a naive COUNT(*)-of-earlier-rows would
# say "3 of 3" where the dispatcher will actually hand it over first.
db "DELETE FROM tasks WHERE assignee='dev3';"
Q1=$(mk "dev3 low a"  dev3 low)
Q2=$(mk "dev3 low b"  dev3 low)
Q3=$(mk "dev3 urgent" dev3 urgent)
IQ3=$(ident_of "$Q3")
# Route it with assign (dev3 -> dev3 is a legitimate no-op move; the receipt is
# what is under test, and the position must not depend on the row having moved).
OUT=$(cmd_task_assign "$IQ3" dev3 2>/dev/null)
POS=$(sed -n 's/.*queue position: \([0-9]* of [0-9]*\).*/\1/p' <<<"$OUT")
[[ "$POS" == "1 of 3" ]] \
  && ok_t "urgent row inserted last reports 'queue position: 1 of 3' (dispatch order)" \
  || bad_t "queue position is not the dispatcher's order" "got '${POS:-none}' from: $OUT"

# And the low-priority one behind it reports a position that agrees with the
# picker itself — re-derived here rather than hard-coded, so the arm cannot go
# stale if the ordering rule legitimately changes.
IQ1=$(ident_of "$Q1")
OUT=$(cmd_task_assign "$IQ1" dev3 2>/dev/null)
POS=$(sed -n 's/.*queue position: \([0-9]*\) of [0-9]*.*/\1/p' <<<"$OUT")
EXPECT=$(_hb_pick_tasks dev3 200 | grep -n "^${Q1}$" | cut -d: -f1)
[[ -n "$POS" && "$POS" == "$EXPECT" ]] \
  && ok_t "reported position ($POS) equals the position _hb_pick_tasks would hand it ($EXPECT)" \
  || bad_t "reported position disagrees with the dispatcher" "receipt=$POS picker=$EXPECT"

# A dep-blocked row is NOT in the dispatch list. A number there would be a lie
# the sender would act on, so the receipt must say what is actually true.
QB=$(mk "dev3 blocked" dev3 high)
db "INSERT OR IGNORE INTO task_deps (task_id, blocked_by) VALUES (${QB}, ${Q1});"
OUT=$(cmd_task_assign "$(ident_of "$QB")" dev3 2>/dev/null)
grep -q 'queue position: waiting on 1 unfinished dependency' <<<"$OUT" \
  && ok_t "a dep-blocked row reports the blocker, not a fabricated position" \
  || bad_t "dep-blocked row got a misleading position" "$OUT"

echo "── D: next wake, all three states ──────────────────────────────────────"

R4=$(mk "wake states" main medium); I4=$(ident_of "$R4")

reg dev2 false 30 0
OUT=$(cmd_task_assign "$I4" dev2 2>/dev/null)
grep -q 'next wake: no auto-wake (heartbeat off for dev2)' <<<"$OUT" \
  && ok_t "heartbeat off -> says the seat does not auto-wake" \
  || bad_t "heartbeat-off wake line wrong" "$OUT"

reg dev2 true 30 1
OUT=$(cmd_task_assign "$I4" dev2 2>/dev/null)
grep -q 'next wake: due now (dispatcher ticks every 5 min)' <<<"$OUT" \
  && ok_t "overdue seat -> 'due now', bounded by the 5-min cron tick" \
  || bad_t "due-now wake line wrong" "$OUT"

reg dev2 true 30 "$(date +%s)"
OUT=$(cmd_task_assign "$I4" dev2 2>/dev/null)
grep -qE 'next wake: in ~(29|30)m' <<<"$OUT" \
  && ok_t "seat that just ran -> 'in ~30m' from lastRunAt + everyMin" \
  || bad_t "future-wake line wrong" "$OUT"

echo "── E: ADDITIVE ONLY — every input can break and the verb still exits 0 ──"

# The constraint, verbatim: "if this code path can return non-zero where it
# returns zero today, it is out of scope." So each of the receipt's three
# dependencies is broken in turn and the VERB is graded, not the receipt.

R5=$(mk "additive: no picker" main medium); I5=$(ident_of "$R5")
_HB_SAVED=$(declare -f _hb_pick_tasks)
unset -f _hb_pick_tasks
OUT=$(cmd_task_assign "$I5" dev2 2>/dev/null); RC=$?
if (( RC == 0 )) && [[ "$(assignee_of "$R5")" == "dev2" ]]; then
  ok_t "picker missing: assign still exits 0 and still moved the row"
else
  bad_t "picker missing broke the verb" "rc=$RC assignee=$(assignee_of "$R5")"
fi
grep -q 'queue position: unknown' <<<"$OUT" \
  && ok_t "picker missing: says 'unknown' rather than inventing a position" \
  || bad_t "picker missing produced a fabricated position" "$OUT"
eval "$_HB_SAVED"

R6=$(mk "additive: no registry" main medium); I6=$(ident_of "$R6")
_REG_SAVED="$REGISTRY"; REGISTRY="$TMP/does-not-exist.json"
OUT=$(cmd_task_assign "$I6" dev2 2>/dev/null); RC=$?
if (( RC == 0 )) && [[ "$(assignee_of "$R6")" == "dev2" ]]; then
  ok_t "registry missing: assign still exits 0 and still moved the row"
else
  bad_t "registry missing broke the verb" "rc=$RC assignee=$(assignee_of "$R6")"
fi
grep -q 'next wake:' <<<"$OUT" \
  && ok_t "registry missing: the wake fact is still named (not silently dropped)" \
  || bad_t "registry missing dropped the wake fact" "$OUT"
REGISTRY="$_REG_SAVED"

# A registry present but CORRUPT is the case a `jq` without a guard turns into a
# non-zero exit — the exact shape the constraint forbids.
R7=$(mk "additive: corrupt registry" main medium); I7=$(ident_of "$R7")
printf 'not json at all {{{\n' >"$REGISTRY"
OUT=$(cmd_task_assign "$I7" dev2 2>/dev/null); RC=$?
if (( RC == 0 )) && [[ "$(assignee_of "$R7")" == "dev2" ]]; then
  ok_t "corrupt registry: assign still exits 0 and still moved the row"
else
  bad_t "corrupt registry broke the verb" "rc=$RC assignee=$(assignee_of "$R7")"
fi
reg dev2 false 30 0

# The receipt called with an owner it cannot resolve at all must print nothing
# and exit 0 — "a receipt that cannot be printed should print nothing".
OUT=$(routing_receipt "" "" 2>/dev/null); RC=$?
[[ $RC -eq 0 && -z "$OUT" ]] \
  && ok_t "receipt with no ident/owner: prints nothing, exits 0" \
  || bad_t "empty-input receipt misbehaved" "rc=$RC out='$OUT'"

# And the whole function is exit-proof. The stub targets `_routing_receipt_render`
# specifically, NOT one of the two helpers below it: those are already called in
# command substitutions, which are subshells of their own, so an `exit` inside
# them is contained whether or not `routing_receipt` wraps anything — an arm
# pointed there would pass on a version with the containment deleted and grade
# nothing. `_routing_receipt_render` is the only call whose containment is the
# wrapper's own doing, so it is the only place this control can live.
_RENDER_SAVED=$(declare -f _routing_receipt_render)
_routing_receipt_render() { exit 9; }
OUT=$(routing_receipt DIVE-1 dev2 2>/dev/null); RC=$?
[[ $RC -eq 0 ]] \
  && ok_t "an exiting render cannot propagate a non-zero status to the caller" \
  || bad_t "receipt propagated a failure" "rc=$RC"
eval "$_RENDER_SAVED"

# The other half of the same constraint: a render that FAILS (non-zero, no exit)
# is equally contained. `set -e` is live in production via header.sh.
_RENDER_SAVED=$(declare -f _routing_receipt_render)
_routing_receipt_render() { return 7; }
routing_receipt DIVE-1 dev2 >/dev/null 2>&1; RC=$?
[[ $RC -eq 0 ]] \
  && ok_t "a failing render cannot propagate a non-zero status to the caller" \
  || bad_t "receipt propagated a return code" "rc=$RC"
eval "$_RENDER_SAVED"

# THE SAME CONSTRAINT WHERE THE WRAPPER ITSELF IS ABSENT. Not hypothetical: this
# arm is here because adding the call sites broke tests/task_reject_trace_unit.sh
# and tests/task_reject_actor_and_closed_unit.sh with rc=127 — they source a
# SUBSET of src/ that does not include the new lib, and bash turns an unknown
# command into a non-zero exit on a verb that had already done its work. A tree
# that loads part of src/ is a real shape (every harness, and any future split),
# so the verb must survive the helper not existing at all.
R9=$(mk "additive: no helper" main medium); I9=$(ident_of "$R9")
_RECEIPT_SAVED=$(declare -f routing_receipt)
unset -f routing_receipt
OUT=$(cmd_task_assign "$I9" dev2 2>/dev/null); RC=$?
if (( RC == 0 )) && [[ "$(assignee_of "$R9")" == "dev2" ]]; then
  ok_t "helper entirely absent: assign still exits 0 and still moved the row"
else
  bad_t "a missing routing_receipt broke the verb" "rc=$RC assignee=$(assignee_of "$R9")"
fi
eval "$_RECEIPT_SAVED"

echo "── J: JSON mode is untouched ───────────────────────────────────────────"

R8=$(mk "json contract" main medium); I8=$(ident_of "$R8")
JSON_MODE=1
OUT=$(cmd_task_assign "$I8" dev2 2>/dev/null); RC=$?
JSON_MODE=0
if (( RC == 0 )) && jq -e '.ok == true' <<<"$OUT" >/dev/null 2>&1; then
  ok_t "JSON mode: output is still a single valid object (no receipt line leaked in)"
else
  bad_t "JSON mode output corrupted by the receipt" "rc=$RC out='$OUT'"
fi

echo "── W: wiring — the lib is SHIPPED, and every routing verb calls it ─────"

# Everything above sources src/ directly, so it would stay green on a version
# where the file exists and the installed CLI never loads it. build.sh is an
# explicit manifest, not a glob: a new lib that is not listed is silently absent
# from the artifact customers install.
grep -q '^  src/lib/routing_receipt.sh \\$' build.sh \
  && ok_t "build.sh manifest ships src/lib/routing_receipt.sh" \
  || bad_t "routing_receipt.sh is not in the build manifest — the shipped CLI would not have it"

for pair in "src/task/delivery.sh:reject" "src/task/crud.sh:assign" "src/task/dispatch.sh:set-body"; do
  f="${pair%%:*}"; v="${pair##*:}"
  grep -q 'routing_receipt "' "$f" \
    && ok_t "the $v verb's file calls routing_receipt" \
    || bad_t "no routing_receipt call in $f (the $v verb)"
done

echo
printf 'routing_receipt_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
