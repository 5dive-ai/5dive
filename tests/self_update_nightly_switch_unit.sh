#!/usr/bin/env bash
# DIVE-6799: nightly self-update on a self-hosted box is OFF by default and
# `5dive self-update --on` turns it on (lodar 2026-10-23: "keep it off then - but
# say that recommended to turn on nightly"). With it on, two guards hold:
#
#   ONE DAY BEHIND MANAGED — a tag installs only after this box has seen the
#     fleet route serve it for 24h. Fails open if a young tag installs.
#   NO NEW VERSION, NO RESTART — a run with nothing eligible installs nothing
#     and restarts nobody (a restart wipes the agent's live chat context).
#
# Hermetic: src/cmd_selfupdate.sh is sourced as shipped and the nightly path is
# driven END TO END through the real cmd_self_update, with curl / the installer
# / systemctl / the board stubbed. No unit, timer or agent on this box is touched.
set -uo pipefail
# The curl() stub below must never reach gh_org() (wiki: a-curl-stub-that-reaches-gh-org-is-a-fork-bomb).
export GH_ORG=5dive-ai

# DIVE-2211: name the tree this harness grades. NO `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-6799 nightly self-update switch/,/^# <<< DIVE-6799 nightly self-update switch/p' src/cmd_selfupdate.sh)"
if grep -q '_su_nightly_decide()' <<<"$block" && grep -q '_su_nightly_run()' <<<"$block"; then
  ok_t "nightly switch block is extractable from src/cmd_selfupdate.sh"
else
  bad_t "nightly switch block missing" "markers '# >>> / # <<< DIVE-6799 nightly self-update switch' not found"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

WORK="$(mktemp -d)"
DAY=86400; T0=1000000000; AT='@'

# ---------------------------------------------------------------- decision arms
# `dec <route> <installed> <seen> <seen_at> <tried> <tried_at> <now> <hour>`
dec() { ( version_lt(){ [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]; }
          eval "$block"; _su_nightly_decide "$@" ); }
check_dec() { # <want> <label> <args...>
  local want="$1" label="$2" got; shift 2
  got="$(dec "$@")"
  [[ "$got" == "$want" ]] && ok_t "$label" || bad_t "$label" "want '$want', got '$got' for: $*"
}
check_dec current "same tag as installed: nothing to do" v1.2.3 1.2.3 v1.2.3 $T0 "" "" $((T0+2*DAY)) 3
check_dec current "route OLDER than installed (a fleet rollback): never a downgrade" v1.2.2 1.2.3 v1.2.2 $T0 "" "" $((T0+2*DAY)) 3
check_dec waiting "a tag first seen 23h ago is skipped — one day behind managed" v1.3.0 1.2.3 v1.3.0 $T0 "" "" $((T0+DAY-3600)) 3
check_dec waiting "a tag never seen before starts the clock, it does not install" v1.3.0 1.2.3 v1.2.9 $T0 "" "" $((T0+5*DAY)) 3
check_dec install "a tag seen for 24h installs at night" v1.3.0 1.2.3 v1.3.0 $T0 "" "" $((T0+DAY)) 3
check_dec outside-window "an eligible tag waits for the night window" v1.3.0 1.2.3 v1.3.0 $T0 "" "" $((T0+DAY)) 14
check_dec retry-tomorrow "a tag that failed tonight is not retried every hour" v1.3.0 1.2.3 v1.3.0 $T0 v1.3.0 $((T0+DAY)) $((T0+DAY+3600)) 4
check_dec install "a failure last night does not block tonight" v1.3.0 1.2.3 v1.3.0 $T0 v1.3.0 $((T0+DAY)) $((T0+2*DAY)) 3
check_dec no-route "an unreadable route is a no" "" 1.2.3 v1.3.0 $T0 "" "" $((T0+2*DAY)) 3
check_dec current "an unreadable installed version is not 'older'" v1.3.0 "" v1.3.0 $T0 "" "" $((T0+2*DAY)) 3

