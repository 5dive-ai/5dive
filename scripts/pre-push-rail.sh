#!/usr/bin/env bash
# DIVE-4208 — THE PRE-PUSH RAIL: run at the maker's desk what CI would red on in
# its first sixty seconds, plus the harnesses the diff actually touched.
#
# THE MEASUREMENT THAT FORCED IT (lodar, 2026-09-10): 3 of the 4 open PRs on
# 5dive-ai/5dive were red on a REQUIRED check. A red required check does not cost
# the fifteen minutes of CI wall clock people quote — it costs a verifier bounce
# plus a FRESH maker wake, ~20-45 min of reload (DIVE-4206), and it costs it
# again on every round. Two of that night's three reds were a 3-second title lint
# and one core shard. Both were runnable in the worktree the diff was written in.
#
# WHAT IT IS NOT. It is not a second test server. A second server adds a queue and
# a second environment to keep in sync with this one; the maker's worktree is
# already the test server and already has the diff in it. It is also not a copy of
# CI: the 5-minute core shards, docker-install and install-contract STAY in CI. The
# rail's ceiling is the first minute of CI plus the harnesses the diff touched.
#
# THE THREE STAGES, in order, first red refuses the push:
#
#   title       the PR-title lint, ~0s. The regex is EXTRACTED from
#               .github/workflows/pr-title-lint.yml at run time, never copied —
#               see title_stage(). Two lists is how a type the lint admits and the
#               cut rejects gets shipped (DIVE-4086's own defect, one level out).
#   lint        the changed files from the CI lint job's OWN file sets, with
#               the job's OWN flags including the DIVE-4067 SC2318 pass. Seconds,
#               because it is scoped to the diff rather than to src/*.sh entire —
#               that whole-tree pass is ~82s and stays in CI.
#   harnesses   scripts/changed-harnesses.sh (the same selector the CI job now
#               calls) run locally, wall-clock capped.
#
# EVERY STAGE FAILS OPEN, LOUDLY, WHEN ITS INSTRUMENT IS MISSING — no shellcheck
# binary, no workflow file to read the regex out of, no selector script. That is
# the settled shape of this repo's hooks (see the actionlint guard in
# scripts/git-hooks/pre-push): a guard that blocks every push on a tool nobody has
# installed is a guard that gets removed, and the CI job is still the hard gate.
# It does NOT fail open on a finding. "I could not run it" and "it passed" print
# differently and are never the same exit.
#
# THE CAP, AND WHAT IT DOES WHEN IT BITES. The harness stage stops starting new
# harnesses once FIVE_PUSH_RAIL_CAP seconds (default 360) have gone, PRINTS THE
# NAMES of what it did not run and the one command that runs them, and does not
# block on the truncation. A cap that silently dropped the tail would make a green
# rail mean "some of it passed", which is the shape of hole this row exists to
# close. A harness that RAN and failed always blocks, cap or no cap.
#
# THE OVERRIDE IS AUDITED. `git push --no-verify` skips every hook in the repo,
# says nothing, and leaves no trace on the PR — so the rail offers a route that
# does the same job and is visible:
#
#   FIVE_PUSH_OVERRIDE="$(cat reason.txt)" git push
#
# The reason must answer the same five questions `smoke-override` asks (see the
# projects CLAUDE.md): (1) why the check did not run; (2) what ran instead, with
# counts; (3) the residual the check uniquely covers; (4) why you sign it anyway;
# (5) what stays uncovered. A reason missing any of the five numbered clauses is
# REFUSED — an override contract that accepts "wip" is a --no-verify with extra
# steps. The accepted reason is printed into the push output and written to
# .git/5dive-push-override.log, so the next reader of that branch can find it.
#
# CONTRACT
#   usage: scripts/pre-push-rail.sh <base> <head> [--only=title|shellcheck|harnesses]
#   exit 0  every stage green (or failed open with a printed warning)
#   exit 1  a stage found something; the push must be refused
#   exit 2  usage error
set -uo pipefail

