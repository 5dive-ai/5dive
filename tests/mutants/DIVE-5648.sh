# DIVE-5648 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/gate_offbox_owner_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the TYPE clause is dropped -> tier-1 secret and manual gates are held (arms 4, 4b red).
m1() { sed -i "s/(need_type IN ('approval','decision')/(1/" src/lib/tasks_db.sh; }
# m2: the TIER clause is dropped -> a tier-2 approval is held (arm 5 reds).
m2() { sed -i "/AND CAST(COALESCE(NULLIF(tier,''),'2') AS INTEGER) < 2$/d" src/lib/tasks_db.sh; }
# m3: the deliverer never holds -> the root's approval pings the human (arm 1 reds).
m3() { sed -i 's/if _offbox=\$(_gate_offbox_held "\$ident"); then/if false; then/' src/task/notify.sh; }
# m4: the re-nag stops excluding held gates (arm 6 and the structural arm red).
m4() { sed -i '/^  AND NOT \${_GATE_OFFBOX_HELD_SQL:-0}$/d' src/cmd_heartbeat.sh; }
