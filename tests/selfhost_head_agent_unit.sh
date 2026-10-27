#!/usr/bin/env bash
# DIVE-7118 — the README's fresh-box path gives a head agent that can work, and a
# seat whose own turns are refused reads not-ok.
#
# Live QA 2026-10-27 (marketing/selfhost-real-2026-10-27/qa-olivia-secrets-ssl.md,
# gaps 6 and 7), on a fresh self-hosted box:
#
#   I  `sudo 5dive init` saved an Anthropic key into the box's SHARED login, then
#      `sudo 5dive agent import olivia --as=olivia` (the README's next line) made
#      her a new EMPTY account and deferred her login, and gave her the pack's
#      `standard` where create gives the first agent on a box `admin`.
#   R  Every interactive turn came back "Credit balance is too low" while
#      `auth status --probe` (headless) said ok, `agent list`/`info` said
#      AUTH ok / STATE ready, and the heartbeat kept dispatching into the seat.
#
#   F/D/L  witty-palm 2026-10-27 (customer-hit): four seats on one login woke
#      every 30 min and stopped with no reply (StopFailure 'stop'), every status
#      read ok, nobody was told (DIVE-6734), and the lead could not move them.
#
# Every positive arm is red on origin/main; every control is green on both
# trees. The counts are in the delivery.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
STATE_DIR="$(mktemp -d)"   # cmd_auth.sh reads it at source time; never the live /var/lib/5dive
# shellcheck source=/dev/null
source src/cmd_auth.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
[[ -r src/lib/seat_refusal.sh ]] && source src/lib/seat_refusal.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d); rm -rf "$STATE_DIR"
AUTH_PROFILES_DIR="$TMP/auth-profiles"
CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$AUTH_PROFILES_DIR" "$CONNECTORS_DIR"
declare -A TYPE_AUTH=([claude]="$CONNECTORS_DIR/anthropic.env:ANTHROPIC_API_KEY")
declare -A TYPE_API_FILE=([claude]="anthropic.env")

echo '== I: init, then agent import (the real cmd_import seam) =='
printf '%s\n' '{"packFormat":1,"agentName":"olivia","config":{"type":"claude","isolation":"standard"},"includes":{"memory":false}}' > "$TMP/manifest.json"
printf '%s\n' '{"packFormat":1,"agentName":"olivia","config":{"type":"claude","isolation":"sandboxed"},"includes":{"memory":false}}' > "$TMP/manifest-sandboxed.json"
: > "$TMP/olivia.tar.gz"
export I_MANIFEST="$TMP/manifest.json" I_AGENTS='{"agents":{}}'
require_root() { :; }
registry_read() { printf '%s\n' "$I_AGENTS"; }
_agents_md_is() { return 1; }
_pack_safe_extract() { cp "$I_MANIFEST" "$2/manifest.json"; }
_pack_harness_targets() { printf '%s\n' claude codex; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
resolve_model_for_profile() { printf '%s' "$1"; }
is_known_type() { [[ "$1" == claude || "$1" == codex ]]; }
box_seat_isolation() { printf ''; }
step() { :; }
cmd_create() { printf '%s\n' "$@" > "$I_REC"; return 1; }
import_argv() { # <label> <args>... — the argv cmd_create got, one per line
  export I_REC="$TMP/$1.argv"; shift
  rm -f "$I_REC"
  ( cmd_import "$TMP/olivia.tar.gz" "$@" ) >/dev/null 2>&1
  cat "$I_REC" 2>/dev/null || echo "(cmd_create not reached)"
}
has() { grep -qxF -- "$2" <<<"$1" && echo yes || echo no; }

# The fresh box: init's "Anthropic API key" step wrote the shared login.
printf 'ANTHROPIC_API_KEY=sk-ant-api03-fixture\n' > "$CONNECTORS_DIR/anthropic.env"
A=$(import_argv fresh --as=olivia)
eq_t "I1 first agent on an empty box: a pack's 'standard' becomes admin" yes "$(has "$A" --isolation=admin)"
eq_t "I2 the shared login init saved is used: no per-agent account" no "$(grep -c '^--auth-profile=' <<<"$A" | sed 's/^0$/no/; s/^[1-9].*/yes/')"
eq_t "I3 ...and the login is not deferred" no "$(has "$A" --defer-auth)"

A=$(import_argv explicit --as=olivia --isolation=standard)
eq_t "I4 control: an explicit --isolation=standard is kept" yes "$(has "$A" --isolation=standard)"
export I_AGENTS='{"agents":{"lead":{"type":"claude"}}}'
A=$(import_argv second --as=olivia)
eq_t "I5 control: a second agent keeps the pack's standard" yes "$(has "$A" --isolation=standard)"
export I_AGENTS='{"agents":{}}' I_MANIFEST="$TMP/manifest-sandboxed.json"
A=$(import_argv sandboxed --as=olivia)
eq_t "I6 control: a pack that asks to be sandboxed stays sandboxed" yes "$(has "$A" --isolation=sandboxed)"
export I_MANIFEST="$TMP/manifest.json"
rm -f "$CONNECTORS_DIR/anthropic.env"
A=$(import_argv nologin --as=olivia)
eq_t "I7 control: no shared login -> the per-agent account, deferred, as before" "yes|yes" \
  "$(has "$A" --auth-profile=olivia)|$(has "$A" --defer-auth)"
printf 'ANTHROPIC_API_KEY=sk-ant-api03-fixture\n' > "$CONNECTORS_DIR/anthropic.env"
A=$(import_argv named --as=olivia --auth-profile=work)
eq_t "I8 control: a named account is never replaced by the shared login" yes "$(has "$A" --auth-profile=work)"

echo '== R: the seat'"'"'s own last turn =='
T="$TMP/home/agent-olivia/.claude/projects/-home-claude-projects"
mkdir -p "$T"
user_rec()  { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hi"}}\n' "$1"; }
err_rec()   { printf '{"type":"assistant","isApiErrorMessage":true,"timestamp":"%s","error":"%s","message":{"model":"<synthetic>","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2" "$3"; }
ok_rec()    { printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}]}}\n' "$1"; }
export SEAT_TRANSCRIPT_ROOT="$TMP/home/agent-olivia/.claude/projects"
refusal() { seat_account_refusal olivia "${1:-0}" 2>/dev/null || echo none; }
T0=$(date -u -d '2026-10-27T10:18:33Z' +%s)

