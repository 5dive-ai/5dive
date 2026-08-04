#!/usr/bin/env bash
# DIVE-2433: scripts/grade-release-commit.sh — the grade the release commit never had.
#
# The property under test is NOT "does it run the tests". It is the three-state exit
# contract, because the defect this row exists to close is an object that was never
# graded while a published record said it was. A grader that cannot tell "clean" from
# "never ran" reproduces that defect one layer down, so every arm below is about
# keeping those two apart.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRADE="${GRADE:-$HERE/../scripts/grade-release-commit.sh}"

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

pass=0; fail=0
ok(){ if eval "$2"; then echo "ok   - $1"; pass=$((pass+1)); else echo "FAIL - $1"; fail=$((fail+1)); fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# A stand-in bundle whose behaviour each arm controls. The real bundle is 53k lines;
# what is being graded here is the GRADER, so the artifact is stubbed deliberately.
mk_bundle() { # $1=version-line $2=selfcheck-rc $3=help-rc
  cat > "$T/5dive" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version)  printf '5dive %s\n' "$1" ;;
  --help)     exit $3 ;;
  selfcheck)  exit $2 ;;
  *)          exit 0 ;;
esac
EOF
  chmod +x "$T/5dive"
}
mk_tests() { # $@ = exit codes, one harness each
  rm -rf "$T/tests"; mkdir -p "$T/tests"; local i=0 c
  for c in "$@"; do i=$((i+1)); printf '#!/usr/bin/env bash\nexit %s\n' "$c" > "$T/tests/t$i.sh"; done
}
# shellcheck disable=SC2034  # OUT/RC are read inside the eval'd assertion strings
run() { OUT=$(cd "$T" && GRC_BUNDLE=./5dive GRC_TESTS_GLOB='tests/*.sh' bash "$GRADE" "$@" 2>&1); RC=$?; }

# ---- 1. THE CLEAN PATH ----
mk_bundle 0.17.10 0 0; mk_tests 0 0 0
run 0.17.10
ok "CLEAN: exits 0 when the artifact and the corpus both pass" "[[ $RC -eq 0 ]]"
ok "CLEAN: says PASS and names the version it graded" "grep -q 'PASS — 0.17.10 graded on the exact artifact' <<<\"\$OUT\""
ok "CLEAN: reports how many harnesses actually ran" "grep -q 'corpus ran 3 harness' <<<\"\$OUT\""

# ---- 2. FAILURES ARE 1, AND EACH IS NAMED ----
mk_bundle 0.17.10 1 0; mk_tests 0
run 0.17.10
ok "SELFCHECK-FAIL: exits 1" "[[ $RC -eq 1 ]]"
ok "SELFCHECK-FAIL: names selfcheck as the failure" "grep -q 'selfcheck did not pass' <<<\"\$OUT\""
ok "SELFCHECK-FAIL: does NOT report PASS" "! grep -q 'PASS —' <<<\"\$OUT\""

mk_bundle 0.17.9 0 0; mk_tests 0
run 0.17.10
ok "VERSION-MISMATCH: a bundle reporting the WRONG version exits 1" "[[ $RC -eq 1 ]]"
ok "VERSION-MISMATCH: names both the got and the expected version" \
  "grep -q \"reports '0.17.9' from --version, expected '0.17.10'\" <<<\"\$OUT\""

mk_bundle 0.17.10 0 1; mk_tests 0
run 0.17.10
ok "HELP-FAIL: a bundle that cannot print --help exits 1" "[[ $RC -eq 1 ]]"

mk_bundle 0.17.10 0 0; mk_tests 0 1 0
run 0.17.10
ok "CORPUS-FAIL: one red harness exits 1" "[[ $RC -eq 1 ]]"
ok "CORPUS-FAIL: names the failing harness" "grep -q 'FAIL — tests/t2.sh' <<<\"\$OUT\""
ok "CORPUS-FAIL: still reports the counts, so the reader sees 3 ran / 1 failed" \
  "grep -q 'corpus ran 3 harness(es), 1 failed' <<<\"\$OUT\""

# ---- 3. UNDETERMINED IS 2 AND IS NEVER A PASS — the point of the row ----
mk_bundle 0.17.10 0 0; mk_tests   # no harnesses at all
run 0.17.10
ok "EMPTY-CORPUS: exits 2, NOT 0 — no harness ran, so nothing was graded" "[[ $RC -eq 2 ]]"
ok "EMPTY-CORPUS: says UNDETERMINED and NOT a pass" \
  "grep -q 'UNDETERMINED' <<<\"\$OUT\" && grep -q 'NOT a pass' <<<\"\$OUT\""
