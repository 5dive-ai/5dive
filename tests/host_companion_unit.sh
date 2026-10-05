#!/usr/bin/env bash
# DIVE-5622 unit harness: `5dive host companion [set|remove]`.
#
# 5dive-api calls `set` over /shell/exec (sudo -n 5dive …, so ROOT) once it has
# built a client's Russian companion box: the box's IPv4 and host key on argv,
# the private key on stdin. Those three are the only caller inputs, so the
# load-bearing arms are the refusals: a hostname, an IPv4 with a 4th octet over
# 255, a host key with a newline or a shell metachar, a key that is not OpenSSH
# armor, and a missing --key-stdin must all stop BEFORE anything is written or
# systemctl is asked anything. Then the effects: every file lands at its fixed
# path with its mode, the proxy unit runs ssh -N -D on loopback as nobody (never
# root), the ssh config pins the host key, the managed CLAUDE.md keeps what was
# already in it and carries exactly one block after two sets, and `remove` takes
# out the block, the files and the unit and leaves the rest of CLAUDE.md alone.
#
# systemctl, chgrp and the group lookup are seams recorded to a call log; every
# path is redirected into a temp dir. No root, no systemd.
#
# Run: bash tests/host_companion_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/host-companion-unit.XXXXXX)"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_host.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); printf 'ok   — %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL — %s\n' "$1"; }

export FIVE_COMPANION_DIR="$TMP/etc/5dive/companion"
export FIVE_COMPANION_SSH_CONF="$TMP/etc/ssh/ssh_config.d/50-5dive-companion.conf"
export FIVE_COMPANION_UNIT_DIR="$TMP/etc/systemd/system"
export FIVE_COMPANION_MD="$TMP/etc/claude-code/CLAUDE.md"
UNIT_FILE="$FIVE_COMPANION_UNIT_DIR/5dive-companion-proxy.service"

CALLS="$TMP/calls"
_host_systemctl() {
  printf 'systemctl %s\n' "$*" >> "$CALLS"
  [[ "$1" == is-active ]] && echo active
  return 0
}
_host_companion_chgrp() { printf 'chgrp %s\n' "$*" >> "$CALLS"; }
GROUP_OK=1
_host_companion_group_exists() { (( GROUP_OK )); }
require_root() { :; }   # the harness is not root

IP=192.0.2.7
HOSTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBmGfZcH4cZQ1i0X1s7k0r0Kq2bYy3m0bXvE6Q1c7Zl8"
KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\nQyNTUxOQAAACAZhn2XB+HGUNYtF9bO5NK9CqtmGMt5tG17xOkNXO2ZfAAAAJgAAAAAAAAA\n-----END OPENSSH PRIVATE KEY-----'

reset() { rm -rf "$TMP/etc"; : > "$CALLS"; JSON_MODE=0; GROUP_OK=1; }

refuses() {   # <desc> <stdin> <args...>
  local desc="$1" in="$2"; shift 2
  reset
  local out rc
  out=$( printf '%s' "$in" | cmd_host_companion "$@" 2>&1 ); rc=$?
  if (( rc != 0 )) && [[ ! -e "$TMP/etc" ]] && ! grep -q '^systemctl' "$CALLS"; then
    pass "$desc (refused rc=$rc, nothing written, systemctl untouched)"
  else
    bad "$desc (rc=$rc, etc=$( [[ -e $TMP/etc ]] && echo written || echo clean ), calls=$(tr '\n' ';' < "$CALLS")) out=${out:0:200}"
  fi
}

