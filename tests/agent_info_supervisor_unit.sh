#!/usr/bin/env bash
# DIVE-3274 isolated unit harness for _sup_info_status (cmd_supervisor.sh) — the
# pure half of the output overlay `agent info` prints, factored out of
# sup_info_for_agent so every branch is assertable with no store, no tick and no
# tmux (same factoring as _sup_classify / _sup_act_plan).
#
# The property under test is NOT "does it label a dark seat". It is: does this
# surface ever print a value that a dark seat and a working seat SHARE? That is
# the DIVE-3272 defect — six green liveness signals agreeing about a seat that
# closed nothing for four days — arriving on the drill-down command
# (community/wiki/every-signal-measured-liveness-none-measured-output.md). So
# the arms below deliberately include the three "nothing is wrong" shapes that
# must NOT collapse into each other: transacting, correctly-idle, and
# never-measured.
# Run: bash tests/agent_info_supervisor_unit.sh (no root, no network; §12 makes
# its own temp sqlite store, never the prod board).
#
# GRADED BY MUTATION, both sides of the argument list — the §12 arms exist
# because a pure-renderer harness cannot see the query that feeds it, which is
# the coverage hole quinn measured on THIS detector's own tests
# (community/wiki/a-detectors-tests-can-grade-the-branch-and-not-the-read.md).
# Reds, 2026-08-11, against 88 passing: newest-row ORDER BY reversed 5 ·
# open-rows narrowed to in_progress 1 · cause json path wrong 2 · per-agent
# scope dropped 6 · staleness bound removed 3 · tick tolerance removed 5 ·
# unmeasured folded into unknown 3. One SURVIVOR, reported not papered over:
# scoping the fleet-heartbeat read to agent='(fleet)' vs any event='heartbeat'
# row — the writer emits that event for no other agent, so the two queries are
# the same query today. An arm for it would grade the fixture, not the code.
# The ORDER BY arm was ADDED after the first draft survived that mutation at
# full green: one seeded row makes "newest" and "oldest" the same row.
set -uo pipefail

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh cmd_supervisor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

PASS=0; FAIL=0
t() {  # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"
  fi
}
tc() {  # <desc> <needle> <haystack>  — contains
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual:              $3"
  fi
}
tnc() {  # <desc> <needle> <haystack>  — does NOT contain
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual:                  $3"
  fi
}

NOW=1000000
# args: armed tick_epoch row_epoch now rec_class rec_cause rec_detail open days
s() { _sup_info_status "$@"; }
f() { jq -r "$1" <<<"$2"; }

echo "== threshold in use: ${_SUP_T_NO_OUTPUT_DAYS}d =="

# --- 1. the incident shape: open rows held, nothing closed in 4d -------------
DRY=$(s true $((NOW-60)) $((NOW-61)) $NOW no-output no-output "20 open row(s), nothing closed in 4d" 20 4)
t   "dry: output=dry"                 "dry"        "$(f .output "$DRY")"
t   "dry: transacting=false"           "false"      "$(f '.transacting|tostring' "$DRY")"
t   "dry: verdict=no-output"           "no-output"  "$(f .verdict "$DRY")"
tc  "dry: state note is not a bare liveness word" "NOT TRANSACTING" "$(f .stateNote "$DRY")"
tc  "dry: state note carries BOTH numbers (the pair is the detector)" \
    "20 open row(s), nothing closed in 4d" "$(f .stateNote "$DRY")"

# --- 2. the same drought with the TICK OFF — the measured half must still fire.
#     This is the whole reason no-output is recomputed here instead of read from
#     the trail: on an unarmed box the trail is empty, and an empty trail is
#     indistinguishable from an all-clear (DIVE-2306).
UNARMED_DRY=$(s false 0 0 $NOW "" "" "" 20 4)
t   "unarmed + dry: verdict still no-output"  "no-output" "$(f .verdict "$UNARMED_DRY")"
t   "unarmed + dry: classification is unobserved, NOT healthy" \
    "unobserved" "$(f .classification "$UNARMED_DRY")"
