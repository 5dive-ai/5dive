#!/usr/bin/env bash
# DIVE-5185 unit: `5dive telegram-app link` — an existing customer's agent bot
# asks for a one-time my.5dive.ai link signed into the box owner's account.
#
# WHAT IS ASSERTED HERE (one arm each)
#   READY.    a paired id + a 200 with a t.me startapp=link_ URL -> status ready, the URL.
#   TOKEN.    the box token reaches curl on STDIN (a -K config line), never argv.
#   OFF.      `telegram-app=off` in box.json -> status off, and NOTHING is sent.
#   PAIRED.   an id outside the calling seat's allowFrom -> not_paired, nothing sent;
#             an id paired in another agent type's channel dir (.codex) is accepted.
#   IDENTITY. no connectord.env -> unavailable (self-hosted); an empty token too.
#   ROOT.     an env file that exists but is unreadable -> ok:false (the one answer
#             that makes the plugin's runner retry with sudo). Skipped as root.
#   ANSWERS.  403 partner_box / 409 account_has_other_telegram / 409 telegram_taken /
#             503 / no answer / a 200 whose URL is not a t.me startapp link -> each
#             maps to its own status, never to ready.
#   BAD.      a non-numeric or group (negative) id is refused before anything runs.
#   CONFIG.   `5dive config telegram-app=on|off|default` validates, stores and clears.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/telegram-app-unit.XXXXXX")"
trap 'rc=$?; chmod -R u+rw "$TMPD" 2>/dev/null; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

export STATE_DIR="$TMPD/state"; mkdir -p "$STATE_DIR"
export BOX_CONFIG="$TMPD/box.json"
export FIVEDIVE_CONNECTORD_ENV="$TMPD/connectord.env"
export FIVE_API_BASE="https://api.example.com"

# shellcheck disable=SC1090
for f in lib/error_codes.sh lib/output.sh lib/verify_policy.sh cmd_box_config.sh cmd_telegram_app.sh; do
  source "src/$f"
done
require_root() { return 0; }

ID=1234567890
HOME_MAYA="$TMPD/home/agent-maya"
mkdir -p "$HOME_MAYA/.claude/channels/telegram" "$HOME_MAYA/.codex/channels/telegram"
printf '{"dmPolicy":"allowlist","allowFrom":["%s"],"groups":{}}\n' "$ID" > "$HOME_MAYA/.claude/channels/telegram/access.json"
printf 'CONNECTORD_TOKEN=box-secret-token-fixture\n' > "$FIVEDIVE_CONNECTORD_ENV"

_tg_app_caller() { printf 'agent-maya'; }
_tg_app_home() { [[ "$1" == agent-maya ]] && printf '%s' "$HOME_MAYA"; }

# The API seam: RESP_CODE / RESP_BODY answer; every call is logged.
POSTS="$TMPD/posts"; : > "$POSTS"
RESP_CODE=200; RESP_BODY=''
curl() {
  printf 'ARGV:%s\n' "$*" >> "$POSTS"
  printf 'STDIN:%s\n' "$(cat)" >> "$POSTS"
  [[ "$RESP_CODE" == none ]] && return 7
  printf '%s\n%s' "$RESP_BODY" "$RESP_CODE"
}
GOOD_URL="https://t.me/FiveDiveBot?startapp=link_$(printf 'a%.0s' {1..43})"

run() { # -> $OUT (stdout), $RC
  OUT=$( JSON_MODE=0; cmd_telegram_app link "$@" --json 2>/dev/null ); RC=$?
}
field() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
posts() { grep -c '^ARGV:' "$POSTS"; }

# READY + TOKEN
RESP_CODE=200; RESP_BODY="{\"url\":\"$GOOD_URL\",\"expiresAt\":\"x\"}"; : > "$POSTS"
run --telegram-id=$ID
[[ "$(field .data.status)" == ready && "$(field .data.url)" == "$GOOD_URL" ]] \
  && ok_ "READY: paired id -> status ready with the link" || bad_ "READY" "$OUT"
grep -q '/server/telegram/link-code' "$POSTS" && grep -q "\"telegramId\":\"$ID\"" "$POSTS" \
  && ok_ "READY: posts the tapping id to /server/telegram/link-code" || bad_ "READY post" "$(cat "$POSTS")"
argv=$(grep '^ARGV:' "$POSTS"); stdin=$(grep '^STDIN:' "$POSTS")
if grep -q box-secret-token-fixture <<<"$argv"; then bad_ "TOKEN: token appeared in curl argv"
elif grep -q 'authorization: Bearer box-secret-token-fixture' <<<"$stdin"; then ok_ "TOKEN: box token goes to curl on stdin only"
else bad_ "TOKEN: token not on stdin" "$(cat "$POSTS")"; fi

# OFF
printf '{"telegram_app":"off"}\n' > "$BOX_CONFIG"; : > "$POSTS"
run --telegram-id=$ID
[[ "$(field .data.status)" == off && "$(posts)" == 0 ]] && ok_ "OFF: box opt-out -> status off, nothing sent" || bad_ "OFF" "$OUT"
rm -f "$BOX_CONFIG"

