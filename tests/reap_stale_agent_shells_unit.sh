#!/usr/bin/env bash
# TIER: core — 0.5s measured on the 5dive control plane (agent-dev seat), and it
# does not grow under load: 0.45s x3 idle, and 48 runs at 16-way concurrency on
# 4 cores with 4 spinners were green. Mostly pure string/awk grading, plus
# staged decoys (two for the environ opt-out, a zombie and the holder that keeps
# it unreaped, one live). The holder is nominally long-lived — it has to outlast
# the arm it serves — but every staged pid is killed by PID from the EXIT trap
# on every path, so nothing survives the run. No DB, no network, no `ps` of the
# real seat, and nothing it kills is not its own.
#
# DIVE-3503 — the reaper's predicate, graded on a FABRICATED process table.
#
# Why fabricated and not `ps`: the incident's processes are gone (they were
# killed by hand before this row was filed), so the live host cannot reproduce
# them, and a test that read the real table would grade whatever happened to be
# running. Every row below is a VERBATIM command line from the incident capture
# in DIVE-3503's body, or from the `ps -eo user,pid,ppid,etimes,args` sweep
# across all 18 seats that chose the predicate.
#
# The three things a green here must mean:
#   1. Both incident shapes are reaped.               (positive control)
#   2. NOTHING a seat legitimately runs long is.      (the safety claim)
#   3. The caller and its whole ancestor chain are exempt — `5dive task done`
#      runs inside one of these shells, so a reaper that missed this would kill
#      the command asking for the reap and, walking up, the runtime.
#
# Arm 0 is a PINNED-EMPTY positive control: if the selector is broken shut, the
# "nothing legitimate is reaped" arms pass vacuously and the file is worthless.
set -uo pipefail
trap 'rc=$?; rm -f "${ZF:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. Redirecting the source's stderr would also
# swallow the helper's own stderr line, which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

. src/lib/reap.sh

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 — expected [$3], got [$2]"; }

# ---------------------------------------------------------------- class arms --
reapable() {   # name, cmdline
  if _reap_is_agent_shell "$2"; then ok "reapable: $1"; else bad "reapable: $1 — classified SAFE, should be reaped"; fi
}
spared() {
  if _reap_is_agent_shell "$2"; then bad "spared: $1 — classified REAPABLE, would have been killed"; else ok "spared: $1"; fi
}

echo "== class predicate: the two incident shapes =="
# dev/dev2/dev3 — the self-matching pgrep waiter, verbatim from the body.
reapable "dev pgrep-self waiter" \
  $'bash -c ... eval "until ! pgrep -f \'timeout 300 bash tests/\' >/dev/null 2>&1; do sleep 20; done; cat $O"'
# quinn — the sentinel waiter whose producer died first.
reapable "quinn sentinel waiter" \
  'bash -c until [ -f /tmp/b6geqofb0.output ] && grep -q "== done ==" /tmp/b6geqofb0.output; do sleep 10; done'
reapable "quinn two-sentinel waiter" \
  'bash -c until grep -q "== M4 ==" /tmp/bc3fnp200.output && grep -q "done" /tmp/b6geqofb0.output; do sleep 15; done'
reapable "sh -c form"   'sh -c while true; do sleep 5; done'
reapable "absolute path" '/bin/bash -c until false; do sleep 1; done'

echo "== class predicate: everything a seat legitimately runs long =="
# Verbatim shapes from the fleet-wide ps sweep (see src/lib/reap.sh header).
spared "seat unit"      'bash /usr/local/bin/5dive-agent-start community'
spared "tmux session"   '/usr/bin/tmux new-session -d -s agent-community -c /home/claude/projects/5dive/community bash --login -c unset CLAUDE_CONFIG_DIR'
spared "run loop"       "bash --login -c unset CLAUDE_CONFIG_DIR OPENAI_API_KEY; export DISABLE_UPDATES=1; RUN_CMD=/home/claude/.local/bin/claude AGENT_NAME=community source /usr/local/lib/5dive/run-loop.sh"
spared "the runtime"    '/home/claude/.local/bin/claude --dangerously-skip-permissions --channels plugin:telegram@5dive-plugins'
spared "plugin MCP"     '/usr/local/bin/bun server.ts'
spared "plugin start"   'bun run --cwd /home/agent-olivia/.claude/plugins/cache/5dive-plugins/telegram/0.5.48 --shell=bun --silent start'
spared "resume hook"    'bun /home/agent-marketing/.claude/plugins/cache/5dive-plugins/telegram/0.5.48/hooks/resume-after-reset.ts 1786856400'
spared "discord bot"    '/home/claude/projects/5dive/marketing/scripts/discord/venv/bin/python -u /home/claude/projects/5dive/marketing/scripts/discord/welcome_bot.py'
spared "node server"    '/usr/bin/node src/server.js'
spared "empty cmdline"  ''

