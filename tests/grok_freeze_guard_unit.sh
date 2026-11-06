#!/usr/bin/env bash
# DIVE-1222 — Grok provisioning freeze guard unit test.
# The guard is inlined in cmd_create right after is_known_type, so every
# provisioning path (agent create, hire, pack import, clone) that funnels
# through cmd_create is blocked. We test (1) static wiring in the source and
# (2) functional behaviour of the refuse/override condition against the built
# `5dive` binary.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
# Three-state: if the helper is unreachable (a staged copy that did not carry
# tests/lib/), the log says NO TREE WAS NAMED rather than falling silent, and a
# `set -e` harness is not killed by a failed source.
# NOTE the absence of `2>/dev/null`. The obvious hardening -- redirect the
# source's stderr so bash's "No such file" does not litter the log -- also
# swallows the helper's own stderr line, which IS the payload. That silenced all
# 210 harnesses at once while every other check in this change stayed green.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.." || exit 1
SRC="src/cmd_agent_create.sh"
BIN="./5dive"
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
has()  { grep -qF -- "$2" "$SRC" && ok "$1" || bad "$1 (missing: $2)"; }

echo "== static wiring (DIVE-1222 grok guard; DIVE-7802 on by default) =="
# DIVE-7802 (lodar 2026-11-06, "dont gate it"): Grok is ON unless the owner ran
# `grok disable`. Asserting the literal condition is what makes a silent revert
# to the old opt-in (refuse when an ARM marker is absent) red here.
has "guard present"            "Grok is turned off on this server"
has "refuse condition"         'if [[ "$type" == "grok" && -e "$grok_off_marker" ]]; then'
has "off marker path defaulted" 'local grok_off_marker="${FIVE_GROK_OFF_MARKER:-/etc/5dive/arm/grok-off}"'
has "names how to undo"        "To turn it back on: sudo 5dive grok enable"
has "note on every grok create" "Grok's tool sends your agent's notes and chat turns to xAI after every turn."
has "guard sits after is_known_type" "DIVE-1221/1222 -> DIVE-7802: Grok is ON by default"
# The risk is accepted, not fixed. These sentences stop a later reader from
# reading "on by default" as "patched", or dropping the off switch as dead code.
has "not a patch"              "NOT A PATCH. The xAI upload path is still live"
has "risk acceptance recorded" "OWNER RISK ACCEPTANCE"
has "create-not-run caveat"    "It gates CREATE, not"
if grep -qF 'grok-unfreeze}' "$SRC" || grep -qF 'FIVE_GROK_ARM_MARKER' "$SRC"; then
  bad "the old opt-in arm marker is still read by create"
else
  ok "the old opt-in arm marker is no longer read by create"
fi

# DIVE-3090: the functional probe below is only meaningful in this ORDER. It
# passes --channels=bogus so a guard that is bypassed, removed or reordered dies
# at channel validation instead of provisioning — but if valid_channel ever moves
# ABOVE the guard, the create stops before the guard is reached and the arm
# proves nothing while still going green. And the barrier is only a barrier while
# valid_channel stays below create_agent_user. Assert both, by line number.
guard_ln=$(grep -nF -- 'if [[ "$type" == "grok" && -e "$grok_off_marker" ]]; then' "$SRC" | head -1 | cut -d: -f1)
chan_ln=$(grep -nF -- 'valid_channel "$channels"' "$SRC" | head -1 | cut -d: -f1)
user_ln=$(grep -nF -- 'create_agent_user "$name"' "$SRC" | head -1 | cut -d: -f1)
if [[ -n "$guard_ln" && -n "$chan_ln" && -n "$user_ln" \
      && $guard_ln -lt $chan_ln && $chan_ln -lt $user_ln ]]; then
  ok "guard < valid_channel < create_agent_user (${guard_ln} < ${chan_ln} < ${user_ln})"
else
  bad "probe order broken (guard=${guard_ln:-?} valid_channel=${chan_ln:-?} create_agent_user=${user_ln:-?}); --channels=bogus no longer separates refuse from bypass"
fi

