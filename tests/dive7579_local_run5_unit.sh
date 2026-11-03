#!/usr/bin/env bash
# DIVE-7579: the fully-local run-5 proof (DIVE-7578) failed on these. Each arm
# group fails on the tree before the fix.
#
#   D1 office chat on a two-network box: the model link is skipped, an
#      undecidable box is refused naming the choices and --addr= (never ON with
#      a page the office cannot reach). Two-interface fixture.
#   D2 a failed panel action under the bundle's `set -e` still writes its audit
#      line and answers in plain words (it killed the helper: "no answer").
#   D3 local-only lets `agent create --auth-profile=<own AI on the LAN>` through
#      (what the panel and `account add` run); cloud accounts, public URLs, a
#      bad name and new credentials on the account are still refused.
#   D4 the panel's update-file install, root side (the live upload is in
#      tests/local_panel_unit.sh).
#   D5 an update file's plugins: bun's cross-plugin hard links make a filtered
#      extract fail (tar rc 2); install.sh's plugin_subtrees takes them whole.
#   D6 `local _restage` brings a running office chat to this CLI's server and
#      restarts it only when it changed; install.sh --upgrade calls it.
#   D7 every Claude Code run the CLI starts on a local-only box carries the
#      quiet env: the busy probe, the auth/quota probe, the memory distiller;
#      a structural sweep finds no unwrapped call site.
#   M1 an update that changes nothing in a seat's checkout owes it no restart.
#
# No network, no root, no systemd: ip/systemctl/sudo are shell functions here.
# ADDRESSES: the public one is RFC 5737's. The code under test tells PRIVATE
# networks apart, which a documentation address (public by class) cannot stand
# in for, so the two private networks are made-up RFC 1918 values built from a
# prefix ($NA model link, $NB office LAN) — not the rig's, and no host's.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok_ "$1"; else bad_ "$1" "$2"; fi; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dive7579.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export FIVE_LOCAL_CHAT_ROOT="$TMPD/root" FIVE_PANEL_CLI="$TMPD/fake5dive"
export FIVE_LOCAL_ONLY_FILE="$TMPD/local-only" FIVE_API_BASE_FILE="$TMPD/api-base" FIVEDIVE_CONNECTORD_ENV="$TMPD/no-connectord.env"
mkdir -p "$TMPD/root/etc/systemd/system" "$TMPD/root/etc/5dive/local-chat" "$TMPD/root/usr/local/lib/5dive/local-chat" "$TMPD/profiles"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/local_only.sh cmd_local_chat.sh cmd_local_chat_server.sh cmd_local_panel.sh; do source "src/$f"; done
set +e
JSON_MODE=0
require_root() { :; }
AUTH_PROFILES_DIR="$TMPD/profiles"
prof() { mkdir -p "$TMPD/profiles/$1"; printf '%s\n' "${@:2}" >"$TMPD/profiles/$1/combined.env"; }
PUB=192.0.2.111 GW=192.0.2.1
NA=10.20 NB=10.30
BOX_A="$NA.0.2" MODEL="$NA.0.3" BOX_B="$NB.0.2" LANHOST="$NB.0.9"

