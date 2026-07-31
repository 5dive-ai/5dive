#!/usr/bin/env bash
# DIVE-916 isolated unit harness for the per-gate HUMAN nonce that closes the
# sudo->--human gate-forge, folded into the DIVE-931 secret-drop chain:
#   * `task need --type=approval|secret|manual` mints human_nonce_hash (hash-only
#     at rest); a TIER 0/1 decision does NOT (genuinely agent-clearable). Since
#     DIVE-2356 the condition is "hard-human TYPE **or** tier>=2", so a tier-2
#     decision mints too — T2 below pins the tier-1 side of that boundary, and
#     gate_tier2_decision_nonce_unit.sh owns the tier-2 side.
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

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
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
# DIVE-2330: identity no longer comes from `id` — it is $EUID resolved in pure
# bash, precisely so a PATH shim cannot answer. Override the SEAMS instead, the
# same way this file already overrides _gate_is_root.
#
# ITERATION 2 — the previous override was INERT for T8 (dev). It did
# `command id -u "$FAKE_CALLER" || printf 0`, and there is no `agent-evil` user on
# any host, so `id -u` failed and the seam returned 0 = ROOT: the arm that exists
# to prove an AGENT caller is refused was modelling root, and passed or failed for
# reasons unrelated to its name. Same defect as DIVE-2365 — the precondition came
# from the host (which uids happen to exist) instead of from the test.
#
# Now: a LITERAL uid plus a passwd line the resolver can actually map, so this is
# true on every host including GitHub's runner. The fixture is PREPENDED to the
# real /etc/passwd so real uids (AGENT_UID below, the lead-clear paths) still
# resolve — a fixture that REPLACED it would silently break those instead.
FAKE_AGENT_UID=424242
_gate_passwd_stream() {
  printf 'agent-evil:x:%s:%s::/nonexistent:/bin/false\n' "$FAKE_AGENT_UID" "$FAKE_AGENT_UID"
  printf '%s\n' "$(</etc/passwd)"
}
_gate_caller_uid() { if [[ "$FAKE_CALLER" == agent-* ]]; then printf '%s' "$FAKE_AGENT_UID"; else printf 0; fi; }

# Assert the seam pair actually resolves BEFORE any arm depends on it — an
# override that silently yields nothing is how T8 became vacuous in the first
# place, and a vacuous arm prints ok.
_pin_check=$(FAKE_CALLER=agent-evil; _gate_uid_to_agent "$(_gate_caller_uid)")
[[ "$_pin_check" == "evil" ]] || { printf 'NOT OK - seam pin is inert: _gate_uid_to_agent returned %s, expected evil\n' "'$_pin_check'"; exit 1; }
_pin_check=$(FAKE_CALLER=root; _gate_uid_to_agent "$(_gate_caller_uid)")
[[ -z "$_pin_check" ]] || { printf 'NOT OK - seam pin: root caller resolved to %s, expected empty\n' "'$_pin_check'"; exit 1; }

# DIVE-1413: every SUDO_UID-driven case below models a POST-SUDO / root context
# (T5 human-on-box, T6 agent-sudo->root, the drop's require_root nested answer) —
# `_gate_sudo_uid_nonagent` now honors $SUDO_UID ONLY at EUID 0, so seam root here
# (the suite itself runs non-root as claude). The non-root forge — where a plain
# $SUDO_UID must be IGNORED in favor of the real uid — is covered end-to-end by
# tests/gate_sudo_uid_forge_unit.sh.
_gate_is_root() { return 0; }

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
  # DIVE-2411: a secret gate must name a delivery path to file at all. Without
  # this the secret iteration is refused and its two arms grade the refusal.
  _t1extra=(); [[ "$ty" == "secret" ]] && _t1extra=(--secret-key=FIXTURE_TOKEN --connector=fixture)
  cmd_task_need "$ident" --type="$ty" --ask="need it" "${_t1extra[@]+"${_t1extra[@]}"}" >/dev/null 2>&1
  h=$(db "SELECT COALESCE(human_nonce_hash,'') FROM tasks WHERE ident='$ident';")
  if [[ "$h" =~ ^[0-9a-f]{64}$ ]]; then ok_t "T1 $ty gate mints human_nonce_hash"
  else bad_t "T1 $ty gate mints human_nonce_hash" "got: '$h'"; fi
  # raw nonce handed to notify hashes to the stored value
  if [[ -n "$NOTIFY_NONCE" && "$(hashof "$NOTIFY_NONCE")" == "$h" ]]; then
    ok_t "T1 $ty raw nonce -> notify hashes to stored"
  else bad_t "T1 $ty raw nonce -> notify hashes to stored" "nonce='$NOTIFY_NONCE' h='$h'"; fi
done

# --- T2: a TIER-1 decision gate mints NO nonce (genuinely agent-clearable) ----
#     DIVE-2356: the tier is now load-bearing for this assertion, so assert it
#     rather than relying on "decision defaults to tier 1 and 'pick' trips no
#     floor". If either ever moves, this gate would land at tier 2 and T2 would
#     quietly invert from "the boundary holds" to "the mint is broken".
seed_task DIVE-200
NOTIFY_NONCE="sentinel"
cmd_task_need DIVE-200 --type=decision --ask="pick" --options="A|B" --recommend="A" >/dev/null 2>&1
t=$(db "SELECT COALESCE(tier,'') FROM tasks WHERE ident='DIVE-200';")
[[ "$t" == "1" ]] && ok_t "T2 precondition: gate landed at tier 1" \
  || bad_t "T2 precondition: gate landed at tier 1" "got tier '$t' — the no-nonce assertion below is no longer about tier 1"
