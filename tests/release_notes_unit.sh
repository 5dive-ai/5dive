#!/usr/bin/env bash
# DIVE-2452 isolated unit harness for the release-body derivation and the CHANGELOG
# stamp — the two halves of "a release that says WHAT shipped, not how it was cut".
#
# Both scripts are driven against a REAL throwaway git repo rather than mocked git
# output, because the whole correctness argument is about what a range contains.
# Covers:
#   - notes come from CHANGELOG.md's ADDED lines over the range, not from the
#     heading text (on main every section says "Unreleased" forever, so a
#     heading-based reader would put the entire file in every release)
#   - a section added BEFORE the incumbent's cut point is NOT in the new notes
#   - `## Unreleased — X` is demoted to `### X` for the release page
#   - fallback to grouped commit subjects when CHANGELOG.md gained nothing
#   - EXIT 1 when neither source yields anything — the arm that matters, since the
#     bug being fixed is a release that published successfully with no notes
#   - the stamp rewrites both heading forms, preserves the separator and the title,
#     leaves prose mentions alone, and refuses when its anchor drifted
# Run: bash tests/release_notes_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
SCRIPTS="$(pwd)/scripts"

TMP="$(mktemp -d /tmp/release-notes-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.name  'Ada Lovelace'
git -C "$R" config user.email 'ada@example.test'

commit() { # <file> <content> <subject>
  printf '%s\n' "$2" > "$R/$1"
  git -C "$R" add "$1"
  git -C "$R" commit -q -m "$3"
}

# --- history: one released section, then two unreleased ones -------------------
cat > "$R/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased — fix(old): something that shipped in the last tag

Body of the already-released section.
EOF
git -C "$R" add CHANGELOG.md
git -C "$R" commit -q -m "fix(old): something that shipped in the last tag"
CUT_FROM=$(git -C "$R" rev-parse HEAD)

cat > "$R/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased — feat(gh): route agent writes through the machine account

Writes go out as the bot; admin and reads stay on the caller.

## Unreleased — fix(old): something that shipped in the last tag

Body of the already-released section.
EOF
git -C "$R" add CHANGELOG.md
git -C "$R" commit -q -m "feat(gh): route agent writes through the machine account"
commit other.txt "x" "fix(cut): stop publishing an empty release body"
TO=$(git -C "$R" rev-parse HEAD)

run_notes() { ( cd "$R" && bash "$SCRIPTS/release-notes.sh" "$@" ) 2>"$TMP/err"; }

out=$(run_notes "$CUT_FROM" "$TO" "1.2.3"); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "notes: derives a body over the range (rc=0)" \
  || bad_t "notes: derives a body over the range" "rc=$rc err=$(cat "$TMP/err")"
[[ "$out" == *"route agent writes through the machine account"* ]] \
  && ok_t "notes: includes the section ADDED in this range" \
  || bad_t "notes: includes the section added in this range" "$out"

# THE HEADING-BASED READER'S BUG, asserted directly. The old section is still
# headed `## Unreleased` at the tip — a reader that collected headings would ship it
# again in every future release. The range says it is not new.
[[ "$out" != *"something that shipped in the last tag"* ]] \
  && ok_t "notes: EXCLUDES an older section that still reads 'Unreleased' at the tip" \
  || bad_t "notes: excludes an older 'Unreleased' section" "leaked a previously-released section: $out"

[[ "$out" == *"### feat(gh): route agent writes"* ]] \
  && ok_t "notes: '## Unreleased — X' is demoted to '### X' for the release page" \
  || bad_t "notes: heading demoted for the release page" "$out"
[[ "$out" != *"## Unreleased"* ]] \
  && ok_t "notes: the word 'Unreleased' never reaches the release body" \
  || bad_t "notes: 'Unreleased' reached the release body" "$out"
[[ "$out" == *"Notes derived from"* && "$out" == *"CHANGELOG.md over"* ]] \
  && ok_t "notes: names its own source (CHANGELOG arm)" \
  || bad_t "notes: names its own source" "$out"

# --- fallback: range with commits but no CHANGELOG change ----------------------
FB_FROM=$(git -C "$R" rev-parse HEAD)
commit a.txt "1" "feat(x): a feature with no changelog entry"
commit b.txt "2" "fix(y): a fix with no changelog entry"
commit c.txt "3" "chore: something uncategorised"
FB_TO=$(git -C "$R" rev-parse HEAD)

out=$(run_notes "$FB_FROM" "$FB_TO" "1.2.4"); rc=$?
[[ $rc -eq 0 ]] \
  && ok_t "fallback: succeeds when CHANGELOG.md gained nothing" \
  || bad_t "fallback: succeeds when CHANGELOG gained nothing" "rc=$rc err=$(cat "$TMP/err")"
[[ "$out" == *"### Features"* && "$out" == *"feat(x): a feature"* ]] \
  && ok_t "fallback: groups feat under Features" \
  || bad_t "fallback: groups feat under Features" "$out"
[[ "$out" == *"### Fixes"* && "$out" == *"fix(y): a fix"* ]] \
  && ok_t "fallback: groups fix under Fixes" \
  || bad_t "fallback: groups fix under Fixes" "$out"
# An unrecognised type must be KEPT, not dropped — a silently shortened list is the
# same class of failure as an empty body.
[[ "$out" == *"### Other"* && "$out" == *"chore: something uncategorised"* ]] \
  && ok_t "fallback: an unrecognised commit type lands under Other, never dropped" \
  || bad_t "fallback: unrecognised type kept" "$out"
