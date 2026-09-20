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
#   H2. The digest's account rows come from the SAME two-source reader the floor
#      uses (live per-seat caches first, published snapshot second) — not from
#      the snapshot alone, which has no scheduled publisher and is stale on
#      every hourly tick. Graded on the state that proves it: stale snapshot,
#      fresh live cache, and the two predicates must land on the same band.
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
import os, time, sys, datetime as dt
src = open('src/cmd_digest.sh').read()
# The block calls the digest's own timestamp parser; extract it rather than
# re-typing one, so a drift there is graded here too.
_ts_a = src.index('def to_epoch(s):')
_ts_b = src.index('\n\n', _ts_a)
_ts_ns = {"dt": dt}
exec(src[_ts_a:_ts_b], _ts_ns)
to_epoch = _ts_ns["to_epoch"]
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
# DIVE-4578 — the same six situations answered by the ACCOUNT's reading instead
# of the per-seat document, plus the two fences and the negative control. The
# QUIET-ACCOUNT case is the row: no seat row at all (or a null one) and a fresh
# account reading at 20% must read OPEN, where it used to read blind -> soft.
def snap(pct, resets, asof=None, name="m"):
    return {"writtenAt": now,
            "accounts": [{"name": name,
                          "usage": {"asOf": now - 60 if asof is None else asof,
                                    "fiveHour": {"pct": 5, "resetsAt": now + 3600},
                                    "sevenDay": {"pct": pct, "resetsAt": resets}}}]}
