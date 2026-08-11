#!/usr/bin/env bash
# DIVE-1499: `task inbox --send` — owner digest with working per-gate tap
# buttons, nonce never on stdout, hash rotation only after confirmed delivery.
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
TMP=$(mktemp -d /tmp/inbox-send.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
# DIVE-1506: this harness deliberately exercises the human-send path, so declare its
# isolated DB as the prod DB (positive allowlist) to pass the fail-closed fixture guard.
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"
tasks_db_init; _tasks_db_migrate

ACCESS="$TMP/access.json"
printf '{"allowFrom":["1234567890"]}' >"$ACCESS"

SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
LAST_TEXT="$TMP/text"; LAST_MARKUP="$TMP/markup"
ALL_TEXT="$TMP/all-text"; ALL_MARKUP="$TMP/all-markup"
FAIL_SEND=0
_task_owner_channel() {
  TASK_CH_TYPE=claude TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS"
  return 0
}
_task_send_owner() {
  local text="$1" markup="$2" ids="$3"
  printf '%s\n' "$ids" >>"$SEND_LOG"
  printf '%s' "$text" >"$LAST_TEXT"; printf '%s' "$markup" >"$LAST_MARKUP"
  printf '%s\n' "$text" >>"$ALL_TEXT"; printf '%s\n' "$markup" >>"$ALL_MARKUP"
  TASK_SEND_MESSAGE_IDS="901"
  if [[ "$FAIL_SEND" == "1" ]]; then TASK_SEND_DELIVERED=0; return 0; fi
  TASK_SEND_DELIVERED=1
}
require_root() { :; }
audit_log() { :; }

PASS=0; FAIL=0
ok_t() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
nsends() { grep -c . "$SEND_LOG"; }
reset() { db "DELETE FROM tasks;"; : >"$SEND_LOG"; : >"$LAST_TEXT"; : >"$LAST_MARKUP"; : >"$ALL_TEXT"; : >"$ALL_MARKUP"; FAIL_SEND=0; }
mk_gate() { # ident type options recommend
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,need_options,recommend,need_asked_at)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',$(sqlq "$2"),2,'choose now',$(sqlq "$3"),$(sqlq "$4"),datetime('now'));
      SELECT last_insert_rowid();"
}

# Empty inbox: reports cleanly, sends nothing.
reset
out=$(cmd_task_inbox --send 2>&1); rc=$?
[[ "$rc" == "0" && "$(nsends)" == "0" && "$out" == *"nothing to send"* ]] \
  && ok_t "empty inbox sends nothing" || bad_t "empty inbox misbehaved" "rc=$rc out=$out"

# Mixed gate types: DIVE-2712 — ONE MESSAGE PER GATE (lodar, 2026-08-04: answering a
# gate retires the keyboard of the message that delivered it, so a shared digest lost
# every gate's buttons at once). The properties these arms guard are UNCHANGED — every
# gate reachable by a working button, hashes stored, raw nonce never on stdout — only
# their SCOPE moves from the single digest to the set of messages.
reset
g1=$(mk_gate DIVE-21 decision 'A|B' A)
g2=$(mk_gate DIVE-22 approval '' approved)
g3=$(mk_gate DIVE-23 manual '' '')
out=$(cmd_task_inbox --send --channel-proof=1234567890 2>&1); rc=$?
approval_cb=$(jq -r --arg p "tna:${g2}:approved:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$ALL_MARKUP")
approval_nonce=${approval_cb##*:}
manual_cb=$(jq -r --arg p "tna:${g3}:done:" '[.inline_keyboard[][] | .callback_data | select(startswith($p))][0] // empty' "$ALL_MARKUP")
manual_nonce=${manual_cb##*:}
h2=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g2};")
h3=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g3};")
grep -q "tna:${g1}:0" "$ALL_MARKUP"; has_d=$?
[[ "$rc" == "0" && "$(nsends)" == "3" && "$has_d" == "0" \
   && -n "$approval_nonce" && "$h2" == "$(_human_nonce_sha "$approval_nonce")" \
   && -n "$manual_nonce"   && "$h3" == "$(_human_nonce_sha "$manual_nonce")" ]] \
  && ok_t "THREE messages (one per gate), working decision+approval+manual buttons, hashes stored" \
  || bad_t "per-gate buttons invalid" "rc=$rc sends=$(nsends) d=$has_d a=$approval_cb m=$manual_cb"
grep -q "DIVE-21" "$ALL_TEXT" && grep -q "DIVE-22" "$ALL_TEXT" && grep -q "DIVE-23" "$ALL_TEXT" \
  && ok_t "every gate appears in some message's text" || bad_t "a gate appears in NO message" \
       "sends=$(nsends) all_text=$(wc -l <"$ALL_TEXT")"
