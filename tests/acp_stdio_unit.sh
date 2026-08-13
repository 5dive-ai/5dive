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

# --- 1b. WHERE the server stages (DIVE-3361) -----------------------------------
# The ACP registry's required verify-auth job spawns this verb as an unprivileged
# sandbox user, so a root-only staging default is not cosmetic: `cat >
# /opt/5dive/acp-server.ts` is Permission denied and the listing fails with no ACP
# frame on the wire at all. Graded here, ABOVE the bun gate, because a stub bin
# answers the preflight — so these arms still run on a box with no bun.
#
# THE UNWRITABLE DEFAULT IS A FILE'S CHILD, NOT A chmod. A `chmod 500` directory is
# writable by root, so on a container CI that runs this harness as root the arms
# below would grade the opposite branch; `$WORK/notadir` is a regular file, so
# `mkdir -p "$WORK/notadir/5dive"` is ENOTDIR for every uid there is.
printf 'not a directory\n' > "$WORK/notadir"
cat > "$WORK/fake-bun" <<'FAKE_BUN'
#!/usr/bin/env bash
exit 0
FAKE_BUN
chmod +x "$WORK/fake-bun"

# (a) default unreachable + a HOME: falls back to the XDG cache dir and RUNS.
rc=0
( export ACP_RUN_DIR_DEFAULT="$WORK/notadir/5dive" ACP_BUN_BIN="$WORK/fake-bun" HOME="$WORK/h1"
  unset ACP_RUN_DIR XDG_CACHE_HOME
  cmd_acp ) >/dev/null 2>"$WORK/stage-a.err" || rc=$?
want "$([[ $rc -eq 0 && -f "$WORK/h1/.cache/5dive/acp-server.ts" ]] && echo true)" \
  "an unwritable default stages under \$HOME/.cache/5dive instead (rc=$rc)"

# (b) XDG_CACHE_HOME wins over \$HOME/.cache when it is set — that variable is one
# of the few the registry client passes through to us, so it is the tier CI may hit.
rc=0
( export ACP_RUN_DIR_DEFAULT="$WORK/notadir/5dive" ACP_BUN_BIN="$WORK/fake-bun" HOME="$WORK/h2" XDG_CACHE_HOME="$WORK/xdg"
  unset ACP_RUN_DIR
  cmd_acp ) >/dev/null 2>"$WORK/stage-b.err" || rc=$?
want "$([[ $rc -eq 0 && -f "$WORK/xdg/5dive/acp-server.ts" && ! -e "$WORK/h2/.cache/5dive/acp-server.ts" ]] && echo true)" \
  "XDG_CACHE_HOME takes the fallback ahead of \$HOME/.cache (rc=$rc)"

# (c) A WRITABLE default is still used first: a managed box does not move.
rc=0
( export ACP_RUN_DIR_DEFAULT="$WORK/optlike" ACP_BUN_BIN="$WORK/fake-bun" HOME="$WORK/h3"
  unset ACP_RUN_DIR XDG_CACHE_HOME
  cmd_acp ) >/dev/null 2>"$WORK/stage-c.err" || rc=$?
want "$([[ $rc -eq 0 && -f "$WORK/optlike/acp-server.ts" && ! -e "$WORK/h3/.cache/5dive/acp-server.ts" ]] && echo true)" \
  "a writable default still wins — the VM's /opt/5dive layout is unchanged (rc=$rc)"

# (d) An EXPLICIT ACP_RUN_DIR is the only candidate. Falling back past a directory
# the caller named would stage, and then exec, somewhere they never asked for.
rc=0
out=$( ( export ACP_RUN_DIR="$WORK/notadir/mine" ACP_BUN_BIN="$WORK/fake-bun" HOME="$WORK/h4"
         unset XDG_CACHE_HOME
         cmd_acp ) 2>&1 >/dev/null ) || rc=$?
want "$([[ $rc -ne 0 && ! -e "$WORK/h4/.cache/5dive/acp-server.ts" ]] && echo true)" \
  "an explicit ACP_RUN_DIR does NOT silently fall back to \$HOME (rc=$rc)"
want "$(grep -q 'notadir/mine' <<<"$out" && ! grep -q 'h4' <<<"$out" && echo true)" \
  "that failure names the directory the caller chose, and only it: ${out:0:80}"

# (e) Nowhere to stage at all: fail naming the override, not a dead pipe.
rc=0
out=$( ( export ACP_RUN_DIR_DEFAULT="$WORK/notadir/5dive" ACP_BUN_BIN="$WORK/fake-bun"
         unset ACP_RUN_DIR XDG_CACHE_HOME HOME
         cmd_acp ) 2>&1 >/dev/null ) || rc=$?
