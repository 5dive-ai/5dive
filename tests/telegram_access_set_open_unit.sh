#!/usr/bin/env bash
# DIVE-8791: `agent telegram-access set` that lets a NEW id in also lifts
# Telegram's owner-only lock on a manager-made bot (the same POST as
# `_telegram_open <name>`), and says what happened: data.open_state. A set that
# lets nobody new in makes no call. A failed lift keeps the write, exits 0 and
# names the lock. Runs the verb under set -e, as the CLI does.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" || true
cd "$(dirname "$0")/.."
SRC=src; TMP=$(mktemp -d /tmp/tg-access-set-open.XXXXXX)
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

ensure_state() { :; }
registry_read() { printf '%s' '{"agents":{"kost":{"type":"claude","channels":"telegram"}}}'; }
STATE="$TMP/access"
_tg_access_state_dir() { printf '%s' "$STATE"; }
# The fixture agent is not a real user: run the write as the caller.
sudo() { [[ "$1" == -u ]] && shift 2; "$@"; }
export FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env" FIVE_API_BASE="https://api.test"
printf 'CONNECTORD_TOKEN=tok123\n' >"$FIVEDIVE_CONNECTORD_ENV"
ANSWER='{"open":true}'; HTTP=200
curl() {
  local cfg; cfg=$(cat)
  printf '%s %s\n' "${@: -1}" "$cfg" >>"$TMP/calls"
  printf '%s\n%s' "$ANSWER" "$HTTP"
}
# body <allowFrom ids...>
body() { local ids; ids=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'); printf '{"dmPolicy":"allowlist","allowFrom":%s,"groups":{}}' "$ids"; }
run() { local b="$1"; shift; : >"$TMP/calls"; ( set -e; cmd_telegram_access_set "$@" <<<"$b" ) >"$TMP/out" 2>"$TMP/err"; }
jrun() { local b="$1"; shift; : >"$TMP/calls"; ( set -e; JSON_MODE=1 cmd_telegram_access_set "$@" <<<"$b" ) >"$TMP/out" 2>"$TMP/err"; }
field() { jq -r ".data.$1" "$TMP/out" 2>/dev/null; }
calls() { grep -c . "$TMP/calls"; }
allow() { jq -c .allowFrom "$STATE/access.json"; }

# ── first person in: one open call, open_state=open ──
jrun "$(body 111)" kost
[[ $? == 0 && "$(field open_state)" == open && "$(field added)" == 1 && "$(calls)" == 1 ]] \
  && pass 'a set that adds an id calls open once; JSON open_state=open, added=1' \
  || nope "add one id (rc/out/calls: $(cat "$TMP/out") $(cat "$TMP/calls"))"
grep -qF 'https://api.test/server/telegram/agents/kost/open header = "authorization: Bearer tok123"' "$TMP/calls" \
  && pass 'the open POST names the agent and the key rides a curl config, not argv' || nope "open URL/key (calls: $(cat "$TMP/calls"))"
[[ "$(allow)" == '["111"]' ]] && pass 'access.json written' || nope "access.json: $(allow)"
run "$(body 111 222)" kost
[[ $? == 0 && "$(calls)" == 1 ]] && grep -q "its bot is open, so they can reach it now" "$TMP/out" \
  && pass 'prose: the OK line says the bot is open' || nope "prose open (out: $(cat "$TMP/out"))"

# ── negative controls: nobody new → zero calls ──
jrun "$(body 111 222)" kost
[[ $? == 0 && "$(calls)" == 0 && "$(field open_state)" == skipped && "$(field added)" == 0 ]] \
  && pass 'same list: zero open calls, open_state=skipped' || nope "same list (out: $(cat "$TMP/out") calls: $(calls))"
jrun "$(body 222)" kost
[[ $? == 0 && "$(calls)" == 0 && "$(allow)" == '["222"]' ]] \
  && pass 'ids only removed: zero open calls, removal written' || nope "removal (calls: $(calls), allow: $(allow))"
jrun "$(body 222 222)" kost
[[ $? == 0 && "$(calls)" == 0 ]] && pass 'a duplicate of an existing id is not a new id' || nope 'duplicate counted as new'
before=$(allow)
jrun '{"dmPolicy":"bogus","allowFrom":["999"],"groups":{}}' kost
[[ $? != 0 && "$(calls)" == 0 && "$(allow)" == "$before" ]] \
  && pass 'a refused body writes nothing and calls nothing' || nope "refused body (calls: $(calls), allow: $(allow))"

# ── a failed lift keeps the write, exits 0, and names the lock ──
ANSWER='{"error":"telegram_refused"}'; HTTP=502
jrun "$(body 222 333)" kost
rc=$?
[[ $rc == 0 && "$(field open_state)" == failed && "$(allow)" == '["222","333"]' && "$(calls)" == 1 ]] \
  && pass 'failed open: exit 0, access.json written, open_state=failed' || nope "failed open (rc=$rc out: $(cat "$TMP/out") allow: $(allow))"
grep -q 'Telegram still blocks everyone but the owner' "$TMP/err" && grep -q '5dive agent _telegram_open kost' "$TMP/err" \
  && grep -q telegram_refused "$TMP/err" \
  && pass 'failed open: output names the lock, the reason and the retry' || nope "failed open message (err: $(cat "$TMP/err"))"
ANSWER=''; HTTP=''
jrun "$(body 222 333 444)" kost
[[ $? == 0 && "$(field open_state)" == failed ]] && grep -q 'could not be reached' "$TMP/err" \
  && pass 'unreachable 5dive: still exit 0, open_state=failed' || nope "unreachable (out: $(cat "$TMP/out") err: $(cat "$TMP/err"))"

# ── not_managed and no_account ──
ANSWER='{"open":false,"reason":"not_managed"}'; HTTP=200
jrun "$(body 555)" kost
[[ $? == 0 && "$(field open_state)" == not_managed && "$(calls)" == 1 ]] \
  && pass 'a BotFather bot: open_state=not_managed' || nope "not_managed (out: $(cat "$TMP/out"))"
: >"$FIVEDIVE_CONNECTORD_ENV"
jrun "$(body 555 666)" kost
[[ $? == 0 && "$(field open_state)" == no_account && "$(calls)" == 0 ]] \
  && pass 'no 5dive account: no POST, open_state=no_account' || nope "no_account (out: $(cat "$TMP/out") calls: $(calls))"

printf '\n%d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