tc  "unarmed: says the tick is not armed"     "NOT ARMED" "$(f .line "$UNARMED_DRY")"
t   "unarmed: tickArmed=false in json"        "false"     "$(f '.tickArmed|tostring' "$UNARMED_DRY")"

# --- 3. quota-exhausted: the half this surface CANNOT measure ----------------
QUOTA=$(s true $((NOW-60)) $((NOW-61)) $NOW quota-exhausted quota-exhausted \
          "pane shows a model-capacity refusal: quota has been exhausted" 2 0)
t   "quota: verdict=quota-exhausted even though output reads ok" \
    "quota-exhausted" "$(f .verdict "$QUOTA")"
t   "quota: the measured half is reported honestly alongside it" "ok" "$(f .output "$QUOTA")"
tc  "quota: state note names the class"  "NOT TRANSACTING (quota-exhausted" "$(f .stateNote "$QUOTA")"
tc  "quota: detail is carried through"   "model-capacity refusal"          "$(f .stateNote "$QUOTA")"

# --- 4. a STALE quota row must not be quoted as current ----------------------
#     The row predates the newest tick, so that tick looked and wrote nothing =>
#     healthy. Inheriting the old class here would be the reverse defect: a
#     recovered seat pinned to a four-day-old alarm.
STALE=$(s true $NOW $((NOW-4000)) $NOW quota-exhausted quota-exhausted "old pane text" 2 0)
t   "stale row: classification collapses to healthy" "healthy" "$(f .classification "$STALE")"
t   "stale row: no verdict inherited"                "null"    "$(f '.verdict|tostring' "$STALE")"
t   "stale row: fromCurrentTick=false"               "false"   "$(f '.fromCurrentTick|tostring' "$STALE")"

# --- 5. the tick-tolerance boundary ------------------------------------------
#     Per-agent rows are written BEFORE the fleet heartbeat that closes the
#     tick, so a CURRENT row carries an earlier ts. Without the tolerance every
#     live classification would read stale and the surface would go quiet
#     exactly when it matters.
SAME=$(s true $NOW $((NOW-1)) $NOW quota-exhausted quota-exhausted "pane" 2 0)
t   "row 1s before the tick (same tick) is current" "true" "$(f '.fromCurrentTick|tostring' "$SAME")"
EDGE_IN=$(s true $NOW $((NOW-_SUP_INFO_TICK_TOL)) $NOW quota-exhausted quota-exhausted "pane" 2 0)
t   "row exactly at the tolerance is current"       "true" "$(f '.fromCurrentTick|tostring' "$EDGE_IN")"
EDGE_OUT=$(s true $NOW $((NOW-_SUP_INFO_TICK_TOL-1)) $NOW quota-exhausted quota-exhausted "pane" 2 0)
t   "one second past the tolerance is NOT current"  "false" "$(f '.fromCurrentTick|tostring' "$EDGE_OUT")"

# --- 6. the three healthy-ish shapes must stay DISTINGUISHABLE ---------------
#     If any two of these print the same string, the command has reproduced the
#     defect it exists to fix.
OK=$(s   true $((NOW-60)) $((NOW-4000)) $NOW healthy "" "" 5 0)
IDLE=$(s true $((NOW-60)) $((NOW-4000)) $NOW healthy "" "" 0 9)
NEW=$(s  true $((NOW-60)) 0             $NOW ""      "" "" 3 -1)
t   "busy seat: output=ok"        "ok"      "$(f .output "$OK")"
t   "empty queue: output=idle"    "idle"    "$(f .output "$IDLE")"
t   "never closed: output=unknown" "unknown" "$(f .output "$NEW")"
t   "never closed: transacting=null, never false" "null" "$(f '.transacting|tostring' "$NEW")"
t   "never closed: NO verdict — a new seat is not a dark one" "null" "$(f '.verdict|tostring' "$NEW")"
tc  "never closed: says WHY it cannot tell" "NEVER closed anything" "$(f .note "$NEW")"
t   "idle seat past the threshold is NOT dry (0 open rows)" "null" "$(f '.verdict|tostring' "$IDLE")"
# the pairwise-distinct property, stated as an assertion rather than left to a reader
for a in OK IDLE NEW DRY QUOTA; do
  for b in OK IDLE NEW DRY QUOTA; do
    [[ "$a" < "$b" ]] || continue
    t "state notes differ: $a vs $b" "differ" \
      "$( [[ "$(f .stateNote "${!a}")" != "$(f .stateNote "${!b}")" ]] && echo differ || echo SAME )"
  done
