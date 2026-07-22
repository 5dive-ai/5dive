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
# NB: ask must NOT name an eng-ship action, else DIVE-1359 downgrades it (below).
seed DIVE-9; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-9 --type=approval --tier=2 --ask="make the final go/no-go call on this?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: explicit --tier=2 approval → human (not routed)" || bad_t "explicit T2 approval → human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- DIVE-1359: eng-ship class — a builder CANNOT hard-human-gate an eng ship/ --
# merge/diff/deploy decision. Even an explicit --tier=2 is downgraded to a
# lead-routed tier-1 and routed to the org lead, NOT pinged to the human. Mirror
# of the T2 floor; routes regardless of the gate_builder_routing pref.
seed DIVE-30; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-30 --type=approval --tier=2 --ask="approve the prod push?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1359: eng-ship approval --tier=2 NOT pinged to human" || bad_t "eng-ship T2 → not human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(db "SELECT tier FROM tasks WHERE ident='DIVE-30';")" == "1" ]] && ok_t "DIVE-1359: eng-ship --tier=2 downgraded to lead-routed tier-1" || bad_t "eng-ship downgrade to tier-1" "got tier '$(db "SELECT tier FROM tasks WHERE ident='DIVE-30';")'"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-30';")" == "main" ]] && ok_t "DIVE-1359: eng-ship approval routed_reviewer=main (lead-clearable)" || bad_t "eng-ship routed to lead" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-30';")'"

# --- DIVE-1359: eng-ship routes even with pref OFF (intrinsic to the kind) ----
_task_pref_set gate_builder_routing off
seed DIVE-31; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-31 --type=approval --ask="ship the DIVE-1359 branch to main?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" && "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-31';")" == "main" ]] && ok_t "DIVE-1359: eng-ship routes to lead even with pref OFF" || bad_t "eng-ship pref-OFF route" "human=$HUMAN_PINGED reviewer='$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-31';")'"
# a genuine money approval with pref OFF still pings the human (floor wins over eng-ship)
seed DIVE-32; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-32 --type=approval --ask="approve the deploy AND the \$900 vercel invoice?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1359: floor beats eng-ship (deploy+\$invoice stays human)" || bad_t "floor beats eng-ship" "HUMAN_PINGED=$HUMAN_PINGED"
# a lead's OWN eng-ship gate is NOT downgraded (no distinct reviewer → human)
seed DIVE-33; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-33 --type=approval --tier=2 --ask="approve the prod push?" --from=main >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(db "SELECT tier FROM tasks WHERE ident='DIVE-33';")" == "2" ]] && ok_t "DIVE-1359: a lead's own eng-ship --tier=2 stays hard-human" || bad_t "lead eng-ship not downgraded" "human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='DIVE-33';")'"

# --- DIVE-1555: a delegated PUSH-FOR-REVIEW (5dive push / DIVE-1376) is eng-ship. A
# feature-branch push-for-review is NOT a `push to main`, so it used to miss the
# classifier and file as a tier-2 human-only approval that landed in the human's DM.
# It must now downgrade to a lead-routed tier-1 the org lead can clear. pref stays
# OFF (set above) to prove the routing is intrinsic to the kind, not the pref.
for _c in \
  "DIVE-34|approve delegated push for review of branch dive-1555-x" \
  "DIVE-35|push branch dive-1555-x for review (PR, no merge)" \
  "DIVE-36|clear this so 5dive push can run"; do
  _id="${_c%%|*}"; _ask="${_c#*|}"
  seed "$_id"; HUMAN_PINGED=0; route_reset
  cmd_task_need "$_id" --type=approval --ask="$_ask" --from=dev >/dev/null 2>&1
  [[ "$HUMAN_PINGED" == "0" \
     && "$(db "SELECT tier FROM tasks WHERE ident='$_id';")" == "1" \
     && "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$_id';")" == "main" ]] \
    && ok_t "DIVE-1555: push-for-review ask ('$_ask') → lead-routed tier-1 (not human DM)" \
    || bad_t "DIVE-1555: push-for-review → lead-routed tier-1" "ask='$_ask' human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='$_id';")' reviewer='$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$_id';")'"
done

