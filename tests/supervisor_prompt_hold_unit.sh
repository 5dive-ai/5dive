#!/usr/bin/env bash
# DIVE-5844 — a tool-permission confirm that clears itself inside its decline
# window must never page a person.
#
# 2026-10-08 03:43Z: `[FLEET-HEALTH blocked-on-prompt] agent 'main' is UP and
# REACHABLE…` reached lodar's phone for a confirm claude's own harness timed out
# about a minute later (supervisor-tick.log:14597, "[seen this tick — the
# decline waits 10m]"). DIVE-4536 had the class, the audited row AND the page
# all fire on first sight; only the keystroke waited for the dwell.
#
# Graded END TO END through cmd_supervisor_tick against a real scratch store —
# the snapshot, the act rung and the delivery leg are the only stubs, so the
# dedup query, the audited rows and the summary/heartbeat counts are the
# production code reading the production schema. The delivery stub records
# every page that would have left the box; a page is a line in $PAGES.
#
#   (a) seen on one tick, gone on the next -> audited row, no page, 1 held
#   (b) still standing past the window   -> exactly one page (and still one
#       on the tick after — the window dedup)
#   (c) a mutant that pages on first sight fails (a), run through the SAME arm
#
# Run: bash tests/supervisor_prompt_hold_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/sup-prompt-hold-unit.XXXXXX)"

PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi; }
fld() { local rest="${1#*"$2"=}"; printf '%s' "${rest%%|*}"; }

# The incident excerpt, verbatim from the log line that paged.
DETAIL_FRESH='pane is sitting on a tool-permission confirm: Do you want to proceed? [seen this tick — the decline waits 10m]'
DETAIL_DWELT='pane is sitting on a tool-permission confirm: Do you want to proceed? [standing 10m+ with no transcript progress — declinable (Esc)]'

# One scenario = a sequence of ticks against ONE store. Each tick is a mark:
#   fresh  — the confirm, inside its window      (promptMark=confirm-fresh)
#   dwelt  — the confirm, past its window        (promptMark=confirm)
#   gone   — the seat is healthy again
# <src> is the supervisor source to load (the real one, or a mutant).
cat >"$TMP/scenario.sh" <<'SCEOF'
set -uo pipefail
SRC_SUP="$1" ACTIONS="$2"; shift 2
W=$(mktemp -d)
export STATE_DIR="$W/state" TASKS_DIR="$W/tasks" TASKS_DB="$W/tasks/tasks.db"
mkdir -p "$STATE_DIR" "$TASKS_DIR"
JSON_MODE=0
cd "$REPO"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh task/routing.sh; do
  . "src/$f"
done
. "$SRC_SUP"
_SUP_ENABLED_FLAG="$W/enabled"; : >"$_SUP_ENABLED_FLAG"
_SUP_ACTIONS_FLAG="$W/actions"; [[ "$ACTIONS" == on ]] && : >"$_SUP_ACTIONS_FLAG"
_SUP_QUOTA_ALERTS_FLAG="$W/quota-alerts"
PAGES="$W/pages"; : >"$PAGES"
require_root()          { :; }
_sup_cli_check()        { :; }
registry_read()         { printf '{"agents":{}}'; }
_sup_act_exec()         { return 0; }            # the Escape reaches the pane
_sup_confirm_note_row() { :; }
_sup_alert_deliver()    { printf '%s\t%s\n' "$2" "$4" >>"$PAGES"; }
( tasks_db_init ) >/dev/null 2>&1 || true
MARK=""
_sup_snapshot() {
  case "$MARK" in
    fresh) jq -nc --arg d "$DETAIL_FRESH" '[{name:"main",type:"claude",classification:"blocked-on-prompt",cause:"dangerous-confirm",detail:$d,signals:{promptMark:"confirm-fresh",promptRecommended:false}}]' ;;
    dwelt) jq -nc --arg d "$DETAIL_DWELT" '[{name:"main",type:"claude",classification:"blocked-on-prompt",cause:"dangerous-confirm",detail:$d,signals:{promptMark:"confirm",promptRecommended:false}}]' ;;
    *)     printf '%s' '[{"name":"main","type":"claude","classification":"healthy","cause":"","detail":"","signals":{}}]' ;;
  esac
}
last=""
for MARK in "$@"; do last=$(cmd_supervisor_tick 2>/dev/null); done
printf 'PAGES=%s|HELDROWS=%s|ALERTROWS=%s|HB=%s|SUMMARY=%s|MSG=%s' \
  "$(wc -l <"$PAGES" | tr -d ' ')" \
  "$(db "SELECT COUNT(*) FROM supervisor_events WHERE agent='main' AND event='alert-held' AND classification='blocked-on-prompt';")" \
  "$(db "SELECT COUNT(*) FROM supervisor_events WHERE agent='main' AND event='alert';")" \
  "$(db "SELECT COALESCE(SUM(json_extract(signals,'\$.promptPagesHeld')),'ABSENT') FROM supervisor_events WHERE event='heartbeat';")" \
  "$last" "$(head -1 "$PAGES" | cut -f2 | tr '|' '/')"
