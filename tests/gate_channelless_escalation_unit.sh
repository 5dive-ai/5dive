#!/usr/bin/env bash
# DIVE-1927 — a gate filed by a CHANNEL-LESS agent must reach a human, or the
# filing must fail loudly. Covers:
#   * _task_escalation_chain — multi-hop walk UP reports_to, cycle-safe, ends at
#     the coordinator, never emits the filer itself.
#   * task_need_notify — unpaired filer + a readable channel above it => alert is
#     escalated AND names the original filer.
#   * task_need_notify — unpaired filer + a PAIRED-but-unreadable channel above
#     it (the real fleet shape: every access.json is 0600) => privileged re-send.
#   * task_need_notify — nobody paired anywhere up the chain => rc 3 (filed but
#     UNNOTIFIED) + a logged delivery error, never a silent OK.
#   * cmd_task_need — an unnotified gate still FILES (the dashboard/`task answer`
#     need no channel; tests/gate_parity_smoke.sh asserts that contract) and says
#     notified:false rather than reading identically to a notified one.
# Isolated: source src/ libs, throwaway STATE_DIR, the live tasks.db is never
# touched. Run: bash tests/gate_channelless_escalation_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-chanless.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_pairing.sh cmd_agent_runtime.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"; : >"$FIVEDIVE_GATE_NOTIFY_LOG"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- fleet fixture -----------------------------------------------------------
# dev3 -> main -> olivia; boss is the (unrelated) coordinator.
db "INSERT INTO agents_org (name,reports_to,role) VALUES
     ('dev3','main',NULL),('main','olivia',NULL),('olivia',NULL,'coordinator'),
     ('lonely',NULL,NULL);"

# READABLE = this uid can read that agent's access.json; PAIRED = the agent has a
# channel at all (root could read it). The gap between the two IS the bug.
READABLE=""; PAIRED=""
_task_agent_channel() {
  local n="$1"; TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
  [[ -n "$n" && " $READABLE " == *" $n "* ]] || return 1
  TASK_CH_TOKEN=tok TASK_CH_ACCESS="$TMP/access.json" TASK_CH_TYPE=claude; return 0
}
# Keep a handle on the REAL probe before stubbing it, so the absent-vs-forbidden
# assertions below exercise the shipped function rather than the stub.
eval "_real_task_agent_paired() $(declare -f _task_agent_paired | tail -n +2)"
# Stub is two-valued on purpose (0/1); the three-valued undetermined case is
# driven explicitly where it matters.
_task_agent_paired() { local n="$1"; [[ -n "$n" && " $PAIRED " == *" $n "* ]]; }
_task_owner_channel() { _task_agent_channel "${FILER_SELF:-}"; }
task_actor() { printf '%s' "${FILER_SELF:-dev3}"; }
audit_log() { :; }
printf '%s\n' '{"allowFrom":["1234567890"]}' >"$TMP/access.json"

# The stub records the channel state AS OF THE SEND. Asserting only on the text
# would pass even when the resolved token/access never reached the sender — the
# exact subshell bug the first cut of this fix shipped with (_task_chain_channel
# called in $( ), so its TASK_CH_* died in the subshell and the "escalated" send
# went out with an empty token to an empty access file).
SENT=""; SENT_ACCESS="x"; SENT_AGENT="x"; SEND_RC=0
_task_send_owner() {
  SENT="$1"; SENT_ACCESS="$TASK_CH_ACCESS"; SENT_AGENT="$TASK_CH_AGENT"
  TASK_SEND_DELIVERED=1; return 0
}
SUDO_CALLS=""; SUDO_RC=0
_task_gate_escalate_via_sudo() { SUDO_CALLS+="$1 "; return "$SUDO_RC"; }

mk_gate() { # <ident> <filer>
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'t','high',$(sqlq "$2"),$(sqlq "$2"),'standard','blocked','decision',2,'pick one',datetime('now'));"
}

# ---- 1. chain walk -----------------------------------------------------------
got=$(_task_escalation_chain dev3 | paste -sd, -)
[[ "$got" == "main,olivia" ]] && ok_t "chain walks multi-hop dev3 -> main -> olivia" \
  || bad_t "chain walks multi-hop" "got '$got'"

got=$(_task_escalation_chain lonely | paste -sd, -)
[[ "$got" == "olivia" ]] && ok_t "no manager falls back to the coordinator" || bad_t "coordinator fallback" "got '$got'"

got=$(_task_escalation_chain olivia | paste -sd, -)
[[ -z "$got" ]] && ok_t "the coordinator never escalates to itself" || bad_t "self-escalation" "got '$got'"

