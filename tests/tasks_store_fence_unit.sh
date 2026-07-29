#!/usr/bin/env bash
# DIVE-2249: the PRODUCTION task board refuses a write from a sourced-library
# caller, so a harness that forgets (or loses) its STATE_DIR isolation cannot
# append real-looking fixture rows to the live board.
#
# Background: on 2026-07-27 a run of tests/gate_verifier_route_unit.sh put six
# fixture rows (DIVE-501..506, created_by=dev) on the LIVE board, and they were
# not inert — two real gate deliveries fired and a human-facing gate had to be
# withdrawn by hand. Same class as DIVE-1500 (gate-notify), DIVE-1506 (human DM
# relay) and DIVE-2010 (audit_log); this is the store those three read FROM.
#
# HERMETIC BY CONSTRUCTION. Every arm points FIVEDIVE_FENCE_EXTRA_STORE at a decoy
# under $TMP and aims the writers at that same decoy, so "prod" here is a file
# this harness owns. The real /var/lib/5dive is never opened, never compared
# against, and never depended on — this suite is identical on a dev box and in
# CI, and cannot itself become the leak it is testing for.
#
# Run: bash tests/tasks_store_fence_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/tasks-store-fence.XXXXXX)"
SUMMARY_PRINTED=0
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf "$TMP" "$PWD/tests/.dive2249-mutant.sh"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - tasks_store_fence_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&2' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The decoy that plays "the production board" for the whole suite.
PROD_DIR="$TMP/prodstate"; PROD_DB="$PROD_DIR/tasks/tasks.db"
mkdir -p "$PROD_DIR/tasks"
export FIVEDIVE_FENCE_EXTRA_STORE="$PROD_DB"

# A sourced-library caller, run as a child so a fenced `fail` exits IT, not us.
# $1 = extra env assignments (as a string), $2 = the body to run after sourcing.
sourced_caller() {
  env -u _TASKS_STORE_ENTRY bash -c "
    set -uo pipefail
    cd '$PWD'
    export FIVEDIVE_FENCE_EXTRA_STORE='$PROD_DB'
    $1
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
             lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
             lib/tasks_db.sh; do source '$SRC'/\$f; done
    $2
  " 2>&1
}

rows() { sqlite3 "$PROD_DB" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || echo MISSING; }

# ---------------------------------------------------------------- arm 0: setup
# Create the decoy board through the ALLOWED path (entrypoint marker set). This
# doubles as the first proof that the fence does not brick the real CLI: if the
# marker did not open the gate, there would be no board to test against at all.
setup_out=$(sourced_caller \
  "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
  '_TASKS_STORE_ENTRY=cli; tasks_db_init')
if [[ "$(rows)" == "MISSING" ]]; then
  bad_t "decoy prod board initialises via the CLI entrypoint" "$setup_out"
  printf -- '-----\ntasks_store_fence_unit: %s passed, %s failed\n' "$PASS" "$((FAIL))"
  SUMMARY_PRINTED=1; exit 1
fi
ok_t "CLI entrypoint may still initialise the prod board (fence is not a lockout)"
BASE=$(rows)

# --------------------------------------------- arm 1: the fence (the RED arm)
# A sourced caller aiming an INSERT at the prod store must be refused.
out1=$(sourced_caller \
  "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
  "db \"INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-501','loop task','todo','dev','dev');\"")
rc1=$?
after1=$(rows)
if [[ "$after1" == "$BASE" ]]; then
  ok_t "sourced-library INSERT into the prod board is refused (rows unchanged: $BASE)"
else
  bad_t "sourced-library INSERT into the prod board is refused" "rows went $BASE -> $after1"
fi
if grep -qi 'DIVE-2249' <<<"$out1"; then
  ok_t "refusal names the ticket and the store, so the harness author can act on it"
else
  bad_t "refusal is legible" "expected DIVE-2249 in the refusal; got: $(head -c 300 <<<"$out1")"
fi

