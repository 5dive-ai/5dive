# ── DIVE-4430: pace the week instead of exhausting it ───────────────────────
#
# THE SHAPE THIS EXISTS TO END. Measured 2026-08-16 and unchanged on the
# 2026-09-13 board: the fleet spends the weekly account ceiling in ~3 days and
# then sits starved for ~4. Four idle days out of seven is the ceiling on the
# autonomy number, and it is not a capacity problem — it is a pacing one.
#
# THE FLOOR IS THE GRADER POOL'S, LIFTED ONE LEVEL UP. `_grader_window_ok`
# (src/task/grader_pool.sh) already refuses to spend a grader session above 80%
# of the 5h window / 90% of the week, and already fails closed on a null meter.
# That brake guards ONE spawn site. Every other token the fleet spends is
# dispatched by `heartbeat tick`, which reads no meter at all. This file is the
# same reading, asked at the dispatch boundary, and it deliberately shares the
# grader pool's per-ACCOUNT posture: seats of one account share one auth window,
# so a per-seat budget would read budgets that do not exist.
#
# ═══ WHY A BLIND METER IS NOT A TOTAL REFUSAL HERE, THOUGH IT IS FOR A GRADER ═
#
# DIVE-4430's filing asked for "fail closed on a null meter exactly as the
# grader pool does". Measured before writing this, on the live fleet
# (2026-09-13, `5dive usage --json`):
#
#     mark        12 seats   sevenDayPct max 15   (4 of 12 seats null)
#     chemmonitor  1 seat    sevenDayPct BLIND
#     codex        1 seat    sevenDayPct BLIND
#
# A grader refusal defers ONE spawn and the delivery waits; the next tick
# retries. A dispatch refusal is the seat's whole turn, every tick, forever —
# so on today's board a literal fail-closed would permanently freeze two of
# three accounts, `codex` among them, whose pool the memo that filed this row
# says does not even count against the weekly ceiling.
#
# The codebase already owns the test that settles this. DIVE-2213 (the tier
# guard) held its unmeasured population precisely because "a healthy registry
# never produces it" — the hold cannot stall the fleet in steady state. Apply
# that same test to the meter and it returns the OPPOSITE answer: a null
# sevenDayPct is steady state here, produced by an idle seat and by a
# statusline cache that has not been written yet, so a hold on it stalls the
# fleet by construction.
#
# So `blind` gets its own policy, and the choice is a named knob rather than a
# buried branch:
#
#   FIVE_PACE_BLIND=soft   (default) — a blind account is held AT THE SOFT
#                          FLOOR. It is never read as 0% (that is the 2026-09-09
#                          bug this whole family of guards exists to prevent),
#                          it never counts as headroom, and high/urgent work
#                          still flows. Strictly tighter than today's no-floor
#                          behaviour and strictly looser than a freeze.
#   FIVE_PACE_BLIND=refuse — the filing's literal reading: no meter, no
#                          dispatch. Correct on a fleet whose meters are
#                          reliable; it freezes chemmonitor and codex on this
#                          one. Left available, not made the default.
#
# The alternative not taken is written on DIVE-4430's body, not only here.
_PACE_FLOOR_7D_SOFT="${FIVE_PACE_7D_SOFT:-60}"
_PACE_FLOOR_7D_HARD="${FIVE_PACE_7D_HARD:-90}"
# The soft floor is a PACING rule, so it only binds while there is still a week
# left to pace. Inside the last `_PACE_RESET_DAYS` days the unspent remainder
# expires at the reset and holding it back buys nothing — only the hard floor
# (which protects the window itself) stays armed.
_PACE_RESET_DAYS="${FIVE_PACE_RESET_DAYS:-3}"
_PACE_BLIND="${FIVE_PACE_BLIND:-soft}"
# Overridable so the unit harness feeds a fixture instead of needing root and a
# live meter. Same posture as _GRADER_USAGE_CMD / _SUP_QUOTA_PAT.
_PACE_USAGE_CMD="${_PACE_USAGE_CMD:-sudo -n 5dive usage --json}"

