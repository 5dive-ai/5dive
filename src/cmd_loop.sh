
# -------- loops (LOOP-7) — agent-native multi-agent orchestration --------
#
# Verbs: spawn · verify · panel · map · until-dry · collect, all honoring
# --ceiling (per-loop token budget) and feeding the `task loops` control window
# (loop_runs board + --kill) and `usage loops` (token roll-up). The loops
# SKILL.md contract lives in the 5dive-ai/skills repo (loops/SKILL.md).
# Unit harnesses: tests/loop_*_unit.sh.
#
# Verbs wrap the EXISTING fleet primitives (no new in-process engine):
#   maker->verifier  = task add --verifier / task verify / task reject (DIVE-474)
#   control + kill    = task loops (DIVE-478) over the new loop_runs table
#   token accounting  = 5dive usage plumbing -> loop_runs.tokens_spent
# All verbs emit ONE json line (machine-facing, JSON-in/JSON-out) and honor
# --ceiling (per-loop token budget; low default; escalate-with-proof at limit).

cmd_loop() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    spawn)     cmd_loop_spawn "$@" ;;
    verify)    cmd_loop_verify "$@" ;;
    grade)     cmd_loop_grade "$@" ;;
    panel)     cmd_loop_panel "$@" ;;
    map)       cmd_loop_map "$@" ;;
    until-dry) cmd_loop_until_dry "$@" ;;
    collect)   cmd_loop_collect "$@" ;;
    status)    cmd_loop_status "$@" ;;
    # DIVE-761: marketplace loop packs — install/uninstall a recurring agentic
    # workflow (persona + skills + cadence) onto an agent. Distinct from the
    # orchestration verbs above; shares the `loop` namespace because both are "loops".
    install)   cmd_loop_pack install "$@" ;;
    uninstall) cmd_loop_pack uninstall "$@" ;;
    show)      cmd_loop_pack show "$@" ;;
    help|-h|--help) _loop_help ;;
    *)         fail "$E_USAGE" "unknown loop command: $sub (spawn|verify|grade|panel|map|until-dry|collect|status|install|show)" ;;
  esac
}

# loop_id: a loop-run handle, distinct from a task ident. (Date.now is fine in
# bash; the no-Date constraint is workflow-script-only.)
_loop_new_id() { printf 'L-%s' "$(date +%s)$(printf '%04x' $((RANDOM)))"; }

_loop_help() {
  cat <<'EOF'
5dive loop — agent-native multi-agent orchestration (LOOP-7)

  loop spawn  --role=maker|verifier|worker --agent=<type|name> --prompt="…"
              [--schema=<json>] [--ceiling=<tokens>] [--wait[=<sec>]]
  loop verify --target=<id> --verifier=<agent> [--accept="…"]
  loop grade  --target=<id> --verifier=<agent> [--accept="…"] [--threshold=<0-100>] [--wait]
  loop panel  --n=<k> --lens="correctness,security,repro" --claim="…" --quorum=<m>
  loop map    --over=<json-array> --do=<spawn-spec> [--max-concurrency=<n>]
  loop until-dry --round=<spawn-spec> --stop-after=<K> --dedup-key="…"
  loop collect --handles=<id,id,…>
  loop status  --handle=<loopId>

  loop install <slug> --onto=<agent> [--cron="…"] [--ceiling=<tokens>] [--dry-run]
              install a marketplace loop pack (recurring agentic workflow:
              persona + skills + cadence) onto an agent. loop show <slug> to peek.

  Orchestration verbs: JSON in / JSON out, honor --ceiling (per-loop token budget;
  self-halt + escalate-with-proof at the limit). Humans watch + kill via
  `5dive task loops [--kill <loopId>]`; they never author a loop.
EOF
}

