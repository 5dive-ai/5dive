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

  DIGEST_TASKS_F="$tmpd/tasks.json" DIGEST_USAGE_F="$tmpd/usage.json" DIGEST_HB_F="$tmpd/hb.txt" \
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

window_label = "7 days" if window >= 604800 else "24h"

if as_json:
    print(json.dumps({
        "window": {"since": since, "now": now, "label": window_label},
        "done": done_l, "inProgress": ip_l, "blocked": blk_l,
        "usage": usage_l, "health": {"stale": stale, "hot": [h["name"] for h in hot]},
    }, indent=2))
else:
    def short(s, n=60):
        s = s or ""
        return s if len(s) <= n else s[: n - 1] + "…"
    out = []
    out.append(f"\U0001F305 5dive standup — last {window_label}")
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
