#!/usr/bin/env bash
# DIVE-7451: a self-hosted box hears voice notes on its own whisper. 2 GB+ of
# memory and ~3 GB free disk: voice turns on by itself (init, and once on the
# next self-update). Below that: init asks once. A box 5dive runs is never
# touched, and any recorded choice (an owner's No, a removal, or the one
# automatic install) is final for the automatic pass.
#
# Hermetic: the DIVE-7451 block of src/cmd_plugin.sh is extracted verbatim and
# src/cmd_init.sh is sourced as shipped. The CLI the block calls, systemd-run
# and systemctl are stubs that log; no plugin, unit or file on this box moves.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${WORK:-}"; echo "HARNESS-RC=$rc"' EXIT
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok_t(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t(){ FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

block="$(sed -n '/^# >>> DIVE-7451 voice default/,/^# <<< DIVE-7451 voice default/p' src/cmd_plugin.sh)"
grep -q '_va_decide()' <<<"$block" || { bad_t "DIVE-7451 block not found in src/cmd_plugin.sh"; echo "$PASS passed, $FAIL failed"; exit 1; }
WORK="$(mktemp -d)"

# box <mem-mb> <disk-mb> [managed:yes|no] [present:yes|no] — a fresh fake box.
box() {
  rm -rf "$WORK/b"; mkdir -p "$WORK/b/state" "$WORK/b/plugins" "$WORK/b/sd"
  printf '{}\n' > "$WORK/b/plugins/installed.json"
  : > "$WORK/b/calls"
  printf '#!/bin/sh\necho "cli $*" >> %s/b/calls\n' "$WORK" > "$WORK/b/cli"; chmod +x "$WORK/b/cli"
  B_MEM="$1"; B_DISK="$2"
  [[ "${3:-no}" == yes ]] && : > "$WORK/b/provisioning.env"
  [[ "${4:-no}" == yes ]] && printf '{"voice@5dive-voice":{"plugin":"voice"}}\n' > "$WORK/b/plugins/installed.json"
  return 0
}
# run '<shell code>' [stdin] — the block (and init) in a subshell on the fake box.
run() {
  local code="$1" input="${2:-}"
  printf '%s' "$input" | (
    export STATE_DIR="$WORK/b/state" VOICE_AUTO_STATE="$WORK/b/state/voice-auto"
    export SELF_UPDATE_PROVISIONING="$WORK/b/provisioning.env" FIVEDIVE_TRANSCRIBE_BIN="$WORK/b/none"
    export FIVEDIVE_VOICE_AUTO_CLI="$WORK/b/cli" VA_SYSTEMD_DIR="$WORK/b/sd"
    export FIVEDIVE_VOICE_AUTO_MEM_MB="$B_MEM" FIVEDIVE_VOICE_AUTO_DISK_MB="$B_DISK"
    JSON_MODE=0; E_USAGE=2; E_GENERIC=1; TERM=dumb
    fail(){ printf 'FAILED: %s\n' "${2:-}"; exit "${1:-1}"; }
    ok(){ printf 'OK — %s\n' "$1"; }; warn(){ :; }
    _plugin_installed_json(){ echo "$WORK/b/plugins/installed.json"; }
    systemd_run_log="$WORK/b/calls"
    systemd-run(){ echo "systemd-run $*" >> "$systemd_run_log"; }
    systemctl(){ :; }
    eval "$block"
    . src/cmd_init.sh
    _init_stdin_tty(){ [[ "${TTY:-yes}" == yes ]]; }
    eval "$code"
  ) 2>&1
}
st(){ cat "$WORK/b/state/voice-auto" 2>/dev/null | grep -v '^at=' | tr '\n' ' '; }
calls(){ cat "$WORK/b/calls"; }

# --- the decision, pure -------------------------------------------------------
dec(){ run "_va_decide $*"; }
want=(
  "1 0 '' 8000 50000|managed"  "0 1 '' 8000 50000|present"  "0 0 off 8000 50000|chosen"
  "0 0 on 8000 50000|chosen"   "0 0 '' 1024 50000|ask"      "0 0 '' 1799 50000|ask"
  "0 0 '' 1800 50000|install"  "0 0 '' 3800 3071|low-disk"  "0 0 '' 3800 3072|install"
  "0 0 '' '' 50000|ask"        "1 1 off 1024 0|managed"
)
bad=0
for w in "${want[@]}"; do
  got="$(box 1 1; dec "${w%|*}")"
  [[ "$got" == "${w#*|}" ]] || { bad=1; bad_t "decide ${w%|*} -> want ${w#*|}" "got: $got"; }
done
(( bad )) || ok_t "decide: ${#want[@]} cases (managed > present > recorded choice > memory > disk; 1800 MiB is the bar, unreadable memory asks)"

# --- memory reading: the cgroup limit wins over the host's MemTotal ------------
box 1 1
printf 'MemTotal:       16384000 kB\n' > "$WORK/mi"; printf '1073741824\n' > "$WORK/cg"
got="$(run 'unset FIVEDIVE_VOICE_AUTO_MEM_MB; VA_MEMINFO='"$WORK/mi"' VA_CGROUP_FILES='"$WORK/cg"' _va_mem_mb')"
[[ "$got" == 1024 ]] && ok_t "memory: a 1 GB container on a 16 GB host reads 1024 MiB" || bad_t "cgroup limit not applied" "$got"
printf 'max\n' > "$WORK/cg"
got="$(run 'unset FIVEDIVE_VOICE_AUTO_MEM_MB; VA_MEMINFO='"$WORK/mi"' VA_CGROUP_FILES='"$WORK/cg"' _va_mem_mb')"
[[ "$got" == 16000 ]] && ok_t "memory: no cgroup limit (max) reads MemTotal" || bad_t "MemTotal not read" "$got"

# --- the automatic pass (what install.sh --upgrade runs) ------------------------
box 4096 20000
out="$(run 'cmd_plugin_auto_voice')"
if grep -qx 'cli plugin add voice --yes' "$WORK/b/calls" \
   && grep -q 'systemd-run --unit=5dive-voice-auto-setup .*plugin setup voice --yes' "$WORK/b/calls" \
   && [[ "$(st)" == "choice=on source=auto " && "$out" == *"heard on this server"* ]]; then
  ok_t "AUTO 4 GB: plugin added now, setup queued in the background unit, recorded on/auto"
else bad_t "auto pass on a big box did not install" "$out | calls: $(calls) | state: $(st)"; fi
: > "$WORK/b/calls"
out="$(run 'cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" && "$out" == *"left as it is"* ]] \
  && ok_t "ONCE: a second pass on a box that got voice once (and lost it) installs nothing" \
  || bad_t "second pass re-installed" "$out | $(calls)"