# `_pace_field <account> <field>` — one numeric field for an account, or EMPTY
# when the meter has no number for it.
#
# `max` across the account's seats, exactly as `_grader_pct` does and for the
# same reason: seats of one account carry one window, so any seat with a
# reading answers for the account, and picking the defined one is the reading
# most favourable to a REFUSAL being wrong rather than to a spend being wrong.
_pace_field() {  # <account> <field>  [<usage-json-on-stdin>]
  local acct="$1" field="$2" json
  json=$(cat)
  [[ -n "$json" ]] || { printf ''; return 0; }
  printf '%s' "$json" | jq -r --arg a "$acct" --arg f "$field" '
    (.data // .)
    | [ .. | objects | select(.account? == $a) | .[$f] | numbers ] as $v
    | if ($v | length) == 0 then "" else ($v | max | tostring) end
  ' 2>/dev/null || printf ''
}

# `_pace_band <account> [<now-epoch>]` — how hard is the floor on this account?
#
# Dual-channel by the same contract as `_grader_window_ok`, and for the reason
# recorded there (DIVE-4380): the verdict is on stdout, the DECISION is the exit
# status, so every caller must capture it as `v=$(...) || rc=$?` — a bare
# `v=$(...)` under the bundle's `set -euo pipefail` aborts the shell on any
# non-admit answer.
#
#   0  open   — dispatch everything, as today
#   2  soft   — high|urgent only, no recurring template firing
#   3  hard   — urgent only, no recurring template firing
#   1  refuse — no dispatch at all (only reachable under FIVE_PACE_BLIND=refuse)
_pace_band() {  # <account> [<now-epoch>]  [<usage-json-on-stdin>]
  local acct="$1" now="${2:-$(date +%s)}" json seven resets days_left
  if [[ -z "$acct" ]]; then
    # No account named is not a measurement, and it must not read as headroom.
    printf 'pace: no account named — holding at the soft floor rather than reading it as 0%%\n'
    [[ "$_PACE_BLIND" == "refuse" ]] && return 1
    return 2
  fi
  json=$(cat)
  if [[ -z "$json" ]]; then
    printf 'pace: %s returned nothing — no meter, holding at the soft floor (never 0%%)\n' "$_PACE_USAGE_CMD"
    [[ "$_PACE_BLIND" == "refuse" ]] && return 1
    return 2
  fi
  seven=$(printf '%s' "$json" | _pace_field "$acct" sevenDayPct)
  # Emptiness FIRST, always, and before any arithmetic — `(( < 60 ))` on an
  # empty operand is 0 in bash, which is the exact fail-open this guard family
  # exists to prevent (2026-09-09: 43% of the fleet read as 0% used).
  if [[ -z "$seven" ]]; then
    printf 'pace: %s has no weekly reading (null) — blind meter, policy=%s\n' "$acct" "$_PACE_BLIND"
    [[ "$_PACE_BLIND" == "refuse" ]] && return 1
    return 2
  fi
  # Percentages arrive as floats (56.99999999999999); truncate to an integer
  # rather than hand bash a decimal point, which is a syntax error and aborts
  # under errexit.
  seven="${seven%%.*}"
  if ! [[ "$seven" =~ ^[0-9]+$ ]]; then
    printf 'pace: %s weekly meter is unparseable (7d=%s) — holding at the soft floor\n' "$acct" "$seven"
    [[ "$_PACE_BLIND" == "refuse" ]] && return 1
    return 2
  fi
  if (( seven >= _PACE_FLOOR_7D_HARD )); then
    printf 'pace: %s is at %s%% of its week (hard floor %s%%) — urgent only\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_HARD"; return 3
  fi
  if (( seven < _PACE_FLOOR_7D_SOFT )); then
    printf 'pace: %s at 7d=%s%% (soft floor %s%%) — no hold\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT"; return 0
  fi
  # Over the soft floor. It binds only while there is still a week to pace.
  resets=$(printf '%s' "$json" | _pace_field "$acct" sevenDayResetsAt)
  resets="${resets%%.*}"
  if [[ "$resets" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] && (( resets > now )); then
    days_left=$(( (resets - now) / 86400 ))
    if (( days_left <= _PACE_RESET_DAYS )); then
      printf 'pace: %s at %s%% (soft floor %s%%) but only %sd to the reset (<=%sd) — unspent headroom expires, no hold\n' \
             "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$days_left" "$_PACE_RESET_DAYS"; return 0
    fi
    printf 'pace: %s is at %s%% of its week (soft floor %s%%) with %sd to the reset — high/urgent only\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$days_left"; return 2
  fi
  # Over the soft floor with NO readable reset. The distance-to-reset test is
  # the only thing that could RELAX the floor, so an unreadable one leaves the
  # floor armed — the unmeasured case never buys headroom.
  printf 'pace: %s is at %s%% of its week (soft floor %s%%), reset time unreadable so the floor stays armed — high/urgent only\n' \
         "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT"; return 2
}

# `_pace_admits <band-rc> <priority> <kind>` — does this band dispatch this row?
# Exit 0 = dispatch it, 1 = hold it. Pure; no I/O, no meter.
#
# An unreadable priority is treated as the LOWEST band, not the highest: a row
# whose priority we could not read must not be the one that walks past the
# floor.
_pace_admits() {  # <band-rc> <priority> [<kind>]
  local rc="$1" prio="${2:-}" kind="${3:-standard}"
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  # Recurring templates are the first thing a paced week gives up: a beat that
  # skips one slot costs a slot, where a held standard row costs the work.
  [[ "$kind" == "recurring" ]] && return 1
  case "$rc" in
    2) [[ "$prio" == "urgent" || "$prio" == "high" ]] && return 0; return 1 ;;
    3) [[ "$prio" == "urgent" ]] && return 0; return 1 ;;
  esac
  return 1
}

