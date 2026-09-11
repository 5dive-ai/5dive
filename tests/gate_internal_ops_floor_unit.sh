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

# --- 2: SAFETY — a genuine prod-destructive ask (no internal-ops vocab) stays hard-human
route_reset; seed DIVE-302
actor_seam_as dev; cmd_task_need DIVE-302 --type=decision --from=dev \
  --ask="Drop the production customers table to reclaim space — irreversible, confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-302)" == "2" ]] && ok_t "safety: prod drop-table stays tier 2 (human)" || bad_t "safety prod tier 2" "got '$(tierof DIVE-302)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: prod drop-table pings the human" || bad_t "safety prod pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 3: SAFETY — internal-ops vocab BUT a real residual floor term (revoke) still floors
route_reset; seed DIVE-303
actor_seam_as dev; cmd_task_need DIVE-303 --type=decision --from=dev \
  --ask="Rebuild the task board after the wipe AND revoke the leaked API key — proceed?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-303)" == "2" ]] && ok_t "safety: internal-ops + 'revoke' residual stays tier 2 (human)" || bad_t "safety revoke residual" "got '$(tierof DIVE-303)'"

# --- 4: SAFETY — money residual (refund/$) inside an internal-ops ask still floors
route_reset; seed DIVE-304
actor_seam_as dev; cmd_task_need DIVE-304 --type=decision --from=dev \
  --ask="Wipe the board test rows after refunding the customer \$500 — go?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-304)" == "2" ]] && ok_t "safety: internal-ops + money residual stays tier 2 (human)" || bad_t "safety money residual" "got '$(tierof DIVE-304)'"

# --- 5: SAFETY — the LEAD filing it has no reviewer, so it is NOT downgraded (human)
route_reset; seed DIVE-305
actor_seam_as main; cmd_task_need DIVE-305 --type=decision --from=main \
  --ask="Board wiped — discard my uncommitted work and rebuild from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-305)" == "2" ]] && ok_t "safety: lead-filed internal-ops stays tier 2 (no reviewer)" || bad_t "safety lead tier 2" "got '$(tierof DIVE-305)'"

# --- 6: NO-OP — a non-floored internal decision is untouched (default tier-1 routing)
route_reset; seed DIVE-306
actor_seam_as dev; cmd_task_need DIVE-306 --type=decision --from=dev \
  --ask="Which task board column order should we show, priority-first or age-first?" \
  --options="priority|age" --recommend="priority" >/dev/null 2>&1
[[ "$(tierof DIVE-306)" == "1" ]] && ok_t "no-op: non-floored internal decision stays tier 1 (unchanged)" || bad_t "no-op tier 1" "got '$(tierof DIVE-306)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "no-op: non-floored decision still pings human (pref off, unchanged)" || bad_t "no-op pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 7: SAFETY — a plain destructive decision with NO internal-ops vocab still floors
route_reset; seed DIVE-307
actor_seam_as dev; cmd_task_need DIVE-307 --type=decision --from=dev \
  --ask="Delete all the old render artifacts to free disk — destroy them permanently?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-307)" == "2" ]] && ok_t "safety: destructive w/o internal-ops vocab stays tier 2 (human)" || bad_t "safety plain destructive" "got '$(tierof DIVE-307)'"

# --- 8: DIVE-1481 — prod object in a recovery FRAMING stays hard-human. The ask
#        matches the internal-ops class ('board recovery') but the destructive verb
#        governs the PRODUCTION DATABASE, not the board, so 'delete' is NOT
#        co-referent to an internal object → survives the residual → stays tier 2.
route_reset; seed DIVE-308
actor_seam_as dev; cmd_task_need DIVE-308 --type=decision --from=dev \
  --ask="Delete the production database as part of the board recovery — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-308)" == "2" ]] && ok_t "DIVE-1481: prod-delete in recovery framing stays tier 2 (human)" || bad_t "1481 prod-in-framing tier 2" "got '$(tierof DIVE-308)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1481: prod-delete in recovery framing pings the human" || bad_t "1481 prod-in-framing pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 9: DIVE-1481 — a genuine internal, CO-REFERENT wipe still downgrades (the fix