# DIVE-1555: the true-human floor still wins — a push-for-review that ALSO names
# money stays a tier-2 human call (not lead-routed).
seed DIVE-37; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-37 --type=approval --ask="approve delegated push for review AND the \$500 vercel invoice?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(db "SELECT tier FROM tasks WHERE ident='DIVE-37';")" == "2" ]] \
  && ok_t "DIVE-1555: money floor beats push-for-review (stays tier-2 human)" \
  || bad_t "DIVE-1555: money floor beats push-for-review" "human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='DIVE-37';")'"

# --- DIVE-1698: a VERIFIED builder ship — "push the tested commit to GitHub + roll
# to the fleet" (repro: DIVE-1674 telegram undefined-guard, filed as approval and
# stuck on lodar's DM). "to GitHub" is not in the push-to-(main|prod|origin) list
# and "rolling to the fleet" is not "roll out", so it missed the classifier and
# stayed at the approval tier-2 default. It must now downgrade to a lead-routed
# tier-1. pref stays OFF to prove the routing is intrinsic to the kind.
for _c in \
  "DIVE-43|Approve pushing the telegram undefined-guard (commit b21be34) to GitHub + rolling to the fleet? suite 319/0" \
  "DIVE-44|push the tested commit to github then roll to the fleet" \
  "DIVE-45|clear this fleet roll of the verified build"; do
  _id="${_c%%|*}"; _ask="${_c#*|}"
  seed "$_id"; HUMAN_PINGED=0; route_reset
  cmd_task_need "$_id" --type=approval --ask="$_ask" --from=dev >/dev/null 2>&1
  [[ "$HUMAN_PINGED" == "0" \
     && "$(db "SELECT tier FROM tasks WHERE ident='$_id';")" == "1" \
     && "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$_id';")" == "main" ]] \
    && ok_t "DIVE-1698: verified push+fleet-roll ask ('$_ask') → lead-routed tier-1 (not human DM)" \
    || bad_t "DIVE-1698: push+fleet-roll → lead-routed tier-1" "ask='$_ask' human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='$_id';")' reviewer='$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$_id';")'"
done

# DIVE-1698: the true-human floor still wins — a push+fleet-roll that ALSO names a
# secret/credential stays a tier-2 human call (not lead-routed).
seed DIVE-46; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-46 --type=approval --ask="push to github + roll the new api key to the fleet?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(db "SELECT tier FROM tasks WHERE ident='DIVE-46';")" == "2" ]] \
  && ok_t "DIVE-1698: secret floor beats push+fleet-roll (stays tier-2 human)" \
  || bad_t "DIVE-1698: secret floor beats push+fleet-roll" "human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='DIVE-46';")'"

# --- DIVE-1605: eng-ship matcher must catch INFLECTED verb forms ----------------
# Regression for the 2026-07-21 leak (DIVE-1602): a builder filed
# "Approve landing the verified fix and pushing to origin" — a textbook eng-ship
# approval — but the gerunds "landing"/"pushing to origin" matched neither
# "land the/it" nor "push to origin", so no downgrade fired: it stayed tier-2
# hard-human and pinged the paired human instead of the lead. Must now downgrade
# + route to main. (DIVE-34..37 are taken above — use DIVE-38.)
seed DIVE-38; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-38 --type=approval --tier=2 --ask="Approve landing the verified CLI/plugin fix and pushing to origin?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1605: 'landing...pushing' eng-ship NOT pinged to human" || bad_t "DIVE-1605 gerund eng-ship -> human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(db "SELECT tier FROM tasks WHERE ident='DIVE-38';")" == "1" ]] && ok_t "DIVE-1605: 'landing...pushing' downgraded to tier-1" || bad_t "DIVE-1605 gerund downgrade" "got tier '$(db "SELECT tier FROM tasks WHERE ident='DIVE-38';")'"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-38';")" == "main" ]] && ok_t "DIVE-1605: 'landing...pushing' routed_reviewer=main (lead-clearable)" || bad_t "DIVE-1605 gerund route to lead" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-38';")'"

