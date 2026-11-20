#!/usr/bin/env bash
# DIVE-8853/DIVE-8872 isolated unit harness for `5dive team freedom [ask|balanced|yolo] [--agent=<n>]`:
# one owner level that sets every switch that asks the owner (browser asks,
# email gates, proactive, per-agent autonomy), reads back "custom" with what
# differs once a switch is changed by hand, and is taken by new agents. On YOLO
# nothing asks: every browser kind `always`, email gates off, autonomy=full.
# Every switch is driven through its own verb (_freedom_run), faked here over
# files, so the harness checks what the level ASKS each verb to do.
# Throwaway STATE_DIR — never touches the live tasks.db or registry.
# Run: bash tests/team_freedom_unit.sh (no root, no network).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/team-freedom-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh \
         lib/registry.sh lib/tasks_db.sh cmd_team_freedom.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
REGISTRY="$TMP/agents.json"; ENV_DIR="$TMP/agents.d"; JSON_MODE=1
export AGENT_HOME_ROOT="$TMP/home"
mkdir -p "$TASKS_DIR" "$ENV_DIR"
tasks_db_init >/dev/null 2>&1
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }

# The team: ann (claude, email connected), bob (codex), the helper (system seat)
# and sysadmin. Only ann and bob are the team.
jq -n '{agents:{ann:{type:"claude"}, bob:{type:"codex"}, "5dive-helper":{type:"claude", system:"helper"}, sysadmin:{type:"claude"}}}' >"$REGISTRY"
for a in ann bob 5dive-helper sysadmin; do printf 'AGENT_NAME=%s\n' "$a" >"$ENV_DIR/$a.env"; echo off >"$TMP/pro.$a"; done
mkdir -p "$AGENT_HOME_ROOT/agent-ann/.claude/channels/email"
EMAIL="$AGENT_HOME_ROOT/agent-ann/.claude/channels/email/config.json"
echo '{"address":"ann@example.com","mode":"imap","smtp":{}}' >"$EMAIL"
# The box default browser: paying asks, the rest go ahead (browser `standard`).
echo '{"pay":"ask","publish":"allow","send":"allow","delete":"allow","mode":"standard"}' >"$TMP/browser.json"

ROOT=1
_freedom_is_root() { [[ "$ROOT" == "1" ]]; }
: >"$TMP/calls"; BROWSER_SET_RC=0
_freedom_run() {
  printf '%s\n' "$*" >>"$TMP/calls"
  case "$1 $2 $3" in
    "browser approvals policy")
      [[ -r "$TMP/browser.json" ]] || return 1
      if [[ "${4:-}" == set ]]; then
        (( BROWSER_SET_RC == 0 )) || return "$BROWSER_SET_RC"
        local p; shift 4
        for p in "$@"; do jq --arg k "${p%%=*}" --arg v "${p#*=}" '.[$k]=$v' "$TMP/browser.json" >"$TMP/b2" && mv "$TMP/b2" "$TMP/browser.json"; done
        return 0
      fi
      cat "$TMP/browser.json" ;;
    "agent proactive "*)
      if [[ "${4:-}" == --json ]]; then jq -cn --arg l "$(cat "$TMP/pro.$3")" '{ok:true, data:{level:$l}}'
      else echo "$4" >"$TMP/pro.$3"; fi ;;
    "agent config "*)
      local v="${5#autonomy=}"
      { grep -v '^AGENT_AUTONOMY=' "$ENV_DIR/$3.env"; [[ "$v" == standard ]] || echo "AGENT_AUTONOMY=$v"; } >"$TMP/e2"; mv "$TMP/e2" "$ENV_DIR/$3.env" ;;
    "email gate "*)
      local key=approve_new; [[ "$4" == inbound ]] && key=approve_inbound
      jq --arg k "$key" --argjson on "$([[ "$5" == on ]] && echo true || echo false)" '.[$k]=$on' "$EMAIL" >"$TMP/m2" && mv "$TMP/m2" "$EMAIL" ;;
    *) return 99 ;;
  esac
}
F() { ( cmd_team_freedom "$@" ) 2>"$TMP/err"; }
st() { F --json | jq -c ".data | $1"; }
calls_since() { : >"$TMP/calls"; }
writes() { grep -cv -- '--json$' "$TMP/calls"; }