echo "== class predicate: the named opt-out beats every reapable shape =="
# A token literally in argv. This arm is a LITERAL on purpose — it grades the
# pure string function, and a shell can really produce this command line.
spared "opt-out token in argv" \
  $'bash -c FIVEDIVE_KEEP_ALIVE=1; until ! pgrep -f \'timeout 300 bash tests/\'; do sleep 20; done'
spared "legacy spelling in argv" \
  $'bash -c 5DIVE_KEEP_ALIVE=1; until ! pgrep -f \'timeout 300 bash tests/\'; do sleep 20; done'

echo "== the opt-out, driven by REAL staged processes =="
#
# WHY THIS SECTION IS NOT LITERALS. Iteration 2 asserted
#   spared "opt-out env" 'bash -c 5DIVE_KEEP_ALIVE=1 nohup ./long-build.sh'
# — a command line the documented invocation CANNOT produce. A variable
# assignment is consumed by the shell and never lands in argv, so the arm graded
# its own fixture, stayed green, and the escape hatch was dead: quinn staged the
# documented form on this host and the reaper killed it (DIVE-3503 it.2). So
# every claim below is read off a real /proc/<pid>/cmdline and /proc/<pid>/environ.
#
# It also turned out the old spelling never ran at all — `5DIVE_KEEP_ALIVE` is
# not a valid shell identifier (leading digit) — which is graded here too.
A=""; B=""; holder=""
# NOTE: this trap REPLACES the one set at the top of the file, so everything
# this harness stages has to be ended from here — including the zombie holder
# staged below, which by design outlives the arm that consumes it. A harness
# for "your background shell outlives your task" must not leak one itself.
cleanup_staged() { local p; for p in $A $B $holder; do kill -KILL "$p" 2>/dev/null; done; }
trap 'rc=$?; cleanup_staged; rm -f "${ZF:-}"; echo "HARNESS-RC=$rc"' EXIT

# ---- staged here, graded ~45 arms below (see "Zombie arm") ------------------
# Staging a zombie is itself a wait on a producer, so it obeys this row's own
# rule, and the first cut of it broke both halves of that rule (measured flaky
# by quinn on the verifier seat: 2 reds in 16 sequential runs and 2 in 6
# concurrent, always `state=reaped-early`). Three things make it deterministic:
#
#   1. `exec sleep` — the holder becomes a process that never calls wait(), so
#      the zombie cannot be reaped out from under the poll. A bash holder that
#      merely slept longer is NOT the fix: it exits at the end of its lifetime
#      and hands the zombie to init, which reaps it instantly.
#      `exec` alone is not enough, though, and this cost a measured 1 red in 18
#      concurrent runs before it was fixed:
#   2. The child must not die while its parent is STILL BASH. Non-interactive
#      bash reaps background children in its SIGCHLD handler, so a child that
#      exits inside the window between the `&` and the `exec` is reaped by the
#      holder itself and never becomes visible. The child therefore waits for
#      the holder to BECOME the non-waiting process — /proc/<ppid>/comm flips
#      from `bash` to `sleep` at the exec — and only then exits. That is an
#      ordering, not a margin: there is no race left to lose under any load,
#      rather than one made rarer by a longer sleep.
#   3. It is staged HERE and consumed ~45 arms below, so the staging cost
#      overlaps the rest of the file. This is TIER: core — every idle second in
#      it is paid on every unrelated PR.
ZHOLD=60      # holder lifetime; >= 10x ZDEADLINE, and ended by cleanup_staged
ZDEADLINE=5   # wall-clock budget for each poll at the arm
# Bounded like everything else here: if the exec never happens the child gives
# up after ~5s rather than waiting forever, and the arm below then reports what
# it actually saw.
ZWAIT='n=0; while [ "$(cat /proc/$PPID/comm 2>/dev/null)" != sleep ] && [ $n -lt 500 ]; do n=$((n+1)); sleep 0.01; done'
ZF=$(mktemp) || ZF=""
if [[ -n "$ZF" ]]; then
  ZF="$ZF" ZWAIT="$ZWAIT" bash -c 'bash -c "$ZWAIT" & echo $! >"$ZF"; exec sleep '"$ZHOLD" & holder=$!
  disown "$holder" 2>/dev/null || true
