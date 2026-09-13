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
# THE FOUR STAGES, in order, first red refuses the push:
#
#   title       the PR-title lint, ~0s. The regex is EXTRACTED from
#               .github/workflows/pr-title-lint.yml at run time, never copied —
#               see title_stage(). Two lists is how a type the lint admits and the
#               cut rejects gets shipped (DIVE-4086's own defect, one level out).
#   fragment    the changelog-fragment lint, ~0s — the SECOND step of that same
#               required `title` context, and the one with no local arm until
#               DIVE-4336. It runs scripts/lint-changelog-fragments.sh, the exact
#               script CI runs, against this push's own range. See fragment_stage().
#   lint        the changed files from the CI lint job's OWN file sets, with
#               the job's OWN flags including the DIVE-4067 SC2318 pass. Seconds,
#               because it is scoped to the diff rather than to src/*.sh entire —
#               that whole-tree pass is ~82s and stays in CI.
#   harnesses   scripts/changed-harnesses.sh (the same selector the CI job now
#               calls) run locally, wall-clock capped.
#
# THE TWO DOOR CHECKS BOTH RUN before either timed stage, and that is the one
# place "first red refuses" is relaxed. Both are ~0s and both report on the same
# required context, so refusing on the title alone would hand back a title fix,
# take the re-push, and only THEN mention the missing fragment — two rounds to
# report two facts that cost nothing to learn together. The timed stages still
# stop at the first red.
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
# steps. The accepted reason is printed into the push output and written to a log
# whose path is printed with it: .git/5dive-push-override.log when you run the push
# yourself, and the root-owned /var/log/5dive/push-override.log when root runs it
# for you (a delegated push) — root must not write into a checkout whose paths an
# agent controls. See override_taken().
#
# CONTRACT
#   usage: scripts/pre-push-rail.sh <base> <head> [--only=title|fragment|shellcheck|harnesses]
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

# WIDEN TO THE PR RANGE. `git push` hands a hook the PUSH range (the remote's
# current tip), but every CI job this rail stands in for grades the PULL REQUEST
# range — `changed-harnesses` diffs the PR base sha, and so do the title and
# lint jobs. On the FIRST push of a branch those coincide; on the second
# they do not, and the difference is silent in the worst direction: a follow-up
# commit that only MODIFIES is graded here against a base that already contains
# the harness an earlier commit ADDED, so the corpus-wide contracts are not
# selected, the rail greens, and CI reds on the wider range. That is the same
# defect class as the selector's (a set chosen narrower than the merge gate's),
# reached by a different route, and it is why this widening lives here rather
# than in the hook: it is the rail's contract to grade what the gate will grade.
#
# Only ever widens: the merge base must be a real ancestor of the pushed base.
# Pushing main itself leaves this alone (the merge base IS the remote tip), and
# a repo with no origin/main keeps the base it was handed.
if mb="$(git merge-base origin/main "$HEAD_REV" 2>/dev/null)" && [[ -n "$mb" ]] \
   && [[ "$mb" != "$BASE" ]] && git merge-base --is-ancestor "$mb" "$BASE" 2>/dev/null; then
  echo "pre-push-rail: widening base $(git rev-parse --short "$BASE" 2>/dev/null || echo "$BASE") -> $(git rev-parse --short "$mb") (the PR range CI grades, not the push range)." >&2
  BASE="$mb"
fi

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

# ── WHICH STRING THE DOOR CHECKS GRADE ────────────────────────────────────────
#
# CI grades the PULL REQUEST title, which does not exist yet at push time. What it
# BECOMES is the squash subject, and GitHub seeds a new PR's title from the sole
# commit's subject when the branch has one commit. So the rail grades $PR_TITLE if
# the author states it, else the subject of the FIRST commit in the pushed range —
# the string GitHub will offer — and says which one it used, because a lint whose
# subject is ambiguous teaches nothing.
#
# RESOLVED ONCE, for both stages. The title stage grades the string itself; the
# fragment stage reads the TYPE out of it, because a feat/fix owes a fragment and a
# chore does not. Two resolutions would let the two halves of one required context
# disagree about which change this even is.
TITLE=""; TITLE_SRC=""; TITLE_RESOLVED=""
resolve_title() {
  [[ -n "$TITLE_RESOLVED" ]] && return 0
  TITLE_RESOLVED=1
  if [[ -n "${PR_TITLE:-}" ]]; then
    TITLE="$PR_TITLE"; TITLE_SRC="\$PR_TITLE"
  else
    # The FIRST commit of the range (oldest), which is the whole range on a
    # single-commit branch and is what GitHub offers as the title.
    TITLE="$(git log --format='%s' "$BASE..$HEAD_REV" 2>/dev/null | tail -1)"
    TITLE_SRC="the first commit subject in $BASE..$HEAD_REV"
  fi
}

# ── stage 1: title ────────────────────────────────────────────────────────────
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
  resolve_title
  title="$TITLE"; src="$TITLE_SRC"
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

