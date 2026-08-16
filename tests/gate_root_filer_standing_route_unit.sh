#!/usr/bin/env bash
# TIER: nightly — 12.3s measured on ubuntu-latest by the core/pristine-confirm runner
# itself (run 31554029604, 2026-08-12, the tier report's own top-10 line; 10.0s on the
# faster core/pristine box in the same run), and that is BEFORE the vestigial-poll fix
# one commit back on this branch. The cost is the FIXTURE, not the arms: this harness
# stands up the REAL council seal (see the note below — stubbing `_gate_standing_lead`
# would grade the stub) and sources 20+ files of src/ to do it. tests/gate_lead_standing_
# unit.sh, whose seal fixtures this file deliberately mirrors, is ALREADY nightly at
# 26.4s for exactly that reason (DIVE-2525). Two harnesses anchored on one expensive
# fixture belong in one tier; core kept the cheaper half of a pair by accident, not by
# argument.
#
# WHAT IS NOT LOST. `changed-harnesses` runs this file on any PR that touches it, and
# that job's cap is on PROBING only — the plain run "stays uncapped, because the harness
# you touched runs is the promise". A routing change is therefore still graded at the
# moment it is written; what stops is paying 12s on every PR that touches nothing here.
# DIVE-3171: EVERY gate the ORG ROOT files reached the paired human by construction.
# `_gate_route_reviewer` walks reports_to then the coordinator/root, skipping any
# candidate equal to the filer — so for the ROOT both candidates ARE the filer, the walk
# comes back empty, and the gate falls through to the human ping. Not intermittent, not
# subject-specific: every gate, every time. The fix routes exactly the gates the CLEARING
# side already calls lead-clearable (`_gate_lead_standing_eligible`) to the SEALED
# `_gate_standing_lead`, and nothing else.
#
# This harness grades the conjunction, in both directions:
#   P0   preconditions — the root really resolves no chart reviewer, and the seal really
#        names a lead (a dead fixture would green half these arms for the wrong reason)
#   A1   acceptance 1 — root's tier-1 eng approval routes to the sealed lead, human NOT pinged
#   A2   acceptance 2 — pinned tier-2 / money / deny-list / non-engineering asks filed by
#        the root still reach the human and reach NO agent
#   A3   acceptance 3 — drift resolves nobody and the gate falls through exactly as before
#   A4   the seal naming the ROOT itself does not route (that is the self-clear path)
#   A5   negative control — a NON-root filer's identical gate is untouched by this branch
#   A6   type narrowing — a `decision` is not standing-routed (agent-clearable by type already)
#   A7   the DIVE-1495 verifier route still wins where it fired
#
# Harness mirrors tests/gate_verifier_route_unit.sh (routing + route/human spies) plus
# tests/gate_lead_standing_unit.sh's REAL council seal fixtures — the anchor is the whole
# point, so stubbing `_gate_standing_lead` would grade the stub.
# Run: bash tests/gate_root_filer_standing_route_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's stderr
# line IS the payload, and silencing it silenced 210 harnesses at once.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-rootstanding-unit.XXXXXX)"
# DIVE-2190/2610: a `fail()` inside any cmd_* exits the whole script, so a truncated run
# would read as a pass that stopped early. fd 8 is the REAL stderr, duped before any arm,
# because a refusal that dies under `2>/dev/null` sends a trap's `>&2` to /dev/null.
SUMMARY_PRINTED=0
exec 8>&2
# shellcheck disable=SC2154  # rc is assigned inside the trap body
trap 'rc=$?; rm -rf "$TMP"; [[ "$SUMMARY_PRINTED" == 1 ]] || printf "ABORTED - gate_root_filer_standing_route_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

# STATE_DIR before cmd_council.sh: COUNCIL_DIR/COUNCIL_LINEAGE are source-time globals.
STATE_DIR="$TMP"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
COUNCIL_DIR="$STATE_DIR/council"; COUNCIL_LINEAGE="$COUNCIL_DIR/lineage.jsonl"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