#        must not over-tighten). 'wipe' governs 'the board', so it is carved out and
#        the residual is clean → lead-routed tier 1.
route_reset; seed DIVE-309
actor_seam_as dev; cmd_task_need DIVE-309 --type=decision --from=dev \
  --ask="Wipe the task board and rebuild it from the audit log — keep or discard my uncommitted wip first?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-309)" == "1" ]] && ok_t "DIVE-1481: co-referent 'wipe the board' still downgrades to tier 1" || bad_t "1481 co-referent tier 1" "got '$(tierof DIVE-309)'"
[[ "$(routedof DIVE-309)" == "main" ]] && ok_t "DIVE-1481: co-referent wipe routed to lead (main)" || bad_t "1481 co-referent routed main" "got '$(routedof DIVE-309)'"

# --- 10: DIVE-1487 — COORDINATION: one verb governs an internal AND an external
#         object ("delete the board AND the production database"). The nearest-object
#         strip would carve 'delete' as co-referent to 'board'; the external-target
#         guard refuses to strip → residual keeps 'delete' → stays hard-human.
route_reset; seed DIVE-310
actor_seam_as dev; cmd_task_need DIVE-310 --type=decision --from=dev \
  --ask="Delete the board and the production database — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-310)" == "2" ]] && ok_t "DIVE-1487: coordinated internal+prod delete stays tier 2 (human)" || bad_t "1487 coordination tier 2" "got '$(tierof DIVE-310)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "DIVE-1487: coordinated delete pings the human" || bad_t "1487 coordination pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 11: DIVE-1487 — PASSIVE OVER-REACH: "wipe the board then delete the prod
#         customer records" — the passive branch would strip 'delete' merely because
#         'board' precedes it within 20 chars, though 'delete' governs prod records.
route_reset; seed DIVE-311
actor_seam_as dev; cmd_task_need DIVE-311 --type=decision --from=dev \
  --ask="Wipe the board then delete the prod customer records — go ahead?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-311)" == "2" ]] && ok_t "DIVE-1487: passive over-reach (prod customer records) stays tier 2 (human)" || bad_t "1487 passive tier 2" "got '$(tierof DIVE-311)'"

# --- 12: DIVE-1487 — compound purge/drop: "purge the backlog and drop the customers
#         table". Guard keeps 'purge' in the residual (→ floor); and the widened
#         'drop[^.]{0,20}table' floor term catches 'drop the customers table' too.
route_reset; seed DIVE-312
actor_seam_as dev; cmd_task_need DIVE-312 --type=decision --from=dev \
  --ask="Purge the backlog and drop the customers table — confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-312)" == "2" ]] && ok_t "DIVE-1487: compound purge+drop-customers-table stays tier 2 (human)" || bad_t "1487 compound tier 2" "got '$(tierof DIVE-312)'"

# --- 13: DIVE-1487 — floor-vocab: a standalone 'drop the customers table' (no
#         internal-ops vocab, no delete/purge) now trips the widened floor directly.
route_reset; seed DIVE-313
actor_seam_as dev; cmd_task_need DIVE-313 --type=decision --from=dev \
  --ask="Drop the customers table in prod — proceed?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-313)" == "2" ]] && ok_t "DIVE-1487: standalone drop-<x>-table trips widened floor (tier 2)" || bad_t "1487 drop-table floor" "got '$(tierof DIVE-313)'"

# --- 14: DIVE-1487 — NO OVER-TIGHTEN: a purely internal co-referent wipe with NO
#         external target still downgrades to lead-routed tier 1 (guard not tripped).
route_reset; seed DIVE-314
actor_seam_as dev; cmd_task_need DIVE-314 --type=decision --from=dev \
  --ask="Wipe the task board and rebuild from the audit log — discard my uncommitted wip first?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-314)" == "1" ]] && ok_t "DIVE-1487: purely-internal wipe still downgrades to tier 1 (no over-tighten)" || bad_t "1487 internal still tier 1" "got '$(tierof DIVE-314)'"
[[ "$(routedof DIVE-314)" == "main" ]] && ok_t "DIVE-1487: purely-internal wipe routed to lead (main)" || bad_t "1487 internal routed main" "got '$(routedof DIVE-314)'"

echo
echo "gate internal-ops floor: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