NOSEAT = []
NULLSEAT = [{"name":"a","account":"m","sevenDayPct":None,"sevenDayResetsAt":None}]
acct_cases = [
    # label, agents, snapshot, want-band, want-source
    ("quiet-account-no-seat-row",   NOSEAT,   snap(20, now+6*86400), "open",  "account"),
    ("quiet-account-null-seat-row", NULLSEAT, snap(20, now+6*86400), "open",  "account"),
    ("account-soft",                NULLSEAT, snap(70, now+6*86400), "soft",  "account"),
    ("account-hard",                NULLSEAT, snap(95, now+6*86400), "hard",  "account"),
    ("account-near-reset",          NULLSEAT, snap(70, now+2*86400), "open",  "account"),
    # The account reading OVERRIDES a live seat row, and the two are never mixed:
    # the seat says 20% with 6d left, the account says 95%.
    ("account-overrides-a-live-seat",
     [{"name":"a","account":"m","sevenDayPct":20,"sevenDayResetsAt":now+6*86400}],
     snap(95, now+6*86400), "hard", "account"),
    # FENCE 1 — the reading's own asOf. Past the age it is not a reading, and the
    # seat document answers instead.
    ("stale-reading-falls-back-to-the-seat",
     [{"name":"a","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+6*86400}],
     snap(20, now+6*86400, asof=now-4000), "soft", "seat"),
    # FENCE 2 — a window that has already turned over is not a statement about
    # the week we are pacing.
    ("reset-passed-falls-back-to-the-seat",
     [{"name":"a","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+6*86400}],
     snap(20, now-3600), "soft", "seat"),
    # NEGATIVE CONTROL — with NEITHER source we are still blind and still held.
    ("neither-source-still-blind", NULLSEAT, {"accounts": []}, "blind", None),
    # SOURCE MIXING, the case every other fixture hides: the account reading has
    # a pct but NO readable reset, and the document has a NEAR one. Taking that
    # reset would RELAX the floor (2d left -> open) on a window the document
    # measured and the account reading did not. The floor must stay armed.
    ("account-pct-without-a-reset-never-borrows-the-documents",
     [{"name":"a","account":"m","sevenDayPct":70,"sevenDayResetsAt":now+2*86400}],
     snap(70, None), "soft", "account"),
    ("a-snapshot-for-another-account-is-not-this-one",
     NULLSEAT, snap(20, now+6*86400, name="other"), "blind", None),
]
bad = 0
for label, agents, want in cases:
    ns = {"os": os, "time": time, "to_epoch": to_epoch, "agents": agents, "acct_snap": {}}
    exec(block, ns)
    got = ns["pace_l"][0]["band"]
    print(("ok" if got == want else "no"), label, got, want)
    if got != want: bad += 1
for label, agents, sn, want, want_src in acct_cases:
    ns = {"os": os, "time": time, "to_epoch": to_epoch, "agents": agents, "acct_snap": sn}
    exec(block, ns)
    rows = ns["pace_l"]
    row = next((r for r in rows if r["account"] == "m"), None)
    got = row["band"] if row else "<no row>"
    gsrc = row.get("source") if row else None
    okrow = (got == want and gsrc == want_src)
    print(("ok" if okrow else "no"), label, got, want, gsrc, want_src)
    if not okrow: bad += 1
# DIVE-4629 — THE SURFACE MUST NOT PRINT A HOLD THE FLOOR IS NOT APPLYING.
# The floor now clears an account whose provider can never publish a weekly
# window; rendering that account as "blind — held at the soft floor" would be
# the same drift between these two predicates that DIVE-4578 closed. The map is
# seeded here the way the digest's own `_digest_account_unmetered` writes it,
# from the floor's classifier.
unmet_cases = [
    # label, agents, snapshot, unmet-map, env, want-band
    ("unmeterable-no-reading",        NULLSEAT, {"accounts": []}, {"m": True}, {}, "open"),
    # The digest's population is the activity document plus the snapshot's
    # names — NOT the registry — so an unmeterable account whose seats were
    # idle all window has no row here at all. Pinned rather than left implicit:
    # it is the one place the surface is narrower than the floor, and it errs by
    # saying nothing rather than by printing a hold.
    ("idle-account-has-no-row-at-all", NOSEAT,  snap(20, now+6*86400, name="other"),
                                                                  {"m": True}, {}, "<no row>"),
    ("not-in-the-map-is-still-blind", NULLSEAT, {"accounts": []}, {},          {}, "blind"),
    ("a-reading-still-answers-first",
     [{"name":"a","account":"m","sevenDayPct":95,"sevenDayResetsAt":now+6*86400}],
     {"accounts": []}, {"m": True}, {}, "hard"),
    ("policy-soft",   NULLSEAT, {"accounts": []}, {"m": True}, {"FIVE_PACE_UNMETERED": "soft"},   "soft"),
    ("policy-hard",   NULLSEAT, {"accounts": []}, {"m": True}, {"FIVE_PACE_UNMETERED": "hard"},   "hard"),
    ("policy-banana", NULLSEAT, {"accounts": []}, {"m": True}, {"FIVE_PACE_UNMETERED": "banana"}, "soft"),
    # Under FIVE_PACE_BLIND=refuse the floor does not consult the unmetered
    # policy, so neither does the surface: the account keeps rendering as held.
    ("blind-refuse-keeps-the-hold", NULLSEAT, {"accounts": []}, {"m": True},
                                    {"FIVE_PACE_BLIND": "refuse"}, "blind"),
]
for label, agents, sn, unmet, env, want in unmet_cases:
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        ns = {"os": os, "time": time, "to_epoch": to_epoch, "agents": agents,
              "acct_snap": sn, "_unmet": unmet}
        exec(block, ns)
        row = next((r for r in ns["pace_l"] if r["account"] == "m"), None)
        got = row["band"] if row else "<no row>"
        # An open account is breach-only: it must not render a line at all.
        if want == "open" and ns["paced"]:
            got = "open-but-still-rendered"
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
    print(("ok" if got == want else "no"), "unmetered-" + label, got, want)
    if got != want: bad += 1
# breach-only: an open account must produce NO digest line.
ns = {"os": os, "time": time, "to_epoch": to_epoch, "acct_snap": {},
      "agents": [{"name":"a","account":"m","sevenDayPct":20,"sevenDayResetsAt":now+6*86400}]}
exec(block, ns)
print(("ok" if not ns["paced"] else "no"), "breach-only", len(ns["paced"]), 0)
if ns["paced"]: bad += 1
# ...and a quiet account the ACCOUNT reading clears must not render either: the
# whole point of the row is that it stops being reported as held.
ns = {"os": os, "time": time, "to_epoch": to_epoch, "agents": [],
      "acct_snap": snap(20, now+6*86400)}
exec(block, ns)
print(("ok" if not ns["paced"] else "no"), "quiet-account-breach-only", len(ns["paced"]), 0)
if ns["paced"]: bad += 1
sys.exit(1 if bad else 0)
PYEOF
dout=$(timeout 120 python3 "$DPROBE" 2>&1); drc=$?
if [[ "$dout" == *EXTRACT-FAILED* ]]; then
  bad_ "H: extraction" "the digest's pacing block could not be located — its sentinel comment moved"
elif (( drc == 0 )); then
  ok_ "H: the digest's band agrees with _pace_band on all six situations, reads the ACCOUNT first (DIVE-4578) with both fences and the blind control, and stays silent on an open account"
else
  bad_ "H: digest band" "the digest's copy disagrees with the floor: ${dout//$'\n'/ | }"
fi

# ── H2: THE DIGEST'S ROWS COME FROM THE SAME READER THE FLOOR USES ─────────
# Arm H stubs the SNAPSHOT and nothing else, so it cannot see the state that
# rejected iteration 1: the snapshot is STALE (nothing publishes it on a
# schedule — its only writer is a human typing `5dive account usage`) while a
# registry-bound seat's LIVE statusline cache is FRESH. In that state the floor
# read the live cache and cleared the account while the digest, on the same
# tick, still rendered it held — a NEW disagreement between the two predicates
# that must agree.
#
# So this arm drives the digest's REAL row builder (`_digest_account_reading`,
# extracted verbatim from src/cmd_digest.sh) over stubs of BOTH carriers, and
# asserts the band it produces equals `_pace_band`'s on the same fixture.
# The builder is extracted below, which means nothing here would notice the
# staging line being pointed back at the snapshot alone — the exact edit that
# IS iteration 1's defect. So assert the wiring structurally, against the live
# source, before grading the function it names.
if grep -qE '^\s+_digest_account_reading >"\$tmpd/acct\.json"' src/cmd_digest.sh; then
  ok_ "H2: the digest STAGES its account rows from _digest_account_reading (not from the snapshot alone)"
else
  bad_ "H2: wiring" "the pace block's account rows are no longer staged from _digest_account_reading — the two-source reader is extracted but unreachable, which is iteration 1's defect exactly"
fi
DIGF="$TMPD/digfn.sh"
awk '/^  _digest_account_snapshot\(\) \{/{f=1} f{print} f&&/^  \}$/{exit}' src/cmd_digest.sh  > "$DIGF"
awk '/^  _digest_account_reading\(\) \{/{f=1}  f{print} f&&/^  \}$/{exit}' src/cmd_digest.sh >> "$DIGF"
if ! grep -q '_grader_account_reading_json' "$DIGF"; then
  bad_ "H2: extraction" "the digest's account-row builder could not be located, or it no longer calls _grader_account_reading_json — which is the whole finding"
else
  ok_ "H2: the digest's account-row builder was extracted from the shipping source and calls the floor's reader"
  NOWR=$(date +%s); RFAR=$(( NOWR + 6*86400 ))
  # The document the digest and the floor BOTH fall back to: the account's one
  # busy seat moved tokens and reported 70% — enough to hold at the soft floor.
  SEATDOC=$(printf '{"agents":[{"name":"s1","account":"m","sevenDayPct":70,"sevenDayResetsAt":%s}]}' "$RFAR")
  ACCTF="$TMPD/acct-built.json"
  ( set -uo pipefail
    source src/task/grader_pool.sh
    # LIVE, per registry-bound seat — fresh, and it says the account has room.
    # `q` is the quiet account the snapshot has never heard of: it exists only
    # as a profile on disk, which is exactly the account this row is about.
    account_best_ratelimits() {
      case "$1" in
        m) printf '{"asOf":%s,"fiveHourPct":5,"fiveResetsAt":%s,"sevenDayPct":20,"sevenResetsAt":%s}' "$(( NOWR - 60 ))" "$(( NOWR + 3600 ))" "$RFAR" ;;
        q) printf '{"asOf":%s,"fiveHourPct":4,"fiveResetsAt":%s,"sevenDayPct":95,"sevenResetsAt":%s}' "$(( NOWR - 60 ))" "$(( NOWR + 3600 ))" "$RFAR" ;;
        *) printf '' ;;
      esac
    }
    # The PUBLISHED SNAPSHOT — stale by 4000s, i.e. the state it is in on every
    # hourly digest tick, and disagreeing with the live cache so a silent
    # fall-through to it is visible as a different band, not as the same one.
    quota_snapshot_read() {
      printf '{"writtenAt":%s,"accounts":[{"name":"m","usage":{"asOf":%s,"fiveHour":null,"sevenDay":{"pct":95,"resetsAt":%s}}}]}' \
             "$(( NOWR - 4000 ))" "$(( NOWR - 4000 ))" "$RFAR"
    }
    account_each() { printf 'q\n'; }
    # shellcheck source=/dev/null
    source "$DIGF"
    _digest_account_reading > "$ACCTF"
  ) 2>/dev/null
  # 1. The builder reached the LIVE cache, not the stale snapshot: `m` carries
  #    20% (live) and not 95% (snapshot), and its asOf is inside the fence.
  gpct=$(jq -r '[(.accounts//[])[]|select(.name=="m")|.sevenDay//.usage.sevenDay|.pct]|first // "none"' "$ACCTF" 2>/dev/null)
  [[ "$gpct" == "20" ]] \
    && ok_ "H2: the digest's row for a seat-bound account carries the LIVE cache's 20%, not the stale snapshot's 95%" \
    || bad_ "H2: live first" "expected 20 from the live cache, got '${gpct}' — a stale snapshot was preferred, which is the reject"
  gage=$(jq -r --argjson n "$NOWR" '[(.accounts//[])[]|select(.name=="m")|.usage.asOf]|first // -1 | $n - .' "$ACCTF" 2>/dev/null)
  [[ "$gage" =~ ^[0-9]+$ ]] && (( gage <= 600 )) \
    && ok_ "H2: ...and that row's asOf is INSIDE the 600s fence, so the digest's fence can admit it at all" \
    || bad_ "H2: asOf age" "row asOf is ${gage}s old — outside the fence, so the digest still falls back to the activity document"
  # 2. The account the snapshot never heard of is still reached, through the
  #    profiles on disk. This is the quiet account the row exists for.
  qpct=$(jq -r '[(.accounts//[])[]|select(.name=="q")|.usage.sevenDay.pct]|first // "none"' "$ACCTF" 2>/dev/null)
  [[ "$qpct" == "95" ]] \
    && ok_ "H2: an account with NO snapshot row is still reached through its profile on disk" \
    || bad_ "H2: union" "account 'q' is absent from the built rows (got '${qpct}')"
  # 3. THE AGREEMENT. Same fixture, both predicates.
  frc=0
  ( set -uo pipefail
    source src/task/grader_pool.sh
    account_best_ratelimits() {
      case "$1" in m) printf '{"asOf":%s,"fiveHourPct":5,"fiveResetsAt":%s,"sevenDayPct":20,"sevenResetsAt":%s}' "$(( NOWR - 60 ))" "$(( NOWR + 3600 ))" "$RFAR" ;; *) printf '' ;; esac
    }
    quota_snapshot_read() {
      printf '{"accounts":[{"name":"m","usage":{"asOf":%s,"sevenDay":{"pct":95,"resetsAt":%s}}}]}' "$(( NOWR - 4000 ))" "$RFAR"
    }
    printf '%s' "$SEATDOC" | _pace_band m "$NOWR" >/dev/null
  ) || frc=$?
  fband=$(source src/task/grader_pool.sh; _pace_band_name "$frc")
  DPROBE2="$TMPD/dpace2.py"
  cat > "$DPROBE2" <<'PY2EOF'
