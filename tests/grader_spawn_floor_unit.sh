#!/usr/bin/env bash
# DIVE-4164 isolated unit harness — the ephemeral grader's SPAWN FLOOR.
#
# The row: `task deliver` spawns a short-lived grader, N in parallel, capped by
# the auth window. This grades the cap's decision function, `_grader_window_ok`.
#
# THE ARM THAT MATTERS IS THE NULL ONE, and it is not hypothetical. Measured on
# the live fleet 2026-09-09 via `sudo 5dive usage --json`: SIX OF FOURTEEN seats
# reported fiveHourPct=null (marketing, warm-mark, creative, olivia, dev2, don),
# and chemmonitor reported null for BOTH fields. A floor written the obvious way
# — `(( pct < 80 ))` — evaluates an empty operand as ZERO in bash, so those seats
# read as 0% used and spawn. The cap would fail OPEN on exactly the seats it
# knows least about, on 43% of the fleet, silently. Arms 1/2/3 below are that
# defect's negative controls and they are the reason this file exists.
#
# Sources src/ directly, touches no state, needs no root and no live meter: the
# usage JSON is a fixture on stdin.
# Run: bash tests/grader_spawn_floor_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src

# shellcheck source=/dev/null
source "$SRC/task/grader_pool.sh"

PASS=0; FAIL=0
# want_rc: 0 = spawn, 1 = refuse (blind/unusable meter), 2 = queue (over floor)
check() { # <name> <want_rc> <want_substring> <account> <json>
  local name="$1" want_rc="$2" want_sub="$3" acct="$4" json="$5" out rc
  out=$(printf '%s' "$json" | _grader_window_ok "$acct"); rc=$?
  if [[ "$rc" == "$want_rc" && "$out" == *"$want_sub"* ]]; then
    PASS=$((PASS+1)); printf 'ok   %-52s rc=%s\n' "$name" "$rc"
  else
    FAIL=$((FAIL+1))
    printf 'FAIL %-52s want rc=%s ~%q · got rc=%s %q\n' "$name" "$want_rc" "$want_sub" "$rc" "$out"
  fi
}

# The real shape of `5dive usage --json`, trimmed to the fields the floor reads.
j() { printf '{"agents":[%s]}' "$1"; }
MARK='{"account":"mark","name":"dev","fiveHourPct":50,"sevenDayPct":70}'
MARK2='{"account":"mark","name":"ops","fiveHourPct":49,"sevenDayPct":70}'

# ── 1-3: THE MEASURED DEFECT. A null meter must REFUSE, never read as 0%. ─────
check 'null 5h refuses (the dev2/olivia shape)' 1 'no 5h reading' mark \
      "$(j '{"account":"mark","name":"dev2","fiveHourPct":null,"sevenDayPct":63}')"
check 'null weekly refuses'                     1 'no weekly reading' mark \
      "$(j '{"account":"mark","name":"x","fiveHourPct":50,"sevenDayPct":null}')"
check 'both null refuses (chemmonitor shape)'   1 'no 5h reading' chemmonitor \
      "$(j '{"account":"chemmonitor","name":"warm-mark","fiveHourPct":null,"sevenDayPct":null}')"
# The account is absent from the report entirely — same blindness, same answer.
check 'unknown account refuses'                 1 'no 5h reading' nosuch "$(j "$MARK")"

# ── 4-6: the meter is missing or unusable at the source ──────────────────────
check 'empty json refuses'                      1 'returned nothing' mark ''
check 'no account named refuses'                1 'no account named' '' "$(j "$MARK")"

# ── 7-8: the happy path, and it must still be reachable ──────────────────────
check 'mark at 50/70 spawns'                    0 'ok: mark at 5h=50% 7d=70%' mark "$(j "$MARK")"
check 'float weekly parses (56.999...)'         0 'ok:' mark \
      "$(j '{"account":"mark","name":"marketing","fiveHourPct":10,"sevenDayPct":56.99999999999999}')"

# ── 9-11: over the floor QUEUES (rc=2) — distinct from a blind refusal ───────
check '5h at the floor queues'                  2 'of its 5h window' mark \
      "$(j '{"account":"mark","name":"dev","fiveHourPct":80,"sevenDayPct":10}')"
check 'weekly at 99 queues (mp-team shape)'     2 'of its weekly window' mp-team \
      "$(j '{"account":"mp-team","name":"community","fiveHourPct":6,"sevenDayPct":99}')"
check '5h just under the floor still spawns'    0 'ok:' mark \
      "$(j '{"account":"mark","name":"dev","fiveHourPct":79,"sevenDayPct":10}')"

# ── 12: PER-ACCOUNT, not per-seat. mark's nine seats share ONE window, so two
# rows for the same account must yield ONE answer, not two budgets. ───────────
check 'two seats of one account read one window' 0 'ok: mark at 5h=50%' mark "$(j "$MARK,$MARK2")"

# ── 13: a sibling account being exhausted must not veto a healthy one ────────
check 'mp-team at 99 does not block mark'       0 'ok: mark' mark \
      "$(j "$MARK"',{"account":"mp-team","name":"community","fiveHourPct":6,"sevenDayPct":99}')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
