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
#   W1  type_has_web_chat: claude, codex, grok, hermes, openclaw yes; pi, "" no.
#   W2  install_channel_for_agent refuses dashboard on a pi seat, naming the list.
#   B1  channels=telegram,dashboard: both MCP tables written, the dashboard one
#       runs the dashboard server with --runtime=grok.
#   B2  a second boot rewrites the dashboard table, never duplicates it.
#   B3  dashboard leaving CHANNELS removes its table and keeps the others.
#   B4  channels=dashboard alone: the dashboard table, no telegram table.
#   K1  the cold-start kick fires for a web-chat-only seat, with no Telegram words.
#
# DIVE-7349 — Hermes and OpenClaw take it too (same subject, same harness):
#   H1  a hermes seat gets the 5dive channel plugin linked from the dashboard
#       checkout, enabled without a prompt, and its spool + sender in ~/.hermes/.env.
#   H2  a dashboard checkout with no hermes plugin is refused, naming self-update.
#   O1  an openclaw seat gets the bridge prerequisites and gateway.mode local.
#   S1  the boot script runs the dashboard server beside a hermes/openclaw seat
#       with --runtime=<type>, and not when dashboard is off or the type is other.
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
for t in claude codex grok hermes openclaw pi ""; do type_has_web_chat "$t" && got+="${t}:y " || got+="${t:-none}:n "; done
eq_t "W1 type_has_web_chat" "claude:y codex:y grok:y hermes:y openclaw:y pi:n none:n " "$got"
out=$( ( install_channel_for_agent pi dashboard px "" ) 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"requires type=claude, codex, grok, hermes or openclaw"* ]] \
  && ok_t "W2 pi refused, the message names the list" || bad_t "W2 pi refused, the message names the list" "rc=$rc out=$out"

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

# --- DIVE-7349: hermes and openclaw ---------------------------------------------
# The setup helpers run as the seat user through sudo; here they run as us, in a
# fixture HOME, with the hermes/openclaw CLIs replaced by argv loggers.
SEAT="$WORK/seat"; mkdir -p "$SEAT" "$PLUG/hermes"
: > "$PLUG/hermes/plugin.yaml"
LOGF="$WORK/argv.log"
printf '#!/bin/sh\necho "hermes $*" >> %q\n' "$LOGF" > "$WORK/bin/hermes"; chmod +x "$WORK/bin/hermes"
setup_sandbox() {
  sudo() { while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done; HOME="$SEAT" "$@"; }
  id() { return 0; }
  getent() { printf 'agent-hx:x:1:1::%s:/bin/bash\n' "$SEAT"; }
  ensure_bun_for_agent() { return 0; }
  step() { :; }
  TYPE_BIN[hermes]="$WORK/bin/hermes"
}
out=$( ( setup_sandbox; install_channel_for_agent hermes dashboard hx "" ) 2>&1 ); rc=$?
eq_t "H1 hermes dashboard install exits 0" "0" "$rc"
eq_t "H1 plugin linked from the dashboard checkout" "$PLUG/hermes" "$(readlink "$SEAT/.hermes/plugins/fivedive" 2>&1)"
grep -qx "hermes plugins enable fivedive --no-allow-tool-override" "$LOGF" \
  && ok_t "H1 plugin enabled without a prompt" || bad_t "H1 plugin enabled without a prompt" "$(cat "$LOGF" 2>&1) $out"
eq_t "H1 spool in .env" "FIVEDIVE_SPOOL_DIR=$SEAT/.hermes/channels/5dive" "$(grep '^FIVEDIVE_SPOOL_DIR=' "$SEAT/.hermes/.env" 2>&1)"
eq_t "H1 only the bridge's sender" "FIVEDIVE_ALLOWED_USERS=5dive-app" "$(grep '^FIVEDIVE_ALLOWED_USERS=' "$SEAT/.hermes/.env" 2>&1)"
[[ -d "$SEAT/.hermes/channels/5dive" && -d "$SEAT/.claude/channels/dashboard/agent-inbox" ]] \
  && ok_t "H1 spool and dashboard inbox exist" || bad_t "H1 spool and dashboard inbox exist" "$(find "$SEAT" -maxdepth 4 -type d 2>&1 | head)"
( setup_sandbox; install_channel_for_agent hermes dashboard hx "" ) >/dev/null 2>&1
eq_t "H1 a second install keeps one line each" "1 1" "$(grep -c '^FIVEDIVE_SPOOL_DIR=' "$SEAT/.hermes/.env") $(grep -c '^FIVEDIVE_ALLOWED_USERS=' "$SEAT/.hermes/.env")"
mv "$PLUG/hermes" "$PLUG/hermes.off"
out=$( ( setup_sandbox; install_channel_for_agent hermes dashboard hx "" ) 2>&1 ); rc=$?
[[ $rc -ne 0 && "$out" == *"has no hermes plugin"*"self-update"* ]] \
  && ok_t "H2 an old dashboard checkout is refused by name" || bad_t "H2 an old dashboard checkout is refused by name" "rc=$rc out=$out"
mv "$PLUG/hermes.off" "$PLUG/hermes"

: > "$LOGF"
out=$( ( setup_sandbox; bash() { echo "bash $*" >> "$LOGF"; }; install_channel_for_agent openclaw dashboard ox "" ) 2>&1 ); rc=$?
eq_t "O1 openclaw dashboard install exits 0, no token asked" "0" "$rc"
grep -q "openclaw config set gateway.mode local" "$LOGF" \
  && ok_t "O1 gateway.mode set to local" || bad_t "O1 gateway.mode set to local" "$(cat "$LOGF") $out"

BRIDGE=$(awk '/^# DIVE-7349: the web chat for a hermes or openclaw seat/ {on=1} on {print} on && /^fi$/ {exit}' "$START")
[[ "$BRIDGE" == *'--runtime=$TYPE'* ]] || bad_t "S1 extract the DIVE-7349 block" "not found in $START"
printf '#!/bin/sh\necho "bun $*" >> %q\n' "$LOGF" > "$WORK/bin/bun"; chmod +x "$WORK/bin/bun"
# tmux: the session is up for the first check, gone after (one bridge run).
printf '#!/bin/sh\nf=%q/tmux-calls; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n+1)) > "$f"; [ "$n" -lt 1 ]\n' "$WORK" > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
bridge() {
  : > "$LOGF"; rm -f "$WORK/tmux-calls"
  ( TYPE="$1" CHANNELS="$2" NAME=bx SESSION=agent-bx; resolve_bun() { echo "$WORK/bin/bun"; }; sleep() { :; }
    eval "${BRIDGE//\/usr\/bin\/tmux/$WORK/bin/tmux}"; wait ) >/dev/null 2>&1
  cat "$LOGF"
}
eq_t "S1 hermes seat: bridge runs with --runtime=hermes" "bun $PLUG/server.ts --runtime=hermes" "$(bridge hermes telegram,dashboard)"
eq_t "S1 openclaw seat: bridge runs with --runtime=openclaw" "bun $PLUG/server.ts --runtime=openclaw" "$(bridge openclaw dashboard)"
eq_t "S1 dashboard off: no bridge" "" "$(bridge hermes telegram)"
eq_t "S1 a grok seat is not this block's" "" "$(bridge grok dashboard)"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
