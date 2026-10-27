#!/usr/bin/env bash
# DIVE-7113 unit harness: https ON a self-hosted box, so its agents send the same
# one-time secret links a hosted box does.
#   * the first `secret link` on a box with no FIVE_DOMAIN makes its own https:
#     a Let's Encrypt IP certificate, else <ip>.sslip.io; only when both fail is
#     the owner asked for a domain or sent to the terminal (two plain asks).
#   * `secret https enable --via=domain --host=<name>` (lodar's "self").
#   * a hosted box (FIVE_DOMAIN) is never touched; a busy 80/443 is never taken.
#   * MARKER: a value pasted through the self-hosted link reaches the connector
#     file and nothing else this harness can see: no outbound call, no 5dive
#     call's argv, no journal line, no page log, no config file.
# Isolation: src/ libs sourced, every path in TMP; systemctl, ss, caddy, curl and
# ip are mocks on PATH. No root, no network beyond 127.0.0.1. A real Caddy
# (CADDY_REAL=<binary>, >= 2.11) also adapts the generated Caddyfiles when given.
# Run: bash tests/secret_https_selfhost_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

trap 'rc=$?; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; [[ -n "${KEEP_TMP:-}" ]] || rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
REPO="$(pwd)"
TMP="$(mktemp -d /tmp/secret-https-selfhost-unit.XXXXXX)"

LIBS="header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh lib/actor.sh lib/self.sh cmd_task.sh cmd_tool.sh cmd_secret.sh cmd_secret_drop.sh"
for f in $LIBS; do
  # shellcheck source=/dev/null
  source "src/$f"
done

export STATE_DIR="$TMP/state"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
export CONNECTORS_DIR="$TMP/connectors"
SECRET_DROP_DIR="$STATE_DIR/secret-drop"
SECRET_DROP_CONF="$TMP/etc5dive/secret-drop.env"
SECRET_DROP_PROVISIONING="$TMP/etc5dive/provisioning.env"
SECRET_DROP_CADDYFILE="$TMP/Caddyfile"
SECRET_DROP_LOCK="$TMP/drop.lock"; SECRET_WRITE_LOCK="$TMP/write.lock"
SECRET_VAULT_KEY="$TMP/etc5dive/vault.key"
SECRET_DROP_PROC_NET="$TMP/procnet"; mkdir -p "$SECRET_DROP_PROC_NET" "$TMP/etc5dive"
: > "$SECRET_DROP_PROC_NET/tcp"; : > "$SECRET_DROP_PROC_NET/tcp6"
SECRET_HTTPS_CADDYFILE="$TMP/etc5dive/secret-https.Caddyfile"
SECRET_HTTPS_UNIT_DIR="$TMP/systemd"
SECRET_HTTPS_LOCK="$TMP/https.lock"
SECRET_HTTPS_WAIT_S=1; SECRET_DROP_POLL_S=0; SECRET_DROP_WAIT_S=1
TOOLS_ENV_FILE="$CONNECTORS_DIR/tools.sh"; TOOLS_WRITE_LOCK="$TMP/tools.lock"
export SECRET_PROJECTS_DIR="$TMP/projects"; mkdir -p "$SECRET_PROJECTS_DIR"
export JOURNAL_LOG="$TMP/journal.log"; : > "$JOURNAL_LOG"
require_root() { :; }
_secret_link_agent_caller() { printf ''; }
_secret_https_install_caddy() { [[ -z "${NO_CADDY:-}" ]] || { SECRET_HTTPS_WHY="could not install Caddy 2.11+ (have: none)"; return 1; }; }
_secret_drop_ensure_server() { return 0; }
JSON_MODE=1
set +e

MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
export MOCK_LOG="$TMP/mock-calls.log"; : > "$MOCK_LOG"
export MOCK5DIVE_DB="$TASKS_DB"
cat > "$MOCKBIN/5dive" <<'EOF'
#!/usr/bin/env bash
echo "5dive $*" >> "$MOCK_LOG"
if [[ "${1:-} ${2:-}" == "task answer" ]]; then
  sqlite3 "$MOCK5DIVE_DB" "UPDATE tasks SET need_answered_at=datetime('now') WHERE ident='$3';"
