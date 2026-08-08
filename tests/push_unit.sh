#!/usr/bin/env bash
# TIER: nightly — 11.9s measured (DIVE-2525): does not fit the 300s PR core; the nightly sweep runs it.
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
#   - DIVE-1970: the target repo is resolved from the WORK TREE's own origin
#     (--repo > origin > the built-in constant), the fallback is announced, and
#     the author refusal names the repo it checked against
# Run: bash tests/push_unit.sh  (no root, no network — token mint never runs).
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

TMP="$(mktemp -d /tmp/push-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_push.sh \
         cmd_agent_create.sh; do
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
  # DIVE-2161. This repo's default branch is master, so `git fetch <url> main` —
  # what the author scan runs — has ALWAYS failed here ("couldn't find remote ref
  # main"). Pre-2161 that fell through to the unbounded fallback, which is the
  # defect: every author assertion in this file was graded through the broken
  # branch, and the harness header even documented it ("the fetch no-ops and it
  # scans the branch"). Give the fixture the remote-tracking main every real work
  # tree has, so those assertions rest on a real range bound instead. Verified
  # load-bearing by deletion: without this line, `set committer: non-matching
  # author -> refuse`, `author refusal names the repo it checked against` and the
  # two cached-bound arms below all stop grading (the scan correctly SKIPs).
  git update-ref refs/remotes/origin/main HEAD
) >/dev/null 2>&1

# run_push <ident> [args...] — capture combined output + rc from cmd_push, run
# inside the scratch repo (git checks need a work tree). --repo points at the
# local repo. Its default branch is master, so the author scan's `git fetch <url>
# main` fails and the scan falls to the CACHED refs/remotes/origin/main seeded
# above (DIVE-2161 — before that ref existed, this fell to the unbounded fallback
# that DIVE-2161 removed, i.e. these assertions were graded through the bug).
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

# 7b) INST-5 FAIL-CLOSED ON A MISSING PREDICATE. Extracting push's gate check into
# lib/broker.sh created a failure mode the inline code could not have: if the lib
# is not loaded the call is merely "command not found" (rc 127) and, as a bare
# statement, execution CONTINUES — CI caught exactly this, with push printing
# "would push ... (gate cleared)" for a task whose gate it never read. The control
# is arm 7 directly above: the SAME fixture, the SAME command, one predicate
# removed. If this pair ever stops differing, the guard has gone vacuous.
for _pred in broker_gate_check broker_bind_target; do
  out=$( cd "$REPO"; unset -f "$_pred"; cmd_push DIVE-907 --repo="file://$REPO" --dry-run 2>&1 ); rc=$?
  # The ACTION must not have happened — an rc alone would also pass on the wrong refusal.
  { [[ $rc -ne 0 ]] && ! grep -qi "would push" <<<"$out"; } \
    && ok_t "missing $_pred -> refuses, and no push is reported" \
    || bad_t "missing $_pred -> refuses, and no push is reported" "rc=$rc :: $out"
  # …and the refusal NAMES the absent predicate, so the operator is not left guessing.
  grep -q "$_pred" <<<"$out" \
    && ok_t "…and the refusal names '$_pred' as the missing predicate" \
    || bad_t "…and the refusal names '$_pred' as the missing predicate" "$out"
done
unset _pred

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
{ [[ $rc -ne 0 ]] && grep -qi "not cleared by an authority" <<<"$out"; } \
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
{ [[ $rc -ne 0 ]] && grep -qi "not cleared by an authority" <<<"$out"; } \
  && ok_t "gate predicate: bare-agent (decision-clear 'main') -> still refuse (DIVE-1555)" \
  || bad_t "gate predicate: bare-agent (decision-clear 'main') -> still refuse (DIVE-1555)" "rc=$rc :: $out"


# --- DIVE-2004: `lead:` is minted ONLY for approval|manual|access, so a DECISION
# gate cleared by its own designated reviewer could never authorize a push — and
# the refusal accused the reviewer who HAD cleared it. Push now accepts that case,
# but only when the claim is corroborated by the stored invoker uid: `gby ==
# reviewer` alone is caller-writable (`task answer --from=<reviewer>`).
# `_gate_agent_for_uid` is stubbed per-case so the harness stays hermetic — CI
# runners have no agent-* users, and the real getent lookup is exercised by the
# _gate_authenticated_actor cases below.
_uid_map=""
_gate_agent_for_uid() { [[ "${1:-}" == "1000" ]] && printf '%s' "$_uid_map" || printf ''; }

_uid_map="main"
seed_task DIVE-2004A "Branch: feature-ok" decision "2026-07-18 00:00:00" "yes" "main" "main"
out=$(authoritative_gate_check DIVE-2004A); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "decision cleared by its routed reviewer, uid corroborates -> pass (DIVE-2004)" \
  || bad_t "decision cleared by its routed reviewer, uid corroborates -> pass (DIVE-2004)" "rc=$rc :: $out"

# THE SPOOF: same row, but the recorded uid belongs to someone else — which is what
# `task answer --from=main` run by another agent produces. Refused, and the refusal
# must say WHY, or a real spoof is invisible.
_uid_map="dev"
out=$(authoritative_gate_check DIVE-2004A); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "IS this gate's routed reviewer" <<<"$out" \
    && grep -q "maps to 'dev'" <<<"$out"; } \
  && ok_t "decision + reviewer match but uid maps elsewhere -> refuse, naming the mismatch (DIVE-2004)" \
  || bad_t "decision + reviewer match but uid maps elsewhere -> refuse, naming the mismatch (DIVE-2004)" "rc=$rc :: $out"

# FAIL CLOSED: uid resolves to no agent at all -> refuse. Unidentifiable is not trusted.
_uid_map=""
out=$(authoritative_gate_check DIVE-2004A); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "maps to 'no agent'" <<<"$out"; } \
  && ok_t "decision + reviewer match but uid resolves to nobody -> refuse (fail closed, DIVE-2004)" \
  || bad_t "decision + reviewer match but uid resolves to nobody -> refuse (fail closed, DIVE-2004)" "rc=$rc :: $out"

