#!/usr/bin/env bash
# DIVE-3961: Codex dashboard and combined-channel launcher/install wiring.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/5dive-agent-start"

fail() { echo "FAIL: $*" >&2; exit 1; }
check() { "$@" || fail "$*"; }

# Exercise the exact channel selector used by the boot path. Removing either
# membership arm makes a supported mode fail here.
eval "$(sed -n '/^codex_dispatcher_enabled() {/,/^}/p' "$START")"
check codex_dispatcher_enabled dashboard
check codex_dispatcher_enabled telegram
check codex_dispatcher_enabled telegram,dashboard
check codex_dispatcher_enabled dashboard,telegram
if codex_dispatcher_enabled none || codex_dispatcher_enabled discord; then
  fail "dispatcher selected for a non-Codex channel"
fi

check grep -q 'CODEX_BIN=.*CODEX_REAL_BIN' "$START"
check grep -q 'CODEX_DISPATCHER_CHANNELS=.*CHANNELS' "$START"
check grep -q 'CODEX_DISPATCHER_WORKDIR=.*WORKDIR' "$START"
check grep -q 'ARGS=(run --cwd "$CODEX_PLUGIN_DIR" --shell=bun --silent start)' "$START"
check grep -q 'codex) : ;; # app-server dispatcher' "$START"

# Fresh installs must carry the sibling adapter because dispatcher.ts resolves
# ../dashboard/server.ts at runtime. Both dependency trees are installed.
check grep -q "5dive-plugins-main/plugins/dashboard" "$ROOT/install.sh"
check grep -q 'LIB_DIR/dashboard' "$ROOT/install.sh"
check grep -q 'cd .*LIB_DIR/dashboard.*bun install' "$ROOT/install.sh"

# Codex dashboard setup is token-free and prepares the compatibility inbox
# where shelld already drops dashboard messages.
check grep -q '"$plugin" == "telegram" || "$plugin" == "dashboard"' "$ROOT/src/lib/agent_setup.sh"
check grep -q '\.claude/channels/dashboard/agent-inbox' "$ROOT/src/lib/agent_setup.sh"
if grep -q 'channels=dashboard is claude-only' \
    "$ROOT/src/cmd_agent_create.sh" "$ROOT/src/cmd_agent_config.sh" "$ROOT/src/lib/agent_setup.sh" "$START"; then
  fail "a Claude-only dashboard rejection remains in a managed path"
fi
if grep -qi 'dashboard.*claude-only' \
    "$START" "$ROOT/src/main.sh" "$ROOT/src/cmd_agent_config.sh"; then
  fail "CLI help still describes dashboard as Claude-only"
fi

bash -n "$START" "$ROOT/install.sh" "$ROOT/src/cmd_agent_create.sh" \
  "$ROOT/src/cmd_agent_config.sh" "$ROOT/src/lib/agent_setup.sh"
echo "PASS: Codex dashboard launcher, combined-channel selection, install layout, and token-free setup"
