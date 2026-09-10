#!/usr/bin/env bash
# DIVE-4208 — scripts/pre-push-rail.sh and scripts/changed-harnesses.sh.
#
# WHAT THIS GRADES, and why each arm can fail. The subject is a GUARD, and every
# way a guard can be broken presents as "green": a stage that skips, a selector
# that returns nothing, an override that accepts anything, a title rule copied
# instead of read. So the arms are mostly about the difference between a pass and
# an UNPROVEN.
#
#   the rule is READ, not COPIED   A3 mutates the workflow's own regex inside a
#                                  sandbox and requires the rail's verdict to move
#                                  with it. A forked copy passes A1/A2 and fails
#                                  this one — which is the whole anti-drift claim
#                                  of this row, and the only arm that grades it.
#   absence is not clean           A5: an unresolvable base is exit 1 and the word
#                                  BLOCKED, never an empty selection.
#   the cap does not launder       A11: over the cap, the un-run harnesses are
#                                  NAMED. A truncation reported as green is the
#                                  hole this row exists to close.
#   the override is graded         A8: five numbered clauses or refused. An
#                                  override that accepts "wip" is --no-verify with
#                                  extra steps.
#   both callers use one selector  A9/A10: the CI job calls the script and carries
#                                  no second pathspec; the hook calls the rail.
#
# NO NETWORK, NO ROOT: every arm runs against throwaway git repos under a temp
# dir. Nothing here runs the real corpus.
#
# Run: bash tests/pre_push_rail_unit.sh
set -uo pipefail

# DIVE-2211 / DIVE-2286: name the tree this harness grades.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# HERMETIC AGAINST GIT'S HOOK ENVIRONMENT. When this harness runs from a pre-push
# hook, `git push` has exported GIT_DIR, and GIT_DIR OUTRANKS `git -C <dir>` — so
# every sandbox repo below would silently be the REAL repo. Measured: 15/15 in a
# shell, 13/15 under the hook, with two failures that look like defects in the
# code under test and are not (A5, A8c). The rail scrubs these for the harnesses
# it runs (A14 grades that); this line makes the harness correct even when
# something else runs it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_QUARANTINE_PATH

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RAIL="$ROOT/scripts/pre-push-rail.sh"
SEL="$ROOT/scripts/changed-harnesses.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'skip %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A SANDBOX REPO with its own copy of the two scripts and the title workflow, so
# an arm may MUTATE the rule the rail reads without touching this checkout. The
# rail resolves its own TOP from ${BASH_SOURCE[0]}, which is what makes this
# possible and is also the property A3 depends on.
mk_sandbox() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts" "$d/.github/workflows" "$d/tests"
  cp "$RAIL" "$d/scripts/pre-push-rail.sh"
  cp "$SEL"  "$d/scripts/changed-harnesses.sh"
  cp "$ROOT/.github/workflows/pr-title-lint.yml" "$d/.github/workflows/"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm 'chore: base' >/dev/null
}

SB="$TMP/sb"; mk_sandbox "$SB"
BASE="$(git -C "$SB" rev-parse HEAD)"
rail() { ( cd "$SB" && bash scripts/pre-push-rail.sh "$@" ) 2>&1; }

# ── title ─────────────────────────────────────────────────────────────────────
out="$(PR_TITLE='feat(plugin): a thing (DIVE-1)' rail "$BASE" HEAD --only=title)"; rc=$?
(( rc == 0 )) && ok "A1 a conventional title passes the title stage" \
              || no "A1 a conventional title was rejected (rc=$rc): $out"

out="$(PR_TITLE='just some words' rail "$BASE" HEAD --only=title)"; rc=$?
{ (( rc == 1 )) && grep -q 'not a conventional-commit subject' <<<"$out"; } \
  && ok "A2 a non-conventional title refuses the push, and says why" \
  || no "A2 a non-conventional title did not refuse (rc=$rc): $out"

