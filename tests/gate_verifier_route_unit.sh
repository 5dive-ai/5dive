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
# DIVE-2610: fd 8 is a dup of the REAL stderr, taken before any arm runs. The marker
# must NOT go to `>&2`: a refusal that exits from inside `cmd_x ... >/dev/null 2>&1`
# kills the shell while that redirect is live, so a trap printing to fd 2 lands in
# /dev/null and the truncation is silent again. Graded by tests/truncation_marker_guard_unit.sh.
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_verifier_route_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: appends the HARNESS-RC line to this harness's pre-existing abort-backstop trap; trap stays where it was (TMP/SUMMARY_PRINTED/fd8 are all already live by this point) rather than moving to the top.

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
# DIVE-3117 (quinn, iteration 2): the suppression audit row is not merely unasserted,
# it is structurally UNOBSERVABLE from the sink side. `_task_store_audit_log` is fenced
# behind `_task_human_send_allowed` (DIVE-2010), so against an isolated fixture TASKS_DB
# it writes NOTHING and warns once — "assert the row landed" cannot be made to work here,
# and a harness that queried the store would grade the fence, not the caller. So grade the
# CALL SITE with a spy. What a future refactor would silently drop is the call and its
# arguments, and that is exactly what this records.
SUPPRESS_LOG="$TMP/suppress.log"; : >"$SUPPRESS_LOG"
_task_store_audit_log() { printf '%s\n' "$*" >>"$SUPPRESS_LOG"; return 0; }
suppress_reset() { : >"$SUPPRESS_LOG"; }
# `grep -c` PRINTS 0 and EXITS 1 on no match, so a `|| echo 0` fallback appends a
# SECOND line and the count becomes "0\n0" — which compares equal to neither 0 nor 1.
# Caught by the zero-match arm below; the one-match arm was green throughout.
suppress_n()     { local n; n=$(grep -c 'verifier-route suppressed' "$SUPPRESS_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }
suppress_last()  { grep 'verifier-route suppressed' "$SUPPRESS_LOG" 2>/dev/null | tail -n1; }
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

# ---- 7. DIVE-3117: a PUSH-FOR-REVIEW ask never routes to the row's verifier ----
# The gate asks for the branch to be pushed; the verifier cannot read the diff until
# it IS pushed. Every arm below needs the lead and the verifier to be DIFFERENT
# agents — the fixtures above reuse `main` as both, so an assertion written against
# them would pass whichever seat the router picked. `grader` is a fixture name, not a
# fleet seat, and dev's lead stays `main`.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('grader','main','builder');"
seed_loop_g() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations)
      VALUES('$1','${2:-loop task}','todo','dev','dev','grader','dev',1,5);"
}
PUSH_ASK='approve delegated push for review of branch dive-3117-pfr-lead-route'

route_reset; suppress_reset; seed_loop_g DIVE-3117; fixture_actor dev
cmd_task_need DIVE-3117 --type=approval --ask="$PUSH_ASK" --from=dev >/dev/null 2>&1
rr=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-3117';")
[[ "$(route_last)" == "main" && "$rr" == "main" ]] \
  && ok_t "push-for-review approval routes to the LEAD, not the verifier" \
  || bad_t "push-for-review approval routes to the LEAD, not the verifier" "route_last=$(route_last) routed_reviewer=$rr human=$HUMAN_PINGED"
# The invariant stated on the ticket, asserted directly and in BOTH directions: a
# push-for-review ask must produce a routed_reviewer that is NEITHER empty (the
# DIVE-2629 failure — no agent can clear it) NOR the verifier (this one — the single
# agent who cannot answer it). The two have opposite causes, so an arm covering one
# is not evidence about the other.
[[ -n "$rr" && "$rr" != "grader" ]] \
  && ok_t "routed_reviewer is neither empty nor the verifier" \
  || bad_t "routed_reviewer is neither empty nor the verifier" "routed_reviewer='$rr' verifier=grader"
# The suppression is the ONLY trace a future regression could be counted from — the
# four measured instances were findable only because each row named its
# routed_reviewer, and after the fix no row does. Assert the call fires once and
# carries the verifier it did NOT go to plus where it went INSTEAD.
sup=$(suppress_last)
[[ "$(suppress_n)" == "1" && "$sup" == *"verifier=grader"* && "$sup" == *"routed=main"* && "$sup" == *"task=DIVE-3117"* ]] \
  && ok_t "suppression audit row fires once, naming the verifier it did NOT go to and where it went" \
  || bad_t "suppression audit row missing or malformed" "n=$(suppress_n) last='$sup'"

