#!/usr/bin/env bash
# TIER: nightly — 54.4s measured (dev3, control plane, 2026-08-05, wall-clock around `bash tests/gate_evidence_form_mutation.sh` -> rc 0, 8 mutants killed). Quote the environment when you replace this number. It does not fit the 300s PR core; the nightly sweep runs it. The argument is on the WHY NOT CORE lines below, because a demotion is third-preference and has to be read, not just parsed.
# DIVE-2799 mutation grader for tests/gate_evidence_form_unit.sh.
#
# WHY NOT CORE (DIVE-2824). This file does not cost what it asserts. It costs 8 x a full
# run of tests/gate_evidence_form_unit.sh, each against a mutated copy of src, so its
# price is set by the harness it grades and by the runner — and nothing a PR diff
# contains moves it. That is precisely the shape a wall-clock PR budget is the wrong
# instrument for: the cap exists to make a diff's own cost legible, and this file's cost
# is constant with respect to every diff that is not this file.
#
# At 54.4s it was the largest single item in the core tier and ~18% of the 300s cap,
# which is how an unrelated +1.1s guard went over the line: test-installed-host on PR
# #517 exited 4 with "OVER BUDGET by 1s (313s > 312s effective cap). NO TEST FAILED —
# 251 of 251 harnesses passed." Reclaiming only that 1.1s would have landed the corpus at
# 311.9s against a 312s cap, which is not a fix — it is the next author's red, and the
# runner's own >=80%-of-budget warning fires there for that reason.
#
# The gate-family siblings were demoted for exactly this argument and are already
# nightly: gate_channel_session_t2_mutation.sh (378s, DIVE-2555) and
# secret_gate_delivery_path_mutation.sh (55.7s, DIVE-2525). This file at core was the
# outlier, not the precedent. The two mutation graders that STAY in core measure 4.5s and
# 7.7s (task_add_parent_citation_warning, task_answer_cancelled_loop_bounce, same host and
# method) — the discriminator is COST, not the `_mutation` in the filename.
#
# WHAT THIS MOVES, stated rather than left to be discovered: no PRODUCT coverage leaves
# the PR core. tests/gate_evidence_form_unit.sh — the harness that grades the evidence-form
# behaviour itself — stays core. What moves to the nightly sweep is the proof that THAT
# FILE's arms are non-vacuous, which is a property of a test file and changes only when
# someone edits it. Editing it runs this grader anyway: the `changed-harnesses` job runs
# and verdict-probes every harness a diff touches, whatever tier it sits in.
#
# WHY THIS FILE EXISTS. Most of the unit suite asserts a field is PRESENT and
# carries a particular string, and presence-assertions are the easiest kind to
# write vacuously: a suite that greps for `evidence=` stays green if the field is
# hardcoded, if a token is silently renamed, or if the separator changes — every
# one of which breaks the historical sweep the field exists to serve. Each mutant
# below removes ONE property from a copy of src and requires the NAMED arm to go
# red. A mutant that leaves the suite green means that arm grades nothing.
#
# M7 grades the ACCEPTANCE direction: a suite made only of "the field says nonce"
# arms would pass on code that hardcodes `nonce`, so one mutant forces the helper
# to a constant and requires the liveness arm to notice.
#
# Every mutant asserts its own application (exactly one occurrence, or the run
# fails loudly) — a mutation that silently no-ops after a refactor would otherwise
# read as a passing grade, and an unwritable worktree would downgrade a mutant to
# a control (DIVE-2799 dev3: measured that failure mode elsewhere).
# Run: bash tests/gate_evidence_form_mutation.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/gate-evform-mut.XXXXXX)"

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
  # Prove the mutant actually differs on disk. An unwritable or unchanged copy
  # would run as a CONTROL and green identically to a killed mutant.
  if diff -q src/cmd_task.sh "$dir/src/cmd_task.sh" >/dev/null 2>&1; then
    bad_t "$name — mutant differs from the baseline on disk" "the copy is byte-identical to src: this mutant graded NOTHING"
    return
  fi
  local out rc
  out=$(EV_SRC_DIR="$dir/src" EV_MUTATED="$name" bash tests/gate_evidence_form_unit.sh 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    bad_t "$name — the suite must go RED" "suite stayed GREEN with the property removed: the '$want' arm grades nothing"
    return
  fi
  if grep -q "FAIL - .*${want}" <<<"$out"; then
    ok_t "$name — kills the '$want' arm"
  else
    bad_t "$name — kills the '$want' arm" "suite failed, but NOT on that arm: $(grep '^FAIL' <<<"$out" | head -3)"
  fi
}

