#!/usr/bin/env bash
# TIER: core — no sleeps, no network. Every arm reads a RESOLUTION off an
#   in-memory org chart, so the whole file is priced in milliseconds.
#
# DIVE-4823 — ROUTING RESOLVES PER ORG ROOT.
#
# `_task_resolve_coordinator` answered a BOARD-WIDE question with no argument:
# an exact `role='coordinator'` tag when exactly one agent holds it; else the
# lone holder of the ` coordinator` prose marker; else the lone org root; else
# nothing. All three tiers are board-wide, which is why a second root silently
# disabled the whole ladder — teal-fox grew nine roots and every unassigned row
# landed nowhere (DIVE-4555). This row gives the resolver an OPTIONAL subject
# and walks the ladder inside that subject's own root + subtree.
#
# WHAT THIS HARNESS GRADES, in the order the claims matter:
#
#   A. THE SINGLE-ROOT NO-OP — the headline. On a chart with one root R every
#      on-chart agent has root_of = R and subtree(R) is the whole chart, so
#      tiers 1-2 are today's board-wide uniqueness and the last tier returns R =
#      today's lone-root tier. Subject or no subject, the answer must be the
#      same value. This is asserted at all three tiers plus the empty case,
#      because "no-op" is a claim about the WHOLE ladder, not about one rung.
#   B. THE MULTI-ROOT FIX — two roots, each subtree resolving its own
#      coordinator, and the board-wide (no-subject) call still returning the
#      historical nothing.
#   C. NO LEAK ACROSS THE FENCE — a tagged agent inside one subtree must not be
#      visible to the other. This is the arm that would go red if the subtree
#      predicate were dropped and the scoping collapsed back to board-wide, so
#      it is mutation-tested below.
#   D. THE FALLTHROUGHS — an off-chart subject, an empty subject and a
#      reports_to CYCLE all resolve EXACTLY as the no-argument call does.
#   E. THE GATE NOTIFIER takes the same subject and keeps DIVE-4365's property:
#      an untagged subtree is as empty as an untagged board, and the fallback is
#      the coordinator resolved in the SAME scope.
#   F. STRUCTURAL — the ten call sites that have a subject in scope pass one.
#
# WHAT IT DELIBERATELY DOES NOT GRADE: that the existing routing suites still
# pass. That is claim A's real evidence and it is bought by RUNNING them
# unmodified, not by copying their fixtures here.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/per-root-routing.XXXXXX)

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()   { # <label> <want> <got>
  [[ "$2" == "$3" ]] && ok_t "$1" || fail_t "$1 — want '$2' got '$3'"
}

chart() { db "DELETE FROM agents_org;"; }
place() { # <name> <role|-> <manager|->
  local _r="$2" _m="$3"
  [[ "$_r" == "-" ]] && _r=""
  db "INSERT INTO agents_org (name,role,reports_to) VALUES ($(sqlq "$1"),$(sqlq "$_r"),$( [[ "$_m" == "-" ]] && printf 'NULL' || sqlq "$_m" ));"
}

# `_board_coordinator_v0` — `_task_resolve_coordinator` EXACTLY as it stood at
# origin/main 6ffb4016, before this row. It is copied in verbatim so "unchanged"
# is a MEASUREMENT against the old ladder on every fixture below, not an
# assertion against a literal a future edit could quietly re-baseline. Arm A0
# runs it against the live function on each chart this file builds.
_board_coordinator_v0() {
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE role='coordinator';")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE role='coordinator' LIMIT 1;"
    return
  fi
  local _marker="lower(' '||COALESCE(role,'')) LIKE '% coordinator%'"
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE ${_marker};")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE ${_marker} LIMIT 1;"
    return
  fi
  if [[ "$(db "SELECT COUNT(*) FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org);")" == "1" ]]; then
    db "SELECT name FROM agents_org WHERE reports_to IS NULL OR reports_to NOT IN (SELECT name FROM agents_org) LIMIT 1;"
  fi
}

# A0 — the no-subject call is the OLD function, on whatever chart is loaded.
# Every fixture in this file calls it, so the board-wide no-op is graded once
# per chart shape rather than once.
a0_t() { # <label>
  eq_t "A0 no-subject call == the pre-DIVE-4823 ladder ($1)" "$(_board_coordinator_v0)" "$(_task_resolve_coordinator)"
}

