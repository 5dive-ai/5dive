#!/usr/bin/env bash
# DIVE-4585 unit harness for _hb_quota_snapshot_sweep — THE SCHEDULER for the
# account-usage snapshot.
#
# The snapshot itself was already covered (tests/quota_wall_health_surfaces_unit.sh)
# and so were its readers (tests/pace_the_week_unit.sh). What was never covered,
# and what this row exists for, is that anything WRITES it on a schedule: its one
# writer was a human typing `sudo 5dive account usage`, so every consumer's 600s
# fence expired it permanently. "A source with no scheduled publisher is not a
# source" — community/wiki/a-source-with-no-scheduled-publisher-is-not-a-source.md.
#
# So every arm here is about the FIRING decision and about the WIRING, not about
# the contents of the snapshot:
#   - the cadence gate is proved by a second call in the same window making no
#     further publish (a gate that let everything through would still pass a
#     "did it publish at all" arm);
#   - the cadence is proved to be strictly INSIDE the consumer fence, which is
#     the one arithmetic claim the whole repair rests on;
#   - a FAILING publish is proved to be counted, never swallowed, and a missing
#     publisher is proved to be NAMED — silence there reads exactly like "not
#     due", which is the defect's own shape;
#   - the wiring is asserted against the live sources, because extraction grades
#     the function and never its call site (DIVE-4578's second finding: an arm
#     that lifts a block out cannot see the staging line pointed elsewhere);
#   - the two spellings of the one fence are proved to move TOGETHER.
# Run: bash tests/heartbeat_quota_snapshot_publisher_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-qsnap-unit.XXXXXX)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# --- Extract the sweep from the module ---------------------------------------
# Extraction is ASSERTED, never assumed: a renamed or moved function must fail
# this harness loudly instead of driving an empty string and going green.
SWEEP_SRC=$(awk '/^_hb_quota_snapshot_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
if [ -z "$SWEEP_SRC" ]; then
  echo "  FAIL — could not extract _hb_quota_snapshot_sweep from $SRC/cmd_heartbeat.sh"
  echo "PASS=0 FAIL=1"; exit 1
fi
grep -q '^_HB_QUOTA_SNAPSHOT_EVERY_SEC=' "$SRC/cmd_heartbeat.sh" \
  && ok "the cadence constant _HB_QUOTA_SNAPSHOT_EVERY_SEC is defined in the module" \
  || bad "_HB_QUOTA_SNAPSHOT_EVERY_SEC is not defined in the module"

# `drive <now> <env...>` — run one sweep in a fresh subshell against $TMP as
# STATE_DIR, with account_usage_publish stubbed to append a line per call.
# Echoes: <RAN> <SKIPPED> <FAILED> <invocations>
drive() {
  local now="$1"; shift
  ( set +u
    export STATE_DIR="$TMP"
    _HB_QUOTA_SNAPSHOT_EVERY_SEC=120
    _hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
    account_usage_publish() { printf 'publish\n' >>"$TMP/calls"; return "${PUBLISH_RC:-0}"; }
    eval "$SWEEP_SRC"
    _hb_quota_snapshot_sweep "$now"
    printf '%s %s %s %s\n' "${_HB_QSNAP_RAN:-x}" "${_HB_QSNAP_SKIPPED:-x}" "${_HB_QSNAP_FAILED:-x}" \
      "$(wc -l <"$TMP/calls" 2>/dev/null || echo 0)"
  )
}
reset() { : >"$TMP/calls"; : >"$TMP/log"; rm -f "$TMP/quota-snapshot.stamp"; }

echo "== firing decision =="
reset
check "a cold box publishes on the first tick" "$(drive 1000)" "1 0 0 1"
check "the stamp records the pass" "$(cat "$TMP/quota-snapshot.stamp")" "1000"

# The cadence gate. A gate that let everything through would still have passed
# the arm above, so the proof is a SECOND call inside the window publishing
# nothing further.
check "a second tick 60s later does NOT republish (cadence gate)" "$(drive 1060)" "0 1 0 1"
check "a tick 119s later still does not republish" "$(drive 1119)" "0 1 0 1"
check "the tick at exactly the cadence republishes" "$(drive 1120)" "1 0 0 2"

reset
PUBLISH_RC=1 drive 2000 >/dev/null
check "a FAILING publish is counted, not swallowed" \
  "$( ( set +u; export STATE_DIR="$TMP"; _HB_QUOTA_SNAPSHOT_EVERY_SEC=120
       _hb_log() { :; }; account_usage_publish() { return 1; }
       eval "$SWEEP_SRC"; rm -f "$TMP/quota-snapshot.stamp"
       _hb_quota_snapshot_sweep 3000
       printf '%s %s %s' "$_HB_QSNAP_RAN" "$_HB_QSNAP_SKIPPED" "$_HB_QSNAP_FAILED" ) )" "0 0 1"
check "a failed pass still stamps (a wedged publisher is not re-entered every tick)" \
  "$(cat "$TMP/quota-snapshot.stamp")" "3000"