# ── the field must reach the WRITE-SITE row (the whole-population sink) ───────
grade "M1-writesite-field-dropped" "EV1 the audit row's evidence= must equal" \
  '    "evidence=${_evform:-none}" "filer_answered=$(_gate_filer_answered "$id" "$_caller4")" \' \
  '    "filer_answered=$(_gate_filer_answered "$id" "$_caller4")" \'

# ── and the tier-2 evidence site, so ONE grep spans both ─────────────────────
grade "M2-t2site-field-dropped" "EV2 the tier-2 evidence site must carry evidence=" \
  '        "evidence=$(_gate_evidence_form "$_t2_hp" "$_t2_su" "$_t2_cs" 0 0)" \' \
  '        "human=$human" \'

# ── the VOCABULARY: a rename breaks the join to tasks.human_evidence ─────────
grade "M3-token-renamed" "EV6 sole-nonce must spell 'nonce' exactly" \
  'if [[ "${1:-0}" == "1" ]]; then out+="${out:++}nonce"; fi' \
  'if [[ "${1:-0}" == "1" ]]; then out+="${out:++}tap"; fi'

# ── the SEPARATOR: exact-match discrimination depends on it ──────────────────
# With a ',' separator the sole-nonce grep still works, but the compound arm's
# fixed-form assertion is what notices — which is the point: the historical sweep
# compares string literals, so the separator is part of the contract.
grade "M4-separator-changed" "EV3b compound order/separator is load-bearing" \
  'if [[ "${3:-0}" == "1" ]]; then out+="${out:++}channel-session"; fi' \
  'if [[ "${3:-0}" == "1" ]]; then out+="${out:+,}channel-session"; fi'

# ── the tier-2 DECISION record fix, which is the bug this change found ───────
# Reverting to the bare `_hp`/`_su` read is the pre-fix source. It must take the
# liveness arm red: a verified nonce on a tier-2 decision gate recorded `none`.
grade "M5-t2-decision-form-unrecorded" "EV0 liveness" \
  '    "$(( ${_hp:-0} || ${_t2_hp:-0} ))" "$(( ${_su:-0} || ${_t2_su:-0} ))" \' \
  '    "${_hp:-0}" "${_su:-0}" \'

# ── a missing filer must not be reported as a measured 0 ─────────────────────
grade "M6-missing-filer-reads-zero" "EV5b a missing filer must not be reported" \
  "  if [[ -z \"\$_f\" ]]; then printf 'unknown'; return; fi" \
  '  if [[ -z "$_f" ]]; then printf 0; return; fi'

# ── ACCEPTANCE direction: the field must be COMPUTED, not constant ───────────
grade "M7-form-hardcoded-none" "EV0 liveness" \
  '  printf '"'"'%s'"'"' "${out:-none}"' \
  '  printf none'

# ── filer_answered must DISCRIMINATE, not always agree ──────────────────────
grade "M8-filer-always-true" "EV5c filer_answered must separate the filer" \
  '  if [[ "${2#agent-}" == "$_f" ]]; then printf '"'"'1'"'"'; else printf '"'"'0'"'"'; fi' \
  '  printf 1'

printf '\ngate_evidence_form_mutation: %d mutants killed, %d ungraded\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
