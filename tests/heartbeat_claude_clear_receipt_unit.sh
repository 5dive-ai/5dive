#!/usr/bin/env bash
# TIER: core
#
# DIVE-8269 — a claude seat's /clear that already ran was marked WEDGED.
#
# Measured 2026-11-11: `[vesper] … wake failed at /clear injection (rc 1): submit
# unverified (rc 1): the composer still held 6 chars of non-ghost text after 2
# Enters ('/clear') — the draft has been CLEARED and the seat marked wedged`,
# while vesper's new session file began `<command-name>/clear</command-name>`
# ~1 s BEFORE that line (quinn 02:40:08Z on DIVE-8174: same shape). The pane
# read is the witness that misfired; the rotated transcript is the receipt.
#
#   R1     /clear + stale pane + a NEW transcript starting with /clear -> accepted
#   R2..   negative controls: no new file / the mark file itself / a new file
#          that is not a /clear / no mark at all / a non-/clear payload
#   R6     the receipt that lands while we poll is still taken
#   M..    mutation arms: the accept removed, the new-file test removed
#
# Reserved-fake values only: seat 'seatx' does not exist, transcripts live under
# $TMP (the _HB_TRANSCRIPT_ROOT seam), sudo is a function, no live pane is touched.
set -uo pipefail
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: one trap, every exit path.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 not present"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }
TMP=$(mktemp -d /tmp/hb-clear-receipt.XXXXXX)
# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh \
         lib/tasks_db.sh lib/actor.sh cmd_task.sh cmd_org.sh cmd_agent.sh \
         cmd_agent_runtime.sh cmd_heartbeat.sh cmd_supervisor.sh; do
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"                       # the wedge ledger lands under $TMP
_HB_TRANSCRIPT_ROOT="$TMP/projects"    # the seat's ~/.claude/projects, faked
PROJ="$_HB_TRANSCRIPT_ROOT/-home-claude-projects-x"
KEYS="$TMP/keys"; PANE_I="$TMP/pane_i"; LOG="$TMP/log"; SLEEPS="$TMP/sleeps"
PANES=()
ROTATE_AT=""        # "enter" = the new session file appears on the first Enter; "sleep:N" = on the Nth sleep
ROTATE_BODY=""      # the new session file's content
_rotate() { printf '%s' "$ROTATE_BODY" >"$PROJ/new-session.jsonl"; ROTATE_AT=""; }
_reset() {
  : >"$KEYS"; : >"$LOG"; echo 0 >"$PANE_I"; echo 0 >"$SLEEPS"; rm -rf "$TMP/composer-wedge" "$_HB_TRANSCRIPT_ROOT"
  mkdir -p "$PROJ"
  printf '%s\n' "${OLD_BODY:-$OLD_SESSION}" >"$PROJ/old-session.jsonl"
  touch -d '-1 hour' "$PROJ/old-session.jsonl"
  ROTATE_AT=""; ROTATE_BODY=""
}
sudo() {
  while [ $# -gt 0 ]; do case "$1" in -u) shift 2;; -n|-H) shift;; *) break;; esac; done
  case "${1:-}" in mkdir|chown|chmod|rm|cat|bash|head|stat|tail) "$@"; return $?;; esac
  [[ "${1:-}" == tmux ]] || return 0
  shift
  case "${1:-}" in
    send-keys) shift; while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) shift;; --) shift; break;; *) break;; esac; done
               printf '%s\n' "$*" >>"$KEYS"
               [[ "$*" == Enter && "$ROTATE_AT" == enter ]] && _rotate
               return 0;;
    capture-pane) local i n; i=$(cat "$PANE_I"); n=${#PANES[@]}; (( i >= n )) && i=$((n-1))
               echo $(( $(cat "$PANE_I") + 1 )) >"$PANE_I"; printf '%b' "${PANES[$i]}"; return 0;;
  esac
  return 0
}
_agent_delivery_inbox()    { return 1; }   # no dispatcher inbox: the tmux path under test
_agent_pane_safe_to_type() { return 0; }
_hb_claude_pid()           { printf '4242'; }   # a CLAUDE seat: the branch under test
_hb_landed_check()         { return 1; }        # never let the DIVE-4279 arm mask a submit arm
_hb_log()                  { printf '%s\n' "$*" >>"$LOG"; }
sleep() {
  local n; n=$(( $(cat "$SLEEPS") + 1 )); echo "$n" >"$SLEEPS"
  [[ "$ROTATE_AT" == "sleep:$n" ]] && _rotate
  return 0
}
_REAL_RECEIPT="$(declare -f _hb_clear_receipt)"
PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
not_ok(){ FAIL=$((FAIL+1)); printf 'not ok - %s\n' "$1"; }
grade() { if eval "$2"; then ok_t "$1"; else not_ok "$1"; fi; }
cus()   { grep -cx 'C-u' "$KEYS"; }
wedged(){ [[ -s "$TMP/composer-wedge/seatx" ]]; }

