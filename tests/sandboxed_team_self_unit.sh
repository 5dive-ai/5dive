#!/usr/bin/env bash
# DIVE-9004 unit harness: a sandboxed seat's team rail (_team_self).
#
# The defect this pins: a sandboxed seat is outside group `claude`, the board is
# root:claude 2770, and the seat held no sudoers at all. The heartbeat dispatched
# its rows with a prompt that says `5dive task show`, and every board verb died on
# EACCES; `agent send` had no route either.
#
# The executor runs IN-PROCESS against a real fixture board, as "root reached by
# sudo from uid 4242" through the sealed seams (_gate_is_root, _gate_passwd_stream)
# — never by trusting an env name. The caller half is graded with sudo stubbed.
#
# Run: bash tests/sandboxed_team_self_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/team-self.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state" TASKS_DIR="$TMP/tasks" TASKS_DB="$TMP/tasks/tasks.db"
export REGISTRY="$STATE_DIR/agents.json"
mkdir -p "$STATE_DIR" "$TASKS_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh cmd_task.sh task/self.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}" >&2; }

cat >"$REGISTRY" <<'JSON'
{"version":2,"agents":{"sand":{"type":"claude","isolation":"sandboxed"},"main":{"type":"claude","isolation":"admin"},"std":{"type":"claude","isolation":"standard"}}}
JSON
_gate_passwd_stream() { printf '%s\n' 'agent-sand:x:4242:4242::/home/agent-sand:/bin/bash' 'agent-main:x:4243:4243::/home/agent-main:/bin/bash' 'agent-std:x:4244:4244::/home/agent-std:/bin/bash'; }
_gate_is_root() { return 0; }
_audit_is_root() { return 1; }
audit_append() { :; }

# Seed the board as main (sudo from 4243): one row for sand, one for main.
seed() { ( export SUDO_UID=4243; cmd_task add "$@" ) 2>&1 | grep -oE 'DIVE-[0-9]+' | head -1; }
tasks_db_init >/dev/null 2>&1
MINE=$(seed "a row for the sandboxed seat" --assignee=sand)
THEIRS=$(seed "a row for main" --assignee=main)
[[ -n "$MINE" && -n "$THEIRS" ]] && ok "fixture: two rows seeded ($MINE, $THEIRS)" || bad "fixture: rows seeded" "mine=$MINE theirs=$THEIRS"

# run the executor as sudo-from-<uid>; wire args NUL-separated on stdin
rail() { local uid="$1"; shift; ( export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_team_self_delegated ) 2>&1; }
col() { db "SELECT COALESCE($2,'') FROM tasks WHERE ident='$1';"; }

echo "== who may cross =="
out=$(rail 4243 show "$MINE"); [[ "$out" == *"serves sandboxed seats only"* ]] && ok "an admin seat is refused (it reaches the board directly)" || bad "admin refused" "$out"
out=$(rail 4244 show "$MINE"); [[ "$out" == *"serves sandboxed seats only"* ]] && ok "a standard seat is refused" || bad "standard refused" "$out"
out=$( (export SUDO_UID=; printf 'show\0%s\0' "$MINE" | cmd_team_self_delegated) 2>&1); [[ "$out" == *"requires sudo from an agent seat"* ]] && ok "no SUDO_UID is refused" || bad "no SUDO_UID refused" "$out"
out=$(rail 0 show "$MINE"); [[ "$out" == *"requires sudo from an agent seat"* ]] && ok "SUDO_UID=0 is refused" || bad "root refused" "$out"
out=$( _gate_is_root() { return 1; }; rail 4242 show "$MINE"); [[ "$out" == *"privileged internal primitive"* ]] && ok "non-root process is refused" || bad "non-root refused" "$out"

echo "== reads =="
out=$(rail 4242 show "$MINE"); [[ "$out" == *"a row for the sandboxed seat"* ]] && ok "show: own row reads" || bad "show own" "$out"
out=$(rail 4242 show "$THEIRS"); [[ "$out" == *"a row for main"* ]] && ok "show: a teammate's row reads (the board is shared)" || bad "show theirs" "$out"
out=$(rail 4242 ls --mine); [[ "$out" == *"$MINE"* && "$out" != *"$THEIRS"* ]] && ok "ls --mine: derived from SUDO_UID, shows only own row" || bad "ls --mine" "$out"

echo "== writes are self-scoped =="
out=$(rail 4242 start "$THEIRS"); [[ "$out" == *"not you"* && "$(col "$THEIRS" status)" != in_progress ]] && ok "start on a teammate's row: refused, row untouched" || bad "start theirs" "$out"
out=$(rail 4242 done "$THEIRS" --result=x); [[ "$out" == *"not you"* && "$(col "$THEIRS" status)" != done ]] && ok "done on a teammate's row: refused" || bad "done theirs" "$out"
out=$(rail 4242 start "$MINE"); [[ "$(col "$MINE" status)" == in_progress ]] && ok "start on own row: in_progress" || bad "start own" "$out"
out=$(rail 4242 need "$MINE" --type=decision --ask="left or right?" --options="left|right" --recommend=left --from=main)
[[ "$out" == *"refuses --from"* && -z "$(col "$MINE" need_type)" ]] && ok "need with --from: refused by name (provenance is derived, never claimed)" || bad "need --from" "$out"
out=$(rail 4242 done "$MINE" --result="did it" --force-result); [[ "$out" == *"refuses --force-result"* ]] && ok "--force-* refused" || bad "force refused" "$out"
out=$(rail 4242 done "$MINE" --result-file=/etc/shadow); [[ "$out" == *"refuses --result-file"* ]] && ok "*-file refused root-side (root never opens a seat-named path)" || bad "result-file refused" "$out"
out=$(rail 4242 done "$MINE" --result="did it, sandboxed"); [[ "$(col "$MINE" status)" == done && "$(col "$MINE" result)" == "did it, sandboxed" ]] && ok "done on own row: closed with the result" || bad "done own" "$out"
out=$(rail 4242 set-body "$MINE" --body=x); [[ "$out" == *"allows only"* ]] && ok "a verb off the list is refused" || bad "verb off list" "$out"

