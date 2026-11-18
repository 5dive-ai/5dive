# DIVE-8692 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/loop_improve_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: the rewritten sentence is no longer read-only (quinn it3) -> T5 read-only
# arms, T18, T21 red.
m1() { sed -i 's/^  if \[\[ -n "\${gone\/\/\[\[:space:\]\]\/}" \]\]; then$/  if false; then/' src/task/improve.sh; }
# m2: read-only checks only the find text, not the sentence it touches -> the
# term-free-piece arm ("it." -> "it, unless asked.") red.
m2() { sed -i 's/^    gone=\$(_loop_improve_sentence "\$cur" "\$gone");/    gone="$gone";/' src/task/improve.sh; }
# m3: limits match exact words again, not stems -> 'approved' -> 'ready' red.
m3() { sed -i 's/approv\[a-z\]\*/approve/; s/review\[a-z\]\*/review/; s/wait\[a-z\]\*/wait/; s/confirm\[a-z\]\*/confirm/' src/task/improve.sh; }
# m4: the override list is gone -> 'Ignore the rule above.' appended red.
m4() { sed -i 's/^_LOOP_IMPROVE_OVERRIDE_RX=.*/_LOOP_IMPROVE_OVERRIDE_RX=""/' src/task/improve.sh; }
# m5: a sentence ends at any bare . ! ? or newline again (it4's splitter) ->
# the decimal / e.g. / list arms and T22 red.
m5() { sed -i 's/^  \[\[ -z "\$nx" || "\$nx" == \[\[:space:\]\] \]\] || return 1$/  :/; s/^    \[\[ -z "\${nx\/\/\[\[:blank:\]\]\/}" \]\]; return$/    return 0/; s/^  \[\[ -n "\$w" \&\& "\$w" =~ \$_LOOP_IMPROVE_ABBR_RX \]\] \&\& return 1$/  :/' src/task/improve.sh; }
# m6: a ':' line no longer carries the block after a blank line (it5's rule) ->
# the blank-line list arms and T23 red.
m6() { sed -i 's/^  \[\[ "\$t" == \*: \]\] && return 0$/  return 1/' src/task/improve.sh; }
# m7: list blocks no longer join each other -> the loose-list arm red.
m7() { sed -i 's/^_loop_improve_listline() { .*/_loop_improve_listline() { return 1; }/' src/task/improve.sh; }