fi

WEDGE='until [ -f /nonexistent/5dive-never ]; do sleep 1; done'
if [[ ! -r /proc/self/cmdline ]]; then
  bad "STAGING: /proc is not readable — the environ opt-out cannot be graded on this host"
else
  # A: the DOCUMENTED invocation, spelled exactly as projects-CLAUDE.md spells it.
  #    Written inline rather than through a helper: an assignment prefix on a
  #    FUNCTION call persists in the calling shell in bash, which would leak the
  #    token into B and turn the negative control green for the wrong reason.
  FIVEDIVE_KEEP_ALIVE=1 nohup bash -c "$WEDGE" >/dev/null 2>&1 &
  A=$!
  # B: the identical wedge with NO opt-out. Negative control: without it, an arm
  #    that spared everything would read exactly like a working opt-out.
  nohup bash -c "$WEDGE" >/dev/null 2>&1 &
  B=$!
  disown "$A" "$B" 2>/dev/null || true   # else the EXIT kill prints "Killed" job notices
  sleep 0.3
  if ! kill -0 "$A" 2>/dev/null || ! kill -0 "$B" 2>/dev/null; then
    bad "STAGING: could not stage the decoys (A=$A B=$B) — the arms below cannot be graded"
  else
    A_CMD=$(tr '\0' ' ' <"/proc/$A/cmdline"); A_CMD="${A_CMD% }"
    B_CMD=$(tr '\0' ' ' <"/proc/$B/cmdline"); B_CMD="${B_CMD% }"

    # The fact iteration 2's fixture got wrong, asserted directly.
    if [[ "$A_CMD" == *KEEP_ALIVE* ]]; then
      bad "the token is ABSENT from argv — fixture assumption, must hold for the rest to mean anything (got: $A_CMD)"
    else
      ok "the token is ABSENT from the opted-out process's argv (real cmdline: $A_CMD)"
    fi
    # ...so the string predicate MUST call it reapable. If it did not, the
    # environ arm below would pass for the wrong reason.
    if _reap_is_agent_shell "$A_CMD"; then
      ok "string predicate alone would REAP the opted-out process (so only environ can spare it)"
    else
      bad "string predicate spared the opted-out process on its own — the environ arm is vacuous"
    fi

    if _reap_keep_alive_env "$A"; then ok "environ opt-out SEEN on the staged opted-out pid"
    else bad "environ opt-out NOT seen on the staged opted-out pid — the documented escape is inert"; fi
    if _reap_keep_alive_env "$B"; then bad "environ opt-out claimed on the UNPROTECTED twin — it spares everything"
    else ok "NEGATIVE CONTROL: environ opt-out not claimed on the unprotected twin"; fi

    # The composition the acting reaper applies, on the real pid + real cmdline.
    if _reap_is_reapable "$A" "$A_CMD"; then
      bad "COMPOSITION: the documented opt-out would be REAPED — this is the it.2 blocker, unfixed"
    else
      ok "COMPOSITION: the documented opt-out is spared"
    fi
    if _reap_is_reapable "$B" "$B_CMD"; then
      ok "COMPOSITION: the unprotected twin is reaped"
    else
      bad "COMPOSITION: the unprotected twin was spared — the reaper selects nothing"
    fi

    # An unreadable environ must NOT read as an opt-out, or a missing /proc
    # silently disables the whole reaper while every arm still reads green.
    if _reap_keep_alive_env 999999999; then
      bad "an unreadable environ was treated as an opt-out — /proc absent would disable the reaper"
    else
      ok "an unreadable environ is NOT an opt-out"
    fi
  fi

  # The name itself, which is why the docs changed: a leading digit is not a
  # valid identifier, so the OLD invocation never started the job.
  bash -c '5DIVE_KEEP_ALIVE=1 true' >/dev/null 2>&1
  is "old spelling is not an assignment — the documented job exited 127" "$?" "127"
  bash -c 'FIVEDIVE_KEEP_ALIVE=1 true' >/dev/null 2>&1
  is "new spelling is a valid assignment prefix — the job runs" "$?" "0"
fi

