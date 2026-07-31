#!/usr/bin/env bash
# DIVE-2411 mutation grader for tests/secret_gate_delivery_path_unit.sh.
#
# WHY THIS FILE EXISTS. What DIVE-2411 ships is two REFUSALS and one WITHHELD
# affordance, and "it must not accept a secret gate with nowhere to put the value"
# is an absence-assertion: an arm that checks only a non-zero rc stays green when
# the condition it is guarding is deleted, because some other refusal fires and
# the rc is identical. The ticket asks for exactly this — force each bad path and
# confirm the refusal is the one being claimed. Each mutant below deletes ONE
# condition from a COPY of src/ and requires the NAMED arm to go red. A mutant
# that leaves the suite green means that arm grades nothing.
#
# The ACCEPTANCE direction is graded too (P3), because a suite made of refusals
# passes trivially on code that refuses everything — which here would brick
# out-of-band delivery and the council's own escalation re-file.
#
# The REMEDY PROSE is graded too (T8). Half of this fix is a string: the old copy
# on a no-path gate said "put the key where I expect it, then tap ✅ Provided",
# which instructs the human to do something undefined and then attest to it. A
# refusal whose message still invites the paste has fixed nothing the human sees,
# and alarm text is exactly the half that ships with zero coverage.
#
# Every mutant asserts its own application (exactly one occurrence, or the run
# fails loudly) — a mutation that silently no-ops after a refactor would
# otherwise read as a passing grade.
# Run: bash tests/secret_gate_delivery_path_mutation.sh   (no root, no network)
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# NOTE the absence of `2>/dev/null`: redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/sgdp-mut.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# grade <name> <expected-red-arm-substring> <old> <new>
# src is COPIED per mutant and the unit suite is pointed at the copy
# (SGDP_SRC_DIR) — the working tree is never mutated, so a run killed halfway
# cannot leave a deleted safety condition behind for the next thing to grade.
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
  # A mutant that breaks the PARSE reddens every arm for the wrong reason, which
  # would read as a kill while grading nothing.
  if ! bash -n "$dir/src/cmd_task.sh" 2>/dev/null; then
    bad_t "$name — mutated source still parses" "the substitution produced a syntax error; every arm would red for the wrong reason"
    return
  fi
  local out rc
  out=$(SGDP_SRC_DIR="$dir/src" bash tests/secret_gate_delivery_path_unit.sh 2>&1); rc=$?
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

# ── half 1: the FILING refusal ───────────────────────────────────────────────
grade "M1-filing-refusal" "N1 filing with no delivery path is refused" \
  '  elif [[ "$type" == "secret" && -z "$secret_key$connector" ]]; then' \
  '  elif false; then'

grade "M2-oob-secret-only" "N2 --out-of-band on a non-secret gate is refused" \
  '    [[ "$type" == "secret" ]] \
      || fail "$E_VALIDATION" "--out-of-band only applies' \
  '    [[ 1 ]] \
      || fail "$E_VALIDATION" "--out-of-band only applies'

grade "M3-one-path-per-gate" "N3 --out-of-band + drop target is refused" \
  '    [[ -z "$secret_key$connector" ]] \
      || fail "$E_VALIDATION" "--out-of-band is mutually exclusive' \
  '    [[ 1 ]] \
      || fail "$E_VALIDATION" "--out-of-band is mutually exclusive'

# The opt-in must NAME the channel. Without this, `--out-of-band=y` is a flag that
# re-selects the defect — chosen, but still with nowhere for the value to go.
grade "M4-oob-must-name-channel" "N4 a bare --out-of-band=yes is refused" \
  '    [[ ${#oob} -ge 12 ]] \' \
  '    [[ 1 ]] \'

# ── half 2: the ANSWER refusal (the durable one) ─────────────────────────────
# Withholding the button only changes messages sent from now on; Telegram never
# expires the buttons already delivered, so this is the condition that stops the
# false record on every legacy gate still in someone's chat history.
grade "M5-answer-refusal" "N6 answering a no-path secret gate is refused" \
  '    [[ -n "$_paths" ]] || fail "$E_CONFLICT"' \
  '    [[ 1 ]] || fail "$E_CONFLICT"'

# ── the affordance ───────────────────────────────────────────────────────────
grade "M6-affordance-withheld" "N7 no ✅ Provided affordance" \
  '      if [[ -n "$_sk_row" || -n "$_oob_row" ]]; then' \
  '      if true; then'

# ── the acceptance direction ─────────────────────────────────────────────────
# A re-file carries the delivery path forward. src/council/engine.mjs re-files an
# escalated gate as `task need <ident> --type=secret --tier=2 --ask=…` and passes
# no delivery flags at all, so without inheritance the council escalation itself
# manufactures the DIVE-2232 shape out of a properly-targeted gate.
grade "M7-inheritance-dead" "P3 a re-file with no flags inherits the existing drop target" \
  '  if [[ "$type" == "secret" && -z "$secret_key$connector$oob" ]]; then' \
  '  if false; then'

# ── the remedy prose ─────────────────────────────────────────────────────────
grade "M8-old-paste-inviting-copy" "T8 the no-path alert names the missing path" \
  'Do NOT paste the credential here.' \
  'Put the key where I expect it, then tap ✅ Provided below.'

printf '\nsecret_gate_delivery_path_mutation: %d mutants killed, %d ungraded\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
