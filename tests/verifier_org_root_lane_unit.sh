#!/usr/bin/env bash
# TIER: core — ~4s measured 2026-09-06 (DIVE-3995). One scratch board, one
# registry fixture, no root, no network.
#
# DIVE-3995. lodar, 2026-09-06: "Olivia shouldn't be verifier. she is our ceo"
# … "maybe just marketing verification for olivia. idk how olivia can verify
# code." The org root — the CEO seat — was reachable as a GENERAL code-grading
# fallback in _task_default_verifier.
#
# THE RUNG THE ROW WAS FILED AGAINST IS NOT THE RUNG THAT PICKED HER, and that
# is the single most important thing this file pins. The chain is
#   qa -> proj_lead -> coordinator -> reports_to -> org_root -> deputy
# and the row was filed against `org_root` (rung 5). On the measured chart the
# root is reached at rung 3: nothing carries role='coordinator' or a
# " coordinator" marker, so _task_resolve_coordinator falls through to its
# documented "lone chart root" fallback and returns the CEO two rungs early.
# `reports_to` is a THIRD door for everyone who reports to the root directly.
# A fix that deleted or guarded rung 5 alone would have read as correct and
# changed NOTHING — C1 below is the arm that would have stayed green while the
# board kept routing code to the CEO, so it is a control, not decoration.
#
# WHAT IT ASSERTS
#   C1  CONTROL: the coordinator rung really does resolve to the org root on a
#       chart with no coordinator marker — i.e. the mechanism is rung 3
#   A1  an engineering row with a reachable QA seat picks the QA seat
#   A2  a maker who reports DIRECTLY to the root still does not get the root
#       (the reports_to door), even though that rung names it
#   A3  NEGATIVE CONTROL: an org with NO QA seat still gets the root, and does
#       NOT fall through to EMPTY/verifyUnavailable — the customer-org case the
#       deferral must never break
#   A4  a content/GTM row DOES get the root — that is the grading set the CEO
#       seat is being given, not a leak
#   A5  the content-lane test is TRANSITIVE (a seat two levels under marketing)
#   B1  a QA seat that is asleep does NOT hand the code row to the root (the
#       state iteration 1 asserted as intended and ops rejected)
#   B2  ...and when the rest of the chain is asleep too the picker ends EMPTY
#       (verifyUnavailable), never at the root
#   B3  the QA seat being the MAKER does not hand the row to the root either
#   B4  nor does the QA seat being EXCLUDED
#   B5  ...while a CONTENT row with the same asleep QA seat still gets the root
#       agent-writable) and does not hang the picker
#   A8  the picker NEVER returns the assignee, on every arm above
#
# EVERY ARM ASSERTS ON ROLE SHAPE, NEVER ON A SEAT NAME. Fixture names only:
# hardcoding a real seat is red only on that seat.
# Run: bash tests/verifier_org_root_lane_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/verifier-orgroot.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
reroster() { _TASK_ROSTER=""; _TASK_ROSTER_STATE=""; }

# Every seat here is wakeable EXCEPT `sleepyqa`, which is registered and never
# woken — the measured shape A6 needs.
mk_registry() {
  cat > "$STATE_DIR/agents.json" <<'JSON'
{"agents":{
  "ceo":     {"type":"claude","heartbeat":{"enabled":true}},
  "cto":     {"type":"claude","heartbeat":{"enabled":true}},
  "sre":     {"type":"claude","heartbeat":{"enabled":true}},
  "coder":   {"type":"claude","heartbeat":{"enabled":true}},
  "grader":  {"type":"claude","heartbeat":{"enabled":true}},
  "cmo":     {"type":"claude","heartbeat":{"enabled":true}},
  "writer":  {"type":"claude","heartbeat":{"enabled":true}},
  "artist":  {"type":"claude","heartbeat":{"enabled":true}},
  "sleepyqa":{"type":"claude"}
}}
JSON
  reroster
}
mk_registry

