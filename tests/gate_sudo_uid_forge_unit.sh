#!/usr/bin/env bash
# DIVE-1413 — EUID-gate the task-answer SUDO_UID human-evidence form.
#
# THREAT (same env-forge class as the DIVE-1401 withdraw path, 547a219): $SUDO_UID
# is a PLAIN ENV VAR any non-root process sets freely. Before this fix
# `_gate_sudo_uid_nonagent` read it UNCONDITIONALLY, so a non-root agent could run
#   SUDO_UID=<claude uid> 5dive task answer <gate> --human
# and mint 'human' evidence (_su=1) that clears an approval/secret/manual gate
# under enforcement — no real human involved.
#
# FIX: trust $SUDO_UID only at EUID 0 (real `sudo` stamps it truthfully AND an
# agent cannot reach root without genuinely sudo-ing). Off root, IGNORE $SUDO_UID
# and judge by the UNSPOOFABLE real uid — which is precisely what the two legit
# non-root human paths carry (the dashboard/shelld exec runs AS claude, so
# `id -u` is already non-agent). The DIVE-931 secret-drop is a ROOT path (secret
# write is require_root, so its nested task-answer runs at EUID 0 with the human's
# SUDO_UID=claude) and clears via the EUID-0 branch.
#
# LESSON FROM DIVE-1401 (why the branch-stubbing suites went falsely green twice):
# a test that stubs the trust primitive proves the branch, not the resolver. This
# suite drives the REAL `_gate_sudo_uid_nonagent` with FORGED env, seaming ONLY
# the two things that cannot be reassigned in-process: `_gate_is_root` (EUID is
# read-only) and the real uid the helper reads via `id -u` (a non-root process
# genuinely IS its own uid — we can't fork as claude — so we stub `id` the way the
# other gate harnesses already do). T-FORGE asserts the forge is REFUSED end-to-end.
#
# Isolation matches the sibling harnesses: source src/ libs, throwaway STATE_DIR,
# the live shared tasks.db is NEVER touched. Run: bash tests/gate_sudo_uid_forge_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-sudo-forge-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
GATE_PROOF_KEY="$STATE_DIR/gate-proof.key"
GATE_PROOF_ENFORCE="$STATE_DIR/gate-proof.enforce"
JSON_MODE=1
mkdir -p "$TASKS_DIR"; set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
audit_log() { :; }

# Resolve real uids on this box to forge with. Need a non-agent (claude) uid and a
# real agent-* uid; if either is missing we cannot model the threat faithfully.
CLAUDE_UID="$(getent passwd claude 2>/dev/null | cut -d: -f3)"
AGENT_UID="$(getent passwd agent-dev 2>/dev/null | cut -d: -f3)"
[[ -n "$AGENT_UID" ]] || AGENT_UID="$(getent passwd 2>/dev/null | awk -F: '$1 ~ /^agent-/{print $3; exit}')"
AGENT_NAME="$(getent passwd "$AGENT_UID" 2>/dev/null | cut -d: -f1)"
if [[ -z "$CLAUDE_UID" || -z "$AGENT_UID" || -z "$AGENT_NAME" ]]; then
  echo "gate_sudo_uid_forge_unit: SKIP — need both a 'claude' and an 'agent-*' user on this host"
  exit 0
fi

# ── Seams — the ONLY two things a running process cannot honestly vary. ────────
# IS_ROOT drives _gate_is_root (EUID is read-only in-process). REAL_UID / REAL_UN
# are the unspoofable identity the helper reads via `id`; a non-root process
# genuinely IS its own uid, so to model "a real agent process" vs "a real claude
# process" without forking as another user we stub `id` exactly as the other gate
# harnesses do. $SUDO_UID is NOT seamed — it is the forgeable env var under test,
# set per-case with a plain assignment (what a real attacker controls).
IS_ROOT=1; REAL_UID=""; REAL_UN=""
_gate_is_root() { [[ "$IS_ROOT" == 1 ]]; }
id() {
  case "${1:-}" in
    -u)  echo "$REAL_UID" ;;
    -un) echo "$REAL_UN" ;;
    *)   command id "$@" ;;
  esac
}

seed_gate() {   # ident type
  db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"
  cmd_task_need "$1" --type="$2" --ask="need it" >/dev/null 2>&1
}
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }

# ── D1: direct helper logic — the resolver, not just the branch. ──────────────
# Non-root + forged SUDO_UID=<claude> but REAL uid = agent  ->  NOT evidence.
IS_ROOT=0; REAL_UID="$AGENT_UID"; REAL_UN="$AGENT_NAME"
SUDO_UID="$CLAUDE_UID" _gate_sudo_uid_nonagent \
  && bad_t "D1 non-root: forged SUDO_UID=claude is REJECTED (real uid=agent)" "returned true" \
  || ok_t "D1 non-root: forged SUDO_UID=claude is REJECTED (real uid=agent)"

