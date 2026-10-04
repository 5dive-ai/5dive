#!/usr/bin/env bash
# DIVE-5366: `5dive tool set|rm|ls` — the keys the Mini App's Settings -> Tools
# pastes onto the box, and the BASH_ENV line that hands them to every agent.
#   * a saved key is an `export VAR='value'` line a fresh bash picks up through
#     BASH_ENV (the agent's next command), and a removed one is gone the same way
#   * a value that could break out of its quotes, or the wrong number of
#     fields, is refused and nothing is written
#   * the unit points BASH_ENV at a 644 shim that sources that file, and a seat
#     that cannot read it gets no key and no stderr (DIVE-5373)
# Isolation: src/ sourced into a throwaway connectors dir; no root, no network.
# Run: bash tests/tool_keys_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/tool-keys-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_tool.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
TOOLS_WRITE_LOCK="$TMP/lock"
require_root() { :; }
JSON_MODE=1
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
F="$TOOLS_ENV_FILE"
# `fail` exits, so every verb runs in a subshell.
run() { ( cmd_tool "$@" ) 2>&1; }
seen() { BASH_ENV="$F" /bin/bash -c "printf '%s' \"\${$1:-}\""; }

[[ "$F" == "$FIVEDIVE_CONNECTOR_DIR/tools.sh" ]] && ok_t "T0 the key file lives in the connectors dir" || bad_t "T0 key file path" "$F"

# --- T1: set -> one export line, 640, and a fresh bash sees it -----------------
out=$(printf 'ghp_FAKE1234567890\n' | run set github); rc=$?
[[ $rc -eq 0 && "$out" == *'"connected":true'* ]] && ok_t "T1 set github answers connected" || bad_t "T1 set github" "rc=$rc $out"
[[ "$(grep -c "^export GH_TOKEN='ghp_FAKE1234567890'$" "$F")" == 1 ]] && ok_t "T1 file holds GH_TOKEN as one export line" || bad_t "T1 export line" "$(cat "$F")"
[[ "$(stat -c %a "$F")" == 640 ]] && ok_t "T1 file is 640" || bad_t "T1 mode" "$(stat -c %a "$F")"
[[ "$(seen GH_TOKEN)" == ghp_FAKE1234567890 ]] && ok_t "T1 a fresh bash with BASH_ENV sees GH_TOKEN" || bad_t "T1 BASH_ENV pickup" "$(seen GH_TOKEN)"

# --- T2: ls reports presence only ---------------------------------------------
out=$(run ls)
gh=$(jq -r '.data.tools[] | select(.id=="github") | .connected' <<<"$out")
el=$(jq -r '.data.tools[] | select(.id=="elevenlabs") | .connected' <<<"$out")
n=$(jq -r '.data.tools | length' <<<"$out")
[[ "$gh" == true && "$el" == false && "$n" == 20 ]] && ok_t "T2 ls: github connected, elevenlabs not, 20 tools" || bad_t "T2 ls" "$out"
[[ "$out" != *ghp_FAKE* ]] && ok_t "T2 ls never prints a key" || bad_t "T2 ls leaks" "$out"

# --- T3: replace is idempotent; another tool's line survives -------------------
printf 'ghp_SECOND12345678\n' | run set github >/dev/null
printf 'sk_el_FAKE_123456\n' | run set elevenlabs >/dev/null
[[ "$(grep -c '^export GH_TOKEN=' "$F")" == 1 && "$(seen GH_TOKEN)" == ghp_SECOND12345678 ]] \
  && ok_t "T3 a second save replaces, never duplicates" || bad_t "T3 replace" "$(cat "$F")"
[[ "$(seen ELEVENLABS_API_KEY)" == sk_el_FAKE_123456 ]] && ok_t "T3 elevenlabs saved beside github" || bad_t "T3 elevenlabs" "$(cat "$F")"

# --- T4: a value that could leave its quotes is refused, nothing written -------
before=$(cat "$F")
# The first has no space, so only the quote rule stands between it and a run.
for bad in "x';touch\${IFS}$TMP/pwned;'" "x'; touch $TMP/pwned; '" 'has space'; do
  out=$(printf '%s\n' "$bad" | run set fal); rc=$?
  [[ $rc -ne 0 && "$(cat "$F")" == "$before" ]] && ok_t "T4 refused: $bad" || bad_t "T4 must refuse: $bad" "rc=$rc"
