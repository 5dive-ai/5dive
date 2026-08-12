#!/usr/bin/env bash
# DIVE-2835 — grade the close-time deployed-vs-claimed comparison.
#
# A result that NAMES a version is making a claim about a DEPLOYED artifact.
# DIVE-2762 closed "verified on v0.19.2" onto a host running 0.19.1 and the board
# read fixed for a day. This harness grades the guard that converts the human
# discipline (remember to grep the installed file) into machinery.
#
# It EXTRACTS the three functions from the shipped src/cmd_task.sh rather than
# re-typing them, so it cannot drift into grading a copy — same design as
# tests/roundtrip_openrouter_verdict.sh, and the same obligation that comes with
# it: prove the extraction anchor is unique and that an empty extraction REDS
# rather than reading as all-arms-pass.
#
# Run: bash tests/task_version_vs_installed_unit.sh   (no root, no network, no db).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC="${1:-src/task/gate_evidence.sh}"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- extraction, and its own non-vacuity ------------------------------------
xtract() { awk -v fn="^$1\\\\(\\\\)" '$0 ~ fn {f=1} f{print} f&&/^}/{exit}' "$SRC"; }
for fn in _gate_version_claim _gate_installed_cli _gate_version_vs_installed; do
  n=$(grep -c "^${fn}()" "$SRC")
  [[ "$n" == 1 ]] && ok_t "extraction anchor for $fn occurs exactly once (got $n)" \
                  || bad_t "anchor for $fn is not unique" "grep -c = $n; an extracting harness can silently grade the wrong block"
  b=$(xtract "$fn")
  [[ -n "$b" ]] && eval "$b" || bad_t "could not extract $fn from $SRC"
done

# warn/step are the CLI's real emitters; here they only need to be capturable.
WARNED=""; STEPPED=""
warn(){ WARNED="$WARNED$*"$'\n'; }
step(){ STEPPED="$STEPPED$*"$'\n'; }

# --- ARM 1: the fence. What IS a claim ---------------------------------------
claim(){ _gate_version_claim "$1"; }
for pair in \
  "VERIFIED ON v0.19.2|0.19.2" \
  "verified on 0.19.2 by main2|0.19.2" \
  "smoked v1.2.3 on a fresh box|1.2.3" \
  "all three acceptance items confirmed against v0.19.3|0.19.3" \
  "tested v2.0.10|2.0.10"; do
  txt="${pair%%|*}"; want="${pair##*|}"; got=$(claim "$txt")
  [[ "$got" == "$want" ]] && ok_t "claim recognised: '${txt:0:44}' -> $got" \
                          || bad_t "claim missed: '$txt'" "got '$got' want '$want'"
done

# --- ARM 2: the fence. What is NOT a claim, and the load-bearing one ----------
# A result routinely names versions it is not claiming to have verified against.
# The last case here is the one a naive `[^0-9]*` gap matches: verb and version in
# DIFFERENT clauses. It is the reason the gap class excludes ; and , and it is the
# arm that reds if someone "simplifies" the regex.
for txt in \
  "fixed in v0.19.2, rollout tracked in DIVE-2816" \
  "the host runs 0.19.1 and the board says fixed" \
  "verified the retirement; separately, the box runs 0.19.1" \
  "graded-sha: d46c0e158f4c1dd09d3709568cb6be764e37b331" \
  "verified on main" \
  "verified against v0.19"; do
  got=$(claim "$txt")
  [[ -z "$got" ]] && ok_t "not a claim: '${txt:0:52}'" \
                  || bad_t "false claim from '$txt'" "extracted '$got' — a version NAMED is not a version VERIFIED ON"
done
got=$(claim $'verified on v0.1.0\nlater: verified on v9.9.9')
[[ "$got" == "9.9.9" ]] && ok_t "LAST occurrence wins (--append-result prepends the older text)" \
                        || bad_t "last-wins" "got '$got' want 9.9.9"

