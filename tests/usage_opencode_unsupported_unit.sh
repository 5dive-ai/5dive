#!/usr/bin/env bash
# DIVE-9127 — `5dive usage` read only claude and codex seats. Every other type
# was dropped before coverage was formed, so a box with an OpenCode seat got
# coverage.complete:true over a population that never included it, `usage
# <seat>` said "no usage … (or unsupported agent type)", and the budget check
# passed that seat as a confident zero ("ok").
#
# Arms, all on an isolated fixture (USAGE_HOME_ROOT + throwaway registry):
#   1. an opencode seat's opencode.db (OpenCode 1.x SQLite) is read: only
#      in-window messages count, step-finish parts are summed, reasoning is
#      output, and `usage <seat> --7d --json` shows exactly those tokens.
#   2. a pi seat (no collector) is named in coverage.unsupported, the read is
#      NOT complete, `usage <pi-seat>` prints the no-visibility line, and a
#      budget on it reads "unknown".
#   3. mutants, each must flip an arm: the budget check without the unsupported
#      seats, `complete` ignoring unsupported, message tokens instead of steps.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

SRC_DIR="${USAGE_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/usage-opencode.XXXXXX)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

NOW="$(date +%s)"
ROOT="$TMP/homes"
mkdir -p "$ROOT/agent-oc/.local/share/opencode" "$ROOT/agent-alpha" \
         "$ROOT/agent-legacy/.local/share/opencode/storage/message/ses_1"
printf '%s\n' '{"role":"assistant","tokens":{"input":5,"output":5}}' \
  > "$ROOT/agent-legacy/.local/share/opencode/storage/message/ses_1/msg_1.json"
printf '%s\n' '{"agents":{"alpha":{"type":"claude"},"oc":{"type":"opencode"},"pi1":{"type":"pi"}}}' > "$TMP/reg.json"
printf '%s\n' '{"agents":{"alpha":{"type":"claude"},"oc":{"type":"opencode"}}}' > "$TMP/reg-nopi.json"
printf '%s\n' '{"agents":{"legacy":{"type":"opencode"}}}' > "$TMP/reg-legacy.json"

