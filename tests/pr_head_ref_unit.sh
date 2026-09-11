#!/usr/bin/env bash
# DIVE-4237 — scripts/pr-head-ref.sh, the ref the merge-ref recompute cannot move.
#
# WHAT THIS GRADES. The subject exists because three jobs in this repo derive
# their whole verdict from `github.event.pull_request.head.sha`, and that sha is
# NOT always an object in the runner's clone: GitHub rebuilds
# `refs/pull/<n>/merge` when the base branch moves, actions/checkout silently
# falls back to the base branch, and the event payload keeps carrying the head
# sha regardless. So every arm below is about ONE distinction — "the head is
# here" versus "I could not make it be here" — because both of the tempting
# collapses are wrong in a way that reads as a verdict on the pull request:
#
#   exit 0 without the object   would clear a change the job never read.
#                               install-guard did exactly this before DIVE-4237
#                               (no errexit, dead `git diff`, empty `$files`,
#                               "the filter and the diff disagree", exit 0), so
#                               arms 3-6 assert non-zero on every unreachable
#                               input. That is the fails-OPEN direction and it
#                               is the one nobody notices.
#   exit non-zero WITH it       would keep the flake the whole row is about,
#                               just later. Arms 1-2 assert 0 both when the sha
#                               is already present and when only the PR-head ref
#                               can supply it.
#   the merge ref must not be   arm 2's fixture gives the fake remote a
#   what makes it pass          refs/pull/<n>/head and NO refs/pull/<n>/merge —
#                               if the script only worked via the merge ref it
#                               would fail here, which is the defect restated.
#   a tree/blob is not a commit arm 5: `^{commit}` is what the callers need;
#                               a sha that resolves to a non-commit is not a
#                               materialised head.
#
# NO NETWORK, NO ROOT: the "remote" is a second local repository on disk, so the
# fetch path is exercised for real rather than stubbed.
# Run: bash tests/pr_head_ref_unit.sh
set -uo pipefail

# DIVE-2692: HARNESS-RC EXIT trap. Registered HERE, immediately after `set`, so the
# precondition exit below (a non-executable subject) is covered too, and with the
# tempdir cleanup FOLDED IN -- bash keeps only the LAST trap per signal, so a second
# `trap ... EXIT` further down would silently replace this one. `rc=$?` is captured
# BEFORE the cleanup runs: `rm` resets `$?` and the rc would report 0 on a real failure.
# `${TMP:-}` because TMP is not assigned until later and this file runs under `set -u`.
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJ="$HERE/../scripts/pr-head-ref.sh"
[ -x "$SUBJ" ] || { echo "FAIL: $SUBJ is not executable"; exit 1; }

pass=0; fail=0
TMP=$(mktemp -d)   # cleanup is folded into the single EXIT trap registered above
export GIT_CONFIG_NOSYSTEM=1 HOME="$TMP/home"; mkdir -p "$HOME"
git config --global user.email dev@example.com >/dev/null 2>&1
git config --global user.name dev >/dev/null 2>&1
git config --global init.defaultBranch main >/dev/null 2>&1
git config --global protocol.file.allow always >/dev/null 2>&1

ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $1"; printf '%s\n' "${2:-}" | sed 's/^/       | /'; }

# want_rc <name> <expected rc> <dir> <args...>
want_rc() {
  local name="$1" want="$2" dir="$3"; shift 3
  local out rc=0
  out=$(cd "$dir" && "$SUBJ" "$@" 2>&1) || rc=$?
  if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else bad "$name — wanted rc=$want got rc=$rc" "$out"; fi
}

# ---------------------------------------------------------------- fixtures
# UPSTREAM: a repo with main, plus a PR branch published ONLY as
# refs/pull/7/head. No refs/pull/7/merge anywhere — see arm 2's note.
up="$TMP/upstream"; mkdir -p "$up"; ( set -e
  cd "$up"; git init -q .
  echo base > f.txt; git add f.txt; git commit -qm base
  git checkout -q -b prbranch
  echo pr >> f.txt; git commit -qam pr
  git update-ref refs/pull/7/head "$(git rev-parse HEAD)"
  git checkout -q main
  git branch -qD prbranch
)
PR_SHA=$(cd "$up" && git rev-parse refs/pull/7/head)
BASE_SHA=$(cd "$up" && git rev-parse main)
TREE_SHA=$(cd "$up" && git rev-parse "main^{tree}")

# FALLBACK CLONE: exactly what checkout leaves behind in the recompute window —
# the base branch, heads and tags only, no PR head object at all.
fb="$TMP/fallback"
git clone -q --no-tags --no-local "file://$up" "$fb"
( cd "$fb" && git rev-parse -q --verify "${PR_SHA}^{commit}" >/dev/null 2>&1 ) \
  && { echo "FIXTURE BROKEN: the fallback clone already has the PR head"; exit 1; }

