#!/usr/bin/env bash
# DIVE-4213 — attempt N+1 resumes from attempt N.
#
# THE BUG, measured over the 7 days to 2026-09-10: 400 maker runs, 228 of them
# reclaimed to todo (57%), and a reclaimed attempt is not a short one — median
# 25 min, p90 50. The next heartbeat then wakes the SAME seat on the SAME row
# with a blank context, so those 25 minutes are done again from nothing. That
# mechanism is the attempts-per-delivered-task number (median 3, mean 4.4).
#
# WHAT THIS PROVES, arm by arm:
#   1  RESUME — a row this seat already worked and had reclaimed (idle stall)
#      wakes attempt N+1 carrying ALL THREE carryover items: the checkout path
#      the attempt was working in, the row as the artifact to read, and the
#      seat's verbatim last assistant message;
#  1b  the clause is actually IN the nudge that reaches the pane, not merely
#      returned by a helper nothing calls;
#  1c  the carryover is framed as EVIDENCE, not instruction — the one property
#      the ticket's bounds section names, because a resumed attempt that
#      inherits the previous attempt's CONCLUSION re-asserts it forever;
#   2  CONTROL — attempt 1 on a fresh row (never claimed, never reclaimed) gets
#      NONE of the three: no carryover is invented where there was no attempt N;
#  2b  CONTROL — a row reclaimed from a DIFFERENT seat carries nothing to this
#      one: the carryover is per (row, seat), not per row;
#   3  THE BOUND — a reclaim that fired because the attempt OVERRAN ITS BUDGET
#      (the wedge arm) resumes nothing, so the seat cannot be handed its own
#      wedge back. The idle reason on the same row does carry;
#   4  CONTROL — the workspace is gone: no carryover, because item (1) rests on
#      positive evidence (a live checkout that still holds the branch) exactly
#      as DIVE-4104's hold does;
#   5  CONTROL — a row reclaimed to the VERIFIER (delivery preserved) is not a
#      maker's resume and carries nothing;
#   6  DEGRADED — an unreadable transcript still yields items (1) and (2) and
#      says item (3) is missing rather than dropping the whole carryover;
#   7  the pasted last message is BOUNDED and single-line: a transcript replay
#      in a tmux line is not a pointer;
#   8  CONTROL — a reclaim SUPERSEDED by a later closed run (the reject bounce:
#      attempt 1 reclaimed_to_todo, attempt 2 completed/verifier_rejected)
#      carries nothing, because the clause keys on the seat's LATEST CLOSED run
#      and not on the newest reclaimed one anywhere in its history.
#
# Same isolation contract as tests/heartbeat_reclaim_loop_unit.sh: source src/
# directly, throwaway tasks.db, throwaway projects root, throwaway seat homes,
# no tmux/network/root.
# Run: bash tests/heartbeat_resume_carryover_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/hb-resume-carryover.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh lib/runs.sh \
         cmd_task.sh cmd_org.sh cmd_project.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

addt() { ( cmd_task_add "$@" ) 2>/dev/null | jq -r '.data.id'; }
ident_of() { db "SELECT ident FROM tasks WHERE id=$1;"; }
reset_all() { db "DELETE FROM tasks; DELETE FROM runs; DELETE FROM run_events; DELETE FROM ship_events; DELETE FROM supervisor_events;"; }

# --- boundaries: no tmux/registry/network/systemd/real-host ------------------
REGISTRY="$TMP/registry.json"; printf '{"agents":{}}' >"$REGISTRY"
registry_read()  { cat "$REGISTRY"; }
registry_write() { cat > "$REGISTRY"; }
with_registry_lock() { local fn="$1"; shift; "$fn" "$@"; }
cmd_send()          { :; }
cmd_task_escalate() { :; }
systemctl()         { return 0; }
sudo()              { return 0; }
_hb_agent_idle()    { return 0; }
# The OTHER nudge enrichments are not what this harness grades; silence them so
# an assertion can never pass on text some unrelated clause happened to contain.
_hb_loop_terminal_clause() { printf ''; }
_hb_reject_fix_clause()    { printf ''; }
_hb_recall_cite()          { printf ''; }
_hb_is_knowledge_task()    { return 1; }

