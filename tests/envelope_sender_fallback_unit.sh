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

# T6a — THE FORGERY. A caller who exports SUDO_USER must not be able to choose the name.
# Only meaningful when the runner IS an agent-* user; otherwise both sources are empty
# and the arm would pass vacuously, so say which case ran rather than reporting green.
if [[ "$REAL_NAME" == agent-* ]]; then
  forged="$(SUDO_USER=agent-notme _envelope_caller)"
  [[ "$forged" == "${REAL_NAME#agent-}" ]] \
    && ok_t "T6a forged SUDO_USER is IGNORED on the direct path (got '$forged', the real EUID label)" \
    || bad_t 'T6a a forged SUDO_USER chose the envelope sender' "got='$forged' want='${REAL_NAME#agent-}'"
  # T6b — and the old ordering really does produce the forgery, so T6a is not vacuous.
  _legacy_rig="$(mktemp)"
  {
    awk '/^auto_sender_from_sudo\(\) \{/,/^\}/'   "$VSRC"
    awk '/^_envelope_sender_fallback\(\) \{/,/^\}/' "$SRC"
    printf 'x="$(auto_sender_from_sudo)"; [[ -n "$x" ]] || x="$(_envelope_sender_fallback)"; printf "%%s" "$x"\n'
  } > "$_legacy_rig"
  legacy="$(SUDO_USER=agent-notme bash "$_legacy_rig")"
  rm -f "$_legacy_rig"
  [[ "$legacy" == "notme" ]] \
    && ok_t 'T6b ANCHOR: the sudo-first ordering DOES forge (returns the exported name) — T6a is not vacuous' \
    || bad_t 'T6b anchor did not reproduce the forgery — T6a proves nothing' "legacy='$legacy'"
else
  bad_t 'T6a/T6b need an agent-* runner to mean anything' "runner='$REAL_NAME' — NOT-REACHED, not a pass"
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
