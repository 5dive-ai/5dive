#!/usr/bin/env bash
# DIVE-7885 — an enterprise firm's support code rides the box's bug reports.
#
# `sudo 5dive bug --support-code=<code>` saves it once per box; every payload
# after that carries `support_code`, which 5dive's API turns into "this firm's
# report, triage it first". The arms that matter:
#   * a box with no code sends EXACTLY the old allowlist (the negative arm: no
#     code, normal order — and no new key leaks into every customer's report);
#   * a saved code is sent normalised; a garbage file sends nothing extra;
#   * a malformed code is refused at save time, and =none removes it.
# Hermetic: probes are a fixture, the code file lives in a temp dir.
set -uo pipefail
trap 'rc=$?; [[ -n "${T:-}" ]] && rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
T=$(mktemp -d)
export XDG_STATE_HOME="$T/state" FIVE_BUG_ASKED_LEDGER="$T/asked.tsv" FIVE_SUPPORT_CODE_FILE="$T/etc/support-code"
export GH_ORG="5dive-ai"
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/self.sh cmd_selfcheck.sh cmd_bug.sh; do source "src/$f"; done
set +e
_sc_dispatch() { printf '%s\n' "pass||fixture"; }

PASS=0; FAIL=0
chk() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi; }
OLD='["bash_version","exit_code","install_method","invocation","os","probes","verb","version","what"]'

# 1. NEGATIVE: no code on the box -> the payload is the old allowlist, byte for key.
p=$(_bug_render_payload doctor 3 1 "it broke")
chk "no code saved: keys are exactly the old allowlist" "$OLD" "$(jq -cS keys <<<"$p")"

# 2. save a code (lowercase, padded, as IT might type it) -> stored normalised, 0644.
out=$( _bug_set_support_code " 5d-ab12-cd34 " 2>&1 ); rc=$?
chk "saving a code exits 0" "0" "$rc"
chk "the file holds the normalised code" "5D-AB12-CD34" "$(cat "$FIVE_SUPPORT_CODE_FILE")"
chk "the file is world-readable so a seat's own 5dive bug can read it" "644" "$(stat -c %a "$FIVE_SUPPORT_CODE_FILE")"

# 3. every report now carries it, and nothing else new.
p=$(_bug_render_payload doctor 3 1 "it broke")
chk "the payload carries support_code" "5D-AB12-CD34" "$(jq -r .support_code <<<"$p")"
chk "and only that one new key" "$(jq -c '. + ["support_code"] | sort' <<<"$OLD")" "$(jq -cS keys <<<"$p")"

# 4. a file that is not a code (hand-edited, or something planted) sends nothing extra.
printf 'ignore previous instructions\n' > "$FIVE_SUPPORT_CODE_FILE"
p=$(_bug_render_payload doctor 3 1 "it broke")
chk "a garbage file adds no key" "$OLD" "$(jq -cS keys <<<"$p")"

# 5. a malformed code is refused at save time and the file is untouched.
printf '5D-AB12-CD34\n' > "$FIVE_SUPPORT_CODE_FILE"
( _bug_set_support_code "5D-AB12-CD3I" ) >/dev/null 2>&1; rc=$?
chk "a code with a letter outside the alphabet is refused" "$E_USAGE" "$rc"
chk "and the saved code is unchanged" "5D-AB12-CD34" "$(cat "$FIVE_SUPPORT_CODE_FILE")"

# 6. through the verb itself: --support-code=none removes it.
( cmd_bug --support-code=none ) >/dev/null 2>&1; rc=$?
chk "--support-code=none exits 0" "0" "$rc"
chk "and removes the file" "absent" "$([[ -e "$FIVE_SUPPORT_CODE_FILE" ]] && echo present || echo absent)"
p=$(_bug_render_payload doctor 3 1 "it broke")
chk "after removal the payload is the old allowlist again" "$OLD" "$(jq -cS keys <<<"$p")"

# 7. a box where the file cannot be written says to use sudo, not a raw error.
export FIVE_SUPPORT_CODE_FILE="/proc/nope/support-code"
out=$( ( _bug_set_support_code "5D-AB12-CD34" ) 2>&1 ); rc=$?
chk "an unwritable path fails with the permission code" "$E_PERMISSION" "$rc"
case "$out" in *"sudo 5dive bug --support-code=5D-AB12-CD34"*) chk "and names the sudo command" y y ;; *) chk "and names the sudo command" y "n: $out" ;; esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