# --- ARM 3: the comparison, by direction --------------------------------------
run_cmp(){ WARNED=""; STEPPED=""
  eval "_gate_installed_cli(){ printf '%s' '$1'; ${2:-return 0}; }"
  _gate_version_vs_installed DIVE-TEST done "$3"; }

run_cmp "/usr/local/bin/5dive|0.19.2" "" "VERIFIED ON v0.19.2"
{ [[ "$STEPPED" == *"matches the installed artifact"* && -z "$WARNED" ]]; } \
  && ok_t "equal: reports that the comparison RAN and agreed, and does not warn" \
  || bad_t "equal case" "step='$STEPPED' warn='$WARNED'"

run_cmp "/usr/local/bin/5dive|0.19.1" "" "VERIFIED ON v0.19.2"
# The path assertion is deliberately POSITIONAL — "/usr/local/bin/5dive reports
# 0.19.1", not just "the path appears somewhere". Measured: a mutation that
# removed the path from the mismatch sentence still passed a loose contains-check,
# because the closing "grep $ipath" sentence supplies the same substring. An arm
# that can be satisfied by a different occurrence is not grading what it names.
{ [[ "$WARNED" == *"DEPLOYED-VS-CLAIMED MISMATCH"* && "$WARNED" == *OLDER* \
    && "$WARNED" == *"/usr/local/bin/5dive reports 0.19.1"* && "$WARNED" == *DIVE-2762* ]]; } \
  && ok_t "installed OLDER than claimed: the DIVE-2762 shape, named, and the mismatch sentence itself names the FILE" \
  || bad_t "older case" "$WARNED"

run_cmp "/usr/local/bin/5dive|0.19.3" "" "VERIFIED ON v0.19.2"
{ [[ "$WARNED" == *NEWER* && "$WARNED" != *"DEPLOYED-VS-CLAIMED MISMATCH"* ]]; } \
  && ok_t "installed NEWER: a note, NOT the mismatch banner (direction is graded, not just difference)" \
  || bad_t "newer case" "$WARNED"

# --- ARM 4: the three honest non-answers --------------------------------------
run_cmp "" "return 1" "VERIFIED ON v0.19.2"
{ [[ "$WARNED" == *"did NOT run"* && "$WARNED" == *"not checked"* ]]; } \
  && ok_t "artifact unreadable: says NOT CHECKED out loud, never silence and never 'agreed'" \
  || bad_t "unreadable case" "$WARNED"

run_cmp "/usr/local/bin/5dive|0.0.0-dev" "" "VERIFIED ON v0.19.2"
{ [[ "$WARNED" == *"dev build"* && "$WARNED" != *OLDER* ]]; } \
  && ok_t "dev build: refuses to order a dev version against a release instead of false-REDing every worktree" \
  || bad_t "dev case" "$WARNED"

run_cmp "/usr/local/bin/5dive|0.19.3" "" "landed the fix, rollout tracked in DIVE-2816"
{ [[ -z "$WARNED" && -z "$STEPPED" ]]; } \
  && ok_t "no claim -> completely SILENT (the enabling half must cost a non-adopter nothing)" \
  || bad_t "no-claim case is noisy" "warn='$WARNED' step='$STEPPED'"

# --- ARM 5: empty extraction must RED, not read as all-arms-pass --------------
# The re-invocation needs a BASE CASE: without the fence the nested run reaches
# this arm too and re-invokes itself forever. Found by hanging the harness twice,
# which is the cheap way to learn that a self-invoking arm is a recursion.
if [[ -z "${DIVE2835_NESTED:-}" ]]; then
  : > "/tmp/dive2835-noblock.$$"
  out=$(DIVE2835_NESTED=1 timeout 30 bash "$0" "/tmp/dive2835-noblock.$$" 2>&1); rc=$?
  rm -f "/tmp/dive2835-noblock.$$"
  { [[ $rc -ne 0 && "$out" == *"is not unique"* ]]; } \
    && ok_t "pointed at a file with no block: reds (rc=$rc), never a vacuous green" \
    || bad_t "empty extraction did not red" "rc=$rc out=${out:0:200}"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
