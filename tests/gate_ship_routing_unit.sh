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
# _gate_route_reviewer shells `5dive agent send` in the on-route path; command -v
# 5dive is false in the harness sandbox, so the send is skipped — no stub needed.

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
seed DIVE-2; HUMAN_PINGED=0
cmd_task_need DIVE-2 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "route on: builder decision does NOT ping human" || bad_t "route suppresses human" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(statusof DIVE-2)" == "blocked" && "$(answered DIVE-2)" == "open" ]] && ok_t "routed gate stays blocked+open for lead" || bad_t "routed gate blocked+open" "status=$(statusof DIVE-2) ans=$(answered DIVE-2)"

# --- pref ON: gate filed BY the lead escalates to human ----------------------
seed DIVE-3; HUMAN_PINGED=0
cmd_task_need DIVE-3 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=main >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: lead's own decision goes to human" || bad_t "lead decision → human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- pref ON: approval gate is NOT routed (human-only category) --------------
seed DIVE-4; HUMAN_PINGED=0
cmd_task_need DIVE-4 --type=approval --ask="approve the prod push?" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: approval stays human-directed" || bad_t "approval → human" "HUMAN_PINGED=$HUMAN_PINGED"

# --- pref ON: tier-2-floored decision (money) is NOT routed ------------------
seed DIVE-5; HUMAN_PINGED=0
cmd_task_need DIVE-5 --type=decision --ask="approve the \$5000 ad spend budget?" --options="yes|no" --recommend="no" --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "route on: T2-floored decision (money) → human" || bad_t "T2 floor → human" "HUMAN_PINGED=$HUMAN_PINGED"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