# ── D1. the office address on a two-network box ─────────────────────────────
# The run-5 shape: the model link on the LOWER interface (enp7s0), the office
# LAN on enp8s0, a public address on eth0.
IFACES="2: eth0    inet $PUB/32 scope global dynamic eth0
3: enp7s0    inet $BOX_A/32 brd $BOX_A scope global dynamic enp7s0
4: enp8s0    inet $BOX_B/32 brd $BOX_B scope global dynamic enp8s0"
ip() {
  case "$*" in
    "-4 -o addr show scope global") printf '%s\n' "$IFACES" ;;
    "-4 route get $MODEL") echo "$MODEL via $NA.0.1 dev enp7s0 src $BOX_A uid 0" ;;
    "-4 route get $LANHOST") echo "$LANHOST via $NB.0.1 dev enp8s0 src $BOX_B uid 0" ;;
    "-4 route get "*) echo "${4} via $GW dev eth0 src $PUB uid 0" ;;
    *) return 1 ;;
  esac
}
hostname() { return 1; }
getent() { [[ "$1 $2" == "ahostsv4 gpu.lan" ]] && echo "$MODEL       STREAM gpu.lan"; }
out=$(_lc_lan_addr); r=$?
check 'D1a two networks, no model known yet: undecidable (rc 2), NOT the first one' '(( r == 2 )) && [[ -z "$out" ]]'
msg=$( ( _lc_serve ) 2>&1 ); r=$?
check 'D1b … serve refuses, names both addresses with their networks and the --addr= to pass' '(( r != 0 )) && grep -qF "$BOX_A (enp7s0)" <<<"$msg" && grep -qF "$BOX_B (enp8s0)" <<<"$msg" && grep -q -- "--addr=" <<<"$msg" && grep -q "NOT started" <<<"$msg"'
check 'D1c … and wrote no config (nothing reports ON)' '[[ ! -e "$(_lc_conf)" ]]'
prof office-ai FIVEDIVE_CUSTOM_HARNESS=claude "FIVEDIVE_CUSTOM_BASE_URL=http://$MODEL:11434" FIVEDIVE_CUSTOM_MODEL=qwen3:8b
check 'D1d the own-AI account is on the model link: the office one is chosen' '[[ "$(_lc_lan_addr)" == "$BOX_B" ]]'
rm -rf "$TMPD/profiles/office-ai"; prof office-llm ANTHROPIC_BASE_URL=http://gpu.lan:11434
check 'D1e a --base-url account by NAME (resolved, then routed) works the same' '[[ "$(_lc_lan_addr)" == "$BOX_B" ]]'
rm -rf "$TMPD/profiles/office-llm"; prof office-ai "FIVEDIVE_CUSTOM_BASE_URL=http://$LANHOST:11434"
check 'D1f the model on the office LAN itself: the other private one is not guessed' '[[ "$(_lc_lan_addr)" == "$BOX_A" ]]'
IFACES="2: eth0    inet $PUB/32 scope global eth0
3: enp7s0    inet $BOX_A/32 scope global enp7s0"
rm -rf "$TMPD/profiles/office-ai"
check 'D1g one private network: that one, as before' '[[ "$(_lc_lan_addr)" == "$BOX_A" ]]'
IFACES="2: eth0    inet $PUB/32 scope global eth0"
_lc_lan_addr >/dev/null; r=$?
check 'D1h a public address alone is never chosen (rc 1)' '(( r == 1 ))'
unset -f ip hostname getent

# ── D2. a failed panel action under set -e ──────────────────────────────────
cat >"$FIVE_PANEL_CLI" <<FAKE
#!/usr/bin/env bash
printf '%q ' "\$@" >>"$TMPD/cli.log"; printf '\n' >>"$TMPD/cli.log"
case " \$* " in
  *" agent restart nosuch "*) echo '{"ok":false,"error":{"message":"no agent named nosuch"}}'; exit 1 ;;
  *" self-update --from="*"bad.tar "*) echo '{"ok":false,"error":{"message":"update refused: the signature does not match the update key. Nothing was changed; this box stays on 0.116.0."}}'; exit 3 ;;
  *" self-update --from="*) echo '{"ok":true,"data":{"restarted":["ada"]}}' ;;
  *" --version "*) echo '{"ok":true,"data":{"version":"0.117.0"}}' ;;
  *) echo '{"ok":true,"data":{"done":true}}' ;;
esac
FAKE
chmod +x "$FIVE_PANEL_CLI"
AUD="$(_lp_audit_file)"
out=$( set -euo pipefail; _lp_exec agent-restart nosuch </dev/null ); r=$?
check 'D2a under set -e the helper answers (rc 0, one JSON reply), it does not die' '(( r == 0 )) && [[ "$(jq -r .ok <<<"$out")" == false ]]'
check 'D2b … the page gets what failed in plain words' '[[ "$(jq -r .error <<<"$out")" == "no agent named nosuch" ]]'
check 'D2c … and the audit line is written' 'grep -qP "\tagent-restart\tnosuch\tfailed: no agent named nosuch$" "$AUD"'

