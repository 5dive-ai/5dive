#!/usr/bin/env bash
# DIVE-7558: the office chat server (src/cmd_local_chat.sh + the bun source in
# src/cmd_local_chat_server.sh) and the wiring around it.
#
#   A. bash: the api-base file the root rail reads, the local-only refusal of
#      `chat e2e enable`, the gate-notice route (office chat, never Telegram),
#      the unit text, the build list.
#   C. DIVE-7566: `local serve` first run on a never-linked box (minted token),
#      the rail's token choice by destination.
#   B. live: the REAL server on bun, two loopback listeners on random ports (the
#      office listener on 127.0.0.1 with a throwaway self-signed cert), driven
#      with curl exactly as the root rail and a browser would.
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

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/local-chat.XXXXXX")"
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export FIVE_LOCAL_ONLY_FILE="$TMPD/local-only"
export FIVE_API_BASE_FILE="$TMPD/api-base"
export FIVEDIVE_CONNECTORD_ENV="$TMPD/no-connectord.env"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/local_only.sh cmd_local_chat.sh cmd_local_chat_server.sh cmd_local_panel.sh cmd_dashboard_relay.sh; do source "src/$f"; done
set +e   # header.sh turns errexit on; this harness reads every rc itself
JSON_MODE=0

# ── A. bash ──────────────────────────────────────────────────────────────────
unset FIVE_API_BASE
check 'A1 no api-base file → production' '[[ "$(five_api_base)" == https://api.5dive.com ]]'
printf 'http://127.0.0.1:8480/\n' >"$FIVE_API_BASE_FILE"
check 'A2 the file wins, trailing slash dropped' '[[ "$(five_api_base)" == http://127.0.0.1:8480 ]]'
check 'A3 the file wins over FIVE_API_BASE' '[[ "$(FIVE_API_BASE=https://x.example.test five_api_base)" == http://127.0.0.1:8480 ]]'
printf 'not a url; rm -rf /\n' >"$FIVE_API_BASE_FILE"
check 'A4 a junk line is ignored (env, then production)' '[[ "$(FIVE_API_BASE=https://x.example.test five_api_base)" == https://x.example.test ]]'
rm -f "$FIVE_API_BASE_FILE"
check 'A5 the root rail reads it' 'grep -q "^_dash_relay_api_base() { five_api_base; }" src/cmd_dashboard_relay.sh'
check 'A6 the partner rail reads it' 'grep -q "^_box_api_base() { five_api_base; }" src/lib/box_token.sh'

# local-only refusal of e2e pairing; off = unchanged.
check 'A7 off: chat e2e enable passes the gate' '( local_only_gate chat e2e enable s3cr3t )'
touch "$FIVE_LOCAL_ONLY_FILE"
out=$( ( local_only_gate chat e2e enable s3cr3t ) 2>&1 ); r=$?
if (( r != 0 )) && grep -q "office chat" <<<"$out"; then ok_ 'A8 on: chat e2e enable is refused, naming the office chat'; else bad_ 'A8 on: chat e2e enable is refused' "rc=$r $out"; fi
check 'A9 on: chat e2e status still runs' '( local_only_gate chat e2e status )'
check 'A10 on: local serve is never refused' '( local_only_gate local serve )'

# gate notice route: the office chat takes it, Telegram is never reached.
TG_CALLED=0; NOTICE_TEXT=""; TASK_CH_TOKEN=""; TASK_CH_ACCESS=""
local_chat_notice() { NOTICE_TEXT="$2"; return 0; }
_task_human_send_allowed() { return 0; }
curl() { TG_CALLED=1; return 0; }
eval "$(sed -n '/^_task_send_owner() {/,/^}/p' src/task/notify.sh)"
eval "$(sed -n '/^_task_send_gate_owner() {/,/^}/p' src/task/notify.sh)"
_human_registry_active() { return 0; }
_task_send_owner '<b>DIVE-1</b> needs you &amp; now' '' 1 ''
if [[ "$TASK_SEND_DELIVERED" == 1 && "$TG_CALLED" == 0 && "$NOTICE_TEXT" == "DIVE-1 needs you & now" ]]; then ok_ 'A11 on: owner send goes to the office chat as plain text, no Telegram call'
else bad_ 'A11 owner send' "delivered=$TASK_SEND_DELIVERED tg=$TG_CALLED text=$NOTICE_TEXT"; fi
NOTICE_TEXT=""
_task_send_gate_owner 'gate text' '' 1 '' ''
if [[ "$TASK_SEND_DELIVERED" == 1 && "$TG_CALLED" == 0 && "$NOTICE_TEXT" == "gate text" && "$TASK_SEND_TARGETS" == office-chat ]]; then ok_ 'A12 on: gate send (human registry on) goes to the office chat'
else bad_ 'A12 gate send' "delivered=$TASK_SEND_DELIVERED tg=$TG_CALLED text=$NOTICE_TEXT targets=${TASK_SEND_TARGETS:-}"; fi
local_chat_notice() { return 1; }
_task_send_owner 'x' '' 1 '' 2>"$TMPD/a13.err"
if [[ "$TASK_SEND_DELIVERED" == 0 && "$TASK_SEND_FAILED" == 1 && "$TG_CALLED" == 0 ]] && grep -q "office chat did not take" "$TMPD/a13.err"; then ok_ 'A13 on: a notice the chat refused is a failed send, never a Telegram fallback'
else bad_ 'A13 refused notice' "delivered=$TASK_SEND_DELIVERED failed=$TASK_SEND_FAILED tg=$TG_CALLED"; fi
rm -f "$FIVE_LOCAL_ONLY_FILE"
unset -f curl
source src/cmd_local_chat.sh   # the real local_chat_notice back

