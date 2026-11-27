# DIVE-9418 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/agent_proactive_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: a teammate's pending claim is never counted -> T18 race: second agent refused red.
m1() { sed -i 's/elif \$mate and (.at \/\/ "") >= \$ps then/elif false then/' src/cmd_agent_proactive.sh; }
# m2: a pending claim blocks forever (no window) -> T18 race: older than the window red.
m2() { sed -i 's/elif \$mate and (.at \/\/ "") >= \$ps then/elif $mate then/' src/cmd_agent_proactive.sh; }
# m3: the claim lock is per agent again -> T18 race: owner's lock red.
m3() { sed -i 's|lock="${TASKS_DIR:-/tmp}/.proactive-owner-${owner//\[^A-Za-z0-9_.-\]/_}.lock"|lock="${TASKS_DIR:-/tmp}/.proactive-${name}.lock"|' src/cmd_agent_proactive.sh; }
