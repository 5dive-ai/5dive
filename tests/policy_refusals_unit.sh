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

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# DIVE-2229: pinned-commit baselines, fail-closed. Same no-2>/dev/null rule.
. "$(dirname "${BASH_SOURCE[0]}")/lib/pinned_baseline.sh" \
  || printf 'pinned baseline helper: UNRESOLVED (tests/lib/pinned_baseline.sh not reachable)\n' >&2
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
# Do not merely CHECK for the baseline — try to obtain it. A shallow CI checkout
# legitimately lacks it, and the oldest version of this code turned that into a
# silent `ok`.
#
# DIVE-2229 — but "obtain origin/main" was still the wrong target. `origin/main`
# and its `FETCH_HEAD` fallback both name the CURRENT tip, so once this
# instrumentation merged the comparison read the post-instrumentation file and
# asked whether it matched itself. The question this arm exists to answer is
# "what did these sites do BEFORE they were instrumented", and only a commit can
# answer that. e142832 is main immediately before da303e9 (DIVE-1922, PR #156)
# introduced policy_refuse at all, so it is the last tree in which every one of
# these sites still called `fail` directly — checked non-vacuous: it carries
# fail "$E_AUTH_REQUIRED" (7), fail "$E_CONFLICT" (12) and fail "$E_USAGE" (73).
PRE_INSTRUMENT_REF="e14283209d022c16034f4a4679d0a46463ddd8f3"   # before DIVE-1922 (PR #156)
if pinned_blob "$PRE_INSTRUMENT_REF" src/cmd_task.sh "$TMP/orig_task.sh"; then
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
  # Every code still in use must be one the pre-instrumentation tree actually
  # used at a refusal.
  #
  # NON-VACUITY FIRST: the loop below is a series of "is this code present in the
  # baseline file" greps, and an EMPTY baseline file answers no to all of them —
  # which reds, so that direction is safe — but a baseline that simply contains
  # no `fail "$E_..."` at all would make a green here mean nothing. Establish the
  # denominator before reading the verdict.
  base_fails="$(grep -cF 'fail "$E_' "$TMP/orig_task.sh" || true)"
  [[ "${base_fails:-0}" -gt 0 ]] \
    && ok_t "baseline ${PRE_INSTRUMENT_REF}:src/cmd_task.sh carries $base_fails direct fail sites — the subset check below has a denominator" \
    || bad_t "baseline carries NO direct fail sites" "${PRE_INSTRUMENT_REF}:src/cmd_task.sh has no \`fail \"\$E_…\"\` at all, so 'every code existed at a refusal there' cannot be answered — the pin is wrong or the file moved"
  unknown=""
  for c in $(grep -oE 'policy_refuse "\$E_[A-Z_]+"' src/cmd_task.sh | grep -oE 'E_[A-Z_]+' | sort -u); do
    grep -qF "fail \"\$${c}\"" "$TMP/orig_task.sh" || unknown="$unknown $c"
  done
  [[ -z "$unknown" ]] \
    && ok_t "every exit code used by an instrumented site existed at a refusal at ${PRE_INSTRUMENT_REF} (pre-instrumentation)" \
    || bad_t "invented exit code" "$unknown"
else
  # NOT ok_t, and NOT skip_t. This comparison is the only thing standing between
  # "telemetry was added" and "telemetry silently changed three exit codes",
  # which is a defect this ticket already shipped once. Counting a skip as a pass
  # is how a suite reports green while its load-bearing assertion never ran.
  bad_t "the behaviour-preservation comparison did NOT run" \
        "$(pinned_unavailable_msg "$PRE_INSTRUMENT_REF")"
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
