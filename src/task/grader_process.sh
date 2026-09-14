# ── DIVE-4417: the grader lane's PROCESS mode ────────────────────────────────
#
# DIVE-4164 promised "task deliver spawns a fresh grader per delivery, N in
# parallel capped". What shipped, and what DIVE-4410 then load-balanced, is
# assign+wake onto a pool seat's ONE RUNNING SESSION. A seat is one systemd unit
# `5dive-agent@<name>.service` plus one tmux session `agent-<name>`, and that
# session runs one turn at a time, so two grades on one seat are a serial queue
# wearing the lane's name. Spreading across two seats took the lane from 1
# concurrent grade to 2. It did not make it N, and no amount of spreading will:
# the ceiling is the number of seats you are willing to provision.
#
# This file is the other spawn shape. One headless one-shot PROCESS per delivery,
# launched by the tick under the pool seat's own unix account, with its own
# working directory, exiting when it has delivered the verdict. N of them run
# under one account, and the cap is read from the LIVE PROCESSES rather than from
# lifecycle rows.
#
# ══ WHY THE CAP MOVES OFF THE LEDGER, WHICH IS THE WHOLE POINT OF (2) ══
# In session mode a spawn row is the only evidence a grade exists, so DIVE-4322
# and DIVE-4418 had to reconstruct "is this grade still running?" from the row's
# later state plus a six-hour staleness bound — a proxy, and one that was wrong
# twice. A process has an answer that needs no proxy: it is in the process table
# or it is not. A killed grader returns its slot the instant it dies, not six
# hours later, and a parked-on-merge PASS never held one at all.
#
# ══ IT SHIPS DARK BEHIND A THIRD LOCK ══
# The lane already ships behind two (dry-run default, empty pool default).
# `_GRADER_SPAWN_MODE` is the third and it defaults to `session`, which is
# byte-for-byte today's behaviour: nothing in this file runs until an operator
# names the mode. Naming it is a separate deliberate act from naming the pool,
# because this mode starts a PAID session per delivery with no per-seat serial
# queue in front of it — the cap is the only thing between the lane and the
# account's window.
#
# ══ WHAT THIS MODE DOES NOT YET DO, STATED RATHER THAN LEFT TO BE FOUND ══
# A second concurrent process under one account has NO systemd unit and NO tmux
# pane. `agent logs`, the supervisor pane classifiers and the liveness rails all
# address the single fixed names above (src/cmd_agent_runtime.sh:35, 109, 682,
# 789), so a one-shot is invisible to every one of them: you cannot `agent logs`
# it, the supervisor cannot read a rate-limit refusal off it, and no rail will
# notice it wedged. That is why `journal_unit` is written EMPTY on its run row
# rather than guessed — an empty column is a readable gap; a plausible-looking
# unit name that resolves to nothing is a lie the next reader has to disprove.
# Extending those rails is ops-owned and is not in this file. Until it lands,
# process mode's containment is the per-process log plus the cap, and that is
# the reason the mode is dark by default rather than the new default.
# The argv marker. It is the ONLY thing that makes a one-shot findable, because
# the process has no unit and no pane to be found by, so it is deliberately a
# string that appears nowhere else in the fleet's argv.
_GRADER_PROCESS_MARK="${_GRADER_PROCESS_MARK:-5dive-grader-oneshot}"

# Per-ACCOUNT parallelism once the per-seat serial queue is gone. In session mode
# the per-seat cap is 1 and it must stay 1 — a second wake there is a queue, not
# a grader (DIVE-4410). In process mode that constant is the thing to RAISE, not
# to delete: the account floor check is still the real gate, and this bound is
# what stops one seat's name absorbing an entire tick's worth of deliveries
# before the floor is ever consulted.
_GRADER_MAX_PER_SEAT_PROCESS="${_GRADER_MAX_PER_SEAT_PROCESS:-4}"

# Where a one-shot runs and where its output lands. Both are per-GRADE, never
# shared: two graders in one directory would fight over the same index.lock, and
# two graders in one log file produce a transcript nobody can attribute.
_GRADER_PROCESS_ROOT="${_GRADER_PROCESS_ROOT:-}"      # default: the seat's ~/graders
_GRADER_PROCESS_LOG_DIR="${_GRADER_PROCESS_LOG_DIR:-/var/log/5dive-graders}"
_GRADER_PROCESS_CLI="${_GRADER_PROCESS_CLI:-claude}"

