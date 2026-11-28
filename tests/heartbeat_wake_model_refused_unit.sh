#!/usr/bin/env bash
# TIER: core
#
# DIVE-9484 — a heartbeat wake that LANDED and was refused by the model is not a
# composer wedge.
#
# Measured on a box 2026-11-27 (02:26Z-07:03Z): a claude seat on a quota-walled
# token plan answered every wake with `API Error: Request rejected (429) · Your
# token-plan 1-month quota has been exhausted…`, Claude Code put the prompt back
# in the composer (`Resend your message to try again`), and the injector's
# claude branch read that as a wedge 50 times: `_wedge_mark`, "it needs 'sudo
# 5dive agent restart'", and the row re-woken into the same 429 every tick for
# 4.6 h. The seat's transcript shows every one of those prompts WAS submitted.
#
# What runs REAL: _hb_wake, _hb_send_line, _hb_landed_mark / _hb_landed_check /
# _hb_landed_needle / _hb_transcript_newest, _hb_pane_model_error, the wedge
# ledger, _hb_park_refused_wake, cmd_task_park on a scratch tasks.db, and the
# tick's refused-wake block (extracted verbatim from src/cmd_heartbeat.sh).
# Faked: tmux (sudo is a function: send-keys is recorded, Enter may append the
# payload to a scratch transcript), the composer reader (it ALWAYS reads unsent
# after both Enters — the pane misfire under test), the pane capture, and the
# unit start.
#
#   R arms — landed + the pane's last turn is an API Error: rc REFUSED, no wedge,
#            no restart text, the row parked on the error line
#   L arm  — landed, no model error: delivered (rc 0), no wedge
#   N arms — negative controls: nothing landed → today's wedge path, with or
#            without an API Error on the pane (a model error never masks a wedge)
#   M arm  — the base tree's claude branch (origin/main a6ff36e6) on the R input:
#            wedge mark + restart text, row not parked (the defect)
#
# Reserved-fake values only: seat 'seatx' does not exist; nothing live is touched.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/hb-wake-refused.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_agent_runtime.sh cmd_supervisor.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=1
mkdir -p "$TASKS_DIR"; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { if [[ "$3" == "$2" ]]; then ok_t "$1"; else bad_t "$1" "want=[$2] got=[$3]"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok_t "$1"; else bad_t "$1" "missing [$2] in: ${3:0:400}"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad_t "$1" "found [$2] in: ${3:0:400}"; else ok_t "$1"; fi; }

