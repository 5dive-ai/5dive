# cmd_usage — per-agent / per-task token visibility for subscription agents.
#
# WHY this exists: our agents (and our customers') run on the Claude
# *subscription*, not the metered API. The only ceiling that matters is the
# 5h / 7d rate limit (the thing that hit "30% in a day"), and the only
# ground-truth signal for who burned it is each agent's Claude Code session
# transcript — every assistant turn logs message.usage (input / output / cache
# tokens) + message.model + a timestamp. We sum those locally, attribute turns
# to tasks by matching turn timestamps against the task queue's started/done
# windows, and surface top agents + top tasks at a glance.
#
# DELIBERATELY NO DOLLARS. Subscription inference has no per-token price for the
# user, so a "$" column would be fiction. We speak in tokens + share-of-limit.
#
# Read-only: scans sibling agent homes (root) + the shared task DB. No registry
# mutation, no lock, no audit — same posture as `account usage`.

# usage_window_secs <flagword> — map a window flag to seconds (default 24h).
usage_window_secs() {
  case "${1:-}" in
    7d|--7d|week)  echo 604800 ;;
    24h|--24h|day) echo 86400 ;;
    *)            echo 86400 ;;
  esac
}

# usage_collect <since_epoch> — emit one JSON object aggregating every claude
# agent's token usage in the window, joined to the task queue. Shape:
#   {window:{since,now}, agents:[{name,account,models:{<model>:{in,out,cc,cr,turns}},
#            total,output,sevenDayPct,fiveHourPct}],
#    tasks:[{ident,title,assignee,total,output,turns}],
#    untracked:{<assignee>:{total,output}}}
# All token fields are raw integers; the presentation layer formats + sorts.
usage_collect() {
  local since="$1" db
  db="${TASKS_DB:-${STATE_DIR}/tasks/tasks.db}"
  REGISTRY="$REGISTRY" TASK_DB="$db" USAGE_SINCE="$since" python3 - <<'PY'
import os, json, glob, time, sqlite3, datetime as dt

since = int(os.environ["USAGE_SINCE"])
now   = int(time.time())
registry = os.environ["REGISTRY"]
task_db  = os.environ["TASK_DB"]

def to_epoch(s):
    if not s:
        return None
    s = s.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        d = dt.datetime.fromisoformat(s.replace(" ", "T", 1) if " " in s and "T" not in s else s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return int(d.timestamp())
    except Exception:
        return None

# --- registry: claude agents only (others have no Anthropic transcripts) ---
try:
    reg = json.load(open(registry))
except Exception:
    reg = {"agents": {}}
agents = {n: a for n, a in reg.get("agents", {}).items()
          if a.get("type", "claude") == "claude"}

def home_of(name):
    import pwd
    try:
        return pwd.getpwnam("agent-" + name).pw_dir
    except KeyError:
        return "/home/agent-" + name

# --- scan transcripts: per agent per model token sums + per-turn timeline ---
# turns[name] = list of (epoch, out_tokens, total_tokens) for task attribution.
agent_rows = []
turns_by_agent = {}
for name, meta in agents.items():
    home = home_of(name)
    models = {}
    turns = []
    pat = os.path.join(home, ".claude", "projects", "*", "*.jsonl")
    for path in glob.glob(pat):
        try:
            if os.path.getmtime(path) < since:   # whole file predates window
                continue
        except OSError:
            continue
        try:
            f = open(path, "r", errors="ignore")
        except OSError:
            continue
        with f:
            for line in f:
                if '"usage"' not in line or '"assistant"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "assistant":
                    continue
                ts = to_epoch(o.get("timestamp"))
                if ts is None or ts < since:
                    continue
                msg = o.get("message") or {}
                u = msg.get("usage") or {}
                model = msg.get("model") or "unknown"
                i  = int(u.get("input_tokens") or 0)
                ot = int(u.get("output_tokens") or 0)
                cc = int(u.get("cache_creation_input_tokens") or 0)
                cr = int(u.get("cache_read_input_tokens") or 0)
                m = models.setdefault(model, {"in":0,"out":0,"cc":0,"cr":0,"turns":0})
                m["in"]+=i; m["out"]+=ot; m["cc"]+=cc; m["cr"]+=cr; m["turns"]+=1
                turns.append((ts, ot, i+ot+cc))   # total excludes cache-read
    if not models:
        continue
    # Headline "total" EXCLUDES cache reads: a cache-read token is ~0.1x weight
    # against the subscription limit, and on agentic workloads it dwarfs real
    # work (100x), which would make the share-of-limit meaningless. We count
    # input + output + cache-write (the tokens that actually move the limit) and
    # keep cache-read visible only in the per-agent detail.
    total  = sum(m["in"]+m["out"]+m["cc"] for m in models.values())
    output = sum(m["out"] for m in models.values())
    cread  = sum(m["cr"] for m in models.values())
    # freshest rate-limit % from the statusline cache (the live 5h/7d numbers).
    five = seven = None
    cache = os.path.join(home, ".claude", "statusline-last.json")
    try:
        sc = json.load(open(cache))
        rl = sc.get("rate_limits") or {}
        five  = (rl.get("five_hour") or {}).get("used_percentage")
        seven = (rl.get("seven_day") or {}).get("used_percentage")
    except Exception:
        pass
    agent_rows.append({
        "name": name, "account": meta.get("authProfile"),
        "models": models, "total": total, "output": output, "cacheRead": cread,
        "fiveHourPct": five, "sevenDayPct": seven,
    })
    turns_by_agent[name] = sorted(turns)

# --- task attribution: assign each turn to the task open for that assignee ---
tasks = []
untracked = {}
try:
    con = sqlite3.connect(task_db)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT ident,title,assignee,started_at,done_at,iteration FROM tasks "
        "WHERE started_at IS NOT NULL AND assignee IS NOT NULL"
    ).fetchall()
    con.close()
except Exception:
    rows = []

# windows per assignee, newest-started first (so an overlapping turn lands on
# the most-recently-started task).
wins = {}
for r in rows:
    a = r["assignee"]
    s = to_epoch(r["started_at"])
    if s is None:
        continue
    e = to_epoch(r["done_at"]) or now
    wins.setdefault(a, []).append({
        "ident": r["ident"], "title": r["title"] or "",
        "start": s, "end": e, "total": 0, "output": 0, "turns": 0,
        "iteration": r["iteration"],   # DIVE-478: maker→verifier loop round (NULL if not a loop)
    })
for a in wins:
    wins[a].sort(key=lambda w: w["start"], reverse=True)

for name, turns in turns_by_agent.items():
    ws = wins.get(name, [])
    for ts, out, tot in turns:
        hit = None
        for w in ws:
            if w["start"] <= ts <= w["end"]:
                hit = w
                break
        if hit:
            hit["total"]+=tot; hit["output"]+=out; hit["turns"]+=1
        else:
            u = untracked.setdefault(name, {"total":0,"output":0})
            u["total"]+=tot; u["output"]+=out

for a in wins:
    for w in wins[a]:
        if w["turns"]:
            tasks.append({"ident":w["ident"],"title":w["title"],"assignee":a,
                          "total":w["total"],"output":w["output"],"turns":w["turns"],
                          "iteration":w["iteration"]})

print(json.dumps({
    "window": {"since": since, "now": now},
    "agents": agent_rows, "tasks": tasks, "untracked": untracked,
}))
PY
}