echo "== filing keeps DIVE-1065's creator =="
out=$(rail 4242 add "please look at this" --assignee=main --body="from a sandboxed seat")
NEW=$(grep -oE 'DIVE-[0-9]+' <<<"$out" | head -1)
[[ -n "$NEW" && "$(col "$NEW" created_by)" == sand ]] && ok "add: created_by is the sandboxed seat (so the 1065 hold sees a sandboxed creator)" || bad "add created_by" "new=$NEW by=$(col "$NEW" created_by) out=$out"
[[ "$(agent_tier "$(col "$NEW" created_by)")" == sandboxed ]] && ok "add: the creator's tier reads sandboxed (what the heartbeat's hold compares)" || bad "add tier" "$(agent_tier "$(col "$NEW" created_by)")"
out=$(rail 4242 add "forged" --assignee=main --from=main); [[ "$out" == *"refuses --from"* ]] && ok "add --from refused" || bad "add --from" "$out"

echo "== send =="
cmd_deliver() { printf 'DELIVER %s\n' "$*"; }
out=$(rail 4242 send main "hello from sand"); [[ "$out" == "DELIVER main hello from sand" ]] && ok "send: hands target+message to cmd_deliver" || bad "send" "$out"
out=$(rail 4242 send --urgent main "now"); [[ "$out" == "DELIVER --urgent main now" ]] && ok "send --urgent carried" || bad "send urgent" "$out"
out=$(rail 4242 send --wake main "x"); [[ "$out" == *"refuses --wake"* ]] && ok "send --wake refused (no lifecycle power)" || bad "send wake" "$out"
out=$(rail 4242 send --id=abc main "x"); [[ "$out" == *"refuses --id"* ]] && ok "send --id refused" || bad "send id" "$out"
unset -f cmd_deliver

echo "== caller half =="
CALLS="$TMP/calls"; WIRE="$TMP/wire"
_gate_is_root() { return 1; }
sudo() {
  if [[ "$2" == "-l" ]]; then [[ "$4" == "_team_self" ]] && return 0 || return 1; fi
  printf '%s\n' "$*" >>"$CALLS"
  python3 -c 'import sys; print(sys.stdin.buffer.read().split(b"\0")[:-1])' >"$WIRE"
}
chmod 0500 "$TASKS_DIR"   # the board is not writable from this "seat"
if [[ -w "$TASKS_DIR" ]]; then
  ok "caller half: (skipped — running as root, the board stays writable)"
else
  : >"$CALLS"; _team_self_try show "$MINE" >/dev/null; rc=$?
  [[ $rc == 0 && "$(cat "$CALLS")" == "-n /usr/local/bin/5dive _team_self" ]] && ok "show crosses through the exact path only" || bad "show crosses" "rc=$rc $(cat "$CALLS")"
  [[ "$(cat "$WIRE")" == "[b'show', b'$MINE']" ]] && ok "operation travels NUL-separated on stdin" || bad "wire" "$(cat "$WIRE")"
  printf 'done from a file\n' >"$TMP/r.txt"
  _team_self_try close "$MINE" --result-file="$TMP/r.txt" >/dev/null
  [[ "$(cat "$WIRE")" == "[b'done', b'$MINE', b'--result=done from a file']" ]] && ok "--result-file is read by the seat and crosses inlined; close->done" || bad "inline" "$(cat "$WIRE")"
  out=$( (_team_self_try set-body "$MINE" --body=x) 2>&1 ); rc=$?
  [[ $rc != 0 && $rc != 125 && "$out" == *"not on a sandboxed seat's team rail"* ]] && ok "an off-rail verb fails with a plain sentence, not EACCES" || bad "off-rail" "rc=$rc $out"
  _team_self_send main "hi" >/dev/null
  [[ "$(cat "$WIRE")" == "[b'send', b'main', b'hi']" ]] && ok "agent send crosses as send <agent> <message>" || bad "send wire" "$(cat "$WIRE")"
fi
chmod 0700 "$TASKS_DIR"
: >"$CALLS"; _team_self_try show "$MINE" >/dev/null 2>&1; rc=$?
[[ $rc == 125 && ! -s "$CALLS" ]] && ok "a seat that can write the board keeps today's path (125, no sudo)" || bad "writable board falls through" "rc=$rc"
chmod 0500 "$TASKS_DIR"
sudo() { [[ "$2" == "-l" ]] && return 1; printf '%s\n' "$*" >>"$CALLS"; }
: >"$CALLS"; _team_self_try show "$MINE" >/dev/null 2>&1; rc=$?
[[ $rc == 125 && ! -s "$CALLS" ]] && ok "a seat without the grant falls through (125, no sudo)" || bad "ungranted falls through" "rc=$rc"
chmod 0700 "$TASKS_DIR"

echo "== wiring =="
grep -q '_team_self_try "$sub" "$@"' src/task/dispatch.sh && ok "cmd_task routes through the rail" || bad "cmd_task wiring"
grep -q '_team_self_send "$name" "$message"' src/cmd_agent_runtime.sh && ok "cmd_send routes through the rail" || bad "cmd_send wiring"
grep -q '^    _team_self)' src/main.sh && ok "main.sh dispatches _team_self" || bad "main wiring"
grep -q 'src/task/self.sh' build.sh && ok "build.sh bundles self.sh" || bad "build wiring"

echo "PASS=$P FAIL=$F"
(( F == 0 ))
