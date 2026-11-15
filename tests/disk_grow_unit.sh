#!/usr/bin/env bash
# DIVE-8491 — `5dive disk grow`: after the partner disk trigger moves a box to a
# bigger server, grow / into the new disk (src/cmd_disk.sh). The cloned cx23
# boxes have cloud-init disabled, so nothing else does it.
#
# The disk is a fake /sys/class/block laid out like a real Hetzner box (sda14 and
# sda15 at the front, sda1 = root at the end, sector numbers read off one), and
# growpart / resize2fs / dumpe2fs are stubs that record their argv. Each guard
# that stops a write has a MUTATION arm: a copy of the code with that guard
# removed must make the same fixture call growpart, or the guard is untested.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
# shellcheck disable=SC2154  # rc is assigned inside the trap string
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692
cd "$(dirname "$0")/.." || exit 1
SRC=src

TMP="$(mktemp -d /tmp/disk-grow-unit.XXXXXX)"
export FIVEDIVE_DISK_SWEEP_LOG="$TMP/log/disk-sweep.log"
export STATE_DIR="$TMP/state"
export FIVEDIVE_DISK_SYSFS="$TMP/sys/class/block"
export FIVEDIVE_DISK_ROOT_DEV=/dev/sda1
export FIVEDIVE_DISK_ROOT_FSTYPE=ext4
export FIVEDIVE_DISK_EUID=0
export SELF_UPDATE_PROVISIONING="$TMP/provisioning.env"
export CALLS="$TMP/calls"
mkdir -p "$STATE_DIR" "$TMP/bin"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh; do source "$SRC/$f"; done
set +e

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
check() { if eval "$2"; then ok_t "$1"; else bad_t "$1" "${3:-assertion: $2}"; fi; }

GIB=$(( 1024 * 1024 * 2 ))   # sectors
DEV="$TMP/sys/devices/block"

# disk <disk_gib> <root_part_gib> <fs_gib> [extra partition after root: 1]
# Front partitions and root's start are this host's real Hetzner numbers.
disk() {
  rm -rf "$TMP/sys" "$CALLS"; mkdir -p "$FIVEDIVE_DISK_SYSFS" "$DEV/sda"
  echo $(( $1 * GIB )) >"$DEV/sda/size"
  mkp() { mkdir -p "$DEV/sda/$1"; echo "$2" >"$DEV/sda/$1/partition"; echo "$3" >"$DEV/sda/$1/start"; echo "$4" >"$DEV/sda/$1/size"
          ln -s "../../devices/block/sda/$1" "$FIVEDIVE_DISK_SYSFS/$1"; }
  ln -s ../../devices/block/sda "$FIVEDIVE_DISK_SYSFS/sda"
  mkp sda14 14 2048 2048
  mkp sda15 15 4096 524288
  mkp sda1 1 528384 $(( $2 * GIB - 528384 ))
  [[ "${4:-}" == 1 ]] && mkp sda2 2 $(( $2 * GIB )) $GIB
  echo $(( $3 * GIB / 8 )) >"$TMP/fs_blocks"   # 4 KiB blocks
  : >"$CALLS"
}

# Stubs. growpart grows the fake partition to the disk's end, like the real one.
cat >"$TMP/bin/growpart" <<'S'
#!/usr/bin/env bash
echo "growpart $*" >>"$CALLS"
[[ -n "${GROWPART_FAIL:-}" ]] && exit 1
d="$FIVEDIVE_DISK_SYSFS/$(basename "$1")"; p="$FIVEDIVE_DISK_SYSFS/$(basename "$1")$2"
echo $(( $(cat "$d/size") - $(cat "$p/start") )) >"$p/size"
S
cat >"$TMP/bin/resize2fs" <<'S'
#!/usr/bin/env bash
echo "resize2fs $*" >>"$CALLS"
S
cat >"$TMP/bin/dumpe2fs" <<'S'
#!/usr/bin/env bash
[[ "$1 $2" == "-h /dev/sda1" ]] || exit 1
printf 'dumpe2fs 1.47.0 (5-Feb-2023)\nFilesystem volume name:   cloudimg-rootfs\nBlock count:              %s\nBlock size:               4096\n' "$(cat "$(dirname "$CALLS")/fs_blocks")"
S
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

CODE="$SRC/cmd_disk.sh"
# shellcheck disable=SC1090
grow() { ( source "$CODE"; cmd_disk_grow "$@" ) >>"$TMP/out" 2>&1; }
calls() { tr '\n' ';' <"$CALLS"; }
lastlog() { grep 'disk-grow' "$FIVEDIVE_DISK_SWEEP_LOG" 2>/dev/null | tail -1; }
: >"$SELF_UPDATE_PROVISIONING"

echo "== frank-lake: moved to an 80 GB disk, root still 40 GB"
disk 80 40 40; grow
check "growpart runs on the root partition's disk and number"  '[[ "$(calls)" == "growpart /dev/sda 1;resize2fs /dev/sda1;" ]]' "calls=$(calls)"
check "the log names both steps"                               'grep -q "grew-partition part=sda1 disk=sda" "$FIVEDIVE_DISK_SWEEP_LOG" && grep -q "disk-grow resized part=sda1" "$FIVEDIVE_DISK_SWEEP_LOG"' "$(lastlog)"

