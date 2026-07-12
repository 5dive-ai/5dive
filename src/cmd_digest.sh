# cmd_digest — deterministic per-fleet standup digest (DIVE-544 Tier 1).
#
# Builds the overnight recap from data every fleet already has: the task queue
# (done in the last 24h / in-progress / blocked gates), 5dive usage (token burn
# + share-of-limit), and heartbeat health. ZERO agent reasoning, ZERO tokens —
# pure CLI aggregation, so it works on every fleet incl. a solo-agent box and
# never depends on a CEO/coordinator agent. `--json` for machines; default is a
# Telegram-ready text block.
#
# Read-only (same posture as `usage`): reads the shared task DB + the usage
# scan; no registry mutation, no lock, no audit.
#
# Usage:
#   5dive digest            # human/Telegram-ready text for the last 24h
#   5dive digest --json     # structured { window, done, inProgress, blocked, usage, health }
#   5dive digest --7d       # widen the window to 7 days

# Per-box digest preference, in the shared state dir so it SURVIVES CLI updates
# (install.sh seeds it OFF and never clobbers it). One digest per fleet → one
# file. Shape: {"enabled":bool,"hour":0-23,"lastSent":"YYYY-MM-DD"}. DEFAULT OFF
# (DIVE-544, Mark): customers opt in only via the telegram /digest command.
_digest_pref_file() { echo "${STATE_DIR}/digest.json"; }
_digest_pref_enabled() {
  local f; f="$(_digest_pref_file)"
  [ -r "$f" ] && [ "$(jq -r '.enabled // false' "$f" 2>/dev/null)" = "true" ]
}
_digest_pref_hour() { jq -r '.hour // 7' "$(_digest_pref_file)" 2>/dev/null || echo 7; }

# _digest_onoff <on|off|status> [--at=HH] — write/read the per-box pref. Backs the
# telegram /digest command (DIVE-624). `on` enables at the given (or stored, or
# default 7) hour; `off` disables; `status` reports.
_digest_onoff() {
  local sub="$1"; shift || true
  local f hour=""; f="$(_digest_pref_file)"
  while [ $# -gt 0 ]; do case "$1" in --at=*) hour="${1#*=}" ;; *) fail "$E_USAGE" "digest $sub: unknown arg: $1" ;; esac; shift; done
  mkdir -p "$(dirname "$f")"
  local cur; cur="$(cat "$f" 2>/dev/null || true)"; [ -n "$cur" ] || cur='{"enabled":false,"hour":7}'
  case "$sub" in
    on)
      [ -n "$hour" ] || hour="$(jq -r '.hour // 7' <<<"$cur")"
      case "$hour" in ''|*[!0-9]*) fail "$E_USAGE" "digest on: --at must be an hour 0-23" ;; esac
      { [ "$hour" -ge 0 ] && [ "$hour" -le 23 ]; } || fail "$E_USAGE" "digest on: --at must be 0-23"
      jq --argjson h "$hour" '.enabled=true | .hour=$h' <<<"$cur" > "$f.tmp" && mv "$f.tmp" "$f"
      echo "digest: ON — daily ${hour}:00 box-local"
      ;;
    off)
      jq '.enabled=false' <<<"$cur" > "$f.tmp" && mv "$f.tmp" "$f"
      echo "digest: OFF"
      ;;
    status)
      if [ "${JSON_MODE:-0}" = 1 ]; then
        jq -c '{enabled:(.enabled//false),hour:(.hour//7),lastSent:(.lastSent//null)}' <<<"$cur"
      else
        jq -r 'if (.enabled//false) then "digest: ON — daily \(.hour//7):00 box-local" else "digest: OFF" end' <<<"$cur"
      fi
      ;;
    *) fail "$E_USAGE" "digest: unknown subcommand: $sub" ;;
  esac
}

