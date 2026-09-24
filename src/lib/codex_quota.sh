# -------- codex quota — the Codex rollout's own rate-limit record ------------
#
# DIVE-3968. Every quota surface on the box was built for Claude: the account
# snapshot (src/lib/quota_wall.sh) is fed from `~/.claude/statusline-last.json`,
# which a Codex seat never writes, so the `codex` account row has carried
# `usage: null` since the day it was bound — and the supervisor's only Codex
# signal was the PANE. Measured twice (2026-09-11 08:14Z, 2026-09-14 06:53Z):
# codex hit its 5h wall, the window reset minutes later, and the seat stayed
# classified `quota-exhausted` for ~2h because the pane said "try again at 7:00
# AM", which names no date, so the park fell to its 6h cap.
#
# THE DEADLINE WAS ON DISK THE WHOLE TIME. Codex appends to its session rollout
# (`~/.codex/sessions/<y>/<m>/<d>/rollout-*.jsonl`):
#
#   * `event_msg/token_count` — carries `rate_limits.primary` (5h) and
#     `.secondary` (7d), each {used_percent, window_minutes, resets_at}, plus
#     `credits` and `plan_type`. Codex 0.4x wrote `resets_in_seconds` instead of
#     an epoch; both are read.
#   * `event_msg/task_complete` — carries `error.codex_error_info`, and a refused
#     turn says exactly `usage_limit_exceeded`. That string is the classifier
#     key; the prose beside it ("try again at 7:00 AM") is only a rendering.
#
# ONE TRAP, and it is the one that makes the naive read wrong at the worst
# moment: the token_count written ON a refused turn is a `limit_id: "premium"`
# record with `primary: null, secondary: null`. The newest token_count is
# therefore EMPTY exactly when the seat is walled. The reading this file uses is
# the newest token_count that carries a window, and the refusal is read from
# the newest task_complete — two different records, joined here.
#
# WHICH WINDOW THE WALL IS. The refusal does not name it. It is the window with
# the highest used_percent in the last reading before the refusal (ties → the
# later reset). Measured against every refusal in the seat's rollout on
# 2026-09-24: 98 of 98 walls, 5h and 7d alike, printed exactly that window's
# resets_at as their "try again at" time — including the ones whose last reading
# said 99%, not 100%.
#
# WHAT IS STORED IS THE MEASUREMENT, NOT THE VERDICT (same rule as quota_wall.sh):
# `codex_quota_read` returns what the rollout said; `codex_quota_state` decides,
# at read time, against the caller's clock — so a wall whose reset has passed
# reads `recovered` on the next call without anyone re-reading the file.

# At/above this a window is `near-limit`. Same threshold rotation already uses
# for "this profile is near its wall" (HEADROOM_MAX_PCT, cmd_account.sh).
CODEX_QUOTA_NEAR_PCT="${CODEX_QUOTA_NEAR_PCT:-90}"

