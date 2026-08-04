#!/usr/bin/env bash
# DIVE-2330 — `_gate_authenticated_actor` authorizes the lead-clear of
# approval/manual/access gates by comparing its return to `routed_reviewer`. It
# must therefore be UNFORGEABLE by the caller it is checking.
#
# It was not. `id -un` and `getent` both resolve through the CALLER'S PATH, and
# every agent sets its own PATH. These arms run the REAL substitution and demand
# the real identity back.
#
# DIVE-2383 extends this harness rather than adding a sibling, because the defect is
# the SAME defect at three more resolvers that DIVE-2330 correctly left out of scope
# (none of them authorizes anything):
#   * `_gate_caller_user`        — the audit log's `caller=` field, our non-refusal sink.
#   * `_gate_closure_subject_uid` — the DIVE-756 SIGNED closure subject. This one is
#     worse than an unsigned wrong value: the signature attests the forgery, so
#     `gate-proof verify` reports a forged subject as INTACT.
#   Both compose over DIVE-2517's `actor_uid_to_name` (src/lib/actor.sh), the
#   pure-bash passwd resolver — not a second walk of their own.
# Every arm below carries its own VACUITY ANCHOR proving the pre-fix expression IS
# forged by the very same shim, because an arm that only checks the new code cannot
# tell a fix from a coincidence.
#
# GROUND TRUTH IS TAKEN WITHOUT THE FUNCTION UNDER TEST: the expected name comes
# from /proc/self/status's real uid resolved against /etc/passwd by awk, never
# from `id` and never from the resolver being graded.
# Run: bash tests/gate_actor_path_forgery_unit.sh   (no root, no network)
set -uo pipefail

# DIVE-2211 / DIVE-2286: name the tree this harness grades. Sourced BEFORE the cd
# so ${BASH_SOURCE[0]} still resolves relative to tests/. Three-state on purpose:
# if the helper is unreachable the log says NO TREE WAS NAMED rather than falling
# silent. Deliberately NO `2>/dev/null` on the source line — redirecting it also
# swallows the helper's own stderr line, which IS the payload, and that is what
# silenced all 210 harnesses at once.
#
# This harness shipped WITHOUT this line and names_the_tree_contract_unit caught
# it in CI (dev, on DIVE-2330 iteration 3). Worth the note: a harness added to fix
# a naming-blindness defect was itself naming no tree.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${SHIM:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
# A skip is NOT a pass (iteration 2, dev): on a non-agent runner one of the five
# "passed" was a skipped arm printed as ok, which inflates a green log.
skip(){ SKIP=$((SKIP+1)); printf 'skip - %s\n' "$1"; }

# --- ground truth, independent of the code under test -----------------------
REAL_UID=$(awk '/^Uid:/{print $2; exit}' /proc/self/status)
REAL_NAME=$(awk -F: -v u="$REAL_UID" '$3==u{print $1; exit}' /etc/passwd)
EXPECT=""; [[ "$REAL_NAME" == agent-* ]] && EXPECT="${REAL_NAME#agent-}"

# --- load ONLY the resolver pair, not the whole CLI --------------------------
# `_gate_is_root` and `_gate_passwd_stream` are NOT optional (iteration 2, dev):
# `_gate_authenticated_actor` calls `_gate_is_root`, and without it the SUDO_UID
# branch was graded against a missing function — bash printed
# `_gate_is_root: command not found` twice and the branch was never exercised.
# `_gate_uid_to_agent` now reads its passwd source through `_gate_passwd_stream`,
# so that must load too or the resolver returns empty for every uid and arms 1-3
# pass vacuously.
# DIVE-2517: these six MOVED from src/cmd_task.sh to src/lib/actor.sh when the
# strict uid-first derivation was promoted to the single one. Same names, same
# bodies — only the file changed. `actor_uid_to_name` is NOT optional: it is the
# passwd walk `_gate_uid_to_agent` now composes over, and without it the resolver
# returns empty for every uid and arms 1-3 pass vacuously.
#
# DIVE-2383 adds the last two to that SAME file. Its original form defined a third,
# `actor_uid_to_name`, in cmd_task.sh — dropped because DIVE-2517's
# `actor_uid_to_name` IS that function, arrived at independently. actor.sh's own
# comment gives the reason not to add a second: "one passwd walk in the tree rather
# than two that can drift."
eval "$(sed -n '/^_gate_passwd_stream()/,/^}/p'         src/lib/actor.sh)"
eval "$(sed -n '/^_gate_is_root()/,/^}/p'              src/lib/actor.sh)"
eval "$(sed -n '/^actor_uid_to_name()/,/^}/p'          src/lib/actor.sh)"
eval "$(sed -n '/^_gate_uid_to_agent()/,/^}/p'         src/lib/actor.sh)"
eval "$(sed -n '/^_gate_caller_uid()/,/^}/p'           src/lib/actor.sh)"
eval "$(sed -n '/^_gate_authenticated_actor()/,/^}/p'  src/lib/actor.sh)"
eval "$(sed -n '/^_gate_caller_user()/,/^}/p'          src/lib/actor.sh)"
eval "$(sed -n '/^_gate_closure_subject_uid()/,/^}/p'  src/lib/actor.sh)"
for _f in _gate_passwd_stream _gate_is_root actor_uid_to_name _gate_uid_to_agent _gate_caller_uid \
          _gate_authenticated_actor _gate_caller_user _gate_closure_subject_uid; do
  declare -F "$_f" >/dev/null || { printf 'NOT OK - %s did not load; the arms below would be vacuous\n' "$_f"; exit 1; }
