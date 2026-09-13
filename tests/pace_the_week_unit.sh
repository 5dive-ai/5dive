#!/usr/bin/env bash
# DIVE-4430 unit: pace the week instead of exhausting it.
#
# THE MEASUREMENT THAT FILED THE ROW. The fleet spends the weekly account
# ceiling in ~3 days and sits starved for ~4 (measured 2026-08-16, unchanged on
# the 2026-09-13 board). Four idle days out of seven is the ceiling on the
# autonomy number. Four arms, one theme.
#
# WHAT IS ASSERTED HERE
#   A. `_pace_band` at the meter values the filing names — 0/59/60/89/90/null —
#      and the polarity that matters: an EMPTY meter is never read as 0% used.
#   B. The soft floor is a PACING rule, so it releases inside the last N days of
#      the window and stays armed when the reset is unreadable. An unmeasured
#      reset never buys headroom.
#   C. `_pace_admits` — which bands dispatch which priorities, and that recurring
#      beats are given up first.
#   D. A DIFFERENTIAL on the real dispatch block, extracted VERBATIM from
#      src/cmd_heartbeat.sh: the same fixture board with the floor off and on.
#      Without the floor-off arm this file could pass against a block that held
#      everything.
#   E. The budget arm: a VERIFIED figure parks, the SAME figure marked
#      unverified does not, and neither does an absent one. This is the whole
#      reason DIVE-3343 removed the previous guard, so it is the arm that must
#      not rot.
#   F. `--max-iters` defaults to 2 on a standard row, is untouched on a template,
#      and never overrides an explicit value.
#   G. The picker already excludes `blocked` rows and rows whose merge another
#      seat owns — asserted against the LIVE query text, because arm 4 of the
#      filing is satisfied by code that is already on main and a regression here
#      would be silent.
#
# WHY THE BLIND-METER POLICY IS A KNOB AND NOT A CONSTANT — and why `soft` is
# the default — is argued in full at the top of src/task/grader_pool.sh, against a
# measurement of the live fleet. Both readings are exercised below, so a future
# operator who flips it gets a tested path rather than an untested one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/pace-week.XXXXXX")"
trap 'rc=$?; rm -rf "$TMPD"; echo "HARNESS-RC=$rc"' EXIT

# ── A/B/C: the floor itself ────────────────────────────────────────────────
# shellcheck source=/dev/null
source src/task/grader_pool.sh
NOW=1789294364                       # a fixed clock; every reset below is relative to it
FAR=$(( NOW + 6*86400 ))             # 6 days out — the soft floor binds
NEAR=$(( NOW + 2*86400 ))            # 2 days out — inside the reset window

mkjson(){ # <pct-or-null> <resets-or-null>
  printf '{"agents":[{"name":"s1","account":"acct","sevenDayPct":%s,"sevenDayResetsAt":%s}]}' "$1" "$2"
}
band(){ # <pct> <resets> -> echoes "<rc>"
  local rc=0
  printf '%s' "$(mkjson "$1" "$2")" | _pace_band acct "$NOW" >/dev/null || rc=$?
  printf '%s' "$rc"
}

# A — the filing's stub values, each side of both floors.
for probe in "0 $FAR 0" "59 $FAR 0" "60 $FAR 2" "89 $FAR 2" "90 $FAR 3" "99 $FAR 3"; do
  read -r pct rst want <<<"$probe"
  got=$(band "$pct" "$rst")
  [[ "$got" == "$want" ]] && ok_ "A: 7d=${pct}% -> band ${want}" \
    || bad_ "A: 7d=${pct}%" "expected band ${want}, got ${got}"
done

# A — THE ARM THIS WHOLE GUARD FAMILY EXISTS FOR. `(( "" < 60 ))` is 0 in bash,
# so a null meter read numerically is a seat with FULL headroom. Measured
# 2026-09-09: 43% of the fleet in exactly that state.
got=$(band null "$FAR")
[[ "$got" == "2" ]] && ok_ "A: null meter holds at the soft floor (default policy), never reads as 0%" \
  || bad_ "A: null meter" "expected band 2 (soft), got ${got} — band 0 would mean it read as 0% used"