# Built-in LOW ceiling default (tokens) — safe direction per design §4: a loop
# never runs unbounded. Override order: --ceiling > $LOOP_CEILING_DEFAULT env
# (config surface, non-blocking open §7) > this built-in.
_LOOP_CEILING_BUILTIN=200000
_loop_eff_ceiling() {
  local c="$1"
  if [[ -n "$c" ]]; then printf '%s' "$c"; return; fi
  if [[ -n "${LOOP_CEILING_DEFAULT:-}" && "${LOOP_CEILING_DEFAULT}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$LOOP_CEILING_DEFAULT"; return
  fi
  printf '%s' "$_LOOP_CEILING_BUILTIN"
}

# --- live token accounting (DIVE-972: advisory ceiling -> enforceable) --------
# The ceiling was a no-op because nothing ever wrote loop_runs.tokens_spent — it
# defaulted to 0 forever, so every `spent >= ceiling` test read 0 and never
# fired. These helpers implement design §4's "re-read tokens_spent (summed via
# the existing usage plumbing for the child tasks' agents)": we recompute the
# real spend from the child tasks' assignees' transcripts (same limit-moving
# metric as `5dive usage` — input+output+cache-write, cache-read excluded) and
# persist it, turning the token ceiling from advisory into a hard stop.

# _loop_refresh_spend <loop_id> — recompute + persist tokens_spent from the real
# transcript usage of this loop's child tasks; echoes the fresh integer. Heavy
# (scans transcripts), so callers in the hot --wait poll go through _loop_spent,
# which throttles; the heartbeat sweep calls this directly (once per tick).
_loop_refresh_spend() {
  local loop_id="$1"
  local row; row=$(db "SELECT COALESCE(child_task_ids,'[]')||'|'||COALESCE(started_at,0) FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
  [[ -n "$row" ]] || { printf '0'; return; }
  local kids="${row%|*}" since="${row##*|}"
  [[ "$kids" == "[]" || -z "$kids" ]] && { printf '%s' "$(db "SELECT COALESCE(tokens_spent,0) FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")"; return; }
  local dbp="${TASKS_DB:-${STATE_DIR}/tasks/tasks.db}" spent
  spent=$(REGISTRY="$REGISTRY" TASK_DB="$dbp" LOOP_KIDS="$kids" LOOP_SINCE="${since:-0}" python3 - <<'PY' 2>/dev/null || printf '0'
import os, json, glob, time, sqlite3, datetime as dt, pwd
since = int(os.environ.get("LOOP_SINCE") or 0)
now = int(time.time())
try:    kids = [int(x) for x in json.loads(os.environ.get("LOOP_KIDS") or "[]")]
except Exception: kids = []
if not kids:
    print(0); raise SystemExit
def to_epoch(s):
    if not s: return None
    s = s.strip()
    try:
        if s.endswith("Z"): s = s[:-1] + "+00:00"
        d = dt.datetime.fromisoformat(s.replace(" ", "T", 1) if " " in s and "T" not in s else s)
        if d.tzinfo is None: d = d.replace(tzinfo=dt.timezone.utc)
        return int(d.timestamp())
    except Exception: return None
# child tasks -> assignee + window
wins = {}
try:
    con = sqlite3.connect(os.environ["TASK_DB"]); con.row_factory = sqlite3.Row
    q = "SELECT id,assignee,started_at,done_at FROM tasks WHERE id IN (%s)" % ",".join("?"*len(kids))
    for r in con.execute(q, kids).fetchall():
        a = r["assignee"];  s = to_epoch(r["started_at"])
        if not a or s is None: continue
        e = to_epoch(r["done_at"]) or now
        wins.setdefault(a, []).append({"start": max(s, since), "end": e, "tok": 0})
    con.close()
except Exception: pass
for a in wins: wins[a].sort(key=lambda w: w["start"], reverse=True)
try:    reg = json.load(open(os.environ["REGISTRY"]))
except Exception: reg = {"agents": {}}
try:    _HOME_OVR = json.loads(os.environ.get("LOOP_HOME_OVERRIDE_JSON") or "{}")
except Exception: _HOME_OVR = {}
def home_of(name):
    if name in _HOME_OVR: return _HOME_OVR[name]  # test hook; unset in production
    try: return pwd.getpwnam("agent-"+name).pw_dir
    except KeyError: return "/home/agent-"+name
total = 0
for name, ws in wins.items():
    if reg.get("agents", {}).get(name, {}).get("type", "claude") != "claude": continue
    lo = min(w["start"] for w in ws)
    for path in glob.glob(os.path.join(home_of(name), ".claude", "projects", "*", "*.jsonl")):
        try:
            if os.path.getmtime(path) < lo: continue
            f = open(path, "r", errors="ignore")
        except OSError: continue
        with f:
            for line in f:
                if '"usage"' not in line or '"assistant"' not in line: continue
                try: o = json.loads(line)
                except Exception: continue
                if o.get("type") != "assistant": continue
                ts = to_epoch(o.get("timestamp"))
                if ts is None: continue
                u = (o.get("message") or {}).get("usage") or {}
                tot = int(u.get("input_tokens") or 0)+int(u.get("output_tokens") or 0)+int(u.get("cache_creation_input_tokens") or 0)
                for w in ws:  # newest-started window wins (matches usage_collect)
                    if w["start"] <= ts <= w["end"]:
                        w["tok"] += tot; break
    total += sum(w["tok"] for w in ws)
print(int(total))
PY
)
  [[ "$spent" =~ ^[0-9]+$ ]] || spent=0
  db "UPDATE loop_runs SET tokens_spent=${spent}, updated_at=$(date +%s) WHERE loop_id=$(sqlq "$loop_id");" >/dev/null 2>&1 || true
  printf '%s' "$spent"
}

# _loop_spent <loop_id> — throttled live spend for the --wait poll: recompute at
# most once per LOOP_SPEND_THROTTLE (default 20s) per loop, else return the last
# persisted value. Drop-in replacement for the old bare SELECT so every ceiling
# check reads a real number without re-scanning transcripts every poll.
declare -A _LOOP_SPEND_LAST 2>/dev/null || true
_loop_spent() {
  local loop_id="$1" throttle="${LOOP_SPEND_THROTTLE:-20}" now last
  now=$(date +%s); last="${_LOOP_SPEND_LAST[$loop_id]:-0}"
  if (( now - last >= throttle )); then
    _loop_refresh_spend "$loop_id" >/dev/null
    _LOOP_SPEND_LAST[$loop_id]=$now
  fi
  db "SELECT COALESCE(tokens_spent,0) FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");"
}

# DIVE-1349 wake-on-spawn: nudge a freshly loop-spawned task's assignee to START
# it NOW rather than waiting for its next heartbeat tick. Without this a
# `loop spawn --wait` caller — notably the dashboard goal planner, which runs
# `goal add` behind a single HTTP request — holds its socket idle until the tick
# fires, which is what 502s the goals page (see goal-planner-sync-wait-502).
#
# STRICTLY best-effort and side-effect-free on failure: it only ever wakes a real
# ENROLLED agent (a bare loop role/type token like "worker" has no box session),
# skips an agent that is actively working a turn (don't interleave — its own
# heartbeat will queue this task), and swallows every error so a wake that can't
# happen degrades to exactly the old behaviour (heartbeat pickup). Runs the
# privileged wake directly when already root, else re-execs it through `sudo -n`
# from the claude-owned shelld exec context (claude has NOPASSWD). Backgrounded so
# it never delays the spawn's return or the --wait poll.
_loop_wake_agent() {
  local name="$1" task_id="$2" task_ident="$3"
  [[ -n "$name" && -n "$task_id" ]] || return 0
  id -u "agent-${name}" >/dev/null 2>&1 || return 0     # a real box agent, not a type token
  command -v systemctl >/dev/null 2>&1 || return 0
  # Don't interleave a busy agent's live turn — only SKIP on an explicit busy read
  # (rc 1); idle/unknown/blocked all fall through to a wake (best-effort).
  if systemctl is-active --quiet "5dive-agent@${name}.service" 2>/dev/null; then
    _hb_agent_idle "$name" >/dev/null 2>&1; [[ $? -eq 1 ]] && return 0
  fi
  if [[ $EUID -eq 0 ]]; then
    _hb_wake "$name" "false" "$task_id" "$task_ident" >/dev/null 2>&1 || true
  else
    sudo -n 5dive heartbeat wake-task "$name" "$task_id" "$task_ident" >/dev/null 2>&1 || true
  fi
  return 0
}

# --- loop spawn (the atom — design §3) ---
# Create a loop_runs row + a backing task (`task add --assignee=<agent>`
# carrying --prompt as body); the heartbeat wakes the agent to work it. Returns
# ONE json line {loopId, handle, status, taskId, taskIdent}. With --wait,
# block-poll the backing task to a terminal state (bounded by the token ceiling
# and by --wait=<sec>), checking kill_requested + tokens_spent between polls;
# on kill or ceiling-breach STOP and escalate-with-proof (never ship best-so-far
# silently). loop_runs.child_task_ids is the authoritative loop→task link that
# `task loops` reads; a trailing body marker tags the task for the woken agent.
cmd_loop_spawn() {
  tasks_db_init
  local role="worker" agent="" prompt="" schema="" ceiling="" project="dive" from=""
  local stage="" wait_flag="" wait_secs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role=*)    role="${1#*=}" ;;
      --agent=*)   agent="${1#*=}" ;;
      --prompt=*)  prompt="${1#*=}" ;;
      --schema=*)  schema="${1#*=}" ;;
      --ceiling=*) ceiling="${1#*=}" ;;
      --project=*) project="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      --stage=*)   stage="${1#*=}" ;;
      --wait)      wait_flag=1 ;;
      --wait=*)    wait_flag=1; wait_secs="${1#*=}" ;;
      --)          shift; break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           fail "$E_USAGE" "loop spawn takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$agent" ]]  || fail "$E_USAGE" "loop spawn: --agent=<type|name> required"
  [[ -n "$prompt" ]] || fail "$E_USAGE" "loop spawn: --prompt=… required"
  case "$role" in maker|verifier|worker) ;; *) fail "$E_VALIDATION" "--role must be maker|verifier|worker (got '$role')" ;; esac
  [[ -z "$ceiling"   || "$ceiling"   =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"
  [[ -z "$wait_secs" || "$wait_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--wait=<seconds> must be a positive integer"
  if [[ -n "$schema" ]]; then
    printf '%s' "$schema" | jq -e . >/dev/null 2>&1 || fail "$E_VALIDATION" "--schema must be valid JSON"
  fi

  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)

  # Backing task: title = role + first prompt line (trimmed); body = full prompt
  # + a machine marker the woken agent reads to know it's a loop task. Reuse
  # `task add` (in JSON mode) so we inherit validation, project resolution,
  # coordinator defaults and trigger-stamped ident — single source of truth.
  local first_line; first_line=$(printf '%s' "$prompt" | head -1 | cut -c1-60)
  local title="loop:${role} — ${first_line}"
  local marker; marker=$(printf '\n\n[loop spawn] loop_id=%s role=%s ceiling=%s' "$loop_id" "$role" "$eff_ceiling")
  [[ -n "$schema" ]] && marker="${marker} schema=present"
  local task_body="${prompt}${marker}"

  local add_json
  add_json=$(JSON_MODE=1 cmd_task_add --assignee="$agent" --project="$project" ${from:+--from="$from"} \
               --body="$task_body" -- "$title") || return $?
  local task_id task_ident
  task_id=$(printf '%s' "$add_json"   | jq -r '.data.id')
  task_ident=$(printf '%s' "$add_json" | jq -r '.data.ident')
  [[ "$task_id" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "loop spawn: backing task create failed ($add_json)"

  # spawned_by_task: the originating task id if we're driving from inside one.
  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)

  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'spawn', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"),
              ${eff_ceiling}, 'running', $(sqlq "[${task_id}]"), ${now}, ${now});"

  # DIVE-1349: wake the assignee to start this task now (best-effort, backgrounded
  # so it never delays the return below or the --wait poll). Fixes the goal-planner
  # -behind-HTTP hang: the planner agent begins its turn in seconds instead of on
  # the next heartbeat tick.
  _loop_wake_agent "$agent" "$task_id" "$task_ident" >/dev/null 2>&1 &

  # No --wait: return the handle immediately (true async fleet semantics).
  if [[ -z "$wait_flag" ]]; then
    ok "loop ${loop_id} spawned → task ${task_ident} (assignee ${agent})" \
       '{loopId:$l, handle:$l, status:"running", role:$r, taskId:($t|tonumber), taskIdent:$ti, assignee:$a, ceiling:($c|tonumber)}' \
       --arg l "$loop_id" --arg r "$role" --arg t "$task_id" --arg ti "$task_ident" --arg a "$agent" --arg c "$eff_ceiling"
    return 0
  fi

  # --wait: block-poll the backing task to terminal, bounded by --wait=<sec>
  # and policed by kill + ceiling. DIVE-1349: the bare-`--wait` default was 1800s
  # (30 min) — far past any gateway/exec timeout, so a `goal add` behind an HTTP
  # request (the dashboard goals page) held the socket until the gateway 502'd.
  # Bounded to LOOP_SPAWN_WAIT_DEFAULT (120s) so a slow plan returns a clean
  # timeout the caller can render, never a 502. Callers needing longer pass an
  # explicit --wait=<sec> (e.g. the goal planner asks for 150s, still in-window).
  local deadline poll="${LOOP_POLL_SECS:-4}"
  if [[ -n "$wait_secs" ]]; then deadline=$(( now + wait_secs )); else deadline=$(( now + ${LOOP_SPAWN_WAIT_DEFAULT:-120} )); fi
  local final_status="running" tstatus="" tresult="" killed="" spent="0"
  while :; do
    local t; t=$(date +%s)
    # kill check (deferred-safe flag flipped by `task loops --kill`)
    killed=$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
    if [[ "$killed" == "1" ]]; then final_status="killed"; break; fi
    # ceiling check
    spent=$(_loop_spent "$loop_id")
    if [[ "${spent:-0}" -ge "$eff_ceiling" ]]; then final_status="escalated"; break; fi
    # terminal-state check on the backing task
    tstatus=$(db "SELECT status FROM tasks WHERE id=${task_id};")
    case "$tstatus" in
      done|rejected|escalated|cancelled) final_status="$tstatus"; break ;;
    esac
    (( t >= deadline )) && { final_status="timeout"; break; }
    sleep "$poll"
  done

  tresult=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${task_id};")
  # Map backing-task terminal state → loop status.
  local loop_status="$final_status"
  case "$final_status" in
    done)               loop_status="done" ;;
    killed)             loop_status="killed" ;;
    escalated|rejected|timeout) loop_status="escalated" ;;
  esac
  local now2; now2=$(date +%s)
  db "UPDATE loop_runs SET status=$(sqlq "$loop_status"), updated_at=${now2},
        result_json=$(sqlq_or_null "$tresult") WHERE loop_id=$(sqlq "$loop_id");"

  # Escalate-with-proof: on kill/ceiling/timeout (NOT a clean done) raise an
  # approval gate on the originating task so a human sees what was tried — never
  # silently return best-so-far (design §4).
  if [[ "$loop_status" == "escalated" || "$loop_status" == "killed" ]] && [[ "$by_task_sql" != "NULL" ]]; then
    cmd_task_need "$by_task_sql" --type=approval \
      --ask="loop ${loop_id} halted (${final_status}, spent ~${spent}tok/${eff_ceiling}) on task ${task_ident}. Continue, adjust ceiling, or stop?" \
      >/dev/null 2>&1 || true
  fi

  ok "loop ${loop_id} ${loop_status} (${final_status}) ← task ${task_ident}" \
     '{loopId:$l, handle:$l, status:$s, role:$r, taskId:($t|tonumber), taskIdent:$ti, ceiling:($c|tonumber), tokensSpent:($sp|tonumber), result:$res}' \
     --arg l "$loop_id" --arg s "$loop_status" --arg r "$role" --arg t "$task_id" --arg ti "$task_ident" \
     --arg c "$eff_ceiling" --arg sp "${spent:-0}" --arg res "$tresult"
  return 0
}