unit=$(FIVEDIVE_CONNECTORD_ENV=/etc/5dive/connectord.env _lc_unit_text /usr/local/bin/bun 192.0.2.10 8443 8480)
check 'A14 unit runs as the dedicated user, never root' 'grep -qx "User=5dive-chat" <<<"$unit"'
check 'A15 unit hands the token in as a credential' 'grep -qx "LoadCredential=token:/etc/5dive/connectord.env" <<<"$unit"'
check 'A16 unit is sandboxed (NoNewPrivileges, ProtectSystem=strict)' 'grep -qx "NoNewPrivileges=yes" <<<"$unit" && grep -qx "ProtectSystem=strict" <<<"$unit"'
check 'A16b DIVE-7598: the unit also copies token, cert and key into its own 0700 runtime folder (credentials folder not visible in a container)' 'grep -qx "RuntimeDirectory=5dive-local-chat" <<<"$unit" && grep -qx "RuntimeDirectoryMode=0700" <<<"$unit" && [[ "$(grep -c "^ExecStartPre=-+/usr/bin/install -m 0400 -o 5dive-chat -g 5dive-chat .* %t/5dive-local-chat/\(token\|cert\|key\)$" <<<"$unit")" == 3 ]] && grep -qx "LoadCredential=key:/etc/5dive/local-chat/key.pem" <<<"$unit"'
check 'A17 build.sh bundles both modules' 'grep -qx "  src/cmd_local_chat.sh" build.sh && grep -qx "  src/cmd_local_chat_server.sh" build.sh'
check 'A18 main dispatches `local`' 'grep -q "cmd_local \"\$@\"" src/main.sh'
check 'A19 local-only on starts it; off KEEPS it running (DIVE-7598)' 'grep -q "_lo_record \"local-chat\"" src/cmd_local_only.sh && grep -q "local-chat) chat_kept=1" src/cmd_local_only.sh && ! grep -q "local-chat) ( _lc_serve_stop )" src/cmd_local_only.sh'

# ── C. DIVE-7566: `local serve` as the CLI runs it (set -euo pipefail) ────────
# The DIVE-7560 proof: a never-linked box could not start the chat (no
# connectord.env), and the first `local serve` died with rc 2 (a sed on the
# config file that is not there yet, under pipefail). Root, systemd and the
# server user are stubs; the files land under FIVE_LOCAL_CHAT_ROOT.
export FIVE_LOCAL_CHAT_ROOT="$TMPD/root"
mkdir -p "$TMPD/root/etc/systemd/system"
serve_() {   # a fresh `local serve`, errexit and pipefail on, as bin/5dive runs
  ( set -euo pipefail
    require_root() { :; }; getent() { return 0; }; systemctl() { return 0; }
    _lc_bun() { printf /usr/local/bin/bun; }; _lc_agents_write() { :; }
    _lc_serve "$@" )
}
out=$( (set -euo pipefail; _lc_conf_get LAN_ADDR; echo "rc=$?") 2>&1 )
check 'C1 reading the config before it exists is empty, not an exit' '[[ "$out" == "rc=0" ]]'
out=$(serve_ --addr=192.0.2.10 2>&1); r=$?
TOKF="$TMPD/root/etc/5dive/local-chat/token.env"
if (( r == 0 )) && grep -q "Office chat is ON: https://192.0.2.10:8443" <<<"$out"; then ok_ 'C2 first `local serve` on a never-linked box starts (no connectord.env, no config yet)'
else bad_ 'C2 first serve' "rc=$r $out"; fi
check 'C3 a token is minted for the office chat, root-only, 64 hex' '[[ "$(stat -c %a "$TOKF")" == 600 ]] && grep -qE "^CONNECTORD_TOKEN=[0-9a-f]{64}$" "$TOKF"'
check 'C4 the unit loads the minted token, and connectord.env is NOT written' 'grep -qx "LoadCredential=token:$TOKF" "$TMPD/root/etc/systemd/system/5dive-local-chat.service" && [[ ! -e "$FIVEDIVE_CONNECTORD_ENV" ]]'
check 'C5 the config names the token file and the agents rail points at the office chat' 'grep -qx "TOKEN_FILE=$TOKF" "$(_lc_conf)" && [[ "$(five_api_base)" == http://127.0.0.1:8480 ]]'
T1=$(cat "$TOKF"); serve_ >/dev/null 2>&1; r=$?
check 'C6 a second serve (no flags: address from the config) keeps the same token' '(( r == 0 )) && [[ "$(cat "$TOKF")" == "$T1" ]]'
# The root rail picks the token by where it is sending.
check 'C7 rail → office chat (loopback base) uses the minted token' '[[ "$(_dash_relay_token)" == "${T1#CONNECTORD_TOKEN=}" ]]'
printf 'https://api.5dive.com\n' >"$FIVE_API_BASE_FILE"
check 'C8 rail → api.5dive.com never gets the minted token' '[[ -z "$(_dash_relay_token)" ]]'
printf 'CONNECTORD_TOKEN=linked-tok\n' >"$TMPD/connectord.env"
check 'C9 a linked box: api.5dive.com gets the box token' '[[ "$(FIVEDIVE_CONNECTORD_ENV=$TMPD/connectord.env _dash_relay_token)" == linked-tok ]]'
out=$(FIVEDIVE_CONNECTORD_ENV="$TMPD/connectord.env" serve_ 2>&1); r=$?
check 'C10 a linked box: serve uses the box token, the office chat and the rail agree' '(( r == 0 )) && grep -qx "LoadCredential=token:$TMPD/connectord.env" "$TMPD/root/etc/systemd/system/5dive-local-chat.service" && [[ "$(FIVEDIVE_CONNECTORD_ENV=$TMPD/connectord.env _dash_relay_token)" == linked-tok ]]'
serve_ >/dev/null 2>&1   # back to the never-linked shape for B
rm -f "$FIVE_API_BASE_FILE"

# ── B. live server ───────────────────────────────────────────────────────────
BUN=$(command -v bun || echo /usr/local/bin/bun)
if [[ ! -x "$BUN" ]]; then bad_ 'B0 bun present' "no bun"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
_local_chat_server_ts >"$TMPD/server.ts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=t" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" >/dev/null 2>&1
printf 'CONNECTORD_TOKEN="boxtok-123"\n' >"$TMPD/connectord.env"
printf '["alice","bob"]\n' >"$TMPD/agents.json"
LAN=$((20000 + RANDOM % 20000)); LOOP=$((LAN + 1))
export LC_STATE="$TMPD/root/var/lib/5dive-local-chat" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$LAN LC_LOOP_PORT=$LOOP \
  LC_CERT="$TMPD/cert.pem" LC_KEY="$TMPD/key.pem" LC_TOKEN_FILE="$TMPD/connectord.env" \
  LC_AGENTS_FILE="$TMPD/agents.json" LC_UPLOADS="/home/claude/chat-uploads"
