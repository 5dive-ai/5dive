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
         lib/tasks_db.sh cmd_task.sh cmd_push.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=0
# Hermetic: point the App env at an absent path so the pre-flight never reads the
# box's real /etc/5dive/connectors/github-app.env. The committer to enforce is
# config-only (DIVE-1461): supplied per-test via GITHUB_APP_COMMIT_AUTHOR.
export GITHUB_APP_ENV="$TMP/no-app-env"
unset GITHUB_APP_COMMIT_AUTHOR
mkdir -p "$TASKS_DIR"
printf '%064d\n' 1496 > "$GATE_PROOF_KEY"
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
#           [answered_by] [routed_reviewer] [sign=1]
seed_task() {
  local answered_by="${6:-human:test}" reviewer="${7:-}" sign="${8:-1}" id sig
  db "INSERT INTO tasks(ident,project_key,title,status,assignee,kind,body,
         need_type,need_answered_at,need_answer,need_answered_by,
         need_answered_uid,routed_reviewer)
      VALUES($(sqlq "$1"),'dive',$(sqlq "t-$1"),'in_progress','dev','standard',
             $(sqlq "$2"),$(sqlq_or_null "$3"),$(sqlq_or_null "$4"),
             $(sqlq_or_null "$5"),$(sqlq_or_null "$answered_by"),1000,
             $(sqlq_or_null "$reviewer"));"
  if [[ -n "$4" && "$sign" == "1" ]]; then
    id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");")
    sig=$(_gate_closure_sign "$id" "$3" "$5" "$answered_by" "$4" 1000)
    db "UPDATE tasks SET need_answer_sig=$(sqlq "$sig") WHERE id=${id};"
  fi
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

# 8) DIVE-1462 branch binding: a --branch that DISAGREES with the task's declared
# branch is refused — the cleared gate binds to the task's own branch, so an agent
# can't cite one task's gate to push a different branch. (Was "override" pre-1462.)
seed_task DIVE-908 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-908 --branch=feature-ok --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "not the branch bound" <<<"$out"; } \
  && ok_t "branch binding: --branch != task branch -> refuse" || bad_t "branch binding: --branch != task branch -> refuse" "rc=$rc :: $out"

# 8b) DIVE-1462: --branch that MATCHES the task's declared branch is allowed
# (redundant but consistent) — binding is equality, not a ban on the flag.
seed_task DIVE-909 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-909 --branch=feature-ok --dry-run); rc=$?
{ [[ $rc -eq 0 ]] && grep -qi "would push feature-ok" <<<"$out"; } \
  && ok_t "branch binding: --branch == task branch -> pass" || bad_t "branch binding: --branch == task branch -> pass" "rc=$rc :: $out"

# 8c) DIVE-1462: a task with a cleared gate but NO declared branch cannot be
# pushed even with an explicit --branch — the gate has nothing to bind to.
seed_task DIVE-910 "no branch line here" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-910 --branch=feature-ok --dry-run); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "declares no branch" <<<"$out"; } \
  && ok_t "branch binding: cleared gate, no declared branch -> refuse" || bad_t "branch binding: cleared gate, no declared branch -> refuse" "rc=$rc :: $out"

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
authoritative_gate_check() {
  local i; i=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");")
  ( _push_gate_check "$i" "$1" 1 ) 2>&1
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

# DIVE-1496: a designated routed reviewer is a valid ship-gate approver. The
# authoritative path additionally demands the root-HMAC closure signature.
seed_task DIVE-923 "Branch: feature-ok" approval "2026-07-18 00:00:00" \
  "yes" "lead:main" "main"
out=$(authoritative_gate_check DIVE-923); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "gate predicate: signed routed reviewer -> pass" \
  || bad_t "gate predicate: signed routed reviewer -> pass" "rc=$rc :: $out"

out=$(authoritative_gate_check DIVE-907); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "gate predicate: signed human -> pass" \
  || bad_t "gate predicate: signed human -> pass" "rc=$rc :: $out"

