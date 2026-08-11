#!/usr/bin/env bash
# DIVE-2179 unit harness: a verifier's `task done`, run DIRECTLY against a live
# maker->verifier handoff (i.e. `task start` was never run), must stamp
# handoff_ack_at BEFORE the DIVE-1830/1835 merge gate can refuse the close. The
# ack means "the verifier attempted to grade this", not "the close succeeded" —
# and `policy_refuse` ends in `fail`, which `exit`s immediately, so anything only
# staged in the deferred `extra` SQL (the `start` path's trick) is lost on a
# refused `done`. Without the fix in _task_status_cmd (src/cmd_task.sh),
# handoff_ack_at stays NULL forever on a structurally-refused done, and
# _hb_stall_sweep (src/cmd_heartbeat.sh) nags the verifier forever with two
# dead-end remedies: `done` is the very thing just refused, and `reject` would
# write a false FAIL over work meant to be graded PASS.
#
# Same isolation contract as the sibling harnesses this borrows conventions
# from: gh stubbed exactly like tests/task_deliver_merge_gate_unit.sh, actor
# impersonated through the sealed seam exactly like tests/handoff_ack_unit.sh
# (tests/lib/actor_seam.sh), throwaway tasks.db. Run:
#   bash tests/task_done_ack_before_merge_gate_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null` on the source below — see the sibling
# harnesses for why silencing it would swallow the payload, not just the noise.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2770: the merge gate gained a CREDENTIAL-FREE rail (an unauthenticated read
# of a public repo). Every no-token arm below was written when "no credential"
# meant "no rail", and with the anon rail live they would reach the real network
# and grade a LIVE PR instead of the fixture. Turn it off here: these harnesses
# grade the pre-2770 rails, and tests/task_merge_gate_anon_rail_unit.sh grades the
# new one. This is also what keeps `no root, no network` true of this file.
#
# IT MUST SIT AFTER lib/grading_tree.sh, AND THAT IS NOT A STYLE CHOICE: that file
# sources lib/env_isolation.sh, which CLEARS inherited FIVE_* knobs so a harness
# never grades the caller's environment. Set above it, this export is wiped and the
# harness silently reaches the network instead — measured, and it read as three
# unrelated assertion failures naming a live PR's real state.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/done-ack-before-gate-unit.XXXXXX)"

# --- stub gh + sudo, same convention as tests/task_deliver_merge_gate_unit.sh ---
# (fail-closed sudo so the token resolver never reaches a real host credential;
# gh emits state/mergedAt from env, keyed off the -q '.field' arg it's asked for)
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
argv="$*"; q=""; state=""
if [[ "$1" == "api" ]]; then
  case "$2" in
    */commits\?*) printf '%s\n' "${GH_STUB_COMMITS_TSV:-$'1\t0'}"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) q="$2"; shift 2 ;;
    -q*) q="${1#-q}"; shift ;;
    --state) state="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
if [[ "$argv" == *"pr list"* && "$state" == "open" ]]; then
  printf '%s' "${GH_STUB_PRLIST:-[]}" | jq -r "$q" 2>/dev/null
  exit 0
fi
case "$q" in
  .state)          printf '%s\n' "${GH_STUB_STATE:-}" ;;
  .mergedAt|.\[0\].mergedAt|'.[0].mergedAt') printf '%s\n' "${GH_STUB_MERGED:-}" ;;
  *)               printf '{"state":"%s","mergedAt":"%s"}\n' "${GH_STUB_STATE:-}" "${GH_STUB_MERGED:-}" ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh cmd_org.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

# DIVE-2518: identity through the sealed seam, not the forgeable USER=... path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"
as_agent() { local _w="$1"; shift; ( actor_seam_as "$_w"; "$@" ); }

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e

