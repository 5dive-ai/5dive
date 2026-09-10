#!/usr/bin/env bash
# TIER: nightly — 17.2s measured (CI installed-host shard 2, run 34526078130, 2026-09-10): shard 2
#   drew 296s of the 300s core cap, so this file is the largest line item in the shard nearest the
#   ceiling; it does not fit the 300s PR core and the nightly sweep runs it unchanged (DIVE-4250).
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
  daemon-reload) printf 'daemon-reload\n' >> "$SYSTEMCTL_FAKE/cmd.log"; exit 0 ;;
  is-active) exit 0 ;;
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

# ------------------------------------------ 6b. the reload after a template revert
# `_hg_restore` is the only thing that puts the unit template back, and systemd
# does not re-read a template on its own. Without the reload the box is running
# the ExecStart it just reverted, which is a rollback that did not roll back.
# Graded by OBSERVING the call, not by reading the line.
set_unit active running 0; rm -f "$SYSTEMCTL_FAKE/on_restart" "$SYSTEMCTL_FAKE/refuse"
export DR_BIN="$WORK/dr/bin" DR_SYSD="$WORK/dr/sysd" DR_RB="$WORK/dr/rb" DR_RB2="$WORK/dr/rb2"
mkdir -p "$DR_BIN" "$DR_SYSD"
printf 'B\n' > "$DR_BIN/5dive"; printf 'L\n' > "$DR_BIN/5dive-agent-start"
printf 'UNIT-OLD\n' > "$DR_SYSD/5dive-agent@.service"
(
  export HEALTH_GATE_BIN_DIR="$DR_BIN" HEALTH_GATE_SYSTEMD_DIR="$DR_SYSD" HEALTH_GATE_ROLLBACK_DIR="$DR_RB"
  _hg_capture >/dev/null 2>&1
  printf 'UNIT-NEW\n' > "$HEALTH_GATE_SYSTEMD_DIR/5dive-agent@.service"
  rm -f "$SYSTEMCTL_FAKE/cmd.log"
  _hg_restore >/dev/null 2>&1
)
eq_t "the reverted unit template is the pre-update bytes again" "$(cat "$DR_SYSD/5dive-agent@.service")" UNIT-OLD
grep -q daemon-reload "$SYSTEMCTL_FAKE/cmd.log" 2>/dev/null \
  && ok_t "restoring the unit template is followed by an observed 'systemctl daemon-reload'" \
  || bad_t "no daemon-reload after the template revert" "systemd would keep running the ExecStart the rollback just removed"

# --------------------------- 6c. the SECOND sample is load-bearing, not redundant
# The counter-delta check catches a unit looping across the two samples. It does
# NOT catch one that stops being a usable instrument between them with the
# counter still — active/running then `failed`, no re-start in between. That unit
# cannot answer a question about the release either.
export HEALTH_GATE_PRECHECK_SECS=1
set_unit active running 5
( sleep 1; printf 'failed\n' > "$SYSTEMCTL_FAKE/ActiveState" ) &
if _hg_canary_ok 5dive-agent@t.service; then
  bad_t "a unit that left active/running between the two samples was accepted as a canary" "the counter never moved, so only the second sample can reject it"
else
  ok_t "a unit that leaves active/running between the two samples is rejected as a canary"
fi
wait 2>/dev/null
unset HEALTH_GATE_PRECHECK_SECS
set_unit active running 0

# =========================================================== 8. THE WIRING, RUN
# Everything above grades the HELPERS. The helpers are not what holds the blast
# radius — `cmd_self_update`'s restart loop is, and up to here that loop was
# graded by grepping its body for symbol names. A gate that is CALLED and whose
# verdict is then ignored satisfies every one of those greps, so the exact defect
# this row exists to prevent could ship green: the loop reads `crash-loop` and
# restarts the rest of the fleet anyway. That is the row's own asymmetry — the
# artifact graded, the outcome not — turned on the fix.
#
# So the loop is EXECUTED here, verbatim from src/cmd_selfupdate.sh, against the
# same kind of systemctl stub, on a fake box with three agents whose FIRST one
# dies on the new launcher. What is asserted is behaviour, not messages:
#   (a) exactly one agent is ever restarted — agents two and three are untouched;
#   (b) the bytes on disk afterwards are the PRE-upgrade bytes;
#   (c) the command exits non-zero.
# Nothing is stubbed between the verdict and those three: `_hg_probe`,
# `_hg_action`, the loop's break and the post-loop rollback all run for real.
cmdbody="$(sed -n '/^cmd_self_update()/,/^}/p' src/cmd_selfupdate.sh)"
if [[ -n "$cmdbody" ]] && grep -q '_hg_probe' <<<"$cmdbody" && [[ "$(tail -n1 <<<"$cmdbody")" == "}" ]]; then
  ok_t "cmd_self_update is extractable from src/cmd_selfupdate.sh as shipped bytes"
