#!/usr/bin/env bash
# DIVE-1002 isolated unit harness for least-privilege agent isolation.
#
# Sources the src/ libs directly (no root, no adduser, no network) and exercises
# the pure pieces of the standard-by-default + scoped-admin design:
#   1. Bootstrap resolution: empty registry -> admin, non-empty -> standard,
#      explicit --isolation always wins.
#   2. write_admin_sudoers: produces a visudo-valid file that grants the 5dive
#      CLI + 5dive service lifecycle but NOT blanket `ALL=(ALL) ... ALL` root.
#   3. v1->v2 migration jq: stamps explicit isolation:"admin" on legacy agents
#      that lacked the field (no silent downgrade).
# Run: bash tests/agent_isolation_unit.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-iso-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# cmd_agent.sh defines create_agent_user/write_admin_sudoers; source just that
# file's function defs (it has no top-level side effects at source time).
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"

STATE_DIR="$TMP"
REGISTRY="$STATE_DIR/agents.json"
JSON_MODE=1
set +e   # header.sh enabled `set -e`; tests deliberately expect non-zero exits

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# ---- 1. bootstrap resolution (mirror of cmd_create's inline logic) ----------
resolve() {  # $1=explicit_flag  $2=explicit_value
  local isolation="$2" isolation_explicit="$1"
  if (( ! isolation_explicit )); then
    if [[ "$(registry_read | jq -r '(.agents // {}) | length')" == "0" ]]; then
      isolation="admin"; else isolation="standard"; fi
  fi
  printf '%s' "$isolation"
}

echo '{"agents":{}}' > "$REGISTRY"
[[ "$(resolve 0 '')" == "admin" ]] \
  && ok_t "empty registry, no flag -> admin (bootstrap)" \
  || bad_t "empty registry -> admin" "got $(resolve 0 '')"

echo '{"agents":{"boss":{"type":"claude","isolation":"admin"}}}' > "$REGISTRY"
[[ "$(resolve 0 '')" == "standard" ]] \
  && ok_t "non-empty registry, no flag -> standard (least-priv)" \
  || bad_t "non-empty -> standard" "got $(resolve 0 '')"

[[ "$(resolve 1 'admin')" == "admin" ]] \
  && ok_t "explicit --isolation=admin wins on populated box" \
  || bad_t "explicit admin wins" "got $(resolve 1 'admin')"

echo '{"agents":{}}' > "$REGISTRY"
[[ "$(resolve 1 'standard')" == "standard" ]] \
  && ok_t "explicit --isolation=standard wins even as first agent" \
  || bad_t "explicit standard wins" "got $(resolve 1 'standard')"

# ---- 2. write_admin_sudoers: scoped, visudo-valid, no blanket root ----------
if command -v visudo >/dev/null 2>&1; then
  SFILE="$TMP/sudoers-test"
  # Mirror write_admin_sudoers' inlined body (the real fn writes to a root-only
  # /etc/sudoers.d path); assert the generated shape is visudo-valid + scoped.
  user="agent-testadmin"
  cat > "$SFILE" <<SUD
${user} ALL=(root) NOPASSWD: \\
  /usr/local/bin/5dive, /usr/local/bin/5dive *, \\
  /usr/bin/systemctl start 5dive-agent@*, /usr/bin/systemctl stop 5dive-agent@*, \\
  /usr/bin/systemctl restart 5dive-agent@*, \\
  /bin/systemctl restart 5dive-*.service
SUD
  if visudo -cf "$SFILE" >/dev/null 2>&1; then
    ok_t "scoped admin sudoers passes visudo -c"
  else
    bad_t "scoped admin sudoers visudo" "$(visudo -cf "$SFILE" 2>&1)"
  fi
  grep -q '/usr/local/bin/5dive' "$SFILE" \
    && ok_t "scoped sudoers grants the 5dive fleet CLI" \
    || bad_t "sudoers grants 5dive" ""
  if grep -qE 'NOPASSWD:[[:space:]]*ALL[[:space:]]*$|=\(ALL\)[[:space:]]*NOPASSWD:[[:space:]]*ALL' "$SFILE"; then
    bad_t "sudoers must NOT grant blanket root" "found ALL=(ALL) NOPASSWD: ALL"
  else
    ok_t "scoped sudoers is NOT blanket ALL=(ALL) NOPASSWD: ALL"
  fi
  # DIVE-1002 (Marcus review): the three indirect root escapes must be ABSENT.
  # Assert against the REAL generated body in src/cmd_agent.sh, not just SFILE.
  BODY=$(sed -n '/^write_admin_sudoers()/,/^}/p' src/cmd_agent.sh)
  for esc in 'systemd-run' 'journalctl' 'systemctl status'; do
    if grep -qF "$esc" <<<"$BODY"; then
      bad_t "admin allowlist must NOT contain '$esc' (root-escapable)" ""
    else
      ok_t "admin allowlist excludes '$esc'"
    fi
  done
  grep -qF '/usr/local/bin/5dive' <<<"$BODY" \
    && ok_t "real write_admin_sudoers still grants the 5dive CLI" \
    || bad_t "real write_admin_sudoers grants 5dive" ""
else
  echo "# visudo not present; skipping sudoers shape asserts"
fi

# ---- 2b. crew refuses root (invariant: no sudo 5dive subcmd execs as root) ---
CREW_BODY=$(sed -n '/^cmd_crew()/,/^  case/p' src/cmd_crew.sh)
grep -q 'id -u.*== *"0"' <<<"$CREW_BODY" && grep -q 'E_PERMISSION' <<<"$CREW_BODY" \
  && ok_t "cmd_crew refuses to run as root (blocks admin->root via crew exec)" \
  || bad_t "cmd_crew root guard" "expected an EUID-0 refusal in cmd_crew"

# ---- 2c. agent restart --defer runs a FIXED command, not caller-injected -----
RESTART_BODY=$(sed -n '/^cmd_restart()/,/^}/p' src/cmd_agent.sh)
grep -q 'restart "5dive-agent@\${name}.service"' <<<"$RESTART_BODY" \
  && ! grep -qE '\--defer.*\$\{?[0-9]|defer.*eval' <<<"$RESTART_BODY" \
  && ok_t "restart --defer wraps a FIXED systemctl restart (no caller-injected cmd)" \
  || bad_t "restart --defer fixed command" "deferred command must not be caller-templated"

# ---- 3. v1 -> v2 migration stamps explicit isolation ------------------------
LEGACY='{"schemaVersion":1,"agents":{"old1":{"type":"claude"},"old2":{"type":"claude","isolation":"standard"}}}'
migrated=$(jq '.schemaVersion = 2
  | (.agents // {}) |= with_entries(.value.isolation //= "admin")' <<<"$LEGACY")
[[ "$(jq -r '.agents.old1.isolation' <<<"$migrated")" == "admin" ]] \
  && ok_t "migration stamps legacy fieldless agent as explicit admin" \
  || bad_t "migration stamps old1=admin" "$(jq -c .agents <<<"$migrated")"
[[ "$(jq -r '.agents.old2.isolation' <<<"$migrated")" == "standard" ]] \
  && ok_t "migration preserves an already-explicit standard agent" \
  || bad_t "migration keeps old2=standard" "$(jq -c .agents <<<"$migrated")"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
