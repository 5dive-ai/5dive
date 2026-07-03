#!/usr/bin/env bash
# DIVE-916 isolated unit harness for the per-gate HUMAN nonce that closes the
# sudo->--human gate-forge, folded into the DIVE-931 secret-drop chain:
#   * `task need --type=approval|secret|manual` mints human_nonce_hash (hash-only
#     at rest); decision does NOT (agent-clearable).
#   * the RAW nonce reaches task_need_notify (embedded in the tap callback_data)
#     and hashes back to the stored value.
#   * `task answer` clears an approval/secret/manual gate under enforcement iff
#     ONE of three EQUIVALENT evidence forms is present: (a) --human-proof=<nonce>,
#     (b) a valid DIVE-519 --proof, (c) a non-agent SUDO_UID — and the forge
#     (agent `sudo task answer --human`, no evidence) is REJECTED.
# Isolation matches the other harnesses: source src/ libs, throwaway STATE_DIR —
# the live shared tasks.db is NEVER touched. Run: bash tests/gate_nonce_unit.sh
# (no root, no network).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/gate-nonce-unit.XXXXXX)"
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

# Capture the raw nonce task need hands the notifier (arg 8), instead of DMing.
NOTIFY_NONCE=""
task_need_notify() { NOTIFY_NONCE="${8:-}"; }

# audit_log needs no root-owned log here; make it a no-op so answers don't warn.
audit_log() { :; }

# Stub the immediate-caller identity (the DIVE-394 `id -un` block). The evidence
# tests model a POST-sudo / dashboard context where the immediate caller is a
# non-agent (root/claude); `_gate_sudo_uid_nonagent` still reads the REAL
# SUDO_UID we set per-case. `command id` is used for actual uid lookups.
FAKE_CALLER="root"
id() { if [[ "${1:-}" == -un ]]; then echo "$FAKE_CALLER"; else command id "$@"; fi; }