"$BUN" "$TMPD/server.ts" serve >"$TMPD/server.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP/" && break; sleep 0.1; done

B="http://127.0.0.1:$LOOP"; W="https://127.0.0.1:$LAN"; JAR="$TMPD/jar"
box(){ curl -sS -H "Authorization: Bearer boxtok-123" "$@"; }
web(){ curl -sSk -b "$JAR" -c "$JAR" -H 'x-local-chat: 1' "$@"; }
code(){ curl -sk -o /dev/null -w '%{http_code}' "$@"; }

check 'B1 the page is served on the office listener' '[[ "$(curl -sk "$W/" | grep -c "Connect this device")" -ge 1 ]]'
check 'B2 the office listener is TLS (plain http refused)' '! curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$LAN/api/agents"'
check 'B3 browser API without a device → 401' '[[ "$(code "$W/api/agents")" == 401 ]]'
check 'B4 box side without the token → 401' '[[ "$(code "$B/server/messages/pending?agent=alice")" == 401 ]]'
check 'B5 box side with a wrong token → 401' '[[ "$(code -H "Authorization: Bearer nope" "$B/server/messages/pending?agent=alice")" == 401 ]]'
check 'B6 box endpoints are not on the office listener' '[[ "$(code -H "Authorization: Bearer boxtok-123" "$W/server/messages/pending?agent=alice")" == 401 ]]'

# pairing: one-time code through the admin path, the way `local pair` does it.
CODE=ABCD2345; HASH=$(printf '%s' "$CODE" | sha256sum | cut -d' ' -f1)
"$BUN" "$TMPD/server.ts" admin pair-add "$HASH" $(( $(date +%s) + 900 )) >/dev/null
check 'B7 a wrong code → 403' '[[ "$(code -H "x-local-chat: 1" -H "content-type: application/json" -d "{\"code\":\"ZZZZ9999\"}" "$W/api/pair")" == 403 ]]'
check 'B8 a POST without the custom header → 403 (cross-site guard)' '[[ "$(code -H "content-type: application/json" -d "{\"code\":\"ABCD-2345\"}" "$W/api/pair")" == 403 ]]'
r=$(web -H 'content-type: application/json' -d '{"code":"abcd-2345","name":"phone"}' "$W/api/pair")
check 'B9 the right code (any case, with dash) pairs and sets an HttpOnly cookie' '[[ "$(jq -r .ok <<<"$r")" == true ]] && grep -q "#HttpOnly_127.0.0.1" "$JAR"'
check 'B10 the code works once' '[[ "$(code -H "x-local-chat: 1" -H "content-type: application/json" -d "{\"code\":\"ABCD2345\"}" "$W/api/pair")" == 403 ]]'
check 'B11 the paired device lists the agents' '[[ "$(web "$W/api/agents" | jq -c "[.agents[].name]")" == "[\"alice\",\"bob\"]" ]]'

# DIVE-7566: the `local pair` VERB itself (it took SIGPIPE, rc 141, on every
# run; the arms above call the server's admin op directly and never ran it).
# Under errexit + pipefail as bin/5dive runs it, against this live server.
mkdir -p "$(_lc_lib)"; cp "$TMPD/server.ts" "$(_lc_lib)/server.ts"
printf 'LAN_ADDR=127.0.0.1\nLAN_PORT=%s\nLOOP_PORT=%s\n' "$LAN" "$LOOP" >"$(_lc_conf)"
cp "$TMPD/cert.pem" "$(_lc_etc)/cert.pem"
pair_() { ( set -euo pipefail; require_root() { :; }; runuser() { shift 3; "$@"; }; _lc_bun() { printf '%s' "$BUN"; }; cmd_local pair ) ; }
out=$(pair_ 2>&1); r=$?
PCODE=$(grep -oE 'Type this code:  [A-Z0-9]{4}-[A-Z0-9]{4}' <<<"$out" | awk '{print $NF}')
if (( r == 0 )) && [[ "$PCODE" =~ ^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{4}$ ]] && grep -q "$(_lc_fingerprint)" <<<"$out"; then
  ok_ "B11a \`local pair\` runs (rc 0) and prints a code and the cert fingerprint"
else bad_ 'B11a local pair verb' "rc=$r $out"; fi
r=$(curl -sSk -c "$TMPD/jar2" -H 'x-local-chat: 1' -H 'content-type: application/json' -d "{\"code\":\"$PCODE\",\"name\":\"laptop\"}" "$W/api/pair")
check 'B11b the printed code pairs a device with the office chat' '[[ "$(jq -r .ok <<<"$r")" == true ]]'
out=$(JSON_MODE=1 pair_ 2>&1); r=$?
check 'B11c `local pair --json` runs too' '(( r == 0 )) && [[ "$(jq -r ".data.code | test(\"^[A-Z0-9]{4}-[A-Z0-9]{4}$\")" <<<"$out")" == true ]]'

# inbound: browser → box pending (the same shape the API returns).
web -H 'content-type: application/json' -d '{"agent":"alice","text":"hello alice"}' "$W/api/messages" >/dev/null
p=$(box "$B/server/messages/pending?agent=alice")
check 'B12 pending carries the message in the API shape' '[[ "$(jq -c ".pending[0] | {text,from,chat_id}" <<<"$p")" == "{\"text\":\"hello alice\",\"from\":\"dashboard\",\"chat_id\":\"alice\"}" ]]'
check 'B13 pending is per agent (bob sees nothing)' '[[ "$(box "$B/server/messages/pending?agent=bob" | jq ".pending | length")" == 0 ]]'
ID=$(jq '.pending[0].id' <<<"$p")
check 'B14 ack takes it' '[[ "$(box -H "content-type: application/json" -d "{\"agent\":\"alice\",\"ids\":[$ID]}" "$B/server/messages/pending/ack" | jq .acked)" == 1 ]]'
check 'B15 an acked message is not offered again' '[[ "$(box "$B/server/messages/pending?agent=alice" | jq ".pending | length")" == 0 ]]'
check 'B16 one agent cannot ack another agent'"'"'s message' '[[ "$(box -H "content-type: application/json" -d "{\"agent\":\"bob\",\"ids\":[$ID]}" "$B/server/messages/pending/ack" | jq .acked)" == 0 ]]'