# `_grader_process_ps` — one line per live one-shot argv, overridable so the unit
# harness can feed a fixture instead of needing live graders on the box.
#
# `pgrep -a -f` and not `ps | grep`: pgrep excludes its own pid, which is the
# classic off-by-one in a self-counting probe.
_GRADER_PROCESS_PS_CMD="${_GRADER_PROCESS_PS_CMD:-}"
_grader_process_ps() {
  if [[ -n "$_GRADER_PROCESS_PS_CMD" ]]; then eval "$_GRADER_PROCESS_PS_CMD"; return 0; fi
  pgrep -a -f "$_GRADER_PROCESS_MARK" 2>/dev/null || printf ''
}

# `_grader_process_count [<seat>]` — live one-shots, all seats or one seat.
#
# COUNTED BY DISTINCT `ident=`, NEVER BY LINE, and that is the load-bearing
# detail. One launch is three processes that all carry the marker in their argv —
# the `sudo`, the `bash -lc`, and after exec the CLI itself — plus `setsid` while
# it lives. Counting lines would read one grade as three or four and the cap
# would bind at a quarter of its number; counting idents reads one grade as one
# however many argv layers happen to be alive at the instant of the read.
_grader_process_count() {  # [<seat>]
  local want="${1:-}" line ident seat
  local -A seen=()
  while IFS= read -r line; do
    [[ "$line" == *"$_GRADER_PROCESS_MARK"* ]] || continue
    [[ "$line" == *ident=* ]] || continue
    ident="${line#*ident=}"; ident="${ident%% *}"
    [[ -n "$ident" ]] || continue
    if [[ -n "$want" ]]; then
      [[ "$line" == *seat=* ]] || continue
      seat="${line#*seat=}"; seat="${seat%% *}"
      [[ "$seat" == "$want" ]] || continue
    fi
    seen["$ident"]=1
  done < <(_grader_process_ps)
  printf '%s' "${#seen[@]}"
}

# `_grader_process_seat_loads` — the per-seat reading in process mode, in the
# same `<seat><US><n>` shape `_grader_seat_loads` emits, so the tick's pick loop
# is identical in both modes and only its SOURCE of truth changes.
_grader_process_seat_loads() {
  local line ident seat key
  local -A seen=() load=()
  while IFS= read -r line; do
    [[ "$line" == *"$_GRADER_PROCESS_MARK"* ]] || continue
    [[ "$line" == *ident=* && "$line" == *seat=* ]] || continue
    ident="${line#*ident=}"; ident="${ident%% *}"
    seat="${line#*seat=}";  seat="${seat%% *}"
    [[ -n "$ident" && -n "$seat" ]] || continue
    key="${seat}/${ident}"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen["$key"]=1
    load["$seat"]=$(( ${load[$seat]:-0} + 1 ))
  done < <(_grader_process_ps)
  for seat in "${!load[@]}"; do printf '%s\x1f%s\n' "$seat" "${load[$seat]}"; done
}

# `_grader_process_session_id <seat>` — `<seat>#<n>`, the attribution DO (3) asks
# for, so `run ls` shows `quinn#3` beside `quinn#4` instead of one `quinn`.
#
# n is derived from the `runs` table's own high-water mark for this seat rather
# than from a counter file: the ledger is the state, there is nothing to lose on
# a restart, and two ticks racing produce a duplicate id at worst — never a
# missing one, and never a live grade attributed to another grade's session.
_grader_process_session_id() {  # <seat>
  local seat="$1" n
  [[ -n "$seat" ]] || return 1
  n=$(db "SELECT COALESCE(MAX(CAST(substr(session_id, instr(session_id,'#')+1) AS INTEGER)),0)+1
            FROM runs
           WHERE agent=$(sqlq "$seat") AND role='grader'
             AND session_id LIKE $(sqlq "${seat}#")||'%';" 2>/dev/null || printf '')
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  printf '%s#%s' "$seat" "$n"
}

# `_grader_process_run_open <seat> <ident> <session_id>` — the run record DO (3)
# asks for. `runs` already carries `session_id` and `journal_unit`
# (src/lib/tasks_db.sh), so the shape needed no migration; nothing wrote two live
# rows for one seat before this.
#
# journal_unit IS WRITTEN EMPTY ON PURPOSE — see the header. A one-shot has no
# unit; writing `5dive-agent@quinn.service` would name the seat's MAIN session,
# whose journal contains everything except this grade.
_grader_process_run_open() {  # <seat> <ident> <session_id>
  local seat="$1" ident="$2" sid="$3" rid tid
  rid="gr-$(date -u +%Y%m%dT%H%M%SZ)-$$-${sid#*#}"
  tid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  [[ "$tid" =~ ^[0-9]+$ ]] || tid=NULL
  db "INSERT INTO runs (id, task_id, ident, agent, role, runtime_type, session_id,
                        journal_unit, wake_reason, status)
      VALUES ($(sqlq "$rid"), ${tid}, $(sqlq "$ident"), $(sqlq "$seat"), 'grader',
              'oneshot', $(sqlq "$sid"), '', 'task.grade.spawned', 'running');" >/dev/null 2>&1 || true
  printf '%s' "$rid"
}

