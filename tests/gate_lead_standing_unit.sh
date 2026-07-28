#!/usr/bin/env bash
# DIVE-2099 isolated unit harness for the ORG LEAD's STANDING authority to clear an
# ENGINEERING approval gate (lodar granted it 2026-07-26; main filed rather than
# implemented it because the requester is the beneficiary).
#
# BEFORE: the only lead-clear path (DIVE-1182/1243) required the gate to have been
# ROUTED to the lead at filing time — routed_reviewer == the authenticated caller. An
# engineering approval that reached the human WITHOUT routing (pref off, filer-is-lead,
# a re-route that NULLed the reviewer, a pre-routing row) was human-only forever even
# though its whole content was a judgement the lead can make. Three of the 14 gates in
# lodar's inbox on 2026-07-26 were that shape.
#
# AFTER: `_gate_lead_standing_eligible` grants the same clearance with no routing, as a
# CONJUNCTION — authenticated caller IS the org lead, type is exactly `approval`, tier
# is exactly 1, the text positively classifies as engineering, AND it trips neither the
# true-human T2 floor nor the ticket's explicit out-of-scope list. Every unknown denies.
#
# The assertions below are the boundary, not the happy path: S2/S3/S5..S9 all check that
# the authority does NOT reach somewhere. S1 and S10 are the non-vacuity arms — without
# them a totally broken predicate that always returns 1 would pass every other case.
# Run: bash tests/gate_lead_standing_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-lead-standing-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# STATE_DIR must be set BEFORE cmd_council.sh is sourced: its COUNCIL_DIR/COUNCIL_LINEAGE
# are source-time globals derived from it (they are re-pinned below anyway, belt-and-braces).
STATE_DIR="$TMP"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_council.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_council.sh LAST, matching the production bundle order (CNCL-14) — the council
# loader is what makes `_gate_standing_lead` resolvable at all. Sourcing it here is not
# convenience: the whole iteration-2 anchor lives in those three council helpers, and a
# harness that stubbed them would be testing its own stubs.
COUNCIL_DIR="$STATE_DIR/council"; COUNCIL_LINEAGE="$COUNCIL_DIR/lineage.jsonl"
TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# File-backed audit observer: cmd_task_answer runs inside `$(...)` in the capturing
# cases, so a plain var would be lost. Records every audit row the answer path emits.
AUDIT_FILE="$TMP/audit"; : > "$AUDIT_FILE"
audit_log() { printf '%s\n' "$*" >> "$AUDIT_FILE"; }
_af_reset() { : > "$AUDIT_FILE"; }
_af()       { cat "$AUDIT_FILE" 2>/dev/null; }
task_need_notify() { :; }
# The task-store audit fence (DIVE-2054) checks the store is production; this harness is
# deliberately isolated, so open the fence or every row is withheld and the audit
# assertions below would pass vacuously against an empty file.
_task_human_send_allowed() { return 0; }

# Only `id -un` is stubbed — `_gate_authenticated_actor` and `_task_resolve_coordinator`
# run for real, because THEY are what decides the authority.
FAKE_CALLER="agent-marcus"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