# long poll: a held pending returns as soon as the browser posts.
t0=$(date +%s%N)
( box "$B/server/messages/pending?agent=bob&wait=10" >"$TMPD/lp.json" ) & LP=$!
sleep 0.5
web -H 'content-type: application/json' -d '{"agent":"bob","text":"wake up"}' "$W/api/messages" >/dev/null
wait "$LP"; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if [[ "$(jq -r '.pending[0].text' "$TMPD/lp.json")" == "wake up" ]] && (( ms < 5000 )); then ok_ "B17 long poll wakes on a new message (${ms} ms, wait was 10 s)"
else bad_ 'B17 long poll' "ms=$ms $(cat "$TMPD/lp.json")"; fi

# outbound: event with a question and a file; status; e2e refused.
printf 'report bytes' >"$TMPD/report.txt"
box -H 'content-type: application/json' -d "{\"agent\":\"alice\",\"body\":\"pick one\",\"metadata\":{\"chat_id\":\"alice\",\"files\":[\"$TMPD/report.txt\"],\"question\":{\"id\":\"q1\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\",\"description\":\"stop\"}]}}}" "$B/server/messages/event" >/dev/null
m=$(web "$W/api/messages?agent=alice" | jq -c '.messages[-1]')
check 'B18 the reply reaches the page with its question buttons' '[[ "$(jq -c "[.text, (.meta.question.options | map(.label))]" <<<"$m")" == "[\"pick one\",[\"Yes\",\"No\"]]" ]]'
FP=$(jq -r '.meta.files[0].path' <<<"$m")
check 'B19 the reply file downloads from the page' '[[ "$(web "$W/api/files?path=$(jq -rn --arg p "$FP" "\$p|@uri")")" == "report bytes" ]]'
check 'B20 an e2e envelope is refused (409), never stored' '[[ "$(code -H "Authorization: Bearer boxtok-123" -H "content-type: application/json" -d "{\"agent\":\"alice\",\"body\":\"x\",\"metadata\":{\"chat_id\":\"alice\",\"e2e\":{\"v\":1}}}" "$B/server/messages/event")" == 409 ]]'
box -H 'content-type: application/json' -d '{"agent":"bob","chat_id":"bob","active":true,"label":"reading the contract"}' "$B/server/messages/status" >/dev/null
check 'B21 the live status line reaches the page' '[[ "$(web "$W/api/messages?agent=bob" | jq -r .status.label)" == "reading the contract" ]]'

# files both ways.
up=$(web -H 'content-type: application/octet-stream' --data-binary 'brief pdf' "$W/api/files?agent=alice&name=brief.pdf")
UP=$(jq -r .path <<<"$up")
check 'B22 an upload lands under the seat'"'"'s chat-uploads path (what the rail fetch accepts)' '[[ "$UP" == /home/claude/chat-uploads/alice/*-brief.pdf ]]'
web -H 'content-type: application/json' -d "{\"agent\":\"alice\",\"text\":\"see file\",\"files\":[\"$UP\"]}" "$W/api/messages" >/dev/null
check 'B23 pending names the upload as image_path' '[[ "$(box "$B/server/messages/pending?agent=alice" | jq -r ".pending[-1].image_path")" == "$UP" ]]'
check 'B24 the box fetches the upload bytes' '[[ "$(box "$B/server/selfhost/files?path=$(jq -rn --arg p "$UP" "\$p|@uri")")" == "brief pdf" ]]'
check 'B25 the box puts a reply file' '[[ "$(box -H "content-type: application/octet-stream" --data-binary "out bytes" "$B/server/selfhost/files?path=%2Fhome%2Fclaude%2Fchat-downloads%2Fx.bin" | jq .size)" == 9 ]]'
check 'B26 heard answers ok (no hands-free on the office page)' '[[ "$(box -H "content-type: application/json" -d "{}" "$B/server/selfhost/heard" | jq .ok)" == true ]]'

# notices: loopback, no token; they show in the notices thread.
check 'B27 a notice is taken on loopback without the token' '[[ "$(curl -s -H "content-type: application/json" -d "{\"text\":\"DIVE-9 needs your call\"}" "$B/local/notice" | jq .ok)" == true ]]'
check 'B28 the notices thread appears in the agent list' '[[ "$(web "$W/api/agents" | jq -r "[.agents[].name] | index(\"5dive\") != null")" == true ]]'
check 'B29 nobody can message the notices thread' '[[ "$(code -b "$JAR" -H "x-local-chat: 1" -H "content-type: application/json" -d "{\"agent\":\"5dive\",\"text\":\"x\"}" "$W/api/messages")" == 400 ]]'
check 'B30 notice endpoint is not on the office listener' '[[ "$(code -H "content-type: application/json" -d "{\"text\":\"x\"}" "$W/local/notice")" == 403 || "$(code -H "x-local-chat: 1" -H "content-type: application/json" -d "{\"text\":\"x\"}" "$W/local/notice")" == 401 ]]'

# revoke: the cookie stops working at once.
DEV=$("$BUN" "$TMPD/server.ts" admin devices-ls | jq -r '.[0].id')
check 'B31 devices-ls shows the paired device' '[[ "$("$BUN" "$TMPD/server.ts" admin devices-ls | jq -r ".[0].name")" == phone ]]'
"$BUN" "$TMPD/server.ts" admin devices-revoke "$DEV" >/dev/null
check 'B32 a revoked device gets 401' '[[ "$(code -b "$JAR" "$W/api/agents")" == 401 ]]'
check 'B33 revoking twice says no such active device (rc 3)' '! "$BUN" "$TMPD/server.ts" admin devices-revoke "$DEV" >/dev/null'

