#!/usr/bin/env bash
# DIVE-2938: `task verify` closes a row without ever running the DIVE-1830 merge gate.
#
# The gate lives in _task_status_cmd (done/cancel); cmd_task_verify flips with a raw
# UPDATE in a different function, so a row can reach status=done with its delivery
# unmerged and nothing records that the question was never asked. Two measured
# receipts: DIVE-2743 (closed on a unit test run in a local worktree; its test file is
# absent from main) and DIVE-2645 (graded "at worktree tip c2baa6b", PR still open).
#
# This harness grades the LEGIBILITY fix, not a gate: a verify-close on a row that
# carries a binding the merge gate WOULD have checked must stamp the result saying it
# was not checked, and a row with no binding must NOT be stamped.
#
# The negative arms are the load-bearing ones. A stamp that fires on everything is
# noise people learn to skip, and a stamp that fires on --no-done or on FAIL would be
# claiming a close that did not happen.
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

STAMP='merge-gate NOT EVALUATED'

# add <title> [body]  -> echoes the ident
mk() {
  local out
  out=$("$CLI" task add "$1" ${2:+--body="$2"} --assignee=main 2>/dev/null) || return 1
  printf '%s' "$out" | grep -oE 'DIVE-[0-9]+|[A-Z]+-[0-9]+' | head -1
}
res_of() { "$CLI" task show "$1" 2>/dev/null | sed -n '/result =/,$p'; }

# --- A: a row binding a BRANCH in prose -> stamped -------------------------
A=$(mk "stamp arm A" "Branch: IDENT-some-feature-branch")
if [[ -n "$A" ]]; then
  # The DIVE-2577 rule anchors on the row's OWN ident, so the body must name it.
  "$CLI" task set-body "$A" "Branch: ${A,,}-some-feature-branch" >/dev/null 2>&1
  "$CLI" task verify "$A" --cmd=true >/dev/null 2>&1
  if res_of "$A" | grep -q "$STAMP"; then
    ok_t "A: branch-in-prose binding -> verify close IS stamped"
  else
    bad_t "A: branch-in-prose binding -> verify close IS stamped" \
          "no stamp; the DIVE-2577 discovery rule did not fire on '${A,,}-some-feature-branch'"
  fi
  res_of "$A" | grep -q "${A,,}-some-feature-branch" \
    && ok_t "A: the stamp NAMES the binding it did not check" \
    || bad_t "A: the stamp NAMES the binding it did not check" "binding absent from result"
else
  bad_t "A: fixture row could not be created" "task add failed"
fi

# --- B: a row binding a PR in prose -> stamped -----------------------------
B=$(mk "stamp arm B" "Delivered as PR #4242 and graded green.")
if [[ -n "$B" ]]; then
  "$CLI" task verify "$B" --cmd=true >/dev/null 2>&1
  res_of "$B" | grep -q "$STAMP" \
    && ok_t "B: PR-in-prose binding -> verify close IS stamped" \
    || bad_t "B: PR-in-prose binding -> verify close IS stamped"
else
  bad_t "B: fixture row could not be created"
fi

# --- C: NEGATIVE — no binding at all -> NOT stamped ------------------------
# The arm that keeps this from becoming noise. A row with nothing to merge has no
# question to leave unanswered.
C=$(mk "stamp arm C" "A research row. No branch, no PR, nothing to land.")
if [[ -n "$C" ]]; then
  "$CLI" task verify "$C" --cmd=true >/dev/null 2>&1
  res_of "$C" | grep -q "$STAMP" \
    && bad_t "C NEGATIVE: no binding -> must NOT be stamped" "stamped a row with nothing to merge" \
    || ok_t "C NEGATIVE: no binding -> not stamped"
else
  bad_t "C: fixture row could not be created"
fi

# --- D: NEGATIVE — --no-done does not close, so it must not stamp ----------
D=$(mk "stamp arm D" "placeholder")
if [[ -n "$D" ]]; then
  "$CLI" task set-body "$D" "Branch: ${D,,}-unlanded" >/dev/null 2>&1
  "$CLI" task verify "$D" --no-done --cmd=true >/dev/null 2>&1
  res_of "$D" | grep -q "$STAMP" \
    && bad_t "D NEGATIVE: --no-done must NOT stamp" "stamped a row that was never closed" \
    || ok_t "D NEGATIVE: --no-done records without stamping (no close happened)"
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
  res_of "$E" | grep -q "$STAMP" \
    && bad_t "E NEGATIVE: a FAIL must NOT stamp" "stamped on a failing verify" \
    || ok_t "E NEGATIVE: a failing verify records the FAIL without stamping"
else
  bad_t "E: fixture row could not be created"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
