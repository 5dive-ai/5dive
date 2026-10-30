#!/bin/bash
# harness-smoke.sh (DIVE-7115) — install ONE AI tool the way a hire does, on a
# fresh box, and check it starts. No key, no model call, no AI spend.
#
#   harness-smoke.sh list-types [header.sh]   print every agent type the CLI sells
#   harness-smoke.sh run <type> <os-label>    run the arm (inside the smoke container)
#
# `run` expects docker/harness-smoke.Dockerfile, booted, with the tree staged at
# /opt/5dive-bundle. It writes /harness-smoke-result.json and exits 0 only when
# every step passed. A red names the type, the OS and the step that failed:
#
#   install-5dive  install.sh from the tree under test did not finish
#   install        `5dive agent install <type>`: the recipe every hire runs
#   version        the installed binary does not answer --version
#   create         `5dive agent create --defer-auth` refused or died
#   start          the seat's unit or its tmux session did not come up and stay up
#   seat-version   the binary does not answer --version as the SEAT (its own uid
#                  and HOME): `version` runs it as claude, whose home holds the
#                  install, so a harness that only works there passed (DIVE-7330)
#
# "Up to just before sign-in" is what --defer-auth means: the seat is made and
# started with no credential, the state a dashboard "set up later" hire is in.
set -uo pipefail

STEP="" TYPE="" OS="" DETAIL=""
RESULT=/harness-smoke-result.json

list_types() {
  # TYPE_BIN is the registry of types (src/header.sh: "TYPE_BIN (mandatory)"),
  # so a type added there joins this smoke with no edit here.
  local header="${1:-src/header.sh}" types
  types=$(sed -n '/^declare -A TYPE_BIN=(/,/^)/p' "$header" \
    | grep -oE '^[[:space:]]*\[[a-z0-9_-]+\]=' | tr -d ' []=') || types=""
  [[ -n "$types" ]] || { echo "harness-smoke: found no agent types in $header" >&2; return 1; }
  printf '%s\n' "$types"
}

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

finish() {
  local result="$1"
  printf '{"type":%s,"os":%s,"step":%s,"result":%s,"detail":%s}\n' \
    "$(json_str "$TYPE")" "$(json_str "$OS")" "$(json_str "$STEP")" \
    "$(json_str "$result")" "$(json_str "$DETAIL")" > "$RESULT"
  if [[ "$result" == pass ]]; then
    echo "HARNESS-SMOKE PASS type=$TYPE os=$OS"
    exit 0
  fi
  echo "HARNESS-SMOKE FAIL type=$TYPE os=$OS step=$STEP: $DETAIL" >&2
  exit 1
}

step() { STEP="$1"; echo; echo "=== [$TYPE / $OS] $STEP"; }

# said <rc> <log> — "exited N: <the FIRST error line>": the cause, not the summary
# the tool prints after it (hermes: the libatomic line, not "pm install failed").
# The CLI's own generic "exited 1 without reporting a reason" is skipped when
# the installer printed something more specific above it.
said() {
  local rc="$1" log="$2" line
  (( rc == 124 )) && { printf 'timed out'; return; }
  line=$(grep -v -e 'without reporting a reason' -e 'logging before google.Init' "$log" 2>/dev/null \
    | grep -iE 'error|✗|fail|cannot|not found|cancel' | head -1) || line=""
  [[ -n "$line" ]] || line=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1) || line=""
  printf 'exited %s: %s' "$rc" "${line:0:400}"
}