fi
EOF
# `ip`: the box's interfaces. BOX_IP empty = behind NAT (no global IPv4 printed).
cat > "$MOCKBIN/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >> "$MOCK_LOG"
[[ -n "${BOX_IP:-}" ]] && printf '2: eth0    inet %s/32 scope global eth0\n' "$BOX_IP"
exit 0
EOF
# `ss`: BUSY_PORTS="80 443" = something else listens there.
cat > "$MOCKBIN/ss" <<'EOF'
#!/usr/bin/env bash
echo "ss $*" >> "$MOCK_LOG"
for p in ${BUSY_PORTS:-}; do [[ "$*" == *"sport = :$p"* ]] && echo "LISTEN 0 4096 *:$p *:*"; done
exit 0
EOF
cat > "$MOCKBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$MOCK_LOG"
[[ "$1" == is-active ]] && { [[ -n "${LINKTLS_ACTIVE:-}" && "$*" == *browser-link-tls* ]]; exit $?; }
exit 0
EOF
cat > "$MOCKBIN/caddy" <<'EOF'
#!/usr/bin/env bash
echo "caddy $*" >> "$MOCK_LOG"
[[ "$1" == version ]] && { echo "v2.11.2 h1:x"; exit 0; }
exit 0
EOF
# `curl`: TLS_OK_HOSTS = the hosts whose certificate verifies (others: rc 60).
cat > "$MOCKBIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_LOG"
h=""
for a in "$@"; do
  case "$a" in https://*) h="${a#https://}"; h="${h%%/*}" ;; esac
done
for ok in ${TLS_OK_HOSTS:-}; do
  if [[ "$h" == "$ok" ]]; then
    if [[ "$*" == *"-w %{http_code}"* ]]; then printf '410'; else printf '{"ok":true}'; fi
    exit 0
  fi
