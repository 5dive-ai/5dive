#!/usr/bin/env bash
# DIVE-4177 — a changelog fragment that the fold would SKIP must not be mergeable, and
# a cut that would drop one must not publish.
#
# THE MEASURED DEFECT. v0.29.0 (3bf6519e) folded 11 fragments and skipped six whose
# first line was not `## Unreleased` — `## Added`, bare prose, a `- fix(...)` bullet.
# The skip printed on stderr inside the cut and release-cut.yml published anyway, so
# the public notes listed two entries and NO feature for a release correctly derived
# MINOR from three `feat` commits. v0.30.0 repeated it: `feat(task): ephemeral graders`
# forced the minor and is absent from its own notes. A seventh entry (DIVE-4144) was
# not skipped at all — it wrote no fragment.
#
# WHAT THESE ARMS GRADE, and why in this shape:
#   - the LINT at PR time (rules 1 and 2), because that is what makes the refusal below
#     unable to fire on a clean main;
#   - the FOLD's refusal, by running the shipped script against a tree with one
#     malformed fragment rather than reading its source (a source read is not an
#     execution);
#   - the AGREEMENT between the two: the accepted-heading pattern is one string in two
#     files, and a drift admits at the door exactly what the cut then drops. That arm is
#     the cross-seam one — mutating either side alone must red it.
#   - the WIRING, because a correct script no workflow calls grades nothing.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TD:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/lint-changelog-fragments.sh"
FOLD="$ROOT/scripts/fold-changelog-fragments.sh"
WF="$ROOT/.github/workflows/pr-title-lint.yml"
CUT="$ROOT/.github/workflows/release-cut.yml"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}" >&2; }

for f in "$LINT" "$FOLD" "$WF" "$CUT"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f — refusing to grade nothing" >&2; exit 2; }
done

TD="$(mktemp -d)"

# A throwaway tree with a changelog.d/. Prints the dir.
mk_tree() {
  local d; d="$(mktemp -d -p "$TD")"
  mkdir -p "$d/changelog.d"
  printf '# Changelog\n\n## v0.1.0 — seed\n' > "$d/CHANGELOG.md"
  printf '# changelog.d/ — docs, not an entry\n' > "$d/changelog.d/README.md"
  printf '%s' "$d"
}

# run_lint <dir> <title> <changed-path>...   -> rc, output in $OUT
run_lint() {
  local d="$1" title="$2"; shift 2
  local changed="$d/.changed"
  : > "$changed"
  local p; for p in "$@"; do printf '%s\n' "$p" >> "$changed"; done
  OUT="$(cd "$d" && bash "$LINT" --title="$title" --changed-from=.changed 2>&1)"
}

# --- Rule 1: a fragment the fold would skip reds, and the error carries the fix ------
d="$(mk_tree)"
printf '## Added\n\n- something\n' > "$d/changelog.d/DIVE-9001.md"
run_lint "$d" 'feat(x): a thing (DIVE-9001)' 'changelog.d/DIVE-9001.md'
rc=$?
if [[ $rc -ne 0 ]] && grep -q 'DIVE-9001.md' <<<"$OUT" && grep -q 'want: the first non-blank line must be' <<<"$OUT"; then
  ok_t 'a `## Added` first line reds the lint and names the wanted first line'
else
  bad_t 'a `## Added` first line reds the lint and names the wanted first line' "rc=$rc out=$OUT"
fi

# The exact shapes measured on v0.29.0, run as data rather than restated in prose.
i=0
for bad in '- fix(heartbeat): a bullet, no heading' 'DIVE-4086: bare prose, no heading' '### Testing' '## Fixed'; do
  i=$((i+1))
  d="$(mk_tree)"
  printf '%s\n' "$bad" > "$d/changelog.d/DIVE-90${i}0.md"
  run_lint "$d" 'fix(x): a thing' "changelog.d/DIVE-90${i}0.md"
  rc=$?
  [[ $rc -ne 0 ]] && ok_t "a v0.29.0-shaped malformed fragment reds: ${bad:0:32}" \
                  || bad_t "a v0.29.0-shaped malformed fragment reds: ${bad:0:32}" "rc=$rc out=$OUT"
done

# --- The accepted shapes must PASS, or the lint is a wall, not a gate ---------------
for good in '## Unreleased — feat(release): a headline (DIVE-9002)' '## Unreleased'; do
  d="$(mk_tree)"
  printf '%s\n\nprose\n' "$good" > "$d/changelog.d/DIVE-9002.md"
  run_lint "$d" 'feat(release): a headline (DIVE-9002)' 'changelog.d/DIVE-9002.md'
  rc=$?
  [[ $rc -eq 0 ]] && ok_t "an accepted heading passes: ${good:0:28}" \
                  || bad_t "an accepted heading passes: ${good:0:28}" "rc=$rc out=$OUT"
done