reset
check "the off switch publishes ZERO times, it does not merely read a flag" \
  "$(QUOTA_SNAPSHOT_PUBLISH=off drive 4000)" "0 0 0 0"

reset
check "a stamp from the FUTURE does not wedge the publisher" \
  "$(printf '99999999\n' >"$TMP/quota-snapshot.stamp"; drive 5000)" "1 0 0 1"

# The packaging defect. Silence here is indistinguishable from "not due", which
# is the exact shape of the defect the sweep exists to end — so it must be loud.
reset
PKG=$( ( set +u; export STATE_DIR="$TMP"; _HB_QUOTA_SNAPSHOT_EVERY_SEC=120
         _hb_log() { printf '%s\n' "$*" >>"$TMP/log"; }
         eval "$SWEEP_SRC"
         _hb_quota_snapshot_sweep 6000
         printf '%s %s' "$_HB_QSNAP_FAILED" "$(wc -l <"$TMP/calls" 2>/dev/null || echo 0)" ) )
check "an absent account_usage_publish is a counted FAILURE, not a quiet skip" "$PKG" "1 0"
grep -q 'PACKAGING DEFECT' "$TMP/log" \
  && ok "and it is NAMED in the log (a silent one reads exactly like 'not due')" \
  || bad "the missing publisher was not named in the log"

echo "== the cadence must be inside the consumer fence =="
# The one arithmetic claim the whole repair rests on: a publisher that runs no
# more often than the fence expires the source it publishes.
CAD=$(grep -oE '^_HB_QUOTA_SNAPSHOT_EVERY_SEC="\$\{_HB_QUOTA_SNAPSHOT_EVERY_SEC:-([0-9]+)\}"' "$SRC/cmd_heartbeat.sh" | grep -oE '[0-9]+\}"$' | tr -d '}"')
FENCE=$(grep -oE '^QUOTA_SNAPSHOT_MAX_AGE="\$\{QUOTA_SNAPSHOT_MAX_AGE:-([0-9]+)\}"' "$SRC/lib/quota_wall.sh" | grep -oE '[0-9]+\}"$' | tr -d '}"')
if [ -n "$CAD" ] && [ -n "$FENCE" ] && [ "$CAD" -lt "$FENCE" ]; then
  ok "the publish cadence (${CAD}s) is strictly inside the consumer fence (${FENCE}s)"
else
  bad "cadence/fence unreadable or cadence >= fence (cadence='${CAD}', fence='${FENCE}')"
fi
if [ -n "$CAD" ] && [ -n "$FENCE" ] && [ $(( CAD * 2 )) -le "$FENCE" ]; then
  ok "and it survives a missed tick with room to spare (2x cadence <= fence)"
else
  bad "a single missed pass would expire the source (2x${CAD} > ${FENCE})"
fi

echo "== ONE fence, two spellings, proved to move together =="
# DIVE-4585's second item. Two names for one predicate agree until an operator
# moves one, and the disagreement is silent.
NLINES=$(grep -cE '^_GRADER_READING_MAX_AGE=' "$SRC/task/grader_pool.sh")
check "grader_pool.sh defines the fence exactly once" "$NLINES" "1"
ALIAS=$( ( set +u; QUOTA_SNAPSHOT_MAX_AGE=999
           eval "$(grep -E '^_GRADER_READING_MAX_AGE=' "$SRC/task/grader_pool.sh")"
           printf '%s' "$_GRADER_READING_MAX_AGE" ) )
check "moving QUOTA_SNAPSHOT_MAX_AGE moves the pacing floor's fence too" "$ALIAS" "999"
DEFLT=$( ( set +u; unset QUOTA_SNAPSHOT_MAX_AGE
           eval "$(grep -E '^_GRADER_READING_MAX_AGE=' "$SRC/task/grader_pool.sh")"
           printf '%s' "$_GRADER_READING_MAX_AGE" ) )
check "with no quota_wall.sh in the process it still falls back to the fence default" "$DEFLT" "600"
OVERRIDE=$( ( set +u; QUOTA_SNAPSHOT_MAX_AGE=999; _GRADER_READING_MAX_AGE=42
              eval "$(grep -E '^_GRADER_READING_MAX_AGE=' "$SRC/task/grader_pool.sh")"
              printf '%s' "$_GRADER_READING_MAX_AGE" ) )
check "an explicit harness override of the old name still wins" "$OVERRIDE" "42"
grep -qE 'QUOTA_SNAPSHOT_MAX_AGE="\$\{QUOTA_SNAPSHOT_MAX_AGE:-600\}"' "$SRC/cmd_digest.sh" \
  && ok "the digest passes the canonical name through to its python block" \
  || bad "the digest no longer passes QUOTA_SNAPSHOT_MAX_AGE through — it may have grown a second name"

echo "== wiring (extraction grades the function, never its call site) =="
# DIVE-4578's second finding, applied to this row's own diff.
grep -q '_hb_quota_snapshot_sweep "\$now"' "$SRC/cmd_heartbeat.sh" \
  && ok "cmd_heartbeat_tick actually CALLS the sweep" \
  || bad "nothing calls _hb_quota_snapshot_sweep — the scheduler is not scheduled"
