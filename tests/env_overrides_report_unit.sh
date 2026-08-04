#!/usr/bin/env bash
# DIVE-2328 (builds DIVE-2327) — doctor/selfcheck REPORT the FIVE_* knobs in effect and
# configured. Facts only: name and value, never a warning.
#
# WHY THE ROW EXISTS. A knob in effect is true about this box and no surface said so.
# That silence is correct for an INTENDED knob — lodar's 2026-07-29 policy sets
# FIVE_VERIFY_DEFAULT=0 for sixteen agents — and identical for an accidental one. On
# DIVE-2325 the absence of this surface cost an hour: a /proc sweep found the knob in one
# session and was read as one operator's stray export, when sixteen were CONFIGURED and
# fifteen simply had not restarted. `configured` is the half that closes that.
#
# THREE TRAPS THIS HARNESS IS BUILT AROUND, all called out on the row before I started:
#
#  1. tests/lib/env_isolation.sh (DIVE-2325) blanket-clears FIVE_* at the seam every
#     harness sources. A test that exports its knob BEFORE that line grades NOTHING and
#     still goes green. So every process-side arm exports AFTER the source, and T1b is a
#     live guard that the isolation really did run first — otherwise this whole file
#     could be silently measuring the host instead of its fixtures.
#
#  2. "Prints nothing when none are set" PASSES ON EMPTY OUTPUT, so it is not evidence.
#     The negative arms here are paired with a neutralization run: see the mutation grade
#     below, which is required to clear this row and which I ran rather than predicted.
#
#  3. chmod IS INERT AGAINST ROOT. The denied-read arms cannot be created as root, and a
#     root run would sail through them reporting green while measuring nothing. They SKIP
#     with a named reason at EUID 0 rather than passing. A skip count is not a pass count.
#
# MUTATION GRADE — RUN, not predicted (2026-07-29; 17 passed / 0 failed / 0 skipped clean,
# each mutation applied to src/ AND rebuilt so the bundle T10 executes moved too):
#   * `_env_overrides_json() { printf '{}'; }`        -> 6/11. Everything that reports.
#   * drop the CONFIGURED half only                    -> 10/7. T3/T4/T5/T6/T7-anchor red,
#     T1/T9 (process side) stay green — the two halves are independently graded.
#   * collapse `partial` back to `unreadable`          -> 16/1. ONLY T5. T4 stays green,
#     and that pair is the evidence the fourth state does work rather than decorate: a
#     mutation that erases the distinction reds exactly the arm about the distinction.
#   * drop redaction on the configured path            -> 15/2. Both T6 file arms; the
#     process-side redaction arm stays green, so they are not one assertion twice.
#   * widen the file grep to ALL assignments           -> 16/1. T7, the no-dump arm.
#   * put the report back INSIDE .checks via doctor_add -> 18/2. Both T11 count arms; the
#     T11 anchor stays green, because the key is still emitted — the defect was never
#     absence, it was being COUNTED.
#
# AND ONE DEFECT IN THE PRODUCT THAT ONLY A REVIEWER'S QUESTION CAUGHT, which is why T11
# exists: every arm above grades the PAYLOAD, and "no judgement language" was true of the
# payload while false at the READER. severity=ok is the schema's neutral member because it
# feeds no warning/error count — and the dashboard sums `severity === "ok"` into a green
# "Passed" stat and hides everything else by default. So sixteen configured knobs became
# sixteen passed checks, and the surface built to make a knob FINDABLE was behind a
# "show all" toggle. A value that is neutral in a payload is not neutral once summed.
#
# TWO DEFECTS IN THIS HARNESS THAT ONLY ITS OWN ANCHORS AND A MISSING SUMMARY CAUGHT,
# recorded because both are the kind that ship green:
#   * T10 was GREEN AND VACUOUS. `cmd_doctor` calls require_root BEFORE parsing argv, so
#     as a normal user both the positive and the bogus category die at the permission
#     check and never reach the allow-list — the positive arm asserted the absence of a
#     message that could not have been produced. Only the ANCHOR went red. Now routed
#     through `sudo -n`, and skipped with a named reason where that is unavailable.
#   * The first run stopped after T9 with fifteen `ok`, no `FAIL` and NO SUMMARY, rc=10 —
#     src/header.sh does `set -euo pipefail`, so sourcing production code re-enables
#     errexit and the first non-zero command substitution killed the file. Grade on the
#     summary line, never the tail.
# Run: bash tests/env_overrides_report_unit.sh   (no network; T10 needs passwordless sudo,
# the denied-read arms need NOT-root — both skip with a reason rather than passing.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

# shellcheck source=/dev/null
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/env_overrides.sh; do
  source "$SRC/$f"
