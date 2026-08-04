#!/usr/bin/env bash
# TIER: nightly — 378s measured (control plane, 2026-08-03, DIVE-2555): does not fit the 300s PR core; the nightly sweep runs it.
# The 300.0s this file shipped with named NO environment and NO date, so neither later
# reading could refute it, only disagree: 335s (main, control plane) and 378s (dev3,
# same box, `time bash tests/gate_channel_session_t2_mutation.sh` -> rc 0, 14 mutants
# killed). scripts/run-harnesses.sh now grades this number against its own clock every
# time the sweep runs it, so the next reading refutes it in the log instead of in a
# ticket. Quote the environment when you replace it.
# DIVE-2412 mutation grader for tests/gate_channel_session_t2_unit.sh.
#
# WHY THIS FILE EXISTS. Most of what DIVE-2412 ships is REFUSALS, and "it must
# not accept an agent's claim" is an absence-assertion: an arm that only checks a
# non-zero rc stays green when the condition it is supposed to be guarding is
# deleted, because some other refusal fires instead and the rc is the same. The
# ticket asks for exactly this: force each path and confirm the refusal is the
# one being claimed. So each mutant below DELETES ONE condition from a copy of
# src and requires the NAMED arm to go red. A mutant that leaves the suite green
# means that arm grades nothing.
#
# The acceptance direction is graded too (M6, M7): a suite made only of refusals
# passes trivially on code that refuses everything, which would ship a tier-2
# gate that no channel proof can ever clear.
#
# Every mutant asserts its own application (exactly one occurrence, or the run
# fails loudly) — a mutation that silently no-ops after a refactor would
# otherwise read as a passing grade.
# Run: bash tests/gate_channel_session_t2_mutation.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/gate-cs-mut.XXXXXX)"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# grade <name> <expected-red-arm-substring> <old> <new>
grade() {
  local name="$1" want="$2" old="$3" new="$4"
  local dir="$TMP/$name"; rm -rf "$dir"; mkdir -p "$dir"
  cp -r src "$dir/src"
  if ! OLD="$old" NEW="$new" F="$dir/src/cmd_task.sh" python3 - <<'PY'
import os, sys
p, old, new = os.environ["F"], os.environ["OLD"], os.environ["NEW"]
s = open(p).read()
n = s.count(old)
if n != 1:
    sys.stderr.write("mutation did not apply cleanly: %d occurrences of %r\n" % (n, old[:90]))
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  then
    bad_t "$name — mutation applies to the current source" "the anchor is gone or duplicated; this mutant graded NOTHING"
    return
  fi
  local out rc
  out=$(CS_SRC_DIR="$dir/src" CS_MUTATED="$name" bash tests/gate_channel_session_t2_unit.sh 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    bad_t "$name — the suite must go RED" "suite stayed GREEN with the condition removed: the '$want' arm grades nothing"
    return
  fi
  if grep -q "FAIL - .*${want}" <<<"$out"; then
    ok_t "$name — kills the '$want' arm"
  else
    bad_t "$name — kills the '$want' arm" "suite failed, but NOT on that arm: $(grep '^FAIL' <<<"$out" | head -3)"
  fi
}

# ── the refusal conditions, one at a time ────────────────────────────────────
grade "M1-sender-check" "CS4 a message from a DIFFERENT sender" \
  '  if [[ "$osender" != "$chat" ]]; then' \
  '  if false; then'

grade "M2-freshness" "CS6 a STALE cited message" \
  '  if (( _age > _max )); then' \
  '  if false; then'

grade "M3-origin-type" "CS5 a HIDDEN forward origin" \
  '  if [[ "$otype" != "user" ]]; then' \
  '  if false; then'

# NOTE the expected arm: not CS3's rc arm but its REASON arm. Deleting the
# existence check still yields a non-zero rc (the error payload has no
# forward_origin, so the attribution check refuses instead), so only the arm that
# reads the reason can tell which condition fired. Measured on this tree.
grade "M4-existence" "CS3 the refusal names the condition" \
  "  if ! jq -e '.ok == true' <<<\"\$resp\" >/dev/null 2>&1; then" \
  '  if false; then'

# The binding is now TWO conditions (iteration 2), so it takes two mutants: one
# for "which gate" and one for "which answer". A single either/or mutant would
# have left whichever half survived ungraded — which is how the value-only clear
# reached iteration 1.
grade "M5a-ident-required" "CS7 a message naming the ANSWER VALUE only" \
  '  if [[ -z "$_ni" || "$_hay" != *"$_ni"* ]]; then' \
  '  if false; then'

grade "M5b-answer-required" "CS7 a message naming the IDENT only" \
  '  if [[ -n "$_nv" && "$_hay" != *"$_nv"* ]]; then' \
  '  if false; then'

grade "M6-token-failclosed" "CS8 an UNATTESTABLE citation" \
  '  if [[ -z "${TASK_CH_TOKEN:-}" ]]; then' \
  '  if false; then'

# ── the tier fence: chat-only proof must NOT reach tier 2 ────────────────────
# This is the mutant that matters most, because it is the shape of the bug the
# ticket warns against — widening the DIVE-1305 form instead of adding an
# attested one.
#
# THE EXPECTED ARM IS THE DECISION ONE, and which arm that is changed on the
# rebase onto main. On an APPROVAL gate the widened fence is now caught one guard
# further down as well (main's DIVE-2233 site refuses an unproven tier-2 --human
# claim, and every approval gate has a minted nonce), so CS2 stays green and no
# longer isolates the fence. A tier-2 DECISION gate mints no nonce, so that site
# is skipped and the fence is the ONLY thing standing there — measured: with the
# fence widened, CS11's uncited relay CLEARS. That is the arm that grades it.
grade "M7-tier-fence-widened" "CS11 the same tier-2 DECISION gate REFUSES" \
  '  if [[ -n "$channel_proof" && "$gtier" != "2" ]]; then' \
  '  if [[ -n "$channel_proof" ]]; then'

# ── the acceptance direction, so the suite is not "refuses everything" ───────
grade "M8-accept-path-dead" "CS1 tier-2 gate CLEARS" \
  '      _cs_ok=1' \
  '      _cs_ok=0'

grade "M9-form-not-recorded" "CS1 records the form as channel-session" \
  '  db "UPDATE tasks SET human_evidence=$(sqlq "${_evform:-none}") WHERE id=${id};"' \
  '  : "${_evform:-none}"'

# ── the tier-2 floor itself, which is the ONLY guard on a decision gate ──────
# The approval/secret/manual evidence block does not run for `decision`, so if the
# citation stopped raising `human` the decision arms would be the ones to notice.
#
# RE-ANCHORED 2026-08-04 (DIVE-2589). DIVE-2588 (#399) dropped the
# `&& _gate_proof_enforced` conjunct from this floor — it was a rollout envelope the
# constrained party could switch off — so the anchor stopped matching and this mutant
# reported "mutation applies to the current source", i.e. it graded NOTHING and said
# so. That is the harness's own self-check working exactly as its header promises,
# and it is why the mutation is asserted to apply rather than assumed to: a
# no-op mutant is otherwise indistinguishable from a killed one.
grade "M10-floor-provenance" "CS11 the same tier-2 DECISION gate REFUSES" \
  '  if [[ "$gtier" == "2" ]] && (( ! human )); then' \
  '  if false; then'

# ── the freshness bound, which iteration 1 let the caller set ────────────────
# M11 removes the clamp and leaves the raw env read that olivia measured the
# bypass on; the CS12 red-team arm must be what goes red. M12 kills the env read
# entirely, which must take the LIVENESS arm red instead — without it, "clamped"
# and "hardcoded, env ignored" would be indistinguishable and the tighten-only
# contract would be an untested claim.
grade "M11-window-clamp-removed" "CS12 a caller-WIDENED window" \
  '|| (( _max <= 0 || _max > _ceil )); then _max=$_ceil; fi' \
  '; then _max=$_ceil; fi'

grade "M12-window-knob-dead" "CS12 a TIGHTER window from the env" \
  '  local _ceil=3600 _max="${GATE_CHANNEL_SESSION_MAX_AGE:-}"' \
  '  local _ceil=3600 _max=""'

# ── the DIVE-2233 tier-2 evidence site, which is where the citation is ADMITTED ──
# Found on the rebase onto main: raising `human` clears the floor, and then this
# site refuses the claim as unproven unless the citation is listed among the
# evidence forms. Every approval/manual gate has a minted nonce, so every one of
# them lands inside that branch — dropping `_t2_cs` kills the feature on its main
# case while leaving all twelve mutants above green.
grade "M13-t2-evidence-omits-citation" "CS1 tier-2 gate CLEARS" \
  '      if (( ! _t2_hp && ! _t2_su && ! _t2_cs )); then' \
  '      if (( ! _t2_hp && ! _t2_su )); then'

printf '\ngate_channel_session_t2_mutation: %d mutants killed, %d ungraded\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
