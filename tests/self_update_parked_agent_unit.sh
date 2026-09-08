#!/usr/bin/env bash
# DIVE-4033: `5dive self-update`'s restart sweep was the ONE path in the tree that
# never read `desiredState`. On a 37-agent customer box the 0.26.0 sweep restarted
# `katya` — a customer-facing sales bot parked when its project closed on
# 2026-08-19 — and the CLI then printed both halves of the contradiction itself
# (`active / disabled`). A parked agent resurrecting itself is a consent problem.
#
# Two ways this fix can be wrong, and they fail in OPPOSITE directions:
#
#   RESURRECTS  — the parked check is not consulted, or is consulted after the
#                 restart, and the agent comes back. That is the original bug.
#   FREEZES     — the check reads "parked" from something that is merely UNKNOWN
#                 (no registry, no jq, corrupt JSON, agent absent from the file)
#                 and the whole fleet is silently skipped, running the old payload
#                 forever. DIVE-3173 names this the worse of the two, and DIVE-1095
#                 is an entire row about a fix that shipped and stayed dormant.
#
# So every uncertain reading must take the SAME branch as "running", and the
# harness carries a NEGATIVE CONTROL beside each positive one — an arm that only
# passes because the fix fires, next to an arm that only passes because it does
# not fire on an unknown.
#
# Hermetic in the shape DIVE-2042/DIVE-3172/DIVE-3173 established: the block is
# extracted VERBATIM from src/cmd_selfupdate.sh between its fence markers and run
# as the SHIPPED BYTES against temp directories. No systemd, no board, no agent
# and no registry outside $WORK is touched.
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

block="$(sed -n '/^# >>> DIVE-4033 an operator-parked agent stays parked/,/^# <<< DIVE-4033 an operator-parked agent stays parked/p' \
  src/cmd_selfupdate.sh)"
if [[ -n "$block" ]] && grep -q '_agent_is_parked()' <<<"$block" \
   && grep -q '_parked_override_note()' <<<"$block"; then
  ok_t "the parked-agent block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "parked block missing" "markers '# >>> / # <<< DIVE-4033 an operator-parked agent stays parked' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# The sweep lives in the DIVE-3173 fence and CALLS this helper, so the sweep arms
# below run the pair exactly as the box does.
sweepblock="$(sed -n '/^# >>> DIVE-3173 deferred restart for a busy agent/,/^# <<< DIVE-3173 deferred restart for a busy agent/p' \
  src/cmd_selfupdate.sh)"
if grep -q '_agent_is_parked()' <<<"$sweepblock"; then
  ok_t "the helper ships INSIDE the DIVE-3173 fence — the sweep's extracted bytes can reach it"
else
  bad_t "the helper is outside the sweep's fence" "the DIVE-3173 harness would grade a sweep whose parked branch cannot fire"
fi

WORK="$(mktemp -d)"

# ------------------------------------------------------------- helper arms ----
# `parked <registry-json-or-MISSING> <name>` -> yes|no
parked() {
  local body="$1" name="${2:-}"
  (
    if [[ "$body" == MISSING ]]; then REGISTRY="$WORK/no-such-registry.json"
    else REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$REGISTRY"; fi
    eval "$block"
    if _agent_is_parked "$name"; then echo yes; else echo no; fi
  )
}
# Same, with jq unreachable. `command -v jq || return 1` was the ONE unknown
# reading with no arm: flipping it to `return 0` (a missing tool reads as parked)
# is a fleet-wide freeze from an unrelated cause, and it survived every arm.
parked_nojq() {
  local body="$1" name="${2:-}"
  (
    mkdir -p "$WORK/emptybin"
    # Shadowing PATH is the POINT — it is how a box with no jq is reproduced
    # without uninstalling anything. Scoped to this subshell.
    # shellcheck disable=SC2123
    PATH="$WORK/emptybin"
    REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$REGISTRY"
    eval "$block"
    if _agent_is_parked "$name"; then echo yes; else echo no; fi
  )
}
STOPPED='{"agents":{"katya":{"desiredState":"stopped"},"nova":{"desiredState":"running"}}}'

if [[ "$(parked "$STOPPED" katya)" == yes ]]; then
  ok_t "POSITIVE: an explicit desiredState=stopped reads as parked — the katya case"
