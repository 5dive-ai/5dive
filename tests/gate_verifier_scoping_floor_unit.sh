#!/usr/bin/env bash
# core (the default — no TIER marker). The two corpus numbers are different runs and
# both belong here, because quoting either alone reads as a contradiction:
#   198 harnesses / 237s  — core WITHOUT this file (the first draft carried a
#                           `# TIER: nightly` marker, so the run excluded it)
#   199 harnesses / 243s  — core WITH it, which is the number that decides the tier
# 243s is 81% of the 300s budget, so it fits. This file itself: 6.4s in that run's
# own slowest-ten table; 8.2s when olivia re-measured it in a detached worktree at
# review. Quote the 8.2s — a budget argument should carry the slowest observation,
# not the friendliest, and the marker holds at either.
#
# The first draft's `# TIER: nightly` was copied from the sibling
# gate_internal_ops_floor_unit.sh header, whose 9.9s measures THAT file and not this
# one. CLAUDE.md is explicit that demotion is the third way out and must be argued in
# the diff; a marker inherited by copy-paste is exactly the refusal that rule names.
#
# DIVE-2012 isolated unit harness: the VERIFIER-SCOPING dead-end.
#
# THE SHAPE. The maker of a live maker→verifier loop files a `decision` gate asking
# the VERIFIER to scope that task's own acceptance criteria. The ask narrates the
# work under test, the T2 category floor fires on the narration, and the gate goes
# to tier 2 — at which point DIVE-1495's verifier-route (guarded on `tier != 2`)
# never runs, routed_reviewer stays NULL, and the DIVE-1117 provenance floor refuses
# the verifier's answer. The human is pinged for a call that was never theirs AND
# the one agent who could answer is locked out. (DIVE-1968, 2026-07-25: dev's remedy
# was to message olivia out of band.)
#
# WHAT THIS HARNESS GRADES, and the split matters:
#   arms 1-2   the defect still reproduces at the TIER/ROUTE level, and is NOT
#              being silently "fixed" by a tier change this ticket did not make
#   arms 3-5   the supported remedy (--discusses, DIVE-2089) lands on the VERIFIER
#              rather than the lead, because the verifier-route runs after every
#              downgrade class. This is the load-bearing claim behind shipping a
#              warning instead of a sixth downgrade class.
#   arms 6-8   THE FIX: the dead-end is announced, names the verifier, and names
#              the flag — and does NOT fire on any of the shapes it must not.
#   arms 9-10  THE SECOND FIX: an appeal refusal names the surviving floor term
#              (it read $_dd_residual, a variable DIVE-2224 deleted, so it printed
#              `matched ''` and raised unbound-variable).
#   arms 11-13 SAFETY: money / an explicit --tier=2 / a non-loop task are untouched.
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR, never the live board. Run: bash tests/gate_verifier_scoping_floor_unit.sh
# (no root, no network).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source. No `2>/dev/null` — that also
# swallows the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; TIER and ROUTING read the uid derivation, so an
# arm impersonating a filer must DERIVE as them. tests/lib/actor_seam.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-vfscope-unit.XXXXXX)"
# DIVE-2190: this harness has no `set -e`, but `fail()` exits the whole script, so a
# refusal inside any cmd_* call would end the run with the last line on screen being
# an `ok` and NO summary — a red that looks like a pass that stopped early.
SUMMARY_PRINTED=0
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_verifier_scoping_floor_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&2' EXIT

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

