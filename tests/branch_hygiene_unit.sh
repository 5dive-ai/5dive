#!/usr/bin/env bash
set -euo pipefail

trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)

cat >"$TMP/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
args="$*"

case "$args" in
  "api repos/acme/demo --jq .default_branch")
    echo main
    ;;
  *"pulls?state=open&per_page=100"*)
    echo open-live
    ;;
  *"branches?per_page=100"*)
    printf '%s\n' \
      $'main\tMAIN\tfalse' \
      $'open-live\tOPEN\tfalse' \
      $'merged-old\tMERGED\tfalse' \
      $'merged-preserved\tKEEP\tfalse' \
      $'reused-head\tREUSED\tfalse' \
      $'changed-head\tCHANGED\tfalse' \
      $'protected-release\tPROTECTED\ttrue' \
      $'no-pr\tNONE\tfalse'
    ;;
  *"-f head=acme:merged-old"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:merged-old"*)
    echo '[{"number":12,"merged_at":"2026-07-01T00:00:00Z","head":{"sha":"MERGED"}}]'
    ;;
  *"-f head=acme:merged-preserved"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:merged-preserved"*)
    echo '[{"number":13,"merged_at":"2026-07-02T00:00:00Z","head":{"sha":"KEEP"}}]'
    ;;
  *"-f head=acme:reused-head"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:reused-head"*)
    echo '[{"number":14,"merged_at":"2026-07-03T00:00:00Z","head":{"sha":"OLD-SHA"}}]'
    ;;
  *"-f head=acme:changed-head"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:changed-head"*)
    echo '[{"number":15,"merged_at":"2026-07-04T00:00:00Z","head":{"sha":"CHANGED"}}]'
    ;;
  *"-f state=closed"*)
    echo '[]'
    ;;
  "api repos/acme/demo/branches/merged-old --jq .commit.sha")
    echo MERGED
    ;;
  "api repos/acme/demo/branches/changed-head --jq .commit.sha")
    echo NEW-SHA
    ;;
  *"-f state=open"*"-f head=acme:merged-old"*)
    echo 0
    ;;
  *"--method DELETE repos/acme/demo/git/refs/heads%2Fmerged-old")
    echo "$args" >>"${GH_MOCK_LOG:?}"
    ;;
  *)
    echo "unexpected gh invocation: $args" >&2
    exit 99
    ;;
esac
MOCK
chmod +x "$TMP/gh"

dry_output=$(GH_BIN="$TMP/gh" GITHUB_REPOSITORY=acme/demo \
  BRANCH_HYGIENE_PRESERVE=merged-preserved \
  "$ROOT/scripts/branch-hygiene.sh" --dry-run)

grep -q 'PRESERVE open-or-explicit branch=open-live' <<<"$dry_output"
grep -q 'PRESERVE open-or-explicit branch=merged-preserved' <<<"$dry_output"
grep -q 'PRESERVE no-exact-merged-pr branch=reused-head' <<<"$dry_output"
grep -q 'DELETE-CANDIDATE branch=merged-old sha=MERGED pr=#12' <<<"$dry_output"
grep -q 'DELETE-CANDIDATE branch=changed-head sha=CHANGED pr=#15' <<<"$dry_output"
grep -q 'SUMMARY candidates=2 deleted=0' <<<"$dry_output"

: >"$TMP/deletes.log"
apply_output=$(GH_BIN="$TMP/gh" GH_MOCK_LOG="$TMP/deletes.log" \
  GITHUB_REPOSITORY=acme/demo BRANCH_HYGIENE_PRESERVE=merged-preserved \
  "$ROOT/scripts/branch-hygiene.sh" --apply)

grep -q 'DELETED branch=merged-old sha=MERGED pr=#12' <<<"$apply_output"
grep -q 'PRESERVE changed-since-inventory branch=changed-head old=CHANGED new=NEW-SHA' <<<"$apply_output"
grep -q 'SUMMARY candidates=2 deleted=1' <<<"$apply_output"
[[ $(wc -l <"$TMP/deletes.log") -eq 1 ]]
grep -q 'heads%2Fmerged-old' "$TMP/deletes.log"

echo "branch_hygiene_unit: PASS"

# --- DIVE-2394: --report classifies branches by EVIDENCE, never by age -----------------
# The measurement this guards (DIVE-2389, 2026-07-30): of 17 stale branches, FOUR held work
# that existed nowhere else while every one of their tasks read `done`. Age separated none of
# them from the merged-and-tidy ones. The arms below are the four outcomes that matter plus
# the two ways this can be wrong SILENTLY: attributing on a whole-message grep, and
# attributing when the evidence source could not be read at all.
RTMP=$(mktemp -d)
trap 'rc=$?; rm -rf "${TMP:-}" "${RTMP:-}"; echo "HARNESS-RC=$rc"' EXIT