# --- loop verify (maker→verifier wrapper — design §3) ---
# Pure wrapper over the DIVE-474/477 primitive: attach a --verifier (≠ the
# target's assignee — writer≠grader) + acceptance criteria to an EXISTING target
# task, so the maker's `task done` hands off to the grader instead of closing
# (PASS→close, FAIL→`task reject` bounces back to the maker, escalate at
# --max-iters). Registers a loop_runs row (topology=verify) and returns a
# handle; with --wait, block-polls the target to its terminal verdict.
cmd_loop_verify() {
  tasks_db_init
  local target="" verifier="" accept="" max_iters="" ceiling="" from="" stage="" wait_flag="" wait_secs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target=*)    target="${1#*=}" ;;
      --verifier=*)  verifier="${1#*=}" ;;
      --accept=*)    accept="${1#*=}" ;;
      --max-iters=*) max_iters="${1#*=}" ;;
      --ceiling=*)   ceiling="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --stage=*)     stage="${1#*=}" ;;
      --wait)        wait_flag=1 ;;
      --wait=*)      wait_flag=1; wait_secs="${1#*=}" ;;
      --)            shift; break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             fail "$E_USAGE" "loop verify takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$target" ]]   || fail "$E_USAGE" "loop verify: --target=<id|DIVE-N> required"
  [[ -n "$verifier" ]] || fail "$E_USAGE" "loop verify: --verifier=<agent> required"
  [[ -z "$max_iters" || "$max_iters" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  [[ -z "$ceiling"   || "$ceiling"   =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"
  [[ -z "$wait_secs" || "$wait_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--wait=<seconds> must be a positive integer"

  resolve_task_id "$target"   # sets RESOLVED_TASK_ID or fails
  local tid="$RESOLVED_TASK_ID"
  local tassignee tstatus tident
  tassignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
  tstatus=$(db "SELECT status FROM tasks WHERE id=${tid};")
  tident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  # writer≠grader: the verifier must differ from the maker (target's assignee).
  [[ "$verifier" != "$tassignee" ]] || fail "$E_VALIDATION" "verifier must differ from the target's assignee ('$tassignee') — writer≠grader"
  # the verifier must be attached BEFORE the maker closes; a terminal target
  # can't be retro-graded via the handoff.
  case "$tstatus" in
    done|cancelled) fail "$E_VALIDATION" "target ${tident} is already ${tstatus} — attach a verifier before the maker closes it" ;;
  esac

  # Attach verifier (+ optional acceptance/max-iters) to the target. Direct
  # UPDATE, same pattern as `task assign`; the DIVE-477 routing reads these.
  db "UPDATE tasks SET verifier=$(sqlq "$verifier")$(
        [[ -n "$accept" ]] && printf ', acceptance_criteria=%s' "$(sqlq "$accept")"
      )$(
        [[ -n "$max_iters" ]] && printf ', max_iterations=%s' "$max_iters"
      ) WHERE id=${tid};"

  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)
  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)
  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'verify', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"),
              ${eff_ceiling}, 'running', $(sqlq "[${tid}]"), ${now}, ${now});"

  if [[ -z "$wait_flag" ]]; then
    ok "loop ${loop_id} verifying ${tident} (verifier ${verifier})" \
       '{loopId:$l, handle:$l, status:"verifying", target:($t|tonumber), targetIdent:$ti, verifier:$v, ceiling:($c|tonumber)}' \
       --arg l "$loop_id" --arg t "$tid" --arg ti "$tident" --arg v "$verifier" --arg c "$eff_ceiling"
    return 0
  fi

  # --wait: block-poll the target to a terminal VERDICT. A 'rejected' bounce is
  # NOT terminal (it loops back to the maker); only done (PASS) or escalated
  # (max-iters exhausted) end the verify loop. Policed by kill + ceiling.
  local deadline poll="${LOOP_POLL_SECS:-4}"
  if [[ -n "$wait_secs" ]]; then deadline=$(( now + wait_secs )); else deadline=$(( now + 1800 )); fi
  local final_status="running" killed="" spent="0"
  while :; do
    local t; t=$(date +%s)
    killed=$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
    if [[ "$killed" == "1" ]]; then final_status="killed"; break; fi
    spent=$(_loop_spent "$loop_id")
    if [[ "${spent:-0}" -ge "$eff_ceiling" ]]; then final_status="escalated"; break; fi
    tstatus=$(db "SELECT status FROM tasks WHERE id=${tid};")
    case "$tstatus" in
      done)                final_status="done";     break ;;
      escalated|cancelled) final_status="$tstatus"; break ;;
    esac
    (( t >= deadline )) && { final_status="timeout"; break; }
    sleep "$poll"
  done

  local tresult; tresult=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${tid};")
  local loop_status verdict
  case "$final_status" in
    done)      loop_status="done";      verdict="pass" ;;
    killed)    loop_status="killed";    verdict="halted" ;;
    *)         loop_status="escalated"; verdict="escalated" ;;
  esac
  local now2; now2=$(date +%s)
  db "UPDATE loop_runs SET status=$(sqlq "$loop_status"), updated_at=${now2},
        result_json=$(sqlq_or_null "$tresult") WHERE loop_id=$(sqlq "$loop_id");"
  if [[ "$loop_status" == "escalated" || "$loop_status" == "killed" ]] && [[ "$by_task_sql" != "NULL" ]]; then
    cmd_task_need "$by_task_sql" --type=approval \
      --ask="loop ${loop_id} verify halted (${final_status}, ~${spent}tok/${eff_ceiling}) on ${tident}. Continue, adjust, or stop?" \
      >/dev/null 2>&1 || true
  fi
  ok "loop ${loop_id} ${loop_status} (verdict ${verdict}) ← ${tident}" \
     '{loopId:$l, handle:$l, status:$s, verdict:$vd, target:($t|tonumber), targetIdent:$ti, verifier:$v, ceiling:($c|tonumber), tokensSpent:($sp|tonumber), result:$res}' \
     --arg l "$loop_id" --arg s "$loop_status" --arg vd "$verdict" --arg t "$tid" --arg ti "$tident" \
     --arg v "$verifier" --arg c "$eff_ceiling" --arg sp "${spent:-0}" --arg res "$tresult"
  return 0
}

