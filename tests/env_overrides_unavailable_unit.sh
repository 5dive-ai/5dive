#!/usr/bin/env bash
# DIVE-2336 — a FAILED env-override report must not render as "no overrides set".
#
# THE DEFECT. Both consumers of _env_overrides_json wrapped it twice:
#     X=$(_env_overrides_json 2>/dev/null || printf '{}')
#     [[ -n "$X" ]] || X='{}'
# `{}` has no process list, no configured list and no state, so every consumer reads it as
# NO OVERRIDES ARE SET. That is the could-not-check-as-negative shape DIVE-2318 closed in
# the merge gate and DIVE-2327 closed for an unreadable agents.d — reappearing one level up
# INSIDE the code that closes it. Four sites, not two: the empty-string coercion is the
# same defect as the `|| printf`, and main caught that when routing the row.
#
# WHICH OF THE FOUR ACTUALLY MATTERS — MEASURED, and it inverts the obvious reading. I
# stubbed jq to fail at each of the 7 invocations a clean run makes, at every position:
#
#     fail@1..6 -> rc=2, EMPTY stdout        fail@7 -> rc=1, EMPTY stdout
#
# EVERY position produced empty stdout, so the visible `|| printf '{}'` arm is NOT the one
# the real failure mode reaches — the EMPTY-STRING coercion is. Fixing only the two obvious
# sites would have left the live path untouched and looked complete.
#
# AND IT CORRECTS MY OWN EARLIER CLAIM. Filing this row I wrote that a mid-loop jq failure
# "could drop entries and still emit a well-formed partial as if complete". It cannot: an
# emptied accumulator makes the NEXT jq fail on invalid --argjson, so the run dies instead
# of shipping a short list. But that safety is ACCIDENTAL — it holds only because the
# poison propagates, and one `|| true` added downstream converts it into exactly the
# partial-as-complete I wrongly claimed. So the rc checks went in anyway, as a guard on a
# property that is currently true by luck rather than by construction.
#
# MUTATION GRADE — RUN, and TWO OF MY FOUR PREDICTIONS WERE WRONG (2026-07-29; 12/0/0 clean):
#
#   * restore `|| printf '{}'` at BOTH call sites   -> 10/2: T7 ONLY. I predicted T5/T6.
#   * restore ONLY the empty-string coercion        -> 10/2: T7 ONLY. Same.
#
#     WHY, AND IT IS WORTH MORE THAN THE PREDICTION WAS. The fix has two layers: the
#     FUNCTION now guarantees a well-formed payload, and the CALL SITES no longer invent
#     one. With the function holding its contract the call-site coercion is UNREACHABLE —
#     it is defence-in-depth against a future caller, not a live path — so no behavioural
#     arm can red on it and only the STRUCTURAL arm can. That is precisely why T7 exists
#     and why it is a grep rather than a run: it is the only thing that can catch half a
#     fix here. Anyone re-running this and expecting T5/T6 to move should not "fix the
#     harness" — the arms are correct and the reachability is the finding.
#
#   * make _env_ov_unavailable emit `{}`            -> 7/5: T1, T3, T4, T5, T6. T2 STAYS
#     GREEN, which is the property the row demanded: `unavailable` and `absent` red
#     DIFFERENT named assertions, so the two states are not one assertion wearing two names.
#   * make _env_ov_unavailable shell out to jq      -> 11/1: T4 alone. The fallback must
#     survive the absence of the very tool whose absence it exists to report.
#   * MOVE the fallback constant out of header.sh into lib/env_overrides.sh (still
#     defined, wrong home)                          -> 15/1: T8 alone. That is the arm
#     standing guard over the regression this change actually caused.
#   * VOID MUTATION, recorded: DELETING the constant outright grades nothing — T0
#     dereferenced it bare, so `set -u` killed the file before any arm ran. Fixed with
#     `${...:-}` so an absent constant REDS an assertion instead of ending the run. If a
#     mutation produces no summary line, it broke the harness; it did not grade it.
#
# Run: bash tests/env_overrides_unavailable_unit.sh   (no network; the doctor arm needs
# passwordless sudo and SKIPS with a reason rather than passing.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
# shellcheck source=/dev/null
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/env_overrides.sh; do
  source "$SRC/$f"
done
# AFTER the sources: header.sh does `set -euo pipefail`, so sourcing production code
# re-enables errexit and the first non-zero substitution would kill this file mid-run —
# printing oks, no FAIL and NO SUMMARY. (Cost me a run on DIVE-2328.)
set +e