cat >"$RTMP/gh" <<'RMOCK'
#!/usr/bin/env bash
set -uo pipefail
args="$*"

case "$args" in
  "api repos/acme/demo --jq .default_branch")
    echo main
    ;;
  *".protected]"*)
    # the delete path's 3-field inventory; --report must never ask for it
    echo "report asked for the delete-path inventory: $args" >&2
    exit 98
    ;;
  *"branches?per_page=100"*)
    printf '%s\n' \
      $'main\tMAIN' \
      $'open-live\tOPEN' \
      $'merged-old\tMERGED' \
      $'dive-3330-verify-merge-gate\tD3330' \
      $'dive-2067-verify-over-closed\tD2067' \
      $'salvage/untracked-test-harnesses-2026-07-26\tSALV' \
      $'status\tSTATUS' \
      $'contained-branch\tCONT'
    ;;
  *"pulls?state=open"*"@tsv"*)
    : # no stale open PRs in this fixture
    ;;
  *"pulls?state=open"*)
    echo open-live
    ;;
  *"commits?sha=main&since="*)
    if [[ -n "${MOCK_SUBJECTS_FAIL:-}" ]]; then
      echo "mock: subject corpus unreadable" >&2
      exit 1
    fi
    case "$args" in
      *'split("\n")[0]'*)
        case "$args" in
          *"page=1"*)
            # SUBJECTS ONLY. DIVE-2067 is deliberately absent from every subject.
            printf '%s\n' \
              'DIVE-3330: verify the merge gate' \
              'DIVE-2113: refuse task start on a closed row' \
              'DIVE-2112: refuse task reject on a closed row'
            ;;
          *) : ;;
        esac
        ;;
      *"commit.message"*)
        # The whole-message form. If the script ever asks for THIS, it sees the
        # bodies that CITE DIVE-2067 and attributes a branch whose work is absent
        # -- the exact false positive measured on 2026-07-30. Reaching this arm
        # turns the DIVE-2067 assertion below red, which is the point of it.
        case "$args" in
          *"page=1"*)
            printf '%s\n' \
              'DIVE-2113: refuse task start on a closed row -- same class as DIVE-2067' \
              'DIVE-2112: refuse task reject on a closed row (see DIVE-2067)'
            ;;
          *) : ;;
        esac
        ;;
    esac
    ;;
  "api repos/acme/demo/commits/"*" --jq .commit.committer.date")
    echo 2026-07-01T00:00:00Z
    ;;
  *"compare/main...main"*)
    # Arm 2's availability probe: the question whose answer is known. It must be
    # answerable exactly when the compare endpoint is readable, and fail with the
    # rest of the endpoint when it is not -- that is what separates a genuine
    # no-common-ancestor from a compare nobody could read.
    [[ -n "${MOCK_PROBE_LOG:-}" ]] && echo probe >>"$MOCK_PROBE_LOG"
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      echo "mock: compare rate-limited" >&2
      exit 1
    fi
    echo identical
    ;;
  *"compare/main...contained-branch"*)
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      echo "mock: compare rate-limited" >&2
      exit 1
    fi
    echo behind
    ;;
  *"compare/main...status"*)
    echo "mock: no common ancestor between main and status" >&2
    exit 1
    ;;
  *"compare/main..."*)
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      echo "mock: compare rate-limited" >&2
      exit 1
    fi
    echo diverged
    ;;
  *"-f head=acme:merged-old"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:merged-old"*)
    echo '[{"number":12,"merged_at":"2026-07-01T00:00:00Z","head":{"sha":"MERGED"}}]'
    ;;
  *"-f state=closed"*)
    echo '[]'
    ;;
  *)
    echo "unexpected gh invocation: $args" >&2
    exit 99
    ;;
esac
RMOCK
chmod +x "$RTMP/gh"

report_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo DEAD_BRANCH_DAYS=14 \
  "$ROOT/scripts/branch-hygiene.sh" --report)

# The four classifications.
grep -q 'LANDED merged-pr #12' <<<"$report_output"
grep -q '`contained-branch` — LANDED contained-in-`main`' <<<"$report_output"
grep -q '`dive-3330-verify-merge-gate` — LANDED subject-attribution DIVE-3330' <<<"$report_output"
grep -q '`dive-2067-verify-over-closed` — \*\*FINDING\*\* unattributed (DIVE-2067)' <<<"$report_output"
grep -q '`salvage/untracked-test-harnesses-2026-07-26` — \*\*FINDING\*\* no-ident' <<<"$report_output"
grep -q '`status` — ORPHAN no-common-ancestor with `main` (by design)' <<<"$report_output"

