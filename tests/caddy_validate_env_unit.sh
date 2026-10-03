#!/usr/bin/env bash
# DIVE-5430: `caddy validate` runs with caddy.service's EnvironmentFiles loaded.
#
# A box that gets certificates by DNS challenge writes `dns cloudflare
# {env.CF_API_TOKEN}` and keeps the token in the unit's EnvironmentFile. A bare
# `caddy validate` never sees it, so it failed on the UNMODIFIED file and both
# `route add` and the secret link's secrets.<domain> block were rolled back on
# such a box, with no cause printed. Arms: caddy_validate passes where the bare
# call fails (the negative control), the env file is parsed as data and never
# leaks out, both call sites land on a DNS-challenge file, and a real failure
# prints validate's own reason. CADDY_CF_BIN=<caddy built with caddy-dns/cloudflare>
# adds the same arms against the real binary; without it they print SKIP.
#
# Offline, no root, no systemd: `systemctl` and `caddy` are stubs on PATH.
# Run: bash tests/caddy_validate_env_unit.sh
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/caddy-validate-env-unit.XXXXXX)"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_route.sh cmd_secret_drop.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1"; }
skip(){ printf 'SKIP %s\n' "$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"
# caddy stub: Caddy 2.11's own failure for an empty {env.CF_API_TOKEN}.
cat >"$BIN/caddy" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == validate ]] || exit 2
if grep -qF '{env.CF_API_TOKEN}' "$3" && [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo '{"level":"info","msg":"using config from file","file":"Caddyfile"}'
  echo "{\"level\":\"error\",\"msg\":\"loading http app module: provision dns.providers.cloudflare: API token '' appears invalid; ensure it's correctly entered and not wrapped in braces nor quotes\"}"
  exit 1
fi
grep -q BADVALIDATE "$3" && { echo 'Error: adapting config using caddyfile: BADVALIDATE, line 3'; exit 1; }
echo 'Valid configuration'
EOF
# systemctl stub: what `systemctl show -p EnvironmentFiles --value caddy` prints.
cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "show -p EnvironmentFiles --value caddy" ]] && { printf '%s\n' "${STUB_ENVFILES:-}"; exit 0; }
exit 0
EOF
chmod +x "$BIN/caddy" "$BIN/systemctl"

ENVF="$TMP/cf-dns.env"
cat >"$ENVF" <<'EOF'
# Cloudflare DNS challenge
; a systemd-style comment
CF_API_TOKEN="0123456789abcdefABCDEF0123456789abcdefAB"

   CF_ZONE='example.com'
CF_NOTE=two words
$(touch PWNED)
EOF
export STUB_ENVFILES="$ENVF (ignore_errors=no) $TMP/missing.env (ignore_errors=yes)"

