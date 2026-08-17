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

# See the twin in the --report mock below: gh writes an HTTP error BODY to STDOUT
# with `--jq` unapplied (DIVE-2394 iteration 4, measured against the live API).
gh_http_error() { # <status> <message>
  printf '{"message":"%s","documentation_url":"https://docs.github.com/rest","status":"%s"}' "$2" "$1"
  echo "gh: $2 (HTTP $1)" >&2
  exit 1
}

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
      $'no-pr\tNONE\tfalse' \
      $'superseded-match\t1111111111111111111111111111111111111111\tfalse' \
      $'superseded-mismatch\t2222222222222222222222222222222222222222\tfalse' \
      $'superseded-unresolved\t3333333333333333333333333333333333333333\tfalse' \
      $'superseded-reused\t4444444444444444444444444444444444444444\tfalse'
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
  # DIVE-3490 fixtures. All four PRs are closed UNMERGED (merged_at null), so
  # the merged predicate can never reach them; only content identity against
  # refs/pull/N/head can, and each arm below fails it a different way.
  *"-f head=acme:superseded-match"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:superseded-match"*)
    echo '[{"number":20,"merged_at":null,"head":{"sha":"1111111111111111111111111111111111111111"}}]'
    ;;
  *"-f head=acme:superseded-mismatch"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:superseded-mismatch"*)
    echo '[{"number":21,"merged_at":null,"head":{"sha":"2222222222222222222222222222222222222222"}}]'
    ;;
  *"-f head=acme:superseded-unresolved"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:superseded-unresolved"*)
    echo '[{"number":22,"merged_at":null,"head":{"sha":"3333333333333333333333333333333333333333"}}]'
    ;;
  # The closed PR exists but its head is an OLDER sha than the branch now holds:
  # the branch was pushed again after the PR closed. Identity must not match, and
  # the pull ref must never be consulted at all.
  *"-f head=acme:superseded-reused"*"-f state=closed"*|*"-f state=closed"*"-f head=acme:superseded-reused"*)
    echo '[{"number":23,"merged_at":null,"head":{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}]'
    ;;
  *"-f state=closed"*)
    echo '[]'
    ;;
  "api repos/acme/demo/git/ref/pull/20/head --jq .object.sha")
    echo 1111111111111111111111111111111111111111
    ;;
  # Pull ref resolves, but to a different commit than the branch head: the
  # branch moved after the PR closed, so GitHub is NOT preserving this head.
  "api repos/acme/demo/git/ref/pull/21/head --jq .object.sha")
    echo 9999999999999999999999999999999999999999
    ;;
  # THE fail-closed arm: the pull ref does not resolve (deleted PR, fork head,
  # network). An absent ref must PRESERVE, never pass for want of a mismatch.
  "api repos/acme/demo/git/ref/pull/22/head --jq .object.sha")
    gh_http_error 404 "Not Found"
    ;;
  "api repos/acme/demo/git/ref/pull/23/head --jq .object.sha")
    echo "unexpected pull-ref lookup for a non-identical head: $args" >&2
    exit 98
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

# A bare `! grep -q ...` SKIPS errexit (shellcheck SC2251): if the forbidden
# string IS present, the `!` inverts it to rc 1 and the harness sails on green.
# Every negative assertion in this file is load-bearing -- one of them is the
# whole "not armed under --apply" guarantee -- so they go through a helper that
# exits, and the helper itself is positive-controlled just below.
refute() {
  local why="$1" pattern="$2"
  if grep -q "$pattern"; then
    echo "REFUTED-ASSERTION FAILED: $why (found: $pattern)" >&2
    exit 1
  fi
}

# Positive control for the helper itself, because a negative assertion that
# cannot fail is exactly the defect it exists to close: refute must EXIT on a
# pattern that IS present. Run in a subshell so this harness survives it.
if ( echo 'REFUTE-SELF-TEST' | refute 'self-test' 'REFUTE-SELF-TEST' ) 2>/dev/null; then
  echo "refute() did not fail on a present pattern" >&2
  exit 1