# ── D3. local-only: an own-AI account on the LAN may create an agent ─────────
touch "$FIVE_LOCAL_ONLY_FILE"
prof office-ai FIVEDIVE_CUSTOM_HARNESS=claude "FIVEDIVE_CUSTOM_BASE_URL=http://$MODEL:11434" FIVEDIVE_CUSTOM_MODEL=qwen3:8b "ANTHROPIC_BASE_URL=http://$MODEL:11434"
prof claude-main CLAUDE_CODE_OAUTH_TOKEN=x
prof halfway "FIVEDIVE_CUSTOM_BASE_URL=http://$MODEL:11434" OPENAI_BASE_URL=https://models.example.com/v1
prof cloudy FIVEDIVE_CUSTOM_BASE_URL=https://models.example.com
gate() { ( local_only_gate "$@" ) >/dev/null 2>&1; }
check 'D3a agent create --auth-profile=<own AI on the LAN> passes (the panel and account add hint)' 'gate agent create bea --type=claude --auth-profile=office-ai --channels=dashboard'
check 'D3b hire and agent import with it pass too' 'gate hire bea --auth-profile=office-ai && touch "$TMPD/p.tar.gz" && gate agent import "$TMPD/p.tar.gz" --auth-profile=office-ai'
check 'D3c a cloud sign-in account is still refused' '! gate agent create bea --type=claude --auth-profile=claude-main'
check 'D3d an account with ANY address outside the office is refused' '! gate agent create bea --auth-profile=halfway && ! gate agent create bea --auth-profile=cloudy'
check 'D3e no account and no --base-url is still refused' '! gate agent create bea --type=claude'
check 'D3f an account name that is a path is refused (never read)' '! gate agent create bea --auth-profile=../office-ai'
check 'D3g new credentials onto the account still need a LAN --base-url' '! gate agent create bea --auth-profile=office-ai --api-key=sk-x && ! gate agent create bea --auth-profile=office-ai --provider=anthropic'
check 'D3h auth set onto a LAN account is unchanged (still needs --base-url)' '! gate agent auth set claude --api-key=sk-x --auth-profile=office-ai && ! gate account set office-ai --api-key=sk-x'
check 'D3i an explicit --base-url still wins over the account' '! gate agent create bea --auth-profile=office-ai --base-url=https://models.example.com && gate agent create bea --auth-profile=claude-main "--base-url=http://$MODEL:11434"'
msg=$( ( local_only_gate agent create bea --auth-profile=claude-main ) 2>&1 )
check 'D3j the refusal names the account in plain words' 'grep -q "AI account .claude-main. (it has no model server on your network)" <<<"$msg"'
rm -f "$FIVE_LOCAL_ONLY_FILE"
check 'D3k off: nothing changes' 'gate agent create bea --type=claude --auth-profile=claude-main'

# ── D4 (root side). install an update file from the panel ───────────────────
check 'D4a the card shows when this CLI carries the file verifier (was: grep for a flag that never existed)' '( _ou_verify() { :; }; FIVE_PANEL_CLI=/bin/false _lp_update_ready ) && ! ( unset -f _ou_verify; _lp_update_ready )'
SPAWNED=0
systemctl() { [[ "$1 $2" == "is-active --quiet" ]] && [[ -n "${UPD_RUNNING:-}" ]]; }
_lp_spawn_update() { SPAWNED=$((SPAWNED + 1)); ( _lp_update_run ); }
inbox() { mkdir -p "$(dirname "$(_lp_update_inbox)")"; printf '%s' "$1" >"$(_lp_update_inbox)"; }
out=$(_lp_exec update-install </dev/null)
check 'D4b nothing uploaded: a plain refusal, nothing started' '[[ "$(jq -r .error <<<"$out")" == "No update file arrived. Pick the file again." ]] && (( SPAWNED == 0 ))'
inbox "signed-file-bytes"
_lp_exec update-install </dev/null >"$TMPD/o"; out=$(cat "$TMPD/o")
check 'D4c an uploaded file: install started, the copy is root-side and the inbox emptied' '[[ "$(jq -r .data.state <<<"$out")" == running ]] && [[ ! -e "$(_lp_update_inbox)" ]]'
st=$(_lp_exec update-status </dev/null)
check 'D4d … the install ran self-update --from=<the root copy> and the status says the new version' '[[ "$(jq -r .data.state <<<"$st")" == done && "$(jq -r .data.to <<<"$st")" == 0.117.0 && "$(jq -r .data.message <<<"$st")" == "Updated to 0.117.0." ]] && grep -qF -- "self-update --from=$(_lp_update_dir)/update.tar" "$TMPD/cli.log"'
check 'D4e … the copy is gone after the run; the status file is root-only' '[[ ! -e "$(_lp_update_dir)/update.tar" && "$(stat -c %a "$(_lp_update_dir)/status.json")" == 600 ]]'
eval "$(declare -f _lp_update_run | sed '1s/_lp_update_run/_lp_update_run_bad/; s#/update.tar"#/bad.tar"#')"
_lp_spawn_update() { SPAWNED=$((SPAWNED + 1)); mv -f "$(_lp_update_dir)/update.tar" "$(_lp_update_dir)/bad.tar"; ( _lp_update_run_bad ); }
inbox "tampered"
_lp_exec update-install </dev/null >/dev/null
st=$(_lp_exec update-status </dev/null)
check 'D4f a file the signature check refuses: failed, in plain words, nothing installed' '[[ "$(jq -r .data.state <<<"$st")" == failed ]] && [[ "$(jq -r .data.message <<<"$st")" == "Not installed: the signature does not match the update key. Nothing was changed; this box stays on 0.116.0." ]]'
inbox "x"; UPD_RUNNING=1; out=$(_lp_exec update-install </dev/null); unset UPD_RUNNING
check 'D4g a second install while one runs is refused' '[[ "$(jq -r .error <<<"$out")" == *"already being installed"* ]]'
ln -sf /etc/passwd "$(_lp_update_inbox)"; n0=$SPAWNED
out=$(_lp_exec update-install </dev/null)
check 'D4h a link put in the chat server folder is refused, never followed' '[[ "$(jq -r .ok <<<"$out")" == false ]] && (( SPAWNED == n0 ))'
printf '{"state":"running","message":"x"}' >"$(_lp_update_dir)/status.json"
check 'D4i a run that died mid-way reads as failed, not running forever' '[[ "$(_lp_exec update-status </dev/null | jq -r .data.state)" == failed ]]'
out=$(_lp_exec update-install extra </dev/null)
check 'D4j update-install takes no argument (the path is fixed)' '[[ "$(jq -r .error <<<"$out")" == "refused: wrong number of arguments" ]]'
check 'D4k the transient unit runs the fixed hidden verb as root' 'grep -q "/usr/local/bin/5dive local _panel-update-run" src/cmd_local_panel.sh && grep -q "_panel-update-run) _lp_update_run" src/cmd_local_chat.sh'
unset -f systemctl

