#!/usr/bin/env bash
# DIVE-7369: `5dive init` asks once, as its last question, whether to turn on
# nightly updates (lodar 10-31: "self-update is burried - self hosters will not
# know they need to turn on"). The default stays OFF (lodar 10-23): only a Yes
# turns it on, and every run that is not asked leaves it off.
#
# Hermetic: src/cmd_init.sh and the DIVE-6799 switch block of
# src/cmd_selfupdate.sh are sourced as shipped and the real _init_pick reads the
# answer from stdin (its numbered fallback). Units land in a temp dir and
# systemctl is stubbed: no unit or timer on this box is touched.
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null`: the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-6799 nightly self-update switch/,/^# <<< DIVE-6799 nightly self-update switch/p' src/cmd_selfupdate.sh)"
grep -q '_su_nightly_on()' <<<"$block" || { bad_t "DIVE-6799 switch block not found in src/cmd_selfupdate.sh"; echo "$PASS passed, $FAIL failed"; exit 1; }
WORK="$(mktemp -d)"

# `ask <answer-on-stdin> [tty:yes|no] [provisioning:yes|no] [already-on:yes|no]`
# Prints what init showed (stderr) plus "TIMER:on|off" and "RC:<n>".
ask() {
  local input="$1" tty="${2:-yes}" prov="${3:-no}" on="${4:-no}"
  rm -rf "$WORK/units" "$WORK/provisioning.env"; mkdir -p "$WORK/units"; : > "$WORK/systemctl"
  [[ "$prov" == yes ]] && : > "$WORK/provisioning.env"
  [[ "$on" == yes ]] && : > "$WORK/units/5dive-self-update.timer"
  (
    SELF_UPDATE_UNIT_DIR="$WORK/units"; SELF_UPDATE_STATE_DIR="$WORK/st"
    SELF_UPDATE_PROVISIONING="$WORK/provisioning.env"
    JSON_MODE=0; E_NOT_FOUND=4; E_GENERIC=1; E_CONFLICT=5; TERM=dumb
    fail(){ printf 'FAILED: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
    warn(){ :; }; ok(){ printf 'OK — %s\n' "$1"; }
    systemctl(){ printf '%s\n' "$*" >> "$WORK/systemctl"; return 0; }
    eval "$block"
    . src/cmd_init.sh
    [[ "$tty" == yes ]] && _init_stdin_tty(){ return 0; } || _init_stdin_tty(){ return 1; }
    printf '%s' "$input" | _init_nightly_ask 2>&1
    echo "RC:$?"
    _su_nightly_is_on && echo "TIMER:on" || echo "TIMER:off"
  )
}
Q="Turn on nightly updates?"

out="$(ask $'1\n')"
if [[ "$out" == *"$Q"* && "$out" == *"TIMER:on"* && "$out" == *"RC:0"* ]] \
   && grep -q 'enable --now 5dive-self-update.timer' "$WORK/systemctl" \
   && grep -q 'ExecStart=/usr/local/bin/5dive self-update --nightly' "$WORK/units/5dive-self-update.service"; then
  ok_t "YES: the question shows and the answer turns the timer on (same units as self-update --on)"
else
  bad_t "Yes did not turn the timer on" "$out"
fi
[[ "$out" == *"Nightly updates are on"* ]] && ok_t "YES: init says it is on and how to turn it off" || bad_t "no confirmation line after Yes" "$out"

out="$(ask $'\n')"
[[ "$out" == *"TIMER:on"* ]] && ok_t "ENTER takes the recommended answer (on)" || bad_t "Enter did not take the default" "$out"

out="$(ask $'2\n')"
if [[ "$out" == *"$Q"* && "$out" == *"TIMER:off"* && ! -s "$WORK/systemctl" \
      && "$out" == *"sudo 5dive self-update --on"* ]]; then
  ok_t "NO: the timer stays off, nothing calls systemd, and init prints the one command for later"
else
  bad_t "No left a timer, or did not print the command" "$out | systemctl: $(cat "$WORK/systemctl")"
fi

out="$(ask $'1\n' no)"
[[ "$out" != *"$Q"* && "$out" == *"TIMER:off"* ]] \
  && ok_t "NON-INTERACTIVE: not asked, timer stays off (never on silently)" || bad_t "asked or turned on with no terminal" "$out"

out="$(ask $'2\n' yes no yes)"
[[ "$out" != *"$Q"* && "$out" == *"TIMER:on"* ]] \
  && ok_t "ALREADY ON: not asked, left on" || bad_t "asked again although nightly updates are on" "$out"

out="$(ask $'1\n' yes yes)"
[[ "$out" != *"$Q"* && "$out" == *"TIMER:off"* && "$out" != *FAILED* ]] \
  && ok_t "MANAGED BOX: not asked, nothing written (5dive updates it from its side)" || bad_t "asked on a managed box" "$out"

out="$(FIVEDIVE_SELF_UPDATE_HINT=0 ask $'1\n')"
[[ "$out" != *"$Q"* && "$out" == *"TIMER:off"* ]] \
  && ok_t "FIVEDIVE_SELF_UPDATE_HINT=0: not asked" || bad_t "the hint switch did not silence the question" "$out"

# A Yes whose unit write fails must not end init red: the agent already exists.
out="$(
  SELF_UPDATE_UNIT_DIR="$WORK/nope/units"
  JSON_MODE=0; E_NOT_FOUND=4; E_GENERIC=1; E_CONFLICT=5; TERM=dumb
  fail(){ exit "${1:-1}"; }; warn(){ :; }; ok(){ :; }; systemctl(){ return 0; }
  SELF_UPDATE_PROVISIONING="$WORK/none.env"
  eval "$block"; . src/cmd_init.sh; _init_stdin_tty(){ return 0; }
  printf '1\n' | _init_nightly_ask 2>&1; echo "RC:$?"
)"
[[ "$out" == *"RC:0"* && "$out" == *"could not be turned on"* ]] \
  && ok_t "A FAILED Yes warns with the command and does not fail init" || bad_t "a failed --on killed init or stayed silent" "$out"

# ------------------------------------------------------------------- wiring
. src/cmd_init.sh
body="$(declare -f cmd_init)"
last_stmt="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*}[[:space:]]*$' | tail -n1 | sed 's/^[[:space:]]*//; s/;$//')"
[[ "$last_stmt" == "_init_nightly_ask" ]] \
  && ok_t "cmd_init asks it LAST (after the agent is made and the next steps print)" || bad_t "the question is not init's last step" "last statement: $last_stmt"
steps="$(bash scripts/init-smoke.sh steps claude)"
if [[ "$(jq -r '.[-1].pick' <<<"$steps")" == "Turn on" ]] \
   && grep -q 'systemctl is-enabled --quiet 5dive-self-update.timer' scripts/init-smoke.sh; then
  ok_t "init-smoke answers Yes last and checks the timer is enabled"
else
  bad_t "init-smoke does not answer the new question (it would stop on it)" "$(jq -c '.[-1]' <<<"$steps" 2>&1)"
fi

echo; echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
