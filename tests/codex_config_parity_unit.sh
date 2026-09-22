#!/usr/bin/env bash
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
TMP=$(mktemp -d /tmp/codex-config-parity.XXXXXX)
trap 'rc=$?; rm -rf "$TMP"; echo "HARNESS-RC=$rc"' EXIT
AGENT_HOME_ROOT="$TMP/home"; export AGENT_HOME_ROOT
mkdir -p "$AGENT_HOME_ROOT/agent-seat/.codex"
cat > "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
[projects."/work"]
trust_level = "trusted"
EOF
chmod 640 "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml"

extract_fn() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\)" {on=1} on {print} on && $0 == "}" {exit}' src/cmd_agent.sh; }
source <(extract_fn resolve_agent_effort)
source <(extract_fn resolve_codex_setting)
source <(extract_fn write_runtime_codex_setting)
source <(extract_fn write_runtime_effort)
priv_read() { local _f=$1; shift; "$@"; }
E_VALIDATION=3; E_NOT_FOUND=4; E_GENERIC=1
fail() { echo "FAIL[$1] $2" >&2; return "$1"; }

P=0; F=0
is() { if [[ "$2" == "$3" ]]; then P=$((P+1)); else echo "FAIL: $1 want=$3 got=$2"; F=$((F+1)); fi; }

write_runtime_effort codex seat high
write_runtime_codex_setting seat approval_policy on-request
write_runtime_codex_setting seat sandbox_mode workspace-write
is effort "$(resolve_agent_effort codex seat)" high
is approval "$(resolve_codex_setting seat approval_policy)" on-request
is sandbox "$(resolve_codex_setting seat sandbox_mode)" workspace-write
is table-preserved "$(sed -n '/^\[projects/,/trusted/p' "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml" | tr '\n' '|')" '[projects."/work"]|trust_level = "trusted"|'
is effort-singleton "$(grep -c '^model_reasoning_effort' "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml")" 1
is approval-singleton "$(grep -c '^approval_policy' "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml")" 1
is mode-preserved "$(stat -c %a "$AGENT_HOME_ROOT/agent-seat/.codex/config.toml")" 600

printf 'codex_config_parity_unit: %d passed, %d failed\n' "$P" "$F"
(( F == 0 ))
