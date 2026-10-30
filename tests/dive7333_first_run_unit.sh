#!/usr/bin/env bash
# DIVE-7333: a newcomer's first screens, after `curl … | sudo bash` and
# `5dive init` (found by DIVE-7326's init QA on five fresh boxes):
#   A  `agent list` called a one-minute-old seat OVERDUE (never ran, but newborn)
#   B  create's self-check read access.json for openclaw/hermes and called a
#      paired seat DEAF; their allowlists live in openclaw.json / ~/.hermes/.env
#   C  the self-check called an openclaw seat that holds its own key a perms
#      fault, because a seat is not meant to read its account's store
#   D  `agent ask` named a refused turn ("Credit balance too low") a formatting
#      problem
#   E  `config set model=` had no openclaw/hermes arm: the pin rides the seat's
#      env file (AGENT_MODEL), and the model readers know both config files
#   F  the boot seed breadcrumbed that same healthy openclaw seat STALE
#   G  init offered Grok while it was off, installed it, ran the sign-in, and
#      only then had create refuse it; it now asks to turn Grok on first
# install.sh's last screen is tests/install_update_hint_unit.sh.
#
# Pure: no root, no systemd, no network. Run: bash tests/dive7333_first_run_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/seat_refusal.sh \
         cmd_auth.sh cmd_agent_create.sh cmd_agent.sh cmd_agent_runtime.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "output containing '$3'" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "output WITHOUT '$3'" "$2"; }

TMP=$(mktemp -d)
export AGENT_HOME_ROOT="$TMP/home"

echo "== A: a seat made a minute ago is not OVERDUE =="
NOW=$(date -u -d 2026-10-30T14:31:55Z +%s)
row() { # <name> <createdAt-json>
  jq -nc --arg n "$1" --argjson c "$2" '[{
    name: $n, type: "openclaw", channels: "telegram", authProfile: null, createdAt: $c,
    heartbeat: {enabled: true, everyMin: 30}, operationalState: "ready", enabled: "enabled",
    sudo: {measured: true, grant: "none", diverges: false, extraEntries: false},
    health: {auth: {state: "ok"}}}]'
}
badge() { awk -v n="$1" '$1 == n {print $2}' <<<"$2"; }
OUT=$(_agent_list_table "$(row fresh '"2026-10-30T14:30:55+00:00"')" "$NOW")
is    'a never-run seat created 60s ago has no overdue flag' "$(badge fresh "$OUT")" '∿never/30m'
hasnt 'and no OVERDUE paragraph under the table'             "$OUT" 'OVERDUE'
OUT=$(_agent_list_table "$(row tz '"2026-10-30T16:30:55+02:00"')" "$NOW")
is    'the UTC offset of createdAt is honoured (+02:00 is the same minute)' "$(badge tz "$OUT")" '∿never/30m'
OUT=$(_agent_list_table "$(row old '"2026-10-30T12:00:00+00:00"')" "$NOW")
is    'a never-run seat 2.5h old still flags'                "$(badge old "$OUT")" '∿never/30m!'
has   'and is named in the OVERDUE line'                     "$OUT" 'OVERDUE'
OUT=$(_agent_list_table "$(row nostamp 'null')" "$NOW")
is    'no createdAt keeps the alarm (absence never clears it)' "$(badge nostamp "$OUT")" '∿never/30m!'
J=$(_agent_list_hb_json "$(row fresh '"2026-10-30T14:30:55+00:00"')" "$NOW" | jq -c '.[0].heartbeatStatus.overdue')
is    '--json agrees: overdue false for the newborn'         "$J" 'false'

echo "== B: the self-check reads each type's own allowlist =="
H="$AGENT_HOME_ROOT/agent-oc"
mkdir -p "$H/.openclaw" "$AGENT_HOME_ROOT/agent-he/.hermes" "$AGENT_HOME_ROOT/agent-cl/.claude/channels/telegram"
printf '{"channels":{"telegram":{"allowFrom":["1234567890"]}},"agents":{"defaults":{"model":{"primary":"anthropic/claude-sonnet-5-5"}}}}\n' > "$H/.openclaw/openclaw.json"
is 'openclaw: allowFrom in openclaw.json counts'         "$(selfcheck_allow_count openclaw oc telegram)" 1
is 'openclaw: a channel with no allowFrom is 0'          "$(selfcheck_allow_count openclaw oc discord)" 0
printf 'TELEGRAM_BOT_TOKEN=x\nTELEGRAM_ALLOWED_USERS=1234567890,1234567891\n' > "$AGENT_HOME_ROOT/agent-he/.hermes/.env"
is 'hermes: TELEGRAM_ALLOWED_USERS counts'               "$(selfcheck_allow_count hermes he telegram)" 2
printf '{"allowFrom":[]}\n' > "$AGENT_HOME_ROOT/agent-cl/.claude/channels/telegram/access.json"
is 'claude: an empty access.json is still 0 (deaf)'      "$(selfcheck_allow_count claude cl telegram)" 0
is 'a missing store is 0, never an error'                "$(selfcheck_allow_count openclaw nobody telegram)" 0
blk=$(sed -n '/reachability: channel allowlist/,/^  done/p' "$SRC/cmd_agent_create.sh")
has 'create'"'"'s deaf check calls the helper'             "$blk" 'selfcheck_allow_count "$type" "$name" "$_ch"'

