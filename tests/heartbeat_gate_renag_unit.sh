#!/usr/bin/env bash
# DIVE-1490: +1h then 24h receipt-backed, button-bearing batched gate re-nags.
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
TMP=$(mktemp -d /tmp/gate-renag.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh cmd_heartbeat.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate
db "INSERT INTO agents_org (name,reports_to,role) VALUES ('main',NULL,'coordinator'),('dev','main',NULL);"

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
CHANNEL_LOG="$TMP/channels"; : >"$CHANNEL_LOG"
LAST_TEXT="$TMP/text"; LAST_MARKUP="$TMP/markup"
FAIL_SEND=0
_task_agent_channel() {
  printf '%s\n' "$1" >>"$CHANNEL_LOG"
  TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS=/dev/null
  return 0
}
_task_send_owner() {
  local text="$1" markup="$2" ids="$3"
  printf '%s\n' "$ids" >>"$SEND_LOG"
  printf '%s' "$text" >"$LAST_TEXT"; printf '%s' "$markup" >"$LAST_MARKUP"
  TASK_SEND_MESSAGE_IDS="901"
  if [[ "$FAIL_SEND" == "1" ]]; then TASK_SEND_DELIVERED=0; return 0; fi
  TASK_SEND_DELIVERED=1
  db "UPDATE tasks SET gate_pinged_at=datetime('now') WHERE id IN (${ids});"
}
audit_log() { :; }
_hb_log() { :; }

# DIVE-2587 — the agent rail. `cmd_send` is REAL in this harness (cmd_agent.sh is
# sourced above), so an unstubbed rail would try to inject into live tmux panes
# from a unit test. Stubbed to a log + a settable rc, which is also what lets the
# fallback arm drive a failing rail deterministically.
AGENT_SEND_LOG="$TMP/agent_sends"; : >"$AGENT_SEND_LOG"
LAST_AGENT_TEXT="$TMP/agent_text"; : >"$LAST_AGENT_TEXT"
FAIL_AGENT_SEND=0
cmd_send() {
  local to="$1" a msg=""; shift
  for a in "$@"; do [[ "$a" == --message=* ]] && msg="${a#--message=}"; done
  printf '%s\n' "$to" >>"$AGENT_SEND_LOG"
  printf '%s' "$msg" >"$LAST_AGENT_TEXT"
  return "$FAIL_AGENT_SEND"
}
DELIV_LOG="$TMP/deliv"; : >"$DELIV_LOG"
_task_gate_delivery_log() { printf '%s|%s|%s\n' "$1" "$2" "$3" >>"$DELIV_LOG"; return 0; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
nsends() { grep -c . "$SEND_LOG"; }
pinged() { db "SELECT CASE WHEN gate_pinged_at IS NULL THEN 'NULL' ELSE 'SET' END FROM tasks WHERE id=$1;"; }
nagent() { grep -c . "$AGENT_SEND_LOG"; }
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; : >"$CHANNEL_LOG"; : >"$LAST_TEXT"; : >"$LAST_MARKUP"; FAIL_SEND=0
          : >"$AGENT_SEND_LOG"; : >"$LAST_AGENT_TEXT"; : >"$DELIV_LOG"; FAIL_AGENT_SEND=0; }
mk_gate() { # ident tier type asked_modifier ping_modifier options recommend routed
  local ping="NULL"; [[ "$5" != "NULL" ]] && ping="datetime('now','$5')"
  local routed="NULL"; [[ -n "${8:-}" ]] && routed="$(sqlq "$8")"
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at,gate_pinged_at,routed_reviewer)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',$(sqlq "$3"),$2,'choose now',$(sqlq "$6"),$(sqlq "$7"),datetime('now','$4'),${ping},${routed});
      SELECT last_insert_rowid();"
}

# Before one hour: never re-ping.
reset
early=$(mk_gate DIVE-10 2 decision '-30 minutes' '-29 minutes' 'A|B' A '')
_hb_gate_renag_sweep
[[ "$(nsends)" == "0" && "$(pinged "$early")" == "SET" ]] \
  && ok_t "no re-ping before +1h" || bad_t "early gate was re-pinged" "sends=$(nsends)"

