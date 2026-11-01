#!/usr/bin/env bash
# DIVE-7451: speech-to-text on a self-hosted box is offered on FIRST USE (the
# first voice note in any channel, a voice-mode tap, the owner asking), never
# installed unasked: not at init, not by self-update. The agent learns to ask
# from the 5dive:voice-offer block install.sh syncs into projects/CLAUDE.md on
# self-hosted boxes; `plugin auto-voice` says whether to ask, runs the yes, waits
# for it, and records a No (and a removal) as the owner's.
#
# Hermetic: the DIVE-7451 block of src/cmd_plugin.sh is extracted verbatim. The
# CLI the block calls, systemd-run and systemctl are stubs that log; no plugin,
# unit or file on this box moves.
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
WORK="$(mktemp -d)"; B_DISK=20000

# box [disk-mb] [managed:yes|no] [hears:yes|no] [registered:yes|no] — a fresh fake box.
box() {
  rm -rf "$WORK/b"; mkdir -p "$WORK/b/state" "$WORK/b/plugins" "$WORK/b/sd"
  printf '{}\n' > "$WORK/b/plugins/installed.json"
  : > "$WORK/b/calls"
  printf '#!/bin/sh\necho "cli $*" >> %s/b/calls\n' "$WORK" > "$WORK/b/cli"; chmod +x "$WORK/b/cli"
  B_DISK="${1:-20000}"
  [[ "${2:-no}" == yes ]] && : > "$WORK/b/provisioning.env"
  [[ "${3:-no}" == yes ]] && { printf '#!/bin/sh\n' > "$WORK/b/transcribe"; chmod +x "$WORK/b/transcribe"; }
  [[ "${4:-no}" == yes ]] && printf '{"voice@5dive-voice":{"plugin":"voice"}}\n' > "$WORK/b/plugins/installed.json"
  return 0
}
# run '<shell code>' — the block in a subshell on the fake box.
run() {
  local code="$1"
  (
    export STATE_DIR="$WORK/b/state" VOICE_AUTO_STATE="$WORK/b/state/voice-auto"
    export SELF_UPDATE_PROVISIONING="$WORK/b/provisioning.env" FIVEDIVE_TRANSCRIBE_BIN="$WORK/b/transcribe"
    export FIVEDIVE_VOICE_AUTO_CLI="$WORK/b/cli" VA_SYSTEMD_DIR="$WORK/b/sd"
    export FIVEDIVE_VOICE_AUTO_DISK_MB="$B_DISK" FIVEDIVE_VOICE_AUTO_POLL_SECS=0
    JSON_MODE=0; E_USAGE=2; E_GENERIC=1; E_TIMEOUT=11; TERM=dumb
    fail(){ printf 'FAILED: %s\n' "${2:-}"; exit "${1:-1}"; }
    ok(){ printf 'OK — %s\n' "$1"; }; warn(){ :; }
    _plugin_installed_json(){ echo "$WORK/b/plugins/installed.json"; }
    systemd-run(){ echo "systemd-run $*" >> "$WORK/b/calls"; }
    systemctl(){ return 3; }   # no unit is active
    eval "$block"
    eval "$code"
  ) 2>&1
}
st(){ cat "$WORK/b/state/voice-auto" 2>/dev/null | grep -v '^at=' | tr '\n' ' '; }
calls(){ cat "$WORK/b/calls"; }

# --- the decision, pure: managed > on > installing > declined > ask -----------
dec(){ run "_va_decide $*"; }
bad=""
for c in "1 0 0 '' managed" "1 1 0 off managed" "0 1 0 off on" "0 1 1 '' on" "0 0 1 off installing" \
         "0 0 0 off declined" "0 0 0 '' ask" "0 0 0 on ask"; do
  set -- $c; want="${!#}"; got="$(eval "dec $1 $2 $3 $4")"
  [[ "$got" == "$want" ]] || bad+="[$c -> $got] "
