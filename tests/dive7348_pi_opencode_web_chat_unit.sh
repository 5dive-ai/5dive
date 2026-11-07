#!/usr/bin/env bash
# DIVE-7348 — Pi and OpenCode agents take the web chat (channels=dashboard).
#
# Before: every channels=dashboard check refused pi and opencode, their channel
# installers took telegram only, and the boot script ran their Telegram relay
# only when CHANNELS was exactly "telegram". The dashboard plugin (0.5.34) now
# answers a pi/opencode web chat with one headless CLI turn per message; this
# harness covers the box half.
#
# Offline: the real boot-script blocks are extracted from bin/5dive-agent-start
# and run against a fixture HOME, as in dive7347_grok_web_chat_unit.sh.
#
#   P1  type_has_web_chat: pi and opencode yes; the refusal's list names both.
#   P2  install_channel_for_agent pi|opencode dashboard: exits 0, no token asked,
#       prepares the dashboard bridge (inbox) for the seat.
#   P3  telegram still needs its token on both (the dashboard arm did not swallow it).
#   D1  type dispatch: telegram,dashboard runs the Telegram relay (bun start),
#       dashboard alone runs the TUI, telegram alone still runs the relay.
#   D2  the relay env (PI_BIN / OPENCODE_BIN) is set for telegram,dashboard.
#   D3  the channel loop takes dashboard on pi/opencode without the refusal.
#   S1  the dashboard server runs beside a pi/opencode seat with --runtime=<type>,
#       from the seat's work folder, DASHBOARD_AGENT_WORKDIR set, and the
#       variables the pane drops (UNSET_CREDS) dropped; hermes is unchanged.
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

# --- P1 who may take the web chat ----------------------------------------------
got=""
for t in pi opencode; do type_has_web_chat "$t" && got+="${t}:y " || got+="${t}:n "; done
eq_t "P1 pi and opencode have the web chat" "pi:y opencode:y " "$got"
eq_t "P1 the refusal's list names both" "claude, codex, grok, antigravity, hermes, openclaw, pi or opencode" "$(web_chat_types_text)"

# --- P2/P3 the channel installers ----------------------------------------------
WORK=$(mktemp -d)
LOGF="$WORK/calls.log"
sandbox() {
  id() { return 0; }
  prepare_dashboard_bridge() { echo "prepare_dashboard_bridge $*" >> "$LOGF"; }
  step() { :; }
}
for t in pi opencode; do
  : > "$LOGF"
  out=$( ( sandbox; install_channel_for_agent "$t" dashboard "${t}x" "" ) 2>&1 ); rc=$?
  eq_t "P2 $t dashboard install exits 0 with no token" "0" "$rc"
  eq_t "P2 $t dashboard install prepares the bridge for the seat user" "prepare_dashboard_bridge agent-${t}x" "$(cat "$LOGF")"
  out=$( ( sandbox; install_channel_for_agent "$t" telegram "${t}x" "" ) 2>&1 ); rc=$?
  [[ $rc -ne 0 && "$out" == *"requires a bot token"* ]] \
    && ok_t "P3 $t telegram still asks for its token" || bad_t "P3 $t telegram still asks for its token" "rc=$rc out=$out"
  out=$( ( sandbox; install_channel_for_agent "$t" discord "${t}x" "tok" ) 2>&1 ); rc=$?
  [[ $rc -ne 0 && "$out" == *"telegram or dashboard"* ]] \
    && ok_t "P3 $t discord refused, naming what it takes" || bad_t "P3 $t discord refused, naming what it takes" "rc=$rc out=$out"
done

# --- D1/D2 the boot script's type dispatch -------------------------------------
START=bin/5dive-agent-start
# The opencode and pi arms of the type dispatch: from `  opencode)` to the
# `    fi ;;` that closes the pi arm.
ARMS=$(awk '/^  opencode\)$/ {on=1} on {print} on && /^  pi\)$/ {pi=1} on && pi && /^    fi ;;$/ {exit}' "$START")
[[ "$ARMS" == *'TELEGRAM_PI_PLUGIN_DIR'* && "$ARMS" == *'TELEGRAM_OPENCODE_PLUGIN_DIR'* ]] \
  || bad_t "D1 extract the opencode/pi dispatch arms" "not found in $START"
mkdir -p "$WORK/tp" "$WORK/to"; : > "$WORK/tp/server.ts"; : > "$WORK/to/server.ts"
dispatch() {
  ( TYPE="$1" CHANNELS="$2" TELEGRAM_PI_PLUGIN_DIR="$WORK/tp" TELEGRAM_OPENCODE_PLUGIN_DIR="$WORK/to"
    resolve_bun() { echo /x/bun; }
    eval "case \"\$TYPE\" in
$ARMS
esac"
    echo "$BIN ${ARGS[*]}" ) 2>&1
}
eq_t "D1 pi telegram,dashboard runs the relay" "/x/bun run --cwd $WORK/tp --shell=bun --silent start" "$(dispatch pi telegram,dashboard)"
eq_t "D1 pi dashboard,telegram runs the relay" "/x/bun run --cwd $WORK/tp --shell=bun --silent start" "$(dispatch pi dashboard,telegram)"
eq_t "D1 pi telegram alone still runs the relay" "/x/bun run --cwd $WORK/tp --shell=bun --silent start" "$(dispatch pi telegram)"
eq_t "D1 pi dashboard alone runs the TUI" "/home/claude/.local/bin/pi " "$(dispatch pi dashboard)"
eq_t "D1 opencode telegram,dashboard runs the relay" "/x/bun run --cwd $WORK/to --shell=bun --silent start" "$(dispatch opencode telegram,dashboard)"
eq_t "D1 opencode dashboard alone runs the TUI" "/home/claude/.local/bin/opencode " "$(dispatch opencode dashboard)"

