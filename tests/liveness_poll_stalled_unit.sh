#!/usr/bin/env bash
# Isolated unit harness for `5dive liveness`'s poll-stalled verdict (DIVE-7825).
#
# THE DEFECT THIS GRADES. Box report 748: after a Telegram outage a seat's
# getUpdates sat on the client's 500 s default for ~8 minutes. The owner's five
# messages queued unread while `bot.heartbeat` stayed fresh (it beats on a timer)
# and `5dive liveness` said alive (the seat had written a row recently). The
# Telegram plugin now writes `bot.lastpoll` after every poll that comes back;
# liveness reads it, and a poller that is running with a lastpoll older than
# _LIV_POLL_STALE_SEC is `poll-stalled`, which outranks alive.
#
# Arms: stale + live poller -> poll-stalled (rc 4, named file and age); fresh ->
# alive; no file (older plugin) -> unchanged; stale + exited poller -> unchanged;
# a non-claude runtime dir is read too; the real /proc path; and one mutation (the
# verdict without the poll rank) that must turn arm 1 red.
#
# Isolation: throwaway homes / proc root / task store, no root, no network.
# Run: bash tests/liveness_poll_stalled_unit.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/liveness-poll-stalled-unit.XXXXXX)" || {
  printf 'FAIL - mktemp: could not create a work dir; nothing was graded\n' >&2; exit 1; }
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh lib/tasks_db.sh \
         cmd_liveness.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done

STATE_DIR="$TMP"; TASKS_DIR="$STATE_DIR/tasks"; TASKS_DB="$TASKS_DIR/tasks.db"
export FIVEDIVE_PROD_TASKS_DB="$TASKS_DB"
REGISTRY="$STATE_DIR/agents.json"
AUDIT_LOG="$STATE_DIR/agent-audit.log"
AGENT_HOME_ROOT="$TMP/home"
_LIV_PROC_ROOT="$TMP/proc"
mkdir -p "$TASKS_DIR" "$AGENT_HOME_ROOT" "$_LIV_PROC_ROOT"
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tasks_db_init >/dev/null 2>&1
utc() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%d %H:%M:%S'; }
seed_board_done() { db "INSERT INTO tasks(ident,title,status,assignee,done_at) VALUES('$1','a row','done','$2',$(sqlq "$3"));" >/dev/null 2>&1; }

# poller <seat> <runtime> <lastpoll-age-sec|none> <pid> <live|dead>
poller() {
  local dir="$AGENT_HOME_ROOT/agent-$1/.$2/channels/telegram"
  mkdir -p "$dir"
  printf '%s\n' "$4" >"$dir/bot.pid"
  [[ "$3" == none ]] || touch -d "@$(( $(date +%s) - $3 ))" "$dir/bot.lastpoll"
  [[ "$5" == live ]] && mkdir -p "$_LIV_PROC_ROOT/$4"
}

RCFILE="$TMP/last-rc"
run() {
  JSON_MODE=0
  cmd_liveness --json "--agent=$1" --window=60 2>/dev/null
  printf '%s' "$?" >"$RCFILE"
}
rc_last() { cat "$RCFILE" 2>/dev/null; }

# Every seat below wrote a row 5 minutes ago: without the poll probe each is alive.
for s in stuck fresh old exited cdx realproc; do seed_board_done "DIVE-9${RANDOM}" "$s" "$(utc -300)"; done

# --- 1. the box report 748 shape: poller running, last poll 8 minutes ago -----
poller stuck claude 500 4242 live
j=$(run stuck); rc1=$(rc_last)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "poll-stalled" ]] \
  && ok_t "a running poller whose last poll came back 500s ago is poll-stalled, though the seat wrote a row 5m ago" \
  || bad_t "stale lastpoll + live poller -> poll-stalled" "$(jq -c '.data.seats[0] | {verdict,reason,telegramPoll}' <<<"$j")"
(( rc1 == 4 )) && ok_t "a poll-stalled seat exits 4, like no-effect and quota-exhausted" || bad_t "rc 4 on poll-stalled" "rc=$rc1"
jq -e '.data.seats[0].telegramPoll | .state == "stalled" and .lastPollAgeSec >= 499 and (.file | endswith("/.claude/channels/telegram/bot.lastpoll"))' <<<"$j" >/dev/null \
  && ok_t "the record names the file and its age, so the operator can check it by hand" \
  || bad_t "telegramPoll names file + age" "$(jq -c '.data.seats[0].telegramPoll' <<<"$j")"
jq -e '.data.seats[0].reason | test("^telegram poll stalled — the last poll came back [0-9]+s ago .*\\(last wrote board: DIVE-")' <<<"$j" >/dev/null \
  && ok_t "the reason says 'telegram poll stalled' and still names what the seat last wrote" \
  || bad_t "poll-stalled reason" "$(jq -r '.data.seats[0].reason' <<<"$j")"