# PAIRED
: > "$POSTS"; run --telegram-id=55555
[[ "$(field .data.status)" == not_paired && "$(posts)" == 0 ]] && ok_ "PAIRED: id outside allowFrom -> not_paired, nothing sent" || bad_ "PAIRED" "$OUT"
printf '{"allowFrom":[55555]}\n' > "$HOME_MAYA/.codex/channels/telegram/access.json"
: > "$POSTS"; run --telegram-id=55555
[[ "$(field .data.status)" == ready ]] && ok_ "PAIRED: an id paired in the .codex channel dir (numeric) is accepted" || bad_ "PAIRED codex" "$OUT"
_tg_app_caller() { printf 'agent-other'; }
: > "$POSTS"; run --telegram-id=$ID
[[ "$(field .data.status)" == not_paired && "$(posts)" == 0 ]] && ok_ "PAIRED: another seat cannot ask for maya's paired id" || bad_ "PAIRED other seat" "$OUT"
_tg_app_caller() { printf 'agent-maya'; }

# IDENTITY
mv "$FIVEDIVE_CONNECTORD_ENV" "$TMPD/env.bak"; : > "$POSTS"
run --telegram-id=$ID
[[ "$(field .data.status)" == unavailable && "$(posts)" == 0 ]] && ok_ "IDENTITY: no connectord.env -> unavailable" || bad_ "IDENTITY none" "$OUT"
printf 'OTHER=1\n' > "$FIVEDIVE_CONNECTORD_ENV"; run --telegram-id=$ID
[[ "$(field .data.status)" == unavailable && "$(posts)" == 0 ]] && ok_ "IDENTITY: no CONNECTORD_TOKEN line -> unavailable" || bad_ "IDENTITY empty" "$OUT"
mv "$TMPD/env.bak" "$FIVEDIVE_CONNECTORD_ENV"

# ROOT
if (( EUID == 0 )); then printf 'skip ROOT: running as root, every file is readable\n'
else
  chmod 000 "$FIVEDIVE_CONNECTORD_ENV"; : > "$POSTS"
  run --telegram-id=$ID
  [[ "$(field .ok)" == false && "$(posts)" == 0 ]] && ok_ "ROOT: unreadable identity -> ok:false (the runner retries with sudo)" || bad_ "ROOT" "$OUT"
  chmod 600 "$FIVEDIVE_CONNECTORD_ENV"
fi

# ANSWERS
for row in "403|{\"error\":\"partner_box\"}|partner_box" \
           "409|{\"error\":\"account_has_other_telegram\"}|other_telegram" \
           "409|{\"error\":\"telegram_taken\"}|taken" \
           "503|{\"error\":\"telegram_app_unavailable\"}|unavailable" \
           "none||error" \
           "500|{\"error\":\"boom\"}|error" \
           "200|{\"url\":\"https://evil.example.com/x\"}|error" \
           "200|{\"url\":\"https://t.me/FiveDiveBot?startapp=ref_x\"}|error"; do
  IFS='|' read -r RESP_CODE RESP_BODY want <<<"$row"
  run --telegram-id=$ID
  [[ "$(field .data.status)" == "$want" && "$(field .data.url)" == null ]] \
    && ok_ "ANSWERS: $RESP_CODE ${RESP_BODY:-<none>} -> $want, no url" || bad_ "ANSWERS $RESP_CODE $RESP_BODY" "$OUT"
done

# BAD
: > "$POSTS"
for bad in "" "@ann" "-$ID" "12ab" "0123456"; do
  run --telegram-id="$bad"
  [[ "$(field .ok)" == false ]] || bad_ "BAD: '$bad' accepted" "$OUT"
done
[[ "$(posts)" == 0 ]] && ok_ "BAD: non-numeric, group and zero-led ids refused, nothing sent" || bad_ "BAD sent"

# CONFIG
( cmd_box_config telegram-app=maybe ) >/dev/null 2>&1 && bad_ "CONFIG: 'maybe' accepted" || ok_ "CONFIG: telegram-app=maybe refused"
cmd_box_config telegram-app=off >/dev/null 2>&1
[[ "$(jq -r .telegram_app "$BOX_CONFIG")" == off && "$(_tg_app_box_setting)" == off ]] && ok_ "CONFIG: telegram-app=off stored" || bad_ "CONFIG off" "$(cat "$BOX_CONFIG")"
cmd_box_config telegram-app=default >/dev/null 2>&1
[[ "$(jq -r 'has("telegram_app")' "$BOX_CONFIG")" == false && "$(_tg_app_box_setting)" == on ]] && ok_ "CONFIG: default clears it (= on)" || bad_ "CONFIG default" "$(cat "$BOX_CONFIG")"
SHOW=$(JSON_MODE=1 cmd_box_config 2>/dev/null)
[[ "$(jq -r .data.telegram_app <<<"$SHOW")" == on ]] && ok_ "CONFIG: 5dive config --json reports telegram_app" || bad_ "CONFIG show" "$SHOW"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