# ── D5. update-file plugins with cross-plugin hard links ────────────────────
S="$TMPD/stage"; P="$TMPD/pl/5dive-plugins-main/plugins"
mkdir -p "$P/buzz/node_modules/accepts" "$P/dashboard/node_modules/accepts" "$P/telegram-codex" "$S/payload" "$S/plugins"
printf 'module.exports = 1;\n' >"$P/buzz/node_modules/accepts/index.js"
ln "$P/buzz/node_modules/accepts/index.js" "$P/dashboard/node_modules/accepts/index.js"   # what bun install does
printf 'serve\n' >"$P/dashboard/server.ts"; printf 'dispatch\n' >"$P/telegram-codex/dispatcher.ts"
tar --sort=name -czf "$S/payload/plugins.tar.gz" -C "$TMPD/pl" 5dive-plugins-main
check 'D5a fixture: the dashboard file is stored as a hard link into buzz' 'tar -tvzf "$S/payload/plugins.tar.gz" | grep -q "dashboard/node_modules/accepts/index.js link to"'
mkdir -p "$TMPD/old"
curl -fsSL "file://$S/payload/plugins.tar.gz" | tar -xz -C "$TMPD/old" --strip-components=1 5dive-plugins-main/plugins/telegram-codex 5dive-plugins-main/plugins/dashboard 2>/dev/null
r=${PIPESTATUS[1]}
check "D5b the old filtered extract fails on it (tar rc $r, as on the run-5 box)" '(( r == 2 ))'
tar -xzf "$S/payload/plugins.tar.gz" -C "$S/plugins" --strip-components=1   # what _ou_verify does
eval "$(sed -n '/^plugin_subtrees() {/,/^}/p' install.sh)"
check 'D5c install.sh has plugin_subtrees' 'declare -F plugin_subtrees'
d="$TMPD/new1"; mkdir -p "$d"
plugin_subtrees "file://$S/payload/plugins.tar.gz" "$d" telegram-codex dashboard; r=$?
check 'D5d from an update file: both plugins whole, the linked package present (rc 0)' '(( r == 0 )) && [[ -f "$d/plugins/telegram-codex/dispatcher.ts" && -f "$d/plugins/dashboard/server.ts" && "$(cat "$d/plugins/dashboard/node_modules/accepts/index.js")" == "module.exports = 1;" ]]'
mkdir -p "$TMPD/lone/payload"; cp "$S/payload/plugins.tar.gz" "$TMPD/lone/payload/"
d="$TMPD/new2"; mkdir -p "$d"
plugin_subtrees "file://$TMPD/lone/payload/plugins.tar.gz" "$d" dashboard; r=$?
check 'D5e a file:// tarball with no unpacked copy beside it: unpacked whole, then taken' '(( r == 0 )) && [[ -f "$d/plugins/dashboard/node_modules/accepts/index.js" ]]'
d="$TMPD/new3"; mkdir -p "$d"
check 'D5f a plugin the file does not carry fails the step (it is not silently empty)' '! plugin_subtrees "file://$S/payload/plugins.tar.gz" "$d" telegram-nope'
check 'D5g all five root-staged plugin steps use it; no filtered tarball pipe is left' '(( $(grep -c "if plugin_subtrees \"\$[A-Z]*_PLUGIN_TARBALL\"" install.sh) == 5 )) && ! grep -qE "curl -fsSL \"\\\$[A-Z]+_PLUGIN_TARBALL\"" install.sh'

