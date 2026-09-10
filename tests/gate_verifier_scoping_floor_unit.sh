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
# DIVE-2610: fd 8 is a dup of the REAL stderr, taken before any arm runs. The marker
# must NOT go to `>&2`: a refusal that exits from inside `cmd_x ... >/dev/null 2>&1`
# kills the shell while that redirect is live, so a trap printing to fd 2 lands in
# /dev/null and the truncation is silent again. Graded by tests/truncation_marker_guard_unit.sh.
exec 8>&2
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_verifier_scoping_floor_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: appends the HARNESS-RC line to this harness's pre-existing abort-backstop trap; trap stays where it was (TMP/SUMMARY_PRINTED/fd8 are all already live by this point) rather than moving to the top.

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
# DIVE-3474 arm 2: a routed gate QUEUES rather than waking the reviewer, so the
# seat it was handed to is read off the gate-delivery row (`chat=queue:<who>`, or
# `chat=agent:<who>` on the --urgent rail) instead of off the send stub. The
# property under test — WHICH seat, and human-vs-agent — is unchanged.
NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"
reset()    { HUMAN_PINGED=0; : >"$ROUTE_FILE"; : >"$NOTIFY_LOG"; : >"$ERR"; }
route_to() { local i; for i in $(seq 1 20); do grep -qE 'chat=(queue|agent):' "$NOTIFY_LOG" 2>/dev/null && break; sleep 0.05; done
             grep -oE 'chat=(queue|agent):[^ ]+' "$NOTIFY_LOG" 2>/dev/null | sed 's/.*://' | tail -n1; }
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

# ============================================================================
# DIVE-4175 arm C — DIVE-2012's DEFECT IS FIXED AT SOURCE, SO THE ARMS MOVED.
#
# The dead-end this file grades was: a scoping ask NARRATES the subsystem under
# test, the keyword floor fires on the narration, the gate goes to tier 2,
# DIVE-1495's verifier-route (guarded on `tier != 2`) never runs, routed_reviewer
# stays NULL, and the one agent who could answer is locked out while the human is
# paged for a call that was never theirs.
#
# Arm C deletes the promoter. The narration no longer promotes anything, so the
# verifier-route runs and the gate lands on the VERIFIER — which is the outcome
# DIVE-2012's whole apparatus (a warning plus a `--discusses` appeal) existed to
# reach by hand. Arms 1-2 therefore no longer assert the repro; they assert that
# the repro's ask now produces the destination, because a repro arm for a defect
# that cannot occur grades nothing.
#
# THE DEAD-END WARNING IS NOW UNREACHABLE BY CONSTRUCTION, and that is a proof
# rather than an observation. Its guard (need.sh:2513) requires
# `tier_floored==1 && type=="decision" && _needs_human==0 && tier_arg!="2"`. After
# arm C the only writers of `tier_floored=1` are `type==secret` (excluded by the
# `decision` clause), `--needs=<human capability>` (excluded by `_needs_human==0`),
# a pinned `--tier=2` (excluded by `tier_arg`), and the DIVE-2241 re-assert, which
# fires only when `_needs_human==1`. No input satisfies all four clauses. Every
# `! warned "CANNOT clear it"` arm below is therefore VACUOUSLY true now — they are
# kept because they were the safety arms and their prose still binds, but they can
# no longer distinguish anything, and each says so. The non-vacuous assertions are
# the routing ones.
#
# WHAT STILL HAS AN OBSERVABLE, measured here rather than assumed: the STRUCTURAL
# discriminator does (arms 13-14 — a loop routes to the verifier, a non-loop and a
# self-filed gate route to the lead), and the DECLARATION does (arm 11). What does
# NOT is DIVE-2089's `--discusses` appeal: arm 3's row is byte-identical to arm 1's,
# asserted as an equality in arm 3b. That is DIVE-4232's evidence, and the mechanism
# code is left in place, untouched, per the 2026-09-10 gate answer.
# ============================================================================