# FULL CLONE: the healthy run, where the merge ref existed and checkout worked.
full="$TMP/full"
git clone -q --no-tags --no-local "file://$up" "$full"
( cd "$full" && git fetch -q origin "+refs/pull/7/head:refs/remotes/pull/7/head" )

echo "== the head is already here =="
want_rc "present sha -> 0" 0 "$full" --sha="$PR_SHA" --pr=7
want_rc "base sha is always present -> 0" 0 "$fb" --sha="$BASE_SHA" --pr=7

echo "== the recompute window: only refs/pull/<n>/head can supply it =="
# This is the arm the row exists for. The fixture has NO refs/pull/7/merge, so a
# script that reached for the merge ref would fail here exactly as CI did.
scratch="$TMP/w1"; cp -a "$fb" "$scratch"
want_rc "absent sha, --pr given -> fetched, 0" 0 "$scratch" --sha="$PR_SHA" --pr=7
if ( cd "$scratch" && git rev-parse -q --verify "${PR_SHA}^{commit}" >/dev/null ); then
  ok "the fetch actually materialised the object"
else
  bad "the fetch reported 0 but the object is still missing" ""
fi

echo "== it must REFUSE rather than report either verdict =="
scratch2="$TMP/w2"; cp -a "$fb" "$scratch2"
missing=$(printf '%040d' 0 | tr '0' 'a')
want_rc "a sha no remote has -> 2" 2 "$scratch2" --sha="$missing" --pr=7
want_rc "a tree sha is not a commit -> 2" 2 "$full" --sha="$TREE_SHA" --pr=7
want_rc "no --sha -> 2" 2 "$full"
want_rc "unknown argument -> 2" 2 "$full" --sha="$PR_SHA" --nope

echo "== the fetch is BY refs/pull/<n>/head, not by bare sha =="
# Why this arm is separate from arm 2. A bare `git fetch <remote> <sha>` happens
# to work against a local file remote, so arm 2 cannot tell the two apart — and
# github.com does NOT serve an arbitrary sha (uploadpack.allowAnySHA1InWant is
# off), which is the whole reason the PR-head REF is the mechanism rather than a
# convenience. So record the argv and assert the refspec, the way
# tests/actionlint_scan_unit.sh grades its canary: on the invocation that
# actually happened.
shim="$TMP/shim"; mkdir -p "$shim"
realgit=$(command -v git)
cat > "$shim/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/git-argv.log"
exec "$realgit" "\$@"
EOF
chmod +x "$shim/git"
scratch3="$TMP/w3"; cp -a "$fb" "$scratch3"; : > "$TMP/git-argv.log"
rc=0; ( cd "$scratch3" && PATH="$shim:$PATH" "$SUBJ" --sha="$PR_SHA" --pr=7 ) >/dev/null 2>&1 || rc=$?
if [ "$rc" != 0 ]; then
  bad "the recorded run did not succeed" "rc=$rc"
elif grep -q 'refs/pull/7/head' "$TMP/git-argv.log"; then
  ok "the fetch names refs/pull/7/head"
else
  bad "the head was materialised WITHOUT refs/pull/<n>/head — that path is what github.com serves" "$(cat "$TMP/git-argv.log")"
fi

echo "== the three exposed jobs actually call this, and none fails open =="
# The defect this row closes lives in .github/workflows/, which no harness can
# execute. Grade the WIRING as text — the same reason
# tests/merge_queue_triggers_unit.sh arm3 is a grep: a workflow that stops
# calling the script is the defect restored, and nothing else would notice.
WF="$HERE/../.github/workflows"
for w in install-guard pii-guard pr-title-lint; do
  if grep -q 'scripts/pr-head-ref.sh' "$WF/$w.yml"; then
    ok "$w.yml materialises the PR head before it diffs"
  else
    bad "$w.yml derives a verdict from pull_request.head.sha without materialising it" ""
  fi
done
# install-guard is the fails-OPEN one: `set -uo pipefail` with no errexit meant a
# dead `git diff` produced an empty $files and fell into the "the path filter and
# the diff disagree" branch, which exits 0. Separating the two is the fix, so
# assert the failure of git is handled on its own.
if grep -q 'if ! files=$(git diff --name-only' "$WF/install-guard.yml"; then
  ok "install-guard separates 'git could not answer' from 'git answered nothing'"
else
  bad "install-guard can still collapse a dead git diff into its exit-0 branch" ""
fi

echo "== the refusal names the runner, not the pull request =="
out=$(cd "$scratch2" && "$SUBJ" --sha="$missing" --pr=7 2>&1 || true)
if grep -qi "UNDETERMINED" <<<"$out" && grep -qi "not a fact about the PR\|runner" <<<"$out"; then
  ok "the refusal says whose problem it is"
else
  bad "the refusal reads as a verdict on the PR" "$out"
fi

echo "pr-head-ref: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