# The OpenCode 1.15 tables this reader touches, as the shipped version creates
# them (message/part: id, session_id, time_created ms, data JSON).
NOW="$NOW" python3 - "$ROOT/agent-oc/.local/share/opencode/opencode.db" <<'PY'
import sqlite3, sys, json, os
now = int(os.environ["NOW"]) * 1000
con = sqlite3.connect(sys.argv[1])
con.execute("PRAGMA journal_mode=WAL")
con.execute("CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
con.execute("CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)")
def tok(i, o, r, cr, cw):
    return {"total": i+o+r+cr+cw, "input": i, "output": o, "reasoning": r, "cache": {"read": cr, "write": cw}}
def msg(mid, at, d):
    con.execute("INSERT INTO message VALUES (?,?,?,?,?)", (mid, "ses_a", at, at, json.dumps(d)))
def step(pid, mid, at, t):
    con.execute("INSERT INTO part VALUES (?,?,?,?,?,?)",
                (pid, mid, "ses_a", at, at, json.dumps({"type": "step-finish", "reason": "stop", "tokens": t, "cost": 0})))
d2, h1, d8 = now - 2*86400*1000, now - 3600*1000, now - 8*86400*1000
# A: two steps, 2 days ago; its own tokens are only the LAST step's.
msg("msg_a", d2, {"role": "assistant", "modelID": "big-pickle", "tokens": tok(50, 20, 0, 2000, 0), "time": {"created": d2}})
step("prt_a1", "msg_a", d2, tok(100, 10, 5, 1000, 20))
step("prt_a2", "msg_a", d2, tok(50, 20, 0, 2000, 0))
con.execute("INSERT INTO part VALUES ('prt_a3','msg_a','ses_a',?,?,?)", (d2, d2, json.dumps({"type": "text", "text": "step-finish"})))
# B: one hour ago, no step parts -> the message's own tokens.
msg("msg_b", h1, {"role": "assistant", "modelID": "other-model", "tokens": tok(7, 3, 1, 400, 2), "time": {"created": h1}})
# user turn in window: never counted.
msg("msg_u", h1, {"role": "user", "tokens": tok(9999, 0, 0, 0, 0), "time": {"created": h1}})
# C: 8 days ago, outside even the 7d window.
msg("msg_c", d8, {"role": "assistant", "modelID": "big-pickle", "tokens": tok(99999, 99999, 0, 0, 0), "time": {"created": d8}})
step("prt_c1", "msg_c", d8, tok(99999, 99999, 0, 0, 0))
con.commit()
PY

# --- the real verbs, with only side effects and the registry location stubbed --
# shellcheck disable=SC1091
source src/lib/error_codes.sh 2>/dev/null || { E_USAGE=2; E_GENERIC=1; E_PERMISSION=10; }
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export USAGE_HOME_ROOT="$ROOT" TASKS_DB="$TMP/none.db"

# probe <src> <registry> <cmd...> — source <src>, run one usage verb, print stdout+stderr.
probe() {
  local src="$1" reg="$2"; shift 2
  (
    JSON_MODE=0
    fail() { printf 'error: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
    # shellcheck disable=SC1090
    source "$src"
    ensure_state() { :; }; require_root() { :; }
    codex_model_default() { :; }
    usage_budget_load() { printf '%s\n' "${BUDGETS:-{\}}"; }
    usage_budget_save() { cat >/dev/null; }
    usage_resolve_owner_channel() { return 1; }
    _task_send_owner() { :; }
    REGISTRY="$reg"
    USAGE_BUDGET_STATE_FILE="$TMP/budget-state.json"
    [[ "$1" == "--json" ]] && { JSON_MODE=1; shift; }
    "$@"
  ) 2>&1
}

collect() { probe "$1" "$2" usage_collect "$((NOW - 604800))"; }

# --- 1. the opencode collector ------------------------------------------------
OUT="$(collect "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json")"
OC="$(jq -c '.agents[]|select(.name=="oc")' <<<"$OUT" 2>/dev/null)"
[[ "$(jq -r '.models["big-pickle"]|[.in,.out,.cc,.cr,.turns]|@csv' <<<"$OC")" == '150,35,20,3000,2' ]] \
  && ok_t "opencode: a message's step-finish parts are summed (reasoning is output), the 8-day-old one is not" \
  || bad_t "opencode step sum / window" "$OC"
[[ "$(jq -r '.models["other-model"]|[.in,.out,.cc,.cr,.turns]|@csv' <<<"$OC")" == '7,4,2,400,1' ]] \
  && ok_t "opencode: a message with no step parts counts its own tokens; user turns never count" \
  || bad_t "opencode message fallback" "$OC"
[[ "$(jq -r '[.total,.quota]|@csv' <<<"$OC")" == '218,3618' ]] \
  && ok_t "opencode: API-EQ and QUOTA totals follow the shared classes" || bad_t "opencode totals" "$OC"
[[ "$(jq -r '.untracked.oc.quota' <<<"$OUT")" == "3618" ]] \
  && ok_t "opencode: its turns land in 'unattributed', so tasks + unattributed = the seat's row" \
  || bad_t "opencode untracked" "$(jq -c '.untracked' <<<"$OUT")"

J7="$(probe "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json" --json cmd_usage oc --7d)"
[[ "$(jq -r '.data.usage.quota' <<<"$J7")" == "3618" ]] \
  && ok_t "usage oc --7d --json: exactly the in-window tokens" || bad_t "usage oc --7d" "$J7"
J1="$(probe "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json" --json cmd_usage oc)"
[[ "$(jq -r '.data.usage.models|keys|join(",")' <<<"$J1")" == "other-model" && "$(jq -r '.data.usage.quota' <<<"$J1")" == "413" ]] \
  && ok_t "usage oc (24h): the 2-day-old message falls out of the window" || bad_t "usage oc 24h" "$J1"

LEG="$(collect "$SRC_DIR/cmd_usage.sh" "$TMP/reg-legacy.json")"
{ [[ "$(jq -r '.coverage.unreadable[0].name' <<<"$LEG")" == "legacy" ]] && [[ "$(jq -r '.coverage.complete' <<<"$LEG")" != "true" ]]; } \
  && ok_t "opencode: a pre-SQLite storage tree with no database is reported unread, not zero" \
  || bad_t "legacy storage" "$(jq -c .coverage <<<"$LEG" 2>/dev/null || echo "$LEG")"

# --- 2. a type no collector reads -----------------------------------------------
[[ "$(jq -c '.coverage.unsupported' <<<"$OUT")" == '[{"name":"pi1","type":"pi"}]' ]] \
  && ok_t "coverage.unsupported names the pi seat and its type" || bad_t "unsupported" "$(jq -c .coverage <<<"$OUT")"
[[ "$(jq -r '.coverage.complete' <<<"$OUT")" != "true" && "$(jq -r '.coverage.agentsExpected' <<<"$OUT")" == "3" ]] \
  && ok_t "a read with an unsupported seat is not complete, and every registered seat is expected" \
  || bad_t "complete/expected" "$(jq -c .coverage <<<"$OUT")"
NOPI="$(collect "$SRC_DIR/cmd_usage.sh" "$TMP/reg-nopi.json")"
[[ "$(jq -r '.coverage.complete' <<<"$NOPI")" == "true" ]] \
  && ok_t "control: the same box without the pi seat reads complete" || bad_t "control complete" "$(jq -c .coverage <<<"$NOPI")"

PI="$(probe "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json" cmd_usage pi1; echo "rc=$?")"
grep -qF "5dive cannot read pi usage yet — no visibility, not zero" <<<"$PI" \
  && ok_t "usage pi1: prints the no-visibility line" || bad_t "usage pi1 line" "$PI"
! grep -qF "no usage for agent" <<<"$PI" && ! grep -q "rc=0" <<<"$PI" \
  && ok_t "usage pi1: fails, and never as 'no usage' (idle or typo)" || bad_t "usage pi1 rc" "$PI"

BOARD="$(probe "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json" cmd_usage)"
grep -qF "NO VISIBILITY — 5dive cannot read usage for pi1 (pi)" <<<"$BOARD" \
  && ok_t "board: one line names the unsupported seat" || bad_t "board line" "$BOARD"

export BUDGETS='{"pi1":{"soft":1000,"hard":5000,"hardStop":false,"notified":{},"stopped":false}}'
budget_state() { probe "$1" "$TMP/reg.json" cmd_usage_budget_check --dry-run >/dev/null; jq -r '.agents.pi1.state' "$TMP/budget-state.json"; }
BC="$(probe "$SRC_DIR/cmd_usage.sh" "$TMP/reg.json" cmd_usage_budget_check --dry-run)"
[[ "$(budget_state "$SRC_DIR/cmd_usage.sh")" == "unknown" ]] && grep -q "NOT checked.*pi1" <<<"$BC" \
  && ok_t "budget check: a budgeted pi seat is 'unknown' and named as NOT checked, never 'ok'" \
  || bad_t "budget pi1" "$BC $(cat "$TMP/budget-state.json")"

# --- 3. mutants: each must flip the arm it guards ---------------------------------
mutate() {  # mutate <name> <python replace old> <new>
  python3 - "$SRC_DIR/cmd_usage.sh" "$TMP/$1.sh" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[3]) == 1, "mutation anchor not found once: " + sys.argv[3]
open(sys.argv[2], "w").write(s.replace(sys.argv[3], sys.argv[4]))
PY
}
mutate m_budget '((.coverage.unreadable // []) + (.coverage.unsupported // []))[]' '(.coverage.unreadable // [])[]' \
  && [[ "$(budget_state "$TMP/m_budget.sh")" == "ok" ]] \
  && ok_t "MUTANT budget check without unsupported seats: pi1 reads 'ok' (the arm above goes red)" \
  || bad_t "budget mutant did not flip" "$(cat "$TMP/budget-state.json")"
mutate m_complete '"complete": not unreadable and not unsupported,' '"complete": not unreadable,' \
  && [[ "$(jq -r '.coverage.complete' <<<"$(collect "$TMP/m_complete.sh" "$TMP/reg.json")")" == "true" ]] \
  && ok_t "MUTANT complete ignoring unsupported: claims complete (the arm above goes red)" \
  || bad_t "complete mutant did not flip"
mutate m_steps 'for t in steps.get(mid) or [o.get("tokens") or {}]:' 'for t in [o.get("tokens") or {}]:' \
  && [[ "$(jq -r '.agents[]|select(.name=="oc")|.models["big-pickle"].in' <<<"$(collect "$TMP/m_steps.sh" "$TMP/reg.json")")" != "150" ]] \
  && ok_t "MUTANT message tokens instead of step sums: undercounts (the arm above goes red)" \
  || bad_t "steps mutant did not flip"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
