#!/usr/bin/env bash
# DIVE-4413 — `telegram.home-channel` MUST NOT BE ACCEPTED AND DROPPED.
#
# The customer measured all 19 paired seats at telegramHomeChannel: null and an
# operator who sets the key seeing nothing change. Two mechanisms, both here:
#
#   1. cmd_agent_config validated the key for every TYPE_CHANNELS type, but
#      install_channel_for_agent hands home_channel to the hermes and openclaw
#      installers ONLY — every other type took the value and discarded it.
#   2. A BARE `telegram.home-channel=` set (no token, no channels= change) did
#      not satisfy the dispatch condition at all, so it never even reached the
#      installer. It validated, landed in applied_keys, reported success, and
#      wrote nothing anywhere.
#
# Accept-and-drop is the worst of the three possible behaviours: an operator who
# sets it believes the destination is bound and stops looking. The contract this
# harness pins is that every input now ends in exactly one of two places — a
# WRITE, or a REFUSAL that names the lever.
#
# THE RED ARM IS B1: on origin/main the access.json is untouched by the set.
#
# `sudo` is replaced by a runas-stripping shim rather than the seeder being
# stubbed out: the python that computes the merge IS the thing under test, and a
# harness that stubbed it would grade nothing (the seam-stub trap —
# a stub hides the path it stubs). Only the privilege drop is removed.
#
# Run: bash tests/agent_config_home_channel_unit.sh (no root, no network).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
TMP=$(mktemp -d /tmp/home-channel.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/registry.sh lib/audit.sh \
         lib/tasks_db.sh lib/actor.sh cmd_agent_runtime.sh cmd_agent_config.sh \
         cmd_agent_pairing.sh cmd_task.sh; do
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

STATE_DIR="$TMP/state"; CONNECTORS_DIR="$TMP/connectors"
mkdir -p "$STATE_DIR" "$CONNECTORS_DIR"
CH="$TMP/home/agent-swan/.claude/channels/telegram"; mkdir -p "$CH"
ACCESS="$CH/access.json"; PTR="$CH/last-human-chat.json"
printf '%s\n' 'TELEGRAM_BOT_TOKEN=1:aaaaaaaaaaaaaaaaaaaaaaaa' >"$CONNECTORS_DIR/telegram-swan.env"
printf '%s\n' 'TELEGRAM_BOT_TOKEN=2:bbbbbbbbbbbbbbbbbbbbbbbb' >"$CONNECTORS_DIR/telegram-herm.env"

# The state dir the seeder writes into — redirected under TMP so no real seat is
# touched. Type dispatch itself is exercised by the hermes refusal arm below.
_tg_access_state_dir() {
  case "$2" in
    claude|codex|grok|pi) printf '%s/home/%s/.%s/channels/telegram' "$TMP" "$1" "$2" ;;
    antigravity)          printf '%s/home/%s/.gemini/channels/telegram' "$TMP" "$1" ;;
    *) return 1 ;;
  esac
}
# Strip only the privilege drop: `sudo -u <user> env A=1 ... python3 -` becomes
# `env A=1 ... python3 -`, same argv, same stdin, same script.
sudo() { while [[ "${1:-}" == -* || "${1:-}" == "$(id -un)" ]]; do [[ "$1" == "-u" ]] && shift; shift; done; "$@"; }
step() { :; }
ensure_state() { :; }
audit_log() { :; }
write_agent_env() { :; }
registry_read() { printf '%s' "$REG"; }
registry_write() { REG=$(cat); }
# Recorded to a FILE, not a variable: run_cfg drives cmd_config in a subshell
# (it calls `fail`, which exits) and a global set in there dies with it.
install_channel_for_agent() { printf '%s' "${5:-}" >"$TMP/install_home"; }
ensure_hermes_gateway() { :; }
# The deferred restart and the hermes gateway are the two side effects this
# command has on the BOX. Neutered by name — the sudo shim above removes only a
# privilege drop, so anything cmd_config genuinely shells out to would otherwise
# run for real against this machine's systemd.
systemd-run() { :; }
systemctl() { :; }

REG='{"agents":{"swan":{"type":"claude","channels":"telegram","botUsername":"b"},"herm":{"type":"hermes","channels":"telegram","botUsername":"h"}}}'
TYPE_CHANNELS=([claude]=1 [codex]=1 [grok]=1 [hermes]=1 [openclaw]=1)

run_cfg() { : >"$TMP/install_home"; ( cmd_config "$@" ) >"$TMP/out" 2>"$TMP/err"; echo $?; }

# ---------------------------------------------------------------- B1: the write
rc=$(run_cfg swan set telegram.home-channel=-1003797470983:200)
if [[ "$rc" != "0" ]]; then
  bad_t "B1 a bare home-channel set on a claude seat must succeed" "rc=$rc err=$(<"$TMP/err")"