# The goal the one-shot is launched with. Deliberately the SAME instruction the
# session-mode wake sends, plus the two facts only a one-shot needs: it is alone
# (no seat session will pick this up if it exits early) and its cwd is its own.
_grader_process_goal() {  # <ident> <session_id> <dir>
  printf 'You are a one-shot grader session (%s) with no inbox and no follow-up turn: this process exits when you stop. Grade delivered task %s. Your working directory %s is yours alone — make any checkout or worktree you need inside it, never in a shared checkout. Read the row, grade the delivery, checkpoint each verified arm to the row as you go, then run 5dive task done or 5dive task reject. Do not wait for CI; grade what is at the delivered head.' \
    "$2" "$1" "$3"
}

# `_grader_process_spawn <seat> <ident> <session_id>` — start ONE grader process.
#
# Deliberately the only function here that touches the fleet, mirroring
# `_grader_spawn_session`: one place to audit, one place to stub.
#
# THE ROW IS STILL ASSIGNED. The verdict path, the double-spawn guard
# (`_grader_row_is_in_progress`) and the reclaim rails all read `assignee`, and a
# grade with no owner is a grade no rail can attribute. What process mode drops
# is the WAKE — and dropping it is DO (4) in full: the seat's main session is
# never handed a grading turn, so its Telegram and a2a traffic is not blocked
# behind a grade for the first time since DIVE-4164.
#
# THE MARKER RIDES IN ARGV, not in the environment, because the environment is
# not readable from the process table without /proc access the counting side may
# not have, and because `sudo` scrubs the environment anyway (the same scrub that
# already drops `_A2A_GUARD` on the scoped-sudo path in `_grader_spawn_session`).
# `: <mark> seat=… ident=… session=…` is a no-op command whose ARGUMENTS are the
# record; every layer of the launch carries the string, which is why the counter
# de-duplicates by ident.

# ══ DIVE-4417 iteration 2: A LAUNCH THAT NEVER STARTS MUST NOT READ AS A SPAWN ══
#
# quinn, grading iteration 1, called this file's spawn with a seat whose unix
# account does not exist. `sudo -n -u` was denied, the per-grade log said so —
# and the function returned 0, because `setsid … &` is backgrounded and its exit
# status was never read by anything. Two consequences, and the second is the one
# that matters: the caller's `|| warn` could not fire, and because the ledger row
# was written BEFORE the launch, the row left `pending` PERMANENTLY — the pending
# query excludes any ident carrying a later `task.grade.spawned` — so nothing
# graded it and no tick ever re-picked it. A denied runas is the EXPECTED first
# failure here, not an exotic one: this row's SEAT REQUIREMENT section is about
# how few seats hold that grant.
#
# Three things now make the outcome knowable, ordered so the likeliest failure is
# also the cheapest:
#   1. `_grader_process_runas_probe` runs BEFORE the row is touched, so a seat
#      that cannot be launched as costs no compensation at all;
#   2. the background pid is kept and checked after a short grace, so a launch
#      that dies on its own (no CLI on PATH, an unwritable directory) is caught
#      as well as one that was refused;
#   3. anything that fails AFTER the assign unwinds it and writes a
#      `task.grade.spawn.failed` row, so the next tick re-picks the delivery.
# The caller's half — emitting `task.grade.spawned` only once this returns 0 —
# is in grader_pool.sh, and neither half is sufficient alone.

# The runas probe. Overridable so the unit harness can make it refuse without
# needing a seat that does not exist. `true` and not the real launch: this asks
# the one question the launch cannot answer for us in time — may this caller
# become that account at all — and it asks it for the price of a fork.
_GRADER_PROCESS_RUNAS_CMD="${_GRADER_PROCESS_RUNAS_CMD:-}"
_grader_process_runas_probe() {  # <seat>
  if [[ -n "$_GRADER_PROCESS_RUNAS_CMD" ]]; then eval "$_GRADER_PROCESS_RUNAS_CMD"; return $?; fi
  sudo -n -u "agent-${1}" true >/dev/null 2>&1
}

# How long to wait before believing the launch. A one-shot that is going to fail
# to start has already failed by the time `sudo` or `bash -lc` returns; nothing
# here waits for the CLI to produce anything.
_GRADER_PROCESS_START_GRACE="${_GRADER_PROCESS_START_GRACE:-2}"

