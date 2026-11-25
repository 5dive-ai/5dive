#!/usr/bin/env bash
# DIVE-9264: the office server's generic sign-in hook (src/cmd_local_chat_server.sh).
# A signed office app may carry <app>/_server/signin.mjs; core imports it, never
# serves it, and gives it a small ctx (origin, kv, people, signIn, json).
#
#   S. the hook's doors: providers (sanitized), /signin/* → handle, /_server/ never served.
#   E. people get an email: invite stores it, PUT .../email sets/clears, 409 on a clash.
#   G. signIn: a Team-list email admits (200 HTML hop + cookie), unknown is refused,
#      allowNew makes a member with no agents, a REMOVED person's email never signs in.
#   I. an invited email (not yet joined) signs in: the invite is spent with its role and
#      agents, in team and domain mode; expired invites do not; no duplicate after.
#   A. /api/proxy/signin/*: 401 signed out, 403 member, owner reaches admin.
#   T. signIn counts against the code-try budget.
#   L. no module / no app / a module that throws on import: feature absent, server up.
#
# The REAL server on bun, loopback only, a throwaway self-signed cert; a fake
# office app dir with a fake module. Needs bun, openssl, curl, jq.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/signin-hook.XXXXXX")"
SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; echo "HARNESS-RC=$rc"' EXIT
for f in header.sh lib/error_codes.sh lib/output.sh cmd_local_chat_server.sh; do source "src/$f"; done
set +e

BUN=$(command -v bun || echo /usr/local/bin/bun)
if [[ ! -x "$BUN" ]]; then bad_ 'S0 bun present' "no bun"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; fi
_local_chat_server_ts >"$T/server.ts"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=t" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$T/key.pem" -out "$T/cert.pem" >/dev/null 2>&1
printf 'CONNECTORD_TOKEN="boxtok-123"\n' >"$T/connectord.env"
printf '["alice","bob"]\n' >"$T/agents.json"
STATE="$T/state"; mkdir -p "$STATE"

# Three app versions: v1 with a module, v2 without, v3 whose module throws on import.
mkapp(){ mkdir -p "$T/apps/$1/app/tg" "$T/apps/$1/app/_server"; printf '{"app":{"index":"/tg/"}}' >"$T/apps/$1/manifest.json"; printf '<p>app %s</p>' "$1" >"$T/apps/$1/app/tg/index.html"; }
mkapp v1; mkapp v2; mkapp v3; rmdir "$T/apps/v2/app/_server"
cat >"$T/apps/v1/app/_server/signin.mjs" <<'MOD'
export function providers(ctx) {
  return [{ id: "fake", label: "Sign in with Fake", href: "/signin/fake/start" },
    { id: "BAD ID", label: "x", href: "/signin/x" }, { id: "evil", label: "Evil", href: "https://evil.example.com/" }];
}
export async function handle(req, url, ctx) {
  if (url.pathname === "/signin/fake/as") {
    const r = ctx.signIn(url.searchParams.get("email") ?? "", { allowNew: url.searchParams.get("new") === "1", via: "Fake sign-in" });
    return r ?? new Response("ask your IT", { status: 403 });
  }
  if (url.pathname === "/signin/fake/people") return ctx.json(ctx.people());
  if (url.pathname === "/signin/fake/kv") {
    const v = url.searchParams.get("v"); ctx.kv.set("k", v === "" ? null : v);
    let big = "refused"; try { ctx.kv.set("x".repeat(65), "1"); big = "stored"; } catch {}
    return ctx.json({ v: ctx.kv.get("k"), big, origin: ctx.origin });
  }
  return ctx.json({ reached: "handle", path: url.pathname, method: req.method });
}
export async function admin(req, url, ctx) { return ctx.json({ reached: "admin", path: url.pathname, method: req.method }); }
MOD
printf 'export function providers() { return []; }\nthrow new Error("broken module");\n' >"$T/apps/v3/app/_server/signin.mjs"
ln -sfn "$T/apps/v1" "$T/apps/current"

# The owner's code, added the way `local pair` does it.
OWNER_CODE=ABCD2345
LC_STATE="$STATE" "$BUN" "$T/server.ts" admin pair-add "$(printf %s "$OWNER_CODE" | sha256sum | cut -d' ' -f1)" "$(( $(date +%s) + 600 ))" owner Boss >/dev/null

