#!/usr/bin/env bash
# DIVE-4295 — a SPOOLED task-engine nag is re-checked against the board at the
# moment it is delivered, not at the moment it was written.
#
# THE DEFECT, measured on quinn's seat 2026-09-11: a send to a busy verifier is
# spooled (DIVE-4214) and drains one message per idle observation. 18 messages
# sat in that spool between 07:20 and 08:55, so nags whose predicate was true
# when the sweep ran were typed into the seat up to an hour later — one for a
# row that had been done and MERGED for ~50 minutes ("still unacknowledged"),
# one for a row quinn had already graded and rejected to dev2 ("grading is
# genuinely yours again"). The sentence asserts CURRENT ownership; the spool is
# what makes it stale.
#
# WHAT THIS GRADES, which is the row's acceptance arm verbatim:
#   * a graded-and-bounced row (open, but assignee moved to the maker) produces
#     NO verifier nag — the spooled copy is DROPPED, not typed;
#   * a done/merged row produces NO verifier nag;
#   * a row genuinely delivered and untouched STILL nags — the guard is a
#     discriminator, not a mute;
#   * an unguarded message (every pre-existing caller) is untouched;
#   * an unreadable board FAILS OPEN — a nag that cannot be judged is delivered,
#     because the sweep already burned its throttle column and a wrong drop is
#     permanent where a wrong delivery costs one re-investigation;
#   * a stale message at the HEAD of the queue does not cost a tick: the drop
#     loop reaches the live message behind it in the same flush;
#   * a row carrying a verifier VERDICT for its current iteration produces no
#     nag on ANY rail, while the same row with the verdict cleared still nags,
#     and a verdict from a PREVIOUS iteration does not mute the current one
#     (iteration 2 — the answered-gate rail delivered a nag for DIVE-4295
#     itself at 11:02:15Z to the seat that had graded it at 10:55:47).
#
# Boundaries only are stubbed (tmux, the idle predicate, sudo). The spool writes
# and reads real files, and the board is a real throwaway sqlite tasks db, so
# _a2a_guard_holds runs its real SQL. _a2a_queue_put, a2a_queue_flush_one and
# inject_and_submit stay REAL — mutating any of them makes this red.
set -uo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/tasks_db.sh cmd_agent_runtime.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done

PASS=0; FAIL=0
TMPROOT="$(mktemp -d /tmp/a2a-stale-nag.XXXXXX)"
trap 'rc=$?; rm -rf "${TMPROOT:-/nonexistent-a2a-4295}"; echo "HARNESS-RC=$rc"' EXIT
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
is() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then ok_t "$label"; else bad_t "$label" "want=[$want] got=[$got]"; fi
}

TYPED="${TMPROOT}/typed.log"; : >"$TYPED"

# --- boundaries -------------------------------------------------------------
_a2a_queue_dir() { printf '%s\n' "${TMPROOT}/agent-${1}/.5dive/a2a-queue"; }
sudo() {
  local -a a=("$@")
  [[ "${a[0]:-}" == "-n" ]] && a=("${a[@]:1}")
  if [[ "${a[0]:-}" == "-u" ]]; then a=("${a[@]:2}"); fi
  "${a[@]}"
}
tmux() { printf 'TMUX %s\n' "$*" >>"$TYPED"; return 0; }
_agent_delivery_inbox()   { return 1; }
_agent_pane_safe_to_type(){ return 0; }
_hb_claude_pid()          { printf '4295\n'; }
_hb_verify_submit()       { return 0; }
wait_agent_input_ready()  { return 0; }
_hb_agent_idle()          { return "${IDLE_RC:-0}"; }
_hb_log()                 { printf 'HBLOG %s\n' "$*" >>"${TMPROOT}/hb.log"; }

# --- a real (throwaway) board ------------------------------------------------
# _a2a_guard_holds fails OPEN on a board it cannot read, so a fake `db` that
# silently returned nothing would green every arm here while grading nothing.
# The db is real.
STATE_DIR="$TMPROOT"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
db "CREATE TABLE tasks (id INTEGER PRIMARY KEY, ident TEXT, status TEXT,
                        assignee TEXT, verifier TEXT, handoff_ack_at TEXT,
                        handoff_delivered_at TEXT, graded_at TEXT,
                        graded_verdict_at TEXT);" >/dev/null
