#!/usr/bin/env bash
# DIVE-4725 — an ANSWERED gate re-nag must not be typed into a seat minutes later.
#
# MEASURED 2026-09-21 (/var/log/5dive-heartbeat.log + the board): the heartbeat
# logged `[gate-renag] delivered 4906 via agent rail to ops` at 00:05:04Z; ops
# answered that gate (DIVE-4719) at 00:05:11Z; ops was mid-turn, so the send was
# SPOOLED (DIVE-4214) and the drain typed it at 00:10:36Z — five minutes after
# the gate closed, and against a `5dive task queue` that read "ops: no gates
# routed to you are waiting." The same window shows the recipient draining five
# spooled messages at 00:06:04, 00:06:18, 00:10:36, 00:11:38 and 00:13:38, which
# is where the repeat is introduced: NOT a sender re-invocation, and not a
# re-presentation of an already-typed message (the flush unlinks before typing),
# but the spool holding sends until long after they stopped being true.
#
# THE FIX: the re-nag rides the DIVE-4295 guard sidecar, re-running at delivery
# the SAME `need_answered_at IS NULL` clause the sweep selected on and that
# `task queue` reads. Nothing about the sweep's own selection changes.
#
# WHAT THIS GRADES:
#   A. an all-answered batch is DROPPED (rc 1);
#   B. NEGATIVE — a mixed batch still DELIVERS (rc 0): only all-answered drops;
#   C. NEGATIVE — a closed row's gate reads as answered for this purpose;
#   D. NEGATIVE — a malformed id list is UNEVALUATED (rc 2), never a drop;
#   E. NEGATIVE — a db that does not answer is UNEVALUATED (rc 2);
#   F. the guard carries NO ownership clause — a gate routed to a reviewer who
#      is not the assignee still delivers;
#   G. end-to-end: a spooled re-nag with an all-answered guard is unlinked and
#      never typed, and the drop is logged;
#   H. NEGATIVE — the same spooled message with no sidecar is delivered
#      (every pre-existing a2a caller is byte-identical);
#   I. the re-nag rail ATTACHES the guard, with the sweep's own id list.
#
# MUTATIONS (the acceptance, each run against this file):
#   drop the _A2A_GUARD prefix in _hb_gate_renag_agent_rail -> I reds;
#   delete the `need_answered_at IS NULL` clause from the gate_unanswered
#     branch -> A reds; delete the branch entirely -> A, F and G red.
# Against origin/main every one of A, F, G and I reds — the cond does not exist.
#
# Boundaries only are stubbed: sudo/tmux, the DB and the idle predicate.
# _a2a_guard_holds, a2a_queue_flush_one and _hb_gate_renag_agent_rail stay REAL.
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
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-4725}"; echo "HARNESS-RC=$rc"' EXIT
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
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { return 0; }
_hb_log() { printf '%s\n' "$*" >>"$LOG"; }
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
_hb_agent_idle() { return 0; }
inject_and_submit() { printf '%s\n' "$2" >>"$TYPED"; return 0; }
_task_gate_delivery_log() { return 0; }
sqlq() { printf "'%s'" "${1//\'/\'\'}"; }

