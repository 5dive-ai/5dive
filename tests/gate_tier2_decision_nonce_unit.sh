#!/usr/bin/env bash
# DIVE-2356 — the per-gate human nonce must be minted for EVERY tier>=2 gate, not
# only for the hard-human TYPES (approval/secret/manual/access).
#
# THE BUG THIS GRADES (measured in DIVE-2355, not inferred): the mint cased on gate
# TYPE alone, so a `decision` floored to tier 2 minted nothing — even though the
# DIVE-1117 floor refuses a non-human answer on exactly that gate. Across every
# answered gate on the live board: approval/manual/secret tier-2 were 40/40 nonce
# SET; decision tier-2 was 4/47, and those 4 came from the escalate-to-human path
# (the one unconditional mint). So a tier-2 decision was the one hard-human gate
# carrying no per-gate evidence at rest.
#
# WHAT THIS CHANGE IS NOT. It ships the MINT alone. The companion rule — refuse a
# tier-2 answer whose human_nonce_hash IS NULL — must not land until tier-2
# decision gates have accumulated nonces in the wild, or it would refuse 43 of the
# last 47 tier-2 decision answers. T5/T6 below are the guard for that: they assert
# the answer path is UNCHANGED, so a future edit that sneaks the refusal in early
# turns this harness red instead of turning the fleet red.
#
# RED-ON-UNFIXED (the test bar): revert the mint condition at src/cmd_task.sh to
# `case "$type" in approval|secret|manual|access)` and T1/T2/T3 fail. Verified by
# mutation, not by reading. T4 is the anchor — it passes on BOTH trees, so a
# harness that silently stopped exercising the code path cannot read as a pass.
#
# Isolation matches the sibling harnesses (gate_tier2_floor_unit.sh): source src/
# libs, throwaway STATE_DIR — the live shared tasks.db is NEVER touched.
# Run: bash tests/gate_tier2_decision_nonce_unit.sh (no root, no network).
set -uo pipefail

# See gate_tier2_floor_unit.sh: the absence of `2>/dev/null` here is deliberate —
# redirecting the source's stderr also swallows the helper's own stderr line,
# which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-t2-decision-nonce.XXXXXX)"
# DIVE-2610: every cmd_task_* call below runs UNSUBSHELLED, and the CLI's `fail`
# EXITS rather than returning. A refusal therefore truncates this harness mid-run:
# the remaining arms never grade, no FAIL prints, and the summary line never
# prints either — so a scan for FAIL/NOT OK reads the truncation as a pass.
# Name it. See community/wiki/a-refusal-that-exits-truncates-its-caller.md.
# fd 8 is a duplicate of the harness's REAL stderr. It must not be plain `>&2`:
# every cmd_task_* call below is invoked as `... >/dev/null 2>&1`, and a `fail`
# that EXITS terminates the shell while that redirection is still in effect — so
# an EXIT trap writing to fd 2 lands in /dev/null and the marker never appears.
# Measured in DIVE-2610: the marker is swallowed by the very redirect that hides
# the refusal it is meant to name.
exec 8>&2
REACHED_END=0
trap 'rc=$?; if (( ! REACHED_END )); then printf "ABORT - gate_tier2_decision_nonce_unit truncated at rc=%d after %d ok / %d FAIL: an unsubshelled cmd_task_* call exited instead of grading. NOT a pass.\n" "$rc" "${PASS:-0}" "${FAIL:-0}" >&8; fi; rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init

# Don't DM on gate filing; no root-owned audit log in this harness. Capture the
# nonce handed to the notifier so we can assert the RAW nonce travels to the tap
# builder and is never left only at rest.
NOTIFY_NONCE=""
task_need_notify() { NOTIFY_NONCE="${8:-}"; }
audit_log() { :; }

