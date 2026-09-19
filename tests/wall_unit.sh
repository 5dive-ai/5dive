#!/usr/bin/env bash
# DIVE-4614 unit harness: `5dive wall`.
#
# The four properties this feature cannot lose, each with the defect that made
# it a property rather than a preference:
#
#   1. THE SEAT LIST COMES FROM THE REGISTRY. The host prototype hard-coded OUR
#      five seats; on a customer box the wall then comes up as six "no tmux
#      session" panes and reads as a dead fleet.
#   2. A PERMISSIONS FAILURE AND AN ABSENT SESSION ARE DIFFERENT ANSWERS. A
#      denied `sudo -u` exits non-zero EXACTLY like "no session", so an
#      uncontrolled probe renders a missing grant as an empty company. The probe
#      is positive-controlled; this harness grades the three-state, and grades
#      it in the direction that actually breaks (denied must NOT read as
#      no-session).
#   3. PANE MODES RESOLVE BEFORE THE JOIN-IF-EXISTS SHORTCUT. Backwards, a pane
#      respawned once `wall` exists execs `tmux attach -t wall`, nesting the
#      wall in its own pane; tmux refuses, the pane dies, the layout collapses.
#      It is a one-line reordering that reads like a no-op.
#   4. A GRID TOO SMALL IS REFUSED, NOT TRUNCATED. A seat you cannot see is the
#      exact failure the wall exists to prevent.
#
# WHY IT IS HERMETIC. Every seam this feature touches is somebody else's
# privilege: systemd, another user's tmux socket, sudo. A harness that used the
# real ones would grade the RUNNER's box — on this host `main` happens to hold an
# unrestricted runas and most seats do not, so the same arm would pass and fail
# by seat. `tmux`, `sudo`, `systemctl` and `registry_read` are therefore all
# stubbed, and section 5 is the one place a real tmux is touched (skipped, out
# loud, when there is none).
#
# Run: bash tests/wall_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/wall-unit.XXXXXX)"
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
export BOX_CONFIG="$STATE_DIR/box.json"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_wall.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }

# ---------------------------------------------------------------------------
echo "1. the grid: parse, default, and the refusal"
# ---------------------------------------------------------------------------
is "3x2 parses"                 "$(wall_parse_grid 3x2 2>/dev/null)"  "3 2"
is "10x4 parses (no cap)"       "$(wall_parse_grid 10x4 2>/dev/null)" "10 4"
wall_parse_grid "3" >/dev/null 2>&1;    is "a bare count is refused"   "$?" "2"
wall_parse_grid "3X2" >/dev/null 2>&1;  is "capital X is refused"      "$?" "2"
wall_parse_grid "0x2" >/dev/null 2>&1;  is "a zero dimension is refused" "$?" "2"
wall_parse_grid "" >/dev/null 2>&1;     is "empty is refused"          "$?" "2"

# The default lodar confirmed on the live wall, and the shape either side of it.
is "six seats default to 3x2"   "$(wall_default_grid 6)" "3 2"
is "five seats still get 3x2"   "$(wall_default_grid 5)" "3 2"
is "four seats get 3x2"         "$(wall_default_grid 4)" "3 2"
is "two seats do not pad to 3"  "$(wall_default_grid 2)" "2 1"
is "nine seats grow ROWS not columns" "$(wall_default_grid 9)" "3 3"
# The direction that matters: three columns is a ceiling, never exceeded.
_cols_ok=yes
for n in 1 2 3 4 5 6 7 8 12 16; do
  c=$(wall_default_grid "$n" | cut -d' ' -f1)
  (( c <= 3 )) || _cols_ok="n=$n gave $c"
done
is "the default never exceeds 3 columns" "$_cols_ok" "yes"

# ---------------------------------------------------------------------------
echo "2. wall_resolve_grid — a grid that hides a seat is REFUSED, not truncated"
# ---------------------------------------------------------------------------
is "an ample grid is taken as asked"  "$(wall_resolve_grid 6 4x2 2>/dev/null)" "4 2"
out=$(wall_resolve_grid 7 3x2 2>&1); rc=$?
is "3x2 with 7 seats exits 2"        "$rc" "2"
case "$out" in *"7 seats"*|*"1 seat"*) ok "the refusal names the shortfall" ;;
  *) bad "the refusal names the shortfall" "a message naming the seat count" "$out" ;; esac
