#!/usr/bin/env bash
# TIER: core — another seat's Telegram token, unreadable to the caller (DIVE-9491).
#
# DIVE-7974 step 3 drops the group read on /etc/5dive/connectors/telegram-*.env.
# After it, a seat reads ONLY its own file (u:agent-<x>:r); root and `claude`
# still read all. Every non-root reader of ANOTHER seat's file then sees
# "present, unreadable". Each arm below models that box and asks: does the
# reader still deliver (through a bot it may use) or hand the job to root — or
# does it go quiet, or worse, send through the WRONG bot?
#
#   C  _task_agent_channel   blind, never the caller's env token on <x>'s chat
#   G  _task_gate_bot_token  empty -> the gate card goes to root (DIVE-9345)
#   P  _task_agent_paired    undetermined (2), never "unpaired" (1)
#   D  disk alarm            the seat's own bot delivers; else "handed to root"
#   S  stuck-login notice    the seat's own bot delivers, not <x>'s chat
#   H  human recipient probe "only root can read", never "no bot"
#   R  telegram-info/-discover, cos set-avatar/rotate  -> require_root
#   T  team-bot relay, digest tick, heartbeat tick: root before the first read
#   M  mutations: revert one hand-off -> its arm goes red
#
# "Unreadable" is modelled by overriding the one seam every reader asks first,
# _tg_token_unreadable, so the arms hold under a root CI runner too (root ignores
# file modes). As non-root the file is ALSO chmod 000, so the seam and the real
# mode agree. Run: bash tests/telegram_token_other_seat_unit.sh (no root, no net).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/tg-other-seat.XXXXXX)
trap 'rc=$?; chmod -R u+rw "${TMP:-/nonexistent}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

PASS=0 FAIL=0
eq() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; echo "     want: $2"; echo "     got:  $3"; fi; }

# ---- the box: seat "self" (the caller; sorts AFTER "other", and jq keys[] sorts, so other is always tried first) and seat "other" ------------------------
export CONNECTORS_DIR="$TMP/connectors"; mkdir -p "$CONNECTORS_DIR"
printf 'TELEGRAM_BOT_TOKEN=111:mine\n'  >"$CONNECTORS_DIR/telegram-self.env"
printf 'TELEGRAM_BOT_TOKEN=222:other\n' >"$CONNECTORS_DIR/telegram-other.env"
[[ $EUID -ne 0 ]] && chmod 000 "$CONNECTORS_DIR/telegram-other.env"
export TELEGRAM_BOT_TOKEN="111:mine"           # what the seat's unit hands it
# Both seats' access.json are made READABLE here on purpose: the live box hides
# other's behind a 0700 dir, but the arm must show the token rule holds on its
# own, not because a second permission happened to cover for it.
for n in self other; do mkdir -p "$TMP/home/$n/telegram"; echo '{}' >"$TMP/home/$n/telegram/access.json"; done
_tg_access_state_dir() { local u="${1#agent-}"; [[ "$2" == claude ]] || return 1; printf '%s/home/%s/telegram' "$TMP" "$u"; }
UNREADABLE=" other "
_tg_token_unreadable_model() { local b="${1##*/telegram-}"; b="${b%.env}"; [[ "$UNREADABLE" == *" $b "* && -e "$1" ]]; }
export REGISTRY="$TMP/registry.json"

load() { # <src dir> — eval the readers under test from that tree
  local s="$1" fn
  for fn in _task_agent_channel _task_gate_bot_token _task_agent_paired; do
    eval "$(awk "/^${fn}\\(\\) \\{/,/^}\$/" "$s/task/notify.sh")"
  done
  eval "$(awk '/^_disk_alarm_deliver\(\) \{/,/^}$/' "$s/cmd_disk.sh")"
  eval "$(awk '/^cmd_disk_alarm\(\) \{/,/^}$/' "$s/cmd_disk.sh")"
  eval "$(awk '/^_hb_stuck_login_deliver\(\) \{/,/^}$/' "$s/cmd_heartbeat.sh")"
  eval "$(awk '/^_human_bot_reach\(\) \{/,/^}$/' "$s/cmd_human.sh")"
  eval "$(awk '/^tg_token_need_root\(\) \{/,/^}$/' "$s/lib/validation.sh")"
  _tg_token_unreadable() { _tg_token_unreadable_model "$@"; }
}
SENT="$TMP/sent"
_task_send_owner() { printf '%s|%s\n' "$TASK_CH_AGENT" "$TASK_CH_TOKEN" >>"$SENT"; TASK_SEND_DELIVERED=1; }

