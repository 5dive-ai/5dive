# DIVE-5974 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the 10-09 "Except a hire" clause comes back on the go-ahead line -> the
# go-ahead-line arms and the no-yes negative control red.
m1() { sed -i 's/\*\*Hires too:\*\* hire your pick, tell them who ("fire <name>" undoes it); one needing a plan upgrade waits for a yes\./**Except a hire:** wait for their yes; "I need someone to…" or "full authority" is not one, naming the agent is./' projects-CLAUDE.md; }
# m2: the money case is dropped -> the plan-upgrade arm reds.
m2() { sed -i 's/; one needing a plan upgrade waits for a yes\././' projects-CLAUDE.md; }
# m3: the market pick goes back to "a need is not a yes" -> the market arms red.
m3() { sed -i 's/your owner.s ask is the go-ahead: admin, hire your pick, then tell them who (\\"fire <name>\\" undoes it); Standard-tier, send them 5dive hire-link <slug>/your owner'"'"'s need is not a yes, nor is a standing \\"full authority\\": name your pick to them; hire it once they say yes (or named it)/' src/cmd_pack.sh; }
# m4: the custom draft goes back to "only on their clear yes" -> the --create arms red.
m4() { sed -i 's/Admin-tier: your owner.s ask is the go-ahead, so run 5dive hire-link \$HIRE_LINK_SLUG --hire now, then tell them who you hired\./Admin-tier: only on their clear yes, run 5dive hire-link $HIRE_LINK_SLUG --hire./' src/cmd_hire_link.sh; }
# m5: the market pick loses its standard-tier route -> the market arms red.
m5() { sed -i 's/; Standard-tier, send them 5dive hire-link <slug>"/"/' src/cmd_pack.sh; }
