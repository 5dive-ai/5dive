#!/usr/bin/env bash
# DIVE-2448 isolated unit harness for `5dive gh` — actor-routed gh, the last mile
# of DIVE-2232 (every agent gh write authenticates as the human account, so the
# audit trail cannot tell agent from human).
#
# Covers the whole non-credential surface. The one thing it deliberately cannot
# cover is the live token path: `_gh_do` reads a root-only connector and execs
# the real gh, so that arm is smoked on a box, not here. Everything that DECIDES
# is pure and tested:
#   - the routing class of every gh shape we route (write / admin / read)
#   - admin PATHS beat the method: `api -X PUT .../protection` is admin, not write
#   - an UNRECOGNISED operation routes to the caller (fail-safe = today's
#     behaviour), which is the whole reason the default direction is what it is
#   - --as=bot cannot buy an admin operation, and _gh_do re-derives rather than
#     trusting the caller (a refusal must survive the caller lying about it)
#   - _gh_do is root-only and takes its argv on STDIN, so no credential-bearing
#     argument lands in the process table
#   - the builder sudoers grant carries _gh_do, a plain standard agent's does not,
#     and neither form uses an arg wildcard (sudo-rs safe)
# Run: bash tests/gh_actor_routing_unit.sh   (no root, no network, no gh needed)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/gh-actor-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh cmd_gh.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
JSON_MODE=0
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

cls() { # <expected> <gh args...>
  local want="$1"; shift
  local got; got=$(_gh_route_class "$@")
  [[ "$got" == "$want" ]] \
    && ok_t "class: '$*' -> $want" \
    || bad_t "class: '$*'" "got '$got', want '$want'"
}

# --- WRITE: the operations that leave an actor field behind. These are the only
# ones attribution is even a question for, and they are what must move to the bot.
cls write pr create --title x --body y
cls write pr merge 349 --squash
cls write pr comment 349 --body hi
cls write pr review 349 --approve
cls write pr close 349
cls write pr edit 349 --add-label x
cls write issue create --title x
cls write issue comment 12 --body hi
cls write release create v1.2.3
cls write release edit v1.2.3 --notes x
cls write workflow run ci.yml
cls write run rerun 123
cls write repo sync
cls write label create bug

# --- READ: no actor field to attribute, and the bot sees fewer repos than the
# caller — routing these to the bot would turn a working query into a 404.
cls read pr view 349
cls read pr list --state open
cls read pr checks 349
cls read pr diff 349
cls read issue view 12
cls read release view v1.2.3
cls read repo view 5dive-ai/5dive
cls read run view 123
cls read workflow list

# --- ADMIN: measured 2026-07-30, 5dive-bot is admin=false on all six repos, so
# these cannot succeed as the bot and must stay on the caller's credential.
cls admin auth status
cls admin auth login --with-token
cls admin config set editor vim
cls admin secret set FOO
cls admin variable set FOO
cls admin repo edit --default-branch main
cls admin repo delete 5dive-ai/scratch
cls admin repo create newthing

# --- api: the method decides write-vs-read, and the PATH beats the method. A PUT
# to branch protection is admin however it is spelled; getting this backwards
# sends the one operation the bot definitely cannot do to the bot.
cls read  api repos/5dive-ai/5dive
cls read  api user --jq .login
cls write api -X POST repos/5dive-ai/5dive/issues/1/comments -f body=hi
cls write api --method PATCH repos/5dive-ai/5dive/issues/1
cls write api repos/5dive-ai/5dive/issues/1/comments -f body=hi
cls admin api -X PUT repos/5dive-ai/5dive/branches/main/protection
cls admin api --method DELETE repos/5dive-ai/5dive/branches/main/protection
cls admin api -X PUT repos/lodar/5dive-api/collaborators/5dive-bot -f permission=push
cls admin api orgs/5dive-ai/members
cls admin api -X POST repos/5dive-ai/5dive/hooks
cls admin api repos/5dive-ai/5dive/actions/permissions

# --- The fail-safe DIRECTION. An operation we do not recognise must route to the
# CALLER: that is today's behaviour unchanged, so a new gh subcommand can never
# turn into a 403 on a path that used to work. It leaves a visible attribution
# gap instead of a silent breakage, and the stderr line is what makes it visible.
cls read some-future-verb do-a-thing
cls read pr some-future-subverb 349
cls write gist edit abc

