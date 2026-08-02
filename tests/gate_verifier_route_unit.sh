#!/usr/bin/env bash
# DIVE-1495: (1) a decision/approval gate the MAKER files on a maker→verifier loop
# routes to the VERIFIER agent (not the paired human); (2) `task reject` supersedes
# any still-open need-gate so the DIVE-1490 re-nag ladder stops firing it.
# Harness mirrors gate_ship_routing_unit.sh: source src/ libs, throwaway STATE_DIR,
# no root, no network. Run: bash tests/gate_verifier_route_unit.sh
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
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
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
#
# DIVE-2518 MOVED THE PIN, and had to. Setting $USER no longer moves the actor —
# that env path WAS the forgery this ticket closed — and wrapping `task_actor`
# cannot pin identity any more either, because cmd_task_need's corroboration guard
# reads the derivation DIRECTLY rather than through that accessor. The pin now goes
# through the sealed seam (tests/lib/actor_seam.sh), which is the same
# _gate_caller_uid/_gate_passwd_stream pair DIVE-2330 kept for exactly this.
#
# `--from` stays under test rather than under simulation, as the note above wants —
# but it is now a CLAIM that must corroborate, so each step DERIVES as the agent it
# files as. A step that derived as one agent and filed as another is refused by
# design, and before this migration that refusal exited the harness mid-run: the
# suite stopped after arm 3 and still reported status 0, which is the truncated-run-
# reads-as-a-pass shape. It went from 9/0 to a silent 3-arm stub.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
FIXTURE_ACTOR=fixture-runner   # not a real agent; set per-step to impersonate one on purpose
fixture_actor() { FIXTURE_ACTOR="$1"; actor_seam_as "$1"; }

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
route_reset; seed_loop DIVE-501; fixture_actor dev
cmd_task_need DIVE-501 --type=decision --options='A|B' --recommend='A' \
  --ask='Which schema for the field?' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "main" ]] \
  && ok_t "maker decision gate routes to verifier 'main'" \
  || bad_t "maker decision gate routes to verifier 'main'" "route_last=$(route_last) human=$HUMAN_PINGED"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-501';")" == "main" ]] \
  && ok_t "routed_reviewer persisted as verifier" \
  || bad_t "routed_reviewer persisted as verifier" "got=$(db "SELECT routed_reviewer FROM tasks WHERE ident='DIVE-501';")"

# ---- 2. approval gate on the loop also routes to the verifier ----
route_reset; seed_loop DIVE-502; fixture_actor dev
actor_seam_as dev; cmd_task_need DIVE-502 --type=approval --ask='OK to merge the refactor?' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "main" ]] \
  && ok_t "maker approval gate routes to verifier 'main'" \
  || bad_t "maker approval gate routes to verifier 'main'" "route_last=$(route_last) human=$HUMAN_PINGED"

# ---- 3. filer IS the verifier -> no self-route (max-iters escalation stays human) ----
route_reset; seed_loop DIVE-503; fixture_actor main
cmd_task_need DIVE-503 --type=decision --options='A|B' --recommend='A' \
  --ask='pick one' --from=main >/dev/null 2>&1
[[ "$(route_last)" != "main" ]] \
  && ok_t "verifier's own gate does not self-route to itself" \
  || bad_t "verifier's own gate does not self-route to itself" "route_last=$(route_last)"

# ---- 4. tier-2 category floor (money) stays human even on a loop ----
route_reset; seed_loop DIVE-504; fixture_actor dev
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
# Back to the NEUTRAL fixture identity. Step 4 pinned `dev` to file its gate, and
# `dev` is DIVE-505's maker — so leaving the pin there makes step 5's reject a
# self-grade and the DIVE-2112 guard correctly ends the run. Under the old global
# $USER pin this reset was implicit (nothing moved the actor per step); with a real
# per-step derivation it has to be written down. Step 6 re-pins `dev` on purpose,
# which is exactly the negative control for this line.
fixture_actor fixture-runner
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
fixture_actor dev
rj_out=$(cmd_task_reject DIVE-506 --feedback='maker grading itself' 2>&1); rj_rc=$?
fixture_actor fixture-runner
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