# The CLI the assign goes through, as a variable for exactly one reason: it is
# the seam that lets the harness grade this function for real. Every arm on the
# launch path was previously unreachable because the only way to run the real
# spawn was to let it mutate the live board.
_GRADER_TASK_CLI="${_GRADER_TASK_CLI:-5dive}"

# `_grader_process_live <ident>` — is a one-shot for THIS delivery in the process
# table right now? The trailing space is load-bearing: `ident=DIVE-1` is a prefix
# of `ident=DIVE-10`, and a prefix match would report another grade's process as
# this one's proof of life.
_grader_process_live() {  # <ident>
  local line
  while IFS= read -r line; do
    [[ "$line" == *"$_GRADER_PROCESS_MARK"* && "$line" == *"ident=${1} "* ]] && return 0
  done < <(_grader_process_ps)
  return 1
}

# `_grader_pid_alive <pid>` — alive, and NOT a zombie.
#
# `kill -0` ALONE IS THE WRONG TEST HERE and it was wrong in the dangerous
# direction: a child that has exited and has not been reaped is a zombie, and
# `kill -0` succeeds on a zombie, so a refused launch read as a running one. That
# is the very defect this iteration exists to remove, reintroduced one layer
# down; it was caught by the arm, not by reading the code.
#
# THE STATE READ IS A SEAM, for the reason that made this guard nearly ship
# ungraded: a zombie produced by `cmd &` in a harness is a RACE, because bash
# reaps its own background children from its SIGCHLD handler, so an arm built on
# one passes whether the guard is present or not. Feeding the state directly is
# the only way to grade the branch rather than the timing.
_GRADER_PID_STATE_CMD="${_GRADER_PID_STATE_CMD:-}"
_grader_pid_state() {  # <pid>
  if [[ -n "$_GRADER_PID_STATE_CMD" ]]; then eval "$_GRADER_PID_STATE_CMD"; return 0; fi
  [[ -r "/proc/$1/status" ]] || return 0
  sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$1/status" 2>/dev/null
}
_grader_pid_alive() {  # <pid>
  kill -0 "$1" 2>/dev/null || return 1
  [[ "$(_grader_pid_state "$1")" == Z ]] && return 1
  return 0
}

# `_grader_process_started <pid> <ident>` — did the launch actually start?
#
# THE ARGV MARKER IS THE AUTHORITY, not the wrapper's pid, and the reason is that
# the pid is not always the one-shot's: `setsid` execs in place when its caller is
# not a process-group leader (the tick, a cron child, is that case) but FORKS and
# exits 0 immediately under job control. Every layer of the launch — setsid, sudo,
# bash, and the CLI after it execs — carries the marker in its argv, so a present
# marker is proof of life whatever the pid is doing.
#
# NOTHING HERE MAY BLOCK. A bare `wait` on a pid that is still running would hold
# the tick for the entire duration of the grade, so the liveness test is the
# non-blocking one and `wait` is only ever reached for a pid already known dead,
# where it exists to reap rather than to be read.
_grader_process_started() {  # <pid> <ident>
  local pid="$1" ident="$2"
  _grader_process_live "$ident" && return 0
  # No marker in the process table. A wrapper that is gone or zombified is a
  # launch that did not start — the sudo refusal quinn measured lands here.
  if ! _grader_pid_alive "$pid"; then wait "$pid" 2>/dev/null || true; return 1; fi
  # Alive, holding the marker in its own argv, yet not visible to the probe: the
  # probe itself is broken (no pgrep, no permission). Believing the launch is the
  # only non-blocking answer, and it is the one that does not invent a failure
  # out of a missing instrument.
  return 0
}

# `_grader_process_unwind <seat> <ident> <sid> <rid> <prev_assignee>` — put the
# row back where the failed launch found it.
#
# THE ASSIGN IS REVERTED WITH A DIRECT WRITE, not with `5dive task assign`, and
# that is deliberate: the shape being restored is the delivered one, where the
# assignee IS the row's verifier, and `cmd_task_assign` refuses that move from
# any other assignee (crud.sh, DIVE-3097) — the verb cannot express the undo of
# its own effect here. The previous value is read before the assign and written
# back verbatim, so a row that arrived unassigned goes back to NULL rather than
# to a guessed seat.
#
# The run row is marked `failed` in the same breath: a row reading `running` for
# a process that never existed is the same lie as the ledger's, one table over.
_grader_process_unwind() {  # <seat> <ident> <sid> <rid> <prev_assignee>
  local seat="$1" ident="$2" sid="$3" rid="$4" prev="$5"
  db "UPDATE tasks SET assignee=NULLIF($(sqlq "$prev"),'') WHERE ident=$(sqlq "$ident");" >/dev/null 2>&1 || true
  if [[ -n "$rid" ]]; then
    db "UPDATE runs SET status='failed' WHERE id=$(sqlq "$rid");" >/dev/null 2>&1 || true
  fi
  # A compensating row, not a silent revert. The tick's warn is a log line nobody
  # queries; this is the durable record that a grade was attempted and did not
  # start, and it is why the next tick re-picking the row is a retry rather than
  # a mystery.
  ledger_emit task.grade.spawn.failed ident="$ident" actor="$(task_actor "")" \
    detail="grader process ${sid} on ${seat} did not start; assign reverted, row stays pending" || true
}

