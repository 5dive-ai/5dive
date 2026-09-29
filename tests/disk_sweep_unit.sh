#!/usr/bin/env bash
# DIVE-5190 — `5dive disk sweep|alarm|tick`: the SAFE box-disk sweep and the
# once-per-episode low-disk alarm (src/cmd_disk.sh).
#
# The sweep DELETES, so every guard is graded twice: the arm on the real code,
# and a MUTATION arm that sources a copy with that guard removed and must see the
# same case go wrong. A delete path whose guards pass with the guard gone is green
# by construction (community/wiki/a-scoped-reclaim-behind-an-unscoped-alarm-can-
# only-offer-spend.md). Holders are REAL processes read through the real /proc:
# an open fd, a cwd inside a scoped_dir, and a memory map with the fd closed
# (how Chrome holds its shared-memory files).
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
HOLDERS=()
trap 'rc=$?; for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; done; chmod -R u+rwX "${TMP:-}" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/disk-sweep-unit.XXXXXX)"
ME="$(id -un)"
export FIVEDIVE_DISK_TMP_ROOT="$TMP/tmp"
export FIVEDIVE_DISK_SWEEP_LOG="$TMP/log/disk-sweep.log"
export FIVEDIVE_DISK_USERS="$ME:$TMP/home"
export STATE_DIR="$TMP/state"
mkdir -p "$FIVEDIVE_DISK_TMP_ROOT" "$TMP/home" "$STATE_DIR"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh; do source "$SRC/$f"; done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-assertion: $2}"; fi; }

T="$FIVEDIVE_DISK_TMP_ROOT"
old() { touch -h -d '3 hours ago' "$@"; }

# plant — a fresh fixture: every case the sweep must decide, plus real holders.
plant() {
  local p; for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; done; HOLDERS=()
  rm -rf "$T" "$TMP/home"; mkdir -p "$T" "$TMP/home"
  head -c 65536 /dev/zero >"$T/.com.google.Chrome.DEAD01"; old "$T/.com.google.Chrome.DEAD01"
  head -c 65536 /dev/zero >"$T/.org.chromium.Chromium.DEAD02"; old "$T/.org.chromium.Chromium.DEAD02"
  mkdir -p "$T/scoped_dirDEAD03/sub"; echo x >"$T/scoped_dirDEAD03/sub/f"; old "$T/scoped_dirDEAD03/sub/f" "$T/scoped_dirDEAD03/sub" "$T/scoped_dirDEAD03"
  echo held >"$T/.com.google.Chrome.HELDFD"; old "$T/.com.google.Chrome.HELDFD"
  ( exec 3<"$T/.com.google.Chrome.HELDFD"; exec sleep 300 ) & HOLDERS+=($!)
  head -c 8192 /dev/zero >"$T/.com.google.Chrome.HELDMAP"; old "$T/.com.google.Chrome.HELDMAP"
  # A raw libc mmap, then close(fd): Python's own mmap module dup()s the fd and
  # would make this a second fd holder, grading nothing about the maps scan.
  python3 -c 'import ctypes,os,sys,time
libc=ctypes.CDLL(None); libc.mmap.restype=ctypes.c_void_p
libc.mmap.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_long]
fd=os.open(sys.argv[1],os.O_RDWR); p=libc.mmap(None,8192,3,1,fd,0); os.close(fd)
assert p not in (None, ctypes.c_void_p(-1).value); time.sleep(300)' "$T/.com.google.Chrome.HELDMAP" & HOLDERS+=($!)
  mkdir -p "$T/scoped_dirHELDCWD"; old "$T/scoped_dirHELDCWD"
  ( cd "$T/scoped_dirHELDCWD" && exec sleep 300 ) & HOLDERS+=($!)
  echo young >"$T/.com.google.Chrome.YOUNG"
  mkdir -p "$T/scoped_dirYOUNGINSIDE"; echo y >"$T/scoped_dirYOUNGINSIDE/new"; old "$T/scoped_dirYOUNGINSIDE"
  echo keep >"$T/notchrome.txt"; old "$T/notchrome.txt"
  echo keep >"$T/.com.google.Chromium-lookalike"; old "$T/.com.google.Chromium-lookalike"
  mkdir -p "$TMP/home/victim"; echo precious >"$TMP/home/victim/data"
  ln -s "$TMP/home/victim" "$T/scoped_dirSYMLINK"; old "$T/scoped_dirSYMLINK"
  mkdir -p "$TMP/home/project" "$TMP/home/.npm/_cacache/content" "$TMP/home/.npm/_npx"
  echo precious >"$TMP/home/project/important.txt"; old "$TMP/home/project/important.txt"
  head -c 65536 /dev/zero >"$TMP/home/.npm/_cacache/content/blob"
  echo npx >"$TMP/home/.npm/_npx/keep"
  # The npm the sweep finds is the user's nvm one; this stub is it. It records
  # its argv and empties the cache the way `npm cache clean --force` does.
  mkdir -p "$TMP/home/.nvm/versions/node/v20.0.0/bin"
  cat >"$TMP/home/.nvm/versions/node/v20.0.0/bin/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >>"$HOME/npm-calls"
