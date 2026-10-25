#!/usr/bin/env bash
# DIVE-6930: `5dive agent _telegram_open` lifts Telegram's owner-only lock on the
# caller's OWN bot, after its owner taps Allow in the telegram plugin. A standard
# seat holds one exact-path, no-args line for it; the agent comes from SUDO_UID.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/telegram-open.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
export STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
  lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh cmd_agent_create.sh cmd_telegram_app.sh cmd_agent_pairing.sh; do
  source "$SRC/$f"
done
set +e
P=0; F=0
pass(){ P=$((P+1)); printf 'ok   %s\n' "$1"; }
nope(){ F=$((F+1)); printf 'FAIL %s\n' "$1" >&2; }

# ── the grant ──
for caps in '0 0' '1 1'; do
  # shellcheck disable=SC2086
  SUD=$(render_standard_sudoers agent-kost $caps)
  [[ $(grep -cE '^agent-kost ALL=\(root\) NOPASSWD: /usr/local/bin/5dive agent _telegram_open$' <<<"$SUD") == 1 ]] \
    && pass "_telegram_open line rendered once, exact, no args (caps $caps)" \
    || nope "_telegram_open line rendered once, exact, no args (caps $caps)"
  [[ "$(classify_sudo_grant <<<"$SUD")" == 'cli-scoped|root|0' ]] \
    && pass "rendered grant classifies cli-scoped, extra=0 (caps $caps)" \
    || nope "rendered grant classifies cli-scoped, extra=0 (caps $caps) (got $(classify_sudo_grant <<<"$SUD"))"
done
[[ "$(printf 'agent-kost ALL=(root) NOPASSWD: /usr/local/bin/5dive agent _telegram_open *\n' | classify_sudo_grant)" == 'custom|root|0' ]] \
  && pass 'a wildcarded _telegram_open line is not recognised as scoped' \
  || nope 'a wildcarded _telegram_open line is not recognised as scoped'
PYC=$(awk '/^def classify_sudo\(/{p=1} p&&/^sudo_sources = \[\]/{exit} p' "$SRC/cmd_agent.sh")
if [[ -n "$PYC" ]] && command -v python3 >/dev/null; then
  got=$(SUDTXT="$(render_standard_sudoers agent-kost 0 0)" python3 -c "import os, re
$PYC
r = classify_sudo(os.environ['SUDTXT'], True)
print(r['grant'], r['impliedIsolation'], r['extraEntries'])")
  [[ "$got" == 'cli-scoped standard False' ]] \
    && pass 'python classifier: rendered grant is standard, no extra entries' \
    || nope "python classifier: rendered grant is standard, no extra entries (got $got)"
else
  nope 'python classifier extractable'
fi
blk=$(awk '/DIVE-6930: let this seat/{p=1} p&&/agent _telegram_open$/{exit} p{print}' "$SRC/cmd_agent_create.sh")
[[ -n "$blk" && "$blk" != *'`'* && "$blk" != *'$'* ]] \
  && pass 'heredoc comment carries no backtick or dollar' || nope 'heredoc comment carries no backtick or dollar'

# ── the verb, over a fake box: root seam, uid map, registry, identity, curl ──
ROOT=1
_gate_is_root() { (( ROOT )); }
actor_uid_to_name() { case "$1" in 1001) echo agent-kost ;; 1002) echo agent-mail ;; 1000) echo claude ;; *) echo "user$1" ;; esac; }
ensure_state() { :; }
registry_read() { printf '%s' '{"agents":{"kost":{"channels":"telegram"},"mail":{"channels":"email"},"claude":{"channels":"telegram"}}}'; }
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env" FIVE_API_BASE="https://api.test"
printf 'CONNECTORD_TOKEN=tok123\n' >"$FIVEDIVE_CONNECTORD_ENV"
ANSWER='{"open":true}'; HTTP=200
curl() {
  local cfg; cfg=$(cat)
  printf '%s %s\n' "${@: -1}" "$cfg" >>"$TMP/calls"
  printf '%s\n%s' "$ANSWER" "$HTTP"
}
run() { ( JSON_MODE=1 cmd_agent_telegram_open "$@" ) >"$TMP/out" 2>&1; }
state() { jq -r '.data.state // .error.code // empty' "$TMP/out" 2>/dev/null; }

