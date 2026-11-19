#!/usr/bin/env bash
# DIVE-8819 isolated unit harness for the 5dive helper seat (src/cmd_helper.sh):
#   1. outside the agent count: the seat is marked system=helper, `agent list
#      --json` carries that field from both builders, and the hire count skips it;
#   2. the greeting goes out ONCE: a second tick, a seat restart and a failed
#      send that is retried never produce a second message;
#   3. the handover read: 200 skips the question and names the business, 404
#      asks it, any other answer retries and asks only after the tries run out;
#   4. which boxes: no demo AI = nothing; an owner's own agent named `helper` is
#      left alone; a seat the owner removed is not built again; a build that keeps
#      failing stops after its tries;
#   5-8. the persona; the greeted claim against a racing tick; a build that stops
#      after create is marked and resumed, never a hire; --help exits 0.
# Throwaway STATE_DIR and fake 5dive / systemd-run / curl on PATH: no root, no
# network, nothing on the live box is touched.
# Run: bash tests/helper_seat_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP="$(mktemp -d /tmp/helper-seat-unit.XXXXXX)"
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/registry.sh cmd_helper.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
PASS=0; FAIL=0
t() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL - %s\n   want: %s\n   got:  %s\n' "$1" "$2" "$3"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then t "$1" yes yes; else t "$1" "contains [$2]" "$3"; fi; }
hasnt() { if grep -qiF -- "$2" <<<"$3"; then t "$1" "no [$2]" "$3"; else t "$1" yes yes; fi; }