[[ "$*" == "cache clean --force" ]] && rm -rf "$HOME/.npm/_cacache"
exit 0
NPM
  chmod +x "$TMP/home/.nvm/versions/node/v20.0.0/bin/npm"
  # Chrome's real modes (mkstemp 0600, mkdtemp 0700). An unprivileged run keeps a
  # group/other-readable entry as UNKNOWN while other uids' processes are unreadable.
  chmod 600 "$T"/.com.google.Chrome.* "$T"/.org.chromium.Chromium.*
  chmod 700 "$T"/scoped_dirDEAD03 "$T"/scoped_dirHELDCWD "$T"/scoped_dirYOUNGINSIDE
  old "$T"/.com.google.Chrome.[DH]* "$T"/.org.chromium.Chromium.* "$T"/scoped_dirDEAD03 "$T"/scoped_dirHELDCWD "$T"/scoped_dirYOUNGINSIDE
  sleep 0.5   # let the holders open/map/cd before the scan
  mkproc
}

# mkproc [<blind euid>] — the proc tree the sweep scans: the REAL /proc entries of
# this harness's holders, plus (optionally) one planted pid whose fd dir and maps
# are unreadable, running as <blind euid>. That is what an unprivileged scan sees
# of another uid's process, made deterministic.
export FIVEDIVE_DISK_PROC_ROOT="$TMP/proc"
mkproc() {
  local p; chmod -R u+rwX "$TMP/proc" 2>/dev/null; rm -rf "$TMP/proc"; mkdir -p "$TMP/proc"
  for p in "${HOLDERS[@]}" "$$"; do ln -s "/proc/$p" "$TMP/proc/$p"; done
  if [[ -n "${1:-}" ]]; then
    mkdir -p "$TMP/proc/999999/fd"; : >"$TMP/proc/999999/maps"
    printf 'Name:\tchrome\nUid:\t%s\t%s\t%s\t%s\n' "$1" "$1" "$1" "$1" >"$TMP/proc/999999/status"
    chmod 000 "$TMP/proc/999999/fd" "$TMP/proc/999999/maps"
  fi
}

mutant() {
  sed -E "$1" "$SRC/cmd_disk.sh" >"$TMP/mut.sh"
  if cmp -s "$SRC/cmd_disk.sh" "$TMP/mut.sh"; then bad_t "mutation '$1' matched nothing — the guard it targets moved"; return 1; fi
  if ! bash -n "$TMP/mut.sh" 2>/dev/null; then bad_t "mutation '$1' broke the syntax — it would 'pass' by deleting nothing"; return 1; fi
}
run_sweep() { ( source "${1:-$SRC/cmd_disk.sh}"; cmd_disk_sweep "${@:2}" ) >"$TMP/out" 2>&1; }

echo "== sweep on the real code"
plant
run_sweep "$SRC/cmd_disk.sh"
check "old unheld Chrome temp file is removed"            '[[ ! -e $T/.com.google.Chrome.DEAD01 ]]'
check "old unheld Chromium temp file is removed"          '[[ ! -e $T/.org.chromium.Chromium.DEAD02 ]]'
check "old unheld scoped_dir is removed"                  '[[ ! -e $T/scoped_dirDEAD03 ]]'
check "old file HELD OPEN by a process is kept"           '[[ -e $T/.com.google.Chrome.HELDFD ]]'
check "old file held only by a MEMORY MAP is kept"        '[[ -e $T/.com.google.Chrome.HELDMAP ]]'
check "old scoped_dir that is a process CWD is kept"      '[[ -e $T/scoped_dirHELDCWD ]]'
check "young Chrome temp file is kept"                    '[[ -e $T/.com.google.Chrome.YOUNG ]]'
check "scoped_dir with a young file inside is kept"       '[[ -e $T/scoped_dirYOUNGINSIDE/new ]]'
check "non-allowlisted /tmp file is never touched"        '[[ -e $T/notchrome.txt && -e $T/.com.google.Chromium-lookalike ]]'
check "a scoped_dir SYMLINK is not followed (target kept)" '[[ -e $TMP/home/victim/data && -L $T/scoped_dirSYMLINK ]]'
check "a planted file under the user's home survives"     '[[ -e $TMP/home/project/important.txt ]]'
check "npm cache is cleaned through npm itself"           'grep -qx "npm cache clean --force" "$TMP/home/npm-calls" 2>/dev/null && [[ ! -e $TMP/home/.npm/_cacache ]]'
check "npm's _npx dir (not the download cache) survives"  '[[ -e $TMP/home/.npm/_npx/keep ]]'
check "the log names what it freed, per class"            'grep -qE "class=chrome-tmp freed_kb=[1-9][0-9]* removed=3 kept_live=3 kept_young=2 kept_unknown=0 failed=0" "$FIVEDIVE_DISK_SWEEP_LOG" && grep -qE "class=npm freed_kb=[1-9]" "$FIVEDIVE_DISK_SWEEP_LOG" && grep -q "disk-sweep total freed_kb=" "$FIVEDIVE_DISK_SWEEP_LOG"' "$(cat "$FIVEDIVE_DISK_SWEEP_LOG" 2>/dev/null)"

