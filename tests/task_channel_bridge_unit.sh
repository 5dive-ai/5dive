#!/usr/bin/env bash
# DIVE-4609: standard-seat Telegram taps cross one exact-path primitive.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/task-channel.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
mkdir -p "$STATE_DIR" "$TASKS_DIR" "$TMP/bin"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh; do
  source "$SRC/$f"
done
source "$SRC/cmd_agent_create.sh"
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }
has(){ grep -Fq -- "$2" "$1" && ok "$3" || bad "$3"; }
not(){ grep -Fq -- "$2" "$1" && bad "$3" || ok "$3"; }

SUD=$(render_standard_sudoers agent-tap 0 0)
[[ $(grep -cE '^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive _task_channel$' <<<"$SUD") == 1 ]] \
  && ok 'exact-path channel grant is rendered once' || bad 'exact-path channel grant is rendered once'
[[ $(grep '_task_channel' <<<"$SUD") != *'*'* ]] && ok 'channel grant has no wildcard' || bad 'channel grant has no wildcard'

ANSWER="$SRC/task/answer.sh"
sed -n '/^cmd_task_channel_delegated()/,/^_task_channel_try()/p' "$ANSWER" >"$TMP/executor.src"
has "$TMP/executor.src" 'case "$op" in answer|clear-recs)' 'executor allows answer and clear-recs'
has "$TMP/executor.src" '_gate_channel_proof_ok "$channel_proof"' 'executor re-verifies paired-human proof'
has "$TMP/executor.src" 'actor=$(_gate_uid_to_agent "$ruid")' 'executor derives the calling seat from SUDO_UID'
not "$TMP/executor.src" 'case "$op" in answer|clear-recs|start' 'executor does not route start'

export CALLS="$TMP/calls" WIRE="$TMP/wire"
# Keep this seam in-process. The pre-push corpus deliberately sanitises inherited
# command environments; a PATH shim made this arm order-dependent even though the
# production call itself is a shell command.
sudo(){
  if [[ "$2" == "-l" ]]; then return 0; fi
  printf '%s\n' "$*" >>"$CALLS"
  python3 -c 'import sys; b=sys.stdin.buffer.read(); print(b.count(b"\0"))' >"$WIRE"
  printf '{"ok":true,"data":{"signed":true}}\n'
}
# The delegated pre-push rail runs harnesses as root. Model the production
# standard-seat caller through the existing root seam rather than inheriting
# the harness runner's uid.
_gate_is_root(){ return 1; }
: >"$CALLS"
out=$(_task_channel_try answer DIVE-1 --value=yes --channel-proof=123 2>&1); rc=$?
[[ $rc == 0 && "$out" == *'"signed":true'* ]] && ok 'channel-proof call delegates successfully' || bad 'channel-proof call delegates successfully'
has "$CALLS" '/usr/local/bin/5dive _task_channel' 'delegation invokes only the hidden primitive'
[[ $(cat "$WIRE") == 4 ]] && ok 'operation and three arguments travel over NUL stdin' || bad 'operation and arguments travel over NUL stdin'
: >"$CALLS"; _task_channel_try answer DIVE-1 --value=yes >/dev/null 2>&1
[[ ! -s "$CALLS" ]] && ok 'no channel proof means no privileged call' || bad 'no channel proof means no privileged call'

# DIVE-4609 iteration 2 (quinn reject): a seat that does NOT hold the grant must
# fall THROUGH to today's unprivileged write, not fail. Every installed seat is
# in that state until its sudoers is re-rendered, so the first version of this
# bridge took a working path away from every one of them. `fail` exits the
# process, so on the pre-fix tree this arm does not print FAIL -- it kills the
# harness mid-run, which is itself the regression signal.
sudo(){
  if [[ "$2" == "-l" ]]; then return 1; fi          # grant absent
  printf '%s\n' "$*" >>"$CALLS"; cat >/dev/null
  printf '{"ok":true,"data":{"signed":true}}\n'
}
: >"$CALLS"; _TASK_CHANNEL_ATTEMPTED=unset
_task_channel_try answer DIVE-1 --value=yes --channel-proof=123 >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ok 'ungranted seat: bridge declines instead of taking the write' \
  || bad 'ungranted seat: bridge declines instead of taking the write'
[[ "${_TASK_CHANNEL_ATTEMPTED}" == 0 ]] && ok 'ungranted seat: ATTEMPTED=0 so the caller falls through' \
  || bad "ungranted seat: ATTEMPTED=0 so the caller falls through (got '${_TASK_CHANNEL_ATTEMPTED}')"
[[ ! -s "$CALLS" ]] && ok 'ungranted seat: no privileged call is made' || bad 'ungranted seat: no privileged call is made'

# ...and the converse, which is the refusal this bridge exists to make: the grant
# IS present, so the proof reached root and ROOT refused it. Falling through here
# would land the write unsigned behind a human proof the primitive rejected, so
# ATTEMPTED stays 1 and the caller returns the refusal.
sudo(){
  if [[ "$2" == "-l" ]]; then return 0; fi          # grant present
  printf '%s\n' "$*" >>"$CALLS"; cat >/dev/null
  printf 'refused\n'; return 4
}
: >"$CALLS"; _TASK_CHANNEL_ATTEMPTED=unset
_task_channel_try answer DIVE-1 --value=yes --channel-proof=123 >/dev/null 2>&1; rc=$?
[[ $rc == 4 ]] && ok 'granted seat: a root refusal propagates as the caller rc' \
  || bad "granted seat: a root refusal propagates as the caller rc (got $rc)"
[[ "${_TASK_CHANNEL_ATTEMPTED}" == 1 ]] && ok 'granted seat: ATTEMPTED=1 so there is no unsigned fall-through' \
  || bad "granted seat: ATTEMPTED=1 so there is no unsigned fall-through (got '${_TASK_CHANNEL_ATTEMPTED}')"

SETUP="$SRC/lib/agent_setup.sh"
has "$SETUP" 'TELEGRAM_BOT_TOKEN=%s' 'Claude install writes the channel token'
has "$SETUP" 'mcp-needs-auth-cache.json' 'Claude install clears stale MCP auth refusal cache'
has "$SETUP" 'chmod 600 "$TMP"' 'Claude channel token is written mode 600'

printf '\n%d passed, %d failed\n' "$P" "$F"
[[ $F == 0 ]]
