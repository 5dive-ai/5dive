# DIVE-5722 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: any seat may --hire -> the standard / unmeasured-tier refusal arms red.
m1() { sed -i 's/^_hire_link_may_hire() {$/_hire_link_may_hire() { return 0;/' src/cmd_hire_link.sh; }
# m2: --create hires on the spot -> the "hires nothing" arm reds.
m2() { sed -i 's/^  _hire_link_lookup "\$HIRE_LINK_SLUG"$/  _hire_link_call POST "\/server\/custom-agents\/$id\/hire"; _hire_link_lookup "$HIRE_LINK_SLUG"/' src/cmd_hire_link.sh; }
# m3: the card link is not checked against the agent made -> the foreign-card arm reds.
m3() { sed -i 's/startapp=agent-\${slug}\$ \]\]/startapp=agent-[a-z0-9_-]+$ ]]/' src/cmd_hire_link.sh; }
# m4: the stale prose comes back -> the not-catalogue arm reds.
m4() { sed -i 's/For a need no catalogue agent fits, make one: 5dive hire-link --create --name=<Name> --description=<what they need>/A custom agent has no Mini App tile: your human makes it on the web dashboard, Agents, New agent, Custom./' src/cmd_hire_link.sh; }
# m5: the block loses its custom-agent line -> the block arm reds.
m5() { sed -i '/^- \*\*None fits:\*\*/d' projects-CLAUDE.md; }