import os, time, sys, json, datetime as dt
src = open('src/cmd_digest.sh').read()
_a = src.index('def to_epoch(s):'); _b = src.index('\n\n', _a)
_ns = {"dt": dt}; exec(src[_a:_b], _ns); to_epoch = _ns["to_epoch"]
a = src.index('# DIVE-4430 — the PACING FLOOR')
tail = 'paced = [p for p in pace_l if p["band"] != "open"]'
block = src[a:src.index(tail) + len(tail)]
acct = json.load(open(os.environ["ACCTF"]))
agents = json.loads(os.environ["SEATDOC"])["agents"]
ns = {"os": os, "time": time, "to_epoch": to_epoch, "agents": agents, "acct_snap": acct}
exec(block, ns)
row = next((r for r in ns["pace_l"] if r["account"] == "m"), None)
print((row or {}).get("band", "<no row>"), (row or {}).get("source"))
PY2EOF
  dres=$(ACCTF="$ACCTF" SEATDOC="$SEATDOC" timeout 120 python3 "$DPROBE2" 2>&1 | tail -1)
  dband=${dres%% *}; dsrc=${dres#* }
  # 2b. A STALE LIVE CACHE MUST NOT SHADOW A FRESH SNAPSHOT. "Live first" read
  #     as a plain fallback chain means a cache that merely EXISTS wins, and a
  #     seat that rendered its statusline two hours ago hands back a reading the
  #     fence then throws away — leaving the account blind while a snapshot
  #     published minutes ago sat unread behind it. Measured on this host
  #     2026-09-16: mp-team's bound caches were past the 600s fence while its
  #     snapshot row was 431s old, and the floor read the ACTIVITY document.
  SHADOW="$TMPD/acct-shadow.json"
  ( set -uo pipefail
    source src/task/grader_pool.sh
    account_best_ratelimits() {   # exists, and is OLDER than the fence
      printf '{"asOf":%s,"fiveHourPct":9,"fiveResetsAt":%s,"sevenDayPct":95,"sevenResetsAt":%s}' \
             "$(( NOWR - 7200 ))" "$(( NOWR + 3600 ))" "$RFAR"
    }
    quota_snapshot_read() {       # published minutes ago, inside the fence
      printf '{"accounts":[{"name":"m","usage":{"asOf":%s,"fiveHour":null,"sevenDay":{"pct":20,"resetsAt":%s}}}]}' \
             "$(( NOWR - 120 ))" "$RFAR"
    }
    account_each() { printf 'm\n'; }
    # shellcheck source=/dev/null
    source "$DIGF"
    _digest_account_reading > "$SHADOW"
  ) 2>/dev/null
  shres=$(ACCTF="$SHADOW" SEATDOC="$SEATDOC" timeout 120 python3 "$DPROBE2" 2>&1 | tail -1)
  shrc=0
  ( set -uo pipefail
    source src/task/grader_pool.sh
    account_best_ratelimits() { printf '{"asOf":%s,"fiveHourPct":9,"fiveResetsAt":%s,"sevenDayPct":95,"sevenResetsAt":%s}' "$(( NOWR - 7200 ))" "$(( NOWR + 3600 ))" "$RFAR"; }
    quota_snapshot_read() { printf '{"accounts":[{"name":"m","usage":{"asOf":%s,"sevenDay":{"pct":20,"resetsAt":%s}}}]}' "$(( NOWR - 120 ))" "$RFAR"; }
    printf '%s' "$SEATDOC" | _pace_band m "$NOWR" >/dev/null
  ) || shrc=$?
  shband=$(source src/task/grader_pool.sh; _pace_band_name "$shrc")
  [[ "$shres" == "open account" && "$shband" == "open" ]] \
    && ok_ "H2: a STALE live cache does not shadow a FRESH snapshot — both readers take the fresher carrier and land on open [account reading]" \
    || bad_ "H2: shadowing" "digest='${shres}', floor='${shband}' — expected 'open account'/'open'; a two-hour-old cache is hiding a two-minute-old snapshot and the account reads blind"

  # 3b. THE DIFFERENTIAL, so the agreement above cannot pass vacuously: the
  #     SNAPSHOT-ALONE source iteration 1 shipped, on this same fixture, lands
  #     on a DIFFERENT band. If these two ever agree, the arm has stopped
  #     discriminating and the ok above means nothing.
  SNAPONLY="$TMPD/acct-snaponly.json"
  ( set -uo pipefail
    source src/task/grader_pool.sh
    quota_snapshot_read() {
      printf '{"writtenAt":%s,"accounts":[{"name":"m","usage":{"asOf":%s,"fiveHour":null,"sevenDay":{"pct":95,"resetsAt":%s}}}]}' \
             "$(( NOWR - 4000 ))" "$(( NOWR - 4000 ))" "$RFAR"
    }
    # shellcheck source=/dev/null
    source "$DIGF"
    _digest_account_snapshot > "$SNAPONLY"
  ) 2>/dev/null
  sres=$(ACCTF="$SNAPONLY" SEATDOC="$SEATDOC" timeout 120 python3 "$DPROBE2" 2>&1 | tail -1)
  sband=${sres%% *}
  [[ "$sband" == "soft" && "$sband" != "$fband" ]] \
    && ok_ "H2: ...and the snapshot-ALONE source iteration 1 shipped lands on 'soft' on the same fixture — the fixture discriminates, so the agreement above is not vacuous" \
    || bad_ "H2: differential" "snapshot-alone gave '${sband}' (floor said '${fband}') — expected 'soft'; if they match, this arm can no longer see the defect"
  [[ "$dband" == "$fband" && "$dband" == "open" && "$dsrc" == "account" ]] \
    && ok_ "H2: STALE SNAPSHOT + FRESH LIVE CACHE — the digest reads 'open [account reading]' and _pace_band agrees; iteration 1 rendered 'soft' here while the floor cleared it" \
    || bad_ "H2: the two predicates disagree" "digest='${dband}' (source=${dsrc}), _pace_band='${fband}' — they must be the same band on the same fixture"
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

# ── J: DIVE-4578 — the floor reads the ACCOUNT first ───────────────────────
# The document `_pace_band` grades is built by walking what each seat DID in the
# window, so its silence about an account means "quiet", not "unmeasured" — and
# FIVE_PACE_BLIND=soft then paces a quiet account down to high/urgent-only while
# its account reading says it has room. Same document, same ambiguity as the
# grader pool's nine-hour stall (DIVE-4575), inverted by this consumer's
# fail-safe pointing the other way.
#
# THESE ARMS DRIVE THE REAL `_pace_account_seven`, NOT A STUB OF `_PACE_ACCOUNT_CMD`.
# `quota_snapshot_read` is what the shipped bundle reaches for when no bound seat
# carries a live cache, so defining THAT is how the normaliser, the age fence and
# the reset fence all execute and only the file read is replaced. Stubbing the
# command seam instead would grade the caller and nothing else.
jarm(){ # <snapshot-json> <usage-doc-or-empty> -> "<rc> <verdict>"
  ( source src/task/grader_pool.sh
    quota_snapshot_read(){ printf '%s' "$1"; }
    # shellcheck disable=SC2317
    quota_snapshot_read(){ printf '%s' "$SNAP"; }
    SNAP="$1"
    local rc=0 out
    out=$(printf '%s' "$2" | _pace_band acct "$NOW") || rc=$?
    printf '%s %s' "$rc" "$out" )
}
snap_(){ # <7d-pct> <7d-resets> [<asOf>]
  printf '{"writtenAt":%s,"accounts":[{"name":"acct","usage":{"asOf":%s,"fiveHour":{"pct":5,"resetsAt":%s},"sevenDay":{"pct":%s,"resetsAt":%s}}}]}' \
    "$NOW" "${3:-$(( NOW - 60 ))}" "$(( NOW + 3600 ))" "$1" "$2"
}
jcase(){ # <label> <want-rc> <snapshot> <usage-doc> [<must-contain>]
  local got rc
  got=$(jarm "$3" "$4"); rc="${got%% *}"
  if [[ "$rc" == "$2" ]] && { [[ -z "${5:-}" ]] || [[ "$got" == *"$5"* ]]; }; then
    ok_ "J: $1"
  else
    bad_ "J: $1" "rc=$rc want=$2 verdict=${got#* }"
  fi
}
# The row itself: a QUIET account — no row in the document at all — with a fresh
# account reading at 20% is OPEN, where it used to be held at the soft floor.
jcase "a quiet account with a fresh 20% account reading is OPEN, not held at the soft floor" \
      0 "$(snap_ 20 "$FAR")" "" "from the account reading"
jcase "a document that names the account but carries no weekly number does not override it either" \
      0 "$(snap_ 20 "$FAR")" "$(mkjson null null)" "from the account reading"
# The account reading is the SOURCE, not a tie-breaker: it overrides a live seat
# row in the tightening direction too.
jcase "the account reading overrides a live seat row (seat 20%, account 95% -> hard)" \
      3 "$(snap_ 95 "$FAR")" "$(mkjson 20 "$FAR")" "hard floor"
jcase "the account reading at 70% with 6d to the reset holds at the soft floor" \
      2 "$(snap_ 70 "$FAR")" "" "from the account reading"
# The reset that relaxes the soft floor comes from the SAME source as the pct —
# the document says 6 days out, the account says 2, and the account wins.
jcase "the days-to-reset relaxation uses the ACCOUNT's reset, never the document's" \
      0 "$(snap_ 70 "$NEAR")" "$(mkjson 70 "$FAR")" "to the reset"
# FENCE 1: the age of the READING, not of the file that quotes it.
jcase "a reading past _GRADER_READING_MAX_AGE is not a reading — the document answers instead" \
      2 "$(snap_ 20 "$FAR" "$(( NOW - 4000 ))")" "$(mkjson 70 "$FAR")" "from the seat reading"
# FENCE 2: a window that has already turned over says nothing about this week.
jcase "a weekly window whose reset has passed is dropped — the document answers instead" \
      2 "$(snap_ 20 "$(( NOW - 3600 ))")" "$(mkjson 70 "$FAR")" "from the seat reading"
# NEGATIVE CONTROLS — the fail-closed rule is not relaxed for the seat we want.
jcase "with NEITHER source the floor is still blind and still holds (never 0%)" \
      2 '{"accounts":[]}' "" "no account reading measured within"
jcase "a snapshot for a DIFFERENT account is not this account's reading" \
      2 '{"writtenAt":0,"accounts":[{"name":"other","usage":{"asOf":0,"sevenDay":{"pct":5}}}]}' "" \
      "no account reading measured within"
jcase "a malformed snapshot is not a measurement" 2 'not json at all' "" "no weekly reading"

# ── K: DIVE-4586 — a stale weekly reading is still a LOWER BOUND ────────────
# Measured on this host 2026-09-18: `mark` has eight bound seats, a real weekly
# reading of 100%, and the freshest statusline cache across all eight is two
# hours old — because the seats stopped rendering WHEN the account hit its wall.
# The asOf fence drops it, the floor calls the account blind, and blind is the
# SOFT floor: eight seats held one band looser than the account they are on.
#
# The fix is not a wider fence (DIVE-4578/4342 refuse that, and it would let a
# stale number buy spend). A weekly percentage never falls before its window
# resets, so an aged reading inside an unreset window bounds the current one
# from BELOW — and the floor is a lower-bound test. Admitted in the restrictive
# direction only; every arm below that could open the floor must stay shut.
STALE=$(( NOW - 4000 ))              # past _GRADER_READING_MAX_AGE
kcase(){ jcase "$@"; }

# THE ROW. Stale 100%, window not reset, no document: was blind/soft, now hard.
kcase "K: a stale 100% reading inside an unreset week hardens the floor (was blind/soft)" \
      3 "$(snap_ 100 "$FAR" "$STALE")" "" "AT LEAST 100%"
kcase "K: a stale 70% reading inside an unreset week holds at the soft floor, named as a bound" \
      2 "$(snap_ 70 "$FAR" "$STALE")" "" "at LEAST 70%"

# THE DIRECTION. A bound can only tighten. The near-reset relaxation is the one
# branch that BUYS dispatch, so a bound must never reach it — while the same
# numbers with a FRESH reading still do.
kcase "K: a bound never buys the near-reset relaxation" \
      2 "$(snap_ 70 "$NEAR" "$STALE")" "" "cannot buy the near-reset relaxation"
kcase "K: CONTROL — the same 70%/2d reading FRESH still opens the floor" \
      0 "$(snap_ 70 "$NEAR")" "" "to the reset"
kcase "K: a bound under the soft floor says nothing — the account is still blind" \
      2 "$(snap_ 20 "$FAR" "$STALE")" "" "no account reading measured within"

# THE PRECONDITION. The whole argument is "the window has not turned over", so
# every way of failing to show that must yield no bound at all.
kcase "K: a stale 100% whose window has already RESET is not a bound" \
      2 "$(snap_ 100 "$(( NOW - 3600 ))" "$STALE")" "" "no account reading measured within"
kcase "K: a stale 100% with no readable reset is not a bound" \
      2 "$(snap_ 100 null "$STALE")" "" "no account reading measured within"
# A reading stamped in the FUTURE is the clock-skew case, and it is what keeps
# `asof <= now < resets` — the chain that places the measurement inside the
# window it reports on — from being assumed rather than shown.
kcase "K: a reading stamped in the future is not a bound" \
      2 "$(snap_ 100 "$FAR" "$(( NOW + 600 ))")" "" "no account reading measured within"
kcase "K: an undated stale reading is not a bound" \
      2 "$(snap_ 100 "$FAR" null)" "" "no account reading measured within"
kcase "K: no snapshot at all is still blind, not a bound" \
      2 '{"accounts":[]}' "" "no account reading measured within"

# THE POLICY. A bound may only ever tighten what the blind branch would have
# returned. Under FIVE_PACE_BLIND=refuse the blind answer is already the
# tightest there is, so the bound must not be consulted — it could only loosen.
kbarm(){ # <blind-policy> <snapshot> -> "<rc> <verdict>"
  ( source src/task/grader_pool.sh
    # shellcheck disable=SC2317
    quota_snapshot_read(){ printf '%s' "$SNAP"; }
    SNAP="$2"; _PACE_BLIND="$1"
    local rc=0 out
    out=$(printf '' | _pace_band acct "$NOW") || rc=$?
    printf '%s %s' "$rc" "$out" )
}
kb=$(kbarm refuse "$(snap_ 100 "$FAR" "$STALE")"); [[ "${kb%% *}" == 1 ]] \
  && ok_ "K: under FIVE_PACE_BLIND=refuse a bound does not loosen the refusal" \
  || bad_ "K: under FIVE_PACE_BLIND=refuse a bound does not loosen the refusal" "rc=${kb%% *} want=1"
kb=$(kbarm soft "$(snap_ 100 "$FAR" "$STALE")"); [[ "${kb%% *}" == 3 ]] \
  && ok_ "K: CONTROL — the same fixture under the default policy DOES harden, so the arm above is not vacuous" \
  || bad_ "K: CONTROL — refuse-policy arm is not vacuous" "rc=${kb%% *} want=3"

# THE ORDERING, pinned deliberately rather than left to fall out: the bound is
# consulted ONLY after both CURRENT sources have failed. A live seat document
# still answers ahead of it. The alternative — vendor-reported 100% outranking
# our own activity log — is argued on the row body; this arm exists so flipping
# it is a decision and not a regression.
kcase "K: a live seat document still answers ahead of the bound" \
      0 "$(snap_ 100 "$FAR" "$STALE")" "$(mkjson 20 "$FAR")" "from the seat reading"


# ── L: the SESSION window, DIVE-4631 ───────────────────────────────────────
# The floor read the week and nothing else. Measured on this host 2026-09-19:
# `dev` at fiveHourPct 101 / sevenDayPct 12 read `open`, was handed a row, and
# died at the session wall mid-attempt. The meter that predicts that is the next
# field in the document the floor was already reading.
#
# `_pace_band` is now the COMBINER (tighter of the two); the old body is
# `_pace_band_7d`. Every arm above still runs against `_pace_band`, and they all
# feed a document with no 5h field at all — so those arms double as the
# compatibility check: a blind session window must change none of them.
F5=$(( NOW + 3*3600 ))               # the session window has 3h to run
F5_NEAR=$(( NOW + 120 ))             # 2 minutes to the reset — NOT a relaxation
F5_PAST=$(( NOW - 600 ))             # this window has already turned over

mk5(){ # <7d-pct> <7d-resets> <5h-pct> <5h-resets>
  printf '{"agents":[{"name":"s1","account":"acct","sevenDayPct":%s,"sevenDayResetsAt":%s,"fiveHourPct":%s,"fiveHourResetsAt":%s}]}' \
         "$1" "$2" "$3" "$4"
}
band5(){ # <7d-pct> <7d-resets> <5h-pct> <5h-resets> -> "<rc>"
  local rc=0
  printf '%s' "$(mk5 "$1" "$2" "$3" "$4")" | _pace_band acct "$NOW" >/dev/null || rc=$?
  printf '%s' "$rc"
}
say5(){ # same args -> the VERDICT text
  printf '%s' "$(mk5 "$1" "$2" "$3" "$4")" | _pace_band acct "$NOW" || true
}
lcase(){ # <label> <want-rc> <7d> <7dr> <5h> <5hr>
  local label="$1" want="$2"; shift 2
  local got; got=$(band5 "$@")
  [[ "$got" == "$want" ]] && ok_ "$label" || bad_ "$label" "expected band ${want}, got ${got}"
}

# L1 — lodar's number. 85% of the session window holds a medium row and still
# admits an urgent one: `hard`, never `refuse`.
lcase "L1: 5h=85% (the cutoff) with a healthy week -> hard" 3 20 "$FAR" 85 "$F5"
[[ "$(adm 3 medium standard)" == "1" ]] && ok_ "L1: at the 5h cutoff a MEDIUM row is held" \
  || bad_ "L1: medium held" "expected a hold"
[[ "$(adm 3 urgent standard)" == "0" ]] && ok_ "L1: at the 5h cutoff an URGENT row still dispatches (hard, never refuse)" \
  || bad_ "L1: urgent admitted" "expected a dispatch"
lcase "L2: 5h=84% is under the cutoff -> no hold" 0 20 "$FAR" 84 "$F5"
lcase "L2: the filed case, 5h=101% / 7d=12% -> hard (this is the row)" 3 12 "$FAR" 101 "$F5"

# L3 — THE DECISION THAT BREAKS THE BOX IF IT IS WRONG. A blind 5h reading
# contributes NOTHING. `fiveHourPct: null` is ordinary steady state (5 of 15
# seats on this host read null), and the weekly already holds a blind account at
# the soft floor — a second hold on the same silence double-counts it.
lcase "L3: a NULL 5h with a healthy week still dispatches (blind 5h contributes nothing)" 0 20 "$FAR" null "$F5"
lcase "L3: a NULL 5h AND a null week is ONE hold at the soft floor, not two" 2 null "$FAR" null null
lcase "L3: an UNPARSEABLE 5h contributes nothing either" 0 20 "$FAR" '"78%"' "$F5"

# L4 — decision 3: a 5h window turns over five times a day, so a stale high
# reading is the common case. A reading whose reset has passed is dropped.
lcase "L4: 5h=101% from a window that has ALREADY reset is dropped" 0 20 "$FAR" 101 "$F5_PAST"
# ...but an ABSENT reset is not a passed one, and the unmeasured case never buys
# dispatch — same posture as the weekly's unreadable-reset branch.
lcase "L4: 5h=101% with NO readable reset leaves the floor armed" 3 20 "$FAR" 101 null

# L5 — decision 4: no near-reset relaxation. The weekly relaxes inside
# _PACE_RESET_DAYS because unspent headroom expires; this floor is not a pacing
# rule, so being near the reset is a reason to WAIT for a whole window.
lcase "L5: 2 minutes to the 5h reset is NOT a relaxation" 3 20 "$FAR" 95 "$F5_NEAR"

# L6 — the tighter band wins, in BOTH directions.
lcase "L6: 5h hard + week open   -> hard (the 5h tightens)" 3 20 "$FAR" 101 "$F5"
lcase "L6: 5h open + week hard   -> hard (the weekly tightens)" 3 95 "$FAR" 10 "$F5"
lcase "L6: 5h hard + week soft   -> hard (tighter of the two)" 3 70 "$FAR" 101 "$F5"
lcase "L6: 5h open + week soft   -> soft (the 5h does not loosen it)" 2 70 "$FAR" 10 "$F5"
lcase "L6: both open             -> open" 0 20 "$FAR" 10 "$F5"

# L7 — the 5h band can never produce `refuse`, and can never loosen one.
( _PACE_BLIND=refuse
  rc=0; printf '%s' "$(mk5 20 "$FAR" 101 "$F5")" | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == "3" ]] && exit 0 || exit 1 ) \
  && ok_ "L7: even under FIVE_PACE_BLIND=refuse the 5h band tops out at hard" \
  || bad_ "L7: 5h never refuses" "expected 3"
