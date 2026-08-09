#!/usr/bin/env bash
# DIVE-2582 unit harness for scripts/fold-changelog-fragments.sh — the
# conflict-free changelog.d/ path. Covers:
#   - two fragments fold in, newest filename first, above the existing content
#   - README.md in changelog.d/ is never treated as a fragment
#   - a missing changelog.d/ folds 0, exit 0 (not an error — nothing pending)
#   - a fragment that doesn't start with '## Unreleased' is reported and
#     skipped: not folded into CHANGELOG.md, not deleted from changelog.d/
#   - a bare '## Unreleased' (no em-dash headline) is accepted
#
# DIVE-2702 extends it with the arm that was missing — IDEMPOTENCE ACROSS CUTS,
# graded the only way that means anything here: a real scratch git repo cut THREE
# times, the fold run detached exactly as release-cut.yml runs it, asserting each
# tag's CHANGELOG carries only its own entries. Two cuts would not have caught the
# obvious wrong fix (checking only the immediately previous tag's notes), because
# the compounding shows up on the THIRD. Extended in place rather than added as a
# new harness — tests/lib/tier.sh's ledger argument, the corpus is at its cap.
# Run: bash tests/fold_changelog_fragments_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$(pwd)/scripts/fold-changelog-fragments.sh"

TMP="$(mktemp -d /tmp/fold-changelog-unit.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/changelog.d"

cat > "$R/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased — fix(old): existing entry

Body of the existing entry.
EOF

cat > "$R/changelog.d/DIVE-9001.md" <<'EOF'
## Unreleased — feat(x): fragment one (DIVE-9001)

Body of fragment one.
EOF

cat > "$R/changelog.d/DIVE-9002.md" <<'EOF'
## Unreleased — feat(y): fragment two (DIVE-9002)

Body of fragment two.
EOF

cat > "$R/changelog.d/README.md" <<'EOF'
convention doc, not an entry
EOF

out=$(cd "$R" && bash "$SCRIPT" 2>"$TMP/err"); rc=$?
[[ $rc -eq 0 && "$out" == "2" ]] \
  && ok_t "folds two fragments, reports count=2 (rc=0)" \
  || bad_t "folds two fragments, reports count=2" "rc=$rc out=$out err=$(cat "$TMP/err")"

body="$(cat "$R/CHANGELOG.md")"
[[ "$body" == *"fragment two"*"fragment one"*"existing entry"* ]] \
  && ok_t "folded content: newest fragment first, above pre-existing content" \
  || bad_t "folded content order" "$body"

[[ -f "$R/changelog.d/README.md" && ! -f "$R/changelog.d/DIVE-9001.md" && ! -f "$R/changelog.d/DIVE-9002.md" ]] \
  && ok_t "folded fragments deleted, README.md untouched" \
  || bad_t "post-fold changelog.d/ contents" "$(ls "$R/changelog.d" 2>&1)"

# --- no changelog.d/ at all: 0 folded, not an error ------------------------
R2="$TMP/repo2"
mkdir -p "$R2"
printf '# Changelog\n' > "$R2/CHANGELOG.md"
out2=$(cd "$R2" && bash "$SCRIPT" 2>"$TMP/err2"); rc2=$?
[[ $rc2 -eq 0 && "$out2" == "0" ]] \
  && ok_t "missing changelog.d/: folds 0, exit 0" \
  || bad_t "missing changelog.d/" "rc=$rc2 out=$out2 err=$(cat "$TMP/err2")"

# --- malformed fragment: reported, not folded, not deleted -----------------
R3="$TMP/repo3"
mkdir -p "$R3/changelog.d"
printf '# Changelog\n' > "$R3/CHANGELOG.md"
cat > "$R3/changelog.d/DIVE-9003.md" <<'EOF'
not a heading, just prose
EOF
out3=$(cd "$R3" && bash "$SCRIPT" 2>"$TMP/err3"); rc3=$?
[[ $rc3 -eq 0 && "$out3" == "0" ]] \
  && ok_t "malformed fragment: folds 0, exit 0 (non-fatal)" \
  || bad_t "malformed fragment fold count" "rc=$rc3 out=$out3"
[[ -f "$R3/changelog.d/DIVE-9003.md" ]] \
  && ok_t "malformed fragment left in place, not deleted" \
  || bad_t "malformed fragment survives" "$(ls "$R3/changelog.d" 2>&1)"
grep -q "DIVE-9003.md" "$TMP/err3" \
  && ok_t "malformed fragment reported on stderr" \
  || bad_t "malformed fragment stderr report" "$(cat "$TMP/err3")"

