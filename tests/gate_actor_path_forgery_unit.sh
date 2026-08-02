#!/usr/bin/env bash
# DIVE-2330 — `_gate_authenticated_actor` authorizes the lead-clear of
# approval/manual/access gates by comparing its return to `routed_reviewer`. It
# must therefore be UNFORGEABLE by the caller it is checking.
#
# It was not. `id -un` and `getent` both resolve through the CALLER'S PATH, and
# every agent sets its own PATH. These arms run the REAL substitution and demand
# the real identity back.
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
# returns empty for every uid and arms 1-3 pass vacuously (the same way
# `_gate_passwd_stream` had to be added in iteration 2).
eval "$(sed -n '/^_gate_passwd_stream()/,/^}/p'        src/lib/actor.sh)"
eval "$(sed -n '/^_gate_is_root()/,/^}/p'             src/lib/actor.sh)"
eval "$(sed -n '/^actor_uid_to_name()/,/^}/p'         src/lib/actor.sh)"
eval "$(sed -n '/^_gate_uid_to_agent()/,/^}/p'        src/lib/actor.sh)"
eval "$(sed -n '/^_gate_caller_uid()/,/^}/p'          src/lib/actor.sh)"
eval "$(sed -n '/^_gate_authenticated_actor()/,/^}/p' src/lib/actor.sh)"
for _f in _gate_passwd_stream _gate_is_root actor_uid_to_name _gate_uid_to_agent _gate_caller_uid _gate_authenticated_actor; do
  declare -F "$_f" >/dev/null || { printf 'NOT OK - %s did not load; the arms below would be vacuous\n' "$_f"; exit 1; }
done

SHIM=$(mktemp -d)
printf '#!/bin/sh\necho agent-lodar\n'  > "$SHIM/id";     chmod +x "$SHIM/id"
printf '#!/bin/sh\necho agent-lodar:x:0:0:::\n' > "$SHIM/getent"; chmod +x "$SHIM/getent"
trap 'rm -rf "$SHIM"' EXIT

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

printf '\ngate_actor_path_forgery_unit: %d passed, %d failed, %d skipped (runner %s, uid %s)\n' \
  "$PASS" "$FAIL" "$SKIP" "${REAL_NAME:-?}" "$REAL_UID"
[ "$FAIL" -eq 0 ]