# --- stubs: never touch tmux/network/audit ------------------------------------
SEND_LOG="$TMP/sent"; : >"$SEND_LOG"
cmd_send() {
  local tgt="$1" msg=""; shift
  for a in "$@"; do case "$a" in --message=*) msg="${a#--message=}";; esac; done
  printf '%s\t%s\n' "$tgt" "$msg" >>"$SEND_LOG"
}
audit_log() { return 0; }
task_need_notify() { :; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Precondition: the seam actually moves task_actor, or every arm below is a
# green no-op grading nothing (DIVE-2518's own lesson).
[[ "$(actor_seam_as maker; task_actor)" == "maker" ]] \
  && ok_t "actor seam moves task_actor (precondition)" \
  || bad_t "actor seam broken" "$(actor_seam_as maker; task_actor)"

ackof()    { db "SELECT COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$1;"; }
statusof() { db "SELECT status FROM tasks WHERE id=$1;"; }

PR1="https://github.com/5dive-ai/5dive/pull/2179"
PR2="https://github.com/5dive-ai/5dive/pull/2180"

# =============================================================================
# T1/T2/T3: the main case — `done` run DIRECTLY (no `task start`) against a live
# handoff bound to an unmerged PR is refused AND stamps handoff_ack_at.
# =============================================================================
out=$(as_agent maker cmd_task_add --assignee=maker --verifier=verifier \
      --body="ship it" -- "DIVE-2179 fixture" 2>"$TMP/err")
tid=$(printf '%s' "$out" | jq -r '.data.id')
as_agent maker cmd_task_deliver "$tid" --pr="$PR1" >/dev/null 2>"$TMP/err"
[[ "$(db "SELECT assignee||'|'||COALESCE(handoff_ack_at,'') FROM tasks WHERE id=$tid;")" == "verifier|" ]] \
  && ok_t "T1 precondition: delivered to verifier, unacked, no task start yet" \
  || bad_t "T1 precondition" "$(db "SELECT * FROM tasks WHERE id=$tid;")"

export GH_STUB_STATE="OPEN" GH_STUB_MERGED=""
out=$(as_agent verifier cmd_task_done "$tid" --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
# DIVE-2645: assert the VERDICT the user reads, not the ticket id. The refusal now
# reads "... is not merged to main (state=..., measured) — merge it, then task done".
[[ $rc -eq "$E_CONFLICT" && "$out" == *"not merged to main"* ]] \
  && ok_t "T2 done-before-start is refused by the merge gate exactly as before (E_CONFLICT)" \
  || bad_t "T2 refusal" "rc=$rc (want $E_CONFLICT) out=$out"
[[ "$(statusof "$tid")" != "done" ]] \
  && ok_t "T2 the task did NOT close" \
  || bad_t "T2 not closed" "status=$(statusof "$tid")"
[[ -n "$(ackof "$tid")" ]] \
  && ok_t "T2 handoff_ack_at IS stamped despite the refusal (DIVE-2179)" \
  || bad_t "T2 ack not stamped" "ack=$(ackof "$tid")"

# T3: the heartbeat stall-sweep's gap#2 predicate (src/cmd_heartbeat.sh,
# _hb_stall_sweep) no longer matches this row now that handoff_ack_at is set —
# checked two ways: the raw predicate, and the real function's own behaviour.
matched=$(db "SELECT COUNT(*) FROM tasks
              WHERE id=$tid
                AND verifier IS NOT NULL AND maker_agent IS NOT NULL
                AND assignee=verifier AND status NOT IN ('done','cancelled')
                AND handoff_ack_at IS NULL AND handoff_stale_pinged_at IS NULL
                AND handoff_delivered_at IS NOT NULL
                AND NOT (need_type IS NOT NULL AND need_answered_at IS NULL);")
[[ "$matched" == "0" ]] \
  && ok_t "T3 _hb_stall_sweep's gap#2 predicate no longer matches this row" \
  || bad_t "T3 stall predicate still matches" "matched=$matched"

db "UPDATE tasks SET handoff_delivered_at=datetime('now','-${_HB_VERIFY_STALE_MIN} minutes','-5 minutes') WHERE id=$tid;"
: >"$SEND_LOG"
_hb_stall_sweep >/dev/null 2>&1
[[ "$(grep -c 'delivered to you' "$SEND_LOG" 2>/dev/null)" == "0" ]] \
  && ok_t "T3b _hb_stall_sweep itself no longer nags this row (handoff_ack_at set)" \
  || bad_t "T3b stall sweep still nagged" "$(cat "$SEND_LOG")"

# T4: the SAME task later merges for real -> `done` closes exactly as before —
# proves the ack fix changed no acceptance, only the ack side-effect.
# `--no-graded-sha` isolates this from DIVE-2940 (a loop close with no stated sha now
# refuses). This case grades the ACK side-effect and the DIVE-1830 gate acceptance;
# it must not go red — or green — for a third gate's reason.
export GH_STUB_STATE="MERGED" GH_STUB_MERGED="2026-08-01T00:00:00Z"
out=$(as_agent verifier cmd_task_done "$tid" --no-graded-sha --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc=$?
[[ $rc -eq 0 && "$(statusof "$tid")" == "done" ]] \
  && ok_t "T4 done still closes once the PR is merged (unchanged acceptance)" \
  || bad_t "T4 close" "rc=$rc status=$(statusof "$tid") out=$out"

# =============================================================================
# T5 (control): a `done` attempt by someone who is NOT the assigned verifier
# must NOT stamp handoff_ack_at — confirms the new block is scoped by the same
# actor/assignee/verifier predicate as the DIVE-1378 `start` ack, not a blanket
# stamp on every `done` call.
# =============================================================================
out2=$(as_agent maker cmd_task_add --assignee=maker --verifier=verifier \
      --body="ship it too" -- "DIVE-2179 control fixture" 2>"$TMP/err")
tid2=$(printf '%s' "$out2" | jq -r '.data.id')
as_agent maker cmd_task_deliver "$tid2" --pr="$PR2" >/dev/null 2>"$TMP/err"
[[ -z "$(ackof "$tid2")" ]] \
  && ok_t "T5 precondition: delivered, unacked" \
  || bad_t "T5 precondition" "ack=$(ackof "$tid2")"

out5=$(as_agent intruder cmd_task_done "$tid2" --result="close under test (DIVE-2773: a first close must carry a reason)" 2>&1); rc5=$?
[[ $rc5 -ne 0 ]] \
  && ok_t "T5 a non-assigned-verifier's done attempt is refused (DIVE-2007)" \
  || bad_t "T5 not refused" "rc=$rc5 out=$out5"
[[ -z "$(ackof "$tid2")" ]] \
  && ok_t "T5 non-assigned-verifier's done attempt does NOT stamp handoff_ack_at" \
  || bad_t "T5 ack wrongly stamped" "ack=$(ackof "$tid2")"

echo "-----"
printf 'task_done_ack_before_merge_gate_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
