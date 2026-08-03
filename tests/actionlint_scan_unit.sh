#!/usr/bin/env bash
# DIVE-2540 — scripts/actionlint-scan.sh, the workflow-file gate.
#
# WHAT THIS GRADES, and why each arm can fail. The subject is a wrapper around an
# external linter, and EVERY way that wrapper can be broken presents as "no
# findings": binary missing, binary dead, flags that lint nothing, an empty
# target set, a checker whose rule moved. So the arms below are almost entirely
# about the difference between a clean scan and an UNPROVEN one.
#
#   the instrument must FIRE   arms 2-4. A stub that accepts the DIVE-2539
#                              fixture, one that rejects it for the wrong reason,
#                              and one that rejects EVERYTHING must all produce
#                              exit 2, never 0 and never 1. Arm 4 is what stops
#                              the canary from being satisfiable by a grep.
#   absence is not clean       arms 1 and 8: no binary, and no workflow files.
#                              Both exit 2. "I scanned nothing" is not a pass.
#   the verdict is faithful    arms 5-7: clean tree -> 0, findings -> 1, and a
#                              usage/internal error from the binary -> 2 rather
#                              than 1, because a crash is not a finding.
#   the canary is the SAME run arm 9 reads the stub's recorded argv: canary and
#                              tree scan must carry identical flags, or the proof
#                              is about an invocation that never happened.
#   the fixture can still fail arm 10. The canary file must be ACCEPTED by
#                              yaml.safe_load and must carry the delimiter inside
#                              a `run:` block — the exact combination that made
#                              DIVE-2539 invisible. A fixture edited into
#                              harmless YAML would leave every arm above green
#                              while grading nothing.
#   CI cannot disarm it        arm 11: no workflow may pass --no-canary, and the
#                              gate must actually call the shared scanner.
#   the real binary            arm 12, SKIPPED unless actionlint is on PATH. The
#                              stub arms grade our wrapper; only this one grades
#                              the claim that actionlint names this defect at
#                              all, and a skip is not a pass.
#
# NO NETWORK, NO ROOT, NO REAL BINARY REQUIRED: arms 1-11 run against a stub
# actionlint whose behaviour is chosen per arm.
#
# Run: bash tests/actionlint_scan_unit.sh
set -uo pipefail

# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE the cd
# so ${BASH_SOURCE[0]} still resolves relative to tests/.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
SCAN="$REPO/scripts/actionlint-scan.sh"
BAD="$REPO/tests/fixtures/actionlint/canary-expression-in-run-comment.yml"
GOOD="$REPO/tests/fixtures/actionlint/known-good-yaml-level-comment.yml"

PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){   FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
# A skip is NOT a pass. An unavailable precondition must never inflate a green log.
skip(){ SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[[ -x "$SCAN" ]] || { no "scripts/actionlint-scan.sh is missing or not executable"; printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"; exit 1; }

# --- the stub -----------------------------------------------------------------
# Emulates actionlint's CONTRACT (exit 0 clean / 1 findings / 2 usage) and records
# every invocation's argv, so the arms can grade both the verdict mapping and the
# flags the wrapper actually used. STUB_MODE picks the behaviour per arm.
STUB="$TMP/actionlint"
ARGV_LOG="$TMP/argv.log"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
targets=(); for a in "$@"; do [[ "$a" == -* ]] || targets+=("$a"); done
is_canary_bad=0; is_canary_good=0
for t in "${targets[@]}"; do
  case "$t" in
    *canary-expression-in-run-comment.yml) is_canary_bad=1 ;;
    *known-good-yaml-level-comment.yml)    is_canary_good=1 ;;
  esac
done
case "${STUB_MODE:?}" in
  dead)        exit 0 ;;                         # never fires, on anything
  # Fires on EVERYTHING, and tagged [expression] on purpose: an over-firing
  # binary that also failed the wrong-reason check would be rejected by the layer
  # ABOVE the one arm 4 exists to isolate, and the arm would pass while the
  # over-fire branch stayed unexercised. This is the witness row only that branch
  # rejects. Shape: a grep for the delimiter, which is what a hand-rolled
  # substitute for actionlint would be.
  overfire)    echo "${targets[0]:-?}: unexpected end of input [expression]"; exit 1 ;;
  wrong_reason)
    if (( is_canary_bad )); then echo "canary: unrelated problem [syntax-check]"; exit 1; fi
    exit 0 ;;
  honest)      (( is_canary_bad )) && { echo "bad:10:61: unexpected end of input [expression]"; exit 1; }
               exit 0 ;;
  findings)    (( is_canary_bad )) && { echo "bad:10:61: unexpected end of input [expression]"; exit 1; }
               (( is_canary_good )) && exit 0
               echo ".github/workflows/x.yml:3:1: property not defined [syntax-check]"; exit 1 ;;
  crash)       (( is_canary_bad )) && { echo "bad:10:61: unexpected end of input [expression]"; exit 1; }
               (( is_canary_good )) && exit 0
               echo "flag provided but not defined" >&2; exit 2 ;;
esac
STUB_EOF
chmod +x "$STUB"

