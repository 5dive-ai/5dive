#!/usr/bin/env bash
# DIVE-3496 — A RESOLVED TOKEN IS NOT A RAIL THAT CAN SEE THE REPO.
#
# THE DEADLOCK THIS GRADES. `_gate_gh_token` returns the FIRST credential it can
# resolve, and the bot rail and the anonymous rail live in `_gate_gh`'s `else`
# arm — i.e. they are reached only when the caller holds NOTHING. So a caller
# holding a token that is BLIND to the target repo forecloses two rails that
# would have answered, and the merge gate renders that as an unresolved merge
# state and refuses. Forever, because nothing about the seat changes.
#
# MEASURED ON THIS HOST 2026-08-16, which is why this is a fixture and not a
# hypothetical. Verifier seats are provisioned with `gh` authenticated as a
# GitHub App INSTALLATION token (`ghs_`, 390 chars) minted against the single
# pinned installation — the 5dive-ai org, 21 repos — and arm 3 of
# `_gate_gh_token` ("our own gh login") resolves it ahead of every fallback:
#     agent-main2's own token -> lodar/5dive-api : GraphQL: Could not resolve to
#                                                  a Repository  (the gate's UNKNOWN)
#     agent-main2's own token -> 5dive-ai/5dive  : answers normally
#     the BOT rail (_gh_do, 5dive-bot PAT) -> lodar/5dive-api : answers, with mergedAt
# DIVE-2192 merged, deployed and ran green, and could not be closed from either
# seat. The answer was one rail away the whole time.
# community/wiki/a-grader-that-cannot-read-the-repo-cannot-close-the-row.md
#
# WHAT THE ARMS ARE FOR. The escalation is only safe because it is NARROW, and
# three of the seven arms below grade the narrowness rather than the fix:
#   T2  a call that SUCCEEDS never touches a second rail (no extra request, so
#       the DIVE-2770 request-count budget is untouched on every green close)
#   T3  a failure that is NOT "cannot see this repository" does not escalate —
#       "Could not resolve to a PullRequest" is a credential that CAN see the
#       repo answering about a PR number, and re-asking a narrower rail cannot
#       improve it
#   T4  when the escalation ALSO fails we return the ORIGINAL status with empty
#       stdout, which is byte-for-byte today's state: the gate stays fail-closed
# T5/T6 anchor the EXTRACTION (`_gate_gh_nocred`) — the no-token path and its
#       exact legacy "no gh rail:" sentence must be unchanged, since that path
#       carries every existing verifier seat.
#
# MUTATION GRADE — RUN against this worktree's src/task/gate_evidence.sh, not
# predicted (2026-08-16; each mutant from 25/0 clean, and the arm names are the
# ones that ACTUALLY went red):
#   * delete the escalation block from `_gate_gh`      -> 16/9: all of T1, both
#     T1b arms, BOTH T4 diagnostic arms and T7's rail count. T4's rc/stdout arms
#     stay GREEN, and that is the point of writing them: without the escalation
#     the caller already gets non-zero and empty stdout, so those two arms pin
#     the DIRECTION (fail-closed is preserved) and cannot grade the fix.
#   * `_gate_gh_blind_err` matches every failure       -> 21/4: T3 alone, all
#     four arms. A one-test kill is what a narrowness guard should look like.
#
# Isolation matches the sibling gate harnesses: src/ sourced into a throwaway
# STATE_DIR (the live tasks.db is NEVER touched); gh and sudo are STUBBED on
# PATH, so this file makes no network call and needs no root. It calls `_gate_gh`
# directly rather than driving `task done` — that is why it fits the core tier
# where its `task done`-driven siblings do not.
# Run: bash tests/task_merge_gate_blind_credential_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# MUST sit AFTER grading_tree.sh — it sources lib/env_isolation.sh, which clears
# inherited FIVE_* knobs, so an export above this line is silently wiped and the
# harness reaches the real network instead.
export FIVE_GATE_NO_ANON=1
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-blind-unit.XXXXXX)"
mkdir -p "$TMP/bin"

