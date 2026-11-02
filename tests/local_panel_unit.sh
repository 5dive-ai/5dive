#!/usr/bin/env bash
# DIVE-7576: the office control panel — /panel on the office chat server, and
# its one root entry `5dive local panel-exec` (src/cmd_local_panel.sh).
#
#   A. panel-exec: every verb runs with good arguments; every injection shape
#      (; $( leading - newline over-long) is refused BEFORE the CLI is called;
#      a gate answer must be one the gate offers; every call is audited and a
#      secret value never is.
#   S. the socket form (what systemd's Accept=yes instance runs): one JSON
#      line, the value after it; a newline inside an argument is refused.
#   U. the socket + service unit text; `local pair --owner`; build list.
#   G. gate evidence: the panel's unit is ACCEPT 3 in the real
#      _gate_cgroup_human_capable, look-alikes are not.
#   B. live: the REAL server on bun with a stand-in for systemd's socket
#      activation that runs the real panel-exec. A chat-only device gets 403
#      on every /api/panel route; an owner device works; the audit names it.
#   N. no new outbound host in the server or the panel module.
#
# Needs bun, openssl, curl, jq. Every address here is loopback; no network.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }
AT='@'   # systemd template instances; spelled through a variable so no line reads like an address

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/local-panel.XXXXXX")"
PIDS=()
trap 'rc=$?; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export FIVE_LOCAL_CHAT_ROOT="$TMPD/root"
export FIVE_PANEL_CLI="$TMPD/fake5dive"
export FIVE_LOCAL_ONLY_FILE="$TMPD/local-only" FIVE_API_BASE_FILE="$TMPD/api-base" FIVEDIVE_CONNECTORD_ENV="$TMPD/no-connectord.env"
mkdir -p "$TMPD/root/etc/systemd/system" "$TMPD/root/etc/5dive/local-chat" "$TMPD/profiles/office-ai" "$TMPD/profiles/claude-main"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/local_only.sh cmd_local_chat.sh cmd_local_chat_server.sh cmd_local_panel.sh; do source "src/$f"; done
set +e
JSON_MODE=0
require_root() { :; }
AUTH_PROFILES_DIR="$TMPD/profiles"
TOOLS_ENV_FILE="$TMPD/tools.sh"
eval "$(sed -n '/^_tool_set_vars() {/,/^}/p' src/cmd_tool.sh)"
printf "export GITHUB_TOKEN='x'\nexport OPENAI_API_KEY='y'\n" >"$TOOLS_ENV_FILE"
printf 'FIVEDIVE_CUSTOM_HARNESS=claude\nFIVEDIVE_CUSTOM_BASE_URL=http://gpu.office:11434\nFIVEDIVE_CUSTOM_MODEL=qwen3\n' >"$TMPD/profiles/office-ai/combined.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=z\n' >"$TMPD/profiles/claude-main/combined.env"

# The stand-in CLI: logs each argv (%q, one line per call) and keeps its stdin;
# answers the shapes the panel reads.
cat >"$FIVE_PANEL_CLI" <<FAKE
#!/usr/bin/env bash
log="$TMPD/cli.log"
printf '%q ' "\$@" >>"\$log"; printf '\n' >>"\$log"
args=" \$* "
case "\$args" in
  *" agent list "*)  echo '{"ok":true,"data":[{"name":"alice","active":"active"},{"name":"bob","active":"inactive"}]}' ;;
  *" task ls "*)     echo '{"ok":true,"data":{"tasks":[{"ident":"DIVE-1","title":"Draft the NDA","status":"in_progress","assignee":"alice"}]}}' ;;
  *" task inbox "*)  echo '{"ok":true,"data":{"inbox":[{"ident":"DIVE-2","need_type":"decision","need_options":"Send it today|Wait for the client","recommend":"Send it today","ask":"Send the NDA?"},{"ident":"DIVE-3","need_type":"approval","need_options":"","ask":"Merge?"}]}}' ;;
  *" secret write "*) cat >"$TMPD/secret.stdin"; echo '{"ok":true,"data":{"key":"X"}}' ;;
  *" account test "*) cat >"$TMPD/test.stdin"; echo '{"ok":true,"data":{"ok":true,"reason":"answered"}}' ;;
  *" config local-only check "*) printf 'ok    local-only switch                  on\nLEAK  snap store                         online\n' ;;
  *" self-update --help "*) echo 'usage: 5dive self-update' ;;
  *" agent create "*) echo '{"ok":false,"error":{"message":"agent create stub refused"}}'; exit 1 ;;
  *) echo '{"ok":true,"data":{"done":true}}' ;;