# Non-agent immediate caller, as in gate_tier2_floor_unit.sh, so nothing here is
# decided by the DIVE-394 agent-uid guard.
#
# DIVE-2610: `-u` MUST be stubbed too, not just `-un`. The T6 answer path runs
# through _gate_sudo_uid_nonagent (src/lib/tasks_db.sh), which consults SUDO_UID
# ONLY when the process is genuinely root ($EUID -eq 0) and otherwise resolves the
# REAL uid via `id -u` -> getent passwd -> "is it agent-*". Unprivileged, the
# `export SUDO_UID=0` above is therefore never read, `command id -u` returns the
# real caller, and on any agent-* uid the tier-2 human-evidence guard refuses with
# `fail 6` -> exit 6, truncating T6/T7 and the summary. On CI (runner, non-agent)
# the same code passes. That is the whole green-on-CI / red-on-every-agent-box
# split: environment, not the fix under test. Pinning `-u` to 0 makes the arm read
# the same on both.
FAKE_CALLER="root"
FAKE_CALLER_UID=0
id() {
  case "${1:-}" in
    -un) echo "$FAKE_CALLER" ;;
    -u)  echo "$FAKE_CALLER_UID" ;;
    *)   command id "$@" ;;
  esac
}
#
# DIVE-2601 + DIVE-2610, RECONCILED: BOTH pins are load-bearing and neither
# subsumes the other. `_gate_sudo_uid_nonagent` (src/lib/tasks_db.sh) calls
# `id -u` DIRECTLY and never routes through `_gate_caller_uid`, so the seam
# override below does NOT cover the T6 answer path — dropping the `id -u` stub
# reverts DIVE-2610 and reds this harness at rc=6 on any agent-* box. Conversely
# `_gate_uid_to_agent`/`task_actor` read `_gate_caller_uid`, which the `id` stub
# does not reach. Keep both; assert both.
# DIVE-2601: ALSO pinned through the seam the derivation reads ($EUID via
# `_gate_caller_uid`). The `id -un` stub alone left that derivation unpinned, so
# the caller's agent-ness on those arms came from the host. (The original DIVE-2601
# note said the `id` stub was dead here; DIVE-2610 measured it live on the T6 path
# via `id -u` — it is not dead, it is merely incomplete. Both pins stay.) uid 0 is
# root on every host and claimed by no agent-*, so no passwd fixture is needed.
_PIN_UID=0
_gate_caller_uid() { printf '%s' "$_PIN_UID"; }
# Assert the pin through the real resolver before any arm depends on it.
_pin_check="$(_gate_uid_to_agent "$(_gate_caller_uid)")"
[[ -z "$_pin_check" ]] \
  || { printf 'NOT OK - identity pin is inert: uid %s resolved to agent %s, expected a NON-agent caller\n' "$_PIN_UID" "'$_pin_check'"; exit 1; }
