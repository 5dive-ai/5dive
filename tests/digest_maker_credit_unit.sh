#!/usr/bin/env bash
# DIVE-2556 — completions must be credited to the MAKER, not to whoever happens
# to own the row at close.
#
# The defect, measured 2026-08-03: on a maker/verifier loop the row's `assignee`
# moves to the verifier at delivery, and the verifier is still the owner when it
# closes. Every per-assignee throughput read therefore credits the grader and
# zeroes the builder — dev built 10 of the 28 rows closed in 24h and its
# credited done count was 0, which reads as an idle agent holding 119 open todos.
#
# This harness grades the WHOLE seam, not a fixture: it drives the real
# `task add/start/done/verify` verbs against a throwaway DB, runs the real
# `task ls --all --json` (the exact producer `5dive digest` shells out to), and
# feeds that JSON into the digest's own embedded python. A fix that lands in the
# digest but never reaches it — because the ls projection does not emit
# maker_agent — fails here rather than passing on hand-built input.
#
# Arms:
#   A  precondition — the loop actually formed (maker_agent=dev, assignee=olivia)
#   B  the OLD instrument, on this same data, credits dev 0 and olivia 2
#      (non-vacuity: the arms below are graded against a control that fails)
#   C  byMaker credits the builder: dev 2
#   D  byVerifier is a SEPARATE series: olivia 2 — never merged into byMaker
#   E  a loopless row (maker_agent NULL) does NOT vanish: it lands on its assignee
#   F  the rendered Shipped line names the maker, with the verifier beside it
#
# Same isolation contract as tests/task_verifier_rail_unit.sh: source src/
# directly, STATE_DIR at a temp dir, live tasks.db never touched.
# Run: bash tests/digest_maker_credit_unit.sh   (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — the helper's stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/digest-maker-credit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
eq_t()  { # eq_t <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1 (expected '$2', got '$3')"; fi
}

# --- build the board: two graded rows built by dev, one loopless row by dev2 ---
mk_graded() { # mk_graded <title>
  local id
  ( actor_seam_as main; cmd_task_add "$1" --assignee=dev --verifier=olivia ) >/dev/null 2>&1
  id=$(db "SELECT MAX(id) FROM tasks;")
  ( actor_seam_as dev;    cmd_task_start "$id" )                >/dev/null 2>&1
  ( actor_seam_as dev;    cmd_task_done  "$id" --result="built" )>/dev/null 2>&1
  # the verifier's ACK *is* the close (a second `task done`, run as olivia)
  ( actor_seam_as olivia; cmd_task_done "$id" --result="graded ok" ) >/dev/null 2>&1
  printf '%s' "$id"
}
G1=$(mk_graded "graded row one")
G2=$(mk_graded "graded row two")
( actor_seam_as main; cmd_task_add "loopless row" --assignee=dev2 --no-verify ) >/dev/null 2>&1
L1=$(db "SELECT MAX(id) FROM tasks;")
( actor_seam_as dev2; cmd_task_start "$L1" )                 >/dev/null 2>&1
( actor_seam_as dev2; cmd_task_done  "$L1" --result="built" )>/dev/null 2>&1

# Arm A — precondition. If the loop never formed, every arm below is vacuous:
# the row would carry assignee=dev and "credit the maker" would be trivially
# true for the wrong reason.
eq_t "A1 graded row closed" "done" "$(db "SELECT status FROM tasks WHERE id=${G1};")"
eq_t "A2 maker_agent stamped to the builder" "dev" \
     "$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${G1};")"
eq_t "A3 assignee MOVED to the verifier at close" "olivia" \
     "$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${G1};")"
eq_t "A4 loopless row has NO maker_agent" "" \
     "$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${L1};")"
eq_t "A5 loopless row closed under its builder" "done|dev2" \
     "$(db "SELECT status||'|'||COALESCE(assignee,'') FROM tasks WHERE id=${L1};")"

# --- run the REAL producer, then the REAL digest python over its output -------
# `--json` is a GLOBAL flag consumed by main(); the verb itself refuses it, so
# the producer is driven the way main() drives it: JSON_MODE=1 + the bare verb.
# Subshell because cmd_task_ls exits the shell on its own success path.
( JSON_MODE=1 cmd_task_ls --all ) >"$TMP/ls.json" 2>/dev/null
python3 -c "import json,sys; d=json.load(open('$TMP/ls.json'))['data']; json.dump(d,open('$TMP/tasks.json','w'))" \
  || { echo "FAIL - task ls --json did not parse"; exit 1; }