# The nudge that would reach the pane.
NUDGE=""
_hb_send_line() { NUDGE="$2"; return 0; }
wake_nudge() { NUDGE=""; _hb_wake "$1" "true" "$2" "$(ident_of "$2")" >/dev/null 2>&1; printf '%s' "$NUDGE"; }

# --- throwaway projects root, real (tiny) git worktrees ----------------------
_HB_PROJECTS_ROOT="$TMP/projects"
_FX_BASE="$_HB_PROJECTS_ROOT/repo-base"
mk_base_clone() {
  rm -rf "$_HB_PROJECTS_ROOT"; mkdir -p "$_FX_BASE"
  git -C "$_FX_BASE" init -q -b trunk 2>/dev/null
  git -C "$_FX_BASE" -c user.email=t@example.com -c user.name=t \
      commit -q --allow-empty -m seed 2>/dev/null
}
mk_worktree_on_branch() {
  local branch="$1" d="$_HB_PROJECTS_ROOT/wt-$1"
  rm -rf "$d"
  git -C "$_FX_BASE" worktree add -q -b "$branch" "$d" HEAD 2>/dev/null
  printf '%s' "$d"
}
mk_ref_only_branch() { git -C "$_FX_BASE" branch -f "$1" HEAD 2>/dev/null; }
bind_branch() {
  local id="$1" branch="$2" ident; ident=$(ident_of "$id")
  db "INSERT INTO ship_events (kind, actor, ident, repo, branch, sha)
      VALUES ('ship','agent-dev',$(sqlq "$ident"),'5dive-ai/5dive',$(sqlq "$branch"),'$(printf 'a%039d' "$id")');"
}

# --- throwaway seat homes, real JSONL transcripts ---------------------------
# The transcript reader is under test, so it is pointed at a fake home rather
# than stubbed: a stub of the thing being graded grades nothing.
_HB_SEAT_HOME_ROOT="$TMP/homes"
seat_transcript() { # <agent> <last assistant text>
  local name="$1" text="$2"
  local d                          # separate stmt: ${name} aborts under set -u on the same line
  d="$TMP/homes/agent-${name}/.claude/projects/-work"
  mkdir -p "$d"
  {
    jq -cn '{type:"user",   message:{role:"user",   content:"go"}}'
    jq -cn --arg t "an earlier turn nobody should quote" \
        '{type:"assistant", message:{role:"assistant", content:[{type:"text",text:$t}]}}'
    jq -cn '{type:"user",   message:{role:"user",   content:"continue"}}'
    jq -cn --arg t "$text" \
        '{type:"assistant", message:{role:"assistant", content:[{type:"text",text:$t}]}}'
  } > "$d/session.jsonl"
}
no_transcript() { rm -rf "$TMP/homes"; }

# --- fixtures ---------------------------------------------------------------
# A real attempt N: the seat claims the row (which OPENS a run), then the row is
# reclaimed through the real reclaim path (which CLOSES that run with the reason).
# Nothing here writes the `runs` row by hand — the carryover reads what the
# reclaim actually recorded.
attempt_then_reclaim() { # <agent> <why-mode: idle|overran|verifier> [row id]
  local who="$1" mode="$2" id="$3"
  _hb_claim_task "$who" "$id" >/dev/null 2>&1
  case "$mode" in
    idle)     _hb_reclaim_to_todo "$who" "$id" "idle 31m with the task still open (claimed then went idle)" ;;
    overran)  _hb_reclaim_to_todo "$who" "$id" "overran 45m budget (reap #1) — requeued from a clean slate, NOT cancelled" ;;
    verifier) _hb_reclaim_to_verifier "$who" "$id" "claiming session gone (claude restarted 60m after the claim)" ;;
  esac
}

LAST_MSG="I pushed the branch and the api test reds at line 41 of runs.sh"

# =============================================================================
# 1) RESUME — all three carryover items reach attempt N+1
# =============================================================================
reset_all; mk_base_clone; no_transcript
T1=$(addt --assignee=dev -- "resume me")
WT1=$(mk_worktree_on_branch "dive-4213-a")
bind_branch "$T1" "dive-4213-a"
seat_transcript dev "$LAST_MSG"
attempt_then_reclaim dev idle "$T1"