# ------------------------------------------------------------- end-to-end arms
# One sandbox per call. katya is idle, nova holds an in_progress row.
# `nightly <state-dir> <route-tag> <now> <hour> [provisioning:yes]`
nightly() {
  local st="$1" tag="$2" now="$3" hour="$4" prov="${5:-no}"
  (
    PENDING_RESTART_DIR="$WORK/pending"; mkdir -p "$PENDING_RESTART_DIR"
    RESTARTS="$WORK/restarts"; : > "$RESTARTS"; : > "$WORK/installs"
    SELF_UPDATE_STATE_DIR="$st"; SELF_UPDATE_NOW="$now"; SELF_UPDATE_HOUR="$hour"
    SELF_UPDATE_INSTALLED=1.2.3; SELF_UPDATE_UNIT_DIR="$WORK/units"; mkdir -p "$SELF_UPDATE_UNIT_DIR"
    SELF_UPDATE_PROVISIONING="$WORK/provisioning.env"; rm -f "$SELF_UPDATE_PROVISIONING"
    [[ "$prov" == yes ]] && : > "$SELF_UPDATE_PROVISIONING"
    ROUTE_TAG="$tag"; JSON_MODE=1
    E_USAGE=2; E_NOT_FOUND=4; E_GENERIC=1; E_CONFLICT=5
    fail(){ printf 'FAILED: %s\n' "${2:-}" >&2; exit "${1:-1}"; }
    step(){ :; }; warn(){ printf 'warn: %s\n' "$*" >&2; }
    ok(){ shift; local filt="${1:-{\}}"; shift || true; jq -nc "$@" "$filt"; }
    json_array(){ printf '%s' "$( (( $# )) && printf '%s\n' "$@" | jq -Rc . | jq -sc . || echo '[]' )"; }
    curl(){ local a; for a in "$@"; do [[ "$a" == -o ]] && { : > "${!#}"; return 0; }; done; printf '%s\n' "$ROUTE_TAG"; }
    bash(){ local u="${CLI_VERSION_URL#file://}"; printf '%s\n' "$(cat "$u" 2>/dev/null || printf '%s' "$CLI_VERSION_URL")" >> "$WORK/installs"
            [[ -f "$WORK/install-fails" ]] && return 1; return 0; }
    systemctl() {
      case "${1:-}" in
        list-units) printf '5dive-agent%skatya.service loaded active running x\n5dive-agent%snova.service loaded active running x\n' "$AT" "$AT" ;;
        restart)    printf '%s\n' "${2:-}" >> "$RESTARTS" ;;
        show)       printf '\n' ;;
        *)          return 0 ;;
      esac
    }
    _team_bot_install_listener(){ return 0; }
    _agent_home(){ printf '/nonexistent/%s\n' "${1:-}"; }
    agent_type(){ printf 'claude\n'; }
    sqlq(){ printf '%s' "$1"; }
    db(){ [[ "$1" == *nova* ]] && echo 1 || echo 0; }
    _hb_agent_idle(){ return 0; }
    . src/cmd_selfupdate.sh
    _hg_capture(){ return 0; }; _hg_probe(){ systemctl restart "$1"; printf 'healthy\n'; }
    _agent_payload_fingerprint(){
      local c; c=$(cat "$WORK/fpc" 2>/dev/null || echo 0); c=$((c+1))
      printf '%s' "$c" > "$WORK/fpc"; printf 'fp-%s\n' "$c"
    }
    ( _su_nightly_run 2>/dev/null ); echo "RC:$?"
  )
}
restarts(){ tr '\n' ' ' < "$WORK/restarts"; }
installs(){ tr '\n' ' ' < "$WORK/installs"; }
last(){ sed -n "s/^$2=//p" "$1/last"; }

ST="$WORK/st1"
out="$(nightly "$ST" v1.2.3 $T0 3)"
if [[ -z "$(restarts)" && -z "$(installs)" && "$(last "$ST" outcome)" == current ]]; then
  ok_t "NO NEW VERSION: nothing installed, NOBODY restarted, and --status has the reason"
