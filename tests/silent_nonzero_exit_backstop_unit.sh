#!/usr/bin/env bash
# DIVE-2598 — THE CLI MUST NEVER EXIT NON-ZERO WITHOUT SAYING WHY.
#
# THE INCIDENT. `5dive task done DIVE-2597 --result="plain text no refs"` exited 1
# with ZERO bytes on stdout AND stderr, and left the row open. Nothing printed,
# nothing the caller could act on; a caller that reads only output saw success.
# It cost the reporter three attempts and a `bash -x` of the installed binary.
# The line was an unguarded `_br_cands=$(_gate_branch_refs_from_text ...)` whose
# pipeline ends in `grep` — exit 1 on no-match, promoted by `pipefail`, fatal
# under `set -e` BEFORE any handler could print. DIVE-2603 guarded that line, and
# `tests/task_merge_gate_branch_in_result_unit.sh` pins it.
#
# WHAT THIS FILE GRADES IS THE OTHER HALF, AND IT IS NOT THE SAME HALF. DIVE-2566
# was the identical shape in `5dive push` one file over, in the same release. Two
# per-line guards do not make a third unguarded substitution any less likely — an
# unguarded `$( )` is a normal thing to write. The property that has to hold is
# that WHATEVER kills this CLI, the exit carries a reason. So the backstop is
# graded here against a REAL induced death in a REAL built bundle, not against the
# one line that happened to cause it: stub `sqlite3` to exit 1 on PATH and any
# db-reading verb dies exactly the DIVE-2598 way. The mutant arm proves the
# hazard is live in this tree and that the green arm is not green by vacuity.
#
# THE FALSE-POSITIVE HALF IS AS LOAD-BEARING AS THE TRUE ONE. A backstop that
# fires after an error that DID print appends "no reason was given" to a message
# that gave one — the report would then be wrong exactly when the CLI was right.
# So every reported-exit shape gets an arm: fail()'s own path, the
# `<verb>_usage; exit "$E_USAGE"` sites that never reach fail(), and success.
#
# HOW THE POPULATION WAS ENUMERATED, because reading did not find it. The backstop
# has to stay quiet for every deliberate non-zero exit that prints its own reason
# and never routes through fail(). Reading src/ found the seven
# `<verb>_usage; exit "$E_USAGE"` sites and cmd_account's in-use refusal. It MISSED
# `cmd_whoami.sh`'s UNMEASURABLE refusal, which builds its own
# `{ok:false,…,data:{…}}` envelope (fail() cannot carry `data`) — the core tier
# caught that one red, which is the only reason the count is not still wrong.
# So the set is enumerated by OPERATION over the BUILT bundle, not by inspection:
#
#   grep -nE '(^|[;&|[:space:]])exit[[:space:]]+("?\$[A-Za-z_]\w*"?|[1-9][0-9]*)' 5dive
#   grep -rn 'ok:false' src/ | grep -v src/lib/output.sh      # the whoami shape
#
# 35 hits, classified: 10 marked in-process sites (fail() itself, cmd_account,
# cmd_whoami, 7 usage exits) + 2 `trap '… exit 130' INT TERM` (covered by the
# signal rule) + 2 `_tasks_alarm …; exit 3` inside a `( flock 9 )` SUBSHELL, which
# cannot double-report because a `( )` subshell does not run the parent's EXIT trap
# (measured, bash 5.2) + 12 inside heredoc'd `bash -s` installers that are a
# DIFFERENT PROCESS and never reach our trap + 9 that are comments, awk programs or
# JS. The second grep answers "what else builds its own envelope": exactly two,
# cmd_account and cmd_whoami, both marked. Re-run both greps when this file is
# touched — the population is the thing that drifts, not the mechanism.
#
# MUTATION GRADE — RUN, not asserted. Six mutations against the committed tree at
# a2c41bf (rebased onto b64b6da), each reverted after; every one turns this file
# red, and on the arms named. Baseline 11/0. Later commits on this branch touch
# only this header — `git diff a2c41bf HEAD -- src/` is EMPTY, so the graded
# mechanism is the shipped one.
#   * `mark_reported() { : ; }`                    -> 8/3  (arms 3, 4, 7)
#   * drop `mark_reported` from fail()             -> 9/2  (arms 3, 7)
#   * drop `mark_reported` from the usage sites    -> 10/1 (arm 4)
#   * `_report_silent_exit() { return 0; }`        -> 6/5  (arms 1, 1b, 6, 8-liveness, 9)
#   * move `_report_silent_exit` BELOW the `[[ -n "$AUDIT_CMD" ]]` return in
#     on_exit_audit                                -> 7/4  (arms 1, 1b, 6, 9)
#   * drop the 130/143 suppression                 -> 10/1 (arm 8, first half)
# Arm 7 survives the reporter being dead ON PURPOSE — it asserts the real message
# is still printed and the backstop stays quiet, so only the marker can move it.
#
# Runs the SHIPPED artifact: builds a throwaway bundle via BUILD_OUT (43ms) and
# executes it. The only verbs it runs are read-only (`task ls`, `--version`) or
# argument errors that never reach the store, and the db-reading ones are run
# with `sqlite3` stubbed dead so they cannot touch the live tasks.db at all.
# Run: bash tests/silent_nonzero_exit_backstop_unit.sh   (no root, no network.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
. "$(dirname "${BASH_SOURCE[0]}")/lib/env_isolation.sh" 2>/dev/null || true
declare -F _five_env_isolate >/dev/null && _five_env_isolate
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/silent-nonzero-backstop.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BACKSTOP_RE='without reporting a reason'

BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$TMP/build.log" 2>&1; then
  bad_t 'build a throwaway bundle to grade' "$(tail -3 "$TMP/build.log")"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# THE MUTANT: the same bundle with the backstop's body replaced by `:`. This is
# the pre-DIVE-2598 CLI, built from THIS tree, so arm 2 measures the difference
# the change makes rather than asserting a remembered fact about an old release.
MUT="$TMP/5dive-mutant"
awk '
  /^_report_silent_exit\(\) \{/ { print "_report_silent_exit() { : ; }"; skip=1; next }
  skip && /^\}/                 { skip=0; next }
  skip                          { next }
  { print }
' "$BIN" > "$MUT"
chmod +x "$MUT"
if ! grep -q '^_report_silent_exit() { : ; }' "$MUT"; then
  bad_t 'build the neutered-backstop mutant' 'the awk rewrite did not take — arm 2 would grade nothing'
fi

# `sqlite3` dead on PATH is the induction: every store read in this CLI goes
# through it, and an unguarded one dies exactly the DIVE-2598 way. Chosen over
# patching a source line so the arm cannot be satisfied by a guard added to one
# call site.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sqlite3"; chmod +x "$TMP/bin/sqlite3"
DEADPATH="$TMP/bin:$PATH"

RC=0; OUT=""; ERR=""
run() {  # run <bin> [args...] — captures rc, stdout (OUT), stderr (ERR) separately
  local bin="$1"; shift
  RC=0
  OUT=$("$bin" "$@" 2>"$TMP/err.txt") || RC=$?
  ERR=$(cat "$TMP/err.txt")
}
run_dead() { local bin="$1"; shift; PATH="$DEADPATH" run "$bin" "$@"; }

