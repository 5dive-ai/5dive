#!/usr/bin/env bash
# DIVE-2624: filing a gate must not un-deliver a maker→verifier handoff.
#
# The `handoff:` line is DERIVED (maker_agent IS NOT NULL AND assignee=verifier
# AND status NOT IN done/cancelled), and `task need` wrote assignee=<filer>
# unconditionally — so ANY gate filed on a delivered row falsified the predicate
# and the delivery vanished from `task show`, the loop board and the stall sweep.
# handoff_delivered_at was never touched: the fact survived, only the predicate
# was falsified, which is why nothing looked broken from the writer's side.
#
# WHAT THIS HARNESS HAS TO PROVE, and the trap it is built around: an arm that
# asserts "the handoff line is present" passes just as well on a row that never
# had a loop spec, because the string is simply absent in both. So every positive
# arm here is paired with an ANCHOR that shows the same assertion FAILING on the
# unfixed shape — the no-loop-spec control row (T4) and the pre-fix column state.
# Without those, the whole file is a tautology.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
as_agent() { local _w="$1"; shift; ( actor_seam_as "$_w"; "$@" ); }
SRC=src
TMP="$(mktemp -d /tmp/gate-handoff-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf()    { jq -r "$1" 2>/dev/null; }

# The DERIVED line, read the way a human reads it: the plain-text `task show`
# render, not the column. Grading the column would grade the fact that survived,
# never the predicate that broke.
show_handoff() { ( JSON_MODE=0; as_agent "$1" cmd_task_show "$2" 2>/dev/null ) | grep -E '^ *handoff:' | sed 's/^ *//'; }

tasks_db_init

# ---------------------------------------------------------------- fixture -----
out=$(as_agent maker cmd_task_add --assignee=maker --verifier=reviewer \
      --body="implement it" -- "gate handoff fixture" 2>"$TMP/err")
tid=$(printf '%s' "$out" | jf '.data.id')
tident=$(printf '%s' "$out" | jf '.data.ident')

# T1 — the maker delivers.
as_agent maker cmd_task_start "$tid" >/dev/null 2>&1
route=$(as_agent maker cmd_task_done "$tid" --result="ready" 2>"$TMP/err")
h1=$(show_handoff maker "$tid")
[[ "$(printf '%s' "$route" | jf '.data.handoff')" == "delivered" && "$h1" == handoff:*delivered* ]] \
  && ok_t "T1 maker delivery renders 'handoff: delivered'" \
  || bad_t "T1 delivered" "route=$route show=$h1"

# T2 — the verifier opens it. This is the DIVE-2619 repro's middle step and it
# matters: the ACKed row is the one whose loss was hardest to notice, because
# `reviewing` is what a reader sees right up until it disappears.
as_agent reviewer cmd_task_start "$tid" >/dev/null 2>&1
h2=$(show_handoff maker "$tid")
[[ "$h2" == handoff:*reviewing* ]] \
  && ok_t "T2 verifier start renders 'handoff: reviewing'" \
  || bad_t "T2 reviewing" "show=$h2"

# T3 — THE FIX. A third party (neither maker nor verifier) files a gate. Before
# DIVE-2624 this wrote assignee=intruder and the handoff line vanished entirely.
as_agent intruder cmd_task_need "$tid" --type=decision --tier=1 \
  --ask="which branch should this land on" --options="main|next" --recommend="main" >/dev/null 2>&1
h3=$(show_handoff maker "$tid")
state3=$(db "SELECT status||'|'||assignee||'|'||COALESCE(gate_filed_by,'') FROM tasks WHERE id=$tid;")
[[ "$h3" == handoff:*reviewing* ]] \
  && ok_t "T3 handoff SURVIVES a third-party gate filing" \
  || bad_t "T3 handoff destroyed by gate filing" "show='$h3' state=$state3"
[[ "$state3" == "blocked|reviewer|intruder" ]] \
  && ok_t "T3 gate blocks the row, verifier keeps it, filer recorded in gate_filed_by" \
  || bad_t "T3 row state" "got=$state3 want=blocked|reviewer|intruder"

