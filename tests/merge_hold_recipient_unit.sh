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
#      in the file next to it. This arm reads every shell file under src/, and
#      it matches the three SHAPES a seat name is written in — double-quoted,
#      single-quoted, and bare — because a guard that only sees the shape the
#      defect happened to use is the file-scoped grep again, one level down
#      (iteration 1, quinn: `cmd_send ops` and a trailing `5dive agent send
#      main` at end of line both scored 0).
#   D. MUTATION of A and C.
#   E. THE WRITE ITSELF, driven through the shipped `cmd_task_verify` — the
#      half of this diff that lives in src/task/loops.sh, and the half that
#      produced the customer symptom. Sections A-D grade delivery.sh; B5-B7
#      seed the column BY HAND and assert the render, so they cannot see
#      whether the verify path stopped writing `main` (iteration 1, quinn).
#      Here a graded row is driven end to end on a box whose roster and chart
#      contain neither `ops` nor `main`, and the arm reads the column the
#      product wrote. Its mutant reverts src/task/loops.sh alone.
#
# NOT MEASURED, declared: no live grade, no gh, no heartbeat tick. The one gh
# read is failed rather than stubbed to a string, which is a SHIPPED
# disposition (`hold:merger:disposition-probe-failed`, loops.sh) and the one
# that reaches the merger branch without inventing an input.
#
# NON-VACUITY, PER FILE — the union receipt in this row's iteration 1 said
# "revert both files -> 7 reds" and those seven all came from delivery.sh,
# which is exactly the misattribution it hid:
#   src/task/delivery.sh reverted alone -> A4-A8, B4, D2, E1-E3 red     (10)
#   src/task/loops.sh    reverted alone -> E1, E2, E3, E6, E7a red       (5)
# The second line is the one that did not exist at iteration 1: reverting
# loops.sh alone left SEVENTEEN harnesses green, this one included.
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

# The whole of `task`, not the two modules sections A-D need: section E drives
# the shipped `cmd_task_verify`, which lives in src/task/loops.sh and is only
# reachable through this file (it resolves its own module dir from BASH_SOURCE,
# so a MUTANT COPY of src/ sources its own loops.sh — which is what makes E7
# possible).
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
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
#
# THE SHAPE, not one shape (iteration 1, quinn). A seat name is written three
# ways in shell — "ops", 'ops' and bare ops — and a guard that only sees the
# double-quoted one repeats the mistake this row exists to close: it grades the
# form the defect happened to take instead of the class. Both shipped literals
# were double-quoted, so the narrow guard was green for the wrong reason.
# Verified against a mutant tree below, one mutant per shape.
_SEAT='[a-z][a-z0-9_-]*'
literal_sends() {
  grep -rnE "^[^#]*(cmd_send|_task_send_agent)[[:space:]]+(\"${_SEAT}\"|'${_SEAT}'|${_SEAT}([[:space:]]|\$))" \
    "${1:-src}" --include='*.sh' \
    | awk 'END {print NR}'
}
# `send to ${reviewer}` is English inside a failure message, not a recipient —
# the one exemption, named rather than regexed around, because a filter nobody
# can read is how the next literal gets in. END-OF-LINE counts: `5dive agent
# send main` with nothing after it is the commonest shape of all and the old
# trailing-[[:space:]] requirement scored it 0.
literal_a2a() {
  grep -rnE "^[^#]*5dive agent send ${_SEAT}([[:space:]]|\$)" "${1:-src}" --include='*.sh' \
    | grep -vE '5dive agent send to([[:space:]]|$)' \
    | awk 'END {print NR}'
}
# The iteration-1 guards, kept ONLY as the control the shape mutants are read
# against: each shape mutant asserts the widened guard sees it AND that this one
# does not, so "the guard got wider" is measured, not claimed.
literal_sends_narrow() {
  grep -rnE '^[^#]*(cmd_send|_task_send_agent)[[:space:]]+"[a-z][a-z0-9_-]*"' "${1:-src}" --include='*.sh' \
    | awk 'END {print NR}'
}
literal_a2a_narrow() {
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

# THE OTHER TWO SHAPES (iteration 1, quinn). One mutant per shape, each read
# twice: the widened guard must SEE it and the iteration-1 guard must MISS it.
# The second half is what makes the widening a measurement rather than a claim —
# a regex that got longer and caught nothing new is the file-scoped grep again.
shape_mutant() {  # <line to append> -> "<widened> <narrow>"
  local d="$TMP/shape-$RANDOM"; cp -r src "$d"
  printf '%s\n' "$1" >> "$d/cmd_liveness.sh"
  case "$2" in
    a2a) printf '%s %s' "$(literal_a2a "$d")" "$(literal_a2a_narrow "$d")" ;;
    *)   printf '%s %s' "$(literal_sends "$d")" "$(literal_sends_narrow "$d")" ;;
  esac
  rm -rf "$d"
}
t "D5 MUTANT (UNQUOTED seat): \`cmd_send ops --message=x\` — seen now, invisible to the iteration-1 guard" \
  "1 0" "$(shape_mutant 'cmd_send ops --message="regression"' send)"