got=$(printf '' | { _pace_band acct "$NOW" >/dev/null; printf '%s' "$?"; })
[[ "$got" == "2" ]] && ok_ "A: an ABSENT snapshot holds at the soft floor too" \
  || bad_ "A: absent snapshot" "expected 2, got ${got}"
got=$(printf '%s' "$(mkjson '"78%"' "$FAR")" | { _pace_band acct "$NOW" >/dev/null; printf '%s' "$?"; })
[[ "$got" == "2" ]] && ok_ "A: an unparseable meter holds at the soft floor" \
  || bad_ "A: unparseable meter" "expected 2, got ${got}"

# A — the strict reading the filing asked for is available, and it refuses.
( _PACE_BLIND=refuse
  rc=0; printf '%s' "$(mkjson null "$FAR")" | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == "1" ]] && exit 0 || exit 1 ) \
  && ok_ "A: FIVE_PACE_BLIND=refuse gives the filing's literal reading (no meter, no dispatch)" \
  || bad_ "A: FIVE_PACE_BLIND=refuse" "expected rc 1"

# B — the soft floor is a PACING rule and releases near the reset; the hard
# floor protects the window itself and does not.
got=$(band 70 "$NEAR")
[[ "$got" == "0" ]] && ok_ "B: over the soft floor but 2d to the reset -> no hold (the remainder expires anyway)" \
  || bad_ "B: near reset" "expected 0, got ${got}"
got=$(band 95 "$NEAR")
[[ "$got" == "3" ]] && ok_ "B: the HARD floor still binds near the reset" \
  || bad_ "B: hard near reset" "expected 3, got ${got}"
got=$(band 70 null)
[[ "$got" == "2" ]] && ok_ "B: an UNREADABLE reset leaves the floor armed — the unmeasured case never buys headroom" \
  || bad_ "B: unreadable reset" "expected 2, got ${got}"
got=$(band 70 "$(( NOW - 86400 ))")
[[ "$got" == "2" ]] && ok_ "B: a reset already in the PAST leaves the floor armed" \
  || bad_ "B: lapsed reset" "expected 2, got ${got}"

# B — the knobs are knobs.
( FIVE_PACE_7D_SOFT=40; source src/task/grader_pool.sh
  rc=0; printf '%s' "$(printf '{"agents":[{"account":"acct","sevenDayPct":45,"sevenDayResetsAt":%s}]}' "$FAR")" \
    | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == "2" ]] && exit 0 || exit 1 ) \
  && ok_ "B: FIVE_PACE_7D_SOFT moves the soft floor" || bad_ "B: FIVE_PACE_7D_SOFT" "45% did not hold at a floor of 40"

# C — which rows each band admits.
adm(){ local rc=0; _pace_admits "$1" "$2" "${3:-standard}" || rc=$?; printf '%s' "$rc"; }
for probe in "0 low standard 0" "0 medium recurring 0" \
             "2 urgent standard 0" "2 high standard 0" "2 medium standard 1" "2 low standard 1" \
             "2 '' standard 1" "2 urgent recurring 1" \
             "3 urgent standard 0" "3 high standard 1" "3 medium standard 1" \
             "1 urgent standard 1" "1 urgent recurring 1"; do
  read -r rc prio kind want <<<"$probe"
  [[ "$prio" == "''" ]] && prio=""
  got=$(adm "$rc" "$prio" "$kind")
  [[ "$got" == "$want" ]] && ok_ "C: band ${rc} + ${prio:-<unreadable>}/${kind} -> $( [[ $want == 0 ]] && echo dispatch || echo hold )" \
    || bad_ "C: band ${rc} ${prio:-<unreadable>}/${kind}" "expected ${want}, got ${got}"
done