: >"$TMP/calls"; SUDO_UID=1001 run
[[ $? == 0 && "$(state)" == open ]] && pass 'a seat opens its bot: state open' || nope "a seat opens its bot (got $(cat "$TMP/out"))"
grep -qF 'https://api.test/server/telegram/agents/kost/open header = "authorization: Bearer tok123"' "$TMP/calls" \
  && pass 'the agent comes from SUDO_UID, and the box key rides a curl config, not argv' || nope "seat-derived URL and key (calls: $(cat "$TMP/calls"))"
: >"$TMP/calls"; SUDO_UID=1001 run mail
[[ $? != 0 && ! -s "$TMP/calls" ]] && pass 'a seat cannot name another agent' || nope 'a seat cannot name another agent'
: >"$TMP/calls"; SUDO_UID=1000 run
grep -qF '/agents/claude/open' "$TMP/calls" && pass 'the claude seat opens the claude agent' || nope 'the claude seat opens the claude agent'
: >"$TMP/calls"; SUDO_UID=1002 run
[[ $? != 0 && ! -s "$TMP/calls" ]] && pass 'an agent without telegram is refused before any call' || nope 'an agent without telegram is refused'
: >"$TMP/calls"; SUDO_UID=4242 run
[[ $? != 0 && ! -s "$TMP/calls" ]] && pass 'a uid that is no agent seat is refused' || nope 'a uid that is no agent seat is refused'
: >"$TMP/calls"; SUDO_UID= run kost
[[ $? == 0 ]] && grep -qF '/agents/kost/open' "$TMP/calls" && pass 'root names the agent' || nope 'root names the agent'
: >"$TMP/calls"; SUDO_UID= run 'Kost;rm'
[[ $? != 0 && ! -s "$TMP/calls" ]] && pass 'a malformed name is refused before any call' || nope 'a malformed name is refused'
ROOT=0; : >"$TMP/calls"; SUDO_UID=1001 run
[[ $? != 0 && ! -s "$TMP/calls" ]] && pass 'not root: refused, no call' || nope 'not root: refused'
ROOT=1
ANSWER='{"open":false,"reason":"not_managed"}'; SUDO_UID=1001 run
[[ $? == 0 && "$(state)" == not_managed ]] && pass 'no manager lock reads as success: not_managed' || nope "not_managed (got $(cat "$TMP/out"))"
ANSWER='{"error":"telegram_refused"}'; HTTP=502; SUDO_UID=1001 run
[[ $? != 0 ]] && grep -q 'telegram_refused' "$TMP/out" && pass 'a refusal fails and names why' || nope "refusal (got $(cat "$TMP/out"))"
ANSWER='{"weird":1}'; HTTP=200; SUDO_UID=1001 run
[[ $? != 0 ]] && pass 'a 200 that is neither open nor not_managed is not success' || nope 'a 200 without open is not success'
ANSWER='{"open":true}'; HTTP=200
: >"$FIVEDIVE_CONNECTORD_ENV"; : >"$TMP/calls"; SUDO_UID=1001 run
[[ $? == 0 && "$(state)" == no_account && ! -s "$TMP/calls" ]] && pass 'a box with no 5dive account: no_account, no call' || nope "no_account (got $(cat "$TMP/out"))"
grep -q '_telegram_open)' "$SRC/main.sh" && grep -q 'cmd_agent_telegram_open "\$@"' "$SRC/main.sh" \
  && pass 'main.sh dispatches agent _telegram_open' || nope 'main.sh dispatches agent _telegram_open'

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