CLAUSE=$(_hb_carryover_clause dev "$T1" "$(ident_of "$T1")"); CRC=$?
if (( CRC == 0 )); then ok_t "a reclaimed row on the same seat produces a carryover clause"
else bad_t "no carryover clause on a reclaimed row" "rc=$CRC runs=$(db "SELECT agent||'/'||status||'/'||COALESCE(outcome,'')||'/'||COALESCE(error_class,'') FROM runs WHERE task_id=$T1;")"; fi

has "$CLAUSE" "$WT1" \
  && ok_t "carryover item (1): names the checkout attempt N was working in ($WT1)" \
  || bad_t "carryover omits the workspace path" "want $WT1 in: $CLAUSE"
has "$CLAUSE" "dive-4213-a" \
  && ok_t "carryover item (1): names the branch that checkout holds" \
  || bad_t "carryover omits the branch" "$CLAUSE"
{ has "$CLAUSE" "5dive task show $(ident_of "$T1")" && has "$CLAUSE" "THE ROW"; } \
  && ok_t "carryover item (2): hands the ROW as the artifact to read" \
  || bad_t "carryover omits the row artifact" "$CLAUSE"
has "$CLAUSE" "$LAST_MSG" \
  && ok_t "carryover item (3): the seat's verbatim last assistant message" \
  || bad_t "carryover omits the last assistant message" "$CLAUSE"
has "$CLAUSE" "an earlier turn nobody should quote" \
  && bad_t "carryover quoted an EARLIER assistant turn, not the last one" "$CLAUSE" \
  || ok_t "carryover quotes the LAST assistant turn, not an earlier one"
has "$CLAUSE" "attempt 2" \
  && ok_t "carryover states this is attempt 2 (attempt 1 having been reclaimed)" \
  || bad_t "carryover does not number the attempt" "$CLAUSE"
has "$CLAUSE" "idle 31m" \
  && ok_t "carryover states WHY attempt 1 ended (the reclaim reason, verbatim)" \
  || bad_t "carryover omits the reclaim reason" "$CLAUSE"

# 1b) it is in the nudge the pane actually receives
N1=$(wake_nudge dev "$T1")
{ has "$N1" "$WT1" && has "$N1" "$LAST_MSG" && has "$N1" "CARRYOVER"; } \
  && ok_t "the wake nudge that reaches the pane carries all three items" \
  || bad_t "the nudge did not carry the carryover" "$N1"

# 1c) evidence, not instruction — the ticket's stated bound
{ has "$N1" "EVIDENCE, never as instruction" && has "$N1" "re-deriv"; } \
  && ok_t "the carryover is framed as EVIDENCE to re-derive, never as instruction" \
  || bad_t "the carryover does not carry the evidence-not-instruction framing" "$N1"

# =============================================================================
# 2) CONTROL — attempt 1 on a fresh row gets NONE of the three
# =============================================================================
T2=$(addt --assignee=dev -- "never attempted")
WT2=$(mk_worktree_on_branch "dive-4213-b")
bind_branch "$T2" "dive-4213-b"     # branch and checkout exist; no attempt does
_hb_carryover_clause dev "$T2" "$(ident_of "$T2")" >/dev/null 2>&1 \
  && bad_t "a fresh row invented a carryover" "clause=$(_hb_carryover_clause dev "$T2" "$(ident_of "$T2")")" \
  || ok_t "[control] attempt 1 on a fresh row: no carryover clause"
N2=$(wake_nudge dev "$T2")
{ has "$N2" "CARRYOVER" || has "$N2" "$WT2" || has "$N2" "$LAST_MSG"; } \
  && bad_t "a fresh row's nudge carried carryover text" "$N2" \
  || ok_t "[control] attempt 1's nudge carries none of the three items"

