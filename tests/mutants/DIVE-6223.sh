# DIVE-6223 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/deliver_small_ci_grade_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the seat-FAIL check is dropped (quinn, iteration 1) -> the reject-then-shrink
# and seat-FAIL-verdict arms red.
m1() { sed -i 's/\[\[ "\$seat_fail" == "0" \]\] || return 0/:/' src/task/routing.sh; }
# m2: only the reject clause is dropped -> the reject-then-shrink arm reds.
m2() { sed -i 's/AND (handoff_rejected_at IS NOT NULL/AND (0/' src/task/routing.sh; }
# m3: only the verdict clause is dropped -> the seat-FAIL-verdict arm reds.
m3() { sed -i "s/graded_verdict='fail' AND COALESCE(graded_by,'') NOT LIKE 'ci:%'/0/" src/task/routing.sh; }
# m4: task deliver no longer asks the rails -> the README/small arms red.
m4() { sed -i 's/_skip=\$(_task_delivery_grader_skip "\$id")/_skip=""/' src/task/delivery.sh; }
# m5: merge standing is not widened to the merge owner of a ci:* row -> the
# standing and restamp arms red.
m5() { sed -i "s/ OR (graded_by LIKE 'ci:%' AND merge_owner = \$(sqlq \"\${1:-}\"))//" src/task/delivery.sh; }
# m6: a maker-stamped command PASS is not restamped ci:command -> the DIVE-6210 arm reds.
m6() { sed -i 's/if \[\[ -n "\$_cg_mk" && "\$_cg_gb" == "\$_cg_mk" \]\]; then/if false; then/' src/task/delivery.sh; }
# m7: --verify no longer beats the rails at deliver -> the --verify arm reds.
m7() { sed -i '/^_task_delivery_grader_skip()/,/^}/ s/\[\[ "\$forced" == "1" \]\] && return 0/:/' src/task/routing.sh; }