seed_task DIVE-924 "Branch: feature-ok" decision "2026-07-18 00:00:00" \
  "yes" "auto:ttl" "main"
out=$(authoritative_gate_check DIVE-924); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "unauthorized provenance" <<<"$out"; } \
  && ok_t "gate predicate: auto-clear -> refuse" \
  || bad_t "gate predicate: auto-clear -> refuse" "rc=$rc :: $out"

# DIVE-1555: a signed lead clear whose CURRENT routed_reviewer no longer equals
# the clearer STILL passes. `lead:other` is stamped only when `agent-other` was the
# routed reviewer AT CLEAR TIME (and the closure is signed over it), so the routing
# being re-pointed to `main` afterwards must not strand the already-authorized push.
# (Pre-1555 this refused because the guard pinned to the CURRENT routed_reviewer.)
seed_task DIVE-925 "Branch: feature-ok" approval "2026-07-18 00:00:00" \
  "yes" "lead:other" "main"
out=$(authoritative_gate_check DIVE-925); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "gate predicate: lead-clear + routing changed after clear -> pass (DIVE-1555)" \
  || bad_t "gate predicate: lead-clear + routing changed after clear -> pass (DIVE-1555)" "rc=$rc :: $out"

# DIVE-1555 (Marcus repro): a correctly lead-cleared push whose routed_reviewer is
# now EMPTY (e.g. the DIVE-1437 T2-escalation NULLs it) is authorized on the signed
# `lead:*` provenance alone — the exact `unauthorized provenance main`/empty-reviewer
# failure this task fixes.
seed_task DIVE-1555A "Branch: feature-ok" approval "2026-07-18 00:00:00" \
  "yes" "lead:main" ""
out=$(authoritative_gate_check DIVE-1555A); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "gate predicate: lead-clear with empty routed_reviewer -> pass (DIVE-1555)" \
  || bad_t "gate predicate: lead-clear with empty routed_reviewer -> pass (DIVE-1555)" "rc=$rc :: $out"

# DIVE-1555 (negative): a BARE agent provenance ('main', no `lead:` prefix) — what a
# self-answered `decision` clear produces — is STILL refused even signed. The fix is
# to file the push gate as a lead-ROUTED approval (Part 1), not to accept bare-agent.
seed_task DIVE-1555B "Branch: feature-ok" decision "2026-07-18 00:00:00" \
  "yes" "main" ""
out=$(authoritative_gate_check DIVE-1555B); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "unauthorized provenance" <<<"$out"; } \
  && ok_t "gate predicate: bare-agent (decision-clear 'main') -> still refuse (DIVE-1555)" \
  || bad_t "gate predicate: bare-agent (decision-clear 'main') -> still refuse (DIVE-1555)" "rc=$rc :: $out"

seed_task DIVE-926 "Branch: feature-ok" approval "2026-07-18 00:00:00" \
  "yes" "human:test" "" 0
out=$(authoritative_gate_check DIVE-926); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "no valid signed closure" <<<"$out"; } \
  && ok_t "gate predicate: unsigned human closure -> refuse" \
  || bad_t "gate predicate: unsigned human closure -> refuse" "rc=$rc :: $out"

db "UPDATE tasks SET need_answer='changed after signing' WHERE ident='DIVE-923';"
out=$(authoritative_gate_check DIVE-923); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "no valid signed closure" <<<"$out"; } \
  && ok_t "gate predicate: tampered reviewer closure -> refuse" \
  || bad_t "gate predicate: tampered reviewer closure -> refuse" "rc=$rc :: $out"

# cmd_push hands the real push to the root helper over STDIN (the privileged work
# — gate/author/mint/push — is authoritative there; agent never holds a token).
grep -Eq 'sudo -n /usr/local/bin/5dive _push_do' "$SRC/cmd_push.sh" \
  && ok_t "cmd_push delegates to root _push_do" \
  || bad_t "cmd_push delegates to root _push_do" "no _push_do handoff in cmd_push"
