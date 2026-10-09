#!/usr/bin/env bash
# DIVE-5934: AWS as a tools-catalog key, and Google as a SIGN-IN in `5dive tool`.
#   * `tool set aws` takes the access key id then the secret on stdin; ls lists it
#   * `tool ls` ends with {id:"google", kind:"signin", env:[], connected, account},
#     read from gcloud's config files (never by running gcloud)
#   * `tool google start` returns at once: `installing` while 5dive-ensure-cli
#     runs detached when gcloud is missing, then the poll that sees it finish
#     starts the login; it refuses with no installer, or with too little disk
#   * poll pulls the accounts.google.com link out of the PTY log (awaiting_code),
#     and reads "You are now logged in as [x]" as ok with the account
#   * submit takes the code on STDIN only, one clean line, and types it into the
#     login; cancel tears it down; `tool rm google` revokes and leaves ls false
#   * every one of those verbs is root-only
# Isolation: src/ sourced against a throwaway connectors dir, session dir and
# gcloud config; sudo is a function, tmux, gcloud and 5dive-ensure-cli are fakes
# on PATH. No root, no network, no real tmux.
# Run: bash tests/tool_google_signin_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/tool-google-unit.XXXXXX)"
export FIVEDIVE_CONNECTOR_DIR="$TMP/connectors"
mkdir -p "$FIVEDIVE_CONNECTOR_DIR" "$TMP/bin"

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh cmd_auth.sh cmd_tool.sh; do
  # shellcheck source=/dev/null
  source "src/$f"
done
set +e
TOOLS_WRITE_LOCK="$TMP/lock"
AUTH_SESSIONS_DIR="$TMP/sessions"
TOOL_GCLOUD_CONFIG="$TMP/gcloud"
TOOL_ENSURE_CLI="$TMP/bin/5dive-ensure-cli"
TOOL_GCLOUD_INSTALL_LOCK="$TMP/gcloud-install.lock"
export FIVEDIVE_GCLOUD_BIN="$TMP/bin/gcloud"
export PATH="$TMP/bin:$PATH"
JSON_MODE=1

# --- stubs --------------------------------------------------------------------
require_root() { :; }
require_auth_session_root() { mkdir -p "$AUTH_SESSIONS_DIR"; return 0; }
chown() { :; }
# sudo -u claude [-H] [-n] <cmd...>: run it as this user. A login shell (-lc)
# would source this runner's own profile, so it runs as a plain -c.
sudo() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in -u) shift 2 ;; *) shift ;; esac
  done
  printf '%s\n' "$*" >>"$TMP/sudo.log"
  if [[ "${1:-}" == bash && "${2:-}" == -lc ]]; then bash -c "$3"; return $?; fi
  "$@"
}
# tmux -S <sock> <verb> ...: the session is "alive" while <sock>.alive exists.
cat >"$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
sock="$2"; verb="$3"; shift 3
case "$verb" in
  new-session) : >"$sock.alive"; printf '%s\n' "$*" >"$sock.cmd" ;;
  has-session) [[ -e "$sock.alive" ]] ;;
  send-keys) printf '%s\n' "$*" >>"$sock.keys" ;;
  kill-session|kill-server) rm -f "$sock.alive" ;;
  *) : ;;