done

SHIM=$(mktemp -d)
# `id -u` must forge a NUMERIC uid too — DIVE-2383's closure-subject arm abuses
# `id -u`, not `id -un`. Dispatching on the flag keeps arms 1-4 byte-identical.
printf '#!/bin/sh\ncase "$1" in\n  -u) echo 4242 ;;\n  *)  echo agent-lodar ;;\nesac\n' > "$SHIM/id"; chmod +x "$SHIM/id"
printf '#!/bin/sh\necho agent-lodar:x:0:0:::\n' > "$SHIM/getent"; chmod +x "$SHIM/getent"

got_clean=$(_gate_authenticated_actor)
got_shim=$(PATH="$SHIM:$PATH" _gate_authenticated_actor)

# 1. A hostile PATH must not change the answer.
[[ "$got_shim" == "$got_clean" ]] \
  && ok "a PATH shim cannot change the authenticated actor" \
  || no "PATH shim changed the actor: clean='$got_clean' shimmed='$got_shim'"

# 2. And the answer must be the REAL identity, not merely stable.
if [[ -n "$EXPECT" ]]; then
  [[ "$got_shim" == "$EXPECT" ]] \
    && ok "under a hostile PATH the resolver still returns the kernel identity ($EXPECT)" \
    || no "expected '$EXPECT' from /proc+/etc/passwd, got '$got_shim'"
else
  skip "identity arm — this runner is not an agent-* user (uid $REAL_UID, name '$REAL_NAME')"
fi

# 3. It must never return the forged name.
[[ "$got_shim" != "lodar" ]] \
  && ok "the forged name is never returned" \
  || no "resolver returned the FORGED identity 'lodar'"

# 4. VACUITY ANCHOR: the old implementation must take arm 1 or 3 RED. If this
#    arm fails, arms 1-3 prove nothing and the harness is decoration.
_old_actor() {
  local u; u=$(id -un 2>/dev/null || echo '')
  if [[ "$u" == agent-* ]]; then printf '%s' "${u#agent-}"; return; fi
  printf ''
}
old_shim=$(PATH="$SHIM:$PATH" _old_actor)
[[ "$old_shim" == "lodar" ]] \
  && ok "ANCHOR: the pre-fix bare 'id -un' IS forged by the same shim (returns 'lodar')" \
  || no "ANCHOR FAILED — the shim did not forge the old implementation (got '$old_shim'); these arms are vacuous"

# 5. Numeric-only contract on the pure-bash resolver.
[[ -z "$(_gate_uid_to_agent 'not-a-uid')" ]] \
  && ok "a non-numeric uid resolves to empty (fails closed)" \
  || no "non-numeric uid did not fail closed"

# --- DIVE-2383: the audit `caller=` field ------------------------------------
# Ground truth is REAL_NAME straight from /proc + /etc/passwd via awk. Note this arm
# needs no agent-* precondition: unlike the actor resolver, `caller=` must name
# `claude` and `root` too, which is exactly why actor_uid_to_name exists alongside
# _gate_uid_to_agent.
caller_clean=$(_gate_caller_user)
caller_shim=$(PATH="$SHIM:$PATH" _gate_caller_user)

# 6. A hostile PATH must not change the logged caller, and it must be the real name.
if [[ "$caller_shim" == "$caller_clean" && "$caller_shim" == "$REAL_NAME" ]]; then
  ok "the audit caller= survives a hostile PATH and names the kernel identity ($REAL_NAME)"