echo "== C: an openclaw seat holding its own key passes the credential check =="
mkdir -p "$H/.openclaw/agents/main/agent"
printf 'key' > "$H/.openclaw/agents/main/agent/openclaw-agent.sqlite"
out=$(selfcheck_cred_reached_agent oc openclaw "" "")
has   'witness 1 says the seat has its own credential' "$out" 'ok:openclaw seat has its own credential'
hasnt 'and nothing is reported about the account store' "$out" 'issue:'

echo "== D: agent ask names a refused turn as one =="
P="$TMP/pane"
printf '> [5dive id=abc123] hello, who are you?\n  ⎿ Credit balance too low · Add funds: https://console.example.invalid\n' > "$P"
d=$(_ask_timeout_diag abc123 "$P" 0 0)
has   'a credit refusal in the pane is named'            "$d" 'REFUSED the turn (Credit balance too low)'
hasnt 'and not as an ignored [reply-format]'            "$d" 'reply-format'
printf '> [5dive id=abc123] why does it say not logged in?\n' > "$P"
d=$(_ask_timeout_diag abc123 "$P" 0 0)
hasnt 'the question'"'"'s own words cannot trip it'      "$d" 'REFUSED'
has   'that pane keeps the old delivered-no-fence verdict' "$d" 'reply-format'
seat_account_refusal() { printf 'billing_error: Credit balance is too low\n'; }
seat_started_epoch() { printf '0\n'; }
d=$(_ask_timeout_diag abc123 "$P" 0 0 oc)
has   'the seat transcript reading is used when a name is given' "$d" 'REFUSED the turn (billing_error'
has   'and the hint names the seat'                       "$d" 'auth status --agent=oc'
has   'cmd_ask passes the seat name' "$(grep -F '_ask_timeout_diag "$msg_id"' "$SRC/cmd_agent_runtime.sh")" '"$ready_warned" "$name"'

echo "== E: a model pin for openclaw and hermes =="
is 'openclaw model is read from openclaw.json'           "$(resolve_agent_model openclaw oc)" 'anthropic/claude-sonnet-5-5'
printf 'model:\n  default: claude-sonnet-5-5\n  provider: anthropic\nagent:\n  default: other\n' > "$AGENT_HOME_ROOT/agent-he/.hermes/config.yaml"
is 'hermes model is model.default in config.yaml'        "$(resolve_agent_model hermes he)" 'claude-sonnet-5-5'
export ENV_DIR="$TMP/agents.d"; mkdir -p "$ENV_DIR"
_MODEL_OVERRIDE=anthropic/claude-haiku-5-5 write_agent_env oc openclaw telegram "" "" standard 2>/dev/null
has 'config set model= stamps AGENT_MODEL'              "$(cat "$ENV_DIR/oc.env")" 'AGENT_MODEL=anthropic/claude-haiku-5-5'
write_agent_env oc openclaw none "" "" standard 2>/dev/null
has 'an unrelated rewrite keeps AGENT_MODEL'            "$(cat "$ENV_DIR/oc.env")" 'AGENT_MODEL=anthropic/claude-haiku-5-5'
cfg=$(sed -n '/^      model)$/,/^        ;;$/p' "$SRC/cmd_agent_config.sh")
has 'config set model= has an openclaw|hermes arm'      "$cfg" 'openclaw|hermes)'
start=$(cat bin/5dive-agent-start)
has 'the boot applies AGENT_MODEL to openclaw'          "$start" "'{agents: {defaults: {model: {primary: \$m}}}}'"
has 'the boot applies AGENT_MODEL to hermes'            "$start" 'config set model.default "$AGENT_MODEL"'

echo "== F: the boot does not breadcrumb a seat that holds its key =="
seed=$(sed -n '/if (( _OC_STATE_READ == 1 )); then/,/assert_cred_seeded openclaw/p' bin/5dive-agent-start)
has 'a seat-held key with an unreadable account db is cred_seed_ok' "$seed" '"$OPENCLAW_STATE_AUTH_PY" has "$LOCAL_OPENCLAW_STATE"'

echo "== G: init asks to turn Grok on before the install and sign-in =="
# shellcheck source=/dev/null
source "$SRC/cmd_grok.sh"; source "$SRC/cmd_init.sh"; set +e
export FIVE_GROK_ARM_MARKER="$TMP/arm/grok-unfreeze"
ENABLED=0
cmd_grok_enable() { ENABLED=1; [[ "${ANSWER:-n}" == y ]] && { mkdir -p "$TMP/arm"; : >"$FIVE_GROK_ARM_MARKER"; }; return 0; }
ANSWER=n; _init_grok_on 2>/dev/null; is 'Grok off and the owner says no: init does not go on with Grok' "$?" 1
ANSWER=y; _init_grok_on 2>/dev/null; is 'the owner says yes: init goes on with Grok'                     "$?" 0
ENABLED=0; _init_grok_on 2>/dev/null; is 'already on: no second question'                                "$ENABLED/$?" 0/0
cmd_grok_enable() { fail "$E_PERMISSION" "only the server owner can turn Grok on"; }
rm -f "$FIVE_GROK_ARM_MARKER"
( _init_grok_on 2>/dev/null; echo "rc=$?" ) >"$TMP/g.out"
is 'a refused enable returns to the wizard instead of ending it' "$(tail -1 "$TMP/g.out")" 'rc=1'
BODY=$(declare -f cmd_init)
pre=${BODY%%cmd_install \"\$type\"*}; pre=${pre%%auth login*}
[[ "$pre" == *_init_grok_on* ]]; is 'the Grok question comes before the install and the sign-in' "$?" 0

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
