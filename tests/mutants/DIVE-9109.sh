# DIVE-9109 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/premium_team_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the premium verifier accepts everything -> R1-R8 red.
m1() { sed -i 's/^_team_premium_verify() {$/_team_premium_verify() { return 0/' src/cmd_team_pack.sh; }
# m2: the inner stamp is not cross-checked against the signed label -> R9 red.
m2() { sed -i "s/'.team == \$o\[0\].team and .licensed_to.account == \$o\[0\].buyer.account'/'true'/" src/cmd_team_pack.sh; }
# m3: the chain checks the office app kind instead of the team kind -> V1, R3 red.
m3() { sed -i 's/_ou_chain "\$meta" "\$root" team_key/_ou_chain "$meta" "$root" office_key/' src/cmd_team_pack.sh; }
