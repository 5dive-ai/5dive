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
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT   # DIVE-2692: fires on every exit path (incl. SKIP/precondition-fail early-exits); folds in tempdir cleanup so the two EXIT traps don't clobber each other.
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/agent-iso-unit.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# create_agent_user/write_admin_sudoers live in cmd_agent_create.sh and
# cmd_restart in cmd_agent_lifecycle.sh (split out of cmd_agent.sh); source the
# function defs (none have top-level side effects at source time).
# shellcheck source=/dev/null
source "$SRC/cmd_agent.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"
# shellcheck source=/dev/null
source "$SRC/cmd_agent_lifecycle.sh"

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
  # DIVE-1088: only bare-trailing-`*` (any-args) forms — sudo-rs (Ubuntu 26.04's
  # default) rejects wildcards INSIDE a command argument, so the old raw
  # `systemctl ... 5dive-agent@*` / `5dive-*.service` lines broke `agent create`
  # there. Mirror the retired shape too so we can assert visudo-rs rejects it.
  cat > "$SFILE" <<SUD
${user} ALL=(root) NOPASSWD: /usr/local/bin/5dive, /usr/local/bin/5dive *
SUD
  if visudo -cf "$SFILE" >/dev/null 2>&1; then
    ok_t "scoped admin sudoers passes visudo -c"
  else
    bad_t "scoped admin sudoers visudo" "$(visudo -cf "$SFILE" 2>&1)"
  fi
  # DIVE-1088: the generated file must also pass sudo-rs's visudo-rs when present
  # (Ubuntu 26.04). The retired embedded-wildcard shape must FAIL it — that was
  # the bug. Skipped where visudo-rs is unavailable (e.g. Ubuntu <=24.04).
  if command -v visudo-rs >/dev/null 2>&1; then
    if visudo-rs -cf "$SFILE" >/dev/null 2>&1; then
      ok_t "scoped admin sudoers passes visudo-rs (sudo-rs / Ubuntu 26.04)"
    else
      bad_t "scoped admin sudoers visudo-rs" "$(visudo-rs -cf "$SFILE" 2>&1 | tail -2)"
    fi
    OLDF="$TMP/sudoers-old"
    printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart 5dive-agent@*\n' "$user" > "$OLDF"
    if visudo-rs -cf "$OLDF" >/dev/null 2>&1; then
      # 0.2.x (24.04) is permissive; 0.2.13 (26.04) rejects. Don't fail the suite
      # on the permissive build — just note it so the guard's intent is on record.
      echo "# note: this visudo-rs build accepts embedded arg-wildcards (pre-0.2.13); the 26.04 build rejects them"
    else
      ok_t "visudo-rs REJECTS the retired embedded-wildcard systemctl grant (reproduces DIVE-1088)"
    fi
  else
    echo "# visudo-rs not present; skipping sudo-rs (Ubuntu 26.04) shape asserts"
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
  # Assert against the REAL generated body in src/cmd_agent_create.sh, not just SFILE.
  BODY=$(sed -n '/^write_admin_sudoers()/,/^}/p' src/cmd_agent_create.sh)
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
  # DIVE-1088: no raw systemctl grant, and NO wildcard inside a command argument
  # (the exact construct sudo-rs rejects). Service lifecycle goes through the CLI.
  if grep -q 'systemctl' <<<"$BODY"; then
    bad_t "admin sudoers must NOT grant raw systemctl (DIVE-1088 sudo-rs compat)" ""
  else
    ok_t "admin sudoers grants no raw systemctl (routes via 5dive CLI / _svc)"
  fi
  if grep -qE '@\*|\*\.service' <<<"$BODY"; then
    bad_t "admin sudoers must have NO embedded-argument wildcard (sudo-rs rejects)" ""
  else
    ok_t "admin sudoers has no embedded-argument wildcard (sudo-rs valid)"
  fi
else
  echo "# visudo not present; skipping sudoers shape asserts"
fi

# ---- 2b. crew refuses root (invariant: no sudo 5dive subcmd execs as root) ---
CREW_BODY=$(sed -n '/^cmd_crew()/,/^  case/p' src/cmd_crew.sh)
grep -q 'id -u.*== *"0"' <<<"$CREW_BODY" && grep -q 'E_PERMISSION' <<<"$CREW_BODY" \
  && ok_t "cmd_crew refuses to run as root (blocks admin->root via crew exec)" \
  || bad_t "cmd_crew root guard" "expected an EUID-0 refusal in cmd_crew"

# ---- 2c. agent restart --defer runs a FIXED command, not caller-injected -----
RESTART_BODY=$(sed -n '/^cmd_restart()/,/^}/p' src/cmd_agent_lifecycle.sh)
grep -q 'restart "5dive-agent@\${name}.service"' <<<"$RESTART_BODY" \
  && ! grep -qE '\--defer.*\$\{?[0-9]|defer.*eval' <<<"$RESTART_BODY" \
  && ok_t "restart --defer wraps a FIXED systemctl restart (no caller-injected cmd)" \
  || bad_t "restart --defer fixed command" "deferred command must not be caller-templated"

