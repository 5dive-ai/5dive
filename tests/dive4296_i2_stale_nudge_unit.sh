#!/usr/bin/env bash
# DIVE-4296 iteration 2 — the two arms main added to the row AFTER iteration 1
# was delivered, both about a machine nudge that is correct when written and
# false by the time it is typed.
#
# DO 5 (main 09:19Z, from lodar 09:18Z "are these messages important? i thought
# we use only tasks queue for that?"): the answered-gate arm of the stall sweep
# sent an a2a ping to the verifier. DIVE-4253 made a gate-answered row
# dispatchable through the queue again, so the ping became a duplicate of the
# tick's own pick — and a late one: it fired for DIVE-4276 101 minutes after the
# answer, at a seat that no longer graded that row. The send is deleted; the
# stamp and the log line stay.
#
# STALE-DROP (main 10:10Z + 10:20Z, live specimen quinn 10:00Z "Fifth false wake.
# DIVE-4284 was closed four minutes before the message reached me"): before
# typing a spooled `from=task-engine` payload, re-derive the row it names. Drop
# it when the row is done/cancelled, when it is no longer assigned to the
# recipient, or when a newer nudge for the same row sits behind it. Never drop a
# human- or agent-authored payload, and never drop on a read that did not answer.
#
# WHAT THIS GRADES:
#   H. an answered gate produces NO a2a send, and still stamps + logs;
#   I. a nudge naming a done row is dropped, logged, and not typed;
#   J. cancelled reads the same as done;
#   K. a nudge for a row that has moved to another seat is dropped;
#   L. of two nudges for the same row, the older is dropped and the newer typed;
#   M. NEGATIVE — a human-authored payload naming a done row is NEVER dropped;
#   N. NEGATIVE — a live row still assigned to this seat is delivered;
#   O. NEGATIVE — an unreadable/unknown row is delivered (fails open);
#   P. NEGATIVE — the predicate absent (runtime-only context) delivers;
#   Q. an all-stale spool empties without delivering anything.
#
# MUTATIONS (the acceptance): restore either cmd_send in the (a4) block -> H reds.
# Delete the assignee clause -> K reds. Delete the newer-duplicate loop -> L reds.
# Drop the `from=task-engine` guard in _a2a_nudge_ident -> M reds.
#
# Boundaries only are stubbed: sudo/tmux/systemd, the DB and the idle predicate.
# _a2a_nudge_ident, _a2a_stale_nudge_reason, a2a_queue_flush_one and the (a4)
# block of _hb_stall_sweep stay REAL.
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/lib/validation.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh
# shellcheck disable=SC1091
source src/cmd_heartbeat.sh

PASS=0; FAIL=0
TMPROOT="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-4296i2}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() { local l="$1" w="$2" g="$3"; if [[ "$g" == "$w" ]]; then ok_t "$l"; else bad_t "$l" "want=[$w] got=[$g]"; fi; }

TYPED="${TMPROOT}/typed.log"
SENT="${TMPROOT}/sent.log"
LOG="${TMPROOT}/hb.log"
: >"$TYPED"; : >"$SENT"; : >"$LOG"

