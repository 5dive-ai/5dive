#!/usr/bin/env bash
# DIVE-5319 unit harness: the one-time secret drop link served by the BOX.
#   * `secret link` mints a link for an open secret gate: https://secrets.<box>/<token>,
#     only the token's SHA-256 stored, root-only store, bound to task+KEY+connector.
#   * `secret _peek` / `secret _redeem` (the page's two calls): expiry, gate re-check,
#     single use (every link for the gate burns), a refused value burns nothing.
#   * the page itself (python, loopback): GET form + headers, POST writes the value
#     exactly once, never echoes it, never logs the token, 404/410/429.
#   * the Caddy route for secrets.<domain>: appended once, restored on a bad validate.
#   * DIVE-5372: `secret link` returns only once the page answers over verified TLS
#     (bounded; ready:false past it), and install.sh pre-warms the route.
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

LIBS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/self.sh cmd_task.sh cmd_tool.sh cmd_secret.sh cmd_secret_drop.sh"
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
# DIVE-6973: the Vault key, in TMP (made on the first save).
SECRET_VAULT_KEY="$TMP/etc5dive/vault.key"
# DIVE-5806: the kernel's listening-socket table, in TMP. Empty = nothing on the port.
SECRET_DROP_PROC_NET="$TMP/procnet"; mkdir -p "$SECRET_DROP_PROC_NET"
procnet_reset() {
  printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "$SECRET_DROP_PROC_NET/tcp"
  printf '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "$SECRET_DROP_PROC_NET/tcp6"
}
# listen_as <uid> [tcp|tcp6] [port-hex] [state-hex]: a socket row, as the kernel prints it.
listen_as() {
  local uid="$1" fam="${2:-tcp}" port="${3:-0C37}" st="${4:-0A}"
  if [[ "$fam" == tcp6 ]]; then
    printf '   0: 00000000000000000000000000000000:%s 00000000000000000000000000000000:0000 %s 00000000:00000000 00:00000000 00000000 %5s        0 4242 1 0000000000000000 100 0 0 10 0\n' "$port" "$st" "$uid" >> "$SECRET_DROP_PROC_NET/tcp6"
  else
    printf '   0: 0100007F:%s 00000000:0000 %s 00000000:00000000 00:00000000 00000000 %5s        0 4242 1 0000000000000000 100 0 0 10 0\n' "$port" "$st" "$uid" >> "$SECRET_DROP_PROC_NET/tcp"
  fi
}
procnet_reset
# DIVE-5772: the tools store and the project folders, in TMP too.
TOOLS_ENV_FILE="$CONNECTORS_DIR/tools.sh"; TOOLS_WRITE_LOCK="$TMP/tools.lock"
export SECRET_PROJECTS_DIR="$TMP/projects"; mkdir -p "$SECRET_PROJECTS_DIR"
export JOURNAL_LOG="$TMP/journal.log"; : > "$JOURNAL_LOG"
printf 'FIVE_DOMAIN=teal-fox.example.com\n' > "$SECRET_DROP_PROVISIONING"
require_root() { :; }
# DIVE-6205: who asks for a link. Empty = the box or a person (the app's card);
# an agent name = an agent seat. The harness user is whatever CI runs as.
_secret_link_agent_caller() { printf '%s' "${LINK_CALLER:-}"; }
JSON_MODE=1
set +e

MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
export MOCK5DIVE_LOG="$TMP/5dive-calls.log"; : > "$MOCK5DIVE_LOG"
export MOCK5DIVE_DB="$TASKS_DB"
cat > "$MOCKBIN/5dive" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK5DIVE_LOG"
# A clear that takes. The real evidence rules are graded in L10, against the real verb.
if [[ "${1:-} ${2:-}" == "task answer" ]]; then
  sqlite3 "$MOCK5DIVE_DB" "UPDATE tasks SET need_answered_at=datetime('now') WHERE ident='$3';"
fi
EOF
chmod +x "$MOCKBIN/5dive"
# `logger` is the journal (DIVE-5772): what the drop says about a clear that did not take.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$JOURNAL_LOG"\n' > "$MOCKBIN/logger"; chmod +x "$MOCKBIN/logger"
PATH="$MOCKBIN:$PATH"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init
task_need_notify() { :; }
seed_gate() {   # <ident> <key> <connector>
  db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','todo','main','mailer');"
  cmd_task_need "$1" --type=secret --ask="Gmail app password for the inbox" --secret-key="$2" --connector="$3" >/dev/null 2>&1
  # The filer is the seat asking; routing may move the assignee (main's on-box run).
  db "UPDATE tasks SET gate_filed_by='mailer', assignee='router-moved' WHERE ident='$1';"
}
reopen() { db "UPDATE tasks SET need_answered_at=NULL WHERE ident='$1';"; }
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
# DIVE-5384: a multi-line value is no longer refused (L5j lands one); an empty one still is.
printf '\n' | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_VALIDATION && -f "$SECRET_DROP_DIR/$(hash_of "$tok1")" && ! -s "$CONNECTORS_DIR/gmail.env" ]] \
  && ok_t "L4a an empty value is refused, nothing written, the link still works" \
  || bad_t "L4a an empty value is refused, nothing written, the link still works" "rc=$rc"