# ── stage 2: the changelog fragment ───────────────────────────────────────────
#
# DIVE-4336 — THE ONE REQUIRED CHECK WITH NO LOCAL ARM. Measured 2026-09-11 while
# grading the day's queue: six PRs (#882 #894 #895 #897 #898 #899) red on the
# required `title` context, every one of them on DIVE-4177's fragment step and
# NONE on the conventional-type arm above. Six makers in one day is not six
# mistakes — nothing on the box knew the rule, so the first thing that ever said
# so was a required context, minutes later, after the maker had correctly
# delivered and moved on. Each firing then spent a verifier round to report one
# missing file, and the grader lane is the fleet's measured bottleneck
# (DIVE-4322). The fix is not a wider gate: the check is right every single time
# and a release-notes reader genuinely has nothing to read without the fragment.
# Only the PLACE it is discovered is wrong, and this stage moves that place.
#
# IT RUNS THE SCRIPT CI RUNS. Not a reimplementation: the rule has an
# exact-string requirement — the precise heading the release fold demands, which
# this file deliberately does not restate, because a second copy of it here would
# BE the drift; tests/pre_push_rail_unit.sh A22 asserts the string appears in the
# lint script and nowhere in this one. Two copies of an exact-string rule diverge
# silently in the worst direction: the rail greens what the merge gate reds, or
# the reverse. Same argument, and the same shape, as the title stage extracting
# its regex instead of forking it. A18-A25 pin this stage, A23 by MUTATING the
# lint script in a sandbox and requiring this stage's verdict to move with it.
#
# WHICH TREE THE HEADING RULE READS. The lint opens each changed changelog.d/*.md
# from the WORKING TREE, as the CI step reads them from its checkout of the head
# sha. In a pre-push hook those are the same tree in every normal case; where they
# are not, CI is still the hard gate. Same standing caveat as shellcheck below.
fragment_stage() {
  local t0 lint changed out lrc summary
  t0="$(now_ms)"
  lint="$TOP/scripts/lint-changelog-fragments.sh"
  if [[ ! -f "$lint" ]]; then
    stage_done fragment "$t0" "SKIPPED — $lint not found; CI's fragment step is the net"
    return 0
  fi
  resolve_title
  if [[ -z "$TITLE" ]]; then
    stage_done fragment "$t0" "SKIPPED — no commit in the range and no \$PR_TITLE, so there is no type to grade the fragment rule against"
    return 0
  fi
  changed="$(mktemp)"
  # --diff-filter=d, the CI step's own filter: a fragment DELETED by this PR is
  # not graded, because deleting it is how an entry gets withdrawn.
  if ! git diff --name-only --diff-filter=d "$BASE" "$HEAD_REV" >"$changed" 2>/dev/null; then
    rm -f "$changed"
    # NOT a skip. The CI step refuses here for the same reason: "I could not read
    # the change" must not print as "the change is clean" (tests/lib/grading_tree.sh).
    stage_done fragment "$t0" "BLOCKED — could not diff $BASE..$HEAD_REV; refusing to report a fragment lint that graded nothing"
    return 1
  fi
  out="$( cd "$TOP" && bash "$lint" --title="$TITLE" --changed-from="$changed" 2>&1 )"; lrc=$?
  rm -f "$changed"
  case "$lrc" in
    0)
      summary="$(grep -v '^::' <<<"$out" | tail -1)"
      stage_done fragment "$t0" "${summary:-ok} (title graded: $TITLE_SRC)"
      # The lint WARNS and exits 0 for a test|ci|chore|docs|refactor|perf PR with
      # no fragment. Print it: that warning is the whole of what the check has to
      # say about this push, and a rail quieter than the CI step it stands in for
      # teaches the maker that local green means CI green when it does not.
      grep '^::warning' <<<"$out" >&2 || true
      return 0
      ;;
    1)
      stage_done fragment "$t0" "RED"
      printf '%s\n' "$out" >&2
      {
        echo "pre-push-rail/fragment: this is the same step of the required \`title\` context that red six PRs on 2026-09-11 (DIVE-4336), and it is the cheapest red in the repo to clear — the fix is one file, here, now."
        echo "  The \`::error\`/\`::warning\` prefixes above are GitHub's annotation syntax: that text is verbatim what CI would print on this push."
        echo "  graded: the title \"$TITLE\" ($TITLE_SRC), against the changelog.d/ paths in $BASE..$HEAD_REV"
      } >&2
      return 1
      ;;
    *)
      # A usage error is a broken INSTRUMENT, not a finding, and the rail's settled
      # shape is to fail open loudly on those and let the CI step be the gate.
      stage_done fragment "$t0" "SKIPPED — the fragment lint could not run (exit $lrc); CI's fragment step is the net"
      printf '%s\n' "$out" >&2
      return 0
      ;;
  esac
}

# ── stage 3: shellcheck ───────────────────────────────────────────────────────
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