# ---- scratch transcript + fake tmux -------------------------------------------
ROOT="$TMP/projects"; PROJ="$ROOT/-home-seatx"; OLD="$PROJ/aaaa.jsonl"
_HB_TRANSCRIPT_ROOT="$ROOT"; _HB_LANDED_WAIT_SEC=0; _HB_LANDED_POLL_SEC=0
KEYS="$TMP/keys"; LOG="$TMP/log"; CLEARED="$TMP/cleared"
rec_user() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}'; }
reset_store() { rm -rf "$ROOT"; mkdir -p "$PROJ"; rec_user 'an earlier, unrelated turn' >"$OLD"; }
sudo() {
  while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
  if [[ "${1:-}" == tmux ]]; then
    shift
    if [[ "${1:-}" == send-keys ]]; then
      shift; while [[ $# -gt 0 ]]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
      printf '%s\n' "$*" >>"$KEYS"
      # Claude Code writes the submitted prompt as a user record (LAND=yes).
      [[ "$*" == Enter && "${LAND:-no}" == yes && ! -f "$TMP/landed" ]] && { rec_user "$NUDGE" >>"$OLD"; touch "$TMP/landed"; }
    fi
    return 0
  fi
  case "${1:-}" in systemctl) return 0 ;; esac
  "$@"
}
_hb_wake_start_unit_if_needed() { return 0; }
_agent_delivery_inbox()    { return 1; }
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { printf '4242'; }
_hb_composer_scrub()       { return 0; }
_hb_submit_settled()       { _HB_COMPOSER_UNSENT="[5dive] Sent by your operator's own runtime - act on what fo"; return 1; }
CLEAR_TAKES=1
_hb_composer_clear()       { echo 1 >>"$CLEARED"; (( CLEAR_TAKES )); }
_hb_log()                  { printf '%s\n' "$*" >>"$LOG"; }
PANE=""
_hb_pane_capture()         { printf '%s' "$PANE"; }
NUDGE="[5dive] Sent by your operator's own runtime - act on what follows: /goal DIVE-1595 — your only row this turn; read it with '5dive task show DIVE-1595'."
_hb_nudge_text()           { printf '%s' "$NUDGE"; }

# The live pane, 2026-11-27: the 429 under claude's ⎿ elbow, and Claude Code's
# own resend hint (it put the prompt back in the composer).
API_LINE='API Error: Request rejected (429) · Your token-plan 1-month quota has been exhausted. Please wait for the quota to reset.'
P_REFUSED=$'❯ [5dive] Sent by your operator\'s own runtime - act on what follows: /goal DIVE-1595\n  ⎿  '"$API_LINE"$'\n\n  Resend your message to try again\n❯ [5dive] Sent by your operator\'s own runtime - act on what fo\n'
P_PLAIN=$'❯ [5dive] Sent by your operator\'s own runtime - act on what fo\n  Opus 5 5h: 3%\n'

mk_todo() { db "INSERT INTO tasks (title, body, priority, assignee, created_by, kind, status)
                VALUES ('quota-walled row', '', 'high', 'seatx', 'main', 'standard', 'todo'); SELECT last_insert_rowid();"; }
row()    { db "SELECT status||'|'||CASE WHEN parked_at IS NULL THEN 'unparked' ELSE 'parked' END FROM tasks WHERE id=$1;"; }
reason() { db "SELECT COALESCE(park_reason,'') FROM tasks WHERE id=$1;"; }
wedged() { [[ -f "$(_wedge_dir)/seatx" ]] && echo yes || echo no; }

# The tick's refused-wake block, verbatim, in a one-pass loop so its `continue`
# is legal outside the tick.
BLOCK="$TMP/refused-block.sh"
awk '/if \(\( _wake_rc == _HB_WAKE_RC_REFUSED \)\); then/{f=1} f{print} f&&/^    fi$/{exit}' "$SRC/cmd_heartbeat.sh" >"$BLOCK"
[[ -s "$BLOCK" ]] && ok_t "T0 the tick's refused-wake block was found and extracted (arms below run shipped text)" \
                  || bad_t "T0 the tick's refused-wake block was found and extracted" ""
# wake <LAND> <PANE> -> sets WRC, TID; tick block runs on the result
wake() {
  : >"$KEYS"; : >"$LOG"; rm -f "$CLEARED" "$TMP/landed"; reset_store; _wedge_clear seatx
  LAND="$1"; PANE="$2"; TID=$(mk_todo); WRC=0
  _hb_wake seatx false "$TID" "DIVE-$TID" || WRC=$?
  local name=seatx task_id="$TID" task_ident="DIVE-$TID" _wake_rc="$WRC" sk_fail=0
  for _ in 1; do . "$BLOCK"; done
}

# ---- R: landed + model refused -------------------------------------------------
wake yes "$P_REFUSED"
is   "R1 landed + API Error on the pane: _hb_wake returns REFUSED ($_HB_WAKE_RC_REFUSED), not a plain failure" "$_HB_WAKE_RC_REFUSED" "$WRC"
is   "R2 ...no wedge mark is written for a seat whose composer took the line" no "$(wedged)"
hasnt "R3 ...no 'agent restart' remedy anywhere in the log" "agent restart" "$(cat "$LOG")"
hasnt "R3b ...and none in the failure reason" "agent restart" "$_HB_SEND_FAIL_REASON"
is   "R4 ...the todo row is PARKED" "blocked|parked" "$(row "$TID")"
has  "R5 ...with the API Error line as its reason" "$API_LINE" "$(reason "$TID")"
has  "R6 ...and the reason says it landed and is not a wedge" "the goal landed" "$(reason "$TID")"
is   "R7 ...wake is +1h when the line prints no reset" "1" "$(db "SELECT CASE WHEN wake_at BETWEEN datetime('now','+55 minutes') AND datetime('now','+65 minutes') THEN 1 ELSE 0 END FROM tasks WHERE id=$TID;")"
is   "R8 ...the restored draft is cleared so it cannot fire later" yes "$([[ -s "$CLEARED" ]] && echo yes || echo no)"
has  "R9 ...the tick line names the refusal and the park" "the goal LANDED but the model refused it" "$(cat "$LOG")"
# the teal-fox shape exactly: the clear did NOT take
CLEAR_TAKES=0; wake yes "$P_REFUSED"; CLEAR_TAKES=1
is   "R10 clear did not take (the measured case): still REFUSED, still no wedge" "$_HB_WAKE_RC_REFUSED|no" "$WRC|$(wedged)"
hasnt "R10b ...and still no 'agent restart' text" "agent restart" "$(cat "$LOG") $_HB_SEND_FAIL_REASON"
# a line that prints a reset parks until it
RESET_EP=$(( $(date +%s) + 5*3600 )); RESET_TXT=$(date -u -d "@$RESET_EP" '+%-I%P')
API_RESET="API Error: Request rejected (429) · You've hit your session limit · resets ${RESET_TXT} (UTC)"
P_RESET=$'❯ x\n  ⎿  '"$API_RESET"$'\n'
wake yes "$P_RESET"
w=$(db "SELECT wake_at FROM tasks WHERE id=$TID;")
is   "R11 a refusal that prints its reset parks until that reset, not +1h" "1" "$(db "SELECT CASE WHEN wake_at > datetime('now','+2 hours') THEN 1 ELSE 0 END FROM tasks WHERE id=$TID;")"
[[ -n "$w" ]] || bad_t "R11b wake_at is set" "empty"

# ---- L: landed, no model error = delivered ------------------------------------
wake yes "$P_PLAIN"
is   "L1 landed, no model error: delivered (rc 0) although the pane misread" 0 "$WRC"
is   "L2 ...no wedge mark" no "$(wedged)"
is   "L3 ...row left todo for the caller to claim (not parked)" "todo|unparked" "$(row "$TID")"
is   "L4 ...and the composer is C-u'd AFTER the last Enter (no remainder left to fire later)" yes \
     "$( (( $(grep -n -x 'C-u' "$KEYS" | tail -1 | cut -d: -f1) > $(grep -n -x 'Enter' "$KEYS" | tail -1 | cut -d: -f1) )) && echo yes || echo no)"
grep -qx 'Up' "$KEYS" && bad_t "L5 ...without the Up recall (the seat may be mid-turn)" "Up sent" \
                      || ok_t "L5 ...without the Up recall (the seat may be mid-turn)"

# ---- N: nothing landed = today's wedge, model error or not ---------------------
wake no "$P_PLAIN"
is   "N1 nothing landed: plain failure (rc 1)" 1 "$WRC"
is   "N2 ...the seat IS marked wedged" yes "$(wedged)"
is   "N3 ...row stays todo, unparked (re-woken next tick, as today)" "todo|unparked" "$(row "$TID")"
has  "N4 ...the failure reason names the receipt arm that missed" "transcript: transcript aaaa.jsonl gained no bytes since byte" "$_HB_WAKE_FAIL_REASON"
wake no "$P_REFUSED"
is   "N5 API Error on the pane but NO landed record: plain failure, not REFUSED" 1 "$WRC"
is   "N6 ...still marked wedged — a model error never masks a real wedge" yes "$(wedged)"
is   "N7 ...row not parked" "todo|unparked" "$(row "$TID")"
CLEAR_TAKES=0; wake no "$P_PLAIN"; CLEAR_TAKES=1
has  "N8 a real wedge whose clear did not take keeps the restart remedy" "agent restart" "$_HB_SEND_FAIL_REASON"

# ---- M: the base tree's claude branch on the R input ---------------------------
# origin/main a6ff36e6, _hb_send_line's claude arm after the 2nd Enter: straight
# to the wedge mark (carried verbatim minus comments; the /clear receipt arm is
# irrelevant to a /goal line).
_REAL_SL="$(declare -f _hb_send_line)"
# `declare -f` drops comments, so the carve keys on code: the 2nd reset of
# _HB_SEND_REFUSED_LINE opens the DIVE-9484 arm, the wedge's `local` closes it.
eval "$(declare -f _hb_send_line | awk '
  /_HB_SEND_REFUSED_LINE="";/ {n++; if (n == 2) skip=1}
  skip && /local _hb_wedged=/ {skip=0}
  !skip {print}')"
declare -f _hb_send_line | grep -q '_HB_SEND_REFUSED_LINE="\$_hb_rline"' \
  && bad_t "M0 the base-tree arm was carved out of the injector" "still present" \
  || ok_t "M0 the base-tree arm was carved out of the injector (the M arm grades the old branch)"
CLEAR_TAKES=0; wake yes "$P_REFUSED"; CLEAR_TAKES=1
is   "M1 base tree, landed + 429: plain failure (not REFUSED)" 1 "$WRC"
is   "M2 base tree: the seat is marked wedged (the defect)" yes "$(wedged)"
has  "M3 base tree: prescribes 'agent restart' (the defect)" "agent restart" "$_HB_SEND_FAIL_REASON"
is   "M4 base tree: the row is not parked, so it is re-woken into the same 429" "todo|unparked" "$(row "$TID")"
eval "$_REAL_SL"

printf 'heartbeat_wake_model_refused_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
