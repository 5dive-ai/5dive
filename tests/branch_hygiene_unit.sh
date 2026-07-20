#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
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
