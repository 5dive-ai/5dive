#!/usr/bin/env bash
# DIVE-3098 — a GRADED-BUT-UNMERGED row is TERMINAL FOR THE VERIFIER and
# NON-TERMINAL FOR THE ROW. Policy decided by olivia
# (olivia/decisions/2026-08-09-graded-but-unmerged-is-terminal-for-the-verifier.md);
# this harness grades the BUILD.
#
# WHY THE ROW EXISTS. main's false-done sweep found DIVE-2645/#427 and
# DIVE-2743/#485 closed `done` with the work not on main. The prescribed remedy
# ("bind delivery_ref before you close") is unfollowable for that class: #427's PR
# was created 12 minutes AFTER the close, #485's TEN SECONDS after. The close and
# the PR-open are one motion and the close runs first, because the close is the half
# a goal loop reads as finished. So verifiers were pushed to a false `done` by the
# instruments. See community/wiki/the-close-runs-before-the-pr-exists.md.
#
# ONE PREDICATE, FOUR READERS — the whole point of the change. `_TASKS_TFV_SQL`
# (lib/tasks_db.sh) is evaluated by `task ls`'s render, `_task_terminal_for_verifier`,
# the goal-hook clause, and the rot-nudger's exclusion. A row the nudger exempts but
# the render still paints `todo` is the original bug in different clothes, so the arms
# below check all four against the SAME fixture.
#
# ANTI-GOAL, asserted not assumed: no new `status` value. `done` keeps meaning
# merged-to-main and the row stays OPEN — arm C3.
#
# Run: bash tests/graded_but_unmerged_terminal_unit.sh (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive3098.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"; set +e

SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() { local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"; }
audit_log() { return 0; }
registry_read() { printf '%s' '{"agents":{}}'; }
_hb_agent_idle() { return 0; }

tasks_db_init
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }

ME=$(task_actor "")     # this harness's actor == the VERIFIER in every fixture
# MAKER must never equal $ME. It was hardcoded "dev", which is a REAL agent on this
# fleet: run by agent-dev, ME=="dev"=="$MAKER", `task add` correctly refuses
# assignee==verifier (a maker cannot grade itself), EVERY fixture failed to create,
# and the harness reported a wall of red that reads as a product regression. It was
# green for every other seat, so it looked tree-related and got blamed on main.
# A reserved fake cannot collide with any actor, present or future, and is what
# projects/5dive/CLAUDE.md already requires of fixtures. Asserted, not assumed:
# a future rename that reintroduces the collision must fail loudly here, not silently
# stop creating rows.
MAKER="fixturemaker"
[[ "$MAKER" != "$ME" ]] || { printf 'FATAL: fixture maker (%s) == this harness actor (%s); every row would be refused as assignee==verifier. Pick a MAKER no real agent can be named.\n' "$MAKER" "$ME" >&2; exit 1; }

