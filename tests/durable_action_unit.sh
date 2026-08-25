#!/usr/bin/env bash
# TIER: nightly — the core tier is over budget (DIVE-2525 / the 300s PR core), so a
# new harness lands nightly by default rather than borrowing headroom it was not
# measured into.
# tests/durable_action_unit.sh — INST-8: durable action semantics (lib/durable.sh).
#
# The property under test is not "the functions run". It is: can a crashed and
# retried agent fire an irreversible action twice? So every arm here is written
# against the ONE failure mode that matters, and three arms exist purely to prove
# the other arms are not passing for the wrong reason:
#
#   * THE MUTATION ARM. The double-claim refusal is supposed to be carried by
#     UNIQUE(idem_key), not by a Bash if. So the harness drops that index and
#     re-runs the same arm: it must go RED. An unmutated green here would mean
#     the concurrency property was never being measured.
#   * THE INVERSION ARM, with its own live control. lib/durable.sh claims it
#     refuses where ledger_emit swallows. Asserting "durable_claim fails on a
#     broken store" alone would pass on any store that is merely absent, so the
#     SAME broken store is handed to ledger_emit in the same arm — it must
#     return 0 while durable_claim refuses, or the two are not actually different.
#   * THE DISTINCTNESS ARM. Four different actions must produce four different
#     keys. A key function that ignored its arguments would pass every replay arm
#     in this file trivially and fail only this one.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/durable-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/actor.sh lib/registry.sh lib/tasks_db.sh lib/durable.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
want() { # <name> <predicate>
  if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL - %s\n     predicate: %s\n' "$1" "$2"; fi
}
q() { sqlite3 "$TASKS_DB" "$1" 2>/dev/null; }
# claim in a SUBSHELL: durable_claim refuses through fail(), which exits.
claim() { ( durable_claim "$@" >/dev/null 2>&1; printf '%s' "$?" ) ; }

echo "-- 1. the migration reached the store this harness runs on"
want "action_leases exists after tasks_db_init" \
     '[[ "$(q "SELECT 1 FROM sqlite_master WHERE type='"'"'table'"'"' AND name='"'"'action_leases'"'"';")" == 1 ]]'
want "UNIQUE index on idem_key exists (the whole guarantee)" \
     '[[ "$(q "SELECT 1 FROM sqlite_master WHERE type='"'"'index'"'"' AND name='"'"'action_leases_idem_idx'"'"';")" == 1 ]]'
# The migration must be gated on action_leases' OWN absence: every live store
# already carries lifecycle_events, so a shared gate would have created this
# table on fresh DBs only (DIVE-2512). Graded on the SOURCE because the effect is
# invisible to a fresh-DB harness by construction.
want "the migration is gated on action_leases' own absence, not lifecycle_events'" \
     'grep -q "name=.action_leases. LIMIT 1" src/lib/tasks_db.sh'
# A pre-INST-8 store: has lifecycle_events, has NO action_leases. This is what
# every box on the fleet looks like, and it is the case the shared gate broke.
LIVE_DIR="$TMP/live"; LIVE="$LIVE_DIR/tasks.db"; mkdir -p "$LIVE_DIR"
( TASKS_DIR="$LIVE_DIR"; TASKS_DB="$LIVE"; tasks_db_init >/dev/null 2>&1 )
sqlite3 "$LIVE" "DROP TABLE action_leases;" 2>/dev/null
want "the fixture really is a pre-INST-8 store (lifecycle_events yes, action_leases no)" \
     '[[ "$(sqlite3 "$LIVE" "SELECT count(*) FROM sqlite_master WHERE name IN ('"'"'lifecycle_events'"'"','"'"'action_leases'"'"');")" == 1 ]]'
want "a store that ALREADY has lifecycle_events still gains action_leases" \
     '( TASKS_DIR="$LIVE_DIR"; TASKS_DB="$LIVE"; _tasks_db_migrate >/dev/null 2>&1; [[ "$(sqlite3 "$LIVE" "SELECT 1 FROM sqlite_master WHERE type='"'"'table'"'"' AND name='"'"'action_leases'"'"';")" == 1 ]] )'