done
[[ -z "$bad" ]] && ok_t "decide: 8 cases (managed > on > installing > declined > ask; a yes that never finished is asked again)" \
                || bad_t "decide" "$bad"

# --- first use on a fresh 4 GB box: asked, nothing installed -------------------
box 20000
out="$(run 'cmd_plugin_auto_voice --status')"
if grep -q 'voice: ask' <<<"$out" && grep -qF 'Install speech-to-text on your server? (about 2 min, keeps voice private)' <<<"$out" \
   && [[ ! -s "$WORK/b/calls" && -z "$(st)" ]]; then
  ok_t "FIRST USE: a fresh box's status says ask, with the one question; nothing installed or recorded"
else bad_t "FIRST USE" "$out | calls=$(calls) state=$(st)"; fi
out="$(run 'cmd_plugin_auto_voice')"
grep -q 'voice: ask' <<<"$out" && [[ ! -s "$WORK/b/calls" ]] \
  && ok_t "NO AUTO: the bare verb only reports; it installs nothing" || bad_t "NO AUTO bare" "$out | $(calls)"

# --- nothing installs it unasked ------------------------------------------------
if ! grep -nE 'auto-voice|_va_' src/cmd_init.sh >/dev/null; then ok_t "NO INIT: init never touches voice (no step, no question)"
else bad_t "NO INIT" "$(grep -nE 'auto-voice|_va_' src/cmd_init.sh)"; fi
if ! grep -nE 'plugin auto-voice|plugin (add|setup) voice' install.sh >/dev/null; then
  ok_t "NO BACKFILL: install.sh (fresh or --upgrade) never runs auto-voice or adds voice"
else bad_t "NO BACKFILL" "$(grep -nE 'plugin auto-voice|plugin (add|setup) voice' install.sh)"; fi
if ! grep -rnE 'plugin auto-voice( |$)(--on)?|_va_install' src --include=*.sh | grep -v '^src/cmd_plugin.sh' | grep -q .; then
  ok_t "NO CALLER: nothing in src outside the verb itself runs it"
else bad_t "NO CALLER" "$(grep -rnE 'plugin auto-voice|_va_install' src --include=*.sh | grep -v '^src/cmd_plugin.sh')"; fi

# --- the owner's yes --------------------------------------------------------------
box 20000
out="$(run 'cmd_plugin_auto_voice --on')"
if grep -q 'cli plugin add voice --yes' <<<"$(calls)" && grep -q "systemd-run --unit=5dive-voice-auto-setup.* plugin setup voice --yes" <<<"$(calls)" \
   && [[ "$(st)" == "choice=on source=owner " ]] && grep -q 'Installing speech-to-text' <<<"$out" && grep -q 'auto-voice --wait' <<<"$out"; then
  ok_t "YES: --on adds the plugin, queues setup in the background unit, records on/owner, says how to wait"
else bad_t "YES" "$out | calls=$(calls) state=$(st)"; fi

box 20000; rm -rf "$WORK/b/sd"
out="$(run 'cmd_plugin_auto_voice --on; sleep 0.2')"
if [[ -s "$WORK/b/state/voice-auto.pid" ]] && grep -q 'cli plugin setup voice --yes' <<<"$(calls)"; then
  ok_t "YES, no systemd: setup runs as a detached child whose pid --wait can watch"
else bad_t "YES no systemd" "$out | calls=$(calls)"; fi

box 900
out="$(run 'cmd_plugin_auto_voice --on')"; rc=$?
if grep -q 'free disk' <<<"$out" && [[ ! -s "$WORK/b/calls" && -z "$(st)" ]]; then
  ok_t "LOW DISK: --on refuses with the reason and installs nothing"
else bad_t "LOW DISK" "rc=$rc $out | $(calls)"; fi

box 20000
printf '#!/bin/sh\nexit 1\n' > "$WORK/b/cli"
out="$(run 'cmd_plugin_auto_voice --on')"
[[ -z "$(st)" ]] && grep -q FAILED <<<"$out" \
  && ok_t "ADD FAILS: nothing recorded, so the next ask can try again" || bad_t "ADD FAILS" "$out | $(st)"