E=$'\e'; NB=$'\xc2\xa0'
P_EMPTY="${E}[39m❯${NB} ${E}[39m\n  Opus 5 5h: 3%\n"
P_CLR="${E}[39m❯${NB} ${E}[39m/clear\n  Opus 5 5h: 3%\n"       # the stale read: '/clear' still in the composer
# The LIVE head of a post-/clear session file (Claude Code 2.1.322, this box,
# 2026-11-12): mode + snapshot lines, an isMeta caveat user record, THEN the
# /clear record. The caveat is a user record too, so "first user record" must
# skip isMeta or the receipt never matches a real file.
OLD_SESSION='{"type":"user","message":{"role":"user","content":"earlier work"},"uuid":"o1"}'
CLEAR_HEAD='{"type":"mode","mode":"normal","sessionId":"s2"}
{"type":"file-history-snapshot","messageId":"m1","snapshot":{}}
{"parentUuid":null,"type":"user","message":{"role":"user","content":"<local-command-caveat>The command below was run directly in Claude Code</local-command-caveat>"},"isMeta":true,"uuid":"u1"}
{"parentUuid":"u1","type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"},"uuid":"u2"}
{"parentUuid":"u2","type":"system","subtype":"local_command","content":"<local-command-stdout></local-command-stdout>"}
'
RESTART_HEAD='{"type":"mode","mode":"normal","sessionId":"s3"}
{"parentUuid":null,"type":"user","message":{"role":"user","content":"continue"},"uuid":"r1"}
{"parentUuid":"r1","type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"},"uuid":"r2"}
'
META_ONLY='{"type":"mode","mode":"normal","sessionId":"s4"}
{"parentUuid":null,"type":"user","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"},"isMeta":true,"uuid":"q1"}
'
ONELINE='/goal DIVE-8269 — your only row this turn. Stop after 6 turns.'
STALE=("$P_EMPTY" "$P_CLR" "$P_CLR" "$P_EMPTY")   # scrub reads empty; both settle reads still show /clear; the clear verifies

# --------------------------------------------------------------- R1: the accept
_reset; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear"; rc=$?
grade "R1a /clear whose pane still reads '/clear' after 2 Enters, but whose session ROTATED to a /clear-first file, returns 0" "[[ $rc -eq 0 ]]"
grade "R1b ...and the seat is NOT written to the wedge ledger" "! wedged"
grade "R1c ...and the composer is NOT cleared after the Enters (one C-u: the pre-type one)" "[[ \$(cus) -eq 1 ]]"
grade "R1d ...and one log line names the receipt: the new transcript, the old one, and DIVE-8269" \
      "[[ \$(grep -c '/clear ACCEPTED.*DIVE-8269' '$LOG') -eq 1 ]] && grep -q 'new-session.jsonl' '$LOG' && grep -q 'old-session.jsonl' '$LOG'"
grade "R1e ...and no failure reason is left behind for the wake to report" "[[ -z \"\$_HB_SEND_FAIL_REASON\" ]]"

# A stale ledger entry is forgotten on the accept, exactly as on a verified submit.
_reset; _wedge_mark seatx 6 '/clear' cleared
PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear"; rc=$?
grade "R1f an accepted /clear clears a previous wedge entry for the seat" "[[ $rc -eq 0 ]] && ! wedged"

# ------------------------------------------------------ R2..R5: negative controls
_reset; PANES=("${STALE[@]}")
_hb_send_line seatx "/clear"; rc=$?
grade "R2a NO new transcript since the mark: unchanged — rc 1" "[[ $rc -eq 1 ]]"
grade "R2b ...the seat is marked wedged" "wedged"
grade "R2c ...the composer is cleared after the Enters" "[[ \$(cus) -ge 2 ]]"
grade "R2d ...and the reason is the DIVE-4642 message" \
      "[[ \"\$_HB_SEND_FAIL_REASON\" == *'CLEARED'* && \"\$_HB_SEND_FAIL_REASON\" == *'DIVE-4642'* ]]"

# The newest file AT THE MARK already starts with /clear (an earlier wake's): it
# is not a rotation, so it is not a receipt for THIS /clear.
OLD_BODY="$CLEAR_HEAD"; _reset; unset OLD_BODY; PANES=("${STALE[@]}")
_hb_send_line seatx "/clear"; rc=$?
grade "R2e the mark's OWN file starting with /clear is not a rotation — rc 1, wedged" "[[ $rc -eq 1 ]] && wedged"

