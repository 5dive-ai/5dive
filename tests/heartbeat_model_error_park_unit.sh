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
#   C. DIVE-5837: Claude Code's weekly wall is a wall to both matchers, and an
#      idle seat on it PARKS until the reset the wall printed
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
  local id seat="${1:-sysadmin}"
  id=$(addt --assignee="$seat" -- "check the box")
  _hb_claim_task "$seat" "$id" >/dev/null 2>&1
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
         "  ⎿  API Error: Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary. Try again in a moment." \
         "● API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited" \
         "  ⎿  API Error: Connection to the API was lost (ECONNRESET). This is usually temporary — try again." \
         "● API Error: Server error mid-response. The response above may be incomplete." \
         "● API Error: Connection lost before a response was produced. Try again." \
         "● API Error: The response stalled before a response was produced. Try again." \
         "● API Error: Please wait a moment and try again."; do
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
         "● API Error: Request was aborted." \
         "● API Error: The model has reached its context window limit." \
         "● API Error: 400 orphaned tool_result in conversation history" \
         "  ⎿  API Error: 400 {\"type\":\"invalid_request_error\"}" \
         "● API Error: Usage credits required for 1M context · run /extra-usage" \
         "● API Error: Could not load Bedrock credentials · token expired. Check your settings." \
         "● API Error: Claude Opus 5.5's safeguards flagged this message. Rephrase it." \
         "● API Error: Claude can't help with this. Start a new session to continue." \
         "● API Error: An image in the conversation could not be processed and was removed. Re-attach the file if you still need it." \
         "● API Error: Claude's response exceeded the 32000 output token maximum." \
         "● API Error: this model does not accept PDF documents, so a PDF was removed." \
         "● API Error: Effort 'max' isn't available with thinking turned off" \
         "  ⎿  API error: ECONNREFUSED 127.0.0.1:3001" \
         "  ⎿  api error: invalid token" \
         "● API error: the /login route returns 500 when the token is missing" \
         "  ⎿  API error: 500 Internal Server Error" \
         "  ⎿  api error: 503 from upstream" \
         "● API error: 429 handling now retries with backoff" \
         "  ⎿  Error: 500 Internal Server Error"; do
  _hb_pane_model_error $'some work\n'"$p"$'\n> done' >/dev/null \
    && bad_t "A3 tool output read as a model error" "$p" \
    || ok_t "A3 tool output is not a model error: ${p:0:40}"
done
# A claude tool result: only its FIRST line carries ⎿, every later line is plain
# indent, which looks exactly like opencode's bare lines. The seat type, not the
# gutter, decides: kind=claude never runs the opencode arm.
CL_CURL=$'● Bash(curl -si localhost:3001/health)\n  ⎿  HTTP/1.1 500 Internal Server Error\n     Error: 500 Internal Server Error\n● The endpoint still 500s; fixing next.\n> '
CL_TEST=$'  ⎿  > test\n     API error: 503 Service Unavailable from mock upstream\n● Done.'
for p in "$CL_CURL" "$CL_TEST"; do
  _hb_pane_model_error "$p" claude >/dev/null \
    && bad_t "A3 a claude seat's indented tool-result line read as a model error" "${p:0:60}" \
    || ok_t "A3 kind=claude: an indented tool-result line is not a model error: ${p:2:22}"
  _hb_pane_model_error "$p" opencode >/dev/null \
    && ok_t "A6 kind=opencode: the same bare 'Error: 5xx' line still parks an opencode seat" \
    || bad_t "A6 kind=opencode lost the bare-line arm" "${p:0:60}"
done
for p in "● API Error: Repeated 529 Overloaded errors" "  ⎿  API Error: Request timed out." \
         "● API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited" \
         '● API Error: 500 {"type":"error","error":{"type":"api_error"}}'; do
  _hb_pane_model_error $'x\n'"$p"$'\n> ' claude >/dev/null \
    && ok_t "A6 kind=claude still parks a claude transient: ${p:0:40}" \
    || bad_t "A6 kind=claude missed a claude transient" "$p"
done
for p in "  ⎿  API Error: Request was aborted." "  ⎿  API error: 500 Internal Server Error"; do
  _hb_pane_model_error $'x\n'"$p"$'\n> ' claude >/dev/null \
    && bad_t "A6 kind=claude parked a non-transient or lowercase line" "$p" \
    || ok_t "A6 kind=claude does not park: ${p:0:40}"
