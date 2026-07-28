#!/usr/bin/env bash
# DIVE-2143 harness for the version-assign PUSH path: does it name the right cause,
# and does it stop retrying a failure that retrying cannot fix?
#
# THE DEFECT THIS GRADES, measured on run 30231912328 (5dive-ai/5dive, 2026-07-27
# 02:19). Branch protection rejected the assignment push. The loop printed
#   "push rejected — main moved under us (attempt 1/3)"  ...2/3 ...3/3
#   "::error::main kept moving across 3 attempts"
# three times over. Main never moved — the tip was 02b356e for the whole run. Two
# costs: three attempts burned on a DETERMINISTIC failure, and, worse, an error that
# points the next reader at a concurrency bug in code that is working correctly.
#
# WHY THE ARMS BELOW ARE BEHAVIOURAL AND NOT MESSAGE GREPS. A harness that only
# checked "does it print the protection message" would pass on a loop that printed it
# and then retried twice anyway — the retry is half the defect. So the arms COUNT the
# push attempts, using a stub `git` on PATH that records every invocation. Counting is
# the assertion; the message is a second, separate one.
#
# AND WHY THERE IS A MUTATION ARM. tests/version_assign_unit.sh learned this the hard
# way (its arms G/H exist because it stayed 16/16 green with two assertions replaced
# by `true`). Arm M replaces the CLASSIFIER with one that always says "race" — the
# pre-DIVE-2143 behaviour, exactly — and demands the run go back to 3 attempts. If the
# discrimination is ever deleted, M fails; without M, arms C/D would keep passing on a
# loop that had stopped discriminating for an unrelated reason.
# Run: bash tests/version_assign_push_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh"
cd "$(dirname "$0")/.."
REPO="$PWD"
CLS="$REPO/scripts/git-push-reject-class.sh"
LOOP="$REPO/scripts/version-assign-push-loop.sh"
FIX="$REPO/tests/fixtures/push-reject"
TMP="$(mktemp -d /tmp/version-assign-push-unit.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
P=0; F=0
ok(){ P=$((P+1)); echo "ok   - $1"; }
no(){ F=$((F+1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "   $2"; }

# ---------------------------------------------------------------------------
# CLASSIFIER — graded against CAPTURED stderr (tests/fixtures/push-reject/), never
# against text invented here. The GH006 capture is verbatim from the run above,
# trailing whitespace and all.
cls(){ bash "$CLS" < "$FIX/$1"; }

[[ "$(cls protected-gh006.txt)" == protection ]] \
  && ok "A the real GH006 capture classifies as 'protection' (not a race)" \
  || no "A GH006" "got: $(cls protected-gh006.txt)"
[[ "$(cls race-fetch-first.txt)" == race ]] \
  && ok "A a real '(fetch first)' rejection classifies as 'race'" \
  || no "A fetch-first" "got: $(cls race-fetch-first.txt)"
[[ "$(cls race-non-fast-forward.txt)" == race ]] \
  && ok "A a real '(non-fast-forward)' rejection classifies as 'race' (git words it differently after a fetch)" \
  || no "A non-ff" "got: $(cls race-non-fast-forward.txt)"
[[ "$(cls unknown-transport.txt)" == unknown ]] \
  && ok "A an unrecognised failure classifies as 'unknown' — the class is REACHABLE, not decorative" \
  || no "A unknown" "got: $(cls unknown-transport.txt)"

# PRECEDENCE. The GH006 capture also carries '! [remote rejected]', and a protection
# rejection that happened to mention a fast-forward hint must still read as protection:
# the whole defect was a gated ref being reported as a race.
printf '%s\n%s\n' "$(cat "$FIX/protected-gh006.txt")" "hint: Updates were rejected because the remote contains work" > "$TMP/mixed.txt"
[[ "$(bash "$CLS" < "$TMP/mixed.txt")" == protection ]] \
  && ok "A PRECEDENCE: protection wins when a capture carries BOTH markers (a gated ref must never read as a race)" \
  || no "A precedence" "got: $(bash "$CLS" < "$TMP/mixed.txt")"
[[ "$(printf '' | bash "$CLS")" == unknown ]] \
  && ok "A empty stderr is 'unknown', not silently a race" || no "A empty" "got: $(printf '' | bash "$CLS")"

# ---------------------------------------------------------------------------
# LOOP — behavioural, with a stub `git` on PATH.
#
# The stub is the seam, and it is deliberately NOT a flag inside the shipped script:
# a test-only branch grades the test-only branch. Here the production code runs
# unmodified and every `git` it calls lands in a recorder. `scripts/version-assign.sh`
# is stubbed the same way — the loop invokes it by RELATIVE path, so a fixture cwd
# substitutes it without the shipped script knowing. What version-assign.sh itself
# does is already graded by tests/version_assign_unit.sh; grading it twice here would
# only couple the two.
mkfix() { # $1 = push exit (0|1), $2 = fixture file of push stderr
  local d="$TMP/fix$RANDOM$RANDOM"; mkdir -p "$d/scripts" "$d/src" "$d/bin"
  printf 'readonly FIVE_VERSION="0.16.29"\n' > "$d/src/header.sh"
  # stub version-assign.sh: always reports an applied assignment, so the loop always
  # reaches the push. Its own logic is graded by version_assign_unit.sh.
  { echo '#!/usr/bin/env bash'
    echo 'echo "version-assign: applied 0.16.28 -> 0.16.29, bundle rebuilt (deadbeef). NO TAG."'; } \
    > "$d/scripts/version-assign.sh"
  # stub git: records every invocation, counts pushes, replays the captured stderr.
  # rev-parse answers the same sha for FETCH_HEAD and HEAD, so "main moved" never
  # fires and the only thing under test is what happens to the PUSH.
  cat > "$d/bin/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$d/git.log'
case "\${1:-}" in
  push)      echo push >> '$d/push.count'; cat '$2' >&2; exit $1 ;;
  rev-parse) echo 0000000000000000000000000000000000000000 ;;
esac
exit 0
EOF
  chmod +x "$d/bin/git" "$d/scripts/version-assign.sh"
  : > "$d/push.count"; : > "$d/git.log"
  printf '%s' "$d"; }

