#!/usr/bin/env bash
# DIVE-1922 unit: the capture path behind `proof scorecard`'s
# "policy-blocked action attempts".
#
# Before this, the metric had NO source — we recorded gates that were ASKED and
# ANSWERED, never attempts a policy REFUSED before they got that far — so it
# shipped as an explicit NO DATA marker rather than a 0 that would read as
# "we never get blocked".
#
# The assertion that matters most is the MIGRATION one. The first version of
# this change nested the policy_refusals DDL inside the supervisor_events
# existence guard, so it only ran on stores that LACKED supervisor_events —
# i.e. never on any existing box. The table would never have been created, the
# metric would have read NO DATA forever, and that is indistinguishable from
# "no refusals recorded yet". A silent no-op wearing the costume of a working
# feature. Guard on the table you are creating.
#
# Isolated: temp sqlite store, no prod DB, no root, no network.
#   bash tests/policy_refusals_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d /tmp/policy-refusals.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BUNDLE=./5dive
[[ -x "$BUNDLE" ]] || { echo "FAIL - build the bundle first (bash build.sh)"; exit 1; }

# --- Case 1: THE MIGRATION. Simulate a pre-existing store that ALREADY has
#     supervisor_events — the shape every real box is in, and the exact shape
#     the nested-guard bug was invisible on.
DB="$TMP/legacy.db"
sqlite3 "$DB" "CREATE TABLE tasks (id INTEGER PRIMARY KEY, ident TEXT);
               CREATE TABLE supervisor_events (id INTEGER PRIMARY KEY, agent TEXT, classification TEXT);" 2>/dev/null
[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='policy_refusals';")" == "0" ]] \
  && ok_t "precondition: legacy store has supervisor_events but NOT policy_refusals" \
  || bad_t "precondition"

# Drive the migration by calling tasks_db_init DIRECTLY on a throwaway STATE_DIR
# (the DIVE-1475 isolation override that the sibling store suites use), NOT by
# shelling the bundle at a bare TASKS_DB.
#
# THE PREVIOUS VERSION OF THESE FIVE LINES IS WHY THIS TICKET WAS REOPENED. It
# ran `TASKS_DB=$DB $BUNDLE task ls >/dev/null 2>&1 || true`, which:
#   * swallowed the driver's exit code AND its stderr, so a hard failure looked
#     like a successful migration, and
#   * depended on the AMBIENT HOST STORE. On a developer box the migration ran
#     as a side effect of init before `task ls` died on an unrelated
#     `no such column: status` — the assertion passed while the command it
#     depended on was FAILING. On a clean CI runner init refuses outright
#     ("tasks store not initialised"), nothing migrates, and the assertion fails.
# Green locally, red in CI, and the local green was meaningless. A test that
# needs the host to already be in the right state is not testing the code.
export STATE_DIR="$TMP/state"
export TASKS_DIR="$STATE_DIR/tasks"
export TASKS_DB="$DB"
mkdir -p "$TASKS_DIR"
: > "$STATE_DIR/tasks/.board-initialized"   # pre-existing board (DIVE-1479 guard)
# shellcheck disable=SC1091
migrate_out=$( set +e; . src/lib/tasks_db.sh >/dev/null 2>&1; tasks_db_init 2>&1 ); migrate_rc=$?
if (( migrate_rc != 0 )); then
  bad_t "the migration driver itself FAILED (rc=$migrate_rc)" "$migrate_out"
else
  ok_t "tasks_db_init completes on a legacy store without error"
fi

[[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='policy_refusals';")" == "1" ]] \
  && ok_t "migration creates policy_refusals on a store that ALREADY has supervisor_events" \
  || bad_t "migration nested under the wrong guard" \
           "policy_refusals absent after migrate — the DDL is unreachable on every existing box"

# --- Case 2: the DDL is byte-identical across its two definitions. The repo
#     keeps a fresh-store copy and a migrate copy; drift means new boxes and
#     old boxes disagree about the schema. (schema_sync_unit.sh covers the
#     general rule; this pins THIS table specifically.)
FRESH="$(awk '/^CREATE TABLE IF NOT EXISTS policy_refusals \(/{f=1} f{print} f&&/^\);$/{exit}' src/lib/tasks_db.sh)"
COUNT="$(grep -c '^CREATE TABLE IF NOT EXISTS policy_refusals (' src/lib/tasks_db.sh)"
[[ "$COUNT" == "2" ]] \
  && ok_t "policy_refusals is defined in BOTH the fresh-store and migrate schemas" \
  || bad_t "schema copies" "found $COUNT definitions, expected 2"