# ── stage 4: the harnesses this diff touched ──────────────────────────────────
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
  # DIVE-4288 (iteration 2, main2's finding): WHO IS WRITING DECIDES WHERE.
  #
  # On a delegated push this function runs as ROOT, inside `_push_do`'s git push,
  # and <git-common-dir> is inside a checkout THE SIGNING AGENT OWNS. Iteration 1
  # made this append reachable root-side for the first time — on `main` the reason
  # never crosses the sudo boundary, so the branch never fires — and therefore
  # inherited its safety: the agent controls the PATH, and `>>` writes THROUGH a
  # symlink into the target and leaves the link intact. Root would be appending
  # agent-supplied text to any file root can write.
  #
  # The fix is NOT a symlink guard on the crossing. It is to DELETE the crossing:
  # when the writer is root, the receipt goes to a root-owned directory no agent
  # can create a path in (/var/log/5dive is root:claude 2750 — group read and
  # traverse, no group write), and the PATH IS PRINTED. "Findable from the seat
  # that signed it" is the whole of what this log owes, and a printed path to a
  # 0640 root:claude file — readable by every seat, writable by none — pays it
  # without root ever touching agent-controlled space. See
  # community/wiki/a-fix-that-makes-a-path-root-reachable-inherits-that-paths-safety.md
  #
  # Keyed on EUID as well as FIVE_PUSH_DELEGATED: the hazard is "root is the
  # writer", not "the CLI said so", and a root-run `git push` in an agent checkout
  # has the same shape with none of the flags set.
  local log
  if [[ ${EUID:-$(id -u)} -eq 0 || -n "${FIVE_PUSH_DELEGATED:-}" ]]; then
    log="/var/log/5dive/push-override.log"
    [[ ${EUID:-$(id -u)} -eq 0 ]] && mkdir -p /var/log/5dive 2>/dev/null
  else
    log="$(git rev-parse --git-common-dir 2>/dev/null)/5dive-push-override.log"
  fi
  # umask 027 so a root-created receipt lands 0640 in that setgid root:claude dir:
  # every seat can READ the signature it is told to look for, none can rewrite it.
  if ( umask 027; { date -u +'%Y-%m-%dT%H:%M:%SZ'; printf 'range %s..%s\n' "$BASE" "$HEAD_REV"; printf '%s\n\n' "$reason"; } >>"$log" 2>/dev/null ); then
    # NAME THE PATH, on both branches and on the failure branch too: a receipt
    # nobody can locate is not an audit trail, and this line is the only thing
    # that makes the root-side log findable from the seat that signed it.
    echo "  logged to: ${log}" >&2
  else
    echo "  NOT LOGGED — could not append to ${log}. The reason above is the only record; it is in this push's output." >&2
  fi
  return 0
}

if override_taken; then exit 0; fi

# BOTH DOOR CHECKS RUN, then the timed stages stop at the first red. See "THE TWO
# DOOR CHECKS BOTH RUN" at the top of this file: they are both ~0s and both report
# on the same required context, and refusing on the title alone would cost a whole
# extra push round to report a fact that was free to learn at the same moment.
wants title      && { title_stage      || rc=1; }
wants fragment   && { fragment_stage   || rc=1; }
(( rc == 0 )) && wants shellcheck && { shellcheck_stage || rc=1; }
(( rc == 0 )) && wants harnesses  && { harness_stage    || rc=1; }

printf 'pre-push-rail: %-11s %6.1fs  %s\n' TOTAL "$(( $(now_ms) - RAIL_T0 ))e-3" \
  "$( (( rc == 0 )) && echo 'green' || echo 'REFUSING THE PUSH' )" >&2
if (( rc != 0 )); then
  {
    echo "pre-push-rail: this push is refused because a check that gates the merge is red HERE, where the fix is cheap."
    echo "  The same red in CI costs a verifier bounce plus a fresh maker wake (~20-45 min, DIVE-4206), on every round."
    echo "  Audited escape (visible on the branch, unlike --no-verify):"
    # DIVE-4288: PRINT THE ESCAPE THIS READER CAN ACTUALLY TAKE. Both of the
    # routes above assume the reader runs `git push` themselves. On a delegated
    # push they do not and cannot — the seat holds no git credential, which is the
    # point of the delegated rail — so root's `_push_do` sets FIVE_PUSH_DELEGATED
    # before it runs the push that triggers this hook. Advice that names a command
    # the reader's seat cannot run is not a weaker escape, it is a dead end: it
    # sent DIVE-4282 to "hand the branch to a credentialed seat or edit the red
    # gate", and editing the gate mid-ship is the one move this repo forbids.
    if [[ -n "${FIVE_PUSH_DELEGATED:-}" ]]; then
      echo "    FIVE_PUSH_OVERRIDE=\"\$(cat reason.txt)\" 5dive push ${FIVE_PUSH_TASK:-<row>}"
      echo "  This push was DELEGATED: your seat holds no git credential of its own, so a direct push — and --no-verify with it — is not a route you can take."
      echo "  The reason rides the same channel as the push parameters and is graded ROOT-side — five numbered clauses, the same contract."
    else
      echo "    FIVE_PUSH_OVERRIDE=\"\$(cat reason.txt)\" git push     # five numbered clauses required"
    fi
  } >&2
fi
exit "$rc"
