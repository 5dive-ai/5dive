#!/usr/bin/env bash
# DIVE-2281 — a direct-path send must carry an envelope, and from= / tier= must
# describe the SAME process.
#
# THE DEFECT: auto_sender_from_sudo resolves from $SUDO_USER, set only when the caller
# reached the CLI THROUGH sudo. The scoped a2a path always does; a full-trust
# NOPASSWD:ALL agent running `5dive agent send` as itself does not, so it resolved to
# "" — and an empty sender skips cmd_send's envelope block ENTIRELY. Measured against
# a live pane before the fix: the receiver showed `❯ <message>` with ZERO occurrences
# of `5dive-msg`. Not a weak tier — NO header. An unenveloped inject is
# byte-indistinguishable from the paired HUMAN typing into that pane.
#
# WHY A SEPARATE HELPER RATHER THAN FIXING auto_sender_from_sudo: that is the SHARED
# actor resolver (12 call sites incl. _gate_withdraw_actor and the task/objective actor
# paths). Changing it changes who the CLI thinks you are everywhere. Measured when
# attempted: 9 harnesses green on main went red, because on an agent host the caller
# genuinely IS an agent-* user and those paths began resolving an identity where they
# previously resolved none. The envelope gap does not justify moving the actor model.
#
# NO SKIPS. Both real branches are asserted — an agent runner resolves its label, a
# non-agent runner resolves EMPTY — so this harness measures something on every host
# rather than reporting a green summary over arms that did not run.
set -uo pipefail

# DIVE-2211: name the tree this harness grades (tests/lib/grading_tree.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2

# DIVE-2328/dev: src/header.sh sets `set -euo pipefail`, so sourcing production code
# re-enables errexit and the first non-zero command substitution kills the file —
# fifteen ok, no summary, rc=10. 132 sibling harnesses carry this; grade the summary.
set +e

trap 'rc=$?; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/src/cmd_agent_runtime.sh"
# auto_sender_from_sudo is the SHARED actor resolver and lives in lib/validation.sh, not
# here. Naming it explicitly because extracting it from $SRC silently yields NOTHING —
# which is how the first cut of T6b "passed" its own rig while proving nothing.
VSRC="$ROOT/src/lib/validation.sh"