# mkrow <mode> — build one delivered maker->verifier row, aged past the nudge
# window, then apply the mode. Modes are the four populations the predicate must
# separate. handoff_delivered_at is aged so the CAUSE of a nudge is genuinely
# arranged: every mode below WOULD be pinged if the exemption did not fire, which
# is what makes an absence informative (acceptance b).
mkrow() {
  local mode="$1" id
  # assignee=MAKER at creation: `task add` refuses assignee==verifier by design
  # (a maker cannot grade itself). The UPDATE below then reproduces exactly what
  # _task_route_to_verifier does at delivery — assignee moves to the verifier and
  # maker_agent records who built it.
  id=$(addt "row-$mode" --assignee="$MAKER" --verifier="$ME" --priority=medium)
  [[ "$id" =~ ^[0-9]+$ ]] || { bad_t "FIXTURE $mode could not be created" "addt returned '$id'"; printf '0'; return; }
  db "UPDATE tasks SET maker_agent='${MAKER}', assignee='${ME}', verifier='${ME}',
        handoff_delivered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-30 minutes'),
        handoff_ack_at=NULL, handoff_stale_pinged_at=NULL, status='todo'
      WHERE id=${id};"
  case "$mode" in
    graded_and_bound)
      ( cmd_task_verify "$id" --no-done --result="graded by reading the diff" ) >/dev/null 2>&1
      db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/1' WHERE id=${id};" ;;
    graded_no_ref)
      ( cmd_task_verify "$id" --no-done --result="graded by reading the diff" ) >/dev/null 2>&1 ;;
    ref_no_grade)
      db "UPDATE tasks SET delivery_ref='https://github.com/5dive-ai/5dive/pull/1' WHERE id=${id};" ;;
    self_graded)   # the forgery arm: maker graded their own row
      db "UPDATE tasks SET graded_at=datetime('now'), graded_by='${MAKER}',
            delivery_ref='https://github.com/5dive-ai/5dive/pull/1' WHERE id=${id};" ;;
  esac
  printf '%s' "$id"
}
# Match the GAP#2 delivery nudge specifically. `grep -q .` would also match the
# gap#3 fleet-idle alarm, so an unrelated alarm would read as "the delivery was
# nudged" — assert on a signal only the system under test can produce.
# Must match the gap#2 nudge FOR THIS ROW. Two earlier versions of this helper were
# wrong in the same direction and both produced a confident green: `grep -q .` also
# matched the gap#3 fleet-idle alarm, and matching the gap#2 text alone also matched
# a nudge fired for a DIFFERENT row in the same sweep — the positive-control row is
# eligible on every call. Scope the assertion to the subject, not just the signal.
nudged() {
  local id="$1" ident hits
  ident=$(db "SELECT COALESCE(ident,'DIVE-'||id) FROM tasks WHERE id=${id};")
  [[ -n "$ident" ]] || { bad_t "nudged(): could not resolve ident for id=$id" "any match would be vacuous"; return 1; }
  # Clear the throttle BEFORE the sweep, not after. gap#2 skips any row whose
  # handoff_stale_pinged_at is already set, and an EARLIER nudged() call in this
  # harness sweeps the whole board — so a row pinged during someone else's call is
  # silently throttled out of its own. Measured: with the clear afterwards, deleting
  # the nudger exemption outright still scored 22/0, i.e. arm B graded nothing.
  db "UPDATE tasks SET handoff_stale_pinged_at=NULL WHERE id=${id};"
  : >"$SEND_LOG"
  _hb_stall_sweep >/dev/null 2>&1
  # Count gap#2 lines naming THIS row. Word-boundary anchored so DIVE-1 does not
  # match DIVE-10, and counted rather than piped: a `grep A | grep -q B` pipeline
  # reports the exit status of the second grep over the FIRST grep's output, which
  # is easy to get subtly wrong and returns a confident wrong answer either way.
  hits=$(grep -E 'Delivered-awaiting-verifier|delivered to you for review' "$SEND_LOG" 2>/dev/null \
         | grep -cE "\b${ident}\b" 2>/dev/null)
  [[ "${hits:-0}" -gt 0 ]]
}

echo "── the real verb stamps the structural marker (it must not be prose) ──"
G=$(mkrow graded_and_bound)
[[ "$(db "SELECT COALESCE(graded_at,'')<>'' FROM tasks WHERE id=${G};")" == "1" ]] \
  && ok_t "task verify --no-done --result= stamps graded_at" || bad_t "graded_at stamped"
[[ "$(db "SELECT COALESCE(graded_by,'') FROM tasks WHERE id=${G};")" == "$ME" ]] \
  && ok_t "graded_by records the ACTOR who graded ($ME)" || bad_t "graded_by is the actor" "got $(db "SELECT graded_by FROM tasks WHERE id=${G};")"