# _digest_tick — hourly cron driver (run as root from /etc/cron.d/5dive-digest).
# Gates on the per-box pref: only fires when enabled, at the configured hour,
# at most once per day. When it fires it delivers ONE per-fleet digest to the
# box's primary paired chat — walks the registry, finds the first
# telegram-enabled agent (a connector token exists), and re-execs `digest --send`
# AS that agent so the owner-channel resolution applies (solo boxes: "first" ==
# the agent). Best-effort: always returns 0 so a miss never spams cron mail.
_digest_tick() {
  _digest_pref_enabled || return 0                       # OFF by default
  [ "$(date +%-H)" = "$(_digest_pref_hour)" ] || return 0  # not the configured hour
  local f today last; f="$(_digest_pref_file)"; today="$(date +%F)"
  last="$(jq -r '.lastSent // ""' "$f" 2>/dev/null)" || last=""
  [ "$last" = "$today" ] && return 0                     # already sent today

  local self; self="$(command -v 5dive 2>/dev/null || echo "$0")"
  local names name sent=0
  names=$(jq -r '.agents | keys[]' "$REGISTRY" 2>/dev/null) || names=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -r "${CONNECTORS_DIR}/telegram-${name}.env" ] || continue
    if sudo -u "agent-${name}" "$self" digest --send >/dev/null 2>&1; then
      echo "digest tick: delivered via agent ${name}" >&2
      sent=1; break
    fi
  done <<<"$names"
  if [ "$sent" = 1 ]; then
    jq --arg d "$today" '.lastSent=$d' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  else
    echo "digest tick: enabled but no telegram-enabled agent to deliver via" >&2
  fi
  return 0
}