ok "EMPTY-CORPUS: does NOT report PASS" "! grep -q 'PASS —' <<<\"\$OUT\""

rm -f "$T/5dive"; mk_tests 0
run 0.17.10
ok "NO-BUNDLE: exits 2 rather than grading nothing and reporting clean" "[[ $RC -eq 2 ]]"
ok "NO-BUNDLE: says the released artifact was never run" \
  "grep -q 'never run' <<<\"\$OUT\" && grep -q 'NOT a pass' <<<\"\$OUT\""

mk_bundle 0.17.10 0 0; mk_tests 0
run
ok "NO-VERSION-ARG: exits 2 rather than defaulting to something and passing" "[[ $RC -eq 2 ]]"
ok "NO-VERSION-ARG: says UNDETERMINED" "grep -q 'UNDETERMINED' <<<\"\$OUT\""

# ---- 4. THE THREE STATES ARE DISTINCT (a caller can act on each) ----
ok "0, 1 and 2 are three DIFFERENT codes, so 'clean' and 'could not look' never collide" \
  "[[ 0 -ne 1 && 1 -ne 2 && 0 -ne 2 ]]"

# =================================================================================
# DIVE-2524. Two properties, and they fail in opposite directions, which is why they
# are graded apart:
#
#   ITEM 1 — a FAILURE MUST CARRY ITS EVIDENCE. The old shape sent every harness's
#   output to /dev/null and printed three bare `FAIL — tests/x.sh` lines. Six nights
#   of red went unread because no reader could tell a regression from a missing
#   token. That is a fails-QUIET defect.
#
#   ITEM 2 — the CHEAP PATH MUST EARN ITSELF. Delta mode inherits the parent's
#   check-runs for everything outside the release-commit delta. If the premise it
#   inherits on is ever false, this script reports a pass over an object nobody
#   graded — the exact defect DIVE-2433 exists to close, rebuilt inside its own fix.
#   That is a fails-OPEN defect, so every arm below asks whether the refusal HOLDS,
#   not whether the happy path works.
# =================================================================================

# A release tree with real git history. The delta assertion reads `git diff` and
# nothing else, so the fixture has to be a repo — stubbing the diff would grade the
# stub. `-c` flags rather than `git config` so this never reads the caller's identity.
_git() { git -C "$T/repo" -c user.name=t -c user.email=t@example.com "$@"; }
mk_repo() { # $1.. = paths the RELEASE commit changes on top of the parent
  rm -rf "$T/repo"; mkdir -p "$T/repo/src" "$T/repo/tests"
  _git init -q 2>/dev/null || git -C "$T/repo" init -q
  printf 'readonly FIVE_VERSION="0.0.0-dev"\n' > "$T/repo/src/header.sh"
  printf 'x\n' > "$T/repo/CHANGELOG.md"; printf 'x\n' > "$T/repo/other.sh"
  _git add -A >/dev/null; _git commit -qm parent
  PARENT=$(_git rev-parse HEAD)
  local p
  for p in "$@"; do mkdir -p "$(dirname "$T/repo/$p")"; printf 'changed %s\n' "$p" >> "$T/repo/$p"; done
  if [[ $# -gt 0 ]]; then _git add -A >/dev/null; _git commit -qm release; fi
}
# The bundle and harnesses live INSIDE the repo, because the script runs from the
# release tree root and that is where git resolves HEAD.
repo_bundle() { # $1=version
  cat > "$T/repo/5dive" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) printf '5dive %s\n' "$1" ;;
  *)         exit 0 ;;
esac
EOF
  chmod +x "$T/repo/5dive"
}
repo_tests() { # $@ = exit codes
  rm -rf "$T/repo/tests"; mkdir -p "$T/repo/tests"; local i=0 c
  for c in "$@"; do i=$((i+1))
    printf '#!/usr/bin/env bash\necho "ASSERTION-DETAIL-%s: the reason this harness failed"\nexit %s\n' "$i" "$c" \
      > "$T/repo/tests/t$i.sh"
  done
}
# shellcheck disable=SC2034  # OUT/RC are read inside the eval'd assertion strings
runr() { OUT=$(cd "$T/repo" && GRC_BUNDLE=./5dive GRC_TESTS_GLOB='tests/*.sh' \
               GRC_DELTA_TESTS="${DTESTS:-tests/t1.sh}" GRADE_ENV_MARK=1 \
               bash "${GRADE_UNDER_TEST:-$GRADE}" "$@" 2>&1); RC=$?; }