D=$(mkrow ref_no_grade)
( cmd_task_deliver "$D" --pr=https://github.com/5dive-ai/5dive/pull/2 --result="the maker typing a grade-shaped sentence" ) >/dev/null 2>&1
# The absence below is only meaningful if the row EXISTS and deliver actually wrote
# to it — otherwise this arm passes on a missing fixture, which is the same defect
# the positive control in (b) exists to prevent.
[[ "$(db "SELECT COALESCE(result,'') LIKE '%grade-shaped%' FROM tasks WHERE id=${D};")" == "1" ]] \
  && ok_t "PRECONDITION: deliver did write the maker's prose to this row" \
  || bad_t "PRECONDITION: deliver wrote the row" "the absence arm below would be vacuous"
[[ -z "$(db "SELECT COALESCE(graded_at,'') FROM tasks WHERE id=${D};")" ]] \
  && ok_t "the MAKER's task deliver --result= does NOT stamp graded_at (not forgeable in prose)" \
  || bad_t "deliver must not stamp graded_at" "a maker could buy the exemption by typing"

echo "── (a) the predicate, and the goal hook it answers ──"
_task_terminal_for_verifier "$G" && ok_t "A: predicate TRUE for grade + bound delivery_ref" || bad_t "A: predicate true"
clause=$(_hb_loop_terminal_clause "$ME" "$G" "DIVE-$G")
grep -q "GRADED AND WAITING ON A MERGE" <<<"$clause" \
  && ok_t "A: the goal-hook clause names it TERMINAL FOR THIS GOAL" || bad_t "A: hook clause emitted" "got: ${clause:0:90}"
grep -q "Treat the goal as MET and stop" <<<"$clause" \
  && ok_t "A: and tells the agent to STOP — the hook does not re-fire" || bad_t "A: clause says stop"
grep -q "$MAKER" <<<"$clause" && ok_t "A: the clause NAMES the merge owner ($MAKER)" || bad_t "A: clause names owner"
grep -q "does NOT close it: it DELIVERS it" <<<"$clause" \
  && bad_t "A: graded-and-waiting must OUTRANK the maker variant" "maker advice on an already-graded row" \
  || ok_t "A: it outranks the maker variant (no 'go deliver' on a graded row)"

echo "── (b) the rot-nudger, with the CAUSE arranged, plus its positive control ──"
P=$(mkrow ref_no_grade)
nudged "$P" && ok_t "B/POSITIVE CONTROL: an aged, ungraded delivery IS nudged (the window really elapsed)" \
             || bad_t "B/POSITIVE CONTROL: the nudger was going to fire" "absence below would prove nothing"
if nudged "$G"; then
  bad_t "B: a graded+bound row must be EXEMPT from the nudger" "still pinged; log=$(tr '\n' ';' <"$SEND_LOG" | head -c 300)"
  printf '   DEBUG tfv=%s ident=%s\n' \
    "$(db "SELECT CASE WHEN ${_TASKS_TFV_SQL} THEN 'TRUE' ELSE 'FALSE' END FROM tasks WHERE id=${G};")" \
    "$(db "SELECT COALESCE(ident,'DIVE-'||id) FROM tasks WHERE id=${G};")"
else
  ok_t "B: graded+bound is EXEMPT from the rot-nudger"
fi

echo "── (c) task ls renders it as its own thing and names the merge owner ──"
render=$( ( JSON_MODE=0; cmd_task_ls --all ) 2>/dev/null | grep "DIVE-${G}\|row-graded_and_bound" | head -1 )
printf '   render: %s\n' "$(sed 's/^ *//' <<<"$render")"
grep -q "graded->merge:${MAKER}" <<<"$render" \
  && ok_t "C: renders 'graded->merge:${MAKER}' — distinct, and names who owes the merge" \
  || bad_t "C: distinct render naming the owner" "got: $render"
grep -qE '\| *todo *\||\| *blocked *\||\| *in_progress *\|' <<<"$render" \
  && bad_t "C: must not read as todo/blocked/in_progress to the eye" "got: $render" \
  || ok_t "C: does not read as todo/blocked/in_progress"
[[ "$(db "SELECT status FROM tasks WHERE id=${G};")" == "todo" ]] \
  && ok_t "C3/ANTI-GOAL: underlying status is STILL todo — no new status value, done still means merged" \
  || bad_t "C3: no new status value" "status was mutated"

echo "── (d) NEGATIVE ARMS: neither half alone qualifies ──"
N1=$(mkrow graded_no_ref)
_task_terminal_for_verifier "$N1" && bad_t "D1: grade with NO delivery_ref must NOT qualify" "predicate true" || ok_t "D1: grade with NO delivery_ref does not qualify"
nudged "$N1" && ok_t "D1: and it still nudges" || bad_t "D1: still nudges"
grep -q "GRADED AND WAITING" <<<"$(_hb_loop_terminal_clause "$ME" "$N1" "DIVE-$N1")" \
  && bad_t "D1: and it must still fail the hook" "hook satisfied without a delivery_ref" || ok_t "D1: and it still fails the hook"
N2=$(mkrow ref_no_grade)
_task_terminal_for_verifier "$N2" && bad_t "D2: delivery_ref with NO grade must NOT qualify" "predicate true" || ok_t "D2: delivery_ref with NO grade does not qualify"
nudged "$N2" && ok_t "D2: and it still nudges" || bad_t "D2: still nudges"
grep -q "GRADED AND WAITING" <<<"$(_hb_loop_terminal_clause "$ME" "$N2" "DIVE-$N2")" \
  && bad_t "D2: and it must still fail the hook" "hook satisfied without a grade" || ok_t "D2: and it still fails the hook"
N3=$(mkrow self_graded)
_task_terminal_for_verifier "$N3" && bad_t "D3: a SELF-GRADED row must NOT qualify" "maker bought its own exemption" || ok_t "D3: self-graded (graded_by == maker) does not qualify"
nudged "$N3" && ok_t "D3: and it still nudges" || bad_t "D3: still nudges"

echo "── (e) DIVE-3428: a grade is NOT a latch — a live reject that post-dates it wins ──"
# Measured on DIVE-3315: graded_at 2026-08-12 (quinn, PASS), handoff_rejected_at
# 2026-08-16 (codex, FAIL). The reject four days newer, the board still painting
# `graded->merge:olivia`, and the /goal wrapper reading that render back as "TERMINAL
# FOR THIS GOAL ... Treat the goal as MET and stop".
#
# EVERY FIXTURE HERE IS BUILT BY THE REAL `task reject` VERB and only its CLOCK
# RELATION is then arranged. A raw-UPDATE fixture would prove the SQL agrees with
# itself while saying nothing about the state the product actually reaches — and the
# whole defect is that a real reject reaches a state the predicate cannot see.
mkreject() { # <how graded_at relates to the reject> -> id
  local rel="$1" id; id=$(mkrow graded_and_bound)
  [[ "$id" =~ ^[0-9]+$ ]] || { printf '0'; return; }
  ( cmd_task_reject "$id" --feedback="the diff does not do what the result claims" ) >/dev/null 2>&1
  case "$rel" in
    newer) db "UPDATE tasks SET graded_at=datetime(handoff_rejected_at,'-4 days') WHERE id=${id};" ;;
    tie)   db "UPDATE tasks SET graded_at=handoff_rejected_at WHERE id=${id};" ;;
    older) db "UPDATE tasks SET graded_at=datetime(handoff_rejected_at,'+1 minute') WHERE id=${id};" ;;
  esac
  printf '%s' "$id"
}
# E0/PRECONDITION. Three separate ways this section could go vacuously green: the
# verb refuses (no row state changes), the verb stops stamping the column, or a
# re-delivery spends the token before the assertion reads it. Assert the cause is
# present and in the real-world DIRECTION before grading any absence.
R0=$(mkrow graded_and_bound)
( cmd_task_reject "$R0" --feedback="bounced" ) >/dev/null 2>&1
[[ -n "$(db "SELECT COALESCE(handoff_rejected_at,'') FROM tasks WHERE id=${R0};")" ]] \
  && ok_t "E0/PRECONDITION: the real \`task reject\` verb stamps handoff_rejected_at" \
  || bad_t "E0/PRECONDITION: reject stamped the column" "every arm below would be vacuous"