# --- loop grade (DIVE-748: numeric scorecard against acceptance-criteria) ---
# The quantitative analogue of `loop verify`: instead of a pass/fail prose
# verdict, an LLM grader scores the target's WORK against each of its acceptance
# criteria and emits a numeric scorecard {overall, criteria:[{name,score,reason}]}.
# This is the measurable artifact DIVE-747's per-loop-run scorecard reads.
# Reuses the `loop spawn --role=verifier --schema` grader machinery; stores the
# parsed card in loop_runs.scorecard_json (topology='grade'). verdict = pass iff
# overall >= threshold (default 70). writer≠grader enforced (grader ≠ assignee).
cmd_loop_grade() {
  tasks_db_init
  local target="" verifier="" accept="" threshold="" ceiling="" from="" stage="" wait_flag="" wait_secs="" project="dive"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target=*)    target="${1#*=}" ;;
      --verifier=*)  verifier="${1#*=}" ;;
      --accept=*)    accept="${1#*=}" ;;
      --threshold=*) threshold="${1#*=}" ;;
      --ceiling=*)   ceiling="${1#*=}" ;;
      --from=*)      from="${1#*=}" ;;
      --stage=*)     stage="${1#*=}" ;;
      --project=*)   project="${1#*=}" ;;
      --wait)        wait_flag=1 ;;
      --wait=*)      wait_flag=1; wait_secs="${1#*=}" ;;
      --)            shift; break ;;
      -*)            fail "$E_USAGE" "unknown flag: $1" ;;
      *)             fail "$E_USAGE" "loop grade takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$target" ]]   || fail "$E_USAGE" "loop grade: --target=<id|DIVE-N> required"
  [[ -n "$verifier" ]] || fail "$E_USAGE" "loop grade: --verifier=<agent> required"
  [[ -z "$threshold" || "$threshold" =~ ^[0-9]+$ ]] && [[ -z "$threshold" || "$threshold" -le 100 ]] \
    || fail "$E_VALIDATION" "--threshold must be an integer 0-100"
  [[ -z "$ceiling"   || "$ceiling"   =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"
  [[ -z "$wait_secs" || "$wait_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--wait=<seconds> must be a positive integer"
  local eff_threshold="${threshold:-70}"

  resolve_task_id "$target"   # sets RESOLVED_TASK_ID or fails
  local tid="$RESOLVED_TASK_ID"
  local tassignee tident
  tassignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE id=${tid};")
  tident=$(db "SELECT ident FROM tasks WHERE id=${tid};")
  # writer≠grader: the grader must differ from the maker (target's assignee).
  [[ "$verifier" != "$tassignee" ]] || fail "$E_VALIDATION" "grader must differ from the target's assignee ('$tassignee') — writer≠grader"
  # Criteria to grade against: explicit --accept, else the task's stored
  # acceptance_criteria (DIVE-476). No criteria → nothing to score against.
  [[ -n "$accept" ]] || accept=$(db "SELECT COALESCE(acceptance_criteria,'') FROM tasks WHERE id=${tid};")
  [[ -n "$accept" ]] || fail "$E_VALIDATION" "no --accept and ${tident} has no acceptance_criteria — set criteria first (task add … --accept=\"…\")"
  # The work to grade: the maker's captured result, falling back to the body.
  local twork; twork=$(db "SELECT COALESCE(NULLIF(result,''), body, '') FROM tasks WHERE id=${tid};")

  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)

  # Strict scoring contract → deterministic parse. Each criterion scored 0-100
  # with a one-line reason; overall is the grader's holistic 0-100.
  local schema='{"type":"object","required":["overall","criteria"],"properties":{"overall":{"type":"integer","minimum":0,"maximum":100},"criteria":{"type":"array","items":{"type":"object","required":["name","score"],"properties":{"name":{"type":"string"},"score":{"type":"integer","minimum":0,"maximum":100},"reason":{"type":"string"}}}}}}'
  local gp; gp=$(printf 'Grade the WORK below against each ACCEPTANCE CRITERION. Reply with ONLY strict JSON {"overall":0-100,"criteria":[{"name":"…","score":0-100,"reason":"…"}]}. Score each criterion 0-100 (0=unmet, 100=fully met) with a one-line reason; "overall" is your holistic 0-100. Be strict: score low when evidence is missing.\n\nTASK: %s\n\nACCEPTANCE CRITERIA:\n%s\n\nWORK TO GRADE:\n%s' "$tident" "$accept" "$twork")

  # Spawn ONE grader (reuses spawn accounting/heartbeat/schema plumbing).
  local gout gtid gtident
  gout=$(JSON_MODE=1 cmd_loop_spawn --role=verifier --agent="$verifier" --project="$project" ${from:+--from="$from"} \
           --ceiling="$eff_ceiling" --stage="grade${stage:+:$stage}" --schema="$schema" --prompt="$gp") || return $?
  gtid=$(printf '%s' "$gout"   | jq -r '.data.taskId')
  gtident=$(printf '%s' "$gout" | jq -r '.data.taskIdent')
  [[ "$gtid" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "loop grade: grader spawn failed ($gout)"

  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)
  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'grade', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"),
              ${eff_ceiling}, 'running', $(sqlq "[${gtid}]"), ${now}, ${now});"

  # No --wait: return the handle + grader composition immediately.
  if [[ -z "$wait_flag" ]]; then
    ok "loop ${loop_id} grading ${tident} (grader ${verifier}, threshold ${eff_threshold})" \
       '{loopId:$l, handle:$l, status:"grading", topology:"grade", target:($t|tonumber), targetIdent:$ti, grader:$v, graderTask:($g|tonumber), threshold:($th|tonumber), ceiling:($c|tonumber)}' \
       --arg l "$loop_id" --arg t "$tid" --arg ti "$tident" --arg v "$verifier" --arg g "$gtid" \
       --arg th "$eff_threshold" --arg c "$eff_ceiling"
    return 0
  fi

  # --wait: block-poll the grader to terminal, policed by kill + ceiling.
  local deadline poll="${LOOP_POLL_SECS:-4}"
  if [[ -n "$wait_secs" ]]; then deadline=$(( now + wait_secs )); else deadline=$(( now + 1800 )); fi
  local final_status="running" killed="" spent="0"
  while :; do
    local t; t=$(date +%s)
    killed=$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
    if [[ "$killed" == "1" ]]; then final_status="killed"; break; fi
    spent=$(_loop_spent "$loop_id")
    if [[ "${spent:-0}" -ge "$eff_ceiling" ]]; then final_status="escalated"; break; fi
    local gstatus; gstatus=$(db "SELECT status FROM tasks WHERE id=${gtid};")
    case "$gstatus" in
      done|rejected|escalated|cancelled) final_status="complete"; break ;;
    esac
    (( t >= deadline )) && { final_status="timeout"; break; }
    sleep "$poll"
  done

  # Parse the grader's scorecard from its task result (strict JSON contract;
  # unparseable/missing overall → escalate, never a silent pass).
  local gres overall criteria_json loop_status verdict
  gres=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${gtid};")
  overall=$(printf '%s' "$gres"  | jq -r 'if (.overall|type)=="number" then .overall else empty end' 2>/dev/null)
  criteria_json=$(printf '%s' "$gres" | jq -c '.criteria // []' 2>/dev/null); [[ -n "$criteria_json" ]] || criteria_json="[]"
  if [[ "$final_status" == "complete" && -n "$overall" ]]; then
    if (( overall >= eff_threshold )); then verdict="pass"; else verdict="fail"; fi
    loop_status="done"
  else
    verdict="escalated"; overall="${overall:-0}"
    loop_status="escalated"; [[ "$final_status" == "killed" ]] && loop_status="killed"
  fi
  local now2; now2=$(date +%s)
  local scorecard_json
  scorecard_json=$(jq -cn --argjson o "${overall:-0}" --argjson cr "$criteria_json" --arg vd "$verdict" \
     --argjson th "$eff_threshold" --arg ti "$tident" --arg v "$verifier" --argjson at "$now2" \
     '{overall:$o, criteria:$cr, verdict:$vd, threshold:$th, target:$ti, grader:$v, gradedAt:$at}')
  db "UPDATE loop_runs SET status=$(sqlq "$loop_status"), updated_at=${now2}, scorecard_json=$(sqlq "$scorecard_json") WHERE loop_id=$(sqlq "$loop_id");"
  ok "loop ${loop_id} ${loop_status} — ${tident} scored ${overall}/100 (verdict ${verdict}, threshold ${eff_threshold})" \
     '{loopId:$l, handle:$l, status:$s, verdict:$vd, overall:($o|tonumber), threshold:($th|tonumber), criteria:$cr, target:($t|tonumber), targetIdent:$ti, grader:$v, ceiling:($c|tonumber), tokensSpent:($sp|tonumber)}' \
     --arg l "$loop_id" --arg s "$loop_status" --arg vd "$verdict" --arg o "${overall:-0}" --arg th "$eff_threshold" \
     --argjson cr "$criteria_json" --arg t "$tid" --arg ti "$tident" --arg v "$verifier" --arg c "$eff_ceiling" --arg sp "${spent:-0}"
  return 0
}

# --- loop panel (N diverse-lens graders + quorum vote — design §3 / spec) ---
# Judge ONE claim with N verifier graders, one per lens (perspective-diverse >
# N identical refuters), then quorum-vote their pass/fail verdicts. Each grader
# is a `loop spawn --role=verifier` (reuses all the spawn accounting/heartbeat
# plumbing); the grader returns a strict {"verdict":"pass"|"fail"} contract so
# the tally is deterministic. Default N=3 quorum=2; both per-call overridable +
# a config default (Mark's cost-dial — panel size is user-owned, not a fixed
# tax). Registers a topology=panel loop_runs row whose child_task_ids are the
# grader tasks. With --wait, block-polls all graders to terminal then votes;
# kill/ceiling between polls → STOP + escalate-with-proof (never silently ship).
_LOOP_PANEL_N_BUILTIN=3
_LOOP_PANEL_QUORUM_BUILTIN=2
_loop_panel_n_default() {
  if [[ -n "${LOOP_PANEL_N_DEFAULT:-}" && "${LOOP_PANEL_N_DEFAULT}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$LOOP_PANEL_N_DEFAULT"; else printf '%s' "$_LOOP_PANEL_N_BUILTIN"; fi
}
_loop_panel_quorum_default() {
  if [[ -n "${LOOP_PANEL_QUORUM_DEFAULT:-}" && "${LOOP_PANEL_QUORUM_DEFAULT}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$LOOP_PANEL_QUORUM_DEFAULT"; else printf '%s' "$_LOOP_PANEL_QUORUM_BUILTIN"; fi
}

cmd_loop_panel() {
  tasks_db_init
  local agent="" claim="" lens_csv="" n="" quorum="" ceiling="" project="dive" from="" stage="" wait_flag="" wait_secs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent=*)   agent="${1#*=}" ;;
      --claim=*)   claim="${1#*=}" ;;
      --lens=*)    lens_csv="${1#*=}" ;;
      --n=*)       n="${1#*=}" ;;
      --quorum=*)  quorum="${1#*=}" ;;
      --ceiling=*) ceiling="${1#*=}" ;;
      --project=*) project="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      --stage=*)   stage="${1#*=}" ;;
      --wait)      wait_flag=1 ;;
      --wait=*)    wait_flag=1; wait_secs="${1#*=}" ;;
      --)          shift; break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           fail "$E_USAGE" "loop panel takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$agent" ]] || fail "$E_USAGE" "loop panel: --agent=<type|name> (who runs the graders) required"
  [[ -n "$claim" ]] || fail "$E_USAGE" "loop panel: --claim=… (the thing to judge) required"
  [[ -z "$n"         || "$n"         =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--n must be a positive integer"
  [[ -z "$quorum"    || "$quorum"    =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--quorum must be a positive integer"
  [[ -z "$ceiling"   || "$ceiling"   =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"
  [[ -z "$wait_secs" || "$wait_secs" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--wait=<seconds> must be a positive integer"

  # Lenses: explicit CSV (trimmed), else a standard diverse triad. N defaults to
  # the lens count (one grader per lens) unless --n is set; config default
  # backstops when neither is given. Lenses round-robin if --n exceeds the list.
  local lenses=()
  if [[ -n "$lens_csv" ]]; then
    IFS=',' read -r -a lenses <<< "$lens_csv"
    local i; for i in "${!lenses[@]}"; do lenses[$i]="$(printf '%s' "${lenses[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; done
  fi
  [[ ${#lenses[@]} -gt 0 ]] || lenses=(correctness completeness risk)
  if [[ -z "$n" ]]; then
    if [[ -n "$lens_csv" ]]; then n=${#lenses[@]}; else n=$(_loop_panel_n_default); fi
  fi
  local eff_quorum="${quorum:-$(_loop_panel_quorum_default)}"
  (( eff_quorum < 1 )) && eff_quorum=1
  (( eff_quorum > n )) && eff_quorum=$n

  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)
  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)
  # Split the panel ceiling across graders so the panel total stays ~eff_ceiling.
  local per_ceiling=$(( eff_ceiling / n )); (( per_ceiling < 1 )) && per_ceiling=1
  # Strict verdict contract → deterministic tally.
  local schema='{"type":"object","required":["verdict"],"properties":{"verdict":{"enum":["pass","fail"]},"reason":{"type":"string"}}}'

  local child_ids=() used_lenses=() members_json="[]"
  local k lens gp gout gtid gtident
  for (( k=0; k<n; k++ )); do
    lens="${lenses[$(( k % ${#lenses[@]} ))]}"
    used_lenses+=("$lens")
    gp=$(printf 'Judge the following claim through the "%s" lens. Reply with ONLY strict JSON {"verdict":"pass"|"fail","reason":"…"}. Default to "fail" if uncertain or under-evidenced.\n\nCLAIM:\n%s' "$lens" "$claim")
    # Force JSON so we can parse the handle; each grader gets its slice of budget.
    gout=$(JSON_MODE=1 cmd_loop_spawn --role=verifier --agent="$agent" --project="$project" ${from:+--from="$from"} \
             --ceiling="$per_ceiling" --stage="panel:${lens}" --schema="$schema" --prompt="$gp") || return $?
    gtid=$(printf '%s' "$gout"   | jq -r '.data.taskId')
    gtident=$(printf '%s' "$gout" | jq -r '.data.taskIdent')
    [[ "$gtid" =~ ^[0-9]+$ ]] || fail "$E_GENERIC" "loop panel: grader spawn failed ($gout)"
    child_ids+=("$gtid")
    members_json=$(printf '%s' "$members_json" | jq -c --argjson t "$gtid" --arg ti "$gtident" --arg ln "$lens" '. + [{taskId:$t, taskIdent:$ti, lens:$ln}]')
  done
  local child_json; child_json=$(printf '%s\n' "${child_ids[@]}" | jq -R . | jq -cs 'map(tonumber)')
  local lenses_json; lenses_json=$(printf '%s\n' "${used_lenses[@]}" | jq -R . | jq -cs .)

  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'panel', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"),
              ${eff_ceiling}, 'running', $(sqlq "$child_json"), ${now}, ${now});"

  # No --wait: return the handle + the panel composition immediately.
  if [[ -z "$wait_flag" ]]; then
    ok "loop ${loop_id} panel: ${n} graders (quorum ${eff_quorum}) judging claim" \
       '{loopId:$l, handle:$l, status:"running", topology:"panel", n:($n|tonumber), quorum:($q|tonumber), lenses:$ln, members:$m, ceiling:($c|tonumber)}' \
       --arg l "$loop_id" --arg n "$n" --arg q "$eff_quorum" --argjson ln "$lenses_json" \
       --argjson m "$members_json" --arg c "$eff_ceiling"
    return 0
  fi

  # --wait: block-poll all graders to terminal, policed by kill + ceiling.
  local deadline poll="${LOOP_POLL_SECS:-4}"
  if [[ -n "$wait_secs" ]]; then deadline=$(( now + wait_secs )); else deadline=$(( now + 1800 )); fi
  local final_status="running" killed="" spent="0"
  local ids_csv; ids_csv=$(IFS=,; printf '%s' "${child_ids[*]}")
  while :; do
    local t; t=$(date +%s)
    killed=$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")
    if [[ "$killed" == "1" ]]; then final_status="killed"; break; fi
    spent=$(_loop_spent "$loop_id")
    if [[ "${spent:-0}" -ge "$eff_ceiling" ]]; then final_status="escalated"; break; fi
    local pending; pending=$(db "SELECT COUNT(*) FROM tasks WHERE id IN (${ids_csv}) AND status NOT IN ('done','rejected','escalated','cancelled');")
    if [[ "${pending:-1}" == "0" ]]; then final_status="complete"; break; fi
    (( t >= deadline )) && { final_status="timeout"; break; }
    sleep "$poll"
  done

  # Tally each grader's verdict from its task result (strict JSON contract;
  # unparseable/missing → abstain, which never counts toward quorum).
  local pass_votes=0 fail_votes=0 abstain=0 votes_json="[]"
  local cid cres cverd ctident
  for cid in "${child_ids[@]}"; do
    cres=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${cid};")
    ctident=$(db "SELECT ident FROM tasks WHERE id=${cid};")
    cverd=$(printf '%s' "$cres" | jq -r '.verdict // empty' 2>/dev/null)
    case "$cverd" in
      pass) pass_votes=$((pass_votes+1)) ;;
      fail) fail_votes=$((fail_votes+1)) ;;
      *)    abstain=$((abstain+1)); cverd="abstain" ;;
    esac
    votes_json=$(printf '%s' "$votes_json" | jq -c --arg ti "$ctident" --arg v "$cverd" '. + [{taskIdent:$ti, verdict:$v}]')
  done

  local verdict loop_status
  if [[ "$final_status" == "complete" ]]; then
    if (( pass_votes >= eff_quorum )); then verdict="pass"; else verdict="fail"; fi
    loop_status="done"
  else
    verdict="escalated"
    loop_status="escalated"; [[ "$final_status" == "killed" ]] && loop_status="killed"
  fi
  local now2; now2=$(date +%s)
  local result_json
  result_json=$(jq -cn --arg vd "$verdict" --argjson p "$pass_votes" --argjson f "$fail_votes" \
     --argjson a "$abstain" --argjson q "$eff_quorum" --argjson vs "$votes_json" \
     '{verdict:$vd, pass:$p, fail:$f, abstain:$a, quorum:$q, votes:$vs}')
  db "UPDATE loop_runs SET status=$(sqlq "$loop_status"), updated_at=${now2}, result_json=$(sqlq "$result_json") WHERE loop_id=$(sqlq "$loop_id");"

  # Escalate-with-proof on any non-clean halt (design §4).
  if [[ "$loop_status" == "escalated" || "$loop_status" == "killed" ]] && [[ "$by_task_sql" != "NULL" ]]; then
    cmd_task_need "$by_task_sql" --type=approval \
      --ask="loop ${loop_id} panel halted (${final_status}, ~${spent}tok/${eff_ceiling}); ${pass_votes} pass / ${fail_votes} fail so far (quorum ${eff_quorum}). Continue, adjust, or stop?" \
      >/dev/null 2>&1 || true
  fi

  ok "loop ${loop_id} panel ${verdict} (${pass_votes} pass / ${fail_votes} fail / quorum ${eff_quorum})" \
     '{loopId:$l, handle:$l, status:$s, topology:"panel", verdict:$vd, pass:($p|tonumber), fail:($f|tonumber), abstain:($a|tonumber), quorum:($q|tonumber), votes:$vs, ceiling:($c|tonumber), tokensSpent:($sp|tonumber)}' \
     --arg l "$loop_id" --arg s "$loop_status" --arg vd "$verdict" --arg p "$pass_votes" --arg f "$fail_votes" \
     --arg a "$abstain" --arg q "$eff_quorum" --argjson vs "$votes_json" --arg c "$eff_ceiling" --arg sp "${spent:-0}"
  return 0
}

# Host concurrency hard cap — mirrors the internal engine's min(16, cores-2) so a
# user can't oversubscribe the box (design §3 / spec map section).
_loop_host_conc_cap() {
  local cores; cores=$(nproc 2>/dev/null || echo 4)
  local cap=$(( cores - 2 )); (( cap < 1 )) && cap=1; (( cap > 16 )) && cap=16
  printf '%s' "$cap"
}
_LOOP_MAP_CONC_BUILTIN=5
_loop_map_conc_default() {
  if [[ -n "${LOOP_MAP_CONCURRENCY_DEFAULT:-}" && "${LOOP_MAP_CONCURRENCY_DEFAULT}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$LOOP_MAP_CONCURRENCY_DEFAULT"; else printf '%s' "$_LOOP_MAP_CONC_BUILTIN"; fi
}

# --- loop map (fan-out over a json array — design §3 / LOOP-3) ---
# Apply one spawn-spec to every element of --over, injecting the element at the
# `{}` placeholder in --do. Order-preserving + index-aligned (output[i] ↔
# input[i]); a failed/timed-out/killed item resolves to null and NEVER aborts the
# batch (the single most important map property). Bounded concurrency is a
# user-owned dial: --max-concurrency > config default (5) > host hard cap
# min(16,cores-2); items past the cap queue and drain as slots free. The whole
# map is one loop run sharing the token ceiling — at the ceiling/kill it halts,
# returns partial results (rest null) + escalates-with-proof, never crashes. No
# silent truncation: result reports {total, ok, failed}.
cmd_loop_map() {
  tasks_db_init
  local over="" do_tmpl="" agent="" role="worker" maxconc="" ceiling="" project="dive" from="" stage="" timeout=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --over=*)            over="${1#*=}" ;;
      --do=*)              do_tmpl="${1#*=}" ;;
      --agent=*)           agent="${1#*=}" ;;
      --role=*)            role="${1#*=}" ;;
      --max-concurrency=*) maxconc="${1#*=}" ;;
      --ceiling=*)         ceiling="${1#*=}" ;;
      --project=*)         project="${1#*=}" ;;
      --from=*)            from="${1#*=}" ;;
      --stage=*)           stage="${1#*=}" ;;
      --timeout=*)         timeout="${1#*=}" ;;
      --)                  shift; break ;;
      -*)                  fail "$E_USAGE" "unknown flag: $1" ;;
      *)                   fail "$E_USAGE" "loop map takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$agent" ]]   || fail "$E_USAGE" "loop map: --agent=<type|name> required"
  [[ -n "$do_tmpl" ]] || fail "$E_USAGE" "loop map: --do=<prompt-template> (use {} for the element) required"
  [[ -n "$over" ]]    || fail "$E_USAGE" "loop map: --over=<json-array> required"
  printf '%s' "$over" | jq -e 'type=="array"' >/dev/null 2>&1 || fail "$E_VALIDATION" "--over must be a JSON array"
  case "$role" in maker|verifier|worker) ;; *) fail "$E_VALIDATION" "--role must be maker|verifier|worker" ;; esac
  [[ -z "$maxconc" || "$maxconc" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-concurrency must be a positive integer"
  [[ -z "$ceiling" || "$ceiling" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"
  [[ -z "$timeout" || "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"

  local n; n=$(printf '%s' "$over" | jq 'length')
  local eff_conc="${maxconc:-$(_loop_map_conc_default)}"
  local hard; hard=$(_loop_host_conc_cap); (( eff_conc > hard )) && eff_conc=$hard
  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)
  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)
  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage, iteration,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'map', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"), 0,
              ${eff_ceiling}, 'running', '[]', ${now}, ${now});"

  # index-aligned result slots; scheduler caps live (non-terminal) child tasks.
  # A plain `live` counter (not ${#assoc[@]}) keeps every expansion set-u-safe
  # even when the in-flight map is momentarily empty (header runs set -euo).
  local -a results; local i; for (( i=0; i<n; i++ )); do results[$i]="null"; done
  local -A inflight          # index->tid for currently-live children
  local -a child_ids=()
  local next=0 completed=0 ok_n=0 failed_n=0 live=0 halt="" spent="0"
  local poll="${LOOP_POLL_SECS:-4}"; local deadline=$(( now + ${timeout:-3600} ))
  while (( completed < n )); do
    local nowt; nowt=$(date +%s)
    [[ "$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")" == "1" ]] && { halt="killed"; break; }
    spent=$(_loop_spent "$loop_id")
    (( ${spent:-0} >= eff_ceiling )) && { halt="escalated"; break; }
    # dispatch up to the concurrency cap
    while (( live < eff_conc && next < n )); do
      local elem; elem=$(printf '%s' "$over" | jq -r ".[$next] | if type==\"string\" then . else (.|tojson) end")
      local prompt="${do_tmpl//\{\}/$elem}"
      local gout gtid
      gout=$(JSON_MODE=1 cmd_loop_spawn --role="$role" --agent="$agent" --project="$project" ${from:+--from="$from"} \
               --ceiling="$eff_ceiling" --stage="map[$next]" --prompt="$prompt") || { halt="error"; break; }
      gtid=$(printf '%s' "$gout" | jq -r '.data.taskId')
      [[ "$gtid" =~ ^[0-9]+$ ]] || { halt="error"; break; }
      inflight[$next]=$gtid; child_ids+=("$gtid"); next=$((next+1)); live=$((live+1))
    done
    [[ -n "$halt" ]] && break
    # reap terminals (guarded so an empty map is never expanded under set -u)
    local progressed=0 k
    if (( live > 0 )); then
      for k in "${!inflight[@]}"; do
        local tid="${inflight[$k]}" ts
        ts=$(db "SELECT status FROM tasks WHERE id=${tid};")
        case "$ts" in
          done)                          results[$k]=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${tid};"); ok_n=$((ok_n+1)); completed=$((completed+1)); unset 'inflight[$k]'; live=$((live-1)); progressed=1 ;;
          rejected|escalated|cancelled)  results[$k]="null"; failed_n=$((failed_n+1)); completed=$((completed+1)); unset 'inflight[$k]'; live=$((live-1)); progressed=1 ;;
        esac
      done
    fi
    db "UPDATE loop_runs SET iteration=${completed}, child_task_ids=$(sqlq "$(printf '%s\n' "${child_ids[@]}" | jq -R . | jq -cs 'map(tonumber)')"), updated_at=$(date +%s) WHERE loop_id=$(sqlq "$loop_id");"
    if (( ! progressed )); then (( nowt >= deadline )) && { halt="timeout"; break; }; sleep "$poll"; fi
  done

  # Build the index-aligned output: each ok slot's result parsed as JSON if it
  # is JSON, else kept as a string; failed/unfinished slots are null.
  local out_arr="[]" j
  for (( j=0; j<n; j++ )); do
    local r="${results[$j]}"
    if [[ "$r" == "null" ]]; then
      out_arr=$(printf '%s' "$out_arr" | jq -c '. + [null]')
    else
      out_arr=$(printf '%s' "$out_arr" | jq -c --arg s "$r" '. + [ ($s | try fromjson catch $s) ]')
    fi
  done
  local status_final="done"
  [[ -n "$halt" && "$halt" != "" ]] && case "$halt" in killed) status_final="killed";; *) status_final="escalated";; esac
  local now2; now2=$(date +%s)
  local result_json; result_json=$(jq -cn --argjson t "$n" --argjson ok "$ok_n" --argjson f "$failed_n" --argjson res "$out_arr" \
     '{total:$t, ok:$ok, failed:$f, results:$res}')
  db "UPDATE loop_runs SET status=$(sqlq "$status_final"), iteration=${completed}, updated_at=${now2}, result_json=$(sqlq "$result_json") WHERE loop_id=$(sqlq "$loop_id");"
  if [[ "$status_final" != "done" && "$by_task_sql" != "NULL" ]]; then
    cmd_task_need "$by_task_sql" --type=approval \
      --ask="loop ${loop_id} map halted (${halt}, ~${spent}tok/${eff_ceiling}); ${ok_n}/${n} done, rest null. Continue, adjust, or stop?" \
      >/dev/null 2>&1 || true
  fi
  ok "loop ${loop_id} map ${status_final}: ${ok_n} ok / ${failed_n} failed / ${n} total" \
     '{loopId:$l, handle:$l, status:$s, topology:"map", total:($t|tonumber), ok:($ok|tonumber), failed:($f|tonumber), concurrency:($cc|tonumber), results:$res, ceiling:($c|tonumber), tokensSpent:($sp|tonumber)}' \
     --arg l "$loop_id" --arg s "$status_final" --arg t "$n" --arg ok "$ok_n" --arg f "$failed_n" --arg cc "$eff_conc" \
     --argjson res "$out_arr" --arg c "$eff_ceiling" --arg sp "${spent:-0}"
  return 0
}

