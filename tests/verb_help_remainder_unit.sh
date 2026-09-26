#!/usr/bin/env bash
# The --help remainder of PR-1000/PR-1019, `task set-body --body-file=`, and
# `task need --owner=` in the help.
#
# THE DEFECTS (measured on 0.54.0):
#
#   5dive push --help              -> error: unknown flag: --help                 rc 2
#   5dive plugin add --help        -> error: unknown flag: --help                 rc 2
#   5dive self-update --help       -> error: self-update must run as root ...     rc 10
#   5dive task set-body DIVE-0 --body-file=/dev/null
#                                  -> error: unknown flag: --body-file=/dev/null  rc 2
#                                     (`task add` takes --body-file=; set-body only --file=)
#   5dive task need --help | grep -c -- --owner   -> 0   (need.sh parses --owner= since DIVE-3342)
#   5dive task --help      | grep -c -- --owner   -> 0
#
# `push` also answered --help only AFTER opening the task store, so on a box (or a
# sandbox) with no store the question failed with rc 10 before it reached a flag.
#
# The --help arms grade the BUILT BUNDLE, as tests/agent_account_subverb_help_unit.sh
# does: it is what ships, and every run is sandboxed (own HOME and STATE_DIR, no
# task store). set-body is graded on sourced functions against a throwaway
# TASKS_DB, because a sandboxed bundle has no store to write a body into.
#
#   bash tests/verb_help_remainder_unit.sh
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

TMP="$(mktemp -d /tmp/verb-help-remainder.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

# --- the artifact ------------------------------------------------------------
BUNDLE="$TMP/5dive"
if ! BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  bad_t "P0: a bundle builds (every --help arm below runs against it)" "$(tail -3 "$TMP/build.log")"
  echo "-----"; printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1
fi
ok_t "P0: a bundle builds (the artifact the fix ships in)"

