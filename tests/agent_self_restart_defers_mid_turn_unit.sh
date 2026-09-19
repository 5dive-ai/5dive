#!/usr/bin/env bash
# `agent _self_restart` asks whether a TURN is in flight before it bounces the seat.
#
# THE DEFECT. `cmd_self_restart` is the primitive behind every restart a session can
# ask for itself — the telegram plugin's /model, /effort, /update, /resume and
# ho:restart all shell out to `sudo -n 5dive agent _self_restart`. It read no state
# at all: it fired `systemd-run --on-active=1 … systemctl restart` unconditionally.
# The ~1s deferral there is for the CLI CALL's own teardown (its comment says so),
# not for the agent's work. Measured 2026-09-15 08:50:02Z: a `/model` one second
# into a tool call bounced the unit, the call died with 137, its results were never
# written, and the human saw only the restart ack.
#
# Two ways the fix can be wrong, and they fail in OPPOSITE directions — every arm
# below is placed on one side or the other:
#
#   KILLS WORK   — the seat is mid-turn and gets bounced anyway. That is the bug.
#   NEVER FIRES  — the restart is deferred and then forgotten, so `/model` silently
#                  does nothing. Deferring must therefore QUEUE the durable marker
#                  DIVE-3173 already sweeps, not merely skip.
#
# AND THE DIRECTION IS DELIBERATELY NOT THE SWEEP'S. In `_pending_restart_sweep` the
# marker already exists, so every uncertain reading defers and waiting costs nothing.
# HERE an uncertain reading RESTARTS, because a wrong defer means an operator typed
# /restart on a box whose native signal is simply unavailable (a non-claude runtime,
# a `claude` too old for `agents --json`) and nothing visibly happened. Only a
# DEFINITE busy / blocked:* queues. Arms D and E pin that asymmetry.
#
# WHAT IS EXECUTED. The shipped `cmd_self_restart` body, extracted from
# src/cmd_agent_lifecycle.sh, and the shipped DIVE-3173 block from
# src/cmd_selfupdate.sh — real `_pending_restart_mark`, real `_pending_restart_sweep`,
# real `_pending_restart_decide` — against a temp state dir. `systemd-run` is a stub
# that records its argv, so "did it bounce the seat" is a file, not an inference.
# The MUTANT arms delete each half of the fix and must reproduce the bounce.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

TMP="$(mktemp -d /tmp/self-restart-mid-turn.XXXXXX)"
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; SRC=src

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---------------------------------------------------------------- the fixtures
# THE HOST IS NOT AN INPUT. Everything this harness reads or writes lives under
# $TMP: the pending-restart dir is repointed with PENDING_RESTART_DIR, the state
# dir with STATE_DIR, and the only `systemd-run` on PATH is the stub below. A
# runner with no /usr/local/bin/5dive, no /etc/5dive, no /var/lib/5dive and no
# sudo grant runs every arm — arm H2 asserts that rather than assuming it.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMD_RUN_CALLS"
STUB
chmod +x "$TMP/bin/systemd-run"
export SYSTEMD_RUN_CALLS="$TMP/systemd-run.calls"; : >"$SYSTEMD_RUN_CALLS"
export PATH="$TMP/bin:$PATH"
export PENDING_RESTART_DIR="$TMP/pending"

SELF_BODY="$(sed -n '/^cmd_self_restart()/,/^}/p' "$SRC/cmd_agent_lifecycle.sh")"
PR_BLOCK="$(sed -n '/^# >>> DIVE-3173 deferred restart for a busy agent/,/^# <<< DIVE-3173 deferred restart for a busy agent/p' \
  "$SRC/cmd_selfupdate.sh")"

if [[ -n "$SELF_BODY" ]] && grep -q 'systemd-run' <<<"$SELF_BODY"; then
  ok_t "cmd_self_restart is extractable from src/cmd_agent_lifecycle.sh"
else
  bad_t "cmd_self_restart not extractable" "the '^cmd_self_restart()' .. '^}' range came back empty or without the restart"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [[ -n "$PR_BLOCK" ]] && grep -q '_pending_restart_mark()' <<<"$PR_BLOCK"; then
  ok_t "the DIVE-3173 pending-restart block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "pending-restart block missing" "self-restart queues into THIS block; without it the arms below grade nothing"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# `require_root` and `require_agent` are SEAMED, and they are not what this file is
