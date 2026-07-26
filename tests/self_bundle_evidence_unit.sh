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
#   bash tests/self_bundle_evidence_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

TMP="$(mktemp -d /tmp/self-bundle.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

for b in python3 sqlite3 jq; do
  command -v "$b" >/dev/null 2>&1 || { echo "SKIP - $b not installed"; exit 0; }
done

# --- the artifact under test -------------------------------------------------
BUILD_OUT="$TMP/under-test/5dive"
mkdir -p "$TMP/under-test"
( cd "$ROOT" && BUILD_OUT="$BUILD_OUT" ./build.sh >/dev/null 2>&1 ) \
  || { echo "FAIL - could not build a throwaway bundle"; exit 1; }
chmod +x "$BUILD_OUT"

# --- the decoy: a different, healthy-looking 5dive earlier on PATH -----------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/5dive" <<'DECOY'
#!/usr/bin/env bash
readonly FIVE_VERSION=99.99.99-DECOY
printf '%s\n' "$*" >> "$DECOY_LOG"
exit 0
DECOY
chmod +x "$TMP/bin/5dive"

export DECOY_LOG="$TMP/decoy.log"

# run <bundle> -> prints nothing; appends any decoy invocation to $DECOY_LOG
run_scorecard() {
  local bundle="$1" d="$2"
  : > "$DECOY_LOG"
  mkdir -p "$d/tasks"
  PATH="$TMP/bin:$PATH" STATE_DIR="$d" TASKS_DB="$d/tasks/tasks.db" \
    FIVEDIVE_NO_HUMAN_SEND=1 "$bundle" proof scorecard --7d >/dev/null 2>&1
  return 0
}

# --- case 1: the fix — scorecard must compute its digest from ITSELF ---------
run_scorecard "$BUILD_OUT" "$TMP/s1"
if grep -q 'digest' "$DECOY_LOG" 2>/dev/null; then
  bad_t "proof scorecard drives the bundle under test, not PATH" \
        "the decoy on PATH was called: $(tr '\n' '|' < "$DECOY_LOG")"
else
  ok_t "proof scorecard drives the bundle under test, not PATH"
fi

# --- case 2: mutation — revert the helper, the decoy MUST get hit ------------
# If this goes quiet the test has stopped reaching the code it claims to cover.
MUT="$TMP/mutated/5dive"; mkdir -p "$TMP/mutated"
python3 - "$BUILD_OUT" "$MUT" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
m = re.search(r'^five_self_bundle\(\) \{.*?^\}\n', s, re.S | re.M)
assert m, "could not locate five_self_bundle in the bundle"
legacy = 'five_self_bundle() { command -v 5dive 2>/dev/null || echo "$0"; }\n'
open(dst, 'w').write(s[:m.start()] + legacy + s[m.end():])
PY
chmod +x "$MUT"
run_scorecard "$MUT" "$TMP/s2"
if grep -q 'digest' "$DECOY_LOG" 2>/dev/null; then
  ok_t "mutation grade: pre-fix resolution DOES reach the decoy (case 1 is live)"
else
  bad_t "mutation grade: pre-fix resolution DOES reach the decoy (case 1 is live)" \
        "the legacy \`command -v\` build never called the decoy either — case 1 proves nothing"
fi

# --- case 3: one implementation, and no evidence site re-resolves by name ----
# Narrow on purpose. cmd_proof.sh must hold NO `command -v 5dive`; cmd_digest.sh may
# hold exactly one — the root cron driver, which is a documented non-evidence re-exec.
# Comments ABOUT the defect are fine and wanted; count only live code.
code_hits() { grep -n 'command -v 5dive' "$1" | grep -vE '^[0-9]+: *#' | wc -l | tr -d ' '; }
n=$(code_hits src/cmd_proof.sh)
[[ "$n" = 0 ]] && ok_t "src/cmd_proof.sh resolves itself only via five_self_bundle" \
                || bad_t "src/cmd_proof.sh resolves itself only via five_self_bundle" "$n occurrence(s) of \`command -v 5dive\` remain"

n=$(code_hits src/cmd_digest.sh)
if [[ "$n" = 1 ]] && grep -q 'DIVE-2080 decided this site DELIBERATELY keeps' src/cmd_digest.sh; then
  ok_t "src/cmd_digest.sh keeps exactly one \`command -v\`, and it is the documented cron re-exec"
else
  bad_t "src/cmd_digest.sh keeps exactly one \`command -v\`, and it is the documented cron re-exec" \
        "found $n occurrence(s); every non-evidence keep must carry the per-site rationale"
fi

# --- case 4: callable when a harness sources ONE cmd_*.sh from the split tree -
for f in src/cmd_proof.sh src/cmd_digest.sh src/cmd_selfcheck.sh; do
  if bash -c "source '$ROOT/$f' >/dev/null 2>&1; declare -F five_self_bundle >/dev/null" 2>/dev/null; then
    ok_t "five_self_bundle is callable when only $f is sourced"
  else
    bad_t "five_self_bundle is callable when only $f is sourced" "the source-tree guard did not load lib/self.sh"
  fi
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