# run_scan <mode> [args...] -> sets RC and OUT
run_scan(){ local mode="$1"; shift
  : > "$ARGV_LOG"
  OUT="$(STUB_MODE="$mode" ARGV_LOG="$ARGV_LOG" ACTIONLINT_BIN="$STUB" bash "$SCAN" "$@" 2>&1)"; RC=$?
}

# --- arm 1: no binary is not a clean tree ------------------------------------
OUT="$(ACTIONLINT_BIN="$TMP/definitely-not-installed" bash "$SCAN" 2>&1)"; RC=$?
(( RC == 2 )) \
  && ok "A1 a missing actionlint exits 2, not 0 (rc=$RC)" \
  || no "A1 a missing actionlint must exit 2 — got rc=$RC: $OUT"
grep -q 'REFUSING to report clean' <<<"$OUT" \
  && ok "A1b it says it is refusing rather than reporting nothing" \
  || no "A1b no refusal on stderr: $OUT"

# --- arm 2: THE arm. A dead instrument must not produce a green ---------------
# This is the failure mode a linter gate has by default: the binary runs, finds
# nothing because it is looking at nothing, and the job goes green forever.
run_scan dead
(( RC == 2 )) \
  && ok "A2 a binary that accepts the DIVE-2539 fixture exits 2 (rc=$RC)" \
  || no "A2 a dead instrument must exit 2, never $RC — clean-on-nothing is the whole defect: $OUT"
# A2b IS LOAD-BEARING, not message polish. Measured against a mutant that removes
# the fire check: the dead stub's empty output then falls through to the signature
# check, which refuses for its OWN reason — so A2 alone stays GREEN with the guard
# it names deleted. The refusal STRING is the only thing that separates the two
# layers here, which is the one case where asserting on a message is asserting on
# the condition.
grep -q 'CANARY DID NOT FIRE' <<<"$OUT" \
  && ok "A2b the reason names the canary, not the adjacent guard" \
  || no "A2b expected 'CANARY DID NOT FIRE': $OUT"

# --- arm 3: fired, but not as an expression error ----------------------------
run_scan wrong_reason
(( RC == 2 )) \
  && ok "A3 a canary rejected WITHOUT an [expression] finding exits 2 (rc=$RC)" \
  || no "A3 rc!=0 alone must not satisfy the canary — got rc=$RC: $OUT"

# --- arm 4: the isolating arm — a scanner that rejects everything ------------
# Without this, arm 2 is satisfiable by `exit 1`, i.e. by a grep for the
# delimiter — which would also reject this repo's own write-up of the hazard.
run_scan overfire
(( RC == 2 )) \
  && ok "A4 a binary that also rejects the KNOWN-GOOD fixture exits 2 (rc=$RC)" \
  || no "A4 over-firing must exit 2, not $RC — else the canary is a grep: $OUT"
grep -q 'OVER-FIRES' <<<"$OUT" \
  && ok "A4b the reason distinguishes over-firing from a real finding" \
  || no "A4b expected 'OVER-FIRES': $OUT"

# --- arms 5-7: the verdict mapping -------------------------------------------
run_scan honest
(( RC == 0 )) \
  && ok "A5 canary fired + tree clean -> exit 0" \
  || no "A5 expected 0, got $RC: $OUT"

run_scan findings
(( RC == 1 )) \
  && ok "A6 canary fired + findings in the tree -> exit 1" \
  || no "A6 expected 1, got $RC: $OUT"
grep -q 'property not defined' <<<"$OUT" \
  && ok "A6b the findings themselves reach stdout" \
  || no "A6b findings were swallowed: $OUT"

run_scan crash
(( RC == 2 )) \
  && ok "A7 a usage/internal error from the binary -> exit 2, not 1 (a crash is not a finding)" \
  || no "A7 expected 2, got $RC: $OUT"

# --- arm 8: an empty target set is not a clean tree --------------------------
# Built as a real skeleton so the script's own ROOT resolution is what finds
# nothing — asserting this through a flag would grade a path CI never takes.
mkdir -p "$TMP/skel/scripts" "$TMP/skel/.github/workflows"
cp "$SCAN" "$TMP/skel/scripts/"
OUT="$(STUB_MODE=honest ARGV_LOG="$ARGV_LOG" ACTIONLINT_BIN="$STUB" \
       ACTIONLINT_CANARY_BAD="$BAD" ACTIONLINT_CANARY_GOOD="$GOOD" \
       bash "$TMP/skel/scripts/actionlint-scan.sh" 2>&1)"; RC=$?
(( RC == 2 )) \
  && ok "A8 an empty .github/workflows exits 2, not 0 (rc=$RC)" \
  || no "A8 a renamed/emptied workflow dir must not read as clean — got rc=$RC: $OUT"

