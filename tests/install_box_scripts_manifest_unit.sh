#!/usr/bin/env bash
# DIVE-4194: ONE list of box-side scripts, read by both writers.
#
# WHY THIS EXISTS. install.sh installed three helper scripts into /usr/local/bin
# from three hand-written curl/chmod blocks, and it was their ONLY writer. The
# control plane's nightly pass (5dive-api scripts/control-plane/5dive-host-updates.sh)
# replaced two files from the release tag and then EXECUTED those helpers without
# replacing them — so a merged one-line fix to a helper reached ZERO existing
# boxes. Measured on DIVE-4130: a DEFAULT_SKILLS change merged at 00:44Z and the
# control plane was still running its 2026-09-09 install-day copy.
#
# The fix is host-scripts.manifest: install.sh enumerates from it, and the
# nightly fetches the SAME FILE out of the tag. This harness guards the half
# that lives in this repo, and specifically the failure that re-opens the gap:
# a new box-side script added to install.sh alone. That addition is green under
# every other test in this corpus — it installs correctly, on every fresh box,
# and is never updated again.
#
# Hermetic: the block is extracted verbatim from install.sh and driven against a
# stubbed `curl`. No network, no root, no box.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

MANIFEST=host-scripts.manifest
[[ -f $MANIFEST ]] || { bad_t "$MANIFEST exists" "not found"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

names=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$MANIFEST" \
        | grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' || true)
[[ -n "$names" ]] && ok_t "the manifest names at least one box-side script" \
                  || bad_t "the manifest names at least one box-side script" "parsed empty"

echo "# every name in the manifest is a file this repo actually ships"
while IFS= read -r n; do
  [[ -n "$n" ]] || continue
  [[ -f "$n" ]] && ok_t "ships $n" || bad_t "ships $n" "$MANIFEST names it, the repo root does not have it"
done <<< "$names"

echo "# THE GUARD: no literal *.sh is written into \$BIN_DIR outside the manifest"
# The exact shape of the defect: someone adds `curl … -o "$BIN_DIR/5dive-new-thing.sh"`
# beside its caller, the installer is correct, and the fleet never updates that
# file again. Variables ($_hs_name from the manifest loop, $bin from the buzz
# staging loop) are the enumerated paths and are allowed; a LITERAL name is not.
literals=$(grep -oE '\$\{?BIN_DIR\}?/[A-Za-z0-9][A-Za-z0-9._-]*\.sh' install.sh \
           | sed -E 's#.*/##' | sort -u)
if [[ -z "$literals" ]]; then
  ok_t "no hardcoded box-side script path in install.sh"
else
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    if grep -qxF -- "$l" <<< "$names"; then
      ok_t "literal \$BIN_DIR/$l is named by the manifest"
    else
      bad_t "literal \$BIN_DIR/$l is NOT in $MANIFEST" \
            "install.sh would ship it to new boxes and the nightly would never update it (DIVE-4194)"
    fi
  done <<< "$literals"
fi

echo "# the shipped block installs every manifest name, 0755, from \$REPO"
run_block() {  # MANIFEST_TEXT -> populates $BIN_DIR, prints the block's output
  local manifest_text=$1
  BIN_DIR=$(mktemp -d)
  REPO=stub
  # shellcheck disable=SC2317
  curl() {
    local out="" url=""
    while [[ $# -gt 0 ]]; do case "$1" in -o) out=$2; shift 2;; -*) shift;; *) url=$1; shift;; esac; done
    local f=${url#stub/}
    if [[ "$f" == host-scripts.manifest ]]; then
      [[ "$manifest_text" == __FETCH_FAILS__ ]] && return 1
      if [[ -n "$out" ]]; then printf '%s\n' "$manifest_text" > "$out"; else printf '%s\n' "$manifest_text"; fi
      return 0
    fi
    [[ -f "$ROOT/$f" ]] || return 1
    if [[ -n "$out" ]]; then cat "$ROOT/$f" > "$out"; else cat "$ROOT/$f"; fi
  }
  ok() { echo "  ok $*"; }
  # `local` is legal only in a function, so wrap the shipped bytes in one.
  eval "_dive4194_block() {
$(sed -n '/# >>> DIVE-4194 box-side scripts/,/# <<< DIVE-4194 box-side scripts/p' install.sh)
}"
  declare -F _dive4194_block >/dev/null || { echo "EXTRACT-FAILED"; return 2; }
  _dive4194_block
}

# NOT a command substitution: run_block sets $BIN_DIR, and a subshell would
# take the directory this file then inspects with it.
LOG=$(mktemp)
run_block "$names" > "$LOG" 2>&1; rc=$?; OUT=$(cat "$LOG")
check_installed() {
  local n missing=""
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ -f "$BIN_DIR/$n" ]] || missing="$missing $n"
    [[ "$(stat -c '%a' "$BIN_DIR/$n" 2>/dev/null)" == 755 ]] || missing="$missing $n(mode)"
  done <<< "$1"
  printf '%s' "$missing"
}
[[ $rc -eq 0 ]] && ok_t "the block runs clean" || bad_t "the block runs clean" "rc=$rc: $OUT"
miss=$(check_installed "$names")
[[ -z "$miss" ]] && ok_t "every manifest name landed 0755" || bad_t "every manifest name landed 0755" "missing/wrong-mode:$miss"

echo "# a poisoned manifest entry is REJECTED, not sanitised"
run_block $'5dive-refresh-skills.sh\n../../etc/cron.d/evil\n/usr/local/bin/abs\n.hidden\ntwo words' > "$LOG" 2>&1; OUT=$(cat "$LOG")
[[ -f "$BIN_DIR/5dive-refresh-skills.sh" ]] && ok_t "the good entry still installs" || bad_t "the good entry still installs" "$OUT"
bad_paths=$(find "$BIN_DIR" -mindepth 1 ! -name '5dive-refresh-skills.sh' | tr '\n' ' ')
[[ -z "$bad_paths" ]] && ok_t "nothing else was written" || bad_t "nothing else was written" "also wrote: $bad_paths"
[[ ! -e /etc/cron.d/evil ]] && ok_t "no traversal outside \$BIN_DIR" || bad_t "no traversal outside \$BIN_DIR" "wrote /etc/cron.d/evil"

echo "# a pin that predates the manifest falls back AND says so"
run_block __FETCH_FAILS__ > "$LOG" 2>&1; OUT=$(cat "$LOG")
miss=$(check_installed $'5dive-refresh-plugins.sh\n5dive-stage-fork-plugins.sh\n5dive-refresh-skills.sh')
[[ -z "$miss" ]] && ok_t "the pre-DIVE-4194 set still installs" || bad_t "the pre-DIVE-4194 set still installs" "missing:$miss"
[[ "$OUT" == *"falling back"* ]] && ok_t "the fallback is announced, not silent" || bad_t "the fallback is announced" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