done
# `set +e` AFTER the sources, and it is load-bearing — 132 sibling harnesses carry the
# same line. src/header.sh does `set -euo pipefail`, so SOURCING PRODUCTION CODE TURNS
# ERREXIT BACK ON regardless of this file's own `set -uo pipefail` at the top. Without
# this line the first command substitution that exits non-zero — T10 runs `./5dive doctor`
# as non-root, which correctly exits 10 — kills the harness mid-file. Measured: the run
# stopped after T9 having printed fifteen `ok` lines, NO `FAIL`, and NO SUMMARY, with
# rc=10. That reads as a clean green to anything that greps for FAIL or reads the tail;
# the missing summary is the only witness. Grade on the summary line, never the tail.
set +e

TMP="$(mktemp -d /tmp/env-ov-unit.XXXXXX)"
PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }

# Fixtures use RESERVED FAKES — never a real agent name (5dive/CLAUDE.md). `testagent`
# and `otheragent` exist on no box.
mkdir -p "$TMP/readable" "$TMP/mixed" "$TMP/denied" "$TMP/empty"
cat >"$TMP/readable/testagent.env" <<'EOF'
AGENT_NAME=testagent
FIVE_VERIFY_DEFAULT=0
NOT_A_FIVE_VAR=ignore-me
EOF
# The no-dump fixture: a credential-shaped line that is NOT FIVE_-named must never be
# emitted, and neither must a FIVE_-named one whose NAME looks credential-shaped.
cat >"$TMP/readable/otheragent.env" <<'EOF'
OPENAI_API_KEY=sk-not-a-real-key-000000
FIVE_API_BASE=https://example.com
FIVE_FAKE_TOKEN=tok-not-a-real-token-000
EOF
cp "$TMP/readable/testagent.env" "$TMP/mixed/testagent.env"
printf 'FIVE_GATE_MAIN_BRANCH=trunk\n' >"$TMP/mixed/denied.env"
printf 'FIVE_GATE_REPOS=who/knows\n'   >"$TMP/denied/secret.env"
chmod 000 "$TMP/mixed/denied.env" "$TMP/denied/secret.env" 2>/dev/null

jqf() { jq -r "$1" <<<"$2" 2>/dev/null; }

# --- T1: process side — a knob exported in THIS shell is listed with its value. -------
# Exported AFTER the isolation seam ran (trap 1). Before it, this grades nothing.
export FIVE_TEST_KNOB=hello
out=$(_env_overrides_json "$TMP/empty/*.env")
[[ "$(jqf '.process[] | select(.name=="FIVE_TEST_KNOB") | .value' "$out")" == "hello" ]] \
  && ok_t 'T1 a knob in the process env is reported with its value' \
  || bad_t 'T1 process knob' "out=$out"

# T1b — THE ISOLATION GUARD. env_isolation.sh must have cleared the host's knobs at
# source time; if it did not, every arm in this file is silently reading the real box.
# On this host FIVE_VERIFY_DEFAULT is set fleet-wide by policy, so its ABSENCE from the
# process list is the proof that isolation ran before the fixtures were built.
[[ -z "$(jqf '.process[] | select(.name=="FIVE_VERIFY_DEFAULT") | .name' "$out")" ]] \
  && ok_t 'T1b isolation ran first — the host fleet knob is NOT bleeding into these arms' \
  || bad_t 'T1b harness is measuring the host, not its fixtures' "out=$out"
unset FIVE_TEST_KNOB

# --- T2: nothing set, nothing configured -> both empty, state=absent. -----------------
# Vacuous on its own (empty output passes) — see the mutation grade in the header.
out=$(_env_overrides_json "$TMP/empty/*.env")
[[ "$(jqf '.process | length' "$out")" == "0" && "$(jqf '.configured | length' "$out")" == "0" \
   && "$(jqf '.configured_state' "$out")" == "absent" ]] \
  && ok_t 'T2 nothing set anywhere: both lists empty and state=absent (graded by mutation, not by this)' \
  || bad_t 'T2 empty case' "out=$out"

# --- T3: THE POINT OF THE ROW — configured but NOT in the process env. ----------------
# This is the DIVE-2325 blind spot: a knob that binds on the next restart and is invisible
# to every process-side read.
out=$(_env_overrides_json "$TMP/readable/*.env")
cfg_v=$(jqf '.configured[] | select(.name=="FIVE_VERIFY_DEFAULT") | .value' "$out")
cfg_f=$(jqf '.configured[] | select(.name=="FIVE_VERIFY_DEFAULT") | .file' "$out")
[[ "$cfg_v" == "0" && "$cfg_f" == *"testagent.env" && "$(jqf '.process | length' "$out")" == "0" ]] \
  && ok_t 'T3 a knob CONFIGURED but not in the process env is reported, with its file' \
  || bad_t 'T3 configured-not-in-process' "out=$out"
