#!/usr/bin/env bash
# DIVE-5805: no secret crosses sudo as environment or argv, and no seat reads the
# system journal.
#
# sudo logs every argv (`COMMAND=`) and every `--preserve-env` variable
# (`ENV=NAME=value`) WITH ITS VALUE into the journal and auth.log, and every seat
# was minted into group systemd-journal. Measured on a customer box: six live
# credentials readable by every seat. Arms:
#   A  the consolidate lane, run for real through a sudo stub that writes the
#      log lines real sudo writes and resets the environment the way it does:
#      the token still ARRIVES in the child (on stdin), and the log holds zero
#      `ENV=…TOKEN|KEY=` lines and no copy of the value. MUTANT: the pre-fix
#      `--preserve-env` call, built from the same source, goes red on both.
#   B  every channel/BYO credential writer in agent_setup.sh and the kimi writer
#      in cmd_agent_create.sh, run for real (the exact pipeline line + its
#      script): the value lands in the seat's file and never on sudo's argv.
#      MUTANT: the pre-fix `env TOKEN="$token"` line, same body, goes red.
#   C  a static sweep of every shell file outside tests/: no sudo command line
#      carries --preserve-env or a secret-named assignment. CONTROL: planted
#      pre-fix lines are caught.
#   D  create_agent_user (standard, admin, sandboxed) leaves the seat out of the
#      journal group, and a re-create drops a pre-5805 membership. MUTANT: the
#      pre-fix group string goes red.
#   E  secrets_posture_reconcile (every root heartbeat tick, every install)
#      drops every agent-* member, an orphan the registry no longer knows
#      included, keeps `claude`, and a second pass is silent.
#   F  doctor_check_journal_seats: reports members as an error, --fix removes
#      them and says a running seat keeps the read until it restarts, then ok.
# Isolation: fake OS seams + temp dirs; no root, no network, no real sudo.
# Run: bash tests/dive5805_no_secret_on_a_sudo_line_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/dive5805-unit.XXXXXX)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1${2:+ :: $2}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi; }

# Reserved fakes only. Shaped like the real thing so a pattern grep sees them.
TOK='sk-ant-oat01-not-a-real-token-5805'
BOT='1234567890:AAnot-a-real-bot-token-5805'
APIKEY='sk-not-a-real-api-key-5805'

SUDOLOG="$TMP/sudo.log"
# What real sudo writes for one invocation: the whole argv as COMMAND=, and
# ENV=NAME=value for each preserved variable. The arms grade this file.
_sudo_log() {
  local a pe=""
  for a in "$@"; do case "$a" in --preserve-env=*) pe="${a#--preserve-env=}" ;; esac; done
  printf 'COMMAND=%s\n' "$*" >> "$SUDOLOG"
  if [ -n "$pe" ]; then
    local IFS=, n
    for n in $pe; do printf 'ENV=%s=%s\n' "$n" "${!n:-}" >> "$SUDOLOG"; done
  fi
}
leaks() { grep -cE 'ENV=[A-Z_]*(TOKEN|KEY)=' "$SUDOLOG" 2>/dev/null || true; }
holds() { grep -cF -- "$1" "$SUDOLOG" 2>/dev/null || true; }

