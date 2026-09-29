#!/usr/bin/env bash
# DIVE-5161 — `5dive agent mail set|remove|list|show`: a partner client connects
# an agent's mailbox with an APP PASSWORD over /shell/exec (root, argv + stdin).
#
# What this grades, and the seams it uses to grade it without root or network:
#   - the password rides STDIN only: argv values, a TTY (a real pty via script(1)),
#     embedded newline / CR / NUL are refused; one trailing \r?\n is stripped;
#   - login is verified BEFORE anything permanent lands, and the two failure
#     classes carry the exact prefixes the API keys off (login_failed: rc 6,
#     mail_unreachable: rc 3), with the password scrubbed from the server text;
#   - on success the files are 0600 in 0700 dirs, every write under the agent's
#     home runs AS the agent (runuser), and no child process ever sees the
#     password in its argv — every external command runs through a PATH wrapper
#     that records its argv, so "never in argv" is measured, not grepped;
#   - a foreign himalaya config is refused before any write; remove/list/show;
#   - the pinned himalaya install refuses a sha256 mismatch.
# Root is SIMULATED: _agent_mail_is_root says yes and `runuser` is a PATH stub
# that marks what runs under it and then runs it as the caller.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-mail-unit.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
pass=0; fail=0
okk() { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- the product, sourced ----------------------------------------------------
declare -A TYPE_PERSONA_FILE=([claude]=".claude/CLAUDE.md" [codex]=".codex/AGENTS.md")
FIVE_REPORTED_FLAG="$TMP/reported"; JSON_MODE=0
# shellcheck source=/dev/null
source "$ROOT/src/lib/error_codes.sh"
# shellcheck source=/dev/null
source "$ROOT/src/lib/output.sh"
# shellcheck source=/dev/null
source "$ROOT/src/lib/validation.sh"
# shellcheck source=/dev/null
source "$ROOT/src/lib/agent_setup.sh"
# shellcheck source=/dev/null
source "$ROOT/src/cmd_agent_mail.sh"

export AGENT_HOME_ROOT="$TMP/home" PERSONA_HOME_ROOT="$TMP/home"
export ARGV_LOG="$TMP/argv.log" HM_MODE="$TMP/hm.mode" HM_EXPECT="$TMP/hm.expect" CURL_CODE="$TMP/curl.code"
export CURL_FIXTURE="" USERS="$TMP/users"
export AGENT_MAIL_HIMALAYA_BIN="$TMP/hbin/himalaya"
mkdir -p "$TMP/hbin" "$TMP/wrap" "$TMP/agenttmp"
: >"$ARGV_LOG"

# Registered agents and which of them have a Linux user.
REG='{"agents":{"alpha":{"type":"claude"},"beta":{"type":"claude"},"gamma":{"type":"codex"},"nouser":{"type":"claude"}}}'
printf 'agent-alpha\nagent-beta\nagent-gamma\n' >"$USERS"
for n in alpha beta gamma nouser; do mkdir -p "$AGENT_HOME_ROOT/agent-$n"; done
registry_read() { printf '%s\n' "$REG"; }
ensure_state_ro() { :; }
require_agent() { jq -e --arg n "$1" '.agents[$n] != null' <<<"$REG" >/dev/null || fail "$E_NOT_FOUND" "no agent named '$1'"; }
agent_type() { jq -r --arg n "$1" '.agents[$n].type // empty' <<<"$REG"; }
_agent_mail_is_root() { return 0; }
# The deferred restart: record the call; RESTART_RC decides its outcome.
export RESTART_LOG="$TMP/restart.log"; RESTART_RC=0; : >"$RESTART_LOG"
cmd_restart() { printf '%s\n' "$*" >>"$RESTART_LOG"; echo '{"ok":true,"data":{"noise":1}}'; return "$RESTART_RC"; }

# --- argv-recording wrappers for every external command the verb runs ---------
for c in cat dd mv chmod mkdir rm head jq python3 grep sha256sum tar install env timeout date \
         mktemp test awk sed tr cut stat uname dirname sh; do
  real=$(type -P "$c") || continue   # the FILE, never a builtin: `exec test` would loop back here
  printf '#!/bin/bash\nprintf "%%s|%%s %%s\\n" "${_AS_USER:-ROOT}" %q "$*" >>"$ARGV_LOG"\nexec %q "$@"\n' "$c" "$real" >"$TMP/wrap/$c"
done
REAL_ID=$(type -P id)
cat >"$TMP/wrap/id" <<EOF
#!/bin/bash
printf '%s|id %s\n' "\${_AS_USER:-ROOT}" "\$*" >>"\$ARGV_LOG"
if [[ "\$1" == -u && "\$2" == agent-* ]]; then grep -qx -- "\$2" "\$USERS"; exit; fi
exec $REAL_ID "\$@"
EOF
cat >"$TMP/wrap/runuser" <<'EOF'
#!/bin/bash
printf '%s|runuser %s\n' "${_AS_USER:-ROOT}" "$*" >>"$ARGV_LOG"
[[ "$1" == -u && "$2" == agent-* && "$3" == -- ]] || { echo "BAD-RUNUSER" >>"$ARGV_LOG"; exit 97; }
export _AS_USER="$2"; shift 3; exec "$@"
EOF
cat >"$TMP/wrap/curl" <<'EOF'
#!/bin/bash
printf '%s|curl %s\n' "${_AS_USER:-ROOT}" "$*" >>"$ARGV_LOG"
out=""; prop=0; netrc=""; prev=""
for a in "$@"; do
  [[ "$prev" == -o ]] && out="$a"; [[ "$prev" == --netrc-file ]] && netrc="$a"
  [[ "$a" == PROPFIND ]] && prop=1; prev="$a"
done
if (( prop )); then
  [[ -r "$netrc" ]] && cp "$netrc" "${ARGV_LOG%/*}/netrc.seen"
  printf '%s' "$(cat "$CURL_CODE" 2>/dev/null || echo 207)"; exit 0
fi
[[ -n "$CURL_FIXTURE" && -n "$out" ]] || exit 22
cp "$CURL_FIXTURE" "$out"
EOF
# himalaya: --version, and `-c <cfg> --json mailbox list`, which runs the config's
# own password.command exactly as the real binary would.
cat >"$AGENT_MAIL_HIMALAYA_BIN" <<'EOF'
#!/bin/bash
printf '%s|himalaya %s\n' "${_AS_USER:-ROOT}" "$*" >>"$ARGV_LOG"
[[ "$1" == --version ]] && { echo "himalaya v2.1.0 +stub"; exit 0; }
cfg="$2"
[[ -e "$AGENT_HOME_ROOT/${_AS_USER:-x}/.config/5dive-mail/mail.json" ]] && echo "PRE-EXISTING-MAILJSON $cfg" >>"$ARGV_LOG"
cmd=$(sed -n 's/^imap\.sasl\.plain\.password\.command = "\(.*\)"$/\1/p' "$cfg")
got=$(sh -c "$cmd")
case "$(cat "$HM_MODE" 2>/dev/null || echo check)" in
  check)
    [[ "$got" == "$(cat "$HM_EXPECT")" ]] && { echo '[]'; exit 0; }
    printf '{"error":"IMAP AUTHENTICATE PLAIN failed: NO Invalid credentials (Failure) for %s","sources":[],"backtrace":null}\n' "$got"; exit 1 ;;
  unreach) echo '{"error":"connect imap.x.invalid:993","sources":["failed to lookup address information: Name does not resolve"],"backtrace":null}'; exit 1 ;;
  noroute) echo '{"error":"connect imap.example.com:993","sources":["No route to host (os error 113)"],"backtrace":null}'; exit 1 ;;
  greeting) echo '{"error":"IMAP greeting failed: decode error","sources":[],"backtrace":null}'; exit 1 ;;
  timeout) exit 124 ;;