org_seed() {  # <name> [--role=x] [--title=y] [--reports-to=z]
  local n="$1"; shift
  db "INSERT OR IGNORE INTO agents_org (name) VALUES ($(sqlq "$n"));"
  for a in "$@"; do case "$a" in
    --role=*)       db "UPDATE agents_org SET role=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
    --title=*)      db "UPDATE agents_org SET title=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
    --reports-to=*) db "UPDATE agents_org SET reports_to=$(sqlq "${a#*=}") WHERE name=$(sqlq "$n");" ;;
  esac; done
  return 0
}

# ---- the chart, shaped like the measured one --------------------------------
# ceo (root, no manager) <- cto <- sre <- {coder, grader}
#                        <- cmo <- {writer, artist}
# Nothing carries role='coordinator' or a " coordinator" marker — deliberately,
# because that absence IS the live chart's shape and what makes C1 true.
# Seed managers BEFORE their reports: agents_org.reports_to is a real foreign
# key, so a manager named before it exists is an unenforced write, not a fixture.
build_chart() {
  db "DELETE FROM agents_org;"
  org_seed ceo    --role="AI CEO — conducts the fleet (advisory)" --title="Ceo · CEO"
  org_seed cto    --role="engineering + infra"       --title="Cto · CTO"       --reports-to=ceo
  org_seed cmo    --role="growth — ads, organic"     --title="Cmo · CMO"       --reports-to=ceo
  org_seed sre    --role="DevOps / SRE"                                        --reports-to=cto
  org_seed coder  --role="Lead Engineer (backend)"                             --reports-to=sre
  org_seed grader --role="Verifier / QA"                                       --reports-to=sre
  org_seed writer --role="research + voice-of-customer" --title="Head of Community" --reports-to=cmo
  org_seed artist --role="brand + meme/ad creative"  --title="Art Director"    --reports-to=cmo
}
build_chart

# ---- C1: THE MECHANISM CONTROL ----------------------------------------------
# The coordinator rung (3) resolves to the org root on this chart. If this ever
# goes red the mechanism moved and the rest of this file is testing a ghost.
coord=$(_task_resolve_coordinator)
root=$(_task_resolve_org_root)
if [[ -n "$root" && "$coord" == "$root" ]]; then
  ok_t "C1 CONTROL: with no coordinator marker, the COORDINATOR rung resolves to the org root (rung 3, not rung 5 — the filed rung was the wrong one)"
else
  bad_t "C1 CONTROL: coordinator rung no longer resolves to the root" "coordinator='${coord:-<empty>}' root='${root:-<empty>}'"
fi

# ---- A1: an engineering row picks the QA seat -------------------------------
got=$(_task_default_verifier coder "" 2>/dev/null)
[[ "$got" == "grader" ]] \
  && ok_t "A1: an engineering row with a reachable QA seat picks the QA seat, not the root" \
  || bad_t "A1: engineering row did not route to QA" "picked '${got:-<empty>}' (want the QA seat; root='$root')"

# ---- A2: the reports_to door onto the root ----------------------------------
# `cto` reports DIRECTLY to the root, so rung 4 names it explicitly. The
# deferral is keyed on the NAME, so this must still not be the root.
got=$(_task_default_verifier cto "" 2>/dev/null)
if [[ -n "$got" && "$got" != "$root" ]]; then
  ok_t "A2: a maker who reports DIRECTLY to the root is still not graded by the root (the reports_to door is covered)"
else
  bad_t "A2: reports_to door still lands on the root" "picked '${got:-<empty>}' (root='$root')"
fi

# ---- A3: NEGATIVE CONTROL — an org with NO QA seat --------------------------
# The customer-org case. Drop the QA seat entirely; the root must come BACK, and
# the picker must not fall through to EMPTY (verifyUnavailable).
db "DELETE FROM agents_org WHERE name='grader';"
got=$(_task_default_verifier coder "" 2>/dev/null)
if [[ "$got" == "$root" ]]; then
  ok_t "A3 NEGATIVE CONTROL: with NO QA seat in the org the root is still the grader — the deferral did not strip the rail off a one-lead org"