else
  bad_t "cmd_self_update not extractable" "the wiring arms below would grade nothing"
fi

# hg_loop <tag> <sed-expr|""> <new-launcher-bytes> [restart-needed-rc] [busy-csv] [parked-csv]
#   Runs the shipped (or mutated) cmd_self_update on a three-agent fake box and
#   writes: $d/rc, $d/out, $d/fake/restart.log, $d/bin/*.
#
#   `restart-needed-rc` is what `_agent_restart_needed` returns. Iteration 3: it
#   was hard-wired to 0, so EVERY arm ran the path where a payload fingerprint
#   moved — and the post-loop launcher-only block, which is the branch that would
#   have caught 0.26.1, was entered by no arm in the repo. Pass 1 for a night on
#   which nobody needs a restart. `busy-csv`/`parked-csv` are the names
#   `_agent_busy_state`/`_agent_is_parked` report as not-idle and parked, so the
#   candidate loop's own guards are reachable too.
hg_loop(){
  local tag="$1" expr="$2" newl="$3" rcneed="${4:-0}" busylist="${5:-}" parkedlist="${6:-}" rbdir="${7:-}" deathmode="${8:-crash}" dying="${9:-a1}" unsteady="${10:-}" mutated d
  d="$WORK/loop-$tag"
  rm -rf "$d"; mkdir -p "$d/bin" "$d/sysd" "$d/sbin" "$d/fake/u" "$d/homes"
  local u n
  : > "$d/fake/units"
  for n in a1 a2 a3; do
    u="5dive-agent@$n.service"
    mkdir -p "$d/fake/u/$u"
    printf '%s\n' "$u" >> "$d/fake/units"
    printf 'active\n'  > "$d/fake/u/$u/ActiveState"
    printf 'running\n' > "$d/fake/u/$u/SubState"
    printf '0\n'       > "$d/fake/u/$u/NRestarts"
    printf '%s\n' "$u" > "$d/fake/u/$u/Id"
  done
  # Only a1 is wired to the launcher on disk: it dies (and systemd re-starts it)
  # while the BAD launcher is installed, and comes back once the good one is
  # restored. The unit's behaviour is a FUNCTION of the artifact, so a rollback
  # that does not actually replace the bytes cannot read as a recovery.
  for n in ${unsteady//,/ }; do printf 'activating\n' > "$d/fake/u/5dive-agent@$n.service/ActiveState"; done
  cat > "$d/fake/u/5dive-agent@$dying.service/on_restart" <<'ORS'
if grep -q BAD "$HG_BIN/5dive-agent-start" 2>/dev/null; then
  n="$(cat "$FK/u/$UNIT/NRestarts" 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$((n + 1))" > "$FK/u/$UNIT/NRestarts"
fi
ORS
  # `blind`: the unit does not crash, systemd just stops answering about it after
  # the bounce. That is the UNKNOWN verdict, and it must HALT without reverting —
  # absence of evidence of health is not evidence of breakage. Id stays readable,
  # which is the positive control that separates the two.
  if [[ "$deathmode" == "blind" ]]; then
    cat > "$d/fake/u/5dive-agent@$dying.service/on_restart" <<'ORS2'
: > "$FK/u/$UNIT/ActiveState"
: > "$FK/u/$UNIT/SubState"
: > "$FK/u/$UNIT/NRestarts"
ORS2
  fi
  cat > "$d/sbin/systemctl" <<'STUB2'
#!/usr/bin/env bash
FK="$SYSTEMCTL_FAKE"
case "$1" in
  list-units)    cat "$FK/units" 2>/dev/null; exit 0 ;;
  show)          cat "$FK/u/$2/${3#--property=}" 2>/dev/null; exit 0 ;;
  restart)       printf '%s\n' "$2" >> "$FK/restart.log"
                 [[ -f "$FK/u/$2/on_restart" ]] && UNIT="$2" . "$FK/u/$2/on_restart"
                 exit 0 ;;
  daemon-reload) printf 'daemon-reload\n' >> "$FK/cmd.log"; exit 0 ;;
  is-active)     exit 0 ;;
esac
exit 0
STUB2
  # The installer is what the update path actually runs; here it lands the
  # release under test onto the same bin dir the gate captured.
  cat > "$d/sbin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] || exit 1