fi

dry_output=$(GH_BIN="$TMP/gh" GITHUB_REPOSITORY=acme/demo \
  BRANCH_HYGIENE_PRESERVE=merged-preserved \
  "$ROOT/scripts/branch-hygiene.sh" --dry-run)

grep -q 'PRESERVE open-or-explicit branch=open-live' <<<"$dry_output"
grep -q 'PRESERVE open-or-explicit branch=merged-preserved' <<<"$dry_output"
grep -q 'PRESERVE no-exact-merged-pr branch=reused-head' <<<"$dry_output"
grep -q 'DELETE-CANDIDATE branch=merged-old sha=MERGED pr=#12' <<<"$dry_output"
grep -q 'DELETE-CANDIDATE branch=changed-head sha=CHANGED pr=#15' <<<"$dry_output"

# DIVE-3490 identity predicate, dry-run. One match, and three distinct refusals.
grep -q 'DELETE-CANDIDATE branch=superseded-match sha=1111111111111111111111111111111111111111 pr=#20 via=pullref-identity pullref=1111111111111111111111111111111111111111' <<<"$dry_output"
grep -q 'PRESERVE superseded-identity-mismatch branch=superseded-mismatch .* pr=#21 pullref=9999999999999999999999999999999999999999' <<<"$dry_output"
grep -q 'PRESERVE superseded-identity-unresolved branch=superseded-unresolved .* pr=#22' <<<"$dry_output"
# A branch pushed past its own closed PR falls back to the ORIGINAL message and
# never reaches the pull ref at all (the mock exits 98 if it does).
grep -q 'PRESERVE no-exact-merged-pr branch=superseded-reused' <<<"$dry_output"
# The unresolved arm must not be reported as a candidate under any name.
refute 'an unresolved pull ref became a candidate' 'DELETE-CANDIDATE branch=superseded-unresolved' <<<"$dry_output"
refute 'a mismatched pull ref became a candidate' 'DELETE-CANDIDATE branch=superseded-mismatch' <<<"$dry_output"

grep -q 'SUMMARY candidates=3 deleted=0' <<<"$dry_output"

: >"$TMP/deletes.log"
apply_output=$(GH_BIN="$TMP/gh" GH_MOCK_LOG="$TMP/deletes.log" \
  GITHUB_REPOSITORY=acme/demo BRANCH_HYGIENE_PRESERVE=merged-preserved \
  "$ROOT/scripts/branch-hygiene.sh" --apply)

grep -q 'DELETED branch=merged-old sha=MERGED pr=#12' <<<"$apply_output"
grep -q 'PRESERVE changed-since-inventory branch=changed-head old=CHANGED new=NEW-SHA' <<<"$apply_output"
[[ $(wc -l <"$TMP/deletes.log") -eq 1 ]]
grep -q 'heads%2Fmerged-old' "$TMP/deletes.log"

# DIVE-3490: the identity predicate is NOT armed under --apply. The weekly
# schedule runs --apply unattended, so a branch that PASSES identity must still
# be preserved there and must not appear in the delete log. This is the arm that
# would fail if someone later wires the predicate into the unattended path.
grep -q 'PRESERVE superseded-identity-not-armed branch=superseded-match sha=1111111111111111111111111111111111111111 pr=#20' <<<"$apply_output"
refute 'the identity predicate was armed under --apply' 'DELETE-CANDIDATE branch=superseded-match' <<<"$apply_output"
refute 'an identity-matched branch reached the delete API' superseded <"$TMP/deletes.log"
# candidates stays 2 under --apply where dry-run saw 3: the identity match is
# preserved, not counted. That difference IS the guarantee.
grep -q 'SUMMARY candidates=2 deleted=1' <<<"$apply_output"

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

