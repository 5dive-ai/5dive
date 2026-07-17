#!/usr/bin/env bash
# DIVE-1376 isolated unit harness for `5dive push` — the delegated-push verb.
# Covers every NON-CREDENTIAL path (the live token-mint + real push is smoked
# separately against the control-plane GitHub App). Same isolation posture as
# objective_status_unit.sh: source the src/ libs, point STATE_DIR at a throwaway
# temp dir, seed the tasks store directly, and drive cmd_push in a scratch git
# repo. Asserts the fail-closed refusals + the happy-path dry-run:
#   - no branch (no --branch, no 'Branch:' body line) -> refuse
#   - protected branch (main/master/HEAD) -> refuse
#   - no gate on the task -> refuse
#   - open (unanswered) gate -> refuse
#   - rejected gate answer -> refuse
#   - author scan fail-closed (a non-lodar commit on the branch) -> refuse
#   - happy dry-run (gate cleared + author=lodar) -> ok, prints dryRun:true
# Run: bash tests/push_unit.sh  (no root, no network — token mint never runs).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/push-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_push.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

LODAR='lodar <markounik@gmail.com>'

# Seed a task with an optional body + gate state.
# seed_task <ident> <body> <need_type> <need_answered_at> <need_answer>
seed_task() {
  db "INSERT INTO tasks(ident,project_key,title,status,assignee,kind,body,
         need_type,need_answered_at,need_answer)
      VALUES($(sqlq "$1"),'dive',$(sqlq "t-$1"),'in_progress','dev','standard',
             $(sqlq "$2"),$(sqlq_or_null "$3"),$(sqlq_or_null "$4"),$(sqlq_or_null "$5"));"
}

# A scratch git repo so the author-scan + branch-existence checks run for real.
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO"
  git init -q
  git config user.name lodar; git config user.email markounik@gmail.com
  git commit -q --allow-empty -m "base (lodar)" --author="$LODAR"
  git branch -q feature-ok
  git checkout -q feature-ok
  git commit -q --allow-empty -m "work (lodar)" --author="$LODAR"
  git checkout -q -b feature-badauthor
  git commit -q --allow-empty -m "sneaky" --author="Bobby <bob@evil.test>"
  git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || true
) >/dev/null 2>&1

# run_push <ident> [args...] — capture combined output + rc from cmd_push, run
# inside the scratch repo (git checks need a work tree). --repo points at the
# local repo so the author scan's `git fetch` no-ops and it scans the branch.
run_push() {
  local ident="$1"; shift
  ( cd "$REPO"; cmd_push "$ident" --repo="file://$REPO" "$@" ) 2>&1
}

# 1) no branch -> refuse
seed_task DIVE-901 "no branch here" decision "2026-07-18 00:00:00" "yes ship it"
out=$(run_push DIVE-901 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "no branch" <<<"$out"; } \
  && ok_t "no branch -> refuse" || bad_t "no branch -> refuse" "rc=$rc :: $out"

# 2) protected branch -> refuse
seed_task DIVE-902 "Branch: feature-ok" decision "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-902 --branch=main --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "protected branch" <<<"$out"; } \
  && ok_t "protected branch -> refuse" || bad_t "protected branch -> refuse" "rc=$rc :: $out"

# 3) no gate -> refuse
seed_task DIVE-903 "Branch: feature-ok" "" "" ""
out=$(run_push DIVE-903 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "no gate" <<<"$out"; } \
  && ok_t "no gate -> refuse" || bad_t "no gate -> refuse" "rc=$rc :: $out"

# 4) open (unanswered) gate -> refuse
seed_task DIVE-904 "Branch: feature-ok" manual "" ""
out=$(run_push DIVE-904 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qiE "OPEN|unanswered" <<<"$out"; } \
  && ok_t "open gate -> refuse" || bad_t "open gate -> refuse" "rc=$rc :: $out"

# 5) rejected gate -> refuse
seed_task DIVE-905 "Branch: feature-ok" approval "2026-07-18 00:00:00" "no, do not ship"
out=$(run_push DIVE-905 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "REJECTED" <<<"$out"; } \
  && ok_t "rejected gate -> refuse" || bad_t "rejected gate -> refuse" "rc=$rc :: $out"

# 6) author scan fail-closed (non-lodar commit on branch) -> refuse
seed_task DIVE-906 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-906 --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "author check FAILED" <<<"$out"; } \
  && ok_t "non-lodar author -> refuse" || bad_t "non-lodar author -> refuse" "rc=$rc :: $out"

# 7) happy dry-run (gate cleared + author=lodar) -> ok, no token mint
seed_task DIVE-907 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes ship it"
out=$(run_push DIVE-907 --dry-run); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "dry-run: would push" <<<"$out"; } \
  && ok_t "happy dry-run -> ok" || bad_t "happy dry-run -> ok" "rc=$rc :: $out"

# 8) branch from --branch overrides a body line
seed_task DIVE-908 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-908 --branch=feature-ok --dry-run); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "would push feature-ok" <<<"$out"; } \
  && ok_t "--branch overrides body line" || bad_t "--branch overrides body line" "rc=$rc :: $out"

echo "-----"
printf 'push_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