else
  bad_t "an explicitly stopped agent did not read as parked" "RESURRECTS: this is the whole ticket"
fi
if [[ "$(parked "$STOPPED" nova)" == no ]]; then
  ok_t "NEGATIVE CONTROL: desiredState=running is not parked (the arm above can fail)"
else
  bad_t "a running agent read as parked" "FREEZES: every agent would be skipped"
fi
if [[ "$(parked '{"agents":{"katya":{}}}' katya)" == no ]]; then
  ok_t "an agent with NO desiredState field restarts (absent is not stopped — DIVE-2318)"
else
  bad_t "a fieldless agent read as parked" "FREEZES: the common case is no field at all"
fi
if [[ "$(parked '{"agents":{}}' katya)" == no ]]; then
  ok_t "an agent absent from the registry restarts, byte for byte as today"
else
  bad_t "an unregistered agent read as parked" "FREEZES on every box whose registry lags systemd"
fi
if [[ "$(parked MISSING katya)" == no ]]; then
  ok_t "NO REGISTRY FILE restarts — a read failure is not an operator intent"
else
  bad_t "a missing registry read as parked" "FREEZES: a perms problem would silently freeze the fleet"
fi
if [[ "$(parked '{"agents":{"katya":{"desiredSt' katya)" == no ]]; then
  ok_t "a TRUNCATED registry restarts (a parse failure is unknown, not stopped)"
else
  bad_t "corrupt JSON read as parked" "FREEZES on a partially-written registry"
fi
if [[ "$(parked_nojq "$STOPPED" katya)" == no ]]; then
  ok_t "NEGATIVE CONTROL: with jq unreachable an explicitly-stopped agent still restarts (a missing tool is unknown, not parked)"
else
  bad_t "no jq read as parked" "FREEZES: a box without jq would skip its whole fleet forever"
fi
if [[ "$(parked_nojq "$STOPPED" katya)" == no ]] && [[ "$(parked "$STOPPED" katya)" == yes ]]; then
  ok_t "and that arm is discriminating — the SAME registry and name park with jq present"
else
  bad_t "the no-jq arm passes for the wrong reason" "it would pass even if the helper never parked anything"
fi
if [[ "$(parked "$STOPPED" "")" == no ]]; then
  ok_t "an empty name is not parked (no accidental match on a nameless unit)"
else
  bad_t "the empty name read as parked" "FREEZES: a name the caller failed to derive would skip"
fi
if [[ "$(parked "$STOPPED" kat)" == no ]] && [[ "$(parked "$STOPPED" katya2)" == no ]]; then
  ok_t "the lookup is an exact key, not a prefix or substring of one"
else
  bad_t "a partial name matched katya's entry" "an unrelated agent would be skipped forever"
fi
if [[ "$(parked '{"agents":{"katya":{"desiredState":"Stopped"}}}' katya)" == no ]]; then
  ok_t "the value is compared exactly — only the value cmd_stop actually writes parks"
else
  bad_t "a variant casing parked the agent" "the two states whose answers are opposite must not collapse"
fi
# The operator line must name BOTH exits: enforce the stop, or clear a stale
# intent. Only a person knows which, and "skipped" alone reads as decided.
note="$( ( eval "$block"; _parked_override_note katya ) )"
if grep -q '5dive agent stop katya' <<<"$note" && grep -q '5dive agent start katya' <<<"$note" \
   && grep -q 'desiredState=stopped' <<<"$note"; then
  ok_t "the operator line names the contradiction AND both ways out of it"
else
  bad_t "the parked line does not name both exits" "got: $note"
fi

# ---------------------------------------------- sweep arms (positive control) --
# One marker, one running unit, an idle board: exactly the shape that restarted
# katya. RESTARTS is the ledger — the file must stay empty when parked.
export PENDING_RESTART_DIR="$WORK/pending"
mk() { ( eval "$sweepblock"; _pending_restart_mark "$@" ); }

sweep_with() { # <registry-json-or-MISSING> [unit-active:yes|no]
  local body="$1" active="${2:-yes}"
  (
    if [[ "$body" == MISSING ]]; then REGISTRY="$WORK/no-such-registry.json"
    else REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$REGISTRY"; fi
    eval "$sweepblock"
    RESTARTS="$WORK/restarts"
    systemctl() {
      case "${1:-}" in
        is-active) [[ "$active" == yes ]] ;;             # the unit IS running
        show)      printf '\n' ;;                       # no ActiveEnterTimestamp => 0
        restart)   printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
        *)         return 0 ;;
      esac
    }
    db(){ echo 0; }; sqlq(){ printf '%s' "$1"; }        # board says idle
    _hb_agent_idle(){ return 0; }                       # pane says idle
    _pending_restart_sweep 2>/dev/null
    printf 'fired=%s parked=%s cleared=%s deferred=%s\n' \
      "$_PR_FIRED" "$_PR_PARKED" "$_PR_CLEARED" "$_PR_DEFERRED"
  )
}
RESTARTS="$WORK/restarts"