want "$([[ $rc -ne 0 ]] && echo true)" "no writable candidate is a clean failure, not a crash (rc=$rc)"
want "$(grep -q 'ACP_RUN_DIR' <<<"$out" && echo true)" \
  "and it names ACP_RUN_DIR, the thing the reader can act on: ${out:0:80}"

BUN=$(ACP_BUN_BIN="" _acp_resolve_bun)
if [[ ! -x "$BUN" ]]; then
  # DIVE-3059: THIS DEFAULTS TO FAIL, and the reason is that the previous version
  # of this block was honest in the log and invisible in the verdict. It printed
  # `SKIP - stdio scenarios` and then `PASS - N checks` and exited 0, so a run
  # that graded 2 of 21 checks was byte-identical, at the layer CI reads, to one
  # that graded all 21. Confirmed to have actually happened: the core tier had no
  # bun, and PR 537's green said nothing whatsoever about the ACP server.
  #
  # The skip itself was correct behaviour — these two scenarios ARE the bun
  # server and a box without bun genuinely cannot grade them. What was wrong is
  # who got to decide. So the decision moves to the CALLER: a human on a bun-less
  # laptop passes ACP_ALLOW_SKIP=1 deliberately, and a CI runner that has lost its
  # bun step goes red instead of silently grading two checks.
  #
  # Keep this even once bun is installed on the runner. Installing bun fixes
  # today's coverage; this is what stops the silent-skip returning the day
  # somebody drops the step.
  # NO HARDCODED TOTAL HERE, deliberately. The first draft of this block said
  # "19 stdio checks", a figure that had been repeated in three agents' messages
  # and in the wiki write-up — and it was wrong: preflight is 3 and a full run is
  # 21, so the stdio scenarios are 18. A literal total in a summary line is also
  # wrong the moment somebody adds a check, and it is the kind of wrong that
  # nothing catches, because the line still LOOKS precise. So report what is
  # known for certain — how many ran, how many failed, and that the stdio
  # scenarios were not among them.
  if [[ -n "${ACP_ALLOW_SKIP:-}" ]]; then
    printf 'SKIP - stdio scenarios: no bun on this box (%s); ACP_ALLOW_SKIP set\n' "$BUN"
    # The count is in the summary line ON PURPOSE: a reader must be able to tell
    # this run from a full one WITHOUT opening the log.
    printf 'PARTIAL - %d preflight checks ran, %d failed; the stdio scenarios did NOT run\n' \
      "$CHECKS" "$FAILED"
    [[ $FAILED -eq 0 ]] || exit 1
    exit 0
  fi
  printf 'FAIL - stdio scenarios cannot run: no bun on this box (%s)\n' "$BUN"
  printf 'FAIL - only %d preflight checks ran; the ACP server itself was NOT graded.\n' "$CHECKS"
  printf 'FAIL - install bun, or set ACP_ALLOW_SKIP=1 to accept an ungraded ACP server.\n'
  exit 1
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

# --- authMethods: the ONE field the ACP registry gates the listing on (DIVE-3361)
# Their REQUIRED verify-auth job reads this and nothing else gets looked at first:
# .github/workflows/client.py :: validate_auth_methods refuses an empty array
# outright ("No authMethods in response"), then keeps only methods whose type is
# agent or terminal. Graded HERE because `authMethods: []` is not a smaller answer,
# it is the whole PR red on the first exchange — and the suite was fully green with
# the empty array, so nothing would have caught a revert of the fix.
#
# THE TYPE IS RESOLVED THE WAY THEY RESOLVE IT rather than read off a field of ours.
# Their priority: (1) a literal `type`, (2) `_meta` "terminal-auth"/"agent-auth",
# (3) default "agent". The spec's AuthMethod has no `type`, so we say it through
# `_meta`; porting their three steps here makes this arm grade the CONTRACT, so it
# still fails if the `_meta` key is dropped AND their step-3 default moves.
ACP_TYPE_JQ='.type // (._meta // {} | if has("terminal-auth") then "terminal" elif has("agent-auth") then "agent" else null end) // "agent"'
n_auth=$(jq -r 'select(.id==1)|.result.authMethods|length' "$WORK/out.jsonl" 2>/dev/null | head -1)
want "$([[ "${n_auth:-0}" -ge 1 ]] && echo true)" \
  "initialize answers >=1 authMethod — an empty array is their outright refusal (got ${n_auth:-none})"