# --- wait: the note that asked is heard after this --------------------------------
box 20000
out="$(run '_va_installing(){ n=$(cat "$WORK/b/n" 2>/dev/null || echo 0); echo $((n+1)) > "$WORK/b/n"; (( n == 2 )) && { printf "#!/bin/sh\n" > "$FIVEDIVE_TRANSCRIBE_BIN"; chmod +x "$FIVEDIVE_TRANSCRIBE_BIN"; }; return 0; }; cmd_plugin_auto_voice --wait; echo "rc=$?"')"
grep -q 'Speech-to-text is ready' <<<"$out" && grep -q 'rc=0' <<<"$out" \
  && ok_t "WAIT: blocks while installing, returns 0 the moment it hears" || bad_t "WAIT" "$out"
box 20000
out="$(FIVEDIVE_VOICE_AUTO_INSTALLING=1 run 'cmd_plugin_auto_voice --wait --timeout=0')"; rc=$?
grep -q 'still installing' <<<"$out" && (( rc == 11 )) \
  && ok_t "WAIT timeout: still installing exits 11 and says to wait again" || bad_t "WAIT timeout" "rc=$rc $out"
out="$(run 'cmd_plugin_auto_voice --wait')"; rc=$?
grep -q 'not installing and not ready' <<<"$out" && (( rc == 1 )) \
  && ok_t "WAIT, nothing running: fails at once, never hangs" || bad_t "WAIT idle" "rc=$rc $out"
out="$(FIVEDIVE_VOICE_AUTO_INSTALLING=1 run 'cmd_plugin_auto_voice --status')"
grep -q 'voice: installing' <<<"$out" && ok_t "STATUS installing: says to wait, not to ask again" || bad_t "STATUS installing" "$out"

# --- the owner's No is remembered -------------------------------------------------
box 20000
run 'cmd_plugin_auto_voice --off' >/dev/null
out="$(run 'cmd_plugin_auto_voice --status')"
if [[ "$(st)" == "choice=off source=owner " ]] && grep -q 'voice: declined' <<<"$out" && grep -q 'do not offer it again' <<<"$out" && [[ ! -s "$WORK/b/calls" ]]; then
  ok_t "NO: --off is recorded as the owner's; status then says declined, never ask"
else bad_t "NO" "$out | $(st)"; fi
out="$(run 'cmd_plugin_auto_voice --on')"
grep -q 'cli plugin add voice' <<<"$(calls)" && [[ "$(st)" == "choice=on source=owner " ]] \
  && ok_t "ASKED LATER: after a No, the owner asking for voice (--on) still installs it" || bad_t "ASKED LATER" "$out | $(calls)"

box 20000 no yes yes; printf 'choice=off\nsource=owner\n' > "$WORK/b/state/voice-auto"; rm -f "$WORK/b/transcribe"
out="$(run 'cmd_plugin_auto_voice --status')"
grep -q 'voice: declined' <<<"$out" && ok_t "REMOVED: a recorded removal reads declined" || bad_t "REMOVED" "$out"
fn="$(sed -n '/^cmd_plugin_remove()/,/^}/p' src/cmd_plugin.sh)"
grep -q '\[\[ "\$plugin" == voice \]\] && { _va_record off owner' <<<"$fn" \
  && ok_t "REMOVED: plugin remove voice records off/owner (in cmd_plugin_remove)" || bad_t "remove hook missing"

# --- a yes whose setup never finished is offered again -----------------------------
box 20000 no no yes; printf 'choice=on\nsource=owner\n' > "$WORK/b/state/voice-auto"
out="$(run 'cmd_plugin_auto_voice --status')"
grep -q 'voice: ask' <<<"$out" && ok_t "FAILED SETUP: registered plugin, no 5dive-transcribe, nothing running -> ask again" || bad_t "FAILED SETUP" "$out"

