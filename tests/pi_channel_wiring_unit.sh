#!/usr/bin/env bash
# DIVE-1201 unit harness for the pi telegram-channel CLI wiring.
#
# pi (earendil-works/pi) is EXTENSION-based (DIVE-1198 SPIKE) with no MCP/hooks
# config surface, so its telegram bridge is a STANDALONE RELAY (telegram-pi/
# server.ts) launched by 5dive-agent-start via bun — the same run-model as
# opencode. This task wired the CLI side to match:
#   - install_channel_for_agent dispatches type=pi -> install_channel_for_pi_agent,
#   - pi_plugin_dir() resolves the shared checkout (env override + the two
#     canonical paths) exactly like opencode_plugin_dir(),
#   - _tg_access_state_dir(pi) -> ~/.pi/channels/telegram (so `agent
#     telegram-access get/set` works for pi),
#   - 5dive-agent-start has a pi launch case (bun relay for channels=telegram)
#     and a PI_OVERRIDE (PI_BIN/PI_PROJECT_DIR) wired into INNER.
# These are the deterministic, no-root/no-network pieces; the end-to-end relay
# launch is exercised once telegram-pi (DIVE-1202) is deployed.
# Run: bash tests/pi_channel_wiring_unit.sh  (no root, no network, no tmux).
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh cmd_agent_pairing.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e  # header.sh enabled set -e; asserts below deliberately probe non-zero rc

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- type registration (from DIVE-1199, guarded here so the channel path holds) ---
[[ "${TYPE_CHANNELS[pi]:-}" == "1" ]] && ok_t "TYPE_CHANNELS[pi]=1 (channels supported)" || bad_t "TYPE_CHANNELS[pi]" "got '${TYPE_CHANNELS[pi]:-}'"

# --- _tg_access_state_dir(pi) -> ~/.pi/channels/telegram ----------------------
got=$(_tg_access_state_dir "agent-foo" pi)
[[ "$got" == "/home/agent-foo/.pi/channels/telegram" ]] && ok_t "state_dir pi -> ~/.pi/channels/telegram" || bad_t "state_dir pi" "got '$got'"
# regression: the other supported types still resolve
[[ "$(_tg_access_state_dir agent-foo codex)" == "/home/agent-foo/.codex/channels/telegram" ]] && ok_t "state_dir codex unchanged" || bad_t "state_dir codex"
[[ "$(_tg_access_state_dir agent-foo antigravity)" == "/home/agent-foo/.gemini/channels/telegram" ]] && ok_t "state_dir agy unchanged (~/.gemini)" || bad_t "state_dir agy"

# --- pi_plugin_dir() resolves from the env override ---------------------------
_pdir=$(mktemp -d); : > "$_pdir/server.ts"
[[ "$(TELEGRAM_PI_PLUGIN_DIR="$_pdir" pi_plugin_dir)" == "$_pdir" ]] && ok_t "pi_plugin_dir resolves TELEGRAM_PI_PLUGIN_DIR" || bad_t "pi_plugin_dir override"
# absent server.ts -> resolver returns nonzero (fail-fast at create)
rm -f "$_pdir/server.ts"
TELEGRAM_PI_PLUGIN_DIR="$_pdir" pi_plugin_dir >/dev/null 2>&1 && bad_t "pi_plugin_dir should reject dir w/o server.ts" || ok_t "pi_plugin_dir rejects dir w/o server.ts"
rm -rf "$_pdir"

# --- the three new pi functions are defined ----------------------------------
for fn in install_channel_for_pi_agent seed_pi_telegram_access pi_plugin_dir; do
  declare -F "$fn" >/dev/null && ok_t "function defined: $fn" || bad_t "missing function" "$fn"
done

# --- dispatcher + agent-start static wiring (grep the sources) ----------------
grep -q 'pi)          install_channel_for_pi_agent' "$SRC/lib/agent_setup.sh" && ok_t "dispatcher routes pi" || bad_t "dispatcher pi route missing"
grep -q 'PI_PROJECT_DIR' 5dive-agent-start && ok_t "agent-start PI_OVERRIDE wired" || bad_t "PI_OVERRIDE missing"
grep -q '${PI_OVERRIDE}' 5dive-agent-start && ok_t "PI_OVERRIDE injected into INNER" || bad_t "PI_OVERRIDE not in INNER"
grep -q 'telegram-pi' install.sh && ok_t "install.sh stages telegram-pi" || bad_t "install.sh telegram-pi staging missing"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