# THE ARM THAT CATCHES A "FIX" THAT TRUNCATES: the answer must not be a grid.
case "$(wall_resolve_grid 7 3x2 2>/dev/null)" in
  "") ok "a refused grid prints NO grid on stdout (never a silent smaller wall)" ;;
  *)  bad "a refused grid prints no grid" "empty stdout" "$(wall_resolve_grid 7 3x2 2>/dev/null)" ;;
esac
is "no flag, no saved value -> the default" "$(wall_resolve_grid 6 2>/dev/null)" "3 2"

# Persistence: the operator's choice survives, and precedence is flag > saved.
printf '{"verify":"always"}\n' >"$BOX_CONFIG"
wall_save_grid 4 2
is "the saved grid is read back"      "$(wall_resolve_grid 6 2>/dev/null)" "4 2"
is "saving preserves the rest of box.json" "$(jq -r '.verify' "$BOX_CONFIG")" "always"
is "an explicit flag beats the saved value" "$(wall_resolve_grid 6 3x2 2>/dev/null)" "3 2"
printf '{"wall":{"grid":"nonsense"}}\n' >"$BOX_CONFIG"
is "a corrupt saved grid falls back to the default, it does not crash" \
   "$(wall_resolve_grid 6 2>/dev/null)" "3 2"
rm -f "$BOX_CONFIG"

# ---------------------------------------------------------------------------
echo "3. the seat list comes from the REGISTRY, not from our five names"
# ---------------------------------------------------------------------------
registry_read() {
  cat <<'JSON'
{"agents":{
  "alpha":{"type":"claude"},
  "bravo":{"type":"codex"},
  "charlie":{"type":"claude"},
  "delta":{"type":"claude"},
  "echo":{"type":"claude"}
}}
JSON
}
# Only bravo (codex, no TUI to mirror) and delta (unit down) are excluded.
_wall_unit_active() { [[ "$1" != "delta" ]]; }

seats=$(wall_registry_seats 6 | tr '\n' ' ')
is "claude seats with a running unit, in registry order" "$seats" "alpha charlie echo "
case "$seats" in *main*|*olivia*|*quinn*)
    bad "no hard-coded 5dive seat survives" "none of our seat names" "$seats" ;;
  *) ok "no hard-coded 5dive seat name appears" ;; esac
is "the cap is honoured"        "$(wall_registry_seats 2 | tr '\n' ' ')" "alpha charlie "
_wall_unit_active() { return 1; }
is "no running unit -> empty roster (not a default list)" "$(wall_registry_seats 6)" ""
# An unreadable registry must not invent seats either.
registry_read() { return 1; }
is "an unreadable registry yields nothing" "$(wall_registry_seats 6)" ""

# ---------------------------------------------------------------------------
echo "4. privilege: DENIED and NO-SESSION are different answers"
# ---------------------------------------------------------------------------
# The stub is the whole point. `sudo` here answers like a box WITHOUT the runas
# grant: the positive control (`true`) fails, and so would `tmux has-session` —
# which is the trap. An implementation that only asked about the session reads
# non-zero and says "no session", i.e. paints a permissions problem as a dead
# fleet.
id() { case "${1:-}" in -u) printf '1000' ;; -un) printf 'operator' ;; esac; }
sudo() {  # -n -u <user> <cmd...>
  local u=""; while (( $# )); do case "$1" in -n) shift ;; -u) u="$2"; shift 2 ;; *) break ;; esac; done
  case "$u" in
    agent-granted) case "${1:-}" in true) return 0 ;; tmux) return 0 ;; esac ;;
    agent-idle)    case "${1:-}" in true) return 0 ;; tmux) return 1 ;; esac ;;
    *)             return 1 ;;   # no runas at all: EVERYTHING fails, `true` included
  esac
  return 1
}
is "a reachable, running seat"        "$(wall_probe_seat granted)" "ok"
is "a reachable seat with no session" "$(wall_probe_seat idle)"    "no-session"
is "NO RUNAS IS 'denied', NOT 'no-session'" "$(wall_probe_seat nogrant)" "denied"
# The message a human reads has to say which of the two it was.
case "$(_wall_denied_help nogrant)" in
  *"NOT PERMITTED"*) ok "the pane text names a permissions problem" ;;
  *) bad "the pane text names a permissions problem" "NOT PERMITTED" "$(_wall_denied_help nogrant)" ;;