export SUDO_UID=0

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
hashof()  { db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$1';"; }
tierof()  { db "SELECT COALESCE(tier,'')             FROM tasks WHERE ident='$1';"; }
typeof_() { db "SELECT COALESCE(need_type,'')        FROM tasks WHERE ident='$1';"; }
answered(){ db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }

# openssl is the mint's entropy source. If it is unavailable this harness cannot
# distinguish "not minted" from "could not mint", so it SKIPS rather than passing
# vacuously or failing for the wrong reason.
if ! _n=$(_human_nonce_mint) || [[ -z "$_n" ]]; then
  printf 'SKIP - gate_tier2_decision_nonce_unit: _human_nonce_mint produced nothing (no entropy source); cannot grade the mint\n'
  exit 0
fi
unset _n

touch "$GATE_PROOF_ENFORCE"   # match the live envelope: enforce is ON fleet-wide

# --- T1: a decision gate EXPLICITLY pinned --tier=2 MINTS a nonce. -------------
#     This is the headline regression. RED on the unfixed tree.
seed_task DIVE-201
NOTIFY_NONCE=""
cmd_task_need DIVE-201 --type=decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
[[ "$(tierof DIVE-201)" == "2" && "$(typeof_ DIVE-201)" == "decision" ]] \
  && ok_t "T1 precondition: gate stored as a tier-2 decision" \
  || bad_t "T1 precondition tier-2 decision" "tier='$(tierof DIVE-201)' type='$(typeof_ DIVE-201)'"
[[ "$(hashof DIVE-201)" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "T1 tier-2 decision MINTS a 64-hex human_nonce_hash" \
  || bad_t "T1 tier-2 decision mints a nonce" "got '$(hashof DIVE-201)' (this is the DIVE-2355 hole)"
[[ -n "$NOTIFY_NONCE" ]] \
  && ok_t "T1 the RAW nonce reaches task_need_notify (tap builder), not just the DB" \
  || bad_t "T1 raw nonce passed to notify" "got empty"

# --- T2: same, via the CATEGORY FLOOR rather than an explicit pin. -------------
#     "secrets" in the ask trips _gate_tier2_floor_hit — the OSS-16 mechanism, and
#     the way most tier-2 decisions actually get there.
seed_task DIVE-202
cmd_task_need DIVE-202 --type=decision --ask="rotate the prod secrets now?" --options="yes|no" --recommend="no" >/dev/null 2>&1
if [[ "$(tierof DIVE-202)" == "2" ]]; then
  ok_t "T2 precondition: category heuristic floored the decision to tier 2"
  [[ "$(hashof DIVE-202)" =~ ^[0-9a-f]{64}$ ]] \
    && ok_t "T2 category-FLOORED tier-2 decision mints a nonce" \
    || bad_t "T2 category-floored tier-2 decision mints a nonce" "got '$(hashof DIVE-202)'"
else
  # Never pass silently if the keyword floor moves — that would make T2 vacuous.
  bad_t "T2 precondition: category floor" "got tier '$(tierof DIVE-202)' (keyword floor may have moved)"
fi

# --- T3: the RESCUE path — a gate filed BEFORE this change (nonce-less at rest)
#     picks one up on the next `task inbox --send` digest. DIVE-2355 called this
#     remedy a no-op precisely because the digest mint was type-gated the same
#     way; this asserts it no longer is. RED on the unfixed tree.
seed_task DIVE-203
cmd_task_need DIVE-203 --type=decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
db "UPDATE tasks SET human_nonce_hash=NULL WHERE ident='DIVE-203';"   # simulate a pre-fix row
[[ -z "$(hashof DIVE-203)" ]] \
  && ok_t "T3 precondition: legacy row starts with human_nonce_hash NULL" \
  || bad_t "T3 precondition NULL hash" "got '$(hashof DIVE-203)'"
TASK_CH_TYPE=claude
_task_send_owner() { TASK_SEND_DELIVERED=1; TASK_SEND_MESSAGE_IDS="1"; }
# `task inbox --send` is root-only (it reads other agents' channel state) and this
# harness runs unprivileged by design. Neutralise ONLY that guard, and say so: the
# root guard is a separate property with its own coverage, and what is under test
# here is the mint condition inside the digest loop. Without this the T3 assertion
# would be graded against a permission error, i.e. it would fail for a reason that
# has nothing to do with the fix.
require_root() { :; }
# DIVE-1506 fail-closed fixture guard: the digest refuses to run when the active
# task DB is not the prod DB, and names FIVEDIVE_PROD_TASKS_DB as the opt-in. Point
# it at THIS harness's throwaway DB — deliberately NOT exported, so it can never
# reach a real `5dive` subprocess and re-designate a fixture as prod. The guard is
# doing its job; this is the sanctioned way to grade the code behind it, and the
# assertion below is a DB write, so opting in cannot make it vacuous.
FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
# Third and last precondition: the digest refuses without a paired owner channel
# (it lives in cmd_agent_pairing.sh, which this harness deliberately does not
# source). TASK_CH_TYPE above supplies the only thing the mint path reads from it.
#
# THREE STUBS, NAMED DELIBERATELY. Each neutralises a PRECONDITION of reaching the
# digest loop — root, prod-DB fence, paired channel — and none of them is the
# property under test. The property under test is a WRITE to human_nonce_hash, so
# no stub can satisfy the assertion on its behalf: with the mint condition
# reverted, all three stubs still apply and T3 still goes red. That is what makes
# this a test of the fix rather than a test of the scaffolding.
_task_owner_channel() { :; }
# SUBSHELL on purpose: _task_inbox_send finishes through `ok`, which exits the
# process. The rotation we are grading is a write to the sqlite FILE, so it
# survives the subshell — but the rest of this harness would not.
( _task_inbox_send "" \
    "need_type IS NOT NULL AND need_answered_at IS NULL AND status NOT IN ('done','cancelled')" \
    "ORDER BY created_at" ) >/dev/null 2>&1
[[ "$(hashof DIVE-203)" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "T3 inbox digest RESCUES a nonce-less tier-2 decision (rotates a hash in)" \
  || bad_t "T3 inbox digest rescues nonce-less tier-2 decision" "got '$(hashof DIVE-203)'"

# --- T4: ANCHOR — an approval gate still mints, on both trees. A pass here with
#     T1/T2/T3 red means the harness is exercising the code path and the mint
#     condition is what changed; a FAIL here means the harness itself broke.
seed_task DIVE-204
cmd_task_need DIVE-204 --type=approval --ask="ship it?" --recommend="approve" >/dev/null 2>&1
[[ "$(hashof DIVE-204)" =~ ^[0-9a-f]{64}$ ]] \
  && ok_t "T4 anchor: approval gate still mints (unchanged by this fix)" \
  || bad_t "T4 anchor approval mints" "got '$(hashof DIVE-204)' — harness broken, not the fix"

# --- T5: BOUNDARY — a tier-1 decision still mints NOTHING. The widened condition
#     is tier>=2, not "all decisions": a tier-1 decision is genuinely
#     agent-clearable and must not acquire human-gate machinery. This must be
#     green on BOTH trees; if it ever goes red the condition over-widened.
seed_task DIVE-205
cmd_task_need DIVE-205 --type=decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=1 >/dev/null 2>&1
[[ "$(tierof DIVE-205)" == "1" ]] \
  && ok_t "T5 precondition: gate stored as a tier-1 decision" \
  || bad_t "T5 precondition tier-1" "got '$(tierof DIVE-205)'"
[[ -z "$(hashof DIVE-205)" ]] \
  && ok_t "T5 boundary: tier-1 decision mints NO nonce (still agent-clearable)" \
  || bad_t "T5 tier-1 decision mints no nonce" "got '$(hashof DIVE-205)' — condition over-widened"

# --- T6: THE ORDERING GUARD. Minting must not, by itself, change who can answer.
#     A --human answer on a nonce-bearing tier-2 decision still CLEARS (DIVE-525:
#     a real tap is never rejected — and the decision tap carries NO nonce in its
#     callback_data today, so an evidence requirement here would reject it).
seed_task DIVE-206
cmd_task_need DIVE-206 --type=decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
[[ "$(hashof DIVE-206)" =~ ^[0-9a-f]{64}$ ]] || bad_t "T6 precondition: gate minted a nonce" "got '$(hashof DIVE-206)'"
cmd_task_answer DIVE-206 --value=A --human >/dev/null 2>&1
[[ "$(answered DIVE-206)" == "closed" ]] \
  && ok_t "T6 ordering guard: --human answer on a NONCE-BEARING tier-2 decision still clears" \
  || bad_t "T6 --human tier-2 decision still clears" "still $(answered DIVE-206) — refuse-on-NULL may have landed early"

# --- T7: the pre-existing DIVE-1117 floor is untouched — a BARE-AGENT answer on
#     the same shape is still refused. Pairs with T6: together they pin the answer
#     path to exactly where it was before this change, in both directions.
seed_task DIVE-207
cmd_task_need DIVE-207 --type=decision --ask="pick a lane" --options="A|B" --recommend="A" --tier=2 >/dev/null 2>&1
out=$(cmd_task_answer DIVE-207 --value=A 2>&1); rc=$?
[[ "$(answered DIVE-207)" == "open" && $rc -ne 0 ]] \
  && ok_t "T7 bare-agent answer on tier-2 decision still REFUSED (DIVE-1117 floor intact)" \
  || bad_t "T7 bare-agent tier-2 still refused" "rc=$rc state=$(answered DIVE-207) out=$out"

REACHED_END=1
echo "-----"
printf 'gate_tier2_decision_nonce_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