# ── D: the differential, on the block that actually ships ──────────────────
# Extracted VERBATIM from src/cmd_heartbeat.sh rather than reimplemented: a
# re-typed copy of a guard is a second predicate free to drift from the first,
# and this file would then grade the copy.
BLOCK="$TMPD/block.sh"
awk '/--- DIVE-4430 pacing floor ---/{f=1} f{print} f&&/--- end DIVE-4430 pacing floor ---/{exit}' \
  src/cmd_heartbeat.sh > "$BLOCK"
if [[ ! -s "$BLOCK" ]] || ! grep -q '_pace_admits' "$BLOCK"; then
  bad_ "D: extraction" "could not extract the pacing block from src/cmd_heartbeat.sh — the sentinel comments moved"
else
  ok_ "D: the pacing block was extracted from the shipping source, not re-typed"
  # A fixture board: one row per priority, all on seat `s1`.
  BOARD="1 urgent
2 high
3 medium
4 low"
  # The extracted block ends in `continue`, which is only legal in a loop — so
  # the probe below drives it with a hand-rolled loop that records the skip.
  probe_board(){ # <usage-json> -> dispatched idents
    local usage="$1"
    ( set +e
      db(){ case "$*" in *priority*) awk -v id="$_Q_ID" '$1==id{print $2}' <<<"$BOARD" ;; *) printf '' ;; esac; }
      _hb_log(){ :; }
      _hb_ident(){ printf 'DIVE-%s' "$1"; }
      name="s1"; reg='{"agents":{"s1":{"authProfile":"acct"}}}'; now="$NOW"
      _HB_PACE_USAGE="$usage"; sk_pace=0
      out=""
      while read -r tid _; do
        task_id="$tid"; _Q_ID="$tid"
        task_ident=$(_hb_ident "$task_id")
        # shellcheck source=/dev/null
        . "$BLOCK"
        out+="${task_ident} "
      done <<<"$BOARD"
      printf '%s' "$out" )
  }
  open_usage=$(mkjson 20 "$FAR")
  soft_usage=$(mkjson 70 "$FAR")
  hard_usage=$(mkjson 95 "$FAR")
  got_open=$(probe_board "$open_usage")
  got_soft=$(probe_board "$soft_usage")
  got_hard=$(probe_board "$hard_usage")
  [[ "$got_open" == "DIVE-1 DIVE-2 DIVE-3 DIVE-4 " ]] \
    && ok_ "D: floor OFF (20%) — every row dispatches, exactly as today" \
    || bad_ "D: floor off" "expected all four rows, got '${got_open}'"
  [[ "$got_soft" == "DIVE-1 DIVE-2 " ]] \
    && ok_ "D: floor SOFT (70%) — only urgent+high, and the urgent row behind two held ones still reaches" \
    || bad_ "D: floor soft" "expected 'DIVE-1 DIVE-2 ', got '${got_soft}'"
  [[ "$got_hard" == "DIVE-1 " ]] \
    && ok_ "D: floor HARD (95%) — urgent only" \
    || bad_ "D: floor hard" "expected 'DIVE-1 ', got '${got_hard}'"
  # The differential is the point: floor-off and floor-on must DIFFER, or this
  # file would pass against a block that was deleted.
  [[ "$got_open" != "$got_soft" && "$got_soft" != "$got_hard" ]] \
    && ok_ "D: the three bands produce three different pick lists (the differential is real)" \
    || bad_ "D: differential" "floor off/soft/hard produced the same list"
fi

# ── E: the budget arm ──────────────────────────────────────────────────────
# shellcheck source=/dev/null
Q="$TMPD/q.sh"
awk '/^_hb_task_verified_quota\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/cmd_heartbeat.sh > "$Q"
[[ -s "$Q" ]] && ok_ "E: _hb_task_verified_quota extracted from the shipping source" \
  || bad_ "E: extraction" "could not extract _hb_task_verified_quota"