db "UPDATE agents_org SET reports_to='dev3' WHERE name='olivia';"   # dev3->main->olivia->dev3
got=$(_task_escalation_chain dev3 | paste -sd, -)
[[ "$got" == "main,olivia" ]] && ok_t "a reports_to cycle terminates" || bad_t "cycle guard" "got '$got'"
db "UPDATE agents_org SET reports_to=NULL WHERE name='olivia';"

# ---- 2. unpaired filer, readable channel above it ----------------------------
mk_gate DIVE-9001 dev3
FILER_SELF=dev3 READABLE="main olivia" PAIRED="main olivia"
SENT=""; TASK_NOTIFY_ESCALATED_FROM=""
task_need_notify DIVE-9001 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "0" ]] && ok_t "escalated gate returns 0" || bad_t "escalated gate returns 0" "rc=$rc"
[[ "$SENT" == *"filed by dev3"* ]] && ok_t "escalated alert names the original filer" \
  || bad_t "escalated alert names the filer" "sent: ${SENT:0:160}"
[[ "$SENT" == *"[DIVE-9001]"* ]] && ok_t "escalated alert carries the gate ident" || bad_t "ident in alert" "${SENT:0:160}"
[[ "$SENT_AGENT" == "main" && -n "$SENT_ACCESS" ]] \
  && ok_t "the send actually carries the ESCALATED agent's resolved channel" \
  || bad_t "escalated channel reaches the sender" "agent='$SENT_AGENT' access='$SENT_ACCESS'"

# Guard the subshell regression directly: the resolver must mutate the CALLER's
# TASK_CH_*, so it may never be invoked as $(_task_chain_channel ...).
TASK_CH_ACCESS=""; TASK_CH_AGENT=""
_task_chain_channel dev3 && got="$TASK_CH_AGENT" || got=""
[[ "$got" == "main" && -n "$TASK_CH_ACCESS" ]] \
  && ok_t "_task_chain_channel resolves TASK_CH_* into the caller's shell" \
  || bad_t "chain resolver sets caller state" "agent='$got' access='$TASK_CH_ACCESS'"