LAN=$((20000 + RANDOM % 20000)); LOOP=$((LAN + 1))
# A restart keeps the db and resets the in-memory code-try budget (10 a minute).
start_srv(){
  LC_STATE="$STATE" LC_LAN_ADDR=127.0.0.1 LC_LAN_PORT=$LAN LC_LOOP_PORT=$LOOP LC_CERT="$T/cert.pem" LC_KEY="$T/key.pem" \
    LC_TOKEN_FILE="$T/connectord.env" LC_AGENTS_FILE="$T/agents.json" LC_UPLOADS="$T/uploads" LC_PANEL_SOCK="$T/none.sock" \
    LC_APP_DIR="$T/apps/current" "$BUN" "$T/server.ts" serve >>"$T/server.log" 2>&1 & SRV_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$LOOP/" && break; sleep 0.1; done
}
start_srv

W="https://127.0.0.1:$LAN"; X="$W/api/proxy"
as_(){ local j="$1"; shift; curl -sSk -b "$T/$j" -c "$T/$j" -H "origin: $W" -H 'content-type: application/json' "$@"; }
code_(){ local j="$1"; shift; curl -sk -o /dev/null -w '%{http_code}' -b "$T/$j" -c "$T/$j" -H "origin: $W" -H 'content-type: application/json' "$@"; }
sqlw(){ "$BUN" -e 'import { Database } from "bun:sqlite"; const d = new Database(process.argv[1]); d.query(process.argv[2]).run(...process.argv.slice(3));' "$STATE/chat.db" "$@"; }
sql(){ "$BUN" -e 'import { Database } from "bun:sqlite"; const d = new Database(process.argv[1], { readonly: true }); console.log(d.query(process.argv[2]).all(...process.argv.slice(3)).map((r) => Object.values(r).join("|")).join("\n"));' "$STATE/chat.db" "$@"; }
as_ boss -H 'x-local-chat: 1' -X POST -d "{\"code\":\"$OWNER_CODE\",\"name\":\"Boss\"}" "$W/api/pair" >/dev/null
check 'S0 the owner is signed in' '[[ "$(as_ boss "$X/me" | jq -r .role)" == owner ]]'

# ── S. the doors ─────────────────────────────────────────────────────────────
r=$(curl -sk "$W/api/signin/providers")
check "S1 providers: the module's list, cut to valid ids and same-origin /signin/ links" '[[ "$(jq -c .providers <<<"$r")" == "[{\"id\":\"fake\",\"label\":\"Sign in with Fake\",\"href\":\"/signin/fake/start\"}]" ]]'
check 'S2 /_server/ is never served (plain, doubled slash, encoded, the folder)' '[[ "$(code_ x "$W/_server/signin.mjs")" == 404 && "$(code_ x "$W//_server/signin.mjs")" == 404 && "$(code_ x "$W/%5Fserver/signin.mjs")" == 404 && "$(code_ x "$W/_server/")" == 404 ]] && [[ "$(curl -sk "$W//_server/signin.mjs")" != *providers* ]]'
check 'S2a the app itself is still served' '[[ "$(curl -sk "$W/tg/")" == "<p>app v1</p>" ]]'
r=$(curl -sk "$W/signin/fake/start?x=1")
check "S3 /signin/* reaches the module's handle, signed out" '[[ "$(jq -c "[.reached,.path,.method]" <<<"$r")" == "[\"handle\",\"/signin/fake/start\",\"GET\"]" ]]'
check 'S3a HEAD /signin/* answers too' '[[ "$(curl -sk -I -o /dev/null -w "%{http_code}" "$W/signin/fake/start")" == 200 ]]'
pg=$(curl -sk "$W/join")
check 'S4 the signed-out page fetches the providers and draws link buttons' '[[ "$pg" == *"/api/signin/providers"* && "$pg" == *"<a class=\"btn\" href="* ]]'
r=$(curl -sk "$W/signin/fake/kv?v=hello")
check 'S5 ctx.kv stores a value, refuses a key over 64 chars; ctx.origin is this office' '[[ "$(jq -c "[.v,.big,.origin]" <<<"$r")" == "[\"hello\",\"refused\",\"$W\"]" ]] && [[ "$(curl -sk "$W/signin/fake/kv?v=" | jq -c .v)" == null ]]'