run_arm() {
  TYPE="$1" OS="$2"
  # hs-<type>: seat names cap at 16 characters, and smoke-antigravity is 17.
  local name="hs-${TYPE}" rc=0 out bin

  step install-5dive
  echo "libatomic1: $(dpkg -s libatomic1 >/dev/null 2>&1 && echo present || echo absent)"
  timeout 1200 env REPO=file:///opt/5dive-bundle bash /opt/5dive-bundle/install.sh || rc=$?
  (( rc == 0 )) || { DETAIL="install.sh exited $rc"; finish fail; }
  command -v 5dive >/dev/null || { DETAIL="install.sh finished but 5dive is not on PATH"; finish fail; }

  step install
  timeout 1500 5dive agent install "$TYPE" 2>&1 | tee /tmp/install.log
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || { DETAIL="5dive agent install $TYPE $(said "$rc" /tmp/install.log)"; finish fail; }
  bin=$(sed -n '/^declare -A TYPE_BIN=(/,/^)/p' "$(command -v 5dive)" \
    | sed -n "s/^[[:space:]]*\[$TYPE\]=\"\(.*\)\"$/\1/p" | head -1) || bin=""
  [[ -n "$bin" && -x "$bin" ]] || { DETAIL="install exited 0 but '${bin:-TYPE_BIN[$TYPE]}' is not executable"; finish fail; }

  step version
  rc=0
  out=$(sudo -u claude -i bash -lc "timeout 60 $(printf '%q' "$bin") --version" 2>&1) || rc=$?
  printf '%s\n' "$out" | tail -5
  (( rc == 0 )) || { DETAIL="$bin --version exited $rc: $(printf '%s' "$out" | tail -1)"; finish fail; }
  [[ -n "${out//[[:space:]]/}" ]] || { DETAIL="$bin --version printed nothing"; finish fail; }

  step create
  # Grok agents are off until the server owner turns them on (DIVE-7066); the
  # owner's `grok enable` asks y/N on a terminal, so write its marker directly,
  # as managed provisioning does.
  [[ "$TYPE" == grok ]] && install -d /etc/5dive/arm && touch /etc/5dive/arm/grok-unfreeze
  timeout 600 5dive agent create "$name" --type="$TYPE" --channels=none --defer-auth \
    --no-skills --no-team-bot --no-heartbeat 2>&1 | tee /tmp/create.log
  rc=${PIPESTATUS[0]}
  (( rc == 0 )) || { DETAIL="5dive agent create --type=$TYPE --defer-auth $(said "$rc" /tmp/create.log)"; finish fail; }

  step start
  local unit="5dive-agent@${name}.service" session="agent-${name}" up=0
  for _ in $(seq 1 60); do
    if systemctl is-active --quiet "$unit" \
       && sudo -u "agent-${name}" tmux has-session -t "$session" 2>/dev/null; then
      up=1; break
    fi
    sleep 3
  done
  if (( up )); then
    # Still up a while later, on the first start: a harness that dies without
    # a key crash-loops, and a single look can land between two restarts.
    sleep 20
    local restarts
    restarts=$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || echo "?")
    if ! systemctl is-active --quiet "$unit"; then
      up=0; DETAIL="$unit came up, then stopped"
    elif ! sudo -u "agent-${name}" tmux has-session -t "$session" 2>/dev/null; then
      up=0; DETAIL="tmux session $session came up, then went away"
    elif [[ "$restarts" != 0 ]]; then
      up=0; DETAIL="$unit restarted $restarts time(s) in its first minute"
    fi
  else
    DETAIL="$unit / tmux session $session not up after 180s"
  fi
  echo "--- pane ($session) ---"
  sudo -u "agent-${name}" tmux capture-pane -p -t "$session" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -25 || true
  echo "--- journal ($unit) ---"
  journalctl -u "$unit" --no-pager -n 40 2>/dev/null || true
  (( up )) || finish fail

  # The unit and the pane stay up while the harness inside dies: the seat's
  # tmux loop restarts it forever. Ask the binary itself, as the seat, with the
  # PATH the seat gets: 5dive-agent-start loads claude's nvm for every type.
  step seat-version
  rc=0
  out=$(cd / && sudo -u "agent-${name}" -H bash -c 'unset NPM_CONFIG_PREFIX
    export NVM_DIR=/home/claude/.nvm
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
    exec timeout 60 "$0" --version' "$bin" 2>&1) || rc=$?
  printf '%s\n' "$out" | tail -5
  (( rc == 0 )) || { DETAIL="$bin --version as agent-${name} exited $rc: $(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1)"; finish fail; }

  STEP="" DETAIL=""
  finish pass
}

case "${1:-}" in
  list-types) shift; list_types "$@" ;;
  run) shift; [[ $# -eq 2 ]] || { echo "usage: $0 run <type> <os-label>" >&2; exit 2; }; run_arm "$@" ;;
  *) echo "usage: $0 list-types [header.sh] | run <type> <os-label>" >&2; exit 2 ;;
esac
