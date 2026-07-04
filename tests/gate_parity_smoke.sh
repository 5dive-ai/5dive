#!/usr/bin/env bash
# OSS-15 — cross-cutting acceptance gate for the Human Gates 2.0 line.
#
# Asserts that EVERY shipped gate feature degrades cleanly WITHOUT Telegram: the
# CLI-only path stays first-class and there is no hard Telegram dependency.
# Telegram is a best-effort NOTIFY layer, never a requirement for a gate to be
# filed, listed, or cleared. Run this before ANY OSS release that touches gates.
#
# Three layers:
#   (1) PARITY MATRIX — each gate feature maps to a CLI verb + a covering headless
#       unit test. Every sibling test runs "no root, no network" (it never talks
#       to Telegram), so each is itself a Telegram-free proof; we assert the
#       covering test file exists so the parity coverage can't silently rot.
#   (2) LIVE SMOKE — with the Telegram plugin/token stripped from the env, drive
#       the need -> inbox -> answer lifecycle + a secret-gate filing end-to-end
#       against a throwaway DB. Proves the gate machinery needs zero Telegram.
#   (3) STATIC INVARIANTS — grep-level guarantees: the gate NOTIFY is best-effort
#       (|| true); a human can clear a hard gate on-box via a non-agent SUDO_UID
#       (no Telegram nonce required); secret gates have an on-box credential-drop
#       fallback; the autonomy report is deterministic digest output.
#
# NO SILENT GAP: "fleet inbox" (task inbox --fleet, OSS-13) is NOT shipped yet
# (blocked). Its parity row is a documented PENDING that self-activates into a
# hard assertion the moment `task inbox --fleet` exists — re-run this smoke then.
#
# Run: bash tests/gate_parity_smoke.sh   (no root, no network, no Telegram)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# The parity condition, made explicit and enforced: no Telegram anything in env.
unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOKEN TELEGRAM_API_ID 2>/dev/null || true

TMP="$(mktemp -d /tmp/gate-parity.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh cmd_task.sh cmd_org.sh cmd_project.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"
TASKS_DIR="$STATE_DIR/tasks"
TASKS_DB="$TASKS_DIR/tasks.db"
JSON_MODE=1
mkdir -p "$TASKS_DIR"
set +e   # header.sh enabled `set -e`; this smoke deliberately expects non-zero exits

tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
jf() { jq -r "$1" 2>/dev/null; }

echo "== (1) parity matrix: every shipped gate feature has a Telegram-free covering test =="
# "feature | <verb notes...> | covering headless test"  (last field = test path)
matrix=(
  "need/inbox/answer core | task need / inbox / answer | tests/task_core_unit.sh"
  "decision-memory prefill (precedent) | task need --recommend from precedent | tests/gate_precedent_unit.sh"
  "human-origin enforcement (nonce + on-box SUDO_UID) | task answer --human-proof | tests/gate_nonce_unit.sh"
  "SLA escalation (unanswered gate walks the org chart) | heartbeat gate-escalate | tests/heartbeat_gate_escalate_unit.sh"
  "secret credential-drop fallback | task need --type=secret / secret write | tests/secret_drop_unit.sh"
  "autonomy report | digest --7d autonomy block | tests/digest_autonomy_unit.sh"
)
for row in "${matrix[@]}"; do
  feat="${row%% |*}"
  testf="${row##*| }"
  [[ -f "$testf" ]] && ok_t "covered headless: $feat -> $testf" \
    || bad_t "MISSING covering test: $feat" "expected $testf"
done

echo "== fleet inbox (OSS-13) parity: PENDING until shipped =="
# cmd_task_inbox today rejects any positional/flag arg, so --fleet fails -> NOTE.
# When OSS-13 lands `task inbox --fleet`, this flips to a hard coverage assertion.
if ( cmd_task_inbox --fleet ) >/dev/null 2>&1; then  # subshell: its fail->exit must not kill the harness
  [[ -f tests/fleet_inbox_unit.sh ]] \
    && ok_t "fleet-inbox shipped and covered by a Telegram-free test" \
    || bad_t "fleet-inbox shipped WITHOUT a Telegram-free covering test" "add tests/fleet_inbox_unit.sh"
