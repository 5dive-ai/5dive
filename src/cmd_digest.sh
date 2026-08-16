# DIVE-3318: `a2a_round_guard` and `a2a_rounds_report` live in src/lib/a2a_rounds.sh.
# In the BUILT bundle that file is cat'd ahead of this one and this line is dead
# code (build.sh's "lib/ helpers -> cmd_*" ordering). In the SPLIT tree it is
# load-bearing: the unit harnesses source individual cmd_* files with a minimal
# lib set, and without this an `agent send` path hits `a2a_round_guard: command
# not found` and dies at rc=3 — which is what tests/agent_send_unconfirmed_unit.sh
# caught. Same shape as src/cmd_task.sh's module loader.
declare -F a2a_round_guard >/dev/null 2>&1 \
  || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/a2a_rounds.sh"

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
#   5dive digest --30d      # widen the window to 30 days (DIVE-1921)
#
# DIVE-1921 — WHAT THE WINDOW ACTUALLY SCOPES. Widening is not uniform across
# this payload, and a reader who assumes it is will misread half the digest.
# Three kinds of aggregate live here:
#   SUMS over the window   — done, autoCleared, zeroHuman.*, autonomy.shipped/
#                            asked, precedentPrefill.count/accepted,
#                            stuck.episodes. These scale with the window.
#   RATES/MEANS over it    — precedentPrefill.acceptanceRate, stuck.mttuSec and
#                            stuck.byCause[].mttuSec. The denominator grows, so
#                            a wider window is the FIX for the thin-n readings
#                            DIVE-1914 hit (mttuSec off one episode, precedent
#                            acceptance off n=2).
#   POINT READINGS         — inProgress, blocked, usage, usageCoverage, health,
#                            loops, stuck.openStuck, autonomy.uptimeDays and the
#                            objectives' current/gap/inflight. These are "as of
#                            now" and are IDENTICAL at 24h, 7d and 30d.
# The last group is the hazard: `usage` is usage_collect's own 5h/7d rolling
# read and `loops` is every loop ever (--all), so under a "last 30 days" header
# they read as 30 days of tokens when they are nothing of the kind. They are
# therefore named in the JSON `pointInTime` map and captioned in the text, so
# the window label can never be applied to a number it does not describe.

# Per-box digest preference, in the shared state dir so it SURVIVES CLI updates
# (install.sh seeds it OFF and never clobbers it). One digest per fleet → one
# file. Shape: {"enabled":bool,"hour":0-23,"lastSent":"YYYY-MM-DD"}. DEFAULT OFF
# (DIVE-544, Mark): customers opt in only via the telegram /digest command.

# DIVE-2080. `five_self_bundle` lives in src/lib/self.sh, concatenated ahead of this
# file in the bundle — so in the built artifact this block is dead. It exists for the
# unit harnesses that source ONLY this file out of the split tree: without it the call
# sites below would die as command-not-found, which is how a "resolve myself honestly"
# rule turns back into a silent wrong answer.
if ! declare -F five_self_bundle >/dev/null 2>&1; then
  _five_self_lib="$(dirname -- "${BASH_SOURCE[0]}")/lib/self.sh"
  # shellcheck source=lib/self.sh
  [[ -r "$_five_self_lib" ]] && source "$_five_self_lib"
  unset _five_self_lib
