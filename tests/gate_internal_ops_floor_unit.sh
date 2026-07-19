#!/usr/bin/env bash
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
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-internalops-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
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
task_need_notify() { HUMAN_PINGED=1; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { HUMAN_PINGED=0; : >"$ROUTE_FILE"; }
route_to()    { local i; for i in $(seq 1 12); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; tail -n1 "$ROUTE_FILE" 2>/dev/null; }

# Org chart: main is the lone coordinator; dev reports to main (so reviewer(dev)=main).
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

seed()      { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1','t','todo','main');"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
routedof()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }

# --- 1: THE REPRO — dev's board-wipe keep/discard decision routes to the LEAD, not lodar
route_reset; seed DIVE-301
cmd_task_need DIVE-301 --type=decision --from=dev \
  --ask="The task board was wiped/destroyed at 04:20 and my in-flight work is at risk — keep or discard my uncommitted work and rebuild the board from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-301)" == "1" ]] && ok_t "repro: board-wipe decision downgraded to tier 1 (not hard-human)" || bad_t "repro tier 1" "got '$(tierof DIVE-301)'"
[[ "$(routedof DIVE-301)" == "main" ]] && ok_t "repro: routed_reviewer=main (the lead's call)" || bad_t "repro routed main" "got '$(routedof DIVE-301)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro: paired human NOT pinged" || bad_t "repro no human ping" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(route_to)" == "main" ]] && ok_t "repro: lead-route send went to main" || bad_t "repro route to main" "got '$(route_to)'"

# --- 2: SAFETY — a genuine prod-destructive ask (no internal-ops vocab) stays hard-human
route_reset; seed DIVE-302
cmd_task_need DIVE-302 --type=decision --from=dev \
  --ask="Drop the production customers table to reclaim space — irreversible, confirm?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-302)" == "2" ]] && ok_t "safety: prod drop-table stays tier 2 (human)" || bad_t "safety prod tier 2" "got '$(tierof DIVE-302)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: prod drop-table pings the human" || bad_t "safety prod pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 3: SAFETY — internal-ops vocab BUT a real residual floor term (revoke) still floors
route_reset; seed DIVE-303
cmd_task_need DIVE-303 --type=decision --from=dev \
  --ask="Rebuild the task board after the wipe AND revoke the leaked API key — proceed?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-303)" == "2" ]] && ok_t "safety: internal-ops + 'revoke' residual stays tier 2 (human)" || bad_t "safety revoke residual" "got '$(tierof DIVE-303)'"

# --- 4: SAFETY — money residual (refund/$) inside an internal-ops ask still floors
route_reset; seed DIVE-304
cmd_task_need DIVE-304 --type=decision --from=dev \
  --ask="Wipe the board test rows after refunding the customer \$500 — go?" \
  --options="yes|no" --recommend="no" >/dev/null 2>&1
[[ "$(tierof DIVE-304)" == "2" ]] && ok_t "safety: internal-ops + money residual stays tier 2 (human)" || bad_t "safety money residual" "got '$(tierof DIVE-304)'"

# --- 5: SAFETY — the LEAD filing it has no reviewer, so it is NOT downgraded (human)
route_reset; seed DIVE-305
cmd_task_need DIVE-305 --type=decision --from=main \
  --ask="Board wiped — discard my uncommitted work and rebuild from the audit log?" \
  --options="keep|discard" --recommend="keep" >/dev/null 2>&1
[[ "$(tierof DIVE-305)" == "2" ]] && ok_t "safety: lead-filed internal-ops stays tier 2 (no reviewer)" || bad_t "safety lead tier 2" "got '$(tierof DIVE-305)'"

# --- 6: NO-OP — a non-floored internal decision is untouched (default tier-1 routing)
route_reset; seed DIVE-306
cmd_task_need DIVE-306 --type=decision --from=dev \
  --ask="Which task board column order should we show, priority-first or age-first?" \
  --options="priority|age" --recommend="priority" >/dev/null 2>&1
[[ "$(tierof DIVE-306)" == "1" ]] && ok_t "no-op: non-floored internal decision stays tier 1 (unchanged)" || bad_t "no-op tier 1" "got '$(tierof DIVE-306)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "no-op: non-floored decision still pings human (pref off, unchanged)" || bad_t "no-op pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 7: SAFETY — a plain destructive decision with NO internal-ops vocab still floors
route_reset; seed DIVE-307
cmd_task_need DIVE-307 --type=decision --from=dev \
  --ask="Delete all the old render artifacts to free disk — destroy them permanently?" \
  --options="yes|no" --recommend="yes" >/dev/null 2>&1
[[ "$(tierof DIVE-307)" == "2" ]] && ok_t "safety: destructive w/o internal-ops vocab stays tier 2 (human)" || bad_t "safety plain destructive" "got '$(tierof DIVE-307)'"

echo
echo "gate internal-ops floor: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
