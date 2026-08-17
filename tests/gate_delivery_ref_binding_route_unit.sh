#!/usr/bin/env bash
# DIVE-3228 / DIVE-3525 isolated unit harness for the SECOND ROW-STATE BINDING.
#
# THE DEFECT. `_routable` already said YES for an unfloored `approval`, but that is
# only half the test: the routing cascade ALSO demanded one of the KIND flags or the
# `gate_builder_routing` pref, and that pref is OFF by default. So an ordinary ship
# approval whose ask missed `_GATE_ENG_SHIP_RX` was routable-and-unrouted —
# `routed_reviewer` NULL, which is the FIRST clause of cmd_task_inbox's human
# predicate. An unrouted gate IS a founder gate. lodar, 2026-08-11, on being pinged
# for DIVE-3225: "I still getting those".
#
# THE FIX, AND WHY IT IS NOT A TYPE DEFAULT. Iteration 1 of this ticket made the
# default the TYPE — every unfloored `approval` routed. main's differential reddened
# two harnesses that are green on origin/main (gate_row_state_routing_unit B1/C6/E1,
# gate_floor_declared_discussion arm 7), and the reason is the useful half: the four
# inherited exclusions only cover rows that are FLOORED or PINNED, while the rows that
# break are unrouted BY ABSENCE — an unbound row, a prose-only branch mention, a plain
# tier-1. Nothing floors them, so no backstop fires, and a type default routes them and
# leaves the human ping EMPTY. "A floored gate must not become agent-routable" held;
# "a row with nothing bound to it must still reach a person" did not.
#
# So the input is the BINDING, not the type. DIVE-3266 already routes on row state but
# reads exactly ONE binding: a `Branch:` line in the body — the binding `5dive push`
# requires, present on every push-for-review row and absent on the other half of the
# ship population, the rows that reached a pull request through `task deliver --pr=`.
# That verb writes the `delivery_ref` COLUMN and never touches the body. This harness
# grades that second binding: a reviewer is defaulted where one is derivable from
# structured row state, and the ABSENCE of that state keeps the gate on the human path.
#
# WHY EVERY POSITIVE ARM IS PAIRED WITH A CONTROL. "The approval routed to main" is
# also what a build with `gate_builder_routing=on`, a widened eng-ship regex, or a
# verifier loop looks like. So:
#   * A0 asserts the plain ask does NOT hit the eng-ship classifier. Without it,
#     case 1 would pass on a build where the fix does nothing and the regex grew.
#   * A0b asserts the pref really is off in this store.
#   * Case 0 is THE ABSENCE CONTROL and the arm iteration 1 failed: the SAME plain ask
#     on a row with NO binding stays unrouted and the human is pinged. A "route every
#     approval" regression passes every other case here and fails that one.
#   * Case 1b reads the trigger out of the ok() line: `row-ship-state:delivery-ref`,
#     so the arm names WHICH binding carried it, and the delivery-ref set stays
#     countable apart from DIVE-3266's branch set.
# The remaining cases are the boundary. Every exclusion arm is filed on a row that IS
# bound, so it grades the guard rather than the absence of a binding — an exclusion arm
# on an unbound row would pass on a build with no fix at all.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR, FIVEDIVE_GATE_NOTIFY_LOG at a temp file so no prod telemetry is touched.
# Run: bash tests/gate_approval_default_route_unit.sh   (no root, no network).
#
# ENV NOTE (DIVE-2007): a resolver reading the ambient identity behaves differently on
# a CI runner ($USER=runner) than on a dev box ($USER=agent-*). Repro the runner shape:
#   env -u SUDO_USER -u SUDO_UID USER=runner bash tests/gate_approval_default_route_unit.sh
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh) — a green
# log from a stale checkout and a green log from origin/main are otherwise identical.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; TIER/ROUTING read the uid derivation, so an arm
# impersonating a filer must DERIVE as them. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-approval-default-route.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
JSON_MODE=0
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
# `5dive` as a shell function: shadows the real binary so a routed handoff cannot
# shell out. The routed rail's observable here is the ROW, not the send.
5dive() { return 0; }

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# A ROUTINE ship approval whose wording carries none of the eng-ship regex members.
# Deliberately no `pr`, `merge`, `deploy`, `push`, `ship`, `diff`, `review`, `ci` —
# and no `land it` either, which the classifier DOES hold and which the first cut of
# this ask tripped. A0 below is what caught that, and is the reason it is an arm and
# not a comment: an ask a maintainer believes is plain is exactly what this whole
# defect is made of.
PLAIN_ASK="the parser rewrite is finished and the numbers look right — say go"

