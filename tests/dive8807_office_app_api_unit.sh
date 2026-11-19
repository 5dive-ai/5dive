#!/usr/bin/env bash
# DIVE-8807: the office server answers the 5dive app at the app's own paths
# (/api/proxy/*, src/cmd_local_chat_server.sh `_local_office_api_ts`).
#
#   M. migration: devices paired before people existed become one person each
#      and keep every agent they had.
#   P. people, invite links and agent grants: deny by default for a member, a
#      member with nothing granted sees no agent and gets 403 on another
#      agent's messages (the app's paths AND the lite page's), removing a
#      person signs out every device they have, a link works once.
#   A. the allowlist: anything not answered is a 404, writes need this origin.
#   C. the contract: every answered path matches the shape the app reads,
#      from tests/fixtures/dive8807-office-app-contract.json.
#
# The REAL server on bun, loopback only, a throwaway self-signed cert; driven
# with curl as the app in a browser would. Needs bun, openssl, curl, jq.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/office-app.XXXXXX")"
SRV_PID=""
PANEL_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "$PANEL_PID" ]] && kill "$PANEL_PID" 2>/dev/null; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT
for f in header.sh lib/error_codes.sh lib/output.sh cmd_local_chat_server.sh; do source "src/$f"; done
set +e

BUN=$(command -v bun || echo /usr/local/bin/bun)
if [[ ! -x "$BUN" ]]; then bad_ 'M0 bun present' "no bun"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
_local_chat_server_ts >"$TMPD/server.ts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=t" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" >/dev/null 2>&1
printf 'CONNECTORD_TOKEN="boxtok-123"\n' >"$TMPD/connectord.env"
printf '["alice","bob"]\n' >"$TMPD/agents.json"
STATE="$TMPD/state"; mkdir -p "$STATE"
UP="$TMPD/uploads"

# ── M. a box from before people: two devices in the old schema ───────────────
OLD_OWNER=ownerCookie0123456789abcdefABCDEF; OLD_CHAT=chatCookie0123456789abcdefABCDEFG
"$BUN" -e '
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
const h = (s) => createHash("sha256").update(s).digest("hex");
const db = new Database(process.argv[1] + "/chat.db", { create: true });
db.exec(`CREATE TABLE devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, cookie_hash TEXT NOT NULL UNIQUE,
  created INTEGER NOT NULL, last_seen INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, role TEXT NOT NULL DEFAULT "chat");
  CREATE TABLE pair_codes (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, role TEXT NOT NULL DEFAULT "chat", name TEXT NOT NULL DEFAULT "");`);
db.query("INSERT INTO devices VALUES (?, ?, ?, 1, 1, 0, ?)").run("aaaa0001", "Boss laptop", h(process.argv[2]), "owner");
db.query("INSERT INTO devices VALUES (?, ?, ?, 2, 2, 0, ?)").run("aaaa0002", "Front desk", h(process.argv[3]), "chat");
' "$STATE" "$OLD_OWNER" "$OLD_CHAT"

# A stand-in for the root panel door (src/cmd_local_panel.sh): one JSON line
# {argv, device}, then EOF; answers by verb and logs every call it took.
PANEL="$TMPD/panel.sock"
cat >"$TMPD/panel.ts" <<'PANEL_TS'
import { appendFileSync } from "node:fs";
const [sock, log] = process.argv.slice(2);
const A = (name: string) => ({ name, type: "claude", channels: "dashboard", createdAt: "2026-11-19T00:00:00Z", active: "active", enabled: "enabled" });
const gate = (id: number, ident: string, assignee: string) => ({ id, ident, title: "Ship it?", status: "blocked", priority: "high", assignee,
  created_by: "lead", created_at: "2026-11-19 00:00:00", need_type: "approval", ask: "Can " + assignee + " ship?" });