esac
EOF
chmod +x "$TMP/wrap/"* "$AGENT_MAIL_HIMALAYA_BIN"

PW='s3cret-App-Pw_7'
printf '%s' "$PW" >"$HM_EXPECT"
# run <stdin-bytes> <fn> <args...>: one verb call as (simulated) root through the
# wrappers; sets OUT (JSON on stdout), ERR, RC.
run() {
  local input="$1"; shift
  OUT=$( { printf '%b' "$input" | ( PATH="$TMP/wrap:$PATH"; TMPDIR="$TMP/agenttmp"; JSON_MODE=1; "$@" ); } 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}
msg() { jq -r '.error.message // empty' <<<"$OUT" 2>/dev/null; }
SET_ARGS=(--email=user@example.com --imap=IMAP.Example.com --smtp=smtp.example.com --password=-)
home="$AGENT_HOME_ROOT/agent-alpha"

# --- the password rides stdin only ----------------------------------------------
run "$PW\n" _agent_mail_set alpha --email=user@example.com --imap=imap.example.com --smtp=smtp.example.com --password="$PW"
(( RC == 2 )) && [[ "$OUT$ERR" != *"$PW"* ]] && okk 'a password in argv is refused (E_USAGE) and never echoed back' \
  || bad "argv password: rc=$RC out=$OUT"
run "$PW\n" _agent_mail_set alpha --email=user@example.com --imap=imap.example.com --smtp=smtp.example.com --password
(( RC == 2 )) && okk 'a bare --password (no value) is refused' || bad "bare --password: rc=$RC"
if command -v script >/dev/null 2>&1; then
  cat >"$TMP/tty.sh" <<EOF
declare -A TYPE_PERSONA_FILE=([claude]=".claude/CLAUDE.md"); FIVE_REPORTED_FLAG="$TMP/reported"
source "$ROOT/src/lib/error_codes.sh"; source "$ROOT/src/lib/output.sh"; source "$ROOT/src/lib/validation.sh"
JSON_MODE=1
source "$ROOT/src/cmd_agent_mail.sh"
_agent_mail_is_root() { return 0; }
_agent_mail_set alpha ${SET_ARGS[*]}
EOF
  TT=$(timeout 20 script -qec "bash $TMP/tty.sh" /dev/null 2>&1 </dev/null); trc=$?
  (( trc == 2 )) && [[ "$TT" == *"error: --password=- reads the password from stdin; pipe it in (stdin is a terminal)"* ]] \
    && okk 'a terminal on stdin is refused (E_USAGE), measured on a real pty' || bad "tty arm: rc=$trc out=$TT"
else
  echo "skip: tty arm (no script(1))"
fi
run "ab\ncd\n" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 3 )) && [[ "$(msg)" == *newline* ]] && okk 'an embedded newline is refused (E_VALIDATION)' || bad "newline: rc=$RC $(msg)"
run "ab\rcd" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 3 )) && okk 'an embedded carriage return is refused' || bad "cr: rc=$RC $(msg)"
run "ab\0cd" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 3 )) && [[ "$(msg)" == *NUL* ]] && okk 'an embedded NUL is refused' || bad "nul: rc=$RC $(msg)"
run "" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 3 )) && okk 'an empty stdin is refused' || bad "empty: rc=$RC $(msg)"
[[ ! -e "$home/.config" ]] && okk 'no refused input wrote anything into the home' || bad 'a refused input wrote into the home'