t "D6 MUTANT (SINGLE-QUOTED seat): \`cmd_send 'ops'\` — same" \
  "1 0" "$(shape_mutant "cmd_send 'ops' --message=\"regression\"" send)"
t "D7 MUTANT (a2a at END OF LINE): \`5dive agent send main\` with nothing after it" \
  "1 0" "$(shape_mutant '  sudo 5dive agent send main' a2a)"
t "D8 ...and the named exemption still holds at end of line: \`agent send to\` is English" \
  "0 0" "$(shape_mutant '  die "could not 5dive agent send to"' a2a)"

# ── E. THE WRITE: cmd_task_verify, driven end to end ─────────────────────────
# Iteration 1 graded this diff's delivery.sh half behaviourally and its loops.sh
# half not at all: B5-B7 seed merge_owner BY HAND and assert the RENDER, so
# reverting loops.sh alone — restoring the very literal this row exists to
# delete — left 17 harnesses green (quinn, reproduced). These arms drive the
# shipped `cmd_task_verify` on a graded, PR-bound row and read the column the
# PRODUCT wrote.
#
# In a CHILD PROCESS, deliberately: the mutant must be a mutant of the SOURCE
# TREE, not a function redefined in this shell, and `cmd_task.sh` resolves its
# own module dir from BASH_SOURCE — so a copy of src/ with one line changed
# sources its own loops.sh and nothing else has to be faked.
#
# The one impure leaf (`_merge_disp_probe`, the single gh read) is made to FAIL
# rather than stubbed to a string: loops.sh turns that into
# `hold:merger:disposition-probe-failed`, which is a shipped disposition and the
# one that reaches the merger branch without inventing an input.
cat > "$TMP/drive_write.sh" <<'DRIVER'
#!/usr/bin/env bash
# <src dir> <roster file> <this-box|teal-fox>  ->  "<merge_owner>|<reason>|<rendered owner>"
set -uo pipefail
SRCD="$1"; export FIVE_MERGE_HOLD_ROSTER="$2"; CHART="$3"
TMP="$(mktemp -d /tmp/mhr-write.XXXXXX)"; STATE_DIR="$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/broker.sh cmd_push.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRCD/$f"
done
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
if [[ "$CHART" == "this-box" ]]; then
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','AI CEO',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','engineering — gate notifier','olivia');"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('ops','DevOps / SRE','main');"
else
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-aleks','founder',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-alena','ops',NULL);"
  db "INSERT INTO agents_org (name, role, reports_to) VALUES ('claude-jane','eng',NULL);"
fi
# grader != maker is a standing predicate (DIVE-477); pin the actor so the arm
# does not depend on which seat runs the suite.
task_actor() { local f="${1:-}"; [[ -n "$f" ]] && printf '%s' "$f" || printf '%s' quinn; }
_merge_disp_probe() { return 1; }
id=$(db "INSERT INTO tasks (title, assignee, created_by, kind, status, maker_agent, verifier,
                            delivery_ref, iteration)
         VALUES ('a held merge on a box with no merge seat','quinn','claude-aleks','standard',
                 'in_progress','claude-ivan','quinn',
                 'https://github.com/5dive-ai/5dive/pull/809',1);
         SELECT last_insert_rowid();")
ident=$(db "SELECT ident FROM tasks WHERE id=$id;")
( set +e; cmd_task_verify "$ident" --no-done \
    --result="PASS — re-derived from a fresh clone. graded-sha: aabbccdd11223344556677889900aabbccddeeff" \
    >/dev/null 2>&1 )