# --- hears already / managed: nothing to offer ------------------------------------
box 20000 no yes
out="$(run 'cmd_plugin_auto_voice --status; cmd_plugin_auto_voice --on')"
grep -q 'voice: on' <<<"$out" && grep -q 'already on' <<<"$out" && ! grep -q 'plugin add' <<<"$(calls)" \
  && ok_t "ON: a box with 5dive-transcribe says on; --on adds nothing" || bad_t "ON" "$out | $(calls)"
box 20000 yes
out="$(run 'cmd_plugin_auto_voice --status; cmd_plugin_auto_voice --on')"
grep -q 'voice: managed' <<<"$out" && [[ ! -s "$WORK/b/calls" && -z "$(st)" ]] \
  && ok_t "MANAGED: a box 5dive runs is never touched, even by --on" || bad_t "MANAGED" "$out | $(calls)"
out="$(run 'cmd_plugin_auto_voice --bogus')"; rc=$?
(( rc == 2 )) && grep -q usage <<<"$out" && ok_t "USAGE: an unknown flag is a usage error" || bad_t "USAGE" "rc=$rc $out"

# --- how the agent knows to ask ---------------------------------------------------
P=prompts/voice-offer-CLAUDE.md
blk="$(sed -n '/<!-- 5dive:voice-offer:begin/,/<!-- 5dive:voice-offer:end/p' "$P" 2>/dev/null)"
if [[ -n "$blk" ]] && grep -qF 'never installed unasked' <<<"$blk" && grep -qF '5dive plugin auto-voice --status' <<<"$blk" \
   && grep -qF 'sudo 5dive plugin auto-voice --on' <<<"$blk" && grep -qF 'auto-voice --wait' <<<"$blk" \
   && grep -qF '5dive-transcribe <file>' <<<"$blk" && grep -qF 'sudo 5dive plugin auto-voice --off' <<<"$blk" \
   && grep -qF 'any channel' <<<"$blk" && grep -qF "$(run 'echo "$VA_ASK"')" <<<"$blk"; then
  ok_t "AGENT: the voice-offer block names every step (status, the same question, yes/wait/hear, no) and 'never unasked'"
else bad_t "AGENT block" "$blk"; fi
sync="$(grep -n -B1 -A1 'voice-offer-CLAUDE.md' install.sh)"
if grep -q '5dive:voice-offer' <<<"$sync" && grep -B3 'voice-offer-CLAUDE.md' install.sh | grep -qF '[[ ! -f /etc/5dive/provisioning.env ]]'; then
  ok_t "AGENT: install.sh syncs the block on every run, only on a self-hosted box"
else bad_t "AGENT sync" "$sync"; fi
# The block lands in the file every agent reads every turn: keep the self-hosted
# box's whole file under the lean cap (tests/projects_claudemd_lean_unit.sh).
w=$( { sed '/<!-- 5dive:hired-agents:begin/,/<!-- 5dive:hired-agents:end/d' prompts/projects-CLAUDE.md; cat "$P"; } | wc -w)
(( w <= 470 )) && ok_t "AGENT: the self-hosted box file with the block is $w words (<= 470)" || bad_t "AGENT words" "$w > 470"
# Sync it for real into a fake live file twice: appended once, replaced in place.
eval "$(sed -n '/^sync_managed_block() {/,/^}/p' install.sh)"
printf '# host\nkeep me\n' > "$WORK/live.md"
sync_managed_block "$WORK/live.md" "$P" 5dive:voice-offer && sync_managed_block "$WORK/live.md" "$P" 5dive:voice-offer
n=$(grep -c '5dive:voice-offer:begin' "$WORK/live.md"); grep -q 'keep me' "$WORK/live.md" && (( n == 1 )) \
  && ok_t "AGENT: syncing twice leaves one block and the host's own lines" || bad_t "AGENT sync twice" "$(cat "$WORK/live.md")"

echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
