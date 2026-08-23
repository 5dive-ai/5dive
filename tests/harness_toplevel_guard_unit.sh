#!/usr/bin/env bash
# DIVE-3679 — tests/meta/harness-verdict-toplevel.sh
#
# The guard's two owed negative controls, made PERMANENT. The row asked for them
# before the guard was allowed to fail anything; running them once on the author's box
# arms nothing, so they live here and red in CI the moment the guard stops
# discriminating. That is the whole difference between "the arms ran" and "the arms
# are armed" — a monitor has to be shown it can FIRE, in the environment where it
# fires, not just shown it does not false-alarm.
#
# Weighted toward the FALSE-CLEAN direction, because that is the direction that costs
# a release: a guard that never accuses passes every day and is worth nothing, and a
# guard that accuses a correctly-wired harness is the DIVE-2039 mistake DIVE-3678 was
# rejected for. So both a firing arm and a NON-firing arm are graded, plus the two
# ways this check could report clean on something it never looked at.
#
# Hermetic apart from arms 3/4, which grade the REAL harness that caused DIVE-3675 at
# a pinned commit and its parent. Those skip loudly (never silently) on a shallow
# clone; every job that runs this corpus uses fetch-depth 0 for exactly that reason.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
GUARD="$PWD/tests/meta/harness-verdict-toplevel.sh"
[[ -r "$GUARD" ]] || { printf 'FAIL: %s not found\n' "$GUARD"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hvt.XXXXXX") || exit 2
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n     %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# ARM 1 — IT FIRES. Verdict inside an arm no pristine lane enters: the exact shape
# that read `not-reached` in all seven environments and refused the v0.21.3 cut.
# ---------------------------------------------------------------------------
cat > "$TMP/violating.sh" <<'STUB'
#!/usr/bin/env bash
FAIL=0
if [[ -n "${LIVE_RELAY:-}" ]]; then
  echo "live arm"
  [[ "$FAIL" -eq 0 ]]
fi
STUB
out=$(bash "$GUARD" --enforce "$TMP/violating.sh" 2>&1); rc=$?
if (( rc == 1 )) && grep -q VIOLATION <<<"$out"; then
  ok "a verdict inside an arm is a VIOLATION and --enforce exits non-zero"
else bad "a verdict inside an arm is a VIOLATION and --enforce exits non-zero" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 2 — IT DOES NOT OVER-FIRE. A harness that skips everything in this
# environment but ends in one top-level verdict is CORRECT and must pass. This is the
# arm that separates this guard from the one DIVE-3678 proposed: `not-reached` here is
# legitimate, and reding on it would accuse every installed-host-only harness.
# ---------------------------------------------------------------------------
cat > "$TMP/healthy.sh" <<'STUB'
#!/usr/bin/env bash
FAIL=0
live_arms() {
  if [[ -z "${LIVE_RELAY:-}" ]]; then echo "SKIP: no relay"; return; fi
  echo "live arm"
}
live_arms
[[ "$FAIL" -eq 0 ]]
STUB
out=$(bash "$GUARD" --enforce "$TMP/healthy.sh" 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'top level' <<<"$out"; then
  ok "a skip-everywhere harness with ONE top-level verdict is green (no false accusation)"
else bad "a skip-everywhere harness with ONE top-level verdict is green (no false accusation)" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARMS 3/4 — the REAL pair, pinned. 07a4345 is the DIVE-3675 fix; its parent is the
# tree that broke the train. A stub can be written to satisfy any instrument; these
# two cannot.
# ---------------------------------------------------------------------------
PIN=07a4345
REAL=tests/buzz_preseed_dm_live.sh
if git cat-file -e "$PIN^:$REAL" 2>/dev/null && git cat-file -e "$PIN:$REAL" 2>/dev/null; then
  git show "$PIN^:$REAL" > "$TMP/real_parent.sh"
  out=$(bash "$GUARD" --enforce "$TMP/real_parent.sh" 2>&1); rc=$?
  if (( rc == 1 )); then ok "the real harness at ${PIN}^ — the tree that refused the v0.21.3 cut — REDS"
  else bad "the real harness at ${PIN}^ — the tree that refused the v0.21.3 cut — REDS" "rc=$rc — $out"; fi
  git show "$PIN:$REAL" > "$TMP/real_fixed.sh"
  out=$(bash "$GUARD" --enforce "$TMP/real_fixed.sh" 2>&1); rc=$?
  if (( rc == 0 )); then ok "the same harness at ${PIN} — live-only, skips in every pristine lane — is GREEN"
  else bad "the same harness at ${PIN} — live-only, skips in every pristine lane — is GREEN" "rc=$rc — $out"; fi
else
  skip "the real DIVE-3675 pair at ${PIN}/${PIN}^" "commit or path not present — shallow clone? this corpus is run with fetch-depth 0 (DIVE-2229)"
  skip "the real DIVE-3675 pair at ${PIN}/${PIN}^ (fixed side)" "same"
fi

# ---------------------------------------------------------------------------
# ARM 5 — WARN-ONLY STILL REPORTS. The guard ships warn-only, so the claim "it is
# reporting" has to be graded too: without --enforce a violation must exit 0 AND
# still print the finding. A warn-only mode that also went quiet would be a guard
# that is wired to nothing while looking installed.
# ---------------------------------------------------------------------------
out=$(bash "$GUARD" "$TMP/violating.sh" 2>&1); rc=$?
if (( rc == 0 )) && grep -q VIOLATION <<<"$out" && grep -q 'WARN-ONLY' <<<"$out"; then
  ok "warn-only exits 0 but still PRINTS the violation"
else bad "warn-only exits 0 but still PRINTS the violation" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 6 — A SELECTOR THAT RESOLVED TO NOTHING IS NOT A PASS, in either mode. This is
# the false-clean shape `changed-harnesses` already guards on its base commit: a
# check reporting clean on what it never looked at.
# ---------------------------------------------------------------------------
out=$(bash "$GUARD" --only=no_such_harness_xyz.sh 2>&1); rc=$?
if (( rc == 1 )) && grep -q BLOCKED <<<"$out"; then
  ok "an --only that matches no harness BLOCKS rather than reporting clean"
else bad "an --only that matches no harness BLOCKS rather than reporting clean" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 7 — NO SECOND ACCUSATION PATH. A harness with neither probe family (no counter,
# no `set -e`) is the probe's UNPROBEABLE and fails THERE. If this guard also failed
# it, the two instruments could disagree about the same file, and the fix for one
# would be a red in the other.
# ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\necho hello\n' > "$TMP/noverdict.sh"
out=$(bash "$GUARD" --enforce "$TMP/noverdict.sh" 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'no-verdict-line' <<<"$out"; then
  ok "no identifiable verdict is reported, not accused (the probe owns UNPROBEABLE)"
else bad "no identifiable verdict is reported, not accused (the probe owns UNPROBEABLE)" "rc=$rc — $out"; fi

# ---------------------------------------------------------------------------
# ARM 8 — THE ABORT FAMILY IS GRADED TOO. `set -e` plus bare assertions has no
# counter, and the probe injects a bare `false` before the LAST executable line. If
# this guard skipped that family it would print a clean pass over 25 of the 444
# harnesses on main — measured, not estimated.
# ---------------------------------------------------------------------------
cat > "$TMP/abort_violating.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${LIVE_RELAY:-}" ]]; then
  [[ 1 -eq 1 ]]
fi
STUB
out=$(bash "$GUARD" --enforce "$TMP/abort_violating.sh" 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'abort family' <<<"$out"; then
  ok "an abort-family harness whose last executable line is inside an arm REDS"
else bad "an abort-family harness whose last executable line is inside an arm REDS" "rc=$rc — $out"; fi

printf -- '-----\nRESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
