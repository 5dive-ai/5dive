#!/usr/bin/env bash
# DIVE-5807 — removing a seat that still runs a process leaves nothing behind.
#
# The bug (divine-owl box audit 2026-10-07, H3): `agent rm devops` ran in the
# same second as the seat's own cron job (supervise-hello.sh). `userdel`
# refused with exit 8 (user has a running process), so the account, its
# memberships in `claude` and `systemd-journal`, the process itself (bun
# server.js on 0.0.0.0:4411, reparented to PID 1 in cron.service) and its
# public route hello.<box> all stayed live, with the launching script deleted.
# `delete_agent_user` is the teardown `agent rm` and `doctor --fix` share, so
# the fix and this harness sit there.
#
# Asserts (REAL processes, killed by the real `kill`; only the uid lookup is a
# seam, because a rootless harness cannot run anything as another uid):
#   - a live seat process is gone after the removal, and so are the account,
#     its group memberships and the route the seat published
#   - the crontab is dropped before deluser looks (no new job can start)
#   - a process that ignores SIGTERM is still stopped (KILL follows)
#   - the measured race: a cron job that starts in the gap makes deluser refuse
#     once; the retry stops it and the account goes
#   - another seat's process and another seat's route survive
#   - the kill guard: a uid that does not resolve to this seat is never killed
#   - a half-removed seat (no account left) still loses its route
# AS ROOT ONLY (CI root-arms job; LP_REQUIRE_ROOT_ARM=1 makes a skip a failure):
# the same removal on a real account running a real process as that uid, with
# the real deluser — and the control first: deluser refuses while it runs.
#
# Run: bash tests/agent_rm_live_process_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
_lp_cleanup() {
  local p
  for p in $(cat "${TMP:-/nonexistent}"/pids-* 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  [[ -n "${REAL_USER:-}" ]] && { pkill -KILL -u "$REAL_USER" 2>/dev/null; userdel "$REAL_USER" 2>/dev/null; }
  [[ -n "${REAL_GROUP:-}" ]] && groupdel "$REAL_GROUP" 2>/dev/null
  rm -rf "${TMP:-}"
}
trap 'rc=$?; _lp_cleanup; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-rm-live-process.XXXXXX)"
export AGENT_HOME_ROOT="$TMP/home"
export REAPED_DIR="$AGENT_HOME_ROOT/.5dive-reaped"
export SYSTEMD_UNIT_DIR="$TMP/systemd"
export AGENT_SHARED_GROUP="fivedive-test"
export SEAT_SWEEP_ROOTS="$TMP/var-lib-5dive"
export RM_PROC_WAIT_TRIES=12
mkdir -p "$AGENT_HOME_ROOT" "$SYSTEMD_UNIT_DIR" "$SEAT_SWEEP_ROOTS"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
JSON_MODE=0
set +e
# shellcheck disable=SC1090
source "$SRC/cmd_agent_create.sh"
# Under `sudo -E` (the CI root arm) a set SUDO_UID makes the route code distrust
# its env and point at the box's REAL Caddyfile. Every arm stays on its temp one.
unset SUDO_UID
# shellcheck disable=SC1090
source "$SRC/cmd_route.sh"
export ROUTE_CADDYFILE="$TMP/Caddyfile" ROUTE_LOCK="$TMP/route.lock" ROUTE_RELOAD_CMD=":"

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# A process the harness does not parent (so a killed one is reaped, not a zombie
# that `kill -0` still answers for). Its pid goes into the fake uid's list.
spawn() {  # <uid> [ignore-term]
  local pid
  if [[ "${2:-}" == ignore-term ]]; then
    pid=$( (bash -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1 & echo $!) )
  else
    pid=$( (sleep 300 >/dev/null 2>&1 & echo $!) )
  fi
  printf '%s\n' "$pid" >>"$TMP/pids-$1"
  printf '%s' "$pid"
}
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) && [[ -n "$s" && "$s" != Z* ]]; }
alive_of() {  # <uid> -> the listed pids still running
  local p
  while read -r p; do [[ -n "$p" ]] && alive "$p" && printf '%s\n' "$p"; done <"$TMP/pids-$1" 2>/dev/null
  return 0
}

