#!/usr/bin/env bash
# DIVE-3785 — gate state on the surfaces people actually READ.
#
# The row this covers was filed off a wrong answer given to the founder: `task
# show` prints its gate block at the TAIL, so a grep window one line too short
# read ten pending human gates as zero. The inverse costs more and is not a grep
# bug at all — `park` archives the gate and CLEARS the live need_* columns, so an
# ANSWERED-then-parked gate makes `task show` render no gate block whatsoever and
# the signed human tap becomes invisible on every surface except `gate-history`.
#
# So the arms below are deliberately paired in BOTH directions. An arm set that
# only proves "a pending gate is visible" would pass on a build that still hides
# every answered one, which is the state this test was written against.
set -euo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${FIVEDIVE_TEST:=1}"; export FIVEDIVE_TEST
CLI="${CLI:-./5dive}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# TASKS_DIR, not just TASKS_DB. `tasks_db_init` guards on the DIRECTORY and, as a
# non-root caller, REFUSES to create it ("tasks store not initialised"). Setting
# only TASKS_DB leaves TASKS_DIR defaulted to /var/lib/5dive/tasks — which exists
# on a 5dive host and does not exist in CI, so the harness is green locally and red
# on the runner off the same tree. Same shape the sibling task harnesses avoid by
# exporting all three and creating the dir themselves.
export STATE_DIR="$TMP"
export TASKS_DIR="$TMP/tasks"
export TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
fails=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fails=$((fails+1)); }
has()  { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }

$CLI task add "gate visibility fixture A" --assignee=dev >/dev/null
$CLI task add "gate visibility fixture B" --assignee=dev >/dev/null
$CLI task add "gate visibility fixture C never gated" --assignee=dev >/dev/null
A=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks WHERE title LIKE 'gate visibility fixture A%';")
B=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks WHERE title LIKE 'gate visibility fixture B%';")
C=$(sqlite3 "$TASKS_DB" "SELECT ident FROM tasks WHERE title LIKE '%never gated%';")

# ---- arm 1: a PENDING human gate is visible in the show HEADER, not only the tail.
# The header is the first ~6 lines; the whole point is that it is above the body.
$CLI task need "$A" --type=manual --ask="fixture ask, needs a person" --tier=2 >/dev/null 2>&1 || true
hdr=$($CLI task show "$A" 2>/dev/null | sed -n '1,8p')
has 'PENDING' "$hdr" && has 'HUMAN' "$hdr" \
  && ok "pending human gate names itself in the show header" \
  || bad "pending human gate absent from the show header (got: $(printf '%s' "$hdr" | tr '\n' '|'))"

# ---- arm 2: the ls column separates a gated row from a merely-blocked one.
lsout=$($CLI task ls 2>/dev/null)
has "HUMAN:manual" "$lsout" && ok "ls marks the human-gated row" || bad "ls does not mark the human-gated row"
# and the never-gated row is marked as such rather than blank — `-` is a value.
has "$C" "$lsout" && ok "never-gated row still listed" || bad "never-gated row vanished from ls"

# ---- arm 3: --gated partitions, and --gated=human is EXACTLY the inbox set.
hn=$($CLI task ls --gated=human --json 2>/dev/null | jq -r '.data.tasks|length')
ib=$($CLI task inbox --json 2>/dev/null | jq -r '.data.inbox|length')
[[ "$hn" == "$ib" && "$hn" != "0" ]] \
  && ok "--gated=human agrees with inbox (n=$hn, non-vacuous)" \
  || bad "--gated=human ($hn) != inbox ($ib), or both empty (vacuous)"
an=$($CLI task ls --gated=agent --json 2>/dev/null | jq -r '.data.tasks|length')
re=$($CLI task inbox --json 2>/dev/null | jq -r '.data.routed_elsewhere')
[[ "$an" == "$re" ]] && ok "--gated=agent agrees with inbox's withheld count" \
  || bad "--gated=agent ($an) != inbox routed_elsewhere ($re)"
ay=$($CLI task ls --gated --json 2>/dev/null | jq -r '.data.tasks|length')
[[ "$ay" == "$((hn+an))" ]] && ok "--gated=any is the sum of the two partitions" \
  || bad "--gated any=$ay != human($hn)+agent($an)"
$CLI task ls --gated=bogus >/dev/null 2>&1 && bad "--gated=bogus was accepted" || ok "--gated rejects an unknown value"