# --- 1. THE DEFECT, REPRODUCED AND REPORTED ----------------------------------
# `task ls` is READ-ONLY, so AUDIT_CMD is unset for it: this arm also proves the
# report is not hung off the audit subsystem's early return.
run_dead "$BIN" task ls
if [[ $RC -ne 0 && "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t "an induced set -e death exits non-zero AND says so (DIVE-2598 shape, read-only verb)"
else
  bad_t 'induced silent death must be reported' "rc=$RC stdout=${#OUT}B stderr=[${ERR:0:200}]"
fi
[[ "$ERR" == *"5dive task"* && "$ERR" == *"5dive bug"* ]] \
  && ok_t 'the report names the verb that died and where to file it' \
  || bad_t 'report should name verb + 5dive bug' "stderr=[${ERR:0:300}]"

# --- 2. THE DIFFERENTIAL: the same run, backstop neutered --------------------
run_dead "$MUT" task ls
if [[ $RC -ne 0 && -z "$OUT" && -z "$ERR" ]]; then
  ok_t "non-vacuity: with the backstop neutered the SAME run is rc=$RC with zero bytes on both streams"
else
  bad_t 'the mutant must reproduce the silent exit' "rc=$RC stdout=${#OUT}B stderr=${#ERR}B — if this is not silent, arm 1 is grading nothing"
fi

# --- 3. NO FALSE POSITIVE: an error that fail() already reported -------------
run "$BIN" zzznotacommand
if [[ $RC -ne 0 && "$ERR" == *"unknown command"* && ! "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t 'an error printed by fail() is NOT also reported as unexplained'
else
  bad_t 'fail() path must suppress the backstop' "rc=$RC stderr=[${ERR:0:300}]"
fi

# --- 4. NO FALSE POSITIVE: a usage exit that never reaches fail() ------------
# `{ _task_usage; exit "$E_USAGE"; }` prints its reason and exits directly, so it
# has to mark itself reported or the backstop calls a printed usage page silent.
run "$BIN" task
if [[ $RC -ne 0 && -n "$ERR$OUT" && ! "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t 'a verb usage page + direct exit is NOT reported as unexplained'
else
  bad_t 'usage-exit sites must mark themselves reported' "rc=$RC stderr=[${ERR:0:200}]"
fi

# --- 5. NO FALSE POSITIVE: success ------------------------------------------
run "$BIN" --version
[[ $RC -eq 0 && ! "$ERR" =~ $BACKSTOP_RE ]] \
  && ok_t 'a successful command reports nothing' \
  || bad_t 'success must stay quiet' "rc=$RC stderr=[${ERR:0:200}]"

# --- 6. --json: stdout must still carry a parseable envelope -----------------
# A silent death under --json is WORSE than in text mode: the caller is parsing
# stdout, and an empty stdout with a bare rc is indistinguishable from a crash of
# the pipeline itself.
run_dead "$BIN" --json task ls
if [[ $RC -ne 0 ]] && jq -e '.ok == false and (.error.message | test("without reporting a reason"))' <<<"$OUT" >/dev/null 2>&1; then
  ok_t '--json emits {ok:false,error:{...}} on stdout instead of nothing'
else
  bad_t '--json must emit an error envelope' "rc=$RC stdout=[${OUT:0:300}]"
fi

# --- 7-9. PROPERTIES REACHABLE ONLY FROM INSIDE ------------------------------
# Sourced from the same src/ files the bundle above was built from.
rig() {  # rig <body> — runs <body> under set -euo pipefail with the real primitives
  bash -c '
    set -euo pipefail
    . "$1/lib/error_codes.sh" 2>/dev/null || true
    . "$1/lib/output.sh"
    AUDIT_CMD=""; declare -a AUDIT_ARGS=()
    . "$1/lib/audit.sh" 2>/dev/null || true
    eval "$2"
  ' _ "$PWD/$SRC" "$1" 2>&1
}

# 7. fail() inside a command substitution. Its `mark_reported` runs in a SUBSHELL,
#    whose variable writes the exiting parent can never see — which is why the
#    marker is a file. If this regresses, every subshell error prints twice: its
#    real message and a backstop claiming there wasn't one.
out=$(rig 'trap on_exit_audit EXIT; x=$(fail 5 "boom in a subshell"); echo "unreachable: $x"')
if [[ "$out" == *"boom in a subshell"* && "$out" != *"without reporting a reason"* ]]; then
  ok_t 'fail() in a command substitution marks the parent reported (file marker, not a variable)'
else
  bad_t 'subshell fail() must suppress the parent backstop' "out=[${out:0:300}]"
fi

# 8. Signals are not unreported failures — and the liveness half proves the
#    suppression is a case, not the whole function being dead.
out=$(rig '_report_silent_exit 130; echo "END"')
[[ "$out" == "END" ]] \
  && ok_t 'exit 130 (Ctrl-C) is not reported as an unexplained failure' \
  || bad_t 'signal exits must be suppressed' "out=[${out:0:200}]"
out=$(rig '_report_silent_exit 1; echo "END"')
[[ "$out" == *"without reporting a reason"* ]] \
  && ok_t 'liveness pair: the same function DOES report a plain rc=1' \
  || bad_t 'the reporter must fire on a non-signal code' "out=[${out:0:200}]"

# 9. The report runs ahead of the AUDIT_CMD early-return.
out=$(rig 'trap on_exit_audit EXIT; AUDIT_CMD=""; false; :')
[[ "$out" == *"without reporting a reason"* ]] \
  && ok_t 'a read-only command (AUDIT_CMD unset) is still reported' \
  || bad_t 'the report must precede the audit early-return' "out=[${out:0:200}]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
