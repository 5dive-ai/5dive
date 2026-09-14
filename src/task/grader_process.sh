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
# This file is the other spawn shape. One EPHEMERAL CLONED SEAT per delivery,
# created by the tick, woken onto the row once, and removed by the next tick that
# sees its grade resolved. N of them run under one auth profile, and the cap is
# read from the LIVE CLONE SEATS rather than from lifecycle rows.
#
# ══ DIVE-4496: WHY IT IS A SEAT AND NOT A HEADLESS ONE-SHOT ══
# It was a one-shot (`claude --print` under `sudo -n -u agent-<seat>`) until the
# live arm ran. MEASURED 2026-09-14 05:45Z, process mode ON: the one-shot spawned
# to grade DIVE-4482 died in 2 seconds with "Not logged in" and left a run record
# reading `running` that only DIVE-4418's six-hour bound would ever close. The
# cause is structural, not a tuning problem: the seat's auth profile is injected
# by `5dive-agent-start`, and a one-shot never runs it, so a one-shot has no
# credential and can never have one without re-implementing that injection here.
#
# A CLONE INHERITS THE WHOLE RAIL INSTEAD OF RE-BUILDING IT. `agent create` runs
# the start script, so the auth profile IS injected — the exact thing the one-shot
# lacked. It also arrives with the things the one-shot header below says process
# mode does not have: a systemd unit, a tmux pane, `agent logs`, the supervisor
# pane classifiers and the liveness rails. So `journal_unit` on the run row is now
# a REAL unit name rather than the deliberate blank the one-shot had to write, and
# the "runtime-rail extensions are owed" caveat is withdrawn rather than deferred.
#
# lodar, 2026-09-14 06:05Z: "if Parallel grading is so complex maybe we should
# just clone it and rm after it done?" and 06:06Z "keep it simple" — ONE create,
# ONE wake, ONE remove. There is no new daemon and no second log format here; the
# remove is the same sweep that handles a clone dying mid-turn, because those are
# the same question asked one tick apart (06:07Z: "the only downside i see it mid
# turn death and then we forget to delete clone").
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
# ══ WHAT THIS MODE COSTS, STATED RATHER THAN LEFT TO BE FOUND ══
# A clone is not free the way a wake is. `agent create` is a unix account plus a
# runtime provision plus a sudoers render — measured in this repo's own comment
# on `_grader_spawn_session` at ~50s, and re-measured under DIVE-4496 on this box
# (the number is in the PR body, not here, because a constant in a comment rots).
# Against a grade that runs 4-9 minutes that is single-digit percent overhead, and
# it buys the credential the one-shot could not have at any price.
#
# THE ACCOUNT FLOOR IS STILL PER AUTH PROFILE, NOT PER SEAT. A clone borrows the
# pool seat's `--auth-profile`, so N clones off one pool seat share ONE window and
# the pool's existing `mark at 5h=…%` check is the real gate. Cloning multiplies
# seats, never budgets.
#
# ══ WHAT A CLONE MUST NOT BE ══
# It is created `--channels=none --no-skills --no-team-bot --no-heartbeat`. The
# last of those is load-bearing and is not a performance choice: a clone with a
# heartbeat is a seat that PICKS ITS OWN NEXT ROW off the shared queue, so an
# ephemeral grader would start doing arbitrary fleet work and then be removed
# mid-turn by its own sweep. One wake, one row, one verdict.
#
# The argv marker, kept because the clone's grading CLI still carries it and it is
# what makes a clone's own work attributable in `ps` beside the fleet's.
_GRADER_PROCESS_MARK="${_GRADER_PROCESS_MARK:-5dive-grader-oneshot}"

# Per-ACCOUNT parallelism once the per-seat serial queue is gone. In session mode
# the per-seat cap is 1 and it must stay 1 — a second wake there is a queue, not
# a grader (DIVE-4410). In process mode that constant is the thing to RAISE, not
# to delete: the account floor check is still the real gate, and this bound is
# what stops one seat's name absorbing an entire tick's worth of deliveries
# before the floor is ever consulted.
_GRADER_MAX_PER_SEAT_PROCESS="${_GRADER_MAX_PER_SEAT_PROCESS:-4}"

# A clone needs neither of the one-shot's two per-grade knobs: its HOME is its
# private working directory (nothing else has an account there, so two graders can
# never fight over one index.lock) and its unit's JOURNAL is its log. What is left
# is the name of the grading CLI, which is read for one thing only — the liveness
# test the sweep runs against the clone's own account.
_GRADER_PROCESS_CLI="${_GRADER_PROCESS_CLI:-claude}"

# ══ DIVE-4496: THE UNIT OF A GRADE IS A CLONE SEAT, SO THAT IS WHAT IS COUNTED ══
#
# In the one-shot shape this was an argv scan: the process had no unit and no
# registry row, so its own command line was the only record it existed. A clone
# has a REGISTRY ROW, which is both cheaper to read and the same thing `agent rm`
# keys on — so the sweep and the cap cannot disagree about which clones exist.
#
# THE CLONE NAME IS THE SESSION ID, and that is what makes ownership unambiguous
# without a second table: session `quinn#3` is seat `gr-quinn-3`. The row asked
# for the clone to be named by the RUN ID and it cannot be — `valid_name`
# (cmd_agent_create.sh) caps a seat at 16 lowercase chars and a run id is
# `gr-<utc-timestamp>-<pid>-<n>`, 29 characters with two uppercase letters in it.
# So the clone is named by the run's IDENTITY instead of its id: the same
# `<pool seat>` and `<n>` the run row carries in `session_id`, which is the pair
# that actually answers "whose grade is this, and which of that seat's grades".
# The full run id stays on the run row and the run row names the clone in `agent`,
# so the mapping is total in both directions.
_GRADER_CLONE_PREFIX="${_GRADER_CLONE_PREFIX:-gr-}"