# ── D6. an update re-stages the office chat ─────────────────────────────────
systemctl() { printf '%s\n' "$*" >>"$TMPD/sc.log"; return 0; }
_lc_bun() { printf '/usr/local/bin/bun'; }
out=$(_lc_restage)
check 'D6a no office chat on this box: nothing touched' '[[ "$out" == *"not set up"* && ! -e "$(_lc_lib)/server.ts" ]]'
printf 'LAN_ADDR=%s\nLAN_PORT=8443\nLOOP_PORT=8480\nTOKEN_FILE=/etc/5dive/local-chat/token.env\n' "$BOX_B" >"$(_lc_conf)"
printf '# old unit\n' >"$(_lc_unit)"; printf '// the server an older CLI staged\n' >"$(_lc_lib)/server.ts"
_lp_socket_text >"$(_lp_socket_unit)"; _lp_service_text >"$(_lp_service_unit)"
: >"$TMPD/sc.log"; out=$(_lc_restage)
check 'D6b a stale server: re-staged from this CLI' 'cmp -s <(_local_chat_server_ts) "$(_lc_lib)/server.ts"'
check 'D6c … the unit rewritten from the saved settings' 'grep -qxF "Environment=LC_STATE=$(_lc_state) LC_LAN_ADDR=$BOX_B LC_LAN_PORT=8443 LC_LOOP_PORT=8480" "$(_lc_unit)"'
check 'D6d … and the office chat restarted' '[[ "$out" == "refreshed and restarted" ]] && grep -qx "try-restart 5dive-local-chat.service" "$TMPD/sc.log"'
: >"$TMPD/sc.log"; out=$(_lc_restage)
check 'D6e run again: already current, NOT restarted' '[[ "$out" == "already current" ]] && ! grep -q restart "$TMPD/sc.log"'
check 'D6f install.sh --upgrade runs it when the box has an office chat' 'grep -q "\"\$BIN_DIR/5dive\" local _restage" install.sh && grep -q "_restage) _lc_restage" src/cmd_local_chat.sh'
unset -f systemctl