# A0b — on a SINGLE-ROOT chart the SUBJECT-carrying call is also the old
# function, for every on-chart agent. That is the whole no-op claim, and it is
# checked exhaustively over the chart rather than at a hand-picked seat.
a0b_t() { # <label>
  local _want _n _bad=""
  _want="$(_board_coordinator_v0)"
  while IFS= read -r _n; do
    [[ -n "$_n" ]] || continue
    [[ "$(_task_resolve_coordinator "$_n")" == "$_want" ]] || _bad="${_bad} ${_n}=>$(_task_resolve_coordinator "$_n")"
  done < <(db "SELECT name FROM agents_org ORDER BY name;")
  [[ -z "$_bad" ]] && ok_t "A0b single root: EVERY on-chart subject == the old ladder ('$_want') ($1)"     || fail_t "A0b single root ($1): these subjects diverged from '$_want':${_bad}"
}

# ── A. THE SINGLE-ROOT NO-OP ────────────────────────────────────────────────
#
# The live fleet's shape: a lone root with a lead under it and a maker under the
# lead. Each tier is exercised in turn and, at every one, the subject-carrying
# call must return the value the no-argument call returns. A no-op asserted only
# at the tier the change touches is not a no-op.

# A1 — tier 3, the lone-root fallback: nothing tagged anywhere.
chart
place olivia 'AI CEO — conducts the fleet (advisory)' -
place main   'engineering + infra + the 5dive CLI'    olivia
place dev3   'feature work'                           main
a0_t "A1 untagged"; a0b_t "A1 untagged"
eq_t "A1 lone root, untagged: no subject resolves the root"      "olivia" "$(_task_resolve_coordinator)"
eq_t "A1 lone root, untagged: subject=dev3 resolves the same"    "olivia" "$(_task_resolve_coordinator dev3)"
eq_t "A1 lone root, untagged: subject=main resolves the same"    "olivia" "$(_task_resolve_coordinator main)"
eq_t "A1 lone root, untagged: subject=the root itself"           "olivia" "$(_task_resolve_coordinator olivia)"

# A2 — tier 2, the DIVE-2041 prose marker on a NON-root seat. The subject-scoped
# call must still prefer the marker over the root, or the marker tier has been
# quietly demoted for every caller that passes a subject.
chart
place olivia 'AI CEO — conducts the fleet (advisory)' -
place main   'engineering lead — fleet coordinator'   olivia
place dev3   'feature work'                           main
a0_t "A2 prose marker"; a0b_t "A2 prose marker"
eq_t "A2 lone root, prose marker: no subject picks the marker holder"    "main" "$(_task_resolve_coordinator)"
eq_t "A2 lone root, prose marker: subject=dev3 picks the same"           "main" "$(_task_resolve_coordinator dev3)"
eq_t "A2 lone root, prose marker: subject=olivia (the root) picks the same" "main" "$(_task_resolve_coordinator olivia)"

# A3 — tier 1, the exact role tag, which must outrank a prose marker elsewhere.
chart
place olivia 'AI CEO — fleet coordinator' -
place main   'coordinator'                olivia
place dev3   'feature work'               main
a0_t "A3 exact tag"; a0b_t "A3 exact tag"
eq_t "A3 lone root, exact tag: no subject prefers the exact tag"  "main" "$(_task_resolve_coordinator)"
eq_t "A3 lone root, exact tag: subject=dev3 prefers the same"     "main" "$(_task_resolve_coordinator dev3)"

# A4 — the EMPTY fourth tier on a board that is genuinely ambiguous: two roots,
# nothing tagged, NO subject. This is the historical answer and the no-subject
# readers (the digest, the pinned banner, `task doctor`) still depend on it.
chart
place olivia 'AI CEO'       -
place marcus 'ops lead'     -
place dev3   'feature work' olivia
a0_t "A4 two roots untagged"
eq_t "A4 two roots, no subject: still empty, as today" "" "$(_task_resolve_coordinator)"

# ── B. THE MULTI-ROOT FIX ───────────────────────────────────────────────────
#
# Two teams on one board. Each root's subtree resolves its own coordinator, and
# the board-wide call keeps returning nothing — the change is ADDITIVE.
chart
place olivia 'AI CEO'                     -
place main   'engineering — coordinator'  olivia
place dev3   'feature work'               main
place marcus 'ops root'                   -
place ops    'ops work'                   marcus
eq_t "B1 two roots: a subject under olivia resolves olivia's tagged coordinator" "main"   "$(_task_resolve_coordinator dev3)"
eq_t "B2 two roots: a subject under marcus, nothing tagged, resolves its OWN root" "marcus" "$(_task_resolve_coordinator ops)"
eq_t "B3 two roots: the root itself as subject resolves its own team"            "marcus" "$(_task_resolve_coordinator marcus)"
# B4 — the no-subject call on this fixture. NOT empty: `main` is the single
# board-wide marker holder here, so the old tier 2 answers it and so does the
# new one. Graded against the old ladder rather than a literal, because the
# claim is "unchanged", not "empty" — a4 above is the genuinely-empty shape.
a0_t "B multi-root, one tagged"