grep -q '\$(_task_chain_channel' src/*.sh 2>/dev/null \
  && bad_t "no command-substitution call sites" "a \$(_task_chain_channel ...) call site would discard the resolved channel" \
  || ok_t "no \$(_task_chain_channel ...) call sites exist"

# ---- 3. paired but UNREADABLE above => privileged re-send --------------------
mk_gate DIVE-9002 dev3
FILER_SELF=dev3 READABLE="" PAIRED="main"
SENT=""; SUDO_CALLS=""; SUDO_RC=0; TASK_NOTIFY_ESCALATED_FROM=""
task_need_notify DIVE-9002 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "0" ]] && ok_t "unreadable-but-paired manager returns 0 via the privileged re-send" \
  || bad_t "privileged re-send rc" "rc=$rc"
[[ "$SUDO_CALLS" == *"DIVE-9002"* ]] && ok_t "privileged re-send was actually invoked" \
  || bad_t "privileged re-send invoked" "calls='$SUDO_CALLS'"
[[ -z "$SENT" ]] && ok_t "the unprivileged run does not also send" || bad_t "double send" "sent: ${SENT:0:80}"

# The privileged run itself must NOT re-sudo — it falls through to unnotified.
SUDO_CALLS=""; TASK_GATE_ESCALATING=1
task_need_notify DIVE-9002 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "3" && -z "$SUDO_CALLS" ]] && ok_t "the privileged run never re-sudoes itself" \
  || bad_t "recursion guard" "rc=$rc calls='$SUDO_CALLS'"
unset TASK_GATE_ESCALATING

# ---- 4. nobody paired anywhere => rc 3, logged, never a SILENT ok -----------
mk_gate DIVE-9003 dev3
FILER_SELF=dev3 READABLE="" PAIRED=""
SENT=""; SUDO_CALLS=""; : >"$FIVEDIVE_GATE_NOTIFY_LOG"
task_need_notify DIVE-9003 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "3" ]] && ok_t "an unnotified gate returns 3 (not a silent 0, and not a refusal)" || bad_t "unnotified rc" "rc=$rc"
[[ -z "$SENT" ]] && ok_t "an unnotified gate sends nothing" || bad_t "unnotified sent" "${SENT:0:80}"
grep -q "result=error" "$FIVEDIVE_GATE_NOTIFY_LOG" \
  && ok_t "the miss is written to the gate-delivery log" || bad_t "delivery log" "$(cat "$FIVEDIVE_GATE_NOTIFY_LOG")"

# ---- 5. cmd_task_need FILES an unnotified gate and marks it ------------------
# The product contract (tests/gate_parity_smoke.sh): a gate files CLI-only with no
# Telegram present. An earlier cut of this fix refused here, which broke CI, the
# parity smoke, `5dive goal`'s plan gate, and every solo/headless install. What
# must hold instead is that an UNNOTIFIED gate never reads like a notified one.
db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status)
    VALUES ('DIVE-9004','unnotified','high','dev3','dev3','standard','todo');"
did=$(db "SELECT id FROM tasks WHERE ident='DIVE-9004';")
FILER_SELF=dev3 READABLE="" PAIRED=""
out=$( (cmd_task_need DIVE-9004 --type=decision --ask="which way?" --options="A|B" --recommend="A" --from=dev3) 2>&1 ); rc=$?
[[ "$rc" == "0" ]] && ok_t "cmd_task_need still FILES the gate when nobody can be pinged" \
  || bad_t "unnotified gate still files" "rc=$rc out=${out:0:200}"
row=$(db "SELECT status||'|'||COALESCE(need_type,'-')||'|'||COALESCE(gate_pinged_at,'NULL') FROM tasks WHERE id=${did};")
[[ "$row" == "blocked|decision|NULL" ]] \
  && ok_t "the gate stands, answerable, with NO delivery receipt" || bad_t "gate row after unnotified file" "row='$row'"
[[ "$out" == *"UNNOTIFIED"* ]] \
  && ok_t "the result SAYS nobody was pinged (never reads like a notified gate)" \
  || bad_t "unnotified is marked" "${out:0:240}"

# ---- 6. absent vs FORBIDDEN in the pairing probe (main's PR #160 review) -----
# The probe must be three-valued. A boolean would put the very conflation this
# ticket exists to remove back on the connector env — and with fail-closed
# `task need`, an unreadable token would REFUSE a gate on a healthy chain.
CONN_OK="$TMP/conn"; mkdir -p "$CONN_OK"
CONNECTORS_DIR="$CONN_OK"
_real_task_agent_paired nosuchagent0001; rc=$?
[[ "$rc" == "1" ]] && ok_t "searchable connector dir + genuinely absent token => PROVABLY unpaired (1)" \
  || bad_t "absent token is provable" "rc=$rc"

# Root-proof blindness: point CONNECTORS_DIR at a regular FILE. `! -d` is true
# for every uid including root, so this negative control cannot vacuously pass
# in a root CI run the way a chmod-000 fixture would.
printf 'x' >"$TMP/not-a-dir"
CONNECTORS_DIR="$TMP/not-a-dir"
_real_task_agent_paired nosuchagent0001; rc=$?
[[ "$rc" == "2" ]] && ok_t "unsearchable connector dir => UNDETERMINED (2), never 'unpaired'" \
  || bad_t "blind dir is undetermined" "rc=$rc (1 here would refuse gates on a healthy chain)"

CONNECTORS_DIR="$CONN_OK"
printf 'TELEGRAM_BOT_TOKEN=t\n' >"$CONN_OK/telegram-nosuchagent0001.env"
if [[ $EUID -ne 0 ]]; then
  chmod 000 "$CONN_OK/telegram-nosuchagent0001.env"
  _real_task_agent_paired nosuchagent0001; rc=$?
  [[ "$rc" == "2" ]] && ok_t "token file present but FORBIDDEN => UNDETERMINED (2)" \
    || bad_t "forbidden token is undetermined" "rc=$rc"
  chmod 644 "$CONN_OK/telegram-nosuchagent0001.env"
else
  printf 'SKIP - forbidden-token case needs a non-root uid (running as root); the root-proof\n       unsearchable-dir case above covers the same branch\n'
fi

# And the behaviour that actually matters: an UNDETERMINED chain must not refuse.
_task_agent_paired() { return 2; }
mk_gate DIVE-9005 dev3
FILER_SELF=dev3 READABLE="" PAIRED=""
SENT=""; SUDO_CALLS=""; SUDO_RC=0
task_need_notify DIVE-9005 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "0" && "$SUDO_CALLS" == *"DIVE-9005"* ]] \
  && ok_t "an UNDETERMINED chain escalates to a privileged sender instead of refusing" \
  || bad_t "undetermined chain must not refuse" "rc=$rc calls='$SUDO_CALLS'"

# When that privileged hand-off fails, say what we KNOW, not the worst cause.
SUDO_RC=1; TASK_NOTIFY_FAIL_REASON=""
task_need_notify DIVE-9005 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "3" && "$TASK_NOTIFY_FAIL_REASON" == *"re-send"* && "$TASK_NOTIFY_FAIL_REASON" != *"no paired channel"* ]] \
  && ok_t "a failed hand-off reports the hand-off, not a false 'nobody is paired'" \
  || bad_t "failure reason is honest" "rc=$rc reason='$TASK_NOTIFY_FAIL_REASON'"
_task_agent_paired() { local n="$1"; [[ -n "$n" && " $PAIRED " == *" $n "* ]]; }

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