# shellcheck source=/dev/null
source "$Q"
vq(){ printf '%s' "$1" | _hb_task_verified_quota "$2"; }
U_OK='{"data":{"tasks":[{"ident":"DIVE-9","quota":200000000,"dispatched":true}]}}'
U_UNV='{"data":{"tasks":[{"ident":"DIVE-9","quota":200000000,"dispatched":false}]}}'
U_NUL='{"data":{"tasks":[{"ident":"DIVE-9","quota":200000000,"dispatched":null}]}}'
U_ABS='{"data":{"tasks":[]}}'
out=$(vq "$U_OK" DIVE-9); rc=$?
[[ $rc -eq 0 && "$out" == "200000000" ]] \
  && ok_ "E: a VERIFIED figure is returned and is chargeable" \
  || bad_ "E: verified" "rc=${rc} out='${out}'"
for probe in "U_UNV unverified" "U_NUL null-dispatched" "U_ABS absent"; do
  read -r var label <<<"$probe"
  out=$(vq "${!var}" DIVE-9); rc=$?
  [[ $rc -ne 0 ]] \
    && ok_ "E: an ${label} figure is NOT chargeable (DIVE-3343's lesson: absence of evidence is not evidence of spend)" \
    || bad_ "E: ${label}" "expected a refusal, got rc=0 out='${out}'"
done
# And the sweep must never park on a refusal. Assert it structurally: the only
# `(( spent >= eff ))` comparison in the sweep must sit BELOW the guard that
# returns on an unverified read.
SW="$TMPD/sw.sh"
awk '/^_hb_task_budget_sweep\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/cmd_heartbeat.sh > "$SW"
g=$(grep -n '_hb_task_verified_quota' "$SW" | head -1 | cut -d: -f1)
c=$(grep -n 'spent >= eff' "$SW" | head -1 | cut -d: -f1)
[[ -n "$g" && -n "$c" ]] && (( g < c )) \
  && ok_ "E: the sweep's verified-figure guard sits ABOVE its only budget comparison" \
  || bad_ "E: ordering" "guard at line ${g:-<none>}, comparison at line ${c:-<none>}"
grep -q "none|NONE) continue" "$SW" \
  && ok_ "E: 'set-budget none' still exempts a row" || bad_ "E: none exemption" "the carve-out is gone"
grep -qE '^\s+\\\$\*\)\s+continue' "$SW" \
  && ok_ "E: the \$cost form is skipped, not compared to a token count" \
  || bad_ "E: cost form" "the \$cost skip is gone — dollars would be compared to tokens"

# ── F: --max-iters default ─────────────────────────────────────────────────
CR=$(sed -n '/DIVE-4430: the maker<->verifier loop is BOUNDED BY DEFAULT/,/^  fi$/p' src/task/crud.sh)
[[ -n "$CR" ]] && ok_ "F: the filing-time default was extracted from src/task/crud.sh" \
  || bad_ "F: extraction" "the default block is missing"
mi(){ # <given-max-iters> <kind> [<env-default>]
  ( max_iters="$1"; kind="$2"; [[ -n "${3:-}" ]] && FIVE_TASK_MAX_ITERS_DEFAULT="$3"
    eval "$CR"; printf '%s' "${max_iters:-NULL}" )
}
[[ "$(mi '' standard)" == "2" ]] && ok_ "F: a standard row filed with no flag gets max_iterations=2" \
  || bad_ "F: default" "got '$(mi '' standard)'"
# NULL is what the caller prints for an unset max_iters, and it is the SQL
# literal the INSERT emits — so this arm asserts the template stores SQL NULL,
# i.e. unbounded, exactly as before.
[[ "$(mi '' recurring)" == "NULL" ]] && ok_ "F: a TEMPLATE is left unchanged — still SQL NULL (it never enters a verify loop)" \
  || bad_ "F: template" "got '$(mi '' recurring)'"
[[ "$(mi 5 standard)" == "5" ]] && ok_ "F: an explicit --max-iters is never overridden, including above the default" \
  || bad_ "F: explicit" "got '$(mi 5 standard)'"
[[ "$(mi '' standard 4)" == "4" ]] && ok_ "F: FIVE_TASK_MAX_ITERS_DEFAULT moves the default" \
  || bad_ "F: env knob" "got '$(mi '' standard 4)'"
