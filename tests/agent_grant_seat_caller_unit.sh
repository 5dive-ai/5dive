#!/usr/bin/env bash
# DIVE-7982 unit harness: an agent seat must not be able to grant itself (or any
# seat) admin or root through `sudo 5dive agent grant`.
#
# The defect: `require_root` passes at EUID 0, and `sudo 5dive …` IS EUID 0, so
# an admin seat (`NOPASSWD: /usr/local/bin/5dive *`) could run
# `sudo 5dive agent grant <itself> root`. cmd_agent_grant never asked who called.
#
# Drives cmd_agent_grant end to end with the writers stubbed to a log, so
# "refused" is graded as "refused AND nothing written", not only an exit code.
# The caller is modelled through lib/actor.sh's documented seams (_gate_is_root,
# _gate_caller_uid, _gate_passwd_stream) plus SUDO_UID, the value sudo writes.
#
# "Same output as today" is graded against the MUTANT: this tree's
# cmd_agent_create.sh with the one guard line removed IS today's behaviour, so the
# allowed arms must print exactly what it prints. The mutant's seat arm must go
# NOT refused, which proves the refusal arms grade the guard line.
#
# Run: bash tests/agent_grant_seat_caller_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 2
SRC=src

TMP="$(mktemp -d /tmp/agent-grant-seat-caller.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
p_ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && p_ok "$1" || bad "$1" "$3" "$2"; }

export SUDOERS_D="$TMP/sudoers.d"
mkdir -p "$SUDOERS_D"
WRITES="$TMP/writes"

GUARD_LINE='refusal=$(_agent_grant_caller_refusal "$cap" "$name") || fail "$E_PERMISSION" "$refusal"'
is "the guard line is present exactly once in the source" \
   "$(grep -cF "$GUARD_LINE" "$SRC/cmd_agent_create.sh")" "1"
grep -vF "$GUARD_LINE" "$SRC/cmd_agent_create.sh" > "$TMP/mutant.sh"

# Seats: adm (admin), low (standard), boss (managed root-all drop-in).
printf '%s\n%s\n' '# Managed by 5dive (DIVE-1002/1088). Fleet-management scope for admin agent agent-adm.' \
  'agent-adm ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *' > "$SUDOERS_D/agent-adm"
printf '%s\n' 'agent-boss ALL=(ALL) NOPASSWD: ALL' > "$SUDOERS_D/agent-boss"

# Everything cmd_agent_grant reaches that touches the box is stubbed AFTER the
# source, because the source defines the real writers.
stubs() {
  require_root() { return 0; }
  _gate_is_root() { [[ "${FAKE_EUID}" == 0 ]]; }
  _gate_caller_uid() { printf '%s' "$FAKE_EUID"; }
  _gate_passwd_stream() {
    printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'claude:x:1000:1000::/home/claude:/bin/bash' \
      'agent-adm:x:1101:1101::/home/agent-adm:/bin/bash' 'agent-low:x:1102:1102::/home/agent-low:/bin/bash' \
      'agent-boss:x:1103:1103::/home/agent-boss:/bin/bash'
  }
  registry_read() { printf '%s' '{"agents":{"adm":{"isolation":"admin"},"low":{"isolation":"standard"},"boss":{"isolation":"beyond-admin"}}}'; }
  write_root_sudoers()     { echo "root $1" >> "$WRITES"; }
  write_admin_sudoers()    { echo "admin $1" >> "$WRITES"; }
  write_standard_sudoers() { echo "standard $*" >> "$WRITES"; }
  _agent_stamp_isolation() { echo "label $1 $2" >> "$WRITES"; }
  secrets_member_sync()    { return 0; }
}