# B5 — root_of is the primitive both tiers stand on; assert it directly so a
# failure upstream is readable as a walk defect and not as a ladder defect.
eq_t "B5 root_of walks two levels to the right root"    "olivia" "$(_task_org_root_of dev3)"
eq_t "B5 root_of on the other tree"                     "marcus" "$(_task_org_root_of ops)"
eq_t "B5 root_of of a root is itself"                   "marcus" "$(_task_org_root_of marcus)"

# ── C. NO LEAK ACROSS THE FENCE ─────────────────────────────────────────────
#
# THE LOAD-BEARING ARM. Both trees now carry a tagged coordinator. Board-wide
# that is two holders = ambiguous = nothing; per-root each must see only its
# own. If the subtree predicate were dropped, C1/C2 would read each other's
# answer or go empty — which is exactly what the mutation at the bottom proves.
chart
place olivia 'AI CEO'                     -
place main   'engineering — coordinator'  olivia
place dev3   'feature work'               main
place marcus 'ops root'                   -
place ops    'ops — coordinator'          marcus
a0_t "C two tagged, one per tree"
eq_t "C1 a tag in the other subtree does not leak in (olivia's tree)" "main" "$(_task_resolve_coordinator dev3)"
eq_t "C2 a tag in the other subtree does not leak in (marcus's tree)" "ops"  "$(_task_resolve_coordinator ops)"
eq_t "C3 board-wide, two holders is still ambiguous"                  ""     "$(_task_resolve_coordinator)"

# C4 — AMBIGUITY SURVIVES INSIDE A SUBTREE. Two holders in ONE tree must fall
# through to that tree's root, not pick one. Scoping a uniqueness test must not
# turn it into a "first match wins" test.
chart
place olivia 'AI CEO'                       -
place main   'engineering — coordinator'    olivia
place dev3   'makers — coordinator'         olivia
a0_t "C4 two holders, one tree"
eq_t "C4 two holders inside one subtree: falls through to that subtree's root" "olivia" "$(_task_resolve_coordinator dev3)"

# ── D. THE FALLTHROUGHS ─────────────────────────────────────────────────────
#
# Every one of these must equal the NO-ARGUMENT answer on the same chart. They
# are written as a comparison against that live value rather than a literal, so
# the arm still means "identical to board-wide" if the fixture ever changes.
chart
place olivia 'AI CEO'       -
place main   'engineering'  olivia
place dev3   'feature work' main
a0_t "D fallthroughs"; a0b_t "D fallthroughs"
_board="$(_task_resolve_coordinator)"
eq_t "D1 off-chart subject falls through to the board-wide answer" "$_board" "$(_task_resolve_coordinator nobody-here)"
eq_t "D2 empty subject is the no-argument call"                    "$_board" "$(_task_resolve_coordinator '')"
eq_t "D3 off-chart subject has no root"                            ""        "$(_task_org_root_of nobody-here)"

# D4 — A reports_to CYCLE. The chart is agent-writable, so a loop is reachable.
# No member of a cycle is a root by the board-wide predicate, so "no root" is
# the honest answer — and the walk must TERMINATE. A hang here is the failure
# this arm exists for, so it is run under a timeout and the timeout is graded.
chart
place olivia 'AI CEO'       -
place loop_a 'a'            olivia
place loop_b 'b'            loop_a
db "UPDATE agents_org SET reports_to='loop_b' WHERE name='loop_a';"
_cyc_out=$( (_task_org_root_of loop_a) & _p=$!; ( sleep 10; kill -9 $_p 2>/dev/null ) & _w=$!; wait $_p 2>/dev/null; kill $_w 2>/dev/null )
_cyc_rc=$?
[[ "$_cyc_rc" == "0" ]] && ok_t "D4 a reports_to cycle terminates (no hang)" \
  || fail_t "D4 the cycle walk did not terminate cleanly (rc=$_cyc_rc)"
eq_t "D4 a cycle yields no root"                                   ""        "$_cyc_out"
eq_t "D4 a cycle-bound subject falls through to the board-wide ladder" "olivia" "$(_task_resolve_coordinator loop_a)"

# ── E. THE GATE NOTIFIER ────────────────────────────────────────────────────
#
# DIVE-4365's property is that an UNTAGGED chart resolves exactly as it does
# today. Per-root must not weaken it in either direction.
chart
place olivia 'AI CEO'                       -
place main   'engineering'                  olivia
place dev3   'feature work'                 main
place marcus 'ops root'                     -
place ops    'ops — gate notifier'          marcus
eq_t "E1 untagged subtree: explicit probe is empty, as on an untagged board" "" "$(_task_gate_notifier_explicit dev3)"
eq_t "E2 untagged subtree: the notifier falls back to that team's coordinator" "olivia" "$(_task_resolve_gate_notifier dev3)"
eq_t "E3 tagged subtree: the explicit holder inside it"                        "ops"    "$(_task_gate_notifier_explicit ops)"
eq_t "E4 tagged subtree: the notifier is that holder"                          "ops"    "$(_task_resolve_gate_notifier ops)"
eq_t "E5 the tag in marcus's tree does not leak into olivia's"                 ""       "$(_task_gate_notifier_explicit dev3)"