const answers: Record<string, (a: string[]) => unknown> = {
  team: () => [A("alice"), A("bob")],
  board: () => ({ tasks: [gate(1, "DIVE-1", "alice"), gate(2, "DIVE-2", "bob")], gates: [gate(1, "DIVE-1", "alice"), gate(2, "DIVE-2", "bob")] }),
  "gate-answer": (a) => ({ ident: a[1], value: a[2] }),
  settings: () => ({ accounts: [{ name: "office-ai", harness: "claude", baseUrl: "http://192.0.2.5:11434", model: "qwen" }], version: "0.140.0" }),
  secrets: () => ["DB_PASS"],
};
Bun.listen({ unix: sock, socket: {
  open(s) { (s as any).buf = ""; },
  data(s, d) { (s as any).buf += Buffer.from(d).toString(); },
  end(s) {
    const req = JSON.parse(((s as any).buf as string).split("\n")[0]);
    appendFileSync(log, JSON.stringify(req.argv) + "\n");
    const f = answers[req.argv[0]];
    s.write(JSON.stringify(f ? { ok: true, data: f(req.argv) } : { ok: false, error: "unknown verb" }));
    s.end();
  },
} });
PANEL_TS
"$BUN" "$TMPD/panel.ts" "$PANEL" "$TMPD/panel.log" >"$TMPD/panel.out" 2>&1 & PANEL_PID=$!
for _ in $(seq 1 50); do [[ -S "$PANEL" ]] && break; sleep 0.1; done

LAN=$((20000 + RANDOM % 20000)); LOOP=$((LAN + 1))
LC_STATE="$STATE" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$LAN LC_LOOP_PORT=$LOOP LC_CERT="$TMPD/cert.pem" LC_KEY="$TMPD/key.pem" \
  LC_TOKEN_FILE="$TMPD/connectord.env" LC_AGENTS_FILE="$TMPD/agents.json" LC_UPLOADS="$UP" LC_PANEL_SOCK="$PANEL" \
  "$BUN" "$TMPD/server.ts" serve >"$TMPD/server.log" 2>&1 & SRV_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP/" && break; sleep 0.1; done

B="http://127.0.0.1:$LOOP"; W="https://127.0.0.1:$LAN"; X="$W/api/proxy"
# as(<jar>) — a browser on one device: its cookie jar, same-origin writes.
as_(){ local j="$1"; shift; curl -sSk -b "$TMPD/$j" -c "$TMPD/$j" -H "origin: $W" -H 'content-type: application/json' "$@"; }
code_(){ local j="$1"; shift; curl -sk -o /dev/null -w '%{http_code}' -b "$TMPD/$j" -c "$TMPD/$j" -H "origin: $W" -H 'content-type: application/json' "$@"; }
box(){ curl -sS -H "Authorization: Bearer boxtok-123" -H 'content-type: application/json' "$@"; }
printf '127.0.0.1\tFALSE\t/\tTRUE\t0\tlc_dev\t%s\n' "$OLD_OWNER" >"$TMPD/boss"
printf '127.0.0.1\tFALSE\t/\tTRUE\t0\tlc_dev\t%s\n' "$OLD_CHAT" >"$TMPD/desk"

r=$(as_ boss "$X/me")
check 'M1 an owner device from before people is an owner person with its name' '[[ "$(jq -c "[.role,.name,.office]" <<<"$r")" == "[\"owner\",\"Boss laptop\",true]" ]]'
r=$(as_ desk "$X/me")
check 'M2 a chat device from before people is a member' '[[ "$(jq -r .role <<<"$r")" == member ]]'
check 'M3 the migrated member keeps every agent (no lost chat on upgrade)' '[[ "$(as_ desk "$X/server/conversations" | jq -c "[.conversations[].dmAgent]")" == "[\"alice\",\"bob\"]" ]]'
check 'M4 the panel still treats the old owner device as an owner (role from the person)' '[[ "$(as_ boss -H "x-local-chat: 1" "$W/api/agents" | jq -r .role)" == owner ]]'