esac
FAKE
chmod +x "$FIVE_PANEL_CLI"
LOG="$TMPD/cli.log"; AUD="$(_lp_audit_file)"
pe() { ( _lp_exec "$@" ) </dev/null; }
calls() { if [[ -f "$LOG" ]]; then wc -l <"$LOG"; else echo 0; fi; }

# ── A. verbs, good arguments ─────────────────────────────────────────────────
okv() { # <arm> <jq on reply> <args...>
  local arm="$1" q="$2"; shift 2
  local out; out=$(pe "$@")
  if [[ "$(jq -r '.ok' <<<"$out")" == true ]] && jq -e "$q" <<<"$out" >/dev/null 2>&1; then ok_ "$arm"; else bad_ "$arm" "$out"; fi
}
okv 'A1 team lists the agents' '.data | map(.name) == ["alice","bob"]' team
okv 'A2 board: open rows and waiting gates' '(.data.tasks[0].ident == "DIVE-1") and (.data.gates | length == 2)' board
okv 'A3 secrets: names only, never values' '.data == ["GITHUB_TOKEN","OPENAI_API_KEY"]' secrets
okv 'A4 settings: local-only rows, the local AI, update hidden' '(.data.localOnly | length == 2) and (.data.localOnly[1] == {ok:false,item:"snap store",state:"online"}) and (.data.accounts == [{name:"office-ai",harness:"claude",baseUrl:"http://gpu.office:11434",model:"qwen3"}]) and (.data.updateFromFile == false)' settings
okv 'A5 agent-restart' '.data.done' agent-restart alice
check 'A5a … ran `agent restart alice`' 'grep -qx -- "--json agent restart alice " <<<"$(tail -1 "$LOG")"'
okv 'A6 agent-remove' '.data.done' agent-remove bob
check 'A6a … ran `agent rm bob`' 'grep -qx -- "--json agent rm bob " <<<"$(tail -1 "$LOG")"'
out=$(pe agent-add paralegal)
check 'A7 agent-add runs create on the local AI account (harness + account from the profile)' 'grep -qx -- "--json agent create paralegal --type=claude --auth-profile=office-ai " <<<"$(tail -1 "$LOG")"'
check 'A7a … and a CLI failure comes back as the error, not ok' '[[ "$(jq -r .ok <<<"$out")" == false ]] && [[ "$(jq -r .error <<<"$out")" == "agent create stub refused" ]]'
okv 'A8 gate-answer with a listed option' '.data.done' gate-answer DIVE-2 'Send it today'
check 'A8a … runs task answer as a human from the panel, the value as ONE argument' 'grep -qxF -- "--json task answer DIVE-2 --value=Send\\ it\\ today --human --from=office-panel " <<<"$(tail -1 "$LOG")"'
okv 'A9 gate-answer approve on an approval gate' '.data.done' gate-answer DIVE-3 approve
out=$(printf 's3cr3t-value' | ( _lp_exec secret-set ACME_API_KEY ))
check 'A10 secret-set: the value on stdin into the tools store' '[[ "$(jq -r .data.saved <<<"$out")" == true ]] && [[ "$(cat "$TMPD/secret.stdin")" == s3cr3t-value ]] && grep -qx -- "--json secret write ACME_API_KEY --connector=tools " <<<"$(tail -1 "$LOG")"'
check 'A10a the secret value is on no argv and in no audit line' '! grep -q s3cr3t "$LOG" && ! grep -q s3cr3t "$AUD"'
okv 'A11 account-test reads the account' '.data.ok == true' account-test office-ai
check 'A11a … ran account test with the saved address, no key flag' 'grep -qx -- "--json account test --base-url=http://gpu.office:11434 --model=qwen3 --harness=claude " <<<"$(tail -1 "$LOG")"'
printf 'FIVEDIVE_CUSTOM_API_KEY=k-123\n' >>"$TMPD/profiles/office-ai/combined.env"
pe account-test office-ai >/dev/null
check 'A11b … a saved key goes on stdin, never argv' '[[ "$(cat "$TMPD/test.stdin")" == k-123 ]] && ! grep -q k-123 "$LOG"'
okv 'A12 device-revoke' '.data.done' device-revoke abcdef12
check 'A12a … ran local devices revoke' 'grep -qx -- "--json local devices revoke abcdef12 " <<<"$(tail -1 "$LOG")"'
out=$(pe account-test claude-main)
check 'A13 account-test refuses an account that is not a local AI' '[[ "$(jq -r .ok <<<"$out")" == false ]]'

