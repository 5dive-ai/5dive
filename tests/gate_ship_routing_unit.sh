#!/usr/bin/env bash
# DIVE-1145 isolated unit harness for ship-gating gate ROUTING in cmd_task_need.
# Policy: a builder's (non-lead) DECISION gate routes to the org lead first
# (status stays blocked, need_answered_at NULL, human ping SUPPRESSED) instead of
# pinging the human — but ONLY when pref gate_builder_routing=on. A gate filed BY
# the lead, a tier-2-floored (true-human category) gate, or any non-decision gate
# falls through to the normal human path. Isolation mirrors the sibling gate
# harnesses: source src/ libs, throwaway STATE_DIR — the live tasks.db is never
# touched. Run: bash tests/gate_ship_routing_unit.sh (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-route-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Never actually DM the human or shell out to a peer in the harness; capture that
# the human path would have fired via a sentinel instead.
HUMAN_PINGED=0
task_need_notify() { HUMAN_PINGED=1; }
audit_log() { :; }
# The on-route path runs `command -v 5dive` then `( 5dive agent send … & )`.
# 5dive IS on PATH on every real host + CI, so WITHOUT a stub the suite fires a
# live "5dive agent send main" (the phantom cross-agent pings we saw). Define a
# `5dive` shell FUNCTION: it shadows the external binary, is inherited by the
# detached ( … & ) subshell, keeps `command -v 5dive` true so the route branch is
# still exercised, and records the send into a sentinel instead of hitting the
# network — ZERO live side-effects regardless of env. ROUTE_SENT counts sends.
# The send is dispatched detached — `( 5dive agent send … & )` — so a var set in
# the stub never propagates back to the parent. Record into a FILE the orphaned
# child can write, then read it back. route_reset truncates it per case;
# route_sent polls briefly (the detached job is async) and echoes the count.
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; }
route_sent()  { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; grep -c . "$ROUTE_FILE" 2>/dev/null || echo 0; }
route_last()  { tail -n1 "$ROUTE_FILE" 2>/dev/null; }

# Org chart: main is the lone root (coordinator); dev reports to main.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

seed() { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1','t','todo','main');"; }
statusof(){ db "SELECT status FROM tasks WHERE ident='$1';"; }
answered(){ db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }

# --- helper resolves the right reviewer -------------------------------------
[[ "$(_gate_route_reviewer dev)"  == "main" ]] && ok_t "reviewer(dev)=main (manager)" || bad_t "reviewer(dev)=main" "got '$(_gate_route_reviewer dev)'"
[[ -z "$(_gate_route_reviewer main)" ]]       && ok_t "reviewer(main)=empty (lead files → human)" || bad_t "reviewer(main) empty" "got '$(_gate_route_reviewer main)'"

# --- pref OFF: decision gate still pings the human (unchanged behavior) ------
seed DIVE-1; HUMAN_PINGED=0
cmd_task_need DIVE-1 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "pref off: decision pings human" || bad_t "pref off pings human" "HUMAN_PINGED=$HUMAN_PINGED"

_task_pref_set gate_builder_routing on

# --- pref ON: builder decision routes to lead, NO human ping ----------------
seed DIVE-2; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-2 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "route on: builder decision does NOT ping human" || bad_t "route suppresses human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(statusof DIVE-2)" == "blocked" && "$(answered DIVE-2)" == "open" ]] && ok_t "routed gate stays blocked+open for lead" || bad_t "routed gate blocked+open" "status=$(statusof DIVE-2) ans=$(answered DIVE-2)"
R2=$(route_sent); [[ "$R2" == "1" && "$(route_last)" == "main" ]] && ok_t "routed send hit lead (main), stubbed — no live network" || bad_t "routed send → main via stub" "sent=$R2 last='$(route_last)'"

# --- pref ON: gate filed BY the lead escalates to human ----------------------
seed DIVE-3; HUMAN_PINGED=0
cmd_task_need DIVE-3 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=main >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: lead's own decision goes to human" || bad_t "lead decision → human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- DIVE-1182: pref ON — builder APPROVAL (ship-gate) routes to lead ---------
# The DIVE-1145 gap: builder ship-gates are `approval`, so v1 left them human-only
# (pinged lodar). Now they route to the org lead like decision, persist
# routed_reviewer, and are clearable by that lead (below).
seed DIVE-4; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-4 --type=approval --ask="approve the prod push?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "route on: builder approval does NOT ping human (DIVE-1182)" || bad_t "approval routed not human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(statusof DIVE-4)" == "blocked" && "$(answered DIVE-4)" == "open" ]] && ok_t "routed approval stays blocked+open for lead" || bad_t "routed approval blocked+open" "status=$(statusof DIVE-4) ans=$(answered DIVE-4)"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-4';")" == "main" ]] && ok_t "routed approval persists routed_reviewer=main" || bad_t "routed_reviewer=main" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-4';")'"
R4=$(route_sent); [[ "$R4" == "1" && "$(route_last)" == "main" ]] && ok_t "routed approval send hit lead (main)" || bad_t "approval send → main" "sent=$R4 last='$(route_last)'"

# --- DIVE-1182: the designated lead can CLEAR a routed approval gate ----------
# cmd_task_answer's approval human-only floor grants agent-<routed_reviewer> an
# exception ONLY on a routed gate. We can't spoof `id -un`==agent-main in-harness,
# so assert the two decision inputs the exception keys on: type is approval/manual
# AND routed_reviewer is set. (uid match is exercised live; unit asserts the row.)
_rr=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-4';")
_rt=$(db "SELECT need_type FROM tasks WHERE ident='DIVE-4';")
[[ -n "$_rr" && ( "$_rt" == "approval" || "$_rt" == "manual" ) ]] && ok_t "lead-clear precondition holds (approval + routed_reviewer set)" || bad_t "lead-clear precondition" "rr='$_rr' rt='$_rt'"