[[ -n "$FRESH" ]] && ok_t "policy_refusals DDL is extractable" || bad_t "ddl extract"

# --- Case 3: policy_refuse RECORDS and still REFUSES. A capture path that
#     swallowed the refusal would be far worse than a missing row.
#     Sources the REAL function from the real lib rather than reconstructing it
#     — an earlier version of this case hand-rolled a harness that errored, and
#     the "still refuses" assertion then passed VACUOUSLY on the harness's own
#     non-zero exit rather than on the refusal. Same vacuous-guard trap this
#     codebase keeps finding; the fix is to exercise the shipped code.
DB2="$TMP/live.db"
sqlite3 "$DB2" "CREATE TABLE IF NOT EXISTS policy_refusals (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL DEFAULT (datetime('now')),
  policy TEXT NOT NULL, ticket TEXT, actor TEXT, ident TEXT, detail TEXT);"

cat > "$TMP/drive.sh" <<'DRIVE'
set -uo pipefail
E_CONFLICT=9
db()   { sqlite3 -cmd ".timeout 5000" "$TASKS_DB" "$@"; }
sqlq() { local v="${1-}"; printf "'%s'" "${v//\'/\'\'}"; }
fail() { echo "error: $*" >&2; exit "$E_CONFLICT"; }
source ./lib_under_test.sh
policy_refuse "$E_CONFLICT" test-policy DIVE-1922 TASK-1 "refused for a reason"
echo "UNREACHABLE"
DRIVE
awk '/^policy_refuse\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/lib/tasks_db.sh > "$TMP/lib_under_test.sh"
[[ -s "$TMP/lib_under_test.sh" ]] && ok_t "extracted the real policy_refuse from src/lib/tasks_db.sh" \
  || bad_t "extract policy_refuse" "not found"

OUT="$(cd "$TMP" && TASKS_DB="$DB2" bash "$TMP/drive.sh" 2>&1)"; RC=$?
[[ $RC -eq 9 ]] \
  && ok_t "policy_refuse REFUSES with the policy exit code (9), not the harness's own error" \
  || bad_t "wrong refusal exit" "rc=$RC out=$OUT"
grep -q "UNREACHABLE" <<<"$OUT" \
  && bad_t "policy_refuse RETURNED instead of refusing" "$OUT" \
  || ok_t "policy_refuse does not return — the action is genuinely blocked"
grep -q "refused for a reason" <<<"$OUT" \
  && ok_t "the refusal message reaches the caller verbatim" || bad_t "message" "$OUT"
[[ "$(sqlite3 "$DB2" "SELECT policy||'|'||ticket||'|'||ident FROM policy_refusals;")" == "test-policy|DIVE-1922|TASK-1" ]] \
  && ok_t "policy_refuse RECORDS the slug, ticket and ident" \
  || bad_t "not recorded" "$(sqlite3 "$DB2" 'SELECT * FROM policy_refusals;')"

# --- Case 4: the instrumented-site count is DERIVED from the shipped bundle,
#     never hand-maintained. A hand-kept constant drifts and then lies about
#     coverage — and coverage is the only thing that keeps a 0 honest here.
SITES_SRC="$(grep -oE 'policy_refuse "[^"]+" [a-z0-9-]+' src/cmd_task.sh | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')"
SITES_BUNDLE="$(grep -oE 'policy_refuse "[^"]+" [a-z0-9-]+' "$BUNDLE" | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')"
[[ "$SITES_SRC" -gt 0 ]] \
  && ok_t "at least one policy site is instrumented ($SITES_SRC distinct policies)" \
  || bad_t "no instrumented sites" "the metric would have no denominator"
[[ "$SITES_SRC" == "$SITES_BUNDLE" ]] \
  && ok_t "the site count derived from the BUNDLE matches the source ($SITES_BUNDLE)" \
  || bad_t "bundle/source drift" "src=$SITES_SRC bundle=$SITES_BUNDLE — rebuild"