# A decision answered by a DIFFERENT agent than the reviewer is still refused, and
# the message names the stamp it wanted rather than blaming the provenance value.
_uid_map="main"
seed_task DIVE-2004B "Branch: feature-ok" decision "2026-07-18 00:00:00" "yes" "qa" "main"
out=$(authoritative_gate_check DIVE-2004B); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "required 'human:\*', 'lead:main'" <<<"$out"; } \
  && ok_t "decision answered by a non-reviewer agent -> refuse, naming what was required (DIVE-2004)" \
  || bad_t "decision answered by a non-reviewer agent -> refuse, naming what was required (DIVE-2004)" "rc=$rc :: $out"

# An APPROVAL answered bare by its reviewer is NOT swept in by the new rule — the
# carve-out is scoped to `decision`, the type that had no path to `lead:` at all.
seed_task DIVE-2004C "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes" "main" "main"
out=$(authoritative_gate_check DIVE-2004C); rc=$?
[[ $rc -ne 0 ]] \
  && ok_t "approval with a BARE reviewer provenance -> still refuse (carve-out is decision-only, DIVE-2004)" \
  || bad_t "approval with a BARE reviewer provenance -> still refuse (carve-out is decision-only, DIVE-2004)" "rc=$rc :: $out"

unset -f _gate_agent_for_uid
# shellcheck source=/dev/null
source "$SRC/lib/actor.sh"  # restore the real helper for the cases below — the
                            # sealed derivation owns it since DIVE-2517; re-sourcing
                            # cmd_task.sh would leave it UNDEFINED and every arm below
                            # would grade an absent function rather than the real one.

# _gate_authenticated_actor: the kernel-enforced identity, EMPTY when unknown.
# Not `task_actor` — that returns --from verbatim, which is the whole bug.
out=$(_gate_authenticated_actor)
me=$(id -un)
if [[ "$me" == agent-* ]]; then
  [[ "$out" == "${me#agent-}" ]] \
    && ok_t "_gate_authenticated_actor resolves the real agent user (DIVE-2004)" \
    || bad_t "_gate_authenticated_actor resolves the real agent user (DIVE-2004)" "got '$out' as $me"
else
  [[ -z "$out" ]] \
    && ok_t "_gate_authenticated_actor is EMPTY for a non-agent, non-root caller (fail closed, DIVE-2004)" \
    || bad_t "_gate_authenticated_actor is EMPTY for a non-agent, non-root caller" "got '$out' as $me"
fi
# A forged --from must not move it: authentication ignores what the caller claims.
out=$(SUDO_UID=99999 _gate_authenticated_actor)
[[ "$out" == "$(_gate_authenticated_actor)" ]] \
  && ok_t "_gate_authenticated_actor ignores an unmappable SUDO_UID below EUID 0 (DIVE-2004)" \
  || bad_t "_gate_authenticated_actor ignores an unmappable SUDO_UID below EUID 0" "got '$out'"
[[ -z "$(_gate_agent_for_uid 'not-a-uid')" && -z "$(_gate_agent_for_uid '')" ]] \
  && ok_t "_gate_agent_for_uid rejects a non-numeric uid (DIVE-2004)" \
  || bad_t "_gate_agent_for_uid rejects a non-numeric uid" "got '$(_gate_agent_for_uid 'not-a-uid')'"
# THE PATH WHERE A 'DENY' COULD QUIETLY BECOME AN 'ALLOW': a uid that resolves to a
# REAL user who is simply not an agent. uid 0 exists on every box and is never an
# agent, so `root` must come back EMPTY, not `root` — an empty return is compared
# against `$reviewer` and can only ever refuse, whereas any non-empty leak here is
# one string-compare away from authorizing. Exercises the real getent lookup (the
# gate-check cases above stub this helper to stay hermetic).
[[ -z "$(_gate_agent_for_uid 0)" ]] \
  && ok_t "_gate_agent_for_uid maps a real NON-agent uid (0/root) to empty, not to its username (DIVE-2004)" \
  || bad_t "_gate_agent_for_uid must not return a non-agent username" "got '$(_gate_agent_for_uid 0)'"
# ...and an unassigned-but-numeric uid resolves to nothing at all.
[[ -z "$(_gate_agent_for_uid 999999)" ]] \
  && ok_t "_gate_agent_for_uid maps an unassigned uid to empty (fail closed, DIVE-2004)" \
  || bad_t "_gate_agent_for_uid unassigned uid" "got '$(_gate_agent_for_uid 999999)'"

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

# --- DIVE-1970: the target repo is resolved FROM THE WORK TREE, not defaulted to
# the CLI repo before the tree is even looked at. Every test above passes an
# explicit --repo, which is exactly why the bug survived: with no --repo, a push
# from a 5dive-frontend tree targeted 5dive-ai/5dive and then blamed the AUTHOR.

# _push_repo_from_worktree: normalizes the three github remote spellings, and
# stays EMPTY (-> caller falls back + says so) for anything it cannot vouch for.
wt_repo_case() {  # wt_repo_case <label> <origin-url-or-empty> <expected>
  local d; d=$(mktemp -d "$TMP/wt.XXXXXX")
  ( cd "$d"; git init -q; [[ -n "$2" ]] && git remote add origin "$2"; ) >/dev/null 2>&1
  local got; got=$(_push_repo_from_worktree "$d")
  [[ "$got" == "$3" ]] \
    && ok_t "worktree origin: $1" || bad_t "worktree origin: $1" "got '$got' want '$3'"
}
wt_repo_case "https -> normalized"  "https://github.com/lodar/5dive-frontend.git" "https://github.com/lodar/5dive-frontend.git"
wt_repo_case "https, no .git"       "https://github.com/lodar/5dive-api"          "https://github.com/lodar/5dive-api.git"
wt_repo_case "scp-style git@"       "git@github.com:5dive-ai/5dive.git"           "https://github.com/5dive-ai/5dive.git"
wt_repo_case "ssh:// url"           "ssh://git@github.com/lodar/5dive-api.git"    "https://github.com/lodar/5dive-api.git"
wt_repo_case "non-github remote -> empty" "file:///tmp/nope"                      ""
wt_repo_case "other forge -> empty" "https://gitlab.com/lodar/x.git"              ""
wt_repo_case "no origin -> empty"   ""                                            ""