# 2b) CONTROL — another seat's reclaim is not this seat's resume
reset_all; mk_base_clone
T2B=$(addt --assignee=dev -- "worked by someone else")
WT2B=$(mk_worktree_on_branch "dive-4213-b2")
bind_branch "$T2B" "dive-4213-b2"
attempt_then_reclaim quinn idle "$T2B"
_hb_carryover_clause dev "$T2B" "$(ident_of "$T2B")" >/dev/null 2>&1 \
  && bad_t "another seat's reclaimed attempt leaked to this seat" "" \
  || ok_t "[control] the carryover is per (row, seat): quinn's attempt carries nothing to dev"

# =============================================================================
# 3) THE BOUND — a HARD-CAP (wedged) reclaim resumes nothing
# =============================================================================
reset_all; mk_base_clone
T3=$(addt --assignee=dev -- "wedged attempt")
WT3=$(mk_worktree_on_branch "dive-4213-c")
bind_branch "$T3" "dive-4213-c"
attempt_then_reclaim dev overran "$T3"
_hb_carryover_clause dev "$T3" "$(ident_of "$T3")" >/dev/null 2>&1 \
  && bad_t "an overran-the-budget reclaim was resumed into its own wedge" "" \
  || ok_t "[bound] a hard-cap reclaim carries nothing: the seat is not handed its own wedge back"
N3=$(wake_nudge dev "$T3")
has "$N3" "CARRYOVER" \
  && bad_t "the wedged row's nudge carried carryover" "$N3" \
  || ok_t "[bound] the wedged row's nudge carries no carryover"
# and the SAME row, same workspace, reclaimed for an idle reason DOES carry —
# so arm 3 is the reason talking, not the fixture failing to build.
attempt_then_reclaim dev idle "$T3"
_hb_carryover_clause dev "$T3" "$(ident_of "$T3")" >/dev/null 2>&1 \
  && ok_t "[bound] the same row reclaimed as IDLE does carry: the bound is the reason, not the fixture" \
  || bad_t "the idle reclaim on the same row carried nothing" "runs=$(db "SELECT COALESCE(error_class,'') FROM runs WHERE task_id=$T3 ORDER BY rowid;")"

# =============================================================================
# 4) CONTROL — no live workspace, no carryover (positive evidence only)
# =============================================================================
reset_all; mk_base_clone
T4=$(addt --assignee=dev -- "branch checked out nowhere")
mk_ref_only_branch "dive-4213-d"        # a ref, no worktree
bind_branch "$T4" "dive-4213-d"
attempt_then_reclaim dev idle "$T4"
_hb_carryover_clause dev "$T4" "$(ident_of "$T4")" >/dev/null 2>&1 \
  && bad_t "carryover invented a workspace for a branch checked out nowhere" "" \
  || ok_t "[control] branch exists only as a ref: no carryover (positive evidence only)"

# =============================================================================
# 5) CONTROL — a reclaim to the VERIFIER is not a maker's resume
# =============================================================================
reset_all; mk_base_clone
T5=$(addt --assignee=dev --verifier=quinn -- "delivered, session gone")
WT5=$(mk_worktree_on_branch "dive-4213-e")
bind_branch "$T5" "dive-4213-e"
attempt_then_reclaim dev verifier "$T5"
_hb_carryover_clause dev "$T5" "$(ident_of "$T5")" >/dev/null 2>&1 \
  && bad_t "a reclaim that PRESERVED the delivery was treated as a maker's resume" "" \
  || ok_t "[control] reclaimed-to-verifier carries nothing to the maker"

# =============================================================================
# 6) DEGRADED — unreadable transcript keeps items (1) and (2)
# =============================================================================
reset_all; mk_base_clone; no_transcript
T6=$(addt --assignee=dev -- "no transcript")
WT6=$(mk_worktree_on_branch "dive-4213-f")
bind_branch "$T6" "dive-4213-f"
attempt_then_reclaim dev idle "$T6"
C6=$(_hb_carryover_clause dev "$T6" "$(ident_of "$T6")")
{ has "$C6" "$WT6" && has "$C6" "5dive task show" && has "$C6" "could not be read"; } \
  && ok_t "[degraded] an unreadable transcript still hands the workspace and the row, and says (3) is missing" \
  || bad_t "an unreadable transcript dropped the whole carryover" "$C6"