printf '%s|%s|%s\n' \
  "$(db "SELECT COALESCE(merge_owner,'') FROM tasks WHERE id=$id;")" \
  "$(db "SELECT COALESCE(merge_hold_reason,'') FROM tasks WHERE id=$id;")" \
  "$(db "SELECT $(_tasks_merge_owner_sql) FROM tasks WHERE id=$id;")"
rm -rf "$TMP"
DRIVER

E_CUST="$TMP/e-roster-customer.json"; printf '%s\n' '{"agents":{"claude-aleks":{},"claude-ivan":{}}}' > "$E_CUST"
E_BOX="$TMP/e-roster-thisbox.json";  printf '%s\n' '{"agents":{"main":{},"ops":{},"dev":{},"quinn":{}}}' > "$E_BOX"
drive() { bash "$TMP/drive_write.sh" "$1" "$2" "$3"; }

E_TEAL=$(drive "$PWD/src" "$E_CUST" teal-fox)
t "E1 teal-fox, driven through \`task verify\`: the WRITTEN merge_owner is the maker, never 'main'" \
  "claude-ivan" "${E_TEAL%%|*}"
t "E2 ...and the reason records WHY it landed there" \
  "disposition-probe-failed-no-merge-seat" "$(cut -d'|' -f2 <<<"$E_TEAL")"
t "E3 ...so the board renders a seat that is on that box's roster" \
  "claude-ivan" "${E_TEAL##*|}"

# POSITIVE CONTROL. Without it E1-E3 would also pass on a tree where the write
# never happened at all.
E_BOXA=$(drive "$PWD/src" "$E_BOX" this-box)
t "E4 this box, same path: the column still says ops — byte-identical to the shipped behaviour" \
  "ops" "${E_BOXA%%|*}"
t "E5 ...with no -no-merge-seat suffix, because a merge seat WAS resolved" \
  "disposition-probe-failed" "$(cut -d'|' -f2 <<<"$E_BOXA")"

# THE MUTANT: src/task/loops.sh alone, reverted to what shipped before this row.
# Both literals come back (`|| printf 'main'` and `${_md_owner:-main}`); nothing
# in delivery.sh moves, so `_merge_hold_seat` still answers "" with rc 1 and the
# mutant has to CHOOSE to stamp the constant anyway. That is the customer defect.
cat > "$TMP/mutate_loops.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
blk = re.compile(r'          if \[\[ "\$_md_owner" == "merger" \]\]; then\n.*?\n          fi\n', re.S)
pre = ('          [[ "$_md_owner" == "merger" ]] \\\n'
       "            && _md_owner=$(_merge_hold_seat '' 2>/dev/null || printf 'main')\n")
s, n1 = blk.subn(pre, s, count=1)
s, n2 = re.subn(re.escape('sqlq "${_md_owner:-}"'), 'sqlq "${_md_owner:-main}"', s, count=1)
open(p, 'w').write(s)
print(f"{n1}{n2}")
PY
LOOPMUT="$TMP/src-loops-pre4571"; cp -r src "$LOOPMUT"
t "E6 the mutant applies, both halves, exactly once each" \
  "11" "$(python3 "$TMP/mutate_loops.py" "$LOOPMUT/task/loops.sh")"
# ANCHOR the cut, on the CODE and not on the prose: the comment above the block
# quotes `${_md_owner:-main}` to explain the defect, so a bare grep for that
# string reds on its own explanation in BOTH trees. Match the call it sits in.
t "E7a anchor: the shipped tree writes no constant" \
  "0" "$(grep -c 'sqlq "${_md_owner:-main}"' src/task/loops.sh)"
t "E7b anchor: the mutant tree does, once" \
  "1" "$(grep -c 'sqlq "${_md_owner:-main}"' "$LOOPMUT/task/loops.sh")"
E_MUT=$(drive "$LOOPMUT" "$E_CUST" teal-fox)
t "E8 MUTANT: teal-fox is stamped 'main' — a seat absent from its roster AND its chart. E1 is not vacuous" \
  "main" "${E_MUT%%|*}"
t "E9 ...and the reason loses the suffix, so the board cannot even say why" \
  "disposition-probe-failed" "$(cut -d'|' -f2 <<<"$E_MUT")"
E_MUTBOX=$(drive "$LOOPMUT" "$E_BOX" this-box)
t "E10 ...while this box reads identically under the mutant, which is why nothing here ever caught it" \
  "ops" "${E_MUTBOX%%|*}"

echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