jq -e '.data.summary.pollStalled == 1 and .data.summary.alive == 0' <<<"$j" >/dev/null \
  && ok_t "the summary counts it as poll-stalled, not alive" \
  || bad_t "summary.pollStalled" "$(jq -c '.data.summary' <<<"$j")"
human=$(JSON_MODE=0; cmd_liveness --agent=stuck --window=60 2>/dev/null)
grep -q '^stuck  *poll-stalled  *telegram poll stalled' <<<"$human" \
  && grep -q '1 poll-stalled' <<<"$human" \
  && grep -q 'not receiving their Telegram messages' <<<"$human" \
  && ok_t "the human table shows the verdict, the reason and the footer" \
  || bad_t "human output" "$human"

# --- 2. a fresh poll is alive, and the record says it is polling -------------
poller fresh claude 20 4343 live
j=$(run fresh)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "alive" && "$(jq -r '.data.seats[0].telegramPoll.state' <<<"$j")" == "polling" ]] \
  && (( $(rc_last) == 0 )) \
  && ok_t "a poll that came back 20s ago leaves the seat alive (rc 0, telegramPoll=polling)" \
  || bad_t "fresh lastpoll -> alive" "$(jq -c '.data.seats[0] | {verdict,telegramPoll}' <<<"$j") rc=$(rc_last)"

# --- 3. no bot.lastpoll (a plugin from before this change) -> unchanged -------
poller old claude none 4444 live
j=$(run old)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "alive" && "$(jq -r '.data.seats[0].telegramPoll.state' <<<"$j")" == "unmeasured" ]] \
  && ok_t "no lastpoll file (older plugin) is not measured and changes nothing" \
  || bad_t "absent lastpoll -> unchanged" "$(jq -c '.data.seats[0] | {verdict,telegramPoll}' <<<"$j")"

# --- 4. a stale file left by a poller that is gone is not a stalled poll ------
poller exited claude 900 4545 dead
j=$(run exited)
[[ "$(jq -r '.data.seats[0].verdict' <<<"$j")" == "alive" && "$(jq -r '.data.seats[0].telegramPoll.state' <<<"$j")" == "unmeasured" ]] \
  && ok_t "a stale lastpoll whose poller exited is not poll-stalled (the pid only suppresses, never grants)" \
  || bad_t "stale lastpoll + dead pid -> unchanged" "$(jq -c '.data.seats[0] | {verdict,telegramPoll}' <<<"$j")"

# --- 5. the forks' state dirs are read too (codex here) ----------------------
poller cdx codex 300 4646 live
[[ "$(run cdx | jq -r '.data.seats[0].verdict')" == "poll-stalled" ]] \
  && ok_t "a codex seat's ~/.codex/channels/telegram/bot.lastpoll is read the same way" \
  || bad_t "codex runtime dir" "$(run cdx | jq -c '.data.seats[0].telegramPoll')"

# --- 6. the real /proc: this shell's own pid is a live poller ---------------
( unset _LIV_PROC_ROOT
  poller realproc claude 400 "$$" dead
  [[ "$(run realproc | jq -r '.data.seats[0].verdict')" == "poll-stalled" ]] ) \
  && ok_t "with the real /proc, a live pid (this shell) and a 400s-old lastpoll read poll-stalled" \
  || bad_t "real /proc path" "$(unset _LIV_PROC_ROOT; run realproc | jq -c '.data.seats[0].telegramPoll')"

# --- MUTATION: the verdict without the poll rank must turn arm 1 red ---------
eval "$(declare -f _liv_verdict | sed '1s/_liv_verdict/_liv_verdict_REAL/')"
eval "$(declare -f _liv_verdict | sed 's/"\$poll" == "stalled"/"$poll" == "never-matches"/')"
grep -q '"stalled"' <<<"$(declare -f _liv_verdict)" \
  && bad_t "MUTATION applied" "the poll rank is still present; the mutant did not take" \
  || ok_t "MUTATION applied (the poll rank is gone from the verdict)"
[[ "$(run stuck | jq -r '.data.seats[0].verdict')" == "alive" ]] \
  && ok_t "MUTATION: without the poll rank the box report 748 seat reads ALIVE — arm 1 is RED, so its green was the rank's doing" \
  || bad_t "MUTATION turns arm 1 red" "verdict=$(run stuck | jq -r '.data.seats[0].verdict')"
eval "$(declare -f _liv_verdict_REAL | sed '1s/_liv_verdict_REAL/_liv_verdict/')"
[[ "$(run stuck | jq -r '.data.seats[0].verdict')" == "poll-stalled" && "$(_liv_verdict 1 0 unmeasured unmeasured)" == "alive" && "$(_liv_verdict 1 0 exhausted stalled)" == "quota-exhausted" ]] \
  && ok_t "restored: arm 1 is poll-stalled again; unmeasured never downgrades; quota-exhausted still ranks first" \
  || bad_t "restore" "stuck=$(run stuck | jq -r '.data.seats[0].verdict')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