TOP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${1:-}"
HEAD_REV="${2:-HEAD}"
ONLY=""
for a in "${@:3}"; do
  case "$a" in
    --only=*) ONLY="${a#--only=}" ;;
    *) echo "pre-push-rail: unknown argument: $a" >&2; exit 2 ;;
  esac
done
[[ -n "$BASE" ]] || { echo "usage: scripts/pre-push-rail.sh <base> <head> [--only=STAGE]" >&2; exit 2; }

CAP="${FIVE_PUSH_RAIL_CAP:-360}"
rc=0
now_ms() { printf '%s' "$(( $(date +%s%N) / 1000000 ))"; }
RAIL_T0="$(now_ms)"

# Per-stage wall time, printed whether the stage passed or failed — the row asks
# for the rail to time ITSELF, because "it feels slow" is not a number anyone can
# act on and a rail nobody can price is a rail that gets ripped out.
stage_done() { # <name> <t0_ms> <verdict>
  printf 'pre-push-rail: %-11s %6.1fs  %s\n' "$1" "$(( $(now_ms) - $2 ))e-3" "$3" >&2
}

wants() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

# ── stage 1: title ────────────────────────────────────────────────────────────
#
# WHICH STRING IS GRADED. CI grades the PULL REQUEST title, which does not exist
# yet at push time. What it BECOMES is the squash subject, and GitHub seeds a new
# PR's title from the sole commit's subject when the branch has one commit. So the
# rail grades $PR_TITLE if the author states it, else the subject of the FIRST
# commit in the pushed range — the string GitHub will offer — and says which one it
# used, because a lint whose subject is ambiguous teaches nothing.
title_stage() {
  local t0 wf line title src
  t0="$(now_ms)"
  wf="$TOP/.github/workflows/pr-title-lint.yml"
  if [[ ! -f "$wf" ]]; then
    stage_done title "$t0" "SKIPPED — $wf not found; CI's title job is the net"
    return 0
  fi
  # EXTRACTED, NOT COPIED. The workflow's condition is the one authority on what
  # a valid title is; a second regex here would be a second author for the same
  # contract, and the failure mode is silent (the rail greens a title the merge
  # gate reds, or the reverse). tests/release_cut_assign_unit.sh already extracts
  # this same line rather than grading a copy of it.
  line="$(grep -m1 -F 'if [[ "$PR_TITLE" =~ ' "$wf" | sed 's/^[[:space:]]*//')"
  if [[ -z "$line" ]]; then
    stage_done title "$t0" "SKIPPED — could not extract the rule from pr-title-lint.yml; CI's title job is the net"
    return 0
  fi
  if [[ -n "${PR_TITLE:-}" ]]; then
    title="$PR_TITLE"; src="\$PR_TITLE"
  else
    # The FIRST commit of the range (oldest), which is the whole range on a
    # single-commit branch and is what GitHub offers as the title.
    title="$(git log --format='%s' "$BASE..$HEAD_REV" 2>/dev/null | tail -1)"
    src="the first commit subject in $BASE..$HEAD_REV"
  fi
  if [[ -z "$title" ]]; then
    stage_done title "$t0" "SKIPPED — no commit in the range and no \$PR_TITLE to grade"
    return 0
  fi
  if PR_TITLE="$title" eval "$line true; else false; fi"; then
    stage_done title "$t0" "ok — \"$title\" ($src)"
    return 0
  fi
  stage_done title "$t0" "RED"
  {
    echo "pre-push-rail/title: this title is not a conventional-commit subject, and main takes SQUASH merges — so it becomes the commit subject and release-cut reads it to decide whether the next cut is a feature or a patch (DIVE-4086)."
    echo "  got:  $title"
    echo "        (graded: $src)"
    echo "  want: feat|fix|test|chore|docs|refactor|ci|perf, an optional (scope), an optional ! for breaking, then a colon and a space"
    echo "  e.g.  feat(plugin): a declared plugin verb is now dispatched (DIVE-4035)"
    echo "  fix:  git commit --amend, or set the title you will give the PR: PR_TITLE='fix(x): ...' git push"
  } >&2
  return 1
}