# ---- 2d. DIVE-1813: standard agent self-restart grant + primitive ------------
# The scoped standard sudoers must grant EXACTLY `5dive agent _self_restart`
# (no args, no wildcard) so /model + /restart work, and the primitive must
# derive its target from SUDO_USER (never argv) so it can only restart itself.
if command -v visudo >/dev/null 2>&1; then
  STDF="$TMP/standard.sudoers"
  render_standard_sudoers "agent-foo" 0 > "$STDF"
  visudo -cf "$STDF" >/dev/null 2>&1 \
    && ok_t "scoped standard sudoers passes visudo -c" \
    || bad_t "standard sudoers visudo" "$(visudo -cf "$STDF" 2>&1)"
  grep -qF 'NOPASSWD: /usr/local/bin/5dive agent _self_restart' "$STDF" \
    && ok_t "standard sudoers grants self-restart (fixes /model + /restart)" \
    || bad_t "standard sudoers self-restart grant" "missing _self_restart line"
  # The grant must be exact-path/no-arg: no wildcard, no unit target on the line.
  if grep -E '_self_restart' "$STDF" | grep -qE '\*|5dive-agent@'; then
    bad_t "self-restart grant must be exact (no wildcard / no unit target)" ""
  else
    ok_t "self-restart grant is exact-path, no wildcard, no argv target"
  fi
  # sudo-rs compat when available (Ubuntu 26.04 rejects embedded arg-wildcards).
  if command -v visudo-rs >/dev/null 2>&1; then
    visudo-rs -cf "$STDF" >/dev/null 2>&1 \
      && ok_t "standard sudoers passes visudo-rs (sudo-rs / Ubuntu 26.04)" \
      || bad_t "standard sudoers visudo-rs" "$(visudo-rs -cf "$STDF" 2>&1 | tail -2)"
  fi
fi
# The primitive derives target from SUDO_USER (not argv) and refuses extra args.
SELF_BODY=$(sed -n '/^cmd_self_restart()/,/^}/p' src/cmd_agent_lifecycle.sh)
grep -q 'SUDO_USER' <<<"$SELF_BODY" \
  && ok_t "cmd_self_restart derives target from SUDO_USER (not argv)" \
  || bad_t "self-restart SUDO_USER derivation" "must not trust argv for the unit"
grep -q 'takes no arguments' <<<"$SELF_BODY" \
  && ok_t "cmd_self_restart refuses caller-supplied arguments" \
  || bad_t "self-restart arg refusal" "must reject any argv"
grep -q 'require_root' <<<"$SELF_BODY" \
  && ok_t "cmd_self_restart requires root (reachable only via NOPASSWD grant)" \
  || bad_t "self-restart require_root" ""
# A non-agent-* / root / empty SUDO_USER must be refused (self-only guarantee).
grep -qE 'agent-\(\[A-Za-z0-9_\.-\]\+\)|!= *"root"' <<<"$SELF_BODY" \
  && ok_t "cmd_self_restart refuses non-agent-* / root / empty SUDO_USER" \
  || bad_t "self-restart caller guard" "must reject non-agent-*/root/empty callers"

# ---- 2d. cmd_svc: 5dive-only unit scope + no-exec invariant (DIVE-1088) -------
# The hardened replacement for the retired raw `systemctl 5dive-*` sudoers grant.
# It runs a FIXED systemctl and must never exec caller-controlled input.
SVC_BODY=$(sed -n '/^cmd_svc()/,/^}/p' src/cmd_agent_runtime.sh)
grep -q 'require_root' <<<"$SVC_BODY" \
  && ok_t "cmd_svc requires root" || bad_t "cmd_svc require_root" "must gate on root"
grep -q -- '--no-pager' <<<"$SVC_BODY" \
  && ok_t "cmd_svc runs systemctl --no-pager (no pager -> !sh escape)" \
  || bad_t "cmd_svc --no-pager" "must pass --no-pager"
if grep -qE '\beval\b|sh -c|\$\(' <<<"$SVC_BODY"; then
  bad_t "cmd_svc must NOT exec caller-controlled input" "found eval/sh -c/command-subst"
else
  ok_t "cmd_svc never execs caller-controlled input"
fi
# Functional: mirror cmd_svc's action + unit gates (keep in sync with the source).
svc_action_ok() { case "$1" in start|stop|restart) return 0;; *) return 1;; esac; }
UNIT_RE='^5dive-(agent@)?[A-Za-z0-9_.-]+(\.service)?$'
for good in '5dive-agent@dev' '5dive-agent@dev.service' '5dive-team-bot-listener.service' '5dive-warm-pool.service'; do
  [[ "$good" =~ $UNIT_RE ]] && ok_t "cmd_svc accepts 5dive unit '$good'" \
    || bad_t "cmd_svc accepts '$good'" "should match"
done
for bad in 'sshd' 'nginx.service' '5dive-agent@dev; rm -rf /' '../../etc/x' '-H' '5dive foo' 'systemd-run'; do
  [[ "$bad" =~ $UNIT_RE ]] && bad_t "cmd_svc must REJECT '$bad'" "matched but should not" \
    || ok_t "cmd_svc rejects non-5dive/malformed unit '$bad'"