# A leading blank line is not a defect — the fold reads the first NON-BLANK line.
d="$(mk_tree)"
printf '\n\n## Unreleased — fix(x): y (DIVE-9003)\n' > "$d/changelog.d/DIVE-9003.md"
run_lint "$d" 'fix(x): y (DIVE-9003)' 'changelog.d/DIVE-9003.md'
[[ $? -eq 0 ]] && ok_t 'leading blank lines before the heading are accepted' \
               || bad_t 'leading blank lines before the heading are accepted' "$OUT"

# --- Rule 2: a feat/fix PR with no fragment at all (DIVE-4144's shape) --------------
d="$(mk_tree)"
run_lint "$d" 'feat(task): ephemeral graders (DIVE-9004)' 'src/cmd_task.sh'
rc=$?
if [[ $rc -ne 0 ]] && grep -q "must add a changelog.d/ fragment" <<<"$OUT"; then
  ok_t 'a feat PR with no fragment reds (the DIVE-4144 shape)'
else
  bad_t 'a feat PR with no fragment reds (the DIVE-4144 shape)' "rc=$rc out=$OUT"
fi

d="$(mk_tree)"
run_lint "$d" 'fix(cut): a thing' 'src/x.sh'
[[ $? -ne 0 ]] && ok_t 'a fix PR with no fragment reds' || bad_t 'a fix PR with no fragment reds' "$OUT"

# ...and the types a release-notes reader is NOT looking for stay warn-only.
for t in test ci chore docs refactor perf; do
  d="$(mk_tree)"
  run_lint "$d" "${t}(x): a thing" 'src/x.sh'
  rc=$?
  if [[ $rc -eq 0 ]] && grep -q '::warning' <<<"$OUT"; then
    ok_t "a '${t}' PR with no fragment warns, does not red"
  else
    bad_t "a '${t}' PR with no fragment warns, does not red" "rc=$rc out=$OUT"
  fi
done

# A title with no conventional type is pr-title-lint's error and must not be reported
# twice — this step must not be the thing that explains a title problem.
d="$(mk_tree)"
run_lint "$d" 'no type here at all' 'src/x.sh'
rc=$?
[[ $rc -eq 0 ]] && ok_t 'an untyped title is left to pr-title-lint, not double-reported' \
                || bad_t 'an untyped title is left to pr-title-lint, not double-reported' "rc=$rc out=$OUT"

# --- Scope: README.md, deletions, and other people's fragments ----------------------
d="$(mk_tree)"
run_lint "$d" 'docs(changelog): rewrite the README' 'changelog.d/README.md'
rc=$?
[[ $rc -eq 0 ]] && ok_t "changelog.d/README.md is not graded as a fragment" \
                || bad_t "changelog.d/README.md is not graded as a fragment" "rc=$rc out=$OUT"

d="$(mk_tree)"
run_lint "$d" 'chore(changelog): withdraw an entry' 'changelog.d/DIVE-9005.md'
rc=$?
[[ $rc -eq 0 ]] && ok_t 'a fragment DELETED by the PR is not graded' \
                || bad_t 'a fragment DELETED by the PR is not graded' "rc=$rc out=$OUT"

# The load-bearing scope arm: main carries fragments that predate this lint. Grading
# the whole directory would red every unrelated PR with somebody else's defect, and a
# lint everyone learns to override is not a gate.
d="$(mk_tree)"
printf '## Added\n' > "$d/changelog.d/DIVE-8000.md"                                  # not this PR's
printf '## Unreleased — fix(x): y (DIVE-9006)\n' > "$d/changelog.d/DIVE-9006.md"     # this PR's
run_lint "$d" 'fix(x): y (DIVE-9006)' 'changelog.d/DIVE-9006.md'
rc=$?
[[ $rc -eq 0 ]] && ok_t "a pre-existing malformed fragment this PR did not touch does not red it" \
                || bad_t "a pre-existing malformed fragment this PR did not touch does not red it" "rc=$rc out=$OUT"

# --- The FOLD's refusal, EXECUTED, not read ----------------------------------------
mk_repo() {
  local d; d="$(mktemp -d -p "$TD")"
  ( cd "$d"
    git init -q .
    git config user.email a@b; git config user.name t
    mkdir -p changelog.d
    printf '# Changelog\n\n## v0.1.0 — seed\n' > CHANGELOG.md
    git add -A >/dev/null 2>&1
    git -c user.name=t -c user.email=a@b commit -q -m seed >/dev/null 2>&1
  ) >/dev/null 2>&1
  printf '%s' "$d"
}

d="$(mk_repo)"
printf '## Unreleased — feat(x): good (DIVE-9010)\n' > "$d/changelog.d/DIVE-9010.md"
printf '## Added\n\n- dropped silently\n'            > "$d/changelog.d/DIVE-9011.md"
out="$(cd "$d" && FOLD_RELEASED_BASELINE="" bash "$FOLD" 2>&1)"; rc=$?
if [[ $rc -eq 3 ]] && grep -q 'DIVE-9011.md' <<<"$out" && grep -qi 'refusing' <<<"$out"; then
  ok_t 'the fold EXITS 3 on a malformed fragment and names the file'
