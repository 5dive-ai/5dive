#!/usr/bin/env bash
# Delete only repository branches whose exact current head was merged by a PR.
#
# This intentionally asks the GitHub API for PR merge state. Git ancestry is not
# sufficient because this repository normally squash-merges pull requests.

set -euo pipefail

mode="dry-run"
case "${1:-}" in
  ""|--dry-run) ;;
  --apply) mode="apply" ;;
  --report) mode="report" ;;
  *) echo "usage: $0 [--dry-run|--apply|--report]" >&2; exit 2 ;;
esac

GH_BIN="${GH_BIN:-gh}"
command -v "$GH_BIN" >/dev/null 2>&1 || {
  echo "branch-hygiene: '$GH_BIN' is required" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "branch-hygiene: 'jq' is required" >&2
  exit 2
}

repo="${GITHUB_REPOSITORY:-}"
if [[ -z "$repo" ]]; then
  repo=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner)
fi
[[ "$repo" == */* ]] || {
  echo "branch-hygiene: expected OWNER/REPO, got '$repo'" >&2
  exit 2
}
owner="${repo%%/*}"

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

# --report is a read-only digest pass: it FLAGS (never deletes/labels/closes)
# unmerged PRs older than STALE_PR_DAYS and branches with no commit activity for
# DEAD_BRANCH_DAYS, emitting Markdown on stdout for the weekly workflow to append
# to its run summary. Kept separate from the delete path so hygiene-flagging is
# never coupled to branch deletion (DIVE-1833, scope-2 of DIVE-1830).
report_stale() {
  local pr_days="${STALE_PR_DAYS:-3}"
  local br_days="${DEAD_BRANCH_DAYS:-14}"
  local now pr_cutoff br_cutoff default_branch
  now=$(date -u +%s)
  pr_cutoff=$((pr_days * 86400))
  br_cutoff=$((br_days * 86400))
  default_branch=$("$GH_BIN" api "repos/$repo" --jq .default_branch)

  # Open PR heads are excluded from the dead-branch list: a branch with an open
  # PR is already surfaced by the stale-PR section, so it is not "dead".
  declare -A open_head=()
  open_head["$default_branch"]=1
  while IFS= read -r ref; do
    [[ -n "$ref" ]] && open_head["$ref"]=1
  done < <("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '.[].head.ref')

  echo "### Branch hygiene digest"
  echo

  # Stale unmerged PRs: open (hence unmerged) and older than the threshold. Age
  # is measured from creation; updated_at is shown so a maintainer can see the
  # last touch without opening each PR.
  local pr_flagged=0
  echo "#### Unmerged PRs open >${pr_days}d"
  while IFS=$'\t' read -r num ref created updated title; do
    [[ -n "$num" ]] || continue
    local created_epoch age_days
    created_epoch=$(date -u -d "$created" +%s)
    (( now - created_epoch >= pr_cutoff )) || continue
    age_days=$(( (now - created_epoch) / 86400 ))
    echo "- #${num} \`${ref}\` — ${age_days}d old (updated ${updated%%T*}) — ${title}"
    pr_flagged=$((pr_flagged + 1))
  done < <("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100" \
    --jq '.[] | [.number, .head.ref, .created_at, .updated_at, .title] | @tsv')
  (( pr_flagged > 0 )) || echo "- none"
  echo

  # Dead branches: no commit activity for the threshold, excluding the default
  # branch and any branch with an open PR. Read-only; nothing is deleted here.
  local br_flagged=0
  echo "#### Branches with no activity >${br_days}d"
  while IFS=$'\t' read -r branch sha; do
    [[ -n "$branch" ]] || continue
    [[ -n "${open_head[$branch]:-}" ]] && continue
    local commit_date commit_epoch age_days
    commit_date=$("$GH_BIN" api "repos/$repo/commits/$sha" --jq .commit.committer.date 2>/dev/null || true)
    [[ -n "$commit_date" ]] || continue
    commit_epoch=$(date -u -d "$commit_date" +%s)
    (( now - commit_epoch >= br_cutoff )) || continue
    age_days=$(( (now - commit_epoch) / 86400 ))
    echo "- \`${branch}\` — ${age_days}d since last commit (${commit_date%%T*})"
    br_flagged=$((br_flagged + 1))
  done < <("$GH_BIN" api --paginate "repos/$repo/branches?per_page=100" \
    --jq '.[] | [.name, .commit.sha] | @tsv')
  (( br_flagged > 0 )) || echo "- none"
  echo

  echo "_Flagged ${pr_flagged} stale PR(s) and ${br_flagged} dead branch(es). This is a report only; nothing was deleted, labelled, or closed._"
}

if [[ "$mode" == "report" ]]; then
  report_stale
  exit 0
fi

declare -A preserve=()
while IFS= read -r branch; do
  [[ -n "$branch" ]] && preserve["$branch"]=1
done < <(printf '%s\n' "${BRANCH_HYGIENE_PRESERVE:-}" | tr ',' '\n')

default_branch=$("$GH_BIN" api "repos/$repo" --jq .default_branch)
preserve["$default_branch"]=1

# Every open PR head is a hard preserve, including fork heads whose ref happens
# to match a branch in this repository. The conservative false-positive is safe.
while IFS= read -r branch; do
  [[ -n "$branch" ]] && preserve["$branch"]=1
done < <("$GH_BIN" api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '.[].head.ref')

candidate_count=0
deleted_count=0
skipped_count=0

echo "branch-hygiene: mode=$mode repo=$repo default=$default_branch"

while IFS=$'\t' read -r branch sha protected; do
  [[ -n "$branch" ]] || continue

  if [[ "$protected" == "true" ]]; then
    echo "PRESERVE protected branch=$branch sha=$sha"
    ((skipped_count += 1))
    continue
  fi
  if [[ -n "${preserve[$branch]:-}" ]]; then
    echo "PRESERVE open-or-explicit branch=$branch sha=$sha"
    ((skipped_count += 1))
    continue
  fi

  # Requiring the PR head SHA to equal the branch's current SHA prevents an old
  # merged PR from deleting a later branch that reused the same name.
  closed_prs=$("$GH_BIN" api --method GET "repos/$repo/pulls" \
    -f state=closed -f "head=$owner:$branch" -f per_page=100)
  merge_row=$(jq -r --arg sha "$sha" '
    [.[] | select(.merged_at != null and .head.sha == $sha)]
    | sort_by(.merged_at) | last
    | if . == null then empty else [.number, .merged_at] | @tsv end
  ' <<<"$closed_prs")

  if [[ -z "$merge_row" ]]; then
    echo "PRESERVE no-exact-merged-pr branch=$branch sha=$sha"
    ((skipped_count += 1))
    continue
  fi

  IFS=$'\t' read -r pr_number merged_at <<<"$merge_row"
  echo "DELETE-CANDIDATE branch=$branch sha=$sha pr=#$pr_number merged_at=$merged_at"
  ((candidate_count += 1))
  [[ "$mode" == "apply" ]] || continue

  # Fail closed on races: the ref must still point at the inventoried SHA and it
  # must still have no open PR immediately before deletion.
  encoded_branch=$(urlencode "$branch")
  current_sha=$("$GH_BIN" api "repos/$repo/branches/$encoded_branch" --jq .commit.sha)
  if [[ "$current_sha" != "$sha" ]]; then
    echo "PRESERVE changed-since-inventory branch=$branch old=$sha new=$current_sha"
    continue
  fi
  open_count=$("$GH_BIN" api --method GET "repos/$repo/pulls" \
    -f state=open -f "head=$owner:$branch" -f per_page=1 --jq length)
  if [[ "$open_count" != "0" ]]; then
    echo "PRESERVE newly-open-pr branch=$branch"
    continue
  fi

  encoded_ref=$(urlencode "heads/$branch")
  "$GH_BIN" api --method DELETE "repos/$repo/git/refs/$encoded_ref" >/dev/null
  echo "DELETED branch=$branch sha=$sha pr=#$pr_number"
  ((deleted_count += 1))
done < <("$GH_BIN" api --paginate "repos/$repo/branches?per_page=100" \
  --jq '.[] | [.name, .commit.sha, .protected] | @tsv')

echo "SUMMARY candidates=$candidate_count deleted=$deleted_count preserved=$skipped_count mode=$mode"