runloop() { # $1 = fixture dir, $2 = loop script to run (real or mutated)
  ( cd "$1" && PATH="$1/bin:$PATH" bash "$2" beforesha 3 ) 2>&1; }
# wc, not `grep -c || echo 0`: grep -c on an empty file prints 0 AND exits 1, so the
# fallback fires too and the count comes back "0\n0" — a comparison that can never
# match, i.e. an arm that fails for a reason that has nothing to do with the subject.
pushes() { local n; n=$(wc -l < "$1/push.count"); echo "${n// /}"; }

# B CONTROL: the happy path. Without it, a red C/D would prove nothing — a loop broken
# for an unrelated reason also makes exactly one push attempt and fails.
d=$(mkfix 0 "$FIX/race-fetch-first.txt"); out=$(runloop "$d" "$LOOP"); rc=$?
(( rc == 0 )) && ok "B CONTROL: a push that SUCCEEDS exits 0 (so a red C/D means the classifier, not a broken fixture)" || no "B rc" "$rc: $out"
[[ "$(pushes "$d")" == 1 ]] && ok "B CONTROL: and pushes exactly once" || no "B count" "$(pushes "$d")"
grep -q 'assigned 0.16.29' <<<"$out" && ok "B CONTROL: and reports the version it assigned" || no "B msg" "$out"

# C THE DEFECT: GH006 must fail on attempt 1 and must not blame a race.
d=$(mkfix 1 "$FIX/protected-gh006.txt"); out=$(runloop "$d" "$LOOP"); rc=$?
(( rc == 1 )) && ok "C a protection rejection FAILS (exit 1) — it is not swallowed" || no "C rc" "$rc: $out"
[[ "$(pushes "$d")" == 1 ]] \
  && ok "C BEHAVIOURAL: exactly ONE push attempt — the deterministic failure is not retried (was 3 on run 30231912328)" \
  || no "C attempts" "expected 1 push, got $(pushes "$d")"
grep -q 'rejected by branch protection' <<<"$out" \
  && ok "C names branch protection as the cause" || no "C cause" "$out"
# if/else, not `A && no || ok`: no() returns non-zero when called without a detail
# argument, so the || arm would fire too and a FAILING assertion would also print an
# "ok" line. The suite would still go red, but the transcript would say both things.
if grep -qE 'main moved under us|kept moving' <<<"$out"; then
  no "C LIE: it still blames a race — this is the exact sentence run 30231912328 printed three times" "$out"
