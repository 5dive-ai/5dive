#!/usr/bin/env bash
# `5dive doctor --help` answers, without root.
#
# THE DEFECT (measured on 0.64.0): cmd_doctor called require_root before it read
# an argument, and its flag loop had no help arm, so asking was refused twice:
#
#   5dive doctor --help        -> error: must run as root — try: sudo 5dive doctor --help   rc 10
#   sudo 5dive doctor --help   -> error: unknown flag: --help                                rc 2
#   5dive doctor -h            -> the same pair
#
# while push, plugin add, self-update and task doctor all answered --help with rc 0.
# The fix answers before the root check, with the block `5dive --help` prints for
# doctor rather than a second copy of it.
#
# Graded on the BUILT BUNDLE, sandboxed (own HOME and STATE_DIR), as
# tests/verb_help_remainder_unit.sh does. The mutant is that bundle with the help
# arm's condition reverted — one line, substituted in place.
#
#   bash tests/doctor_help_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d /tmp/doctor-help-unit.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# --- the artifact ------------------------------------------------------------
BIN="$TMP/5dive"
if ! BUILD_OUT="$BIN" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "P0: a bundle builds (every arm below runs against it)" "$(tail -3 "$TMP/build.log")"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
ok_t "P0: a bundle builds (the artifact the fix ships in)"

mkdir -p "$TMP/home" "$TMP/state"
run() { local b="$1"; shift
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" "$b" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }

# Which uid graded this. As root the root check passes on its own, so the H arms
# still grade the help arm (pre-fix root got rc 2) but not the "no root" half.
if [[ "$(id -u)" == 0 ]]; then
  printf 'note: running as root — the arms grade the help arm, not that it needs no root\n'
else
  printf 'note: running as uid %s (non-root)\n' "$(id -u)"
fi

# The doctor block of `5dive --help`, cut independently of the code under test:
# its entry line to the next blank line.
run "$BIN" --help >/dev/null
top_block=$(awk '/^  5dive doctor /{b=1} b&&/^$/{exit} b' "$TMP/out")
[[ -n "$top_block" ]] \
  && ok_t "P1: '5dive --help' documents doctor (the block the fix reprints)" \
  || bad_t "P1: '5dive --help' has a doctor block" "$(head -5 "$TMP/out")"

# --- H) the question is answered ---------------------------------------------
rc=$(run "$BIN" doctor --help)
[[ "$rc" == 0 ]] && has "$(head -1 "$TMP/out")" "usage: 5dive doctor [--fix]" \
  && ok_t "H1: 5dive doctor --help -> rc 0, 'usage: 5dive doctor [--fix]' on stdout" \
  || bad_t "H1: doctor --help" "rc=$rc out=$(head -3 "$TMP/out") err=$(err)"
want="usage: ${top_block#  }"
[[ "$(out)" == "$want" ]] \
  && ok_t "H2: ...and it is the doctor block of '5dive --help', not a second copy" \
  || bad_t "H2: doctor --help reprints the top-level block" "$(diff <(printf '%s\n' "$want") "$TMP/out" | head -6)"

rc=$(run "$BIN" doctor -h)
[[ "$rc" == 0 ]] && has "$(head -1 "$TMP/out")" "usage: 5dive doctor [--fix]" \
  && ok_t "H3: 5dive doctor -h -> the same answer" \
  || bad_t "H3: doctor -h" "rc=$rc out=$(head -3 "$TMP/out") err=$(err)"

rc=$(run "$BIN" doctor --fix --help)
[[ "$rc" == 0 ]] && has "$(head -1 "$TMP/out")" "usage: 5dive doctor [--fix]" \
  && ok_t "H4: doctor --fix --help asks the question; nothing is repaired" \
  || bad_t "H4: doctor --fix --help" "rc=$rc out=$(head -3 "$TMP/out") err=$(err)"

# --- C) CONTROL: help is not a way past the checks ---------------------------
rc=$(run "$BIN" doctor --bogus)
[[ "$rc" != 0 ]] && ! has "$(out)" "usage: 5dive doctor" \
  && ok_t "C1: CONTROL: doctor --bogus is still refused (rc $rc), with no usage block" \
  || bad_t "C1: doctor --bogus must still fail" "rc=$rc out=$(head -3 "$TMP/out")"
rc=$(run "$BIN" doctor --category=--help)
! has "$(out)" "usage: 5dive doctor" \
  && ok_t "C2: CONTROL: '--help' as a flag VALUE is not a question (rc $rc, no usage)" \
  || bad_t "C2: --category=--help must not answer help" "rc=$rc out=$(head -3 "$TMP/out")"

# --- M) MUTANT: the help arm's condition reverted ------------------------------
MUT="$TMP/5dive-mutant"
cp "$BIN" "$MUT"; chmod +x "$MUT"
perl -0pi -e 's/if _verb_help_wanted "\$\@"; then(\n\s+AUDIT_CMD=""   # a help request)/if false; then$1/' "$MUT"
changed=$(diff "$BIN" "$MUT" | grep -c '^[<>]')
if [[ "$changed" != 2 ]]; then
  bad_t "M0: the mutant is exactly one reverted line" "diff shows $changed changed line(s) — the substitution no longer matches cmd_doctor"
else
  ok_t "M0: the mutant is exactly one reverted line"
  rc=$(run "$MUT" doctor --help)
  [[ "$rc" != 0 ]] \
    && ok_t "M1: MUTANT without the help arm goes red: doctor --help -> rc $rc ($(head -1 "$TMP/err"))" \
    || bad_t "M1: MUTANT stayed green — H1 cannot tell the fix from its absence" "rc=$rc out=$(head -2 "$TMP/out")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
