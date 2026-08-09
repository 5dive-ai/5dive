#!/usr/bin/env bash
# DIVE-3017 — drive `5dive acp` end to end over stdio: the REAL verb, the REAL
# embedded ACP server, a stubbed `5dive` underneath it.
#
# WHY AT THIS SEAM. The value of the verb is entirely in what a client reads off
# the pipe — a negotiated protocol version, a roster delivered as
# availableCommands, a prompt that refuses to open a blank session, a turn that
# actually reaches `agent ask`. None of that is visible to a helper-level test,
# and the client that consumes it (Buzz) is a Tauri desktop app we cannot run
# here. So: stub the CLI, speak JSON-RPC at the verb, assert the frames.
#
# The stub also pins the thing an integration test could not: exactly WHICH
# argv reaches `5dive agent ask`, and that an UNATTACHED prompt reaches it not
# at all.
set -euo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# shellcheck disable=SC1091
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
source src/lib/audit.sh 2>/dev/null || true
# shellcheck disable=SC1091
source src/cmd_acp.sh

WORK=$(mktemp -d)
FAILED=0
CHECKS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   - %s\n' "$1"; }
bad()  { CHECKS=$((CHECKS+1)); FAILED=$((FAILED+1)); printf 'FAIL - %s\n' "$1"; }
want() { if [[ "$1" == "true" ]]; then ok "$2"; else bad "$2"; fi; }

# --- the stub CLI the server talks to -------------------------------------------
# Reserved fakes only: no real agent, box or account appears here.
cat > "$WORK/stub-5dive" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "agent" && "${2:-}" == "list" ]]; then
  printf '%s\n' '{"ok":true,"data":[{"name":"alpha","type":"claude","model":"opus"},{"name":"beta","type":"codex","model":"gpt-5"}]}'
  exit 0
fi
if [[ "${1:-}" == "agent" && "${2:-}" == "ask" ]]; then
  printf '%s\n' "$*" >> "$ASK_LOG"
  if [[ -n "${ASK_SLOW:-}" ]]; then exec sleep 20; fi
  printf 'REPLY from %s: %s\n' "$3" "$4"
  exit 0
fi
printf 'stub: unexpected argv: %s\n' "$*" >&2
exit 9
STUB
chmod +x "$WORK/stub-5dive"

export ACP_CLI_BIN="$WORK/stub-5dive"
export ACP_RUN_DIR="$WORK/run"
export ACP_ASK_TIMEOUT=5
export ASK_LOG="$WORK/ask.log"
: > "$ASK_LOG"

# --- 1. the bun preflight, which needs no bun ----------------------------------
# presets.rs renders NotInstalled only when the COMMAND is absent, so `5dive`
# present + bun missing is a client spawning us into a dead pipe. That path must
# say why and exit E_NOT_INSTALLED, not die with a stack trace.
rc=0
out=$(ACP_BUN_BIN="$WORK/no-such-bun" cmd_acp 2>&1 >/dev/null) || rc=$?
want "$([[ $rc -eq 7 ]] && echo true)" "bun missing exits E_NOT_INSTALLED (7), got $rc"
want "$(grep -qi 'bun' <<<"$out" && echo true)" "bun-missing message names bun: ${out:0:90}"
rc=0
out=$(cmd_acp --nonsense 2>&1 >/dev/null) || rc=$?
want "$([[ $rc -eq 2 ]] && echo true)" "an argument is a usage error (2), got $rc"

BUN=$(ACP_BUN_BIN="" _acp_resolve_bun)
if [[ ! -x "$BUN" ]]; then
  # Honest skip, and scoped: the two stdio scenarios below ARE the bun server, so
  # a box without bun cannot grade them. The preflight checks above already ran.
  printf 'SKIP - stdio scenarios: no bun on this box (%s); preflight checks ran\n' "$BUN"
  printf 'PASS - %d checks, %d failed (stdio scenarios skipped)\n' "$CHECKS" "$FAILED"
  [[ $FAILED -eq 0 ]] || exit 1
  exit 0
fi

# --- 2. handshake, roster, refuse-to-open-blank, attach, turn, fall-through -----
req() { printf '%s\n' "$1"; }
# Runs the REAL verb (so the staging, the preflight and the exec are all in the
# graded path), re-sourced under `timeout` because a function cannot be wrapped.
VERB='source src/header.sh; source src/lib/error_codes.sh; source src/lib/output.sh; source src/cmd_acp.sh; cmd_acp'
{
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"clientCapabilities":{}}}'
  req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}'
  req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"do the thing"}]}}'
  req '{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"/alpha"}]}}'
  req '{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"now do the thing"}]}}'
  req '{"jsonrpc":"2.0","id":6,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"/nope still send me"}]}}'
  req '{"jsonrpc":"2.0","id":7,"method":"nonsense/method","params":{}}'
} | timeout 60 bash -c "$VERB" 2>"$WORK/err.log" >"$WORK/out.jsonl" || true