# A second scratch repo that KNOWS which repo it belongs to (origin = frontend).
# No committer is configured for these, so the author scan is a no-op and nothing
# here touches the network.
REPO2="$TMP/repo2"; mkdir -p "$REPO2"
( cd "$REPO2"
  git init -q
  git config user.name test; git config user.email test@example.test
  git commit -q --allow-empty -m "base" --author="$AUTHOR"
  git checkout -q -b feature-fe
  git commit -q --allow-empty -m "work" --author="$AUTHOR"
  git remote add origin "https://github.com/lodar/5dive-frontend.git"
) >/dev/null 2>&1

# bare `5dive push` in the frontend tree -> the FRONTEND repo, not the CLI repo.
seed_task DIVE-970 "Branch: feature-fe" approval "2026-07-18 00:00:00" "yes ship it"
out=$( cd "$REPO2"; cmd_push DIVE-970 --dry-run 2>&1 ); rc=$?
{ [[ $rc -eq 0 ]] && grep -q "lodar/5dive-frontend" <<<"$out" && ! grep -q "5dive-ai/5dive" <<<"$out"; } \
  && ok_t "no --repo -> target resolved from the work tree's origin" \
  || bad_t "no --repo -> target resolved from the work tree's origin" "rc=$rc :: $out"
grep -q "work tree's origin" <<<"$out" \
  && ok_t "dry-run names WHERE the target came from" \
  || bad_t "dry-run names WHERE the target came from" "$out"

# a tree with no github origin still works — via the constant, said OUT LOUD.
seed_task DIVE-971 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes"
out=$( cd "$REPO"; cmd_push DIVE-971 --dry-run 2>&1 ); rc=$?
{ [[ $rc -eq 0 ]] && grep -q "5dive-ai/5dive" <<<"$out" \
    && grep -qi "no github.com 'origin'" <<<"$out"; } \
  && ok_t "no github origin -> constant fallback, announced" \
  || bad_t "no github origin -> constant fallback, announced" "rc=$rc :: $out"

# an explicit --repo still wins, and a cross-repo push is called out.
seed_task DIVE-972 "Branch: feature-fe" approval "2026-07-18 00:00:00" "yes"
out=$( cd "$REPO2"; cmd_push DIVE-972 --repo="https://github.com/5dive-ai/5dive.git" --dry-run 2>&1 ); rc=$?
{ [[ $rc -eq 0 ]] && grep -q "would push feature-fe@[0-9a-f]* to 5dive-ai/5dive" <<<"$out"; } \
  && ok_t "--repo still wins over the work tree" \
  || bad_t "--repo still wins over the work tree" "rc=$rc :: $out"
grep -qi "but this work tree's origin is lodar/5dive-frontend" <<<"$out" \
  && ok_t "--repo disagreeing with the tree warns" \
  || bad_t "--repo disagreeing with the tree warns" "$out"

# the author-scan refusal NAMES the repo it checked against + how wide it looked.
# That is the whole point: dev3 read ~18 unrelated commits as "my branch is dirty".
out=$( cd "$REPO"; GITHUB_APP_COMMIT_AUTHOR="$AUTHOR" cmd_push DIVE-906 --repo="file://$REPO" --dry-run 2>&1 ); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "author check FAILED against file://$REPO" <<<"$out" \
    && grep -qi "target resolved from --repo" <<<"$out" \
    && grep -qi "check the TARGET REPO first" <<<"$out"; } \
  && ok_t "author refusal names the repo it checked against" \
  || bad_t "author refusal names the repo it checked against" "rc=$rc :: $out"

# --- DIVE-2161: an UNRESOLVABLE range bound must not render as a measurement.
# dev2 pushed a one-commit, correctly-authored branch and got "author check
# FAILED ... UNBOUNDED" plus hundreds of pre-policy commits listed as violations.
# The tool could not fetch the target's main, silently widened the range to the
# branch's entire history, and graded that. These arms fix the shape: the bound is
# resolved, degraded to a cached one that SAYS it may be stale, or refused.
#
# REPO3 reproduces it: main carries pre-policy commits authored by someone else,
# the feature branch carries ONE correctly-authored commit. An unbounded scan
# reports the pre-policy commits; a bounded one reports nothing.
REPO3="$TMP/repo3"; mkdir -p "$REPO3"
( cd "$REPO3"
  git init -q -b main
  git config user.name test; git config user.email test@example.test
  for i in 1 2 3; do git commit -q --allow-empty -m "pre-policy $i" --author="$OTHER"; done
  git checkout -q -b feature-clean
  git commit -q --allow-empty -m "the one real commit" --author="$AUTHOR"
  git checkout -q -b feature-dirty main
  git commit -q --allow-empty -m "genuinely wrong author" --author="$OTHER"
) >/dev/null 2>&1
PREPOLICY_SHA=$( cd "$REPO3" && git rev-parse main )
UNFETCHABLE="file://$TMP/there-is-no-repo-here.git"   # fails fast, no network
cache_on()  { ( cd "$REPO3" && git update-ref refs/remotes/origin/main main ) >/dev/null 2>&1; }
cache_off() { ( cd "$REPO3" && git update-ref -d refs/remotes/origin/main ) >/dev/null 2>&1; }
# run the scan in a subshell so its `fail` exits the subshell, not the harness
scan3() { # <branch> <repo-url> <mode> -> combined output; rc from the subshell
  ( _push_author_scan "$REPO3" "$2" "$1" "$AUTHOR" "a test" "$3" ) 2>&1
}

