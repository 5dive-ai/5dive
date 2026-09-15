#!/usr/bin/env bash
# DIVE-4571 — the LAST hardcoded recipient in the product, and a repo-wide guard
# so the next one cannot be added quietly.
#
# THE ROW. luca's teal-fox report (box-1, 0.40.0) named fifteen call sites that
# addressed a literal seat name. Fourteen are fixed by the two rows this one
# stacks on: DIVE-4551 (the three supervisor alert rails) and DIVE-4554 (the
# eleven heartbeat escalations — eight `ops`, three `main`, including the
# DIVE-1434 pinger-liveness canary). Running the remediation grep the DIVE-4551
# wiki page prescribes — repo-wide this time, not on the file that was handed to
# us — turned up one more, in a different shape and a third file:
#
#   src/task/delivery.sh  _merge_hold_seat  ->  printf '%s' "$_MERGE_HOLD_SEAT_FALLBACK"
#   src/task/loops.sh     ...               ->  || printf 'main' ; ${_md_owner:-main}
#
# `_merge_hold_seat` ASKED THE ROSTER whether `ops` was live and then, on a no,
# printed `main` without ever asking the same question about it. Both names exist
# on exactly one box: ours. On teal-fox's chart (claude-aleks / claude-alena /
# claude-jane) every graded-and-waiting row was therefore stamped
# `merge_owner=main` — a seat the roster has never heard of. That is not an alert
# that reaches nobody, it is the other half of the same report: a row that reads
# ASSIGNED and is dispatchable to no one, which `task doctor` calls clean.
#
# WHAT IS ASSERTED:
#   A. `_merge_hold_seat` driven for real against four rosters + charts — this
#      box, ops-disabled, the lone-root customer chart, and teal-fox where
#      nothing resolves. Not a stubbed resolver: a stub would grade itself.
#   B. The disposition and the WRITE: an unresolvable `merger` degrades to the
#      maker ROLE, carries `-no-merge-seat` in its reason, and the column is
#      left empty rather than backfilled — `_tasks_merge_owner_sql` COALESCEs
#      empty to maker_agent, so the board renders a seat that exists.
#   C. The REPO-WIDE enumeration. DIVE-4554's arm E ran this grep over
#      src/cmd_heartbeat.sh alone, which is exactly how the class survived the
#      first fix: DIVE-4551 cleaned three sites in one file and eleven lived on
#      in the file next to it. This arm reads every shell file under src/.
#   D. MUTATION. Restore either literal and an arm above must go red.
#
# NOT MEASURED, declared: no live grade, no gh, no heartbeat tick. This grades
# who a hold names and what is written for it.
#
# Run: bash tests/merge_hold_recipient_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/merge-hold-recipient-unit.XXXXXX)"
STATE_DIR="$TMP"

# The roster path is read into a `readonly` at source time, so it is fixed here
# and its CONTENT is what each arm rewrites.
export FIVE_MERGE_HOLD_ROSTER="$TMP/agents.json"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         task/routing.sh task/delivery.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"
  fi
}

roster() { printf '%s\n' "$1" > "$FIVE_MERGE_HOLD_ROSTER"; }
roster_this_box() { roster '{"agents":{"main":{},"ops":{},"dev":{},"quinn":{}}}'; }
roster_ops_down()  { roster '{"agents":{"main":{},"ops":{"heartbeat":{"enabled":false}},"dev":{}}}'; }
roster_customer()  { roster '{"agents":{"claude-aleks":{},"claude-ivan":{}}}'; }

chart() { db "DELETE FROM agents_org;"; }
this_box() {
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','AI CEO — conducts the fleet (advisory)',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','engineering + infra + the 5dive CLI — gate notifier','olivia');"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE','main');"
}
lone_root() {  # the customer chart DIVE-4551 was filed from: no main, no ops
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-ivan','engineer','claude-aleks');"
}
three_roots() {  # teal-fox as reported: nothing resolves, and that is the state
  chart
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-alena','ops',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-jane','eng',NULL);"
}

# ── A. who owes a held merge, resolved for real ──────────────────────────────
this_box; roster_this_box
t "A1 this box: a held merge is still ops — byte-identical to the shipped behaviour" \
  "ops" "$(_merge_hold_seat '5dive-ai/5dive')"
t "A2 this box: a repo outside ops's credential still falls back to main" \
  "main" "$(_merge_hold_seat 'vercel/next.js')"

roster_ops_down
t "A3 ops disabled in the roster: still main here, and CHECKED this time" \
  "main" "$(_merge_hold_seat '5dive-ai/5dive')"

lone_root; roster_customer
t "A4 customer chart, no ops and no main: the fallback resolves through the notifier, not a constant" \
  "claude-aleks" "$(_merge_hold_seat '5dive-ai/5dive')"
db "UPDATE agents_org SET role='engineer — gate notifier' WHERE name='claude-ivan';"
t "A5 ...and an explicit gate-notifier tag moves it, without a new config key" \
  "claude-ivan" "$(_merge_hold_seat '5dive-ai/5dive')"

three_roots; roster_customer
t "A6 teal-fox chart: nothing resolves — the resolver says so instead of naming main" \
  "" "$(_merge_hold_seat '5dive-ai/5dive')"
t "A7 ...and says so by EXIT STATUS too, so a caller cannot mistake it for a seat" \
  "1" "$( _merge_hold_seat '5dive-ai/5dive' >/dev/null 2>&1; echo $? )"
t "A8 teal-fox chart: a seat merely ROLED 'ops' is not a seat NAMED ops" \
  "" "$(_merge_hold_seat '')"

# ── B. the disposition, and what gets written ────────────────────────────────
this_box; roster_this_box
t "B1 this box: the merger role resolves into the disposition unchanged" \
  "hold:ops:merge-state-BLOCKED" "$(_merge_hold_resolve 'hold:merger:merge-state-BLOCKED' '5dive-ai/5dive')"