# ---- refusals ---------------------------------------------------------------
refuses "a hostname is not an IPv4"           "$KEY" set --host=ru.example.com --host-key="$HOSTKEY" --key-stdin
refuses "an octet over 255"                   "$KEY" set --host=192.0.2.256 --host-key="$HOSTKEY" --key-stdin
refuses "an IPv4 with a trailing option"      "$KEY" set "--host=$IP -oProxyCommand=x" --host-key="$HOSTKEY" --key-stdin
refuses "a host key with a newline"           "$KEY" set --host=$IP --host-key="$HOSTKEY"$'\n'"evil ssh-ed25519 AAAA" --key-stdin
refuses "a host key with a shell metachar"    "$KEY" set --host=$IP --host-key='ssh-ed25519 AAAA$(id)' --key-stdin
refuses "an unknown host-key type"            "$KEY" set --host=$IP --host-key="ssh-dss AAAAB3Nza" --key-stdin
refuses "no --key-stdin"                      "$KEY" set --host=$IP --host-key="$HOSTKEY"
refuses "a PEM RSA key, not OpenSSH armor"    $'-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----' set --host=$IP --host-key="$HOSTKEY" --key-stdin
refuses "a key body line with a space"        $'-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA BBBB\n-----END OPENSSH PRIVATE KEY-----' set --host=$IP --host-key="$HOSTKEY" --key-stdin
refuses "an empty key"                        "" set --host=$IP --host-key="$HOSTKEY" --key-stdin
refuses "an unknown flag"                     "$KEY" set --host=$IP --host-key="$HOSTKEY" --key-stdin --socks-port=9
GROUP_MISSING_OUT=$(reset; GROUP_OK=0; printf '%s' "$KEY" | cmd_host_companion set --host=$IP --host-key="$HOSTKEY" --key-stdin 2>&1; echo "rc=$?")
if [[ "$GROUP_MISSING_OUT" == *"rc=1"* && ! -e "$TMP/etc" ]]; then pass "no claude group: refused before writing"; else bad "no claude group: $GROUP_MISSING_OUT"; fi

# ---- set ----------------------------------------------------------------------
reset
mkdir -p "$(dirname "$FIVE_COMPANION_MD")"
printf '%s\n' "# Box policy" "keep me" > "$FIVE_COMPANION_MD"
out=$( printf '%s' "$KEY" | cmd_host_companion set --host=$IP --host-key="$HOSTKEY" --key-stdin 2>&1 ); rc=$?
(( rc == 0 )) && pass "set: rc=0" || bad "set: rc=$rc out=$out"

[[ "$(cat "$FIVE_COMPANION_DIR/id_ed25519")" == "$KEY" ]] && pass "set: the key file is exactly the stdin key" || bad "set: key file differs"
[[ "$(stat -c %a "$FIVE_COMPANION_DIR/id_ed25519")" == 640 ]] && pass "set: key mode 0640" || bad "set: key mode $(stat -c %a "$FIVE_COMPANION_DIR/id_ed25519")"
grep -qx "chgrp claude $FIVE_COMPANION_DIR/id_ed25519" "$CALLS" && pass "set: key group is claude" || bad "set: no chgrp claude on the key"
[[ "$(cat "$FIVE_COMPANION_DIR/known_hosts")" == "ru-box $HOSTKEY" ]] && pass "set: known_hosts pins the given host key under the alias" || bad "set: known_hosts=$(cat "$FIVE_COMPANION_DIR/known_hosts")"
conf=$(cat "$FIVE_COMPANION_SSH_CONF")
for want in "Host ru-box $IP" "  HostName $IP" "  User root" "  StrictHostKeyChecking yes" "  HostKeyAlias ru-box" \
            "  IdentityFile $FIVE_COMPANION_DIR/id_ed25519" "  UserKnownHostsFile $FIVE_COMPANION_DIR/known_hosts" "  IdentitiesOnly yes"; do
  grep -qxF -- "$want" <<<"$conf" && pass "ssh config: '$want'" || bad "ssh config lacks '$want'"
done
grep -qiE 'ProxyCommand|LocalCommand|PermitLocalCommand' <<<"$conf" && bad "ssh config carries a command option" || pass "ssh config: no command-running option"
unitc=$(cat "$UNIT_FILE")
grep -qx "User=nobody" <<<"$unitc" && pass "unit: runs as nobody" || bad "unit: User= is not nobody"
grep -qx "Group=claude" <<<"$unitc" && pass "unit: group claude (reads the key)" || bad "unit: Group= is not claude"
grep -qx "ExecStart=/usr/bin/ssh -F $FIVE_COMPANION_SSH_CONF -N -D 127.0.0.1:1080 -o ExitOnForwardFailure=yes ru-box" <<<"$unitc" \
  && pass "unit: ssh -N -D bound to loopback, no remote command" || bad "unit: ExecStart=$(grep ExecStart <<<"$unitc")"
