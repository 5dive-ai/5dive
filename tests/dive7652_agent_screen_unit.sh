#!/usr/bin/env bash
# DIVE-7652 — `5dive agent logs <name> --screen`: one frame of the agent's own
# window for the app's "What it's doing" > Screen view.
#
# The property that matters is NOT "it prints the screen". It is that looking
# never touches the agent: `5dive wall` attaches, and under `window-size latest`
# an attached phone-width client squeezes the live agent's window. So the arms
# below drive a REAL tmux server (private socket, no root) holding a 120x30
# session, and grade:
#
#   S1  a non-root caller is refused, and tmux is never reached
#   S2  JSON is one frame: cols/rows of the pane, at most `rows` lines, the
#       marker text, and the SGR colour escapes (`-e`)
#   S3  no tmux client attached during or after, and the session's width and
#       height are unchanged (the resize trap)
#   S4  text mode prints the coloured frame raw
#   S5  --screen with --follow/--tmux is a usage error
#   S6  a seat with no session fails E_NOT_RUNNING, not an empty frame
#
# Mutation arms (run by hand at delivery): drop `-e` from the capture -> S2's
# colour arm goes red; swap the capture for `attach -r` -> S3 goes red.
#
# `sudo` is a runas-stripping shim and `tmux` points at the private socket; the
# capture code itself runs unchanged. Run: bash tests/dive7652_agent_screen_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v tmux >/dev/null || { echo "SKIP: tmux not installed"; echo "HARNESS-RC=0"; exit 0; }
TMP=$(mktemp -d /tmp/agent-screen.XXXXXX)
SOCK="$TMP/tmux.sock"
trap 'rc=$?; command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_agent_runtime.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

CALLS="$TMP/tmux-calls"; : >"$CALLS"
sudo() { while [[ "${1:-}" == -* ]]; do [[ "$1" == "-u" ]] && shift; shift; done; "$@"; }
tmux() { printf '%s\n' "$*" >>"$CALLS"; command tmux -S "$SOCK" "$@"; }
require_agent() { :; }

# The seat: a 120x30 session painting a red marker and a plain prompt line.
command tmux -S "$SOCK" -f /dev/null new-session -d -s agent-swan -x 120 -y 30 \
  "printf '\\033[31mRED-MARKER\\033[0m working\\n> prompt-line\\n'; sleep 600"
command tmux -S "$SOCK" set-option -g window-size latest
sleep 0.5
w0=$(command tmux -S "$SOCK" display -p -t agent-swan '#{window_width}x#{window_height}')
c0=$(command tmux -S "$SOCK" list-clients -t agent-swan | wc -l)

run() { ( cmd_logs "$@" ) 2>"$TMP/err"; }

# S1 — non-root refused before tmux. EUID is read-only, so this runs the real
# require_root as whoever runs the harness; as root it cannot grade, say so.
if (( EUID == 0 )); then
  ok_t "S1 skipped: harness running as root (require_root cannot refuse)"
else
  : >"$CALLS"
  out=$(unset FIVE_ARGV; run swan --screen); rc=$?
  if (( rc != 0 )) && grep -qi "root" "$TMP/err" && [[ ! -s "$CALLS" ]]; then
    ok_t "S1 non-root caller refused, tmux never reached (rc=$rc)"
  else
    bad_t "S1 non-root caller refused" "rc=$rc calls=$(cat "$CALLS") err=$(cat "$TMP/err") out=$out"
  fi
fi

# The rest grade the capture itself, past the root check.
require_root() { :; }

# S2 — JSON frame.
: >"$CALLS"
JSON_MODE=1
out=$(run swan --screen); rc=$?
c_mid=$(command tmux -S "$SOCK" list-clients -t agent-swan | wc -l)
if (( rc == 0 )) && jq -e '.ok and .data.source=="screen" and .data.cols==120 and .data.rows==30' <<<"$out" >/dev/null; then
  ok_t "S2 envelope names source=screen, cols=120, rows=30"
else
  bad_t "S2 envelope" "rc=$rc out=$out err=$(cat "$TMP/err")"
fi
n=$(jq '.data.lines | length' <<<"$out" 2>/dev/null)
if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 2 && n <= 30 )); then ok_t "S2 one frame: $n lines, never more than the pane's 30 rows"
else bad_t "S2 one frame" "lines=$n"; fi
if jq -e '[.data.lines[] | select(test("RED-MARKER"))] | length == 1' <<<"$out" >/dev/null \
   && jq -e '[.data.lines[] | select(test("prompt-line"))] | length == 1' <<<"$out" >/dev/null; then
  ok_t "S2 frame carries the visible text"
else bad_t "S2 frame text" "$out"; fi
if jq -e '[.data.lines[] | select(test("\u001b\\[[0-9;]*31m"))] | length >= 1' <<<"$out" >/dev/null; then
  ok_t "S2 colours kept (SGR 31 escape in the frame)"
else bad_t "S2 colours kept" "$out"; fi
if grep -q "attach" "$CALLS"; then bad_t "S2 never attaches" "$(cat "$CALLS")"
else ok_t "S2 only capture/display calls: $(tr '\n' ';' <"$CALLS")"; fi

# S3 — no client, no resize.
w1=$(command tmux -S "$SOCK" display -p -t agent-swan '#{window_width}x#{window_height}')
c1=$(command tmux -S "$SOCK" list-clients -t agent-swan | wc -l)
if [[ "$c0" == 0 && "$c_mid" == 0 && "$c1" == 0 ]]; then ok_t "S3 tmux clients: before=$c0 after-capture=$c_mid at-end=$c1"
else bad_t "S3 tmux clients unchanged" "before=$c0 during=$c_mid after=$c1"; fi
if [[ "$w0" == "120x30" && "$w1" == "$w0" ]]; then ok_t "S3 session size unchanged: $w0 -> $w1"
else bad_t "S3 session size unchanged" "$w0 -> $w1"; fi

# S4 — text mode prints the frame raw.
JSON_MODE=0
out=$(run swan --screen); rc=$?
if (( rc == 0 )) && [[ "$out" == *$'\e['*31m*RED-MARKER* ]]; then ok_t "S4 text mode prints the coloured frame"
else bad_t "S4 text mode" "rc=$rc out=$(printf '%q' "$out")"; fi

# S5 — usage errors.
out=$(run swan --screen --follow); rc=$?
if (( rc == E_USAGE )); then ok_t "S5 --screen --follow is a usage error"; else bad_t "S5 --follow" "rc=$rc"; fi
out=$(run swan --screen --tmux); rc=$?
if (( rc == E_USAGE )); then ok_t "S5 --screen --tmux is a usage error"; else bad_t "S5 --tmux" "rc=$rc"; fi

# S6 — no session.
JSON_MODE=1
out=$(run heron --screen); rc=$?
if (( rc == E_NOT_RUNNING )); then ok_t "S6 a seat with no session fails E_NOT_RUNNING"
else bad_t "S6 no session" "rc=$rc out=$out"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
