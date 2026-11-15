#!/usr/bin/env bash
# DIVE-8512 unit: the seat document's weekly reading is a lower bound too, and a
# blind admit is not silent.
#
# THE INCIDENT. chill-gorge, 4 nights in 13 days, always the first ticks after
# the 20:00Z nightly update:
#   20:05:14Z DIVE-1305 (high) HELD — hard band: acct-1 is at 99% (from the seat reading)
#   20:10:21Z due + todo DIVE-1305 — waking (fresh=false)
# The account carrier was empty, so the only 99% the floor had came from the
# seat usage document. The re-collect five minutes later (the cache TTL) was
# non-empty but had no reading for acct-1 (seats just restarted), so the floor
# went BLIND, which is OPEN under the shipped default, and logged nothing.
#
# WHAT IS ASSERTED HERE, under the shipped defaults (95/95, FIVE_PACE_BLIND=open),
# with the account carrier and its bound EMPTY on every tick, through the real
# `_pace_usage_snapshot` -> `_pace_band` -> `_pace_admits` path:
#   A.  tick 1 doc: acct-1 at 99%, reset in the future -> high row HELD (band 3).
#       tick 2 doc: non-empty, nothing for acct-1 -> still band 3, still HELD.
#       (Red on the pre-fix tree: band 0, dispatched.)
#   B.  NEGATIVE CONTROL: tick 1's reset already passed -> tick 2 is the blind
#       policy unchanged (open). B2: the remembered window turns over between the
#       ticks -> open again.
#   C.  NEGATIVE CONTROL: tick 2 carries acct-1 at 40% -> the measured reading
#       wins (open, "from the seat reading"); C2: a tick 3 that drops acct-1 again
#       is bounded by the LAST reading (40%), so still open.
#   D.  A blind admit names its band and verdict on the wake line; a measured
#       open admit adds nothing. The wake snippet is extracted from the shipping
#       src/cmd_heartbeat.sh, not retyped.
#   E.  The remembered pct is paired with ITS OWN reset: a 99% seat whose window
#       already turned over is not remembered with a sibling's future reset.
# Run: bash tests/pace_seat_bound_unit.sh  (no root, no network)
# Mutation: PACE_SRC=<pre-fix pace.sh> bash tests/pace_seat_bound_unit.sh -> A red.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pace-seat-bound.XXXXXX")"
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
PASS=0; FAIL=0
ok_(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad_(){ FAIL=$((FAIL+1)); printf 'FAIL %s — %s\n' "$1" "${2:-}"; }

unset FIVE_PACE_7D_SOFT FIVE_PACE_7D_HARD FIVE_PACE_5H FIVE_PACE_BLIND FIVE_PACE_UNMETERED
export BOX_CONFIG="$TMP/box.json"; printf '{}\n' >"$BOX_CONFIG"
export FIVE_PACE_READING_CACHE_DIR="$TMP/pace-reading"
export FIVE_PACE_CACHE_FILE="$TMP/pace-usage.json"
export FIVE_PACE_SEAT_BOUND_FILE="$TMP/pace-usage.seat-bound.json"
export FIVE_PACE_CACHE_SEC=300
PACE_SRC="${PACE_SRC:-src/lib/pace.sh}"
# shellcheck disable=SC1090
source "$PACE_SRC"
empty_(){ return 0; }
_PACE_ACCOUNT_CMD=empty_          # the account carrier is empty on every tick
_PACE_ACCOUNT_BOUND_CMD=empty_    # ...and so is its bound (same carrier)
_PACE_WINDOW_CAPABLE_CMD=true     # a claude account: blind means blind

NOW=$(date -u +%s)
FUT=$(( NOW + 9*3600 ))           # this week resets in 9h (05:00Z next morning)
PAST=$(( NOW - 3600 ))
DOC=""
usage_(){ printf '%s' "$DOC"; }
_PACE_USAGE_CMD=usage_

row(){ # <account> <pct|null> <reset|null>
  printf '{"name":"s-%s","account":"%s","sevenDayPct":%s,"sevenDayResetsAt":%s,"fiveHourPct":null}' "$RANDOM" "$1" "$2" "$3"
}
doc(){ local IFS=,; printf '{"agents":[%s]}' "$*"; }
OTHER=$(row acct-2 20 "$FUT")     # tick 2 is non-empty: another account still reports

fresh(){ rm -f "$FIVE_PACE_CACHE_FILE" "$FIVE_PACE_SEAT_BOUND_FILE"; }
tick(){ # <doc> [<now>] -> "<rc>\t<verdict>"; expires the usage cache first, as five minutes would
  DOC="$1"; local n="${2:-$NOW}" snap v rc=0
  [[ -f "$FIVE_PACE_CACHE_FILE" ]] && touch -d '10 minutes ago' "$FIVE_PACE_CACHE_FILE"
  snap=$(_pace_usage_snapshot)
  v=$(printf '%s' "$snap" | _pace_band acct-1 "$n") || rc=$?
  printf '%s\t%s' "$rc" "$v"
}
admits(){ _pace_admits "$1" high standard && echo dispatched || echo held; }

# ── A ──────────────────────────────────────────────────────────────────────
fresh
t1=$(tick "$(doc "$(row acct-1 99 "$FUT")" "$OTHER")")
t2=$(tick "$(doc "$OTHER")")
rc1=${t1%%$'\t'*}; rc2=${t2%%$'\t'*}; v2=${t2#*$'\t'}
[[ "$rc1" == 3 && "$(admits "$rc1")" == held ]] \
  && ok_ "A1: tick 1, acct-1 at 99% from the seat doc, carrier empty -> band 3, high row held" \
  || bad_ "A1" "rc=$rc1 verdict=${t1#*$'\t'}"
[[ "$rc2" == 3 && "$(admits "$rc2")" == held ]] \
  && ok_ "A2: tick 2, the doc drops acct-1 -> band 3 from the remembered seat reading, high row still held" \
  || bad_ "A2 (the chill-gorge admit)" "rc=$rc2 admit=$(admits "$rc2") verdict=$v2"
[[ "$v2" == *"last seat reading (99%)"* ]] \
  && ok_ "A3: the hold names its source (the last seat reading, 99%)" \
  || bad_ "A3" "verdict=$v2"

# ── B ──────────────────────────────────────────────────────────────────────
fresh
tick "$(doc "$(row acct-1 99 "$PAST")" "$OTHER")" >/dev/null
t2=$(tick "$(doc "$OTHER")"); rc2=${t2%%$'\t'*}; v2=${t2#*$'\t'}
[[ "$rc2" == 0 && "$v2" == *"blind meter, policy=open"* ]] \
  && ok_ "B1: tick 1's window had already turned over -> nothing remembered, tick 2 is blind/open as before" \
  || bad_ "B1" "rc=$rc2 verdict=$v2"
fresh
tick "$(doc "$(row acct-1 99 "$FUT")" "$OTHER")" >/dev/null
t2=$(tick "$(doc "$OTHER")" $(( FUT + 60 ))); rc2=${t2%%$'\t'*}
[[ "$rc2" == 0 ]] \
  && ok_ "B2: the remembered window turns over before tick 2 -> the bound is dropped, open" \
  || bad_ "B2" "rc=$rc2 verdict=${t2#*$'\t'}"

# ── C ──────────────────────────────────────────────────────────────────────
fresh
tick "$(doc "$(row acct-1 99 "$FUT")" "$OTHER")" >/dev/null
t2=$(tick "$(doc "$(row acct-1 40 "$FUT")" "$OTHER")"); rc2=${t2%%$'\t'*}; v2=${t2#*$'\t'}
[[ "$rc2" == 0 && "$v2" == *"7d=40%"*"from the seat reading"* && "$v2" != *"99"* ]] \
  && ok_ "C1: tick 2 carries acct-1 at 40% -> the measured reading wins, the remembered 99% is not consulted" \
  || bad_ "C1" "rc=$rc2 verdict=$v2"
t3=$(tick "$(doc "$OTHER")"); rc3=${t3%%$'\t'*}
[[ "$rc3" == 0 ]] \
  && ok_ "C2: a tick 3 that drops acct-1 again is bounded by the LAST reading (40%), not the old 99% -> open" \
  || bad_ "C2" "rc=$rc3 verdict=${t3#*$'\t'}"

# ── D ──────────────────────────────────────────────────────────────────────
HB=src/cmd_heartbeat.sh
s=$(grep -n '# DIVE-8512: a row the pacing floor admitted BLIND' "$HB" | head -1 | cut -d: -f1)
e=$(awk -v s="${s:-0}" 'NR>s && /due \+ todo \$\{task_ident\} — waking/ {print NR; exit}' "$HB")
if [[ -n "$s" && -n "$e" ]]; then
  SNIP=$(sed -n "${s},${e}p" "$HB")
  ok_ "D0: the wake-line snippet extracted from $HB (lines $s-$e)"
else
  SNIP=""; bad_ "D0: wake-line snippet" "start=[$s] end=[$e]"
fi
wake_line(){ # <pace_rc> <pace_verdict> -> the logged wake line
  local LOGL=""; _hb_log(){ LOGL="$*"; }
  local name=seat1 task_ident=DIVE-1305 eff_fresh=false _pace_rc="$1" _pace_verdict="$2"
  wrap(){ eval "$SNIP"; }; wrap
  printf '%s' "$LOGL"
}
fresh
t2=$(tick "$(doc "$OTHER")"); rc2=${t2%%$'\t'*}; v2=${t2#*$'\t'}
wl=$(wake_line "$rc2" "$v2")
[[ "$rc2" == 0 && "$wl" == *"waking (fresh=false, pace=open: pace: acct-1 has no weekly reading"*"blind meter, policy=open"* ]] \
  && ok_ "D1: a blind admit names its band and the blind verdict on the wake line" \
  || bad_ "D1" "rc=$rc2 line=$wl"
[[ $(grep -c . <<<"$wl") == 1 ]] && ok_ "D2: ...on ONE line" || bad_ "D2" "line=$wl"
t2=$(tick "$(doc "$(row acct-1 40 "$FUT")")"); rc2=${t2%%$'\t'*}; v2=${t2#*$'\t'}
wl=$(wake_line "$rc2" "$v2")
[[ "$rc2" == 0 && "$wl" == "[seat1] due + todo DIVE-1305 — waking (fresh=false)" ]] \
  && ok_ "D3: a measured open admit adds nothing to the wake line" \
  || bad_ "D3" "rc=$rc2 line=$wl"
for bv in "pace: no account named — blind, never read as 0%; not held (FIVE_PACE_BLIND=open)" \
          "pace: acct-1 weekly meter is unparseable (7d=x) — blind, never read as 0%; not held (FIVE_PACE_BLIND=open)"; do
  [[ -n "$(_pace_wake_note 0 "$bv")" ]] || bad_ "D4: every blind verdict shape is recognised" "missed: $bv"
done
[[ -z "$(_pace_wake_note 0 "pace: acct-1 runs on a provider that publishes no weekly usage window at all: no hold")" \
   && -z "$(_pace_wake_note 0 "pace: the weekly floor is off on this box (pace-week=off, from config) — acct-1 is not held for its week")" ]] \
  && ok_ "D4: the no-account and unparseable blind verdicts are recognised; unmeterable and pace-week=off are not called blind" \
  || bad_ "D4" "a non-blind verdict was tagged blind"

# ── E ──────────────────────────────────────────────────────────────────────
fresh
tick "$(doc "$(row acct-1 99 "$PAST")" "$(row acct-1 50 "$FUT")" "$OTHER")" >/dev/null
got=$(jq -c '."acct-1" | [.pct, .resets]' "$FIVE_PACE_SEAT_BOUND_FILE" 2>/dev/null)
[[ "$got" == "[50,$FUT]" ]] \
  && ok_ "E: the remembered pct is paired with its own reset (99% from a turned-over window is not remembered)" \
  || bad_ "E" "remembered=$got"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
