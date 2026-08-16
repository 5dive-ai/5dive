# -------- DIVE-3503: a lifetime bound for agent-launched shells --------
#
# 2026-08-16: four seats (dev, dev2, dev3, quinn) could not take new work because
# a shell the AGENT had written was still running after the task that spawned it
# had closed. Two different triggers, one missing thing:
#
#   dev/dev2/dev3  `until ! pgrep -f 'timeout 300 bash tests/'; do sleep 20; done`
#                  — `pgrep -f` matches the waiter's OWN argv, so the predicate
#                  can never go false. 67 and 64 minutes at kill time.
#   quinn          `until grep -q "== done ==" <file>; do sleep 10; done`
#                  — the producer was killed mid-run, so the sentinel it would
#                  have echoed can never be written. 8.3 and 6.5 hours; one child
#                  was ALSO spinning at 97.2% of a core the whole time.
#
# Nothing in this product bounded any of them. `git grep -nE "pkill|kill -" -- src/`
# was empty; the heartbeat's `reaped` counter counts cancelled ROWS, not
# processes; `task done|cancel|deliver` is a DB transition that touches no
# process. So a child outlived the command, the turn, the task and the row, and a
# human was the only thing that could end it — three separate times in one day.
#
# WHAT THIS REAPS, and why the predicate is this narrow. Measured `ps` across all
# 18 seats before choosing it: everything a seat legitimately runs long is one of
# `5dive-agent-start`, `tmux new-session`, the run-loop `bash --login -c`, the
# `claude` runtime itself, or a `bun`/`node` plugin-MCP server. NONE of those is
# an agent-written `bash -c`, and both incident shapes were. So the target class
# is exactly: a shell invoked with -c, descended from the seat's runtime, older
# than the grace age. That covers both triggers above and every trigger we have
# not seen yet, and it cannot reach the seat's own machinery.
#
# WHAT IT DELIBERATELY CANNOT REACH:
#   * any process in the CALLER's own ancestor chain — `5dive task done` runs
#     inside one of these shells, so a reaper that did not exclude its ancestors
#     would kill the command asking for the reap, and (walking up) the runtime.
#   * pid 1, the seat unit, tmux, the run loop, the runtime, MCP servers.
#   * anything younger than the grace age (default 900s) — a shell that has been
#     alive fifteen minutes past its task boundary is not the fast case.
#   * anything carrying the opt-out FIVEDIVE_KEEP_ALIVE, read from the process's
#     ENVIRONMENT (/proc/<pid>/environ) as well as its command line. A deliberate
#     long background job is a legitimate thing to want; killing it would be a
#     new defect, not a fix, so this escape has to actually work:
#       FIVEDIVE_KEEP_ALIVE=1 nohup ./long-build.sh &
#
#     It reads environ and not just `ps` because a variable-assignment prefix is
#     NEVER part of argv — `env`/`nohup` exec away and the assignment is consumed
#     by the shell, so `ps` shows `nohup ./long-build.sh` with no token anywhere.
#     Iteration 2 checked the command line only, so the escape documented to
#     agents was inert and an opted-out job was killed anyway (measured by quinn
#     on this host, DIVE-3503 it.2). Environ is readable on both call paths: the
#     task-boundary reaper runs as the seat over its own pids, the heartbeat as
#     root. Children inherit the variable, so a protected job protects its tree.
#
#     The name changed here too, and that is the load-bearing half of the fix:
#     `5DIVE_KEEP_ALIVE` is not a valid shell identifier (it begins with a
#     digit), so the invocation we documented did not "fail to be visible" — it
#     did not run. Measured: `5DIVE_KEEP_ALIVE=1 nohup ./x &` exits 127
#     (`command not found`) and `export 5DIVE_KEEP_ALIVE=1` is refused as `not a
#     valid identifier`. FIVEDIVE_* matches FIVEDIVE_REAP/FIVEDIVE_REAP_MIN_AGE
#     below. The old spelling is still honoured in the command line only, for
#     anyone who pasted it as a literal comment token; it is not documented.
#
#     NOT read on a host without /proc (non-Linux): there the environ arm is
#     inert and only a token literally in argv spares a shell.
#
# NEVER `pkill -f` HERE. The incident is itself the proof: an `-f` pattern in it
# matched a seat on another machine that was merely QUOTING the string, plus the
# pgrep process running the query. Everything below kills by PID, and the
# descendant set is collected BEFORE the parent dies — quinn's spinning child
# reparented to init on SIGTERM and needed a direct SIGKILL, which is only
# possible if its PID was already in hand.

# Grace age in seconds. A shell younger than this is left alone by every caller.
_REAP_MIN_AGE_DEFAULT="${FIVEDIVE_REAP_MIN_AGE:-900}"
[[ "$_REAP_MIN_AGE_DEFAULT" =~ ^[0-9]+$ ]] || _REAP_MIN_AGE_DEFAULT=900

