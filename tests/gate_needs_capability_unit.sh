#!/usr/bin/env bash
# TIER: nightly — 18.0s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2241 isolated unit harness for the DECLARED human-class capability
# (`5dive task need --needs=<capability>`).
#
# THE DEFECT. A gate filed on a verifier-loop task routes to the VERIFIER by kind
# (DIVE-1495) regardless of what is being ASKED — so an approval that needs a
# PERSON lands on whichever agent happens to be grading the ticket. Three
# instances in 36h across three agents (dev3/DIVE-2084, main/DIVE-2146, olivia
# immediately after). The fix: a filer may DECLARE the capability the ask
# consumes, and exactly three names (human_tap / spend_authority /
# secret_provision) resolve to the paired human as CONSTANTS.
#
# WHY EVERY CASE IS PAIRED. "The human_tap gate reached the human" is not
# evidence on its own — it is also what a box with no verifier, a broken org
# chart or an unroutable gate looks like. Each declared arm is therefore run
# against a CONTROL gate filed on the SAME task, by the same filer, at the same
# type, differing ONLY in the flag. The control must route to the verifier. That
# is what makes the pass mean "the routing CHANGED" rather than "routing exists".
#
# THE MUTATION ARM (case 6) is the same requirement one level down: with the
# constant resolution removed (_gate_needs_human stubbed to recognise nothing),
# the human_tap case must go RED — i.e. it must route to the verifier like any
# other gate — while the control stays green. Without it, every assertion here
# would also pass on a build where --needs is silently ignored and something else
# happens to keep the gate off the verifier.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR, FIVEDIVE_GATE_NOTIFY_LOG at a temp file so no prod telemetry is
# touched. Run: bash tests/gate_needs_capability_unit.sh (no root, no network).
#
# ENV NOTE (DIVE-2007): a resolver reading the ambient identity behaves
# differently on a CI runner ($USER=runner) than on a dev box ($USER=agent-*).
# Repro the runner shape before pushing:
#   env -u SUDO_USER -u SUDO_UID USER=runner bash tests/gate_needs_capability_unit.sh
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh) — a
# green log from a stale checkout and a green log from origin/main are otherwise
# byte-identical. Sourced BEFORE the cd, from BASH_SOURCE, so the tree named is the
# one this FILE lives in rather than whatever $PWD happened to be.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; TIER/ROUTING read the uid derivation, so an arm
# impersonating a filer must DERIVE as them. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-needs-capability-unit.XXXXXX)"

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

# WHICH RAIL DID THIS GATE TAKE is read off the ok() line the operator actually
# sees — "needs a human" vs "routed to <agent> for <role> review" — plus the agent
# send log. Deliberately NOT off a stubbed deliverer: on an unpaired harness box
# the human ping legitimately ends UNNOTIFIED (rc=3), so "the human was pinged" is
# not observable here, while "this gate was addressed to the human and to no
# agent" is, and is the property under test.
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }

# `5dive` as a shell function: shadows the real binary and records every agent
# send, which is the routed rail's only observable side effect here.
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() {
  if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then
    printf '%s\n' "${3:-}" >>"$ROUTE_FILE"
  fi
  return 0
}

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('olivia','main','qa');"