_GRADER_PROCESS_LAUNCH="${_GRADER_PROCESS_LAUNCH:-}"
_grader_process_spawn() {  # <seat> <ident> <session_id>
  local seat="$1" ident="$2" sid="$3"
  [[ -n "$seat" && -n "$ident" && -n "$sid" ]] || return 1
  local working_owner=""
  working_owner=$(_grader_non_pool_working_owner "$ident" 2>/dev/null || printf '')
  if [[ -n "$working_owner" ]]; then
    warn "$ident: skip — owner is $working_owner, not a pool seat"
    return 2
  fi
  # BEFORE the row is touched: the failure that needs no compensation.
  if ! _grader_process_runas_probe "$seat"; then
    warn "$ident: grader process on $seat cannot start — no runas for agent-${seat}"
    return 3
  fi
  local prev_assignee=""
  prev_assignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  "$_GRADER_TASK_CLI" task assign "$ident" "$seat" >/dev/null 2>&1 || return 1
  local rid=""
  rid=$(_grader_process_run_open "$seat" "$ident" "$sid")

  local root="${_GRADER_PROCESS_ROOT:-/home/agent-${seat}/graders}"
  local dir="${root}/${ident}-${sid#*#}"
  local logf="${_GRADER_PROCESS_LOG_DIR}/${ident}-${sid#*#}.log"
  if [[ -n "$_GRADER_PROCESS_LAUNCH" ]]; then
    local lrc=0
    "$_GRADER_PROCESS_LAUNCH" "$seat" "$ident" "$sid" "$dir" "$logf" || lrc=$?
    if (( lrc != 0 )); then
      warn "$ident: grader process ${sid} on $seat did not start (launch rc=${lrc})"
      _grader_process_unwind "$seat" "$ident" "$sid" "$rid" "$prev_assignee"
    fi
    return "$lrc"
  fi

  mkdir -p "$_GRADER_PROCESS_LOG_DIR" 2>/dev/null || true
  # The seat's account owns its own tree; the log is opened by the ROOT tick and
  # inherited across the sudo as an already-open fd, so the child never needs
  # write access to /var/log and the log cannot be tampered with by the grade.
  install -d -o "agent-${seat}" -g "agent-${seat}" -m 0755 "$dir" 2>/dev/null \
    || mkdir -p "$dir" 2>/dev/null || true

  local goal; goal=$(_grader_process_goal "$ident" "$sid" "$dir")
  local script
  # %q throughout, including the marker fields. Idents are DB-sourced `DIVE-<n>`
  # and seats are roster names, so nothing here is reachable today — quinn
  # recorded it as defense-in-depth rather than a finding — but a quoted field
  # costs nothing and removes the question from the next reader.
  printf -v script ': %q seat=%q ident=%q session=%q; cd %q || exit 1; exec %q --print %q' \
    "$_GRADER_PROCESS_MARK" "$seat" "$ident" "$sid" "$dir" "$_GRADER_PROCESS_CLI" "$goal"

  # setsid so the grader outlives the tick that started it — the tick is a cron
  # child and its process group is torn down when it returns. Detached from the
  # tick's stdin so a grader can never consume the caller's input.
  setsid sudo -n -u "agent-${seat}" bash -lc "$script" >>"$logf" 2>&1 </dev/null &
  local pid=$!
  # The grace is the whole difference between "started" and "was launched". It is
  # spent once per spawn, in a tick that already spends a sudo and a DB write per
  # spawn, and it buys the only window in which a refusal is still attributable.
  sleep "$_GRADER_PROCESS_START_GRACE" 2>/dev/null || true
  if ! _grader_process_started "$pid" "$ident"; then
    warn "$ident: grader process ${sid} on $seat did not start — see ${logf}"
    _grader_process_unwind "$seat" "$ident" "$sid" "$rid" "$prev_assignee"
    return 4
  fi
  disown 2>/dev/null || true
  return 0
}
