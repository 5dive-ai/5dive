#!/usr/bin/env bash
# DIVE-1968 — the FILER'S OWN channel must be resolved BY NAME, in the contexts
# where the caller is not the filer.
#
# Why this file exists, and why gate_channelless_escalation_unit.sh could never
# have caught this: that harness stubs
#     _task_owner_channel() { _task_agent_channel "${FILER_SELF:-}"; }
# i.e. it models the own-channel probe as FILER-scoped. In production it is
# CALLER-scoped — `auto_sender_from_sudo` reads $SUDO_USER (only when agent-*),
# else $USER (only when agent-*) — so it resolves EMPTY under the root re-nag
# sweep and under the privileged re-send, and resolves the WRONG AGENT when a
# peer drives the send. The fixture stubbed the bug away, then every assertion
# built on top of it passed. Measured consequence: a top-of-org filer (olivia,
# quinn — reports_to='') has a working channel and still logs
# "no paired channel for filer X or anyone above it", because the chain walks
# strictly UP and the filer is never a candidate.
#
# So these cases drive the REAL _task_owner_channel and never stub it.
# Isolated: throwaway STATE_DIR + TASKS_DB, gate telemetry redirected. Run:
#   bash tests/gate_filer_own_channel_unit.sh
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-filer-own.XXXXXX)"

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
# The real shape: olivia is TOP (reports_to NULL) and HAS a channel.
db "INSERT INTO agents_org (name,reports_to,role) VALUES
     ('dev','main',NULL),('main','olivia',NULL),('olivia',NULL,'coordinator');"

READABLE=""; PAIRED=""; RESOLVED_AS=""
_task_agent_channel() {
  local n="$1"; TASK_CH_TOKEN="" TASK_CH_ACCESS="" TASK_CH_TYPE=""
  [[ -n "$n" && " $READABLE " == *" $n "* ]] || return 1
  TASK_CH_TOKEN=tok TASK_CH_ACCESS="$TMP/access-${n}.json" TASK_CH_TYPE=claude
  RESOLVED_AS="$n"; return 0
}
_task_agent_paired() { local n="$1"; [[ -n "$n" && " $PAIRED " == *" $n "* ]]; }
# NOTE: _task_owner_channel is deliberately NOT stubbed — it is under test.
task_actor() { printf '%s' "${TASK_GATE_FILER:-}"; }
audit_log() { :; }

SENT=""; SEND_ACCESS=""
_task_send_owner() { SENT="$1"; SEND_ACCESS="$TASK_CH_ACCESS"; TASK_SEND_DELIVERED=1; return 0; }
SUDO_CALLS=""
_task_gate_escalate_via_sudo() { SUDO_CALLS+="$1 "; return 1; }

mk_gate() { # <ident> <filer>
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_asked_at)
      VALUES ($(sqlq "$1"),'t','high',$(sqlq "$2"),$(sqlq "$2"),'standard','blocked','decision',2,'pick one',datetime('now'));"
}
errs() { grep -c 'result=error' "$FIVEDIVE_GATE_NOTIFY_LOG" 2>/dev/null || echo 0; }

# ---- 1. the root re-nag sweep: caller is nobody, filer is top-of-org ---------
# This is the exact production context — heartbeat cron, no SUDO_UID, USER=root.
mk_gate DIVE-9101 olivia
READABLE="olivia"; PAIRED="olivia"
unset SUDO_USER; USER=root

# First prove the case is real: the caller-scoped probe finds NOTHING here. If
# this ever starts succeeding the rest of the test proves nothing.
RESOLVED_AS=""; _task_owner_channel
[[ -z "$RESOLVED_AS" ]] \
  && ok_t "caller-scoped _task_owner_channel resolves nobody in a root sweep" \
  || bad_t "root sweep precondition" "resolved '$RESOLVED_AS' — test no longer exercises the gap"

before=$(errs); SENT=""; RESOLVED_AS=""
TASK_GATE_FILER=olivia task_need_notify DIVE-9101 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "0" ]] && ok_t "top-of-org filer with a channel: gate delivers (rc 0)" \
  || bad_t "top-of-org filer delivers" "rc=$rc"
[[ "$RESOLVED_AS" == "olivia" ]] \
  && ok_t "resolved the FILER'S OWN channel by name" \
  || bad_t "filer own channel by name" "resolved '$RESOLVED_AS'"
[[ -n "$SENT" && "$SEND_ACCESS" == *"access-olivia.json"* ]] \
  && ok_t "the send carries the filer's own resolved channel" \
  || bad_t "send carries filer channel" "sent='${SENT:0:80}' access='$SEND_ACCESS'"
[[ "$(errs)" == "$before" ]] \
  && ok_t "no 'no paired channel' error row for a filer who HAS one" \
  || bad_t "spurious error row" "$(tail -1 "$FIVEDIVE_GATE_NOTIFY_LOG")"
[[ -z "$SUDO_CALLS" ]] && ok_t "no privileged re-send needed" || bad_t "unexpected re-send" "$SUDO_CALLS"

# ---- 2. a PEER drives the send: the alert belongs to the FILER'S human -------
# sudo chain says agent-dev, but the gate is olivia's. Resolving the caller here
# alerts the wrong human — silently, since it looks like a successful delivery.
mk_gate DIVE-9102 olivia
READABLE="olivia dev"; PAIRED="olivia dev"
SUDO_USER=agent-dev; USER=dev
SENT=""; RESOLVED_AS=""
TASK_GATE_FILER=olivia task_need_notify DIVE-9102 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$RESOLVED_AS" == "olivia" ]] \
  && ok_t "peer-driven send still resolves the FILER, not the caller" \
  || bad_t "peer-driven resolves filer" "resolved '$RESOLVED_AS' (dev = wrong human)"
unset SUDO_USER

# ---- 3. regression: a filer with NO channel still escalates UP ---------------
mk_gate DIVE-9103 dev
READABLE="main"; PAIRED="main olivia"
USER=root; SENT=""; RESOLVED_AS=""; TASK_NOTIFY_ESCALATED_FROM=""
TASK_GATE_FILER=dev task_need_notify DIVE-9103 decision "pick one" "" "" "" "" "" ""; rc=$?
[[ "$rc" == "0" && "$TASK_NOTIFY_ESCALATED_FROM" == "dev" ]] \
  && ok_t "channel-less filer still escalates up the chart (unchanged)" \
  || bad_t "escalation preserved" "rc=$rc from='$TASK_NOTIFY_ESCALATED_FROM'"
[[ "$SENT" == *"filed by dev"* ]] \
  && ok_t "escalated alert still names the original filer" \
  || bad_t "escalated alert names filer" "${SENT:0:120}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
