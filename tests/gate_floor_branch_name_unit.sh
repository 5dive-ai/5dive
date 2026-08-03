#!/usr/bin/env bash
# DIVE-2629 isolated unit harness: the tier-2 category floor must grade the ACTION
# a gate authorises, not the SUBJECT MATTER named in a git branch name.
#
# THE DEFECT (measured by main 2026-08-03, reproduced verbatim in T1/T2 below).
# 'approve delegated push for review of branch dive-2613-teardown-outcomes-hetzner-only'
# floored to tier 2 on the single word 'teardown', which appears ONLY inside the
# branch name. Delete that one token from the same sentence and it drops to tier 1;
# add it to an unrelated branch name and that one floors too. The action being
# authorised is "push a feature branch to a remote for review" — inert, reversible,
# destroys nothing.
#
# WHY THIS IS NOT "one extra human tap", which is the floor's usual accepted cost.
# A tier-2 approval carries NO routed_reviewer, and cmd_task_answer's
# designated-reviewer exception requires actor == routed_reviewer, so once floored
# NO agent can ever clear it — not the filer, not their lead, not the coordinator.
# It is a RATCHET: permanently the human's, with no agent action that hands it
# back. DIVE-2613 sat there while dev2 stayed blocked behind it.
#
# T3-T8 ARE THE ARM THAT MATTERS, and they are the reason this file is not just
# "assert the false positive is gone". A suite that only asserts T1/T2 is satisfied
# by DELETING 'teardown' from the floor, or by exempting every push ask wholesale —
# both of which would let a genuinely destructive or spend-bearing ask through. T3
# fails against a wholesale "push asks are never floored" implementation. T5 fails
# against redacting every hyphenated word rather than branch-SHAPED tokens. T6
# fails against exempting the whole _gate_eng_ship_hit class instead of the inert
# push-for-review subset.
#
# MUTATION GRADE (all five run, all five go red where stated):
#   M1  remove the `if _gate_push_for_review_hit` block from _gate_tier2_floor_hit
#       -> T1/T2 red (the fix is gone).
#   M2  drop the _GATE_PUSH_NOT_INERT_RX check from _gate_push_for_review_hit
#       -> T6 red (a merge/deploy ask would inherit the exemption).
#   M2b write the not-inert destination clause as the ADJACENT `push to (main|...)`
#       instead of `\bto\b … (main|master|prod)` -> T6f/T6g red. This is the one
#       the fix got WRONG on first writing, and T6f is the live DIVE-1940 ask that
#       caught it: an adjacent pattern cannot see a repo name sitting between the
#       verb and its destination ("push branch X to 5dive-frontend MAIN").
#   M3  redact every token containing a hyphen (drop the slug-shape test)
#       -> T5 red ('auto-teardown' in prose would stop flooring).
#   M4  omit the mirrored redaction in _gate_tier2_floor_term
#       -> T7 red (the helper reports a term the floor did not use).
#
# PRE-LAND CORPUS SWEEP (main's condition on the ticket: "how many rows are floored
# this way, and would any legitimately-destructive gate be downgraded"). Ran
# _gate_floor_axis over all 435 gate rows in the live store (tasks + gate_history),
# old code vs new. THREE change, all `ask` -> `title` — meaning they become
# LEAD-ROUTED with floored_by=title, not unfloored: DIVE-2613 and DIVE-2034 (both
# `…-teardown-…` in the branch name, both inert push-or-PR asks) and DIVE-2068
# (`…-secret-gate-shipflag`). The 2068 variant that says "Open PR + MERGE" is NOT
# among them — it still floors, which is M2's guard doing its job on real data.
# A fourth row, DIVE-1940, changed on the first draft and does NOT change now; it
# is T6f.
#
# TIER: core — 0.6s measured on the 5dive control-plane host (bash, no root, no
# network): source-and-call only, no DB writes beyond tasks_db_init.
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched. Run:
#   bash tests/gate_floor_branch_name_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-floor-branch-name-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

no_floor() {  # <label> <text> -- asserts the floor does NOT fire
  if _gate_tier2_floor_hit "$2"; then
    bad_t "$1" "floored on term='$(_gate_tier2_floor_term "$2")' -- text: $2"
  else
    ok_t "$1"
  fi
}
floors() {    # <label> <text> -- asserts the floor DOES fire
  if _gate_tier2_floor_hit "$2"; then
    ok_t "$1 (term='$(_gate_tier2_floor_term "$2")')"
  else
    bad_t "$1" "did NOT floor -- text: $2"
  fi
}

# --- T1: main's MEASURED pair. The two that floored are the defect; the two that
#     did not are the control, and they must be UNCHANGED by this fix. -----------
no_floor "T1a teardown in the branch name no longer floors" \
  'approve delegated push for review of branch dive-2613-teardown-outcomes-hetzner-only'
no_floor "T1b same ask without 'teardown' is unchanged (control)" \
  'approve delegated push for review of branch dive-2613-outcomes-hetzner-only'
no_floor "T1c teardown grafted onto an unrelated branch no longer floors" \
  'approve delegated push for review of branch dive-XXXX-teardown-foo'
no_floor "T1d unrelated branch is unchanged (control)" \
  'approve delegated push for review of branch dive-2592-budget-variance'

# --- T2: the same exemption across the other ways a push ask is phrased, and
#     across the other destructive terms a branch name plausibly carries. --------
no_floor "T2a push-for-review, delete in the slug" \
  'approve push-for-review of branch dive-2700-delete-orphan-rows'