pass=0; fail=0
ok_t()  { printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
bad_t() { printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# Extract the helper without executing the rest of the module (which needs the full
# CLI environment). The function is self-contained by design.
FN="$(awk '/^_envelope_sender_fallback\(\) \{/,/^\}/' "$SRC")"
[[ -n "$FN" ]] \
  && ok_t 'T0 the helper is present and extractable' \
  || bad_t 'T0 helper not found — every arm below is vacuous' "src=$SRC"
eval "$FN"
[[ -s "$VSRC" ]] \
  && ok_t 'T0b the shared resolver source is present — the T6 rigs are not extracting from an empty file' \
  || bad_t 'T0b lib/validation.sh missing — T6a/T6b would pass vacuously' "vsrc=$VSRC"


# --- T1 both real branches, no mocking, no skip ------------------------------
REAL_UID="$(grep -m1 '^Uid:' /proc/self/status | awk '{print $2}')"
REAL_NAME="$(awk -F: -v u="$REAL_UID" '$3==u{print $1; exit}' /etc/passwd)"
got="$(_envelope_sender_fallback)"
if [[ "$REAL_NAME" == agent-* ]]; then
  [[ "$got" == "${REAL_NAME#agent-}" ]] \
    && ok_t "T1 agent runner resolves its own label (uid $REAL_UID -> '$got')" \
    || bad_t 'T1 agent runner did not resolve its label' "got='$got' want='${REAL_NAME#agent-}'"
else
  [[ -z "$got" ]] \
    && ok_t "T1 NON-agent runner resolves EMPTY (uid $REAL_UID, '$REAL_NAME') — unenveloped shape preserved" \
    || bad_t 'T1 a non-agent runner was given an identity' "got='$got' want=''"
fi

# --- T2 no external command: nothing here is PATH-resolvable -----------------
# This is the DIVE-1401 property. An earlier cut used `id -un`, which resolves
# through the caller's PATH and was forgeable by an agent controlling its own
# environment. Assert the implementation cannot reach a PATH lookup at all.
if printf '%s' "$FN" | grep -qE '(^|[^a-z_])(id|getent|whoami)[[:space:]]'; then
  bad_t 'T2 the helper shells out — that is PATH-forgeable (DIVE-1401)' \
        "$(printf '%s' "$FN" | grep -nE '(^|[^a-z_])(id|getent|whoami)[[:space:]]' | head -2)"
else
  ok_t 'T2 no external command: identity cannot be forged via PATH (DIVE-1401)'
fi

# --- T3 it reads $EUID, the one input a caller cannot set --------------------
printf '%s' "$FN" | grep -q 'EUID' \
  && ok_t 'T3 derives from $EUID (bash builtin: not PATH-resolved, not env-settable)' \
  || bad_t 'T3 does not use $EUID' ''

# --- T4 no env-settable passwd source ----------------------------------------
# The value feeds envelope_tier, so an env-overridable source would be a NEW forgery
# vector in the field the design treats as unforgeable.
printf '%s' "$FN" | grep -q 'done < /etc/passwd' \
  && ok_t 'T4 passwd source is hardcoded — no env-settable override into tier=' \
  || bad_t 'T4 passwd source is overridable' "$(printf '%s' "$FN" | grep -n 'done <')"

# --- T5 from= and tier= must resolve the SAME caller -------------------------
# Before the fix the header recomputed auto_sender_from_sudo inline, so a direct-path
# send could show a real from= beside tier=unknown:no-caller: two fields disagreeing
# about one sender.
# Updated with the T6 swap: both fields now resolve through _envelope_caller, so the
# constraint is unchanged and only the spelling moved. Asserted as the ABSENCE of the
# defect shape rather than the presence of one spelling — an inline
# `envelope_tier "$(...)"` is the bug, whatever function sits inside it.
if grep -q 'envelope_tier "\$_dcaller"' "$SRC" && grep -q '_dcaller="\$(_envelope_caller)"' "$SRC"; then
  ok_t 'T5 tier= is computed from the same resolved caller as from= (both via _envelope_caller)'
else
  bad_t 'T5 tier= recomputes its own caller — from= and tier= can disagree' \
        "$(grep -n 'envelope_tier' "$SRC" | head -3)"
fi
if grep -qE 'envelope_tier "\$\([a-z_]+\)"' "$SRC"; then
  bad_t 'T5b an inline envelope_tier "$(resolver)" is back — that IS the disagreeing-fields defect' \
        "$(grep -nE 'envelope_tier "\$\([a-z_]+\)"' "$SRC" | head -3)"
else
  ok_t 'T5b no inline envelope_tier "$(resolver)" anywhere — the caller is always resolved to a variable first'
fi

# --- T6 PRECEDENCE: the unforgeable source WINS over the forgeable one --------
# Rewritten after dev's review. The previous T6 grepped for the fallback being gated
# BEHIND auto_sender_from_sudo, which pinned the wrong order: $SUDO_USER is a plain env
# var on the direct path, so asking it first meant the composition preferred the
# FORGEABLE source. T6's stated justification — "sudo path unchanged" — is satisfied by
# BOTH orderings (T6c proves it), so the constraint survives and only the assertion moved.
#
# Graded BEHAVIOURALLY, not by grep: the old arm would have stayed green through the
# actual defect, since it asserted the presence of a line rather than an outcome.
eval "$(awk '/^auto_sender_from_sudo\(\) \{/,/^\}/' "$VSRC")"
eval "$(awk '/^_envelope_caller\(\) \{/,/^\}/' "$SRC")"

# T6a/T6b — THE PRECEDENCE, GRADED WITHOUT DEPENDING ON WHO RUNS THE SUITE.
#
# The first cut of these arms keyed off the real runner ($REAL_NAME == agent-*) and called
# bad_t otherwise, on the reasoning that a skip is NOT-REACHED and must not read as green.
# That reasoning is right and the implementation was wrong: CI runs as `runner`, never as
# an agent-* user, so the arm could NEVER pass in the only environment that gates a merge.
# Measured: 11/0 on this host, 9/1 on CI, failing on the arm asserting the fix. A control
# that cannot pass where it is enforced is worse than one that is skipped there — it
# trains people to merge past it.
#
# So grade the ORDER itself, which is the actual security property, by substituting the
# EUID source with a stub. _envelope_caller is tiny and calls exactly two things, so a
# stubbed _envelope_sender_fallback exercises the real composition without needing the
# process to BE an agent. The real-identity check stays below as a bonus arm, and is a
# pass either way because T1 already grades the live resolver against /proc/self/status.
_precedence_rig() {                      # <euid-stub-output> <sudo_user> -> resolved caller
  local rig; rig="$(mktemp)"
  {
    awk '/^auto_sender_from_sudo\(\) \{/,/^\}/' "$VSRC"
    printf '_envelope_sender_fallback() { printf %%s %s; }\n' "'$1'"
    awk '/^_envelope_caller\(\) \{/,/^\}/' "$SRC"
    printf '_envelope_caller\n'
  } > "$rig"
  SUDO_USER="$2" bash "$rig"; rm -f "$rig"
}

got="$(_precedence_rig euidname agent-forged)"
[[ "$got" == "euidname" ]] \
  && ok_t "T6a a forged SUDO_USER is IGNORED when EUID resolves (got '$got', not 'forged')" \
  || bad_t 'T6a forged SUDO_USER chose the envelope sender — precedence is inverted' \
           "got='$got' want='euidname'"

# T6b ANCHOR — the same rig with an EMPTY EUID source must fall THROUGH to SUDO_USER.
# Two jobs: it proves the sudo path still answers (so the swap did not break _deliver),
# and it proves T6a is not passing because the rig ignores SUDO_USER entirely.
got="$(_precedence_rig '' agent-forged)"
[[ "$got" == "forged" ]] \
  && ok_t 'T6b ANCHOR: an empty EUID source falls through to SUDO_USER — T6a is not vacuous, sudo path intact' \
  || bad_t 'T6b anchor failed — either the fallback is dead or the rig never consults SUDO_USER' \
           "got='$got' want='forged'"

# T6b2 — and the OLD ordering really does forge, so the fix is not cosmetic.
_legacy_rig="$(mktemp)"
{
  awk '/^auto_sender_from_sudo\(\) \{/,/^\}/' "$VSRC"
  printf '_envelope_sender_fallback() { printf %%s "euidname"; }\n'
  printf 'x="$(auto_sender_from_sudo)"; [[ -n "$x" ]] || x="$(_envelope_sender_fallback)"; printf "%%s" "$x"\n'
} > "$_legacy_rig"
legacy="$(SUDO_USER=agent-forged bash "$_legacy_rig")"; rm -f "$_legacy_rig"
[[ "$legacy" == "forged" ]] \
  && ok_t 'T6b2 ANCHOR: the sudo-first ordering DOES forge (returns the exported name) — the swap is load-bearing' \
  || bad_t 'T6b2 anchor did not reproduce the forgery — T6a proves nothing' "legacy='$legacy'"

# T6d — BONUS, real identity. Only meaningful when the runner is an agent; reported as a
# pass either way with the case NAMED, because T1 already grades the live resolver and
# these arms no longer depend on it.
if [[ "$REAL_NAME" == agent-* ]]; then
  forged="$(SUDO_USER=agent-notme _envelope_caller)"
  [[ "$forged" == "${REAL_NAME#agent-}" ]] \
    && ok_t "T6d live process: forged SUDO_USER ignored, resolved '$forged' from the real EUID" \
    || bad_t 'T6d live process: a forged SUDO_USER chose the sender' "got='$forged'"
else
  ok_t "T6d live-identity arm N/A here (runner '$REAL_NAME' is not agent-*) — precedence graded by T6a/T6b above, not by this"
fi

# T6c — THE SCOPED PATH IS UNCHANGED BY THE SWAP, which is what makes it free. As root
# the EUID branch returns empty (root is not agent-*), so SUDO_USER — written by sudo
# under env_reset, not by the caller — still answers. Asserted against the real function
# with EUID forced to 0 via a subshell that cannot actually setuid, so grade the
# COMPONENT: _envelope_sender_fallback must yield empty for uid 0.
root_side="$(awk -F: '$3==0{print $1; exit}' /etc/passwd)"
[[ "$root_side" != agent-* ]] \
  && ok_t "T6c uid 0 ('$root_side') is not agent-* — EUID branch yields empty as root, so _deliver still resolves via SUDO_USER" \
  || bad_t 'T6c uid 0 resolves as an agent — the scoped path would change behaviour' "root_side='$root_side'"

echo "-----"
echo "envelope_sender_fallback_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
