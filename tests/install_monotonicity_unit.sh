#!/usr/bin/env bash
# DIVE-2243: install.sh's upgrade path had NO monotonicity guard. The DIVE-2144
# publish-source cutover pointed the fleet at the newest release TAG while that
# tag sat below what boxes were running, so ~23h of self-updates rolled boxes
# BACKWARDS — and each one printed "5dive upgraded: 0.16.33 -> 0.16.32".
#
# This asserts the guard DISCRIMINATES rather than that it blocks: a lower
# candidate must be refused, a higher one must proceed, and the refusal must
# name both versions. Hermetic by construction — the guard and the report block
# are extracted VERBATIM from install.sh by their fence markers and run under
# install.sh's real `set -euo pipefail`, so this asserts the shipped bytes
# rather than a paraphrase of them (same shape as install_pin_sha_unit.sh).
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source. NOTE the absence of
# `2>/dev/null` — redirecting the source's stderr also swallows the helper's own
# stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TD:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

guard="$(sed -n '/^# >>> DIVE-2243 monotonicity guard/,/^# <<< DIVE-2243 monotonicity guard/p' install.sh)"
report="$(sed -n '/^  # >>> DIVE-2243 upgrade report/,/^  # <<< DIVE-2243 upgrade report/p' install.sh)"

if [[ -n "$guard" ]] && grep -q 'assert_version_monotonic()' <<<"$guard" && grep -q 'version_lt()' <<<"$guard"; then
  ok_t "monotonicity guard is extractable from install.sh"
else
  bad_t "monotonicity guard missing" "markers '# >>> / # <<< DIVE-2243 monotonicity guard' not found in install.sh"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [[ -n "$report" ]] && grep -q 'DOWNGRADED' <<<"$report"; then
  ok_t "upgrade-report block is extractable from install.sh"
else
  bad_t "upgrade-report block missing" "markers '# >>> / # <<< DIVE-2243 upgrade report' not found in install.sh"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

TD="$(mktemp -d)"
# A "5dive binary" here is only ever grepped for its FIVE_VERSION line, so a
# one-line stand-in exercises the real read path. `--none--` writes a file that
# carries no version at all (the unreadable case).
mkbin() { # $1=path $2=version|--none--
  if [[ "$2" == "--none--" ]]; then printf '#!/usr/bin/env bash\necho hi\n' > "$1"
  else printf '#!/usr/bin/env bash\nreadonly FIVE_VERSION="%s"\n' "$2" > "$1"; fi
}

# Run the extracted guard against an installed version and a candidate version.
# Prints stderr; returns the guard's rc. `--absent--` as the installed version
# means no binary on disk at all (fresh install).
run_guard() { # $1=installed $2=candidate [$3=FIVE_ALLOW_DOWNGRADE] [$4=GH_PINNED_TAG]
  local inst="$TD/installed" cand="$TD/candidate"
  rm -f "$inst" "$cand"
  [[ "$1" == "--absent--" ]] || mkbin "$inst" "$1"
  mkbin "$cand" "$2"
  env -i PATH="/usr/bin:/bin" \
    FIVE_ALLOW_DOWNGRADE="${3:-0}" GH_PINNED_TAG="${4:-}" GH_PINNED_SHA="" REPO="" \
    bash -c "set -euo pipefail
$guard
assert_version_monotonic '$inst' '$cand'" 2>&1
}

# 1. THE DEFECT: a strictly lower candidate is refused, and the refusal names
#    both versions and where the lower one came from.
out="$(run_guard 0.16.33 0.16.32 0 v0.16.32)"; rc=$?
if (( rc != 0 )) && [[ "$out" == *"refusing to DOWNGRADE"* && "$out" == *"0.16.33"* && "$out" == *"0.16.32"* && "$out" == *"v0.16.32"* ]]; then
  ok_t "0.16.33 -> 0.16.32 REFUSED, naming both versions and the resolved tag"
else
  bad_t "downgrade was not refused" "rc=$rc out: ${out//$'\n'/ | }"
fi

# 2. CONTROL — the guard must DISCRIMINATE, not block. A higher candidate
#    proceeds silently. Liveness for this negative is case 1 above: the same
#    harness proves the string DOES appear when the direction is backwards.
out="$(run_guard 0.16.32 0.17.0 0 v0.17.0)"; rc=$?
if (( rc == 0 )) && [[ "$out" != *"refusing to DOWNGRADE"* ]]; then
  ok_t "0.16.32 -> 0.17.0 PROCEEDS (guard discriminates on direction)"
else
  bad_t "forward upgrade was blocked" "rc=$rc out: ${out//$'\n'/ | }"
fi

# 3. VERSION SORT, not lexical. "0.16.10" sorts BELOW "0.16.9" as a string, so a
#    plain `sort` here would refuse an ordinary forward patch upgrade. This is
#    the same trap resolve_gh_tag documents, on the other side of the compare.
out="$(run_guard 0.16.9 0.16.10)"; rc=$?
if (( rc == 0 )) && [[ "$out" != *"refusing to DOWNGRADE"* ]]; then
  ok_t "0.16.9 -> 0.16.10 PROCEEDS (sort -V, not lexical sort)"