# DIVE-2518: identity is pinned through the SEALED seam, not $USER — that env path was
# the forgery DIVE-2518 closed, and `--from` is now a CLAIM that must corroborate, so
# every step DERIVES as the agent it files as.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
FIXTURE_ACTOR=fixture-runner
fixture_actor() { FIXTURE_ACTOR="$1"; actor_seam_as "$1"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

HUMAN_PINGED=0
# DIVE-2011: stub the HUMAN deliverer one layer down, never the shared wrapper —
# task_need_notify dispatches BOTH rails, so stubbing it would report a human ping that
# never happened AND suppress the routed send this harness asserts on.
_task_need_notify_deliver() { HUMAN_PINGED=1; }
audit_log() { :; }
# The task-store audit sink is FENCED behind `_task_human_send_allowed` (DIVE-2054) and
# writes nothing against an isolated fixture DB, so querying the store would grade the
# fence. Spy on the CALL SITE: what a refactor silently drops is the call and its args.
AUDIT_SPY="$TMP/audit-spy.log"; : >"$AUDIT_SPY"
_task_store_audit_log() { printf '%s\n' "$*" >>"$AUDIT_SPY"; return 0; }
spy_reset() { : >"$AUDIT_SPY"; }
# `grep -c` prints 0 and EXITS 1 on no match, so a `|| echo 0` fallback appends a SECOND
# line and the count is "0\n0", equal to neither 0 nor 1 (DIVE-3117 hit this exact shape).
spy_n()    { local n; n=$(grep -c 'org-root standing-route' "$AUDIT_SPY" 2>/dev/null); printf '%s' "${n:-0}"; }
spy_last() { grep 'org-root standing-route' "$AUDIT_SPY" 2>/dev/null | tail -n1; }

ROUTE_FILE="$TMP/route.log"
5dive() { if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then printf '%s\n' "${3:-}" >>"$ROUTE_FILE"; fi; return 0; }
export -f 5dive 2>/dev/null || true
route_reset() { : >"$ROUTE_FILE"; HUMAN_PINGED=0; spy_reset; }
# DIVE-3298: these two used to poll `for i in $(seq 1 10); do ... sleep 0.05; done`
# before reading ROUTE_FILE. There is nothing to wait for. The `5dive` send is the
# plain bash FUNCTION defined above, called in-process by cmd_task_need — no
# subshell, no `&`, no external process — so the write has already happened by the
# time the call returns. The poll only ever ran to completion on the arms that
# EXPECT an empty file (the A2 quartet, A3, A4, A6), where it burned the full
# 10x0.05s before confirming the emptiness it was always going to confirm: 3.56s of
# the harness's 14.75s, entirely on its negative arms. Measured 31/31 both ways.
# If the routed send is ever moved off-process, restore a wait HERE — but assert on
# the process, not on a sleep that passes by timing out.
route_sent()  { local n; n=$(grep -c . "$ROUTE_FILE" 2>/dev/null); echo "${n:-0}"; }
route_last()  { tail -n1 "$ROUTE_FILE" 2>/dev/null; }
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
rr_of()       { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
rp_of()       { db "SELECT COALESCE(route_provenance,'') FROM tasks WHERE ident='$1';"; }
tier_of()     { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }

# ---- the org chart, in PRODUCTION SHAPE: olivia is the lone root (CEO), main is the
# engineering lead under her, dev is a builder under main. No role='coordinator' row, so
# `_task_resolve_coordinator` resolves the unique root — which IS olivia, which is the
# whole defect.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('olivia',NULL,'AI CEO');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main','olivia','engineering');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# ---- the SEALED anchor (DIVE-2099): the holder is the agent NAMED in the constitution,
# trusted only while the live bytes still match the digest sealed into the lineage.
constitution_yaml() {
  # No `hard_gates:` key on purpose — absent means the loader keeps the SHIPPED default
  # classes, so the tier-2 floor the A2 arms lean on behaves exactly as in production.
  printf 'ship:\ncomms:\n'
  [[ -n "${1:-}" ]] && printf 'authority:\n  eng_approval_lead: %s\n' "$1"
  return 0
}
write_constitution() { mkdir -p "$STATE_DIR"; printf '%s' "$1" > "$STATE_DIR/constitution.yaml"; }
seal_constitution()  {
  mkdir -p "$COUNCIL_DIR"
  printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
    "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"
}
anchor_to() { write_constitution "$(constitution_yaml "$1")"; seal_constitution; }
anchor_to main

seed()      { db "INSERT INTO tasks(ident,title,status,created_by,assignee) VALUES('$1',$(sqlq "${2:-a routine engineering row}"),'todo','main','olivia');"; }
seed_loop() { db "INSERT INTO tasks(ident,title,status,created_by,assignee,verifier,maker_agent,iteration,max_iterations)
                  VALUES('$1','loop row','todo','main','olivia','quinn','olivia',1,5);"; }

# The ask that produced the complaint, verbatim in shape (DIVE-3047's): eng-ship
# classified, no tier-2 floor term, tier 1 by the DIVE-1284 approval default.
ENG_ASK='approve delegated push for review of branch dive-3171-root-filer (@abc1234)'

# ---- P0. PRECONDITIONS. Both halves of this fix are fixture-dependent, and a dead
# fixture greens the negative arms for exactly the wrong reason (an empty standing lead
# makes A2/A3/A4 pass without the code under test running at all).
[[ -z "$(_gate_route_reviewer olivia)" ]] \
  && ok_t "P0 the org root resolves NO chart reviewer (the defect's mechanism)" \
  || bad_t "P0 the org root resolves NO chart reviewer" "got '$(_gate_route_reviewer olivia)'"
[[ "$(_gate_route_reviewer dev)" == "main" ]] \
  && ok_t "P0 a non-root filer still resolves their chart lead" \
  || bad_t "P0 a non-root filer still resolves their chart lead" "got '$(_gate_route_reviewer dev)'"
[[ "$(_gate_standing_lead)" == "main" ]] \
  && ok_t "P0 the sealed constitution anchors the standing lead to 'main'" \
  || bad_t "P0 the sealed constitution anchors to main" "got '$(_gate_standing_lead)'"
[[ "$(_task_pref_get gate_builder_routing)" != "on" ]] \
  && ok_t "P0 gate_builder_routing is OFF (so routing here is by KIND, as in production)" \
  || bad_t "P0 gate_builder_routing is OFF" "pref is on — the A1 arm would pass via the pref, not the fix"

# ---- A1. ACCEPTANCE 1: the root's tier-1 engineering approval routes to the sealed lead
# and the human is NOT pinged.
route_reset; seed DIVE-3901; fixture_actor olivia
cmd_task_need DIVE-3901 --type=approval --ask="$ENG_ASK" --from=olivia >/dev/null 2>&1
[[ ( "$(route_last)" == "main" || "$(queued_for DIVE-3901 main)" == "1" ) && "$(rr_of DIVE-3901)" == "main" ]] \
  && ok_t "A1 root's tier-1 eng approval routes to the sealed standing lead 'main'" \
  || bad_t "A1 root's tier-1 eng approval routes to 'main'" "route_last=$(route_last) queued=$(queued_for DIVE-3901 main) routed_reviewer=$(rr_of DIVE-3901) tier=$(tier_of DIVE-3901)"
[[ "$HUMAN_PINGED" == "0" ]] \
  && ok_t "A1 the paired human is NOT pinged (the three weeks this ticket is about)" \
  || bad_t "A1 human not pinged" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(tier_of DIVE-3901)" == "1" ]] \
  && ok_t "A1 the gate is still tier 1 — routing moved, tiering did not" \
  || bad_t "A1 tier unchanged at 1" "tier=$(tier_of DIVE-3901)"
# DIVE-3171: WHO routed and WHY land in the same write. cmd_task_answer reads this
# column to keep the clear stamped `lead:standing:` instead of `lead:` — graded in
# tests/gate_lead_clear_stamp_unit.sh arms 5b/5c/5d — so a route recorded without its
# source is a stamp that silently loses the seal.
[[ "$(rp_of DIVE-3901)" == "seal:standing-lead" ]] \
  && ok_t "A1 the route's SOURCE is persisted beside the reviewer (route_provenance)" \
  || bad_t "A1 route_provenance persisted" "route_provenance='$(rp_of DIVE-3901)'"
[[ "$(spy_n)" == "1" && "$(spy_last)" == *"outcome=routed"* && "$(spy_last)" == *"standing_lead=main"* && "$(spy_last)" == *"routed=main"* ]] \
  && ok_t "A1 the decision is audited at the moment it is made (outcome=routed)" \
  || bad_t "A1 audit row" "n=$(spy_n) last=$(spy_last)"

# ---- A2. ACCEPTANCE 2: a gate that is NOT lead-standing-eligible, filed by the root,
# still reaches the human and reaches NO agent. Four independent conjuncts, one arm each
# — the fallback must not become a way to launder a hard gate past a person.
a2_arm() {  # $1=ident $2=label $3=ask $4=extra-flag
  route_reset; seed "$1"; fixture_actor olivia
  cmd_task_need "$1" --type=approval --ask="$3" ${4:+"$4"} --from=olivia >/dev/null 2>&1
  [[ "$HUMAN_PINGED" == "1" && "$(route_sent)" == "0" && -z "$(rr_of "$1")" ]] \
    && ok_t "A2 $2 filed by the root stays HUMAN and reaches no agent" \
    || bad_t "A2 $2 stays human" "human=$HUMAN_PINGED sent=$(route_sent) routed_reviewer=$(rr_of "$1") tier=$(tier_of "$1") spy=$(spy_last)"
  [[ "$(spy_last)" == *"outcome=not-standing-eligible"* ]] \
    && ok_t "A2 $2 is refused by the ELIGIBILITY conjunct (audited)" \
    || bad_t "A2 $2 refused by eligibility" "spy=$(spy_last)"
}
a2_arm DIVE-3902 "an explicitly pinned --tier=2 eng ask" "$ENG_ASK" "--tier=2"
a2_arm DIVE-3903 "a money ask" 'approve the $4,000 spend on the CI runner before the push'
a2_arm DIVE-3904 "a deny-listed fleet/agent-provisioning ask" 'approve the agent create for a second frontend engineer, then push the branch'
a2_arm DIVE-3905 "a non-engineering ask (no positive eng classification)" 'approve the phrasing of the standup summary'

# ---- A3. ACCEPTANCE 3 (the negative control the ticket names): with the constitution
# DRIFTED the seal resolves nobody and the gate falls through to the human exactly as it
# does today. Fail closed. Re-sealing the SAME bytes restores it, which proves the seal —
# not the file — is the variable, so the arm above cannot be passing on a broken reader.
write_constitution "$(constitution_yaml main)"$'\n# drift\n'
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "A3 drift resolves no standing lead" \
  || bad_t "A3 drift resolves no standing lead" "got '$(_gate_standing_lead)'"
route_reset; seed DIVE-3906; fixture_actor olivia
cmd_task_need DIVE-3906 --type=approval --ask="$ENG_ASK" --from=olivia >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(route_sent)" == "0" && -z "$(rr_of DIVE-3906)" ]] \
  && ok_t "A3 under drift the root's eng approval falls through to the human (fail closed)" \
  || bad_t "A3 drift falls through to the human" "human=$HUMAN_PINGED sent=$(route_sent) routed_reviewer=$(rr_of DIVE-3906)"
[[ "$(spy_last)" == *"outcome=no-standing-lead"* ]] \
  && ok_t "A3 the fall-through is audited as no-standing-lead, not as an absent build" \
  || bad_t "A3 drift audited" "spy=$(spy_last)"
anchor_to main
[[ "$(_gate_standing_lead)" == "main" ]] \
  && ok_t "A3 re-sealing the same bytes restores the lead — the SEAL is the variable" \
  || bad_t "A3 re-seal restores" "got '$(_gate_standing_lead)'"

# ---- A4. The seal naming the ROOT HERSELF must not route: that is the self-clear path
# DIVE-2099 exists to refuse, and re-creating it here would be the same defect wearing
# the fix's clothes.
anchor_to olivia
route_reset; seed DIVE-3907; fixture_actor olivia
cmd_task_need DIVE-3907 --type=approval --ask="$ENG_ASK" --from=olivia >/dev/null 2>&1
[[ "$HUMAN_PINGED" == "1" && "$(route_sent)" == "0" && -z "$(rr_of DIVE-3907)" ]] \
  && ok_t "A4 a standing lead equal to the filer does not self-route" \
  || bad_t "A4 no self-route" "human=$HUMAN_PINGED sent=$(route_sent) routed_reviewer=$(rr_of DIVE-3907)"
[[ "$(spy_last)" == *"outcome=standing-lead-is-filer"* ]] \
  && ok_t "A4 the refusal names its reason (standing-lead-is-filer)" \
  || bad_t "A4 self-route reason" "spy=$(spy_last)"
anchor_to main

# ---- A5. NEGATIVE CONTROL: a NON-root filer's identical gate is untouched. dev has a
# chart lead, so the chart routes it and this branch must not run AT ALL — an audit row
# here would mean the fallback is evaluating gates it has no business evaluating.
route_reset; seed DIVE-3908; fixture_actor dev
cmd_task_need DIVE-3908 --type=approval --ask="$ENG_ASK" --from=dev >/dev/null 2>&1
[[ ( "$(route_last)" == "main" || "$(queued_for DIVE-3908 main)" == "1" ) && "$(rr_of DIVE-3908)" == "main" && "$HUMAN_PINGED" == "0" ]] \
  && ok_t "A5 a builder's identical gate still routes via the CHART to main" \
  || bad_t "A5 builder routes via the chart" "route_last=$(route_last) queued=$(queued_for DIVE-3908 main) routed_reviewer=$(rr_of DIVE-3908) human=$HUMAN_PINGED"
[[ "$(spy_n)" == "0" ]] \
  && ok_t "A5 the fallback does not even evaluate a routeable filer's gate" \
  || bad_t "A5 fallback stays out of the routeable path" "spy=$(spy_last)"
# The discriminator the answer path reads: a chart route must say `chart`, or a
# chart-routed clear would acquire the standing label meant for the seal.
[[ "$(rp_of DIVE-3908)" == "chart" ]] \
  && ok_t "A5 a chart route records itself as 'chart', never as the seal" \
  || bad_t "A5 chart route_provenance" "route_provenance='$(rp_of DIVE-3908)'"

# ---- A6. TYPE NARROWING: `decision` is agent-clearable by TYPE already, so it is not in
# the standing authority's scope and must not acquire a route here. This is the ticket's
# negative arm — do NOT widen this to route ALL unrouteable gates to the lead.
route_reset; seed DIVE-3909; fixture_actor olivia
cmd_task_need DIVE-3909 --type=decision --options='A|B' --recommend='A' --ask="$ENG_ASK" --from=olivia >/dev/null 2>&1
[[ "$(route_sent)" == "0" && -z "$(rr_of DIVE-3909)" ]] \
  && ok_t "A6 a root-filed DECISION is not standing-routed (type is not in scope)" \
  || bad_t "A6 decision not standing-routed" "sent=$(route_sent) routed_reviewer=$(rr_of DIVE-3909) spy=$(spy_last)"
[[ "$(spy_last)" == *"outcome=not-standing-eligible"* ]] \
  && ok_t "A6 the type narrowing is the recorded reason" \
  || bad_t "A6 decision reason" "spy=$(spy_last)"

# ---- A7. The DIVE-1495 verifier route still wins where it fired: that gate already has
# an agent routee, so it is not the "chart resolved nobody" case this fix is about.
# The ask is deliberately NOT push-for-review shaped, or DIVE-3117 would suppress the
# verifier route and the arm would grade 3117 instead of this.
route_reset; seed_loop DIVE-3910; fixture_actor olivia
cmd_task_need DIVE-3910 --type=approval --ask='OK to land the refactor of the task router?' --from=olivia >/dev/null 2>&1
[[ ( "$(route_last)" == "quinn" || "$(queued_for DIVE-3910 quinn)" == "1" ) && "$(rr_of DIVE-3910)" == "quinn" ]] \
  && ok_t "A7 a live verifier route still wins over the standing fallback" \
  || bad_t "A7 verifier route wins" "route_last=$(route_last) queued=$(queued_for DIVE-3910 quinn) routed_reviewer=$(rr_of DIVE-3910)"
[[ "$(spy_n)" == "0" ]] \
  && ok_t "A7 the fallback does not evaluate a verifier-routed gate" \
  || bad_t "A7 fallback stays out of the verifier path" "spy=$(spy_last)"
[[ "$(rp_of DIVE-3910)" == "verifier-loop" ]] \
  && ok_t "A7 a verifier route records itself as 'verifier-loop'" \
  || bad_t "A7 verifier route_provenance" "route_provenance='$(rp_of DIVE-3910)'"

fixture_actor fixture-runner
echo "-----"
echo "gate_root_filer_standing_route_unit: $PASS passed, $FAIL failed"
SUMMARY_PRINTED=1
[[ "$FAIL" == "0" ]]