# ---- 5. ITEM 1: THE FAILURE CARRIES ITS OWN OUTPUT ----
# Non-vacuity matters here: asserting "FAIL — tests/t2.sh" appears would have passed
# on the OLD script too. The arm has to demand a string only the harness's own stdout
# can produce.
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 0 1 0
runr 0.17.11
ok "EVIDENCE: a failing harness's OWN OUTPUT reaches the log, not just its name" \
  "grep -q 'ASSERTION-DETAIL-2' <<<\"\$OUT\""
ok "EVIDENCE: the output is fenced and attributed to the harness that produced it" \
  "grep -q 'last 25 lines of tests/t2.sh' <<<\"\$OUT\" && grep -q 'end tests/t2.sh' <<<\"\$OUT\""
ok "EVIDENCE: a PASSING harness stays quiet — a green corpus must not bury the verdict" \
  "! grep -q 'ASSERTION-DETAIL-1' <<<\"\$OUT\""
ok "EVIDENCE: the verdict still names the harness and still exits 1" \
  "[[ $RC -eq 1 ]] && grep -q 'FAIL — tests/t2.sh' <<<\"\$OUT\""

# ---- 6. ITEM 2: DELTA MODE, AND EVERY WAY ITS PREMISE CAN BE FALSE ----
# The happy path first, only so the refusals below are known to be refusing something
# that would otherwise have run.
mk_repo src/header.sh 5dive 5dive.sha256 CHANGELOG.md; repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 "$PARENT"
ok "DELTA: a delta inside the release-commit set grades the subset and exits 0" "[[ $RC -eq 0 ]]"
ok "DELTA: says it is INHERITING, so the log records that the corpus was not run" \
  "grep -q 'inheriting the parent' <<<\"\$OUT\""
ok "DELTA: the PASS names the parent it inherited from — a pass that cites no parent is unauditable" \
  "grep -q 'inherited from parent' <<<\"\$OUT\""
ok "DELTA: reports a DELTA corpus count, distinguishable from a full-corpus run" \
  "grep -q 'delta corpus ran 1 harness' <<<\"\$OUT\""

# THE PREMISE BREAKS — one path outside the set and the parent's green describes a
# different tree. UNDETERMINED, never a pass, and never a plain failure either.
mk_repo src/header.sh other.sh; repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 "$PARENT"
ok "WIDER-DELTA: a path outside the release-commit set is UNDETERMINED (2), not 0 and not 1" \
  "[[ $RC -eq 2 ]]"
ok "WIDER-DELTA: NAMES the offending path rather than refusing anonymously" \
  "grep -q 'other.sh' <<<\"\$OUT\""
ok "WIDER-DELTA: says NOT a pass and does not print PASS" \
  "grep -q 'NOT a pass' <<<\"\$OUT\" && ! grep -q 'PASS —' <<<\"\$OUT\""

# ANTI-VACUITY. A subset test over an empty diff passes trivially, so a cut whose
# version write silently did nothing would inherit a green on an unchanged tree. This
# is the arm that distinguishes "proved the delta" from "found no counterexample".
mk_repo; repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 "$PARENT"
ok "EMPTY-DELTA: an EMPTY diff is UNDETERMINED — the subset check proved nothing" \
  "[[ $RC -eq 2 ]]"
ok "EMPTY-DELTA: names src/header.sh as the write that never landed" \
  "grep -q 'src/header.sh' <<<\"\$OUT\" && grep -q 'version assignment never landed' <<<\"\$OUT\""

mk_repo 5dive 5dive.sha256; repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 "$PARENT"
ok "NO-VERSION-WRITE: a delta that rebundles but never assigns the version is UNDETERMINED" \
  "[[ $RC -eq 2 ]]"

mk_repo src/header.sh; repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
ok "UNRESOLVABLE-PARENT: a parent git cannot resolve is UNDETERMINED, not an inherited pass" \
  "[[ $RC -eq 2 ]]"
ok "UNRESOLVABLE-PARENT: says the inheritance is unproven" \
  "grep -q 'unproven' <<<\"\$OUT\" && grep -q 'NOT a pass' <<<\"\$OUT\""

