#!/usr/bin/env bash
# DIVE-7151 — a secret gate on a box with NO chat channel printed no link. On a
# fresh self-hosted box (0.105.0, 2026-10-28) the owner asked olivia (admin seat)
# how to give her a key from a phone. `task need --type=secret` minted nothing,
# because minting lived in the alert path alone and no alert went out, and its
# line said "answer on the dashboard" on a box with no dashboard. She told the
# owner to use that dashboard, then said the box could not make a link. The link
# itself worked: `sudo 5dive secret link` made one in 22 s.
#
#   U1-U4  no channel + an admin seat: the link is minted and is the first note
#          of the OK line, a step line of its own, and JSON secret_link_url;
#   U5-U6  no channel + the mint fails: the "no secure link in this alert"
#          warning, with secret link's own fallback (a domain, or the terminal);
#   U7-U8  no channel + a standard seat: no sudo, no link, the warning names why
#          and the terminal line;
#   D1-D3  "dashboard" is said only on a box linked to the app: the OK line, and
#          the no-channel warning one frame down;
#   C1-C2  controls: a notified gate mints nothing here (its alert did); a box
#          linked to 5dive.app chat keeps its own page (DIVE-7102).
# Isolation: src/ libs, throwaway STATE_DIR; the live tasks.db is never touched.
# Run: bash tests/secret_gate_unnotified_link_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.." || exit 1
SRC=src
TMP=$(mktemp -d /tmp/secret-unnotified-link.XXXXXX)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_secret.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
. "$(dirname "${BASH_SOURCE[0]}")/lib/gate_seam.sh" \
  || printf 'gate seam: UNRESOLVED (tests/lib/gate_seam.sh not reachable); a refusal inside cmd_task_need will abort this harness\n' >&2
set +e
STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
mkdir -p "$TASKS_DIR"
export FIVEDIVE_CHAT_ONLY_MARK="$TMP/chat-only" FIVEDIVE_CONNECTORD_ENV="$TMP/connectord.env"
export FIVEDIVE_NO_HUMAN_SEND=1 FIVEDIVE_GATE_NOTIFY_LOG="$TMP/gate-notify.log"
JSON_MODE=0
tasks_db_init

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-}"; fi; }

NOTIFY_RC=3
task_need_notify() { return "$NOTIFY_RC"; }
registry_read() { printf '%s\n' '{"agents":{"olivia":{"type":"claude"}}}'; }
SUDO_LOG="$TMP/sudo.log"; SUDO_RC=0; SUDO_OUT=''
sudo() { echo "$*" >> "$SUDO_LOG"; printf '%s' "$SUDO_OUT"; return "$SUDO_RC"; }
id() { [[ "${1:-}" == -un ]] && { printf 'agent-olivia\n'; return 0; }; command id "$@"; }
SEAT_TIER=admin
agent_tier() { [[ "$1" == olivia ]] && printf '%s\n' "$SEAT_TIER" || printf 'unknown:unregistered\n'; }
N=0
file_gate() { # [type] — files a fresh gate; sets OUT ERR JS
  local type="${1:-secret}" extra=()
  N=$((N+1)); IDENT="DIVE-$N"; : > "$SUDO_LOG"
  db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('$IDENT','t','todo','olivia');"
  [[ "$type" == secret ]] && extra=(--secret-key=X_API_KEY --connector=tools)
  [[ "$type" == decision ]] && extra=(--options="ship it now|wait a week" --recommend="ship it now")
  OUT=$(cmd_task_need "$IDENT" --from=olivia --type="$type" --ask="the X API key for posting" "${extra[@]}" 2>"$TMP/err")
  ERR=$(cat "$TMP/err")
}
okline() { grep -m1 '^OK — ' <<<"$OUT"; }
LINK='https://203-0-113-7.sslip.io/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCd'

echo '== no channel, an admin seat: the link is printed =='
SUDO_OUT="{\"ok\":true,\"data\":{\"url\":\"$LINK\",\"ttl_minutes\":30}}"
file_gate
check 'U1 the gate mints its link although no alert went out' \
  '[[ "$(cat "$SUDO_LOG")" == "-n 5dive --json secret link $IDENT --again" ]]' "sudo: $(cat "$SUDO_LOG")"
check 'U2 the link is the FIRST note of the OK line, as the thing to send the owner' \
  '[[ "$(okline)" == "OK — $IDENT needs a human (secret, tier "[0-9]") [no chat channel, so nobody was pinged: send the owner this link yourself"*"$LINK]"* ]]' "$(okline)"
check 'U3 and a step line of its own carries it' \
  'grep -qx "==> Send the owner this link (one use, until [0-9:]* UTC; the value never goes in chat): $LINK" <<<"$ERR"' "$ERR"
check 'U3b the line names no dashboard and says nothing about UNNOTIFIED answering' \
  '! grep -qiE "dashboard|UNNOTIFIED" <<<"$(okline)"' "$(okline)"