# EVERY simulated HTTP failure goes through this, and it writes the error body to
# STDOUT (DIVE-2394 iteration 4). That is what the real tool does: measured against
# the live API, `gh api repos/5dive-ai/5dive/compare/main...no-such-branch --jq .status`
# prints {"message":"Not Found",...,"status":"404"} on stdout with `--jq` UNAPPLIED,
# rc=1. A mock that failed on stderr instead made every `cmd=$(... || true)` capture
# read EMPTY -- so this file was green over a product in which the whole
# empty-compare arm below was unreachable. A mock that is wrong about which STREAM
# an error uses makes every assertion above it vacuous.
gh_http_error() { # <status> <message>
  printf '{"message":"%s","documentation_url":"https://docs.github.com/rest","status":"%s"}' "$2" "$1"
  echo "gh: $2 (HTTP $1)" >&2
  exit 1
}

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
      $'gh-pages\tGHPAGES' \
      $'contained-branch\tCONT' \
      $'dive-3491-superseded-ok\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      $'dive-3492-superseded-moved\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
      $'dive-3493-superseded-gone\tcccccccccccccccccccccccccccccccccccccccc' \
      $'dive-3494-pushed-past\tdddddddddddddddddddddddddddddddddddddddd' \
      $'salvage/preserved-2026-08-01\teeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    ;;
  *"pulls?state=open"*"@tsv"*)
    : # no stale open PRs in this fixture
    ;;
  *"pulls?state=open"*)
    echo open-live
    ;;
  *"commits?sha=main&since="*)
    if [[ -n "${MOCK_SUBJECTS_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
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
    if [[ -n "${MOCK_DATES_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
    fi
    echo 2026-07-01T00:00:00Z
    ;;
  *"compare/main...main"*)
    # Arm 2's availability probe: the question whose answer is known. It must be
    # answerable exactly when the compare endpoint is readable, and fail with the
    # rest of the endpoint when it is not -- that is what separates a genuine
    # no-common-ancestor from a compare nobody could read.
    [[ -n "${MOCK_PROBE_LOG:-}" ]] && echo probe >>"$MOCK_PROBE_LOG"
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
    fi
    echo identical
    ;;
  *"compare/main...contained-branch"*)
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
    fi
    echo behind
    ;;
  *"compare/main...status"*|*"compare/main...gh-pages"*)
    # TWO intentional orphans, on purpose: one is not enough to tell "one probe
    # per run" apart from "one probe per orphan branch", and iteration 2 signed
    # the first while shipping the second.
    gh_http_error 404 "Not Found"
    ;;
  *"compare/main..."*)
    if [[ -n "${MOCK_COMPARE_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
    fi
    echo diverged
    ;;
  # The closed-PR page is the evidence source arms 1 and 4 SHARE, and it was the
  # one with no failure-direction test of its own (iteration 4).
  *"-f state=closed"*)
    if [[ -n "${MOCK_PRS_FAIL:-}" ]]; then
      gh_http_error 403 "API rate limit exceeded"
    fi
    case "$args" in
  *"-f head=acme:merged-old"*|*"-f state=closed"*"-f head=acme:merged-old"*)
    echo '[{"number":12,"merged_at":"2026-07-01T00:00:00Z","head":{"sha":"MERGED"}}]'
    ;;
  # DIVE-3490 arm-4 fixtures. Every one of these PRs is closed UNMERGED, so arms
  # 1-3 cannot reach any of them: #30 and #34 are byte-identical to their pull
  # ref, #31 moved, #32's ref is gone, #33's PR head is an older commit.
  *"-f head=acme:dive-3491-superseded-ok"*)
    echo '[{"number":30,"merged_at":null,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]'
    ;;
  *"-f head=acme:dive-3492-superseded-moved"*)
    echo '[{"number":31,"merged_at":null,"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]'
    ;;
  *"-f head=acme:dive-3493-superseded-gone"*)
    echo '[{"number":32,"merged_at":null,"head":{"sha":"cccccccccccccccccccccccccccccccccccccccc"}}]'
    ;;
  *"-f head=acme:dive-3494-pushed-past"*)
    echo '[{"number":33,"merged_at":null,"head":{"sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}]'
    ;;
  *"-f head=acme:salvage/preserved-2026-08-01"*)
    echo '[{"number":34,"merged_at":null,"head":{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}}]'
    ;;
  *)
    echo '[]'
    ;;
    esac
    ;;
  "api repos/acme/demo/git/ref/pull/30/head --jq .object.sha")
    echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    ;;
  "api repos/acme/demo/git/ref/pull/34/head --jq .object.sha")
    echo eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    ;;
  # Resolves, but to another commit: GitHub is not preserving THIS head.
  "api repos/acme/demo/git/ref/pull/31/head --jq .object.sha")
    echo 9999999999999999999999999999999999999999
    ;;
  # Fail-closed arm: the ref is gone. Must NOT discharge the finding.
  "api repos/acme/demo/git/ref/pull/32/head --jq .object.sha")
    gh_http_error 404 "Not Found"
    ;;
  # The PR head is an older commit than the branch holds, so arm 4 must decide
  # `none` from the PR list alone and never ask for this ref.
  "api repos/acme/demo/git/ref/pull/33/head --jq .object.sha")
    echo "unexpected pull-ref lookup for a non-identical head: $args" >&2
    exit 98
    ;;
  # There is deliberately NO pull-ref arm for #12: arm 1 discharges merged-old
  # before arm 4 runs, and asking here would fall to the catch-all and exit 99.
  *)
    echo "unexpected gh invocation: $args" >&2
    exit 99
    ;;
