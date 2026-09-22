#!/usr/bin/env bash
# Every `5dive task` SUBVERB answers `--help` with its own usage.
#
# `5dive task --help` printed the task surface, but every subverb rejected the
# flag: each one parses its own flags and 34 of those loops end in
# `-*) fail "$E_USAGE" "unknown flag: $1"`. So `5dive task ls --help` — what an
# operator types to ask a verb how it works — answered "unknown flag: --help"
# and printed the usage line of whatever the loop thought it was doing.
#
# WHAT THIS GRADES, and why it walks the case statement instead of a list: the
# fix answers in ONE place (cmd_task, before the dispatch) and READS the text
# from the surface usage or from the verb's own `usage:` literal. A list of verbs
# in here would go stale exactly when a new verb is added without either — which
# is the case this is built to catch. So the labels come out of `cmd_task`'s own
# `case` in src/task/dispatch.sh, every one of them is asked for help, and the
# count is printed so a shrinking corpus is visible rather than silent.
#
#   bash tests/task_subverb_help_unit.sh   (no root, no network)
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
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/task-subverb-help.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_project.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e; tasks_db_init >/dev/null 2>&1

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# `fail` exits, so every subverb call runs in a subshell.
ask()   { ( cmd_task "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
out()   { cat "$TMP/out"; }
err()   { cat "$TMP/err"; }
first() { head -1 "$TMP/out"; }

# --- 0) The corpus: every label cmd_task's own case dispatches ---------------
# Read out of the FILE, not out of the runtime, so a fix that broke the runtime
# reader could not also shrink the list it is graded against.
mapfile -t LABELS < <(awk '/^cmd_task\(\) \{/,/^\}/' "$SRC/task/dispatch.sh" \
  | sed -n 's/^    \([a-z0-9|_-]*\))[[:space:]]*cmd_task_[a-z_]*.*/\1/p' | tr '|' '\n')
(( ${#LABELS[@]} >= 49 )) \
  && ok_t "precondition: cmd_task's case dispatches ${#LABELS[@]} subverb labels" \
  || bad_t "precondition: the case statement enumerates its subverbs" "found only ${#LABELS[@]}"
grep -qx 'ls' <<<"$(printf '%s\n' "${LABELS[@]}")" && grep -qx 'list' <<<"$(printf '%s\n' "${LABELS[@]}")" \
  && ok_t "precondition: the corpus carries aliases too (ls and list are both in it)" \
  || bad_t "precondition: aliases are in the corpus" "ls/list missing from ${#LABELS[@]} labels"

# --- A) EVERY label answers --help, with ITS OWN usage -----------------------
# Split-tree caveat, stated rather than hidden: src/cmd_task.sh's loader does not
# source task/grader_pool.sh, so `grader-replay`/`grader-tick` are not defined
# HERE at all (they are in the bundle, which cats every src/task/*.sh). They are
# graded through the built bundle in arm G. Arm B pins that exception list so it
# cannot quietly grow.
ANSWERED=0; ASKED=0; UNDEFINED=(); BAD_RC=(); BAD_LINE=()
for lab in "${LABELS[@]}"; do
  [[ -n "$lab" ]] || continue
  read -r canon fn <<<"$(_task_verb_arm "$lab")"
  if ! declare -F "$fn" >/dev/null 2>&1; then UNDEFINED+=("$lab"); continue; fi
  ASKED=$((ASKED+1))
  rc="$(ask "$lab" --help)"
  [[ "$rc" == "0" ]] || { BAD_RC+=("$lab(rc=$rc: $(err | head -1))"); continue; }
  line="$(first)"
  case "$line" in
    "usage: 5dive task $canon"*) ANSWERED=$((ANSWERED+1)) ;;
    *) BAD_LINE+=("$lab -> ${line:-<empty>}") ;;
  esac
done
(( ${#BAD_RC[@]} == 0 )) \
  && ok_t "A1: all $ASKED dispatchable labels exit 0 on --help" \
  || bad_t "A1: --help exits 0 for every dispatchable label" "${#BAD_RC[@]} did not: ${BAD_RC[*]}"
(( ${#BAD_LINE[@]} == 0 && ANSWERED == ASKED )) \
  && ok_t "A2: all $ANSWERED of them open with 'usage: 5dive task <verb>'" \
  || bad_t "A2: every label prints its own usage line" "${#BAD_LINE[@]} wrong: ${BAD_LINE[*]}"

# A3: the answer is the verb's OWN usage, not the whole task surface — the
# failure a "print _task_usage for everything" fix would pass A1 and A2 with.
ask park --help >/dev/null
SURFACE_LINES=$(_task_usage | grep -c '')
PARK_LINES=$(out | grep -c '')
{ (( PARK_LINES > 0 && PARK_LINES < SURFACE_LINES / 4 )) && has "$(out)" 'auto-unparks at --wake'; } \
  && ok_t "A3: 'park --help' is park's entry ($PARK_LINES lines), not the $SURFACE_LINES-line surface" \
  || bad_t "A3: the answer is scoped to the verb" "$PARK_LINES lines against a $SURFACE_LINES-line surface"

# A4: a verb the surface does NOT document falls back to its own `usage:`
# literal. `loop` is that case in this tree; without the fallback it answers
# nothing at all.
rc="$(ask loop --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive task loop'; } \
  && ok_t "A4: an undocumented-on-the-surface verb falls back to its own literal (loop)" \
  || bad_t "A4: the own-literal fallback answers" "rc=$rc first: $(first)"
! _task_usage | grep -qE '^  loop[ |]' \
  && ok_t "A4b: ... and 'loop' really is absent from the surface (A4 is not vacuous)" \
  || bad_t "A4b: loop is absent from the surface usage" "it is documented there, so A4 proves nothing"

# --- B) The two labels this tree cannot define, pinned by name --------------
[[ "${UNDEFINED[*]}" == "grader-replay grader-tick" ]] \
  && ok_t "B1: exactly the 2 known split-tree gaps are undefined here (${UNDEFINED[*]}) — graded in G" \
  || bad_t "B1: the split-tree exception list is unchanged" "got: '${UNDEFINED[*]}' (expected 'grader-replay grader-tick')"
! declare -F cmd_task_grader_tick >/dev/null 2>&1 \
  && ok_t "B2: ... and that gap is src/cmd_task.sh's loader, not this change (the verb is undefined, not unhelped)" \
  || bad_t "B2: grader-tick is genuinely undefined in the split tree" "it is defined, so B1 is wrong"

# --- C) The spellings, and where help STOPS being a question ----------------
rc="$(ask show -h)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive task show'; } \
  && ok_t "C1: -h is the same question as --help" \
  || bad_t "C1: -h answers" "rc=$rc first: $(first)"
rc="$(ask show 1 --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive task show'; } \
  && ok_t "C2: --help AFTER a positional still asks about the verb" \
  || bad_t "C2: --help after a positional answers" "rc=$rc first: $(first)"
rc="$(ask show -- --help)"
{ [[ "$rc" != "0" ]] && ! has "$(first)" 'usage: 5dive task show'; } \
  && ok_t "C3: '--' ends the flags: --help after it is an ARGUMENT, not a question" \
  || bad_t "C3: -- stops the help scan" "rc=$rc first: $(first)"
! _task_help_wanted '--ask=should we ship it --help me decide' \
  && ok_t "C4: a --help INSIDE a value is a value, not a question" \
  || bad_t "C4: --help inside a value is not a question" "it was taken as one"
rc="$(ask --help)"
{ [[ "$rc" == "0" ]] && has "$(out)" '5dive task — shared task queue'; } \
  && ok_t "C5: '5dive task --help' still prints the whole surface" \
  || bad_t "C5: the surface help is unchanged" "rc=$rc first: $(first)"
rc="$(ask ls)"
[[ "$rc" == "0" ]] \
  && ok_t "C6: an ordinary call is not swallowed — 'task ls' still runs" \
  || bad_t "C6: the intercept only fires on --help" "rc=$rc err: $(err | head -1)"

# --- D) Aliases answer with the verb they actually run ----------------------
D_BAD=()
for pair in "list ls" "view show" "close done" "gates inbox" "new add" "delete rm"; do
  read -r alias canon <<<"$pair"
  rc="$(ask "$alias" --help)"
  { [[ "$rc" == "0" ]] && has "$(first)" "usage: 5dive task $canon"; } || D_BAD+=("$alias(rc=$rc: $(first))")
done
(( ${#D_BAD[@]} == 0 )) \
  && ok_t "D1: all 6 aliases answer with the canonical verb's usage" \
  || bad_t "D1: aliases resolve to the verb they run" "${D_BAD[*]}"

# --- E) The verbs that ALREADY answered --help still answer ------------------
E_BAD=()
for v in merge merge-audit merge-unverified merge-gate-selftest queue; do
  rc="$(ask "$v" --help)"
  { [[ "$rc" == "0" ]] && has "$(first)" "usage: 5dive task $v"; } || E_BAD+=("$v(rc=$rc)")
done
(( ${#E_BAD[@]} == 0 )) \
  && ok_t "E1: the 5 verbs that answered --help themselves still answer (now through the one place)" \
  || bad_t "E1: no regression on the verbs that already answered" "${E_BAD[*]}"

# --- F) MUTANT: take the intercept out and the defect comes back ------------
# BEFORE/AFTER on purpose: "the intercept is gone" is also true of a sed that
# matched nothing, which would make every arm below vacuous.
ORIG="$(declare -f cmd_task)"
MUT="$(printf '%s\n' "$ORIG" | sed 's/^\([[:space:]]*\)if _task_help_intercept.*/\1if false; then/')"
has "$ORIG" '_task_help_intercept' \
  && ok_t "F0a: BEFORE — the shipped dispatcher really does intercept --help" \
  || bad_t "F0a: the dispatcher intercepts --help" "no intercept found; every mutant arm below is vacuous"
! has "$MUT" '_task_help_intercept' \
  && ok_t "F0b: AFTER — the mutation really removed it (the sed matched)" \
  || bad_t "F0b: the mutation removed the intercept" "the sed did not match; the mutant is not mutated"

eval "$MUT"
rc="$(ask ls --help)"
[[ "$rc" != "0" ]] \
  && ok_t "F1: MUTANT — 'task ls --help' fails again (A1 would be red on it)" \
  || bad_t "F1: mutant fails on ls --help" "it exited 0: $(first)"
has "$(err)" 'unknown flag: --help' \
  && ok_t "F2: MUTANT — and the operator is back to 'unknown flag: --help' (the defect)" \
  || bad_t "F2: mutant prints the original error" "stderr: $(err | head -1)"

eval "$ORIG"
rc="$(ask ls --help)"
{ [[ "$rc" == "0" ]] && has "$(first)" 'usage: 5dive task ls'; } \
  && ok_t "F3: RESTORE took — the fixed dispatcher is back (later arms grade the fix, not the mutant)" \
  || bad_t "F3: restore took" "rc=$rc first: $(first)"

# --- G) THE SHIPPED ARTIFACT, where the lazy-autoload path actually runs -----
# src/ has every function defined; the BUNDLE carries the task modules as
# unparsed text behind autoload stubs (DIVE-4087), so the own-literal fallback
# has to load a module before it can read one. That branch cannot run in the
# arms above, and this is the only place it is exercised.
BUNDLE="$TMP/5dive"
if BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  ok_t "G0: a bundle builds (the artifact the fix actually ships in)"
  G_BAD=()
  for spec in "ls|usage: 5dive task ls" "list|usage: 5dive task ls" "park|usage: 5dive task park" \
              "grader-tick|usage: 5dive task grader-tick" "grader-replay|usage: 5dive task grader-replay"; do
    v="${spec%%|*}"; want="${spec#*|}"
    bout="$(HOME="$TMP" "$BUNDLE" task "$v" --help 2>"$TMP/berr")"; brc=$?
    { [[ "$brc" == "0" ]] && has "$bout" "$want"; } \
      || G_BAD+=("$v(rc=$brc: $(printf '%s' "${bout:-$(head -1 "$TMP/berr")}" | head -1))")
  done
  (( ${#G_BAD[@]} == 0 )) \
    && ok_t "G1: the bundle answers --help for a surface verb, an alias and both lazy-only verbs" \
    || bad_t "G1: the bundle answers --help" "${G_BAD[*]}"
  # G2 proves G1's last two are not passing by accident: in the bundle those two
  # verbs have no surface entry, so only the module-loading fallback can answer.
  ! HOME="$TMP" "$BUNDLE" task --help 2>/dev/null | grep -qE '^  grader-tick[ |]' \
    && ok_t "G2: ... and 'grader-tick' is absent from the bundle's surface, so only the fallback could have answered" \
    || bad_t "G2: grader-tick is absent from the surface" "it is documented there; G1 proves less than it says"
else
  bad_t "G0: a bundle builds" "$(tail -3 "$TMP/build.log")"
fi

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