# Two gates past +1h collapse into ONE message with working button rows.
reset
g1=$(mk_gate DIVE-11 2 decision '-2 hours' '-119 minutes' 'A|B' A '')
g2=$(mk_gate DIVE-12 2 approval '-2 hours' '-119 minutes' '' approved '')
_hb_gate_renag_sweep
rows=$(jq '.inline_keyboard | length' "$LAST_MARKUP" 2>/dev/null)
grep -q "tna:${g1}:0" "$LAST_MARKUP"; has_d=$?
approval_cb=$(jq -r --arg p "tna:${g2}:approved:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$LAST_MARKUP")
approval_nonce=${approval_cb##*:}
stored=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g2};")
[[ "$(nsends)" == "1" && "$rows" -ge 2 && "$has_d" == "0" && -n "$approval_nonce" && "$stored" == "$(_human_nonce_sha "$approval_nonce")" ]] \
  && ok_t "two +1h gates -> ONE batch with valid per-gate tap buttons" \
  || bad_t "batched buttons invalid" "sends=$(nsends) rows=$rows decision=$has_d approval=$approval_cb"
[[ "$(pinged "$g1")" == "SET" && "$(pinged "$g2")" == "SET" ]] \
  && ok_t "confirmed batch stamps both delivery receipts" || bad_t "batch receipt missing"