# seed <ident> [delivery_ref] — the ONLY difference between a bound and an unbound
# row here is the `delivery_ref` COLUMN. Body and title are identical in both, so no
# arm can route on prose by accident, and the `Branch:` binding DIVE-3266 already
# reads is never written: this harness grades the SECOND binding in isolation.
seed() { # <ident> [delivery_ref]
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,delivery_ref)
      VALUES('$1',$(sqlq 'a routine ticket'),'todo','main','dev',$(sqlq "${2:-}"));"
}
PR_REF="https://github.com/5dive-ai/5dive/pull/695"
# A gate is filed ON THE TASK ROW. `gate_filed_by` is stamped by cmd_task_need at the
# moment the gate is written, so it is the one column that separates "this gate was
# filed and not routed" from "this gate was REFUSED at filing and there is nothing to
# look up". Case 5 leaned on the second without noticing (quinn, iteration 1).
gate_written() { [[ -n "$(db "SELECT COALESCE(gate_filed_by,'') FROM tasks WHERE ident='$1';")" ]]; }
reviewer_of() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
prov_of()     { db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE ident='$1';"; }
tier_of()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

# --- A0. NON-VACUITY: the plain ask really does miss the eng-ship classifier ----
# Every positive arm below is meaningless if this ask routes by kind. Assert it
# BEFORE the first filing, and assert the classifier is alive on an ask that should
# hit it — a predicate stubbed to always-false would satisfy the first half alone.
_gate_eng_ship_hit "$PLAIN_ASK" \
  && bad_t "PLAIN_ASK must NOT hit the eng-ship classifier" "it does — every positive arm below is vacuous" \
  || ok_t "PLAIN_ASK does not hit the eng-ship classifier (so case 1 can only route via the type)"
_gate_eng_ship_hit "approve the merge of the parser refactor" \
  && ok_t "the eng-ship classifier is ALIVE (a real ship ask still hits it)" \
  || bad_t "the eng-ship classifier is dead" "the A0 negative above would pass for the wrong reason"

# --- A0b. NON-VACUITY: the pref really is off in this store --------------------
_pref="$(_task_pref_get gate_builder_routing)"; _pref="${_pref:-off}"
[[ "$_pref" == "off" ]] \
  && ok_t "gate_builder_routing is off in this store (so no arm routes via the pref)" \
  || bad_t "gate_builder_routing is '$_pref'" "with the pref on, every gate routes and this harness proves nothing"

# --- 0. THE ABSENCE CONTROL — the arm iteration 1 failed ----------------------
# Same plain ask, same type, same tier, same filer as case 1. The ONLY difference is
# that nothing is bound to this row. DIVE-3266's contract says this gate is the
# human's, and says so explicitly rather than silently. A build that defaults on the
# TYPE passes every other case in this file and fails here.
seed DIVE-9000
actor_seam_as dev
OUT0=$(cmd_task_need DIVE-9000 --type=approval --ask="$PLAIN_ASK" --recommend="go" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9000)" ]] \
  && ok_t "an UNBOUND row does NOT route — absence of a binding is the human's gate" \
  || bad_t "an unbound approval routed to '$(reviewer_of DIVE-9000)'" "the default is keyed on the TYPE, not the binding: $OUT0"
[[ "$OUT0" == *"NOT ROUTED"* ]] \
  && ok_t "and the unrouted receipt is still EXPLICIT (DIVE-3266's E1 contract holds)" \
  || bad_t "the unrouted receipt is not explicit" "$OUT0"

# 0b. An ordinary `decision` on an unbound row is likewise untouched — still
# pref-gated. A decision is already agent-clearable by TYPE, so it was never the
# population that reached lodar, and widening past it would be a second change.
seed DIVE-9020
actor_seam_as dev
cmd_task_need DIVE-9020 --type=decision --ask="$PLAIN_ASK" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
[[ -z "$(reviewer_of DIVE-9020)" ]] \
  && ok_t "an unbound decision is UNCHANGED — still pref-gated, still unrouted" \
  || bad_t "an unbound decision routed to '$(reviewer_of DIVE-9020)'" "the fix widened past the binding"

# --- 1. THE FIX: the SAME ask on a DELIVERY-BOUND row routes to the chart lead ---
# One variable against case 0: this row carries a `delivery_ref`. No `Branch:` line is
# written, so DIVE-3266's binding cannot be what carried it.
seed DIVE-9001 "$PR_REF"
actor_seam_as dev
OUT1=$(cmd_task_need DIVE-9001 --type=approval --ask="$PLAIN_ASK" --recommend="go" --from=dev 2>&1)
[[ "$(reviewer_of DIVE-9001)" == "main" ]] \
  && ok_t "a delivery-bound approval routes to the filer's lead (main), not to the human" \
  || bad_t "a delivery-bound approval routed to '$(reviewer_of DIVE-9001)', expected main" "$OUT1"
[[ "$(prov_of DIVE-9001)" == "chart" ]] \
  && ok_t "route_provenance is 'chart' — the org chart is still what resolved the NAME" \
  || bad_t "route_provenance is '$(prov_of DIVE-9001)', expected chart" "a new basis string would reach _gate_route_why's unknown arm"

# --- 1b. the receipt NAMES the kind, so this set is countable -------------------
[[ "$OUT1" == *"trigger=row-ship-state:delivery-ref"* ]] \
  && ok_t "the ok() line names trigger=row-ship-state:delivery-ref — WHICH binding carried it" \
  || bad_t "the ok() line does not name the delivery-ref binding" "$OUT1"
[[ "$OUT1" == *"routed to main"* ]] \
  && ok_t "the operator's receipt says 'routed to main' rather than 'needs a human'" \
  || bad_t "the receipt does not say routed to main" "$OUT1"

# --- 2. UNCHANGED: an approval that DOES hit eng-ship still routes, as eng-ship --
seed DIVE-9002 "$PR_REF"
actor_seam_as dev
OUT2=$(cmd_task_need DIVE-9002 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --from=dev 2>&1)
[[ "$(reviewer_of DIVE-9002)" == "main" ]] \
  && ok_t "an eng-ship approval still routes to main (pre-existing behaviour preserved)" \
  || bad_t "eng-ship approval routed to '$(reviewer_of DIVE-9002)'" "$OUT2"
[[ "$OUT2" == *"trigger=eng-ship"* ]] \
  && ok_t "and it is still reported as eng-ship — the more specific kind keeps naming itself" \
  || bad_t "an eng-ship approval no longer reports trigger=eng-ship" "$OUT2"

# --- 3..4. INHERITED EXCLUSION: a declared human-class capability (DIVE-2241) ----
i=3
for cap in human_tap spend_authority; do
  ident="DIVE-90$i"; seed "$ident" "$PR_REF"
  actor_seam_as dev
  OUTC=$(cmd_task_need "$ident" --type=approval --ask="$PLAIN_ASK" --recommend="go" --needs="$cap" --from=dev 2>&1)
  [[ -z "$(reviewer_of "$ident")" ]] \
    && ok_t "--needs=$cap keeps the approval on the human (routed_reviewer empty)" \
    || bad_t "--needs=$cap routed to '$(reviewer_of "$ident")'" "$OUTC"
  i=$((i+1))
done

# --- 5. INHERITED EXCLUSION: an EXPLICIT --tier=2 is the caller's hard contract --
seed DIVE-9005 "$PR_REF"
actor_seam_as dev
OUT5=$(cmd_task_need DIVE-9005 --type=approval --tier=2 --ask="$PLAIN_ASK" --recommend="go" \
         --rubber-stamp-ok="the release window is the founder's call and no lead holds it" --from=dev 2>&1)
# NON-VACUITY (quinn, iteration 1): a `--tier=2` approval carrying a `--recommend` and
# no `--rubber-stamp-ok` can be REFUSED at filing by the DIVE-2848 tapback cap, and a
# refused gate was never written — so `routed_reviewer` is empty for a reason that has
# nothing to do with the backstop this arm claims to grade. Assert the gate EXISTS
# first, and supply the audited escape so it is written whatever the store's tapback
# history. Without this line the arm asserts an empty lookup on a row with no gate.
gate_written DIVE-9005 \
  && ok_t "the --tier=2 gate was actually FILED (so the next assert reads a real gate)" \
  || bad_t "--tier=2 approval was refused at filing" "the unrouted assert below would be vacuous: $OUT5"
[[ -z "$(reviewer_of DIVE-9005)" ]] \
  && ok_t "an explicit --tier=2 approval is NOT routed (DIVE-1957 backstop still wins)" \
  || bad_t "--tier=2 approval routed to '$(reviewer_of DIVE-9005)'" "$OUT5"

# --- 6. INHERITED EXCLUSION: the T2 category floor (money) ----------------------
seed DIVE-9006 "$PR_REF"
actor_seam_as dev
OUT6=$(cmd_task_need DIVE-9006 --type=approval --ask="approve the \$5,000 invoice and pay it from the company card" --recommend="yes" --from=dev 2>&1)
[[ "$(tier_of DIVE-9006)" == "2" ]] \
  && ok_t "a money ask still floors to tier 2" \
  || bad_t "money ask tiered to '$(tier_of DIVE-9006)'" "the floor is what case 6 leans on; without it the next assert is vacuous"
[[ -z "$(reviewer_of DIVE-9006)" ]] \
  && ok_t "a money-floored approval is NOT routed — it stays the human's" \
  || bad_t "a money-floored approval routed to '$(reviewer_of DIVE-9006)'" "$OUT6"

# --- 7. OUT OF TYPE: `secret` must never become agent-clearable ------------------
seed DIVE-9007 "$PR_REF"
actor_seam_as dev
OUT7=$(cmd_task_need DIVE-9007 --type=secret --ask="paste the new API credential for the mailer" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9007)" ]] \
  && ok_t "a secret gate is NOT routed (the fix is scoped to approval, and CLAUDE.md is explicit)" \
  || bad_t "a secret gate routed to '$(reviewer_of DIVE-9007)'" "$OUT7"

# --- 8. TYPE PARITY: `manual` follows the BINDING, exactly as it already does ----
# Measured on origin/main in a control worktree, 2026-08-17: a BRANCH-bound `manual`
# gate already routes to the lead — DIVE-3266 put `manual` in the row-state type set
# and shipped it. So the second binding must not carve `manual` out: doing that would
# make the SAME gate route or not route depending on which of two structured bindings
# the row happens to carry, which is the "two copies of one predicate that can
# disagree" shape this whole ticket is trying to remove. The binding is the input.
#
# What must hold instead is the ABSENCE property, and that is what this grades: a
# `manual` gate on a row with nothing bound stays the human's. `secret` (case 7) is
# the type that is genuinely out — it is not in the row-state type set at all.
seed DIVE-9008
actor_seam_as dev
OUT8=$(cmd_task_need DIVE-9008 --type=manual --ask="$PLAIN_ASK" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9008)" ]] \
  && ok_t "an UNBOUND manual gate is not routed — absence still keeps it human" \
  || bad_t "an unbound manual gate routed to '$(reviewer_of DIVE-9008)'" "$OUT8"

seed DIVE-9018 "$PR_REF"
actor_seam_as dev
OUT8B=$(cmd_task_need DIVE-9018 --type=manual --ask="$PLAIN_ASK" --from=dev 2>&1)
[[ "$(reviewer_of DIVE-9018)" == "main" ]] \
  && ok_t "a delivery-bound manual routes, at PARITY with the branch-bound one main already routes" \
  || bad_t "a delivery-bound manual did not route" "the two bindings disagree about the same type: $OUT8B"

# --- 9. NO NEW SEAT: a filer the chart cannot route still reaches the human ------
# main is the root — `_gate_route_reviewer` skips any candidate equal to the filer,
# so the walk falls off the end empty. The fix resolves its target through that same
# walk, so it must add nobody here. (DIVE-3171's sealed standing-lead covers the
# tier-1 slice of this case and is not in scope: no constitution is sealed in this
# store, so the fallback declines and the gate is the human's, as designed.)
seed DIVE-9009 "$PR_REF"
actor_seam_as main
OUT9=$(cmd_task_need DIVE-9009 --type=approval --ask="$PLAIN_ASK" --recommend="go" --from=main 2>&1)
[[ -z "$(reviewer_of DIVE-9009)" ]] \
  && ok_t "an approval filed by the chart ROOT is still unrouted — the fix adds no reachable seat" \
  || bad_t "a root-filed approval routed to '$(reviewer_of DIVE-9009)'" "$OUT9"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
