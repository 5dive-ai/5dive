#!/usr/bin/env bash
# DIVE-5448 — a secret gate on a fresh box (divine-owl, 2026-10-03): lodar asked
# olivia (admin seat) for a secret box, she filed the gate correctly, and
#   1. the alert sat 2.5 min behind a LEAD REVIEW no lead could act on — a tier-2
#      secret is the owner's value, answerable only by a human;
#   2. it went out with NO link, though the seat can mint one, and nothing in
#      gate-notify.log said why: every no-link return in _task_mint_drop_link was
#      a silent `return 0`.
#
# A arms: a tier-2 secret gate is not held; the controls (tier-2 manual, tier-1
#   self-minted secret) keep their windows, so the skip is that narrow.
# B arms: every mint outcome writes one `gate-drop-link` line — ok, error with
#   the reason (sudo refusal text, the CLI's own error, a non-https url, a
#   no_new_privs shell), `none` for a seat that cannot mint (and still runs no
#   sudo) — and the delivery parser never counts those lines as a send.
#
# Run: bash tests/secret_gate_now_and_loud_mint_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP=$(mktemp -d /tmp/secret-gate-now.XXXXXX)

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
export FIVEDIVE_NO_HUMAN_SEND=1
LOG="$TMP/gate-notify.log"; FIVEDIVE_GATE_NOTIFY_LOG="$LOG"
# Load the lazily-dispatched notify module before stubbing anything inside it.
declare -F _task_gate_undo_window_secs >/dev/null 2>&1 || _task_gate_undo_window_secs DIVE-0 >/dev/null 2>&1
unset _5DIVE_GATE_UNDO_WINDOW_SECS TASK_GATE_ROUTE_URGENT

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check()  { if eval "$2"; then ok_t "$1"; else fail_t "$1" "${3:-}"; fi; }

mkgate() { # <ident> <need_type> <tier>
  db "INSERT INTO tasks (ident,title,status,priority,assignee,created_by,need_type,tier,need_asked_at,secret_key,connector)
      VALUES ($(sqlq "$1"),'fixture','blocked','high','olivia','olivia',$(sqlq "$2"),$3,datetime('now'),'TEST_SECRET','test-secret');"
}

# ---------------------------------------------------------------- A: no hold --
mkgate DIVE-9501 secret 2
mkgate DIVE-9502 manual 2
mkgate DIVE-9503 secret 1
s1=$(_task_gate_undo_window_secs DIVE-9501)
s2=$(_task_gate_undo_window_secs DIVE-9502)
s3=$(_task_gate_undo_window_secs DIVE-9503)
check 'A1 a tier-2 secret gate pings now (window 0), not after a lead review' '[[ "$s1" == 0 ]]' "got ${s1}s"
check 'A2 control: a tier-2 manual gate still holds for the lead review' \
  '[[ "$s2" == "$_GATE_LEAD_REVIEW_HOLD_SECS" && "$s2" -gt 0 ]]' "got ${s2}s"
check 'A3 control: a tier-1 (self-minted) secret keeps its DIVE-4154 window' '[[ "$s3" -gt 0 ]]' "got ${s3}s"
check 'A4 no renderer shows a tier-2 secret gate as "with your lead"' \
  '[[ -z "$(_task_gate_in_lead_hold DIVE-9501)" && -n "$(_task_gate_in_lead_hold DIVE-9502)" ]]' \
  "secret='$(_task_gate_in_lead_hold DIVE-9501)' manual='$(_task_gate_in_lead_hold DIVE-9502)'"

# ------------------------------------------------------- B: the mint is loud --
SUDO_LOG="$TMP/sudo.log"; : > "$SUDO_LOG"
SUDO_RC=0; SUDO_OUT=''; SUDO_ERR=''
sudo() { echo "$*" >> "$SUDO_LOG"; [[ -n "$SUDO_ERR" ]] && printf '%s\n' "$SUDO_ERR" >&2; printf '%s' "$SUDO_OUT"; return "$SUDO_RC"; }
id() { [[ "${1:-}" == -un ]] && { printf 'agent-olivia\n'; return 0; }; command id "$@"; }
SEAT_TIER=admin
agent_tier() { [[ "$1" == olivia ]] && printf '%s\n' "$SEAT_TIER" || printf 'unknown:unregistered\n'; }
lastline() { tail -n1 "$LOG" 2>/dev/null; }
mint() { : > "$SUDO_LOG"; _task_mint_drop_link DIVE-9501 2>/dev/null; }