# THE ARM THAT WAS MISSING, and its absence shipped a dead migration to every box.
# The arm above calls _tasks_db_migrate DIRECTLY, and nothing on a live box does:
# tasks_db_init consults the DIVE-2808 skip gate first, and a store already
# stamped with the current $_TASKS_SCHEMA_EPOCH never enters the migration again.
# So a one-shot block added without an epoch bump is green in every fresh-DB
# harness (they start empty and take the canonical schema) and reaches no existing
# board — exactly what INST-8 did, caught only by driving a copy of the real
# 2311-task board. Drive the PUBLIC entry point, on a store that is already
# stamped, and stamp it with the epoch VARIABLE so this arm survives future bumps.
STAMPED_DIR="$TMP/stamped"; STAMPED="$STAMPED_DIR/tasks.db"; mkdir -p "$STAMPED_DIR"
( TASKS_DIR="$STAMPED_DIR"; TASKS_DB="$STAMPED"; tasks_db_init >/dev/null 2>&1 )
sqlite3 "$STAMPED" "DROP TABLE action_leases;" 2>/dev/null
sqlite3 "$STAMPED" "INSERT INTO task_prefs(key,value,updated_at) VALUES ('schema_epoch','3525-1',datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value=excluded.value;" 2>/dev/null
want "the fixture carries a STALE epoch stamp — a real box's shape the day this lands" \
     '[[ "$(sqlite3 "$STAMPED" "SELECT value FROM task_prefs WHERE key='"'"'schema_epoch'"'"';")" != "$_TASKS_SCHEMA_EPOCH" ]]'
want "tasks_db_init — the entry point a live box uses — creates action_leases on it" \
     '( TASKS_DIR="$STAMPED_DIR"; TASKS_DB="$STAMPED"; tasks_db_init >/dev/null 2>&1; [[ "$(sqlite3 "$STAMPED" "SELECT 1 FROM sqlite_master WHERE type='"'"'table'"'"' AND name='"'"'action_leases'"'"';")" == 1 ]] )'
# And the bump itself, pinned. This is the arm that catches a future author adding
# a one-shot block and forgetting the epoch, or a rebase quietly restoring the old
# constant: the epoch must no longer be the value every live board is stamped with.
want "the schema epoch was BUMPED off the value live boards carry (the skip-gate fix)" \
     '[[ "$_TASKS_SCHEMA_EPOCH" != "3525-1" ]]'

echo
echo "-- 2. the key is the ACTION's identity, not the attempt's"
K1=$(durable_key deploy INST-8 app@main prod)
K2=$(durable_key deploy INST-8 app@main prod)
want "the same action computes the same key twice (a retry recognizes itself)" '[[ -n "$K1" && "$K1" == "$K2" ]]'
want "the key is a digest, not a passthrough (>=16 chars)" '[[ ${#K1} -ge 16 ]]'
want "four different actions produce four DIFFERENT keys" \
     '[[ $(printf "%s\n" "$(durable_key deploy INST-8 app@main prod)" "$(durable_key deploy INST-8 app@main preview)" "$(durable_key deploy INST-8 app@other prod)" "$(durable_key deploy INST-9 app@main prod)" | sort -u | wc -l) -eq 4 ]]'
want "no pid, timestamp or nonce in the key derivation" \
     '! grep -nE "durable_key\(\)" -A 12 src/lib/durable.sh | grep -qE "\\\$\\\$|date |EPOCH|RANDOM"'
want "an empty digest REFUSES instead of returning a key every action would share" \
     'grep -q "refusing to act on an empty idempotency key" src/lib/durable.sh'

echo
echo "-- 3. claim / replay / in-flight — the three answers a caller must branch on"
want "a first claim is granted (rc 0)"                  '[[ "$(claim deploy INST-8 app@main prod)" == 0 ]]'
want "it left exactly ONE lease row"                    '[[ "$(q "SELECT count(*) FROM action_leases;")" == 1 ]]'
want "the row is held, attempts=1, and carries its target" \
     '[[ "$(q "SELECT state||\"/\"||attempts||\"/\"||target FROM action_leases;")" == "held/1/app@main" ]]'
want "a SECOND claim of the same action while the lease is live is refused (rc 4)" \
     '[[ "$(claim deploy INST-8 app@main prod)" == 4 ]]'
want "the refused claim did NOT create a second row" '[[ "$(q "SELECT count(*) FROM action_leases;")" == 1 ]]'
want "a claim on a DIFFERENT action is unaffected (rc 0)" '[[ "$(claim deploy INST-8 app@main preview)" == 0 ]]'
durable_settle "$K1" done "dpl_receipt_1" >/dev/null 2>&1
want "settling done records the receipt" '[[ "$(q "SELECT outcome_ref FROM action_leases WHERE idem_key=\"$K1\";")" == "dpl_receipt_1" ]]'
want "after done, the same action REPLAYS (rc 3) instead of being granted" \
     '[[ "$(claim deploy INST-8 app@main prod)" == 3 ]]'