rm -rf "$W"
SCEOF
run() { DETAIL_FRESH="$DETAIL_FRESH" DETAIL_DWELT="$DETAIL_DWELT" REPO="$PWD" bash "$TMP/scenario.sh" "$@"; }

# The three arms are FUNCTIONS of the source, so a mutant is graded by the very
# assertions it claims to break, not by a shadow check of its own.
arm_a() {  # <src> <label> -> prints the arm's pass/fail counts on its own
  local out; out=$(run "$1" on fresh gone)
  t "(a)$2 transient confirm: no page"                           "0" "$(fld "$out" PAGES)"
  t "(a)$2 transient confirm: the audited held row is written"   "1" "$(fld "$out" HELDROWS)"
  t "(a)$2 transient confirm: no event='alert' row (it did not page)" "0" "$(fld "$out" ALERTROWS)"
  t "(a)$2 transient confirm: one held page on the heartbeat"    "1" "$(fld "$out" HB)"
}

arm_a src/cmd_supervisor.sh ""
# The summary line of the HOLDING tick says so — a tick that ends with the seat
# healthy has nothing to say, so read the first tick on its own.
out=$(run src/cmd_supervisor.sh on fresh)
t "(a) the holding tick's summary counts the held page" "yes" \
  "$([[ "$(fld "$out" SUMMARY)" == *"1 prompt page(s) held"* ]] && echo yes || echo no)"

# (b) sticky, actions ON: held, then declined AND paged once; a further dwelt
# tick inside the alert window does not page again.
out=$(run src/cmd_supervisor.sh on fresh dwelt dwelt)
t "(b) sticky confirm, actions on: exactly one page"            "1" "$(fld "$out" PAGES)"
t "(b) ...audited as one event='alert' row"                     "1" "$(fld "$out" ALERTROWS)"
t "(b) ...the page says the Escape landed"                      "yes" \
  "$([[ "$(fld "$out" MSG)" == *"DECLINED (Escape), the seat is free again"* ]] && echo yes || echo no)"
t "(b) ...and does not claim the seat is still frozen"          "no" \
  "$([[ "$(fld "$out" MSG)" == *"WAITING ON A KEYPRESS"* ]] && echo yes || echo no)"
# (b) sticky, actions OFF: nothing presses Escape, the page still fires once.
out=$(run src/cmd_supervisor.sh off fresh dwelt dwelt)
t "(b) sticky confirm, actions off: exactly one page"           "1" "$(fld "$out" PAGES)"
t "(b) ...naming why nobody pressed Escape"                     "yes" \
  "$([[ "$(fld "$out" MSG)" == *"automatic actions are disabled"* ]] && echo yes || echo no)"
# A confirm first seen already past its window (no fresh tick at all) still pages.
out=$(run src/cmd_supervisor.sh on dwelt)
t "(b) a confirm first seen past its window pages once"         "1" "$(fld "$out" PAGES)"

# (c) MUTANT: the pre-fix policy — page on first sight. Built by disarming the
# hold branch only, then run through arm (a) verbatim; it must go red there.
sed 's/"\$prompt_mark_s" == "confirm-fresh" \]\]; then/"$prompt_mark_s" == "__never__" ]]; then/' \
  src/cmd_supervisor.sh >"$TMP/mutant_first_sight.sh"
t "(c) mutant applied (exactly one hold branch disarmed)" "1" \
  "$(diff src/cmd_supervisor.sh "$TMP/mutant_first_sight.sh" | grep -c '^>')"
P0=$PASS F0=$FAIL
arm_a "$TMP/mutant_first_sight.sh" " [MUTANT]" >/dev/null
mut_fail=$((FAIL - F0)); PASS=$P0; FAIL=$F0
t "(c) the page-on-first-sight mutant FAILS arm (a)" "yes" "$( (( mut_fail > 0 )) && echo yes || echo no)"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]]
