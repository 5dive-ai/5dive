#!/usr/bin/env bash
# TIER: core (the default; no marker needed) — 2.8s measured on the control-plane VM
# (bare `bash tests/gate_refusal_empty_filer_e2e.sh`, 2026-08-12, two samples, low kept).
# It builds a throwaway bundle and that is nearly all of the cost, but build.sh is cheap
# here; it fits the 300s PR core with room, so it is NOT demoted. Editing it always runs
# it (changed-harnesses), so the PR that touches either refusal still grades this.
#
# DIVE-3340 iter2 — THE TWO GATE REFUSALS MUST STILL PRINT WHEN THE FILER IS EMPTY.
#
# WHY THIS HARNESS EXISTS AT ALL, AND WHY THE ARMS ARE NOT IN THE UNIT FILE.
# main2's iteration-1 grade found that `task cancel` over an open gate aborted with
# rc=1 and "exited without reporting a reason" instead of printing its refusal,
# whenever the gate's filer resolved to the empty string. Mechanism:
#
#   _gate_route_reviewer() { local _filer="$1"; [[ -n "$_filer" ]] || return; ... }
#
# A bare `return` inherits the rc of the last command — the FAILED `[[ -n ]]` — so an
# EMPTY filer returns 1, while a non-empty filer that resolves nobody returns 0 (the
# trailing `if` inside the `for` sets the rc, and a false `if` with no `else` is 0).
# The bundle runs `set -euo pipefail` and an assignment's rc is its command
# substitution's, so `_cg_lead=$(_gate_route_reviewer "$_cg_filer")` killed the shell
# one line before the refusal it was resolving a value FOR.
#
# THE INSTRUMENT IS THE WHOLE POINT. tests/task_close_needs_a_reason_unit.sh sources
# the functions under `set -uo pipefail` — NO `-e`. Arms written there pass with the
# guard and pass without it: measured, both directions, 39/0. An errexit abort is not
# reproducible in a shell that has errexit off, so the unit harness cannot grade this
# defect no matter how the assertions are phrased. Only the BUILT bundle carries
# `set -euo pipefail` (src/header.sh:14), which is why this file builds one.
#
# REACHABILITY OF THE EMPTY-FILER STATE. `task need` never writes an empty
# gate_filed_by; legacy rows, fixtures and direct writes do. A fresh box whose org
# chart names no coordinator also leaves assignee='' by default — the customer-VM
# shape this ticket came from. Zero rows on the live board hold it today, so this is
# a regression guard on a reachable-but-unoccupied cell, not a live-firing bug.
#
# Run: bash tests/gate_refusal_empty_filer_e2e.sh   (exit 0 == green)
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

# DIVE-2211: name the tree this harness grades. No 2>/dev/null — the helper's stderr
# line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for b in jq sqlite3; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP: $b not on PATH (empty-filer gate e2e needs it)"; exit 0; }
done

TMP="$(mktemp -d /tmp/gate-empty-filer-e2e.XXXXXX)"
FIVE="$TMP/5dive"
if ! BUILD_OUT="$FIVE" bash "$ROOT/build.sh" >/dev/null 2>&1 || [[ ! -x "$FIVE" ]]; then
  echo "SKIP: could not build a throwaway ./5dive (build.sh failed)"; exit 0
fi
# Isolate — never touch a live state dir. All three are exported because
# _tasks_store_dir derives the sentinel from TASKS_DB's OWN directory (DIVE-1986):
# pointing TASKS_DB elsewhere while leaving TASKS_DIR at its default is the exact
# shape that once auto-restored 579 prod rows into /tmp.
export STATE_DIR="$TMP" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
DB="$TASKS_DB"
# `5dive task init` REFUSES without root ("must run as root", rc=10) and `task add`
# will not self-init, so a non-root harness cannot provision a board through the
# bundle at all. Bootstrap the store by sourcing the same tasks_db_init the unit
# harnesses use, then hand the built bundle the initialised store. The bundle is
# still the thing under test — only the empty schema comes from src.
mkdir -p "$TASKS_DIR"
( for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
           lib/state.sh lib/broker.sh lib/audit.sh lib/registry.sh lib/disk.sh lib/tasks_db.sh; do
    # shellcheck source=/dev/null
    source "$ROOT/src/$f" 2>/dev/null
  done
  tasks_db_init ) >/dev/null 2>&1
[[ -f "$DB" ]] || { echo "SKIP: could not bootstrap a scratch tasks store at $DB"; exit 0; }

P=0; F=0
ok(){  P=$((P+1)); echo "ok   - $1"; }
bad(){ F=$((F+1)); echo "FAIL - $1"; [[ -n "${2:-}" ]] && echo "       $2"; }

# Confirm the bundle really is the errexit shape this harness claims to grade. If a
# future build stops emitting `set -euo pipefail`, every arm below silently stops
# testing anything and this line is what says so.
grep -qE '^set -euo pipefail' "$FIVE" \
  && ok "INSTRUMENT: the built bundle runs 'set -euo pipefail' (the shape the unit harness lacks)" \
  || bad "INSTRUMENT: built bundle is not errexit — every arm here is vacuous" "$(grep -m1 '^set ' "$FIVE")"

mkrow() {  # $1 = title  -> prints ident
  "$FIVE" task add "$1" --json 2>/dev/null | jq -r '.data.ident // empty'
}
gate_it() { # $1 = ident, $2..= extra SET clauses
  sqlite3 "$DB" "UPDATE tasks SET need_type='decision', ask='which surface?',
                   need_answered_at=NULL, tier=2 ${2:+, $2} WHERE ident='$1';"
}

