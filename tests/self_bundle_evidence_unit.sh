#!/usr/bin/env bash
# DIVE-2080: every self-re-invocation that produces EVIDENCE must run the bundle it is
# part of, never whatever `5dive` happens to be on PATH.
#
# WHY A BEHAVIOURAL TEST AND NOT A GREP. DIVE-2061 fixed selfcheck's probe 7 to resolve
# the bundle under test — and `proof scorecard`, which that probe shells into, then
# re-resolved itself onto the INSTALLED CLI. A source-level grep for the old line would
# have passed on the fixed probe while the defect sat one call deeper. So this test puts
# a DECOY `5dive` first on PATH and asserts the bundle under test never talks to it.
#
# The decoy is a PLAUSIBLE bundle (executable, carries `readonly FIVE_VERSION=`), so a
# pass here means the ORDERING is right, not merely that the sniff rejected the decoy.
#
# AND THE ABSENCE-ASSERTION IS MUTATION-GRADED. "the decoy was never called" also holds
# when scorecard dies before it would have called anything, so the test would pass on a
# build that never reaches the code under test — the exact failure mode
# community/wiki/grade-absence-assertions-by-mutation.md describes. Case 2 therefore
# reverts five_self_bundle to the pre-fix `command -v` resolution in a copy of the
# bundle and REQUIRES the decoy to be hit. If case 2 ever goes quiet, case 1 has stopped
# proving anything.
#
# DIVE-6938: `proof scorecard` (cases 1 and 2, the decoy and its mutation) moved to
# the devteam plugin with cmd_proof.sh, and 5dive-plugins runs the whole harness
# against this tree with it in place (tests/devteam/self_bundle_evidence_unit.sh).
# What stays here is the core's half: digest and selfcheck.
#
#   bash tests/self_bundle_evidence_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
ROOT="$PWD"

TMP="$(mktemp -d /tmp/self-bundle.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

for b in python3 sqlite3 jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP - $b not installed"; exit 0; }
done

# --- case 3: one implementation, and no evidence site re-resolves by name ----
# Narrow on purpose. cmd_proof.sh must hold NO `command -v 5dive`; cmd_digest.sh may
# hold exactly one — the root cron driver, which is a documented non-evidence re-exec.
# Comments ABOUT the defect are fine and wanted; count only live code.
code_hits() { grep -n 'command -v 5dive' "$1" | grep -vE '^[0-9]+: *#' | wc -l | tr -d ' '; }

n=$(code_hits src/cmd_digest.sh)
if [[ "$n" = 1 ]] && grep -q 'DIVE-2080 decided this site DELIBERATELY keeps' src/cmd_digest.sh; then
  ok_t "src/cmd_digest.sh keeps exactly one \`command -v\`, and it is the documented cron re-exec"
else
  bad_t "src/cmd_digest.sh keeps exactly one \`command -v\`, and it is the documented cron re-exec" \
        "found $n occurrence(s); every non-evidence keep must carry the per-site rationale"
fi

# --- case 4: callable when a harness sources ONE cmd_*.sh from the split tree -
for f in src/cmd_digest.sh src/cmd_selfcheck.sh; do
  if bash -c "source '$ROOT/$f' >/dev/null 2>&1; declare -F five_self_bundle >/dev/null" 2>/dev/null; then
    ok_t "five_self_bundle is callable when only $f is sourced"
  else
    bad_t "five_self_bundle is callable when only $f is sourced" "the source-tree guard did not load lib/self.sh"
  fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
