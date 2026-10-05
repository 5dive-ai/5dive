#!/usr/bin/env bash
# DIVE-5114 — `agent import --from-url=<https-url>`: a partner box imports a
# pack from 5dive-api's short-lived signed link (the pack lives in the partner's
# PRIVATE registry, so the box never resolves a slug and never holds a
# credential). Grades the parser, the https-only fetch, that the link is never
# echoed, the handoff into the normal file-pack path, and temp-file cleanup.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
TMP=""; SRV_PID=""
trap 'rc=$?; [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=/dev/null
source src/lib/error_codes.sh
# shellcheck source=/dev/null
source src/lib/output.sh
# shellcheck source=/dev/null
source src/lib/validation.sh
# shellcheck source=/dev/null
source src/cmd_pack.sh
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n       %s\n' "$1" "${2:-}"; }
eq_t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "expected [$2], got [$3]"; }

TMP=$(mktemp -d)
SIGNED='https://api.5dive.com/partner/packs/acme/maya.tar.gz?e=1790000000&sig=deadbeefcafe'

echo '== link host =='
eq_t 'host of a signed link drops path and query' api.5dive.com "$(_pack_url_host "$SIGNED")"
eq_t 'host of a link with a port keeps the port' 'h.example:8443' "$(_pack_url_host 'https://h.example:8443/x?y')"