# ── stage 2: shellcheck ───────────────────────────────────────────────────────
#
# The file SETS and the FLAGS are the `shellcheck` job's, in install-smoke.yml —
# two invocations per file, because --include=SC2318 restricts to the codes named
# and so cannot be folded into the -S error pass without losing error coverage
# (DIVE-4067's own note). What differs from CI is only the SCOPE: the changed
# files, not the whole set. The whole-set pass is ~82s and stays in CI, where it
# is the thing that catches a file this diff did not touch going bad.
shellcheck_stage() {
  local t0 f files=() shebang=() nosheb=() local_rc=0
  t0="$(now_ms)"
  if ! command -v shellcheck >/dev/null 2>&1; then
    stage_done shellcheck "$t0" "SKIPPED — shellcheck is not installed here; CI's shellcheck job is the net"
    return 0
  fi
  mapfile -t files < <(git diff --name-only --diff-filter=ACMR "$BASE" "$HEAD_REV" 2>/dev/null)
  for f in "${files[@]}"; do
    [[ -f "$TOP/$f" ]] || continue
    case "$f" in
      install.sh|5dive-agent-start|build.sh|5dive-stage-fork-plugins.sh|5dive-refresh-plugins.sh|5dive-refresh-skills.sh|scripts/*.sh)
        shebang+=("$f") ;;
      src/*.sh|src/task/*.sh)
        nosheb+=("$f") ;;
    esac
  done
  if (( ${#shebang[@]} + ${#nosheb[@]} == 0 )); then
    stage_done shellcheck "$t0" "ok — no linted shell file in this diff"
    return 0
  fi
  for f in "${shebang[@]}"; do
    ( cd "$TOP" && shellcheck -S error "$f" ) || local_rc=1
    ( cd "$TOP" && shellcheck --include=SC2318 "$f" ) || local_rc=1
  done
  for f in "${nosheb[@]}"; do
    ( cd "$TOP" && shellcheck -S error --shell=bash "$f" ) || local_rc=1
    ( cd "$TOP" && shellcheck --include=SC2318 --shell=bash "$f" ) || local_rc=1
  done
  if (( local_rc == 0 )); then
    stage_done shellcheck "$t0" "ok — $(( ${#shebang[@]} + ${#nosheb[@]} )) changed file(s) clean"
    return 0
  fi
  stage_done shellcheck "$t0" "RED"
  echo "pre-push-rail/shellcheck: findings above. SC2318 is a merge blocker at ANY severity (DIVE-4067) — 0.26.1 emptied every box on one of them." >&2
  return 1
}

# GIT'S HOOK ENVIRONMENT IS NOT INERT, AND IT REACHES THE HARNESSES.
#
# `git push` exports GIT_DIR (and friends) into every hook it runs, and GIT_DIR
# OUTRANKS `git -C <dir>`: a harness that builds a throwaway repo under mktemp
# and drives it with `git -C "$SB" ...` then operates on THE REAL REPO, silently.
# Measured on this rail's own first push: tests/pre_push_rail_unit.sh is 15/15 in
# a shell and 13/15 under the hook — A5 stopped seeing an unresolvable base
# (because the real repo HAS an origin/main to fall back to) and A8c wrote its
# override log into the real .git instead of the sandbox's. Neither failure is
# about the code under test, and both look exactly like one.
#
# So harnesses run with the repo-scoping variables REMOVED. This is not defensive
# tidying: without it the rail's verdict on any harness that touches a temp repo
# is about the wrong tree, and the class is invisible in CI, which runs harnesses
# from a plain shell and never sets these.
GIT_ENV_SCRUB=(env
  -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX
  -u GIT_COMMON_DIR -u GIT_NAMESPACE -u GIT_OBJECT_DIRECTORY
  -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_QUARANTINE_PATH
  -u GIT_INDEX_VERSION -u GIT_REFLOG_ACTION)

# ── stage 3: the harnesses this diff touched ──────────────────────────────────
harness_stage() {
  local t0 sel_rc files=() ran=0 local_rc=0 elapsed remaining=() h_rc
  t0="$(now_ms)"
  local sel="$TOP/scripts/changed-harnesses.sh"
  if [[ ! -f "$sel" ]]; then
    stage_done harnesses "$t0" "SKIPPED — $sel not found; CI's changed-harnesses job is the net"
    return 0
  fi
  mapfile -t files < <(cd "$TOP" && bash "$sel" "$BASE" "$HEAD_REV" 2>/dev/null); sel_rc=$?
  if (( sel_rc != 0 )); then
    # The selector's exit 1 means it could not resolve a base. Do NOT convert
    # that into "nothing changed" here; the whole reason it exits non-zero is so
    # its callers cannot.
    stage_done harnesses "$t0" "BLOCKED — the selector could not resolve a base to diff against"
    ( cd "$TOP" && bash "$sel" "$BASE" "$HEAD_REV" >/dev/null ) || true
    return 1
  fi
  if (( ${#files[@]} == 0 )); then
    stage_done harnesses "$t0" "ok — this diff touches no harness"
    return 0
  fi
  # The bundle is a harness PRECONDITION, declared rather than inherited from
  # whatever an earlier harness left in the tree (DIVE-2525): three harnesses read
  # ./5dive and ./5dive.sha256 and say so in their own failure text, and in a
  # worktree that has never built, a SUBSET run is exactly where that bites.
  if [[ ! -f "$TOP/5dive" || ! -f "$TOP/5dive.sha256" ]]; then
    ( cd "$TOP" && ./build.sh >/dev/null 2>&1 ) \
      || echo "pre-push-rail/harnesses: ./build.sh failed; harnesses that need the bundle may red for that reason." >&2
  fi
  # THE CAP HAS TO BOUND ONE HARNESS, not just the gaps between them. Measured
  # while timing this rail over the last 10 merges to main: the first range
  # touched seven gate harnesses, one of them a mutation harness, and a
  # between-harnesses check let a SINGLE file run past ten minutes with the cap
  # set to six. A cap that only decides whether to START the next one is a cap
  # in name and a promise the maker cannot plan around, which is how a rail
  # earns the reputation that gets it removed. So each harness gets the budget
  # that is actually left, through `timeout`.
  #
  # AND A TIMED-OUT HARNESS IS NOT A RED. rc 124 means "we did not find out",
  # which is a third outcome; folding it into either of the other two is the
  # class this repo keeps re-learning (tests/lib/grading_tree.sh). It is NAMED
  # in the un-run list and it does NOT refuse the push — CI grades it.
  local i left
  for (( i = 0; i < ${#files[@]}; i++ )); do
    elapsed=$(( ( $(now_ms) - t0 ) / 1000 ))
    left=$(( CAP - elapsed ))
    if (( left <= 0 )); then
      remaining=("${files[@]:$i}")
      break
    fi
    echo "=== ${files[$i]} (budget ${left}s)" >&2
    if command -v timeout >/dev/null 2>&1; then
      ( cd "$TOP" && "${GIT_ENV_SCRUB[@]}" timeout "${left}s" bash "${files[$i]}" ) >&2; h_rc=$?
    else
      ( cd "$TOP" && "${GIT_ENV_SCRUB[@]}" bash "${files[$i]}" ) >&2; h_rc=$?
    fi
    case "$h_rc" in
      0) ran=$(( ran + 1 )) ;;
      124) echo "NOT GRADED (over the remaining ${left}s budget): ${files[$i]}" >&2
           remaining+=("${files[$i]}") ;;
      *) echo "FAILED: ${files[$i]}" >&2; local_rc=1; ran=$(( ran + 1 )) ;;
    esac
  done
  if (( ${#remaining[@]} )); then
    # NAMES, not a count. A truncation reported as a number reads as "all of it
    # ran" to everyone who does not stop to compare it against the selection.
    {
      printf 'pre-push-rail/harnesses: OVER THE %ss CAP after %d harness(es) — these were NOT GRADED here and CI is what grades them:\n' "$CAP" "$ran"
      printf '  %s\n' "${remaining[@]}"
      printf '  run them by hand:  bash %s\n' "${remaining[*]}"
      printf '  or raise the cap:  FIVE_PUSH_RAIL_CAP=900 git push\n'
    } >&2
  fi
  if (( local_rc == 0 )); then
    stage_done harnesses "$t0" "ok — $ran/${#files[@]} changed harness(es) green"
    return 0
  fi
  stage_done harnesses "$t0" "RED — a harness this diff touches fails here, and will fail the same way in CI"
  return 1
}

# ── the audited override ──────────────────────────────────────────────────────
#
# Checked BEFORE any stage runs: the point of an override is to not pay for the
# rail, and a "override" that still runs everything first is a slower push, not an
# escape. It is refused unless the reason answers all five questions, and the
# accepted reason is printed and logged so it is findable from the branch.
override_taken() {
  local reason="${FIVE_PUSH_OVERRIDE:-}" n missing=()
  [[ -n "$reason" ]] || return 1
  for n in 1 2 3 4 5; do
    grep -qE "(^|[^0-9])${n}[).:]" <<<"$reason" || missing+=("$n")
  done
  if (( ${#missing[@]} )); then
    {
      echo "pre-push-rail: OVERRIDE REFUSED — the reason is missing clause(s): ${missing[*]}."
      echo "  An override contract that accepts 'wip' is a --no-verify with extra steps, so this one is graded."
      echo "  Write five numbered clauses, the same five smoke-override asks for:"
      echo "    1) why the check did not run here"
      echo "    2) what ran instead, with counts, on the tree you are pushing"
      echo "    3) the residual the check uniquely covers, which you are signing"
      echo "    4) why you sign it anyway"
      echo "    5) what stays uncovered"
    } >&2
    exit 1
  fi
  {
    echo "pre-push-rail: OVERRIDDEN — the rail did not run. Signed reason:"
    printf '%s\n' "$reason" | sed 's/^/  | /'
  } >&2
  local log; log="$(git rev-parse --git-common-dir 2>/dev/null)/5dive-push-override.log"
  { date -u +'%Y-%m-%dT%H:%M:%SZ'; printf 'range %s..%s\n' "$BASE" "$HEAD_REV"; printf '%s\n\n' "$reason"; } >>"$log" 2>/dev/null || true
  return 0
}

if override_taken; then exit 0; fi

wants title      && { title_stage      || rc=1; }
(( rc == 0 )) && wants shellcheck && { shellcheck_stage || rc=1; }
(( rc == 0 )) && wants harnesses  && { harness_stage    || rc=1; }

printf 'pre-push-rail: %-11s %6.1fs  %s\n' TOTAL "$(( $(now_ms) - RAIL_T0 ))e-3" \
  "$( (( rc == 0 )) && echo 'green' || echo 'REFUSING THE PUSH' )" >&2
if (( rc != 0 )); then
  {
    echo "pre-push-rail: this push is refused because a check that gates the merge is red HERE, where the fix is cheap."
    echo "  The same red in CI costs a verifier bounce plus a fresh maker wake (~20-45 min, DIVE-4206), on every round."
    echo "  Audited escape (visible on the branch, unlike --no-verify):"
    echo "    FIVE_PUSH_OVERRIDE=\"\$(cat reason.txt)\" git push     # five numbered clauses required"
  } >&2
fi
exit "$rc"
