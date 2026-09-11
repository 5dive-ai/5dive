#!/usr/bin/env bash
# Stop hook: tear down the Chrome tree agent-browser left behind (DIVE-4306).
#
# WHY THIS EXISTS. `agent-browser` launches a headless Chrome tree and does
# NOT close it when the turn ends. Claude Code reports native status `busy`
# for as long as ANY background shell is alive — that is what the
# "N shells still running" suffix on a finished turn's done line means — so
# `_hb_agent_idle` sees busy and the heartbeat cannot dispatch to the seat.
# Measured 2026-09-11: quinn held an agent-browser-linux-x64 + Chrome tree
# 1h20m past the turn that opened it and took no row for that whole window;
# lodar found it by eye. DIVE-4298 BOUNDS that (classify idle-with-background-
# shells, reap on the done line) to ~2 heartbeat ticks. This is the leak
# itself: the browser closes at turn end, so there is nothing to bound.
#
# WHAT IT DOES. Fires on Stop (end of assistant turn), for THIS uid only:
#   1. `agent-browser close --all` — the CLI's own graceful path, bounded by
#      $AGENT_BROWSER_CLOSE_TIMEOUT (default 10s).
#   2. Anything still resident afterwards (a close that hung, a Chrome whose
#      parent CLI already died, a crashpad handler) gets SIGTERM, then
#      SIGKILL after $AGENT_BROWSER_KILL_GRACE (default 3s).
# Both stages are scoped to this uid, and SELECTION IS BY EXECUTABLE, not by
# command-line text: a candidate enters the kill list only if
# `readlink /proc/<pid>/exe` resolves under an `agent-browser`/`.agent-browser`
# path. Every member of the real tree does — the CLI is
# `<prefix>/node_modules/agent-browser/bin/agent-browser-linux-x64`, and the
# Chrome and crashpad handler it spawns live under
# `<home>/.agent-browser/browsers/chrome-<ver>/` — while a shell that merely
# NAMES one of those paths has an exe of `/bin/bash` and is never selected.
# The argv pattern is kept as the cheap pre-filter only. This matters because
# an argv match is reachable by ordinary work: measured on agent-quinn
# 2026-09-11, `pgrep -u $(id -u) -f '[/.]agent-browser[-/]'` returned the real
# process AND two of the seat's own concurrent tool shells, whose command
# lines quoted the CLI's path — and background shells alive at turn end are
# precisely what this hook runs alongside. A pid whose exe is UNREADABLE is
# SKIPPED, never killed (same fail-safe direction as the rest of the hook).
#
# MULTI-TURN BROWSER WORK. Closing at turn end means a session does not
# survive into the next turn by default — that is the row's ask, and it is
# the safe default for a fleet where the failure mode is a frozen seat. A
# turn that genuinely needs the browser to live on writes a LEASE:
#
#     echo $(( $(date +%s) + 900 )) > "$HOME/.5dive/browser-lease"
#
# While that epoch is in the future the hook is a no-op and says so. The
# lease is bounded by construction (it is an expiry, not a flag), so a
# forgotten lease self-heals; DIVE-4298's reaper remains the backstop.
#
# Exit code is always 0: a teardown failure must never block the Stop.
set -uo pipefail

LOG="${AGENT_BROWSER_TEARDOWN_LOG:-$HOME/.claude/browser-teardown.log}"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }

UID_SELF="$(id -u)"
# argv PRE-FILTER only. It is cheap and it is not authoritative: a live
# process's command line can carry a PATH-shaped agent-browser token without
# being the browser (a shell installing, grepping or testing this thing —
# measured on agent-quinn, two such shells came back from this very pattern).
# Everything it returns is confirmed by exe below before it can be killed.
PATTERN="${AGENT_BROWSER_PROC_PATTERN:-[/.]agent-browser[-/]}"
# The authoritative test, applied to /proc/<pid>/exe. Same token, but on a
# path the process cannot fake by quoting it: its own executable.
EXE_PATTERN="${AGENT_BROWSER_EXE_PATTERN:-[/.]agent-browser[-/]}"

# Confirm a candidate by its OWN EXECUTABLE. An unreadable exe (a process
# that exited between pgrep and here, or one we may not introspect) returns
# non-zero, so the pid is skipped rather than killed.
exe_is_browser() { # exe_is_browser <pid>
  local exe
  exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
  [[ -n "$exe" ]] || return 1
  printf '%s' "$exe" | grep -qE -- "$EXE_PATTERN"
}

# The kill list: argv pre-filter, minus this hook and its parent, then each
# survivor confirmed by exe. `pkill -f` cannot express this and is never used.
browser_pids() {
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == "$$" || "$p" == "${PPID:-0}" ]] && continue
    exe_is_browser "$p" && printf '%s\n' "$p"
  done < <(pgrep -u "$UID_SELF" -f "$PATTERN" 2>/dev/null)
}

# Nothing of OURS running -> do no work at all (the common case, and this hook
# is on the end-of-turn path of every seat). Note this gate is the confirmed
# list, not the raw pgrep: a bystander shell quoting the path must not even
# trigger a close.
[[ -n "$(browser_pids)" ]] || exit 0

LEASE_FILE="${AGENT_BROWSER_LEASE_FILE:-$HOME/.5dive/browser-lease}"
if [[ -r "$LEASE_FILE" ]]; then
  lease=$(tr -dc '0-9' <"$LEASE_FILE" 2>/dev/null | head -c 20)
  if [[ -n "$lease" ]] && (( lease > $(date +%s) )); then
    log "lease active until $lease — skipping teardown"
    exit 0
  fi
fi

close_timeout="${AGENT_BROWSER_CLOSE_TIMEOUT:-10}"
kill_grace="${AGENT_BROWSER_KILL_GRACE:-3}"

if command -v agent-browser >/dev/null 2>&1; then
  timeout "$close_timeout" agent-browser close --all >/dev/null 2>&1
  log "agent-browser close --all rc=$?"
fi

# Survivors: the graceful close hung, or Chrome outlived the CLI that spawned
# it. TERM first so Chrome flushes its profile, then KILL.
pids="$(browser_pids)"
if [[ -n "$pids" ]]; then
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null
  for _ in $(seq 1 "$kill_grace"); do
    [[ -n "$(browser_pids)" ]] || break
    sleep 1
  done
  pids="$(browser_pids)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null
    log "SIGKILL sent to surviving browser processes: $(echo $pids | tr '\n' ' ')"
  else
    log "browser tree terminated on SIGTERM"
  fi
else
  log "browser tree closed by agent-browser close --all"
fi

exit 0
