#!/usr/bin/env bash
# DIVE-1923 unit: the capture path behind `proof scorecard`'s
# "autonomous rollback rate".
#
# Before this, the metric had NO source. Nothing in the fleet recorded an agent
# undoing work it had already SHIPPED — `task reject` is a verifier bounce that
# happens before a ship, a different event — so the row shipped as an explicit
# NO DATA marker rather than a 0.0% that would read as "we never roll back".
#
# This suite is deliberately mostly NEGATIVE, in the shape DIVE-1914 established:
# an empty source must never yield a number, and the assertions that matter most
# are the ones that fail when the feature is silently absent.
#   * Case 1 is the MIGRATION, guarded on ship_events ITSELF. DIVE-1922 nested
#     its DDL under a neighbouring table's absence check, so it never ran on any
#     existing box and the metric read NO DATA forever — indistinguishable from
#     "nothing has been reverted yet". Every live box now HAS policy_refusals, so
#     nesting this table there would reproduce that bug exactly; Case 1b asserts
#     structurally that it is not nested.
#   * Case 5 is the one that keeps the metric honest: a ledger with ZERO ships
#     must stay NO DATA. A rate over an empty denominator is undefined, and
#     0.0% is precisely the false reading the original marker existed to refuse.
#
# Isolated: temp sqlite store + temp git repo, no prod DB, no root, no network.
#   bash tests/rollback_rate_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/rollback-rate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- Case 1: THE MIGRATION, on a store shaped like every real box: it already
#     has policy_refusals, so a ship_events DDL nested under THAT guard would be
#     unreachable everywhere it matters.
DB="$TMP/legacy.db"
sqlite3 "$DB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, ident TEXT);
               CREATE TABLE supervisor_events (id INTEGER PRIMARY KEY, agent TEXT, classification TEXT);
               CREATE TABLE policy_refusals (id INTEGER PRIMARY KEY, policy TEXT);" 2>/dev/null
[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='ship_events';")" == "0" ]] \
  && ok_t "precondition: legacy store HAS policy_refusals but NOT ship_events" \
  || bad_t "precondition"

export STATE_DIR="$TMP/state"
export TASKS_DIR="$STATE_DIR/tasks"
export TASKS_DB="$DB"
mkdir -p "$TASKS_DIR"
: > "$STATE_DIR/tasks/.board-initialized"   # pre-existing board (DIVE-1479 guard)
# shellcheck disable=SC1091
migrate_out=$( set +e; . src/lib/tasks_db.sh >/dev/null 2>&1; tasks_db_init 2>&1 ); migrate_rc=$?
(( migrate_rc == 0 )) \
  && ok_t "tasks_db_init completes on a legacy store without error" \
  || bad_t "the migration driver itself FAILED (rc=$migrate_rc)" "$migrate_out"

[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='ship_events';")" == "1" ]] \
  && ok_t "migration creates ship_events on a store that ALREADY has policy_refusals" \
  || bad_t "migration nested under the wrong guard" \
           "ship_events absent after migrate — the DDL is unreachable on every existing box"

# --- Case 1b: structural. The ship_events migration must be guarded on its OWN
#     existence check, not swept into the policy_refusals heredoc. This is the
#     assertion that would have caught DIVE-1922's defect at review, before any
#     box was in the wrong state.
if awk '/has_policy_refusals=\$\(sqlite3/{f=1} f&&/^MIG$/{exit} f' src/lib/tasks_db.sh \
     | grep -q 'CREATE TABLE IF NOT EXISTS ship_events'; then
  bad_t "ship_events DDL is nested inside the policy_refusals guard" \
        "it would never run on a box that already has policy_refusals — i.e. all of them"
else
  ok_t "ship_events DDL is NOT nested inside the policy_refusals guard"
fi
grep -q 'name=.ship_events. LIMIT 1' src/lib/tasks_db.sh \
  && ok_t "the migration guards on ship_events itself" \
  || bad_t "no self-guard" "the block does not test for the table it creates"

# --- Case 2: the DDL is identical across its two definitions (fresh + migrate).
[[ "$(grep -c '^CREATE TABLE IF NOT EXISTS ship_events (' src/lib/tasks_db.sh)" == "2" ]] \
  && ok_t "ship_events is defined in BOTH the fresh-store and migrate schemas" \
  || bad_t "schema copies" "expected 2 definitions"