rm -rf "$PENDING_RESTART_DIR"; mk katya "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with "$STOPPED")"
if [[ "$out" == "fired=0 parked=1 cleared=0 deferred=0" ]] && [[ ! -s "$RESTARTS" ]]; then
  ok_t "POSITIVE CONTROL: a parked agent is not bounced — no systemctl restart issued"
else
  bad_t "the sweep restarted a parked agent" "sweep said '$out', restarts: $(tr '\n' ' ' < "$RESTARTS") — RESURRECTS"
fi
# ...and the debt SURVIVES the sweep. Clearing it here (iteration 1) meant the
# `agent start` exit — a no-op on a live unit, it only flips the registry — left
# the agent on the pre-update payload with nothing owed and nothing said.
if [[ -f "$PENDING_RESTART_DIR/katya" ]]; then
  ok_t "the owed restart is HELD, not destroyed — the marker survives the parked sweep"
else
  bad_t "the parked branch cleared the marker" "FREEZES: the debt is unrecoverable, and the agent stays on the old payload silently"
fi

# ---- the DISCRIMINATING pair: two sweeps, the registry edited between them ----
# A one-sweep harness structurally cannot see the marker's fate. These arms run
# the sweep twice with the operator's reconciliation in the middle, once per exit
# the parked line names — and each is only reachable because the marker was kept.
out2="$(sweep_with '{"agents":{"katya":{"desiredState":"running"}}}')"
if [[ "$out2" == "fired=1 parked=0 cleared=0 deferred=0" ]] \
   && grep -qx '5dive-agent@katya.service' "$RESTARTS" \
   && [[ ! -f "$PENDING_RESTART_DIR/katya" ]]; then
  ok_t "EXIT 1 ('the intent is stale'): after 'agent start' flips the registry, the NEXT sweep pays the held debt"
else
  bad_t "the owed restart never fired after the operator unparked the agent" \
        "second sweep said '$out2', restarts: $(tr '\n' ' ' < "$RESTARTS") — FREEZES on the pre-update payload"
fi

rm -rf "$PENDING_RESTART_DIR"; mk katya "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with "$STOPPED")"
out2="$(sweep_with "$STOPPED" no)"
if [[ "$out" == "fired=0 parked=1 cleared=0 deferred=0" ]] \
   && [[ "$out2" == "fired=0 parked=0 cleared=1 deferred=0" ]] \
   && [[ ! -s "$RESTARTS" ]] && [[ ! -f "$PENDING_RESTART_DIR/katya" ]]; then
  ok_t "EXIT 2 ('the stop is real'): once 'agent stop' takes the unit down the held marker is cleared, not fired"
else
  bad_t "holding the marker leaves a debt that can never be discharged" \
        "sweeps said '$out' then '$out2', restarts: $(tr '\n' ' ' < "$RESTARTS")"
fi
# The held marker must not read as an ordinary deferral: nobody is waiting on a
# task boundary, and an OVERDUE line would tell an operator to chase the agent.
rm -rf "$PENDING_RESTART_DIR"; mk katya "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with "$STOPPED")"
if [[ "$out" == *"deferred=0"* ]] && [[ "$out" == *"parked=1"* ]]; then
  ok_t "a held parked debt counts as PARKED only — not folded into deferred/overdue"
else
  bad_t "the parked hold is reported as a deferral" "sweep said '$out'"
fi

rm -rf "$PENDING_RESTART_DIR"; mk nova "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with "$STOPPED")"
if [[ "$out" == "fired=1 parked=0 cleared=0 deferred=0" ]] \
   && grep -qx '5dive-agent@nova.service' "$RESTARTS"; then
  ok_t "NEGATIVE CONTROL: an unparked agent in the SAME registry still fires — the skip is per-agent"