# --- cmd_gh: the decision is PRINTED, on every call, for both directions. A
# routing tool that acts silently teaches nobody where the remaining gaps are.
out=$( ( cmd_gh --explain pr comment 349 --body hi ) 2>&1 )
[[ "$out" == *"actor=5dive-bot"* && "$out" == *"class=write"* ]] \
  && ok_t "explain: a write names the bot as the actor" \
  || bad_t "explain: a write names the bot as the actor" "$out"
out=$( ( cmd_gh --explain pr view 349 ) 2>&1 )
[[ "$out" == *"actor=your own gh credential"* && "$out" == *"class=read"* ]] \
  && ok_t "explain: a read stays on the caller and says so" \
  || bad_t "explain: a read stays on the caller and says so" "$out"
out=$( ( cmd_gh --explain --as=caller pr comment 349 --body hi ) 2>&1 )
[[ "$out" == *"actor=your own gh credential"* ]] \
  && ok_t "explain: --as=caller overrides a write back to the caller" \
  || bad_t "explain: --as=caller overrides a write back to the caller" "$out"

# --as=bot must NOT be able to buy an admin operation. Honouring the flag would
# trade a clear refusal for a 403 the caller has to decode.
out=$( ( cmd_gh --as=bot api -X PUT repos/5dive-ai/5dive/branches/main/protection ) 2>&1 )
[[ "$out" == *"admin=false"* ]] \
  && ok_t "--as=bot refuses an admin-class operation with the reason" \
  || bad_t "--as=bot refuses an admin-class operation" "$out"

out=$( ( cmd_gh --as=nobody pr view 1 ) 2>&1 )
[[ "$out" == *"--as must be"* ]] \
  && ok_t "--as rejects an unknown identity" \
  || bad_t "--as rejects an unknown identity" "$out"

# --- _gh_do: root-only, and it re-derives the class rather than trusting the
# caller. The refusal has to survive a caller that routes an admin call anyway.
out=$( ( cmd_gh_do ) 2>&1 )
[[ "$out" == *"root-only"* ]] \
  && ok_t "_gh_do refuses a non-root caller" \
  || bad_t "_gh_do refuses a non-root caller" "$out"
grep -q '_gh_route_class "${args\[@\]}"' "$SRC/cmd_gh.sh" \
  && ok_t "_gh_do re-derives the routing class as root (never trusts the caller)" \
  || bad_t "_gh_do re-derives the routing class as root" "no authoritative re-derivation in cmd_gh.sh"

# The credential invariant, checked as SHAPE because the live path needs a box:
# argv travels on stdin (never the process table) and the token is only ever an
# environment prefix — the same posture as delegated push (DIVE-1460).
grep -q "printf '%s\\\\0' \"\$@\" | sudo -n /usr/local/bin/5dive _gh_do" "$SRC/cmd_gh.sh" \
  && ok_t "cmd_gh hands argv to _gh_do over STDIN, never argv" \
  || bad_t "cmd_gh hands argv over STDIN" "no NUL-separated stdin handoff found"
grep -q 'GH_TOKEN="$tok" GITHUB_TOKEN="" gh "${args\[@\]}"' "$SRC/cmd_gh.sh" \
  && ok_t "_gh_do passes the token as an env prefix, never in argv" \
  || bad_t "_gh_do passes the token as an env prefix" "token not applied as an environment prefix"
# A missing sudo grant must be told apart from a failed gh call. sudo exits 1 for
# a denial, which is indistinguishable from gh's own 1 by rc alone — the first
# draft keyed on 127 (command-not-found) and was therefore dead code that could
# never fire. Measured on this box: a denial returns 1, and `sudo -n -l <cmd>`
# returns 0 for an account holding the grant and non-zero for one that does not.
grep -q 'sudo -n -l /usr/local/bin/5dive _gh_do' "$SRC/cmd_gh.sh" \
  && ok_t "cmd_gh distinguishes a missing grant from a failed call (sudo -l probe)" \
  || bad_t "cmd_gh distinguishes a missing grant from a failed call" "no sudo -l probe"
