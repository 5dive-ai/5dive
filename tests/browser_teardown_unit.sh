#!/usr/bin/env bash
# DIVE-4306 unit harness for the turn-end agent-browser teardown.
#
# The defect: agent-browser launches a headless Chrome tree and leaves it
# running past the end of the turn. Claude Code reports native status `busy`
# for as long as ANY background shell is alive, so `_hb_agent_idle` refuses to
# dispatch and the seat is frozen for the lifetime of that Chrome (measured
# 2026-09-11 on quinn: 1h20m). DIVE-4298 bounds that at the heartbeat; this
# change closes the leak, so there is nothing left to bound.
#
# Two units under test:
#   1. hooks/stop-browser-teardown.sh — the Stop hook itself, driven against
#      stubbed pgrep/pkill/agent-browser so every branch is reachable without
#      a browser, plus ONE live arm that opens a real agent-browser session
#      and asserts the hook leaves no process behind (skipped when the CLI or
#      its Chrome is not installed).
#   2. _register_browser_teardown_hook — extracted VERBATIM from
#      5dive-agent-start (not re-typed), so the arms grade the shipped text.
#
# Run: bash tests/browser_teardown_unit.sh   (no root, no network, no tmux.)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
ROOT="$PWD"
HOOK="$ROOT/hooks/stop-browser-teardown.sh"
START="$ROOT/5dive-agent-start"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }

[[ -x "$HOOK" ]] || { echo "PRECONDITION: $HOOK missing or not executable"; exit 1; }

# ---------------------------------------------------------------- stub rig --
# The hook kills through bash's `kill` BUILTIN, which a PATH stub cannot
# intercept -- so the rig does not fake the kill. It fakes only DISCOVERY:
# the `pgrep` stub reports a set of REAL processes we spawned (plain `sleep`s,
# and for the escalation arm a `sleep` that ignores SIGTERM), and each arm
# asserts on whether those processes are actually gone afterwards. So TERM,
# the grace loop and the KILL escalation are graded as executed, not as
# "the script called something we recorded".
#
# PIDS  : file holding the fake browser pids, one per line
# CALLS : file the agent-browser stub appends its invocations to
# CLOSE_CLEARS=1 : the graceful close really does end them (SIGKILL in the
#                  stub), so the hook's survivor path must not run.
mk_stubs() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/pgrep" <<'EOF'
#!/usr/bin/env bash
# Report only pids that are still alive; empty output + rc 1 == none left,
# which is exactly what real pgrep does.
out=""
while read -r p; do
  [[ -n "$p" ]] || continue
  kill -0 "$p" 2>/dev/null && out+="$p"$'\n'
done <"$PIDS"
[[ -n "$out" ]] || exit 1
printf '%s' "$out"
EOF
  cat > "$dir/agent-browser" <<'EOF'
#!/usr/bin/env bash
printf 'agent-browser %s\n' "$*" >>"$CALLS"
if [[ "${CLOSE_CLEARS:-1}" == 1 ]]; then
  while read -r p; do [[ -n "$p" ]] && kill -KILL "$p" 2>/dev/null; done <"$PIDS"
  sleep 0.2
fi
exit "${CLOSE_RC:-0}"
EOF
  chmod 755 "$dir"/pgrep "$dir"/agent-browser
}

spawn_fake() { # spawn_fake <pidfile> <count> [ignore-term]
  local f="$1" n="$2" ignore="${3:-}" i
  : >"$f"
  for ((i=0;i<n;i++)); do
    if [[ -n "$ignore" ]]; then
      setsid bash -c 'trap "" TERM; exec sleep 300' >/dev/null 2>&1 &
    else
      setsid sleep 300 >/dev/null 2>&1 &
    fi
    echo "$!" >>"$f"
  done
}