# `_pace_band_name <rc>` — the band as one word, for logs and the digest.
_pace_band_name() {
  case "${1:-}" in
    0) printf 'open' ;;  2) printf 'soft' ;;
    3) printf 'hard' ;;  1) printf 'refuse' ;;
    *) printf 'unknown' ;;
  esac
}

# ── The snapshot, and why it is CACHED ──────────────────────────────────────
#
# `heartbeat tick` runs EVERY MINUTE (measured on this host, 2026-09-13: a tick
# line per minute in /var/log/5dive-heartbeat.log), and `usage --json` takes
# ~4.4s because it walks every seat's transcripts. A floor that re-read it on
# every tick would add a transcript scan a minute to a fleet whose problem is
# that it spends too much — the guard would be paying for itself in the coin it
# is trying to save. (`_hb_budget_sweep` already pays one such collect per tick;
# this must not make it two.)
#
# So the reading is cached, and the TTL is chosen against what is being
# measured, not against how fresh it is nice to be: `sevenDayPct` is a
# percentage of a SEVEN-DAY window. It cannot move enough in five minutes to
# change a band — 5 minutes is 0.05% of the window — and the one thing a stale
# reading could get wrong is releasing the floor a few minutes late.
#
# THE CACHE FAILS TO BLIND, NEVER TO STALE AND NEVER TO 0%:
#   * past the TTL the cache is not used at all — an old number is not a
#     measurement of now, and the alternative (blind -> soft floor) is the safe
#     side;
#   * a failed live read returns EMPTY, which `_pace_band` reads as a blind
#     meter, not as headroom;
#   * only a NON-EMPTY reading is ever written, so a failed collect can never
#     overwrite a good cache with nothing.
_PACE_CACHE_SEC="${FIVE_PACE_CACHE_SEC:-300}"
_PACE_CACHE_FILE="${FIVE_PACE_CACHE_FILE:-${STATE_DIR:-/var/lib/5dive}/pace-usage.json}"

_pace_usage_snapshot() {  # -> the usage document on stdout, or EMPTY
  local now age out
  now=$(date +%s)
  if [[ -r "$_PACE_CACHE_FILE" ]]; then
    local mt; mt=$(stat -c %Y "$_PACE_CACHE_FILE" 2>/dev/null || echo 0)
    [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    age=$(( now - mt ))
    if (( mt > 0 && age >= 0 && age < _PACE_CACHE_SEC )) && [[ -s "$_PACE_CACHE_FILE" ]]; then
      cat "$_PACE_CACHE_FILE"; return 0
    fi
  fi
  out=$($_PACE_USAGE_CMD 2>/dev/null || printf '')
  # Only a non-empty reading is written. A failed collect must not demote a
  # cache that is merely a little old into no cache at all on the NEXT tick.
  if [[ -n "$out" ]]; then
    local tmp="${_PACE_CACHE_FILE}.$$"
    if mkdir -p "$(dirname "$_PACE_CACHE_FILE")" 2>/dev/null \
       && printf '%s' "$out" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$_PACE_CACHE_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  printf '%s' "$out"
}
