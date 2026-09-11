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
# Both stages are scoped to this uid, and the match is the PATH-shaped token
# `[/.]agent-browser[-/]` that every process in the tree carries — so it never
# reaches another seat's browser, and never a shell that merely mentions the
# string (this hook's own, for one).
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
# The PATH-shaped token, not the bare word. The CLI is
# `<prefix>/node_modules/agent-browser/bin/agent-browser-linux-x64` and every
# Chrome + crashpad handler it spawns lives under
# `<home>/.agent-browser/browsers/chrome-<ver>/`, so both carry `/agent-browser/`
# or `.agent-browser/`. A bare `agent-browser` also matches any SHELL whose
# command line merely mentions the string -- including the agent's own tool
# wrapper -- and `pkill -f` on that would kill the session, not the browser.
# Measured while writing the harness: a bare pattern self-matched the very
# shell running the check.
PATTERN="${AGENT_BROWSER_PROC_PATTERN:-[/.]agent-browser[-/]}"

# Nothing of ours running -> do no work at all (this is the common case, and
# the hook is on the end-of-turn path of every seat).
pgrep -u "$UID_SELF" -f "$PATTERN" >/dev/null 2>&1 || exit 0

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
# it. TERM first so Chrome flushes its profile, then KILL. Explicit pid list
# rather than `pkill -f`: this hook's own shell (and the shell that invoked
# it) can carry the pattern in its command line, and killing those would take
# down the session instead of the browser.
browser_pids() {
  pgrep -u "$UID_SELF" -f "$PATTERN" 2>/dev/null \
    | grep -vx -e "$$" -e "${PPID:-0}" || true
}

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