else
  bad_t "a run with no newer tag did something" "restarts='$(restarts)' installs='$(installs)' out=$out"
fi

ST="$WORK/st2"
nightly "$ST" v1.3.0 $T0 3 >/dev/null
nightly "$ST" v1.3.0 $((T0+DAY-3600)) 4 >/dev/null
if [[ -z "$(installs)" && -z "$(restarts)" && "$(last "$ST" outcome)" == waiting \
      && "$(sed -n 's/^at=//p' "$ST/seen")" == "$T0" ]]; then
  ok_t "YOUNG TAG: 23h after the first sighting it is still skipped, and the sighting kept its first time"
else
  bad_t "a tag younger than 24h was taken (or the sighting was re-stamped)" "installs='$(installs)' seen=$(cat "$ST/seen" 2>/dev/null)"
fi
out="$(nightly "$ST" v1.3.0 $((T0+DAY)) 3)"
if [[ "$(installs)" == "v1.3.0 " ]]; then
  ok_t "24h later, at night, it installs — pinned to the tag that passed the wait"
else
  bad_t "the eligible tag did not install, or not pinned" "installs='$(installs)' out=$out"
fi
r="$(restarts)"
if [[ "$r" == *katya* && "$r" != *nova* && -f "$WORK/pending/nova" ]]; then
  ok_t "BUSY AGENT: only the idle agent restarted; the busy one owes its restart for its next idle moment"
else
  bad_t "the busy agent was restarted, or the idle one was not" "restarts='$r' pending=$(ls "$WORK/pending" 2>/dev/null | tr '\n' ' ')"
fi
[[ "$(last "$ST" outcome)" == installed ]] && ok_t "--status records 'installed'" || bad_t "last outcome after install" "$(cat "$ST/last")"

ST="$WORK/st3"; rm -rf "$WORK/pending"; : > "$WORK/install-fails"
nightly "$ST" v1.4.0 $T0 3 >/dev/null
out="$(nightly "$ST" v1.4.0 $((T0+DAY)) 3)"
if [[ "$out" == *"RC:1"* && "$(last "$ST" outcome)" == failed ]]; then
  ok_t "FAILED UPDATE: the run exits non-zero and --status shows 'failed'"
else
  bad_t "a failed install was not recorded" "out=$out last=$(cat "$ST/last" 2>/dev/null)"
fi
nightly "$ST" v1.4.0 $((T0+DAY+3600)) 4 >/dev/null
[[ -z "$(installs)" && "$(last "$ST" outcome)" == retry-tomorrow ]] \
  && ok_t "the failed tag is not retried an hour later" || bad_t "retried within the night" "installs='$(installs)'"
rm -f "$WORK/install-fails"

ST="$WORK/st4"
nightly "$ST" v1.3.0 $T0 3 yes >/dev/null
nightly "$ST" v1.3.0 $((T0+2*DAY)) 3 yes >/dev/null
[[ -z "$(installs)" && "$(last "$ST" outcome)" == managed ]] \
  && ok_t "MANAGED BOX: the nightly run does nothing (update.sh owns it)" || bad_t "the nightly run installed on a managed box" "installs='$(installs)'"