cmd_digest() {
  case "${1:-}" in
    tick)          shift; _digest_tick "$@"; return 0 ;;
    on|off|status) local _s="$1"; shift; _digest_onoff "$_s" "$@"; return 0 ;;
  esac
  # `--json` is consumed globally by main() (sets JSON_MODE); read that flag here.
  local as_json="${JSON_MODE:-0}" window=86400 do_send=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --7d)    window=604800 ;;
      --24h|--day) window=86400 ;;
      --send)  do_send=1 ;;
      -h|--help)
        echo "usage: 5dive digest [--json] [--7d] [--send]"
        echo "       5dive digest on [--at=<0-23>] | off | status   # per-box auto-delivery (default OFF)"
        echo "       5dive digest tick                              # cron driver (hourly; gated on the pref)"
        echo "  --send  deliver the digest to the paired Telegram chat (text only)"
        return 0 ;;
      *) fail "$E_USAGE" "digest: unknown arg: $1" ;;
    esac
    shift
  done
  # Telegram delivery is always the human-readable text, never JSON.
  [ "$do_send" = 1 ] && as_json=0

  # Three deterministic data sources. Invoke them as isolated subprocesses (not
  # in-process) so each gets a clean dispatch + setup and the EXIT-audit trap /
  # errexit of one sub-call can't abort the digest. Assignment-level `|| fallback`
  # guarantees a valid empty shape if a source is unavailable.
  local self
  self="$(command -v 5dive 2>/dev/null || true)"
  _digest_run() { if [ -n "$self" ]; then "$self" "$@"; else bash "$0" "$@"; fi; }

  # Stage each source in a temp file (a large task queue blows past the env-var
  # size limit if passed inline). Paths — not payloads — go to python.
  local tmpd
  tmpd="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" RETURN
  _digest_run task ls --all --json >"$tmpd/tasks.json" 2>/dev/null || echo '{"data":{"tasks":[]}}' >"$tmpd/tasks.json"
  [ -s "$tmpd/tasks.json" ] || echo '{"data":{"tasks":[]}}' >"$tmpd/tasks.json"
  _digest_run usage --json >"$tmpd/usage.json" 2>/dev/null || echo '{"data":{"agents":[],"tasks":[]}}' >"$tmpd/usage.json"
  [ -s "$tmpd/usage.json" ] || echo '{"data":{"agents":[],"tasks":[]}}' >"$tmpd/usage.json"
  _digest_run heartbeat ls >"$tmpd/hb.txt" 2>/dev/null || : >"$tmpd/hb.txt"
  # DIVE-972: per-loop token burn (cost side of the loop control window). --all
  # so a loop that finished (done/escalated/killed) in the window still reports
  # its final burn, not just the currently-running set.
  _digest_run usage loops --by-loop --all --json >"$tmpd/loops.json" 2>/dev/null || echo '{"data":{"loops":[]}}' >"$tmpd/loops.json"
  [ -s "$tmpd/loops.json" ] || echo '{"data":{"loops":[]}}' >"$tmpd/loops.json"

  # DIVE-973: mean-time-to-unstick (MTTU). Sourced from the supervisor_events
  # transition trail (see cmd_supervisor.sh) — the single log that captures BOTH
  # loop_runs.stuck onsets (folded in as cause='loop-stuck') and the service/
  # tmux/poller/no-progress stuck signals. Each stuck episode = a transition INTO
  # classification='stuck' paired with the next transition OUT of it; MTTU is the
  # mean of those durations for episodes that RECOVERED in the window. Read the
  # trail directly (read-only SELECT, same posture as `supervisor` board): the
  # loop-status subcommands don't expose history. A generous lookback captures
  # episodes whose onset predates the window but whose recovery lands inside it.
  local _sup_lb=$(( $(date +%s) - window - 2592000 ))   # window + 30d onset lookback
  dbfmt -json "SELECT agent, CAST(strftime('%s', ts) AS INTEGER) AS ts, classification, prev_classification, cause FROM supervisor_events WHERE event='transition' AND ts >= datetime(${_sup_lb}, 'unixepoch') ORDER BY agent, id;" >"$tmpd/sup.json" 2>/dev/null || echo '[]' >"$tmpd/sup.json"
  [ -s "$tmpd/sup.json" ] || echo '[]' >"$tmpd/sup.json"

  # OSS-19 (OSS-26) objectives block. Per objective: current (latest reading),
  # target, direction, unit, public, and a window baseline (the latest reading
  # from BEFORE the window opened) so python can derive the trend the same
  # window-delta way _window_counts derives the ship/ask deltas. inflight counts
  # this objective's linked-project open tasks; originatedThisCycle is always 0
  # in this measurement-only build (no origination path exists yet). Objectives
  # are gated on the table existing so an old store just yields []. Table missing
  # or empty => [] and the block is omitted from the standup.
  local _obj_wstart="-${window} seconds"
  dbfmt -json "SELECT o.name AS name, o.target AS target, o.direction AS direction,
                      o.unit AS unit, o.public AS public, o.status AS status,
                      (SELECT value FROM objective_readings r WHERE r.objective_id=o.id AND r.value IS NOT NULL ORDER BY r.id DESC LIMIT 1) AS current,
                      (SELECT value FROM objective_readings r WHERE r.objective_id=o.id AND r.value IS NOT NULL AND r.ts < datetime('now', $(sqlq "$_obj_wstart")) ORDER BY r.id DESC LIMIT 1) AS baseline,
                      (SELECT COUNT(*) FROM tasks t WHERE o.project_key IS NOT NULL AND t.project_key=o.project_key AND t.kind='standard' AND t.status NOT IN ('done','cancelled')) AS inflight
               FROM objectives o ORDER BY o.created_at;" >"$tmpd/obj.json" 2>/dev/null || echo '[]' >"$tmpd/obj.json"
  [ -s "$tmpd/obj.json" ] || echo '[]' >"$tmpd/obj.json"

  DIGEST_TASKS_F="$tmpd/tasks.json" DIGEST_USAGE_F="$tmpd/usage.json" DIGEST_HB_F="$tmpd/hb.txt" \
  DIGEST_LOOPS_F="$tmpd/loops.json" DIGEST_SUP_F="$tmpd/sup.json" DIGEST_OBJ_F="$tmpd/obj.json" \
  DIGEST_WINDOW="$window" DIGEST_JSON="$as_json" python3 - >"$tmpd/out.txt" <<'PY'
import os, json, time, datetime as dt

window = int(os.environ["DIGEST_WINDOW"])
now = int(time.time())
since = now - window
as_json = os.environ["DIGEST_JSON"] == "1"