echo "== blindness: a process the scan cannot read keeps what it could be holding"
plant; mkproc "$(id -u)"; : >"$FIVEDIVE_DISK_SWEEP_LOG"
run_sweep "$SRC/cmd_disk.sh"
check "an unreadable process of the OWNER's uid -> old entries kept as UNKNOWN" '[[ -e $T/.com.google.Chrome.DEAD01 && -e $T/scoped_dirDEAD03 ]] && grep -qE "kept_unknown=[1-9]" "$FIVEDIVE_DISK_SWEEP_LOG"' "$(cat "$FIVEDIVE_DISK_SWEEP_LOG")"
plant; mkproc 4242; : >"$FIVEDIVE_DISK_SWEEP_LOG"
echo shared >"$T/.com.google.Chrome.WORLDREAD"; chmod 644 "$T/.com.google.Chrome.WORLDREAD"; old "$T/.com.google.Chrome.WORLDREAD"
run_sweep "$SRC/cmd_disk.sh"
check "another uid unreadable: a 0600 entry is still swept"              '[[ ! -e $T/.com.google.Chrome.DEAD01 ]]'
check "another uid unreadable: a world-readable entry is kept (UNKNOWN)" '[[ -e $T/.com.google.Chrome.WORLDREAD ]] && grep -q "kept_unknown=1 " "$FIVEDIVE_DISK_SWEEP_LOG"' "$(cat "$FIVEDIVE_DISK_SWEEP_LOG")"
if mutant 's/if \[\[ -n "\$\{_DISK_BLIND\[\$owner\]:-\}" \]\] \|\|/if false ||/'; then
  plant; mkproc "$(id -u)"; run_sweep "$TMP/mut.sh"
  check "MUTANT no-blind-owner-check deletes under blindness (guard is load-bearing)" '[[ ! -e $T/.com.google.Chrome.DEAD01 ]]'
fi

echo "== dry run deletes nothing"
plant; : >"$FIVEDIVE_DISK_SWEEP_LOG"
run_sweep "$SRC/cmd_disk.sh" --dry-run
check "--dry-run removes no Chrome entry"                 '[[ -e $T/.com.google.Chrome.DEAD01 && -e $T/scoped_dirDEAD03 ]]'
check "--dry-run runs no npm"                             '[[ ! -e $TMP/home/npm-calls && -e $TMP/home/.npm/_cacache/content/blob ]]'
check "--dry-run still reports what it would free"        'grep -qE "class=chrome-tmp freed_kb=[1-9][0-9]* removed=3 .*dry_run=1" "$FIVEDIVE_DISK_SWEEP_LOG"'

echo "== mutation arms: each guard removed must let its case go wrong"
if mutant '/if _disk_held "\$e"; then live=/d'; then
  plant; run_sweep "$TMP/mut.sh"
  check "MUTANT no-holder-check deletes the held file (guard is load-bearing)" '[[ ! -e $T/.com.google.Chrome.HELDFD ]]'
fi
if mutant '/grep -hF -- " \$root\/" "\$DISK_PROC"/,/awk -v r=/d'; then
  plant; run_sweep "$TMP/mut.sh"
  check "MUTANT no-maps-scan deletes the mmapped file (maps scan is load-bearing)" '[[ ! -e $T/.com.google.Chrome.HELDMAP && -e $T/.com.google.Chrome.HELDFD ]]'