if [[ -n "$approval_nonce" && "$out" != *"$approval_nonce"* && "$out" != *"$manual_nonce"* ]]; then
  ok_t "raw nonce never printed to stdout"
else
  bad_t "nonce leaked to stdout" "out=$out"
fi

# Unconfirmed delivery: command fails, hashes NOT rotated.
reset
g4=$(mk_gate DIVE-24 approval '' '')
FAIL_SEND=1
out=$(cmd_task_inbox --send 2>&1); rc=$?
h4=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE id=${g4};")
[[ "$rc" != "0" && -z "$h4" ]] \
  && ok_t "unconfirmed delivery fails and leaves hash unrotated" \
  || bad_t "fail-closed path broken" "rc=$rc hash=$h4"

# Bad channel-proof: refused before any send.
reset
mk_gate DIVE-25 decision 'A|B' A >/dev/null
out=$(cmd_task_inbox --send --channel-proof=999 2>&1); rc=$?
[[ "$rc" != "0" && "$(nsends)" == "0" ]] \
  && ok_t "unallowlisted channel-proof refused" || bad_t "bad proof accepted" "rc=$rc out=$out"

# Cap: 12 gates -> 10 sent, overflow noted.
reset
for i in $(seq 31 42); do mk_gate "DIVE-${i}" decision 'A|B' A >/dev/null; done
out=$(cmd_task_inbox --send 2>&1); rc=$?
n_ids=$(grep -c '^[0-9]' "$SEND_LOG")
grep -q "and 2 more" "$LAST_TEXT"; has_more=$?
[[ "$rc" == "0" && "$n_ids" == "10" && "$has_more" == "0" ]] \
  && ok_t "digest caps at 10 gates and notes the overflow" \
  || bad_t "cap broken" "rc=$rc gate_messages=$n_ids more=$has_more sends=$(nsends)"

# ---------------------------------------------------------------------------
# DIVE-3117 part 2 — the human inbox must not list a gate that is waiting on an
# AGENT. Every arm below is graded by MUTATION on `routed_reviewer`, the field
# the view actually reads: the SAME row is listed, one field is flipped, and the
# listing must change. An arm that seeds two different rows would pass against a
# filter keyed on anything those rows happen not to share.
# Note the fixtures above all carry tier=2 with no routed_reviewer, so they are
# untouched by this clause by construction — that is itself the tier-2 negative
# control, restated explicitly below rather than left implicit.
mk_rgate() { # ident type tier routed_reviewer needs_capability   (tier: '' => NULL, "''" => empty string)
  local _tier; case "$3" in '') _tier=NULL ;; "''") _tier="''" ;; *) _tier="$(sqlq "$3")" ;; esac
  db "INSERT INTO tasks (ident,title,priority,assignee,created_by,kind,status,need_type,tier,ask,recommend,need_asked_at,routed_reviewer,needs_capability)
      VALUES ($(sqlq "$1"),'gate','high','dev','dev','standard','blocked',$(sqlq "$2"),${_tier},'approve delegated push for review',
              'approve',datetime('now'),$(sqlq_or_null "$4"),$(sqlq_or_null "$5"));
      SELECT last_insert_rowid();"
}
inbox_idents() { ( JSON_MODE=1; cmd_task_inbox 2>/dev/null | jq -r '.data.inbox[].ident' | sort | tr '\n' ' ' ); }
inbox_routed_n() { ( JSON_MODE=1; cmd_task_inbox 2>/dev/null | jq -r '.data.routed_elsewhere' ); }

# THE MUTATION ARM. One row, one field. Unrouted -> listed; routed to an agent
# seat -> gone. This is DIVE-2159/DIVE-2245's exact shape: type=approval, tier 1,
# routed_reviewer=main2, correctly routed and listing for a human anyway.
reset
r1=$(mk_rgate DIVE-2159 approval 1 '' '')
before=$(inbox_idents)
db "UPDATE tasks SET routed_reviewer='main2' WHERE id=${r1};"
after=$(inbox_idents)
[[ "$before" == "DIVE-2159 " && "$after" == "" ]] \
  && ok_t "MUTATION: flipping routed_reviewer on ONE row takes it out of the human inbox" \
  || bad_t "routed_reviewer mutation did not change the listing" "before='$before' after='$after'"