TMP="$(mktemp -d /tmp/env-ov-unavail.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
skip_t() { SKIP=$((SKIP+1)); printf 'SKIP - %s\n   %s\n' "$1" "${2:-}"; }

mkdir -p "$TMP/bin" "$TMP/env" "$TMP/empty"
printf 'FIVE_GATE_MAIN_BRANCH=trunk\n' >"$TMP/env/testagent.env"   # reserved fake name

# A SURGICAL jq stub: passes everything through EXCEPT the one invocation that assembles
# this payload, identified by a key only that call uses. Precise on purpose — a stub that
# broke jq wholesale would break selfcheck itself and the arm would red for the wrong
# reason, proving nothing about the call site.
cat >"$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
# Match the jq PROGRAM text, never a key that also appears in the DATA. First cut keyed
# on *configured_unreadable*, which the assembled payload itself contains — so the stub
# also killed selfcheck's OWN final jq (the one taking --argjson eov) and both call-site
# arms failed with empty output, looking like the product was broken. `configured_state:$s`
# is filter syntax and cannot occur in the data.
for a in "$@"; do case "$a" in *'configured_state:$s'*) exit 1 ;; esac; done
exec /usr/bin/jq "$@"
STUB
chmod +x "$TMP/bin/jq"

jqr() { /usr/bin/jq -r "$1" 2>/dev/null; }

# --- T0: the fallback is PARSEABLE and matches the single constant. Trivial-looking and
#     it caught a real bug immediately: the first cut wrote `${_5D_ENV_OV_UNAVAILABLE:-<json>}`
#     and a `}` inside the default TERMINATES the expansion, so the function emitted the
#     payload plus a stray trailing brace. Every downstream arm then failed with an empty
#     state and pointed at the CALL SITES, which were fine.
fbj=$(_env_ov_unavailable)
printf '%s' "$fbj" | /usr/bin/jq -e . >/dev/null 2>&1 \
  && ok_t 'T0 the fallback payload is valid JSON' \
  || bad_t 'T0 fallback is not parseable' "fb=[$fbj]"
# `:-` so a MISSING constant reds this assertion instead of killing the file under set -u —
# the first mutation attempt did exactly that and graded nothing.
[[ "$fbj" == "${_5D_ENV_OV_UNAVAILABLE:-}" && -n "${_5D_ENV_OV_UNAVAILABLE:-}" ]] \
  && ok_t 'T0 the function and the header constant are the SAME string — no drift' \
  || bad_t 'T0 function/constant drift' "fn=[$fbj] const=[${_5D_ENV_OV_UNAVAILABLE:-UNSET}]"

# --- T1: the reporter cannot run -> state=unavailable, well-formed, rc 0. -------------
out=$(PATH="$TMP/bin:$PATH" _env_overrides_json "$TMP/env/*.env" 2>/dev/null); rc=$?
st=$(printf '%s' "$out" | jqr '.configured_state // "MISSING"')
[[ $rc -eq 0 && "$st" == "unavailable" ]] \
  && ok_t 'T1 a failed reporter reports UNAVAILABLE, well-formed and rc 0' \
  || bad_t 'T1 unavailable' "rc=$rc st=$st out=$out"
[[ -n "$out" ]] \
  && ok_t 'T1 it never exits with EMPTY stdout — the caller is not left to invent a payload' \
  || bad_t 'T1 empty stdout' "rc=$rc"

# --- T2: ANCHOR. `absent` must remain reachable and DISTINCT, or T1 proves nothing —
#     a fix that renamed every outcome to `unavailable` would pass T1 and be useless.
out2=$(_env_overrides_json "$TMP/empty/*.env" 2>/dev/null)
st2=$(printf '%s' "$out2" | jqr '.configured_state // "MISSING"')
[[ "$st2" == "absent" ]] \
  && ok_t 'T2 ANCHOR: genuinely-nothing still reports ABSENT, so the two states are distinguishable' \
  || bad_t 'T2 absent collapsed' "st2=$st2 out2=$out2"

