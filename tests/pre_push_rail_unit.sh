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
#   the fragment rule is RUN,       A18-A24 (DIVE-4336). The fragment lint is the
#   not restated                   second step of the required `title` context and
#                                  had no local arm: six PRs red on it in one day,
#                                  each costing a verifier grade round. A22/A23 are
#                                  its anti-drift pair — the heading string lives in
#                                  the lint script and nowhere in the rail, and
#                                  mutating that script moves the rail's verdict.
#
# NO NETWORK, NO ROOT: every arm runs against throwaway git repos under a temp
# dir. Nothing here runs the real corpus.
#
# Run: bash tests/pre_push_rail_unit.sh
set -uo pipefail
# DIVE-2692 corpus contract (tests/harness_rc_corpus_contract_unit.sh): ONE folded
# EXIT trap, registered here — before any early exit — with `rc=$?` captured FIRST
# and the marker echoed LAST, so no cleanup can disturb the code being reported.
# $TMP is created ~25 lines below, hence ${TMP:-}: under `set -u` an unset name in
# the trap body would itself abort the trap on an early exit.
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

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
FRAGLINT="$ROOT/scripts/lint-changelog-fragments.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'skip %s\n' "$1"; }

TMP="$(mktemp -d)"   # cleaned by the single folded EXIT trap at the top of this file.

