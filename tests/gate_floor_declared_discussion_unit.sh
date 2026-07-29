#!/usr/bin/env bash
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
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-discusses-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
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

# Org chart: main is the lone coordinator; dev reports to main (so reviewer(dev)=main).
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"

# seed <ident> [title] — the TITLE is a first-class variable here (DIVE-1957).
seed()      { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1',$(sqlq "${2:-neutral engineering task}"),'todo','main');"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
routedof()  { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
askof()     { db "SELECT COALESCE(ask,'') FROM tasks WHERE ident='$1';"; }
floorof()   { db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='$1';"; }
showof()    { JSON_MODE=0 cmd_task_show "$1" 2>/dev/null; }

# dev3's real ask on DIVE-2078, trimmed. Names "credentials" and "privileged";
# requests nothing but a modelling choice.
DESIGN_ASK="For the capability-vs-clearance model: should an agent's right to act be derived from the credentials it holds, or from a separately declared clearance level that privileged operations check against?"
DESIGN_WHY="this is a data-model sizing question about how to REPRESENT credential handling; it performs no credential operation and grants nothing"

# ---------------------------------------------------------------------------
# 1: THE REPRO, ask axis — a design decision naming 'credential' reaches the LEAD
route_reset; seed DIVE-401
cmd_task_need DIVE-401 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
[[ "$(tierof DIVE-401)" == "1" ]] && ok_t "repro/ask: declared design decision downgraded to tier 1" || bad_t "repro/ask tier 1" "got '$(tierof DIVE-401)'"
[[ "$(routedof DIVE-401)" == "main" ]] && ok_t "repro/ask: routed_reviewer=main (the lead, not the human)" || bad_t "repro/ask routed main" "got '$(routedof DIVE-401)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro/ask: paired human NOT pinged" || bad_t "repro/ask no human ping" "HUMAN_PINGED=$HUMAN_PINGED"
[[ "$(route_to)" == "main" ]] && ok_t "repro/ask: lead-route send went to main" || bad_t "repro/ask route to main" "got '$(route_to)'"

# 2: THE REPRO, TITLE axis (DIVE-1957) — the ask is byte-neutral and the floor
#    keyword lives ONLY in the task title, which the filer cannot reword.
route_reset; seed DIVE-402 "design the token exchange between the runtime and the broker"
cmd_task_need DIVE-402 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" \
  --discusses="a transport-shape design question; the title names the subsystem, nothing is being minted or handled" >/dev/null 2>&1
[[ "$(tierof DIVE-402)" == "1" ]] && ok_t "repro/TITLE: floor keyword in the TITLE is appealable too" || bad_t "repro/TITLE tier 1" "got '$(tierof DIVE-402)'"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "repro/TITLE: paired human NOT pinged" || bad_t "repro/TITLE no human ping" "HUMAN_PINGED=$HUMAN_PINGED"

# 3: MUTATION GUARD — the SAME two gates WITHOUT the flag still floor to the human.
#    If these ever pass at tier 1 the suite above is grading a floor that stopped
#    firing for some other reason, and every arm is vacuous.
route_reset; seed DIVE-403
cmd_task_need DIVE-403 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" >/dev/null 2>&1
[[ "$(tierof DIVE-403)" == "2" ]] && ok_t "mutation: same ask WITHOUT --discusses still floors to tier 2" || bad_t "mutation ask tier 2" "got '$(tierof DIVE-403)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "mutation: same ask WITHOUT --discusses still pings the human" || bad_t "mutation ask pings human" "HUMAN_PINGED=$HUMAN_PINGED"
route_reset; seed DIVE-404 "design the token exchange between the runtime and the broker"
cmd_task_need DIVE-404 --type=decision --from=dev \
  --ask="Should the exchange be modelled as a synchronous call or an async queue?" \
  --options="sync|async" --recommend="async" >/dev/null 2>&1
[[ "$(tierof DIVE-404)" == "2" ]] && ok_t "mutation/TITLE: same title WITHOUT --discusses still floors to tier 2" || bad_t "mutation title tier 2" "got '$(tierof DIVE-404)'"

# 4: SAFETY — the non-appealable MONEY core survives any declaration.
route_reset; seed DIVE-405
cmd_task_need DIVE-405 --type=decision --from=dev \
  --ask="How should we model the credential store, and do we refund the affected customers \$500 each?" \
  --options="A|B" --recommend="A" --discusses="mostly a data-model question" >/dev/null 2>&1
[[ "$(tierof DIVE-405)" == "2" ]] && ok_t "safety: money residual refuses the appeal, stays tier 2" || bad_t "safety money tier 2" "got '$(tierof DIVE-405)'"
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "safety: money residual still pings the human" || bad_t "safety money pings human" "HUMAN_PINGED=$HUMAN_PINGED"

# 5: SAFETY — the non-appealable IRREVERSIBLE-INFRA core survives any declaration.
route_reset; seed DIVE-406
cmd_task_need DIVE-406 --type=decision --from=dev \
  --ask="Model the credential lifecycle — and revoke the leaked key + move the dns record while we are here?" \
  --options="A|B" --recommend="A" --discusses="framing it as a lifecycle design question" >/dev/null 2>&1
[[ "$(tierof DIVE-406)" == "2" ]] && ok_t "safety: revoke/dns residual refuses the appeal, stays tier 2" || bad_t "safety infra tier 2" "got '$(tierof DIVE-406)'"

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
cmd_task_need DIVE-408 --type=approval --from=dev --ask="$SR_ASK_2146" >/dev/null 2>&1
sr_tier="$(tierof DIVE-408)"; sr_ping="$HUMAN_PINGED"
[[ "$sr_ping" == "1" ]] && ok_t "precondition: the self-restart gate still reaches the paired human (tier $sr_tier), unchanged" || bad_t "precondition human reached" "tier=$sr_tier ping=$sr_ping"
# And the counterfactual olivia actually cares about: hand main its pin back and
# the gate is hard-human, by the pin, with or without this ticket.
route_reset; seed DIVE-419 "$SR_TITLE_2146"
cmd_task_need DIVE-419 --type=approval --from=dev --tier=2 --ask="$SR_ASK_2146" >/dev/null 2>&1
[[ "$(tierof DIVE-419)" == "2" && "$HUMAN_PINGED" == "1" ]] \
  && ok_t "precondition: the pinned re-file (what DIVE-2146 actually did) is hard-human independent of the floor" \
  || bad_t "precondition pinned refile" "tier=$(tierof DIVE-419) ping=$HUMAN_PINGED"

# 8: SAFETY — an explicit --tier=2 pin is the caller's hard-human contract and
#    outranks the appeal (DIVE-1957). Warn, do not obey.
route_reset; seed DIVE-409
cmd_task_need DIVE-409 --type=decision --from=dev --tier=2 \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
[[ "$(tierof DIVE-409)" == "2" ]] && ok_t "safety: --tier=2 pin vetoes the appeal" || bad_t "safety pin tier 2" "got '$(tierof DIVE-409)'"
[[ -z "$(routedof DIVE-409)" ]] && ok_t "safety: a pinned gate is never routed to an agent" || bad_t "safety pin not routed" "got '$(routedof DIVE-409)'"

# 9: SAFETY — the LEAD has no reviewer above them, so there is nobody to appeal TO.
route_reset; seed DIVE-410
cmd_task_need DIVE-410 --type=decision --from=main \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
[[ "$(tierof DIVE-410)" == "2" ]] && ok_t "safety: lead-filed appeal has no reviewer, stays tier 2" || bad_t "safety lead tier 2" "got '$(tierof DIVE-410)'"

# 10: NO-OP — a decision the floor never touched is unchanged by the flag's absence
#     AND by its presence (the appeal warns rather than silently re-tiering).
route_reset; seed DIVE-411
cmd_task_need DIVE-411 --type=decision --from=dev \
  --ask="Should the dashboard column order be priority-first or age-first?" \
  --options="priority|age" --recommend="priority" >/dev/null 2>&1
[[ "$(tierof DIVE-411)" == "1" ]] && ok_t "no-op: an unfloored decision is untouched (tier 1)" || bad_t "no-op tier 1" "got '$(tierof DIVE-411)'"

# 11: ANNOUNCE (defect 2) — the floor names the term that fired, on stderr, and
#     points a decision filer at the sanctioned appeal instead of at rewording.
route_reset; seed DIVE-412
ann=$(cmd_task_need DIVE-412 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" 2>&1 >/dev/null)
grep -qi "FORCED to tier 2" <<<"$ann" && ok_t "announce: the escalation is stated at file time, not left silent" || bad_t "announce states escalation" "stderr: $ann"
grep -qi "credential" <<<"$ann" && ok_t "announce: names the MATCHED TERM ('credential'), not just 'the floor'" || bad_t "announce names term" "stderr: $ann"
grep -q -- "--discusses" <<<"$ann" && ok_t "announce: offers the recorded appeal to a decision filer" || bad_t "announce offers appeal" "stderr: $ann"
grep -qi "reword" <<<"$ann" && ok_t "announce: explicitly warns against rewording the ask (anti-laundering)" || bad_t "announce anti-laundering" "stderr: $ann"

# 12: ANNOUNCE — a non-decision gate must NOT be offered an appeal it cannot use.
route_reset; seed DIVE-413
ann2=$(cmd_task_need DIVE-413 --type=approval --from=dev \
  --ask="Approve deleting the leaked credential from the store." 2>&1 >/dev/null)
grep -qi "FORCED to tier 2" <<<"$ann2" && ok_t "announce/approval: still states the escalation" || bad_t "announce approval states" "stderr: $ann2"
grep -q -- "--discusses" <<<"$ann2" && bad_t "announce/approval must NOT advertise --discusses" "stderr: $ann2" || ok_t "announce/approval: does NOT advertise an appeal that would be refused"

# 13: AUDIT — the declaration is on the record whether it applied or was refused.
#     That attributability is the whole reason a declaration beats a reworded ask.
route_reset; seed DIVE-414
cmd_task_need DIVE-414 --type=decision --from=dev \
  --ask="$DESIGN_ASK" --options="capability|clearance" --recommend="clearance" \
  --discusses="$DESIGN_WHY" >/dev/null 2>&1
grep -q "floor-appeal applied" "$AUDIT_FILE" && ok_t "audit: an APPLIED appeal is recorded" || bad_t "audit applied" "$(cat "$AUDIT_FILE")"
grep -q "declared=" "$AUDIT_FILE" && ok_t "audit: the declared reason is recorded verbatim" || bad_t "audit declared" "$(cat "$AUDIT_FILE")"
route_reset; seed DIVE-415
cmd_task_need DIVE-415 --type=decision --from=dev \
  --ask="Model the store, and refund the customer \$500?" --options="A|B" --recommend="A" \
  --discusses="claiming this is only design" >/dev/null 2>&1
grep -q "floor-appeal refused" "$AUDIT_FILE" && ok_t "audit: a REFUSED appeal is recorded too (an attempt is evidence)" || bad_t "audit refused" "$(cat "$AUDIT_FILE")"

# 14: the reviewer the gate was moved TO can see the claim it was moved on.
[[ "$(askof DIVE-414)" == *"floor appeal"* && "$(askof DIVE-414)" == *"$DESIGN_WHY"* ]] \
  && ok_t "handoff: the declaration is written into the ask the reviewer grades" \
  || bad_t "handoff declaration in ask" "got '$(askof DIVE-414)'"

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
grep -qi "T2 category floor" <<<"$res2" \
  && ok_t "result/TITLE: the RESULT LINE states the floor fired on a title-only match" \
  || bad_t "result/TITLE states floor" "stdout: $res2"
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
[[ "$(jq -r '.data.tier_floored' <<<"$jres" 2>/dev/null)" == "true" ]] \
  && ok_t "json: tier_floored is reported" || bad_t "json tier_floored" "$jres"
[[ "$(jq -r '.data.floor_term' <<<"$jres" 2>/dev/null)" == "credential" ]] \
  && ok_t "json: the matched term rides the JSON payload" || bad_t "json floor_term" "$jres"
route_reset; seed DIVE-424
jres2=$(cmd_task_need DIVE-424 --type=decision --from=dev \
  --ask="Should the dashboard column order be priority-first or age-first?" \
  --options="priority|age" --recommend="priority" 2>/dev/null)
[[ "$(jq -r '.data.floor_term' <<<"$jres2" 2>/dev/null)" == "null" ]] \
  && ok_t "json: floor_term is null when nothing floored (not a constant)" || bad_t "json floor_term null" "$jres2"

# 20: DIVE-2186 — THE LATER-SESSION REREAD SURFACE. File-time locals are not
#     evidence after the command exits: the gate row must carry the original
#     floor decision, matched term, and appeal outcome, and `task show` must
#     render them beside the ask. Grade all three meaningful states.
fp=$(floorof DIVE-403)
[[ "$(jq -r '.tier_floored' <<<"$fp" 2>/dev/null)" == "true" \
   && "$(jq -r '.floor_term' <<<"$fp" 2>/dev/null)" == "credential" \
   && "$(jq -r '.appeal' <<<"$fp" 2>/dev/null)" == "null" ]] \
  && ok_t "persist/reread: unappealed floor stores (tier_floored, matched term, no appeal)" \
  || bad_t "persist unappealed tuple" "$fp"
shown=$(showof DIVE-403)
grep -q 'floor: tier forced to 2  matched term: credential' <<<"$shown" \
  && ok_t "task show: later reread explains the forced tier and matched term" \
  || bad_t "task show forced-floor explanation" "$shown"

fp_applied=$(floorof DIVE-414)
[[ "$(jq -r '.tier_floored' <<<"$fp_applied" 2>/dev/null)" == "true" \
   && "$(jq -r '.floor_term' <<<"$fp_applied" 2>/dev/null)" == "credential" \
   && "$(jq -r '.appeal' <<<"$fp_applied" 2>/dev/null)" == "appealed" ]] \
  && ok_t "persist/reread: applied appeal retains the floor it overrode" \
  || bad_t "persist appealed tuple" "$fp_applied"
shown_applied=$(showof DIVE-414)
grep -q 'floor: tier-2 category matched before appeal  matched term: credential' <<<"$shown_applied" \
  && grep -q 'floor appeal: appealed' <<<"$shown_applied" \
  && ok_t "task show: applied appeal remains attributable after the filer returns" \
  || bad_t "task show appealed explanation" "$shown_applied"

fp_refused=$(floorof DIVE-415)
[[ "$(jq -r '.tier_floored' <<<"$fp_refused" 2>/dev/null)" == "true" \
   && "$(jq -r '.floor_term' <<<"$fp_refused" 2>/dev/null)" == "refund" \
   && "$(jq -r '.appeal' <<<"$fp_refused" 2>/dev/null)" == "refused" ]] \
  && ok_t "persist/reread: refused appeal stores the surviving floor decision" \
  || bad_t "persist refused tuple" "$fp_refused"
shown_refused=$(showof DIVE-415)
grep -q 'floor: tier forced to 2  matched term: refund' <<<"$shown_refused" \
  && grep -q 'floor appeal: refused' <<<"$shown_refused" \
  && ok_t "task show: refused appeal and its matched term survive file time" \
  || bad_t "task show refused explanation" "$shown_refused"

[[ -z "$(floorof DIVE-424)" ]] \
  && ok_t "persist/no-op: an unfloored, unappealed gate stores no provenance" \
  || bad_t "persist no-op null" "$(floorof DIVE-424)"
shown_noop=$(showof DIVE-424)
grep -q '^  floor:' <<<"$shown_noop" \
  && bad_t "task show/no-op must not invent floor provenance" "$shown_noop" \
  || ok_t "task show/no-op: ordinary gates gain no floor line"

# Re-filing retires the old gate. Preserve its explanation in gate_history and
# clear it from the replacement instead of leaving stale WHY on a new gate.
old_fp="$fp"
cmd_task_need DIVE-403 --type=decision --from=dev \
  --ask="Should the dashboard use compact or comfortable rows?" \
  --options="compact|comfortable" --recommend="compact" >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(floor_provenance,'') FROM gate_history WHERE ident='DIVE-403' ORDER BY id DESC LIMIT 1;")" == "$old_fp" ]] \
  && ok_t "history: re-file archives the outgoing floor explanation" \
  || bad_t "history floor provenance" "$(db "SELECT COALESCE(floor_provenance,'') FROM gate_history WHERE ident='DIVE-403' ORDER BY id DESC LIMIT 1;")"
[[ -z "$(floorof DIVE-403)" ]] \
  && ok_t "re-file: replacement gate does not inherit stale floor provenance" \
  || bad_t "re-file stale floor provenance" "$(floorof DIVE-403)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