# --- 1-2: THE REPRO'S ASK NOW REACHES THE VERIFIER --------------------------
reset; seedloop DIVE-921
actor_seam_as dev; cmd_task_need DIVE-921 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-921)" == "1" ]] && ok_t "repro fixed: the verifier-scoping ask is no longer promoted by its narration" || bad_t "repro no longer floors" "got tier '$(tierof DIVE-921)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro fixed: the paired human is NOT pinged for a call that was never theirs" || bad_t "repro human not pinged" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(routedof DIVE-921)" == "olivia" ]] && ok_t "repro fixed: routed_reviewer=olivia — the designated answerer HAS standing (DIVE-1495 runs)" || bad_t "repro routed verifier" "got '$(routedof DIVE-921)' — expected the verifier"
# The floor PREDICATE is untouched by arm C; only the promotion left. Read it off
# the stamp, so this arm still reds if the term list or the axis split regresses.
[[ "$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-921';")" == axis=ask* ]] \
  && ok_t "repro fixed: the floor still MATCHED the narration (stamp kept, promotion gone)" \
  || bad_t "repro prov" "got '$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-921';")'"

# --- 3-5: THE REMEDY still lands on the VERIFIER (unchanged by arm C) --------
reset; seedloop DIVE-922
actor_seam_as dev; cmd_task_need DIVE-922 --type=decision --from=dev \
  --discusses="scoping my own acceptance criteria with the verifier; no secret is handled here" \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-922)" == "1" ]] && ok_t "remedy: the appealed scoping gate is tier 1" || bad_t "remedy tier 1" "got '$(tierof DIVE-922)'"
[[ "$(routedof DIVE-922)" == "olivia" ]] && ok_t "remedy: routed_reviewer=olivia (the VERIFIER, not lead main)" || bad_t "remedy routed olivia" "got '$(routedof DIVE-922)'"
[[ "$HUMAN_PINGED" == "0" && "$(route_to)" == "olivia" ]] && ok_t "remedy: human NOT pinged; the handoff send went to olivia" || bad_t "remedy no human ping" "HUMAN_PINGED=$HUMAN_PINGED route=$(route_to)"

# --- 3b: DIVE-2089's APPEAL HAS NOTHING LEFT TO APPEAL (DIVE-4232 evidence).
#     `--discusses` exists to downgrade a gate the floor over-promoted. With no
#     promotion there is no downgrade to perform, and arm 3's row is identical to
#     arm 1's. Asserted as an EQUALITY on purpose: if a later change gives the
#     appeal an observable again this goes RED and names it.
# LIVENESS FIRST — an equality is satisfied by two EMPTY values.
[[ -n "$(tierof DIVE-921)" && -n "$(routedof DIVE-921)" && -n "$(tierof DIVE-922)" && -n "$(routedof DIVE-922)" ]] \
  && ok_t "DIVE-4232 liveness: both appeal-discriminator rows filed and routed (the equality below is not vacuous)" \
  || bad_t "2089 discriminator liveness" "921(tier='$(tierof DIVE-921)' routed='$(routedof DIVE-921)') 922(tier='$(tierof DIVE-922)' routed='$(routedof DIVE-922)')"
[[ -n "$(tierof DIVE-921)" && "$(tierof DIVE-921)" == "$(tierof DIVE-922)" && "$(routedof DIVE-921)" == "$(routedof DIVE-922)" ]] \
  && ok_t "DIVE-4232 evidence: --discusses changes NO observable at the gate (with=$(tierof DIVE-922)/$(routedof DIVE-922), without=$(tierof DIVE-921)/$(routedof DIVE-921))" \
  || bad_t "2089 appeal discriminator" "with(tier=$(tierof DIVE-922) routed=$(routedof DIVE-922)) != without(tier=$(tierof DIVE-921) routed=$(routedof DIVE-921)) — DIVE-2089 HAS an observable again; re-read DIVE-4232 before retiring it"

# --- 6-7: THE DEAD-END ADVICE IS UNREACHABLE. There is no dead-end to announce:
#     the filer's gate already reached the verifier in arm 1. Asserted as the
#     OUTCOME (the advice's whole purpose was to get the filer to olivia) plus the
#     silence, which is now true by construction — see the header proof.
reset; seedloop DIVE-923
actor_seam_as dev; cmd_task_need DIVE-923 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(routedof DIVE-923)" == "olivia" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "fix superseded: the filer reaches olivia WITHOUT being advised to re-file" \
  || bad_t "fix reaches verifier unaided" "routed='$(routedof DIVE-923)' HUMAN_PINGED=$HUMAN_PINGED"