# --- Case 3: the WRITER. Sources the real ship_ledger_record out of the shipped
#     lib rather than reconstructing it (the vacuous-harness trap DIVE-1922 hit).
DB2="$TMP/live.db"
sqlite3 "$DB2" "$(awk '/^CREATE TABLE IF NOT EXISTS ship_events \(/{f=1} f{print} f&&/^\);$/{exit}' src/lib/tasks_db.sh)
CREATE UNIQUE INDEX IF NOT EXISTS ship_events_kind_sha_idx ON ship_events(kind, sha);"

awk '/^ship_ledger_record\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/lib/tasks_db.sh > "$TMP/writer.sh"
[[ -s "$TMP/writer.sh" ]] \
  && ok_t "extracted the real ship_ledger_record from src/lib/tasks_db.sh" \
  || bad_t "extract ship_ledger_record" "not found"

cat > "$TMP/drive_writer.sh" <<'DRIVE'
set -uo pipefail
db()   { sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "$@"; }
sqlq() { local v="${1-}"; printf "'%s'" "${v//\'/\'\'}"; }
source "$TMP/writer.sh"
ship_ledger_record ship     DIVE-1 acme/repo br aaaaaaa1 ""
ship_ledger_record ship     DIVE-1 acme/repo br aaaaaaa1 ""     # duplicate push
ship_ledger_record ship     DIVE-1 acme/repo br bbbbbbb2 ""
ship_ledger_record rollback DIVE-2 acme/repo br ccccccc3 aaaaaaa1   # undoes OUR ship
ship_ledger_record rollback DIVE-2 acme/repo br ddddddd4 eeeeeee5   # undoes a stranger
DRIVE
TMP="$TMP" TASKS_DB="$DB2" bash "$TMP/drive_writer.sh" >/dev/null 2>&1

[[ "$(sqlite3 "$DB2" "SELECT COUNT(*) FROM ship_events WHERE kind='ship';")" == "2" ]] \
  && ok_t "re-recording the same sha is idempotent — the denominator counts commits, not pushes" \
  || bad_t "duplicate ships recorded" "$(sqlite3 "$DB2" "SELECT COUNT(*) FROM ship_events WHERE kind='ship';")"
[[ "$(sqlite3 "$DB2" "SELECT self FROM ship_events WHERE sha='ccccccc3';")" == "1" ]] \
  && ok_t "a revert of a RECORDED ship is marked self=1 (provably our own work)" \
  || bad_t "self not set" "reverting a known ship must be attributable"
[[ "$(sqlite3 "$DB2" "SELECT self FROM ship_events WHERE sha='ddddddd4';")" == "0" ]] \
  && ok_t "a revert of an UNKNOWN sha stays self=0 — never promoted into the numerator" \
  || bad_t "unprovable revert counted as ours" \
           "authorship cannot establish this: every commit we push is authored lodar"

# --- Case 4: the WALKER, exercised against a real git repo. This is the layer
#     the ordering bug lives in — rev-list is newest-first, so recording ships
#     and rollbacks in ONE pass looks up a reverted sha before its ship row
#     exists and marks a provable self-revert as unattributable. A renderer- or
#     writer-level test structurally cannot see that (DIVE-1914's lesson).
REPO="$TMP/repo"; mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main .
  git config user.email t@example.com; git config user.name t
  echo base > a.txt; git add a.txt; git commit -qm base
  git checkout -q -b feat
  echo change > a.txt; git commit -qam "feat: a change"
  BAD=$(git rev-parse HEAD)
  git revert --no-edit "$BAD"
  git rev-parse "$BAD" > "$TMP/bad.sha"
) >/dev/null 2>&1

DB3="$TMP/walk.db"
sqlite3 "$DB3" "$(awk '/^CREATE TABLE IF NOT EXISTS ship_events \(/{f=1} f{print} f&&/^\);$/{exit}' src/lib/tasks_db.sh)
CREATE UNIQUE INDEX IF NOT EXISTS ship_events_kind_sha_idx ON ship_events(kind, sha);"
awk '/^_push_record_ship_ledger\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/cmd_push.sh > "$TMP/walker.sh"
[[ -s "$TMP/walker.sh" ]] \
  && ok_t "extracted the real _push_record_ship_ledger from src/cmd_push.sh" \
  || bad_t "extract walker" "not found"

cat > "$TMP/drive_walk.sh" <<'DRIVE'
set -uo pipefail
db()   { sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "$@"; }
sqlq() { local v="${1-}"; printf "'%s'" "${v//\'/\'\'}"; }
source "$TMP/writer.sh"
source "$TMP/walker.sh"
_push_record_ship_ledger "$REPO" feat DIVE-1923 acme/repo
DRIVE
TMP="$TMP" REPO="$REPO" TASKS_DB="$DB3" bash "$TMP/drive_walk.sh" >/dev/null 2>&1