cat > "$out" <<'INS'
#!/usr/bin/env bash
printf '%s\n' "$HG_NEW_LAUNCHER" > "$HG_BIN/5dive-agent-start"
printf 'NEW-BUNDLE\n'            > "$HG_BIN/5dive"
chmod 755 "$HG_BIN/5dive-agent-start" "$HG_BIN/5dive"
INS
exit 0
CURL
  chmod 755 "$d/sbin/systemctl" "$d/sbin/curl"
  printf 'GOOD-BUNDLE\n'   > "$d/bin/5dive"
  printf 'GOOD-LAUNCHER\n' > "$d/bin/5dive-agent-start"
  chmod 755 "$d/bin/5dive" "$d/bin/5dive-agent-start"

  mutated="$cmdbody"
  if [[ -n "$expr" ]]; then
    mutated="$(sed "$expr" <<<"$cmdbody")"
    if [[ "$mutated" == "$cmdbody" ]]; then printf 'MUTATION-DID-NOT-APPLY\n' > "$d/rc"; return; fi
  fi
  {
    cat <<'PRELUDE'
set -uo pipefail
E_GENERIC=1; E_USAGE=2; E_NOT_FOUND=3
step(){ printf 'step: %s\n' "$*"; }
warn(){ printf 'warn: %s\n' "$*"; }
ok(){   printf 'ok: %s\n'   "$1"; return 0; }
fail(){ printf 'fail: %s\n' "${2:-}"; exit "${1:-1}"; }
json_array(){ printf '[]\n'; }
gh_org(){ printf '5dive-ai\n'; }
_PR_FIRED=0; _PR_PARKED=0
_pending_restart_sweep(){ return 0; }
_pending_restart_mark(){ return 0; }
_agent_home(){ printf '%s/%s\n' "$HG_HOMES" "${1:-}"; }
_agent_payload_fingerprint(){ printf 'fp\n'; }
agent_type(){ printf 'claude\n'; }
_hg_in_list(){ case ",${2:-}," in *",${1:-},"*) return 0 ;; esac; return 1; }
_agent_is_parked(){ _hg_in_list "${1:-}" "${HG_PARKED:-}"; }
_parked_override_note(){ printf 'agent %s is parked\n' "${1:-}"; }
_agent_restart_needed(){ return "${HG_RESTART_NEEDED_RC:-0}"; }
_agent_busy_state(){ _hg_in_list "${1:-}" "${HG_BUSY:-}" && printf 'busy\n' || printf 'idle\n'; }
_team_bot_install_listener(){ return 0; }
PRELUDE
    printf '%s\n' "$block"
    printf '%s\n' "$mutated"
    printf 'cmd_self_update\n'
  } > "$d/driver.sh"

  (
    export PATH="$d/sbin:$PATH"
    export SYSTEMCTL_FAKE="$d/fake" HG_BIN="$d/bin" HG_HOMES="$d/homes" HG_NEW_LAUNCHER="$newl"
    export HG_RESTART_NEEDED_RC="$rcneed" HG_BUSY="$busylist" HG_PARKED="$parkedlist"
    export HEALTH_GATE_BIN_DIR="$d/bin" HEALTH_GATE_SYSTEMD_DIR="$d/sysd" HEALTH_GATE_ROLLBACK_DIR="${rbdir:-$d/rb}"
    export HEALTH_GATE_WINDOW_SECS=0 HEALTH_GATE_POLL_SECS=1 HEALTH_GATE_PRECHECK_SECS=0
    bash "$d/driver.sh" > "$d/out" 2>&1
    printf '%s\n' "$?" > "$d/rc"
  )
}
hg_restarted_units(){ sort -u "$WORK/loop-$1/fake/restart.log" 2>/dev/null | paste -sd, -; }

# --- the bad release, on the shipped loop -----------------------------------
hg_loop shipped "" BAD-LAUNCHER
d="$WORK/loop-shipped"
eq_t "(c) a release that kills the first agent makes self-update EXIT NON-ZERO" \
  "$( [[ "$(cat "$d/rc" 2>/dev/null)" == 0 ]] && echo zero || echo non-zero )" non-zero
eq_t "(a) BLAST RADIUS: exactly one agent was ever restarted — agents two and three were never touched" \
  "$(hg_restarted_units shipped)" 5dive-agent@a1.service
eq_t "(b) the launcher on disk afterwards is the PRE-upgrade one — the box was rolled back, not just warned about" \
  "$(cat "$d/bin/5dive-agent-start" 2>/dev/null)" GOOD-LAUNCHER
eq_t "(b) the bundle on disk afterwards is the PRE-upgrade one" \
  "$(cat "$d/bin/5dive" 2>/dev/null)" GOOD-BUNDLE
grep -qi 'HEALTH GATE FAILED' "$d/out" \
  && ok_t "the operator gets the loud rollback line, not a quiet box" \
  || bad_t "no rollback line in the output" "$(tail -n3 "$d/out")"
grep -qi 'running again on the restored build' "$d/out" \
  && ok_t "the canary is brought back UP on the restored build — the gate does not end its run leaving one agent dark" \
  || bad_t "canary not recovered" "$(tail -n3 "$d/out")"

