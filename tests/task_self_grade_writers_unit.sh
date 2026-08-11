#!/usr/bin/env bash
# DIVE-3097 unit harness — the maker-can't-grade-itself refusal, enumerated
# across every WRITER that can land a row in the (assignee==verifier,
# maker_agent EMPTY) shape, not just the one verb (`task verifier`) that
# already refused it.
#
# THE DEFECT. `task verifier <id> <assignee>` was refused with:
#   "'X' is <ident>'s own assignee — a maker can't grade itself
#    (reassign first, or pick a different grader)"
# but the IDENTICAL end state was reachable, unguarded, through:
#   (1) `task add --assignee=X --verifier=X` at creation time — zero guard.
#   (2) `task add --verifier=X` with NO --assignee, where X happens to be the
#       agent the DIVE-333 auto-coordinate default would pick anyway — the
#       collision is IMPLIED, not typed out, and still zero guard.
#   (3) `task assign <id> <verifier-name>` — a raw reassignment verb with no
#       verifier awareness at all, landing the ASSIGNEE onto a row's EXISTING
#       verifier from the other direction `task verifier`'s attach-time check
#       cannot see (the assignee moves AFTER the verifier was set).
#   (4) `task need` (gate filing) — any agent may file a gate on any task, and
#       the filer becomes assignee-of-record as a SIDE EFFECT. If the filer is
#       the row's own verifier and nothing has been delivered yet, that side
#       effect used to self-appoint the verifier as assignee with no handoff
#       ever recorded.
# Found live as DIVE-2899: assignee=dev3, verifier=dev3, delivered_at NULL — a
# maker booked as its own grader, never handed off to anyone.
#
# A FIFTH writer — the recurring-stall escalation ladder in
# `_hb_stall_sweep` (src/cmd_heartbeat.sh) reassigning a stalled recurring
# instance to a free agent — is covered separately in
# tests/heartbeat_recurring_stall_escalate_unit.sh (arm 8), because it needs
# the heartbeat harness's registry/cmd_send scaffolding, not this one's.
#
# WHAT THIS FILE PROVES, arm by arm: (1)/(2)/(3) are refused with the SAME
# "maker can't grade itself" semantics `task verifier` already uses; (4) is
# handled differently ON PURPOSE — filing a gate is not itself the maker→
# grader transition, so it is not refused outright, only stopped from
# SILENTLY creating the collision (the write that would move the assignee is
# suppressed, the gate still files). Each arm is paired with a NON-vacuity
# sibling — the same shape one field off, where the write must still go
# through — so a guard that is simply too broad shows up as a false refusal
# right beside the true one, the same trap
# tests/gate_filing_preserves_handoff_unit.sh is built around.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path.
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/task-self-grade-writers-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; tests expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run()   { local verb="$1"; shift; ( JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
run_as(){ local who="$1" verb="$2"; shift 2
          ( actor_seam_as "${who}"; JSON_MODE=1; "cmd_task_$verb" "$@" ) 2>"$TMP"/err; }
jf()    { jq -r "$1" 2>/dev/null; }
has()   { [[ "$1" == *"$2"* ]]; }

JSON_MODE=1
tasks_db_init
# Lone-root org: boss has nobody above it, so it is BOTH the DIVE-333
# auto-coordinate default AND a plausible explicit --verifier — exactly the
# shape arm 2 needs. alice/carol are ordinary reports, distinct from boss and
# from each other, for the arms that need a real second party.
db "INSERT INTO agents_org (name, reports_to) VALUES ('boss',NULL),('alice','boss'),('carol','boss');"

# =============================================================================
# ARM 1 — `task add --assignee=X --verifier=X` (the literal DIVE-2899 shape)
# =============================================================================
out1=$(run add --assignee=alice --verifier=alice -- "self-graded chore"); rc1=$?
(( rc1 != 0 )) && has "$(cat "$TMP"/err)$out1" "can't grade itself" \
  && ok_t "ARM1 'task add --assignee=X --verifier=X' refuses (same message as 'task verifier')" \
  || bad_t "ARM1 'task add --assignee=X --verifier=X' refuses" "rc=$rc1 $out1 $(cat "$TMP"/err)"
[[ "$(db "SELECT COUNT(*) FROM tasks WHERE title='self-graded chore';")" == "0" ]] \
  && ok_t "ARM1 the refused row was never written (all-or-nothing, not a partial insert)" \
  || bad_t "ARM1 the refused row was never written" "$(db "SELECT * FROM tasks WHERE title='self-graded chore';")"

# Non-vacuity sibling: same call, DISTINCT names, must succeed. Proves ARM1 is
# grading the COLLISION and not just refusing every `task add --verifier=`.
out1b=$(run add --assignee=alice --verifier=carol -- "properly graded chore"); rc1b=$?
(( rc1b == 0 )) \
  && ok_t "ARM1-sibling distinct assignee/verifier still succeeds (guard is not over-broad)" \
  || bad_t "ARM1-sibling distinct assignee/verifier still succeeds" "rc=$rc1b $out1b $(cat "$TMP"/err)"

# =============================================================================
# ARM 2 — `task add --verifier=X` with NO --assignee, where X is the agent the
# DIVE-333 auto-coordinate default would pick anyway (the IMPLIED collision).
# boss is the lone org root, so it is exactly that default.
# =============================================================================
out2=$(run add --verifier=boss -- "implied collision via auto-coordinate"); rc2=$?
(( rc2 != 0 )) && has "$(cat "$TMP"/err)$out2" "can't grade itself" \
  && ok_t "ARM2 '--verifier=<the auto-coordinate default>' refuses even with no explicit --assignee" \
  || bad_t "ARM2 implied collision via auto-coordinate refuses" "rc=$rc2 $out2 $(cat "$TMP"/err)"

# Non-vacuity sibling: an ordinary add with no --assignee and no --verifier at
# all must still auto-coordinate to boss normally — ARM2 must not have broken
# the DIVE-333 default itself.
out2b=$(run add -- "ordinary auto-coordinated chore"); rc2b=$?
(( rc2b == 0 )) && [[ "$(printf '%s' "$out2b" | jf '.data.assignee')" == "boss" ]] \
  && ok_t "ARM2-sibling a plain add with no --verifier still auto-coordinates to boss" \
  || bad_t "ARM2-sibling plain add still auto-coordinates" "rc=$rc2b $out2b"

# =============================================================================
# ARM 3 — `task assign <id> <verifier>`: a raw reassignment landing the
# ASSIGNEE onto the row's EXISTING verifier, the direction `task verifier`'s
# own attach-time check structurally cannot see.
# =============================================================================
a3=$(run add --assignee=alice --verifier=carol -- "assign onto own verifier"); a3_id=$(printf '%s' "$a3" | jf '.data.id')
out3=$(run assign "$a3_id" carol); rc3=$?
(( rc3 != 0 )) && has "$(cat "$TMP"/err)$out3" "can't grade itself" \
  && ok_t "ARM3 'task assign <id> <its-own-verifier>' refuses" \
  || bad_t "ARM3 'task assign <id> <its-own-verifier>' refuses" "rc=$rc3 $out3 $(cat "$TMP"/err)"
[[ "$(db "SELECT assignee FROM tasks WHERE id=${a3_id};")" == "alice" ]] \
  && ok_t "ARM3 the refused assign left the row's assignee untouched" \
  || bad_t "ARM3 the refused assign left the assignee untouched" "assignee=$(db "SELECT assignee FROM tasks WHERE id=${a3_id};")"

# Non-vacuity sibling: reassigning to a THIRD party (neither the current
# assignee nor the verifier) must still work — the guard must not have made
# `task assign` refuse everything.
out3b=$(run assign "$a3_id" boss); rc3b=$?
(( rc3b == 0 )) && [[ "$(db "SELECT assignee FROM tasks WHERE id=${a3_id};")" == "boss" ]] \
  && ok_t "ARM3-sibling reassigning to a third, non-verifier party still works" \
  || bad_t "ARM3-sibling reassigning to a third party still works" "rc=$rc3b $out3b"

# Non-vacuity sibling 2: the row the DIVE-477 handoff itself puts in exactly
# this shape (assignee flips TO the verifier as PART of a normal delivery,
# via `task done` -> `_task_route_to_verifier`) must be left alone — ARM3
# refuses a raw `task assign` onto the verifier, never the legitimate,
# system-driven handoff write.
a3c=$(run add --assignee=alice --verifier=carol -- "legitimate handoff"); a3c_id=$(printf '%s' "$a3c" | jf '.data.id')
run_as alice start "$a3c_id" >/dev/null
run_as alice done  "$a3c_id" --result="ready" >/dev/null
[[ "$(db "SELECT assignee FROM tasks WHERE id=${a3c_id};")" == "carol" ]] \
  && ok_t "ARM3-sibling a normal maker->verifier handoff DOES still flip assignee to the verifier" \
  || bad_t "ARM3-sibling normal handoff still flips assignee to the verifier" "assignee=$(db "SELECT assignee FROM tasks WHERE id=${a3c_id};")"
# ...and re-pointing `task assign` at the SAME verifier the row is already
# delivered to is a no-op, not a NEW collision being created — refusing it
# would just be noise on an idempotent call.
out3d=$(run assign "$a3c_id" carol); rc3d=$?
(( rc3d == 0 )) \
  && ok_t "ARM3-sibling re-assigning a delivered row to the verifier it's ALREADY with is not refused (no new collision)" \
  || bad_t "ARM3-sibling idempotent re-assign to the current verifier is not refused" "rc=$rc3d $out3d $(cat "$TMP"/err)"

# =============================================================================
# ARM 4 — `task need`: the filer becomes assignee-of-record as a side effect.
# If the filer is the row's own verifier and nothing has been delivered yet,
# that side effect must not self-appoint them onto the row.
# =============================================================================
a4=$(run add --assignee=alice --verifier=carol -- "gate filed by own verifier pre-delivery"); a4_id=$(printf '%s' "$a4" | jf '.data.id')
out4=$(run_as carol need "$a4_id" --type=decision --tier=1 --ask="which path" --options="a|b" --recommend="a"); rc4=$?
(( rc4 == 0 )) \
  && ok_t "ARM4 the gate itself still files (this is a preserve, not a refusal)" \
  || bad_t "ARM4 the gate still files" "rc=$rc4 $out4 $(cat "$TMP"/err)"
[[ "$(db "SELECT assignee FROM tasks WHERE id=${a4_id};")" == "alice" ]] \
  && ok_t "ARM4 the row's own verifier filing a gate does NOT self-appoint as assignee pre-delivery" \
  || bad_t "ARM4 verifier-filed gate does not self-appoint pre-delivery" "assignee=$(db "SELECT assignee FROM tasks WHERE id=${a4_id};") (want alice, unchanged — carol is the verifier and must not become assignee too)"

# Non-vacuity sibling: a THIRD party (neither maker nor verifier) filing the
# same kind of gate on an undelivered row still takes the assignee exactly as
# DIVE-891 always intended — ARM4 must not have broken ordinary gate-filing
# ownership for everyone.
a4b=$(run add --assignee=alice --verifier=carol -- "gate filed by a stranger pre-delivery"); a4b_id=$(printf '%s' "$a4b" | jf '.data.id')
run_as boss need "$a4b_id" --type=decision --tier=1 --ask="which path" --options="a|b" --recommend="a" >/dev/null
[[ "$(db "SELECT assignee FROM tasks WHERE id=${a4b_id};")" == "boss" ]] \
  && ok_t "ARM4-sibling a stranger filing the same gate still becomes assignee-of-record (DIVE-891, unchanged)" \
  || bad_t "ARM4-sibling stranger-filed gate still takes the assignee" "assignee=$(db "SELECT assignee FROM tasks WHERE id=${a4b_id};")"

# Non-vacuity sibling 2: the DIVE-2196 case this ticket must not regress — the
# verifier filing a gate on a row ALREADY delivered to them (assignee is
# ALREADY carol) is a no-op by construction and must still stamp the review
# ACK exactly as before.
a4c=$(run add --assignee=alice --verifier=carol -- "verifier escalates a live review"); a4c_id=$(printf '%s' "$a4c" | jf '.data.id')
run_as alice start "$a4c_id" >/dev/null
run_as alice done  "$a4c_id" --result="ready" >/dev/null
run_as carol need "$a4c_id" --type=decision --tier=1 --ask="in scope?" --options="yes|no" --recommend="yes" >/dev/null
state4c=$(db "SELECT assignee||'|'||CASE WHEN handoff_ack_at IS NULL THEN 'noack' ELSE 'ack' END FROM tasks WHERE id=${a4c_id};")
[[ "$state4c" == "carol|ack" ]] \
  && ok_t "ARM4-sibling verifier escalating a LIVE review keeps the row and stamps the ACK (DIVE-2196, unregressed)" \
  || bad_t "ARM4-sibling verifier escalating a live review is unregressed" "state=$state4c"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