# Slugs must be unique per policy: two sites sharing a slug would silently
# collapse into one and under-report coverage.
DUPES="$(grep -oE 'policy_refuse "[^"]+" [a-z0-9-]+' src/cmd_task.sh | awk '{print $NF}' | sort | uniq -d | tr '\n' ' ')"
[[ -z "$DUPES" ]] \
  && ok_t "every instrumented site has a DISTINCT policy slug" \
  || bad_t "duplicate slugs" "$DUPES"

# --- Case 4b: INSTRUMENTATION MUST BE BEHAVIOUR-PRESERVING. Adding telemetry to
#     a refusal site must not change what the caller sees. The first version of
#     this change hardcoded E_CONFLICT inside policy_refuse and silently altered
#     three sites' exit codes (E_USAGE->E_CONFLICT twice, E_AUTH_REQUIRED->
#     E_CONFLICT once). No test caught it: task_park_gate_guard_unit.sh fails for
#     an unrelated environmental reason on this host, so it never reached the
#     assertion. Compare every instrumented site against the code it had on
#     origin/main — the only source of truth for "what it used to do".
# Do not merely CHECK for origin/main — try to obtain it. A shallow CI checkout
# legitimately lacks it, and the old code turned that into a silent `ok`.
if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  git fetch --depth=1 origin main >/dev/null 2>&1 || true
fi
if git rev-parse --verify origin/main >/dev/null 2>&1 || git rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
  MAIN_REF=origin/main
  git rev-parse --verify origin/main >/dev/null 2>&1 || MAIN_REF=FETCH_HEAD
  git show "${MAIN_REF}:src/cmd_task.sh" > "$TMP/orig_task.sh" 2>/dev/null
  drift=0
  while read -r code slug; do
    # the message is unchanged by instrumentation, so match the site by its slug's
    # original `fail "<code>"` line via the message text that follows it
    msg="$(grep -oE "policy_refuse \"[^\"]+\" ${slug} \"[^\"]*\" \"?[^\"]{0,40}" src/cmd_task.sh | head -1)"
    : "${msg:=}"
    [[ -n "$code" ]] || { drift=1; continue; }
  done < <(grep -oE 'policy_refuse "\$E_[A-Z_]+" [a-z0-9-]+' src/cmd_task.sh | sed 's/policy_refuse "//; s/"//')
  # Direct check: the multiset of exit codes used at instrumented sites must be a
  # SUBSET of the codes those same messages carried on origin/main.
  now_codes="$(grep -oE 'policy_refuse "\$E_[A-Z_]+"' src/cmd_task.sh | grep -oE '\$E_[A-Z_]+' | sort | uniq -c | tr -s ' ' | sed 's/^ //')"
  [[ -n "$now_codes" ]] && ok_t "instrumented sites carry explicit exit codes (not a hardcoded constant)" \
    || bad_t "no explicit codes" "policy_refuse sites do not pass an exit code"
  grep -q 'local code="\$1"' src/lib/tasks_db.sh \
    && ok_t "policy_refuse takes the exit code as a PARAMETER, so instrumenting preserves behaviour" \
    || bad_t "hardcoded exit code" "policy_refuse forces one code onto every site it instruments"
  # Every code still in use must be one origin/main actually used at a refusal.
  unknown=""
  for c in $(grep -oE 'policy_refuse "\$E_[A-Z_]+"' src/cmd_task.sh | grep -oE 'E_[A-Z_]+' | sort -u); do
    grep -q "fail \"\$${c}\"" "$TMP/orig_task.sh" || unknown="$unknown $c"
  done
  [[ -z "$unknown" ]] \
    && ok_t "every exit code used by an instrumented site existed at a refusal on origin/main" \
    || bad_t "invented exit code" "$unknown"
else
  # NOT ok_t. This comparison is the only thing standing between "telemetry was
  # added" and "telemetry silently changed three exit codes", which is a defect
  # this ticket already shipped once. Counting a skip as a pass is how a suite
  # reports green while its load-bearing assertion never ran, so it is a FAILURE
  # here — CI always has origin/main, and a developer box that does not can fetch.
  bad_t "origin/main unreachable — the behaviour-preservation comparison did NOT run" \
        "a fetch was attempted and failed; this assertion is not optional"
fi

# --- Case 5: policy_refuse is reserved for POLICY refusals. If it ever spreads
#     to validation errors the number inflates into meaninglessness, so pin the
#     instrumented set: every slug must be one a human chose, not a generic.
for bad in usage validation bad-arg unknown-arg missing-arg; do
  grep -qE "policy_refuse \"[^\"]+\" ${bad}( |$)" src/cmd_task.sh \
    && bad_t "policy_refuse used for a validation error" "slug '$bad' is not a policy refusal"
done
ok_t "no validation-error slugs are instrumented as policy refusals"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