[[ "$(mi '' standard 'not-a-number')" == "2" ]] \
  && ok_ "F: a MISTYPED override falls back to 2, never to unbounded" \
  || bad_ "F: malformed env" "got '$(mi '' standard 'not-a-number')' — NULL here would be the unbounded state this exists to end"

# ── G: rows waiting on someone else are already excluded ───────────────────
# Arm 4 of the filing is satisfied by code already on main (DIVE-4206/DIVE-4220
# for the merge half, the gate predicate for the other). Asserted against the
# LIVE query text so the property cannot regress silently — this is the arm that
# would otherwise be defended by nothing at all.
PICK=$(awk '/^_hb_pick_tasks\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' src/cmd_heartbeat.sh)
[[ -n "$PICK" ]] && ok_ "G: _hb_pick_tasks extracted" || bad_ "G: extraction" "picker not found"
grep -q "t.status='todo'" <<<"$PICK" \
  && ok_ "G: the picker selects ONLY todo — a 'blocked' row (a live human gate, a park, a budget breach) is never dispatched" \
  || bad_ "G: blocked" "the status filter is gone; blocked rows would be dispatched"
grep -q "NOT (t.need_type IS NOT NULL AND t.need_answered_at IS NULL)" <<<"$PICK" \
  && ok_ "G: a row with an UNANSWERED gate is excluded — it wakes on the answer, not on the tick" \
  || bad_ "G: gate" "the unanswered-gate exclusion is gone (DIVE-1817 burned 13.8M over 3 days in exactly that state)"
grep -q "AND NOT ( (\${_TASKS_TFV_SQL})" <<<"$PICK" \
  && ok_ "G: a row whose merge ANOTHER seat owes is excluded from this seat's list" \
  || bad_ "G: other-seat merge" "the DIVE-4206 exclusion is gone"
grep -q "OR ( (\${_TASKS_TFV_SQL})" <<<"$PICK" \
  && ok_ "G: ...and the SAME row IS dispatched to the seat that owns the merge (DIVE-4220)" \
  || bad_ "G: own merge" "the DIVE-4220 arm is gone — a graded row would wait for a seat to happen to look"

# ── H: the digest's copy of the band must agree with the floor's ───────────
# The digest recomputes the band from the same usage document rather than
# asking the heartbeat for it (one read, same numbers). That makes it a SECOND
# PREDICATE, and a second predicate is free to drift from the first — which is
# the defect class this repo has paid for more than once. So it is extracted
# from src/cmd_digest.sh and graded against the SAME six situations _pace_band
# answers above, including the max-across-seats rule that lets one live seat
# answer for a blind sibling on the same account.
DPROBE="$TMPD/dpace.py"
cat > "$DPROBE" <<'PYEOF'
import os, time, sys
src = open('src/cmd_digest.sh').read()
try:
    a = src.index('# DIVE-4430 — the PACING FLOOR')
    tail = 'paced = [p for p in pace_l if p["band"] != "open"]'
    b = src.index(tail) + len(tail)
except ValueError:
    print('EXTRACT-FAILED'); sys.exit(2)