# ------------------------------------------------------------- selector arms --
# Table columns: PID \t PPID \t ELAPSED_SECONDS \t COMMAND
#
#   1     init
#   100   the seat unit            (child of 1)
#   200   tmux                     (child of 1)
#   300   the run loop             (child of 200)
#   400   the claude runtime       (child of 300)
#   500   THE CALLER's shell       (child of 400)   <- `5dive task done` runs here
#   501   the caller itself        (child of 500)
#   600   a wedged waiter          (child of 400)   <- must be reaped
#   601   its spinning child       (child of 600)   <- must ride the tree
#   700   a young shell            (child of 400)   <- under the grace age
TABLE=$(printf '%s\n' \
  $'1\t0\t99999\t/sbin/init' \
  $'100\t1\t72204\tbash /usr/local/bin/5dive-agent-start dev' \
  $'200\t1\t72203\t/usr/bin/tmux new-session -d -s agent-dev' \
  $'300\t200\t72203\tbash --login -c source /usr/local/lib/5dive/run-loop.sh' \
  $'400\t300\t72200\t/home/claude/.local/bin/claude --dangerously-skip-permissions' \
  $'500\t400\t3600\tbash -c 5dive task done DIVE-3503 --result=...' \
  $'501\t500\t3600\tbash -c 5dive task done DIVE-3503 --result=...' \
  $'600\t400\t4029\tbash -c until ! pgrep -f timeout 300 bash tests/; do sleep 20; done' \
  $'601\t600\t4029\tsleep 20' \
  $'700\t400\t30\tbash -c until false; do sleep 1; done')

sel() { printf '%s\n' "$TABLE" | _reap_select "$1" "$2" "${@:3}" | cut -f1 | sort -n | tr '\n' ' ' | sed 's/ $//'; }

echo "== selector =="
# ARM 0 — POSITIVE CONTROL. Caller is 501, grace 900s. If this comes back empty
# the selector is broken shut and every "spared" arm below is vacuous.
got=$(sel 501 900)
if [[ -z "$got" ]]; then
  bad "POSITIVE CONTROL: selector returned nothing — every arm below is vacuous"
else
  ok "POSITIVE CONTROL: selector fires (selected: $got)"
fi

# The caller's own chain: 501, 500, 400, 300, 200 (and 1) must never appear.
for p in 1 200 300 400 500 501; do
  if grep -qE "(^| )$p( |$)" <<<"$got"; then bad "caller-chain pid $p selected — the reaper would kill its own caller"; else ok "caller-chain pid $p exempt"; fi
done
# The young shell is under the floor.
if grep -qE '(^| )700( |$)' <<<"$got"; then bad "700 selected despite being 30s old (floor 900s)"; else ok "age floor holds (700 spared)"; fi
# The wedged waiter IS selected.
if grep -qE '(^| )600( |$)' <<<"$got"; then ok "wedged waiter 600 selected"; else bad "wedged waiter 600 NOT selected — the bug this fixes goes unfixed"; fi

# Explicit protection list is honoured on top of the ancestor walk.
got2=$(sel 501 900 600)
if grep -qE '(^| )600( |$)' <<<"$got2"; then bad "--protect 600 ignored"; else ok "explicit protection honoured"; fi

# Age floor is a real dial, not a constant: at floor 10 the young shell joins.
got3=$(sel 501 10)
if grep -qE '(^| )700( |$)' <<<"$got3"; then ok "age floor is a dial (700 joins at floor=10)"; else bad "age floor is not honoured as a parameter"; fi

echo "== descendants =="
# The spinning child must be in hand BEFORE the parent is signalled: in the
# incident it survived SIGTERM to its parent and reparented to init, and could
# only be ended by a direct SIGKILL on a PID already collected.
desc=$(printf '%s\n' "$TABLE" | _reap_descendants 600 | sort -n | tr '\n' ' ' | sed 's/ $//')
is "descendants of 600 include the reparenting child" "$desc" "600 601"
desc2=$(printf '%s\n' "$TABLE" | _reap_descendants 400 | sort -n | tr '\n' ' ' | sed 's/ $//')
is "descendants of the runtime are the whole subtree" "$desc2" "400 500 501 600 601 700"

