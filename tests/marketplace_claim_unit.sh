#!/usr/bin/env bash
# DIVE-7756: the marketplace image's one-time connect job
# (marketplace/image/files/usr/local/lib/5dive-claim/claim.py), driven against a
# fake Vultr metadata service and a fake 5dive API on loopback. What it proves:
# the code is read only with Vultr's header, registered and polled over the API,
# the link line runs only once the owner has connected, after first boot, and
# with the API's one-time code; every refusal stops the job without a link; the
# codes are never written to the log or the state dir; nothing asks for a password.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
tmp="$(mktemp -d)"
srv_pid=""
trap 'rc=$?; [[ -n "$srv_pid" ]] && kill "$srv_pid" 2>/dev/null; rm -rf "$tmp"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1" >&2; }

claim=marketplace/image/files/usr/local/lib/5dive-claim/claim.py
unit=marketplace/image/files/etc/systemd/system/5dive-claim.service
CODE=k8MSrSRVUJbwtFjc1YYzC9oQrZbDXnJa
ACCT=K7PM-4QXR

# The fake: GET /meta (Vultr metadata: 403 without its header), POST
# /connector/claim/register and /poll (answers scripted per scenario in
# $tmp/scenario), GET /link (a link step that writes the token file with the
# code it was given). Every request is appended to $tmp/requests.
cat > "$tmp/fake.py" <<'PY'
import http.server, json, os, sys
D = sys.argv[1]
def scen():
    return open(os.path.join(D, "scenario")).read().strip()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def rec(self, line):
        with open(os.path.join(D, "requests"), "a") as f: f.write(line + "\n")
    def send(self, st, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(st); self.send_header("content-type", ctype); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        s = scen()
        if self.path == "/meta":
            self.rec("GET /meta hdr=%s" % self.headers.get("METADATA-TOKEN"))
            if self.headers.get("METADATA-TOKEN") != "vultr": return self.send(403, "forbidden", "text/plain")
            if s == "nocode": return self.send(404, "not found", "text/plain")
            if s == "badcode": return self.send(200, "k8MS#rSRVUJbwtFjc1YYz", "text/plain")
            return self.send(200, "k8MSrSRVUJbwtFjc1YYzC9oQrZbDXnJa\n", "text/plain")
        if self.path == "/link":
            self.rec("GET /link")
            tok = os.path.join(D, "connectord.env")
            return self.send(200, '#!/bin/bash\necho "link ran with $# arg"\n[[ "$1" == K7PM-4QXR ]] || exit 7\necho CONNECTORD_TOKEN=0123456789abcdef0123 > %s\n' % tok, "text/x-shellscript")
        self.send(404, {})
    def do_POST(self):
        s = scen()
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"null")
        ok_code = body.get("code") == "k8MSrSRVUJbwtFjc1YYzC9oQrZbDXnJa"
        self.rec("POST %s code_ok=%s" % (self.path, ok_code))
        if self.path == "/connector/claim/register":
            if s == "blocked": return self.send(403, {"error": "blocked"})
            if s == "expired": return self.send(200, {"state": "expired"})
            return self.send(200, {"state": "waiting"})
        if self.path == "/connector/claim/poll":
            n_file = os.path.join(D, "polls"); n = int(open(n_file).read()) + 1 if os.path.exists(n_file) else 1
            open(n_file, "w").write(str(n))
            if s == "used": return self.send(410, {"state": "used"})
            if s in ("happy", "late") and n >= 2: return self.send(200, {"state": "code", "code": "K7PM-4QXR", "command": "x"})
            return self.send(200, {"state": "waiting"})
        self.send(404, {})
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 -I "$tmp/fake.py" "$tmp" >/dev/null 2>&1 &
srv_pid=$!
for _ in $(seq 50); do [[ -s "$tmp/port" ]] && break; sleep 0.1; done
port=$(cat "$tmp/port")
base="http://127.0.0.1:$port"

