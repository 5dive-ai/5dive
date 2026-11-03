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
check 'A6 the partner rail reads it' 'grep -q "^_partner_api_base() { five_api_base; }" src/cmd_partner.sh'

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

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