[[ "$(jqf '.configured_state' "$out")" == "read" ]] \
  && ok_t 'T3 state=read when every source was readable' \
  || bad_t 'T3 state=read' "out=$out"

# --- T4: everything denied -> state=unreadable, and NOT an empty "none configured". ---
if (( EUID == 0 )); then
  skip_t 'T4 all-denied -> state=unreadable' 'running as root: chmod 000 is inert, so this cannot be measured here'
  skip_t 'T5 mixed read+denied -> state=partial' 'running as root: chmod 000 is inert, so this cannot be measured here'
else
  out=$(_env_overrides_json "$TMP/denied/*.env")
  [[ "$(jqf '.configured_state' "$out")" == "unreadable" \
     && "$(jqf '.configured | length' "$out")" == "0" \
     && "$(jqf '.configured_unreadable | length' "$out")" -ge 1 ]] \
    && ok_t 'T4 a denied read is state=unreadable with the path named — NOT an empty list' \
    || bad_t 'T4 unreadable is not absent' "out=$out"

  # --- T5: MIXED read + denied -> state=partial. Olivia: partial fires under ORDINARY
  #     config (the unit names an EnvironmentFile under /etc a non-root caller cannot
  #     read), so the fixture must cover mixed, not just all-or-nothing.
  out=$(_env_overrides_json "$TMP/mixed/*.env")
  st=$(jqf '.configured_state' "$out"); n=$(jqf '.configured | length' "$out")
  u=$(jqf '.configured_unreadable | length' "$out")
  [[ "$st" == "partial" && "$n" -ge 1 && "$u" -ge 1 ]] \
    && ok_t 'T5 some read AND some denied is state=partial, with the missed path carried' \
    || bad_t 'T5 partial (the fourth state)' "st=$st n=$n u=$u out=$out"
  [[ "$(jqf '.configured_unreadable[0]' "$out")" == *"denied.env"* ]] \
    && ok_t 'T5 the reader is told WHICH source is unaccounted for' \
    || bad_t 'T5 must name the missed source' "out=$out"
fi

# --- T6: REDACTION by NAME, on both sides. Value only; the name still reports. --------
out=$(_env_overrides_json "$TMP/readable/*.env")
[[ "$(jqf '.configured[] | select(.name=="FIVE_FAKE_TOKEN") | .value' "$out")" == "<redacted>" ]] \
  && ok_t 'T6 a credential-shaped NAME has its value redacted, and is still listed' \
  || bad_t 'T6 redaction' "out=$out"
[[ "$out" != *"tok-not-a-real-token"* ]] \
  && ok_t 'T6 the redacted value appears nowhere in the payload' \
  || bad_t 'T6 value leaked' "out=$out"
export FIVE_PROC_SECRET=leak-me-not
o2=$(_env_overrides_json "$TMP/empty/*.env")
[[ "$(jqf '.process[] | select(.name=="FIVE_PROC_SECRET") | .value' "$o2")" == "<redacted>" \
   && "$o2" != *"leak-me-not"* ]] \
  && ok_t 'T6 redaction applies to the PROCESS side too, not only to files' \
  || bad_t 'T6 process-side redaction' "o2=$o2"
unset FIVE_PROC_SECRET

# --- T7: NEVER DUMP A FILE. agents.d carries symlinks into auth-profiles combined.env,
#     so only FIVE_*-NAMED assignments may ever leave the reader.
[[ "$out" != *"sk-not-a-real-key"* && "$out" != *"OPENAI_API_KEY"* && "$out" != *"NOT_A_FIVE_VAR"* ]] \
  && ok_t 'T7 non-FIVE_ assignments (incl. a credential line) never appear in the payload' \
  || bad_t 'T7 file contents leaked' "out=$out"
[[ "$(jqf '.configured[] | select(.name=="FIVE_API_BASE") | .value' "$out")" == "https://example.com" ]] \
  && ok_t 'T7 ANCHOR: the FIVE_ line in that same file IS read — T7 is not vacuous' \
  || bad_t 'T7 anchor' "out=$out"

# --- T8: NO JUDGEMENT LANGUAGE anywhere in the payload. -------------------------------
# The row's central constraint: report presence and value, never a verdict. doctor cannot
# know intent, and a line calling lodar's policy "unexpected" is how we end up back here.
bad_words=""
for w in unexpected suspicious insecure should warning WARN danger misconfigur wrong invalid; do
  [[ "${out,,}" == *"${w,,}"* ]] && bad_words="${bad_words:+$bad_words }$w"
done
[[ -z "$bad_words" ]] \
  && ok_t 'T8 the payload carries no judgement language' \
  || bad_t 'T8 judgement language present' "found: $bad_words"