mkdir -p "$TMP/home" "$TMP/state"
run() { local b="$1"; shift
  ( HOME="$TMP/home" STATE_DIR="$TMP/state" "$b" "$@" ) </dev/null >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
out() { cat "$TMP/out"; }
err() { cat "$TMP/err"; }

[[ ! -e "$TMP/state/tasks/tasks.db" ]] \
  && ok_t "P1: the sandbox has no task store (so push --help cannot lean on one)" \
  || bad_t "P1: sandbox has no task store" "found $TMP/state/tasks/tasks.db"

# --- H) the three verbs answer --help ------------------------------------------
rc=$(run "$BUNDLE" push --help)
[[ "$rc" == 0 ]] && has "$(head -1 "$TMP/out")" "usage: 5dive push <id|DIVE-N>" \
  && ok_t "H1: 5dive push --help -> rc 0, its usage on stdout, with no task store" \
  || bad_t "H1: push --help" "rc=$rc out=$(out) err=$(err)"
rc=$(run "$BUNDLE" push DIVE-1 -h)
[[ "$rc" == 0 ]] && has "$(out)" "usage: 5dive push" \
  && ok_t "H1b: ...and -h after a task id asks the same question" \
  || bad_t "H1b: push DIVE-1 -h" "rc=$rc out=$(out) err=$(err)"
rc=$(run "$BUNDLE" push --pr-title=--help)
[[ "$rc" != 0 ]] && ! has "$(out)" "usage: 5dive push" \
  && ok_t "H1c: CONTROL: '--help' as a flag VALUE is not a question (rc $rc, no usage)" \
  || bad_t "H1c: --pr-title=--help must not answer help" "rc=$rc out=$(out)"

rc=$(run "$BUNDLE" plugin add --help)
[[ "$rc" == 0 ]] && has "$(out)" "5dive plugin add <plugin>" \
  && ok_t "H2: 5dive plugin add --help -> rc 0, the plugin usage (which documents add) on stdout" \
  || bad_t "H2: plugin add --help" "rc=$rc out=$(out) err=$(err)"
rc=$(run "$BUNDLE" plugin add --as=--help)
! has "$(out)" "5dive plugin add <plugin>" \
  && ok_t "H2b: CONTROL: --as=--help is a value, not a question (rc $rc)" \
  || bad_t "H2b: --as=--help must not answer help" "rc=$rc out=$(out)"

for v in self-update update; do
  rc=$(run "$BUNDLE" "$v" --help)
  [[ "$rc" == 0 ]] && has "$(head -1 "$TMP/out")" "usage: 5dive self-update" \
    && ok_t "H3: 5dive $v --help -> rc 0, usage on stdout (uid $EUID)" \
    || bad_t "H3: $v --help" "rc=$rc out=$(out) err=$(err)"
done
if (( EUID != 0 )); then
  rc=$(run "$BUNDLE" self-update)
  [[ "$rc" != 0 ]] && has "$(err)" "must run as root" \
    && ok_t "H4: CONTROL: self-update without --help is still root-gated (rc $rc)" \
    || bad_t "H4: self-update stays root-gated" "rc=$rc err=$(err)"
else
  # As root the bare verb would run the installer. H3 above already ran as root.
  ok_t "H4: CONTROL skipped under uid 0 (the bare verb would really update this box)"
fi

# --- O) task need --owner= is in both helps -------------------------------------
run "$BUNDLE" task need --help >/dev/null
n=$(grep -c -- '--owner' "$TMP/out")
(( n >= 1 )) && ok_t "O1: 5dive task need --help names --owner ($n line(s))" \
  || bad_t "O1: task need --help names --owner" "$(out)"
run "$BUNDLE" task --help >/dev/null
n=$(grep -c -- '--owner' "$TMP/out")
(( n >= 1 )) && ok_t "O2: 5dive task --help names --owner ($n line(s))" \
  || bad_t "O2: task --help names --owner" "count 0"
grep -q -- '--owner=<human>.*route' "$TMP/out" \
  && ok_t "O3: ...with one line saying it routes the gate to that person" \
  || bad_t "O3: the --owner line says what it does" "$(grep -- '--owner' "$TMP/out")"

# --- S) set-body takes --body-file=, the spelling task add takes ------------------
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
export FIVEDIVE_HARNESS=1   # the board-write fence: this store is a fixture
STATE_DIR="$TMP/sb"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; JSON_MODE=0
mkdir -p "$TASKS_DIR"; tasks_db_init >/dev/null 2>&1
db "INSERT INTO tasks(id, ident, title, status, priority, created_by, created_at, project_key)
    VALUES(7, 'DIVE-7', 'seeded row', 'todo', 'high', 'harness', datetime('now'), 'dive');" >/dev/null 2>&1
printf 'first line\nsecond line\n' > "$TMP/body.txt"
printf 'other body\n' > "$TMP/other.txt"
body() { db "SELECT body FROM tasks WHERE id=7;"; }
setbody() { ( cmd_task_set_body "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }

rc=$(setbody DIVE-7 --body-file="$TMP/body.txt")
[[ "$rc" == 0 && "$(body)" == "$(cat "$TMP/body.txt")" ]] \
  && ok_t "S1: set-body --body-file=<path> sets the body verbatim, newlines kept" \
  || bad_t "S1: set-body --body-file=" "rc=$rc body=[$(body)] err=$(err)"
rc=$(setbody DIVE-7 --file="$TMP/other.txt")
[[ "$rc" == 0 && "$(body)" == "other body" ]] \
  && ok_t "S2: CONTROL: --file=<path> still works" \
  || bad_t "S2: set-body --file= unchanged" "rc=$rc body=[$(body)] err=$(err)"
rc=$(setbody DIVE-7 --file="$TMP/body.txt" --body-file="$TMP/other.txt")
[[ "$rc" == "$E_USAGE" ]] && has "$(err)" "--body-file conflicts with --file" \
  && ok_t "S3: --file= and --body-file= together are refused (rc $rc), naming both" \
  || bad_t "S3: two body files refused" "rc=$rc err=$(err)"
rc=$(setbody DIVE-7 --body-file="$TMP/body.txt" some inline words)
[[ "$rc" == "$E_USAGE" ]] && has "$(err)" "--body-file conflicts with the positional text" \
  && ok_t "S4: --body-file= plus inline text is refused (rc $rc), naming the flag used" \
  || bad_t "S4: --body-file plus inline text refused" "rc=$rc err=$(err)"

# --- M) MUTANT: the bundle without push's help intercept -------------------------
# Re-introduce the defect in a copy of the built bundle; H1 must go red on it.
MUT="$TMP/5dive.mut"
awk '/# Asking what the verb does needs no task store and no broker: answer first\./{skip=1}
     skip && /^  fi$/ {skip=0; next}
     !skip' "$BUNDLE" > "$MUT"; chmod +x "$MUT"
! grep -q 'Asking what the verb does needs no task store' "$MUT" && bash -n "$MUT" \
  && ok_t "M0: (anchor) the mutation removed push's help intercept and the bundle still parses" \
  || bad_t "M0: mutation anchor" "the intercept comment no longer matches, or the cut broke the bundle"
rc=$(run "$MUT" push --help)
[[ "$rc" != 0 ]] \
  && ok_t "M1: MUTANT: without the intercept push --help fails again (rc $rc) — H1 goes red" \
  || bad_t "M1: mutant must fail push --help" "rc=$rc out=$(out)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
