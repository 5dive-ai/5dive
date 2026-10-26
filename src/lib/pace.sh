# shellcheck shell=bash
# ── DIVE-6938: the account meter and the dispatch pace, kept in the core ──────
#
# These lines used to open and close src/task/grader_pool.sh. That file moved to
# the devteam plugin (DIVE-6935/6938), but the heartbeat paces EVERY dispatch on
# every box with `_pace_*`, and the pace reads the same per-account meter the
# grader spawn floor reads. So the meter (`_grader_pct` .. `_grader_account_reading`,
# `_grader_account_of`) and the pace stay here, and the plugin's grader_pool.sh
# keeps only the grader half, which calls into this file.
#
# ── DIVE-4164: ephemeral graders — the spawn floor ──────────────────────────
#
# One grade, one session, then gone. `_task_route_to_verifier` (delivery.sh) is
# the single funnel every delivery passes through, so the spawn REQUEST is
# emitted there; this file owns the question that gates it: may we spend a
# grader session right now, and on which account?
#
# WHY THE FLOOR IS NOT READ FROM THE SUPERVISOR, though the design row said it
# was. `_sup_quota_match`/`_sup_quota_deadline` scrape TMUX PANE TEXT for refusal
# phrasings and a resume deadline. That is a boolean — "this seat is walled right
# NOW" — carrying no number and no headroom, so it cannot express a floor at all.
# The numeric window lives in cmd_usage.sh: per-ACCOUNT fiveHourPct/sevenDayPct,
# sourced from Claude's statusline rate-limit cache and Codex's
# rate_limits.primary/secondary.used_percent. Two independent inputs, and this
# file reads the numeric one; the pane signal stays a separate per-seat veto.
#
# PER ACCOUNT, NEVER PER SEAT, and that is not a style choice. Measured
# 2026-09-09: mark's nine seats every one of them read the SAME pair (50%/70%),
# because they share one auth window. A per-seat cap would read nine independent
# budgets that do not exist and spawn nine graders into one window.
_GRADER_FLOOR_5H="${_GRADER_FLOOR_5H:-80}"
_GRADER_FLOOR_7D="${_GRADER_FLOOR_7D:-90}"
_GRADER_MAX_PER_ACCOUNT="${_GRADER_MAX_PER_ACCOUNT:-2}"
# Overridable so the unit harness can feed a fixture instead of needing root and
# a live meter. Same posture as _SUP_QUOTA_PAT.
_GRADER_USAGE_CMD="${_GRADER_USAGE_CMD:-5dive usage --json}"

# `_grader_pct <account> <field>` — the account's percentage for one field, or
# EMPTY when the meter has no number for it.
#
# Empty is a real, common state, not an edge case: measured 2026-09-09, SIX OF
# FOURTEEN live seats reported fiveHourPct=null (marketing, warm-mark, creative,
# olivia, dev2, don), and chemmonitor reported null for both. Whatever the cause
# — idle seat, statusline cache not yet written — the floor has nothing to
# compare against, and the caller must treat that as a refusal.
#
# Seats of one account all carry the same pair, so any one row answers for the
# account; `max` picks a defined one if some rows are null and others are not,
# which is the reading most favourable to a REFUSAL being wrong, never to a
# spawn being wrong.
_grader_pct() {  # <account> <fiveHourPct|sevenDayPct> [<json-on-stdin>]
  local acct="$1" field="$2" json
  json=$(cat)
  [[ -n "$json" ]] || { printf ''; return 0; }
  printf '%s' "$json" | jq -r --arg a "$acct" --arg f "$field" '
    [ .. | objects | select(.account? == $a) | .[$f] | numbers ] as $v
    | if ($v | length) == 0 then "" else ($v | max | tostring) end
  ' 2>/dev/null || printf ''
}

# ── DIVE-4575: THE ACCOUNT'S READING, NOT AN IDLE SEAT'S ────────────────────
#
# `_grader_pct` above reads `5dive usage --json`, and that document is built
# from TRANSCRIPT ACTIVITY: cmd_usage.sh walks each seat's session files for the
# window and `continue`s past a seat that moved no tokens in it, so an IDLE seat
# contributes no row at all — and a seat whose statusline cache was never
# written contributes a row with null percentages. Either way the ACCOUNT can
# read blind while its window is perfectly well known, because the numbers live
# in the seats' statusline caches and `account usage` reads those caches through
# the REGISTRY binding, which no amount of idleness erases.
#
# MEASURED 2026-09-15 (DIVE-4575): the pool's second template seat main2 sat
# idle from 09-14, its `~/.claude/statusline-last.json` carried no `rate_limits`
# key at all, and the lane refused it on EVERY tick for nine hours with
# `main2: refuse: mark has no 5h reading (null)` — while `main`, on the same
# account and therefore in the same auth window, held a live 5h/7d reading the
# whole time (`/var/lib/5dive/account-usage.json`, `source: main`). Seven graded
# deliveries queued behind a seat the pool could not use precisely because it
# had not been using it. The fail-closed rule is right (DIVE-4342: never launder
# an absent reading into clear); the SOURCE was wrong.
#
# So the account reading is read FIRST and the per-seat usage document is the
# FALLBACK, never the other way round. It is fenced HARDER than the document it
# overrides, because a fresher source that is allowed to be stale is not an
# improvement:
#   * the reading must carry its own measurement time (`asOf`) and be no older
#     than `_GRADER_READING_MAX_AGE` — the age of the READING, not of the file
#     that quotes it (src/lib/quota_wall.sh's fence, same seconds);
#   * a window whose `resetsAt` has already passed is DROPPED, because a
#     percentage from a window that has since turned over is not a statement
#     about the window we are about to spend in (`quota_wall_reset_guard`);
#   * when nothing fresh is found it emits NOTHING and the caller keeps failing
#     closed. There is no path here that invents a number.
# DIVE-4585 — ONE FENCE, ONE NUMBER. This used to carry its own `600` literal
# while the digest's python block and `agent list` read QUOTA_SNAPSHOT_MAX_AGE,
# also 600. Two spellings of one predicate agree only until an operator moves
# one of them, and the disagreement they would then produce is SILENT: the floor
# and the digest would grade the same account's reading differently, which is
# precisely what DIVE-4578 iteration 1 was rejected for. So the canonical knob is
# QUOTA_SNAPSHOT_MAX_AGE (src/lib/quota_wall.sh, bundled ahead of this file) and
# this name is now an ALIAS of it, retained because ~2 harnesses and the pacing
# floor's own messages spell the fence this way. Set QUOTA_SNAPSHOT_MAX_AGE and
# both predicates move; the `600` here is only the no-quota_wall.sh fallback a
# hand-picked harness source list would hit.
_GRADER_READING_MAX_AGE="${_GRADER_READING_MAX_AGE:-${QUOTA_SNAPSHOT_MAX_AGE:-600}}"

# ── DIVE-584: THE WEEKLY WINDOW DOES NOT MOVE AT THE 5-HOUR WINDOW'S SPEED ──
#
# The fence above is one number applied to both windows, and a reading only
# refreshes while a seat of that account is TALKING. Measured on this host
# 2026-09-20: 27 of 29 accounts read `null` for the week and landed in
# `blind meter, policy=soft` — `/var/log/5dive-heartbeat.log`
# `2026-09-20T06:00:05Z … DIVE-382 slot NOT fired — pacing floor soft on
# claude-dimon … no weekly reading (null)`. The floor was holding dispatch on
# the absence of a measurement, not on a measurement.
#
# 600s is the right fence for the FIVE-HOUR window: at a 5-hour horizon a
# ten-minute-old percentage is most of a percent out of date, and a window that
# resets four or five times a day can move a long way while nobody looks.
# Applied to the WEEKLY window it is a category error — a 7-day window moves
# ~0.6 %/h at a full-tilt burn, so a reading a few hours old is still a fair
# statement about the week, and there is no 24-hour span in which it becomes a
# different number by more than the floor's own granularity.
#
# So the weekly window gets its own fence. DIVE-4777 sets it at 4h, not the 24h
# this first shipped with: the drift figure above is the whole justification, and
# ~0.6 %/h over 24h is ~14 points against a `_GRADER_FLOOR_7D` of 90 — a fence
# six times looser than the reason given for it. This widening can OPEN dispatch
# as well as close it, so the fence has to be no wider than the number that
# argues for it: 4h is ~2.4 points, inside the floor's own granularity.
# This is NOT the one-directional
# lower bound of DIVE-4586 (`_pace_account_seven_bound`, further down) and does
# not replace it: that admits an EXPIRED-fence reading in the raise-only
# direction. This widens the fence itself for one window, so an accepted weekly
# reading is an ordinary reading and may open as well as close. The reason that
# is sound here and was refused for the 5-hour window (DIVE-4578, DIVE-4342) is
# the drift rate above, and only that — keep the two numbers apart.
_GRADER_READING_WEEKLY_MAX_AGE="${_GRADER_READING_WEEKLY_MAX_AGE:-${QUOTA_SNAPSHOT_WEEKLY_MAX_AGE:-14400}}"
[[ "$_GRADER_READING_WEEKLY_MAX_AGE" =~ ^[0-9]+$ ]] || _GRADER_READING_WEEKLY_MAX_AGE=14400
# A weekly fence NARROWER than the 5-hour one would be a misconfiguration that
# silently blinds the window this knob exists to open; the wider of the two wins.
(( _GRADER_READING_WEEKLY_MAX_AGE >= _GRADER_READING_MAX_AGE )) \
  || _GRADER_READING_WEEKLY_MAX_AGE="$_GRADER_READING_MAX_AGE"

_GRADER_READING_US=$'\037'