# --- T9: the namespace is enumerated, not hardcoded. A knob invented right now, that no
#     list in the codebase mentions, must still be reported.
export FIVE_KNOB_INVENTED_TODAY=42
o3=$(_env_overrides_json "$TMP/empty/*.env")
[[ "$(jqf '.process[] | select(.name=="FIVE_KNOB_INVENTED_TODAY") | .value' "$o3")" == "42" ]] \
  && ok_t 'T9 an unknown FIVE_ knob is reported — the namespace is enumerated dynamically' \
  || bad_t 'T9 hardcoded list' "o3=$o3"
unset FIVE_KNOB_INVENTED_TODAY

# --- T10: `--category=policy` is REACHABLE. Pre-existing defect: the allow-list omitted
#     `policy` while run_policy dispatched it and the usage text advertised it, so anyone
#     who read the error and did what it said got a usage failure.
#     Asserted on the USAGE message, not the exit code, so it holds with or without root.
#     MUST RUN AS ROOT, and the ANCHOR is what proved it. `cmd_doctor` calls
#     require_root BEFORE it parses argv, so as a normal user BOTH `--category=policy`
#     and `--category=nosuchcat` die at the permission check having never reached the
#     allow-list. The positive arm alone was therefore GREEN AND VACUOUS — it asserted
#     the absence of a usage message that could not have been produced. Only the anchor
#     went red, which is the entire reason it is here.
if [[ ! -x ./5dive ]]; then
  skip_t 'T10 --category=policy reachable' 'built ./5dive bundle not present'
  skip_t 'T10 anchor' 'built ./5dive bundle not present'
elif ! sudo -n true 2>/dev/null; then
  skip_t 'T10 --category=policy reachable' 'no passwordless sudo: doctor require_root fires before argv is parsed, so this cannot be measured here'
  skip_t 'T10 anchor' 'no passwordless sudo: see above'
else
  o4=$(sudo -n ./5dive doctor --category=policy 2>&1)
  [[ "$o4" != *"unknown --category"* ]] \
    && ok_t 'T10 --category=policy is accepted (was a usage error)' \
    || bad_t 'T10 policy still unreachable' "o4=$(head -c 200 <<<"$o4")"
  o5=$(sudo -n ./5dive doctor --category=nosuchcat 2>&1)
  [[ "$o5" == *"unknown --category"* ]] \
    && ok_t 'T10 ANCHOR: a genuinely bogus category still errors — T10 is not vacuous' \
    || bad_t 'T10 anchor' "o5=$(head -c 200 <<<"$o5")"
fi

# --- T11: THE CONSUMER PROPERTY. A report must not be counted as a result.
#     Found by main asking the right question during review: my claim ("no judgement
#     language") was about the PAYLOAD, and the risk lives at the READER. Measured — the
#     first cut used doctor_add with severity=ok, and the dashboard does
#       passing = checks.filter(c => c.severity === "ok").length
#     rendered in green, so sixteen configured-knob lines became sixteen PASSED CHECKS:
#     an assertion of health nobody made. `--category=policy` reported "17 checks, 17 ok"
#     where exactly ONE check had run. And its default view is
#       visible = checks.filter(c => c.severity !== "ok")
#     so the surface built to make an unintended knob FINDABLE was hidden unless you
#     clicked "show all". `ok` is neutral in the payload and NOT neutral once summed.
#     So env_overrides rides alongside .checks, never inside it — which is what selfcheck
#     already did, and this arm is what stops doctor drifting back.
if [[ -x ./5dive ]] && sudo -n true 2>/dev/null; then
  dj=$(sudo -n ./5dive --json doctor --category=policy 2>/dev/null)
  n_in_checks=$(jqf '[.data.checks[]? | select(.name|startswith("env-"))] | length' "$dj")
  passed=$(jqf '.data.summary.passed' "$dj"); total=$(jqf '.data.summary.total' "$dj")
  [[ "$n_in_checks" == "0" ]] \
    && ok_t 'T11 the env report is NOT in .checks — no green badge, not hidden by the ok-filter' \
    || bad_t 'T11 report leaked into checks' "n=$n_in_checks"
  [[ "$passed" == "$total" && "$total" -le 2 ]] \
    && ok_t "T11 summary counts only real checks (total=$total) — the report inflates nothing" \
    || bad_t 'T11 summary inflated by the report' "passed=$passed total=$total"
  [[ -n "$(jqf '.data.env_overrides.configured_state' "$dj")" ]] \
    && ok_t 'T11 ANCHOR: env_overrides IS present as its own key — T11 is not passing by absence' \
    || bad_t 'T11 anchor: the report vanished entirely' "dj=$(head -c 200 <<<"$dj")"
else
  skip_t 'T11 report is not counted as a result' 'needs the built bundle and passwordless sudo (doctor require_root)'
  skip_t 'T11 summary not inflated' 'see above'
  skip_t 'T11 anchor' 'see above'
fi

echo "-----"
printf 'env_overrides_report_unit: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