# A3 IS THE ANTI-DRIFT ARM. Rewrite the workflow's condition to accept only
# `zzz: ` and nothing else. A rail that READS the workflow follows the mutation
# in both directions; a rail carrying its own copy of the regex does not move at
# all, and passes A1 and A2 while being exactly the defect this row is about.
sed -i 's/(feat|fix|test|chore|docs|refactor|ci|perf)/(zzz)/' \
  "$SB/.github/workflows/pr-title-lint.yml"
if grep -q 'zzz' "$SB/.github/workflows/pr-title-lint.yml"; then
  out_a="$(PR_TITLE='zzz: mutated rule' rail "$BASE" HEAD --only=title)"; rc_a=$?
  out_b="$(PR_TITLE='feat(x): normally fine' rail "$BASE" HEAD --only=title)"; rc_b=$?
  { (( rc_a == 0 )) && (( rc_b == 1 )); } \
    && ok "A3 the rule is EXTRACTED from pr-title-lint.yml, not forked — the verdict moves with the workflow" \
    || no "A3 the rail did not follow the mutated workflow rule (zzz rc=$rc_a, feat rc=$rc_b) — it is grading a copy: $out_a | $out_b"
  git -C "$SB" checkout -- .github/workflows/pr-title-lint.yml
else
  skip "A3 could not mutate the workflow rule in the sandbox"
fi

# ── the selector ──────────────────────────────────────────────────────────────
SB2="$TMP/sel"; mkdir -p "$SB2/tests/lib" "$SB2/tests/meta"
git -C "$SB2" init -q 2>/dev/null || git init -q "$SB2"
git -C "$SB2" config user.email t@example.com; git -C "$SB2" config user.name t
: >"$SB2/tests/gone_unit.sh"; : >"$SB2/tests/keep_unit.sh"
git -C "$SB2" add -A >/dev/null; git -C "$SB2" commit -qm base >/dev/null
b2="$(git -C "$SB2" rev-parse HEAD)"
: >"$SB2/tests/new_unit.sh"; : >"$SB2/tests/lib/helper.sh"; : >"$SB2/tests/meta/probe.sh"
echo x >"$SB2/tests/keep_unit.sh"; rm "$SB2/tests/gone_unit.sh"
git -C "$SB2" add -A >/dev/null; git -C "$SB2" commit -qm next >/dev/null
sel_out="$( cd "$SB2" && bash "$SEL" "$b2" HEAD 2>/dev/null )"
want=$'tests/keep_unit.sh\ntests/new_unit.sh'
[[ "$(printf '%s\n' "$sel_out" | sort)" == "$want" ]] \
  && ok "A4 the selector takes added+modified tests/*.sh and excludes tests/lib, tests/meta and deletions" \
  || no "A4 selection is wrong: $(printf '%s' "$sel_out" | tr '\n' ' ')"

# A5: no such base, and no origin/main to fall back to.
sel_out="$( cd "$SB2" && bash "$SEL" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef HEAD 2>&1 )"; rc=$?
{ (( rc == 1 )) && grep -q 'BLOCKED' <<<"$sel_out"; } \
  && ok "A5 an unresolvable base is BLOCKED (exit 1), never an empty selection" \
  || no "A5 an unresolvable base did not block (rc=$rc): $sel_out"

# ── shellcheck stage ──────────────────────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  # SC2318 is the DIVE-4067 code: a WARNING that the -S error pass drops, and the
  # one that emptied every box. If the rail only ran `-S error` this arm greens.
  cat >"$SB/scripts/sc2318_probe.sh" <<'EOF'