done

# --- 7. armed but no tick has ever completed ---------------------------------
FRESH_BOX=$(s true 0 0 $NOW "" "" "" 5 0)
t   "armed, never ticked: classification=unobserved" "unobserved" "$(f .classification "$FRESH_BOX")"
tc  "armed, never ticked: says so"  "no tick has completed" "$(f .line "$FRESH_BOX")"
tnc "armed, never ticked: never claims healthy" "healthy" "$(f .line "$FRESH_BOX")"

# --- 7b. an UNREADABLE store is a fourth value, not the benign third ---------
#     Found end-to-end, not by reading the code: with TASKS_DB pointed at a
#     missing path the counters fell back to 0-open/never-closed and printed
#     "no open rows, nothing ever closed" — a measurement that was never taken,
#     in the voice of one that was. Exactly the defect class this command exists
#     to stop, so it gets pinned here.
NOSTORE=$(s true 0 0 $NOW "" "" "" 0 -1 false)
t   "no store: output=unmeasured (not unknown, not idle)" "unmeasured" "$(f .output "$NOSTORE")"
t   "no store: storeReadable=false"        "false"       "$(f '.storeReadable|tostring' "$NOSTORE")"
t   "no store: transacting=null"           "null"        "$(f '.transacting|tostring' "$NOSTORE")"
tc  "no store: state note says UNMEASURED" "UNMEASURED"  "$(f .stateNote "$NOSTORE")"
tc  "no store: line says it is not an all-clear" "not an all-clear" "$(f .line "$NOSTORE")"
t   "no store: state note differs from the empty-queue reading" "differ" \
    "$( [[ "$(f .stateNote "$NOSTORE")" != "$(f .stateNote "$NEW")" ]] && echo differ || echo SAME )"
# and an unreadable store must not let a stale trail speak either
NOSTORE_ROW=$(s true $NOW $((NOW-1)) $NOW quota-exhausted quota-exhausted "pane" 9 9 false)
t   "no store: no classification is inherited" "unobserved" "$(f .classification "$NOSTORE_ROW")"
t   "no store: fromCurrentTick=false"          "false"      "$(f '.fromCurrentTick|tostring' "$NOSTORE_ROW")"

# --- 8. junk inputs degrade, never crash and never invent a clear -------------
JUNK=$(s "" "x" "y" "z" "" "" "" "n" "m")
t   "junk: still valid json"                 "0"          "$(jq -e . >/dev/null 2>&1 <<<"$JUNK"; echo $?)"
t   "junk: unarmed reading, not a clear"     "unobserved" "$(f .classification "$JUNK")"
t   "junk: output unknown"                   "unknown"    "$(f .output "$JUNK")"

# --- 9. the age renderer ------------------------------------------------------
t "ago 45s"    "45s" "$(_sup_info_ago 45)"
t "ago 12m"    "12m" "$(_sup_info_ago 720)"
t "ago 3h"     "3h"  "$(_sup_info_ago 10800)"
t "ago 4d"     "4d"  "$(_sup_info_ago 345600)"
t "ago unknown" "?"  "$(_sup_info_ago -1)"