! warned "CANNOT clear it" \
  && ok_t "fix superseded: no dead-end advice (VACUOUS — the guard is unreachable after arm C)" \
  || bad_t "deadend must not fire" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 8: NEGATIVE CONTROL — an appealed gate still gets no dead-end warning.
reset; seedloop DIVE-924
actor_seam_as dev; cmd_task_need DIVE-924 --type=decision --from=dev \
  --discusses="scoping my own acceptance criteria with the verifier" \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
! warned "CANNOT clear it" \
  && ok_t "no-op: a successfully appealed gate gets no dead-end warning" \
  || bad_t "no-op appealed gate silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 9-10: THE APPEAL-REFUSAL PATH IS ALSO DEAD. A money ask on a loop used to be
#     floored, appealed, and REFUSED (Rule 3: 'spend' survives the residual), and
#     the refusal line had to name the surviving term. Nothing floors it now, so
#     there is no appeal to refuse. What replaces the property: the ask reaches the
#     verifier undeclared (below), and reaches the HUMAN when the filer DECLARES
#     that it spends money (arm 11).
reset; seedloop DIVE-925
actor_seam_as dev; cmd_task_need DIVE-925 --type=decision --from=dev \
  --discusses="just a design discussion" \
  --ask="Should we spend \$500 on the ads test before grading criterion 3?" \
  --options="yes|no" --recommend="no" 2>"$ERR" >/dev/null
! warned "_dd_residual" \
  && ok_t "refusal: no unbound-variable error naming _dd_residual" \
  || bad_t "refusal no unbound var" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"
! warned "discusses REFUSED" \
  && ok_t "refusal path dead: nothing floored the money ask, so the appeal had nothing to refuse" \
  || bad_t "refusal path dead" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

# --- 11: SAFETY — a money ask on a loop reaches the HUMAN when DECLARED, and the
#     human keeps the call: no seat is routed it. This is the arm that carries the
#     old 'safety: money stays tier 2, unrouted' property across arm C.
reset; seedloop DIVE-941
actor_seam_as dev; cmd_task_need DIVE-941 --type=decision --from=dev --needs=spend_authority \
  --ask="Should we spend \$500 on the ads test before grading criterion 3?" \
  --options="yes|no" --recommend="no" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-941)" == "2" && -z "$(routedof DIVE-941)" && "$HUMAN_PINGED" == "1" ]] \
  && ok_t "safety: a DECLARED money ask on a loop stays tier 2, unrouted, and pings the human" \
  || bad_t "safety money declared" "tier=$(tierof DIVE-941) routed='$(routedof DIVE-941)' HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(routedof DIVE-941)" != "olivia" ]] \
  && ok_t "safety: the verifier is NOT handed a spend decision (the declaration outranks the loop route)" \
  || bad_t "safety money not to verifier" "routed='$(routedof DIVE-941)'"

# --- 11b: a REFUSED appeal gets no advice to re-try the flag that just refused.
#     Kept verbatim; VACUOUS after arm C (nothing is refused any more).
! warned "CANNOT clear it" \
  && ok_t "safety: a refused appeal gets no advice to re-try the flag (VACUOUS after arm C)" \
  || bad_t "safety refused-appeal silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 400)"

# --- 11c: THE CONTROL FOR WHAT ARM C GIVES UP. The identical money ask with
#     nothing declared no longer reaches the human at all — it goes to the
#     verifier. This is the loosening, recorded rather than lost.
reset; seedloop DIVE-931
actor_seam_as dev; cmd_task_need DIVE-931 --type=decision --from=dev \
  --ask="Should we spend \$500 on the ads test before grading criterion 3?" \
  --options="yes|no" --recommend="no" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-931)" == "1" && "$(routedof DIVE-931)" == "olivia" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "arm C control: the SAME money ask UNDECLARED reaches the verifier, not the human" \
  || bad_t "control money undeclared" "tier=$(tierof DIVE-931) routed='$(routedof DIVE-931)' HUMAN_PINGED=$HUMAN_PINGED"

