#!/usr/bin/env bash
# DIVE-7731: the marketplace image's one-time connect page
# (marketplace/image/files/usr/local/lib/5dive-claim/claim.py), driven over HTTP
# on loopback with every path moved into a temp dir: the root password is
# checked against a shadow file, a browser without it cannot link, wrong
# passwords lock the page for good, it expires, it links with the self-host line
# and then closes, and its route goes in and out of the Caddy front.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
claim_py="$PWD/marketplace/image/files/usr/local/lib/5dive-claim/claim.py"
tmp="$(mktemp -d)"
pids=()
cleanup() {
  local p
  for p in "${pids[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$tmp" 2>/dev/null || true
}
trap 'rc=$?; cleanup; echo "HARNESS-RC=$rc"; exit "$rc"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

PW='correct horse 7731'
hash_of() { python3 -I -c 'import ctypes,sys;l=ctypes.CDLL("libcrypt.so.1");l.crypt.restype=ctypes.c_char_p;l.crypt.argtypes=[ctypes.c_char_p,ctypes.c_char_p];print(l.crypt(sys.argv[1].encode(),b"$y$j9T$abcdefghijklmnop$").decode())' "$1"; }
HASH=$(hash_of "$PW")
[[ "$HASH" == '$y$'* ]] && ok "test rig: a yescrypt root hash" || bad "test rig: no yescrypt hash ($HASH)"

free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# One box: its own dirs, shadow, Caddy front, token file and link script.
box() { # <name> [<root shadow field>]
  local d="$tmp/$1" field="${2:-$HASH}"
  mkdir -p "$d/etc5" "$d/state"
  printf 'root:%s:20000:0:99999:7:::\nubuntu:!:20000::::::\n' "$field" > "$d/shadow"
  printf 'SECRET_HTTPS_MODE=ip\nSECRET_HTTPS_HOST=203.0.113.7\n' > "$d/etc5/secret-drop.env"
  printf '{\n\tadmin off\n}\n\nhttps://203.0.113.7 {\n\t@viewer path /browser/viewer/*\n\thandle @viewer {\n\t\treverse_proxy 127.0.0.1:3111\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:3127\n\t}\n}\n' > "$d/etc5/Caddyfile"
  # The self-host line's stand-in: checks the code it got, writes the token.
  cat > "$d/link.sh" <<EOF
#!/usr/bin/env bash
code="\$1"
echo "Linking this server to your 5dive.app account..."
[[ "\$code" == K7PM-4QXR ]] || { echo "error: That code is not valid or has expired." >&2; exit 1; }
printf 'CONNECTORD_TOKEN=%064d\n' 0 > "$d/etc5/connectord.env"
echo "Done."
EOF
  printf '%s' "$d"
}

start() { # <box dir> [extra env...] -> sets PORT, BOXD
  BOXD="$1"; shift
  PORT=$(free_port)
  env CLAIM_STATE_DIR="$BOXD/state" CLAIM_SHADOW="$BOXD/shadow" CLAIM_TOKEN_FILE="$BOXD/etc5/connectord.env" \
      CLAIM_SECRET_CONF="$BOXD/etc5/secret-drop.env" CLAIM_CADDYFILE="$BOXD/etc5/Caddyfile" \
      CLAIM_LINK_URL="file://$BOXD/link.sh" CLAIM_LINK_LOG="$BOXD/link.log" CLAIM_APP="https://my.example" \
      CLAIM_PORT="$PORT" CLAIM_NO_SYSTEMCTL=1 CLAIM_TICK_S=0.3 CLAIM_SHOWN_GRACE_S=1 CLAIM_CLI=/bin/false CLAIM_IPV4=203.0.113.7 "$@" \
      python3 -I "$claim_py" open >/dev/null 2>"$BOXD/open.err" || true
  env CLAIM_STATE_DIR="$BOXD/state" CLAIM_SHADOW="$BOXD/shadow" CLAIM_TOKEN_FILE="$BOXD/etc5/connectord.env" \
      CLAIM_SECRET_CONF="$BOXD/etc5/secret-drop.env" CLAIM_CADDYFILE="$BOXD/etc5/Caddyfile" \
      CLAIM_LINK_URL="file://$BOXD/link.sh" CLAIM_LINK_LOG="$BOXD/link.log" CLAIM_APP="https://my.example" \
      CLAIM_PORT="$PORT" CLAIM_NO_SYSTEMCTL=1 CLAIM_TICK_S=0.3 CLAIM_SHOWN_GRACE_S=1 CLAIM_CLI=/bin/false CLAIM_IPV4=203.0.113.7 "$@" \
      python3 -I "$claim_py" serve >/dev/null 2>"$BOXD/serve.err" &
  pids+=($!)
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/claim/healthz" && return 0; sleep 0.1; done
  echo "server did not start: $(cat "$BOXD/open.err" "$BOXD/serve.err")" >&2; return 1
}
U() { printf 'http://127.0.0.1:%s%s' "$PORT" "$1"; }
code_of() { curl -s -o "$tmp/body" -w '%{http_code}' "$@"; }
pw_post() { code_of -X POST --data-urlencode "password=$1" "$(U /claim/password)" -D "$tmp/hdr" "${@:2}"; }
status_of() { env CLAIM_STATE_DIR="$BOXD/state" python3 -I "$claim_py" status; }

