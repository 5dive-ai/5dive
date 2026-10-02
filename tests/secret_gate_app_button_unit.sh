#!/usr/bin/env bash
# DIVE-5370: a standard seat's secret-gate alert carries a button that opens the
# Mini App on the gate's "Open secure link" card.
#   * the button is the link `telegram-app link` hands back for the seat's owner
#     (the first id in its allowlist), so it never opens a NEW account for a
#     Telegram id that is not the owner's (DIVE-5185)
#   * any answer but status=ready with a t.me ?startapp=link_ url means NO button
#   * notify adds it only when no drop link was minted, as its own row, and a
#     failed merge keeps the ✅ Provided keyboard
# Isolation: src/ sourced; `5dive` is a stub that records its argv and prints a
# canned answer; no network, no root.
# Run: bash tests/secret_gate_app_button_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/secret-app-button-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh task/notify.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e

# The stub answers with whatever $TMP/answer holds and logs its argv.
cat > "$TMP/5dive" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
cat "$TMP/answer"
EOF
chmod +x "$TMP/5dive"
five_self_bundle() { printf '%s' "$TMP/5dive"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
ACC="$TMP/access.json"
printf '{"allowFrom":["123456789","987654321"]}' > "$ACC"
answer() { printf '%s' "$1" > "$TMP/answer"; : > "$TMP/argv.log"; }
GOOD='https://t.me/FiveDiveBot?startapp=link_AbC-12_x'

# --- A1: ready + a t.me link -> one URL button --------------------------------
answer "{\"ok\":true,\"data\":{\"status\":\"ready\",\"url\":\"$GOOD\"}}"
b=$(_task_secret_gate_app_button "$ACC")
[[ "$(jq -r .url <<<"$b" 2>/dev/null)" == "$GOOD" && "$(jq -r .text <<<"$b")" == *"Open secure link"* ]] \
  && ok_t "A1 ready -> an 'Open secure link' URL button" || bad_t "A1 button" "$b"
[[ "$(cat "$TMP/argv.log")" == "--json telegram-app link --telegram-id=123456789" ]] \
  && ok_t "A1 asks for the seat's owner (first allowlist id)" || bad_t "A1 argv" "$(cat "$TMP/argv.log")"
jq -e 'has("callback_data") | not' <<<"$b" >/dev/null 2>&1 \
  && ok_t "A1 a url button, never a callback (no tna handler involved)" || bad_t "A1 shape" "$b"

# --- A2: every non-ready answer -> no button -----------------------------------
for st in web_account other_telegram partner_box off not_paired unavailable error; do
  answer "{\"ok\":true,\"data\":{\"status\":\"$st\",\"url\":\"$GOOD\"}}"
  b=$(_task_secret_gate_app_button "$ACC")
  [[ -z "$b" ]] && ok_t "A2 status=$st -> no button" || bad_t "A2 status=$st must not button" "$b"
done
answer 'not json at all'
[[ -z "$(_task_secret_gate_app_button "$ACC")" ]] && ok_t "A2 garbage answer -> no button" || bad_t "A2 garbage"

# --- A3: ready but not a t.me startapp=link_ url -> no button ------------------
for u in 'https://evil.example/x' 'https://t.me/FiveDiveBot?startapp' 'https://t.me/FiveDiveBot?startapp=link_a"b'; do
  answer "$(jq -nc --arg u "$u" '{ok:true,data:{status:"ready",url:$u}}')"
  b=$(_task_secret_gate_app_button "$ACC")
  [[ -z "$b" ]] && ok_t "A3 refused url: $u" || bad_t "A3 must refuse: $u" "$b"
done

# --- A4: no owner to ask -> no call, no button ---------------------------------
answer "{\"ok\":true,\"data\":{\"status\":\"ready\",\"url\":\"$GOOD\"}}"
printf '{"allowFrom":[]}' > "$TMP/empty.json"
b=$(_task_secret_gate_app_button "$TMP/empty.json")
[[ -z "$b" && ! -s "$TMP/argv.log" ]] && ok_t "A4 empty allowlist -> nothing asked, no button" || bad_t "A4 empty" "$b / $(cat "$TMP/argv.log")"
b=$(_task_secret_gate_app_button "$TMP/missing.json")
[[ -z "$b" && ! -s "$TMP/argv.log" ]] && ok_t "A4 no access file -> nothing asked, no button" || bad_t "A4 missing" "$b"

# --- A5: the notify site adds it only with no drop link, keeping ✅ Provided ----
site=$(awk '/DIVE-5370: no link minted here/{p=1} p{print} p&&/^      fi$/{exit}' src/task/notify.sh)
grep -qF 'if [[ -z "$_drop" && -n "$secret_key" && -n "$connector" ]]; then' <<<"$site" \
  && ok_t "A5 the button is added only when no drop link was minted" || bad_t "A5 guard" "$site"
grep -qF '.inline_keyboard += [[$b]]' <<<"$site" \
  && ok_t "A5 appended as its own row (✅ Provided stays)" || bad_t "A5 append" "$site"
# Run the merge lines against a Provided keyboard, and against a broken button.
merge() { # <reply_markup> <button>
  local reply_markup="$1" _appbtn="$2"
  local _base='{"inline_keyboard":[]}' _merged
  eval "$(grep -E '^\s+(\[\[ -n "\$reply_markup" \]\] && _base=|_merged=\$\(jq|\s+&& \[\[ -n "\$_merged" \]\])' <<<"$site")"
  printf '%s' "$reply_markup"
}
PROV='{"inline_keyboard":[[{"text":"✅ Provided","callback_data":"tna:7:provided"}]]}'
m=$(merge "$PROV" "$(jq -nc --arg u "$GOOD" '{text:"🔑 Open secure link",url:$u}')")
[[ "$(jq -r '.inline_keyboard[0][0].text' <<<"$m" 2>/dev/null)" == "✅ Provided" && "$(jq -r '.inline_keyboard[1][0].url' <<<"$m")" == "$GOOD" ]] \
  && ok_t "A5 merged: Provided row, then the app row" || bad_t "A5 merge" "$m"
m=$(merge "$PROV" 'not-json')
[[ "$m" == "$PROV" ]] && ok_t "A5 a failed merge keeps the Provided keyboard" || bad_t "A5 failed merge dropped it" "$m"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
