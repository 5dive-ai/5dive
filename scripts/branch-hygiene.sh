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
# unmerged PRs older than STALE_PR_DAYS, and classifies every other branch BY
# EVIDENCE that its work landed. Markdown on stdout for the weekly workflow to
# append to its run summary. Kept separate from the delete path so
# hygiene-flagging is never coupled to branch deletion (DIVE-1833, scope-2 of
# DIVE-1830).
#
# Age is the right axis for an OPEN PR — that section is about attention. It is
# the WRONG axis for a branch, and DIVE-2394 replaced it there; see the block
# above the classifier below for the measurement that forced it.
report_stale() {
  local pr_days="${STALE_PR_DAYS:-3}"
  local now pr_cutoff default_branch
  now=$(date -u +%s)
  pr_cutoff=$((pr_days * 86400))
  default_branch=$("$GH_BIN" api "repos/$repo" --jq .default_branch)

  local rtmp
  rtmp=$(mktemp -d) || { echo "branch-hygiene: mktemp failed" >&2; return 1; }
  # Expanded NOW, not at exit: $rtmp is function-local and would be unbound in the
  # trap body under `set -u`, which turns a clean report into a rc=1.
  # shellcheck disable=SC2064
  trap "rm -rf -- '$rtmp'" EXIT

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

  # BRANCHES ARE CLASSIFIED BY EVIDENCE, NEVER BY AGE (DIVE-2394; measured on
  # DIVE-2389, 5dive-ai/5dive, 2026-07-30).
  #
  # An audit of 17 stale branches found FOUR whose work existed NOWHERE ELSE while
  # every one of their tasks read `done` on the board — including a council fix
  # graded PASS and never merged, and a guard whose absence was a live defect.
  # Age separated none of them from the merged-and-tidy ones, and neither does
  # ancestry: under squash-merge a landed branch is never an ancestor of the
  # default branch, so `ahead_by` is non-zero for merged and unmerged alike
  # (`dive-2072-hook-staleness` read ahead=5 with its PR merged). A digest sorted
  # by age hands the reader the wrong axis, and the reflex answer to "dead branch,
  # 40d" is delete. See community/wiki/a-stale-branch-pile-can-be-the-only-copy.md.
  #
  # Three arms, ANY ONE of which means the work landed:
  #   1. merged-pr  — a closed PR whose head SHA equals the branch's current SHA.
  #                   The same predicate the --apply path deletes on.
  #   2. contained  — the branch is an ancestor of the default branch (compare
  #                   status identical|behind). Rare under squash-merge; cheap to ask.
  #   3. subject    — the branch's ident appears in a commit SUBJECT on the default
  #                   branch. SUBJECT ONLY, and this is the whole trap: `git log
  #                   --grep=<IDENT>` reads the WHOLE message and matches other
  #                   commits CITING the defect — measured 9 hits for DIVE-2067
  #                   while the guard itself was absent from main, all nine of them
  #                   later guards' comments. The false positive gets STRONGER the
  #                   more important the missing work was, because a good finding is
  #                   cited more.
  #
  # None of the three -> FINDING. It may be the only copy. Report it; never delete it.
  # Age is still printed, as a fact about the branch. It is not the classifier.
  #
  # THE FAILURE DIRECTION IS DELIBERATE, AND IT IS OWED PER ARM: a missing or
  # truncated evidence source makes this section report MORE findings, never
  # fewer. Nothing is ever attributed on the ABSENCE of a reading — and nothing
  # is moved OUT of the findings section on one either, which is the half arm 2
  # got wrong first (DIVE-2394 iteration 2). Every arm below therefore has a
  # distinct "could not read this" state, its own counter, and its own footer:
  # a run that could not see an evidence source must say which one.
  local ident_prefixes="${BRANCH_HYGIENE_IDENT_PREFIXES:-DIVE|OSS|CNCL|INST|MOB|STEER|CX}"
  local max_subject_pages="${BRANCH_HYGIENE_SUBJECT_PAGES:-20}"

  # Pass 1 — inventory the branches this section judges, with last-commit dates.
  # The oldest of those bounds the subject corpus below: work lands on the default
  # branch AFTER the branch's last commit, never before it.
  local inv="$rtmp/inventory" oldest="$now"
  : >"$inv"
  while IFS=$'\t' read -r branch sha; do
    [[ -n "$branch" ]] || continue
    [[ -n "${open_head[$branch]:-}" ]] && continue
    local commit_date commit_epoch
    commit_date=$("$GH_BIN" api "repos/$repo/commits/$sha" --jq .commit.committer.date 2>/dev/null || true)
    if [[ -n "$commit_date" ]]; then
      commit_epoch=$(date -u -d "$commit_date" +%s)
      if (( commit_epoch < oldest )); then oldest="$commit_epoch"; fi
    else
      commit_epoch=0
    fi
    printf '%s\t%s\t%s\t%s\n' "$branch" "$sha" "$commit_date" "$commit_epoch" >>"$inv"
  done < <("$GH_BIN" api --paginate "repos/$repo/branches?per_page=100" \
    --jq '.[] | [.name, .commit.sha] | @tsv')

  # The subject corpus, fetched ONCE for the whole run and bounded by that date.
  # Paged by hand rather than with --paginate so the cap is visible: a corpus that
  # stops early must SAY so, because "the ident is not in here" then means "not in
  # the part I read".
  local subj="$rtmp/subjects" subj_state=ok since page=1 got
  since=$(date -u -d "@$(( oldest - 86400 ))" +%Y-%m-%dT%H:%M:%SZ)
  : >"$subj"
  while (( page <= max_subject_pages )); do
    if ! got=$("$GH_BIN" api \
      "repos/$repo/commits?sha=$(urlencode "$default_branch")&since=$since&per_page=100&page=$page" \
      --jq '.[] | .commit.message | split("\n")[0]' 2>/dev/null); then
      subj_state=unavailable
      break
    fi
    [[ -n "$got" ]] || break
    printf '%s\n' "$got" >>"$subj"
    if (( $(printf '%s\n' "$got" | wc -l) < 100 )); then break; fi
    page=$((page + 1))
  done
  if [[ "$subj_state" == ok ]] && (( page > max_subject_pages )); then subj_state=truncated; fi

  # Arm 2's evidence-availability probe. `gh api` exits non-zero for a 404 (no
  # common ancestor, which is a FACT about the branch) and for a rate limit, a
  # 5xx or a token-scope refusal (which is the absence of a reading) alike, so
  # an empty compare status has two causes whose remedies are OPPOSITE: "by
  # design, ignore this forever" and "this told you nothing, re-run it". Reading
  # both as ORPHAN files the branch under "preserved, not stale, do not sweep"
  # and drops it out of the findings section — measured on the DIVE-2394 report
  # mock with both compare arms rate-limited: 2 findings became 0, and
  # `dive-2067-verify-over-closed` (the branch from the DIVE-2389 audit that
  # held a live defect fix existing nowhere else) landed in the preserved
  # bucket. A digest reading "0 findings" is an all-clear.
  #
  # Discriminate by asking the SAME endpoint a question whose answer is known:
  # <default>...<default> is `identical` whenever compare is readable at all.
  # Asked LAZILY, only when a compare comes back empty, so a run with no orphan
  # branch pays nothing. It is NOT one call per run in general: while compare is
  # readable the probe is re-asked on every empty compare, so the cost is one
  # call per orphan branch (today, one — `status`). Only the `unavailable`
  # verdict is sticky, because that direction over-reports and because two
  # branches in one digest must not be graded against different endpoint
  # states.
  local cmp_state=ok
  compare_endpoint_readable() {
    [[ "$cmp_state" == ok ]] || return 1
    local probe
    probe=$("$GH_BIN" api \
      "repos/$repo/compare/$(urlencode "$default_branch")...$(urlencode "$default_branch")" \
      --jq .status 2>/dev/null || true)
    [[ "$probe" == identical ]] && return 0
    cmp_state=unavailable
    return 1
  }

  # Pass 2 — classify. `cmp_unavail` is a per-run tally, NOT a fifth bucket: the
  # four buckets below must still sum to the branch count, so a branch whose
  # arm-2 read failed is counted where arms 1 and 3 actually placed it.
  local br_findings=0 br_landed=0 br_orphan=0 br_unknown=0 cmp_unavail=0
  local f_out="$rtmp/findings" l_out="$rtmp/landed" o_out="$rtmp/other"
  : >"$f_out"; : >"$l_out"; : >"$o_out"

  while IFS=$'\t' read -r branch sha commit_date commit_epoch; do
    [[ -n "$branch" ]] || continue
    local age_note="age unreadable"
    if (( commit_epoch > 0 )); then
      age_note="$(( (now - commit_epoch) / 86400 ))d since last commit (${commit_date%%T*})"
    fi

    local merged_pr
    merged_pr=$("$GH_BIN" api --method GET "repos/$repo/pulls" \
      -f state=closed -f "head=$owner:$branch" -f per_page=100 2>/dev/null \
      | jq -r --arg sha "$sha" '
          [.[] | select(.merged_at != null and .head.sha == $sha)]
          | sort_by(.merged_at) | last
          | if . == null then "" else "#\(.number)" end' 2>/dev/null || true)
    if [[ -n "$merged_pr" ]]; then
      echo "- \`${branch}\` — LANDED merged-pr ${merged_pr} — ${age_note}" >>"$l_out"
      br_landed=$((br_landed + 1))
      continue
    fi

    # Arm 2, and the orphan detector with it. `status` on this repo is an
    # INTENTIONAL orphan with no common ancestor — the zero-human badge, written
    # daily by `5dive proof publish` — and an ancestry-based sweep flags it every
    # single week. Compare fails on it, which is the signal, not an error — but
    # ONLY once `compare_endpoint_readable` has separated that failure from a
    # compare nobody could read; see the probe above.
    local cmp_status
    cmp_status=$("$GH_BIN" api \
      "repos/$repo/compare/$(urlencode "$default_branch")...$(urlencode "$branch")" \
      --jq .status 2>/dev/null || true)
    case "$cmp_status" in
      identical|behind)
        echo "- \`${branch}\` — LANDED contained-in-\`${default_branch}\` — ${age_note}" >>"$l_out"
        br_landed=$((br_landed + 1))
        continue
        ;;
      "")
        # Empty has two causes. Ask the probe which one this is, and never let
        # them share a detail string: one says "ignore this forever", the other
        # says "re-run, this run told you nothing".
        if compare_endpoint_readable; then
          echo "- \`${branch}\` — ORPHAN no-common-ancestor with \`${default_branch}\` (by design) — preserved, not stale, do not sweep — ${age_note}" >>"$o_out"
          br_orphan=$((br_orphan + 1))
          continue
        fi
        # Arm 2 did not RUN for this branch, so it says nothing about it — and an
        # arm that said nothing must not be able to move a branch OUT of the
        # findings section. Fall through to arm 3 and let the branch be
        # classified on the arms that did run. `status` then reports as a
        # no-ident FINDING instead of ORPHAN, which over-reports; that is the
        # signed direction, and the footer says which arm was missing.
        cmp_unavail=$((cmp_unavail + 1))
        ;;
    esac

    local ident
    ident=$(grep -oiE "(${ident_prefixes})[-_]?[0-9]+" <<<"$branch" | head -1 \
      | tr '[:lower:]' '[:upper:]' \
      | sed -E "s/^(${ident_prefixes})[-_]?([0-9]+)\$/\\1-\\2/" || true)

    if [[ -z "$ident" ]]; then
      echo "- \`${branch}\` — **FINDING** no-ident — the name carries no task ident, so no attribution is possible from it at all; read its contents before any deletion — ${age_note}" >>"$f_out"
      br_findings=$((br_findings + 1))
      continue
    fi

    if [[ "$subj_state" == unavailable ]]; then
      echo "- \`${branch}\` — UNKNOWN evidence-unavailable (${ident}) — the commit-subject corpus could not be read this run, so arm 3 did not run; NOT attributed — ${age_note}" >>"$o_out"
      br_unknown=$((br_unknown + 1))
      continue
    fi

    if grep -qiF -- "$ident" "$subj"; then
      echo "- \`${branch}\` — LANDED subject-attribution ${ident} — ${age_note}" >>"$l_out"
      br_landed=$((br_landed + 1))
      continue
    fi

    echo "- \`${branch}\` — **FINDING** unattributed (${ident}) — no merged PR at this head, not contained in \`${default_branch}\`, and ${ident} appears in no commit SUBJECT there. This branch may be the only copy of its work — ${age_note}" >>"$f_out"
    br_findings=$((br_findings + 1))
  done <"$inv"

  echo "#### Branches that may be the only copy (evidence, not age)"
  if (( br_findings > 0 )); then
    cat "$f_out"
    echo
    echo "Rescue BEFORE any deletion. Zero byte cost when the objects are already in the canonical store, and the ref survives branch deletion permanently:"
    echo
    echo '```'
    echo "git push https://github.com/${repo}.git refs/remotes/origin/<branch>:refs/rescued/<branch>"
    echo '```'
  else
    echo "- none"
  fi
  echo

  echo "#### Branches with evidence their work landed"
  if (( br_landed > 0 )); then cat "$l_out"; else echo "- none"; fi
  echo

  if (( br_orphan > 0 || br_unknown > 0 )); then
    echo "#### Neither — preserved, and not counted as findings"
    cat "$o_out"
    echo
  fi

  if [[ "$cmp_state" == unavailable ]]; then
    echo "_The \`compare\` endpoint could not be read this run: arm 2 did not run for ${cmp_unavail} branch(es), and no branch was attributed OR filed as an orphan on its absence. A branch with no common ancestor is indistinguishable from an unreadable compare while this is true, so \`${default_branch}\`-orphans such as an intentional badge branch report as findings here. Re-run before acting on this section._"
    echo
  fi

  case "$subj_state" in
    truncated)
      echo "_Commit-subject corpus stopped at the ${max_subject_pages}-page cap (since ${since}); an attribution past that point was not seen, so this run over-reports findings rather than under-reporting them._"
      echo
      ;;
    unavailable)
      echo "_The commit-subject corpus could not be read this run. Arm 3 did not run, and nothing was attributed on its absence._"
      echo
      ;;
  esac

  if [[ -n "${DEAD_BRANCH_DAYS:-}" ]]; then
    echo "_DEAD_BRANCH_DAYS=${DEAD_BRANCH_DAYS} was set and is NOT read: branch age stopped being a classifier in DIVE-2394. It is printed per branch as a fact, nothing more._"
    echo
  fi

  echo "_Flagged ${pr_flagged} stale PR(s). Branches: ${br_findings} finding(s), ${br_landed} with landing evidence, ${br_orphan} orphan, ${br_unknown} unknown. This is a report only; nothing was deleted, labelled, or closed._"
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