grep -q "^Restart=always" <<<"$unitc" && pass "unit: restarts on drop" || bad "unit: no Restart=always"
grep -qx "systemctl daemon-reload" "$CALLS" && grep -qx "systemctl enable 5dive-companion-proxy.service" "$CALLS" \
  && grep -qx "systemctl restart 5dive-companion-proxy.service" "$CALLS" && pass "set: reload, enable, restart the fixed unit" || bad "set: calls=$(tr '\n' ';' < "$CALLS")"
md=$(cat "$FIVE_COMPANION_MD")
[[ "$(head -2 <<<"$md")" == $'# Box policy\nkeep me' ]] && pass "CLAUDE.md: what was there is kept" || bad "CLAUDE.md head: $(head -2 <<<"$md")"
grep -q 'socks5h://127.0.0.1:1080' <<<"$md" && grep -q 'ssh ru-box' <<<"$md" && pass "CLAUDE.md: names the proxy and ru-box" || bad "CLAUDE.md lacks the proxy line"

# a second set (a re-run after a rebuilt EU box) keeps ONE block
reset_calls() { : > "$CALLS"; }
reset_calls
printf '%s' "$KEY" | cmd_host_companion set --host=192.0.2.9 --host-key="$HOSTKEY" --key-stdin >/dev/null 2>&1
n=$(grep -c '^<!-- 5dive-companion:begin' "$FIVE_COMPANION_MD")
[[ "$n" == 1 ]] && pass "second set: exactly one CLAUDE.md block" || bad "second set: $n blocks"
grep -qx "  HostName 192.0.2.9" "$FIVE_COMPANION_SSH_CONF" && pass "second set: the new address replaces the old" || bad "second set: address not replaced"
grep -q "keep me" "$FIVE_COMPANION_MD" && pass "second set: CLAUDE.md content kept" || bad "second set: CLAUDE.md content lost"

# status
st=$( JSON_MODE=1; cmd_host_companion --json 2>/dev/null )
[[ "$(jq -r '.data.host + " " + .data.proxyState' <<<"$st")" == "192.0.2.9 active" ]] && pass "status: host and proxy state" || bad "status: $st"

# ---- remove ---------------------------------------------------------------------
reset_calls
cmd_host_companion remove >/dev/null 2>&1; rc=$?
(( rc == 0 )) && pass "remove: rc=0" || bad "remove: rc=$rc"
[[ ! -e "$UNIT_FILE" && ! -e "$FIVE_COMPANION_SSH_CONF" && ! -e "$FIVE_COMPANION_DIR/id_ed25519" ]] \
  && pass "remove: unit, ssh config and key are gone" || bad "remove: files left"
grep -qx "systemctl disable --now 5dive-companion-proxy.service" "$CALLS" && pass "remove: unit disabled and stopped" || bad "remove: calls=$(tr '\n' ';' < "$CALLS")"
[[ "$(cat "$FIVE_COMPANION_MD")" == $'# Box policy\nkeep me' ]] && pass "remove: CLAUDE.md back to what it was" || bad "remove: CLAUDE.md=$(cat "$FIVE_COMPANION_MD")"
st=$( JSON_MODE=1; cmd_host_companion --json 2>/dev/null )
[[ "$(jq -r '.data.configured' <<<"$st")" == false ]] && pass "status after remove: not configured" || bad "status after remove: $st"

# a box whose CLAUDE.md held only our block: remove deletes the file
reset
printf '%s' "$KEY" | cmd_host_companion set --host=$IP --host-key="$HOSTKEY" --key-stdin >/dev/null 2>&1
cmd_host_companion remove >/dev/null 2>&1
[[ ! -e "$FIVE_COMPANION_MD" ]] && pass "remove: a CLAUDE.md that held only the block is removed" || bad "remove: left $(cat "$FIVE_COMPANION_MD")"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
