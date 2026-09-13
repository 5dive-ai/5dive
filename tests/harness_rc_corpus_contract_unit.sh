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
trap 'rc=$?; rm -rf "${MUTTMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: this file is itself part of the corpus it enforces; folds in the mutation tempdir cleanup below so a second `trap ... EXIT` doesn't silently replace this one.

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
# neighbour codex_bin_resolution_unit.sh printed HARNESS-RC=0. One offender in a
# 300+ corpus -- so the blast radius is small and the detector has to be PRECISE,
# not merely loud.
#
# WHY "IS IT AT TOP LEVEL" AND NOT "IS THERE A SECOND TRAP LINE". Five other files
# carry a second EXIT trap that is entirely correct, and a line-grep reds all five:
# broker_surface_unit.sh registers one inside a `( ... )` subshell (whose trap dies
# with the subshell), and audit_exit_trap_row / gh_actor_routing / pre_push_rail /
# silent_nonzero_exit_backstop each write one into a quoted heredoc or an awk-built
# FIXTURE -- text that is never executed by this shell at all. All five were
# confirmed by RUNNING them: 1 HARNESS-RC line each. A detector that reds a correct
# file teaches authors to route around it, which is how this contract dies twice.
#
# THE DISCRIMINATOR IS A REAL PARSE BY BASH ITSELF, in DIVE-3679's shape: if
# everything BEFORE the trap line parses as COMPLETE bash, the line runs in this
# shell's top level; an unterminated `(` or an open heredoc leaves the prefix
# incomplete and the line is not ours to judge.
#
# WHY THIS IS NOT `verdict_injection_point_top_level` CALLED VERBATIM, measured
# rather than assumed -- the first cut of this arm DID call it and produced a FALSE
# POSITIVE on tests/pre_push_rail_unit.sh:304, a trap inside a `<<'EOF'` fixture:
#
#   $ head -n 303 tests/pre_push_rail_unit.sh | bash -n
#   warning: here-document at line 300 delimited by end-of-file (wanted `EOF')
#   exit 0
#
# An unterminated heredoc is a WARNING, not an error, so bash -n exits 0 and a
# rc-only reading calls the prefix complete. That is the same class this whole file
# is about: a check that succeeds against the wrong target. Completeness therefore
# requires BOTH rc 0 AND an empty stderr. Recorded here and not fixed in the shared
# library because DIVE-3679's caller asks the question about a TERMINAL verdict line,
# where an open heredoc cannot be in play -- widening that instrument mid-ship to suit
# a new caller is how a working control acquires a behaviour nobody graded.
#
# THREE OUTCOMES. The parse can also FAIL TO RUN (mktemp). That is neither "top
# level" nor "nested" and it is reported as UNKNOWN rather than silently picking a
# side -- a check that cannot run must not answer.
_rc_prefix_is_complete() {   # <file> <lineno> -> 0 top-level, 1 nested/open, 2 could-not-run
  local f="$1" n="$2" pfx err rc
  (( n <= 1 )) && return 0
  pfx=$(mktemp) || return 2
  err=$(mktemp) || { rm -f "$pfx"; return 2; }
  head -n $(( n - 1 )) "$f" > "$pfx" || { rm -f "$pfx" "$err"; return 2; }
  bash -n "$pfx" 2>"$err"; rc=$?
  # Empty stderr is load-bearing, not belt-and-braces: see the heredoc note above.
  if [[ $rc -eq 0 && ! -s "$err" ]]; then rc=0; else rc=1; fi
  rm -f "$pfx" "$err"
  return $rc
}

TRAP_STMT_RE='(^|[;&|do][[:space:]]*|^[[:space:]]*)trap[[:space:]]'

# ONE detector, called by the corpus loop AND by the mutation arms below. A second
# copy for the mutants would grade the copy -- the same argument tests/lib/
# harness-verdict-detect.sh carries for its own extraction.
_rc_silenced_lines() {   # <file> -> "<lineno>:<line>" per silencing trap; "?<lineno>" per unclassifiable
  local f="$1" ln line
  grep -qE "$RC_RE" "$f" || return 0   # no marker to silence; that is the MISSING arm's job
  while IFS=: read -r ln line; do
    [[ -n "$ln" ]] || continue
    _rc_prefix_is_complete "$f" "$ln"
    case $? in
      0) printf '%s:%s\n' "$ln" "$line" ;;
      2) printf '?%s\n' "$ln" ;;
    esac
  done < <(grep -nE "$TRAP_STMT_RE" "$f" \
             | grep -E '\bEXIT\b' \
             | grep -v 'HARNESS-RC' \
             | grep -vE '^[0-9]+:[[:space:]]*#')
}

SILENCED=(); UNKNOWN_TL=()
for t in "${CORPUS[@]}"; do
  while read -r hit; do
    [[ -n "$hit" ]] || continue
    if [[ "$hit" == \?* ]]; then UNKNOWN_TL+=("$t:${hit#?}"); else SILENCED+=("$t:$hit"); fi
  done < <(_rc_silenced_lines "$t")