done
[[ "$*" == *"-w %{http_code}"* ]] && printf '000'
exit 60
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$JOURNAL_LOG"\n' > "$MOCKBIN/logger"
chmod +x "$MOCKBIN"/*
REAL_CURL=$(command -v curl)
PATH="$MOCKBIN:$PATH"; hash -r

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
t()  { [[ "$2" == "$3" ]] && ok_t "$1" || bad_t "$1" "want [$2] got [$3]"; }
tc() { [[ "$3" == *"$2"* ]] && ok_t "$1" || bad_t "$1" "missing [$2] in [$3]"; }
tn() { [[ "$3" != *"$2"* ]] && ok_t "$1" || bad_t "$1" "found [$2] in [$3]"; }

tasks_db_init
task_need_notify() { :; }
seed_gate() {   # <ident> <key> <connector>
  db "INSERT INTO tasks (ident, title, status, created_by, assignee) VALUES ('$1','t','todo','main','olivia');"
  cmd_task_need "$1" --type=secret --ask="An API key for the shop" --secret-key="$2" --connector="$3" >/dev/null 2>&1
}
# A fresh self-hosted box: no FIVE_DOMAIN, no conf, no front.
fresh() {
  rm -f "$SECRET_DROP_PROVISIONING" "$SECRET_DROP_CONF" "$SECRET_HTTPS_CADDYFILE" "$STATE_DIR/secret-https.failed"
  rm -rf "$SECRET_HTTPS_UNIT_DIR" "$SECRET_DROP_DIR"; : > "$MOCK_LOG"
  unset BUSY_PORTS LINKTLS_ACTIVE NO_CADDY
}
link() { ( _secret_link "$@" ) 2>&1; }
url_of() { printf '%s' "$1" | jq -r '.data.url // empty' 2>/dev/null; }
unitf="$SECRET_HTTPS_UNIT_DIR/5dive-secret-https.service"
seed_gate DIVE-21 SHOP_API_KEY shop

# --- H1: the first link turns on an IP certificate by itself --------------------
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10
out=$(link DIVE-21); rc=$?; url=$(url_of "$out")
[[ $rc -eq 0 && "$url" =~ ^https://192\.0\.2\.10/[A-Za-z0-9_-]{43}$ ]] \
  && ok_t "H1a first link on a fresh self-hosted box: https://<public ip>/<token>" \
  || bad_t "H1a first link on a fresh self-hosted box: https://<public ip>/<token>" "rc=$rc out=$out"
t  "H1b the conf names the way and the host" $'SECRET_HTTPS_MODE=ip\nSECRET_HTTPS_HOST=192.0.2.10' "$(cat "$SECRET_DROP_CONF" 2>/dev/null)"
cf=$(cat "$SECRET_HTTPS_CADDYFILE" 2>/dev/null)
tc "H1c ip: Let's Encrypt's shortlived profile (the one that issues IP certs)" $'issuer acme {\n\t\t\tprofile shortlived' "$cf"
tc "H1d ip: default_sni, a client never sends an IP as SNI" $'default_sni 192.0.2.10' "$cf"
tc "H1e no admin endpoint" $'admin off' "$cf"
tc "H1f every path goes to the page on loopback" "reverse_proxy 127.0.0.1:3127" "$cf"
tc "H1g the page down = the closed page, 410" "This request is closed" "$cf"
u=$(cat "$unitf" 2>/dev/null)
tc "H1h unit: Caddy runs as user caddy" "User=caddy" "$u"
tc "H1i unit: the config is handed in by systemd (DIVE-6980)" "LoadCredential=Caddyfile:$SECRET_HTTPS_CADDYFILE" "$u"
tc "H1j unit: only the bind capability" "CapabilityBoundingSet=CAP_NET_BIND_SERVICE" "$u"
tc "H1k the link waits for a verified handshake on the IP" "--connect-to 192.0.2.10:443:127.0.0.1:443 https://192.0.2.10/healthz" "$(cat "$MOCK_LOG")"
tn "H1l ... and never skips verification (-k)" " -k " "$(grep '^curl' "$MOCK_LOG")"
t  "H1m ready:true once the page answers" "true" "$(printf '%s' "$out" | jq -r '.data.ready' 2>/dev/null)"
: > "$MOCK_LOG"; out=$(link DIVE-21 --again); url=$(url_of "$out")
[[ "$url" == https://192.0.2.10/* ]] && ! grep -q '^systemctl restart' "$MOCK_LOG" \
  && ok_t "H1n the second link reuses the front (no restart)" \
  || bad_t "H1n the second link reuses the front (no restart)" "url=$url log=$(cat "$MOCK_LOG")"

# --- H2: the IP certificate fails -> sslip.io ---------------------------------
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192-0-2-10.sslip.io
out=$(link DIVE-21 --again); rc=$?; url=$(url_of "$out")
[[ $rc -eq 0 && "$url" == https://192-0-2-10.sslip.io/* ]] \
  && ok_t "H2a no IP certificate in time -> <ip-with-dashes>.sslip.io" \
  || bad_t "H2a no IP certificate in time -> <ip-with-dashes>.sslip.io" "rc=$rc out=$out"
cf=$(cat "$SECRET_HTTPS_CADDYFILE" 2>/dev/null)
tn "H2b sslip: no IP-only profile" "profile shortlived" "$cf"
tn "H2c sslip: no default_sni" "default_sni" "$cf"
grep -q '^curl.*https://192.0.2.10/healthz' "$MOCK_LOG" \
  && ok_t "H2d the IP way was tried first" || bad_t "H2d the IP way was tried first" "$(cat "$MOCK_LOG")"

# --- H3: both fail -> the owner is asked, in plain words -----------------------
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=""
out=$(link DIVE-21 --again); rc=$?
t  "H3a both fail -> no link (exit 7)" "$E_NOT_INSTALLED" "$rc"
tc "H3b ... first ask: a domain pointed at the box's IP" 'Do you have a domain? Point it at 192.0.2.10 and tell me the name.' "$out"
tc "H3c ... with the command a name runs" "sudo 5dive secret https enable --via=domain --host=<name>" "$out"
tc "H3d ... else the terminal" "sudo 5dive secret write SHOP_API_KEY --connector=shop --task=DIVE-21" "$out"
tc "H3e ... and why" "no valid certificate for 192.0.2.10" "$out"
[[ ! -e "$unitf" && ! -e "$SECRET_HTTPS_CADDYFILE" ]] && ! grep -q '^SECRET_HTTPS_HOST=' "$SECRET_DROP_CONF" 2>/dev/null \
  && ok_t "H3f a failed front leaves nothing on (no unit, no Caddyfile, no host)" \
  || bad_t "H3f a failed front leaves nothing on (no unit, no Caddyfile, no host)" "$(ls "$SECRET_HTTPS_UNIT_DIR" 2>&1)"
: > "$MOCK_LOG"; out=$(link DIVE-21 --again); rc=$?
[[ $rc -eq $E_NOT_INSTALLED ]] && ! grep -q '^curl' "$MOCK_LOG" && ! grep -q '^systemctl restart' "$MOCK_LOG" \
  && ok_t "H3g within the retry window the next link does not wait again" \
  || bad_t "H3g within the retry window the next link does not wait again" "rc=$rc log=$(cat "$MOCK_LOG")"
tc "H3h ... and still says why" "no valid certificate for 192.0.2.10" "$out"

# --- H4: behind NAT / busy ports / no Caddy: fast, honest, nothing taken --------
fresh; export BOX_IP="" TLS_OK_HOSTS=""
out=$(link DIVE-21 --again); rc=$?
[[ $rc -eq $E_NOT_INSTALLED && "$out" == *"no public IPv4"* && "$out" == *"Point it at this box"* ]] && ! grep -q '^curl' "$MOCK_LOG" \
  && ok_t "H4a behind NAT: refused at once, no certificate wait, the ask names no IP" \
  || bad_t "H4a behind NAT: refused at once, no certificate wait, the ask names no IP" "rc=$rc out=$out"
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10 BUSY_PORTS=443
out=$(link DIVE-21 --again); rc=$?
[[ $rc -eq $E_NOT_INSTALLED && "$out" == *"port 80 or 443"* && ! -e "$unitf" ]] && ! grep -q '^systemctl restart' "$MOCK_LOG" \
  && ok_t "H4b port 443 held by another program: never taken, no front started" \
  || bad_t "H4b port 443 held by another program: never taken, no front started" "rc=$rc out=$out"
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10 BUSY_PORTS="80 443" LINKTLS_ACTIVE=1
out=$(link DIVE-21 --again)
tc "H4c the browser's login-link front on 443 is named" "login-link front" "$out"
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10 NO_CADDY=1
out=$(link DIVE-21 --again); rc=$?
[[ $rc -eq $E_NOT_INSTALLED && "$out" == *"could not install Caddy"* ]] && ! grep -q 'sslip' "$MOCK_LOG" \
  && ok_t "H4d no Caddy: refused, and sslip.io is not tried (it needs Caddy too)" \
  || bad_t "H4d no Caddy: refused, and sslip.io is not tried (it needs Caddy too)" "rc=$rc out=$out"
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10
out=$( ( _secret_link DIVE-21 --again --no-start ) 2>&1); rc=$?
[[ $rc -eq $E_NOT_INSTALLED && ! -e "$unitf" ]] && ! grep -q '^systemctl' "$MOCK_LOG" \
  && ok_t "H4e --no-start never turns a front on" || bad_t "H4e --no-start never turns a front on" "rc=$rc"

# --- H5: the owner's own domain ---------------------------------------------------
fresh; export BOX_IP="" TLS_OK_HOSTS=box.example.org
out=$( ( _secret_https enable --via=domain --host=Box.Example.org ) 2>&1); rc=$?
t  "H5a enable --via=domain works behind NAT (the owner forwards the ports)" "0 box.example.org" "$rc $(printf '%s' "$out" | jq -r .data.host 2>/dev/null)"
out=$(link DIVE-21 --again); url=$(url_of "$out")
[[ "$url" == https://box.example.org/* ]] && ok_t "H5b the link uses the owner's domain" || bad_t "H5b the link uses the owner's domain" "$out"
out=$( ( _secret_https enable --via=domain ) 2>&1); rc=$?
t  "H5c --via=domain with no --host is refused" "$E_USAGE" "$rc"
out=$( ( _secret_https enable --via=domain --host='x.org { }' ) 2>&1); rc=$?
t  "H5d a host that is not a domain name is refused" "$E_NOT_INSTALLED" "$rc"
out=$( ( _secret_https status ) 2>&1)
t  "H5e status names the host" "box.example.org" "$(printf '%s' "$out" | jq -r .data.host 2>/dev/null)"
( _secret_https disable ) >/dev/null 2>&1
[[ ! -e "$unitf" && ! -e "$SECRET_HTTPS_CADDYFILE" ]] && ! grep -q '^SECRET_HTTPS_' "$SECRET_DROP_CONF" \
  && ok_t "H5f disable removes the unit, the Caddyfile and the host" || bad_t "H5f disable removes the unit, the Caddyfile and the host" "$(cat "$SECRET_DROP_CONF")"

# --- H6: a hosted box is never touched ---------------------------------------------
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10
printf 'FIVE_DOMAIN=teal-fox.example.com\n' > "$SECRET_DROP_PROVISIONING"
out=$( ( _secret_https enable --via=ip ) 2>&1); rc=$?
[[ $rc -eq $E_CONFLICT && ! -e "$unitf" ]] && ok_t "H6a secret https refuses on a box with FIVE_DOMAIN" || bad_t "H6a secret https refuses on a box with FIVE_DOMAIN" "rc=$rc out=$out"
printf 'SECRET_HTTPS_MODE=ip\nSECRET_HTTPS_HOST=192.0.2.10\n' > "$SECRET_DROP_CONF"
out=$( ( _secret_link DIVE-21 --again --no-start ) 2>&1)
[[ "$(url_of "$out")" == https://secrets.teal-fox.example.com/* ]] \
  && ok_t "H6b FIVE_DOMAIN wins over a planted self-host host" || bad_t "H6b FIVE_DOMAIN wins over a planted self-host host" "$out"
rm -f "$SECRET_DROP_PROVISIONING"; printf 'SECRET_DROP_BASE_URL=https://tunnel.example.net\n' > "$SECRET_DROP_CONF"
( _secret_https_auto ) >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$unitf" ]] && ok_t "H6c an owner's own SECRET_DROP_BASE_URL: no automatic front" || bad_t "H6c an owner's own SECRET_DROP_BASE_URL: no automatic front" "rc=$rc"

# --- H7: a real Caddy adapts both generated files (when one is given) ------------
if [[ -n "${CADDY_REAL:-}" && -x "${CADDY_REAL}" ]]; then
  for m in ip sslip; do
    h=192.0.2.10; [[ $m == sslip ]] && h=192-0-2-10.sslip.io
    _secret_https_caddyfile "$m" "$h" > "$TMP/cf.$m"
    if "$CADDY_REAL" adapt --config "$TMP/cf.$m" --adapter caddyfile > "$TMP/cf.$m.json" 2>"$TMP/cf.$m.err"; then
      ok_t "H7 real Caddy $("$CADDY_REAL" version | cut -d' ' -f1) adapts the $m Caddyfile"
    else bad_t "H7 real Caddy adapts the $m Caddyfile" "$(cat "$TMP/cf.$m.err")"; fi
  done
  tc "H7 ip: the adapted config asks ACME for the shortlived profile" '"profile":"shortlived"' "$(cat "$TMP/cf.ip.json")"
else
  printf 'skip - H7 real Caddy (set CADDY_REAL=<caddy 2.11+ binary>)\n'
fi

# --- H8: MARKER — the value goes browser -> this box, and nowhere else ---------------
# The page runs for real on loopback (Caddy only adds TLS in front of it), with
# the self-hosted conf in place. The marker must land in the connector file and
# appear in nothing else the drop path writes or sends.
fresh; export BOX_IP=192.0.2.10 TLS_OK_HOSTS=192.0.2.10
out=$(link DIVE-21 --again); tok=$(url_of "$out"); tok="${tok##*/}"
WRAP="$TMP/5dive-bundle"
cat > "$WRAP" <<EOF
#!/usr/bin/env bash
cd "$REPO"
for f in $LIBS; do source "src/\$f"; done
STATE_DIR="$STATE_DIR"; TASKS_DIR="$TASKS_DIR"; TASKS_DB="$TASKS_DB"; CONNECTORS_DIR="$CONNECTORS_DIR"
SECRET_DROP_DIR="$SECRET_DROP_DIR"; SECRET_DROP_LOCK="$SECRET_DROP_LOCK"; SECRET_WRITE_LOCK="$SECRET_WRITE_LOCK"
SECRET_DROP_CONF="$SECRET_DROP_CONF"; SECRET_DROP_PROVISIONING="$SECRET_DROP_PROVISIONING"
SECRET_VAULT_KEY="$SECRET_VAULT_KEY"
TOOLS_ENV_FILE="$TOOLS_ENV_FILE"; TOOLS_WRITE_LOCK="$TOOLS_WRITE_LOCK"; SECRET_PROJECTS_DIR="$SECRET_PROJECTS_DIR"
PATH="$MOCKBIN:\$PATH"; export MOCK_LOG="$MOCK_LOG" MOCK5DIVE_DB="$TASKS_DB" JOURNAL_LOG="$JOURNAL_LOG"
require_root() { :; }
shift
args=(); for a in "\$@"; do [[ "\$a" == --json ]] && JSON_MODE=1 || args+=("\$a"); done
cmd_secret "\${args[@]}"
EOF
chmod +x "$WRAP"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
_secret_drop_server_py > "$TMP/server.py"
python3 "$TMP/server.py" 127.0.0.1 "$PORT" "$WRAP" "$SECRET_DROP_DIR" 0 > "$TMP/server.out" 2> "$TMP/server.log" & SRV_PID=$!
for _ in $(seq 1 50); do "$REAL_CURL" -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
MARKER="dive7113-marker-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
: > "$MOCK_LOG"; : > "$JOURNAL_LOG"
code=$("$REAL_CURL" -s -o "$TMP/post.html" -w '%{http_code}' -H 'X-Forwarded-For: 192.0.2.9' --data-urlencode "value=$MARKER" "http://127.0.0.1:$PORT/$tok")
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
t  "H8a the paste is taken (200)" "200" "$code"
t  "H8b the marker lands as the gate's KEY in the connector file" "SHOP_API_KEY=$MARKER" "$(grep '^SHOP_API_KEY=' "$CONNECTORS_DIR/shop.env" 2>/dev/null)"
t  "H8c the gate is closed" "1" "$(db "SELECT need_answered_at IS NOT NULL FROM tasks WHERE ident='DIVE-21';")"
leaks=$(grep -rlF -- "$MARKER" "$TMP" 2>/dev/null | grep -vxF "$CONNECTORS_DIR/shop.env")
t  "H8d MARKER appears in no other file: call logs, journal, page log, conf, Caddyfile, task DB" "" "$leaks"
tn "H8e no outbound call during the paste (no curl at all)" "curl" "$(cat "$MOCK_LOG")"
tn "H8f no 5dive call carries the value in its argv" "$MARKER" "$(cat "$MOCK_LOG")"
# The drop code names no 5dive host, API or Sentry: nothing it runs could reach one.
api=$(grep -nE '5dive\.(ai|com)|https?://api\.|sentry' src/cmd_secret_drop.sh | grep -vE '^[0-9]+:[[:space:]]*#' || true)
t  "H8g src/cmd_secret_drop.sh names no 5dive host, API or Sentry" "" "$api"

printf '\nsecret_https_selfhost_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