# ── CONTROL: a NON-empty filer refuses correctly (this is what already worked) ──
# Without it, an empty-filer red below could equally mean "the refusal is broken for
# everyone" or "this harness cannot detect a refusal at all".
C=$(mkrow "DIVE-3340 control: non-empty filer")
gate_it "$C" "gate_filed_by='dev'"
c_err=$("$FIVE" task cancel "$C" --result="abandoning this" 2>&1 >/dev/null); c_rc=$?
(( c_rc == 5 )) && [[ "$c_err" == *"withdraw"* ]] \
  && ok "CONTROL: a gate with a resolvable filer refuses rc=5 and prints its refusal" \
  || bad "CONTROL: the ordinary refusal path is broken — the empty-filer arms cannot be read" "rc=$c_rc err='$c_err'"

# ── The cell: BOTH filer expressions empty ────────────────────────────────────
# cancel   reads COALESCE(NULLIF(gate_filed_by,''), assignee, '')
# withdraw reads COALESCE(NULLIF(gate_filed_by,''), NULLIF(created_by,''), '')
# They are DIFFERENT expressions, so all three columns must be cleared or one verb
# quietly keeps a non-empty filer and its arm grades nothing. Measured: clearing only
# gate_filed_by+assignee left the withdraw arm passing with the guard absent.
Q=$(mkrow "DIVE-3340 empty filer")
gate_it "$Q" "gate_filed_by='', assignee='', created_by=''"
q_cancel_filer=$(sqlite3 "$DB" "SELECT COALESCE(NULLIF(gate_filed_by,''), assignee, '') FROM tasks WHERE ident='$Q';")
q_wd_filer=$(sqlite3 "$DB" "SELECT COALESCE(NULLIF(gate_filed_by,''), NULLIF(created_by,''), '') FROM tasks WHERE ident='$Q';")
q_type=$(sqlite3 "$DB" "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='$Q';")
[[ -z "$q_cancel_filer" && -z "$q_wd_filer" && "$q_type" == "decision" ]] \
  && ok "REACHABILITY: pending gate, and BOTH filer expressions resolve EMPTY" \
  || bad "REACHABILITY: fixture is not the empty-filer shape — every arm below is vacuous" \
         "cancel_filer='$q_cancel_filer' withdraw_filer='$q_wd_filer' type='$q_type'"

# ── A: cancel over an open gate, empty filer ──────────────────────────────────
a_err=$("$FIVE" task cancel "$Q" --result="abandoning this" 2>&1 >/dev/null); a_rc=$?
a_status=$(sqlite3 "$DB" "SELECT status FROM tasks WHERE ident='$Q';")
(( a_rc == 5 )) \
  && ok "A1: the cancel refuses with the guard's own rc (5), not an errexit abort (rc=1)" \
  || bad "A1: empty filer aborts the guard instead of refusing" "rc=$a_rc err='$a_err'"
[[ "$a_err" != *"without reporting a reason"* ]] \
  && ok "A2: no 'exited without reporting a reason' banner (the iteration-1 symptom)" \
  || bad "A2: the iteration-1 bug banner is back" "err='$a_err'"
[[ "$a_err" == *"5dive task answer $Q --value="* ]] \
  && ok "A3: the two-exit refusal PRINTS, and still names the ANSWER route first" \
  || bad "A3: the refusal text never reached the caller on an empty filer" "err='$a_err'"
[[ "$a_err" == *"5dive task need $Q --withdraw"* ]] \
  && ok "A4: ...and still names --withdraw as the second exit" \
  || bad "A4: --withdraw vanished from the empty-filer refusal" "err='$a_err'"
# The unresolvable principals must render as the placeholder the DIVE-2382 text
# promises, not vanish — "this route does not exist here" vs "never offered".
[[ "$a_err" == *"unknown"* && "$a_err" == *"none"* ]] \
  && ok "A5: unresolvable filer/lead/coordinator render as 'unknown'/'none' (DIVE-2382 placeholders hold)" \
  || bad "A5: an unresolved principal vanished from the enumeration" "err='$a_err'"
[[ "$a_status" == "todo" ]] \
  && ok "A6: the row is left open — a refused cancel destroys nothing" \
  || bad "A6: the row moved despite the refusal" "status='$a_status'"

# ── B: withdraw over the same row (the PRE-EXISTING half, same shape) ─────────
b_err=$("$FIVE" task need "$Q" --withdraw 2>&1 >/dev/null); b_rc=$?
b_type=$(sqlite3 "$DB" "SELECT COALESCE(need_type,'') FROM tasks WHERE ident='$Q';")
(( b_rc != 0 )) && [[ "$b_err" != *"without reporting a reason"* ]] \
  && ok "B1: the WITHDRAW refusal also survives an empty filer (rc=$b_rc, no bug banner)" \
  || bad "B1: the withdraw path aborts on an empty filer" "rc=$b_rc err='$b_err'"
[[ "$b_err" == *"withdraw"* ]] \
  && ok "B2: ...and it is the withdraw guard's own message, not a shell error" \
  || bad "B2: the withdraw refusal text is missing" "err='$b_err'"
[[ "$b_type" == "decision" ]] \
  && ok "B3: the gate survives the refused withdraw" \
  || bad "B3: the gate was cleared by a refused withdraw" "need_type='$b_type'"

printf '\n%d passed, %d failed\n' "$P" "$F"
[[ $F -eq 0 ]]