# --- boundaries -------------------------------------------------------------
require_root() { :; }
fail() { printf 'FAILCALL %s\n' "${2:-}" >&2; return 1; }
systemctl() { return 0; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { [[ "${1:-}" == "has-session" ]] && return 0; return 0; }
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
_hb_agent_idle() { return 0; }
# What actually reached the seat. a2a_queue_flush_one's delivery funnel.
inject_and_submit() { printf '%s\n' "$2" >>"$TYPED"; return 0; }
# Any a2a send from the stall sweep.
cmd_send() { printf 'SEND %s\n' "$*" >>"$SENT"; return 0; }

# ROWS: the fixture the db stub answers from. ident -> "status<US>assignee".
declare -A ROWS=()
db() {
  local q="$1" k
  # The (a4) answered-gate query — driven only when A4_ROW is set.
  if [[ "$q" == *"gate_answered_nudged_at IS NULL"* ]]; then
    printf '%s\n' "${A4_ROW:-}"; return 0
  fi
  if [[ "$q" == *"gate_answered_nudged_at=datetime"* ]]; then
    printf 'STAMP\n' >>"$LOG"; return 0
  fi
  # The staleness lookup: pull the quoted ident back out of the statement.
  if [[ "$q" == *"COALESCE(ident,'DIVE-'||id)="* ]]; then
    k="$(grep -m1 -oE "DIVE-[0-9]+" <<<"$q" 2>/dev/null)" || k=""
    printf '%s\n' "${ROWS[${k:-none}]:-}"
    return 0
  fi
  printf '\n'
}
sqlq() { printf "'%s'" "${1//\'/\'\'}"; }

spool() {  # spool <seat> <n> <payload>  — n orders the file names
  local seat="$1" n="$2" payload="$3" dir
  dir="$(_a2a_queue_dir "$seat")"
  mkdir -p "$dir"
  printf '%s' "$payload" >"${dir}/$(printf '%03d' "$n")-x.msg"
}
depth() { local dir; dir="$(_a2a_queue_dir "$1")"; find "$dir" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l; }
reset_spool() { rm -rf "${TMPROOT}/agent-${1}"; : >"$TYPED"; : >"$LOG"; }
NUDGE() { printf '[5dive-msg from=task-engine id=n%s tier=admin] %s: pick it back up.' "$1" "$2"; }
HUMAN() { printf '[5dive-msg from=lodar id=h%s tier=admin] %s: what happened here?' "$1" "$2"; }

# --- H: an answered gate sends nothing --------------------------------------
: >"$SENT"; : >"$LOG"
A4_ROW="$(printf '77\x1fDIVE-4276\x1fquinn\x1f2026-09-11 05:38:30')"
_hb_stall_sweep >/dev/null 2>&1 || true
unset A4_ROW
is "H: the answered-gate arm sends no a2a at all" "" "$(grep -c 'SEND' "$SENT" | tr -d ' ' | sed 's/^0$//')"
grep -q 'STAMP' "$LOG" && ok_t "H: the row is still stamped (the sweep will not re-examine it)" \
  || bad_t "H: the row is still stamped" "$(cat "$LOG")"
grep -q 'left to the queue' "$LOG" && ok_t "H: the log says the queue owns the delivery now" \
  || bad_t "H: the log says the queue owns the delivery now" "$(cat "$LOG")"

# --- I/J: a nudge for a closed row is dropped -------------------------------
for st in done cancelled; do
  reset_spool quinn
  ROWS=([DIVE-4284]="$(printf '%s\x1fquinn' "$st")")
  spool quinn 1 "$(NUDGE 1 DIVE-4284)"
  a2a_queue_flush_one quinn && rc=0 || rc=$?
  lbl="I: a nudge naming a ${st} row"
  [[ "$st" == cancelled ]] && lbl="J: a nudge naming a ${st} row"
  is "${lbl} is not typed" "" "$(cat "$TYPED")"
  is "${lbl} is unlinked from the spool" "0" "$(depth quinn)"
  is "${lbl} reports no delivery (rc 1)" "1" "$rc"
  grep -q "dropped stale spooled nudge (DIVE-4284 is ${st})" "$LOG" \
    && ok_t "${lbl} logs the drop and the reason" \
    || bad_t "${lbl} logs the drop and the reason" "$(cat "$LOG")"
done

# --- K: the row has moved to another seat -----------------------------------
reset_spool quinn
ROWS=([DIVE-4288]="$(printf 'todo\x1fops')")
spool quinn 1 "$(NUDGE 1 DIVE-4288)"
a2a_queue_flush_one quinn || true
is "K: a nudge for a row now on another seat is not typed" "" "$(cat "$TYPED")"
grep -q 'dropped stale spooled nudge (DIVE-4288 is now on ops)' "$LOG" \
  && ok_t "K: the drop names the seat that holds it now" \
  || bad_t "K: the drop names the seat that holds it now" "$(cat "$LOG")"

# --- L: a newer nudge for the same row is already behind it -----------------
reset_spool quinn
ROWS=([DIVE-4293]="$(printf 'todo\x1fquinn')")
spool quinn 1 "$(NUDGE old DIVE-4293)"
spool quinn 2 "$(NUDGE new DIVE-4293)"
a2a_queue_flush_one quinn || true
grep -q 'id=nnew' "$TYPED" && ok_t "L: the NEWER of two nudges for one row is the one typed" \
  || bad_t "L: the NEWER of two nudges for one row is the one typed" "typed=[$(cat "$TYPED")]"
grep -q 'id=nold' "$TYPED" && bad_t "L: the older duplicate is not typed" "typed=[$(cat "$TYPED")]" \
  || ok_t "L: the older duplicate is not typed"
is "L: one call clears both (drop + deliver), spool empty" "0" "$(depth quinn)"
grep -q 'a newer nudge for DIVE-4293 is already spooled behind it' "$LOG" \
  && ok_t "L: the drop reason names the duplicate" \
  || bad_t "L: the drop reason names the duplicate" "$(cat "$LOG")"

# --- M: NEGATIVE — a human payload is never dropped -------------------------
reset_spool quinn
ROWS=([DIVE-4284]="$(printf 'done\x1fops')")
spool quinn 1 "$(HUMAN 1 DIVE-4284)"
a2a_queue_flush_one quinn || true
grep -q 'from=lodar' "$TYPED" \
  && ok_t "M: a human-authored message naming a done row on another seat is STILL delivered" \
  || bad_t "M: a human-authored message is still delivered" "typed=[$(cat "$TYPED")] log=[$(cat "$LOG")]"

# --- N: NEGATIVE — a live row on this seat is delivered ---------------------
reset_spool quinn
ROWS=([DIVE-4300]="$(printf 'todo\x1fquinn')")
spool quinn 1 "$(NUDGE 1 DIVE-4300)"
a2a_queue_flush_one quinn && rc=0 || rc=$?
grep -q 'DIVE-4300' "$TYPED" && ok_t "N: a live row still assigned to this seat is delivered" \
  || bad_t "N: a live row still assigned to this seat is delivered" "typed=[$(cat "$TYPED")]"
is "N: the delivery is reported (rc 0)" "0" "$rc"

# --- O: NEGATIVE — unknown row, the read did not answer ---------------------
reset_spool quinn
ROWS=()
spool quinn 1 "$(NUDGE 1 DIVE-9999)"
a2a_queue_flush_one quinn || true
grep -q 'DIVE-9999' "$TYPED" \
  && ok_t "O: a row the db does not answer for is DELIVERED — the predicate fails open" \
  || bad_t "O: fails open on an unanswered read" "typed=[$(cat "$TYPED")] log=[$(cat "$LOG")]"

# --- P: NEGATIVE — predicate absent (runtime-only context) ------------------
reset_spool quinn
ROWS=([DIVE-4284]="$(printf 'done\x1fquinn')")
spool quinn 1 "$(NUDGE 1 DIVE-4284)"
_saved="$(declare -f _a2a_stale_nudge_reason)"
unset -f _a2a_stale_nudge_reason
a2a_queue_flush_one quinn || true
eval "$_saved"
grep -q 'DIVE-4284' "$TYPED" \
  && ok_t "P: with the predicate unloaded the message is DELIVERED, never dropped" \
  || bad_t "P: unloaded predicate must deliver" "typed=[$(cat "$TYPED")]"

# --- Q: an all-stale spool empties and delivers nothing ---------------------
reset_spool quinn
ROWS=([DIVE-4284]="$(printf 'done\x1fquinn')" [DIVE-4288]="$(printf 'todo\x1fops')")
spool quinn 1 "$(NUDGE 1 DIVE-4284)"
spool quinn 2 "$(NUDGE 2 DIVE-4288)"
spool quinn 3 "$(NUDGE 3 DIVE-4284)"
a2a_queue_flush_one quinn && rc=0 || rc=$?
is "Q: an all-stale spool types nothing" "" "$(cat "$TYPED")"
is "Q: an all-stale spool is emptied in one call" "0" "$(depth quinn)"
is "Q: and reports no delivery (rc 1)" "1" "$rc"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
