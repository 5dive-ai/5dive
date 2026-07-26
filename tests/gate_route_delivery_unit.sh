#!/usr/bin/env bash
# DIVE-2011 isolated unit harness for LEAD-ROUTE DELIVERY TELEMETRY.
#
# What this pins, and why each assertion exists rather than being obvious:
#
# The lead-route branch of cmd_task_need used to dispatch its handoff as
#   ( 5dive agent send "$reviewer" "$msg" --from="$actor" >/dev/null 2>&1 & ) || true
# and then `return` BEFORE task_need_notify was ever called. So (a) the DIVE-1968
# delivery assertion never ran for a routed gate, (b) no gate-delivery row was
# written at all — routed gates were invisible to the only dataset anyone reads to
# judge the gate rail — and (c) "routed to X" printed whether or not X was
# reachable, because the send's exit status was structurally unobservable
# (backgrounded, both streams to /dev/null, `|| true` outside the subshell).
#
# Every case below is written against a FAILING send as well as a succeeding one,
# because the whole defect class is that only the success shape was ever exercised.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR, and FIVEDIVE_GATE_NOTIFY_LOG pointed at a temp file so delivery rows
# are captured HERE and the prod telemetry fence (DIVE-1968) is never crossed.
# Run: bash tests/gate_route_delivery_unit.sh (no root, no network).
#
# ENV NOTE (DIVE-2007): a guard or resolver that reads the ambient identity can
# behave differently on a CI runner ($USER=runner) than on a dev box ($USER=agent-*)
# and the difference is invisible from the box you develop on. Repro the runner
# shape before pushing:
#   env -u SUDO_USER -u SUDO_UID USER=runner bash tests/gate_route_delivery_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-route-delivery-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-2054: "task need lead-route" is now routed through _task_store_audit_log
# (STORE IDENTITY fence, DIVE-2010) — declare this fixture store as prod so the
# audit-row assertions below keep exercising the real path.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

# Capture delivery rows locally. _task_gate_delivery_log honours this path even
# when the prod-store fence withholds the fleet log + audit rows, which is exactly
# the contract this harness needs: real rows, zero prod writes.
NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# The HUMAN deliverer is stubbed one layer BELOW task_need_notify, because the
# wrapper is now the shared entry point for both rails and stubbing it would
# bypass the very dispatch under test.
HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
# Capture audit rows: the routed branch's audit result used to be a hardcoded "ok"
# — a GREEN row for a send whose status was discarded (olivia's second DIVE-1968
# finding). An absent row is a gap; a false green is worse.
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
audit_reset() { : >"$AUDIT_LOG_FILE"; }
audit_route() { grep 'task need lead-route' "$AUDIT_LOG_FILE" 2>/dev/null; }

# `5dive` as a shell function: shadows the real binary, is inherited by the
# detached child that performs the send, keeps `command -v 5dive` true, and lets a
# case choose the send's EXIT STATUS — the input the old code could not observe.
SEND_RC=0
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() {
  if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then
    printf '%s\n' "${3:-}" >>"$ROUTE_FILE"
    if (( SEND_RC != 0 )); then printf 'agent-%s: tmux session not found\n' "${3:-}" >&2; fi
    return "$SEND_RC"
  fi
  return 0
}

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"
_task_pref_set gate_builder_routing on

seed()  { db "INSERT INTO tasks(ident,title,status,created_by) VALUES('$1','t','todo','main');"; }
# Rows are written by the DETACHED child, so poll briefly instead of reading once.
rows_for() { local i; for i in $(seq 1 60); do grep -c "tasks=$1 " "$NOTIFY_LOG" 2>/dev/null | grep -qv '^0$' && break; sleep 0.1; done
             grep "tasks=$1 " "$NOTIFY_LOG" 2>/dev/null; }
reset_log() { : >"$NOTIFY_LOG"; : >"$ROUTE_FILE"; : >"$AUDIT_LOG_FILE"; }