# --- 10. THE NEGATIVE CASE, GRADED (main, at the DIVE-3274 push approval) -----
#     "A status line that learns to append a warning to everything is the same
#     defect wearing the other sign, and it is the more likely regression here."
#     So the healthy readings are asserted for what they must NOT contain, not
#     only for what they say.
for arm in OK IDLE; do
  v="${!arm}"
  t   "negative case ($arm): verdict is null"       "null" "$(f '.verdict|tostring' "$v")"
  tnc "negative case ($arm): no NOT TRANSACTING"    "NOT TRANSACTING" "$(f .stateNote "$v")"
  tnc "negative case ($arm): no warning glyph"      "⚠"                "$(f .stateNote "$v")"
  tnc "negative case ($arm): supervisor line names no class"  "quota"  "$(f .line "$v")"
  tnc "negative case ($arm): supervisor line is not an alarm" "no-output" "$(f .line "$v")"
done
t   "negative case: a healthy seat's supervisor line is exactly the class + tick age" \
    "healthy (tick 1m ago)" "$(f .line "$OK")"

# --- 11. A STALE TICK MUST NOT SPEAK FOR THE PRESENT ------------------------
#     Also main's #2: "If the newest event is older than the detector's own
#     window, say so rather than printing nothing." The observer stopping is not
#     the observed being healthy — the whole absence-reads-as-health shape.
STALE_TICK=$(s true $((NOW-_SUP_INFO_TICK_STALE-1)) 0 $NOW "" "" "" 5 0)
t   "stale tick, no rows: classification=unobserved, NOT healthy" \
    "unobserved" "$(f .classification "$STALE_TICK")"
tc  "stale tick: names the age of the last tick" "ago and nothing has refreshed this" \
    "$(f .line "$STALE_TICK")"
STALE_TICK_ROW=$(s true $((NOW-_SUP_INFO_TICK_STALE-1)) $((NOW-_SUP_INFO_TICK_STALE)) $NOW \
                   quota-exhausted quota-exhausted "old pane text" 5 0)
t   "stale tick + a recorded row: still unobserved, class not forwarded" \
    "unobserved" "$(f .classification "$STALE_TICK_ROW")"
tc  "stale tick: the stale row is still SHOWN, with its own age" "newest recorded row" \
    "$(f .line "$STALE_TICK_ROW")"
FRESH_TICK=$(s true $((NOW-_SUP_INFO_TICK_STALE+1)) 0 $NOW "" "" "" 5 0)
t   "one second inside the staleness bound: healthy is still derivable" \
    "healthy" "$(f .classification "$FRESH_TICK")"

# --- 12. POSITIVE CONTROL ON THE JOIN (main's #3) ----------------------------
#     "Asserting the query compiles is not asserting it matched." Everything
#     above grades the pure renderer with literal arguments — which is exactly
#     the blind spot quinn measured on this detector's own tests
#     ([[a-detectors-tests-can-grade-the-branch-and-not-the-read]]): the read is
#     invisible to a harness that hands the decision its numbers. So these arms
#     drive sup_info_for_agent over a REAL sqlite store and assert the rendering
#     CHANGES when a classification is seeded.
TMPD=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
export TASKS_DB="$TMPD/tasks.db"
_SUP_ENABLED_FLAG="$TMPD/supervisor.enabled"; touch "$_SUP_ENABLED_FLAG"
sqlite3 "$TASKS_DB" "
CREATE TABLE tasks (id INTEGER PRIMARY KEY, assignee TEXT, status TEXT, kind TEXT,
                    created_at TEXT, done_at TEXT);
CREATE TABLE supervisor_events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, agent TEXT,
                    event TEXT, classification TEXT, cause TEXT, prev_classification TEXT,
                    signals TEXT);
INSERT INTO supervisor_events (ts,agent,event,classification,signals)
  VALUES (datetime('now'),'(fleet)','heartbeat','healthy','{}');"

BEFORE=$(sup_info_for_agent seatx)
t   "join/before: a seat with no rows at all reads unknown, not dry" \
    "unknown" "$(f .output "$BEFORE")"
t   "join/before: no verdict" "null" "$(f '.verdict|tostring' "$BEFORE")"

