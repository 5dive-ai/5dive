#!/usr/bin/env bash
# install.sh replaces the agent launcher and the host scripts by RENAME, not in place.
#
# WHY THIS EXISTS. `curl -o <path>` truncates the existing file and keeps its
# inode, and bash reads a running script by byte offset as it goes. Every seat's
# main process is `bash /usr/local/bin/5dive-agent-start <seat>`, so an update
# that rewrote the launcher in place left each of them to resume at its OLD offset
# in the NEW bytes. Measured on a 0.50.0 -> 0.53.0 update: a seat stopped fourteen
# minutes after the write died with `line 2065: $'\200\224': command not found`
# (the tail of an em-dash) and status 127.
#
# This harness parks a real `bash <launcher>` past its first lines, replaces the
# file under it, and grades what the running process does next. The fixed helper
# must let it finish its OLD tail; the pre-fix write and a helper whose rename is
# mutated back into an in-place copy must both go red on the same detector.
#
# Hermetic: replace_by_rename is extracted verbatim from install.sh and fed by
# curl over file://. No network, no root. The one live arm reads a running
# 5dive-agent@ unit on the host and SKIPS where none runs (CI).
set -uo pipefail
# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${W:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
W="$(mktemp -d)"

echo "# the shipped helper, extracted verbatim"
eval "$(grep '^die()' install.sh)"
eval "$(sed -n '/^replace_by_rename() {$/,/^}$/p' install.sh)"
if declare -F replace_by_rename >/dev/null; then
  ok_t "install.sh defines replace_by_rename"
else
  bad_t "install.sh defines replace_by_rename" "not found; every arm below is ungraded"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

echo "# the writes that running processes execute go through it"
grep -qF 'replace_by_rename "$BIN_DIR/5dive-agent-start" curl -fsSL "$REPO/5dive-agent-start"' install.sh \
  && ok_t "the launcher is replaced by rename" \
  || bad_t "the launcher is replaced by rename" "install.sh no longer routes 5dive-agent-start through replace_by_rename"
grep -qF 'replace_by_rename "$BIN_DIR/$_hs_name" curl -fsSL "$REPO/$_hs_name"' install.sh \
  && ok_t "the host scripts are replaced by rename" \
  || bad_t "the host scripts are replaced by rename" "the host-scripts.manifest loop no longer routes through replace_by_rename"
inplace="$(grep -nE -- '-o[[:space:]]+"?\$\{?BIN_DIR\}?/' install.sh || true)"
[[ -z "$inplace" ]] && ok_t "no curl writes straight into \$BIN_DIR" \
                    || bad_t "no curl writes straight into \$BIN_DIR" "$inplace"

