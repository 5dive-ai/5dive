#!/usr/bin/env bash
# TIER: core — pure functions, no network, no root, no git. Measured 0.1s on the 5dive host.
# DIVE-4748. `5dive push --open-pr` is TWO operations behind ONE verb, and until this
# row the verb could not say which of the two had failed:
#
#   - the push leg ended on "push failed (branch X); see output above", and the output
#     above is git's own text. For the delegated rail that text is systematically
#     misleading in one direction: GitHub answers an unauthorised WRITE with 404
#     `Repository not found`, never 403, so a permissions answer reads as a missing
#     repository. DIVE-4744 was told that about lodar/5dive-api — a repo `git ls-remote`
#     reached with the same credential minutes later.
#   - the PR leg's recovery advice was `5dive gh pr create --repo <r> --head <b>`, which
#     has no --base, no --title and no --body, so `gh` PROMPTS. No agent seat has a tty.
#     The advertised recovery could only fail.
#
# Both fixes are pure string work, so both are graded here without a credential, a
# cleared gate or a network: `_push_why` and `_push_pr_retry_cmd` take strings and
# return strings. The failure ORDERING (push first, PR second, PR failure non-fatal)
# is asserted against the source, because driving it needs a real token mint.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh; do source "$SRC/$f"; done
# cmd_push.sh is sourced for its pure helpers only; nothing below calls cmd_push.
# shellcheck source=/dev/null
source "$SRC/cmd_push.sh"

PASS=0; FAIL=0
ok_()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad_()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     got: %s\n' "$1" "$2"; }
has()   { local label="$1" hay="$2" needle="$3"; case "$hay" in *"$needle"*) ok_ "$label" ;; *) bad_ "$label (missing: $needle)" "$hay" ;; esac; }
hasnt() { local label="$1" hay="$2" needle="$3"; case "$hay" in *"$needle"*) bad_ "$label (should NOT contain: $needle)" "$hay" ;; *) ok_ "$label" ;; esac; }

echo "== _push_why: the 404 arm is the one this row exists for =="
W=$(_push_why "remote: Repository not found.
fatal: repository 'https://github.com/lodar/5dive-api.git/' not found" "lodar/5dive-api" "151145880")
has  "404 names the repo"                     "$W" "lodar/5dive-api"
has  "404 names the INSTALLATION, not just the repo" "$W" "151145880"
has  "404 says a write-404 is a permissions answer" "$W" "permissions answer"
has  "404 names the permission to check"      "$W" "contents:write"
has  "404 names the endpoint that settles it" "$W" "/app/installations/"
has  "404 names the positive control"         "$W" "ls-remote"

echo "== _push_why: the other arms are DIFFERENT causes, not one list =="
W=$(_push_why "remote: Permission to lodar/5dive-api.git denied to 5dive-bot." "lodar/5dive-api" "151145880")
has   "403 arm says the write was refused explicitly" "$W" "REFUSED the write explicitly"
hasnt "403 arm does not reach for the 404 gloss"      "$W" "permissions answer far more often"

W=$(_push_why " ! [rejected]  b -> b (non-fast-forward)
error: failed to push some refs" "o/r" "1")
has   "non-fast-forward is named a HISTORY conflict" "$W" "HISTORY conflict"
hasnt "non-fast-forward does not blame the credential" "$W" "contents:write"

W=$(_push_why "error: pre-push hook declined" "o/r" "1")
has  "local hook arm says nothing left the box" "$W" "nothing reached GitHub"

W=$(_push_why "fatal: unable to access 'https://github.com/o/r': Could not resolve host: github.com" "o/r" "1")
has  "network arm says the call did not complete" "$W" "did not complete"

W=$(_push_why "refusing to allow an OAuth App to create or update workflow \`.github/workflows/ci.yml\` without \`workflow\` scope" "o/r" "1")
has  "workflow arm names workflows:write" "$W" "workflows:write"

W=$(_push_why "" "o/r" "1")
has  "empty stderr says so rather than inventing a cause" "$W" "without printing a reason"

W=$(_push_why "something nobody has a case for" "o/r" "1")
has  "default arm echoes git's own last line" "$W" "git said: something nobody has a case for"

echo "== _push_pr_retry_cmd: the advice must be a command that RUNS =="
R=$(_push_pr_retry_cmd "lodar/5dive-api" "main" "dive-4744-x" "" "" "0")
has "retry carries --base (gh prompts without it)"  "$R" "--base main"
has "retry carries --head"                          "$R" "--head dive-4744-x"
has "retry carries a --title placeholder"           "$R" "--title '<title>'"
has "retry carries a --body placeholder"            "$R" "--body '<body>'"
hasnt "retry does NOT pass --as=bot (write already routes there)" "$R" "--as=bot"

R=$(_push_pr_retry_cmd "lodar/5dive-api" "main" "b" "DIVE-4748: fix" "/tmp/body.md" "1")
has "a supplied title is reused verbatim"    "$R" "--title 'DIVE-4748: fix'"
has "a supplied body FILE is reused"         "$R" "--body-file /tmp/body.md"
hasnt "and then no --body placeholder"       "$R" "--body '<body>'"
has "draft is carried through"               "$R" "--draft"

echo "== ordering + wording, asserted against the source =="
S=$(cat "$SRC/cmd_push.sh")
hasnt "the leg-blind 'push failed (branch' message is gone" "$S" 'push failed (branch ${branch}); see output above'
has   "the push refusal names the leg"        "$S" "the PUSH leg failed for branch"
has   "the push refusal says the PR was never attempted" "$S" "never attempted"
has   "the PR-leg warn says the branch IS up" "$S" "the BRANCH IS UP"
has   "the PR-leg warn says do not re-push"   "$S" "do NOT re-push"
has   "the PR-leg warn names the actor"       "$S" "5dive-bot"
# The PR leg must stay NON-fatal and stay AFTER the push: that ordering is what makes
# "the branch is up" true when the warn fires. A regression here is silent otherwise.
has   "the PR leg is still called after the delegated push" "$S" '_push_open_pr "$ident" "$slug" "$branch"'
if grep -q 'if ! _push_open_pr' "$SRC/cmd_push.sh"; then ok_ "the PR leg is still non-fatal (warn, not fail)"; else bad_ "the PR leg is still non-fatal" "no 'if ! _push_open_pr' guard"; fi

printf '\n%s arms: %s pass, %s fail\n' "$((PASS+FAIL))" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