# codex_quota_rollout <home> — the seat's newest rollout file, or nothing.
codex_quota_rollout() {
  local home="${1:-}" root
  root="${home}/.codex/sessions"
  [[ -n "$home" && -d "$root" ]] || return 0
  { find "$root" -type f -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null || true; } \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# codex_quota_read <home> — one compact JSON measurement, or nothing when the
# seat has no rollout. Shape:
#   {source:"codex-rollout", file,
#    snapshot: null | {at, limitId, planType, reachedType,
#                      primary:   null | {usedPct, windowMin, resetsAt},
#                      secondary: null | {usedPct, windowMin, resetsAt},
#                      credits:   null | {hasCredits, unlimited, balance}},
#    lastTurn: null | {at, error}}          # error: codex_error_info or null
# The file is read BACKWARDS and the scan stops once both records are found, so
# a 40MB rollout costs one tail read, not a full parse, on every supervisor tick.
codex_quota_read() {
  local home="${1:-}" file
  file=$(codex_quota_rollout "$home")
  [[ -n "$file" && -r "$file" ]] || return 0
  CQ_FILE="$file" python3 - <<'PY' 2>/dev/null || true
import os, json, datetime as dt

path = os.environ["CQ_FILE"]

def to_epoch(s):
    try:
        s = (s or "").strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        d = dt.datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return int(d.timestamp())
    except Exception:
        return None

def lines_backwards(f, block=1 << 16):
    f.seek(0, os.SEEK_END)
    pos, rest = f.tell(), b""
    while pos > 0:
        step = min(block, pos)
        pos -= step
        f.seek(pos)
        buf = f.read(step) + rest
        parts = buf.split(b"\n")
        rest = parts[0]
        for ln in reversed(parts[1:]):
            if ln:
                yield ln
    if rest:
        yield rest

def window(w, at):
    if not isinstance(w, dict):
        return None
    reset = w.get("resets_at")
    if not isinstance(reset, (int, float)):
        # Codex 0.4x: seconds from the reading, not an epoch (DIVE-4430).
        r = w.get("resets_in_seconds")
        reset = at + int(r) if isinstance(r, (int, float)) and at is not None else None
    return {"usedPct": w.get("used_percent"),
            "windowMin": w.get("window_minutes"),
            "resetsAt": int(reset) if reset is not None else None}

snap = turn = None
with open(path, "rb") as f:
    for raw in lines_backwards(f):
        if snap is not None and turn is not None:
            break
        if b'"token_count"' not in raw and b'"task_complete"' not in raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        p = o.get("payload") or {}
        at = to_epoch(o.get("timestamp"))
        if o.get("type") != "event_msg" or at is None:
            continue
        if p.get("type") == "task_complete" and turn is None:
            err = p.get("error") or {}
            turn = {"at": at, "error": err.get("codex_error_info") if isinstance(err, dict) else None}
        elif p.get("type") == "token_count" and snap is None:
            rl = p.get("rate_limits") or {}
            # The refused turn's own record is `premium` with both windows null
            # — see the header. It is not a reading; keep looking.
            if not (rl.get("primary") or rl.get("secondary")):
                continue
            c = rl.get("credits")
            snap = {"at": at, "limitId": rl.get("limit_id"), "planType": rl.get("plan_type"),
                    "reachedType": rl.get("rate_limit_reached_type"),
                    "primary": window(rl.get("primary"), at),
                    "secondary": window(rl.get("secondary"), at),
                    "credits": ({"hasCredits": c.get("has_credits"), "unlimited": c.get("unlimited"),
                                 "balance": c.get("balance")} if isinstance(c, dict) else None)}

print(json.dumps({"source": "codex-rollout", "file": path, "snapshot": snap, "lastTurn": turn},
                 separators=(",", ":")))
PY
}

# _cq_line <field>... — one unit-separated record (quota_wall_line's shape).
_cq_line() { local IFS=$'\037'; printf '%s\n' "$*"; }

# codex_quota_state <measurement-json> [now_epoch] -> ONE line, six
# unit-separated fields (quota_wall_line's separator):
#   <state> <window> <pct> <resetsAt-epoch> <asOf-epoch> <note>
# state: missing | healthy | near-limit | exhausted | recovered
#   missing    — no rollout, or one with no rate-limit reading in it.
#   exhausted  — the newest turn was refused `usage_limit_exceeded` and the
#                walled window's reset is still ahead (resetsAt empty when no
#                reading predates the refusal's window — the wall is real, its
#                end is unknown); OR a reading at 100% whose window is still open.
#   recovered  — the newest turn was refused and that window has SINCE reset:
#                capacity is back and the seat has not run a turn to show it.
#   near-limit — no wall; the fuller open window is at/above CODEX_QUOTA_NEAR_PCT.
#   healthy    — no wall; below that.
# A window whose resetsAt has passed counts as 0% — that is the vendor's own
# semantics for a rolled window, not an inference.
codex_quota_state() {
  local m="${1:-}" now="${2:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  local us=$'\037'
  if [[ -z "$m" ]]; then
    _cq_line missing "" "" "" "" "no codex rollout on this seat"
    return 0
  fi
  jq -r --argjson now "$now" --argjson near "$CODEX_QUOTA_NEAR_PCT" --arg us "$us" '
    def wname: if . == 300 then "5h" elif . == 10080 then "7d"
               elif . == null then "quota" else "\(.)m" end;
    def out(s; w; p; r; a; n):
      [s, w, p, r, a, n] | map(if . == null then "" else tostring end) | join($us);
    .snapshot as $s | .lastTurn as $t
    | [($s.primary // empty), ($s.secondary // empty)]
      | map(select(.usedPct != null)
            | . + {name: (.windowMin | wname),
                   eff: (if .resetsAt != null and .resetsAt <= $now then 0 else .usedPct end)}) as $ws
    | ([$s.at, $t.at] | map(select(. != null)) | max) as $asof
    | if ($t.error // "") == "usage_limit_exceeded" then
        ($ws | sort_by(.usedPct, (.resetsAt // 0)) | last) as $hit
        | (if $hit != null and $hit.resetsAt != null and $hit.resetsAt > $t.at
           then $hit.resetsAt else null end) as $d
        | if $d != null and $d <= $now then
            out("recovered"; $hit.name; ($hit.usedPct | floor); $d; $asof;
                "the \($hit.name) window that refused the last turn reset at \($d) — capacity is back, no turn run since")
          elif $d != null then
            out("exhausted"; $hit.name; 100; $d; $asof;
                "last turn refused usage_limit_exceeded; the \($hit.name) window resets at \($d)")
          else
            out("exhausted"; ($hit.name // null); 100; null; $asof;
                "last turn refused usage_limit_exceeded; no reading predates the refusal, so its reset time is unknown")
          end
      elif ($ws | length) == 0 then
        out("missing"; null; null; null; $asof; "codex rollout carries no rate-limit reading")
      else
        ($ws | sort_by(.eff, (.resetsAt // 0)) | last) as $top
        | if $top.eff >= 100 then
            out("exhausted"; $top.name; ($top.eff | floor); $top.resetsAt; $asof;
                "\($top.name) window at \($top.eff | floor)% and still open")
          elif $top.eff >= $near then
            out("near-limit"; $top.name; ($top.eff | floor); $top.resetsAt; $asof;
                "\($top.name) window at \($top.eff | floor)%")
          else
            out("healthy"; $top.name; ($top.eff | floor); $top.resetsAt; $asof;
                "\($top.name) window at \($top.eff | floor)%")
          end
      end' <<<"$m" 2>/dev/null \
    || _cq_line missing "" "" "" "" "codex rollout reading is not parseable"
}

# codex_quota_ratelimits <measurement-json> [now_epoch] — the SAME measurement,
# in the shape `usage_read_ratelimits` hands the account snapshot
# ({asOf, fiveHourPct, fiveResetsAt, sevenDayPct, sevenResetsAt}), so the codex
# account row stops being `usage: null` and every surface that already joins
# seat -> account -> usage (agent list/info, liveness, supervisor, rotation's
# headroom fence) reads Codex through the path it already trusts.
#
# asOf is the newest rollout event (a refusal re-attests the wall as much as a
# reading does). A refused turn raises the walled window to 100: the vendor
# refusing is the measurement, even when the last reading before it said 99.
codex_quota_ratelimits() {
  local m="${1:-}" now="${2:-}" st
  [[ -n "$m" ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  local state win
  IFS=$'\037' read -r state win _ _ _ _ <<<"$(codex_quota_state "$m" "$now")"
  [[ "$state" == "missing" ]] && return 0
  st="$state"
  jq -c --arg st "$st" --arg win "$win" '
    .snapshot as $s
    | ([$s.at, .lastTurn.at] | map(select(. != null)) | max) as $asof
    | def pct(w; name): if w == null or w.usedPct == null then null
                        elif $st == "exhausted" and $win == name then ([w.usedPct, 100] | max)
                        else w.usedPct end;
      {asOf: $asof, source: "codex-rollout",
       fiveHourPct:   pct($s.primary; "5h"),   fiveResetsAt:  ($s.primary.resetsAt // null),
       sevenDayPct:   pct($s.secondary; "7d"), sevenResetsAt: ($s.secondary.resetsAt // null)}
  ' <<<"$m" 2>/dev/null || true
}