# --- T3: EVERY failure position, not just a convenient one. The measurement that decided
#     the fix said all 7 cascade to empty; this asserts all of them now report.
# Richer fixture so the sweep covers as many positions as the measurement in the header
# (2 process knobs + 2 files = 7 jq invocations). Exported HERE, after the isolation seam
# in grading_tree.sh has run — before it, env_isolation.sh (DIVE-2325) would clear them and
# the process half of this sweep would silently cover nothing.
export FIVE_SWEEP_ONE=1 FIVE_SWEEP_TWO=2
printf 'FIVE_GATE_REPOS=who/knows\n' >"$TMP/env/otheragent.env"
printf 'FIVE_API_BASE=https://example.com\n' >"$TMP/env/thirdagent.env"
cnt="$TMP/jqcount"
cat >"$TMP/bin/jqn" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$JQ_COUNT" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$JQ_COUNT"
[[ "$n" == "$JQ_FAIL_AT" ]] && exit 1
exec /usr/bin/jq "$@"
STUB
chmod +x "$TMP/bin/jqn"; mkdir -p "$TMP/nbin"; ln -sf "$TMP/bin/jqn" "$TMP/nbin/jq"
export JQ_COUNT="$cnt"; : >"$cnt"
JQ_FAIL_AT=0 PATH="$TMP/nbin:$PATH" _env_overrides_json "$TMP/env/*.env" >/dev/null 2>&1
total=$(cat "$cnt" 2>/dev/null || echo 0)
bad_pos=""
if [[ "$total" -gt 0 ]]; then
  for i in $(seq 1 "$total"); do
    : >"$cnt"
    o=$(JQ_FAIL_AT=$i PATH="$TMP/nbin:$PATH" _env_overrides_json "$TMP/env/*.env" 2>/dev/null)
    s=$(printf '%s' "$o" | jqr '.configured_state // "EMPTY"')
    [[ "$s" == "unavailable" ]] || bad_pos="${bad_pos:+$bad_pos }$i:$s"
  done
fi
[[ "$total" -gt 0 && -z "$bad_pos" ]] \
  && ok_t "T3 a jq failure at ANY of the $total invocation positions reports unavailable" \
  || bad_t 'T3 some position still emits empty/partial' "total=$total bad=$bad_pos"
[[ "$total" -ge 7 ]] \
  && ok_t "T3 the sweep covered $total positions — as many as the measurement it is based on" \
  || bad_t 'T3 sweep too narrow to stand behind the header claim' "total=$total (want >=7)"
unset JQ_COUNT FIVE_SWEEP_ONE FIVE_SWEEP_TWO

# --- T4: the fallback must survive its own CAUSE. The likeliest reason the reporter
#     failed is that jq is gone, so a fallback that needs jq to say so says nothing.
# ABSOLUTE path to bash: a `PATH=x cmd` prefix changes the lookup used for `cmd` itself,
# so `PATH="$TMP/empty" bash` cannot find bash and the arm fails for a reason that has
# nothing to do with the fallback.
fb=$(PATH="$TMP/empty" /bin/bash -c 'source '"$SRC"'/lib/env_overrides.sh; _env_ov_unavailable' 2>/dev/null)
[[ "$(printf '%s' "$fb" | jqr '.configured_state')" == "unavailable" ]] \
  && ok_t 'T4 the fallback needs no jq — it still speaks when jq is the thing that is gone' \
  || bad_t 'T4 fallback depends on jq' "fb=$fb"

# --- T5: THE CALL SITE, exercised for real. selfcheck does not require_root, so this is
#     the arm that reproduces the defect end-to-end rather than testing the helper twice.
if [[ -x ./5dive ]]; then
  sj=$(PATH="$TMP/bin:$PATH" ./5dive selfcheck --json --only=gate-delivery 2>/dev/null)
  sst=$(printf '%s' "$sj" | jqr '.env_overrides.configured_state // "MISSING"')
  [[ "$sst" == "unavailable" ]] \
    && ok_t 'T5 selfcheck call site: a failed reporter surfaces as unavailable, not as {}' \
    || bad_t 'T5 selfcheck coerced a failure into nothing-to-report' "state=$sst"
  # ANCHOR: the same command with a WORKING jq must NOT say unavailable, or T5 passes on
  # a selfcheck that is broken for unrelated reasons.
  sj2=$(./5dive selfcheck --json --only=gate-delivery 2>/dev/null)
  sst2=$(printf '%s' "$sj2" | jqr '.env_overrides.configured_state // "MISSING"')
  [[ "$sst2" != "unavailable" && "$sst2" != "MISSING" ]] \
    && ok_t "T5 ANCHOR: with a working jq the same call reports '$sst2' — T5 is not vacuous" \
    || bad_t 'T5 anchor' "state=$sst2"