def load(env, default):
    try:
        with open(os.environ[env]) as fh:
            d = json.load(fh)
        return d.get("data", d) if isinstance(d, dict) else d
    except Exception:
        return default

tasks_data = load("DIGEST_TASKS_F", {"tasks": []})
usage_data = load("DIGEST_USAGE_F", {"agents": [], "tasks": []})
tasks = tasks_data.get("tasks", tasks_data if isinstance(tasks_data, list) else [])

def to_epoch(s):
    if not s:
        return None
    s = s.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        if " " in s and "T" not in s:
            s = s.replace(" ", "T", 1)
        d = dt.datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return int(d.timestamp())
    except Exception:
        return None

# Recurring/scheduled rows are machinery, not standup-worthy items.
work = [t for t in tasks if t.get("kind", "task") not in ("recurring", "schedule")]

done, in_progress, blocked, parked = [], [], [], []
for t in work:
    st = t.get("status")
    if st == "done":
        de = to_epoch(t.get("done_at"))
        if de is not None and de >= since:
            done.append(t)
    elif st == "in_progress":
        in_progress.append(t)
    elif t.get("parked_at"):
        # Explicitly "no action now" — counted but never in the needs-you list.
        parked.append(t)
    elif st == "blocked" and t.get("need_type") and not t.get("need_answer"):
        # The true "needs you NOW" signal: an OPEN human gate (filed, unanswered)
        # that isn't parked. need_type lingers after an answer, so we also require
        # need_answer to be empty.
        blocked.append(t)

def line(t):
    who = t.get("assignee") or "unassigned"
    return {"ident": t.get("ident"), "title": (t.get("title") or "").strip(),
            "assignee": who, "ask": (t.get("ask") or "").strip(),
            "need_type": t.get("need_type")}

done_l = [line(t) for t in done]
ip_l = [line(t) for t in in_progress]
blk_l = [line(t) for t in blocked]

# DIVE-891: gates the tier system cleared without a ping (tier-0 immediate or
# tier-1 48h TTL — need_answered_by 'auto:t0' / 'auto:ttl') inside the window.
# The digest line is the human's ONLY surface for these, so it names what was
# applied — silence would read as "nothing was decided".
auto_cleared = []
for t in work:
    by = t.get("need_answered_by") or ""
    if by.startswith("auto:"):
        ae = to_epoch(t.get("need_answered_at"))
        if ae is not None and ae >= since:
            auto_cleared.append(t)
auto_l = [{"ident": t.get("ident"), "applied": (t.get("need_answer") or "").strip(),
           "by": t.get("need_answered_by"), "assignee": t.get("assignee") or "unassigned",
           "precedent": t.get("precedent_ref")}
          for t in auto_cleared]

# OSS-11 (DIVE-976): precedent-prefill acceptance rate — of gates that were
# prefilled from a precedent AND answered in the window, how many kept the
# prefilled recommendation (need_answer == recommend). Low acceptance ⇒ matching
# is too loose ⇒ tighten (this metric also gates promotion to v2 auto-clear).
def _norm(s):
    return (s or "").strip()
prefilled = []
for t in work:
    if t.get("precedent_ref") and t.get("need_answer"):
        ae = to_epoch(t.get("need_answered_at"))
        if ae is not None and ae >= since:
            prefilled.append(t)
accepted = [t for t in prefilled if _norm(t.get("need_answer")) == _norm(t.get("recommend"))]
prefill_rate = round(100 * len(accepted) / len(prefilled)) if prefilled else None

# OSS-20: split the acceptance rate by match kind (exact vs fuzzy) so the two are
# comparable — fuzzy prefill is a paraphrase match and expected to accept lower;
# promotion to auto-clear (OSS-21) reads the EXACT rate only. Legacy prefills with
# no recorded kind count as 'exact' (they predate the fuzzy fallback).
def _by_kind(kind):
    sub = [t for t in prefilled if (t.get("precedent_kind") or "exact") == kind]
    acc = [t for t in sub if _norm(t.get("need_answer")) == _norm(t.get("recommend"))]
    return {"count": len(sub), "accepted": len(acc),
            "rate": (round(100 * len(acc) / len(sub)) if sub else None)}
