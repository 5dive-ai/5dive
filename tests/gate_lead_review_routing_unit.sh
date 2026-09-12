#!/usr/bin/env bash
# TIER: core — no sleeps. Every arm here reads a RESOLUTION (which tier, which
#   bot, which recipient) rather than waiting on the hold child, which is why it
#   is priced in milliseconds and gate_undo_window_unit is priced in sleeps.
#
# DIVE-4365 — THE THREE PLACES A FALSE HUMAN GATE WAS MANUFACTURED.
#
# Measured motivation (DIVE-4359, 2026-09-12): a `secret` gate was filed for a
# value we INVENT and place with credentials the box already holds. It reached a
# phone because `secret` is tier 2 by TYPE; nothing stood between the filer and
# the human; and the ping went out from the org root's bot while the conversation
# about it happened in the lead's chat. Three separate mechanisms, one page, zero
# decisions. This harness grades one claim per mechanism.
#
# WHAT IT DELIBERATELY DOES NOT GRADE: that a held ping eventually fires. That is
# gate_undo_window_unit's property and it costs a real sleep to assert; re-testing
# it here would buy a second copy of the same evidence at the same price. What is
# graded here is the CEILING the hold resolves, which is the thing this row moved.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/gate-lead-review.XXXXXX)

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_agent_runtime.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_NO_HUMAN_SEND=1
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# The org chart the live fleet has: a lone root (olivia) with a lead (main) under
# it and a maker (dev3) under the lead. The lone-root fallback is what makes
# olivia the coordinator today, and reproducing it here is the point — the whole
# part-3 claim is about what a chart in exactly this shape resolves to.
db "INSERT INTO agents_org (name,role,reports_to) VALUES ('olivia','AI CEO — conducts the fleet (advisory)',NULL);"
db "INSERT INTO agents_org (name,role,reports_to) VALUES ('main','engineering + infra + the 5dive CLI','olivia');"
db "INSERT INTO agents_org (name,role,reports_to) VALUES ('dev3','feature work','main');"

mkrow() { # $1=ident
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by)
      VALUES ($(sqlq "$1"),'lead review fixture','todo','high','dev3','dev3');"
  db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");"
}

# ── PART 3 — THE NOTIFIER IS A SEPARATE KNOB FROM THE COORDINATOR ────────────
#
# Arm 1 is the no-op arm and it is the one that matters most: the re-nag's sender
# resolver is being SWAPPED on every deployment, and almost none of them will
# ever tag a notifier. If an untagged chart resolved differently, this row would
# be a fleet-wide change to who rings the phone, dressed as an opt-in.
[[ "$(_task_resolve_gate_notifier)" == "olivia" && "$(_task_resolve_coordinator)" == "olivia" ]] \
  && ok_t "untagged chart: notifier and coordinator both resolve to the lone root — no behaviour change" \
  || fail_t "untagged chart: notifier=$(_task_resolve_gate_notifier) coordinator=$(_task_resolve_coordinator) (both must be olivia)"

[[ -z "$(_task_gate_notifier_explicit)" ]] \
  && ok_t "untagged chart: the EXPLICIT probe is empty, so the file-time delivery path keeps the filer-first chain" \
  || fail_t "untagged chart: _task_gate_notifier_explicit printed '$(_task_gate_notifier_explicit)' — the deliver path would re-route on an untagged chart"

db "UPDATE agents_org SET role='engineering + infra + the 5dive CLI — gate notifier' WHERE name='main';"

[[ "$(_task_resolve_gate_notifier)" == "main" ]] \
  && ok_t "marker on main: the gate notifier resolves to main" \
  || fail_t "marker on main: notifier resolved to '$(_task_resolve_gate_notifier)', want main"

# THE SPLIT IS THE DELIVERABLE. Tagging the notifier must not move the default
# assignee, the default planner, the reviewer fallback or the loop owner — all
# five of which read the COORDINATOR. If this arm ever goes red, the one-liner
# this row exists to avoid has been re-created inside the row that avoided it.
[[ "$(_task_resolve_coordinator)" == "olivia" ]] \
  && ok_t "marker on main: the COORDINATOR is untouched (default assignee / planner / loop owner stay olivia's)" \
  || fail_t "marker on main: coordinator moved to '$(_task_resolve_coordinator)' — the knobs are not split"

[[ "$(_task_gate_notifier_explicit)" == "main" ]] \
  && ok_t "marker on main: the explicit probe names main, so the file-time ping prefers main's bot" \
  || fail_t "marker on main: explicit probe printed '$(_task_gate_notifier_explicit)'"

