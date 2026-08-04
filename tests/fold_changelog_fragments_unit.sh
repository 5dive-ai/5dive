#!/usr/bin/env bash
# DIVE-2582 unit harness for scripts/fold-changelog-fragments.sh — the
# conflict-free changelog.d/ path. Covers:
#   - two fragments fold in, newest filename first, above the existing content
#   - README.md in changelog.d/ is never treated as a fragment
#   - a missing changelog.d/ folds 0, exit 0 (not an error — nothing pending)
#   - a fragment that doesn't start with '## Unreleased' is reported and
#     skipped: not folded into CHANGELOG.md, not deleted from changelog.d/
#   - a bare '## Unreleased' (no em-dash headline) is accepted
# Run: bash tests/fold_changelog_fragments_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.." || exit 1
SCRIPT="$(pwd)/scripts/fold-changelog-fragments.sh"

TMP="$(mktemp -d /tmp/fold-changelog-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