# --- loop until-dry (unknown-size discovery — design §3 / LOOP-4) ---
# Repeat a finder round (--round prompt; a loop spawn) until K consecutive rounds
# return zero FRESH results. "Fresh" = --dedup-key value not in the seen-set;
# dedup is against everything ever SEEN (never the kept set — else a rejected
# item reappears every round and the loop never converges). First termination to
# fire wins: K empty rounds (default 2), --max-iters, --max-runtime, or the token
# ceiling; a cap hit before going dry returns partial + escalates (no silent
# caps). Each round's finder must return a JSON array of objects. Returns the
# accumulated deduped set.
cmd_loop_until_dry() {
  tasks_db_init
  local round="" dedup_key="" stop_after="2" agent="" role="worker" max_iters="" max_runtime="" ceiling="" project="dive" from="" stage="" round_timeout=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --round=*)       round="${1#*=}" ;;
      --dedup-key=*)   dedup_key="${1#*=}" ;;
      --stop-after=*)  stop_after="${1#*=}" ;;
      --agent=*)       agent="${1#*=}" ;;
      --role=*)        role="${1#*=}" ;;
      --max-iters=*)   max_iters="${1#*=}" ;;
      --max-runtime=*) max_runtime="${1#*=}" ;;
      --ceiling=*)     ceiling="${1#*=}" ;;
      --project=*)     project="${1#*=}" ;;
      --from=*)        from="${1#*=}" ;;
      --stage=*)       stage="${1#*=}" ;;
      --round-timeout=*) round_timeout="${1#*=}" ;;
      --)              shift; break ;;
      -*)              fail "$E_USAGE" "unknown flag: $1" ;;
      *)               fail "$E_USAGE" "loop until-dry takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$agent" ]]     || fail "$E_USAGE" "loop until-dry: --agent=<type|name> required"
  [[ -n "$round" ]]     || fail "$E_USAGE" "loop until-dry: --round=<finder-prompt> required"
  [[ -n "$dedup_key" ]] || fail "$E_USAGE" "loop until-dry: --dedup-key=<field> required"
  [[ "$stop_after" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--stop-after must be a positive integer"
  [[ -z "$max_iters"   || "$max_iters"   =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-iters must be a positive integer"
  [[ -z "$max_runtime" || "$max_runtime" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--max-runtime must be a positive integer (seconds)"
  [[ -z "$ceiling"     || "$ceiling"     =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--ceiling must be a positive integer (tokens)"

  local eff_ceiling; eff_ceiling=$(_loop_eff_ceiling "$ceiling")
  local loop_id; loop_id=$(_loop_new_id)
  local by_task_sql="NULL"
  [[ -n "${FIVE_TASK_ID:-}" && "${FIVE_TASK_ID}" =~ ^[0-9]+$ ]] && by_task_sql="${FIVE_TASK_ID}"
  local by_agent; by_agent=$(task_actor "$from")
  local now; now=$(date +%s)
  db "INSERT INTO loop_runs (loop_id, topology, spawned_by_agent, spawned_by_task, stage, iteration,
                             ceiling, status, child_task_ids, started_at, updated_at)
      VALUES ($(sqlq "$loop_id"), 'until-dry', $(sqlq "$by_agent"), ${by_task_sql}, $(sqlq_or_null "$stage"), 0,
              ${eff_ceiling}, 'running', '[]', ${now}, ${now});"

  local seen_keys="[]" accum="[]"      # seen-set (all keys ever) + kept items
  local -a child_ids
  local round_no=0 empty_streak=0 exit_reason="" spent="0"
  local poll="${LOOP_POLL_SECS:-4}"
  while :; do
    # termination caps (checked before each round)
    (( empty_streak >= stop_after )) && { exit_reason="dry"; break; }
    [[ -n "$max_iters" ]] && (( round_no >= max_iters )) && { exit_reason="max-iters"; break; }
    local elapsed=$(( $(date +%s) - now ))
    [[ -n "$max_runtime" ]] && (( elapsed >= max_runtime )) && { exit_reason="max-runtime"; break; }
    [[ "$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")" == "1" ]] && { exit_reason="killed"; break; }
    spent=$(_loop_spent "$loop_id")
    (( ${spent:-0} >= eff_ceiling )) && { exit_reason="ceiling"; break; }

    round_no=$((round_no+1))
    # Spawn one finder for this round; block-poll it to terminal.
    local gout gtid
    gout=$(JSON_MODE=1 cmd_loop_spawn --role="$role" --agent="$agent" --project="$project" ${from:+--from="$from"} \
             --ceiling="$eff_ceiling" --stage="round[$round_no]" --prompt="$round") || { exit_reason="error"; break; }
    gtid=$(printf '%s' "$gout" | jq -r '.data.taskId'); child_ids+=("$gtid")
    db "UPDATE loop_runs SET child_task_ids=$(sqlq "$(printf '%s\n' "${child_ids[@]}" | jq -R . | jq -cs 'map(tonumber)')") WHERE loop_id=$(sqlq "$loop_id");"
    local rdeadline=$(( $(date +%s) + ${round_timeout:-1800} )) rstatus=""
    while :; do
      [[ "$(db "SELECT kill_requested FROM loop_runs WHERE loop_id=$(sqlq "$loop_id");")" == "1" ]] && { rstatus="killed"; break; }
      rstatus=$(db "SELECT status FROM tasks WHERE id=${gtid};")
      case "$rstatus" in done|rejected|escalated|cancelled) break ;; esac
      (( $(date +%s) >= rdeadline )) && { rstatus="timeout"; break; }
      sleep "$poll"
    done
    if [[ "$rstatus" != "done" ]]; then exit_reason="$rstatus"; break; fi

    # Parse the finder's result as a JSON array; count FRESH (key not seen).
    local rres items fresh=0
    rres=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${gtid};")
    items=$(printf '%s' "$rres" | jq -c 'if type=="array" then . else [] end' 2>/dev/null || echo '[]')
    local m; m=$(printf '%s' "$items" | jq 'length')
    local x
    for (( x=0; x<m; x++ )); do
      local item key; item=$(printf '%s' "$items" | jq -c ".[$x]")
      key=$(printf '%s' "$item" | jq -r "(.[\"$dedup_key\"]) // empty")
      [[ -z "$key" ]] && continue
      if printf '%s' "$seen_keys" | jq -e --arg k "$key" 'index($k) != null' >/dev/null 2>&1; then continue; fi
      seen_keys=$(printf '%s' "$seen_keys" | jq -c --arg k "$key" '. + [$k]')
      accum=$(printf '%s' "$accum" | jq -c --argjson it "$item" '. + [$it]')
      fresh=$((fresh+1))
    done
    if (( fresh == 0 )); then empty_streak=$((empty_streak+1)); else empty_streak=0; fi
    db "UPDATE loop_runs SET iteration=${round_no}, updated_at=$(date +%s) WHERE loop_id=$(sqlq "$loop_id");"
  done

  local status_final="done"
  case "$exit_reason" in dry) status_final="done";; killed) status_final="killed";; max-iters|max-runtime|ceiling|timeout|rejected|escalated|cancelled|error) status_final="escalated";; esac
  local kept; kept=$(printf '%s' "$accum" | jq 'length')
  local now2; now2=$(date +%s)
  local result_json; result_json=$(jq -cn --arg er "$exit_reason" --argjson r "$round_no" --argjson k "$kept" --argjson items "$accum" \
     '{exitReason:$er, rounds:$r, found:$k, items:$items}')
  db "UPDATE loop_runs SET status=$(sqlq "$status_final"), iteration=${round_no}, updated_at=${now2}, result_json=$(sqlq "$result_json") WHERE loop_id=$(sqlq "$loop_id");"
  if [[ "$status_final" != "done" && "$by_task_sql" != "NULL" ]]; then
    cmd_task_need "$by_task_sql" --type=approval \
      --ask="loop ${loop_id} until-dry stopped early (${exit_reason}, ~${spent}tok/${eff_ceiling}) after ${round_no} rounds, ${kept} found — coverage NOT exhaustive. Continue, adjust, or stop?" \
      >/dev/null 2>&1 || true
  fi
  ok "loop ${loop_id} until-dry ${status_final} (${exit_reason}): ${kept} found over ${round_no} rounds" \
     '{loopId:$l, handle:$l, status:$s, topology:"until-dry", exitReason:$er, rounds:($r|tonumber), found:($k|tonumber), items:$items, ceiling:($c|tonumber), tokensSpent:($sp|tonumber)}' \
     --arg l "$loop_id" --arg s "$status_final" --arg er "$exit_reason" --arg r "$round_no" --arg k "$kept" \
     --argjson items "$accum" --arg c "$eff_ceiling" --arg sp "${spent:-0}"
  return 0
}

# --- loop collect (the intentional barrier — design §3) ---
# Block-poll every handle's backing task(s) to terminal and gather their results
# into one index-aligned array — for the downstream step that genuinely needs the
# whole set at once (dedup/merge/early-exit-on-zero). Handles are loopIds; each
# resolves to its loop_runs.child_task_ids. done→result (JSON-parsed if JSON),
# any other terminal→null. Bounded by --timeout + kill.
cmd_loop_collect() {
  tasks_db_init
  local handles="" timeout="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --handles=*) handles="${1#*=}" ;;
      --timeout=*) timeout="${1#*=}" ;;
      --from=*)    from="${1#*=}" ;;
      --)          shift; break ;;
      -*)          fail "$E_USAGE" "unknown flag: $1" ;;
      *)           fail "$E_USAGE" "loop collect takes only flags (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$handles" ]] || fail "$E_USAGE" "loop collect: --handles=<loopId,loopId,…> required"
  [[ -z "$timeout" || "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "$E_VALIDATION" "--timeout must be a positive integer (seconds)"

  local -a hids; IFS=',' read -r -a hids <<< "$handles"
  # Resolve each handle → its backing task ids (index-aligned to the handle list).
  local -a tids
  local h
  for h in "${hids[@]}"; do
    h="$(printf '%s' "$h" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local cj; cj=$(db "SELECT COALESCE(child_task_ids,'[]') FROM loop_runs WHERE loop_id=$(sqlq "$h");")
    [[ -z "$cj" || "$cj" == "[]" ]] && { tids+=("");  continue; }
    # one handle may back multiple tasks (panel/map); collect uses the FIRST as
    # the handle's representative result (spawn/verify handles are single-task).
    local t0; t0=$(printf '%s' "$cj" | jq -r '.[0] // empty')
    tids+=("$t0")
  done

  local n=${#hids[@]} poll="${LOOP_POLL_SECS:-4}" now; now=$(date +%s)
  local deadline=$(( now + ${timeout:-1800} )) halt=""
  # barrier: wait until every resolved task is terminal (or timeout/kill).
  while :; do
    local pending=0 i
    for i in "${!tids[@]}"; do
      local t="${tids[$i]}"; [[ -z "$t" ]] && continue
      local ts; ts=$(db "SELECT status FROM tasks WHERE id=${t};")
      case "$ts" in done|rejected|escalated|cancelled) ;; *) pending=$((pending+1)) ;; esac
    done
    (( pending == 0 )) && break
    (( $(date +%s) >= deadline )) && { halt="timeout"; break; }
    sleep "$poll"
  done

  local out_arr="[]" ok_n=0 fail_n=0 i
  for (( i=0; i<n; i++ )); do
    local t="${tids[$i]}"
    if [[ -z "$t" ]]; then out_arr=$(printf '%s' "$out_arr" | jq -c '. + [null]'); fail_n=$((fail_n+1)); continue; fi
    local ts r; ts=$(db "SELECT status FROM tasks WHERE id=${t};")
    if [[ "$ts" == "done" ]]; then
      r=$(db "SELECT COALESCE(result,'') FROM tasks WHERE id=${t};")
      out_arr=$(printf '%s' "$out_arr" | jq -c --arg s "$r" '. + [ ($s | try fromjson catch $s) ]'); ok_n=$((ok_n+1))
    else
      out_arr=$(printf '%s' "$out_arr" | jq -c '. + [null]'); fail_n=$((fail_n+1))
    fi
  done
  local status_final="done"; [[ "$halt" == "timeout" ]] && status_final="timeout"
  ok "loop collect ${status_final}: ${ok_n} ok / ${fail_n} null / ${n} handles" \
     '{status:$s, total:($t|tonumber), ok:($ok|tonumber), failed:($f|tonumber), results:$res}' \
     --arg s "$status_final" --arg t "$n" --arg ok "$ok_n" --arg f "$fail_n" --argjson res "$out_arr"
  return 0
}