# --- validation --------------------------------------------------------------------
run "$PW\n" _agent_mail_set alpha --email=user@example.com --imap='imap.example.com:99999' --smtp=smtp.example.com --password=-
(( RC == 3 )) && okk 'an out-of-range port is refused' || bad "port: rc=$RC"
run "$PW\n" _agent_mail_set alpha --email=user@example.com --imap='imap example.com' --smtp=smtp.example.com --password=-
(( RC == 3 )) && okk 'a host with a space is refused' || bad "host: rc=$RC"
run "$PW\n" _agent_mail_set alpha --email='not-an-email' --imap=imap.example.com --smtp=smtp.example.com --password=-
(( RC == 3 )) && okk 'a malformed email is refused' || bad "email: rc=$RC"
run "$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}" --caldav=http://cal.example.com/dav/
(( RC == 3 )) && okk 'a non-https CalDAV URL is refused' || bad "caldav http: rc=$RC"
run "$PW\n" _agent_mail_set nobody "${SET_ARGS[@]}"
(( RC == 4 )) && okk 'an unknown agent is E_NOT_FOUND' || bad "unknown agent: rc=$RC"
run "$PW\n" _agent_mail_set nouser "${SET_ARGS[@]}"
(( RC == 4 )) && [[ "$(msg)" == *"no Linux user"* ]] && okk 'an agent with no Linux user is E_NOT_FOUND' || bad "nouser: rc=$RC $(msg)"
OUT=$( { printf '%s\n' "$PW" | ( PATH="$TMP/wrap:$PATH"; JSON_MODE=1; _agent_mail_is_root() { return 1; }; _agent_mail_set alpha "${SET_ARGS[@]}" ); } 2>/dev/null); RC=$?
(( RC == 10 )) && okk 'set without root is E_PERMISSION' || bad "non-root: rc=$RC"