echo "== nothing to grow: the next hour does nothing"
disk 80 80 80; grow
check "a full-size partition and filesystem: no growpart, no resize2fs" '[[ -z "$(calls)" ]]' "calls=$(calls)"
disk 40 40 40; grow
check "an unmoved 40 GB box: nothing runs"                     '[[ -z "$(calls)" ]]' "calls=$(calls)"

echo "== half done: growpart ran earlier, resize2fs did not"
disk 80 80 40; grow
check "the filesystem alone is grown"                          '[[ "$(calls)" == "resize2fs /dev/sda1;" ]]' "calls=$(calls)"

echo "== guards: each one stops the write"
disk 80 40 40 1; grow
check "a partition after root: skipped"                        '[[ -z "$(calls)" ]] && grep -q "skipped=root-not-last part=sda1 after=sda2" <<<"$(lastlog)"' "calls=$(calls) log=$(lastlog)"
disk 80 40 40; rm -f "$SELF_UPDATE_PROVISIONING"; grow; : >"$SELF_UPDATE_PROVISIONING"
check "a self-hosted box (no provisioning.env): skipped"       '[[ -z "$(calls)" ]] && grep -q "skipped=self-hosted" <<<"$(lastlog)"' "calls=$(calls) log=$(lastlog)"
disk 80 40 40; FIVEDIVE_DISK_EUID=1000 grow
check "not root: skipped"                                      '[[ -z "$(calls)" ]] && grep -q "skipped=not-root" <<<"$(lastlog)"' "calls=$(calls)"
disk 80 40 40; FIVEDIVE_DISK_ROOT_FSTYPE=xfs grow
check "not ext4: skipped"                                      '[[ -z "$(calls)" ]] && grep -q "skipped=fstype:xfs" <<<"$(lastlog)"' "calls=$(calls)"
disk 80 40 40; FIVEDIVE_DISK_ROOT_DEV=/dev/mapper/vg-root grow
check "root on LVM (not a plain partition): skipped"           '[[ -z "$(calls)" ]] && grep -q "skipped=not-a-partition" <<<"$(lastlog)"' "calls=$(calls)"
disk 80 40 40; GROWPART_FAIL=1 grow
check "growpart fails: resize2fs does not run, FAILED logged"  '[[ "$(calls)" == "growpart /dev/sda 1;" ]] && grep -q "FAILED step=growpart" <<<"$(lastlog)"' "calls=$(calls)"
disk 80 40 40; grow --dry-run
check "--dry-run writes nothing and says what it would do"     '[[ -z "$(calls)" ]] && grep -q "would-grow part=sda1 disk=sda slack_mb=40960 dry_run=1" <<<"$(lastlog)"' "calls=$(calls) log=$(lastlog)"

echo "== the hourly tick runs it"
# shellcheck disable=SC1090
tick() { ( source "$CODE"; _disk_alarm_deliver() { return 0; }; cmd_disk_sweep() { :; }; cmd_disk_tick ) >>"$TMP/out" 2>&1; }
disk 80 40 40; FIVEDIVE_DISK_FAKE_DF="50 50" tick
check "disk tick grows a moved box"                            '[[ "$(calls)" == "growpart /dev/sda 1;resize2fs /dev/sda1;" ]]' "calls=$(calls)"
disk 80 40 40; FIVEDIVE_DISK_GROW=0 FIVEDIVE_DISK_FAKE_DF="50 50" tick
check "FIVEDIVE_DISK_GROW=0 keeps the tick off the disk"       '[[ -z "$(calls)" ]]' "calls=$(calls)"
check "disk --help names the verb"                             'grep -q "5dive disk grow" <<<"$( source "$CODE"; cmd_disk --help )"'

echo "== mutation arms: each guard removed, the same fixture must write"
mutant() { # <name> <sed expr> <env assignment or -> <fixture...>
  local name="$1" expr="$2" env="$3"; shift 3
  CODE="$TMP/mut-$name.sh"; sed "$expr" "$SRC/cmd_disk.sh" >"$CODE"
  if cmp -s "$CODE" "$SRC/cmd_disk.sh"; then bad_t "mutant $name applies" "sed matched nothing"; CODE="$SRC/cmd_disk.sh"; return; fi
  "$@"
  if [[ "$env" == noprov ]]; then rm -f "$SELF_UPDATE_PROVISIONING"; grow; : >"$SELF_UPDATE_PROVISIONING"
  elif [[ "$env" == nonroot ]]; then FIVEDIVE_DISK_EUID=1000 grow
  else grow; fi
  check "mutant $name: the guard's fixture now calls growpart (so the arm above grades it)" '[[ "$(calls)" == growpart* ]]' "calls=$(calls)"
  CODE="$SRC/cmd_disk.sh"
}
mutant root-last  's/(( pstart > start ))/(( 0 ))/'                                   -       disk 80 40 40 1
mutant managed    's/if ! _disk_grow_managed; then/if false; then/'                   noprov  disk 80 40 40
mutant min-slack  's/if (( slack >= DISK_GROW_MIN_SECTORS )); then/if true; then/'    -       disk 80 80 80
mutant root-only  's/if ! _disk_is_root; then _disk_log "disk-grow/if false; then _disk_log "disk-grow/' nonroot disk 80 40 40

echo
echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