# --- NEGATIVE CONTROL: a GOOD release must not trip any of the three ---------
# Without this every assertion above is satisfiable by a gate that halts on
# everything, which would freeze the fleet off updates permanently.
hg_loop good "" GOOD-LAUNCHER
d="$WORK/loop-good"
eq_t "NEGATIVE CONTROL: a healthy release exits ZERO" "$(cat "$d/rc" 2>/dev/null)" 0
eq_t "NEGATIVE CONTROL: a healthy release restarts ALL THREE agents — the gate is not a brake on good nights" \
  "$(hg_restarted_units good)" "5dive-agent@a1.service,5dive-agent@a2.service,5dive-agent@a3.service"
eq_t "NEGATIVE CONTROL: a healthy release is NOT rolled back — the new bundle stays on disk" \
  "$(cat "$d/bin/5dive" 2>/dev/null)" NEW-BUNDLE

# --- MUTANTS of the WIRING --------------------------------------------------
# Each is a one-token regression that leaves every `_hg_*` call in place, so the
# presence-greps above still pass. If one of these survives, the arms are reading
# the gate's text rather than its effect (the DIVE-1095 shape).
mutw(){ # <name> <sed-expr> ; killed when the shipped assertions go red
  local name="$1" expr="$2" tag rc units launcher
  tag="m$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  hg_loop "$tag" "$expr" BAD-LAUNCHER
  rc="$(cat "$WORK/loop-$tag/rc" 2>/dev/null)"
  if [[ "$rc" == "MUTATION-DID-NOT-APPLY" ]]; then
    bad_t "MUTATION DID NOT APPLY — $name" "sed '$expr' matched nothing; this arm graded the SHIPPED loop, not a mutant"
    return
  fi
  units="$(hg_restarted_units "$tag")"
  launcher="$(cat "$WORK/loop-$tag/bin/5dive-agent-start" 2>/dev/null)"
  if [[ "$rc" == 0 || "$units" != "5dive-agent@a1.service" || "$launcher" != GOOD-LAUNCHER ]]; then
    ok_t "MUTANT KILLED — $name (rc=$rc restarted=[$units] launcher=$launcher)"
  else
    bad_t "MUTANT SURVIVED — $name" "the wiring arms pass against a loop that does not hold the blast radius"
  fi
}

# W1: the halt becomes a skip. The gate reads crash-loop and the loop restarts
# every remaining agent anyway — 0.26.1's night back, with the gate installed
# and green.
mutw "the gate's halt turned into a 'continue' restarts the rest of the fleet anyway" \
     '/elif \[\[ "$hg_action" != "proceed" \]\]; then/{n;s/break/continue/;}'
# W2: the post-loop block never runs. Detects, never halts, never rolls back —
# every _hg_* call still present and every presence-grep still satisfied.
mutw "the post-loop rollback block disabled leaves the bad build on disk" \
     's/^  if \[\[ "$hg_action" != "proceed" \]\]; then$/  if false; then/'
# W3: the canary is never selected, so the probe never runs inside the loop.
mutw "the in-loop canary probe never selected lets the whole pass run unmeasured" \
     's/^    if \[\[ -z "$hg_canary" \]\]; then$/    if false; then/'

# ============================================ 9. THE LAUNCHER-ONLY NIGHT, RUN
# Section 8 drives the restart loop, but every one of its arms runs with
# `_agent_restart_needed` returning 0 — a night on which a payload fingerprint
# moved. 0.26.1 was NOT that night. `5dive-agent-start` lives in /usr/local/bin,
# not in an agent's home, so DIVE-3172's fingerprint never moved: nobody needed
# a restart, nothing exercised the new startup path, and the box went dark at its
# next bounce from any cause. The post-loop block is the branch written for
# exactly that, and until this section NOTHING in the repo entered it — deleting
# it whole shipped 83/0 green. Same asymmetry as the row itself, one block over:
# `_hg_artifact_moved` the helper was graded four ways in section 4, the CONSUMER
# of its verdict by presence-grep.
#
# So: nobody needs a restart, the installer moves the launcher, the canary dies
# on it. Asserted on behaviour, exactly as in section 8 —
#   (a) exactly one agent is ever restarted;
#   (b) the bytes on disk afterwards are the PRE-upgrade bytes;
#   (c) the command exits non-zero.
hg_loop lonly "" BAD-LAUNCHER 1
d="$WORK/loop-lonly"
grep -q 'skipped a1 (payload unchanged)' "$d/out" \
  && ok_t "FIXTURE: the launcher-only night is real — no agent needed a restart, so the in-loop probe never ran" \
  || bad_t "fixture did not reach the launcher-only shape" "$(grep -c . "$d/out" 2>/dev/null) lines; $(tail -n3 "$d/out")"
grep -q 'the launcher changed — probing' "$d/out" \
  && ok_t "the pass spends ONE restart because the launcher itself moved, rather than leaving the new startup path unexercised" \
  || bad_t "the launcher-only probe never announced itself" "$(tail -n3 "$d/out")"