# --- login verification: failures persist nothing ------------------------------------
: >"$ARGV_LOG"
echo check >"$HM_MODE"
run "wrong-$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 6 )) && [[ "$(msg)" == "login_failed: IMAP AUTHENTICATE PLAIN failed: NO Invalid credentials"* ]] \
  && okk 'a refused login is E_AUTH_REQUIRED with a login_failed: message' || bad "login_failed: rc=$RC $(msg)"
[[ "$OUT$ERR" != *"wrong-$PW"* ]] && okk 'the password is scrubbed from the server text it echoed' || bad "password leaked in error: $(msg)"
[[ ! -e "$home/.config/5dive-mail" && ! -e "$home/.config/himalaya/config.toml" ]] \
  && okk 'a failed login persists nothing' || bad "failed login left: $(find "$home/.config" 2>/dev/null | tr '\n' ' ')"
[[ ! -s "$RESTART_LOG" ]] && okk 'a failed login restarts nothing' || bad "restart after failed login: $(cat "$RESTART_LOG")"
[[ -z "$(ls -A "$TMP/agenttmp")" ]] && okk 'a failed login leaves no temp dir behind' || bad "temp left: $(ls -A "$TMP/agenttmp")"
grep -q "^agent-alpha|himalaya -c $TMP/agenttmp/.* --json mailbox list$" "$ARGV_LOG" \
  && okk 'himalaya ran as the agent, against a temp config, with the global --json flag' || bad "himalaya argv: $(grep himalaya "$ARGV_LOG")"
for mode in unreach greeting noroute timeout; do
  echo "$mode" >"$HM_MODE"
  run "$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}"
  (( RC == 3 )) && [[ "$(msg)" == "mail_unreachable: "* ]] && okk "a $mode failure is E_VALIDATION with a mail_unreachable: message" \
    || bad "$mode: rc=$RC $(msg)"
done
echo unreach >"$HM_MODE"; run "$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}"
[[ "$(msg)" == "mail_unreachable: connect imap.x.invalid:993: failed to lookup address information: Name does not resolve" ]] \
  && okk 'the unreachable message carries the error and its sources' || bad "sources: $(msg)"
[[ ! -e "$home/.config/5dive-mail" && -z "$(ls -A "$TMP/agenttmp")" ]] && okk 'an unreachable server persists nothing' || bad 'unreachable persisted something'

# --- success ------------------------------------------------------------------------
: >"$ARGV_LOG"; echo check >"$HM_MODE"
printf '# my notes\nkeep me\n' >"$TMP/persona-before"
mkdir -p "$home/.claude"; cp "$TMP/persona-before" "$home/.claude/CLAUDE.md"; chmod 640 "$home/.claude/CLAUDE.md"
run "$PW\r\n" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 0 )) && [[ "$(jq -c .data <<<"$OUT")" == '{"agent":"alpha","email":"user@example.com","calendar":false,"restarted":true}' ]] \
  && okk 'a verified login connects: data {agent,email,calendar,restarted}, one envelope, and a trailing CRLF was stripped' || bad "success: rc=$RC out=$OUT err=$ERR"
