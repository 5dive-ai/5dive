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
has "guard present"            "grok provisioning is frozen (DIVE-1221)"
has "refuse condition"         'if [[ "$type" == "grok" && "${FIVE_GROK_UNFREEZE_VERIFIED:-}" != "1" ]]; then'
has "points to DIVE-1221"      "See DIVE-1221."
has "override warns"           "bypassing the DIVE-1221 Grok exfiltration freeze"
has "guard sits after is_known_type" "DIVE-1221/1222: Grok provisioning is FROZEN"

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
  out="$($SUDO env -u FIVE_GROK_UNFREEZE_VERIFIED "$BIN" agent create grokbot --type=grok --channels=bogus 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && grep -qF "grok provisioning is frozen (DIVE-1221)" <<<"$out"; then
    ok "grok create refused with DIVE-1221 error"
  else
    bad "grok create should refuse (rc=$rc, out: $out)"
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