else
  bad_t "A3 NEGATIVE CONTROL: root no longer reachable without a QA seat" "picked '${got:-<empty>}' (want root='$root'; EMPTY would mean verifyUnavailable)"
fi
build_chart

# ---- A4: the content lane KEEPS the root ------------------------------------
got=$(_task_default_verifier cmo "" 2>/dev/null)
[[ "$got" == "$root" ]] \
  && ok_t "A4: a content/GTM row DOES route to the root — marketing verification is the set the CEO seat is given" \
  || bad_t "A4: content row lost the root" "picked '${got:-<empty>}' (want root='$root')"

# ---- A5: the lane test is transitive ----------------------------------------
# `artist` is two levels under the root and one under the marketing seat; its
# OWN role also matches, so use `writer`, whose match must come from cmo.
db "UPDATE agents_org SET role='research assistant', title='Writer' WHERE name='writer';"
if _task_verify_content_lane writer; then
  ok_t "A5: the content-lane test is TRANSITIVE — a seat whose own role says nothing inherits the lane from its manager"
else
  bad_t "A5: lane test is not transitive" "writer reports to the marketing seat and did not read as content lane"
fi
got=$(_task_default_verifier writer "" 2>/dev/null)
[[ "$got" == "$root" ]] \
  && ok_t "A5b: and that transitive content row routes to the root" \
  || bad_t "A5b: transitive content row lost the root" "picked '${got:-<empty>}' (want root='$root')"
build_chart

# A5c: the engineering lane is NOT content — the discriminator actually
# discriminates, rather than everything reading as content (which would make A1
# green for the wrong reason).
_task_verify_content_lane coder \
  && bad_t "A5c: the lane test says an engineering seat is content" "coder read as content lane — A1/A4 cannot both be meaningful" \
  || ok_t "A5c: an engineering seat does NOT read as the content lane (the discriminator discriminates)"

# ---- B1..B5: THE STATES WHERE THE ROOT ACTUALLY GETS A CODE ROW -------------
# These are the arms iteration 1 did not have, and their absence is what ops
# rejected: neutering the deferral alone left that suite at 12/12 green, because
# every arm it did have was decided at the QA rung, which behaves identically
# with and without the change. Each arm below reaches the root's rung with the
# QA rung declining, which is the only way the CEO seat ever sees a code row —
# and each one is RED against unmodified origin/main routing.sh.

# ---- B1: the QA seat is registered but never woken --------------------------
db "DELETE FROM agents_org WHERE name='grader';"
org_seed sleepyqa --role="Verifier / QA" --reports-to=sre
_task_doctor_lane_wakeable sleepyqa; rc_sleepy=$?
[[ "$rc_sleepy" == "1" ]] \
  && ok_t "B1 CONTROL: the fixture really does make the QA seat unwakeable (rc 1)" \
  || bad_t "B1 CONTROL: fixture wakeability" "sleepyqa rc=$rc_sleepy (want 1)"
got=$(_task_default_verifier coder "" 2>/dev/null)
if [[ -n "$got" && "$got" != "$root" && "$got" != coder ]]; then
  ok_t "B1: with the QA seat ASLEEP an engineering row still does not land on the root — it takes a live grader further down the chain ('$got')"
else
  bad_t "B1: an asleep QA seat handed the code row to the root" "picked '${got:-<empty>}' (root='$root'; the chart conflating 'no QA seat' with 'the QA seat is asleep' is the rejected shape)"
fi

# ---- B2: ...and the chain below it is asleep too -> EMPTY, not the root ------
# The org NAMED a QA rail and cannot reach any of it. `verifyUnavailable` is the
# designed outcome here; the root is not a consolation prize. The manager and
# the deputy rung (which resolves to cto on this chart) are put to sleep too, so
# the chain genuinely runs out — otherwise this arm grades the deputy rung, not
# the root's absence from the tail.
cat > "$STATE_DIR/agents.json" <<'JSON'
{"agents":{
  "ceo":     {"type":"claude","heartbeat":{"enabled":true}},
  "coder":   {"type":"claude","heartbeat":{"enabled":true}},
  "cmo":     {"type":"claude","heartbeat":{"enabled":true}},
  "writer":  {"type":"claude","heartbeat":{"enabled":true}},
  "artist":  {"type":"claude","heartbeat":{"enabled":true}},
  "cto":     {"type":"claude"},
  "sre":     {"type":"claude"},
  "sleepyqa":{"type":"claude"}
}}
JSON
reroster
got=$(_task_default_verifier coder "" 2>/dev/null)
if [[ -z "$got" ]]; then
  ok_t "B2: a named-but-unreachable QA rail ends at EMPTY (verifyUnavailable), not at the root — the honest label, not a code row on the CEO seat"
