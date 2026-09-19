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

SETUP="$SRC/lib/agent_setup.sh"
has "$SETUP" 'TELEGRAM_BOT_TOKEN=%s' 'Claude install writes the channel token'
has "$SETUP" 'mcp-needs-auth-cache.json' 'Claude install clears stale MCP auth refusal cache'
has "$SETUP" 'chmod 600 "$TMP"' 'Claude channel token is written mode 600'

printf '\n%d passed, %d failed\n' "$P" "$F"
[[ $F == 0 ]]