# ── D7. Claude Code started by the CLI on a local-only box ──────────────────
eval "$(sed -n '/^_hb_agent_native_state() {/,/^}/p' src/cmd_heartbeat.sh | sed "s#/home/agent-#$TMPD/home/agent-#")"
mkdir -p "$TMPD/home/agent-ada/.local/bin"; printf '#!/bin/sh\n' >"$TMPD/home/agent-ada/.local/bin/claude"; chmod +x "$TMPD/home/agent-ada/.local/bin/claude"
_hb_claude_pid() { printf 4242; }
sudo() { printf '%s\n' "$*" >"$TMPD/sudo.log"; echo '[{"pid":4242,"status":"idle"}]'; }
st=$(_hb_agent_native_state ada)
check 'D7a off: the busy probe is unchanged' '[[ "$st" == idle && "$(cat "$TMPD/sudo.log")" == "-n -u agent-ada $TMPD/home/agent-ada/.local/bin/claude agents --json" ]]'
touch "$FIVE_LOCAL_ONLY_FILE"
st=$(_hb_agent_native_state ada)
check 'D7b on: the busy probe (heartbeat + self-update busy check) carries the quiet env' '[[ "$st" == idle ]] && [[ "$(cat "$TMPD/sudo.log")" == "-n -u agent-ada env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1 NPM_CONFIG_REGISTRY=http://127.0.0.1:9/ $TMPD/home/agent-ada/.local/bin/claude agents --json" ]]'
eval "$(sed -n '/^auth_probe_output() {/,/^}/p' src/cmd_auth.sh)"
declare -A TYPE_PROBE=([claude]='claude --print ping')
sudo() { printf '%s\n' "$*" >"$TMPD/sudo.log"; }
auth_probe_output claude office-ai 5 >/dev/null
check 'D7c on: the auth/quota probe exports the quiet env before claude runs' 'grep -q "export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; export DISABLE_AUTOUPDATER=1; .*claude --print ping" "$TMPD/sudo.log"'
rm -f "$FIVE_LOCAL_ONLY_FILE"; auth_probe_output claude office-ai 5 >/dev/null
check 'D7d off: the auth probe is unchanged' '! grep -q DISABLE_NONESSENTIAL "$TMPD/sudo.log"'
unset -f sudo
check 'D7e the memory distiller and its --help probe take the quiet env' 'grep -q "distiller=\"env \${_qp}\${distiller}\"" src/cmd_memory.sh && grep -qF "env \"\${_qa[@]}\" \"\$_cl\" --help" src/cmd_memory.sh'
check 'D7f doctor --repair never runs an internet install on a local-only box' 'grep -q "local-only mode is on: an update file brings it" src/cmd_doctor.sh'
# The sweep: every place the CLI itself execs Claude Code must sit in a function
# that reads local_only_claude_env. A new unwrapped call site fails here.
sweep_bad=""; sweep_n=0
while IFS=: read -r file line _; do
  sweep_n=$((sweep_n + 1))
  fn=$(awk -v L="$line" 'NR <= L && /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {f = $1} NR == L {print f; exit}' "$file")
  body=$(sed -n "/^${fn%%(*}() *{/,/^}/p" "$file")
  grep -q "local_only_claude_env" <<<"$body" || sweep_bad+="$file:$line(${fn%%(*}) "
done < <(grep -nE '(agents --json|"\$_cl" --help|distiller="\$_cl |sudo -u claude -i timeout)' src/cmd_heartbeat.sh src/cmd_memory.sh src/cmd_auth.sh | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')
check "D7g sweep: all $sweep_n Claude Code call sites the CLI runs read the quiet env (${sweep_bad:-none unwrapped})" '[[ -z "$sweep_bad" ]] && (( sweep_n >= 4 ))'

# ── M1. an update that moves nothing in a seat's checkout ───────────────────
source src/lib/offline_update.sh; set +e
co="$TMPD/co"; mkdir -p "$co/.claude-plugin" "$co/plugins/dashboard"
printf '{}\n' >"$co/.claude-plugin/marketplace.json"; printf 'v1\n' >"$co/plugins/dashboard/server.ts"
git -C "$co" init -q && git -C "$co" add -A && git -C "$co" -c user.name=t -c user.email=t@example.com commit -qm init
src="$TMPD/upd"; mkdir -p "$src/.claude-plugin" "$src/plugins/dashboard"
cp "$co/.claude-plugin/marketplace.json" "$src/.claude-plugin/"; printf 'v1\n' >"$src/plugins/dashboard/server.ts"
_ou_refresh_checkout "$src" "$co"; r=$?
check 'M1a the same plugins: rc 3 (no restart owed), no commit' '(( r == 3 )) && (( $(git -C "$co" rev-list --count HEAD) == 1 ))'
printf 'v2\n' >"$src/plugins/dashboard/server.ts"
_ou_refresh_checkout "$src" "$co"; r=$?
check 'M1b changed plugins: rc 0, committed' '(( r == 0 )) && (( $(git -C "$co" rev-list --count HEAD) == 2 )) && [[ "$(cat "$co/plugins/dashboard/server.ts")" == v2 ]]'
check 'M1c self-update restarts on rc 0 only, says "already current" on 3' 'grep -q "elif (( co_rc == 3 )); then" src/cmd_selfupdate.sh'

# ── m2. a long check item keeps two spaces before its state ─────────────────
source src/cmd_local_only.sh; set +e
row=$(_lo_line ok "plugin catalog refresh (agent-ada)" "local copy")
check 'm2 a 34-character item still parses as item + state (the panel splits on two spaces)' '[[ "$(jq -Rr "capture(\"^(?<s>ok|LEAK) +(?<item>.+?)  +(?<state>.*)$\") | .state" <<<"$row")" == "local copy" ]]'

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