box 1024 20000
out="$(run 'cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" && -z "$(st)" && "$out" == *"under 2 GB"* && "$out" == *"auto-voice --on"* ]] \
  && ok_t "AUTO 1 GB: nothing installed, nothing recorded, the one command to turn it on is printed" \
  || bad_t "small box auto pass" "$out | $(calls) | $(st)"

box 8000 50000 yes
out="$(run 'cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" && -z "$(st)" && "$out" == *"run by 5dive"* ]] \
  && ok_t "MANAGED: a box 5dive runs is never touched" || bad_t "managed box touched" "$out | $(calls)"

box 8000 50000 no yes
out="$(run 'cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" && "$out" == *"already on"* ]] \
  && ok_t "PRESENT: a box that has the voice plugin is left alone" || bad_t "present box touched" "$out | $(calls)"

box 8000 50000
printf 'x\n' > "$WORK/b/t"; chmod +x "$WORK/b/t"
out="$(run 'FIVEDIVE_TRANSCRIBE_BIN='"$WORK/b/t"' cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" ]] && ok_t "PRESENT: a box with 5dive-transcribe (voice set up by hand) is left alone" || bad_t "hand-set box touched" "$(calls)"

# --- the owner's choice ---------------------------------------------------------
box 8000 50000
run 'cmd_plugin_auto_voice --off' >/dev/null; out="$(run 'cmd_plugin_auto_voice')"
[[ "$(st)" == "choice=off source=owner " && ! -s "$WORK/b/calls" ]] \
  && ok_t "OWNER OFF: --off is recorded as the owner's, and the automatic pass then installs nothing" \
  || bad_t "--off not honoured" "$out | $(calls) | $(st)"