done
seen FAL_KEY >/dev/null
[[ ! -e "$TMP/pwned" ]] && ok_t "T4 nothing executed on the next bash" || bad_t "T4 injection ran"

# --- T5: two-field tools take exactly two lines ---------------------------------
out=$(printf 'hfkey_only_one\n' | run set higgsfield); rc=$?
[[ $rc -ne 0 && "$out" == *"takes 2 value"* && "$(cat "$F")" == "$before" ]] && ok_t "T5 higgsfield with one line refused" || bad_t "T5 one line" "rc=$rc $out"
out=$(printf 'hf_key_FAKE01\nhf_secret_FAKE02\n' | run set higgsfield); rc=$?
[[ $rc -eq 0 && "$(seen HF_API_KEY)" == hf_key_FAKE01 && "$(seen HF_API_SECRET)" == hf_secret_FAKE02 ]] \
  && ok_t "T5 higgsfield key + secret saved" || bad_t "T5 two lines" "rc=$rc $out"
printf 'EAAB_FAKE_TOKEN1\nact_123456\n' | run set meta >/dev/null
[[ "$(seen ACCESS_TOKEN)" == EAAB_FAKE_TOKEN1 && "$(seen AD_ACCOUNT_ID)" == act_123456 ]] \
  && ok_t "T5 meta fills ACCESS_TOKEN + AD_ACCOUNT_ID (its CLI's names)" || bad_t "T5 meta" "$(cat "$F")"

# --- T6: rm forgets one tool, the next bash no longer has it --------------------
out=$(run rm github); rc=$?
[[ $rc -eq 0 && -z "$(seen GH_TOKEN)" && "$(seen ELEVENLABS_API_KEY)" == sk_el_FAKE_123456 ]] \
  && ok_t "T6 rm github: gone on the next command, elevenlabs kept" || bad_t "T6 rm" "rc=$rc $(cat "$F")"
out=$(run rm higgsfield)
[[ -z "$(seen HF_API_KEY)" && -z "$(seen HF_API_SECRET)" ]] && ok_t "T6 rm clears both higgsfield fields" || bad_t "T6 rm two" "$(cat "$F")"

# --- T7: unknown tool -------------------------------------------------------------
out=$(printf 'x1234567890\n' | run set dropbox); rc=$?
[[ $rc -ne 0 && "$out" == *"unknown tool"* ]] && ok_t "T7 unknown tool refused" || bad_t "T7 unknown" "rc=$rc $out"

# --- T8: the unit hands the keys to every agent, through the shim ------------------
# DIVE-5373: BASH_ENV is the 644 shim install.sh writes, never the key file itself,
# which a sandboxed seat cannot open (bash then prints "Permission denied").
unit_env=$(grep -E '^Environment=BASH_ENV=' systemd/5dive-agent@.service | sed 's/^Environment=BASH_ENV=//')
[[ "$unit_env" == "/usr/local/lib/5dive/tool-env.sh" ]] && ok_t "T8 5dive-agent@.service sets BASH_ENV to the tool-env shim" || bad_t "T8 unit" "got: $unit_env"
shim=$(sed -n "/<<'TOOLENV'$/,/^TOOLENV$/p" install.sh | sed '1d;$d')
[[ "$shim" == *"/etc/5dive/connectors/tools.sh"* ]] && ok_t "T8 install.sh writes a shim that sources the key file" || bad_t "T8 shim body" "$shim"
shim_ln=$(grep -n 'mv -f "$_te_tmp" "$LIB_DIR/tool-env.sh"' install.sh | head -1 | cut -d: -f1)
unit_ln=$(grep -n 'systemd/5dive-agent%40.service" -o' install.sh | head -1 | cut -d: -f1)
[[ -n "$shim_ln" && -n "$unit_ln" ]] && (( shim_ln < unit_ln )) \
  && ok_t "T8 the shim is installed before the unit that points at it" || bad_t "T8 order" "shim@$shim_ln unit@$unit_ln"
