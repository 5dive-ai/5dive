#!/usr/bin/env bash
# DIVE-1352: coverage for _init_run, the verbose/quiet sub-step wrapper the
# init wizard drives install / agent-create / pairing through. No root,
# network, install, or agent state is touched — _init_run just wraps arbitrary
# commands, so we wrap `cat`/`bash -c exit N` and assert the contract:
#   - verbose streams the sub-process to fd2 (the wizard's terminal channel)
#   - quiet captures it to the per-run log and shows only spinner + ✓/✗
#   - stdin (the piped secret for `agent create --api-key=-`) reaches the cmd
#     in BOTH modes (quiet backgrounds the cmd; the pipe must still flow)
#   - the sub-process rc propagates, and quiet surfaces the log path on failure
set -euo pipefail
cd "$(dirname "$0")/.."
export NO_COLOR=1
# shellcheck disable=SC1091
# shellcheck source=../src/cmd_init.sh
source src/cmd_init.sh

fails=0
ck() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1 (got=[$2] want=[$3])"; fails=$((fails+1)); fi; }
ckhas() { case "$2" in *"$3"*) echo "ok   - $1";; *) echo "FAIL - $1 (missing [$3] in [$2])"; fails=$((fails+1));; esac; }

# 1. verbose: sub-process output streams to fd2, stdin flows through, rc=0
rc=0; err=$( _INIT_QUIET=0; printf 'SEKRET' | { _init_run "make widget" cat; } 2>&1 1>/dev/null ) || rc=$?
ck    "verbose success rc=0" "$rc" "0"
ckhas "verbose passes stdin through to the cmd" "$err" "SEKRET"

# 2. verbose: non-zero rc propagates to the caller
rc=0; ( _INIT_QUIET=0; _init_run "boom" bash -c 'exit 7' ) >/dev/null 2>&1 || rc=$?
ck "verbose propagates sub-process rc" "$rc" "7"

# 3. quiet: stdout captured to log (not leaked), stdin flows to backgrounded cmd
log=$(mktemp); : > "$log"
rc=0; out=$( _INIT_QUIET=1; _INIT_LOG="$log"; printf 'SEKRET2' | { _init_run "make gadget" cat; } 2>/dev/null ) || rc=$?
ck    "quiet success rc=0" "$rc" "0"
ck    "quiet does not leak sub-process stdout to the caller" "$out" ""
ck    "quiet captures output to the log AND stdin reached the cmd" "$(cat "$log")" "SEKRET2"

# 4. quiet: rc propagates, failure message surfaces the log path, output logged
log=$(mktemp); : > "$log"
if err=$( { _INIT_QUIET=1; _INIT_LOG="$log"; _init_run "explode" bash -c 'echo trace-line; exit 4'; } 2>&1 1>/dev/null ); then rc=0; else rc=$?; fi
ck    "quiet propagates sub-process rc" "$rc" "4"
ckhas "quiet failure surfaces the log path" "$err" "$log"
ckhas "quiet logs the failed cmd output" "$(cat "$log")" "trace-line"

# 5. the marketplace pre-register datetime is timezone-aware (no utcnow leak)
if grep -q 'datetime.datetime.now(datetime.timezone.utc)' src/lib/agent_setup.sh; then
  echo "ok   - agent_setup uses tz-aware now(), not deprecated utcnow()"
else
  echo "FAIL - agent_setup still uses datetime.utcnow()"; fails=$((fails+1))
fi

echo ""
if [[ $fails -eq 0 ]]; then echo "PASS: _init_run verbose/quiet + stdin + rc + log + datetime"; else echo "FAILED ($fails)"; exit 1; fi