# E6 — the fallback resolves in the SAME scope. A subtree notifier falling back
# to a BOARD-WIDE coordinator would return nothing on a multi-root chart, which
# is the DIVE-4365 no-op breaking in the least visible possible way.
eq_t "E6 the notifier's fallback is scoped, not board-wide" "olivia" "$(_task_resolve_gate_notifier dev3)"

# ── F. STRUCTURAL — the call sites pass a subject ───────────────────────────
#
# Read off the SOURCE, because the alternative is standing up ten commands. A
# site that reverts to the bare call is a silent half-revert of this row: the
# function keeps its parameter, every unit arm above stays green, and routing
# goes back to board-wide for that path only.
declare -a SITES=(
  "src/task/crud.sh|_task_resolve_coordinator \"\$(task_actor"
  "src/cmd_goal.sh|_task_resolve_coordinator \"\$(task_actor"
  "src/task/loops.sh|_task_resolve_coordinator \"\$creator\""
  "src/cmd_heartbeat.sh|_task_resolve_coordinator \"\$filer\""
  "src/task/routing.sh|_task_resolve_coordinator \"\$_assignee\""
  "src/task/routing.sh|_task_resolve_coordinator \"\$_filer\""
  "src/task/notify.sh|_task_resolve_gate_notifier \"\$_hf\""
)
for _s in "${SITES[@]}"; do
  _f="${_s%%|*}"; _pat="${_s#*|}"
  grep -qF -- "$_pat" "$_f" \
    && ok_t "F ${_f##*/} passes a subject: ${_pat}" \
    || fail_t "F ${_f##*/} does NOT pass a subject — expected to find: ${_pat}"
done
# The two objective planners resolve the subject from the row rather than a
# local, so they are matched on the query shape instead of a variable name.
_obj_n=$(grep -cF '_task_resolve_coordinator "$(db "SELECT COALESCE(created_by,'"''"') FROM objectives' src/cmd_objective.sh)
eq_t "F both objective planners pass the objective's creator" "2" "$_obj_n"

# need.sh's two gate-authorization arms are the ones DELIBERATELY left
# board-wide: they ask "may this caller retire someone else's gate", not "whose
# team is this". Passing a subject there narrows a standing grant — measured
# against tests/gate_withdraw_unit.sh T-2382a, which builds a two-root chart on
# purpose. Asserted as an ABSENCE so a later "finish the wiring" edit has to
# read this note first.
_need_subj=$(grep -cE '_task_resolve_coordinator "\$[ew]_filer"' src/task/need.sh)
eq_t "F need.sh keeps both gate-authorization calls board-wide" "0" "$_need_subj"

# And the six board-level readers must NOT have grown a subject — an invented
# filer there is a guess about whose phone rings.
for _f in src/cmd_doctor.sh src/cmd_org.sh src/task/inbox.sh src/task/status.sh src/task/notify.sh; do
  grep -qE '_task_resolve_coordinator[[:space:]]*(2>|\)|$)' "$_f" \
    && ok_t "F ${_f##*/} keeps a board-level (no-subject) call" \
    || fail_t "F ${_f##*/} lost its board-level call"
done

# ── MUTATION — the subtree predicate is what C stands on ────────────────────
#
# Delete the subtree scoping out of `declare -f` output and re-run arm C. This
# mutates the PREDICATE THAT SHIPS rather than substituting a stub: a stub that
# returns the right name proves only that a stub returns the right name.
_mut=$(declare -f _task_resolve_coordinator | sed 's/name IN (SELECT name FROM _sub) AND //g')
( eval "$_mut"
  chart
  place olivia 'AI CEO'                     -
  place main   'engineering — coordinator'  olivia
  place dev3   'feature work'               main
  place marcus 'ops root'                   -
  place ops    'ops — coordinator'          marcus
  [[ "$(_task_resolve_coordinator dev3)" == "main" && "$(_task_resolve_coordinator ops)" == "ops" ]]
) 2>/dev/null
[[ $? -ne 0 ]] \
  && ok_t "MUT unscoping the subtree predicate turns arm C RED" \
  || fail_t "MUT arm C passed with the subtree predicate REMOVED — it is not testing the scoping"

printf '\n%s\n' "arms: $((PASS+FAIL))  pass: $PASS  fail: $FAIL"
[[ $FAIL -eq 0 ]]