fi
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

  # DIVE-2080 decided this site DELIBERATELY keeps `command -v`. Everything else that
  # re-invokes the CLI to produce evidence moved to five_self_bundle; this one is not an
  # evidence path. It is the root cron driver re-execing `digest --send` as ANOTHER
  # UNIX user via sudo, and the intent really is "run the CLI installed on this box" —
  # a worktree bundle root happens to be sitting in is the wrong answer here, and it may
  # not even be readable by agent-<name>. Not a blanket replace: see src/lib/self.sh.
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
      --30d)   window=2592000 ;;
      --24h|--day) window=86400 ;;
      --send)  do_send=1 ;;
      -h|--help)
        echo "usage: 5dive digest [--json] [--7d|--30d] [--send]"
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
  # DIVE-2080: digest's numbers are the input to `proof scorecard` and the published
  # badge, so the sub-calls that produce them must be THIS bundle. Preferring PATH here
  # meant a worktree bundle reported the installed CLI's fleet. Unresolvable keeps the
  # pre-existing `bash "$0"` fallback rather than inventing a source.
  local self
  self="$(five_self_bundle 2>/dev/null || true)"
  _digest_run() { if [ -n "$self" ]; then "$self" "$@"; else bash "$0" "$@"; fi; }

  # The one shape allowed to stand in for an unread usage source (DIVE-1937).
  # complete:false is what makes it degrade rather than read as an idle fleet.
  _digest_usage_unavailable() {
    printf '%s\n' '{"data":{"agents":[],"tasks":[],"coverage":{"agentsExpected":null,"agentsRead":0,"unreadable":[],"complete":false,"unavailable":true,"reason":"the usage collector could not be run by this caller (5dive usage needs root)"}}}'
  }

  # Stage each source in a temp file (a large task queue blows past the env-var
  # size limit if passed inline). Paths — not payloads — go to python.
  local tmpd
  tmpd="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" RETURN
  _digest_run task ls --all --json >"$tmpd/tasks.json" 2>/dev/null || echo '{"data":{"tasks":[]}}' >"$tmpd/tasks.json"
  [ -s "$tmpd/tasks.json" ] || echo '{"data":{"tasks":[]}}' >"$tmpd/tasks.json"
  # DIVE-1937: the fallback used to ERASE the failure. `usage` is root-only, so
  # every non-root digest fell straight through to an empty agent list that
  # renders exactly like a quiet fleet — and then the health line went on to
  # claim "no rate-limit pressure" on the strength of a source it never read.
  # The fallback now carries a coverage stanza saying the source was unreadable,
  # so the standup can say UNKNOWN instead of implying zero.
  _digest_run usage --json >"$tmpd/usage.json" 2>/dev/null || _digest_usage_unavailable >"$tmpd/usage.json"
  [ -s "$tmpd/usage.json" ] || _digest_usage_unavailable >"$tmpd/usage.json"
  _digest_run heartbeat ls >"$tmpd/hb.txt" 2>/dev/null || : >"$tmpd/hb.txt"
  # DIVE-3501: seats whose ENTIRE runnable queue is tier-guard held. This is the
  # ONLY surface for that state — the rows read `todo`, the unit reads `active`,
  # and the guard's own trace is a stderr line in /var/log/5dive-heartbeat.log
  # that nobody reads (7865 of them by 2026-08-16, while dev2 sat stranded for
  # six days). The digest is the surface that comes TO a lead on a cadence rather
  # than one they have to already suspect a problem to open. Breach-only: the
  # source emits an empty `seats` when nothing is stranded and the block is
  # omitted entirely. Stateless — see cmd_heartbeat_held; nothing here counts ticks.
  _digest_run heartbeat held --json >"$tmpd/held.json" 2>/dev/null || echo '{"data":{"seats":[]}}' >"$tmpd/held.json"
  [ -s "$tmpd/held.json" ] || echo '{"data":{"seats":[]}}' >"$tmpd/held.json"
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
               FROM objectives o WHERE o.status <> 'retired' ORDER BY o.created_at;" >"$tmpd/obj.json" 2>/dev/null || echo '[]' >"$tmpd/obj.json"
  [ -s "$tmpd/obj.json" ] || echo '[]' >"$tmpd/obj.json"

  # DIVE-2306: the fleet-freeze / ahead reading. DIVE-2287 built an alarm that
  # survives the release process being down and delivered it to `5dive
  # supervisor` and `update --check` — both of which a human has to go and LOOK
  # at. The digest is the one surface that comes to them (`--send` delivers it
  # to the paired chat), so this is where the signal stops needing an audience
  # that already suspects something.
  #
  # NOT a fourth board-shaped source: it is one `update --check`, the same
  # command the dashboard tile runs, so the digest and the tile cannot disagree.
  # HARD-BOUNDED because it makes a network probe and this runs from cron —
  # `_published_cli_probe` fails closed on a dead endpoint, but "fails closed"
  # is about the ANSWER, not about how long the socket takes to say so. A hung
  # CDN must cost the digest a few seconds, never the digest. Unreadable => `{}`
  # => the block is omitted, which is the same degrade-not-erase rule DIVE-1937
  # applied to the usage source.
  if [ -n "$self" ]; then timeout 25 "$self" update --check --json >"$tmpd/update.json" 2>/dev/null || echo '{}' >"$tmpd/update.json"
  else timeout 25 bash "$0" update --check --json >"$tmpd/update.json" 2>/dev/null || echo '{}' >"$tmpd/update.json"; fi
  [ -s "$tmpd/update.json" ] || echo '{}' >"$tmpd/update.json"

  DIGEST_TASKS_F="$tmpd/tasks.json" DIGEST_USAGE_F="$tmpd/usage.json" DIGEST_HB_F="$tmpd/hb.txt" \
  DIGEST_LOOPS_F="$tmpd/loops.json" DIGEST_SUP_F="$tmpd/sup.json" DIGEST_OBJ_F="$tmpd/obj.json" \
  DIGEST_UPDATE_F="$tmpd/update.json" DIGEST_HELD_F="$tmpd/held.json" \
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
    # DIVE-2556: `assignee` is the row's CURRENT owner, and on a maker/verifier
    # loop it moves to the VERIFIER at delivery — the verifier then closes the
    # row, so it is still theirs at close. Crediting a completion to `assignee`
    # therefore credits the grader and zeroes the builder: measured 2026-08-03,
    # dev built 10 of the 28 rows closed in 24h and its credited count was 0.
    # Fall back to `assignee` rather than swapping to maker_agent outright —
    # maker_agent is NULL on every row that never ran a loop, and those rows
    # would vanish from the count entirely.
    maker = t.get("maker_agent") or who
    ver = t.get("verifier") or ""
    return {"ident": t.get("ident"), "title": (t.get("title") or "").strip(),
            "assignee": who, "maker": maker, "verifier": ver,
            "ask": (t.get("ask") or "").strip(),
            "need_type": t.get("need_type")}

