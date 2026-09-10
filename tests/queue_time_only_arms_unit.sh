#!/usr/bin/env bash
# DIVE-4186 — the queue-time-only split, graded as text.
#
# TIER: core — ~0.3s (grep/awk over .github/workflows, no network, no build).
#
# WHAT THIS EXISTS FOR. DIVE-4139 put a merge queue in front of main, so the required
# status checks are graded on the `gh-readonly-queue/main/...` merge group. That made the
# `pull_request` arm of the installed-host tier a SECOND full grade of the same tree
# (~1551 job-s per PR, measured on batch #834), and this row deleted it. The deletion is
# implemented as a per-job `if: github.event_name != 'pull_request'`, and its failure mode
# is invisible in both directions:
#
#   * REMOVE the guard and the duplication silently comes back — nothing goes red, CI just
#     costs what it used to.
#   * ADD the guard to a job that is NOT queue-time-only and a maker stops learning they
#     broke it until the PR is enqueued, where a red costs the whole batch. Also not red.
#
# So the split is pinned here by NAME, in both directions, rather than left to a comment.
#
# THE HAZARD THIS HARNESS MAKES VISIBLE, and it is the reason for arm 3: a job skipped by
# an `if:` reports the conclusion `skipped`, which branch protection counts as SATISFIED.
# That is exactly what makes the guard safe while the queue is on (the context still
# reports on the merge group, which is where the merge is decided) and exactly what makes
# it dangerous if the queue is ever turned OFF — PRs would then merge with the whole
# installed-host tier ungraded, silently. Arm 3 refuses a guard on a workflow that has
# stopped firing on `merge_group`, so switching the queue off cannot leave the guards
# standing without something going red.
set -uo pipefail
# DIVE-2573/DIVE-2692: ONE EXIT trap whose first act is capturing $?.
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
# DIVE-2211: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

WF=.github/workflows
GUARD="github.event_name != 'pull_request'"

# The split, pinned. Derived on DIVE-4139's body from a per-job job-seconds census of
# PR #806 / batch #834 and restated on DIVE-4186's; it is a POLICY, so it is spelled
# here rather than inferred from the file this harness grades.
declare -A QUEUE_ONLY=(
  [core-installed-host]=unit-tests
  [core-installed-host-confirm]=unit-tests
  [rails-installed-host]=unit-tests
  [acp-graded-installed]=unit-tests
  [test-installed-host]=unit-tests
  [test-installed-host-confirm]=unit-tests
  [docker-install]=install-smoke
)
# Kept on `pull_request` for fast maker feedback. NOT the complement of the map above —
# it is the subset whose loss would be felt by a maker, listed so that a guard landing on
# one of them reds here instead of quietly moving feedback to enqueue time.
declare -A PR_TIME=(
  [core-pristine]=unit-tests
  [rails-pristine]=unit-tests
  [acp-graded-pristine]=unit-tests
  [workflow-structure-guards]=unit-tests
  [changed-harnesses]=unit-tests
  [test]=unit-tests
  [test-confirm]=unit-tests
  [core-budget-report]=unit-tests
  [core-total-produced]=unit-tests
  [core-confirm-plan]=unit-tests
  [shellcheck]=install-smoke
  [supply-chain-guard]=supply-chain-guard
  [scan]=pii-guard
  [actionlint]=actionlint
)

# The `if:` expression of one job, as one line. Reads the block from `^  <job>:` to the
# next job header, so a guard written on a nested `steps:`-level `if:` is NOT mistaken
# for the job's own — job-level `if:` sits at exactly four spaces.
job_if(){   # <file> <job> -> its job-level if: expressions, one per line
  awk -v job="  $2:" '
    $0 == job { inj = 1; next }
    inj && /^  [^ ]/ { inj = 0 }
    inj && /^    if:/ { sub(/^    if:[ \t]*/, ""); print }
  ' "$1"
}

