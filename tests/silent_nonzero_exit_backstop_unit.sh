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
#   grep -nE '(^|[;&|[:space:]])exit[[:space:]]+("?\$\{?[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}?"?|[1-9][0-9]*)' 5dive
#   grep -rn 'ok:false' src/ | grep -v src/lib/output.sh      # the whoami shape
#   grep -nE "trap[[:space:]]+.*[[:space:]]EXIT([[:space:]]|$)" 5dive   # arm 11
#
# THE THIRD GREP IS THE ITERATION-1 GAP, and it is why exit sites are not the whole
# population. A property hung off a trap can be switched off by a line that contains
# no `exit` at all: `trap '_watch_teardown' EXIT` in cmd_watch REPLACED
# `trap on_exit_audit EXIT` for the rest of the process. The exit-site census
# classified those two verbs correctly and still could not see it. Arm 11 pins the
# trap population; arm 10/10b grade the behaviour. Re-run all THREE when this file
# is touched.
#
# CENSUS A — 37 hits on a fresh bundle at this tree, classified: 10 marked
# in-process sites (fail() itself, cmd_account, cmd_whoami, 7 usage exits) + 2
# `trap '… exit 130' INT TERM` (covered by the signal rule) + 2 `_tasks_alarm …;
# exit 3` inside a `( flock 9 )` SUBSHELL, which cannot double-report because a
# `( )` subshell does not run the parent's EXIT trap (measured, bash 5.2) + 12
# inside heredoc'd `bash -s` installers that are a DIFFERENT PROCESS and never
# reach our trap + 10 that are comments, awk programs or JS + 1 `exit
# "${E_PERMISSION:-13}"` in lib/tasks_db.sh. That last one is the BRACED form the
# first version of this regex could not see: harmless (the branch only runs with
# `fail` undefined, i.e. output.sh unsourced and no trap installed) but it was a
# hole in the instrument, so the regex above now spans `${…}` and `${…:-…}` and
# the count moved 35 → 36 (a comment, found on a re-count) → 37.
#
# CENSUS B answers "what else builds its own envelope": exactly two, cmd_account
# and cmd_whoami, both marked. CENSUS C is arm 11's expected set — 3 lines, one
# `trap on_exit_audit EXIT` and two identical `trap 'rm -rf "$TMPDIR"' EXIT` in
# heredoc'd installers. Its `([[:space:]]|$)` tail is load-bearing: it is what
# keeps the two PROSE mentions of the old clobbering line (in lib/output.sh and
# cmd_watch.sh, which build.sh ships verbatim) out of the census. Re-run all three
# when this file is touched — the population is what drifts, not the mechanism.
#
# MUTATION GRADE — RUN, not asserted. RE-TAKEN AT 6c35c00, on the branch merged with
# main (8412b71). Re-taken because iteration 2 changed src/, so the previous table's
# "`git diff a2c41bf HEAD -- src/` is EMPTY" no longer held — a mutation score
# transfers only while the graded tree is the shipped one. Taken three times in all
# (pre-merge, on a rebase that was abandoned to keep the PR fast-forward, and here)
# with identical results. Nothing after 6c35c00 touches src/ (only this comment
# block), so `git diff 6c35c00 HEAD -- src/` is empty and the graded mechanism is
# the shipped one. Eight mutations, each applied to the committed tree and reverted
# after (`git checkout -- src/`, tree verified clean at the end); every one turns
# this file red, on the arms named. Baseline 15/0, 1.7s on the dev box.
#   * `push_exit_handler() { : ; }`                -> 14/1 (arm 10)
#   * drop the `_five_run_exit_handlers` call from on_exit_audit  -> 14/1 (arm 10)
#   * cmd_watch back to `trap '_watch_teardown' EXIT`            -> 14/1 (arm 11)
#   * cmd_supervisor back to its raw `trap … EXIT`               -> 14/1 (arm 11)
#   * `mark_reported() { : ; }`                    -> 12/3 (arms 3, 4, 7)
#   * drop `mark_reported` from fail()             -> 13/2 (arms 3, 7)
#   * `_report_silent_exit() { return 0; }`        -> 9/6  (arms 1, 1b, 6, 8-liveness, 9, 10)
#   * drop the 130/143 suppression                 -> 14/1 (arm 8, first half)
# The last four are the iteration-1 table re-run unchanged in shape; the counts
# moved only because the baseline grew from 11 arms to 15. Note what the third and
# fourth mutations do NOT red: arms 10/10b, which inject into `whoami`. Restoring
# the clobbering line in a REAL verb is caught by the CENSUS and by nothing else
# in this file — which is the whole reason arm 11 exists, and why the real-verb
# behaviour is measured by hand in the ground-truth note below rather than here
# (it needs a TTY, so it cannot be a CI arm).
#
# GROUND TRUTH ON THE REAL VERB, because arms 10/10b carry the property on `whoami`
# (which needs no TTY) and a harness that only ever grades its own injection can be
# right about a shape and wrong about the shipped verb. Two arms on one built
# bundle, differing ONLY in whether cmd_watch registers its teardown via
# `push_exit_handler` or the old `trap '_watch_teardown' EXIT`, each with a bare
# `false` injected on the line after, run as `sudo script -qec "<bundle> watch"
# /dev/null` (a TTY is required or both arms die at the `-t 1` gate and agree):
#   push_exit_handler  -> rc=1, 476 bytes, full diagnostic naming verb `watch`,
#                         and the alt-screen escapes come FIRST — the teardown ran
#                         before the message, so it lands on a restored terminal
#   trap … EXIT        -> rc=1,  18 bytes, terminal-reset escapes only, no report
# That is the iteration-1 measurement reproduced and then reversed.
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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
declare -F _five_env_isolate >/dev/null && _five_env_isolate
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/silent-nonzero-backstop.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