# ═══════════════ A — the consolidate lane ═══════════════
echo "== A: consolidate hands the token over stdin, and sudo logs none of it =="
SWEEP_SRC=$(awk '/^_hb_memory_consolidate_sweep\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
SEATUSER_SRC=$(awk '/^_hb_consolidate_seat_user\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
HELPERS_SRC=$(awk '/^_hb_distiller_seed_env\(\) \{/,/^\}/; /^_hb_distiller_env_feed\(\) \{/,/^\}/' "$SRC/cmd_heartbeat.sh")
VARS_SRC=$(grep -E '^_HB_DISTILLER_ENV_VARS=' "$SRC/cmd_heartbeat.sh")
if [ -z "$SWEEP_SRC" ] || [ -z "$SEATUSER_SRC" ] || [ -z "$HELPERS_SRC" ] || [ -z "$VARS_SRC" ]; then
  bad "extract the sweep, its seat resolver, the seed/feed helpers and the var list from cmd_heartbeat.sh"
else
  ok "extracted the sweep and the seed/feed helpers from cmd_heartbeat.sh"
fi
eval "$VARS_SRC"; eval "$HELPERS_SRC"; eval "$SEATUSER_SRC"
_HB_CONSOLIDATE_EVERY_MIN=360; _HB_CONSOLIDATE_TIMEOUT_S=300; _HB_CONSOLIDATE_NOTX_AFTER=4
STATE_DIR="$TMP/state"; CONNECTORS_DIR="$TMP/connectors"; ENV_DIR="$STATE_DIR/agents.d"
SELF_BIN="$TMP/fake-5dive"
export TOKEN_SEEN="$TMP/token-seen"
cat > "$SELF_BIN" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-<absent>}" >> "$TOKEN_SEEN"
printf '%s' '{"ok":true,"data":{"atoms_written":1,"processed":1,"distiller_failed":0}}'
BIN
chmod +x "$SELF_BIN"
_hb_log() { :; }
registry_read() { printf '%s' '{"agents":{"alice":{}}}'; }
id() { case "${2:-}" in agent-alice) return 0 ;; *) command id "$@" ;; esac; }
timeout() { shift; "$@"; }
# sudo -H resets the environment and the SEAT cannot read root's key files: the
# stub logs, hides the fixtures from the child, and runs it with an empty env
# plus only what --preserve-env named. So the token can arrive by exactly one
# route the real box has, and the arm says which.
sudo() {
  _sudo_log "$@"
  local -a keep=(); local pe="" a
  while [ $# -gt 0 ]; do case "$1" in
    -u) shift 2 ;; -n|-H) shift ;;
    --preserve-env=*) pe="${1#--preserve-env=}"; shift ;;
    *) break ;; esac; done
  if [ -n "$pe" ]; then local IFS=,; for a in $pe; do keep+=("$a=${!a:-}"); done; unset IFS; fi
  mv "$CONNECTORS_DIR" "$CONNECTORS_DIR.hidden"
  env -i PATH="$PATH" TOKEN_SEEN="$TOKEN_SEEN" "${keep[@]}" "$@"
  local rc=$?
  mv "$CONNECTORS_DIR.hidden" "$CONNECTORS_DIR"
  return $rc
}
run_sweep() {  # <sweep source>
  rm -rf "$STATE_DIR" "$CONNECTORS_DIR"; : > "$SUDOLOG"; : > "$TOKEN_SEEN"
  mkdir -p "$CONNECTORS_DIR"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nANTHROPIC_API_KEY=%s\n' "$TOK" "$APIKEY" > "$CONNECTORS_DIR/anthropic.env"
  eval "$1"
  # The mutant has no feed, so its `cat` must hit EOF rather than wait on ours.
  _hb_memory_consolidate_sweep 1000000000 </dev/null
}
run_sweep "$SWEEP_SRC"
check "A1 the seat's token ARRIVES in the distiller (it cannot read the file; stdin is the route)" \
  "$(grep -cxF -- "$TOK" "$TOKEN_SEEN")" "1"
check "A2 the pass is counted as distilled, not failed" "$_HB_CONS_ATOMS/$_HB_CONS_FAILED" "1/0"
check "A3 sudo logged ZERO ENV=…TOKEN|KEY= lines (the row's acceptance grep)" "$(leaks)" "0"
check "A4 and no copy of either value anywhere in what sudo logged" "$(( $(holds "$TOK") + $(holds "$APIKEY") ))" "0"
grep -q 'COMMAND=.*memory consolidate' "$SUDOLOG" \
  && ok "A5 CONTROL: the stub did log the call (a silent log would pass A3/A4 for nothing)" \
  || bad "A5 CONTROL: the stub logged no consolidate call" "$(cat "$SUDOLOG")"