esac
RMOCK
chmod +x "$RTMP/gh"

: >"$RTMP/probe-ok.log"
report_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo DEAD_BRANCH_DAYS=14 \
  MOCK_PROBE_LOG="$RTMP/probe-ok.log" "$ROOT/scripts/branch-hygiene.sh" --report)

# The four classifications.
grep -q 'LANDED merged-pr #12' <<<"$report_output"
grep -q '`contained-branch` — LANDED contained-in-`main`' <<<"$report_output"
grep -q '`dive-3330-verify-merge-gate` — LANDED subject-attribution DIVE-3330' <<<"$report_output"
grep -q '`dive-2067-verify-over-closed` — \*\*FINDING\*\* unattributed (DIVE-2067)' <<<"$report_output"
grep -q '`salvage/untracked-test-harnesses-2026-07-26` — \*\*FINDING\*\* no-ident' <<<"$report_output"
grep -q '`status` — ORPHAN no-common-ancestor with `main` (by design)' <<<"$report_output"
grep -q '`gh-pages` — ORPHAN no-common-ancestor with `main` (by design)' <<<"$report_output"

# ARM 4 (DIVE-3490). A closed-UNMERGED PR whose pull ref is byte-identical to the
# branch head discharges the finding -- and says plainly that the work did not land.
grep -q '`dive-3491-superseded-ok` — PRESERVED pull-ref-identity #30' <<<"$report_output"
grep -q 'byte-identical to `refs/pull/30/head`.*the work did not land' <<<"$report_output"
grep -q 'restore: `git push origin aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:refs/heads/dive-3491-superseded-ok`' <<<"$report_output"
# It needs no ident, so it reaches the branch arm 3 can never judge.
grep -q '`salvage/preserved-2026-08-01` — PRESERVED pull-ref-identity #34' <<<"$report_output"
refute 'a pull-ref-preserved branch was also reported as a no-ident finding' \
  'salvage/preserved-2026-08-01. — \*\*FINDING\*\*' <<<"$report_output"

# THE FAILURE DIRECTION FOR ARM 4: each of its three negative states must leave
# the branch a FINDING. A mismatched ref, an unresolvable ref and a PR head that
# is not this commit are all "no evidence", never "safe to delete".
grep -q '`dive-3492-superseded-moved` — \*\*FINDING\*\* unattributed (DIVE-3492)' <<<"$report_output"
grep -q '`dive-3493-superseded-gone` — \*\*FINDING\*\* unattributed (DIVE-3493)' <<<"$report_output"
grep -q '`dive-3494-pushed-past` — \*\*FINDING\*\* unattributed (DIVE-3494)' <<<"$report_output"
refute 'a mismatched pull ref discharged a finding' 'dive-3492-superseded-moved. — PRESERVED' <<<"$report_output"
refute 'an unresolvable pull ref discharged a finding' 'dive-3493-superseded-gone. — PRESERVED' <<<"$report_output"

