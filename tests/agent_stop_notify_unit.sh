#!/usr/bin/env bash
# DIVE-3965 — `5dive-agent-stop-notify` is the ExecStopPost half of Codex channel
# crash parity: the notification that has to survive the death of every process
# that could otherwise have sent it.
#
# Graded by RUNNING the shipped script with the environment systemd actually
# hands an ExecStopPost (SERVICE_RESULT/EXIT_CODE/EXIT_STATUS), against a stub
# sender that records its argv. Not by sourcing the classifier: the thing that
# breaks in this file is the wiring between the classifier, the dedup mark and
# the allowFrom read, and a harness that calls one function reaches none of it.
#
# Every negative arm pins the ABSENCE of a send AND a zero exit — an
# ExecStopPost that exits non-zero turns a clean stop into a failed unit, so
# "nothing was sent" is only half of the claim being made here.
set -uo pipefail

TMP=""
trap 'rc=$?; [[ -n "$TMP" ]] && rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT

# DIVE-2211: name the tree this harness grades. No `2>/dev/null` — the helper's
# stderr line IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${ROOT}/5dive-agent-stop-notify"
[[ -x "$SUT" ]] || { echo "FAIL: $SUT is missing or not executable"; exit 1; }

TMP="$(mktemp -d)"
HOME_DIR="${TMP}/home"
mkdir -p "${HOME_DIR}/.codex/channels/telegram"
printf '{"allowFrom":["1234567890"],"groups":{},"pending":{}}\n' \
  > "${HOME_DIR}/.codex/channels/telegram/access.json"
printf '{"agents":{"tester":{"desiredState":"running"}}}\n' > "${TMP}/agents.json"

SENT="${TMP}/sent.log"
cat > "${TMP}/send-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "${2//$'\n'/ }" >> "$SENT"
STUB
chmod 755 "${TMP}/send-stub"

fails=0
pass() { echo "ok   — $1"; }
fail() { echo "FAIL — $1"; fails=$((fails+1)); }

# run <label> <result> <exit-kind> <exit-val> [extra env assignments...]
run() {
  local label="$1" result="$2" kind="$3" val="$4"; shift 4
  : > "$SENT"
  env -u TELEGRAM_STATE_DIR SERVICE_RESULT="$result" EXIT_CODE="$kind" EXIT_STATUS="$val" \
      TELEGRAM_BOT_TOKEN="stub-token" \
      STOP_NOTIFY_HOME="$HOME_DIR" \
      STOP_NOTIFY_REGISTRY="${TMP}/agents.json" \
      STOP_NOTIFY_STATE_DIR="${TMP}/state" \
      STOP_NOTIFY_SEND_CMD="${TMP}/send-stub" \
      SENT="$SENT" \
      "$@" \
      "$SUT" tester
  RC=$?
  OUT="$(cat "$SENT" 2>/dev/null)"
  [[ $RC -eq 0 ]] || fail "$label: exited $RC — an ExecStopPost must always exit 0"
}

silent() { [[ -z "$OUT" ]] && pass "$1" || fail "$1: sent '$OUT'"; }
sent_matching() {
  if grep -qE "$2" <<<"$OUT"; then pass "$1"; else fail "$1: got '$OUT', wanted /$2/"; fi
  grep -q '^1234567890	' <<<"$OUT" || fail "$1: did not address the allowFrom chat"
}

# ── 1. the quiet cases ──────────────────────────────────────────────────────
run "clean exit" success exited 0
silent "a clean exit says nothing"

run "operator stop" signal killed TERM
silent "a SIGTERM (the ordinary restart/stop path) says nothing"

rm -rf "${TMP}/state"
printf '{"agents":{"tester":{"desiredState":"stopped"}}}\n' > "${TMP}/agents.json"
run "deliberate stop" exit-code exited 1
silent "a recorded operator stop says nothing even when the exit is non-zero"
printf '{"agents":{"tester":{"desiredState":"running"}}}\n' > "${TMP}/agents.json"

# ── 2. cause awareness ──────────────────────────────────────────────────────
rm -rf "${TMP}/state"
run "oom" oom-kill killed KILL
sent_matching "an OOM kill is reported as running out of memory" 'ran out of memory'

rm -rf "${TMP}/state"
run "permanent 3" exit-code exited 3
sent_matching "a not-installed CLI says it will NOT be retried" 'NOT be retried'
grep -q 'plugin is not installed' <<<"$OUT" || fail "exit 3 must name the missing install, not just the number"

rm -rf "${TMP}/state"
run "crash loop" start-limit-hit exited 1
sent_matching "a start-limit trip says systemd gave up" 'gave up'

rm -rf "${TMP}/state"
run "sigkill" signal killed KILL
sent_matching "a SIGKILL is reported as a kill by signal" 'killed by signal KILL'

# The causes above must not be the same sentence — the whole point of the row.
rm -rf "${TMP}/state"
run "oom text" oom-kill killed KILL; oom_text="$OUT"
rm -rf "${TMP}/state"
run "exit text" exit-code exited 9; exit_text="$OUT"
[[ "$oom_text" != "$exit_text" ]] \
  && pass "two different causes produce two different sentences" \
  || fail "OOM and a bare non-zero exit produced identical text"

# ── 3. dedup, and what it must NOT swallow ──────────────────────────────────
rm -rf "${TMP}/state"
run "first crash" exit-code exited 9
[[ -n "$OUT" ]] && pass "the first crash of a window is sent" || fail "the first crash was suppressed"

run "repeat crash" exit-code exited 9
silent "an identical cause inside the window is suppressed"

run "different cause" oom-kill killed KILL
[[ -n "$OUT" ]] \
  && pass "a DIFFERENT cause inside the same window is still sent" \
  || fail "dedup swallowed a different failure — a crash-loop would hide an OOM"

# A window that has elapsed re-opens, and the message carries the count of what
# was suppressed: "it crashed" and "it has crashed 3 times" are different facts.
rm -rf "${TMP}/state"
run "t0" exit-code exited 9
run "t1" exit-code exited 9
run "t2" exit-code exited 9
run "after window" exit-code exited 9 STOP_NOTIFY_DEDUP_SECS=0
if grep -q 'further occurrence' <<<"$OUT"; then
  pass "the next message after a suppressed run reports how many were suppressed"
else
  fail "suppressed repeats were dropped without a count: '$OUT'"
fi

# ── 4. it must not send where it has no addressee or no token ───────────────
rm -rf "${TMP}/state"
: > "$SENT"
env -u TELEGRAM_BOT_TOKEN SERVICE_RESULT=oom-kill EXIT_CODE=killed EXIT_STATUS=KILL \
    STOP_NOTIFY_HOME="$HOME_DIR" STOP_NOTIFY_REGISTRY="${TMP}/agents.json" \
    STOP_NOTIFY_STATE_DIR="${TMP}/state2" STOP_NOTIFY_SEND_CMD="${TMP}/send-stub" \
    SENT="$SENT" "$SUT" tester
rc=$?
[[ $rc -eq 0 && ! -s "$SENT" ]] \
  && pass "no bot token: silent, and still exit 0" \
  || fail "no-token path sent '$(cat "$SENT")' rc=$rc"

rm -rf "${TMP}/state"
run "no access file" oom-kill killed KILL STOP_NOTIFY_HOME="${TMP}/empty-home"
silent "an agent with no paired channel state is silent"

env SERVICE_RESULT=oom-kill "$SUT" >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "a missing agent name exits 0 instead of erroring" \
               || fail "a missing agent name did not exit 0"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