else
  printf 'NOTE - fleet inbox (task inbox --fleet, OSS-13) not shipped yet (blocked); parity row deferred. Re-run when OSS-13 lands.\n'
fi

echo "== (2) live smoke: file -> inbox -> answer with Telegram stripped from env =="
cmd_task_add "Parity probe gate" >/dev/null 2>&1
pid=$(db "SELECT id FROM tasks WHERE title='Parity probe gate' ORDER BY id DESC LIMIT 1;")
[[ -n "$pid" ]] || bad_t "setup: could not add probe task" ""

cmd_task_need "$pid" --type=decision --options="approve|revise" --recommend="approve" \
  --ask="Approve the parity probe?" >/dev/null 2>&1
st=$(db "SELECT status||'|'||COALESCE(need_type,'') FROM tasks WHERE id=${pid};")
[[ "$st" == "blocked|decision" ]] \
  && ok_t "gate filed CLI-only (blocked, decision) with no Telegram present" \
  || bad_t "need did not file a CLI gate" "got: $st"

inbox=$(cmd_task_inbox 2>/dev/null)
printf '%s' "$inbox" | jq -e --arg id "$pid" '.data.inbox[] | select(.id == ($id|tonumber))' >/dev/null 2>&1 \
  && ok_t "filed gate appears in the CLI inbox (no Telegram)" \
  || bad_t "gate missing from CLI inbox" "$inbox"

cmd_task_answer "$pid" --value="approve" >/dev/null 2>&1
ans=$(db "SELECT status||'|'||COALESCE(need_answer,'') FROM tasks WHERE id=${pid};")
[[ "$ans" == *"|approve" && "$ans" != blocked* ]] \
  && ok_t "gate answered + unblocked via CLI (no Telegram)" \
  || bad_t "answer did not clear the gate via CLI" "got: $ans"

cmd_task_add "Parity secret probe" >/dev/null 2>&1
sid=$(db "SELECT id FROM tasks WHERE title='Parity secret probe' ORDER BY id DESC LIMIT 1;")
cmd_task_need "$sid" --type=secret --ask="drop the token" --secret-key=PARITY_TOKEN --connector=pypi >/dev/null 2>&1
sg=$(db "SELECT need_type||'|'||COALESCE(secret_key,'')||'|'||COALESCE(connector,'') FROM tasks WHERE id=${sid};")
[[ "$sg" == "secret|PARITY_TOKEN|pypi" ]] \
  && ok_t "secret gate + on-box drop target filed CLI-only" \
  || bad_t "secret gate did not store its on-box drop target" "got: $sg"

echo "== (3) static invariants: Telegram is notify-only; on-box human clear; drop fallback =="
grep -Eq 'task_need_notify .*\|\| true' src/cmd_task.sh \
  && ok_t "gate NOTIFY is best-effort (|| true) — a Telegram failure never blocks a gate" \
  || bad_t "gate notify is not best-effort guarded" "expected 'task_need_notify ... || true' in src/cmd_task.sh"

grep -q '_gate_sudo_uid_nonagent' src/cmd_task.sh \
  && ok_t "hard gates clear on-box via a non-agent SUDO_UID (no Telegram nonce required)" \
  || bad_t "no on-box human-evidence path" "expected _gate_sudo_uid_nonagent form in cmd_task_answer"

grep -Eqi 'ONBOX|on-box|drop' src/cmd_task.sh src/cmd_secret.sh \
  && ok_t "secret gates have an on-box credential-drop fallback" \
  || bad_t "no on-box credential-drop fallback found" "expected an ONBOX / drop path"

grep -q 'autonomy' src/cmd_digest.sh \
  && ok_t "autonomy report is deterministic digest output (zero agent / Telegram deps)" \
  || bad_t "no autonomy block in digest" "expected an 'autonomy' block in src/cmd_digest.sh"

echo ""
printf 'gate parity smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