echo "== functional (built binary) =="
# cmd_create is root-gated; the freeze fires right after is_known_type, before
# any user/FS side effect, so a sudo dry-hit is cheap — but that safety used to
# be BORROWED from the subject under test. This arm performs the real forbidden
# act and asserts the guard refused, which is only safe while the guard holds.
# DIVE-2910 armed FIVE_GROK_UNFREEZE_VERIFIED=1 on a host (lodar's recorded risk
# acceptance); the override reaches every `sudo` call through /etc/environment +
# pam_env, so this arm inherited it, the guard passed, and the harness itself
# PROVISIONED and STARTED the agent it exists to prevent — a live
# `grok --always-approve` over /home/claude/projects for 8h before anyone
# noticed. The comment that used to sit here ("verified: no agent-grokbot user
# is created") was measured on an UNARMED host and never said so.
# DIVE-3090 — two changes so the arm owns its safety instead of borrowing it:
#   1. `env -u FIVE_GROK_UNFREEZE_VERIFIED` pins the refusal, so this grades the
#      GUARD and not the HOST. An armed box can no longer flatter or arm it.
#   2. `--channels=bogus` is a second, independent barrier: the guard sits
#      between is_known_type and valid_channel, so a refusing guard still yields
#      the DIVE-1221 error, while a guard that is bypassed, removed or reordered
#      dies at channel validation instead of provisioning a real agent.
SUDO=""
[[ $EUID -eq 0 ]] || { sudo -n true 2>/dev/null && SUDO="sudo -n"; }
# ensure_state (state init) chgrps the state tree to the `claude` group, which
# install.sh always creates but a bare CI runner does not — without it the
# `chown root:claude` aborts under `set -e` BEFORE the freeze guard runs, so the
# check would see a chown error instead of the refusal. Replicate the install
# invariant so this stays hermetic; skip (don't fail) if the group can't be made.
if [[ $EUID -eq 0 || -n "$SUDO" ]]; then
  getent group claude >/dev/null 2>&1 || $SUDO groupadd claude 2>/dev/null || true
fi
have_claude_grp=0; getent group claude >/dev/null 2>&1 && have_claude_grp=1
if [[ -x "$BIN" && ( $EUID -eq 0 || -n "$SUDO" ) && $have_claude_grp -eq 1 ]]; then
  # DIVE-3070: agent-grokbot can PRE-EXIST this run — the DIVE-2910 incident left
  # uid 1021 in place on purpose (forensics), and `id` cannot tell "leaked by this
  # create" from "left by an earlier one". Absence is therefore the wrong
  # assertion on any host that has ever leaked; snapshot first and grade the DELTA.
  pre_user=0; id agent-grokbot &>/dev/null && pre_user=1
  # TWO ARMS, both host-independent: each PINS the off marker rather than
  # reading the host's (DIVE-3090 caught this harness inheriting a host's state).
  # `env -u FIVE_GROK_ARM_MARKER -u FIVE_GROK_UNFREEZE_VERIFIED` keeps the old
  # seams inert: re-adding either as an escape hatch turns an arm red.
  #
  # ARM A — no off marker (every server by default, DIVE-7802). Gets PAST the
  # guard, so its safety is not borrowed from it: --channels=bogus is an
  # independent barrier and the line-order check above proves valid_channel
  # sits between the guard and create_agent_user. Reaching the CHANNELS error is
  # the pass; reaching the guard error means Grok is still gated.
  absent_marker="/nonexistent/5dive-grok-off-$$"
  out="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED -u FIVE_GROK_ARM_MARKER FIVE_GROK_OFF_MARKER="$absent_marker" \
        "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc=$?
  if grep -qF "Grok is turned off on this server" <<<"$out"; then
    bad "no off marker: grok create still refused (rc=$rc, out: $out)"
  elif [[ $rc -ne 0 ]] && grep -qF "invalid channels" <<<"$out"; then
    ok "no off marker: guard permitted, stopped at the --channels=bogus barrier"
  else
    bad "no off marker: expected the channels error, got rc=$rc out: $out"
  fi
  if grep -qF "to xAI after every turn" <<<"$out" && ! grep -qE "DIVE-[0-9]" <<<"$out"; then
    ok "no off marker: the plain xAI note is shown, no internal ids"
  else
    bad "no off marker: expected the xAI note and no DIVE ids (out: $out)"
  fi

  # ARM B — after `grok disable` (real binary, pinned marker) the NEXT create
  # is refused, and the refusal says how to undo it, with no internal ids.
  dmark="$(mktemp -d)/arm/grok-off"
  $SUDO env FIVE_GROK_OFF_MARKER="$dmark" "$BIN" grok disable >/dev/null 2>&1
  out3="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED -u FIVE_GROK_ARM_MARKER FIVE_GROK_OFF_MARKER="$dmark" \
         "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc3=$?
  if [[ -e "$dmark" && $rc3 -ne 0 ]] && grep -qF "Grok is turned off on this server" <<<"$out3" \
     && grep -qF "sudo 5dive grok enable" <<<"$out3" && ! grep -qE "DIVE-[0-9]" <<<"$out3"; then
    ok "grok disable: off marker written, next grok create refused, names the undo"
  else
    bad "grok disable: marker present=$([[ -e "$dmark" ]] && echo yes || echo no) rc=$rc3 out: $out3"
  fi
  # ...and `grok enable` undoes it: back to the channels barrier.
  $SUDO env FIVE_GROK_OFF_MARKER="$dmark" "$BIN" grok enable >/dev/null 2>&1
  out4="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED -u FIVE_GROK_ARM_MARKER FIVE_GROK_OFF_MARKER="$dmark" \
         "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc4=$?
  if [[ ! -e "$dmark" && $rc4 -ne 0 ]] && grep -qF "invalid channels" <<<"$out4"; then
    ok "grok enable: off marker removed, create reaches the channels barrier again"
  else
    bad "grok enable: marker present=$([[ -e "$dmark" ]] && echo yes || echo no) rc=$rc4 out: $out4"
  fi
  $SUDO rm -rf "$(dirname "$(dirname "$dmark")")"

  post_user=0; id agent-grokbot &>/dev/null && post_user=1
  if [[ $post_user -gt $pre_user ]]; then
    bad "freeze leaked a user (agent-grokbot created by THIS run)"
  else
    ok "no user created by refused grok create"
  fi
  if [[ $pre_user -eq 1 ]]; then
    echo "  note: agent-grokbot PRE-EXISTED this run (DIVE-2910 residue) — the check above is a delta, not an absence"
  fi