# 7b. NEGATIVE ARM (the ticket names it): a push-for-review ask on a row with NO
# verifier keeps its current routing. It must reach the lead by the SAME eng-ship
# path, so the loop's existence is not an input to routing in either direction.
route_reset; fixture_actor dev
db "INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('DIVE-3118','plain task','todo','dev','dev');"
cmd_task_need DIVE-3118 --type=approval --ask="$PUSH_ASK" --from=dev >/dev/null 2>&1
rr_nl=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-3118';")
[[ "$(route_last)" == "main" && "$rr_nl" == "main" ]] \
  && ok_t "no-verifier row keeps its lead routing (fix is not conditional on the loop)" \
  || bad_t "no-verifier row keeps its lead routing" "route_last=$(route_last) routed_reviewer=$rr_nl human=$HUMAN_PINGED"

# 7c. NEGATIVE CONTROL: verifier-routing is SUPPRESSED for one ask class, not
# disabled. A non-push question on the same loop shape still reaches the verifier —
# without this arm, deleting the DIVE-1495 route entirely would pass 7 and 7b.
route_reset; suppress_reset; seed_loop_g DIVE-3119; fixture_actor dev
cmd_task_need DIVE-3119 --type=decision --options='A|B' --recommend='A' \
  --ask='Which schema for the field?' --from=dev >/dev/null 2>&1
[[ "$(suppress_n)" == "0" ]] \
  && ok_t "NEGATIVE: no suppression row when the verifier route actually fires" \
  || bad_t "suppression row emitted on a gate that WAS verifier-routed" "n=$(suppress_n) last=$(suppress_last)"
[[ "$(route_last)" == "grader" ]] \
  && ok_t "a non-push gate on the same loop still routes to the verifier" \
  || bad_t "a non-push gate on the same loop still routes to the verifier" "route_last=$(route_last)"

# 7d. NEGATIVE CONTROL (DIVE-2224): the classifier reads the ASK, never the TITLE.
# This ticket's own title contains 'push-for-review'; a title-reading classifier
# would strip the verifier off every genuine question filed on it.
route_reset; fixture_actor dev
seed_loop_g DIVE-3120 'push-for-review gate routes to the loop VERIFIER'
cmd_task_need DIVE-3120 --type=decision --options='A|B' --recommend='A' \
  --ask='Which schema for the field?' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "grader" ]] \
  && ok_t "a push-for-review TITLE does not lead-route a non-push ask" \
  || bad_t "a push-for-review TITLE does not lead-route a non-push ask" "route_last=$(route_last)"

# 7e. NEGATIVE CONTROL: NOT-INERT pushes are unchanged. `_gate_push_for_review_hit`
# fails closed, so "push … then merge to main" is not an inert push-for-review and
# keeps the DIVE-1495 route — the same narrowing DIVE-2629 made on the tier axis.
route_reset; seed_loop_g DIVE-3121; fixture_actor dev
cmd_task_need DIVE-3121 --type=approval \
  --ask='push branch dive-3117-pfr-lead-route for review, then merge to main' --from=dev >/dev/null 2>&1
[[ "$(route_last)" == "grader" ]] \
  && ok_t "a not-inert push (merge to main named) keeps the verifier route" \
  || bad_t "a not-inert push (merge to main named) keeps the verifier route" "route_last=$(route_last)"

# 7f. The tier-2 human floor still wins over the whole class: a push ask that also
# names a spend stays with the human and reaches NO agent, verifier or lead.
route_reset; seed_loop_g DIVE-3122; fixture_actor dev
cmd_task_need DIVE-3122 --type=approval \
  --ask='approve delegated push for review of branch dive-3117-x and the $900 runner spend' --from=dev >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(route_sent)" == "0" ]] \
  && ok_t "a push ask naming a spend stays human (T2 floor outranks the class)" \
  || bad_t "a push ask naming a spend stays human" "human=$HUMAN_PINGED sent=$(route_sent) routed=$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-3122';")"
fixture_actor fixture-runner

echo "-----"
echo "gate_verifier_route_unit: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
