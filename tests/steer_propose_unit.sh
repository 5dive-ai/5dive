#!/usr/bin/env bash
# STEER-11 isolated unit harness for the new-work generator (cmd_steer.sh +
# _hb_steer_sweep / _hb_steer_apply_sweep in cmd_heartbeat.sh). Covers olivia's
# four acceptance assertions (STEER-5 §4) plus the guardrails:
#   1. drained board (0 open standard tasks) + real signal -> after N ticks, >=1
#      well-formed, source-grounded candidate filed in review state, capped.
#   2. idempotent — a second tick in the same drain episode does NOT re-fire.
#   3. negative — a *dammed* (open-but-blocked) queue does NOT trigger.
#   4. candidate routed to the lead in review state (blocked+gate), NOT
#      auto-dispatched to a builder; on lead-approve it flips to dispatchable.
#   + per-cycle cap, de-dup by source, and the outstanding cap.
# Same isolation contract as the other harnesses: source src/ directly, throwaway
# tasks.db (STATE_DIR -> tmp), cmd_send stubbed (no tmux/network).
# Run: bash tests/steer_propose_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/steer-propose.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh \
         cmd_steer.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# --- stubs: never touch tmux/network -----------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() { local tgt="$1"; shift; local msg=""; for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done; printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"; }
audit_log() { return 0; }

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

reset_all() { db "DELETE FROM tasks; DELETE FROM projects; DELETE FROM task_prefs;"; : >"$SEND_LOG"; }
mkproj() { # <key> <prefix> <goal> <lead>
  JSON_MODE=1 cmd_project_add "$1" --prefix="$2" --name="$1 project" --goal="$3" --lead-agent="$4" >/dev/null 2>&1
}
steer_count() { db "SELECT COUNT(*) FROM tasks WHERE ask LIKE '[steer]%';" 2>/dev/null; }
n_from() { printf '%s' "$1" | jq -r '.data.proposed // 0' 2>/dev/null; }

# =============================================================================
# 1 + 4: drained active project with a goal -> propose files a review-state
#        candidate assigned to the lead, source-grounded, NOT dispatchable.
# =============================================================================
reset_all
mkproj frog FROG "ship the frog feature" main
out=$(STEER_MAX_PROPOSE=3 cmd_steer_propose --from=steer-generator 2>/dev/null)
n=$(n_from "$out")
[[ "$n" == "1" ]] && ok_t "drained project mints exactly 1 candidate" || bad_t "drained project mints 1 candidate" "proposed=$n out=$out"

row=$(db "SELECT status||'|'||COALESCE(assignee,'')||'|'||COALESCE(need_type,'')||'|'||COALESCE(created_by,'') FROM tasks WHERE ask LIKE '[steer]%' LIMIT 1;")
IFS='|' read -r st asg ntype cby <<<"$row"
[[ "$st" == "blocked" ]]        && ok_t "candidate is in review state (blocked), not dispatchable" || bad_t "candidate blocked" "status=$st"
[[ "$asg" == "main" ]]          && ok_t "candidate routed to project lead (main)"                  || bad_t "candidate routed to lead" "assignee=$asg"
[[ "$ntype" == "decision" ]]    && ok_t "candidate carries an approve|revise decision gate"        || bad_t "candidate has decision gate" "need_type=$ntype"
[[ "$cby" == "steer-generator" ]] && ok_t "candidate stamped created_by=steer-generator (audit)"   || bad_t "created_by audit stamp" "created_by=$cby"
srcok=$(db "SELECT COUNT(*) FROM tasks WHERE ask LIKE '[steer]%' AND instr(COALESCE(body,''),'steer-source: project:frog')>0;")
[[ "$srcok" == "1" ]] && ok_t "candidate is source-grounded (steer-source: project:frog)" || bad_t "candidate source-grounded" "match=$srcok"

# de-dup: a second propose over the same signal mints nothing new.
out2=$(cmd_steer_propose --from=steer-generator 2>/dev/null); n2=$(n_from "$out2")
[[ "$n2" == "0" && "$(steer_count)" == "1" ]] && ok_t "de-dup: same source not re-proposed" || bad_t "de-dup by source" "n2=$n2 total=$(steer_count)"

