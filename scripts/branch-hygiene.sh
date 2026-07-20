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
  *) echo "usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
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
