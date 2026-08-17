#!/usr/bin/env bash
# DIVE-3228 / DIVE-3525 isolated unit harness for the APPROVAL ROUTING DEFAULT.
#
# THE DEFECT. `_routable` already said YES for an unfloored `approval`, but that is
# only half the test: the routing cascade ALSO demanded one of the KIND flags or the
# `gate_builder_routing` pref, and that pref is OFF by default. So an ordinary ship
# approval whose ask missed `_GATE_ENG_SHIP_RX` was routable-and-unrouted —
# `routed_reviewer` NULL, which is the FIRST clause of cmd_task_inbox's human
# predicate. An unrouted gate IS a founder gate. lodar, 2026-08-11, on being pinged
# for DIVE-3225: "I still getting those".
#
# THE FIX. `approval` is a routing kind in its own right (`_approval_default`), so the
# TYPE routes it to the filer's chart lead instead of the ask's prose deciding.
#
# WHY EVERY POSITIVE ARM IS PAIRED WITH A CONTROL. "The approval routed to main" is
# also what a build with `gate_builder_routing=on`, a widened eng-ship regex, or a
# verifier loop looks like. So:
#   * A0 asserts the plain ask does NOT hit the eng-ship classifier. Without it,
#     case 1 would pass on a build where the fix does nothing and the regex grew.
#   * A0b asserts the pref really is off in this store.
#   * Case 0 is the UNCHANGED arm: the same plain ask as a `decision` stays unrouted,
#     because decision routing is still pref-gated. A "route everything" regression
#     passes every other case here and fails that one.
#   * Case 1b reads the trigger out of the ok() line: `approval-default` and not
#     `eng-ship`, so the arm names WHICH kind carried it rather than only that
#     something did.
# The remaining cases are the boundary, and all of them assert the gate does NOT
# reach an agent: the four exclusions the fix inherits from `_routable`, plus the
# two types (`secret`, `manual`) it deliberately does not cover, plus a filer the
# chart cannot route at all.
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

seed() { # <ident> [title]
  db "INSERT INTO tasks(ident,title,status,created_by,assignee)
      VALUES('$1',$(sqlq "${2:-a routine ticket}"),'todo','main','dev');"
}
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

# --- 0. UNCHANGED: an ordinary `decision` is still pref-gated and stays unrouted -
# The regression detector for "the fix routed everything". A decision is already
# agent-clearable by TYPE, so it was never the population that reached lodar.
seed DIVE-9000
actor_seam_as dev
cmd_task_need DIVE-9000 --type=decision --ask="$PLAIN_ASK" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
[[ -z "$(reviewer_of DIVE-9000)" ]] \
  && ok_t "an ordinary decision is UNCHANGED — still pref-gated, still unrouted" \
  || bad_t "a decision routed to '$(reviewer_of DIVE-9000)'" "the fix is scoped to approval and widened past it"

# --- 1. THE FIX: an ordinary approval routes to the filer's chart lead ----------
seed DIVE-9001
actor_seam_as dev
OUT1=$(cmd_task_need DIVE-9001 --type=approval --ask="$PLAIN_ASK" --recommend="go" --from=dev 2>&1)
[[ "$(reviewer_of DIVE-9001)" == "main" ]] \
  && ok_t "an ordinary approval routes to the filer's lead (main), not to the human" \
  || bad_t "approval routed to '$(reviewer_of DIVE-9001)', expected main" "$OUT1"
[[ "$(prov_of DIVE-9001)" == "chart" ]] \
  && ok_t "route_provenance is 'chart' — the org chart is still what resolved the NAME" \
  || bad_t "route_provenance is '$(prov_of DIVE-9001)', expected chart" "a new basis string would reach _gate_route_why's unknown arm"

# --- 1b. the receipt NAMES the kind, so this set is countable -------------------
[[ "$OUT1" == *"trigger=approval-default"* ]] \
  && ok_t "the ok() line names trigger=approval-default (not eng-ship) — the type carried it" \
  || bad_t "the ok() line does not name approval-default" "$OUT1"