VALUE='abcd efgh ijkl mnop'
printf '%s' "$VALUE" | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) > "$TMP/redeem.out" 2>&1; rc=$?
[[ $rc -eq 0 && "$(grep -cxF "GMAIL_APP_PASSWORD=$VALUE" "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L4b a redeem writes the value exactly once into the gate's connector file" \
  || bad_t "L4b a redeem writes the value exactly once into the gate's connector file" "rc=$rc env=$(cat "$CONNECTORS_DIR/gmail.env" 2>/dev/null)"
! grep -qF "$VALUE" "$TMP/redeem.out" && ok_t "L4c the redeem's output never carries the value" \
  || bad_t "L4c the redeem's output never carries the value" "$(cat "$TMP/redeem.out")"
grep -q "task answer DIVE-11 --human --from=drop --drop-link=$(hash_of "$tok1")" "$MOCK5DIVE_LOG" \
  && ok_t "L4d the write clears the gate, citing the redeemed link (task answer --drop-link=<hash>)" \
  || bad_t "L4d the write clears the gate, citing the redeemed link (task answer --drop-link=<hash>)" "calls: $(cat "$MOCK5DIVE_LOG")"
[[ ! -e "$SECRET_DROP_DIR/$(hash_of "$tok1")" && ! -e "$SECRET_DROP_DIR/$(hash_of "$tok2")" ]] \
  && ok_t "L4e single use: every link for the gate burns, not only the one used" \
  || bad_t "L4e single use: every link for the gate burns, not only the one used" "ls: $(ls "$SECRET_DROP_DIR")"
printf 'second' | ( _secret_drop_redeem --hash="$(hash_of "$tok1")" ) >/dev/null 2>&1; rc=$?
[[ $rc -eq $E_NOT_FOUND && "$(grep -c '^GMAIL_APP_PASSWORD=' "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L4f a second use is refused and writes nothing" \
  || bad_t "L4f a second use is refused and writes nothing" "rc=$rc"
reopen DIVE-11
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
SECRET_VAULT_KEY="$SECRET_VAULT_KEY"
TOOLS_ENV_FILE="$TOOLS_ENV_FILE"; TOOLS_WRITE_LOCK="$TOOLS_WRITE_LOCK"; SECRET_PROJECTS_DIR="$SECRET_PROJECTS_DIR"
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
[[ "$code" == 200 ]] && grep -q '<textarea name=value class=secret' "$TMP/page.html" && ! grep -q '<input' "$TMP/page.html" && ! grep -q 'type=password' "$TMP/page.html" && grep -q '[.]secret{-webkit-text-security:disc}' "$TMP/page.html" && grep -q 'mailer needs GMAIL_APP_PASSWORD' "$TMP/page.html" \
  && ok_t "L5a GET shows a CSS-masked textarea (never type=password, so no save-password prompt) and which seat FILED the ask (not the routed assignee) for which KEY" \
  || bad_t "L5a GET shows a CSS-masked textarea (never type=password, so no save-password prompt) and which seat FILED the ask (not the routed assignee) for which KEY" "code=$code $(head -c 400 "$TMP/page.html")"
grep -qi '^cache-control: no-store' "$TMP/page.hdr" && grep -qi '^referrer-policy: no-referrer' "$TMP/page.hdr" \
  && grep -qi "^content-security-policy: default-src 'none'" "$TMP/page.hdr" && grep -qi '^x-frame-options: DENY' "$TMP/page.hdr" \
  && ok_t "L5b no-store, no-referrer, CSP default-src none, no framing" \
  || bad_t "L5b no-store, no-referrer, CSP default-src none, no framing" "$(cat "$TMP/page.hdr")"
VALUE='s3cr3t-Value_9 with space'
code=$(curl -s -o "$TMP/post.html" -w '%{http_code}' --data-urlencode "value=$VALUE" "$B/$tok")
[[ "$code" == 200 && "$(grep -cxF "GMAIL_APP_PASSWORD=$VALUE" "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L5c POST lands the value exactly once in the connector file" \
  || bad_t "L5c POST lands the value exactly once in the connector file" "code=$code env=$(cat "$CONNECTORS_DIR/gmail.env" 2>/dev/null) body=$(head -c 300 "$TMP/post.html")"
grep -q 'has been told' "$TMP/post.html" && ok_t "L5c2 a clear that took says the task has been told" \
  || bad_t "L5c2 a clear that took says the task has been told" "$(head -c 400 "$TMP/post.html")"
reopen DIVE-11
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
# L5j DIVE-5384: a pasted 3-line block lands whole. A browser submits a textarea's
# line breaks as CRLF, so the POST sends CRLF and the box must hold LF.
reopen DIVE-11; rm -rf "$SECRET_DROP_DIR"; rm -f "$CONNECTORS_DIR/gmail.env"
out=$(mint DIVE-11); tok=$(tok_of "$out")
ML=$'Application key ak16charsxxxxxxx\nApplication secret as32charsxxxxxxxxxxxxxxxxxxxxxxxx\nConsumer Key ck32charsxxxxxxxxxxxxxxxxxxxxxxxx'
code=$(curl -s -o "$TMP/post-ml.html" -w '%{http_code}' --data-urlencode "value=${ML//$'\n'/$'\r\n'}" "$B/$tok")
VF="$CONNECTORS_DIR/gmail.d/GMAIL_APP_PASSWORD"
[[ "$code" == 200 ]] && cmp -s "$VF" <(printf '%s\n' "$ML") \
  && [[ "$(cat "$CONNECTORS_DIR/gmail.env")" == "GMAIL_APP_PASSWORD_FILE=$VF" ]] \
  && ok_t "L5j a 3-line paste (CRLF, as a browser sends it) reads back byte-identical on the box; the .env holds one pointer line" \
  || bad_t "L5j a 3-line paste (CRLF, as a browser sends it) reads back byte-identical on the box; the .env holds one pointer line" "code=$code env=$(cat "$CONNECTORS_DIR/gmail.env" 2>/dev/null) file=$(od -c "$VF" 2>&1 | head -4) body=$(head -c 300 "$TMP/post-ml.html")"
! grep -qF 'as32chars' "$TMP/post-ml.html" && ! grep -qF 'as32chars' "$TMP/server.log" \
  && ok_t "L5k the multi-line value is in neither the response nor the server log" \
  || bad_t "L5k the multi-line value is in neither the response nor the server log" "leaked"
reopen DIVE-11
out=$(mint DIVE-11); tok=$(tok_of "$out")
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode $'value=innocent\r\nEVIL=1' "$B/$tok")
[[ "$code" == 200 ]] && ! grep -q '^EVIL=' "$CONNECTORS_DIR/gmail.env" && [[ "$(wc -l < "$CONNECTORS_DIR/gmail.env")" == 1 ]] \
  && ok_t "L5l a paste of 'x<newline>EVIL=1' through the page creates no second key" \
  || bad_t "L5l a paste of 'x<newline>EVIL=1' through the page creates no second key" "code=$code env=$(cat "$CONNECTORS_DIR/gmail.env")"
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
# DIVE-6205: with the page gone, Caddy serves the closed page (410), not a bare 502.
printf 'teal-fox.example.com {\n}\n' > "$SECRET_DROP_CADDYFILE"
_secret_drop_ensure_route
blk=$(sed -n '/^secrets\.teal-fox\.example\.com {/,/^}/p' "$SECRET_DROP_CADDYFILE")
[[ "$blk" == *"handle_errors"* && "$blk" == *'{err.status_code} in [502, 503, 504]'* && "$blk" == *'` 410'* \
   && "$blk" == *"<h1>This request is closed</h1><p>The agent no longer needs this, or it was already provided.</p>"* ]] \
  && ok_t "L7c the route serves the page's own 410 'This request is closed' when the page is down" \
  || bad_t "L7c closed page on the route" "$blk"
# A box routed before this change carries the old block: replaced once, the rest
# of the Caddyfile untouched, and a second run changes nothing.
cat > "$SECRET_DROP_CADDYFILE" <<EOF
teal-fox.example.com {
    handle /shell/* {
        reverse_proxy localhost:3101
    }
}

# DIVE-5319: one-time secret drop links (5dive secret link). Its own name, so TLS
# ends on this box: the root name is proxied by Cloudflare, *.<domain> is not.
secrets.teal-fox.example.com {
    reverse_proxy 127.0.0.1:${SECRET_DROP_PORT}
}

owner.example.com {
    respond "mine"
}
EOF
_secret_drop_ensure_route; cp "$SECRET_DROP_CADDYFILE" "$TMP/cf.once"; _secret_drop_ensure_route
[[ "$(grep -c '^secrets\.teal-fox\.example\.com {' "$SECRET_DROP_CADDYFILE")" == 1 && "$(grep -c 'handle_errors' "$SECRET_DROP_CADDYFILE")" == 1 \
   && "$(grep -c '^# DIVE-5319: one-time' "$SECRET_DROP_CADDYFILE")" == 1 ]] \
   && grep -q 'reverse_proxy localhost:3101' "$SECRET_DROP_CADDYFILE" && grep -q 'respond "mine"' "$SECRET_DROP_CADDYFILE" \
   && cmp -s "$SECRET_DROP_CADDYFILE" "$TMP/cf.once" \
  && ok_t "L7d an old secrets block is upgraded in place once; the other sites are kept; a second run is a no-op" \
  || bad_t "L7d old block upgrade" "$(cat "$SECRET_DROP_CADDYFILE")"
unset -f systemd-run systemctl

# --- L11: DIVE-5372 — the link waits for its page over valid TLS ---------------
# lodar's first real link (chill-gorge, 2026-10-02) went out before Caddy had a
# certificate for secrets.<box>, and the first tap failed TLS. A box that has
# never minted (no secrets. route) must hand the URL out only once
# https://secrets.<d>/healthz answers through Caddy with a verified certificate,
# or after the bound, marked ready:false. `curl` is a mock: probes with
# --resolve are the TLS check (counted, args logged); anything else is the
# page's own loopback healthz in _secret_drop_ensure_server, answered "up".
export PROBE_LOG="$TMP/probe.log" PROBE_COUNT="$TMP/probe.count"
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" --resolve "*) ;; *) echo '{"ok":true}'; exit 0 ;; esac
echo "$*" >> "$PROBE_LOG"
n=$(( $(cat "$PROBE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$PROBE_COUNT"
# PROBE_READY_AFTER=k: the first k probes fail the handshake (curl rc 35).
(( n > ${PROBE_READY_AFTER:-0} )) && [[ "${PROBE_NEVER:-0}" != 1 ]] || exit 35
echo '{"ok":true}'
EOF
chmod +x "$MOCKBIN/curl"; hash -r   # L5 already ran the real curl: drop bash's cached path
export RELOAD_LOG="$TMP/reload.log"
systemd-run() { echo "systemd-run $*" >> "$RELOAD_LOG"; }; systemctl() { :; }
probe_reset() { : > "$PROBE_LOG"; rm -f "$PROBE_COUNT"; : > "$RELOAD_LOG"; }
mint_live() { ( _secret_link "$@" ) 2>/dev/null; }   # NOT --no-start: route, page, wait
fresh_box() { printf 'teal-fox.example.com {\n    handle /shell/* {\n        reverse_proxy localhost:3101\n    }\n}\n' > "$SECRET_DROP_CADDYFILE"; }
probes() { cat "$PROBE_COUNT" 2>/dev/null || echo 0; }
export SECRET_DROP_POLL_S=0.1

# The page is root's here (DIVE-5806 looks at who holds the port before it trusts /healthz).
listen_as 0
seed_gate DIVE-31 READY_KEY ready31
fresh_box; probe_reset
out=$(PROBE_READY_AFTER=3 mint_live DIVE-31); rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.ready')" == true && "$(probes)" == 4 ]] \
  && grep -q '^secrets\.teal-fox\.example\.com {' "$SECRET_DROP_CADDYFILE" && grep -q 'systemd-run.*reload caddy' "$RELOAD_LOG" \
  && ok_t "L11a a never-routed box: route added + reload scheduled, and the link returns only once the TLS probe succeeds (3 failed handshakes, then ready:true)" \
  || bad_t "L11a a never-routed box: route added + reload scheduled, and the link returns only once the TLS probe succeeds (3 failed handshakes, then ready:true)" "rc=$rc probes=$(probes) out=$out reload=$(cat "$RELOAD_LOG")"
p1=$(head -1 "$PROBE_LOG")
[[ "$p1" == *"--resolve secrets.teal-fox.example.com:443:127.0.0.1"* && "$p1" == *"https://secrets.teal-fox.example.com/healthz"* ]] \
  && ! grep -qE -- '(^| )(-k|--insecure)( |$)' "$PROBE_LOG" \
  && ok_t "L11b the probe is https://secrets.<d>/healthz through this box's Caddy (--resolve to loopback), certificate verified (never -k)" \
  || bad_t "L11b the probe is https://secrets.<d>/healthz through this box's Caddy (--resolve to loopback), certificate verified (never -k)" "probe: $p1"

seed_gate DIVE-32 READY_KEY ready32
fresh_box; probe_reset
t0=$(date +%s)
out=$(PROBE_NEVER=1 SECRET_DROP_WAIT_S=2 mint_live DIVE-32); rc=$?
el=$(( $(date +%s) - t0 ))
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.ready')" == false \
   && "$(printf '%s' "$out" | jq -r '.data.url')" =~ ^https://secrets\.teal-fox\.example\.com/[A-Za-z0-9_-]{43}$ \
   && $el -ge 2 && $el -le 6 && "$(probes)" -ge 2 ]] \
  && ok_t "L11c never ready: the link still comes back after the bound (2s here, ${el}s measured), marked ready:false" \
  || bad_t "L11c never ready: the link still comes back after the bound (2s here, ${el}s measured), marked ready:false" "rc=$rc el=$el probes=$(probes) out=$out"
probe_reset
out=$( (JSON_MODE=0; PROBE_NEVER=1 SECRET_DROP_WAIT_S=0 _secret_link DIVE-32) 2>&1 ); rc=$?
[[ $rc -eq 0 && "$out" == *"not ready yet"*"open it again"* ]] \
  && ok_t "L11d text mode says the page is not ready yet and the link stays valid" \
  || bad_t "L11d text mode says the page is not ready yet and the link stays valid" "rc=$rc out=$out"

probe_reset
out=$(mint DIVE-31); rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.ready')" == null && "$(probes)" == 0 ]] \
  && ok_t "L11e --no-start never probes (ready:null, not checked)" \
  || bad_t "L11e --no-start never probes (ready:null, not checked)" "probes=$(probes) out=$out"
printf 'SECRET_DROP_BASE_URL=https://drop.example.net\n' > "$SECRET_DROP_CONF"
fresh_box; probe_reset
out=$(PROBE_NEVER=1 mint_live DIVE-31); rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.ready')" == null && "$(probes)" == 0 ]] \
  && ! grep -q '^secrets\.' "$SECRET_DROP_CADDYFILE" \
  && ok_t "L11f an owner's own base URL: no route, no probe, no wait (ready:null)" \
  || bad_t "L11f an owner's own base URL: no route, no probe, no wait (ready:null)" "rc=$rc probes=$(probes) out=$out"
rm -f "$SECRET_DROP_CONF"

# Pre-warm (install.sh, every install and --upgrade): the route and its reload
# exist before any gate, so Caddy fetches the certificate ahead of the first link.
fresh_box; probe_reset
( _secret_drop_prewarm ); rc=$?; ( _secret_drop_prewarm ); rc2=$?
[[ $rc -eq 0 && $rc2 -eq 0 && "$(grep -c '^secrets\.teal-fox\.example\.com {' "$SECRET_DROP_CADDYFILE")" == 1 \
   && "$(grep -c 'reload caddy' "$RELOAD_LOG")" == 1 && "$(probes)" == 0 ]] \
  && ok_t "L11g secret _prewarm routes secrets.<d> once and schedules one reload (idempotent, no page, no probe)" \
  || bad_t "L11g secret _prewarm routes secrets.<d> once and schedules one reload (idempotent, no page, no probe)" "rc=$rc/$rc2 reloads=$(grep -c 'reload caddy' "$RELOAD_LOG") cf=$(cat "$SECRET_DROP_CADDYFILE")"
mv "$SECRET_DROP_PROVISIONING" "$TMP/prov.off2"; fresh_box; cp "$SECRET_DROP_CADDYFILE" "$TMP/cf.nodomain"
( _secret_drop_prewarm ); rc=$?
mv "$TMP/prov.off2" "$SECRET_DROP_PROVISIONING"
[[ $rc -eq 0 ]] && cmp -s "$SECRET_DROP_CADDYFILE" "$TMP/cf.nodomain" \
  && ok_t "L11h _prewarm on a box with no FIVE_DOMAIN: rc 0, Caddyfile untouched" \
  || bad_t "L11h _prewarm on a box with no FIVE_DOMAIN: rc 0, Caddyfile untouched" "rc=$rc"
n=$(grep -c '5dive" secret _prewarm >/dev/null 2>&1 || true\|^5dive secret _prewarm >/dev/null 2>&1 || true' install.sh)
[[ "$n" == 2 ]] \
  && ok_t "L11i install.sh pre-warms on both the fresh-install and the --upgrade path, best-effort" \
  || bad_t "L11i install.sh pre-warms on both the fresh-install and the --upgrade path, best-effort" "matches=$n"
unset -f systemd-run systemctl five_self_bundle; rm -f "$MOCKBIN/curl"; hash -r
procnet_reset

# --- L13: DIVE-5806 (H2) — a seat squatting the page's port gets no link ------
# divine-owl audit 2026-10-07: 3127 is unprivileged and free between gates, and
# _secret_drop_ensure_server took ANY /healthz 200 as the real page, so a seat that
# bound it first got the owner's next secret over secrets.<box>'s valid certificate.
# Now `secret link` reads the kernel's socket table and refuses unless root holds it.
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PROBE_LOG"; echo '{"ok":true}'
EOF
chmod +x "$MOCKBIN/curl"; hash -r
export SERVE_LOG="$TMP/serve.log"
systemd-run() { echo "systemd-run $*" >> "$SERVE_LOG"; [[ -n "${RACE_UID:-}" && " $* " == *" secret serve "* ]] && listen_as "$RACE_UID"; return 0; }
systemctl() { :; }
five_self_bundle() { printf '%s' "$MOCKBIN/5dive"; }   # the page's start is systemd-run's mock above
export SECRET_DROP_BIND_S=1 SECRET_DROP_POLL_S=0.1
links_for() { grep -l "^task=$1\$" "$SECRET_DROP_DIR"/* 2>/dev/null | wc -l; }
squat_case() {   # <label> <ident> <want-uid> <mint args...>
  local label="$1" ident="$2" want="$3"; shift 3
  : > "$PROBE_LOG"; : > "$SERVE_LOG"
  local before; before=$(links_for "$ident")
  out=$( (JSON_MODE=0; _secret_link "$ident" "$@") 2>&1 ); rc=$?
  [[ $rc -eq 5 && "$out" == *"held by uid ${want}"*"not root"* && "$out" != *"https://secrets."* \
     && "$(links_for "$ident")" == "$before" && ! -s "$PROBE_LOG" ]] \
    && ok_t "$label" || bad_t "$label" "rc=$rc links=$before->$(links_for "$ident") probes=$(wc -l < "$PROBE_LOG") out=$out"
}
seed_gate DIVE-41 SQUAT_KEY squat41
fresh_box
procnet_reset; listen_as 1001
squat_case "L13a a non-root listener on 127.0.0.1:3127: secret link refuses (rc 5, names uid 1001), mints nothing, never probes" DIVE-41 1001
! grep -q 'secret serve' "$SERVE_LOG" \
  && ok_t "L13b ...and does not try to start the page behind the squatter" \
  || bad_t "L13b ...and does not try to start the page behind the squatter" "serve=$(cat "$SERVE_LOG")"
squat_case "L13c --no-start refuses the same squatted port" DIVE-41 1001 --no-start
procnet_reset; listen_as 1002 tcp6
squat_case "L13d a non-root listener on [::]:3127 (tcp6) is a squat too" DIVE-41 1002
procnet_reset; listen_as 0; listen_as 1003
squat_case "L13e root AND a seat on the port: refused (any non-root holder)" DIVE-41 1003
procnet_reset; RACE_UID=1004
squat_case "L13f the seat wins the bind between the look and the page's start: refused after the start" DIVE-41 1004
unset RACE_UID
grep -q 'secret serve' "$SERVE_LOG" \
  && ok_t "L13g ...the page WAS started there (the second look is what caught it)" \
  || bad_t "L13g ...the page WAS started there (the second look is what caught it)" "serve=$(cat "$SERVE_LOG")"
procnet_reset; listen_as 1001 tcp 0C38; listen_as 1001 tcp 0C37 01; listen_as 0
: > "$PROBE_LOG"
out=$(mint_live DIVE-41); rc=$?
[[ $rc -eq 0 && "$(printf '%s' "$out" | jq -r '.data.url')" =~ ^https://secrets\.teal-fox\.example\.com/[A-Za-z0-9_-]{43}$ ]] \
  && ok_t "L13h root's page on 3127 mints as before; a seat on 3128, or a non-listening 3127 socket, is not a squat" \
  || bad_t "L13h root's page on 3127 mints as before; a seat on 3128, or a non-listening 3127 socket, is not a squat" "rc=$rc out=$out"
unset -f systemd-run systemctl; rm -f "$MOCKBIN/curl"; hash -r
procnet_reset

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

# --- L10: the gate CLOSES on a box that enforces human evidence -------------------
# main's on-box arm (2026-10-01): the page's systemd-run unit has no SUDO_UID and a
# system.slice cgroup, so with `gate-proof enforce on` the old bare `task answer
# --human` was refused and the gate stayed open while the page said "told". Here the
# REAL `task answer` runs as a separate process (the page's shell-out), as root,
# enforcement on, no SUDO_UID, the transient unit's cgroup.
REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"; : > "$TMP/enforce"
export AUDIT_LOG_T="$TMP/audit.log"; : > "$AUDIT_LOG_T"
cat > "$REALBIN/5dive" <<EOF
#!/usr/bin/env bash
cd "$REPO"; for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"
SECRET_DROP_DIR="$SECRET_DROP_DIR"; AUDIT_LOG="$AUDIT_LOG_T"
TOOLS_ENV_FILE="$TOOLS_ENV_FILE"; TOOLS_WRITE_LOCK="$TOOLS_WRITE_LOCK"; SECRET_PROJECTS_DIR="$SECRET_PROJECTS_DIR"
# DIVE-5772: the drop tells the agent itself when the clear does not take.
if [[ "\${1:-}" == agent ]]; then printf '%s\n' "\$*" >> "$TMP/agent-sends.log"; exit 0; fi
# Lock contention seam: the first N answers fail as a busy store would.
if [[ -n "\${BUSY_FIRST:-}" ]]; then
  n=\$(cat "$TMP/busy.n" 2>/dev/null || echo 0); echo \$((n+1)) > "$TMP/busy.n"
  (( n < BUSY_FIRST )) && { echo "Error: database is locked (5)" >&2; exit 1; }
fi
[[ -n "\${SLOW_ANSWER:-}" && "\${1:-} \${2:-}" == "task answer" ]] && sleep "\$SLOW_ANSWER"
export GATE_PROOF_ENFORCE="$TMP/enforce"; unset SUDO_UID
# Root, as the page's unit is: euid 0 (no agent), no SUDO_UID, so the uid half of
# the principal test passes and the STRUCTURAL half refuses, exactly as on the box.
_gate_is_root() { return 0; }; _gate_caller_uid() { printf '0'; }
_gate_sudo_uid_nonagent() { return 0; }
_gate_caller_cgroup() { printf '%s' '/system.slice/5dive-secret-drop.service'; }
task_need_notify() { :; }; _task_send_owner() { :; }
# DIVE-6205: the drop's ping is detached; here always the in-process child, and
# SLOW_SEND holds it as a mid-turn seat's wake would.
_task_answer_ping_unit_ok() { return 1; }
cmd_send() { [[ -n "\${SLOW_SEND:-}" ]] && { printf 'start %s\n' "\$(date +%s)" >> "$TMP/slow-send.log"; sleep "\$SLOW_SEND"; }; printf '%s\n' "\$*" >> "$TMP/sends.log"; }
# The audit fence withholds lines on a non-prod store; AUDIT_LOG is the harness's file.
_task_store_audit_log() { audit_log "\$@"; }
# Mutation seam: break the link between the redeem's checks and the answer.
case "\${MUTATE_LINK:-}" in
  delete) rm -f "$SECRET_DROP_DIR"/* ;;
  retask) sed -i 's/^task=.*/task=DIVE-99/' "$SECRET_DROP_DIR"/* ;;
esac
[[ "\${1:-}" == task ]] && shift
cmd_task "\$@"
EOF
chmod +x "$REALBIN/5dive"
cp "$MOCKBIN/logger" "$REALBIN/logger"
ans_at() { db "SELECT COALESCE(need_answered_at,'') FROM tasks WHERE ident='$1';"; }
# The drop's ping runs detached (DIVE-6205): wait, bounded, for its line.
wait_for_line() { local i; for i in $(seq 1 ${3:-50}); do grep -qF -- "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# The page's own bundle, with the real verb on PATH instead of the mock.
WRAP2="$TMP/5dive-bundle-real"; sed "s#$MOCKBIN#$REALBIN#" "$WRAP" > "$WRAP2"; chmod +x "$WRAP2"
redeem_real() {   # <hash> <value> [VAR=val...]
  local h="$1" v="$2"; shift 2
  printf '%s' "$v" | env "$@" "$WRAP2" secret _redeem --hash="$h" --json
}

seed_gate DIVE-21 E2E_KEY e2e5319
out=$(printf 'x' | PATH="$REALBIN:$PATH" 5dive task answer DIVE-21 --human --from=drop 2>&1); rc=$?
[[ $rc -eq $E_AUTH_REQUIRED && -z "$(ans_at DIVE-21)" && "$out" == *"needs a human"* ]] \
  && ok_t "L10a control: this arm models the box (bare --human, no SUDO_UID, enforce on -> refused, gate open)" \
  || bad_t "L10a control: this arm models the box (bare --human, no SUDO_UID, enforce on -> refused, gate open)" "rc=$rc at=$(ans_at DIVE-21) out=$out"
out=$(mint DIVE-21); tok=$(tok_of "$out"); h=$(hash_of "$tok")
VALUE='e2e-value-5319'
out=$(redeem_real "$h" "$VALUE" 2>&1); rc=$?
ev=$(db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE ident='DIVE-21';")
by=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-21';")
[[ $rc -eq 0 && -n "$(ans_at DIVE-21)" && "$ev" == "drop-link" && "$by" == human:* ]] \
  && ok_t "L10b redeem closes the gate with no human principal: need_answered_at set, evidence=drop-link, answered_by human:*" \
  || bad_t "L10b redeem closes the gate with no human principal: need_answered_at set, evidence=drop-link, answered_by human:*" "rc=$rc at=$(ans_at DIVE-21) ev=$ev by=$by out=$out"
grep -q 'task=DIVE-21.*evidence=drop-link' "$AUDIT_LOG_T" && grep -q 'enforce=on' "$AUDIT_LOG_T" \
  && ok_t "L10c the audit line names evidence=drop-link, under enforce=on" \
  || bad_t "L10c the audit line names evidence=drop-link, under enforce=on" "audit: $(grep DIVE-21 "$AUDIT_LOG_T" | tail -3)"
[[ ! -e "$SECRET_DROP_DIR/$h" && "$(grep -cxF "E2E_KEY=$VALUE" "$CONNECTORS_DIR/e2e5319.env")" == 1 ]] && ! grep -qF "$VALUE" "$AUDIT_LOG_T" \
  && ok_t "L10d the link is burned after the clear, the value is in the file once and never in the audit" \
  || bad_t "L10d the link is burned after the clear, the value is in the file once and never in the audit" "ls=$(ls "$SECRET_DROP_DIR")"

# L10k DIVE-5384: a multi-line value lands as KEY_FILE + its file, and that counts
# as "the value landed" for the evidence check, so the gate closes, and the ping to
# the seat names the file. A pointer whose file is gone is NOT evidence.
: > "$TMP/sends.log"
seed_gate DIVE-25 E2E_PEM e2e25
out=$(mint DIVE-25); h=$(hash_of "$(tok_of "$out")")
PEM=$'-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----'
out=$(redeem_real "$h" "$PEM" 2>&1); rc=$?
ev=$(db "SELECT COALESCE(human_evidence,'') FROM tasks WHERE ident='DIVE-25';")
[[ $rc -eq 0 && -n "$(ans_at DIVE-25)" && "$ev" == "drop-link" ]] && cmp -s "$CONNECTORS_DIR/e2e25.d/E2E_PEM" <(printf '%s\n' "$PEM") \
  && ok_t "L10k a multi-line redeem through the real verb lands the file AND closes the gate (evidence=drop-link)" \
  || bad_t "L10k a multi-line redeem through the real verb lands the file AND closes the gate (evidence=drop-link)" "rc=$rc at=$(ans_at DIVE-25) ev=$ev out=$out"
wait_for_line "E2E_PEM spans several lines" "$TMP/sends.log"
grep -qF "E2E_PEM spans several lines, so it is the file $CONNECTORS_DIR/e2e25.d/E2E_PEM" "$TMP/sends.log" \
  && ok_t "L10l the seat's 'provided' ping names the value file, not the .env" \
  || bad_t "L10l the seat's 'provided' ping names the value file, not the .env" "sends: $(cat "$TMP/sends.log")"
seed_gate DIVE-26 E2E_PEM e2e26
out=$(mint DIVE-26); h=$(hash_of "$(tok_of "$out")")
printf 'E2E_PEM_FILE=%s\n' "$CONNECTORS_DIR/e2e26.d/E2E_PEM" > "$CONNECTORS_DIR/e2e26.env"
out=$(PATH="$REALBIN:$PATH" 5dive task answer DIVE-26 --human --from=drop --drop-link="$h" 2>&1); rc=$?
[[ $rc -eq $E_AUTH_REQUIRED && -z "$(ans_at DIVE-26)" ]] \
  && ok_t "L10m a KEY_FILE pointer with no value file behind it is not evidence (refused, gate open)" \
  || bad_t "L10m a KEY_FILE pointer with no value file behind it is not evidence (refused, gate open)" "rc=$rc at=$(ans_at DIVE-26) out=$out"
rm -f "$CONNECTORS_DIR/e2e26.env"

# Mutation arms: the evidence is read from the STORE, so a link gone or re-bound
# between the checks and the answer leaves the gate open, and redeem says so.
seed_gate DIVE-22 E2E_KEY e2e22
out=$(mint DIVE-22); h=$(hash_of "$(tok_of "$out")")
out=$(redeem_real "$h" "v22" MUTATE_LINK=delete 2>&1); rc=$?
[[ $rc -eq $E_AUTH_REQUIRED && -z "$(ans_at DIVE-22)" && "$out" == *"did not update"* \
   && "$(grep -c '^E2E_KEY=v22$' "$CONNECTORS_DIR/e2e22.env")" == 1 ]] \
  && ok_t "L10e mutation: link deleted before the answer -> gate stays open, distinct rc, 'did not update' (value still saved)" \
  || bad_t "L10e mutation: link deleted before the answer -> gate stays open, distinct rc, 'did not update' (value still saved)" "rc=$rc at=$(ans_at DIVE-22) out=$out"
# DIVE-5772: that failure is no longer thrown away. The refusal is in the journal
# with what `task answer` said, it is NOT retried (it would refuse again), and the
# agent that filed the gate is told directly, woken, where the value is.
grep -q 'task answer DIVE-22 (attempt 1 of 4) did not clear the gate: rc=6 ' "$JOURNAL_LOG" \
  && ! grep -q 'DIVE-22 (attempt 2' "$JOURNAL_LOG" \
  && ok_t "L10e2 the refused clear is logged to the journal with task answer's reason, once (a refusal is not retried)" \
  || bad_t "L10e2 the refused clear is logged to the journal with task answer's reason, once" "journal: $(cat "$JOURNAL_LOG")"
grep -q '^agent send mailer --wake --message=DIVE-22: your owner saved E2E_KEY through the secure link' "$TMP/agent-sends.log" \
  && ok_t "L10e3 …and the filing agent is told directly, with --wake, where E2E_KEY is" \
  || bad_t "L10e3 the filing agent is told directly" "sends: $(cat "$TMP/agent-sends.log" 2>/dev/null)"
out=$(mint DIVE-22 2>&1); rc=$?
[[ $rc -eq 0 ]] || reopen DIVE-22
out=$(mint DIVE-22); h=$(hash_of "$(tok_of "$out")")
printf 'E2E_KEY=x\n' > "$CONNECTORS_DIR/e2e22.env"
out=$(PATH="$REALBIN:$PATH" 5dive task answer DIVE-22 --human --from=drop --drop-link="$(hash_of forged)" 2>&1); rc=$?
out2=$(PATH="$REALBIN:$PATH" 5dive task answer DIVE-22 --human --from=drop --drop-link=../../etc 2>&1); rc2=$?
rm -f "$CONNECTORS_DIR/e2e22.env"
out3=$(PATH="$REALBIN:$PATH" 5dive task answer DIVE-22 --human --from=drop --drop-link="$h" 2>&1); rc3=$?
[[ $rc -eq $E_AUTH_REQUIRED && $rc2 -eq $E_AUTH_REQUIRED && $rc3 -eq $E_AUTH_REQUIRED && -z "$(ans_at DIVE-22)" ]] \
  && ok_t "L10f a bare --drop-link is not evidence: unknown hash, malformed hash, or a live link whose KEY never landed -> refused" \
  || bad_t "L10f a bare --drop-link is not evidence: unknown hash, malformed hash, or a live link whose KEY never landed -> refused" "rc=$rc/$rc2/$rc3 at=$(ans_at DIVE-22)"
db "UPDATE tasks SET need_type='approval' WHERE ident='DIVE-22';"
printf 'E2E_KEY=x\n' > "$CONNECTORS_DIR/e2e22.env"
_gate_is_root() { return 0; }
_gate_drop_link_ok "$(db "SELECT id FROM tasks WHERE ident='DIVE-22';")" "$h"; rc=$?
unset -f _gate_is_root; . src/lib/actor.sh
db "UPDATE tasks SET need_type='secret' WHERE ident='DIVE-22';"
_gate_drop_link_ok "$(db "SELECT id FROM tasks WHERE ident='DIVE-22';")" "$h"; rc2=$?
[[ $rc -ne 0 && $rc2 -ne 0 ]] \
  && ok_t "L10g the link is evidence on a SECRET gate only, and only for a root caller" \
  || bad_t "L10g the link is evidence on a SECRET gate only, and only for a root caller" "approval-gate rc=$rc non-root rc=$rc2"

# The page, with the real verb: a re-bound link -> "Saved on your server, but the
# task did not update", never "has been told".
PORT3=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
MUTATE_LINK=retask python3 "$TMP/server.py" 127.0.0.1 "$PORT3" "$WRAP2" "$SECRET_DROP_DIR" 0 2> "$TMP/server3.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT3/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
seed_gate DIVE-23 E2E_KEY e2e23
out=$(mint DIVE-23); tok=$(tok_of "$out")
code=$(curl -s -o "$TMP/post3.html" -w '%{http_code}' --data-urlencode "value=v23" "http://127.0.0.1:$PORT3/$tok")
[[ "$code" == 200 && -z "$(ans_at DIVE-23)" ]] \
  && ! grep -q 'DIVE-23 has been told\|did not update\|Tell your agent' "$TMP/post3.html" && grep -q 'your agent has been told it is there. Nothing else to do' "$TMP/post3.html" \
  && ok_t "L10h page: the clear did not take -> 'saved', no claim the task moved, and nothing asked of the owner (DIVE-5772)" \
  || bad_t "L10h page: the clear did not take -> saved, nothing asked of the owner" "code=$code at=$(ans_at DIVE-23) body=$(head -c 400 "$TMP/post3.html")"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- L12: DIVE-5772 — the drop closes its own gate for EVERY connector ----------
# DIVE-5771 (marketing's Telegram Ads key, 2026-10-07): a STANDARD seat files its
# secret gate with --connector=tools, because tools.sh is the one store an agent
# can read (DIVE-5370). The value landed in tools.sh as `export KEY='...'`, the
# evidence check read tools.env, `task answer` refused, and lodar had to tap
# Provided. Same REAL verb, same root/no-SUDO_UID/enforce-on unit as L10.
seed_gate DIVE-571 TGADS_API_KEY tools
db "UPDATE tasks SET gate_filed_by='marketing', assignee='marketing' WHERE ident='DIVE-571';"
out=$(mint DIVE-571); h=$(hash_of "$(tok_of "$out")")
out=$(redeem_real "$h" "tgads-value-5772" 2>&1); rc=$?
by=$(db "SELECT COALESCE(need_answered_by,'') FROM tasks WHERE ident='DIVE-571';")
[[ $rc -eq 0 && -n "$(ans_at DIVE-571)" && "$by" == "human:drop" ]] && grep -qxF "export TGADS_API_KEY='tgads-value-5772'" "$TOOLS_ENV_FILE" \
  && ok_t "L12a ACCEPTANCE: a tools drop on a standard seat's gate closes it, answered_by=human:drop, no tap" \
  || bad_t "L12a a tools drop closes its gate as human:drop" "rc=$rc at=$(ans_at DIVE-571) by=$by out=$out tools=$(grep -c TGADS "$TOOLS_ENV_FILE" 2>/dev/null)"
wait_for_line "TGADS_API_KEY is set in your environment" "$TMP/sends.log"
grep -q 'TGADS_API_KEY is set in your environment' "$TMP/sends.log" && grep -q -- '--wake' "$TMP/sends.log" \
  && ok_t "L12b the seat is pinged and woken at once (it is told the key is in its environment)" \
  || bad_t "L12b seat pinged + woken" "sends: $(grep DIVE-571 "$TMP/sends.log")"
# project-<app> (DIVE-5664) writes the app's own .env: the other connector that
# never wrote <conn>.env.
mkdir -p "$SECRET_PROJECTS_DIR/shop"
seed_gate DIVE-572 SHOP_API_KEY project-shop
out=$(mint DIVE-572); h=$(hash_of "$(tok_of "$out")")
out=$(redeem_real "$h" "shop-value" 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(ans_at DIVE-572)" ]] && grep -qxF "SHOP_API_KEY=shop-value" "$SECRET_PROJECTS_DIR/shop/.env" \
  && ok_t "L12c a project-<app> drop closes its gate too (the value is in the app's .env)" \
  || bad_t "L12c project drop closes its gate" "rc=$rc at=$(ans_at DIVE-572) out=$out env=$(cat "$SECRET_PROJECTS_DIR/shop/.env" 2>/dev/null | sed 's/=.*/=…/')"
# The evidence is still the store: a tools link whose KEY never reached tools.sh is not evidence.
seed_gate DIVE-573 OTHER_API_KEY tools
out=$(mint DIVE-573); h=$(hash_of "$(tok_of "$out")")
out=$(PATH="$REALBIN:$PATH" 5dive task answer DIVE-573 --human --from=drop --drop-link="$h" 2>&1); rc=$?
[[ $rc -eq $E_AUTH_REQUIRED && -z "$(ans_at DIVE-573)" ]] \
  && ok_t "L12d NEG: a tools link whose key is not in tools.sh is not evidence (refused, gate open)" \
  || bad_t "L12d tools link without the key" "rc=$rc at=$(ans_at DIVE-573) out=$out"
# A busy store is retried, and each miss is in the journal.
: > "$JOURNAL_LOG"; rm -f "$TMP/busy.n"
seed_gate DIVE-574 BUSY_API_KEY tools
out=$(mint DIVE-574); h=$(hash_of "$(tok_of "$out")")
out=$(redeem_real "$h" "busy-value" BUSY_FIRST=2 2>&1); rc=$?
[[ $rc -eq 0 && -n "$(ans_at DIVE-574)" ]] && grep -q 'DIVE-574 (attempt 2 of 4).*database is locked' "$JOURNAL_LOG" \
  && ok_t "L12e a busy store is retried: locked twice, closed on the third try, both misses in the journal" \
  || bad_t "L12e busy retry" "rc=$rc at=$(ans_at DIVE-574) journal=$(cat "$JOURNAL_LOG") out=$out"
# The gate card the owner sees in Telegram after the drop: struck with no
# buttons, and it says where the answer came from. editMessageText without a
# reply_markup is what removes the keyboard; the stub records both.
db "INSERT INTO gate_cards (task_id, ident, gate_epoch, chat_id, message_id, via, state)
    SELECT id, ident, 1, '1234567890', '777', 'marketing', 'live' FROM tasks WHERE ident='DIVE-571';" 2>/dev/null
(
  _task_human_send_allowed() { return 0; }
  _task_gate_bot_token() { printf 'TOKEN'; }
  _mirror_delete_message() { printf '{"ok":false,"description":"x"}'; }
  _mirror_edit_text() { printf '%s\x1f%s\x1f%s\x1fno-reply-markup\n' "$2" "$3" "$4" > "$TMP/edit.log"; printf '{"ok":true}'; }
  _task_gate_card_apply DIVE-571 settle "answered by human:drop" human:drop
) >/dev/null 2>&1
IFS=$'\x1f' read -r e_chat e_mid e_text e_kb < <(tr '\n' ' ' < "$TMP/edit.log")
[[ "$e_mid" == 777 && "$e_text" == *"TGADS_API_KEY saved via the secure link"* && "$e_text" == *"Nothing to tap"* && "$e_text" != *Provided* \
   && "$(db "SELECT state FROM gate_cards WHERE message_id='777';")" == struck ]] \
  && ok_t "L12f the Telegram card is edited to 'saved via the secure link', with no Provided button, and recorded struck" \
  || bad_t "L12f gate card after the drop" "edit=[$(cat "$TMP/edit.log" 2>/dev/null)] state=$(db "SELECT state FROM gate_cards WHERE message_id='777';")"

# --- L14: DIVE-6205 — the page's verdict, the second link, the closed page -------
# A (teal-fox, 2026-10-13): the owner saved, the gate closed, and the page said
# "Nothing was saved. Try the link again": `task answer --from=drop` waited on a
# wake into a mid-turn seat (up to 105s) and the page gives up at 60s. Here the
# wake is held for HOLD seconds and the page's budget is PAGE seconds, HOLD > PAGE,
# the same shape at a scale a PR can run (box: 90 and 60; run it so with
# DIVE6205_HOLD_S=90 DIVE6205_PAGE_S=60).
HOLD="${DIVE6205_HOLD_S:-6}"; PAGE_S="${DIVE6205_PAGE_S:-4}"
PORT4=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
FIVE_SECRET_DROP_RUN_TIMEOUT="$PAGE_S" SLOW_SEND="$HOLD" \
  python3 "$TMP/server.py" 127.0.0.1 "$PORT4" "$WRAP2" "$SECRET_DROP_DIR" 0 2> "$TMP/server4.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT4/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
: > "$TMP/sends.log"; : > "$TMP/slow-send.log"
seed_gate DIVE-61 HELD_API_KEY e2e61
out=$(mint DIVE-61); tok=$(tok_of "$out")
t0=$(date +%s%N)
code=$(curl -s -o "$TMP/post4.html" -w '%{http_code}' --data-urlencode "value=held-value" "http://127.0.0.1:$PORT4/$tok")
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
[[ "$code" == 200 && -n "$(ans_at DIVE-61)" ]] && (( ms < PAGE_S * 1000 )) \
   && grep -q '<h1>Saved</h1>' "$TMP/post4.html" && ! grep -q 'Nothing was saved' "$TMP/post4.html" \
  && ok_t "L14a ACCEPTANCE: the filer seat held mid-turn (wake ${HOLD}s > page ${PAGE_S}s) -> 200 Saved in ${ms}ms, gate answered" \
  || bad_t "L14a held seat -> 200 Saved, fast, gate answered" "code=$code ms=$ms at=$(ans_at DIVE-61) body=$(head -c 300 "$TMP/post4.html")"
[[ -s "$TMP/slow-send.log" && ! -s "$TMP/sends.log" ]] \
  && ok_t "L14b the wake was handed off and is still running when the page answers" \
  || bad_t "L14b wake handed off, still running" "slow=$(cat "$TMP/slow-send.log") sends=$(cat "$TMP/sends.log")"
wait_for_line "HELD_API_KEY is in" "$TMP/sends.log" $(( (HOLD + 5) * 10 ))
grep -q -- "--wake" "$TMP/sends.log" && grep -q "DIVE-61 secret gate provided" "$TMP/sends.log" \
  && ok_t "L14c ...and the seat is still pinged and woken afterwards" \
  || bad_t "L14c the wake still happens" "sends=$(cat "$TMP/sends.log")"
# The page's own budget runs out (here: the gate clear itself is slow). The value
# may be saved, so the page never says it was not.
seed_gate DIVE-62 SLOW_API_KEY e2e62
out=$(mint DIVE-62); tok=$(tok_of "$out")
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
FIVE_SECRET_DROP_RUN_TIMEOUT=1 SLOW_ANSWER=3 \
  python3 "$TMP/server.py" 127.0.0.1 "$PORT4" "$WRAP2" "$SECRET_DROP_DIR" 0 2> "$TMP/server4.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT4/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
code=$(curl -s -o "$TMP/post5.html" -w '%{http_code}' --data-urlencode "value=slow-value" "http://127.0.0.1:$PORT4/$tok")
[[ "$code" == 504 ]] && grep -q 'It may have been saved. Ask your agent before trying again' "$TMP/post5.html" \
   && ! grep -q 'Nothing was saved\|Try the link again' "$TMP/post5.html" \
  && ok_t "L14d a page timeout says 'it may have been saved, ask your agent', never 'Nothing was saved'" \
  || bad_t "L14d page timeout wording" "code=$code body=$(head -c 300 "$TMP/post5.html")"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# The detached ping goes to its own systemd unit when it can (the page's unit
# stops, killing its children, once the page idles out).
(
  _task_answer_ping_unit_ok() { return 0; }
  five_self_bundle() { printf '/opt/5dive/bin/5dive'; }
  systemd-run() { printf '%s\n' "$*" > "$TMP/sdrun.log"; }
  _task_answer_ping_detached mailer --wake --from=human --message='DIVE-1 provided'
) ; rc=$?
[[ $rc -eq 0 && "$(cat "$TMP/sdrun.log" 2>/dev/null)" == "--quiet --collect --setenv=_5DIVE_SYSTEM_NOTICE=1 /opt/5dive/bin/5dive agent send mailer --wake --from=human --message=DIVE-1 provided" ]] \
  && ok_t "L14e with systemd and root, the ping is its own transient unit: agent send, a system notice, --wake kept" \
  || bad_t "L14e systemd-run ping" "rc=$rc argv=$(cat "$TMP/sdrun.log" 2>/dev/null)"

# B: an agent asking for a link while the gate's link is live is told so.
seed_gate DIVE-63 SECOND_API_KEY e2e63
LINK_CALLER="" mint DIVE-63 >/dev/null   # the gate's alert (it passes --again; the box caller is never refused)
n0=$(ls "$SECRET_DROP_DIR" | wc -l)
out=$(LINK_CALLER=mailer mint DIVE-63); rc=$?
[[ $rc -eq 3 && "$(ls "$SECRET_DROP_DIR" | wc -l)" == "$n0" && "$out" == *"already live"* && "$out" == *"--again"* && "$out" == *UTC* ]] \
  && ok_t "L14f an agent's second 'secret link' while one is live exits 3, names the expiry and --again, mints nothing" \
  || bad_t "L14f second link refused" "rc=$rc n=$n0->$(ls "$SECRET_DROP_DIR" | wc -l) out=$out"
out=$(LINK_CALLER=mailer mint DIVE-63 --again); rc=$?
[[ $rc -eq 0 && -n "$(tok_of "$out")" && "$(ls "$SECRET_DROP_DIR" | wc -l)" == $((n0 + 1)) ]] \
  && ok_t "L14g ...and with --again it mints one" \
  || bad_t "L14g --again mints" "rc=$rc out=$out"
out=$(LINK_CALLER="" mint DIVE-63); rc=$?
[[ $rc -eq 0 && -n "$(tok_of "$out")" ]] \
  && ok_t "L14h control: the app's card (the box, not an agent) still gets a fresh link while one is live" \
  || bad_t "L14h the card keeps minting" "rc=$rc out=$out"
seed_gate DIVE-64 FIRST_API_KEY e2e64
out=$(LINK_CALLER=mailer mint DIVE-64); rc=$?
[[ $rc -eq 0 && -n "$(tok_of "$out")" ]] \
  && ok_t "L14i control: an agent's FIRST link (none live) is minted as before" \
  || bad_t "L14i first link" "rc=$rc out=$out"
for f in "$SECRET_DROP_DIR"/*; do grep -q '^task=DIVE-64$' "$f" && sed -i "s/^expires=.*/expires=$(( $(date +%s) - 5 ))/" "$f"; done
out=$(LINK_CALLER=mailer mint DIVE-64); rc=$?
[[ $rc -eq 0 && -n "$(tok_of "$out")" ]] \
  && ok_t "L14j control: an expired link does not count as live" \
  || bad_t "L14j expired is not live" "rc=$rc out=$out"

# --- L15: DIVE-6727 — a refused paste names the rule, and the agent is told -----
# teal-fox, 2026-10-21: four pastes of a one-line key into a tools link, each
# answered "The server refused that value", while the agent re-filed the gate.
# The page's bundle with two seams: the agent send is a log line (detached, as on
# the box), and a break-write flag file makes a named connector's write fail (its lock path
# cannot be opened), the one way a value-agnostic write refuses.
WRAP3="$TMP/5dive-bundle-6727"; SENDS6727="$TMP/sends-6727.log"; : > "$SENDS6727"
sed "s#^shift   \# the page calls#_gate_is_root() { return 1; }; cmd_send() { printf '%s\\\\n' \"\\\$*\" >> \"$SENDS6727\"; }\n[[ -f \"$TMP/break-write\" ]] \&\& SECRET_WRITE_LOCK=\"$TMP/no-such-dir/write.lock\"\nshift   \# the page calls#" "$WRAP" > "$WRAP3"; chmod +x "$WRAP3"
PORT5=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$TMP/server.py" 127.0.0.1 "$PORT5" "$WRAP3" "$SECRET_DROP_DIR" 0 2> "$TMP/server5.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT5/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
B5="http://127.0.0.1:$PORT5"
body_of() { sed -n 's#.*<main>\(.*\)</main>.*#\1#p' "$1"; }   # the page's words, not its CSS
seed_gate DIVE-671 DEMO_API_KEY tools
out=$(mint DIVE-671); tok=$(tok_of "$out")
code=$(curl -s -o "$TMP/r1.html" -w '%{http_code}' --data-urlencode "value=a b" "$B5/$tok")
r1=$(body_of "$TMP/r1.html")
[[ "$code" == 400 && "$r1" == *"with no spaces and no"* && "$r1" == *"The link still works"* && "$r1" != *"The server refused that value"* \
   && -f "$SECRET_DROP_DIR/$(hash_of "$tok")" ]] \
  && ok_t "L15a ACCEPTANCE: 'a b' into a tools link -> the page names the tools rule (one line, no spaces or ' mark), the link still works" \
  || bad_t "L15a the refusal names the tools rule" "code=$code body=$r1"
wait_for_line "DIVE-671: your owner's paste for DEMO_API_KEY" "$SENDS6727"
msg=$(grep -F 'DIVE-671:' "$SENDS6727")
[[ "$msg" == "mailer --wake --message=DIVE-671: your owner's paste for DEMO_API_KEY on the secure link was refused at "*" UTC; nothing was saved and the link still works. The rule the page showed them: It must be one line, with no spaces"*"Do not file a new gate"* ]] \
  && ok_t "L15b the seat that filed the gate is told, woken: refused at <time>, the same rule, do not re-file" \
  || bad_t "L15b the filer is told of the refusal" "sends: $(cat "$SENDS6727")"
! grep -qF 'a b' <<<"$r1" && ! grep -qF 'a b' "$SENDS6727" && ! grep -qF 'a b' "$TMP/server5.log" \
  && ok_t "L15c the pasted value is in neither the page body, the agent message nor the server log" \
  || bad_t "L15c the value leaked" "body=$r1 sends=$(cat "$SENDS6727")"
code=$(curl -s -o "$TMP/r2.html" -w '%{http_code}' --data-urlencode "value=x'y" "$B5/$tok")
sleep 1
[[ "$code" == 400 && "$(grep -c 'DIVE-671:' "$SENDS6727")" == 1 ]] \
  && ok_t "L15d a second refusal on the same link inside ${SECRET_DROP_REFUSED_TELL_S:-600}s does not tell the agent again" \
  || bad_t "L15d the tell is rate-limited" "code=$code sends=$(cat "$SENDS6727")"
sed -i "s/^refused_told=.*/refused_told=$(( $(date +%s) - ${SECRET_DROP_REFUSED_TELL_S:-600} - 1 ))/" "$SECRET_DROP_DIR/$(hash_of "$tok")"
curl -s -o /dev/null --data-urlencode "value=a b" "$B5/$tok"
for _ in $(seq 1 50); do [[ "$(grep -c 'DIVE-671:' "$SENDS6727")" == 2 ]] && break; sleep 0.1; done
[[ "$(grep -c 'DIVE-671:' "$SENDS6727")" == 2 ]] \
  && ok_t "L15e ...and past the window a refusal tells it again" \
  || bad_t "L15e the window reopens" "sends=$(cat "$SENDS6727")"
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "value=demo-key-6727" "$B5/$tok")
[[ "$code" == 200 ]] && grep -qxF "export DEMO_API_KEY='demo-key-6727'" "$TOOLS_ENV_FILE" \
  && ok_t "L15f control: the corrected paste on the same link saves" \
  || bad_t "L15f the corrected paste saves" "code=$code"
mkdir -p "$SECRET_PROJECTS_DIR/shop6727"
seed_gate DIVE-672 SHOP_API_KEY project-shop6727
out=$(mint DIVE-672); tok=$(tok_of "$out")
code=$(curl -s -o "$TMP/r3.html" -w '%{http_code}' --data-urlencode 'value=sk$1#x' "$B5/$tok")
r3=$(body_of "$TMP/r3.html")
[[ "$code" == 400 && "$r3" == *"only letters, digits and these marks: _ . / : + = @ , ~ -"* && "$r3" != *'sk$1#x'* ]] \
  && ok_t "L15g a project-<app> link names the characters an app's .env line can hold" \
  || bad_t "L15g the project rule" "code=$code body=$r3"
seed_gate DIVE-673 OVH_KEYS ovh6727
out=$(mint DIVE-673); tok=$(tok_of "$out"); : > "$TMP/break-write"
code=$(curl -s -o "$TMP/r4.html" -w '%{http_code}' --data-urlencode "value=Zq7 multi-line ok" "$B5/$tok"); rm -f "$TMP/break-write"
r4=$(body_of "$TMP/r4.html")
[[ "$code" == 400 && "$r4" == *"takes any value, line breaks included"* && "$r4" != *Zq7* ]] \
  && ok_t "L15h a named connector's refusal says the value was not the problem (it takes multi-line values)" \
  || bad_t "L15h the named-connector rule" "code=$code body=$r4"
printf '%s\n' "$r1" "$r3" "$r4" > "$TMP/rc3-pages.txt"
[[ -n "${DIVE6727_PAGES_OUT:-}" ]] && cp "$TMP/rc3-pages.txt" "$DIVE6727_PAGES_OUT"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- L16: DIVE-6844 — a saved login: a link with no task, listed by name --------
# lodar 2026-10-24: "user can see what he saved and remove or set new or rewrite".
# A saved value is one more secret, in a root-only store no agent reads, added and
# rewritten only through the one-time link, listed by NAME, removed by name.
SAVED="$CONNECTORS_DIR/saved.env"
rm -f "$SAVED"
# DIVE-6973: a saved line is v1:<ciphertext>; this reads it back with the box key.
saved_val() { local l; l=$(sed -n "s/^${1}=//p" "$SAVED" | head -n 1); [[ -n "$l" ]] && _vault_dec "$l"; }
out=$(mint --save=linkedin-password); rc=$?; tok=$(tok_of "$out"); h=$(hash_of "$tok")
[[ $rc -eq 0 && -n "$tok" && "$(jq -r '.data.save' <<<"$out")" == linkedin-password ]] \
  && grep -qx 'task=' "$SECRET_DROP_DIR/$h" && grep -qx 'save=linkedin-password' "$SECRET_DROP_DIR/$h" \
  && grep -qx 'key=LINKEDIN_PASSWORD' "$SECRET_DROP_DIR/$h" && grep -qx 'connector=saved' "$SECRET_DROP_DIR/$h" \
  && ok_t "L16a secret link --save=<name> mints a link bound to no task, writing <NAME> into the saved store" \
  || bad_t "L16a a task-less save link" "rc=$rc out=$out entry=$(cat "$SECRET_DROP_DIR/$h" 2>/dev/null)"
bad=""
for n in LinkedIn 1password a--b trail- 'a b' "$(printf 'x%.0s' $(seq 1 41))"; do
  mint --save="$n" >/dev/null 2>&1 && bad+="[$n] "
done
mint DIVE-11 --save=x >/dev/null 2>&1 && bad+="[task+save] "
[[ -z "$bad" ]] && ok_t "L16b a name must be lowercase letters, digits and dashes from a letter, <=40; a gate and a save never share a link" \
  || bad_t "L16b bad names refused" "accepted: $bad"
PORT6=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$TMP/server.py" 127.0.0.1 "$PORT6" "$WRAP" "$SECRET_DROP_DIR" 0 2> "$TMP/server6.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT6/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
B6="http://127.0.0.1:$PORT6"
code=$(curl -s -o "$TMP/s1.html" -w '%{http_code}' "$B6/$tok")
[[ "$code" == 200 ]] && grep -q 'Save <b>linkedin-password</b>' "$TMP/s1.html" && grep -q '<textarea name=value class=secret' "$TMP/s1.html" \
  && ! grep -q 'needs\|the task' "$TMP/s1.html" \
  && ok_t "L16c the page says what is saved, by name, with the masked field and no task or agent" \
  || bad_t "L16c the save page" "code=$code $(sed -n 's#.*<main>\(.*\)</main>.*#\1#p' "$TMP/s1.html" | head -c 400)"
V1='Pa55-word one'
code=$(curl -s -o "$TMP/s2.html" -w '%{http_code}' --data-urlencode "value=$V1" "$B6/$tok")
[[ "$code" == 200 && "$(grep -c '^LINKEDIN_PASSWORD=v1:' "$SAVED")" == 1 && "$(saved_val LINKEDIN_PASSWORD)" == "$V1" && "$(stat -c %a "$SAVED")" == 600 ]] \
  && ! grep -qF "$V1" "$SAVED" \
  && grep -q '<b>linkedin-password</b> is on your server now' "$TMP/s2.html" \
  && ! grep -qF "$V1" "$TMP/s2.html" && ! grep -qF "$V1" "$TMP/server6.log" \
  && ok_t "L16d POST saves it once in saved.env (600), and the value is in neither the page nor the log" \
  || bad_t "L16d the save" "code=$code env=$(cat "$SAVED" 2>/dev/null) body=$(head -c 300 "$TMP/s2.html")"
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "value=again" "$B6/$tok")
[[ "$code" == 404 ]] && ok_t "L16e the save link is dead after one use" || bad_t "L16e single use" "code=$code"
# Rewrite: a fresh link for the same name replaces the value; two live links for
# one name, and using one burns the other.
printf 'LINKEDIN_PASSWORD=linkedin.com\nGITHUB_TOKEN=github.com\n' > "$CONNECTORS_DIR/saved.hosts"
o1=$(mint --save=linkedin-password); t1=$(tok_of "$o1")
o2=$(mint --save=linkedin-password); t2=$(tok_of "$o2")
V2='new-Pa55'
code=$(curl -s -o /dev/null -w '%{http_code}' --data-urlencode "value=$V2" "$B6/$t2")
[[ "$code" == 200 && "$(grep -c '^LINKEDIN_PASSWORD=' "$SAVED")" == 1 && "$(saved_val LINKEDIN_PASSWORD)" == "$V2" ]] \
  && ! grep -qF "$V1" "$SAVED" && [[ ! -f "$SECRET_DROP_DIR/$(hash_of "$t1")" ]] \
  && [[ "$(cat "$CONNECTORS_DIR/saved.hosts")" == 'GITHUB_TOKEN=github.com' ]] \
  && ok_t "L16f rewrite: a new link for the name replaces the value (one line), burns the name's other link, and frees it from its old site" \
  || bad_t "L16f rewrite" "code=$code env=$(cat "$SAVED")"
o3=$(mint --save=github-token); t3=$(tok_of "$o3")
code=$(curl -s -o "$TMP/s3.html" -w '%{http_code}' --data-urlencode $'value=line one\r\nline two' "$B6/$t3")
[[ "$code" == 400 ]] && grep -q 'typed into one field' "$TMP/s3.html" && ! grep -q '^GITHUB_TOKEN' "$SAVED" \
  && [[ -f "$SECRET_DROP_DIR/$(hash_of "$t3")" ]] \
  && ok_t "L16g a value of two lines is refused with the one-line rule, and the link still works" \
  || bad_t "L16g multi-line refused" "code=$code env=$(cat "$SAVED")"
curl -s -o /dev/null --data-urlencode "value=ghp-fixture-6844" "$B6/$t3"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
ls_out=$( (JSON_MODE=1; _secret_saved ls) 2>&1 )
[[ "$(jq -c '.data.names' <<<"$ls_out")" == '["github-token","linkedin-password"]' ]] \
  && ! grep -qF "$V2" <<<"$ls_out" && ! grep -qF 'ghp-fixture' <<<"$ls_out" \
  && ok_t "L16h secret saved ls lists the names, never a value" \
  || bad_t "L16h names only" "$ls_out"
! grep -qF "$V2" "$TOOLS_ENV_FILE" 2>/dev/null && ! grep -qF 'ghp-fixture' "$TOOLS_ENV_FILE" 2>/dev/null \
  && ok_t "L16i a saved value never lands in tools.sh (the file every agent loads)" \
  || bad_t "L16i not in tools.sh" "$(cat "$TOOLS_ENV_FILE")"
rm_out=$( (JSON_MODE=1; _secret_saved rm linkedin-password) 2>&1 ); rc=$?
rm2=$( (_secret_saved rm linkedin-password) 2>&1 ); rc2=$?
[[ $rc -eq 0 && $rc2 -ne 0 && "$(jq -c '.data.names' <<<"$( (JSON_MODE=1; _secret_saved ls) 2>&1 )")" == '["github-token"]' ]] \
  && [[ "$(saved_val GITHUB_TOKEN)" == ghp-fixture-6844 ]] \
  && printf 'GITHUB_TOKEN=github.com\n' > "$CONNECTORS_DIR/saved.hosts" && ( _secret_saved rm github-token ) >/dev/null 2>&1 \
  && [[ ! -s "$CONNECTORS_DIR/saved.hosts" ]] \
  && ok_t "L16j saved rm <name> forgets that one (and its site) and keeps the rest; a second rm says nothing is saved" \
  || bad_t "L16j remove" "rc=$rc out=$rm_out rc2=$rc2 out2=$rm2 env=$(cat "$SAVED")"

# --- L17: DIVE-6973 — Vault v2: encrypted at rest, a login pair, last use ------
# lodar 2026-10-26: "can vault be encoded?", "login password pair?", "warn to
# create new account for agents". Every arm that says "never" makes the value
# reachable first (it is in the store, it was just typed), then counts 0.
VK="$SECRET_VAULT_KEY"; USAGE="$CONNECTORS_DIR/saved.usage"; HOSTS="$CONNECTORS_DIR/saved.hosts"
rm -f "$SAVED" "$USAGE" "$HOSTS"
grep -q 'Best to make a separate account for your agents. On your own account, they can do anything you can.' "$TMP/s1.html" \
  && ok_t "L17a the one-value save page carries the separate-account tip above the field" \
  || bad_t "L17a separate-account tip on the plain save page" "$(head -c 300 "$TMP/s1.html")"
[[ -f "$VK" && "$(stat -c %a "$VK")" == 400 && "$(tr -d '\n' < "$VK" | wc -c)" == 64 ]] \
  && ok_t "L17b the first save made the box key: 400, 32 random bytes as hex" \
  || bad_t "L17b vault.key" "$(ls -la "$VK" 2>&1)"
# An old (DIVE-6844) one-value item for the same name, bound to a site, so the
# pair can be seen to replace it and free the site.
printf 'old-one-value' | ( _secret_write GITHUB --connector=saved ) >/dev/null 2>&1
printf 'GITHUB=github.com\nOTHER=example.org\n' > "$HOSTS"
PL='owner@example.com'; PP='Pa55 w0rd with spaces '; PS='jbsw y3dp ehpk 3pxp'; SEED=JBSWY3DPEHPK3PXP
o=$(mint --save=github --pair); tp=$(tok_of "$o"); hp=$(hash_of "$tp")
[[ "$(jq -r '.data.pair' <<<"$o")" == true ]] && grep -qx 'pair=1' "$SECRET_DROP_DIR/$hp" \
  && ! mint --pair >/dev/null 2>&1 && ! mint DIVE-11 --pair >/dev/null 2>&1 \
  && ok_t "L17c secret link --save=<name> --pair mints a pair link; --pair without --save is refused" \
  || bad_t "L17c pair link" "$o"
PORT7=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$TMP/server.py" 127.0.0.1 "$PORT7" "$WRAP" "$SECRET_DROP_DIR" 0 2> "$TMP/server7.log" & SRV_PID=$!
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT7/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
B7="http://127.0.0.1:$PORT7"
code=$(curl -s -o "$TMP/p1.html" -w '%{http_code}' "$B7/$tp")
[[ "$code" == 200 ]] && grep -q '>Login</label>' "$TMP/p1.html" && grep -q '>Password</label>' "$TMP/p1.html" \
  && grep -q '>2FA setup key (optional)</label>' "$TMP/p1.html" \
  && grep -q 'Best to make a separate account for your agents. On your own account, they can do anything you can.' "$TMP/p1.html" \
  && grep -q 'With this, your agents can sign in without you. Use it on an account made for them.' "$TMP/p1.html" \
  && grep -q '<textarea id=f-password name=password class=secret' "$TMP/p1.html" && ! grep -q 'type=password' "$TMP/p1.html" \
  && ok_t "L17d the pair page asks Login, Password, '2FA setup key (optional)', with both warning lines; the password is masked, never type=password" \
  || bad_t "L17d pair page" "code=$code $(sed -n 's#.*<main>\(.*\)</main>.*#\1#p' "$TMP/p1.html" | head -c 600)"
code=$(curl -s -o "$TMP/p2.html" -w '%{http_code}' --data-urlencode "login=$PL" --data-urlencode $'password=two\nlines' --data-urlencode "totp=" "$B7/$tp")
code2=$(curl -s -o "$TMP/p3.html" -w '%{http_code}' --data-urlencode "login=$PL" --data-urlencode "password=$PP" --data-urlencode "totp=not-a-key!" "$B7/$tp")
[[ "$code" == 400 && "$code2" == 400 && -f "$SECRET_DROP_DIR/$hp" ]] && grep -q 'letters A-Z and digits 2-7' "$TMP/p3.html" \
  && [[ "$(saved_val GITHUB)" == old-one-value ]] && ! grep -q '^GITHUB__' "$SAVED" \
  && ok_t "L17e a two-line password or a bad 2FA key is refused whole (nothing written), with the rule, and the link still works" \
  || bad_t "L17e pair refusal" "code=$code code2=$code2 env=$(cat "$SAVED")"
code=$(curl -s -o "$TMP/p4.html" -w '%{http_code}' --data-urlencode "login=$PL" --data-urlencode "password=$PP" --data-urlencode "totp=$PS" "$B7/$tp")
[[ "$code" == 200 && ! -f "$SECRET_DROP_DIR/$hp" ]] && grep -q 'sign in with it' "$TMP/p4.html" \
  && [[ "$(saved_val GITHUB__LOGIN)" == "$PL" && "$(saved_val GITHUB__PASSWORD)" == "$PP" && "$(saved_val GITHUB__2FA)" == "$SEED" ]] \
  && ! grep -q '^GITHUB=' "$SAVED" && [[ "$(cat "$HOSTS")" == 'OTHER=example.org' ]] \
  && ok_t "L17f a pair POST writes login, password and the 2FA seed as one item, drops the old one-value line and frees the site" \
  || bad_t "L17f pair save" "code=$code env=$(cat "$SAVED") hosts=$(cat "$HOSTS")"
bad=""
for v in "$PL" "$PP" "$SEED" 'Pa55' 'owner@' old-one-value; do grep -qF -- "$v" "$SAVED" && bad+="[$v] "; done
[[ -z "$bad" ]] && [[ "$(grep -cE '^[A-Z][A-Z0-9_]*=' "$SAVED")" == "$(grep -cE '^[A-Z][A-Z0-9_]*=v1:' "$SAVED")" ]] \
  && ! grep -qF -- "$PP" "$TMP/p4.html" && ! grep -qF -- "$PP" "$TMP/server7.log" \
  && ok_t "L17g NEGATIVE CONTROL: saved.env holds no value in the clear after a save (every line v1:), and the page and log never echo it" \
  || bad_t "L17g plaintext in saved.env" "found: $bad file=$(cat "$SAVED")"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# Migration: a DIVE-6844 box's plain line is encrypted by the first saved verb
# run as root, and still reveals by its bare name.
printf 'OLD_ITEM=plain-old-1\n' >> "$SAVED"
printf 'GITHUB=github.com\n' > "$HOSTS"
ls_out=$( (JSON_MODE=1; _secret_saved ls) 2>&1 )
[[ "$(saved_val OLD_ITEM)" == plain-old-1 ]] && ! grep -qF plain-old-1 "$SAVED" && grep -q '^OLD_ITEM=v1:' "$SAVED" \
  && ok_t "L17h migration: a plain saved line is encrypted in place by the first saved verb, and nothing plain is left" \
  || bad_t "L17h migration" "$(cat "$SAVED")"
want='{"names":["github","old-item"],"items":[{"name":"github","fields":["login","password","2fa"],"login":"owner@example.com","host":"github.com","lastUsedAt":null,"lastUsedBy":null},{"name":"old-item","fields":["value"],"login":null,"host":null,"lastUsedAt":null,"lastUsedBy":null}]}'
[[ "$(jq -c '.data' <<<"$ls_out")" == "$want" ]] \
  && ok_t "L17i saved ls --json: names kept, items carry fields, the login, the site and last use (none yet)" \
  || bad_t "L17i ls shape" "$ls_out"
r=$( (JSON_MODE=0; _secret_reveal --agent=kostya --host=github.com github.login github.password github.2fa old-item) 2>"$TMP/rv.err" ); rc=$?
[[ $rc -eq 0 && "$(jq -r '."github.login"' <<<"$r")" == "$PL" && "$(jq -r '."github.password"' <<<"$r")" == "$PP" \
   && "$(jq -r '."github.2fa"' <<<"$r")" == "$SEED" && "$(jq -r '."old-item"' <<<"$r")" == plain-old-1 && "$(jq -r 'keys|length' <<<"$r")" == 4 ]] \
  && ok_t "L17j _reveal answers each ref with its plaintext; an old one-value item still answers by its bare name" \
  || bad_t "L17j reveal" "rc=$rc err=$(cat "$TMP/rv.err")"
[[ "$(wc -l < "$USAGE")" == 2 && "$(stat -c %a "$USAGE")" == 600 ]] \
  && grep -qE '^github github\.com kostya [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$USAGE" \
  && grep -qE '^old-item github\.com kostya ' "$USAGE" \
  && ok_t "L17k _reveal writes ONE usage line per item (<name> <host> <agent> <utc>), 600" \
  || bad_t "L17k usage" "$(cat "$USAGE" 2>&1)"
before=$(wc -l < "$USAGE")
r=$( (JSON_MODE=1; _secret_reveal --agent=kostya --host=github.com github.password nope.password) 2>"$TMP/rv2.err" ); rc=$?
[[ $rc -eq 4 && -z "$r" && "$(wc -l < "$USAGE")" == "$before" ]] && grep -q 'nope.password' "$TMP/rv2.err" \
  && ! grep -qF -- "$PP" "$TMP/rv2.err" \
  && ok_t "L17l NEGATIVE CONTROL: a missing ref -> exit 4 naming it, NOTHING on stdout (even --json) and no usage line" \
  || bad_t "L17l missing ref" "rc=$rc out=[$r] usage=$(wc -l < "$USAGE") err=$(cat "$TMP/rv2.err")"
ls_out=$( (JSON_MODE=1; _secret_saved ls) 2>&1 ); ls_h=$( (JSON_MODE=0; _secret_saved ls) 2>&1 )
bad=""
for v in "$PP" "$SEED" plain-old-1 'Pa55'; do
  grep -qF -- "$v" <<<"$ls_out$ls_h" && bad+="[ls:$v] "
  grep -qF -- "$v" "$USAGE" && bad+="[usage:$v] "
done
[[ -z "$bad" && "$(jq -r '.data.items[0].lastUsedBy' <<<"$ls_out")" == kostya && "$(jq -r '.data.items[0].lastUsedAt' <<<"$ls_out")" =~ Z$ ]] \
  && grep -qx 'github (owner@example.com), used by kostya just now' <<<"$ls_h" \
  && ok_t "L17m NEGATIVE CONTROL: ls (json and human) and the usage file never hold a password, 2FA key or value; ls shows 'used by kostya just now'" \
  || bad_t "L17m no value in ls/usage" "bad=$bad ls=$ls_out human=$ls_h"
# A store copied to a box with another key: names stay, values are refused, never garbage.
cp -p "$VK" "$TMP/vk.bak"; chmod 600 "$VK"; openssl rand -hex 32 > "$VK"
r=$( (_secret_reveal --agent=kostya --host=github.com github.password) 2>"$TMP/rv3.err" ); rc=$?
[[ $rc -eq 5 && -z "$r" ]] && grep -q 'save it again' "$TMP/rv3.err" \
  && ok_t "L17n under another box's key a value is refused ('save it again'), nothing on stdout" \
  || bad_t "L17n wrong key" "rc=$rc out=[$r] err=$(cat "$TMP/rv3.err")"
cp -p "$TMP/vk.bak" "$VK"
# `secret write` at the terminal: one field of a pair, the 2FA key normalised; a
# one-value write drops the pair.
printf 'otpauth://totp/x?secret=NBSWY3DPEB3W64TMMQ&issuer=x' | ( _secret_write GITHUB__2FA --connector=saved ) >/dev/null 2>&1; rc=$?
printf 'junk!' | ( _secret_write GITHUB__2FA --connector=saved ) >/dev/null 2>&1; rc2=$?
[[ $rc -eq 0 && $rc2 -ne 0 && "$(saved_val GITHUB__2FA)" == NBSWY3DPEB3W64TMMQ && "$(saved_val GITHUB__PASSWORD)" == "$PP" ]] \
  && ok_t "L17o secret write <KEY>__2FA takes an otpauth link or a spaced key down to its seed, keeps the pair's other fields, refuses junk" \
  || bad_t "L17o write a field" "rc=$rc rc2=$rc2"
printf 'GITHUB=github.com\n' > "$HOSTS"
out=$( (JSON_MODE=1; _secret_saved rm github) 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^GITHUB' "$SAVED" && [[ ! -s "$HOSTS" ]] && ! grep -q '^github ' "$USAGE" && grep -q '^old-item ' "$USAGE" \
  && ok_t "L17p saved rm <pair> removes every field, its site and its usage lines, and keeps the rest" \
  || bad_t "L17p rm pair" "rc=$rc env=$(cat "$SAVED") usage=$(cat "$USAGE")"
# Key exclusion: the export stage's tripwire refuses the Vault's files by name.
EXP="$TMP/export-stage"; bad=""
for nm in vault.key saved.env saved.hosts saved.usage; do
  rm -rf "$EXP"; mkdir -p "$EXP/etc"; printf 'x\n' > "$EXP/etc/$nm"
  ( source src/cmd_pack.sh >/dev/null 2>&1; _pack_secret_tripwire "$EXP" ) >/dev/null 2>&1 && bad+="[$nm] "
done
rm -rf "$EXP"; mkdir -p "$EXP"; printf 'x\n' > "$EXP/notes-about-vault.md"
( source src/cmd_pack.sh >/dev/null 2>&1; _pack_secret_tripwire "$EXP" ) >/dev/null 2>&1 || bad+="[false-positive] "
[[ -z "$bad" ]] \
  && ok_t "L17q NEGATIVE CONTROL: agent export's tripwire refuses a stage holding vault.key or a saved.* file (and passes a note that names the Vault)" \
  || bad_t "L17q key exclusion" "let through: $bad"
# No path in the CLI copies /etc/5dive: a tar/cp/rsync naming it, or the key, is new.
hits=$(grep -rnE '(\btar\b|\brsync\b|\bcp\b|\bscp\b)[^#]*(/etc/5dive([/" ]|$)|vault\.key|saved\.env)' src scripts install.sh 2>/dev/null || true)
[[ -z "$hits" ]] \
  && ok_t "L17r no tar, cp, rsync or scp in the CLI names /etc/5dive, vault.key or saved.env" \
  || bad_t "L17r a copy path names the Vault" "$hits"

echo
echo "secret-drop-link unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