[[ "$out" == *"CHANGELOG.md gained nothing in this range"* ]] \
  && ok_t "fallback: says WHY it fell back" \
  || bad_t "fallback: names its source" "$out"

# --- the arm that matters: nothing derivable must REFUSE -----------------------
EMPTY=$(git -C "$R" rev-parse HEAD)
out=$(run_notes "$EMPTY" "$EMPTY" "1.2.5"); rc=$?
[[ $rc -eq 1 ]] \
  && ok_t "empty range REFUSES (rc=1) rather than publishing a bodyless release" \
  || bad_t "empty range refuses" "rc=$rc out=$out"
grep -q "could not be derived" "$TMP/err" \
  && ok_t "empty range: the refusal says what was missing" \
  || bad_t "empty range: refusal message" "$(cat "$TMP/err")"
grep -q "DIVE-2452" "$TMP/err" \
  && ok_t "empty range: the refusal cites the row, so the next reader finds the why" \
  || bad_t "empty range: refusal cites the row" "$(cat "$TMP/err")"

# --- the stamp ------------------------------------------------------------------
S="$TMP/stamp"; mkdir -p "$S"
cat > "$S/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased — feat(a): first thing

Prose that mentions Unreleased in the middle of a sentence.

## Unreleased

A bare heading with no title.

## v0.16.0 — an already-stamped section

Left alone.
EOF
n=$( ( cd "$S" && bash "$SCRIPTS/stamp-changelog.sh" 1.2.3 ) 2>"$TMP/serr" ); rc=$?
[[ $rc -eq 0 && "$n" == "2" ]] \
  && ok_t "stamp: rewrites both heading forms and reports the count (2)" \
  || bad_t "stamp: rewrites both heading forms" "rc=$rc n=$n err=$(cat "$TMP/serr")"
grep -q '^## v1.2.3 — feat(a): first thing$' "$S/CHANGELOG.md" \
  && ok_t "stamp: preserves the separator and the section title" \
  || bad_t "stamp: preserves separator and title" "$(grep -n '^## ' "$S/CHANGELOG.md")"
grep -q '^## v1.2.3$' "$S/CHANGELOG.md" \
  && ok_t "stamp: a bare heading becomes a bare versioned heading" \
  || bad_t "stamp: bare heading" "$(grep -n '^## ' "$S/CHANGELOG.md")"
grep -q 'mentions Unreleased in the middle' "$S/CHANGELOG.md" \
  && ok_t "stamp: a prose mention of Unreleased is untouched (anchored at line start)" \
  || bad_t "stamp: prose mention untouched" "$(cat "$S/CHANGELOG.md")"
grep -q '^## v0.16.0 — an already-stamped section$' "$S/CHANGELOG.md" \
  && ok_t "stamp: an already-stamped section is left alone" \
  || bad_t "stamp: already-stamped section" "$(grep -n '^## ' "$S/CHANGELOG.md")"
[[ "$(grep -c '^## Unreleased' "$S/CHANGELOG.md" || true)" == "0" ]] \
  && ok_t "stamp: no 'Unreleased' heading survives in the release tree" \
  || bad_t "stamp: headings survived" "$(grep -n '^## ' "$S/CHANGELOG.md")"

# Idempotence: a second run has nothing to do and must not fail — a re-run of the
# cut step is a normal event, not an error.
n2=$( ( cd "$S" && bash "$SCRIPTS/stamp-changelog.sh" 1.2.3 ) 2>/dev/null ); rc=$?
[[ $rc -eq 0 && "$n2" == "0" ]] \
  && ok_t "stamp: idempotent — a second run stamps 0 and succeeds" \
  || bad_t "stamp: idempotent" "rc=$rc n=$n2"

# Input validation: a bad version must never reach the file.
( cd "$S" && bash "$SCRIPTS/stamp-changelog.sh" "not-a-version" ) >/dev/null 2>&1
[[ $? -eq 2 ]] \
  && ok_t "stamp: refuses a version that is not MAJOR.MINOR.PATCH" \
  || bad_t "stamp: refuses a bad version" "accepted a malformed version"
( cd "$S" && bash "$SCRIPTS/stamp-changelog.sh" 1.2.3 no-such-file.md ) >/dev/null 2>&1
[[ $? -eq 2 ]] \
  && ok_t "stamp: refuses a missing changelog rather than creating one" \
  || bad_t "stamp: refuses a missing changelog" "accepted a missing file"

# --- wiring: the workflow must actually CALL both, and fail the cut on refusal --
WF=.github/workflows/release-cut.yml
grep -q 'scripts/release-notes.sh' "$WF" \
  && ok_t "wiring: release-cut.yml calls release-notes.sh" \
  || bad_t "wiring: release-cut.yml calls release-notes.sh" "not referenced"
grep -q 'scripts/stamp-changelog.sh' "$WF" \
  && ok_t "wiring: release-cut.yml calls stamp-changelog.sh" \
  || bad_t "wiring: release-cut.yml calls stamp-changelog.sh" "not referenced"
grep -q -- '--notes-file' "$WF" \
  && ok_t "wiring: the release body comes from the derived file, not the cut reason" \
  || bad_t "wiring: --notes-file" "gh release create still uses inline --notes"
# The refusal has to abort the CUT. A derivation that fails and is then ignored is
# the original bug with extra steps.
grep -q 'release notes could not be derived' "$WF" \
  && ok_t "wiring: a failed derivation aborts the cut with a named error" \
  || bad_t "wiring: failed derivation aborts the cut" "no abort arm found"

echo "-----"
printf 'release_notes_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