else
  got=$(jq -r '.groups["-1003797470983"].message_thread_id // "ABSENT"' "$ACCESS" 2>/dev/null)
  [[ "$got" == "200" ]] \
    && ok_t "B1 a claude seat's home-channel binds groups.<chat>.message_thread_id (RED on main: nothing written)" \
    || bad_t "B1 access.json was not written" "message_thread_id=$got file=$(cat "$ACCESS" 2>&1)"
fi
pc=$(jq -r '.chatId // "ABSENT"' "$PTR" 2>/dev/null); pt=$(jq -r '.messageThreadId // "ABSENT"' "$PTR" 2>/dev/null)
[[ "$pc" == "-1003797470983" && "$pt" == "200" ]] \
  && ok_t "B2 last-human-chat.json is seeded too, so the pointer branch agrees with the binding" \
  || bad_t "B2 pointer not seeded" "chatId=$pc thread=$pt"

# ------------------------------------------- B3: the binding is the REAL lever
# Not a second opinion about which key matters: hand the file the command just
# wrote to the send path and watch where the gate goes.
TASKS_DIR="$TMP/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"; mkdir -p "$TASKS_DIR"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"; export FIVEDIVE_GATE_NOTIFY_LOG="$TMP/notify.log"
tasks_db_init; _tasks_db_migrate
SEND_LOG="$TMP/sends"; : >"$SEND_LOG"
_mirror_send() { printf '%s|%s\n' "$2" "$3" >>"$SEND_LOG"; printf '%s' '{"ok":true,"result":{"message_id":1}}'; }
_mirror_log_button_reject() { :; }; _mirror_follow_migration() { :; }
TASK_CH_TOKEN=x TASK_CH_ACCESS="$ACCESS" TASK_CH_TYPE=claude
_task_send_owner "needs you" "" "" >/dev/null 2>&1
grep -q '^-1003797470983|200$' "$SEND_LOG" \
  && ok_t "B3 a gate sent after the set lands in the bound TOPIC, not in General" \
  || bad_t "B3 the binding did not change where a gate goes" "sends=$(tr '\n' ',' <"$SEND_LOG")"

# ------------------------------------------------ B4: operator keys survive it
jq '.groups["-1003797470983"].requireMention = true | .groups["-1003797470983"].allowFrom = ["777"]' "$ACCESS" >"$TMP/a" && mv "$TMP/a" "$ACCESS"
run_cfg swan set telegram.home-channel=-1003797470983:41 >/dev/null
rm2=$(jq -r '.groups["-1003797470983"].requireMention' "$ACCESS" 2>/dev/null)
af=$(jq -r '.groups["-1003797470983"].allowFrom[0] // "ABSENT"' "$ACCESS" 2>/dev/null)
th=$(jq -r '.groups["-1003797470983"].message_thread_id' "$ACCESS" 2>/dev/null)
[[ "$rm2" == "true" && "$af" == "777" && "$th" == "41" ]] \
  && ok_t "B4 re-binding updates the topic and preserves the operator's own group keys" \
  || bad_t "B4 clobbered operator state" "requireMention=$rm2 allowFrom=$af thread=$th"

# --------------------------------------------------- B5: a bare chat, no topic
run_cfg swan set telegram.home-channel=-1009 >/dev/null
nt=$(jq -r '.groups["-1009"] | has("message_thread_id")' "$ACCESS" 2>/dev/null)
nv=$(jq -r '.groups["-1009"].message_thread_id' "$ACCESS" 2>/dev/null)
[[ "$nt" == "true" && "$nv" == "null" ]] \
  && ok_t "B5 a bare chat id binds the group with an explicit null topic" \
  || bad_t "B5 bare chat not bound" "has=$nt value=$nv"

# ---------------------------------------------------------- B6/B7: refusals
rc=$(run_cfg swan set telegram.home-channel=-1009:abc)
[[ "$rc" != "0" ]] && grep -qi 'topic' "$TMP/err" \
  && ok_t "B6 a non-numeric topic is refused, naming the topic as the problem" \
  || bad_t "B6 bad topic accepted" "rc=$rc err=$(<"$TMP/err")"

rc=$(run_cfg herm set telegram.home-channel=-1009:200)
[[ "$rc" != "0" ]] && grep -q 'bare chat id' "$TMP/err" \
  && ok_t "B7 <chat>:<topic> on a gateway type is REFUSED with the reason, never accepted and dropped" \
  || bad_t "B7 hermes silently took a topic it cannot use" "rc=$rc err=$(<"$TMP/err")"

# ------------------------------------- B8: hermes keeps its installer contract
rc=$(run_cfg herm set telegram.home-channel=-1009)
[[ "$rc" == "0" && "$(<"$TMP/install_home")" == "-1009" ]] \
  && ok_t "B8 a hermes seat still gets its home channel through the installer (no regression)" \
  || bad_t "B8 hermes path broken" "rc=$rc install_home='$(<"$TMP/install_home")' err=$(<"$TMP/err")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