prefill_exact = _by_kind("exact")
prefill_fuzzy = _by_kind("fuzzy")

# OSS-10 zero-human KPI: gates a HUMAN answered in the window. Provenance is
# need_answered_by = 'human:*' (the --human tap/dashboard path); bare agent
# names are agent-cleared decisions and 'auto:*' is the tier system — neither
# costs the human anything, so neither counts as a touch.
human_touches = []
for t in work:
    by = t.get("need_answered_by") or ""
    if by.startswith("human:"):
        ae = to_epoch(t.get("need_answered_at"))
        if ae is not None and ae >= since:
            human_touches.append(t)
ht_l = [{"ident": t.get("ident"), "type": t.get("need_type"),
         "answer": (t.get("need_answer") or "").strip()} for t in human_touches]

# Usage: top agents by output tokens + their share-of-limit; flag anyone hot.
agents = usage_data.get("agents", []) or []
agents_sorted = sorted(agents, key=lambda a: a.get("output", 0), reverse=True)
usage_l = [{"name": a.get("name"), "output": a.get("output", 0),
            "fiveHourPct": a.get("fiveHourPct"), "sevenDayPct": a.get("sevenDayPct")}
           for a in agents_sorted]
hot = [a for a in usage_l if (a.get("fiveHourPct") or 0) >= 80]

# Heartbeat health from the `heartbeat ls` table: flag agents that aren't fresh.
stale = []
try:
    with open(os.environ["DIGEST_HB_F"]) as fh:
        hb = fh.read()
except Exception:
    hb = ""
for ln in hb.splitlines()[1:]:
    cols = ln.split()
    if len(cols) >= 4 and cols[1] == "on" and cols[3] == "no":
        stale.append(cols[0])

# DIVE-972: per-loop token burn. loops[].tokens is the live spend; a loop whose
# spend has reached its ceiling was halted (advisory ceiling is now enforced).
loops_data = load("DIGEST_LOOPS_F", {"loops": []})
loops_all = loops_data.get("loops", []) if isinstance(loops_data, dict) else []
loops_burn = sorted(
    [{"loopId": l.get("loop_id"), "topology": l.get("topology"),
      "status": l.get("status"), "tokens": int(l.get("tokens") or 0),
      "ceiling": (int(l["ceiling"]) if l.get("ceiling") not in (None, "") else None),
      "atCeiling": bool(l.get("ceiling") not in (None, "") and int(l.get("tokens") or 0) >= int(l["ceiling"]))}
     for l in loops_all],
    key=lambda x: x["tokens"], reverse=True)
loops_total = sum(l["tokens"] for l in loops_burn)
loops_capped = [l for l in loops_burn if l["atCeiling"]]

def _htok(n):
    n = n or 0
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.1f}k"
    return str(n)

# DIVE-973: MTTU (mean-time-to-unstick). Walk the supervisor_events transition
# trail per agent in chronological order. A stuck episode opens at a transition
# INTO classification='stuck' and closes at the next transition OUT of it (back
# to healthy/slow/drift). We count an episode toward MTTU when it RECOVERED
# inside the window (recovery ts >= since); its onset may predate the window.
# An agent still stuck at read time (open onset, no recovery row) is reported as
# an unresolved-stuck count, not folded into the mean. cause carries the stuck
# reason ('loop-stuck' = a loop_runs.stuck onset), so we also break MTTU down by
# cause. Transition rows only fire on a class change, so stuck onsets never
# double-count. Empty trail => mttuSec null, zero episodes.
sup_rows = load("DIGEST_SUP_F", [])
by_agent = {}
for r in sup_rows:
    by_agent.setdefault(r.get("agent"), []).append(r)
