#!/usr/bin/env bash
# DIVE-6169 — a 5dive box vouches for its own agent's did on the a2a feed.
#
# The did is graded against an INDEPENDENT value: RFC 8032's first ed25519 test
# key, whose did:key is the one @5dive/openagent's didKeyFromPublicKey prints
# (z6Mktwupdm…, also the did:key spec's example). The transport is graded for
# real: _a2a_vouch_post's curl talks to a mock endpoint on 127.0.0.1 that records
# the path, the Authorization header and the body of every request.
#
# Arms: did from the fixture key; a non-key file is refused; a 200 POST (path,
# bearer, body is {did} only, added); 4xx and the API's 502/503 are "refused",
# 429 and a closed port are "not reached"; no box token -> rc 3 and nothing sent;
# the verb (--json, no key -> E_NOT_FOUND); and the import hook sits inside the
# adopted-key block, after the key is installed.
set -uo pipefail

TMP=""; SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

PASS=0; FAIL=0
ok_t()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
chk()    { if [[ "$2" == "$3" ]]; then ok_t "$1"; else fail_t "$1 (expected '$2', got '$3')"; fi }

if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v openssl >/dev/null; then
  ok_t "SKIP: no python3/curl/openssl on this host"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 0
fi

TMP=$(mktemp -d)
mkdir -p "$TMP/reqs" "$TMP/home/agent-ada/.openagent"
export CONNECTORD_TOKEN="fake-box-token-0000" FIVE_A2A_VOUCH_TIMEOUT=5 AGENT_HOME_ROOT="$TMP/home"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_partner.sh cmd_agent_a2a_vouch.sh; do
  source "src/$f"
done
set +e
require_root() { :; }

# RFC 8032 §7.1 TEST 1 secret key, as a pkcs8 PEM (what openagent's keystore writes).
cat >"$TMP/home/agent-ada/.openagent/agent.key" <<'PEM'
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
-----END PRIVATE KEY-----
PEM
WANT="did:key:z6MktwupdmLXVVqTzCw4i46r4uGyosGXRnR3XjN4Zq7oMMsw"

# ── 1. did from the key ───────────────────────────────────────────────────────
chk "the did:key of RFC 8032 test key 1 is openagent's" "$WANT" "$(_a2a_did_from_key "$TMP/home/agent-ada/.openagent/agent.key")"
_a2a_did_from_key /etc/hostname >/dev/null; chk "a file that is not an ed25519 key -> rc 1" 1 "$?"
_a2a_did_from_key "$TMP/nope" >/dev/null; chk "a missing key -> rc 1" 1 "$?"

# ── the mock endpoint (status from $TMP/status, default 200) ──────────────────
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 - "$TMP" "$PORT" >/dev/null 2>&1 <<'PY' &
import http.server, json, os, sys
d, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode()
        i = len(os.listdir(os.path.join(d, "reqs")))
        with open(os.path.join(d, "reqs", "%03d.json" % i), "w") as f:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}, f)
        try:
            status = int(open(os.path.join(d, "status")).read().strip())
        except Exception:
            status = 200
        out = json.dumps({"vouched": True, "added": True} if status < 300 else {"error": "nope"}).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
SRV_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/ready" && break; sleep 0.1; done
rm -f "$TMP"/reqs/*
export FIVE_API_BASE="http://127.0.0.1:$PORT"
nreq() { find "$TMP/reqs" -type f | wc -l; }
req()  { jq -r "$2" "$TMP/reqs/$(printf '%03d' "$1").json"; }

# ── 2. a vouch reaches the API with the box bearer and the did only ───────────
_a2a_vouch_post "$WANT"; chk "200 -> rc 0" 0 "$?"
chk "...one request" 1 "$(nreq)"
chk "...to /server/a2a/vouch" "/server/a2a/vouch" "$(req 0 .path)"
chk "...with the box's own bearer" "Bearer fake-box-token-0000" "$(req 0 .auth)"
chk "...and a body of {did} alone (the API, not the box, names the server)" \
  "{\"did\":\"$WANT\"}" "$(req 0 .body | jq -c .)"
chk "...added is read from the answer" true "$_A2A_VOUCH_ADDED"

# ── 3. answers ────────────────────────────────────────────────────────────────
for s in 400 401 403 502 503; do
  echo "$s" >"$TMP/status"; _a2a_vouch_post "$WANT"; chk "$s -> refused (rc 2)" 2 "$?"
done
for s in 404 429 500; do
  echo "$s" >"$TMP/status"; _a2a_vouch_post "$WANT"; chk "$s -> not reached (rc 1)" 1 "$?"
done
CLOSED=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
FIVE_API_BASE="http://127.0.0.1:$CLOSED" _a2a_vouch_post "$WANT"; chk "a closed port -> not reached (rc 1)" 1 "$?"
rm -f "$TMP/status"

# ── 4. no box token: not a managed box, nothing sent ──────────────────────────
n0=$(nreq)
( unset CONNECTORD_TOKEN; _partner_connectord_env() { printf '%s' "$TMP/no-such-env"; }; _a2a_vouch_post "$WANT" ); chk "no box token -> rc 3" 3 "$?"
chk "...and nothing reached the endpoint" "$n0" "$(nreq)"

# ── 5. the verb ───────────────────────────────────────────────────────────────
out=$(cmd_agent_a2a_vouch ada --json 2>&1); chk "a2a-vouch ada --json exits 0" 0 "$?"
chk "...prints the agent's did, vouched" "ada $WANT true true" "$(jq -r '"\(.name) \(.did) \(.vouched) \(.added)"' <<<"$out" 2>/dev/null)"
chk "...and the request carried that did" "$WANT" "$(req "$(( $(nreq) - 1 ))" .body | jq -r .did)"
( cmd_agent_a2a_vouch bob >/dev/null 2>&1 ); chk "an agent with no key -> E_NOT_FOUND" "$E_NOT_FOUND" "$?"
( cmd_agent_a2a_vouch >/dev/null 2>&1 ); chk "no name -> E_USAGE" "$E_USAGE" "$?"
( cmd_agent_a2a_vouch 'x;y' >/dev/null 2>&1 ); chk "a bad name -> E_VALIDATION" "$E_VALIDATION" "$?"
echo 403 >"$TMP/status"; ( cmd_agent_a2a_vouch ada >/dev/null 2>&1 ); chk "a refused vouch is not a silent exit 0" "$E_GENERIC" "$?"; rm -f "$TMP/status"

# ── 6. wiring ─────────────────────────────────────────────────────────────────
blk=$(awk '/if \(\( has_signing_key \)\) && \[\[ -s "\$signing_keyfile" \]\]; then/{on=1} on{print} on&&/^  fi$/{exit}' src/cmd_pack.sh)
[[ "$blk" == *'install -o "agent-${as}" -g "agent-${as}" -m 600 "$signing_keyfile" "$kdir/agent.key"'*'_a2a_vouch_agent "$as"'* ]] \
  && ok_t "agent import vouches inside the adopted-key block, after the key is installed" \
  || fail_t "the import hook is missing or before the key install"
grep -qE '^ +a2a-vouch\)$' src/main.sh && grep -q 'cmd_agent_a2a_vouch "\$@"' src/main.sh \
  && ok_t "5dive agent a2a-vouch dispatches" || fail_t "a2a-vouch is not dispatched in main.sh"
grep -qx '  src/cmd_agent_a2a_vouch.sh' build.sh && ok_t "build.sh bundles the module" || fail_t "build.sh does not bundle cmd_agent_a2a_vouch.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