# --- 1. a routed gate now records a delivery verdict at all -------------------
# The headline defect: zero rows for the entire routed population.
reset_log; seed DIVE-7; HUMAN_PINGED=0; SEND_RC=0; JSON_MODE=0
OUT7=$(cmd_task_need DIVE-7 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=dev 2>"$TMP/e7")
R7=$(rows_for DIVE-7)
[[ -n "$R7" ]] && ok_t "routed gate writes a gate-delivery row (was ZERO rows for the whole rail)" \
  || bad_t "routed gate writes a delivery row" "log: $(cat "$NOTIFY_LOG")"
grep -q 'result=ok' <<<"$R7" && ok_t "confirmed routed send records result=ok" || bad_t "routed ok row" "row: $R7"
grep -q 'chat=agent:main' <<<"$R7" && ok_t "row names the RAIL (chat=agent:main), so routed rows are separable from Bot API rows" \
  || bad_t "row carries chat=agent:main" "row: $R7"
[[ "$(grep -c . <<<"$R7")" == "1" ]] && ok_t "exactly ONE row per routed gate (child logs, parent credits — no double count)" \
  || bad_t "one row per routed gate" "rows: $R7"
[[ "$HUMAN_PINGED" == "0" ]] && ok_t "routed gate still does NOT ping the paired human (DIVE-1145 intact)" \
  || bad_t "routed gate suppresses human ping" "HUMAN_PINGED=$HUMAN_PINGED"
grep -q 'routed to main' <<<"$OUT7" && ok_t "delivered send still prints the plain 'routed to main' line" \
  || bad_t "delivered prints routed line" "out: $OUT7"
grep -qi 'NOT DELIVERED\|not yet confirmed' <<<"$OUT7" && bad_t "delivered send prints no undelivered caveat" "out: $OUT7" \
  || ok_t "delivered send prints NO undelivered caveat"
grep -q 'delivery=delivered' <<<"$(audit_route)" && ok_t "audit row carries delivery=delivered" \
  || bad_t "audit delivery=delivered" "audit: $(audit_route)"

# --- 2. a FAILING send is no longer reported as a successful route ------------
# This is the case that could not previously exist: the stub returns non-zero and
# the old code printed "routed to main" regardless.
reset_log; seed DIVE-8; HUMAN_PINGED=0; SEND_RC=7; JSON_MODE=0
OUT8=$(cmd_task_need DIVE-8 --type=decision --ask="ship A or B?" --options="A|B" --recommend="A" --from=dev 2>"$TMP/e8")
R8=$(rows_for DIVE-8)
grep -q 'result=error' <<<"$R8" && ok_t "failed routed send records result=error" || bad_t "failed send error row" "row: $R8"
grep -q 'rc=7' <<<"$R8" && ok_t "error row carries the send's ACTUAL exit status (rc=7)" || bad_t "error row names rc" "row: $R8"
grep -q 'HANDOFF NOT DELIVERED' <<<"$OUT8" && ok_t "failed send does NOT print a bare 'routed to X' — the ok line says NOT DELIVERED" \
  || bad_t "failed send marks the ok line" "out: $OUT8"
grep -q "task answer DIVE-8" <<<"$OUT8" && ok_t "failed send names the answering surface that needs no channel" \
  || bad_t "failed send names task answer" "out: $OUT8"
grep -q 'FAILED' "$TMP/e8" && ok_t "failed send warns LOUDLY on stderr" || bad_t "failed send warns" "stderr: $(cat "$TMP/e8")"
_A8=$(audit_route)
grep -q 'delivery=failed' <<<"$_A8" && ok_t "audit row carries delivery=failed" || bad_t "audit delivery=failed" "audit: $_A8"
grep -qE 'lead-route error' <<<"$_A8" && ok_t "audit result is error, NOT the old hardcoded green (olivia's 1968 finding)" \
  || bad_t "audit result not a false green" "audit: $_A8"
