#!/usr/bin/env bash
# TIER: nightly — 9.9s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-1480 isolated unit harness for the INTERNAL-OPS / recovery floor carve-out.
#
# The T2 destructive floor (delete|destroy|wipe|purge|…) is deliberately biased to
# over-elevate, but it mis-fired on the 2026-07-19 board wipe: dev's STEER-1 "keep
# vs discard my work / rebuild the board" DECISION gate NARRATED the wipe
# ('destroyed'/'wiped'/'purge'), so the floor forced it to hard-human tier-2 and it
# landed on lodar — when it was Marcus's (the lead's) call. The carve-out downgrades
# such an internal-ops/recovery decision to a LEAD-routed tier-1, but ONLY when the
# floor actually over-fired AND the sole trigger was an internal-destructive term:
# a genuine prod/infra/money/secret ask still stays hard-human. This harness proves
# the repro fixes AND every safety boundary holds. Isolation matches the sibling
# gate harnesses: source src/ into a throwaway STATE_DIR, never the live board.
# Run: bash tests/gate_internal_ops_floor_unit.sh   (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; TIER and ROUTING read the uid derivation, so an
# arm impersonating a filer must DERIVE as them. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-internalops-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
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

# Never DM the human or shell to a peer; record instead.
HUMAN_PINGED=0
# DIVE-2011: stub the HUMAN deliverer, not the wrapper. task_need_notify is now
# the shared entry point for BOTH rails (it dispatches to the lead-route
# deliverer when TASK_GATE_ROUTE_TO is set), so stubbing the wrapper would make
# this sentinel fire on a ROUTED gate — i.e. report a human ping that never
# happened — and would suppress the route send this harness is asserting on.
# One layer down, HUMAN_PINGED means what its name says: the paired human's
# notify path ran. The routed rail runs for real against the `5dive` stub.
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { HUMAN_PINGED=0; : >"$ROUTE_FILE"; }
route_to()    { local i; for i in $(seq 1 12); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; tail -n1 "$ROUTE_FILE" 2>/dev/null; }
# DIVE-3474 changed HOW a routed gate reaches the lead, not WHETHER it does: a
# non-urgent routed gate is QUEUED (no `agent send`, no window re-send) and the
# lead meets it on its next natural wake. The arm(s) below assert the gate reached
# a NAMED seat, and that property is unchanged — so the check gains the queue as a
# second way of being reached rather than being relaxed. It calls the REAL queue
# predicate (`_task_agent_gate_pred`, the one `5dive task queue` and the heartbeat
# nudge both use), so a row queued where nobody looks still fails here.
queued_for() { # <ident> <agent> -> 1 if `5dive task queue --for=<agent>` would list it
  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND $(_task_agent_gate_pred "$2");" 2>/dev/null)
  [[ "${n:-0}" != "0" ]] && echo 1 || echo 0
}

# Org chart: main is the lone coordinator; dev reports to main (so reviewer(dev)=main).
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

seed()      { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1','t','todo','main');"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
routedof()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }

# --- 1: THE REPRO — dev's board-wipe keep/discard decision routes to the LEAD, not lodar
route_reset; seed DIVE-301
actor_seam_as dev; cmd_task_need DIVE-301 --type=decision --from=dev \
  --ask="The task board was wiped/destroyed at 04:20 and my in-flight work is at risk — keep or discard my uncommitted work and rebuild the board from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-301)" == "1" ]] && ok_t "repro: board-wipe decision downgraded to tier 1 (not hard-human)" || bad_t "repro tier 1" "got '$(tierof DIVE-301)'"
[[ "$(routedof DIVE-301)" == "main" ]] && ok_t "repro: routed_reviewer=main (the lead's call)" || bad_t "repro routed main" "got '$(routedof DIVE-301)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro: paired human NOT pinged" || bad_t "repro no human ping" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(route_to)" == "main" || "$(queued_for DIVE-301 main)" == "1" ]] && ok_t "repro: the gate reached main — sent, or queued for its next wake" || bad_t "repro reached main" "route_to='$(route_to)' queued=$(queued_for DIVE-301 main)"