block = src[a:b]
now = int(time.time())
cases = [
    ("open",  [{"name":"a","account":"m","sevenDayPct":20,"sevenDayResetsAt":now+6*86400}], "open"),
    ("soft",  [{"name":"a","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+6*86400}], "soft"),
    ("hard",  [{"name":"a","account":"m","sevenDayPct":95,"sevenDayResetsAt":now+6*86400}], "hard"),
    ("near-reset", [{"name":"a","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+2*86400}], "open"),
    ("blind", [{"name":"a","account":"m","sevenDayPct":None,"sevenDayResetsAt":None}], "blind"),
    ("one-blind-seat-on-a-measured-account",
              [{"name":"a","account":"m","sevenDayPct":None,"sevenDayResetsAt":None},
               {"name":"b","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+6*86400}], "soft"),
]
bad = 0
for label, agents, want in cases:
    ns = {"os": os, "time": time, "agents": agents}
    exec(block, ns)
    got = ns["pace_l"][0]["band"]
    print(("ok" if got == want else "no"), label, got, want)
    if got != want: bad += 1
# breach-only: an open account must produce NO digest line.
ns = {"os": os, "time": time,
      "agents": [{"name":"a","account":"m","sevenDayPct":20,"sevenDayResetsAt":now+6*86400}]}
exec(block, ns)
print(("ok" if not ns["paced"] else "no"), "breach-only", len(ns["paced"]), 0)
if ns["paced"]: bad += 1
sys.exit(1 if bad else 0)
PYEOF
dout=$(timeout 120 python3 "$DPROBE" 2>&1); drc=$?
if [[ "$dout" == *EXTRACT-FAILED* ]]; then
  bad_ "H: extraction" "the digest's pacing block could not be located — its sentinel comment moved"
elif (( drc == 0 )); then
  ok_ "H: the digest's band agrees with _pace_band on all six situations, and stays silent on an open account"
else
  bad_ "H: digest band" "the digest's copy disagrees with the floor: ${dout//$'\n'/ | }"
fi

# ── I: the snapshot cache ──────────────────────────────────────────────────
# A floor that re-reads a ~4.4s transcript walk on a once-a-minute tick would
# be paying for itself in the coin it exists to save. The cache is therefore
# part of the guard, not an optimisation bolted beside it, and its failure
# directions are what must not rot: fresh is served from disk, stale is NOT
# served at all (an old number is not a measurement of now), and a failed live
# read never overwrites a good cache with nothing.
CF="$TMPD/pace-cache.json"
( FIVE_PACE_CACHE_FILE="$CF" FIVE_PACE_CACHE_SEC=300
  source src/task/grader_pool.sh
  live_a(){ printf '{"agents":[{"account":"acct","sevenDayPct":11}]}'; }
  live_b(){ printf '{"agents":[{"account":"acct","sevenDayPct":22}]}'; }
  live_dead(){ printf ''; return 1; }

  _PACE_USAGE_CMD=live_a
  first=$(_pace_usage_snapshot)
  [[ "$first" == *'"sevenDayPct":11'* ]] || { echo "I1 miss-then-read failed: $first"; exit 1; }
  [[ -s "$CF" ]] || { echo "I1 cache not written"; exit 1; }

  # Fresh: the LIVE reader has changed and must NOT be consulted.
  _PACE_USAGE_CMD=live_b
  second=$(_pace_usage_snapshot)
  [[ "$second" == *'"sevenDayPct":11'* ]] || { echo "I2 fresh cache not served: $second"; exit 1; }

  # Stale: age past the TTL, so the cache is bypassed and the live value wins.
  touch -d '2 hours ago' "$CF"
  third=$(_pace_usage_snapshot)
  [[ "$third" == *'"sevenDayPct":22'* ]] || { echo "I3 stale cache was served: $third"; exit 1; }

  # A dead live read past the TTL yields EMPTY -- which _pace_band reads as a
  # blind meter, never as 0% -- and must leave the cache file intact.
  touch -d '2 hours ago' "$CF"
  _PACE_USAGE_CMD=live_dead
  fourth=$(_pace_usage_snapshot)
  [[ -z "$fourth" ]] || { echo "I4 dead read returned '$fourth'"; exit 1; }
  [[ -s "$CF" ]] || { echo "I4 dead read destroyed the cache"; exit 1; }
  rcb=0; printf '%s' "$fourth" | _pace_band acct "$NOW" >/dev/null || rcb=$?
  [[ "$rcb" == "2" ]] || { echo "I4 empty snapshot did not read as blind/soft (got $rcb)"; exit 1; }
  exit 0 ) && ok_ "I: the snapshot cache serves fresh, bypasses stale, and fails to BLIND rather than to 0% or to a stale number" \
    || bad_ "I: snapshot cache" "see the message above"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