# T1 — never set: no level lit (the box default matches no level), nothing differs.
t "T1 unset: level null, label null, set_level null, differs []" 'null|null|null|[]' "$(st '"\(.level)|\(.label)|\(.set_level)|\(.differs)"' | tr -d '"')"
t "T1 levels named for the app" '["ask","balanced","yolo"]' "$(st .levels)"

# T2 — only the owner (root) sets it; an agent cannot widen its own team.
ROOT=0; F yolo >/dev/null; rc=$?; ROOT=1
t "T2 non-root set refused" "1" "$([[ $rc -ne 0 ]] && echo 1)"
t "T2 refusal names sudo" "1" "$(grep -c 'sudo 5dive team freedom yolo' "$TMP/err")"
t "T2 nothing saved" "null" "$(st .set_level)"

# T3 — YOLO: nothing asks. Every browser kind always, email gates off, autonomy
# full (claude only), proactive Very high; the helper and sysadmin untouched.
out=$(F yolo); t "T3 set yolo ok" "yolo|YOLO" "$(jq -r '.data | "\(.level)|\(.label)"' <<<"$out")"
t "T3 browser all four always" "always always always always" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T3 email: new senders go through, mails anyone" "false false" "$(jq -r '"\(.approve_inbound) \(.approve_new)"' "$EMAIL")"
t "T3 ann autonomy full" "AGENT_AUTONOMY=full" "$(grep AUTONOMY "$ENV_DIR/ann.env")"
t "T3 bob (codex) has no autonomy written" "0" "$(grep -c AUTONOMY "$ENV_DIR/bob.env")"
t "T3 proactive more for the team" "more more" "$(cat "$TMP/pro.ann") $(cat "$TMP/pro.bob")"
t "T3 helper and sysadmin untouched" "off off 0 0" "$(cat "$TMP/pro.5dive-helper") $(cat "$TMP/pro.sysadmin") $(grep -c AUTONOMY "$ENV_DIR/5dive-helper.env") $(grep -c AUTONOMY "$ENV_DIR/sysadmin.env")"
t "T3 status yolo, nothing differs" "yolo|yolo|[]" "$(st '"\(.level)|\(.set_level)|\(.differs)"' | tr -d '"')"
t "T3 browser set in ONE call" "1" "$(grep -c '^browser approvals policy set send=always publish=always pay=always delete=always$' "$TMP/calls")"

# T4 — a switch changed by hand makes it custom, and says which and how.
jq '.pay="ask"' "$TMP/browser.json" >"$TMP/b2" && mv "$TMP/b2" "$TMP/browser.json"
echo little >"$TMP/pro.bob"
t "T4 custom" "custom|yolo|Custom" "$(st '"\(.level)|\(.set_level)|\(.label)"' | tr -d '"')"
t "T4 differs names both" '[{"switch":"browser.pay","agent":null,"now":"ask","want":"always"},{"switch":"proactive","agent":"bob","now":"little","want":"more"}]' "$(st .differs)"

# T5 — setting a level again overwrites hand changes. Balanced: sends on its
# own, posting/paying/deleting ask, email gates on, today's yolo, High.
F balanced >/dev/null
t "T5 browser balanced" "ask ask allow ask" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T5 email gates back on" "true true" "$(jq -r '"\(.approve_inbound) \(.approve_new)"' "$EMAIL")"
t "T5 ann autonomy yolo (keeps hard gates)" "AGENT_AUTONOMY=yolo" "$(grep AUTONOMY "$ENV_DIR/ann.env")"
t "T5 proactive little" "little little" "$(cat "$TMP/pro.ann") $(cat "$TMP/pro.bob")"
t "T5 status balanced" "balanced" "$(st .level | tr -d '"')"

# T6 — idempotent: the same level again changes nothing (no restart, no audit noise).
calls_since; F balanced >/dev/null
t "T6 no write on a re-set" "0" "$(writes)"

# T7 — Ask me often: everything asks, autonomy standard (no line), Normal.
F ask >/dev/null
t "T7 browser all ask" "ask ask ask ask" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T7 ann autonomy standard" "0" "$(grep -c AUTONOMY "$ENV_DIR/ann.env")"
t "T7 proactive off" "off off" "$(cat "$TMP/pro.ann") $(cat "$TMP/pro.bob")"

# T8 — a switch that refuses: exit non-zero, the level is still saved, and the
# status shows it honestly as custom.
BROWSER_SET_RC=64; F yolo >/dev/null; rc=$?; BROWSER_SET_RC=0
t "T8 refusal exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1)"
t "T8 refusal names the browser" "1" "$(grep -m1 -c 'did not change: browser' "$TMP/err")"
t "T8 status custom with the browser kinds" "custom|4" "$(st '"\(.level)|\([.differs[]|select(.switch|startswith("browser"))]|length)"' | tr -d '"')"