box 8000 50000
run '_va_record off owner' >/dev/null; out="$(run 'cmd_plugin_auto_voice')"
[[ ! -s "$WORK/b/calls" ]] && ok_t "REMOVED: the record plugin remove writes keeps the automatic pass away" || bad_t "removed voice came back" "$(calls)"
rm_fn="$(sed -n '/^cmd_plugin_remove() {/,/^}/p' src/cmd_plugin.sh)"
[[ "$rm_fn" == *'[[ "$plugin" == voice ]] && { _va_record off owner'* ]] \
  && ok_t "REMOVED: plugin remove voice records off/owner (in cmd_plugin_remove)" || bad_t "remove hook missing from cmd_plugin_remove"
box 1024 20000
out="$(run 'cmd_plugin_auto_voice --on')"
grep -qx 'cli plugin add voice --yes' "$WORK/b/calls" && [[ "$(st)" == "choice=on source=owner " ]] \
  && ok_t "OWNER ON: --on installs on a small box and records on/owner" || bad_t "--on" "$out | $(calls) | $(st)"
box 4096 20000
printf '#!/bin/sh\nexit 1\n' > "$WORK/b/cli"
out="$(run 'cmd_plugin_auto_voice')"
[[ -z "$(st)" && "$out" == *"next update tries again"* ]] \
  && ok_t "ADD FAILS: nothing recorded, so the next update tries again" || bad_t "a failed add was recorded" "$out | $(st)"

# --- init -----------------------------------------------------------------------
Q="Turn on voice? (puts a speech model on this server)"
box 4096 20000
out="$(run '_init_voice_step; echo RC:$?')"
[[ "$out" != *"$Q"* && "$out" == *"heard on this server"* && "$out" == *"RC:0"* ]] && grep -qx 'cli plugin add voice --yes' "$WORK/b/calls" \
  && ok_t "INIT 4 GB: not asked, voice turned on, one line says so" || bad_t "init on a big box" "$out | $(calls)"
box 1024 20000
out="$(run '_init_voice_step; echo RC:$?' $'\n')"
[[ "$out" == *"$Q"* && ! -s "$WORK/b/calls" && "$(st)" == "choice=off source=owner " && "$out" == *"auto-voice --on"* ]] \
  && ok_t "INIT 1 GB, Enter: asked once, default Not now, recorded off/owner, prints how to turn it on" \
  || bad_t "init small default" "$out | $(calls) | $(st)"
box 1024 20000
out="$(run '_init_voice_step' $'1\n')"
[[ "$out" == *"$Q"* ]] && grep -qx 'cli plugin add voice --yes' "$WORK/b/calls" && [[ "$(st)" == "choice=on source=owner " ]] \
  && ok_t "INIT 1 GB, Turn on: installed and recorded on/owner" || bad_t "init small yes" "$out | $(calls) | $(st)"
box 1024 20000
out="$(run 'TTY=no _init_voice_step; echo RC:$?' $'1\n')"
[[ "$out" != *"$Q"* && ! -s "$WORK/b/calls" && -z "$(st)" && "$out" == *"RC:0"* ]] \
  && ok_t "INIT 1 GB, no terminal: not asked, nothing installed or recorded" || bad_t "init no tty" "$out | $(calls)"
box 4096 1000
out="$(run '_init_voice_step')"
[[ "$out" == *"3 GB of free disk"* && ! -s "$WORK/b/calls" ]] && ok_t "INIT low disk: says why voice is off and how to turn it on" || bad_t "init low disk" "$out"
box 8000 50000 yes
out="$(run '_init_voice_step')"
[[ -z "$out" && ! -s "$WORK/b/calls" ]] && ok_t "INIT managed box: silent, untouched" || bad_t "init managed" "$out"
grep -q '_init_voice_step$' <(sed -n '/^cmd_init() {/,/^}/p' src/cmd_init.sh) \
  && ok_t "init calls the voice step" || bad_t "cmd_init does not call _init_voice_step"
grep -q '"\$BIN_DIR/5dive" plugin auto-voice' install.sh \
  && ok_t "install.sh --upgrade runs the automatic pass" || bad_t "install.sh does not call plugin auto-voice"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