# ============================================================================
# DIVE-4175 arm C — WHAT THESE ARMS NOW ASSERT, AND WHY THE TIER LEFT.
#
# Arms 2-5, 7, 8 and 10-13 below used to read `tier == 2` and `HUMAN_PINGED == 1`.
# That was never the property they were defending; it was the TRANSITION the old
# keyword promoter happened to use to get there. Arm C deletes the promoter, so a
# floor term in the ask no longer promotes anything — every floor hit lead-routes.
# Reading the tier now grades a mechanism that is gone.
#
# Each safety arm is therefore converted to the OUTCOME it exists to produce — a
# reserved ask REACHES THE PAIRED HUMAN — reached by the route that survives arm C:
# the filer DECLARING the capability (`--needs=`, DIVE-2241). And each keeps, as an
# explicit negative control, the thing arm C GIVES UP: the same ask with nothing
# declared lead-routes instead of paging. The corpus records the loosening rather
# than losing it silently.
#
# THE PREDICATE IS NOT WHAT CHANGED. `floor_provenance` still records the axis and
# the term on every one of these asks, so an arm that used to prove "this ask trips
# the floor" still proves it — off the stamp instead of off the tier.
#
# WHAT DOES NOT SURVIVE, AND IT IS A FINDING NOT A CLEANUP: DIVE-1481's
# co-reference discriminator and DIVE-1487's external-target guard exist to decide
# which side of a tier-2/tier-1 split a floored ask lands on. With no split left
# they change no observable at the gate — measured directly in arms 8-14, where the
# ask the guard REFUSES to strip and the ask it strips now produce byte-identical
# rows. The mechanism code is left in place, untouched, per the 2026-09-10 gate
# answer; whether it may be retired is DIVE-4232's question and these arms are its
# starting evidence.
# ============================================================================
provof() { db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='$1';"; }

# --- 2: SAFETY — a genuine prod-destructive ask reaches the human WHEN DECLARED.
route_reset; seed DIVE-302
actor_seam_as dev; cmd_task_need DIVE-302 --type=decision --from=dev --needs=human_tap \
  --ask="Drop the production customers table to reclaim space — irreversible, confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-302)" == "2" ]] && ok_t "safety: DECLARED prod drop-table is tier 2 (human)" || bad_t "safety prod tier 2" "got '$(tierof DIVE-302)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: DECLARED prod drop-table pings the human" || bad_t "safety prod pings human" "HUMAN_PINGED=$HUMAN_PINGED"
# negative control — what arm C gives up: the identical ask, undeclared, lead-routes.
route_reset; seed DIVE-352
actor_seam_as dev; cmd_task_need DIVE-352 --type=decision --from=dev \
  --ask="Drop the production customers table to reclaim space — irreversible, confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-352)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "arm C control: the SAME prod ask UNDECLARED lead-routes, no page" || bad_t "control prod undeclared lead-routes" "routed='$(routedof DIVE-352)' HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(provof DIVE-352)" == axis=ask* ]] && ok_t "arm C control: the floor still MATCHED the undeclared prod ask (prov $(provof DIVE-352))" || bad_t "control prod prov" "got '$(provof DIVE-352)' — the predicate stopped matching"

# --- 3: SAFETY — a secret residual (revoke a leaked key) reaches the human WHEN DECLARED.
route_reset; seed DIVE-303
actor_seam_as dev; cmd_task_need DIVE-303 --type=decision --from=dev --needs=secret_provision \
  --ask="Rebuild the task board after the wipe AND revoke the leaked API key — proceed?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-303)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "safety: internal-ops + DECLARED secret residual reaches the human" || bad_t "safety revoke residual" "tier='$(tierof DIVE-303)' HUMAN_PINGED=$HUMAN_PINGED"
route_reset; seed DIVE-353
actor_seam_as dev; cmd_task_need DIVE-353 --type=decision --from=dev \
  --ask="Rebuild the task board after the wipe AND revoke the leaked API key — proceed?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(routedof DIVE-353)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "arm C control: the SAME secret ask UNDECLARED lead-routes, no page" || bad_t "control secret undeclared" "routed='$(routedof DIVE-353)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 4: SAFETY — a money residual inside an internal-ops ask reaches the human WHEN DECLARED.
route_reset; seed DIVE-304
actor_seam_as dev; cmd_task_need DIVE-304 --type=decision --from=dev --needs=spend_authority \
  --ask="Wipe the board test rows after refunding the customer \$500 — go?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-304)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "safety: internal-ops + DECLARED money residual reaches the human" || bad_t "safety money residual" "tier='$(tierof DIVE-304)' HUMAN_PINGED=$HUMAN_PINGED"