[[ "$(db "SELECT handoff_rejected_at >= graded_at FROM tasks WHERE id=${R0};")" == "1" ]] \
  && ok_t "E0: and unarranged it lands at-or-after the grade — the older arm is the rare one, not the norm" \
  || bad_t "E0: reject lands at-or-after the grade" "got grade=$(db "SELECT graded_at FROM tasks WHERE id=${R0};") reject=$(db "SELECT handoff_rejected_at FROM tasks WHERE id=${R0};")"

R1=$(mkreject newer)
# MUTATION CONTROL, and it is the load-bearing half: prove the row is separated by
# the NEW conjunct and not by something the reject also changed (it moves status,
# assignee and result too). The pre-DIVE-3428 predicate, evaluated verbatim against
# the same fixture, must still say TRUE — otherwise the arms below pass for a reason
# that has nothing to do with this diff.
_TFV_PRE_3428="graded_at IS NOT NULL
       AND delivery_ref IS NOT NULL AND TRIM(delivery_ref) <> ''
       AND (maker_agent IS NULL OR graded_by IS NULL OR graded_by <> maker_agent)
       AND status NOT IN ('done','cancelled')"
[[ "$(db "SELECT CASE WHEN ${_TFV_PRE_3428} THEN 1 ELSE 0 END FROM tasks WHERE id=${R1};")" == "1" ]] \
  && ok_t "E1/MUTATION CONTROL: the pre-DIVE-3428 predicate says TRUE here — this fixture is the bug" \
  || bad_t "E1/MUTATION CONTROL: old predicate TRUE" "the absence arms below would not be grading this conjunct"
_task_terminal_for_verifier "$R1" \
  && bad_t "E1: a reject NEWER than the grade must NOT qualify" "predicate still true — a grade is being latched" \
  || ok_t "E1: a reject NEWER than the grade drops the row out of the predicate"
# THE WRAPPER ARM TAKES $MAKER, NOT $ME, AND THAT IS NOT A DETAIL. The clause opens
# with `WHERE ... assignee=<name>` and a reject moves assignee to the MAKER, so asking
# it as the verifier returns early on the row query and the arm passes without ever
# reaching the predicate — measured: with $ME it stayed green under the mutant that
# deleted the conjunct outright. The maker is also the seat the DIVE-3315 wrapper was
# actually handed to. Its discrimination control is E2 below: same actor, same shape,
# only the clock relation differs.
[[ "$(db "SELECT assignee FROM tasks WHERE id=${R1};")" == "$MAKER" ]] \
  && ok_t "E1/PRECONDITION: the reject moved the row to $MAKER, so the wrapper arm asks as the seat that holds it" \
  || bad_t "E1/PRECONDITION: assignee is $MAKER" "the clause would return early and the next arm would be vacuous"