done_l = [line(t) for t in done]
ip_l = [line(t) for t in in_progress]
blk_l = [line(t) for t in blocked]

# DIVE-2556: maker and verifier as two SEPARATE series, never one merged
# per-owner tally. A row that was built by one agent and graded by another is a
# unit of work for both, counted under each — summing byMaker gives the fleet's
# build throughput, summing byVerifier its review load, and neither number is
# the other's. Keyed on the same COALESCE(maker_agent, assignee) as the lines
# above so a loopless row still lands on whoever holds it.
def _tally(items, key):
    d = {}
    for x in items:
        k = x.get(key)
        if k:
            d[k] = d.get(k, 0) + 1
    return dict(sorted(d.items(), key=lambda kv: (-kv[1], kv[0])))
throughput = {"byMaker": _tally(done_l, "maker"), "byVerifier": _tally(done_l, "verifier")}

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
#
# DIVE-1937: the burn block and the health line both rest on a read that can be
# SHORT — usage_collect only sees the transcripts its caller may read (DIVE-1929)
# — so the coverage the collector reports travels with the numbers here too. An
# absent coverage key is treated as partial, not as complete: an unlabelled total
# is indistinguishable from a truncated one, which is how this shipped.
usage_cov = usage_data.get("coverage") if isinstance(usage_data, dict) else None
if not isinstance(usage_cov, dict):
    usage_cov = {"agentsExpected": None, "agentsRead": None, "unreadable": [],
                 "complete": False, "unavailable": False,
                 "reason": "the usage collector reported no coverage — an unlabelled "
                           "total cannot be told apart from a partial read"}
usage_complete = bool(usage_cov.get("complete"))
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