# T9 — no browser plugin: the browser is not part of the team's switches.
F ask >/dev/null; mv "$TMP/browser.json" "$TMP/browser.off"
t "T9 no browser: still ask, nothing differs" "ask|[]" "$(st '"\(.level)|\(.differs)"' | tr -d '"')"
mv "$TMP/browser.off" "$TMP/browser.json"

# T10 — DIVE-8872: a new agent starts on Balanced once Team freedom has been
# used on this box (whatever the others are on); before that, today's defaults.
F yolo >/dev/null
t "T10 new claude agent autonomy: Balanced's" "yolo" "$(_freedom_new_agent_autonomy claude)"
t "T10 new codex agent: no autonomy" "" "$(_freedom_new_agent_autonomy codex)"
jq '.agents.cat={type:"claude"}' "$REGISTRY" >"$TMP/r2" && mv "$TMP/r2" "$REGISTRY"
printf 'AGENT_NAME=cat\nAGENT_AUTONOMY=yolo\n' >"$ENV_DIR/cat.env"; echo off >"$TMP/pro.cat"; _freedom_new_agent_inherit cat
t "T10 new agent proactive: Balanced's" "little" "$(cat "$TMP/pro.cat")"
t "T10 new agent stored on Balanced, matches it" "balanced|balanced|[]" "$(F --agent=cat --json | jq -r '.data | "\(.level)|\(.set_level)|\(.differs)"')"
t "T10 the shared browser follows the most careful agent (cat)" "ask ask allow ask" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T10 ann stays YOLO" "yolo" "$(F --agent=ann --json | jq -r .data.level)"
jq 'del(.agents.cat)' "$REGISTRY" >"$TMP/r2" && mv "$TMP/r2" "$REGISTRY"
db "DELETE FROM task_prefs WHERE key LIKE 'freedom.%';"
t "T10 never used: new agent keeps today's default" "" "$(_freedom_new_agent_autonomy claude)"
calls_since; _freedom_new_agent_inherit cat
t "T10 never used: nothing stored or written" "0|0" "$(writes)|$(db "SELECT count(*) FROM task_prefs WHERE key LIKE 'freedom.%';")"

# T11 — a bad level is a usage error, not a silent no-op.
F free >/dev/null; rc=$?
t "T11 unknown level refused" "1" "$([[ $rc -ne 0 ]] && echo 1)"

# T12 — the runtime and the CLI agree on the new mode: `full` is accepted, the
# launcher gives it a directive that drops hard gates, and `yolo` still keeps them.
t "T12 valid_autonomy accepts full" "1" "$(grep -c 'son-of-anton|full)\$' "$SRC/cmd_agent_create.sh")"
t "T12 launcher: full files no approval gates" "1" "$(grep -c 'Do not file approval gates' bin/5dive-agent-start)"
t "T12 launcher: yolo still honors hard gates" "1" "$(grep -c 'You MUST still get a human.s explicit go before crossing a HARD GATE' bin/5dive-agent-start)"
t "T12 helper seat opts out of the team level" "1" "$(grep -c -- '--autonomy=standard </dev/null' "$SRC/cmd_helper.sh")"

# T13 — the real CLI runs under errexit: a clean set (no switch refused) and a
# re-set (nothing to change) both exit 0 with the ok line, not a silent death.
E() { ( set -euo pipefail; cmd_team_freedom "$@" ) 2>"$TMP/err"; }
out=$(E yolo); rc=$?
t "T13 clean set under errexit: rc 0" "0" "$rc"
t "T13 clean set under errexit: ok line, changes named, none failed" "true|YOLO|1|0" "$(jq -r '"\(.ok)|\(.data.label)|\(.data.changed|length>0|if . then 1 else 0 end)|\(.data.failed|length)"' <<<"$out" 2>/dev/null)"
out=$(E yolo); rc=$?
t "T13 re-set under errexit: rc 0, nothing changed" "0|true|[]" "$rc|$(jq -r '.ok' <<<"$out" 2>/dev/null)|$(jq -c '.data.changed' <<<"$out" 2>/dev/null)"