[[ "$(cat "$RESTART_LOG")" == "alpha --defer" ]] && okk 'set schedules a deferred restart of the agent' || bad "restart log: $(cat "$RESTART_LOG")"
! grep -q PRE-EXISTING-MAILJSON "$ARGV_LOG" && okk 'the login ran before any permanent file existed' || bad 'mail.json existed before the login check'
m=$(stat -c %a "$home/.config/5dive-mail/password" "$home/.config/5dive-mail/mail.json" \
     "$home/.config/himalaya/config.toml" "$home/.config/5dive-mail" "$home/.config/himalaya" 2>&1 | tr '\n' ' ')
[[ "$m" == "600 600 600 700 700 " ]] && okk 'files are 0600 and their dirs 0700' || bad "modes: $m"
[[ "$(stat -c %U "$home/.config/5dive-mail/password")" == "$(id -un)" ]] && okk 'files are owned by the user the writes ran as' || bad 'owner mismatch'
[[ "$(cat "$home/.config/5dive-mail/password")" == "$PW" && "$(wc -c <"$home/.config/5dive-mail/password")" == "${#PW}" ]] \
  && okk 'the password file holds exactly the password (no newline)' || bad 'password file content wrong'
cfg="$home/.config/himalaya/config.toml"
[[ "$(head -n1 "$cfg")" == "$(_agent_mail_marker)" ]] && okk 'config.toml opens with the 5dive marker' || bad "marker: $(head -n1 "$cfg")"
grep -qx "imap.sasl.plain.password.command = \"cat $home/.config/5dive-mail/password\"" "$cfg" \
  && grep -qx 'imap.server = "imaps://imap.example.com:993"' "$cfg" && grep -qx 'smtp.server = "smtps://smtp.example.com:465"' "$cfg" \
  && ! grep -q "$PW" "$cfg" \
  && okk 'config: lowercased host, default ports, password.command cats the absolute password path, no secret' || bad "config: $(cat "$cfg")"
[[ "$(jq -c '{email,imap,smtp,caldav,calendar}' "$home/.config/5dive-mail/mail.json")" == '{"email":"user@example.com","imap":"imap.example.com:993","smtp":"smtp.example.com:465","caldav":null,"calendar":false}' ]] \
  && jq -e '.connectedAt | test("^[0-9]{4}-")' "$home/.config/5dive-mail/mail.json" >/dev/null && ! grep -q "$PW" "$home/.config/5dive-mail/mail.json" \
  && okk 'mail.json carries {email,imap,smtp,caldav,calendar,connectedAt} and no secret' || bad "mail.json: $(cat "$home/.config/5dive-mail/mail.json")"
[[ -z "$(ls -A "$TMP/agenttmp")" ]] && okk 'success cleans up its temp dir' || bad "temp left: $(ls -A "$TMP/agenttmp")"
# Every write/read of an agent path ran under runuser as the agent.
rootw=$(grep -E '^ROOT\|(dd|mv|chmod|mkdir|rm|python3|install|cat|head|test|mktemp) ' "$ARGV_LOG" | grep -F "$AGENT_HOME_ROOT" || true)
[[ -z "$rootw" ]] && grep -q '^agent-alpha|dd ' "$ARGV_LOG" && grep -q '^agent-alpha|mv -fT -- .*config.toml' "$ARGV_LOG" \
  && okk 'every touch of the agent home ran as agent-alpha; root touched none' || bad "root touched agent paths: $rootw"
# THE argv property: the log holds every external command's argv.
grep -q '|himalaya ' "$ARGV_LOG" && grep -q '|dd ' "$ARGV_LOG" && [[ $(wc -l <"$ARGV_LOG") -gt 20 ]] \
  && okk "argv recorder is live ($(wc -l <"$ARGV_LOG") child execs recorded)" || bad 'argv recorder recorded nothing'
