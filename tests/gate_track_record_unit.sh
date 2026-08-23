#!/usr/bin/env bash
# TIER: nightly — sibling of gate_precedent_unit.sh (same shape, same isolation).
# DIVE-3694 (ROADMAP #22) isolated unit harness for PROMOTION ON A MEASURED
# PER-FILER TRACK RECORD: a tier-1 `decision` gate from a seat whose own recent
# recommendations have been returned at or above threshold applies itself and
# pings nobody; a reversal demotes the seat on the very next gate.
#
# The six arms mirror the row's acceptance list one-for-one:
#   1  above-threshold seat clears, provenance auto:record, record cited
#   2  below-threshold / too-few / NO record at all still pings
#   3  a reversal demotes — the NEXT gate from that seat pings again
#   4  approval / secret / manual / tier-2 / --needs / floored are untouched
#   5  the rate is STARTS-WITH: `merge — ALREADY DONE` counts as a MATCH
#   6  the kill switch restores pre-DIVE-3694 routing
# Isolation matches the sibling harnesses: source src/ libs against a throwaway
# STATE_DIR; the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_track_record_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-track-record-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }

tasks_db_init
NOTIFIED=""
task_need_notify() { NOTIFIED="${NOTIFIED} ${1:-}"; }
audit_log() { :; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','$2');"; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

# Seed one ALREADY-ANSWERED tier-1 decision gate onto the seat's record, <age>
# days old, answered <ans>. Ordering inside the window is by need_answered_at, so
# a smaller <age> is MORE RECENT — that is what the streak test reads.
seed_hist() { # <ident> <filer> <recommend> <ans> <age-days>
  seed_task "$1" "$2"
  db "UPDATE tasks SET need_type='decision', tier=1, gate_filed_by=$(sqlq "$2"),
        recommend=$(sqlq "$3"), need_answer=$(sqlq "$4"),
        need_asked_at=datetime('now','-$5 day'),
        need_answered_at=datetime('now','-$5 day'),
        need_answered_by='lead:main', status='todo' WHERE ident='$1';"
}
# N concordant gates for a seat, ages descending from <start> days.
seed_clean() { # <seat> <n> <start-age> <ident-base>
  local i; for ((i=0;i<$2;i++)); do seed_hist "$4-1$i" "$1" merge merge $(( $3 - i )); done
}

# ===================== ARM 1: a promoted seat clears ======================
seed_clean alpha 12 40 TR-A
eq_t "record: alpha counts 12"             "$(_gate_record_stats alpha | cut -d' ' -f2)" "12"
eq_t "record: alpha 12/12 concordant"      "$(_gate_record_stats alpha | cut -d' ' -f1)" "12"
eq_t "record: alpha streak clean"          "$(_gate_record_stats alpha | cut -d' ' -f3)" "1"
if _gate_record_promoted alpha; then ok_t "record: alpha is promoted"; else bad_t "record: alpha is promoted" "not promoted"; fi

seed_task TR-9001 alpha
NOTIFIED=""
( cmd_task_need TR-9001 --type=decision --from=alpha --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A1: promoted seat auto-cleared"      "$(field TR-9001 need_answered_by)" "auto:record"
eq_t "A1: the recommendation was applied"  "$(field TR-9001 need_answer)"      "raise"
eq_t "A1: row unblocked"                   "$(field TR-9001 status)"           "todo"
eq_t "A1: nobody was pinged"               "${NOTIFIED// /}"                    ""
eq_t "A1: provenance is NOT human"         "$(db "SELECT CASE WHEN need_answered_by LIKE 'human:%' THEN 'human' ELSE 'not-human' END FROM tasks WHERE ident='TR-9001';")" "not-human"

# The record must be legible to the seat itself (row scope item 4).
LINE="$(_gate_record_line alpha)"
case "$LINE" in *PROMOTED*12/12*) ok_t "A1: track-record line states rate and count" ;;
  *) bad_t "A1: track-record line states rate and count" "$LINE" ;; esac
case "$LINE" in *Revoked*) ok_t "A1: track-record line names what revokes it" ;;
  *) bad_t "A1: track-record line names what revokes it" "$LINE" ;; esac