CF="$TMP/Caddyfile"
cat >"$CF" <<'EOF'
box.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    handle /files/* {
        reverse_proxy localhost:3101
    }
}
EOF
cp "$CF" "$TMP/Caddyfile.orig"

echo "== the helper"
[[ "$(caddy_env_files)" == "$ENVF"$'\n'"$TMP/missing.env" ]] && ok 'reads the unit'"'"'s EnvironmentFiles, ignore_errors tags dropped' \
  || bad "caddy_env_files ($(caddy_env_files | tr '\n' ' '))"
caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; rc=$?
[[ $rc == 1 ]] && ok 'negative control: the bare `caddy validate` fails on the unmodified DNS-challenge file' || bad "bare validate rc=$rc"
out=$(caddy_validate "$CF" 2>&1); rc=$?
[[ $rc == 0 ]] && ok 'caddy_validate passes the same file with the unit'"'"'s env loaded' || bad "caddy_validate rc=$rc ($out)"
[[ -z "${CF_API_TOKEN:-}" ]] && ok 'the token never leaks into the caller (subshell)' || bad 'CF_API_TOKEN leaked into the caller'
out=$(cd "$TMP" && STUB_ENVFILES="" caddy_validate "$CF" 2>&1); rc=$?
[[ $rc == 1 && "$(caddy_validate_why "$out")" == *"API token '' appears invalid"* ]] \
  && ok 'a unit with no env file still fails, and the why line is validate'"'"'s own cause' || bad "no-env rc=$rc why=$(caddy_validate_why "$out")"
[[ ! -e "$TMP/PWNED" && ! -e PWNED ]] && ok 'the env file is parsed as data, never executed' || bad 'a line of the env file was executed'
v=$(bash -c 'source src/lib/validation.sh; _caddy_env_load "$1"; printf "%s|%s|%s" "$CF_API_TOKEN" "$CF_ZONE" "$CF_NOTE"' _ "$ENVF")
[[ "$v" == '0123456789abcdefABCDEF0123456789abcdefAB|example.com|two words' ]] \
  && ok 'KEY=VALUE as systemd reads it: quotes stripped, comments and blanks skipped, inner spaces kept' || bad "parsed ($v)"
[[ "$(caddy_validate_why $'x\nError: adapting config: bad')" == 'Error: adapting config: bad' ]] \
  && ok 'why line: an older Caddy'"'"'s `Error:` line wins' || bad 'why line for Error:'

echo "== route add on a DNS-challenge box"
PROV="$TMP/provisioning.env"; printf 'FIVE_DOMAIN=box.example.com\n' >"$PROV"
export ROUTE_CADDYFILE="$CF" ROUTE_PROVISIONING="$PROV" ROUTE_CADDY_BIN="$BIN/caddy" ROUTE_LOCK="$TMP/route.lock" ROUTE_RELOAD_CMD=true
cand="$TMP/cand"; { cat "$CF"; printf '\napp.box.example.com {\n    reverse_proxy 127.0.0.1:3200\n}\n'; } >"$cand"
( _route_apply "$cand" ) >"$TMP/out" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q '^app.box.example.com {' "$CF" && ok '_route_apply swaps the candidate in' || bad "_route_apply rc=$rc ($(cat "$TMP/out"))"
cp "$TMP/Caddyfile.orig" "$CF"
{ cat "$CF"; printf 'BADVALIDATE\n'; } >"$cand"
( _route_apply "$cand" ) >"$TMP/out" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q 'BADVALIDATE, line 3' "$TMP/out" && cmp -s "$CF" "$TMP/Caddyfile.orig" \
  && ok 'a real validate failure leaves the file and prints the reason' || bad "fail path rc=$rc ($(cat "$TMP/out"))"
# Mutation: the pre-fix bare call. The same candidate must be refused.
sed 's|caddy_validate "$cand" "$ROUTE_CADDY_BIN"|"$ROUTE_CADDY_BIN" validate --config "$cand" --adapter caddyfile|' src/cmd_route.sh >"$TMP/route.mutant.sh"
grep -q '"$ROUTE_CADDY_BIN" validate --config' "$TMP/route.mutant.sh" || bad 'mutant did not apply'
{ cat "$CF"; printf '\napp.box.example.com {\n    reverse_proxy 127.0.0.1:3200\n}\n'; } >"$cand"
( source "$TMP/route.mutant.sh"; _route_apply "$cand" ) >"$TMP/out" 2>&1; rc=$?
[[ $rc != 0 ]] && cmp -s "$CF" "$TMP/Caddyfile.orig" && ok 'mutation: the bare call refuses the route (this arm is what the fix turns green)' \
  || bad "mutant rc=$rc"

echo "== secret link route on a DNS-challenge box"
SECRET_DROP_CADDYFILE="$CF" SECRET_DROP_PROVISIONING="$PROV" SECRET_DROP_CONF="$TMP/none.conf"
systemd-run(){ :; }
cp "$TMP/Caddyfile.orig" "$CF"
_secret_drop_ensure_route >"$TMP/out" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q '^secrets\.box\.example\.com {' "$CF" && ok 'secrets.<domain> lands on the DNS-challenge file' || bad "secret route rc=$rc ($(cat "$TMP/out"))"
cp "$TMP/Caddyfile.orig" "$CF"
( STUB_ENVFILES=""; _secret_drop_ensure_route ) >"$TMP/out" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q "API token '' appears invalid" "$TMP/out" && cmp -s "$CF" "$TMP/Caddyfile.orig" \
  && ok 'without the env file it restores and says why' || bad "secret route no-env rc=$rc ($(cat "$TMP/out"))"
unset -f systemd-run

echo "== the real Caddy (caddy-dns/cloudflare)"
if [[ -x "${CADDY_CF_BIN:-}" ]]; then
  R="$TMP/real.Caddyfile"
  printf '{\n\tadmin off\n}\nbox.example.com {\n\ttls {\n\t\tdns cloudflare {env.CF_API_TOKEN}\n\t}\n\trespond "ok"\n}\n' >"$R"
  "$CADDY_CF_BIN" validate --config "$R" --adapter caddyfile >/dev/null 2>&1; rc=$?
  [[ $rc == 1 ]] && ok 'real: the bare validate fails on the unmodified file' || bad "real bare rc=$rc"
  out=$(caddy_validate "$R" "$CADDY_CF_BIN" 2>&1); rc=$?
  [[ $rc == 0 ]] && ok 'real: caddy_validate passes it' || bad "real caddy_validate rc=$rc ($(caddy_validate_why "$out"))"
  out=$(STUB_ENVFILES="" caddy_validate "$R" "$CADDY_CF_BIN" 2>&1)
  [[ "$(caddy_validate_why "$out")" == *"API token '' appears invalid"* ]] && ok 'real: the why line names the cause' || bad "real why ($(caddy_validate_why "$out"))"
else
  skip 'CADDY_CF_BIN not set'
fi

echo "RESULT: $P pass, $F fail"
(( F == 0 ))