# DIVE-3501: tier-guard stranded seats. Breach-only — an empty list means no seat
# is stranded, and the rendered block is omitted rather than printing a reassuring
# "0 stranded" line every day (a monitor with a daily all-clear stops being read).
held_data = load("DIGEST_HELD_F", {"seats": []})
held_seats = held_data.get("seats", []) if isinstance(held_data, dict) else []

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

# DIVE-1921: this was a `>=` ladder — `"7 days" if window >= 604800 else "24h"`
# — so ANY window wider than a week rendered under a "last 7 days" header. The
# headline of the digest would have asserted a span it did not measure, and the
# scorecard downstream reads this label. Derive it from the window instead, with
# a computed fallback so a future width can never silently borrow another's name.
_WINDOW_LABELS = {86400: "24h", 604800: "7 days", 2592000: "30 days"}
window_label = _WINDOW_LABELS.get(window) or f"{max(1, round(window / 86400))} days"

# DIVE-1921: the window scopes the sums and the rates; it does NOT scope the
# point readings (see the header block). Naming them in the payload is what
# stops a consumer applying `window.label` to a number it does not describe —
# `usage` is usage_collect's own 5h/7d rolling read, `loops` is every loop ever.
point_in_time = {
    "inProgress":    "current status, not a window count",
    "blocked":       "current status, not a window count",
    "usage":         "usage_collect's own rolling 5h/7d limits — never this window",
    "usageCoverage": "describes the usage read above, same rolling scope",
    "health":        "freshness and rate-limit pressure as of now",
    "cli":           "version-delivery reading as of now, and for THIS box only — never a fleet aggregate",
    "loops":         "every loop the fleet has run (--all), not a window slice",
    "stuck.openStuck":       "agents wedged right now",
    "autonomy.uptimeDays":   "all-time streak since the last human-blocking gate",
    "objectives[].current":  "latest reading; only .trend/.baseline use the window",
    "objectives[].inflight": "open linked tasks as of now",
}

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
# DIVE-1921: the trend compares this window against the one before it, so a 30d
# reading reaches 60 days back. If the store does not go that far, the prior
# counts are a PARTIAL span reported as a whole one and the arrow overstates the
# improvement — the wider the window, the more likely that is. Say so rather
# than render a flattering delta: the earliest row we hold has to predate the
# prior window's start for the comparison to be like-for-like.
_first_seen = [x for x in (to_epoch(t.get("created_at")) for t in work if t.get("created_at")) if x]
prior_complete = bool(_first_seen) and min(_first_seen) <= (since - window)
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
            "priorShipped": prev_ship, "priorAsked": prev_ask, "windowLabel": window_label,
            "priorWindowComplete": prior_complete}

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

# DIVE-2306: the fleet's version-delivery reading, from `update --check`.
#
# Three of its fields are things NO other line in this digest can report, and
# each is false-or-absent in the states the rest of the health block calls
# healthy: `frozen` (this box's CLI has not moved in 7d+ — what a dead release
# cutter looks like from here), `ahead` (this box is past the newest release and
# the installer refuses to move it), and `frozenArmed:false` (this box cannot
# record the observation, so its freeze reading can never leave `unknown`).
#
# Rendered only when one of them is live. A digest line that says "releases are
# fine" every day is a line nobody reads on the day it matters, and `behind` is
# already covered by the box's own update banner.
upd = load("DIGEST_UPDATE_F", {})
if not isinstance(upd, dict):
    upd = {}
cli_frozen = upd.get("frozen")
cli_ahead = upd.get("ahead") is True
# Strictly `is False`: a pre-DIVE-2306 CLI omits the field, and a missing field
# is "not observed", never "armed".
cli_unarmed = upd.get("frozenArmed") is False
cli_alarm = bool(cli_frozen == "frozen" or cli_ahead or cli_unarmed)
cli_block = {
    "current": upd.get("current"), "latest": upd.get("latest"),
    "behind": upd.get("behind"), "ahead": upd.get("ahead"),
    "frozen": cli_frozen if cli_frozen is not None else "unknown",
    "frozenAgeSec": upd.get("frozenAgeSec"),
    "frozenDetail": upd.get("frozenDetail"),
    "frozenArmed": upd.get("frozenArmed"),
    # The reading is one box's. "The fleet has stopped" is still an inference a
    # reader makes from several boxes agreeing — say the scope rather than let
    # the word "fleet" in the rendered line imply an aggregate we never took.
    "scope": "this box only — not a fleet aggregate",
    "read": bool(upd),
}