else
  no "caller= forged or wrong: clean='$caller_clean' shimmed='$caller_shim' real='$REAL_NAME'"
fi

# 7. And never the forged name.
[[ "$caller_shim" != "agent-lodar" && "$caller_shim" != "lodar" ]] \
  && ok "the forged caller name is never logged" \
  || no "caller= returned the FORGED identity '$caller_shim'"

# 8. VACUITY ANCHOR for arms 6-7: the pre-fix expression IS forged by this shim.
_old_caller() { id -un 2>/dev/null || echo '?'; }
old_caller_shim=$(PATH="$SHIM:$PATH" _old_caller)
[[ "$old_caller_shim" == "agent-lodar" ]] \
  && ok "ANCHOR: the pre-fix bare 'id -un' logs the forged caller (agent-lodar)" \
  || no "ANCHOR FAILED — shim did not forge the old caller= (got '$old_caller_shim'); arms 6-7 are vacuous"

# --- DIVE-2383: the SIGNED closure subject uid --------------------------------
# Two independent forges, because the pre-fix expression had two holes:
#   ${SUDO_UID:-$(id -u)}  ->  an env var below root, AND a PATH-resolved binary.
_old_subject_uid() { printf '%s' "${SUDO_UID:-$(id -u 2>/dev/null || echo "")}"; }

if _gate_is_root; then
  # At EUID 0 SUDO_UID is written by sudo and is TRUSTED by design — the fix keeps
  # that branch. Skipping rather than passing: this runner cannot exercise the hole.
  skip "closure-subject arms — runner is root (uid $REAL_UID), where SUDO_UID is trusted by design"
  skip "closure-subject SUDO_UID anchor — same reason"
else
  # 9. Forged SUDO_UID + hostile PATH must not move the signed subject.
  subj=$(SUDO_UID=4242 PATH="$SHIM:$PATH" _gate_closure_subject_uid)
  [[ "$subj" == "$REAL_UID" ]] \
    && ok "the SIGNED closure subject stays the kernel uid ($REAL_UID) under a forged SUDO_UID and PATH" \
    || no "signed closure subject was moved to '$subj' (expected $REAL_UID)"

  # 10. ANCHOR: the pre-fix expression takes the forged env var.
  old_subj_env=$(SUDO_UID=4242 _old_subject_uid)
  [[ "$old_subj_env" == "4242" ]] \
    && ok "ANCHOR: the pre-fix \${SUDO_UID:-...} signs the forged env uid (4242)" \
    || no "ANCHOR FAILED — forged SUDO_UID did not move the old subject (got '$old_subj_env'); arm 9 is vacuous"

  # 11. ANCHOR: and with SUDO_UID absent it takes the PATH shim instead. Both holes
  #     are real, so both need their own anchor — closing one would otherwise look
  #     like closing the class.
  old_subj_path=$(unset SUDO_UID; PATH="$SHIM:$PATH" _old_subject_uid)
  [[ "$old_subj_path" == "4242" ]] \
    && ok "ANCHOR: with SUDO_UID unset the pre-fix falls back to the PATH-forged 'id -u' (4242)" \
    || no "ANCHOR FAILED — PATH shim did not forge the old subject (got '$old_subj_path'); arm 9 is half-vacuous"
fi

# 12. Numeric-only contract on the new resolver, matching arm 5.
[[ -z "$(actor_uid_to_name 'not-a-uid')" ]] \
  && ok "actor_uid_to_name: a non-numeric uid resolves to empty (fails closed)" \
  || no "actor_uid_to_name did not fail closed on a non-numeric uid"

# 13. And the `?` fallback is reached rather than an empty field, so a uid missing
#     from passwd still writes an attributable row.
_gate_caller_uid_saved=$(declare -f _gate_caller_uid)
_gate_caller_uid() { printf '%s' '4242'; }
[[ "$(_gate_caller_user)" == "?" ]] \
  && ok "an unresolvable uid logs '?' rather than an empty caller= field" \
  || no "unresolvable uid did not fall back to '?' (got '$(_gate_caller_user)')"
eval "$_gate_caller_uid_saved"

printf '\ngate_actor_path_forgery_unit: %d passed, %d failed, %d skipped (runner %s, uid %s)\n' \
  "$PASS" "$FAIL" "$SKIP" "${REAL_NAME:-?}" "$REAL_UID"
[ "$FAIL" -eq 0 ]
