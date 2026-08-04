#!/usr/bin/env bash
# DIVE-2680 regression guard: `5dive agent export <name> --with-memory` on a
# seat with NO ~/.claude/projects dir at all (every non-claude-type agent —
# opencode, codex never create Claude Code's session store) used to die
# silently: rc=1, zero bytes on stdout AND stderr, nothing written.
#
# Root cause: _pack_memory_dir (src/cmd_pack.sh) does
#   [[ -d "$base" ]] || return 1
# and cmd_export's draft phase assigned its result unguarded:
#   local memdir; memdir=$(_pack_memory_dir "$name")
# Under the CLI's `set -euo pipefail`, that assignment failing kills the
# process BEFORE the very next line's `fail()` call ever runs — same shape as
# community/wiki/a-cli-that-exits-non-zero-without-a-reason.md, just wearing a
# `return 1` instead of that page's grep/curl -f/jq -e shape.
#
# For a claude-type agent the projects dir always exists (even with no memory
# facts in it), so _pack_memory_dir instead returns EMPTY with rc=0 — that path
# already worked and reached the `fail "$E_NOT_FOUND" "... has no persona
# memory to export"` message. THIS harness's job is the return-1 path, which
# is exactly the path a claude-type fixture cannot exercise.
#
# Sources src/ directly (no root, no network, no agent user). Grades the real
# call site in cmd_export by running it in a CHILD bash with `set -e` actually
# live (this harness's own `set +e`, needed so ok_/bad_ survive a probed
# non-zero return, would otherwise mask the very defect under test — the
# child process is what keeps `set -e` load-bearing here).
#
# Run: bash tests/pack_export_memory_dir_missing_unit.sh
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits).

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

PASS=0; FAIL=0
ok_()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# A child bash gets a genuinely fresh `set -e` (this harness's own `set +e`
# below, needed to survive probing non-zero rc's, cannot leak into it). It
# sources the real sources, stubs require_root/require_agent (out of scope —
# this defect is about the memory-dir assignment, not auth) and the two
# arg-independent bits of _pack_agent_config/persona rendering that would
# otherwise need a real /home/agent-<name> tree, then calls the REAL
# cmd_export exactly as `5dive agent export <name> --with-memory` does.
# $1 = the shape of _pack_memory_dir to install ("missing-dir" reproduces the
# defect; "empty-result" is the already-working claude-type control).
run_export() {
  local shape="$1"
  bash -c '
    set -euo pipefail
    SRC="$1"; shape="$2"
    for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
      source "$SRC/$f"
    done
    source "$SRC/cmd_pack.sh"
    require_root()  { :; }
    require_agent() { :; }
    if [[ "$shape" == missing-dir ]]; then
      _pack_memory_dir() { return 1; }     # DIVE-2680: the opencode/codex shape
    else
      _pack_memory_dir() { return 0; }     # the already-working claude-type shape (empty, rc=0)
    fi
    cmd_export nosuch-agent-2680 --with-memory
  ' _ "$SRC" "$shape"
}

# ---- 1. the defect shape: no ~/.claude/projects dir at all -----------------
OUT=$(run_export missing-dir 2>&1); RC=$?
[[ $RC -ne 0 ]] && ok_ "missing-dir: cmd_export exits non-zero" \
                || bad_ "missing-dir: cmd_export exits non-zero" "rc=$RC out=[$OUT]"
[[ -n "$OUT" ]] && ok_ "missing-dir: something is printed (not the silent zero-byte death)" \
                || bad_ "missing-dir: something is printed (not the silent zero-byte death)" "0 bytes on stdout+stderr — DIVE-2680 regressed"
printf '%s' "$OUT" | grep -qi 'no persona memory to export' \
  && ok_ "missing-dir: the existing, specific refusal message is what prints" \
  || bad_ "missing-dir: the existing, specific refusal message is what prints" "out=[$OUT]"

# ---- 2. control: the already-working claude-type shape still works --------
COUT=$(run_export empty-result 2>&1); CRC=$?
[[ $CRC -ne 0 ]] && ok_ "control (empty-result): also exits non-zero" \
                 || bad_ "control (empty-result): also exits non-zero" "rc=$CRC out=[$COUT]"
printf '%s' "$COUT" | grep -qi 'no persona memory to export' \
  && ok_ "control (empty-result): same message, unaffected by the fix" \
  || bad_ "control (empty-result): same message, unaffected by the fix" "out=[$COUT]"

# ---- 3. mutation: reverting the guard reproduces the silent death ---------
# Proves this harness actually grades the fix rather than agreeing with
# itself: with the unguarded assignment restored, arm 1 must go back to zero
# bytes on both streams.
MOUT=$(bash -c '
  set -euo pipefail
  SRC="$1"
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
    source "$SRC/$f"
  done
  source "$SRC/cmd_pack.sh"
  require_root()  { :; }
  require_agent() { :; }
  _pack_memory_dir() { return 1; }
  # The pre-fix line, reproduced verbatim (no `|| memdir=""`).
  export_draft_prefix_mutant() {
    local memdir; memdir=$(_pack_memory_dir "x")
    echo "UNREACHABLE: $memdir"
  }
  export_draft_prefix_mutant
' _ "$SRC" 2>&1); MRC=$?
{ [[ $MRC -ne 0 ]] && [[ -z "$MOUT" ]]; } \
  && ok_ "mutation control: the pre-fix (unguarded) line dies with ZERO bytes, confirming this harness grades the real defect" \
  || bad_ "mutation control: the pre-fix line should die with zero bytes" "rc=$MRC out=[$MOUT] — if this is non-empty the harness above is not grading DIVE-2680"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