row() { db "INSERT INTO tasks (ident,status,assignee,verifier,handoff_ack_at)
            VALUES ($(sqlq "$1"),$(sqlq "$2"),$(sqlq "$3"),$(sqlq "$4"),$5);" >/dev/null; }
#    ident        status       assignee verifier  ack
row 'DIVE-LIVE'  'todo'       'quinn'  'quinn'   'NULL'          # delivered, untouched
row 'DIVE-DONE'  'done'       'quinn'  'quinn'   'NULL'          # graded + merged
row 'DIVE-BOUNCED' 'todo'     'dev2'   'quinn'   "'2026-09-11'"  # graded, rejected to maker
row 'DIVE-ACKED' 'in_progress' 'quinn' 'quinn'   "'2026-09-11'"  # started by the verifier

# Rows carrying a VERDICT, for the third drop condition. graded_verdict_at is
# compared against handoff_delivered_at, never against "ever" — a verdict from a
# previous iteration must not mute the nag for the current one.
rowg() { db "INSERT INTO tasks (ident,status,assignee,verifier,handoff_ack_at,
                                handoff_delivered_at,graded_at,graded_verdict_at)
             VALUES ($(sqlq "$1"),$(sqlq "$2"),$(sqlq "$3"),$(sqlq "$4"),$5,$6,$7,$8);" >/dev/null; }
#     ident            status        assignee verifier  ack                      delivered                  graded_at                  verdict_at
# The LIVE counter-example quinn read at 11:02:15Z: DIVE-4295 itself, graded 10:55:47 and nagged anyway.
rowg 'DIVE-GRADED'   'in_progress' 'quinn' 'quinn' "'2026-09-11 10:52:21'" "'2026-09-11 10:40:00'" "'2026-09-11 10:55:47'" "'2026-09-11 10:55:47'"
# Same shape, but the verdict belongs to the PREVIOUS iteration — re-delivered at 11:10.
rowg 'DIVE-REGRADE'  'todo'        'quinn' 'quinn' 'NULL'                  "'2026-09-11 11:10:00'" "'2026-09-11 09:00:00'" "'2026-09-11 09:00:00'"
# Graded before graded_verdict_at existed (DIVE-3430): only graded_at is set.
rowg 'DIVE-LEGACY'   'in_progress' 'quinn' 'quinn' "'2026-09-11 10:52:21'" "'2026-09-11 10:40:00'" "'2026-09-11 10:55:47'" 'NULL'
# A verdict with NO recorded delivery — nothing establishes a current iteration.
rowg 'DIVE-NODELIV'  'in_progress' 'quinn' 'quinn' "'2026-09-11 10:52:21'" 'NULL'                  "'2026-09-11 10:55:47'" "'2026-09-11 10:55:47'"

typed_count() { grep -c -- 'send-keys -t [^ ]* -l --' "$TYPED" 2>/dev/null || true; }
spool_count() { find "$(_a2a_queue_dir "$1")" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
reset_arm()   { : >"$TYPED"; rm -rf "${TMPROOT}/agent-quinn"; }

# --- T1: the predicate itself, every state ----------------------------------
# rc 0 = still true (deliver) · 1 = stale (drop) · 2 = unjudgeable (deliver).
for arm in \
  "DIVE-LIVE:verifier_unacked:0:delivered-and-untouched still nags" \
  "DIVE-DONE:verifier_unacked:1:a done/merged row does not" \
  "DIVE-BOUNCED:verifier_unacked:1:a graded-and-bounced row does not" \
  "DIVE-ACKED:verifier_unacked:1:an already-acked row does not" \
  "DIVE-BOUNCED:verifier_owns:1:the answered-gate nag drops on a bounced row" \
  "DIVE-LIVE:verifier_owns:0:the answered-gate nag survives on a live row" \
  "DIVE-ACKED:verifier_owns:0:the answered-gate rail ignores the ack clause" \
  "DIVE-NOSUCH:verifier_unacked:1:a row that is not on the board at all" \
  "DIVE-LIVE:bogus_cond:2:an unknown condition is unjudgeable, not false" ; do
  IFS=':' read -r i c want label <<<"$arm"
  got=0; _a2a_guard_holds "task:${i}:quinn:${c}" || got=$?
  is "T1: ${label}" "$want" "$got"
done

# T1b: the pool wake keys on ASSIGNMENT only — a grading session runs on a pool
# seat that is not the row's `verifier`, so a verifier clause there would read
# false on every healthy row and delete the rail.
got=0; _a2a_guard_holds "task:DIVE-BOUNCED:dev2:assignee_owns" || got=$?
is "T1b: assignee_owns holds for the seat the row actually sits on" "0" "$got"
got=0; _a2a_guard_holds "task:DIVE-BOUNCED:quinn:assignee_owns" || got=$?
is "T1b: assignee_owns is false for a seat that no longer holds it" "1" "$got"

# --- T2: end to end — spool while busy, then flush at idle -------------------
for arm in "DIVE-DONE:0:a merged row's spooled nag is DROPPED, not typed" \
           "DIVE-BOUNCED:0:a bounced row's spooled nag is DROPPED, not typed" \
           "DIVE-LIVE:1:a live row's spooled nag is still DELIVERED"; do
  IFS=':' read -r i want label <<<"$arm"
  reset_arm
  _rc=0
  IDLE_RC=1 _A2A_GUARD="task:${i}:quinn:verifier_unacked" \
    inject_and_submit quinn "📥 ${i} was delivered to you for review 61m ago" || _rc=$?
  is "T2: ${i} spooled while busy (rc 4)" "4" "$_rc"
  is "T2: ${i} one message on the spool"  "1" "$(spool_count quinn)"
  IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
  is "T2: ${label}" "$want" "$(typed_count)"
  is "T2: ${i} spool is empty either way" "0" "$(spool_count quinn)"
done

# --- T3: a stale HEAD does not cost the live message a tick ------------------
# The drop loop is the reason this is one flush and not three. On the measured
# spool the alternative is 18 ticks to reach the message that is actually true.
reset_arm
for i in DIVE-DONE DIVE-BOUNCED DIVE-LIVE; do
  IDLE_RC=1 _A2A_GUARD="task:${i}:quinn:verifier_unacked" \
    inject_and_submit quinn "📥 ${i} nag" >/dev/null 2>&1 || true
done
is "T3: three spooled" "3" "$(spool_count quinn)"
IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
is "T3: ONE typed in a single flush"            "1" "$(typed_count)"
is "T3: and it is the live one"                 "1" "$(grep -c 'DIVE-LIVE' "$TYPED" || true)"
is "T3: neither stale one was typed"            "0" "$(grep -c 'DIVE-DONE\|DIVE-BOUNCED' "$TYPED" || true)"
is "T3: spool drained"                          "0" "$(spool_count quinn)"

# --- T4: an UNGUARDED message is untouched ----------------------------------
# Every pre-existing caller spools without a sidecar. Those must deliver exactly
# as they did before — the guard is opt-in per send, not a new gate on a2a.
reset_arm
IDLE_RC=1 inject_and_submit quinn "hello from a peer, no guard" >/dev/null 2>&1 || true
is "T4: unguarded message spooled" "1" "$(spool_count quinn)"
IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
is "T4: unguarded message DELIVERED" "1" "$(typed_count)"

# --- T5: an unreadable board FAILS OPEN -------------------------------------
# Direction matters and is the opposite of the usual fail-closed reflex: the
# sweep stamps handoff_stale_pinged_at at ENQUEUE time, so a dropped nag never
# fires again for that row. Unjudgeable therefore delivers.
reset_arm
IDLE_RC=1 _A2A_GUARD="task:DIVE-DONE:quinn:verifier_unacked" \
  inject_and_submit quinn "📥 DIVE-DONE nag" >/dev/null 2>&1 || true
_SAVED_DB="$TASKS_DB"; TASKS_DB="${TMPROOT}/tasks/nonexistent-dir/tasks.db"
IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
TASKS_DB="$_SAVED_DB"
is "T5: unreadable board delivers rather than drops" "1" "$(typed_count)"

# --- T6: THE THIRD DROP CONDITION — a verdict for the CURRENT iteration ------
# DIVE-4295 iteration 2. The row's DO named three drop conditions; iteration 1
# implemented two and picked up the third only accidentally on verifier_unacked
# (via `handoff_ack_at IS NULL`), so the answered-gate rail nagged a row its own
# grader had already graded — measured on DIVE-4295 ITSELF at 11:02:15Z. The
# arms below are the pair in BOTH directions: a graded row is silent, and the
# same row with the verdict cleared still nags.
for arm in \
  "DIVE-GRADED:verifier_owns:1:a verdict for the current iteration silences the answered-gate rail" \
  "DIVE-GRADED:assignee_owns:1:and silences the grader-pool wake" \
  "DIVE-GRADED:verifier_unacked:1:and the delivered-unacked rail (already true via the ack clause)" \
  "DIVE-REGRADE:verifier_owns:0:a verdict OLDER than this delivery does NOT mute the new iteration" \
  "DIVE-REGRADE:assignee_owns:0:same, on the pool wake" \
  "DIVE-LEGACY:verifier_owns:1:a pre-DIVE-3430 grade (graded_at only) still counts as a verdict" \
  "DIVE-NODELIV:verifier_owns:0:a verdict with no recorded delivery fails OPEN, like every other NULL" \
  "DIVE-ACKED:verifier_owns:0:an acked but UNGRADED row is still nagged — the close really is owed" ; do
  IFS=':' read -r i c want label <<<"$arm"
  got=0; _a2a_guard_holds "task:${i}:quinn:${c}" || got=$?
  is "T6: ${label}" "$want" "$got"
done

# The other direction on the SAME row, not a different one: clear the verdict and
# the identical predicate must deliver again. This is what stops the clause from
# being satisfied by something else about DIVE-GRADED.
db "UPDATE tasks SET graded_at=NULL, graded_verdict_at=NULL WHERE ident='DIVE-GRADED';" >/dev/null
got=0; _a2a_guard_holds "task:DIVE-GRADED:quinn:verifier_owns" || got=$?
is "T6: the SAME row with its verdict cleared nags again" "0" "$got"
db "UPDATE tasks SET graded_at='2026-09-11 10:55:47', graded_verdict_at='2026-09-11 10:55:47'
    WHERE ident='DIVE-GRADED';" >/dev/null
got=0; _a2a_guard_holds "task:DIVE-GRADED:quinn:verifier_owns" || got=$?
is "T6: and is silent again once restored" "1" "$got"

# --- T7: end to end on the rail that was actually wrong ----------------------
# T2 drives verifier_unacked; the live defect arrived on verifier_owns, so the
# spool-then-flush path is pinned there too rather than assumed to follow.
reset_arm
_rc=0
IDLE_RC=1 _A2A_GUARD="task:DIVE-GRADED:quinn:verifier_owns" \
  inject_and_submit quinn "✅ DIVE-GRADED: the human gate was ANSWERED 63m ago. Pick it back up" || _rc=$?
is "T7: the answered-gate nag spooled while busy (rc 4)" "4" "$_rc"
IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
is "T7: a graded row's spooled answered-gate nag is DROPPED, not typed" "0" "$(typed_count)"
is "T7: spool drained" "0" "$(spool_count quinn)"

reset_arm
IDLE_RC=1 _A2A_GUARD="task:DIVE-REGRADE:quinn:verifier_owns" \
  inject_and_submit quinn "✅ DIVE-REGRADE: the human gate was ANSWERED 63m ago. Pick it back up" >/dev/null 2>&1 || true
IDLE_RC=0 a2a_queue_flush_one quinn >/dev/null 2>&1 || true
is "T7: a re-delivered row's answered-gate nag is still DELIVERED" "1" "$(typed_count)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