# DIVE-2700: THE FOLD'S DELETIONS ARE PART OF THE RELEASE COMMIT, AND THEY ARE THE
# ONLY WRITE IN IT THAT REMOVES A PATH. release-cut.yml:450 runs
# fold-changelog-fragments.sh, which REMOVES every changelog.d/*.md it folds into
# CHANGELOG.md, and :493 stages that removal with `git add -A -f changelog.d`. The
# deletions land in the delta, so delta mode must tolerate them or no cut can complete
# while a single fragment exists — which is exactly how v0.19.0 died (run 30885717462,
# 7 fragment deletions reported "OUTSIDE the release-commit set").
#
# mk_repo cannot express this: it only ADDS paths on top of the parent, and the shape
# under test is a path present in the PARENT and absent from the RELEASE commit. Built
# by hand for that reason.
rm -rf "$T/repo"; mkdir -p "$T/repo/src" "$T/repo/tests" "$T/repo/changelog.d"
_git init -q 2>/dev/null || git -C "$T/repo" init -q
printf 'readonly FIVE_VERSION="0.0.0-dev"\n' > "$T/repo/src/header.sh"
printf 'x\n' > "$T/repo/CHANGELOG.md"
printf '### fragment\n' > "$T/repo/changelog.d/DIVE-1.md"
printf '### fragment\n' > "$T/repo/changelog.d/DIVE-2.md"
_git add -A >/dev/null; _git commit -qm parent
PARENT=$(_git rev-parse HEAD)
# The release commit, exactly as the cut builds it: version assigned, CHANGELOG
# stamped, fragments folded away.
printf 'readonly FIVE_VERSION="0.17.11"\n' > "$T/repo/src/header.sh"
printf 'x\nfolded\n' > "$T/repo/CHANGELOG.md"
rm -f "$T/repo/changelog.d/DIVE-1.md" "$T/repo/changelog.d/DIVE-2.md"
_git add -A >/dev/null; _git commit -qm release
repo_bundle 0.17.11; repo_tests 0
runr 0.17.11 "$PARENT"
ok "FOLD-DELTA: DELETED changelog.d fragments are inside the release-commit set and grade 0" \
  "[[ $RC -eq 0 ]]"
ok "FOLD-DELTA: no fragment is reported as an offending path" \
  "! grep -q 'OUTSIDE the release-commit set' <<<\"\$OUT\""
ok "FOLD-DELTA: still INHERITS rather than silently falling back to the full corpus" \
  "grep -q 'inheriting the parent' <<<\"\$OUT\""

# ---- 7. THE EXPENSIVE PATH IS THE DEFAULT ----
# Without a parent there is no premise, so there is nothing to inherit. The arm that
# matters is the COUNT: delta mode would have run 1, the full corpus runs 3.
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 0 0 0
runr 0.17.11
ok "NO-PARENT: falls back to the FULL corpus rather than inheriting an unproven premise" \
  "[[ $RC -eq 0 ]] && grep -q 'corpus ran 3 harness' <<<\"\$OUT\""
ok "NO-PARENT: does NOT claim to have inherited anything" \
  "! grep -q 'inheriting the parent' <<<\"\$OUT\""

OUT=$(cd "$T/repo" && GRC_BUNDLE=./5dive GRC_TESTS_GLOB='tests/*.sh' GRC_DELTA_TESTS='tests/t1.sh' \
      GRC_FULL_CORPUS=1 bash "$GRADE" 0.17.11 "$PARENT" 2>&1); RC=$?
ok "FULL-OVERRIDE: GRC_FULL_CORPUS=1 runs all 3 even with a valid parent" \
  "[[ $RC -eq 0 ]] && grep -q 'corpus ran 3 harness' <<<\"\$OUT\""

# ---- 8. THE EXCLUSION IS NAMED, PRINTED AND COUNTED ----
# tests/release_cut_bundle_unit.sh asserts MAIN's invariants and a release commit
# inverts all of them, so it is unanswerable here. What must never happen is a corpus
# that quietly shrinks: a skip nobody can see is indistinguishable from coverage.
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 0 0
cp "$T/repo/tests/t2.sh" "$T/repo/tests/release_cut_bundle_unit.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/repo/tests/release_cut_bundle_unit.sh"
runr 0.17.11
ok "EXCLUDE: the main-tree-only harness does not fail the grade" "[[ $RC -eq 0 ]]"
ok "EXCLUDE: the skip is PRINTED, so a reader sees what did not run" \
  "grep -q 'SKIP — tests/release_cut_bundle_unit.sh' <<<\"\$OUT\""
ok "EXCLUDE: the skip names WHY it cannot be answered on a release commit" \
  "grep -q 'MAIN-tree invariants' <<<\"\$OUT\""