else
  skip_t 'T5 selfcheck call site' 'built ./5dive not present'
  skip_t 'T5 anchor' 'built ./5dive not present'
fi

# --- T6: the doctor call site. Needs root (require_root fires before argv is parsed —
#     that is what made a DIVE-2328 arm green and vacuous), so it SKIPS with a reason.
if [[ -x ./5dive ]] && sudo -n true 2>/dev/null; then
  dj=$(sudo -n env "PATH=$TMP/bin:$PATH" ./5dive --json doctor --category=policy 2>/dev/null)
  dst=$(printf '%s' "$dj" | jqr '.data.env_overrides.configured_state // "MISSING"')
  [[ "$dst" == "unavailable" ]] \
    && ok_t 'T6 doctor call site: a failed reporter surfaces as unavailable, not as {}' \
    || bad_t 'T6 doctor coerced a failure into nothing-to-report' "state=$dst"
  dj2=$(sudo -n ./5dive --json doctor --category=policy 2>/dev/null)
  dst2=$(printf '%s' "$dj2" | jqr '.data.env_overrides.configured_state // "MISSING"')
  [[ "$dst2" != "unavailable" && "$dst2" != "MISSING" ]] \
    && ok_t "T6 ANCHOR: with a working jq the same call reports '$dst2' — T6 is not vacuous" \
    || bad_t 'T6 anchor' "state=$dst2"
else
  skip_t 'T6 doctor call site' 'needs the built bundle and passwordless sudo (doctor require_root)'
  skip_t 'T6 anchor' 'see above'
fi

# --- T7: FOUR SITES, not two. The `|| printf` arm and the empty-string arm are separate
#     coercions, and the measurement says the EMPTY one is what the real failure reaches.
#     Asserted structurally because no runtime input can distinguish them once both are
#     fixed — this is the arm that catches half a fix.
for f in src/cmd_doctor.sh src/cmd_selfcheck.sh; do
  if grep -qE "_env_overrides_json[^|]*\|\|[[:space:]]*printf[[:space:]]*'\{\}'" "$f" \
     || grep -qE "^[[:space:]]*\[\[ -n \"\\\$(_eov|DOCTOR_ENV_OVERRIDES)\" \]\][[:space:]]*\|\|.*'\{\}'" "$f"; then
    bad_t "T7 $f still coerces a failure to '{}'" "$(grep -nE "'\{\}'" "$f" | head -2)"
  else
    ok_t "T7 $f coerces neither arm to '{}'"
  fi
done

# --- T8: THE REGRESSION THIS FIX CAUSED AND THE FULL SUITE CAUGHT. tests/selfcheck_unit.sh
#     sources only header/error_codes/output/cmd_selfcheck — NOT lib/env_overrides.sh. My
#     first cut used `_env_ov_unavailable` as the call-site fallback, so in that context the
#     fallback was as missing as the reporter it covered: _eov came back empty, `jq
#     --argjson eov ""` failed, and selfcheck's whole --json contract died (33/0 -> 26/7).
#     A FALLBACK MUST NOT LIVE IN THE FILE IT IS A FALLBACK FOR. That is the same property
#     T4 asserts one level down, and I broke it one level up in the same change.
hv=$(/bin/bash -c 'source '"$SRC"'/header.sh 2>/dev/null; printf "%s" "${_5D_ENV_OV_UNAVAILABLE:-MISSING}"' 2>/dev/null)
[[ "$hv" != "MISSING" ]] && printf '%s' "$hv" | /usr/bin/jq -e . >/dev/null 2>&1 \
  && ok_t 'T8 header.sh ALONE defines the fallback constant — available wherever a call site is' \
  || bad_t 'T8 fallback constant needs more than header.sh' "hv=[$hv]"
# ANCHOR: header.sh alone must NOT bring the function, or T8 proves nothing about WHY the
# constant is the right fallback.
hf=$(/bin/bash -c 'source '"$SRC"'/header.sh 2>/dev/null; declare -F _env_ov_unavailable >/dev/null && echo PRESENT || echo ABSENT' 2>/dev/null)
[[ "$hf" == "ABSENT" ]] \
  && ok_t 'T8 ANCHOR: the FUNCTION is absent in that same context — which is why the constant is the fallback' \
  || bad_t 'T8 anchor: function unexpectedly present' "hf=$hf"

echo "-----"
printf 'env_overrides_unavailable_unit: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ $FAIL -eq 0 ]]