cache_off
out=$(scan3 feature-clean "$UNFETCHABLE" authoritative); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "author check COULD NOT RUN" <<<"$out" \
    && grep -q "could not determine WHICH commits" <<<"$out" \
    && ! grep -q "author check FAILED" <<<"$out" \
    && ! grep -q "$PREPOLICY_SHA" <<<"$out"; } \
  && ok_t "2161: no bound, authoritative -> REFUSE, and lists no commits" \
  || bad_t "2161: no bound, authoritative -> REFUSE, and lists no commits" "rc=$rc :: $out"

# the refusal must name WHY the bound is missing — "I cannot measure" is only
# actionable with the cause attached.
{ grep -q "fetching that repo's main failed (" <<<"$out" \
    && grep -Eq "not found, or is not visible|git said:" <<<"$out" \
    && grep -q "no cached refs/remotes/origin/main" <<<"$out"; } \
  && ok_t "2161: the refusal names the CAUSE of the missing bound" \
  || bad_t "2161: the refusal names the CAUSE of the missing bound" "$out"

out=$(scan3 feature-clean "$UNFETCHABLE" preflight); rc=$?
{ [[ $rc -eq 0 ]] && grep -q "author check SKIPPED here" <<<"$out" \
    && grep -q "re-run authoritatively" <<<"$out"; } \
  && ok_t "2161: no bound, preflight -> SKIP with a reason (delegated push has no creds)" \
  || bad_t "2161: no bound, preflight -> SKIP with a reason" "rc=$rc :: $out"

# THE REPORTED BUG. Fetch impossible, cached origin/main present, branch clean:
# pre-fix this printed the three pre-policy commits as author violations.
cache_on
out=$(scan3 feature-clean "$UNFETCHABLE" authoritative); rc=$?
{ [[ $rc -eq 0 ]] && ! grep -q "$PREPOLICY_SHA" <<<"$out"; } \
  && ok_t "2161: cached bound -> a clean branch PASSES (no phantom pre-policy offenders)" \
  || bad_t "2161: cached bound -> a clean branch PASSES" "rc=$rc :: $out"
grep -Eq "cached refs/remotes/origin/main|could not fetch" <<<"$out" \
  && ok_t "2161: the cached bound is announced, not silent" \
  || bad_t "2161: the cached bound is announced, not silent" "$out"

# ...and a cached bound still CATCHES a genuinely mis-authored commit — exactly
# one, the branch's own, not the pre-policy history behind it.
out=$(scan3 feature-dirty "$UNFETCHABLE" authoritative); rc=$?
n=$(grep -cE "^  [0-9a-f]{40} " <<<"$out") || n=0
{ [[ $rc -ne 0 ]] && grep -q "author check FAILED" <<<"$out" && [[ "$n" -eq 1 ]] \
    && grep -q "MAY BE STALE" <<<"$out"; } \
  && ok_t "2161: cached bound catches a real bad author — exactly 1 offender, flagged stale" \
  || bad_t "2161: cached bound catches a real bad author — exactly 1 offender, flagged stale" "rc=$rc n=$n :: $out"

# a FRESH fetch still bounds authoritatively and says so (no stale caveat).
out=$(scan3 feature-dirty "file://$REPO3" authoritative); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "not already on that repo's main" <<<"$out" \
    && ! grep -q "MAY BE STALE" <<<"$out"; } \
  && ok_t "2161: a fetchable remote still gives the fresh, authoritative bound" \
  || bad_t "2161: a fetchable remote still gives the fresh, authoritative bound" "rc=$rc :: $out"

# --- DIVE-2161 MUTATION ARMS. A harness that only exercises the resolvable path
# passes forever while this defect stands (the ticket says so explicitly). Each
# arm re-introduces one piece of the pre-fix behaviour into the SHIPPED source and
# demands the corresponding assertion goes red. The sed is verified to have
# actually changed the file — a mutation that did not land greens like a pass.
mutate() { # <name> <sed-expr> -> path to the mutated source, or "" if sed no-op'd
  local f="$TMP/mut-$1.sh"
  sed "$2" "$SRC/cmd_push.sh" > "$f"
  cmp -s "$f" "$SRC/cmd_push.sh" && { printf ''; return 1; }
  printf '%s' "$f"
}
mut_scan3() { # <mutated-src> <branch> <repo-url> <mode>
  ( source "$1" >/dev/null 2>&1; _push_author_scan "$REPO3" "$3" "$2" "$AUTHOR" "a test" "$4" ) 2>&1
}

# --- main's review note. The two DIVE-1461 author assertions near the top now
# rest on the CACHED bound this fixture gained (`update-ref` above): without a
# remote-tracking main the pre-flight would correctly SKIP and those assertions
# would keep printing ok while grading nothing. Grade them here so nobody later
# has to wonder whether they still red. Forced onto the cached rung with an
# unfetchable --repo — otherwise whether an ambient fetch of the constant target
# happens to succeed on the box decides which bound they use.
seed_task DIVE-961 "Branch: feature-badauthor" approval "2026-07-18 00:00:00" "yes"
seed_task DIVE-962 "Branch: feature-ok"        approval "2026-07-18 00:00:00" "yes"
cached_push() { ( cd "$REPO"; GITHUB_APP_COMMIT_AUTHOR="$AUTHOR" cmd_push "$1" --repo="$UNFETCHABLE" --dry-run ) 2>&1; }
mut_cached_push() { ( source "$1" >/dev/null 2>&1; cd "$REPO"; GITHUB_APP_COMMIT_AUTHOR="$AUTHOR" cmd_push "$2" --repo="$UNFETCHABLE" --dry-run ) 2>&1; }

out=$(cached_push DIVE-961); rc=$?
{ [[ $rc -ne 0 ]] && grep -q "author check FAILED" <<<"$out"; } \
  && ok_t "2161: on the cached bound a bad author is still REFUSED (the 1461 assertion still grades)" \
  || bad_t "2161: on the cached bound a bad author is still REFUSED" "rc=$rc :: $out"