# `_grader_reading_expired <resetsAt> <now>` — exit 0 when this window has
# already turned over. An ABSENT or UNREADABLE reset is NOT expired: the reading
# itself already passed the age fence, and we do not discard a measured window
# over a timestamp format. Epoch seconds (what the statusline cache carries) and
# vendor date strings (what a snapshot may carry) are both accepted.
_grader_reading_expired() {  # <resetsAt> <now>
  local r="${1:-}" now="${2:-0}" e
  [[ -n "$r" && "$r" != "null" ]] || return 1
  if [[ "$r" =~ ^[0-9]+$ ]]; then e="$r"; else e=$(date -d "$r" +%s 2>/dev/null) || return 1; fi
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  (( e < now ))
}

# `_grader_reading_pair <now>` — apply the age and reset fences to ONE reading in
# the `usage_read_ratelimits` shape, and print `<5h><US><7d>`. Either field may
# be empty (that window was null, or its reset had passed); NOTHING is printed
# when the reading has no usable measurement time at all, which is the caller's
# signal to fall back.
_grader_reading_pair() {  # <now>   [<reading-json-on-stdin>]
  local now="${1:-0}" json asof five seven fr sr
  json=$(cat)
  [[ -n "$json" && "$json" != "null" ]] || return 0
  asof=$(jq -r '.asOf // empty'         <<<"$json" 2>/dev/null || printf '')
  [[ "$asof" =~ ^[0-9]+$ ]] || return 0
  # DIVE-584: the age fence is PER WINDOW now. A reading outside the weekly
  # fence is nothing at all (the caller's fall-back signal, as before); one
  # between the two fences is a weekly measurement whose 5-hour half has gone
  # stale, and only the 5-hour half is dropped. A reading from the FUTURE is
  # still nothing, on either window — that is a clock fault, not an age.
  (( now >= asof )) || return 0
  (( now - asof <= _GRADER_READING_WEEKLY_MAX_AGE )) || return 0
  five=$(jq -r  '.fiveHourPct // empty'   <<<"$json" 2>/dev/null || printf '')
  seven=$(jq -r '.sevenDayPct // empty'   <<<"$json" 2>/dev/null || printf '')
  (( now - asof <= _GRADER_READING_MAX_AGE )) || five=""
  fr=$(jq -r    '.fiveResetsAt // empty'  <<<"$json" 2>/dev/null || printf '')
  sr=$(jq -r    '.sevenResetsAt // empty' <<<"$json" 2>/dev/null || printf '')
  if _grader_reading_expired "$fr" "$now"; then five=""; fi
  if _grader_reading_expired "$sr" "$now"; then seven=""; fi
  printf '%s%s%s' "$five" "$_GRADER_READING_US" "$seven"
}