# MUTANT: the DIVE-584 call, built from the same source by putting back the
# names list and --preserve-env. Must go red on A3 and A4 — or the arm is blind.
MUT_SRC=$(sed \
  -e 's/^\( *\)_hb_distiller_env_feed \\$/\1_hb_pe=$(_hb_distiller_env_feed | sed -n "s\/^export \\([A-Z_]*\\)=.*\/\\1\/p" | paste -sd, -)/' \
  -e 's/| timeout "\${_HB_CONSOLIDATE_TIMEOUT_S}" sudo -n -u/timeout "${_HB_CONSOLIDATE_TIMEOUT_S}" sudo -n ${_hb_pe:+--preserve-env="$_hb_pe"} -u/' \
  <<<"$SWEEP_SRC")
if [ "$MUT_SRC" = "$SWEEP_SRC" ]; then
  bad "A6 MUTANT could not be built (the call site moved); the instrument is unproven"
else
  run_sweep "$MUT_SRC"
  check "A6 MUTANT --preserve-env: the token still arrives (so only the log can tell them apart)" \
    "$(grep -cxF -- "$TOK" "$TOKEN_SEEN")" "1"
  [ "$(leaks)" -gt 0 ] && [ "$(holds "$TOK")" -gt 0 ] \
    && ok "A7 MUTANT --preserve-env: sudo logs ENV=CLAUDE_CODE_OAUTH_TOKEN=<value> — the instrument sees the leak" \
    || bad "A7 MUTANT --preserve-env went green; A3/A4 prove nothing" "leaks=$(leaks)"
fi
eval "$SWEEP_SRC"
unset -f sudo id timeout

# ═══════════════ B — the credential writers ═══════════════
echo "== B: every channel/BYO writer puts the value in the file and never on sudo's argv =="
# The exact pipeline line plus its script, cut out of the source and run. The
# stub logs, drops sudo's own flags, and runs the rest with HOME at a fixture.
sudo() {
  _sudo_log "$@"
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -n|-H) shift ;; *) break ;; esac; done
  HOME="$WHOME" "$@"
}
# writer_snippet <file> <TAG> — the line that opens the TAG heredoc (minus the
# `if !` / `; then` around it) through the terminator.
writer_snippet() {
  awk -v t="$2" '
    index($0, "<<\047" t "\047") { p = 1; l = $0; sub(/^[[:space:]]*if ! /, "", l); sub(/; then[[:space:]]*$/, "", l); print l; next }
    p { print; if ($0 == t) exit }' "$1"
}
run_writer() {  # <file> <TAG> [src text]
  local snip="${3:-$(writer_snippet "$1" "$2")}"
  WHOME="$TMP/home-$2"; rm -rf "$WHOME"; mkdir -p "$WHOME"; : > "$SUDOLOG"
  [ -n "$snip" ] || { echo "no snippet"; return 9; }
  ( user=$(id -un); token="$BOT"; state="$WHOME/state"; key=TELEGRAM_BOT_TOKEN; val="$BOT"
    var=KIMI_API_KEY; value="$APIKEY"; api_key="$APIKEY"; hermes_home="$WHOME/hermes"
    mkdir -p "$hermes_home"
    pairs=("TELEGRAM_BOT_TOKEN=$BOT"); eval "$snip" ) >/dev/null 2>&1
}
B_SITES="lib/agent_setup.sh:CLAUDE_TELEGRAM_STATE lib/agent_setup.sh:CLAUDE_TELEGRAM_ENV_KEY lib/agent_setup.sh:HERMES_ENV lib/agent_setup.sh:HERMES_BYO_ENV lib/agent_setup.sh:CODEX_ENV lib/agent_setup.sh:GROK_ENV lib/agent_setup.sh:AGY_ENV lib/agent_setup.sh:OPENCODE_ENV lib/agent_setup.sh:PI_ENV cmd_agent_create.sh:KIMI_ENV"
for site in $B_SITES; do
  f="$SRC/${site%%:*}"; tag="${site#*:}"
  want="$BOT"; [[ "$tag" == KIMI_ENV || "$tag" == HERMES_BYO_ENV ]] && want="$APIKEY"
  run_writer "$f" "$tag"
  landed=$(grep -rlF -- "$want" "$WHOME" 2>/dev/null | wc -l)
  if [ "$landed" -ge 1 ] && [ "$(holds "$want")" = 0 ] && grep -q '^COMMAND=' "$SUDOLOG"; then
    ok "B $tag: the value lands in the seat's file, and sudo's logged argv holds none of it"
  else
    bad "B $tag" "landed=$landed argv-copies=$(holds "$want") log=$(head -c 200 "$SUDOLOG")"
  fi