seed_task() { db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$1','t','todo','main');"; }
hashof() { printf '%s' "$1" | openssl dgst -sha256 | awk '{print $NF}'; }

# Resolve a REAL agent-* uid explicitly. The evidence tests need a SUDO_UID that
# `_gate_sudo_uid_nonagent` classifies as an agent (i.e. NOT human evidence); do
# NOT source it from the caller (`command id -u`). Running the suite the standard
# way (`sudo -u claude ...`) would make the caller a non-agent uid and flip
# T3-wrong / T6-FORGE / T9 into FALSE failures. Prefer this box's agent-dev, else
# the first agent-* user in passwd.
AGENT_UID="$(getent passwd agent-dev 2>/dev/null | cut -d: -f3)"
[[ -n "$AGENT_UID" ]] || AGENT_UID="$(getent passwd 2>/dev/null | awk -F: '$1 ~ /^agent-/{print $3; exit}')"
if [[ -z "$AGENT_UID" ]]; then
  echo "gate_nonce_unit: SKIP — no agent-* user on this host to source a real agent uid"
  exit 0
fi

# --- T1: approval/secret/manual gates mint a 64-hex human_nonce_hash ----------
_t1n=100
for ty in approval secret manual; do
  _t1n=$((_t1n+1)); ident="DIVE-$_t1n"
  seed_task "$ident"
  NOTIFY_NONCE=""
  cmd_task_need "$ident" --type="$ty" --ask="need it" >/dev/null 2>&1
  h=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$ident';")
  if [[ "$h" =~ ^[0-9a-f]{64}$ ]]; then ok_t "T1 $ty gate mints human_nonce_hash"
  else bad_t "T1 $ty gate mints human_nonce_hash" "got: '$h'"; fi
  # raw nonce handed to notify hashes to the stored value
  if [[ -n "$NOTIFY_NONCE" && "$(hashof "$NOTIFY_NONCE")" == "$h" ]]; then
    ok_t "T1 $ty raw nonce -> notify hashes to stored"
  else bad_t "T1 $ty raw nonce -> notify hashes to stored" "nonce='$NOTIFY_NONCE' h='$h'"; fi
done

# --- T2: decision gate mints NO nonce (agent-clearable) -----------------------
seed_task DIVE-200
NOTIFY_NONCE="sentinel"
cmd_task_need DIVE-200 --type=decision --ask="pick" --options="A|B" --recommend="A" >/dev/null 2>&1
h=$(db "SELECT COALESCE(human_nonce_hash,'null') FROM tasks WHERE ident='DIVE-200';")
[[ "$h" == "null" || -z "$h" ]] && ok_t "T2 decision gate mints no nonce" \
  || bad_t "T2 decision gate mints no nonce" "got: '$h'"
[[ -z "$NOTIFY_NONCE" ]] && ok_t "T2 decision passes empty nonce to notify" \
  || bad_t "T2 decision passes empty nonce to notify" "got: '$NOTIFY_NONCE'"

# Helper: seed an approval gate with a KNOWN nonce hash so we can present it.
seed_gate_known() {
  local ident="$1" nonce="$2"
  seed_task "$ident"
  cmd_task_need "$ident" --type=approval --ask="approve?" >/dev/null 2>&1
  db "UPDATE tasks SET human_nonce_hash=$(sqlq "$(hashof "$nonce")") WHERE ident='$ident';"
}
answered() { db "SELECT CASE WHEN need_answered_at IS NULL THEN 'open' ELSE 'closed' END FROM tasks WHERE ident='$1';"; }

touch "$GATE_PROOF_ENFORCE"   # enforcement ON for T3-T8

# --- T3: (a) valid --human-proof nonce clears; wrong nonce rejected -----------
seed_gate_known DIVE-301 KNOWNNONCE123
SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-301 --value=approved --human --human-proof=KNOWNNONCE123 >/dev/null 2>&1
[[ "$(answered DIVE-301)" == "closed" ]] && ok_t "T3 valid --human-proof clears (SUDO_UID=agent)" \
  || bad_t "T3 valid --human-proof clears" "still $(answered DIVE-301)"

seed_gate_known DIVE-302 KNOWNNONCE123
out=$(SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-302 --value=approved --human --human-proof=WRONG 2>&1); rc=$?
[[ "$(answered DIVE-302)" == "open" && $rc -ne 0 ]] && ok_t "T3 wrong --human-proof rejected" \
  || bad_t "T3 wrong --human-proof rejected" "rc=$rc state=$(answered DIVE-302)"

# --- T4: (b) valid DIVE-519 --proof clears ------------------------------------
_gate_proof_ensure_key 2>/dev/null; ( umask 077; openssl rand -hex 32 > "$GATE_PROOF_KEY" )
seed_task DIVE-400; cmd_task_need DIVE-400 --type=approval --ask="approve?" >/dev/null 2>&1
nid=$(db "SELECT id FROM tasks WHERE ident='DIVE-400';")
tok=$(_gate_proof_mint "$nid" approval)
SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-400 --value=approved --human --proof="$tok" >/dev/null 2>&1
[[ "$(answered DIVE-400)" == "closed" ]] && ok_t "T4 valid DIVE-519 --proof clears" \
  || bad_t "T4 valid DIVE-519 --proof clears" "still $(answered DIVE-400)"

# --- T5: (c) non-agent SUDO_UID clears with NO proof (drop / human-on-box) ----
seed_task DIVE-500; cmd_task_need DIVE-500 --type=secret --ask="drop key" >/dev/null 2>&1
SUDO_UID=0 cmd_task_answer DIVE-500 --human --from=drop >/dev/null 2>&1
[[ "$(answered DIVE-500)" == "closed" ]] && ok_t "T5 non-agent SUDO_UID (root) clears, no proof (drop path)" \
  || bad_t "T5 non-agent SUDO_UID clears" "still $(answered DIVE-500)"

# --- T6: THE FORGE — agent sudo->root, SUDO_UID=agent, bare --human: REJECTED -
# id -un=root (post-sudo, passes the DIVE-394 block) but SUDO_UID=agent uid and
# no nonce/proof -> no evidence -> rejected under enforcement.
seed_task DIVE-600; cmd_task_need DIVE-600 --type=approval --ask="approve?" >/dev/null 2>&1
out=$(SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-600 --value=approved --human 2>&1); rc=$?
[[ "$(answered DIVE-600)" == "open" && $rc -ne 0 ]] && ok_t "T6 FORGE rejected (agent SUDO_UID, bare --human, enforce on)" \
  || bad_t "T6 FORGE rejected" "rc=$rc state=$(answered DIVE-600) out=$out"

# --- T7: same inputs, enforcement OFF -> audit-only, clears (dormant ship) ----
rm -f "$GATE_PROOF_ENFORCE"
seed_task DIVE-700; cmd_task_need DIVE-700 --type=approval --ask="approve?" >/dev/null 2>&1
SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-700 --value=approved --human >/dev/null 2>&1
[[ "$(answered DIVE-700)" == "closed" ]] && ok_t "T7 enforce OFF -> dormant, clears (audit-only)" \
  || bad_t "T7 enforce OFF clears" "still $(answered DIVE-700)"
touch "$GATE_PROOF_ENFORCE"

# --- T8: agent immediate-caller (pre-sudo) blocked by the DIVE-394 id-un guard -
FAKE_CALLER="agent-evil"
seed_task DIVE-800; cmd_task_need DIVE-800 --type=manual --ask="do it" >/dev/null 2>&1
out=$(cmd_task_answer DIVE-800 --value=done --human 2>&1); rc=$?
[[ "$(answered DIVE-800)" == "open" && $rc -ne 0 && "$out" == *"only a human"* ]] \
  && ok_t "T8 agent-* immediate caller blocked on manual gate (defense-in-depth)" \
  || bad_t "T8 agent-* caller blocked on manual" "rc=$rc state=$(answered DIVE-800) out=$out"
FAKE_CALLER="root"

# --- T9: _gate_sudo_uid_nonagent direct logic --------------------------------
SUDO_UID=0 _gate_sudo_uid_nonagent && ok_t "T9 SUDO_UID=root -> non-agent" || bad_t "T9 root non-agent" ""
SUDO_UID="$AGENT_UID" _gate_sudo_uid_nonagent && bad_t "T9 agent uid -> should be agent" "" || ok_t "T9 agent SUDO_UID -> agent (not evidence)"

echo "-----"
printf 'gate_nonce_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
