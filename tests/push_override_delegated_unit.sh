#!/usr/bin/env bash
# DIVE-4288 — the pre-push rail's AUDITED OVERRIDE, across the sudo boundary.
#
# WHAT WAS BROKEN, and why every arm here is about a thing that PRINTED NOTHING.
# `scripts/pre-push-rail.sh` refuses a red push and advertises
# `FIVE_PUSH_OVERRIDE="$(cat reason.txt)" git push`. It reads that variable from
# the environment of the process running the rail, and on a delegated push that
# process is ROOT's — `cmd_push` hands the push over a plain `sudo -n`, which
# strips it. Measured 2026-09-11 (dev3, DIVE-4282): a five-clause reason exported
# in front of `5dive push` produced NEITHER of `override_taken()`'s two outcomes,
# no OVERRIDDEN block and no clause refusal, because the reason never arrived.
#
# So the failure mode this file grades is silence, not a wrong answer, and each
# arm names the thing that has to be POSITIVELY observed:
#
#   the reason SURVIVES the wire   B1/B2/B3: the writer and reader are the two
#                                  ends of `_push_do`'s stdin, and a five-clause
#                                  reason is multi-line by construction — a fifth
#                                  `read -r` would truncate it to clause 1 and
#                                  then refuse the push for missing 2-5. B1 is the
#                                  MUTATION arm: drop the reason from the writer
#                                  and it reds.
#   the grading is ROOT-side       B4/B5: `_push_override_grade` accepts five
#                                  clauses and refuses four, NAMING the missing
#                                  number. Root grades it so the signing agent
#                                  cannot fake the audit line.
#   the two graders AGREE          B6: the CLI's predicate and the rail's own
#                                  `override_taken()` run over one fixture corpus
#                                  and must return the same verdict on every
#                                  fixture. Two copies of a contract is how a
#                                  reason the rail accepts and root refuses (or
#                                  worse, the reverse) gets shipped.
#   the advice is RUNNABLE         B7/B8: under FIVE_PUSH_DELEGATED the rail and
#                                  the hook must advertise `5dive push <row>` and
#                                  must NOT advertise `git push` / `--no-verify`,
#                                  which that seat cannot run. Printing a dead end
#                                  is what sent DIVE-4282 to "hand the branch to a
#                                  credentialed seat or edit the red gate".
#   the signature is FINDABLE      B9: an accepted override prints the path of the
#                                  log it was written to. On a delegated push that
#                                  file is written by root inside an agent-owned
#                                  checkout; a receipt nobody can locate is not an
#                                  audit trail.
#
# NO ROOT, NO NETWORK. `cmd_push_do` itself is root-only and mints a real token,
# so it is not run here: the pieces it is built from are functions precisely so
# they can be graded without it. The call SITE (that cmd_push passes the variable
# at all) is graded in tests/push_unit.sh, which already has the task/gate rig.
#
# Run: bash tests/push_override_delegated_unit.sh
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

# DIVE-2211 / DIVE-2286: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# HERMETIC AGAINST GIT'S HOOK ENVIRONMENT (see tests/pre_push_rail_unit.sh): when
# this harness is run BY the pre-push hook, GIT_DIR is exported and outranks
# `git -C <dir>`, so the sandbox repo below would silently be this checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_QUARANTINE_PATH
# And against the variable UNDER TEST: an operator overriding their own push must
# not turn these arms green.
unset FIVE_PUSH_OVERRIDE FIVE_PUSH_DELEGATED FIVE_PUSH_TASK

cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC=src
RAIL="$ROOT/scripts/pre-push-rail.sh"
HOOK="$ROOT/scripts/git-hooks/pre-push"

PASS=0; FAIL=0
TMP="$(mktemp -d)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
JSON_MODE=0
# cmd_push.sh is sourced for its functions only; nothing below dispatches a verb.
# shellcheck source=/dev/null
source "$SRC/cmd_push.sh"
set +e

# DEFINED AFTER THE SOURCE, AND NOT CALLED `ok`. src/lib/output.sh exports its own
# `ok()` — the CLI's success printer — so a reporter named `ok` here is silently
# replaced by it the moment cmd_push.sh's dependencies load: every arm prints a
# plausible success line and the counters stay at zero. Same trap as push_unit.sh,
# which is why that file uses these names too.
ok_t()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

# The five-clause reason this repo's override contract actually asks for. Written
# out in full rather than as "1) 2) 3) 4) 5)" so the arms grade a reason a person
# would really sign — and so B1 has genuinely multi-line, punctuation-bearing text
# to carry across the wire.
FIVE=$'1) the pre-push rail could not run the touched harness here: the worktree has no built bundle and build.sh reds on this box.\n2) what ran instead: shellcheck over the 2 changed shell files (green) and 3 of 4 touched harnesses on the pushed tree (green).\n3) the residual I am signing: the fourth harness, which is the only check covering the selector on an added-file diff.\n4) I sign it anyway because CI grades that harness on this same range within the hour and the row is blocking a stalled release.\n5) what stays uncovered: nothing after CI reports; until then, the added-file selection path.'
FOUR=$'1) the rail could not run here.\n2) shellcheck ran, 2 files, green.\n3) the residual is the harness stage.\n5) what stays uncovered: the harness stage until CI.'