grep -qE '^  chmod 644 "\$_te_tmp"$' install.sh && ok_t "T8 the shim is 644" || bad_t "T8 shim mode"
grep -qE '^EnvironmentFile=.*tools' systemd/5dive-agent@.service \
  && bad_t "T8 not an EnvironmentFile (read once at start)" || ok_t "T8 not an EnvironmentFile (read once at start)"

# --- T9: the shipped shim, run as a seat that cannot read the keys ---------------
# The shim from install.sh, re-pointed at this run's key file. "Outsider" is a
# seat outside group claude: as root, a real other uid (root reads anything);
# otherwise this uid against a mode-000 file / dir, which it cannot open either.
SH="$TMP/tool-env.sh"
printf '%s\n' "${shim//\/etc\/5dive\/connectors\/tools.sh/$F}" > "$SH"
[[ "$(cat "$SH")" == *"$F"* ]] && ok_t "T9 shim re-pointed at the test key file" || bad_t "T9 shim rewrite" "$(cat "$SH")"
outsider() {
  if (( EUID == 0 )); then
    chmod 755 "$TMP"; chmod 644 "$SH"
    setpriv --reuid=65534 --regid=65534 --clear-groups env BASH_ENV="$1" /bin/bash -c "$2"
  else
    env BASH_ENV="$1" /bin/bash -c "$2"
  fi
}
printf 'sk_el_FAKE_999999\n' | run set elevenlabs >/dev/null
v=$(BASH_ENV="$SH" /bin/bash -c 'printf %s "${ELEVENLABS_API_KEY:-}"' 2>"$TMP/err0")
[[ "$v" == sk_el_FAKE_999999 && ! -s "$TMP/err0" ]] && ok_t "T9 a seat that can read the keys gets them through the shim, no stderr" || bad_t "T9 reader" "v=$v err=$(cat "$TMP/err0")"
(( EUID == 0 )) || chmod 000 "$F"
# Positive control: the 0.68.0 shape (BASH_ENV = the key file) IS noisy for this seat.
outsider "$F" 'echo ok' >"$TMP/out1" 2>"$TMP/err1"
grep -q 'Permission denied' "$TMP/err1" && ok_t "T9 control: BASH_ENV at the unreadable key file prints Permission denied" || bad_t "T9 control (the arm cannot see the failure)" "$(cat "$TMP/err1")"
outsider "$SH" 'printf %s "${ELEVENLABS_API_KEY:-}"; echo ok' >"$TMP/out2" 2>"$TMP/err2"
[[ ! -s "$TMP/err2" && "$(cat "$TMP/out2")" == ok ]] && ok_t "T9 through the shim, the same seat gets no key and EMPTY stderr" || bad_t "T9 shim noise" "out=$(cat "$TMP/out2") err=$(cat "$TMP/err2")"
(( EUID == 0 )) || chmod 640 "$F"
# Missing file inside a directory the seat cannot traverse (the /etc/5dive case).
(( EUID == 0 )) || chmod 000 "$FIVEDIVE_CONNECTOR_DIR"
(( EUID == 0 )) && chmod 700 "$FIVEDIVE_CONNECTOR_DIR"
outsider "$SH" 'echo ok' >"$TMP/out3" 2>"$TMP/err3"
[[ ! -s "$TMP/err3" && "$(cat "$TMP/out3")" == ok ]] && ok_t "T9 untraversable keys dir: empty stderr, rc 0" || bad_t "T9 dir" "out=$(cat "$TMP/out3") err=$(cat "$TMP/err3")"
chmod 755 "$FIVEDIVE_CONNECTOR_DIR"

# --- T10: ls after the LAST key is removed, under the CLI's own errexit ----------
# The harness runs `set +e`, which hides a pipefail exit; the real CLI does not.
for t in elevenlabs meta; do run rm "$t" >/dev/null; done
[[ -e "$F" ]] && ! grep -q '^export ' "$F" && ok_t "T10 precondition: key file exists with no key line left" || bad_t "T10 precondition" "$(cat "$F" 2>&1)"
out=$( ( set -euo pipefail; cmd_tool ls ) 2>&1 ); rc=$?
gh=$(jq -r '.data.tools[] | select(.id=="github") | .connected' <<<"$out" 2>/dev/null)
n=$(jq -r '.data.tools | length' <<<"$out" 2>/dev/null)
[[ $rc -eq 0 && "$gh" == false && "$n" == 20 ]] && ok_t "T10 ls with every key removed: rc 0, 20 tools, none connected" || bad_t "T10 ls after last rm" "rc=$rc $out"

