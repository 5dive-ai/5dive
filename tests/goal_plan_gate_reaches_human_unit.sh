#!/usr/bin/env bash
# TIER: nightly — 9.9s measured on the 5dive host; same tier as its siblings goal_add_unit and gate_decision_lead_rail_unit (the changed-harnesses job runs it on the PR that edits it).
# DIVE-8721 — A GOAL OVER THE CHECKPOINT, ON A BOX WITH AN ORG LEAD, REACHES THE
# OWNER AND THE OWNER'S APPROVE BUILDS IT.
#
# THE INCIDENT (even-branch, CLI 0.135.0, 2026-11-18 10:01Z). `goal add` planned 8
# tasks, over the default checkpoint of 6, and filed the anchor's plan gate as a
# tier-1 `decision`. DIVE-4415 routes a tier<2 decision to the org lead BY KIND, so
# the gate read "routed to tess" and needs_human was 0. But `goal add --from-gate`
# builds only on a HUMAN approve (DIVE-916). The one answer that could build the
# plan was never asked for, and the answer that was asked for could not build it:
# the app's goal card sat at "planning" with no Start, and the partner's Start
# answered 409. A T2 plan already gated at tier 2 + human_tap and worked; only the
# count checkpoint — any goal over 6 steps — was broken.
#
# THE FIX files the count-checkpoint gate exactly like the T2 one. These arms hold
# it, plus the control that makes them mean something:
#   P  the same chart routes a PLAIN tier-1 decision from the same filer to the
#      lead. Without it every arm below would also pass on a chart with no lead,
#      where everything reaches the human anyway.
#   G  goal add over the checkpoint: the anchor's gate is not routed to the lead,
#      is human-bound by the CLI's own verdict (the predicate `task ls --json`
#      exports as needs_human — what the app's "check" stage and the partner's
#      humanGateOpen read), and the human was pinged. Both with --from (the app
#      and partner pass none, the planner path passes one) and without.
#   B  a human approve (`task answer --human`, the app's and partner's Start)
#      builds every planned task via --from-gate.
#
# Run: bash tests/goal_plan_gate_reaches_human_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/goal-plan-gate-human.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - goal_plan_gate_reaches_human_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The human-ping sentinel is a FILE: every call below runs in a subshell.
PING_FILE="$TMP/ping.log"
_task_need_notify_deliver() { printf '1\n' >>"$PING_FILE"; }
human_pinged() { [[ -s "$PING_FILE" ]]; }
_task_store_audit_log() { return 0; }
audit_log() { :; }
5dive() { return 0; }
export -f 5dive 2>/dev/null || true
_gate_proof_enforced() { return 1; }   # the evidence floor is another row's subject

# A chart with a reachable lead under the root: tess leads, swan builds.
db "INSERT INTO agents_org(name,reports_to,role) VALUES('lodar-root',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('tess','lodar-root','lead');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('swan','tess','builder');"

col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
human_verdict() {   # the CLI's own "waiting on a human" verdict (needs_human in ls --json)
  db "SELECT CASE WHEN $(_task_gate_open_pred) AND ( $(_task_human_gate_pred) ) THEN 1 ELSE 0 END FROM tasks WHERE ident=$(sqlq "$1");"
}

# ── P. THE CONTROL — this chart routes a plain tier-1 decision to the lead ───
db "INSERT INTO tasks(ident,title,status,created_by) VALUES('DIVE-901','control decision','todo','swan');"
: >"$PING_FILE"
( actor_seam_as swan; cmd_task_need DIVE-901 --type=decision --options="approve|revise" --recommend="approve" \
    --ask="Which of the two shapes should we build for this scope fork?" --from=swan ) >/dev/null 2>&1
if [[ "$(col DIVE-901 routed_reviewer)" == "tess" && "$(human_verdict DIVE-901)" == "0" ]] && ! human_pinged; then
  ok_t "P  control: a plain tier-1 decision from swan routes to the lead tess (so a human route below is the fix, not a leadless chart)"
else
  bad_t "P  control: plain decision must reach the lead" "routed='$(col DIVE-901 routed_reviewer)' verdict=$(human_verdict DIVE-901)"
fi

# An 8-task, all-low plan: over the default checkpoint (6), no T2 task.
plan_for() {
  local key="$1" i out='{"project":{"key":"'"$key"'","name":"'"$key"'","goal":"g"},"tasks":['
  for i in 1 2 3 4 5 6 7 8; do
    out+="{\"local_id\":\"t$i\",\"title\":\"step $i of the launch\",\"assignee_or_role\":\"swan\",\"risk\":\"low\"},"
  done
  printf '%s' "${out%,}]}"
}