grep -q "GRADED AND WAITING" <<<"$(_hb_loop_terminal_clause "$MAKER" "$R1" "DIVE-$R1")" \
  && bad_t "E1: and the /goal wrapper must not call it TERMINAL" "the DIVE-3315 instruction, reprinted" \
  || ok_t "E1: and the /goal wrapper no longer tells the agent to stop"
# BOTH board branches, because DIVE-3098 fixed two of them and this omission
# propagated to both: --all is where a reader who went looking for detail lands.
for view in --all ''; do
  r=$( ( JSON_MODE=0; cmd_task_ls ${view:+$view} ) 2>/dev/null | grep -E "\bDIVE-${R1}\b|row-graded_and_bound" | grep -E "\bDIVE-${R1}\b" | head -1 )
  if [[ -z "$r" ]]; then
    bad_t "E1: the rejected row is absent from \`task ls ${view:-(compact)}\`" "cannot grade a render that did not print"
  elif grep -q "graded->merge:" <<<"$r"; then
    bad_t "E1: \`task ls ${view:-(compact)}\` still renders graded->merge" "got: $(sed 's/^ *//' <<<"$r")"
  else
    ok_t "E1: \`task ls ${view:-(compact)}\` renders its plain status, not graded->merge"
  fi
done

# E2/POSITIVE CONTROL — the other arm, and it is what makes E1 a discrimination
# rather than a blanket suppression. graded_at is COALESCE'd (first grade wins), so a
# reject that PREDATES the first-ever grade is a verifier who bounced and then graded
# a pass without a re-delivery. That row is still waiting on a merge.
R2=$(mkreject older)
_task_terminal_for_verifier "$R2" \
  && ok_t "E2/POSITIVE CONTROL: a reject OLDER than the grade still qualifies — not a blanket suppression" \
  || bad_t "E2/POSITIVE CONTROL: older reject still qualifies" "the fix over-fires and hides genuine merge-waiting rows"
render2=$( ( JSON_MODE=0; cmd_task_ls --all ) 2>/dev/null | grep -E "\bDIVE-${R2}\b" | head -1 )
grep -q "graded->merge:${MAKER}" <<<"$render2" \
  && ok_t "E2: and it still renders graded->merge:${MAKER}" \
  || bad_t "E2: older reject still renders graded->merge" "got: $(sed 's/^ *//' <<<"$render2")"
# The wrapper's discrimination control: SAME actor and SAME post-reject row shape as
# E1, differing only in which clock is newer. Without this, E1's wrapper arm could be
# green because the clause never speaks to a maker at all.
grep -q "GRADED AND WAITING" <<<"$(_hb_loop_terminal_clause "$MAKER" "$R2" "DIVE-$R2")" \
  && ok_t "E2/CONTROL: and the wrapper DOES still say TERMINAL here — E1's silence is the clock, not the seat" \
  || bad_t "E2/CONTROL: wrapper terminal on the older-reject row" "E1's wrapper arm cannot distinguish anything"

# E3/THE TIE, which is why this conjunct is `<` and not the `<=` the row proposed.
# graded_at is stamped by verify's else-branch (`rc != 0 || no_done`), so a FAIL
# verify stamps it; a verifier who runs `task verify` then `task reject` lands both
# in the same second at datetime()'s one-second resolution — the same tie DIVE-2624
# measured on this exact column pair. `<=` hands that tie to the grade and reprints
# the label. The tie goes to the reject because the errors are not symmetric: a false
# graded->merge stops an agent on live work, a false plain status costs one read.
R3=$(mkreject tie)
[[ "$(db "SELECT handoff_rejected_at = graded_at FROM tasks WHERE id=${R3};")" == "1" ]] \
  && ok_t "E3/PRECONDITION: the tie fixture really has both stamps in the same second" \
  || bad_t "E3/PRECONDITION: timestamps equal" "this arm is not testing the tie"
_task_terminal_for_verifier "$R3" \
  && bad_t "E3: a same-second reject must NOT qualify" "the tie went to the grade — this is the \`<=\` bug" \
  || ok_t "E3: a same-second reject drops the row out too (the tie goes to the reject)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
