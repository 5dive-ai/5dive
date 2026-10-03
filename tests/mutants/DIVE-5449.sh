# DIVE-5449 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/hired_agents_act_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the general owner-ask line is dropped -> the general-line arm reds.
m1() { sed -i "/^- \*\*Your owner's ask IS the go-ahead:\*\*/d" projects-CLAUDE.md; }
# m2: the root line goes back to untiered (sysadmin / lead for every seat) ->
# the admin negative control reds.
m2() { sed -i 's/^- \*\*Root\*\*, admin: `sudo 5dive`\. Standard-tier: /- **Root**: /' projects-CLAUDE.md; }
# m3: admin answers a hire ask with the link again -> the admin negative control reds.
m3() { sed -i 's/^\(- \*\*`5dive market` hires\*\*, admin: \)/\1send your human `5dive hire-link <slug>` or /' projects-CLAUDE.md; }
# m4: admin's blank teammate goes back to "send your human the sign-in link" ->
# the admin negative control reds.
m4() { sed -i 's/(else `5dive agent auth start <type>`)/, then send your human the `5dive agent auth start <type>` link/' projects-CLAUDE.md; }