done
# OPENCLAW_CHANNEL runs the openclaw binary, so it is graded statically by C;
# its prelude shape is asserted here so it cannot drift back unnoticed.
grep -q "printf 'export PLUGIN=%q TOKEN=%q" "$SRC/lib/agent_setup.sh" \
  && ok "B OPENCLAW_CHANNEL: the token rides the stdin prelude" \
  || bad "B OPENCLAW_CHANNEL: no stdin prelude for the token"

# MUTANT: the pre-fix line for one writer, same body.
MUT=$(writer_snippet "$SRC/lib/agent_setup.sh" CODEX_ENV \
  | sed "1s/.*/sudo -u \"\$user\" -H env TOKEN=\"\$token\" bash -s <<'CODEX_ENV'/")
run_writer "$SRC/lib/agent_setup.sh" CODEX_ENV "$MUT"
[ "$(grep -rlF -- "$BOT" "$WHOME" 2>/dev/null | wc -l)" -ge 1 ] && [ "$(holds "$BOT")" -gt 0 ] \
  && ok "B MUTANT env TOKEN=…: the file is written AND the token is on sudo's logged argv — the arm sees it" \
  || bad "B MUTANT went green; the B arms prove nothing" "argv-copies=$(holds "$BOT")"
unset -f sudo

# ═══════════════ C — static sweep ═══════════════
echo "== C: no sudo command line in the product carries a secret =="
# argv_secret_hits <file...> — sudo command lines (continuations joined,
# comment lines dropped) with --preserve-env or a secret-named assignment on
# sudo's side of any pipe.
argv_secret_hits() {
  awk '
    FNR == 1 { buf = "" }
    buf == "" && /^[[:space:]]*#/ { next }
    { line = $0; if (buf == "") start = FNR }
    line ~ /\\$/ { sub(/\\$/, "", line); buf = buf line " "; next }
    { buf = buf line; print FILENAME ":" start ":" buf; buf = "" }
  ' "$@" \
  | grep -E '(^|[^A-Za-z_-])sudo[[:space:]]' \
  | grep -E 'sudo[[:space:]][^|;]*(--preserve-env|[[:space:]][A-Z_]*(TOKEN|KEY|SECRET|PASSWORD|PAIRS?|VAL)=)' \
  || true
}
mapfile -t SHFILES < <(git ls-files 2>/dev/null | grep -v '^tests/' | grep -E '(\.sh$|^install\.sh$|^bin/|^systemd/5dive-agent-start)' )
[ "${#SHFILES[@]}" -gt 20 ] && ok "C swept ${#SHFILES[@]} shell files outside tests/" \
  || bad "C the file list is too short to mean anything" "${#SHFILES[@]} files"
HITS=$(argv_secret_hits "${SHFILES[@]}")
[ -z "$HITS" ] && ok "C no sudo line carries --preserve-env or a secret-named assignment" \
  || bad "C sudo lines carrying a secret" "$HITS"
printf '%s\n' \
  '    sudo -u "$user" -H env TOKEN="$token" bash -s <<'"'"'X'"'"'' \
  '  timeout 9 sudo -n ${pe:+--preserve-env="$pe"} -u "$u" -H bash -c true' \
  '  timeout 20 sudo -u "$i" env -i \' '      BUZZ_PRIVATE_KEY="$key" "$bin" send' > "$TMP/planted.sh"
