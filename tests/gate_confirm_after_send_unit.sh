#!/usr/bin/env bash
# TIER: core — 4.5s measured (DIVE-2354, 2026-08-10, agent-dev box). Deliberately
# NOT demoted to nightly: at 4.5s the "does not fit the 300s core" sentence would
# be an unmeasured claim, and that exact demotion-on-a-bad-number is the error
# recorded against DIVE-2828. If CI's budget check reds on it, that is an
# attributable signal on this PR and the demotion can then carry a real number.
#
# DIVE-2354 — A CUSTOMER-REPLY GATE MUST BE ANSWERABLE BOTH WAYS.
#
# THE DEFECT, measured on the first run of the DIVE-2348 customer-feedback loop:
# emails went out 13:27 and 13:30; the loop fired the drafting step at 13:40 and
# filed a gate worded "lodar approves the reply BEFORE it is sent". That gate
# describes an order that had already not happened, so it had no honest answer —
# answering asserts a prior approval that did not occur, cancelling erases the
# decision point (and on that run deleted marketing's escalation path for a
# genuinely unapproved second email), leaving it open reads as a bypassed human.
# Nobody bypassed anyone and the record said somebody had.
#
# THE PROPERTY UNDER TEST is not "the flag parses". It is that the two orders
# RENDER APART on every surface a human answers from — the row, the chat message,
# and the button — because a ratification that renders as a prior approval is the
# false record the ticket exists to end. Each mode arm is therefore run against a
# CONTROL gate of the same type filed on a sibling row differing ONLY in --mode.
# Without the control, "the show output mentions ratification" is also what a
# build that mentions it unconditionally looks like.
#
# THE MUTATION ARM (case 8) removes the DATA rather than the code: gate_mode is
# nulled on an already-filed, already-answered row and every mode assertion must
# FLIP RED while the control stays green. That is what makes the arms above
# evidence that they read the stored order, rather than evidence that some other
# always-true string happens to be in the output.
#
# Isolation mirrors the sibling gate harnesses: source src/ libs, throwaway
# STATE_DIR, gate telemetry to a temp log so no prod store is touched. The
# channel sink `_task_send_owner` is stubbed so the composed alert text is
# observable at the CALL SITE (an unpaired harness box sends nothing).
# Run: bash tests/gate_confirm_after_send_unit.sh   (no root, no network)
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
SRC=src
TMP="$(mktemp -d /tmp/gate-confirm-after-send-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e

NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }
5dive() { return 0; }