esac
case "$(_wall_denied_help nogrant)" in
  *"no tmux session"*) bad "the denied pane never says 'no tmux session'" "no such text" "it does" ;;
  *) ok "the denied pane never claims 'no tmux session'" ;;
esac
# Root needs no grant, and must not be told it lacks one.
id() { case "${1:-}" in -u) printf '0' ;; -un) printf 'root' ;; esac; }
sudo() { local u=""; while (( $# )); do case "$1" in -n) shift ;; -u) u="$2"; shift 2 ;; *) break ;; esac; done
         [[ "${1:-}" == "tmux" ]] && return 0; return 0; }
is "as root the probe never reports denied" "$(wall_probe_seat anyseat)" "ok"
unset -f id sudo

# ---------------------------------------------------------------------------
echo "5. PANE MODES BEFORE THE JOIN SHORTCUT — the regression arm"
# ---------------------------------------------------------------------------
# The defect, exactly: with a `wall` session ALREADY UP, a respawned pane runs
# `5dive wall --follow <seat>`. If the join-if-exists shortcut is reached first,
# that pane execs `tmux attach -t wall` and nests the wall inside its own pane.
# So the fixture says "the wall exists" for every has-session query and asserts
# what the pane actually attached to.
TMUXLOG="$TMP/tmux.log"
tmux() { printf '%s\n' "$*" >>"$TMUXLOG"; case "$1" in has-session) return 0 ;; esac; return 0; }
sudo() { local u=""; while (( $# )); do case "$1" in -n) shift ;; -u) u="$2"; shift 2 ;; *) break ;; esac; done
         printf 'AS:%s %s\n' "$u" "$*" >>"$TMUXLOG"; [[ "${1:-}" == "tmux" && "${2:-}" == "has-session" ]] && return 0; return 0; }
id() { case "${1:-}" in -u) printf '0' ;; -un) printf 'root' ;; esac; }
# One pass of the follow loop, then out.
sleep() { printf 'SLEEP %s\n' "$*" >>"$TMUXLOG"; exit 0; }
( cmd_wall --follow charlie ) >/dev/null 2>&1
log=$(cat "$TMUXLOG" 2>/dev/null)
case "$log" in
  *"AS:agent-charlie tmux attach -r -t agent-charlie"*)
     ok "--follow attaches READ-ONLY to the seat, with the wall already up" ;;
  *) bad "--follow attaches read-only to the seat" "attach -r -t agent-charlie" "$log" ;;
esac
case "$log" in
  *"attach -t wall"*) bad "--follow NEVER joins the wall (the nesting defect)" "no 'attach -t wall'" "$log" ;;
  *) ok "--follow never execs 'tmux attach -t wall' (the nesting defect stays fixed)" ;;
esac
# ...and the writable mode is reachable ONLY through its own flag.
: >"$TMUXLOG"
( cmd_wall --follow-rw charlie ) >/dev/null 2>&1
case "$(cat "$TMUXLOG")" in
  *"attach -t agent-charlie"*) ok "--follow-rw attaches WRITABLE (opt-in, one pane)" ;;
  *) bad "--follow-rw attaches writable" "attach -t agent-charlie" "$(cat "$TMUXLOG")" ;;
esac
case "$(cat "$TMUXLOG")" in
  *"attach -r"*) bad "--follow-rw is not silently read-only" "no -r" "$(cat "$TMUXLOG")" ;;
  *) ok "--follow-rw is genuinely writable, not a mislabelled read-only attach" ;;
esac
unset -f sleep

