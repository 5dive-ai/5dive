#!/usr/bin/env bash
# DIVE-1345 isolated unit harness for the gate-notify observability fix.
#
# DIVE-1344 found the STEP-1 gate-button-reject log was NEVER written for
# agent-filed gates: task_need_notify runs AS the agent (group claude, not root)
# and /var/log/5dive is 2750 (group has no write), so _mirror_log_button_reject
# always hit its stderr fallback and the file was never created. The fix:
#   * audit_init ensures a group-writable subdir <auditdir>/notify at 2770
#     (setgid + group-write, same shape as TASKS_DIR) so agents CAN create it,
#     while the parent /var/log/5dive stays 2750 — the tamper-evident audit log
#     is never exposed to group writes.
#   * _mirror_log_button_reject repoints to <auditdir>/notify/gate-notify.log and
#     creates it with umask 0002 so every group-claude agent can append.
#
# Isolation: source src/ libs into a throwaway AUDIT_LOG tree; no live path, no
# network. chown root:claude fails as non-root and is (correctly) non-fatal — the
# chmods still run because we run under `set +e`. Run: bash tests/gate_notify_log_observable_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-notify-log-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source "$SRC/header.sh"
# shellcheck disable=SC1090
source "$SRC/lib/audit.sh"
set +e   # header.sh set -e; the expected non-root chown failures must not abort

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Point AUDIT_LOG at a throwaway tree; audit_init derives the dir from it.
AUDIT_LOG="$TMP/log/agent-audit.log"
audit_init 2>/dev/null

# 1: audit_init creates the notify subdir.
if [[ -d "$TMP/log/notify" ]]; then ok_t "audit_init creates <auditdir>/notify"
else bad_t "notify subdir not created"; fi

# 2: notify subdir is setgid + group-writable (2770) so agents can create the log.
nmode=$(stat -c '%a' "$TMP/log/notify" 2>/dev/null); nperm=$(stat -c '%A' "$TMP/log/notify" 2>/dev/null)
if [[ "$nmode" == "2770" ]]; then ok_t "notify subdir mode 2770 ($nperm)"
else bad_t "notify subdir mode=$nmode ($nperm) want 2770"; fi

# 3: the parent audit dir stays hardened 2750 (group NOT writable) — audit integrity.
pmode=$(stat -c '%a' "$TMP/log" 2>/dev/null); pperm=$(stat -c '%A' "$TMP/log" 2>/dev/null)
if [[ "$pmode" == "2750" ]]; then ok_t "audit dir stays hardened 2750 ($pperm)"
else bad_t "audit dir mode=$pmode ($pperm) want 2750 — must NOT be group-writable"; fi

# 4: the audit log itself is untouched (640 root, not group-writable).
lmode=$(stat -c '%a' "$AUDIT_LOG" 2>/dev/null)
if [[ "$lmode" == "640" ]]; then ok_t "agent-audit.log stays 640"
else bad_t "agent-audit.log mode=$lmode want 640"; fi

# 5: _mirror_log_button_reject repoints to the notify subdir.
if grep -q 'logf="/var/log/5dive/notify/gate-notify.log"' "$SRC/cmd_agent_runtime.sh"
then ok_t "reject log repointed to notify subdir"
else bad_t "reject log path NOT repointed to notify subdir"; fi

# 6: the reject log is created group-writable (umask 0002) so cross-agent appends work.
if grep -q 'umask 0002' "$SRC/cmd_agent_runtime.sh"
then ok_t "reject log created group-writable (umask 0002)"
else bad_t "umask 0002 guard missing"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
