#!/usr/bin/env bash
# DIVE-5526 — a partner spare's claim hung in `account set`, and every later
# create and import on the box hung behind it, printing nothing.
#
#   * `account set` runs under the registry lock (main.sh) and, on a box with a
#     sysadmin seat, calls `5dive sysadmin _bind-pending` — a NEW process, whose
#     `agent config` takes the same lock. IN_REGISTRY_LOCK is not exported, so the
#     grandchild waited on its own parent forever (DIVE-5247 moved the call out of
#     process; in process it was re-entrant). Arm a1 runs the REAL
#     cmd_account_set and with_registry_lock, with a fake `5dive` that takes the
#     lock the way the plugin's `agent config` does.
#   * A lock that is never released must fail with a reason, not hang (a2, a3).
set +e -o pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
HOLDER=""
trap 'rc=$?; [[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT

command -v jq >/dev/null && command -v flock >/dev/null || { echo 'SKIP - jq or flock unavailable'; exit 0; }

PASS=0
FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# --- seams: the process-killing `fail`, state checks, the auth write --------
E_USAGE=2; E_VALIDATION=3; E_NOT_FOUND=4; E_CONFLICT=5; E_TIMEOUT=11
export REGISTRY="$TMP/agents.json" REGISTRY_LOCK="$TMP/registry.lock"
echo '{"agents":{"sysadmin":{"pendingAuthProfile":"openrouter"}}}' > "$REGISTRY"

cat > "$TMP/seams.sh" <<'SEAMS'
E_USAGE=2; E_VALIDATION=3; E_NOT_FOUND=4; E_CONFLICT=5; E_TIMEOUT=11
fail() { printf '%s\n' "$2" >&2; exit "$1"; }
ensure_state() { :; }
SEAMS
. "$TMP/seams.sh"
. "$ROOT/src/lib/registry.sh"
. "$ROOT/src/cmd_account.sh" 2>/dev/null
valid_profile_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
is_known_type() { [[ "$1" == claude ]]; }
audit_log() { :; }
cmd_auth_set() { :; }

# A `5dive` that does what `sysadmin _bind-pending` -> `agent config` does: take
# the registry lock in a new process, then record what it saw.
cat > "$TMP/fake5dive" <<FAKE
#!/usr/bin/env bash
. "$TMP/seams.sh"
. "$ROOT/src/lib/registry.sh"
bound() { echo "bound in=\${IN_REGISTRY_LOCK:-unset} stdin=\$(readlink /proc/\$\$/fd/0)" > "$TMP/child.log"; }
with_registry_lock bound
FAKE
chmod +x "$TMP/fake5dive"
export FIVEDIVE_SELF_BIN="$TMP/fake5dive"

# a1: the claim's key write on a box with a sysadmin seat finishes and binds it.
# Pre-fix it never returns: `timeout` stands in for shelld's 60 s kill.
export FIVEDIVE_REGISTRY_LOCK_WAIT=8
start=$SECONDS
echo 'sk-or-v1-fake' | timeout 20 bash -c '
  . "$1/seams.sh"; . "$2/src/lib/registry.sh"; . "$2/src/cmd_account.sh" 2>/dev/null
  valid_profile_name() { :; }; is_known_type() { :; }; audit_log() { :; }; cmd_auth_set() { read -r _; }
  with_registry_lock cmd_account_set openrouter --type=claude --provider=openrouter --api-key=- --replace
' _ "$TMP" "$ROOT"
rc=$?; took=$((SECONDS - start))
if [[ $rc -eq 0 && $took -lt 5 ]] && grep -q '^bound in=1 ' "$TMP/child.log" 2>/dev/null; then
  ok_t "a1 account set under the lock binds the waiting seat through a child process, in ${took}s"
else
  bad_t "a1 account set deadlocked on its own child (rc=$rc, ${took}s)" "$(cat "$TMP/child.log" 2>/dev/null || echo 'child never got the lock')"
fi
grep -q 'stdin=/dev/null' "$TMP/child.log" 2>/dev/null \
  && ok_t "a1b the child does not inherit the caller's stdin (the key's pipe)" \
  || bad_t "a1b the child inherited stdin" "$(cat "$TMP/child.log" 2>/dev/null)"

# a2: a lock nobody releases fails within the wait and says who has it open.
( flock -x 9; sleep 60 ) 9>"$REGISTRY_LOCK" &
HOLDER=$!
sleep 0.5
noop() { echo ran; }
start=$SECONDS
out="$(FIVEDIVE_REGISTRY_LOCK_WAIT=1 timeout 20 bash -c '. "$1/seams.sh"; . "$2/src/lib/registry.sh"; noop() { echo ran; }; with_registry_lock noop' _ "$TMP" "$ROOT" 2>&1)"
rc=$?; took=$((SECONDS - start))
if [[ $rc -eq $E_TIMEOUT && $took -lt 5 && "$out" == *"not released in 1s"* && "$out" != *ran* ]]; then
  ok_t "a2 a held lock fails in ${took}s with E_TIMEOUT and runs nothing"
else
  bad_t "a2 a held lock: rc=$rc in ${took}s" "$out"
fi
[[ "$out" == *"sleep 60"* || "$out" == *"flock"* || "$out" == *"bash"* ]] \
  && ok_t "a3 the refusal names a process that has the lock open" \
  || bad_t "a3 no holder named" "$out"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""

# a4: a free lock is taken at once and the function runs (no regression).
out="$(timeout 10 bash -c '. "$1/seams.sh"; . "$2/src/lib/registry.sh"; noop() { echo ran; }; with_registry_lock noop' _ "$TMP" "$ROOT" 2>&1)"
[[ "$out" == ran ]] && ok_t "a4 a free lock runs the function" || bad_t "a4 free lock" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