# ── P. people, invite links, grants ──────────────────────────────────────────
r=$(as_ boss -X POST -d '{"email":"Mia","agents":[]}' "$X/team/invite")
LINK=$(jq -r .link <<<"$r"); TOKEN=${LINK#*#}
check 'P1 Team → Invite gives a one-time join link on this office (43-char token, as the app reads it)' '[[ "$LINK" == "$W/join#"* && "$TOKEN" =~ ^[A-Za-z0-9_-]{43}$ && "$(jq -r .emailed <<<"$r")" == false ]]'
check 'P2 the owner sees the invite as "invited" until it is used' '[[ "$(as_ boss "$X/team" | jq -r "[.members[] | select(.state == \"invited\") | .name] | join(\",\")")" == Mia ]]'
check 'P3 the join page is served at /join' '[[ "$(curl -sk "$W/join" | grep -c "/api/proxy/team/accept")" -ge 1 ]]'
r=$(as_ mia1 -X POST -d "{\"token\":\"$TOKEN\"}" "$X/team/accept")
check 'P4 the link signs this device in (HttpOnly cookie) as the invited person' '[[ "$(jq -r .ok <<<"$r")" == true ]] && grep -q "#HttpOnly_127.0.0.1" "$TMPD/mia1" && [[ "$(as_ mia1 "$X/me" | jq -c "[.name,.role]")" == "[\"Mia\",\"member\"]" ]]'
MIA=$(as_ mia1 "$X/me" | jq -r .id)
check 'P5 the link works once' '[[ "$(code_ other -X POST -d "{\"token\":\"$TOKEN\"}" "$X/team/accept")" == 404 ]]'
check 'P6 a made-up link is refused' '[[ "$(code_ other -X POST -d "{\"token\":\"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG\"}" "$X/team/accept")" == 404 ]]'
check 'P6a a token is spent as given: the same link case-folded fails' '[[ "$(code_ other -X POST -d "{\"token\":\"${TOKEN^^}\"}" "$X/team/accept")" == 404 ]]'

# deny by default
check 'P7 a member with no agents granted gets an empty agent list (app)' '[[ "$(as_ mia1 "$X/server/conversations" | jq -c ".conversations")" == "[]" ]]'
check 'P8 ...and on the lite page too' '[[ "$(as_ mia1 -H "x-local-chat: 1" "$W/api/agents" | jq -c ".agents")" == "[]" ]]'
check "P9 a 403 on another agent's messages (app list)" '[[ "$(code_ mia1 "$X/server/messages?agent=alice")" == 403 ]]'
check 'P10 a 403 on sending to it (app)' '[[ "$(code_ mia1 -X POST -d "{\"agent\":\"alice\",\"body\":\"hi\"}" "$X/server/messages")" == 403 ]]'
check 'P11 a 403 on the lite page read and send' '[[ "$(code_ mia1 -H "x-local-chat: 1" "$W/api/messages?agent=alice")" == 403 && "$(code_ mia1 -H "x-local-chat: 1" -X POST -d "{\"agent\":\"alice\",\"text\":\"hi\"}" "$W/api/messages")" == 403 ]]'
check 'P12 the messages feed with no agent named returns nothing of theirs' '[[ "$(as_ mia1 "$X/server/messages" | jq -c .messages)" == "[]" ]]'
check 'P13 a member cannot invite, grant or remove' '[[ "$(code_ mia1 -X POST -d "{\"name\":\"Zed\"}" "$X/team/invite")" == 403 && "$(code_ mia1 -X PUT -d "{\"agents\":[\"alice\"]}" "$X/team/members/$MIA/agents")" == 403 ]]'

# grant one agent
r=$(as_ boss -X PUT -d '{"agents":["alice"]}' "$X/team/members/$MIA/agents")
check 'P14 the owner grants alice' '[[ "$(jq -c .agents <<<"$r")" == "[\"alice\"]" ]]'
check 'P15 the member now sees alice only' '[[ "$(as_ mia1 "$X/server/conversations" | jq -c "[.conversations[].dmAgent]")" == "[\"alice\"]" ]]'
r=$(as_ mia1 -X POST -d '{"agent":"alice","body":"hello from Mia"}' "$X/server/messages")
check 'P16 the member can chat with alice; the box gets it signed with her name' '[[ "$(jq -c "[.ok,.agent,.queued]" <<<"$r")" == "[true,\"alice\",true]" ]] && [[ "$(box "$B/server/messages/pending?agent=alice" | jq -r ".pending[0].text")" == "hello from Mia" ]]'
check 'P17 bob is still refused' '[[ "$(code_ mia1 "$X/server/messages?agent=bob")" == 403 ]]'
check 'P18 the member list shows her grant' '[[ "$(as_ boss "$X/team" | jq -c "[.members[] | select(.id == \"$MIA\") | .agents][0]")" == "[\"alice\"]" ]]'

# exec: the app's agent list and Needs-you, cut to what the member may use
ex_(){ local j="$1"; shift; as_ "$j" -X POST -d "$(printf '%s\n' "$@" | jq -Rsc '{args: (split("\n")[:-1] + ["--json"])}')" "$X/server/agents/exec"; }
data_(){ jq -c '.stdout | fromjson | .data'; }
check 'E1 the owner gets every agent from `agent list`' '[[ "$(ex_ boss agent list | data_ | jq -c "[.[].name]")" == "[\"alice\",\"bob\"]" ]]'
check 'E2 the member gets only alice' '[[ "$(ex_ mia1 agent list | data_ | jq -c "[.[].name]")" == "[\"alice\"]" ]]'
check "E3 the member's Needs-you shows alice's gate only" '[[ "$(ex_ mia1 task inbox | data_ | jq -c "[[.inbox[].ident], .needs_you]")" == "[[\"DIVE-1\"],1]" ]]'
r=$(ex_ mia1 task answer DIVE-2 --value=approved --human)
check "E4 the member cannot answer bob's gate (nothing reaches root)" '[[ "$(jq -r ".stdout | fromjson | .ok" <<<"$r")" == false ]] && ! grep -q "gate-answer" "$TMPD/panel.log"'
r=$(ex_ mia1 task answer DIVE-1 --value=approved --human)
check "E5 the member answers alice's gate; the app's approved goes to root as approve" '[[ "$(jq -r ".stdout | fromjson | .ok" <<<"$r")" == true ]] && grep -qx "\[\"gate-answer\",\"DIVE-1\",\"approve\"\]" "$TMPD/panel.log"'
check 'E6 a member cannot read AI accounts, secrets or the version' '[[ "$(code_ mia1 -X POST -d "{\"args\":[\"account\",\"list\"]}" "$X/server/agents/exec")" == 403 && "$(code_ mia1 -X POST -d "{\"args\":[\"secret\",\"saved\",\"ls\"]}" "$X/server/agents/exec")" == 403 ]]'
for A_ in '"shell","rm"' '"agent","rm","alice"' '"secret","link","X"' '"task","verify","DIVE-1"'; do
  check "E7 an exec not on the list is a 404, never run: [$A_]" '[[ "$(code_ boss -X POST -d "{\"args\":[$A_]}" "$X/server/agents/exec")" == 404 ]]'
done
check 'E8 every root call was a fixed verb' '! grep -qvE "^\[\"(team|board|gate-answer|settings|secrets)\"" "$TMPD/panel.log"'

# a second device for the same person, then remove the person
r=$(as_ mia1 -X POST -d "{\"personId\":\"$MIA\"}" "$X/team/invite"); T2=$(jq -r .link <<<"$r"); T2=${T2#*#}
as_ mia2 -X POST -d "{\"token\":\"$T2\"}" "$X/team/accept" >/dev/null
check 'P19 a person links a second device: same person, nobody new' '[[ "$(as_ mia2 "$X/me" | jq -r .id)" == "$MIA" && "$(as_ boss "$X/team" | jq "[.members[] | select(.state == \"joined\")] | length")" == 2 ]]'
check 'P20 a member cannot link a device for someone else' '[[ "$(code_ mia1 -X POST -d "{\"personId\":\"$(as_ boss "$X/me" | jq -r .id)\"}" "$X/team/invite")" == 403 ]]'
check 'P21 the owner cannot remove themself' '[[ "$(code_ boss -X DELETE "$X/team/members/$(as_ boss "$X/me" | jq -r .id)")" == 400 ]]'
check 'P22 the owner removes Mia' '[[ "$(as_ boss -X DELETE "$X/team/members/$MIA" | jq -r .ok)" == true ]]'
check "P23 a removed person's EVERY device gets 401 (app, lite page, panel)" '[[ "$(code_ mia1 "$X/me")" == 401 && "$(code_ mia2 "$X/me")" == 401 && "$(code_ mia2 "$X/server/conversations")" == 401 && "$(code_ mia1 -H "x-local-chat: 1" "$W/api/agents")" == 401 ]]'
check 'P24 the owner is untouched' '[[ "$(code_ boss "$X/me")" == 200 ]]'
r=$(as_ boss -X POST -d '{"name":"Old link"}' "$X/team/invite"); OID=$(jq -r .id <<<"$r"); OT=$(jq -r .link <<<"$r"); OT=${OT#*#}
check 'P25 an unused invite can be cancelled, and its link then fails' '[[ "$(as_ boss -X DELETE "$X/team/members/$OID" | jq -r .ok)" == true && "$(code_ other -X POST -d "{\"token\":\"$OT\"}" "$X/team/accept")" == 404 ]]'
check 'P26 a member leaves; the last owner cannot' '[[ "$(as_ desk -X POST -d "{}" "$X/team/leave" | jq -r .ok)" == true && "$(code_ desk "$X/me")" == 401 && "$(code_ boss -X POST -d "{}" "$X/team/leave")" == 400 ]]'
r=$(as_ boss -X POST -d '{"name":"Ann","role":"owner"}' "$X/team/invite"); T3=$(jq -r .link <<<"$r"); T3=${T3#*#}
as_ ann -X POST -d "{\"token\":\"$T3\"}" "$X/team/accept" >/dev/null
r=$(as_ boss -X POST -d '{"email":"Gus"}' "$X/team/invite"); T4=$(jq -r .link <<<"$r"); T4=${T4#*#}
as_ gus -X POST -d "{\"token\":\"$T4\"}" "$X/team/accept" >/dev/null
check "P26a the app's \"All agents\" (agents left out) grants every agent" '[[ "$(as_ gus "$X/server/conversations" | jq "[.conversations[].dmAgent] | length")" == 2 && "$(as_ gus "$X/me" | jq -r .role)" == member ]]'
check 'P27 an owner invite makes an owner who sees every agent' '[[ "$(as_ ann "$X/me" | jq -r .role)" == owner && "$(as_ ann "$X/server/conversations" | jq "[.conversations[].dmAgent] | length")" == 2 ]]'

# ── A. allowlist, signed out, origin ─────────────────────────────────────────
check 'A1 signed out: /me is 401' '[[ "$(code_ nobody "$X/me")" == 401 ]]'
for p in billing keys server/shell server/terminal enterprise/plan agent-telegram/finish server/snapshots; do
  check "A2 not answered → 404, never forwarded: /$p" '[[ "$(code_ boss "$X/'"$p"'")" == 404 ]]'
done
check 'A3 a write from another origin is refused' '[[ "$(curl -sk -o /dev/null -w "%{http_code}" -b "$TMPD/boss" -H "origin: https://evil.example.test" -H "content-type: application/json" -d "{\"name\":\"X\"}" "$X/team/invite")" == 403 ]]'
check 'A4 a wrong method on an answered path is 405' '[[ "$(code_ boss -X DELETE "$X/me")" == 405 ]]'

# long poll and the live feed
LAST=$(as_ boss "$X/server/messages?agent=bob" | jq '[.messages[].id] | max // 0')
( sleep 1; box -d '{"agent":"bob","body":"bob says hi"}' "$B/server/messages/event" >/dev/null ) &
r=$(as_ boss "$X/server/messages?agent=bob&since=$LAST&wait=5")
check 'A5 the long poll returns the agent reply as it lands' '[[ "$(jq -r ".messages[0].body" <<<"$r")" == "bob says hi" && "$(jq -r ".messages[0].direction" <<<"$r")" == outbound ]]'
( sleep 1; box -d '{"agent":"bob","body":"live one"}' "$B/server/messages/event" >/dev/null ) &
s=$(curl -sNk --max-time 3 -b "$TMPD/boss" "$X/server/messages/stream")
check 'A6 the live feed sends ready, then the message' 'grep -q "^event: ready" <<<"$s" && grep -q "live one" <<<"$s"'

# files: a member's upload lands in a granted agent's folder only
as_ boss -X POST -d '{"name":"Fay","agents":[]}' "$X/team/invite" | jq -r .link | { read -r l; as_ fay -X POST -d "{\"token\":\"${l#*#}\"}" "$X/team/accept" >/dev/null; }
check 'A7 a member cannot upload into an agent they do not have' '[[ "$(curl -sk -o /dev/null -w "%{http_code}" -b "$TMPD/fay" -H "origin: $W" --data-binary "x" "$X/server/files/upload?agent=alice&name=a.txt")" == 403 ]]'
r=$(curl -sSk -b "$TMPD/boss" -H "origin: $W" --data-binary "hello file" "$X/server/files/upload?agent=alice&name=a.txt")
FP=$(jq -r .path <<<"$r")
check 'A8 an owner uploads; the file comes back by its path' '[[ "$FP" == "$UP/alice/"* && "$(curl -sk -b "$TMPD/boss" "$X/server/files/download?path=$FP")" == "hello file" ]]'
check "A9 a member cannot download another agent's file" '[[ "$(code_ fay "$X/server/files/download?path=$FP")" == 403 ]]'

# ── C. contract: the shapes the app reads ────────────────────────────────────
FIX=tests/fixtures/dive8807-office-app-contract.json
# shape_ok <shape> <json> — every field the fixture names is there with a type it allows ("a|b").
shape_ok(){ jq -e --argjson s "$1" '
  def chk($s; $v): if ($s | type) == "string" then ($s | split("|")) as $t | (($v | type) as $vt | $t | index($vt)) != null
    elif ($s | type) == "array" then ($v | type) == "array" and all($v[]; chk($s[0]; .))
    else ($v | type) == "object" and all($s | to_entries[]; . as $e | chk($e.value; $v[$e.key])) end;
  chk($s; .)' <<<"$2" >/dev/null; }
box -d '{"agent":"alice","body":"for the contract"}' "$B/server/messages/event" >/dev/null
CID=$(as_ boss "$X/server/conversations" | jq '.conversations[0].id')
while IFS=$'\t' read -r key req shape; do
  m=${key%% *}; p=${key#* }; p=${p%% *}; p=${p//<conversation>/$CID}
  if [[ "$m" == GET ]]; then r=$(as_ boss "$X$p"); else r=$(as_ boss -X "$m" -d "$req" "$X$p"); fi
  env_=$(jq -c --arg k "$key" '.paths[$k].envelope // empty' "$FIX")
  if shape_ok "$shape" "$r" && { [[ -z "$env_" ]] || { [[ "$(jq -r '.stdout | fromjson | .ok' <<<"$r")" == true ]] && shape_ok "$env_" "$(jq -c '.stdout | fromjson | .data' <<<"$r")"; }; }; then
    ok_ "C $key matches what the app reads"
  else bad_ "C $key" "$(head -c 300 <<<"$r")"; fi
done < <(jq -r '.paths | to_entries[] | [.key, (.value.request // {} | tojson), (.value.response | tojson)] | @tsv' "$FIX")
# Every route the server answers has a contract arm (or is named here as one the app reads nothing from).
ANSWERED=$(grep -oE '\["(GET|POST|PUT|DELETE)", /\^\\/[^$]*\$/' "$TMPD/server.ts" | sed -E 's/\["([A-Z]+)", \/\^(.*)\$\//\1 \2/; s/\\//g' | sort -u)
NO_READ='POST /team/leave|PUT /team/members/([a-f0-9]{8,32})/agents|DELETE /team/members/(i?[a-f0-9]{8,32})|POST /server/files/upload|POST /server/files/mkdir|GET /server/files/download|GET /server/messages/stream|POST /server/conversations/(d+)/read'
miss=$(while read -r a; do k=$(sed -E 's/\(d\+\)/<conversation>/' <<<"$a"); jq -e --arg k "$k" '.paths | keys | map(split(" ")[0:2] | join(" ") | split("?")[0]) | index($k)' "$FIX" >/dev/null || grep -qxE "$NO_READ" <<<"$a" || grep -qxF "$a" <<<"${NO_READ//|/$'\n'}" || echo "$a"; done <<<"$ANSWERED")
check 'C0 every answered path has a contract arm or is a write the app reads nothing back from' '[[ -z "$miss" && $(wc -l <<<"$ANSWERED") -ge 18 ]]'
[[ -n "$miss" ]] && printf '  no contract arm: %s\n' $miss

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
