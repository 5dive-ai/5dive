#!/usr/bin/env bash
# TIER: nightly — 24.2s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
# DIVE-2089 isolated unit harness for the DECLARED-DISCUSSION floor appeal.
#
# THE DEFECT. The T2 category floor reads SUBJECT MATTER as risk and picks the
# gate's audience from it. dev3's tier-1 SIZING gate on DIVE-2078 — "how should
# we model capability vs clearance" — was floored hard-human because the ask
# contains "credentials" and "privileged". It performs no credential operation.
# Worse, it was SILENT: dev3 found out by re-reading their own filed gate, and
# worked around it by re-filing with neutral wording, which teaches the fleet to
# launder vocabulary to reach the right audience.
#
# THE FIX UNDER TEST. `--discusses="<why>"` — a DECLARED, recorded, audited
# appeal on --type=decision only, honoured only when the floor actually
# over-fired, refused for the non-appealable core (money / customer comms /
# irreversible infra), refused when the caller pinned --tier=2, refused when no
# lead exists, and downgrading only to a LEAD-ROUTED tier 1. Plus a loud
# file-time announcement naming the term that fired.
#
# TWO HARD REQUIREMENTS THIS SUITE MEETS, both learned the expensive way:
#
#  1. VARY THE TITLE, NOT ONLY THE ASK (DIVE-1957). The floor matches over ask +
#     TASK TITLE. A suite that only ever varies the ask exercises the axis a
#     filer can already reword and would FALSELY PASS. Arm 2 puts the keyword in
#     the title with a byte-neutral ask — the axis the filer cannot fix at all.
#
#  2. PROVE THE APPEAL IS THE ONLY THING THAT MOVES ANYTHING (DIVE-2146
#     pre-condition). olivia's precondition is that the floor is currently the
#     SOLE ENFORCER of at least one standing directive (the self-restart confirm
#     at projects/CLAUDE.md:13) and that a control which STOPS firing emits no
#     signal at all. Arms 3 and 10 are that proof, stated as assertions rather
#     than as an enumeration: every gate filed WITHOUT the new flag gets exactly
#     the tier it got before, and the self-restart-shaped APPROVAL gate cannot
#     reach the appeal even if someone passes the flag (arm 6, a hard refusal).
#
# Isolation matches the sibling gate harnesses: source src/ into a throwaway
# STATE_DIR, never the live board.
# Run: bash tests/gate_floor_declared_discussion_unit.sh   (no root, no network).
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
# DIVE-2518: `--from` is provenance; the TIER and ROUTING decisions read the uid
# derivation, so an arm impersonating a filer must DERIVE as them.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-discusses-unit.XXXXXX)"

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

# Never DM the human or shell to a peer; record instead. Stub the HUMAN deliverer
# one layer below task_need_notify (DIVE-2011) so HUMAN_PINGED means what its name
# says and the routed rail still runs for real against the `5dive` stub.
HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
AUDIT_FILE="$TMP/audit.log"; : >"$AUDIT_FILE"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_FILE"; return 0; }
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { HUMAN_PINGED=0; : >"$ROUTE_FILE"; : >"$AUDIT_FILE"; }
route_to()    { local i; for i in $(seq 1 12); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.05; done; tail -n1 "$ROUTE_FILE" 2>/dev/null; }
# DIVE-3474 changed HOW a routed gate reaches the lead, not WHETHER it does: a
# non-urgent routed gate is QUEUED (no `agent send`, no window re-send) and the
# lead meets it on its next natural wake. The arm(s) below assert the gate reached
# a NAMED seat, and that property is unchanged — so the check gains the queue as a
# second way of being reached rather than being relaxed. It calls the REAL queue
# predicate (`_task_agent_gate_pred`, the one `5dive task queue` and the heartbeat
# nudge both use), so a row queued where nobody looks still fails here.
queued_for() { # <ident> <agent> -> 1 if `5dive task queue --for=<agent>` would list it
  local n; n=$(db "SELECT COUNT(*) FROM tasks WHERE ident='$1' AND $(_task_agent_gate_pred "$2");" 2>/dev/null)
  [[ "${n:-0}" != "0" ]] && echo 1 || echo 0
}

