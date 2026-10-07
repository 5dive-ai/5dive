# DIVE-5729 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/team_plan_first_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the verb guard is removed -> task cancel/done on the kickoff closes it (T21, T22 red; T23 stays green on the cascade guard alone).
m1() { sed -i 's/if \[\[ "\$_ko_held" != "0" \]\]; then/if false; then/' src/task/status.sh; }
# m2: the cascade guard is removed -> a close around the verbs releases the team (T24 red).
m2() { sed -i 's/if \[\[ "\$(_task_team_kickoff_holds "\$closed_id")" != "0" \]\]; then/if false; then/' src/task/loops.sh; }
# m3: both guards removed -> the reject's repro: cancel/done start the team (T21-T25 red).
m3() { m1; m2; }
# m4: the kickoff predicate never matches -> both guards are inert (T21-T24 red).
m4() { sed -i "s/AND k.body LIKE '%team kickoff: % (5dive.yaml)%');/AND 0);/" src/task/loops.sh; }
# m5: a closed kickoff is not resolvable -> the team cannot be answered after a stray close (T25 red).
m5() { sed -i 's/\[\[ -n "\$rows" \]\] || rows=\$(_team_kickoff_closed_holding "\$lead")/:/' src/cmd_compose.sh; }
# m6: the heartbeat blocked-sweep's kickoff exclusion is removed -> one tick after a stray close starts the team (T27 red; T25 red too, the team already started).
m6() { sed -i "/AND NOT EXISTS (SELECT 1 FROM task_deps d JOIN tasks k ON k.id=d.blocked_by/,+2d" src/cmd_heartbeat.sh; }
