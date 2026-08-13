#!/usr/bin/env bash
# DIVE-3330: `task verify --cmd=true` must not close a row past the merge gate.
#
# The gate lives in _task_status_cmd (done/cancel); cmd_task_verify flips with a raw
# UPDATE in a different function, so a row can reach status=done with its delivery
# unmerged and nothing records that the question was never asked. Two measured
# receipts: DIVE-2743 (closed on a unit test run in a local worktree; its test file is
# absent from main) and DIVE-2645 (graded "at worktree tip c2baa6b", PR still open).
#
# A passing command proves only what the command checked. When a row carries a
# delivery binding, verify records the structural grade and holds the row open for
# the merge owner; `task done` remains the only close path that answers ancestry.
#
# The unbound control must still auto-close, so a mutation that merely disables every
# verify close cannot make this harness green.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "${TMP:-}" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT=$PWD
CLI="$ROOT/5dive"
# DIVE-3059 instance 1, and it is this file's own defect: the SKIP below used to
# exit 0, so a tree that had not run ./build.sh reported this harness as GREEN. That
# is what let main stay red for six commits while every local check said fine. A
# precondition this harness NEEDS is a FAILURE, not a skip — the escape is explicit
# and local-only, matching ACP_ALLOW_SKIP in tests/acp_stdio_unit.sh.
if [[ ! -x "$CLI" ]]; then
  if [[ "${BUNDLE_ALLOW_SKIP:-}" == "1" ]]; then
    echo "SKIP - no built bundle at $CLI (BUNDLE_ALLOW_SKIP=1); NOTHING WAS GRADED"; exit 0
  fi
  echo "FAIL - no built bundle at $CLI — run ./build.sh. This harness grades the CLI"
  echo "       end-to-end and cannot run without one; refusing to exit 0 and be read as"
  echo "       coverage. Set BUNDLE_ALLOW_SKIP=1 to skip deliberately (local only)."
  echo "0 passed, 1 failed"; exit 1
fi


TMP=$(mktemp -d)
# ISOLATION. The CLI reads TASKS_DB / TASKS_DIR / STATE_DIR (src/lib/tasks_db.sh);
# it has never read FIVE_TASKS_DB, which is what this line said until DIVE-3059 and
# is why the isolation was a no-op: on a host with real state the fixture rows landed
# on the PRODUCTION board (18 of them), and on a fresh CI runner `task add` had no
# initialised state to fall back to and failed 0/5. One wrong variable name, two
# opposite symptoms, and the local one looked like a pass.
export TASKS_DB="$TMP/tasks.db"
export TASKS_DIR="$TMP"      # the .board-initialized marker lives HERE, not beside the db
export STATE_DIR="$TMP/state"
export HOME="$TMP"          # keep the fixture off the real board

# The isolated store must exist before the bundle is driven, and `5dive task init`
# is require_root by design (src/cmd_task.sh) because it writes /var/lib — so a
# non-root CI runner can NEVER create one that way, and every `task add` refuses
# with "tasks store not initialised". That is the whole CI failure. The root check
# is on the COMMAND, not the library, so init IN-PROCESS the way every other
# harness does, then hand the bundle the path and keep grading the CLI end-to-end
# as a black box. DIVE-3059.
( for _f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
            lib/state.sh lib/tasks_db.sh; do . "${ROOT:-$PWD}/src/$_f"; done
  set +e; mkdir -p "$(dirname "$TASKS_DB")"; tasks_db_init; _tasks_db_migrate ) >/dev/null 2>&1