# OPEN: the set of task ids whose gate is open AND unanswered, i.e. what the
# board would return. DBFAIL forces an unreadable read.
OPEN=""
DBFAIL=0
DBGARBAGE=0
db() {
  local q="$1" ids id n=0
  (( DBFAIL )) && return 1
  if [[ "$q" == *"need_answered_at IS NULL"* && "$q" == *"COUNT(*)"* ]]; then
    (( DBGARBAGE )) && { printf 'not-a-number\n'; return 0; }
    ids="$(sed -n 's/.*id IN (\([0-9,]*\)).*/\1/p' <<<"${q//$'\n'/ }")"
    for id in ${ids//,/ }; do
      [[ " ${OPEN} " == *" ${id} "* ]] && n=$((n+1))
    done
    printf '%s\n' "$n"; return 0
  fi
  # _hb_gate_renag_agent_rail's org-chart check and its row renderer.
  if [[ "$q" == *"agents_org"* ]]; then printf 'ops\n'; return 0; fi
  if [[ "$q" == *"FROM tasks WHERE id IN"* ]]; then printf '[DIVE-4719] approval — ship it?\n'; return 0; fi
  printf '\n'
}

G() { printf 'task:%s:%s:gate_unanswered' "$1" "${2:-ops}"; }
rcof() { local rc=0; "$@" || rc=$?; printf '%s' "$rc"; }

# --- A: every gate in the batch is answered ---------------------------------
OPEN=""
is "A: an all-answered re-nag batch is dropped" "1" "$(rcof _a2a_guard_holds "$(G 4906)")"
is "A: a multi-row all-answered batch is dropped too" "1" "$(rcof _a2a_guard_holds "$(G 4906,4910,4913)")"

# --- B: NEGATIVE — a mixed batch still says something ------------------------
OPEN="4910"
is "B: a batch with one gate still open is DELIVERED" "0" "$(rcof _a2a_guard_holds "$(G 4906,4910,4913)")"
OPEN="4906"
is "B: the still-open row may be the first in the list" "0" "$(rcof _a2a_guard_holds "$(G 4906,4910)")"

# --- C: NEGATIVE — a done/cancelled row is not an open gate ------------------
# The db stub answers from OPEN, which the real clause derives with
# `status NOT IN ('done','cancelled')` — so a closed row is simply not in it.
OPEN=""
is "C: a gate on a closed row does not hold the message open" "1" "$(rcof _a2a_guard_holds "$(G 4906)")"

# --- D: NEGATIVE — a malformed id list is unevaluated, never a drop ----------
OPEN=""
is "D: a non-numeric id list is unevaluated (rc 2)" "2" "$(rcof _a2a_guard_holds "$(G DIVE-4719)")"
is "D: an empty id list is unevaluated (rc 2)" "2" "$(rcof _a2a_guard_holds "task::ops:gate_unanswered")"
is "D: a trailing comma is unevaluated (rc 2)" "2" "$(rcof _a2a_guard_holds "$(G 4906,)")"

# --- E: NEGATIVE — an unreadable board is unevaluated ------------------------
DBFAIL=1
is "E: a db that does not answer is unevaluated (rc 2)" "2" "$(rcof _a2a_guard_holds "$(G 4906)")"
DBFAIL=0
DBGARBAGE=1
is "E: a non-numeric count is unevaluated (rc 2)" "2" "$(rcof _a2a_guard_holds "$(G 4906)")"
DBGARBAGE=0

# --- F: NEGATIVE — no ownership clause: the reviewer is not the assignee -----
# The existing conds all AND assignee=<seat>; a gate is routed to a REVIEWER who
# routinely is not. The seat field is carried for the record and not queried.
OPEN="4906"
is "F: an open gate routed to a non-assignee reviewer still delivers" "0" \
   "$(rcof _a2a_guard_holds "$(G 4906 somebody-else)")"

# --- G: end-to-end through the spool ----------------------------------------
spool() {  # spool <seat> <n> <payload> [guard]
  local seat="$1" n="$2" payload="$3" guard="${4:-}" dir
  dir="$(_a2a_queue_dir "$seat")"
  mkdir -p "$dir"
  printf '%s' "$payload" >"${dir}/$(printf '%03d' "$n")-x.msg"
  [[ -n "$guard" ]] && printf '%s' "$guard" >"${dir}/$(printf '%03d' "$n")-x.guard"
  return 0
}
depth() { find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reset_spool() { rm -rf "${TMPROOT}/agent-${1}"; : >"$TYPED"; : >"$LOG"; }
RENAG='[5dive-msg from=main id=r1 tier=admin] 🔁 Gate reminder — gate(s) routed to you for review, still unanswered:
• [DIVE-4719] approval — ship it?'

reset_spool ops
OPEN=""
spool ops 1 "$RENAG" "$(G 4906)"
rc=0; a2a_queue_flush_one ops || rc=$?
is "G: an answered re-nag is not typed into the seat" "" "$(cat "$TYPED")"
is "G: it is unlinked from the spool" "0" "$(depth ops)"
is "G: and the call reports no delivery (rc 1)" "1" "$rc"
grep -q 'guard no longer holds' "$LOG" \
  && ok_t "G: the drop is logged with the guard that stopped it" \
  || bad_t "G: the drop is logged" "log=[$(cat "$LOG")]"

# --- H: NEGATIVE — no sidecar, unconditional delivery ------------------------
reset_spool ops
OPEN=""
spool ops 1 "$RENAG"
rc=0; a2a_queue_flush_one ops || rc=$?
grep -q 'Gate reminder' "$TYPED" \
  && ok_t "H: the same message with NO guard sidecar is delivered unconditionally" \
  || bad_t "H: an unguarded message must deliver" "typed=[$(cat "$TYPED")] log=[$(cat "$LOG")]"
is "H: and reports the delivery (rc 0)" "0" "$rc"

# --- I: the rail attaches the guard -----------------------------------------
: >"$SENT"
cmd_send() { printf 'GUARD=%s ARGS=%s\n' "${_A2A_GUARD:-<unset>}" "$*" >>"$SENT"; return 0; }
_task_agent_channel() { return 0; }
_hb_gate_renag_agent_rail ops "4906,4910" >/dev/null 2>&1 || true
grep -q 'GUARD=task:4906,4910:ops:gate_unanswered' "$SENT" \
  && ok_t "I: the re-nag rail attaches the guard, carrying the sweep's own id list" \
  || bad_t "I: the re-nag rail attaches the guard" "sent=[$(cat "$SENT")]"
grep -q 'Gate reminder' "$SENT" \
  && ok_t "I: and the message itself is unchanged" \
  || bad_t "I: the message is unchanged" "sent=[$(cat "$SENT")]"
is "I: _A2A_GUARD does not leak past the call" "" "${_A2A_GUARD:-}"

# --- J: the branch's row count stays inside the function --------------------
# Asked for by the DIVE-4725 grade. `n` is declared BOTH at the function top
# (pre-existing, shared with the graded-handoff clause) and now at the point of
# use, so this arm passes at origin/main too: it is a scope REGRESSION guard,
# not a discriminator for this fix. It reds only if BOTH declarations go. The
# call and the read must sit in the SAME shell — wrapping either in $( ) makes
# the arm vacuous, because a leaked global cannot cross a subshell back.
db() { echo 2; }
n_before="${n-unset}"
_a2a_guard_holds "task:4906,4910:ops:gate_unanswered" >/dev/null 2>&1 || true
is "J: the gate_unanswered count does not leak into the caller" "$n_before" "${n-unset}"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