# ── R. refusals: the CLI is never reached ────────────────────────────────────
refused() { # <arm> <args...>
  local arm="$1"; shift
  local before out after; before=$(calls); out=$(pe "$@"); after=$(calls)
  if [[ "$(jq -r .ok <<<"$out")" == false ]] && [[ "$(jq -r .error <<<"$out")" == refused:* ]] && (( before == after )); then ok_ "$arm"
  else bad_ "$arm" "out=$out calls $before→$after"; fi
}
LONG=$(printf 'a%.0s' $(seq 1 201))
refused 'R1 unknown verb' rm-rf /
refused 'R2 no verb'
refused 'R3 extra argument' agent-restart alice bob
refused 'R4 missing argument' agent-restart
for shape in 'alice;id' 'a$(id)' '-rf' $'alice\nbob' "$(printf 'a%.0s' $(seq 1 17))" 'Alice' 'al ice' '../etc'; do
  refused "R5 agent name refused: $(printf '%q' "$shape" | head -c 30)" agent-restart "$shape"
done
for shape in 'DIVE-1;id' 'DIVE-$(id)' '-DIVE-1' $'DIVE-1\nDIVE-2' "DIVE-$(printf '1%.0s' $(seq 1 8))"; do
  refused "R6 task ident refused: $(printf '%q' "$shape" | head -c 30)" gate-answer "$shape" approve
done
for shape in 'yes;id' 'a$(id)' '--value=x' $'approve\nreject' "$LONG" 'a`id`' 'a|b' 'a>b'; do
  refused "R7 gate value refused: $(printf '%q' "$shape" | head -c 30)" gate-answer DIVE-2 "$shape"
done
for shape in 'KEY;id' 'K$(id)' '-KEY' $'KEY\nX' "K$(printf 'A%.0s' $(seq 1 64))" 'lower_key'; do
  refused "R8 secret name refused: $(printf '%q' "$shape" | head -c 30)" secret-set "$shape"
done
for shape in 'abc;id' '$(id)aaaaaa' '-abcdef12' $'abcdef12\n' 'ABCDEF12'; do
  refused "R9 device id refused: $(printf '%q' "$shape" | head -c 30)" device-revoke "$shape"
done
refused 'R10 account name with a slash' account-test '../x'
before=$(calls); out=$(pe gate-answer DIVE-2 'Delete everything')
check 'R11 a gate answer the gate does not offer is refused (only the read ran)' '[[ "$(jq -r .ok <<<"$out")" == false ]] && (( $(calls) == before + 1 )) && ! grep -q "task answer" <<<"$(tail -1 "$LOG")"'
out=$(pe gate-answer DIVE-9 approve)
check 'R12 a row with no open gate is refused' '[[ "$(jq -r .error <<<"$out")" == *"not waiting"* ]] && ! grep -q "task answer" <<<"$(tail -1 "$LOG")"'
out=$(head -c 9000 /dev/zero | tr '\0' a | ( _lp_exec secret-set BIG_API_KEY ))
check 'R13 a secret value over 8 KB is refused' '[[ "$(jq -r .ok <<<"$out")" == false ]] && ! grep -q BIG_API_KEY <<<"$(tail -1 "$LOG")"'

# ── A. audit ─────────────────────────────────────────────────────────────────
check 'A20 the audit log exists, 0600' '[[ -f "$AUD" && "$(stat -c %a "$AUD")" == 600 ]]'
check 'A21 an action is audited with its verb, args and ok' 'grep -qP "\tagent-restart\talice\tok$" "$AUD"'
check 'A22 a refusal is audited with the reason' 'grep -qP "\tagent-restart\talice;id\trefused: argument 1 is not a valid agent$" "$AUD"'
check 'A23 a newline in an argument cannot forge a second audit line' '! grep -qP "^bob" "$AUD"'

