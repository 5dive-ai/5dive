#!/usr/bin/env bash
# DIVE-3499: "handing work back is a ROW, not a message" is enforced — `agent send`
# is REFUSED when the recipient already owns an open row bound to the ident or PR
# the message names.
#
# Graded against a REAL sqlite board in a throwaway STATE_DIR (not a stubbed `db`):
# the whole claim is "the guard reads the task table correctly", so a fake table
# would grade the harness. The wiring is asserted separately by grepping both send
# paths — a guard nothing calls passes every test it has.
#
# Run: bash tests/a2a_handback_guard_unit.sh
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d /tmp/a2a-handback-unit.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

echo "== part 1: the guard with NO board reachable (fails OPEN) =="
(
  # A subshell with only the library sourced — `db`/`sqlq` do not exist here,
  # which is the fresh-box / sourced-library case. A control that refused the
  # fleet because its own store did not answer is worse than the traffic it
  # removes, so this must be silent and permissive.
  export A2A_ROUND_LEDGER="$TMP/rounds-open.tsv"
  # shellcheck source=../src/lib/a2a_rounds.sh
  . "$ROOT/src/lib/a2a_rounds.sh"
  A2A_ROUND_LEDGER="$TMP/rounds-open.tsv"
  out="$(a2a_round_guard main dev 'DIVE-4242 your PR is red, the typecheck fails' 2>/dev/null)"; rc=$?
  if [[ "$rc" == 0 && -z "$out" ]]; then
    printf '  ok   unreachable board -> the send proceeds, silently\n'
  else
    printf '  FAIL unreachable board must fail OPEN (rc=%s out=%s)\n' "$rc" "$out"; exit 1
  fi
  a2a_open_row_owned dev DIVE-4242 "" >/dev/null 2>&1
  [[ $? == 2 ]] && printf '  ok   a2a_open_row_owned reports "could not look" (rc 2), not "no row"\n' \
                || { printf '  FAIL a2a_open_row_owned must return 2 with no db()\n'; exit 1; }
) || FAIL=$((FAIL+1))
PASS=$((PASS+2))

echo "== part 2: against a real board =="
SRC=src
export STATE_DIR="$TMP/state"
export TASKS_DIR="$STATE_DIR/tasks"
export TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/tasks_db.sh lib/a2a_rounds.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# src/header.sh sets `set -e`. This harness grades REFUSALS, i.e. non-zero
# returns, so `set -e` would kill it on its first correct assertion — as it did.
set +e
# src/lib/output.sh exports its OWN `ok`/`bad`, which silently replaced this
# harness's counters — every assertion printed "OK — …" and PASS stayed at 2, so
# a red arm would have printed and not counted. Redefine AFTER the sources.
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
A2A_ROUND_LEDGER="$TMP/rounds.tsv"
# The DIVE-2249 store fence refuses a sourced-library writer aimed at the PROD
# path only; this board is a throwaway under $TMP, so nothing is fenced. Stated
# because "the fence let it through" must read as a property, not a bypass.
tasks_db_init >/dev/null 2>&1 || { echo "  SKIP: tasks_db_init failed (no sqlite3?)"; echo "PASS=$PASS FAIL=$FAIL"; exit 0; }

seed() { # <ident> <assignee> <status> [delivery_ref]
  db "INSERT INTO tasks(ident,title,status,assignee,created_by,delivery_ref,created_at)
      VALUES($(sqlq "$1"),$(sqlq "row $1"),$(sqlq "$3"),$(sqlq "$2"),'main',$(sqlq_or_null "${4:-}"),datetime('now'));" \
    >/dev/null
}
seed DIVE-9001 dev  todo        'https://github.com/5dive-ai/5dive/pull/777'
seed DIVE-9002 dev  done        ''
seed DIVE-9003 main in_progress ''
seed DIVE-9004 dev  blocked     ''

echo "-- the refusal fires on the case the rule names --"
out="$(a2a_round_guard main dev 'DIVE-9001 your PR is red, the typecheck fails on the second commit.' 2>/dev/null)"; rc=$?
check "handing back a row the recipient owns is REFUSED (rc)" "$rc" "1"
case "$out" in
  *refused*DIVE-9001*"task reject"*) ok "the refusal names the row and the remedy verb" ;;
  *) bad "refusal text is missing the row or the remedy: $out" ;;
esac
case "$out" in
  *"set-body"*|*"assign"*) ok "the refusal offers the other two routes too" ;;
  *) bad "refusal should name set-body/assign as well: $out" ;;
