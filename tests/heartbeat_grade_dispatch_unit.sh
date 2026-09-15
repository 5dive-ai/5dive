#!/usr/bin/env bash
# DIVE-4576 — THE GRADER DISPATCH CARRIES THE METHOD AND THE BUDGET.
#
# THE DEFECT. A grader — a heartbeat-woken verifier seat, or an ephemeral clone
# that starts from nothing — was told to "GRADE it" and nothing more. The only
# method a cold seat can invent from that is re-derivation: redo the maker's work
# and see whether it agrees, which is a second full session per close and two on
# a reject. Since this row the maker's result NAMES its evidence, so the dispatch
# can name the cheap method: re-run what is named, at the sha that is named.
#
# WHAT THESE ARMS GRADE, and why one of them is unusual. Parts 1-3 read the exact
# bytes a seat would receive, which is the only thing that reaches it. Part 4 is
# the unusual one: `_hb_is_grade_wake` is the VERIFIER variant's predicate
# restated for the base line (which is assembled before the clause runs and
# cannot read a variable set inside a command substitution), and a restated
# predicate drifts. So every row shape is run through BOTH, and a disagreement
# in either direction is a FAIL — that agreement is the only thing keeping one
# dispatch from stating two different turn caps in one sentence.
# Run: bash tests/heartbeat_grade_dispatch_unit.sh  (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-grade-dispatch.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/verify_policy.sh lib/tasks_db.sh lib/actor.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh \
         task/grader_pool.sh task/grader_process.sh; do
  # The two grader files are sourced EXPLICITLY: `cmd_task.sh`'s lazy loader does
  # not reach them (they arrive through build.sh's bundle manifest in the shipped
  # CLI), so a harness that relied on the loader would grade a process in which
  # the clone lane's goal builder does not exist — and would report that as a
  # missing clause rather than as a missing file.
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