ok "EXCLUDE: the skip is COUNTED in the summary, not silently dropped" \
  "grep -qE 'ran 2 harness\(es\), 0 failed, 1 skipped' <<<\"\$OUT\""

# And exclusion must never be able to empty the corpus into a pass.
mk_repo src/header.sh 5dive; repo_bundle 0.17.11
rm -rf "$T/repo/tests"; mkdir -p "$T/repo/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/repo/tests/release_cut_bundle_unit.sh"
runr 0.17.11
ok "EXCLUDE-ALL: excluding every harness is UNDETERMINED, never a clean pass" \
  "[[ $RC -eq 2 ]] && grep -q 'NOT a pass' <<<\"\$OUT\""

# A red harness inside the DELTA set still fails the cut — delta mode narrows what is
# asked, it does not soften the answer.
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 1
runr 0.17.11 "$PARENT"
ok "DELTA-RED: a failing delta harness still exits 1 and still prints its evidence" \
  "[[ $RC -eq 1 ]] && grep -q 'ASSERTION-DETAIL-1' <<<\"\$OUT\""

# ---- 9. MUTATION: DO THE ARMS ABOVE ACTUALLY BITE? ----
# Every refusal in section 6 is a negative. A negative that cannot be made to fire is
# indistinguishable from one that is dead, so each guard is deleted in turn and the
# arm it protects must flip. `sed` on a copy — the script under test is never touched.
mutant() { # $1=label $2=sed-expr $3=setup-fn-args... via $MUT_SETUP ; asserts flip
  sed -E "$2" "$GRADE" > "$T/mutant.sh"; chmod +x "$T/mutant.sh"
}
# MUTANT A: drop the subset check. WIDER-DELTA must stop refusing.
mutant A 's/^  if \(\( \$\{#_unexpected\[@\]\} > 0 \)\); then/  if false; then/'
mk_repo src/header.sh other.sh; repo_bundle 0.17.11; repo_tests 0
GRADE_UNDER_TEST="$T/mutant.sh" runr 0.17.11 "$PARENT"
ok "MUTANT-A (subset check removed): WIDER-DELTA stops refusing — the arm is live" \
  "[[ $RC -ne 2 ]]"

# MUTANT B: drop the required-path check. EMPTY-DELTA must stop refusing.
mutant B 's/^  if \(\( \$\{#_missing\[@\]\} > 0 \)\); then/  if false; then/'
mk_repo; repo_bundle 0.17.11; repo_tests 0
GRADE_UNDER_TEST="$T/mutant.sh" runr 0.17.11 "$PARENT"
ok "MUTANT-B (anti-vacuity check removed): an EMPTY delta inherits a pass — the arm is live" \
  "[[ $RC -ne 2 ]]"

# MUTANT C: send harness output back to /dev/null, i.e. restore the six-nights-of-
# silence defect. The EVIDENCE arms must go red.
mutant C 's|if ! _out=\$\(bash "\$_t" 2>&1\); then|if ! _out=$(bash "$_t" >/dev/null 2>\&1); then|'
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 0 1 0
GRADE_UNDER_TEST="$T/mutant.sh" runr 0.17.11
ok "MUTANT-C (output discarded again): the EVIDENCE arm goes red — it was not passing on the name alone" \
  "! grep -q 'ASSERTION-DETAIL-2' <<<\"\$OUT\""

# MUTANT D: make the exclusion silent. The reader-facing half of the skip must break.
mutant D 's/^    echo "grade-release-commit: SKIP/    : "grade-release-commit: SKIP/'
mk_repo src/header.sh 5dive; repo_bundle 0.17.11; repo_tests 0 0
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/repo/tests/release_cut_bundle_unit.sh"
GRADE_UNDER_TEST="$T/mutant.sh" runr 0.17.11
ok "MUTANT-D (skip made silent): the corpus shrinks with nothing in the log — the arm is live" \
  "! grep -q 'SKIP — tests/release_cut_bundle_unit.sh' <<<\"\$OUT\""