done
for act in edit mask 'restart;bash' status; do
  svc_action_ok "$act" && bad_t "cmd_svc must REJECT action '$act'" "only start|stop|restart" \
    || ok_t "cmd_svc rejects non-lifecycle action '$act'"
done

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

# ---- 4. DIVE-3294: the home is minted traversable, non-sandboxed ONLY -------
# Structural first: ONE `!= sandboxed` predicate must decide group membership AND
# home traversal. A second one is exactly how a sandboxed agent ends up
# group-claude on one path and closed on the other with nothing failing loudly.
# (The `== "sandboxed"` at the setfacl block is a DIFFERENT policy — DIVE-1033's
# traverse grant on /home/claude — and is deliberately not counted here.)
ISO_BODY="$(declare -f create_agent_user)"
n_ne=$(grep -c '!= "sandboxed"' <<<"$ISO_BODY")
[[ "$n_ne" -eq 1 ]] \
  && ok_t "create_agent_user: exactly ONE '!= sandboxed' predicate gates group + home" \
  || bad_t "one predicate must decide group membership and home traversal" "found $n_ne '!= sandboxed' tests; a second one will drift from the first"

# Behavioural. Stub only the root-requiring externals; chgrp/chmod run for real
# against a temp home, so this grades the effect and not an echoed expectation.
export AGENT_HOME_ROOT="$TMP/homes"
mkdir -p "$AGENT_HOME_ROOT"
HOME_MODE_STUB=0700      # the hostile case: chgrp alone would NOT be enough
adduser() { mkdir -p "$AGENT_HOME_ROOT/${!#}"; chmod "$HOME_MODE_STUB" "$AGENT_HOME_ROOT/${!#}"; }
usermod() { :; }
setfacl() { printf '%s\n' "$*" >>"$TMP/setfacl.log"; }
write_admin_sudoers() { :; }
write_standard_sudoers() { :; }
seed_agent_git_identity() { :; }

# A group we are genuinely a member of and that is NOT our primary, so a chgrp is
# observable. Where none exists the group arm cannot run; the MODE arm below still
# does, and the gap is printed rather than passed over.
ISO_PRIMARY="$(id -gn)"; ISO_SHARED=""
for g in $(id -Gn); do [[ "$g" != "$ISO_PRIMARY" ]] && { ISO_SHARED="$g"; break; }; done
export AGENT_SHARED_GROUP="${ISO_SHARED:-$ISO_PRIMARY}"

create_agent_user iso3294std standard >/dev/null 2>&1
STD_HOME="$AGENT_HOME_ROOT/agent-iso3294std"
(( 0$(stat -c '%a' "$STD_HOME") & 0010 )) \
  && ok_t "non-sandboxed home gains g+x (chgrp alone is insufficient at HOME_MODE 0700)" \
  || bad_t "non-sandboxed home must be group-traversable" "mode $(stat -c '%a' "$STD_HOME")"
if [[ -n "$ISO_SHARED" ]]; then
  [[ "$(stat -c '%G' "$STD_HOME")" == "$AGENT_SHARED_GROUP" ]] \
    && ok_t "non-sandboxed home is chgrp'd to the shared group" \
    || bad_t "non-sandboxed home group" "want $AGENT_SHARED_GROUP, got $(stat -c '%G' "$STD_HOME")"
else
  printf 'NOTE - group arm NOT RUN: no secondary group for %s, so a chgrp is unobservable here. Mode arm still graded.\n' "$ISO_PRIMARY"
fi

# The safety property, and it is portable — no group membership needed to grade it.
create_agent_user iso3294box sandboxed >/dev/null 2>&1
BOX_HOME="$AGENT_HOME_ROOT/agent-iso3294box"
[[ "$(stat -c '%a' "$BOX_HOME")" == "700" ]] \
  && ok_t "sandboxed home stays CLOSED (0700) — no traversal granted to anyone" \
  || bad_t "sandboxed home must stay closed" "mode $(stat -c '%a' "$BOX_HOME"), want 700"
[[ "$(stat -c '%G' "$BOX_HOME")" == "$ISO_PRIMARY" ]] \
  && ok_t "sandboxed home is NOT chgrp'd to the shared group" \
  || bad_t "sandboxed home group must be untouched" "got $(stat -c '%G' "$BOX_HOME")"
# Regression guard: the new branch must not have disturbed DIVE-1033's ACL grant.
grep -q 'u:agent-iso3294box:--x' "$TMP/setfacl.log" 2>/dev/null \
  && ok_t "DIVE-1033 traverse-only ACL on /home/claude still granted to sandboxed" \
  || bad_t "sandboxed must still get its DIVE-1033 ACL" "$(cat "$TMP/setfacl.log" 2>/dev/null)"
unset -f adduser usermod setfacl write_admin_sudoers write_standard_sudoers seed_agent_git_identity
unset AGENT_HOME_ROOT AGENT_SHARED_GROUP

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