# usage_fmt_tokens — jq filter snippet: humanize an integer token count.
# (defined as a jq function string reused by the presenters)
USAGE_JQ_HELPERS='
  def htok: if . == null then "-"
            elif . >= 1000000 then ((. / 1000000 * 10 | floor) / 10 | tostring) + "M"
            elif . >= 1000 then ((. / 1000 * 10 | floor) / 10 | tostring) + "k"
            else (. | tostring) end;
  def pct(x): if x == null then "-" else ((x | floor | tostring) + "%") end;
  def shortmodel: if . == null then "-"
                  else (sub("^claude-";"") | sub("-20[0-9]+$";"")) end;
'

# cmd_usage — entry point. Dispatches budget subcommand, else renders the board
# (no agent arg) or a single-agent detail view.
cmd_usage() {
  # loops subcommand (DIVE-597): token spend aggregated over the LOOP-7
  # loop_runs table — the cost side of the loop control window. Read-only over
  # the shared (group-readable) tasks.db like `task loops`, so NO root needed —
  # handled before ensure_state's require_root.
  if [[ "${1:-}" == "loops" ]]; then
    shift
    cmd_usage_loops "$@"
    return
  fi

  ensure_state

  # budget subcommand is handled separately (its own store + writes).
  if [[ "${1:-}" == "budget" ]]; then
    shift
    cmd_usage_budget "$@"
    return
  fi

  require_root

  local agent="" win_flag="24h"
  local args=()
  for a in "$@"; do
    case "$a" in
      --7d|7d|--week)  win_flag="7d" ;;
      --24h|24h|--day) win_flag="24h" ;;
      --*)             fail "$E_USAGE" "unknown flag: $a" ;;
      *)               args+=("$a") ;;
    esac
  done
  [[ ${#args[@]} -le 1 ]] || fail "$E_USAGE" "usage: 5dive usage [<agent>] [--7d] [--json]"
  [[ ${#args[@]} -eq 1 ]] && agent="${args[0]}"

  local since now data budgets
  since=$(( $(date +%s) - $(usage_window_secs "$win_flag") ))
  data=$(usage_collect "$since") || fail "$E_GENERIC" "failed to collect usage"
  budgets=$(usage_budget_load)

  if [[ -n "$agent" ]]; then
    usage_render_agent "$data" "$agent" "$win_flag"
  else
    usage_render_board "$data" "$win_flag" "$budgets"
  fi
}

# usage_render_board — top agents + top tasks, sorted by tokens descending.
usage_render_board() {
  local data="$1" win="$2" budgets="$3"
  if (( JSON_MODE )); then
    jq -c --argjson b "$budgets" --arg win "$win" \
      '{ok:true, data: (. + {budgets:$b, windowLabel:$win})}' <<<"$data"
    return
  fi
  local label; [[ "$win" == "7d" ]] && label="last 7d" || label="last 24h"
  echo "TOP AGENTS — $label  (subscription tokens; no \$ — these run on the plan)"
  jq -r "$USAGE_JQ_HELPERS"'
    # per-account totals → each agent gets a share of its account 7d limit.
    (reduce .agents[] as $a ({}; .[$a.account // "-"] += $a.total)) as $acct
    | if (.agents | length) == 0 then "  (no claude-agent transcripts in window)"
      else
      (["AGENT","MODEL","OUTPUT","TOTAL","7D%","SHARE"] | @tsv),
      (.agents | sort_by(-.total)[] |
        (.models | to_entries | max_by(.value.out).key | shortmodel) as $m |
        (if (.sevenDayPct != null and ($acct[.account // "-"] // 0) > 0)
         then ((.total / $acct[.account // "-"]) * .sevenDayPct) else null end) as $share |
        [ .name, $m, (.output|htok), (.total|htok),
          pct(.sevenDayPct), (if $share==null then "-" else (($share|floor|tostring)+"%") end)
        ] | @tsv)
      end' <<<"$data" | column -t -s $'\t' | sed 's/^/  /'

  echo
  echo "TOP TASKS — $label"
  jq -r "$USAGE_JQ_HELPERS"'
    if (.tasks | length) == 0 then "  (no task-attributed turns in window)"
    else
      (["TASK","AGENT","ITER","OUTPUT","TOTAL","TITLE"] | @tsv),
      (.tasks | sort_by(-.total)[:12][] |
        [ .ident, .assignee,
          (if (.iteration // 0) > 0 then (.iteration|tostring) else "-" end),
          (.output|htok), (.total|htok),
          (.title | if length > 42 then .[:41] + "…" else . end) ] | @tsv)
    end' <<<"$data" | column -t -s $'\t' | sed 's/^/  /'

  # over-budget callout (soft, visibility-only — no throttle).
  local over
  over=$(jq -r --argjson b "$budgets" '
    (reduce .agents[] as $a ({}; .[$a.name] = $a.total)) as $tot
    | [ $b | to_entries[] | select(($tot[.key] // 0) > .value)
        | "  ⚠ " + .key + " over budget: " + (($tot[.key]//0)|tostring) + " > " + (.value|tostring) + " tok" ]
    | .[]' <<<"$data" 2>/dev/null)
  [[ -n "$over" ]] && { echo; echo "$over"; }
}

# usage_render_agent — one agent: per-model breakdown + its tasks in window.
usage_render_agent() {
  local data="$1" agent="$2" win="$3"
  local row
  row=$(jq -c --arg n "$agent" '.agents[] | select(.name == $n)' <<<"$data")
  [[ -n "$row" ]] || fail "$E_GENERIC" "no usage for agent '$agent' in window (or not a claude agent)"
  if (( JSON_MODE )); then
    jq -c --arg n "$agent" \
      '{ok:true, data: {agent:$n, usage:(.agents[]|select(.name==$n)),
        tasks:[.tasks[]|select(.assignee==$n)],
        untracked:(.untracked[$n] // null)}}' <<<"$data"
    return
  fi
  local label; [[ "$win" == "7d" ]] && label="last 7d" || label="last 24h"
  echo "$agent — $label"
  jq -r "$USAGE_JQ_HELPERS"'
    (["MODEL","IN","OUT","CACHE-W","CACHE-R","TURNS"] | @tsv),
    (.models | to_entries
       | map(select((.value.in + .value.out + .value.cc + .value.cr) > 0))
       | sort_by(-.value.out)[] |
      [ (.key|shortmodel), (.value.in|htok), (.value.out|htok),
        (.value.cc|htok), (.value.cr|htok), (.value.turns|tostring) ] | @tsv)
    ' <<<"$row" | column -t -s $'\t' | sed 's/^/  /'
  jq -r "$USAGE_JQ_HELPERS"'
    "  total (input+output+cache-write, excl. cache-read): " + (.total|htok)
    + "   |   cache-read: " + (.cacheRead|htok)' <<<"$row"
  echo
  echo "  tasks ($label):"
  jq -r "$USAGE_JQ_HELPERS"'
    if (.tasks | map(select(.assignee==$n)) | length) == 0 then "    (none attributed)"
    else (.tasks | map(select(.assignee==$n)) | sort_by(-.total)[] |
      "    " + .ident + "  " + (.total|htok) + "  " + .title) end
    ' --arg n "$agent" <<<"$data"
}

# --- loop token aggregation (DIVE-597) ---------------------------------------
# Read-only roll-up of loop_runs.tokens_spent — the cost side of the LOOP-7
# control window (pairs with `task loops`, which shows iteration/status/kill).
# Default: per-topology summary (loops, total tokens, ceiling sum) + a grand
# total. --by-loop: one row per loop run. --all includes finished loops
# (default: running only). JSON: {ok, data:{scope, total, byTopology|loops}}.
cmd_usage_loops() {
  tasks_db_init
  local by_loop=0 show_all=0
  local a
  for a in "$@"; do
    case "$a" in
      --by-loop) by_loop=1 ;;
      --all)     show_all=1 ;;
      *)         fail "$E_USAGE" "unknown flag: $a (usage loops [--by-loop] [--all])" ;;
    esac
  done
  local w="status='running'"; (( show_all )) && w="1=1"
  local total; total=$(db "SELECT COALESCE(SUM(tokens_spent),0) FROM loop_runs WHERE ${w};")

  if (( by_loop )); then
    if (( JSON_MODE )); then
      local rows; rows=$(dbfmt -json "SELECT loop_id, topology, status,
               COALESCE(tokens_spent,0) AS tokens, ceiling
             FROM loop_runs WHERE ${w} ORDER BY tokens_spent DESC, started_at DESC;")
      [[ -n "$rows" ]] || rows="[]"
      jq -cn --argjson r "$rows" --argjson t "${total:-0}" '{ok:true, data:{scope:"by-loop", total:$t, loops:$r}}'
    else
      dbfmt -box "SELECT loop_id, topology, status,
               COALESCE(tokens_spent,0)||'/'||COALESCE(CAST(ceiling AS TEXT),'∞') AS tokens
             FROM loop_runs WHERE ${w} ORDER BY tokens_spent DESC, started_at DESC;"
      printf 'total: %s tokens\n' "${total:-0}"
    fi
    return
  fi

  if (( JSON_MODE )); then
    local rows; rows=$(dbfmt -json "SELECT topology, COUNT(*) AS loops,
               COALESCE(SUM(tokens_spent),0) AS tokens, COALESCE(SUM(ceiling),0) AS ceiling
             FROM loop_runs WHERE ${w} GROUP BY topology ORDER BY tokens DESC;")
    [[ -n "$rows" ]] || rows="[]"
    jq -cn --argjson r "$rows" --argjson t "${total:-0}" '{ok:true, data:{scope:"by-topology", total:$t, byTopology:$r}}'
  else
    dbfmt -box "SELECT topology, COUNT(*) AS loops,
               COALESCE(SUM(tokens_spent),0) AS tokens, COALESCE(SUM(ceiling),0) AS ceiling
             FROM loop_runs WHERE ${w} GROUP BY topology ORDER BY tokens DESC;"
    printf 'total: %s tokens\n' "${total:-0}"
  fi
}

# --- soft per-agent token budgets (visibility-only; no hard throttle) ---------
# Store: ${STATE_DIR}/usage-budgets.json = {"<agent>": <daily_token_limit>}.
# A budget is a 24h token ceiling. We surface an over-budget ⚠ on the board;
# we never pause or rate-limit an agent (matches the "soft cap" intent — a hard
# kill on a working agent is the wrong kind of insurance).
USAGE_BUDGETS_FILE="${STATE_DIR}/usage-budgets.json"

usage_budget_load() {
  [[ -s "$USAGE_BUDGETS_FILE" ]] && cat "$USAGE_BUDGETS_FILE" 2>/dev/null || echo '{}'
}

cmd_usage_budget() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    ls|list)
      local b; b=$(usage_budget_load)
      if (( JSON_MODE )); then jq -c '{ok:true,data:.}' <<<"$b"; return; fi
      jq -r 'if length==0 then "no budgets set (5dive usage budget set <agent> --daily=<tokens>)"
             else (["AGENT","DAILY_TOKEN_BUDGET"]|@tsv),
                  (to_entries[]|[.key,(.value|tostring)]|@tsv) end' <<<"$b" \
        | column -t -s $'\t'
      ;;
    set)
      require_root
      local agent="" daily=""
      for a in "$@"; do
        case "$a" in
          --daily=*) daily="${a#--daily=}" ;;
          --*) fail "$E_USAGE" "unknown flag: $a" ;;
          *) agent="$a" ;;
        esac
      done
      [[ -n "$agent" ]] || fail "$E_USAGE" "usage: 5dive usage budget set <agent> --daily=<tokens>"
      [[ "$daily" =~ ^[0-9]+$ ]] || fail "$E_USAGE" "--daily must be an integer token count"
      local b; b=$(usage_budget_load)
      b=$(jq -c --arg n "$agent" --argjson v "$daily" '.[$n]=$v' <<<"$b") \
        || fail "$E_GENERIC" "failed to update budget"
      printf '%s\n' "$b" > "$USAGE_BUDGETS_FILE"
      chmod 0664 "$USAGE_BUDGETS_FILE" 2>/dev/null || true
      ok "budget set: $agent = $daily tok/24h" "$(jq -c --arg n "$agent" --argjson v "$daily" '{agent:$n,daily:$v}' <<<'{}')"
      ;;
    clear|rm|unset)
      require_root
      local agent="${1:-}"
      [[ -n "$agent" ]] || fail "$E_USAGE" "usage: 5dive usage budget clear <agent>"
      local b; b=$(usage_budget_load)
      b=$(jq -c --arg n "$agent" 'del(.[$n])' <<<"$b")
      printf '%s\n' "$b" > "$USAGE_BUDGETS_FILE"
      ok "budget cleared: $agent" "$(jq -c --arg n "$agent" '{agent:$n,cleared:true}' <<<'{}')"
      ;;
    *) fail "$E_USAGE" "unknown budget command: $sub (set|ls|clear)" ;;
  esac
}
