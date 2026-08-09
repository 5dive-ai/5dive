#!/usr/bin/env bash
# TIER: nightly — 174.1s measured (CI pristine, 2026-08-03, PR #395 attempt 1): priced by the network, not by its assertions, so a wall-clock cap cannot budget it.
#
# THE DEMOTION ARGUMENT, because a demotion nobody has to justify is a second budget
# nobody watches. The SAME file with the SAME assertions cost 174.1s on that run, 57.5s
# on main in CI four hours earlier, and 2.4s on the control plane (agent-dev, same day,
# 18 passed / 0 failed). Nothing in the file changed between those three readings. Its
# WHICH READING THE DECISION RESTS ON, because three figures from three environments
# are three different claims and a demotion argued on the wrong one is argued on
# nothing (olivia, grading DIVE-2592). It rests on 57.5s — the CI reading on MAIN,
# the ordinary case, the one that is charged to every PR on a good day. 174.1s is the
# tail and shows the SPREAD, not the cost; on its own it would be an argument from an
# outlier. 2.4s on the control plane is not evidence for demotion at all — it is the
# CONTROL that rules out the alternative explanation, because a file that costs 2.4s
# here and 57.5s there is not an expensive file, it is an environment-priced one, and
# that is the difference between "merge or retire this" and "a wall-clock cap is the
# wrong instrument for it". Even at the ordinary reading it is 19% of the entire 300s
# core; the demotion would still be right if the 174.1s tail had never happened.
#
# Its cost is REMOTE RESOLUTION: arm C verifies that every pinned baseline is a commit that
# resolves HERE, and a pin absent from the local object store falls back to
# `git fetch origin <sha>` — one network round trip to github.com per unresolved pin.
# So its wall-clock is a property of the runner's link, not of the corpus, which makes
# it UNBUDGETABLE IN A WALL-CLOCK CAP BY CONSTRUCTION rather than merely expensive: at
# its high end it is 58% of the entire 300s PR core on its own, and it red-flagged PR
# #395 on content that never touched it (DIVE-2592).
#
# WHAT THE DEMOTION COSTS, said plainly rather than left for the next reader to find: a
# PR that introduces a NEW branch-ref baseline is now caught by the nightly sweep rather
# than at review time. That is the whole loss. The nightly still runs this file every
# day, `changed-harnesses` still runs it on any diff that touches it, and arm C's own
# subject — that a pin resolves in the environment that gates the merge — is graded in
# the environment that has always had the full history (full-sweep checks out depth 0).
#
# DIVE-2229 unit: a test baseline must name a COMMIT, and it must RESOLVE in the
# environment that gates the merge.
#
# THE CLASS. Two harnesses took their "before" from `origin/main`. That ref is
# correct exactly until the fix merges — after which origin/main IS the post-fix
# tree, and the anchor compares post to post:
#
#   - on a DID-CHANGE assertion it goes red on main for a reason unrelated to the
#     code under test (measured: "fix did not increase distinguishable decisions
#     (3 -> 3)" on heartbeat_tier_guard_unmeasured_unit.sh after DIVE-2213);
#   - on a MUST-NOT-CHANGE assertion it goes VACUOUS-PASS and never announces
#     itself. `envelope_tier() is byte-identical to origin/main` was the arm
#     olivia cited as proof DIVE-2210's wire format was unmoved, and by then it
#     was comparing a file to itself.
#
# The second half is independent and hits the FIX too: `actions/checkout@v4`
# defaults to depth 1, and neither a branch ref nor a pinned commit resolves in a
# depth-1 tree. On a true depth-1 clone the suite read 36 passed, 0 failed,
# 2 SKIPPED where a full checkout reads 41/0/0 — so those arms had never once run
# in CI, and every past green there was 36+2. A skip is NOT-REACHED, not green.
# Fixing only the pin leaves the anchors decisive on a laptop, which is the one
# place they gate nothing; fixing only the depth leaves them vacuous everywhere.
#
# ENUMERATED BY TARGET, NOT BY PATTERN. `git grep -l origin/main tests/` returns
# 9 files, and 7 of them are not instances: comments, and harnesses that build a
# THROWAWAY repo and legitimately `git update-ref refs/remotes/origin/main` in
# it. Fencing all 9 would have "fixed" seven non-bugs and taught the next reader
# that the shape is the rule. The rule is: a git read that resolves a ref against
# THIS repository, where the ref is a BRANCH.
#
# Isolated: reads files, runs git only against fixtures it creates. No root, no
# network, never the live tasks.db.
#   bash tests/baseline_pin_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; return 0; }

TMP="$(mktemp -d /tmp/baseline-pin.XXXXXX)"

# DIVE-2525: the suite that anchors to pinned commits is no longer run by ONE
# workflow. unit-tests.yml runs the CORE tier on every PR; full-sweep.yml runs the
# whole corpus nightly, which is where a DEMOTED pinned-baseline harness now lives.
# Arm D must sweep both, or it grades the fetch-depth of a workflow that no longer
# runs the harnesses whose pins it exists to protect — the check would still be
# green and would have stopped covering the thing that moved.
WFS=(.github/workflows/unit-tests.yml .github/workflows/full-sweep.yml)