BAD="$(cat "$TMP/bad.sha" 2>/dev/null || echo none)"
[[ "$(sqlite3 "$DB3" "SELECT COUNT(*) FROM ship_events WHERE kind='ship';")" == "2" ]] \
  && ok_t "the walker records only the branch's own commits, not main's history" \
  || bad_t "wrong ship count" "$(sqlite3 "$DB3" "SELECT sha FROM ship_events WHERE kind='ship';")"
[[ "$(sqlite3 "$DB3" "SELECT COUNT(*) FROM ship_events WHERE kind='rollback';")" == "1" ]] \
  && ok_t "the walker detects the revert from git's own \"This reverts commit\" line" \
  || bad_t "revert not detected" "no new discipline is asked of anyone — git writes that line"
[[ "$(sqlite3 "$DB3" "SELECT reverts FROM ship_events WHERE kind='rollback';")" == "$BAD" ]] \
  && ok_t "the walker captures WHICH sha was undone" \
  || bad_t "wrong reverts sha" "got $(sqlite3 "$DB3" "SELECT reverts FROM ship_events WHERE kind='rollback';") want $BAD"
[[ "$(sqlite3 "$DB3" "SELECT self FROM ship_events WHERE kind='rollback';")" == "1" ]] \
  && ok_t "ships are recorded BEFORE rollbacks — a same-push self-revert is attributable" \
  || bad_t "one-pass ordering bug" \
           "the revert was looked up before its ship row existed, so self=0 (rev-list is newest-first)"

# --- Case 5: THE RENDERER, and the assertion this whole ticket exists for.
#     Extract the real python block and drive it at each of the three states.
python3 - <<'EOF' > "$TMP/render.py"
import re
src = open('src/cmd_proof.sh').read()
i = src.index('_ships = os.environ.get("SHIPS"')
j = src.index('by = os.environ["BY"]', i)
open('/dev/stdout','w').write(
    'import os\n'
    'def metric(name, value, sample=None, note=None, nodata=None):\n'
    '    return {"name": name, "value": value, "sample": sample, "note": note, "nodata": nodata}\n'
    'metrics = []\n' + src[i:j] +
    '\nimport json; print(json.dumps(metrics[-1]))\n')
EOF
[[ -s "$TMP/render.py" ]] \
  && ok_t "extracted the real rollback-rate renderer from src/cmd_proof.sh" \
  || bad_t "extract renderer" "not found"

render() { env -u SHIPS -u ROLLBACKS -u ROLLBACKS_UNPROVEN -u LEDGER_SINCE "$@" python3 "$TMP/render.py"; }

R="$(render)"
grep -q '"value": null' <<<"$R" && grep -q 'no ship_events ledger' <<<"$R" \
  && ok_t "no ledger at all renders NO DATA, naming the missing source" \
  || bad_t "absent ledger" "$R"

R="$(render SHIPS=0 ROLLBACKS=0 ROLLBACKS_UNPROVEN=0 LEDGER_SINCE='2026-07-26 09:00:00')"
grep -q '"value": null' <<<"$R" \
  && ok_t "a ledger with ZERO ships stays NO DATA — a rate over an empty denominator is undefined" \
  || bad_t "0 ships rendered a number" \
           "0.0% here reads as 'we never roll back', the exact false claim the marker existed to refuse: $R"
# The marker's own prose says "not 0.0%", so match the VALUE field, not the blob.
grep -q '"value": "0.0%"' <<<"$R" \
  && bad_t "0.0% emitted on an empty denominator" "$R" \
  || ok_t "no 0.0% value is emitted when nothing has shipped"
grep -q '2026-07-26' <<<"$R" \
  && ok_t "the no-data marker states when the ledger opened, so absence is dateable" \
  || bad_t "no ledger date" "$R"

R="$(render SHIPS=100 ROLLBACKS=3 ROLLBACKS_UNPROVEN=0)"
grep -q '"value": "3.0%"' <<<"$R" \
  && ok_t "ships > 0 renders a real rate" || bad_t "rate wrong" "$R"
grep -q '3 of 100 recorded ships reverted' <<<"$R" \
  && ok_t "the sample rides ON the number, never in a footnote" || bad_t "no sample" "$R"