_reset; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$RESTART_HEAD"
_hb_send_line seatx "/clear"; rc=$?
grade "R3a a NEW transcript whose first user record is not /clear (a restart) is not the receipt — rc 1, wedged" \
      "[[ $rc -eq 1 ]] && wedged && ! grep -q '/clear ACCEPTED' '$LOG'"

_reset; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$META_ONLY"
_hb_send_line seatx "/clear"; rc=$?
grade "R3b a new file holding only an isMeta caveat (no command record) is not the receipt — rc 1" "[[ $rc -eq 1 ]] && wedged"

# No mark: the store was empty/unreadable before the first keystroke, so nobody
# can say the file is NEW — cannot tell, so no accept (DIVE-2159).
_reset; rm -f "$PROJ/old-session.jsonl"; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear"; rc=$?
grade "R3c no transcript at the mark: a /clear-first file afterwards is not accepted (cannot tell new) — rc 1" "[[ $rc -eq 1 ]] && wedged"

_reset; PANES=("$P_EMPTY" "${E}[39m❯${NB} ${E}[39m${ONELINE}\n" "${E}[39m❯${NB} ${E}[39m${ONELINE}\n" "$P_EMPTY")
ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "$ONELINE"; rc=$?
grade "R4a a NON-control payload is untouched: a rotated /clear session does not excuse an unsent goal — rc 1, wedged" \
      "[[ $rc -eq 1 ]] && wedged && ! grep -q '/clear ACCEPTED' '$LOG'"

_reset; PANES=("$P_EMPTY" "${E}[39m❯${NB} ${E}[39m/compact\n" "${E}[39m❯${NB} ${E}[39m/compact\n" "$P_EMPTY")
ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/compact"; rc=$?
grade "R5a /compact is out of scope (it does not rotate the file): unchanged — rc 1, wedged" "[[ $rc -eq 1 ]] && wedged"

# ------------------------------------------------- R6: the receipt lands late
# The rotation is ~1 s; the check polls, so a file that appears between polls
# is still taken. Count the sleeps _hb_send_line makes up to the receipt check,
# then rotate on the first poll's sleep.
_reset; PANES=("${STALE[@]}"); _hb_clear_receipt() { echo "$(cat "$SLEEPS")" >"$TMP/sleeps_at_check"; return 1; }
_hb_send_line seatx "/clear" >/dev/null 2>&1
BASE=$(cat "$TMP/sleeps_at_check"); eval "$_REAL_RECEIPT"
_reset; PANES=("${STALE[@]}"); ROTATE_AT="sleep:$((BASE + 1))"; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear"; rc=$?
grade "R6a a rotation that lands while the receipt check is polling is accepted — rc 0, not wedged" "[[ $rc -eq 0 ]] && ! wedged"

# ------------------------------------------------------------- mutation arms
_hb_clear_receipt() { return 1; }                              # M1: the accept removed
_reset; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear" >/dev/null 2>&1; rc=$?
grade "M1 MUTANT (no receipt accept): R1's exact fixture goes back to rc 1 + wedged, so R1a/R1b are live" "[[ $rc -eq 1 ]] && wedged"
eval "$_REAL_RECEIPT"

# M2: the new-file test removed — the mark's own /clear-first file now passes.
eval "$(declare -f _hb_clear_receipt | sed 's/ && "\$now_file" != "\$_HB_LANDED_FILE"//')"
OLD_BODY="$CLEAR_HEAD"; _reset; unset OLD_BODY; PANES=("${STALE[@]}")
_hb_send_line seatx "/clear" >/dev/null 2>&1; rc=$?
grade "M2 MUTANT (no 'new file' test): R2e's fixture is accepted, so R2e is live" "[[ $rc -eq 0 ]]"
eval "$_REAL_RECEIPT"

# M3: the isMeta skip removed — the live file's caveat record becomes 'first', so R1 can never match.
eval "$(declare -f _hb_clear_receipt | sed 's/isMeta/zzNoSuchKey/')"
_reset; PANES=("${STALE[@]}"); ROTATE_AT=enter; ROTATE_BODY="$CLEAR_HEAD"
_hb_send_line seatx "/clear" >/dev/null 2>&1; rc=$?
grade "M3 MUTANT (no isMeta skip): the LIVE-shaped file is rejected, so the fixture carries the real caveat record" "[[ $rc -eq 1 ]]"
eval "$_REAL_RECEIPT"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