[[ "$(grep -c 'task need' "$AUDIT_LOG_FILE")" == "1" ]] && ok_t "ONE audit row per routed gate (no second row for the same send)" \
  || bad_t "one audit row" "audit: $(cat "$AUDIT_LOG_FILE")"
# The gate itself must still stand: a failed PING is not a failed FILING. Losing a
# gate is worse than delaying one (DIVE-1927).
[[ "$(db "SELECT status FROM tasks WHERE ident='DIVE-8';")" == "blocked" \
   && "$(db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='DIVE-8';")" == "open" ]] \
  && ok_t "failed send leaves the gate FILED + open (routing recorded, ping missed)" \
  || bad_t "failed send keeps the gate" "status=$(db "SELECT status FROM tasks WHERE ident='DIVE-8';")"
[[ "$(db "SELECT COALESCE(routed_reviewer,'') FROM tasks WHERE ident='DIVE-8';")" == "main" ]] \
  && ok_t "failed send still persists routed_reviewer (the lead can clear it)" || bad_t "routed_reviewer persists" ""
# gate_pinged_at NULL is what makes the heartbeat T1 re-nag pick it up (<=15 min).
[[ -z "$(db "SELECT COALESCE(gate_pinged_at,'') FROM tasks WHERE ident='DIVE-8';")" ]] \
  && ok_t "failed send leaves gate_pinged_at NULL, so the re-nag ladder escalates it" || bad_t "gate_pinged_at NULL" ""

# --- 3. the JSON envelope tells a machine reader the same thing ---------------
reset_log; seed DIVE-9; SEND_RC=7; JSON_MODE=1
J9=$(cmd_task_need DIVE-9 --type=decision --ask="ship?" --from=dev 2>/dev/null)
[[ "$(jq -r '.data.delivery' <<<"$J9" 2>/dev/null)" == "failed" ]] && ok_t "JSON: delivery=failed on a failed routed send" \
  || bad_t "JSON delivery=failed" "json: $J9"
[[ "$(jq -r '.data.notified' <<<"$J9" 2>/dev/null)" == "false" ]] && ok_t "JSON: notified=false on a failed routed send" \
  || bad_t "JSON notified=false" "json: $J9"
reset_log; seed DIVE-10; SEND_RC=0
J10=$(cmd_task_need DIVE-10 --type=decision --ask="ship?" --from=dev 2>/dev/null)
[[ "$(jq -r '.data.delivery' <<<"$J10" 2>/dev/null)" == "delivered" && "$(jq -r '.data.notified' <<<"$J10" 2>/dev/null)" == "true" ]] \
  && ok_t "JSON: delivery=delivered + notified=true on a confirmed routed send" || bad_t "JSON delivered" "json: $J10"
JSON_MODE=0

# --- 4. no CLI on PATH = a gate that pinged nobody, recorded as such ----------
# Previously guarded by `if command -v 5dive`, whose else-branch sent nothing and
# said nothing. Driven at the deliverer rather than through cmd_task_need: emptying
# PATH to hide `5dive` also hides sqlite3/jq/date, so the full command could not
# run at all and the case would assert on a crash instead of on the branch.
reset_log
_saved_5dive=$(declare -f 5dive)
_NC_RC=0
# PATH must be a real-but-empty DIRECTORY, not "": an empty PATH entry means the
# CWD, and the repo root holds a built `./5dive`, so `command -v 5dive` still
# succeeded and this case silently exercised a different branch. `hash -r` drops
# any cached lookup for the same reason.
mkdir -p "$TMP/emptybin"
( unset -f 5dive; PATH="$TMP/emptybin"; hash -r; TASK_GATE_ROUTE_TO=main TASK_GATE_ROUTE_ROLE="lead review" \
    _task_need_route_deliver DIVE-11 decision "ship?" "" "" ) >"$TMP/o11" 2>"$TMP/e11" || _NC_RC=$?
eval "$_saved_5dive"
R11=$(grep 'tasks=DIVE-11 ' "$NOTIFY_LOG")
grep -q 'result=error' <<<"$R11" && ok_t "no 5dive on PATH: records result=error instead of silently sending nothing" \
  || bad_t "no-CLI error row" "row: $R11 log: $(cat "$NOTIFY_LOG")"
grep -q 'attempted' <<<"$R11" && ok_t "no-CLI row says NOT ATTEMPTED, not 'send failed' (the two are different findings)" \
  || bad_t "no-CLI row wording" "row: $R11"
[[ "$_NC_RC" == "3" ]] && ok_t "no-CLI returns rc 3 (filed, NOT notified) so the caller marks its ok line" \
  || bad_t "no-CLI rc 3" "rc=$_NC_RC"
[[ -z "$(grep -c . "$ROUTE_FILE" 2>/dev/null | grep -v '^0$')" ]] && ok_t "no-CLI attempts no send at all" \
  || bad_t "no-CLI sends nothing" "route: $(cat "$ROUTE_FILE")"

# --- 5. the DIVE-1968 assertion now fences the routed rail too ----------------
# The invariant, not the implementation: if a routed deliverer ever exits with no
# row (the shape every future edit to that branch can reintroduce), the wrapper
# synthesises the missing verdict and downgrades rc 0 to 3.
reset_log
_real_route=$(declare -f _task_need_route_deliver)
_task_need_route_deliver() { TASK_GATE_ROUTE_STATE="delivered"; return 0; }   # silent: no row
seed DIVE-12
TASK_GATE_ROUTE_TO=main TASK_GATE_ROUTE_ROLE="lead review" \
  task_need_notify DIVE-12 decision "ship?" "" "" >/dev/null 2>"$TMP/e12"; ARC=$?
[[ "$ARC" == "3" ]] && ok_t "assertion covers the routed rail: a silent deliverer is downgraded to rc 3" \
  || bad_t "routed silent deliverer → rc 3" "rc=$ARC"
grep -q 'result=error' <<<"$(grep 'tasks=DIVE-12' "$NOTIFY_LOG")" \
  && ok_t "assertion synthesises the missing routed verdict as an error row" \
  || bad_t "synthesised error row" "log: $(cat "$NOTIFY_LOG")"
grep -q 'UNVERIFIABLE' "$TMP/e12" && ok_t "assertion warns UNVERIFIABLE at the filer for a routed gate" \
  || bad_t "routed UNVERIFIABLE warn" "stderr: $(cat "$TMP/e12")"
eval "$_real_route"

# --- 6. dispatch is scoped: the human rail is untouched ----------------------
# TASK_GATE_ROUTE_TO is set only as a per-call prefix, so nothing else (the root
# re-nag sweep, the privileged re-send, a plain human gate) can fall into the
# routed deliverer.
reset_log; seed DIVE-13; HUMAN_PINGED=0; SEND_RC=0
cmd_task_need DIVE-13 --type=decision --ask="ship?" --from=main >/dev/null 2>&1   # lead files → human
[[ "$HUMAN_PINGED" == "1" ]] && ok_t "an UNROUTED gate still runs the human deliverer (dispatch is per-call)" \
  || bad_t "unrouted → human deliverer" "HUMAN_PINGED=$HUMAN_PINGED"
# The stubbed human deliverer writes no row of its own, so the DIVE-1968 assertion
# synthesises one — pre-existing behaviour, and the proof the human rail took the
# HUMAN path: the row carries no `chat=agent:` rail marker and no send rc.
_H13=$(grep 'tasks=DIVE-13 ' "$NOTIFY_LOG")
[[ -n "$_H13" ]] && ! grep -q 'chat=agent:' <<<"$_H13" \
  && ok_t "the human rail's row is NOT a routed row (no chat=agent: marker)" \
  || bad_t "human rail row is not routed" "row: $_H13"
[[ -z "${TASK_GATE_ROUTE_TO:-}" ]] && ok_t "TASK_GATE_ROUTE_TO does not leak past the routed call" \
  || bad_t "route global scoped" "TASK_GATE_ROUTE_TO=${TASK_GATE_ROUTE_TO:-}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