R="$(render SHIPS=100 ROLLBACKS=0 ROLLBACKS_UNPROVEN=0)"
grep -q '"value": "0.0%"' <<<"$R" && grep -q '0 of 100 recorded ships reverted' <<<"$R" \
  && ok_t "0.0% over a NON-empty denominator is a real measurement and does ship" \
  || bad_t "honest zero suppressed" "a sourced zero must render; only an empty denominator must not: $R"

R="$(render SHIPS=100 ROLLBACKS=1 ROLLBACKS_UNPROVEN=4)"
grep -q 'excluded from the numerator' <<<"$R" \
  && ok_t "unattributable reverts are reported beside the rate, not silently dropped" \
  || bad_t "hidden exclusions" "a rate that hides what it excluded is a coverage claim it never earned: $R"
grep -q '"value": "1.0%"' <<<"$R" \
  && ok_t "unattributable reverts stay OUT of the numerator" || bad_t "inflated numerator" "$R"

# --- Case 6: the shell-layer query. DIVE-1914's finding was that a guard written
#     at the renderer layer passes while the defect sits in the shell's query
#     selection. Run the real SQL against a real store.
Q_SHIPS="$(sqlite3 "$DB2" "SELECT COUNT(*) FROM ship_events WHERE kind='ship' AND ts>=datetime('now','-7 days');")"
Q_RB="$(sqlite3 "$DB2" "SELECT COUNT(*) FROM ship_events WHERE kind='rollback' AND self=1 AND ts>=datetime('now','-7 days');")"
Q_RBU="$(sqlite3 "$DB2" "SELECT COUNT(*) FROM ship_events WHERE kind='rollback' AND self=0 AND ts>=datetime('now','-7 days');")"
[[ "$Q_SHIPS|$Q_RB|$Q_RBU" == "2|1|1" ]] \
  && ok_t "the shipped queries read 2 ships / 1 attributable / 1 unattributable off a real store" \
  || bad_t "query drift" "got $Q_SHIPS|$Q_RB|$Q_RBU want 2|1|1"
for q in "kind='ship' AND ts>=datetime" "kind='rollback' AND self=1" "kind='rollback' AND self=0"; do
  grep -qF "$q" src/cmd_proof.sh \
    && ok_t "cmd_proof.sh carries the query fragment: $q" \
    || bad_t "missing query fragment" "$q"
done

# --- Case 7: END TO END, and the assertion that shipped-then-caught this change.
#     The first cut of the shell block was spliced INTO the middle of the
#     `VAR=... \` continuation chain that hands the renderer its environment,
#     which severed it: python ran with no DIGEST_FILE and the whole verb died on
#     a traceback. All 29 assertions above stayed green through that, because
#     each one exercises a layer (SQL, writer, walker, renderer) and none of them
#     runs the VERB. DIVE-1914's finding, turned on this ticket: a guard that
#     cannot see the layer the bug lives in does not help however many assertions
#     it carries. Two guards, one structural and one end-to-end.
CHAIN="$(awk '/^  DIGEST_FILE="\$work\/digest.json"/{f=1} f{print} f&&/python3 <<.SCOREPY.$/{exit}' src/cmd_proof.sh)"
BAD_CHAIN="$(grep -vcE '^[[:space:]]*[A-Z_]+=|python3 <<' <<<"$CHAIN")"
[[ -n "$CHAIN" && "$BAD_CHAIN" == "0" ]] \
  && ok_t "the renderer's env chain is unbroken — every continued line is an assignment" \
  || bad_t "non-assignment spliced into the renderer's env continuation chain" \
           "a comment or statement there severs it and python3 runs with no DIGEST_FILE: $(grep -vE '^[[:space:]]*[A-Z_]+=|python3 <<' <<<"$CHAIN" | head -3)"

if [[ -x ./5dive ]]; then
  E2E="$(timeout 180 ./5dive proof scorecard 2>&1)"; E2E_RC=$?
  grep -q 'Traceback' <<<"$E2E" \
    && bad_t "the verb raised a traceback" "$(grep -A3 Traceback <<<"$E2E" | head -5)" \
    || ok_t "\`proof scorecard\` runs to completion without a traceback"
  grep -q 'autonomous rollback rate' <<<"$E2E" \
    && ok_t "the autonomous rollback rate row actually renders in the real verb" \
    || bad_t "row absent from live output" "rc=$E2E_RC; $(tail -5 <<<"$E2E")"
else
  echo "skip - ./5dive not built (run bash build.sh); the end-to-end arm did NOT run"
fi

echo "-----"
echo "rollback_rate_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
exit $?
