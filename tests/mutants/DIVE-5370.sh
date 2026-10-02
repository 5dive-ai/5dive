# DIVE-5370 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/secret_tools_connector_unit.sh or
# tests/secret_gate_delivery_path_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: `secret write` stops checking the name -> S7 (PATH, LD_PRELOAD, ...) red.
m1() { sed -i 's/&& _tools_var_reserved "\$key"; then/\&\& false; then/' src/cmd_secret.sh; }
# m2: `task need` stops checking the name -> secret_gate_delivery_path N8 red.
m2() { sed -i 's/&& _tools_var_reserved "\$secret_key"; then/\&\& false; then/' src/task/need.sh; }
# m3: the reserved list is empty -> S7 and N8 both red.
m3() { sed -i 's/^_tools_var_reserved() {$/_tools_var_reserved() { return 1;/' src/lib/validation.sh; }
# m4: back to a denylist — a name that is not a credential name is accepted ->
# S7 (HTTPS_PROXY, NODE_TLS_REJECT_UNAUTHORIZED, FUNCNEST, ...) and N8 red.
m4() { sed -i 's/^  return 0 # not a credential name: refused$/  return 1/' src/lib/validation.sh; }