# arm <label> <project key> <who> [--from=<who>]
gate_arm() {
  local label="$1" key="$2" who="$3"; shift 3
  : >"$PING_FILE"
  local out; out=$( actor_seam_as "$who"; cmd_goal_add --plan="$(plan_for "$key")" --project="$key" "$@" -- "launch $key" 2>/dev/null )
  local anchor; anchor=$(printf '%s' "$out" | jq -r '.data.anchor // ""' 2>/dev/null)
  local gated;  gated=$(printf '%s' "$out" | jq -r '.data.gated // false' 2>/dev/null)
  local nstd;   nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard' AND title NOT LIKE 'Goal:%';")
  if [[ "$gated" != "true" || -z "$anchor" || "$nstd" != "0" ]]; then
    bad_t "G${label} goal over the checkpoint files ONE plan gate, builds nothing" "gated=$gated anchor=$anchor nstd=$nstd out=$out"
    return
  fi
  ok_t "G${label} 8-task goal (> checkpoint 6) files one plan gate on $anchor and builds nothing"
  local rr; rr=$(col "$anchor" routed_reviewer)
  [[ -z "$rr" ]] \
    && ok_t "G${label} the plan gate is NOT routed to the org lead" \
    || bad_t "G${label} the plan gate must not go to the lead" "routed_reviewer='$rr' (the even-branch shape: routed to tess)"
  [[ "$(human_verdict "$anchor")" == "1" ]] \
    && ok_t "G${label} the CLI's needs_human verdict is 1 — the app's 'check' stage and the partner's humanGateOpen see it" \
    || bad_t "G${label} needs_human verdict" "got $(human_verdict "$anchor") tier=$(col "$anchor" tier) cap=$(col "$anchor" needs_capability)"
  human_pinged \
    && ok_t "G${label} the paired human was pinged with the plan" \
    || bad_t "G${label} human ping" "no delivery recorded"
  [[ "$(col "$anchor" tier)" == "2" && "$(col "$anchor" needs_capability)" == "human_tap" ]] \
    && ok_t "G${label} filed like the T2 plan gate: tier 2, needs human_tap (never 48h auto-applied)" \
    || bad_t "G${label} tier/capability" "tier=$(col "$anchor" tier) cap=$(col "$anchor" needs_capability)"
  [[ "$(col "$anchor" ask)" == *"Plans over 6 steps need your OK"* ]] \
    && ok_t "G${label} the ask still names WHY it gated (over checkpoint), not 'carries a Tier-2 task'" \
    || bad_t "G${label} reason text" "ask='$(col "$anchor" ask)'"
  LAST_ANCHOR="$anchor"
}

LAST_ANCHOR=""
gate_arm 1 launch-a swan --from=swan
ANCHOR_A="$LAST_ANCHOR"
LAST_ANCHOR=""
gate_arm 2 launch-b swan
ANCHOR_B="$LAST_ANCHOR"

# ── B. THE OWNER'S APPROVE BUILDS IT ─────────────────────────────────────────
# `task answer --human` is what the app's Start and the partner's Start send, over
# the dashboard exec: a non-agent SUDO_UID in a human-capable cgroup — the evidence
# form a tier-2 `--human` claim needs (DIVE-2233/2371), the same one every tier-2
# approval and T2 plan gate is already answered through. Stubbing the two seams
# models that caller; the proof check itself still runs.
if [[ -n "$ANCHOR_A" ]]; then
  ( actor_seam_as owner; _gate_uid_to_agent() { printf ''; }; _gate_human_principal() { return 0; }
    cmd_task_answer "$ANCHOR_A" --value=approve --human ) >/dev/null 2>"$TMP/ans.err"
  nby=$(col "$ANCHOR_A" need_answered_by)
  [[ "$nby" == human:* && "$(col "$ANCHOR_A" need_answer)" == "approve" ]] \
    && ok_t "B1 the owner's approve lands as a human answer ($nby)" \
    || bad_t "B1 human answer" "answered_by='$nby' answer='$(col "$ANCHOR_A" need_answer)' err=$(head -c 400 "$TMP/ans.err")"
  out=$( cmd_goal_add --from-gate="$ANCHOR_A" 2>/dev/null ); rc=$?
  nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='launch-a' AND kind='standard' AND title NOT LIKE 'Goal:%';")
  [[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.materialized // false')" == "true" && "$nstd" == "8" ]] \
    && ok_t "B2 --from-gate builds all 8 planned tasks after the owner's approve" \
    || bad_t "B2 build" "rc=$rc nstd=$nstd out=$out"
else
  bad_t "B  owner approve builds it" "no anchor from G1"
fi

# B3: the lead cannot clear it by answering as an agent — it was never theirs.
if [[ -n "$ANCHOR_B" ]]; then
  ( actor_seam_as tess; cmd_task_answer "$ANCHOR_B" --value=approve ) >/dev/null 2>&1
  out=$( cmd_goal_add --from-gate="$ANCHOR_B" 2>/dev/null ); rc=$?
  nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='launch-b' AND kind='standard' AND title NOT LIKE 'Goal:%';")
  [[ $rc -ne 0 && "$nstd" == "0" ]] \
    && ok_t "B3 the lead answering as an agent builds nothing (the gate is the owner's)" \
    || bad_t "B3 lead answer must not build" "rc=$rc nstd=$nstd answered_by='$(col "$ANCHOR_B" need_answered_by)'"
  # B4: nor by passing --human without the evidence (the flag alone is a claim).
  ( actor_seam_as tess; _gate_human_principal() { return 1; }
    cmd_task_answer "$ANCHOR_B" --value=approve --human ) >/dev/null 2>&1
  [[ "$(col "$ANCHOR_B" need_answered_by)" != human:* && -z "$(col "$ANCHOR_B" need_answered_at)" ]] \
    && ok_t "B4 an agent's unproven --human on the plan gate is refused (the tier-2 proof floor holds)" \
    || bad_t "B4 unproven --human must be refused" "answered_by='$(col "$ANCHOR_B" need_answered_by)'"
fi

SUMMARY_PRINTED=1
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
