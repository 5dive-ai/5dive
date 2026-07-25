#!/usr/bin/env bash
# DIVE-2003 — HERMETIC format contract for _hb_repo_grep_ident (cmd_heartbeat.sh).
#
# Why this file exists, and why it is separate from heartbeat_gate_shipped_unit.sh:
# that harness STUBS _hb_repo_grep_ident, so the production format string
# '%h %ct %s' is exercised by NO test at all. The sweep then reads the commit epoch
# with `awk '{print $3}'`, which is only correct because the function PREPENDS the
# repo stem — a two-function contract with nothing asserting it. olivia measured the
# consequence on DIVE-2001: reverting only the stub to a no-epoch format produces
# 8/2, BYTE-IDENTICAL to the signature of deleting the guard condition outright.
# Two different defects, one signature, so the stubbed suite cannot tell them apart.
#
# This test calls the REAL function against a throwaway git repo it creates itself.
# Hermetic: no network, no configured repo, nothing outside its own tmpdir.
# Run: bash tests/heartbeat_gate_shipped_contract_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/hb-gate-contract.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/tasks_db.sh cmd_heartbeat.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e   # after sourcing: header.sh sets -e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- a throwaway repo, committed at a known epoch -----------------------------
REPO_STEM=contract-repo
mkdir -p "$TMP/$REPO_STEM"
git -C "$TMP/$REPO_STEM" init -q -b main 2>/dev/null || git -C "$TMP/$REPO_STEM" init -q
: >"$TMP/$REPO_STEM/f"
git -C "$TMP/$REPO_STEM" add f
GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000042 +0000" \
  git -C "$TMP/$REPO_STEM" -c user.name=t -c user.email=t@t commit -qm "fix: DIVE-4242 landed"

_HB_REPO_BASE="$TMP"
_HB_GATE_SHIPPED_REF="$(git -C "$TMP/$REPO_STEM" rev-parse --abbrev-ref HEAD)"

out=$(_hb_repo_grep_ident "$REPO_STEM" DIVE-4242); rc=$?

# 1. the function answers at all
[[ $rc -eq 0 && -n "$out" ]] \
  && ok_t "real _hb_repo_grep_ident finds a matching commit in a throwaway repo" \
  || bad_t "no hit from the real lookup" "rc=$rc out='$out'"

# 2. THE CONTRACT: field 1 = repo stem, field 3 = numeric committer epoch.
#    This is what `awk '{print $3}'` in the sweep depends on, end to end.
f1=$(awk '{print $1}' <<<"$out"); f3=$(awk '{print $3}' <<<"$out")
[[ "$f1" == "$REPO_STEM" ]] \
  && ok_t "field 1 is the repo stem (the prepend the sweep's field offset relies on)" \
  || bad_t "field 1 not the repo stem" "got '$f1' from '$out'"
[[ "$f3" =~ ^[0-9]+$ ]] \
  && ok_t "field 3 is a NUMERIC epoch — the format the pre-ask guard parses" \
  || bad_t "field 3 not numeric" "got '$f3' from '$out' — the DIVE-2001 guard silently fails open on this"

# 3. it is %ct (committer), NOT %at (author). With %at, an old-authored commit
#    merged after the ask would be wrongly skipped — another silence. The two dates
#    differ by 42s in this fixture precisely so the wrong one cannot pass.
[[ "$f3" == "1700000042" ]] \
  && ok_t "field 3 is the COMMITTER date (%ct), not the author date (%at)" \
  || bad_t "field 3 is not %ct" "got '$f3', author=1700000000 committer=1700000042"

# 4. the digit-boundary grep still holds on a real repo: DIVE-424 must NOT match
#    a commit mentioning DIVE-4242.
out2=$(_hb_repo_grep_ident "$REPO_STEM" DIVE-424); rc2=$?
[[ $rc2 -ne 0 || -z "$out2" ]] \
  && ok_t "digit-boundary holds on real history: DIVE-424 does not match DIVE-4242" \
  || bad_t "prefix ident matched" "out2='$out2'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
