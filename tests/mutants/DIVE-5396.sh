# DIVE-5396 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: any name counts as exact -> 'x11-.+' and 'o.+' reach apt-get as regexes.
m1() { sed -i 's/^_pkg_exact() {$/_pkg_exact() { return 0;/' src/cmd_pkg.sh; }
# m2: the prefix match is taken as a hit -> 'jq.' (prefix of jqp) passes.
m2() { sed -i 's/grep -qxF -- "\$1" <<<"\$all"/[[ -n "$all" ]]/' src/cmd_pkg.sh; }
# m3: the root half trusts the env under sudo -> the seam arms red.
m3() { sed -i 's/^  \[\[ "\${1:-\$EUID}" == 0 \&\& -n "\${SUDO_UID:-}" \]\] || return 0$/  return 0/' src/cmd_pkg.sh src/cmd_route.sh; }