eq_t "(c) LAUNCHER-ONLY: a release that kills the canary makes self-update EXIT NON-ZERO" \
  "$( [[ "$(cat "$d/rc" 2>/dev/null)" == 0 ]] && echo zero || echo non-zero )" non-zero
eq_t "(a) LAUNCHER-ONLY BLAST RADIUS: exactly one agent was ever restarted" \
  "$(hg_restarted_units lonly)" 5dive-agent@a1.service
eq_t "(b) LAUNCHER-ONLY: the launcher on disk afterwards is the PRE-upgrade one" \
  "$(cat "$d/bin/5dive-agent-start" 2>/dev/null)" GOOD-LAUNCHER
eq_t "(b) LAUNCHER-ONLY: the bundle on disk afterwards is the PRE-upgrade one" \
  "$(cat "$d/bin/5dive" 2>/dev/null)" GOOD-BUNDLE
grep -qi 'HEALTH GATE FAILED' "$d/out" \
  && ok_t "LAUNCHER-ONLY: the operator gets the loud rollback line" \
  || bad_t "no rollback line on the launcher-only night" "$(tail -n3 "$d/out")"
grep -qi 'running again on the restored build' "$d/out" \
  && ok_t "LAUNCHER-ONLY: the canary is brought back UP on the restored build" \
  || bad_t "canary not recovered on the launcher-only night" "$(tail -n3 "$d/out")"

# NEGATIVE CONTROL: the launcher did NOT move and nobody needed a restart. This
# is the ordinary quiet night, and the block must not be a brake on it — no
# probe, no restart, the new bundle stays. Without this arm every assertion above
# is satisfied by a block that spends a restart on every pass, which is the
# opposite failure and the one that costs a bounce per box per night.
hg_loop lonlyquiet "" GOOD-LAUNCHER 1
d="$WORK/loop-lonlyquiet"
eq_t "NEGATIVE CONTROL: a night where the launcher did not move exits ZERO" "$(cat "$d/rc" 2>/dev/null)" 0
eq_t "NEGATIVE CONTROL: it restarts NOBODY — an unchanged launcher is not probed" \
  "$(hg_restarted_units lonlyquiet)" ""
eq_t "NEGATIVE CONTROL: the new bundle stays on disk" "$(cat "$d/bin/5dive" 2>/dev/null)" NEW-BUNDLE
grep -q 'health gate not probed' "$d/out" \
  && ok_t "NEGATIVE CONTROL: the summary says the gate was not probed, and on this night that is TRUE" \
  || bad_t "the quiet night did not report itself honestly" "$(tail -n3 "$d/out")"

# The candidate loop re-applies every guard the restart loop applies, because an
# agent nobody asked to restart must not be resurrected from a park or
# interrupted mid-row. Both fixtures move the launcher to a build that is FINE
# (GOOD-LAUNCHER-2 — different bytes, and the fake unit only dies on `BAD`), so
# the only thing either arm can see is WHICH agent the gate chose to spend.
hg_loop lonlybusy "" GOOD-LAUNCHER-2 1 a1
d="$WORK/loop-lonlybusy"
eq_t "the launcher-only probe SKIPS the agent holding an in_progress row and spends the next one" \
  "$(hg_restarted_units lonlybusy)" 5dive-agent@a2.service
eq_t "a healthy new launcher probed on a busy box still exits zero" "$(cat "$d/rc" 2>/dev/null)" 0
hg_loop lonlyparked "" GOOD-LAUNCHER-2 1 "" a1
eq_t "the launcher-only probe SKIPS a parked agent rather than resurrecting it" \
  "$(hg_restarted_units lonlyparked)" 5dive-agent@a2.service

# --- MUTANTS of the LAUNCHER-ONLY WIRING ------------------------------------
# L1-L3 leave every `_hg_*` call text in place and pass all 83 arms that existed
# before this section. Graded against the launcher-only fixture: killed when the
# blast radius, the bytes on disk or the exit status stops matching the shipped
# behaviour asserted above — never on a log message.
mutl(){ # <name> <sed-expr>
  local name="$1" expr="$2" tag rc units launcher
  tag="l$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  hg_loop "$tag" "$expr" BAD-LAUNCHER 1
  rc="$(cat "$WORK/loop-$tag/rc" 2>/dev/null)"
  if [[ "$rc" == "MUTATION-DID-NOT-APPLY" ]]; then
    bad_t "MUTATION DID NOT APPLY — $name" "sed '$expr' matched nothing; this arm graded the SHIPPED loop, not a mutant"
    return
  fi
  units="$(hg_restarted_units "$tag")"
  launcher="$(cat "$WORK/loop-$tag/bin/5dive-agent-start" 2>/dev/null)"
  if [[ "$rc" == 0 || "$units" != "5dive-agent@a1.service" || "$launcher" != GOOD-LAUNCHER ]]; then
    ok_t "MUTANT KILLED — $name (rc=$rc restarted=[$units] launcher=$launcher)"
  else
    bad_t "MUTANT SURVIVED — $name" "the launcher-only night is graded by nothing but the presence of the block"
  fi
}
# L1: the block's outer guard never opens. 0.26.1's night verbatim on an idle
# box: rc=0, nothing restarted, the bad launcher left on disk, and a summary line
# claiming the launcher did not change.
mutl "the launcher-only block's outer guard disabled leaves the bad launcher on an unprobed box" \
     's/^  if \[\[ -z "$hg_canary" \&\& "$hg_action" == "proceed" \]\] \&\& command -v systemctl/  if false \&\& command -v systemctl/'
