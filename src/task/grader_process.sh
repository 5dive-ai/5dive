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
  5dive task assign "$ident" "$seat" >/dev/null 2>&1 || return 1
  _grader_process_run_open "$seat" "$ident" "$sid" >/dev/null

  local root="${_GRADER_PROCESS_ROOT:-/home/agent-${seat}/graders}"
  local dir="${root}/${ident}-${sid#*#}"
  local logf="${_GRADER_PROCESS_LOG_DIR}/${ident}-${sid#*#}.log"
  if [[ -n "$_GRADER_PROCESS_LAUNCH" ]]; then
    "$_GRADER_PROCESS_LAUNCH" "$seat" "$ident" "$sid" "$dir" "$logf"; return $?
  fi

  mkdir -p "$_GRADER_PROCESS_LOG_DIR" 2>/dev/null || true
  # The seat's account owns its own tree; the log is opened by the ROOT tick and
  # inherited across the sudo as an already-open fd, so the child never needs
  # write access to /var/log and the log cannot be tampered with by the grade.
  install -d -o "agent-${seat}" -g "agent-${seat}" -m 0755 "$dir" 2>/dev/null \
    || mkdir -p "$dir" 2>/dev/null || true

  local goal; goal=$(_grader_process_goal "$ident" "$sid" "$dir")
  local script
  printf -v script ': %s seat=%s ident=%s session=%s; cd %q || exit 1; exec %s --print %q' \
    "$_GRADER_PROCESS_MARK" "$seat" "$ident" "$sid" "$dir" "$_GRADER_PROCESS_CLI" "$goal"

  # setsid so the grader outlives the tick that started it — the tick is a cron
  # child and its process group is torn down when it returns. Detached from the
  # tick's stdin so a grader can never consume the caller's input.
  setsid sudo -n -u "agent-${seat}" bash -lc "$script" >>"$logf" 2>&1 </dev/null &
  disown 2>/dev/null || true
  return 0
}