auth_types=$(jq -r "select(.id==1)|.result.authMethods[]|$ACP_TYPE_JQ" "$WORK/out.jsonl" 2>/dev/null | tr '\n' ' ')
want "$(grep -qE '(^| )(agent|terminal)( |$)' <<<"$auth_types" && echo true)" \
  "and one resolves, under THEIR rules, to agent or terminal (got: ${auth_types:-none})"
want "$(jq -e 'select(.id==1)|.result.authMethods[0]|(.id//""|length>0) and (.name//""|length>0)' "$WORK/out.jsonl" >/dev/null 2>&1 && echo true)" \
  "the method carries a non-empty id and name — both are read straight into the listing"
# POSITIVE CONTROL, and it is not decoration: the two arms above are substring
# greps over a value derived from a file, so a malformed frame, an absent .id==1
# response or a mistyped jq path all present as the same green. Run the SAME
# expression over a frame that MUST fail it.
ctl=$(jq -rn "[{\"id\":\"x\",\"name\":\"x\",\"type\":\"password\"}]|.[]|$ACP_TYPE_JQ" 2>/dev/null | tr '\n' ' ')
want "$(! grep -qE '(^| )(agent|terminal)( |$)' <<<"$ctl" && [[ -n "${ctl// /}" ]] && echo true)" \
  "control: that same expression REFUSES a password-only method (got: ${ctl:-none}) — so the arms can fail"
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
#
# COUNTED FIRST, on purpose (olivia, grading e577edd): "no unparseable lines" is
# structurally pass-on-zero — an EMPTY stdout satisfies it — so on its own it would
# have read green in exactly the run where the server never spoke. The floor is
# asserted here rather than left to the sibling arms, so trimming them cannot
# quietly turn this into a tautology.
frames=$(grep -c . "$WORK/out.jsonl" 2>/dev/null || true)
frames=${frames:-0}
want "$([[ $frames -ge 8 ]] && echo true)" \
  "stdout carried frames at all ($frames lines; 7 responses + notifications) — the purity arm is pass-on-zero without this"
badlines=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  jq -e . >/dev/null 2>&1 <<<"$line" || badlines=$((badlines+1))
done < "$WORK/out.jsonl"
want "$([[ $badlines -eq 0 && $frames -ge 8 ]] && echo true)" \
  "every stdout line is one parseable JSON frame ($badlines bad of $frames)"

# --- 4. NO FLEET: the laptop that installs us from the ACP registry (DIVE-3370) --
# `5dive acp` enumerates the LOCAL fleet, so the machine most likely to run us
# first has none and gets an empty agent list. What is graded here is that the
# empty list SAYS WHICH of the four causes it is — the CLI absent, a box that
# hosts no fleet, a fleet it cannot read, a fleet with no agents — because those
# have four different next actions and they used to collapse into one silent [].
#
# Driven through ACP_CLI_BIN, i.e. the same seam the roster resolves through, so
# each arm is the REAL server reading a REAL `agent list` answer.
nofleet() {   # $1 = stub script body, $2 = out file
  cat > "$WORK/stub-nofleet" <<STUBX
#!/usr/bin/env bash
$1
STUBX
  chmod +x "$WORK/stub-nofleet"
  {
    req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}'
    req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}'
    req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"do the thing"}]}}'
  } | ( ACP_CLI_BIN="$WORK/stub-nofleet" timeout 60 "$BUN" "$ACP_RUN_DIR/acp-server.ts" ) \
      2>>"$WORK/err.log" >"$2" || true
}
chunks_of() { jq -r 'select(.method=="session/update")|.params.update|select(.sessionUpdate=="agent_message_chunk")|.content.text' "$1" 2>/dev/null | tr '\n' ' '; }
descs_of()  { jq -r 'select(.method=="session/update")|.params.update|select(.sessionUpdate=="available_commands_update")|.availableCommands[].description' "$1" 2>/dev/null | tr '\n' '|'; }

# (a) A BOX THAT HOSTS NO FLEET. The real shape, measured: our CLI answers a
# structured envelope on stdout and exits 10, so the reason is READ off
# .error.message rather than grepped out of stderr.
nofleet 'printf "%s\n" "{\"ok\":false,\"error\":{\"code\":10,\"class\":\"permission\",\"message\":\"must run as root — try: sudo 5dive agent list --json\"}}"
echo "error: must run as root" >&2
exit 10' "$WORK/nofleet.jsonl"
c=$(chunks_of "$WORK/nofleet.jsonl"); d=$(descs_of "$WORK/nofleet.jsonl")
want "$(grep -q 'LOCAL fleet' <<<"$c" && echo true)" \
  "no fleet: the reply names the LOCAL-only limit as the cause, not a failure: ${c:0:70}"