# L2: the moved-artifact test always answers "unchanged", so the probe is skipped
# on exactly the night it exists for.
mutl "the moved-launcher test disabled skips the probe on the launcher-only night" \
     's/^    if (( hg_moved != 1 )); then$/    if false; then/'
# L3: the candidate loop does not stop at its verdict, so the next agent's
# healthy probe OVERWRITES the rollback one — detect, then un-detect.
mutl "the candidate loop that does not stop lets a later healthy probe overwrite the rollback verdict" \
     '/\[\[ "$hg_action" == "proceed" \]\] && restarted+=("$cand")/{n;s/break/continue/;}'
# L4/L5: the re-applied guards. Killed on WHICH agent was spent, which is the
# only thing these guards decide.
mutg(){ # <name> <sed-expr> <busy-csv> <parked-csv>
  local name="$1" expr="$2" bl="$3" pl="$4" tag rc units
  tag="g$(printf '%s' "$name" | cksum | cut -d' ' -f1)"
  hg_loop "$tag" "$expr" GOOD-LAUNCHER-2 1 "$bl" "$pl"
  rc="$(cat "$WORK/loop-$tag/rc" 2>/dev/null)"
  if [[ "$rc" == "MUTATION-DID-NOT-APPLY" ]]; then
    bad_t "MUTATION DID NOT APPLY — $name" "sed '$expr' matched nothing; this arm graded the SHIPPED loop, not a mutant"
    return
  fi
  units="$(hg_restarted_units "$tag")"
  if [[ "$units" != "5dive-agent@a2.service" ]]; then
    ok_t "MUTANT KILLED — $name (restarted=[$units])"
  else
    bad_t "MUTANT SURVIVED — $name" "the guard is graded by nothing — the probe may bounce an agent nobody asked to restart"
  fi
}
mutg "dropping the idle guard lets the launcher-only probe interrupt an agent mid-row" \
     '/\[\[ "$(_agent_busy_state "$cand")" == "idle" \]\] || continue/d' a1 ""
mutg "dropping the parked guard lets the launcher-only probe resurrect a parked agent" \
     '/_agent_is_parked "$cand" && continue/d' "" a1

# --- the two SIBLING consumer branches in the same block --------------------
# Quinn's iteration-2 reject was "the same class, one block over", twice. These
# are the remaining consumers of a verdict inside this block that no arm entered:
# `no-safe-canary`, and `hg_moved == 2` (the manifest could not be read).
#
# 9a. Every candidate is unsafe. The gate must NOT invent a canary, and it must
# not go quiet either — a box that installed a startup path nothing on it has
# exercised is the state the operator has to hear about, because the next bounce
# from any cause is what finds out.
hg_loop lonlynone "" GOOD-LAUNCHER-2 1 a1,a2,a3
d="$WORK/loop-lonlynone"
eq_t "no safe candidate: the gate restarts NOBODY rather than inventing a canary" \
  "$(hg_restarted_units lonlynone)" ""
eq_t "no safe candidate: the pass still exits zero — an unprobed box is not evidence of breakage" \
  "$(cat "$d/rc" 2>/dev/null)" 0
grep -q 'no agent was safe to probe' "$d/out" \
  && ok_t "no safe candidate: the operator is TOLD the new startup path is unexercised" \
  || bad_t "the unexercised box went quiet" "$(tail -n3 "$d/out")"
hg_loop lonlynonemut '/hg_verdict="no-safe-canary"/,+1d' GOOD-LAUNCHER-2 1 a1,a2,a3
if [[ "$(cat "$WORK/loop-lonlynonemut/rc" 2>/dev/null)" == "MUTATION-DID-NOT-APPLY" ]]; then
  bad_t "MUTATION DID NOT APPLY — the no-safe-canary warning deleted" "sed matched nothing"
elif grep -q 'no agent was safe to probe' "$WORK/loop-lonlynonemut/out" 2>/dev/null; then
  bad_t "MUTANT SURVIVED — the no-safe-canary warning deleted" "the box can install an unexercised startup path silently"
else
  ok_t "MUTANT KILLED — deleting the no-safe-canary verdict makes an unexercised box silent"
fi