# ---------------------------------------------------------------------------
echo "5b. ERREXIT MUST NOT KILL A PANE — the seat-restart property"
# ---------------------------------------------------------------------------
# Found on the real-tmux acceptance run, not by reading. The bundle runs under
# header.sh's `set -euo pipefail`; the host prototype this feature came from ran
# under `set -uo pipefail`, so the difference had never been met. Every branch of
# the follow loop is a NON-ZERO EXIT THAT IS NORMAL — no session yet, no runas,
# tmux refusing the attach — and under errexit the FIRST one kills the pane,
# the pane takes its slot, and the layout collapses around a seat that merely
# restarted. Every pane died inside a second and the whole wall vanished.
#
# The arm drives the loop with errexit ON and a seat that is never attachable,
# and asserts the loop is still going on the third pass. A `set -e` regression
# stops it on the first.
cat >"$TMP/errexit_arm.sh" <<'ARM'
set -euo pipefail          # exactly what header.sh gives every bundle function
SRCDIR="$1"; COUNTFILE="$2"   # captured HERE: inside a stub, $1/$2 are the STUB's args
source "$SRCDIR/cmd_wall.sh"
id()   { case "${1:-}" in -u) printf '1000' ;; -un) printf 'operator' ;; esac; }
# The seat IS reachable and IS running — this drives the `ok` branch, which is
# where the pane actually died: the ATTACH is what fails (tmux refusing, the
# session vanishing between the probe and the attach — a seat restarting).
sudo() {
  while (( $# )); do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
  case "${1:-}:${2:-}" in
    true:*)            return 0 ;;
    tmux:has-session)  return 0 ;;
    tmux:attach)       return 1 ;;   # the normal, non-zero, NOT-fatal outcome
  esac
  return 1
}
clear() { :; }
_n=0
sleep() { _n=$((_n+1)); printf '%s
' "$_n" >"$COUNTFILE"; (( _n < 3 )) || exit 7; }
wall_watch_seat someseat
ARM
: >"$TMP/loops"
( bash "$TMP/errexit_arm.sh" "$PWD/$SRC" "$TMP/loops" ) >/dev/null 2>&1
armrc=$?
is "the follow loop survives repeated failure under set -e" "$(cat "$TMP/loops")" "3"
is "it is the arm that stops the loop, not errexit"          "$armrc" "7"

# A vacant slot must HOLD its slot and say what it is. A pane that exits takes
# its slot with it and the surviving panes reflow — which is the unreadable
# layout this feature was built to replace.
sleep() { exit 0; }   # one pass of the keep-alive loop
vac=$( wall_vacant_pane 4 2>&1 )
case "$vac" in *"VACANT SLOT"*) ok "a vacant pane names itself" ;;
  *) bad "a vacant pane names itself" "VACANT SLOT" "$vac" ;; esac
case "$vac" in *"5dive wall --follow"*) ok "a vacant pane says how to fill it without a restart" ;;
  *) bad "a vacant pane says how to fill it" "a respawn-pane line" "$vac" ;; esac
unset -f sleep

# ---------------------------------------------------------------------------
echo "6. the flag-ordering trap: a flag is never read as a seat name"
# ---------------------------------------------------------------------------
# `--rebuild` below `seats=("$@")` built a ONE-PANE wall titled "--rebuild".
# This grades the parse, which is where the bug lived, without building
# anything: the roster is the stub's, and the flags are gone from it.
: >"$TMUXLOG"
registry_read() { printf '{"agents":{"alpha":{"type":"claude"},"charlie":{"type":"claude"}}}\n'; }
_wall_unit_active() { return 0; }
tmux() { printf '%s\n' "$*" >>"$TMUXLOG"; case "$1" in has-session) return 1 ;; new-session|split-window) printf '%%%s\n' "$RANDOM" ;; esac; return 0; }
exec_guard() { :; }
( cmd_wall --rebuild --grid=2x1 ) >/dev/null 2>&1
log=$(cat "$TMUXLOG")
case "$log" in
  *"-T --rebuild"*|*"--follow --rebuild"*)
     bad "a flag is never titled as a seat" "no pane named --rebuild" "$log" ;;
  *) ok "--rebuild is consumed as a flag, never titled as a seat" ;;
esac
case "$log" in
  *"kill-session -t wall"*) ok "--rebuild tears the old wall down before laying it out" ;;
  *) bad "--rebuild kills the existing session" "kill-session -t wall" "$log" ;;
esac
case "$log" in
  *"-T alpha"*) ok "the registry seats are what get titled" ;;
  *) bad "the registry seats are titled" "-T alpha" "$log" ;;
esac

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