# DIVE-7598: CREDENTIALS_DIRECTORY set but absent (systemd in a container), the
# files in RUNTIME_DIRECTORY: the server still serves TLS with the box token.
RUND="$TMPD/run-lc"; mkdir -p "$RUND"
cp "$TMPD/cert.pem" "$RUND/cert"; cp "$TMPD/key.pem" "$RUND/key"; cp "$TMPD/connectord.env" "$RUND/token"
LAN2=$((LAN + 2)); LOOP2=$((LAN + 3))
env -u LC_CERT -u LC_KEY -u LC_TOKEN_FILE LC_STATE="$TMPD/state2" LC_LAN_PORT=$LAN2 LC_LOOP_PORT=$LOOP2 \
  CREDENTIALS_DIRECTORY="$TMPD/no-such-credentials" RUNTIME_DIRECTORY="$RUND" \
  "$BUN" "$TMPD/server.ts" serve >"$TMPD/server2.log" 2>&1 & SRV2=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP2/" && break; sleep 0.1; done
check 'B40 no visible credentials folder: the server serves TLS from its runtime folder' '[[ "$(curl -sk "https://127.0.0.1:$LAN2/" | grep -c "Connect this device")" -ge 1 ]]'
check 'B41 ... and reads the box token from there' '[[ "$(code -H "Authorization: Bearer boxtok-123" "http://127.0.0.1:$LOOP2/server/messages/pending?agent=alice")" != 401 && "$(code "http://127.0.0.1:$LOOP2/server/messages/pending?agent=alice")" == 401 ]]'
kill "$SRV2" 2>/dev/null; wait "$SRV2" 2>/dev/null

# ── D. DIVE-8565: the firm's own name (--domain, --cert/--key, port 443) ─────
export FIVE_LOCAL_CHAT_ROOT="$TMPD/rootd"
mkdir -p "$TMPD/rootd/etc/systemd/system"
DCONF="$TMPD/rootd/etc/5dive/local-chat"
serve_d() {   # as serve_, plus `ss` stubbed: SS_OUT is what holds the port
  ( set -euo pipefail
    require_root() { :; }; getent() { return 0; }; systemctl() { return 0; }
    ss() { [[ -n "${SS_OUT:-}" ]] && printf '%s\n' "$SS_OUT"; return 0; }
    _lc_bun() { printf /usr/local/bin/bun; }; _lc_agents_write() { :; }
    _lc_serve "$@" )
}
pair_d() { ( set -euo pipefail; require_root() { :; }; _lc_admin() { :; }; _lc_pair "$@" ); }
# A firm's own authority and certificates it signed.
CA="$TMPD/ca"; mkdir -p "$CA"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=Firm CA" \
  -keyout "$CA/ca.key" -out "$CA/ca.pem" >/dev/null 2>&1
leaf() {   # leaf <name> <out-prefix> [<days>]
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" -keyout "$2.key" -out "$2.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\n' "$1" >"$2.ext"
  openssl x509 -req -in "$2.csr" -CA "$CA/ca.pem" -CAkey "$CA/ca.key" -CAcreateserial -days "${3:-30}" -extfile "$2.ext" -out "$2.leaf" >/dev/null 2>&1
  cat "$2.leaf" "$CA/ca.pem" >"$2.pem"   # the chain, as IT hands it over
}
leaf team.example.test "$CA/team"; leaf other.example.test "$CA/other"
# An already-expired one, signed with dates in the past (openssl 3.0 has no
# x509 -not_after; `openssl ca` takes -startdate/-enddate).
mkdir -p "$CA/db"; : >"$CA/db/index"; echo 01 >"$CA/db/serial"
printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s/db/index\nnew_certs_dir=%s/db\nserial=%s/db/serial\ndefault_md=sha256\npolicy=p\n[p]\ncommonName=supplied\n[x]\nsubjectAltName=DNS:team.example.test\n' "$CA" "$CA" "$CA" >"$CA/ca.cnf"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=team.example.test" -keyout "$CA/old.key" -out "$CA/old.csr" >/dev/null 2>&1
openssl ca -batch -config "$CA/ca.cnf" -extensions x -cert "$CA/ca.pem" -keyfile "$CA/ca.key" -in "$CA/old.csr" -out "$CA/old.pem" \
  -startdate 20200101000000Z -enddate 20200201000000Z -notext >/dev/null 2>&1

out=$(serve_d --addr=192.0.2.10 --domain=Team.Example.TEST. 2>&1); r=$?
check 'D1 --domain serves on the name, port 443 by default (the address is just https://<name>)' '(( r == 0 )) && grep -qx "Office chat is ON: https://team.example.test" <<<"$out" && grep -qx "LAN_PORT=443" "$DCONF/config" && grep -qx "DOMAIN=team.example.test" "$DCONF/config"'
check 'D2 ... and says IT points the name at the office address' 'grep -qF "Your IT points team.example.test at 192.0.2.10" <<<"$out"'
UNIT="$TMPD/rootd/etc/systemd/system/5dive-local-chat.service"
check 'D3 port 443: the never-root unit gets ONLY the bind capability, NoNewPrivileges kept' 'grep -qx "AmbientCapabilities=CAP_NET_BIND_SERVICE" "$UNIT" && grep -qx "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" "$UNIT" && grep -qx "NoNewPrivileges=yes" "$UNIT" && grep -qx "User=5dive-chat" "$UNIT" && grep -qx "LC_LAN_PORT=443" < <(grep -o "LC_LAN_PORT=[0-9]*" "$UNIT")'
check 'D4 no certificate given: a self-signed one names BOTH the domain and the office address' 'san=$(openssl x509 -in "$DCONF/cert.pem" -noout -ext subjectAltName) && grep -q "DNS:team.example.test" <<<"$san" && grep -q "IP Address:192.0.2.10" <<<"$san" && grep -qx "CERT=self" "$DCONF/config"'
out=$(pair_d 2>&1); r=$?
check 'D5 pair names https://team.example.test and still warns about the self-signed cert' '(( r == 0 )) && grep -qF "open:  https://team.example.test" <<<"$out" && grep -q "self-signed" <<<"$out"'
out=$(JSON_MODE=1 _lc_status 2>&1)
check 'D6 status --json: url, domain, self-signed' '[[ "$(jq -r ".data.url, .data.domain, .data.certificate" <<<"$out" | tr "\n" " ")" == "https://team.example.test team.example.test self-signed " ]]'

