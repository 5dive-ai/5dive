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
#   CANDIDATE  = any line naming both `trap` and `EXIT`, minus the marker line
#                itself, minus whole-line comments. Deliberately a superset: a
#                false candidate costs one harness run and nothing else.
#   VERDICT    = run the candidate and count HARNESS-RC lines in its output.
#                Zero lines IS the defect, by definition rather than by proxy.
#
# WHY THIS IS AFFORDABLE AND THE FILE HEADER'S OBJECTION DOES NOT REACH IT. That
# header rejects executing the corpus ("300+ harnesses ... costs minutes and would
# grade the corpus, not the property"), and that objection is about the 585-file
# corpus. The candidate set is 13 files / 41 lines today -- measured, 34s serial,
# every one of the 12 non-self candidates emitting exactly one marker line, so
# ZERO false positives where the static classifier's own precision work landed.
# The oracle is exact where the parse was approximate, and it is exact for
# spellings nobody has thought of yet, which is the whole point.
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
# What is closed is the whole class of "a shape the classifier's author did not
# enumerate" for any trap written in the harness itself -- which is what let this
# class arrive three times, and what iteration 1's negative mutants could not see.
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

_rc_candidate_lines() {   # <file> -> "<lineno>:<line>" for every trap/EXIT line that is not the marker
  grep -nE '\btrap\b' "$1" \
    | grep -E '\bEXIT\b' \
    | grep -v 'HARNESS-RC' \
    | grep -vE '^[0-9]+:[[:space:]]*#'
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
  grep -q 'HARNESS-RC' <<<"$out" && return 0
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
    ok "no harness loses its HARNESS-RC line at runtime (${CANDIDATES} of ${#CORPUS[@]} carry a second trap/EXIT line; each was RUN and printed its marker)"
  else
    nok "${#SILENCED[@]} harness(es) emit NO HARNESS-RC line when run -- a later EXIT trap replaced the marker trap:"
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
  n=$(bash "$f" 2>&1 | grep -c 'HARNESS-RC')
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
  n=$(bash "$f" 2>&1 | grep -c 'HARNESS-RC')
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

_mut_negative "a '( trap - EXIT; ... )' reset inside a subshell" \
  "$(_mut_write clean_subshell_reset_unit.sh "$MUT_HEAD
( trap - EXIT; echo inner )
echo body")"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