# ---------------------------------------------------------------- arms --------
run_arms() { # <label prefix> -> prints one verdict line per arm (used by M too)
  local p="$1" out
  # C
  _task_agent_channel other; local rc=$?
  eq "${p}C1 other's channel: not resolved (rc 1)" 1 "$rc"
  eq "${p}C2 ...and marked BLIND, not unpaired" 1 "${TASK_CH_BLIND:-0}"
  eq "${p}C3 ...and NO token picked up (never my env token on other's chat)" "" "${TASK_CH_TOKEN:-}"
  _task_agent_channel self
  eq "${p}C4 control: my own channel resolves with my own token" "111:mine" "${TASK_CH_TOKEN:-}"
  # G
  eq "${p}G1 gate card on other's bot: empty token -> handed to root" "" "$(_task_gate_bot_token other)"
  eq "${p}G2 control: my own card edits with my token" "111:mine" "$(_task_gate_bot_token self)"
  # P
  _task_agent_paired other; eq "${p}P1 other paired? undetermined (2), never 'unpaired'" 2 "$?"
  # D
  : >"$SENT"; printf '%s\n' '{"agents":{"another":{},"other":{},"self":{}}}' >"$REGISTRY"
  _disk_alarm_deliver "low disk"; rc=$?
  eq "${p}D1 disk alarm, other tried first: delivered" 0 "$rc"
  eq "${p}D2 ...through MY bot, and only mine" "self|111:mine" "$(cat "$SENT")"
  : >"$SENT"; printf '%s\n' '{"agents":{"other":{}}}' >"$REGISTRY"
  _disk_alarm_deliver "low disk"; rc=$?
  eq "${p}D3 only other's bot on the box: not sent from this seat" "1|" "$rc|$(cat "$SENT")"
  eq "${p}D4 ...and counted as blind (so it is handed to root, not 'no chat')" 1 "${_DISK_ALARM_BLIND:-0}"
  out=$( _disk_free_pct() { echo 2; }; _disk_state_get() { :; }; _disk_state_set() { :; }
         _disk_log() { echo "$*"; }; DISK_ALARM_PATH=/ DISK_REARM_PCT=10 DISK_ALARM_PCT=5; cmd_disk_alarm )
  eq "${p}D5 ...and the log says the root tick has it" yes \
     "$(grep -q 'UNDELIVERED.*readable only by root; handed to the root tick' <<<"$out" && echo yes || echo no)"
  # S
  : >"$SENT"; printf '%s\n' '{"agents":{"other":{},"self":{}}}' >"$REGISTRY"
  _hb_stuck_login_deliver "login stuck" "nobody"; rc=$?
  eq "${p}S1 stuck-login notice: delivered" 0 "$rc"
  eq "${p}S2 ...through MY bot, never my token on other's chat" "self|111:mine" "$(cat "$SENT")"
  # H
  local calls="$TMP/curl"; : >"$calls"
  out=$( curl() { echo x >>"$calls"; echo '{"ok":true}'; }; _human_bot_reach other 42 )
  eq "${p}H1 human probe via other's bot: says only root can read it" yes \
     "$(grep -q "^unknown: only root can read other's bot token" <<<"$out" && echo yes || echo no)"
  eq "${p}H2 ...and makes no Bot API call (and never says 'no bot')" "0|no" \
     "$(wc -l <"$calls" | tr -d ' ')|$([[ "$out" == "no bot" ]] && echo yes || echo no)"
  # R
  local roots="$TMP/roots"; : >"$roots"
  ( require_root() { echo "$*" >>"$roots"; }
    tg_token_need_root "$CONNECTORS_DIR/telegram-other.env" agent telegram-info other
    tg_token_need_root "$CONNECTORS_DIR/telegram-self.env"    agent telegram-info self
    tg_token_need_root "$CONNECTORS_DIR/telegram-ghost.env" agent telegram-info ghost )
  eq "${p}R1 need-root: other's file -> require_root; mine and an absent one -> no" "agent telegram-info other" "$(cat "$roots")"
}

