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
# DIVE-4575 changed this arm's EXPECTED TEXT and not its property. An empty
# per-seat document is no longer a refusal ON ITS OWN — the account reading is
# consulted first and may still carry the window — so what must still hold is
# that with NEITHER source the answer is rc=1, and that the reason names both
# sources rather than blaming the document. The old wording said only
# "5dive usage --json returned nothing", which is what made nine hours of live
# refusals read as a quiet fleet instead of an unmeasured account.
check 'empty json refuses when the account is blind too' 1 'no account reading measured' mark ''
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

# ══ DIVE-4575: THE ACCOUNT'S READING, NOT AN IDLE SEAT'S ════════════════════
#
# Arms 1-3 above are the null meter's negative controls and they stay exactly as
# they are: a blind ACCOUNT still refuses. What the live fleet showed on
# 2026-09-15 is that "blind" was being decided from the wrong document. The pool
# seat main2 sat idle from 09-14, never wrote a `rate_limits` key to its
# statusline cache, and `5dive usage --json` — which is built from transcript
# activity — therefore reported nulls for it, while `main`, on the SAME auth
# account and so in the same window, held a live reading all day. Seven graded
# deliveries queued for up to nine hours behind `refuse: mark has no 5h reading
# (null)`.
#
# THESE ARMS DRIVE THE REAL `_grader_account_reading`, NOT A STUB OF IT. The
# lane resolves its account source through two `declare -F`-guarded helpers, so
# defining `quota_snapshot_read` here is exactly how the shipped bundle reaches
# it — the normaliser, the asOf fence and the reset fence are all executed, and
# only the file read is replaced. A stubbed `_GRADER_ACCOUNT_READING_CMD` would
# have graded the caller and nothing else.
SNAP=''
quota_snapshot_read() { [[ -n "$SNAP" ]] && printf '%s' "$SNAP"; return 0; }
NOW=$(date +%s)
# snap <fivePct|null> <sevenPct|null> <asOfAgeSec> [<5hResetsAt>] [<7dResetsAt>]
snap() {
  local f="$1" s7="$2" age="$3" fr="${4:-$((NOW + 3600))}" sr="${5:-$((NOW + 86400))}"
  printf '{"writtenAt":%d,"accounts":[{"name":"mark","usage":{"asOf":%d,"source":"main","remembered":false,%s}}]}' \
    "$NOW" "$((NOW - age))" \
    "$(printf '"fiveHour":%s,"sevenDay":%s' \
        "$( [[ "$f"  == null ]] && printf null || printf '{"pct":%s,"resetsAt":%s}' "$f"  "$fr" )" \
        "$( [[ "$s7" == null ]] && printf null || printf '{"pct":%s,"resetsAt":%s}' "$s7" "$sr" )")"
}
# The main2 shape: the account's seat rows in the usage document are all null.
IDLE='{"account":"mark","name":"main2","fiveHourPct":null,"sevenDayPct":null}'

# 14 — THE ROW ITSELF. Every seat row null, a fresh account reading under the
#      floor: the lane spawns instead of refusing for the ninth hour.
SNAP="$(snap 7 40 30)"
check 'idle seat + fresh account reading spawns' 0 'from the account reading' mark "$(j "$IDLE")"
# 15 — and the account reading is the AUTHORITY, not a tiebreaker: it refuses a
#      seat document that would have admitted.
SNAP="$(snap 95 40 30)"
check 'account reading over the floor beats a clear seat row' 2 'of its 5h window' mark "$(j "$MARK")"
# 16 — A FRESHER SOURCE THAT MAY BE STALE IS NOT AN IMPROVEMENT. Past the age
#      fence the reading is not used at all and the seat document answers again.
SNAP="$(snap 7 40 7200)"
check 'a stale account reading is ignored (seat doc answers)' 0 'ok: mark at 5h=50%' mark "$(j "$MARK")"
# 17 — ...and with nothing behind it, the stale reading buys no headroom either.
SNAP="$(snap 7 40 7200)"
check 'a stale account reading never becomes headroom' 1 'no 5h reading' mark "$(j "$IDLE")"
# 18 — A WINDOW THAT HAS ALREADY RESET is not a statement about the window we
#      are about to spend in. The 5h side is dropped; the 7d side survives; the
#      seat document supplies the dropped half.
SNAP="$(snap 95 40 30 $((NOW - 60)))"
check 'a reset 5h window is dropped, not spent' 0 '5h from the seat reading, 7d from the account' mark "$(j "$MARK")"
# 19 — an empty per-seat document is no longer a blanket refusal.
SNAP="$(snap 7 40 30)"
check 'empty usage doc + fresh account reading spawns' 0 'ok: mark at 5h=7%' mark ''
# 20 — a reading with no measurement time cannot be aged, so it is not a
#      reading. Same door as DIVE-4342: never launder an undated number.
SNAP='{"writtenAt":'"$NOW"',"accounts":[{"name":"mark","usage":{"fiveHour":{"pct":7},"sevenDay":{"pct":40}}}]}'
check 'an undated account reading is not a reading' 1 'no 5h reading' mark "$(j "$IDLE")"
# 21 — neither source measures anything: still fails closed, and the reason now
#      names BOTH so the next reader is not sent back to the seat.
SNAP=''
check 'both sources blind still refuses closed' 1 'no account reading measured within 600s and no seat of the account carries one' mark "$(j "$IDLE")"
SNAP=''

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