# --- 11d: RULE 4 — no lead sits above the filer. The appeal would have refused
#     for want of a route; the LOOP still supplies one, so the gate reaches the
#     verifier rather than dead-ending. Property converted from 'floored silently'
#     to 'reaches the designated answerer'.
reset; seedloop DIVE-932 main
actor_seam_as main; cmd_task_need DIVE-932 --type=decision --from=main \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(routedof DIVE-932)" == "olivia" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "no-lead: the loop supplies the route the org chart could not — reaches olivia" \
  || bad_t "safety no-lead routes to verifier" "routed='$(routedof DIVE-932)' HUMAN_PINGED=$HUMAN_PINGED"
! warned "CANNOT clear it" \
  && ok_t "no-lead: no advice promising a route the appeal would refuse (VACUOUS after arm C)" \
  || bad_t "safety no-lead silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 400)"

# --- 12: SAFETY — an EXPLICIT --tier=2 is the caller's hard-human contract
#         (DIVE-1957). Untouched by arm C: the pinned tier never came from the
#         keyword promoter, and this arm is the proof that arm C did not widen
#         itself into the pinned axis.
reset; seedloop DIVE-926
actor_seam_as dev; cmd_task_need DIVE-926 --type=decision --from=dev --tier=2 \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(tierof DIVE-926)" == "2" && "$HUMAN_PINGED" == "1" ]] && ! warned "CANNOT clear it" \
  && ok_t "safety: explicit --tier=2 stays hard-human and gets no appeal advice" \
  || bad_t "safety pinned tier 2 silent" "tier=$(tierof DIVE-926) HUMAN_PINGED=$HUMAN_PINGED stderr: $(tr '\n' ' ' <"$ERR" | tail -c 200)"

# --- 13: STRUCTURAL DISCRIMINATOR — AND IT STILL HAS AN OBSERVABLE. Byte-identical
#         ask to arm 1 on a task with NO loop: it routes to the LEAD (main), where
#         the loop version routed to the VERIFIER (olivia). This is the arm that
#         proves the trigger is the LOOP and not the vocabulary, and unlike the
#         appeal in 3b it survives arm C intact — so DIVE-1495's verifier-route is
#         NOT a candidate for retirement on DIVE-4232.
reset; seedplain DIVE-927
actor_seam_as dev; cmd_task_need DIVE-927 --type=decision --from=dev \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(routedof DIVE-927)" == "main" ]] \
  && ok_t "discriminator: identical ask on a NON-loop task routes to the LEAD, not the verifier" \
  || bad_t "discriminator non-loop routes to lead" "routed='$(routedof DIVE-927)'"
[[ "$(routedof DIVE-927)" != "$(routedof DIVE-921)" ]] \
  && ok_t "DIVE-4232 evidence: the LOOP discriminator DOES still change an observable (loop=$(routedof DIVE-921) vs non-loop=$(routedof DIVE-927))" \
  || bad_t "loop discriminator" "loop and non-loop both routed to '$(routedof DIVE-927)' — the verifier-route stopped discriminating"
! warned "CANNOT clear it" \
  && ok_t "discriminator: a non-loop task gets no dead-end advice (VACUOUS after arm C)" \
  || bad_t "discriminator non-loop silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 200)"

# --- 14: SELF-ROUTE — the VERIFIER filing on their own loop is not their own
#         answerer, so the gate falls to the lead instead. Also still observable.
reset; seedloop DIVE-928 olivia
actor_seam_as olivia; cmd_task_need DIVE-928 --type=decision --from=olivia \
  --ask="$SCOPE_ASK" --options="split|keep" --recommend="split" 2>"$ERR" >/dev/null
[[ "$(routedof DIVE-928)" != "olivia" ]] \
  && ok_t "self-route: the verifier's own gate is not routed back to themselves (got '$(routedof DIVE-928)')" \
  || bad_t "self-route not to self" "routed='$(routedof DIVE-928)'"
! warned "CANNOT clear it" \
  && ok_t "self-route: no advice to reach themselves (VACUOUS after arm C)" \
  || bad_t "self-route silent" "stderr: $(tr '\n' ' ' <"$ERR" | tail -c 300)"

echo
echo "gate verifier-scoping floor: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ $FAIL -eq 0 ]]
