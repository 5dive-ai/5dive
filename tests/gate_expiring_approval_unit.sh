#!/usr/bin/env bash
# TIER: core — ~4s measured (agent-dev seat, worktree cli-4833-dev, 2026-09-22).
#   No root, no network, no tmux.
#
# DIVE-4833 — AN APPROVAL ACTION EXPIRES, AND ALL FOUR OUTCOMES ARE AUDITED.
#
# THE DEFECT, IN THE PRODUCT'S OWN WORDS. `cmd_task_answer` carries a DIVE-2228
# note reading "Telegram inline buttons on already-delivered messages never
# expire". A button sitting in someone's chat history from three weeks ago still
# lands a live answer today, and nothing in the row could tell that tap from one
# made in response to the question. For a `decision` that is untidy. For an
# `approval` it means a risky action gets authorised by a tap on a question
# nobody remembers being asked — with full provenance recorded for it.
#
# THE FOUR OUTCOMES THE ROW NAMES, and each is a SEPARATE audit event so that one
# `audit_log` grep answers "what was authorised here" without parsing a value:
#   ALLOW            a live offer answered yes          -> gate.approval-allow
#   DENY             a live offer answered no           -> gate.approval-deny
#   TIMEOUT          the clock ran out, nobody answered -> gate.approval-timeout
#   STALE RESPONSE   a person taps AFTER expiry         -> gate.approval-stale-response
#
# TIMEOUT AND STALE-RESPONSE ARE NOT THE SAME EVENT, and collapsing them is the
# mistake this file exists to prevent. Timeout is the clock; it RESOLVES the gate,
# fail-closed, exactly once. A stale response is a human action that changes
# nothing — and it is the record an operator needs when they ask "I approved that,
# why did nothing happen?". Answering that question with silence is the reason
# both rows exist.
#
# WHY THE ENFORCEMENT ARM IS THE LOAD-BEARING ONE. Two surfaces answer gates: the
# Telegram listener and the dashboard. Both reach the store through `task answer`,
# so the deadline is enforced THERE and neither surface is trusted to have withheld
# its button. Arm C3 is what proves that: it answers as the dashboard does, with no
# Telegram anywhere, and the refusal still fires.
#
# Run: bash tests/gate_expiring_approval_unit.sh   (no root, no network)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive4833.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh \
         cmd_heartbeat.sh; do
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1; mkdir -p "$TASKS_DIR"; set +e
tasks_db_init
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"   # so the audit fence ALLOWS (DIVE-2010)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