# --- stub gh: the CALLER'S credential. GH_STUB_MODE picks which of the three
# measured outcomes it replays.
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'GH %s\n' "$*" >>"$GH_ARGS_LOG"
case "${GH_STUB_MODE:-blind_repo}" in
  ok)          printf '%s\n' "${GH_STUB_OUT:-MERGED}"; exit 0 ;;
  blind_repo)  printf 'GraphQL: Could not resolve to a Repository with the name '"'"'lodar/5dive-api'"'"'. (repository)\n' >&2; exit 1 ;;
  blind_404)   printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
  missing_pr)  printf 'GraphQL: Could not resolve to a PullRequest with the number 999999.\n' >&2; exit 1 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/gh"

# --- stub sudo: stands in for `sudo -n /usr/local/bin/5dive _gh_do`, the
# credential-free BOT rail. Reads the NUL-separated argv the real one reads.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'BOT\n' >>"$GH_ARGS_LOG"
[[ "${BOT_STUB_RC:-0}" == "0" ]] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit "${BOT_STUB_RC}"; }
printf '%s' "${BOT_STUB_OUT:-MERGED}"
exit 0
STUB
chmod +x "$TMP/bin/sudo"

export PATH="$TMP/bin:$PATH"
export GH_ARGS_LOG="$TMP/gh.args"; : >"$GH_ARGS_LOG"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/broker.sh lib/audit.sh \
         lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_push.sh \
         cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=0
mkdir -p "$TASKS_DIR"; set +e

# `_GATE_GH_DO` is a readonly path constant and `_gate_gh_bot_ok` probes it with
# `-x`, which is false on a CI runner with no installed CLI. Override the PROBE,
# not the path: what this file grades is the routing decision, and the probe's
# own correctness is graded by its own siblings. T6 restores the real answer.
_gate_gh_bot_ok() { [[ "${BOT_STUB_AVAILABLE:-1}" == "1" ]]; }