else
  ok "C it does NOT print 'main moved under us' / 'kept moving' (the wrong cause)"
fi
grep -q 'GH006: Protected branch update failed' <<<"$out" \
  && ok "C ECHOES the remote's own words rather than paraphrasing them" || no "C echo" "$out"
grep -q '6 of 6 required status checks are expected' <<<"$out" \
  && ok "C including the required-checks line, which is the actionable half" || no "C checks line" "$out"

# D THE RACE STILL RETRIES. The fix must not turn every rejection into a hard stop —
# the reset-and-recompute path is correct and is why the loop exists.
for f in race-fetch-first race-non-fast-forward; do
  d=$(mkfix 1 "$FIX/$f.txt"); out=$(runloop "$d" "$LOOP"); rc=$?
  (( rc == 1 )) && ok "D ($f) an unresolvable race still fails loudly" || no "D rc ($f)" "$rc: $out"
  [[ "$(pushes "$d")" == 3 ]] \
    && ok "D ($f) BEHAVIOURAL: all 3 attempts are used — the genuine-race retry path is intact" \
    || no "D attempts ($f)" "expected 3 pushes, got $(pushes "$d")"
  grep -q 'main moved under us' <<<"$out" \
    && ok "D ($f) and a real race IS reported as a race" || no "D msg ($f)" "$out"
done

# E UNKNOWN: no retry, no invented cause, and the raw text survives to the log.
d=$(mkfix 1 "$FIX/unknown-transport.txt"); out=$(runloop "$d" "$LOOP"); rc=$?
(( rc == 1 )) && ok "E an unrecognised rejection fails" || no "E rc" "$rc: $out"
[[ "$(pushes "$d")" == 1 ]] \
  && ok "E BEHAVIOURAL: it is not retried — 'unrecognised' is not quietly widened into 'race'" \
  || no "E attempts" "expected 1 push, got $(pushes "$d")"
grep -q 'UNRECOGNISED' <<<"$out" && ok "E says outright that it does not know the cause" || no "E msg" "$out"
if grep -qE 'main moved under us|kept moving' <<<"$out"; then
  no "E it reached for the nearest familiar cause instead of admitting ignorance" "$out"
else
  ok "E and does NOT reach for the nearest familiar cause"
fi
grep -q "Couldn't connect to server" <<<"$out" \
  && ok "E the remote's own text reaches the log verbatim" || no "E echo" "$out"

# ---------------------------------------------------------------------------
# M MUTATION: break the discrimination, demand the arms above go red.
#
# The classifier is resolved relative to the loop script's own directory, so a COPY of
# the shipped loop beside a stubbed classifier reproduces the pre-fix behaviour with
# the loop itself untouched. If someone later deletes the protection branch, or makes
# the classifier answer "race" to everything (which is precisely what the old code
# did), this arm fails.
mkdir -p "$TMP/mut/scripts"
cp "$LOOP" "$TMP/mut/scripts/"
{ echo '#!/usr/bin/env bash'; echo 'cat >/dev/null'; echo 'echo race'; } > "$TMP/mut/scripts/git-push-reject-class.sh"
chmod +x "$TMP/mut/scripts/git-push-reject-class.sh"
d=$(mkfix 1 "$FIX/protected-gh006.txt"); out=$(runloop "$d" "$TMP/mut/scripts/$(basename "$LOOP")")
if [[ "$(pushes "$d")" == 3 ]] && grep -q 'main moved under us' <<<"$out"; then
  ok "M MUTATION: a classifier that always says 'race' reproduces the defect (3 attempts + 'main moved under us') — so arm C is driven by the classifier, not by luck"
else
  no "M MUTATION" "mutating the classifier did NOT change the outcome ($(pushes "$d") pushes) — arms C/E are passing for some other reason and grade nothing"
fi

# N NO TAG, still. tests/version_assign_unit.sh arm H scans the two files that USED to
# hold every shipped line of this subsystem. The push moved out of them, so the scan
# had to move too — a guarantee whose scope quietly stops covering the code it was
# written for is worse than no guarantee. (Kept here as well as there: whichever file
# a future edit lands in, one of the two harnesses sees it.)
if grep -nEi 'git[[:space:]]+tag|gh[[:space:]]+release|refs/tags|--tags|create-release|action-gh-release' "$LOOP" "$CLS"; then
  no "N a tag verb appears in the extracted push path (bump yes, tag no — lodar froze releases)"