grep -qF -- "$PW" "$ARGV_LOG" && bad "the password appeared in a child argv: $(grep -F -- "$PW" "$ARGV_LOG" | head -2)" \
  || okk 'the password is in no child process argv'
pf="$home/.claude/CLAUDE.md"
[[ "$(grep -c '<!-- 5dive:mail -->' "$pf")" == 1 && "$(head -n2 "$pf")" == "$(cat "$TMP/persona-before")" ]] \
  && grep -q 'user@example.com' "$pf" && grep -q 'NEVER send, reply, forward or delete' "$pf" && grep -q "himalaya envelope search" "$pf" \
  && okk "the agent's CLAUDE.md gets the mail block, and its own text is kept" || bad "persona: $(cat "$pf")"

[[ "$(stat -c %a "$pf")" == 640 ]] && okk "the persona file keeps its own mode" || bad "persona mode: $(stat -c %a "$pf")"

# --- replace, idempotent block, STARTTLS ports, CalDAV --------------------------------
: >"$ARGV_LOG"; printf '207' >"$CURL_CODE"
run "$PW\n" _agent_mail_set alpha --email=other@example.com --imap=imap.example.com:143 --smtp=smtp.example.com:587 \
  --caldav=https://cal.example.com/dav/cal/ --password=-
(( RC == 0 )) && [[ "$(jq -c .data <<<"$OUT")" == '{"agent":"alpha","email":"other@example.com","calendar":true,"restarted":true}' ]] \
  && okk 'set again replaces the mailbox, and a 207 CalDAV answer sets calendar:true' || bad "replace: rc=$RC $OUT $ERR"
grep -qx 'imap.server = "imap://imap.example.com:143"' "$cfg" && grep -qx 'imap.starttls = true' "$cfg" \
  && grep -qx 'smtp.server = "smtp://smtp.example.com:587"' "$cfg" && grep -qx 'smtp.starttls = true' "$cfg" \
  && okk 'port 143 / 587 are written as imap:// / smtp:// with starttls' || bad "starttls cfg: $(cat "$cfg")"
[[ "$(stat -c %a "$home/.config/5dive-mail/netrc")" == 600 ]] && grep -qx "password $PW" "$home/.config/5dive-mail/netrc" \
  && grep -qx 'machine cal.example.com' "$home/.config/5dive-mail/netrc" && okk 'the CalDAV netrc is saved 0600' || bad "netrc: $(ls -l "$home/.config/5dive-mail")"
grep -q '^agent-alpha|curl .*--netrc-file .* -X PROPFIND -H Depth: 0 -- https://cal.example.com/dav/cal/' "$ARGV_LOG" \
  && ! grep -qF -- "$PW" "$ARGV_LOG" && okk 'CalDAV is probed as the agent with a netrc file, never user:pass in argv' || bad "curl argv: $(grep curl "$ARGV_LOG")"
[[ "$(grep -c '<!-- 5dive:mail -->' "$pf")" == 1 ]] && grep -q other@example.com "$pf" && ! grep -q 'user@example.com' "$pf" \
  && grep -q 'https://cal.example.com/dav/cal/' "$pf" && okk 'the persona block is replaced in place (one block) and names the calendar' || bad "block: $(grep -c 5dive:mail "$pf")"