# One digest, ONE verdict per branch: the old standalone pull-ref section is gone,
# so no branch can be printed as both a finding and a restorable dead branch.
refute 'the superseded section was reinstated alongside the classifier' \
  'Dead branches restorable from their own pull ref' <<<"$report_output"
refute 'a branch got two contradictory verdicts' 'Deleting destroys nothing' <<<"$report_output"

# A date in a branch name is not an ident: the salvage branch must not read as CX-2026 etc.
refute 'a date in a branch name was read as an ident' \
  'salvage/untracked-test-harnesses-2026-07-26.*unattributed' <<<"$report_output"

# The findings section names the rescue, and age is no longer a section heading.
grep -q 'refs/rescued/<branch>' <<<"$report_output"
grep -q 'Branches that may be the only copy (evidence, not age)' <<<"$report_output"
refute 'the age-based branch section came back' 'Branches with no activity' <<<"$report_output"

# Age is still printed as a fact about each branch.
grep -q 'since last commit (2026-07-01)' <<<"$report_output"

# DEAD_BRANCH_DAYS was set; the report must say it is not read rather than pretend.
grep -q 'DEAD_BRANCH_DAYS=14 was set and is NOT read' <<<"$report_output"

grep -q '5 finding(s), 5 not the only copy (2 of those preserved by pull ref, not landed), 2 orphan, 0 unknown' <<<"$report_output"

# THE PROBE'S COST, MEASURED IN BOTH DIRECTIONS (DIVE-2394 iteration 3). Iteration 2 signed
# "one call per run" and shipped one call per ORPHAN BRANCH: only the `unavailable` verdict is
# sticky. With compare READABLE the probe is re-asked on every empty compare, so two orphans
# cost two calls -- and a fixture with one orphan cannot tell those two claims apart.
[[ $(wc -l <"$RTMP/probe-ok.log") -eq 2 ]]

# The read-only invariant the ops runner greps for (branch-hygiene-report.sh).
refute 'the report path deleted something' '^DELETED ' <<<"$report_output"

# THE FAILURE DIRECTION. With the subject corpus unreadable, the branch that WAS
# attributed by subject must stop being attributed -- never the other way round.
fail_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo MOCK_SUBJECTS_FAIL=1 \
  "$ROOT/scripts/branch-hygiene.sh" --report)

refute 'a branch was attributed by subject with the corpus unreadable' \
  'LANDED subject-attribution' <<<"$fail_output"
grep -q '`dive-3330-verify-merge-gate` — UNKNOWN evidence-unavailable (DIVE-3330)' <<<"$fail_output"
grep -q '`dive-2067-verify-over-closed` — UNKNOWN evidence-unavailable (DIVE-2067)' <<<"$fail_output"
grep -q 'Arm 3 did not run, and nothing was attributed on its absence' <<<"$fail_output"

# Arm 4 reads neither the subject corpus nor an ident, so it still discharges on a
# run where arm 3 could not run at all -- and the arm-4 negatives still degrade to
# UNKNOWN rather than to a pass.
grep -q '`dive-3491-superseded-ok` — PRESERVED pull-ref-identity #30' <<<"$fail_output"
grep -q '`salvage/preserved-2026-08-01` — PRESERVED pull-ref-identity #34' <<<"$fail_output"
grep -q '`dive-3493-superseded-gone` — UNKNOWN evidence-unavailable (DIVE-3493)' <<<"$fail_output"
grep -q '1 finding(s), 4 not the only copy (2 of those preserved by pull ref, not landed), 2 orphan, 5 unknown' <<<"$fail_output"

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