( _PACE_BLIND=refuse
  rc=0; printf '%s' "$(mk5 null "$FAR" 101 "$F5")" | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == "1" ]] && exit 0 || exit 1 ) \
  && ok_ "L7: a refusal from the weekly is tighter than the 5h hold and still wins" \
  || bad_ "L7: refuse still wins" "expected 1"

# L8 — the knob is a knob.
( FIVE_PACE_5H=50; source src/task/grader_pool.sh
  rc=0; printf '%s' "$(printf '{"agents":[{"account":"acct","sevenDayPct":20,"sevenDayResetsAt":%s,"fiveHourPct":60,"fiveHourResetsAt":%s}]}' "$FAR" "$F5")" \
    | _pace_band acct "$NOW" >/dev/null || rc=$?
  [[ "$rc" == "3" ]] && exit 0 || exit 1 ) \
  && ok_ "L8: FIVE_PACE_5H moves the session floor" || bad_ "L8: FIVE_PACE_5H" "60% did not hold at a floor of 50"
lcase "L8: CONTROL — the same 60% does NOT hold at the default 85" 0 20 "$FAR" 60 "$F5"

# L9 — max across the account's seats. CONFIRMED on the live document before it
# was written: every chemmonitor seat reported 38/39/38% against ONE
# fiveHourResetsAt, so the window is per-ACCOUNT and any seat answers for it.
got=$(printf '{"agents":[{"account":"acct","sevenDayPct":20,"sevenDayResetsAt":%s,"fiveHourPct":5,"fiveHourResetsAt":%s},{"account":"acct","sevenDayPct":20,"sevenDayResetsAt":%s,"fiveHourPct":101,"fiveHourResetsAt":%s}]}' \
        "$FAR" "$F5" "$FAR" "$F5" | { _pace_band acct "$NOW" >/dev/null; printf '%s' "$?"; })
