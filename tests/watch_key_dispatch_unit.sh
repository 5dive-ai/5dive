#!/usr/bin/env bash
# DIVE-3484: `5dive watch` died on arrow-down, and the reason was `set -e`.
#
# `(( selected++ ))` is a POST-increment: it evaluates to the OLD value, so at
# selected=0 — the default selection, the very first thing a user's arrow-down
# hits — the arithmetic command returns 1. As the LAST command of an `&&` list
# it is not exempt from `set -e`, so the shell exited 1 mid-loop, past every
# error path, and the user got the never-exit-silently backstop instead of a
# moving cursor. Reported by lodar 2026-08-16.
#
# This harness grades the SHIPPED LINES, not a transcription of them: it lifts
# each key's case arm straight out of src/cmd_watch.sh and executes it under the
# same `set -euo pipefail` the CLI runs with. A rewrite of the dispatch that
# reintroduces any arithmetic-command-as-last-`&&`-operand fails here whatever
# form it takes, because the failure graded is the exit status, not the syntax.
#
# The guard-false direction is deliberately covered too (arrow-up at the top,
# arrow-down at the bottom, an empty roster): `set -e` does NOT fire when the
# *first* operand of an `&&` list fails, and that asymmetry is the whole reason
# only one of the four keys ever crashed. A future reader who "fixes" the safe
# half will see these arms hold it.
set -uo pipefail
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/cmd_watch.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

[ -r "$SRC" ] || { bad "src/cmd_watch.sh not readable — nothing graded"; echo; printf '%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# The arm runner. The NESTING is load-bearing and it is why this is generated
# text rather than an `eval`: `set -e` exempts a failed first operand of an `&&`
# list, but `eval`/`.` are plain commands, so running the arm through either
# reports an exit the real loop does not take (measured: all four arms "failed"
# their guard-false cases under eval, none of them do in cmd_watch). So the arm
# is written into the same shape the source runs it in — a case arm, inside the
# key loop, with a command after it.
write_arm() { # $1 count  $2 selected  $3 stmt
  {
    printf 'set -euo pipefail\n'
    printf 'count=%s\n'    "$1"
    printf 'selected=%s\n' "$2"
    printf 'while :; do\n  case k in\n    k) %s ;;\n  esac\n  break\ndone\n' "$3"
    printf 'printf "%%s" "$selected"\n'
  } >"$TMP/arm.sh"
}

# Lift one case arm out of the key dispatch. Strips the `<label>)` head and the
# `;;` tail, leaving the statement the interactive loop actually runs.
arm_of() { # $1 = literal case label as it appears in the source, e.g. 'j|J)'
  grep -F -- "$1" "$SRC" | grep -E '\bselected\b' | head -1 \
    | sed -E 's/^[[:space:]]*[^)]*\)[[:space:]]*//; s/[[:space:]]*;;[[:space:]]*$//'
}

# $1 label  $2 stmt  $3 count  $4 selected-in  $5 expected selected-out
grade() {
  local out rc
  write_arm "$3" "$4" "$2"
  out=$(bash "$TMP/arm.sh" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$1 (count=$3 selected=$4): the arm EXITED $rc — watch dies here"
  elif [ "$out" != "$5" ]; then
    bad "$1 (count=$3 selected=$4): selected=$out, want $5"
  else
    ok "$1 (count=$3 selected=$4) -> selected=$5"
  fi
}

echo "== the four selection arms are present in the source =="
declare -A ARM=()
for label in 'j|J)' 'k|K)' 'A)' 'B)'; do
  stmt="$(arm_of "$label")"
  if [ -n "$stmt" ]; then
    ARM["$label"]="$stmt"
    ok "extracted $label -> $stmt"
  else
    bad "no case arm matched $label — this harness would grade nothing"
  fi
done

echo "== moving DOWN (j, and ESC[B) — the arm that crashed =="
for label in 'j|J)' 'B)'; do
  stmt="${ARM[$label]:-}"; [ -n "$stmt" ] || continue
  grade "$label from the top"       "$stmt" 5 0 1   # THE REPORTED BUG
  grade "$label mid-list"           "$stmt" 5 3 4
  grade "$label at the bottom"      "$stmt" 5 4 4   # guard false: no move, no exit
  grade "$label on an empty roster" "$stmt" 0 0 0
done

echo "== moving UP (k, and ESC[A) =="
for label in 'k|K)' 'A)'; do
  stmt="${ARM[$label]:-}"; [ -n "$stmt" ] || continue
  grade "$label from the bottom"    "$stmt" 5 4 3
  grade "$label mid-list"           "$stmt" 5 1 0   # lands on 0 — the value that bit us
  grade "$label at the top"         "$stmt" 5 0 0   # guard false: no move, no exit
  grade "$label on an empty roster" "$stmt" 0 0 0
done

echo "== negative control: this runner can still produce the crash =="
# Every arm above passing is only evidence if the runner is capable of failing.
# The pre-fix line, verbatim, through the same runner: it MUST exit at
# selected=0 and MUST survive everywhere else — that asymmetry is the bug's
# signature, and a runner that cannot reproduce it is grading nothing.
DEFECTIVE='(( count > 0 && selected < count - 1 )) && ((selected++))'
write_arm 5 0 "$DEFECTIVE"
if bash "$TMP/arm.sh" >/dev/null 2>&1; then
  bad "the pre-fix line SURVIVED selected=0 — this runner cannot see the reported bug"
else
  ok "the pre-fix line still exits at selected=0 (the runner reproduces the report)"
fi
write_arm 5 3 "$DEFECTIVE"
if bash "$TMP/arm.sh" >/dev/null 2>&1; then
  ok "the pre-fix line survives selected=3 — the runner is not failing everything"
else
  bad "the pre-fix line failed away from the boundary — the runner exits on its own"
fi

echo "== the class, across every command =="
# `cmd ... && ((x++))` and `&& ((x--))` are the shape: an arithmetic command as
# the last operand of an && list returns 1 whenever its value is 0, which under
# `set -euo pipefail` is an exit, not a no-op. Prefer `x=$(( x + 1 ))`.
hits="$(grep -rnE '&&[[:space:]]*\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\+\+|--)[[:space:]]*\)\)' "$ROOT/src/" || true)"
if [ -z "$hits" ]; then
  ok "no arithmetic post-increment as the last operand of an && list in src/"
else
  bad "arithmetic post-increment ends an && list — returns 1 at value 0, exits under set -e:"
  printf '%s\n' "$hits" | sed 's/^/         /'
fi

# A grep that can no longer find its own target passes forever. Positive-control
# the pattern against the pre-fix line so a silent regex rot is visible.
canary='          j|J) (( count > 0 && selected < count - 1 )) && ((selected++)) ;;'
if printf '%s\n' "$canary" | grep -qE '&&[[:space:]]*\(\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\+\+|--)[[:space:]]*\)\)'; then
  ok "the class pattern still matches the original defective line"
else
  bad "the class pattern no longer matches the line it was written for — the scan above proves nothing"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