# --- T11: the business apps (DIVE-5513, OINOA) ---------------------------------
# The twelve ids, each with its vars in stdin order, after the first eight.
out=$(run ls)
want='bitrix24=BITRIX24_WEBHOOK_URL amocrm=AMOCRM_DOMAIN,AMOCRM_TOKEN moysklad=MOYSKLAD_TOKEN yandex-calendar=YANDEX_LOGIN,YANDEX_CALDAV_PASSWORD hubspot=HUBSPOT_TOKEN pipedrive=PIPEDRIVE_TOKEN notion=NOTION_TOKEN asana=ASANA_TOKEN calendly=CALENDLY_TOKEN lexoffice=LEXOFFICE_API_KEY sevdesk=SEVDESK_API_TOKEN holded=HOLDED_API_KEY'
got=$(jq -r '[.data.tools[8:][] | "\(.id)=\(.env | join(","))"] | join(" ")' <<<"$out")
[[ "$got" == "$want" ]] && ok_t "T11 ls lists the 12 business apps after the 8, vars in stdin order" || bad_t "T11 business ids" "got: $got"
url='https://acme.bitrix24.ru/rest/1/abc123def456/'
out=$(printf '%s\n' "$url" | run set bitrix24); rc=$?
[[ $rc -eq 0 && "$(grep -c "^export BITRIX24_WEBHOOK_URL='${url}'$" "$F")" == 1 && "$(seen BITRIX24_WEBHOOK_URL)" == "$url" ]] \
  && ok_t "T11 bitrix24: the webhook URL is one export line a fresh bash sees" || bad_t "T11 bitrix24" "rc=$rc $out $(cat "$F")"
c=$(run ls | jq -r '.data.tools[] | select(.id=="bitrix24") | .connected')
[[ "$c" == true ]] && ok_t "T11 ls: bitrix24 connected" || bad_t "T11 bitrix24 ls" "$c"
out=$(printf 'acme.amocrm.ru\nlongLivedFAKE.token-123\n' | run set amocrm); rc=$?
[[ $rc -eq 0 && "$(seen AMOCRM_DOMAIN)" == acme.amocrm.ru && "$(seen AMOCRM_TOKEN)" == longLivedFAKE.token-123 ]] \
  && ok_t "T11 amocrm: domain then token" || bad_t "T11 amocrm" "rc=$rc $out"
out=$(printf 'ivan@yandex.ru\nappPassFAKE16chr\n' | run set yandex-calendar); rc=$?
[[ $rc -eq 0 && "$(seen YANDEX_LOGIN)" == ivan@yandex.ru && "$(seen YANDEX_CALDAV_PASSWORD)" == appPassFAKE16chr ]] \
  && ok_t "T11 yandex-calendar (a hyphenated id): login then app password" || bad_t "T11 yandex-calendar" "rc=$rc $out"
out=$(printf 'only-one-line\n' | run set amocrm); rc=$?
[[ $rc -ne 0 && "$out" == *"takes 2 value"* ]] && ok_t "T11 amocrm with one line refused" || bad_t "T11 amocrm one line" "rc=$rc $out"
out=$(printf 'pdFAKEtoken0123456789\n' | run set pipedrive); rc=$?
[[ $rc -eq 0 && "$(seen PIPEDRIVE_TOKEN)" == pdFAKEtoken0123456789 && -z "$(seen PIPEDRIVE_DOMAIN)" ]] \
  && ok_t "T11 pipedrive: the token alone (no domain)" || bad_t "T11 pipedrive one value" "rc=$rc $out"
out=$(run rm bitrix24); rc=$?
[[ $rc -eq 0 && -z "$(seen BITRIX24_WEBHOOK_URL)" && "$(seen AMOCRM_TOKEN)" == longLivedFAKE.token-123 ]] \
  && ok_t "T11 rm bitrix24 drops its line, amocrm kept" || bad_t "T11 rm bitrix24" "rc=$rc $(cat "$F")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