grep -q 'rc -eq 127' "$SRC/cmd_gh.sh" \
  && bad_t "cmd_gh does not key the grant check on rc=127" "127 is command-not-found; a sudo denial is 1, so that branch is dead" \
  || ok_t "cmd_gh does not key the grant check on rc=127 (dead branch)"
grep -q 'echo .*\$tok\|printf .*\$tok' "$SRC/cmd_gh.sh" \
  && bad_t "_gh_do never prints the token" "found a print of \$tok" \
  || ok_t "_gh_do never prints the token"

# --- The sudoers grant rides the EXISTING builder capability (--can-push): an
# agent allowed to ship is the same agent whose writes should carry the machine
# account. A non-builder standard agent must not get it, and neither form may use
# an arg wildcard (a wildcard on `5dive` is equivalent to NOPASSWD: ALL).
STD=$(render_standard_sudoers agent-testy 0)
BLD=$(render_standard_sudoers agent-testy 1)
[[ "$STD" == *"_gh_do"* ]] \
  && bad_t "sudoers: plain standard agent gets NO _gh_do" "unexpected _gh_do in non-builder grant" \
  || ok_t "sudoers: plain standard agent gets NO _gh_do"
[[ "$BLD" == *"NOPASSWD: /usr/local/bin/5dive _gh_do"* ]] \
  && ok_t "sudoers: builder (can_push=1) gets exact-path _gh_do" \
  || bad_t "sudoers: builder (can_push=1) gets exact-path _gh_do" "$BLD"
[[ "$BLD" == *"5dive _gh_do *"* ]] \
  && bad_t "sudoers: builder _gh_do has no arg wildcard" "wildcard present -> not sudo-rs safe" \
  || ok_t "sudoers: builder _gh_do has no arg wildcard"
# The grant CLASSIFIER has to learn the new line too, and this is not cosmetic:
# an unrecognised entry sets `extra=1`, which is the signal that a drifted grant
# is present — so a new capability line reads as DRIFT until it is declared. This
# is what agent_sudo_grant_unit.sh caught on the first push of this change.
# The rendered grant must contain NOTHING but comments and rules. This is not
# paranoia: the heredoc that renders it is UNQUOTED (it interpolates ${user}), so
# a backtick in a COMMENT is command substitution — a backtick-quoted word in the
# first draft of this change EXECUTED gh and pasted its help text into the
# sudoers file. `visudo -c` catches it, but only on a rig that has both visudo
# AND the substituted binary installed, and CI had neither, so it went green.
# This assertion needs neither.
stray=$(printf '%s\n' "$BLD" | grep -vE '^\s*(#|$)' | grep -vE '^agent-testy ALL=' | head -1)
[[ -z "$stray" ]] \
  && ok_t "sudoers: the rendered grant is comments and rules only (no substituted output)" \
  || bad_t "sudoers: the rendered grant is comments and rules only" "stray line: ${stray}"
[[ "$(printf '%s\n' "$BLD" | classify_sudo_grant)" == "cli-scoped|root|0" ]] \
  && ok_t "sudoers: classify_sudo_grant RECOGNISES _gh_do (no drift flag)" \
  || bad_t "sudoers: classify_sudo_grant recognises _gh_do" "got '$(printf '%s\n' "$BLD" | classify_sudo_grant)', want 'cli-scoped|root|0'"

# --- Wiring: the verb is dispatchable, the hidden helper is reachable, and the
# bundle actually carries the file. A routing rule nobody can call is not a fix.
grep -q '^    gh)' "$SRC/main.sh" \
  && ok_t "wiring: 'gh' is dispatched in main.sh" \
  || bad_t "wiring: 'gh' is dispatched in main.sh" "no dispatch arm"
grep -q '^    _gh_do)' "$SRC/main.sh" \
  && ok_t "wiring: '_gh_do' is dispatched in main.sh" \
  || bad_t "wiring: '_gh_do' is dispatched in main.sh" "no dispatch arm"
grep -q 'src/cmd_gh.sh' build.sh \
  && ok_t "wiring: cmd_gh.sh is in the bundle" \
  || bad_t "wiring: cmd_gh.sh is in the bundle" "build.sh does not concatenate it"
grep -q '5dive gh whoami' "$SRC/main.sh" \
  && ok_t "wiring: the verb is advertised in help" \
  || bad_t "wiring: the verb is advertised in help" "no help line"

echo "-----"
printf 'gh_actor_routing_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