route_reset; seed DIVE-354
actor_seam_as dev; cmd_task_need DIVE-354 --type=decision --from=dev \
  --ask="Wipe the board test rows after refunding the customer \$500 — go?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-354)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "arm C control: the SAME money ask UNDECLARED lead-routes, no page" || bad_t "control money undeclared" "routed='$(routedof DIVE-354)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 5: SAFETY — the LEAD filing it has NO reviewer above, so there is no lead to
#     route to and the gate still reaches the PAIRED HUMAN. This is the one safety
#     arm arm C does not touch at all: it never depended on the promoter, it depends
#     on the `_routable` backstop finding nobody. The tier moved 2 -> 1; the OUTCOME
#     the arm exists for — the human is the one who sees it — is unchanged.
route_reset; seed DIVE-305
actor_seam_as main; cmd_task_need DIVE-305 --type=decision --from=main \
  --ask="Board wiped — discard my uncommitted work and rebuild from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: lead-filed internal-ops reaches the human (no reviewer to route to)" || bad_t "safety lead reaches human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ -z "$(routedof DIVE-305)" ]] && ok_t "safety: lead-filed internal-ops is NOT routed to a seat (nobody above the lead)" || bad_t "safety lead no reviewer" "routed='$(routedof DIVE-305)'"

# --- 6: NO-OP — a non-floored internal decision is untouched (default tier-1 routing)
route_reset; seed DIVE-306
actor_seam_as dev; cmd_task_need DIVE-306 --type=decision --from=dev \
  --ask="Which task board column order should we show, priority-first or age-first?" \
  --options="priority|age" --recommend="priority" >/dev/null 2>&1
[[ "$(tierof DIVE-306)" == "1" ]] && ok_t "no-op: non-floored internal decision stays tier 1 (unchanged)" || bad_t "no-op tier 1" "got '$(tierof DIVE-306)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "no-op: non-floored decision still pings human (pref off, unchanged)" || bad_t "no-op pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 7: SAFETY — a plain destructive decision with NO internal-ops vocab reaches
#     the human WHEN DECLARED, and lead-routes when it is not.
route_reset; seed DIVE-307
actor_seam_as dev; cmd_task_need DIVE-307 --type=decision --from=dev --needs=human_tap \
  --ask="Delete all the old render artifacts to free disk — destroy them permanently?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-307)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "safety: DECLARED destructive w/o internal-ops vocab reaches the human" || bad_t "safety plain destructive" "tier='$(tierof DIVE-307)' HUMAN_PINGED=$HUMAN_PINGED"
route_reset; seed DIVE-357
actor_seam_as dev; cmd_task_need DIVE-357 --type=decision --from=dev \
  --ask="Delete all the old render artifacts to free disk — destroy them permanently?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(routedof DIVE-357)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "arm C control: the SAME destructive ask UNDECLARED lead-routes, no page" || bad_t "control destructive undeclared" "routed='$(routedof DIVE-357)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 8: DIVE-1481 — prod object in a recovery FRAMING. The guard's job was to keep
#     'delete the PRODUCTION DATABASE' out of the internal-ops carve-out so it stayed
#     hard-human. Under arm C the carve-out is unreachable (it is guarded on
#     tier_floored==1 and nothing floors any more), so the guard decides nothing:
#     this ask and the co-referent one in arm 9 now produce the same row. Asserted as
#     such below, and paired with arm 9 as the DISCRIMINATOR CHECK — the two must
#     differ for DIVE-1481 to have an observable, and they do not.
route_reset; seed DIVE-308
actor_seam_as dev; cmd_task_need DIVE-308 --type=decision --from=dev \
  --ask="Delete the production database as part of the board recovery — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-308)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1481: prod-delete in recovery framing lead-routes (arm C outcome)" || bad_t "1481 prod-in-framing lead-routes" "routed='$(routedof DIVE-308)' HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(provof DIVE-308)" == axis=ask* ]] && ok_t "DIVE-1481: the floor still MATCHED the prod-delete ask (prov $(provof DIVE-308))" || bad_t "1481 prov" "got '$(provof DIVE-308)'"
