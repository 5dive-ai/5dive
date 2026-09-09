#!/usr/bin/env bash
# DIVE-2097 — src/lib/self.sh must precede every five_self_bundle consumer in
# build.sh's cat list, and that must be a CHECK, not the prose comment it was.
#
# Background (main's DIVE-2080 verification): the shipped bundle is safe because
# lib/self.sh sits third in the cat list, well ahead of cmd_digest.sh / cmd_proof.sh /
# cmd_selfcheck.sh, whose `declare -F five_self_bundle || source .../lib/self.sh`
# guard is dead code there and load-bearing only in the split tree (a unit harness
# sourcing one src/cmd_*.sh with no lib/ ahead of it). Nothing but a hand-maintained
# comment protected that ordering — if a future consumer landed ahead of lib/self.sh,
# the guard would fire INSIDE the bundle, where dirname "$BASH_SOURCE" is the install
# dir and lib/self.sh does not exist, and `set -euo pipefail` would take the whole CLI
# down. build.sh now asserts the invariant on the built artifact directly (definition
# line < first consumer-guard line) so this can't regress silently again.
#
# Two cases, per community/wiki/grade-absence-assertions-by-mutation.md: a check that
# never fires on the shipped tree proves nothing about whether it CAN fire. Case 2
# mutates a COPY of build.sh placed inside the repo root (build.sh itself `cd`s to
# its own dirname, so it must run from a path that still sees src/) and requires the
# reorder to be caught.
#
#   bash tests/build_bundle_self_order_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; rm -rf "${TMP:-}" "${MUT_BUILD:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
ROOT="$PWD"

TMP="$(mktemp -d /tmp/bundle-order.XXXXXX)"
MUT_BUILD="$ROOT/.dive2097-mutant-build.sh"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP - python3 not installed"; exit 0; }

# --- case 1: the real cat list builds clean (positive control, no false alarm) ------
mkdir -p "$TMP/good"
if ( cd "$ROOT" && BUILD_OUT="$TMP/good/5dive" ./build.sh >"$TMP/good.log" 2>&1 ); then
  ok_t "build.sh passes the ordering check on the real (correctly-ordered) cat list"
else
  bad_t "build.sh passes the ordering check on the real (correctly-ordered) cat list" \
        "build failed: $(cat "$TMP/good.log")"
fi

# --- case 2: mutation — reorder the cat list so a consumer precedes lib/self.sh ----
# Moves src/lib/self.sh to just AFTER src/cmd_digest.sh (a real consumer). If this
# stays green the check is vacuous; it MUST fail, and fail on the ordering message,
# not on some unrelated breakage.
# DIVE-4087 made this a TWO-move mutation, and the reason is the point of the
# arm. The manifest is now two lists: CORE_FILES (parsed on every call) and
# LAZY_FILES (trailing text, pulled in by line range). A consumer that sits in
# LAZY_FILES can never see an unparsed definition, because the core carries an
# autoload stub for it — so the old one-move mutation (slide self.sh past
# cmd_digest.sh, which is now lazy) no longer constructs the defect and the arm
# would have gone VACUOUS while still reading green.
#
# The defect class is unchanged: a `declare -F five_self_bundle || source
# .../lib/self.sh` guard PARSED BEFORE the definition, inside the always-parsed
# region, where nothing but list order orders them. So: pull cmd_digest.sh into
# CORE_FILES and put self.sh after it.
python3 - "$ROOT/build.sh" "$MUT_BUILD" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(keepends=True)
self_idx = next(i for i, l in enumerate(lines) if l.strip() == 'src/lib/self.sh')
lazy_digest = next(i for i, l in enumerate(lines) if l.strip() == 'src/cmd_digest.sh')
assert lazy_digest > self_idx, "fixture assumption broken: cmd_digest.sh is not in LAZY_FILES"
lines.pop(lazy_digest)                      # out of the lazy region
moved_self = lines.pop(self_idx)            # out of its ordered slot in the core
lines.insert(self_idx, '  src/cmd_digest.sh\n')   # consumer first ...
lines.insert(self_idx + 1, moved_self)      # ... definition after it
open(dst, 'w').write(''.join(lines))
PY
chmod +x "$MUT_BUILD"

mkdir -p "$TMP/bad"
if ( cd "$ROOT" && BUILD_OUT="$TMP/bad/5dive" ./.dive2097-mutant-build.sh >"$TMP/bad.log" 2>&1 ); then
  bad_t "mutation grade: self.sh after a consumer MUST fail the build" \
        "build succeeded when it should have refused: $(cat "$TMP/bad.log")"
elif grep -q 'AFTER the first' "$TMP/bad.log"; then
  ok_t "mutation grade: self.sh after a consumer fails with the ordering error"
else
  bad_t "mutation grade: self.sh after a consumer fails with the ordering error" \
        "build failed but not on the ordering check: $(cat "$TMP/bad.log")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