# about. require_root gates on $EUID (readonly; CI does not run as root) and
# require_agent reads the live registry — both host facts no stub in this file could
# reach, and a harness whose arms only run where the product is installed as root has
# not graded them. tests/agent_isolation_unit.sh owns those two guards and asserts
# they are still in the shipped body; arm W3 below re-asserts the same thing here, so
# the seam cannot hide their removal.
harness_env() {
  cat <<'PRELUDE'
set -uo pipefail
FIVE_ARGV=()
PRELUDE
  printf '. %q/src/lib/error_codes.sh\n' "$ROOT"
  printf '. %q/src/lib/output.sh\n' "$ROOT"
  # AFTER output.sh, which assigns JSON_MODE=0 at its top level — set before the
  # source and the prose arms and the json arms would grade the same mode.
  cat <<'PRELUDE'
JSON_MODE="${HARNESS_JSON_MODE:-0}"
require_root()  { :; }
require_agent() { :; }
PRELUDE
}

# run_self_restart <native-stdout> <native-rc> [extra-shell]
#   native-rc 1 with empty stdout is the "signal unavailable" reading.
#   extra-shell is evaluated last, so an arm can unset a helper to make it ABSENT.
run_self_restart() {
  local native_out="$1" native_rc="$2" extra="${3:-}"
  (
    eval "$(harness_env)"
    eval "$PR_BLOCK"
    _hb_agent_native_state() { printf '%s' "$NATIVE_OUT"; return "$NATIVE_RC"; }
    eval "$SELF_BODY"
    export NATIVE_OUT="$native_out" NATIVE_RC="$native_rc"
    export SUDO_USER="agent-carol"
    [[ -z "$extra" ]] || eval "$extra"
    cmd_self_restart
  )
}

reset_fixture() { rm -rf "$PENDING_RESTART_DIR"; : >"$SYSTEMD_RUN_CALLS"; }
calls()   { wc -l <"$SYSTEMD_RUN_CALLS" | tr -d ' '; }
marker()  { [[ -f "$PENDING_RESTART_DIR/carol" ]]; }

# --- A. a turn in flight is QUEUED, never bounced ----------------------------
reset_fixture
outA="$(run_self_restart busy 0 2>&1)"; rcA=$?
if [[ "$(calls)" == 0 ]]; then
  ok_t "A native 'busy' -> systemd-run is NOT called. THE DEFECT'S CELL: this is the bounce that killed the 09-15 turn"
else
  bad_t "A a mid-turn seat was bounced" "systemd-run calls: $(cat "$SYSTEMD_RUN_CALLS")"
fi
marker \
  && ok_t "A1 ...and the restart is QUEUED: the durable marker the DIVE-3173 sweep already reads exists" \
  || bad_t "A1 no marker written" "a deferral that leaves no record is the NEVER FIRES failure — /model would silently do nothing"
[[ "$(sed -n 's/^reason=//p' "$PENDING_RESTART_DIR/carol" 2>/dev/null)" == "self-restart asked mid-turn" ]] \
  && ok_t "A2 ...carrying its own reason, so the sweep's log line names WHY the bounce is owed" \
  || bad_t "A2 marker reason" "got [$(sed -n 's/^reason=//p' "$PENDING_RESTART_DIR/carol" 2>/dev/null)]"
[[ "$(sed -n 's/^marked_at=//p' "$PENDING_RESTART_DIR/carol" 2>/dev/null)" =~ ^[0-9]+$ ]] \
  && ok_t "A3 ...and a numeric stamp, which is what the 24h ceiling measures against" \
  || bad_t "A3 marker stamp" "a marker with no parseable stamp cannot be called overdue"
[[ "$outA" == *"queued"* && "$outA" == *"turn is in flight"* ]] \
  && ok_t "A4 the caller is TOLD it was queued, not told it restarted — the 09-15 human saw only a restart ack" \
  || bad_t "A4 prose does not say queued" "got [$outA]"
(( rcA == 0 )) \
  && ok_t "A5 ...and it is a SUCCESS, not an error: the request was accepted, just not executed yet" \
  || bad_t "A5 rc" "rc=$rcA — /model would report a failure for a request that was honoured"