cp "$DCONF/cert.pem" "$TMPD/before.pem"
out=$(serve_d --domain=team.example.test --cert="$CA/other.pem" --key="$CA/other.key" 2>&1); r=$?
check 'D7 a certificate for another name is refused, nothing replaced' '(( r != 0 )) && grep -q "not for team.example.test" <<<"$out" && cmp -s "$TMPD/before.pem" "$DCONF/cert.pem"'
out=$(serve_d --domain=team.example.test --cert="$CA/team.pem" --key="$CA/other.key" 2>&1); r=$?
check 'D8 a key that is not the certificate'"'"'s is refused, nothing replaced' '(( r != 0 )) && grep -q "does not belong" <<<"$out" && cmp -s "$TMPD/before.pem" "$DCONF/cert.pem"'
if [[ -s "$CA/old.pem" ]]; then
  out=$(serve_d --domain=team.example.test --cert="$CA/old.pem" --key="$CA/old.key" 2>&1); r=$?
  check 'D9 an expired certificate is refused' '(( r != 0 )) && grep -q "expired" <<<"$out" && cmp -s "$TMPD/before.pem" "$DCONF/cert.pem"'
else bad_ 'D9 an expired certificate is refused' "could not make an expired cert with this openssl"; fi
out=$(serve_d --cert="$CA/team.pem" 2>&1); r=$?
check 'D10 --cert without --key is refused' '(( r != 0 )) && grep -q "together" <<<"$out"'
out=$(serve_d --domain=-bad..name 2>&1); r=$?
check 'D11 a malformed name is refused, the saved one kept' '(( r != 0 )) && grep -qx "DOMAIN=team.example.test" "$DCONF/config"'

out=$(serve_d --domain=team.example.test --cert="$CA/team.pem" --key="$CA/team.key" 2>&1); r=$?
check 'D12 the firm'"'"'s certificate is taken: the whole chain as given, key 0600, CERT=own' '(( r == 0 )) && cmp -s "$CA/team.pem" "$DCONF/cert.pem" && cmp -s "$CA/team.key" "$DCONF/key.pem" && [[ "$(stat -c %a "$DCONF/key.pem")" == 600 ]] && grep -qx "CERT=own" "$DCONF/config" && grep -q "Certificate: yours, valid until" <<<"$out"'
out=$(pair_d 2>&1)
check 'D13 pair with the firm'"'"'s certificate: no self-signed warning, just the address and the code' 'grep -qF "open:  https://team.example.test" <<<"$out" && ! grep -q "self-signed" <<<"$out" && grep -q "^2. Type this code" <<<"$out"'
serve_d >/dev/null 2>&1; r=$?
check 'D14 a later serve with no flags KEEPS the firm'"'"'s certificate (never swapped for a self-signed one)' '(( r == 0 )) && cmp -s "$CA/team.pem" "$DCONF/cert.pem" && grep -qx "CERT=own" "$DCONF/config"'
out=$(JSON_MODE=1 _lc_status 2>&1)
check 'D15 status --json says own, and when it runs out' '[[ "$(jq -r .data.certificate <<<"$out")" == own && -n "$(jq -r .data.certificateUntil <<<"$out")" ]]'
out=$(SS_OUT='LISTEN 0 4096 *:443 *:* users:(("caddy",pid=20147,fd=3))' serve_d 2>&1); r=$?
check 'D16 port 443 held by another program: refused, names it, nothing started' '(( r != 0 )) && grep -q "port 443 is already used by caddy" <<<"$out"'
out=$(serve_d --domain=none 2>&1); r=$?
check 'D17 --domain=none goes back to the office address; the firm cert (no IP in it) is replaced by a self-signed one' '(( r == 0 )) && grep -qx "DOMAIN=" "$DCONF/config" && grep -qx "Office chat is ON: https://192.0.2.10" <<<"$out" && grep -qx "CERT=self" "$DCONF/config" && san=$(openssl x509 -in "$DCONF/cert.pem" -noout -ext subjectAltName) && grep -q "IP Address:192.0.2.10" <<<"$san"'
out=$(serve_d --domain=team.example.test --port=8443 2>&1); r=$?
check 'D18 --port with --domain wins; above 1024 the unit gets no capability' '(( r == 0 )) && grep -qx "Office chat is ON: https://team.example.test:8443" <<<"$out" && ! grep -q "CAP_NET_BIND_SERVICE" "$UNIT"'
out=$(serve_d --port=80 2>&1); r=$?
check 'D19 a low port other than 443 is still refused' '(( r != 0 )) && grep -q "443 or 1024-65535" <<<"$out"'