# 9b. DIVE-2230 at the CONSUMER: the capture failed, so the manifest cannot say
# whether the launcher moved. An absent reading resolves to NEITHER answer, and
# the branch that costs one restart is the recoverable one — so it probes anyway.
# Nothing can be rolled back, and the arm asserts that the box is told exactly
# that instead of being left to look rolled back.
hg_loop lonlyunread "" BAD-LAUNCHER 1 "" "" /proc/version/cannot-mkdir
d="$WORK/loop-lonlyunread"
grep -q 'could not capture a rollback point' "$d/out" \
  && ok_t "FIXTURE: the capture is unusable, so the moved-launcher question is UNREADABLE (exit 2), not 'unchanged'" \
  || bad_t "fixture did not produce an unusable capture" "$(tail -n3 "$d/out")"
eq_t "unreadable manifest: the gate PROBES anyway — one restart beats assuming the launcher did not move" \
  "$(hg_restarted_units lonlyunread)" 5dive-agent@a1.service
grep -q 'manifest unreadable — probed rather than assumed unchanged' "$d/out" \
  && ok_t "unreadable manifest: the reason names itself in the log" \
  || bad_t "the probed-on-unknown reason was not stated" "$(tail -n3 "$d/out")"
eq_t "unreadable manifest: a canary that dies still EXITS NON-ZERO" \
  "$( [[ "$(cat "$d/rc" 2>/dev/null)" == 0 ]] && echo zero || echo non-zero )" non-zero
grep -q 'would roll this box back and CANNOT' "$d/out" \
  && ok_t "unreadable manifest: the operator is told the box is on the new build and NOT rolled back — a rollback with no capture is not faked" \
  || bad_t "a rollback that could not happen was not reported" "$(tail -n3 "$d/out")"
hg_loop lonlyunreadmut 's/^    if (( hg_moved != 1 )); then$/    if (( hg_moved == 0 )); then/' \
  BAD-LAUNCHER 1 "" "" /proc/version/cannot-mkdir
rc="$(cat "$WORK/loop-lonlyunreadmut/rc" 2>/dev/null)"
if [[ "$rc" == "MUTATION-DID-NOT-APPLY" ]]; then
  bad_t "MUTATION DID NOT APPLY — unreadable treated as unchanged" "sed matched nothing"
elif [[ "$rc" == 0 || "$(hg_restarted_units lonlyunreadmut)" != 5dive-agent@a1.service ]]; then
  ok_t "MUTANT KILLED — treating an unreadable manifest as 'unchanged' skips the probe (rc=$rc restarted=[$(hg_restarted_units lonlyunreadmut)])"
else
  bad_t "MUTANT SURVIVED — unreadable treated as unchanged" "the launcher-only probe is skipped on exactly the box that cannot answer"
fi

# 9c. The HALT consumer, driven. `_hg_action`'s asymmetry is graded four ways in
# section 3 and its unknown->halt arm has a mutant, but the CONSUMER of a halt —
# the block that must warn, revert NOTHING, and still stop the pass — was entered
# by no driven arm. It is the third of the three outcomes this row turns on, and
# the one where getting it wrong (reverting) freezes a box off updates forever.
hg_loop lonlyblind "" BAD-LAUNCHER 1 "" "" "" blind
d="$WORK/loop-lonlyblind"
eq_t "HALT: a canary systemd stops answering about still stops the pass (non-zero)" \
  "$( [[ "$(cat "$d/rc" 2>/dev/null)" == 0 ]] && echo zero || echo non-zero )" non-zero
eq_t "HALT: the blast radius is still one — agents two and three are never reached" \
  "$(hg_restarted_units lonlyblind)" 5dive-agent@a1.service
eq_t "HALT: NOTHING is reverted on an unreadable box — the new launcher stays on disk" \
  "$(cat "$d/bin/5dive-agent-start" 2>/dev/null)" BAD-LAUNCHER
eq_t "HALT: and the new bundle stays too — a halt is not a rollback" \
  "$(cat "$d/bin/5dive" 2>/dev/null)" NEW-BUNDLE
grep -q 'INCONCLUSIVE' "$d/out" \
  && ok_t "HALT: the operator is told the box could not be read, not that it was rolled back" \
  || bad_t "the halt was not reported as inconclusive" "$(tail -n3 "$d/out")"
# The mutant is the TRIGGER-HAPPY direction, which this file names as the worse
# one: treat every non-proceed verdict as a rollback and a box systemd merely
# would not talk about gets a good release reverted under it.
hg_loop lonlyblindmut 's/if \[\[ "$hg_action" == "rollback" \]\]; then/if true; then/' \
  BAD-LAUNCHER 1 "" "" "" blind
if [[ "$(cat "$WORK/loop-lonlyblindmut/rc" 2>/dev/null)" == "MUTATION-DID-NOT-APPLY" ]]; then
  bad_t "MUTATION DID NOT APPLY — halt treated as rollback" "sed matched nothing"