# ── B1-B3: the wire ───────────────────────────────────────────────────────────
#
# MUTATION ARM. The whole row is "the reason never crossed the sudo boundary", so
# the property is that a reason written by one end is READ BACK WHOLE by the
# other. Delete the fifth field from `_push_do_stdin_write` and this reds; keep
# the field but read it with a fifth `read -r` and it reds too, on clause 2.
out="$(_push_do_stdin_write DIVE-1 /srv/repo feat-x https://github.com/o/r.git "$FIVE" \
       | { _push_do_stdin_read
           printf '%s\n%s\n%s\n%s\n--\n%s\n' "$_PUSH_DO_IDENT" "$_PUSH_DO_REPOPATH" \
                  "$_PUSH_DO_BRANCH" "$_PUSH_DO_REPOURL" "$_PUSH_DO_OVERRIDE"; })"
got_reason="${out#*$'\n--\n'}"
{ [[ "$(sed -n 1p <<<"$out")" == DIVE-1 ]] \
  && [[ "$(sed -n 2p <<<"$out")" == /srv/repo ]] \
  && [[ "$(sed -n 3p <<<"$out")" == feat-x ]] \
  && [[ "$(sed -n 4p <<<"$out")" == https://github.com/o/r.git ]] \
  && [[ "$got_reason" == "$FIVE" ]]; } \
  && ok_t "B1 a five-clause reason crosses the _push_do wire WHOLE, alongside the four parameters (MUTATION ARM: drop the fifth field and this reds)" \
  || bad_t "B1 the reason did not survive the wire intact: $out"

out="$(_push_do_stdin_write DIVE-2 /srv/repo feat-y https://github.com/o/r.git "" \
       | { _push_do_stdin_read; printf '[%s][%s]\n' "$_PUSH_DO_BRANCH" "$_PUSH_DO_OVERRIDE"; })"
[[ "$out" == '[feat-y][]' ]] \
  && ok_t "B2 no override: the four parameters still arrive and the reason reads EMPTY — the no-override path is unchanged" \
  || bad_t "B2 the no-override path changed shape: $out"

# FORWARD COMPAT. A root-side `_push_do` from this release can be handed stdin by
# an OLDER `cmd_push` (a box mid-upgrade, or a hand-driven call) that writes only
# four lines. It must see an empty reason, not block on the read.
out="$(printf '%s\n' DIVE-3 /srv/repo feat-z https://github.com/o/r.git \
       | { _push_do_stdin_read; printf '[%s][%s]\n' "$_PUSH_DO_IDENT" "$_PUSH_DO_OVERRIDE"; })"
[[ "$out" == '[DIVE-3][]' ]] \
  && ok_t "B3 a four-line (pre-DIVE-4288) writer is read as 'no override', not as a hang or a partial field" \
  || bad_t "B3 the reader mishandled a four-field stream: $out"

# ── B4-B5: the grading, root-side ─────────────────────────────────────────────
out="$( _push_override_grade "$FIVE" 2>&1 )"; rc=$?
{ (( rc == 0 )) && [[ -z "$out" ]]; } \
  && ok_t "B4 a five-clause reason is ACCEPTED root-side, silently" \
  || bad_t "B4 a valid reason was not accepted (rc=$rc): $out"

out="$( _push_override_grade "$FOUR" 2>&1 )"; rc=$?
{ (( rc != 0 )) && grep -q "OVERRIDE REFUSED" <<<"$out" && grep -q "clause(s): 4" <<<"$out"; } \
  && ok_t "B5 a reason missing clause 4 is REFUSED root-side and the refusal NAMES 4 — a count would not tell the signer what to write" \
  || bad_t "B5 the four-clause reason was not refused by number (rc=$rc): $out"

out="$( _push_override_grade "" 2>&1 )"; rc=$?
{ (( rc == 0 )) && [[ -z "$out" ]]; } \
  && ok_t "B5b an ABSENT reason is not an override and is not graded — the ordinary push must not be refused for lacking one" \
  || bad_t "B5b an empty reason was graded (rc=$rc): $out"

# ── B6: the two graders agree ─────────────────────────────────────────────────
#
# The rail keeps its own copy of the predicate because it also runs on a seat that
# has no 5dive bundle (a plain `git push` in a clone). Two copies of a contract is
# how a reason one side accepts and the other refuses gets shipped, so they are
# run over ONE corpus here and required to agree fixture by fixture.
SB="$TMP/sb"; mkdir -p "$SB/scripts"
cp "$RAIL" "$SB/scripts/pre-push-rail.sh"
git -C "$SB" init -q
git -C "$SB" config user.email t@example.com
git -C "$SB" config user.name t
git -C "$SB" add -A >/dev/null
git -C "$SB" commit -qm 'chore: base' >/dev/null
SB_BASE="$(git -C "$SB" rev-parse HEAD)"

# The rail's verdict, read off its two printed outcomes rather than its exit code:
# `override_taken` exits 1 on a refusal and returns 1 when there is no reason at
# all, so the exit code alone cannot tell those apart — which is precisely the
# ambiguity DIVE-4288 was diagnosed through.
rail_verdict() { # <reason> -> "accept" | "refuse"
  local o
  o="$( cd "$SB" && FIVE_PUSH_OVERRIDE="$1" bash scripts/pre-push-rail.sh "$SB_BASE" HEAD --only=title 2>&1 )"
  if   grep -q 'OVERRIDDEN' <<<"$o";       then printf 'accept'
  elif grep -q 'OVERRIDE REFUSED' <<<"$o"; then printf 'refuse'
  else printf 'silent'; fi
}
cli_verdict() { # <reason> -> "accept" | "refuse"
  [[ -z "$(_push_override_missing_clauses "$1")" ]] && printf 'accept' || printf 'refuse'
}

disagree=0
declare -a FIXTURES=(
  "$FIVE"
  "$FOUR"
  'wip'
  ''
  $'1. one\n2. two\n3. three\n4. four\n5. five'
  $'1: one\n2: two\n3: three\n4: four\n5: five'
  $'shipping 11) eleven 12) twelve 13) thirteen 14) fourteen 15) fifteen'
  $'1) a\n2) b\n3) c\n4) d'
)
for fx in "${FIXTURES[@]}"; do
  [[ -z "$fx" ]] && continue     # the empty reason is B5b's arm; the rail is silent on it by design
  rv="$(rail_verdict "$fx")"; cv="$(cli_verdict "$fx")"
  if [[ "$rv" != "$cv" ]]; then
    disagree=$((disagree+1))
    printf '     disagreement: rail=%s cli=%s on %q\n' "$rv" "$cv" "${fx:0:60}"
  fi
done
(( disagree == 0 )) \
  && ok_t "B6 the rail's grader and the root-side grader return the SAME verdict on every fixture, including the digit-prefix trap (11) is not clause 1)" \
  || bad_t "B6 the two graders disagree on $disagree fixture(s) — a reason one side accepts and the other refuses"

# ── B7-B8: the advice names a command this seat can run ───────────────────────
#
# A red stage is forced with --only=title and no workflow file to read the rule
# out of… which fails OPEN by design, so instead force the red the cheap way: a
# harness stage with a failing harness in the diff.
mkdir -p "$SB/tests"
cp "$ROOT/scripts/changed-harnesses.sh" "$SB/scripts/changed-harnesses.sh" 2>/dev/null
printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/tests/red_unit.sh"
git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'test: red' >/dev/null

rail_refusal() { ( cd "$SB" && env "$@" bash scripts/pre-push-rail.sh "$SB_BASE" HEAD --only=harnesses ) 2>&1; }

out="$(rail_refusal FIVE_PUSH_DELEGATED=1 FIVE_PUSH_TASK=DIVE-4282)"
{ grep -q '5dive push DIVE-4282' <<<"$out" && ! grep -qE '\bgit push\b' <<<"$out"; } \
  && ok_t "B7 on a DELEGATED push the rail's refusal advertises '5dive push <row>' and never 'git push' — the route that seat actually has" \
  || bad_t "B7 the delegated refusal did not name a runnable escape: $out"

out="$(rail_refusal FIVE_PUSH_NOTHING=1)"
grep -q 'git push' <<<"$out" \
  && ok_t "B8 on an ordinary push the refusal still advertises 'git push' — the delegated text did not replace it for everyone" \
  || bad_t "B8 the ordinary refusal lost its escape: $out"

# The hook prints its own escape block one level out, and it advertised
# --no-verify, which a credential-less seat cannot run either.
grep -q 'FIVE_PUSH_DELEGATED' "$HOOK" \
  && ok_t "B8b the pre-push hook's own escape block branches on FIVE_PUSH_DELEGATED too — it advertised --no-verify, which that seat cannot run" \
  || bad_t "B8b the hook still prints one escape block for both kinds of push"

# ── B9: the signature is findable ─────────────────────────────────────────────
out="$( cd "$SB" && FIVE_PUSH_OVERRIDE="$FIVE" bash scripts/pre-push-rail.sh "$SB_BASE" HEAD --only=harnesses 2>&1 )"; rc=$?
{ (( rc == 0 )) && grep -q 'OVERRIDDEN' <<<"$out" \
  && grep -q 'logged to:.*5dive-push-override.log' <<<"$out"; } \
  && ok_t "B9 an accepted override prints the PATH of the log it was written to — on a delegated push that file is written by root inside the agent's checkout" \
  || bad_t "B9 the accepted override did not name its log path (rc=$rc): $out"

grep -Fq 'chown --reference="$repopath"' "$SRC/cmd_push.sh" \
  && ok_t "B9b _push_do hands the override log back to the checkout's owner — root's append would otherwise leave a file the signing seat cannot write" \
  || bad_t "B9b the override log is left root-owned in an agent's checkout"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
