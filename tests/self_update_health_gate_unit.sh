#!/usr/bin/env bash
# DIVE-4068: the update path grades the ARTIFACT and never the OUTCOME.
#
# 0.26.1 shipped a launcher that could not start any agent (DIVE-4067). It
# fetched, its sha256 matched, `bash -n` parsed it and its version went forwards
# — every check install.sh runs passed. The nightly then restarted every agent,
# and every box that took the release emptied itself and stayed empty until a
# human noticed. The one cheap question nobody asked was "does an agent still
# start on this box", and the box can answer it in about twenty seconds.
#
# The gate has to be wrong in one of two directions, and they are not symmetric:
#
#   BLIND      — the probe reads `active` on a unit that is crash-looping and
#                reports a pass. This is the original bug wearing a gate: the
#                unit is Type=simple, so a launcher that execs and dies one line
#                later IS active for the instant between them. A naive is-active
#                check is not a weaker version of this fix, it is the defect.
#   TRIGGER-   — the gate reverts a good release on a reading it merely could not
#   HAPPY        take, and the box then never accepts an update while that
#                reading stays broken. DIVE-3173 and DIVE-1095 both name the
#                silent-freeze direction as the worse of the two.
#
# So every arm below carries its NEGATIVE CONTROL — an arm that passes only
# because the gate does NOT fire on an unknown — and section 7 re-runs the
# decisive arms against MUTANTS that reproduce each pre-fix shape, so a green
# here cannot come from a test that would pass against the broken code too.
#
# Hermetic in the shape DIVE-2042/DIVE-3172/DIVE-3173/DIVE-4033 established: the
# block is extracted VERBATIM from src/cmd_selfupdate.sh between its fence
# markers and run as the SHIPPED BYTES. systemctl is a stub on $PATH; every file
# it touches is under $WORK. No unit, no agent and no /usr/local/bin is read or
# written.
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
eq_t(){ [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want '$3', got '$2'"; }

# ---------------------------------------------------------------- 1. extraction
block="$(sed -n '/^# >>> DIVE-4068 post-install health gate/,/^# <<< DIVE-4068 post-install health gate/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_hg_verdict()' <<<"$block" && grep -q '_hg_action()' <<<"$block" \
   && grep -q '_hg_capture()' <<<"$block" && grep -q '_hg_restore()' <<<"$block" \
   && grep -q '_hg_probe()' <<<"$block" && grep -q '_hg_artifact_moved()' <<<"$block"; then
  ok_t "the health-gate block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "health-gate block missing" "markers '# >>> / # <<< DIVE-4068 post-install health gate' not found, or a helper is outside the fence"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The gate is CALLED from cmd_self_update, and a fix that ships dormant is
# DIVE-1095's entire row. Grade the wiring, not just the helpers.
body="$(sed -n '/^cmd_self_update()/,/^}/p' src/cmd_selfupdate.sh)"
for sym in _hg_capture _hg_probe _hg_action _hg_restore _hg_artifact_moved _hg_rollback_note; do
  grep -q "$sym" <<<"$body" \
    && ok_t "cmd_self_update calls $sym — the gate is wired, not dormant" \
    || bad_t "$sym is never called from cmd_self_update" "the gate would ship inert (DIVE-1095)"
done
# The capture must precede the installer, or there is nothing left to restore.
cap_ln=$(grep -n '_hg_capture' <<<"$body" | head -n1 | cut -d: -f1)
up_ln=$(grep -n 'installer" --upgrade' <<<"$body" | head -n1 | cut -d: -f1)
if [[ -n "$cap_ln" && -n "$up_ln" ]] && (( cap_ln < up_ln )); then
  ok_t "the rollback point is captured BEFORE the installer runs"
else
  bad_t "capture does not precede the upgrade" "cap=$cap_ln upgrade=$up_ln — after --upgrade there is nothing left to snapshot"
fi

WORK="$(mktemp -d)"
eval "$block"

# ------------------------------------------------------- 2. _hg_verdict: truth
# THE ARM THIS ROW EXISTS FOR. Type=simple + RestartSec=3: a launcher that dies
# immediately is reported `active/running` on the very next poll, and only the
# NRestarts delta separates it from a healthy agent.
eq_t "crash-loop: active/running but systemd re-started it -> crash-loop" \
  "$(_hg_verdict active running 0 1)" crash-loop
eq_t "crash-loop is a DELTA, not a level: NRestarts 7 -> 7 is healthy" \
  "$(_hg_verdict active running 7 7)" healthy
eq_t "the launcher's permanent exits (2/3) park the unit -> failed" \
  "$(_hg_verdict failed "" 0 0)" failed
eq_t "healthy: active/running, counter still" \
  "$(_hg_verdict active running 3 3)" healthy
eq_t "inactive after a restart we issued -> down" \
  "$(_hg_verdict inactive dead 0 0)" down
# NEGATIVE CONTROLS — every one of these must NOT be an answer.
eq_t "NEGATIVE CONTROL: unreadable ActiveState -> unknown, never down" \
  "$(_hg_verdict "" "" "" "")" unknown
eq_t "NEGATIVE CONTROL: still activating when the window closed -> unknown" \
  "$(_hg_verdict activating start 0 0)" unknown
eq_t "NEGATIVE CONTROL: unreadable NRestarts on a running unit -> healthy, not crash-loop" \
  "$(_hg_verdict active running "" "")" healthy
eq_t "NEGATIVE CONTROL: garbage NRestarts is discarded, not parsed as a delta" \
  "$(_hg_verdict active running abc def)" healthy
# `failed` outranks the counter: a parked unit is broken whatever the delta says.
eq_t "failed wins over an unchanged counter" "$(_hg_verdict failed dead 2 2)" failed

# ---------------------------------------------- 3. _hg_action: the asymmetry
eq_t "healthy -> proceed"                "$(_hg_action healthy)"        proceed
eq_t "crash-loop -> rollback"            "$(_hg_action crash-loop)"     rollback
eq_t "failed -> rollback"                "$(_hg_action failed)"         rollback
eq_t "down -> rollback"                  "$(_hg_action down)"           rollback
eq_t "NEGATIVE CONTROL: unknown HALTS, it does not roll back (a release is not reverted on an unreadable box)" \
  "$(_hg_action unknown)" halt
# The two outcomes that deliberately do NOT halt. Each is here because halting
# would introduce a NEW fleet-wide failure in the name of preventing one.
eq_t "NEGATIVE CONTROL: restart-refused moves the canary role on — one stuck unit must not stop the nightly for the whole box" \
  "$(_hg_action restart-refused)" next-canary
eq_t "NEGATIVE CONTROL: not-a-canary moves the canary role on — an already-sick agent must not revert a good release for the whole box" \
  "$(_hg_action not-a-canary)" next-canary
eq_t "NEGATIVE CONTROL: gate-unavailable PROCEEDS — a box whose systemd answers nothing keeps updating exactly as it did before this gate existed" \
  "$(_hg_action gate-unavailable)" proceed
eq_t "NEGATIVE CONTROL: an unrecognised verdict halts rather than proceeding" \
  "$(_hg_action wat)" halt

# --------------------------------------------- 4. capture / restore round-trip
export HEALTH_GATE_BIN_DIR="$WORK/bin" HEALTH_GATE_SYSTEMD_DIR="$WORK/systemd"
export HEALTH_GATE_ROLLBACK_DIR="$WORK/rollback"
mkdir -p "$HEALTH_GATE_BIN_DIR" "$HEALTH_GATE_SYSTEMD_DIR"
printf 'GOOD-BUNDLE\n'   > "$HEALTH_GATE_BIN_DIR/5dive"
printf 'GOOD-LAUNCHER\n' > "$HEALTH_GATE_BIN_DIR/5dive-agent-start"
chmod 755 "$HEALTH_GATE_BIN_DIR/5dive" "$HEALTH_GATE_BIN_DIR/5dive-agent-start"
# The systemd template is deliberately ABSENT here — a box that has none must
# not have one conjured onto it by a rollback.
_hg_capture && ok_t "capture succeeds with the two binaries present and the unit template absent" \
             || bad_t "capture returned non-zero" "all three artifacts were readable or legitimately absent"
grep -q '^absent' "$HEALTH_GATE_ROLLBACK_DIR/manifest" \
  && ok_t "an absent artifact is RECORDED as absent, not silently skipped" \
  || bad_t "absent artifact not recorded" "$(cat "$HEALTH_GATE_ROLLBACK_DIR/manifest")"

# The bad release lands.
printf 'BAD-LAUNCHER\n' > "$HEALTH_GATE_BIN_DIR/5dive-agent-start"
printf 'NEW-BUNDLE\n'   > "$HEALTH_GATE_BIN_DIR/5dive"
_hg_artifact_moved "$HEALTH_GATE_BIN_DIR/5dive-agent-start"; m=$?
eq_t "_hg_artifact_moved sees the launcher move (exit 0)" "$m" 0
printf 'GOOD-LAUNCHER\n' > "$WORK/same"; cp "$WORK/same" "$HEALTH_GATE_BIN_DIR/5dive-agent-start"
_hg_artifact_moved "$HEALTH_GATE_BIN_DIR/5dive-agent-start"; m=$?
eq_t "NEGATIVE CONTROL: identical bytes are NOT a move (exit 1)" "$m" 1
printf 'BAD-LAUNCHER\n' > "$HEALTH_GATE_BIN_DIR/5dive-agent-start"
( HEALTH_GATE_ROLLBACK_DIR="$WORK/nope"; _hg_artifact_moved "$HEALTH_GATE_BIN_DIR/5dive-agent-start" )
m=$?
eq_t "NEGATIVE CONTROL: no manifest is UNKNOWN (exit 2), never 'unchanged' — the launcher-only probe must still run" "$m" 2

restored="$(_hg_restore | sort | paste -sd, -)"
eq_t "restore puts back exactly the two artifacts it captured" "$restored" "5dive,5dive-agent-start"
eq_t "the launcher is the pre-update bytes again" "$(cat "$HEALTH_GATE_BIN_DIR/5dive-agent-start")" GOOD-LAUNCHER
eq_t "the bundle is the pre-update bytes again"   "$(cat "$HEALTH_GATE_BIN_DIR/5dive")" GOOD-BUNDLE
[[ -x "$HEALTH_GATE_BIN_DIR/5dive-agent-start" ]] \
  && ok_t "the restored launcher is still executable (cp -p) — a 644 launcher is a dark box too" \
  || bad_t "restored launcher lost its mode" "$(stat -c %a "$HEALTH_GATE_BIN_DIR/5dive-agent-start")"
[[ -e "$HEALTH_GATE_SYSTEMD_DIR/5dive-agent@.service" ]] \
  && bad_t "restore CONJURED a unit template that never existed" "an absent artifact must stay absent" \
  || ok_t "NEGATIVE CONTROL: the absent unit template was not conjured by the restore"
( HEALTH_GATE_ROLLBACK_DIR="$WORK/nope"; _hg_restore >/dev/null 2>&1 ) \
  && bad_t "restore claimed success with no manifest" "it must report that it restored nothing" \
  || ok_t "NEGATIVE CONTROL: restore with no rollback point returns non-zero rather than claiming a rollback"

# ------------------------------------------------------- 5. _hg_watch / _hg_probe
# A systemctl stub whose answers are read from files, so an arm can make the
# unit crash-loop, park, or stay up without a single real unit.
mkdir -p "$WORK/bin2"
cat > "$WORK/bin2/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show) p="${3#--property=}"; cat "$SYSTEMCTL_FAKE/$p" 2>/dev/null; exit 0 ;;
  restart) [[ -f "$SYSTEMCTL_FAKE/refuse" ]] && exit 1
           [[ -f "$SYSTEMCTL_FAKE/on_restart" ]] && . "$SYSTEMCTL_FAKE/on_restart"
           exit 0 ;;
  daemon-reload|is-active) exit 0 ;;
esac
exit 0
STUB
chmod 755 "$WORK/bin2/systemctl"
PATH="$WORK/bin2:$PATH"; export PATH
export SYSTEMCTL_FAKE="$WORK/fake"; mkdir -p "$SYSTEMCTL_FAKE"
export HEALTH_GATE_WINDOW_SECS=0 HEALTH_GATE_POLL_SECS=1

# Writes the Id positive control alongside the state, because a real systemd
# always answers it. An arm that wants "systemd told us nothing" removes it.
set_unit(){ printf '%s\n' "$1" > "$SYSTEMCTL_FAKE/ActiveState"
            printf '%s\n' "$2" > "$SYSTEMCTL_FAKE/SubState"
            printf '%s\n' "$3" > "$SYSTEMCTL_FAKE/NRestarts"
            printf '5dive-agent@t.service\n' > "$SYSTEMCTL_FAKE/Id"; }

set_unit active running 0; rm -f "$SYSTEMCTL_FAKE/on_restart" "$SYSTEMCTL_FAKE/refuse"
eq_t "probe on a healthy unit -> healthy" "$(_hg_probe 5dive-agent@t.service)" healthy

# The DIVE-4067 shape: the restart succeeds, the unit is `active`, and systemd
# has already had to re-start it once.
set_unit active running 0
printf 'printf 1 > "$SYSTEMCTL_FAKE/NRestarts"\n' > "$SYSTEMCTL_FAKE/on_restart"
eq_t "probe on a launcher that dies and is re-started -> crash-loop (THE 0.26.1 shape)" \
  "$(_hg_probe 5dive-agent@t.service)" crash-loop

set_unit active running 0
printf 'printf failed > "$SYSTEMCTL_FAKE/ActiveState"\n' > "$SYSTEMCTL_FAKE/on_restart"
eq_t "probe on a launcher exiting 2/3 (RestartPreventExitStatus) -> failed" \
  "$(_hg_probe 5dive-agent@t.service)" failed

rm -f "$SYSTEMCTL_FAKE/on_restart"; set_unit active running 0
: > "$SYSTEMCTL_FAKE/refuse"
eq_t "NEGATIVE CONTROL: systemctl refusing the restart -> restart-refused (never a rollback)" \
  "$(_hg_probe 5dive-agent@t.service)" restart-refused
rm -f "$SYSTEMCTL_FAKE/refuse"

# THE POSITIVE CONTROL. Without it "systemd told us nothing" and "the unit is in
# a state I cannot classify" are the same empty string, and the gate would halt
# the nightly on every box with an uninterrogable systemd — permanently, and for
# a reason nobody would trace back to this row. `Id` is what separates them.
# `unknown` is reached through the POST-restart path: the unit was a fine
# instrument going in, and afterwards we cannot classify what came back. That is
# the reading that HALTS the pass without reverting anything.
set_unit active running 0
printf 'printf activating > "$SYSTEMCTL_FAKE/ActiveState"\n' > "$SYSTEMCTL_FAKE/on_restart"
eq_t "still activating when the window closed -> unknown (halts): a reading we cannot classify is never a pass" \
  "$(_hg_probe 5dive-agent@t.service)" unknown
set_unit active running 0
printf 'printf "" > "$SYSTEMCTL_FAKE/ActiveState"\n' > "$SYSTEMCTL_FAKE/on_restart"
eq_t "the state going unreadable AFTER the restart -> unknown, not down (down would revert the release)" \
  "$(_hg_probe 5dive-agent@t.service)" unknown
rm -f "$SYSTEMCTL_FAKE/on_restart"
set_unit active running 0
rm -f "$SYSTEMCTL_FAKE"/{Id,ActiveState,SubState,NRestarts}
eq_t "systemd answering NOTHING -> gate-unavailable, which PROCEEDS — not 'unknown', which would freeze the box off updates" \
  "$(_hg_probe 5dive-agent@t.service)" gate-unavailable
set_unit active running 0
eq_t "the control does not swallow the measurement: with Id back, a healthy unit still grades healthy" \
  "$(_hg_probe 5dive-agent@t.service)" healthy

# _hg_watch must not answer on the FIRST healthy reading — "it started" is not
# the question. With a window it keeps looking, and a unit that dies late is
# still caught.
set_unit active running 0
HEALTH_GATE_WINDOW_SECS=2 HEALTH_GATE_POLL_SECS=1
( sleep 1; printf 4 > "$SYSTEMCTL_FAKE/NRestarts" ) &
w=$(_hg_watch 5dive-agent@t.service 0); wait 2>/dev/null
eq_t "watch keeps looking past the first healthy reading — a unit that dies at t+1s is still caught" "$w" crash-loop
HEALTH_GATE_WINDOW_SECS=0

# ------------------------------------- 5b. the canary has to be a usable instrument
# A false ROLLBACK is the one way this row can make a night worse than it found
# it: an agent already crash-looping before the update is byte-for-byte
# indistinguishable from a release that broke the box, and believing it reverts a
# good release for every agent on the box. `--state=running` does not settle it —
# a unit re-started every 3s IS running at the instant it is enumerated.
export HEALTH_GATE_PRECHECK_SECS=1
set_unit active running 5
_hg_canary_ok 5dive-agent@t.service \
  && ok_t "a steady active/running unit is a usable canary" \
  || bad_t "a steady unit was rejected as a canary" "the gate would skip every valid canary"

set_unit activating start 0
_hg_canary_ok 5dive-agent@t.service \
  && bad_t "a unit that is not active/running was accepted as a canary" "it cannot answer a question about the release" \
  || ok_t "a unit not active/running before the update is NOT a canary"

# THE ARM. The unit reads active/running at both samples, but systemd re-started
# it between them: it was ALREADY looping before the update touched anything.
set_unit active running 5
( sleep 1; printf 6 > "$SYSTEMCTL_FAKE/NRestarts" ) &
if _hg_canary_ok 5dive-agent@t.service; then
  bad_t "an ALREADY crash-looping unit was accepted as a canary" "the gate would blame the release and roll back a good one"
else
  ok_t "an already crash-looping unit is rejected as a canary (a false rollback is the worst outcome this row has)"
fi
wait 2>/dev/null

# NEGATIVE CONTROL: being stricter on an unreadable counter would disqualify every
# canary on a systemd too old to report NRestarts.
printf 'active\n' > "$SYSTEMCTL_FAKE/ActiveState"; printf 'running\n' > "$SYSTEMCTL_FAKE/SubState"
printf '5dive-agent@t.service\n' > "$SYSTEMCTL_FAKE/Id"; : > "$SYSTEMCTL_FAKE/NRestarts"
_hg_canary_ok 5dive-agent@t.service \
  && ok_t "NEGATIVE CONTROL: an unreadable NRestarts does not disqualify a canary" \
  || bad_t "an unreadable counter disqualified a healthy canary" "no canary would ever be usable on an older systemd"

# And the probe must NOT restart a unit it has just declared unusable.
set_unit active running 5
printf 'printf RESTARTED > "$SYSTEMCTL_FAKE/didrestart"\n' > "$SYSTEMCTL_FAKE/on_restart"
rm -f "$SYSTEMCTL_FAKE/didrestart"
( sleep 1; printf 6 > "$SYSTEMCTL_FAKE/NRestarts" ) &
v="$(_hg_probe 5dive-agent@t.service)"; wait 2>/dev/null
eq_t "probe on an already-looping unit -> not-a-canary" "$v" not-a-canary
[[ -e "$SYSTEMCTL_FAKE/didrestart" ]] \
  && bad_t "the probe restarted a unit it had already rejected" "the caller does the ordinary restart; the probe must not double-bounce it" \
  || ok_t "the probe does NOT restart a unit it rejected — the caller's ordinary restart is the only bounce"
rm -f "$SYSTEMCTL_FAKE/on_restart"; unset HEALTH_GATE_PRECHECK_SECS
set_unit active running 0

# ------------------------------------------------------------- 6. the loud line
note="$(_hg_rollback_note dev crash-loop 5dive,5dive-agent-start)"
for want in dev crash-loop 5dive-agent-start RESTORED; do
  grep -qi -- "$want" <<<"$note" && ok_t "the rollback line names '$want'" \
    || bad_t "rollback line omits '$want'" "$note"
done
grep -qi 'no other agent was touched' <<<"$note" \
  && ok_t "the rollback line states the blast radius" || bad_t "blast radius not stated" "$note"

# ------------------------------------------------------------------ 7. MUTANTS
# Each mutant reproduces a PRE-FIX shape, not a deleted call. A mutant that
# survives means the arms above would have passed against the broken gate too.
# The helper asserts the mutation ACTUALLY APPLIED before grading it — a sed that
# silently matched nothing would otherwise print "killed" for an unmutated block,
# which is the harness lying about its own reach.
mut(){ # <name> <sed-expr> <arm>
  local name="$1" expr="$2" arm="$3" mutated out
  mutated="$(sed "$expr" <<<"$block")"
  if [[ "$mutated" == "$block" ]]; then
    bad_t "MUTATION DID NOT APPLY — $name" "sed '$expr' matched nothing; this arm graded the SHIPPED block, not a mutant"
    return
  fi
  out="$(bash -c "$mutated
$arm" 2>&1 | tail -n1)"
  [[ "$out" == "MUTANT-CAUGHT" ]] && ok_t "MUTANT KILLED — $name" \
    || bad_t "MUTANT SURVIVED — $name" "arm returned '$out'"
}

# M1: the naive gate — read is-active and ignore the restart counter. This IS the
# blind check that would have reported 0.26.1 as a clean install.
mut "a verdict that ignores NRestarts calls a crash-looping unit healthy" \
    's/&& (( after > before ))/\&\& false/' \
    '[[ "$(_hg_verdict active running 0 1)" == healthy ]] && echo MUTANT-CAUGHT'

# M2: unknown folded into proceed — the mass restart continues across a box
# nobody could read.
mut "an unknown verdict that PROCEEDS lets the loop restart the rest of the fleet" \
    "/printf 'halt/s/halt/proceed/" \
    '[[ "$(_hg_action unknown)" == proceed ]] && echo MUTANT-CAUGHT'

# M3: unknown folded into rollback — the silent-freeze direction DIVE-3173 and
# DIVE-1095 both name as the worse one.
mut "an unknown verdict that ROLLS BACK reverts a good release on an unreadable box" \
    "/printf 'halt/s/halt/rollback/" \
    '[[ "$(_hg_action unknown)" == rollback ]] && echo MUTANT-CAUGHT'

# M4: the absent/present status ignored — a restore conjures a unit template that
# never existed on this box.
mkdir -p "$WORK/m4/bin" "$WORK/m4/sysd"
printf 'B\n' > "$WORK/m4/bin/5dive"; printf 'L\n' > "$WORK/m4/bin/5dive-agent-start"
export M4_BIN="$WORK/m4/bin" M4_SYSD="$WORK/m4/sysd" M4_RB="$WORK/m4/rb"
mut "a restore that ignores the absent/present status conjures files that never existed" \
    '/== "present"/d' \
    'export HEALTH_GATE_BIN_DIR="$M4_BIN" HEALTH_GATE_SYSTEMD_DIR="$M4_SYSD" HEALTH_GATE_ROLLBACK_DIR="$M4_RB"
     _hg_capture >/dev/null 2>&1
     printf X > "$HEALTH_GATE_SYSTEMD_DIR/5dive-agent@.service"
     _hg_restore >/dev/null 2>&1
     [[ -e "$HEALTH_GATE_SYSTEMD_DIR/5dive-agent@.service" ]] && echo MUTANT-CAUGHT'

# M5: a missing manifest answering "unchanged" — the launcher-only night is never
# probed, which is precisely the night 0.26.1 shipped on.
mut "a missing manifest that answers 'unchanged' skips the launcher-only probe" \
    '/-n "$line" /s/return 2/return 1/' \
    'HEALTH_GATE_ROLLBACK_DIR=/nonexistent-hg-rb; _hg_artifact_moved /bin/sh; [[ $? -eq 1 ]] && echo MUTANT-CAUGHT'

# M6: the positive control removed — an uninterrogable systemd becomes
# indistinguishable from a sick unit and every such box halts its nightly
# forever. This mutant is the shape of a SAFETY CHECK causing the outage, which
# is the one way this row could make things worse than it found them.
mut "dropping the Id positive control makes an unreadable systemd halt the nightly" \
    '/-z "$(_hg_unit_field "$unit" Id)"/s/-z/-n/' \
    'export SYSTEMCTL_FAKE PATH HEALTH_GATE_WINDOW_SECS=0
     rm -f "$SYSTEMCTL_FAKE"/{Id,ActiveState,SubState,NRestarts}
     [[ "$(_hg_action "$(_hg_probe 5dive-agent@t.service)")" != proceed ]] && echo MUTANT-CAUGHT'

# M7: the canary pre-check dropped — an agent that was already crash-looping
# before the update is believed, and the gate reverts a good release for the
# whole box. The FALSE ROLLBACK direction.
mut "dropping the canary pre-check lets an already-sick agent revert a good release" \
    '/if ! _hg_canary_ok "$unit"; then/,+2d' \
    'export SYSTEMCTL_FAKE PATH HEALTH_GATE_WINDOW_SECS=0
     printf active > "$SYSTEMCTL_FAKE/ActiveState"; printf running > "$SYSTEMCTL_FAKE/SubState"
     printf "5dive-agent@t.service" > "$SYSTEMCTL_FAKE/Id"; printf 5 > "$SYSTEMCTL_FAKE/NRestarts"
     printf %s "printf 6 > \"\$SYSTEMCTL_FAKE/NRestarts\"" > "$SYSTEMCTL_FAKE/on_restart"
     [[ "$(_hg_action "$(_hg_probe 5dive-agent@t.service)")" == rollback ]] && echo MUTANT-CAUGHT'

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
