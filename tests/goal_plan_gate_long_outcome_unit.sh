#!/usr/bin/env bash
# TIER: nightly — same tier as its sibling goal_plan_gate_reaches_human_unit (the changed-harnesses job runs it on the PR that edits it).
# DIVE-8837 — A GOAL OVER THE PLAN CHECKPOINT REACHES ITS APPROVAL WHATEVER THE
# LENGTH OF THE OUTCOME, AND A FAILED FINISH LEAVES NO UNGATED ANCHOR.
#
# THE INCIDENT (even-branch, CLI 0.137.1, 2026-11-19 14:27-14:49Z). The plan gate's
# ask quoted the WHOLE outcome inside 14 fixed words, so any outcome over ~11 words
# broke the 25-word ask cap and `task need` refused the gate. The refusal is `fail`
# = `exit`, so the finish died before reporting, the async poll (which threw stderr
# away) recorded "plan finish failed", and a "Goal: …" anchor sat with no gate.
#
#   L  long outcomes (41 words) over the checkpoint, count-only and T2: gated, one
#      anchor, the gate is open and human-bound, the ask fits the cap and names the
#      goal clipped.
#   S  a short outcome is named whole; one that reads as an internal name is not.
#   R  a refused gate leaves no anchor and no project behind, and says why.
#   J  the async path: a long outcome gates; a refusal's real reason lands in the
#      job's `reason`, not "plan finish failed".
#
# No gate seam on purpose: production `cmd_task_need` exits on a refusal, and that
# exit is part of what this harness grades.
# Run: bash tests/goal_plan_gate_long_outcome_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/goal-plan-gate-long.XXXXXX)"
SUMMARY_PRINTED=0
exec 8>&2
trap 'rc=$?; rm -rf "${TMP:-}"; [[ "${SUMMARY_PRINTED:-0}" == 1 ]] || printf "ABORTED - goal_plan_gate_long_outcome_unit exited early (rc=%s) before its summary; every assertion after the last ok above was SKIPPED, not passed\n" "$rc" >&8; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh lib/broker.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_goal.sh cmd_loop.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

_task_need_notify_deliver() { return 0; }
_task_store_audit_log() { return 0; }
audit_log() { :; }
5dive() { return 0; }
export -f 5dive 2>/dev/null || true
_gate_proof_enforced() { return 1; }
_org_resolve_assignee() { printf '%s' "swan"; }

db "INSERT INTO agents_org(name,reports_to,role) VALUES('lodar-root',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('kostya','lodar-root','lead');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('swan','kostya','builder');"

col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident=$(sqlq "$1");"; }
human_verdict() {
  db "SELECT CASE WHEN $(_task_gate_open_pred) AND ( $(_task_human_gate_pred) ) THEN 1 ELSE 0 END FROM tasks WHERE ident=$(sqlq "$1");"
}
words() { local -a w=(); read -r -a w <<<"$1"; printf '%s' "${#w[@]}"; }
# Production runs under header.sh's `set -e`; so do the verbs here.
run() { ( set -e; actor_seam_as swan; "$@" ) 2>"$TMP/run.err"; }

# plan_for <key> [t2] — 8 tasks, over the default checkpoint (6).
plan_for() {
  local key="$1" t2="${2:-}" i risk out='{"project":{"key":"'"$1"'","name":"'"$1"'","goal":"g"},"tasks":['
  for i in 1 2 3 4 5 6 7 8; do
    risk=low; [[ -n "$t2" && "$i" == 8 ]] && risk=spend
    out+="{\"local_id\":\"t$i\",\"title\":\"step $i of the launch\",\"assignee_or_role\":\"swan\",\"risk\":\"$risk\"},"
  done
  printf '%s' "${out%,}]}"
}

LONG="Open a small online shop for our handmade candles, with a product page for each scent, a simple checkout, a welcome email for new buyers, and a weekly note to past customers about new scents, seasonal gift sets and offers"
(( $(words "$LONG") >= 40 )) || { echo "fixture: LONG outcome must be 40+ words"; exit 1; }

# long_arm <label> <key> [t2]
long_arm() {
  local label="$1" key="$2" t2="${3:-}"
  local out; out=$(run cmd_goal_add --plan="$(plan_for "$key" "$t2")" --project="$key" -- "$LONG"); local rc=$?
  local anchor gated
  anchor=$(printf '%s' "$out" | jq -r '.data.anchor // ""' 2>/dev/null)
  gated=$(printf '%s' "$out" | jq -r '.data.gated // false' 2>/dev/null)
  if [[ $rc -ne 0 || "$gated" != "true" || -z "$anchor" ]]; then
    bad_t "L${label} a 41-word outcome over the checkpoint reaches gated" "rc=$rc out=$out err=$(head -c 300 "$TMP/run.err")"
    return
  fi
  ok_t "L${label} a 41-word outcome over the checkpoint reaches gated on $anchor"
  local ask; ask=$(col "$anchor" ask)
  [[ "$(col "$anchor" need_type)" == "decision" && "$(human_verdict "$anchor")" == "1" ]] \
    && ok_t "L${label} the anchor carries an open plan gate bound for a person" \
    || bad_t "L${label} open human gate" "need_type=$(col "$anchor" need_type) verdict=$(human_verdict "$anchor")"
  (( $(words "$ask") <= _GATE_ASK_MAX_WORDS )) \
    && ok_t "L${label} the ask fits the cap ($(words "$ask") <= ${_GATE_ASK_MAX_WORDS} words): $ask" \
    || bad_t "L${label} ask over the cap" "$(words "$ask") words: $ask"
  [[ "$ask" == *'"Open a small online shop'* && "$ask" == *'…"'* ]] \
    && ok_t "L${label} the ask names the goal, clipped" \
    || bad_t "L${label} goal named and clipped" "ask=$ask"
  local nstd; nstd=$(db "SELECT COUNT(*) FROM tasks WHERE project_key=$(sqlq "$key") AND kind='standard' AND title NOT LIKE 'Goal:%';")
  [[ "$nstd" == "0" ]] && ok_t "L${label} nothing built before the approve" || bad_t "L${label} built early" "nstd=$nstd"
  if [[ -n "$t2" ]]; then
    [[ "$ask" == *"money, publishing, secrets or deletion"* ]] \
      && ok_t "L${label} the T2 ask says why a person must approve" \
      || bad_t "L${label} T2 reason" "ask=$ask"
  else
    [[ "$ask" == *"Plans over 6 steps need your OK"* ]] \
      && ok_t "L${label} the count ask says why a person must approve" \
      || bad_t "L${label} count reason" "ask=$ask"
  fi
}
long_arm 1 shop-a
long_arm 2 shop-b t2