# The withheld gate is COUNTED, not merely absent — an inbox that went quiet must
# not read the same as a fleet with no open gates.
[[ "$(inbox_routed_n)" == "1" ]] \
  && ok_t "a withheld routed gate is counted in routed_elsewhere" \
  || bad_t "routed_elsewhere miscounted" "got=$(inbox_routed_n)"
out=$(cmd_task_inbox 2>&1)
[[ "$out" == *"routed to an agent seat"* ]] \
  && ok_t "prose inbox names the withheld count instead of reading empty" \
  || bad_t "withheld gates are silently absent from the prose inbox" "out=$out"

# NEGATIVE 1 — tier 2 is a hard gate: routed or not, it stays on the human's list.
# Same mutation, opposite verdict, so the arm cannot pass by the filter being off.
reset
r2=$(mk_rgate DIVE-2245 approval 2 '' '')
before=$(inbox_idents)
db "UPDATE tasks SET routed_reviewer='main2' WHERE id=${r2};"
after=$(inbox_idents)
# NOTE the assertion is the LISTING only. An earlier draft also required
# routed_elsewhere==0 here, which reds this control on pristine main for a reason
# that has nothing to do with its subject (the field does not exist there yet) —
# a negative control has to be green on BOTH trees or it is not a control. The
# counter gets its own positive arm below.
[[ "$before" == "DIVE-2245 " && "$after" == "DIVE-2245 " ]] \
  && ok_t "NEGATIVE: a tier-2 gate keeps listing when routed to an agent" \
  || bad_t "a tier-2 routed gate was hidden from the human" "before='$before' after='$after'"
[[ "$(inbox_routed_n)" == "0" ]] \
  && ok_t "a tier-2 routed gate is not counted as withheld" \
  || bad_t "tier-2 routed gate counted as withheld" "got=$(inbox_routed_n)"

# NEGATIVE 2 — a declared human capability keeps listing even at tier 1 and even
# routed. Production cannot reach that state today (--needs forces tier 2 and
# _routable=0), so this arm seeds it directly: it grades the CLAUSE, which is
# there precisely so a change to that faraway floor cannot silently hide a
# human-capability gate.
reset
mk_rgate DIVE-2246 approval 1 'main2' 'human_tap' >/dev/null
[[ "$(inbox_idents)" == "DIVE-2246 " ]] \
  && ok_t "NEGATIVE: needs_capability keeps a routed tier-1 gate on the human's list" \
  || bad_t "a declared human-capability gate was hidden" "idents=$(inbox_idents)"

# NEGATIVE 3 — an UNKNOWN tier reads as 2 and stays visible. The fail-safe
# direction: one gate too many is recoverable, a hidden one is the defect.
# BOTH unknowns, because they are not the same value in SQLite: `tier` is
# INTEGER-affinity but nullable, and an empty string is stored as TEXT '' rather
# than converted, so a bare COALESCE(tier,'2') hands '' to CAST and gets 0. This
# arm was RED on the first implementation for exactly that reason; NULLIF fixed it.
reset
mk_rgate DIVE-2247 approval '' 'main2' '' >/dev/null
[[ "$(inbox_idents)" == "DIVE-2247 " ]] \
  && ok_t "NEGATIVE: a NULL-tier routed gate stays visible (unknown tier reads as hard)" \
  || bad_t "a NULL-tier routed gate was hidden" "idents=$(inbox_idents)"
reset
mk_rgate DIVE-2249 approval "''" 'main2' '' >/dev/null
[[ "$(inbox_idents)" == "DIVE-2249 " ]] \
  && ok_t "NEGATIVE: an EMPTY-STRING tier routed gate stays visible too (NULLIF, not COALESCE alone)" \
  || bad_t "an empty-string tier routed gate was hidden" "idents=$(inbox_idents) tier=$(db "SELECT quote(tier) FROM tasks WHERE ident='DIVE-2249';")"

# The same clause governs --send, which is the path that actually reaches the
# human's phone. A filter on the listing alone would leave the buzz intact.
reset
r5=$(mk_rgate DIVE-2248 approval 1 '' '')
out=$(cmd_task_inbox --send 2>&1)
sent_before=$(nsends)
: >"$SEND_LOG"
db "UPDATE tasks SET routed_reviewer='main2', gate_pinged_at=NULL WHERE id=${r5};"
out=$(cmd_task_inbox --send 2>&1); rc=$?
[[ "$sent_before" == "1" && "$(nsends)" == "0" && "$out" == *"nothing to send"* ]] \
  && ok_t "--send stops delivering a gate once it is routed to an agent" \
  || bad_t "--send still pushed a routed gate to the human" "before=$sent_before after=$(nsends) rc=$rc out=$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