grep -Eq 'printf .* "\$ident" "\$repopath" "\$branch" "\$repo"' "$SRC/cmd_push.sh" \
  && ok_t "cmd_push passes params over stdin (not argv)" \
  || bad_t "cmd_push passes params over stdin" "params not piped to _push_do"
grep -Fq '_push_gate_check "$id" "$ident" 1' "$SRC/cmd_push.sh" \
  && ok_t "root push requires signed gate closure" \
  || bad_t "root push requires signed gate closure" "authoritative flag missing"

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

# --- DIVE-1462 branch binding predicate: _push_bind_branch is the shared check
# called by BOTH cmd_push pre-flight and the root-only _push_do. Assert it
# directly (subshell: `fail` exits it).
bind() { # <ident> <branch> -> combined output; rc via subshell
  local i; i=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$1");")
  ( _push_bind_branch "$i" "$1" "$2" ) 2>&1
}
# matching branch (DIVE-907 declares feature-ok) -> pass
out=$(bind DIVE-907 feature-ok); rc=$?
[[ $rc -eq 0 ]] && ok_t "bind predicate: matching branch -> pass" || bad_t "bind predicate: matching branch -> pass" "rc=$rc :: $out"
# mismatching branch -> refuse
out=$(bind DIVE-907 some-other-branch); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "not the branch bound" <<<"$out"; } \
  && ok_t "bind predicate: mismatch -> refuse" || bad_t "bind predicate: mismatch -> refuse" "rc=$rc :: $out"
# task with no declared branch (DIVE-901 body 'no branch here') -> refuse
out=$(bind DIVE-901 feature-ok); rc=$?
{ [[ $rc -ne 0 ]] && grep -qi "declares no branch" <<<"$out"; } \
  && ok_t "bind predicate: no declared branch -> refuse" || bad_t "bind predicate: no declared branch -> refuse" "rc=$rc :: $out"

# --- DIVE-1462/STEER-4 builder-scoped sudoers: render_standard_sudoers emits the
# _push_do grant ONLY for a builder (can_push=1), never for a plain standard
# agent, and the builder form is exact-path (no arg wildcard) so it's sudo-rs
# safe. Also visudo-validate both renderings when visudo is available.
NOBUILD=$(render_standard_sudoers agent-qa 0)
grep -q '_push_do' <<<"$NOBUILD" \
  && bad_t "render: standard (can_push=0) omits _push_do" "unexpected _push_do in non-builder grant" \
  || ok_t "render: standard (can_push=0) omits _push_do"
grep -q 'agent _deliver' <<<"$NOBUILD" \
  && ok_t "render: standard keeps a2a grant" || bad_t "render: standard keeps a2a grant" "no _deliver line"

BUILD=$(render_standard_sudoers agent-bob 1)
grep -Eq '^agent-bob ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _push_do$' <<<"$BUILD" \
  && ok_t "render: builder (can_push=1) adds exact-path _push_do" \
  || bad_t "render: builder (can_push=1) adds exact-path _push_do" "$BUILD"
# no trailing arg wildcard on the _push_do line (sudo-rs rejects arg wildcards)
grep -E '_push_do' <<<"$BUILD" | grep -q '\*' \
  && bad_t "render: builder _push_do has no arg wildcard" "wildcard present -> not sudo-rs safe" \
  || ok_t "render: builder _push_do has no arg wildcard"
if command -v visudo >/dev/null 2>&1; then
  for cp in 0 1; do
    tf=$(mktemp); render_standard_sudoers agent-vv "$cp" > "$tf"
    visudo -cf "$tf" >/dev/null 2>&1 \
      && ok_t "render: can_push=$cp passes visudo -c" \
      || bad_t "render: can_push=$cp passes visudo -c" "visudo rejected the rendering"
    rm -f "$tf"
  done
else
  printf 'skip - visudo not available (rendering syntax not machine-validated here)\n'
fi

echo "-----"
printf 'push_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