# A date in a branch name is not an ident: the salvage branch must not read as CX-2026 etc.
! grep -q 'salvage/untracked-test-harnesses-2026-07-26.*unattributed' <<<"$report_output"

# The findings section names the rescue, and age is no longer a section heading.
grep -q 'refs/rescued/<branch>' <<<"$report_output"
grep -q 'Branches that may be the only copy (evidence, not age)' <<<"$report_output"
! grep -q 'Branches with no activity' <<<"$report_output"

# Age is still printed as a fact about each branch.
grep -q 'since last commit (2026-07-01)' <<<"$report_output"

# DEAD_BRANCH_DAYS was set; the report must say it is not read rather than pretend.
grep -q 'DEAD_BRANCH_DAYS=14 was set and is NOT read' <<<"$report_output"

grep -q '2 finding(s), 3 with landing evidence, 1 orphan, 0 unknown' <<<"$report_output"

# The read-only invariant the ops runner greps for (branch-hygiene-report.sh).
! grep -q '^DELETED ' <<<"$report_output"

# THE FAILURE DIRECTION. With the subject corpus unreadable, the branch that WAS
# attributed by subject must stop being attributed -- never the other way round.
fail_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo MOCK_SUBJECTS_FAIL=1 \
  "$ROOT/scripts/branch-hygiene.sh" --report)

! grep -q 'LANDED subject-attribution' <<<"$fail_output"
grep -q '`dive-3330-verify-merge-gate` — UNKNOWN evidence-unavailable (DIVE-3330)' <<<"$fail_output"
grep -q '`dive-2067-verify-over-closed` — UNKNOWN evidence-unavailable (DIVE-2067)' <<<"$fail_output"
grep -q 'Arm 3 did not run, and nothing was attributed on its absence' <<<"$fail_output"
grep -q '1 finding(s), 2 with landing evidence, 1 orphan, 2 unknown' <<<"$fail_output"

# THE SAME FAILURE DIRECTION, OWED PER ARM (DIVE-2394 iteration 2). Arm 2's evidence source is
# the `compare` endpoint, and `gh api` exits non-zero for a genuine no-common-ancestor 404 and
# for a rate limit alike. Reading both as ORPHAN filed the branch under "preserved, not stale,
# do not sweep" -- measured on this fixture before the fix: 2 findings became 0, and
# `dive-2067-verify-over-closed` (the DIVE-2389 branch that held a live defect fix existing
# nowhere else) disappeared out of the findings section. A digest reading "0 findings" is an
# all-clear, and by the page this row compiled, the deletion reflex is formed by the digest.
: >"$RTMP/probe.log"
cmpfail_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo MOCK_COMPARE_FAIL=1 \
  MOCK_PROBE_LOG="$RTMP/probe.log" "$ROOT/scripts/branch-hygiene.sh" --report)

# The probe is asked LAZILY and its `unavailable` verdict is STICKY: one call, not one per
# branch. Cost is half of it; the other half is that a compare recovering mid-run must not
# hand two branches in the same digest verdicts derived from different endpoint states.
[[ $(wc -l <"$RTMP/probe.log") -eq 1 ]]

# MORE findings, never fewer: the 2 baseline findings survive and the branches arm 2 can no
# longer speak for join them, rather than being preserved out of sight.
grep -q '`dive-2067-verify-over-closed` — \*\*FINDING\*\* unattributed (DIVE-2067)' <<<"$cmpfail_output"
grep -q '`contained-branch` — \*\*FINDING\*\*' <<<"$cmpfail_output"
! grep -q 'LANDED contained-in-' <<<"$cmpfail_output"

# An unreadable compare is NEVER reported as an orphan verdict: the two have opposite remedies.
! grep -q 'ORPHAN' <<<"$cmpfail_output"
grep -q 'compare` endpoint could not be read this run: arm 2 did not run for 5 branch(es)' <<<"$cmpfail_output"

# Arm 3 still runs and is still trusted -- one unreadable arm does not blind the others.
grep -q '`dive-3330-verify-merge-gate` — LANDED subject-attribution DIVE-3330' <<<"$cmpfail_output"

grep -q '4 finding(s), 2 with landing evidence, 0 orphan, 0 unknown' <<<"$cmpfail_output"
! grep -q '^DELETED ' <<<"$cmpfail_output"

# And the probe is what discriminates: with compare readable, the intentional orphan is still
# an orphan and is still NOT a finding. (Guards the probe being wired to a constant `true`.)
grep -q '`status` — ORPHAN' <<<"$report_output"
! grep -q 'arm 2 did not run' <<<"$report_output"

echo "branch_hygiene_unit: report-by-evidence PASS"