# --- B. blocked:* is not idle either -----------------------------------------
reset_fixture
outB="$(run_self_restart 'blocked:permission prompt' 0 2>&1)"
if [[ "$(calls)" == 0 ]] && marker; then
  ok_t "B native 'blocked:permission prompt' queues too — a seat waiting on a prompt has a live turn behind it"
else
  bad_t "B a blocked seat was bounced" "calls=$(cat "$SYSTEMD_RUN_CALLS")"
fi
[[ "$outB" == *"queued"* ]] \
  && ok_t "B1 ...and says so" || bad_t "B1" "got [$outB]"

# --- C/D/E. NEVER FIRES: everything that is not a definite busy still restarts -
reset_fixture
run_self_restart idle 0 >/dev/null 2>&1
if [[ "$(calls)" == 1 ]] && ! marker; then
  ok_t "C native 'idle' -> exactly one systemd-run, no marker: today's path, byte for byte"
else
  bad_t "C an idle seat was not restarted" "calls=$(calls) marker=$(marker && echo yes || echo no) — the NEVER FIRES failure"
fi
reset_fixture
run_self_restart '' 1 >/dev/null 2>&1
if [[ "$(calls)" == 1 ]] && ! marker; then
  ok_t "D signal UNAVAILABLE (rc 1, no reading) -> restart. The opposite direction from the sweep, deliberately: a non-claude runtime must not lose /restart"
else
  bad_t "D an unreadable signal blocked the restart" "calls=$(calls) — every non-claude seat would silently stop honouring /model"
fi
reset_fixture
run_self_restart busy 0 'unset -f _hb_agent_native_state' >/dev/null 2>&1
if [[ "$(calls)" == 1 ]] && ! marker; then
  ok_t "E the helper ABSENT (a split tree, an older module set) -> restart, unchanged. The guard is declare -F, not a call into the void"
else
  bad_t "E an absent helper changed behaviour" "calls=$(calls) — a missing function must not be a silent policy change"
fi

# --- F. the JSON contract ----------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  reset_fixture
  jout="$(HARNESS_JSON_MODE=1 run_self_restart busy 0 2>/dev/null)"
  if [[ "$(jq -r '.data.queued' <<<"$jout" 2>/dev/null)" == "true" \
     && "$(jq -r '.data.deferred' <<<"$jout" 2>/dev/null)" == "true" \
     && "$(jq -r '.data.state' <<<"$jout" 2>/dev/null)" == "busy" ]]; then
    ok_t "F --json carries queued:true + the state that caused it, so a plugin can relay the real outcome instead of its own 'restarting' text"
  else
    bad_t "F json payload" "got [$jout]"
  fi
  reset_fixture
  jout2="$(HARNESS_JSON_MODE=1 run_self_restart idle 0 2>/dev/null)"
  [[ "$(jq -r '.data.queued // "absent"' <<<"$jout2" 2>/dev/null)" == "absent" ]] \
    && ok_t "F1 ...and the idle path's payload is unchanged — queued is absent, not false" \
    || bad_t "F1 idle payload changed" "got [$jout2]"
else
  bad_t "F jq is required by this harness" "jq is a documented dev dependency (CONTRIBUTING.md)"
fi

# --- G/H. a marker we cannot write REFUSES; it does not fall through ---------
# The two failures are not symmetric. A refusal is loud, immediate and costs one
# retry; falling through to systemd-run is the lost turn this whole file is about.
reset_fixture
: >"$TMP/not-a-dir"
outG="$(PENDING_RESTART_DIR="$TMP/not-a-dir/pending" run_self_restart busy 0 2>&1)"; rcG=$?
if [[ "$(calls)" == 0 ]]; then
  ok_t "G the marker cannot be written -> still NO bounce. Failing to record the debt must not become permission to kill the turn"
else
  bad_t "G unwritable marker fell through to the restart" "calls=$(cat "$SYSTEMD_RUN_CALLS")"
fi
(( rcG != 0 )) && [[ "$outG" == *"refusing"* ]] \
  && ok_t "G1 ...and it REFUSES loudly, naming the host-side remedy, instead of returning a success it did not perform" \
  || bad_t "G1 refusal" "rc=$rcG out=[$outG]"