# ── E. DIVE-8611: a renewed certificate is taken; a warning 14 days before ────
# The firm's files as certbot keeps them: live/ names are links that move to
# each new file in archive/. The source checks want root's files; here the
# test user's (the seam only counts under FIVE_LOCAL_CHAT_ROOT).
export LC_CERT_SRC_UID; LC_CERT_SRC_UID=$(id -u)
umask 022   # as root's files are: a 0002 test shell would make every source group-writable (refused, E12)
LE="$TMPD/rootd/etc/letsencrypt"; mkdir -p "$LE/renewal-hooks" "$LE/archive/team" "$LE/live/team"
cp "$CA/team.pem" "$LE/archive/team/fullchain1.pem"; cp "$CA/team.key" "$LE/archive/team/privkey1.pem"; chmod 0600 "$LE/archive/team/privkey1.pem"
ln -sfn ../../archive/team/fullchain1.pem "$LE/live/team/fullchain.pem"; ln -sfn ../../archive/team/privkey1.pem "$LE/live/team/privkey.pem"
renew() {   # renew <prefix> <n>: certbot writes the nth files and moves the links
  cp "$1.pem" "$LE/archive/team/fullchain$2.pem"; cp "$1.key" "$LE/archive/team/privkey$2.pem"; chmod 0600 "$LE/archive/team/privkey$2.pem"
  ln -sfn "../../archive/team/fullchain$2.pem" "$LE/live/team/fullchain.pem"; ln -sfn "../../archive/team/privkey$2.pem" "$LE/live/team/privkey.pem"
}
SYSLOG="$TMPD/systemctl.log"
sync_d() { ( set -euo pipefail; require_root() { :; }; systemctl() { printf '%s\n' "$*" >>"$SYSLOG"; return 0; }; _lc_cert_sync ) }
TIMER="$TMPD/rootd/etc/systemd/system/5dive-local-chat-cert.timer"; CSVC="$TMPD/rootd/etc/systemd/system/5dive-local-chat-cert.service"
HOOK="$LE/renewal-hooks/deploy/5dive-office-chat"; MOTD="$TMPD/rootd/etc/motd.d/5dive-office-chat-certificate"
mkdir -p "$TMPD/rel"
out=$(cd "$LE/live" && serve_d --domain=team.example.test --port=8443 --cert=team/fullchain.pem --key=team/privkey.pem 2>&1); r=$?
check 'E1 serve keeps WHERE the firm'"'"'s files are: absolute, the certbot link itself (not the file it points at today)' '(( r == 0 )) && grep -qx "CERT_SRC=$LE/live/team/fullchain.pem" "$DCONF/config" && grep -qx "KEY_SRC=$LE/live/team/privkey.pem" "$DCONF/config" && grep -qx "CERT=own" "$DCONF/config"'
check 'E2 ... and says a renewal there is taken by itself' 'grep -qF "When IT renews it at $LE/live/team/fullchain.pem, the chat takes the new one by itself" <<<"$out"'
check 'E3 a daily timer runs `local _cert-sync` (oneshot, catches up after a power-off)' 'grep -qx "ExecStart=/usr/local/bin/5dive local _cert-sync" "$CSVC" && grep -qx "Type=oneshot" "$CSVC" && grep -qx "OnCalendar=daily" "$TIMER" && grep -qx "Persistent=true" "$TIMER"'
check 'E4 certbot is on the box: its deploy hook runs the same sync right after a renewal' '[[ -x "$HOOK" ]] && grep -qx "exec /usr/local/bin/5dive local _cert-sync" "$HOOK"'
serve_d >/dev/null 2>&1; r=$?
check 'E5 a later serve with no flags keeps the source paths' '(( r == 0 )) && grep -qx "CERT_SRC=$LE/live/team/fullchain.pem" "$DCONF/config" && grep -qx "KEY_SRC=$LE/live/team/privkey.pem" "$DCONF/config"'
: >"$SYSLOG"; out=$(sync_d 2>&1); r=$?
check 'E6 sync with nothing renewed: no copy, no restart, no warning' '(( r == 0 )) && ! grep -q "took" <<<"$out" && ! grep -q try-restart "$SYSLOG" && cmp -s "$CA/team.pem" "$DCONF/cert.pem" && [[ ! -e "$MOTD" ]]'

leaf team.example.test "$CA/team2" 60; renew "$CA/team2" 2
: >"$SYSLOG"; out=$(sync_d 2>&1); r=$?
check 'E7 RENEWED: sync takes the new pair (chain + key, key 0600) and restarts the chat on it' '(( r == 0 )) && grep -q "took the renewed certificate from $LE/live/team/fullchain.pem" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem" && cmp -s "$CA/team2.key" "$DCONF/key.pem" && [[ "$(stat -c %a "$DCONF/key.pem")" == 600 ]] && grep -qx "try-restart 5dive-local-chat.service" "$SYSLOG"'
check 'E8 ... no half-copies left behind' '[[ ! -e "$DCONF/.cert.new" && ! -e "$DCONF/.key.new" ]]'

leaf other.example.test "$CA/wrong" 60; renew "$CA/wrong" 3
: >"$SYSLOG"; out=$(sync_d 2>&1); r=$?
check 'E9 a "renewal" for another name is NOT taken: the old one stays, the reason is said, no restart' '(( r == 0 )) && grep -q "was NOT taken" <<<"$out" && grep -q "not for team.example.test" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem" && ! grep -q try-restart "$SYSLOG"'
cp "$CA/team.pem" "$LE/archive/team/fullchain4.pem"; cp "$CA/team2.key" "$LE/archive/team/privkey4.pem"
ln -sfn ../../archive/team/fullchain4.pem "$LE/live/team/fullchain.pem"; ln -sfn ../../archive/team/privkey4.pem "$LE/live/team/privkey.pem"
out=$(sync_d 2>&1); r=$?
check 'E10 a certificate whose key is not the new key (caught mid-renewal) is NOT taken' '(( r == 0 )) && grep -q "does not belong" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem" && cmp -s "$CA/team2.key" "$DCONF/key.pem"'
if [[ -s "$CA/old.pem" ]]; then
  renew "$CA/old" 5; out=$(sync_d 2>&1)
  check 'E11 an expired "renewal" is NOT taken' 'grep -q "expired" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem"'
else bad_ 'E11 an expired renewal is not taken' "no expired cert with this openssl"; fi
leaf team.example.test "$CA/team3" 60; renew "$CA/team3" 6; chmod 0666 "$LE/archive/team/fullchain6.pem"
out=$(sync_d 2>&1)
check 'E12 a file another user could change is NOT followed (else they could put their certificate on the firm'"'"'s name)' 'grep -q "can be changed by a user other than root" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem"'
chmod 0644 "$LE/archive/team/fullchain6.pem"; out=$(LC_CERT_SRC_UID=12345 sync_d 2>&1)
check 'E13 a file not owned by root is NOT followed' 'grep -q "can be changed by a user other than root" <<<"$out" && cmp -s "$CA/team2.pem" "$DCONF/cert.pem"'
out=$(sync_d 2>&1)
check 'E14 ... and once it is root'"'"'s and locked, it is taken' 'grep -q "took the renewed" <<<"$out" && cmp -s "$CA/team3.pem" "$DCONF/cert.pem"'