# ── S. socket form ───────────────────────────────────────────────────────────
sock() { ( _lp_exec --socket ); }
out=$(printf '{"argv":["agent-restart","alice"],"device":"0011aabb"}\n' | sock)
check 'S1 a JSON request runs, the device is audited' '[[ "$(jq -r .ok <<<"$out")" == true ]] && grep -qP "^\S+\t0011aabb\tagent-restart\talice\tok$" <<<"$(tail -1 "$AUD")"'
out=$(printf '{"argv":["agent-restart","alice\\nbob"]}\n' | sock)
check 'S2 a newline inside an argument is refused' '[[ "$(jq -r .ok <<<"$out")" == false ]]'
out=$(printf 'agent-restart alice\n' | sock)
check 'S3 a request that is not JSON is refused' '[[ "$(jq -r .error <<<"$out")" == "bad request" ]]'
out=$(printf '{"argv":["secret-set","SOCK_API_KEY"],"device":"0011aabb"}\nfrom-the-socket' | sock)
check 'S4 the value after the line reaches secret write on stdin' '[[ "$(jq -r .ok <<<"$out")" == true && "$(cat "$TMPD/secret.stdin")" == from-the-socket ]]'
out=$(printf '{"argv":["agent-restart","-x"],"device":"$(id)"}\n' | sock)
check 'S5 a forged device id is audited as invalid, the flag refused' '[[ "$(jq -r .ok <<<"$out")" == false ]] && grep -qP "\tinvalid\t" <<<"$(tail -1 "$AUD")"'
out=$(printf '{"argv":["team",1]}\n' | sock)
check 'S6 a non-string argument is refused' '[[ "$(jq -r .error <<<"$out")" == "bad request" ]]'

# ── U. units, pair, build ────────────────────────────────────────────────────
st=$(_lp_socket_text); sv=$(_lp_service_text)
check 'U1 socket: root:5dive-chat 0660, one instance per call' 'grep -qx "ListenStream=/run/5dive-local-panel.sock" <<<"$st" && grep -qx "SocketGroup=5dive-chat" <<<"$st" && grep -qx "SocketMode=0660" <<<"$st" && grep -qx "Accept=yes" <<<"$st"'
check 'U2 service: the one fixed command, stdin/stdout on the socket' 'grep -qx "ExecStart=/usr/local/bin/5dive local panel-exec --socket" <<<"$sv" && grep -qx "StandardInput=socket" <<<"$sv" && grep -qx "StandardOutput=socket" <<<"$sv"'
ut=$(_lc_unit_text /usr/local/bin/bun 192.0.2.10 8443 8480 /etc/5dive/x)
check 'U3 the chat server keeps its sandbox (5dive-chat, NoNewPrivileges, ProtectSystem=strict)' 'grep -qx "User=5dive-chat" <<<"$ut" && grep -qx "NoNewPrivileges=yes" <<<"$ut" && grep -qx "ProtectSystem=strict" <<<"$ut"'
check 'U4 no sudoers grant is written for the chat user' '! grep -q "sudoers.d" src/cmd_local_panel.sh src/cmd_local_chat.sh'
check 'U5 build.sh bundles the panel module' 'grep -qx "  src/cmd_local_panel.sh" build.sh'
check 'U6 serve installs the panel units, serve --stop removes them' 'grep -q "^  _lp_install$" src/cmd_local_chat.sh && grep -q "^  _lp_remove$" src/cmd_local_chat.sh'
check 'U7 local pair refuses an unknown flag' '! ( _lc_pair --admin ) 2>/dev/null'