want "$(grep -q 'must run as root' <<<"$c" && echo true)" \
  "no fleet: and quotes the CLI's OWN message, read from the JSON envelope"
want "$(grep -qi '5dive init' <<<"$c" && echo true)" \
  "no fleet: and names a next action a laptop user can actually take"
want "$(grep -q 'no 5dive fleet is readable' <<<"$d" && echo true)" \
  "no fleet: the command PICKER carries the cause too — it is all a client draws before the user types: ${d:0:80}"
want "$(jq -e 'select(.id==1)|.result.authMethods|length>=1' "$WORK/nofleet.jsonl" >/dev/null 2>&1 && echo true)" \
  "no fleet: initialize STILL answers authMethods — the registry's verify-auth job runs on a fleetless box too"
want "$(jq -e 'select(.id==3)|.result.stopReason=="end_turn"' "$WORK/nofleet.jsonl" >/dev/null 2>&1 && echo true)" \
  "no fleet: the prompt is answered, not refused — an empty fleet is not an error"

# (b) A FLEET THAT IS THERE AND EMPTY reads differently from one we could not
# read. Same empty list, different next action, so this is the arm that proves
# the status is diagnosed rather than inferred from length.
nofleet 'printf "%s\n" "{\"ok\":true,\"data\":[]}"' "$WORK/emptyfleet.jsonl"
c=$(chunks_of "$WORK/emptyfleet.jsonl"); d=$(descs_of "$WORK/emptyfleet.jsonl")
want "$(grep -q 'no agents yet' <<<"$c" && grep -q 'agent create' <<<"$c" && echo true)" \
  "empty fleet: reads as a host with no agents yet, and points at \`agent create\`: ${c:0:70}"
want "$(! grep -q 'LOCAL fleet' <<<"$c" && echo true)" \
  "empty fleet: and does NOT reuse the no-fleet-here text — a successful read is authoritative"
want "$(grep -q 'no agents yet' <<<"$d" && echo true)" \
  "empty fleet: the picker carries that cause: ${d:0:80}"

# (c) NO CLI AT ALL. Distinct from both: nothing about fleets is knowable. Run
# without the stub rather than through it — the case is a binary that is not there.
rm -f "$WORK/stub-nofleet"
{
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}'
  req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}'
  req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"do the thing"}]}}'
} | ( ACP_CLI_BIN="$WORK/stub-nofleet" timeout 60 "$BUN" "$ACP_RUN_DIR/acp-server.ts" ) \
    2>>"$WORK/err.log" >"$WORK/nocli.jsonl" || true
c=$(chunks_of "$WORK/nocli.jsonl"); d=$(descs_of "$WORK/nocli.jsonl")
want "$(grep -q 'CLI is not reachable' <<<"$c" && echo true)" \
  "no CLI: reads as an absent CLI, not as an absent fleet: ${c:0:70}"
want "$(grep -q "not on this process's PATH" <<<"$d" && echo true)" \
  "no CLI: the picker says so too: ${d:0:80}"

# (e) WHOSE MESSAGE THE READER GETS. The roster read probes the CLI DIRECTLY before
# it tries `sudo -n` (rosterArgvs): `agent list` is a rootless read, and on a laptop
# the sudo attempt fails with "sudo: a password is required" — a sentence about sudo
# that says nothing about 5dive. Reverting to sudo-first would put that sentence in
# front of the user, so grade which of the two answers is the one explained.
#
# HONEST LIMIT: under a ROOT runner rosterArgvs never emits the sudo candidate, so
# this arm is vacuous there — it grades the ordering on a non-root box (the GitHub
# runner is `runner`) and cannot go falsely red on either.
mkdir -p "$WORK/pathbin"
cat > "$WORK/pathbin/5dive" <<'PB1'
#!/usr/bin/env bash
printf '%s\n' '{"ok":false,"error":{"code":10,"class":"permission","message":"DIRECT-ANSWER: no fleet on this box"}}'
exit 10
PB1
cat > "$WORK/pathbin/sudo" <<'PB2'
#!/usr/bin/env bash
echo "sudo: a password is required" >&2
exit 1
PB2
chmod +x "$WORK/pathbin/5dive" "$WORK/pathbin/sudo"
{
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}'
  req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}'
  req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"do the thing"}]}}'
} | ( unset ACP_CLI_BIN; PATH="$WORK/pathbin:$PATH" timeout 60 "$BUN" "$ACP_RUN_DIR/acp-server.ts" ) \
    2>>"$WORK/err.log" >"$WORK/direct.jsonl" || true