# seed the OUTPUT half: rows held, last close well past the threshold
sqlite3 "$TASKS_DB" "
INSERT INTO tasks (assignee,status,kind,created_at,done_at) VALUES
 ('seatx','in_progress','standard',datetime('now'),NULL),
 ('seatx','todo','standard',datetime('now'),NULL),
 ('seatx','done','standard',datetime('now','-30 days'),datetime('now','-${_SUP_T_NO_OUTPUT_DAYS} days','-1 day'));"
AFTER=$(sup_info_for_agent seatx)
t   "join/after: the SQL actually matched — output flips to dry" "dry" "$(f .output "$AFTER")"
t   "join/after: verdict=no-output with no event row at all" "no-output" "$(f .verdict "$AFTER")"
t   "join/after: open rows counted through the real query" "2" "$(f '.openRows|tostring' "$AFTER")"
t   "join: the rendering CHANGED (not just the query compiled)" "changed" \
    "$( [[ "$(f .stateNote "$BEFORE")" != "$(f .stateNote "$AFTER")" ]] && echo changed || echo SAME )"

# a cancel is output too — done_at stamps both terminal states
sqlite3 "$TASKS_DB" "UPDATE tasks SET done_at=datetime('now') WHERE status='done';"
t   "join: a recent close clears the dry reading" "ok" "$(f .output "$(sup_info_for_agent seatx)")"

# seed the INHERITED half: an OLD row of a DIFFERENT class first, then the
# current one. Order matters to the arms below — with a single row seeded,
# "newest row" and "oldest row" are the same row and an ORDER BY mutation
# survives at full green. Measured: it did, on the first draft of this harness.
sqlite3 "$TASKS_DB" "
INSERT INTO supervisor_events (ts,agent,event,classification,cause,signals) VALUES
 (datetime('now','-2 days'),'seatx','observe','drift','goal-drift',
  json_object('detail','STALE ROW — an ORDER BY mutation surfaces this one'));
INSERT INTO supervisor_events (ts,agent,event,classification,cause,signals) VALUES
 (datetime('now'),'seatx','observe','quota-exhausted','quota-exhausted',
  json_object('detail','pane shows a model-capacity refusal: quota exhausted, resets 08-14 13:49 UTC'));
INSERT INTO supervisor_events (ts,agent,event,classification,signals)
  VALUES (datetime('now'),'(fleet)','heartbeat','degraded','{}');"
QROW=$(sup_info_for_agent seatx)
t   "join: a seeded classification reaches the surface" "quota-exhausted" "$(f .verdict "$QROW")"
t   "join: read through the real event query, not a literal" "quota-exhausted" \
    "$(f .classification "$QROW")"
# main's design note: the classification and the CAUSE are different facts.
tc  "join: the CAUSE string is carried, not just the class" "resets 08-14 13:49 UTC" \
    "$(f .detail "$QROW")"
tc  "join: and it reaches the line the reader sees" "resets 08-14 13:49 UTC" "$(f .line "$QROW")"
t   "join: output stays honestly ok — the two halves do not contaminate" "ok" "$(f .output "$QROW")"
tnc "join: the NEWEST row wins — the older class is not the one reported" \
    "STALE ROW" "$(f .detail "$QROW")"
t   "join: an older row of another class is not surfaced" "quota-exhausted" \
    "$(f .classification "$QROW")"

# an agent with no rows, on the same store, must NOT inherit seatx's alarm
OTHER=$(sup_info_for_agent seaty)
t   "join: per-agent scoping — a clean seat on the same store stays clean" \
    "null" "$(f '.verdict|tostring' "$OTHER")"
t   "join: clean seat reads healthy off the fleet heartbeat" "healthy" "$(f .classification "$OTHER")"

# and an unreadable store is still the fourth state, through the real I/O path
TASKS_DB="$TMPD/does-not-exist.db"
t   "join: unreadable store degrades to unmeasured through the I/O half" \
    "unmeasured" "$(f .output "$(sup_info_for_agent seatx)")"

echo "-- $PASS passed, $FAIL failed --"
(( FAIL == 0 ))