# --- loop status (LOOP-7: read-only single-loop drilldown) ---
# The read-side complement to `task loops` (the fleet-wide board): inspect ONE
# loop run by handle. PURE read — never spawns, mutates, block-waits, or authors
# work (unlike `loop collect`, which barriers on terminal state). Emits
# topology/stage/iteration/tokens-vs-ceiling/status/stuck plus each backing
# task's LIVE state, so an orchestrator can poll a handle between other work.
# JSON in / JSON out. `stuck` = the stored supervisor flag OR a derived signal
# (a running loop at/over its ceiling, or with no heartbeat for the stall
# window) so a wedged loop is visible even before the next supervisor tick.
# Terminal loops (done/killed/escalated) are never reported stuck.
_LOOP_STALE_SECS=900
cmd_loop_status() {
  tasks_db_init
  local handle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --handle=*) handle="${1#*=}" ;;
      --)         shift; break ;;
      -*)         fail "$E_USAGE" "unknown flag: $1" ;;
      *)          [[ -z "$handle" ]] && handle="$1" || fail "$E_USAGE" "loop status takes one handle (unexpected: $1)" ;;
    esac
    shift
  done
  [[ -n "$handle" ]] || fail "$E_USAGE" "loop status: --handle=<loopId> required"

  local exists; exists=$(db "SELECT 1 FROM loop_runs WHERE loop_id=$(sqlq "$handle") LIMIT 1;")
  [[ -n "$exists" ]] || fail "$E_NOT_FOUND" "no loop run with handle '$handle' (see: 5dive task loops --all)"

  # The run row as one JSON object (typed columns; the *_json blobs stay raw so
  # we can re-parse them for the caller).
  local row
  row=$(dbfmt -json "SELECT loop_id, topology, COALESCE(stage,'') AS stage,
           COALESCE(iteration,0) AS iteration, COALESCE(tokens_spent,0) AS tokens_spent,
           ceiling, status, stuck AS stuck_flag, kill_requested,
           COALESCE(spawned_by_agent,'') AS spawned_by_agent, spawned_by_task,
           COALESCE(child_task_ids,'[]') AS child_task_ids,
           result_json, scorecard_json, started_at, updated_at
         FROM loop_runs WHERE loop_id=$(sqlq "$handle") LIMIT 1;" | jq -c '.[0]')

  local now; now=$(date +%s)
  local updated_at; updated_at=$(printf '%s' "$row" | jq -r '.updated_at')
  local age=$(( now - updated_at ))
  local rstatus;  rstatus=$(printf '%s' "$row" | jq -r '.status')
  local ceiling;  ceiling=$(printf '%s' "$row" | jq -r '.ceiling // empty')
  local spent;    spent=$(printf '%s' "$row" | jq -r '.tokens_spent')

  # Derived stuck (only meaningful while running).
  local stuck=0 stuck_reason=""
  [[ "$(printf '%s' "$row" | jq -r '.stuck_flag')" == "1" ]] && { stuck=1; stuck_reason="flagged"; }
  if [[ "$rstatus" == "running" ]]; then
    if [[ -n "$ceiling" && "${spent:-0}" -ge "$ceiling" ]]; then stuck=1; stuck_reason="ceiling"; fi
    if (( age >= _LOOP_STALE_SECS )); then stuck=1; [[ -z "$stuck_reason" || "$stuck_reason" == "flagged" ]] && stuck_reason="stale"; fi
  fi

  # Resolve backing task ids → live state (index-aligned to child_task_ids).
  local child_ids; child_ids=$(printf '%s' "$row" | jq -r '.child_task_ids')
  local children="[]" cdone=0 copen=0 cfail=0
  local ids; ids=$(printf '%s' "$child_ids" | jq -r '.[]? // empty')
  local cid
  for cid in $ids; do
    [[ "$cid" =~ ^[0-9]+$ ]] || continue
    local crow
    crow=$(dbfmt -json "SELECT id, ident, status, COALESCE(assignee,'') AS assignee
             FROM tasks WHERE id=${cid} LIMIT 1;" | jq -c '.[0] // empty')
    [[ -n "$crow" ]] || crow=$(jq -cn --argjson id "$cid" '{id:$id, ident:null, status:"missing", assignee:""}')
    children=$(printf '%s' "$children" | jq -c --argjson c "$crow" '. + [$c]')
    case "$(printf '%s' "$crow" | jq -r '.status')" in
      done)                          cdone=$((cdone+1)) ;;
      rejected|escalated|cancelled)  cfail=$((cfail+1)) ;;
      *)                             copen=$((copen+1)) ;;
    esac
  done

  # Assemble the drilldown object.
  local out
  out=$(printf '%s' "$row" | jq -c \
        --argjson stuck "$stuck" --arg sr "$stuck_reason" --argjson age "$age" \
        --argjson children "$children" --argjson cd "$cdone" --argjson co "$copen" --argjson cf "$cfail" \
        '{loopId:.loop_id, handle:.loop_id, topology:.topology, stage:.stage,
          iteration:.iteration, tokensSpent:.tokens_spent, ceiling:.ceiling,
          status:.status, killRequested:(.kill_requested==1),
          stuck:($stuck==1), stuckReason:(if $sr=="" then null else $sr end),
          spawnedBy:.spawned_by_agent, spawnedByTask:.spawned_by_task,
          startedAt:.started_at, updatedAt:.updated_at, ageSecs:$age,
          childCounts:{total:($children|length), done:$cd, open:$co, failed:$cf},
          children:$children,
          result:(.result_json | if .==null then null else (try fromjson catch .) end),
          scorecard:(.scorecard_json | if .==null then null else (try fromjson catch .) end)}')

  if (( JSON_MODE )); then
    ok "" '$d' --argjson d "$out"
    return 0
  fi

  # Text mode: a compact header + the backing-task board.
  local topology stage iteration by sbtask
  topology=$(printf '%s' "$row" | jq -r '.topology')
  stage=$(printf '%s' "$row"    | jq -r 'if (.stage//"")=="" then "-" else .stage end')
  iteration=$(printf '%s' "$row"| jq -r '.iteration')
  by=$(printf '%s' "$row"       | jq -r 'if (.spawned_by_agent//"")=="" then "-" else .spawned_by_agent end')
  sbtask=$(printf '%s' "$row"   | jq -r '.spawned_by_task // "-"')
  printf 'loop %s  [%s]  topology=%s  stage=%s  iter=%s\n' "$handle" "$rstatus" "$topology" "$stage" "$iteration"
  printf '  tokens %s/%s   age %ss   stuck=%s%s   kill=%s\n' \
    "$spent" "${ceiling:-∞}" "$age" "$([[ "$stuck" == 1 ]] && echo yes || echo no)" \
    "$([[ -n "$stuck_reason" ]] && echo " ($stuck_reason)" || true)" \
    "$(printf '%s' "$row" | jq -r 'if .kill_requested==1 then "requested" else "no" end')"
  printf '  by %s (task %s)   children: %s done / %s open / %s failed\n' "$by" "$sbtask" "$cdone" "$copen" "$cfail"
  if [[ -n "$ids" ]]; then
    local csv; csv=$(printf '%s' "$child_ids" | jq -r 'map(tostring)|join(",")')
    printf '\nbacking tasks:\n'
    dbfmt -box "SELECT id, ident, status, COALESCE(assignee,'-') AS assignee
                FROM tasks WHERE id IN (${csv}) ORDER BY id;"
  fi
  return 0
}