done
for p in "500 Something went wrong on our side" "  ┃  500 Something went wrong on our side" \
         "  ┃  AI_APICallError: Bad Request" "  ┃  Error: 503 Service Unavailable"; do
  _hb_pane_model_error $'x\n'"$p"$'\n  ctrl+p commands' opencode >/dev/null \
    && ok_t "A6 kind=opencode parks a provider error: ${p:0:40}" \
    || bad_t "A6 kind=opencode missed a provider error" "$p"
done
_hb_pane_model_error $'x\n● API Error: 529 overloaded\n> ' opencode >/dev/null \
  && bad_t "A6 kind=opencode ran claude's arm" "● API Error: 529 overloaded" \
  || ok_t "A6 kind=opencode never runs claude's 'API Error:' arm"

OLD=$'500 Something went wrong on our side'; for i in $(seq 1 20); do OLD+=$'\n'"working line $i"; done
_hb_pane_model_error "$OLD" >/dev/null \
  && bad_t "A4 an error 20 lines above the seat's last output matched" "" \
  || ok_t "A4 an error that real work scrolled past is not the state the seat stopped in"
_hb_pane_model_error "" >/dev/null \
  && bad_t "A5 an empty pane read as a model error" "" \
  || ok_t "A5 no reading is no evidence: an empty pane is not a model error"

# ── B. rule (b) ──────────────────────────────────────────────────────────────
# sysadmin is an opencode seat; the park site reads the type from the registry.
printf '{"agents":{"sysadmin":{"type":"opencode"},"maya":{}}}' >"$REGISTRY"
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

# A legacy claude seat has NO .type in the registry. The park site must default
# it to claude, or an empty kind would run the opencode arm on its tool output.
PANE="$CL_CURL"
T5=$(mk_idle_claimed maya)
read -r RC5 _ < <(_hb_reclaim maya 30)
[[ "$(row "$T5")" == "todo|unparked|nowake" ]] && (( ${RC5:-0} == 1 )) \
  && ok_t "B5 a claude seat with an EMPTY registry .type skips the opencode arm: its 'Error: 500' tool line requeues, no park" \
  || bad_t "B5 an untyped claude seat was parked on its own tool output" "row=$(row "$T5") reason=[$(reason "$T5")]"
PANE=$'x\n● API Error: Repeated 529 Overloaded errors\n> '
T6=$(mk_idle_claimed maya)
read -r RC6 _ < <(_hb_reclaim maya 30)
[[ "$(row "$T6")" == "blocked|parked|wake" && "$(reason "$T6")" == *"API Error: Repeated 529"* ]] \
  && ok_t "B6 the same untyped claude seat still parks on a real claude transient" \
  || bad_t "B6 an untyped claude seat missed its own model error" "row=$(row "$T6") reason=[$(reason "$T6")]"

# ── C. DIVE-5837: the weekly wall ───────────────────────────────────────────
# The banner pair, verbatim from a customer box on 0.81.0 (2026-10-07/08): every
# turn ended on these two lines in ~0.5s, and neither matcher called it a wall.
WK1="You've hit your weekly limit · resets Oct 9, 4pm (UTC)"
WK2="/upgrade to increase your usage limit."
WKPANE=$'> /goal DIVE-697\n  ⎿  '"$WK1"$'\n     '"$WK2"$'\n\n> '
grep -qiE "$_SUP_QUOTA_PAT" <<<"$WK1" \
  && ok_t "C1 the supervisor/probe pattern reads the weekly banner as a wall" \
  || bad_t "C1 _SUP_QUOTA_PAT missed the weekly banner" "$WK1"
[[ "$(printf '%s\n' "$WK1" | _hb_quota_probe_classify)" == walled ]] \
  && ok_t "C2 the quota-probe classifies the refused probe as walled, not COULD-NOT-DETERMINE" \
  || bad_t "C2 the probe classifier missed the banner" "$(printf '%s\n' "$WK1" | _hb_quota_probe_classify)"
_hb_pane_is_usage_limit "$WKPANE" \
  && ok_t "C3 the pane matcher reads the banner pair as a wall (header + action)" \
  || bad_t "C3 _hb_pane_is_usage_limit missed the banner pair" "$WKPANE"
_hb_pane_is_usage_limit "$WK1" && _hb_pane_is_usage_limit "x"$'\n'"You've hit your weekly limit"$'\n'"$WK2" \
  && ok_t "C3b either action line alone completes the header: the dated reset, and the /upgrade line" \
  || bad_t "C3b one action line of the pair was not enough"