# Ambiguity yields NOTHING rather than a guess — the same uniqueness posture every
# other resolver in routing.sh takes. A guess about who pages a person is the
# wrong place to be clever.
db "UPDATE agents_org SET role='feature work — gate notifier' WHERE name='dev3';"
[[ -z "$(_task_gate_notifier_explicit)" && "$(_task_resolve_gate_notifier)" == "olivia" ]] \
  && ok_t "two marker holders: ambiguous, so the explicit probe is empty and the re-nag falls back to the coordinator" \
  || fail_t "two marker holders: explicit='$(_task_gate_notifier_explicit)' notifier='$(_task_resolve_gate_notifier)'"
db "UPDATE agents_org SET role='feature work' WHERE name='dev3';"

# ── PART 2 — THE HOLD CEILING IS THE LEAD-REVIEW WINDOW ON HUMAN-BOUND GATES ──
h_id=$(mkrow DIVE-9401)
db "UPDATE tasks SET need_type='manual', tier=2, need_asked_at=datetime('now'), status='blocked' WHERE id=${h_id};"
secs=$(_task_gate_undo_window_secs DIVE-9401)
[[ "$secs" == "$_GATE_LEAD_REVIEW_HOLD_SECS" ]] \
  && ok_t "a tier-2 (human-bound) gate holds for the lead-review window, not the DIVE-4154 type window" \
  || fail_t "tier-2 hold resolved ${secs}s, want ${_GATE_LEAD_REVIEW_HOLD_SECS}s"

# The window must still be shorter than the re-nag's own exclusion, or the
# recovery path becomes the first contact — the 840-not-900 ordering argument,
# re-asserted one layer up. Graded STRUCTURALLY against the sweep's clause so a
# later raise of either constant reds here rather than silently re-ordering them.
grep -q "datetime('now','-31 minutes')" src/cmd_heartbeat.sh \
  && (( _GATE_LEAD_REVIEW_HOLD_SECS < 31*60 )) \
  && ok_t "the re-nag sweep excludes a never-pinged tier-2 row inside its hold, with margin over the hold" \
  || fail_t "the lead-review hold (${_GATE_LEAD_REVIEW_HOLD_SECS}s) is not strictly inside the re-nag's exclusion window"

l_id=$(mkrow DIVE-9402)
db "UPDATE tasks SET need_type='decision', tier=1, need_asked_at=datetime('now'), status='blocked' WHERE id=${l_id};"
secs=$(_task_gate_undo_window_secs DIVE-9402)
[[ "$secs" == "$_GATE_UNDO_WINDOW_SECS" ]] \
  && ok_t "a tier-1 (lead-routed) gate keeps the DIVE-4154 window — a gate that rings no phone is not worth holding" \
  || fail_t "tier-1 hold resolved ${secs}s, want ${_GATE_UNDO_WINDOW_SECS}s"

u_id=$(mkrow DIVE-9403)
db "UPDATE tasks SET need_type='manual', tier=2, gate_urgent=1, need_asked_at=datetime('now'), status='blocked' WHERE id=${u_id};"
[[ "$(_task_gate_undo_window_secs DIVE-9403)" == "0" ]] \
  && ok_t "the filer's explicit urgency still skips the hold outright — a longer window did not swallow the skip" \
  || fail_t "an urgent tier-2 gate resolved a non-zero hold"

# ── PART 1 — A SELF-MINTED SECRET IS NOT A HUMAN'S TO ISSUE ──────────────────
export FIVEDIVE_NO_HUMAN_SEND=1
s_id=$(mkrow DIVE-9404)
out=$(cmd_task_need DIVE-9404 --type=secret --self-minted --from=dev3 \
        --secret-key=MARKETPLACE_REVALIDATE_SECRET --connector=vercel \
        --ask="Shall we mint the revalidate token now, or wait for the next cut?" 2>&1)
tier=$(db "SELECT COALESCE(tier,2) FROM tasks WHERE id=${s_id};")
prov=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE id=${s_id};")
[[ "$tier" == "1" ]] \
  && ok_t "a self-minted secret gate routes tier 1 (lead review), not tier 2 (the paired human)" \
  || fail_t "self-minted secret resolved tier ${tier}, want 1 — output: ${out}"
[[ "$prov" == "axis=self-minted-secret" ]] \
  && ok_t "the store records WHY it was not floored (axis=self-minted-secret), so the take is measurable" \
  || fail_t "floor_provenance='${prov}', want axis=self-minted-secret"
# `human recipient` reports nobody: the gate is not the human's, and the predicate
# that decides that is the one the dashboard's needs-you card reads.
_gate_needs_human "secret_provision" && nh=1 || nh=0
[[ "$(db "SELECT COALESCE(needs_capability,'') FROM tasks WHERE id=${s_id};")" == "" && "$tier" == "1" ]] \
  && ok_t "no human capability is recorded against a self-minted secret — 'human recipient' reports nobody" \
  || fail_t "a self-minted secret still carries a human capability"