check "C CONTROL: all three planted pre-fix shapes are caught" "$(argv_secret_hits "$TMP/planted.sh" | wc -l | tr -d ' ')" "3"
printf '%s\n' "  printf '%s' \"\$key\" | sudo -u \"\$user\" env STATE=\"\$s\" python3 -c x" > "$TMP/clean.sh"
check "C CONTROL: a key piped INTO sudo is not flagged" "$(argv_secret_hits "$TMP/clean.sh" | wc -l | tr -d ' ')" "0"

# ═══════════════ D/E/F — the journal group ═══════════════
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/state.sh lib/audit.sh lib/registry.sh cmd_agent_create.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
# output.sh defines its own ok(); put the harness's counters back.
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1${2:+ :: $2}"; }
OS="$TMP/os"; mkdir -p "$OS/groups"
_sp_group_exists() { [[ -f "$OS/groups/$1" ]]; }
_sp_groupadd()     { : > "$OS/groups/$1"; }
_sp_members()      { cat "$OS/groups/$1" 2>/dev/null; }
_sp_member_add()   { printf '%s\n' "$1" >> "$OS/groups/$2"; }
_sp_member_del()   { grep -vxF "$1" "$OS/groups/$2" > "$OS/tmp"; mv "$OS/tmp" "$OS/groups/$2"; }
_sp_user_exists()  { grep -qxF "$1" "$OS/users"; }
members() { sort "$OS/groups/$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
JOURNAL_GROUP=systemd-journal

echo "== D: create_agent_user leaves the seat out of the journal group =="
export AGENT_HOME_ROOT="$TMP/homes"; mkdir -p "$AGENT_HOME_ROOT"
adduser() { mkdir -p "$AGENT_HOME_ROOT/${!#}"; printf '%s\n' "${!#}" >> "$OS/users"; }
# usermod -aG a,b user — the real effect on the fake group files.
usermod() { local g; for g in ${2//,/ }; do [[ -f "$OS/groups/$g" ]] || : > "$OS/groups/$g"; _sp_member_add "$3" "$g"; done; }
setfacl() { :; }; chgrp() { :; }
write_admin_sudoers() { :; }; write_standard_sudoers() { :; }; seed_agent_git_identity() { :; }
plugin_root_traverse_grant() { :; }; secrets_member_sync() { :; }
id() { case "${1:-}" in -u) grep -qxF "$2" "$OS/users" ;; *) command id "$@" ;; esac; }
export AGENT_SHARED_GROUP=claude
printf 'claude\n' > "$OS/users"; : > "$OS/groups/systemd-journal"; printf 'claude\n' > "$OS/groups/claude"
for iso in standard admin sandboxed; do
  create_agent_user "d$iso" "$iso" >/dev/null 2>&1
  grep -qxF "agent-d$iso" "$OS/groups/systemd-journal" \
    && bad "D a new $iso seat is in systemd-journal" "$(members systemd-journal)" \
    || ok "D a new $iso seat is NOT in systemd-journal"
done
grep -qxF agent-dstandard "$OS/groups/claude" && ! grep -qxF agent-dsandboxed "$OS/groups/claude" \
  && ok "D CONTROL: the workspace group still follows the tier (standard in, sandboxed out)" \
  || bad "D the workspace group membership changed" "$(members claude)"
printf 'agent-dstandard\n' >> "$OS/groups/systemd-journal"
create_agent_user dstandard standard >/dev/null 2>&1
grep -qxF agent-dstandard "$OS/groups/systemd-journal" \
  && bad "D a re-create kept a pre-5805 membership" || ok "D a re-create drops a pre-5805 membership"
# MUTANT: the pre-fix group string and no drop.
eval "$(declare -f create_agent_user \
  | sed -e 's/groups="\${shared_group}";/groups="${shared_group},systemd-journal";/' \
        -e 's/local groups="";/local groups="systemd-journal";/' \
        -e 's/journal_member_drop "\$user"/true/')"
: > "$OS/groups/systemd-journal"
create_agent_user dmut standard >/dev/null 2>&1
grep -qxF agent-dmut "$OS/groups/systemd-journal" \
  && ok "D MUTANT (pre-fix groups): the seat lands in systemd-journal — the arm sees it" \
  || bad "D MUTANT went green; the D arms prove nothing"
unset -f usermod adduser setfacl chgrp id

echo "== E: the posture pass (every root tick) empties the journal group of seats =="
# Only the journal half is graded here; the key half is secrets_posture_unit.sh.
secrets_group() { printf 'claude-keys'; }; : > "$OS/groups/claude-keys"
default_creds_secure() { :; }; profile_creds_secure() { :; }
export CONNECTORS_DIR="$TMP/e-conn" AUTH_PROFILES_DIR="$TMP/e-prof" FIVEDIVE_CONNECTORD_ENV="$TMP/e-none"
mkdir -p "$CONNECTORS_DIR" "$AUTH_PROFILES_DIR"
printf 'claude\nagent-olivia\nagent-dave\nagent-devops\n' > "$OS/users"
printf 'claude\nagent-olivia\nagent-devops\nagent-dave\n' > "$OS/groups/systemd-journal"
REG='{"agents":{"olivia":{"isolation":"admin"},"dave":{"isolation":"standard"}}}'   # devops: orphan
secrets_posture_reconcile --quiet "$REG" > "$TMP/e.out" 2>&1; out=$(cat "$TMP/e.out")
check "E every agent-* member is dropped — the orphan the registry forgot included" "$(members systemd-journal)" "claude"
check "E JG_DROPPED counts them" "$JG_DROPPED" "3"
grep -q 'journal posture (DIVE-5805): 3 seat' <<<"$out" && ok "E the pass says what it changed" || bad "E no summary line" "$out"
out=$(secrets_posture_reconcile --quiet "$REG" 2>&1)
[[ "$out" != *journal* ]] && ok "E a second pass changes nothing and says nothing" || bad "E second pass spoke" "$out"
rm -f "$OS/groups/systemd-journal"
secrets_posture_reconcile --quiet "$REG" >/dev/null 2>&1 && ok "E a box with no journal group is a no-op, rc 0" || bad "E no journal group: rc non-zero"

echo "== F: doctor reports a member, --fix removes it =="
eval "$(awk '/^doctor_check_journal_seats\(\) \{/,/^\}/' "$SRC/cmd_doctor.sh")"
declare -F doctor_check_journal_seats >/dev/null && ok "F extracted doctor_check_journal_seats" || bad "F doctor_check_journal_seats not found in cmd_doctor.sh"
DLOG="$TMP/doctor.log"
doctor_add() { printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-false}" "${6:-false}" >> "$DLOG"; }
printf 'claude\nagent-x\n' > "$OS/groups/systemd-journal"
: > "$DLOG"; DOCTOR_REPAIR=0; doctor_check_journal_seats
check "F without --fix: an error naming the seat, fixable" "$(cut -d'|' -f2,3,5 "$DLOG")" "journal-seats|error|true"
grep -q 'agent-x' "$DLOG" && ok "F the message names agent-x" || bad "F the message does not name the seat" "$(cat "$DLOG")"
check "F without --fix nothing is removed" "$(members systemd-journal)" "agent-x claude"
: > "$DLOG"; DOCTOR_REPAIR=1; doctor_check_journal_seats
check "F --fix: removed and repaired" "$(cut -d'|' -f3,6 "$DLOG")" "ok|true"
grep -q 'keeps the read until its next restart' "$DLOG" && ok "F --fix says a running seat keeps the read until restart" || bad "F --fix overclaims" "$(cat "$DLOG")"
check "F after --fix only claude is left" "$(members systemd-journal)" "claude"
: > "$DLOG"; DOCTOR_REPAIR=0; doctor_check_journal_seats
check "F re-run is ok" "$(cut -d'|' -f3 "$DLOG")" "ok"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