{ printf 'not json, a record cut by tail\n'; user_rec 2026-10-27T10:18:32Z; err_rec 2026-10-27T10:18:33.123Z billing_error "Credit balance is too low"; } > "$T/s1.jsonl"
eq_t "R1 a billing refusal is read off the seat's own transcript" "Credit balance is too low" "$(refusal)"
eq_t "R2 control: a refusal from before the seat last started does not count" none "$(refusal $((T0 + 60)))"
{ user_rec 2026-10-27T10:18:32Z; err_rec 2026-10-27T10:18:33Z rate_limit "You've hit your session limit"; } > "$T/s1.jsonl"
eq_t "R3 control: a rate limit is not an account refusal (it rolls back on its own)" none "$(refusal)"
{ err_rec 2026-10-27T10:18:33Z billing_error "Credit balance is too low"; user_rec 2026-10-27T10:20:00Z; ok_rec 2026-10-27T10:20:05Z; } > "$T/s1.jsonl"
eq_t "R4 control: a later turn that got through clears it" none "$(refusal)"
{ err_rec 2026-10-27T10:18:33Z authentication_failed "Invalid API key · Fix external API key"; } > "$T/s1.jsonl"
eq_t "R5 an authentication refusal counts too" "Invalid API key · Fix external API key" "$(refusal)"
rm -f "$T"/*.jsonl
eq_t "R6 control: no transcript is no reading, not a refusal" none "$(refusal)"

{ err_rec 2026-10-27T10:18:33Z billing_error "Credit balance is too low"; } > "$T/s1.jsonl"
seat_started_epoch() { echo 0; }
AH=$(agent_auth_health opencode "" olivia)
eq_t "R7 agent_auth_health: a refused seat reads 'refused', not ok" refused "${AH%%|*}"
eval "$(awk '$0 ~ /^_agent_operational_state\(\) \{/ { on = 1 } on { print } on && $0 == "}" { exit }' src/cmd_agent.sh)"
eq_t "R8 ...and its operational verdict is degraded, not ready" degraded "$(_agent_operational_state active refused clear)"
eq_t "R8b control: an ok credential with a clear start stays ready" ready "$(_agent_operational_state active ok clear)"

PY="$TMP/snapshot.py"
awk '/^# __5DIVE_AGENT_LIST_PY_BEGIN__$/ { emit=1; next } /^# __5DIVE_AGENT_LIST_PY_END__$/ { exit } emit { print }' src/cmd_agent.sh > "$PY"
mkdir -p "$TMP/profiles" "$TMP/sudoers"
# A seat name no host runs: the snapshot reads the REAL unit's start time, and a
# live 5dive-agent@olivia (poke-two has one) would filter the fixture's turns.
ln -s agent-olivia "$TMP/home/agent-qa7118"
printf '%s\n' '{"agents":{"qa7118":{"type":"opencode","channels":"none","workdir":"/work","isolation":"admin","heartbeat":{"enabled":false},"createdAt":"2026-10-27T10:16:59Z"}}}' > "$TMP/agents.json"
snap() { python3 "$PY" "$TMP/agents.json" "$TMP/profiles" "$TMP/connectors" "$TMP/home" "$TMP/sudoers" /default 2>/dev/null; }
OUT=$(snap)
eq_t "R9 agent list (the snapshot) shows AUTH refused, with what the account said" "refused|Credit balance is too low" \
  "$(jq -r '.[0].health.auth | "\(.state)|\(.refusal)"' <<<"$OUT")"
{ err_rec 2026-10-27T10:18:33Z rate_limit "You've hit your session limit"; } > "$T/s1.jsonl"
eq_t "R9b control: the snapshot leaves a rate-limited seat's auth ok" ok "$(snap | jq -r '.[0].health.auth.state')"
{ err_rec 2026-10-27T10:18:33Z billing_error "Credit balance is too low"; } > "$T/s1.jsonl"

# auth status --agent --probe: the probe passes (headless), the seat's turn did not.
registry_read_checked() { printf '%s\n' '{"agents":{"olivia":{"type":"claude"}}}'; }
auth_status_one() { echo ok; }
_agent_startup_credential_health() { echo 'clear|'; }
out=$(JSON_MODE=1 cmd_auth_status --agent=olivia --probe 2>/dev/null)
eq_t "R10 auth status --agent --probe: ok turns stale when the seat's own turn was refused" "stale|Credit balance is too low" \
  "$(jq -r '"\(.data.claude)|\(.seat.reason)"' <<<"$out" 2>/dev/null)"
rm -f "$T"/*.jsonl
out=$(JSON_MODE=1 cmd_auth_status --agent=olivia --probe 2>/dev/null)
eq_t "R10b control: with no refusal the probe's ok stands" ok "$(jq -r '.data.claude' <<<"$out" 2>/dev/null)"

# The heartbeat hold sits above the task pick, beside the spend-cap hold.
hb_hold=$(awk '/DIVE-7118 account-refusal hold/,/^    fi$/' src/cmd_heartbeat.sh)
pick_ln=$(grep -n 'Wake the agent against ONE concrete todo' src/cmd_heartbeat.sh | cut -d: -f1)
hold_ln=$(grep -n 'DIVE-7118 account-refusal hold' src/cmd_heartbeat.sh | cut -d: -f1)
[[ -n "$hold_ln" && -n "$pick_ln" ]] && (( hold_ln < pick_ln )) && grep -q 'seat_turn_trouble "$name" "$(seat_started_epoch "$name")"' <<<"$hb_hold" && grep -q 'continue' <<<"$hb_hold" \
  && ok_t "R11 the heartbeat skips a refused seat before it picks a row" \
  || bad_t "R11 the heartbeat skips a refused seat before it picks a row" "hold at ${hold_ln:-none}, pick at ${pick_ln:-none}"
grep -qx '  src/lib/seat_refusal.sh' build.sh \
  && ok_t "R12 the reader is in the bundle" || bad_t "R12 the reader is in the bundle" "build.sh does not list src/lib/seat_refusal.sh"

echo '== F: a run of turns that stop on an API error (witty-palm, StopFailure stop) =='
S="$TMP/stamps"; mkdir -p "$S"; export SEAT_STOP_STAMP_DIR="$S"
trouble() { local t; t=$(seat_turn_trouble olivia "${1:-0}" 2>/dev/null) || { echo none; return; }; printf '%s\n' "${t%%$'\t'*}"; }
seat_started_epoch() { echo 0; }
ms() { echo $(( $(date -u -d "$1" +%s) * 1000 )); }
api_err() { err_rec "$1" "${2:-unknown}" "${3:-API Error: 400 invalid_request_error}"; }
clear_t() { rm -f "${T:?}"/*.jsonl; }
clear_s() { rm -f "${S:?}"/*.stamp; }
wakes() { # <kind: err|rl|ovl|none> — three heartbeat wakes, a new transcript each, an hour apart
  local i
  for i in 1 2 3; do
    { user_rec "2026-10-27T0${i}:00:00Z"
      case "$1" in
        err) api_err "2026-10-27T0${i}:00:05Z" ;;
        rl)  err_rec "2026-10-27T0${i}:00:05Z" rate_limit "You've hit your session limit" ;;
        ovl) err_rec "2026-10-27T0${i}:00:05Z" unknown "API Error: 529 Overloaded" ;;
      esac; } > "$T/w$i.jsonl"
    touch -d "2026-10-27T0${i}:00:05Z" "$T/w$i.jsonl"
  done
}
clear_t; wakes err
eq_t "F1 three wakes in a row that end in an API error read failing (across transcripts)" failing "$(trouble)"
eq_t "F1b ...and the reason names the run" yes "$(seat_account_refusal olivia 0 2>/dev/null | grep -q '^3 turns in a row failed since 2026-10-27T01:00:05Z' && echo yes || echo no)"
clear_t; wakes none
eq_t "F3 control: wakes with no reply and no stop stamp are not failures (in flight, or interrupted)" none "$(trouble)"
ms 2026-10-27T03:00:07Z > "$S/notify-ningidrin_stop_autonomous-silent-noepoch.stamp"
eq_t "F2 wakes with no reply and the hook's 'stop' stamp after them read failing (the witty-palm shape)" failing "$(trouble)"
eq_t "F2b control: a restart after the last stop clears it" none "$(trouble "$(date -u -d 2026-10-27T03:30:00Z +%s)")"
clear_s; ms 2026-10-27T03:00:07Z > "$S/notify-ningidrin_ratelimit_autonomous-silent-r1761555600.stamp"
eq_t "F2c control: a rate-limit stamp is not a stop stamp" none "$(trouble)"
clear_s; clear_t; wakes rl
eq_t "F4 control: three rate limits in a row are not a stuck login" none "$(trouble)"
clear_t; wakes ovl
eq_t "F5 control: three overloads in a row are a passing outage, not a stuck login" none "$(trouble)"
clear_t
{ user_rec 2026-10-27T01:00:00Z; api_err 2026-10-27T01:00:05Z; user_rec 2026-10-27T01:10:00Z; api_err 2026-10-27T01:10:05Z; } > "$T/w1.jsonl"
eq_t "F6 control: two failures ten minutes apart are not yet a run" none "$(trouble)"
{ user_rec 2026-10-27T01:00:00Z; api_err 2026-10-27T01:00:05Z; user_rec 2026-10-27T02:10:00Z; api_err 2026-10-27T02:10:05Z; } > "$T/w1.jsonl"
eq_t "F7 ...two failures over an hour apart are" failing "$(trouble)"
{ user_rec 2026-10-27T01:00:00Z; api_err 2026-10-27T01:00:05Z; user_rec 2026-10-27T02:10:00Z; api_err 2026-10-27T02:10:05Z; user_rec 2026-10-27T02:40:00Z; ok_rec 2026-10-27T02:40:05Z; } > "$T/w1.jsonl"
eq_t "F8 control: a turn that got through ends the run" none "$(trouble)"
{ user_rec 2026-10-27T01:00:00Z; api_err 2026-10-27T01:00:05Z; user_rec 2026-10-27T02:10:00Z; api_err 2026-10-27T02:10:05Z; } > "$T/w1.jsonl"
AH=$(agent_auth_health opencode "" olivia)
eq_t "F9 agent_auth_health reads failing, and the verdict is degraded" "failing|degraded" "${AH%%|*}|$(_agent_operational_state active "${AH%%|*}" clear)"
eq_t "F10 agent list (the snapshot) reads failing too, with the run" "failing|2 turns in a row failed since 2026-10-27T01:00:05Z" \
  "$(snap | jq -r '.[0].health.auth | "\(.state)|\((.refusal // "") | sub(": API Error.*$"; ""))"')"
clear_t; wakes none
R="$TMP/home/agent-olivia/.cache/5dive-telegram/resume"; mkdir -p "$R"
ms 2026-10-27T03:00:07Z > "$R/notify-ningidrin_stop_autonomous-silent-noepoch.stamp"
eq_t "F11 the snapshot reads the stop stamp the same way" failing "$(snap | jq -r '.[0].health.auth.state')"
rm -f "${R:?}"/*.stamp
eq_t "F11b control: the snapshot with no stamp leaves it ok" ok "$(snap | jq -r '.[0].health.auth.state')"
hb_hold=$(awk '/DIVE-7118 account-refusal hold/,/^    fi$/' src/cmd_heartbeat.sh)
grep -qF '"${_refusal%%$'"'"'\t'"'"'*}" == refused' <<<"$hb_hold" \
  && ok_t "F12 the heartbeat holds only a refused seat; a failing one keeps its wakes" \
  || bad_t "F12 the heartbeat holds only a refused seat; a failing one keeps its wakes" "the hold does not check the kind"
clear_t

echo '== D: the owner is told once per stuck login (the exception to DIVE-6734) =='
eval "$(awk '/^_hb_stuck_login_text\(\) \{/,/^}$/' src/cmd_heartbeat.sh)"
eval "$(awk '/^_hb_stuck_login_deliver\(\) \{/,/^}$/' src/cmd_heartbeat.sh)"
eval "$(awk '/^_hb_stuck_login_sweep\(\) \{/,/^}$/' src/cmd_heartbeat.sh)"
export HB_STUCK_LOGIN_DIR="$TMP/stuck" HB_STUCK_LOGIN_EVERY_SEC=0
clear_sent() { rm -f "${HB_STUCK_LOGIN_DIR:?}"/sent-*; }
any_sent() { ls "$HB_STUCK_LOGIN_DIR"/sent-* >/dev/null 2>&1 && echo yes || echo no; }
REGISTRY="$TMP/registry.json"
printf '%s\n' '{"agents":{"claude-boss":{"type":"claude"},"claude-mario":{"type":"claude","authProfile":"ningidrin"},"claude-oleg":{"type":"claude","authProfile":"ningidrin"},"claude-artem":{"type":"claude","authProfile":"ningidrin"},"claude-ruslan":{"type":"claude","authProfile":"ningidrin"}}}' > "$REGISTRY"
for n in claude-boss claude-mario claude-oleg claude-artem claude-ruslan; do : > "$CONNECTORS_DIR/telegram-$n.env"; done
DM="$TMP/dm.log"; : > "$DM"
_hb_log() { :; }
_task_agent_channel() { D_BOT="$1"; [[ "${D_UNREACHABLE:-0}" == 0 ]]; }
_task_send_owner() { printf 'bot=%s\t%s\n' "$D_BOT" "${1//$'\n'/ }" >> "$DM"; TASK_SEND_DELIVERED=1; }
STUCK=" claude-mario claude-oleg claude-artem claude-ruslan "
seat_turn_trouble() { [[ "$STUCK" == *" $1 "* ]] && printf 'failing\t3 turns in a row failed\n'; }
sweep() { _hb_stuck_login_sweep "$(date +%s)" "$(cat "$REGISTRY")"; }
sweep
eq_t "D1 four stuck seats on one login: ONE message" 1 "$(wc -l < "$DM")"
eq_t "D1b ...naming the login, the seats and the fix, sent through a bot that is not stuck" yes \
  "$(grep -q 'bot=claude-boss.*"ningidrin" has stopped working\. .*claude-mario.*claude-ruslan.*Settings → AI subscriptions' "$DM" && echo yes || echo no)"
sweep; sweep
eq_t "D2 later passes while still stuck: no second message" 1 "$(wc -l < "$DM")"
STUCK=" "; sweep
eq_t "D3 the login works again: its stamp goes" no "$(any_sent)"
STUCK=" claude-oleg "; sweep
eq_t "D3b ...so the next episode is told, once" 2 "$(wc -l < "$DM")"
STUCK=" claude-boss "; : > "$DM"; clear_sent; sweep
eq_t "D4 the box's shared login is named as that" yes "$(grep -q "shared AI login has stopped working" "$DM" && echo yes || echo no)"
: > "$DM"; clear_sent; STUCK=" claude-mario "; D_UNREACHABLE=1 sweep
eq_t "D5 control: an owner who could not be reached is retried next pass (no stamp)" "0|no" "$(wc -l < "$DM")|$(any_sent)"
# The real reader behind the sweep: a rate-limited seat must never send it.
unset -f seat_turn_trouble; source src/lib/seat_refusal.sh; seat_started_epoch() { echo 0; }
printf '%s\n' '{"agents":{"olivia":{"type":"claude","authProfile":"work"}}}' > "$REGISTRY"
: > "$CONNECTORS_DIR/telegram-olivia.env"
: > "$DM"; clear_sent; clear_t; wakes rl; sweep
eq_t "D6 control: three rate limits in a row send nothing" 0 "$(wc -l < "$DM")"
clear_t; wakes err; sweep
eq_t "D7 ...and the same seat stuck on a real error sends one, end to end through the reader" 1 "$(grep -c '"work" has stopped working' "$DM")"
grep -q '_hb_stuck_login_sweep "$now" "$reg"' src/cmd_heartbeat.sh \
  && ok_t "D8 the heartbeat tick runs the sweep" || bad_t "D8 the heartbeat tick runs the sweep" "no call in cmd_heartbeat_tick"
clear_t

_syn=""; for f in src/cmd_agent.sh src/cmd_auth.sh src/cmd_heartbeat.sh src/cmd_account.sh src/main.sh src/lib/seat_refusal.sh; do bash -n "$f" 2>/dev/null || _syn+=" $f"; done
eq_t "S1 every file this row touches parses (a quote inside a single-quoted jq program broke agent info once)" "" "$_syn"

echo '== L: the lead moves a stuck seat to another login, without root =='
source src/cmd_account.sh 2>/dev/null
LREC="$TMP/lead.rec"
with_registry_lock() { "$@"; }
cmd_agent_set_account() { printf 'set %s %s\n' "$1" "$2" >> "$LREC"; }
cmd_restart() { printf 'restart %s\n' "$1" >> "$LREC"; }
registry_read() { printf '%s\n' '{"agents":{"claude-boss":{"isolation":"admin"},"claude-pal":{"isolation":"standard"},"claude-mario":{"isolation":"standard"}}}'; }
_gate_uid_to_agent() { case "$1" in 1001) echo claude-boss ;; 1002) echo claude-pal ;; esac; }
mark_reported() { :; }
rc1() { sed 's/^rc=[1-9][0-9]*/rc=1/'; }
root_half() { # <sudo uid> <wire...>
  local uid="$1"; shift; : > "$LREC"
  ( _gate_is_root() { return 0; }; SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_lead_account_delegated ) >/dev/null 2>&1
  echo "rc=$?|$(tr '\n' ';' < "$LREC")"
}
eq_t "L1 an admin seat moves a stuck seat to another login (set-account, which restarts it)" "rc=0|set claude-mario work;" "$(root_half 1001 text set claude-mario work)"
eq_t "L2 ...or just restarts it" "rc=0|restart claude-mario;" "$(root_half 1001 text restart claude-mario)"
eq_t "L3 control: a standard seat is refused, nothing runs" "rc=1|" "$(root_half 1002 text set claude-mario work | rc1)"
eq_t "L4 control: a uid that is not a seat is refused" "rc=1|" "$(root_half 4242 text restart claude-mario | rc1)"
eq_t "L5 control: anything but restart/set is refused" "rc=1|" "$(root_half 1001 text rm claude-mario | rc1)"
eq_t "L5b control: a bad account name is refused" "rc=1|" "$(root_half 1001 text set claude-mario '../x' | rc1)"
WIRE="$TMP/wire"
caller_half() { # <grant 0|1> <args...>
  local g="$1"; shift; : > "$WIRE"; : > "$LREC"
  ( _gate_is_root() { return 1; }
    sudo() { if [[ "$1 $2" == "-n -l" ]]; then (( g )); return; fi; [[ "$*" == "-n /usr/local/bin/5dive _lead_account" ]] && tr '\0' '|' > "$WIRE"; }
    cmd_agent_recover "$@" ) >/dev/null 2>&1
  echo "rc=$?|$(cat "$WIRE")|$(tr '\n' ';' < "$LREC")"
}
eq_t "L6 a non-root seat with the grant crosses the rail with the operation on stdin" "rc=0|text|set|claude-mario|work||" "$(caller_half 1 claude-mario --to=work)"
eq_t "L6b ...restart when no login is named" "rc=0|text|restart|claude-mario||" "$(caller_half 1 claude-mario)"
eq_t "L7 control: a seat whose grant does not reach the rail is refused before anything runs" "rc=1||" "$(caller_half 0 claude-mario --to=work | rc1)"
grep -q 'cmd_agent_recover "\$@"' src/main.sh && grep -q 'cmd_lead_account_delegated "\$@"' src/main.sh && grep -q ' _lead_account ' src/cmd_plugin.sh \
  && ok_t "L8 main dispatches agent recover and the hidden _lead_account" || bad_t "L8 main dispatches agent recover and the hidden _lead_account" "dispatch or builtin verb missing"
echo
printf 'DIVE-7118 self-host head agent: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