want "the replay hands back the ORIGINAL receipt, not an empty string" \
     '( durable_claim deploy INST-8 app@main prod >/dev/null 2>&1; [[ "$DURABLE_OUTCOME_REF" == "dpl_receipt_1" ]] )'
want "a replay does not bump attempts (it did not act)" \
     '[[ "$(q "SELECT attempts FROM action_leases WHERE idem_key=\"$K1\";")" == 1 ]]'

echo
echo "-- 4. crash recovery, and the double-fire window it opens"
durable_settle "$(durable_key deploy INST-8 app@main preview)" failed "curl rc=7" >/dev/null 2>&1
want "a FAILED attempt is retryable (rc 0) — 'we tried' is not 'it happened'" \
     '[[ "$(claim deploy INST-8 app@main preview)" == 0 ]]'
want "the retry bumps attempts to 2" \
     '[[ "$(q "SELECT attempts FROM action_leases WHERE target=\"app@main\" AND surface=\"deploy\" AND idem_key=\"$(durable_key deploy INST-8 app@main preview)\";")" == 2 ]]'
KX=$(durable_key deploy INST-8 wedged@main prod)
claim deploy INST-8 wedged@main prod >/dev/null
want "a lease held by a LIVE attempt is not stealable" '[[ "$(claim deploy INST-8 wedged@main prod)" == 4 ]]'
q "UPDATE action_leases SET expires_at=datetime('now','-1 hours') WHERE idem_key='$KX';" >/dev/null
want "an EXPIRED held lease is reclaimable — one crash must not wedge the surface forever" \
     '[[ "$(claim deploy INST-8 wedged@main prod)" == 0 ]]'
want "the reclaim is recorded as a reclaim, not as a fresh claim" \
     '[[ "$(q "SELECT count(*) FROM lifecycle_events WHERE detail LIKE \"%lease=reclaimed_from=held%\";")" -ge 1 ]]'
want "a DONE lease is never reclaimed even after its expiry passes" \
     '( q "UPDATE action_leases SET expires_at=datetime(\"now\",\"-1 hours\") WHERE idem_key=\"$K1\";" >/dev/null; [[ "$(claim deploy INST-8 app@main prod)" == 3 ]] )'
# The TTL is the bet: reclaiming an expired lease double-fires if the original
# attempt was slow rather than dead. Graded against cmd_deploy.sh's OWN curl
# timeouts, so shortening either side without the other reds this arm.
want "the default TTL exceeds the deploy action's own worst-case wall time" \
     '[[ "$_DURABLE_TTL_DEFAULT" -gt "$(( $(grep -o "max-time [0-9]*" src/cmd_deploy.sh | grep -o "[0-9]*" | sort -rn | head -1) * 2 ))" ]]'
want "the TTL bet is DOCUMENTED where the reclaim is, not only here" \
     'grep -q "TTL is therefore a bet" src/lib/durable.sh'

echo
echo "-- 5. the mutation arm: is UNIQUE(idem_key) actually carrying the property?"
MUT="$TMP/mut.db"
( TASKS_DB="$MUT"; tasks_db_init >/dev/null 2>&1
  sqlite3 "$MUT" "DROP INDEX action_leases_idem_idx;" 2>/dev/null
  durable_claim deploy INST-8 mut@main prod >/dev/null 2>&1
  durable_claim deploy INST-8 mut@main prod >/dev/null 2>&1 ) >/dev/null 2>&1
MUT_ROWS=$(sqlite3 "$MUT" "SELECT count(*) FROM action_leases;" 2>/dev/null)
want "without the UNIQUE index the double claim DOES double-insert (arm 3 was real)" \
     '[[ "$MUT_ROWS" == 2 ]]'
want "and with the index the same sequence yields ONE row (the control)" \
     '[[ "$(q "SELECT count(*) FROM action_leases WHERE target=\"wedged@main\";")" == 1 ]]'

echo
echo "-- 6. the inversion: a lease write refuses where a ledger write swallows"
BROKE="$TMP/nodir/nope.db"
want "durable_claim REFUSES (non-zero) on an unwritable store" \
     '[[ "$( ( TASKS_DB="$BROKE"; durable_claim deploy INST-8 x@main prod >/dev/null 2>&1; printf %s $? ) )" != 0 ]]'