# Set FIVEDIVE_REAP=0 to disable the automatic (task-boundary and heartbeat)
# reapers entirely without touching an explicit `5dive agent reap` invocation.
_reap_enabled() { [[ "${FIVEDIVE_REAP:-1}" != "0" ]]; }

# ---- pure predicate: is this command line an AGENT-WRITTEN shell? ----
#
# Unit-testable: takes the command line as a string, no /proc, no ps, no kill.
# Returns 0 (reapable class) / 1 (leave it alone). Ordered exclusions first so a
# command line that is BOTH a login shell and a `-c` (the run loop is exactly
# that) lands on the exclusion.
_reap_is_agent_shell() {
  local cmd="$1"
  [[ -n "$cmd" ]] || return 1
  # The named opt-out, in the command line. Checked first: it must beat every
  # other arm, including command lines that look exactly like the incident's.
  # This arm only sees a token literally in argv; the documented env-var form is
  # invisible here by construction and is handled by _reap_keep_alive_env below.
  [[ "$cmd" == *FIVEDIVE_KEEP_ALIVE* ]] && return 1
  [[ "$cmd" == *5DIVE_KEEP_ALIVE* ]] && return 1   # legacy spelling, undocumented
  # The seat's own machinery, in the order `ps` shows it. `--login` is the run
  # loop's shell and is NEVER an agent-written command; run-loop.sh and
  # 5dive-agent-start name themselves; tmux/claude/bun/node are not shells.
  case "$cmd" in
    *5dive-agent-start*|*run-loop.sh*|*' --login '*|*' --login -c'*) return 1 ;;
    /usr/bin/tmux*|tmux\ *|*/tmux\ new-session*)                     return 1 ;;
    */claude\ *|*/claude|claude\ --*)                                return 1 ;;
    */bun\ *|bun\ *|*/node\ *|node\ *|*/python3\ *|python3\ *)        return 1 ;;
  esac
  # What is left: a shell invoked with -c. That is the whole target class.
  case "$cmd" in
    bash\ -c\ *|/bin/bash\ -c\ *|/usr/bin/bash\ -c\ *) return 0 ;;
    sh\ -c\ *|/bin/sh\ -c\ *|/usr/bin/sh\ -c\ *)       return 0 ;;
    zsh\ -c\ *|/bin/zsh\ -c\ *|/usr/bin/zsh\ -c\ *)    return 0 ;;
    bash\ -lc\ *|/bin/bash\ -lc\ *)                    return 0 ;;
  esac
  return 1
}

# ---- the opt-out, read from the process ENVIRONMENT ----
#
# _reap_keep_alive_env <pid> -> 0 if this process opted out, 1 otherwise.
#
# `FIVEDIVE_KEEP_ALIVE=1 nohup ./long-build.sh &` puts the variable in the
# child's environment and NOWHERE in its argv, so the string predicate above
# cannot see it and only /proc/<pid>/environ can. PRESENCE is the opt-out; the
# value is not read, so it matches the command-line arm exactly (a token is a
# token) and `=0` does not mean "off".
#
# Unreadable environ (no /proc, or the process exited between the ps and here)
# is NOT treated as an opt-out: sparing on failure-to-read would silently
# disable the whole reaper on any host where the file is missing, which is the
# "remedy that reports success while doing nothing" this row exists to punish.
_reap_keep_alive_env() {
  local p="$1" env_raw
  [[ -r "/proc/$p/environ" ]] || return 1
  env_raw=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || return 1
  grep -qE '^(FIVEDIVE|5DIVE)_KEEP_ALIVE=' <<<"$env_raw"
}

# The composition the class loop actually applies: the pure command-line class
# test, then the environment opt-out. It exists as a function so the unit test
# grades THIS, driven by a real staged pid and its real /proc/<pid>/cmdline,
# rather than re-typing the loop's two conditions and grading its own copy —
# which is exactly how iteration 2 stayed green while the opt-out was dead.
_reap_is_reapable() {   # <pid> <cmdline>
  _reap_is_agent_shell "$2" || return 1
  ! _reap_keep_alive_env "$1"
}