no_floor "T2b 5dive push, purge in the slug" \
  'please approve 5dive push for branch feat/purge-stale-cache'
no_floor "T2c branch slug with a trailing period" \
  'approve delegated push for review of branch dive-2613-teardown-outcomes.'
no_floor "T2d slug with two hyphens and no ticket prefix" \
  'approve delegated push for review of branch fix-token-refresh-loop'

# --- T3: THE ASK'S OWN PROSE IS STILL READ. A push gate that ALSO names money, a
#     secret, or a publish is a human call and must still floor. This arm fails
#     against a wholesale "push asks are never floored" exemption. ---------------
floors "T3a push ask that also names a spend" \
  'approve delegated push for review of branch dive-2613-foo, and approve $500 for the ads run'
floors "T3b push ask that also rotates a credential" \
  'approve delegated push for review of branch dive-2613-foo and provision a new api key'
floors "T3c push ask that also publishes" \
  'approve delegated push for review of branch dive-2613-foo then publish the launch post'
floors "T3d push ask that also emails customers" \
  'approve delegated push for review of branch dive-2613-foo and email customers about it'

# --- T4: a genuinely destructive ask that is NOT a push-for-review is untouched. -
floors "T4a bare teardown ask still floors" \
  'approve the teardown of the hetzner box'
floors "T4b delete ask still floors" \
  'confirm we delete the orphaned agent accounts'
floors "T4c the word branch alone buys no exemption" \
  'approve the branch teardown of the staging fleet'

# --- T5: HYPHENATED PROSE IS NOT A BRANCH NAME. One hyphen and no ticket prefix
#     is how English compounds are written, so the floor STAYS ON. Fails against
#     "redact every hyphenated token". ------------------------------------------
floors "T5a auto-teardown in prose still floors" \
  'approve delegated push for review of the auto-teardown fix'
floors "T5b re-publish in prose still floors" \
  'approve delegated push for review of the re-publish path'

# --- T6: NOT THE WHOLE ENG-SHIP CLASS. merge / deploy / roll-to-fleet / push-to-
#     main TOUCH PROD and keep flooring on their subject matter. Fails against an
#     exemption keyed on _gate_eng_ship_hit. ------------------------------------
floors "T6a push for review THEN merge to main is not inert" \
  'approve delegated push for review of branch dive-2613-teardown-outcomes then merge to main'
floors "T6b deploy is not inert" \
  'approve deploy of branch dive-2613-teardown-outcomes-hetzner-only'
floors "T6c roll to the fleet is not inert" \
  'approve delegated push for branch dive-2613-teardown-foo and roll to the fleet'
floors "T6d push to prod is not inert" \
  'approve push to prod of branch dive-2613-teardown-foo'
# T6f/T6g are the REAL DIVE-1940 ask, verbatim from the live corpus, and they are
# the arm the fix failed on first writing: an adjacent `push to main` pattern
# cannot see a repo name between the verb and the destination. Caught by the
# pre-land sweep, not by the ticket. Commit sha is a public repo ref, not PII.
floors "T6f push to a REPO's main is not inert (DIVE-1940, verbatim)" \
  'Push branch dive-1940-token-ux @ 3d9851a0 to 5dive-frontend main? I have no push creds; the work is built and verified.'
floors "T6g push to master is not inert" \
  'approve delegated push of branch dive-2613-teardown-foo to the app repo master'
if _gate_eng_ship_hit 'approve deploy of branch dive-2613-teardown-outcomes-hetzner-only'; then
  ok_t "T6e the T6b text IS eng-ship, so T6b proves the exemption is narrower than eng-ship"
else
  bad_t "T6e T6b text is eng-ship" "classifier changed; T6b no longer discriminates"
fi

# --- T7: the reporter must never name a term the floor did not use. -------------
_t7=$(_gate_tier2_floor_term 'approve delegated push for review of branch dive-2613-teardown-outcomes-hetzner-only')
if [[ -z "$_t7" ]]; then
  ok_t "T7 _gate_tier2_floor_term reports nothing where the floor does not fire"
else
  bad_t "T7 floor_term agrees with the floor" "reported '$_t7' for a text that does not floor"
fi
_t7b=$(_gate_tier2_floor_term 'approve the teardown of the hetzner box')
if [[ "$_t7b" == "teardown" ]]; then
  ok_t "T7b floor_term still names the term on a real hit"
else
  bad_t "T7b floor_term names the term" "expected 'teardown', got '$_t7b'"
fi

# --- T8: the redactor itself. Shape classification, and no cwd globbing. --------
for _s in 'dive-2613-teardown-foo' 'feat/purge-cache' 'a-b-c' 'dive-2613'; do
  _gate_branch_slug_token "$_s" \
    && ok_t "T8 '$_s' reads as a branch ref" \
    || bad_t "T8 '$_s' reads as a branch ref" "not classified as a slug"
done
for _s in 'auto-teardown' 'teardown' 're-publish' 'e-mail'; do
  if _gate_branch_slug_token "$_s"; then
    bad_t "T8 '$_s' is NOT a branch ref" "wrongly classified as a slug"
  else
    ok_t "T8 '$_s' is NOT a branch ref"
  fi
done
_g=$(cd "$TMP" && touch zz-glob-canary.txt && _gate_redact_branch_refs 'approve branch dive-1-a *')
case "$_g" in
  *zz-glob-canary*) bad_t "T8 redactor does not glob against the cwd" "expanded: $_g" ;;
  *)                ok_t  "T8 redactor does not glob against the cwd" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