[[ "$(_hb_wall_class "$WKPANE")" == rate-limit ]] \
  && ok_t "C4 the weekly wall classifies rate-limit (a rolling window), not undetermined" \
  || bad_t "C4 wall class" "$(_hb_wall_class "$WKPANE")"
# The session banner kept matching (it is what DIVE-4206 widened for).
grep -qiE "$_SUP_QUOTA_PAT" <<<"You've hit your session limit · resets 4am (UTC)" \
  && grep -qiE "$_SUP_QUOTA_PAT" <<<"You've hit your weekly spend limit" \
  && ok_t "C5 [control] the session and weekly-SPEND banners still match" \
  || bad_t "C5 the widening lost an existing banner"
# Negative controls from the report: prose that mentions a weekly limit is not a wall.
for p in "the weekly limit is 100 requests" "we hit your daily standup limit" "I hit your weekly report limit"; do
  if grep -qiE "$_SUP_QUOTA_PAT" <<<"$p" || _hb_pane_is_usage_limit "$p"$'\n'"$WK2"$'\n'"resets Oct 9, 4pm"; then
    bad_t "C6 non-wall prose matched a wall matcher" "$p"
  else ok_t "C6 [neg] not a wall: '$p'"; fi
done
_hb_pane_is_usage_limit "You've used 43% of your weekly limit · resets Oct 9, 4pm" \
  && bad_t "C6b the usage meter read as a wall" "" \
  || ok_t "C6b [neg] the usage meter ('used 43% of your weekly limit · resets …') is not a wall"
# The dated reset is read as a DATE at a fixed clock (2026-10-08 02:16Z), so the
# park keys to Oct 9 16:00 UTC and not to "today, 4pm".
NOW=$(date -u -d '2026-10-08 02:16' +%s); WANT=$(date -u -d '2026-10-09 16:00' +%s)
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "$WK1" "$NOW")"
[[ "$DL" == live && "$EP" == "$WANT" ]] \
  && ok_t "C7 'resets Oct 9, 4pm (UTC)' parses to 2026-10-09 16:00Z, live at the report's clock" \
  || bad_t "C7 the dated reset did not parse" "state=$DL epoch=$EP want=$WANT"
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "$WK1" "$(date -u -d '2026-10-10 00:00' +%s)")"
[[ "$DL" == lapsed && "$EP" == "$WANT" ]] && ok_t "C7b the same reset read after it passed is lapsed" \
  || bad_t "C7b lapsed" "state=$DL epoch=$EP"
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "resets Jan 2, 9am (UTC)" "$(date -u -d '2026-12-30 12:00' +%s)")"
[[ "$DL" == live && "$EP" == "$(date -u -d '2027-01-02 09:00' +%s)" ]] \
  && ok_t "C7c across New Year the nearest year wins (Jan 2 read on Dec 30 is next year)" \
  || bad_t "C7c year rollover" "state=$DL epoch=$EP"
# The bound (quinn, DIVE-5837 it1): no weekly wall resets more than 7 days out,
# so a dated reset further ahead than 8 days is unknown, never a months-long park.
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "You've hit your weekly limit · resets Mar 1, 9am (UTC)" "$NOW")"
[[ "$DL" == unknown && -z "$EP" ]] \
  && ok_t "C7d 'resets Mar 1, 9am (UTC)' read on 2026-10-08 is unknown, not live until 2027-03-01" \
  || bad_t "C7d a far-dated reset was read as this wall's reset" "state=$DL epoch=$EP"
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "resets Oct 16, 2am (UTC)" "$NOW")"
[[ "$DL" == live && "$EP" == "$(date -u -d '2026-10-16 02:00' +%s)" ]] \
  && ok_t "C7e [control] a reset just under 8 days out (Oct 16, 2am) is still live" \
  || bad_t "C7e the bound cut a real 7-day reset" "state=$DL epoch=$EP"
IFS=$'\x1f' read -r DL EP <<<"$(_sup_quota_deadline "resets Oct 17, 4am (UTC)" "$NOW")"
[[ "$DL" == unknown ]] \
  && ok_t "C7f just over 8 days out (Oct 17, 4am) is unknown" \
  || bad_t "C7f the bound let 8d+ through" "state=$DL epoch=$EP"