# --- seams (rootless arms) ------------------------------------------------------
SEAT_UID=4242; OTHER_UID=4243
setfacl() { :; }
capability_forget_agent() { :; }
audit_log() { :; }
caddy_validate() { return 0; }
chown() { :; }
ORDER="$TMP/order"
crontab()  { printf 'crontab %s\n' "$*" >>"$ORDER"; return 0; }
loginctl() { printf 'loginctl %s\n' "$*" >>"$ORDER"; return 0; }
systemctl() { return 0; }
# pgrep -U/-u <uid>: the fake uid's still-running pids. Nothing else is listed,
# so no arm can signal a process that is not its own.
pgrep() { [[ "${1:-}" == -[uU] ]] && alive_of "${2:-x}"; }
DELETED="$TMP/deleted"; GROUPS_F="$TMP/group"
UID_TAKEN=""; CRON_ONCE="$TMP/cron-fires-once"
id() {
  if [[ "${1:-}" == -u && -n "${2:-}" ]]; then
    grep -qxF -- "$2" "$DELETED" 2>/dev/null && return 1
    [[ "$2" == agent-gone || "$2" == agent-race || "$2" == agent-guard ]] && { echo "$SEAT_UID"; return 0; }
    return 1
  fi
  command id "$@"
}
getent() {
  if [[ "${1:-}" == passwd && "${2:-}" == "$SEAT_UID" ]]; then
    [[ -n "$UID_TAKEN" ]] && { printf 'someone:x:%s:%s::/x:/bin/sh\n' "$2" "$2"; return 0; }
    grep -qxF -- "$CUR" "$DELETED" 2>/dev/null && return 2
    printf '%s:x:%s:%s::%s:/bin/bash\n' "$CUR" "$2" "$2" "$AGENT_HOME_ROOT/$CUR"; return 0
  fi
  if [[ "${1:-}" == passwd && "${2:-}" == agent-* ]]; then
    printf '%s:x:%s:%s::%s:/bin/bash\n' "$2" "$SEAT_UID" "$SEAT_UID" "$AGENT_HOME_ROOT/$2"; return 0
  fi
  [[ "${1:-}" == group ]] && { grep "^${2:-}:" "$GROUPS_F"; return; }
  return 2
}
gpasswd() { :; }
# userdel's real rule: refuse (exit 8) while the user runs a process. Success
# drops the account from every group, as deluser does. The cron race: on its
# first call it starts a new job as the seat, then refuses. (deluser runs inside
# $( ) in the code under test, so the one-shot flag is a FILE.)
deluser() {
  local u="${*: -1}"
  printf 'deluser %s\n' "$u" >>"$ORDER"
  if [[ -e "$CRON_ONCE" ]]; then rm -f "$CRON_ONCE"; spawn "$SEAT_UID" >/dev/null
    echo "userdel: user $u is currently used by process" >&2; return 8; fi
  if [[ -n "$(alive_of "$SEAT_UID")" ]]; then
    echo "userdel: user $u is currently used by process" >&2; return 8
  fi
  printf '%s\n' "$u" >>"$DELETED"
  sed -i -E "s/([:,])${u}(,|\$)/\\1\\2/; s/,,/,/; s/:,/:/; s/,\$//" "$GROUPS_F"
  return 0
}

seed() {  # <seat>
  CUR="agent-$1"
  for f in "$TMP"/pids-*; do [[ -e "$f" ]] && { while read -r p; do kill -KILL "$p" 2>/dev/null; done <"$f"; rm -f "$f"; }; done
  : >"$ORDER"; : >"$DELETED"
  printf '%s\n' "${AGENT_SHARED_GROUP}:x:1000:agent-keep,agent-$1" "systemd-journal:x:999:agent-$1" >"$GROUPS_F"
  printf 'example.test {\n    respond "box"\n}\n\n# 5dive-route:begin hello port=4411 by=%s\nhello.example.test {\n    reverse_proxy 127.0.0.1:4411\n}\n# 5dive-route:end hello\n\n# 5dive-route:begin keepapp port=4412 by=keep\nkeepapp.example.test {\n    reverse_proxy 127.0.0.1:4412\n}\n# 5dive-route:end keepapp\n' "$1" >"$ROUTE_CADDYFILE"
  UID_TAKEN=""; rm -f "$CRON_ONCE"
}
in_any_group() { grep -E "[:,]agent-$1(,|\$)" "$GROUPS_F"; }