# ---------------------------------------------------------------------------
# The detector. One function, used on the real corpus AND on synthetic fixtures,
# so the mutation arm below grades the SAME code the verdict arms use.
#
# A line is an instance when it reads a blob/tree out of THIS repo (`git show`,
# `git rev-parse`, `git diff`, `git log`, `git merge-base`) naming a BRANCH ref.
# `git -C <somewhere>` is excluded by construction: that is a throwaway fixture
# repo, and its refs are ones the harness just wrote itself.
# ---------------------------------------------------------------------------
branch_baselines() {   # <file> -> matching "line:text", empty if clean
  grep -nE '(^|[^-])git (show|rev-parse|diff|log|merge-base)[^|;&]*(origin/(main|master)|FETCH_HEAD)' "$1" \
    | grep -v 'git -C' \
    | grep -vE '^\s*[0-9]+:\s*#'
}

# --- Arm A: the detector FIRES on the shape (liveness). Without this, arm B's
#     "no file matched" is equally consistent with a detector that matches
#     nothing at all — the exact vacuity this ticket is about.
# The fixture is ASSEMBLED, never written literally, because this file is itself
# inside the corpus arm B sweeps: a literal `git show origin/<branch>` here would
# make the harness its own only offender. Excluding this file from the sweep
# instead would carve out the one place a real instance could then hide.
_B="ma""in"
printf '#!/usr/bin/env bash\nold="$(git show origin/%s:src/lib/registry.sh)"\n' "$_B" > "$TMP/positive.sh"
if [[ -n "$(branch_baselines "$TMP/positive.sh")" ]]; then
  ok_t "detector FIRES on a synthetic \`git show origin/${_B}:<path>\` — arm B is a real measurement"
else
  bad_t "detector is DEAD" "it did not match the canonical instance, so 'no harness matched' below would be vacuous"
fi

# --- Arm A2: and it does NOT fire on the two legitimate shapes, or the fence is
#     a nuisance that the next author will disable rather than obey.
{ printf '#!/usr/bin/env bash\n'
  printf '# a comment mentioning git show origin/%s is not an instance\n' "$_B"
  printf 'git -C "$REPO3" update-ref refs/remotes/origin/%s %s\n' "$_B" "$_B"
  printf 'git -C "$REPO3" show origin/%s:f\n' "$_B"
} > "$TMP/negative.sh"
if [[ -z "$(branch_baselines "$TMP/negative.sh")" ]]; then
  ok_t "detector is SILENT on comments and on throwaway-repo \`git -C\` refs — enumerated by target, not by pattern"
else
  bad_t "detector over-matches" "$(branch_baselines "$TMP/negative.sh")"
fi