else
  bad_t "an unparked agent's restart was dropped" "sweep said '$out', restarts: $(tr '\n' ' ' < "$RESTARTS") — FREEZES"
fi

rm -rf "$PENDING_RESTART_DIR"; mk katya "payload changed" >/dev/null; : > "$RESTARTS"
out="$(sweep_with MISSING)"
if [[ "$out" == "fired=1 parked=0 cleared=0 deferred=0" ]] \
   && grep -qx '5dive-agent@katya.service' "$RESTARTS"; then
  ok_t "NEGATIVE CONTROL: with no registry the sweep behaves exactly as before the fix"
else
  bad_t "a missing registry changed the sweep's behaviour" "sweep said '$out' — FREEZES"
fi

# The parked branch must sit AFTER the is-active guard: a parked agent whose unit
# is already down is the state the operator asked for, and a loud line every
# sweep would bury the case that is genuinely wrong.
# Read the ordering inside the SWEEP FUNCTION, not the whole fence — the helper's
# own definition sits above the sweep and would win any file-wide "first match".
sweepfn="$(sed -n '/^_pending_restart_sweep() {/,/^}$/p' src/cmd_selfupdate.sh)"
if [[ -n "$sweepfn" ]] \
   && [[ "$(grep -n 'is-active --quiet' <<<"$sweepfn" | head -n1 | cut -d: -f1)" -lt \
         "$(grep -n '_agent_is_parked' <<<"$sweepfn" | head -n1 | cut -d: -f1)" ]]; then
  ok_t "the parked branch is asked only of a unit that is actually running"
else
  bad_t "the parked check precedes the is-active guard" "a correctly-stopped parked agent would log a contradiction every sweep"
fi

# ------------------------------------- cmd_self_update arm (end-to-end shape) --
# The nightly path itself, with curl/bash/systemctl/board stubbed. This is the
# arm that grades the line the customer box actually ran.
self_update_with() { # <registry-json-or-MISSING> <payload-moves:yes|no>
  local body="$1" moves="$2"
  (
    if [[ "$body" == MISSING ]]; then REGISTRY="$WORK/no-such-registry.json"
    else REGISTRY="$WORK/agents.json"; printf '%s' "$body" > "$REGISTRY"; fi
    PENDING_RESTART_DIR="$WORK/pending-su"; rm -rf "$PENDING_RESTART_DIR"
    RESTARTS="$WORK/restarts-su"; : > "$RESTARTS"
    E_USAGE=2; E_NOT_FOUND=3; E_GENERIC=1
    fail(){ printf 'FAILED: %s\n' "${2:-}" >&2; exit 1; }
    step(){ printf 'step: %s\n' "$*" >&2; }
    warn(){ printf 'warn: %s\n' "$*" >&2; }
    ok(){ shift; local filt="$1"; shift; jq -nc "$filt" "$@"; }
    json_array(){ printf '%s' "$( (( $# )) && printf '%s\n' "$@" | jq -Rc . | jq -sc . || echo '[]' )"; }
    curl(){ : > "${!#}"; return 0; }
    bash(){ return 0; }                                  # the installer --upgrade
    systemctl() {
      case "${1:-}" in
        list-units) printf '5dive-agent@katya.service loaded active running x\n5dive-agent@nova.service loaded active running x\n' ;;
        restart)    printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
        is-active)  return 0 ;;
        show)       printf '\n' ;;
        *)          return 0 ;;
      esac
    }
    _team_bot_install_listener(){ return 0; }
    _agent_home(){ printf '/nonexistent/%s\n' "${1:-}"; }
    agent_type(){ printf 'claude\n'; }
    db(){ echo 0; }; sqlq(){ printf '%s' "$1"; }
    _hb_agent_idle(){ return 0; }
    . src/cmd_selfupdate.sh
    # Move the payload for every agent, or for none, on demand. Declared AFTER
    # the source so it overrides the shipped one.
    # The counter lives in a FILE, not a variable: every call site reads this
    # through a command substitution, so a shell variable would reset to 0 in each
    # subshell and every fingerprint would come back identical — i.e. "payload
    # unchanged" for all of them, and both arms would pass while measuring nothing.
    rm -f "$WORK/fpc"
    if [[ "$moves" == yes ]]; then
      _agent_payload_fingerprint(){
        local c; c=$(cat "$WORK/fpc" 2>/dev/null || echo 0); c=$((c+1))
        printf '%s' "$c" > "$WORK/fpc"; printf 'fp-%s\n' "$c"
      }
    else
      _agent_payload_fingerprint(){ printf 'fp-same\n'; }
    fi
    cmd_self_update 2>/dev/null
    printf '\nRESTARTS:%s\n' "$(tr '\n' ' ' < "$RESTARTS")"
  )
}