alive_count() { local f="$1" n=0 p; while read -r p; do [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && n=$((n+1)); done <"$f"; echo "$n"; }
reap_fakes()  { local f="$1" p; while read -r p; do [[ -n "$p" ]] && kill -KILL "$p" 2>/dev/null; done <"$f" 2>/dev/null; }

arm_env() { # arm_env <name> -> prints the case dir, with stubs + dirs ready
  local name="$1"
  local dir="$TMP/$name"
  mkdir -p "$dir/bin" "$dir/home/.claude" "$dir/home/.5dive"
  mk_stubs "$dir/bin"
  : >"$dir/calls"; : >"$dir/pids"
  echo "$dir"
}

run_hook() { # run_hook <dir> [extra env assignments...]
  local dir="$1"; shift
  env -i HOME="$dir/home" PATH="$dir/bin:/usr/bin:/bin" \
      PIDS="$dir/pids" CALLS="$dir/calls" \
      AGENT_BROWSER_KILL_GRACE=2 AGENT_BROWSER_CLOSE_TIMEOUT=5 "$@" \
      bash "$HOOK" >/dev/null 2>&1
  echo $?
}

# ---- arm 1: nothing running -> the hook does no work at all.
d="$(arm_env a1)"
rc="$(run_hook "$d")"
check "arm1 no browser running: exit 0" "$rc" "0"
check "arm1 no browser running: agent-browser never invoked" "$(wc -l <"$d/calls")" "0"

# ---- arm 2: browser up, graceful close really ends it -> no kill path.
d="$(arm_env a2)"; spawn_fake "$d/pids" 2
rc="$(run_hook "$d" CLOSE_CLEARS=1)"
check "arm2 graceful close: exit 0" "$rc" "0"
check "arm2 graceful close: close --all called once" \
  "$(grep -c 'agent-browser close --all' "$d/calls")" "1"
check "arm2 graceful close: no browser process left" "$(alive_count "$d/pids")" "0"
grep -q 'closed by agent-browser close --all' "$d/home/.claude/browser-teardown.log" \
  && ok "arm2 graceful close: logged as closed by the CLI" \
  || bad "arm2 graceful close: log line" "$(cat "$d/home/.claude/browser-teardown.log" 2>/dev/null)"
reap_fakes "$d/pids"

# ---- arm 3: close fails/hangs -> survivors get SIGTERM and die.
d="$(arm_env a3)"; spawn_fake "$d/pids" 2
rc="$(run_hook "$d" CLOSE_CLEARS=0 CLOSE_RC=1)"
check "arm3 close failed: exit 0 (never blocks Stop)" "$rc" "0"
check "arm3 close failed: survivors reaped" "$(alive_count "$d/pids")" "0"
grep -q 'terminated on SIGTERM' "$d/home/.claude/browser-teardown.log" \
  && ok "arm3 close failed: logged as SIGTERM teardown" \
  || bad "arm3 close failed: log line" "$(cat "$d/home/.claude/browser-teardown.log" 2>/dev/null)"
reap_fakes "$d/pids"

# ---- arm 4: a tree that IGNORES SIGTERM must be escalated to SIGKILL.
d="$(arm_env a4)"; spawn_fake "$d/pids" 1 ignore-term
sleep 0.3
rc="$(run_hook "$d" CLOSE_CLEARS=0 CLOSE_RC=1)"
check "arm4 stubborn tree: exit 0" "$rc" "0"
check "arm4 stubborn tree: killed anyway" "$(alive_count "$d/pids")" "0"
grep -q 'SIGKILL sent' "$d/home/.claude/browser-teardown.log" \
  && ok "arm4 stubborn tree: escalation logged" \
  || bad "arm4 stubborn tree: log line" "$(cat "$d/home/.claude/browser-teardown.log" 2>/dev/null)"
reap_fakes "$d/pids"

# ---- arm 5: an unexpired lease suppresses the teardown entirely.
d="$(arm_env a5)"; spawn_fake "$d/pids" 1
echo $(( $(date +%s) + 600 )) >"$d/home/.5dive/browser-lease"
rc="$(run_hook "$d")"
check "arm5 live lease: exit 0" "$rc" "0"
check "arm5 live lease: agent-browser never invoked" "$(wc -l <"$d/calls")" "0"
check "arm5 live lease: browser still up" "$(alive_count "$d/pids")" "1"
reap_fakes "$d/pids"

# ---- arm 6: an EXPIRED lease does not suppress it (the lease self-heals).
d="$(arm_env a6)"; spawn_fake "$d/pids" 1
echo $(( $(date +%s) - 60 )) >"$d/home/.5dive/browser-lease"
run_hook "$d" CLOSE_CLEARS=1 >/dev/null
check "arm6 expired lease: close --all still called" \
  "$(grep -c 'agent-browser close --all' "$d/calls")" "1"
check "arm6 expired lease: browser gone" "$(alive_count "$d/pids")" "0"
reap_fakes "$d/pids"

# ---- arm 7: a garbage lease file is not a lease.
d="$(arm_env a7)"; spawn_fake "$d/pids" 1
printf 'forever\n' >"$d/home/.5dive/browser-lease"
run_hook "$d" CLOSE_CLEARS=1 >/dev/null
check "arm7 unparseable lease: torn down anyway" "$(alive_count "$d/pids")" "0"
reap_fakes "$d/pids"

# ---- arm 8: the shipped PATTERN must not match a shell that merely MENTIONS
# agent-browser. This is the bug the rig itself hit: a bare pattern
# self-matched the checking shell, and `kill` on that ends the session.
PAT="$(sed -n 's/^PATTERN="\${AGENT_BROWSER_PROC_PATTERN:-\(.*\)}"$/\1/p' "$HOOK")"
check "arm8 pattern extracted from the shipped hook" "${PAT:+yes}" "yes"
matches() { printf '%s' "$1" | grep -qE -- "$PAT" && echo yes || echo no; }
check "arm8 matches the agent-browser CLI" \
  "$(matches '/usr/lib/node_modules/agent-browser/bin/agent-browser-linux-x64')" "yes"
check "arm8 matches the Chrome it spawns" \
  "$(matches '/home/x/.agent-browser/browsers/chrome-153.0.8010.36/chrome --headless=new')" "yes"
check "arm8 matches the crashpad handler" \
  "$(matches '/home/x/.agent-browser/browsers/chrome-153.0.8010.36/chrome_crashpad_handler --monitor-self')" "yes"
check "arm8 does NOT match a shell mentioning it" \
  "$(matches 'bash -c pgrep -u 1001 -f agent-browser | head')" "no"
check "arm8 does NOT match this hook itself" \
  "$(matches 'bash /usr/local/lib/5dive/stop-browser-teardown.sh')" "no"
check "arm8 does NOT match an unrelated chrome" \
  "$(matches '/opt/google/chrome/chrome --headless')" "no"

# ---- MUTATION CONTROL: with the teardown body removed the hook must STOP
# ending the tree. A rig that still passes arm3 against a gutted hook grades
# nothing.
sed -e 's/^  timeout "\$close_timeout" agent-browser close --all.*$/  :/' \
    -e 's/^  kill -TERM \$pids.*$/  :/' -e 's/^    kill -KILL \$pids.*$/    :/' \
    "$HOOK" >"$TMP/hook-mut.sh"
d="$(arm_env m1)"; spawn_fake "$d/pids" 1
env -i HOME="$d/home" PATH="$d/bin:/usr/bin:/bin" PIDS="$d/pids" CALLS="$d/calls" \
    AGENT_BROWSER_KILL_GRACE=1 CLOSE_CLEARS=0 \
    bash "$TMP/hook-mut.sh" >/dev/null 2>&1
if [[ "$(alive_count "$d/pids")" == "1" ]]; then
  ok "mutation control: gutted hook leaves the tree up (arms are non-vacuous)"
else
  bad "mutation control" "gutted hook still ended the tree — the rig grades nothing"
fi
reap_fakes "$d/pids"

# ------------------------------------------------- registration function ----
# Extract the function VERBATIM from the shipped boot script.
awk '/^_register_browser_teardown_hook\(\) \{/,/^\}$/' "$START" >"$TMP/reg.sh"
if [[ ! -s "$TMP/reg.sh" ]]; then
  bad "extract _register_browser_teardown_hook" "not found in $START"
else
  ok "extracted _register_browser_teardown_hook from 5dive-agent-start ($(wc -l <"$TMP/reg.sh") lines)"
  # shellcheck source=/dev/null
  . "$TMP/reg.sh"
  FAKEHOOK="$TMP/fake-teardown.sh"; printf '#!/bin/sh\nexit 0\n' >"$FAKEHOOK"; chmod 755 "$FAKEHOOK"

  S="$TMP/settings-basic.json"
  printf '{"model":"claude-opus-5","permissions":{"defaultMode":"bypassPermissions"}}\n' >"$S"
  _register_browser_teardown_hook "$S" "$FAKEHOOK"
  check "reg1 hook registered on Stop" \
    "$(jq -r --arg h "$FAKEHOOK" '[.hooks.Stop[].hooks[].command]|index($h)!=null' "$S")" "true"
  check "reg1 unrelated keys preserved" \
    "$(jq -r '.permissions.defaultMode' "$S")" "bypassPermissions"

  before="$(cat "$S")"
  _register_browser_teardown_hook "$S" "$FAKEHOOK"
  check "reg2 idempotent (second boot changes nothing)" "$(cat "$S")" "$before"
  check "reg2 exactly one Stop entry" \
    "$(jq '[.hooks.Stop[].hooks[].command]|length' "$S")" "1"

  S2="$TMP/settings-existing.json"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/local/lib/5dive/sessionstart-resume-context.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/usr/local/lib/5dive/stop-telegram-reply-check.sh"}]}]}}\n' >"$S2"
  _register_browser_teardown_hook "$S2" "$FAKEHOOK"
  check "reg3 existing Stop hook kept (append, not replace)" \
    "$(jq -r '[.hooks.Stop[].hooks[].command]|index("/usr/local/lib/5dive/stop-telegram-reply-check.sh")!=null' "$S2")" "true"
  check "reg3 SessionStart untouched" \
    "$(jq '.hooks.SessionStart|length' "$S2")" "1"
  check "reg3 teardown appended" \
    "$(jq '[.hooks.Stop[].hooks[].command]|length' "$S2")" "2"

  S3="$TMP/settings-nohook.json"; printf '{"model":"x"}\n' >"$S3"
  _register_browser_teardown_hook "$S3" "$TMP/does-not-exist.sh"
  check "reg4 uninstalled hook file -> settings untouched" "$(cat "$S3")" '{"model":"x"}'

  _register_browser_teardown_hook "$TMP/no-such-settings.json" "$FAKEHOOK"
  check "reg5 missing settings.json -> no file created" \
    "$([[ -e "$TMP/no-such-settings.json" ]] && echo yes || echo no)" "no"

  S6="$TMP/settings-perm.json"
  printf '{"model":"x"}\n' >"$S6"; chmod 600 "$S6"
  _register_browser_teardown_hook "$S6" "$FAKEHOOK"
  check "reg6 mode stays 600 after rewrite" "$(stat -c '%a' "$S6")" "600"
fi

# ------------------------------------------------------------- live arm -----
# The row's acceptance test: a COMPLETED browser run leaves no agent-browser
# or chrome process behind. Real CLI, real Chrome, real hook — skipped (not
# failed) where the browser is not installed, e.g. CI.
if command -v agent-browser >/dev/null 2>&1 \
   && [[ -d "$HOME/.agent-browser/browsers" || -n "${AGENT_BROWSER_LIVE:-}" ]]; then
  # Count with the SHIPPED pattern, not a bare word: a bare one self-matches
  # the very shell running the count (see arm8).
  own() { pgrep -u "$(id -u)" -f "$PAT" 2>/dev/null | grep -vx -e "$$" -e "$PPID" | wc -l; }
  base="$(own)"
  if [[ "$base" != "0" ]]; then
    printf 'SKIP live arm: %s agent-browser process(es) already resident for this uid\n' "$base"
  else
    timeout 90 agent-browser open "about:blank" >/dev/null 2>&1
    after_open="$(own)"
    if [[ "$after_open" == "0" ]]; then
      printf 'SKIP live arm: agent-browser open launched no resident process\n'
    else
      ok "live: a completed browser run leaves $after_open process(es) resident (the leak)"
      AGENT_BROWSER_KILL_GRACE=3 bash "$HOOK" >/dev/null 2>&1
      after_hook="$(own)"
      check "live: no agent-browser/chrome process survives the Stop hook" "$after_hook" "0"
    fi
  fi
else
  printf 'SKIP live arm: agent-browser CLI or its Chrome not installed here\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