# ── E. people get an email ───────────────────────────────────────────────────
r=$(as_ boss -X POST -d '{"email":"Mia@example.com","agents":[]}' "$X/team/invite")
TOKEN=$(jq -r .link <<<"$r"); TOKEN=${TOKEN#*#}
check 'E1 an invite with an email keeps it (lower-case), the name is the local part' '[[ "$(as_ boss "$X/team" | jq -c "[.members[] | select(.state == \"invited\") | [.name,.email]][0]")" == "[\"Mia\",\"mia@example.com\"]" ]]'
as_ mia -X POST -d "{\"token\":\"$TOKEN\"}" "$X/team/accept" >/dev/null
MIA=$(as_ mia "$X/me" | jq -r .id)
check 'E2 the person made from the code carries the email (workEmail, email)' '[[ "$(as_ boss "$X/team" | jq -c "[.members[] | select(.id == \"$MIA\") | [.workEmail,.email]][0]")" == "[\"mia@example.com\",\"mia@example.com\"]" ]]'
check "E3 a second invite for a live person's email is 409 email_taken" '[[ "$(as_ boss -X POST -d "{\"email\":\"mia@example.com\"}" "$X/team/invite" | jq -r .error)" == email_taken ]]'
r=$(as_ boss -X POST -d '{"email":"Leo B","agents":[]}' "$X/team/invite")
check 'E3a an invite with a plain name still works (no email stored)' '[[ "$(jq -r .ok <<<"$r")" == true && "$(as_ boss "$X/team" | jq -c "[.members[] | select(.name == \"Leo B\") | .email][0]")" == "\"Leo B\"" ]]'
TOKEN=$(jq -r .link <<<"$r"); TOKEN=${TOKEN#*#}
as_ leo -X POST -d "{\"token\":\"$TOKEN\"}" "$X/team/accept" >/dev/null
LEO=$(as_ leo "$X/me" | jq -r .id)
check "E4 PUT .../email sets a person's email" '[[ "$(as_ boss -X PUT -d "{\"email\":\"Leo@example.com\"}" "$X/team/members/$LEO/email" | jq -c "[.ok,.email]")" == "[true,\"leo@example.com\"]" ]]'
check 'E5 ...409 when another live person has it' '[[ "$(code_ boss -X PUT -d "{\"email\":\"mia@example.com\"}" "$X/team/members/$LEO/email")" == 409 ]]'
check 'E6 ...setting the same email again on the same person is fine' '[[ "$(code_ boss -X PUT -d "{\"email\":\"leo@example.com\"}" "$X/team/members/$LEO/email")" == 200 ]]'
check 'E7 ...400 on a bad email, 403 for a member, 404 for no one' '[[ "$(code_ boss -X PUT -d "{\"email\":\"nope\"}" "$X/team/members/$LEO/email")" == 400 && "$(code_ mia -X PUT -d "{\"email\":\"\"}" "$X/team/members/$LEO/email")" == 403 && "$(code_ boss -X PUT -d "{\"email\":\"\"}" "$X/team/members/abcdef012345/email")" == 404 ]]'
as_ boss -X PUT -d '{"email":""}' "$X/team/members/$LEO/email" >/dev/null
check 'E8 ..."" clears it (workEmail empty, email falls back to the name)' '[[ "$(as_ boss "$X/team" | jq -c "[.members[] | select(.id == \"$LEO\") | [.workEmail,.email]][0]")" == "[\"\",\"Leo B\"]" ]]'
as_ boss -X PUT -d '{"email":"leo@example.com"}' "$X/team/members/$LEO/email" >/dev/null

# ── G. signIn ────────────────────────────────────────────────────────────────
H="$T/hop.h"
r=$(curl -sk -D "$H" -c "$T/sso1" "$W/signin/fake/as?email=%20MIA@example.com%20")
check 'G1 a Team-list email is admitted: 200 HTML hop to / (not a 302), no-store' 'grep -qi "^HTTP/[0-9.]* 200" "$H" && grep -qi "^content-type: text/html" "$H" && grep -qi "^cache-control: no-store" "$H" && ! grep -qi "^location:" "$H" && grep -q "http-equiv=\"refresh\" content=\"0;url=/\"" <<<"$r" && grep -q "href=\"/\"" <<<"$r"'
check 'G1a ...with the session cookie (HttpOnly, Secure, SameSite=Strict)' 'c=$(grep -i "^set-cookie: lc_dev=" "$H"); grep -qi "HttpOnly; Secure; SameSite=Strict" <<<"$c"'
check 'G2 the cookie works: it is Mia, still a member with her grants' '[[ "$(as_ sso1 "$X/me" | jq -c "[.id,.role]")" == "[\"$MIA\",\"member\"]" && "$(as_ sso1 "$X/team" | jq -c .agents)" == "[]" ]]'
check 'G2a ...a NEW device, named after the sign-in' '[[ "$(as_ boss "$X/team" | jq "[.members[] | select(.id == \"$MIA\") | .devices][0]")" == 2 && "$(sql "SELECT name FROM devices WHERE person = ? ORDER BY created DESC, rowid DESC LIMIT 1" "$MIA")" == "Fake sign-in" ]]'
n0=$(sql "SELECT COUNT(*) FROM people")
check 'G3 an unknown email with allowNew:false is refused (null), no one is made' '[[ "$(code_ x "$W/signin/fake/as?email=stranger@example.com")" == 403 && "$(sql "SELECT COUNT(*) FROM people")" == "$n0" ]]'
check 'G3a a non-email is refused' '[[ "$(code_ x "$W/signin/fake/as?email=not-an-email&new=1")" == 403 ]]'
check 'G4 allowNew:true makes a member with NO agents' '[[ "$(code_ sso2 "$W/signin/fake/as?email=Newbie@example.com&new=1")" == 200 && "$(as_ sso2 "$X/me" | jq -c "[.name,.role]")" == "[\"Newbie\",\"member\"]" && "$(as_ sso2 "$X/server/conversations" | jq -c .conversations)" == "[]" && "$(as_ boss "$X/team" | jq -c "[.members[] | select(.workEmail == \"newbie@example.com\") | .agents][0]")" == "[]" ]]'
as_ boss -X DELETE "$X/team/members/$LEO" >/dev/null
check "G5 a REMOVED person's email is refused, even with allowNew:true" '[[ "$(code_ sso3 "$W/signin/fake/as?email=leo@example.com&new=1")" == 403 && "$(code_ sso3 "$X/me")" == 401 && "$(sql "SELECT COUNT(*) FROM people WHERE email = ?" leo@example.com)" == 1 ]]'
check "G6 people(): the Team list's emails, the leaver marked removed" '[[ "$(curl -sk "$W/signin/fake/people" | jq -c "sort_by(.email)")" == "[{\"email\":\"leo@example.com\",\"removed\":true},{\"email\":\"mia@example.com\",\"removed\":false},{\"email\":\"newbie@example.com\",\"removed\":false}]" ]]'

# ── I. an invited, not-yet-joined email signs in by work account ─────────────
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; start_srv
inv(){ as_ boss -X POST -d "{\"email\":\"$1\",\"agents\":$2}" "$X/team/invite"; }
r=$(inv Ana@example.com '["alice"]'); ANA_ID=$(jq -r .id <<<"$r")
check 'I1 team mode (allowNew:false): an invited email is admitted, as the invite made her (member, its agents)' '[[ "$(code_ sso4 "$W/signin/fake/as?email=ana@example.com")" == 200 && "$(as_ sso4 "$X/me" | jq -c "[.name,.role]")" == "[\"Ana\",\"member\"]" && "$(as_ sso4 "$X/team" | jq -c .agents)" == "[\"alice\"]" ]]'
ANA=$(as_ sso4 "$X/me" | jq -r .id)
check 'I1a ...the invite is spent: off the invited list, joined with her work email' '[[ "$(as_ boss "$X/team" | jq -c "[.members[] | select(.id == \"$ANA_ID\")] | length")" == 0 && "$(as_ boss "$X/team" | jq -c "[.members[] | select(.workEmail == \"ana@example.com\") | [.id,.state]]")" == "[[\"$ANA\",\"joined\"]]" && "$(sql "SELECT used FROM pair_codes WHERE email = ?" ana@example.com)" == 1 ]]'
check 'I1b ...signing in again later is the same person, no second one' '[[ "$(code_ sso5 "$W/signin/fake/as?email=ana@example.com")" == 200 && "$(as_ sso5 "$X/me" | jq -r .id)" == "$ANA" && "$(sql "SELECT COUNT(*) FROM people WHERE email = ?" ana@example.com)" == 1 ]]'
r=$(inv Ben@example.com '["bob"]'); TOKEN=$(jq -r .link <<<"$r"); TOKEN=${TOKEN#*#}
check 'I2 domain mode (allowNew:true): the invite wins, one person carrying its agents' '[[ "$(code_ sso6 "$W/signin/fake/as?email=ben@example.com&new=1")" == 200 && "$(as_ sso6 "$X/team" | jq -c .agents)" == "[\"bob\"]" && "$(sql "SELECT COUNT(*) FROM people WHERE email = ?" ben@example.com)" == 1 ]]'
check 'I2a ...opening the join link afterwards is refused and makes no duplicate' '[[ "$(code_ ben2 -X POST -d "{\"token\":\"$TOKEN\"}" "$X/team/accept")" == 404 && "$(sql "SELECT COUNT(*) FROM people WHERE email = ? OR name = ?" ben@example.com Ben)" == 1 && "$(as_ boss "$X/team" | jq "[.members[] | select(.name == \"Ben\")] | length")" == 1 ]]'
inv Cy@example.com '["alice"]' >/dev/null
sqlw "UPDATE pair_codes SET expires = ? WHERE email = ?" "$(( $(date +%s) - 10 ))" cy@example.com
check 'I3 an EXPIRED email invite does not admit in team mode (the owner invites again)' '[[ "$(code_ x "$W/signin/fake/as?email=cy@example.com")" == 403 && "$(sql "SELECT COUNT(*) FROM people WHERE email = ?" cy@example.com)" == 0 ]]'
inv leo@example.com '[]' >/dev/null
check 'I4 a leaver the owner re-invites by email signs in as a NEW person; the removed one stays removed' '[[ "$(code_ sso7 "$W/signin/fake/as?email=leo@example.com")" == 200 && "$(as_ sso7 "$X/me" | jq -r .id)" != "$LEO" && "$(sql "SELECT COUNT(*) FROM people WHERE email = ? AND removed = 0" leo@example.com)" == 1 && "$(code_ leo "$X/me")" == 401 ]]'

# ── A. the module's admin door ───────────────────────────────────────────────
check 'A1 /api/proxy/signin/* signed out is 401' '[[ "$(code_ x "$X/signin/settings")" == 401 ]]'
check 'A2 ...a member gets 403' '[[ "$(code_ mia "$X/signin/settings")" == 403 ]]'
check 'A3 ...an owner reaches admin, path unchanged' '[[ "$(as_ boss "$X/signin/settings" | jq -c "[.reached,.path,.method]")" == "[\"admin\",\"/api/proxy/signin/settings\",\"GET\"]" ]]'
check 'A4 ...an owner PUT from this origin reaches admin' '[[ "$(as_ boss -X PUT -d "{}" "$X/signin/settings" | jq -r .method)" == PUT ]]'
check 'A5 ...a write from another origin is 403 before admin' '[[ "$(curl -sk -o /dev/null -w "%{http_code}" -b "$T/boss" -H "origin: https://evil.example.com" -H "content-type: application/json" -X PUT -d "{}" "$X/signin/settings")" == 403 ]]'

# ── T. the code-try budget ───────────────────────────────────────────────────
got=""; for _ in $(seq 1 12); do c=$(code_ x "$W/signin/fake/as?email=stranger@example.com"); [[ "$c" == 429 ]] && { got=429; break; }; done
check 'T1 signIn counts against the code-try budget (429 once it is spent)' '[[ "$got" == 429 ]]'

# ── L. no module, no app, a broken module ────────────────────────────────────
ln -sfn "$T/apps/v2" "$T/apps/current"
check "L1 an app with no module: providers [], /signin/* 404, the owner's admin door 404" '[[ "$(curl -sk "$W/api/signin/providers" | jq -c .providers)" == "[]" && "$(code_ x "$W/signin/fake/start")" == 404 && "$(code_ boss "$X/signin/settings")" == 404 ]]'
ln -sfn "$T/apps/nowhere" "$T/apps/current"
check 'L2 no app at all: providers [], /signin/* 404' '[[ "$(curl -sk "$W/api/signin/providers" | jq -c .providers)" == "[]" && "$(code_ x "$W/signin/fake/start")" == 404 ]]'
ln -sfn "$T/apps/v3" "$T/apps/current"
check 'L3 a module that throws on import: providers [], /signin/* 404' '[[ "$(curl -sk "$W/api/signin/providers" | jq -c .providers)" == "[]" && "$(code_ x "$W/signin/fake/start")" == 404 ]]'
check 'L4 ...the server keeps running and logs one line' 'kill -0 "$SRV_PID" && [[ "$(as_ boss "$X/me" | jq -r .role)" == owner && "$(grep -c "sign-in module not loaded" "$T/server.log")" == 1 ]]'
ln -sfn "$T/apps/v1" "$T/apps/current"
check 'L5 a new app version with a module brings it back' '[[ "$(curl -sk "$W/api/signin/providers" | jq -r ".providers[0].id")" == fake ]]'

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
