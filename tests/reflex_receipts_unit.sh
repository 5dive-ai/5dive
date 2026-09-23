#!/usr/bin/env bash
# DIVE-4866 — reflex phase 0: decision receipts at the four decision points, and
# the offline replay harness that scores a candidate backend against them.
#
# WHAT THIS GRADES
#  A. A receipt lands at each decision point, through the REAL verb, not a call
#     to the helper: task add and task assign (task-route), task reject
#     (retry-action), the reaper's _hb_reclaim_to_todo (stuck), and task answer
#     (gate-answer, with matched_recommend).
#  B. A receipt carries labels, ids and counts, never content: the title, the
#     gate ask, an option's text and the answer's text are absent from the
#     stored row, and a secret gate records "provided" and nothing else.
#  C. ADDITIVE ONLY: with the receipt helpers missing, the verb still exits 0 and
#     still does its job. FIVEDIVE_REFLEX_RECEIPTS=0 writes nothing.
#  D. The replay: history is rebuilt from the ledger, live receipts take over
#     from their first timestamp (nothing counted twice), the fake backend scores
#     deterministically, and a backend that answers badly (a choice outside the
#     options, a missing line) is scored INVALID and never silently dropped.
#
# Runs against a real sqlite board in a throwaway STATE_DIR, never the live one.
# No root, no network.
# TIER: core — 5.7s measured on the 5dive control plane (agent-dev seat, worktree cli-4866-dev, 2026-09-23, slowest of 3: 5.67/5.73/4.79s).
# Run: bash tests/reflex_receipts_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/reflex-receipts-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/reflex.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh cmd_reflex.sh cmd_trace.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" 2>/dev/null || true

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/agents.json"
printf '{"agents":{"main":{},"dev":{},"dev2":{},"quinn":{}}}\n' >"$REGISTRY"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init
task_need_notify() { return 0; }
audit_log() { return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { # <name> <cond-rc> [detail]
  if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi
}
rcpt() { # <policy> <task id> -> the newest receipt for that task, as JSON
  db "SELECT detail FROM lifecycle_events WHERE kind='decision.$1' AND task_id=$2 ORDER BY id DESC LIMIT 1;"
}
nrcpt() { db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%'${1:+ AND task_id=$1};"; }
idof()  { db "SELECT id FROM tasks WHERE ident='$1';"; }

echo "── A/B: a receipt at each decision point, content-free ──────────────────"

# --- task-route, via add ---------------------------------------------------
OUT=$(JSON_MODE=1 cmd_task_add --assignee=dev --priority=high -- "SECRETTITLE route me" 2>/dev/null)
I1=$(jq -r '.data.ident' <<<"$OUT"); T1=$(idof "$I1")
R=$(rcpt task-route "$T1")
check "task add writes a task-route receipt with result=assignee" \
  "$(jq -e '.result=="dev" and .effect.via==null and .signals.via=="add" and .backend.adapter=="current_behavior"' <<<"$R" >/dev/null; echo $?)" "$R"
check "the route receipt's candidates are the roster" \
  "$(jq -e '.candidates==["dev","dev2","main","quinn"]' <<<"$R" >/dev/null; echo $?)" "$R"
check "the receipt carries the proposal's hashes and an id that is its idem key" \
  "$(jq -e '(.state_hash|startswith("sha256:")) and (.candidate_hash|startswith("sha256:")) and (.id|startswith("dec_"))' <<<"$R" >/dev/null \
     && [[ "$(db "SELECT idem_key FROM lifecycle_events WHERE kind='decision.task-route' AND task_id=$T1;")" == "$(jq -r .id <<<"$R")" ]]; echo $?)" "$R"
check "no title text in any receipt" \
  "$(grep -qx 0 <<<"$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%' AND detail LIKE '%SECRETTITLE%';")"; echo $?)"

# --- task-route, via assign ------------------------------------------------
cmd_task_assign "$I1" dev2 >/dev/null 2>&1
R=$(rcpt task-route "$T1")
check "task assign writes a task-route receipt with from/to" \
  "$(jq -e '.result=="dev2" and .effect.from=="dev" and .effect.to=="dev2" and .signals.via=="assign"' <<<"$R" >/dev/null; echo $?)" "$R"

# --- retry-action, via reject ----------------------------------------------
db "UPDATE tasks SET maker_agent='dev2', verifier='quinn', assignee='quinn', iteration=1, max_iterations=3,
      handoff_delivered_at=datetime('now'), status='todo' WHERE id=${T1};"
ACTOR_OVERRIDE=quinn TASK_ACTOR=quinn cmd_task_reject "$I1" \
  --feedback="FINDING: x FIX: name the concrete change VERIFY: rerun" >/dev/null 2>&1
R=$(rcpt retry-action "$T1")
check "task reject writes a retry-action receipt (bounce = retry_with_feedback)" \
  "$(jq -e '.result=="retry_with_feedback" and .candidates==["human","retry_with_feedback"] and .signals.iteration==1 and .effect.disposition=="bounced"' <<<"$R" >/dev/null; echo $?)" "$R"

# --- stuck, via the reaper's primitive -------------------------------------
db "UPDATE tasks SET status='in_progress', assignee='dev2', started_at=datetime('now','-50 minutes') WHERE id=${T1};"
_hb_reclaim_to_todo dev2 "$T1" "overran 45m budget (reap #1) — requeued from a clean slate, NOT cancelled" >/dev/null 2>&1
R=$(rcpt stuck "$T1")
check "the reaper writes a stuck receipt with the reason class and claim age" \
  "$(jq -e '.result=="reclaim" and .signals.reason=="budget" and (.signals.claim_age_min>=49 and .signals.claim_age_min<=51) and .effect.seat=="dev2"' <<<"$R" >/dev/null; echo $?)" "$R"
check "the reclaim itself still happened" "$(grep -qx todo <<<"$(db "SELECT status FROM tasks WHERE id=$T1;")"; echo $?)"
check "the reaper's receipt is not the reaped seat's work (authority=dispatcher, as task.reclaimed)" \
  "$(grep -qx dispatcher <<<"$(db "SELECT authority FROM lifecycle_events WHERE kind='decision.stuck' AND task_id=$T1;")"; echo $?)"
OUT=$(JSON_MODE=0 cmd_trace "$I1" --no-audit 2>/dev/null)
check "trace shows a receipt as its pick, not as the JSON blob" \
  "$(grep -q 'decision.task-ro.*decided dev2 of 4 option(s) (current_behavior)' <<<"$OUT" && ! grep -q '"state_hash"' <<<"$OUT"; echo $?)" "$(grep -n decision <<<"$OUT")"

# --- gate-answer, via need + answer ----------------------------------------
OUT=$(JSON_MODE=1 cmd_task_add --assignee=dev -- "gate row" 2>/dev/null); I2=$(jq -r '.data.ident' <<<"$OUT"); T2=$(idof "$I2")
cmd_task_need "$I2" --type=decision --options="KEEPOPT going|DROPOPT it" --recommend="KEEPOPT going" \
  --ask="ASKTEXT which way" --ask-ok="fixture gate: the options are the input under test (DIVE-4866)" --tier=1 >"$TMP/need.out" 2>&1
cmd_task_answer "$I2" --value="DROPOPT it" --human >"$TMP/answer.out" 2>&1
R=$(rcpt gate-answer "$T2")
check "task answer writes a gate-answer receipt labelled by option, with matched_recommend" \
  "$(jq -e '.result=="opt2" and .signals.matched_recommend==false and .signals.need_type=="decision"' <<<"$R" >/dev/null; echo $?)" "$R $(tail -n3 "$TMP/need.out" "$TMP/answer.out")"
check "the gate-answer candidates are the legal set, never the answer text" \
  "$(jq -e '.candidates==["opt1","opt2","other"] and .signals.recommend=="opt1" and .signals.n_options==2' <<<"$R" >/dev/null; echo $?)" "$R"
check "no ask, option or answer text in any receipt" \
  "$(grep -qx 0 <<<"$(db "SELECT COUNT(*) FROM lifecycle_events WHERE kind LIKE 'decision.%' AND (detail LIKE '%ASKTEXT%' OR detail LIKE '%KEEPOPT%' OR detail LIKE '%DROPOPT%');")"; echo $?)"

# A secret: the helper reads the row, so drive it directly off a stored secret.
OUT=$(JSON_MODE=1 cmd_task_add --assignee=dev -- "secret row" 2>/dev/null); T3=$(idof "$(jq -r '.data.ident' <<<"$OUT")")
db "UPDATE tasks SET need_type='secret', need_answer='sk-SECRETVALUE', need_answered_by='human:1234567890', tier=2 WHERE id=$T3;"
reflex_gate_receipt "$T3"
R=$(rcpt gate-answer "$T3")
check "a secret gate records 'provided' and nothing of the value" \
  "$(jq -e '.result=="provided" and .signals.matched_recommend==false' <<<"$R" >/dev/null \
     && ! grep -q SECRETVALUE <<<"$R"; echo $?)" "$R"

echo "── C: additive only ─────────────────────────────────────────────────────"

N0=$(nrcpt)
FIVEDIVE_REFLEX_RECEIPTS=0 cmd_task_assign "$I2" dev2 >/dev/null 2>&1
check "FIVEDIVE_REFLEX_RECEIPTS=0 writes no receipt" "$([[ "$(nrcpt)" == "$N0" ]]; echo $?)"

# Break the helpers the way a partial source set would: undefined entirely.
(
  unset -f reflex_receipt reflex_roster_csv reflex_gate_receipt
  cmd_task_assign "$I2" main >/dev/null 2>&1; echo "rc=$?"
) >"$TMP/nohelper.out"
check "with no reflex helpers defined, task assign still exits 0 and moves the row" \
  "$(grep -qx 'rc=0' "$TMP/nohelper.out" && [[ "$(db "SELECT assignee FROM tasks WHERE id=$T2;")" == main ]]; echo $?)" "$(cat "$TMP/nohelper.out")"
# A jq that always fails: the receipt is lost, the verb is not.
(
  mkdir -p "$TMP/badbin"; printf '#!/bin/sh\nexit 1\n' >"$TMP/badbin/jq"; chmod +x "$TMP/badbin/jq"
  PATH="$TMP/badbin:$PATH" cmd_task_assign "$I2" dev >/dev/null 2>&1; echo "rc=$?"
) >"$TMP/badjq.out"
check "with a broken jq, task assign still exits 0" "$(grep -qx 'rc=0' "$TMP/badjq.out"; echo $?)" "$(cat "$TMP/badjq.out")"

echo "── D: the replay ────────────────────────────────────────────────────────"

# A fresh board with a known history, so every number below is derivable by hand.
TASKS_DB="$TMP/replay.db"; TASKS_DIR="$TMP"
tasks_db_init >/dev/null 2>&1
le() { # <kind> <task_id> <actor> <ts> <detail>
  db "INSERT INTO lifecycle_events (kind, ident, task_id, actor, idem_key, ts, detail)
      VALUES ('$1', 'DIVE-$2', $2, '$3', '$1|$2|$4|$RANDOM$RANDOM', '$4', $(sqlq "$5"));"
}
mkrow() { db "INSERT INTO tasks (id, title, status, created_by, kind) VALUES ($1, 't$1', '$2', 'main', 'standard');"; }
mkrow 1 done; mkrow 2 done; mkrow 3 cancelled; mkrow 4 todo
H=$(date -u -d '-3 days' '+%Y-%m-%d %H:%M:%S'); H2=$(date -u -d '-3 days +5 minutes' '+%Y-%m-%d %H:%M:%S')
H3=$(date -u -d '-2 days' '+%Y-%m-%d %H:%M:%S')
# route: 1 -> dev, delivered by dev (right); 2 -> main, delivered by dev2 (wrong).
le task.created 1 main "$H" "high → dev"
le task.created 2 main "$H" "high → main"
le task.delivered 1 dev "$H3" "delivered"; le task.done 1 quinn "$H3" "done"
le task.delivered 2 dev2 "$H3" "delivered"; le task.done 2 quinn "$H3" "done"
# retry: 1 bounced, delivered again, done -> retry was right. 3 bounced, cancelled
# with no delivery after -> human was right, current (bounce) wrong.
le task.rejected 1 quinn "$H" "rejected by quinn at iteration 1/3, bounced back to maker dev; prior_result=none"
le task.rejected 3 quinn "$H" "rejected by quinn at iteration 1/3, bounced back to maker dev; prior_result=none"
# stuck: 2 reaped from dev2, which delivered 2 days later (not quick) -> reclaim right.
#        4 reaped from dev, which delivered 5 minutes later -> leave was right.
le task.reclaimed 2 dev2 "$H" "reclaim -> todo (DIVE-3251); why=idle 20m with the task still open; cleared started_at=$H"
le task.reclaimed 4 dev "$H" "reclaim -> todo (DIVE-3251); why=overran 45m budget (reap #1); cleared started_at=$H"
le task.delivered 4 dev "$H2" "delivered"
# gates: one answered with the recommendation, one against it, one approval.
db "INSERT INTO gate_history (task_id, ident, need_type, need_options, recommend, need_answer, need_answered_at, need_answered_by, tier, retired_by)
    VALUES (1,'DIVE-1','decision','Yes do it|No wait','Yes do it','yes do it','$H','human:1',1,'test'),
           (2,'DIVE-2','decision','Yes do it|No wait','Yes do it','No wait','$H','human:1',1,'test'),
           (3,'DIVE-3','approval','','approve','Approved — push it','$H','lead:ops',1,'test');"

J=$(JSON_MODE=0 _reflex_replay --since=7d --json 2>/dev/null)
p() { jq -c --arg p "$1" '.policies[] | select(.policy==$p)' <<<"$J"; }
check "history is rebuilt: 2 route, 2 retry, 2 stuck, 3 gate cases" \
  "$(jq -e '[.policies[].cases]==[2,2,2,3] and ([.policies[].from_history]==[2,2,2,3])' <<<"$J" >/dev/null; echo $?)" "$J"
check "task-route: today's routing scored 1 of 2 against the seat that delivered" \
  "$(p task-route | jq -e '.resolved==2 and .current_behavior_accuracy==0.5 and .backend_accuracy==0.5 and .agreement_with_current==1' >/dev/null; echo $?)" "$(p task-route)"
check "retry-action: the cancelled-without-redelivery bounce scores wrong" \
  "$(p retry-action | jq -e '.current_behavior_accuracy==0.5 and .outcome_labels=={"human":1,"retry_with_feedback":1}' >/dev/null; echo $?)" "$(p retry-action)"
check "stuck: a delivery within 10 minutes of the kill labels it leave" \
  "$(p stuck | jq -e '.outcome_labels=={"leave":1,"reclaim":1} and .current_behavior_accuracy==0.5' >/dev/null; echo $?)" "$(p stuck)"
check "gate-answer: 2 of 3 answered with the recommendation; no current is shown the backend" \
  "$(p gate-answer | jq -e '.with_recommend==3 and (.matched_recommend_rate*3|round)==2 and .current_behavior_accuracy==null' >/dev/null; echo $?)" "$(p gate-answer)"

J=$(_reflex_replay --since=7d --json --backend=fake:recommend --policy=gate-answer 2>/dev/null)
check "fake:recommend reproduces the recommend-match rate as its accuracy" \
  "$(jq -e '.policies|length==1 and (.[0].backend_accuracy*3|round)==2 and .[0].invalid==0' <<<"$J" >/dev/null; echo $?)" "$J"

# A backend that picks outside the options on line 1 and stops after line 2.
cat >"$TMP/bad-backend.sh" <<'EOF'
#!/usr/bin/env bash
n=0
while IFS= read -r l; do
  n=$((n+1))
  if (( n == 1 )); then echo '{"choice":"not-an-option"}'
  elif (( n == 2 )); then jq -c '{choice:.options[0]}' <<<"$l"
  fi
done
EOF
J=$(_reflex_replay --since=7d --json --backend="bash $TMP/bad-backend.sh" --policy=stuck 2>/dev/null)
check "an out-of-options choice and a missing line are INVALID, never dropped" \
  "$(jq -e '.policies[0].cases==2 and .policies[0].invalid==1' <<<"$J" >/dev/null; echo $?)" "$J"

# A live receipt takes over from its own timestamp: history before it still
# counts, history after it does not (the receipt IS that decision).
LIVE='{"v":1,"id":"dec_x","policy":"stuck","task":"DIVE-4","candidates":["leave","reclaim"],"result":"reclaim","signals":{"reason":"budget"},"effect":{"task":"DIVE-4","seat":"dev"}}'
db "INSERT INTO lifecycle_events (kind, ident, task_id, actor, idem_key, ts, detail)
    VALUES ('decision.stuck','DIVE-4',4,'dev','dec_x','$H',$(sqlq "$LIVE"));"
J=$(_reflex_replay --since=7d --json --policy=stuck 2>/dev/null)
check "a live receipt replaces the history rebuilt at or after its timestamp" \
  "$(jq -e '.policies[0].cases==1 and .policies[0].from_receipts==1 and .policies[0].from_history==0' <<<"$J" >/dev/null; echo $?)" "$J"

OUT=$(_reflex_log --policy=stuck 2>/dev/null)
check "reflex log lists the receipt" "$(grep -q 'stuck.*DIVE-4.*reclaim' <<<"$OUT"; echo $?)" "$OUT"

echo
echo "reflex receipts: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