else
  bad_t "lexical sort refused a forward upgrade" "rc=$rc out: ${out//$'\n'/ | }"
fi

# 4. Equal versions are not a downgrade (the daily no-op self-update).
out="$(run_guard 0.17.0 0.17.0)"; rc=$?
if (( rc == 0 )) && [[ "$out" != *"refusing to DOWNGRADE"* ]]; then
  ok_t "0.17.0 -> 0.17.0 PROCEEDS (equal is not backwards)"
else
  bad_t "equal versions were refused" "rc=$rc out: ${out//$'\n'/ | }"
fi

# 5. The deliberate escape exists, and it is LOUD. A real rollback is legitimate;
#    the point is that it must be asked for, never a side effect of resolution.
out="$(run_guard 0.16.33 0.16.32 1 v0.16.32)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"DOWNGRADE 0.16.33 -> 0.16.32"* && "$out" == *"FIVE_ALLOW_DOWNGRADE=1"* ]]; then
  ok_t "FIVE_ALLOW_DOWNGRADE=1 permits the rollback and announces it"
else
  bad_t "escape hatch did not permit/announce the rollback" "rc=$rc out: ${out//$'\n'/ | }"
fi

# 6. Fresh install: nothing installed to move backwards from.
out="$(run_guard --absent-- 0.16.1)"; rc=$?
if (( rc == 0 )); then ok_t "no installed binary PROCEEDS (fresh install)"
else bad_t "fresh install was refused" "rc=$rc out: ${out//$'\n'/ | }"; fi

# 7. Unreadable version fails OPEN, and says so. An empty grep is not evidence of
#    a backwards move, and bricking an upgrade over one would be worse than the
#    defect this guards.
out="$(run_guard --none-- 0.16.1)"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"not comparable"* ]]; then
  ok_t "unreadable installed version PROCEEDS with a stated warning"
else
  bad_t "unreadable version did not fail open with a warning" "rc=$rc out: ${out//$'\n'/ | }"
fi

# --- the printed line -------------------------------------------------------
# The report is what made this invisible: it asserted a direction nothing had
# measured. Run the shipped branch verbatim with old/new pinned.
run_report() { # $1=_old_ver $2=_new_ver
  env -i PATH="/usr/bin:/bin" bash -c "set -euo pipefail
$(sed -n '/^# >>> DIVE-2243 monotonicity guard/,/^# <<< DIVE-2243 monotonicity guard/p' install.sh)
_old_ver='$1'; _new_ver='$2'; BIN_DIR='$TD'
$report" 2>&1
}

out="$(run_report 0.16.33 0.16.32)"
if [[ "$out" == *"5dive DOWNGRADED: 0.16.33 -> 0.16.32"* && "$out" != *"upgraded: 0.16.33"* ]]; then
  ok_t "report says DOWNGRADED (never 'upgraded') when the new version is lower"
else
  bad_t "report announced a downgrade as an upgrade" "out: ${out//$'\n'/ | }"
fi

out="$(run_report 0.16.32 0.17.0)"
if [[ "$out" == *"5dive upgraded: 0.16.32 -> 0.17.0"* && "$out" != *"DOWNGRADED"* ]]; then
  ok_t "report still says upgraded on a real forward move"
else
  bad_t "forward move mis-reported" "out: ${out//$'\n'/ | }"
fi

out="$(run_report 0.16.9 0.16.10)"
if [[ "$out" == *"5dive upgraded: 0.16.9 -> 0.16.10"* && "$out" != *"DOWNGRADED"* ]]; then
  ok_t "report uses version sort (0.16.9 -> 0.16.10 is forward)"
else
  bad_t "report lexically mis-sorted a forward patch move" "out: ${out//$'\n'/ | }"
fi

# --- wiring -----------------------------------------------------------------
# The guard is worthless where it cannot stop the swap. Assert it is called in
# refresh_managed_files AFTER the integrity check and BEFORE the atomic mv, and
# that a refusal removes the temp bundle instead of leaving debris in BIN_DIR.
call_ln="$(grep -n 'assert_version_monotonic "\$BIN_DIR/5dive" "\$_bundle_tmp"' install.sh | head -1 | cut -d: -f1)"
mv_ln="$(grep -n 'mv -f "\$_bundle_tmp" "\$BIN_DIR/5dive"' install.sh | head -1 | cut -d: -f1)"
sum_ln="$(grep -n 'sha256sum "\$_bundle_tmp"' install.sh | head -1 | cut -d: -f1)"
if [[ -n "$call_ln" && -n "$mv_ln" && -n "$sum_ln" ]] && (( sum_ln < call_ln && call_ln < mv_ln )); then
  ok_t "guard runs after the checksum and before the swap (lines $sum_ln < $call_ln < $mv_ln)"
else
  bad_t "guard is not wired between the checksum and the swap" "checksum=$sum_ln guard=${call_ln:-none} mv=${mv_ln:-none}"
fi
if sed -n "${call_ln:-1},$((${call_ln:-1} + 4))p" install.sh | grep -q 'rm -f "\$_bundle_tmp"'; then
  ok_t "a refusal removes the temp bundle from BIN_DIR"
else
  bad_t "refusal leaves the temp bundle behind" "no 'rm -f \$_bundle_tmp' within 4 lines of the guard call"
fi

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
