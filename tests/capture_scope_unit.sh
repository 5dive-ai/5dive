#!/usr/bin/env bash
# DIVE-5806 (L4): a scoped seat's `agent _capture` reads only the reply to a
# question IT delivered to that pane.
#
# divine-owl audit, 2026-10-07: dave (standard) ran `sudo 5dive agent _capture
# olivia` 73 times. `_capture` took any --after-id and anchored on the first pane
# line CONTAINING `id=<after-id>`, so `--after-id=1` read olivia's (admin) pane
# after any `task_id=1…` line, up to the next [5dive-msg — and a pane can hold
# secrets. Now `_deliver --id` records (caller uid, target, id), `_capture` from a
# sudo caller needs that record, and it anchors on the envelope `_deliver` stamped
# (`from=<caller> id=<id>`), so `ask` keeps working and nothing else is readable.
#
# Offline: root, tmux and sudo are stubbed; the pane is a fixture.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source src/header.sh
# shellcheck disable=SC1091
source src/lib/error_codes.sh
# shellcheck disable=SC1091
source src/lib/output.sh
# shellcheck disable=SC1091
source src/cmd_agent_runtime.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"
export FIVE_CAPTURE_ACC_DIR="$WORK/acc" FIVE_CAPTURE_MINT_DIR="$WORK/mint"

require_root()  { :; }
_gate_is_root() { return 0; }
require_agent() { :; }
PANE="$WORK/pane"
sudo() {
  case " $* " in
    *" has-session "*)  return 0 ;;
    *" capture-pane "*) cat "$PANE"; return 0 ;;
  esac
  return 0
}
declare -A SEAT_OF_UID=([1001]=dave [1002]=erin)
actor_routing_agent() { local a="${SEAT_OF_UID[${SUDO_UID:-}]:-}"; [[ -n "$a" ]] && { printf '%s' "$a"; return 0; }; return 1; }

SECRET_BEFORE="SECRET-olivia-own-work-sk-live-123"
SECRET_OTHER="SECRET-reply-to-someone-else"
MID="ab12cd34"
printf '%s\n' \
  "  task_id=1 claimed by olivia" \
  "  export STRIPE_KEY=${SECRET_BEFORE}" \
  "  done." \
  "[5dive-msg from=erin id=${MID}9 tier=standard] erin's own question" \
  "  ${SECRET_OTHER}" \
  "[5dive-msg from=dave id=${MID} tier=standard] what is the deploy plan?" \
  "  drain, roll, verify" \
  "[5dive-msg from=trinity id=99887766 tier=admin] later question" \
  "  ${SECRET_OTHER}" > "$PANE"

cap() {   # <sudo-uid or ''> <target> <after-id>
  ( if [[ -n "$1" ]]; then export SUDO_UID="$1"; else unset SUDO_UID; fi
    JSON_MODE=0; cmd_capture "$2" --after-id="$3" ) 2>&1
}

# 1 — the audit's shape: a standard seat picks a short id with no question behind it.
out=$(cap 1001 olivia 1); rc=$?
[[ $rc -eq 10 && "$out" == *"refused"*"question you delivered"* && "$out" != *SECRET* ]] \
  && ok_t "C1 dave's _capture olivia --after-id=1 with no delivered question: refused (rc 10), nothing of the pane emitted" \
  || bad_t "C1 dave's _capture olivia --after-id=1 with no delivered question: refused (rc 10), nothing of the pane emitted" "rc=$rc out=$out"

# 2 — ask's real path: _deliver --id recorded the question, the reply window comes back.
_capture_mint_record_as() { ( export SUDO_UID="$1"; _capture_mint_record "$2" "$3" ); }
_capture_mint_record_as 1001 olivia "$MID"
out=$(cap 1001 olivia "$MID"); rc=$?
[[ $rc -eq 0 && "$out" == "  drain, roll, verify" ]] \
  && ok_t "C2 after dave's _deliver --id=${MID}, his _capture returns exactly his reply window" \
  || bad_t "C2 after dave's _deliver --id=${MID}, his _capture returns exactly his reply window" "rc=$rc out=[$out]"

# 3 — a recorded short id still anchors only on dave's own envelope, not on `task_id=1`
#     and not on erin's `id=${MID}9` (a prefix match).
_capture_mint_record_as 1001 olivia 1
out=$(cap 1001 olivia 1); rc=$?
[[ $rc -eq 0 && -z "$out" ]] \
  && ok_t "C3 dave delivered --id=1: the read anchors on 'from=dave id=1', so task_id=1 opens nothing (empty)" \
  || bad_t "C3 dave delivered --id=1: the read anchors on 'from=dave id=1', so task_id=1 opens nothing (empty)" "rc=$rc out=[$out]"