# and the property the guard was protecting still has a route: DECLARE it.
route_reset; seed DIVE-358
actor_seam_as dev; cmd_task_need DIVE-358 --type=decision --from=dev --needs=human_tap \
  --ask="Delete the production database as part of the board recovery — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-358)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1481: DECLARED prod-delete still reaches the human" || bad_t "1481 declared reaches human" "tier='$(tierof DIVE-358)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 9: DIVE-1481 — a genuine internal, CO-REFERENT wipe. Kept verbatim: its
#     property (lead-routed tier 1) is exactly what arm C produces for the whole
#     class, so this arm passes unchanged and is the OTHER half of the discriminator.
route_reset; seed DIVE-309
actor_seam_as dev; cmd_task_need DIVE-309 --type=decision --from=dev \
  --ask="Wipe the task board and rebuild it from the audit log — keep or discard my uncommitted wip first?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-309)" == "1" ]] && ok_t "DIVE-1481: co-referent 'wipe the board' is lead-clearable tier 1" || bad_t "1481 co-referent tier 1" "got '$(tierof DIVE-309)'"
[[ "$(routedof DIVE-309)" == "main" ]] && ok_t "DIVE-1481: co-referent wipe routed to lead (main)" || bad_t "1481 co-referent routed main" "got '$(routedof DIVE-309)'"

# --- 9b: THE DISCRIMINATOR CHECK (DIVE-4232 evidence). DIVE-1481 exists to make
#     arm 8 and arm 9 land differently. If every observable at the gate is equal
#     across the two, the guard changes nothing that can be seen from here.
#     ASSERTED AS AN EQUALITY ON PURPOSE: this arm is a live measurement, and if a
#     later change gives DIVE-1481 an observable again it goes RED and says so.
# LIVENESS FIRST. An equality is satisfied by two EMPTY values, which is exactly
#     what a gate that failed to file at all produces — so the discriminator would
#     report "indistinguishable" about two rows that do not exist. Require both
#     sides to be populated before the equality is allowed to mean anything.
[[ -n "$(tierof DIVE-308)" && -n "$(routedof DIVE-308)" && -n "$(tierof DIVE-309)" && -n "$(routedof DIVE-309)" ]] \
  && ok_t "DIVE-4232 liveness: both discriminator rows filed and routed (the equality below is not vacuous)" \
  || bad_t "1481 discriminator liveness" "308(tier='$(tierof DIVE-308)' routed='$(routedof DIVE-308)') 309(tier='$(tierof DIVE-309)' routed='$(routedof DIVE-309)') — an empty side makes the equality meaningless"
[[ -n "$(tierof DIVE-308)" && "$(tierof DIVE-308)" == "$(tierof DIVE-309)" && "$(routedof DIVE-308)" == "$(routedof DIVE-309)" ]] \
  && ok_t "DIVE-4232 evidence: DIVE-1481's guarded and unguarded asks are INDISTINGUISHABLE at the gate (tier=$(tierof DIVE-308) routed=$(routedof DIVE-308))" \
  || bad_t "1481 discriminator" "guarded(tier=$(tierof DIVE-308) routed=$(routedof DIVE-308)) != unguarded(tier=$(tierof DIVE-309) routed=$(routedof DIVE-309)) — DIVE-1481 HAS an observable again; DIVE-4232 must be re-read before anything is retired"

# --- 10: DIVE-1487 — COORDINATION: one verb governs an internal AND an external
#         object. Same shape as arm 8: the external-target guard's only job was to
#         keep this on the tier-2 side of a split that no longer exists.
route_reset; seed DIVE-310
actor_seam_as dev; cmd_task_need DIVE-310 --type=decision --from=dev \
  --ask="Delete the board and the production database — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-310)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1487: coordinated internal+prod delete lead-routes (arm C outcome)" || bad_t "1487 coordination lead-routes" "routed='$(routedof DIVE-310)' HUMAN_PINGED=$HUMAN_PINGED"
route_reset; seed DIVE-360
actor_seam_as dev; cmd_task_need DIVE-360 --type=decision --from=dev --needs=human_tap \
  --ask="Delete the board and the production database — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-360)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1487: DECLARED coordinated delete still reaches the human" || bad_t "1487 declared reaches human" "tier='$(tierof DIVE-360)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 11: DIVE-1487 — PASSIVE OVER-REACH: "wipe the board then delete the prod