PASS=0; FAILN=0
ok_t()  { PASS=$((PASS+1));  printf 'ok   - %s\n' "$1"; }
bad_t() { FAILN=$((FAILN+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# The enrichments that reach outside this harness are stubbed empty; they have
# their own harnesses and would otherwise decide these arms' bytes.
_hb_recall_cite()      { printf ''; }
_hb_carryover_clause() { printf ''; }
_hb_reject_fix_clause(){ printf ''; }

echo "── PART 1 — the method clause says what a grade IS ───────────────"
M=$(_grader_grade_method_clause)
has "$M" "VERIFY THE CLAIMS" && ok_t "the clause names the method"       || bad_t "the clause names the method" "$M"
has "$M" "DO NOT RE-INVESTIGATE" && ok_t "the clause forbids re-derivation" || bad_t "the clause forbids re-derivation" "$M"
has "$M" "RE-RUN"            && ok_t "the clause says re-run what is named" || bad_t "the clause says re-run what is named" "$M"
has "$M" "DELIVERED-SHA"     && ok_t "the clause names the sha field"    || bad_t "the clause names the sha field" "$M"
has "$M" "unevidenced"       && ok_t "an unevidenced claim is named a FAIL" || bad_t "an unevidenced claim is named a FAIL" "$M"
has "$M" "Budget 25 turns"   && ok_t "the budget is STATED, with its number" || bad_t "the budget is STATED, with its number" "$M"
# The budget is a knob, and a knob nothing reads is a comment.
_GRADER_TURN_BUDGET=9 ; has "$(_grader_grade_method_clause)" "Budget 9 turns" \
  && ok_t "the budget is read from _GRADER_TURN_BUDGET" || bad_t "the budget is read from _GRADER_TURN_BUDGET" "$(_grader_grade_method_clause)"
_GRADER_TURN_BUDGET=25

echo "── PART 2 — both grader lanes carry it ───────────────────────────"
G=$(_grader_process_goal DIVE-1 sess-1 gr-quinn-1)
has "$G" "VERIFY THE CLAIMS" && ok_t "the CLONE lane's goal carries the method" || bad_t "the CLONE lane's goal carries the method" "$G"
has "$G" "Budget 25 turns"   && ok_t "the CLONE lane's goal carries the budget" || bad_t "the CLONE lane's goal carries the budget" "$G"
# The session lane sends its message through `5dive agent send`, i.e. outside
# this process. Asserted STRUCTURALLY — that it composes the same one string —
# which is the property that matters (two hand-maintained copies is how the two
# lanes stop being comparable), and it is stated as a source assertion rather
# than dressed up as a behavioural one.
grep -q '_grader_grade_method_clause' src/task/grader_pool.sh \
  && ok_t "the SESSION lane composes the same clause (source assertion)" \
  || bad_t "the SESSION lane composes the same clause (source assertion)" "no call in src/task/grader_pool.sh"

echo "── PART 3 — the heartbeat dispatch, per role ─────────────────────"
mk() { # <ident> <assignee> <verifier> <maker> -> task id
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,verifier,maker_agent,kind,created_at)
      VALUES ($(sqlq "$1"),'row','todo','high',$(sqlq "$2"),'main',$(sqlq_or_null "$3"),$(sqlq_or_null "$4"),'standard',datetime('now'));"
  db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"
}
TG=$(mk DIVE-G1 quinn quinn dev)        # delivered handoff: quinn grades
TM=$(mk DIVE-M1 dev quinn '')           # maker before any handoff
CG=$(_hb_loop_terminal_clause quinn "$TG" DIVE-G1)
has "$CG" "you are the VERIFIER" && ok_t "the grade wake selects the verifier variant" || bad_t "the grade wake selects the verifier variant" "$CG"
has "$CG" "VERIFY THE CLAIMS"    && ok_t "the verifier variant carries the method"     || bad_t "the verifier variant carries the method" "$CG"
has "$CG" "Budget 25 turns"      && ok_t "the verifier variant carries the budget"     || bad_t "the verifier variant carries the budget" "$CG"
has "$CG" "FINDING: unevidenced" && ok_t "it hands over the reject line to use"        || bad_t "it hands over the reject line to use" "$CG"
NG=$(_hb_nudge_text quinn "$TG" DIVE-G1)
has "$NG" "Stop after 25 turns" && ok_t "the dispatch's own turn cap IS the grade budget" \
  || bad_t "the dispatch's own turn cap IS the grade budget" "$NG"
! has "$NG" "Stop after 6 turns" && ok_t "the dispatch does not also state the default cap" \
  || bad_t "the dispatch does not also state the default cap" "two caps in one dispatch"
NM=$(_hb_nudge_text dev "$TM" DIVE-M1)
has "$NM" "Stop after 6 turns" && ok_t "a non-grade wake keeps the historical cap" || bad_t "a non-grade wake keeps the historical cap" "$NM"
! has "$NM" "VERIFY THE CLAIMS" && ok_t "a maker is not handed the grader's method" || bad_t "a maker is not handed the grader's method" "$NM"

echo "── PART 4 — the restated predicate agrees with the variant ───────"
# Every shape through BOTH. `want` is what the CLAUSE does (the authority);
# `_hb_is_grade_wake` must match it exactly.
agree() { # <label> <ident> <assignee> <verifier> <maker> <woken>
  local label="$1" id; id=$(mk "$2" "$3" "$4" "$5")
  local clause; clause=$(_hb_loop_terminal_clause "$6" "$id" "$2")
  local want=1; has "$clause" "you are the VERIFIER" && want=0
  _hb_is_grade_wake "$6" "$id"; local got=$?
  (( want == got )) && ok_t "agree: $label" \
    || bad_t "agree: $label" "clause says $( ((want==0)) && echo grade || echo not-grade ), predicate says $( ((got==0)) && echo grade || echo not-grade )"
}
agree "delivered handoff, verifier woken"  DIVE-A1 quinn quinn dev   quinn
agree "maker woken before handoff"         DIVE-A2 dev   quinn ''    dev
agree "maker woken after handoff"          DIVE-A3 quinn quinn dev   dev
agree "verifier-of-record, nothing made"   DIVE-A4 quinn quinn ''    quinn
agree "self-graded row (maker == verifier)" DIVE-A5 quinn quinn quinn quinn
agree "bystander woken"                    DIVE-A6 quinn quinn dev   olivia
agree "no verifier at all"                 DIVE-A7 dev   ''    ''    dev

echo "── PART 5 — mutation: the budget is actually read ────────────────"
ORIG=$(declare -f _hb_nudge_text)
# `declare -f` reprints the body, not the source bytes (it spaces `2> /dev/null`
# and adds a trailing `;`), so the pattern matches the reprinted shape.
MUT=$(printf '%s\n' "$ORIG" | sed '0,/_hb_is_grade_wake .*_hb_grade_turn_budget)/s//:/')
if [[ "$MUT" == "$ORIG" ]]; then
  bad_t "mutation landed" "sed matched nothing — the arm below would be vacuous"
else
  eval "$MUT"
  has "$(_hb_nudge_text quinn "$TG" DIVE-G1)" "Stop after 6 turns" \
    && ok_t "cutting the role test reverts the cap to 6 (the test is what raises it)" \
    || bad_t "cutting the role test reverts the cap to 6" "the cap is not attributable to the role test"
  eval "$ORIG"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAILN"
(( FAILN == 0 ))