out=$(cached_push DIVE-962); rc=$?
{ [[ $rc -eq 0 ]] && grep -q "CACHED bound, may be stale" <<<"$out"; } \
  && ok_t "2161: a clean branch passes on the cached bound, and the dry-run SAYS the bound was cached" \
  || bad_t "2161: a clean branch passes on the cached bound, and the dry-run SAYS the bound was cached" "rc=$rc :: $out"

# M0 — take the cached bound away and the refusal above stops being produced:
# proof that it is the cached rung doing the grading, not an ambient fetch.
if M0=$(mutate m0 's|^    for cref in refs/remotes/origin/main refs/remotes/origin/master; do|    for cref in refs/remotes/__no_such_ref__; do|'); then
  out=$(mut_cached_push "$M0" DIVE-961); rc=$?
  { [[ $rc -eq 0 ]] && ! grep -q "author check FAILED" <<<"$out" \
      && grep -q "author check SKIPPED here" <<<"$out"; } \
    && ok_t "2161-MUT: without the cached bound the 1461 author assertion stops grading (arm is live)" \
    || bad_t "2161-MUT: without the cached bound the 1461 author assertion stops grading" "rc=$rc :: $out"
else
  bad_t "2161-MUT: cached-bound grade of the 1461 assertions" "sed did not change cmd_push.sh — anchor moved"
fi

# M1 — the refusal widens to the whole history again (the exact pre-fix line).
if M1=$(mutate m1 's|^      fail "\$E_GENERIC" "author check COULD NOT RUN.*|      rangespec="refs/heads/${branch}"; scope="MUTATED: the pre-2161 unbounded fallback"|'); then
  cache_off
  out=$(mut_scan3 "$M1" feature-clean "$UNFETCHABLE" authoritative); rc=$?
  { [[ $rc -ne 0 ]] && grep -q "$PREPOLICY_SHA" <<<"$out"; } \
    && ok_t "2161-MUT: re-widening the range makes the phantom list come back (arm is live)" \
    || bad_t "2161-MUT: re-widening the range makes the phantom list come back" "the mutation did not reproduce the bug — the refusal arm may not be what is protecting us. rc=$rc :: $out"
else
  bad_t "2161-MUT: widen-the-range mutation" "sed did not change cmd_push.sh — the anchor moved, mutation NOT applied"
fi

# M2 — drop the cached-bound fallback: the reported case stops passing.
if M2=$(mutate m2 's|^    for cref in refs/remotes/origin/main refs/remotes/origin/master; do|    for cref in refs/remotes/__no_such_ref__; do|'); then
  cache_on
  out=$(mut_scan3 "$M2" feature-clean "$UNFETCHABLE" authoritative); rc=$?
  [[ $rc -ne 0 ]] \
    && ok_t "2161-MUT: without the cached fallback the clean branch is refused (arm is live)" \
    || bad_t "2161-MUT: without the cached fallback the clean branch is refused" "rc=$rc :: $out"
else
  bad_t "2161-MUT: drop-cached-fallback mutation" "sed did not change cmd_push.sh — anchor moved"
fi

# M3 — remove the preflight escape: a credential-less delegated push starts failing.
if M3=$(mutate m3 's|^      \[\[ "\$mode" == preflight \]\] && { warn |      [[ "$mode" == "__never__" ]] \&\& { warn |'); then
  cache_off
  out=$(mut_scan3 "$M3" feature-clean "$UNFETCHABLE" preflight); rc=$?
  [[ $rc -ne 0 ]] \
    && ok_t "2161-MUT: without the preflight skip a credential-less pre-check hard-fails (arm is live)" \
    || bad_t "2161-MUT: without the preflight skip a credential-less pre-check hard-fails" "rc=$rc :: $out"
else
  bad_t "2161-MUT: drop-preflight-skip mutation" "sed did not change cmd_push.sh — anchor moved"
fi
cache_off

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

# --- gh#250: the minted token's permission set must follow the branch --------
# contents:write alone cannot push .github/workflows/*; GitHub refuses and the
# error blames the App's grants rather than this token's, so the operator
# chases the wrong thing. _push_touches_workflows decides, and these grade the
# decision (no token is ever minted here — the predicate is pure git).
WFREPO="$TMP/wfrepo"; mkdir -p "$WFREPO"
( cd "$WFREPO"
  git init -q -b main
  git config user.name test; git config user.email test@example.test
  mkdir -p .github/workflows src
  printf 'name: ci\n' > .github/workflows/ci.yml
  printf 'x\n' > src/a.txt
  git add -A; git commit -q -m base
  git checkout -q -b code-only;  printf 'y\n' >> src/a.txt;                git commit -qam "code"
  git checkout -q main
  git checkout -q -b touches-ci; printf '# edit\n' >> .github/workflows/ci.yml; git commit -qam "ci"
  git checkout -q main
) >/dev/null 2>&1

wf() { ( _push_touches_workflows "$WFREPO" "$WFREPO" "$1" ) 2>/dev/null; }

[[ "$(wf code-only)"  == "no"  ]] \
  && ok_t "workflows scope: a code-only branch keeps contents:write alone" \
  || bad_t "workflows scope: code-only branch" "got '$(wf code-only)', want 'no'"
[[ "$(wf touches-ci)" == "yes" ]] \
  && ok_t "workflows scope: a branch touching .github/workflows/ needs workflows:write" \
  || bad_t "workflows scope: workflow-touching branch" "got '$(wf touches-ci)', want 'yes'"
# Neither a live NOR a cached bound -> no range to diff. Must be 'unknown' (which
# the caller treats as "include the permission and say so"), never a silent 'no' —
# a false 'no' is a push that fails AFTER the human cleared the gate. WFREPO has no
# remote-tracking refs, so this arm exercises the both-bounds-missing path.
[[ "$( ( _push_touches_workflows "$WFREPO" "/nonexistent/remote.git" touches-ci ) 2>/dev/null )" == "unknown" ]] \
  && ok_t "workflows scope: no live AND no cached bound -> unknown (fails open, loudly)" \
  || bad_t "workflows scope: no live and no cached bound" "want 'unknown'"