# ---- arm 4: THE ANSWERED-THEN-PARKED CASE. This is the arm the pre-fix build
# fails, and it is the one that cost 7 days on DIVE-3594. Simulate exactly what
# park does: archive the ANSWERED gate, clear the live columns.
$CLI task need "$B" --type=approval --ask="fixture ask, will be answered then parked" --tier=2 >/dev/null 2>&1 || true
bid=$(sqlite3 "$TASKS_DB" "SELECT id FROM tasks WHERE ident='$B';")
sqlite3 "$TASKS_DB" "
  INSERT INTO gate_history (task_id, ident, need_type, ask, need_answer, need_answered_at,
                            need_answered_by, retired_by, retired_at)
  VALUES ($bid, '$B', 'approval', 'fixture ask, will be answered then parked', 'approved',
          '2026-08-28 05:02:10', 'human:h00000', 'park', '2026-08-28 05:07:01');
  UPDATE tasks SET need_type=NULL, ask=NULL, need_answer=NULL, need_answered_at=NULL,
                   need_answered_by=NULL, tier=NULL WHERE id=$bid;"
hdr=$($CLI task show "$B" 2>/dev/null | sed -n '1,8p')
has 'ANSWERED' "$hdr" && has 'approved' "$hdr" && has 'human:h00000' "$hdr" \
  && ok "answered-then-parked gate reports its ANSWER in the header" \
  || bad "answered-then-parked gate reads as ungated (got: $(printf '%s' "$hdr" | tr '\n' '|'))"
has 'RETIRED' "$hdr" \
  && ok "header says the card was retired, so 'no live gate' is not a contradiction" \
  || bad "header claims an answer without naming the retirement"
# ...and it must NOT show up as something a human still owes.
$CLI task ls --gated=human --json 2>/dev/null | jq -e --arg b "$B" '.data.tasks|map(.ident)|index($b)|not' >/dev/null \
  && ok "answered-then-parked row is not counted as pending on a human" \
  || bad "answered-then-parked row leaked into --gated=human"

# ---- arm 5: never-gated row says 'none', not blank.
g=$($CLI task show "$C" 2>/dev/null | sed -n '1,8p' | grep -E '^ *gate = ' || true)
has 'none' "$g" && ok "never-gated row renders gate = none" || bad "never-gated row gate line wrong: '$g'"

# ---- arm 6: gate-history --json key set does not vary with the data.
# The defect: dbfmt strips null keys, so an unanswered gate omitted need_answer
# entirely and a parser asking the WRONG key got the same None as a real absence.
ks=$($CLI task gate-history "$B" --json 2>/dev/null | jq -r '[.data.gates[]|keys|length]|unique|length')
[[ "$ks" == "1" ]] && ok "gate-history --json rows all carry the same key set" \
  || bad "gate-history --json key set varies with the data ($ks distinct shapes)"
$CLI task gate-history "$B" --json 2>/dev/null | jq -e '.data.gates[0]|has("need_answer") and has("need_answered_at") and has("answered")' >/dev/null \
  && ok "answer fields are present-and-null, plus an explicit 'answered' boolean" \
  || bad "gate-history --json still omits the answer fields"

# ---- arm 7: `task inbox --fleet` is accepted (OSS-36's flag; inbox is already fleet-wide).
$CLI task inbox --fleet >/dev/null 2>&1 && ok "inbox accepts --fleet as a no-op" || bad "inbox --fleet still errors"

# ---- arm 8: source-level — the renderers CALL the predicates, never paste them.
# Same contract tests/task_needs_human_parity_unit.sh enforces; restated here
# because this row added two new consumers of it.
# Anchored on the DEFINITION line, matching tests/task_needs_human_parity_unit.sh:
# a bare substring grep also matches the unrelated routed-gate-queue query below
# it, which is a second USE of routed_reviewer, not a second copy of the rule.
n=$(cat src/cmd_task.sh src/task/*.sh | grep -c "^  printf '%s' \"( COALESCE(routed_reviewer,'') = ''")
[[ "$n" == "1" ]] && ok "the human-gate disjunction still appears exactly once" \
  || bad "the human-gate disjunction appears $n times — a second copy was pasted"

printf '\n%s\n' "$( ((fails==0)) && echo 'PASS' || echo "FAIL ($fails)" )"
exit $(( fails > 0 ))
