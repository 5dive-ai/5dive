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
  (( now >= asof && now - asof <= _GRADER_READING_MAX_AGE )) || return 0
  five=$(jq -r  '.fiveHourPct // empty'   <<<"$json" 2>/dev/null || printf '')
  seven=$(jq -r '.sevenDayPct // empty'   <<<"$json" 2>/dev/null || printf '')
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

# `_grader_window_ok <account>` — may we spawn a grader on this account?
# Exit 0 = yes. Non-zero = no, with the reason on stdout for the row's record.
#
# ═══ THIS FUNCTION FAILS CLOSED, AND THAT IS THE WHOLE POINT OF IT ═══
#
# The natural way to write the test is `(( pct < FLOOR ))`. With an empty pct
# that is `(( < 80 ))`, and bash evaluates an empty arithmetic operand as ZERO —
# so a seat whose meter said NOTHING reads as 0% used and spawns. The cap fails
# OPEN precisely on the seats it knows least about, which is backwards, and on
# 2026-09-09 that was 43% of the fleet. Every refusal below is therefore written
# as an explicit emptiness test BEFORE any numeric comparison.
_grader_window_ok() {  # <account>  [<usage-json-on-stdin>]
  local acct="$1" json five="" seven=""
  if [[ -z "$acct" ]]; then
    printf 'refuse: no account named — a floor with no account is not a measurement\n'; return 1
  fi
  json=$(cat)
  # NOT a refusal on its own any more (DIVE-4575): an empty per-seat document is
  # the normal state of a quiet fleet, and the account reading below may still
  # carry the window. It becomes a refusal only if that source is blind too, and
  # the message below says so.
  # DIVE-4575: THE ACCOUNT'S READING FIRST. Per window, not per document, so one
  # blind window on the better source does not throw away its good one.
  local pair five_src="" seven_src=""
  pair=$($_GRADER_ACCOUNT_READING_CMD "$acct" 2>/dev/null || printf '')
  if [[ -n "$pair" ]]; then
    five="${pair%%$_GRADER_READING_US*}"; seven="${pair#*$_GRADER_READING_US}"
    if [[ -n "$five" ]];  then five_src="account";  fi
    if [[ -n "$seven" ]]; then seven_src="account"; fi
  fi
  if [[ -z "$five" ]]; then
    five=$(printf '%s' "$json" | _grader_pct "$acct" fiveHourPct)
    if [[ -n "$five" ]]; then five_src="seat"; fi
  fi
  if [[ -z "$seven" ]]; then
    seven=$(printf '%s' "$json" | _grader_pct "$acct" sevenDayPct)
    if [[ -n "$seven" ]]; then seven_src="seat"; fi
  fi

  # Emptiness first, always, and each side separately so the reason names which
  # meter was blind rather than blaming "the meter". The reason now also names
  # that BOTH sources were asked: "no 5h reading" used to read as "this seat is
  # quiet", which is exactly the misreading that left DIVE-4575 open all day.
  if [[ -z "$five" ]]; then
    printf 'refuse: %s has no 5h reading (null) — no account reading measured within %ss and no seat of the account carries one; failing closed, not assuming 0%%\n' \
           "$acct" "$_GRADER_READING_MAX_AGE"; return 1
  fi
  if [[ -z "$seven" ]]; then
    printf 'refuse: %s has no weekly reading (null) — no account reading measured within %ss and no seat of the account carries one; failing closed, not assuming 0%%\n' \
           "$acct" "$_GRADER_READING_MAX_AGE"; return 1
  fi
  # Percentages arrive as floats (56.99999999999999); strip to integer for the
  # comparison rather than trusting bash arithmetic with a decimal point, which
  # is a syntax error and would abort under errexit.
  five="${five%%.*}"; seven="${seven%%.*}"
  if ! [[ "$five" =~ ^[0-9]+$ && "$seven" =~ ^[0-9]+$ ]]; then
    printf 'refuse: %s meter is unparseable (5h=%s 7d=%s)\n' "$acct" "$five" "$seven"; return 1
  fi
  if (( five >= _GRADER_FLOOR_5H )); then
    printf 'queue: %s is at %s%% of its 5h window (floor %s%%) — spawn waits for the reset\n' \
           "$acct" "$five" "$_GRADER_FLOOR_5H"; return 2
  fi
  if (( seven >= _GRADER_FLOOR_7D )); then
    printf 'queue: %s is at %s%% of its weekly window (floor %s%%) — spawn waits for the reset\n' \
           "$acct" "$seven" "$_GRADER_FLOOR_7D"; return 2
  fi
  printf 'ok: %s at 5h=%s%% 7d=%s%% (5h from the %s reading, 7d from the %s reading)\n' \
         "$acct" "$five" "$seven" "${five_src:-seat}" "${seven_src:-seat}"; return 0
}

# `_grader_spawn_request <ident> <task_id> <verifier> <iteration>` — record that
# this delivery wants a grader.
#
# EMITTED FROM `_task_route_to_verifier`, WHICH IS WHY THE GUARDRAIL HOLDS.
# The row's first guardrail is "never maker-spawned". That helper is the ONE
# funnel every delivery passes through — both of `task done`'s routing forks and
# `task deliver` — which is why DIVE-4144's bare-re-deliver guard was put there
# too. Emitting from it means the spawn is a consequence of the SYSTEM recording
# a delivery, not an act the maker performs: there is no code path by which a
# maker names, times or primes its own judge, and that is a structural property
# rather than a rule someone has to remember.
#
# A REQUEST, NOT A SPAWN, and the distinction is deliver-on-push. The supervisor
# lane consumes these and does the spawning on its own tick. If this function
# actually started a grader, `task done` would block until one existed — which is
# the polling wait deliver-on-push exists to forbid, re-introduced at the exact
# point the maker is trying to walk away.
#
# NEVER FATAL. The caller invokes it with `|| true`: a delivery that is already
# durably recorded must not be failed by a bookkeeping write. A lost request is
# recoverable (the supervisor also sweeps delivered-but-ungraded rows); a delivery
# that errored after the row was updated is not.
_grader_spawn_request() {  # <ident> <task_id> <verifier> <iteration>
  local ident="$1" tid="$2" vfier="$3" iter="$4"
  [[ -n "$ident" ]] || return 0
  declare -F ledger_emit >/dev/null 2>&1 || return 0
  ledger_emit task.grade.requested ident="$ident" task_id="$tid" \
    actor="$(task_actor "")" \
    detail="ephemeral grader requested for iteration ${iter}${vfier:+ (pinned: ${vfier})}"
}

# `_grader_checkpoint <ident> <arm> <verdict> <sha>` — one verified arm, appended.
#
# TO THE LEDGER, NOT THE SESSION, because the grader has no session to come back
# to. A walled grader must leave a partial record the NEXT one can resume from;
# that is DIVE-4104's principle (a walled verifier must not destroy the grade)
# applied to a grader that is ephemeral by construction.
#
# lifecycle_events is the store for the same reason DIVE-2777 chose it: it is
# append-only and nothing on the re-delivery path rewrites it, so a checkpoint
# cannot be clobbered by the next delivery the way a result column would be.
_grader_checkpoint() {  # <ident> <arm> <verdict> <graded-sha>
  local ident="$1" arm="$2" verdict="$3" sha="$4"
  [[ -n "$ident" && -n "$arm" ]] || return 0
  declare -F ledger_emit >/dev/null 2>&1 || return 0
  ledger_emit task.grade.checkpoint ident="$ident" actor="$(task_actor "")" \
    detail="arm=${arm} verdict=${verdict:-unknown} sha=${sha:-unknown}"
  # MIRRORED INTO THE ROW BODY, and the mirror is the half that matters for
  # resumption. The ledger is the durable record, but the NEXT grader is a fresh
  # wake, and a fresh wake reads the ROW — that is the assumption the whole loop
  # already runs on. A checkpoint only the ledger holds is a checkpoint the
  # thing it exists for will never look at.
  #
  # Best-effort: a failed mirror must not lose the ledger row that already
  # landed, so the append is guarded and never propagates a failure.
  declare -F cmd_task_set_body >/dev/null 2>&1 || return 0
  local line="- grade checkpoint: arm=${arm} verdict=${verdict:-unknown} sha=${sha:-unknown}"
  ( JSON_MODE=0; cmd_task_set_body "$ident" "$line" --append ) >/dev/null 2>&1 || true
  return 0
}