# One run of the job in scenario $1, its own state dir; extra env after.
run() {
  local s="$1"; shift
  echo "$s" > "$tmp/scenario"
  rm -rf "$tmp/state" "$tmp/connectord.env" "$tmp/polls" "$tmp/claim.log"; : > "$tmp/requests"
  mkdir -p "$tmp/state"; touch "$tmp/state/firstboot-done"
  env -i PATH="$PATH" CLAIM_API="$base" CLAIM_META_URL="$base/meta" CLAIM_LINK_URL="$base/link" \
    CLAIM_STATE_DIR="$tmp/state" CLAIM_TOKEN_FILE="$tmp/connectord.env" CLAIM_LOG="$tmp/claim.log" \
    CLAIM_FIRSTBOOT_DONE="$tmp/state/firstboot-done" CLAIM_POLL_S=0.05 CLAIM_SLOW_POLL_S=0.05 \
    CLAIM_GIVE_UP_S=20 CLAIM_FIRSTBOOT_WAIT_S=5 CLAIM_META_TRIES=2 "$@" \
    timeout 60 python3 -I "$claim"
}
closed() { cat "$tmp/state/closed" 2>/dev/null || echo "<not closed>"; }
no_secret_on_disk() {
  if grep -rqF -e "$CODE" -e "$ACCT" "$tmp/claim.log" "$tmp/state" 2>/dev/null; then bad "$1: a code was written to disk"; else ok "$1: no code in the log or state"; fi
}

# 0. It parses, and the unit runs it isolated.
python3 -I -m py_compile "$claim" && ok "claim.py compiles" || bad "claim.py does not compile"
grep -q '^ExecStart=/usr/bin/python3 -I /usr/local/lib/5dive-claim/claim.py$' "$unit" && ok "unit runs claim.py with -I" || bad "unit ExecStart"
grep -q '^ConditionPathExists=!/var/lib/5dive-claim/closed$' "$unit" && ok "unit stays off once closed" || bad "unit closed condition"

# 1. Happy path: header-only metadata, register, wait, take the one-time code, link once.
rc=0; run happy || rc=$?
[[ $rc -eq 0 ]] && ok "happy: exits 0" || bad "happy: rc=$rc"
grep -q '^GET /meta hdr=vultr$' "$tmp/requests" && ok "happy: metadata asked with Vultr's header" || bad "happy: no header on the metadata call"
grep -q '^POST /connector/claim/register code_ok=True$' "$tmp/requests" && ok "happy: registered with its code" || bad "happy: register"
[[ $(grep -c '^POST /connector/claim/poll code_ok=True$' "$tmp/requests") -ge 2 ]] && ok "happy: polled until the owner connected" || bad "happy: polls"
[[ $(grep -c '^GET /link$' "$tmp/requests") -eq 1 ]] && ok "happy: the link step ran once" || bad "happy: link ran $(grep -c '^GET /link$' "$tmp/requests") times"
grep -q '^CONNECTORD_TOKEN=' "$tmp/connectord.env" 2>/dev/null && ok "happy: linked with the API's one-time code" || bad "happy: not linked"
[[ $(closed) == linked ]] && ok "happy: closed as linked" || bad "happy: closed=$(closed)"
no_secret_on_disk happy

# 2. Closed already: nothing is asked of anyone.
rc=0; echo happy > "$tmp/scenario"; : > "$tmp/requests"
env -i PATH="$PATH" CLAIM_API="$base" CLAIM_META_URL="$base/meta" CLAIM_STATE_DIR="$tmp/state" \
  CLAIM_TOKEN_FILE="$tmp/none" CLAIM_LOG="$tmp/claim.log" timeout 20 python3 -I "$claim" || rc=$?
[[ $rc -eq 0 && ! -s "$tmp/requests" ]] && ok "closed: a second start does nothing" || bad "closed: rc=$rc requests=$(wc -l <"$tmp/requests")"

# 3. Linked another way first (the login line): it closes without a call.
rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/requests"
echo CONNECTORD_TOKEN=0123456789abcdef0123 > "$tmp/pre.env"
env -i PATH="$PATH" CLAIM_API="$base" CLAIM_META_URL="$base/meta" CLAIM_STATE_DIR="$tmp/state" \
  CLAIM_TOKEN_FILE="$tmp/pre.env" CLAIM_LOG="$tmp/claim.log" timeout 20 python3 -I "$claim" || true
[[ ! -s "$tmp/requests" && $(closed) == linked ]] && ok "linked elsewhere: closes, no call" || bad "linked elsewhere: closed=$(closed)"