# T3b — the fix must not cost the resume ping its target. `task need` no longer
# moves the assignee, so `task answer` reads gate_filed_by to find who to wake.
# Graded off the answer's own emitted `owner`, not off the SQL text.
ans=$(as_agent intruder cmd_task_answer "$tid" --value="main" 2>"$TMP/err")
[[ "$(printf '%s' "$ans" | jf '.data.owner')" == "intruder" ]] \
  && ok_t "T3b answer resumes the FILER, not the row's holder" \
  || bad_t "T3b resume target" "$ans"
h3b=$(show_handoff maker "$tid")
[[ "$h3b" == handoff:*reviewing* ]] \
  && ok_t "T3b handoff still stands after the gate is answered" \
  || bad_t "T3b post-answer handoff" "show='$h3b'"

# T4 — ANCHOR / MUTATION CONTROL. A row with NO loop spec. The guard must be
# narrow: filing a gate here still takes the assignee (that is the DIVE-891
# owner-of-record behaviour, unchanged), and the handoff line is absent BOTH
# sides of the filing. If T3 ever passes while this arm also reports a surviving
# handoff, T3 is matching a string that is always there and proves nothing.
p=$(as_agent worker cmd_task_add --assignee=worker --body="plain" -- "no loop spec" 2>"$TMP/err")
pid=$(printf '%s' "$p" | jf '.data.id')
hp_before=$(show_handoff worker "$pid")
as_agent intruder cmd_task_need "$pid" --type=decision --tier=1 \
  --ask="which colour" --options="red|blue" --recommend="red" >/dev/null 2>&1
hp_after=$(show_handoff worker "$pid")
pstate=$(db "SELECT assignee FROM tasks WHERE id=$pid;")
[[ -z "$hp_before" && -z "$hp_after" && "$pstate" == "intruder" ]] \
  && ok_t "T4 anchor: no loop spec => no handoff line either side, assignee still moves" \
  || bad_t "T4 anchor" "before='$hp_before' after='$hp_after' assignee=$pstate"

# T5 — the DIVE-2196 converse, unchanged: when the VERIFIER files the gate it is
# an act of review, so the ACK is stamped. The preserve-CASE is a no-op here by
# construction (assignee=verifier=filer) and must stay one.
q=$(as_agent maker cmd_task_add --assignee=maker --verifier=reviewer -- "verifier escalates" 2>"$TMP/err")
qid=$(printf '%s' "$q" | jf '.data.id')
as_agent maker cmd_task_start "$qid" >/dev/null 2>&1
as_agent maker cmd_task_done "$qid" --result="ready" >/dev/null 2>&1
as_agent reviewer cmd_task_need "$qid" --type=decision --tier=1 \
  --ask="is this in scope" --options="yes|no" --recommend="yes" >/dev/null 2>&1
qstate=$(db "SELECT assignee||'|'||CASE WHEN handoff_ack_at IS NULL THEN 'noack' ELSE 'ack' END FROM tasks WHERE id=$qid;")
hq=$(show_handoff maker "$qid")
[[ "$qstate" == "reviewer|ack" && "$hq" == handoff:*reviewing* ]] \
  && ok_t "T5 verifier's own filing keeps the row and stamps the review ACK" \
  || bad_t "T5 verifier filing" "state=$qstate show='$hq'"

# ------------------------------------------------- iteration accounting (b) ---
# The counter is read as "times the verifier sent it back". A re-delivery that
# restores a handoff is not rework and must not inflate it.
r=$(as_agent maker cmd_task_add --assignee=maker --verifier=reviewer -- "iteration accounting" 2>"$TMP/err")
rid=$(printf '%s' "$r" | jf '.data.id')
as_agent maker cmd_task_start "$rid" >/dev/null 2>&1
as_agent maker cmd_task_done "$rid" --result="pass 1" >/dev/null 2>&1
i1=$(db "SELECT iteration FROM tasks WHERE id=$rid;")
[[ "$i1" == "1" ]] && ok_t "T6 first delivery is iteration 1" || bad_t "T6 first delivery" "iteration=$i1"