# ------------------------------------- arm 1b: the refusal is LOUD (agent-main)
# "rows unchanged" and "message present" can BOTH hold while the caller sails on
# — and a fenced harness that keeps running turns from RED into VACUOUS, which is
# the defect class this whole ticket sits in. So assert the property that matters:
# the process must DIE at the fence, non-zero, with the diagnostic on stderr.
# The marker line below runs only if execution survived the refusal.
loud_out=$(sourced_caller \
  "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
  "db \"INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-501','loop task','todo','dev','dev');\"
   printf 'EXECUTION-CONTINUED-PAST-FENCE\n'")
loud_rc=$?
if (( loud_rc != 0 )) && ! grep -q 'EXECUTION-CONTINUED-PAST-FENCE' <<<"$loud_out"; then
  ok_t "the refusal is LOUD — non-zero exit ($loud_rc) and execution stops at the fence, so a fenced harness goes RED not vacuous"
else
  bad_t "the refusal is LOUD" \
        "rc=$loud_rc, continued=$(grep -q 'EXECUTION-CONTINUED-PAST-FENCE' <<<"$loud_out" && echo YES || echo no). A refusal that returns 0, or that lets the caller carry on, converts every fenced harness from a red into a test that passes having asserted nothing."
fi

# ------------------------------------------- arm 2: LIVENESS (anti-vacuity)
# The SAME insert, from the CLI entrypoint, must LAND. Without this arm, arm 1's
# "rows unchanged" would also pass if the INSERT were malformed, the table were
# missing, or sqlite were absent — i.e. it would pass for reasons that have
# nothing to do with the fence.
out2=$(sourced_caller \
  "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
  "_TASKS_STORE_ENTRY=cli; db \"INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-501','loop task','todo','dev','dev');\"")
after2=$(rows)
if (( after2 == BASE + 1 )); then
  ok_t "the identical INSERT LANDS from the CLI entrypoint (arm 1's zero is not vacuous)"
else
  bad_t "the identical INSERT lands from the CLI entrypoint" \
        "rows went $BASE -> $after2 (expected $((BASE+1))); the refusal in arm 1 may be passing for the wrong reason. out: $(head -c 300 <<<"$out2")"
fi
sqlite3 "$PROD_DB" "DELETE FROM tasks WHERE ident='DIVE-501';" 2>/dev/null
BASE=$(rows)

# --------------------------------------- arm 3: an ISOLATED store still works
# The fence keys on the prod path, not on "is a test", so a harness that DID
# isolate is untouched. If this reds, the fence has broken all 200+ harnesses.
ISO="$TMP/iso"; mkdir -p "$ISO/tasks"
out3=$(sourced_caller \
  "export STATE_DIR='$ISO' TASKS_DIR='$ISO/tasks' TASKS_DB='$ISO/tasks/tasks.db'" \
  "tasks_db_init; db \"INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-501','loop task','todo','dev','dev');\"")
iso_rows=$(sqlite3 "$ISO/tasks/tasks.db" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || echo MISSING)
if [[ "$iso_rows" == "1" ]]; then
  ok_t "an isolated store is unaffected — properly-fenced harnesses still write"
else
  bad_t "an isolated store is unaffected" "expected 1 row in the throwaway store, got '$iso_rows'. out: $(head -c 300 <<<"$out3")"
fi

# ------------------------------------------------- arm 4: READS are not fenced
out4=$(sourced_caller \
  "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
  "db 'SELECT COUNT(*) FROM tasks;'")
if [[ "$out4" =~ ^[0-9]+$ ]]; then
  ok_t "a sourced READ of the prod board is still allowed (fence is write-scoped)"
else
  bad_t "a sourced READ of the prod board is still allowed" "got: $(head -c 200 <<<"$out4")"
fi

# ------------------- arm 4b: the shape a verb BLOCKLIST let through, and one it
# caught. Kept as a pair on purpose so the claim stays honest: the blocklist
# draft of this fence DID catch the CTE-prefixed INSERT (the token ` INSERT `
# still appears whitespace-delimited), and let `ATTACH DATABASE` straight
# through. Only the second is a bypass the allowlist fixed — the first is a
# regression guard. Both are asserted the same way so a future edit that
# re-inverts the check reds on the one that matters.
for probe in \
  "WITH src AS (SELECT 'DIVE-501' AS i) INSERT INTO tasks(ident,title,status,created_by,assignee) SELECT i,'loop task','todo','dev','dev' FROM src;" \
  "ATTACH DATABASE '$TMP/elsewhere.db' AS side;" ; do
  pre=$(rows)
  outp=$(sourced_caller \
    "export STATE_DIR='$PROD_DIR' TASKS_DIR='$PROD_DIR/tasks' TASKS_DB='$PROD_DB'" \
    "db \"${probe//\"/\\\"}\"")
  label="${probe%% *}"
  if [[ "$(rows)" == "$pre" ]] && grep -qi 'DIVE-2249' <<<"$outp"; then
    ok_t "a ${label}-prefixed statement is refused (read allowlist, not a verb blocklist)"
  else
    bad_t "a ${label}-prefixed statement is refused" \
          "rows $pre -> $(rows); out: $(head -c 250 <<<"$outp")"
  fi
done

# --------- arm 4c: FIVEDIVE_PROD_TASKS_DB does NOT arm this fence
# 23 harnesses export that variable pointing at their own throwaway store, to
# open the DIVE-1506 human-send allowlist. If the fence ever starts reading it,
# every one of them breaks while the real board gains nothing — so assert the
# separation directly rather than trusting a comment.
ISO2="$TMP/iso2"; mkdir -p "$ISO2/tasks"
out4c=$(sourced_caller \
  "export STATE_DIR='$ISO2' TASKS_DIR='$ISO2/tasks' TASKS_DB='$ISO2/tasks/tasks.db' FIVEDIVE_PROD_TASKS_DB='$ISO2/tasks/tasks.db'" \
  "tasks_db_init; db \"INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-501','loop task','todo','dev','dev');\"")
iso2_rows=$(sqlite3 "$ISO2/tasks/tasks.db" 'SELECT COUNT(*) FROM tasks;' 2>/dev/null || echo MISSING)
if [[ "$iso2_rows" == "1" ]]; then
  ok_t "a harness that declares its OWN store prod via FIVEDIVE_PROD_TASKS_DB still writes (fence does not read that knob)"
else
  bad_t "FIVEDIVE_PROD_TASKS_DB does not arm the fence" \
        "expected 1 row in the throwaway store, got '$iso2_rows' — this fence is now breaking the 23 suites that set that variable. out: $(head -c 300 <<<"$out4c")"
fi

# ------------------------------- arm 5: the DIVE-2249 regression, on the real
# harness, mutation-graded BY CONSTRUCTION.
#
# Take tests/gate_verifier_route_unit.sh and delete the one line that gives it
# its isolation — the exact mutation that reproduced the original leak six rows
# at a time — then run it with the decoy standing in as prod. The assertion is
# the ticket's: running the suite adds ZERO rows to the production board.
#
# This arm IS the mutation arm. It does not test the harness in its healthy
# state (which passes trivially); it tests the broken state that actually
# happened, so if the fence ever regresses this reds immediately with the six
# fixture idents named.
VICTIM=tests/gate_verifier_route_unit.sh
if [[ ! -f "$VICTIM" ]]; then
  printf 'SKIP - DIVE-2249 regression: %s not present in this tree (precondition unavailable, NOT a pass)\n' "$VICTIM"
else
  # The mutant must live in tests/ — gate_verifier_route_unit.sh locates the tree
  # it grades with `cd "$(dirname "$0")/.."`, so a copy under $TMP would cd to
  # /tmp, fail to source src/, and add zero rows for a reason that has nothing to
  # do with the fence. That vacuous pass is exactly what this arm exists to avoid,
  # and it is why the loud-failure assertion below is not optional.
  MUT="tests/.dive2249-mutant.sh"
  sed 's|^STATE_DIR="\$TMP"; TASKS_DIR=.*|# DIVE-2249 mutation: isolation deliberately removed|' "$VICTIM" >"$MUT"
  if ! grep -q 'DIVE-2249 mutation' "$MUT"; then
    bad_t "DIVE-2249 regression: mutation landed" \
          "the STATE_DIR isolation line in $VICTIM no longer matches the mutation pattern — this arm would be grading an UNMUTATED harness and passing for free; re-derive the pattern"
  else
    BASE5=$(rows)
    env -u _TASKS_STORE_ENTRY \
        STATE_DIR="$PROD_DIR" TASKS_DIR="$PROD_DIR/tasks" TASKS_DB="$PROD_DB" \
        FIVEDIVE_FENCE_EXTRA_STORE="$PROD_DB" \
        bash "$MUT" >"$TMP/mutant.out" 2>&1
    after5=$(rows)
    leaked=$(sqlite3 "$PROD_DB" \
      "SELECT group_concat(ident,',') FROM tasks WHERE ident IN ('DIVE-501','DIVE-502','DIVE-503','DIVE-504','DIVE-505','DIVE-506');" 2>/dev/null)
    if (( after5 == BASE5 )) && [[ -z "$leaked" ]]; then
      ok_t "DIVE-2249 regression: an UNISOLATED gate_verifier_route_unit adds ZERO rows to the prod board"
    else
      bad_t "DIVE-2249 regression: an UNISOLATED gate_verifier_route_unit adds ZERO rows to the prod board" \
            "rows $BASE5 -> $after5; fixture idents present: ${leaked:-none}. This is the original leak, live again."
    fi
    if grep -qi 'DIVE-2249' "$TMP/mutant.out"; then
      ok_t "the unisolated run FAILS LOUDLY rather than silently writing elsewhere"
    else
      bad_t "the unisolated run fails loudly" "no DIVE-2249 refusal in the mutant's output; a fence that drops writes silently is the same defect one layer over. head: $(head -c 300 "$TMP/mutant.out")"
    fi
  fi
fi

printf -- '-----\ntasks_store_fence_unit: %s passed, %s failed\n' "$PASS" "$FAIL"
SUMMARY_PRINTED=1
(( FAIL == 0 ))