# DIVE-2011: stub the HUMAN deliverer, not the wrapper — task_need_notify is the
# shared entry point for BOTH rails, so stubbing it would report a human ping that
# never happened and suppress the route send these arms assert on.
HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
ERR="$TMP/err.txt"
reset()    { HUMAN_PINGED=0; : >"$ROUTE_FILE"; : >"$ERR"; }
route_to() { local i; for i in $(seq 1 12); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; tail -n1 "$ROUTE_FILE" 2>/dev/null; }
tierof()   { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
routedof() { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
warned()   { grep -qF -- "$1" "$ERR"; }
# MUTATION-DRIVEN, and the reason is worth keeping. A bare `warned "matched 'spend'"`
# on the appeal-refusal arm PASSED against a mutant that restored the `$_dd_residual`
# bug — because the DIVE-2012 dead-end warning fires on the same gate and names the
# same term, so the assertion was satisfied by the wrong writer. Two lines on stderr
# can carry one substring; grade the LINE that is supposed to carry it.
warned_on() { grep -F -- "$1" "$ERR" | grep -qF -- "$2"; }

# Org chart: main is the lone coordinator; dev reports to main; olivia is a
# top-of-org verifier. reviewer(dev)=main, so an arm that routed to the LEAD
# instead of the verifier is visibly different from one that routed correctly.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('olivia',NULL,'verifier');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# A LIVE maker→verifier loop: maker=dev holds it, verifier=olivia grades it.
seedloop() { db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations)
                 VALUES('$1','gate delivery telemetry','todo','olivia','${2:-dev}','olivia','${2:-dev}',1,3);"; }
# Same task WITHOUT a loop — the structural discriminator's negative control.
seedplain() { db "INSERT INTO tasks(ident,title,status,created_by,assignee)
                  VALUES('$1','gate delivery telemetry','todo','olivia','dev');"; }

# The ticket's own ask shape: a criteria-scoping question for the verifier whose
# only floor term ('secret') is NARRATION of the subsystem under test.
SCOPE_ASK="Does acceptance criterion 3 require covering the secret-drop delivery path, or is the fence enough for this iteration?"

# --- 1: THE REPRO — floored, human pinged, routed_reviewer NULL ---------------
reset; seedloop DIVE-921
actor_seam_as dev; cmd_task_need DIVE-921 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-921)" == "2" ]] && ok_t "repro: verifier-scoping ask floors to tier 2" || bad_t "repro tier 2" "got '$(tierof DIVE-921)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "repro: the paired human is pinged for a call that was never theirs" || bad_t "repro human pinged" "HUMAN_PINGED=$HUMAN_PINGED"

# --- 2: the OTHER half — the designated answerer is locked out ---------------
# routed_reviewer NULL is exactly what leaves the verifier with no standing: the
# DIVE-1117 provenance floor refuses a non-human answer on a tier-2 gate, and the
# designated-reviewer exception it would otherwise take is keyed on this column.
[[ -z "$(routedof DIVE-921)" ]] && ok_t "repro: routed_reviewer NULL — the verifier has no standing to answer" || bad_t "repro routed NULL" "got '$(routedof DIVE-921)'"

# --- 3-5: THE REMEDY LANDS ON THE VERIFIER, not the lead ---------------------
# Load-bearing for shipping a warning rather than a sixth downgrade class: if the
# appeal routed to main (the lead) this fix would be pointing at the wrong door.
reset; seedloop DIVE-922
actor_seam_as dev; cmd_task_need DIVE-922 --type=decision --from=dev \
  --discusses="scoping my own acceptance criteria with the verifier; no secret is handled here" \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-922)" == "1" ]] && ok_t "remedy: --discusses downgrades the floored scoping gate to tier 1" || bad_t "remedy tier 1" "got '$(tierof DIVE-922)'"
[[ "$(routedof DIVE-922)" == "olivia" ]] && ok_t "remedy: routed_reviewer=olivia (the VERIFIER, not lead main)" || bad_t "remedy routed olivia" "got '$(routedof DIVE-922)'"
[[ "$HUMAN_PINGED" == "0" && "$(route_to)" == "olivia" ]] && ok_t "remedy: human NOT pinged; the handoff send went to olivia" || bad_t "remedy no human ping" "HUMAN_PINGED=$HUMAN_PINGED route=$(route_to)"

# --- 6-7: THE FIX — the dead-end announces itself and names both the verifier
#          and the flag. Asserted on CONTENT, not on "a warning appeared": a
#          message that fires but names the lead would be worse than silence.
reset; seedloop DIVE-923
actor_seam_as dev; cmd_task_need DIVE-923 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
# Pin the TARGET, not merely the presence of the name: a mutant that advised
# re-filing to "the lead" survived an assertion that only required 'olivia' to
# appear somewhere in the message, because the message names the verifier twice.
# NOTE the quoting: `warned_on "..." -- "--discusses"` puts the `--` in $2, so the
# second grep searched for "--" and matched almost anything. warned_on already
# passes -- to grep itself; the needle goes in $2 unadorned.
warned_on "CANNOT clear it" "routes it to olivia" && warned_on "CANNOT clear it" '--discusses="<why>"' \
  && ok_t "fix: the advice names the VERIFIER as the re-file target and names the flag" \
  || bad_t "fix names verifier + flag" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"
warned_on "CANNOT clear it" "matched 'secret'" \
  && ok_t "fix: the warning names the floor term that actually fired ('secret')" \
  || bad_t "fix names the term" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 8: NEGATIVE CONTROL — the warning must not fire when the appeal APPLIED.
#        Re-uses arm 3's gate: a downgraded gate is already routed to the verifier,
#        so advising a re-file there would be noise pointing at a solved problem.
reset; seedloop DIVE-924
actor_seam_as dev; cmd_task_need DIVE-924 --type=decision --from=dev \
  --discusses="scoping my own acceptance criteria with the verifier" \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
! warned "CANNOT clear it" \
  && ok_t "no-op: a successfully appealed gate gets no dead-end warning" \
  || bad_t "no-op appealed gate silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 9-10: THE SECOND FIX — an appeal REFUSAL names the surviving term.
#           Before this change the line read $_dd_residual (deleted by DIVE-2224),
#           so it printed `matched ''` and raised unbound-variable under set -u.
#           Arm 10 is the non-vacuity arm: it asserts the refusal is not merely
#           quiet but names the MONEY term, which is the one that survived.
reset; seedloop DIVE-925
actor_seam_as dev; cmd_task_need DIVE-925 --type=decision --from=dev \
  --discusses="just a design discussion" \
  --ask="Should we spend \$500 on the ads test before grading criterion 3?" \
  --options="yes|no" --recommend="no" 2>"$ERR" >/dev/null
! warned "_dd_residual" \
  && ok_t "refusal: no unbound-variable error naming _dd_residual" \
  || bad_t "refusal no unbound var" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"
# On the REFUSAL line specifically — see warned_on. The DIVE-2012 dead-end warning
# fires on this same gate and also names 'spend', so a file-wide grep here graded
# the wrong writer and passed against the restored bug.
warned_on "discusses REFUSED" "matched 'spend'" \
  && ok_t "refusal: the REFUSAL line names the surviving term ('spend'), not ''" \
  || bad_t "refusal names term" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 11: SAFETY — a genuine money ask on a loop stays hard-human and gets NO
#         dead-end advice. The advice must never read as "one flag and this
#         reaches an agent" on the one class that may not.
[[ "$(tierof DIVE-925)" == "2" && "$(routedof DIVE-925)" == "" ]] \
  && ok_t "safety: money ask on a loop stays tier 2, unrouted (human keeps the call)" \
  || bad_t "safety money tier 2" "tier=$(tierof DIVE-925) routed='$(routedof DIVE-925)'"

# --- 12: SAFETY — an EXPLICIT --tier=2 is the caller's hard-human contract
#         (DIVE-1957). No advice, because there is nothing to appeal.
reset; seedloop DIVE-926
actor_seam_as dev; cmd_task_need DIVE-926 --type=decision --from=dev --tier=2 \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-926)" == "2" ]] && ! warned "CANNOT clear it" \
  && ok_t "safety: explicit --tier=2 stays hard-human and gets no appeal advice" \
  || bad_t "safety pinned tier 2 silent" "tier=$(tierof DIVE-926) stderr: $(tr '\n' ' ' <"$ERR" | tail -c 200)"

# --- 13: STRUCTURAL DISCRIMINATOR — no loop on the task, no advice. This is the
#         arm that proves the trigger is the LOOP and not the vocabulary: byte
#         identical ask to arm 6, and it must stay silent.
reset; seedplain DIVE-927
actor_seam_as dev; cmd_task_need DIVE-927 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-927)" == "2" ]] && ! warned "CANNOT clear it" \
  && ok_t "discriminator: identical ask on a NON-loop task floors silently (trigger is the loop)" \
  || bad_t "discriminator non-loop silent" "tier=$(tierof DIVE-927) stderr: $(tr '\n' ' ' <"$ERR" | tail -c 200)"

# --- 14: SELF-ROUTE — the VERIFIER filing on their own loop is not their own
#         answerer, so there is nobody to advise them to reach.
reset; seedloop DIVE-928 olivia
actor_seam_as olivia; cmd_task_need DIVE-928 --type=decision --from=olivia \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
! warned "CANNOT clear it" \
  && ok_t "self-route: the verifier's own gate gets no advice to reach themselves" \
  || bad_t "self-route silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

echo
echo "gate verifier-scoping floor: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ $FAIL -eq 0 ]]