elif [[ "$(cat "$WORK/loop-lonlyblindmut/bin/5dive-agent-start" 2>/dev/null)" != BAD-LAUNCHER ]]; then
  ok_t "MUTANT KILLED — treating a halt as a rollback reverts a release on a box that was merely unreadable"
else
  bad_t "MUTANT SURVIVED — halt treated as rollback" "nothing grades the difference between halting and reverting"
fi

# 9d. The last consumer inside the restart loop: an agent that was ALREADY
# unsteady before the update. `_hg_canary_ok` is graded at the helper in 5b, but
# its caller's answer — restart that agent ORDINARILY and let the NEXT one take
# the canary role — was entered by no driven arm. Believing a sick unit is the one
# way this gate makes a night worse than it found it: it reverts a good release
# for the whole box on one independently broken agent.
hg_loop notacanary "" BAD-LAUNCHER 0 "" "" "" crash a2 a1
d="$WORK/loop-notacanary"
grep -q 'not using a1 as the health-gate canary' "$d/out" \
  && ok_t "a unit that was not steady BEFORE the update is refused as an instrument, out loud" \
  || bad_t "the unsteady unit was used as a canary" "$(tail -n3 "$d/out")"
eq_t "the sick agent is still restarted ORDINARILY and the NEXT agent takes the canary role — a3 is never reached" \
  "$(hg_restarted_units notacanary)" "5dive-agent@a1.service,5dive-agent@a2.service"
eq_t "the release is judged on the agent that could answer: bytes reverted" \
  "$(cat "$d/bin/5dive-agent-start" 2>/dev/null)" GOOD-LAUNCHER
eq_t "and the pass exits non-zero" \
  "$( [[ "$(cat "$d/rc" 2>/dev/null)" == 0 ]] && echo zero || echo non-zero )" non-zero
# The mutant is the CONSUMER's own branch (the validity check itself lives in the
# extracted block, which this driver runs as shipped bytes): if `not-a-canary` is
# not distinguished from `restart-refused`, the sick agent is never restarted at
# all and is logged as a failed restart — it silently stays on the old payload,
# which is the DIVE-4033 shape this row must not reintroduce.
hg_loop notacanarymut 's/^        if \[\[ "$hg_verdict_raw" == "not-a-canary" \]\]; then$/        if false; then/' BAD-LAUNCHER 0 "" "" "" crash a2 a1
u="$(hg_restarted_units notacanarymut)"
if [[ "$(cat "$WORK/loop-notacanarymut/rc" 2>/dev/null)" == "MUTATION-DID-NOT-APPLY" ]]; then
  bad_t "MUTATION DID NOT APPLY — the canary validity check removed" "sed matched nothing"
elif [[ "$u" != "5dive-agent@a1.service,5dive-agent@a2.service" ]]; then
  ok_t "MUTANT KILLED — conflating 'not an instrument' with 'systemctl refused' leaves the sick agent unrestarted and mislogged (restarted=[$u])"
else
  bad_t "MUTANT SURVIVED — the not-a-canary fall-through removed" "an agent left on the old payload and logged as a failed restart is graded by nothing"
fi

# --- MUTANT of the second sample (helper, but only reachable from 6c) --------
mut "dropping the second sample's active/running check accepts a unit that stopped being an instrument" \
    '/\[\[ "$a2" == "active"/d' \
    'export SYSTEMCTL_FAKE PATH HEALTH_GATE_PRECHECK_SECS=1
     printf active > "$SYSTEMCTL_FAKE/ActiveState"; printf running > "$SYSTEMCTL_FAKE/SubState"
     printf "5dive-agent@t.service" > "$SYSTEMCTL_FAKE/Id"; printf 5 > "$SYSTEMCTL_FAKE/NRestarts"
     ( sleep 1; printf failed > "$SYSTEMCTL_FAKE/ActiveState" ) &
     _hg_canary_ok 5dive-agent@t.service && echo MUTANT-CAUGHT
     wait 2>/dev/null'
# M9: the reload dropped from the restore — the box keeps the ExecStart it reverted.
mut "a restore with no daemon-reload leaves systemd on the ExecStart it just reverted" \
    '/systemctl daemon-reload/d' \
    'export SYSTEMCTL_FAKE PATH
     export HEALTH_GATE_BIN_DIR="$DR_BIN" HEALTH_GATE_SYSTEMD_DIR="$DR_SYSD" HEALTH_GATE_ROLLBACK_DIR="$DR_RB2"
     _hg_capture >/dev/null 2>&1
     printf NEW > "$HEALTH_GATE_SYSTEMD_DIR/5dive-agent@.service"
     rm -f "$SYSTEMCTL_FAKE/cmd.log"
     _hg_restore >/dev/null 2>&1
     grep -q daemon-reload "$SYSTEMCTL_FAKE/cmd.log" 2>/dev/null || echo MUTANT-CAUGHT'

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
