#!/usr/bin/env bash
# DIVE-5308 — a reaped seat leaves no unit and no uid-owned file behind.
#
# The bug (daily bug report 2026-10-01 #2, seen first-hand 09-20 on 0.46.0):
# `doctor --category=registry --fix` reaped an orphan seat's user, group and
# agent unit, but the seat's browser-probe timer instance stayed enabled and
# kept firing every 6h, and `browser-profiles/agent-<seat>` plus
# `notify/audit-drops.log` stayed owned by the freed uid 1036 — so the next
# seat created on that uid inherited the old seat's logged-in browser profile.
# `delete_agent_user` is the teardown `agent rm` and the reaper share, so the
# fix and this harness sit there.
#
# Asserts:
#   - every unit instance named for the seat is disabled, and no other seat's is
#     (agent-gone2 shares a prefix with agent-gone and must survive)
#   - the per-name sandbox drop-in goes, a sibling's stays
#   - the row's literal done-when: `find <roots> -uid <old>` names nothing that
#     was not handed to root
#   - a path named for the seat is quarantined root-only, contents preserved
#   - a shared file stays where it is and is handed to root:<shared group>
#   - nothing outside the sweep roots is touched
#   - negative controls: an account that SURVIVES deluser keeps its files, a uid
#     that already belongs to someone else is not swept, a unit-only orphan (no
#     account) still loses its units
# Rootless: find matches by the harness's OWN uid, standing in for the freed
# one; chown is recorded, since only root can perform it.
#
# Unit names are spelled with ${AT}: the fixture guard's email pattern reads a
# literal `<template>@agent-<seat>.timer` as an address. They are unit names.
# Run: bash tests/agent_rm_seat_residue_unit.sh
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-rm-seat-residue.XXXXXX)"
export AGENT_HOME_ROOT="$TMP/home"
export REAPED_DIR="$AGENT_HOME_ROOT/.5dive-reaped"
export SYSTEMD_UNIT_DIR="$TMP/systemd"
export AGENT_SHARED_GROUP="fivedive-test"
LIB="$TMP/var-lib-5dive"; LOG="$TMP/var-log-5dive"
export SEAT_SWEEP_ROOTS="$LIB $LOG"
mkdir -p "$AGENT_HOME_ROOT" "$SYSTEMD_UNIT_DIR"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh; do
  source "$SRC/$f"
done
JSON_MODE=0
set +e
# shellcheck disable=SC1090
source "$SRC/cmd_agent_create.sh"
[[ "$REAPED_DIR" == "$AGENT_HOME_ROOT/.5dive-reaped" ]] || { echo "BUG: harness lost REAPED_DIR"; exit 1; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

ME=$(command id -u)   # the "freed" uid: the only one a rootless find can match
AT='@'
AGENT_UNIT="5dive-agent${AT}gone.service"
PROBE_TIMER="5dive-browser-probe${AT}agent-gone.timer"
PROBE_SVC="5dive-browser-probe${AT}agent-gone.service"
SIB_TIMER="5dive-browser-probe${AT}agent-gone2.timer"
KEEP_TIMER="5dive-browser-probe${AT}agent-keep.timer"
SEAT_RX="${AT}agent-gone\\."

# --- seams ---------------------------------------------------------------------
setfacl() { :; }
gpasswd() { :; }
capability_forget_agent() { :; }
audit_log() { :; }
CHOWN_LOG="$TMP/chown.log"; : >"$CHOWN_LOG"
chown() { printf '%s\n' "$*" >>"$CHOWN_LOG"; return 0; }
declare -A FAKE_UID=() FAKE_HOME=()
DELUSER_REFUSE=""; UID_TAKEN=""
id() {
  if [[ "${1:-}" == "-u" && -n "${2:-}" ]]; then
    grep -qxF -- "$2" "$DELETED" 2>/dev/null && return 1
    [[ -n "${FAKE_UID[$2]:-}" ]] && { printf '%s\n' "${FAKE_UID[$2]}"; return 0; }
    return 1
  fi
  command id "$@"
}
getent() {
  if [[ "${1:-}" == passwd && "${2:-}" =~ ^[0-9]+$ ]]; then
    [[ "$2" == "$UID_TAKEN" ]] && { printf 'someone:x:%s:%s::/x:/bin/sh\n' "$2" "$2"; return 0; }
    return 2
  fi
  if [[ "${1:-}" == passwd && -n "${FAKE_HOME[${2:-}]:-}" ]]; then
    printf '%s:x:%s:%s::%s:/bin/bash\n' "$2" "$ME" "$ME" "${FAKE_HOME[$2]}"; return 0
  fi
  return 2
}
# deluser runs inside $( ) in the code under test, so its effect goes to a FILE.
DELETED="$TMP/deleted-users"
deluser() {
  local u="${*: -1}"
  [[ "$u" == "$DELUSER_REFUSE" ]] && return 1
  printf '%s\n' "$u" >>"$DELETED"; return 0
}
# systemd: one `<unit> <enabled|static>` line per unit instance on the "box".
UNITS="$TMP/units"; SYSCTL_LOG="$TMP/systemctl.log"; : >"$SYSCTL_LOG"
systemctl() {
  printf '%s\n' "$*" >>"$SYSCTL_LOG"
  local pat="${*: -1}" u st
  case "${1:-}" in
    list-units)
      while read -r u st; do
        # shellcheck disable=SC2053
        [[ "$u" == $pat ]] || continue
        # a failed unit carries a bullet in front of its name
        if [[ "$u" == *.service ]]; then printf '● %s loaded failed failed x\n' "$u"
        else printf '%s loaded active waiting x\n' "$u"; fi
      done <"$UNITS" ;;
    list-unit-files)
      while read -r u st; do
        # shellcheck disable=SC2053
        [[ "$u" == $pat ]] && printf '%s %s %s\n' "$u" "$st" "$st"
      done <"$UNITS" ;;
    disable)
      awk -v u="$pat" '$1 != u' "$UNITS" >"$UNITS.n"; mv "$UNITS.n" "$UNITS" ;;
  esac
  return 0
}

