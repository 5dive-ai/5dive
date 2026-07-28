#!/usr/bin/env bash
# DIVE-2224 isolated unit harness: PART 1, a gate classifier must never read the ASK
# and the TITLE as ONE string; PART 2 (lodar answered A, 2026-07-28), the floor's
# SUBJECT is the ASK, with a fail-closed fallback to the title when the ask states
# nothing of its own.
#
# THE BUG. Every text-driven gate classifier was fed "${ask} ${title}". The ask is
# what is being asked for (written at gate-filing time); the title is what the ticket
# is about (written at ticket-creation time). They are different statements, and
# several of these regexes match over a BOUNDED DISTANCE — the T2 floor's
# `drop[^.]{0,20}table`, DIVE-1481's 20-character co-reference window. Joining two
# subjects with a space lets those windows reach ACROSS the seam and FABRICATE a
# classification present in NEITHER field.
#
# Measured on origin/main before the fix, with the shipped floor regex:
#   ask   "confirm we can drop"                 -> MISS
#   title "table stakes: the onboarding rewrite"-> MISS
#   join  (the two with a space)                -> HIT  (drop[^.]{0,20}table)
# Neither text is about a database.
#
# BOTH DIRECTIONS ARE GRADED, and the second is the dangerous one:
#   UP   — a phantom floor hit ESCALATES a routine gate to hard-human (annoying:
#          the human taps something they should never have seen).
#   DOWN — a phantom internal-ops co-reference STRIPS a destructive term out of the
#          residual, the re-tested floor then misses, and the gate is DOWNGRADED to
#          lead-clearable. That REMOVES a human from a destructive ask. An ask that
#          names no target is exactly where a human matters most.
#
# WHAT MUST NOT CHANGE (non-vacuity): evaluating per field preserves "either field
# can trip it" — the DIVE-1957 title axis, load-bearing in both directions. Every
# phantom case below is therefore paired with a SINGLE-FIELD control that must still
# fire, so this suite cannot pass by disabling a classifier. The title-only floor
# case is asserted explicitly: it is exactly what a later axis change (the gated
# Part 2 of DIVE-2224) would flip, and it should flip loudly, not silently.
#
# NOT COVERED HERE, stated rather than implied: _gate_lead_standing_eligible takes
# the same per-field treatment in this change but is not driven by this harness —
# it needs an authenticated actor equal to the sealed standing lead. Its own suite
# is tests/gate_lead_standing_unit.sh.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR — the live tasks.db is never touched.
# Run: bash tests/gate_seam_concatenation_unit.sh (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` — redirecting the source's stderr also swallows
# the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-seam-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; HUMAN_PINGED=0; }

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# The TITLE is half the classifier input, so it is a first-class variable here.
seed()    { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1',$(sqlq "$2"),'todo','main');"; }
tierof()  { db "SELECT tier FROM tasks WHERE ident='$1';"; }
routedof(){ db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }

# hard-human: tier 2, no reviewer, the paired human was pinged.
assert_human() { # <ident> <label>
  local id="$1" lbl="$2" t r; t=$(tierof "$id"); r=$(routedof "$id")
  [[ "$t" == "2" && -z "$r" && "$HUMAN_PINGED" == "1" ]] \
    && ok_t "$lbl" || bad_t "$lbl" "tier='$t' routed='$r' human=$HUMAN_PINGED"
}
# not floored: tier stays 1. NOTE the human ping is NOT part of this predicate --
# with gate_builder_routing at its default (off) an ordinary tier-1 decision gate
# still notifies the paired human, so requiring human=0 here fails the CONTROL case
# and would have graded the wrong property. The floor's effect is the TIER.
assert_not_floored() { # <ident> <label>
  local id="$1" lbl="$2" t; t=$(tierof "$id")
  [[ "$t" == "1" ]] \
    && ok_t "$lbl" || bad_t "$lbl" "tier='$t' human=$HUMAN_PINGED routed='$(routedof "$id")'"
}
# lead-clearable: tier 1 routed to the lead.
assert_lead_routed() { # <ident> <label>
  local id="$1" lbl="$2" t r; t=$(tierof "$id"); r=$(routedof "$id")
  [[ "$t" == "1" && "$r" == "main" && "$HUMAN_PINGED" == "0" ]] \
    && ok_t "$lbl" || bad_t "$lbl" "tier='$t' routed='$r' human=$HUMAN_PINGED"
}

# =============================================================================
# UP DIRECTION — the T2 floor must not be fabricated across the seam
# =============================================================================

# (1) THE MEASURED PHANTOM. `drop` ends the ask, `table` opens the title; the floor's
#     drop[^.]{0,20}table window closes over the join. Neither field is about a
#     database and no rewording of either can prevent it, because the defect is in
#     the join.
route_reset; seed DIVE-801 'table stakes: the onboarding rewrite'
cmd_task_need DIVE-801 --type=decision --from=dev \
  --ask="confirm we can drop" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_not_floored DIVE-801 "seam: 'drop' in ask + 'table' in title does NOT fabricate a floor hit"

# (2) NON-VACUITY, ask axis: a real floor term in the ASK still forces hard-human.
route_reset; seed DIVE-802 'onboarding rewrite'
cmd_task_need DIVE-802 --type=decision --from=dev \
  --ask="approve the refund to the customer" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_human DIVE-802 "non-vacuity: a floor term in the ASK still floors to hard-human"

# (3) PART 2 / ANSWER A: a floor term in the TITLE, with a SUBSTANTIVE ask that names
#     nothing of the sort, no longer reaches the human -- it routes to the lead. This
#     assertion is the deliberate flip of pre-2224 behaviour; it is spelled out so the
#     axis change is loud rather than silent.
route_reset; seed DIVE-803 'the stale credential rotation write-up'
cmd_task_need DIVE-803 --type=decision --from=dev \
  --ask="which of these two wordings should we use?" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_lead_routed DIVE-803 "answer A: a floor term in the TITLE + a substantive ask routes to the LEAD, not the human"

# (4) CONTROL: neither field, no seam — an ordinary gate is untouched.
route_reset; seed DIVE-804 'onboarding rewrite'
cmd_task_need DIVE-804 --type=decision --from=dev \
  --ask="which of these two wordings should we use?" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_not_floored DIVE-804 "control: a gate with no floor term in either field stays tier 1"

# =============================================================================
# DOWN DIRECTION — the dangerous one. A fabricated internal-ops CO-REFERENCE
# strips a destructive term out of the residual and removes the human.
# =============================================================================

# (5) THE PHANTOM CO-REFERENCE. 'purge' is destructive and sits at the END of the ask;
#     'task board' is an internal object and OPENS the title. DIVE-1481's 20-char
#     window closes over the join, strips 'purge' from the residual, the re-tested
#     floor misses, and the gate is downgraded to lead-clearable. The ask names NO
#     object at all — it is the case where a human matters most.
route_reset; seed DIVE-805 'task board tidy-up for DIVE-2224'
cmd_task_need DIVE-805 --type=decision --from=dev \
  --ask="approve the purge" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_human DIVE-805 "seam: a co-reference manufactured ACROSS the join does NOT strip the floor (stays human)"

# (6) NON-VACUITY: the genuine internal-ops case — verb and object BOTH in the ask —
#     must still be lead-clearable. Without this, (5) could pass by breaking the
#     DIVE-1480 carve-out outright.
route_reset; seed DIVE-806 'onboarding rewrite'
cmd_task_need DIVE-806 --type=decision --from=dev \
  --ask="approve the purge of the task board backlog rows" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_lead_routed DIVE-806 "non-vacuity: a REAL internal-ops ask (verb+object in one field) still downgrades to the lead"

# (7) NON-VACUITY, title axis for the carve-out: verb and object both in the TITLE.
route_reset; seed DIVE-807 'purge the task board backlog rows left by the wipe'
cmd_task_need DIVE-807 --type=decision --from=dev \
  --ask="please confirm" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_lead_routed DIVE-807 "non-vacuity: a REAL internal-ops TITLE (verb+object in one field) still downgrades"

# =============================================================================
# PART 2 — the ASK is the subject, and the EMPTY-ASK FALLBACK is load-bearing
# =============================================================================

# (8) INSTRUMENT SANITY before trusting any of the cases below. olivia's first run of
#     the 177-gate measurement returned "177 of 177 match the ask" because she had
#     extracted an EMPTY regex, and an empty pattern matches everything. Assert the
#     predicates discriminate at all, in both directions, before believing them.
_gate_tier2_floor_hit "delete the row" \
  && ok_t "instrument: the floor MATCHES an obviously-destructive ask" \
  || bad_t "instrument: the floor MATCHES an obviously-destructive ask" "floor did not fire"
_gate_tier2_floor_hit "push the reviewed branch to origin" \
  && bad_t "instrument: the floor does NOT match a routine push ask" "floor fired on a routine ask" \
  || ok_t "instrument: the floor does NOT match a routine push ask"
_gate_ask_substantive "push the reviewed branch for DIVE-2216 to origin so CI can grade it" \
  && ok_t "instrument: a real ask is substantive" \
  || bad_t "instrument: a real ask is substantive" "classed as empty"
_gate_ask_substantive "approve this" \
  && bad_t "instrument: 'approve this' is NOT substantive" "classed as substantive" \
  || ok_t "instrument: 'approve this' is NOT substantive"

# (9) THE FALLBACK, and the case lodar is actually trusting. A lazy filing where the
#     TITLE is the only statement of the request must still reach the human. If this
#     case ever passes with the fallback removed, the fallback is decorative --
#     graded by mutation, not by reading.
route_reset; seed DIVE-808 'delete all customer data'
cmd_task_need DIVE-808 --type=decision --from=dev \
  --ask="approve this" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_human DIVE-808 "FALLBACK: ask 'approve this' + destructive TITLE still reaches the human (fail-closed)"

# (10) the same fallback with an ask that is pure politeness.
route_reset; seed DIVE-809 'wipe the production database and start over'
cmd_task_need DIVE-809 --type=decision --from=dev \
  --ask="please confirm" --options="A|B" --recommend="A" >/dev/null 2>&1
assert_human DIVE-809 "FALLBACK: a politeness-only ask + destructive TITLE still reaches the human"

# (11) THE NAMED VICTIM. DIVE-2216's real title contains 'deleted', so before answer A
#      EVERY push gate on that ticket escalated to the human and no rewording of the
#      ask could change it -- the rail was inert on that ticket by construction.
route_reset; seed DIVE-810 'agent ask harvests NOTHING from a grok seat: the reply fence requires each marker alone on a line, grok puts them inline, and the fallback was deleted - the seat reads as a silent abstain'
cmd_task_need DIVE-810 --type=decision --from=dev \
  --ask="push the reviewed branch for this ticket to origin so CI can grade it" \
  --options="A|B" --recommend="A" >/dev/null 2>&1
assert_lead_routed DIVE-810 "answer A: a routine push ask on DIVE-2216's own title now routes to the LEAD"

# (12) an APPROVAL gate takes the same axis as a decision gate -- the filing floor and
#      the approval/manual routing arm must not disagree about which field decided.
route_reset; seed DIVE-811 'the stale credential rotation write-up'
cmd_task_need DIVE-811 --type=approval --from=dev \
  --ask="which of these two wordings should we use?" --recommend="A" >/dev/null 2>&1
assert_lead_routed DIVE-811 "answer A applies to an APPROVAL gate too (filing floor and routing arm agree)"

printf '\nDIVE-2224 gate seam: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