# THE HOME ROOT AND THE QUARANTINE DIRECTORY ARE NAMED PRIVATELY HERE, AND THAT
# IS A BUILD CONSTRAINT, NOT A STYLE CHOICE (DIVE-4496 iteration 2).
#
# The CLI-wide overrides for these two live as TOP-LEVEL assignments in
# src/cmd_agent_create.sh (the "STATE_DIR-style override ... what lets the
# rootless unit harness drive these paths" clause). `lazy_tokens` matches a bare
# word anywhere in a file — comments included, deliberately — so merely NAMING
# either of those two globals here would have made this module depend on that
# one. This module is in the universal `__MODDEPS` set, so that single edge
# closes over every module and every verb in the CLI then loads the agent-create
# module: measured on the bundle, `whoami` 8 -> 9 modules, `task ls` 13 -> 14,
# `heartbeat ls` 11 -> 12. A fleet-wide startup cost.
#
# And it bought nothing. Those globals are themselves only `${NAME:-/home}` over
# the environment, so a `:-` fallback read here supplied exactly what loading the
# provider would have. The private names below keep the test seam (the harness
# sets them) and carry the same defaults, with no edge.
_GRADER_HOME_ROOT="${_GRADER_HOME_ROOT:-/home}"
_GRADER_QUARANTINE_DIR="${_GRADER_QUARANTINE_DIR:-${_GRADER_HOME_ROOT}/.5dive-reaped}"