# --- Arm B: the corpus. Non-vacuity first: a scan of zero files passes trivially.
mapfile -t CORPUS < <(ls tests/*.sh tests/lib/*.sh 2>/dev/null)
if (( ${#CORPUS[@]} >= 20 )); then
  ok_t "scanned ${#CORPUS[@]} harness files — the sweep below has a denominator"
else
  bad_t "corpus is too small to be the real one" "found ${#CORPUS[@]} files under tests/; a near-empty sweep cannot support 'none of them'"
fi
offenders=""
for f in "${CORPUS[@]}"; do
  hits="$(branch_baselines "$f")"
  [[ -n "$hits" ]] && offenders="${offenders}${f}: ${hits}"$'\n'
done
if [[ -z "$offenders" ]]; then
  ok_t "no harness derives a baseline from a BRANCH ref against this repo (pin the commit — tests/lib/pinned_baseline.sh)"
else
  bad_t "a baseline is named by a branch, so it moves when the fix merges" "$offenders"
fi

# --- Arm C: the pins that exist must be real commits AND must not be the tip.
#     A pin that happens to equal current HEAD is a moving baseline wearing a
#     sha, and it is what you get by pinning during the merge that lands it.
head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
pins="$(grep -rhoE '^[A-Z_]*REF="[0-9a-f]{7,40}"' tests/*.sh | grep -oE '[0-9a-f]{7,40}' | sort -u)"
if [[ -n "$pins" ]]; then
  ok_t "harnesses declare $(wc -w <<<"$pins") pinned baseline commit(s)"
  for p in $pins; do
    # AN ABBREVIATED PIN KILLS THE FALLBACK. `git fetch origin e32fab8` is
    # rejected with "couldn't find remote ref" — a remote will serve a full
    # object name and nothing shorter. So a 7-char pin leaves
    # pinned_baseline.sh's shallow-tree recovery as DEAD CODE: the arm reds on
    # every shallow checkout while reading, on a full one, exactly as it should.
    # Found by running the fallback, not by reading it.
    if (( ${#p} != 40 )); then
      bad_t "pinned baseline $p is abbreviated (${#p} chars)" "the shallow-tree fetch in tests/lib/pinned_baseline.sh cannot ask a remote for an abbreviated sha, so the recovery path never runs; use the full 40-char object name"
      continue
    fi
    if ! git rev-parse --verify -q "${p}^{commit}" >/dev/null 2>&1; then
      # Not a failure of the PIN — a shallow tree cannot see it. Arm D owns that.
      printf '#    pin %s not present in this (possibly shallow) checkout\n' "$p"
      continue
    fi
    if [[ "$(git rev-parse "$p")" == "$head_sha" ]]; then
      bad_t "pinned baseline $p IS HEAD" "comparing the tree to itself; pick the commit BEFORE the change under test"
    else
      ok_t "pin $p resolves to a commit that is not HEAD"
    fi
  done
else
  bad_t "no pinned baselines found" "the two harnesses this ticket repaired should declare *_REF=\"<sha>\"; the grep found none, so this arm is scanning the wrong thing"
fi

# --- Arm D: the CI half. Every checkout in the workflow that runs the suite must
#     ask for full history, or the pins above resolve nowhere that gates a merge.
for WF in "${WFS[@]}"; do
if [[ -f "$WF" ]]; then
  n_checkout="$(grep -c 'uses: actions/checkout@' "$WF")"
  n_depth="$(grep -c 'fetch-depth: 0' "$WF")"
  if (( n_checkout > 0 )); then
    ok_t "$WF has $n_checkout checkout step(s) to account for"
  else
    bad_t "no checkout steps found in $WF" "the parse is wrong, not the workflow"
  fi
  if (( n_depth >= n_checkout && n_checkout > 0 )); then
    ok_t "every checkout in $WF sets fetch-depth: 0 ($n_depth/$n_checkout) — pinned baselines resolve where the merge is gated"
  else
    bad_t "a checkout in $WF is depth-1" "$n_depth of $n_checkout steps set fetch-depth: 0; at depth 1 no pinned commit resolves and the baseline arms report NOT-REACHED, which reads as green"
  fi
else
  bad_t "$WF is missing" "the CI half of this ticket cannot be asserted"
fi
done

# --- Arm E: the helper must FAIL CLOSED. An unresolvable pin returning success
#     (or an empty file that compares equal to an empty extraction) is how this
#     whole class re-enters through its own fix.
if . tests/lib/pinned_baseline.sh 2>/dev/null; then
  ok_t "tests/lib/pinned_baseline.sh is sourceable"
  if pinned_blob "0000000000000000000000000000000000000000" src/cmd_task.sh "$TMP/nope" 2>/dev/null; then
    bad_t "pinned_blob reported SUCCESS for an unresolvable commit" "callers would compare against whatever it left behind"
  else
    ok_t "pinned_blob REFUSES an unresolvable commit (non-zero, no output file)"
  fi
  [[ ! -e "$TMP/nope" ]] \
    && ok_t "pinned_blob left no partial file behind on refusal" \
    || bad_t "pinned_blob wrote a file it could not fill" "$(wc -c < "$TMP/nope") bytes at $TMP/nope"
  # A resolvable commit with a path that does not exist there is a DIFFERENT
  # failure and must not be laundered into "baseline unavailable".
  if pinned_blob HEAD "no/such/path/at/all.sh" "$TMP/nopath" 2>/dev/null; then
    bad_t "pinned_blob reported SUCCESS for a missing path at a resolvable ref" "an empty baseline compares equal to an empty extraction"
  else
    ok_t "pinned_blob REFUSES a missing path at a resolvable ref"
  fi

  # --- Arm E2: AN EMPTY DIFF IS NOT A CLEAN DIFF. olivia's scope check on this
  #     very branch ran `git diff --name-only origin/main...origin/<branch>`
  #     before the branch was pushed, got nothing, and its out-of-scope grep
  #     reported "none out of scope — claim HOLDS". A comparison against a ref
  #     that is not there announces SUCCESS rather than ABSENCE. Measure the
  #     naive form failing, then the guarded form refusing, in one arm — the
  #     mutation is differential or it proves nothing.
  ABSENT="dead0dead0dead0dead0dead0dead0dead0dead0"
  naive="$(git diff --name-only "$ABSENT" 2>/dev/null | grep -vE '^(tests/|\.github/)' || true)"
  if [[ -z "$naive" ]]; then
    ok_t "REPRODUCED: an out-of-scope filter over a diff against an absent ref reports CLEAN on zero evidence"
  else
    bad_t "could not reproduce the empty-diff vacuity" "the naive form returned '$naive' — this arm is grading something else and its verdict below is not about the defect"
  fi
  if pinned_diff "$ABSENT" --name-only >/dev/null 2>&1; then
    bad_t "pinned_diff reported SUCCESS against an absent ref" "callers would read its empty output as 'nothing out of scope'"
  else
    ok_t "pinned_diff REFUSES an absent ref instead of returning an empty diff that satisfies every filter"
  fi
else
  bad_t "tests/lib/pinned_baseline.sh not sourceable" "the shared fail-closed resolver is the fix; without it each caller re-invents the skip"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