AUDIT="$TMP/audit.calls"; : >"$AUDIT"
audit_log() { printf '%s\n' "$*" >>"$AUDIT"; }
task_need_notify() { return 0; }     # precondition, never an observable
_gate_proof_enforced() { return 1; } # the evidence floor is a different row's subject
# THE CALLER IS A HUMAN, and that is what this stub says. `cmd_task_answer` refuses
# an approval from an AGENT uid (correctly — the refusal names Telegram and the
# dashboard as the ways a human answers). Both of those arrive as a NON-agent uid:
# the dashboard answers on-box as `claude`, a Telegram tap is relayed under sudo as
# root. `_gate_uid_to_agent` returning empty IS that population, so this models the
# only callers this row is about rather than bypassing a rule.
_gate_uid_to_agent() { printf ''; }
addt()  { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
reset() { : >"$AUDIT"; unset _TASK_STORE_AUDIT_FENCED; }
ev()    { grep -c "gate.approval-$1" "$AUDIT" 2>/dev/null | head -1; }
col()   { db "SELECT COALESCE($2,'<NULL>') FROM tasks WHERE id=${1};"; }

# mkgate <expires-in-or-empty> -> id. Built by the REAL `task need` verb, never a
# raw UPDATE: the whole question is what the product does, and a hand-written row
# would prove the SQL agrees with itself.
mkgate() {
  local exp="${1:-}" id
  id=$(addt --assignee=dev -- "fixture approval gate")
  local -a a=( "$id" --type=approval --ask="ship the thing?" --recommend="approve" --tier=1 )
  [[ -n "$exp" ]] && a+=( "--expires-in=$exp" )
  ( cmd_task_need "${a[@]}" ) >/dev/null 2>&1
  printf '%s' "$id"
}
# Age a gate past its deadline WITHOUT touching any other column — the clock is
# the only thing arranged, so what the arms below observe is the product's
# reaction to time and not to a fixture that also changed the gate.
age_past() { db "UPDATE tasks SET need_expires_at=datetime('now','-1 minute') WHERE id=${1};"; }

echo "── A. the offer carries a deadline, and a bad one is refused at filing ──"
A1=$(mkgate "+2h")
[[ "$(col "$A1" need_expires_at)" != "<NULL>" ]] \
  && ok_t "A1 --expires-in stores a deadline on the gate" || bad_t "A1 no deadline stored" "got $(col "$A1" need_expires_at)"
[[ "$(db "SELECT CASE WHEN need_expires_at > datetime('now') THEN 1 ELSE 0 END FROM tasks WHERE id=${A1};")" == "1" ]] \
  && ok_t "A1b ...in the future, resolved through the store's own clock" || bad_t "A1b deadline is not in the future"
A2=$(mkgate "")
[[ "$(col "$A2" need_expires_at)" == "<NULL>" ]] \
  && ok_t "A2 CONTROL: a gate filed WITHOUT --expires-in has no deadline — every pre-DIVE-4833 gate is unchanged" || bad_t "A2 a deadline appeared uninvited"
# A2b/A2c — THE MOST DANGEROUS REGRESSION THIS FILE GUARDS, and it is not the one
# the name suggests. Every gate on every live board has NULL here after the
# migration. A predicate that read NULL as "past" — `COALESCE(need_expires_at,
# '0000-01-01') <= now` is the one-line way to write it — would expire the ENTIRE
# INBOX on deploy: every approval unanswerable, every one auto-resolved as
# not-approved, all at once and silently. Measured: that exact mutant reds only
# ONE arm without these two, which is not enough weight for the blast radius.
_hb_gate_expire_sweep >/dev/null 2>&1
[[ "$(col "$A2" need_answered_at)" == "<NULL>" ]] \
  && ok_t "A2b ...and the sweep does NOT touch it — NULL means no deadline, never an expired one" \
  || bad_t "A2b the sweep resolved a gate that has no deadline" "every gate on every existing board would be auto-denied on deploy"
( cmd_task_answer "$A2" --value=approved --human ) >/dev/null 2>&1
[[ "$(col "$A2" need_answer)" == "approved" ]] \
  && ok_t "A2c ...and it is still ANSWERABLE — a deadline nobody asked for must not be enforced against them" \
  || bad_t "A2c a gate with no deadline could not be answered" "answer=$(col "$A2" need_answer)"
A3=$(addt --assignee=dev -- "already-expired filing")
_o=$( cmd_task_need "$A3" --type=approval --ask="x?" --recommend="approve" --tier=1 --expires-in="2020-01-01 00:00" 2>&1 )
[[ "$(db "SELECT COALESCE(need_type,'<NULL>') FROM tasks WHERE id=${A3};")" == "<NULL>" ]] \
  && ok_t "A3 a deadline already in the PAST is refused at filing — a gate nobody could ever answer is not filed" \
  || bad_t "A3 an already-expired gate was filed" "${_o:0:160}"

echo "── B. ALLOW and DENY — a live offer, answered ──"
reset; B1=$(mkgate "+2h")
( cmd_task_answer "$B1" --value=approved --human ) >/dev/null 2>&1
[[ "$(col "$B1" need_answer)" == "approved" ]] \
  && ok_t "B1/ALLOW the answer is stored (liveness — the path under test ran)" || bad_t "B1 answer not stored" "got $(col "$B1" need_answer)"
[[ "$(ev allow)" == "1" ]] \
  && ok_t "B1/ALLOW ...and emits exactly one gate.approval-allow audit row" || bad_t "B1 allow row" "count=$(ev allow) calls=$(cat "$AUDIT")"
[[ "$(ev deny)" == "0" ]] \
  && ok_t "B1/ALLOW ...and no deny row — the two outcomes are separate events, not one event with a value" || bad_t "B1 a deny row rode along"
reset; B2=$(mkgate "+2h")
( cmd_task_answer "$B2" --value=denied --human ) >/dev/null 2>&1
[[ "$(col "$B2" need_answer)" == "denied" && "$(ev deny)" == "1" && "$(ev allow)" == "0" ]] \
  && ok_t "B2/DENY a denial stores and emits gate.approval-deny, and no allow row" || bad_t "B2 deny outcome" "answer=$(col "$B2" need_answer) deny=$(ev deny) allow=$(ev allow)"

echo "── C. TIMEOUT — the clock ran out and nobody answered ──"
reset; C1=$(mkgate "+2h"); age_past "$C1"
_hb_gate_expire_sweep >/dev/null 2>&1
[[ "$(col "$C1" need_answered_at)" != "<NULL>" ]] \
  && ok_t "C1/TIMEOUT the sweep RESOLVES an expired offer — it does not leave it unanswerable and open forever" || bad_t "C1 expired gate left unresolved" "the waiting agent would wait forever"
[[ "$(col "$C1" need_answer)" == "timeout" && "$(col "$C1" need_answered_by)" == "auto:timeout" ]] \
  && ok_t "C1/TIMEOUT ...as 'timeout' by 'auto:timeout' — FAIL CLOSED: an approval nobody answered is not an approval" || bad_t "C1 wrong resolution" "answer=$(col "$C1" need_answer) by=$(col "$C1" need_answered_by)"
[[ "$(col "$C1" need_answer_sig)" == "<NULL>" ]] \
  && ok_t "C1/TIMEOUT ...with NO signature, because nobody signed anything" || bad_t "C1 a timeout carried a signature"
[[ "$(ev timeout)" == "1" ]] \
  && ok_t "C1/TIMEOUT ...and emits exactly one gate.approval-timeout row" || bad_t "C1 timeout row" "count=$(ev timeout)"
# The auto: prefix is load-bearing, not cosmetic: the zero-human KPI counts
# `need_answered_by NOT LIKE 'auto:%'`, so a timeout must never read as a person.
[[ "$(db "SELECT CASE WHEN need_answered_by NOT LIKE 'auto:%' THEN 1 ELSE 0 END FROM tasks WHERE id=${C1};")" == "0" ]] \
  && ok_t "C1/TIMEOUT ...and the zero-human KPI predicate does NOT count it as a human decision" || bad_t "C1 a timeout would be counted as a person deciding"
reset
_hb_gate_expire_sweep >/dev/null 2>&1
[[ "$(ev timeout)" == "0" ]] \
  && ok_t "C2 IDEMPOTENCE: a second sweep resolves nothing and emits nothing — the predicate stops matching a resolved row" || bad_t "C2 the sweep re-fired on a resolved gate" "count=$(ev timeout)"
# C3 — THE LOAD-BEARING ARM. No Telegram anywhere: this is the dashboard's path,
# and the refusal still fires, because the deadline is enforced at the store.
reset; C3=$(mkgate "+2h"); age_past "$C3"
_o=$( cmd_task_answer "$C3" --value=approved --human 2>&1 ); _rc=$?
# ASSERT THE REFUSAL, NOT MERELY A REFUSAL. `rc != 0` alone is satisfied by ANY
# failure on this path — including the generic "no pending human gate" the code
# would fall through to with the expiry check deleted, which is how a mutant that
# removes the whole guard was still scoring this arm green. Measured: with the
# guard disabled this arm passed while B1/B2 went red, i.e. it was reporting on
# something else entirely. Key on the rule's own name.
(( _rc != 0 )) && grep -q "DIVE-4833" <<<"$_o" && grep -q "EXPIRED" <<<"$_o" \
  && ok_t "C3 an expired offer is REFUSED at 'task answer' BY THE EXPIRY RULE — the one point BOTH surfaces reach, so neither is trusted to have withheld its button" \
  || bad_t "C3 an expired approval was not refused by the expiry rule" "rc=$_rc msg=${_o:0:200}"
[[ "$(col "$C3" need_answer)" != "approved" ]] \
  && ok_t "C3 ...and nothing was authorised: the stored answer is not the tapped value" || bad_t "C3 the late tap authorised the action" "answer=$(col "$C3" need_answer) — THIS IS THE DEFECT"

echo "── D. STALE RESPONSE — a person taps after the deadline ──"
reset; D1=$(mkgate "+2h"); age_past "$D1"
( cmd_task_answer "$D1" --value=approved --human ) >/dev/null 2>&1
[[ "$(ev stale-response)" == "1" ]] \
  && ok_t "D1/STALE the late tap is RECORDED, not merely rejected — 'I approved that, why did nothing happen?' has an answer" || bad_t "D1 stale row" "count=$(ev stale-response) calls=$(cat "$AUDIT")"
[[ "$(ev timeout)" == "1" ]] \
  && ok_t "D1/STALE ...and the clock's own resolution is recorded alongside it, once" || bad_t "D1 timeout row missing or duplicated" "count=$(ev timeout)"
[[ "$(ev allow)" == "0" ]] \
  && ok_t "D1/STALE ...and NO allow row: a refused answer must never audit as an authorisation" || bad_t "D1 a refused tap audited as an allow" "count=$(ev allow)"
_o=$( cmd_task_answer "$D1" --value=approved --human 2>&1 )
grep -q "NOT applied" <<<"$_o" && grep -q "Nothing was authorised" <<<"$_o" \
  && ok_t "D1/STALE ...and the message tells the tapper plainly that nothing was authorised" || bad_t "D1 refusal text" "${_o:0:200}"

echo "── E. the deadline reaches the surfaces that must render it ──"
E1=$(mkgate "+2h")
_j=$( JSON_MODE=1 cmd_task_ls --all 2>/dev/null )
grep -q 'need_expires_at' <<<"$_j" \
  && ok_t "E1 task ls --json carries need_expires_at — the dashboard cannot render a deadline it is never sent" || bad_t "E1 the deadline is absent from the JSON the dashboard reads"
_i=$( JSON_MODE=1 cmd_task_inbox 2>/dev/null )
grep -q 'need_expires_at' <<<"$_i" \
  && ok_t "E2 ...and so does the human INBOX projection, which is the one the Needs-You card reads" || bad_t "E2 the inbox projection drops the deadline"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