# ---- 10. THE SHIPPED DELTA LIST IS REAL ----
# Every arm above overrides GRC_DELTA_TESTS with a stub, which is right for grading the
# mechanism and grades NOTHING about the list release-cut.yml actually runs. That list
# is a set of hardcoded paths, so a renamed or deleted harness silently shrinks the
# release grade to whatever still resolves — coverage lost with no error anywhere,
# which is the same fails-quiet shape as ITEM 1. Read the default out of the script and
# hold it to the tree.
_defaults=$(GRC_DELTA_TESTS= bash -c '. /dev/stdin <<< "$(sed -n "/^GRC_DELTA_TESTS=/,/^tests.*}\"$/p" "$1")"; echo "$GRC_DELTA_TESTS"' _ "$GRADE" 2>/dev/null)
_repo="$(cd "$(dirname "$GRADE")/.." && pwd)"
_dmiss=(); _dn=0
for _d in $_defaults; do _dn=$((_dn+1)); [[ -f "$_repo/$_d" ]] || _dmiss+=("$_d"); done
ok "SHIPPED-LIST: the default delta corpus is NOT empty (an empty one makes every cut UNDETERMINED)" \
  "[[ $_dn -gt 0 ]]"
ok "SHIPPED-LIST: every harness the release grade names still EXISTS (${_dn} named, ${#_dmiss[@]} missing: ${_dmiss[*]:-none})" \
  "[[ ${#_dmiss[@]} -eq 0 ]]"
ok "SHIPPED-LIST: the excluded main-tree harness is NAMED in it, so its SKIP shows up in the release log" \
  "grep -q 'tests/release_cut_bundle_unit.sh' <<<\"\$_defaults\""

# ---- 11. THE ALLOWED-PATH SET STILL MATCHES WHAT THE CUT ACTUALLY WRITES ----
# GRC_DELTA_PATHS is a hardcoded copy of a fact that lives in release-cut.yml: the set
# of paths the DIVE-2091 release-commit block stages. The copy is the risk. Add a
# fifth path there — another generated artifact, another stamp — and delta mode goes
# UNDETERMINED and the cut REFUSES. That is the safe direction and it is still a
# 02:37Z outage discovered by nobody being paged. Derive the truth from the workflow
# and fail HERE, at PR time, instead.
_wf="$_repo/.github/workflows/release-cut.yml"
_pathset=$(GRC_DELTA_PATHS= bash -c '. /dev/stdin <<< "$(sed -n "/^GRC_DELTA_PATHS=/p" "$1")"; echo "$GRC_DELTA_PATHS"' _ "$GRADE" 2>/dev/null)
# Every pathspec the cut stages, read out of the `git add` lines themselves.
#
# DIVE-2700 — THIS CENSUS IS WHY THE DRIFT WENT UNNOTICED, and the PARSER is the
# defect, not the list. It used to require a literal `git add -f ` optionally behind
# `if [ -f ...]; then`. DIVE-2582 added a fifth writer phrased two ordinary ways the
# pattern did not admit: `git add -A -f changelog.d` (a flag inserted BETWEEN `add`
# and `-f`) behind `if [ -d changelog.d ]` (a DIRECTORY test, not a file test). So the
# census counted 4 of 5 writers and printed "0 unlisted", and this arm was GREEN on
# the exact commit whose cut refused. A census that silently under-counts prints the
# same "none" as one that checked everything.
#
# Now: match ANY `git add`, then strip the flags whatever their order. Over-matching
# here is safe — an extra pathspec can only add a drift complaint at PR time, never
# suppress one.
_staged=$(grep -oE 'git add [^;|&]+' "$_wf" 2>/dev/null \
          | sed -E 's/^git add //' \
          | tr ' ' '\n' | sed -E '/^-/d; /^$/d' | sort -u)
_drift=(); _sn=0
for _s in $_staged; do
  _sn=$((_sn+1))
  _hit=0
  # Entries are GLOBS (DIVE-2700), so compare by pattern. `changelog.d` staged as a
  # DIRECTORY must be recognised by the `changelog.d/*` entry, which a literal
  # `grep -w` over the pathset would miss.
  for _a in $_pathset; do
    [[ "$_s" == $_a || "$_a" == "$_s"/* ]] && { _hit=1; break; }
  done
  (( _hit )) || _drift+=("$_s")
done
ok "PATHSET: the workflow's release-commit block was found and stages something" \
  "[[ -f \"\$_wf\" && $_sn -gt 0 ]]"
ok "PATHSET: every path release-cut.yml stages is ALLOWED by GRC_DELTA_PATHS (${_sn} staged, ${#_drift[@]} unlisted: ${_drift[*]:-none})" \
  "[[ ${#_drift[@]} -eq 0 ]]"
ok "PATHSET: the required-path guard names a path the cut actually writes" \
  "grep -qw -- 'src/header.sh' <<<\"\$_staged\""

echo; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