# --- DIVE-1182: SECRET is NEVER routed (stays hard-human) ---------------------
# A legacy secret gate (out-of-band delivery, no drop target): --secret-key
# without --connector is a validation error (they must be given together), which
# would `exit` mid-harness — and the drop target is irrelevant to the routing
# exclusion under test, so file it plain.
seed DIVE-7; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-7 --type=secret --ask="paste the deploy key" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: secret stays human-directed (never routed)" || bad_t "secret → human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ -z "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-7';")" ]] && ok_t "secret leaves routed_reviewer NULL" || bad_t "secret routed_reviewer NULL" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-7';")'"

# --- DIVE-1182: a true-human-category APPROVAL (money) is NOT routed ----------
seed DIVE-8; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-8 --type=approval --ask="approve the \$5000 ad spend budget?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: money approval → human (category floor, not routed)" || bad_t "money approval → human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ -z "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-8';")" ]] && ok_t "money approval leaves routed_reviewer NULL" || bad_t "money approval routed_reviewer NULL" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-8';")'"

# --- DIVE-1182: explicit --tier=2 approval is NOT routed (hard-human contract) -
seed DIVE-9; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-9 --type=approval --tier=2 --ask="approve the prod push?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: explicit --tier=2 approval → human (not routed)" || bad_t "explicit T2 approval → human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- pref ON: tier-2-floored decision (money) is NOT routed ------------------
seed DIVE-5; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-5 --type=decision --ask="approve the \$5000 ad spend budget?" --options="yes|no" --recommend="no" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: T2-floored decision (money) → human" || bad_t "T2 floor → human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ ! -s "$ROUTE_FILE" ]] && ok_t "T2-floored decision: no lead route fired" || bad_t "T2 floor no route" "sent=$(route_last)"

# --- pref ON: EXPLICIT --tier=2 decision (no floor keyword) is NOT routed ----
# Guards the hard-human contract: 2 = never auto-applies, always pings. Before
# the effective-tier fix this left tier_floored=0 and silently routed to the lead.
seed DIVE-6; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-6 --type=decision --tier=2 --ask="pick the launch date?" --options="mon|tue" --recommend="mon" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: explicit --tier=2 decision → human (not routed)" || bad_t "explicit T2 decision → human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ ! -s "$ROUTE_FILE" ]] && ok_t "explicit --tier=2 decision: no lead route fired" || bad_t "explicit T2 no route" "sent=$(route_last)"

# --- DIVE-1145 (iter-4): the `task routing` toggle sets/reads the pref --------
# Subshell each call so a `fail` (usage) exit can't abort the harness; the pref
# write lands in the sqlite DB so it survives the subshell.
_task_pref_set gate_builder_routing off
( cmd_task_routing on )  >/dev/null 2>&1
[[ "$(_task_pref_get gate_builder_routing)" == "on" ]]  && ok_t "task routing on → pref=on"   || bad_t "task routing on"  "pref=$(_task_pref_get gate_builder_routing)"
( cmd_task_routing off ) >/dev/null 2>&1
[[ "$(_task_pref_get gate_builder_routing)" == "off" ]] && ok_t "task routing off → pref=off" || bad_t "task routing off" "pref=$(_task_pref_get gate_builder_routing)"
( cmd_task_routing bogus ) >/dev/null 2>&1; rc=$?
[[ "$rc" != "0" ]] && ok_t "task routing bogus → usage error (rc=$rc)" || bad_t "task routing bogus" "rc=$rc"

# --- DIVE-1182 FUNCTIONAL: designated lead clears routed approval; others don't -
# Exercise cmd_task_answer's uid exception by spoofing `id -un`. The exception is
# keyed on: caller == agent-<routed_reviewer> AND need_type approval/manual AND a
# routed_reviewer set. enforce is OFF in this throwaway state, so the evidence
# block is inert; the uid block (which fires regardless of enforce) is what we test.
_gate_proof_enforced() { return 1; }   # keep evidence block inert for this unit
# Non-reviewer agent (dev) must STILL be blocked on the routed approval gate.
id() { if [[ "${1:-}" == "-un" ]]; then echo "agent-dev"; else command id "$@"; fi; }
( cmd_task_answer DIVE-4 --value=approved --from=dev ) >/dev/null 2>&1; rc_dev=$?
[[ "$rc_dev" != "0" && "$(answered DIVE-4)" == "open" ]] && ok_t "non-reviewer agent (dev) still blocked on routed approval" || bad_t "dev blocked" "rc=$rc_dev ans=$(answered DIVE-4)"
# Designated lead (main) CAN clear it.
id() { if [[ "${1:-}" == "-un" ]]; then echo "agent-main"; else command id "$@"; fi; }
( cmd_task_answer DIVE-4 --value=approved --from=main ) >/dev/null 2>&1; rc_main=$?
[[ "$rc_main" == "0" && "$(answered DIVE-4)" == "closed" ]] && ok_t "designated lead (main) clears routed approval (DIVE-1182)" || bad_t "lead clears approval" "rc=$rc_main ans=$(answered DIVE-4)"
[[ "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-4';")" == lead:* ]] && ok_t "lead-clear recorded as lead:* provenance (not human:*)" || bad_t "lead:* provenance" "got '$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-4';")'"
unset -f id

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
