#!/usr/bin/env bash
# DIVE-1495: (1) a decision/approval gate the MAKER files on a maker→verifier loop
# routes to the VERIFIER agent (not the paired human); (2) `task reject` supersedes
# any still-open need-gate so the DIVE-1490 re-nag ladder stops firing it.
# Harness mirrors gate_ship_routing_unit.sh: source src/ libs, throwaway STATE_DIR,
# no root, no network. Run: bash tests/gate_verifier_route_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-vfroute-unit.XXXXXX)"
# DIVE-2190: this harness has no `set -e`, but `fail()` exits the whole script, so a
# refusal inside any cmd_* call ends the run with the last line on screen being an `ok`
# and NO summary — a red that looks like a pass that stopped early. Say so, loudly, and
# without touching the exit status the verdict line set.
SUMMARY_PRINTED=0
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_verifier_route_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&2' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# DIVE-2190: the harness isolates STATE_DIR but the CALLER IDENTITY is ambient — task_actor
# reads SUDO_USER/USER — while the fixtures hard-code real agent names (maker='dev'). Run this
# suite as the agent literally named `dev` and the DIVE-2112 self-grading guard fires on step 5's
# reject for the right reason, killing the run. CI runs as a user matching no fixture, so it is
# permanently green there. Pin identity the way STATE_DIR is pinned, so WHO runs the suite stops
# being an input. Wrapping the REAL resolver (rather than reimplementing it) keeps the --from
# precedence under test instead of under simulation, and keeps the override inside this shell —
# there is deliberately no env var that could forge an actor in production.
eval "task_actor_REAL() $(declare -f task_actor | tail -n +2)"
FIXTURE_ACTOR=fixture-runner   # not a real agent; set per-step to impersonate one on purpose
task_actor() { USER="agent-${FIXTURE_ACTOR}" SUDO_USER='' task_actor_REAL "$@"; }

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

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
ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; HUMAN_PINGED=0; }
route_sent()  { local i n; for i in $(seq 1 10); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; n=$(grep -c . "$ROUTE_FILE" 2>/dev/null); echo "${n:-0}"; }
route_last()  { local i; for i in $(seq 1 10); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; tail -n1 "$ROUTE_FILE" 2>/dev/null; }

# Org chart: main is the lone root/coordinator; dev reports to main.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# A live maker→verifier loop task: maker=dev, verifier=main, dev holds it.
seed_loop() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations)
      VALUES('$1','loop task','todo','dev','dev','main','dev',1,5);"
}

# ---- 1. maker's decision gate routes to the verifier agent, not the human ----
route_reset; seed_loop DIVE-501
cmd_task_need DIVE-501 --type=decision --options='A|B' --recommend='A' \
  --ask='Which schema for the field?' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "main" ]] \
  && ok_t "maker decision gate routes to verifier 'main'" \
  || bad_t "maker decision gate routes to verifier 'main'" "route_last=$(route_last) human=$HUMAN_PINGED"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-501';")" == "main" ]] \
  && ok_t "routed_reviewer persisted as verifier" \
  || bad_t "routed_reviewer persisted as verifier" "got=$(db "SELECT routed_reviewer FROM tasks WHERE ident='DIVE-501';")"

# ---- 2. approval gate on the loop also routes to the verifier ----
route_reset; seed_loop DIVE-502
cmd_task_need DIVE-502 --type=approval --ask='OK to merge the refactor?' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "main" ]] \
  && ok_t "maker approval gate routes to verifier 'main'" \
  || bad_t "maker approval gate routes to verifier 'main'" "route_last=$(route_last) human=$HUMAN_PINGED"

# ---- 3. filer IS the verifier -> no self-route (max-iters escalation stays human) ----
route_reset; seed_loop DIVE-503
cmd_task_need DIVE-503 --type=decision --options='A|B' --recommend='A' \
  --ask='pick one' --from=main >/dev/null 2>&1
[[ "$(route_last)" != "main" ]] \
  && ok_t "verifier's own gate does not self-route to itself" \
  || bad_t "verifier's own gate does not self-route to itself" "route_last=$(route_last)"

# ---- 4. tier-2 category floor (money) stays human even on a loop ----
route_reset; seed_loop DIVE-504
cmd_task_need DIVE-504 --type=decision --options='A|B' --recommend='A' \
  --ask='Approve the $5000 refund to the customer?' --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(route_sent)" == "0" ]] \
  && ok_t "tier-2 money floor stays human, not verifier-routed" \
  || bad_t "tier-2 money floor stays human, not verifier-routed" "human=$HUMAN_PINGED sent=$(route_sent)"

# ---- 5. reject supersedes a still-open need-gate (DIVE-1490 re-nag fix) ----
# Seed a loop task carrying an OPEN manual gate, then reject it.
db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations,
      need_type,ask,need_answered_at)
    VALUES('DIVE-505','loop','blocked','dev','dev','main','dev',1,5,'manual','pending human thing',NULL);"
# DIVE-2190: stdout only. This call can END the harness (cmd_* refusals go through fail()),
# and `2>&1` sent the one line explaining WHY straight to /dev/null — the failure erased its
# own reason. Redirect noise, never diagnosis.
cmd_task_reject DIVE-505 --feedback='needs another pass' >/dev/null
gate_open=$(db "SELECT CASE WHEN need_type IS NOT NULL AND need_answered_at IS NULL THEN 1 ELSE 0 END FROM tasks WHERE ident='DIVE-505';")
answered_by=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-505';")
[[ "$gate_open" == "0" && "$answered_by" == "auto:reject" ]] \
  && ok_t "reject supersedes the open gate (auto:reject, no longer live)" \
  || bad_t "reject supersedes the open gate" "gate_open=$gate_open answered_by=$answered_by"
[[ "$(db "SELECT status FROM tasks WHERE ident='DIVE-505';")" == "todo" ]] \
  && ok_t "rejected task still bounces to maker (status todo)" \
  || bad_t "rejected task still bounces to maker (status todo)" "status=$(db "SELECT status FROM tasks WHERE ident='DIVE-505';")"

# ---- 6. the identity pin is a pin, not an off switch (DIVE-2190 negative control) ----
# Step 5 only passes because the actor is NOT the maker. Impersonate the maker on purpose and
# the DIVE-2112 guard must still refuse — otherwise a pin that silently resolved to "nobody"
# would look identical to a working one. Subshell: policy_refuse exits, and that exit is the
# assertion here, not an abort.
db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations,
      need_type,ask,need_answered_at)
    VALUES('DIVE-506','loop','blocked','dev','dev','main','dev',1,5,'manual','pending human thing',NULL);"
FIXTURE_ACTOR=dev
rj_out=$(cmd_task_reject DIVE-506 --feedback='maker grading itself' 2>&1); rj_rc=$?
FIXTURE_ACTOR=fixture-runner
[[ "$rj_rc" != "0" && "$rj_out" == *MAKER* ]] \
  && ok_t "maker impersonation is still refused (identity pin does not disarm DIVE-2112)" \
  || bad_t "maker impersonation is still refused" "rc=$rj_rc out=${rj_out//$'\n'/ }"
[[ "$(db "SELECT status FROM tasks WHERE ident='DIVE-506';")" == "blocked" \
   && "$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-506';")" == "" ]] \
  && ok_t "refused reject wrote nothing (status and gate untouched)" \
  || bad_t "refused reject wrote nothing" "status=$(db "SELECT status FROM tasks WHERE ident='DIVE-506';") answered_by=$(db "SELECT need_answered_by FROM tasks WHERE ident='DIVE-506';")"

echo "-----"
echo "gate_verifier_route_unit: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