# --- bare '## Unreleased' (no em-dash headline) is accepted -----------------
R4="$TMP/repo4"
mkdir -p "$R4/changelog.d"
printf '# Changelog\n' > "$R4/CHANGELOG.md"
cat > "$R4/changelog.d/DIVE-9004.md" <<'EOF'
## Unreleased

Bare heading body.
EOF
out4=$(cd "$R4" && bash "$SCRIPT" 2>"$TMP/err4"); rc4=$?
[[ $rc4 -eq 0 && "$out4" == "1" ]] \
  && ok_t "bare '## Unreleased' heading (no em-dash) is accepted" \
  || bad_t "bare heading fold count" "rc=$rc4 out=$out4 err=$(cat "$TMP/err4")"

# ===========================================================================
# DIVE-2702: the fold is IDEMPOTENT ACROSS CUTS.
#
# The regression this arm exists for: the fold deletes fragments in the DETACHED
# release commit only (DIVE-2247 removed this job's push to main), so main keeps
# every fragment forever and the next cut folded them all again — each release's
# notes repeating all previous releases', compounding, on a nightly auto-cut.
#
# Modelled on the real thing rather than on the script's arguments: a git repo
# with a main branch, `git checkout --detach` before each fold, a commit and a
# `v*` tag after it, and main left carrying its fragments the whole time.
# ===========================================================================
RG="$TMP/repo-cuts"
mkdir -p "$RG/changelog.d"
git -C "$RG" init -q -b main 2>/dev/null
git -C "$RG" config user.email 'harness@example.com'
git -C "$RG" config user.name  'harness'
printf '# Changelog\n' > "$RG/CHANGELOG.md"

# add a fragment on MAIN and commit it there
frag_on_main() { # $1 = ident, $2 = body marker
  printf '## Unreleased — feat(x): %s (%s)\n\nBody %s.\n' "$2" "$1" "$2" > "$RG/changelog.d/${1}.md"
  git -C "$RG" add -A && git -C "$RG" commit -q -m "add ${1}"
}

# one release cut: detach at main, fold, commit, tag, return to main.
# $1 = tag, $2 = "auto" (no env, script self-detects) | an explicit baseline ref
cut_release() {
  local tag="$1" mode="$2" out
  git -C "$RG" checkout -q --detach main
  if [[ "$mode" == "auto" ]]; then
    out=$( cd "$RG" && bash "$SCRIPT" 2>>"$TMP/cuterr" )
  else
    out=$( cd "$RG" && FOLD_RELEASED_BASELINE="$mode" bash "$SCRIPT" 2>>"$TMP/cuterr" )
  fi
  git -C "$RG" add -A
  git -C "$RG" commit -q -m "release ${tag}"
  git -C "$RG" tag "$tag"
  git -C "$RG" checkout -q main
  printf '%s' "$out"
}

frag_on_main DIVE-9101 "entry one"
frag_on_main DIVE-9102 "entry two"

# CUT 1 — nothing has shipped yet, so everything folds. No tags exist, so this
# also covers the auto-detect path's "no previous release" state.
c1=$(cut_release v1.0.0 auto)
c1_notes="$(git -C "$RG" show v1.0.0:CHANGELOG.md)"
[[ "$c1" == "2" ]] \
  && ok_t "cut 1 folds both pending fragments" \
  || bad_t "cut 1 fold count" "out=$c1 err=$(cat "$TMP/cuterr" 2>/dev/null)"
[[ "$c1_notes" == *"entry one"* && "$c1_notes" == *"entry two"* ]] \
  && ok_t "cut 1 notes carry both entries" \
  || bad_t "cut 1 notes" "$c1_notes"
# The premise of the whole defect, asserted rather than assumed: the deletion
# lives in the TAG and main still has the fragments.
[[ -f "$RG/changelog.d/DIVE-9101.md" && -z "$(git -C "$RG" ls-tree --name-only v1.0.0 changelog.d/DIVE-9101.md)" ]] \
  && ok_t "fragment consumed in the tag, still present on main (the immortality this arm is about)" \
  || bad_t "fragment lifetime after cut 1" "main:$(ls "$RG/changelog.d") tag:$(git -C "$RG" ls-tree --name-only v1.0.0 changelog.d/)"

# CUT 2 — one new fragment. Baseline passed EXPLICITLY, exactly as release-cut.yml
# passes "${incumbent}^".
frag_on_main DIVE-9103 "entry three"
c2=$(cut_release v1.1.0 'v1.0.0^')
c2_notes="$(git -C "$RG" show v1.1.0:CHANGELOG.md)"
[[ "$c2" == "1" ]] \
  && ok_t "cut 2 folds ONLY the new fragment (explicit baseline)" \
  || bad_t "cut 2 fold count" "out=$c2 err=$(cat "$TMP/cuterr" 2>/dev/null)"