# --- arm 0: POSITIVE CONTROL on the extractor -----------------------------------
# A check that cannot fail launders an absence as "checked", and this whole harness is
# one extractor away from grading nothing. Drive job_if over a fixture whose answer is
# known, in both directions, before grading the real files.
fx="$(mktemp)"
cat > "$fx" <<'FIXTURE'
jobs:
  guarded:
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - if: always()
        run: true
  bare:
    runs-on: ubuntu-latest
    steps:
      - if: github.event_name != 'pull_request'
        run: true
FIXTURE
ctl=0
[[ "$(job_if "$fx" guarded)" == "$GUARD" ]] || { ctl=1; printf '    control: guarded job read as [%s]\n' "$(job_if "$fx" guarded)"; }
[[ -z "$(job_if "$fx" bare)" ]] || { ctl=1; printf '    control: a STEP-level if: leaked into the job-level read\n'; }
rm -f "$fx"
if (( ctl == 0 )); then ok "arm0 the extractor reads a job-level if: and ignores a step-level one"
else no "arm0 the extractor is broken — every arm below would grade nothing"; fi

# --- arm 1: every queue-time-only job carries the guard --------------------------
for job in "${!QUEUE_ONLY[@]}"; do
  f="$WF/${QUEUE_ONLY[$job]}.yml"
  if ! grep -qE "^  ${job}:\$" "$f"; then
    no "arm1 $job: no such job in $(basename "$f") — the map and the workflow disagree"
    continue
  fi
  if job_if "$f" "$job" | grep -qF "$GUARD"; then
    ok "arm1 $job is queue-time only"
  else
    no "arm1 $job lost its \`$GUARD\` guard — the PR arm of the installed-host tier is back (~1551 job-s per PR)"
  fi
done

# --- arm 2: no PR-time job picked one up ----------------------------------------
for job in "${!PR_TIME[@]}"; do
  f="$WF/${PR_TIME[$job]}.yml"
  if ! grep -qE "^  ${job}:\$" "$f"; then
    no "arm2 $job: no such job in $(basename "$f") — the map and the workflow disagree"
    continue
  fi
  if job_if "$f" "$job" | grep -qF "$GUARD"; then
    no "arm2 $job is guarded but is PR-time: a maker now learns of this red only at enqueue, where it costs the whole batch"
  else
    ok "arm2 $job still runs on pull_request"
  fi
done

# --- arm 3: a guard is only sound while the queue still grades the job -----------
# `skipped` counts as SATISFIED for branch protection. A guarded job whose workflow has
# stopped firing on `merge_group` is therefore a required context that is graded on NO
# event a merge is decided on, which is worse than the duplication this row deleted.
for f in $(printf '%s\n' "${QUEUE_ONLY[@]}" | sort -u); do
  p="$WF/$f.yml"
  if grep -qE '^  merge_group:' "$p" && grep -qE '^  push:' "$p"; then
    ok "arm3 $f.yml still fires on merge_group AND push"
  else
    no "arm3 $f.yml carries queue-time-only guards but no longer fires on merge_group and push — those jobs are now graded nowhere"
  fi
done

# --- arm 4: the confirm plan's absence is allowed EXACTLY ONE WAY ----------------
# core-confirm-plan fails CLOSED on installed verdict files that are not there. That is
# correct when the shards ran, and a false red when they were queue-time-skipped. The
# repair must key on the shard job's own result being `skipped` and nothing weaker: a
# `!= success` here would swallow a shard that ran and DIED, which is the reading the
# BLOCKED refusal exists to refuse.
u="$WF/unit-tests.yml"
if grep -qF '[ "$INSTALLED_RESULT" = skipped ]' "$u" && grep -qE '^\s+plan installed$' "$u"; then
  ok "arm4 core-confirm-plan skips the installed plan on \`skipped\` alone, and still runs it otherwise"
else
  no "arm4 core-confirm-plan's installed-tier branch is gone or widened past \`= skipped\` — a shard that ran and died would stop being BLOCKED"
fi
if grep -qE 'INSTALLED_RESULT.*!=.*success|INSTALLED_RESULT" != success' "$u"; then
  no "arm4 core-confirm-plan keys on \`!= success\`, which also swallows failure and cancelled"
else
  ok "arm4 no \`!= success\` widening on INSTALLED_RESULT"
fi

printf '\nqueue_time_only_arms_unit: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