recovered = []          # {agent, onsetTs, recoveryTs, durSec, cause}
open_stuck = []         # agents with an onset but no recovery row (still wedged)
for agent, rows in by_agent.items():
    rows = sorted(rows, key=lambda r: (r.get("ts") or 0))
    onset_ts = None; onset_cause = None
    for r in rows:
        is_stuck = r.get("classification") == "stuck"
        if is_stuck and onset_ts is None:
            onset_ts = r.get("ts"); onset_cause = r.get("cause")
        elif (not is_stuck) and onset_ts is not None:
            rt = r.get("ts")
            if rt is not None and onset_ts is not None:
                recovered.append({"agent": agent, "onsetTs": onset_ts, "recoveryTs": rt,
                                  "durSec": max(0, rt - onset_ts), "cause": onset_cause})
            onset_ts = None; onset_cause = None
    if onset_ts is not None:
        open_stuck.append({"agent": agent, "onsetTs": onset_ts, "cause": onset_cause})

in_window = [e for e in recovered if (e["recoveryTs"] or 0) >= since]
mttu_sec = round(sum(e["durSec"] for e in in_window) / len(in_window)) if in_window else None
mttu_by_cause = {}
for e in in_window:
    c = e["cause"] or "unknown"
    mttu_by_cause.setdefault(c, []).append(e["durSec"])
mttu_by_cause = {c: {"episodes": len(v), "mttuSec": round(sum(v) / len(v))}
                 for c, v in mttu_by_cause.items()}

def _hdur(sec):
    sec = int(sec or 0)
    if sec < 90: return f"{sec}s"
    m = sec // 60
    if m < 90: return f"{m}m"
    h = m / 60
    if h < 48: return f"{h:.1f}h"
    return f"{h/24:.1f}d"

window_label = "7 days" if window >= 604800 else "24h"

# OSS-14: one-glance autonomy rollup — "ran N days, shipped X, asked you Y",
# with trend vs the prior window. Deterministic, from data already loaded; the
# marketing-flagship framing of the OSS-10 zero-human numbers. Zero agent tokens.
def _window_counts(lo, hi):
    ship = sum(1 for t in work if t.get("status") == "done"
               and lo <= (to_epoch(t.get("done_at")) or -1) < hi)
    ask = sum(1 for t in work
              if (t.get("need_answered_by") or "").startswith("human:")
              and lo <= (to_epoch(t.get("need_answered_at")) or -1) < hi)
    return ship, ask
prev_ship, prev_ask = _window_counts(since - window, since)
# uptime = days since the last human-blocking stall. An open gate right now means
# not-autonomous this instant (0); else days since the most recent gate was filed;
# else (never needed a human) the streak runs since the company's first task.
if blocked:
    uptime_days = 0