OVR=$(awk '/^OPENCODE_OVERRIDE=""$/ {on=1} on {print} on && /^PI_OVERRIDE=""$/ {pi=1} on && pi && /^fi$/ {exit}' "$START")
[[ "$OVR" == *'PI_BIN'* ]] || bad_t "D2 extract the relay env blocks" "not found"
ovr() { ( TYPE="$1" CHANNELS="$2" WORKDIR=/w; eval "$OVR"; echo "${OPENCODE_OVERRIDE}${PI_OVERRIDE}" ) 2>&1; }
[[ "$(ovr pi telegram,dashboard)" == *'PI_BIN='*'PI_PROJECT_DIR=/w'* ]] \
  && ok_t "D2 pi relay env for telegram,dashboard" || bad_t "D2 pi relay env for telegram,dashboard" "$(ovr pi telegram,dashboard)"
[[ "$(ovr opencode telegram,dashboard)" == *'OPENCODE_BIN='*'OPENCODE_PROJECT_DIR=/w'* ]] \
  && ok_t "D2 opencode relay env for telegram,dashboard" || bad_t "D2 opencode relay env for telegram,dashboard" "$(ovr opencode telegram,dashboard)"
eq_t "D2 no relay env for dashboard alone" "" "$(ovr pi dashboard)"

# --- D3 the channel loop --------------------------------------------------------
LOOP=$(awk '/^IFS=.,. read -ra CHANNEL_LIST/ {on=1} on {print} on && /^done$/ {exit}' "$START")
[[ "$LOOP" == *'channels=dashboard requires'* ]] || bad_t "D3 extract the channel loop" "not found"
chloop() { ( TYPE="$1" CHANNELS=dashboard HOME="$WORK/h-$1" ARGS=(); exit() { echo "EXIT $1"; return "$1"; }; eval "$LOOP"; echo "ok" ) 2>&1 | tail -1; }
eq_t "D3 pi takes dashboard in the channel loop" "ok" "$(chloop pi)"
eq_t "D3 opencode takes dashboard in the channel loop" "ok" "$(chloop opencode)"
[[ "$( ( TYPE=devin CHANNELS=dashboard HOME="$WORK/h-d" ARGS=(); eval "$LOOP" ) 2>&1 )" == *"requires type="*"pi or opencode"* ]] \
  && ok_t "D3 a type with no web chat is refused, the list named" || bad_t "D3 a type with no web chat is refused, the list named"

# --- S1 the bridge beside the seat ---------------------------------------------
BRIDGE=$(awk '/^# DIVE-7349: the web chat for a hermes or openclaw seat/ {on=1} on {print} on && /^fi$/ {exit}' "$START")
[[ "$BRIDGE" == *'--runtime=$TYPE'* && "$BRIDGE" == *'DASHBOARD_AGENT_WORKDIR'* ]] || bad_t "S1 extract the bridge block" "not found in $START"
PLUG="$WORK/plugins/dashboard"; mkdir -p "$PLUG" "$WORK/bin" "$WORK/seatwork"; : > "$PLUG/server.ts"
# The stand-in bun records argv, cwd and the variables the turn would see.
printf '#!/bin/sh\necho "bun $* | cwd=$PWD | wd=${DASHBOARD_AGENT_WORKDIR:-unset} | xdg=${XDG_CONFIG_HOME:-unset} | anth=${ANTHROPIC_API_KEY:-unset} | or=${OPENROUTER_API_KEY:-unset}" >> %q\n' "$LOGF" > "$WORK/bin/bun"; chmod +x "$WORK/bin/bun"
# tmux: the session is up for the first check, gone after (one bridge run).
printf '#!/bin/sh\nf=%q/tmux-calls; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n+1)) > "$f"; [ "$n" -lt 1 ]\n' "$WORK" > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
bridge() {
  : > "$LOGF"; rm -f "$WORK/tmux-calls"
  ( cd /; TYPE="$1" CHANNELS="$2" UNSET_CREDS="$3" NAME=bx SESSION=agent-bx WORKDIR="$WORK/seatwork" DASHBOARD_PLUGIN_DIR="$PLUG"
    export XDG_CONFIG_HOME=/home/claude/.config ANTHROPIC_API_KEY=leak OPENROUTER_API_KEY=seatkey
    resolve_bun() { echo "$WORK/bin/bun"; }; sleep() { :; }
    eval "${BRIDGE//\/usr\/bin\/tmux/$WORK/bin/tmux}"; wait ) >/dev/null 2>&1
  cat "$LOGF"
}
OC_UNSET="CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY GEMINI_API_KEY GOOGLE_API_KEY XDG_CONFIG_HOME"
eq_t "S1 opencode seat: beside the seat, in its work folder, the pane's drops dropped" \
  "bun $PLUG/server.ts --runtime=opencode | cwd=$WORK/seatwork | wd=$WORK/seatwork | xdg=unset | anth=unset | or=seatkey" \
  "$(bridge opencode telegram,dashboard "$OC_UNSET")"
eq_t "S1 pi seat: beside the seat, nothing dropped when the pane drops nothing" \
  "bun $PLUG/server.ts --runtime=pi | cwd=$WORK/seatwork | wd=$WORK/seatwork | xdg=/home/claude/.config | anth=leak | or=seatkey" \
  "$(bridge pi dashboard "")"
eq_t "S1 pi dashboard off: no bridge" "" "$(bridge pi telegram "")"
eq_t "S1 hermes unchanged: no work-folder env, no drops" \
  "bun $PLUG/server.ts --runtime=hermes | cwd=/ | wd=unset | xdg=/home/claude/.config | anth=leak | or=seatkey" \
  "$(bridge hermes dashboard "$OC_UNSET")"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