pass=0; fail=0
# The stub knobs must be EXPORTED — the stubs are separate processes. A bare
# `VAR=x out=$(...)` prefix does NOT export (it is an assignment list, not a
# command prefix), which silently ran every arm on the default fixture.
reset_stubs() {
  export GH_STUB_MODE=blind_repo GH_STUB_OUT=MERGED
  export BOT_STUB_OUT=MERGED BOT_STUB_RC=0 BOT_STUB_AVAILABLE=1
  : >"$GH_ARGS_LOG"
  _GATE_GH_LAST_ERR=""
}
# NOTE: every call below runs _gate_gh IN THIS SHELL and captures stdout through a
# file. A command substitution would run it in a subshell, where _GATE_GH_LAST_ERR
# is set and then discarded — the diagnostic arms would grade an empty string and
# pass for the wrong reason.
ok()  { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got : %s\n' "$1" "$3" "$2"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want substring: %s\n  got : %s\n' "$1" "$3" "$2"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  unwanted substring: %s\n  got : %s\n' "$1" "$3" "$2"; fi; }

# ---------------------------------------------------------------- T1: THE FIX
# A blind caller credential escalates to the credential-free rail, and the answer
# the bot rail already held reaches the gate.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_OUT='MERGED'
_gate_gh "ghs_pinned_to_the_org" 0 pr view https://github.com/lodar/5dive-api/pull/110 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok  "T1 escalates on a repo the caller's credential cannot see: rc"  "$rc"  "0"
ok  "T1 the escalated answer is returned"                            "$out" "MERGED"
has "T1 the bot rail was actually consulted" "$(cat "$GH_ARGS_LOG")" "BOT"
ok  "T1 clears the stale error on success"                           "$_GATE_GH_LAST_ERR" ""

# A REST 404 is the same event in the other wire format and must escalate too.
reset_stubs; export GH_STUB_MODE=blind_404 BOT_STUB_OUT='MERGED'
_gate_gh "ghs_pinned_to_the_org" 0 api /repos/lodar/5dive-api/pulls/110 >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok  "T1b a REST 404 escalates as well: rc"    "$rc"  "0"
ok  "T1b and returns the escalated answer"    "$out" "MERGED"

# --------------------------------------------------- T2: THE HAPPY PATH ANCHOR
# A call that ANSWERS must never touch a second rail. This is what keeps every
# green close costing the same number of requests it costs today (DIVE-2770 T9).
reset_stubs; export GH_STUB_MODE=ok GH_STUB_OUT='OPEN'
_gate_gh "a_working_token" 0 pr view https://github.com/5dive-ai/5dive/pull/1 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok    "T2 a successful call: rc"                     "$rc"  "0"
ok    "T2 returns the caller-credential answer"      "$out" "OPEN"
hasnt "T2 does NOT consult a second rail" "$(cat "$GH_ARGS_LOG")" "BOT"

# ------------------------------------------------------ T3: THE NARROWNESS ARM
# "Could not resolve to a PullRequest" is a credential that CAN see the repo,
# answering about a number. No escalation, and the caller's own stderr survives.
reset_stubs; export GH_STUB_MODE=missing_pr
_gate_gh "a_working_token" 0 pr view https://github.com/5dive-ai/5dive/pull/999999 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok    "T3 an unrelated failure does not escalate: rc is non-zero" "$((rc != 0))" "1"
ok    "T3 stdout stays empty"                                     "$out" ""
hasnt "T3 no second rail was consulted" "$(cat "$GH_ARGS_LOG")" "BOT"
has   "T3 the caller's own error is preserved" "$_GATE_GH_LAST_ERR" "Could not resolve to a PullRequest"

# ------------------------------------------------- T4: FAIL-CLOSED IS PRESERVED
# Blind caller AND a rail that cannot answer either. The contract is that this
# is indistinguishable, to the gate, from today's refusal — non-zero, empty
# stdout — while the diagnostic names BOTH halves so the reader is not sent to
# look for a missing PR.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_RC=1
_gate_gh "ghs_pinned_to_the_org" 0 pr view https://github.com/lodar/5dive-api/pull/110 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok  "T4 both rails blind: rc is non-zero"      "$((rc != 0))" "1"
ok  "T4 both rails blind: stdout is empty"     "$out" ""
has "T4 names the caller's blindness"          "$_GATE_GH_LAST_ERR" "cannot see this repository"
has "T4 names that the fallback was tried too" "$_GATE_GH_LAST_ERR" "credential-free rails were tried"

# ------------------------------------ T5: THE EXTRACTION DID NOT MOVE ANYTHING
# No token at all is the path every credential-less verifier seat already takes.
reset_stubs; export BOT_STUB_OUT='MERGED'
_gate_gh "" 0 pr view https://github.com/5dive-ai/5dive/pull/1 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok    "T5 no-token path still reaches the bot rail: rc" "$rc"  "0"
ok    "T5 no-token path returns its answer"             "$out" "MERGED"
hasnt "T5 no-token path never invokes the caller's gh" "$(cat "$GH_ARGS_LOG")" "GH "

# ------------------------------------------- T6: THE LEGACY NO-RAIL SENTENCE
# With no token, no bot and the anon rail disabled, the refusal text is the one
# DIVE-2705 wrote and downstream refusals quote. An extraction that reworded it
# would be a silent diagnostic regression.
reset_stubs; export BOT_STUB_AVAILABLE=0
_gate_gh "" 0 pr view https://github.com/5dive-ai/5dive/pull/1 --json state -q .state >"$TMP/out"; rc=$?; out=$(cat "$TMP/out")
ok  "T6 no rail at all: rc is 1"       "$rc"  "1"
ok  "T6 no rail at all: stdout empty"  "$out" ""
has "T6 keeps the legacy sentence"     "$_GATE_GH_LAST_ERR" "no gh rail: no token, the gate bot is not usable here"

# ------------------------------------------------------------------ T7: BUDGET
# The escalation costs exactly ONE extra call, and only on the blind path.
reset_stubs; export GH_STUB_MODE=blind_repo BOT_STUB_OUT='MERGED'
_gate_gh "ghs_pinned_to_the_org" 0 pr view https://github.com/lodar/5dive-api/pull/110 --json state -q .state >/dev/null
ok "T7 one caller call" "$(grep -c '^GH ' "$GH_ARGS_LOG")" "1"
ok "T7 one rail call"   "$(grep -c '^BOT$' "$GH_ARGS_LOG")" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
