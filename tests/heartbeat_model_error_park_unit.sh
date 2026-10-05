#!/usr/bin/env bash
# DIVE-5624 — a row whose seat's model calls keep failing ends VISIBLY.
#
# THE ROW, measured on slate-clover 2026-10-05: every opencode call got the
# region relay's 500, the pane showed `500 Something went wrong on our side`, and
# box rows DIVE-1/DIVE-2 sat in_progress from 13:20Z with result, gate and park
# reason all null. Rule (b) of _hb_reclaim only ever requeued such a row to todo,
# the next nudge hit the same 500, and the row never said why.
#
#   A. the pane matcher: what reads as "the last turn ended on a model error"
#   B. rule (b): an idle seat on a model error PARKS the row with the error as
#      its reason; an idle seat without one still requeues exactly as before
#
# Every arm is pure or db-only: no tmux, no root, no network.
# Run: bash tests/heartbeat_model_error_park_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-model-error.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_supervisor.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ── boundaries ───────────────────────────────────────────────────────────────
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()      { cat "$REGISTRY"; }
registry_write()     { cat > "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
_hb_pane_fingerprint() { echo "fp"; }
cmd_send()           { :; }
cmd_task_escalate()  { :; }
_hb_send_line()      { return 0; }
_hb_claude_started() { echo ""; }    # rule (a) never fires
_hb_agent_idle()     { return 0; }   # a confident idle reading: rule (b) is in scope
PANE=""
_hb_pane_capture()   { printf '%s' "$PANE"; }

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
row()  { db "SELECT status||'|'||CASE WHEN parked_at IS NULL THEN 'unparked' ELSE 'parked' END||'|'||CASE WHEN wake_at IS NULL THEN 'nowake' ELSE 'wake' END FROM tasks WHERE id=$1;"; }
reason() { db "SELECT COALESCE(park_reason,'') FROM tasks WHERE id=$1;"; }
mk_idle_claimed() {
  local id
  id=$(addt --assignee=sysadmin -- "check the box")
  _hb_claim_task sysadmin "$id" >/dev/null 2>&1
  db "UPDATE tasks SET started_at=datetime('now','-40 minutes') WHERE id=${id};"
  printf '%s' "$id"
}

# ── A. the matcher ───────────────────────────────────────────────────────────
OC500=$'  ┃  check the box\n\n  ┃  500 Something went wrong on our side\n\n  ctrl+p commands'
m=$(_hb_pane_model_error "$OC500") \
  && [[ "$m" == "500 Something went wrong on our side" ]] \
  && ok_t "A1 the slate-clover pane (opencode, relay 500) reads as a model error, line trimmed" \
  || bad_t "A1 the slate-clover pane did not match" "got [$m]"
# The reason the cabinet shows is the error, not claude's bullet, in any locale.
m=$(LC_ALL=C _hb_pane_model_error $'some work\n● API Error: 529 overloaded') \
  && [[ "$m" == "API Error: 529 overloaded" ]] \
  && ok_t "A1b a claude ● error line is trimmed to the error itself" \
  || bad_t "A1b the claude gutter leaked into the reason" "got [$m]"

for p in "API Error: 529 {\"type\":\"overloaded_error\"}" \
         "AI_APICallError: Service Unavailable" \
         "Error: 429 Too Many Requests" \
         "ProviderModelNotFoundError: openrouter/vendor/x" \
         "  ┃  Error: 503 Service Unavailable" \
         "│ API Error: 500 {\"type\":\"api_error\"}" \
         "● API Error: 500 {\"type\":\"api_error\",\"message\":\"Internal server error\"}" \
         "  ⎿  API Error: Request timed out." \
         "● API Error: Request rejected (429) · rate limited" \
         "● API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}" \
         "  ⎿  API Error: Connection error." \
         "● API Error: Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary. Try again in a moment." \
         "  ⎿  API Error: Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary. Try again in a moment."; do
  _hb_pane_model_error $'some work\n'"$p" >/dev/null \
    && ok_t "A2 provider error reads as a model error: ${p:0:40}" \
    || bad_t "A2 provider error missed" "$p"
done

# Ordinary output mentioning a status number with no error word is not one, and
# neither is an error that scrolled up past the tail the seat stopped on.
_hb_pane_model_error $'served 500 requests in 3s\n> done, 2 files changed' >/dev/null \
  && bad_t "A3 a bare status number in ordinary output matched" "served 500 requests" \
  || ok_t "A3 a status number with no error word is not a model error"
# The seat's own TOOL output names HTTP errors all day on a fleet that works on
# HTTP APIs; a healthy idle seat with one of these in its tail must still
# requeue, not park under a false "model calls failing" (quinn, DIVE-5624 it1).
for p in "Fixed: /api/foo returned 500 Internal Server Error, now 200" \
         "HTTP/1.1 404 Not Found" \
         "test for 401 unauthorized path added" \
         "fixed the API error on the login route" \
         "404 page not found" \
         "500 Internal Server Error" \
         "Root cause of the API error: missing auth header" \
         '  console.error("API error:", err)' \
         "│ 500 error rate dropped to zero" \
         "  throw new ProviderError(\"upstream 500\")" \
         "if (e instanceof AI_APICallError) retry()" \
         "the relay said Something went wrong on our side, now fixed" \
         "503 Service Unavailable" \
         "- [x] handle 429 too many requests" \
         "Error: 404 Not Found" \
         "Error: 401 Unauthorized" \
         "  ✗ API error: expected 200 got 500" \
         "ApiError: something" \
         "  ⎿  API error handling added to the client" \
         "  ⎿  API Error: Request was aborted." \
         "● API Error: Request was aborted."; do
  _hb_pane_model_error $'some work\n'"$p"$'\n> done' >/dev/null \
    && bad_t "A3 tool output read as a model error" "$p" \
    || ok_t "A3 tool output is not a model error: ${p:0:40}"
done
OLD=$'500 Something went wrong on our side'; for i in $(seq 1 20); do OLD+=$'\n'"working line $i"; done
_hb_pane_model_error "$OLD" >/dev/null \
  && bad_t "A4 an error 20 lines above the seat's last output matched" "" \
  || ok_t "A4 an error that real work scrolled past is not the state the seat stopped in"
_hb_pane_model_error "" >/dev/null \
  && bad_t "A5 an empty pane read as a model error" "" \
  || ok_t "A5 no reading is no evidence: an empty pane is not a model error"

# ── B. rule (b) ──────────────────────────────────────────────────────────────
PANE="$OC500"
T1=$(mk_idle_claimed)
read -r RC1 _ < <(_hb_reclaim sysadmin 30)
R1=$(reason "$T1")
[[ "$(row "$T1")" == "blocked|parked|wake" ]] && (( ${RC1:-0} == 1 )) \
  && [[ "$R1" == *"model calls failing on sysadmin"* && "$R1" == *"500 Something went wrong on our side"* ]] \
  && ok_t "B1 idle on a model error -> PARKED with the error as the reason the cabinet shows, wake set" \
  || bad_t "B1 the row did not end visibly" "row=$(row "$T1") reclaimed=${RC1:-?} reason=[$R1]"

W1=$(db "SELECT CAST(ROUND((julianday(wake_at)-julianday('now'))*24) AS INTEGER) FROM tasks WHERE id=${T1};")
[[ "$W1" == "1" ]] && ok_t "B2 the park auto-wakes in an hour, so a transient outage costs one hour" \
  || bad_t "B2 wake is not +1h" "hours=$W1"

# CONTROL: the same idle stall with a clean pane still requeues, unchanged.
PANE=$'> all done\n  ctrl+p commands'
T2=$(mk_idle_claimed)
read -r RC2 _ < <(_hb_reclaim sysadmin 30)
[[ "$(row "$T2")" == "todo|unparked|nowake" ]] && (( ${RC2:-0} == 1 )) \
  && ok_t "B3 [control] idle with no model error -> plain requeue to todo, as before" \
  || bad_t "B3 [control] a clean idle stall changed shape" "row=$(row "$T2") reclaimed=${RC2:-?}"

# A park that cannot land (a live human gate on the row) falls back to the old
# requeue rather than leaving the claim where it was.
PANE="$OC500"
T3=$(mk_idle_claimed)
cmd_task_park() { return 1; }
read -r RC3 _ < <(_hb_reclaim sysadmin 30)
unset -f cmd_task_park; source "$SRC/task/loops.sh" 2>/dev/null || source "$SRC/cmd_task.sh"
[[ "$(row "$T3")" == "todo|unparked|nowake" ]] && (( ${RC3:-0} == 1 )) \
  && ok_t "B4 a park that does not land falls back to the requeue, never a held claim" \
  || bad_t "B4 a failed park stranded the claim" "row=$(row "$T3") reclaimed=${RC3:-?}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