[[ "$c2_notes" == *"entry three"* && "$c2_notes" != *"entry one"* && "$c2_notes" != *"entry two"* ]] \
  && ok_t "cut 2 notes do NOT repeat cut 1's entries" \
  || bad_t "cut 2 notes repeat an earlier release" "$c2_notes"

# CUT 3 — the COMPOUNDING arm, and the reason two cuts are not enough. A fix that
# only asked "is this entry in the previous TAG's CHANGELOG?" passes cut 2 and
# fails here: v1.1.0's notes do not mention entry one/two either. Auto-detect
# (no env) so the self-detection path is graded too.
frag_on_main DIVE-9104 "entry four"
c3=$(cut_release v1.2.0 auto)
c3_notes="$(git -C "$RG" show v1.2.0:CHANGELOG.md)"
[[ "$c3" == "1" ]] \
  && ok_t "cut 3 folds ONLY the new fragment (auto-detected baseline)" \
  || bad_t "cut 3 fold count" "out=$c3 err=$(cat "$TMP/cuterr" 2>/dev/null)"
[[ "$c3_notes" == *"entry four"* \
   && "$c3_notes" != *"entry one"* && "$c3_notes" != *"entry two"* && "$c3_notes" != *"entry three"* ]] \
  && ok_t "cut 3 notes repeat NEITHER earlier release (the compounding arm)" \
  || bad_t "cut 3 notes repeat an earlier release" "$c3_notes"

# CUT 4 — an EDITED fragment is new content and MUST fold again. This is the
# control whose expected value is non-zero: it fails if the skip is too greedy
# (e.g. keyed on the ident/filename instead of the blob), which every other arm
# above would happily pass.
printf '## Unreleased — feat(x): entry one REWRITTEN (DIVE-9101)\n\nBody rewritten.\n' > "$RG/changelog.d/DIVE-9101.md"
git -C "$RG" add -A && git -C "$RG" commit -q -m "edit DIVE-9101"
c4=$(cut_release v1.3.0 auto)
c4_notes="$(git -C "$RG" show v1.3.0:CHANGELOG.md)"
[[ "$c4" == "1" && "$c4_notes" == *"entry one REWRITTEN"* ]] \
  && ok_t "an EDITED fragment folds again (skip is by blob, not by ident)" \
  || bad_t "edited fragment did not re-fold" "out=$c4 notes=$c4_notes"

# --- baseline states that are not "a previous cut" -------------------------
# Set-but-EMPTY means "nothing has shipped yet": fold everything, silently.
RG2="$TMP/repo-empty-baseline"
mkdir -p "$RG2/changelog.d"
printf '# Changelog\n' > "$RG2/CHANGELOG.md"
printf '## Unreleased — feat(x): first ever (DIVE-9105)\n\nBody.\n' > "$RG2/changelog.d/DIVE-9105.md"
out5=$( cd "$RG2" && FOLD_RELEASED_BASELINE="" bash "$SCRIPT" 2>"$TMP/err5" ); rc5=$?
[[ $rc5 -eq 0 && "$out5" == "1" ]] \
  && ok_t "set-but-empty baseline (first cut ever): folds everything, rc=0" \
  || bad_t "empty baseline fold" "rc=$rc5 out=$out5 err=$(cat "$TMP/err5")"
grep -q 'DIVE-2702' "$TMP/err5" \
  && bad_t "empty baseline warned" "an empty baseline is a normal first cut, not a broken one: $(cat "$TMP/err5")" \
  || ok_t "set-but-empty baseline does not warn (it is not a failure to look)"

# UNRESOLVABLE baseline: still folds (a cut must not die over a changelog) but is
# REPORTED, because folding everything is precisely the defect and must never pass
# silently. Graded on stderr, which release-cut.yml captures into its log line.
RG3="$TMP/repo-bad-baseline"
mkdir -p "$RG3/changelog.d"
printf '# Changelog\n' > "$RG3/CHANGELOG.md"
printf '## Unreleased — feat(x): pending (DIVE-9106)\n\nBody.\n' > "$RG3/changelog.d/DIVE-9106.md"
out6=$( cd "$RG3" && FOLD_RELEASED_BASELINE="v9.9.9^" bash "$SCRIPT" 2>"$TMP/err6" ); rc6=$?
[[ $rc6 -eq 0 && "$out6" == "1" ]] \
  && ok_t "unresolvable baseline: non-fatal, still folds (rc=0)" \
  || bad_t "unresolvable baseline fold" "rc=$rc6 out=$out6 err=$(cat "$TMP/err6")"
grep -q 'does not resolve' "$TMP/err6" && grep -q 'may repeat' "$TMP/err6" \
  && ok_t "unresolvable baseline is REPORTED, naming the repeat consequence" \
  || bad_t "unresolvable baseline not reported" "$(cat "$TMP/err6")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
