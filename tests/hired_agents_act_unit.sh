#!/usr/bin/env bash
# DIVE-5396: a hired agent can act without root. It hires by LINK (never agent
# create), publishes its own app (route add) and installs a system package
# (pkg install) through two exact-path, stdin-fed root primitives, and installs
# its own npm/pip tools into ~/.local with no sudo.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/hired-agents.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_agent_create.sh \
  cmd_route.sh cmd_pkg.sh cmd_hire_link.sh; do
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }
check(){ local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
# output.sh's ok() is shadowed by the harness ok(); the verbs' own answers go
# through this one, restored inside each subshell run.
cli_ok(){ local prose="${1:-}"; shift || true
  if (( ${JSON_MODE:-0} )); then local e="${1:-}"; [[ $# -gt 0 ]] && shift; jq -cn "$@" "{ok:true, data: (${e:-{\}})}"
  else [[ -n "$prose" ]] && echo "OK — $prose"; fi; return 0; }
audit_log(){ printf 'AUDIT %s\n' "$*" >>"$TMP/audit"; }

# ── the grant ────────────────────────────────────────────────────────────────
SUD=$(render_standard_sudoers agent-tap 0 0)
for v in _route_do _pkg_do; do
  [[ $(grep -cE "^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive ${v}\$" <<<"$SUD") == 1 ]] \
    && ok "exact-path $v grant rendered once, no args" || bad "exact-path $v grant rendered once, no args"
done
grep -qE '/usr/bin/apt|apt-get|5dive-write-caddyfile|systemctl' <<<"$(grep -v '^#' <<<"$SUD")" \
  && bad 'no raw apt / caddyfile / systemctl grant' || ok 'no raw apt / caddyfile / systemctl grant'
[[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
  && ok 'rendered standard grant still classifies cli-scoped, extra=0' \
  || bad "rendered standard grant classifies cli-scoped, extra=0 (got $(classify_sudo_grant <<<"$SUD"))"
grep -qF '"/usr/local/bin/5dive _route_do", "/usr/local/bin/5dive _pkg_do"' "$SRC/cmd_agent.sh" \
  && ok 'python agent-list classifier knows both verbs' || bad 'python agent-list classifier knows both verbs'
VERBS=$(sed -n 's/^readonly FIVEDIVE_BUILTIN_VERBS="\(.*\)"$/\1/p' "$SRC/cmd_plugin.sh")
for v in hire-link route _route_do pkg _pkg_do; do
  [[ " $VERBS " == *" $v "* ]] && ok "builtin verb list has $v" || bad "builtin verb list has $v"
done

# ── route: a box Caddyfile in the shape services.sh writes ───────────────────
CF="$TMP/Caddyfile"; PROV="$TMP/provisioning.env"
cat >"$CF" <<'EOF'
{
    email ops@example.com
}

box.example.com {
    handle /shell/* {
        reverse_proxy localhost:3101
    }
    handle /s/* {
        reverse_proxy 127.0.0.1:3106
    }
    handle /files/* {
        reverse_proxy localhost:3101
    }
    handle {
        respond "Setting up" 503
    }
}

secrets.box.example.com {
    reverse_proxy 127.0.0.1:3127
}
EOF
cp "$CF" "$TMP/Caddyfile.orig"
printf 'FIVE_DOMAIN=box.example.com\n' >"$PROV"
cat >"$TMP/caddy" <<'EOF'
#!/usr/bin/env bash
# validate stub: a file containing BADVALIDATE fails, anything else passes
[[ "$1" == validate ]] || exit 2
! grep -q BADVALIDATE "$3"
EOF
chmod +x "$TMP/caddy"
export ROUTE_CADDYFILE="$CF" ROUTE_PROVISIONING="$PROV" ROUTE_CADDY_BIN="$TMP/caddy" ROUTE_LOCK="$TMP/route.lock"
export ROUTE_RELOAD_CMD="true"
_gate_uid_to_agent(){ case "$1" in 1042) printf olivia ;; 1043) printf marcus ;; *) printf '' ;; esac; }
_gate_is_root(){ return 0; }
LISTEN_UID=1042
_route_port_owner_ok(){ [[ "$1" == 3200 || "$1" == 3300 ]] && [[ "$2" == "$LISTEN_UID" ]]; }
# rr <sudo_uid> <wire...> — the root half in a subshell (fail exits), wire on stdin
rr(){ local uid="$1"; shift
  ( ok(){ cli_ok "$@"; }; export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_route_delegated ) >"$TMP/out" 2>&1; }

rr 1042 json add app 3200; rc=$?
[[ $rc == 0 ]] && ok 'route add app --port=3200 as a standard seat succeeds' || bad "route add app (rc=$rc: $(cat "$TMP/out"))"
grep -qF '"url":"https://app.box.example.com/"' "$TMP/out" && ok 'answers the subdomain url' || bad "answers the url ($(cat "$TMP/out"))"
B=$(sed -n '/# 5dive-route:begin app /,/# 5dive-route:end app/p' "$CF")
[[ "$B" == *'port=3200 by=olivia'* && "$B" == *'app.box.example.com {'* && "$B" == *'reverse_proxy 127.0.0.1:3200'* ]] \
  && ok 'block fenced, owned by the SUDO_UID seat, proxies to loopback' || bad "block shape ($B)"
grep -q 'AUDIT _route_do add ok 0 -- by=olivia app --port=3200' "$TMP/audit" && ok 'add audited root-side' || bad "add audited ($(cat "$TMP/audit" 2>/dev/null))"
[[ "$(_route_list_lines)" == 'app 3200 olivia' ]] && ok 'route ls reads it back' || bad "route ls ($(_route_list_lines))"

neg(){ local label="$1"; shift; cp "$CF" "$TMP/before"; rr "$@"; local r=$?
  if [[ $r != 0 ]] && cmp -s "$CF" "$TMP/before"; then ok "refused, file untouched: $label"; else bad "refused: $label (rc=$r, $(cat "$TMP/out"))"; fi; }
neg 'route add shell'                 1042 json add shell 3200
neg 'route add secrets'               1042 json add secrets 3200
neg 'route add /shell'                1042 json add /shell 3200
neg 'route add /files'                1042 json add /files 3200
neg "shelld's port 3101"              1042 json add other 3101
neg 'a port nobody of yours listens on' 1042 json add other 3999
neg "another seat's listener"         1043 json add other 3200
neg 'a name already routed'           1042 json add app 3300
neg 'a privileged port'               1042 json add other 80
neg 'an uppercase/odd name'           1042 json add 'App;x' 3200
neg 'a caller that is not a seat'     1777 json add other 3200
neg 'an op other than add/rm'         1042 json write 'x {}'
neg 'extra wire fields'               1042 json add other 3200 extra
grep -q "secrets.box.example.com {" "$CF" && ok 'the box block a reserved name names is still there' || bad 'secrets block survived'

rr 1042 json add /tool 3300; rc=$?
P_BLOCK=$(sed -n '/# 5dive-route:begin \/tool /,/# 5dive-route:end \/tool/p' "$CF")
[[ $rc == 0 && "$P_BLOCK" == *'handle_path /tool/* {'* && "$P_BLOCK" == *'redir /tool /tool/ 308'* ]] \
  && ok 'path route inserted as handle_path in the main site' || bad "path route ($(cat "$TMP/out"))"
awk '/# 5dive-route:end \/tool/{e=NR} /handle \/files\/\*/{f=NR} END{exit !(e && f && e < f)}' "$CF" \
  && ok 'path route sits before the /files/* handle' || bad 'path route position'
neg 'rm by a seat that does not own it' 1043 json rm app
neg 'rm of a block the verb did not write' 1042 json rm secrets
rr 1042 json rm /tool; rr 1042 json rm app; rc=$?
cmp -s "$CF" "$TMP/Caddyfile.orig" && ok 'rm of both restores the original byte for byte' || bad "rm restores ($(diff "$TMP/Caddyfile.orig" "$CF"))"

cp "$CF" "$TMP/before"
ROUTE_CADDY_BIN_SAVE="$ROUTE_CADDY_BIN"; export ROUTE_CADDY_BIN="$TMP/caddy-fail"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/caddy-fail"; chmod +x "$TMP/caddy-fail"
rr 1042 json add app 3200; rc=$?
[[ $rc != 0 ]] && cmp -s "$CF" "$TMP/before" && ok 'a failed validate leaves the live file untouched' || bad 'failed validate'
export ROUTE_CADDY_BIN="$ROUTE_CADDY_BIN_SAVE" ROUTE_RELOAD_CMD="false"
rr 1042 json add app 3200; rc=$?
[[ $rc != 0 ]] && cmp -s "$CF" "$TMP/before" && ok 'a failed reload puts the previous file back' || bad "failed reload ($(cat "$TMP/out"))"
export ROUTE_RELOAD_CMD="true"
ls "$TMP"/Caddyfile.new.* "$TMP"/Caddyfile.route.* >/dev/null 2>&1 && bad 'no staging files left behind' || ok 'no staging files left behind'

# the REAL listener check, against a fake ss naming this shell's own pid
ss(){ printf 'LISTEN 0 511 127.0.0.1:3200 0.0.0.0:* users:(("node",pid=%s,fd=19))\n' "$$"; }
unset -f _route_port_owner_ok; source <(sed -n '/^_route_port_owner_ok() {/,/^}/p' "$SRC/cmd_route.sh")
_route_port_owner_ok 3200 "$(id -u)" && ok 'listener owned by the caller uid passes' || bad 'listener owned by caller'
_route_port_owner_ok 3200 99999 && bad 'listener owned by another uid is refused' || ok 'listener owned by another uid is refused'
ss(){ :; }
_route_port_owner_ok 3200 "$(id -u)" && bad 'no listener is refused' || ok 'no listener is refused'
unset -f ss

# the caller half pipes the operation to the exact-path primitive, nothing on argv
sudo(){ printf '%s\n' "$*" >"$TMP/sudo-argv"; tr '\0' '|' >"$TMP/sudo-stdin"; return 0; }
( cmd_route add app --port=3200 ) >/dev/null 2>&1 || true
if [[ $EUID -ne 0 ]]; then
  [[ "$(cat "$TMP/sudo-argv")" == '-n /usr/local/bin/5dive _route_do' && "$(cat "$TMP/sudo-stdin")" == 'text|add|app|3200|' ]] \
    && ok 'non-root route add crosses _route_do with the op on stdin' || bad "caller half ($(cat "$TMP/sudo-argv") / $(cat "$TMP/sudo-stdin"))"
  ( cmd_pkg install jq ffmpeg --json ) >/dev/null 2>&1 || true
  [[ "$(cat "$TMP/sudo-argv")" == '-n /usr/local/bin/5dive _pkg_do' && "$(cat "$TMP/sudo-stdin")" == 'json|install|jq|ffmpeg|' ]] \
    && ok 'non-root pkg install crosses _pkg_do with the names on stdin' || bad "pkg caller half ($(cat "$TMP/sudo-argv") / $(cat "$TMP/sudo-stdin"))"
fi
unset -f sudo

# ── pkg: names only, install only ────────────────────────────────────────────
pneg(){ local label="$1"; shift; ( cmd_pkg "$@" ) >"$TMP/out" 2>&1 && bad "pkg refused: $label" || ok "pkg refused: $label"; }
pneg 'a flag'                install --allow-unauthenticated jq
pneg 'an apt -o option'      install -o APT::Get::AllowUnauthenticated=1 jq
pneg 'a .deb path'           install /tmp/evil.deb
pneg 'a version pin'         install jq=1.6
pneg 'a release selector'    install jq/noble
pneg 'a URL'                 install http://x/y.deb
pneg 'remove'                remove jq
pneg 'purge'                 purge jq
pneg 'nothing to install'    install
APT_LOG="$TMP/apt.log"
cat >"$TMP/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$APT_LOG"
printf 'DEBIAN_FRONTEND=%s NEEDRESTART_SUSPEND=%s\n' "\${DEBIAN_FRONTEND:-}" "\${NEEDRESTART_SUSPEND:-}" >>"$APT_LOG"
case "\$*" in
  *missingpkg*) [[ -f "$TMP/updated" ]] || { echo "E: Unable to locate package missingpkg"; exit 100; } ;;
  *conflicting*) echo "E: Packages need to be removed but remove is disabled."; exit 100 ;;
esac
[[ "\$1" == update ]] && touch "$TMP/updated"
exit 0
EOF
chmod +x "$TMP/apt-get"; export PKG_APT_GET="$TMP/apt-get"
# apt-cache stub: `pkgnames -- <prefix>` over a fixed list, prefix-matched like
# the real one; missingpkg exists only once the lists are updated.
cat >"$TMP/apt-cache" <<EOF
#!/usr/bin/env bash
[[ "\$1" == pkgnames && "\$2" == -- ]] || exit 100
names="jq jqp g++ conflicting x11-apps x11-utils openssh-server"
[[ -f "$TMP/updated" ]] && names="\$names missingpkg"
for n in \$names; do [[ "\$n" == "\$3"* ]] && echo "\$n"; done
exit 0
EOF
chmod +x "$TMP/apt-cache"; export PKG_APT_CACHE="$TMP/apt-cache"
pr(){ local uid="$1"; shift; : >"$APT_LOG"
  ( ok(){ cli_ok "$@"; }; export SUDO_UID="$uid"; printf '%s\0' "$@" | cmd_pkg_delegated ) >"$TMP/out" 2>&1; }
pr 1042 json install jq; rc=$?
L1=$(head -1 "$APT_LOG")
[[ $rc == 0 && "$L1" == 'install -y -q --no-install-recommends --no-remove '*' -- jq' ]] \
  && ok 'pkg install jq runs apt-get install --no-install-recommends --no-remove -- jq' || bad "apt argv ($L1; $(cat "$TMP/out"))"
grep -q 'DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1' "$APT_LOG" && ok 'non-interactive, needrestart suspended' || bad 'apt env'
grep -q 'AUDIT _pkg_do install ok 0 -- by=olivia jq' "$TMP/audit" && ok 'install audited root-side under the seat' || bad 'install audited'
pr 1042 json install missingpkg; rc=$?
[[ $rc == 0 ]] && grep -q '^update ' "$APT_LOG" && ok 'stale lists: one apt-get update, then the install succeeds' || bad "stale-list retry ($(cat "$TMP/out"))"
rm -f "$TMP/updated"
pr 1042 json install conflicting; rc=$?
[[ $rc != 0 ]] && grep -q 'would remove other packages' "$TMP/out" && ok 'an install that would remove a package aborts and says so' || bad "no-remove ($(cat "$TMP/out"))"
pkgneg(){ local label="$1"; shift; pr "$@"; local r=$?
  [[ $r != 0 && ! -s "$APT_LOG" ]] && ok "_pkg_do refused before apt: $label" || bad "_pkg_do refused: $label (rc=$r)"; }
pkgneg 'op remove'          1042 json remove jq
pkgneg 'flag-shaped name'   1042 json install --reinstall
pkgneg 'path-shaped name'   1042 json install ./x.deb
pkgneg 'no package'         1042 json install
pkgneg 'bad output mode'    1042 yaml install jq
# apt-get reads a name with no exact match as a REGEX: 'x11-.+' would install
# every x11-* package (708 on a real box). Only an exact package name reaches it.
nonexact(){ local label="$1"; shift; pr 1042 json install "$@"; local r=$?
  [[ $r != 0 ]] && ! grep -q '^install ' "$APT_LOG" && grep -q 'no package is named exactly' "$TMP/out" \
    && ok "pkg refused, no install ran: $label" || bad "pkg non-exact: $label (rc=$r; $(cat "$TMP/out"))"
  rm -f "$TMP/updated"; }
nonexact "regex 'x11-.+'"            'x11-.+'
nonexact "regex 'o.+'"               'o.+'
nonexact "a prefix of a real package" 'openssh'
nonexact "regex 'jq.'"              'jq.'
nonexact 'one regex among exact names' jq 'x11-.+'
grep -q 'AUDIT _pkg_do install refused' "$TMP/audit" && ok 'a non-exact name is audited as refused' || bad 'non-exact audited'
pr 1042 json install g++; rc=$?
[[ $rc == 0 ]] && grep -q -- '-- g++$' "$APT_LOG" && ok "an exact name with regex characters (g++) still installs" || bad "g++ ($(cat "$TMP/out"))"
# The same refusal against the REAL apt-cache, where the box has one.
if command -v apt-cache >/dev/null 2>&1; then
  PKG_APT_CACHE=apt-cache; nonexact "regex 'x11-.+' (real apt-cache)" 'x11-.+'; PKG_APT_CACHE="$TMP/apt-cache"
fi
# Under sudo the root half ignores its test seams: env_reset strips them today,
# and nothing here depends on that.
v=$( export SUDO_UID=1042 PKG_APT_GET=/tmp/evil PKG_APT_CACHE=/tmp/evil; _pkg_trust_env 0; printf '%s %s' "$PKG_APT_GET" "$PKG_APT_CACHE" )
[[ "$v" == 'apt-get apt-cache' ]] && ok 'root under sudo ignores PKG_APT_GET / PKG_APT_CACHE from the env' || bad "pkg seams under sudo ($v)"
v=$( export SUDO_UID=1042 ROUTE_RELOAD_CMD='touch /tmp/pwn' ROUTE_CADDYFILE=/tmp/cf ROUTE_CADDY_BIN=/tmp/evil; _route_trust_env 0
  printf '%s|%s|%s' "${ROUTE_RELOAD_CMD-unset}" "$ROUTE_CADDYFILE" "$ROUTE_CADDY_BIN" )
[[ "$v" == 'unset|/etc/caddy/Caddyfile|caddy' ]] && ok 'root under sudo ignores ROUTE_RELOAD_CMD and the ROUTE_* paths' || bad "route seams under sudo ($v)"
v=$( export SUDO_UID=1042 PKG_APT_GET=/x/apt-get; _pkg_trust_env 1007; printf '%s' "$PKG_APT_GET" )
[[ "$v" == /x/apt-get ]] && ok 'a non-root run keeps the seams (the harness itself)' || bad "seams off root ($v)"

# ── hire-link ────────────────────────────────────────────────────────────────
_tg_app_api(){ printf 'https://api.example.com'; }
_tg_app_env_file(){ printf '%s' "$TMP/connectord.env"; }
printf 'CONNECTORD_TOKEN=tok\n' >"$TMP/connectord.env"
_marketplace_index(){ printf '{"packs":[{"slug":"marcus"},{"slug":"olivia"}]}'; }
HL_CODE=200; HL_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-marcus"}'
curl(){ printf '%s\n%s' "$HL_BODY" "$HL_CODE"; }
hl(){ ( ok(){ cli_ok "$@"; }; cmd_hire_link "$@" ) >"$TMP/out" 2>&1; }
hl marcus; rc=$?
[[ $rc == 0 && "$(cat "$TMP/out")" == 'https://t.me/FiveDiveBot?startapp=agent-marcus' ]] \
  && ok 'hire-link marcus prints the startapp link (Telegram owner)' || bad "hire-link miniapp ($(cat "$TMP/out"))"
HL_BODY='{"channel":"web","url":"https://5dive.example/dashboard/agents/new"}'
hl marcus --json; grep -qF '"status":"ready"' "$TMP/out" && grep -qF '"channel":"web"' "$TMP/out" \
  && ok 'a web owner gets the dashboard link' || bad "hire-link web ($(cat "$TMP/out"))"
HL_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-olivia"}'
hl marcus --json; grep -qF '"status":"error"' "$TMP/out" && ok 'a link for a different agent is not passed on' || bad "mismatched link ($(cat "$TMP/out"))"
HL_BODY='{"channel":"miniapp","url":"https://evil.example/?startapp=agent-marcus"}'
hl marcus --json; grep -qF '"status":"error"' "$TMP/out" && ok 'a link off t.me is not passed on' || bad "foreign link ($(cat "$TMP/out"))"
HL_CODE=403; HL_BODY='{"error":"partner_box"}'
hl marcus --json; grep -qF '"status":"partner_box"' "$TMP/out" && ok 'a partner box is told to hire in the partner app' || bad 'partner box'
HL_CODE=200
# The prose is the text answer (--json carries the status); the old arm grepped
# 'custom' and matched the slug itself.
hl mycustombot --json; grep -qF '"status":"not_catalogue"' "$TMP/out" \
  && hl mycustombot && grep -qF 'hire-link --create' "$TMP/out" && ! grep -qiE 'web|dashboard' "$TMP/out" \
  && ok 'a non-catalogue slug names --create, never the web dashboard (DIVE-5722)' || bad "not catalogue ($(cat "$TMP/out"))"
( cmd_hire_link 'a/b' ) >/dev/null 2>&1 && bad 'a malformed slug is refused' || ok 'a malformed slug is refused'

# ── DIVE-5722: a lead makes a custom agent from chat ─────────────────────────
# The API answers by path; every call is logged (method, path, body) and the
# token must arrive on curl's stdin config, never argv.
CID=abcdef123456
CA_CODE=201
CA_BODY='{"id":"abcdef123456","pack":"custom-abcdef123456","name":"Ivy","role":"Accounts manager","skills":["follow-up-ladder","copywriting"],"cardUrl":"https://api.example.com/custom-agent/abcdef123456/card.svg?v=0123456789"}'
LK_CODE=200; LK_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-custom-abcdef123456"}'
HR_CODE=202; HR_BODY='{"state":"hiring"}'
POLLS=('{"state":"hiring"}' '{"state":"hired","name":"ivy"}')
curl(){
  local a method=POST url="" data="" cfg
  cfg=$(cat)
  while (( $# )); do case "$1" in -X) method="$2"; shift ;; --data-binary) data="$2"; shift ;; https://*) url="$1" ;; esac; shift; done
  [[ "$cfg" == *'Bearer tok'* ]] || { printf 'NO-TOKEN %s\n' "$url" >>"$TMP/calls"; }
  printf '%s %s %s\n' "$method" "${url#https://api.example.com}" "$data" >>"$TMP/calls"
  case "$method ${url#https://api.example.com}" in
    "POST /server/custom-agents") printf '%s\n%s' "$CA_BODY" "$CA_CODE" ;;
    "POST /server/telegram/hire-link") printf '%s\n%s' "$LK_BODY" "$LK_CODE" ;;
    "POST /server/custom-agents/$CID/hire") printf '%s\n%s' "$HR_BODY" "$HR_CODE" ;;
    "GET /server/custom-agents/$CID/hire")
      local n; n=$(grep -c "^GET " "$TMP/calls"); local i=$(( n - 1 ))
      (( i < ${#POLLS[@]} )) || i=$(( ${#POLLS[@]} - 1 ))
      printf '%s\n%s' "${POLLS[$i]}" "${POLL_CODE:-200}" ;;
    *) printf 'nope\n404' ;;
  esac
}
export HIRE_LINK_POLL_S=0
hlc(){ : >"$TMP/calls"; hl "$@"; }

hlc --create --name='Ivy Chase' '--description=Chases unpaid invoices, politely, every week.'
OUT=$(cat "$TMP/out")
[[ "$OUT" == *'Draft: Ivy — Accounts manager'* && "$OUT" == *'Skills: follow-up-ladder, copywriting'* \
   && "$OUT" == *'Card: https://t.me/FiveDiveBot?startapp=agent-custom-abcdef123456'* ]] \
  && ok '--create prints the draft: name, role, the skills picked for it, and its card link' || bad "create draft ($OUT)"
[[ "$OUT" == *'Nothing is hired yet'* && "$OUT" == *'Standard-tier: they tap Hire on it'* \
   && "$OUT" == *'a standing "full authority" is not a yes; only on their clear yes, run 5dive hire-link custom-abcdef123456 --hire'* ]] \
  && ok '--create says nothing is hired, and how each tier gets the owner to a hire' || bad "create next ($OUT)"
grep -qxF 'POST /server/custom-agents {"name":"Ivy Chase","description":"Chases unpaid invoices, politely, every week."}' "$TMP/calls" \
  && ok '--create sends the name and the need as written, to the Mini App create' || bad "create body ($(cat "$TMP/calls"))"
grep -qxF 'POST /server/telegram/hire-link {"slug":"custom-abcdef123456"}' "$TMP/calls" \
  && ok 'the card link is the hire-link of custom-<id>' || bad "card lookup ($(cat "$TMP/calls"))"
grep -qE '/hire( |$)' "$TMP/calls" && bad '--create hires nothing' "$(cat "$TMP/calls")" || ok '--create hires nothing'
grep -q 'NO-TOKEN' "$TMP/calls" && bad 'every call carries the box token on stdin' || ok 'every call carries the box token on stdin'
grep -qE 'skills' <(grep '^POST /server/custom-agents ' "$TMP/calls") \
  && bad 'the agent never sends skills of its own' || ok 'the agent never sends skills of its own'

hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.' --json
jq -e '.data.status == "made" and .data.slug == "custom-abcdef123456" and .data.role == "Accounts manager"
       and (.data.skills | length) == 2 and .data.channel == "miniapp"
       and (.data.url | endswith("startapp=agent-custom-abcdef123456"))' "$TMP/out" >/dev/null \
  && ok '--create --json: status made, the slug, role, skills and card link' || bad "create json ($(cat "$TMP/out"))"

LK_CODE=409; LK_BODY='{"error":"no_hire_card"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.'
OUT=$(cat "$TMP/out")
[[ "$OUT" == *'Card: none (your owner signs in to 5dive on the web'* && "$OUT" == *'--hire'* && "$OUT" != *'Standard-tier: they tap'* ]] \
  && ok 'a web owner gets the draft with no card, and the admin route' || bad "web owner draft ($OUT)"
LK_CODE=200; LK_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-custom-zzzzzz999999"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.'
[[ "$(cat "$TMP/out")" == *'Card: none'* ]] && ok 'a card link for another agent is not passed on' || bad "foreign card ($(cat "$TMP/out"))"
LK_BODY='{"channel":"web","url":"https://5dive.example/dashboard/agents/new"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.'
[[ "$(cat "$TMP/out")" == *'Card: none'* ]] && ok 'a made agent is never sent to the web dashboard' || bad "web dashboard card ($(cat "$TMP/out"))"
LK_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-custom-abcdef123456"}'

CA_CODE=400; CA_BODY='{"error":"invalid_description"}'
hlc --create --name=Ivy --description=short --json
jq -e '.data.status == "invalid" and .data.error == "invalid_description"' "$TMP/out" >/dev/null \
  && ok "the API's refusal of the words comes back as invalid, with the reason" || bad "invalid ($(cat "$TMP/out"))"
CA_CODE=429; CA_BODY='{"error":"Too many requests"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.' --json
jq -e '.data.status == "limit"' "$TMP/out" >/dev/null && ok "the owner's spent day reads as limit" || bad "limit ($(cat "$TMP/out"))"
CA_CODE=403; CA_BODY='{"error":"partner_box"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.' --json
jq -e '.data.status == "partner_box"' "$TMP/out" >/dev/null && ok 'a partner box makes nothing from chat' || bad "partner create ($(cat "$TMP/out"))"
CA_CODE=201; CA_BODY='{"id":"../../etc","name":"x"}'
hlc --create --name=Ivy '--description=Chases unpaid invoices, politely.' --json
jq -e '.data.status == "error"' "$TMP/out" >/dev/null && ! grep -q 'hire-link {"slug"' "$TMP/calls" \
  && ok 'an answer without a well-formed id is an error, and nothing is looked up by it' || bad "bad id ($(cat "$TMP/out"))"
CA_BODY='{"id":"abcdef123456","pack":"custom-abcdef123456","name":"Ivy","role":"Accounts manager","skills":["follow-up-ladder"],"cardUrl":"https://api.example.com/c.svg"}'
for args in "--create" "--create custom-abcdef123456 --name=a --description=bbbbbbbbbbb" "--create --name=a --description=bbbbbbbbbbbb --hire" "marcus --name=x"; do
  # shellcheck disable=SC2086
  ( cmd_hire_link $args ) >/dev/null 2>&1 && bad "usage refused: $args" || ok "usage refused: $args"
done

hlc custom-abcdef123456
[[ "$(cat "$TMP/out")" == 'https://t.me/FiveDiveBot?startapp=agent-custom-abcdef123456' ]] && ! grep -q '^GET\|/hire ' "$TMP/calls" \
  && ok 'hire-link custom-<id> prints its card link, skipping the catalogue' || bad "custom link ($(cat "$TMP/out"))"
LK_CODE=404; LK_BODY='{"error":"not_found"}'
hlc custom-abcdef123456 --json
jq -e '.data.status == "not_found"' "$TMP/out" >/dev/null && ok "another owner's made agent is not_found" || bad "custom 404 ($(cat "$TMP/out"))"
LK_CODE=200; LK_BODY='{"channel":"miniapp","url":"https://t.me/FiveDiveBot?startapp=agent-custom-abcdef123456"}'

# --hire: the Mini App's Hire, only for an admin-tier seat. `id -un` and the
# registry are stubbed; under root (CI) the asker is SUDO_USER.
hlh(){ local tier="$1"; shift; : >"$TMP/calls"
  ( ok(){ cli_ok "$@"; }; id(){ printf 'agent-lead\n'; }; export SUDO_USER=agent-lead
    actor_registry_agent(){ ACTOR_AGENT=lead; ACTOR_TIER="$tier"; }
    cmd_hire_link "$@" ) >"$TMP/out" 2>&1; }
hlh admin custom-abcdef123456 --hire
[[ "$(cat "$TMP/out")" == 'Hired: ivy is on the team.'* ]] \
  && grep -qxF "POST /server/custom-agents/$CID/hire " "$TMP/calls" && [[ $(grep -c "^GET /server/custom-agents/$CID/hire" "$TMP/calls") == 2 ]] \
  && ok 'admin --hire hires, waiting through the import the way the Mini App polls' || bad "admin hire ($(cat "$TMP/out") | $(cat "$TMP/calls"))"
hlh beyond-admin custom-abcdef123456 --hire --json
jq -e '.data.status == "hired" and .data.name == "ivy"' "$TMP/out" >/dev/null && ok 'beyond-admin hires too (--json)' || bad "beyond-admin ($(cat "$TMP/out"))"
for t in standard unknown:no-tier unknown:registry-unreadable; do
  hlh "$t" custom-abcdef123456 --hire --json
  jq -e '.data.status == "tier"' "$TMP/out" >/dev/null && [[ ! -s "$TMP/calls" ]] \
    && ok "a $t seat is refused --hire before any call, and told to send the card" || bad "tier $t ($(cat "$TMP/out") | $(cat "$TMP/calls"))"
done
( ok(){ cli_ok "$@"; }; id(){ printf 'agent-temp\n'; }; export SUDO_USER=agent-temp
  actor_registry_agent(){ ACTOR_AGENT=""; ACTOR_TIER=unknown:unregistered; }
  : >"$TMP/calls"; cmd_hire_link custom-abcdef123456 --hire --json ) >"$TMP/out" 2>&1
jq -e '.data.status == "tier"' "$TMP/out" >/dev/null && ok 'an unregistered agent-* name is not trusted with a hire' || bad "unregistered agent ($(cat "$TMP/out"))"
( cmd_hire_link marcus --hire ) >/dev/null 2>&1 && bad '--hire on a catalogue slug is refused (agent import hires those)' \
  || ok '--hire on a catalogue slug is refused (agent import hires those)'
POLLS=('{"state":"hiring"}'); HIRE_LINK_WAIT_S=0 hlh admin custom-abcdef123456 --hire --json
jq -e '.data.status == "hiring"' "$TMP/out" >/dev/null && ok 'a hire still importing when the wait ends says hiring, run it again' || bad "hiring ($(cat "$TMP/out"))"
POLLS=('{"state":"failed","error":"import_failed","message":"pack rejected"}'); POLL_CODE=502
hlh admin custom-abcdef123456 --hire --json
jq -e '.data.status == "error" and (.data.message | contains("pack rejected"))' "$TMP/out" >/dev/null \
  && ok "the box's refusal reaches the agent" || bad "hire failed ($(cat "$TMP/out"))"
POLL_CODE=200; HR_CODE=200; HR_BODY='{"state":"hired","name":"ivy"}'
hlh admin custom-abcdef123456 --hire
[[ "$(cat "$TMP/out")" == 'Hired: ivy'* ]] && ! grep -q '^GET' "$TMP/calls" && ok 'an already hired agent answers its name with no wait' || bad "already hired ($(cat "$TMP/out"))"
HR_CODE=404; HR_BODY='{"error":"not found"}'
hlh admin custom-abcdef123456 --hire --json
jq -e '.data.status == "not_found"' "$TMP/out" >/dev/null && ok "--hire of another owner's agent is not_found" || bad "hire 404 ($(cat "$TMP/out"))"
unset -f curl

# ── the tool-env shim: user-level installs with no sudo ──────────────────────
SHIM=$(sed -n "/cat > \"\$_te_tmp\" <<'TOOLENV'/,/^TOOLENV\$/p" install.sh | sed '1d;$d')
printf '%s\n' "$SHIM" >"$TMP/tool-env.sh"
H="$TMP/home"; mkdir -p "$H"
OUT=$(env -i HOME="$H" PATH=/usr/bin:/bin bash -c ". '$TMP/tool-env.sh'; printf '%s|%s|%s' \"\$NPM_CONFIG_PREFIX\" \"\$PIP_BREAK_SYSTEM_PACKAGES\" \"\$PATH\"")
if [[ $EUID -ne 0 ]]; then
  [[ "$OUT" == "$H/.local|1|$H/.local/bin:/usr/bin:/bin" ]] && ok 'a seat gets npm prefix ~/.local, pip --user allowed, ~/.local/bin on PATH' || bad "shim env ($OUT)"
  mkdir -p "$H/.nvm"; echo x >"$H/.nvm/nvm.sh"
  OUT=$(env -i HOME="$H" PATH=/usr/bin:/bin bash -c ". '$TMP/tool-env.sh'; printf '%s' \"\${NPM_CONFIG_PREFIX:-unset}\"")
  [[ "$OUT" == unset ]] && ok 'an nvm seat keeps its own npm prefix' || bad "nvm seat ($OUT)"
fi
ERR=$(env -i HOME="$H" PATH=/usr/bin:/bin bash -c ". '$TMP/tool-env.sh'" 2>&1)
[[ -z "$ERR" ]] && ok 'the shim stays silent' || bad "shim noise ($ERR)"

# ── the instructions every seat on a 5dive-built box loads ───────────────────
# Rendered the way a 5dive-built box gets it: the API writes the file, then
# install.sh's own sync_managed_block puts the block in. The CLI header above
# the blocks never reaches such a box, so every rule here must live IN the block.
eval "$(sed -n '/^sync_managed_block()/,/^}$/p' install.sh)"
LIVE="$TMP/box-CLAUDE.md"
printf '# Your machine\n\n- `claude` has full sudo; other agents work without root.\n' >"$LIVE"
sync_managed_block "$LIVE" projects-CLAUDE.md 5dive:hired-agents
BLOCK=$(sed -n '/<!-- 5dive:hired-agents:begin/,/<!-- 5dive:hired-agents:end/p' "$LIVE")
# DIVE-5823: on exact-swallow an admin lead told "I need someone to chase unpaid
# invoices" imported a catalogue pack on the need alone. The owner's ask is the
# go-ahead, but a need is not a yes to a pack the lead picked: the market line
# itself says the hire waits for it (the custom path's --create output already did).
for want in 'Standard-tier never creates agents' 'Standard-tier: send `5dive hire-link <slug>`' \
            '5dive pkg install' '5dive route add <name> --port=<port>' '5dive task add' 'npm i -g' \
            '**Blank teammates**, admin: `sudo 5dive agent create' '--type=claude|codex|grok|antigravity' \
            '5dive agent auth start <type>' '**`5dive market` hires**, admin:' \
            "its Telegram bot: your human's Connect tap (Mini App, Team)" \
            '**None fits:** `5dive hire-link --create --name=<Name> --description=<need>`'; do
  [[ "$BLOCK" == *"$want"* ]] && ok "hired-agents block says: $want" || bad "hired-agents block says: $want"
done

# DIVE-5449 (lodar: "if user ask something do it ... that logic should apply to
# all"): the owner's ask is the authorisation. One general line says so, and it
# reaches the box.
GENERAL="- **Your owner's ask IS the go-ahead:** do what your tier can, no link/tap/gate; else say why, then the Standard-tier route. **Except a hire:** wait for their yes; \"I need someone to…\" or \"full authority\" is not one, naming the agent is."
grep -qxF -- "$GENERAL" "$LIVE" && ok 'the rendered box file carries the general owner-ask line' \
  || bad 'the rendered box file carries the general owner-ask line' "no '$GENERAL'"
# DIVE-5824: with "on their yes" written only on the market line, the admin lead
# on exact-swallow still hired on the need alone, on both paths: the general
# go-ahead line above it won. So the exception is graded INSIDE the go-ahead line,
# and it names the owner's standing grant, which that lead held ("full authority").
GOLINE=$(grep -F "**Your owner's ask IS the go-ahead:**" "$LIVE")
for want in '**Except a hire:** wait for their yes' '"I need someone to…"' '"full authority" is not one' 'naming the agent is'; do
  [[ "$GOLINE" == *"$want"* ]] && ok "the go-ahead line itself carves out the hire: $want" \
    || bad "the go-ahead line itself carves out the hire: $want" "$GOLINE"
done
# Negative control: the block as an ADMIN seat reads it. Every standard-tier
# route is written "Standard-tier…" and runs to the end of its bullet, so cut
# those; what is left is what admin is told to do. It must not bounce an owner's
# ask with a link, a tap, a gate or a hand-off for work admin runs itself. The one
# tap left is a real limit, not a guardrail: the new agent's Telegram bot is made
# by the owner's own Telegram account (Connect), which no seat holds.
# DIVE-5722: the verb's own name (`5dive hire-link --create …`) is cut too: running
# it is not answering the owner with a link, and what it prints is graded above.
ADMIN=$(grep '^- ' <<<"$BLOCK" | grep -vxF -- "$GENERAL" | sed 's/Standard-tier.*$//' \
        | sed "s/its Telegram bot: your human's Connect tap (Mini App, Team)//" | sed 's/`5dive hire-link --create [^`]*`//')
if grep -niE 'link|tap|gate|approv|sysadmin|task add|your lead|ask (an|your)|send your human' <<<"$ADMIN" >"$TMP/bounce"; then
  bad 'an admin seat is never told to answer its owner with a link, tap or hand-off' "$(head -3 "$TMP/bounce")"
else ok 'an admin seat is never told to answer its owner with a link, tap or hand-off'; fi
for want in 'sudo 5dive agent import <slug>' 'sudo 5dive agent create <name>' '**Root**, admin: `sudo 5dive`.'; do
  [[ "$ADMIN" == *"$want"* ]] && ok "admin reads: $want" || bad "admin reads: $want"
done

# DIVE-5449: an admin seat hires a catalogue pack itself, with the Mini App's own
# argv (5dive-frontend hireCalls: agent import <slug> --as= --isolation= and the
# owner's signed-in account). Olivia refused, citing billing: there is none on a
# box that is up, so the block names none.
grep -qiE 'bill|pay|stars|charge|cost' <<<"$BLOCK" \
  && bad "the hired-agents block names no billing ($(grep -oiE 'bill|pay|stars|charge|cost' <<<"$BLOCK" | head -1))" \
  || ok 'the hired-agents block names no billing'
HIRE=$(grep -F '**`5dive market` hires**' <<<"$BLOCK" | grep -oE '`sudo 5dive agent import [^`]*`' | tr -d '`')
[[ "$HIRE" == 'sudo 5dive agent import <slug> --as=<name> --auth-profile=<5dive account list>' ]] \
  && ok 'the admin hire is one exact sudo agent import line' || bad "admin hire verb ($HIRE)"
CAT=$(grep -F '**`5dive market` hires**' <<<"$BLOCK")
grep -qF '`--isolation=admin` for Leadership/Engineering/Ops' <<<"$CAT" \
  && ok 'the admin hire names the Mini App seat rule' || bad 'the admin hire names the Mini App seat rule'
# Drive the REAL cmd_import with that line (placeholders filled the way an agent
# fills them) up to cmd_create, which records its argv and stops: nothing is made.
L=${HIRE#sudo 5dive agent import }; L=${L//<slug>/dario}; L=${L//<name>/dario}
L=${L//<5dive account list>/mark}
read -r -a HARGV <<<"$L"
imp(){ ( source "$SRC/cmd_pack.sh"; set +e
  printf '%s\n' '{"packFormat":1,"agentName":"dario","config":{"type":"claude"},"includes":{"memory":false}}' >"$TMP/m.json"
  : >"$TMP/dario.tar.gz"
  require_root(){ :; }; registry_read(){ printf '{"agents":{}}\n'; }; _agents_md_is(){ return 1; }
  _marketplace_fetch_pack(){ [[ "$1" == dario ]] && printf '%s' "$TMP/dario.tar.gz"; }
  _pack_safe_extract(){ cp "$TMP/m.json" "$2/manifest.json"; }
  _pack_harness_targets(){ printf 'claude\n'; }; _pack_targets_declared(){ return 1; }
  _pack_disclosure_json(){ printf '{}\n'; }; _pack_disclosure_print(){ :; }; _pack_rename_persona(){ :; }
  resolve_model_alias(){ printf '%s' "$1"; }; is_known_type(){ [[ "$1" == claude ]]; }; step(){ :; }
  cmd_create(){ printf '%s\n' "$@" >"$TMP/create.argv"; return 1; }
  cmd_import "$@" ) >/dev/null 2>&1; }
rm -f "$TMP/create.argv"; imp "${HARGV[@]}" --isolation=admin
A=$(tr '\n' ' ' <"$TMP/create.argv" 2>/dev/null)
[[ "$A" == 'dario --type=claude '* && " $A" == *' --isolation=admin '* && " $A" == *' --auth-profile=mark '* ]] \
  && ok 'the block line imports pack dario as dario, admin seat, on the owner account' || bad "import argv ($A)"
# Control: the same import without --auth-profile binds the new agent to its own
# empty login, which never answers. That is why the line carries the flag.
rm -f "$TMP/create.argv"; imp dario --as=dario
A=$(tr '\n' ' ' <"$TMP/create.argv" 2>/dev/null)
[[ " $A" == *' --auth-profile=dario '* ]] && ok 'control: no --auth-profile binds the agent to its own empty login' \
  || bad "control argv ($A)"
grep -q 'sync_managed_block /home/claude/projects/CLAUDE.md "$REPO/projects-CLAUDE.md" 5dive:hired-agents' install.sh \
  && ok 'install.sh syncs the block on every install' || bad 'install.sh syncs the block'

# DIVE-5823: the pick is made reading `5dive market`, so the yes rule is printed
# there too, by the real cmd_market / cmd_market_show over a stubbed index.
mkt(){ ( source "$SRC/cmd_pack.sh"; set +e; JSON_MODE=0
  _marketplace_index(){ printf '%s' '{"packs":[{"slug":"tally","name":"Tally","rarity":"rare","character":"Accountant","tagline":"sends and chases invoices","tags":["invoices"],"skills":["emails"],"path":"packs/tally"}]}'; }
  _marketplace_slug(){ echo test/registry; }; _marketplace_base(){ echo https://example.invalid; }
  _pack_targets_from(){ echo claude; }; resolve_model_alias(){ printf '%s' "$1"; }; curl(){ return 22; }
  "$@" ) 2>&1; }
YES="your owner's need is not a yes, nor is a standing \"full authority\": name your pick to them; hire it once they say yes (or named it)"
for v in "cmd_market invoice" "cmd_market_show tally"; do
  o=$(mkt $v)
  grep -q 'tally' <<<"$o" && grep -qxF "  $YES" <<<"$o" && ok "$v lists the pack and says a need is not a yes" \
    || bad "$v lists the pack and says a need is not a yes ($(tail -2 <<<"$o" | tr '\n' ' '))"
done
# Control: a search that matches nothing names no pick, so it prints no yes line.
o=$(mkt cmd_market vegetable)
grep -qF 'not a yes' <<<"$o" && bad 'control: an empty search prints no yes line' || ok 'control: an empty search prints no yes line'

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
