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
if grep -q 'envelope_tier "\$_dcaller"' "$SRC" && grep -q '_dcaller="\$(auto_sender_from_sudo)"' "$SRC"; then
  ok_t 'T5 tier= is computed from the same resolved caller as from='
else
  bad_t 'T5 tier= recomputes its own caller — from= and tier= can disagree' \
        "$(grep -n 'envelope_tier' "$SRC" | head -3)"
fi

# --- T6 the fallback is ONLY reached when sudo yields nothing -----------------
grep -q '\[\[ -n "\$sender" \]\] || sender="\$(_envelope_sender_fallback)"' "$SRC" \
  && ok_t 'T6 fallback runs ONLY when auto_sender_from_sudo is empty (sudo path unchanged)' \
  || bad_t 'T6 the fallback is not gated behind the sudo resolver' ''

echo "-----"
echo "envelope_sender_fallback_unit: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
