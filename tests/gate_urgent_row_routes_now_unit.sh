#!/usr/bin/env bash
# DIVE-4809 — AN URGENT ROW'S GATE WAKES ITS REVIEWER NOW, AND ITS PROVENANCE IS RECORDED.
#
# WHAT THIS GRADES, and why each arm exists rather than being obvious.
#
# DIVE-3474 arm 2 made a routed gate QUEUE for the reviewer's next natural wake and
# made `--urgent` the only opt-out. Measured on the 2026-09-22 red-main freeze
# (DIVE-4806): 34 of that outage's ~70 minutes were one approval gate sitting in
# that queue. The urgency had been declared — on the ROW — and the routing decision
# read only the flag. DIVE-4154 had already taught the OTHER half of the same rail
# (`_task_gate_undo_window_secs`) to read `priority='urgent'`; this makes the two
# halves agree.
#
# THE CONTROL IS THE LOAD-BEARING ARM. A change that turns urgency on cannot be
# graded by arms that only check it turned on: source that routed EVERY gate
# immediately would pass all of those and would delete DIVE-3474's whole measured
# result. Arm 1 is a normal-priority row that must still QUEUE, and the mutation
# section below has a mutant (M2) that fires the derivation unconditionally
# precisely to prove arm 1 can notice.
#
# AND THE PROVENANCE IS GRADED SEPARATELY FROM THE EFFECT. `gate_urgent=1` alone
# cannot tell a later reader whether a filer over-declared or this inheritance
# over-fired — different defects, different fixes. Arms 2c/3b pin `urgent_src`, so
# a future change that laundered the derived case into the filer's declaration
# (cheap, and invisible to every other assertion here) goes red.
#
# THE MUTANTS LIVE NEXT DOOR. tests/gate_urgent_row_routes_now_mutation.sh removes
# each property below from a copy of src/ and requires the NAMED arm here to go red —
# including the one that fires the derivation unconditionally, which is what proves
# GU1 can still see DIVE-3474's default. It is `TIER: nightly` by the DIVE-2867 class
# rule (a mutant grader re-copies the source tree once per mutant), so a change to
# this file that weakens an arm is caught by the nightly sweep, not by the PR core.
# It re-runs THIS file with GU_SRC_DIR pointed at the patched tree.
#
# Run: bash tests/gate_urgent_row_routes_now_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
. "$(dirname "${BASH_SOURCE[0]}")/lib/actor_seam.sh"

SRC="${GU_SRC_DIR:-src}"
TMP="$(mktemp -d /tmp/gate-urgent-row-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# The arms read HUMAN_PINGED and SENT, flags the stubs below set in THIS shell, so
# the in-process gate seam is the only one that can grade them (DIVE-4462).
GATE_SEAM_INPROCESS=1
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
mkdir -p "$TASKS_DIR"; set +e
NOTIFY_LOG="$TMP/gate-notify.log"; : >"$NOTIFY_LOG"
export FIVEDIVE_GATE_NOTIFY_LOG="$NOTIFY_LOG"
# The undo window would fork a detached child that sleeps before pinging; zero it so
# the arms grade the ROUTING decision and not the phone-hold timer (which DIVE-4154
# already grades in tests/gate_undo_window_unit.sh).
export _5DIVE_GATE_UNDO_WINDOW_SECS=0

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
HUMAN_PINGED=0
_task_need_notify_deliver() { HUMAN_PINGED=1; }
AUDIT_LOG_FILE="$TMP/audit.log"; : >"$AUDIT_LOG_FILE"
audit_log() { printf '%s\n' "$*" >>"$AUDIT_LOG_FILE"; }

# `5dive` as a shell function: shadows the real binary, is inherited by the detached
# child that performs the a2a send, and keeps `command -v 5dive` true.
ROUTE_FILE="$TMP/route.log"; : >"$ROUTE_FILE"
5dive() {
  if [[ "${1:-}" == "agent" && "${2:-}" == "send" ]]; then
    printf '%s\n' "${3:-}" >>"$ROUTE_FILE"
  fi
  return 0
}

db "INSERT INTO agents_org(name,reports_to,role) VALUES('main',NULL,'coordinator');"
db "INSERT INTO agents_org(name,reports_to,role) VALUES('dev','main','builder');"
_task_pref_set gate_builder_routing on

# seed <ident> <priority>
seed() { db "INSERT INTO tasks(ident,title,status,created_by,priority) VALUES('$1','t','todo','main','$2');"; }
# The send is performed by a DETACHED child, so poll rather than reading once.
sent_to() { local i; for i in $(seq 1 60); do [[ -s "$ROUTE_FILE" ]] && break; sleep 0.1; done; cat "$ROUTE_FILE" 2>/dev/null; }
reset_log() { : >"$NOTIFY_LOG"; : >"$ROUTE_FILE"; : >"$AUDIT_LOG_FILE"; }
ASKOK='fixture gate: the routing decision is the input under test, not prose a person reads (DIVE-4462)'