[[ "$got" == "3" ]] && ok_ "L9: max across the account's seats — one seat at 101% answers for the pool" \
  || bad_ "L9: max across seats" "expected 3, got ${got}"

# L13 — TWO SEATS OF ONE ACCOUNT THAT DISAGREE ABOUT THE CLOCK (quinn's
# iteration-1 finding). Every row of the usage document comes from that SEAT's
# own statusline cache, rewritten only when the seat runs, so a seat idle since
# it hit the wall carries a stale pct AND the stale reset that belongs to it
# while a busy sibling carries a current pair. L4 (expired -> dropped) is
# single-seat and L9 gives both seats the SAME reset, so neither of them can see
# a per-FIELD max pick the pct from one seat and the clock from the other. This
# arm is the one that does: the over-floor seat's window turned over an hour
# ago, the under-floor seat's is live, and the account must NOT be held.
mk5_two(){ # <5h-a> <5hr-a> <5h-b> <5hr-b>  — one account, two seats, healthy week
  printf '{"agents":[{"name":"stale","account":"acct","sevenDayPct":20,"sevenDayResetsAt":%s,"fiveHourPct":%s,"fiveHourResetsAt":%s},{"name":"fresh","account":"acct","sevenDayPct":20,"sevenDayResetsAt":%s,"fiveHourPct":%s,"fiveHourResetsAt":%s}]}' \
         "$FAR" "$1" "$2" "$FAR" "$3" "$4"
}
band_two(){ local rc=0; printf '%s' "$(mk5_two "$@")" | _pace_band acct "$NOW" >/dev/null || rc=$?; printf '%s' "$rc"; }
got=$(band_two 101 "$F5_PAST" 5 "$F5")
[[ "$got" == "0" ]] \
  && ok_ "L13: a stale 101% whose OWN window has reset, beside a live 5%, does not hold the account" \
  || bad_ "L13: cross-seat clock pairing" "expected 0, got ${got} — the pct and the reset were maxed independently"