TICK_LN=$(grep -n '^cmd_heartbeat_tick() {' "$SRC/cmd_heartbeat.sh" | cut -d: -f1)
CALL_LN=$(awk -v s="$TICK_LN" 'NR>s && /_hb_quota_snapshot_sweep "\$now"/ {print NR; exit}' "$SRC/cmd_heartbeat.sh")
PACE_LN=$(awk -v s="$TICK_LN" 'NR>s && /_HB_PACE_USAGE="" _HB_PACE_CMD=/ {print NR; exit}' "$SRC/cmd_heartbeat.sh")
WAKE_LN=$(awk -v s="$TICK_LN" 'NR>s && /_hb_materialize_recurring "\$now"/ {print NR; exit}' "$SRC/cmd_heartbeat.sh")
if [ -n "$CALL_LN" ] && [ -n "$PACE_LN" ] && [ "$CALL_LN" -lt "$PACE_LN" ] && [ "$CALL_LN" -lt "${WAKE_LN:-999999}" ]; then
  ok "and calls it BEFORE this tick reads any account's headroom (line $CALL_LN < $PACE_LN)"
else
  bad "the publish happens after the tick's meter read — this tick paces on the stale snapshot (call=$CALL_LN pace=$PACE_LN materialize=$WAKE_LN)"
fi
grep -q '^account_usage_publish() {' "$SRC/cmd_account.sh" \
  && ok "account_usage_publish exists in cmd_account.sh" \
  || bad "account_usage_publish is gone — the sweep has nothing to call"
awk '/^account_usage_publish\(\) \{/,/^\}/' "$SRC/cmd_account.sh" | grep -q 'quota_snapshot_publish' \
  && ok "and it reaches quota_snapshot_publish (it is a publisher, not a reader)" \
  || bad "account_usage_publish never calls quota_snapshot_publish"
awk '/^account_usage_publish\(\) \{/,/^\}/' "$SRC/cmd_account.sh" | grep -q 'account_usage_rows' \
  && ok "and it builds its rows with the SAME builder the table prints" \
  || bad "account_usage_publish does not call account_usage_rows — a second row-builder has appeared"
awk '/^cmd_account_usage\(\) \{/,/^\}/' "$SRC/cmd_account.sh" | grep -q 'account_usage_rows' \
  && ok "the hand-run path still uses the extracted builder (not a left-behind copy)" \
  || bad "cmd_account_usage no longer calls account_usage_rows"
awk '/^cmd_account_usage\(\) \{/,/^\}/' "$SRC/cmd_account.sh" | grep -q 'quota_snapshot_publish' \
  && ok "and the hand-run still publishes (the immediate-refresh path is not regressed)" \
  || bad "cmd_account_usage stopped publishing"

echo "== the publisher publishes (behavioural, through the real quota_wall.sh) =="
BEH=$( ( set +u
         export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
         . "$SRC/lib/quota_wall.sh"
         account_usage_rows() { printf '%s' '[{"name":"acct","agents":["a"],"usage":{"asOf":123}}]'; }
         eval "$(awk '/^account_usage_publish\(\) \{/,/^\}/' "$SRC/cmd_account.sh")"
         account_usage_publish
         quota_snapshot_read | jq -r '.accounts[0].name' ) )
check "a published snapshot is readable back by quota_snapshot_read" "$BEH" "acct"
EMPTY=$( ( set +u
           export STATE_DIR="$TMP/state2"; mkdir -p "$STATE_DIR"
           . "$SRC/lib/quota_wall.sh"
           account_usage_rows() { printf '%s' '[]'; }
           eval "$(awk '/^account_usage_publish\(\) \{/,/^\}/' "$SRC/cmd_account.sh")"
           account_usage_publish; echo "rc=$?"
           [ -e "$QUOTA_SNAPSHOT_FILE" ] && echo "wrote" || echo "kept" ) )
check "a box with NO accounts keeps the previous snapshot rather than blanking it" "$EMPTY" "$(printf 'rc=0\nkept')"

# --- DIVE-4585 iteration 2: the cadence constant must not leak into another
# payload module ---------------------------------------------------------------
# `lazy_tokens` matches identifiers over the WHOLE file, comments included, so a
# single mention of _HB_QUOTA_SNAPSHOT_EVERY_SEC (a top-level global of
# cmd_heartbeat.sh) from any other payload module creates a __MODDEPS edge to
# cmd_heartbeat. grader_pool.sh is in every verb's closure, so that edge lands on
# `whoami` and reds the lazy-dispatch budget. Iteration 1 shipped exactly that.
echo "== the cadence constant does not leak into another payload module =="
LEAKS=$(grep -rl '_HB_QUOTA_SNAPSHOT_EVERY_SEC' "$SRC" 2>/dev/null \
        | grep -v '/cmd_heartbeat\.sh$' | sort | tr '\n' ' ')
check "no payload module other than cmd_heartbeat.sh names the cadence constant" "$LEAKS" ""

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