# STICKY in the `unavailable` direction, and this is the assertion that says so: eleven branches
# reach arm 2 with an empty compare and the probe is asked ONCE. Paired with the two-call
# readable-direction assertion above, the pair pins the actual rule -- sticky when unavailable,
# re-asked while readable -- which neither measures alone. The point is not the call count: a
# compare recovering mid-run must not hand two branches in the same digest verdicts derived
# from different endpoint states.
[[ $(wc -l <"$RTMP/probe.log") -eq 1 ]]

# MORE findings, never fewer: the 5 baseline findings survive and the branches arm 2 can no
# longer speak for join them, rather than being preserved out of sight.
grep -q '`dive-2067-verify-over-closed` — \*\*FINDING\*\* unattributed (DIVE-2067)' <<<"$cmpfail_output"
grep -q '`contained-branch` — \*\*FINDING\*\*' <<<"$cmpfail_output"
refute 'a branch was attributed by arm 2 while compare was unreadable' 'LANDED contained-in-' <<<"$cmpfail_output"

# An unreadable compare is NEVER reported as an orphan verdict: the two have opposite remedies.
refute 'an unreadable compare was reported as an orphan' 'ORPHAN' <<<"$cmpfail_output"
grep -q 'compare` endpoint could not be read this run: arm 2 did not run for 11 branch(es)' <<<"$cmpfail_output"

# Arm 3 still runs and is still trusted -- one unreadable arm does not blind the others.
grep -q '`dive-3330-verify-merge-gate` — LANDED subject-attribution DIVE-3330' <<<"$cmpfail_output"

grep -q '`gh-pages` — \*\*FINDING\*\*' <<<"$cmpfail_output"
grep -q '8 finding(s), 4 not the only copy (2 of those preserved by pull ref, not landed), 0 orphan, 0 unknown' <<<"$cmpfail_output"
refute '--report reached the delete path' '^DELETED ' <<<"$cmpfail_output"

# THE FAILURE DIRECTION FOR THE THIRD EVIDENCE SOURCE (iteration 4). Arms 1 and 4 share one
# read -- the closed-PR page -- and it was the only source left with no unreadable-direction
# test, which is precisely the shape that hid the defect this iteration fixes. With that page
# unreadable, both arms must go SILENT (nothing attributed, nothing preserved) and the branches
# they spoke for must appear as findings, never vanish.
prsfail_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo MOCK_PRS_FAIL=1 \
  "$ROOT/scripts/branch-hygiene.sh" --report)

refute 'arm 1 attributed while the closed-PR page was unreadable' \
  'LANDED merged-pr' <<<"$prsfail_output"
refute 'arm 4 preserved a branch while the closed-PR page was unreadable' \
  'PRESERVED pull-ref-identity' <<<"$prsfail_output"
grep -q '8 finding(s), 2 not the only copy (0 of those preserved by pull ref, not landed), 2 orphan, 0 unknown' <<<"$prsfail_output"

# THE FOURTH SOURCE: the per-branch commit date. It feeds no arm, only the age NOTE -- but an
# error body captured here is fed to `date -d`, which fails and kills the whole digest under
# `set -e`. Unreadable must degrade to "age unreadable" and the classification must be
# untouched, because a report that dies is a report nobody reads.
datesfail_output=$(GH_BIN="$RTMP/gh" GITHUB_REPOSITORY=acme/demo MOCK_DATES_FAIL=1 \
  "$ROOT/scripts/branch-hygiene.sh" --report)

grep -q 'age unreadable' <<<"$datesfail_output"
grep -q '5 finding(s), 5 not the only copy (2 of those preserved by pull ref, not landed), 2 orphan, 0 unknown' <<<"$datesfail_output"
refute 'a JSON error body was printed as an age' 'message.*Not Found\|rate limit' <<<"$datesfail_output"

# And the probe is what discriminates: with compare readable, the intentional orphan is still
# an orphan and is still NOT a finding. (Guards the probe being wired to a constant `true`.)
grep -q '`status` — ORPHAN' <<<"$report_output"
refute 'the arm-2 footer appeared in a run where compare was READABLE' 'arm 2 did not run' <<<"$report_output"

echo "branch_hygiene_unit: report-by-evidence PASS"