# --- DIVE-1381: content-curation class — a persona/pack QUEUE-READINESS approval --
# on our early-stage content surfaces is lead-clearable, NOT a human call. The T2
# floor matches 'publish' and would force it hard-human (the DIVE-1366 wall); the
# carve-out downgrades it to a lead-routed tier-1. Mirror of eng-ship; routes
# regardless of pref. pref stays OFF here (set above) to prove the routing is
# intrinsic to the kind.
seed DIVE-40; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-40 --type=approval --ask="approve persona 'doc' as ready to publish to the character-pack drip queue?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1381: curation 'publish' approval NOT pinged to human" || bad_t "curation → not human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(db "SELECT tier FROM tasks WHERE ident='DIVE-40';")" == "1" ]] && ok_t "DIVE-1381: curation gate downgraded from T2-floor to lead-routed tier-1" || bad_t "curation downgrade to tier-1" "got tier '$(db "SELECT tier FROM tasks WHERE ident='DIVE-40';")'"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-40';")" == "main" ]] && ok_t "DIVE-1381: curation approval routed_reviewer=main (lead-clearable), pref OFF" || bad_t "curation routed to lead" "got '$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-40';")'"

# curation-shaped WITHOUT a floor word is still intrinsically lead-routed (pref OFF)
seed DIVE-41; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-41 --type=approval --ask="approve the persona skill-set for 'doc' before it enters the drip queue?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" && "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-41';")" == "main" ]] && ok_t "DIVE-1381: curation (no floor word) routes to lead, pref OFF" || bad_t "curation no-floor route" "human=$HUMAN_PINGED reviewer='$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-41';")'"

# DIVE-1492: brand alone is no longer a hard-human floor. A brand decision that
# also names a persona stays lead-clearable through the curation route.
seed DIVE-42; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-42 --type=approval --ask="approve the brand palette for the persona pack?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" && "$(db "SELECT tier FROM tasks WHERE ident='DIVE-42';")" == "1" && "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-42';")" == "main" ]] \
  && ok_t "DIVE-1492: brand persona approval routes to lead at tier-1" \
  || bad_t "brand persona approval should route to lead" "human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='DIVE-42';")' reviewer='$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-42';")'"

# floor WINS over curation: MONEY in a curation ask stays hard-human.
seed DIVE-43; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-43 --type=approval --ask="approve the \$200 spend to publish the persona pack?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1381: floor beats curation (\$spend to publish persona → human)" || bad_t "money beats curation" "HUMAN_PINGED=$HUMAN_PINGED"

# floor WINS over curation: customer-comms (newsletter) stays hard-human.
seed DIVE-44; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-44 --type=approval --ask="approve the persona pack newsletter blast to customers?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1381: floor beats curation (persona newsletter blast → human)" || bad_t "newsletter beats curation" "HUMAN_PINGED=$HUMAN_PINGED"

# a lead's OWN curation gate is NOT downgraded (no distinct reviewer → human)
seed DIVE-45; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-45 --type=approval --tier=2 --ask="approve persona 'doc' ready to publish to the drip queue?" --from=main >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(db "SELECT tier FROM tasks WHERE ident='DIVE-45';")" == "2" ]] && ok_t "DIVE-1381: a lead's own curation --tier=2 stays hard-human" || bad_t "lead curation not downgraded" "human=$HUMAN_PINGED tier='$(db "SELECT tier FROM tasks WHERE ident='DIVE-45';")'"

# substring guard: 'accurate' / 'personalize' must NOT trip the curation class, so
# a non-curation ask that merely contains those substrings + 'publish' still floors.
seed DIVE-47; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-47 --type=approval --ask="approve the accurate personalized copy before we publish it?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1381: 'accurate'/'personalized'+publish does NOT match curation (still floors)" || bad_t "substring guard" "HUMAN_PINGED=$HUMAN_PINGED"

# a NON-curation 'publish' ask still floors to the human — proves the carve-out is
# scoped to the curation KIND, not to any ask that merely names 'publish'. (No
# other floor word here: 'publish' is the ONLY trigger, and it must still floor.)
seed DIVE-46; HUMAN_PINGED=0; route_reset
cmd_task_need DIVE-46 --type=approval --ask="approve the publish of the homepage hero copy?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1381: non-curation 'publish' still floors (carve-out scoped)" || bad_t "non-curation publish floors" "HUMAN_PINGED=$HUMAN_PINGED"

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
