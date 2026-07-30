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

echo; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