# T7 — restore. The row comes off the verifier WITHOUT a verdict (here by the
# hand correction someone runs after a mis-routed row: `task assign` back to the
# maker) and the maker re-delivers the SAME pass. Note the fixture cannot be "the
# maker just runs done twice": DIVE-477's writer-is-not-grader guard refuses a
# second done on a row that is still delivered, and with T3's fix in place a gate
# filing no longer un-delivers it either. So a restore now needs an explicit
# un-delivery — which is exactly the situation the counter kept mis-labelling.
as_agent reviewer cmd_task_assign "$rid" maker >/dev/null 2>&1
red=$(as_agent maker cmd_task_done "$rid" --result="pass 1 (restored)" 2>"$TMP/err")
i2=$(db "SELECT iteration FROM tasks WHERE id=$rid;")
[[ "$i2" == "1" ]] \
  && ok_t "T7 a re-delivery with no reject in between does NOT bump the counter" \
  || bad_t "T7 restore inflated the counter" "iteration=$i2 (want 1) out=$red"
printf '%s' "$red" | jf '.data.iteration' | grep -qx 1 \
  && ok_t "T7 the emitted iteration matches the stored one" \
  || bad_t "T7 emitted iteration" "$red"

# T8 — a REAL second pass. The verifier bounces it; the maker's next delivery is
# rework and must bump. This is the arm that stops T7 being "never bump again".
as_agent reviewer cmd_task_reject "$rid" --feedback="missed the criteria" >/dev/null 2>&1
rej=$(db "SELECT COALESCE(handoff_rejected_at,'') FROM tasks WHERE id=$rid;")
[[ -n "$rej" ]] && ok_t "T8 reject stamps handoff_rejected_at" || bad_t "T8 reject clock" "empty"
as_agent maker cmd_task_start "$rid" >/dev/null 2>&1
as_agent maker cmd_task_done "$rid" --result="pass 2" >/dev/null 2>&1
i3=$(db "SELECT iteration FROM tasks WHERE id=$rid;")
[[ "$i3" == "2" ]] \
  && ok_t "T8 a delivery after a verifier reject DOES bump the counter" \
  || bad_t "T8 rework not counted" "iteration=$i3 (want 2)"

# T8b — the reject is a TOKEN and the delivery SPENDS it. Graded directly, because
# the alternative implementation (compare handoff_rejected_at against
# handoff_delivered_at) is observationally identical to this one whenever the two
# writes land in different seconds — and passes T9 by luck on a slow box while
# failing it on CI, which is exactly what happened. Asserting the clear makes the
# distinction visible without depending on how fast the machine is.
spent=$(db "SELECT COALESCE(handoff_rejected_at,'CLEARED') FROM tasks WHERE id=$rid;")
[[ "$spent" == "CLEARED" ]] \
  && ok_t "T8b the delivery that counts a reject also consumes it" \
  || bad_t "T8b reject token not consumed" "handoff_rejected_at=$spent"

# T9 — and the restore rule still holds on the far side of a real bump, so the
# reject clock is compared against the CURRENT delivery and not merely "ever set".
# Without this arm T8 would also pass on a naive "bump whenever handoff_rejected_at
# IS NOT NULL", which would count every delivery after the first reject as rework.
as_agent reviewer cmd_task_assign "$rid" maker >/dev/null 2>&1
as_agent maker cmd_task_done "$rid" --result="pass 2 (restored)" >/dev/null 2>&1
i4=$(db "SELECT iteration FROM tasks WHERE id=$rid;")
[[ "$i4" == "2" ]] \
  && ok_t "T9 a stale reject clock does not re-arm the bump" \
  || bad_t "T9 stale reject clock" "iteration=$i4 (want 2)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
