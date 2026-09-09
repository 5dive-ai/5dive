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
  local acct="$1" json five seven
  if [[ -z "$acct" ]]; then
    printf 'refuse: no account named — a floor with no account is not a measurement\n'; return 1
  fi
  json=$(cat)
  if [[ -z "$json" ]]; then
    printf 'refuse: %s returned nothing — no meter, no spawn\n' "$_GRADER_USAGE_CMD"; return 1
  fi
  five=$(printf '%s' "$json"  | _grader_pct "$acct" fiveHourPct)
  seven=$(printf '%s' "$json" | _grader_pct "$acct" sevenDayPct)

  # Emptiness first, always, and each side separately so the reason names which
  # meter was blind rather than blaming "the meter".
  if [[ -z "$five" ]]; then
    printf 'refuse: %s has no 5h reading (null) — failing closed, not assuming 0%%\n' "$acct"; return 1
  fi
  if [[ -z "$seven" ]]; then
    printf 'refuse: %s has no weekly reading (null) — failing closed, not assuming 0%%\n' "$acct"; return 1
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
  printf 'ok: %s at 5h=%s%% 7d=%s%%\n' "$acct" "$five" "$seven"; return 0
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