else
  ok "N BEHAVIOURAL: no tag verb in the extracted push path either — the no-tag guarantee followed the code out of the YAML"
fi

# ---------------------------------------------------------------------------
# F THE GLUE. Extracting the loop into a script created a NEW unreachable seam: the
# YAML lines that read its exit code. They are graded here by RUNNING THE SHIPPED
# BLOCK — fenced out of .github/workflows/version-assign.yml, never retyped, so a
# future edit to the step cannot drift past this arm the way a copy would.
#
# The trap being held shut: a `run:` with no `shell:` key runs under errexit, and
# `set -uo pipefail` does NOT turn it back off. Under `cmd; rc=$?`, errexit fires on the
# loop's own non-zero exit and the rc line never runs — so exit 3 ("nothing owed", the
# COMMON path on any doc-only merge) would escape as a red step. The arm asserts the
# contract by EXIT CODE for all three returns, not by reading the source.
#
# MEASURED IN THIS REPO rather than read from the docs, because this arm's whole premise
# is a claim about someone else's runner: throwaway branch ci-errexit-probe, run
# 30243567053 (2026-07-27 06:41, deleted after). A step with no `shell:` printed
# PROBE-START and then "Process completed with exit code 3" — the line after
# `bash -c "exit 3"; rc=$?` never ran. Its control step with an explicit `shell: bash`
# behaved IDENTICALLY, which is why the precondition below says a `shell:` key means
# "recheck the premise" and not "the premise is void": `shell: bash` still carries -e,
# so only a non-bash or flag-overriding shell would actually change the answer.
if grep -q '^ *shell:' "$REPO/.github/workflows/version-assign.yml"; then
  no "F precondition: the step now sets shell: — this arm's bash -e premise needs rechecking"
else
  ok "F precondition: the step declares no shell:, so GitHub runs it as 'bash -e {0}'"
fi

# Fence the block: the run: body of the assign step, dedented, expressions filled in.
awk '/^ *run: \|$/{grab=1; next} grab{ if ($0 ~ /^ *$/) {print ""; next} if ($0 !~ /^          /) exit; sub(/^          /,""); print }' \
  "$REPO/.github/workflows/version-assign.yml" > "$TMP/step.sh"
sed -i 's/\${{ github.event.before }}/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "$TMP/step.sh"
grep -q 'version-assign-push-loop.sh' "$TMP/step.sh" \
  && ok "F the fence caught the real step body (it calls the push loop)" \
  || no "F FENCE" "extraction produced nothing usable — the arm below would grade a stub, not the step"

# A sandbox where the step can run: stubbed git (only cat-file is reached), a stubbed
# push loop that returns the code under test, a stubbed gh, and a header to read.
mkstep(){ # $1=dir  $2=loop exit code  $3=optional step.sh override
  local d="$TMP/step-$1"; mkdir -p "$d/scripts" "$d/src" "$d/bin"
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$d/scripts/version-assign-push-loop.sh"
  printf 'readonly FIVE_VERSION="0.16.99"\n' > "$d/src/header.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/git";  printf '#!/usr/bin/env bash\necho "dispatched"\n' > "$d/bin/gh"
  chmod +x "$d/bin/git" "$d/bin/gh" "$d/scripts/version-assign-push-loop.sh"
  cp "${3:-$TMP/step.sh}" "$d/step.sh"; echo "$d"
}
runstep(){ ( cd "$1" && PATH="$1/bin:$PATH" bash -e ./step.sh >"$1/out" 2>&1 ); echo $?; }

d=$(mkstep owed3 3); rc=$(runstep "$d")
[[ "$rc" == 0 ]] \
  && ok "F 'nothing owed' (loop exit 3) leaves the step GREEN — the quiet common path stays quiet" \
  || no "F exit-3 leaks" "step exited $rc under bash -e; a doc-only merge would paint main red. $(cat "$d/out")"
d=$(mkstep fail1 1); rc=$(runstep "$d")
[[ "$rc" == 1 ]] \
  && ok "F a loud loop failure (exit 1) still FAILS the step — the fix did not soften it into a pass" \
  || no "F exit-1" "step exited $rc, expected 1"
d=$(mkstep ok0 0); rc=$(runstep "$d")
if [[ "$rc" == 0 ]] && grep -q 'dispatched' "$d/out"; then
  ok "F a successful assignment (exit 0) proceeds to the bundle-drift dispatch"