else
  echo "  skip functional (need built ./5dive + root/sudo -n + claude group)"
fi

echo "== grok enable / disable / status (DIVE-7802, sourced; no root, no live create) =="
# Sourced with stubs so it needs no root and never reaches a create. No arm
# needs a terminal: turning Grok on asks nothing (DIVE-7802), which the
# no-tty pipes below prove.
G="$(mktemp -d)"
cat >"$G/drive.sh" <<'DRIVE'
set -uo pipefail
E_USAGE=2 E_PERMISSION=3 E_GENERIC=1 JSON_MODE=0
fail() { printf 'FAIL(%s) %s\n' "$1" "$2"; exit 1; }
ok()   { printf 'OK — %s\n' "$1"; }
require_root() { :; }
actor_routing_agent() { [[ -n "${STUB_AGENT:-}" ]] && { printf '%s' "$STUB_AGENT"; return 0; }; return 1; }
source "$1"; shift
cmd_grok "$@"
DRIVE
gmod="$PWD/src/cmd_grok.sh"
gm="$G/arm/grok-off"
drive() { FIVE_GROK_OFF_MARKER="$gm" bash "$G/drive.sh" "$gmod" "$@" </dev/null 2>&1; }
rm -f "$gm"; o=$(drive status)
grep -qF "Grok is on" <<<"$o" && ok "status with no marker: on by default" || bad "status/default: $o"
o=$(drive disable)
[[ -e "$gm" ]] && grep -qF "keep running" <<<"$o" \
  && ok "disable: off marker written, says existing agents keep running" || bad "disable: marker=$([[ -e "$gm" ]] && echo present || echo absent) out: $o"
o=$(drive status)
grep -qF "Grok is off" <<<"$o" && grep -qF "sudo 5dive grok enable" <<<"$o" \
  && ok "status after disable: off, names the undo" || bad "status/off: $o"
o=$(STUB_AGENT=olivia drive enable); rc=$?
[[ $rc -ne 0 && -e "$gm" ]] && grep -qF "only they can turn it back on" <<<"$o" \
  && ok "enable from an agent seat does not undo the owner's off" || bad "enable/agent: rc=$rc marker=$([[ -e "$gm" ]] && echo present || echo absent) out: $o"
o=$(drive enable --yes); rc=$?
[[ $rc -ne 0 && -e "$gm" ]] && ok "enable takes no options" || bad "enable --yes: rc=$rc out: $o"
o=$(drive enable); rc=$?
[[ $rc -eq 0 && ! -e "$gm" ]] && grep -qF "to xAI after every turn" <<<"$o" \
  && ok "enable with no tty: off marker removed, no question asked, note shown" || bad "enable/no-tty: rc=$rc marker=$([[ -e "$gm" ]] && echo present) out: $o"
# The quoted guide line (`sudo 5dive grok enable && …`) must still succeed: a
# harmless "Grok is already on", exit 0, from any seat, needing no root.
o=$(STUB_AGENT=olivia drive enable); rc=$?
[[ $rc -eq 0 && ! -e "$gm" ]] && grep -qF "Grok is already on" <<<"$o" \
  && ok "enable when on (the quoted guide line): 'Grok is already on', exit 0, from an agent seat" || bad "enable/on: rc=$rc out: $o"
sed 's/^require_root() { :; }$/require_root() { printf "FAIL(3) needs root\\n"; exit 1; }/' "$G/drive.sh" >"$G/drive-noroot.sh"
o=$(FIVE_GROK_OFF_MARKER="$gm" bash "$G/drive-noroot.sh" "$gmod" enable 2>&1 </dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -qF "Grok is already on" <<<"$o" \
  && ok "enable when on needs no root" || bad "enable/on/no-root: rc=$rc out: $o"
rm -rf "$G"

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
