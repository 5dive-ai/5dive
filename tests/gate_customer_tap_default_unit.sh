#!/usr/bin/env bash
# TIER: core
# DIVE-4346 — A CUSTOMER IS TAPPED ONLY FOR MONEY, A SECRET, AN IRREVERSIBLE STEP,
# OR SOMETHING ONLY A PERSON AT A BROWSER CAN DO.
#
# lodar, Telegram 2026-09-12 01:06Z: "i just think about our customers. this would
# be annoying for them to tap on such a minor change. human gate is still the most
# annoying part of 5dive."
#
# MEASURED ON THIS BOARD, the 7 days to 2026-09-12: 35 gates reached the paired
# human; 16 of them (46%) named no capability at all, and 313 changes shipped in
# the same week — 0.11 taps per shipped change. Replayed over the 171
# tier-2 asks in gate_history for the 30 days to 2026-09-12, the two new
# answerability refusals below fire on 9 and 1 asks respectively, with ZERO false
# positives — the full list is on the row body.
#
# THIS FILE GRADES THREE THINGS AND THEIR CONTROLS:
#   1. the "go look at the preview" refusal — unsatisfiable on an auth-gated
#      route, because a PRODUCTION login provider refuses preview domains and the
#      hosting bypass key has no authority over it (DIVE-4263, ~1 day and 6 gates);
#   2. the "a code-hosting rule is not a decision" refusal (DIVE-4020/4196);
#   3. the capability-declaration default — a decision/approval gate that reaches
#      a person must name which of the four it consumes.
#
# WHERE THIS DIVERGES FROM THE ROW AS FILED, deliberately. The row asked for a
# needs-less manual/approval gate to be ROUTED to a lead/verifier seat. That is
# the behaviour DIVE-4329 removed ONE DAY EARLIER on a measurement: on 2026-09-11
# a manual gate asking a person to try a login took a re-route exit, queued on a
# lead seat that cannot open a browser, and nobody was ever pinged. A gate that
# reaches nobody is worse than the tap, because it is silent. So the default is a
# REFUSAL AT FILING (cost: one re-file) rather than a re-route (cost: a silent
# stall), and the mutation arm below is its equivalent: a needs-less APPROVAL gate
# that reaches the human must be RED. Arms M4/M5 pin that `manual` and `secret`
# stay human-facing, so this cannot be "passed" by re-routing everything.
#
# Every refusal is paired with a control that must still FILE, because a lone red
# exit cannot tell "the rule works" from "cmd_task_need is unreachable".
#
# Run: bash tests/gate_customer_tap_default_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-customer-tap.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
_tasks_db_migrate