# 4. No code from the hoster (DigitalOcean, or a server without the variable): stops, never registers.
for s in nocode badcode; do
  run "$s" || true
  ! grep -q '/connector/' "$tmp/requests" && [[ $(closed) == "no code from the hoster" ]] \
    && ok "$s: stops without calling 5dive" || bad "$s: closed=$(closed)"
done

# 5. Refusals: a used code, an expired one, a blocked server. No link runs.
for s in used expired blocked; do
  run "$s" || true
  ! grep -q '^GET /link$' "$tmp/requests" && [[ -f "$tmp/state/closed" ]] && [[ ! -e "$tmp/connectord.env" ]] \
    && ok "$s: stops, no link (closed: $(closed))" || bad "$s: link ran or not closed ($(closed))"
  no_secret_on_disk "$s"
done

# 6. The owner connects during first boot: the link waits for first boot's done mark.
echo late > "$tmp/scenario"
rm -rf "$tmp/state" "$tmp/connectord.env" "$tmp/polls"; : > "$tmp/requests"; mkdir -p "$tmp/state"
( sleep 2; touch "$tmp/state/firstboot-done"; date +%s.%N > "$tmp/done-at" ) &
marker_pid=$!
env -i PATH="$PATH" CLAIM_API="$base" CLAIM_META_URL="$base/meta" CLAIM_LINK_URL="$base/link" \
  CLAIM_STATE_DIR="$tmp/state" CLAIM_TOKEN_FILE="$tmp/connectord.env" CLAIM_LOG="$tmp/claim.log" \
  CLAIM_FIRSTBOOT_DONE="$tmp/state/firstboot-done" CLAIM_POLL_S=0.05 CLAIM_SLOW_POLL_S=0.05 \
  CLAIM_FIRSTBOOT_WAIT_S=30 CLAIM_META_TRIES=2 timeout 60 python3 -I "$claim" || true
linked_at=$(stat -c %Y.%N "$tmp/connectord.env" 2>/dev/null | cut -d. -f1)
done_at=$(cut -d. -f1 "$tmp/done-at" 2>/dev/null || echo 0)
[[ -n "$linked_at" && "$linked_at" -ge "$done_at" && "$done_at" -gt 0 ]] && ok "first boot: the link ran after its done mark" \
  || bad "first boot: linked_at=$linked_at done_at=$done_at"
wait "$marker_pid" || true

# 7. No password anywhere in the job.
if grep -qiE 'passw|shadow|crypt\(' "$claim"; then bad "claim.py mentions a password or the shadow file"; else ok "claim.py never touches a password"; fi

# 8. The image wires it: build installs it off, first boot starts it and marks done, clean-up resets it.
grep -q 'files/usr/local/lib/5dive-claim/claim.py" /usr/local/lib/5dive-claim/claim.py' marketplace/image/build.sh && ok "build installs claim.py" || bad "build: claim.py"
grep -q 'systemctl enable --now --no-block 5dive-claim.service' marketplace/image/firstboot.sh && ok "first boot starts the job" || bad "first boot: start"
grep -q 'touch "$claim_dir/firstboot-done"' marketplace/image/firstboot.sh && ok "first boot marks itself done" || bad "first boot: done mark"
! grep -q 'systemctl enable' marketplace/image/build.sh && ok "build never enables it (the build server must not claim)" || bad "build enables a unit"
root="$tmp/root"; mkdir -p "$root/var/lib/5dive-claim" "$root/etc/systemd/system/multi-user.target.wants" "$root/var/log" "$root/etc"
touch "$root/var/lib/5dive-claim/closed" "$root/var/log/5dive-claim.log" "$root/etc/systemd/system/multi-user.target.wants/5dive-claim.service" "$root/etc/machine-id"
IMAGE_ROOT="$root" bash marketplace/image/cleanup.sh >/dev/null 2>&1 || true
[[ ! -e "$root/var/lib/5dive-claim" && ! -e "$root/var/log/5dive-claim.log" && ! -e "$root/etc/systemd/system/multi-user.target.wants/5dive-claim.service" ]] \
  && ok "clean-up resets the job for the next server" || bad "clean-up left the job's state"

echo "# pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
