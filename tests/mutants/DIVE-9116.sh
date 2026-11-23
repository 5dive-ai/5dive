# DIVE-9116 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/premium_team_update_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: an installed premium team is never seen as installed (a re-import adopts the
# seats untouched, as before this row) -> U1, U3-U5, U8, D1, D2, B1 red.
m1() { sed -i 's/^_team_premium_update_from() {$/_team_premium_update_from() { return 0/' src/cmd_team_pack.sh; }
# m2: the role block is appended instead of swapped -> U4 red (two role blocks).
m2() { sed -i 's/_team_role_block_swap "\$stage\/old" "\$stage\/block" >"\$stage\/new" || rc=\$?/rc=3/' src/cmd_compose.sh; }
# m3: the buyer is not compared -> B1 red.
m3() { sed -i 's/if \[\[ "\$nacct" != "\$oacct" \]\]; then/if false; then/' src/cmd_team_pack.sh; }
# m4: the version is not compared -> D1, D2 red.
m4() { sed -i 's/if (( cmp <= 0 \&\& ! allow )); then/if false; then/' src/cmd_team_pack.sh; }
# m5: a pack FILE is ignored by agent update (it falls back to the recorded source)
# -> U5 red (skill and pack section stay at 1.0.0).
m5() { sed -i 's/^  if \[\[ -n "\$pfile" \]\]; then$/  if false; then/' src/cmd_pack.sh; }