# Non-root, no SUDO_UID at all, real uid = agent  ->  NOT evidence.
IS_ROOT=0; REAL_UID="$AGENT_UID"; REAL_UN="$AGENT_NAME"
( unset SUDO_UID; _gate_sudo_uid_nonagent ) \
  && bad_t "D2 non-root agent (no SUDO_UID) is REJECTED" "returned true" \
  || ok_t "D2 non-root agent (no SUDO_UID) is REJECTED"

# Non-root, real uid = claude (the dashboard/shelld exec runs AS claude): TRUSTED,
# and a forged SUDO_UID=agent must NOT flip a genuine non-agent process to distrust.
IS_ROOT=0; REAL_UID="$CLAUDE_UID"; REAL_UN="claude"
SUDO_UID="$AGENT_UID" _gate_sudo_uid_nonagent \
  && ok_t "D3 non-root real-claude (shelld exec) is TRUSTED, ignores forged SUDO_UID=agent" \
  || bad_t "D3 non-root real-claude is TRUSTED" "returned false"

# EUID 0 + SUDO_UID=<claude>: the real-sudo / DIVE-931-drop path still clears.
IS_ROOT=1; REAL_UID="0"; REAL_UN="root"
SUDO_UID="$CLAUDE_UID" _gate_sudo_uid_nonagent \
  && ok_t "D4 root + SUDO_UID=claude (sudo / DIVE-931 drop) is TRUSTED" \
  || bad_t "D4 root + SUDO_UID=claude is TRUSTED" "returned false"

# EUID 0 + SUDO_UID=<agent>: the residual agent-sudo->root forge is still caught
# at root (unchanged from before — this is the T6 case in gate_nonce_unit).
IS_ROOT=1; REAL_UID="0"; REAL_UN="root"
SUDO_UID="$AGENT_UID" _gate_sudo_uid_nonagent \
  && bad_t "D5 root + SUDO_UID=agent is REJECTED" "returned true" \
  || ok_t "D5 root + SUDO_UID=agent is REJECTED"

# ── E: end-to-end through cmd_task_answer under enforcement. ──────────────────
touch "$GATE_PROOF_ENFORCE"

# T-FORGE: non-root agent forging SUDO_UID=claude, bare --human, no nonce -> REJECTED.
# The immediate-caller (id -un) is the agent itself here, so this also passes
# through the DIVE-394 guard as a genuine agent context (not a stubbed non-agent).
IS_ROOT=0; REAL_UID="$AGENT_UID"; REAL_UN="$AGENT_NAME"
seed_gate DIVE-9601 approval
out=$(SUDO_UID="$CLAUDE_UID" cmd_task_answer DIVE-9601 --value=approved --human 2>&1); rc=$?
[[ "$(answered DIVE-9601)" == "open" && $rc -ne 0 ]] \
  && ok_t "T-FORGE non-root agent forging SUDO_UID=claude is REJECTED end-to-end" \
  || bad_t "T-FORGE forge rejected" "rc=$rc state=$(answered DIVE-9601) out=$out"

# T-DROP: the DIVE-931 drop context (root, SUDO_UID=claude, --from=drop) still clears.
IS_ROOT=1; REAL_UID="0"; REAL_UN="root"
seed_gate DIVE-9602 secret
SUDO_UID="$CLAUDE_UID" cmd_task_answer DIVE-9602 --human --from=drop >/dev/null 2>&1
[[ "$(answered DIVE-9602)" == "closed" ]] \
  && ok_t "T-DROP root secret-drop (SUDO_UID=claude) still clears end-to-end" \
  || bad_t "T-DROP drop clears" "still $(answered DIVE-9602)"

# T-SHELLD: the dashboard/shelld exec (non-root, real uid=claude) still clears.
IS_ROOT=0; REAL_UID="$CLAUDE_UID"; REAL_UN="claude"
seed_gate DIVE-9603 approval
SUDO_UID="" cmd_task_answer DIVE-9603 --value=approved --human >/dev/null 2>&1
[[ "$(answered DIVE-9603)" == "closed" ]] \
  && ok_t "T-SHELLD non-root real-claude (dashboard exec) still clears end-to-end" \
  || bad_t "T-SHELLD shelld clears" "still $(answered DIVE-9603)"

echo "-----"
printf 'gate_sudo_uid_forge_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