echo "== the fixed tree"
load src
run_arms ""

echo "== R2: every verb that reads a NAMED seat's token asks tg_token_need_root first"
for spec in "src/cmd_agent_telegram.sh:cmd_telegram_info" "src/cmd_agent_telegram.sh:cmd_telegram_discover" "src/cmd_cos.sh:cmd_agent_cos"; do
  f="${spec%%:*}" fn="${spec#*:}"
  body=$(awk "/^${fn}\\(\\) \\{/,/^}\$/" "$f")
  # Each `telegram-${...}.env` assignment must be followed by the guard before
  # the first read of it (sed/grep of the file, or the -r test).
  n_files=$(grep -c 'telegram-\${[a-z_]*}\.env' <<<"$body")
  n_guard=$(grep -c 'tg_token_need_root ' <<<"$body")
  eq "R2 $fn: one guard per token file it names ($n_files)" "$n_files" "$n_guard"
done

echo "== T: the readers that stay root-run are root BEFORE their first read"
first_line() { grep -n -m1 -E "$2" <<<"$1" | cut -d: -f1; }
tb=$(awk '/^cmd_agent_team_bot\(\) \{/,/^}$/' src/cmd_agent_teambot.sh)
eq "T1 team-bot: ensure_state (root) precedes the first token-file read" yes \
   "$( (( $(first_line "$tb" '^  ensure_state$') < $(first_line "$tb" 'telegram-\$\{') )) && echo yes || echo no)"
dg=$(awk '/^_digest_tick\(\) \{/,/^}$/' src/cmd_digest.sh)
eq "T2 digest tick: require_root precedes the first token-file test" yes \
   "$( (( $(first_line "$dg" 'require_root "digest tick"') < $(first_line "$dg" 'telegram-\$\{') )) && echo yes || echo no)"
hb=$(awk '/^cmd_heartbeat_tick\(\) \{/,/^}$/' src/cmd_heartbeat.sh)
eq "T3 heartbeat tick (stuck-login's one caller) requires root, before the sweep" yes \
   "$( (( $(first_line "$hb" 'require_root "heartbeat tick"') < $(first_line "$hb" '_hb_stuck_login_sweep ') )) && echo yes || echo no)"
eq "T4 selection loops select by -e, never -r, on telegram-<x>.env" 0 \
   "$(grep -cE '\-r "\$\{CONNECTORS_DIR\}/telegram-\$\{name\}\.env"' src/cmd_disk.sh src/cmd_heartbeat.sh src/cmd_digest.sh | awk -F: '{s+=$2} END{print s+0}')"

echo "== M: revert one hand-off at a time -> that arm goes red"
mutant() { # <file under src> <sed expr> <arm id to watch>
  local rel="$1" expr="$2" arm="$3" d="$TMP/mut"
  rm -rf "$d"; cp -r src "$d"
  sed -i -E "$expr" "$d/$rel"
  if cmp -s "src/$rel" "$d/$rel"; then eq "M $arm: the mutation applied" applied "no-op"; return; fi
  local res; res=$( load "$d"; PASS=0 FAIL=0; run_arms "" 2>&1 | grep -E "^(ok|FAIL) +${arm} " )
  eq "M $arm red after: $expr" FAIL "$(awk '{print $1}' <<<"$res" | head -1)"
}
mutant task/notify.sh 's/^  if _tg_token_unreadable "\$token_file"; then TASK_CH_BLIND=1; return 1; fi$//' C3
mutant task/notify.sh 's/^  if _tg_token_unreadable "\$token_file"; then TASK_CH_BLIND=1; return 1; fi$//' S2
mutant task/notify.sh 's/^    _tg_token_unreadable "\$f" && return 0$//' G1
mutant cmd_disk.sh 's/^      \[\[ "\$\{TASK_CH_BLIND:-0\}" == 1 \]\] && _DISK_ALARM_BLIND=.*$/      :/' D4
mutant cmd_human.sh 's/^  if _tg_token_unreadable "\$f"; then printf .*$//' H1

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