# ...and the same document with the stale seat's window still LIVE must hold, or
# the arm above would pass simply because two seats never hold anything.
got=$(band_two 101 "$F5" 5 "$F5")
[[ "$got" == "3" ]] \
  && ok_ "L13: CONTROL — the same two seats with the 101% window still live DO hold (L13 is not vacuous)" \
  || bad_ "L13: cross-seat control" "expected 3, got ${got}"
# The mirror: the OVER-floor seat is the fresh one and the stale sibling is
# under the floor. The survivor is 101%, so the hold stands — a per-reading
# fence must not throw away a live reading just because a sibling is stale.
got=$(band_two 5 "$F5_PAST" 101 "$F5")
[[ "$got" == "3" ]] \
  && ok_ "L13: a live 101% beside a stale 5% still holds (the fence drops readings, not accounts)" \
  || bad_ "L13: mirror" "expected 3, got ${got}"

# L10 — the operator reading a hold needs the exit for the band that caused it.
v=$(say5 20 "$FAR" 101 "$F5")
[[ "$v" == *"5-hour session window"* && "$v" == *"weekly:"* ]] \
  && ok_ "L10: the verdict names the session window AND carries the weekly reading" \
  || bad_ "L10: verdict text" "got '${v}'"
grep -q 'FIVE_PACE_5H' src/cmd_heartbeat.sh \
  && ok_ "L10: the held-row log line names FIVE_PACE_5H as an exit" \
  || bad_ "L10: the held-row log line" "the operator has no exit for the 5h band"

# L11 — BOTH halves are fed with a here-string, and the combiner reads stdin
# before any early return, so a PIPE cannot hand a caller an EPIPE status in
# place of a band. Both shipping call sites pipe.
got=$(printf '%s' "$(mk5 20 "$FAR" 10 "$F5")" | { _pace_band "" "$NOW" >/dev/null; printf '%s' "$?"; })
[[ "$got" == "2" ]] && ok_ "L11: the no-account path through a PIPE returns the band (2), not a pipe status" \
  || bad_ "L11: pipe safety" "expected 2, got ${got}"

# L12 — THE DIFFERENTIAL, through the block that actually ships. Section D
# graded the dispatch block on the weekly alone; these two arms drive the SAME
# verbatim-extracted block with a document that carries a 5h field, so the
# combiner is graded where it is really called and not only at the function.
if declare -F probe_board >/dev/null 2>&1; then
  got_5h=$(probe_board "$(mk5 20 "$FAR" 101 "$F5")")
  [[ "$got_5h" == "DIVE-1 " ]] \
    && ok_ "L12: the shipping dispatch block holds everything but the urgent row on a 101% session window" \
    || bad_ "L12: dispatch block, 5h hard" "expected 'DIVE-1 ', got '${got_5h}'"
  got_5o=$(probe_board "$(mk5 20 "$FAR" 10 "$F5")")
  [[ "$got_5o" == "DIVE-1 DIVE-2 DIVE-3 DIVE-4 " ]] \
    && ok_ "L12: CONTROL — the same block with a healthy session window dispatches all four (the arm above is not vacuous)" \
    || bad_ "L12: dispatch block, 5h open" "expected all four rows, got '${got_5o}'"
else
  bad_ "L12: the dispatch-block differential" "probe_board is not defined — section D's extraction failed, so this arm cannot run"
fi