# =============================================================================
# 4b: lead approves -> apply sweep flips it to a dispatchable todo for the builder
# =============================================================================
cid=$(db "SELECT id FROM tasks WHERE ask LIKE '[steer]%' LIMIT 1;")
# lead re-targets the candidate at a builder before approving (intended-assignee)
db "UPDATE tasks SET body=replace(body,'steer-intended-assignee: main','steer-intended-assignee: dev') WHERE id=${cid};" 2>/dev/null
# simulate the lead answering the gate 'approve'
db "UPDATE tasks SET need_answer='approve', need_answered_at=datetime('now') WHERE id=${cid};"
_hb_steer_apply_sweep
arow=$(db "SELECT status||'|'||COALESCE(assignee,'')||'|'||COALESCE(need_type,'') FROM tasks WHERE id=${cid};")
IFS='|' read -r ast aasg antype <<<"$arow"
[[ "$ast" == "todo" && -z "$antype" ]] && ok_t "approved candidate flips to dispatchable todo (gate cleared)" || bad_t "approve->dispatchable" "row=$arow"
[[ "$aasg" == "dev" ]] && ok_t "approved candidate reassigned to intended builder (dev)" || bad_t "approve reassign" "assignee=$aasg"

# =============================================================================
# 2 + trigger debounce/idempotency via _hb_steer_sweep
# =============================================================================
reset_all
mkproj frog FROG "ship the frog feature" main
db "DELETE FROM tasks;"   # fully drained board (project has a goal, no open work)
export STEER_IDLE_TICKS=2
_hb_steer_sweep   # tick 1 -> debounce, no fire
[[ "$(steer_count)" == "0" ]] && ok_t "debounce: no fire before STEER_IDLE_TICKS ticks" || bad_t "debounce holds" "count=$(steer_count)"
_hb_steer_sweep   # tick 2 -> fire
c_after_fire=$(steer_count)
[[ "$c_after_fire" -ge 1 ]] && ok_t "generator fires after N idle ticks" || bad_t "fires after N ticks" "count=$c_after_fire"
_hb_steer_sweep   # tick 3 -> board now non-empty (candidate blocked) -> reset, no re-fire
[[ "$(steer_count)" == "$c_after_fire" ]] && ok_t "idempotent: no re-fire in the same drain episode" || bad_t "idempotent episode" "before=$c_after_fire after=$(steer_count)"
unset STEER_IDLE_TICKS

# =============================================================================
# 3: NEGATIVE — a dammed (open-but-blocked) queue does NOT trigger generation
# =============================================================================
reset_all
mkproj frog FROG "ship the frog feature" main
db "INSERT INTO tasks (title,status,kind,assignee,project_key,created_by) VALUES ('stuck','blocked','standard','dev','frog','main');"
export STEER_IDLE_TICKS=1
_hb_steer_sweep
_hb_steer_sweep
[[ "$(steer_count)" == "0" ]] && ok_t "dammed queue (open-but-blocked) does NOT trigger generation" || bad_t "dammed negative" "count=$(steer_count)"
unset STEER_IDLE_TICKS

# =============================================================================
# per-cycle cap + outstanding cap
# =============================================================================
reset_all
mkproj a AAA "goal a" main; mkproj b BBB "goal b" main; mkproj c CCC "goal c" main; mkproj d DDD "goal d" main
out=$(STEER_MAX_PROPOSE=2 STEER_MAX_OUTSTANDING=10 cmd_steer_propose --from=steer-generator 2>/dev/null)
[[ "$(n_from "$out")" == "2" ]] && ok_t "per-cycle cap: files at most STEER_MAX_PROPOSE" || bad_t "per-cycle cap" "proposed=$(n_from "$out")"

reset_all
mkproj a AAA "goal a" main; mkproj b BBB "goal b" main; mkproj c CCC "goal c" main
out=$(STEER_MAX_PROPOSE=3 STEER_MAX_OUTSTANDING=1 cmd_steer_propose --from=steer-generator 2>/dev/null)
[[ "$(n_from "$out")" == "1" ]] && ok_t "outstanding cap: stops at STEER_MAX_OUTSTANDING" || bad_t "outstanding cap" "proposed=$(n_from "$out")"

# =============================================================================
echo "-----"
echo "steer_propose: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