# ── ARM 1 (CONTROL) — a normal-priority row still QUEUES ──────────────────────
# Without this arm every other arm below passes on source that pings unconditionally,
# which is exactly the behaviour DIVE-3474 measured and removed.
reset_log; seed DIVE-4801 high; HUMAN_PINGED=0; JSON_MODE=0
OUT1=$(cmd_task_need DIVE-4801 --type=decision --ask="read the failing log first, or hand it straight to the author?" --options="read it first|hand it over" --ask-ok="$ASKOK" --recommend="read it first" --from=dev 2>"$TMP/e1")
sleep 0.4   # the send is detached; give a WRONG one time to land before asserting absence
[[ ! -s "$ROUTE_FILE" ]] \
  && ok_t "GU1 CONTROL: a priority=high row's routed gate sends NO a2a — it still queues (DIVE-3474 stands)" \
  || bad_t "GU1 control queues" "route log: $(cat "$ROUTE_FILE")"
grep -qi 'QUEUED' <<<"$OUT1" \
  && ok_t "GU1b CONTROL: and the filer is TOLD it queued" || bad_t "GU1b filer told" "out: $OUT1"
[[ "$(db "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='DIVE-4801';")" == "0" ]] \
  && ok_t "GU1c CONTROL: gate_urgent stays 0 — the derivation is not unconditional" || bad_t "GU1c gate_urgent" ""
grep -q 'task need filed .*urgent=0 urgent_src=<none>' "$AUDIT_LOG_FILE" \
  && ok_t "GU1d CONTROL: the audit row records NO urgency and NO source" \
  || bad_t "GU1d audit row" "audit: $(grep 'task need filed' "$AUDIT_LOG_FILE")"

# ── ARM 2 — an URGENT ROW routes NOW, with no --urgent on the command ─────────
reset_log; seed DIVE-4802 urgent; HUMAN_PINGED=0; JSON_MODE=0
OUT2=$(cmd_task_need DIVE-4802 --type=approval --ask="read the failing log first, or hand it straight to the author?" --ask-ok="$ASKOK" --recommend="read it first" --from=dev 2>"$TMP/e2")
[[ "$(sent_to)" == "main" ]] \
  && ok_t "GU2: an urgent ROW's routed gate WAKES the reviewer at file time (the 34 minutes DIVE-4806 measured)" \
  || bad_t "GU2 urgent row wakes reviewer" "route log: '$(cat "$ROUTE_FILE")' out: $OUT2"
! grep -qi 'QUEUED, not pinged' <<<"$OUT2" \
  && ok_t "GU2b: and the filer does NOT get the queued-not-pinged note" || bad_t "GU2b not queued" "out: $OUT2"
[[ "$(db "SELECT COALESCE(gate_urgent,0) FROM tasks WHERE ident='DIVE-4802';")" == "1" ]] \
  && ok_t "GU2c: gate_urgent=1 is PERSISTED, so the re-nag grace and the queue view read the same fact" \
  || bad_t "GU2c gate_urgent persisted" ""
grep -q 'task need filed .*urgent=1 urgent_src=priority=urgent' "$AUDIT_LOG_FILE" \
  && ok_t "GU2d: the audit row says the urgency was DERIVED from the row, not declared by the filer" \
  || bad_t "GU2d audit provenance" "audit: $(grep 'task need filed' "$AUDIT_LOG_FILE")"
grep -q 'priority=urgent' <<<"$OUT2" \
  && ok_t "GU2e: the filer is told WHERE the wake came from (a wake nobody typed must be attributable)" \
  || bad_t "GU2e filer told the source" "out: $OUT2"

# ── ARM 3 — an EXPLICIT --urgent is never relabelled as derived ───────────────
reset_log; seed DIVE-4803 high; HUMAN_PINGED=0; JSON_MODE=0
OUT3=$(cmd_task_need DIVE-4803 --urgent --type=decision --ask="read the failing log first, or hand it straight to the author?" --options="read it first|hand it over" --ask-ok="$ASKOK" --recommend="read it first" --from=dev 2>"$TMP/e3")
[[ "$(sent_to)" == "main" ]] \
  && ok_t "GU3: --urgent on a normal-priority row still wakes the reviewer (the flag is untouched)" \
  || bad_t "GU3 flag still works" "route log: '$(cat "$ROUTE_FILE")'"
grep -q 'task need filed .*urgent=1 urgent_src=--urgent' "$AUDIT_LOG_FILE" \
  && ok_t "GU3b: the flag's filing is recorded as the FILER's, never as the row's" \
  || bad_t "GU3b flag provenance" "audit: $(grep 'task need filed' "$AUDIT_LOG_FILE")"
! grep -q 'priority=urgent' <<<"$OUT3" \
  && ok_t "GU3c: and the derived-wake note is NOT printed for a flag the filer typed" \
  || bad_t "GU3c no derived note" "out: $OUT3"

# ── ARM 4 — the derivation cannot DOWNGRADE an explicit --urgent ──────────────
# `--urgent` on an urgent row must stay the filer's declaration: the branch is
# `else`, and an implementation that recomputed unconditionally would relabel it.
reset_log; seed DIVE-4804 urgent; HUMAN_PINGED=0; JSON_MODE=0
OUT4=$(cmd_task_need DIVE-4804 --urgent --type=decision --ask="read the failing log first, or hand it straight to the author?" --options="read it first|hand it over" --ask-ok="$ASKOK" --recommend="read it first" --from=dev 2>"$TMP/e4")
grep -q 'task need filed .*urgent=1 urgent_src=--urgent' "$AUDIT_LOG_FILE" \
  && ok_t "GU4: --urgent on an ALREADY-urgent row is still attributed to the filer" \
  || bad_t "GU4 flag wins on an urgent row" "audit: $(grep 'task need filed' "$AUDIT_LOG_FILE")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