# `_grader_account_reading <account>` — the account's own 5h/7d pair, or EMPTY.
#
# TWO SOURCES, in the order of how little they depend on the seat having run:
#   (a) LIVE, across the seats the REGISTRY binds to this account
#       (`account_best_ratelimits`, cmd_account.sh) — it opens each bound seat's
#       statusline cache directly and keeps the freshest, so an idle seat is
#       simply outvoted by a busy sibling instead of blinding the account. Root
#       only (sibling homes are 0750); the grader cron is root, and an
#       unprivileged caller gets nothing and falls through rather than erroring.
#   (b) the published account-usage snapshot (`quota_snapshot_read`), normalised
#       into the same shape — the unprivileged reader's copy of the same numbers.
#
# Both are `declare -F`-guarded so this file stays sourceable on its own: the
# unit harnesses source it alone, and there the account reading is simply absent
# and every existing arm keeps grading the per-seat fallback it was written for.
# `_grader_account_reading_json <account>` — the account's reading in the
# `usage_read_ratelimits` shape ({asOf, fiveHourPct, fiveResetsAt, sevenDayPct,
# sevenResetsAt}), UNFENCED, or EMPTY. Split out for DIVE-4578: the pacing floor
# needs the weekly pct AND its reset time out of the same reading, which the
# fenced `<5h><US><7d>` pair cannot carry. The fences live one level up, in
# `_grader_reading_pair` (the pool) and `_pace_account_seven` (the floor), so
# there is still exactly one place that decides what "too old" means.
_grader_account_reading_json() {  # <account> -> reading JSON or EMPTY
  local acct="${1:-}" rl="" snap="" live_at=-1 snap_at=-1
  [[ -n "$acct" ]] || return 0
  if declare -F account_best_ratelimits >/dev/null 2>&1; then
    rl=$(account_best_ratelimits "$acct" 2>/dev/null || printf '')
  fi
  # DIVE-4578 iteration 2: THE FRESHER CARRIER WINS, not simply the first
  # non-empty one. "Live first" as a plain fallback chain means a live cache
  # that merely EXISTS shadows the snapshot, and a seat that rendered its
  # statusline two hours ago still hands back a reading — which the caller's
  # asOf fence then throws away, leaving the account blind while a snapshot
  # published minutes ago sat unread behind it. Measured on this host
  # 2026-09-16: mp-team's bound seats carried caches older than the 600s fence
  # while the snapshot's row for it was 431s old, so the floor read the ACTIVITY
  # document for an account whose own reading was available. Neither carrier is
  # trusted more for being fresher — both fences still run, one level up — this
  # only stops the staler of two real readings from hiding the other. Live wins
  # a tie, which is the old order in the case where both are equally fresh.
  if declare -F quota_snapshot_read >/dev/null 2>&1; then
    snap=$(quota_snapshot_read 2>/dev/null | jq -c --arg a "$acct" '
           (((.accounts // []) | map(select(.name == $a)) | first | .usage) // null)
           | if . == null then empty
             else {asOf: .asOf,
                   fiveHourPct:   (.fiveHour.pct      // null),
                   fiveResetsAt:  (.fiveHour.resetsAt // null),
                   sevenDayPct:   (.sevenDay.pct      // null),
                   sevenResetsAt: (.sevenDay.resetsAt // null)} end' 2>/dev/null || printf '')
  fi
  [[ -n "$rl" && "$rl" != "null" ]] || rl=""
  [[ -n "$snap" && "$snap" != "null" ]] || snap=""
  if [[ -n "$rl" ]]; then live_at=$(jq -r '.asOf // -1' <<<"$rl" 2>/dev/null || printf -- -1); fi
  if [[ -n "$snap" ]]; then snap_at=$(jq -r '.asOf // -1' <<<"$snap" 2>/dev/null || printf -- -1); fi
  [[ "$live_at" =~ ^-?[0-9]+$ ]] || live_at=-1
  [[ "$snap_at" =~ ^-?[0-9]+$ ]] || snap_at=-1
  if [[ -z "$rl" ]] || { [[ -n "$snap" ]] && (( snap_at > live_at )); }; then rl="$snap"; fi
  [[ -n "$rl" && "$rl" != "null" ]] || return 0
  printf '%s' "$rl"
}

_grader_account_reading() {  # <account> -> "<5h><US><7d>" or EMPTY
  local acct="${1:-}" rl now
  [[ -n "$acct" ]] || return 0
  now=$(date +%s)
  rl=$(_grader_account_reading_json "$acct") || return 0
  [[ -n "$rl" ]] || return 0
  printf '%s' "$rl" | _grader_reading_pair "$now"
}
# Overridable so a unit harness can feed a fixture instead of needing root, a
# registry and a live meter. Same posture as `_GRADER_USAGE_CMD` — a FUNCTION
# NAME, not a command string, because it is expanded unquoted.
_GRADER_ACCOUNT_READING_CMD="${_GRADER_ACCOUNT_READING_CMD:-_grader_account_reading}"


# `_grader_account_of <agent>` — which auth account a pool seat spends from.
# Read from the SAME `5dive usage --json` document the floor reads, deliberately:
# the mapping and the meter must agree, and two sources could disagree about
# which window a seat draws on — which is the one thing the cap cannot survive.
_grader_account_of() {  # <agent>  [<usage-json-on-stdin>]
  local agent="$1" json acct=""
  json=$(cat)
  [[ -n "$agent" ]] || { printf ''; return 0; }
  # DIVE-4575: THE REGISTRY BINDING FIRST, one door further back than the floor.
  # The usage document only carries a seat that moved tokens in the window, so a
  # seat idle for long enough has no row in it at all and resolved to NO ACCOUNT
  # — and `_grader_window_ok` then refused it for "no account named", which is
  # not what is wrong with it. The binding is registry state and outlives any
  # amount of idleness. `declare -F`-guarded for the same reason as the reading:
  # the unit harnesses source this file alone.
  if declare -F quota_seat_account >/dev/null 2>&1; then
    acct=$(quota_seat_account "$agent" 2>/dev/null || printf '')
  fi
  if [[ -z "$acct" ]]; then
    acct=$(printf '%s' "$json" | jq -r --arg n "$agent" '
      [ .. | objects | select(.name? == $n) | .account? | strings ] | (.[0] // "")
    ' 2>/dev/null || printf '')
  fi
  printf '%s' "$acct"
}


# ══ DIVE-4430 — THE DISPATCHER'S FLOOR LIVES IN THIS FILE, NOT IN ITS OWN ════
#
# What follows is the same reading as `_grader_window_ok` above, asked one level
# up: at the DISPATCH boundary rather than at the grader-spawn boundary. It was
# written as `src/task/pace.sh` and moved here in iteration 2, and the reason is
# worth keeping because it is a property of this bundle, not of this feature:
#
# A NEW LAZY MODULE IS A GLOBAL CHANGE TO WHAT EVERY VERB LOADS. Since DIVE-4087
# the bundle carries its command modules as unparsed trailing text and a stub
# pulls one in on first call, following `__MODDEPS`. Adding `src/task/pace.sh`
# to build.sh's LAZY_FILES gave `cmd_heartbeat`, `cmd_usage` and (transitively)
# `cmd_loop`/`cmd_proof` one more module to load, and CI's install-contract T4
# turned red on EXACTLY those three verbs — `5dive heartbeat|loop|proof --help`
# each exiting 2 against the installed bundle, green at the PR's base and green
# on origin/main. Measured with FIVE_LAZY_TRACE=1: those three are precisely the
# verbs whose load set grew, and nothing else in the diff is global.
#
# I could not reproduce it from a desk run (all three are rc=0 for me as a
# non-root user on the merged tree, as they were for the verifier) and this seat
# has neither docker nor a password-less root to run the contract where CI runs
# it. So the fix is BY CONSTRUCTION rather than by reproduction: fold the floor
# into the module that already owns the meter, and the load set of every verb
# becomes byte-identical to origin/main's again — the global change is not
# repaired, it is withdrawn.
#
# It also belongs here on the merits, which is what makes the move something
# other than a dodge. One file now holds every reader of the account meter: the
# same per-ACCOUNT posture (seats of one account share one auth window), the
# same `max`-across-seats rule, the same dual-channel contract (verdict on
# stdout, DECISION in the exit status — DIVE-4380). Two files reading one meter
# was the drift this codebase has paid for before.
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
#   FIVE_PACE_BLIND=open   (default since DIVE-5364) — a blind account is not
#                          held. It is still never read as 0% (the verdict says
#                          "blind", and a remembered reading over a floor still
#                          tightens it — DIVE-4586 below), but no reading is not
#                          a reason to stop the team.
#   FIVE_PACE_BLIND=soft   (the default until DIVE-5364) — a blind account is
#                          held AT THE SOFT FLOOR: high/urgent work flows,
#                          medium work and every recurring beat wait.
#   FIVE_PACE_BLIND=refuse — the filing's literal reading: no meter, no
#                          dispatch. Correct on a fleet whose meters are
#                          reliable; it freezes chemmonitor and codex on this
#                          one. Left available, not made the default.
#
# The alternative not taken is written on DIVE-4430's body, not only here.
#
# ── DIVE-5364: WHY THE DEFAULT IS NOW 95/95 AND A BLIND METER HOLDS NOTHING ──
#
# 2026-10-01, a 12-seat distribution team on a customer box: every recurring
# slot from 07:00Z to 16:30Z was "NOT fired — pacing floor soft … blind meter,
# policy=soft". The account's meter was blind BECAUSE the team was idle — the
# only current reading comes from a seat active in the last 600s, so a team
# waiting on its schedule has no reading exactly when the materializer asks —
# and its remembered reading (63%) was under every floor. The team could not
# wake itself for a day and the board showed nothing (last_skipped stayed `-`).
# lodar, 2026-10-02: "pacing shouldnt be so aggressive … default 95%".
#
# So below 95% of the week everything runs; at 95% only urgent work runs, which
# keeps the last 5% for incidents. The soft band is empty by default
# (soft == hard). A blind meter returns open, and the remembered lower bound is
# the only thing that can still tighten it. An owner who wants the old pacing
# back sets `5dive config pace-week=60/90` and FIVE_PACE_BLIND=soft.
# The built-in floors. What a band actually reads is `_PACE_FLOOR_*`, which
# `_pace_floors_load` resolves from these, the box config and the env at READ
# time (DIVE-4890, below); the initial values here are only what a caller sees
# before the first load.
_PACE_DEFAULT_7D_SOFT=95
_PACE_DEFAULT_7D_HARD=95
_PACE_FLOOR_7D_SOFT="${FIVE_PACE_7D_SOFT:-$_PACE_DEFAULT_7D_SOFT}"
_PACE_FLOOR_7D_HARD="${FIVE_PACE_7D_HARD:-$_PACE_DEFAULT_7D_HARD}"
# The soft floor is a PACING rule, so it only binds while there is still a week
# left to pace. Inside the last `_PACE_RESET_DAYS` days the unspent remainder
# expires at the reset and holding it back buys nothing — only the hard floor
# (which protects the window itself) stays armed.
_PACE_RESET_DAYS="${FIVE_PACE_RESET_DAYS:-3}"
_PACE_BLIND="${FIVE_PACE_BLIND:-open}"

# `_pace_blind_rc` — the band a blind meter gets under `_PACE_BLIND`. One place,
# because the floor has three ways to be blind (no account named, no reading,
# an unparseable reading) and they must not answer differently. An unknown
# policy word falls to the soft hold and the caller's verdict names it.
_pace_blind_rc() {
  case "$_PACE_BLIND" in
    open)   return 0 ;;
    refuse) return 1 ;;
    *)      return 2 ;;
  esac
}
# The verdict's tail for a blind meter, matching `_pace_blind_rc`.
_pace_blind_what() {
  case "$_PACE_BLIND" in
    open)   printf 'not held (FIVE_PACE_BLIND=open)' ;;
    refuse) printf 'no dispatch (FIVE_PACE_BLIND=refuse)' ;;
    soft)   printf 'held at the soft floor, high/urgent only (FIVE_PACE_BLIND=soft)' ;;
    *)      printf 'held at the soft floor — FIVE_PACE_BLIND=%s is not a policy I know (open|soft|refuse)' "$_PACE_BLIND" ;;
  esac
}

# ── DIVE-4631: THE WEEK IS NOT THE ONLY WINDOW THE WORK HAS TO FIT IN ───────
#
# Measured on this host 2026-09-19: `dev` read fiveHourPct 101 and sevenDayPct
# 12. The floor read the week alone, returned `open`, and the dispatcher handed
# the seat a row it could not finish — the seat claimed it, hit the session wall
# mid-attempt, and the row went to reclaim. The meter that would have predicted
# that was the NEXT FIELD in the document the floor was already reading.
#
# One knob, one threshold, and the band it produces is `hard` (urgent only) and
# never `refuse`. Freezing is the failure mode this family keeps re-learning
# (DIVE-4430, DIVE-4575, DIVE-4586): an incident is worth a turn that may be
# truncated; a medium row is not.
_PACE_DEFAULT_5H=85
_PACE_FLOOR_5H="${FIVE_PACE_5H:-$_PACE_DEFAULT_5H}"

# ── DIVE-4890: THE FLOORS ARE A BOX SETTING, NOT ONLY A CRON ENV VAR ─────────
#
# Until this row the floors were env-only. An owner changed how much of an
# account's week the heartbeat spends by hand-editing an env var on a root cron
# line — impossible on a customer box — and the digest, which runs from a
# different line, never saw it: on this host (2026-09-23) the tick paced at
# 85/95 while the digest still rendered holds at 60/90.
#
# So the floors are `5dive config pace-week=<soft>/<hard>|off|default` and
# `5dive config pace-5h=<pct>|off|default`, stored as `.pace_week` / `.pace_5h`
# in the box file every seat reads (src/cmd_box_config.sh), and resolved HERE,
# once, for every reader — the tick and the digest both call this, so the two
# cannot answer from different numbers again.
#
# PRECEDENCE: env, then config, then the built-in default. An explicit env var
# still wins so every existing cron line keeps meaning what it meant. For the
# week the pair is one setting: either FIVE_PACE_7D_* var set makes the week
# env-sourced (the unset half takes its default, as before this row), because
# mixing an env soft floor with a config hard floor is a band nobody chose.
#
# `off` means NO FLOOR in that window: the weekly band returns open for every
# reading, blind and unmeterable included, and the 5h band contributes nothing.
#
# RESOLVED AT READ TIME, not load time, for the reason src/lib/verify_policy.sh
# gives: harnesses reassign STATE_DIR after sourcing, and a load-time read would
# pace them from the LIVE box's file.
_pace_box_config_path() {
  if declare -F _box_config_path >/dev/null 2>&1; then _box_config_path; return 0; fi
  printf '%s' "${BOX_CONFIG:-${STATE_DIR:-/var/lib/5dive}/box.json}"
}

# One percentage: an integer 0..100 with no leading zero. The leading-zero ban is
# not pedantry — bash reads `085` as octal and aborts on it under errexit.
_pace_pct_valid() { [[ "${1:-}" =~ ^(0|[1-9][0-9]?|100)$ ]]; }

# `pace-week` values: `<soft>/<hard>` with soft <= hard <= 100, `off`, `default`.
_pace_week_valid() {  # <value>
  local v="${1:-}" s h
  [[ "$v" == off || "$v" == default ]] && return 0
  [[ "$v" == */* ]] || return 1
  s="${v%%/*}"; h="${v#*/}"
  _pace_pct_valid "$s" && _pace_pct_valid "$h" || return 1
  (( s <= h ))
}

# `pace-5h` values: `<pct>`, `off`, `default`.
_pace_5h_valid() {  # <value>
  local v="${1:-}"
  [[ "$v" == off || "$v" == default ]] && return 0
  _pace_pct_valid "$v"
}

# Sets _PACE_FLOOR_7D_SOFT/_HARD, _PACE_FLOOR_5H, _PACE_WEEK_OFF/_PACE_5H_OFF
# (1 = no floor in that window) and _PACE_WEEK_SRC/_PACE_5H_SRC (env, config,
# default, or default with the reason a stored value was ignored).
_pace_floors_load() {
  local f cw="" c5="" s h
  local -a kv=()
  f=$(_pace_box_config_path)
  if [[ -r "$f" ]]; then
    mapfile -t kv < <(jq -r '(.pace_week // "" | tostring), (.pace_5h // "" | tostring)' "$f" 2>/dev/null || true)
    cw="${kv[0]:-}"; c5="${kv[1]:-}"
  fi
  _PACE_WEEK_OFF=0; _PACE_5H_OFF=0
  if [[ -n "${FIVE_PACE_7D_SOFT:-}" || -n "${FIVE_PACE_7D_HARD:-}" ]]; then
    _PACE_FLOOR_7D_SOFT="${FIVE_PACE_7D_SOFT:-$_PACE_DEFAULT_7D_SOFT}"
    _PACE_FLOOR_7D_HARD="${FIVE_PACE_7D_HARD:-$_PACE_DEFAULT_7D_HARD}"
    _PACE_WEEK_SRC="env FIVE_PACE_7D_SOFT/FIVE_PACE_7D_HARD"
  elif [[ "$cw" == off ]]; then
    _PACE_WEEK_OFF=1; _PACE_WEEK_SRC="config"
  elif [[ -n "$cw" && "$cw" != default ]] && _pace_week_valid "$cw"; then
    s="${cw%%/*}"; h="${cw#*/}"
    _PACE_FLOOR_7D_SOFT="$s"; _PACE_FLOOR_7D_HARD="$h"; _PACE_WEEK_SRC="config"
  else
    _PACE_FLOOR_7D_SOFT="$_PACE_DEFAULT_7D_SOFT"; _PACE_FLOOR_7D_HARD="$_PACE_DEFAULT_7D_HARD"
    _PACE_WEEK_SRC="default"
    [[ -n "$cw" && "$cw" != default ]] && _PACE_WEEK_SRC="default — the stored pace_week '${cw}' is not a valid value and is ignored"
  fi
  if [[ -n "${FIVE_PACE_5H:-}" ]]; then
    _PACE_FLOOR_5H="$FIVE_PACE_5H"; _PACE_5H_SRC="env FIVE_PACE_5H"
  elif [[ "$c5" == off ]]; then
    _PACE_5H_OFF=1; _PACE_5H_SRC="config"
  elif [[ -n "$c5" && "$c5" != default ]] && _pace_pct_valid "$c5"; then
    _PACE_FLOOR_5H="$c5"; _PACE_5H_SRC="config"
  else
    _PACE_FLOOR_5H="$_PACE_DEFAULT_5H"; _PACE_5H_SRC="default"
    [[ -n "$c5" && "$c5" != default ]] && _PACE_5H_SRC="default — the stored pace_5h '${c5}' is not a valid value and is ignored"
  fi
  return 0
}

# The effective weekly setting as ONE string: `off` or `<soft>/<hard>`. This is
# what `5dive config` prints and what cmd_digest hands its python block, so the
# surface renders the band the tick applies.
_pace_week_effective() {
  _pace_floors_load
  if (( _PACE_WEEK_OFF )); then printf 'off'; else printf '%s/%s' "$_PACE_FLOOR_7D_SOFT" "$_PACE_FLOOR_7D_HARD"; fi
}
_pace_5h_effective() {
  _pace_floors_load
  if (( _PACE_5H_OFF )); then printf 'off'; else printf '%s' "$_PACE_FLOOR_5H"; fi
}
# Overridable so the unit harness feeds a fixture instead of needing root and a
# live meter. Same posture as _GRADER_USAGE_CMD / _SUP_QUOTA_PAT.
_PACE_USAGE_CMD="${_PACE_USAGE_CMD:-sudo -n 5dive usage --json}"

# ── DIVE-4578: THE ACCOUNT'S READING FIRST, HERE TOO ────────────────────────
#
# `5dive usage --json` is built by walking what each seat DID in the window, so
# its silence about a seat means "this seat was quiet", not "this account is
# unmeasured". The grader pool read that silence as unmeasured and refused a
# seat for nine hours (DIVE-4575). This floor reads the same document and makes
# the INVERTED mistake: `FIVE_PACE_BLIND=soft` holds a blind account at the soft
# floor, so a QUIET account is paced down to high/urgent-only while its account
# reading — reached through the registry binding, which idleness cannot erase —
# says it is at 30% of its week. Same document, same ambiguity, opposite
# direction, because each consumer's fail-safe points its own way.
#
# So the population of the defect is the document's READERS, and the fix is the
# same re-ordering DIVE-4575 proved on the pool: account reading first, the
# per-seat activity document as the fallback, and the account reading fenced
# HARDER than the source it overrides (a fresher source that is allowed to be
# stale is not an improvement). The blind branch is untouched — with NEITHER
# source we still hold at the soft floor and never read the emptiness as 0%
# (DIVE-4342).

# ── DIVE-4731: ONE ACCOUNT READING PER TICK, NOT ONE PER TEMPLATE ───────────
#
# THE MEASUREMENT. /var/log/5dive-heartbeat.log, two ticks, both on `mark`:
#
#   2026-09-20T03:00:04Z  DIVE-1236 NOT fired — hard … 100% … from the SEAT reading
#   2026-09-20T03:00:06Z  DIVE-1483 fired -> new standard todo
#   2026-09-18T04:00:06Z  DIVE-1237 NOT fired — hard … 100% … from the SEAT reading
#   2026-09-18T04:00:07Z  DIVE-1430 fired -> new standard todo
#
# Same tick, same account, two seconds apart, opposite verdicts. The per-seat
# usage document is collected ONCE PER TICK (`_HB_PACE_USAGE`) and is a `max`
# across the account's seats, so it cannot have differed between the two
# iterations. The account reading is what differed: it was unreadable on the
# first template and readable on the second, because `_pace_band_7d` re-reads it
# ONCE PER TEMPLATE. The materializer's SELECT is unordered, so the lowest row
# id due in a minute eats the blind read — DIVE-1236 (id 1288) lost a recovery
# that DIVE-1483 (id 1618) caught two seconds later, and creative's OpenAgent
# beat stayed dead a day longer than dev's for that reason alone (DIVE-4728).
#
# ═══ WHAT A FLICKER MEANS FOR A BEAT — THE DECISION THIS ROW OWED ══════════
#
# A momentary failure to read the account's reading is NOT a measurement of the
# account, and it must not silently hand the verdict to the per-seat activity
# document. That document is a `max` over seats and carries no per-seat
# measurement time, so a seat that hit 100% two hours ago and went quiet answers
# for the account forever — on 09-20 03:00 it said 100% while the account's own
# reading had headroom. The fallback chain is right in its ORDER and wrong in
# its TRIGGER: it should fire when the account has had no readable reading for
# the whole fence window, not when one read happened to land in a gap.
#
# So the last GOOD account reading is carried across the gap, and only a gap
# wider than the fence itself reaches the seat document. Three properties make
# that safe, and each one is an arm in tests/pace_the_week_unit.sh:
#
#   * IT CANNOT INVENT FRESHNESS. The cache stores the reading UNFENCED and
#     re-prints it verbatim; `_pace_account_seven`'s asOf fence and
#     `_grader_reading_expired`'s reset fence still run on every call, against
#     the reading's OWN timestamps and the CURRENT clock. A reading that has
#     aged out is dropped whether it came from the carrier or from here.
#   * IT CANNOT INVENT A NUMBER. Only a NON-EMPTY reading is ever written, and
#     an empty read with no cache behind it stays empty — the blind branch, the
#     soft floor, and never 0%. This is `_pace_usage_snapshot`'s rule and it is
#     the same rule for the same reason (DIVE-4342).
#   * IT CANNOT OUTLIVE THE FENCE. The stale-serve is bounded by
#     `_GRADER_READING_MAX_AGE`, the same window `_pace_account_seven` grades
#     against, so the cache never holds a reading past the point where the
#     caller would have thrown it away anyway.
#
# WHY A FILE AND NOT A SHELL VARIABLE. The materializer grades each template
# inside a command substitution (`_mz_verdict=$(… | _pace_band …)`), which is a
# SUBSHELL — an in-memory memo written there dies with it and the next template
# reads a cold cache. The TTL is therefore what makes the reading per-tick: one
# real carrier read per account per `_PACE_READING_CACHE_SEC`, every template
# after the first in that window served from it.
_PACE_READING_CACHE_SEC="${FIVE_PACE_READING_CACHE_SEC:-60}"
_PACE_READING_CACHE_DIR="${FIVE_PACE_READING_CACHE_DIR:-${STATE_DIR:-/var/lib/5dive}/pace-reading}"

# `_pace_reading_cache_path <account>` — one file per account, named from a
# SANITISED account (an account name reaches this from the registry and may
# carry `@self:` or a slash; neither may become a path component).
_pace_reading_cache_path() {  # <account>
  local acct="${1:-}"
  printf '%s/%s.json' "$_PACE_READING_CACHE_DIR" "${acct//[^A-Za-z0-9_.-]/_}"
}

# `_pace_account_reading_cached <account>` — the account's reading JSON, from
# the carrier at most once per TTL, or from the last good read across a flicker.
# EMPTY when neither has one. Unfenced, exactly like the function it wraps.
_pace_account_reading_cached() {  # <account> -> reading JSON or EMPTY
  local acct="${1:-}" f now mt age out tmp
  [[ -n "$acct" ]] || return 0
  declare -F _grader_account_reading_json >/dev/null 2>&1 || return 0
  # NO CARRIER IN THIS PROCESS, NOTHING TO CARRY. `_grader_account_reading_json`
  # is always defined beside this function, but the two things it actually reads
  # are not: a hand-picked harness source list, or a caller that sources this
  # file alone, has neither. Such a process could never have WRITTEN this cache,
  # so it must not READ one either — otherwise a reading left by an unrelated
  # process becomes an answer here, which is the cross-source confusion this
  # whole family (DIVE-4575/4578) exists to refuse.
  declare -F account_best_ratelimits >/dev/null 2>&1 \
    || declare -F quota_snapshot_read >/dev/null 2>&1 \
    || return 0
  f=$(_pace_reading_cache_path "$acct")
  now=$(date +%s)
  mt=0
  if [[ -r "$f" && -s "$f" ]]; then
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    age=$(( now - mt ))
    if (( mt > 0 && age >= 0 && age < _PACE_READING_CACHE_SEC )); then
      cat "$f"; return 0
    fi
  fi
  out=$(_grader_account_reading_json "$acct" 2>/dev/null || printf '')
  if [[ -n "$out" ]]; then
    tmp="${f}.$$"
    if mkdir -p "$_PACE_READING_CACHE_DIR" 2>/dev/null \
       && printf '%s' "$out" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
    printf '%s' "$out"; return 0
  fi
  # THE FLICKER BRANCH. The carrier said nothing THIS call; the last thing it
  # said is still the account's most recent reading, and the caller's own fences
  # will grade it. Bounded by the fence window so this can never hand back
  # something the caller would have rejected as a carrier read.
  if (( mt > 0 )) && [[ -r "$f" && -s "$f" ]]; then
    age=$(( now - mt ))
    # DIVE-584: bounded by the WIDEST fence any caller applies, not the 5-hour
    # one. This branch is a carrier, not a verdict — every consumer re-fences
    # the reading's own `asOf` per window on the way out — so narrowing it here
    # threw the weekly reading away before the weekly fence ever saw it, which
    # is the second of the three places one number was doing two jobs.
    if (( age >= 0 && age < _GRADER_READING_WEEKLY_MAX_AGE )); then
      cat "$f"; return 0
    fi
  fi
  return 0
}
# Overridable by the same contract as `_PACE_ACCOUNT_CMD` — a FUNCTION NAME, not
# a command string — so a unit harness can drive the fences without a carrier.
_PACE_READING_JSON_CMD="${_PACE_READING_JSON_CMD:-_pace_account_reading_cached}"

# `_pace_account_seven <account> [<now>]` — the account's own WEEKLY reading as
# `<pct><US><resetsAt-epoch>`, or EMPTY.
#
# Both fences of `_grader_reading_pair`, applied to the weekly window only:
#   * the READING's own measurement time (`asOf`) within
#     `_GRADER_READING_WEEKLY_MAX_AGE` (DIVE-584: the weekly fence, not the
#     5-hour one) — not the age of the file that quotes it;
#   * a window whose `sevenResetsAt` has already passed is DROPPED entirely,
#     because a percentage from a window that has since turned over is not a
#     statement about the week we are pacing.
# Either fence, or an absent number, yields EMPTY — which sends the caller to
# the per-seat document, and if that is blind too, to the blind branch. There is
# no path here that invents a number.
#
# The reset is normalised to EPOCH before it is printed, because the caller does
# days-to-reset arithmetic on it and the two sources spell it differently (the
# statusline cache carries epoch seconds, a snapshot may carry a vendor date
# string). An unparseable reset prints EMPTY and leaves the floor armed, which
# is the direction the unmeasured case must always point.
_pace_account_seven() {  # <account> [<now-epoch>] -> "<pct><US><resets>" or EMPTY
  local acct="${1:-}" now="${2:-}" rl asof seven sr
  [[ -n "$acct" ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  rl=$($_PACE_READING_JSON_CMD "$acct" 2>/dev/null || printf '')
  [[ -n "$rl" && "$rl" != "null" ]] || return 0
  asof=$(jq -r '.asOf // empty' <<<"$rl" 2>/dev/null || printf '')
  [[ "$asof" =~ ^[0-9]+$ ]] || return 0
  # DIVE-584: this function reads the WEEKLY window and nothing else, so it
  # fences on the weekly age. The reset fence below is unchanged and still does
  # the work the age fence cannot — a percentage from a window that has already
  # turned over is dropped however fresh it is.
  (( now >= asof && now - asof <= _GRADER_READING_WEEKLY_MAX_AGE )) || return 0
  seven=$(jq -r '.sevenDayPct // empty'   <<<"$rl" 2>/dev/null || printf '')
  sr=$(jq -r    '.sevenResetsAt // empty' <<<"$rl" 2>/dev/null || printf '')
  [[ -n "$seven" ]] || return 0
  _grader_reading_expired "$sr" "$now" && return 0
  if [[ -n "$sr" && ! "$sr" =~ ^[0-9]+$ ]]; then sr=$(date -d "$sr" +%s 2>/dev/null) || sr=""; fi
  [[ "$sr" =~ ^[0-9]+$ ]] || sr=""
  printf '%s%s%s' "$seven" "$_GRADER_READING_US" "$sr"
}
# Overridable so a unit harness can feed a fixture instead of needing root, a
# registry and a live meter. A FUNCTION NAME, not a command string, because it
# is expanded unquoted — same posture as `_GRADER_ACCOUNT_READING_CMD`.
_PACE_ACCOUNT_CMD="${_PACE_ACCOUNT_CMD:-_pace_account_seven}"

# ── DIVE-4586: A STALE WEEKLY READING IS STILL A LOWER BOUND ────────────────
#
# 19 of 22 accounts published `usage: null` after DIVE-4585 gave the snapshot a
# scheduled publisher, and the reflex reading of that is "there is no number for
# these accounts". Measured on this host 2026-09-18, that is not what it says.
# Only FOUR accounts have a bound seat at all, and of those the one the floor
# gets wrong is `mark`: eight seats, a real weekly reading of 100%, and the
# freshest statusline cache across all eight is TWO HOURS old — so
# `_pace_account_seven`'s asOf fence drops it and the floor reads `mark` as
# blind and holds it at the SOFT floor, while the account is in fact over the
# HARD one.
#
# The cause is a loop, and it is the same one `src/lib/quota_wall.sh` records
# for the snapshot: the seats stopped rendering statuslines BECAUSE the account
# hit its wall, so the wall is exactly the condition under which the evidence of
# the wall goes stale. Freshness fences are correct and this does not touch
# them — widening one would be DIVE-4578's and DIVE-4342's refusal, and it would
# let a stale number through in the direction that BUYS spend.
#
# What is true instead: a weekly `used_percentage` is monotonically
# non-decreasing inside its own window. It only falls when the window turns
# over, and the window's turn-over time is carried in the reading itself. So
# while `sevenResetsAt` is still in the FUTURE, an aged reading of 100% is not a
# current measurement — but it IS a sound lower bound on the current one, and
# the floor is a lower-bound test: "is this account at or above N%".
#
# Therefore this reading is admitted in ONE direction only. It can raise the
# floor (soft, hard); it can never open it, never satisfy the
# distance-to-reset relaxation (which is the one branch that BUYS dispatch),
# and never turn absence into a number — under the soft floor a lower bound
# says nothing, so the caller falls through to the blind branch exactly as
# before. The failure this whole family refuses is a green word nobody
# measured; a bound that can only ever say "at least this red" cannot produce
# one.
#
# NOT fixed here, because it is a different defect with a different fix: the
# `codex` account's three seats can never produce this reading at all — their
# CLI is not Claude Code and has no Anthropic 5h/7d window — so they sit at the
# blind soft floor permanently, waiting on a number that does not exist for
# their provider. That is provider awareness, not a carrier. See the row body.
#
# `_pace_account_seven_bound <account> [<now>]` -> "<pct><US><resets>" or EMPTY.
# Same source and the same reset fence as `_pace_account_seven`; the asOf fence
# is replaced by the requirement that the reading HAVE a measurement time (an
# undated reading is still nothing) and that its window not have turned over.
_pace_account_seven_bound() {  # <account> [<now-epoch>] -> "<pct><US><resets>" or EMPTY
  local acct="${1:-}" now="${2:-}" rl asof seven sr
  [[ -n "$acct" ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  rl=$($_PACE_READING_JSON_CMD "$acct" 2>/dev/null || printf '')
  [[ -n "$rl" && "$rl" != "null" ]] || return 0
  asof=$(jq -r '.asOf // empty' <<<"$rl" 2>/dev/null || printf '')
  # An undated reading is not a bound either: with no measurement time we cannot
  # say the reading was taken inside the window it names.
  [[ "$asof" =~ ^[0-9]+$ ]] || return 0
  (( asof <= now )) || return 0
  seven=$(jq -r '.sevenDayPct // empty'   <<<"$rl" 2>/dev/null || printf '')
  sr=$(jq -r    '.sevenResetsAt // empty' <<<"$rl" 2>/dev/null || printf '')
  [[ -n "$seven" ]] || return 0
  # The whole argument rests on the window not having turned over. No readable
  # reset means we cannot show that, so there is no bound — not a bound we
  # assume. This is stricter than `_pace_account_seven`, which may print an
  # empty reset because a FRESH pct stands on its own.
  if [[ -n "$sr" && ! "$sr" =~ ^[0-9]+$ ]]; then sr=$(date -d "$sr" +%s 2>/dev/null) || sr=""; fi
  [[ "$sr" =~ ^[0-9]+$ ]] || return 0
  (( sr > now )) || return 0
  # `asof <= now < sr` already places the measurement inside the window it
  # reports on, so there is no separate asof-vs-reset test to write: the future-
  # asOf guard above is what makes that chain hold.
  printf '%s%s%s' "$seven" "$_GRADER_READING_US" "$sr"
}
# Overridable by the same contract as _PACE_ACCOUNT_CMD, for the same reason.
_PACE_ACCOUNT_BOUND_CMD="${_PACE_ACCOUNT_BOUND_CMD:-_pace_account_seven_bound}"

# ── DIVE-4629: "NOT MEASURED YET" AND "CANNOT BE MEASURED HERE" ARE TWO STATES
#
# Everything above this point is about a number that exists and could not be
# read: a carrier that went quiet, a reading that aged out, a window that
# turned over. DIVE-4586 closed the last of those and signed the one it could
# not: the `codex` account's three seats run a CLI that is not Claude Code and
# whose provider publishes no Anthropic 5h/7d window AT ALL. `usage_read_ratelimits`
# (cmd_account.sh) says so in its own contract — it emits nothing for "a
# non-claude type whose CLI doesn't surface Anthropic 5h/7d limits". No carrier,
# no cadence and no lower bound can produce a number that does not exist, so
# under `FIVE_PACE_BLIND=soft` those seats are held to high|urgent-only on every
# tick, forever. Measured 2026-09-17 (DIVE-4586): 3 of 16 seats, 19% of the
# fleet, paced down permanently by a meter that was never about them.
#
# That is not caution. A fail-safe default is only safe over the population the
# meter can in principle measure; outside it the default is a standing penalty
# nobody ever decided, with no appeal and no event that can ever lift it.
#
# ═══ WHY THE ANSWER IS NOT "TREAT THE MISSING READING AS HEALTHY" ═══════════
#
# It would be the 2026-09-09 bug again (absence read as 0% used), and the row
# refuses it explicitly. The claim made here is a different one, and it is a
# claim about JURISDICTION rather than about consumption:
#
#   This floor rations ONE quantity — the percentage of an Anthropic weekly
#   subscription window an account has consumed. For an account whose provider
#   has no such window, every band above `open` is a statement about a quantity
#   that does not exist, and `open` is not "we measured 0%" — it is "this meter
#   has nothing to say here".
#
# What is NOT claimed: that those seats cost nothing. They spend on their own
# provider's plan, and that spend is unmetered by us — DIVE-3968 (codex native
# quota telemetry) is the row that would give it a meter. Until it does, the
# honest state is "unrationed and visibly so", which the verdict line below says
# in words, rather than "rationed by a meter that cannot see it".
#
# ═══ THE CLASSIFICATION IS POSITIVE, NEVER INFERRED FROM ABSENCE ════════════
#
# The dangerous mistake would be to read "no reading arrived" as "this provider
# cannot publish one" — that is a fail-open on exactly the carrier outage this
# family exists to survive. So the capability is decided from the REGISTRY, not
# from the meter: the account is unmeterable only when the registry is readable,
# it binds at least one seat to the account, EVERY bound seat's type is known,
# and NONE of those types can report the window. Anything else — an unreadable
# registry, no bound seat, a seat whose type is missing, a single claude seat —
# is `unknown`, which changes nothing and leaves today's blind branch to answer.
#
# The capable list is an ALLOW-list for the same reason. A BYO-claude seat is
# type `claude` pointed at a non-Anthropic endpoint, so it is classified capable
# and keeps today's behaviour even though its endpoint may publish nothing; a
# false "capable" costs a hold that already happens, where a false "unmeterable"
# would buy dispatch. The two errors are not symmetric, and the list leans the
# way the cheap one falls.
_PACE_WINDOW_TYPES="${FIVE_PACE_WINDOW_TYPES:-claude}"
#   open   (default) — the floor has no jurisdiction over this account; dispatch
#                      as normal and SAY SO in the verdict, so the absence of a
#                      meter is visible rather than silent.
#   soft|hard|refuse — the pre-DIVE-4629 behaviour (`soft`) and the two tighter
#                      readings, for an operator who wants unmetered spend
#                      rationed by default. Unrecognised values fall back to
#                      `soft`, which is the behaviour this row changed.
_PACE_UNMETERED="${FIVE_PACE_UNMETERED:-open}"

# `_pace_seat_types <account>` — the runtime type of every seat the REGISTRY
# binds to this account, one per line, `?` for a seat whose type is unreadable.
# EMPTY when there is no readable registry or no seat is bound — which the
# caller must read as "unknown", never as "none".
#
# The `@self:<name>` synthesis is the one the floor's own callers use
# (cmd_heartbeat.sh 4493/7419: `.agents[$n].authProfile // ("@self:" + $n)`), so
# the domain this walks is exactly the domain the floor is asked about.
_pace_seat_types() {  # <account> -> one type per line, or EMPTY
  local acct="${1:-}"
  [[ -n "$acct" ]] || return 0
  [[ -n "${REGISTRY:-}" && -r "${REGISTRY:-}" ]] || return 0
  jq -r --arg a "$acct" '
    (.agents // {}) | to_entries[]
    | select(((.value.authProfile // ("@self:" + .key)) == $a))
    | (if (.value.type | type) == "string" and (.value.type | length) > 0
       then .value.type else "?" end)
  ' "$REGISTRY" 2>/dev/null || printf ''
}
# Overridable by the same contract as _PACE_ACCOUNT_CMD — a FUNCTION NAME, not a
# command string — so the unit harness can feed a seat population without a
# registry and without root.
_PACE_SEAT_TYPES_CMD="${_PACE_SEAT_TYPES_CMD:-_pace_seat_types}"

# `_pace_window_capable <account>` — can this account's provider EVER publish
# the weekly window the floor waits for?
#
#   0  yes      — at least one bound seat runs a type that reports it
#   1  no       — the registry answered, seats are bound, every type is known,
#                 and not one of them can report it
#   2  unknown  — no account, no readable registry, no bound seat, or a seat
#                 whose type we could not read
#
# Only exit 1 is evidence. 0 and 2 both leave every existing branch untouched.
_pace_window_capable() {  # <account>
  local acct="${1:-}" t seen=0 unknown=0
  [[ -n "$acct" ]] || return 2
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    if [[ "$t" == "?" ]]; then unknown=1; continue; fi
    seen=1
    case " $_PACE_WINDOW_TYPES " in *" $t "*) return 0 ;; esac
  done < <($_PACE_SEAT_TYPES_CMD "$acct" 2>/dev/null || printf '')
  (( unknown )) && return 2
  (( seen )) || return 2
  return 1
}
# Overridable so a caller that already knows the answer can supply it; the
# digest uses the function itself (src/cmd_digest.sh) so the surface and the
# floor cannot drift into disagreeing about which accounts are unmeterable.
_PACE_WINDOW_CAPABLE_CMD="${_PACE_WINDOW_CAPABLE_CMD:-_pace_window_capable}"

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

# `_pace_band_7d <account> [<now-epoch>]` — how hard is the WEEKLY floor on
# this account? This is the original `_pace_band` body, unchanged; `_pace_band`
# is now the combiner below, which takes the tighter of this and the session
# window (DIVE-4631). Call it with a HERE-STRING, never a pipe: it returns
# before its `json=$(cat)` when no account is named, and a pipe would then hand
# the caller the writer's EPIPE status instead of this function's band.
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
#
# Blind (no account, no reading, unparseable) answers `_pace_blind_rc`: open by
# default since DIVE-5364, soft or refuse when the box opts in.
_pace_band_7d() {  # <account> [<now-epoch>]  [<usage-json-on-stdin>]
  local acct="$1" now="${2:-$(date +%s)}" json seven="" resets="" days_left src="" pair=""
  local lb_pair="" lb_seven="" lb_resets=""
  local pw=0 unmet_band unmet_why
  [[ "${_PACE_FLOORS_FRESH:-}" == 1 ]] || _pace_floors_load
  # DIVE-4890: `pace-week=off` is no weekly floor at all — ahead of every branch
  # below, blind and unmeterable included, because each of those is a way the
  # weekly floor holds and the owner turned the weekly floor off. Stdin is
  # drained so a piping caller is never handed an EPIPE in place of a band.
  if (( _PACE_WEEK_OFF )); then
    cat >/dev/null
    printf 'pace: the weekly floor is off on this box (pace-week=off, from %s) — %s is not held for its week\n' \
           "$_PACE_WEEK_SRC" "${acct:-<no account>}"
    return 0
  fi
  if [[ -z "$acct" ]]; then
    # No account named is not a measurement, and it must not read as headroom:
    # it is a blind meter and gets the blind policy, never a 0% reading.
    printf 'pace: no account named — blind, never read as 0%%; %s\n' "$(_pace_blind_what)"
    local _brc=0; _pace_blind_rc || _brc=$?; return "$_brc"
  fi
  json=$(cat)
  # DIVE-4578: the ACCOUNT's reading first, the per-seat document second. The
  # pct and its reset are taken from ONE source and never mixed: a reset from
  # the activity document does not describe the window the account reading
  # measured.
  pair=$($_PACE_ACCOUNT_CMD "$acct" "$now" 2>/dev/null || printf '')
  if [[ -n "$pair" ]]; then
    seven="${pair%%$_GRADER_READING_US*}"; resets="${pair#*$_GRADER_READING_US}"
    [[ -n "$seven" ]] && src="account"
  fi
  if [[ -z "$seven" && -n "$json" ]]; then
    seven=$(printf '%s' "$json" | _pace_field "$acct" sevenDayPct)
    if [[ -n "$seven" ]]; then
      src="seat"
      resets=$(printf '%s' "$json" | _pace_field "$acct" sevenDayResetsAt)
    fi
  fi
  # Emptiness FIRST, always, and before any arithmetic — `(( < 60 ))` on an
  # empty operand is 0 in bash, which is the exact fail-open this guard family
  # exists to prevent (2026-09-09: 43% of the fleet read as 0% used).
  #
  # The reason names BOTH sources, because "has no weekly reading" used to read
  # as "this account is at its limit" when it actually meant "this account has
  # been quiet" — the misreading that kept DIVE-4575 open all day, and the one a
  # log line is the only trace of here.
  # DIVE-4586. Neither source carries a CURRENT reading. Before calling the
  # account blind, ask whether it carries a stale one whose window has not
  # turned over — a lower bound (see `_pace_account_seven_bound`). It is
  # consulted ONLY here, after both current sources have failed, and it is only
  # ever allowed to make the floor harder: over the hard floor it hardens, over
  # the soft floor it holds without the distance-to-reset relaxation that is
  # the one branch capable of BUYING dispatch, and under the soft floor it says
  # nothing at all and we fall into the blind branch below unchanged. A bound
  # cannot show an account is under a floor, only that it is over one.
  #
  # THE BOUND IS ONLY EVER A TIGHTENING DEVICE, under every policy — so it is
  # measured against what the blind branch below would otherwise return.
  # `FIVE_PACE_BLIND=open` (the default since DIVE-5364) falls to open, so a
  # bound over a floor is the ONLY thing that holds a blind account — at the
  # default 95/95, a remembered 95% or more is urgent-only. `FIVE_PACE_BLIND=soft`
  # falls to the soft floor, so a bound may move it to hard (tighter) or leave it
  # at soft (equal). `FIVE_PACE_BLIND=refuse`
  # already returns the tightest answer there is, so a bound could only ever
  # LOOSEN it — and that policy's contract is "no current meter, no dispatch",
  # which a lower bound does not satisfy. Under `refuse` the bound is therefore
  # not consulted at all.
  if [[ -z "$seven" && "$_PACE_BLIND" != "refuse" ]]; then
    lb_pair=$($_PACE_ACCOUNT_BOUND_CMD "$acct" "$now" 2>/dev/null || printf '')
    if [[ -n "$lb_pair" ]]; then
      lb_seven="${lb_pair%%$_GRADER_READING_US*}"; lb_resets="${lb_pair#*$_GRADER_READING_US}"
      lb_seven="${lb_seven%%.*}"
      if [[ "$lb_seven" =~ ^[0-9]+$ ]]; then
        if (( lb_seven >= _PACE_FLOOR_7D_HARD )); then
          printf 'pace: %s has no CURRENT weekly reading, but its last reading (%s%%) is inside a week that has not reset yet — a weekly percentage never falls before its reset, so the account is at AT LEAST %s%% (hard floor %s%%) — urgent only\n' \
                 "$acct" "$lb_seven" "$lb_seven" "$_PACE_FLOOR_7D_HARD"
          return 3
        fi
        if (( lb_seven >= _PACE_FLOOR_7D_SOFT )); then
          printf 'pace: %s has no CURRENT weekly reading, but its last reading (%s%%) is inside a week that has not reset yet — at LEAST %s%% (soft floor %s%%); a lower bound cannot buy the near-reset relaxation, so the floor stays armed — high/urgent only\n' \
                 "$acct" "$lb_seven" "$lb_seven" "$_PACE_FLOOR_7D_SOFT"
          return 2
        fi
      fi
    fi
  fi
  # DIVE-4629. Still no number, and no bound either. Before calling the account
  # BLIND — a word that means "we could not read it" and carries a hold that
  # waits for a carrier — ask whether this account's provider can ever publish
  # the number at all. The answer comes from the REGISTRY (which seats are bound
  # and what they run), never from the meter's silence, so a carrier outage on a
  # claude account can never reach this branch. See the block above
  # `_pace_seat_types` for why the default is `open` and why that is a statement
  # about jurisdiction rather than about consumption.
  if [[ -z "$seven" ]]; then
    pw=0; $_PACE_WINDOW_CAPABLE_CMD "$acct" >/dev/null 2>&1 || pw=$?
    if (( pw == 1 )); then
      # `FIVE_PACE_BLIND=refuse` is an operator saying "no current meter, no
      # dispatch". An account that can NEVER be metered is the strongest case of
      # that, not an exception to it, so the policy below is not consulted — and
      # the verdict says so out loud rather than leaving a knob that silently
      # does nothing.
      if [[ "$_PACE_BLIND" == "refuse" ]]; then
        printf 'pace: %s runs on a provider that publishes no weekly usage window at all, so this floor can never measure it — FIVE_PACE_BLIND=refuse holds it anyway (FIVE_PACE_UNMETERED=%s is not consulted under refuse) — no dispatch\n' \
               "$acct" "$_PACE_UNMETERED"
        return 1
      fi
      case "$_PACE_UNMETERED" in
        open)   unmet_band=0; unmet_why='this floor rations a weekly Anthropic window and this provider has none — not a reading of 0%, a meter with no jurisdiction here; its own plan is unmetered by us (DIVE-3968) — no hold' ;;
        soft)   unmet_band=2; unmet_why='policy FIVE_PACE_UNMETERED=soft rations it anyway — high/urgent only' ;;
        hard)   unmet_band=3; unmet_why='policy FIVE_PACE_UNMETERED=hard rations it anyway — urgent only' ;;
        refuse) unmet_band=1; unmet_why='policy FIVE_PACE_UNMETERED=refuse — no dispatch' ;;
        *)      unmet_band=2; unmet_why="FIVE_PACE_UNMETERED=${_PACE_UNMETERED} is not a policy I know (open|soft|hard|refuse) — falling back to the soft floor" ;;
      esac
      # The reason is a %s ARGUMENT, never part of the format: one of these
      # strings interpolates an env value, and a `%` in it would be read as a
      # conversion.
      printf 'pace: %s runs on a provider that publishes no weekly usage window at all: %s\n' "$acct" "$unmet_why"
      return "$unmet_band"
    fi
  fi
  if [[ -z "$seven" ]]; then
    if [[ -z "$json" ]]; then
      printf 'pace: %s has no weekly reading — no account reading measured within %ss and %s returned nothing; blind meter, policy=%s (never 0%%) — %s\n' \
             "$acct" "$_GRADER_READING_MAX_AGE" "$_PACE_USAGE_CMD" "$_PACE_BLIND" "$(_pace_blind_what)"
    else
      printf 'pace: %s has no weekly reading (null) — no account reading measured within %ss and no seat of the account carries one; blind meter, policy=%s — %s\n' \
             "$acct" "$_GRADER_READING_MAX_AGE" "$_PACE_BLIND" "$(_pace_blind_what)"
    fi
    local _brc=0; _pace_blind_rc || _brc=$?; return "$_brc"
  fi
  # Percentages arrive as floats (56.99999999999999); truncate to an integer
  # rather than hand bash a decimal point, which is a syntax error and aborts
  # under errexit.
  seven="${seven%%.*}"
  if ! [[ "$seven" =~ ^[0-9]+$ ]]; then
    printf 'pace: %s weekly meter is unparseable (7d=%s) — blind, never read as 0%%; %s\n' "$acct" "$seven" "$(_pace_blind_what)"
    local _brc=0; _pace_blind_rc || _brc=$?; return "$_brc"
  fi
  if (( seven >= _PACE_FLOOR_7D_HARD )); then
    printf 'pace: %s is at %s%% of its week (hard floor %s%%, from the %s reading) — urgent only\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_HARD" "$src"; return 3
  fi
  if (( seven < _PACE_FLOOR_7D_SOFT )); then
    printf 'pace: %s at 7d=%s%% (soft floor %s%%, from the %s reading) — no hold\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$src"; return 0
  fi
  # Over the soft floor. It binds only while there is still a week to pace. The
  # reset comes from whichever source gave us the pct (set above) — never from
  # the other one.
  resets="${resets%%.*}"
  if [[ "$resets" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]] && (( resets > now )); then
    days_left=$(( (resets - now) / 86400 ))
    if (( days_left <= _PACE_RESET_DAYS )); then
      printf 'pace: %s at %s%% (soft floor %s%%) but only %sd to the reset (<=%sd) — unspent headroom expires, no hold\n' \
             "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$days_left" "$_PACE_RESET_DAYS"; return 0
    fi
    printf 'pace: %s is at %s%% of its week (soft floor %s%%, from the %s reading) with %sd to the reset — high/urgent only\n' \
           "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$src" "$days_left"; return 2
  fi
  # Over the soft floor with NO readable reset. The distance-to-reset test is
  # the only thing that could RELAX the floor, so an unreadable one leaves the
  # floor armed — the unmeasured case never buys headroom.
  printf 'pace: %s is at %s%% of its week (soft floor %s%%, from the %s reading), reset time unreadable so the floor stays armed — high/urgent only\n' \
         "$acct" "$seven" "$_PACE_FLOOR_7D_SOFT" "$src"; return 2
}


# `_pace_field_5h <account> <now>` — the SESSION-window percentage for an
# account: the max over the account's seats, but reduced over READINGS and never
# over FIELDS. EMPTY when no seat of the account carries a live one.
#
# WHY THIS IS NOT `_pace_field` TWICE (DIVE-4631, quinn's iteration-1 finding).
# Every row of the usage document is built from THAT seat's own
# `~/.claude/statusline-last.json` (`src/cmd_usage.sh`), which is rewritten only
# when that seat runs. So a seat idle since it hit the wall carries a stale pct
# AND the stale reset that belongs to it, while an active sibling carries a
# current pair. Maxing the pct over all seats and then, separately, maxing the
# reset over all seats picks the pct from one seat and the clock from ANOTHER:
# the stale 101% is fenced against the fresh seat's reset, survives, and pins the
# whole account at `hard` on a window that turned over an hour ago. That hold is
# self-sustaining — the stale seat refreshes its cache only by RUNNING, which the
# hold prevents for everything below urgent — which is exactly the freeze this
# family keeps re-learning (DIVE-4430/4575/4586). A pct and its reset are ONE
# reading: community/wiki/a-pct-and-its-reset-are-one-reading.md, and this is its
# cross-seat instance.
#
# So: pair each seat's pct with ITS OWN `fiveHourResetsAt`, drop the pairs whose
# window has already turned over, and take the max of whatever survives. The
# fence is still `_grader_reading_expired` and nothing else — one place decides
# what "expired" means, it accepts both epoch seconds and vendor date strings,
# and an ABSENT or unparseable reset is NOT a passed one, so that reading is KEPT
# and the floor stays armed (decision 3's edge, unchanged).
_pace_field_5h() {  # <account> <now>  [<usage-json-on-stdin>]
  local acct="${1:-}" now="${2:-0}" json best="" pct reset
  json=$(cat)
  [[ -n "$acct" && -n "$json" ]] || { printf ''; return 0; }
  while IFS=$'\t' read -r pct reset; do
    [[ -n "$pct" ]] || continue
    pct="${pct%%.*}"
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    # `<seat>` is the reading's own clock, never a sibling's.
    if _grader_reading_expired "${reset%%.*}" "$now"; then continue; fi
    if [[ -z "$best" ]] || (( pct > best )); then best="$pct"; fi
  done < <(printf '%s' "$json" | jq -r --arg a "$acct" '
    (.data // .)
    | .. | objects | select(.account? == $a)
    | select(.fiveHourPct | numbers)
    | [ (.fiveHourPct | tostring), ((.fiveHourResetsAt // "") | tostring) ] | @tsv
  ' 2>/dev/null || printf '')
  printf '%s' "$best"
}
# `_pace_band_5h <account> [<now-epoch>]` — how hard is the SESSION-window floor?
#
# Same two channels as every band function here: verdict on stdout, decision in
# the exit status. Only TWO answers are reachable:
#
#   0  open — this window says nothing that should hold a row
#   3  hard — at or over `_PACE_FLOOR_5H`% of the session window; urgent only
#
# Four decisions are baked in, and each one is a place this could have been
# written differently:
#
# 1. NEVER `refuse`, and never `soft`. See the knob above.
#
# 2. A BLIND 5h READING CONTRIBUTES NOTHING — `open`, not a hold. `fiveHourPct:
#    null` is ordinary steady state here (`community`, `creative`, `ops`,
#    `codex` and `warm-mark` all read null on the box this was written on). The
#    WEEKLY band already holds a blind account at the soft floor, so a second
#    hold keyed on the same blindness double-counts one silence and paces the
#    whole fleet down on it. This is NOT the "never read an empty meter as 0%"
#    rule being broken (DIVE-4342): the weekly is still holding, and this
#    function is a TIGHTENER on top of it that declines to tighten.
#
# 3. A READING WHOSE `fiveHourResetsAt` HAS ALREADY PASSED IS DROPPED. It is the
#    same fence the weekly applies via `sevenResetsAt`, and it matters more
#    here: a 5h window turns over five times a day, so a stale high reading is
#    the common case rather than the exotic one. An ABSENT or unparseable reset
#    is not a passed one — `_grader_reading_expired` keeps that reading, and the
#    floor stays armed, because the unmeasured case never buys dispatch. The
#    fence is applied PER READING, inside `_pace_field_5h`, against that seat's
#    own reset — see the long note there for why an account-level fence is
#    unsound the moment the account has more than one seat.
#
# 4. NO NEAR-RESET RELAXATION. The weekly relaxes inside `_PACE_RESET_DAYS`
#    because unspent headroom expires at the reset. That reasoning does not
#    transfer: this floor is not a pacing rule at all — it exists so we do not
#    spend a dispatch on a turn that will be truncated — so being close to the
#    reset is a reason to WAIT for a whole window, never to spend the stub of
#    this one.
#
# The reading is `max` across the account's seats (`_pace_field_5h`), which is
# the fail-closed lower bound on a shared pool and the same reasoning DIVE-4586
# uses for the weekly — but the max is taken over live READINGS, not over the
# pct field on its own. CONFIRMED before it was written, on the live document
# 2026-09-19/20: every seat of `chemmonitor` reported 38/39/38% against ONE
# `fiveHourResetsAt` (1789891800), and every seat of `mark` reported 0% against
# one reset of its own — one window per ACCOUNT, sampled at slightly different
# moments per seat, not one window per seat. If that ever stops being true the
# right read is the seat's own, and the seat name is in hand at the dispatch
# call site (`$name`); this function would then take it as an argument.
_pace_band_5h() {  # <account> [<now-epoch>]  [<usage-json-on-stdin>]
  local acct="${1:-}" now="${2:-}" json five="" raw=""
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  # Read stdin FIRST and unconditionally, before any early return, so a caller
  # that pipes cannot be handed an EPIPE in place of a band.
  json=$(cat)
  [[ "${_PACE_FLOORS_FRESH:-}" == 1 ]] || _pace_floors_load
  if (( _PACE_5H_OFF )); then
    printf 'pace/5h: the session-window floor is off on this box (pace-5h=off, from %s) — contributes nothing\n' "$_PACE_5H_SRC"
    return 0
  fi
  if [[ -z "$acct" || -z "$json" ]]; then
    printf 'pace/5h: no session-window reading (%s) — the session floor contributes nothing; the weekly band stands alone\n' \
           "$( [[ -z "$acct" ]] && printf 'no account named' || printf 'no usage document' )"
    return 0
  fi
  # ONE reduction, over READINGS: each seat's pct is fenced on that seat's own
  # clock and the max is taken over the survivors. There is deliberately no
  # post-hoc `_grader_reading_expired` here any more — a second, account-level
  # fence could only ever be applied to a reset that had itself been maxed
  # across seats, which is the unpairing this helper exists to prevent. The
  # single-seat path is not special-cased either: with one seat the reduction
  # degenerates to that seat's own pair, which is what the old post-hoc check
  # was doing by accident rather than by construction.
  five=$(printf '%s' "$json" | _pace_field_5h "$acct" "$now")
  if [[ -z "$five" ]]; then
    # Nothing survived. Say WHICH of the two silences it was, because they have
    # different operator meanings: no meter at all, or every meter belonging to
    # a window that has since turned over.
    raw=$(printf '%s' "$json" | _pace_field "$acct" fiveHourPct)
    if [[ -n "$raw" ]]; then
      printf 'pace/5h: %s reads %s%% of a session window that has ALREADY reset — a percentage from a window that has since turned over is not a statement about the one we are pacing; dropped (every seat carrying a reading was fenced on its OWN fiveHourResetsAt)\n' \
             "$acct" "${raw%%.*}"
      return 0
    fi
    printf 'pace/5h: %s has no session-window reading (null or unparseable) — a blind 5h meter contributes NOTHING here; the weekly band is what holds a blind account (DIVE-4631 decision 2)\n' "$acct"
    return 0
  fi
  if (( five >= _PACE_FLOOR_5H )); then
    printf 'pace/5h: %s is at %s%% of its 5-hour session window (floor %s%%) — a turn started now is truncated at the wall, so urgent only\n' \
           "$acct" "$five" "$_PACE_FLOOR_5H"
    return 3
  fi
  printf 'pace/5h: %s at 5h=%s%% (floor %s%%) — no hold\n' "$acct" "$five" "$_PACE_FLOOR_5H"
  return 0
}
# `_pace_rank <band-rc>` — how TIGHT is this band, as an orderable number. The
# exit codes are not ordered (1 is the tightest and sorts lowest), so the
# combiner cannot compare them directly. An unknown code ranks tightest: a band
# we cannot read must not be the one that wins by being loose.
_pace_rank() {  # <band-rc>
  case "${1:-}" in 0) printf 0 ;; 2) printf 1 ;; 3) printf 2 ;; 1) printf 3 ;; *) printf 3 ;; esac
}

# `_pace_band <account> [<now-epoch>]` — THE TIGHTER of the weekly floor and the
# session-window floor (DIVE-4631).
#
# The combiner lives here rather than at the call sites deliberately: heartbeat
# dispatch, the materializer and anything added later all get the session window
# with no change of their own, and there is exactly one place where the two
# windows are reconciled.
#
# Same dual channel as before (DIVE-4380) — verdict on stdout, decision in the
# exit status — so every existing caller is unchanged:
#
#   0  open   — dispatch everything, as today
#   2  soft   — high|urgent only, no recurring template firing
#   3  hard   — urgent only, no recurring template firing
#   1  refuse — no dispatch at all (only reachable under FIVE_PACE_BLIND=refuse)
#
# Both halves are fed with a HERE-STRING, never a pipe: `_pace_band_7d` returns
# before its `json=$(cat)` when no account is named, and under the bundle's
# `set -euo pipefail` a pipe would hand us printf's EPIPE status in place of the
# band. Reading stdin once here also means a caller may still pipe into
# `_pace_band` itself, which both shipping call sites do.
_pace_band() {  # <account> [<now-epoch>]  [<usage-json-on-stdin>]
  local acct="${1:-}" now="${2:-}" json v7="" v5="" rc7=0 rc5=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  json=$(cat)
  # ONE read of the floors per band, shared by both windows (the flag is local,
  # so it reaches the two subshells below and nothing after this call).
  _pace_floors_load
  local _PACE_FLOORS_FRESH=1
  v7=$(_pace_band_7d "$acct" "$now" <<<"$json") || rc7=$?
  v5=$(_pace_band_5h "$acct" "$now" <<<"$json") || rc5=$?
  if (( $(_pace_rank "$rc5") > $(_pace_rank "$rc7") )); then
    printf '%s · (weekly: %s)\n' "$v5" "$v7"
    return "$rc5"
  fi
  if (( rc5 != 0 )); then
    printf '%s · (session window: %s)\n' "$v7" "$v5"
    return "$rc7"
  fi
  printf '%s\n' "$v7"
  return "$rc7"
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
