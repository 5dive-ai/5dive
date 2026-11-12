#!/usr/bin/env bash
# DIVE-8292: `5dive agent auth submit <sid> --code=-` reads the Claude callback
# code from stdin. 5dive.app's chat-only sign-in hands the code to the box's
# reporter, and a code in argv is readable in ps and lands in the audit log.
#
# Arms: the code from stdin reaches the login pane exactly; an empty stdin fails
# with "no callback code on stdin" BEFORE the session is looked up (the reporter's
# probe for this form); a bad code read from stdin is refused by the same check
# as --code=<code>; the plain --code=<code> form still works.
#
# Run: bash tests/auth_submit_code_stdin_unit.sh  (no root, no network, no tmux).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

TMP=$(mktemp -d -t auth-submit-stdin.XXXXXX)
AUTH_SESSIONS_DIR="$TMP/auth-sessions"
SID=0123456789abcdef
mkdir -p "$AUTH_SESSIONS_DIR/$SID"
KEYS="$TMP/keys.log"
: >"$KEYS"
# The leaf: `sudo -u claude tmux …` records what it would type into the pane.
sudo() { shift 2; [[ "$1" == tmux ]] || return 1; shift
  case "$*" in
    *has-session*) return 0 ;;
    *send-keys*" -l -- "*) printf '%s\n' "${@: -1}" >>"$KEYS" ;;
  esac
  return 0
}
meta() { printf '{"sessionId":"%s","type":"claude","state":"awaiting_code"}\n' "$SID" >"$AUTH_SESSIONS_DIR/$SID/meta.json"; }

CODE='AbC-12_xyz.QR/9#state-Zz_1'

# 1. The code from stdin reaches the pane, and is in no argv of the call.
meta; : >"$KEYS"
out=$( ( printf '%s\n' "$CODE" | cmd_auth_submit "$SID" --code=- ) 2>&1 ); rc=$?
if (( rc == 0 )) && [[ "$(cat "$KEYS")" == "$CODE" ]] && [[ "$(jq -r .state "$AUTH_SESSIONS_DIR/$SID/meta.json")" == submitted ]]; then
  ok_t "--code=- types the stdin code into the login pane and marks the session submitted"
else bad_t "--code=- did not submit the stdin code" "rc=$rc keys=$(cat "$KEYS") out=$out"; fi

# 1b. No trailing newline (printf '%s') works too.
meta; : >"$KEYS"
( printf '%s' "$CODE" | cmd_auth_submit "$SID" --code=- ) >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$KEYS")" == "$CODE" ]] && ok_t "a code with no newline is read whole" || bad_t "no-newline code" "rc=$rc keys=$(cat "$KEYS")"

# 2. Empty stdin: refused before the session is looked up (a bogus sid gives the same answer).
out=$( ( cmd_auth_submit not-a-session --code=- </dev/null ) 2>&1 ); rc=$?
if (( rc != 0 )) && [[ "$out" == *"no callback code on stdin"* ]] && [[ "$out" != *"invalid session id"* ]]; then
  ok_t "empty stdin fails with 'no callback code on stdin' before any session lookup"
else bad_t "empty stdin" "rc=$rc out=$out"; fi

# 3. A bad code from stdin is refused by the same character check, and never typed.
meta; : >"$KEYS"
out=$( ( printf '%s\n' 'abc; rm -rf /' | cmd_auth_submit "$SID" --code=- ) 2>&1 ); rc=$?
if (( rc != 0 )) && [[ "$out" == *"unexpected characters"* ]] && [[ ! -s "$KEYS" ]]; then
  ok_t "a code with spaces or ; from stdin is refused and never typed"
else bad_t "bad stdin code" "rc=$rc out=$out keys=$(cat "$KEYS")"; fi

# 4. The argv form still works.
meta; : >"$KEYS"
( cmd_auth_submit "$SID" --code="$CODE" ) >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$KEYS")" == "$CODE" ]] && ok_t "--code=<code> still submits" || bad_t "argv form" "rc=$rc keys=$(cat "$KEYS")"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