# --- arm 9: the canary and the tree scan are the SAME invocation -------------
run_scan honest
canary_flags="$(awk '{f=""; for(i=1;i<=NF;i++) if ($i ~ /^-/) f=f" "$i; print f}' "$ARGV_LOG" | head -1)"
tree_flags="$(awk '{f=""; for(i=1;i<=NF;i++) if ($i ~ /^-/) f=f" "$i; print f}' "$ARGV_LOG" | tail -1)"
[[ -n "$canary_flags" && "$canary_flags" == "$tree_flags" ]] \
  && ok "A9 canary and tree scan carry identical flags ($canary_flags)" \
  || no "A9 flags differ — canary:'$canary_flags' tree:'$tree_flags'; the proof would be about another run"
grep -q -- '-shellcheck=' <<<"$tree_flags" \
  && ok "A9b shellcheck integration is OFF by default (three INFO findings in this tree today)" \
  || no "A9b expected -shellcheck= in the default flags: $tree_flags"
run_scan honest --with-shellcheck
tree_flags="$(awk '{f=""; for(i=1;i<=NF;i++) if ($i ~ /^-/) f=f" "$i; print f}' "$ARGV_LOG" | tail -1)"
grep -q -- '-shellcheck=' <<<"$tree_flags" \
  && no "A9c --with-shellcheck must REMOVE the disabling flag: $tree_flags" \
  || ok "A9c --with-shellcheck re-enables it — tightening is one flag, not a rewrite"

# --- arm 10: the canary fixture must still be able to fail -------------------
# The DIVE-2539 shape is precisely "valid YAML that Actions cannot parse". If the
# fixture ever stops being valid YAML, or stops carrying the delimiter inside a
# `run:` block, every arm above stays green while proving nothing.
if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$BAD" 2>/dev/null; then
  ok "A10 the canary fixture is VALID YAML — it exercises the expression layer, not the YAML layer"
else
  no "A10 the canary fixture no longer parses as YAML; it would now fail for the wrong reason"
fi
# Inside a `run:` block scalar there are no comments as far as substitution is
# concerned. Track block-scalar depth rather than grepping the whole file, so a
# delimiter moved up to YAML level (where it is harmless) reds this arm.
in_run_delim="$(awk '
  /^[[:space:]]*run:[[:space:]]*[|>]/ { inrun=1; ind=match($0,/[^ ]/); next }
  inrun && /[^[:space:]]/ { if (match($0,/[^ ]/) <= ind) inrun=0 }
  inrun && /\$\{\{/ { n++ }
  END { print n+0 }' "$BAD")"
(( in_run_delim >= 1 )) \
  && ok "A10b the canary carries an expression delimiter INSIDE a run: block ($in_run_delim)" \
  || no "A10b the canary no longer carries the defect inside a run: block — it cannot fire"
good_in_run="$(awk '
  /^[[:space:]]*run:[[:space:]]*[|>]/ { inrun=1; ind=match($0,/[^ ]/); next }
  inrun && /[^[:space:]]/ { if (match($0,/[^ ]/) <= ind) inrun=0 }
  inrun && /\$\{\{/ { n++ }
  END { print n+0 }' "$GOOD")"
(( good_in_run == 0 )) && grep -q '\${{' "$GOOD" \
  && ok "A10c the known-good fixture carries the delimiter only at YAML level — the discriminator holds" \
  || no "A10c known-good fixture is not the discriminator it claims to be (in-run=$good_in_run)"

# --- arm 11: the gate cannot be disarmed in CI -------------------------------
if grep -rq -- '--no-canary' .github/workflows/; then
  no "A11 a workflow passes --no-canary — that flag exists for this harness only and disarms the proof"
else
  ok "A11 no workflow passes --no-canary"
fi
if grep -rq 'scripts/actionlint-scan.sh' .github/workflows/; then
  ok "A11b a workflow calls the shared scanner (no forked scan logic in CI)"
else
  no "A11b nothing in .github/workflows calls scripts/actionlint-scan.sh"
fi

# --- arm 12: the REAL binary, when there is one ------------------------------
# The arms above grade our wrapper against a stub. Only this one grades the claim
# the whole row rests on: that actionlint names THIS defect. Skipped, loudly,
# where the binary is absent.
REAL="${ACTIONLINT_REAL_BIN:-$(command -v actionlint 2>/dev/null || true)}"
if [[ -x "$REAL" ]]; then
  real_out="$("$REAL" -no-color -oneline -shellcheck= -pyflakes= "$BAD" 2>&1)"; real_rc=$?
  { (( real_rc == 1 )) && grep -q '\[expression\]' <<<"$real_out"; } \
    && ok "A12 real actionlint rejects the canary as an [expression] error" \
    || no "A12 real actionlint did not name the defect (rc=$real_rc): $real_out"
  "$REAL" -no-color -oneline -shellcheck= -pyflakes= "$GOOD" >/dev/null 2>&1 \
    && ok "A12b real actionlint accepts the known-good fixture" \
    || no "A12b real actionlint rejected a known-good workflow"
  ACTIONLINT_BIN="$REAL" bash "$SCAN" >/dev/null 2>&1 \
    && ok "A12c the tree in this checkout is clean under the real binary" \
    || no "A12c the real scan is not clean on this tree"
else
  skip "A12 actionlint is not installed here — the real-binary arms did not run (CI installs a pinned copy)"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