# ==== 1. the reported shape: a live process at removal =========================
seed gone
P=$(spawn "$SEAT_UID"); KEEP=$(spawn "$OTHER_UID")
delete_agent_user gone 0 2>"$TMP/stderr"
! alive "$P" \
  && ok_t "the seat's live process is gone after the removal" \
  || bad_t "the seat's process survived the removal" "pid $P"
grep -qxF agent-gone "$DELETED" && [[ "$_RM_USER_DISPOSITION" == deleted ]] \
  && ok_t "the account is deleted (deluser no longer refuses)" \
  || bad_t "the account survived" "disp=$_RM_USER_DISPOSITION; $(cat "$ORDER"); $(cat "$TMP/stderr")"
[[ -z "$(in_any_group gone)" ]] \
  && ok_t "no group membership is left (${AGENT_SHARED_GROUP}, systemd-journal)" \
  || bad_t "a group membership survived" "$(in_any_group gone)"
! grep -q 'hello' "$ROUTE_CADDYFILE" && [[ "$_RM_ROUTES_DISPOSITION" == "removed:hello" ]] \
  && ok_t "the route the seat published is removed" \
  || bad_t "the seat's route survived" "disp=$_RM_ROUTES_DISPOSITION; $(cat "$ROUTE_CADDYFILE")"
grep -q 'keepapp.example.test' "$ROUTE_CADDYFILE" && grep -q 'respond "box"' "$ROUTE_CADDYFILE" \
  && ok_t "another seat's route and the box's own site are untouched" \
  || bad_t "a route that is not the seat's was touched" "$(cat "$ROUTE_CADDYFILE")"
alive "$KEEP" \
  && ok_t "another uid's process is not touched" \
  || bad_t "another uid's process was killed" "pid $KEEP"
c=$(grep -n '^crontab -u agent-gone -r$' "$ORDER" | head -1 | cut -d: -f1)
d=$(grep -n '^deluser agent-gone$' "$ORDER" | head -1 | cut -d: -f1)
[[ -n "$c" && -n "$d" ]] && (( c < d )) \
  && ok_t "the crontab is dropped before deluser looks" \
  || bad_t "crontab not dropped before deluser" "$(cat "$ORDER")"
grep -qxF 'loginctl terminate-user agent-gone' "$ORDER" \
  && ok_t "the seat's login sessions are terminated" \
  || bad_t "loginctl terminate-user not run" "$(cat "$ORDER")"
[[ "$_RM_PROCS_DISPOSITION" == "stopped:1" ]] \
  && ok_t "the receipt says one process was stopped" \
  || bad_t "process disposition wrong" "$_RM_PROCS_DISPOSITION"

# ==== 2. a process that ignores SIGTERM ========================================
seed gone
P=$(spawn "$SEAT_UID" ignore-term)
delete_agent_user gone 0 2>"$TMP/stderr"
! alive "$P" && grep -qxF agent-gone "$DELETED" \
  && ok_t "a process that ignores SIGTERM is still stopped (KILL follows) and the account goes" \
  || bad_t "a TERM-ignoring process survived" "pid $P; $(cat "$TMP/stderr")"

# ==== 3. the measured race: cron starts a job in the gap ========================
seed race
P=$(spawn "$SEAT_UID"); : >"$CRON_ONCE"
delete_agent_user race 0 2>"$TMP/stderr"
[[ $(grep -c '^deluser agent-race$' "$ORDER") == 2 ]] && grep -qxF agent-race "$DELETED" \
  && [[ -z "$(alive_of "$SEAT_UID")" ]] \
  && ok_t "a job that starts in the gap makes deluser refuse once; the retry stops it and the account goes" \
  || bad_t "the cron race left the seat behind" "$(cat "$ORDER"); alive=$(alive_of "$SEAT_UID"); $(cat "$TMP/stderr")"

# ==== 4. the kill guard ========================================================
seed guard
P=$(spawn "$SEAT_UID"); UID_TAKEN=1
delete_agent_user guard 0 2>"$TMP/stderr"
alive "$P" && [[ "$_RM_PROCS_DISPOSITION" == none ]] \
  && ok_t "a uid that does not resolve to this seat is never signalled" \
  || bad_t "the kill guard let a foreign uid be signalled" "pid $P disp=$_RM_PROCS_DISPOSITION"