#!/usr/bin/env bash
f() { local dir="$HOME/x" f="$dir/y"; echo "$f"; }
f
EOF
  git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'chore: probe' >/dev/null
  out="$(rail "$BASE" HEAD --only=shellcheck)"; rc=$?
  { (( rc == 1 )) && grep -q 'SC2318' <<<"$out"; } \
    && ok "A6 a changed script carrying SC2318 refuses the push (the code -S error drops)" \
    || no "A6 SC2318 in a changed script did not refuse (rc=$rc): $out"
  git -C "$SB" reset -q --hard "$BASE"
  # And a diff with no linted shell file in it is a PASS, not a skip.
  echo hi >"$SB/README.md"; git -C "$SB" add -A >/dev/null
  git -C "$SB" commit -qm 'docs: readme' >/dev/null
  out="$(rail "$BASE" HEAD --only=shellcheck)"; rc=$?
  { (( rc == 0 )) && grep -q 'no linted shell file' <<<"$out"; } \
    && ok "A7 a diff with no linted shell file passes the stage and says so" \
    || no "A7 unexpected verdict on a shell-free diff (rc=$rc): $out"
  git -C "$SB" reset -q --hard "$BASE"
else
  skip "A6/A7 shellcheck is not installed here — the lint arms did not run (CI installs it)"
fi

# ── the harness stage and its cap ─────────────────────────────────────────────
cat >"$SB/tests/slow_unit.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$SB/tests/other_unit.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'test: two' >/dev/null
out="$(FIVE_PUSH_RAIL_CAP=0 rail "$BASE" HEAD --only=harnesses)"; rc=$?
{ (( rc == 0 )) && grep -q 'OVER THE 0s CAP' <<<"$out" \
  && grep -q 'tests/slow_unit.sh' <<<"$out" && grep -q 'run them by hand' <<<"$out"; } \
  && ok "A11 over the cap the un-run harnesses are NAMED with the command to run them, not silently dropped" \
  || no "A11 the cap did not name what it dropped (rc=$rc): $out"

cat >"$SB/tests/red_unit.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'test: red' >/dev/null
out="$(rail "$BASE" HEAD --only=harnesses)"; rc=$?
{ (( rc == 1 )) && grep -q 'FAILED: tests/red_unit.sh' <<<"$out"; } \
  && ok "A12 a touched harness that fails here refuses the push and is named" \
  || no "A12 a red harness did not refuse (rc=$rc): $out"

# ── the audited override ──────────────────────────────────────────────────────
out="$(FIVE_PUSH_OVERRIDE='no time, shipping it' rail "$BASE" HEAD --only=harnesses)"; rc=$?
{ (( rc == 1 )) && grep -q 'OVERRIDE REFUSED' <<<"$out"; } \
  && ok "A8a an override reason without the five numbered clauses is refused" \
  || no "A8a a bare override reason was accepted (rc=$rc): $out"

five=$'1) the harness box is offline\n2) ran the two sibling harnesses, 2/2 green\n3) residual: the shard this diff touches\n4) signing because the change is comment-only\n5) uncovered: the installed-host environment'
out="$(FIVE_PUSH_OVERRIDE="$five" rail "$BASE" HEAD)"; rc=$?
{ (( rc == 0 )) && grep -q 'OVERRIDDEN' <<<"$out" && ! grep -q 'FAILED: tests/red_unit.sh' <<<"$out"; } \
  && ok "A8b a five-clause reason is accepted, printed, and skips the rail (the red harness above did not run)" \
  || no "A8b the five-clause override did not take (rc=$rc): $out"
[[ -s "$SB/.git/5dive-push-override.log" ]] \
  && ok "A8c the accepted reason is written to .git/5dive-push-override.log, so it is findable from the branch" \
  || no "A8c no override log was written"