#         customer records". Converted the same way.
route_reset; seed DIVE-311
actor_seam_as dev; cmd_task_need DIVE-311 --type=decision --from=dev \
  --ask="Wipe the board then delete the prod customer records — go ahead?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-311)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1487: passive over-reach lead-routes (arm C outcome)" || bad_t "1487 passive lead-routes" "routed='$(routedof DIVE-311)' HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(provof DIVE-311)" == axis=ask* ]] && ok_t "DIVE-1487: the floor still MATCHED the passive over-reach ask (prov $(provof DIVE-311))" || bad_t "1487 passive prov" "got '$(provof DIVE-311)'"

# --- 12: DIVE-1487 — compound purge/drop.
route_reset; seed DIVE-312
actor_seam_as dev; cmd_task_need DIVE-312 --type=decision --from=dev \
  --ask="Purge the backlog and drop the customers table — confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(routedof DIVE-312)" == "main" && "$HUMAN_PINGED" == "0" ]] && ok_t "DIVE-1487: compound purge+drop-customers-table lead-routes (arm C outcome)" || bad_t "1487 compound lead-routes" "routed='$(routedof DIVE-312)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 13: DIVE-1487 — floor-vocab: a standalone 'drop the customers table' trips the
#         WIDENED floor term. The tier is no longer the evidence that it tripped;
#         floor_provenance is, and it names the term. This is the arm that would go
#         red if `drop[^.]{0,20}table` were ever dropped from the shipped default —
#         which is exactly what `5dive council floor-diff` reports on the live host,
#         where the sealed constitution omits it.
route_reset; seed DIVE-313
actor_seam_as dev; cmd_task_need DIVE-313 --type=decision --from=dev \
  --ask="Drop the customers table in prod — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(provof DIVE-313)" == axis=ask* ]] && ok_t "DIVE-1487: standalone drop-<x>-table still trips the widened floor (prov $(provof DIVE-313))" || bad_t "1487 drop-table floor" "got prov '$(provof DIVE-313)' — the widened term stopped matching"

# --- 14: DIVE-1487 — NO OVER-TIGHTEN: a purely internal co-referent wipe with NO
#         external target still lead-routes at tier 1 (unchanged by arm C).
route_reset; seed DIVE-314
actor_seam_as dev; cmd_task_need DIVE-314 --type=decision --from=dev \
  --ask="Wipe the task board and rebuild from the audit log — discard my uncommitted wip first?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-314)" == "1" ]] && ok_t "DIVE-1487: purely-internal wipe stays tier 1 (no over-tighten)" || bad_t "1487 internal still tier 1" "got '$(tierof DIVE-314)'"
[[ "$(routedof DIVE-314)" == "main" ]] && ok_t "DIVE-1487: purely-internal wipe routed to lead (main)" || bad_t "1487 internal routed main" "got '$(routedof DIVE-314)'"

# --- 14b: THE DISCRIMINATOR CHECK for DIVE-1487 (DIVE-4232 evidence). The
#     external-target guard exists to make arm 10 (coordinated internal+prod) and
#     arm 14 (purely internal) land differently. Same equality assertion as 9b.
[[ -n "$(tierof DIVE-310)" && -n "$(routedof DIVE-310)" && -n "$(tierof DIVE-314)" && -n "$(routedof DIVE-314)" ]] \
  && ok_t "DIVE-4232 liveness: both DIVE-1487 discriminator rows filed and routed" \
  || bad_t "1487 discriminator liveness" "310(tier='$(tierof DIVE-310)' routed='$(routedof DIVE-310)') 314(tier='$(tierof DIVE-314)' routed='$(routedof DIVE-314)')"
[[ -n "$(tierof DIVE-310)" && "$(tierof DIVE-310)" == "$(tierof DIVE-314)" && "$(routedof DIVE-310)" == "$(routedof DIVE-314)" ]] \
  && ok_t "DIVE-4232 evidence: DIVE-1487's guarded and unguarded asks are INDISTINGUISHABLE at the gate (tier=$(tierof DIVE-310) routed=$(routedof DIVE-310))" \
  || bad_t "1487 discriminator" "guarded(tier=$(tierof DIVE-310) routed=$(routedof DIVE-310)) != unguarded(tier=$(tierof DIVE-314) routed=$(routedof DIVE-314)) — DIVE-1487 HAS an observable again; DIVE-4232 must be re-read before anything is retired"

echo
echo "gate internal-ops floor: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
