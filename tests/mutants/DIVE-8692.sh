# DIVE-8692 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/loop_improve_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the rewritten sentence is no longer read-only (quinn it3) -> T5 read-only
# arms, T18, T21 red.
m1() { sed -i 's/^  if \[\[ -n "\${gone\/\/\[\[:space:\]\]\/}" \]\]; then$/  if false; then/' src/task/loops.sh; }
# m2: read-only checks only the find text, not the sentence it touches -> the
# term-free-piece arm ("it." -> "it, unless asked.") red.
m2() { sed -i 's/^    gone=\$(_loop_improve_sentence "\$cur" "\$gone");/    gone="$gone";/' src/task/loops.sh; }
# m3: limits match exact words again, not stems -> 'approved' -> 'ready' red.
m3() { sed -i 's/approv\[a-z\]\*/approve/; s/review\[a-z\]\*/review/; s/wait\[a-z\]\*/wait/; s/confirm\[a-z\]\*/confirm/' src/task/loops.sh; }
# m4: the override list is gone -> 'Ignore the rule above.' appended red.
m4() { sed -i 's/^_LOOP_IMPROVE_OVERRIDE_RX=.*/_LOOP_IMPROVE_OVERRIDE_RX=""/' src/task/loops.sh; }