if as_json:
    print(json.dumps({
        "window": {"since": since, "now": now, "label": window_label,
                   "seconds": window, "days": round(window / 86400, 2)},
        "pointInTime": point_in_time,
        "objectives": objectives,
        "done": done_l, "inProgress": ip_l, "blocked": blk_l, "autoCleared": auto_l,
        "throughput": throughput,
        "zeroHuman": {"shipped": len(done_l), "humanTouches": len(ht_l), "gates": ht_l},
        "autonomy": autonomy,
        "precedentPrefill": {"count": len(prefilled), "accepted": len(accepted),
                             "acceptanceRate": prefill_rate,
                             "byKind": {"exact": prefill_exact, "fuzzy": prefill_fuzzy}},
        "usage": usage_l, "usageCoverage": usage_cov,
        "cli": cli_block,
        "health": {"stale": stale, "hot": [h["name"] for h in hot],
                   # DIVE-1937: `hot` is only a claim about what was READ. A
                   # consumer must not read an empty list as "nobody is hot".
                   "hotCoverage": "complete" if usage_complete else "partial",
                   # DIVE-3501: [] means measured-and-none, not unmeasured — the
                   # predicate is a pure query over tasks + the registry.
                   "tierHeldSeats": held_seats},
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
        # DIVE-1921: a prior window the store does not fully cover is a partial
        # span; saying so costs one word and stops the arrow reading as growth.
        partial = "" if prior_complete else ", a span the store does not fully cover"
        return f" ({arrow}{abs(d)} vs {prev} prior {window_label}{partial})"
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
        # DIVE-2556: name the MAKER, and the verifier beside it when they differ.
        # The old line printed `assignee`, which on a graded row is the verifier.
        cred = t["maker"]
        if t["verifier"] and t["verifier"] != t["maker"]:
            cred += f" (verified by {t['verifier']})"
        out.append(f"  • {t['ident']} {short(t['title'])} — {cred}")
    if not done_l:
        out.append("  (nothing closed)")
    if len(done_l) > 8:
        out.append(f"  … +{len(done_l) - 8} more")
    if throughput["byMaker"]:
        _bm = ", ".join(f"{k} {v}" for k, v in list(throughput["byMaker"].items())[:6])
        out.append(f"  built by: {_bm}")
    if throughput["byVerifier"]:
        _bv = ", ".join(f"{k} {v}" for k, v in list(throughput["byVerifier"].items())[:6])
        out.append(f"  verified by: {_bv}")
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
        # DIVE-1921: `usage loops --all` is every loop the fleet has run, so this
        # total is NOT a slice of the window it is printed under. Say which.
        out.append(f"\U0001F504 Loop burn ({_htok(loops_total)} tok{cap_note}, all loops — not the {window_label})")
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
    # DIVE-1937: say what the burn read COVERED before any claim that rests on it.
    if not usage_complete:
        if usage_cov.get("unavailable"):
            out.append("\U0001F512 Token burn UNKNOWN — " + str(usage_cov.get("reason") or
                       "the usage source could not be read") + ". Unknown is not zero.")
        else:
            u = usage_cov.get("unreadable") or []
            named = ", ".join(x.get("name", "?") for x in u[:4])
            more = f" +{len(u) - 4} more" if len(u) > 4 else ""
            read, exp = usage_cov.get("agentsRead"), usage_cov.get("agentsExpected")
            span = (f"{read} of {exp}" if read is not None and exp is not None else "an unknown share of")
            out.append(f"\U0001F512 Token burn PARTIAL — {span} agent transcript sets readable"
                       + (f" (missing: {named}{more})" if named else "")
                       + ". The burn figures are a floor, not the fleet.")
    # DIVE-2306: the version-delivery alarms, in the same block as the other
    # as-of-now health readings. Placed BEFORE the "Fleet healthy" line on
    # purpose — that line is about heartbeats and rate limits and is free to say
    # healthy while nothing has shipped to the box in a week, which is exactly
    # the pair of statements that has to be readable together.
    if cli_frozen == "frozen":
        out.append("\U0001F9CA Fleet freeze — " + str(cli_block["frozenDetail"] or
                   f"CLI {cli_block['current']} has not been observed to change")
                   + ". No release has reached this box; check the release cutter"
                     " (this box only, not a fleet aggregate).")
    if cli_ahead:
        out.append(f"⬆️ CLI {cli_block['current']} is AHEAD of the newest release "
                   f"{cli_block['latest']} — the installer will refuse to move it "
                   "(a release cut is owed).")
    if cli_unarmed:
        out.append("\U0001F6A8 Version-freeze alarm UNARMED on this box — " +
                   str(cli_block["frozenDetail"] or "the observation cannot be recorded") +
                   ". Until a caller that can write it runs, a frozen fleet reads here as silence.")
    if stale:
        out.append("\U0001F634 Heartbeat stale: " + ", ".join(stale))
    # DIVE-3501: placed with the other as-of-now health readings and BEFORE the
    # "Fleet healthy" line, for the same reason the freeze alarm is — that line
    # is about heartbeats and rate limits and will happily say healthy while a
    # seat has had zero runnable work for six days. The two have to read together.
    for hs in held_seats:
        ids = ", ".join(hs.get("idents") or []) or "no idents recorded"
        out.append(f"\U0001F6D1 {hs.get('agent')} is STRANDED — all {hs.get('heldCount')} "
                   f"runnable row(s) held by the tier guard, idle {hs.get('stalledHours')}h: {ids}. "
                   f"Exit: 5dive task assign <id> <equal-or-higher-tier agent>, or "
                   f"5dive heartbeat wake-task {hs.get('agent')} <task_id>.")
    if not hot and not stale:
        # "no rate-limit pressure" is a claim about every agent. It may only be
        # made when every agent was actually read (DIVE-1937).
        if usage_complete:
            out.append("\U0001F49A Fleet healthy — heartbeats fresh, no rate-limit pressure")
        else:
            out.append("\U0001F49B Heartbeats fresh; rate-limit pressure UNVERIFIED — "
                       "the burn read above was short of the fleet")
    # DIVE-1921: the header says "last {window_label}" and most of the body honours
    # it — but token burn, loop burn and the in-progress/blocked/still-stuck counts
    # are as-of-now readings that do not move with the window. Under a 30d header
    # that gap is wide enough to be read as a claim, so it gets stated once.
    out.append(f"\U0001F4CF Window — sums and rates above cover the last {window_label}; "
               "token burn (5h/7d rolling), loop burn, in-progress/needs-you and "
               "still-stuck are as-of-now readings, unchanged by the window.")
    print("\n".join(out))
PY

  # DIVE-3318 clause 3: the per-sender send/bytes split and live round pressure.
  # Appended to the rendered text rather than threaded through the python block,
  # because its two sources (the audit log and the round ledger) are files this
  # shell can read and the renderer deliberately takes only staged JSON.
  #
  # TEXT MODE ONLY. `out.txt` holds a JSON DOCUMENT under --json, and appending a
  # text block to it produces a file that is neither — which is not a cosmetic
  # defect: `5dive proof` parses `digest --json` and died on a traceback
  # (tests/rollback_rate_unit.sh, 35/35 on origin/main -> 33/35 with the
  # unconditional append). A machine-readable stream has exactly one shape.
  if [ "$as_json" != 1 ]; then
    a2a_rounds_report "$window" >>"$tmpd/out.txt" 2>/dev/null || true
  fi

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