esac
# blocked is open. A row parked on a gate is the MOST likely thing to get pinged
# about, so a status list that forgot it would miss the loudest case.
out="$(a2a_round_guard main dev 'DIVE-9004 please pick this back up, it is unblocked now.' 2>/dev/null)"; rc=$?
check "a BLOCKED row still counts as open" "$rc" "1"
# The ident can sit anywhere in the body, not just at the front (a2a_topic_of
# takes the first ident only; the handback check must take them all).
out="$(a2a_round_guard main dev 'per our thread on DIVE-3318, the follow-up is DIVE-9001 and it is red.' 2>/dev/null)"; rc=$?
check "a later ident in the body is still seen" "$rc" "1"

echo "-- the PR arm --"
out="$(a2a_round_guard main dev 'https://github.com/5dive-ai/5dive/pull/777 needs a rebase before it can land.' 2>/dev/null)"; rc=$?
check "a PR URL bound to their open row is REFUSED" "$rc" "1"
case "$out" in *"PR #777"*) ok "the PR refusal names the PR number" ;; *) bad "PR refusal text: $out" ;; esac
out="$(a2a_round_guard main dev 'take another look at #777 before it lands.' 2>/dev/null)"; rc=$?
check "the bare #N shorthand is caught too" "$rc" "1"
out="$(a2a_round_guard main dev 'unrelated: #778 in another repo just merged.' 2>/dev/null)"; rc=$?
check "a PR bound to NO row of theirs is not refused" "$rc" "0"

echo "-- the negative controls: what must still send --"
# THE ARM THAT MATTERS MOST. Each of these is a message the fleet needs to be
# able to send, and every one of them names a row or a PR. If a future tightening
# breaks them it has broken the rule's own carve-out, not just a test.
neg=(
  "DIVE-9002 is closed — noting the follow-up landed clean on the same tree."   # done row
  "DIVE-9003 is mine, not yours — I am taking the rebase."                      # not their row
  "DIVE-9001 — do you want the 24h or the 7d window before I cut it?"           # a QUESTION
  "DIVE-9001 blocks the release cut, can you land it today?"                    # a QUESTION
  "the release cut is blocked and nobody owns it"                               # no ident at all
  "DIVE-4242 never existed on this board"                                       # unknown ident
)
for m in "${neg[@]}"; do
  out="$(a2a_round_guard main dev "$m" 2>/dev/null)"; rc=$?
  if [[ "$rc" == 0 ]]; then ok "sends: ${m:0:46}…"; else bad "must NOT be refused: $m -> $out"; fi
done
# A send to the row's own OWNER about someone ELSE's row is untouched.
out="$(a2a_round_guard dev main 'DIVE-9001 is red on my side, I own it and I am fixing it.' 2>/dev/null)"; rc=$?
check "the OWNER may still talk about their own row" "$rc" "0"

echo "-- the refusal is not counted as a round --"
rm -f "$A2A_ROUND_LEDGER"
a2a_round_guard main dev 'DIVE-9001 your PR is red.' >/dev/null 2>&1
n=$( [[ -r "$A2A_ROUND_LEDGER" ]] && grep -c . "$A2A_ROUND_LEDGER" || echo 0 )
check "a refused handback writes no ledger row" "$n" "0"

echo "-- the exemptions --"
out="$(_5DIVE_A2A_NOTIFY=1 a2a_round_guard main dev 'DIVE-9001 gate filed, needs your answer.' 2>/dev/null)"; rc=$?
check "the notification rail is exempt" "$rc" "0"
out="$(a2a_round_guard '' dev 'DIVE-9001 your PR is red.' 2>/dev/null)"; rc=$?
check "an unmeasurable sender (human/root relay) is not refused" "$rc" "0"

echo "== part 3: wiring — both send paths must call the guard =="
for f in src/cmd_agent_runtime.sh; do
  n="$(grep -c 'a2a_round_guard' "$f")"
  if (( n >= 2 )); then ok "both send paths in $f call a2a_round_guard ($n sites)"
  else bad "$f has $n a2a_round_guard call sites, expected >= 2 (send + _deliver)"; fi
done
if grep -q 'a2a_handback_refusal' src/lib/a2a_rounds.sh \
   && grep -A6 'a2a_handback_refusal "\$from" "\$to" "\$msg"' src/lib/a2a_rounds.sh | grep -q 'return 1'; then
  ok "a2a_round_guard returns non-zero on a handback (the callers fail on it)"
else
  bad "the handback check is not wired into a2a_round_guard's refusal return"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