# Org chart: marcus is the coordinator (the org lead), dev reports to marcus.
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('marcus','coordinator',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('dev','builder','marcus');"
[[ "$(_task_resolve_coordinator)" == "marcus" ]] \
  || { printf 'FAIL - harness precondition: org lead did not resolve to marcus\n'; exit 1; }

# --- the ANCHOR (iteration 2, lodar answered `anchor-to-named-agent` 2026-07-27) -------
# The holder is the agent NAMED in the constitution, and the name counts only while the
# file still matches the digest SEALED into the council lineage. These helpers write both
# halves so every arm below exercises the real `_council_*` chain, not a stub.
constitution_yaml() {  # $1 = the named eng_approval_lead ('' = none), $2 = extra body
  # NO `hard_gates:` key on purpose: absent means the loader keeps the SHIPPED default
  # classes, so the tier-2 floor these arms lean on behaves exactly as in production. A
  # trimmed hard_gates block here would silently narrow the floor and green S5/S5d for
  # the wrong reason.
  printf 'ship:\ncomms:\n'
  [[ -n "${1:-}" ]] && printf 'authority:\n  eng_approval_lead: %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2"
  return 0
}
write_constitution() { mkdir -p "$STATE_DIR"; printf '%s' "$1" > "$STATE_DIR/constitution.yaml"; }
seal_constitution()  { # seal whatever bytes are on disk right now
  mkdir -p "$COUNCIL_DIR"
  printf '{"seq":1,"record":{"constitutionDigest":"%s"}}\n' \
    "$(sha256sum < "$STATE_DIR/constitution.yaml" | awk '{print $1}')" > "$COUNCIL_LINEAGE"
}
anchor_to() { write_constitution "$(constitution_yaml "$1")"; seal_constitution; }

anchor_to marcus
[[ "$(_gate_standing_lead)" == "marcus" ]] \
  || { printf 'FAIL - harness precondition: the sealed constitution did not anchor to marcus (got %s)\n' "$(_gate_standing_lead)"; exit 1; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1',$(sqlq "${2:-t}"),'todo','dev');"; }
answered()  { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }
provof()    { db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='$1';"; }
tierof()    { db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='$1';"; }
typeof_()   { db "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='$1';"; }
revof()     { db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='$1';"; }
unroute()   { db "UPDATE tasks SET routed_reviewer=NULL WHERE ident='$1';"; }

export SUDO_UID=1234          # agent-ish uid: NOT the non-agent human-evidence form
touch "$GATE_PROOF_ENFORCE"   # enforcement ON — the human-only floor is live

# ---------------------------------------------------------------------------------
# S1: THE GRANT. An UNROUTED tier-1 engineering approval, answered by the org lead,
#     now CLEARS — and is stamped with the distinct `lead:standing:` provenance.
#     Non-vacuity arm: if the predicate never fired, this case fails.
# ---------------------------------------------------------------------------------
seed_task DIVE-401 "delegated push for the retry backoff fix"
cmd_task_need DIVE-401 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-401   # the gap this ticket closes: no routed_reviewer to lean on
[[ "$(typeof_ DIVE-401)" == "approval" && "$(tierof DIVE-401)" == "1" && -z "$(revof DIVE-401)" ]] \
  && ok_t "S1 precond: unrouted tier-1 approval (the shape that was human-only)" \
  || bad_t "S1 precond" "type=$(typeof_ DIVE-401) tier=$(tierof DIVE-401) rev='$(revof DIVE-401)'"
_af_reset
out=$(cmd_task_answer DIVE-401 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -eq 0 && "$(answered DIVE-401)" == "closed" ]] \
  && ok_t "S1 org lead CLEARS an unrouted engineering approval (standing authority)" \
  || bad_t "S1 lead clears unrouted eng approval" "rc=$rc state=$(answered DIVE-401) out=$out"
[[ "$(provof DIVE-401)" == "lead:standing:marcus" ]] \
  && ok_t "S1 provenance is lead:standing:marcus — distinct from human:* AND from lead:*" \
  || bad_t "S1 standing provenance" "got '$(provof DIVE-401)'"
[[ "$(provof DIVE-401)" != human:* ]] \
  && ok_t "S1 never reuses the human:* shape (design note 3)" \
  || bad_t "S1 not human:*" "got '$(provof DIVE-401)'"
# The audit row must be the POST-WRITE one and must quote what actually landed in the
# row (DIVE-2090: a pre-check row greens identically whether or not the write happened).
grep -q "task answer lead-standing-clear" <<<"$(_af)" \
  && ok_t "S1 emits a DISTINCT lead-standing-clear audit event" \
  || bad_t "S1 distinct audit event" "audit=$(_af)"
grep -q "persisted_provenance=lead:standing:marcus" <<<"$(_af)" \
  && ok_t "S1 audit quotes the PERSISTED provenance read back from the row" \
  || bad_t "S1 audit reads back the write" "audit=$(_af)"
grep -q "authenticated_caller=marcus" <<<"$(_af)" \
  && ok_t "S1 audit names the authenticated (kernel) caller, not --from" \
  || bad_t "S1 audit names authenticated caller" "audit=$(_af)"

# ---------------------------------------------------------------------------------
# S2: NOT A GENERAL AMNESTY. The same gate answered by a NON-lead builder is refused —
#     the authority is the ORG LEAD's, and identity comes from the kernel, not --from.
#     (`--from=marcus` here is the spoof: task_actor returns it verbatim.)
# ---------------------------------------------------------------------------------
seed_task DIVE-402 "delegated push for the retry backoff fix"
cmd_task_need DIVE-402 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-402
FAKE_CALLER="agent-dev"
out=$(cmd_task_answer DIVE-402 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-402)" == "open" ]] \
  && ok_t "S2 a NON-lead agent is still REFUSED (authority is the lead's alone)" \
  || bad_t "S2 non-lead refused" "rc=$rc state=$(answered DIVE-402) out=$out"
[[ "$(provof DIVE-402)" != *"standing"* ]] \
  && ok_t "S2 a spoofed --from=marcus cannot mint lead:standing (DIVE-2004)" \
  || bad_t "S2 --from spoof blocked" "got '$(provof DIVE-402)'"
FAKE_CALLER="agent-marcus"

# ---------------------------------------------------------------------------------
# S3: FAIL CLOSED on the unclassifiable. A tier-1 approval that does NOT positively
#     classify as engineering stays human-only — absence of evidence denies.
# ---------------------------------------------------------------------------------
seed_task DIVE-403 "Q3 headcount"
cmd_task_need DIVE-403 --type=approval --tier=1 --ask="approve the Q3 headcount plan for the team" >/dev/null 2>&1
unroute DIVE-403
out=$(cmd_task_answer DIVE-403 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-403)" == "open" ]] \
  && ok_t "S3 a NON-engineering tier-1 approval stays human-only (fail closed)" \
  || bad_t "S3 non-engineering refused" "rc=$rc state=$(answered DIVE-403) out=$out"

# ---------------------------------------------------------------------------------
# S4: EMPTY ask — nothing to classify, so nothing to grant. (The predicate is called
#     directly: cmd_task_need requires an ask, so this is the legacy/hand-edited row.)
# ---------------------------------------------------------------------------------
_gate_lead_standing_eligible approval 1 "   " \
  && bad_t "S4 empty text denies" "eligible on an empty ask" \
  || ok_t "S4 an empty ask+title is unclassifiable -> denied"

# ---------------------------------------------------------------------------------
# S5: THE T2 FLOOR IS NOT PIERCED. An engineering-shaped ask carrying a true-human
#     floor term is tier-2 and stays human-only — DIVE-2089 owns the floor's
#     subject-matter misread; this authority deliberately does not route around it.
# ---------------------------------------------------------------------------------
seed_task DIVE-405 "rotate the deploy key"
cmd_task_need DIVE-405 --type=approval --tier=1 --ask="approve merging the branch that rotates the deploy credential" >/dev/null 2>&1
[[ "$(tierof DIVE-405)" == "2" ]] \
  && ok_t "S5 precond: the T2 category floor still fires (tier forced to 2)" \
  || bad_t "S5 precond floor fires" "tier=$(tierof DIVE-405)"
unroute DIVE-405
out=$(cmd_task_answer DIVE-405 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-405)" == "open" ]] \
  && ok_t "S5 a tier-2 gate is NOT reachable by the standing authority" \
  || bad_t "S5 tier-2 unreachable" "rc=$rc state=$(answered DIVE-405) out=$out"
# ...and the predicate itself refuses tier 2 even if the answer path ever changed.
_gate_lead_standing_eligible approval 2 "approve merging the branch" \
  && bad_t "S5b predicate denies tier 2" "eligible at tier 2" \
  || ok_t "S5b predicate itself refuses tier 2 (defense in depth)"
_gate_lead_standing_eligible approval "" "approve merging the branch" \
  && bad_t "S5c predicate denies an empty tier" "eligible on a legacy NULL tier" \
  || ok_t "S5c a legacy/NULL tier is not a tier-1 gate -> denied"

__S5D__
# S5d: THE FLOOR RE-CHECK, ISOLATED. S5 above cannot exercise it: `task need` already
# floors such a gate to tier 2, so the tier guard rejects it first and a mutant with the
# floor re-check deleted still passes every other case. The re-check earns its keep on a
# row whose STORED tier is 1 while the text trips the true-human floor — a legacy row
# filed before the floor existed, or a tier column edited after the fact. Drive the
# predicate directly, which is the only way to construct that state.
while IFS='|' read -r _label _ask; do
  [[ -n "$_label" ]] || continue
  _gate_lead_standing_eligible approval 1 "$_ask" \
    && bad_t "S5d stale tier-1 + floor text: $_label" "eligible on: $_ask" \
    || ok_t "S5d floor re-check denies a stale tier-1 row: $_label"
done <<'CASES'
credential|approve merging the branch that rotates the deploy credential
money|approve the merge and the $400 runner invoice that comes with it
destructive|approve the deploy that will purge the events table
publish|approve the merge then publish the announcement post
CASES
# Non-vacuity for S5d: the SAME ask with the floor term removed stays eligible, so the
# four denials above are attributable to the floor and not to some unrelated guard.
_gate_lead_standing_eligible approval 1 "approve merging the branch that rotates the deploy config" \
  && ok_t "S5d control: the same ask without a floor term is still eligible" \
  || bad_t "S5d control eligible" "denied the floor-free control ask"

# ---------------------------------------------------------------------------------
# S6: TYPE NARROWING. `secret` and `manual` never take this path, however
#     engineering-shaped the ask is. `decision` needs no new authority (lead-clearable
#     by type already) and is excluded so the grant stays exactly one class wide.
# ---------------------------------------------------------------------------------
for _t in secret manual decision access; do
  _gate_lead_standing_eligible "$_t" 1 "approve delegated push for review of branch fix-x" \
    && bad_t "S6 type $_t denied" "eligible for type=$_t" \
    || ok_t "S6 type '$_t' is outside the standing authority (approval only)"
done
# And end-to-end: a manual gate with an engineering ask is still refused.
seed_task DIVE-406 "smoke test the release"
cmd_task_need DIVE-406 --type=manual --tier=1 --ask="run the smoke test and approve the release build" >/dev/null 2>&1
unroute DIVE-406
out=$(cmd_task_answer DIVE-406 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-406)" == "open" ]] \
  && ok_t "S6b an engineering-shaped MANUAL gate is still human-only" \
  || bad_t "S6b manual refused" "rc=$rc state=$(answered DIVE-406) out=$out"

# ---------------------------------------------------------------------------------
# S7: THE EXPLICIT OUT-OF-SCOPE LIST — engineering vocabulary plus an out-of-scope
#     subject denies. These are the ticket's named exclusions the T2 floor does NOT
#     already cover (a customer's box, our public/marketing surfaces, a brand or
#     strategic call, fleet privilege changes).
# ---------------------------------------------------------------------------------
while IFS='|' read -r _label _ask; do
  [[ -n "$_label" ]] || continue
  _gate_lead_standing_eligible approval 1 "$_ask" \
    && bad_t "S7 out-of-scope: $_label" "eligible on: $_ask" \
    || ok_t "S7 out-of-scope denied: $_label"
done <<'CASES'
customer box|approve merging the hotfix onto the customer's box
customer host|approve the deploy to a customer vm running our stack
marketing site|approve shipping the diff to the marketing site
landing page|approve the code review then deploy the landing page
public repo|approve the merge that changes the public repo readme
brand call|approve the pull request that changes our brand voice
strategic call|approve the merge behind the strategic pivot
agent create|approve the diff then create an agent for the new lane
agent removal|approve the merge and remove agent dev3 afterwards
sudo grant|approve the deploy that adds a sudo rule for the runner
pr agency|approve the diff and the pr agency retainer alongside it
CASES
# The corresponding IN-scope asks must still be eligible, or the denylist has swallowed
# the grant and every S7 pass above would be meaningless.
while IFS='|' read -r _label _ask; do
  [[ -n "$_label" ]] || continue
  _gate_lead_standing_eligible approval 1 "$_ask" \
    && ok_t "S7b in-scope still eligible: $_label" \
    || bad_t "S7b in-scope eligible: $_label" "denied: $_ask"
done <<'CASES'
push for review|approve delegated push for review of branch fix-retry-backoff
branch clearance|approve the merge of branch dive-2099 into main
code review|code review passed, approve the diff to land
deploy our api|approve the redeploy of our api after the ci run went green
CASES

# ---------------------------------------------------------------------------------
# S8: NO RESOLVABLE LEAD, NO AUTHORITY. The lead is resolved by `_gate_route_reviewer`
#     — the FILER's manager, falling back to the org coordinator — the same resolver
#     routing uses. A filer with no manager on an AMBIGUOUS chart resolves to EMPTY, and
#     without the empty-check "" == "" would hand this authority to every caller.
# ---------------------------------------------------------------------------------
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('rival','coordinator',NULL);"
[[ -z "$(_task_resolve_coordinator)" ]] \
  && ok_t "S8 precond: an ambiguous org chart resolves the coordinator to EMPTY" \
  || bad_t "S8 precond ambiguous chart" "got '$(_task_resolve_coordinator)'"
# `orphan` is not in agents_org, so it has no manager and the resolver falls through to
# the (now ambiguous) coordinator — the only way to reach an empty lead.
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-408','delegated push for the retry backoff fix','todo','orphan');"
db "UPDATE tasks SET assignee='orphan' WHERE ident='DIVE-408';"
[[ -z "$(_gate_route_reviewer orphan)" ]] \
  && ok_t "S8 precond: an unmanaged filer on an ambiguous chart has no lead" \
  || bad_t "S8 precond orphan lead" "got '$(_gate_route_reviewer orphan)'"
cmd_task_need DIVE-408 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-408
# `task need` stamps the gate-hitting ACTOR onto assignee, so re-pin the unmanaged
# filer AFTER filing — the lead is resolved from the stored filer at answer time.
db "UPDATE tasks SET assignee='orphan', created_by='orphan' WHERE ident='DIVE-408';"
out=$(cmd_task_answer DIVE-408 --value=approved --from=marcus 2>&1); rc=$?
# ITERATION 2 INVERTS THIS ASSERTION, deliberately. Under iteration 1 an unresolvable
# CHART meant no authority; under the anchor the chart is not an input at all, so the
# constitution-named holder clears an orphan filer's gate. That is the behaviour change
# lodar chose, and asserting the old outcome would quietly re-couple the two.
[[ $rc -eq 0 && "$(provof DIVE-408)" == "lead:standing:marcus" ]] \
  && ok_t "S8 an unresolvable CHART is irrelevant — the anchored holder still clears" \
  || bad_t "S8 anchored holder clears on an unresolvable chart" "rc=$rc prov='$(provof DIVE-408)' out=$out"
# S8b: THE ARM THAT ACTUALLY EXERCISES THE EMPTY-CHECKS. S8 above only proves the
# INEQUALITY branch ("marcus" != ""), which a mutant with the -n guards removed still
# passes. The guards earn their keep only when BOTH sides are empty: a NON-agent caller
# (`_gate_authenticated_actor` returns empty by design) on a box whose org chart does not
# resolve a lead. Without `-n`, "" == "" is TRUE and the standing authority would be
# handed to a caller with no agent identity at all. Assert on the PROVENANCE, not on the
# refusal: a non-agent caller can legitimately clear the gate by other evidence forms —
# what must never happen is that clear being stamped as the lead's standing authority.
db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('DIVE-410','delegated push for the retry backoff fix','todo','orphan','orphan');"
cmd_task_need DIVE-410 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-410
db "UPDATE tasks SET assignee='orphan', created_by='orphan' WHERE ident='DIVE-410';"
FAKE_CALLER="claude"   # not agent-* -> _gate_authenticated_actor is EMPTY
_af_reset
out=$(cmd_task_answer DIVE-410 --value=approved --from=marcus 2>&1); rc=$?
[[ "$(provof DIVE-410)" != *"standing"* ]] \
  && ok_t "S8b empty caller identity + empty org lead is NOT a match ('' == '' must not grant)" \
  || bad_t "S8b empty-vs-empty must not grant" "rc=$rc prov='$(provof DIVE-410)' out=$out"
grep -q "task answer lead-standing-clear" <<<"$(_af)" \
  && bad_t "S8b no standing audit row on an unidentified caller" "audit=$(_af)" \
  || ok_t "S8b no lead-standing-clear row for an unidentified caller"
FAKE_CALLER="agent-marcus"
db "DELETE FROM agents_org WHERE name='rival';"

# ---------------------------------------------------------------------------------
# S9: NO REGRESSION on the DIVE-1182 routed lead-clear — it still stamps the plain
#     `lead:<actor>` shape, so the two clearances stay distinguishable from each other
#     and not just from a human tap.
# ---------------------------------------------------------------------------------
seed_task DIVE-409 "ship the parser fix"
cmd_task_need DIVE-409 --type=approval --ask="approve shipping the parser fix" >/dev/null 2>&1
db "UPDATE tasks SET routed_reviewer='marcus' WHERE ident='DIVE-409';"
_af_reset
out=$(cmd_task_answer DIVE-409 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -eq 0 && "$(provof DIVE-409)" == "lead:marcus" ]] \
  && ok_t "S9 the ROUTED lead-clear still stamps plain lead:marcus (unchanged)" \
  || bad_t "S9 routed lead-clear unchanged" "rc=$rc prov='$(provof DIVE-409)' out=$out"
grep -q "task answer lead-standing-clear" <<<"$(_af)" \
  && bad_t "S9 routed clear must NOT emit the standing audit event" "audit=$(_af)" \
  || ok_t "S9 a routed clear emits NO lead-standing-clear row (events stay separable)"
grep -q "standing=0" <<<"$(_af)" \
  && ok_t "S9 the lead-clear row marks standing=0 for a routed clear" \
  || bad_t "S9 lead-clear row marks standing" "audit=$(_af)"

# ---------------------------------------------------------------------------------
# S10: DOWNSTREAM. `lead:standing:<actor>` keeps the `lead:` prefix precisely so every
#      existing consumer treats it exactly as before. cmd_push's delegated-push
#      predicate is the load-bearing one (in-scope item #1 is push-for-review), and
#      cmd_goal's objective-apply floor must STILL refuse it (it demands human:*).
# ---------------------------------------------------------------------------------
_p="lead:standing:marcus"
[[ "$_p" == lead:* && "$_p" != human:* ]] \
  && ok_t "S10 shape holds: matches the lead:* consumers, never the human:* ones" \
  || bad_t "S10 shape" "got '$_p'"
if [[ -f "$SRC/cmd_push.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SRC/cmd_push.sh" 2>/dev/null
  if declare -F _push_gate_check >/dev/null; then
    db "UPDATE tasks SET need_answer='approved', need_answered_at='2026-07-26 16:00:00',
           need_answered_by='lead:standing:marcus', need_type='approval', routed_reviewer=NULL
        WHERE ident='DIVE-401';"
    _i=$(db "SELECT id FROM tasks WHERE ident='DIVE-401';")
    out=$( _push_gate_check "$_i" DIVE-401 2>&1 ); rc=$?
    [[ $rc -eq 0 ]] \
      && ok_t "S10b cmd_push accepts a lead:standing clear for delegated push" \
      || bad_t "S10b push accepts lead:standing" "rc=$rc :: $out"
  else
    printf 'skip - S10b: _push_gate_check not defined after sourcing cmd_push.sh\n'
  fi
else
  printf 'skip - S10b: src/cmd_push.sh not present\n'
fi

# =================================================================================
# ITERATION 2 — THE ANCHOR. olivia rejected iteration 1 for resolving the holder live
# at clear time from `agents_org.reports_to`; lodar answered the tier-2 decision gate
# `anchor-to-named-agent` on 2026-07-27. S11..S15 are that reject, executable.
#
# The chart is now RE-POINTED for every arm below to the production shape (olivia root,
# main the builders' lead) — precisely so that a predicate that still consulted it would
# give a DIFFERENT answer than the constitution does, and be caught.
# =================================================================================
db "DELETE FROM agents_org;"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('olivia','AI CEO — conducts the fleet',NULL);"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('main','engineering + infra + the 5dive CLI','olivia');"
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('dev','Backend lane','main');"

# ---------------------------------------------------------------------------------
# S11: THE REQUIRED TEST from olivia's reject — "mutate the org chart AFTER filing and
#      assert the clear is REFUSED". This is the self-grant path in one arm: `org set`
#      is root-guarded (DIVE-2124) but every agent here holds (ALL) NOPASSWD:ALL, so
#      writing the chart is one sudo away and `by_claimed` is caller-forgeable
#      (DIVE-2131). mallory files nothing, rewrites the chart to make itself dev's
#      lead, and tries to clear dev's gate. Under iteration 1 that SUCCEEDED. Every
#      one of the 54 assertions this suite shipped with treated the chart as trusted
#      ground truth, which is exactly why none of them could catch it.
# ---------------------------------------------------------------------------------
anchor_to marcus
seed_task DIVE-411 "delegated push for the retry backoff fix"
cmd_task_need DIVE-411 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-411
db "UPDATE tasks SET assignee='dev', created_by='dev' WHERE ident='DIVE-411';"
# ... the gate is now FILED. The attacker mutates the chart afterwards.
db "INSERT INTO agents_org (name, role, reports_to) VALUES ('mallory','Backend lane',NULL);"
db "UPDATE agents_org SET reports_to='mallory' WHERE name='dev';"
[[ "$(_gate_route_reviewer dev)" == "mallory" ]] \
  && ok_t "S11 precond: the post-filing chart mutation DID take (dev now reports to mallory)" \
  || bad_t "S11 precond chart mutated" "route_reviewer(dev)='$(_gate_route_reviewer dev)'"
FAKE_CALLER="agent-mallory"
_af_reset
out=$(cmd_task_answer DIVE-411 --value=approved --from=mallory 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-411)" == "open" ]] \
  && ok_t "S11 a chart mutation AFTER filing does NOT confer the authority — REFUSED" \
  || bad_t "S11 post-filing chart mutation refused" "rc=$rc state=$(answered DIVE-411) prov='$(provof DIVE-411)' out=$out"
[[ "$(provof DIVE-411)" != *standing* ]] \
  && ok_t "S11 the self-appointed lead mints no lead:standing provenance" \
  || bad_t "S11 no standing provenance for self-appointed lead" "got '$(provof DIVE-411)'"
grep -q "lead-standing-clear" <<<"$(_af)" \
  && bad_t "S11 no standing audit row for a refused clear" "audit=$(_af)" \
  || ok_t "S11 emits no lead-standing-clear audit row for the refused attempt"

# ---------------------------------------------------------------------------------
# S12: THE OTHER DIRECTION, and the non-vacuity partner to S11 — the chart is not
#      merely ignored WHEN IT HELPS an attacker, it is not consulted at all. marcus is
#      the constitution's name and is ABSENT from the chart entirely; the clear still
#      lands. Without this arm, a predicate that simply always denied would pass S11.
# ---------------------------------------------------------------------------------
[[ -z "$(_gate_route_reviewer marcus)" && "$(db "SELECT COUNT(*) FROM agents_org WHERE name='marcus';")" == "0" ]] \
  && ok_t "S12 precond: marcus is NOT in the org chart at all" \
  || bad_t "S12 precond marcus absent" "route='$(_gate_route_reviewer marcus)'"
seed_task DIVE-412 "delegated push for the retry backoff fix"
cmd_task_need DIVE-412 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-412
db "UPDATE tasks SET assignee='dev', created_by='dev' WHERE ident='DIVE-412';"
FAKE_CALLER="agent-marcus"
_af_reset
out=$(cmd_task_answer DIVE-412 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -eq 0 && "$(provof DIVE-412)" == "lead:standing:marcus" ]] \
  && ok_t "S12 the CONSTITUTION-named agent clears even with no chart standing at all" \
  || bad_t "S12 named agent clears" "rc=$rc prov='$(provof DIVE-412)' out=$out"
grep -q "authority_source=sealed-constitution:authority.eng_approval_lead" <<<"$(_af)" \
  && ok_t "S12 audit names WHERE the authority came from, not just who used it" \
  || bad_t "S12 audit names the authority source" "audit=$(_af)"
grep -q "standing_lead=marcus" <<<"$(_af)" \
  && ok_t "S12 audit records the anchored holder the clear was checked against" \
  || bad_t "S12 audit records the anchored holder" "audit=$(_af)"

# ---------------------------------------------------------------------------------
# S13: DRIFT DENIES EVERYONE. The anchor's whole strength is that writing the file is
#      self-defeating: an agent CAN sudo a new name in, and the moment it does the live
#      sha256 stops matching the sealed one. Both halves are pinned — the injected name
#      gains nothing, AND the legitimate holder loses the authority too (fail closed,
#      not "fall back to the last good value").
# ---------------------------------------------------------------------------------
write_constitution "$(constitution_yaml mallory)"   # edited, NOT re-sealed
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "S13 a drifted constitution resolves NO standing lead" \
  || bad_t "S13 drift resolves nobody" "got '$(_gate_standing_lead)'"
seed_task DIVE-413 "delegated push for the retry backoff fix"
cmd_task_need DIVE-413 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-413
FAKE_CALLER="agent-mallory"
out=$(cmd_task_answer DIVE-413 --value=approved --from=mallory 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-413)" == "open" ]] \
  && ok_t "S13 the name an agent WROTE ITSELF into the file is REFUSED (drift)" \
  || bad_t "S13 injected name refused" "rc=$rc state=$(answered DIVE-413) out=$out"
seed_task DIVE-414 "delegated push for the retry backoff fix"
cmd_task_need DIVE-414 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-414
FAKE_CALLER="agent-marcus"
out=$(cmd_task_answer DIVE-414 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-414)" == "open" ]] \
  && ok_t "S13 drift revokes the LEGITIMATE holder too — the tamper is not survivable" \
  || bad_t "S13 legit holder also denied under drift" "rc=$rc state=$(answered DIVE-414) out=$out"

# ---------------------------------------------------------------------------------
# S14: NO SEAL, NO AUTHORITY. A constitution.yaml with no sealed digest behind it is
#      exactly as writable as the org chart was, so anchoring to it would reproduce the
#      self-grant path in a different file. An UNSEALED file naming marcus grants
#      nothing; re-sealing the same bytes restores it (proving the seal is the variable
#      under test, not some unrelated breakage).
# ---------------------------------------------------------------------------------
write_constitution "$(constitution_yaml marcus)"; rm -f "$COUNCIL_LINEAGE"
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "S14 an UNSEALED constitution grants nobody, even naming the real holder" \
  || bad_t "S14 unsealed grants nobody" "got '$(_gate_standing_lead)'"
seed_task DIVE-415 "delegated push for the retry backoff fix"
cmd_task_need DIVE-415 --type=approval --ask="approve delegated push for review of branch fix-retry-backoff" >/dev/null 2>&1
unroute DIVE-415
out=$(cmd_task_answer DIVE-415 --value=approved --from=marcus 2>&1); rc=$?
[[ $rc -ne 0 && "$(answered DIVE-415)" == "open" ]] \
  && ok_t "S14 and the clear is refused end-to-end, not just at the resolver" \
  || bad_t "S14 unsealed clear refused" "rc=$rc state=$(answered DIVE-415) out=$out"
seal_constitution
[[ "$(_gate_standing_lead)" == "marcus" ]] \
  && ok_t "S14 sealing the SAME bytes restores it — the seal is the variable" \
  || bad_t "S14 seal restores" "got '$(_gate_standing_lead)'"

# ---------------------------------------------------------------------------------
# S15: THE FIELD ITSELF FAILS CLOSED. Absent, empty, non-name, and misplaced values all
#      resolve to nobody. Absence of a name is never "everyone" and never a fallback to
#      the chart — the failure mode a false NEGATIVE here would produce is exactly the
#      one design note 1 exists to prevent.
# ---------------------------------------------------------------------------------
anchor_to ""            # no `authority:` block at all
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "S15 no authority.eng_approval_lead key -> nobody (not everybody)" \
  || bad_t "S15 absent key denies" "got '$(_gate_standing_lead)'"
write_constitution "$(constitution_yaml "" 'authority:
  eng_approval_lead:')"; seal_constitution
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "S15 an EMPTY value -> nobody" \
  || bad_t "S15 empty value denies" "got '$(_gate_standing_lead)'"
# NB: a bare word like `all` is NOT in this list — it is a legal agent name and is
# compared literally, so it grants only an agent actually called `all`. There is no
# wildcard vocabulary in this field, which is the point: `*` below is refused as a name,
# not interpreted as one.
for _bad in '"human:marcus"' "'*'" "'MARCUS'" "'../../etc/passwd'" '"marcus; rm -rf /"'; do
  write_constitution "$(constitution_yaml "" "authority:
  eng_approval_lead: $_bad")"; seal_constitution
  [[ -z "$(_gate_standing_lead)" ]] \
    && ok_t "S15 a non-name value ($_bad) -> nobody" \
    || bad_t "S15 non-name denies ($_bad)" "got '$(_gate_standing_lead)'"
done
# A key of the right NAME under the wrong PARENT must not grant: only a top-level
# `authority:` block counts, so a nested lookalike elsewhere in the file is inert.
write_constitution "$(constitution_yaml "" 'ship:
  eng_approval_lead: marcus')"; seal_constitution
[[ -z "$(_gate_standing_lead)" ]] \
  && ok_t "S15 eng_approval_lead under a DIFFERENT top-level key grants nothing" \
  || bad_t "S15 nested lookalike denies" "got '$(_gate_standing_lead)'"
# ... and the same bytes under the right parent DO grant, so S15 is not passing because
# the reader is simply broken.
anchor_to marcus
[[ "$(_gate_standing_lead)" == "marcus" ]] \
  && ok_t "S15 non-vacuity: the reader still resolves a correctly-placed name" \
  || bad_t "S15 non-vacuity" "got '$(_gate_standing_lead)'"
FAKE_CALLER="agent-marcus"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