# The floor that is NOT lifted. A self-minted secret whose ask also asks to spend
# money is floored on THAT and still reaches the person — the declaration lifts
# exactly one floor, which is what keeps it from becoming a general escape.
sp_id=$(mkrow DIVE-9405)
out=$(cmd_task_need DIVE-9405 --type=secret --self-minted --from=dev3 \
        --needs=spend_authority --out-of-band="already in my .env on this box" \
        --ask="Shall we pay the \$40/mo for the hosted plan this token unlocks, or stay on the free tier?" 2>&1)
tier=$(db "SELECT COALESCE(tier,2) FROM tasks WHERE id=${sp_id};")
[[ "$tier" == "2" ]] \
  && ok_t "a spend gate still resolves to the human — self-minting lifts the secret-type floor and nothing else" \
  || fail_t "a declared spend_authority gate resolved tier ${tier}, want 2"

# --self-minted is refused, not ignored, where there is no secret to describe.
d_id=$(mkrow DIVE-9406)
out=$(cmd_task_need DIVE-9406 --type=decision --self-minted --from=dev3 \
        --options="A|B" --ask="Shall we ship the tile dark, or hold it for the relay?" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--self-minted only applies to a secret gate"* ]] \
  && ok_t "--self-minted on a non-secret gate is REFUSED, never silently ignored" \
  || fail_t "--self-minted on a decision gate returned rc=${rc}: ${out}"

# ── PART 1 — THE ONE EXIT: THE LEAD'S ESCALATION ─────────────────────────────
#
# AUTHORIZED ON THE TRUSTED UNIX IDENTITY, NEVER ON --from — the same principal
# `--withdraw` takes, and for the same reason: --from is a self-declaration, and a
# flag that promotes a gate to a person must not be forgeable by typing a name.
# So the fixture makes the RUNNING seat the gate's routed reviewer rather than
# passing --from=main, which would prove nothing about the authorization.
ACTOR=$(task_actor "")
db "UPDATE tasks SET routed_reviewer=$(sqlq "$ACTOR") WHERE ident='DIVE-9404';"
out=$(cmd_task_need DIVE-9404 --escalate 2>&1); rc=$?
tier=$(db "SELECT COALESCE(tier,2) FROM tasks WHERE ident='DIVE-9404';")
prov=$(db "SELECT COALESCE(floor_provenance,'') FROM tasks WHERE ident='DIVE-9404';")
urg=$(db "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='DIVE-9404';")
[[ $rc -eq 0 && "$tier" == "2" ]] \
  && ok_t "the lead forwards a lead-reviewed gate to the human with --escalate, keeping the ident and the ask" \
  || fail_t "--escalate by the lead returned rc=${rc}, tier=${tier}: ${out}"
[[ "$prov" == "axis=lead-escalated" ]] \
  && ok_t "an escalation records itself as a LEAD'S forward, distinct from the category floor and from a pinned --tier=2" \
  || fail_t "floor_provenance after escalate='${prov}'"
[[ "$urg" == "1" ]] \
  && ok_t "an escalated gate skips the lead-review hold — it has already been read by a lead" \
  || fail_t "an escalated gate did not skip the hold (gate_urgent=${urg})"

out=$(cmd_task_need DIVE-9404 --escalate 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"already tier 2"* ]] \
  && ok_t "escalating an already-human gate is refused — there is nothing above it" \
  || fail_t "a second --escalate returned rc=${rc}: ${out}"

e_id=$(mkrow DIVE-9407)
db "UPDATE tasks SET need_type='decision', tier=1, ask='x', need_asked_at=datetime('now'), status='blocked', gate_filed_by='dev3' WHERE id=${e_id};"
db "UPDATE tasks SET routed_reviewer=$(sqlq "$ACTOR") WHERE id=${e_id};"
out=$(cmd_task_need DIVE-9407 --escalate --type=decision 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"takes no other gate flags"* ]] \
  && ok_t "--escalate refuses to double as a re-file, so a forwarded gate cannot quietly change its ask" \
  || fail_t "--escalate with --type returned rc=${rc}: ${out}"

r_id=$(mkrow DIVE-9408)
db "UPDATE tasks SET need_type='decision', tier=1, ask='x', need_asked_at=datetime('now'), status='blocked', gate_filed_by='dev3', created_by='dev3', assignee='dev3', routed_reviewer='olivia' WHERE id=${r_id};"
out=$(cmd_task_need DIVE-9408 --escalate 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"can forward this gate to the paired human"* ]] \
  && ok_t "a seat that is neither filer, lead, routed reviewer nor coordinator cannot forward a gate to a person" \
  || fail_t "an unauthorized --escalate returned rc=${rc}: ${out}"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