# DIVE-2547: the live fetch is UNAUTHENTICATED, so on a PRIVATE repo it can never
# succeed and the old code demanded workflows:write on every push forever. With a
# cached remote-tracking ref present the probe must fall back to it and MEASURE,
# rather than escalating the token. Same fixture, plus refs/remotes/origin/main.
WFCACHED="$TMP/wfcached"
cp -r "$WFREPO" "$WFCACHED" 2>/dev/null
( cd "$WFCACHED" && git update-ref refs/remotes/origin/main refs/heads/main ) >/dev/null 2>&1
wfc() { ( _push_touches_workflows "$WFCACHED" "/nonexistent/remote.git" "$1" ) 2>/dev/null; }

[[ "$(wfc code-only)" == "no" ]] \
  && ok_t "workflows scope: unreachable remote + cached ref -> measures 'no', does NOT escalate" \
  || bad_t "workflows scope: cached-ref fallback on a code-only branch" "got '$(wfc code-only)', want 'no'"
[[ "$(wfc touches-ci)" == "yes" ]] \
  && ok_t "workflows scope: cached-ref fallback still catches a workflow-touching branch" \
  || bad_t "workflows scope: cached-ref fallback on a ci branch" "got '$(wfc touches-ci)', want 'yes'"
# The degradation must SAY it degraded (DIVE-2161: a cached bound that hides its
# staleness is the failure this whole class is about).
( _push_touches_workflows "$WFCACHED" "/nonexistent/remote.git" code-only ) 2>&1 >/dev/null \
  | grep -q 'may be stale' \
  && ok_t "workflows scope: the cached-bound fallback names its own staleness on stderr" \
  || bad_t "workflows scope: cached fallback is silent" "no staleness warning emitted"
# And the caller wires it: the wide body is reachable only when not 'no'.
grep -q 'workflows:"write"' "$SRC/cmd_push.sh" \
  && ok_t "workflows scope: _push_do can request workflows:write" \
  || bad_t "workflows scope: _push_do can request workflows:write" "no workflows grant in the token body"

# --- DIVE-2563: the installation is resolved PER REPO, not pinned -------------
# A GitHub App gets one installation per ACCOUNT it is installed on, and the token
# exchange refuses any repo outside the installation it is addressed to. A single
# pinned GITHUB_APP_INSTALLATION_ID therefore works only while the whole fleet
# lives in one account — which stopped being true the moment a repo sat under a
# different owner. Measured 2026-08-03: 5dive-ai/5dive resolves to the pinned
# installation; lodar/5dive-api and lodar/5dive-frontend resolve to none at all.
grep -q 'repos/\${slug}/installation' "$SRC/cmd_push.sh" \
  && ok_t "installation: _push_do asks GitHub which installation owns the repo" \
  || bad_t "installation: per-repo lookup" "no /repos/<slug>/installation call before the mint"

# The lookup needs the owner/repo slug, and it runs BEFORE the mint. The first cut
# of this fix referenced \$slug 40 lines above its assignment, which expands to
# empty and silently queries /repos//installation — a lookup that cannot fail
# loudly. Pin the ordering, not just the presence.
_slug_ln=$(grep -n '^  slug=\$(_push_repo_slug "\$repourl")' "$SRC/cmd_push.sh" | head -1 | cut -d: -f1) || _slug_ln=""
_inst_ln=$(grep -n 'repos/\${slug}/installation' "$SRC/cmd_push.sh" | head -1 | cut -d: -f1) || _inst_ln=""
[[ -n "$_slug_ln" && -n "$_inst_ln" && "$_slug_ln" -lt "$_inst_ln" ]] \
  && ok_t "installation: slug is assigned BEFORE the installation lookup reads it" \
  || bad_t "installation: slug assigned before use" "slug at line ${_slug_ln:-none}, lookup at ${_inst_ln:-none}"

# A refusal must carry what GitHub actually said. `curl -fsS` prints nothing on a
# 4xx, so the old code rendered "There is at least one repository that does not
# exist or is not accessible to the parent installation" as "installation token
# exchange failed" and the operator had to re-run the call by hand to find out.
grep -q "message // empty" "$SRC/cmd_push.sh" \
  && ok_t "installation: a failed mint surfaces GitHub's own message" \
  || bad_t "installation: mint failure names the cause" "the API error body is discarded"

# === DIVE-2566: BEHAVIOURAL REPLACEMENTS FOR THE TWO PRESENCE GREPS ABOVE =====
#
# olivia mutation-graded the three DIVE-2563 arms at c728b00 and found two of them
# survive a mutation that RESTORES the exact defect they name:
#   MUT A  replace `inst="$_inst_for_repo"` with `:` — the installation is looked up,
#          announced on stderr, and never ADOPTED, so the mint still POSTs to the
#          pinned id and every lodar/* repo 422s exactly as before DIVE-2563.
#          push_unit stayed 94/0, because the arm only greps that the LOOKUP EXISTS.
#   MUT B  strip `${_why}` from the mint's fail(), leaving the `message // empty`
#          extraction intact but discarding it before the operator sees it.
#          push_unit stayed 94/0, because the arm greps that the body is PARSED.
#
# Both are this row's own lesson one layer up: DIVE-2566 exists because a fallback
# that was PRESENT in the source was UNREACHABLE at runtime while the suite stayed
# green. Presence-of-string is not reachability, and that fix was applied only to the
# guard. These two arms EXECUTE the source's own lines instead of reading them.