# A SANDBOX REPO with its own copy of the two scripts and the title workflow, so
# an arm may MUTATE the rule the rail reads without touching this checkout. The
# rail resolves its own TOP from ${BASH_SOURCE[0]}, which is what makes this
# possible and is also the property A3 depends on.
mk_sandbox() { # <dir>
  local d="$1"
  mkdir -p "$d/scripts" "$d/.github/workflows" "$d/tests"
  cp "$RAIL" "$d/scripts/pre-push-rail.sh"
  cp "$SEL"  "$d/scripts/changed-harnesses.sh"
  # DIVE-4336: the fragment stage runs THIS script, so the sandbox needs its own
  # copy — that is what lets A23 mutate the rule and watch the verdict move.
  cp "$FRAGLINT" "$d/scripts/lint-changelog-fragments.sh"
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

# A15/A16: A CHANGED-FILES SELECTOR CANNOT SEE A CORPUS-WIDE CONTRACT, and this
# is the arm that exists because it bit this row. A harness like
# tests/harness_rc_corpus_contract_unit.sh enumerates `tests/*.sh` and asserts a
# property of EVERY OTHER harness — so ADDING a harness invalidates it while
# changing its own diff not at all. Path-keyed selection therefore returns it
# never, and the rail greens on a set chosen to exclude the check about to red
# the PR: measured on this branch's first push (`harnesses 2.5s green`, then four
# required checks red on exactly that contract).
#
# A15 requires an ADD to pull the contract in; A16 requires a pure MODIFY not to,
# because a selection that is unconditional is not a selection. Mutating the
# script back to the path-keyed rule (delete the addel block) reds A15 and leaves
# A16 and A4 green — that mutation is the one that reproduces the rejection.
SB3="$TMP/sel-corpus"; mkdir -p "$SB3/tests"
git -C "$SB3" init -q 2>/dev/null || git init -q "$SB3"
git -C "$SB3" config user.email t@example.com; git -C "$SB3" config user.name t
# A stand-in corpus contract: what makes it one is that its SOURCE enumerates the
# corpus glob, which is how the selector discovers it — not a name on a list.
printf '#!/usr/bin/env bash\nCORPUS=(tests/*.sh)\necho "${#CORPUS[@]}"\n' \
  >"$SB3/tests/some_corpus_contract_unit.sh"
: >"$SB3/tests/keep_unit.sh"
git -C "$SB3" add -A >/dev/null; git -C "$SB3" commit -qm base >/dev/null
b3="$(git -C "$SB3" rev-parse HEAD)"

: >"$SB3/tests/brand_new_unit.sh"
git -C "$SB3" add -A >/dev/null; git -C "$SB3" commit -qm add >/dev/null
sel_out="$( cd "$SB3" && bash "$SEL" "$b3" HEAD 2>/dev/null )"
{ grep -qx 'tests/brand_new_unit.sh' <<<"$sel_out" \
  && grep -qx 'tests/some_corpus_contract_unit.sh' <<<"$sel_out"; } \
  && ok "A15 a diff that only ADDS a harness selects the corpus-wide contract too — the contract's input is the corpus, not its own source" \
  || no "A15 an added harness did not pull in the corpus-wide contract: $(printf '%s' "$sel_out" | tr '\n' ' ')"

add_head="$(git -C "$SB3" rev-parse HEAD)"
echo x >"$SB3/tests/keep_unit.sh"
git -C "$SB3" add -A >/dev/null; git -C "$SB3" commit -qm modify >/dev/null
sel_out="$( cd "$SB3" && bash "$SEL" "$add_head" HEAD 2>/dev/null )"
{ grep -qx 'tests/keep_unit.sh' <<<"$sel_out" \
  && ! grep -qx 'tests/some_corpus_contract_unit.sh' <<<"$sel_out"; } \
  && ok "A16 a pure MODIFY does not pull the corpus-wide contract in — corpus membership did not change" \
  || no "A16 a modify-only diff wrongly selected the corpus-wide contract: $(printf '%s' "$sel_out" | tr '\n' ' ')"

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
# A8c: THE RECEIPT IS FINDABLE AT THE PATH THE RAIL PRINTED — which is not one
# fixed path. Since DIVE-4288 the rail writes to .git/5dive-push-override.log
# when you run the push yourself and to the root-owned
# /var/log/5dive/push-override.log when root runs it (EUID 0, i.e. every
# delegated `5dive push`). Hard-coding the .git path made this arm red on any
# ROOT-side run of this harness — exactly the run that gates a delegated push —
# while the rail was behaving correctly. Grade the property instead: the rail
# names a path, and that path holds the reason.
logpath="$(sed -n 's/^ *logged to: //p' <<<"$out" | tail -1)"
# the rail printed it from inside $SB, so a relative path resolves there.
[[ -n "$logpath" && "$logpath" != /* ]] && logpath="$SB/$logpath"
{ [[ -n "$logpath" ]] && [[ -s "$logpath" ]] && grep -q 'the harness box is offline' "$logpath"; } \
  && ok "A8c the accepted reason is written to the log the rail names ($logpath), so it is findable from the branch" \
  || no "A8c no override log was written at the printed path (printed: ${logpath:-<none>})"

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

# A17: THE RAIL GRADES THE PR RANGE, NOT THE PUSH RANGE. `git push` hands a hook
# the remote's current tip, but every CI job the rail stands in for diffs the PR
# BASE. They coincide on a branch's first push and diverge on every one after —
# so a follow-up commit that only MODIFIES would be graded against a base that
# already contains the harness an earlier commit ADDED, the corpus-wide contracts
# would not be selected (A16's rule, correctly applied to the wrong range), the
# rail would green and CI would red. Same defect class as A15, different route.
# Measured live: this branch's own second push reported "1/1 changed harness"
# while its PR range adds a harness and touches three.
#
# The arm: a sandbox with a real origin/main two commits behind, an ADD in the
# first branch commit and a MODIFY in the second, and the rail invoked with the
# PUSH base. It must widen to the merge base and select the corpus contract.
SB4="$TMP/pr-range"; mk_sandbox "$SB4"
git -C "$SB4" update-ref refs/remotes/origin/main "$(git -C "$SB4" rev-parse HEAD)"
printf '#!/usr/bin/env bash\nCORPUS=(tests/*.sh)\necho ok\n' >"$SB4/tests/a_corpus_contract_unit.sh"
: >"$SB4/tests/keep_unit.sh"
git -C "$SB4" add -A >/dev/null; git -C "$SB4" commit -qm 'chore: contract' >/dev/null
git -C "$SB4" update-ref refs/remotes/origin/main "$(git -C "$SB4" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho added\n' >"$SB4/tests/added_unit.sh"
git -C "$SB4" add -A >/dev/null; git -C "$SB4" commit -qm 'test: add' >/dev/null
push_base="$(git -C "$SB4" rev-parse HEAD)"   # what the SECOND push would hand the hook
echo x >>"$SB4/tests/keep_unit.sh"
git -C "$SB4" add -A >/dev/null; git -C "$SB4" commit -qm 'test: tweak' >/dev/null
out="$( cd "$SB4" && bash scripts/pre-push-rail.sh "$push_base" HEAD --only=harnesses 2>&1 )"; rc=$?
{ grep -q 'widening base' <<<"$out" && grep -q 'a_corpus_contract_unit.sh' <<<"$out"; } \
  && ok "A17 the rail widens the push range to the PR range, so a follow-up commit is graded against the base CI grades" \
  || no "A17 the rail graded the narrow push range (rc=$rc): $out"

# ── the changelog fragment (DIVE-4336) ────────────────────────────────────────
#
# THE DEFECT THESE CLOSE. `title` is one required context with TWO steps, and only
# the first had a local arm. Measured 2026-09-11: six PRs (#882 #894 #895 #897
# #898 #899) red on that context, every one of them on the fragment step, none on
# the type arm — so the rail greened and CI red, which is the shape of hole the
# rail exists to close, reached through the one check it did not run.
SB5="$TMP/frag"; mk_sandbox "$SB5"
frag_base="$(git -C "$SB5" rev-parse HEAD)"
frail() { ( cd "$SB5" && bash scripts/pre-push-rail.sh "$@" ) 2>&1; }

echo 'a change' >"$SB5/src_thing.sh"
git -C "$SB5" add -A >/dev/null; git -C "$SB5" commit -qm 'feat(x): a thing' >/dev/null

out="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc=$?
{ (( rc == 1 )) && grep -q 'must add a changelog.d/ fragment' <<<"$out" \
  && grep -q 'whose first line is' <<<"$out" && grep -q '## Unreleased' <<<"$out"; } \
  && ok "A18 a feat PR with no changelog.d/ fragment refuses the push AND prints the exact first line the fragment must carry" \
  || no "A18 the missing fragment did not refuse, or did not print the required first line (rc=$rc): $out"

# A24: TWO FACTS, ONE ROUND. Both door checks are ~0s and both report on the same
# required context, so the rail must not hand back the title red, take a re-push,
# and only then mention the fragment — that is the two-round cost this row exists
# to remove, reproduced locally.
out="$(PR_TITLE='just some words' frail "$frag_base" HEAD)"; rc=$?
{ (( rc == 1 )) && grep -q 'not a conventional-commit subject' <<<"$out" \
  && grep -q 'pre-push-rail: fragment' <<<"$out"; } \
  && ok "A24 a red title does not suppress the fragment stage — both door checks report in one push" \
  || no "A24 the fragment stage did not run alongside a red title (rc=$rc): $out"

# A20 first, because it runs on the SAME fragment-less range: a docs PR is a
# WARNING, not a refusal. The rail must not be stricter than the gate it stands
# in for — a local check that reds what CI passes gets overridden, then ignored.
out="$(PR_TITLE='docs(readme): a note' frail "$frag_base" HEAD --only=fragment)"; rc=$?
{ (( rc == 0 )) && grep -q '::warning' <<<"$out"; } \
  && ok "A20 a docs PR with no fragment passes and prints the lint's warning — the rail is not stricter than the gate" \
  || no "A20 a fragment-less docs PR was mis-graded (rc=$rc): $out"

out="$(PR_TITLE='not a conventional subject at all' frail "$frag_base" HEAD --only=fragment)"; rc=$?
(( rc == 0 )) \
  && ok "A20b a non-conventional title has no type, so the fragment stage says nothing — pr-title-lint owns that error, and reporting it twice teaches nobody" \
  || no "A20b the fragment stage reported on a title with no type (rc=$rc): $out"

# A21: PRESENT IS NOT ENOUGH. #882 carried a fragment and was red anyway — it
# opened `### Fixed`, which the release fold SKIPS onto a log nobody reads.
mkdir -p "$SB5/changelog.d"
printf '### Fixed\n\n- a thing\n' >"$SB5/changelog.d/DIVE-1.md"
git -C "$SB5" add -A >/dev/null; git -C "$SB5" commit -qm 'chore: bad fragment' >/dev/null
out="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc=$?
{ (( rc == 1 )) && grep -q 'would be SKIPPED by the release fold' <<<"$out"; } \
  && ok "A21 a fragment whose first line is not the fold's heading refuses the push — present is not foldable (#882's own red)" \
  || no "A21 a malformed fragment was accepted (rc=$rc): $out"

# A19: and the same branch with the fragment fixed is GREEN. Without this arm the
# stage could refuse unconditionally and A18/A21 would both still pass.
printf '## Unreleased — feat(x): a thing (DIVE-1)\n\n- a thing\n' >"$SB5/changelog.d/DIVE-1.md"
git -C "$SB5" add -A >/dev/null; git -C "$SB5" commit -qm 'chore: fix fragment' >/dev/null
out="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc=$?
{ (( rc == 0 )) && grep -q '1 changelog.d fragment(s) graded' <<<"$out"; } \
  && ok "A19 the same branch with a well-formed fragment passes, and the stage says how many it graded" \
  || no "A19 a well-formed fragment did not pass (rc=$rc): $out"

# A22/A23 ARE THE ANTI-DRIFT PAIR, and they are the reason this row says "that
# same script" rather than "the same rule". The heading is an EXACT STRING; a
# second copy of it in the rail would let the rail green what the merge gate reds
# (or the reverse) and nothing would ever say so.
#
# A22 is the static half: one script, called by both readers, restated by neither.
{ grep -q 'bash scripts/lint-changelog-fragments.sh' "$ROOT/.github/workflows/pr-title-lint.yml" \
  && grep -q 'scripts/lint-changelog-fragments.sh' "$RAIL" \
  && grep -q 'Unreleased' "$FRAGLINT" \
  && ! grep -q 'Unreleased' "$RAIL"; } \
  && ok "A22 the CI step and the rail both CALL lint-changelog-fragments.sh, and the accepted heading is written in that script and nowhere in the rail" \
  || no "A22 the fragment rule is stated in more than one place, or a caller stopped calling the script — the rail and the merge gate can now drift"

# A23 is the live half, the fragment-stage analogue of A3: mutate the rule inside
# the sandbox's own copy of the lint and require the rail's verdict to MOVE. A
# rail carrying a forked copy passes A18-A21 and fails this one.
sed -i 's/Unreleased/Zzzreleased/' "$SB5/scripts/lint-changelog-fragments.sh"
if grep -q 'Zzzreleased' "$SB5/scripts/lint-changelog-fragments.sh"; then
  out_a="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc_a=$?
  printf '## Zzzreleased — feat(x): a thing (DIVE-1)\n\n- a thing\n' >"$SB5/changelog.d/DIVE-1.md"
  git -C "$SB5" add -A >/dev/null; git -C "$SB5" commit -qm 'chore: mutated heading' >/dev/null
  out_b="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc_b=$?
  { (( rc_a == 1 )) && (( rc_b == 0 )); } \
    && ok "A23 the fragment rule is RUN from lint-changelog-fragments.sh, not forked — mutating that script moves the rail's verdict in both directions" \
    || no "A23 the rail did not follow the mutated lint (old-heading rc=$rc_a, new-heading rc=$rc_b) — it is grading a copy: $out_a | $out_b"
else
  skip "A23 could not mutate the lint rule in the sandbox"
fi

# A25: THE INSTRUMENT MISSING IS NOT A PASS THAT LOOKS LIKE A PASS. Every stage of
# this rail fails open on a missing tool and says so out loud; a fragment stage
# that printed plain `ok` with no script present would be the quietest possible
# version of the hole this row closes.
rm -f "$SB5/scripts/lint-changelog-fragments.sh"
out="$(PR_TITLE='feat(x): a thing (DIVE-1)' frail "$frag_base" HEAD --only=fragment)"; rc=$?
{ (( rc == 0 )) && grep -q 'SKIPPED' <<<"$out" && grep -q "CI's fragment step is the net" <<<"$out"; } \
  && ok "A25 with the lint script absent the stage fails OPEN and says SKIPPED — 'I could not run it' and 'it passed' print differently" \
  || no "A25 a missing lint script did not fail open loudly (rc=$rc): $out"

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