# `_grader_clone_name <session-id>` — `quinn#3` -> `gr-quinn-3`, or non-zero.
#
# REFUSES rather than truncates. A truncated seat name would still create, and it
# would create a seat whose name no longer maps back to any session — the sweep
# would then read it as an orphan and reap a live grade every tick. A pool seat
# whose name is too long to clone is a configuration fact the operator must see,
# not one this function may paper over.
_grader_clone_name() {  # <session-id>
  local sid="$1" seat="${1%%#*}" n="${1##*#}" name
  [[ -n "$sid" && "$sid" == *#* && -n "$seat" && "$n" =~ ^[0-9]+$ ]] || return 1
  name="${_GRADER_CLONE_PREFIX}${seat}-${n}"
  # The same shape `valid_name` enforces, re-asserted here so the refusal is
  # attributable to the clone lane rather than surfacing as an `agent create`
  # usage error several layers down.
  [[ "$name" =~ ^[a-z][a-z0-9-]*$ && ${#name} -le 16 ]] || return 1
  printf '%s' "$name"
}

# `_grader_clone_pool_seat <clone>` — `gr-quinn-3` -> `quinn`. The inverse, and
# it is a pure string operation on purpose: the per-seat load reading runs once
# per tick over every clone, and a DB round trip per clone to recover a name the
# name already contains is a cost with no answer attached.
_grader_clone_pool_seat() {  # <clone>
  local c="${1#${_GRADER_CLONE_PREFIX}}"
  [[ "$1" == "${_GRADER_CLONE_PREFIX}"* && "$c" == *-* ]] || return 1
  printf '%s' "${c%-*}"
}

# `_grader_clone_ls` — one live clone seat name per line.
#
# The REGISTRY is the source, not `getent passwd`, because the registry is what
# `agent rm` reads and refuses on: a clone this returns must be one the sweep can
# actually remove. A half-created seat with an account and no registry row is a
# real state and it is NOT this lane's to clean — `5dive doctor
# --category=registry --fix` (doctor_check_orphan_seats) already owns that class
# and has since DIVE-4340.
_GRADER_CLONE_LS_CMD="${_GRADER_CLONE_LS_CMD:-}"
_grader_clone_ls() {
  if [[ -n "$_GRADER_CLONE_LS_CMD" ]]; then eval "$_GRADER_CLONE_LS_CMD"; return 0; fi
  [[ -r "${REGISTRY:-}" ]] || { printf ''; return 0; }
  jq -r --arg p "$_GRADER_CLONE_PREFIX" \
    '.agents | keys[] | select(startswith($p))' "$REGISTRY" 2>/dev/null || printf ''
}

# `_grader_process_count` — live clone seats, all pool seats or one.
#
# Kept under its old name because it is the tick's cap reading and the tick is
# unchanged by this row (the row's instruction is "re-point the LAUNCH; keep the
# tick"). What changed is only what a "process" IS.
_grader_process_count() {  # [<seat>]
  local want="${1:-}" clone n=0 pool
  while IFS= read -r clone; do
    [[ -n "$clone" ]] || continue
    if [[ -n "$want" ]]; then
      pool=$(_grader_clone_pool_seat "$clone" 2>/dev/null || printf '')
      [[ "$pool" == "$want" ]] || continue
    fi
    n=$((n+1))
  done < <(_grader_clone_ls)
  printf '%s' "$n"
}

# `_grader_process_seat_loads` — the per-POOL-SEAT reading, in the same
# `<seat><US><n>` shape `_grader_seat_loads` emits, so the tick's pick loop is
# identical in both modes and only its SOURCE of truth changes.
#
# Per POOL seat and never per clone: a clone is one grade by construction, so a
# per-clone load is always 1 and would make the cap meaningless. The number the
# lane must bound is how many clones one AUTH PROFILE is carrying, and the pool
# seat is the name that profile is reached through.
_grader_process_seat_loads() {
  local clone pool
  local -A load=()
  while IFS= read -r clone; do
    [[ -n "$clone" ]] || continue
    pool=$(_grader_clone_pool_seat "$clone" 2>/dev/null || printf '')
    [[ -n "$pool" ]] || continue
    load["$pool"]=$(( ${load[$pool]:-0} + 1 ))
  done < <(_grader_clone_ls)
  for pool in "${!load[@]}"; do printf '%s\x1f%s\n' "$pool" "${load[$pool]}"; done
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
  # DIVE-4496: keyed on `session_id` ALONE, no longer on `agent`. In clone mode
  # `runs.agent` holds the CLONE (`gr-quinn-3`), not the pool seat, so the old
  # `agent=<seat>` clause would find zero prior rows and hand out `quinn#1`
  # forever — every clone colliding on one name, and every one of them reusing a
  # session id already spent. The `session_id LIKE '<seat>#%'` clause is the one
  # that was always doing the selecting.
  n=$(db "SELECT COALESCE(MAX(CAST(substr(session_id, instr(session_id,'#')+1) AS INTEGER)),0)+1
            FROM runs
           WHERE role='grader'
             AND session_id LIKE $(sqlq "${seat}#")||'%';" 2>/dev/null || printf '')
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  printf '%s#%s' "$seat" "$n"
}

# `_grader_process_run_open <seat> <ident> <session_id>` — the run record DO (3)
# asks for. `runs` already carries `session_id` and `journal_unit`
# (src/lib/tasks_db.sh), so the shape needed no migration; nothing wrote two live
# rows for one seat before this.
#
# DIVE-4496: journal_unit IS NOW A REAL UNIT, and the change is the whole point
# of the clone shape. A one-shot had none, so this column was written EMPTY on
# purpose — an empty column being a readable gap where a plausible unit name that
# resolves to nothing is a lie. A clone is a seat: `5dive-agent@gr-quinn-3.service`
# exists, `agent logs gr-quinn-3` works, and the supervisor's pane classifiers can
# read a rate-limit refusal off it. The gap is closed rather than documented.
#
# `agent` HOLDS THE CLONE, NOT THE POOL SEAT, and that is the ownership record the
# sweep runs on: given a clone seat there is exactly one query for its grade
# (`runs WHERE agent=<clone>`), and given a run row the pool seat whose budget it
# spends is in `session_id`. Writing the pool seat here instead would leave the
# sweep with no way to tell which of quinn's three clones a row belonged to.
_grader_process_run_open() {  # <seat> <ident> <session_id> [<clone>]
  local seat="$1" ident="$2" sid="$3" clone="${4:-}" rid tid unit=""
  rid="gr-$(date -u +%Y%m%dT%H%M%SZ)-$$-${sid#*#}"
  tid=$(db "SELECT id FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  [[ "$tid" =~ ^[0-9]+$ ]] || tid=NULL
  [[ -n "$clone" ]] && unit="5dive-agent@${clone}.service"
  db "INSERT INTO runs (id, task_id, ident, agent, role, runtime_type, session_id,
                        journal_unit, wake_reason, status)
      VALUES ($(sqlq "$rid"), ${tid}, $(sqlq "$ident"), $(sqlq "${clone:-$seat}"), 'grader',
              'clone', $(sqlq "$sid"), $(sqlq "$unit"), 'task.grade.spawned', 'running');" >/dev/null 2>&1 || true
  printf '%s' "$rid"
}

# The instruction the clone is woken with. Deliberately the SAME instruction the
# session-mode wake sends, plus the two facts only an ephemeral seat needs: it is
# alone (nothing will pick this row up if it stops early, because the clone has no
# heartbeat) and its home is its own to check out into.
_grader_process_goal() {  # <ident> <session_id> <clone>
  printf 'You are an ephemeral grader seat (%s, session %s) created for this one delivery: you have no inbox, no heartbeat and no next row, and this seat is removed once your verdict lands. Grade delivered task %s. Your home directory is yours alone — make any checkout or worktree you need inside it, never in a shared checkout. Read the row, grade the delivery, checkpoint each verified arm to the row as you go, then run 5dive task done or 5dive task reject. Do not wait for CI; grade what is at the delivered head.' \
    "$3" "$2" "$1"
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

# `_grader_clone_live <clone>` — is this clone actually WORKING right now?
#
# ══ THE PID IN THE RUN ID IS NOT THE GRADE'S PID, AND IT NEVER WAS ══
#
# This row's live specimen (`gr-20260914T054510Z-1554431-1`, measured by quinn
# 2026-09-14 06:22Z) came with the suggestion that the cheapest correct liveness
# test is `kill -0` on the pid the run id embeds. It is not, and the specimen is
# itself the proof: `_grader_process_run_open` builds that id from `$$`, and `$$`
# in the tick is the TICK's shell — a cron child that returns in seconds. pid
# 1554431 was dead 37 minutes later because the tick was dead, not because the
# grade was. Keyed on that pid, the sweep would reap every clone it had just
# created, on the very next tick, while the grade was running. So the embedded pid
# is useful for exactly one thing (telling two run ids apart) and is never read as
# liveness here.
#
# WHAT IS READ INSTEAD is the clone's own account: a grading CLI running as
# `agent-<clone>`. That is the thing the mutant kills (`SIGKILL a clone's claude
# mid-grade`) and the thing a wedged-but-alive grade still has, which is the pair
# the sweep has to tell apart. The unit is deliberately NOT the test: the template
# restarts, and a restarted clone comes back with an empty session and no goal —
# it will never resume the grade, so `is-active` would report a seat that is up
# and idle as a grade in progress.
#
# IT FAILS TOWARD REAPING, and that direction is chosen. A clone wrongly reaped
# costs one re-queued delivery (the next tick grades it again); a dead clone
# wrongly believed alive costs the delivery its grade until the six-hour bound —
# which is the failure this row exists to remove.
_GRADER_CLONE_LIVE_CMD="${_GRADER_CLONE_LIVE_CMD:-}"
_grader_clone_live() {  # <clone>
  local clone="$1"
  [[ -n "$clone" ]] || return 1
  if [[ -n "$_GRADER_CLONE_LIVE_CMD" ]]; then eval "$_GRADER_CLONE_LIVE_CMD"; return $?; fi
  pgrep -u "agent-${clone}" -f "$_GRADER_PROCESS_CLI" >/dev/null 2>&1
}

# How long after its run row opens a clone is believed alive without being asked.
# `agent create` provisions a runtime and the CLI is not up the instant the row is
# written, so a liveness test inside this window would reap every clone during its
# own startup. It is a floor on the AGE OF THE RUN ROW, not a sleep: nothing waits.
_GRADER_CLONE_START_GRACE_S="${_GRADER_CLONE_START_GRACE_S:-300}"

# ══ DIVE-4496: THE PID MACHINERY IS GONE, NOT MOVED ══
#
# Iteration 2 of DIVE-4417 kept a background pid and probed it for zombie-vs-live
# (`_grader_pid_state`, `_grader_pid_alive`, `_grader_process_started`), because
# the launch was `setsid sudo … &` and a backgrounded launch's exit status is
# never read by anything. There is no background pid here: `agent create` is
# called SYNCHRONOUSLY and its exit status IS the answer to "did the launch
# start", so the entire question those three functions reconstructed is now
# answered directly. Their arms went with them; the arms that replaced them grade
# the create's rc, the credential refusal and the sweep.
#
# THE COST OF SYNCHRONOUS IS A SLOW TICK, and it is bounded rather than ignored.
# A create is a unix account plus a runtime provision plus a sudoers render, so
# the tick pays that wall time inline. `_GRADER_CLONE_MAX_CREATES_PER_TICK`
# (read by the tick) is 1: the lane reaches its seat cap over consecutive ticks
# instead of inside one. Measured against the live cron — `*/5` with NO flock —
# one create keeps a tick an order of magnitude clear of its own period, where
# four would risk overlapping ticks double-spawning a delivery. The cron line
# should also carry `flock -n` and that is an ops change, not this file's.

# `_grader_clone_create <clone> <pool_seat>` — the seat, and nothing else.
#
# `--channels=none --no-skills --no-team-bot`: a grader has no inbox, no plugin
# surface and no team bot to bind. `--no-heartbeat` is the load-bearing one — see
# the header: a clone with a heartbeat picks its own next row off the shared queue.
#
# The auth profile is the POOL SEAT's, which is the whole reason a pool seat is
# still chosen before a clone is created: the floor check the tick already ran was
# a reading of that profile's window, and a clone created on any other profile
# would be a grade spent against a budget nobody measured.
_GRADER_CLONE_CREATE_CMD="${_GRADER_CLONE_CREATE_CMD:-}"
_grader_clone_create() {  # <clone> <pool_seat>
  local clone="$1" pool="$2" profile=""
  [[ -n "$clone" && -n "$pool" ]] || return 1
  if [[ -n "$_GRADER_CLONE_CREATE_CMD" ]]; then eval "$_GRADER_CLONE_CREATE_CMD"; return $?; fi
  if [[ -r "${REGISTRY:-}" ]]; then
    profile=$(jq -r --arg n "$pool" '.agents[$n].authProfile // empty' "$REGISTRY" 2>/dev/null || printf '')
  fi
  # NO PROFILE IS A REFUSAL, not a create with the default. An unpinned clone
  # resolves whatever credential the box's default names, which is exactly the
  # "authenticated by accident" shape the one-shot failed in — and this time it
  # would fail after spending a seat.
  [[ -n "$profile" ]] || { warn "grader clone ${clone}: pool seat ${pool} has no auth profile to clone"; return 5; }
  "$_GRADER_TASK_CLI" agent create "$clone" --type=claude --auth-profile="$profile" \
    --channels=none --no-skills --no-team-bot --no-heartbeat >/dev/null 2>&1 || return $?
  _grader_clone_record_origin "$clone" "$pool"
}

# ══ DIVE-4521 (precondition 4): WRITE THE LINEAGE THE REGISTRY CANNOT INFER ══
#
# `5dive agent info` returns type, profile, workdir, created — and nothing
# recording parent or origin, so the `writer != grader` guard compares names and
# a clone of the maker passes it (DIVE-4514). The dispatcher's gate
# (`_grader_seat_origin`, grader_pool.sh) can read a clone's origin out of the
# name THIS lane mints, but every other reader of the registry — a future guard,
# `agent info`, a human — cannot. So the one moment that knows the answer records
# it, as the `origin` field that page asks for.
#
# NON-FATAL BY DESIGN. The seat exists and can grade; the field is for readers,
# and the dispatcher's own gate does not depend on it (the name carries the same
# fact). Failing the create over a registry write would trade a working grade for
# a missing annotation — and the tick may run where `registry_write`'s root-owned
# atomic replace is not permitted.
_GRADER_CLONE_ORIGIN_CMD="${_GRADER_CLONE_ORIGIN_CMD:-}"
_grader_clone_record_origin() {  # <clone> <pool_seat>
  local clone="${1:-}" pool="${2:-}"
  [[ -n "$clone" && -n "$pool" ]] || return 0
  if [[ -n "$_GRADER_CLONE_ORIGIN_CMD" ]]; then eval "$_GRADER_CLONE_ORIGIN_CMD"; return 0; fi
  [[ -w "${REGISTRY:-}" ]] || { warn "grader clone ${clone}: registry not writable — lineage origin=${pool} NOT recorded"; return 0; }
  local updated
  updated=$(jq --arg c "$clone" --arg o "$pool" \
    'if (.agents|has($c)) then .agents[$c].origin = $o else . end' "$REGISTRY" 2>/dev/null) || {
      warn "grader clone ${clone}: could not compute lineage origin=${pool}"; return 0; }
  [[ -n "$updated" ]] || { warn "grader clone ${clone}: empty registry read; lineage origin=${pool} NOT recorded"; return 0; }
  printf '%s\n' "$updated" | registry_write 2>/dev/null \
    || warn "grader clone ${clone}: registry write failed; lineage origin=${pool} NOT recorded"
  return 0
}

# `_grader_clone_creds <clone> <pool_seat>` — the READ credential, copied.
#
# ══ WHAT IS COPIED, AND WHY THESE TWO FILES AND NOT A GRANT ══
# `/usr/local/sbin/verifier-gh-read-token.sh` mints for `SEATS=(quinn main2)` only
# (measured: its own default argv), so a clone is born with no GitHub credential
# at all and would grade blind. The two files are the whole of that credential:
# `~/.config/gh/hosts.yml` and `~/.config/5dive/gh-read-tokens.env`. They hold
# `ghs_` GitHub App INSTALLATION tokens scoped contents:read + metadata:read +
# pull_requests:read, with a ~1 hour TTL — so the copy expires with or before the
# grade and there is nothing to revoke. That short life is the security property,
# not a limitation of the copy.
#
# ══ WHAT MUST NEVER BE COPIED, ENFORCED AND NOT JUST DOCUMENTED ══
# The 5dive-bot classic PAT (`/etc/5dive/connectors/github-bot.env`, scopes
# `repo, workflow`) is full WRITE on everything, and handing it to a throwaway
# seat would also route around the delegated-push review gate. That is the mint
# script's own rule. So the copy REFUSES on any `gho_`/`ghp_`-shaped token in the
# source, which is a content test rather than a path test: a write token that
# reaches these files by some future accident is caught by the thing that copies
# them, not by the naming of the file it arrived in.
_GRADER_CLONE_CREDS_CMD="${_GRADER_CLONE_CREDS_CMD:-}"
_GRADER_CLONE_CRED_FILES="${_GRADER_CLONE_CRED_FILES:-.config/gh/hosts.yml .config/5dive/gh-read-tokens.env}"
_grader_clone_creds() {  # <clone> <pool_seat>
  local clone="$1" pool="$2" rel src dst
  [[ -n "$clone" && -n "$pool" ]] || return 1
  if [[ -n "$_GRADER_CLONE_CREDS_CMD" ]]; then eval "$_GRADER_CLONE_CREDS_CMD"; return $?; fi
  local home_root="$_GRADER_HOME_ROOT"
  for rel in $_GRADER_CLONE_CRED_FILES; do
    src="${home_root}/agent-${pool}/${rel}"
    dst="${home_root}/agent-${clone}/${rel}"
    # A MISSING SOURCE IS A REFUSAL. The caller unwinds on it, which is the row's
    # "a clone that cannot run the read probe against its delivery is unwound on
    # the spot, not left to grade blind" — asked one step earlier, where it costs
    # nothing.
    [[ -r "$src" ]] || { warn "grader clone ${clone}: ${pool} has no ${rel} to copy"; return 3; }
    # ══ DIVE-4521 (precondition 3): THE ALPHABET IS EVERY WRITE-CAPABLE SHAPE ══
    # It read `gh[op]_` — gho_/ghp_, and deliberately NOT ghs_, the read-only
    # installation token that is supposed to travel. `ghu_` (a user-to-server
    # token) and a fine-grained `github_pat_` are both write-capable and neither
    # can appear in these two files TODAY, which is exactly why this widened
    # before the flip: "cannot appear today" is a standing fact about a dark
    # lane, and this row is the moment it stops being one. A content test costs
    # the same over four shapes as over two.
    # `ghs_` stays out of the class on purpose; adding it would refuse the very
    # credential the clone is created to carry.
    if grep -qE 'gh[opu]_[A-Za-z0-9_]{8}|github_pat_[A-Za-z0-9_]{8}' "$src" 2>/dev/null; then
      warn "grader clone ${clone}: REFUSED to copy ${rel} — it carries a write-capable token (gho_/ghp_/ghu_/github_pat_); read-only ghs_ installation tokens only"
      return 4
    fi
    # ══ THE DIRECTORY IS CREATED OWNED BY THE CLONE, NOT BY ROOT ══
    # MEASURED on the first live arm, 2026-09-14: `install -D` creates the missing
    # parents ROOT-OWNED and only chowns the FILE, and `gh` does not merely read
    # its config dir — on first use it MIGRATES and writes `config.yml` into it.
    # So the clone got a perfectly readable hosts.yml inside a directory it could
    # not write, `gh auth token` died with "failed to write config after
    # migration: permission denied", `5dive gh` read that as "you hold NO gh
    # credential on this seat" and routed the read to the bot — which needs a
    # NOPASSWD grant the clone lacks. One root-owned directory presented as a
    # missing credential three layers away. `install -d` applies the owner to
    # EVERY component it creates, which is the difference that matters here.
    install -d -o "agent-${clone}" -g "agent-${clone}" -m 0700 "${dst%/*}" 2>/dev/null \
      || { warn "grader clone ${clone}: could not create ${rel%/*} owned by the clone"; return 3; }
    install -o "agent-${clone}" -g "agent-${clone}" -m 0600 "$src" "$dst" 2>/dev/null \
      || { warn "grader clone ${clone}: could not install ${rel}"; return 3; }
  done
  return 0
}

# `_grader_clone_wake <clone> <ident> <session_id>` — ONE wake, onto ONE row.
#
# ══ NOT `heartbeat wake-task`, AND THE REASON IS MEASURABLE IN THE DISPATCH ══
# The row's direction says "heartbeat-wake it onto the row as verifier", and that
# verb is the wrong instrument for a clone. `_hb_task_loop_note`
# (cmd_heartbeat.sh) picks which of its variants to send by comparing the woken
# seat's name against the row's `verifier` COLUMN. A clone is never that column's
# value — the row's verifier is the routed seat (quinn), and the clone is a
# throwaway grading on its behalf — so `vfier != name` selects the MAKER variant,
# which tells the clone that its `task done` "DELIVERS rather than closes" and
# that the work is its to do. A wake that hands the grader the maker's contract is
# worse than no wake: it produces a confident turn doing the wrong job.
#
# `agent send` carries its OWN instruction, so the framing comes from this file
# rather than from a column the clone does not appear in. It is also exactly what
# `_grader_spawn_session` does today, which means the clone lane and the session
# lane wake with the same words and a verdict from one is comparable to a verdict
# from the other.
#
# The `_A2A_GUARD` is DIVE-4295's: if the row closes or moves to another seat
# while this copy is spooled, the copy is dropped rather than typed.
# `assignee_owns` and not a verifier clause — the clone IS the assignee here (the
# assign above is what makes that true) and is NOT the verifier.
_GRADER_CLONE_WAKE_CMD="${_GRADER_CLONE_WAKE_CMD:-}"
_grader_clone_wake() {  # <clone> <ident> <session_id>
  local clone="$1" ident="$2" sid="${3:-}"
  [[ -n "$clone" && -n "$ident" ]] || return 1
  if [[ -n "$_GRADER_CLONE_WAKE_CMD" ]]; then eval "$_GRADER_CLONE_WAKE_CMD"; return $?; fi
  local msg; msg=$(_grader_process_goal "$ident" "$sid" "$clone")
  _A2A_GUARD="task:${ident}:${clone}:assignee_owns" \
  "$_GRADER_TASK_CLI" agent send "$clone" "$msg" >/dev/null 2>&1
}

# `_grader_clone_remove <clone>` — the seat goes away, its home is quarantined.
#
# NOT `--purge-home`. `agent rm` already moves the home to
# `/home/.5dive-reaped/<clone>-<ts>` root-owned 0700 (DIVE-2138), which is the
# reap backup the row asks for, and a grade's working tree is occasionally the
# only record of what it looked at. `_grader_clone_reaped_prune` caps its age so
# the quarantine does not become the disk leak.
_GRADER_CLONE_REMOVE_CMD="${_GRADER_CLONE_REMOVE_CMD:-}"
_grader_clone_remove() {  # <clone>
  local clone="$1"
  [[ -n "$clone" ]] || return 1
  if [[ -n "$_GRADER_CLONE_REMOVE_CMD" ]]; then eval "$_GRADER_CLONE_REMOVE_CMD"; return $?; fi
  "$_GRADER_TASK_CLI" agent rm "$clone" >/dev/null 2>&1
}

# `_grader_clone_reaped_prune` — cap the age of the quarantine.
#
# ONLY `<prefix>*` ENTRIES, never the whole of the quarantine directory that
# src/cmd_agent_create.sh moves a removed home into (its DIVE-2138 "quarantine,
# not delete" clause): that directory also holds the homes of seats an operator
# removed by hand, and a grader lane has no business deciding when those expire.
_GRADER_REAPED_MAX_DAYS="${_GRADER_REAPED_MAX_DAYS:-7}"
_GRADER_CLONE_PRUNE_CMD="${_GRADER_CLONE_PRUNE_CMD:-}"
_grader_clone_reaped_prune() {
  if [[ -n "$_GRADER_CLONE_PRUNE_CMD" ]]; then eval "$_GRADER_CLONE_PRUNE_CMD"; return 0; fi
  local dir="$_GRADER_QUARANTINE_DIR" d
  [[ -d "$dir" ]] || return 0
  d="${_GRADER_REAPED_MAX_DAYS}"; [[ "$d" =~ ^[0-9]+$ ]] || d=7
  find "$dir" -maxdepth 1 -mindepth 1 -type d -name "${_GRADER_CLONE_PREFIX}*" \
    -mtime "+${d}" -exec rm -rf -- {} + 2>/dev/null || true
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

# `_grader_process_spawn <seat> <ident> <session_id>` — create ONE clone, wake it.
#
# ORDER IS THE WHOLE CORRECTNESS ARGUMENT here, and it is the order that makes
# every failure cheap in proportion to how likely it is:
#
#   1. non-pool owner, then runas — neither touches the row or the fleet;
#   2. NAME — refused before any spend, because a pool seat whose name cannot be
#      cloned fails identically on every tick and must say so;
#   3. CREATE the clone. Nothing on the row yet: a failed create leaves a board
#      byte-identical to before and the next tick retries;
#   4. CREDS. A refusal here removes the clone again — the "unwound on the spot"
#      the row asks for — and still nothing has touched the row;
#   5. only NOW assign the row and open the run record, i.e. once the thing being
#      recorded actually exists;
#   6. WAKE. A failed wake unwinds both (assign reverted, run marked failed,
#      compensating ledger row) AND removes the clone, so the delivery goes back
#      to pending with no seat left behind.
#
# The caller's half — emitting `task.grade.spawned` only once this returns 0 —
# is in grader_pool.sh, and neither half is sufficient alone. That is DIVE-4417
# iteration 2's finding and it is unchanged: a spawn row written ahead of a
# launch that never started is PERMANENT, because the pending query excludes any
# ident carrying a later `task.grade.spawned`.
#
# ══ THERE IS NO WHOLE-LAUNCH SEAM ANY MORE, AND THAT IS DELIBERATE ══
# DIVE-4417 had `_GRADER_PROCESS_LAUNCH`, one seam standing in for the entire
# launch, because the launch was one `setsid sudo` line. It cannot stand in for
# this one: the assign and the run record sit BETWEEN the create and the wake
# (nothing may be written to the row until the clone exists, and nothing may be
# woken until the row is written), so a seam that swallowed the whole sequence
# would take the ordering — the only thing worth grading here — out of reach of
# every arm. The four per-step seams above replace it, and the harness drives the
# caller's contract through the WAKE seam, which is the step that fails after the
# row has been touched.
_grader_process_spawn() {  # <seat> <ident> <session_id>
  local seat="$1" ident="$2" sid="$3"
  [[ -n "$seat" && -n "$ident" && -n "$sid" ]] || return 1
  local working_owner=""
  working_owner=$(_grader_non_pool_working_owner "$ident" 2>/dev/null || printf '')
  if [[ -n "$working_owner" ]]; then
    warn "$ident: skip — owner is $working_owner, not a pool seat"
    return 2
  fi
  # BEFORE the row is touched: the failure that needs no compensation. The clone
  # is created by this caller, but the creds are copied OUT of the pool seat's
  # home, which still needs the runas the one-shot needed.
  if ! _grader_process_runas_probe "$seat"; then
    warn "$ident: grader clone for $seat cannot start — no runas for agent-${seat}"
    return 3
  fi
  local clone=""
  clone=$(_grader_clone_name "$sid" 2>/dev/null || printf '')
  if [[ -z "$clone" ]]; then
    warn "$ident: cannot derive a clone seat name from session '${sid}' — a seat name is at most 16 lowercase chars (valid_name); rename the pool seat or shorten it"
    return 5
  fi

  if ! _grader_clone_create "$clone" "$seat"; then
    warn "$ident: could not create grader clone ${clone} off ${seat} — row untouched, next tick retries"
    return 6
  fi
  if ! _grader_clone_creds "$clone" "$seat"; then
    warn "$ident: grader clone ${clone} has no read credential — removing it rather than grading blind"
    _grader_clone_remove "$clone" || warn "$ident: grader clone ${clone} could not be removed; the sweep will take it"
    return 7
  fi
  # THE PROBE, RUN AS THE CLONE, and it is a different question from the one the
  # tick already answered. The tick's `_grader_can_read` ran against the POOL
  # SEAT, because that is the name it was choosing between; whether the COPY
  # landed and works is a property of the clone, and the two come apart exactly
  # where it matters — an expired token (they live ~1h), a copy that silently
  # failed, a clone whose account cannot reach the credential it now owns. A
  # clone that cannot read its own delivery would grade blind and return a
  # confident FAIL about a diff it never saw, so it is unwound on the spot.
  if declare -F _grader_can_read >/dev/null 2>&1 && ! _grader_can_read "$clone" "$ident"; then
    warn "$ident: grader clone ${clone} holds a credential that cannot read the delivery — removing it rather than grading blind"
    _grader_clone_remove "$clone" || warn "$ident: grader clone ${clone} could not be removed; the sweep will take it"
    return 9
  fi

  local prev_assignee=""
  prev_assignee=$(db "SELECT COALESCE(assignee,'') FROM tasks WHERE ident=$(sqlq "$ident");" 2>/dev/null || printf '')
  # ASSIGNED TO THE CLONE, not to the pool seat. The verdict path, the
  # double-spawn guard and the reclaim rails all read `assignee`, and the seat
  # that is about to be woken is the clone — a row owned by the pool seat while
  # a clone grades it is a grade no rail can attribute to the thing doing it.
  if ! "$_GRADER_TASK_CLI" task assign "$ident" "$clone" >/dev/null 2>&1; then
    warn "$ident: could not assign to grader clone ${clone}"
    _grader_clone_remove "$clone" || true
    return 8
  fi
  local rid=""
  rid=$(_grader_process_run_open "$seat" "$ident" "$sid" "$clone")

  if ! _grader_clone_wake "$clone" "$ident" "$sid"; then
    warn "$ident: grader clone ${clone} was created but did not start grading (the wake was not delivered) — unwinding"
    _grader_process_unwind "$seat" "$ident" "$sid" "$rid" "$prev_assignee"
    _grader_clone_remove "$clone" || warn "$ident: grader clone ${clone} could not be removed; the sweep will take it"
    return 4
  fi
  return 0
}

# ══ DIVE-4496: THE SWEEP IS THE REMOVE, AND THAT IS WHY THERE IS ONLY ONE ══
#
# lodar asked for "ONE create, ONE wake, ONE remove" and for the tick that creates
# a clone to also sweep clones. Those are the same mechanism, not two: "the grade
# finished, take the seat away" and "the grade died mid-turn, take the seat away
# and re-queue" differ only in whether a verdict landed, which is one column. A
# separate happy-path remove would be a second code path doing the same thing, and
# the one that ran less often would be the one that was wrong.
#
# WHY THE CLONE DOES NOT REMOVE ITSELF, since that is the obvious other design:
# `agent rm` stops the systemd unit the clone's own turn is running inside, so a
# self-remove is a process deleting the account it is executing as, mid-verdict.
# lodar's 06:07Z worry ("mid turn death and then we forget to delete clone") is
# exactly the failure a self-remove cannot cover, and the sweep covers both.
#
# FOUR STATES PER CLONE, and the order is from cheapest to most expensive:
#   resolved  — its run row has a verdict after it. Remove, close the run `ok`.
#   orphan    — no open run row at all (a create that outlived its tick, a run
#               row already closed). Remove. Nothing to re-queue.
#   stale     — run row open past `_GRADER_STALE_HOURS`. Remove + re-queue.
#   dead      — run row open, inside the bound, past the start grace, and no
#               grading CLI running as the clone. Remove + re-queue. THIS is the
#               state the one-shot had no answer for at all: DIVE-4417 graded a
#               launch that never STARTS, and a launch that starts and then dies
#               was contained only by the six-hour bound.
# Anything else is live and is left alone.
#
# ══ WHERE A SWEPT DELIVERY GOES BACK TO, AND WHY IT IS NOT THIS LANE ══
#
# The obvious re-queue is a fresh `task.grade.requested`: the pending query keys
# on the LATEST request and excludes any ident carrying a later
# `task.grade.spawned`, so a new request row is the only thing that puts a reaped
# delivery back in THIS lane's pending set.
#
# IT IS NOT DONE, AND THE REASON IS A GUARDRAIL THIS ROW MUST NOT WIDEN.
# `tests/grader_spawn_trigger_unit.sh` arm1b asserts STRUCTURALLY that
# `_grader_spawn_request` has exactly one call site — inside
# `_task_route_to_verifier`, the single funnel every delivery passes through — so
# that no code path anywhere can name, time or prime a judge outside the act of
# the system recording a delivery. A second emitter here would have turned that
# arm red, and widening a safety control to unblock the change it would block is
# the one move this repo's rules name outright.
#
# SO THE SWEEP RESTORES THE ROW TO ITS ROUTED VERIFIER instead, which is the same
# recovery `_hb_reclaim_to_todo … keep-handoff` performs for every other seat that
# dies holding a delivery: assignee back to `verifier`, status back to `todo`, the
# delivery stamps untouched, the run closed `abandoned`. The delivery is graded on
# the next pass — by the verifier's own session rather than by a new clone. That
# is a degrade to the SESSION lane, which is the posture every other guard in this
# file already takes, and it is a complete recovery rather than a deferral: the
# grade happens, the row is never stranded, and no delivery waits on the six-hour
# bound. Re-entering the CLONE lane after a sweep needs the funnel taught to
# re-request, which is a change in `delivery.sh` and belongs to whoever owns that
# guardrail — it is written on the row rather than smuggled in here.
_grader_clone_sweep() {  # [--commit]  -> <number of clones swept>
  local commit=0
  [[ "${1:-}" == "--commit" ]] && commit=1
  local clone swept=0 row rid ridnt rts reason
  local grace="${_GRADER_CLONE_START_GRACE_S}"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=300
  local hours; hours=$(_grader_stale_hours)
  while IFS= read -r clone; do
    [[ -n "$clone" ]] || continue
    # The clone's own open run row — ONE query per clone, keyed on the column
    # that holds the clone name, which is the ownership record run_open writes.
    row=$(db "SELECT id||x'1f'||COALESCE(ident,'')||x'1f'||COALESCE(started_at,'')
                FROM runs
               WHERE agent=$(sqlq "$clone") AND role='grader' AND status='running'
               ORDER BY id DESC LIMIT 1;" 2>/dev/null || printf '')
    rid="${row%%$'\x1f'*}"; ridnt=""; rts=""
    if [[ "$row" == *$'\x1f'* ]]; then
      ridnt="${row#*$'\x1f'}"; rts="${ridnt#*$'\x1f'}"; ridnt="${ridnt%%$'\x1f'*}"
    fi
    reason=""
    if [[ -z "$rid" ]]; then
      reason="orphan: no open run record"
    elif [[ -n "$ridnt" ]] && _grader_clone_verdict_landed "$ridnt" "$rts"; then
      reason="resolved: verdict landed"
    elif [[ -n "$rts" ]] && _grader_clone_run_older_than "$rts" "$(( hours * 3600 ))"; then
      reason="stale: run open past the ${hours}h bound"
    elif [[ -n "$rts" ]] && _grader_clone_run_older_than "$rts" "$grace" \
         && ! _grader_clone_live "$clone"; then
      reason="dead: no ${_GRADER_PROCESS_CLI} running as agent-${clone}"
    fi
    # LIVE IS NOT COUNTED HERE. `_grader_process_count` is the tick's one
    # reading of how many clones exist, and it is called immediately after this;
    # a second count returned from the remover is a second source of truth for
    # the cap, which is the DIVE-4418 failure in a new place.
    [[ -n "$reason" ]] || continue
    swept=$((swept+1))
    (( commit )) || continue
    _grader_clone_remove "$clone" \
      || warn "grader clone ${clone} (${reason}) could not be removed — it will be retried next tick"
    case "$reason" in
      resolved:*)
        # The run row is closed here and NOWHERE ELSE, which is the live specimen
        # this row was filed with: `gr-20260914T054510Z-1554431-1` still read
        # `running (open)` in `run ls` 37 minutes after its process was gone,
        # because the record's liveness was asserted at INSERT and never checked
        # again. The sweep is the check.
        [[ -n "$rid" ]] && db "UPDATE runs SET status='ok', outcome='graded' WHERE id=$(sqlq "$rid");" >/dev/null 2>&1 || true
        ;;
      orphan:*) : ;;
      *) _grader_clone_requeue "$clone" "$ridnt" "$rid" ;;
    esac
  done < <(_grader_clone_ls)
  (( commit )) && _grader_clone_reaped_prune
  printf '%s' "$swept"
  return 0
}

# `_grader_clone_requeue <clone> <ident> <run id>` — the row goes back to its
# verifier, the run is closed, and the attempt is on the record.
#
# `abandoned` AND NOT `failed`, which is DIVE-3932's distinction and it is load
# bearing: we know the attempt stopped, we do NOT know that it errored. A sweep
# that writes `failed` for a clone somebody SIGKILLed is asserting a fault it did
# not witness.
#
# THE RESTORE IS GUARDED on the delivery being live and ungraded, copied clause
# for clause from `_hb_reclaim_to_todo`'s keep-handoff mode, so this can never
# invent a handoff on a row whose delivery was already bounced or graded.
_grader_clone_requeue() {  # <clone> <ident> <run id>
  local clone="$1" ident="$2" rid="$3"
  [[ -n "$ident" ]] || return 0
  db "UPDATE tasks
         SET assignee=verifier, status='todo', started_at=NULL, updated_at=datetime('now')
       WHERE ident=$(sqlq "$ident")
         AND verifier IS NOT NULL AND verifier<>''
         AND maker_agent IS NOT NULL
         AND handoff_delivered_at IS NOT NULL
         AND handoff_ack_at IS NULL
         AND (handoff_rejected_at IS NULL OR handoff_rejected_at < handoff_delivered_at);" >/dev/null 2>&1 || true
  [[ -n "$rid" ]] && db "UPDATE runs SET status='abandoned', outcome='grader_clone_swept'
                          WHERE id=$(sqlq "$rid");" >/dev/null 2>&1 || true
  # A compensating row, not a silent revert — the same reason
  # `_grader_process_unwind` writes one. Without it a delivery that was graded
  # twice looks like a duplicate the lane cannot account for.
  ledger_emit task.grade.spawn.failed ident="$ident" actor="$(task_actor "")" \
    detail="grader clone ${clone} swept before a verdict; row restored to its verifier" || true
  return 0
}

# `_grader_clone_verdict_landed <ident> <run ts>` — did a verdict land on this row
# after its clone's run opened?
#
# THE SAME EXIT SET the in-flight predicate uses (`task.graded` / `task.done` /
# `task.rejected` strictly later than the spawn), asked about one run rather than
# all of them. Not `tasks.status='done'`: a PASS is deliberately held open as
# `graded->merge` for hours (DIVE-3330), and a clone kept alive for the length of
# somebody's merge queue is the DIVE-4322 leak with a seat attached instead of a
# slot.
_grader_clone_verdict_landed() {  # <ident> <run ts>
  local ident="$1" ts="$2" n
  [[ -n "$ident" ]] || return 1
  n=$(db "SELECT COUNT(*) FROM lifecycle_events
           WHERE ident=$(sqlq "$ident")
             AND kind IN ('task.done','task.rejected','task.graded')
             AND ($(sqlq "$ts")='' OR ts >= $(sqlq "$ts"));" 2>/dev/null || printf '0')
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 ))
}

# `_grader_clone_run_older_than <ts> <seconds>` — age, computed BY SQLITE.
#
# By the store and not by `date -d`, because the run row's timestamp is written by
# sqlite's own `datetime('now')` in UTC and comparing it against a shell `date`
# reading is how a sweep acquires a timezone bug that only fires half the year.
_grader_clone_run_older_than() {  # <ts> <seconds>
  local ts="$1" secs="$2" v
  [[ -n "$ts" && "$secs" =~ ^[0-9]+$ ]] || return 1
  v=$(db "SELECT CASE WHEN (julianday('now')-julianday($(sqlq "$ts")))*86400 > ${secs}
                      THEN 1 ELSE 0 END;" 2>/dev/null || printf '0')
  [[ "$v" == "1" ]]
}