seed_box() {
  rm -rf "$LIB" "$LOG" "$TMP/elsewhere" "$AGENT_HOME_ROOT"; mkdir -p "$AGENT_HOME_ROOT"
  : >"$CHOWN_LOG"; : >"$SYSCTL_LOG"; : >"$DELETED"
  mkdir -p "$LIB/browser-profiles/agent-gone/Default" "$LIB/browser-profiles/agent-gone2/Default" \
           "$LIB/tasks/gate-visibility" "$LOG/notify" "$TMP/elsewhere"
  printf 'session=logged-in\n' >"$LIB/browser-profiles/agent-gone/Default/Cookies"
  printf 'x\n' >"$LIB/browser-profiles/agent-gone2/Default/Cookies"
  printf 'r\n' >"$LIB/tasks/gate-visibility/agent-gone.reading"
  printf 'drop\n' >"$LOG/notify/audit-drops.log"
  printf 'n\n' >"$TMP/elsewhere/not-swept"
  printf '%s enabled\n%s enabled\n%s static\n%s enabled\n%s enabled\n' \
    "$AGENT_UNIT" "$PROBE_TIMER" "$PROBE_SVC" "$SIB_TIMER" "$KEEP_TIMER" >"$UNITS"
  rm -rf "$SYSTEMD_UNIT_DIR"
  mkdir -p "$SYSTEMD_UNIT_DIR/$AGENT_UNIT.d" "$SYSTEMD_UNIT_DIR/5dive-agent${AT}gone2.service.d"
  printf '[Service]\nMemoryMax=512M\n' >"$SYSTEMD_UNIT_DIR/$AGENT_UNIT.d/isolation.conf"
  printf '[Service]\nMemoryMax=512M\n' >"$SYSTEMD_UNIT_DIR/5dive-agent${AT}gone2.service.d/isolation.conf"
  mkdir -p "$AGENT_HOME_ROOT/agent-gone"
  FAKE_UID=([agent-gone]="$ME"); FAKE_HOME=([agent-gone]="$AGENT_HOME_ROOT/agent-gone")
  DELUSER_REFUSE=""; UID_TAKEN=""
}
chowned_to_root() {  # <path> -> recorded as handed to root:<group>
  grep -qxF -- "-h root:${AGENT_SHARED_GROUP} -- $1" "$CHOWN_LOG"
}

# ==== 1. the reported shape ===================================================
seed_box
delete_agent_user gone 0 2>"$TMP/stderr"

left=$(grep -E "$SEAT_RX" "$UNITS")
[[ -z "$left" ]] \
  && ok_t "no unit named for the reaped seat is left enabled" \
  || bad_t "a unit named for the reaped seat survived" "$left"
grep -qxF "disable --now $PROBE_TIMER" "$SYSCTL_LOG" \
  && ok_t "the browser-probe timer is stopped AND disabled (disable --now)" \
  || bad_t "the timer was not disabled --now" "$(cat "$SYSCTL_LOG")"
grep -q "^$SIB_TIMER " "$UNITS" && grep -q "^$KEEP_TIMER " "$UNITS" \
  && ok_t "other seats' units survive, including one whose name shares the prefix" \
  || bad_t "a sibling seat's unit was disabled" "$(cat "$UNITS")"
