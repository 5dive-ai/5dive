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
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# --- ground truth, independent of the code under test -----------------------
REAL_UID=$(awk '/^Uid:/{print $2; exit}' /proc/self/status)
REAL_NAME=$(awk -F: -v u="$REAL_UID" '$3==u{print $1; exit}' /etc/passwd)
EXPECT=""; [[ "$REAL_NAME" == agent-* ]] && EXPECT="${REAL_NAME#agent-}"

# --- load ONLY the resolver pair, not the whole CLI --------------------------
eval "$(sed -n '/^_gate_uid_to_agent()/,/^}/p'        src/cmd_task.sh)"
eval "$(sed -n '/^_gate_caller_uid()/,/^}/p'          src/cmd_task.sh)"
eval "$(sed -n '/^_gate_authenticated_actor()/,/^}/p' src/cmd_task.sh)"

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
  ok "skipped identity arm — this runner is not an agent-* user (uid $REAL_UID)"
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

printf '\ngate_actor_path_forgery_unit: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
