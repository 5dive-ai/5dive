# DIVE-7873 negative controls, run from the tree root (task deliver's computed
# grade, DIVE-4825). Each must red tests/backup_unit.sh.
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# m1: a restore brings back the OLD box's identity (quinn it1: this mutant passed
# about half the time while both fixture tokens had one length) -> IDENTITY reds.
m1() { sed -i 's#/etc/5dive/connectord.env /etc/5dive/provisioning.env#/etc/5dive/provisioning.env#' src/cmd_backup.sh; }
# m2: enable ignores an EARLIER box's backup under the owner's prefix (quinn it1
# fix 1) -> the FRESH BOX and SEQUENCE step 1 arms red.
m2() { sed -i 's/if \[\[ -n "\$repos" \]\] && (( ! newkey )); then/if false; then/' src/cmd_backup.sh; }
# m3: restore claims backups continue when nothing opens this box's own repo
# (quinn it1 fix 2) -> the MISMATCH arms red.
m3() { sed -i 's/own_err="\$BK_REPO already holds a backup under a different key, and nothing on this box opens it"/:/' src/cmd_backup.sh; }
# m4: restore probes with the box's old key but never re-keys -> the RE-KEY arms red.
m4() { sed -i 's/_bk_repo_probe "\$dir\/key" && _bk_rekey "\$dir\/key" "\$pw"; }/_bk_repo_probe "$dir\/key"; }/' src/cmd_backup.sh; }
# m5: a failed run's error comes from the log's last line again (quinn it1 nit 4)
# -> the silent-restic arm reds.
m5() { sed -i 's/local last; last=\$(grep -v/local last; last=$(tail -n 1 "$log"); : $(grep -v/' src/cmd_backup.sh; }
# m6: the code leaks into the run report -> CUSTODY reds.
m6() { sed -i 's/_bk_report "\$ok" "\$err" "\$bytes" "\$snap"$/_bk_report "$ok" "$err $(cat "$dir\/key")" "$bytes" "$snap"/' src/cmd_backup.sh; }