# ── G. gate evidence ─────────────────────────────────────────────────────────
eval "$(sed -n '/^_gate_cgroup_pick_line()/,/^}/p;/^_gate_cgroup_human_capable()/,/^}/p' src/lib/tasks_db.sh)"
try() { _CG="$1"; ( _gate_caller_cgroup() { printf '%s' "$_CG"; }; _gate_cgroup_human_capable ); }
check 'G1 the panel instance is human-capable (ACCEPT 3)' 'try "/system.slice/system-5dive\\x2dlocal\\x2dpanel.slice/5dive-local-panel${AT}3-4242-0.service"'
check 'G2 the chat server itself is not' '! try "/system.slice/5dive-local-chat.service"'
check 'G3 another unit in the panel slice is not' '! try "/system.slice/system-5dive\\x2dlocal\\x2dpanel.slice/evil.service"'
check 'G4 a user-manager scope named like it is not' '! try "/user.slice/user-1000.slice/user${AT}1000.service/app.slice/system-5dive\\x2dlocal\\x2dpanel.slice/5dive-local-panel${AT}x.service"'
check 'G5 an agent unit is still refused' '! try "/system.slice/system-5dive\\x2dagent.slice/5dive-agent${AT}main.service"'
check 'G6 the panel slice without the escape is not' '! try "/system.slice/system-5dive-local-panel.slice/5dive-local-panel${AT}x.service"'

# ── B. live server ───────────────────────────────────────────────────────────
BUN=$(command -v bun || echo /usr/local/bin/bun)
if [[ ! -x "$BUN" ]]; then bad_ 'B0 bun present' "no bun"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
_local_chat_server_ts >"$TMPD/server.ts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=t" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" >/dev/null 2>&1
printf 'CONNECTORD_TOKEN="boxtok"\n' >"$TMPD/tok.env"; printf '["alice"]\n' >"$TMPD/agents.json"
STATE="$TMPD/state"; mkdir -p "$STATE"
# A db from before roles existed: one device, no role column.
"$BUN" -e 'import { Database } from "bun:sqlite"; const d = new Database(process.argv[1] + "/chat.db", { create: true });
  d.exec("CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, cookie_hash TEXT NOT NULL UNIQUE, created INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0); CREATE TABLE pair_codes (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0);");
  d.query("INSERT INTO devices VALUES (?,?,?,?,?,0)").run("0ld0ld0ld0", "old phone", "h", 1, 1);' "$STATE"
# systemd's Accept=yes, stood in for: each connection runs the real panel-exec.
cat >"$TMPD/panel-exec.sh" <<PEX
#!/usr/bin/env bash
cd "$PWD"
export FIVE_LOCAL_CHAT_ROOT="$FIVE_LOCAL_CHAT_ROOT" FIVE_PANEL_CLI="$FIVE_PANEL_CLI"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_local_chat.sh cmd_local_panel.sh; do source "src/\$f"; done
set +e; require_root() { :; }; AUTH_PROFILES_DIR="$TMPD/profiles"; TOOLS_ENV_FILE="$TOOLS_ENV_FILE"
$(declare -f _tool_set_vars)
_lp_exec --socket
PEX
chmod +x "$TMPD/panel-exec.sh"
PSOCK="$TMPD/panel.sock"
cat >"$TMPD/sockd.py" <<'SOCKD'
# Accept=yes, as systemd does it: each connection becomes the child's stdin and stdout.
import socket, subprocess, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
while True:
    c, _ = s.accept()
    subprocess.Popen(["bash", sys.argv[2]], stdin=c.fileno(), stdout=c.fileno())
    c.close()
SOCKD
python3 -I "$TMPD/sockd.py" "$PSOCK" "$TMPD/panel-exec.sh" >"$TMPD/sockd.log" 2>&1 & PIDS+=($!)
LAN=$((20000 + RANDOM % 20000)); LOOP=$((LAN + 1))
LC_STATE="$STATE" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$LAN LC_LOOP_PORT=$LOOP LC_CERT="$TMPD/cert.pem" LC_KEY="$TMPD/key.pem" \
  LC_TOKEN_FILE="$TMPD/tok.env" LC_AGENTS_FILE="$TMPD/agents.json" LC_PANEL_SOCK="$PSOCK" \
  "$BUN" "$TMPD/server.ts" serve >"$TMPD/server.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP/" && [[ -S "$PSOCK" ]] && break; sleep 0.1; done