# =============================================================================
# 7) the pasted message is bounded and single-line
# =============================================================================
reset_all; mk_base_clone
T7=$(addt --assignee=dev -- "enormous last turn")
WT7=$(mk_worktree_on_branch "dive-4213-g")
bind_branch "$T7" "dive-4213-g"
BIG=$(printf 'line one\n%s\nend' "$(head -c 4000 /dev/zero | tr '\0' 'x')")
seat_transcript dev "$BIG"
attempt_then_reclaim dev idle "$T7"
C7=$(_hb_carryover_clause dev "$T7" "$(ident_of "$T7")")
if [[ "$(printf '%s' "$C7" | wc -l)" -eq 0 ]] && (( ${#C7} < 2500 )) && has "$C7" "..."; then
  ok_t "[bounds] a 4KB last turn is truncated and flattened to one line (clause ${#C7} chars, 0 newlines)"
else
  bad_t "the pasted last message was not bounded/flattened" "len=${#C7} newlines=$(printf '%s' "$C7" | wc -l) tail=${C7: -80}"
fi

# =============================================================================
# 8) CONTROL — a reclaim SUPERSEDED by a later closed run is not a resume
#
# The reject bounce, and it is the common shape rather than an exotic one: 57% of
# maker runs are reclaimed, and a verifier reject is exactly when the seat is woken
# again. Attempt 1 is reclaimed to todo; attempt 2 delivers and is rejected, which
# closes that run completed/verifier_rejected through the same `_run_close_for_task`
# call `task reject` makes (src/task/delivery.sh). Selecting the newest RECLAIMED
# run reaches PAST attempt 2 and emits a clause that says "attempt 1 ... so this is
# attempt 2" when it is attempt 3, and prints attempt 2's transcript line under a
# label naming attempt 1. The clause must therefore key on the seat's LATEST CLOSED
# run, and stay silent when that run is not a reclaim.
# =============================================================================
reset_all; mk_base_clone
T8=$(addt --assignee=dev --verifier=quinn -- "reclaimed, then delivered and rejected")
WT8=$(mk_worktree_on_branch "dive-4213-h")
bind_branch "$T8" "dive-4213-h"
seat_transcript dev "$LAST_MSG"
attempt_then_reclaim dev idle "$T8"                 # attempt 1: abandoned/reclaimed_to_todo
_hb_claim_task dev "$T8" >/dev/null 2>&1            # attempt 2: a real run opens
# ... and the real reject closes it. The seat is named explicitly because
# `run_current` otherwise defaults to the CALLING actor's seat, which in a harness
# is the host user and not `dev`; on the live path the caller already is that seat.
_run_close_for_task "$T8" completed verifier_rejected dev

RUNS8=$(db "SELECT COALESCE(attempt,1)||'/'||status||'/'||COALESCE(outcome,'') FROM runs WHERE task_id=$T8 AND agent='dev' AND ended_at IS NOT NULL ORDER BY COALESCE(ended_at,started_at), rowid;" | tr '\n' ' ')
case "$RUNS8" in
  *"abandoned/reclaimed_to_todo"*"completed/verifier_rejected"*)
    ok_t "[fixture] the reject bounce is built by the real path: $RUNS8" ;;
  *) bad_t "the reject-bounce fixture did not produce reclaim-then-reject" "$RUNS8" ;;
esac

C8=$(_hb_carryover_clause dev "$T8" "$(ident_of "$T8")" 2>/dev/null); C8RC=$?
if (( C8RC != 0 )) && [[ -z "$C8" ]]; then
  ok_t "[control] a reclaim superseded by a later completed/verifier_rejected run carries nothing"
else
  bad_t "the carryover reached PAST a newer closed run (the reject bounce)" "rc=$C8RC runs=$RUNS8 clause=$C8"
fi

# 8b) and the nudge the pane receives says nothing about a resume, so it cannot
#     disagree with the reject-fix clause it arrives beside.
N8=$(wake_nudge dev "$T8")
has "$N8" "CARRYOVER" \
  && bad_t "the nudge for a reject bounce still carried a carryover clause" "$N8" \
  || ok_t "[control] the reject-bounce nudge carries no carryover beside the reject fix"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