else
  no "F exit-0" "step exited $rc / dispatch not reached: $(cat "$d/out")"
fi

# F-MUT: put the ORIGINAL `; rc=$?` back and demand the exit-3 arm go red. Without
# this, all three arms above would keep passing under a shell that never had -e on,
# and would be grading nothing. (Positive control: exit 1 must stay red either way,
# so a red here is the errexit interaction and not a broken sandbox.)
sed 's@^rc=0; \(bash scripts/version-assign-push-loop.sh .*\) || rc=$?$@\1; rc=$?@' "$TMP/step.sh" > "$TMP/step-mut.sh"
if ! grep -q '3; rc=\$?' "$TMP/step-mut.sh"; then
  no "F-MUT could not re-introduce the '; rc=\$?' form — the arms above are ungraded"
else
  d=$(mkstep mut3 3 "$TMP/step-mut.sh"); rcm=$(runstep "$d")
  d=$(mkstep mut1 1 "$TMP/step-mut.sh"); rcc=$(runstep "$d")
  if [[ "$rcm" == 3 && "$rcc" == 1 ]]; then
    ok "F-MUT MUTATION: restoring '; rc=\$?' makes the exit-3 arm leak 3 (control: exit-1 still 1) — the arm grades the errexit seam, not the happy path"
  else
    no "F-MUT MUTATION" "mutant exited $rcm on 'nothing owed' (expected the 3 to leak) / $rcc on failure — arm F is not driven by the '|| rc=\$?'"
  fi
fi

# ---------------------------------------------------------------------------
# P ANCHOR EXPIRY. Arm F's precondition guards a premise about GitHub's RUNNER. The
# fixtures are a premise about GitHub's and git's WORDING, one layer out and with the
# same expiry shape: if GitHub rewords GH006, every arm above keeps passing against a
# capture that no longer resembles a real rejection, and the live path silently falls
# through to `unknown`. We cannot test against a real remote — exercising the
# protection branch means re-breaking main's protection — so the substitute is to
# record WHICH substrings the verdict actually rests on and red if they stop being
# load-bearing. It cannot detect a rewording at GitHub; it makes the fixture's
# dependence on specific bytes VISIBLE instead of implicit, so the recapture has an
# address. (Raised by Marcus in review of this branch.)
declare -A ANCHOR=(
  [protected-gh006.txt]='GH006|protected branch|required status check'
  [race-fetch-first.txt]='fetch first|Updates were rejected because'
  [race-non-fast-forward.txt]='non-fast-forward|Updates were rejected because'
)
declare -A ANCHOR_CLASS=(
  [protected-gh006.txt]=protection
  [race-fetch-first.txt]=race
  [race-non-fast-forward.txt]=race
)
for f in "${!ANCHOR[@]}"; do
  missing=""
  IFS='|' read -r -a as <<<"${ANCHOR[$f]}"
  for a in "${as[@]}"; do grep -qiF -- "$a" "$FIX/$f" || missing+="'$a' "; done
  if [[ -z "$missing" ]]; then
    ok "P $f still contains every recorded anchor (${ANCHOR[$f]//|/, })"
  else
    no "P $f LOST an anchor: $missing" "the capture no longer carries the text the classifier keys on — RECAPTURE it from a real rejection rather than editing the anchor list to match"
  fi
  # And prove the anchors are the WHOLE reason it matches: with all of them removed the
  # verdict must fall to 'unknown'. If it still classifies, some other substring is
  # carrying the match and the recorded anchor list is a fiction — which is exactly the
  # state that would let a GitHub rewording pass unnoticed.
  sed -E "s/(${ANCHOR[$f]})//Ig" "$FIX/$f" > "$TMP/stripped-$f"
  got=$(bash "$CLS" < "$TMP/stripped-$f")
  if [[ "$got" == unknown ]]; then
    ok "P $f: stripping the anchors drops it to 'unknown' — the recorded list IS what the ${ANCHOR_CLASS[$f]} verdict rests on"
  else
    no "P $f anchors are not load-bearing" "stripped of ${ANCHOR[$f]} it still reads '$got', so the recorded anchors are not what the classifier keys on and arm P grades nothing"
  fi
done

echo; echo "DIVE-2143 version-assign push classification: passed: $P  failed: $F"
[ "$F" -eq 0 ]