[[ -s "$TASKS_DB" ]] || { echo "FAIL - could not create the isolated tasks store at $TASKS_DB"; echo "0 passed, 1 failed"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

HOLD='merge-gate hold (DIVE-3330)'

# add <title> [body]  -> echoes the ident
mk() {
  local out
  out=$("$CLI" task add "$1" ${2:+--body="$2"} --assignee=main 2>/dev/null) || return 1
  printf '%s' "$out" | grep -oE 'DIVE-[0-9]+|[A-Z]+-[0-9]+' | head -1
}
res_of() { "$CLI" task show "$1" 2>/dev/null | sed -n '/result =/,$p'; }
field_of() { sqlite3 "$TASKS_DB" "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }

# --- A: a row binding a BRANCH in prose -> grade recorded, row stays open --
A=$(mk "hold arm A" "Branch: IDENT-some-feature-branch")
if [[ -n "$A" ]]; then
  # The DIVE-2577 rule anchors on the row's OWN ident, so the body must name it.
  "$CLI" task set-body "$A" "Branch: ${A,,}-some-feature-branch" >/dev/null 2>&1
  "$CLI" task verify "$A" --cmd=true >/dev/null 2>&1; A_RC=$?
  [[ "$A_RC" -eq 0 ]] \
    && ok_t "A: passing verify still exits 0 while holding the close" \
    || bad_t "A: passing verify still exits 0" "rc=$A_RC"
  [[ "$(field_of "$A" status)" != "done" ]] \
    && ok_t "A RED: --cmd=true cannot close a branch-bound row" \
    || bad_t "A RED: --cmd=true cannot close a branch-bound row" "status=done — raw UPDATE bypass survived"
  [[ -n "$(field_of "$A" graded_at)" ]] \
    && ok_t "A: held verify stamps the structural grade" \
    || bad_t "A: held verify stamps the structural grade" "graded_at is empty"
  res_of "$A" | grep -q "$HOLD" \
    && ok_t "A: result names the merge hold" \
    || bad_t "A: result names the merge hold" "hold marker absent"
  res_of "$A" | grep -q "${A,,}-some-feature-branch" \
    && ok_t "A: the hold names the binding it did not check" \
    || bad_t "A: the stamp NAMES the binding it did not check" "binding absent from result"
else
  bad_t "A: fixture row could not be created" "task add failed"
fi

# --- B: delivery_ref -> the DIVE-3315 terminal render ----------------------
B=$(mk "hold arm B" "Delivered and awaiting verifier grade.")
if [[ -n "$B" ]]; then
  sqlite3 "$TASKS_DB" "UPDATE tasks SET delivery_ref='https://github.com/example/repo/pull/4242', maker_agent='fixturemaker', verifier='main', assignee='main' WHERE ident='$B';"
  "$CLI" task verify "$B" --cmd=true >/dev/null 2>&1
  [[ "$(field_of "$B" status)" != "done" && -n "$(field_of "$B" graded_at)" ]] \
    && ok_t "B RED: delivery_ref row is graded but remains open" \
    || bad_t "B RED: delivery_ref row is graded but remains open" "status=$(field_of "$B" status), graded_at=$(field_of "$B" graded_at)"
  "$CLI" task ls --all 2>/dev/null | grep -F "$B" | grep -q 'graded->merge:fixturemaker' \
    && ok_t "B: held row renders graded->merge and names the merge owner" \
    || bad_t "B: held row renders graded->merge and names the merge owner" "render missing"
else
  bad_t "B: fixture row could not be created"
fi

# --- C: NEGATIVE — no binding at all -> NOT stamped ------------------------
# The arm that keeps this from becoming noise. A row with nothing to merge has no
# question to leave unanswered.
#
# DIVE-3265 — THIS ARM WAS BLIND, AND THAT BLINDNESS IS WHY THE CRASH SHIPPED.
# `grep -q "$STAMP"` returning false has TWO causes and the arm could not tell
# them apart: (a) the row closed cleanly and correctly carried no stamp, or
# (b) `task verify` DIED before writing anything, so `result` is empty and of
# course does not contain the stamp. (b) is what actually happened on every run
# from the day DIVE-2938 shipped: the no-binding body is exactly the input that
# makes the extractor's `grep` exit 1, `pipefail` promote it, and the unguarded
# `$( )` kill the verb under `set -euo pipefail`. The arm was green throughout.
# So the negative is now stated from BOTH ends — no stamp AND the close actually
# happened (rc 0, status done, result written). An absence assertion that cannot
# fail when the verb never ran is not coverage.
C=$(mk "stamp arm C" "A research row. No branch, no PR, nothing to land.")
if [[ -n "$C" ]]; then
  "$CLI" task verify "$C" --cmd=true >/dev/null 2>&1; C_RC=$?
  res_of "$C" | grep -q "$HOLD" \
    && bad_t "C NEGATIVE: no binding -> must NOT be held" "held a row with nothing to merge" \
    || ok_t "C NEGATIVE: no binding -> no merge hold"
  [[ "$C_RC" -eq 0 ]] \
    && ok_t "C: the close SUCCEEDED (rc=0) — DIVE-3265, the arm above is not green by crash" \
    || bad_t "C: the close SUCCEEDED (rc=0)" "rc=$C_RC — an unguarded probe assignment killed the verb; the stamp arm above passed for the wrong reason"
  [[ "$("$CLI" task show "$C" 2>/dev/null | grep -m1 'status' | tr -d ' ')" == "status=done" ]] \
    && ok_t "C: the row actually reached status=done (DIVE-3265 control)" \
    || bad_t "C: the row actually reached status=done" "status never flipped — verify did not complete"
else
  bad_t "C: fixture row could not be created"
fi

# --- F: DIVE-3265 — a body naming an ARTIFACT FILE is not a branch binding ----
# The merge-gate's discovery rule is shared with `task done`, so a file basename
# misread as a branch does not just mis-stamp here — one file over it produces a
# refusal the row can never satisfy. Graded at the verb because that is where the
# reader meets it: a design-doc row must close CLEAN and unstamped.
F=$(mk "stamp arm F" "placeholder")
if [[ -n "$F" ]]; then
  "$CLI" task set-body "$F" "Delivered: community/designs/${F,,}-svc-account-split.md" >/dev/null 2>&1
  "$CLI" task verify "$F" --cmd=true >/dev/null 2>&1; F_RC=$?
  res_of "$F" | grep -q "$HOLD" \
    && bad_t "F NEGATIVE: an .md artifact must NOT read as a branch binding" \
             "held a non-repo deliverable; one file over, this same rule REFUSES the close outright (DIVE-3264)" \
    || ok_t "F NEGATIVE: a design-doc deliverable is not merge-held"
  [[ "$F_RC" -eq 0 && "$("$CLI" task show "$F" 2>/dev/null | grep -m1 'status' | tr -d ' ')" == "status=done" ]] \
    && ok_t "F: the design-doc row closes clean (rc=0, done)" \
    || bad_t "F: the design-doc row closes clean" "rc=$F_RC"
else
  bad_t "F: fixture row could not be created"
fi

# --- G: DIVE-3265 source pin — the sibling call site is GUARDED ---------------
# DIVE-2603 fixed this exact hazard at the `task done` call site and pinned it
# there with the same shape; this site shipped later (DIVE-2938) and reintroduced
# it. Both callers of the extractor are guarded now — pin both, or the next new
# call site repeats it a third time.
grep -qE 'branches=\$\(_gate_branch_refs_from_text .*\) \|\| branches=' "$ROOT/src/cmd_task.sh" "$ROOT"/src/task/*.sh \
  && ok_t "G: the verify-hold helper GUARDS the probe assignment (DIVE-3265)" \
  || bad_t "G: verify-hold helper guarded" "unguarded \$( ) — under set -e + pipefail a body naming no branch kills task verify"

# --- D: NEGATIVE — --no-done does not close, so it must not stamp ----------
D=$(mk "stamp arm D" "placeholder")
if [[ -n "$D" ]]; then
  "$CLI" task set-body "$D" "Branch: ${D,,}-unlanded" >/dev/null 2>&1
  "$CLI" task verify "$D" --no-done --cmd=true >/dev/null 2>&1
  res_of "$D" | grep -q "$HOLD" \
    && bad_t "D NEGATIVE: explicit --no-done must not claim an automatic hold" "unexpected hold marker" \
    || ok_t "D NEGATIVE: explicit --no-done records without automatic-hold prose"
  [[ "$("$CLI" task show "$D" 2>/dev/null | grep -m1 'status' | tr -d ' ')" == "status=done" ]] \
    && bad_t "D: --no-done must leave status unflipped" "row went done" \
    || ok_t "D: --no-done left status unflipped (control for arm D)"
else
  bad_t "D: fixture row could not be created"
fi

# --- E: NEGATIVE — a FAILING verify does not close, so it must not stamp ---
E=$(mk "stamp arm E" "placeholder")
if [[ -n "$E" ]]; then
  "$CLI" task set-body "$E" "Branch: ${E,,}-unlanded" >/dev/null 2>&1
  "$CLI" task verify "$E" --cmd=false >/dev/null 2>&1
  "$CLI" task verify "$E" --cmd=false >/dev/null 2>&1; E_RC=$?
  res_of "$E" | grep -q "$HOLD" \
    && bad_t "E NEGATIVE: a FAIL must NOT claim a merge hold" "hold marker on a failing verify" \
    || ok_t "E NEGATIVE: a failing verify records the FAIL without hold prose"
  # DIVE-3265 (Marcus's merge condition): ASSERT THE EXIT STATUS, NOT THE MESSAGE.
  # A verb that fails while returning 0 is the nastier half of this ticket's class —
  # every caller reading `$?` (a script, a loop, a cron) sees success and carries on.
  # The message is for a human at a terminal; the status is the only thing the rest of
  # the fleet reads, so it gets its own arm rather than riding on the prose.
  #
  # WHAT WAS ACTUALLY MEASURED, because it corrects the ticket body: the CRASH path
  # exits 1, not 0. Built bundle, guard reverted as a negative control, no-branch row:
  # rc=1, and the DIVE-2598 backstop prints "5dive task exited 1 without reporting a
  # reason". So "rc=0 despite failing" does not reproduce at the CLI boundary and
  # nothing was changed for it — but the property it was worried about is real and is
  # now pinned here and at arm C, from both directions: a FAIL is non-zero, a clean
  # close is zero.
  [[ "$E_RC" -ne 0 ]] \
    && ok_t "E: a failing verify EXITS NON-ZERO (rc=$E_RC) — a caller reading \$? cannot read it as success" \
    || bad_t "E: a failing verify exits non-zero" "rc=0 on a FAIL — every scripted caller reads this run as a success"
else
  bad_t "E: fixture row could not be created"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