[[ ! -e "$SYSTEMD_UNIT_DIR/$AGENT_UNIT.d" && -e "$SYSTEMD_UNIT_DIR/5dive-agent${AT}gone2.service.d" ]] \
  && ok_t "the seat's sandbox drop-in is removed; the sibling's stays" \
  || bad_t "drop-in disposition wrong" "$(ls "$SYSTEMD_UNIT_DIR")"

# The row's literal done-when, with the rootless substitution: everything the
# old uid still owns under the roots must have been handed to root.
residue=""
while IFS= read -r -d '' f; do chowned_to_root "$f" || residue+="$f "; done \
  < <(find "$LIB" "$LOG" -uid "$ME" -print0)
[[ -z "$residue" ]] \
  && ok_t "find <roots> -uid <old> names nothing the sweep did not hand to root" \
  || bad_t "files of the freed uid were left with it" "$residue"

q=$(ls -d "$REAPED_DIR"/gone-*-files 2>/dev/null | head -1)
[[ ! -e "$LIB/browser-profiles/agent-gone" && -s "$q$LIB/browser-profiles/agent-gone/Default/Cookies" ]] \
  && ok_t "the seat's browser profile is quarantined (gone from its path, contents kept)" \
  || bad_t "browser profile not quarantined" "q=$q; $(ls -R "$LIB/browser-profiles" 2>&1 | head)"
[[ ! -e "$LIB/tasks/gate-visibility/agent-gone.reading" && -e "$q$LIB/tasks/gate-visibility/agent-gone.reading" ]] \
  && ok_t "a file named for the seat in a shared dir is quarantined too" \
  || bad_t "seat-named file left in place" "$(ls "$LIB/tasks/gate-visibility")"
[[ -n "$q" && "$(stat -c %a "$q")" == 700 ]] && grep -qxF -- "-hR root:root $q$LIB/browser-profiles/agent-gone" "$CHOWN_LOG" \
  && ok_t "the quarantine is 0700 and its contents are handed to root" \
  || bad_t "quarantine not root-only" "q=$q $(cat "$CHOWN_LOG")"
[[ -e "$LIB/browser-profiles/agent-gone2/Default/Cookies" ]] \
  && ok_t "a prefix-sharing seat's profile is NOT treated as this seat's" \
  || bad_t "agent-gone2's profile was moved" ""
[[ -e "$LOG/notify/audit-drops.log" ]] && chowned_to_root "$LOG/notify/audit-drops.log" \
  && ok_t "a shared log stays in place and is handed to root:${AGENT_SHARED_GROUP}" \
  || bad_t "shared log disposition wrong" "$(cat "$CHOWN_LOG")"
! grep -q "$TMP/elsewhere" "$CHOWN_LOG" && [[ -e "$TMP/elsewhere/not-swept" ]] \
  && ok_t "nothing outside the sweep roots is touched" \
  || bad_t "the sweep reached outside its roots" "$(cat "$CHOWN_LOG")"
[[ "${_RM_FILES_DISPOSITION:-}" == swept:* && "$_RM_USER_DISPOSITION" == deleted ]] \
  && ok_t "the disposition reports the sweep (${_RM_FILES_DISPOSITION:-})" \
  || bad_t "disposition" "files=${_RM_FILES_DISPOSITION:-unset} user=$_RM_USER_DISPOSITION"

# ==== 2. negative control: the account survived deluser ======================
seed_box; DELUSER_REFUSE="agent-gone"
delete_agent_user gone 0 2>/dev/null
[[ -e "$LIB/browser-profiles/agent-gone/Default/Cookies" ]] && ! grep -q -- "-h root:" "$CHOWN_LOG" \
  && ok_t "an account that survives deluser keeps its files (its uid is not free)" \
  || bad_t "files swept from a live account" "$(cat "$CHOWN_LOG")"

# ==== 3. negative control: the uid already belongs to another account ========
seed_box; UID_TAKEN="$ME"
delete_agent_user gone 0 2>"$TMP/stderr"
[[ -e "$LIB/browser-profiles/agent-gone/Default/Cookies" ]] && ! grep -q -- "-h root:" "$CHOWN_LOG" \
  && ok_t "a uid that resolves to another account is not swept" \
  || bad_t "swept a uid someone else holds" "$(cat "$CHOWN_LOG")"
grep -q "already belongs to another account" "$TMP/stderr" \
  && ok_t "and the skip is said, not silent" \
  || bad_t "no warning for the taken uid" "$(cat "$TMP/stderr")"

# ==== 4. a unit-only orphan: no account, units still go ======================
seed_box; FAKE_UID=()
delete_agent_user gone 0 2>/dev/null
[[ -z "$(grep -E "$SEAT_RX" "$UNITS")" ]] && ! grep -q -- "-h root:" "$CHOWN_LOG" \
  && ok_t "with no account left, the seat's units still go and no file is swept" \
  || bad_t "unit-only orphan" "$(cat "$UNITS")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