awk "/python3 - >.*<<'PY'/{f=1;next} f&&/^PY\$/{f=0} f" src/cmd_digest.sh > "$TMP/digest.py"
[[ -s "$TMP/digest.py" ]] || { echo "FAIL - could not extract digest python"; exit 1; }
echo '{"agents":[],"tasks":[]}' > "$TMP/usage.json"; : > "$TMP/hb.txt"
echo '{"loops":[]}' > "$TMP/loops.json"

run_digest() { # run_digest [json|text]
  DIGEST_TASKS_F="$TMP/tasks.json" DIGEST_USAGE_F="$TMP/usage.json" \
  DIGEST_HB_F="$TMP/hb.txt" DIGEST_LOOPS_F="$TMP/loops.json" \
  DIGEST_WINDOW=604800 DIGEST_JSON="${2:-1}" python3 "$TMP/digest.py" 2>/dev/null
}
run_digest json 1 >"$TMP/out.json"
pick() { python3 -c "import json,sys; print($1)" <"$TMP/out.json"; }

eq_t "shipped 3 rows in window" "3" "$(pick "len(json.load(sys.stdin)['done'])")"

# Arm B — the control. Counting the SAME closed rows by the owner column is the
# instrument that produced the zero. It must fail here; if it ever agrees with
# byMaker, this harness has stopped discriminating and arms C/D prove nothing.
OLD_DEV=$(pick "sum(1 for t in json.load(sys.stdin)['done'] if t['assignee']=='dev')")
OLD_OLI=$(pick "sum(1 for t in json.load(sys.stdin)['done'] if t['assignee']=='olivia')")
eq_t "B1 CONTROL: by-assignee credits the builder 0" "0" "$OLD_DEV"
eq_t "B2 CONTROL: by-assignee credits the grader 2"  "2" "$OLD_OLI"

# Arm C — the fix. Same rows, credited to whoever built them.
eq_t "C1 byMaker credits the builder 2" "2" \
     "$(pick "json.load(sys.stdin)['throughput']['byMaker'].get('dev',0)")"
eq_t "C2 byMaker does NOT credit the grader" "0" \
     "$(pick "json.load(sys.stdin)['throughput']['byMaker'].get('olivia',0)")"

# Arm D — two series, not one. Review load is real work and is reported, but it
# is reported SEPARATELY; merging the two is how the builder's count got eaten.
eq_t "D1 byVerifier credits the grader 2" "2" \
     "$(pick "json.load(sys.stdin)['throughput']['byVerifier'].get('olivia',0)")"
eq_t "D2 byVerifier does not carry the loopless row" "0" \
     "$(pick "json.load(sys.stdin)['throughput']['byVerifier'].get('dev2',0)")"

# Arm E — the trap in the prescribed fix. A bare swap to maker_agent drops every
# row that never ran a loop (maker_agent NULL), which is most of the board.
eq_t "E1 loopless row still counted, under its own builder" "1" \
     "$(pick "json.load(sys.stdin)['throughput']['byMaker'].get('dev2',0)")"
eq_t "E2 byMaker total == rows closed" "3" \
     "$(pick "sum(json.load(sys.stdin)['throughput']['byMaker'].values())")"

# Arm F — the human-facing line. The digest text is what lodar actually reads.
run_digest text 0 >"$TMP/out.txt"
if grep -qE '^  • .* — dev \(verified by olivia\)$' "$TMP/out.txt"; then
  ok_t "F1 Shipped line names the maker, verifier beside it"
else
  bad_t "F1 Shipped line names the maker, verifier beside it (got: $(grep -m1 '  • ' "$TMP/out.txt"))"
fi
if grep -q 'built by: dev 2' "$TMP/out.txt"; then
  ok_t "F2 per-maker rollup rendered"
else
  bad_t "F2 per-maker rollup rendered (got: $(grep -m1 'built by' "$TMP/out.txt"))"
fi
if grep -q 'verified by: olivia 2' "$TMP/out.txt"; then
  ok_t "F3 per-verifier rollup rendered as its own line"
else
  bad_t "F3 per-verifier rollup rendered as its own line"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