# ------------------------------------------------- heartbeat escalation memo --
# DIVE-3503 layer 3: _hb_mark_active_defer rewrites activeDefer every deferred
# tick. It MUST merge, or .escFp — the record of what the last force-nudge was
# aimed at — is dropped one tick after the escalation writes it and the
# repeat-detection can never match. Graded here as the jq expression, so this
# does not need a registry or a live agent.
echo "== heartbeat: escFp survives a counter tick =="
merged=$(jq -c -n --arg fp "PANE-B" --argjson c 2 '
  {agents:{dev:{heartbeat:{activeDefer:{fp:"PANE-A",n:1,escFp:"PANE-A"}}}}}
  | .agents.dev.heartbeat.activeDefer = ((.agents.dev.heartbeat.activeDefer // {}) + {fp:$fp, n:$c})
  | .agents.dev.heartbeat.activeDefer')
is "escFp survives, fp/n advance" "$merged" '{"fp":"PANE-B","n":2,"escFp":"PANE-A"}'
# Negative control: the pre-fix expression drops it. If this ever stops dropping,
# the arm above is grading nothing.
dropped=$(jq -c -n --arg fp "PANE-B" --argjson c 2 '
  {activeDefer:{fp:"PANE-A",n:1,escFp:"PANE-A"}}
  | .activeDefer = {fp:$fp, n:$c} | .activeDefer')
is "NEGATIVE CONTROL: bare assignment drops escFp" "$dropped" '{"fp":"PANE-B","n":2}'

# ------------------------------------------------ did the kill actually work --
# The reaper counts what it ENDED, not what it signalled, so the discriminator
# it uses gets graded. A bare `kill -0` would answer "still running" for a
# zombie — a process that is over but whose parent has not waited yet — and our
# victims' parents are runtimes that may not wait for seconds, so that reads as
# a failed kill on a successful one.
echo "== _reap_pid_ended =="
_reap_pid_ended "$$" && bad "_reap_pid_ended says THIS shell has ended" \
                     || ok "a running process is not ended"

sleep 0 & gone=$!; wait "$gone" 2>/dev/null || true
_reap_pid_ended "$gone" && ok "a reaped pid is ended" \
                        || bad "_reap_pid_ended says a fully-exited pid is still running"

# Zombie arm — the reason _reap_pid_ended is not a bare `kill -0`, so it is the
# arm that must not be skipped. Staged in a GRANDCHILD: a direct child of this
# shell is waited on and never lingers as Z, so the zombie has to belong to a
# parent that is still alive and not waiting — which is also the real case (our
# victims' parents are runtimes that wait late or not at all).
#
# The holder was staged at the top of the file; only the wait for it lives here.
# That wait was the second half of quinn's flake and it is bounded the way this
# row says a wait must be: by the CLOCK, not by an iteration count (the old
# 50 x 0.02s was 1s of sleep plus ~100 forks whose cost is load-dependent, a
# budget that cannot be compared with the holder's lifetime), and it observes
# the PRODUCER (`kill -0 $holder`) and not only the /proc proxy — so "the holder
# died first" is reported AS THAT instead of as "reaped-early".
z=""; zstate=""
zend=$(( SECONDS + ZDEADLINE ))
while [[ -n "$ZF" ]]; do
  z=$(cat "$ZF" 2>/dev/null || true); [[ -n "$z" ]] && break
  kill -0 "$holder" 2>/dev/null || { zstate="holder-died-before-it-published-a-pid"; break; }
  (( SECONDS >= zend )) && { zstate="timed-out-after-${ZDEADLINE}s-waiting-for-the-pid"; break; }
  sleep 0.02
done
if [[ -n "$z" ]]; then
  zend=$(( SECONDS + ZDEADLINE ))
  while :; do
    zraw=$(cat "/proc/$z/stat" 2>/dev/null) || { zstate="reaped-early"; break; }
    zraw="${zraw##*) }"; zstate="${zraw%% *}"
    [[ "$zstate" == "Z" ]] && break
    kill -0 "$holder" 2>/dev/null || { zstate="holder-died-first(last-state=$zstate)"; break; }
    (( SECONDS >= zend )) && { zstate="timed-out-after-${ZDEADLINE}s(last-state=$zstate)"; break; }
    sleep 0.02
  done
fi
if [[ "$zstate" == "Z" ]]; then
  _reap_pid_ended "$z" && ok "a zombie is ended (a bare kill -0 would say still running)" \
                       || bad "_reap_pid_ended reports a zombie as still running — a successful kill would read as failed"
  kill -0 "$z" 2>/dev/null && ok "NEGATIVE CONTROL: bare kill -0 does answer 'running' for it" \
                          || bad "NEGATIVE CONTROL: kill -0 already says gone — the arm above grades nothing"
else
  bad "zombie arm NOT STAGED (state=${zstate:-no-pid}) — the zombie branch went ungraded"
fi
# End it as soon as the arm is done with it; the EXIT trap (cleanup_staged) is
# the backstop for every path that does not reach here. No `wait` — it was
# disowned at staging, so it is no longer a job this shell can wait for.
[[ -z "$holder" ]] || kill -TERM "$holder" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
