# DIVE-5824 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
# INVERTED by DIVE-5974 (lodar 2026-10-10: the owner's ask is the go-ahead for a
# hire too). Each mutant now RESTORES one place DIVE-5824's yes rule was written.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the go-ahead line carves the hire out again -> the go-ahead-line arms red.
m1() { sed -i 's/\*\*Hires too:\*\* hire your pick, tell them who ("fire <name>" undoes it); one needing a plan upgrade waits for a yes\./**Except a hire:** wait for their yes; "I need someone to…" or "full authority" is not one, naming the agent is./' projects-CLAUDE.md; }
# m2: the market pick says a need or a standing grant is not a yes -> the market arms red.
m2() { sed -i 's/your owner.s ask is the go-ahead: admin, hire your pick, then tell them who (\\"fire <name>\\" undoes it); Standard-tier, send them 5dive hire-link <slug>/your owner'"'"'s need is not a yes, nor is a standing \\"full authority\\": name your pick to them; hire it once they say yes (or named it)/' src/cmd_pack.sh; }
# m3: the custom draft waits for a clear yes -> the --create arms red.
m3() { sed -i 's/Admin-tier: your owner.s ask is the go-ahead, so run 5dive hire-link \$HIRE_LINK_SLUG --hire now, then tell them who you hired\./Admin-tier: a standing \\"full authority\\" is not a yes; only on their clear yes, run 5dive hire-link $HIRE_LINK_SLUG --hire/' src/cmd_hire_link.sh; }