SUDO_OUT='{"ok":true,"data":{"url":"https://secrets.box.example.com/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCd","ttl_minutes":30}}'
got=$(mint)
check 'B1 an admin seat mints: url|ttl, and one ok line' \
  '[[ "$got" == https://secrets.box.example.com/*"|30" && "$(lastline)" == *"gate-drop-link result=ok tasks=DIVE-9501"* ]]' \
  "got=$got log=$(lastline)"

SUDO_OUT=''; SUDO_RC=1; SUDO_ERR='sudo: a password is required'
got=$(mint)
check 'B2 a refused sudo writes an error line that QUOTES the refusal' \
  '[[ -z "$got" && "$(lastline)" == *"result=error tasks=DIVE-9501"* && "$(lastline)" == *"a\\ password\\ is\\ required"* ]]' \
  "got=$got log=$(lastline)"

SUDO_RC=4; SUDO_ERR=''
SUDO_OUT='{"ok":false,"error":{"code":"E_NOT_INSTALLED","message":"this box has no https name an owner can reach"}}'
got=$(mint)
check "B3 secret link's own error message is what the line says" \
  '[[ -z "$got" && "$(lastline)" == *"result=error"* && "$(lastline)" == *"no\\ https\\ name"* ]]' \
  "got=$got log=$(lastline)"

SUDO_RC=0; SUDO_OUT='{"ok":true,"data":{"url":"http://secrets.box.example.com/x","ttl_minutes":30}}'
got=$(mint)
check 'B4 a non-https link is never put in the alert, and says so' \
  '[[ -z "$got" && "$(lastline)" == *"result=error"* && "$(lastline)" == *"not\\ an\\ https\\ link"* ]]' \
  "got=$got log=$(lastline)"

for SEAT_TIER in standard sandboxed unknown:unregistered; do
  got=$(mint)
  check "B5 a ${SEAT_TIER} seat mints nothing, runs NO sudo, and logs none (not error)" \
    '[[ -z "$got" && ! -s "$SUDO_LOG" && "$(lastline)" == *"result=none tasks=DIVE-9501"* ]]' \
    "got=$got sudo=$(cat "$SUDO_LOG") log=$(lastline)"
done
SEAT_TIER=admin

# A no_new_privs shell (a sandboxed agent's Bash) cannot run sudo at all. Real
# no_new_privs via setpriv, in a child that re-enters this file at one arm.
if [[ "${1:-}" == --nnp-arm ]]; then
  SUDO_OUT='{"ok":true,"data":{"url":"https://secrets.box.example.com/x","ttl_minutes":30}}'
  got=$(mint)
  [[ -z "$got" && ! -s "$SUDO_LOG" && "$(lastline)" == *"result=error"* && "$(lastline)" == *no_new_privs* ]] && exit 0
  echo "got=$got sudo=$(cat "$SUDO_LOG") log=$(lastline)"; exit 1
fi
if command -v setpriv >/dev/null 2>&1 && setpriv --no-new-privs true 2>/dev/null; then
  setpriv --no-new-privs bash "$0" --nnp-arm >"$TMP/nnp.out" 2>&1; nrc=$?
  out=$(grep -v '^HARNESS-RC\|^ok \|^FAIL\|^   \|grading tree' "$TMP/nnp.out")
  check 'B6 a no_new_privs shell says so instead of spending a refused sudo' '[[ "$nrc" == 0 ]]' "$out"
else
  ok_t 'B6 SKIP: setpriv unavailable here (the arm needs real no_new_privs)'
fi

dl=$(_task_gate_deliveries DIVE-9501)
check 'B7 the delivery parser never reads a gate-drop-link line as a send' '[[ -z "$dl" ]]' "deliveries: $dl"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