# ---- pure selector ----
#
# stdin: the process table, one record per line, TAB-separated:
#     PID \t PPID \t ELAPSED_SECONDS \t COMMAND LINE
# argv: <self_pid> <min_age> [protected_pid ...]
#
# stdout: the PIDs to reap, one per line, ascending.
#
# Protection is computed HERE rather than by the caller so the test can grade it:
# the caller's ancestor chain is walked through the same table, so `5dive task
# done`'s own shell — and its parent, and the runtime above it — are excluded by
# construction and not by a hand-maintained list.
_reap_select() {
  local self="$1" min_age="$2"; shift 2
  local protected=" $* "
  awk -v self="$self" -v min_age="$min_age" -v protected="$protected" '
    BEGIN { FS="\t" }
    {
      pid[NR]=$1; ppid[$1]=$2; age[$1]=$3; cmd[$1]=$4; n=NR
    }
    END {
      # Walk the caller up to pid 1, marking every ancestor (and the caller).
      p = self
      guard = 0
      while (p != "" && p != "0" && p != "1" && guard++ < 200) {
        safe[p] = 1
        p = ppid[p]
      }
      safe["1"] = 1
      # Explicit protections (the seat unit, tmux, the runtime — whatever the
      # caller measured), plus pid 1.
      split(protected, prot, " ")
      for (i in prot) if (prot[i] != "") safe[prot[i]] = 1
      for (i = 1; i <= n; i++) {
        p = pid[i]
        if (safe[p]) continue
        if (age[p] + 0 < min_age + 0) continue
        print p "\t" cmd[p]
      }
    }
  '
}

# ---- descendants of a PID, from a table on stdin (pure) ----
# Emits pid then every transitive child, deepest last. Bounded so a cycle in a
# malformed table cannot spin — which would be this very bug, in the fix for it.
_reap_descendants() {
  local root="$1"
  awk -v root="$root" '
    BEGIN { FS="\t" }
    { ppid[$1]=$2; kids[$2] = kids[$2] " " $1 }
    END {
      queue[1] = root; head = 1; tail = 1; guard = 0
      while (head <= tail && guard++ < 5000) {
        cur = queue[head++]
        print cur
        split(kids[cur], c, " ")
        for (i in c) if (c[i] != "") queue[++tail] = c[i]
      }
    }
  '
}

# ---- the process table for one seat ----
# `ps -u <user>` — the seat's own processes only, never a fleet-wide scan, and
# never a pattern match. Empty (rc 1) if the user has no processes or ps fails.
_reap_seat_table() {
  local seat_user="$1"
  ps -u "$seat_user" -o pid=,ppid=,etimes=,args= 2>/dev/null \
    | awk '{ pid=$1; ppid=$2; et=$3; $1=$2=$3=""; sub(/^ +/,""); printf "%s\t%s\t%s\t%s\n", pid, ppid, et, $0 }'
}

# ---- did this pid actually end? ----
# `kill -0` alone answers NO for a zombie: the process is over, but its entry
# survives until its parent waits, and a signal-permission probe still succeeds.
# We kill trees whose parent is a runtime that may not reap for seconds, so a
# bare `kill -0` re-check would report a false failure on a successful kill.
# Reads the state field out of /proc/<pid>/stat, splitting after the LAST `)`
# because comm is unescaped and can contain both spaces and parens.
# Returns 0 = ended (gone, or a zombie awaiting its parent), 1 = still running.
#
# NARROWED (quinn, it.2): bash's `kill -0` cannot separate EPERM from ESRCH, so
# a LIVE process this uid may not signal also reads as "ended" — the refused
# signal named in the paragraph above is the one case this answers wrong. That
# is unreachable on both call paths today, because `ps -u <seat>` only yields
# pids the caller may signal (own uid, or root), so it is a latent edge and not
# a live hole; measured from this seat, _reap_pid_ended 1 returns ENDED for pid 1.
_reap_pid_ended() {
  local p="$1" raw
  kill -0 "$p" 2>/dev/null || return 0
  raw=$(cat "/proc/$p/stat" 2>/dev/null) || return 0
  raw="${raw##*) }"
  [[ "${raw%% *}" == "Z" ]]
}