# ── M: the mutants ─────────────────────────────────────────────────────────
# Every L arm above is paired here with a mutation that reverts the fix, so a
# green L section cannot be green vacuously.
MUT="$TMPD/mut.sh"
grep -q '_pace_band_5h' src/task/grader_pool.sh && grep -q '_PACE_FLOOR_5H' src/task/grader_pool.sh \
  && ok_ "M0: the session floor is IN the shipped source (the mutants below are not vacuous)" \
  || bad_ "M0: the session floor is in the shipped source" "not found"
mutant(){ # <sed-expr> ; writes $MUT, returns 1 if the sed did not change anything
  sed "$1" src/task/grader_pool.sh > "$MUT"
  ! cmp -s "$MUT" src/task/grader_pool.sh
}
mband(){ # <7d> <7dr> <5h> <5hr> -> rc, against the MUTANT
  ( source "$MUT"
    rc=0; printf '%s' "$(mk5 "$1" "$2" "$3" "$4")" | _pace_band acct "$NOW" >/dev/null || rc=$?
    printf '%s' "$rc" )
}
# M1 — the combiner never asks the session window (the pre-fix behaviour).
if mutant 's|^  v5=$(_pace_band_5h .*|  v5="" rc5=0|'; then
  ok_ "M1: the mutation took (the combiner no longer consults the 5h band)"
  [[ "$(mband 20 "$FAR" 101 "$F5")" == "0" ]] \
    && ok_ "M1: REVERTED — 5h=101% / 7d=20% reads 'open' again, exactly the filed defect" \
    || bad_ "M1: the mutant did not flip the arm" "L1/L6 would pass against a floor that is not there"
else bad_ "M1: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# M2 — decision 2 reverted: a blind 5h HOLDS instead of contributing nothing.
if mutant 's|^    printf .pace/5h: %s has no session-window reading.*|    printf "pace/5h: MUTANT blind hold\\n" "$acct"; return 3|'; then
  ok_ "M2: the mutation took (a blind 5h now holds)"
  [[ "$(mband 20 "$FAR" null "$F5")" == "3" ]] \
    && ok_ "M2: REVERTED — a null 5h now holds a healthy seat, which is the fleet-wide freeze L3 forbids" \
    || bad_ "M2: the mutant did not flip the arm" "L3 is not grading the blind branch"
else bad_ "M2: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# M3 — decision 3 reverted: the per-reading expired-window fence removed.
if mutant 's|^    if _grader_reading_expired "${reset%%.\*}" "$now"; then continue; fi|    if false; then continue; fi|'; then
  ok_ "M3: the mutation took (the expired-window fence is gone)"
  [[ "$(mband 20 "$FAR" 101 "$F5_PAST")" == "3" ]] \
    && ok_ "M3: REVERTED — a reading from a window that already reset holds again" \
    || bad_ "M3: the mutant did not flip the arm" "L4 is not grading the reset fence"
else bad_ "M3: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# M3b — the PRE-FIX reduction restored verbatim: max the pct over the seats, max
# the reset over the seats separately, then fence the one against the other.
# This is the shape that shipped at 319f9074 and that quinn rejected. It leaves
# L4 GREEN — which is the whole point, and is asserted below, because it is what
# makes L13 and not L4 the arm that catches this.
if mutant 's#^  five=$(printf .%s. "$json" | _pace_field_5h "$acct" "$now")#  five=$(printf "%s" "$json" | _pace_field "$acct" fiveHourPct); _mr=$(printf "%s" "$json" | _pace_field "$acct" fiveHourResetsAt); if _grader_reading_expired "${_mr%%.*}" "$now"; then five=""; fi#'; then
  ok_ "M3b: the mutation took (the pct and the reset are maxed independently again)"
  mband_two(){ ( source "$MUT"
      rc=0; printf '%s' "$(mk5_two "$@")" | _pace_band acct "$NOW" >/dev/null || rc=$?; printf '%s' "$rc" ); }
  [[ "$(mband_two 101 "$F5_PAST" 5 "$F5")" == "3" ]] \
    && ok_ "M3b: REVERTED — the stale 101% is fenced against the SIBLING's live clock and pins the account at hard" \
    || bad_ "M3b: the mutant did not flip the arm" "L13 is not grading the pct/reset pairing"
  [[ "$(mband 20 "$FAR" 101 "$F5_PAST")" == "0" ]] \
    && ok_ "M3b: the single-seat arm L4 stays GREEN against this mutant — L13 is what catches it" \
    || bad_ "M3b: L4 under the mutant" "expected 0; this mutant is not the pre-fix shape"
else bad_ "M3b: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# M4 — the ranking reverted: the LOOSER band wins the combine.
if mutant 's|^  if (( $(_pace_rank "$rc5") > $(_pace_rank "$rc7") )); then|  if false; then|'; then
  ok_ "M4: the mutation took (the 5h band can no longer win the combine)"
  [[ "$(mband 20 "$FAR" 101 "$F5")" == "0" ]] \
    && ok_ "M4: REVERTED — the tighter band no longer wins, and the filed case dispatches" \
    || bad_ "M4: the mutant did not flip the arm" "L6 is not grading the combiner"
else bad_ "M4: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# M5 — the floor itself moved out of reach: 101% no longer clears it.
if mutant 's|^_PACE_FLOOR_5H=.*|_PACE_FLOOR_5H=999|'; then
  ok_ "M5: the mutation took (the session floor was raised out of reach)"
  [[ "$(mband 20 "$FAR" 101 "$F5")" == "0" ]] \
    && ok_ "M5: REVERTED — with the floor at 999% the filed case dispatches again" \
    || bad_ "M5: the mutant did not flip the arm" "L1 is not grading the threshold"
else bad_ "M5: the mutation took" "the sed matched nothing — this mutant is vacuous"; fi
# The mutants ran in subshells against $MUT; this process still holds the real
# source. Re-source it so nothing below grades a mutant.
# shellcheck source=/dev/null
source src/task/grader_pool.sh
[[ "$(band5 20 "$FAR" 101 "$F5")" == "3" ]] \
  && ok_ "M6: RESTORE — the shipping source is back in this process (later arms grade the product)" \
  || bad_ "M6: RESTORE" "the process is still holding a mutant"
# ── M (DIVE-4629): A PROVIDER THAT PUBLISHES NO WEEKLY WINDOW AT ALL ───────
#
# Every arm above grades a number that EXISTS and could not be read. These
# grade the other state: `codex`'s three seats run a CLI with no Anthropic 5h/7d
# window, so no carrier, cadence or bound can ever produce one and the blind
# soft floor held them at high|urgent-only permanently (DIVE-4586's signed
# residual). What must hold:
#
#   1. the classification is POSITIVE — read off the REGISTRY (which seats are
#      bound and what they run), never off the meter's silence, so a carrier
#      outage on a claude account can never reach the new branch;
#   2. any doubt at all — no registry, no bound seat, one unreadable type, one
#      claude sibling — is `unknown` and changes NOTHING;
#   3. a real reading, and even a stale-but-unreset lower bound, still answers
#      AHEAD of the new branch. Capability is the last question asked, never the
#      first;
#   4. `FIVE_PACE_BLIND=refuse` is not loosened by it, and the verdict says the
#      unmetered policy was not consulted rather than leaving a silent no-op.