c=$(chunks_of "$WORK/direct.jsonl")
want "$(grep -q 'DIRECT-ANSWER' <<<"$c" && echo true)" \
  "roster reads the CLI directly and explains THAT answer: ${c:0:70}"
want "$(! grep -q 'password is required' <<<"$c" && echo true)" \
  "and never hands the user sudo's complaint instead of 5dive's"

# (f) SUDO EXISTS AND 5DIVE DOES NOT — the registry's own download-and-run case,
# and the arm that caught a real misdiagnosis: the box read as `unreachable` and told
# a reader with no 5dive binary to run `5dive init`. PATH is ONLY this dir: the real
# 5dive must be invisible, so unlike arm (e) it deliberately does not append $PATH.
#
# THE STUB ANSWERS IN FRENCH ON PURPOSE. sudo's failure is not a usable signal — its
# exit status for a missing command is a sudo-version property (1 here, not the 127 a
# shell gives) and its wording is gettext-localised. Presence is therefore decided on
# OUR side (direct-candidate-ran, or a 5dive envelope came back), never by reading
# sudo. A localised stub is what holds that: a regression to matching English
# "command not found" passes an English stub and reds this one.
mkdir -p "$WORK/nfbin"
# ABSOLUTE shebang, unlike every other stub here: PATH is stripped to this dir, so
# `#!/usr/bin/env bash` would need `bash` ON that PATH, fail to exec, and reach the
# server as a THROW — the no-CLI answer, by the wrong route. The arm then passes
# whether or not the code under test is correct. (It did; that is why this is here.)
cat > "$WORK/nfbin/sudo" <<'PB3'
#!/bin/bash
for a in "$@"; do [[ "$a" == -* ]] && continue; echo "sudo: $a : commande introuvable" >&2; exit 1; done
PB3
chmod +x "$WORK/nfbin/sudo"
{
  req '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}'
  req '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}'
  req '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"5dive-1","prompt":[{"type":"text","text":"do the thing"}]}}'
# `env` sets the stripped PATH on the SERVER only. Writing `PATH=... timeout` would
# resolve `timeout` itself against the stripped PATH, find nothing, and run no
# server at all — whereupon the `5dive init` assertion below passes on empty output.
} | ( unset ACP_CLI_BIN; timeout 60 env PATH="$WORK/nfbin" "$BUN" "$ACP_RUN_DIR/acp-server.ts" ) \
    2>>"$WORK/err.log" >"$WORK/nosudocli.jsonl" || true
c=$(chunks_of "$WORK/nosudocli.jsonl")
want "$([[ -n "$c" ]] && echo true)" \
  "sudo present, 5dive absent: the server answered at all — empty output would pass the negative below for free"
want "$(grep -q 'CLI is not reachable' <<<"$c" && echo true)" \
  "sudo present, 5dive absent: reads as an absent CLI, not an absent fleet: ${c:0:70}"
want "$(! grep -qi '5dive init' <<<"$c" && echo true)" \
  "sudo present, 5dive absent: and never tells a reader with no 5dive binary to run \`5dive init\`"

# (d) NEGATIVE CONTROL over the three arms above. They are substring greps, and a
# server that answered ONE generic empty-roster sentence to every cause would pass
# any one of them read alone. The distinctness is the deliverable, so assert it:
# the three replies must differ from each other.
want "$([[ "$(chunks_of "$WORK/nofleet.jsonl")" != "$(chunks_of "$WORK/emptyfleet.jsonl")" \
        && "$(chunks_of "$WORK/emptyfleet.jsonl")" != "$(chunks_of "$WORK/nocli.jsonl")" \
        && "$(chunks_of "$WORK/nofleet.jsonl")" != "$(chunks_of "$WORK/nocli.jsonl")" ]] && echo true)" \
  "control: the three causes produce three DIFFERENT replies — one generic sentence would pass each arm alone"
want "$([[ -n "$(chunks_of "$WORK/nocli.jsonl")" ]] && echo true)" \
  "control: and the no-CLI run spoke at all — an empty stdout would satisfy the distinctness arm"

printf '%s\n' "--- server stderr (diagnostics belong here):"
head -5 "$WORK/err.log" || true
if [[ $FAILED -ne 0 ]]; then printf 'FAILED %d of %d checks\n' "$FAILED" "$CHECKS"; exit 1; fi
printf 'PASS - %d checks\n' "$CHECKS"