echo '== validate-only parser (hire --from-market) =='
if ( _import_parse_args --from-url=https://x.example/p.tar.gz --as=a ) >/dev/null 2>&1; then
  ok_t '--from-url is a known import flag'
else
  bad_t '--from-url is a known import flag' 'parser refused it'
fi

echo '== fetch is https-only =='
printf 'secret\n' > "$TMP/local"
if out=$(_pack_fetch_url "file://$TMP/local" 2>&1); then
  bad_t 'a file:// link is refused by the fetch itself' "fetched: $out"
else
  ok_t 'a file:// link is refused by the fetch itself'
fi
[[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*.tar.gz' -newer "$TMP/local" 2>/dev/null)" ]] \
  && ok_t 'a refused fetch leaves no temp file' \
  || bad_t 'a refused fetch leaves no temp file' "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*.tar.gz' -newer "$TMP/local")"

# A real https fetch against a local server with a throwaway CA, when the host
# has the tools. Proves _pack_fetch_url downloads and echoes the file path.
mkdir -p "$TMP/srv"; printf 'PACKBYTES' > "$TMP/srv/p.tar.gz"
if command -v openssl >/dev/null && command -v python3 >/dev/null \
   && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
        -addext 'subjectAltName=IP:127.0.0.1' -keyout "$TMP/k.pem" -out "$TMP/c.pem" >/dev/null 2>&1; then
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  HPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  # One process: https on PORT (with /to-http and /to-https 302s) and plain http
  # on HPORT serving the same files, so a redirect can try to downgrade.
  python3 - "$TMP/srv" "$PORT" "$TMP/c.pem" "$TMP/k.pem" "$HPORT" >/dev/null 2>&1 <<'PY' &
import http.server, ssl, sys, functools, threading
d, port, cert, key, hport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        for pre, target in (("/to-http/", f"http://127.0.0.1:{hport}/"), ("/to-https/", f"https://127.0.0.1:{port}/")):
            if self.path.startswith(pre):
                self.send_response(302); self.send_header("Location", target + self.path[len(pre):]); self.end_headers(); return
        super().do_GET()
h = functools.partial(H, directory=d)
plain = http.server.HTTPServer(("127.0.0.1", hport), h)
threading.Thread(target=plain.serve_forever, daemon=True).start()
s = http.server.HTTPServer(("127.0.0.1", port), h)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
s.socket = ctx.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
  SRV_PID=$!
  for _ in $(seq 50); do curl -s --cacert "$TMP/c.pem" -o /dev/null "https://127.0.0.1:$PORT/" && break; sleep 0.1; done
  got=$(CURL_CA_BUNDLE="$TMP/c.pem" _pack_fetch_url "https://127.0.0.1:$PORT/p.tar.gz?sig=x")
  if [[ -n "$got" && -f "$got" ]]; then
    eq_t 'an https link is downloaded to a local file' PACKBYTES "$(cat "$got")"; rm -f "$got"
  else
    bad_t 'an https link is downloaded to a local file' "rc=$? out=[$got]"
  fi
  if out=$(CURL_CA_BUNDLE="$TMP/c.pem" _pack_fetch_url "https://127.0.0.1:$PORT/missing.tar.gz"); then
    bad_t 'a 404 link fails the fetch' "out=[$out]"
  else
    ok_t 'a 404 link fails the fetch'
  fi
  # Redirects: https->https is followed (the control), https->http is refused.
  # The plain-http target serves the real bytes, so only --proto-redir stops it.
  got=$(CURL_CA_BUNDLE="$TMP/c.pem" _pack_fetch_url "https://127.0.0.1:$PORT/to-https/p.tar.gz?sig=x")
  if [[ -n "$got" && -f "$got" ]]; then
    eq_t 'an https->https redirect is followed' PACKBYTES "$(cat "$got")"; rm -f "$got"
  else
    bad_t 'an https->https redirect is followed' "out=[$got]"
  fi
  if [[ "$(curl -s "http://127.0.0.1:$HPORT/p.tar.gz")" != PACKBYTES ]]; then
    bad_t 'an https->http redirect is refused' 'plain-http target not serving; arm cannot grade'
  elif out=$(CURL_CA_BUNDLE="$TMP/c.pem" _pack_fetch_url "https://127.0.0.1:$PORT/to-http/p.tar.gz?sig=x"); then
    bad_t 'an https->http redirect is refused' "downgraded and fetched: $out"; rm -f "$out"
  else
    ok_t 'an https->http redirect is refused'
  fi
else
  ok_t 'SKIP live https fetch (no openssl/python3 on this host)'
fi

echo '== cmd_import seam =='
# Drive the real cmd_import through --from-url and the REAL safe-extract as far as
# cmd_create; every mutating boundary is replaced. cmd_create records its argv and
# returns non-zero so nothing is created.
mkdir -p "$TMP/pack"
printf '%s\n' '{"packFormat":1,"agentName":"maya","config":{"type":"claude","isolation":"standard"},"includes":{"memory":false}}' > "$TMP/pack/manifest.json"
printf 'You are Maya.\n' > "$TMP/pack/CLAUDE.md"
tar -czf "$TMP/maya.tar.gz" -C "$TMP/pack" .
export D5114_PACK="$TMP/maya.tar.gz" D5114_REC="$TMP/create.argv" D5114_FETCHED="$TMP/fetched"
require_root() { :; }
registry_read() { printf '%s\n' '{"agents":{}}'; }
_pack_harness_targets() { printf '%s\n' claude; }
_pack_targets_declared() { return 1; }
_pack_disclosure_json() { printf '%s\n' '{}'; }
_pack_disclosure_print() { :; }
_pack_rename_persona() { :; }
resolve_model_alias() { printf '%s' "$1"; }
is_known_type() { [[ "$1" == claude ]]; }
step() { :; }
_marketplace_fetch_pack() { echo "REGISTRY-HIT" > "$D5114_REC.registry"; return 1; }
_pack_fetch_url() { local t; t=$(mktemp --suffix=.tar.gz); cp "$D5114_PACK" "$t"; printf '%s\n%s\n' "$1" "$t" > "$D5114_FETCHED"; echo "$t"; }
cmd_create() { printf '%s\n' "$@" > "$D5114_REC"; return 1; }

( cmd_import --from-url="$SIGNED" --as=maya-a ) >/dev/null 2>&1
eq_t 'the signed link reaches the fetch verbatim' "$SIGNED" "$(sed -n 1p "$D5114_FETCHED" 2>/dev/null)"
grep -qx 'maya-a' "$D5114_REC" 2>/dev/null \
  && ok_t 'the fetched pack flows through safe-extract into cmd_create' \
  || bad_t 'the fetched pack flows through safe-extract into cmd_create' "argv: $(tr '\n' ' ' < "$D5114_REC" 2>/dev/null)"
[[ ! -e "$D5114_REC.registry" ]] \
  && ok_t 'a --from-url import never touches the public registry' \
  || bad_t 'a --from-url import never touches the public registry' 'registry fetch ran'
fetched_tmp=$(sed -n 2p "$D5114_FETCHED" 2>/dev/null)
[[ -n "$fetched_tmp" && ! -e "$fetched_tmp" ]] \
  && ok_t 'the downloaded tarball is removed after extract' \
  || bad_t 'the downloaded tarball is removed after extract' "still there: $fetched_tmp"

rm -f "$D5114_REC" "$D5114_FETCHED"
out=$( ( cmd_import --from-url='http://api.5dive.com/p.tar.gz' --as=maya-b ) 2>&1 )
rc=$?
{ (( rc != 0 )) && [[ ! -e "$D5114_FETCHED" ]] && grep -q 'https' <<<"$out"; } \
  && ok_t 'a plain-http link is refused before any fetch' \
  || bad_t 'a plain-http link is refused before any fetch' "rc=$rc out=$out"

out=$( ( cmd_import maya --from-url="$SIGNED" --as=maya-c ) 2>&1 ); rc=$?
{ (( rc != 0 )) && grep -q 'ONE of' <<<"$out"; } \
  && ok_t 'a slug plus --from-url is a usage error' \
  || bad_t 'a slug plus --from-url is a usage error' "rc=$rc out=$out"
out=$( ( cmd_import --from-persona="$TMP/pack/CLAUDE.md" --from-url="$SIGNED" --as=maya-d ) 2>&1 ); rc=$?
{ (( rc != 0 )) && grep -q 'ONE of' <<<"$out"; } \
  && ok_t '--from-persona plus --from-url is a usage error' \
  || bad_t '--from-persona plus --from-url is a usage error' "rc=$rc out=$out"

_pack_fetch_url() { return 1; }
out=$( ( cmd_import --from-url="$SIGNED" --as=maya-e ) 2>&1 ); rc=$?
(( rc != 0 )) && ok_t 'a failed fetch fails the import' || bad_t 'a failed fetch fails the import' "rc=$rc"
grep -q 'api.5dive.com' <<<"$out" && ! grep -q 'sig=' <<<"$out" \
  && ok_t 'the failure names the host and never echoes the signed link' \
  || bad_t 'the failure names the host and never echoes the signed link' "out=$out"

echo
printf 'DIVE-5114 pack import --from-url: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
