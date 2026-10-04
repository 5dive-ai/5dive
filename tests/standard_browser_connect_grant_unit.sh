#!/usr/bin/env bash
# DIVE-5495: a standard seat holds ONE exact-path line for the browser plugin's
# privileged Connect half, `5dive browser _connect`, so an agent's captcha/login
# request reaches its owner and the owner's tap opens the viewer. Root re-checks
# the code, the seat and the tapper inside the verb; the grant names no args.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/browser-connect-grant.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_agent_create.sh; do
  source "$SRC/$f"
done
set +e
P=0; F=0
ok(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
bad(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }

for caps in '0 0' '1 0' '0 1' '1 1'; do
  # shellcheck disable=SC2086
  SUD=$(render_standard_sudoers agent-tap $caps)
  [[ $(grep -cE '^agent-tap ALL=\(root\) NOPASSWD: /usr/local/bin/5dive browser _connect$' <<<"$SUD") == 1 ]] \
    && ok "browser _connect line rendered once, exact, no args (caps $caps)" \
    || bad "browser _connect line rendered once, exact, no args (caps $caps)"
  # The classifier must read the rendered file as standard with NO unrecognised
  # entry, or `agent _reconcile_sudoers` skips the seats that need the line and
  # the plugin's measured-standard probe guard reads them as drifted.
  [[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
    && ok "rendered grant classifies cli-scoped, extra=0 (caps $caps)" \
    || bad "rendered grant classifies cli-scoped, extra=0 (caps $caps) (got $(classify_sudo_grant <<<"$SUD"))"
done
SUD=$(render_standard_sudoers agent-tap 0 0)
BL=$(grep -v '^#' <<<"$SUD"); BL=$(grep 'browser' <<<"$BL")
[[ "$BL" == 'agent-tap ALL=(root) NOPASSWD: /usr/local/bin/5dive browser _connect' ]] \
  && ok 'the one browser line is the exact _connect line' || bad "the one browser line is the exact _connect line (got: $BL)"
[[ "$BL" != *'*'* ]] \
  && ok 'browser grant carries no wildcard' || bad 'browser grant carries no wildcard'
# A widened line is NOT the scoped verb: it must still read as an extra entry.
[[ "$(printf 'agent-tap ALL=(root) NOPASSWD: /usr/local/bin/5dive browser _connect *\n' | classify_sudo_grant)" == 'custom|root|0' ]] \
  && ok 'a wildcarded browser _connect line is not recognised as scoped' \
  || bad 'a wildcarded browser _connect line is not recognised as scoped'
[[ "$(printf 'agent-tap ALL=(root) NOPASSWD: /usr/local/bin/5dive browser setup\n' | classify_sudo_grant)" == 'custom|root|0' ]] \
  && ok 'another browser verb is not recognised as scoped' || bad 'another browser verb is not recognised as scoped'
grep -qF 'command == "/usr/local/bin/5dive browser _connect" or' "$SRC/cmd_agent.sh" \
  && ok 'python agent-list classifier knows the line' || bad 'python agent-list classifier knows the line'
# The python classifier, run for real on the rendered file.
PYC=$(awk '/^def classify_sudo\(/{p=1} p&&/^sudo_sources = \[\]/{exit} p' "$SRC/cmd_agent.sh")
if [[ -n "$PYC" ]] && command -v python3 >/dev/null; then
  got=$(SUDTXT="$SUD" python3 -c "import os, re
$PYC
r = classify_sudo(os.environ['SUDTXT'], True)
print(r['grant'], r['impliedIsolation'], r['extraEntries'])")
  [[ "$got" == 'cli-scoped standard False' ]] \
    && ok 'python classifier: rendered grant is standard, no extra entries' \
    || bad "python classifier: rendered grant is standard, no extra entries (got $got)"
else
  bad 'python classifier extractable'
fi
# The comment block lives in an UNQUOTED heredoc: no backtick or dollar in it.
blk=$(awk '/DIVE-5495: let this seat ask/{p=1} p&&/browser _connect$/{exit} p{print}' "$SRC/cmd_agent_create.sh")
[[ -n "$blk" && "$blk" != *'`'* && "$blk" != *'$'* ]] \
  && ok 'heredoc comment carries no backtick or dollar' || bad 'heredoc comment carries no backtick or dollar'

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