out="$(self_update_with "$STOPPED" yes)"
if grep -q '"parked":\["katya"\]' <<<"$(tr -d ' ' <<<"$out")" \
   && ! grep -q 'katya' <<<"$(sed -n 's/^RESTARTS://p' <<<"$out")" \
   && grep -q 'nova' <<<"$(sed -n 's/^RESTARTS://p' <<<"$out")"; then
  ok_t "END TO END: self-update leaves the parked agent alone and restarts the other one"
else
  bad_t "self-update restarted the parked agent (or froze the unparked one)" "output: $out"
fi
if grep -q '"parked_count":1' <<<"$(tr -d ' ' <<<"$out")"; then
  ok_t "the JSON carries parked/parked_count — the contradiction is machine-readable, not just prose"
else
  bad_t "no parked_count in the self-update JSON" "output: $out"
fi
# self-update is the OTHER writer of this case, and it is the one the customer box
# ran. Its parked branch must record the debt too — otherwise the marker the sweep
# now holds never exists, and the whole hold above is unreachable from the nightly
# path. The payload MOVED in this arm, so a restart is genuinely owed.
if [[ -f "$WORK/pending-su/katya" ]]; then
  ok_t "END TO END: self-update RECORDS the owed restart for the parked agent instead of dropping it"
else
  bad_t "self-update dropped the parked agent's owed restart" \
        "the agent stays on the pre-update payload with nothing owed — the silent FREEZES direction"
fi
if [[ ! -f "$WORK/pending-su/nova" ]]; then
  ok_t "the unparked agent was restarted outright, so it owes nothing (the marker is not written for everyone)"
else
  bad_t "a marker was written for the agent that already restarted" "it would be bounced a second time next sweep"
fi

# NEGATIVE CONTROL for that mark: parked, but the payload did NOT move. Nothing is
# owed, so nothing may be recorded — marking unconditionally would bounce a
# just-unparked agent for no reason, on every CLI-only night.
out="$(self_update_with "$STOPPED" no)"
if grep -q '"parked_count":1' <<<"$(tr -d ' ' <<<"$out")" && [[ ! -f "$WORK/pending-su/katya" ]]; then
  ok_t "NEGATIVE CONTROL: parked with an UNCHANGED payload records no debt — the mark is conditional on the predicate"
else
  bad_t "self-update owed a restart for a payload that never moved" "output: $out"
fi

out="$(self_update_with MISSING yes)"
r="$(sed -n 's/^RESTARTS://p' <<<"$out")"
if grep -q 'katya' <<<"$r" && grep -q 'nova' <<<"$r" \
   && grep -q '"parked_count":0' <<<"$(tr -d ' ' <<<"$out")"; then
  ok_t "NEGATIVE CONTROL: with no registry self-update restarts both, exactly as before"
else
  bad_t "an unreadable registry changed self-update's behaviour" "output: $out"
fi

# The parked question must be asked BEFORE the payload predicate, or a parked
# agent reads as "skipped (payload unchanged)" on a CLI-only night and is
# resurrected with no explanation on the next night that the payload moves.
loop="$(sed -n '/^  for i in "${!units\[@\]}"; do/,/^  done$/p' src/cmd_selfupdate.sh)"
if [[ -n "$loop" ]] \
   && [[ "$(grep -n '_agent_is_parked' <<<"$loop" | head -n1 | cut -d: -f1)" -lt \
         "$(grep -n '_agent_restart_needed' <<<"$loop" | head -n1 | cut -d: -f1)" ]]; then
  ok_t "the parked check precedes the payload predicate — the reason reported is the true one"
else
  bad_t "the payload predicate is consulted first" "a parked agent would be reported as 'payload unchanged'"
fi

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