# An auto:record answer must NEVER feed the record that produced it.
eq_t "A1: auto:record excluded from own window" "$(_gate_record_stats alpha | cut -d' ' -f2)" "12"

# ============ ARM 2: below threshold / too few / NO record pings ==========
# 2a — enough gates, rate under the bar (8/12 = 66%).
seed_clean bravo 8 40 TR-B
seed_hist TR-B-x0 bravo merge hold 32; seed_hist TR-B-x1 bravo merge hold 31
seed_hist TR-B-x2 bravo merge hold 30; seed_hist TR-B-x3 bravo merge hold 29
seed_task TR-9002 bravo
( cmd_task_need TR-9002 --type=decision --from=bravo --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A2a: under-rate seat still pings"    "$(field TR-9002 need_answered_at)" "∅"
eq_t "A2a: under-rate seat stays blocked"  "$(field TR-9002 status)"           "blocked"

# 2b — a perfect rate over too FEW gates is not a record.
seed_clean charlie 5 40 TR-C
seed_task TR-9003 charlie
( cmd_task_need TR-9003 --type=decision --from=charlie --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A2b: 5/5 is too few to promote"      "$(field TR-9003 need_answered_at)" "∅"

# 2c — ABSENCE OF A RECORD IS NEVER A GOOD RECORD. A brand-new seat pings.
seed_task TR-9004 delta
( cmd_task_need TR-9004 --type=decision --from=delta --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A2c: a new seat starts un-promoted"  "$(field TR-9004 need_answered_at)" "∅"
eq_t "A2c: new seat stats are 0 0 0"       "$(_gate_record_stats delta)"        "0 0 0"

# ================ ARM 3: a reversal demotes on the NEXT gate ==============
# echo is promoted on 12 clean gates, then answered AGAINST once, most recently.
seed_clean echo7 12 40 TR-E
if _gate_record_promoted echo7; then ok_t "A3: echo7 promoted before the reversal"; else bad_t "A3: echo7 promoted before the reversal" "not promoted"; fi
seed_hist TR-E-rev echo7 merge "hold — not this cut" 1
eq_t "A3: rate still over the bar after one reversal" \
     "$(( 100 * $(_gate_record_stats echo7 | cut -d' ' -f1) / $(_gate_record_stats echo7 | cut -d' ' -f2) >= 85 ? 1 : 0 ))" "1"
eq_t "A3: but the streak is broken"        "$(_gate_record_stats echo7 | cut -d' ' -f3)" "0"
if _gate_record_promoted echo7; then bad_t "A3: reversal demotes the seat" "still promoted"; else ok_t "A3: reversal demotes the seat"; fi
seed_task TR-9005 echo7
( cmd_task_need TR-9005 --type=decision --from=echo7 --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A3: the NEXT gate from that seat pings again" "$(field TR-9005 need_answered_at)" "∅"
eq_t "A3: and stays blocked"                        "$(field TR-9005 status)"           "blocked"
case "$(_gate_record_line echo7)" in *reversal*) ok_t "A3: the line explains the demotion" ;;
  *) bad_t "A3: the line explains the demotion" "$(_gate_record_line echo7)" ;; esac

# ======== ARM 4: the refusals — one test per human-by-type + tier 2 =======
# alpha is promoted throughout this arm; every row below must still be untouched.
seed_task TR-9010 alpha
( cmd_task_need TR-9010 --type=approval --from=alpha --tier=1 --ask="merge the branch" --recommend="merge" ) >/dev/null 2>&1 || true
eq_t "A4: approval never auto-cleared"     "$(field TR-9010 need_answered_at)" "∅"
seed_task TR-9011 alpha
( cmd_task_need TR-9011 --type=secret --from=alpha --ask="provide the token" --recommend="provide" ) >/dev/null 2>&1 || true
eq_t "A4: secret never auto-cleared"       "$(field TR-9011 need_answered_at)" "∅"
seed_task TR-9012 alpha
( cmd_task_need TR-9012 --type=manual --from=alpha --ask="tap the console button" --recommend="tap" ) >/dev/null 2>&1 || true
eq_t "A4: manual never auto-cleared"       "$(field TR-9012 need_answered_at)" "∅"
seed_task TR-9013 alpha
( cmd_task_need TR-9013 --type=decision --from=alpha --tier=2 --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
# Nothing is applied. NOTE WHY, because the reason is not this ticket's guard:
# DIVE-2848's rubber-stamp cap REFUSES a tier-2 decision that carries a
# --recommend outright, so the gate is never filed at all (tier stays NULL). The
# assertion that matters either way is that no answer was written.
eq_t "A4: explicit --tier=2 never auto-cleared" "$(field TR-9013 need_answered_at)" "∅"
eq_t "A4: explicit --tier=2 was refused at filing, not auto-applied" "$(field TR-9013 tier)" "∅"
# The T2 SUBJECT floor (money) — the filer cannot lower it and neither can a record.
seed_task TR-9014 alpha
( cmd_task_need TR-9014 --type=decision --from=alpha --ask="approve spend of \$4,000 on the new box" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A4: a floored (money) decision never auto-cleared" "$(field TR-9014 need_answered_at)" "∅"
eq_t "A4: and that gate really WAS filed at tier 2 (a live negative, not a refusal)" "$(field TR-9014 tier)" "2"
eq_t "A4: and it is still blocked on a human"  "$(field TR-9014 status)" "blocked"
# A DECLARED capability outranks any record (DIVE-2241).
seed_task TR-9015 alpha
( cmd_task_need TR-9015 --type=decision --from=alpha --needs=human_tap --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A4: --needs=<capability> never auto-cleared" "$(field TR-9015 need_answered_at)" "∅"
# A recommendation that is not on the filer's own menu falls through to the ping.
seed_task TR-9016 alpha
( cmd_task_need TR-9016 --type=decision --from=alpha --ask="pick the retry budget" --options="raise|hold" --recommend="delete everything" ) >/dev/null 2>&1 || true
eq_t "A4: off-menu recommendation is not applied" "$(field TR-9016 need_answered_at)" "∅"
# No recommendation at all: there is nothing to apply.
seed_task TR-9017 alpha
( cmd_task_need TR-9017 --type=decision --from=alpha --ask="pick a wholly novel retry budget" --options="raise|hold" ) >/dev/null 2>&1 || true
eq_t "A4: no recommendation, no auto-clear" "$(field TR-9017 need_answered_at)" "∅"

# ============ ARM 5: STARTS-WITH, not equality — the pinned case ==========
# `merge — ALREADY DONE` is a MATCH. Equality would score all 12 as reversals and
# read 0%, and the threshold would have been set against a wrong number.
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do
  seed_hist "TR-F-$i" foxtrot merge "merge — ALREADY DONE" $(( 40 - i ))
done
eq_t "A5: rec+commentary counts as a MATCH" "$(_gate_record_stats foxtrot | cut -d' ' -f1)" "12"
if _gate_record_promoted foxtrot; then ok_t "A5: starts-with promotes the seat"; else bad_t "A5: starts-with promotes the seat" "not promoted"; fi
# The negative control on the same discriminator: a DIFFERENT answer is not a match.
seed_hist TR-F-neg golf merge "hold — merge later" 3
eq_t "A5: an answer that merely CONTAINS the rec is not a match" "$(_gate_record_stats golf | cut -d' ' -f1)" "0"

# ==================== ARM 6: the kill switch =============================
_task_pref_set track_record off
seed_task TR-9018 alpha
( cmd_task_need TR-9018 --type=decision --from=alpha --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A6: pref off restores the ping"      "$(field TR-9018 need_answered_at)" "∅"
eq_t "A6: pref off leaves the row blocked" "$(field TR-9018 status)"           "blocked"
_task_pref_set track_record on
seed_task TR-9019 alpha
( cmd_task_need TR-9019 --type=decision --from=alpha --ask="pick the retry budget" --options="raise|hold" --recommend="raise" ) >/dev/null 2>&1 || true
eq_t "A6: pref on clears again"            "$(field TR-9019 need_answered_by)"  "auto:record"

echo "-------------------------------------"
echo "gate_track_record_unit: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
