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
#   - config-only author scan: unset committer -> any author passes; a configured
#     committer passes a matching-author branch and refuses a mismatching one
#   - happy dry-run (gate cleared) -> ok, prints dryRun:true
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
# Hermetic: point the App env at an absent path so the pre-flight never reads the
# box's real /etc/5dive/connectors/github-app.env. The committer to enforce is
# config-only (DIVE-1461): supplied per-test via GITHUB_APP_COMMIT_AUTHOR.
export GITHUB_APP_ENV="$TMP/no-app-env"
unset GITHUB_APP_COMMIT_AUTHOR
mkdir -p "$TASKS_DIR"
set +e

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Neutral test identities — the public test source carries no real personal email.
AUTHOR='Ada Lovelace <ada@example.test>'   # the "configured" committer to enforce
OTHER='Bob Byte <bob@example.test>'        # a non-matching author

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
  git config user.name test; git config user.email test@example.test
  git commit -q --allow-empty -m "base" --author="$AUTHOR"
  git branch -q feature-ok
  git checkout -q feature-ok
  git commit -q --allow-empty -m "work" --author="$AUTHOR"
  git checkout -q -b feature-badauthor
  git commit -q --allow-empty -m "other-author" --author="$OTHER"
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

# 6) DIVE-1461 config-only: with NO committer configured, the author scan is a
# no-op — even a mismatched-author branch pushes (no restriction).
seed_task DIVE-906 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-906 --dry-run); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "would push" <<<"$out"; } \
  && ok_t "unset committer -> any author passes" || bad_t "unset committer -> any author passes" "rc=$rc :: $out"

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

# 9) DIVE-1461 config-only: with a committer CONFIGURED (via GITHUB_APP_COMMIT_AUTHOR,
# as _push_do sees it after sourcing the App env), a MATCHING-author branch passes...
seed_task DIVE-921 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes"
out=$( export GITHUB_APP_COMMIT_AUTHOR="$AUTHOR"; run_push DIVE-921 --dry-run ); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "would push" <<<"$out"; } \
  && ok_t "set committer: matching author -> pass" || bad_t "set committer: matching author -> pass" "rc=$rc :: $out"

# 10) ...and a NON-matching-author branch is refused fail-closed.
seed_task DIVE-922 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
out=$( export GITHUB_APP_COMMIT_AUTHOR="$AUTHOR"; run_push DIVE-922 --dry-run ); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "author check FAILED" <<<"$out"; } \
  && ok_t "set committer: non-matching author -> refuse" || bad_t "set committer: non-matching author -> refuse" "rc=$rc :: $out"

# --- DIVE-1460: the shared cleared-gate predicate. cmd_push AND the root-only
# token mint (cmd_push_mint_token) both call _push_gate_check, so a direct
# `sudo 5dive _push_mint_token <task>` re-verifies the SAME human gate and can't
# be a bypass door. Assert the predicate here (the mint's root/credential steps
# run only as root with the App key, so its gate branch is covered via this).
gate_check() { # <ident> -> combined output; rc via subshell (fail exits it)
  local i; i=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");")
  ( _push_gate_check "$i" "$1" ) 2>&1
}

# cleared gate (DIVE-907 seeded above: answered approval "yes ship it") -> ok
out=$(gate_check DIVE-907); rc=$?
[[ $rc -eq 0 ]] && ok_t "gate predicate: cleared -> pass" || bad_t "gate predicate: cleared -> pass" "rc=$rc :: $out"

# no gate (DIVE-903) -> refuse
out=$(gate_check DIVE-903); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "no gate" <<<"$out"; } \
  && ok_t "gate predicate: no gate -> refuse" || bad_t "gate predicate: no gate -> refuse" "rc=$rc :: $out"

# open gate (DIVE-904) -> refuse
out=$(gate_check DIVE-904); rc=$?
{ [[ $rc -ne 0 ]] && grep -qiE "OPEN|unanswered" <<<"$out"; } \
  && ok_t "gate predicate: open -> refuse" || bad_t "gate predicate: open -> refuse" "rc=$rc :: $out"

# rejected gate (DIVE-905) -> refuse
out=$(gate_check DIVE-905); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "REJECTED" <<<"$out"; } \
  && ok_t "gate predicate: rejected -> refuse" || bad_t "gate predicate: rejected -> refuse" "rc=$rc :: $out"

# cmd_push hands the real push to the root helper over STDIN (the privileged work
# — gate/author/mint/push — is authoritative there; agent never holds a token).
grep -Eq 'sudo -n /usr/local/bin/5dive _push_do' "$SRC/cmd_push.sh" \
  && ok_t "cmd_push delegates to root _push_do" \
  || bad_t "cmd_push delegates to root _push_do" "no _push_do handoff in cmd_push"
grep -Eq 'printf .* "\$ident" "\$repopath" "\$branch" "\$repo"' "$SRC/cmd_push.sh" \
  && ok_t "cmd_push passes params over stdin (not argv)" \
  || bad_t "cmd_push passes params over stdin" "params not piped to _push_do"

# --- DIVE-1460 input hardening: _push_do runs as ROOT on agent-controlled
# branch/url/repo-path. _push_validate_inputs must reject flag/refspec/traversal
# injection before any of them reaches git. (REPO from the scratch tree above.)
vin() { ( _push_validate_inputs "$1" "$2" "$3" ) 2>&1; }   # subshell: fail exits it
GHURL="https://github.com/5dive-ai/5dive.git"
# valid inputs -> pass, echoes canonical repo-path
out=$(vin "feature-ok" "$GHURL" "$REPO"); rc=$?
{ [[ $rc -eq 0 ]] && [[ "$out" == /* ]]; } \
  && ok_t "validate: clean inputs -> pass" || bad_t "validate: clean inputs -> pass" "rc=$rc :: $out"
# flag-like branch -> refuse
out=$(vin "--upload-pack=x" "$GHURL" "$REPO"); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "unsafe branch" <<<"$out"; } \
  && ok_t "validate: flag-like branch -> refuse" || bad_t "validate: flag-like branch -> refuse" "rc=$rc :: $out"
# '..' rev-range branch -> refuse
out=$(vin "a..b" "$GHURL" "$REPO"); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "'\.\.'" <<<"$out"; } \
  && ok_t "validate: '..' branch -> refuse" || bad_t "validate: '..' branch -> refuse" "rc=$rc :: $out"
# non-github / ssh url -> refuse
out=$(vin "feature-ok" "git@github.com:5dive-ai/5dive.git" "$REPO"); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "repo url must be" <<<"$out"; } \
  && ok_t "validate: ssh url -> refuse" || bad_t "validate: ssh url -> refuse" "rc=$rc :: $out"
# non-github host -> refuse
out=$(vin "feature-ok" "https://evil.example/5dive-ai/5dive.git" "$REPO"); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "repo url must be" <<<"$out"; } \
  && ok_t "validate: non-github host -> refuse" || bad_t "validate: non-github host -> refuse" "rc=$rc :: $out"
# non-existent repo-path -> refuse
out=$(vin "feature-ok" "$GHURL" "/no/such/path/xyz"); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "does not resolve" <<<"$out"; } \
  && ok_t "validate: bad repo-path -> refuse" || bad_t "validate: bad repo-path -> refuse" "rc=$rc :: $out"

echo "-----"
printf 'push_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