# A13: THE CAP MUST BOUND ONE HARNESS. A between-harnesses check lets a single
# long file run arbitrarily past the cap — measured at >10 min against a 360s cap
# while timing this rail over real merges. And the outcome is NOT-GRADED, a third
# thing: it must be named, and it must NOT refuse the push, because "we did not
# find out" is not "it failed".
git -C "$SB" reset -q --hard "$BASE"
# mkdir, because `reset --hard` REMOVES a directory that its tracked files made
# non-empty — tests/ is gone here, and a heredoc into a missing directory fails
# silently enough that this arm graded an EMPTY selection and read as a cap bug.
mkdir -p "$SB/tests"
cat >"$SB/tests/sleepy_unit.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'test: sleepy' >/dev/null
if command -v timeout >/dev/null 2>&1; then
  start=$(date +%s)
  out="$(FIVE_PUSH_RAIL_CAP=2 rail "$BASE" HEAD --only=harnesses)"; rc=$?
  took=$(( $(date +%s) - start ))
  { (( rc == 0 )) && (( took < 20 )) \
    && grep -q 'NOT GRADED' <<<"$out" && grep -q 'tests/sleepy_unit.sh' <<<"$out"; } \
    && ok "A13 the cap bounds a SINGLE harness — it is stopped at the remaining budget, named NOT GRADED, and does not refuse the push (${took}s)" \
    || no "A13 one harness ran past the cap or was mis-graded (rc=$rc, ${took}s): $out"
else
  skip "A13 coreutils timeout is not installed here — the per-harness budget could not be graded"
fi
git -C "$SB" reset -q --hard "$BASE"

# A14: THE HOOK'S GIT ENVIRONMENT MUST NOT REACH THE HARNESSES. `git push`
# exports GIT_DIR into its hooks, and GIT_DIR OUTRANKS `git -C <dir>` — so a
# harness driving a throwaway repo grades the REAL one. Measured on this rail's
# own first push: this very file is 15/15 in a shell and 13/15 under the hook.
# The arm below is that failure, made a test: a harness that reports which tree
# it is standing in must report its OWN, with GIT_DIR pointing somewhere else.
git -C "$SB" reset -q --hard "$BASE"
mkdir -p "$SB/tests"
cat >"$SB/tests/wheres_my_tree_unit.sh" <<'EOF'
#!/usr/bin/env bash
# The shape every repo harness has: build a throwaway repo, drive it with
# `git -C`. Under an inherited GIT_DIR that reads the PUSHING repo instead.
own="$(mktemp -d)"; trap 'rm -rf "$own"' EXIT
git -C "$own" init -q
# A repo just initialised has NO commit, so this must be empty. Under an
# inherited GIT_DIR it resolves the PUSHING repo's HEAD instead — the same
# substitution that made A5 read a real origin/main into a sandbox with none.
seen="$(git -C "$own" rev-parse --verify --quiet HEAD)"
[[ -z "$seen" ]] || { echo "a fresh repo reported HEAD=$seen — this is not my tree"; exit 1; }
EOF
git -C "$SB" add -A >/dev/null; git -C "$SB" commit -qm 'test: tree' >/dev/null
# GIT_DIR set the way `git push` sets it for a hook: the repo BEING PUSHED, which
# here is the sandbox itself. That is faithful, and it is enough to break a
# harness that builds its own repo.
out="$( GIT_DIR="$SB/.git" rail "$BASE" HEAD --only=harnesses )"; rc=$?
{ (( rc == 0 )) && grep -q '1/1 changed harness(es) green' <<<"$out"; } \
  && ok "A14 a harness runs with the hook's GIT_DIR scrubbed, so it grades its own tree and not the pushing repo" \
  || no "A14 the hook's git environment reached the harness (rc=$rc): $out"
git -C "$SB" reset -q --hard "$BASE"

# ── both callers use the one selector ─────────────────────────────────────────
wf="$ROOT/.github/workflows/unit-tests.yml"
{ grep -q 'bash scripts/changed-harnesses.sh' "$wf" \
  && ! grep -q "diff-filter=ACMR .*'tests/\*\.sh'" "$wf"; } \
  && ok "A9 the changed-harnesses CI job CALLS the selector and carries no second copy of the pathspec" \
  || no "A9 unit-tests.yml still selects harnesses itself — the rail and the merge gate can drift"

grep -q 'scripts/pre-push-rail.sh' "$ROOT/scripts/git-hooks/pre-push" \
  && ok "A10 the repo-shipped pre-push hook runs the rail" \
  || no "A10 the pre-push hook does not call the rail — nothing runs it at push time"

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