# 14 days before: the server's login message, status, the panel.
leaf team.example.test "$CA/soon" 10; renew "$CA/soon" 7
out=$(sync_d 2>&1)
check 'E15 runs out in under 14 days: sync warns in plain words, naming the day and where IT renews it' 'grep -q "took the renewed" <<<"$out" && grep -qE "certificate runs out in [0-9]+ days, on [0-9]{4}-[0-9]{2}-[0-9]{2}\. Ask your IT to renew it at $LE/live/team/fullchain.pem: the chat takes the new one by itself" <<<"$out"'
check 'E16 ... and the same sentence is the server'"'"'s login message (pam_motd reads /etc/motd.d)' 'grep -q "runs out in" "$MOTD" && [[ "$(stat -c %a "$MOTD")" == 644 ]]'
out=$(JSON_MODE=1 _lc_status 2>&1)
check 'E17 status --json: days left, where renewals come from, the warning' '[[ "$(jq -r .data.certificateDaysLeft <<<"$out")" -le 10 && "$(jq -r .data.certificateRenewsFrom <<<"$out")" == "$LE/live/team/fullchain.pem" ]] && [[ "$(jq -r .data.certificateWarning <<<"$out")" == *"runs out in"* ]]'
status_on() { ( systemctl() { [[ "$1" == is-active ]] && printf 'active\n'; return 0; }; _lc_status ) }
out=$(status_on 2>&1)
check 'E18 status (text): renewals followed from where, and the warning' 'grep -qF "Renewals: taken from $LE/live/team/fullchain.pem by themselves" <<<"$out" && grep -q "runs out in" <<<"$out"'
out=$(_lc_cert_json)
check 'E19 the panel gets {mine, until, daysLeft, renewsBySelf, warning}' 'jq -e ".mine == true and .renewsBySelf == true and (.daysLeft <= 10) and (.until | test(\"^[0-9]{4}-\")) and (.warning | test(\"runs out in\"))" <<<"$out"'
leaf team.example.test "$CA/fresh" 80; renew "$CA/fresh" 8
out=$(sync_d 2>&1)
check 'E20 renewed in time: the login message and the warning are gone' 'grep -q "took the renewed" <<<"$out" && ! grep -q "runs out in" <<<"$out" && [[ ! -e "$MOTD" ]] && [[ "$(jq -r .warning <<<"$(_lc_cert_json)")" == "" ]]'
cp "$CA/old.pem" "$DCONF/cert.pem"
check 'E21 already run out: says so, and that phones refuse the chat until IT renews it' '[[ "$(_lc_cert_warning)" == *"ran out on 2020-02-01. Phones and laptops refuse the chat until your IT renews it at"* ]]'
sed -i "/^CERT_SRC=/d;/^KEY_SRC=/d" "$DCONF/config"
check 'E22 a box set up before this (no source kept): the warning says what IT runs' '[[ "$(_lc_cert_warning)" == *"runs: sudo 5dive local serve --cert=<file> --key=<file>"* ]]'
check 'E23 ... and status says renewals are not followed yet' '[[ "$(status_on)" == *"Renewals: not followed"* ]]'
cp "$CA/fresh.pem" "$DCONF/cert.pem"; cp "$CA/fresh.key" "$DCONF/key.pem"
_lc_conf_set CERT self
check 'E24 a self-signed certificate never warns (it is not IT'"'"'s to renew)' '[[ -z "$(_lc_cert_warning)" ]] && [[ "$(jq -r .mine <<<"$(_lc_cert_json)")" == false ]]'
out=$(sync_d 2>&1); r=$?
check 'E25 sync on a self-signed chat does nothing' '(( r == 0 )) && ! grep -q took <<<"$out" && cmp -s "$CA/fresh.pem" "$DCONF/cert.pem"'
rm -f "$TIMER" "$CSVC"
( set -euo pipefail; require_root() { :; }; systemctl() { return 0; }; _lc_bun() { printf /usr/local/bin/bun; }; _lc_restage ) >/dev/null 2>&1
check 'E26 an update (local _restage) adds the daily check to a chat set up before it' '[[ -s "$TIMER" && -s "$CSVC" ]]'
printf 'x\n' >"$MOTD"
( set -euo pipefail; systemctl() { return 0; }; five_api_base_file() { printf '%s' "$TMPD/api-base"; }; _lc_serve_stop ) >/dev/null 2>&1
check 'E27 serve --stop removes the timer, the certbot hook and the login message' '[[ ! -e "$TIMER" && ! -e "$CSVC" && ! -e "$HOOK" && ! -e "$MOTD" ]]'
check 'E28 the panel page shows the warning above every tab, and a Certificate card in Settings' 'grep -q "id=\"cw\" class=\"cw\" hidden" src/cmd_local_chat_server.sh && grep -q "function certWarn" src/cmd_local_chat_server.sh && grep -q "<h3>Certificate</h3>" src/cmd_local_chat_server.sh'

# Live: the real server on the firm's certificate. A browser that trusts the
# firm's authority opens it BY NAME with no warning; any other name fails.
DP=$((LAN + 4)); DL=$((LAN + 5))
env -u LC_TOKEN_FILE LC_STATE="$TMPD/state3" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$DP LC_LOOP_PORT=$DL \
  LC_CERT="$CA/team.pem" LC_KEY="$CA/team.key" LC_TOKEN_FILE="$TMPD/connectord.env" \
  "$BUN" "$TMPD/server.ts" serve >"$TMPD/server3.log" 2>&1 & SRV3=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$DL/" && break; sleep 0.1; done
check 'D20 live: https://team.example.test verifies against the firm'"'"'s authority (no warning) and serves the page' '[[ "$(curl -s --cacert "$CA/ca.pem" --resolve "team.example.test:$DP:127.0.0.1" "https://team.example.test:$DP/" | grep -c "Connect this device")" -ge 1 ]]'
check 'D21 live: the same server under another name fails verification' '! curl -s -o /dev/null --cacert "$CA/ca.pem" --resolve "other.example.test:$DP:127.0.0.1" "https://other.example.test:$DP/"'
kill "$SRV3" 2>/dev/null; wait "$SRV3" 2>/dev/null

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