else
  bad_t "B2: the picker fell back to a grader instead of verifyUnavailable" "picked '$got' (root='$root'; want EMPTY)"
fi
mk_registry
build_chart

# ---- B3: the QA seat IS the maker -------------------------------------------
# _task_resolve_qa excludes the maker by SQL, so a row filed by the only QA seat
# reaches the root's rung with no QA candidate at all.
got=$(_task_default_verifier grader "" 2>/dev/null)
if [[ -n "$got" && "$got" != "$root" && "$got" != grader ]]; then
  ok_t "B3: a row made BY the QA seat is not graded by the root either ('$got')"
else
  bad_t "B3: the QA seat's own row landed on the root" "picked '${got:-<empty>}' (root='$root')"
fi

# ---- B4: the QA seat is EXCLUDED --------------------------------------------
# The documented data lever must not read as "then give it to the CEO".
FIVE_VERIFY_EXCLUDE=grader
got=$(_task_default_verifier coder "" 2>/dev/null)
unset FIVE_VERIFY_EXCLUDE
if [[ -n "$got" && "$got" != "$root" && "$got" != coder ]]; then
  ok_t "B4: excluding the QA seat does not promote the root onto code rows ('$got')"
else
  bad_t "B4: excluding the QA seat handed the row to the root" "picked '${got:-<empty>}' (root='$root')"
fi

# ---- B5: the widened arming did NOT steal the content lane ------------------
db "DELETE FROM agents_org WHERE name='grader';"
org_seed sleepyqa --role="Verifier / QA" --reports-to=sre
got=$(_task_default_verifier writer "" 2>/dev/null)
[[ "$got" == "$root" ]] \
  && ok_t "B5: a CONTENT row with the same asleep QA seat still routes to the root — the deferral widened without touching the lane the CEO seat is given" \
  || bad_t "B5: content lane lost the root once the arming widened" "picked '${got:-<empty>}' (want root='$root')"
build_chart

# ---- A7: a reports_to cycle terminates --------------------------------------
# The chart is agent-writable, so a loop is reachable. Assert on TERMINATION,
# under a timeout, because the failure mode this guards is a hang — an arm that
# just checks the return value would sit here forever instead of going red.
db "UPDATE agents_org SET reports_to='coder' WHERE name='sre';"
db "UPDATE agents_org SET reports_to='sre'   WHERE name='coder';"
timeout 10 bash -c '
  cd "$1"; SRC=src
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
           lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
           lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
    source "$SRC/$f"; done
  STATE_DIR="$2"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
  _task_verify_content_lane coder; exit 0
' _ "$PWD" "$STATE_DIR" >/dev/null 2>&1
if [[ $? -ne 124 ]]; then
  ok_t "A7: a reports_to CYCLE terminates the lane walk instead of hanging the picker"
else
  bad_t "A7: the lane walk hangs on a reports_to cycle" "timed out at 10s"
fi
build_chart

# ---- A8: the picker never returns the assignee ------------------------------
self=0
for who in coder cto cmo writer artist grader sre; do
  g=$(_task_default_verifier "$who" "" 2>/dev/null)
  [[ -n "$g" && "$g" == "$who" ]] && { self=1; bad_t "A8: picker returned the assignee" "assignee='$who' picked itself"; }
done
(( self == 0 )) && ok_t "A8: across every seat on the chart the picker NEVER returns the assignee (no maker==grader skew reintroduced)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