BACKSTOP_RE='without reporting a reason'

BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" bash build.sh >"$TMP/build.log" 2>&1; then
  bad_t 'build a throwaway bundle to grade' "$(tail -3 "$TMP/build.log")"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# THE INDUCTION, AND WHY IT IS NOT A STORE-READING VERB. The first version of this
# harness killed `task ls` by stubbing `sqlite3` dead on PATH. It passed here and
# FAILED in CI: a fresh runner has no tasks store, so `task ls` refuses early and
# correctly ("tasks store not initialised", rc=10, through fail()) and never reaches
# sqlite3 at all. The arm was measuring a death that only happens on a provisioned
# host. So the death is now INJECTED into the built bundle instead — one unguarded
# `var=$(… | grep <no-match>)` at the top of a handler, which is the DIVE-2598
# mechanism exactly: grep exits 1 on no-match, pipefail promotes it, `set -e` ends
# the run before anything prints. `whoami` is the carrier because it needs no host
# state beyond /etc/passwd, and CURRENT_VERB is already set by the time it runs, so
# the report can be checked for the verb it names.
inject() {  # inject <src-bundle> <dst> [extra-awk-rewrite]
  awk -v extra="${3:-}" '
    /^cmd_whoami\(\) \{/ {
      print
      if (extra == "chain")   { print "  _dive2598_teardown() { printf teardown-ran >&2; }"; print "  push_exit_handler _dive2598_teardown" }
      if (extra == "clobber") { print "  _dive2598_teardown() { printf teardown-ran >&2; }"; print "  trap '\''_dive2598_teardown'\'' EXIT" }
      print "  _dive2598_induced=$(printf %s \"\" | grep -m1 zzz-no-match)"
      next
    }
    extra == "neuter" && /^_report_silent_exit\(\) \{/ { print "_report_silent_exit() { : ; }"; skip=1; next }
    skip && /^\}/ { skip=0; next }
    skip { next }
    { print }
  ' "$1" > "$2"
  chmod +x "$2"
}
INJ="$TMP/5dive-injected"; inject "$BIN" "$INJ"
MUT="$TMP/5dive-injected-nobackstop"; inject "$BIN" "$MUT" neuter
grep -q 'zzz-no-match' "$INJ" && grep -q 'zzz-no-match' "$MUT" \
  && grep -q '^_report_silent_exit() { : ; }' "$MUT" \
  || bad_t 'build the injected bundles' 'an awk rewrite did not take — arms 1, 2 and 6 would grade nothing'

RC=0; OUT=""; ERR=""
run() {  # run <bin> [args...] — captures rc, stdout (OUT), stderr (ERR) separately
  local bin="$1"; shift
  RC=0
  OUT=$("$bin" "$@" 2>"$TMP/err.txt") || RC=$?
  ERR=$(cat "$TMP/err.txt")
}

# --- 1. THE DEFECT, REPRODUCED AND REPORTED ----------------------------------
# `whoami` is READ-ONLY, so AUDIT_CMD is unset for it: this arm also proves the
# report is not hung off the audit subsystem's early return.
run "$INJ" whoami
if [[ $RC -ne 0 && "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t "an induced set -e death exits non-zero AND says so (DIVE-2598 shape, read-only verb)"
else
  bad_t 'induced silent death must be reported' "rc=$RC stdout=${#OUT}B stderr=[${ERR:0:200}]"
fi
[[ "$ERR" == *"5dive whoami"* && "$ERR" == *"5dive bug"* ]] \
  && ok_t 'the report names the verb that died and where to file it' \
  || bad_t 'report should name verb + 5dive bug' "stderr=[${ERR:0:300}]"

# --- 2. THE DIFFERENTIAL: the same run, backstop neutered --------------------
run "$MUT" whoami
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
run "$INJ" --json whoami
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

# --- 10. A VERB THAT NEEDS ITS OWN CLEANUP DOES NOT DISABLE THE BACKSTOP -----
# The iteration-1 gap. `watch` and `supervisor --watch` each wrote
# `trap '<teardown>' EXIT`; bash traps REPLACE, so that line discarded
# `trap on_exit_audit EXIT` for the rest of the process — no report, no audit
# record — and no census of exit SITES could see it, because the line contains no
# `exit`. Graded on `whoami` rather than the real verbs so it needs no TTY.
CHAIN="$TMP/5dive-injected-chain"; inject "$BIN" "$CHAIN" chain
CLOB="$TMP/5dive-injected-clobber"; inject "$BIN" "$CLOB" clobber
grep -q 'push_exit_handler _dive2598_teardown' "$CHAIN" \
  && grep -q "trap '_dive2598_teardown' EXIT" "$CLOB" \
  || bad_t 'build the exit-handler bundles' 'an awk rewrite did not take — arms 10 and 10b would grade nothing'

run "$CHAIN" whoami
if [[ $RC -ne 0 && "$ERR" == *"teardown-ran"* && "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t 'a verb registering cleanup via push_exit_handler keeps the backstop AND runs its teardown'
else
  bad_t 'push_exit_handler must chain, not replace' "rc=$RC stderr=[${ERR:0:300}]"
fi

# 10b. NON-VACUITY, and the reason the helper exists rather than a review rule:
#      the same teardown installed the obvious way still runs and still kills the
#      report. If this ever stops being silent, arm 10 is proving nothing.
run "$CLOB" whoami
if [[ $RC -ne 0 && "$ERR" == *"teardown-ran"* && ! "$ERR" =~ $BACKSTOP_RE ]]; then
  ok_t "non-vacuity: the same teardown as a raw \`trap ... EXIT\` still runs and silences the report (rc=$RC)"
else
  bad_t 'the clobbering shape must reproduce the silent exit' "rc=$RC stderr=[${ERR:0:300}] — if this reports, arm 10 grades nothing"
fi

# --- 11. THE POPULATION: exactly one EXIT trap in the shipped bundle ---------
# A property hung off a trap has a second population beside the exit sites, and
# arm 10 only covers the two verbs we already know about. This is the arm that
# catches the NEXT cmd_* to write the obvious thing: any EXIT trap in the bundle
# other than the classified set below reds here and has to be justified.
#   * `trap on_exit_audit EXIT`      — main.sh, the one process-wide trap
#   * `trap 'rm -rf "$TMPDIR"' EXIT` — TWICE (cmd_skill.sh, lib/agent_setup.sh),
#     both inside heredoc'd `bash -s` installers that are a DIFFERENT PROCESS and
#     never see ours; identical text, so `sort -u` folds them to one line.
census_traps() {  # census_traps <bundle> — distinct EXIT-trap installs, C-collated
  grep -oE "trap[[:space:]]+('[^']*'|\"[^\"]*\"|[A-Za-z_][A-Za-z0-9_]*)[[:space:]]+EXIT([[:space:]]|$)" "$1" \
    | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u
}
EXPECTED_TRAPS=$'trap \'rm -rf "$TMPDIR"\' EXIT\ntrap on_exit_audit EXIT'
FOUND_TRAPS=$(census_traps "$BIN")
if [[ "$FOUND_TRAPS" == "$EXPECTED_TRAPS" ]]; then
  ok_t 'the built bundle installs no EXIT trap beyond the classified set (nothing can clobber the backstop)'
else
  bad_t 'unclassified EXIT trap in the bundle' "found:
$FOUND_TRAPS
expected:
$EXPECTED_TRAPS
A new \`trap ... EXIT\` REPLACES on_exit_audit. Use push_exit_handler, or classify it here."
fi
# Liveness for the arm above: a clean census is worthless unless the same census
# reds on a bundle that HAS the extra trap. $CLOB is exactly that bundle.
[[ "$(census_traps "$CLOB")" != "$EXPECTED_TRAPS" ]] \
  && ok_t 'liveness pair: the same census DOES flag a bundle carrying an extra EXIT trap' \
  || bad_t 'the census must detect an added EXIT trap' "census of the clobber bundle matched the expected set — the arm above cannot fail"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
