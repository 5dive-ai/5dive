# DIVE-5824 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the hire exception leaves the go-ahead line and sits on its own bullet ->
# the go-ahead-line arms red (the 0.82.0 shape the live lead read past).
m1() { sed -i 's/^\(- \*\*Your owner.s ask IS the go-ahead:\*\* .*Standard-tier route\.\) \(\*\*Except a hire:\*\* .*\)$/\1\n- \2/' projects-CLAUDE.md; }
# m2: the standing grant is no longer named -> the "full authority" arm reds.
m2() { sed -i 's/ or "full authority" is not one/ is not one/' projects-CLAUDE.md; }
# m3: the market pick drops the standing-grant clause -> the market yes arms red.
m3() { sed -i 's/your owner.s need is not a yes, nor is a standing \\"full authority\\": name/your owner'"'"'s need is not a yes: name/' src/cmd_pack.sh; }
# m4: the custom draft drops the standing-grant clause -> the --create next arm reds.
m4() { sed -i 's/Admin-tier: a standing \\"full authority\\" is not a yes; only/Admin-tier: only/' src/cmd_hire_link.sh; }