printf '%s\n' "[5dive-msg from=dave id=${MID}9 tier=standard] x" "  ${SECRET_OTHER}" > "$PANE.prefix"
PANE_SAVE="$PANE"; PANE="$PANE.prefix"; rm -f "$FIVE_CAPTURE_ACC_DIR"/*   # a fresh transcript: C2's frames are not this pane
_capture_mint_record_as 1001 olivia "${MID}"
out=$(cap 1001 olivia "$MID"); rc=$?
PANE="$PANE_SAVE"
[[ $rc -eq 0 && -z "$out" ]] \
  && ok_t "C4 'from=dave id=${MID}9' is not dave's id=${MID} envelope (no prefix match)" \
  || bad_t "C4 'from=dave id=${MID}9' is not dave's id=${MID} envelope (no prefix match)" "rc=$rc out=[$out]"
rm -f "$FIVE_CAPTURE_ACC_DIR"/*

# 4 — the record is per caller and per target.
out=$(cap 1002 olivia "$MID"); rc=$?
[[ $rc -eq 10 && "$out" != *drain* ]] \
  && ok_t "C5 dave's record does not let erin read dave's reply window" \
  || bad_t "C5 dave's record does not let erin read dave's reply window" "rc=$rc out=$out"
out=$(cap 1001 morpheus "$MID"); rc=$?
[[ $rc -eq 10 ]] \
  && ok_t "C6 a question delivered to olivia opens no other seat's pane" \
  || bad_t "C6 a question delivered to olivia opens no other seat's pane" "rc=$rc out=$out"

# 5 — direct root is unchanged (it can tmux any pane anyway).
printf '%s\n' "[5dive-msg from=dave id=${MID} tier=standard] what is the deploy plan?" "  drain, roll, verify" > "$PANE.root"
PANE="$PANE.root"
out=$(cap "" olivia "$MID"); rc=$?
PANE="$PANE_SAVE"
[[ $rc -eq 0 && "$out" == "  drain, roll, verify" ]] \
  && ok_t "C7 direct root (no SUDO_UID) reads as before, no record needed" \
  || bad_t "C7 direct root (no SUDO_UID) reads as before, no record needed" "rc=$rc out=[$out]"

# 6 — the record is root-only and _deliver writes it for the id it injects.
perm=$(stat -c '%a' "$FIVE_CAPTURE_MINT_DIR"); fperm=$(stat -c '%a' "$FIVE_CAPTURE_MINT_DIR/1001.olivia.${MID}")
[[ "$perm" == 700 && "$fperm" == 600 ]] \
  && ok_t "C8 the record store is 0700 and each record 0600" \
  || bad_t "C8 the record store is 0700 and each record 0600" "dir=$perm file=$fperm"
rm -rf "$FIVE_CAPTURE_MINT_DIR"
(
  export SUDO_UID=1001
  a2a_round_guard() { return 0; }; envelope_tier() { printf standard; }; envelope_via() { :; }
  envelope_provenance() { printf corroborated; }; _agent_delivery_inbox() { return 0; }
  _wake_sender_vouchable() { return 1; }; inject_and_submit() { printf '%s' "$2" > "$WORK/injected"; return 0; }
  audit_log() { :; }; JSON_MODE=1
  cmd_deliver --id=c0ffee01 olivia "is the api up?"
) >/dev/null 2>&1
[[ -f "$FIVE_CAPTURE_MINT_DIR/1001.olivia.c0ffee01" && "$(cat "$WORK/injected" 2>/dev/null)" == "[5dive-msg from=dave id=c0ffee01 tier=standard] is the api up?" ]] \
  && ok_t "C9 cmd_deliver --id=c0ffee01 olivia (as dave) records 1001.olivia.c0ffee01 and injects the envelope _capture anchors on" \
  || bad_t "C9 cmd_deliver --id=c0ffee01 olivia (as dave) records 1001.olivia.c0ffee01 and injects the envelope _capture anchors on" "mint=$(ls "$FIVE_CAPTURE_MINT_DIR" 2>&1) injected=$(cat "$WORK/injected" 2>&1)"

echo
echo "capture-scope unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