esac
SH
# The installer puts a fake gcloud in place. gcloud records its argv and config,
# and (like a revoke that left the property behind) changes nothing on disk.
cat >"$TMP/gcloud.src" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/gcloud.args"
printf '%s\n' "\${CLOUDSDK_CONFIG:-}" >>"$TMP/gcloud.env"
SH
cat >"$TMP/bin/5dive-ensure-cli.src" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$TMP/ensure.args"
cp "$TMP/gcloud.src" "$TMP/bin/gcloud" && chmod 755 "$TMP/bin/gcloud"
echo "Setting up google-cloud-cli ..."
SH
chmod 755 "$TMP/bin/tmux" "$TMP/bin/5dive-ensure-cli.src"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# `fail` exits, so every verb runs in a subshell.
run() { ( cmd_tool "$@" ) 2>&1; }
runq() { ( cmd_tool "$@" ) 2>/dev/null; }
F="$TOOLS_ENV_FILE"
seen() { BASH_ENV="$F" /bin/bash -c "printf '%s' \"\${$1:-}\""; }
row() { jq -c --arg id "$1" '.data.tools[] | select(.id == $id)' <<<"$(runq ls)"; }
meta() { jq -r "$2" "$AUTH_SESSIONS_DIR/$1/meta.json"; }
nsessions() { local n=0 d; for d in "$AUTH_SESSIONS_DIR"/*/; do [[ -d "$d" ]] && n=$((n+1)); done; echo "$n"; return 0; }
wait_install() {
  local i
  for i in $(seq 1 50); do [[ -s "$AUTH_SESSIONS_DIR/$1/install.rc" ]] && return 0; sleep 0.1; done
  return 1
}

# --- A: aws is a catalog key ---------------------------------------------------
out=$(printf 'AKIAFAKE00000000TEST\nwJalrFAKEsecretKEY0000000000000000000000\n' | run set aws); rc=$?
[[ $rc -eq 0 && "$(seen AWS_ACCESS_KEY_ID)" == AKIAFAKE00000000TEST && "$(seen AWS_SECRET_ACCESS_KEY)" == wJalrFAKEsecretKEY0000000000000000000000 ]] \
  && ok_t "A1 set aws: key id then secret, a fresh bash sees both" || bad_t "A1 set aws" "rc=$rc $out"
r=$(row aws)
[[ "$(jq -c '[.kind, .env, .connected]' <<<"$r")" == '["key",["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY"],true]' ]] \
  && ok_t "A2 ls --json lists aws: kind key, both vars, connected" || bad_t "A2 ls aws" "$r"
[[ "$(runq ls)" != *wJalrFAKE* ]] && ok_t "A2 ls never prints the secret" || bad_t "A2 leak"
out=$(printf 'AKIAONLYONELINE00000\n' | run set aws); rc=$?
[[ $rc -ne 0 && "$out" == *"takes 2 value"* ]] && ok_t "A3 aws with one line refused" || bad_t "A3 one line" "rc=$rc $out"
out=$(run rm aws); rc=$?
[[ $rc -eq 0 && -z "$(seen AWS_ACCESS_KEY_ID)" && "$(jq -r .connected <<<"$(row aws)")" == false ]] \
  && ok_t "A4 rm aws: both gone, ls disconnected" || bad_t "A4 rm aws" "rc=$rc $out"
_tools_var_reserved AWS_ACCESS_KEY_ID && bad_t "A5 a secret gate may write AWS_ACCESS_KEY_ID to tools" \
  || ok_t "A5 a secret gate may write AWS_ACCESS_KEY_ID to tools (catalog extra)"

# --- G1: ls ends with the google sign-in, read from gcloud's files ---------------
out=$(runq ls)
last=$(jq -c '.data.tools[-1]' <<<"$out")
[[ "$last" == '{"id":"google","kind":"signin","env":[],"connected":false,"account":""}' ]] \
  && ok_t "G1 ls: google is the last row, signin, not connected (no config dir)" || bad_t "G1 google row" "$last"
txt=$( ( JSON_MODE=0; cmd_tool ls ) 2>&1 | tail -1)
[[ "$txt" == $'google\t-\t' ]] && ok_t "G1 text ls: google -" || bad_t "G1 text ls" "$txt"
mkdir -p "$TOOL_GCLOUD_CONFIG/configurations"
printf '[core]\naccount = owner@example.com\nproject = demo-1\n' >"$TOOL_GCLOUD_CONFIG/configurations/config_default"
[[ "$(jq -r .connected <<<"$(row google)")" == false ]] \
  && ok_t "G2 an account line with no credential store is not connected" || bad_t "G2 no creds" "$(row google)"
printf 'SQLite format 3\0fake' >"$TOOL_GCLOUD_CONFIG/credentials.db"
r=$(row google)
[[ "$(jq -c '[.connected, .account]' <<<"$r")" == '[true,"owner@example.com"]' ]] \
  && ok_t "G2 account + credentials.db: connected, account named" || bad_t "G2 connected" "$r"
txt=$( ( JSON_MODE=0; cmd_tool ls ) 2>&1 | tail -1)
[[ "$txt" == $'google\tconnected\towner@example.com' ]] && ok_t "G2 text ls names the account" || bad_t "G2 text" "$txt"
printf 'work\n' >"$TOOL_GCLOUD_CONFIG/active_config"
printf '[core]\nproject = other\n' >"$TOOL_GCLOUD_CONFIG/configurations/config_work"
[[ "$(jq -r .connected <<<"$(row google)")" == false ]] \
  && ok_t "G2 reads the ACTIVE configuration (work, no account): not connected" || bad_t "G2 active config" "$(row google)"
rm -f "$TOOL_GCLOUD_CONFIG/active_config" "$TOOL_GCLOUD_CONFIG/credentials.db" "$TOOL_GCLOUD_CONFIG/configurations/config_work"
out=$(printf 'x\n' | run set google); rc=$?
[[ $rc -ne 0 && "$out" == *"signs in"* ]] && ok_t "G3 tool set google refused: it is a sign-in" || bad_t "G3 set google" "rc=$rc $out"
[[ ! -e "$TMP/sudo.log" ]] && ok_t "G3 ls never ran anything as claude (no gcloud exec)" || bad_t "G3 ls ran" "$(cat "$TMP/sudo.log")"

# --- G4: start with gcloud missing --------------------------------------------------
out=$(run google start); rc=$?
[[ $rc -eq 7 && "$out" == *"no installer"* && "$(nsessions)" == 0 ]] \
  && ok_t "G4 no gcloud and no 5dive-ensure-cli: refused (7), no session" || bad_t "G4 no installer" "rc=$rc $out"
mv "$TMP/bin/5dive-ensure-cli.src" "$TOOL_ENSURE_CLI"
out=$( ( TOOL_GCLOUD_MIN_FREE_KB=999999999999; cmd_tool google start ) 2>&1 ); rc=$?
[[ $rc -eq 3 && "$out" == *"MB free"* && "$(nsessions)" == 0 && ! -e "$TMP/ensure.args" ]] \
  && ok_t "G4 too little disk: refused (3) naming the MB, nothing installed" || bad_t "G4 disk" "rc=$rc $out"
out=$(runq google start); rc=$?
S1=$(jq -r '.data.session' <<<"$out")
[[ $rc -eq 0 && "$S1" =~ ^[0-9a-f]{16}$ && "$(jq -r .data.state <<<"$out")" == installing ]] \
  && ok_t "G4 start with gcloud missing: {session, state:installing} at once" || bad_t "G4 start" "rc=$rc $out"
wait_install "$S1" && [[ "$(cat "$TMP/ensure.args")" == gcloud ]] \
  && ok_t "G4 the detached installer ran 5dive-ensure-cli gcloud" || bad_t "G4 installer" "$(ls "$AUTH_SESSIONS_DIR/$S1")"

# --- G5: the poll that sees the install finish starts the login ---------------------
out=$(runq google poll "$S1")
D1="$AUTH_SESSIONS_DIR/$S1"
[[ "$(jq -r .data.state <<<"$out")" == pending_url ]] && ok_t "G5 poll after the install: pending_url" || bad_t "G5 pending_url" "$out"
cmd=$(cat "$D1/tmux.sock.cmd" 2>/dev/null)
[[ "$cmd" == *"CLOUDSDK_CONFIG=$TOOL_GCLOUD_CONFIG script -q -f -c"* && "$cmd" == *"$FIVEDIVE_GCLOUD_BIN auth login --no-launch-browser --enable-gdrive-access"* && "$cmd" == *"-s auth-$S1"* ]] \
  && ok_t "G5 login: gcloud auth login --no-launch-browser --enable-gdrive-access under script, shared config" || bad_t "G5 login cmd" "$cmd"
[[ "$(meta "$S1" .urlDeadline)" -gt "$(date +%s)" ]] && ok_t "G5 a link deadline is armed" || bad_t "G5 deadline" "$(meta "$S1" .urlDeadline)"

# --- G6: the link out of the PTY log --------------------------------------------------
URL='https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=32555940559.apps.googleusercontent.com&redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html&scope=openid+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive&state=AbC123&prompt=consent&code_challenge=xyz&code_challenge_method=S256'
printf '\e[0mGo to the following link in your browser, and complete the sign-in prompts:\r\n\r\n    %s\r\n\r\nOnce finished, enter the verification code provided in your browser: ' "$URL" >"$D1/login.log"
out=$(runq google poll "$S1")
[[ "$(jq -r .data.state <<<"$out")" == awaiting_code && "$(jq -r .data.url <<<"$out")" == "$URL" ]] \
  && ok_t "G6 poll: awaiting_code with the whole accounts.google.com link" || bad_t "G6 url" "$out"
[[ "$(jq -c '.data | keys' <<<"$out")" == '["account","error","session","state","url"]' ]] \
  && ok_t "G6 poll answers exactly {session, state, url, account, error}" || bad_t "G6 shape" "$out"

# --- G7: submit: stdin only, one clean line --------------------------------------------
K="$D1/tmux.sock.keys"
out=$(printf '4/0AbC-def_123\n' | run google submit "$S1" 4/0AbC-def_123); rc=$?
[[ $rc -eq 2 && "$out" == *"stdin"* && ! -e "$K" ]] && ok_t "G7 a code in argv is refused (2), nothing typed" || bad_t "G7 argv" "rc=$rc $out"
out=$(printf 'x\n' | run google submit "$S1" --code=4/0AbC); rc=$?
[[ $rc -eq 2 && ! -e "$K" ]] && ok_t "G7 --code= is refused too" || bad_t "G7 --code" "rc=$rc $out"
for bad in '4/0AbC def' "4/0AbC'x" '4/0AbC"x' '4/0Ab`id`'; do
  out=$(printf '%s\n' "$bad" | run google submit "$S1"); rc=$?
  [[ $rc -eq 3 && ! -e "$K" ]] && ok_t "G7 refused: $bad" || bad_t "G7 must refuse: $bad" "rc=$rc $out"
done
out=$(printf '4/0AbC\nsecond\n' | run google submit "$S1"); rc=$?
[[ $rc -eq 3 && ! -e "$K" ]] && ok_t "G7 two lines refused" || bad_t "G7 two lines" "rc=$rc $out"
out=$(printf '4/0AbC-def_123\r\n' | runq google submit "$S1"); rc=$?
[[ $rc -eq 0 && "$(jq -r .data.state <<<"$out")" == submitted ]] && ok_t "G7 a clean code: submitted" || bad_t "G7 submit" "rc=$rc $out"
keys=$(cat "$K" 2>/dev/null)
[[ "$keys" == *"-t auth-$S1 -l -- 4/0AbC-def_123"* && "$keys" == *"-t auth-$S1 Enter"* ]] \
  && ok_t "G7 the code is typed literally into the login, then Enter (CR stripped)" || bad_t "G7 keys" "$keys"
[[ "$(grep -c -- '4/0AbC-def_123' "$TMP/sudo.log")" == 1 ]] \
  && ok_t "G7 the code reached argv only in the one send-keys" || bad_t "G7 code spread" "$(cat "$TMP/sudo.log")"

# --- G8: ok with the account -----------------------------------------------------------
printf '\r\nYou are now logged in as [owner@example.com].\r\nYour current project is [None].\r\n' >>"$D1/login.log"
printf 'SQLite format 3\0fake' >"$TOOL_GCLOUD_CONFIG/credentials.db"
out=$(runq google poll "$S1")
[[ "$(jq -c '[.data.state, .data.account, .data.error]' <<<"$out")" == '["ok","owner@example.com",null]' ]] \
  && ok_t "G8 poll: ok with the account" || bad_t "G8 ok" "$out"
[[ ! -e "$D1/tmux.sock.alive" ]] && ok_t "G8 the login is torn down once the account is on disk" || bad_t "G8 teardown"
[[ "$(jq -c '[.connected, .account]' <<<"$(row google)")" == '[true,"owner@example.com"]' ]] \
  && ok_t "G8 ls: google connected as owner@example.com" || bad_t "G8 ls" "$(row google)"
out=$(printf '4/0AbC\n' | run google submit "$S1"); rc=$?
[[ $rc -eq 3 && "$out" == *"already ended"* ]] && ok_t "G8 submit after ok refused" || bad_t "G8 late submit" "rc=$rc $out"

# --- G9: a newer start replaces the live one; cancel ------------------------------------
S2=$(runq google start | jq -r .data.session)
[[ "$(meta "$S2" .state)" == pending_url && "$(cat "$TMP/ensure.args")" == gcloud ]] \
  && ok_t "G9 start with gcloud installed: straight to pending_url" || bad_t "G9 start" "$(meta "$S2" .state)"
S3=$(runq google start | jq -r .data.session)
[[ "$(meta "$S2" .state)" == expired && ! -e "$AUTH_SESSIONS_DIR/$S2/tmux.sock.alive" && "$(meta "$S1" .state)" == ok ]] \
  && ok_t "G9 a newer start expires the live session, leaves the finished one" || bad_t "G9 replace" "$(meta "$S2" .state)"
out=$(runq google cancel "$S3"); rc=$?
[[ $rc -eq 0 && "$(jq -r .data.state <<<"$out")" == expired && ! -e "$AUTH_SESSIONS_DIR/$S3/tmux.sock.alive" ]] \
  && ok_t "G9 cancel: expired, login torn down" || bad_t "G9 cancel" "rc=$rc $out"

# --- G10: a login that dies says why --------------------------------------------------------
S4=$(runq google start | jq -r .data.session)
printf 'ERROR: (gcloud.auth.login) There was a problem with web authentication.\r\n' >"$AUTH_SESSIONS_DIR/$S4/login.log"
rm -f "$AUTH_SESSIONS_DIR/$S4/tmux.sock.alive"
out=$(runq google poll "$S4")
[[ "$(jq -r .data.state <<<"$out")" == error && "$(jq -r .data.error <<<"$out")" == *"problem with web authentication"* ]] \
  && ok_t "G10 login gone before a link: error carrying gcloud's ERROR line" || bad_t "G10 error" "$out"

# --- G11: only Google sessions, only well-formed ids -------------------------------------------
mkdir -p "$AUTH_SESSIONS_DIR/0123456789abcdef"
printf '{"sessionId":"0123456789abcdef","type":"claude","state":"pending_url"}\n' >"$AUTH_SESSIONS_DIR/0123456789abcdef/meta.json"
out=$(run google poll 0123456789abcdef); rc=$?
[[ $rc -eq 4 ]] && ok_t "G11 an agent auth session is not a Google one (4)" || bad_t "G11 type" "rc=$rc $out"
out=$(run google poll ../../etc); rc=$?
[[ $rc -eq 3 ]] && ok_t "G11 a malformed session id is refused (3)" || bad_t "G11 id" "rc=$rc $out"

# --- G12: rm google signs out, keeps the rest of the config ------------------------------------
: >"$TMP/gcloud.args"
out=$(run rm google); rc=$?
[[ $rc -eq 0 && "$(jq -c '.data' <<<"$out")" == '{"tool":"google","connected":false}' ]] \
  && ok_t "G12 rm google answers connected:false" || bad_t "G12 rm" "rc=$rc $out"
[[ "$(cat "$TMP/gcloud.args")" == "auth revoke --all --quiet" && "$(tail -1 "$TMP/gcloud.env")" == "$TOOL_GCLOUD_CONFIG" ]] \
  && ok_t "G12 it ran gcloud auth revoke --all --quiet against the shared config" || bad_t "G12 revoke" "$(cat "$TMP/gcloud.args")"
[[ "$(jq -c '[.connected, .account]' <<<"$(row google)")" == '[false,""]' ]] \
  && ok_t "G12 ls: google not connected, even though revoke left the account line" || bad_t "G12 ls" "$(row google)"
[[ -d "$TOOL_GCLOUD_CONFIG" ]] && grep -q '^project = demo-1$' "$TOOL_GCLOUD_CONFIG/configurations/config_default" \
  && ok_t "G12 the config dir and its other settings are kept" || bad_t "G12 kept" "$(cat "$TOOL_GCLOUD_CONFIG/configurations/config_default")"

# --- G14: the real CLI runs under errexit + pipefail; the harness's set +e hides that ---
strict() { ( set -euo pipefail; cmd_tool "$@" ) 2>/dev/null; }
out=$(strict ls); rc=$?
[[ $rc -eq 0 && "$(jq -r '.data.tools[-1].id' <<<"$out")" == google ]] && ok_t "G14 ls under errexit: rc 0" || bad_t "G14 ls" "rc=$rc $out"
out=$(strict google start); rc=$?
S5=$(jq -r '.data.session' <<<"$out")
[[ $rc -eq 0 && "$S5" =~ ^[0-9a-f]{16}$ ]] && ok_t "G14 start under errexit: rc 0" || bad_t "G14 start" "rc=$rc $out"
out=$(strict google poll "$S5"); rc=$?
[[ $rc -eq 0 && "$(jq -r .data.state <<<"$out")" == pending_url ]] && ok_t "G14 poll (no link yet) under errexit: rc 0" || bad_t "G14 poll" "rc=$rc $out"
printf '    %s\r\n' "$URL" >"$AUTH_SESSIONS_DIR/$S5/login.log"
out=$(strict google poll "$S5"); rc=$?
[[ $rc -eq 0 && "$(jq -r .data.state <<<"$out")" == awaiting_code ]] && ok_t "G14 poll (link) under errexit: rc 0" || bad_t "G14 poll link" "rc=$rc $out"
out=$(printf '4/0AbC-def_123\n' | strict google submit "$S5"); rc=$?
[[ $rc -eq 0 ]] && ok_t "G14 submit under errexit: rc 0" || bad_t "G14 submit" "rc=$rc $out"
rm -f "$AUTH_SESSIONS_DIR/$S5/tmux.sock.alive"
out=$(strict google poll "$S5"); rc=$?
[[ $rc -eq 0 && "$(jq -r .data.state <<<"$out")" == error ]] && ok_t "G14 poll (login died after the code) under errexit: rc 0, error" || bad_t "G14 poll died" "rc=$rc $out"
out=$(strict rm google); rc=$?
[[ $rc -eq 0 ]] && ok_t "G14 rm google under errexit: rc 0" || bad_t "G14 rm" "rc=$rc $out"

# --- G13: root-only ---------------------------------------------------------------------------
nonroot() { ( require_root() { fail "$E_PERMISSION" "must run as root"; }; cmd_tool "$@" ) 2>/dev/null; }
before=$(nsessions)
for v in "google start" "google poll $S1" "google cancel $S1" "rm google" "set aws"; do
  # shellcheck disable=SC2086
  out=$(printf '4/0AbC\n' | nonroot $v); rc=$?
  [[ $rc -eq 10 ]] && ok_t "G13 not root: tool $v refused (10)" || bad_t "G13 tool $v" "rc=$rc $out"
done
out=$(printf '4/0AbC\n' | nonroot google submit "$S1"); rc=$?
[[ $rc -eq 10 ]] && ok_t "G13 not root: tool google submit refused (10)" || bad_t "G13 submit" "rc=$rc $out"
[[ "$(nsessions)" == "$before" ]] && ok_t "G13 no refused start made a session" || bad_t "G13 sessions" "$(nsessions)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