# 1. The page opens on the box, with its route in the front.
start "$(box a)"
[[ "$(status_of)" == open ]] && ok "open: the claim is open" || bad "open: status $(status_of)"
grep -q '# 5dive-claim begin' "$BOXD/etc5/Caddyfile" && grep -q '@claim path / /claim /claim/\*' "$BOXD/etc5/Caddyfile" \
  && ok "open: the claim route is in the https front" || bad "open: no claim route in the front"
! grep -q '^http://' "$BOXD/etc5/Caddyfile" && ok "open (ip front): no extra http block, Caddy redirects http itself" \
  || bad "open (ip front): an http block was added"
c=$(code_of "$(U /)"); [[ "$c" == 200 ]] && grep -q 'root password' "$tmp/body" && grep -q 'type=password' "$tmp/body" \
  && ok "GET /: the password page" || bad "GET /: $c"
! grep -q 'no root password yet' "$tmp/body" && ok "GET /: no SSH-key tip on a server with a password" || bad "GET /: SSH-key tip shown wrongly"

# 2. A browser WITHOUT the password cannot link (the row's negative arm).
c=$(code_of -X POST --data "code=K7PM-4QXR&claim=$(printf 'x%.0s' $(seq 43))" "$(U /claim/finish)")
[[ "$c" == 403 && ! -e "$BOXD/etc5/connectord.env" ]] && ok "no password: a made-up claim cannot link (403, no token)" || bad "no password: finish answered $c"
c=$(code_of -X POST --data "code=K7PM-4QXR" "$(U /claim/finish)")
[[ "$c" == 403 ]] && ok "no password: no claim at all cannot link" || bad "no claim: finish answered $c"

# 3. A wrong password: 401, counted, says how many tries are left.
c=$(pw_post 'hunter2')
[[ "$c" == 401 ]] && grep -q '9 tries left' "$tmp/body" && ok "wrong password: 401, 9 tries left" || bad "wrong password: $c"
c=$(pw_post "$PW" -H 'Origin: https://evil.example')
[[ "$c" == 403 ]] && ok "the right password from another site's form: refused" || bad "cross-site password post: $c"

