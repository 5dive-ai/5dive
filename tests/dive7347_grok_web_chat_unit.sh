#!/usr/bin/env bash
# DIVE-7347 — a Grok agent takes the web chat (channels=dashboard).
#
# Before: every channels=dashboard check said "claude or codex", so the app's
# one-tap `agent config <grok> set channels=…,dashboard` was refused, and the
# boot script wired telegram-grok only when CHANNELS was exactly "telegram".
# The dashboard plugin (0.5.14) now carries the Grok bridge; this harness covers
# the box half: who may take the channel, and what the boot script writes into
# ~/.grok/config.toml.
#
# Offline: the real boot-script blocks are extracted from bin/5dive-agent-start
# and run against a fixture HOME (same shape as agent_start_cred_seed_unit.sh).
#
#   W1  type_has_web_chat: claude, codex, grok yes; hermes, pi, "" no.
#   W2  install_channel_for_agent refuses dashboard on a hermes seat, by name.
#   B1  channels=telegram,dashboard: both MCP tables written, the dashboard one
#       runs the dashboard server with --runtime=grok.
#   B2  a second boot rewrites the dashboard table, never duplicates it.
#   B3  dashboard leaving CHANNELS removes its table and keeps the others.
#   B4  channels=dashboard alone: the dashboard table, no telegram table.
#   K1  the cold-start kick fires for a web-chat-only seat, with no Telegram words.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
WORK=""
trap 'rc=$?; [[ -n "$WORK" ]] && rm -rf "$WORK"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh; do
  # shellcheck disable=SC1090
  source "src/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

# --- who may take the web chat -------------------------------------------------
got=""
for t in claude codex grok hermes pi ""; do type_has_web_chat "$t" && got+="${t}:y " || got+="${t:-none}:n "; done
eq_t "W1 type_has_web_chat" "claude:y codex:y grok:y hermes:n pi:n none:n " "$got"
out=$( ( install_channel_for_agent hermes dashboard hx "" ) 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"requires type=claude, codex or grok"* ]] \
  && ok_t "W2 hermes refused, the message names grok" || bad_t "W2 hermes refused, the message names grok" "rc=$rc out=$out"

# --- the boot script ------------------------------------------------------------
WORK=$(mktemp -d)
START=bin/5dive-agent-start
# The DIVE-7347 block: from its comment to the first column-0 `fi` after it.
BLOCK=$(awk '/^# DIVE-7347: the web chat for a grok agent/ {on=1} on {print} on && /^fi$/ {exit}' "$START")
[[ "$BLOCK" == *'mcp_servers.dashboard'* ]] || { bad_t "extract the DIVE-7347 block" "not found in $START"; echo "$PASS passed, $FAIL failed"; exit 1; }
PLUG="$WORK/plugins/dashboard"; mkdir -p "$PLUG"; : > "$PLUG/server.ts"
export HOME="$WORK/home" DASHBOARD_PLUGIN_DIR="$PLUG"
mkdir -p "$HOME/.grok"
CFG="$HOME/.grok/config.toml"
boot() { ( TYPE=grok CHANNELS="$1" NAME=gk; eval "$BLOCK" ) 2>&1; }
tables() { python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(" ".join(sorted(d.get("mcp_servers",{}))))' "$CFG" 2>&1; }

# What the telegram block leaves behind on a real boot, plus a user table.
printf '%s\n' '[models]' 'default = "grok-4.5"' '' '[mcp_servers.telegram]' 'command = "bun"' \
  'args = ["/usr/local/lib/5dive/telegram-grok/server.ts"]' > "$CFG"
boot telegram,dashboard >/dev/null
eq_t "B1 both MCP tables" "dashboard telegram" "$(tables)"
args=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1],"rb"))["mcp_servers"]["dashboard"]["args"])' "$CFG" 2>&1)
eq_t "B1 dashboard runs the Grok bridge" "['$PLUG/server.ts', '--runtime=grok']" "$args"

boot telegram,dashboard >/dev/null
eq_t "B2 one dashboard table after a second boot" "1" "$(grep -c '^\[mcp_servers\.dashboard\]' "$CFG")"
eq_t "B2 still valid TOML" "dashboard telegram" "$(tables)"

boot telegram >/dev/null
eq_t "B3 chat off: dashboard table gone" "telegram" "$(tables)"
grep -q '^default = "grok-4.5"' "$CFG" && ok_t "B3 other tables kept" || bad_t "B3 other tables kept" "$(cat "$CFG")"

rm -f "$CFG"
boot dashboard >/dev/null
eq_t "B4 web chat only" "dashboard" "$(tables)"

# --- the cold-start kick ----------------------------------------------------------
KICK=$(awk '/^# DIVE-7347: a web-chat-only grok seat needs the same kick/ {on=1} on {print} on && /^fi$/ {exit}' "$START")
[[ -n "$KICK" ]] || bad_t "K1 extract the kick block" "not found"
coldstart_kick_submit() { printf 'KICK:%s\n' "$COLDSTART_KICK_TEXT"; }
coldstart_kick_never_typed() { printf 'NEVER\n'; }
COLDSTART_KICK_TEXT='Start your Telegram listen loop: call wait_for_message now'
seq() { echo 1; }; sleep() { :; }
mkdir -p "$WORK/bin"; printf '#!/bin/sh\necho "Resume session"\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
kick() { ( TYPE=grok CHANNELS="$1" SESSION=agent-gk; eval "${KICK//\/usr\/bin\/tmux/$WORK/bin/tmux}"; wait ) 2>&1; }
out=$(kick dashboard)
[[ "$out" == KICK:* && "$out" != *Telegram* && "$out" != *wait_for_message* ]] \
  && ok_t "K1 web-chat-only seat kicked without Telegram words" || bad_t "K1 web-chat-only seat kicked without Telegram words" "$out"
out=$(kick telegram,dashboard)
[[ "$out" == *"KICK:Start your Telegram listen loop"* ]] \
  && ok_t "K1 a Telegram seat keeps its listen-loop kick" || bad_t "K1 a Telegram seat keeps its listen-loop kick" "$out"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