# --- ARM A: the mint URL must carry the RESOLVED id, not the pinned one -------
# ASSERT THE ANCHORS FIRST. If the extraction misses, the arm must FAIL LOUDLY
# rather than silently grade an empty string — an arm that cannot find its subject
# is exactly the vacuous pass this whole ticket is about.
_a_start=$(grep -n 'if \[\[ -n "\$_inst_for_repo" && "\$_inst_for_repo" != "\$inst" \]\]' "$SRC/cmd_push.sh" | head -1 | cut -d: -f1) || _a_start=""
_a_end=$(awk -v s="${_a_start:-0}" 'NR>s && /^  fi$/ {print NR; exit}' "$SRC/cmd_push.sh")
_a_url=$(grep -c 'app/installations/\${inst}/access_tokens' "$SRC/cmd_push.sh") || _a_url=0
if [[ -z "$_a_start" || -z "$_a_end" || "$_a_url" -eq 0 ]]; then
  bad_t "installation: ARM A could not locate its subject (DIVE-2566)" \
        "adoption block ${_a_start:-none}..${_a_end:-none}, mint-URL hits ${_a_url} — the arm graded nothing"
else
  # Run the SOURCE's own adoption block with a resolved id that differs from the
  # pinned one, then build the mint URL the way the source builds it.
  _a_out=$(bash -c '
set -euo pipefail
inst=147419836; _inst_for_repo=999000111; slug=lodar/5dive-api
'"$(sed -n "${_a_start},${_a_end}p" "$SRC/cmd_push.sh")"'
printf "%s\n" "https://api.github.com/app/installations/${inst}/access_tokens"
' 2>/dev/null)
  if [[ "$_a_out" == *"/app/installations/999000111/access_tokens"* ]]; then
    ok_t "installation: the mint URL carries the RESOLVED installation, not the pinned id (DIVE-2566, kills MUT A)"
  else
    bad_t "installation: resolved id reaches the mint (DIVE-2566)" \
          "mint URL came out as '${_a_out:-<block died>}' — the lookup's answer is announced but never adopted, so every repo outside the pinned installation still 4xxs"
  fi
fi

# --- ARM B: a 404 body's own message must REACH the operator ------------------
# Extracts the mint's failure block and runs it with a real GitHub 404 body, with
# `fail` stubbed to capture what the operator would actually see. Greping that the
# body is PARSED cannot tell that apart from a fail() that drops it on the floor.
_b_start=$(grep -n 'if \[\[ -z "\$tok" \]\]; then' "$SRC/cmd_push.sh" | head -1 | cut -d: -f1) || _b_start=""
_b_end=$(awk -v s="${_b_start:-0}" 'NR>s && /^  fi$/ {print NR; exit}' "$SRC/cmd_push.sh")
if [[ -z "$_b_start" || -z "$_b_end" ]]; then
  bad_t "installation: ARM B could not locate its subject (DIVE-2566)" \
        "failure block ${_b_start:-none}..${_b_end:-none} — the arm graded nothing"
else
  _b_msg='Not Found'
  _b_out=$(bash -c '
set -uo pipefail
E_AUTH_REQUIRED=6; E_GENERIC=1
fail() { printf "FAILCODE:%s\nFAILMSG:%s\n" "$1" "$2"; exit 0; }
tok=""; slug=lodar/5dive-api; inst=147419836
_tokresp='"'"'{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}'"'"'
'"$(sed -n "${_b_start},${_b_end}p" "$SRC/cmd_push.sh")"'
' 2>/dev/null)
  if [[ "$_b_out" == *"FAILMSG:"* && "$_b_out" == *"$_b_msg"* ]]; then
    ok_t "installation: GitHub's own 404 message REACHES the operator's failure text (DIVE-2566, kills MUT B)"
  else
    bad_t "installation: mint failure carries the remote's message (DIVE-2566)" \
          "operator would have seen '${_b_out:-<block died>}' — the body is parsed but discarded before it is shown, which is the state that cost a builder an hour on DIVE-1560"
  fi
  # ...and the code must be OURS, not curl's rc=22 and not the E_GENERIC catch-all.
  # This is the row's originating symptom: a number from another namespace.
  if [[ "$_b_out" == *"no installation covering"* ]]; then
    ok_t "installation: a 404 mint names the NO-INSTALLATION cause specifically, not a generic failure (DIVE-2566)"
  else
    bad_t "installation: 404 names the no-installation cause (DIVE-2566)" \
          "got '${_b_out:-<block died>}' — the one cause an operator cannot fix by retrying must say so"
  fi
  # THE ROW'S ORIGINATING SYMPTOM was an exit code from someone else's namespace:
  # curl's rc=22 leaking through set -euo pipefail, which is not a 5dive code at all.
  # E_GENERIC would technically be "ours" and still tells the operator nothing, so
  # the arm pins the CLASS and not merely the fact that we called fail().
  if [[ "$_b_out" == *"FAILCODE:${E_AUTH_REQUIRED}"* ]]; then
    ok_t "installation: the mint failure exits E_AUTH_REQUIRED, not the E_GENERIC catch-all (DIVE-2566)"
  else
    bad_t "installation: mint failure carries a meaningful E_ code (DIVE-2566)" \
          "got '${_b_out:-<block died>}' — expected FAILCODE:${E_AUTH_REQUIRED}; rc=22 from curl and a generic 1 are equally unactionable"
  fi
fi


# DIVE-2566: the installation lookup is a probe that is ALLOWED to fail — a repo
# outside every installation 404s it, which is precisely the case the pinned-id
# fallback exists for. `curl -fsS` exits 22 on HTTP>=400, `pipefail` promotes it
# through the `| jq`, and a bare `var=$(...)` under `set -e` kills the push, so the
# fallback branch was UNREACHABLE in its own motivating case (delegated push to any
# lodar/* repo died with a bare rc=22 and no message).
#
# STATIC ARM: the assignment must handle its own failure.
grep -qE "jq -r '\.id // empty'\) \|\| _inst_for_repo=" "$SRC/cmd_push.sh" \
  && ok_t "installation: the lookup assignment cannot fail the script (DIVE-2566)" \
  || bad_t "installation: lookup is guarded" "the \$( ) assignment is unguarded — under set -e + pipefail a 404 kills the push and the fallback below is dead code"

# BEHAVIOURAL ARM. The grep above only proves a STRING is present, so this one runs
# the shape the SOURCE actually carries under a real `set -euo pipefail` against a
# command that exits non-zero. Deriving the tail FROM cmd_push.sh is the whole point:
# an inline guarded-vs-unguarded demo would pass no matter what the source says, and
# a mutation to the source would leave it green. (It did, on the first cut of this
# arm — caught by mutation-grading the guard away and finding only the static arm
# reddened.) The unguarded control runs alongside it so the arm cannot pass by the
# probe simply never failing.
_probe() {  # $1 = tail to append to the assignment
  bash -c 'set -euo pipefail
f() {
  local _inst_for_repo
  _inst_for_repo=$(sh -c "exit 22" | jq -r ".id // empty" 2>/dev/null)'"$1"'
  echo "FALLBACK-REACHED:[${_inst_for_repo}]"
}
f' 2>/dev/null
}
_src_tail=""
grep -qE "jq -r '\.id // empty'\) \|\| _inst_for_repo=" "$SRC/cmd_push.sh" && _src_tail=' || _inst_for_repo=""'
_src_out="$(_probe "$_src_tail")"          # the shape cmd_push.sh actually has
_unguarded_out="$(_probe "")"              # negative control: no guard at all
if [[ "$_src_out" == "FALLBACK-REACHED:[]" && -z "$_unguarded_out" ]]; then
  ok_t "installation: the SOURCE's assignment shape reaches the fallback under set -e (DIVE-2566)"
else
  bad_t "installation: source shape survives a failing lookup (DIVE-2566)" \
        "source shape gave '${_src_out:-<died before the fallback>}', unguarded control gave '${_unguarded_out:-<died, correct>}' — the source's own shape must reach the fallback AND the unguarded control must not"
fi

# ---------------------------------------------------------------------------
# DIVE-2801: a step must not report a verdict it did not compute.
#
# --dry-run runs the agent-side preflight (require_sig=0); the real push runs the
# root executor (require_sig=1). A flat "gate cleared" therefore answers for the
# SIGNATURE check that never ran here — the leg most likely to refuse, because a
# seat whose sudo grant does not reach `gate-proof sign` stores an unsigned
# closure while the answer reports OK (DIVE-2760).
#
# The arms are deliberately PAIRED. Asserting only the warning would also pass
# for a fix that always warns, which is worthless: a warning on every push is
# noise, and noise is how this stayed invisible. So the positive control asserts
# the honest case stays quiet and asserts the refusal wording is ABSENT.

# 20) UNSIGNED closure -> predict the refusal rather than preview a push that
#     cannot happen. Absence of a signature is readable at preflight without the
#     root key, so this is a prediction, not a disclaimer.
seed_task DIVE-990 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes" "lead:scoped" "" 0
out=$(run_push DIVE-990 --dry-run); rc=$?
{ [[ $rc -eq 0 ]] \
    && grep -qi "would NOT push" <<<"$out" \
    && grep -qi "WILL refuse" <<<"$out"; } \
  && ok_t "unsigned closure -> dry run predicts the push-time refusal (DIVE-2801)" \
  || bad_t "unsigned closure -> dry run predicts the push-time refusal (DIVE-2801)" "rc=$rc :: $out"

# 20b) the machine-readable surface must carry it too — a script reading `gate`
#      would otherwise still see "cleared" for a push that cannot happen.
out=$( cd "$REPO"; JSON_MODE=1 cmd_push DIVE-990 --repo="file://$REPO" --dry-run 2>&1 ); rc=$?
{ [[ $rc -eq 0 ]] \
    && grep -q '"gate":"authority-ok-signature-absent"' <<<"$out" \
    && grep -q '"signature":"unsigned"' <<<"$out"; } \
  && ok_t "unsigned closure -> JSON gate/signature name the uncomputed check (DIVE-2801)" \
  || bad_t "unsigned closure -> JSON gate/signature name the uncomputed check (DIVE-2801)" "rc=$rc :: $out"

# 21) POSITIVE CONTROL — a SIGNED closure must still read as a clean rehearsal.
#     This is the arm that stops the fix degrading into "always warn": a blanket
#     warning fails HERE while arm 20 would still pass.
seed_task DIVE-991 "Branch: feature-ok" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-991 --dry-run); rc=$?
{ [[ $rc -eq 0 ]] \
    && grep -qi "dry-run: would push" <<<"$out" \
    && ! grep -qi "would NOT push" <<<"$out" \
    && ! grep -qi "WILL refuse" <<<"$out" \
    && grep -qi "NOT verified here" <<<"$out"; } \
  && ok_t "signed closure -> clean rehearsal, disclaimed not warned (DIVE-2801 positive control)" \
  || bad_t "signed closure -> clean rehearsal, disclaimed not warned (DIVE-2801 positive control)" "rc=$rc :: $out"

# 22) The usage refusal must not recommend a remedy it cannot honour. `--branch`
#     satisfies THIS check but not the DIVE-1462 gate binding in _push_do, which
#     reads the branch from the task body — so offering it as the alternative
#     sends the caller straight into the next refusal. Same defect, one step up.
seed_task DIVE-992 "no branch line in this body" approval "2026-07-18 00:00:00" "yes"
out=$(run_push DIVE-992 --dry-run 2>&1); rc=$?
{ [[ $rc -ne 0 ]] \
    && grep -q "Branch: <name>" <<<"$out" \
    && grep -q "body is REQUIRED" <<<"$out" \
    && ! grep -q "pass --branch=<name> or add" <<<"$out"; } \
  && ok_t "branch refusal names the body requirement, not --branch alone (DIVE-2801)" \
  || bad_t "branch refusal names the body requirement, not --branch alone (DIVE-2801)" "rc=$rc :: $out"

echo "-----"
printf 'push_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