# `5dive task grader-replay [--days=N] [--cap=N] [--json]` — DIVE-4164 deliverable 2.
#
# Replays the real delivery history through the spawner's ARITHMETIC and reports
# what it would have done: grades per day, peak concurrent graders, and how much
# would have queued at a given cap. Read-only and dry-run BY CONSTRUCTION — it
# reads lifecycle_events and prints; it holds no spawn path at all, which is why
# it is safe to point at production history.
#
# WHAT IT CANNOT DO, said plainly rather than left for a reader to discover: the
# usage meter is a CURRENT reading with no history, so this cannot replay the
# floor. It replays ARRIVALS against a cap. "How often would the floor have
# queued us" is not answerable from any data we keep, and pretending otherwise by
# applying today's percentages to last week's deliveries would produce a
# confident number that means nothing.
#
# Pairing: each `task.delivered` is matched to the next `task.done`/`task.rejected`
# for the same ident. Deliveries older than the window are excluded, so every
# figure is a LOWER bound — the honest direction for a capacity argument.
cmd_task_grader_replay() {
  # --json may already have been consumed by the global pre-parser (main.sh
  # sets JSON_MODE), so seed from it rather than assuming the flag reaches here.
  local days=7 cap="$_GRADER_MAX_PER_ACCOUNT" json="${JSON_MODE:-0}" svc=""
  while (( $# )); do
    case "$1" in
      --days=*) days="${1#--days=}" ;;
      --cap=*)  cap="${1#--cap=}" ;;
      --service-cap=*) svc="${1#--service-cap=}" ;;
      --json)   JSON_MODE=1; json=1 ;;
      *) fail "$E_USAGE" "usage: 5dive task grader-replay [--days=N] [--cap=N] [--json]" ;;
    esac; shift
  done
  [[ "$days" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ ]] \
    || fail "$E_VALIDATION" "--days and --cap take whole numbers"
  [[ -z "$svc" || "$svc" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "$E_VALIDATION" "--service-cap takes hours (e.g. 1 or 0.5)"
  local rows
  rows=$(db "SELECT ts||'|'||kind||'|'||COALESCE(ident,'')
               FROM lifecycle_events
              WHERE kind IN ('task.delivered','task.done','task.rejected')
                AND ts >= datetime('now','-${days} days')
              ORDER BY ts, id;")
  printf '%s\n' "$rows" | python3 -c '
import sys, datetime as dt, json as J
cap=int(sys.argv[1]); days=int(sys.argv[2]); want_json=sys.argv[3]=="1"
svc=float(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else None
ev=[]
for line in sys.stdin:
    p=line.rstrip("\n").split("|")
    if len(p)<3 or not p[0]: continue
    try: ev.append((dt.datetime.fromisoformat(p[0]), p[1], p[2]))
    except ValueError: continue
openq={}; spans=[]; perday={}
for ts,kind,ident in ev:
    if kind=="task.delivered":
        perday[ts.date().isoformat()]=perday.get(ts.date().isoformat(),0)+1
        openq.setdefault(ident, ts)
    else:
        t0=openq.pop(ident,None)
        if t0 is not None: spans.append((t0,ts))
lat=sorted((b-a).total_seconds()/3600 for a,b in spans)
# THE HISTORICAL SERVICE TIME INHERITS THE DISEASE THIS DESIGN REMOVES: the p90
# tail is a row waiting on a standing seats wake cadence, not grading. Replaying
# it unmodified therefore OVER-estimates the pool a fast ephemeral grader needs.
# --service-cap=H answers "what if every grade finished within H hours" instead.
if svc is not None:
    spans=[(a, min(b, a+dt.timedelta(hours=svc))) for a,b in spans]
def q(v,p):
    if not v: return None
    return round(v[min(len(v)-1,int(round(p*(len(v)-1))))],2)
marks=[]
for a,b in spans: marks.append((a,1)); marks.append((b,-1))
for t0 in openq.values(): marks.append((t0,1))
marks.sort()
cur=peak=0
for t,d in marks:
    cur+=d; peak=max(peak,cur)
# queueing at the cap: a delivery arriving with cap graders busy waits.
busy=[]; queued=0; maxq=0
for a,b in sorted(spans):
    busy=[x for x in busy if x>a]
    if len(busy)>=cap:
        queued+=1; maxq=max(maxq,len(busy)-cap+1)
        busy.sort(); start=busy[0]
    else: start=a
    busy.append(max(b,start))
out={"windowDays":days,"deliveries":sum(perday.values()),
     "perDay":dict(sorted(perday.items())),"resolved":len(spans),
     "stillOutstanding":len(openq),
     "latencyHoursP50":q(lat,.5),"latencyHoursP90":q(lat,.9),
     "latencyHoursMax":round(lat[-1],1) if lat else None,
     "peakConcurrentGraders":peak,"cap":cap,
     "wouldQueueAtCap":queued,"maxQueueDepth":maxq,"serviceCapHours":svc}
if want_json: print(J.dumps(out,indent=2)); raise SystemExit
nd=out["deliveries"]; nr=out["resolved"]; no=out["stillOutstanding"]
p50=out["latencyHoursP50"]; p90=out["latencyHoursP90"]; pmx=out["latencyHoursMax"]
print(f"deliveries in {days}d : {nd}  (resolved {nr}, still outstanding {no})")
for d,n in out["perDay"].items(): print(f"  {d}  {n}")
print(f"grade latency h      : p50={p50} p90={p90} max={pmx}")
print(f"peak concurrent      : {peak} graders")
print(f"at cap={cap}          : {queued} deliveries would queue, max depth {maxq}")
if svc is not None:
    print(f"service time CAPPED at {svc}h — modelling a fast ephemeral grader, not the seats we run today")
print("NOTE: arrivals replayed against the cap. The usage meter keeps no history,")
print("      so the spawn FLOOR is not replayable and is not modelled here.")
' "$cap" "$days" "$json" "$svc"
}

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

# `_grader_can_read <seat> <ident>` — can this seat get a true answer out of
# GitHub about the repo it would grade?
#
# REUSES `task merge-gate-selftest`, which already asks exactly this and answers
# with its EXIT STATUS. The question is deliberately not "did a token resolve" —
# a seat holding a credential that cannot see the repo is, from the gate's
# vantage, as blind as one holding nothing, and those two were indistinguishable
# before that verb existed.
#
# A DENIED `sudo -u` IS INDISTINGUISHABLE FROM A REAL NEGATIVE — both exit
# non-zero — and here that ambiguity is SAFE, which is worth stating because
# elsewhere on this host it is the classic trap. The dangerous direction is a
# probe that fails OPEN and reads "contained" whether or not it ran. This one
# fails CLOSED: an unrunnable probe means we decline to spawn on that seat and
# fall through to the next. The cost of being wrong is a queued grade, not a
# blind one.
_GRADER_READ_PROBE="${_GRADER_READ_PROBE:-}"
_grader_can_read() {  # <seat> <ident>
  local seat="$1" ident="$2"
  [[ -n "$seat" ]] || return 1
  if [[ -n "$_GRADER_READ_PROBE" ]]; then "$_GRADER_READ_PROBE" "$seat" "$ident"; return $?; fi
  local ref; ref=$(db "SELECT COALESCE(delivery_ref,'') FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  [[ -n "$ref" ]] || return 1
  # ══ TWO THINGS WERE WRONG HERE, AND EACH ALONE MADE THE LANE UNSPAWNABLE ══
  # (DIVE-4217, measured on the live store 2026-09-10: pending=8 spawn=0 queue=8,
  # every line "has headroom but cannot read the delivery ref".)
  #
  # 1. A SEAT NAME IS NOT A UNIX ACCOUNT. The pool, the ledger, `task assign` and
  #    `agent send` all speak seat names (`quinn`); the account this host will
  #    switch to is `agent-quinn`, which is how every other seat-targeting sudo
  #    in this CLI spells it. `sudo -n -u quinn` exits 1 with "unknown user
  #    quinn" — indistinguishable from a genuine refusal.
  #
  # 2. `merge-gate-selftest --pr=` TAKES A KNOWN-MERGED CONTROL PR, NOT THE
  #    SUBJECT. Its own usage says `--pr=<merged pull url>`, and it returns
  #    non-zero with verdict `wrong` on anything that does not read MERGED. Fed
  #    the row's live `delivery_ref` it therefore refuses EVERY delivery that is
  #    still open — that is, every delivery there is any point grading — and
  #    passes only on refs already merged, which need no grader. The guardrail
  #    was inverted: it admitted exactly the rows it should have skipped.
  #
  # What the design actually asked for (see the wiki page below, answer 4) is
  # "can THIS seat get a true answer out of GitHub about THIS repo". That is a
  # READ of the subject whose STATE IS IRRELEVANT: any state at all means the
  # rail answered, and an empty answer means it did not. This is NOT a widening
  # of the guardrail — a blind seat still fails it. Measured discriminating on
  # both seats the same day: 5dive-ai/5dive#841 -> OPEN (readable),
  # lodar/5dive-api#149 -> empty (quinn and main2 genuinely 403 on lodar/*).
  # `5dive gh` is used rather than bare `gh` so the read is routed by the same
  # identity policy every other read in this CLI goes through.
  #
  # community/wiki/a-selftest-is-not-a-capability-probe-and-reusing-one-inverts-the-guardrail.md
  local state
  state=$(sudo -n -u "agent-${seat}" 5dive gh pr view "$ref" --json state -q .state 2>/dev/null | tail -1)
  [[ -n "$state" ]]
}

# ══ DIVE-4410: PER-SEAT LOAD — the pool is a set of seats, not a preference list ══
#
# The pick loop below was first-fit over `$_GRADER_POOL`, gated only by ACCOUNT
# headroom and repo readability. Neither of those is per-SEAT, so with two seats
# on one account the first name in the pool won every time. MEASURED (main,
# 2026-09-13): /var/log/5dive-grader.log carried 126 spawns since 2026-09-10 and
# every one of them read `-> quinn`; the 06:1xZ tick spawned DIVE-4404, 4397,
# 4401 and 4405 onto quinn in a single pass while main2 sat idle.
#
# A SPAWN IS assign+wake ON A SEAT, and a seat runs ONE session at a time
# (`_grader_spawn_session` below — it is not a new process). So N spawns onto one
# seat is not N graders, it is an N-deep serial queue wearing the lane's name.
# That is the whole defect: the counters said `spawn=4`, the fleet ran 1.
#
# So the seat is chosen by LOAD, and the cap that matters here is per seat:
# one in-flight grade per pool seat. When every seat is at it the row QUEUES —
# it does not stack a second grade behind the first, because stacking is exactly
# what looked like capacity and was not.
_GRADER_MAX_PER_SEAT="${_GRADER_MAX_PER_SEAT:-1}"

# ══ DIVE-4417: THE MODE SWITCH LIVES HERE, WITH THE TICK THAT READS IT ══
#
# `src/task/grader_process.sh` holds the process machinery; these four
# predicates hold the QUESTION the tick asks, and they are in this file on
# purpose. Every call into that file below is behind `_grader_process_mode`, so
# in the shipped default — session mode — the tick reaches none of it and this
# file is still standalone: `tests/grader_tick_unit.sh` sources it alone, and a
# lane whose default path depended on a second file would have that harness
# grading a shape the bundle never runs.
#
# ── DIVE-4521: THE DEFAULT IS NOW `process`. WHAT THAT COST TO SAY ──
#
# It shipped as `session` — byte-for-byte the old behaviour — because naming
# `process` is a THIRD lock, deliberate and separate from naming the pool: that
# mode starts a paid ephemeral CLONE SEAT per delivery with no per-seat serial
# queue in front of it. DIVE-4496 merged the whole create/creds/wake/sweep path
# to main (17ad9baa) behind this one expansion, so until it flipped the lane was
# code nothing could reach.
#
# The flip is this line and the four preconditions DIVE-4496's PASS signed, all
# of which are in this diff or beside it:
#   1. `flock -n` on the `*/5` grader-tick cron line (a create is synchronous
#      wall time inside the tick; the code bound
#      `_GRADER_CLONE_MAX_CREATES_PER_TICK` keeps a tick well inside its period,
#      but the lock is the real control).
#   2. a NATURALLY-QUEUED delivery graded end-to-end by a clone that is then
#      reaped — the state this flip newly exposes, and the arm the row is
#      accepted on.
#   3. `ghu_` / fine-grained `github_pat_` in the clone-creds refusal alphabet
#      (grader_process.sh): "cannot appear in those two files today" stops being
#      a standing fact the moment the lane is live.
#   4. the lineage guard below — `writer != grader` compares NAMES, and a clone
#      of the maker passes that check while carrying the maker's inherited blind
#      spots.
#
# Anything unrecognised still reads as `session`, so a typo'd mode degrades to
# the OLD behaviour rather than to the new default.
_GRADER_SPAWN_MODE="${_GRADER_SPAWN_MODE:-process}"

# A PREDICATE, not a bare `[[ ]]` at each of the five sites that ask: a mode
# spelled differently in one of them is a lane that counts processes and then
# wakes a session.
_grader_process_mode() { [[ "$_GRADER_SPAWN_MODE" == "process" ]]; }

# The mode name for the plan and the JSON. Anything unrecognised reads as
# `session` — a typo'd mode must degrade to today's behaviour, and the plan must
# say which behaviour it degraded to rather than printing the typo back.
_grader_spawn_mode() { _grader_process_mode && printf 'process' || printf 'session'; }

# ══ DIVE-4521 (precondition 4, live case DIVE-4514): SAME-ORIGIN IS NOT A GRADE ══
#
# `writer != grader` (DIVE-474/477) compares agent NAMES. Contamination comes
# from where a seat STARTED, not from what its directives say today, and the
# registry has no lineage field — so `main` -> `main2`, a clone seeded from
# main's own directives, is invisible to that guard BY CONSTRUCTION. The board
# cannot refuse what it cannot represent.
# community/wiki/the-writer-not-grader-guard-is-lineage-blind-a-clone-can-grade-its-origins-maker.md
#
# Two changes made that STANDING rather than incidental: DIVE-4410 spreads
# spawns across pool seats on purpose, and this row's flip makes every grader a
# clone. So the refusal has to be representable here, in the dispatcher, instead
# of relying on a clone recognising itself and declining by hand — which is what
# actually happened on DIVE-4514 and is not a control.
#
# THREE SOURCES, CHEAPEST FIRST, and the order is the whole design:
#   1. `_GRADER_SEAT_ORIGINS` — an operator map (`"main2=main"`), because the
#      pre-existing pool clones were minted before anything recorded lineage and
#      no amount of reading can recover it. It sits on the cron line beside
#      `_GRADER_POOL` for the same reason that does: it is fleet shape, not code.
#   2. the clone's own NAME, which THIS lane mints (`gr-quinn-1` -> `quinn`).
#      Derived with pure string ops and the prefix defaulted locally, never by
#      calling into grader_process.sh: `tests/grader_tick_unit.sh` sources this
#      file ALONE and a cross-file call here would grade a half-built lane.
#   3. the registry's `origin` field, which `_grader_clone_create` now writes for
#      every clone it mints (grader_process.sh) — the lineage field the wiki page
#      asks for, populated where this lane is the one that knows the answer.
# An agent none of the three can place is its OWN origin, which fails toward
# spawning rather than toward a lane that refuses every seat it cannot explain.
_GRADER_SEAT_ORIGINS="${_GRADER_SEAT_ORIGINS:-}"
_grader_seat_origin() {  # <agent> -> the agent this one descends from
  local a="${1:-}" pair pfx="${_GRADER_CLONE_PREFIX:-gr-}" o=""
  [[ -n "$a" ]] || return 1
  for pair in $_GRADER_SEAT_ORIGINS; do
    [[ "$pair" == "${a}="* && -n "${pair#*=}" ]] && { printf '%s' "${pair#*=}"; return 0; }
  done
  if [[ "$a" == "${pfx}"* ]]; then
    o="${a#"$pfx"}"
    [[ "$o" == *-* ]] && { printf '%s' "${o%-*}"; return 0; }
  fi
  if [[ -r "${REGISTRY:-}" ]]; then
    o=$(jq -r --arg n "$a" '.agents[$n].origin // empty' "$REGISTRY" 2>/dev/null || printf '')
  fi
  printf '%s' "${o:-$a}"
}

# Same-origin, not same-name. Two unnamed seats are not a collision (an unknown
# maker must not refuse the whole pool), which is why both names are required.
_grader_same_origin() {  # <seat> <maker>
  [[ -n "${1:-}" && -n "${2:-}" ]] || return 1
  [[ "$(_grader_seat_origin "$1")" == "$(_grader_seat_origin "$2")" ]]
}

# ══ DIVE-4496: HOW MANY CLONES ONE TICK MAY CREATE ══
#
# A clone is created SYNCHRONOUSLY (see grader_process.sh: the create's exit
# status is the only honest answer to "did this launch start"), so every create is
# wall time the tick spends inline. The live cron is `*/5` with NO flock, so a
# tick that outran its own period would overlap the next one and two ticks could
# spawn the same delivery twice. One create per tick keeps the tick an order of
# magnitude inside its period; the lane still reaches its seat cap, over
# consecutive ticks instead of inside one, and a grade runs 4-9 minutes so the
# cap is full long before the first verdict.
#
# It bounds CREATES, never the cap: clones already running are untouched by it,
# and a tick that spends its budget QUEUES the rest with that reason named.
_GRADER_CLONE_MAX_CREATES_PER_TICK="${_GRADER_CLONE_MAX_CREATES_PER_TICK:-1}"
_grader_clone_create_budget() {
  # `:-1` and not a bare expansion: this is read inside subshells the harness
  # and the tick both create, and an UNSET variable under the bundle's `set -u`
  # would abort the tick rather than fall back to the default.
  local n="${_GRADER_CLONE_MAX_CREATES_PER_TICK:-1}"
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" || printf '1'
}

# The per-seat bound in force, by mode. Read through a function so the two
# comparison sites in the tick cannot disagree about which bound applies. ONE is
# correct for a serial seat and must stay 1 there (DIVE-4410: a second wake on a
# seat is a queue, not a grader); it is only once the grades are separate
# processes that this constant is the thing to raise.
_grader_max_per_seat() {
  if _grader_process_mode; then printf '%s' "${_GRADER_MAX_PER_SEAT_PROCESS:-4}"
  else printf '%s' "$_GRADER_MAX_PER_SEAT"; fi
}

# The per-seat reading, from whichever source the mode names — ledger rows for a
# session lane, the live process table for a process lane. One function so a
# future mode cannot be taught to the cap and forgotten in the spread; the two
# disagreeing about which grades exist is the DIVE-4418 failure in a new place.
_grader_load_source() {
  if _grader_process_mode; then _grader_process_seat_loads; else _grader_seat_loads; fi
}

# The seat rides in the spawn row's DETAIL (`grader session on <seat>`), which is
# the only place it is recorded — `task.grade.spawned` has no seat column and
# lifecycle_events is append-only, so adding one would leave every historical row
# NULL. `substr(...,19)` skips that fixed 18-character prefix; anything else is
# bucketed as unattributable and counted against no seat, which is the reading
# that fails toward SPAWNING rather than toward a phantom busy seat.
# Kept as one string so the load query and the round-robin cursor cannot drift
# apart in how they read a seat name.
_GRADER_SEAT_EXPR="CASE WHEN s.detail LIKE 'grader session on %'
        THEN CASE WHEN instr(substr(s.detail,19),' ')>0
                  THEN substr(s.detail,19,instr(substr(s.detail,19),' ')-1)
                  ELSE substr(s.detail,19) END
        ELSE '' END"

# ── DIVE-4418: a grade that never reaches a verdict must not pin its slot ──
#
# Every exit below is an EVENT THAT HAS TO HAPPEN. A killed session, a seat
# parked mid-grade, a wake that never landed — none of them emit anything, so
# before this bound the spawn row stayed in the in-flight set FOREVER and the
# slot it held was never returned. That is not a hypothetical: DIVE-4322 exists
# because merge-parked PASSes froze 19 grades for three hours, and DIVE-4410
# (the commit this sits on) narrows the tolerance from "1 of 4 account slots" to
# "1 of 2 seats" — one stuck grade is now HALF the lane and two are all of it.
#
# WHY SIX HOURS. Measured on the live store 2026-09-13, all 53 `task.grade.spawned`
# rows ever emitted, spawn -> first task.graded/done/rejected: 52 resolved, p50
# 0.5h, p90 ~2.6h, max 5.92h (DIVE-4276, a PASS parked on an unmergeable PR —
# the very close-lag DIVE-4322 then removed from the exit set). Since that fix
# landed the tail collapsed: the 21 spawns from 2026-09-12 onward all resolved
# inside 0.84h. Six hours is therefore above every real grade this lane has ever
# run INCLUDING the pathological one, so the bound cannot cut a live grader off
# — it only reclaims a slot nothing is using.
#
# IT IS A CEILING ON THE COUNT, NOT A KILL. Nothing is signalled to the seat and
# no session is stopped; a straggler that does finish still emits its verdict and
# still grades the row. The only thing the bound changes is whether a spawn with
# no verdict keeps SPENDING capacity, and the answer after six hours is no.
_GRADER_STALE_HOURS="${_GRADER_STALE_HOURS:-6}"

# Validated in ONE place because the value is env-supplied and reaches three
# different consumers — two interpolated into SQL and one into a `%d`. A garbage
# value must degrade to the default everywhere at once; validating at each use
# site is how a knob ends up meaning 6 in the query and blowing up in the printf.
_grader_stale_hours() {
  local h="${_GRADER_STALE_HOURS}"
  [[ "$h" =~ ^[0-9]+$ ]] && printf '%s' "$h" || printf '6'
}

# `_grader_inflight_exits_sql` — the in-flight predicate, and the ONE place it
# lives. Both readers below (`_grader_seat_loads`, and the account-wide cap in
# the tick) interpolate THIS, so they cannot drift: if they disagreed, the lane
# would refuse on one count and spread on the other and no reader could say which
# number the plan line meant.
#
# A FUNCTION RATHER THAN A STRING CONSTANT, deliberately. `_GRADER_STALE_HOURS`
# is env-overridable, and a constant would bake whatever the value was AT SOURCE
# TIME — so a harness (or an operator) that set the bound after the bundle loaded
# would get the default and no error. Printing the fragment at call time means the
# knob is read when the query is built, which is the only moment it can be right.
#
# Assumes the spawn row is aliased `s`, and expects its caller to have already
# selected which spawn rows it cares about. See the long DIVE-4322 note on the cap
# for why the exit set is the VERDICT (task.graded / a verdict clock strictly
# later than this spawn) and not the row's close.
_grader_inflight_exits_sql() {
  local hours; hours=$(_grader_stale_hours)
  cat <<SQL
           AND s.ts >= datetime('now','-${hours} hours')
           AND NOT EXISTS (SELECT 1 FROM lifecycle_events d
                            WHERE d.ident=s.ident
                              AND d.kind IN ('task.done','task.rejected','task.graded')
                              AND d.id > s.id)
           AND NOT EXISTS (SELECT 1 FROM tasks t
                            WHERE t.ident = s.ident
                              AND (t.status IN ('done','cancelled')
                                   OR (COALESCE(t.graded_verdict_at,'') > s.ts
                                       AND (COALESCE(t.graded_verdict,'') <> ''
                                            OR COALESCE(t.merge_owner,'') <> ''))))
SQL
}

# `_grader_stale_spawns` — the spawns the bound just dropped, so the plan can SAY
# so. A SILENT EXPIRY IS THE SAME FAILURE WITH A DIFFERENT CLOCK: a lane that
# quietly stops counting a grade looks exactly like a lane that never had one,
# and the reason DIVE-4322 took three hours to find is that nothing on the board
# said a slot was gone. Same rows as the predicate above, with the age test
# INVERTED and everything else identical — a spawn that exited normally is not
# stale, it is finished, and must never appear here.
_grader_stale_spawns() {  # -> "<ident><US><spawn ts><US><age hours>" per dropped spawn
  local hours; hours=$(_grader_stale_hours)
  db "SELECT s.ident||x'1f'||s.ts||x'1f'||CAST(ROUND((julianday('now')-julianday(s.ts))*24,1) AS TEXT)
        FROM lifecycle_events s
       WHERE s.kind='task.grade.spawned'
         AND s.id = (SELECT MAX(x.id) FROM lifecycle_events x
                      WHERE x.ident = s.ident AND x.kind='task.grade.spawned')
         AND s.ts < datetime('now','-${hours} hours')
         AND NOT EXISTS (SELECT 1 FROM lifecycle_events d
                          WHERE d.ident=s.ident
                            AND d.kind IN ('task.done','task.rejected','task.graded')
                            AND d.id > s.id)
         AND NOT EXISTS (SELECT 1 FROM tasks t
                          WHERE t.ident = s.ident
                            AND (t.status IN ('done','cancelled')
                                 OR (COALESCE(t.graded_verdict_at,'') > s.ts
                                     AND (COALESCE(t.graded_verdict,'') <> ''
                                          OR COALESCE(t.merge_owner,'') <> ''))))
       ORDER BY s.ts;" 2>/dev/null || printf ''
}

# The in-flight predicate is `_grader_inflight_exits_sql`, shared with the
# account-wide cap below.
#
# One row per ident (`s.id = MAX(id) for that ident`) rather than DISTINCT,
# because here the rows must be GROUPED by seat: a re-spawn that moved an ident
# to another seat must count against the seat that holds it NOW, and a DISTINCT
# over both rows would count it against the seat that no longer does. Summed over
# seats this yields the same set of idents the cap counts.
_grader_seat_loads() {  # → "<seat><US><n>" per busy pool seat
  db "SELECT seat||x'1f'||COUNT(*) FROM (
        SELECT ${_GRADER_SEAT_EXPR} AS seat
          FROM lifecycle_events s
         WHERE s.kind='task.grade.spawned'
           AND s.id = (SELECT MAX(x.id) FROM lifecycle_events x
                        WHERE x.ident = s.ident AND x.kind='task.grade.spawned')
$(_grader_inflight_exits_sql)
      ) WHERE seat<>'' GROUP BY seat;" 2>/dev/null || printf ''
}

# The round-robin cursor. THE LEDGER IS THE POOL STATE — there is no second file
# to keep in sync, no state to lose on a restart, and the cursor is readable by
# anyone reading the spawn log. Ties are the common case once every seat is idle
# (all zero), and without a cursor a load-only sort is stable on pool order,
# i.e. first-fit again the moment the pool drains.
_grader_last_picked_seat() {
  db "SELECT ${_GRADER_SEAT_EXPR} FROM lifecycle_events s
       WHERE s.kind='task.grade.spawned' ORDER BY s.id DESC LIMIT 1;" 2>/dev/null || printf ''
}

# `_grader_pool_order <last-picked>` — the pool, least-loaded first.
#
# Reads `<seat>=<n>` lines on stdin (absent seat = 0) and prints the pool ordered
# by (in-flight ASC, distance after <last-picked> ASC). Load dominates so a seat
# at 0 is never passed over for one at 1; the cursor only breaks ties.
# A `<last-picked>` that is not in the pool (the seat was removed) rotates by
# nothing and the order is plain pool order — the safe degradation, not an error.
_grader_pool_order() {  # <last-picked-seat>   ["<seat>=<n>" lines on stdin]
  local last="${1:-}" s n i=0 rot=-1 total
  local -a seats=()
  local -A load=()
  while IFS='=' read -r s n; do
    [[ -n "$s" && "$n" =~ ^[0-9]+$ ]] && load["$s"]="$n"
  done
  for s in $_GRADER_POOL; do
    seats+=("$s"); [[ "$s" == "$last" ]] && rot=$i; i=$((i+1))
  done
  total=${#seats[@]}
  (( total )) || return 0
  local idx
  for ((i=0; i<total; i++)); do
    idx=$(( (rot + 1 + i) % total ))
    printf '%s %s %s\n' "${load[${seats[$idx]}]:-0}" "$i" "${seats[$idx]}"
  done | sort -k1,1n -k2,2n | awk '{print $3}'
}

# `5dive task grader-tick [--commit] [--cap=N] [--json]` — DIVE-4164, the lane.
#
# Consumes `task.grade.requested` and decides, per pending delivery, whether a
# grader may be spawned right now: is there a free slot under the cap, does the
# chosen pool seat's ACCOUNT have window headroom, and can that seat actually
# read the repo it would grade.
#
# ══ IT SHIPS DARK, AND THAT IS DELIBERATE ══
# Two independent locks, because this is the one verb in the row that starts
# real sessions on a live fleet:
#   1. DRY-RUN IS THE DEFAULT. Without --commit it prints the plan and spawns
#      nothing. The plan is the useful artifact on its own — it is how you see
#      what the lane WOULD do before letting it do anything.
#   2. THE POOL IS EMPTY BY DEFAULT. `_GRADER_POOL` ships unset, so even
#      `--commit` has nowhere to spawn and says so. Naming the pool is a
#      separate, deliberate act from enabling the lane.
# A customer-facing flow does not ship while its end-to-end arm is owed; this
# one's arm is owed, so the surface ships dark rather than waiting in a branch.
_GRADER_POOL="${_GRADER_POOL:-}"

# Return the current working owner when assigning this row to a pool seat would
# steal an active claim.  This is deliberately derived again in
# `_grader_spawn_session`: the tick's plan and the eventual fleet mutation are
# separated by several probes, and the owner may change between them.
_grader_non_pool_working_owner() {  # <ident>
  local ident="$1" row status owner seat
  [[ -n "$ident" ]] || return 1
  row=$(db "SELECT status||x'1f'||COALESCE(assignee,'') FROM tasks
             WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  status="${row%%$'\x1f'*}"
  owner="${row#*$'\x1f'}"
  [[ "$row" == *$'\x1f'* && "$status" == "in_progress" && -n "$owner" ]] || return 1
  for seat in $_GRADER_POOL; do
    [[ "$owner" == "$seat" ]] && return 1
  done
  printf '%s' "$owner"
}

_grader_row_is_in_progress() {  # <ident>
  [[ "$(db "SELECT status FROM tasks WHERE ident=$(sqlq "$1");" 2>/dev/null || printf '')" == "in_progress" ]]
}

# Close the durable request records whose answer is already known.  Dry-run
# remains read-only: the pending query below independently excludes these rows,
# while --commit appends the supersession receipt that prevents future readers
# from repeatedly re-deriving the same stale request.
_grader_supersede_resolved_requests() {
  local rows req_id ident
  rows=$(db "SELECT e.id||x'1f'||e.ident
               FROM lifecycle_events e
               JOIN tasks t ON t.ident=e.ident
              WHERE e.kind='task.grade.requested'
                AND NOT EXISTS (
                      SELECT 1 FROM lifecycle_events n
                       WHERE n.ident=e.ident AND n.id>e.id
                         AND n.kind IN ('task.grade.requested','task.grade.spawned',
                                        'task.grade.request.superseded'))
                AND (
                      t.status IN ('done','cancelled')
                   OR t.handoff_delivered_at IS NULL
                   OR t.handoff_rejected_at IS NOT NULL
                   OR (t.graded_verdict_at IS NOT NULL AND t.graded_verdict_at>=e.ts)
                   OR (t.graded_verdict_at IS NULL AND t.graded_at IS NOT NULL AND t.graded_at>=e.ts)
                )
              ORDER BY e.id;" 2>/dev/null || printf '')
  while IFS=$'\x1f' read -r req_id ident; do
    [[ "$req_id" =~ ^[0-9]+$ && -n "$ident" ]] || continue
    ledger_emit task.grade.request.superseded ident="$ident" actor="$(task_actor "")" \
      detail="grade request ${req_id} superseded by current row state" || true
  done <<<"$rows"
}

cmd_task_grader_tick() {
  local commit=0 cap="$_GRADER_MAX_PER_ACCOUNT" json="${JSON_MODE:-0}" only=""
  while (( $# )); do
    case "$1" in
      --commit) commit=1 ;;
      --cap=*)  cap="${1#--cap=}" ;;
      # --only=<ident>: act on ONE named delivery and leave the rest of the
      # queue untouched. This is not a convenience — it is the control that
      # makes the FIRST live run of this lane possible without collateral. The
      # tick is otherwise all-or-nothing over whatever is pending, so an
      # operator running the owed end-to-end arm (DIVE-4217) would have had to
      # let it also spawn graders onto other people's rows, whose verifier is
      # someone else. It filters the pending set; it releases no lock, so
      # --commit is still required to act and the pool must still be named.
      --only=*) only="${1#--only=}" ;;
      --json)   JSON_MODE=1; json=1 ;;
      *) fail "$E_USAGE" "usage: 5dive task grader-tick [--commit] [--cap=N] [--only=<ident>] [--json]" ;;
    esac; shift
  done
  [[ "$cap" =~ ^[0-9]+$ ]] || fail "$E_VALIDATION" "--cap takes a whole number"

  # Pending means the LATEST request is still a delivered, ungraded handoff.
  # A legacy grade may have no graded_verdict_at, so graded_at is its fallback.
  # >= is intentional: both clocks have one-second precision, and a verdict in
  # the request's second must fail closed rather than purchase a duplicate grade.
  (( commit )) && _grader_supersede_resolved_requests
  local pending
  pending=$(db "SELECT e.ident FROM lifecycle_events e
                  JOIN tasks t ON t.ident = e.ident
                 WHERE e.kind='task.grade.requested'
                   AND t.handoff_delivered_at IS NOT NULL
                   AND t.handoff_rejected_at IS NULL
                   AND NOT (t.graded_verdict_at IS NOT NULL AND t.graded_verdict_at >= e.ts)
                   AND NOT (t.graded_verdict_at IS NULL AND t.graded_at IS NOT NULL AND t.graded_at >= e.ts)
                   AND ((t.status='todo' AND (t.assignee IS NULL OR t.assignee=t.verifier))
                        OR (t.status='in_progress' AND COALESCE(t.assignee,'')<>''))
                   AND NOT EXISTS (SELECT 1 FROM lifecycle_events n
                                    WHERE n.ident=e.ident AND n.id > e.id
                                      AND n.kind IN ('task.grade.requested','task.grade.spawned',
                                                     'task.grade.request.superseded'))
                 ORDER BY e.id;" 2>/dev/null || printf '')

  local usage="" ; usage=$($_GRADER_USAGE_CMD 2>/dev/null || printf '')
  local n_pending=0 n_spawn=0 n_queue=0 n_refuse=0 n_fail=0 n_created=0 n_dark=0 plan=""
  # ══ DIVE-4322: IN FLIGHT MEANS GRADING, NOT "NOT YET CLOSED" ══
  #
  # This count was `spawned with no later task.done/task.rejected`, i.e. a grade
  # occupied a slot until the ROW closed. That is not when grading ends. A PASS on
  # a bound row is deliberately held open as graded->merge (DIVE-3330); the close
  # then waits on a human's merge and the grader's own `task done`, which is hours
  # to a day. The grader session, meanwhile, ended at the verdict and is gone —
  # the seat is idle and holding a slot it is not using.
  #
  # MEASURED 2026-09-11 by main: DIVE-4276 (spawned 07:50Z, PASS, its PR
  # CONFLICTING so nobody could merge it) and DIVE-4288 (spawned 10:30Z, PASS, PR
  # merged 12:32Z, close still owed) held both slots of the --cap=2 root cron for
  # three hours. 19 grades queued behind them and the pool seat's heartbeat read
  # "no todo — stay idle" every minute while five graded rows sat on its name.
  #
  # RAISING THE CAP WOULD NOT FIX IT, which is why the fix is here. The leak
  # scales with OWED MERGES, not with grading capacity: any cap is exhausted by
  # enough rows parked on a human's merge button.
  #
  # THE EXIT SET IS THE VERDICT, and it has two independent readings:
  #
  #   (a) `task.graded` — emitted by `task verify` the moment a verdict is stored
  #       (src/task/loops.sh), for both verdicts and for the raw-UPDATE auto-close
  #       that emits no task.done at all. This is the primary and the precise one:
  #       it is ordered by ledger id against THIS spawn, so a re-grade after a
  #       reject re-occupies a slot exactly as it should.
  #
  #   (b) the row's own structural state, as a belt for every row graded BEFORE
  #       (a) ships — an upgrade cannot retro-emit a ledger row, and without this
  #       the lane would stay frozen by today's parked rows until they closed.
  #       `graded_verdict_at` (the verdict's own clock, DIVE-3430) and a closed
  #       status cover it; `merge_owner` is the column the graded->merge render
  #       reads and is carried here for the same reason.
  #
  # (b) IS PINNED TO THIS SPAWN, NOT READ BARE, and that is the whole care in it.
  # A bare `merge_owner IS NOT NULL` fails OPEN on the one shape that matters: a
  # row that PASSED, was later rejected and re-delivered, and now has a grader
  # genuinely working on it while a stale merge_owner from the first pass says
  # otherwise. Requiring the verdict clock to be strictly LATER than the spawn
  # makes the belt say the same thing (a) says — "a verdict landed after we
  # started this grade" — rather than "a verdict landed at some point".
  # The count is COUNT(DISTINCT s.ident), not COUNT(*): DIVE-4281 de-dupes a
  # double spawn on one ident so two ledger rows cannot eat two slots. Both
  # rows guard this one expression — keep the DISTINCT and the exits together.
  #
  # DIVE-4418: the exit set is no longer written out here. It lives in
  # `_grader_inflight_exits_sql` — the ONE place — because the per-seat load
  # query above reads the same set, and a bound added to one copy and not the
  # other would make the cap and the spread disagree about which grades exist.
  # That fragment also carries the staleness bound; read its note for why six
  # hours and why it cannot cut a live grader off.
  local inflight; inflight=$(db "SELECT COUNT(DISTINCT s.ident) FROM lifecycle_events s
                                  WHERE s.kind='task.grade.spawned'
$(_grader_inflight_exits_sql)
                                ;" 2>/dev/null || printf 0)
  [[ "$inflight" =~ ^[0-9]+$ ]] || inflight=0

  # ══ DIVE-4417: IN PROCESS MODE THE LEDGER IS NOT THE TRUTH ABOUT CAPACITY ══
  # Everything above reconstructs "is this grade still running?" from rows the
  # grade may never write, which is why it needed DIVE-4322's exit set and
  # DIVE-4418's six-hour bound on top. A process answers directly: it is in the
  # process table or it is not. Read here, once per tick, and used for both the
  # cap and the log line DO (6) asks for — in session mode it is reported and
  # binds nothing, because there are no one-shots to find.
  # GUARDED, not read unconditionally: in session mode there are no one-shots to
  # find, and calling into grader_process.sh from the default path would make
  # this file's own harness depend on a file it does not source.
  # ══ DIVE-4496: THE TICK THAT CREATES A CLONE ALSO SWEEPS CLONES ══
  #
  # Same tick, not a second cron line, because the two readings must not be able
  # to disagree: the cap below counts LIVE CLONE SEATS, and a clone whose grade is
  # over is not a live grade — if the sweep ran on its own schedule, the cap would
  # spend part of every tick counting seats that were already finished.
  #
  # BEFORE the count, never after. A tick that removed three finished clones and
  # then planned against the number it read BEFORE removing them would refuse
  # three deliveries it had just made room for. The sweep REMOVES and
  # `_grader_process_count` READS; keeping those as two functions is what lets the
  # count be the one source of truth for the cap in both modes.
  #
  # It runs in DRY-RUN TOO and reports without acting, for the same reason the
  # stale bound is announced rather than silent: the plan must say which seats this
  # tick would take away.
  local n_swept=0
  if _grader_process_mode; then
    n_swept=$(_grader_clone_sweep $( ((commit)) && printf '%s' --commit ) 2>/dev/null || printf 0)
    [[ "$n_swept" =~ ^[0-9]+$ ]] || n_swept=0
  fi
  local n_procs=0
  if _grader_process_mode; then
    n_procs=$(_grader_process_count)
    [[ "$n_procs" =~ ^[0-9]+$ ]] || n_procs=0
    # The trailing count means two different things by mode and must SAY which.
    # Committed, the sweep has already removed and `n_procs` is what is left
    # grading. In dry-run nothing was removed, so the same number is everything
    # still PRESENT — reporting that as "still grading" would double-count the
    # clones the line just said it would take away.
    (( n_swept )) && plan+="sweep   ${n_swept} grader clone(s) $( ((commit)) \
      && printf 'removed; %d still grading' "$n_procs" \
      || printf 'would be removed (dry-run); %d clone seat(s) present' "$n_procs" )"$'\n'
  fi
  # `if`, NEVER `pred && assign`: under the bundle's `set -euo pipefail` a false
  # predicate at statement position is a non-zero simple command and errexit kills
  # the tick — i.e. the SESSION-mode path, the one that must not change at all.
  if _grader_process_mode; then inflight="$n_procs"; fi
  # The per-seat bound differs by mode (1 is correct for a serial seat, wrong for
  # parallel processes), so it is resolved ONCE and both comparison sites read
  # this local — two sites reading the raw constant is how a mode half-applies.
  local _gp_seatcap; _gp_seatcap=$(_grader_max_per_seat)
  [[ "$_gp_seatcap" =~ ^[0-9]+$ ]] || _gp_seatcap=1

  # ══ THE DROP IS ANNOUNCED, NEVER SILENT ══
  # Read BEFORE the pending loop and printed at the TOP of the plan, so a reader
  # who is trying to explain why the lane had capacity (or why a grade never came
  # back) sees the reclaimed slots before the decisions they paid for. Read-only
  # in every mode — this is the dry-run's answer too, since the bound changes what
  # the plan SAYS and a plan that hid it would be the wrong plan.
  local n_stale=0 _st_ident _st_ts _st_age stale_h
  stale_h=$(_grader_stale_hours)
  while IFS=$'\x1f' read -r _st_ident _st_ts _st_age; do
    [[ -n "$_st_ident" ]] || continue
    n_stale=$((n_stale+1))
    plan+="stale   $_st_ident  (spawned $_st_ts, ${_st_age}h ago — past the ${stale_h}h bound, no longer counted in flight; its slot is back)"$'\n'
  done < <(_grader_stale_spawns)

  # DIVE-4410: the same reading, split by seat, plus the round-robin cursor.
  # Read ONCE per tick and then maintained in memory as this pass spawns, so two
  # rows in one tick cannot both be told the same seat is free.
  local -A _gp_load=()
  local _gp_seat _gp_n
  while IFS=$'\x1f' read -r _gp_seat _gp_n; do
    [[ -n "$_gp_seat" && "$_gp_n" =~ ^[0-9]+$ ]] || continue
    _gp_load["$_gp_seat"]="$_gp_n"
  done < <(_grader_load_source)
  local _gp_last; _gp_last=$(_grader_last_picked_seat)

  local ident
  while IFS= read -r ident; do
    [[ -n "$ident" ]] || continue
    [[ -z "$only" || "$ident" == "$only" ]] || continue
    local working_owner=""
    working_owner=$(_grader_non_pool_working_owner "$ident" 2>/dev/null || printf '')
    if [[ -n "$working_owner" ]]; then
      n_refuse=$((n_refuse+1))
      plan+="skip    $ident  (owner is $working_owner, not a pool seat)"$'\n'
      if (( commit )); then
        local _owner_req
        _owner_req=$(db "SELECT id FROM lifecycle_events
                          WHERE ident=$(sqlq "$ident") AND kind='task.grade.requested'
                          ORDER BY id DESC LIMIT 1;" 2>/dev/null || printf '')
        [[ "$_owner_req" =~ ^[0-9]+$ ]] && \
          ledger_emit task.grade.request.superseded ident="$ident" actor="$(task_actor "")" \
            detail="grade request ${_owner_req} superseded: owner is ${working_owner}, not a pool seat" || true
      fi
      continue
    fi
    # A pool seat already holding the claim IS the grader in flight; asking the
    # lane for a second session would duplicate work even though no verdict has
    # landed yet. Non-pool claims took the explicit safety line above.
    _grader_row_is_in_progress "$ident" && continue
    n_pending=$((n_pending+1))
    # DIVE-4251: THE POLICY IS CHECKED FIRST, before the cap, the meter and the
    # credential probe — a row the customer's box grants no grader must cost this
    # lane nothing at all, and must never appear in the plan as merely "queued"
    # (a queue is a promise to spawn later; a declined row is not).
    #
    # THIS IS DEFENCE IN DEPTH, NOT THE ONLY CONTROL, and saying so matters for
    # anyone reading it later: `_task_route_to_verifier`'s callers already decline
    # to EMIT a `task.grade.requested` for such a row, so on a correct box this
    # branch never fires. It exists because policy can change AFTER a request was
    # emitted — a customer flipping to `never` must stop the graders that are
    # already queued, not just the next ones — and because a lane that re-derives
    # the answer cannot be desynchronised from the emitter by a future edit.
    local _gp_id; _gp_id=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
    if [[ -n "$_gp_id" ]] && ! _task_verify_grants "$_gp_id"; then
      n_refuse=$((n_refuse+1))
      plan+="skip    $ident  (verification policy grants this row no grader — 5dive config verify=)"$'\n'; continue
    fi
    # DIVE-4324: a row filed with a PINNED standing reviewer who is not in this
    # pool is not this lane's row. `seat:<agent>` means "that agent grades it in
    # its own session"; routing has already handed the row to them, so spawning a
    # throwaway grader on a pool seat here would buy a SECOND session for a grade
    # that was deliberately bought as a first.
    #
    # SCOPED TO NON-POOL SEATS ON PURPOSE, and this is the load-bearing half: the
    # fleet's usual pins (quinn, main2) ARE the pool, and for those the pool's
    # fresh session IS how that seat grades. Skipping those would strand every
    # pinned row on this box. So the skip fires only where the two genuinely
    # disagree — a pin naming somebody the pool cannot spawn.
    local _gp_rm="" _gp_maker=""
    [[ -n "$_gp_id" ]] && _gp_rm=$(db "SELECT COALESCE(review_mode,'') FROM tasks WHERE id=${_gp_id};" 2>/dev/null || printf '')
    # DIVE-4521: the maker, for the lineage gate in the seat pick below. Read
    # HERE with the other per-row columns rather than inside the pool loop — the
    # loop runs once per pool seat and a DB round trip per seat to re-read one
    # unchanging column is a cost with no answer attached.
    [[ -n "$_gp_id" ]] && _gp_maker=$(db "SELECT COALESCE(maker_agent,'') FROM tasks WHERE id=${_gp_id};" 2>/dev/null || printf '')
    if [[ "$_gp_rm" == seat:* ]]; then
      local _gp_pin="${_gp_rm#seat:}" _gp_in_pool=0 _gp_s
      for _gp_s in $_GRADER_POOL; do [[ "$_gp_s" == "$_gp_pin" ]] && { _gp_in_pool=1; break; }; done
      if (( ! _gp_in_pool )); then
        n_refuse=$((n_refuse+1))
        plan+="skip    $ident  (review=$_gp_rm — pinned standing reviewer, not a pool seat; $_gp_pin grades it in its own session)"$'\n'; continue
      fi
    fi
    # THE CAP IS CHECKED BEFORE THE SEAT, so a full lane costs no meter reads and
    # no credential probes — a queued delivery must be cheap or the tick becomes
    # the burn it was meant to bound.
    if (( inflight >= cap )); then
      n_queue=$((n_queue+1)); plan+="queue   $ident  (cap $cap reached; $inflight in flight)"$'\n'; continue
    fi
    # DIVE-4496: the per-tick CREATE budget, checked beside the cap and reported
    # as its own reason. A clone create is synchronous wall time inside a tick
    # whose cron carries no flock, so this is the bound that keeps a tick from
    # outrunning its own period — it is not the cap, and a reader must be able to
    # tell "the lane is full" from "this tick has spent its creates".
    if _grader_process_mode && (( n_created >= $(_grader_clone_create_budget) )); then
      n_queue=$((n_queue+1))
      plan+="queue   $ident  (this tick's clone-create budget of $(_grader_clone_create_budget) is spent; the next tick creates the next one)"$'\n'; continue
    fi
    if [[ -z "$_GRADER_POOL" ]]; then
      n_refuse=$((n_refuse+1))
      plan+="dark    $ident  (no pool configured — set _GRADER_POOL to enable)"$'\n'; continue
    fi
    # DIVE-4410: LEAST-LOADED pool seat whose ACCOUNT has headroom — not the
    # first one. The three gates are independent and are applied in cost order:
    # per-seat load (free, already read), then the account floor, then the
    # credential probe (a sudo + a GitHub read).
    local seat="" chosen="" why="" busy="" pairs="" loadstr="" samelin=""
    # The busy note is built over the WHOLE pool, not accumulated as the pick
    # loop walks it: the loop stops at the first admitted seat, so a seat that
    # was skipped for being busy is often never visited at all and the line
    # would silently omit the very seat that explains the choice.
    for seat in $_GRADER_POOL; do
      pairs+="${seat}=${_gp_load[$seat]:-0}"$'\n'
      loadstr+="${loadstr:+ }${seat}=${_gp_load[$seat]:-0}"
      (( ${_gp_load[$seat]:-0} >= _gp_seatcap )) && busy+="${seat} busy:${_gp_load[$seat]:-0}; "
      # DIVE-4521: same-origin refusals are collected over the WHOLE pool here
      # for the reason the busy note is — `why` is REPLACED by the admitted
      # seat's verdict on the pick, so a lineage refusal recorded inside that
      # loop vanishes from the very line that reports the spawn it caused. A
      # grade routed away from the maker's own lineage must SAY so on the spawn
      # line; otherwise the only trace of the guard working is the absence of a
      # seat name nobody was looking for.
      _grader_same_origin "$seat" "$_gp_maker" && samelin+="${seat} same-origin:${_gp_maker}; "
    done
    local order; order=$(printf '%s' "$pairs" | _grader_pool_order "$_gp_last")
    for seat in $order; do
      # A seat already grading is not capacity. `_grader_spawn_session` is
      # assign+wake on a live seat and a seat runs one session at a time, so a
      # second grade here is a queue, not a parallel grader.
      (( ${_gp_load[$seat]:-0} < _gp_seatcap )) || continue
      # DIVE-4521 / DIVE-4514: LINEAGE BEFORE THE METER. A same-origin seat is
      # refused whatever its headroom, and it is checked first because it is a
      # string comparison — spending a usage read and a GitHub probe on a seat
      # that can never be admitted is the cost this ordering exists to avoid.
      # The CLONE inherits the pool seat's origin (it is minted from it), so
      # guarding the seat guards the clone the spawn below would create.
      if _grader_same_origin "$seat" "$_gp_maker"; then
        why="${why}${seat}: same origin as maker ${_gp_maker} ($(_grader_seat_origin "$seat")) — a clone cannot grade its origin's work; "
        continue
      fi
      local acct; acct=$(printf '%s' "$usage" | _grader_account_of "$seat")
      # `|| rc=$?`, NOT `; rc=$?`, and the difference is the whole refusal half
      # of this lane. `_grader_window_ok` is dual-channel BY DESIGN — verdict on
      # stdout, DECISION in the exit status (0 admit, 1 no measurement, 2 over
      # floor) — so a refusing seat returns non-zero as its ANSWER, not as an
      # error. `verdict=$(...)` is a simple command and `rc=$?` is a separate
      # one: under the bundle's `set -euo pipefail` (src/header.sh) the shell
      # aborts ON THE ASSIGNMENT, `rc` is never assigned, the second pool seat is
      # never tried and `queue (no seat with headroom — …)` can never print. The
      # caller saw only `5dive task exited 1 without reporting a reason`.
      # Measured on 0.35.1, 2026-09-12 (DIVE-4380); `||` is what suppresses
      # errexit here, and `rc=0` must be set first because `||` leaves it
      # untouched on the admit path. A `local verdict=$(...)` would mask it the
      # other way round (the `local` builtin's own status wins) — the
      # neighbouring trap, not the fix.
      # community/wiki/a-refusal-verdict-captured-into-a-variable-dies-under-set-e.md
      local verdict rc=0
      verdict=$(printf '%s' "$usage" | _grader_window_ok "$acct") || rc=$?
      if (( rc == 0 )); then
        # Guardrail 2: never a grader without read access to the repo it grades.
        # Checked AFTER the floor because it is the more expensive probe.
        if _grader_can_read "$seat" "$ident"; then chosen="$seat"; why="$verdict"; break; fi
        why="${why}${seat}: has headroom but cannot read the delivery ref; "
        continue
      fi
      why="${why}${seat}: ${verdict}; "
    done
    if [[ -z "$chosen" ]]; then
      n_queue=$((n_queue+1))
      # The busy seats are named in the SAME line as the headroom refusals, so
      # "queued because the pool is working" and "queued because the meter said
      # no" are one read apart rather than two log files apart.
      # The headline names the binding constraint rather than one fixed phrase:
      # "no seat with headroom" is the floor/credential refusal (and is the exact
      # park line the errexit arm grades); a pool seat sitting at its per-seat cap
      # is a different fact and must not be reported as a meter refusal.
      # DIVE-4575: A LANE RUNNING DARK IS NOT A LANE THROTTLING, and in a log
      # line that only names the refusals they read the same. The difference is
      # the whole of that row: a floor refusal clears by itself at the window's
      # reset, a blind one never does — nothing about waiting makes an unwritten
      # statusline cache appear. Nine hours of `no seat with headroom` were read
      # as a busy account. The headline is deliberately NOT changed (the errexit
      # park arm grades it verbatim); the dark verdict is appended, counted, and
      # carries the operator's next move.
      local dark_note=""
      if [[ "$why" == *"failing closed"* ]]; then
        n_dark=$((n_dark+1))
        # DIVE-4585: the snapshot now has a scheduled publisher (the heartbeat
        # tick republishes it every couple of minutes — the sweep clause in
        # src/cmd_heartbeat.sh owns the cadence), so a reading that is absent
        # HERE is no longer the expected steady state it was when this note was
        # written — it means no seat bound to the account has ever rendered a
        # statusline, or the tick is not running. Say both, in that order.
        #
        # DIVE-4585 iteration 2: the cadence is deliberately NOT named here, in
        # prose OR in the message. `lazy_tokens` matches identifiers over the
        # whole file including comments, so one mention of a top-level global of
        # another payload module puts a __MODDEPS edge on this one — and this
        # module is in every verb's closure, so the edge lands on `whoami`.
        # Cite the owning file, never the constant.
        dark_note=" [POOL DARK: an account with no measured reading — this refusal does not clear at any window reset. The snapshot is republished by the heartbeat tick every couple of minutes (DIVE-4585), so check that the tick is running ('5dive heartbeat ls', /var/log/5dive-heartbeat.log) before anything else; if it is, no seat bound to this account has ever rendered a statusline — start one once, or run 'sudo -n 5dive account usage' for an immediate publish]"
      fi
      plan+="queue   $ident  ($( [[ -n "$busy" ]] && printf 'no free seat' || printf 'no seat with headroom' ) — ${busy}${why})${dark_note}"$'\n'; continue
    fi
    n_spawn=$((n_spawn+1)); inflight=$((inflight+1))
    # DIVE-4410: maintain the reading in memory. Without this the second row in
    # the same tick reads the seat it just filled as idle — which is precisely
    # the 4-onto-quinn tick this row was filed on.
    _gp_load["$chosen"]=$(( ${_gp_load[$chosen]:-0} + 1 ))
    _gp_last="$chosen"
    # DIVE-4417 (6): the live process count per tick, on the spawn line, beside
    # the mode that produced it — the one number that says whether the lane is
    # actually running graders in parallel or is a queue reporting spawn=N.
    plan+="spawn   $ident  -> $chosen  (in-flight ${loadstr}; ${busy}${samelin}${why}mode=$(_grader_spawn_mode) clones=${n_procs})"$'\n'
    if _grader_process_mode; then n_procs=$((n_procs+1)); fi
    if (( commit )); then
      # THE ONLY LINE THAT STARTS ANYTHING, and it records the intent to the
      # ledger BEFORE acting so a crash between the two leaves a spawn we can
      # see rather than one we cannot account for.
      # The session id is minted BEFORE the ledger row so the row can name it:
      # `run ls` and the spawn log must agree on which of quinn's concurrent
      # grades this is, and a detail written without it is unattributable
      # forever (lifecycle_events is append-only).
      #
      # The `grader session on <seat>` prefix is LOAD-BEARING and is kept
      # verbatim in both modes — `_GRADER_SEAT_EXPR` reads the seat out of this
      # string at a fixed offset, so the suffix may grow and the prefix may not.
      local _gp_sid=""
      if _grader_process_mode; then
        # ══ DIVE-4417 iteration 2: IN PROCESS MODE THE LEDGER ROW COMES AFTER ══
        #
        # "Record the intent before acting" is right in SESSION mode and wrong
        # here, and the asymmetry is the whole point. There, a wake that fails
        # leaves a visibly idle seat with a unit, a pane and a liveness rail
        # watching it, so a spawn row with nothing behind it is noticed. A
        # one-shot has none of those (see grader_process.sh's header), so the
        # same row written ahead of a failed launch is permanent: the pending
        # query at :674 excludes any ident carrying a later
        # `task.grade.spawned`, and the delivery would never be re-picked by
        # any tick. quinn measured exactly that on iteration 1.
        #
        # So in this mode the row is the RECEIPT of a started process, not the
        # intent to start one. The window it opens instead — a crash between
        # the launch and this emit — is the safe one: the row stays pending and
        # the next tick re-picks it, which is a duplicate grade at worst rather
        # than a delivery nobody grades. `_grader_process_spawn` owns the other
        # half: it probes the runas before it assigns, confirms the process is
        # alive before it returns 0, and unwinds the assign if it is not.
        _gp_sid=$(_grader_process_session_id "$chosen")
        if _grader_process_spawn "$chosen" "$ident" "$_gp_sid"; then
          n_created=$((n_created+1))
          ledger_emit task.grade.spawned ident="$ident" actor="$(task_actor "")" \
            detail="grader session on ${chosen}${_gp_sid:+ (process ${_gp_sid})}" || true
        else
          warn "$ident: grader process on $chosen failed"
          # The tick's own arithmetic is corrected too. A summary reading
          # spawn=1 for a launch that never started is the same untruth as the
          # ledger row, one line further down, and the slot it reserved must go
          # back or the rest of this tick plans against capacity it never spent.
          n_spawn=$((n_spawn-1)); n_fail=$((n_fail+1))
          inflight=$((inflight-1)); n_procs=$((n_procs-1))
          _gp_load["$chosen"]=$(( ${_gp_load[$chosen]:-1} - 1 ))
          plan+="failed  $ident  -> $chosen  (launch did not start; assign reverted, row stays pending)"$'\n'
        fi
      else
        ledger_emit task.grade.spawned ident="$ident" actor="$(task_actor "")" \
          detail="grader session on ${chosen}" || true
        _grader_spawn_session "$chosen" "$ident" || warn "$ident: spawn on $chosen failed"
      fi
    fi
  done <<<"$pending"

  if (( json )); then
    # `dark` is the POOL-IS-UNCONFIGURED count and keeps its meaning. DIVE-4575's
    # `blindAccount` is a different fact with a different fix — the pool IS named
    # and is refusing because nothing measured its account — so it gets its own
    # field rather than being folded into a count readers already interpret.
    printf '{"pending":%d,"spawned":%d,"queued":%d,"dark":%d,"blindAccount":%d,"stale":%d,"staleHours":%d,"cap":%d,"commit":%s,"pool":"%s","mode":"%s","clones":%d,"seatCap":%d,"failed":%d,"swept":%d}\n' \
      "$n_pending" "$n_spawn" "$n_queue" "$n_refuse" "$n_dark" "$n_stale" "$stale_h" "$cap" \
      "$( ((commit)) && printf true || printf false )" "$_GRADER_POOL" \
      "$(_grader_spawn_mode)" "$n_procs" "$_gp_seatcap" "$n_fail" "$n_swept"
    return 0
  fi
  printf '%s' "$plan"
  # DIVE-4496: `clones=` and `swept=` are on the tick line because the row asks
  # for them there — a clone lane whose seat churn is only visible in the journal
  # is a lane nobody can audit from the log the cron already writes. `clones=`
  # REPLACES DIVE-4417's `procs=` rather than joining it: they are one reading
  # under two names now that a "process" is a seat, and two names for one number
  # in a log line is how a reader concludes they measure different things.
  printf 'pending=%d spawn=%d queue=%d dark=%d blindacct=%d stale=%d cap=%d mode=%s clones=%d swept=%d seatcap=%d failed=%d %s\n' \
    "$n_pending" "$n_spawn" "$n_queue" "$n_refuse" "$n_dark" "$n_stale" "$cap" \
    "$(_grader_spawn_mode)" "$n_procs" "$n_swept" "$_gp_seatcap" "$n_fail" \
    "$( ((commit)) && printf '(COMMITTED)' || printf '(dry-run — pass --commit to act)' )"
}

# `_grader_spawn_session <seat> <ident>` — start one grading session.
#
# A SESSION ON A POOL SEAT, not a new seat: the isolation this design needs is
# "no maker context, no previous-grade context", and a cold wake already IS an
# empty session window. A seat costs a unix account plus a runtime provision
# (~50s measured) plus a sudoers render; a wake is seconds.
#
# Deliberately the ONLY function here that touches the fleet, so there is exactly
# one place to audit and one place to stub in a harness.
_grader_spawn_session() {  # <seat> <ident>
  local seat="$1" ident="$2"
  [[ -n "$seat" && -n "$ident" ]] || return 1
  local working_owner=""
  working_owner=$(_grader_non_pool_working_owner "$ident" 2>/dev/null || printf '')
  if [[ -n "$working_owner" ]]; then
    warn "$ident: skip — owner is $working_owner, not a pool seat"
    return 2
  fi
  5dive task assign "$ident" "$seat" >/dev/null 2>&1 || return 1
  # DIVE-4295: guard the wake so a spooled copy is dropped rather than typed if
  # the row closes or moves to another seat while it waits. `assignee_owns`, not
  # a verifier clause: this seat is a grading session on a POOL seat, which is
  # not the row's `verifier` column. Exported through the environment because
  # this call crosses a process boundary into the `5dive` CLI.
  #
  # KNOWN LIMIT, stated rather than left to be discovered: on a SCOPED-sudo
  # caller `cmd_send` re-execs through `sudo -n ... agent _deliver`
  # (cmd_agent_runtime.sh:2421) and sudo SCRUBS the environment, so on that path
  # this variable does not arrive and the wake spools UNGUARDED. It fails in the
  # safe direction -- unguarded means delivered, which is exactly today's
  # behaviour, never a new drop -- and the two rails this ticket was filed on
  # (_hb_stall_sweep (a) and (a4)) call cmd_send IN-PROCESS and are unaffected.
  # Closing it properly needs an env_keep entry or a new `_deliver` argument, and
  # a sudoers wildcard is not something to widen inside this change.
  _A2A_GUARD="task:${ident}:${seat}:assignee_owns" \
  # DIVE-4576: the same method clause the clone lane sends — one definition, in
  # src/task/grader_process.sh. Guarded with `declare -F` because this file is
  # sourced before that one and a harness may load either alone; a missing clause
  # degrades to the pre-DIVE-4576 wording rather than failing a spawn.
  local _gm=""; declare -F _grader_grade_method_clause >/dev/null 2>&1 && _gm=" $(_grader_grade_method_clause "$ident")"
  5dive agent send "$seat" "Grade delivered task ${ident} from its bounded packet, then run 5dive task done or 5dive task reject. Checkpoint each verified arm to the row as you go.${_gm}" >/dev/null 2>&1
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
_PACE_FLOOR_5H="${FIVE_PACE_5H:-85}"
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
    if (( age >= 0 && age < _GRADER_READING_MAX_AGE )); then
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
#   * the READING's own measurement time (`asOf`) within `_GRADER_READING_MAX_AGE`
#     — not the age of the file that quotes it;
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
  (( now >= asof && now - asof <= _GRADER_READING_MAX_AGE )) || return 0
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
_pace_band_7d() {  # <account> [<now-epoch>]  [<usage-json-on-stdin>]
  local acct="$1" now="${2:-$(date +%s)}" json seven="" resets="" days_left src="" pair=""
  local lb_pair="" lb_seven="" lb_resets=""
  local pw=0 unmet_band unmet_why
  if [[ -z "$acct" ]]; then
    # No account named is not a measurement, and it must not read as headroom.
    printf 'pace: no account named — holding at the soft floor rather than reading it as 0%%\n'
    [[ "$_PACE_BLIND" == "refuse" ]] && return 1
    return 2
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
  # `FIVE_PACE_BLIND=soft` (the default) falls to the soft floor, so a bound may
  # move it to hard (tighter) or leave it at soft (equal). `FIVE_PACE_BLIND=refuse`
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
      printf 'pace: %s has no weekly reading — no account reading measured within %ss and %s returned nothing; blind meter, policy=%s (never 0%%)\n' \
             "$acct" "$_GRADER_READING_MAX_AGE" "$_PACE_USAGE_CMD" "$_PACE_BLIND"
    else
      printf 'pace: %s has no weekly reading (null) — no account reading measured within %ss and no seat of the account carries one; blind meter, policy=%s\n' \
             "$acct" "$_GRADER_READING_MAX_AGE" "$_PACE_BLIND"
    fi
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