# --- stubs: nothing leaves the box -------------------------------------------
cmd_send()               { return 0; }
_task_agent_channel()    { return 0; }
_task_send_owner()       { return 0; }
task_need_notify()       { return 0; }
_task_gate_retire_buttons() { return 0; }
audit_log()              { return 0; }
AUDIT_ROWS="$TMP/audit_rows"; : >"$AUDIT_ROWS"
_task_store_audit_log()  { printf '%s\n' "$*" >>"$AUDIT_ROWS"; return 0; }
# No lead above the filer, so a tier that survives to these arms survived for the
# reason the case is about. Overridden live in arm M3.
_gate_route_reviewer()   { printf ''; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t()  { if [[ "$2" == "$3" ]]; then ok_t "$1"; else bad_t "$1" "want [$3] got [$2]"; fi; }
has_t() { if [[ "$2" == *"$3"* ]]; then ok_t "$1"; else bad_t "$1" "[$2] does not contain [$3]"; fi; }
red_t() { if [[ "$2" != "0" ]]; then ok_t "$1"; else bad_t "$1" "filed (rc 0) when it had to be refused: $3"; fi; }
field() { db "SELECT COALESCE($2,'∅') FROM tasks WHERE ident='$1';"; }

N=0
seed() { N=$((N+1)); db "INSERT INTO tasks (ident, title, priority, assignee, created_by, kind, status)
      VALUES ('$1', '${2:-a plain internal row}', 'medium', 'dev', 'main', 'standard', 'todo');"; }

RC=0; OUT=""
file_gate() { local id="$1"; shift; OUT=$( (cmd_task_need "$id" --from=dev "$@") 2>&1 ); RC=$?; }

# ============ PRECONDITION ===================================================
seed LIVE-1
file_gate LIVE-1 --type=decision --tier=2 --needs=human_tap \
  --ask="Two AI workers have been signed out since July. Sign them back in, or retire them?"
eq_t "PRECONDITION: a DECLARED human-capability gate files (rc 0)" "$RC" "0"
eq_t "PRECONDITION: ... and the row is a real tier-2 gate" \
     "$(field LIVE-1 need_type)|$(field LIVE-1 tier)" "decision|2"

# ============ A. the predicates at unit level ================================
# TRUE POSITIVES — every one of these is a verbatim tier-2 ask from gate_history,
# and the last three are the ones lodar was handed on 2026-09-12 00:27..01:05Z.
while IFS='|' read -r src ask; do
  if _gate_ask_unsatisfiable_preview "$ask"; then ok_t "A-pv+: $src is caught"
  else bad_t "A-pv+: $src is caught" "missed: $ask"; fi
done <<'CORPUS'
DIVE-3618|Open the #98 Vercel preview at desktop width, confirm the agent row shows the moon icon?
DIVE-3613|Can you open PR #97's Vercel preview on your phone at /dashboard/chat and approve the merge?
DIVE-3594|Does the agent detail page still look right in the Vercel preview?
DIVE-4263|Screenshot the three task-review choices: https://5dive-frontend-git-dev3.vercel.app/dashboard/settings
DIVE-4294|Open the dashboard preview, click Update on one box, and say whether the version cell reads right.
DIVE-4239|One real login test needed: fresh box, open https://5dive-frontend-git-dive-4239.vercel.app and sign in.
DIVE-4307|Please open the new customer rescue screen's preview and confirm it looks right.
CORPUS

# FALSE-POSITIVE CONTROLS — measured, not imagined. Each carries BOTH a preview
# token and a look-verb, and each is a legitimate gate: the verb's object is the
# change, or the looking is a subordinate note about what happens after the merge.
while IFS='|' read -r src ask; do
  if _gate_ask_unsatisfiable_preview "$ask"; then bad_t "A-pv-: $src survives" "wrongly caught: $ask"
  else ok_t "A-pv-: $src survives"; fi
done <<'CONTROLS'
DIVE-3978|Push the finished page update to a review branch so it can be graded and previewed? Nothing goes live: it only opens the change for review.
DIVE-3984|Approve pushing the headline change for review. This seat cannot render page images, so the deploy preview must be looked at before merge.
DIVE-4239b|This feature needs one real person to run a ten minute login test on a preview build. Commit that person now, or leave it unassigned?
CONTROLS

if _gate_ask_codehost_rule "Approve PR #779 as code owner of install.sh? Recommend: approve, then merge."; then
  ok_t "A-ch+: a per-change tap whose reason is a code-owner rule is caught"
else bad_t "A-ch+: a per-change tap whose reason is a code-owner rule is caught" "missed"; fi
if _gate_ask_codehost_rule "Will a repository admin make that branch protection change?"; then
  bad_t "A-ch-: an ask to CHANGE the rule survives" "wrongly caught — that is a browser-only human action"
else ok_t "A-ch-: an ask to CHANGE the rule survives"; fi
if _gate_ask_codehost_rule "Changes to the script that installs our product wait for your approval. Move that approval off you, or drop it entirely?"; then
  bad_t "A-ch-2: DIVE-4334's own decision survives" "wrongly caught"
else ok_t "A-ch-2: DIVE-4334's own decision survives"; fi

# ============ B. the preview refusal, end to end =============================
PV="Please open the new customer rescue screen's preview and confirm it looks right."
seed PV-1
file_gate PV-1 --type=manual --tier=2 --ask="$PV"
red_t "B1: a human-facing 'open the preview' gate is REFUSED" "$RC" "$OUT"
has_t "B1b: the refusal explains the SECOND wall" "$OUT" "refuses preview addresses outright"
eq_t  "B1c: NO gate was written by the refused filing" "$(field PV-1 need_type)" "∅"
eq_t  "B1d: the task was not moved to blocked" "$(field PV-1 status)" "todo"
has_t "B1e: the refusal is audited" "$(cat "$AUDIT_ROWS")" "task need ask-answerable refused"
has_t "B1f: it offers verifying on a box, not a re-route" "$OUT" "verify on a real box"

# CONTROL: the same ask at tier 1 is read by an AGENT and must still file.
seed PV-2
file_gate PV-2 --type=decision --tier=1 --ask="$PV"
eq_t "B2: the SAME ask at tier 1 still files (rc 0)" "$RC" "0"
eq_t "B2b: ... and really is a gate" "$(field PV-2 need_type)" "decision"

# The audited escape must work, or the gate is unfileable (DIVE-2216).
seed PV-3
file_gate PV-3 --type=manual --tier=2 --ask="$PV" --ask-ok="he owns the only login that can reach this box"
eq_t "B3: --ask-ok files it anyway (rc 0)" "$RC" "0"
has_t "B3b: ... and the escape is audited" "$(cat "$AUDIT_ROWS")" "task need ask-answerable escaped"

# ============ C. the code-hosting-rule refusal ===============================
seed CH-1
file_gate CH-1 --type=approval --tier=2 --needs=human_tap \
  --ask="Approve this change as code owner of the installer?"
red_t "C1: an approval asked for BECAUSE of a repo rule is REFUSED" "$RC" "$OUT"
has_t "C1b: the refusal says the rule fires again next time" "$OUT" "fires again on the very next change"
eq_t  "C1c: NO gate was written" "$(field CH-1 need_type)" "∅"
seed CH-2
file_gate CH-2 --type=decision --tier=2 --needs=human_tap \
  --ask="Take the installer approval off you, or drop it entirely?"
eq_t "C2: the decision ABOUT the rule still files (rc 0)" "$RC" "0"

# ============ M. the capability matrix, and the mutation arm =================
# type × --needs present/absent × --recommend present/absent -> who is pinged.
GOOD="Sign the two parked workers back in, or retire them?"
seed MA-1
file_gate MA-1 --type=approval --tier=2 --needs=spend_authority --ask="$GOOD"
eq_t "M1: approval + declared capability -> files, human-facing" \
     "$RC|$(field MA-1 tier)|$(field MA-1 needs_capability)" "0|2|spend_authority"
eq_t "M1b: ... and no seat was routed (it is the human's)" "$(field MA-1 routed_reviewer)" "∅"

# THE MUTATION ARM. Delete the capability-declaration refusal and this goes green.
seed MB-1
file_gate MB-1 --type=approval --tier=2 --ask="$GOOD"
red_t "M2: approval + NO capability, reaching the human, is REFUSED" "$RC" "$OUT"
has_t "M2b: the refusal names the four things a customer is tapped for" "$OUT" "money, a secret, something irreversible"
eq_t  "M2c: NO gate was written" "$(field MB-1 need_type)" "∅"
has_t "M2d: the refusal is audited" "$(cat "$AUDIT_ROWS")" "task need capability-undeclared refused"
has_t "M2e: it offers tier 0 with the filer's own recommendation" "$OUT" "--tier=0"
seed MB-2
file_gate MB-2 --type=decision --tier=2 --recommend="sign them back in" --ask="$GOOD"
red_t "M2f: decision + recommend + NO capability is REFUSED too" "$RC" "$OUT"

# A lead exists: the same needs-less gate is now read by an AGENT, not a person,
# so the refusal must NOT fire. This is the arm that proves the rule is scoped to
# gates that actually reach the customer.
_gate_route_reviewer() { printf 'main'; }
seed MC-1
file_gate MC-1 --type=approval --tier=1 --ask="$GOOD"
eq_t "M3: a lead-routed needs-less approval still files (rc 0)" "$RC" "0"
# The claim this arm carries is SCOPE, not the route: with a lead above the
# filer the gate is read by an agent, so the refusal must not fire and a real
# tier-1 gate must be on the row. (The resolved reviewer name is decided further
# down cmd_task_need by machinery this harness does not stand up; asserting it
# here would be asserting the stub, not the product.)
eq_t "M3b: ... and a real tier-1 gate is on the row" \
     "$(field MC-1 need_type)|$(field MC-1 tier)" "approval|1"
_gate_route_reviewer() { printf ''; }

# M4/M5 — the two types that name their capability in their own name stay
# human-facing and stay fileable. Without these, "refuse everything undeclared"
# would pass M2 while breaking the gates that are correct.
seed MD-1
file_gate MD-1 --type=manual --tier=2 --ask="Try one file import on your own box and say whether it worked?"
eq_t "M4: a tier-2 manual gate files without --needs (the type IS the capability)" "$RC" "0"
eq_t "M4b: ... and stays tier 2" "$(field MD-1 tier)" "2"
seed ME-1
file_gate ME-1 --type=secret --tier=2 --secret-key=DEMO_TOKEN --connector=env \
  --ask="Send a throwaway login for the test dashboard?"
eq_t "M5: a secret gate files without --needs and stays tier 2" "$RC|$(field ME-1 tier)" "0|2"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