# OLD parks after its first two lines until $2 exists, then prints its tail.
# NEW is built so OLD's resume offset lands on the 2nd byte of an em-dash: the
# exact bytes the seat hit, so an in-place write reproduces `$'\200\224'`.
printf '#!/usr/bin/env bash\n: > "$1"; until [[ -e "$2" ]]; do sleep 0.05; done\necho OLD-TAIL\n' > "$W/old"
off=$(head -2 "$W/old" | wc -c)
l1='#!/usr/bin/env bash'
{ printf '%s\n#%*s' "$l1" $(( off - ${#l1} - 3 )) ''; printf '\xe2\x80\x94\necho NEW-TAIL\n'; } > "$W/new"
[[ "$(tail -c +$((off + 1)) "$W/new" | head -c 2 | od -An -tx1 | tr -d ' \n')" == 8094 ]] \
  && ok_t "fixture: the old offset lands mid em-dash in the new file" \
  || bad_t "fixture: the old offset lands mid em-dash in the new file" "offset $off"

# run_swap <writer…>: start OLD as a running `bash <dest>`, replace <dest> with
# `<writer…> <dest>` while it is parked, release it. Sets OUT ERR RC WRC INODE0 INODE1.
DEST="$W/bin/5dive-agent-start"
run_swap() {
  local pid
  rm -rf "${W:?}/bin" "$W/ready" "$W/go"; mkdir -p "$W/bin"
  cp "$W/old" "$DEST"; chmod 755 "$DEST"; INODE0=$(stat -c %i "$DEST")
  timeout 20 bash "$DEST" "$W/ready" "$W/go" > "$W/out" 2> "$W/err" & pid=$!
  for _ in $(seq 200); do [[ -e "$W/ready" ]] && break; sleep 0.05; done
  "$@" "$DEST"; WRC=$?
  : > "$W/go"; wait "$pid"; RC=$?
  OUT=$(cat "$W/out"); ERR=$(cat "$W/err"); INODE1=$(stat -c %i "$DEST" 2>/dev/null)
}
# the detector: the running process finished what it started, on the old inode
survived() { [[ $RC -eq 0 && "$OUT" == OLD-TAIL && -z "$ERR" && "$INODE0" != "$INODE1" ]]; }
w_fixed()   { ( replace_by_rename "$1" curl -fsSL "file://$W/new" ); }
w_inplace() { curl -fsSL "file://$W/new" -o "$1" && chmod 755 "$1"; }

echo "# a running launcher survives replace_by_rename"
run_swap w_fixed
survived && ok_t "the running bash finishes its OLD tail, exit 0, new inode" \
         || bad_t "the running bash finishes its OLD tail, exit 0, new inode" "wrc=$WRC rc=$RC out=[$OUT] err=[$ERR] inode $INODE0 -> $INODE1"
cmp -s "$DEST" "$W/new" && ok_t "the destination now carries the new bytes" \
                        || bad_t "the destination now carries the new bytes" "differs from the fetched file"
[[ "$(stat -c %a "$DEST")" == 755 ]] && ok_t "the destination is 0755" \
                                     || bad_t "the destination is 0755" "mode $(stat -c %a "$DEST")"
left="$(find "$W/bin" -mindepth 1 ! -name 5dive-agent-start)"
[[ -z "$left" ]] && ok_t "no temp file is left beside it" || bad_t "no temp file is left beside it" "$left"

echo "# the temp is written BESIDE the destination (same filesystem, so mv is a rename)"
record_o() { printf '%s\n' "$2" > "$W/o_arg"; cp "$W/new" "$2"; }
mkdir -p "$W/bin"; ( replace_by_rename "$DEST" record_o )
[[ "$(dirname "$(cat "$W/o_arg" 2>/dev/null)")" == "$W/bin" ]] \
  && ok_t "the fetch writes to a temp in the destination's directory" \
  || bad_t "the fetch writes to a temp in the destination's directory" "wrote to $(cat "$W/o_arg" 2>/dev/null)"

echo "# a failed fetch dies and leaves the installed file alone"
cp "$W/old" "$DEST"; i0=$(stat -c %i "$DEST")
( replace_by_rename "$DEST" curl -fsSL "file://$W/absent" ) 2> "$W/ferr"; frc=$?
[[ $frc -ne 0 ]] && grep -q 'error: failed to download 5dive-agent-start' "$W/ferr" \
  && ok_t "the helper dies, naming the file" || bad_t "the helper dies, naming the file" "rc=$frc: $(cat "$W/ferr")"
cmp -s "$DEST" "$W/old" && [[ "$(stat -c %i "$DEST")" == "$i0" ]] \
  && ok_t "the installed file is untouched" || bad_t "the installed file is untouched" "bytes or inode changed"
left="$(find "$W/bin" -mindepth 1 ! -name 5dive-agent-start)"
[[ -z "$left" ]] && ok_t "the failed temp is removed" || bad_t "the failed temp is removed" "$left"

echo "# MUTANT: the pre-fix write (curl -o in place) must go red on the same detector"
run_swap w_inplace
if survived; then
  bad_t "MUTANT in-place write is red" "the detector passed an in-place write; it cannot see the defect"
else
  ok_t "MUTANT in-place write is red (out=[$OUT] inode $INODE0 -> $INODE1)"
fi
[[ "$ERR" == *"\$'\\200\\224': command not found"* ]] \
  && ok_t "MUTANT reproduces the seat's error: \$'\\200\\224': command not found" \
  || bad_t "MUTANT reproduces the seat's error" "err=[$ERR]"

echo "# MUTANT: the helper with its rename turned back into an in-place copy"
mut="$(declare -f replace_by_rename \
       | sed -e 's/^replace_by_rename ()/replace_by_rename_mut ()/' \
             -e 's/mv -f "\$_tmp" "\$_dest"/cat "$_tmp" > "$_dest"; rm -f "$_tmp"/')"
[[ "$mut" == *'cat "$_tmp" > "$_dest"'* ]] && ok_t "MUTANT applied (mv replaced by an in-place copy)" \
                                          || bad_t "MUTANT applied" "the sed did not match the shipped mv line"
eval "$mut"
w_mut() { ( replace_by_rename_mut "$1" curl -fsSL "file://$W/new" ); }
run_swap w_mut
if survived; then
  bad_t "MUTANT helper is red" "the detector passed an in-place helper"
else
  ok_t "MUTANT helper is red (out=[$OUT] inode $INODE0 -> $INODE1)"
fi

echo "# LIVE: a running seat executes the file install.sh writes, under bash"
# The fix keys on a box fact: the unit's main process is `bash <launcher>`, read
# by offset, at the path install.sh installs to. Read it off this host, not a fixture.
bin_dir="$(sed -n 's/^BIN_DIR="\(.*\)"$/\1/p' install.sh)"
live_probe() {  # prints skip:<why> | cmd:<unit> <cmdline>
  local sc="${SYSTEMCTL:-systemctl}" u pid
  command -v "$sc" >/dev/null 2>&1 || { echo "skip:no $sc on this host"; return; }
  for u in $("$sc" list-units --type=service --state=running --no-legend --plain '5dive-agent@*' 2>/dev/null | awk '{print $1}'); do
    pid="$("$sc" show "$u" -p MainPID --value 2>/dev/null)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || continue
    echo "cmd:$u $(tr '\0' ' ' < "/proc/$pid/cmdline")"; return
  done
  echo "skip:no running 5dive-agent@ unit on this host"
}
live="$(live_probe)"
case "$live" in
  skip:*) echo "skip - ${live#skip:} (CI has none; the arm grades a real box)" ;;
  cmd:*)
    if [[ "${live#cmd:}" =~ ^[^\ ]+\ (/usr)?(/bin/)?bash\ ${bin_dir}/5dive-agent-start\  ]]; then
      ok_t "live ${live#cmd:}"
    else
      bad_t "live seat runs bash ${bin_dir}/5dive-agent-start" "${live#cmd:}"
    fi ;;
esac
echo "# CONTROL: the live arm skips, never fails, on a host with no units"
[[ "$(SYSTEMCTL="$W/absent-systemctl" live_probe)" == skip:* ]] \
  && ok_t "no systemctl -> skip" || bad_t "no systemctl -> skip" "$(SYSTEMCTL="$W/absent-systemctl" live_probe)"
[[ "$(SYSTEMCTL=true live_probe)" == skip:* ]] \
  && ok_t "no running unit -> skip" || bad_t "no running unit -> skip" "$(SYSTEMCTL=true live_probe)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