done

if (( ${#SILENCED[@]} == 0 )); then
  ok "no harness re-registers a top-level EXIT trap that would unarm its HARNESS-RC trap"
else
  nok "${#SILENCED[@]} top-level EXIT trap(s) replace the HARNESS-RC trap and silence it:"
  for m in "${SILENCED[@]}"; do printf '       %s\n' "$m"; done
  printf '\n       FIX -- FOLD the cleanup into the marker trap instead of registering a\n'
  printf '       second one. bash keeps only the LAST trap per signal, so the file above\n'
  printf '       currently emits NO HARNESS-RC line at all, pass or fail:\n\n'
  printf '           trap '"'"'rc=$?; <your cleanup here>; echo "HARNESS-RC=$rc"'"'"' EXIT\n\n'
  printf '       rc=$? must stay FIRST so cleanup cannot overwrite the exit code.\n'
fi

if (( ${#UNKNOWN_TL[@]} > 0 )); then
  nok "${#UNKNOWN_TL[@]} trap line(s) could not be classified (parser could not run); asserting nothing about them:"
  for m in "${UNKNOWN_TL[@]}"; do printf '       %s\n' "$m"; done
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

# DIVE-4440 MUTANTS for the SILENCED arm. Three files, and the two NEGATIVE ones
# are the point: a detector that only proves it can fire is a detector nobody has
# shown to be quiet, and the first cut of this arm DID red a correct file.
#
# Every mutant carries an ANCHOR: the positive one is RUN and shown to actually lose
# its HARNESS-RC line, so the arm is grading a live hazard and not a disliked shape.

# (a) POSITIVE -- a second EXIT trap at top level.
cat > "$MUTTMP/silenced_unit.sh" <<'MUT'
#!/usr/bin/env bash
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
echo body
MUT
if [[ -n "$(_rc_silenced_lines "$MUTTMP/silenced_unit.sh")" ]]; then
  ok "mutation: a second TOP-LEVEL EXIT trap is correctly reported SILENCED"
else
  nok "mutation: a second top-level EXIT trap is (wrongly) reported clean -- the arm has no teeth"
fi
# ANCHOR: prove the mutation is a real silencing, not a shape this file dislikes.
SIL_OUT="$(bash "$MUTTMP/silenced_unit.sh" 2>&1)"
if [[ "$SIL_OUT" != *HARNESS-RC* ]]; then
  ok "mutation: the silenced form is a LIVE bug -- the mutant emits NO HARNESS-RC line at runtime"
else
  nok "mutation: expected the mutant to emit no HARNESS-RC (got: $SIL_OUT) -- the arm above grades nothing"
fi

# (b) NEGATIVE -- inside a ( ... ) subshell. The trap dies with the subshell and the
# parent's marker trap is untouched (tests/broker_surface_unit.sh does exactly this).
cat > "$MUTTMP/subshell_unit.sh" <<'MUT'
#!/usr/bin/env bash
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
(
  trap 'echo inner' EXIT
  echo body
)
MUT
if [[ -z "$(_rc_silenced_lines "$MUTTMP/subshell_unit.sh")" ]]; then
  ok "mutation NEGATIVE: an EXIT trap inside a subshell is correctly NOT reported"
else
  nok "mutation NEGATIVE: a subshell EXIT trap is (wrongly) reported silenced -- false positive"
fi
SUB_OUT="$(bash "$MUTTMP/subshell_unit.sh" 2>&1)"
if [[ "$SUB_OUT" == *HARNESS-RC* ]]; then
  ok "mutation NEGATIVE anchor: the subshell mutant really does still print HARNESS-RC"
else
  nok "mutation NEGATIVE anchor: the subshell mutant lost HARNESS-RC -- the negative control is wrong"
fi

# (c) NEGATIVE -- inside a QUOTED HEREDOC, i.e. text written to a fixture and never
# executed by this shell. This is the exact false positive the first cut produced on
# tests/pre_push_rail_unit.sh:304, pinned so it cannot come back: bash -n only WARNS
# on an unterminated heredoc, so an rc-only completeness test calls this top level.
cat > "$MUTTMP/heredoc_unit.sh" <<'MUT'
#!/usr/bin/env bash
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cat > /dev/null <<'FIXTURE'
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
FIXTURE
echo body
MUT
if [[ -z "$(_rc_silenced_lines "$MUTTMP/heredoc_unit.sh")" ]]; then
  ok "mutation NEGATIVE: an EXIT trap inside a quoted heredoc is correctly NOT reported"
else
  nok "mutation NEGATIVE: a heredoc EXIT trap is (wrongly) reported silenced -- the heredoc-warning gap is back"
fi
HD_OUT="$(bash "$MUTTMP/heredoc_unit.sh" 2>&1)"
if [[ "$HD_OUT" == *HARNESS-RC* ]]; then
  ok "mutation NEGATIVE anchor: the heredoc mutant really does still print HARNESS-RC"
else
  nok "mutation NEGATIVE anchor: the heredoc mutant lost HARNESS-RC -- the negative control is wrong"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
