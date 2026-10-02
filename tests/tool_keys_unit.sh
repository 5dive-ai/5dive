#!/usr/bin/env bash
# DIVE-5366: `5dive tool set|rm|ls` — the keys the Mini App's Settings -> Tools
# pastes onto the box, and the BASH_ENV line that hands them to every agent.
#   * a saved key is an `export VAR='value'` line a fresh bash picks up through
#     BASH_ENV (the agent's next command), and a removed one is gone the same way
#   * a value that could break out of its quotes, or the wrong number of
#     fields, is refused and nothing is written
#   * the unit points BASH_ENV at the file the verb writes
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
[[ "$gh" == true && "$el" == false && "$n" == 8 ]] && ok_t "T2 ls: github connected, elevenlabs not, 8 tools" || bad_t "T2 ls" "$out"
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

# --- T8: the unit hands the file to every agent -----------------------------------
unit_env=$(grep -E '^Environment=BASH_ENV=' systemd/5dive-agent@.service | sed 's/^Environment=BASH_ENV=//')
[[ "$unit_env" == "/etc/5dive/connectors/tools.sh" ]] && ok_t "T8 5dive-agent@.service sets BASH_ENV to the tool key file" || bad_t "T8 unit" "got: $unit_env"
grep -qE '^EnvironmentFile=.*tools' systemd/5dive-agent@.service \
  && bad_t "T8 not an EnvironmentFile (read once at start)" || ok_t "T8 not an EnvironmentFile (read once at start)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
