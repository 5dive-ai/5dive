#!/usr/bin/env bash
# DIVE-4916 — reflex phase 1: the gate-answer SHADOW. The configured model picks
# an answer for every new gate; the pick is a receipt and nothing else.
#
# WHAT THIS GRADES
#  S1. Byte-identical. A gate filed through the real `task need`, then shadowed
#      by a fake backend: the task row, its gate_history, every non-shadow ledger
#      row and the notification are identical before and after the sweep, and
#      identical (modulo clock and nonce) to a run with NO backend configured.
#      The shadow receipt carries the pick, confidence and probabilities, and the
#      request carried the title/ask/options but never the body or the answer.
#      The answer, when it lands, links back to the shadow receipt.
#  S2. Time box. A backend that hangs leaves the gate unaffected, returns inside
#      the box and records effect.error=timeout; the kick returns at once.
#  S3. Opt-in. No model in box.json, or a model with neither key nor backend,
#      shadows nothing. Secret gates are never shadowed. A gate shadowed once is
#      never shadowed twice.
#  S4. `reflex report --live` bands and scores a fixture of answered gates, lists
#      the >=0.9 picks auto-apply would have got wrong, and the replay never counts
#      a shadow receipt as today's decision.
#  M.  Mutant: the shadow writes its pick into the gate's answer -> S1 goes red.
#
# Throwaway STATE_DIR, fake backends only: no root, no network, no key.
# TIER: core — 24.2s measured on the 5dive control plane (agent-dev seat, worktree cli-4916-dev, 2026-09-24, slowest of 3: 19.3/20.8/24.2s).
# Run: bash tests/reflex_shadow_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/reflex-shadow-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/routing_receipt.sh lib/reflex.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh cmd_reflex.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" 2>/dev/null || true
set +e
JSON_MODE=0
audit_log() { return 0; }
# The notification, recorded instead of sent. Arg 8 is the per-gate human nonce
# (random by design), so the cross-run comparison masks it; the same-run
# before/after comparison does not need to.
task_need_notify() { printf '%s\n' "$(jq -cn --args '$ARGS.positional' "$@")" >>"$NOTIFY_LOG"; return 0; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if [[ "$2" == 0 ]]; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

board() { # <dir> — a fresh board and box config, made current
  STATE_DIR="$1"; TASKS_DIR="$1/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
  REGISTRY="$1/agents.json"; BOX_CONFIG="$1/box.json"; NOTIFY_LOG="$1/notify.log"
  mkdir -p "$TASKS_DIR"; : >"$NOTIFY_LOG"
  printf '{"agents":{"main":{},"dev":{}}}\n' >"$REGISTRY"
  printf '{"verify":"delivered-only"}\n' >"$BOX_CONFIG"
  tasks_db_init >/dev/null 2>&1
}
set_model() { jq --arg m "$1" '.reflex_model=$m' "$BOX_CONFIG" >"$BOX_CONFIG.t" && mv "$BOX_CONFIG.t" "$BOX_CONFIG"; }
idof() { db "SELECT id FROM tasks WHERE ident='$1';"; }
# Everything the shadow must not touch, as one blob: the whole row, the retired
# epochs, every ledger row that is not a shadow receipt, and the notifications.
snap() { # <task id> [mask]
  local m="${2:-}"
  {
    sqlite3 -json "$TASKS_DB" "SELECT * FROM tasks WHERE id=$1;"
    sqlite3 -json "$TASKS_DB" "SELECT * FROM gate_history WHERE task_id=$1 ORDER BY id;"
    sqlite3 -json "$TASKS_DB" "SELECT kind, actor, authority, policy_decision, detail FROM lifecycle_events
       WHERE task_id=$1 AND NOT (kind='decision.gate-answer' AND json_extract(detail,'\$.mode')='shadow') ORDER BY id;"
    cat "$NOTIFY_LOG"
  } | if [[ -n "$m" ]]; then
    # Cross-run mask: clocks, the random nonce and its hash, and receipt ids.
    sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:]{8}(\.[0-9]+)?Z?/<T>/g; s/dec_[0-9a-f]+/<ID>/g;
            s/"human_nonce_hash":"[^"]*"/"human_nonce_hash":<N>/g; s/sha256:[0-9a-f]{16}/<H>/g' \
      | jq -c 'if type=="array" and length==9 and (.[7]|type)=="string" then .[7]="<nonce>" else . end' 2>/dev/null
  else cat; fi
}
shadow_rcpt() { db "SELECT detail FROM lifecycle_events WHERE kind='decision.gate-answer' AND task_id=$1
                    AND json_extract(detail,'\$.mode')='shadow' ORDER BY id DESC LIMIT 1;"; }
nshadow() { db "SELECT COUNT(*) FROM lifecycle_events WHERE kind='decision.gate-answer' AND json_extract(detail,'\$.mode')='shadow';"; }

# A fake backend: logs each request, picks opt2 at 0.93 with a distribution.
FAKE="tee -a \"\$RX_REQ_LOG\" | jq -c '{choice: \"opt2\", confidence: 0.93, probabilities: {opt1: 0.05, opt2: 0.93, other: 0.02}, probability_source: \"head\"}'"
export RX_REQ_LOG="$TMP/requests.jsonl"

file_gate() { # -> ident; a decision gate through the real verb
  local out ident
  out=$(JSON_MODE=1 cmd_task_add --assignee=dev -- "TITLETEXT pick a lane" 2>/dev/null); ident=$(jq -r '.data.ident' <<<"$out")
  db "UPDATE tasks SET body='BODYTEXT never send me' WHERE ident='$ident';"
  cmd_task_need "$ident" --type=decision --options="KEEPOPT going|DROPOPT it" --recommend="KEEPOPT going" \
    --ask="ASKTEXT which way" --ask-ok="fixture gate: the options are the input under test (DIVE-4916)" --tier=1 >/dev/null 2>&1
  printf '%s' "$ident"
}

# s1_arm <label> — S1 on a fresh board; prints BEFORE==AFTER as rc. Used by the
# mutant too, so the same predicate is what goes red.
s1_arm() {
  board "$TMP/$1"; set_model "typesafe/jev-1.13"
  local ident id before after
  ident=$(file_gate); id=$(idof "$ident")
  before=$(snap "$id")
  FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
  after=$(snap "$id")
  S1_ID="$id"; S1_IDENT="$ident"
  [[ "$before" == "$after" ]]
}

echo "── S1: the shadow changes nothing ──────────────────────────────────────"
: >"$RX_REQ_LOG"
s1_arm with; RC=$?
check "S1 row, gate_history, ledger and notification are byte-identical before and after the sweep" "$RC"
R=$(shadow_rcpt "$S1_ID")
check "S1 a shadow receipt lands with the model, pick, confidence and probabilities" \
  "$(jq -e '.mode=="shadow" and .result=="opt2" and .confidence==0.93 and .probabilities.opt2==0.93
            and .probability_source=="head" and .backend.model=="typesafe/jev-1.13" and .fallback==false
            and .effect.acted==false and (.effect.gate_asked_at|length)>0 and .effect.error==null
            and .candidates==["opt1","opt2","other"]' <<<"$R" >/dev/null; echo $?)" "$R"
check "S1 the receipt holds no title, ask or option text" \
  "$(! grep -qE 'TITLETEXT|ASKTEXT|KEEPOPT|DROPOPT' <<<"$R"; echo $?)" "$R"
check "S1 the request carried title, ask, options and recommend (the replay's --inputs=titles shape)" \
  "$(jq -se 'length==1 and .[0].policy=="gate-answer" and .[0].state.title=="TITLETEXT pick a lane"
             and .[0].state.gate.ask=="ASKTEXT which way" and .[0].state.gate.options=={"opt1":"KEEPOPT going","opt2":"DROPOPT it"}
             and .[0].state.gate.recommend=="KEEPOPT going" and .[0].options==["opt1","opt2","other"]' "$RX_REQ_LOG" >/dev/null; echo $?)" "$(cat "$RX_REQ_LOG")"
check "S1 the request never carried the body or an outcome field" \
  "$(! grep -qE 'BODYTEXT|matched_recommend|answered_by' "$RX_REQ_LOG"; echo $?)" "$(cat "$RX_REQ_LOG")"
WITH=$(snap "$S1_ID" mask)
FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
check "S1 a gate is shadowed once: a second sweep adds nothing" "$([[ "$(nshadow)" == 1 ]]; echo $?)" "$(nshadow)"

# The same filing with no backend configured at all.
board "$TMP/without"; ident=$(file_gate); id=$(idof "$ident")
reflex_shadow_sweep
WITHOUT=$(snap "$id" mask)
check "S1 the gated row and its notification match a run with NO backend (clock and nonce masked)" \
  "$([[ -n "$WITH" && "$WITH" == "$WITHOUT" ]]; echo $?)" "$(diff <(printf '%s\n' "$WITH") <(printf '%s\n' "$WITHOUT") | head -5)"
check "S1 ...and the run with no backend wrote no shadow" "$([[ "$(nshadow)" == 0 ]]; echo $?)"

# The answer links back to the pick.
board "$TMP/link"; set_model "typesafe/jev-1.13"; ident=$(file_gate); id=$(idof "$ident")
FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
SID=$(jq -r .id <<<"$(shadow_rcpt "$id")")
cmd_task_answer "$ident" --value="DROPOPT it" --human >/dev/null 2>&1
A=$(db "SELECT detail FROM lifecycle_events WHERE kind='decision.gate-answer' AND task_id=$id
        AND json_extract(detail,'\$.mode')='observe' ORDER BY id DESC LIMIT 1;")
check "S1 the gate-answer receipt links the shadow pick (id, pick, matched)" \
  "$(jq -e --arg s "$SID" '.result=="opt2" and .effect.shadow==$s and .effect.shadow_pick=="opt2" and .effect.shadow_matched==true' <<<"$A" >/dev/null; echo $?)" "$A"
check "S1 the answer landed as the human gave it, not as the model picked" \
  "$([[ "$(db "SELECT need_answer FROM tasks WHERE id=$id;")" == "DROPOPT it" ]]; echo $?)"

echo "── S2: the time box ────────────────────────────────────────────────────"
board "$TMP/hang"; set_model "typesafe/jev-1.13"; ident=$(file_gate); id=$(idof "$ident")
before=$(snap "$id"); t0=$(date +%s)
FIVEDIVE_REFLEX_SHADOW_TIMEOUT=1 FIVEDIVE_REFLEX_SHADOW_BACKEND="sleep 30" reflex_shadow_sweep
el=$(( $(date +%s) - t0 ))
check "S2 a hanging backend is cut at the time box (${el}s for a 1s box)" "$(( el <= 4 ? 0 : 1 ))"
R=$(shadow_rcpt "$id")
check "S2 the timeout is a receipt field, not a pick" \
  "$(jq -e '.effect.error=="timeout" and .result=="none" and .fallback==true and .confidence==null and .effect.time_box_s==1' <<<"$R" >/dev/null; echo $?)" "$R"
check "S2 the gate is unaffected by the hang" "$([[ "$before" == "$(snap "$id")" ]]; echo $?)"
# The heartbeat's entry point returns at once and the sweep finishes detached.
board "$TMP/kick"; set_model "typesafe/jev-1.13"; ident=$(file_gate); id=$(idof "$ident")
t0=$(date +%s%N)
FIVEDIVE_REFLEX_SHADOW_LOCK="$TMP/kick.lock" FIVEDIVE_REFLEX_SHADOW_BACKEND="sleep 1; $FAKE" reflex_shadow_kick
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "S2 reflex_shadow_kick returns without waiting on the backend (${ms}ms)" "$(( ms < 800 ? 0 : 1 ))"
for _ in $(seq 1 40); do [[ -n "$(shadow_rcpt "$id")" ]] && break; sleep 0.25; done
check "S2 ...and the detached sweep still writes the pick" "$(jq -e '.result=="opt2"' <<<"$(shadow_rcpt "$id")" >/dev/null; echo $?)"

echo "── S3: opt-in ──────────────────────────────────────────────────────────"
board "$TMP/optin"; ident=$(file_gate); id=$(idof "$ident")
FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
check "S3 no reflex_model on the box: nothing shadowed, backend or not" "$([[ "$(nshadow)" == 0 ]]; echo $?)"
set_model "typesafe/jev-1.13"
FIVEDIVE_REFLEX_OPENROUTER_KEY_FILE="$TMP/absent.key" reflex_shadow_sweep
check "S3 a model but no readable key and no backend: nothing shadowed" "$([[ "$(nshadow)" == 0 ]]; echo $?)"
FIVEDIVE_REFLEX_SHADOW=0 FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
check "S3 FIVEDIVE_REFLEX_SHADOW=0 wins over the box" "$([[ "$(nshadow)" == 0 ]]; echo $?)"
out=$(JSON_MODE=1 cmd_task_add --assignee=dev -- "secret row" 2>/dev/null); T3=$(idof "$(jq -r '.data.ident' <<<"$out")")
db "UPDATE tasks SET need_type='secret', ask='paste it', need_asked_at=datetime('now'), tier=2 WHERE id=$T3;"
FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
check "S3 with it on, the decision gate is shadowed and the secret gate is not" \
  "$([[ -n "$(shadow_rcpt "$id")" && -z "$(shadow_rcpt "$T3")" ]]; echo $?)"
db "UPDATE tasks SET need_type='decision', need_asked_at=datetime('now','-2 hours') WHERE id=$T3;"
FIVEDIVE_REFLEX_SHADOW_BACKEND="$FAKE" reflex_shadow_sweep
check "S3 a gate asked before the window is history, not live: not shadowed" "$([[ -z "$(shadow_rcpt "$T3")" ]]; echo $?)"

echo "── S4: the live report ─────────────────────────────────────────────────"
board "$TMP/report"
AT=$(date -u '+%Y-%m-%d %H:%M:%S')
mk() { # <id> <answer|-> ; a gate_history epoch with options Yes/No, recommend Yes
  db "INSERT INTO tasks (id, ident, title, status, created_by, kind) VALUES ($1, 'DIVE-$1', 't$1', 'todo', 'main', 'standard');"
  [[ "$2" == - ]] && { db "UPDATE tasks SET need_type='decision', need_options='Yes do it|No wait', recommend='Yes do it', need_asked_at='$AT' WHERE id=$1;"; return; }
  db "INSERT INTO gate_history (task_id, ident, need_type, need_options, recommend, need_asked_at, need_answer, need_answered_at, need_answered_by, tier, retired_by)
      VALUES ($1, 'DIVE-$1', 'decision', 'Yes do it|No wait', 'Yes do it', '$AT', $(sqlq "$2"), '$AT', 'human:1', 1, 'test');"
}
pick() { # <id> <pick> <confidence|null> [error]
  reflex_receipt policy=gate-answer mode=shadow ident="DIVE-$1" task_id="$1" result="$2" confidence="$3" \
    candidates="opt1,opt2,other" backend='{"adapter":"command","model":"typesafe/jev-1.13"}' \
    fallback="$([[ -n "${4:-}" ]] && echo true || echo false)" actor=reflex authority=heartbeat \
    effect="$(jq -cn --arg at "$AT" --arg e "${4:-}" '{gate_asked_at:$at, acted:false} + (if $e=="" then {} else {error:$e} end)')"
}
mk 1 "Yes do it"; pick 1 opt1 0.95          # >=0.9 right, answered = recommend
mk 2 "No wait";   pick 2 opt1 0.92          # >=0.9 WRONG, answered against recommend
mk 3 "no wait";   pick 3 opt2 0.8           # 0.7-0.9 right
mk 4 "2";         pick 4 opt1 0.5           # <0.7 wrong ("2" is option 2)
mk 5 -;           pick 5 opt1 0.97          # not answered yet
mk 6 "Yes do it"; pick 6 none null timeout  # a failed call
mk 7 "Yes do it"; pick 7 opt1 null          # a pick with no confidence
J=$(JSON_MODE=0 _reflex_report --live --json 2>&1)
b() { jq -c --arg b "$1" '.bands[] | select(.band==$b)' <<<"$J"; }
check "S4 counts: 7 shadowed, 6 answered, 1 open, 1 failed (timeout)" \
  "$(jq -e '.shadowed==7 and .answered==6 and .pending==1 and .failed==1 and .failures=={"timeout":1}' <<<"$J" >/dev/null; echo $?)" "$J"
check "S4 >=0.9: 2 scored, model right 50%, answered-with-recommend 50%" \
  "$(b '>=0.9' | jq -e '.scored==2 and .accuracy==0.5 and .recommend_match==0.5' >/dev/null; echo $?)" "$(b '>=0.9')"
check "S4 0.7-0.9: 1 scored, right 100%, recommend 0%" \
  "$(b '0.7-0.9' | jq -e '.scored==1 and .accuracy==1 and .recommend_match==0' >/dev/null; echo $?)" "$(b '0.7-0.9')"
check "S4 <0.7: 1 scored, right 0% (an answer given as the option's number is still opt2)" \
  "$(b '<0.7' | jq -e '.scored==1 and .accuracy==0 and .recommend_match==0' >/dev/null; echo $?)" "$(b '<0.7')"
check "S4 no confidence is its own band; the failed call is scored nowhere" \
  "$(b none | jq -e '.scored==1 and .accuracy==1' >/dev/null && jq -e '.overall.scored==5' <<<"$J" >/dev/null; echo $?)" "$J"
check "S4 would_be_wrong lists exactly the >=0.9 miss, with its answer" \
  "$(jq -e '.would_be_wrong|length==1 and .[0].ident=="DIVE-2" and .[0].pick=="opt1" and .[0].answer=="opt2" and .[0].answer_text=="No wait"' <<<"$J" >/dev/null; echo $?)" "$(jq -c .would_be_wrong <<<"$J")"
T=$(JSON_MODE=0 _reflex_report --live 2>&1)
check "S4 the text report prints the bands and the wrong-at-0.9 line" \
  "$(grep -q '^>=0.9 ' <<<"$T" && grep -q 'WRONG on 1 gate' <<<"$T" && grep -q 'DIVE-2  picked opt1 at 0.92  answered opt2 (No wait)' <<<"$T"; echo $?)" "$T"
check "S4 report without --live is refused" "$( ( _reflex_report >/dev/null 2>&1 ); [[ $? != 0 ]]; echo $?)"
RJ=$(JSON_MODE=0 _reflex_replay --since=7d --policy=gate-answer --json 2>/dev/null)
check "S4 the replay never counts a shadow receipt as a decision (0 from receipts, 6 from history)" \
  "$(jq -e '.policies[0].from_receipts==0 and .policies[0].from_history==6' <<<"$RJ" >/dev/null; echo $?)" "$RJ"

echo "── M: the mutant ───────────────────────────────────────────────────────"
# Let the shadow write its pick into the gate's answer. The S1 predicate must
# see it; if it stays green the arm grades nothing.
MUT="$TMP/reflex_mutant.sh"
awk '{print} /^    actor="reflex" authority="heartbeat"$/ {
  print "  db \"UPDATE tasks SET need_answer=$(sqlq \"${choice:-none}\") WHERE id=$(jq -r .task_id <<<\"$g\");\" >/dev/null 2>&1"}' \
  "$SRC/lib/reflex.sh" >"$MUT"
check "M the mutant was applied (anchor line found)" "$(grep -q 'SET need_answer=' "$MUT"; echo $?)"
( source "$MUT"; s1_arm mutant ); MRC=$?
check "M with the pick written to the answer, the byte-identical arm goes RED" "$(( MRC != 0 ? 0 : 1 ))"
( s1_arm control ); CRC=$?
check "M control: the unmutated source stays green on the same arm" "$CRC"

echo
echo "passed $PASS, failed $FAIL"
(( FAIL == 0 ))