[[ "$_RM_USER_DISPOSITION" == present ]] && grep -q 'SURVIVED' "$TMP/stderr" \
  && ok_t "and the refused account is reported loudly, not as removed" \
  || bad_t "a refused account was not reported" "disp=$_RM_USER_DISPOSITION; $(cat "$TMP/stderr")"

# ==== 5. half-removed seat: no account, route still public ======================
seed ghost
delete_agent_user ghost 0 2>"$TMP/stderr"
! grep -q 'hello' "$ROUTE_CADDYFILE" && grep -q keepapp "$ROUTE_CADDYFILE" \
  && ok_t "a seat whose account is already gone still loses its route (the doctor --fix path)" \
  || bad_t "a half-removed seat's route survived" "$(cat "$ROUTE_CADDYFILE")"

# ==== 6. route rm after the refactor: byte for byte ============================
printf 'site {\n}\n' >"$ROUTE_CADDYFILE"; cp "$ROUTE_CADDYFILE" "$TMP/before"
printf '\n# 5dive-route:begin x port=5000 by=a\nx.e {\n}\n# 5dive-route:end x\n' >>"$ROUTE_CADDYFILE"
_route_strip "$ROUTE_CADDYFILE" x >"$TMP/after"
cmp -s "$TMP/before" "$TMP/after" \
  && ok_t "stripping a route block leaves the file byte for byte as before it was added" \
  || bad_t "route strip is not the inverse of add" "$(diff "$TMP/before" "$TMP/after")"

# ==== 7. AS ROOT: a real account, a real process, the real deluser ==============
if [[ $EUID -ne 0 ]]; then
  if [[ "${LP_REQUIRE_ROOT_ARM:-0}" == 1 ]]; then bad_t "R1 root arm required but not root" "EUID=$EUID"
  else printf 'skip - R1 root arm (not root; CI root-arms runs it with LP_REQUIRE_ROOT_ARM=1)\n'; fi
else
  unset -f id getent deluser pgrep crontab loginctl gpasswd systemctl chown
  command -v deluser >/dev/null || bad_t "R1 deluser is installed" "missing"
  REAL_USER="agent-lp5807"; REAL_GROUP="fivedive-lp5807"
  export AGENT_SHARED_GROUP="$REAL_GROUP"
  groupadd "$REAL_GROUP" && useradd -M -d "$AGENT_HOME_ROOT/$REAL_USER" -s /bin/bash -G "$REAL_GROUP" "$REAL_USER"
  ruid=$(command id -u "$REAL_USER")
  ( setsid setpriv --reuid="$ruid" --regid="$ruid" --clear-groups sleep 300 >/dev/null 2>&1 & )
  sleep 0.5
  rp=$(pgrep -u "$ruid" | head -1)
  # Control: the bug's premise, on this kernel — deluser refuses a running user.
  deluser --quiet "$REAL_USER" >/dev/null 2>&1; crc=$?
  command id -u "$REAL_USER" >/dev/null 2>&1 && [[ -n "$rp" ]] && (( crc != 0 )) \
    && ok_t "R1 control: deluser refuses an account with a live process (rc $crc)" \
    || bad_t "R1 control did not reproduce the refusal" "rc=$crc pid=$rp"
  printf 'x.example.test {\n}\n\n# 5dive-route:begin lpapp port=4999 by=lp5807\nlpapp.example.test {\n    reverse_proxy 127.0.0.1:4999\n}\n# 5dive-route:end lpapp\n' >"$ROUTE_CADDYFILE"
  delete_agent_user lp5807 0 2>"$TMP/stderr"
  [[ -z "$(pgrep -u "$ruid")" ]] \
    && ok_t "R1 no process runs as the removed uid" || bad_t "R1 a process survived" "$(pgrep -a -u "$ruid")"
  ! command id -u "$REAL_USER" >/dev/null 2>&1 \
    && ok_t "R1 the account is gone" || bad_t "R1 the account survived" "$(cat "$TMP/stderr")"
  ! getent group "$REAL_GROUP" | cut -d: -f4 | tr ',' '\n' | grep -qx "$REAL_USER" \
    && ok_t "R1 no group membership is left" || bad_t "R1 group membership survived" "$(getent group "$REAL_GROUP")"
  ! grep -q lpapp "$ROUTE_CADDYFILE" \
    && ok_t "R1 the seat's route is gone" || bad_t "R1 the route survived" "$(cat "$ROUTE_CADDYFILE")"
fi

echo
echo "agent_rm_live_process_unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
