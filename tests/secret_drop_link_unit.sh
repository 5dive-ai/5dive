#!/usr/bin/env bash
# DIVE-5319 unit harness: the one-time secret drop link served by the BOX.
#   * `secret link` mints a link for an open secret gate: https://secrets.<box>/<token>,
#     only the token's SHA-256 stored, root-only store, bound to task+KEY+connector.
#   * `secret _peek` / `secret _redeem` (the page's two calls): expiry, gate re-check,
#     single use (every link for the gate burns), a refused value burns nothing.
#   * the page itself (python, loopback): GET form + headers, POST writes the value
#     exactly once, never echoes it, never logs the token, 404/410/429.
#   * the Caddy route for secrets.<domain>: appended once, restored on a bad validate.
#   * `secret write` at a terminal asks with hidden input (the no-domain fallback).
# Isolation: src/ libs sourced, throwaway STATE_DIR / connectors dir / Caddyfile;
# `5dive` (task answer) and `caddy` are mocks on PATH. No root, no network beyond
# 127.0.0.1. Run: bash tests/secret_drop_link_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP="$(mktemp -d /tmp/secret-drop-link-unit.XXXXXX)"

LIBS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/self.sh cmd_task.sh cmd_secret.sh cmd_secret_drop.sh"
for f in $LIBS; do
  # shellcheck source=/dev/null
  source "src/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable)\n' >&2

# The box, in TMP. Every path the verbs read is pointed here.
export STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
export CONNECTORS_DIR="$TMP/connectors"
SECRET_DROP_DIR="$STATE_DIR/secret-drop"
SECRET_DROP_CONF="$TMP/secret-drop.env"
SECRET_DROP_PROVISIONING="$TMP/provisioning.env"
SECRET_DROP_CADDYFILE="$TMP/Caddyfile"
SECRET_DROP_LOCK="$TMP/drop.lock"
SECRET_WRITE_LOCK="$TMP/write.lock"
printf 'FIVE_DOMAIN=teal-fox.example.com\n' > "$SECRET_DROP_PROVISIONING"
require_root() { :; }
JSON_MODE=1
set +e

MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
export MOCK5DIVE_LOG="$TMP/5dive-calls.log"; : > "$MOCK5DIVE_LOG"
cat > "$MOCKBIN/5dive" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK5DIVE_LOG"
EOF
chmod +x "$MOCKBIN/5dive"
PATH="$MOCKBIN:$PATH"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
seed_gate() {   # <ident> <key> <connector>
  db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','todo','main','mailer');"
  cmd_task_need "$1" --type=secret --ask="Gmail app password for the inbox" --secret-key="$2" --connector="$3" >/dev/null 2>&1
  db "UPDATE tasks SET assignee='mailer' WHERE ident='$1';"
}
mint() { ( _secret_link "$@" --no-start ) 2>&1; }
tok_of() { printf '%s' "$1" | jq -r '.data.url // empty' | sed 's#.*/##'; }
hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# --- L1: a link for an open gate ---------------------------------------------
seed_gate DIVE-11 GMAIL_APP_PASSWORD gmail
out=$(mint DIVE-11); rc=$?
url=$(printf '%s' "$out" | jq -r '.data.url // empty')
tok=$(tok_of "$out")
[[ $rc -eq 0 && "$url" =~ ^https://secrets\.teal-fox\.example\.com/[A-Za-z0-9_-]{43}$ ]] \
  && ok_t "L1a link is https://secrets.<FIVE_DOMAIN>/<43-char token>" \
  || bad_t "L1a link is https://secrets.<FIVE_DOMAIN>/<43-char token>" "rc=$rc out=$out"
h=$(hash_of "$tok")
[[ -f "$SECRET_DROP_DIR/$h" && "$(ls "$SECRET_DROP_DIR" | wc -l)" == 1 ]] \
  && ok_t "L1b the store holds one entry, named by the token's SHA-256" \
  || bad_t "L1b the store holds one entry, named by the token's SHA-256" "ls: $(ls "$SECRET_DROP_DIR")"
[[ -n "$tok" ]] && ! grep -rqF -- "$tok" "$STATE_DIR" \
  && ok_t "L1c the raw token is stored nowhere on the box (store, tasks.db)" \
  || bad_t "L1c the raw token is stored nowhere on the box (store, tasks.db)" "found it under $STATE_DIR"
[[ "$(stat -c %a "$SECRET_DROP_DIR")" == 700 && "$(stat -c %a "$SECRET_DROP_DIR/$h")" == 600 ]] \
  && ok_t "L1d store dir 700, entry 600" \
  || bad_t "L1d store dir 700, entry 600" "$(stat -c '%a %n' "$SECRET_DROP_DIR" "$SECRET_DROP_DIR/$h")"
grep -qx 'task=DIVE-11' "$SECRET_DROP_DIR/$h" && grep -qx 'key=GMAIL_APP_PASSWORD' "$SECRET_DROP_DIR/$h" \
  && grep -qx 'connector=gmail' "$SECRET_DROP_DIR/$h" \
  && ok_t "L1e the link is bound to the gate: task, KEY and connector" \
  || bad_t "L1e the link is bound to the gate: task, KEY and connector" "$(cat "$SECRET_DROP_DIR/$h")"
exp=$(sed -n 's/^expires=//p' "$SECRET_DROP_DIR/$h"); now=$(date +%s)
(( exp > now + 1700 && exp <= now + 1800 )) \
  && ok_t "L1f default expiry is 30 minutes" || bad_t "L1f default expiry is 30 minutes" "exp-now=$((exp-now))"

# --- L2: what is refused ------------------------------------------------------
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-12','t','todo','main');"
out=$(mint DIVE-12); rc=$?
[[ $rc -eq $E_CONFLICT && "$out" == *"no secret gate open"* ]] && ok_t "L2a no secret gate -> refused" \
  || bad_t "L2a no secret gate -> refused" "rc=$rc out=$out"
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-13','t','todo','main');"
cmd_task_need DIVE-13 --type=secret --ask="x" --out-of-band="my own vault" >/dev/null 2>&1
out=$(mint DIVE-13); rc=$?
[[ $rc -eq $E_CONFLICT && "$out" == *"out-of-band"* ]] && ok_t "L2b an out-of-band gate has nowhere to write -> refused" \
  || bad_t "L2b an out-of-band gate has nowhere to write -> refused" "rc=$rc out=$out"
out=$(mint DIVE-11 --ttl=0); rc=$?; out2=$(mint DIVE-11 --ttl=61); rc2=$?
[[ $rc -eq $E_VALIDATION && $rc2 -eq $E_VALIDATION ]] && ok_t "L2c ttl outside 1-60 refused" \
  || bad_t "L2c ttl outside 1-60 refused" "rc=$rc/$rc2"
mv "$SECRET_DROP_PROVISIONING" "$TMP/prov.off"
out=$(mint DIVE-11); rc=$?
[[ $rc -eq $E_NOT_INSTALLED && "$out" == *"sudo 5dive secret write GMAIL_APP_PASSWORD --connector=gmail --task=DIVE-11"* ]] \
  && ok_t "L2d no reachable name -> refused, and it names the terminal path" \
  || bad_t "L2d no reachable name -> refused, and it names the terminal path" "rc=$rc out=$out"
printf 'SECRET_DROP_BASE_URL=http://192.0.2.5:8080\n' > "$SECRET_DROP_CONF"
out=$(mint DIVE-11); rc=$?
[[ $rc -eq $E_NOT_INSTALLED ]] && ok_t "L2e a plain-http base URL is refused (the value would cross in clear)" \
  || bad_t "L2e a plain-http base URL is refused (the value would cross in clear)" "rc=$rc out=$out"
printf 'SECRET_DROP_BASE_URL=https://box.example.net/drop\n' > "$SECRET_DROP_CONF"
out=$(mint DIVE-11); url=$(printf '%s' "$out" | jq -r '.data.url // empty')
[[ "$url" =~ ^https://box\.example\.net/drop/[A-Za-z0-9_-]{43}$ ]] \
  && ok_t "L2f a self-hosted box's https base URL (its own tunnel) is used" \
  || bad_t "L2f a self-hosted box's https base URL (its own tunnel) is used" "out=$out"
rm -f "$SECRET_DROP_CONF"; mv "$TMP/prov.off" "$SECRET_DROP_PROVISIONING"
printf 'FIVE_DOMAIN=a.example.com { }\n' > "$TMP/prov.bad"
d=$(SECRET_DROP_PROVISIONING="$TMP/prov.bad" _secret_drop_domain); rc=$?
[[ $rc -ne 0 && -z "$d" ]] && ok_t "L2g a domain with spaces or braces is refused (no Caddyfile injection)" \
  || bad_t "L2g a domain with spaces or braces is refused (no Caddyfile injection)" "rc=$rc d=$d"

# --- L3: _peek ------------------------------------------------------------------
rm -rf "$SECRET_DROP_DIR"
out=$(mint DIVE-11); tok=$(tok_of "$out"); h=$(hash_of "$tok")
out=$( ( _secret_drop_peek --hash="$h" ) 2>&1 ); rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.key')" == GMAIL_APP_PASSWORD \
   && "$(printf '%s' "$out" | jq -r '.data.agent')" == mailer && -f "$SECRET_DROP_DIR/$h" ]] \
  && ok_t "L3a peek a live link: what it is for, and it does not burn" \
  || bad_t "L3a peek a live link: what it is for, and it does not burn" "rc=$rc out=$out"
( _secret_drop_peek --hash="$(hash_of nope)" ) >/dev/null 2>&1; rc=$?
( _secret_drop_peek --hash="../../etc/passwd" ) >/dev/null 2>&1; rc2=$?
[[ $rc -eq $E_NOT_FOUND && $rc2 -eq $E_NOT_FOUND ]] && ok_t "L3b unknown or malformed hash -> not found" \
  || bad_t "L3b unknown or malformed hash -> not found" "rc=$rc/$rc2"
sed -i "s/^expires=.*/expires=$(( $(date +%s) - 5 ))/" "$SECRET_DROP_DIR/$h"
( _secret_drop_peek --hash="$h" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_TIMEOUT && ! -f "$SECRET_DROP_DIR/$h" ]] && ok_t "L3c an expired link is refused and deleted" \
  || bad_t "L3c an expired link is refused and deleted" "rc=$rc"

# --- L4: _redeem ----------------------------------------------------------------
rm -rf "$SECRET_DROP_DIR"; : > "$MOCK5DIVE_LOG"
out=$(mint DIVE-11); tok1=$(tok_of "$out")
out=$(mint DIVE-11); tok2=$(tok_of "$out")
printf 'line one\nline two' | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_VALIDATION && -f "$SECRET_DROP_DIR/$(hash_of "$tok1")" && ! -s "$CONNECTORS_DIR/gmail.env" ]] \
  && ok_t "L4a a multi-line value is refused, nothing written, the link still works" \
  || bad_t "L4a a multi-line value is refused, nothing written, the link still works" "rc=$rc"
VALUE='abcd efgh ijkl mnop'
printf '%s' "$VALUE" | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) > "$TMP/redeem.out" 2>&1; rc=$?
[[ $rc -eq 0 && "$(grep -cxF "GMAIL_APP_PASSWORD=$VALUE" "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L4b a redeem writes the value exactly once into the gate's connector file" \
  || bad_t "L4b a redeem writes the value exactly once into the gate's connector file" "rc=$rc env=$(cat "$CONNECTORS_DIR/gmail.env" 2>/dev/null)"
! grep -qF "$VALUE" "$TMP/redeem.out" && ok_t "L4c the redeem's output never carries the value" \
  || bad_t "L4c the redeem's output never carries the value" "$(cat "$TMP/redeem.out")"
grep -q 'task answer DIVE-11 --human --from=drop' "$MOCK5DIVE_LOG" \
  && ok_t "L4d the write clears the gate (task answer --from=drop)" \
  || bad_t "L4d the write clears the gate (task answer --from=drop)" "calls: $(cat "$MOCK5DIVE_LOG")"
[[ ! -e "$SECRET_DROP_DIR/$(hash_of "$tok1")" && ! -e "$SECRET_DROP_DIR/$(hash_of "$tok2")" ]] \
  && ok_t "L4e single use: every link for the gate burns, not only the one used" \
  || bad_t "L4e single use: every link for the gate burns, not only the one used" "ls: $(ls "$SECRET_DROP_DIR")"
printf 'second' | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_NOT_FOUND && "$(grep -c '^GMAIL_APP_PASSWORD=' "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L4f a second use is refused and writes nothing" \
  || bad_t "L4f a second use is refused and writes nothing" "rc=$rc"
out=$(mint DIVE-11); tok=$(tok_of "$out")
db "UPDATE tasks SET need_answered_at=datetime('now') WHERE ident='DIVE-11';"
printf 'late' | ( _secret_drop_redeem --hash="$(hash_of "$tok")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_CONFLICT && ! -e "$SECRET_DROP_DIR/$(hash_of "$tok")" ]] && ! grep -q '=late$' "$CONNECTORS_DIR/gmail.env" \
  && ok_t "L4g gate answered after the mint -> refused, link burned, nothing written" \
  || bad_t "L4g gate answered after the mint -> refused, link burned, nothing written" "rc=$rc"
db "UPDATE tasks SET need_answered_at=NULL WHERE ident='DIVE-11';"
out=$(mint DIVE-11); tok=$(tok_of "$out")
db "UPDATE tasks SET secret_key='OTHER_KEY' WHERE ident='DIVE-11';"
printf 'moved' | ( _secret_drop_redeem --hash="$(hash_of "$tok")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_CONFLICT ]] && ! grep -q '=moved$' "$CONNECTORS_DIR/gmail.env" \
  && ok_t "L4h gate re-pointed to another KEY after the mint -> refused (the link is bound)" \
  || bad_t "L4h gate re-pointed to another KEY after the mint -> refused (the link is bound)" "rc=$rc"
db "UPDATE tasks SET secret_key='GMAIL_APP_PASSWORD' WHERE ident='DIVE-11';"

# --- L5: the page (live python server on loopback) ---------------------------
WRAP="$TMP/5dive-bundle"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
cd "$REPO"
for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"
SECRET_DROP_DIR="$SECRET_DROP_DIR"; SECRET_DROP_LOCK="$SECRET_DROP_LOCK"; SECRET_WRITE_LOCK="$SECRET_WRITE_LOCK"
PATH="$MOCKBIN:\$PATH"; export MOCK5DIVE_LOG="$MOCK5DIVE_LOG"
require_root() { :; }
shift   # the page calls "<bundle> secret <sub> ..."
args=(); for a in "\$@"; do [[ "\$a" == --json ]] && JSON_MODE=1 || args+=("\$a"); done
cmd_secret "\${args[@]}"
EOF
chmod +x "$WRAP"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
_secret_drop_server_py > "$TMP/server.py"
python3 "$TMP/server.py" 127.0.0.1 "$PORT" "$WRAP" "$SECRET_DROP_DIR" 0 2> "$TMP/server.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
rm -rf "$SECRET_DROP_DIR"; rm -f "$CONNECTORS_DIR/gmail.env"; : > "$MOCK5DIVE_LOG"
out=$(mint DIVE-11); tok=$(tok_of "$out")
B="http://127.0.0.1:$PORT"
code=$(curl -s -o "$TMP/page.html" -D "$TMP/page.hdr" -w '%{http_code}' "$B/$tok")
[[ "$code" == 200 ]] && grep -q 'type=password name=value' "$TMP/page.html" && grep -q 'mailer needs GMAIL_APP_PASSWORD' "$TMP/page.html" \
  && ok_t "L5a GET shows a masked field and who asks for which KEY" \
  || bad_t "L5a GET shows a masked field and who asks for which KEY" "code=$code $(head -c 400 "$TMP/page.html")"
grep -qi '^cache-control: no-store' "$TMP/page.hdr" && grep -qi '^referrer-policy: no-referrer' "$TMP/page.hdr" \
  && grep -qi "^content-security-policy: default-src 'none'" "$TMP/page.hdr" && grep -qi '^x-frame-options: DENY' "$TMP/page.hdr" \
  && ok_t "L5b no-store, no-referrer, CSP default-src none, no framing" \
  || bad_t "L5b no-store, no-referrer, CSP default-src none, no framing" "$(cat "$TMP/page.hdr")"
VALUE='s3cr3t-Value_9 with space'
code=$(curl -s -o "$TMP/post.html" -w '%{http_code}' --data-urlencode "value=$VALUE" "$B/$tok")
[[ "$code" == 200 && "$(grep -cxF "GMAIL_APP_PASSWORD=$VALUE" "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L5c POST lands the value exactly once in the connector file" \
  || bad_t "L5c POST lands the value exactly once in the connector file" "code=$code env=$(cat "$CONNECTORS_DIR/gmail.env" 2>/dev/null) body=$(head -c 300 "$TMP/post.html")"
! grep -qF "$VALUE" "$TMP/post.html" && ! grep -qF "$VALUE" "$TMP/server.log" \
  && ok_t "L5d the value is in neither the response nor the server log" \
  || bad_t "L5d the value is in neither the response nor the server log" "leaked"
! grep -qF "$tok" "$TMP/server.log" && ok_t "L5e the token (the path) is never logged" \
  || bad_t "L5e the token (the path) is never logged" "$(cat "$TMP/server.log")"
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "value=again" "$B/$tok")
[[ "$code" == 404 && "$(grep -c '^GMAIL_APP_PASSWORD=' "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L5f the link is dead after one use (404, nothing written)" \
  || bad_t "L5f the link is dead after one use (404, nothing written)" "code=$code"
out=$(mint DIVE-11); tok=$(tok_of "$out")
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "value=" "$B/$tok")
[[ "$code" == 400 && -f "$SECRET_DROP_DIR/$(hash_of "$tok")" ]] && ok_t "L5g an empty paste is refused and keeps the link" \
  || bad_t "L5g an empty paste is refused and keeps the link" "code=$code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$B/$tok")
[[ "$code" == 405 ]] && ok_t "L5h other methods -> 405" || bad_t "L5h other methods -> 405" "code=$code"
codes=""
for i in $(seq 1 11); do codes+="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 192.0.2.9' "$B/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA$i") "; done
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 192.0.2.9' "$B/$tok")
code2=$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 192.0.2.7' "$B/$tok")
[[ "$codes" == *"404 "* && "$code" == 429 && "$code2" == 200 ]] \
  && ok_t "L5i ten failed lookups from one client -> 429 for it, others unaffected" \
  || bad_t "L5i ten failed lookups from one client -> 429 for it, others unaffected" "codes=$codes then=$code other=$code2"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- L6: idle exit ---------------------------------------------------------------
# A real run with --idle-exit would take 15s+ per poll; instead the page is run
# against an EMPTY store with a 1s idle and must be gone by the first poll tick.
rm -rf "$SECRET_DROP_DIR"; mkdir -p "$SECRET_DROP_DIR"
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
sed 's/time.sleep(15)/time.sleep(0.2)/; s/quiet + 15/quiet + 1/' "$TMP/server.py" > "$TMP/server-fast.py"
timeout 10 python3 "$TMP/server-fast.py" 127.0.0.1 "$PORT2" "$WRAP" "$SECRET_DROP_DIR" 1 2>/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok_t "L6 the page exits by itself once no link is live (no standing listener)" \
  || bad_t "L6 the page exits by itself once no link is live (no standing listener)" "rc=$rc (124 = still running)"

# --- L7: the Caddy route --------------------------------------------------------
cat > "$MOCKBIN/caddy" <<'EOF'
#!/usr/bin/env bash
[[ "${CADDY_VALIDATE_FAIL:-0}" == 1 ]] && exit 1; exit 0
EOF
chmod +x "$MOCKBIN/caddy"
printf 'teal-fox.example.com {\n    handle /shell/* {\n        reverse_proxy localhost:3101\n    }\n}\n' > "$SECRET_DROP_CADDYFILE"
systemd-run() { :; }; systemctl() { :; }
_secret_drop_ensure_route; _secret_drop_ensure_route
[[ "$(grep -c '^secrets\.teal-fox\.example\.com {' "$SECRET_DROP_CADDYFILE")" == 1 ]] \
  && grep -q "reverse_proxy 127.0.0.1:${SECRET_DROP_PORT}" "$SECRET_DROP_CADDYFILE" \
  && ok_t "L7a secrets.<domain> is routed to the page, once (idempotent)" \
  || bad_t "L7a secrets.<domain> is routed to the page, once (idempotent)" "$(cat "$SECRET_DROP_CADDYFILE")"
printf 'teal-fox.example.com {\n}\n' > "$SECRET_DROP_CADDYFILE"; cp "$SECRET_DROP_CADDYFILE" "$TMP/cf.before"
CADDY_VALIDATE_FAIL=1 _secret_drop_ensure_route 2>/dev/null
cmp -s "$SECRET_DROP_CADDYFILE" "$TMP/cf.before" && ! ls "$TMP"/Caddyfile.dive5319.* >/dev/null 2>&1 \
  && ok_t "L7b a failed validate restores the previous Caddyfile byte for byte" \
  || bad_t "L7b a failed validate restores the previous Caddyfile byte for byte" "$(diff "$TMP/cf.before" "$SECRET_DROP_CADDYFILE")"
unset -f systemd-run systemctl

# --- L8: serve refuses a routable plain-HTTP bind --------------------------------
out=$( ( _secret_serve --listen=0.0.0.0:3127 ) 2>&1 ); rc=$?
[[ $rc -eq $E_VALIDATION && "$out" == *"routable plain-HTTP"* ]] && ok_t "L8 serve binds loopback only" \
  || bad_t "L8 serve binds loopback only" "rc=$rc out=$out"

# --- L9: the terminal fallback asks with hidden input -----------------------------
if command -v script >/dev/null 2>&1; then
  rm -f "$CONNECTORS_DIR/tty.env"
  cat > "$TMP/tty.sh" <<EOF
cd "$REPO"; for f in $LIBS; do source "src/\$f"; done
CONNECTORS_DIR="$CONNECTORS_DIR"; SECRET_WRITE_LOCK="$SECRET_WRITE_LOCK"; require_root() { :; }
_secret_write TTY_KEY --connector=tty
EOF
  ( sleep 1; printf 'typed-hidden-value\r' ) | script -qfec "bash $TMP/tty.sh" /dev/null > "$TMP/tty.out" 2>&1
  [[ "$(grep -cx 'TTY_KEY=typed-hidden-value' "$CONNECTORS_DIR/tty.env" 2>/dev/null)" == 1 ]] \
    && grep -q 'Paste the value for TTY_KEY (hidden)' "$TMP/tty.out" && ! grep -q 'typed-hidden-value' "$TMP/tty.out" \
    && ok_t "L9 at a terminal, secret write asks for the value without echoing it" \
    || bad_t "L9 at a terminal, secret write asks for the value without echoing it" "out=$(tr -d '\r' < "$TMP/tty.out") env=$(cat "$CONNECTORS_DIR/tty.env" 2>/dev/null)"
else
  ok_t "L9 SKIP (no script(1) on this host)"
fi

echo
echo "secret-drop-link unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