fi
if mutant '/-mmin "-\$DISK_CHROME_MIN_AGE"/,+2d'; then
  plant; run_sweep "$TMP/mut.sh"
  check "MUTANT no-age-check deletes the young file (age guard is load-bearing)" '[[ ! -e $T/.com.google.Chrome.YOUNG ]]'
fi
if mutant 's/\\\( -type f -o -type d \\\) //'; then
  plant; run_sweep "$TMP/mut.sh"
  check "MUTANT no-type-filter follows the symlink (type filter is load-bearing)" '[[ ! -e $TMP/home/victim/data || ! -L $T/scoped_dirSYMLINK ]]'
fi

echo "== alarm: once per low episode, re-armed on recovery, retried if undelivered"
for p in "${HOLDERS[@]}"; do kill "$p" 2>/dev/null; done; HOLDERS=()
rm -f "$STATE_DIR/disk.json"
alarm() {
  ( source "$SRC/cmd_disk.sh"
    _disk_alarm_deliver() { echo "SENT $1" >>"$TMP/sent"; return "${DELIVER_RC:-0}"; }
    cmd_disk_alarm ) >>"$TMP/alarm.out" 2>&1
}
sent() { grep -c '^SENT' "$TMP/sent" 2>/dev/null || echo 0; }
: >"$TMP/sent"
FIVEDIVE_DISK_FAKE_DF="95 5"  alarm
FIVEDIVE_DISK_FAKE_DF="96 4"  alarm
check "under 10% free the owner is told exactly once"      '[[ $(sent) == 1 ]]' "sent=$(sent)"
check "the message names the free percentage, plainly"     'grep -q "SENT Your 5dive box .* 5% free" "$TMP/sent"'
FIVEDIVE_DISK_FAKE_DF="88 12" alarm
check "between the alarm and re-arm lines stays quiet"      '[[ $(sent) == 1 ]]'
FIVEDIVE_DISK_FAKE_DF="50 50" alarm
FIVEDIVE_DISK_FAKE_DF="95 5"  alarm
check "after recovery a new low episode alarms again"      '[[ $(sent) == 2 ]]' "sent=$(sent)"
rm -f "$STATE_DIR/disk.json"; : >"$TMP/sent"
FIVEDIVE_DISK_FAKE_DF="95 5" DELIVER_RC=1 alarm
FIVEDIVE_DISK_FAKE_DF="95 5" DELIVER_RC=0 alarm
FIVEDIVE_DISK_FAKE_DF="95 5" DELIVER_RC=0 alarm
check "an undelivered alarm is retried, then told once"    '[[ $(sent) == 2 ]] && grep -q UNDELIVERED "$TMP/alarm.out"' "sent=$(sent)"

echo "== tick: sweeps daily, hourly under pressure"
rm -f "$STATE_DIR/disk.json"; : >"$FIVEDIVE_DISK_SWEEP_LOG"
tick() { ( source "$SRC/cmd_disk.sh"; _disk_alarm_deliver() { return 0; }; cmd_disk_tick ) >/dev/null 2>&1; }
sweeps() { grep -c 'disk-sweep total' "$FIVEDIVE_DISK_SWEEP_LOG" 2>/dev/null || echo 0; }
FIVEDIVE_DISK_FAKE_DF="50 50" tick; FIVEDIVE_DISK_FAKE_DF="50 50" tick
check "with room, two ticks in a row sweep once"            '[[ $(sweeps) == 1 ]]' "sweeps=$(sweeps)"
jq '.last_sweep_at -= 7200' "$STATE_DIR/disk.json" >"$STATE_DIR/d" && mv "$STATE_DIR/d" "$STATE_DIR/disk.json"
FIVEDIVE_DISK_FAKE_DF="95 5" tick
check "under the alarm line a tick sweeps again after 1h"  '[[ $(sweeps) == 2 ]]' "sweeps=$(sweeps)"

echo "== wiring"
check "build.sh bundles src/cmd_disk.sh"                   'grep -qx "  src/cmd_disk.sh" build.sh'
check "main dispatches the disk verb"                      'grep -qE "^    disk\)" src/main.sh && grep -q "cmd_disk \"\$@\"" src/main.sh'
check "install.sh writes the hourly cron, gated on the bundle" 'grep -q "grep -q '"'"'cmd_disk_tick'"'"' \"\$BIN_DIR/5dive\"" install.sh && grep -q "root /usr/local/bin/5dive disk tick" install.sh'

echo
echo "disk_sweep_unit: $PASS passed, $FAIL failed ($((PASS + FAIL)) arms)"
(( FAIL == 0 ))