[[ "$OUT1" == *"routed to main"* ]] \
  && ok_t "the operator's receipt says 'routed to main' rather than 'needs a human'" \
  || bad_t "the receipt does not say routed to main" "$OUT1"

# --- 2. UNCHANGED: an approval that DOES hit eng-ship still routes, as eng-ship --
seed DIVE-9002
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
  ident="DIVE-90$i"; seed "$ident"
  actor_seam_as dev
  OUTC=$(cmd_task_need "$ident" --type=approval --ask="$PLAIN_ASK" --recommend="go" --needs="$cap" --from=dev 2>&1)
  [[ -z "$(reviewer_of "$ident")" ]] \
    && ok_t "--needs=$cap keeps the approval on the human (routed_reviewer empty)" \
    || bad_t "--needs=$cap routed to '$(reviewer_of "$ident")'" "$OUTC"
  i=$((i+1))
done

# --- 5. INHERITED EXCLUSION: an EXPLICIT --tier=2 is the caller's hard contract --
seed DIVE-9005
actor_seam_as dev
OUT5=$(cmd_task_need DIVE-9005 --type=approval --tier=2 --ask="$PLAIN_ASK" --recommend="go" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9005)" ]] \
  && ok_t "an explicit --tier=2 approval is NOT routed (DIVE-1957 backstop still wins)" \
  || bad_t "--tier=2 approval routed to '$(reviewer_of DIVE-9005)'" "$OUT5"

# --- 6. INHERITED EXCLUSION: the T2 category floor (money) ----------------------
seed DIVE-9006
actor_seam_as dev
OUT6=$(cmd_task_need DIVE-9006 --type=approval --ask="approve the \$5,000 invoice and pay it from the company card" --recommend="yes" --from=dev 2>&1)
[[ "$(tier_of DIVE-9006)" == "2" ]] \
  && ok_t "a money ask still floors to tier 2" \
  || bad_t "money ask tiered to '$(tier_of DIVE-9006)'" "the floor is what case 6 leans on; without it the next assert is vacuous"
[[ -z "$(reviewer_of DIVE-9006)" ]] \
  && ok_t "a money-floored approval is NOT routed — it stays the human's" \
  || bad_t "a money-floored approval routed to '$(reviewer_of DIVE-9006)'" "$OUT6"

# --- 7. OUT OF TYPE: `secret` must never become agent-clearable ------------------
seed DIVE-9007
actor_seam_as dev
OUT7=$(cmd_task_need DIVE-9007 --type=secret --ask="paste the new API credential for the mailer" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9007)" ]] \
  && ok_t "a secret gate is NOT routed (the fix is scoped to approval, and CLAUDE.md is explicit)" \
  || bad_t "a secret gate routed to '$(reviewer_of DIVE-9007)'" "$OUT7"

# --- 8. OUT OF TYPE: `manual` is a thing only a person can physically do ---------
seed DIVE-9008
actor_seam_as dev
OUT8=$(cmd_task_need DIVE-9008 --type=manual --ask="$PLAIN_ASK" --from=dev 2>&1)
[[ -z "$(reviewer_of DIVE-9008)" ]] \
  && ok_t "a manual gate is NOT routed by this default" \
  || bad_t "a manual gate routed to '$(reviewer_of DIVE-9008)'" "$OUT8"

# --- 9. NO NEW SEAT: a filer the chart cannot route still reaches the human ------
# main is the root — `_gate_route_reviewer` skips any candidate equal to the filer,
# so the walk falls off the end empty. The fix resolves its target through that same
# walk, so it must add nobody here. (DIVE-3171's sealed standing-lead covers the
# tier-1 slice of this case and is not in scope: no constitution is sealed in this
# store, so the fallback declines and the gate is the human's, as designed.)
seed DIVE-9009
actor_seam_as main
OUT9=$(cmd_task_need DIVE-9009 --type=approval --ask="$PLAIN_ASK" --recommend="go" --from=main 2>&1)
[[ -z "$(reviewer_of DIVE-9009)" ]] \
  && ok_t "an approval filed by the chart ROOT is still unrouted — the fix adds no reachable seat" \
  || bad_t "a root-filed approval routed to '$(reviewer_of DIVE-9009)'" "$OUT9"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