# Org chart: main is the lone coordinator; dev reports to main (so reviewer(dev)=main).
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# seed <ident> [title] — the TITLE is a first-class variable here (DIVE-1957).
seed()      { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1',$(sqlq "${2:-neutral engineering task}"),'todo','main');"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
routedof()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
askof()     { db "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$1';"; }

# dev3's real ask on DIVE-2078, trimmed. Names "credentials" and "privileged";
# requests nothing but a modelling choice.
# DIVE-4176: kept under the human-ask readability budget on purpose. Every arm
# below files this ask on a gate that FLOORS to the paired human, so the
# readability refusal grades it; at its former 30 words it was refused before the
# FLOOR this harness measures was ever reached. The two floor terms it turns on
# ("credentials", "clearance") are untouched.
DESIGN_ASK="Should an agent's right to act come from the credentials it holds, or from a separately declared clearance level?"
DESIGN_WHY="this is a data-model sizing question about how to REPRESENT credential handling; it performs no credential operation and grants nothing"

# ===========================================================================
# DIVE-4175 arm C — THE APPEAL HAS NOTHING LEFT TO APPEAL.
#
# `--discusses` (DIVE-2089) exists to downgrade a gate the KEYWORD FLOOR promoted
# to tier 2 on a substring of prose. Arm C deletes that promotion, so there is no
# promotion to appeal: every arm below that used to read `tier == 2` was reading
# the transition, not the property.
#
# Each arm is converted to the OUTCOME it defends, reached by the route that
# survives arm C — the filer DECLARING the capability (`--needs=`, DIVE-2241) —
# and each keeps the loosening as an explicit negative control. The floor
# PREDICATE is untouched, so any arm that only needed "this ask trips the floor"
# now reads it off `floor_provenance`, which still records axis and term.
#
# THE MEASUREMENT THIS SUITE NOW CARRIES (DIVE-4232 evidence): with the promotion
# gone, a gate filed WITH `--discusses` and the identical gate filed WITHOUT it
# produce the same tier and the same route. The flag's only surviving trace is an
# audit line saying the appeal was REFUSED. Asserted as an equality in arm 3b so
# that a later change restoring an observable turns it red instead of silent.
# The DIVE-2089 code is left in place, untouched, per the 2026-09-10 gate answer.
# ===========================================================================
# ---------------------------------------------------------------------------
# 1: THE REPRO, ask axis — a design decision naming 'credential' reaches the LEAD
route_reset; seed DIVE-401
actor_seam_as dev; cmd_task_need DIVE-401 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
[[ "$(tierof DIVE-401)" == "1" ]] && ok_t "repro/ask: declared design decision downgraded to tier 1" || bad_t "repro/ask tier 1" "got '$(tierof DIVE-401)'"
[[ "$(routedof DIVE-401)" == "main" ]] && ok_t "repro/ask: routed_reviewer=main (the lead, not the human)" || bad_t "repro/ask routed main" "got '$(routedof DIVE-401)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro/ask: paired human NOT pinged" || bad_t "repro/ask no human ping" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(route_to)" == "main" || "$(queued_for DIVE-401 main)" == "1" ]] && ok_t "repro/ask: the gate reached main — sent, or queued for its next wake" || bad_t "repro/ask reached main" "route_to='$(route_to)' queued=$(queued_for DIVE-401 main)"

# 2: THE REPRO, TITLE axis (DIVE-1957) — the ask is byte-neutral and the floor
#    keyword lives ONLY in the task title, which the filer cannot reword.
route_reset; seed DIVE-402 "design the token exchange between the runtime and the broker"
actor_seam_as dev; cmd_task_need DIVE-402 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" \
  --discusses="a transport-shape design question; the title names the subsystem, nothing is being minted or handled" >/dev/null 2>&1
[[ "$(tierof DIVE-402)" == "1" ]] && ok_t "repro/TITLE: floor keyword in the TITLE is appealable too" || bad_t "repro/TITLE tier 1" "got '$(tierof DIVE-402)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro/TITLE: paired human NOT pinged" || bad_t "repro/TITLE no human ping" "HUMAN_PINGED=$HUMAN_PINGED"

# 3: MUTATION GUARD — the SAME two gates WITHOUT the flag still floor to the human.
#    If these ever pass at tier 1 the suite above is grading a floor that stopped
#    firing for some other reason, and every arm is vacuous.
route_reset; seed DIVE-403
actor_seam_as dev; cmd_task_need DIVE-403 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" >/dev/null 2>&1
# DIVE-4175 arm C: the guard's JOB is to prove this suite is not vacuous — that
# the floor still FIRES on this ask, so arms 1-2 are grading something. The tier
# can no longer show that; `floor_provenance` can, and it names the axis and term.
[[ "$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-403';")" == axis=ask*term=credential* ]] \
  && ok_t "mutation: the floor still MATCHES the ask WITHOUT --discusses (prov names axis+term)" \
  || bad_t "mutation ask still matches" "got prov '$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-403';")' — the floor stopped firing and every arm above is vacuous"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "arm C control: the undeclared design ask no longer pages the human" || bad_t "control undeclared no page" "HUMAN_PINGED=$HUMAN_PINGED"

# 3b: DIVE-2089 IS INERT (DIVE-4232 evidence). Arm 1 filed this ask WITH the flag,
#     arm 3 filed it WITHOUT. Same tier, same route. The flag's only surviving
#     trace is the audit line in arm 13. Equality asserted on purpose: a later
#     change that gives the appeal an observable again turns this RED.
# LIVENESS FIRST — an equality is satisfied by two EMPTY values, and unlike arm 1
#     DIVE-403 has no absolute tier/route assertion of its own anywhere else.
[[ "$(tierof DIVE-403)" == "1" && "$(routedof DIVE-403)" == "main" ]] \
  && ok_t "DIVE-4232 liveness: the unappealed gate filed and lead-routed (tier 1 -> main), so the equality below is not vacuous" \
  || bad_t "2089 discriminator liveness" "403(tier='$(tierof DIVE-403)' routed='$(routedof DIVE-403)') — an empty or unrouted side makes the equality meaningless"
[[ -n "$(tierof DIVE-401)" && "$(tierof DIVE-401)" == "$(tierof DIVE-403)" && "$(routedof DIVE-401)" == "$(routedof DIVE-403)" ]] \
  && ok_t "DIVE-4232 evidence: --discusses changes NO observable at the gate (with=$(tierof DIVE-401)/$(routedof DIVE-401), without=$(tierof DIVE-403)/$(routedof DIVE-403))" \
  || bad_t "2089 appeal discriminator" "with(tier=$(tierof DIVE-401) routed=$(routedof DIVE-401)) != without(tier=$(tierof DIVE-403) routed=$(routedof DIVE-403)) — DIVE-2089 HAS an observable again; re-read DIVE-4232 before retiring it"

# 3c: AND THE HUMAN IS STILL REACHABLE — by declaration, which is the route arm C
#     leaves standing. Non-vacuity for the whole "safety" family below.
route_reset; seed DIVE-453
actor_seam_as dev; cmd_task_need DIVE-453 --type=decision --from=dev --needs=human_tap \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" >/dev/null 2>&1
[[ "$(tierof DIVE-453)" == "2" && "$HUMAN_PINGED" == "1" ]] \
  && ok_t "arm C: the SAME ask with a DECLARED capability is tier 2 and reaches the human" \
  || bad_t "declared reaches human" "tier=$(tierof DIVE-453) HUMAN_PINGED=$HUMAN_PINGED"
# DIVE-2224 answer A (lodar, 2026-07-28 05:32): this arm changed DISPOSITION, not
# PURPOSE. A floor term in the TITLE with a substantive ask no longer floors -- it
# routes to the lead stamped floored_by=title. The guard still has to prove the title
# is READ AT ALL, so it now grades that stamp: if the title axis went dead the gate
# would be tier 1 with NO stamp, and this arm reds exactly as it did before.
route_reset; seed DIVE-404 "design the token exchange between the runtime and the broker"
res404=$( JSON_MODE=0; cmd_task_need DIVE-404 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" 2>/dev/null )
{ [[ "$(tierof DIVE-404)" == "1" ]] && grep -qi "floored_by=title" <<<"$res404"; } \
  && ok_t "mutation/TITLE: the title axis is still LIVE — lead-routed and STAMPED floored_by=title (answer A)" \
  || bad_t "mutation title stamped" "tier='$(tierof DIVE-404)' stdout: $res404"

# 4: SAFETY — the non-appealable MONEY core survives any declaration.
route_reset; seed DIVE-405
actor_seam_as dev; cmd_task_need DIVE-405 --type=decision --from=dev \
  --ask="How should we model the credential store, and do we refund the affected customers \$500 each?" \
  --options="A|B" --recommend="A" --needs=spend_authority >/dev/null 2>&1
[[ "$(tierof DIVE-405)" == "2" ]] && ok_t "safety: a DECLARED money ask is tier 2, whatever else the ask says" || bad_t "safety money tier 2" "got '$(tierof DIVE-405)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: the declared money ask pings the human" || bad_t "safety money pings human" "HUMAN_PINGED=$HUMAN_PINGED"
# control — the loosening: the same ask, declaring nothing, reaches the lead instead.
route_reset; seed DIVE-465
actor_seam_as dev; cmd_task_need DIVE-465 --type=decision --from=dev \
  --ask="How should we model the credential store, and do we refund the affected customers \$500 each?" \
  --options="A|B" --recommend="A" --discusses="mostly a data-model question" >/dev/null 2>&1
[[ "$(routedof DIVE-465)" == "main" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "arm C control: the same money ask UNDECLARED lead-routes — the appeal no longer decides it" \
  || bad_t "control money undeclared" "routed='$(routedof DIVE-465)' HUMAN_PINGED=$HUMAN_PINGED"

# 5: SAFETY — the non-appealable IRREVERSIBLE-INFRA core survives any declaration.
route_reset; seed DIVE-406
actor_seam_as dev; cmd_task_need DIVE-406 --type=decision --from=dev \
  --ask="Model the credential lifecycle — and revoke the leaked key + move the dns record while we are here?" \
  --options="A|B" --recommend="A" --needs=secret_provision >/dev/null 2>&1
[[ "$(tierof DIVE-406)" == "2" && "$HUMAN_PINGED" == "1" ]] && ok_t "safety: a DECLARED irreversible-infra ask is tier 2 and reaches the human" || bad_t "safety infra tier 2" "tier='$(tierof DIVE-406)' HUMAN_PINGED=$HUMAN_PINGED"

# 6: DIVE-2146 REGRESSION GUARD — an APPROVAL gate declares an ACTION, so the
#    appeal does not exist for it. This is what makes the self-restart confirm
#    (projects/CLAUDE.md:13, currently enforced only incidentally by this floor)
#    unreachable by this change: the flag is REFUSED, not accepted-and-ignored.
route_reset; seed DIVE-407
( cmd_task_need DIVE-407 --type=approval --from=dev \
    --ask="Approve restarting agent-main's own service so the new hook loads — it tears down the live session." \
    --discusses="I am only discussing the restart" >/dev/null 2>&1 )
[[ "$?" != "0" ]] && ok_t "2146 guard: --discusses on --type=approval is REFUSED (non-zero)" || bad_t "2146 guard approval refused" "rc was 0"
[[ -z "$(tierof DIVE-407)" ]] && ok_t "2146 guard: the refused approval gate was NOT filed at all" || bad_t "2146 guard no gate" "tier '$(tierof DIVE-407)'"
for t in secret manual access; do
  route_reset; seed "DIVE-41$RANDOM"
  ( cmd_task_need DIVE-401 --type="$t" --from=dev --ask="hand me the api key" --discusses="only discussing it" >/dev/null 2>&1 )
  [[ "$?" != "0" ]] && ok_t "2146 guard: --discusses on --type=$t is REFUSED" || bad_t "2146 guard $t refused" "rc was 0"
done

# 7: THE DIVE-2146 PRE-CONDITION, REFUTED BY MEASUREMENT.
#
#    olivia's precondition on this ticket says the tier floor is "currently the
#    only thing ENFORCING" the self-restart confirm directive, so landing 2089
#    would silently revert that control to willpower. That premise is FALSE, and
#    this arm is the measurement rather than an argument: the REAL DIVE-2146 ask
#    and title (copied verbatim from the live board row) do not trip the floor at
#    all. Not one term matches.
#
#    Its gate reached the human at tier 2 for a reason DIVE-2146's own body
#    records: main lead-routed it, withdrew it 29 seconds later, and re-filed
#    with an EXPLICIT --tier=2. A hand-pinned tier is not the floor, and this
#    ticket does not touch it (arm 8 pins the pin's precedence).
#
#    So the "two reasons for one control" analysis is right in general and wrong
#    about this instance — there was only ever ONE reason, the stated directive,
#    and it was never load-bearing on the floor. Keeping this arm as a live
#    assertion rather than a note means the day someone widens the floor to catch
#    'restart'/'session', the entanglement olivia feared becomes real and THIS
#    goes red first.
SR_ASK_2146="Approve restarting agent-main so the DIVE-2146 preflight hook actually loads? It is wired into settings.json but hooks only load at session start, so it is inert and unproven until a restart — which tears down this live session."
SR_TITLE_2146="do not ask a question, print the answer: put the missing question in the path as an artifact"
_gate_tier2_floor_hit "${SR_ASK_2146} ${SR_TITLE_2146}" \
  && bad_t "precondition: the floor is NOT the self-restart confirm's enforcer" "floor matched '$(_gate_tier2_floor_term "${SR_ASK_2146} ${SR_TITLE_2146}")' — the DIVE-2146 entanglement is now REAL and this ticket must re-open it" \
  || ok_t "precondition REFUTED: the real DIVE-2146 ask+title trip NO floor term — the floor never enforced the self-restart confirm"
route_reset; seed DIVE-408 "$SR_TITLE_2146"
actor_seam_as dev; cmd_task_need DIVE-408 --type=approval --from=dev --ask="$SR_ASK_2146" >/dev/null 2>&1
sr_tier="$(tierof DIVE-408)"; sr_ping="$HUMAN_PINGED"
[[ "$sr_ping" == "1" ]] && ok_t "precondition: the self-restart gate still reaches the paired human (tier $sr_tier), unchanged" || bad_t "precondition human reached" "tier=$sr_tier ping=$sr_ping"
# And the counterfactual olivia actually cares about: hand main its pin back and
# the gate is hard-human, by the pin, with or without this ticket.
route_reset; seed DIVE-419 "$SR_TITLE_2146"
# --ask-ok (DIVE-4176): SR_ASK_2146 is the REAL DIVE-2146 ask reproduced verbatim,
# and the pin makes it hard-human, so the readability rule refuses it — correctly:
# at 40 words with an ident and a filename in it, it is precisely the shape the
# rule exists to bounce. Rewording it would destroy the historical artifact this
# arm grades, so the escape is declared instead.
actor_seam_as dev; cmd_task_need DIVE-419 --type=approval --from=dev --tier=2 --ask="$SR_ASK_2146" \
  --ask-ok="fixture: a verbatim historical ask, reproduced to grade the floor rather than to be read" >/dev/null 2>&1
[[ "$(tierof DIVE-419)" == "2" && "$HUMAN_PINGED" == "1" ]] \
  && ok_t "precondition: the pinned re-file (what DIVE-2146 actually did) is hard-human independent of the floor" \
  || bad_t "precondition pinned refile" "tier=$(tierof DIVE-419) ping=$HUMAN_PINGED"

# 8: SAFETY — an explicit --tier=2 pin is the caller's hard-human contract and
#    outranks the appeal (DIVE-1957). Warn, do not obey.
route_reset; seed DIVE-409
actor_seam_as dev; cmd_task_need DIVE-409 --type=decision --from=dev --tier=2 \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
[[ "$(tierof DIVE-409)" == "2" ]] && ok_t "safety: --tier=2 pin vetoes the appeal" || bad_t "safety pin tier 2" "got '$(tierof DIVE-409)'"
[[ -z "$(routedof DIVE-409)" ]] && ok_t "safety: a pinned gate is never routed to an agent" || bad_t "safety pin not routed" "got '$(routedof DIVE-409)'"

# 9: SAFETY — the LEAD has no reviewer above them, so there is nobody to appeal TO.
route_reset; seed DIVE-410
actor_seam_as main; cmd_task_need DIVE-410 --type=decision --from=main \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
# DIVE-4175 arm C: the tier moved 2 -> 1, the OUTCOME did not. Nobody sits above
# the lead, so the `_routable` backstop resolves no seat and the gate lands on the
# paired human exactly as before. This arm never depended on the promoter.
[[ "$HUMAN_PINGED" == "1" && -z "$(routedof DIVE-410)" ]] \
  && ok_t "safety: lead-filed gate has no reviewer above it, so it reaches the human" \
  || bad_t "safety lead reaches human" "tier=$(tierof DIVE-410) routed='$(routedof DIVE-410)' HUMAN_PINGED=$HUMAN_PINGED"

# 10: NO-OP — a decision the floor never touched is unchanged by the flag's absence
#     AND by its presence (the appeal warns rather than silently re-tiering).
route_reset; seed DIVE-411
actor_seam_as dev; cmd_task_need DIVE-411 --type=decision --from=dev \
  --ask="Should the dashboard column order be priority-first or age-first?" \
  --options="priority|age" --recommend="priority" >/dev/null 2>&1
[[ "$(tierof DIVE-411)" == "1" ]] && ok_t "no-op: an unfloored decision is untouched (tier 1)" || bad_t "no-op tier 1" "got '$(tierof DIVE-411)'"

# 11: ANNOUNCE (defect 2) — the floor names the term that fired, on stderr, and
#     points a decision filer at the sanctioned appeal instead of at rewording.
route_reset; seed DIVE-412
ann=$(cmd_task_need DIVE-412 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" 2>&1 >/dev/null)
# DIVE-4175 arm C: THE ANNOUNCEMENT SURVIVES, ITS THREE CLAIMS CHANGED.
#   - "FORCED to tier 2" is retired: nothing is forced any more. What the filer
#     must be told instead is that their wording did NOT reach a person, which is
#     the arm below.
#   - "--discusses" is retired as the offer: the appeal has nothing to appeal
#     (arm 3b). The message now names `--needs=`, which is the route that works.
#   - the anti-laundering line is retired WITH ITS INCENTIVE. It warned against
#     rewording an ask to duck the floor; when wording no longer promotes, a
#     reworded ask buys the filer nothing, so there is nothing to deter.
# The MATCHED-TERM claim is unchanged and still asserted — it was always the
# load-bearing half, and it is what makes the warning actionable.
grep -qi "credential" <<<"$ann" && ok_t "announce: names the MATCHED TERM ('credential'), not just 'the floor'" || bad_t "announce names term" "stderr: $ann"
grep -qi "NOT routed to the paired human" <<<"$ann" && ok_t "announce: states the CONSEQUENCE — this wording did not reach a person" || bad_t "announce states consequence" "stderr: $ann"
grep -q -- "--needs=" <<<"$ann" && ok_t "announce: offers the route that actually reaches a person (--needs=)" || bad_t "announce offers needs" "stderr: $ann"
grep -q -- "--discusses" <<<"$ann" && bad_t "announce must NOT offer the inert appeal" "stderr: $ann" || ok_t "announce: does NOT offer --discusses, which would change nothing (arm 3b)"

# 12: ANNOUNCE — a non-decision gate must NOT be offered an appeal it cannot use.
route_reset; seed DIVE-413
ann2=$(cmd_task_need DIVE-413 --type=approval --from=dev \
  --ask="Approve deleting the leaked credential from the store." 2>&1 >/dev/null)
# DIVE-4175 arm C: same conversion. The lint is type-agnostic by construction (it
# sits in the axis `case`, before any type branch), so an approval filer is told
# the same true thing; and it still must not advertise an appeal approval cannot use.
grep -qi "credential" <<<"$ann2" && ok_t "announce/approval: names the matched term on a non-decision gate too" || bad_t "announce approval names term" "stderr: $ann2"
grep -q -- "--discusses" <<<"$ann2" && bad_t "announce/approval must NOT advertise --discusses" "stderr: $ann2" || ok_t "announce/approval: does NOT advertise an appeal that would be refused"

# 13: AUDIT — the declaration is on the record whether it applied or was refused.
#     That attributability is the whole reason a declaration beats a reworded ask.
route_reset; seed DIVE-414
actor_seam_as dev; cmd_task_need DIVE-414 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
# DIVE-4175 arm C: there is no APPLIED appeal left to record — with no promotion
# there is nothing to downgrade, so DIVE-2089 takes its refusal path on every
# input. The property this arm actually defends is ATTRIBUTABILITY: whatever the
# filer declared is on the record, which is the whole reason a declaration beats a
# reworded ask. That survives, on the refusal line.
grep -q "floor-appeal" "$AUDIT_FILE" && ok_t "audit: the appeal attempt is recorded (applied or refused — an attempt is evidence)" || bad_t "audit appeal recorded" "$(cat "$AUDIT_FILE")"
grep -q "declared=" "$AUDIT_FILE" && ok_t "audit: the declared reason is recorded verbatim" || bad_t "audit declared" "$(cat "$AUDIT_FILE")"
grep -q "floor-appeal applied" "$AUDIT_FILE" \
  && bad_t "2089 appeal discriminator (audit)" "an appeal APPLIED — DIVE-2089 has an observable again; re-read DIVE-4232 before retiring it. $(cat "$AUDIT_FILE")" \
  || ok_t "DIVE-4232 evidence: the appeal is REFUSED on every input now — it never applies"
route_reset; seed DIVE-415
actor_seam_as dev; cmd_task_need DIVE-415 --type=decision --from=dev \
  --ask="Model the store, and refund the customer \$500?" --options="A|B" --recommend="A" \
  --discusses="claiming this is only design" >/dev/null 2>&1
grep -q "floor-appeal refused" "$AUDIT_FILE" && ok_t "audit: a REFUSED appeal is recorded too (an attempt is evidence)" || bad_t "audit refused" "$(cat "$AUDIT_FILE")"

# 14: the reviewer the gate was moved TO can see the claim it was moved on.
# DIVE-4175 arm C: the ask is rewritten only by an APPLIED appeal, and none apply
# now (arm 13). So the reviewer no longer sees the claim in the ask they grade —
# it is on the audit record instead. That is a REAL loss of surface, recorded here
# rather than deleted: the reviewer reading only the gate does not see the
# declaration. It is DIVE-4232's to decide, since the fix is either to retire the
# flag or to write the declaration on a surface that does not depend on the appeal.
[[ "$(askof DIVE-414)" == *"$DESIGN_WHY"* ]] \
  && bad_t "2089 appeal discriminator (ask rewrite)" "the ask carries the declaration — DIVE-2089 has an observable again; re-read DIVE-4232 before retiring it" \
  || ok_t "DIVE-4232 evidence: the declaration no longer reaches the ask the reviewer grades (audit-only)"
# Own fixture: arm 13's second half reset the audit file, so re-file rather than
# grading a leftover from another gate's run.
route_reset; seed DIVE-454
actor_seam_as dev; cmd_task_need DIVE-454 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
grep -qF -- "declared=$DESIGN_WHY" "$AUDIT_FILE" \
  && ok_t "handoff: the declaration is still attributable — recorded verbatim on the audit line" \
  || bad_t "handoff declaration audited" "$(cat "$AUDIT_FILE")"

# 15: hygiene — the flag cannot ride along on --withdraw, and must say something.
route_reset; seed DIVE-416
( cmd_task_need DIVE-416 --withdraw --discusses="x y z a b c d e f" >/dev/null 2>&1 )
[[ "$?" != "0" ]] && ok_t "hygiene: --withdraw --discusses is a usage error" || bad_t "hygiene withdraw" "rc was 0"
route_reset; seed DIVE-417
( cmd_task_need DIVE-417 --type=decision --from=dev --ask="$DESIGN_ASK" --discusses="dunno" >/dev/null 2>&1 )
[[ "$?" != "0" ]] && ok_t "hygiene: an empty-calorie --discusses is refused (it is read by a human reviewer)" || bad_t "hygiene short reason" "rc was 0"

# 16: THE SURFACE THE FILER RE-READS — the RESULT LINE, not the stderr warn.
#     (olivia, iteration 1 reject.) The floor announces on TWO surfaces and only
#     one was graded: arms 11/12 capture `2>&1 >/dev/null`, which is stderr and
#     DISCARDS stdout, so the `ok ... ${floor_note}` line at cmd_task.sh:4449 had
#     ZERO assertions across all 36 arms above. Proved by mutation, not by
#     reading: strip ${floor_term:+: matched '$floor_term'} out of floor_note and
#     the suite still returned 36 passed, 0 failed.
#
#     That is the wrong surface to leave unguarded, because it is the one defect
#     2's own discovery story runs through. dev3 found the escalation by
#     RE-READING their filed gate — the persisted result — not by catching a warn
#     that had already scrolled past. The build note quoted this very line as the
#     before/after evidence for the fix.
#
#     TWO reasons it was unasserted, and the second is the one that bites. This
#     suite sets JSON_MODE=1 globally (line 52), and under JSON_MODE ok() emits
#     the jq payload and NEVER renders the prose at all. So an arm that merely
#     stopped discarding stdout would ALSO stay green under olivia's mutation —
#     it would be grading through the bug. The mode has to be flipped for the
#     duration or the assertion is decorative.
route_reset; seed DIVE-420
res=$( JSON_MODE=0; cmd_task_need DIVE-420 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" 2>/dev/null )
grep -qi "T2 category floor" <<<"$res" \
  && ok_t "result/ask: the RESULT LINE states the floor fired (not only the stderr warn)" \
  || bad_t "result/ask states floor" "stdout: $res"
grep -qi "matched 'credential'" <<<"$res" \
  && ok_t "result/ask: the RESULT LINE names the MATCHED TERM" \
  || bad_t "result/ask names term" "stdout: $res"

# 17: same assertion on the TITLE axis (DIVE-1957) — the term the filer cannot
#     reword away must be named on the durable surface too. The ask here is
#     byte-neutral; 'token' can only have come from the seeded title.
route_reset; seed DIVE-421 "design the token exchange between the runtime and the broker"
res2=$( JSON_MODE=0; cmd_task_need DIVE-421 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" 2>/dev/null )
# DIVE-2224 answer A: the durable surface must still NAME the title term -- that was
# always this arm's point ("the term the filer cannot reword away is named on the
# durable surface"). What changed is what it says about it: routed to the lead and
# stamped, rather than floored to the human.
grep -qi "floored_by=title" <<<"$res2" \
  && ok_t "result/TITLE: the RESULT LINE states the gate was NOT floored and why (floored_by=title)" \
  || bad_t "result/TITLE states floored_by" "stdout: $res2"
grep -qi "matched 'token'" <<<"$res2" \
  && ok_t "result/TITLE: names the term that matched from the TITLE, the axis the filer cannot reword" \
  || bad_t "result/TITLE names term" "stdout: $res2"

# 18: NEGATIVE CONTROL + LIVENESS. Without both of these the two arms above can
#     be satisfied by a constant, and the negative can pass on an EMPTY string —
#     which is exactly the failure mode being fixed (prose that never rendered).
route_reset; seed DIVE-422
res3=$( JSON_MODE=0; cmd_task_need DIVE-422 --type=decision --from=dev \
  --ask="Should the dashboard column order be priority-first or age-first?" \
  --options="priority|age" --recommend="priority" 2>/dev/null )
[[ -n "$res3" ]] \
  && ok_t "result/no-op: LIVENESS — the prose result line rendered at all (JSON_MODE really is off)" \
  || bad_t "result no-op liveness" "stdout was EMPTY — the negative below would pass vacuously"
grep -qi "category floor" <<<"$res3" \
  && bad_t "result/no-op must NOT claim a floor" "stdout: $res3" \
  || ok_t "result/no-op: an unfloored gate's result line claims no floor (the note is not a constant)"

# 19: the MACHINE-READABLE surface carries the WHY too. An agent that files with
#     --json got tier_floored:true and no way to learn which term did it, so the
#     JSON reader was left in exactly the state defect 2 describes. floor_term
#     rides the payload, and is null — not "" — when nothing floored.
route_reset; seed DIVE-423
jres=$(cmd_task_need DIVE-423 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" 2>/dev/null)
# DIVE-4175 arm C: SAME PROPERTY, DIFFERENT PAYLOAD. `tier_floored` is the
# UNROUTED payload's field, and before arm C a floored gate was unrouted so a
# --json filer always got it. Arm C sends this class to a seat, so the row now
# renders through the ROUTED payload — where the machine-readable WHY is
# `route_trigger`, naming the AXIS the term came from. `floor_term` was added
# alongside it in the same change, because a trigger without the term leaves the
# JSON reader in exactly the state defect 2 describes.
[[ "$(jq -r '.data.route_trigger' <<<"$jres" 2>/dev/null)" == "floored-by-ask" ]] \
  && ok_t "json: route_trigger reports the floor fired AND names the AXIS it fired on" \
  || bad_t "json route_trigger axis" "$jres"
[[ "$(jq -r '.data.floor_term' <<<"$jres" 2>/dev/null)" == "credential" ]] \
  && ok_t "json: the matched term rides the JSON payload" || bad_t "json floor_term" "$jres"
# and the axis is not a constant: a TITLE-axis hit must say so.
route_reset; seed DIVE-425 "design the token exchange between the runtime and the broker"
actor_seam_as dev; jres3=$(cmd_task_need DIVE-425 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" 2>/dev/null)
[[ "$(jq -r '.data.route_trigger' <<<"$jres3" 2>/dev/null)" == "floored-by-title" \
   && "$(jq -r '.data.floor_term' <<<"$jres3" 2>/dev/null)" == "token" ]] \
  && ok_t "json: the axis and term are per-gate, not constants (title axis reports title+token)" \
  || bad_t "json axis not constant" "$jres3"
route_reset; seed DIVE-424
jres2=$(cmd_task_need DIVE-424 --type=decision --from=dev \
  --ask="Should the dashboard column order be priority-first or age-first?" \
  --options="priority|age" --recommend="priority" 2>/dev/null)
[[ "$(jq -r '.data.floor_term' <<<"$jres2" 2>/dev/null)" == "null" ]] \
  && ok_t "json: floor_term is null when nothing floored (not a constant)" || bad_t "json floor_term null" "$jres2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