# ---- the acting reaper ----
#
# _reap_stale_shells <seat> [--min-age=SEC] [--dry-run] [--reason=<text>]
#
# Prints one line per reaped tree (PID + the truncated command line) on stderr
# and the count on stdout. Returns 0 always: a reaper that fails the verb it is
# attached to would make `task done` refusable for a reason the agent cannot fix.
_reap_stale_shells() {
  local seat="$1"; shift
  local min_age="$_REAP_MIN_AGE_DEFAULT" dry=0 reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --min-age=*) min_age="${1#*=}" ;;
      --dry-run)   dry=1 ;;
      --reason=*)  reason="${1#*=}" ;;
    esac
    shift
  done
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age="$_REAP_MIN_AGE_DEFAULT"

  local seat_user="$seat"
  [[ "$seat_user" == agent-* || "$seat_user" == "claude" ]] || seat_user="agent-${seat}"
  id -u "$seat_user" >/dev/null 2>&1 || { printf '0'; return 0; }

  local table; table=$(_reap_seat_table "$seat_user")
  [[ -n "$table" ]] || { printf '0'; return 0; }

  # Candidates: the reapable CLASS first (pure predicate on the command line),
  # then the age/ancestor filter. Two passes so the class test stays a pure
  # string function the unit test can drive directly.
  # Every name the read below binds is declared here. Both call sites invoke
  # this function inside $( ), so an undeclared `cmd`/`ppid` would die with the
  # subshell today — but `cmd` is a heavily reused name in this codebase and a
  # future direct call would clobber the caller's.
  local class_table="" pid ppid etimes cmd
  while IFS=$'\t' read -r pid ppid etimes cmd; do
    if _reap_is_reapable "$pid" "$cmd"; then
      class_table+="${pid}"$'\t'"${ppid}"$'\t'"${etimes}"$'\t'"${cmd}"$'\n'
    fi
  done <<<"$table"
  [[ -n "$class_table" ]] || { printf '0'; return 0; }

  # The ancestor walk must see the FULL table (the caller's parents are mostly
  # not themselves reapable-class), so selection reads $table and intersects.
  local selected n=0
  selected=$(printf '%s' "$table" | _reap_select "$$" "$min_age" | cut -f1)
  [[ -n "$selected" ]] || { printf '0'; return 0; }

  local victims=""
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    grep -qE "^${pid}"$'\t' <<<"$class_table" || continue
    victims+="${pid} "
  done <<<"$selected"
  [[ -n "$victims" ]] || { printf '0'; return 0; }

  local tree_pids=""
  for pid in $victims; do
    tree_pids+="$(printf '%s' "$table" | _reap_descendants "$pid") "
  done
  # De-dup, preserving nothing but identity: a nested victim would otherwise be
  # signalled twice, which is harmless but makes the log lie about the count.
  tree_pids=$(tr ' ' '\n' <<<"$tree_pids" | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ') || tree_pids=""

  for pid in $victims; do
    local cmd_short; cmd_short=$(grep -E "^${pid}"$'\t' <<<"$class_table" | cut -f4 | cut -c1-160) || cmd_short=""
    printf '5dive: reaping stale agent shell pid=%s (age>=%ss%s): %s\n' \
      "$pid" "$min_age" "${reason:+, $reason}" "$cmd_short" >&2
    n=$((n + 1))
  done

  if (( dry == 1 )); then printf '%s' "$n"; return 0; fi

  # TERM the whole tree, give it a second, then KILL whatever is left. The
  # incident's runaway survived TERM to its parent and reparented to init, so the
  # second pass is not belt-and-braces — it is the only thing that ended it.
  #
  # LIMIT, deliberate: the keep-alive opt-out is checked on the VICTIM only
  # (_reap_is_reapable, above); $tree_pids descendants are signalled without a
  # re-check. Not reachable that we can find — every way to put the token in a
  # child's environ also leaves it in the parent's environ or argv, so the
  # parent is spared first and the tree is never collected — and re-checking
  # here would be worse than the hole: a protected descendant would leave its
  # unprotected parent half-killed.
  local p
  for p in $tree_pids; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 1
  for p in $tree_pids; do
    kill -0 "$p" 2>/dev/null && { kill -KILL "$p" 2>/dev/null || true; }
  done

  # Count what was ENDED, not what was signalled. `kill` is best-effort here —
  # the heartbeat path runs as root and a seat's own `task done` does not, so a
  # refused signal is a live possibility — and a remedy that reports success
  # without checking the act is the exact shape this row exists to fix
  # (DIVE-1486's escalation "worked" 176 times while nothing was ever unstuck).
  local survivors=""
  for p in $victims; do
    _reap_pid_ended "$p" || { survivors+="${p} "; n=$((n - 1)); }
  done
  [[ -z "$survivors" ]] || printf '5dive: reap FAILED, still running after TERM+KILL (not counted): %s\n' \
    "${survivors% }" >&2

  printf '%s' "$n"
  return 0
}

# Task-boundary entry point. Called by the terminal status verbs; silent and
# free when the seat has nothing stale, which is the overwhelmingly common case.
_reap_at_task_boundary() {
  local verb="$1" ident="$2"
  _reap_enabled || return 0
  # $USER before a fork: this sits on `task done`'s hot path, where a stray
  # command substitution has been measured at ~900ms across one harness
  # (see the audit-arg note in src/task/status.sh). id -un is the fallback.
  local seat="${USER:-}"
  [[ -n "$seat" ]] || seat=$(id -un 2>/dev/null) || return 0
  [[ "$seat" == agent-* || "$seat" == "claude" ]] || return 0
  local n; n=$(_reap_stale_shells "$seat" --reason="task ${ident} ${verb}") || return 0
  [[ "${n:-0}" =~ ^[0-9]+$ ]] && (( n > 0 )) || return 0
  printf 'note: reaped %s stale background shell(s) left over past this task boundary (DIVE-3503). A wait loop with no deadline is a leak; bound the next one.\n' "$n" >&2
  audit_log "task ${verb}" ok 0 -- "$ident" "reaped=$n" 2>/dev/null || true
  return 0
}
