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

echo "== static wiring (DIVE-1222 grok freeze) =="
has "guard present"            "grok provisioning is frozen"
# DIVE-3185: the predicate moved from an env var to a managed-fleet MARKER FILE.
# Asserting the literal condition (not just "some grok check exists") is what
# makes a silent revert to a permissive default, or back to an env var, red here.
has "refuse condition"         'if [[ "$type" == "grok" && ! -e "$grok_arm_marker" ]]; then'
has "marker path defaulted"    'local grok_arm_marker="${FIVE_GROK_ARM_MARKER:-/etc/5dive/arm/grok-unfreeze}"'
has "names the unfreeze bar"   "a verified xAI client-side fix"
has "override warns"           "bypassing the DIVE-1221 Grok exfiltration freeze"
has "guard sits after is_known_type" "DIVE-1221/1222: Grok provisioning is FROZEN"
# DIVE-3185: these two sentences are load-bearing, not decoration. The first
# prevents a later reader treating the marker as a security boundary and building
# something on top of it (the CODEOWNERS-naming-a-nonexistent-team failure mode:
# a thing that looks like a control and is not). The second is acceptance 4 — an
# arm whose reverse is undocumented is a one-way door. Both are the kind of
# comment that gets "tidied" by someone who does not know why it is there.
has "marker named a speed bump"  "SPEED BUMP, NOT A SECURITY BOUNDARY"
# DIVE-3185 item 4: the comment must record an owner risk acceptance on a
# PARTIALLY-satisfied condition, and say WHICH half. A future reader who finds
# armed customer boxes has to be able to tell "the owner accepted a live risk"
# from "the freeze's exit condition was met" — those are different facts and
# only one of them is true. Asserting both halves by name is what stops the
# distinction being flattened by a later tidy-up.
has "condition is half met"      "THAT CONDITION IS HALF MET"
has "names the unmet half"       "ZERO tags and ZERO"
has "risk acceptance recorded"   "RISK ACCEPTANCE ON A PARTIALLY-SATISFIED CONDITION"
has "un-arm path documented"     "UN-ARMING"
has "create-not-run caveat"      'does not mean "recallable"'

# DIVE-3090: the functional probe below is only meaningful in this ORDER. It
# passes --channels=bogus so a guard that is bypassed, removed or reordered dies
# at channel validation instead of provisioning — but if valid_channel ever moves
# ABOVE the guard, the create stops before the guard is reached and the arm
# proves nothing while still going green. And the barrier is only a barrier while
# valid_channel stays below create_agent_user. Assert both, by line number.
guard_ln=$(grep -nF -- 'DIVE-1221/1222: Grok provisioning is FROZEN' "$SRC" | head -1 | cut -d: -f1)
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
  # DIVE-3185 — TWO ARMS, both host-independent, because the guard is now a
  # predicate and a one-armed test cannot tell "refuses everything" from
  # "refuses correctly". Each arm PINS the marker rather than reading the host's:
  # on an armed customer box the old single arm would have gone red, and on the
  # control host it would have inherited the arm exactly as DIVE-3090 did.
  #
  # ARM A — the UNMARKED path, which is the OSS path every stranger installs.
  # Marker pinned to a path that cannot exist, so this grades the GUARD.
  # `env -u FIVE_GROK_UNFREEZE_VERIFIED` is retained deliberately: it is now
  # inert (DIVE-3185 removed the env var from the condition), and keeping it
  # proves that — if anyone re-adds an env-var escape hatch alongside the marker,
  # this arm goes red instead of quietly passing.
  absent_marker="/nonexistent/5dive-grok-arm-$$"
  out="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED FIVE_GROK_ARM_MARKER="$absent_marker" \
        "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc=$?
  # DIVE-2645: assert the VERDICT, not a ticket id. The refusal no longer carries
  # "(DIVE-1221)" — an arm that requires one is what made the archaeology mandatory.
  if [[ $rc -ne 0 ]] && grep -qF "grok provisioning is frozen" <<<"$out"; then
    ok "unmarked host: grok create refused with the freeze error"
  else
    bad "unmarked host: grok create should refuse (rc=$rc, out: $out)"
  fi

  # ARM B — the MARKED path. This deliberately gets PAST the freeze, so its
  # safety is not borrowed from the guard: --channels=bogus is an independent
  # barrier, and the line-order check above proves valid_channel still sits
  # between the guard and create_agent_user. Reaching the CHANNELS error is the
  # pass; reaching the freeze error means the marker predicate never worked and
  # the arm we shipped for lodar's risk acceptance is dead on every box.
  marked=$(mktemp) || marked=""
  if [[ -n "$marked" ]]; then
    printf 'DIVE-3185 test marker\n' >"$marked"
    out2="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED FIVE_GROK_ARM_MARKER="$marked" \
           "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc2=$?
    if grep -qF "grok provisioning is frozen" <<<"$out2"; then
      bad "marked host: marker did NOT arm — still hit the freeze (rc=$rc2, out: $out2)"
    elif [[ $rc2 -ne 0 ]] && grep -qF "invalid channels" <<<"$out2"; then
      ok "marked host: guard permitted, stopped at the --channels=bogus barrier"
    else
      bad "marked host: expected the channels error, got rc=$rc2 out: $out2"
    fi
    rm -f "$marked"
  else
    echo "  skip marked-path arm (mktemp failed)"
  fi

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

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