# ── S. short outcomes ────────────────────────────────────────────────────────
out=$(run cmd_goal_add --plan="$(plan_for shop-s)" --project=shop-s -- "Open the candle shop"); a=$(printf '%s' "$out" | jq -r '.data.anchor // ""')
ask=$(col "$a" ask)
[[ -n "$a" && "$ask" == 'Approve the 8-step plan for "Open the candle shop"? '* ]] \
  && ok_t "S1 a short outcome is named whole: $ask" \
  || bad_t "S1 short outcome named whole" "out=$out ask=$ask"
out=$(run cmd_goal_add --plan="$(plan_for shop-j)" --project=shop-j -- "Finish DIVE-1234 for the shop"); a=$(printf '%s' "$out" | jq -r '.data.anchor // ""')
ask=$(col "$a" ask)
[[ -n "$a" && "$ask" == "Approve the 8-step plan for your goal? "* && "$(human_verdict "$a")" == "1" ]] \
  && ok_t "S2 an outcome that reads as an internal name becomes 'your goal' and the gate still files" \
  || bad_t "S2 jargon outcome" "out=$out ask=$ask err=$(head -c 300 "$TMP/run.err")"

# ── R. a refused gate leaves nothing behind ─────────────────────────────────
refuse_need() { fail "$E_VALIDATION" "STUB-REFUSAL: the gate cap said no"; }
out=$( set -e; actor_seam_as swan; cmd_task_need() { refuse_need; }
       cmd_goal_add --plan="$(plan_for shop-r)" --project=shop-r -- "$LONG" 2>/dev/null ); rc=$?
nanc=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='shop-r';")
nproj=$(db "SELECT COUNT(*) FROM projects WHERE key='shop-r';")
[[ $rc -ne 0 && "$nanc" == "0" && "$nproj" == "0" ]] \
  && ok_t "R1 a refused plan gate leaves no anchor and no project (rc=$rc)" \
  || bad_t "R1 no anchor without a gate" "rc=$rc anchors=$nanc projects=$nproj out=$out"
[[ "$(printf '%s' "$out" | jq -r '.error.message // ""' 2>/dev/null)" == *"STUB-REFUSAL"* ]] \
  && ok_t "R2 the failure names the gate's own reason" \
  || bad_t "R2 failure reason" "out=$out"

# ── J. the async path ───────────────────────────────────────────────────────
# job_for <key> — a pending async job whose planner task has landed an 8-task plan.
job_for() {
  local o j t
  o=$( set -e; actor_seam_as swan; cmd_goal_add --planner=swan --project="$1" -- "$LONG" 2>/dev/null )
  j=$(printf '%s' "$o" | jq -r '.data.job // ""')
  t=$(db "SELECT task_id FROM goal_jobs WHERE job_id=$(sqlq "$j");")
  [[ -n "$t" ]] && db "UPDATE tasks SET status='done', result=$(sqlq "$(plan_for "$1")") WHERE id=${t};" >/dev/null
  printf '%s' "$j"
}
JOB=$(job_for shop-j1)
out=$( set -e; actor_seam_as swan; cmd_goal_status "$JOB" 2>/dev/null )
[[ "$(printf '%s' "$out" | jq -r '.data.status // ""')" == "done" && "$(printf '%s' "$out" | jq -r '.data.gated // false')" == "true" ]] \
  && ok_t "J1 async: a 41-word outcome over the checkpoint reaches gated" \
  || bad_t "J1 async long outcome gates" "job=$JOB out=$out"
JOB=$(job_for shop-j2)
out=$( set -e; actor_seam_as swan; cmd_task_need() { refuse_need; }; cmd_goal_status "$JOB" 2>/dev/null )
reason=$(printf '%s' "$out" | jq -r '.data.reason // ""')
[[ "$(printf '%s' "$out" | jq -r '.data.status // ""')" == "failed" && "$reason" == *"STUB-REFUSAL"* ]] \
  && ok_t "J2 async: a refused gate's real reason is the job's reason ($reason)" \
  || bad_t "J2 async failure reason" "job=$JOB out=$out"
nanc=$(db "SELECT COUNT(*) FROM tasks WHERE project_key='shop-j2' AND title LIKE 'Goal:%';")
[[ "$nanc" == "0" ]] \
  && ok_t "J3 async: the failed finish left no ungated anchor" \
  || bad_t "J3 async ungated anchor left" "anchors=$nanc"

SUMMARY_PRINTED=1
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