# Rule (b) on the wall. maya is a claude seat; the reset is two days out from the
# REAL clock, because the park arm reads the clock itself.
FUT_D=$(date -u -d '+2 days' '+%b %-d'); FUT_W=$(date -u -d '+2 days' '+%Y-%m-%d 16:00')
PANE=$'> /goal DIVE-697\n  ⎿  You\'ve hit your weekly limit · resets '"$FUT_D"$', 4pm (UTC)\n     '"$WK2"$'\n\n> '
T7=$(mk_idle_claimed maya)
read -r RC7 _ < <(_hb_reclaim maya 30)
R7=$(reason "$T7"); W7=$(db "SELECT wake_at FROM tasks WHERE id=${T7};")
[[ "$(row "$T7")" == "blocked|parked|wake" && "$W7" == "$FUT_W:00" ]] && (( ${RC7:-0} == 1 )) \
  && [[ "$R7" == *"usage limit on maya"* && "$R7" == *"hit your weekly limit · resets $FUT_D, 4pm (UTC)"* ]] \
  && ok_t "C8 idle on the weekly wall -> PARKED until the reset it printed, banner as the reason" \
  || bad_t "C8 the walled seat's row was not parked to its reset" "row=$(row "$T7") wake=[$W7] want=[$FUT_W:00] reason=[$R7]"
N7=$(db "SELECT COUNT(*) FROM tasks WHERE id=${T7} AND COALESCE(body,'') LIKE '%decided not to start%';")
[[ "$N7" == 0 ]] && ok_t "C8b nothing about a decision is written to the row" || bad_t "C8b nudge note on the row" "$N7"
# No reset printed: header + /upgrade only -> +1h.
PANE=$'x\n  ⎿  You\'ve hit your weekly limit\n     '"$WK2"$'\n> '
T8=$(mk_idle_claimed maya)
read -r RC8 _ < <(_hb_reclaim maya 30)
W8=$(db "SELECT CAST(ROUND((julianday(wake_at)-julianday('now'))*24) AS INTEGER) FROM tasks WHERE id=${T8};")
[[ "$(row "$T8")" == "blocked|parked|wake" && "$W8" == 1 ]] \
  && ok_t "C9 a wall that printed no reset parks +1h" \
  || bad_t "C9 no-reset wall" "row=$(row "$T8") hours=$W8"
# A far-dated reset (quinn's probe pane, and this PR's own fixture as a grader
# sees it in a diff) parks +1h, never months.
for far in "You've hit your weekly limit · resets Mar 1, 9am (UTC)" "+WK1=\"You've hit your weekly limit · resets Mar 1, 4pm (UTC)\""; do
  PANE=$'x\n  ⎿  '"$far"$'\n     '"$WK2"$'\n> '
  T11=$(mk_idle_claimed maya)
  read -r RC11 _ < <(_hb_reclaim maya 30)
  W11=$(db "SELECT CAST(ROUND((julianday(wake_at)-julianday('now'))*24) AS INTEGER) FROM tasks WHERE id=${T11};")
  [[ "$(row "$T11")" == "blocked|parked|wake" && "$W11" == 1 ]] \
    && ok_t "C9b a far-dated reset parks +1h, not months: '$far'" \
    || bad_t "C9b a far-dated reset parked past +1h" "row=$(row "$T11") hours=$W11 pane=[$far]"
done
# A wall whose reset already passed is scrollback, not a wall in force: requeue.
PAST_D=$(date -u -d '-2 days' '+%b %-d')
PANE=$'x\n  ⎿  You\'ve hit your weekly limit · resets '"$PAST_D"$', 4pm (UTC)\n     '"$WK2"$'\n> '
T9=$(mk_idle_claimed maya)
read -r RC9 _ < <(_hb_reclaim maya 30)
[[ "$(row "$T9")" == "todo|unparked|nowake" ]] \
  && ok_t "C10 [control] a wall whose printed reset has passed is not parked: plain requeue" \
  || bad_t "C10 a lapsed wall parked the row" "row=$(row "$T9") reason=[$(reason "$T9")]"
# A wall that scrolled up behind more than 15 lines of real work is not the state now.
PANE="You've hit your weekly limit · resets ${FUT_D}, 4pm (UTC)"$'\n'"$WK2"$'\n'"$(seq 1 20 | sed 's/^/  work line /')"$'\n> '
T10=$(mk_idle_claimed maya)
read -r RC10 _ < <(_hb_reclaim maya 30)
[[ "$(row "$T10")" == "todo|unparked|nowake" ]] \
  && ok_t "C11 [control] a wall scrolled past by real work is not read: plain requeue" \
  || bad_t "C11 a scrolled-up wall parked the row" "row=$(row "$T10")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
