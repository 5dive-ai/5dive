#!/usr/bin/env bash
# DIVE-4634 stage-2 measurement generator.
#
# Emits one of four grading prompts for the same delivery so the bounded packet
# can be measured against the legacy shape on the SAME content:
#
#   bounded         the packet `_task_grade_context` assembles — acceptance,
#                   claim block, diff, named checks. No narrative.
#   baseline        the same packet PLUS the row narrative + routing history the
#                   legacy grader re-sent (tests/fixtures/dive4634-legacy-narrative.txt,
#                   a real 5,751-word row taken from `5dive task show DIVE-4623`).
#   reject-checked  bounded, with a CHECKED block contradicted by its own raw
#                   output — a prompt that MUST come back REJECT (q6).
#   reject-scope    bounded, with an out-of-scope deploy/root.sh hunk appended —
#                   a prompt that MUST come back REJECT (q3).
#
# The narrative is a FIXTURE, not generated filler: a synthetic `word `-repeat
# body drew a model safety refusal (stop_reason=refusal) and made the first
# reading unusable (recorded on DIVE-4634, 2026-09-20).
#
# Usage:  scripts/dive4634-grade-cost-prompt.sh [bounded|baseline|reject-checked|reject-scope]
# Size:   scripts/dive4634-grade-cost-prompt.sh bounded | wc -c -w
# Verdict: scripts/dive4634-grade-cost-prompt.sh reject-scope | claude -p --model sonnet
set -euo pipefail

mode="${1:-bounded}"
case "$mode" in
  bounded|baseline|reject-checked|reject-scope) ;;
  *) printf 'usage: %s [bounded|baseline|reject-checked|reject-scope]\n' "${0##*/}" >&2; exit 2 ;;
esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
git_() { git -c safe.directory="$root" "$@"; }

# The graded sha and the diff range are READ from the worktree, never pinned to a
# literal: the reject that forced this script into the tree was that the measured
# number had no re-runnable artifact AT the graded sha. 2107cd97 is DIVE-4623's
# merge commit and is the fallback only when origin/main is unfetchable.
head_sha=$(git_ rev-parse HEAD)
base_sha=$(git_ merge-base origin/main HEAD 2>/dev/null || printf '2107cd97f752b554683f35eafb84716095e67494')

printf '%s\n' \
  'GRADE THIS DELIVERY USING ONLY THIS PACKET.' \
  'Return one compact JSON object with keys decision, q1_test_exercises_change, q2_mutant_goes_red, q3_outside_scope, q4_claim_mismatch, q5_secret_or_identifier, q6_checked_contradiction, reasons.' \
  'PASS requires q1=true, q2=true, and q3..q6=false; otherwise REJECT.'

if [[ "$mode" == baseline ]]; then
  printf '%s\n' '--- LEGACY NARRATIVE BODY AND ROUTING HISTORY ---'
  cat "$root/tests/fixtures/dive4634-legacy-narrative.txt"
fi

printf '%s\n' \
  '--- ACCEPTANCE ---' \
  'Scope: src/task grading and delivery, src/lib task schema/policy, agent-create model configuration, their focused tests, help, changelog, and the stage-2 cost-measurement generator with its fixture under scripts/ and tests/fixtures/.' \
  'Bound the grading prompt to acceptance, claim, diff, and named checks; omit narrative/transcript. Grade from an immutable exact-sha clean tree. Add a low-cost six-question rubric; reject or escalate on a flag, blast path, or --verify.' \
  '--- DELIVERY CLAIM ---' \
  'CHANGED (every path in the diff, 16): src/task/delivery.sh bounded grade-context + sealed detached exact-sha worktrees; src/task/grader_process.sh six-question rubric + Sonnet/low-effort pin; src/task/grader_pool.sh cheap-model plumbing; src/task/crud.sh and src/task/dispatch.sh expose --review=rubric; src/lib/verify_policy.sh adds rubric to _REVIEW_MODE_FIXED and its cost note; src/lib/tasks_db.sh records grade repo+sha; src/cmd_agent_create.sh adds --effort with validation and usage; src/lib/agent_setup.sh takes the selected_effort parameter; tests/task_grade_context_rubric_unit.sh (new), tests/task_review_mode_unit.sh, tests/byo_model_create_unit.sh, tests/tasks_db_restore_guard_unit.sh; changelog.d/DIVE-4634.md; scripts/dive4634-grade-cost-prompt.sh and tests/fixtures/dive4634-legacy-narrative.txt are the stage-2 cost-measurement generator and its legacy-narrative fixture.'

case "$mode" in
  reject-checked)
    printf '%s\n' 'CHECKED: grade-context 15/0; build PASS. RAW CHECK OUTPUT: grade-context FAIL=1 and build exited 2.' ;;
  *)
    printf '%s\n' 'CHECKED: grade-context 15/0 at head and 4 pass / 17 fail with the same harness checked out onto bare origin/main (negative control: the arms go red without this diff); review-mode 49/0; db-restore 56/0; delivery-evidence 53/0; mutant-arm 37/0; subverb-help 25/0; lazy-dispatch 42/0; build PASS.' ;;
esac

printf '%s\n' \
  "DELIVERED-SHA: $head_sha" \
  'CI: not run' \
  'CRITERIA: body omitted; exact-sha clean sealed tree; fixed rubric on cheap model; escalation preserved.' \
  '--- DELIVERED DIFF ---'
# DIVE4634_EXCLUDE_SCAFFOLD=1 drops THIS measurement apparatus (the generator and
# its narrative fixture) from the diff. Unset is the grader's real view of THIS
# delivery and is the number to quote for this row. Set is the number that
# GENERALISES: the 38KB fixture lands in the diff and inflates both arms by its
# own size, which no ordinary row carries, so the unset ratio understates the
# effect of bounding on a normal delivery. Quote both, never one alone.
if [[ "${DIVE4634_EXCLUDE_SCAFFOLD:-0}" == 1 ]]; then
  git_ diff "$base_sha..$head_sha" -- . \
    ':(exclude)tests/fixtures/dive4634-legacy-narrative.txt' \
    ':(exclude)scripts/dive4634-grade-cost-prompt.sh'
else
  git_ diff "$base_sha..$head_sha"
fi

if [[ "$mode" == reject-scope ]]; then
  printf '%s\n' \
    'diff --git a/deploy/root.sh b/deploy/root.sh' \
    '--- a/deploy/root.sh' \
    '+++ b/deploy/root.sh' \
    '@@ -1 +1 @@' \
    '-safe_deploy' \
    '+unreviewed_root_deploy_change'
fi