else:
    _asked = [x for x in (to_epoch(t.get("need_asked_at")) for t in work if t.get("need_asked_at")) if x]
    if _asked:
        uptime_days = max(0, (now - max(_asked)) // 86400)
    else:
        _born = [x for x in (to_epoch(t.get("created_at")) for t in work if t.get("created_at")) if x]
        uptime_days = max(0, (now - min(_born)) // 86400) if _born else 0
autonomy = {"uptimeDays": uptime_days, "currentlyBlocked": bool(blocked),
            "shipped": len(done_l), "asked": len(ht_l),
            "priorShipped": prev_ship, "priorAsked": prev_ask, "windowLabel": window_label}

# OSS-19 (OSS-26) objectives: current vs target with a window trend, riding the
# same window-delta idea as _window_counts. current/baseline come straight from
# the readings table (metric run by the tick/digest only — never a planner). gap
# is signed toward "better" per direction; trend is up/down/flat vs the window
# baseline; originatedThisCycle is 0 in this measurement-only build.
obj_rows = load("DIGEST_OBJ_F", [])
if isinstance(obj_rows, dict):
    obj_rows = obj_rows.get("objectives", [])
objectives = []
for o in obj_rows:
    cur = o.get("current")
    base = o.get("baseline")
    tgt = o.get("target")
    direction = o.get("direction") or "up"
    if cur is None:
        trend = "none"
    elif base is None:
        trend = "new"
    elif cur > base:
        trend = "up"
    elif cur < base:
        trend = "down"
    else:
        trend = "flat"
    gap = None
    if cur is not None and tgt is not None:
        gap = round((cur - tgt) if direction == "up" else (tgt - cur), 4)
    objectives.append({
        "name": o.get("name"), "current": cur, "target": tgt,
        "direction": direction, "unit": o.get("unit"),
        "trend": trend, "gap": gap, "inflight": int(o.get("inflight") or 0),
        "originatedThisCycle": 0, "status": o.get("status"),
        "public": bool(o.get("public")),
    })

if as_json:
    print(json.dumps({
        "window": {"since": since, "now": now, "label": window_label},
        "objectives": objectives,
        "done": done_l, "inProgress": ip_l, "blocked": blk_l, "autoCleared": auto_l,
        "zeroHuman": {"shipped": len(done_l), "humanTouches": len(ht_l), "gates": ht_l},
        "autonomy": autonomy,
        "precedentPrefill": {"count": len(prefilled), "accepted": len(accepted),
                             "acceptanceRate": prefill_rate,
                             "byKind": {"exact": prefill_exact, "fuzzy": prefill_fuzzy}},
        "usage": usage_l, "health": {"stale": stale, "hot": [h["name"] for h in hot]},
        "loops": {"total": loops_total, "capped": len(loops_capped), "byLoop": loops_burn},
        "stuck": {"mttuSec": mttu_sec, "episodes": len(in_window),
                  "openStuck": len(open_stuck), "byCause": mttu_by_cause},
    }, indent=2))
else:
    def short(s, n=60):
        s = s or ""
        return s if len(s) <= n else s[: n - 1] + "…"
    out = []
    out.append(f"\U0001F305 5dive standup — last {window_label}")
    touches = len(ht_l)
    kpi = f"\U0001F3AF Zero-human: {len(done_l)} shipped · {touches} human touch{'es' if touches != 1 else ''}"
    if 0 < touches <= 4:
        kpi += " (" + ", ".join(g["ident"] for g in ht_l) + ")"
    out.append(kpi)
    def _trend(cur, prev):
        d = cur - prev
        arrow = "↑" if d > 0 else ("↓" if d < 0 else "→")
        return f" ({arrow}{abs(d)} vs {prev} prior {window_label})"
    _up = ("currently waiting on you" if autonomy["currentlyBlocked"]
           else f"ran {autonomy['uptimeDays']}d without needing you")
    out.append(f"\U0001F9BE Autonomy — {_up} · shipped {len(done_l)}{_trend(len(done_l), prev_ship)}"
               f" · asked you {len(ht_l)}×{_trend(len(ht_l), prev_ask)}")
    if objectives:
        out.append("")
        out.append(f"\U0001F9ED Objectives ({len(objectives)})")
        _arrow = {"up": "↑", "down": "↓", "flat": "→", "new": "•", "none": "·"}
        for o in objectives:
            u = o["unit"] or ""
            cur = f"{o['current']:g}{u}" if o["current"] is not None else "—"
            tgt = f"{o['target']:g}{u}" if o["target"] is not None else "?"
            paused = " (paused)" if o["status"] == "paused" else ""
            inflight = f", {o['inflight']} inflight" if o["inflight"] else ""
            out.append(f"  {_arrow.get(o['trend'], '·')} {o['name']}: {cur} / {tgt} "
                       f"({o['direction']}{inflight}){paused}")
    out.append("")
    out.append(f"✅ Shipped ({len(done_l)})")
    for t in done_l[:8]:
        out.append(f"  • {t['ident']} {short(t['title'])} — {t['assignee']}")
    if not done_l:
        out.append("  (nothing closed)")
    if len(done_l) > 8:
        out.append(f"  … +{len(done_l) - 8} more")
    out.append("")
    out.append(f"\U0001F501 In progress ({len(ip_l)})")
    for t in ip_l[:8]:
        out.append(f"  • {t['ident']} {short(t['title'])} — {t['assignee']}")
    if not ip_l:
        out.append("  (idle)")
    out.append("")
    out.append(f"\U0001F64B Needs you ({len(blk_l)})")
    for t in blk_l[:8]:
        ask = short(t["ask"], 80) if t["ask"] else short(t["title"])
        out.append(f"  • {t['ident']} {ask} — {t['assignee']}")
    if not blk_l:
        out.append("  (nothing blocked)")
    if auto_l:
        out.append("")
        out.append(f"\U0001F916 Auto-cleared gates ({len(auto_l)})")
        for t in auto_l[:8]:
            prec = f" from precedent #{t['precedent']}" if t.get("precedent") else ""
            out.append(f"  • {t['ident']} applied: {short(t['applied'], 60)} ({t['by']}{prec})")
        if len(auto_l) > 8:
            out.append(f"  … +{len(auto_l) - 8} more")
    if prefilled:
        out.append("")
        out.append(f"\U0001F9E0 Precedent prefills ({len(prefilled)}) — "
                   f"{prefill_rate}% kept the prefilled rec ({len(accepted)}/{len(prefilled)})")
        # OSS-20: break out exact vs fuzzy so the fuzzy fallback's quality is legible
        # (only the exact rate gates promotion to auto-clear).
        def _kind_line(label, k):
            if not k["count"]:
                return None
            return f"    {label}: {k['rate']}% ({k['accepted']}/{k['count']})"
        for _ln in (_kind_line("exact", prefill_exact), _kind_line("fuzzy", prefill_fuzzy)):
            if _ln:
                out.append(_ln)
    if loops_burn:
        out.append("")
        cap_note = f", {len(loops_capped)} hit ceiling" if loops_capped else ""
        out.append(f"\U0001F504 Loop burn ({_htok(loops_total)} tok{cap_note})")
        for l in loops_burn[:6]:
            ceil = _htok(l["ceiling"]) if l["ceiling"] is not None else "∞"
            flag = " ⛔ ceiling" if l["atCeiling"] else ""
            out.append(f"  • {l['loopId']} [{l['topology']}] {_htok(l['tokens'])}/{ceil} — {l['status']}{flag}")
        if len(loops_burn) > 6:
            out.append(f"  … +{len(loops_burn) - 6} more")
    if in_window or open_stuck:
        out.append("")
        if in_window:
            top = sorted(mttu_by_cause.items(), key=lambda kv: kv[1]["episodes"], reverse=True)
            cause_note = ", ".join(f"{c} {_hdur(v['mttuSec'])}" for c, v in top[:3])
            line_s = (f"\U0001F551 Unstick — MTTU {_hdur(mttu_sec)} over "
                      f"{len(in_window)} episode{'s' if len(in_window) != 1 else ''}")
            if cause_note:
                line_s += f" ({cause_note})"
            out.append(line_s)
        if open_stuck:
            out.append(f"  ⛔ {len(open_stuck)} still stuck: " +
                       ", ".join(e["agent"] for e in open_stuck[:6]))
    out.append("")
    if hot:
        out.append("⚠️ Rate-limit watch: " +
                   ", ".join(f"{h['name']} {h['fiveHourPct']}%/5h" for h in hot))
    if stale:
        out.append("\U0001F634 Heartbeat stale: " + ", ".join(stale))
    if not hot and not stale:
        out.append("\U0001F49A Fleet healthy — heartbeats fresh, no rate-limit pressure")
    print("\n".join(out))
PY

  if [ "$do_send" = 1 ]; then
    # Deliver via the same paired-chat path the gate alerts use (follows
    # last-human-chat → allowed DMs → bound group topics). Best-effort: if no
    # channel resolves, fall back to printing so a cron still leaves a log trail.
    if _task_owner_channel; then
      _task_send_owner "$(cat "$tmpd/out.txt")"
      echo "digest: sent to paired Telegram chat" >&2
    else
      echo "digest --send: no Telegram channel resolved for this agent; printing instead" >&2
      cat "$tmpd/out.txt"
    fi
  else
    cat "$tmpd/out.txt"
  fi
}
