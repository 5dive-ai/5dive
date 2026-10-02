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
hl mycustombot --json; grep -qF '"status":"not_catalogue"' "$TMP/out" && grep -qi 'custom' "$TMP/out" \
  && ok 'a non-catalogue slug says custom agents are made on the web' || bad "not catalogue ($(cat "$TMP/out"))"
( cmd_hire_link 'a/b' ) >/dev/null 2>&1 && bad 'a malformed slug is refused' || ok 'a malformed slug is refused'

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
BLOCK=$(sed -n '/<!-- 5dive:hired-agents:begin/,/<!-- 5dive:hired-agents:end/p' projects-CLAUDE.md)
for want in 'never create or import agents yourself' '5dive hire-link <slug>' '5dive pkg install' \
            '5dive route add <name> --port=<port>' '5dive task add' 'npm i -g'; do
  [[ "$BLOCK" == *"$want"* ]] && ok "hired-agents block says: $want" || bad "hired-agents block says: $want"
done
grep -q 'sync_managed_block /home/claude/projects/CLAUDE.md "$REPO/projects-CLAUDE.md" 5dive:hired-agents' install.sh \
  && ok 'install.sh syncs the block on every install' || bad 'install.sh syncs the block'

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