# M1 — `_pace_seat_types` against a REAL registry file, including the
# `@self:<name>` synthesis the floor's callers use and a seat with no type.
MREG="$TMPD/agents.json"
cat > "$MREG" <<'JSON'
{"agents": {
  "codexy":  {"type": "codex",  "authProfile": "codex"},
  "vesper":  {"type": "codex",  "authProfile": "codex"},
  "claudey": {"type": "claude", "authProfile": "mark"},
  "mixed1":  {"type": "codex",  "authProfile": "mixed"},
  "mixed2":  {"type": "claude", "authProfile": "mixed"},
  "untyped": {"authProfile": "partial"},
  "typed":   {"type": "codex",  "authProfile": "partial"},
  "selfie":  {"type": "codex"}
}}
JSON
mtypes(){ ( REGISTRY="$MREG"; source src/task/grader_pool.sh; _pace_seat_types "$1" | sort | tr '\n' ' ' ); }
[[ "$(mtypes codex)" == "codex codex " ]] \
  && ok_ "M1: _pace_seat_types reads the registry binding" \
  || bad_ "M1: _pace_seat_types" "got '$(mtypes codex)'"
[[ "$(mtypes '@self:selfie')" == "codex " ]] \
  && ok_ "M1: the @self:<name> synthesis is the one the floor's callers pass" \
  || bad_ "M1: @self synthesis" "got '$(mtypes '@self:selfie')'"
[[ "$(mtypes partial)" == "? codex " ]] \
  && ok_ "M1: a seat with no readable type is reported as ? and not silently dropped" \
  || bad_ "M1: untyped seat" "got '$(mtypes partial)'"

# M2 — the classifier's three answers. 1 is the only one that is evidence.
mcap(){ ( REGISTRY="${2-$MREG}"; source src/task/grader_pool.sh
          local rc=0; _pace_window_capable "$1" || rc=$?; printf '%s' "$rc" ); }
for probe in "codex 1" "mark 0" "mixed 0" "partial 2" "@self:selfie 1" "nosuchaccount 2"; do
  read -r acct want <<<"$probe"
  got=$(mcap "$acct")
  [[ "$got" == "$want" ]] && ok_ "M2: _pace_window_capable ${acct} -> ${want}" \
    || bad_ "M2: _pace_window_capable ${acct}" "expected ${want}, got ${got}"
done
got=$(mcap codex "$TMPD/no-such-registry.json")
[[ "$got" == "2" ]] && ok_ "M2: NO READABLE REGISTRY is unknown (2), never 'unmeterable' — absence is not evidence" \
  || bad_ "M2: unreadable registry" "expected 2, got ${got}"

# M3 — the band. `marm <types> <usage-json> <snapshot-json>` in a subshell so
# the caller can set FIVE_PACE_* before the file is sourced.
marm(){ # <types|""> <usage-json|""> <snapshot-json|""> -> "<rc> <verdict>"
  ( source src/task/grader_pool.sh
    MTYPES="$1"; MSNAP="$3"
    # shellcheck disable=SC2317
    _m_types(){ local t; for t in $MTYPES; do printf '%s\n' "$t"; done; }
    # shellcheck disable=SC2317
    quota_snapshot_read(){ printf '%s' "$MSNAP"; }
    _PACE_SEAT_TYPES_CMD=_m_types
    local rc=0 out
    out=$(printf '%s' "$2" | _pace_band acct "$NOW") || rc=$?
    printf '%s %s' "$rc" "$out" )
}
mcase(){ # <label> <want-rc> <types> <usage-json> <snapshot-json> <want-substr>
  local got; got=$(marm "$3" "$4" "$5")
  if [[ "${got%% *}" == "$2" && "${got#* }" == *"$6"* ]]; then ok_ "$1"
  else bad_ "$1" "rc=${got%% *} want=$2 | verdict: ${got#* }"; fi
}
msnap(){ printf '{"accounts":[{"name":"acct","usage":{"asOf":%s,"sevenDay":{"pct":%s,"resetsAt":%s}}}]}' "$3" "$1" "$2"; }
MSTALE=$(( NOW - 7200 ))

mcase "M3: an account whose every bound seat runs a provider with no weekly window is NOT blind — the floor has no jurisdiction and says so" \
      0 "codex" "" "" "no weekly usage window at all"
mcase "M3: ...and the verdict refuses the 0% reading explicitly" \
      0 "codex" "" "" "not a reading of 0%"
mcase "M3: CONTROL — one claude seat on the account and it is blind-held exactly as before" \
      2 "claude codex" "" "" "no weekly reading"
mcase "M3: CONTROL — an unreadable seat type is doubt, and doubt holds" \
      2 "? codex" "" "" "no weekly reading"
mcase "M3: CONTROL — no bound seat at all is unknown, not unmeterable" \
      2 "" "" "" "no weekly reading"

# ORDERING. Capability is the LAST question. A current reading answers first...
mcase "M3: a CURRENT seat reading still answers ahead of the capability branch" \
      3 "codex" "$(mkjson 95 "$FAR")" "" "from the seat reading"
# ...and so does DIVE-4586's stale-but-unreset lower bound, which is the arm
# that keeps this row from re-opening a floor that one already closed.
mcase "M3: DIVE-4586's lower bound still hardens an unmeterable-looking account" \
      3 "codex" "" "$(msnap 100 "$FAR" "$MSTALE")" "at AT LEAST 100%"

# THE POLICY KNOB, every value, including one that is not a value.
for probe in "open 0" "soft 2" "hard 3" "refuse 1"; do
  read -r pol want <<<"$probe"
  got=$( FIVE_PACE_UNMETERED="$pol" marm "codex" "" "" )
  [[ "${got%% *}" == "$want" ]] && ok_ "M4: FIVE_PACE_UNMETERED=${pol} -> band ${want}" \
    || bad_ "M4: FIVE_PACE_UNMETERED=${pol}" "expected ${want}, got ${got%% *}"
done
got=$( FIVE_PACE_UNMETERED=banana marm "codex" "" "" )
[[ "${got%% *}" == "2" && "${got#* }" == *"is not a policy I know"* ]] \
  && ok_ "M4: an unrecognised policy falls back to the soft floor and names itself" \
  || bad_ "M4: unrecognised policy" "rc=${got%% *} want=2 | ${got#* }"
# A `%` in the env value must not be read as a printf conversion.
got=$( FIVE_PACE_UNMETERED='100%s%d' marm "codex" "" "" )
[[ "${got#* }" == *'100%s%d'* ]] \
  && ok_ "M4: the policy value is a printf ARGUMENT, not part of the format" \
  || bad_ "M4: printf format injection" "verdict: ${got#* }"

# FIVE_PACE_BLIND=refuse is an operator's explicit freeze and the new branch
# does not loosen it — and the verdict says the knob was not consulted, which is
# what keeps it from reading as a knob that quietly does nothing.
got=$( FIVE_PACE_BLIND=refuse FIVE_PACE_UNMETERED=open marm "codex" "" "" )
[[ "${got%% *}" == "1" && "${got#* }" == *"not consulted under refuse"* ]] \
  && ok_ "M4: FIVE_PACE_BLIND=refuse is not loosened by the capability branch, and says so" \
  || bad_ "M4: refuse + unmeterable" "rc=${got%% *} want=1 | ${got#* }"

# M5 — `_pace_admits` is untouched by all of this: band 0 dispatches every
# priority AND the recurring beats, which is what "no hold" has to mean.
mad=0
for probe in "low standard" "low recurring" "urgent recurring"; do
  read -r prio kind <<<"$probe"
  _pace_admits 0 "$prio" "$kind" || mad=1
done
(( mad == 0 )) && ok_ "M5: band 0 admits every priority and the recurring beats — the seats are genuinely unheld" \
  || bad_ "M5: band 0 admits" "a row was still held under the open band"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