W="https://127.0.0.1:$LAN"
code(){ curl -sk -o /dev/null -w '%{http_code}' "$@"; }
pair_dev() { # <jar> <role|""> <code>
  local h; h=$(printf '%s' "$3" | sha256sum | cut -d' ' -f1)
  LC_STATE="$STATE" "$BUN" "$TMPD/server.ts" admin pair-add "$h" $(( $(date +%s) + 900 )) ${2:+"$2"} >/dev/null
  curl -sSk -c "$1" -H 'x-local-chat: 1' -H 'content-type: application/json' -d "{\"code\":\"$3\",\"name\":\"t\"}" "$W/api/pair"
}
r=$(LC_STATE="$STATE" "$BUN" "$TMPD/server.ts" admin devices-ls)
check 'B1 an existing db gains the role column in place; old devices are chat-only' '[[ "$(jq -r ".[] | select(.id == \"0ld0ld0ld0\") | .role" <<<"$r")" == chat ]]'
r=$(pair_dev "$TMPD/chat.jar" "" CHAT2345)
check 'B2 a plain pair code makes a chat device' '[[ "$(jq -r .role <<<"$r")" == chat ]]'
r=$(pair_dev "$TMPD/owner.jar" owner OWNR2345)
check 'B3 an --owner pair code makes an owner device' '[[ "$(jq -r .role <<<"$r")" == owner ]]'
check 'B4 admin pair-add refuses an unknown role' '! LC_STATE="$STATE" "$BUN" "$TMPD/server.ts" admin pair-add "$(printf x | sha256sum | cut -d" " -f1)" 9999999999 root >/dev/null 2>&1'
cw() { curl -sSk -b "$TMPD/chat.jar" -H 'x-local-chat: 1' "$@"; }
ow() { curl -sSk -b "$TMPD/owner.jar" -H 'x-local-chat: 1' "$@"; }
before_aud=$(wc -l <"$AUD")
n403=0; nroutes=0
for rt in "GET team" "POST team" "GET board" "POST answer" "GET secrets" "POST secrets" "GET settings" "POST test" "POST revoke" "GET nope"; do
  m=${rt% *}; pth=/api/panel/${rt#* }; nroutes=$((nroutes + 1))
  if [[ $m == GET ]]; then c=$(code -b "$TMPD/chat.jar" "$W$pth")
  else c=$(code -b "$TMPD/chat.jar" -H 'x-local-chat: 1' -H 'content-type: application/json' -d '{"action":"restart","name":"alice","ident":"DIVE-3","value":"approve","account":"office-ai","id":"abcdef12"}' "$W$pth"); fi
  if [[ "$c" == 403 ]]; then n403=$((n403 + 1)); else printf '     %s %s → %s\n' "$m" "$pth" "$c"; fi
done
check "B5 a chat-only device gets 403 on every /api/panel route ($n403/$nroutes)" '(( n403 == nroutes ))'
check 'B6 … and nothing reached root (no audit line)' '(( $(wc -l <"$AUD") == before_aud ))'
check 'B7 an unpaired browser gets 401 on the panel API' '[[ "$(code "$W/api/panel/team")" == 401 ]]'
check 'B8 the chat device still chats' '[[ "$(cw "$W/api/agents" | jq -r .role)" == chat ]]'
check 'B9 the owner device sees its role (the chat page shows Manage)' '[[ "$(ow "$W/api/agents" | jq -r .role)" == owner ]]'
OWNER_ID=$(LC_STATE="$STATE" "$BUN" "$TMPD/server.ts" admin devices-ls | jq -r '.[] | select(.role == "owner") | .id')
check 'B10 owner: team' '[[ "$(ow "$W/api/panel/team" | jq -c "[.data[].name]")" == "[\"alice\",\"bob\"]" ]]'
check 'B11 owner: the action is audited with the owner device id' 'grep -qP "\t${OWNER_ID}\tteam\t\tok$" <<<"$(tail -1 "$AUD")"'
check 'B12 owner: restart' '[[ "$(ow -H "content-type: application/json" -d "{\"action\":\"restart\",\"name\":\"alice\"}" "$W/api/panel/team" | jq -r .ok)" == true ]]'
check 'B13 owner: board' '[[ "$(ow "$W/api/panel/board" | jq ".data.gates | length")" == 2 ]]'
check 'B14 owner: answer a gate' '[[ "$(ow -H "content-type: application/json" -d "{\"ident\":\"DIVE-2\",\"value\":\"Wait for the client\"}" "$W/api/panel/answer" | jq -r .ok)" == true ]]'
c=$(code -b "$TMPD/owner.jar" -H 'x-local-chat: 1' -H 'content-type: application/json' -d '{"ident":"DIVE-2","value":"x;reboot"}' "$W/api/panel/answer")
check 'B15 owner: an injected answer is refused by root (422), not run' '[[ "$c" == 422 ]] && ! grep -q reboot "$LOG"'
check 'B16 owner: set a secret; the value reaches secret write on stdin only' '[[ "$(ow -H "content-type: application/json" -d "{\"name\":\"WEB_API_KEY\",\"value\":\"v-from-web\"}" "$W/api/panel/secrets" | jq -r .ok)" == true && "$(cat "$TMPD/secret.stdin")" == v-from-web ]] && ! grep -q v-from-web "$AUD" "$LOG"'
s=$(ow "$W/api/panel/settings")
check 'B17 owner: settings (local-only rows, the AI, devices with roles, this device marked)' '[[ "$(jq -r ".data.localOnly | length" <<<"$s")" == 2 && "$(jq -r ".data.accounts[0].name" <<<"$s")" == office-ai && "$(jq -r ".data.me" <<<"$s")" == "$OWNER_ID" ]] && jq -e ".data.devices | map(.role) | index(\"owner\")" <<<"$s"'
check 'B18 owner: the Test button runs account test' '[[ "$(ow -H "content-type: application/json" -d "{\"account\":\"office-ai\"}" "$W/api/panel/test" | jq -r .data.ok)" == true ]]'
check 'B19 a POST without the custom header is refused (cross-site guard holds on the panel)' '[[ "$(code -b "$TMPD/owner.jar" -H "content-type: application/json" -d "{\"action\":\"remove\",\"name\":\"alice\"}" "$W/api/panel/team")" == 403 ]]'
check 'B20 /panel is served with the same CSP' '[[ "$(curl -sk -D - -o "$TMPD/panel.html" "$W/panel" | grep -ci "content-security-policy: default-src .self.")" == 1 ]] && grep -q "<title>Office server</title>" "$TMPD/panel.html"'
sed -n '/<script>/,/<\/script>/p' "$TMPD/panel.html" | sed '1d;$d' >"$TMPD/panel.js"
check 'B21 the panel page script parses' '"$BUN" build --no-bundle "$TMPD/panel.js" >/dev/null'
curl -sk "$W/" | sed -n '/<script>/,/<\/script>/p' | sed '1d;$d' >"$TMPD/chat.js"
check 'B22 the chat page script still parses' '"$BUN" build --no-bundle "$TMPD/chat.js" >/dev/null'
kill "${PIDS[0]}" 2>/dev/null; sleep 0.3; rm -f "$PSOCK"
r=$(ow "$W/api/panel/team")
check 'B23 helper down: a plain error, the chat page still serves' '[[ "$(jq -r .error <<<"$r")" == *"not running"* ]] && [[ "$(code "$W/")" == 200 ]]'

# ── N. no new outbound host ──────────────────────────────────────────────────
hosts=$( { _local_chat_server_ts; cat src/cmd_local_panel.sh; } | grep -oE 'https?://[A-Za-z0-9.-]*' | sort -u | tr '\n' ' ')
check "N1 the only URLs in the server + panel are loopback (${hosts})" '[[ -z "$(tr " " "\n" <<<"$hosts" | grep -vE "^https?://(127\.0\.0\.1)?$" | grep -v "^$")" ]]'
check 'N2 the panel module calls no network tool' '! grep -qwE "curl|wget|nc|ssh" src/cmd_local_panel.sh'
srv_code=$(_local_chat_server_ts | sed '/^const PAGE = /,$d' | grep -v '^[[:space:]]*//')
check 'N3 the server process dials nothing but the panel socket' '[[ "$(grep -cE "createConnection|node:net|fetch\\(|Bun\\.connect\\(" <<<"$srv_code")" == 1 ]] && grep -q "unix: PANEL_SOCK" <<<"$srv_code"'
check 'N4 the pages fetch only their own origin (relative paths)' '! _local_chat_server_ts | grep -oE "fetch\\([^,)]*" | grep -vE "fetch\\((path|\"/)"' 

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
