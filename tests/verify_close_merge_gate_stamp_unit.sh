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
[[ -x "$CLI" ]] || { echo "SKIP - no built bundle at $CLI (run ./build.sh)"; exit 0; }

TMP=$(mktemp -d)
export FIVE_TASKS_DB="$TMP/tasks.db"
export HOME="$TMP"          # keep the fixture off the real board
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