# 4. The right password: off to the 5dive app with the server and a one-time claim.
c=$(pw_post "$PW" -H 'Origin: https://203.0.113.7')
loc=$(tr -d '\r' < "$tmp/hdr" | sed -n 's/^Location: //Ip')
claim=$(sed -n 's/.*[?&]claim=\([A-Za-z0-9_-]*\).*/\1/p' <<<"$loc")
[[ "$c" == 303 && "$loc" == "https://my.example/self-host?server=203.0.113.7&claim="* && ${#claim} -ge 32 ]] \
  && ok "right password: 303 to the app's /self-host with server and claim" || bad "right password: $c $loc"
! grep -qi 'set-cookie' "$tmp/hdr" && ok "right password: no cookie (the claim is the proof)" || bad "right password: set a cookie"
! grep -rq "$PW" "$BOXD/state" "$BOXD/link.log" 2>/dev/null && ok "the password is stored nowhere" || bad "the password was written to disk"

# 5. A good claim with a code that is not one: refused, claim kept.
c=$(code_of -X POST --data "code=nope&claim=$claim" "$(U /claim/finish)")
[[ "$c" == 400 ]] && ok "finish: a malformed code is refused before anything runs" || bad "finish bad code: $c"

# 6. The link: the self-host line runs with the code, the server links, the page says so.
c=$(code_of -X POST --data "code=k7pm-4qxr&claim=$claim" "$(U /claim/finish)" -D "$tmp/hdr")
[[ "$c" == 303 ]] && grep -qi '^Location: /claim/linking' "$tmp/hdr" && ok "finish: 303 to the progress page" || bad "finish: $c"
for _ in $(seq 50); do code_of "$(U /claim/linking)" >/dev/null; grep -q 'Server connected' "$tmp/body" && break; sleep 0.1; done
grep -q 'Server connected' "$tmp/body" && grep -q 'href=.https://my.example/tg' "$tmp/body" \
  && ok "linking: Server connected, with Meet your team" || bad "linking never said connected: $(sed 's/<[^>]*>/ /g' "$tmp/body" | tr -s ' ' | head -c 200)"
grep -q '^CONNECTORD_TOKEN=' "$BOXD/etc5/connectord.env" && ok "the server holds its token" || bad "no token written"
c=$(code_of -X POST --data "code=K7PM-4QXR&claim=$claim" "$(U /claim/finish)")
[[ "$c" == 403 || "$c" == 410 ]] && ok "the same claim again: refused ($c), one link per server" || bad "claim replay: $c"

# 7. The page is gone after linking: closed, route out of the front, / answers 410.
for _ in $(seq 40); do [[ "$(status_of)" == closed:linked ]] && break; sleep 0.1; done
[[ "$(status_of)" == closed:linked ]] && ok "after linking: closed (linked)" || bad "after linking: status $(status_of)"
! grep -q '5dive-claim' "$BOXD/etc5/Caddyfile" && grep -q 'https://203.0.113.7 {' "$BOXD/etc5/Caddyfile" \
  && ok "after linking: the claim route left the front, the front stays" || bad "after linking: route still in the front"
sleep 0.5
c=$(curl -s -o /dev/null -w '%{http_code}' "$(U /)" || true)
[[ "$c" == 000 ]] && ok "after linking: the page process has exited" || bad "after linking: the page still answers ($c)"
c=0; env CLAIM_STATE_DIR="$BOXD/state" CLAIM_PORT="$(free_port)" CLAIM_NO_SYSTEMCTL=1 python3 -I "$claim_py" open >/dev/null 2>&1 || c=$?
[[ "$(status_of)" == closed:linked ]] && ok "after linking: open again does not reopen it" || bad "reopened after linking"

# 8. Brute force: MAX_FAILS wrong passwords close it for good, even for the right one.
start "$(box b)" CLAIM_MAX_FAILS=3
pw_post a >/dev/null; pw_post b >/dev/null; c=$(pw_post c)
[[ "$c" == 403 ]] && grep -q 'Too many wrong passwords' "$tmp/body" && ok "lockout: the 3rd wrong password locks it" || bad "lockout: $c"
# The route leaves only AFTER that answer: on a real box dropping it restarts
# Caddy, which cut this very request (seen live on a DO droplet: the 10th try got
# a dropped connection instead of the locked page).
grep -q '5dive-claim' "$BOXD/etc5/Caddyfile" && ok "lockout: the route is still in the front when the locked page is answered" \
  || bad "lockout: the route left the front before the answer, so Caddy's restart would cut it"
c=$(pw_post "$PW")
[[ "$c" == 410 && "$(status_of)" == closed:locked ]] && ok "lockout: the right password after it is refused (410, closed:locked)" || bad "after lockout: $c $(status_of)"
for _ in $(seq 40); do ! grep -q '5dive-claim' "$BOXD/etc5/Caddyfile" && break; sleep 0.1; done
! grep -q '5dive-claim' "$BOXD/etc5/Caddyfile" && grep -q 'https://203.0.113.7 {' "$BOXD/etc5/Caddyfile" \
  && ok "lockout: then the route leaves the front, the front stays" || bad "lockout: the route never left the front"

# 9. It expires: a page past its hours takes nothing.
start "$(box c)" CLAIM_OPEN_HOURS=0
c=$(pw_post "$PW")
[[ "$c" == 410 ]] && ok "expired: the right password is refused (410)" || bad "expired: $c"
for _ in $(seq 20); do [[ "$(status_of)" == closed:expired ]] && break; sleep 0.1; done
[[ "$(status_of)" == closed:expired ]] && ok "expired: closed (expired)" || bad "expired: status $(status_of)"

# 10. An SSH-key server (no root password): the page says how to get one without a terminal.
start "$(box d '*')"
code_of "$(U /)" >/dev/null
grep -q 'no root password yet' "$tmp/body" && grep -q 'Reset root password' "$tmp/body" \
  && ok "SSH-key server: the page says how to get a password (control panel, by email)" || bad "SSH-key server: no tip"
c=$(pw_post '*'); [[ "$c" == 401 ]] && ok "SSH-key server: no password matches '*'" || bad "SSH-key server: '*' answered $c"
printf 'root:%s:20000:0:99999:7:::\n' "$HASH" > "$BOXD/shadow"
c=$(pw_post "$PW"); [[ "$c" == 303 ]] && ok "SSH-key server: after a reset password, it works" || bad "after reset: $c"

# 11. A link that fails says why and lets the owner try again.
start "$(box e)"
pw_post "$PW" >/dev/null
claim=$(tr -d '\r' < "$tmp/hdr" | sed -n 's/^Location: .*[?&]claim=\([A-Za-z0-9_-]*\).*/\1/Ip')
code_of -X POST --data "code=AAAA-BBBB&claim=$claim" "$(U /claim/finish)" >/dev/null
for _ in $(seq 50); do code_of "$(U /claim/linking)" >/dev/null; grep -q 'Not connected yet' "$tmp/body" && break; sleep 0.1; done
grep -q 'not valid or has expired' "$tmp/body" && grep -q "href='/'" "$tmp/body" \
  && ok "failed link: the line's own error and Try again" || bad "failed link page: $(sed 's/<[^>]*>/ /g' "$tmp/body" | tr -s ' ' | head -c 200)"
[[ "$(status_of)" == open ]] && ok "failed link: the page stays open" || bad "failed link: status $(status_of)"

# 12. A server already linked another way never opens the page.
d=$(box f); printf 'CONNECTORD_TOKEN=%064d\n' 1 > "$d/etc5/connectord.env"
env CLAIM_STATE_DIR="$d/state" CLAIM_TOKEN_FILE="$d/etc5/connectord.env" CLAIM_NO_SYSTEMCTL=1 python3 -I "$claim_py" open >/dev/null 2>&1 || true
[[ "$(env CLAIM_STATE_DIR="$d/state" python3 -I "$claim_py" status)" == closed:linked-elsewhere ]] \
  && ok "already linked: never opens (closed:linked-elsewhere)" || bad "already linked: opened"

# 13. No https front (no name, the CLI's enable fails): no page, so no password over plain HTTP.
d=$(box g); : > "$d/etc5/secret-drop.env"
env CLAIM_STATE_DIR="$d/state" CLAIM_TOKEN_FILE="$d/etc5/connectord.env" CLAIM_SECRET_CONF="$d/etc5/secret-drop.env" \
    CLAIM_CADDYFILE="$d/etc5/Caddyfile" CLAIM_CLI=/bin/false CLAIM_NO_SYSTEMCTL=1 python3 -I "$claim_py" open >/dev/null 2>&1 || true
[[ "$(env CLAIM_STATE_DIR="$d/state" python3 -I "$claim_py" status)" == closed:no-https ]] \
  && ok "no https front: the page stays shut (closed:no-https)" || bad "no https front: $(env CLAIM_STATE_DIR="$d/state" python3 -I "$claim_py" status)"

# 14. An sslip.io front: the bare IP over http goes to the https name.
out=$(python3 -I - "$claim_py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("claim", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base = "{\n\tadmin off\n}\n\nhttps://203-0-113-7.sslip.io {\n\thandle {\n\t\treverse_proxy 127.0.0.1:3127\n\t}\n}\n"
t = m.with_route(base, "203-0-113-7.sslip.io", "203.0.113.7")
assert "http://203.0.113.7 {\n\tredir https://203-0-113-7.sslip.io{uri} 302\n}" in t, t
assert m.strip_route(t) == base, repr(m.strip_route(t))
assert m.with_route(t, "203-0-113-7.sslip.io", "203.0.113.7") == t, "not idempotent"
assert m.with_route(base, "other.host", None) is None
print("ok")
PY
)
[[ "$out" == ok ]] && ok "sslip front: http://<ip> redirects to the name; route in and out is exact and idempotent" || bad "sslip route: $out"

echo "# $pass passed, $fail failed"
(( fail == 0 ))