db "INSERT INTO tasks (ident, title, status, created_by) VALUES ('DIVE-90','t','todo','olivia');"
JS=$(JSON_MODE=1 cmd_task_need DIVE-90 --from=olivia --type=secret --ask="a key" --secret-key=Y_API_KEY --connector=tools 2>/dev/null)
check 'U4 JSON carries secret_link_url and when it expires' \
  '[[ "$(jq -r .data.secret_link_url <<<"$JS")" == "$LINK" && "$(jq -r .data.drop_link_expires_at <<<"$JS")" == 20*Z && "$(jq -r .data.notified <<<"$JS")" == false ]]' "$JS"

echo '== no channel, the mint fails: the warning, with the fallback =='
SUDO_RC=4
SUDO_OUT='{"ok":false,"error":{"code":"E_NOT_INSTALLED","message":"this box has no secure web address for the link yet. Ask your owner first: \"Do you have a domain?\" Without one, the owner types the value on this box instead: sudo 5dive secret write X_API_KEY --connector=tools --task=DIVE-3"}}'
file_gate
check 'U5 the warning says no secure link, and why, in secret link'"'"'s words' \
  'grep -q "no secure link in this alert — .*Do you have a domain?.*secret write X_API_KEY" <<<"$ERR"' "$ERR"
check 'U6 no link is printed, and no dashboard is named' \
  '! grep -q "https://" <<<"$(okline)" && ! grep -qi dashboard <<<"$(okline)$ERR"' "ok=$(okline) err=$ERR"
SUDO_RC=0; SUDO_OUT="{\"ok\":true,\"data\":{\"url\":\"$LINK\",\"ttl_minutes\":30}}"

echo '== no channel, a standard seat: no link may reach it =='
SEAT_TIER=standard
file_gate
check 'U7 a standard seat runs no sudo and prints no link' \
  '[[ ! -s "$SUDO_LOG" ]] && ! grep -q "$LINK" <<<"$OUT$ERR"' "sudo=$(cat "$SUDO_LOG") out=$OUT"
check 'U8 the warning names why, an admin seat'"'"'s link, and the terminal line' \
  'grep -q "no secure link in this alert — no chat channel.*5dive secret link $IDENT.*secret write X_API_KEY --connector=tools --task=$IDENT" <<<"$ERR"' "$ERR"
SEAT_TIER=admin

echo '== "dashboard" only where there is one =='
file_gate decision
check 'D1 an OSS box (no app link) never says dashboard on an unnotified gate' \
  '[[ "$(okline)" == *"[UNNOTIFIED — nobody was pinged; answer with: 5dive task answer $IDENT]"* ]] && ! grep -qi dashboard <<<"$(okline)"' "$(okline)"
: > "$FIVEDIVE_CONNECTORD_ENV"
file_gate decision
check 'D2 a box linked to the app still names its dashboard' \
  '[[ "$(okline)" == *"answer on the dashboard or: 5dive task answer $IDENT"* ]]' "$(okline)"
rm -f "$FIVEDIVE_CONNECTORD_ENV"
# One frame down: the deliverer's own no-channel warning.
(
  _task_secret_send_via_root() { return 1; }
  _task_gate_preview_channel() { return 1; }
  _task_chain_channel() { return 1; }
  _task_chain_paired() { :; }
  _task_deployment_has_channels() { return 1; }
  _task_need_notify_deliver_now DIVE-1 decision "a q" "a|b" "" "" "" "" ""
) >/dev/null 2>"$TMP/dn.err"; drc=$?
check 'D3 the no-channel warning on an OSS box says how to answer, without a dashboard' \
  '[[ $drc == 3 ]] && grep -q "Nobody was pinged; answer with: 5dive task answer DIVE-1" "$TMP/dn.err" && ! grep -qi dashboard "$TMP/dn.err"' "rc=$drc $(cat "$TMP/dn.err")"

echo '== controls =='
NOTIFY_RC=0
file_gate
check 'C1 a notified gate mints nothing here (its alert carried the link)' \
  '[[ ! -s "$SUDO_LOG" ]] && ! grep -q "$LINK" <<<"$OUT"' "sudo=$(cat "$SUDO_LOG") out=$OUT"
NOTIFY_RC=3; : > "$FIVEDIVE_CHAT_ONLY_MARK"
file_gate
check 'C2 a box linked to 5dive.app chat keeps its own page and mints nothing' \
  '[[ ! -s "$SUDO_LOG" && "$(okline)" == *"my.5dive.ai/tg/secret?key=X_API_KEY"* ]] && ! grep -q "$LINK" <<<"$OUT"' "sudo=$(cat "$SUDO_LOG") out=$OUT"
rm -f "$FIVEDIVE_CHAT_ONLY_MARK"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
