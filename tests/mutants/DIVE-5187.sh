# DIVE-5187 mutants — each removes one defence of the sysadmin approval. Run from
# the tree root; the row's verify_command must go red under every one of them
# (tests/sysadmin_unit.sh arm h, and arm j2 re-checks it on each commit).
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: answer no longer refuses a seat caller
m1() {
  sed -i 's/^  \[\[ "\$caller" != agent-\* \]\] || fail .*$/  :/' src/cmd_sysadmin.sh
}
# m2: the broker answers on the seat's behalf (a seat-reachable approval, the old keyboard's class)
m2() {
  sed -i 's/^    status) _sysadmin_status "\$(jq -r .\.id \/\/ "". <<<"\$req")" ;;$/&\n    answer) _sysadmin_caller() { :; }; _sysadmin_answer "$(jq -r ".id" <<<"$req")" "$(jq -r ".answer" <<<"$req")" "--sha=$(jq -r ".sha" <<<"$req")" ;;/' src/cmd_sysadmin.sh
}