j() { jq -r "$1" "$WORK/out.jsonl" 2>/dev/null | grep -v '^null$' | head -1; }

want "$([[ "$(j 'select(.id==1)|.result.protocolVersion')" == "1" ]] && echo true)" \
  "initialize negotiates DOWN from the client's 2 to the 1 we speak"
want "$([[ "$(j 'select(.id==1)|.result.agentCapabilities.loadSession')" == "false" ]] && echo true)" \
  "initialize declares loadSession:false (we do not resume client-held ids)"
want "$([[ "$(j 'select(.id==2)|.result.sessionId')" == "5dive-1" ]] && echo true)" \
  "session/new returns a sessionId"

cmds=$(jq -r 'select(.method=="session/update")|.params.update|select(.sessionUpdate=="available_commands_update")|.availableCommands[].name' "$WORK/out.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')
for n in attach agents alpha beta; do
  want "$(grep -qw "$n" <<<"$cmds" && echo true)" "availableCommands carries /$n (got: $cmds)"
done

chunks=$(jq -r 'select(.method=="session/update")|.params.update|select(.sessionUpdate=="agent_message_chunk")|.content.text' "$WORK/out.jsonl" 2>/dev/null | tr '\n' ' ')
want "$(grep -q 'Not attached yet' <<<"$chunks" && echo true)" \
  "an UNATTACHED prompt returns the roster instead of opening a blank session"
want "$(grep -q 'REPLY from alpha: now do the thing' <<<"$chunks" && echo true)" \
  "an attached prompt streams the agent's reply back as a text chunk"
want "$(jq -e 'select(.id==5)|.result.stopReason=="end_turn"' "$WORK/out.jsonl" >/dev/null 2>&1 && echo true)" \
  "a completed turn answers stopReason end_turn"
want "$(jq -e 'select(.id==7)|.error.code==-32601' "$WORK/out.jsonl" >/dev/null 2>&1 && echo true)" \
  "an unknown method is a -32601, not a crash"
reattach=$(jq -r 'select(.method=="session/update")|.params.update|select(.sessionUpdate=="available_commands_update")|.availableCommands[]|select(.name=="attach")|.description' "$WORK/out.jsonl" 2>/dev/null | tr '\n' '|')
want "$(grep -q 'currently: alpha' <<<"$reattach" && echo true)" \
  "availableCommands is REFRESHED after the attach (attach description names alpha)"

# The stub log is the load-bearing assertion: exactly the turns that should have
# reached the agent did, with the argv they should have carried.
asks=$(wc -l <"$ASK_LOG" | tr -d ' ')
want "$([[ "$asks" == "2" ]] && echo true)" \
  "agent ask ran exactly twice — the unattached prompt did NOT reach an agent (got $asks)"
want "$(grep -q 'agent ask alpha now do the thing --timeout=5' "$ASK_LOG" && echo true)" \
  "the turn reaches: agent ask alpha <prompt> --timeout=<n>"
want "$(grep -q 'agent ask alpha /nope still send me' "$ASK_LOG" && echo true)" \
  "an unknown slash command falls THROUGH to the attached agent rather than being eaten"

# --- 3. cancel while a prompt is open ------------------------------------------
# The read loop dispatches without awaiting precisely so this works: the cancel
# arrives as the next line while the prompt it cancels is still running.
: > "$ASK_LOG"
{
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}'
  req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}'
  req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"/alpha"}]}}'
  req '{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"take your time"}]}}'
  sleep 2
  req '{"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{"sessionId":"5dive-1"}}'
  sleep 2
} | ( ASK_SLOW=1 timeout 60 "$BUN" "$ACP_RUN_DIR/acp-server.ts" ) 2>>"$WORK/err.log" >"$WORK/cancel.jsonl" || true

want "$(jq -e 'select(.id==4)|.result.stopReason=="cancelled"' "$WORK/cancel.jsonl" >/dev/null 2>&1 && echo true)" \
  "session/cancel lands WHILE the prompt is open and the turn answers stopReason cancelled"

# stdout is the wire: a stray diagnostic on it is a parse error in the client.
badlines=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  jq -e . >/dev/null 2>&1 <<<"$line" || badlines=$((badlines+1))
done < "$WORK/out.jsonl"
want "$([[ $badlines -eq 0 ]] && echo true)" "every stdout line is one parseable JSON frame ($badlines bad)"

printf '%s\n' "--- server stderr (diagnostics belong here):"
head -5 "$WORK/err.log" || true
if [[ $FAILED -ne 0 ]]; then printf 'FAILED %d of %d checks\n' "$FAILED" "$CHECKS"; exit 1; fi
printf 'PASS - %d checks\n' "$CHECKS"