# T14 — DIVE-8872: the level is PER AGENT. One agent's set touches only its own
# switches; the shared browser follows the most careful agent.
F ask >/dev/null
out=$(F yolo --agent=bob)
t "T14 set bob yolo ok, names bob" "yolo|bob|ask" "$(jq -r '.data | "\(.level)|\(.agent)|\(.browser_level)"' <<<"$out")"
t "T14 bob proactive more, ann untouched" "more off" "$(cat "$TMP/pro.bob") $(cat "$TMP/pro.ann")"
t "T14 ann email and autonomy untouched" "true true 0" "$(jq -r '"\(.approve_inbound) \(.approve_new)"' "$EMAIL") $(grep -c AUTONOMY "$ENV_DIR/ann.env")"
t "T14 browser stays on ann's Ask me often" "ask ask ask ask" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T14 the set line says the browser stays careful" "1" "$( (JSON_MODE=0; F yolo --agent=bob) | grep -c 'browser is shared by the whole box and stays on Ask me often')"
t "T14 per-agent status: bob yolo, nothing differs" "bob|yolo|yolo|[]" "$(F --agent=bob --json | jq -r '.data | "\(.agent)|\(.level)|\(.set_level)|\(.differs)"')"
t "T14 per-agent status: browser reported beside, at ask" "ask|[]" "$(F --agent=bob --json | jq -r '.data.browser | "\(.level)|\(.differs)"')"
t "T14 team status: two agents, mixed = custom" "custom|ann:ask,bob:yolo" "$(F --json | jq -r '.data | "\(.level)|\([.agents[] | "\(.agent):\(.level)"] | join(","))"')"
F yolo --agent=ann >/dev/null
t "T14 every agent on YOLO: browser always" "always always always always" "$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T14 team status yolo" "yolo|yolo" "$(st '"\(.level)|\(.set_level)"' | tr -d '"')"
F balanced --agent bob >/dev/null
t "T14 --agent <name> form; browser back to Balanced" "little|ask ask allow ask" "$(cat "$TMP/pro.bob")|$(jq -r '"\(.pay) \(.publish) \(.send) \(.delete)"' "$TMP/browser.json")"
t "T14 ann still yolo" "yolo" "$(F --agent=ann --json | jq -r .data.level)"

# T15 — per-agent Custom: a hand change makes only that agent custom.
jq '.approve_inbound=true' "$EMAIL" >"$TMP/m2" && mv "$TMP/m2" "$EMAIL"
t "T15 ann custom with the email gate" 'custom|[{"switch":"email.inbound","agent":"ann","now":"on","want":"off"}]' "$(F --agent=ann --json | jq -c '.data | "\(.level)|\(.differs)"' | jq -r .)"
t "T15 bob still balanced" "balanced" "$(F --agent=bob --json | jq -r .data.level)"

# T16 — refusals: not on the team, bad name, non-root.
F --agent=sysadmin --json >/dev/null; rc=$?
t "T16 sysadmin is not on the team (rc 4)" "4" "$rc"
F yolo --agent=nobody >/dev/null; rc=$?
t "T16 unknown agent refused (rc 4)" "4|1" "$rc|$(grep -c "'nobody' is not on the team" "$TMP/err")"
F yolo --agent='a;b' >/dev/null; rc=$?
t "T16 bad name is a usage error" "1" "$([[ $rc -ne 0 ]] && echo 1)"
ROOT=0; F yolo --agent=bob >/dev/null; ROOT=1
t "T16 non-root refusal names --agent" "1" "$(grep -c 'sudo 5dive team freedom yolo --agent=bob' "$TMP/err")"

# T17 — DIVE-8853's whole-team key is read as the level of an agent with none of
# its own; the set-everyone form replaces it with per-agent keys.
db "DELETE FROM task_prefs WHERE key LIKE 'freedom.%';"
db "INSERT INTO task_prefs (key, value, updated_at) VALUES ('freedom.team', '{\"level\":\"ask\",\"set_at\":\"x\",\"set_by\":\"root\"}', datetime('now'));"
t "T17 legacy team key read per agent" "ask|ask" "$(F --agent=ann --json | jq -r .data.set_level)|$(F --agent=bob --json | jq -r .data.set_level)"
F yolo >/dev/null
t "T17 set-everyone writes per-agent keys, drops the team key" "freedom.agent.ann,freedom.agent.bob" "$(db "SELECT group_concat(key) FROM (SELECT key FROM task_prefs WHERE key LIKE 'freedom.%' ORDER BY key);")"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