# --- fakes -------------------------------------------------------------------
FAKE="$TMP/bin"; mkdir -p "$FAKE"
CALLS="$TMP/calls.log"; : >"$CALLS"
cat >"$FAKE/5dive" <<'EOF'
#!/usr/bin/env bash
printf '5dive %s\n' "$*" >>"$CALLS"
[[ "$1 $2" == "agent _deliver" && -n "${FAKE_DELIVER_FAIL:-}" ]] && exit 1
exit 0
EOF
cat >"$FAKE/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$CALLS"
EOF
# curl: answers FAKE_HTTP with FAKE_BODY written to the -o file.
cat >"$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
cat >/dev/null   # the bearer header on stdin
for a in "$@"; do [[ "$a" == http* ]] && printf 'curl %s\n' "$a" >>"$CALLS"; done
[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" >"$out"
printf '%s' "${FAKE_HTTP:-000}"
EOF
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" CALLS
export FIVEDIVE_SELF_BIN="$FAKE/5dive" CONNECTORD_TOKEN="box-token-fixture"
_partner_box_token() { printf '%s' "$CONNECTORD_TOKEN"; }
_partner_api_base() { printf 'https://api.example.test'; }
RUNNING=1
_helper_running() { (( RUNNING )); }

fresh() {   # a new box: state dir, registry, optional demo AI account
  STATE_DIR="$TMP/box$1"; HELPER_STATE_DIR="$STATE_DIR"
  AUTH_PROFILES_DIR="$STATE_DIR/auth-profiles"; REGISTRY="$STATE_DIR/registry.json"
  mkdir -p "$STATE_DIR"
  if [[ "${2:-demo}" == demo ]]; then
    mkdir -p "$AUTH_PROFILES_DIR/demo-ai"
    printf 'ANTHROPIC_AUTH_TOKEN=sk-or-v1-fixture\n' >"$AUTH_PROFILES_DIR/demo-ai/combined.env"
  fi
  : >"$CALLS"
}
reg_with() { printf '{"agents":%s}' "$1"; }
built() { mkdir -p "$STATE_DIR/helper"; date >"$STATE_DIR/helper/built"; }
HELPER_ROW='"helper":{"type":"claude","system":"helper"}'
HIRE_ROW='"theo":{"type":"claude"}'
n_calls() { grep -c -- "$1" "$CALLS"; }

echo '== 1. outside the agent count =='
t 'the helper seat reads as mine' mine "$(_helper_seat "$(reg_with "{$HELPER_ROW}")")"
t "an owner's own agent named helper is taken" taken "$(_helper_seat "$(reg_with '{"helper":{"type":"claude"}}')")"
t 'no seat yet' none "$(_helper_seat "$(reg_with "{$HIRE_ROW}")")"
t 'hires skip the helper seat' 1 "$(_helper_hires "$(reg_with "{$HELPER_ROW,$HIRE_ROW}")")"
t 'hires skip the partner sysadmin seat' 0 "$(_helper_hires "$(reg_with '{"sysadmin":{"type":"claude"}}')")"
t 'a box with only the helper has no hires' 0 "$(_helper_hires "$(reg_with "{$HELPER_ROW}")")"
# Both `agent list --json` builders carry the marker the API and app filter on.
t 'the jq list builder reports system' 1 "$(grep -c 'system: (.value.system // null),' src/cmd_agent.sh)"
t 'the snapshot list builder reports system' 1 "$(grep -c '"system": value.get("system"),' src/cmd_agent.sh)"
# The team export (cloud copy's source) leaves the box's system seats out.
t 'the team export skips system seats' 1 "$(grep -c "select((.value.system // \"\") == \"\") | .key' <<<\"\$reg\"" src/cmd_compose.sh)"
# _helper_mark writes the marker the seat test reads.
fresh 1; reg_with "{$HELPER_ROW}" | jq '.agents.helper |= del(.system)' >"$REGISTRY"
registry_write() { cat >"$REGISTRY"; }   # the real one chowns to root:claude
IN_REGISTRY_LOCK=1 _helper_mark
t 'mark sets system=helper' helper "$(jq -r '.agents.helper.system' "$REGISTRY")"
t 'mark names it 5dive' '5dive|Help & setup' "$(jq -r '.agents.helper | "\(.displayName)|\(.role)"' "$REGISTRY")"

echo '== 2. which boxes =='
fresh 2 none
t 'no demo AI: the tick does nothing' '' "$(_helper_tick "$(reg_with '{}')")"
t 'no demo AI: nothing built' 0 "$(n_calls systemd-run)"
fresh 3
out=$(_helper_tick "$(reg_with '{}')")
has 'a demo AI box with no seat starts the build' 'building the helper seat' "$out"
has 'the build is the fixed transient unit' "--unit=5dive-helper-ensure" "$(cat "$CALLS")"
fresh 4; mkdir -p "$STATE_DIR/helper"; date >"$STATE_DIR/helper/built"
_helper_tick "$(reg_with "{$HIRE_ROW}")" >/dev/null
t 'a seat the owner removed is not built again' 0 "$(n_calls systemd-run)"
fresh 5
_helper_tick "$(reg_with '{"helper":{"type":"claude"},'"$HIRE_ROW"'}')" >/dev/null
t "an owner's own helper agent is left alone" 0 "$(n_calls '5dive\|systemd-run\|curl')"
fresh 6; mkdir -p "$STATE_DIR/helper"; echo 6 >"$STATE_DIR/helper/build-tries"
_helper_tick "$(reg_with '{}')" >/dev/null
t 'a build that failed its tries stops' 0 "$(n_calls systemd-run)"

echo '== 3. the greeting waits for an owner, then goes out once =='
fresh 7; built; FAKE_HTTP=404
_helper_tick "$(reg_with "{$HELPER_ROW}")" >/dev/null
t 'no hire yet (an unclaimed spare): no greeting' 0 "$(n_calls '_deliver')"
RUNNING=0; _helper_tick "$(reg_with "{$HELPER_ROW,$HIRE_ROW}")" >/dev/null; RUNNING=1
t 'seat not running: no greeting' 0 "$(n_calls '_deliver')"
REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_HTTP=404 FAKE_BODY='{"error":"none"}' _helper_tick "$REG" >/dev/null
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'two ticks: one greeting' 1 "$(n_calls 'agent _deliver --system-notice helper')"
# A seat restart changes nothing on disk the greeting reads; the box restart
# (STATE_DIR persists) neither.
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'after a restart: still one greeting' 1 "$(n_calls '_deliver')"
t 'greeted is recorded' yes "$([[ -s "$STATE_DIR/helper/greeted" ]] && echo yes)"
t 'once greeted, the tick reads nothing' 0 "$(n_calls curl | awk '{print ($1>2)?1:0}')"
fresh 8; built; REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_DELIVER_FAIL=1 FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'a failed send leaves no greeted mark' no "$([[ -e "$STATE_DIR/helper/greeted" ]] && echo yes || echo no)"
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
t 'the retry sends it, once' 2 "$(n_calls '_deliver')"
t 'greeted after the retry' yes "$([[ -e "$STATE_DIR/helper/greeted" ]] && echo yes)"

echo '== 4. the handover read =='
fresh 9; built; REG="$(reg_with "{$HELPER_ROW,$HIRE_ROW}")"
FAKE_HTTP=200 FAKE_BODY='{"business":"a bakery\nin Lyon","suggested":["theo","dude","x y"],"asked_at":"2026-11-19T10:00:00Z"}' \
  _helper_tick "$REG" >/dev/null
msg=$(sed -n '/_deliver/,$p' "$CALLS")
has 'reads GET /helper/handover' 'https://api.example.test/helper/handover' "$(cat "$CALLS")"
has '200: names the business' '"a bakery in Lyon"' "$msg"
has '200: says not to ask again' 'Do not ask about it again' "$msg"
has '200: passes at most two clean suggestions' '5dive suggested: theo, dude)' "$msg"
hasnt '200: does not ask the question' 'what does your business do' "$msg"
fresh 10; built; FAKE_HTTP=404 _helper_tick "$REG" >/dev/null
msg=$(sed -n '/_deliver/,$p' "$CALLS")
has '404: asks the one question' 'what does your business do?' "$msg"
fresh 11; built; HELPER_HANDOVER_TRIES=3
for i in 1 2; do FAKE_HTTP=503 _helper_tick "$REG" >/dev/null; done
t 'API down: no greeting while tries remain' 0 "$(n_calls '_deliver')"
FAKE_HTTP=503 _helper_tick "$REG" >/dev/null
t 'API down past the tries: one greeting' 1 "$(n_calls '_deliver')"
has 'API down past the tries: it asks' 'what does your business do?' "$(sed -n '/_deliver/,$p' "$CALLS")"
HELPER_HANDOVER_TRIES=12

echo '== 5. what the seat is =='
p=$(_helper_persona)
has 'never takes a job' 'Never take a job, never claim one, and never say "On it"' "$p"
has 'never builds or edits agents' 'Never build, edit, restart or remove agents' "$p"
has 'how-to in two lines' 'in at most two short lines' "$p"
has 'Telegram is the plane icon' 'plane icon' "$p"
for g in "$(_helper_greeting '' '')" "$(_helper_greeting 'a bakery' 'theo')"; do
  hasnt 'no greeting says On it' 'on it' "$g"
  hasnt 'no greeting says it messaged first' 'messaged you first' "$g"
done
# The seat is built standard (no sudo: it cannot run agent create) on demo-ai,
# by root with no SUDO_UID, which the DIVE-6843 refusal lets through.
has 'built as a standard seat on the demo AI' '--auth-profile="$HELPER_ACCOUNT" \' "$(grep -A1 'agent create "$HELPER_AGENT"' src/cmd_helper.sh)"
has 'standard isolation' '--isolation=standard' "$(grep -A1 'agent create "$HELPER_AGENT"' src/cmd_helper.sh)"

echo '== 6. the greeted claim holds against a second sender =='
# A tick that read the handover, then lost the race: another tick already wrote
# greeted. noclobber makes the claim fail, so this one sends nothing.
fresh 12; built; mkdir -p "$STATE_DIR/helper"; echo 'claimed by the other tick' >"$STATE_DIR/helper/greeted"
FAKE_HTTP=404 _helper_greet >/dev/null
t 'a claim already taken: no second send' 0 "$(n_calls '_deliver')"
t 'the other claim is left as it was' 'claimed by the other tick' "$(cat "$STATE_DIR/helper/greeted")"

echo '== 7. a build that stops half way is still not a hire =='
# agent create wrote the row, then the persona step failed.
fresh 13; reg_with '{"helper":{"type":"claude"}}' >"$REGISTRY"
registry_read() { cat "$REGISTRY"; }
persona_install_doc() { printf 'persona %s\n' "$1" >>"$CALLS"; return "${FAKE_PERSONA_RC:-0}"; }
IN_REGISTRY_LOCK=1 FAKE_PERSONA_RC=1 _helper_build none 2>/dev/null; rc=$?
t 'the half build reports failure' 1 "$rc"
t 'it is marked system=helper anyway' helper "$(jq -r '.agents.helper.system' "$REGISTRY")"
t 'so it reads mine, not taken' mine "$(_helper_seat "$(cat "$REGISTRY")")"
t 'and it is not a hire' 0 "$(_helper_hires "$(cat "$REGISTRY")")"
t 'not built yet' no "$([[ -e "$STATE_DIR/helper/built" ]] && echo yes || echo no)"
: >"$CALLS"
out=$(_helper_tick "$(cat "$REGISTRY")")
has 'the next tick resumes the build' 'building the helper seat' "$out"
t 'and does not greet a seat with no persona' 0 "$(n_calls '_deliver')"
: >"$CALLS"
IN_REGISTRY_LOCK=1 _helper_build mine 2>/dev/null; rc=$?
t 'finishing a marked seat succeeds' 0 "$rc"
t 'finishing does not create the seat again' 0 "$(n_calls 'agent create')"
t 'finishing installs the persona' 1 "$(n_calls 'persona helper')"
t 'then it is built' yes "$([[ -e "$STATE_DIR/helper/built" ]] && echo yes)"
fresh 14; reg_with '{}' >"$REGISTRY"
IN_REGISTRY_LOCK=1 _helper_build none 2>/dev/null
t 'a new build creates the seat' 1 "$(n_calls 'agent create helper')"
unset -f registry_read persona_install_doc

echo '== 8. --help =='
for h in --help -h help; do
  out=$(cmd_helper "$h" 2>&1); rc=$?
  t "helper $h exits 0" 0 "$rc"
  has "helper $h prints the usage line" 'usage: 5dive helper ensure|status' "$out"
done
t 'the usage line is what _verb_own_usage reads' 'usage: 5dive helper ensure|status [--json]' \
  "$(_verb_own_usage cmd_helper '5dive helper ensure|status')"
t 'helper is a builtin verb (plugins cannot claim it)' 1 \
  "$(grep '^readonly FIVEDIVE_BUILTIN_VERBS=' src/cmd_plugin.sh | grep -c ' helper ')"

echo "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