# run <source> <euid> <sudo_uid|-> <name> <cap>  -> sets RC, OUT, WROTE
run() {
  local src="$1" euid="$2" suid="$3"; shift 3
  : > "$WRITES"
  OUT=$( (
    # shellcheck source=/dev/null
    source "$src"; stubs; set +e
    FAKE_EUID="$euid"
    if [[ "$suid" == - ]]; then unset SUDO_UID; else export SUDO_UID="$suid"; fi
    unset SUDO_USER
    cmd_agent_grant "$@"
  ) 2>&1 )
  RC=$?
  WROTE=$(wc -l < "$WRITES" | tr -d ' ')
}

echo "1. a seat caller (sudo from agent-adm) is refused admin and root, and nothing is written"
run "$SRC/cmd_agent_create.sh" 0 1101 adm root
is "agent-adm grant adm root  -> E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$WROTE" "0"
is "  the refusal names the agent" "$(grep -c "came from the agent 'adm'" <<<"$OUT")" "1"
run "$SRC/cmd_agent_create.sh" 0 1101 low root
is "agent-adm grant low root  -> E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$WROTE" "0"
run "$SRC/cmd_agent_create.sh" 0 1101 low admin
is "agent-adm grant low admin -> E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$WROTE" "0"
run "$SRC/cmd_agent_create.sh" 0 1101 adm admin
is "agent-adm grant adm admin -> E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$WROTE" "0"
# A seat's own uid as EUID (no sudo) never reaches here in production
# (require_root), but the identity read must still name it.
run "$SRC/cmd_agent_create.sh" 1102 - low root
is "agent-low as its own uid, grant low root -> E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$WROTE" "0"

echo "2. a seat taking ITSELF down to standard is allowed (a downgrade)"
run "$SRC/cmd_agent_create.sh" 0 1101 adm standard
is "agent-adm grant adm standard -> 0" "$RC" "0"
is "  the standard policy and label are written" "$(cat "$WRITES")" $'standard agent-adm 0 0\nlabel adm standard'

echo "3. the owner and root keep working, with today's output"
for c in "0 - low root" "0 1000 low root" "0 - low admin" "0 1000 adm root"; do
  # shellcheck disable=SC2086
  set -- $c
  run "$SRC/cmd_agent_create.sh" "$1" "$2" "$3" "$4"; rc_new=$RC; out_new=$OUT; w_new=$(cat "$WRITES")
  run "$TMP/mutant.sh"           "$1" "$2" "$3" "$4"; rc_old=$RC; out_old=$OUT; w_old=$(cat "$WRITES")
  who=$([[ "$2" == - ]] && echo "direct root" || echo "sudo from claude")
  is "$who grant $3 $4 -> 0" "$rc_new" "0"
  is "  same exit, output and writes as today" "$rc_new|$out_new|$w_new" "$rc_old|$out_old|$w_old"
done
run "$SRC/cmd_agent_create.sh" 0 - low root
is "  direct root grant low root really writes the root policy" "$(head -1 "$WRITES")" "root agent-low"

echo "4. a seat that already holds unrestricted root widens nothing, so it is allowed"
run "$SRC/cmd_agent_create.sh" 0 1103 low root
is "agent-boss (ALL) grant low root -> 0" "$RC" "0"
is "  root policy written" "$(head -1 "$WRITES")" "root agent-low"

echo "5. SUDO_USER is not read: a forged value changes nothing"
: > "$WRITES"
OUT=$( ( source "$SRC/cmd_agent_create.sh"; stubs; set +e; FAKE_EUID=0; export SUDO_UID=1101 SUDO_USER=claude
         cmd_agent_grant adm root ) 2>&1 ); RC=$?
is "SUDO_UID=agent-adm, SUDO_USER=claude -> still E_PERMISSION" "$RC" "$E_PERMISSION"
is "  nothing written" "$(wc -l < "$WRITES" | tr -d ' ')" "0"

echo "6. mutant: remove the caller check and the seat arm goes red"
run "$TMP/mutant.sh" 0 1101 adm root
is "mutant: agent-adm grant adm root is NOT refused" "$RC" "0"
is "mutant: and it writes the root policy" "$(head -1 "$WRITES")" "root agent-adm"

echo
echo "agent_grant_seat_caller_unit: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
