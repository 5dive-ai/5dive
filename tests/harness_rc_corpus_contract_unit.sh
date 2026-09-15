#!/usr/bin/env bash
# DIVE-2692 corpus contract: every harness in tests/*.sh carries the
# HARNESS-RC EXIT trap (DIVE-2573 landed the mechanism; DIVE-2692 extended it
# from 13 to the full corpus).
#
# WHY THIS EXISTS AT ALL (olivia, reviewing DIVE-2692): the ticket's own body
# is that DIVE-2573 shipped covering "the 12 graded harnesses" when that 12
# was a SUBSET, not the corpus — and while DIVE-2692 was in flight, 4 more
# harnesses landed on origin/main via unrelated PRs, uncovered, which is the
# exact same shape recurring a third time. A follow-up ticket for the next
# batch just ages into the next residue the moment one more harness lands.
# This file converts that unbounded recurring chore into a one-time gate: the
# next harness that lands without the trap fails THIS check, in CI, on its
# own PR — not a future ticket someone has to notice is needed.
#
# It is a CONTRACT test rather than a run of the corpus (see
# tests/names_the_tree_contract_unit.sh, the DIVE-2211 sibling this is
# modeled on) because executing 300+ harnesses to observe one line each costs
# minutes and would grade the corpus, not the property. The cost is the seam
# above; the seam is named, not hidden. tests/lib/*.sh is out of scope by
# construction (the tests/*.sh glob does not reach it) — DIVE-2692's own body
# argues sourced libraries stay excluded, since a trap or shell option in a
# sourced file leaks into every caller.
#
# Sources src/ nothing at all (no root, no network). Run:
#   bash tests/harness_rc_corpus_contract_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${MUTTMP:-}" "${ORACLE_TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: this file is itself part of the corpus it enforces; folds in the mutation tempdir cleanup below so a second `trap ... EXIT` doesn't silently replace this one.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nok() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# COULD-NOT-RUN IS ITS OWN BRANCH, and it REFUSES rather than reporting green —
# a corpus enumeration that silently collapsed is the exact "green suite either
# way" failure mode this file exists to close off.
shopt -s nullglob
CORPUS=(tests/*.sh)
shopt -u nullglob
if (( ${#CORPUS[@]} == 0 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated 0 harnesses; this file asserts nothing\n'
  exit 1
fi
# Floor deliberately far below the real count (300+): a collapse detector, not
# a pin that has to be bumped on every new harness.
if (( ${#CORPUS[@]} < 50 )); then
  printf 'FAIL - could not run: tests/*.sh enumerated only %d harnesses; expected the full corpus\n' "${#CORPUS[@]}"
  exit 1
fi
ok "corpus enumerates ${#CORPUS[@]} harnesses"

# What matters is "a trap that fires on every EXIT and echoes the marker",
# not one exact spelling. Every author's cleanup differs (rm -rf a tempdir,
# a named cleanup() with rc threaded through as $1, folding into a
# pre-existing ABORT-marker trap, ${VAR:-} hardening for set -u, ...) — the
# invariant is trap ... HARNESS-RC=$rc ... EXIT co-occurring on one line,
# which is how bash traps are written throughout this corpus.
#
# olivia (reviewing this file at e6524ed): presence-and-reference alone is
# not enough. `trap 'cleanup; rc=$?; echo "HARNESS-RC=$rc"' EXIT` matches a
# looser regex here but is the EXACT hazard this ticket hand-fixed in 3 files
# and threaded through cleanup's own $1 in gate_answer_audit_unit.sh: if
# cleanup runs (or fails) before `rc=$?` captures the real exit code, $? has
# already been overwritten by cleanup's own status by the time it's read.
# Measured: `cleanup(){ :; }; trap 'cleanup; rc=$?; echo HARNESS-RC=$rc' EXIT;
# exit 7` reports HARNESS-RC=0, not 7. The invariant this regex enforces is
# therefore narrower than "references $rc somewhere" — it requires `rc=$?` to
# be the FIRST thing the trap body does, before any cleanup can run and
# disturb $?. Measured against the pushed tree: rejects 0 of 309 (every
# current file already opens this way).
RC_RE='trap .rc=\$\?;.*HARNESS-RC=\$rc.*EXIT'

MISSING=()
for t in "${CORPUS[@]}"; do
  grep -qE "$RC_RE" "$t" && continue
  MISSING+=("$t")
done

if (( ${#MISSING[@]} == 0 )); then
  ok "every harness in tests/*.sh carries the HARNESS-RC EXIT trap"
else
  nok "${#MISSING[@]} harness(es) do not carry the HARNESS-RC EXIT trap:"
  for m in "${MISSING[@]}"; do printf '       %s\n' "$m"; done
  printf '\n       FIX -- add, immediately after your set -[e]uo pipefail line (BEFORE any\n'
  printf '       early SKIP/precondition exit, so that path is covered too):\n\n'
  printf '           trap '"'"'rc=$?; <fold in any existing cleanup here>; echo "HARNESS-RC=$rc"'"'"' EXIT\n\n'
  printf '       bash keeps only the LAST trap registered per signal, so an existing\n'
  printf '       `trap ... EXIT` must be FOLDED into this one line, never left as a second\n'
  printf '       trap alongside it -- the second registration silently replaces the first.\n'
  printf '       See tests/names_the_tree_contract_unit.sh for the sibling corpus contract\n'
  printf '       this file is modeled on, and DIVE-2692 for the full writeup.\n'
fi

# DIVE-4440: A SECOND `trap ... EXIT` SILENTLY UNARMS THE FIRST, AND THE REGEX
# ABOVE CANNOT SEE IT.
#
# The FIX text this file prints already SAYS the rule -- "bash keeps only the LAST
# trap registered per signal ... never left as a second trap alongside it" -- and
# until now nothing checked it. A file could carry a perfect marker trap on line 29,
# register a bare cleanup trap on line 196, and pass this contract forever while
# emitting no HARNESS-RC at all. That is not a weaker check than none; it is worse,
# because the green here is read as coverage.
#
# MEASURED, not reasoned: at c7462480 tests/codex_channel_health_unit.sh matched
# RC_RE (line 29) and printed ZERO HARNESS-RC lines on a PASSING run, while its
# neighbour codex_bin_resolution_unit.sh printed HARNESS-RC=0.
#
# ---------------------------------------------------------------------------
# ITERATION 2 (DIVE-4440, after ops's grade): THE VERDICT IS BEHAVIOURAL NOW.
# ---------------------------------------------------------------------------
# Iteration 1 answered "is this trap at top level?" STATICALLY -- a prefix parse
# (`head -n N-1 | bash -n`) behind an enumeration of trap PREFIXES. ops measured
# three spellings that really silence the marker and that it reported clean:
#
#   trap inside a top-level `if ... then` BLOCK        -> 0 marker lines, reported clean
#   trap inside a FUNCTION BODY called at top level    -> 0 marker lines, reported clean
#   `if [[ ... ]]; then trap ... EXIT; fi` on ONE LINE -> 0 marker lines, reported clean
#
# TWO INDEPENDENT CAUSES, and both are properties of the STATIC approach itself:
#
#  (a) The prefix parse conflated "the prefix does not parse" with "this trap is
#      not in this shell". Only a `( ... )` subshell and never-executed fixture
#      text are genuinely exempt -- but `if`, `for`, `while`, `case` and a function
#      body ALL leave the prefix unterminated too, and a trap in any of them
#      replaces the EXIT slot for the whole shell. Five exempting shapes were
#      silently inherited from two.
#  (b) The candidate regex enumerated trap PREFIXES
#      (`(^|[;&|do][[:space:]]*|^[[:space:]]*)trap[[:space:]]`) and `then` was not
#      among them -- `[;&|do]` is a character CLASS, so `do trap` matched by
#      accident via `o` while `then trap` / `else trap` / `{ trap` matched nothing.
#      The one-line form never became a candidate, so the parser never saw it.
#
# THE GENERAL LESSON, and the reason this is not patched by adding `then` to a
# regex: an enumeration of the shapes its author thought of cannot be completed by
# thinking harder, and its NEGATIVE mutants only ever prove it is quiet on those
# same shapes. So the enumeration is now used ONLY to pick CANDIDATES, where being
# over-broad is free, and the VERDICT is rendered by RUNNING the file:
#
#   CANDIDATE  = any line naming `trap` that is not the compliant marker line
#                itself, minus whole-line comments. Deliberately a superset: a
#                false candidate costs one harness run and nothing else. (The
#                `and EXIT` half of this was iteration 3's last enumeration and is
#                gone -- see ITERATION 4 at _rc_candidate_lines.)
#   VERDICT    = run the candidate and count HARNESS-RC lines in its output.
#                Zero lines IS the defect, by definition rather than by proxy.
#
# WHY THIS IS AFFORDABLE AND THE FILE HEADER'S OBJECTION DOES NOT REACH IT. That
# header rejects executing the corpus ("300+ harnesses ... costs minutes and would
# grade the corpus, not the property"), and that objection is about the 585-file
# corpus. The candidate set is 28 files of 592 today (13 before iteration 4 dropped
# the signal filter) -- measured on the merged tree, 136s serial including this
# file's own excluded run, every one of the 27 non-self candidates emitting exactly
# ONE anchored marker, so ZERO false positives where the static classifier's own
# precision work landed. The honest cost: this harness runs ~2.5min, not ~38s.
# The oracle is exact where the parse was approximate, and it is exact for
# spellings nobody has thought of yet, which is the whole point.
#
# THE COST THE STATIC VERSION DID NOT HAVE, named because it is real and it is not
# free: running a candidate gives this contract that candidate's SIDE EFFECTS. TMPDIR
# is isolated per run and removed by the trap on line 28, but a harness that writes
# relative to the repo writes into the tree being graded -- ops found an untracked
# package.json in a grading worktree after a contract run. Disposable in CI, which
# starts from a clean checkout; NOT disposable in a developer worktree, where it
# shows up as unexplained `git status` noise. The trade was taken knowingly: the
# static verdict cost three spellings of blindness, and this costs one stray file.
#
# THE DEAD END, named so it is not re-walked: "append `)` to the prefix and
# re-parse" looks like the cheap way to keep the static route and tell a subshell
# from an open compound. ops measured it misclassifying BOTH real files --
# broker_surface_unit.sh:384 (a true subshell) reads as an open compound, and
# pre_push_rail_unit.sh:304 (a true heredoc) reads as a subshell. Recovering the
# exemption from `bash -n`'s exit code is not possible; recovering it from RUNNING
# the file is trivial, because a correct subshell/heredoc trap leaves the marker in
# place and that is exactly what is measured.
#
# THE RESIDUALS, stated rather than hidden -- there are two, and neither is the
# class that has now arrived three times:
#
#  1. The oracle grades the path the harness actually takes when run here. A trap
#     registered only on a branch this run does not enter stays invisible -- but so
#     does its silencing, on this run. A trap in a function that is never called is
#     likewise NOT reported, and that is correct: it silences nothing.
#  2. The CANDIDATE set is still textual, so a harness that registers its second
#     trap entirely from a file it sources -- with no `trap`/`EXIT` text of its own
#     -- is never picked up. That is the same seam this file's header already names
#     for tests/lib/*.sh ("a trap ... in a sourced file leaks into every caller"),
#     and it is not closable by a wider grep; it needs the sourced file to be in
#     scope, which DIVE-2692's body argues against. Measured: the one sourced-trap
#     spelling that DOES leave text behind (`printf 'trap ... EXIT' > f; . "$f"`) is
#     caught, because the printf line is a candidate.
#
# CLOSURE CLAIM, CORRECTED IN ITERATION 4 -- the old wording ("the whole class of
# a shape the classifier's author did not enumerate, for any trap written in the
# harness itself") was FALSE when written, and ops proved it with two spellings:
# the classifier still enumerated the SIGNAL NAME, so `trap 'cleanup' 0` and
# `trap 'cleanup' exit` were not candidates. A file that prints a completeness
# claim it does not enforce is the exact defect this row exists to kill, so the
# claim is now scoped to what the code actually does:
#
#   CLOSED: where the trap APPEARS (any prefix, any compound statement, any
#           function that runs) -- the oracle runs the file and counts markers, so
#           it is exact for spellings nobody has written yet; and how the SIGNAL is
#           SPELLED -- the candidate greps no longer read the signal position at
#           all, so `EXIT`, `exit`, `Exit`, `0`, a multi-signal list and `trap - 0`
#           are all candidates and all graded by the same oracle.
#   NOT CLOSED, and these are the residuals below: a trap on a branch this run does
#           not take; a trap registered wholly from a sourced file with no `trap`
#           text of its own; and the candidate grep's one remaining literal -- the
#           word `trap` itself. A harness that assembles the keyword out of
#           fragments (`t=tr; ${t}ap ...`) is not a candidate. That is a deliberate
#           floor, not an oversight: the word `trap` is what the FIX text tells
#           authors to write, and no accidental cleanup is spelled around it.
#
# Note what pins the FIRST trap: RC_RE still requires the literal `EXIT`, so a
# compliant marker trap must be spelled `EXIT` -- enforced LOUDLY by the MISSING
# arm above, which reds any other spelling by name. That is why the candidate and
# non-compliant greps below can afford to know nothing about signals: the marker
# trap's own spelling is already pinned, and everything else is a candidate.
#
# THREE OUTCOMES, unchanged in spirit: a candidate that cannot be RUN (timeout,
# unexecutable) is neither clean nor silenced. It is reported UNKNOWN and fails --
# a check that cannot run must not answer.
#
# SELF IS EXEMPT FROM THE RUN, by absolute path: this file is its own candidate
# (the mutants below write `trap ... EXIT` fixtures), and running it from inside
# itself does not terminate. Its own marker is graded where every harness's is --
# by scripts/run-harnesses.sh, in the log of this very run.
ORACLE_TIMEOUT="${HARNESS_RC_ORACLE_TIMEOUT:-180}"
SELF_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ORACLE_TMP="$(mktemp -d /tmp/harness-rc-oracle.XXXXXX)"

# ITERATION 4 (DIVE-4440, ops's third grade): THE LAST ENUMERATION WAS THE SIGNAL
# NAME, and it is gone. Iteration 3 still required `\bEXIT\b` on the line. In bash
# `EXIT`, lowercase `exit`, any mixed case, and the number `0` are the SAME signal
# (measured: all four register; only `SIGEXIT` is rejected), and `trap 'cleanup' 0`
# is the classic POSIX idiom. ops measured both spellings really losing the marker
# and this contract staying silent on them, because the line never became a
# candidate and the exact behavioural oracle was never consulted -- iteration 1's
# failure mode moved one field to the right.
#
# So the signal filter is DROPPED rather than widened to `EXIT|exit|0`. Widening
# adds zero candidates today and keeps a list that the next spelling walks past;
# dropping it means the candidate set is "any line naming `trap` that is not the
# compliant marker trap", with no knowledge of signals at all. MEASURED on the tree
# merged into origin/main e0cb028d: 13 -> 28 candidate files of 592, and all 28 emit
# EXACTLY ONE anchored marker, so the widening costs ZERO false positives. It costs
# TIME: 27 non-self runs, 136s serial measured (was 34s for 13), so this harness
# goes from ~38s to ~2.5min. That is the trade iteration 2 already argued for --
# over-inclusion costs one harness run and nothing else -- and it is named here
# rather than discovered in a CI shard.
_rc_candidate_lines() {   # <file> -> "<lineno>:<line>" for every `trap` line that is not a COMPLIANT marker trap
  grep -nE '\btrap\b' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE "$RC_RE"
}

# ITERATION 3 (DIVE-4440, ops's second grade): the line above used to drop every
# line containing the substring HARNESS-RC, which exempted the one shape that is
# WORSE than silence -- a second top-level trap that DOES print the marker and
# prints the WRONG VALUE. LIVE AT HEAD when ops measured it:
# tests/headless_question_guard_unit.sh:245 registered
# `trap 'rm -f "$mut"; rc=$?; echo "HARNESS-RC=$rc"' EXIT`, so `rm -f` ran before
# `rc=$?` and the harness forced to exit 7 printed HARNESS-RC=0 (control, with the
# head trap alone: HARNESS-RC=7). The behavioural oracle cannot see that -- the file
# emits a marker, so it "survives" -- which is why the corruption gets its OWN arm
# below rather than a wider oracle. Filtering on RC_RE instead of the substring is
# what lets that arm have a candidate set at all.
#
# ITERATION 4: this arm loses the signal filter too, for the same reason -- a trap
# that captures rc AFTER its cleanup misreports just as badly spelled `0` or
# `exit`. It is STATIC (it reports on the grep alone), so over-inclusion is NOT
# free here and the naive drop introduces a real false positive: measured, the only
# corpus line that gains is codex_channel_health_unit.sh:204, a plain assignment
# whose TRAILING COMMENT happens to read "... the HARNESS-RC trap at the head".
# The fix is a fact about the builtin's syntax rather than another spelling list:
# a trap whose BODY prints the marker always has the word `trap` BEFORE it on the
# line, because the body follows the keyword. Requiring that order drops the
# comment and keeps every real shape. Measured across 592 harnesses: ZERO lines
# outside this file match, so this arm reds the file that lies and nothing else.
_rc_noncompliant_marker_lines() {   # <file> -> "<lineno>:<line>" for every `trap` line whose body MENTIONS the marker but is not a compliant marker trap
  grep -nE '\btrap\b.*HARNESS-RC' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE "$RC_RE"
}

# ONE detector, called by the corpus loop AND by the mutation arms below. A second
# copy for the mutants would grade the copy -- the same argument tests/lib/
# harness-verdict-detect.sh carries for its own extraction.
#
# `_HARNESS_RC_ORACLE` is a recursion fuse, not a feature flag: nothing in tests/
# executes this contract today (checked -- all five references are comments), but a
# harness that did would be run by this oracle and would re-enter it forever. A
# nested run therefore REFUSES instead of returning a value it cannot stand behind.
_rc_marker_survives() {   # <file> -> 0 marker present, 1 SILENCED, 2 could-not-run
  local f="$1" out rc
  out=$(_HARNESS_RC_ORACLE=1 TMPDIR="$ORACLE_TMP" timeout "$ORACLE_TIMEOUT" bash "$f" 2>&1)
  rc=$?
  (( rc == 124 || rc == 125 || rc == 126 || rc == 127 )) && return 2
  # ANCHORED, and counted -- not `grep -q HARNESS-RC`. An unanchored substring test
  # over merged stdout+stderr hands a clean verdict to any harness that prints the
  # marker's NAME anywhere in its own output, and the candidate set is exactly the
  # population where that is likeliest: files carrying a second `trap ... EXIT` are
  # disproportionately files ABOUT exit traps and markers (audit_exit_trap_row,
  # silent_nonzero_exit_backstop and truncation_marker_guard are 3 of today's 28).
  # Measured by ops: a probe registering a second top-level trap AND echoing one
  # sentence containing the word HARNESS-RC ran with ZERO emitted markers and this
  # contract called it clean. Measured here: all 27 non-self candidates emit exactly
  # ONE anchored line, so the anchor costs no false positive.
  (( $(grep -cE '^HARNESS-RC=[0-9]+$' <<<"$out") >= 1 )) && return 0
  return 1
}

_rc_verdict() {   # <file> -> 0 ran/marker survived, 1 SILENCED, 2 could-not-run, 3 self (exempt), 4 not a candidate
  local f="$1" abs
  grep -qE "$RC_RE" "$f" || return 4   # no marker to silence; the MISSING arm above owns this file
  [[ -n "$(_rc_candidate_lines "$f")" ]] || return 4
  abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  [[ "$abs" == "$SELF_ABS" ]] && return 3
  _rc_marker_survives "$f"
}

if [[ -n "${_HARNESS_RC_ORACLE:-}" ]]; then
  nok "could not run: this contract was invoked from inside a harness the oracle runs; refusing to recurse rather than answering"
else
  SILENCED=(); UNKNOWN_TL=(); CANDIDATES=0
  for t in "${CORPUS[@]}"; do
    _rc_verdict "$t"
    case $? in
      0) CANDIDATES=$((CANDIDATES+1)) ;;
      1) CANDIDATES=$((CANDIDATES+1)); SILENCED+=("$t") ;;
      2) CANDIDATES=$((CANDIDATES+1)); UNKNOWN_TL+=("$t") ;;
      3) CANDIDATES=$((CANDIDATES+1)) ;;
      4) ;;
    esac
  done

  if (( ${#SILENCED[@]} == 0 )); then
    ok "no harness loses its HARNESS-RC line at runtime (${CANDIDATES} of ${#CORPUS[@]} carry a non-compliant \`trap\` line, any signal spelling; each was RUN and printed its marker)"
  else
    nok "${#SILENCED[@]} harness(es) emit NO HARNESS-RC line when run -- a later EXIT trap replaced the marker trap (EXIT, exit, Exit and 0 are all the same signal):"
    for m in "${SILENCED[@]}"; do
      printf '       %s\n' "$m"
      while IFS= read -r cl; do [[ -n "$cl" ]] && printf '         suspect %s\n' "$cl"; done < <(_rc_candidate_lines "$m")
    done
    printf '\n       FIX -- FOLD the cleanup into the marker trap instead of registering a\n'
    printf '       second one. bash keeps only the LAST trap per signal, so the file above\n'
    printf '       currently emits NO HARNESS-RC line at all, pass or fail:\n\n'
    printf '           trap '"'"'rc=$?; <your cleanup here>; echo "HARNESS-RC=$rc"'"'"' EXIT\n\n'
    printf '       rc=$? must stay FIRST so cleanup cannot overwrite the exit code.\n'
    printf '       A trap inside a ( ... ) subshell, or inside fixture text this shell never\n'
    printf '       executes, is fine and is NOT what is reported here -- the verdict above is\n'
    printf '       the marker count from actually running the file, not a guess about scope.\n'
  fi

  if (( ${#UNKNOWN_TL[@]} > 0 )); then
    nok "${#UNKNOWN_TL[@]} candidate harness(es) could not be RUN (timeout ${ORACLE_TIMEOUT}s / not executable); asserting nothing about them:"
    for m in "${UNKNOWN_TL[@]}"; do printf '       %s\n' "$m"; done
  fi
fi

# ---------------------------------------------------------------------------
# ITERATION 3 ARM: A MARKER WITH THE WRONG VALUE IS WORSE THAN NO MARKER.
# ---------------------------------------------------------------------------
# Everything above grades the marker's EXISTENCE. Nothing graded its VALUE, and a
# job that fails while printing `HARNESS-RC=0` is the same silent failure with a
# receipt attached -- strictly worse than silence, because it survives a human
# reading the log and it survives the run-harnesses.sh summary.
#
# The shape: a second top-level EXIT trap that DOES carry the marker but runs its
# cleanup BEFORE `rc=$?`, so the captured code is the cleanup's, not the harness's.
# RC_RE (line 76) was written for exactly this hazard -- it requires `rc=$?;` to be
# the FIRST statement in the trap body -- and the MISSING arm satisfies it with ANY
# ONE matching line in the file, so a file can open with a compliant trap and
# replace it 226 lines later with a non-compliant one and be green twice over.
#
# MEASURED, at head, not hypothesised: tests/headless_question_guard_unit.sh:245
# carried `trap 'rm -f "$mut"; rc=$?; echo "HARNESS-RC=$rc"' EXIT`. Forced to exit 7
# it printed HARNESS-RC=0; with only the compliant head trap it printed HARNESS-RC=7.
# It is fixed in the same commit as this arm.
#
# SCOPE, measured across the corpus: exactly one file outside this one carried such
# a line. So this arm reds the file that lies and nothing else.
#
# WHY THIS IS STATIC WHILE THE ARM ABOVE IS BEHAVIOURAL, and it is not a relapse:
# the behavioural oracle answers "was a marker emitted", and a corrupting trap emits
# one -- it is clean by that oracle's definition and always will be. Grading the
# VALUE behaviourally would mean forcing each candidate to a known non-zero exit,
# which means editing it. The property here is a property of the TRAP BODY's
# statement order, which is what RC_RE already reads; the iteration-1 failure was
# enumerating where a trap may APPEAR, and that is not what this reads.
#
# SELF IS EXEMPT, and this is a real hole, stated rather than hidden: this file
# prints the FIX text (`trap 'rc=$?; <your cleanup here>; ...' EXIT`) through printf
# and writes deliberately non-compliant fixtures for the mutants below, so its own
# text carries such lines by design. Distinguishing fixture text from live code is
# the static-scope problem the oracle above exists to avoid re-walking. What covers
# this file instead: its own trap is line 28, graded by the MISSING arm, by
# run-harnesses.sh in the log of this very run, and by the corrupting-form mutants
# below, which are the same measurement applied to text this file controls.
NONCOMPLIANT=()
for t in "${CORPUS[@]}"; do
  abs="$(cd "$(dirname "$t")" && pwd)/$(basename "$t")"
  [[ "$abs" == "$SELF_ABS" ]] && continue
  [[ -n "$(_rc_noncompliant_marker_lines "$t")" ]] && NONCOMPLIANT+=("$t")
done

if (( ${#NONCOMPLIANT[@]} == 0 )); then
  ok "every EXIT trap that prints HARNESS-RC captures rc FIRST -- no harness reports a code that is its cleanup's, not its own"
else
  nok "${#NONCOMPLIANT[@]} harness(es) register an EXIT trap that prints HARNESS-RC with the WRONG value:"
  for m in "${NONCOMPLIANT[@]}"; do
    printf '       %s\n' "$m"
    while IFS= read -r cl; do [[ -n "$cl" ]] && printf '         suspect %s\n' "$cl"; done < <(_rc_noncompliant_marker_lines "$m")
  done
  printf '\n       FIX -- rc=$? must be the FIRST statement in the trap body, before any\n'
  printf '       cleanup, or the marker reports the cleanup command'"'"'s exit code:\n\n'
  printf '           trap '"'"'rc=$?; <your cleanup here>; echo "HARNESS-RC=$rc"'"'"' EXIT\n\n'
  printf '       A harness that fails while printing HARNESS-RC=0 is worse than one that\n'
  printf '       prints nothing: the receipt makes the failure look graded.\n'
fi
# MUTATION, not just reading the regex: a check that cannot fail proves
# nothing (this file's own sibling on DIVE-2211 exists partly to name that
# risk). Stage a throwaway harness missing the trap and confirm THIS FILE's
# own detector -- run against a corpus of exactly one -- calls it missing;
# then stage one carrying it and confirm the same detector calls it present.
# Never touches the real tests/ tree.
MUTTMP="$(mktemp -d /tmp/harness-rc-contract-mut.XXXXXX)"

printf '#!/usr/bin/env bash\nset -uo pipefail\necho hi\n' > "$MUTTMP/no_trap_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/no_trap_unit.sh"; then
  nok "mutation: a harness with NO trap at all is (wrongly) reported present"
else
  ok "mutation: a harness with no trap at all is correctly reported MISSING"
fi

printf '#!/usr/bin/env bash\nset -uo pipefail\ntrap '"'"'rc=$?; echo "HARNESS-RC=$rc"'"'"' EXIT\necho hi\n' > "$MUTTMP/has_trap_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/has_trap_unit.sh"; then
  ok "mutation: a harness carrying the trap is correctly reported PRESENT (the check can pass, not just fail)"
else
  nok "mutation: a harness carrying the trap is (wrongly) reported missing"
fi

# A trap missing the ECHO (cleanup only, no marker) must still be caught --
# guards against a detector that fires on the bare word "trap ... EXIT".
printf '#!/usr/bin/env bash\nset -uo pipefail\ntrap '"'"'rm -rf /tmp/whatever'"'"' EXIT\necho hi\n' > "$MUTTMP/cleanup_only_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/cleanup_only_unit.sh"; then
  nok "mutation: a trap with cleanup but no HARNESS-RC echo is (wrongly) reported present"
else
  ok "mutation: a trap with cleanup but no HARNESS-RC echo is correctly reported MISSING"
fi

# THE HAZARDOUS ORDERING (olivia's finding): cleanup BEFORE rc=$? captures the
# real exit code, so by the time it's read $? has already been overwritten by
# cleanup's own status. This is a static grep check, but its value is what it
# discriminates at RUNTIME, so confirm both halves: the static detector must
# reject the file, AND actually running the hazardous form on a real non-zero
# exit must misreport 0 -- proving there is a live bug here for the detector
# to be worth rejecting, not just a shape the regex happens to dislike.
printf '#!/usr/bin/env bash\nset -uo pipefail\ncleanup() { :; }\ntrap '"'"'cleanup; rc=$?; echo "HARNESS-RC=$rc"'"'"' EXIT\nexit 7\n' > "$MUTTMP/hazardous_order_unit.sh"
if grep -qE "$RC_RE" "$MUTTMP/hazardous_order_unit.sh"; then
  nok "mutation: the hazardous cleanup-before-rc ordering is (wrongly) reported present"
else
  ok "mutation: the hazardous cleanup-before-rc ordering is correctly reported MISSING"
fi
HAZ_OUT="$(bash "$MUTTMP/hazardous_order_unit.sh" 2>&1)"
if [[ "$HAZ_OUT" == *"HARNESS-RC=0"* ]]; then
  ok "mutation: the hazardous form is a LIVE bug, not just a disliked shape -- exit 7 misreports as HARNESS-RC=0 at runtime"
else
  nok "mutation: expected the hazardous form to misreport rc at runtime (got: $HAZ_OUT) -- the arm above is not grading a real hazard"
fi

# DIVE-4440 ITERATION 2 MUTANTS FOR THE SILENCING ARM.
#
# WHY THERE ARE SO MANY, and it is the finding this row ends on: iteration 1 shipped
# one positive and two negative mutants and was GREEN on all three while three real
# silencing spellings walked past it. **A detector's NEGATIVE mutants prove it is
# quiet on the shapes its author thought of. They can never prove it is LOUD on the
# ones they did not.** Coverage is graded by writing the spellings the author did not
# enumerate, measuring ground truth by RUNNING them, and reading the guard's verdict
# on the same tree -- so every shape a cleanup trap can plausibly be written in gets
# an arm, including the three ops measured past iteration 1.
#
# EACH POSITIVE MUTANT CARRIES THREE ARMS:
#   CANDIDATE -- the superset grep sees the line. This is cause (b) of the iteration-1
#                miss: the one-line `then trap` form was never a candidate, so the
#                classifier never got a chance to be wrong about it.
#   VERDICT   -- the contract's own detector reports it silenced.
#   ANCHOR    -- the mutant, RUN, really emits zero HARNESS-RC lines. The verdict is
#                behavioural now, so the anchor measures the same thing the detector
#                does -- kept deliberately, because it is the GROUND TRUTH and it
#                stays valid if the verdict is ever re-implemented some other way. A
#                mutant nobody proved is a live silencing grades nothing.
# Negative mutants carry the VERDICT and the ANCHOR inverted: not reported, and the
# marker really does still print.

_mut_write() { printf '%s\n' "$2" > "$MUTTMP/$1"; printf '%s' "$MUTTMP/$1"; }

_mut_positive() {   # <label> <file>
  local label="$1" f="$2" rc n
  if [[ -n "$(_rc_candidate_lines "$f")" ]]; then
    ok "mutation CANDIDATE: $label is seen by the candidate grep"
  else
    nok "mutation CANDIDATE: $label is INVISIBLE to the candidate grep -- it would never be run and the contract would call it clean"
  fi
  _rc_verdict "$f"; rc=$?
  if (( rc == 1 )); then
    ok "mutation: $label is correctly reported SILENCED"
  else
    nok "mutation: $label is (wrongly) reported clean (verdict $rc) -- the arm has no teeth against this spelling"
  fi
  # ANCHORED like the oracle: the spoof mutant below prints the marker's NAME and no
  # marker, and an unanchored count would call it a non-silencing and quietly void
  # the arm it exists to prove.
  n=$(bash "$f" 2>&1 | grep -cE '^HARNESS-RC=[0-9]+$')
  if (( n == 0 )); then
    ok "mutation ANCHOR: $label really does emit 0 HARNESS-RC lines when run"
  else
    nok "mutation ANCHOR: $label emitted $n HARNESS-RC line(s) -- it is not a live silencing, so the arm above grades nothing"
  fi
}

_mut_negative() {   # <label> <file>
  local label="$1" f="$2" rc n
  _rc_verdict "$f"; rc=$?
  if (( rc == 0 )); then
    ok "mutation NEGATIVE: $label is correctly NOT reported"
  else
    nok "mutation NEGATIVE: $label is (wrongly) reported silenced (verdict $rc) -- a false positive teaches authors to route around this guard"
  fi
  n=$(bash "$f" 2>&1 | grep -cE '^HARNESS-RC=[0-9]+$')
  if (( n >= 1 )); then
    ok "mutation NEGATIVE ANCHOR: $label really does still print HARNESS-RC"
  else
    nok "mutation NEGATIVE ANCHOR: $label lost HARNESS-RC -- the negative control is wrong, not the detector"
  fi
}

MUT_HEAD='#!/usr/bin/env bash
set -uo pipefail
trap '"'"'rc=$?; echo "HARNESS-RC=$rc"'"'"' EXIT'

# --- POSITIVE: every spelling that really replaces the EXIT slot -------------

# (1) The inline form this class has arrived as three times (DIVE-3592 x2, DIVE-4440).
_mut_positive "an inline second top-level EXIT trap" \
  "$(_mut_write silenced_inline_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT
echo body")"

# (2) ops's spelling #1: a multi-line top-level if/then BLOCK. Iteration 1 read the
# unterminated `if` prefix as "not this shell" and exempted it.
_mut_positive "a trap inside a top-level if/then BLOCK" \
  "$(_mut_write silenced_ifblock_unit.sh "$MUT_HEAD
d=\$(mktemp -d)
if [[ -n \"\$d\" ]]; then
  trap 'rm -rf \"\$d\"' EXIT
fi
echo body")"

# (3) ops's spelling #3: the ONE-LINE then-form. `then` was not in the prefix
# enumeration, so this never even became a candidate.
_mut_positive "a one-line 'if ...; then trap ... EXIT; fi'" \
  "$(_mut_write silenced_ifoneline_unit.sh "$MUT_HEAD
d=\$(mktemp -d)
if [[ -n \"\$d\" ]]; then trap 'rm -rf \"\$d\"' EXIT; fi
echo body")"

# (4) ops's spelling #2: a FUNCTION BODY called at top level. The trap is registered
# in this shell the moment the function runs.
_mut_positive "a trap in a function body that IS called" \
  "$(_mut_write silenced_func_unit.sh "$MUT_HEAD
d=\$(mktemp -d)
arm() { trap 'rm -rf \"\$d\"' EXIT; }
arm
echo body")"

# (5)-(8) The rest of the compound statements that leave a prefix unterminated and
# that iteration 1 therefore exempted by accident: for, while, case, brace group.
_mut_positive "a trap inside a top-level for loop" \
  "$(_mut_write silenced_for_unit.sh "$MUT_HEAD
for d in one; do
  trap 'echo cleanup' EXIT
done
echo body")"

_mut_positive "a trap inside a top-level while loop" \
  "$(_mut_write silenced_while_unit.sh "$MUT_HEAD
n=0
while (( n < 1 )); do
  trap 'echo cleanup' EXIT
  n=1
done
echo body")"

_mut_positive "a trap inside a top-level case branch" \
  "$(_mut_write silenced_case_unit.sh "$MUT_HEAD
case x in
  x) trap 'echo cleanup' EXIT ;;
esac
echo body")"

_mut_positive "a trap inside a top-level { ...; } brace group" \
  "$(_mut_write silenced_brace_unit.sh "$MUT_HEAD
{ trap 'echo cleanup' EXIT; }
echo body")"

# (9) An else branch -- `else trap` matched nothing in the old prefix enumeration.
_mut_positive "a trap in an else branch" \
  "$(_mut_write silenced_else_unit.sh "$MUT_HEAD
if false; then :; else trap 'echo cleanup' EXIT; fi
echo body")"

# (10) Double-quoted trap body. The iteration-1 enumeration grep that FOUND the
# original instances was single-quote-anchored; the detector must not care.
_mut_positive "a double-quoted trap body" \
  "$(_mut_write silenced_dquote_unit.sh "$MUT_HEAD
d=\$(mktemp -d)
trap \"rm -rf \$d\" EXIT
echo body")"

# (11) `trap - EXIT` at top level registers nothing and still silences the marker --
# a DISARM, which no shape-based reading of "a second trap" would call a hazard.
_mut_positive "a bare 'trap - EXIT' reset at top level" \
  "$(_mut_write silenced_reset_unit.sh "$MUT_HEAD
trap - EXIT
echo body")"

# (12)-(15) ITERATION 4: THE SIGNAL SPELLINGS. In bash EXIT, lowercase exit, any
# mixed case, and the number 0 are the SAME signal -- `trap 'cleanup' 0` is the
# classic POSIX idiom, not an exotic shape -- and iteration 3's candidate greps
# required the literal `\bEXIT\b`, so these registered a silencing trap that this
# contract could not see. Each carries the same three arms as every positive above,
# and the CANDIDATE arm is the one that matters here: iteration 3 failed at that
# stage, not at the verdict.
_mut_positive "a second top-level trap on signal 0 (the POSIX spelling)" \
  "$(_mut_write silenced_sig0_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' 0
echo body")"

_mut_positive "a second top-level trap on lowercase 'exit'" \
  "$(_mut_write silenced_siglower_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' exit
echo body")"

_mut_positive "a second top-level trap on mixed-case 'Exit'" \
  "$(_mut_write silenced_sigmixed_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' Exit
echo body")"

_mut_positive "a second top-level trap on a MULTI-signal list ending in 0" \
  "$(_mut_write silenced_siglist_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' INT TERM 0
echo body")"

# (16) The disarm, spelled numerically -- mutant (11) covered `trap - EXIT`, and the
# numeric spelling is the one iteration 3's grep could not see.
_mut_positive "a bare 'trap - 0' reset at top level" \
  "$(_mut_write silenced_reset0_unit.sh "$MUT_HEAD
trap - 0
echo body")"

# --- NEGATIVE: the shapes that are CORRECT and must never be redded -----------
# A detector that reds a correct file teaches authors to route around it, which is
# how this contract dies a fourth time. All five shapes below exist in the real
# corpus (broker_surface, audit_exit_trap_row, gh_actor_routing, pre_push_rail,
# silent_nonzero_exit_backstop, auth_status_per_agent_scope).

_mut_negative "an EXIT trap inside a ( ... ) subshell" \
  "$(_mut_write clean_subshell_unit.sh "$MUT_HEAD
(
  trap 'echo inner' EXIT
  echo body
)")"

_mut_negative "an EXIT trap inside a quoted heredoc fixture" \
  "$(_mut_write clean_heredoc_unit.sh "$MUT_HEAD
cat > /dev/null <<'FIXTURE'
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT
FIXTURE
echo body")"

_mut_negative "an EXIT trap inside awk-built fixture text" \
  "$(_mut_write clean_awk_unit.sh "$MUT_HEAD
awk 'BEGIN { print \"trap '\"'\"'rm -rf x'\"'\"' EXIT\" }' > /dev/null
echo body")"

# A function that is DEFINED and never CALLED registers nothing. This is the arm
# that proves the oracle is not just "does the word trap appear" -- and it is the
# one shape where a static top-level reading would have been WRONG in the loud
# direction.
_mut_negative "a trap in a function body that is never called" \
  "$(_mut_write clean_uncalled_func_unit.sh "$MUT_HEAD
arm() { trap 'echo cleanup' EXIT; }
echo body")"

# ITERATION 4: the signal-agnostic candidate grep must not red a CORRECT trap just
# because it is spelled `0`. A subshell trap on signal 0 is a candidate now (it was
# invisible before) and the oracle must still leave it clean.
_mut_negative "a trap on signal 0 inside a ( ... ) subshell" \
  "$(_mut_write clean_subshell_sig0_unit.sh "$MUT_HEAD
(
  trap 'echo inner' 0
  echo body
)")"

# ITERATION 4: a trap on a DIFFERENT signal entirely is a candidate now (no signal
# filter) and silences nothing. It must be run and found clean, not reported.
_mut_negative "a top-level trap on ERR, which is not the EXIT slot at all" \
  "$(_mut_write clean_errtrap_unit.sh "$MUT_HEAD
trap 'echo errhandler' ERR
echo body")"

_mut_negative "a '( trap - EXIT; ... )' reset inside a subshell" \
  "$(_mut_write clean_subshell_reset_unit.sh "$MUT_HEAD
( trap - EXIT; echo inner )
echo body")"

# --- ITERATION 3: THE SPOOF -------------------------------------------------
# The arm that would have caught iteration 2's oracle. A silenced harness that
# merely MENTIONS the marker in its own output bought a clean verdict from
# `grep -q HARNESS-RC`. Ground truth is the ANCHORED count, which is zero.
_mut_positive "a silenced harness that PRINTS the word HARNESS-RC in its own output" \
  "$(_mut_write silenced_spoof_unit.sh "$MUT_HEAD
d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT
echo 'note: this harness explains the HARNESS-RC contract to the reader'
echo body")"

# The control the anchor actually needs, and the shape matters: it must be a
# CANDIDATE that reaches the oracle. A file with no second `trap ... EXIT` never
# gets that far -- _rc_verdict returns 4 (not a candidate) and the oracle is never
# consulted -- so a spoof-text fixture WITHOUT a trap proves nothing about
# anchoring. This one carries a CORRECT (subshell) second trap, so it is graded by
# the oracle, AND it prints the marker's name in its own output. Anchoring must
# leave it clean: the risk anchoring introduces is redding a file whose real marker
# the anchor fails to match, not redding one that merely says the word.
_mut_negative "a COMPLIANT candidate that also prints the word HARNESS-RC in its output" \
  "$(_mut_write clean_spoof_unit.sh "$MUT_HEAD
( d=\$(mktemp -d); trap 'rm -rf \"\$d\"' EXIT; echo inner )
echo 'note: this harness explains the HARNESS-RC contract to the reader'
echo body")"

# --- ITERATION 3: THE CORRUPTING FORM ---------------------------------------
# A marker with the WRONG VALUE. Three arms, mirroring _mut_positive, because the
# same two ways of grading nothing apply: the line must be SEEN by the
# non-compliant grep, it must be REPORTED by the arm, and the mutant RUN must
# really misreport its exit code -- otherwise the arm grades a disliked shape
# rather than a live defect.
_mut_corrupting() {   # <label> <file> <expected-wrong-rc> <expected-true-rc>
  local label="$1" f="$2" want="$3" truth="$4" got
  if [[ -n "$(_rc_noncompliant_marker_lines "$f")" ]]; then
    ok "mutation CANDIDATE: $label is seen by the non-compliant-marker grep"
  else
    nok "mutation CANDIDATE: $label is INVISIBLE to the non-compliant-marker grep -- the arm would never see it"
  fi
  got=$(bash "$f" 2>&1 | grep -oE '^HARNESS-RC=[0-9]+$' | tail -1)
  if [[ "$got" == "HARNESS-RC=$want" ]]; then
    ok "mutation ANCHOR: $label really misreports -- exits $truth and prints $got"
  else
    nok "mutation ANCHOR: $label printed '$got', expected HARNESS-RC=$want -- it is not a live corruption, so the arm above grades nothing"
  fi
}

_mut_corrupting_negative() {   # <label> <file> <expected-rc>
  local label="$1" f="$2" want="$3" got
  if [[ -z "$(_rc_noncompliant_marker_lines "$f")" ]]; then
    ok "mutation NEGATIVE: $label is correctly NOT reported as a corrupting trap"
  else
    nok "mutation NEGATIVE: $label is (wrongly) reported -- a false positive on a correct fold teaches authors to route around this guard"
  fi
  got=$(bash "$f" 2>&1 | grep -oE '^HARNESS-RC=[0-9]+$' | tail -1)
  if [[ "$got" == "HARNESS-RC=$want" ]]; then
    ok "mutation NEGATIVE ANCHOR: $label really does report its own code ($got)"
  else
    nok "mutation NEGATIVE ANCHOR: $label printed '$got', expected HARNESS-RC=$want -- the negative control is wrong, not the detector"
  fi
}

# (1) The live shape, as it stood at tests/headless_question_guard_unit.sh:245.
_mut_corrupting "cleanup BEFORE rc=\$? in a second top-level trap" \
  "$(_mut_write corrupt_order_unit.sh "$MUT_HEAD
f=\$(mktemp)
trap 'rm -f \"\$f\"; rc=\$?; echo \"HARNESS-RC=\$rc\"' EXIT
exit 7")" 0 7

# (2) The same hazard written with a function call instead of an inline command --
# the value is whatever the cleanup returned, which need not be 0.
_mut_corrupting "a cleanup FUNCTION called before rc=\$?" \
  "$(_mut_write corrupt_func_unit.sh "$MUT_HEAD
cleanup() { return 3; }
trap 'cleanup; rc=\$?; echo \"HARNESS-RC=\$rc\"' EXIT
exit 7")" 3 7

# (3) ITERATION 4: the same corruption spelled on signal 0. The value arm dropped
# its `\bEXIT\b` filter too, so this must be SEEN by the non-compliant grep; it was
# invisible to iteration 3.
_mut_corrupting "cleanup before rc=\$? in a trap spelled on signal 0" \
  "$(_mut_write corrupt_sig0_unit.sh "$MUT_HEAD
f=\$(mktemp)
trap 'rm -f \"\$f\"; rc=\$?; echo \"HARNESS-RC=\$rc\"' 0
exit 7")" 0 7

# NEGATIVE, ITERATION 4: the false positive the naive signal-filter drop introduced
# in the VALUE arm -- a plain line whose TRAILING COMMENT names both `trap` and the
# marker. Live shape: codex_channel_health_unit.sh:204. It must never be reported.
# (This mutant has no corrupting trap at all, so it is graded only by the
# non-compliant grep -- which is the stage it exists to defend.)
_mut_corrupting_negative "an ordinary line whose trailing comment names the HARNESS-RC trap" \
  "$(_mut_write corrupt_comment_tail_unit.sh "$MUT_HEAD
d=\$(mktemp -d)   # cleanup folded into the HARNESS-RC trap at the head
exit 7")" 7

# NEGATIVE: the CORRECT fold. rc is captured first, cleanup runs after, and the
# marker carries the harness's own code. This must never be reported.
_mut_corrupting_negative "a correctly folded second trap (rc=\$? first, cleanup after)" \
  "$(_mut_write corrupt_clean_unit.sh "$MUT_HEAD
f=\$(mktemp)
trap 'rc=\$?; rm -f \"\$f\"; echo \"HARNESS-RC=\$rc\"' EXIT
exit 7")" 7

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