want "ledger_emit on the SAME unwritable store returns 0 (the live control)" \
     '[[ "$( ( TASKS_DB="$BROKE"; ledger_emit test.control ident=INST-8 >/dev/null 2>&1; printf %s $? ) )" == 0 ]]'
NOTBL="$TMP/notbl.db"
sqlite3 "$NOTBL" "CREATE TABLE t(x);" 2>/dev/null
want "a store MISSING action_leases refuses rather than reading as 'no prior action'" \
     '[[ "$( ( TASKS_DB="$NOTBL"; durable_claim deploy INST-8 x@main prod >/dev/null 2>&1; printf %s $? ) )" != 0 ]]'
want "settling a key that does not exist is LOUD, not a silent zero-row update" \
     '[[ "$( ( durable_settle "deadbeefdeadbeefdeadbeef" done r1 >/dev/null 2>&1; printf %s $? ) )" != 0 ]]'

echo
echo "-- 7. compensation is RECORDED, never executed"
durable_compensation "$K1" "vercel rollback dpl_receipt_1" >/dev/null 2>&1
want "the compensation is stored next to the action it undoes" \
     '[[ "$(q "SELECT compensation FROM action_leases WHERE idem_key=\"$K1\";")" == "vercel rollback dpl_receipt_1" ]]'
want "nothing in lib/durable.sh evals, sources or shells out a compensation" \
     '! grep -nE "eval|bash -c|sh -c|\\\$\\(compensation" src/lib/durable.sh | grep -qv "^[0-9]*:#"'
want "a compensation on an unknown key refuses" \
     '[[ "$( ( durable_compensation deadbeefdeadbeefdeadbeef "undo" >/dev/null 2>&1; printf %s $? ) )" != 0 ]]'

echo
echo "-- 8. scope: only IRREVERSIBLE surfaces take a lease"
want "every broker surface answers the irrev field" \
     'for s in $(broker_surfaces); do broker_surface "$s" irrev >/dev/null || exit 1; done'
want "the two surfaces DISAGREE (the field is live, not one constant)" \
     '[[ "$(broker_surface deploy irrev)" == 1 && "$(broker_surface push irrev)" == 0 ]]'
want "an unknown surface still HARD-fails on irrev rather than returning empty" \
     '[[ "$( ( broker_surface email irrev >/dev/null 2>&1; printf %s $? ) )" != 0 ]]'
# THE PLACEMENT INVARIANT, and it is the one that decides whether an ordinary
# refusal can wedge the surface for a full TTL. Every fail() the verb can raise
# must sit ABOVE the claim, and the claim must sit immediately above the POST —
# so there is no exit path between "we hold the lease" and "we acted" other than
# a real crash, which is what the TTL is for. Graded by line order, both sides.
want "the claim sits BELOW the last refusal the verb can raise (no wedge path)" \
     '[[ $(grep -n "durable_claim deploy" src/cmd_deploy.sh | cut -d: -f1) -gt $(grep -n "has no linked GitHub repo" src/cmd_deploy.sh | cut -d: -f1) ]]'
want "the claim sits ABOVE the POST that fires the deploy" \
     '[[ $(grep -n "durable_claim deploy" src/cmd_deploy.sh | cut -d: -f1) -lt $(grep -n "v13/deployments" src/cmd_deploy.sh | cut -d: -f1) ]]'
want "and above the credential read there is NO claim (an early claim was the wedge)" \
     '[[ $(grep -n "broker_connector_read" src/cmd_deploy.sh | tail -1 | cut -d: -f1) -lt $(grep -n "durable_claim deploy" src/cmd_deploy.sh | cut -d: -f1) ]]'
want "cmd_deploy settles DONE with the deployment id as the receipt" \
     'grep -q "durable_settle \"\$DURABLE_KEY\" done \"\$did\"" src/cmd_deploy.sh'
want "cmd_deploy settles FAILED before it refuses, so a refusal cannot wedge the lease" \
     '[[ $(grep -n "durable_settle \"\$DURABLE_KEY\" failed" src/cmd_deploy.sh | cut -d: -f1) -lt $(grep -n "Vercel deployment request failed" src/cmd_deploy.sh | tail -1 | cut -d: -f1) ]]'
want "the reversible surface (push) took no lease — scope held" \
     '! grep -q "durable_claim" src/cmd_push.sh'
want "lib/durable.sh is registered in the bundle" 'grep -q "src/lib/durable.sh" build.sh'

echo
echo "durable action unit: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