# DIVE-2356: the re-nag mint is "hard-human TYPE **or** tier>=2", so g1 — a tier-2
# DECISION, which minted nothing before — now gets a hash rotated in on a confirmed
# send. This sweep is the rescue path for the 43 tier-2 decision gates measured
# nonce-less in DIVE-2355: they acquire evidence on their next reminder instead of
# waiting to be re-filed. Deliberately asserts the STORED HASH only, not a button:
# the decision keyboard still carries no nonce in its callback_data (telegram-pi's
# TNA_RE is greedy and would swallow it), which is why the assertion above for the
# APPROVAL gate can pair callback_data to the hash and this one cannot.
[[ "$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g1};")" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "tier-2 DECISION gate gets a nonce rotated in by the re-nag (DIVE-2356)" \
  || bad_t "tier-2 decision re-nag mint" "hash='$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g1};")'"
# (The tier-1 ANCHOR for this lives at the END of the file: it needs its own
# `reset`, and resetting here would pull the gates out from under the +24h
# throttle assertions that follow.)

# Immediate second tick is idempotent; then a 24h-old reminder stamp re-arms.
: >"$SEND_LOG"
_hb_gate_renag_sweep
[[ "$(nsends)" == "0" ]] && ok_t "no duplicate before 24h" || bad_t "immediate duplicate" "sends=$(nsends)"
db "UPDATE tasks SET need_asked_at=datetime('now','-3 days'), gate_pinged_at=datetime('now','-25 hours');"
_hb_gate_renag_sweep
[[ "$(nsends)" == "1" ]] && ok_t "subsequent reminder fires after 24h" || bad_t "24h reminder missing" "sends=$(nsends)"

# T1 reminder resolves to the org lead's channel. DIVE-2587 moved the DEFAULT for
# an on-chart reviewer onto the agent rail, so this arm now pins the human-channel
# lane explicitly — the routing it grades (which channel a T1 falls back to) is
# still live and is exactly what the rail's fallback and backstop land on.
reset
t1=$(mk_gate DIVE-13 1 decision '-2 hours' '-119 minutes' 'yes|no' yes main)
FIVEDIVE_GATE_RENAG_AGENT_RAIL=0 _hb_gate_renag_sweep
[[ "$(nsends)" == "1" && "$(tail -1 "$CHANNEL_LOG")" == "main" && "$(pinged "$t1")" == "SET" ]] \
  && ok_t "T1 re-nag routes to org lead" \
  || bad_t "T1 route wrong" "sends=$(nsends) channels=$(tr '\n' ',' <"$CHANNEL_LOG")"

# An unconfirmed transport never advances the throttle or rotates the nonce.
reset
bad=$(mk_gate DIVE-14 2 approval '-2 hours' NULL '' approved '')
oldhash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${bad};")
FAIL_SEND=1 _hb_gate_renag_sweep
newhash=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${bad};")
[[ "$(pinged "$bad")" == "NULL" && "$newhash" == "$oldhash" ]] \
  && ok_t "failed re-nag leaves receipt and nonce unchanged for retry" \
  || bad_t "failed re-nag mutated delivery state" "pinged=$(pinged "$bad") old=$oldhash new=$newhash"

# DIVE-2356 ANCHOR (last, because it needs its own `reset`): a tier-1 decision must
# NOT acquire a nonce — the widened condition is tier>=2, not "every decision".
# Green on BOTH the fixed and unfixed tree; red here means the mint over-widened
# and tier-1 gates started dragging human-gate machinery around.
# DIVE-2587 pins the human lane here ON PURPOSE: the mint lives in
# _hb_gate_renag_batch, so letting this gate take the agent rail would make the
# anchor pass because the mint never RAN — a vacuous green on the exact assertion
# that exists to catch an over-widened mint.
reset
t1d=$(mk_gate DIVE-14 1 decision '-2 hours' '-119 minutes' 'A|B' A '')
FIVEDIVE_GATE_RENAG_AGENT_RAIL=0 _hb_gate_renag_sweep
[[ -z "$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${t1d};")" ]] \
  && ok_t "anchor: tier-1 decision gets NO nonce from the re-nag (DIVE-2356)" \
  || bad_t "anchor: tier-1 decision re-nag mint (DIVE-2356)" "over-widened — got a hash"

# ─────────────────────────────────────────────────────────────────────────────
# DIVE-2587 — the re-nag is what converts a correctly lead-routed gate back into
# a human push. Measured on the prod board: the file-time routed rail leaves
# gate_pinged_at NULL and hands off over `5dive agent send`; every T1 gate that
# reached the human that day was stamped at a heartbeat tick with a matching
# `[gate-renag] delivered <row> via <lead>` line. Routing was already correct —
# the lead's PAIRED CHANNEL is the human's phone, so this sweep undid it.
reset
a1=$(mk_gate DIVE-15 1 approval '-2 hours' '-119 minutes' '' approved main)
_hb_gate_renag_sweep
[[ "$(nagent)" == "1" && "$(tail -1 "$AGENT_SEND_LOG")" == "main" \
   && "$(nsends)" == "0" && "$(pinged "$a1")" == "SET" ]] \
  && ok_t "DIVE-2587: an agent-routed T1 re-nag takes the agent rail, no human send" \
  || bad_t "DIVE-2587: agent-routed T1 re-nag still pushed to the human" \
           "agent=$(nagent) human=$(nsends) pinged=$(pinged "$a1")"

# The assertion above passes on an EMPTY message. A reminder the lead cannot act
# on is a buzz, not a handoff — so grade the payload, not just the destination.
grep -q 'DIVE-15' "$LAST_AGENT_TEXT" \
  && ok_t "DIVE-2587: the agent-rail reminder names the gate" \
  || bad_t "DIVE-2587: agent-rail reminder does not name the gate" "text=$(cat "$LAST_AGENT_TEXT")"

# gate_pinged_at is the throttle as well as the receipt. An unstamped agent-rail
# send would re-fire on EVERY tick — trading the human's phone for the lead's
# terminal at 5-minute cadence. Non-differential BY DESIGN: this grades a risk
# that only EXISTS on the fixed tree, so it is paired with a liveness arm below
# rather than with a red on origin/main.
: >"$AGENT_SEND_LOG"; : >"$SEND_LOG"
_hb_gate_renag_sweep
[[ "$(nagent)" == "0" && "$(nsends)" == "0" ]] \
  && ok_t "DIVE-2587: the agent-rail send stamps the receipt, so the next tick is quiet" \
  || bad_t "DIVE-2587: agent rail re-fired on the next tick" "agent=$(nagent) human=$(nsends)"

# LIVENESS for the arm above — "quiet" must mean throttled, not wedged. Drop the
# receipt and the same sweep fires again, so the zero above is the stamp's doing.
db "UPDATE tasks SET gate_pinged_at=NULL WHERE id=${a1};"
_hb_gate_renag_sweep
[[ "$(nagent)" == "1" ]] \
  && ok_t "DIVE-2587: clearing the receipt re-arms the rail (the quiet tick was throttled, not dead)" \
  || bad_t "DIVE-2587: rail did not re-fire after the receipt was cleared" "agent=$(nagent)"

# A rail that cannot deliver hands its rows BACK to the human channel. This is
# the property that makes the change quieting rather than silencing.
reset
a2=$(mk_gate DIVE-16 1 approval '-2 hours' '-119 minutes' '' approved main)
FAIL_AGENT_SEND=1 _hb_gate_renag_sweep
[[ "$(nagent)" == "1" && "$(nsends)" == "1" && "$(tail -1 "$CHANNEL_LOG")" == "main" \
   && "$(pinged "$a2")" == "SET" ]] \
  && ok_t "DIVE-2587: a failed agent rail falls back to the human channel — never dropped" \
  || bad_t "DIVE-2587: failed agent rail dropped the gate" \
           "agent=$(nagent) human=$(nsends) pinged=$(pinged "$a2")"

# The backstop: in-band nagging that has not worked for a day stops being quiet.
reset
a3=$(mk_gate DIVE-17 1 approval '-30 hours' '-25 hours' '' approved main)
_hb_gate_renag_sweep
[[ "$(nagent)" == "0" && "$(nsends)" == "1" ]] \
  && ok_t "DIVE-2587: past the 24h backstop the gate reaches the human again" \
  || bad_t "DIVE-2587: backstop did not surface a day-old lead-routed gate" \
           "agent=$(nagent) human=$(nsends)"

# One reviewer, one fresh gate and one stale one: the age split must send BOTH,
# on their own rails. A split that loses a row is the failure this arm exists for.
reset
m1=$(mk_gate DIVE-18 1 approval '-2 hours' '-119 minutes' '' approved main)
m2=$(mk_gate DIVE-19 1 approval '-30 hours' '-25 hours' '' approved main)
_hb_gate_renag_sweep
[[ "$(nagent)" == "1" && "$(nsends)" == "1" \
   && "$(pinged "$m1")" == "SET" && "$(pinged "$m2")" == "SET" ]] \
  && ok_t "DIVE-2587: a mixed-age batch splits across both rails, losing neither" \
  || bad_t "DIVE-2587: mixed-age batch lost a row" \
           "agent=$(nagent) human=$(nsends) fresh=$(pinged "$m1") stale=$(pinged "$m2")"

# Only an agent has a terminal to read the rail in. A reviewer who is not on the
# org chart keeps the human channel.
reset
n1=$(mk_gate DIVE-20 1 approval '-2 hours' '-119 minutes' '' approved ghost)
_hb_gate_renag_sweep
[[ "$(nagent)" == "0" && "$(nsends)" == "1" && "$(tail -1 "$CHANNEL_LOG")" == "ghost" ]] \
  && ok_t "DIVE-2587: an off-chart reviewer is not an agent — human channel kept" \
  || bad_t "DIVE-2587: off-chart reviewer took the agent rail" \
           "agent=$(nagent) human=$(nsends)"

# Off-switch restores the pre-2587 behaviour exactly (and is what the two arms
# above pin, so it must be load-bearing rather than decorative).
reset
o1=$(mk_gate DIVE-21 1 approval '-2 hours' '-119 minutes' '' approved main)
FIVEDIVE_GATE_RENAG_AGENT_RAIL=0 _hb_gate_renag_sweep
[[ "$(nagent)" == "0" && "$(nsends)" == "1" ]] \
  && ok_t "DIVE-2587: FIVEDIVE_GATE_RENAG_AGENT_RAIL=0 restores the human ping" \
  || bad_t "DIVE-2587: off-switch did not restore the human ping" \
           "agent=$(nagent) human=$(nsends)"

# ANCHOR — the T2 human floor is NOT what is being changed. A tier-2 gate goes to
# the paired human whatever its filer's org position; this arm is green on both
# trees and reds only if the rail ever widened past tier 1.
reset
z1=$(mk_gate DIVE-22 2 approval '-2 hours' '-119 minutes' '' approved '')
_hb_gate_renag_sweep
[[ "$(nagent)" == "0" && "$(nsends)" == "1" ]] \
  && ok_t "anchor: the T2 human floor still re-nags the paired human (DIVE-2587)" \
  || bad_t "anchor: the agent rail leaked into the T2 floor (DIVE-2587)" \
           "agent=$(nagent) human=$(nsends)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