else
  bad_t 'the fold EXITS 3 on a malformed fragment and names the file' "rc=$rc out=$out"
fi

# Its own exit code, because release-cut maps a GENERIC non-zero to "publish anyway".
# If the refusal shared that code the cut would keep publishing dropped entries; if it
# took over every non-zero, an unrelated fold failure would kill a cut.
d="$(mk_repo)"
printf '## Unreleased — feat(x): good (DIVE-9012)\n' > "$d/changelog.d/DIVE-9012.md"
out="$(cd "$d" && FOLD_RELEASED_BASELINE="" bash "$FOLD" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && [[ "$(tail -1 <<<"$out")" == "1" ]]; then
  ok_t 'a clean tree still folds and still exits 0 printing the count'
else
  bad_t 'a clean tree still folds and still exits 0 printing the count' "rc=$rc out=$out"
fi
[[ ! -f "$d/changelog.d/DIVE-9012.md" ]] && ok_t 'the folded fragment is still consumed' \
                                         || bad_t 'the folded fragment is still consumed' 'fragment survived'

# A tree with NO fragments at all is a normal cut, not a refusal.
d="$(mk_repo)"
out="$(cd "$d" && FOLD_RELEASED_BASELINE="" bash "$FOLD" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok_t 'an empty changelog.d still exits 0' || bad_t 'an empty changelog.d still exits 0' "rc=$rc $out"

# --- THE SEAM. One pattern, two files. --------------------------------------------
pat_lint="$(grep -m1 -o "readonly FRAGMENT_HEADING_RE=.*" "$LINT")"
pat_fold="$(grep -m1 -o "readonly FRAGMENT_HEADING_RE=.*" "$FOLD")"
if [[ -n "$pat_lint" && "$pat_lint" == "$pat_fold" ]]; then
  ok_t 'the accepted-heading pattern is byte-identical in the lint and the fold'
else
  bad_t 'the accepted-heading pattern is byte-identical in the lint and the fold' "lint=[$pat_lint] fold=[$pat_fold]"
fi

# The agreement that actually matters is behavioural, so grade it that way too: every
# heading the lint admits must FOLD, and every one it rejects must be REFUSED. A
# one-sided read of the pattern string cannot catch a divergent use of it.
i=0
for h in '## Unreleased' '## Unreleased — feat(x): y (DIVE-9020)' '## Added' '### Testing' 'bare prose'; do
  i=$((i+1)); frag="DIVE-903${i}.md"
  d="$(mk_repo)"; printf '%s\n' "$h" > "$d/changelog.d/$frag"
  ( cd "$d" && FOLD_RELEASED_BASELINE="" bash "$FOLD" >/dev/null 2>&1 ); fold_rc=$?
  dl="$(mk_tree)"; printf '%s\n' "$h" > "$dl/changelog.d/$frag"
  run_lint "$dl" 'feat(x): y' "changelog.d/$frag"; lint_rc=$?
  fold_bad=$(( fold_rc == 3 ? 1 : 0 )); lint_bad=$(( lint_rc != 0 ? 1 : 0 ))
  [[ "$fold_bad" -eq "$lint_bad" ]] \
    && ok_t "lint and fold agree on: ${h:0:34}" \
    || bad_t "lint and fold agree on: ${h:0:34}" "fold_rc=$fold_rc lint_rc=$lint_rc"
done

# --- WIRING. A correct script nothing calls grades nothing. -------------------------
if grep -q 'scripts/lint-changelog-fragments.sh' "$WF"; then
  ok_t 'pr-title-lint.yml invokes the fragment lint'
else
  bad_t 'pr-title-lint.yml invokes the fragment lint' 'not referenced'
fi
# It has to be in the job that reports the REQUIRED `title` context, or it blocks nothing.
if [[ "$(grep -cE '^  [a-z_-]+:$' <<<"$(sed -n '/^jobs:/,$p' "$WF")")" -eq 1 ]]; then
  ok_t 'the fragment lint reports under the single (required) job in pr-title-lint.yml'
else
  bad_t 'the fragment lint reports under the single (required) job in pr-title-lint.yml' \
        'a second job would be an unrequired context that blocks no merge'
fi
if grep -q 'fetch-depth: 0' "$WF"; then
  ok_t 'the workflow fetches enough history to diff against the base sha'
else
  bad_t 'the workflow fetches enough history to diff against the base sha' 'shallow clone cannot reach base.sha'
fi
if grep -q '_fold_rc" -eq 3' "$CUT" && grep -q 'REFUSING to cut' "$CUT"; then
  ok_t 'release-cut.yml turns the fold-refusal exit 3 into a failed cut'
else
  bad_t 'release-cut.yml turns the fold-refusal exit 3 into a failed cut' 'rc 3 not distinguished'
fi
if grep -q 'publishing anyway' "$CUT"; then
  ok_t 'a non-3 fold failure still only warns (a cut must not die over a changelog)'
else
  bad_t 'a non-3 fold failure still only warns (a cut must not die over a changelog)' 'warning path gone'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