reset_fixture
outH="$(run_self_restart busy 0 'unset -f _pending_restart_mark' 2>&1)"; rcH=$?
if [[ "$(calls)" == 0 ]] && (( rcH != 0 )); then
  ok_t "H the queue helper ABSENT on a busy seat -> refuse, not bounce (the fail-safe direction when we cannot queue)"
else
  bad_t "H absent queue helper bounced the seat" "calls=$(calls) rc=$rcH"
fi

# --- H2. THE HOST-PRISTINE CONTROL -------------------------------------------
# CI has no /usr/local/bin/5dive, no /etc/5dive, no /var/lib/5dive and no sudo
# grant. A predicate that short-circuits on one of those passes on a developer box
# and reds on the runner, so this is asserted, not assumed — both as a text property
# of the shipped block and by re-running arm A with the host stripped out.
if grep -qE '/usr/local/bin|/etc/5dive|/var/lib/5dive' <<<"$SELF_BODY"; then
  bad_t "H2 the shipped block names an absolute host path" \
        "$(grep -nE '/usr/local/bin|/etc/5dive|/var/lib/5dive' <<<"$SELF_BODY")"
else
  ok_t "H2 the shipped block reads no absolute host path — nothing here can short-circuit on what CI does not install"
fi
reset_fixture
(
  # PATH holds the stub and the base system only; STATE_DIR and the pending dir are
  # inside $TMP; and the three host paths are proved absent from this subshell's view
  # rather than merely unused.
  export PATH="$TMP/bin:/usr/bin:/bin"
  export STATE_DIR="$TMP/state"
  run_self_restart busy 0 >/dev/null 2>&1
)
if [[ "$(calls)" == 0 ]] && marker \
   && [[ "$(cd "$PENDING_RESTART_DIR" && pwd -P)" == "$(cd "$TMP" && pwd -P)"/* ]]; then
  ok_t "H2a ...and arm A reaches the same verdict on a stripped PATH with STATE_DIR inside the tempdir — every byte this harness touches is under \$TMP"
else
  bad_t "H2a the pristine control did not reproduce arm A" \
        "calls=$(calls) marker=$(marker && echo yes || echo no) dir=$PENDING_RESTART_DIR"
fi

# --- S. the SWEEP half: a queued restart cannot fire mid-turn either ----------
# The board is not the session. `_agent_busy_state` answers "does this seat hold an
# in_progress row", and the 09-15 seat held none — it was capturing an incident. The
# session reading is now an input to the verdict rather than a late guard inside the
# `fire` arm, which is what makes the 24h ceiling reachable for a session-busy seat.
sweep_with() { # <in_progress-rows> <_hb_agent_idle-rc> [marked-secs-ago]
  local _BUSY_ROWS="$1" idle_rc="$2" ago="${3:-0}"
  (
    eval "$(harness_env)"
    eval "$PR_BLOCK"
    RESTARTS="$TMP/sweep-restarts"
    systemctl() {
      case "${1:-}" in
        is-active) return 0 ;;
        show)      printf '\n' ;;
        restart)   printf '%s\n' "${2:-}" >>"$RESTARTS" ;;
        *)         return 0 ;;
      esac
    }
    # NOT named `n`: `_agent_busy_state` declares its own `local n` before calling
    # `db`, so a stub reading $n would read the CALLEE's empty local and every arm
    # would grade `unknown` (which defers) no matter what this one meant to inject.
    db(){ echo "$_BUSY_ROWS"; }; sqlq(){ printf '%s' "$1"; }
    _hb_agent_idle(){ return "$idle_rc"; }
    _pr_log(){ :; }
    if (( ago > 0 )); then
      mkdir -p "$PENDING_RESTART_DIR"
      printf 'marked_at=%s\nreason=self-restart asked mid-turn\n' "$(( $(date +%s) - ago ))" \
        >"$PENDING_RESTART_DIR/carol"
    fi
    _pending_restart_sweep
    printf 'fired=%s deferred=%s overdue=%s cleared=%s\n' \
      "$_PR_FIRED" "$_PR_DEFERRED" "$_PR_OVERDUE" "$_PR_CLEARED"
  )
}
mark_carol() {
  ( eval "$(harness_env)"; eval "$PR_BLOCK"; _pending_restart_mark carol "self-restart asked mid-turn" ) >/dev/null
}
RESTARTS="$TMP/sweep-restarts"

reset_fixture; mark_carol; : >"$RESTARTS"
outS="$(sweep_with 0 1)"
if [[ "$outS" == "fired=0 deferred=1 overdue=0 cleared=0" ]] && [[ ! -s "$RESTARTS" ]] && marker; then
  ok_t "S an IDLE BOARD with a busy SESSION defers and keeps the marker — a seat mid-turn with no claimed row is exactly the 09-15 case"
else
  bad_t "S a queued restart fired mid-turn" "sweep=[$outS] restarts=[$(tr '\n' ' ' <"$RESTARTS")]"
fi
reset_fixture; mark_carol; : >"$RESTARTS"
outS2="$(sweep_with 0 0)"
if [[ "$outS2" == "fired=1 deferred=0 overdue=0 cleared=0" ]] && grep -qx '5dive-agent@carol.service' "$RESTARTS"; then
  ok_t "S1 ...and once the session IS between turns the same marker fires the bounce (NEVER FIRES stays closed)"
else
  bad_t "S1 the queued restart never fired" "sweep=[$outS2] restarts=[$(tr '\n' ' ' <"$RESTARTS")]"
fi
reset_fixture; : >"$RESTARTS"
outS3="$(sweep_with 0 1 $((25 * 3600)))"
if [[ "$outS3" == "fired=0 deferred=1 overdue=1 cleared=0" ]] && [[ ! -s "$RESTARTS" ]]; then
  ok_t "S2 THE CEILING IS NOW REACHABLE for a session-busy seat: 25h owed reads OVERDUE (loud) and STILL does not force the bounce"
else
  bad_t "S2 overdue unreachable or lethal" "sweep=[$outS3] restarts=[$(tr '\n' ' ' <"$RESTARTS")] — held inside the fire arm this population was silent forever"
fi
reset_fixture; mark_carol; : >"$RESTARTS"
outS4="$(sweep_with 1 0)"
if [[ "$outS4" == "fired=0 deferred=1 overdue=0 cleared=0" ]] && [[ ! -s "$RESTARTS" ]]; then
  ok_t "S3 a BUSY BOARD still defers on its own, with no session reading needed — the DIVE-3173 predicate is untouched"
else
  bad_t "S3 the board predicate regressed" "sweep=[$outS4]"
fi

# ------------------------------------------------------------- wiring arms ---
# Every arm above grades extracted text. These grade that the SHIPPED tree is what
# was extracted, so the file cannot pass against dead code.
grep -q '_hb_agent_native_state' "$SRC/cmd_agent_lifecycle.sh" \
  && grep -q '_pending_restart_mark' "$SRC/cmd_agent_lifecycle.sh" \
  && ok_t "W1 the shipped cmd_agent_lifecycle.sh asks the native state and queues through the pending-restart marker" \
  || bad_t "W1 self-restart is still unconditional" "every arm above would be grading dead code"
# The session check must sit BEFORE the verdict, not inside `fire`. Held in `fire`
# it produced the same deferral but bypassed `_pending_restart_decide` entirely, so
# `overdue` could never be reached for a session-busy seat (arm S2).
if awk '/busy="\$\(_agent_busy_state "\$name"\)"/{i=1}
        i && /_hb_agent_idle/{h=1}
        i && /verdict="\$\(_pending_restart_decide/{exit !h}' "$SRC/cmd_selfupdate.sh"; then
  ok_t "W2 the sweep folds the session reading into the busy verdict BEFORE _pending_restart_decide runs"
else
  bad_t "W2 the session reading is not an input to the verdict" "back inside the fire arm, arm S2's ceiling is unreachable again"
fi
# The seams this harness installs (require_root / require_agent) must not be able to
# hide their removal from the shipped primitive. tests/agent_isolation_unit.sh owns
# these; they are re-asserted here because THIS file is the one that stubs them out.
if grep -q 'require_root' <<<"$SELF_BODY" && grep -q 'SUDO_USER' <<<"$SELF_BODY" \
   && grep -q 'takes no arguments' <<<"$SELF_BODY"; then
  ok_t "W3 the shipped primitive still requires root, still derives its target from SUDO_USER and still refuses argv (the two seams above cannot hide their loss)"
else
  bad_t "W3 a self-only guard disappeared" "this file stubs require_root/require_agent, so it must re-assert them"
fi
# The queue is only worth having if something sweeps it. Both callers, named.
grep -q '_pending_restart_sweep' "$SRC/cmd_heartbeat.sh" \
  && grep -q '_pending_restart_sweep' "$SRC/cmd_selfupdate.sh" \
  && ok_t "W4 the queue has its two independent sweepers (the heartbeat tick and self-update), so a queued self-restart is not waiting on one armed timer" \
  || bad_t "W4 nothing sweeps the queue" "a deferral nothing pays off is the NEVER FIRES failure"

# ---------------------------------------------------------------- MUTANT arms -
# Each mutant deletes one half of the fix and must reproduce the bounce. A strike-out
# assertion can pass vacuously, so M0/M2 first prove the mutation actually changed the
# text and still parses.
MUT_SELF="$TMP/self_mut.sh"
sed '/# >>> self-restart defers while a turn is in flight/,/# <<< self-restart defers while a turn is in flight/d' \
  <<<"$SELF_BODY" >"$MUT_SELF"
mdiff=$(diff <(printf '%s\n' "$SELF_BODY") "$MUT_SELF" | grep -c '^[<>]')
(( mdiff > 10 )) \
  && ok_t "M0 MUTANT 1 removes the whole in-flight check from cmd_self_restart ($mdiff diff lines)" \
  || bad_t "M0 mutation is a no-op" "diff lines=$mdiff — a mutant that changed nothing cannot go red"
bash -n "$MUT_SELF" && ok_t "M0a ...and the mutant is still valid bash" || bad_t "M0a mutant does not parse" ""
reset_fixture
(
  eval "$(harness_env)"
  eval "$PR_BLOCK"
  _hb_agent_native_state() { printf 'busy'; }
  . "$MUT_SELF"
  export SUDO_USER="agent-carol"
  cmd_self_restart
) >/dev/null 2>&1
if [[ "$(calls)" == 1 ]] && ! marker; then
  ok_t "M1 MUTANT 1 — arm A is RED on it: a seat reading 'busy' is bounced by systemd-run again. The 09-15 defect, live"
else
  bad_t "M1 mutant must reproduce the defect" "calls=$(calls) marker=$(marker && echo yes || echo no) — arm A is vacuous"
fi

MUT_PR="$TMP/pending_mut.sh"
perl -0pe 's/^    if \[\[ "\$busy" == "idle" \]\] \\\n.*?\n    fi\n//ms' <<<"$PR_BLOCK" >"$MUT_PR"
pdiff=$(diff <(printf '%s\n' "$PR_BLOCK") "$MUT_PR" | grep -c '^[<>]')
(( pdiff >= 4 )) \
  && ok_t "M2 MUTANT 2 removes the sweep's session reading, leaving the board-only verdict ($pdiff diff lines)" \
  || bad_t "M2 mutation is a no-op" "diff lines=$pdiff"
bash -n "$MUT_PR" && ok_t "M2a ...and the mutant is still valid bash" || bad_t "M2a mutant does not parse" ""
reset_fixture; mark_carol; : >"$RESTARTS"
outM="$(
  eval "$(harness_env)"
  . "$MUT_PR"
  RESTARTS="$TMP/sweep-restarts"
  systemctl() {
    case "${1:-}" in
      is-active) return 0 ;;
      show)      printf '\n' ;;
      restart)   printf '%s\n' "${2:-}" >>"$RESTARTS" ;;
      *)         return 0 ;;
    esac
  }
  db(){ echo 0; }; sqlq(){ printf '%s' "$1"; }
  _hb_agent_idle(){ return 1; }
  _pr_log(){ :; }
  _pending_restart_sweep
  printf 'fired=%s deferred=%s\n' "$_PR_FIRED" "$_PR_DEFERRED"
)"
if [[ "$outM" == "fired=1 deferred=0" ]] && grep -qx '5dive-agent@carol.service' "$RESTARTS"; then
  ok_t "M3 MUTANT 2 — arm S is RED on it: the board-only verdict bounces a mid-turn seat with no open row. Arm S is not vacuous"
else
  bad_t "M3 mutant must reproduce the defect" "sweep=[$outM] restarts=[$(tr '\n' ' ' <"$RESTARTS")]"
fi

echo
printf 'agent_self_restart_defers_mid_turn: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