# ---------------------------------------------------------------- --on / --off
# `sw <verb> [provisioning:yes]` — runs the switch with systemctl stubbed.
sw() {
  local verb="$1" prov="${2:-no}"
  (
    SELF_UPDATE_UNIT_DIR="$WORK/units"; mkdir -p "$SELF_UPDATE_UNIT_DIR"
    SELF_UPDATE_STATE_DIR="$WORK/sw"; SELF_UPDATE_PROVISIONING="$WORK/provisioning.env"; rm -f "$SELF_UPDATE_PROVISIONING"
    [[ "$prov" == yes ]] && : > "$SELF_UPDATE_PROVISIONING"
    JSON_MODE=0; E_NOT_FOUND=4; E_GENERIC=1; E_CONFLICT=5
    fail(){ printf 'FAILED: %s\n' "${2:-}"; exit "${1:-1}"; }
    warn(){ :; }; ok(){ printf 'OK — %s\n' "$1"; }
    systemctl(){ printf '%s\n' "$*" >> "$WORK/systemctl"; return 0; }
    eval "$block"
    "$verb"
  )
}
rm -rf "$WORK/units"; : > "$WORK/systemctl"
out="$(sw _su_nightly_on)"
if [[ -f "$WORK/units/5dive-self-update.timer" ]] && grep -q 'ExecStart=/usr/local/bin/5dive self-update --nightly' "$WORK/units/5dive-self-update.service" \
   && grep -q 'enable --now 5dive-self-update.timer' "$WORK/systemctl"; then
  ok_t "--on writes and enables the timer"
else
  bad_t "--on did not install the timer" "out=$out"
fi
[[ -z "$(sw _su_nightly_hint)" ]] && ok_t "with it on, no 'Recommended' line" || bad_t "hint printed while on"
out="$(sw _su_nightly_off)"
[[ ! -e "$WORK/units/5dive-self-update.timer" && ! -e "$WORK/units/5dive-self-update.service" ]] \
  && ok_t "--off removes both units" || bad_t "--off left a unit" "$(ls "$WORK/units")"
[[ "$(sw _su_nightly_hint)" == *"Recommended: turn on nightly updates with 5dive self-update --on"* ]] \
  && ok_t "with it off, the 'Recommended' line prints" || bad_t "hint missing while off"
out="$(sw _su_nightly_on yes)"
if [[ "$out" == FAILED:* && ! -e "$WORK/units/5dive-self-update.timer" ]]; then
  ok_t "MANAGED BOX: --on refuses, says why, and writes nothing"
else
  bad_t "--on went through on a managed box" "out=$out"
fi
[[ -z "$(sw _su_nightly_hint yes)" ]] && ok_t "MANAGED BOX: no 'Recommended' line" || bad_t "hint printed on a managed box"
[[ -z "$(FIVEDIVE_SELF_UPDATE_HINT=0 sw _su_nightly_hint)" ]] && ok_t "FIVEDIVE_SELF_UPDATE_HINT=0 silences it" || bad_t "hint env ignored"

# ------------------------------------------------------------- install.sh arms
# NEGATIVE CONTROL for the grader: a fresh install must leave no timer. The only
# place install.sh may NAME the timer is its uninstall block, which removes it.
if ! grep -nE 'OnCalendar|enable --now 5dive-self-update|self-update --on' install.sh | grep -vE '^[0-9]+:\s*#' | grep -q .; then
  ok_t "install.sh installs no nightly timer (off by default)"
else
  bad_t "install.sh creates or enables the nightly timer" "$(grep -nE 'OnCalendar|enable --now 5dive-self-update|self-update --on' install.sh)"
fi
lastcmd="$(grep -vE '^\s*(#|$)' install.sh | tail -n1)"
[[ "$lastcmd" == '5dive _self_update_hint 2>/dev/null || true' ]] \
  && ok_t "the 'Recommended' line is the last thing install.sh prints" || bad_t "install.sh does not end with the hint" "last line: $lastcmd"
grep -qF 'rm -f "$SYSTEMD_DIR/5dive-self-update.timer"' install.sh \
  && ok_t "uninstall removes the timer" || bad_t "uninstall leaves the timer behind"
body="$(sed -n '/^cmd_self_update()/,/^}/p' src/cmd_selfupdate.sh)"
[[ "$body" == *"_su_nightly_hint >&2"* ]] && ok_t "a manual self-update ends with the same line" || bad_t "manual self-update prints no hint"
grep -qE '^\s+_self_update_hint\)$' src/main.sh && grep -q -- '--status' src/main.sh \
  && ok_t "main dispatches _self_update_hint and --status" || bad_t "dispatch missing"

echo; echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