t "B2 a maker hold is untouched — only the merger role is resolved here" \
  "hold:maker:branch-conflicted" "$(_merge_hold_resolve 'hold:maker:branch-conflicted' '5dive-ai/5dive')"
t "B3 a plain merge is untouched" \
  "merge" "$(_merge_hold_resolve 'merge' '5dive-ai/5dive')"

three_roots; roster_customer
t "B4 teal-fox chart: an unresolvable merger becomes the MAKER role, never an empty seat" \
  "hold:maker:merge-state-BLOCKED-no-merge-seat" \
  "$(_merge_hold_resolve 'hold:merger:merge-state-BLOCKED' '5dive-ai/5dive')"

# The write itself, through the column readers that render it. An empty
# merge_owner must degrade to the maker, not to '?' and not to a constant.
db "INSERT INTO tasks (ident,title,status,assignee,maker_agent,created_by)
    VALUES ('DIVE-T1','fixture','todo','claude-ivan','claude-ivan','claude-aleks');"
_t1=$(db "SELECT id FROM tasks WHERE ident='DIVE-T1';")
db "UPDATE tasks SET merge_owner='', merge_hold_reason='merge-state-BLOCKED-no-merge-seat' WHERE id=${_t1};"
t "B5 an empty merge_owner renders as the maker — a seat that exists on this box" \
  "claude-ivan" "$(db "SELECT $(_tasks_merge_owner_sql) FROM tasks WHERE id=${_t1};")"
t 'B6 ...and task show prints - for the owner rather than a phantom name' \
  "-" "$(db "SELECT CASE WHEN COALESCE(merge_owner,'')='' THEN '-' ELSE merge_owner END FROM tasks WHERE id=${_t1};")"
t "B7 ...while the REASON still records why nobody owns it" \
  "merge-state-BLOCKED-no-merge-seat" "$(db "SELECT merge_hold_reason FROM tasks WHERE id=${_t1};")"

# ── C. the repo-wide enumeration ─────────────────────────────────────────────
# The remediation grep as a DELIVERABLE, over every shell file under src/ — the
# scope is the point. Comment lines are excluded (they document the defect); a
# heredoc'd example would be caught, which is the safe direction.
# `grep -c` PRINTS 0 and EXITS 1 on no matches, so a `|| echo 0` tail emits TWO
# zeros and every arm below would compare against '0\n0'. Count with awk.
literal_sends() {
  grep -rnE '^[^#]*(cmd_send|_task_send_agent)[[:space:]]+"[a-z][a-z0-9_-]*"' "${1:-src}" --include='*.sh' \
    | awk 'END {print NR}'
}
# `send to ${reviewer}` is English inside a failure message, not a recipient —
# the one exemption, named rather than regexed around, because a filter nobody
# can read is how the next literal gets in.
literal_a2a() {
  grep -rnE '^[^#]*5dive agent send [a-z][a-z0-9_-]*[[:space:]]' "${1:-src}" --include='*.sh' \
    | grep -v '5dive agent send to ' \
    | awk 'END {print NR}'
}
t "C1 no shell file under src/ addresses a send to a literal seat name" "0" "$(literal_sends src)"
t "C2 ...nor through the a2a verb" "0" "$(literal_a2a src)"
t "C3 the only surviving seat literals are the resolver defaults, and there are three" \
  "3" "$(grep -rcE "^(readonly )?_MERGE_HOLD_SEAT(_FALLBACK)?=|lower\(name\)='ops'" src --include='*.sh' | awk -F: '{s+=$2} END {print s+0}')"

# ── D. mutation ──────────────────────────────────────────────────────────────
# Non-vacuity, both halves: the behavioural arm and the enumeration arm.
# Restore the unchecked fallback exactly as it shipped before this row, then
# re-source ONLY that function into a subshell and re-drive the teal-fox arm.
mutant_answer() {
  ( _merge_hold_seat() {
      local repo="${1:-}"
      if [[ -n "$repo" ]] && ! grep -qE "$_MERGE_HOLD_SEAT_OWNERS_RX" <<<"$repo"; then
        printf '%s' "$_MERGE_HOLD_SEAT_FALLBACK"; return 0
      fi
      _merge_hold_seat_live "$_MERGE_HOLD_SEAT" || { printf '%s' "$_MERGE_HOLD_SEAT_FALLBACK"; return 0; }
      printf '%s' "$_MERGE_HOLD_SEAT"
    }
    _merge_hold_seat "$1" )
}
three_roots; roster_customer
t "D1 MUTANT (the shipped pre-DIVE-4571 resolver): teal-fox is stamped 'main' — a seat not in its roster" \
  "main" "$(mutant_answer '5dive-ai/5dive')"
t "D2 ...which is what A6 now refuses, so A6 is not vacuous" \
  "" "$(_merge_hold_seat '5dive-ai/5dive')"

# The enumeration arm, mutated: a literal-addressed send in a module the old
# file-scoped grep never read.
MUTDIR="$TMP/src-mutant"; cp -r src "$MUTDIR"
printf '%s\n' 'cmd_send "ops" --from="task-engine" --message="regression"' >> "$MUTDIR/cmd_liveness.sh"
t "D3 MUTANT: one literal send added to an unrelated module — the repo-wide arm goes red (1, not 0)" \
  "1" "$(literal_sends "$MUTDIR")"
t "D4 ...and the arm DIVE-4554 shipped, which reads cmd_heartbeat.sh alone, stays green on it" \
  "0" "$(grep -c '^[^#]*cmd_send "[a-z][a-z0-9_-]*"' "$MUTDIR/cmd_heartbeat.sh")"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