# Spy on the CALL SITE, not on Telegram: the composed alert text is the record the
# human answers from, and on an unpaired box nothing is ever sent.
SENT="$TMP/sent.txt"; : >"$SENT"
_task_send_owner() { printf '%s\n' "$1" >>"$SENT"; return 0; }
# An unpaired harness box resolves no channel, so the composed text is never
# reached. Stub the resolver (not the composer) so the arms below grade the real
# message-building code on the real gate row.
_task_owner_channel() { TASK_CH_TOKEN="t"; TASK_CH_ACCESS="$TMP/access.json"; TASK_CH_TYPE="claude"; TASK_CH_AGENT="marketing"; return 0; }
alert_of() { : >"$SENT"; _task_need_notify_deliver "$1" approval "$2" "" approved >/dev/null 2>&1; cat "$SENT"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
JSON_MODE=0

tasks_db_init
db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('marketing','main','builder');"

seed() { db "INSERT INTO tasks(ident,title,status,created_by,assignee)
             VALUES('$1',$(sqlq "${2:-reply to a customer on a live thread}"),'todo','main','marketing');"; }
mode_of()  { db "SELECT COALESCE(gate_mode,'<null>') FROM tasks WHERE ident='$1';"; }
show_of()  { JSON_MODE=0 cmd_task_show "$1" 2>&1; }
sent_of()  { : >"$SENT"; }

# ---------------------------------------------------------------------------
# 0. SCHEMA — the column exists on a FRESH store, not only after a migration.
#    A fresh store takes the CREATE and never runs the ALTER loop (DIVE-2808), so
#    a column declared in only one of the two places is a store that silently
#    cannot record the order at all.
# ---------------------------------------------------------------------------
for tbl in tasks gate_history; do
  if [[ "$(db "SELECT 1 FROM pragma_table_info('$tbl') WHERE name='gate_mode';")" == "1" ]]; then
    ok_t "0/$tbl: gate_mode present on a fresh store"
  else
    bad_t "0/$tbl: gate_mode present on a fresh store" "column missing — a fresh store cannot record which order a gate was in"
  fi
done

# ---------------------------------------------------------------------------
# 1. THE CONTROL AND THE MODE GATE — same type, same ask, one flag apart.
# ---------------------------------------------------------------------------
seed DIVE-9001 'reply to a customer on a live thread'
seed DIVE-9002 'reply to a customer on a live thread'
cmd_task_need DIVE-9001 --type=approval --from=marketing \
  --ask="send this reply to the customer" --recommend="approved" >/dev/null 2>&1
cmd_task_need DIVE-9002 --type=approval --from=marketing --mode=confirm-after-send \
  --ask="this reply was already sent at 13:30 — confirm it" --recommend="approved" >/dev/null 2>&1
CTRL_SENT="$(alert_of DIVE-9001 'send this reply to the customer')"
MODE_SENT="$(alert_of DIVE-9002 'this reply was already sent at 13:30 — confirm it')"

[[ "$(mode_of DIVE-9001)" == "<null>" ]] \
  && ok_t "1a: control stores NO mode (absent is a real third state, not a default)" \
  || bad_t "1a: control stores NO mode" "got '$(mode_of DIVE-9001)' — a filer who said nothing must not be recorded as having declared an order"
[[ "$(mode_of DIVE-9002)" == "confirm-after-send" ]] \
  && ok_t "1b: --mode=confirm-after-send is stored as data on the row" \
  || bad_t "1b: --mode=confirm-after-send is stored" "got '$(mode_of DIVE-9002)'"

# ---------------------------------------------------------------------------
# 2. `task show` RENDERS THE TWO APART, pending.
# ---------------------------------------------------------------------------
c_show="$(show_of DIVE-9001)"; m_show="$(show_of DIVE-9002)"
grep -qi 'confirm-after-send' <<<"$m_show" \
  && ok_t "2a: show names the order on the mode gate" \
  || bad_t "2a: show names the order on the mode gate" "$m_show"
grep -qi 'RATIFICATION' <<<"$m_show" \
  && ok_t "2b: show says the tap is a RATIFICATION, not a prior approval" \
  || bad_t "2b: show says RATIFICATION" "$m_show"
grep -qi 'confirm-after-send\|RATIFICATION' <<<"$c_show" \
  && bad_t "2c: control show is unchanged" "the control gate is rendering ratification language: $c_show" \
  || ok_t "2c: control show carries no ratification language"

# ---------------------------------------------------------------------------
# 3. THE CHAT MESSAGE — the surface the tap actually happens on.
# ---------------------------------------------------------------------------
grep -qi 'ALREADY TAKEN' <<<"$MODE_SENT" \
  && ok_t "3a: the alert says the action has already happened" \
  || bad_t "3a: alert names the order" "$MODE_SENT"
grep -qi 'ALREADY TAKEN\|RATIFICATION' <<<"$CTRL_SENT" \
  && bad_t "3b: control alert is unchanged" "$CTRL_SENT" \
  || ok_t "3b: control alert carries no ratification language"

# ---------------------------------------------------------------------------
# 4. THE BUTTONS — labels differ; callback_data must be BYTE-IDENTICAL, because
#    every shipped plugin handler parses it and this ticket ships no plugin change.
# ---------------------------------------------------------------------------
cid="$(db "SELECT id FROM tasks WHERE ident='DIVE-9001';")"
mid="$(db "SELECT id FROM tasks WHERE ident='DIVE-9002';")"
c_btn="$(_task_gate_reply_markup "$cid" approval "" approved "" claude)"
m_btn="$(_task_gate_reply_markup "$mid" approval "" approved "" claude)"
grep -q 'Confirm (after the fact)' <<<"$m_btn" \
  && ok_t "4a: the approve button reads 'Confirm (after the fact)'" \
  || bad_t "4a: button relabelled" "$m_btn"
grep -q '✅ Approve' <<<"$c_btn" \
  && ok_t "4b: control button still reads 'Approve'" \
  || bad_t "4b: control button unchanged" "$c_btn"
c_cb="$(grep -o 'tna:[0-9]*:[a-z]*' <<<"$c_btn" | sed "s/tna:${cid}:/tna:N:/" | sort | tr '\n' ' ')"
m_cb="$(grep -o 'tna:[0-9]*:[a-z]*' <<<"$m_btn" | sed "s/tna:${mid}:/tna:N:/" | sort | tr '\n' ' ')"
[[ -n "$c_cb" && "$c_cb" == "$m_cb" ]] \
  && ok_t "4c: callback_data byte-identical to the control ($c_cb)" \
  || bad_t "4c: callback_data byte-identical" "control='$c_cb' mode='$m_cb' — a relabel that changes the token breaks every deployed tap handler"

# ---------------------------------------------------------------------------
# 5. THE ANSWER IS RECORDED AS A RATIFICATION.
# ---------------------------------------------------------------------------
# The answer is written directly: clearing an approval gate is root-gated and
# nonce-proven, and that authority path is graded by tests/gate_t2_nonce_proof_unit.sh
# and tests/gate_answer_audit_unit.sh. What is under test HERE is what the record
# READS once answered — the half that produced the false claim on DIVE-2348.
for _t in DIVE-9001 DIVE-9002; do
  db "UPDATE tasks SET need_answer='approved', need_answered_at=datetime('now'),
         need_answered_by='human:lodar' WHERE ident='$_t';"
done
c_show="$(show_of DIVE-9001)"; m_show="$(show_of DIVE-9002)"
grep -qi 'RATIFIED AFTER THE FACT' <<<"$m_show" \
  && ok_t "5a: the answered mode gate reads RATIFIED AFTER THE FACT" \
  || bad_t "5a: answered mode gate reads as a ratification" "$m_show"
grep -qi 'RATIFIED AFTER THE FACT' <<<"$c_show" \
  && bad_t "5b: control answer is unchanged" "$c_show" \
  || ok_t "5b: the control's answer still reads as a plain approval"

# ---------------------------------------------------------------------------
# 6. REFUSALS. Each is a property, not a spelling check.
# ---------------------------------------------------------------------------
seed DIVE-9003
( cmd_task_need DIVE-9003 --type=approval --from=marketing --mode=sometime --ask=x ) >/dev/null 2>&1
(( $? != 0 )) && ok_t "6a: an unknown --mode is refused" \
              || bad_t "6a: unknown --mode refused" "a free-text order is prose, which is what this ticket replaces"
( cmd_task_need DIVE-9003 --type=decision --options="a|b" --recommend=a --from=marketing \
    --mode=confirm-after-send --ask=x ) >/dev/null 2>&1
(( $? != 0 )) && ok_t "6b: --mode on a non-approval type is refused" \
              || bad_t "6b: --mode refused off --type=approval" "a decision is lead-clearable, so a ratification filed as one need never reach a person"
( cmd_task_need DIVE-9003 --type=approval --from=marketing --tier=0 \
    --mode=confirm-after-send --recommend=approved --ask=x ) >/dev/null 2>&1
(( $? != 0 )) && ok_t "6c: --tier=0 + confirm-after-send is refused (no auto-ratification)" \
              || bad_t "6c: tier-0 auto-ratification refused" "tier 0 applies the FILER's own recommendation — on a ratification that is the agent clearing its own already-taken action"
[[ "$(mode_of DIVE-9003)" == "<null>" ]] \
  && ok_t "6d: no refused filing left a mode on the row" \
  || bad_t "6d: refused filings leave no mode" "got '$(mode_of DIVE-9003)'"

# ---------------------------------------------------------------------------
# 7. THE ORDER SURVIVES INTO HISTORY, AND DOES NOT SURVIVE A WITHDRAWAL.
#    A re-file archives the outgoing gate; the archived row must carry the order
#    it was filed under, or the record loses exactly the fact this ticket adds.
# ---------------------------------------------------------------------------
cmd_task_need DIVE-9002 --type=approval --from=marketing \
  --ask="a fresh, ordinary approval" --recommend="approved" >/dev/null 2>&1
[[ "$(db "SELECT COALESCE(gate_mode,'<null>') FROM gate_history WHERE ident='DIVE-9002' ORDER BY id DESC LIMIT 1;")" == "confirm-after-send" ]] \
  && ok_t "7a: gate_history carries the archived gate's order" \
  || bad_t "7a: gate_history carries the order" "the ratification vanished from the record when the row was re-filed"
[[ "$(mode_of DIVE-9002)" == "<null>" ]] \
  && ok_t "7b: a re-file replaces the order rather than inheriting it" \
  || bad_t "7b: re-file replaces the order" "got '$(mode_of DIVE-9002)' on a gate filed with no --mode"
# 7c is filed by the HARNESS's own actor, not by marketing: withdrawal is
# filer/lead/coordinator-gated, and a refused withdraw would leave gate_mode
# already NULL from 7b — a pass that measures nothing. The rc is asserted so this
# arm cannot go green on a branch that never ran.
seed DIVE-9005
cmd_task_need DIVE-9005 --type=approval --mode=confirm-after-send \
  --ask="already sent — confirm it" --recommend="approved" >/dev/null 2>&1
[[ "$(mode_of DIVE-9005)" == "confirm-after-send" ]] \
  && ok_t "7c/pre: the withdraw arm starts from a row that HOLDS an order" \
  || bad_t "7c/pre: withdraw arm baseline" "got '$(mode_of DIVE-9005)' — the arm below would measure nothing"
( cmd_task_need DIVE-9005 --withdraw ) >"$TMP/wd.out" 2>&1
_wd_rc=$?
(( _wd_rc == 0 )) \
  && ok_t "7c/rc: the withdraw actually ran" \
  || bad_t "7c/rc: the withdraw actually ran" "rc=$_wd_rc: $(cat "$TMP/wd.out")"
[[ "$(mode_of DIVE-9005)" == "<null>" ]] \
  && ok_t "7c: a withdrawn gate reports no order" \
  || bad_t "7c: withdraw clears the order" "got '$(mode_of DIVE-9005)'"

# ---------------------------------------------------------------------------
# 8. MUTATION — null the DATA on the already-answered row. Every mode assertion
#    above must flip red; the control must stay green. Without this, each grep
#    above is equally satisfied by a build that prints the ratification line
#    unconditionally.
# ---------------------------------------------------------------------------
seed DIVE-9004
sent_of
cmd_task_need DIVE-9004 --type=approval --from=marketing --mode=confirm-after-send \
  --ask="already sent — confirm it" --recommend="approved" >/dev/null 2>&1
db "UPDATE tasks SET need_answer='approved', need_answered_at=datetime('now'),
       need_answered_by='human:lodar' WHERE ident='DIVE-9004';"
grep -qi 'RATIFIED AFTER THE FACT' <<<"$(show_of DIVE-9004)" \
  || bad_t "8/pre: the mutation arm's baseline is green" "the arm cannot discriminate — it is red before the mutation"
db "UPDATE tasks SET gate_mode=NULL WHERE ident='DIVE-9004';"
m2id="$(db "SELECT id FROM tasks WHERE ident='DIVE-9004';")"
mut_show="$(show_of DIVE-9004)"
mut_btn="$(_task_gate_reply_markup "$m2id" approval "" approved "" claude)"
grep -qi 'RATIFIED AFTER THE FACT\|confirm-after-send' <<<"$mut_show" \
  && bad_t "8a: nulling gate_mode removes the ratification from show" "the render is NOT reading the stored order: $mut_show" \
  || ok_t "8a: nulling gate_mode removes the ratification from show"
grep -q 'Confirm (after the fact)' <<<"$mut_btn" \
  && bad_t "8b: nulling gate_mode restores the plain Approve button" "the button label is not reading the row" \
  || ok_t "8b: nulling gate_mode restores the plain Approve button"
grep -q '✅ Approve' <<<"$mut_btn" \
  && ok_t "8c: the mutated row's button is byte-equal to the control's label" \
  || bad_t "8c: mutated button falls back to Approve" "$mut_btn"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