# Seed a task carrying a LIVE maker→verifier loop: dev is the maker, olivia the
# verifier. This is the exact shape the defect was reported on — without
# maker_agent + verifier the verifier-route never engages and the control arm
# would pass vacuously.
seed_loop() {
  db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent)
      VALUES('$1',$(sqlq "${2:-a routine ticket}"),'todo','main','dev','olivia','dev');"
}
reset_log() { : >"$NOTIFY_LOG"; : >"$ROUTE_FILE"; : >"$AUDIT_LOG_FILE"; }
reviewer_of() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
tier_of()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
declared_of() { db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE ident='$1';"; }
JSON_MODE=0

# --- 0. the sealed list is a list, and it does not match by prefix -----------
# The resolver is a whitespace-fenced substring test; a prefix hit would let
# `human_tap_delegate` inherit the human's authority by naming itself close to it.
_gate_needs_human human_tap        && ok_t "human_tap resolves human-class"        || bad_t "human_tap resolves"
_gate_needs_human spend_authority  && ok_t "spend_authority resolves human-class"  || bad_t "spend_authority resolves"
_gate_needs_human secret_provision && ok_t "secret_provision resolves human-class" || bad_t "secret_provision resolves"
_gate_needs_human human_tap_delegate && bad_t "a PREFIX of a constant must not resolve" "human_tap_delegate matched" \
  || ok_t "a prefix/extension of a constant does NOT resolve (human_tap_delegate)"
_gate_needs_human human            && bad_t "a substring of a constant must not resolve" "human matched" \
  || ok_t "a substring of a constant does NOT resolve (human)"
_gate_needs_human delegated_push   && bad_t "an AGENT capability must not resolve human" "delegated_push matched" \
  || ok_t "an agent capability (delegated_push) does NOT resolve human — out of scope, not mis-scoped"
_gate_needs_human ""               && bad_t "empty must not resolve" "empty matched" \
  || ok_t "an EMPTY declaration does not resolve (absent == undeclared, never non-holding)"

# --- 0b. the near-miss class: a typo must not silently WEAKEN the gate --------
# Exact matching made `--needs=human-tap` fall through to a tier-1, agent-clearable,
# TTL-auto-appliable gate while the filer believed they had secured a human — and the
# warn that says so goes to whoever ran the command, which for a headless agent filing
# programmatically is nobody. Normalising case + separator kills the whole class; edit
# distance is deliberately NOT attempted (a resolver that guesses is a new thing to be
# wrong about, and this one decides whether a human is required).
for v in human-tap HUMAN_TAP Human_Tap HUMAN-TAP spend-authority SECRET-PROVISION; do
  _gate_needs_human "$v" && ok_t "near-miss '$v' normalises to a human-class constant" \
    || bad_t "near-miss '$v' resolves" "a typo must not silently weaken the gate"
done
# Normalisation must not become a wildcard: it maps case and separator, nothing else.
for v in humantap human__tap human_tap_x spend_author; do
  _gate_needs_human "$v" && bad_t "normalisation over-reaches on '$v'" "matched a name that is not one of the three" \
    || ok_t "'$v' still does NOT resolve — normalisation maps case+separator, it does not guess"
done

# --- 1. CONTROL: no --needs on a verifier-loop task still routes to the verifier
# Filed FIRST so a later human-arm pass cannot be read as "this box never routes".
reset_log; seed_loop DIVE-9001
OUT_C=$(cmd_task_need DIVE-9001 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --from=dev 2>"$TMP/e_c")
RC_C=$?
[[ "$(reviewer_of DIVE-9001)" == "olivia" ]] \
  && ok_t "CONTROL (no --needs): gate routes to the verifier olivia — the pre-existing behaviour is live here" \
  || bad_t "control routes to verifier" "routed_reviewer='$(reviewer_of DIVE-9001)' rc=$RC_C out=$OUT_C err=$(cat "$TMP/e_c")"
# DIVE-3474 arm 2: the routed handoff no longer WAKES olivia — it lands in her
# queue. The fact this control exists to pin is unchanged (the gate reached the
# agent rail and not the human), so it is graded on the rail that now carries it.
[[ ! -s "$ROUTE_FILE" ]] && ok_t "CONTROL: olivia's window was NOT woken (DIVE-3474: routed gates queue)" \
  || bad_t "control does not wake olivia" "route: $(cat "$ROUTE_FILE")"
grep -q 'DIVE-9001' <<<"$(cmd_task_queue --for=olivia --json 2>/dev/null)" \
  && ok_t "CONTROL: olivia was actually HANDED the gate — it is in her queue" \
  || bad_t "control queues to olivia" "queue: $(cmd_task_queue --for=olivia --json 2>/dev/null)"
grep -q 'routed to olivia for verifier review' <<<"$OUT_C" \
  && ok_t "CONTROL: the ok line says routed to olivia for verifier review — the human was not addressed" \
  || bad_t "control ok line names the verifier" "out: $OUT_C"

# --- 2. DECLARED human_tap on the SAME shape goes to the human instead --------
reset_log; seed_loop DIVE-9002
OUT_H=$(cmd_task_need DIVE-9002 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --needs=human_tap --from=dev 2>"$TMP/e_h")
RC_H=$?
[[ "$(reviewer_of DIVE-9002)" == "" ]] \
  && ok_t "DECLARED human_tap: NO routed_reviewer — the gate did not go to an agent" \
  || bad_t "human_tap clears routed_reviewer" "routed_reviewer='$(reviewer_of DIVE-9002)' rc=$RC_H err=$(cat "$TMP/e_h")"
grep -q '^olivia$' "$ROUTE_FILE" \
  && bad_t "human_tap must not send to the verifier" "route: $(cat "$ROUTE_FILE")" \
  || ok_t "DECLARED human_tap: the verifier was NOT sent this gate (the reported defect)"
grep -q 'needs a human' <<<"$OUT_H" \
  && ok_t "DECLARED human_tap: the ok line says the task needs a HUMAN (the human rail, positively)" \
  || bad_t "human_tap takes the human rail" "out: $OUT_H"
[[ "$(tier_of DIVE-9002)" == "2" ]] \
  && ok_t "DECLARED human_tap: tier is 2 — never TTL-auto-applies, never agent-clearable" \
  || bad_t "human_tap forces tier 2" "tier=$(tier_of DIVE-9002)"
[[ "$(declared_of DIVE-9002)" == "human_tap" ]] \
  && ok_t "the DECLARATION is on the record (needs_capability=human_tap), not merely in its effect" \
  || bad_t "declaration recorded" "needs_capability='$(declared_of DIVE-9002)'"
grep -q 'declared-capability.*declared=human_tap' "$AUDIT_LOG_FILE" \
  && ok_t "the declaration is audited at file time" || bad_t "declaration audited" "audit: $(cat "$AUDIT_LOG_FILE")"
grep -qi 'T2 category floor' <<<"$OUT_H$(cat "$TMP/e_h")" \
  && bad_t "a DECLARED gate must not be explained as a keyword-floor hit" "out: $OUT_H $(cat "$TMP/e_h")" \
  || ok_t "the operator is told it is hard-human by DECLARATION, not by the keyword floor"
grep -q 'discusses' <<<"$OUT_H$(cat "$TMP/e_h")" \
  && bad_t "a filer must not be invited to appeal their OWN declaration" "out: $(cat "$TMP/e_h")" \
  || ok_t "no --discusses appeal is offered against the filer's own declaration"

# --- 2b. the near-miss END TO END, not just at the resolver ------------------
# The resolver arms above would pass even if cmd_task_need never called it, so file
# a real gate with the hyphenated spelling on the verifier-loop shape.
reset_log; seed_loop DIVE-9020
OUT_N=$(cmd_task_need DIVE-9020 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --needs=human-tap --from=dev 2>"$TMP/e_n")
[[ "$(reviewer_of DIVE-9020)" == "" && "$(tier_of DIVE-9020)" == "2" ]] \
  && ok_t "--needs=human-tap (hyphenated) reaches the human end to end, not just in the resolver" \
  || bad_t "hyphenated declaration routes to the human" "reviewer='$(reviewer_of DIVE-9020)' tier=$(tier_of DIVE-9020) err=$(cat "$TMP/e_n")"
[[ "$(declared_of DIVE-9020)" == "human-tap" ]] \
  && ok_t "the record keeps what was TYPED (human-tap), not the normalised form — provenance is the declaration, not our reading of it" \
  || bad_t "record keeps the typed spelling" "needs_capability='$(declared_of DIVE-9020)'"

# --- 3. the other two constants behave identically ---------------------------
n=9010
for cap in spend_authority secret_provision; do
  reset_log; seed_loop "DIVE-$n"
  OUT_X=$(cmd_task_need "DIVE-$n" --type=decision --ask="pick option A or B" --options="A|B" --recommend="A" --needs="$cap" --from=dev 2>"$TMP/e_$n")
  if [[ "$(reviewer_of "DIVE-$n")" == "" && "$(tier_of "DIVE-$n")" == "2" ]] && grep -q 'needs a human' <<<"$OUT_X" \
     && ! grep -q '^olivia$' "$ROUTE_FILE"; then
    ok_t "--needs=$cap resolves to the human on a verifier-loop task (tier 2, unrouted, verifier not sent)"
  else
    bad_t "$cap resolves human" "reviewer='$(reviewer_of "DIVE-$n")' tier=$(tier_of "DIVE-$n") out=$OUT_X route=$(cat "$ROUTE_FILE")"
  fi
  # A decision defaults to tier 1 and is agent-clearable by TYPE; the declaration
  # is what makes it not. Prove the control for THIS type too, so the pass is not
  # inherited from case 1's approval arm.
  n=$((n+1)); reset_log; seed_loop "DIVE-$n"
  actor_seam_as dev; cmd_task_need "DIVE-$n" --type=decision --ask="pick option A or B" --options="A|B" --recommend="A" --from=dev >/dev/null 2>&1
  [[ "$(reviewer_of "DIVE-$n")" == "olivia" ]] \
    && ok_t "CONTROL for $cap's arm: the same decision without --needs still routes to the verifier" \
    || bad_t "decision control routes to verifier" "reviewer='$(reviewer_of "DIVE-$n")'"
  n=$((n+1))
done

# --- 4. FALL THROUGH, never refuse -------------------------------------------
# An unrecognised capability must file normally and route as it would have. A
# router that hard-fails on an unknown name turns a mis-declared gate into a
# STUCK one — strictly worse than the mis-route it was meant to prevent.
reset_log; seed_loop DIVE-9004
OUT_U=$(cmd_task_need DIVE-9004 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --needs=gh_push --from=dev 2>"$TMP/e_u")
RC_U=$?
[[ "$RC_U" == "0" ]] && ok_t "an UNRECOGNISED --needs does not refuse (rc=0) — a typo costs a re-file, not a block" \
  || bad_t "unrecognised needs does not refuse" "rc=$RC_U err=$(cat "$TMP/e_u")"
[[ "$(reviewer_of DIVE-9004)" == "olivia" ]] \
  && ok_t "an UNRECOGNISED --needs falls through to today's routing (still the verifier)" \
  || bad_t "unrecognised falls through" "routed_reviewer='$(reviewer_of DIVE-9004)'"
grep -qi 'not a human-class capability' "$TMP/e_u" \
  && ok_t "the fall-through is LOUD — the filer is told the flag changed nothing" \
  || ok_t "(advisory) fall-through warning text not matched — behaviour is still correct"
[[ "$(declared_of DIVE-9004)" == "gh_push" ]] \
  && ok_t "an unrecognised declaration is still RECORDED verbatim (a mis-declaration you cannot see is one you cannot correct)" \
  || bad_t "unrecognised declaration recorded" "needs_capability='$(declared_of DIVE-9004)'"

# --- 5. a downgrade KIND cannot pull a declared gate back to an agent ---------
# eng-ship (DIVE-1359) forces a ship-shaped approval down to a lead-routed tier-1
# regardless of tier. It classifies on the ask's SHAPE; a declaration states what
# the ask CONSUMES, and must outrank it. Without the re-assert this arm routes.
reset_log; seed_loop DIVE-9005 "land the branch"
actor_seam_as dev; cmd_task_need DIVE-9005 --type=approval --ask="approve the ship: merge and deploy the release branch to prod" --recommend="yes" --needs=human_tap --from=dev >/dev/null 2>"$TMP/e5"
[[ "$(reviewer_of DIVE-9005)" == "" && "$(tier_of DIVE-9005)" == "2" ]] \
  && ok_t "an eng-ship-shaped ask with --needs=human_tap is NOT downgraded to a lead-routed tier-1" \
  || bad_t "declaration outranks the eng-ship downgrade" "reviewer='$(reviewer_of DIVE-9005)' tier=$(tier_of DIVE-9005)"

# --- 6. MUTATION: remove the constant resolution, the human arm must go RED ---
# Differential by construction: the SAME two gates are re-filed against a build
# whose resolver recognises nothing. The human arm must now route to the verifier
# (red) while the control is unchanged (green). If the human arm still stayed off
# the verifier here, cases 2-3 would be passing for some reason other than the
# constant, and this whole file would be evidence of nothing.
# Capture the REAL resolver by reading the live definition, never by hand-copying
# its body: a transcribed copy is a snapshot that stops tracking the source the
# moment the source changes, and the restore would then hand every later arm a
# resolver that differs from production in exactly the way nobody re-reads.
# (This file already lost one round to that — the normalisation Marcus asked for
# on #288 would have been silently absent from the restored copy.)
eval "_gate_needs_human_REAL() $(declare -f _gate_needs_human | sed '1d')"
_gate_needs_human() { return 1; }                       # the removal
_gate_needs_human human_tap && bad_t "mutation did not land" "resolver still recognises human_tap" \
  || ok_t "MUTATION LANDED: the resolver now recognises nothing"

reset_log; seed_loop DIVE-9006
actor_seam_as dev; cmd_task_need DIVE-9006 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --needs=human_tap --from=dev >/dev/null 2>&1
[[ "$(reviewer_of DIVE-9006)" == "olivia" ]] \
  && ok_t "MUTATION: without the constant, --needs=human_tap routes to the VERIFIER — the arm is RED, so the green above was the constant's doing" \
  || bad_t "mutation turns the human arm red" "routed_reviewer='$(reviewer_of DIVE-9006)' — the human arm passes WITHOUT the resolution, so it proves nothing"

reset_log; seed_loop DIVE-9007
actor_seam_as dev; cmd_task_need DIVE-9007 --type=approval --ask="approve the merge of the parser refactor" --recommend="yes" --from=dev >/dev/null 2>&1
[[ "$(reviewer_of DIVE-9007)" == "olivia" ]] \
  && ok_t "MUTATION: the CONTROL is unaffected — the mutation is scoped to the declared path, not to routing at large" \
  || bad_t "mutation leaves the control green" "routed_reviewer='$(reviewer_of DIVE-9007)'"

# Restore, and prove the restore took, so a later addition to this file cannot
# silently run against the mutated build.
eval "$(declare -f _gate_needs_human_REAL | sed '1s/_gate_needs_human_REAL/_gate_needs_human/')"
_gate_needs_human human_tap && ok_t "resolver restored after the mutation arm" || bad_t "resolver restored"
# ...and restored to the PRODUCTION resolver, not to a weaker snapshot of it. A
# near-miss is the property most likely to be lost by a hand-copied restore, so it
# is the one asserted on.
_gate_needs_human human-tap && ok_t "the restored resolver is the production one (normalisation intact), not a stale transcription" \
  || bad_t "restore preserves normalisation" "the mutation arm restored a resolver that differs from production"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
