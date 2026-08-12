#!/usr/bin/env bash
# TIER: core — DIVE-3096's sudo/PAM boundary, no root or network.
#
# env_isolation.sh clears caller FIVE_* values, but sudo opens a PAM session
# after that clearing.  When sudo's pam_env rule reads /etc/environment, a host
# FIVE_* value comes back.  This harness grades the conjunction, not either
# input alone, and carries both green-side controls so "refuse every sudo" cannot
# pass.  It also pins exact argv forwarding on the clean side: inserting `env -u`
# would change the command matched by exact-path sudoers grants.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${tmp:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
LIB="tests/lib/env_isolation.sh"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tmp=$(mktemp -d /tmp/env-iso-sudo.XXXXXX)
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$SUDO_LOG"\n' > "$tmp/bin/sudo"
chmod +x "$tmp/bin/sudo"
printf 'session required pam_env.so readenv=1 user_readenv=0\n' > "$tmp/pam-active"
printf 'session required pam_env.so readenv=1 envfile=/etc/default/locale\n' > "$tmp/pam-other"
printf 'FIVE_TEST_HOST_POLICY=1\n' > "$tmp/environment-dirty"
: > "$tmp/environment-clean"

# Each arm gets a fresh shell because installing the guard deliberately defines
# `sudo` for the remainder of that harness process.
SUDO_LOG="$tmp/clean.log" PATH="$tmp/bin:$PATH" \
  bash -c '. '"$LIB"'; unset -f sudo 2>/dev/null || true; _five_env_sudo_guard_install '"$tmp"'/environment-clean '"$tmp"'/pam-active; sudo -n /usr/local/bin/5dive whoami --json' \
  >/dev/null 2>"$tmp/clean.err"; rc=$?
[[ $rc -eq 0 && "$(cat "$tmp/clean.log")" == '-n /usr/local/bin/5dive whoami --json' ]] \
  && ok_t 'T1 CONTROL: active pam_env plus a CLEAN environment forwards exact sudo argv' \
  || bad_t 'T1 clean side did not reach sudo unchanged' "rc=$rc log=$(cat "$tmp/clean.log" 2>/dev/null) err=$(cat "$tmp/clean.err")"

SUDO_LOG="$tmp/other.log" PATH="$tmp/bin:$PATH" \
  bash -c '. '"$LIB"'; unset -f sudo 2>/dev/null || true; _five_env_sudo_guard_install '"$tmp"'/environment-dirty '"$tmp"'/pam-other; sudo -n true' \
  >/dev/null 2>"$tmp/other.err"; rc=$?
[[ $rc -eq 0 && "$(cat "$tmp/other.log")" == '-n true' ]] \
  && ok_t 'T2 CONTROL: a host knob is not blamed when sudo PAM reads a DIFFERENT file' \
  || bad_t 'T2 inactive predicate was refused' "rc=$rc log=$(cat "$tmp/other.log" 2>/dev/null) err=$(cat "$tmp/other.err")"

SUDO_LOG="$tmp/dirty.log" PATH="$tmp/bin:$PATH" \
  bash -c '. '"$LIB"'; unset -f sudo 2>/dev/null || true; _five_env_sudo_guard_install '"$tmp"'/environment-dirty '"$tmp"'/pam-active; sudo -n true' \
  >/dev/null 2>"$tmp/dirty.err"; rc=$?
[[ $rc -eq 125 && ! -s "$tmp/dirty.log" ]] \
  && ok_t 'T3 ARM: pam_env plus a host FIVE_* knob refuses before privileged code runs' \
  || bad_t 'T3 sudo boundary stayed reachable' "rc=$rc log=$(cat "$tmp/dirty.log" 2>/dev/null) err=$(cat "$tmp/dirty.err")"
err=$(cat "$tmp/dirty.err")
[[ "$err" == *'REFUSED sudo'* && "$err" == *'FIVE_TEST_HOST_POLICY'* \
   && "$err" == *'after this harness cleared FIVE_'* && "$err" == *'DIVE-3092'* ]] \
  && ok_t 'T4 refusal names the restored knob, the boundary, and the no-sweep decision' \
  || bad_t 'T4 refusal does not explain the actual predicate' "err=$err"

grep -qx '_five_env_sudo_guard_install' "$LIB" \
  && ok_t 'T5 SEAM: sourcing env_isolation installs the sudo boundary guard' \
  || bad_t 'T5 guard helper exists but is not installed at the shared seam'

# A shell function cannot intercept an explicitly bypassed lookup. The shared
# seam covers the current sudo corpus because no harness uses command sudo,
# env sudo, or an absolute sudo path; pin that condition rather than assuming it.
bypass=$(grep -RInE --include='*.sh' \
  '(^|[;&|()][[:space:]]*)(command[[:space:]]+sudo|/usr(/local)?/bin/sudo|/bin/sudo|env([[:space:]]+-[^[:space:]]+)*[[:space:]]+sudo)([[:space:]]|$)' \
  tests 2>/dev/null || true)
[[ -z "$bypass" ]] \
  && ok_t 'T6 SCOPE: no harness bypasses function-resolved sudo' \
  || bad_t 'T6 a sudo caller bypasses the shared isolation guard' "$bypass"

echo '-----'
printf 'env_isolation_sudo_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