printf '404' >"$CURL_CODE"
run "$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}" --caldav=https://cal.example.com/dav/
(( RC == 0 )) && [[ "$(jq -r .data.calendar <<<"$OUT")" == false && ! -e "$home/.config/5dive-mail/netrc" ]] \
  && [[ "$(jq -r .caldav "$home/.config/5dive-mail/mail.json")" == https://cal.example.com/dav/ ]] \
  && okk 'a non-207 CalDAV answer still connects mail, with calendar:false and no netrc' || bad "caldav 404: rc=$RC $OUT"
[[ "$(_agent_mail_netrc h u 'abcd efgh ijkl')" == *'password "abcd efgh ijkl"'* ]] && okk 'a password with spaces is quoted in the netrc' || bad 'netrc quoting'

RESTART_RC=1
run "$PW\n" _agent_mail_set alpha "${SET_ARGS[@]}"
(( RC == 0 )) && [[ "$(jq -r .data.restarted <<<"$OUT")" == false && "$(wc -l <<<"$OUT")" == 1 ]] \
  && okk 'a restart that cannot be scheduled still connects, with restarted:false' || bad "restart fail: rc=$RC $OUT"
RESTART_RC=0

# --- a foreign himalaya config is refused before any write -----------------------------
bh="$AGENT_HOME_ROOT/agent-beta"; mkdir -p "$bh/.config/himalaya"; printf '[accounts.mine]\nemail = "me@example.com"\n' >"$bh/.config/himalaya/config.toml"
cp "$bh/.config/himalaya/config.toml" "$TMP/beta-before"
: >"$ARGV_LOG"
run "$PW\n" _agent_mail_set beta "${SET_ARGS[@]}"
(( RC == 5 )) && [[ "$(msg)" == himalaya_config_exists* ]] && cmp -s "$TMP/beta-before" "$bh/.config/himalaya/config.toml" \
  && [[ ! -e "$bh/.config/5dive-mail" ]] && ! grep -q 'himalaya -c' "$ARGV_LOG" \
  && okk 'a foreign himalaya config is refused (E_CONFLICT) before any login or write' || bad "foreign: rc=$RC $(msg)"

# --- list / show --------------------------------------------------------------------------
gh="$AGENT_HOME_ROOT/agent-gamma"; mkdir -p "$gh/.config/5dive-mail"; printf '{not json' >"$gh/.config/5dive-mail/mail.json"
run "" _agent_mail_list
[[ "$RC" == 0 && "$(jq -c .data <<<"$OUT")" == '[{"agent":"alpha","email":"user@example.com","calendar":false}]' ]] \
  && [[ "$OUT" != *"$PW"* ]] && okk 'list returns {agent,email,calendar} per connected agent, skips malformed, no secret' || bad "list: $OUT $ERR"
run "" _agent_mail_show alpha
[[ "$RC" == 0 && "$(jq -c .data <<<"$OUT")" == '{"agent":"alpha","email":"user@example.com","calendar":false}' && "$OUT" != *"$PW"* ]] \
  && okk 'show returns the one agent, no secret' || bad "show: $OUT"
run "" _agent_mail_show beta
[[ "$RC" == 0 && "$(jq -c .data <<<"$OUT")" == null ]] && okk 'show on an agent with no mailbox is data null' || bad "show none: $OUT"
run "" _agent_mail_show nobody
(( RC == 4 )) && okk 'show on an unknown agent is E_NOT_FOUND' || bad "show unknown: rc=$RC"

# --- remove -------------------------------------------------------------------------------
: >"$RESTART_LOG"
run "" _agent_mail_remove alpha
(( RC == 0 )) && [[ "$(jq -c .data <<<"$OUT")" == '{"agent":"alpha","removed":true,"restarted":true}' ]] && [[ "$(cat "$RESTART_LOG")" == "alpha --defer" ]] && [[ ! -e "$home/.config/5dive-mail" && ! -e "$cfg" ]] \
  && ! grep -q '5dive:mail' "$pf" && [[ "$(cat "$pf")" == "$(cat "$TMP/persona-before")" ]] \
  && okk 'remove deletes the files, the managed config and the persona block (the rest of the file intact)' || bad "remove: rc=$RC $OUT $(cat "$pf")"
: >"$RESTART_LOG"
run "" _agent_mail_remove alpha
(( RC == 0 )) && [[ "$(jq -c .data <<<"$OUT")" == '{"agent":"alpha","removed":false,"restarted":false}' ]] && okk 'remove is idempotent: removed:false when nothing is connected' || bad "remove again: $OUT"
[[ ! -s "$RESTART_LOG" ]] && okk 'remove with nothing connected restarts nothing' || bad "restart on no-op remove: $(cat "$RESTART_LOG")"
run "" _agent_mail_remove beta
cmp -s "$TMP/beta-before" "$bh/.config/himalaya/config.toml" && okk 'remove never deletes a foreign himalaya config' || bad 'remove deleted a foreign config'
run "" _agent_mail_remove nobody
(( RC == 4 )) && okk 'remove on an unknown agent is E_NOT_FOUND' || bad "remove unknown: rc=$RC"
run "" _agent_mail_list
[[ "$RC" == 0 && "$(jq -c .data <<<"$OUT")" == '[]' ]] && okk 'list is an empty array when nothing is connected' || bad "empty list: $OUT"

# --- the pinned himalaya install ------------------------------------------------------------
mkdir -p "$TMP/pkg/share"; printf '#!/bin/bash\necho "himalaya v2.1.0 +fixture"\n' >"$TMP/pkg/himalaya"; chmod 755 "$TMP/pkg/himalaya"
tar -czf "$TMP/fixture.tgz" -C "$TMP/pkg" himalaya share
fsha=$(sha256sum "$TMP/fixture.tgz" | awk '{print $1}')
inst() { # <sha> -> runs _agent_mail_ensure_himalaya into a fresh bin path
  local fixture_sha="$1"
  ( PATH="$TMP/wrap:$PATH"; TMPDIR="$TMP/agenttmp"
    export CURL_FIXTURE="$TMP/fixture.tgz" AGENT_MAIL_HIMALAYA_BIN="$TMP/ibin/himalaya"
    _agent_mail_himalaya_asset() { printf 'https://example.invalid/himalaya.tgz %s\n' "$fixture_sha"; }
    _agent_mail_ensure_himalaya )
}
rm -rf "$TMP/ibin"; why=$(inst 0000000000000000000000000000000000000000000000000000000000000000); irc=$?
(( irc != 0 )) && [[ "$why" == "sha256 mismatch"* && ! -e "$TMP/ibin/himalaya" ]] \
  && okk 'a sha256 mismatch refuses the install and installs nothing' || bad "sha mismatch: rc=$irc why=$why"
rm -rf "$TMP/ibin"; why=$(inst "$fsha"); irc=$?
(( irc == 0 )) && [[ "$(stat -c %a "$TMP/ibin/himalaya" 2>/dev/null)" == 755 ]] && "$TMP/ibin/himalaya" --version | grep -q '^himalaya v2.1.0' \
  && okk 'a matching sha256 installs the binary 0755' || bad "install ok: rc=$irc why=$why"
OUT=$( ( PATH="$TMP/wrap:$PATH"; TMPDIR="$TMP/agenttmp"; JSON_MODE=1; export AGENT_MAIL_HIMALAYA_BIN="$TMP/nobin/himalaya" CURL_FIXTURE="$TMP/fixture.tgz"
         _agent_mail_himalaya_asset() { printf 'https://example.invalid/h.tgz %s\n' 0000; }
         printf '%s\n' "$PW" | _agent_mail_set alpha "${SET_ARGS[@]}" ) 2>/dev/null); RC=$?
(( RC == 7 )) && [[ "$(msg)" == "himalaya_install_failed: sha256 mismatch"* ]] && okk 'set surfaces a failed install as E_NOT_INSTALLED himalaya_install_failed:' || bad "set install fail: rc=$RC $(msg)"
[[ "$(_agent_mail_himalaya_asset)" == *" "[0-9a-f]* ]] || [[ "$(uname -m)" != x86_64 && "$(uname -m)" != aarch64 ]] \
  && okk 'the pinned asset resolves for this arch' || bad 'no pinned asset for this arch'

# --- wiring ------------------------------------------------------------------------------
grep -q '^  src/cmd_agent_mail.sh$' "$ROOT/build.sh" && okk 'module is bundled' || bad 'module missing from build.sh'
grep -q 'cmd_agent_mail "\$@"' "$ROOT/src/main.sh" && okk '`agent mail` is dispatched' || bad 'agent mail not dispatched'

echo "pass=$pass fail=$fail"
(( fail == 0 ))