h=$(db "SELECT COALESCE(human_nonce_hash,'null') FROM tasks WHERE ident='DIVE-200';")
[[ "$h" == "null" || -z "$h" ]] && ok_t "T2 tier-1 decision gate mints no nonce" \
  || bad_t "T2 tier-1 decision gate mints no nonce" "got: '$h'"
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
# rc CAPTURED on purpose (iteration 2): `cmd_task_answer` is a sourced FUNCTION, so
# a `fail` inside it calls `exit` and kills THIS harness mid-suite rather than
# failing one arm. That is how the DIVE-2330 guard bug presented — 9/18 arms and
# exit 6, with the remaining arms never printing at all. A subshell contains it, so
# the next such regression reds an arm instead of truncating the log.
(SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-301 --value=approved --human --human-proof=KNOWNNONCE123) >/dev/null 2>&1
[[ "$(answered DIVE-301)" == "closed" ]] && ok_t "T3 valid --human-proof clears (SUDO_UID=agent)" \
  || bad_t "T3 valid --human-proof clears" "still $(answered DIVE-301)"

seed_gate_known DIVE-302 KNOWNNONCE123
out=$(SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-302 --value=approved --human --human-proof=WRONG 2>&1); rc=$?
[[ "$(answered DIVE-302)" == "open" && $rc -ne 0 ]] && ok_t "T3 wrong --human-proof rejected" \
  || bad_t "T3 wrong --human-proof rejected" "rc=$rc state=$(answered DIVE-302)"

# --- T4: DIVE-950 — form (b) --proof is DROPPED. An agent-SUDO_UID answer that
#     presents ONLY a --proof token (even a well-formed one) is REJECTED: the token
#     is no longer evidence, so with no nonce + agent SUDO_UID there is none. -----
seed_task DIVE-400; cmd_task_need DIVE-400 --type=approval --ask="approve?" >/dev/null 2>&1
out=$(SUDO_UID="$AGENT_UID" cmd_task_answer DIVE-400 --value=approved --human --proof="v1:dead:9999999999:beef" 2>&1); rc=$?
[[ "$(answered DIVE-400)" == "open" && $rc -ne 0 ]] && ok_t "T4 DIVE-950: --proof no longer clears (form b dropped)" \
  || bad_t "T4 --proof dropped" "rc=$rc state=$(answered DIVE-400) out=$out"

# --- T5: (c) non-agent SUDO_UID clears with NO proof (drop / human-on-box) ----
seed_task DIVE-500; cmd_task_need DIVE-500 --type=secret --ask="drop key" --secret-key=FIXTURE_TOKEN --connector=fixture >/dev/null 2>&1
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

# --- T8: agent immediate-caller (pre-sudo) blocked by the DIVE-394 guard -------
# DIFFERENTIAL (iteration 2): the same gate, the same answer, ONLY the caller
# identity changes. Asserting the agent arm alone cannot distinguish "refused
# because the caller is an agent" from "refused for one of the other reasons a
# tier-2 manual gate refuses" — which is exactly how the inert version passed.
FAKE_CALLER="agent-evil"
seed_task DIVE-800; cmd_task_need DIVE-800 --type=manual --ask="do it" >/dev/null 2>&1
out=$(cmd_task_answer DIVE-800 --value=done --human 2>&1); rc=$?
[[ "$(answered DIVE-800)" == "open" && $rc -ne 0 && "$out" == *"only a human"* ]] \
  && ok_t "T8 agent-* immediate caller blocked on manual gate (defense-in-depth)" \
  || bad_t "T8 agent-* caller blocked on manual" "rc=$rc state=$(answered DIVE-800) out=$out"

# T8b: the CONTROL. Non-agent caller, everything else identical — must NOT hit
# the agent refusal. Without this arm T8 grades a message, not a mechanism.
FAKE_CALLER="root"
seed_task DIVE-801; cmd_task_need DIVE-801 --type=manual --ask="do it" >/dev/null 2>&1
out8b=$(cmd_task_answer DIVE-801 --value=done --human 2>&1); rc8b=$?
[[ "$out8b" != *"only a human can clear it"* ]] \
  && ok_t "T8b CONTROL: non-agent caller does NOT hit the agent refusal (rc=$rc8b)" \
  || bad_t "T8b non-agent caller wrongly hit the agent refusal" "rc=$rc8b out=$out8b"

# --- T9: _gate_sudo_uid_nonagent direct logic --------------------------------
SUDO_UID=0 _gate_sudo_uid_nonagent && ok_t "T9 SUDO_UID=root -> non-agent" || bad_t "T9 root non-agent" ""
SUDO_UID="$AGENT_UID" _gate_sudo_uid_nonagent && bad_t "T9 agent uid -> should be agent" "" || ok_t "T9 agent SUDO_UID -> agent (not evidence)"

echo "-----"
printf 'gate_nonce_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
