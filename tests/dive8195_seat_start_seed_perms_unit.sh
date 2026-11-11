#!/usr/bin/env bash
# DIVE-8195 unit: EVERY start of a seat re-normalizes the perms of the login it
# seeds from, not only `5dive agent restart`.
#
# teal-fox 2026-11-11: the nightly update restarts seats with a plain
# `systemctl restart`, so normalize_restart_profile_perms (one caller: cmd_restart)
# never ran. Three admin antigravity seats booted on a 0600 token with no seat ACL
# and stayed DEGRADED until a hand restart. The fix is a root `ExecStartPre=-+` on
# the unit template that runs `5dive agent _seed_perms %i`.
#
#   U  the template carries the step, root (+), failure-tolerant (-), bounded,
#      before ExecStart, and systemd parses it
#   D  main.sh routes `_seed_perms` to cmd_agent_seed_perms, outside the registry
#      lock (`agent restart` holds that lock across its synchronous systemctl
#      restart, which runs this step: taking it here would deadlock to timeout)
#   F  cmd_agent_seed_perms: known seat -> normalize for it; unknown/empty -> no-op;
#      a failing normalize never fails the step
#   A  as root (sudo -n; SKIP said out loud without it): a 0600 antigravity token
#      on an account goes 0640 through the real chain, and the shipped agy start
#      block, run as a non-root seat afterwards, seeds it with no ERROR and no
#      breadcrumb. Before the chain runs, the same block leaves the breadcrumb.
#
#   bash tests/dive8195_seat_start_seed_perms_unit.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; [[ -n "${TMP:-}" ]] && { rm -rf "$TMP" 2>/dev/null || sudo -n rm -rf "$TMP" 2>/dev/null; }; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
TMP="$(mktemp -d /tmp/dive8195-unit.XXXXXX)"
chmod 0755 "$TMP"

fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1${2:+ ($2)}"; fail=1; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want=$3 got=$2"; fi; }

UNIT=$(ls systemd/5dive-agent*.service | head -1)
STEP='ExecStartPre=-+/usr/bin/timeout 30 /usr/local/bin/5dive agent _seed_perms %i'

# ---------- U: the template ----------
check "U1 the unit template runs the seed-perms step exactly once" \
      "$(grep -cxF "$STEP" "$UNIT")" 1
pre_ln=$(grep -nxF "$STEP" "$UNIT" | cut -d: -f1)
start_ln=$(grep -n '^ExecStart=' "$UNIT" | cut -d: -f1)
if [[ -n "$pre_ln" && -n "$start_ln" ]] && (( pre_ln < start_ln )); then
  ok "U2 the step sits before ExecStart"
else
  bad "U2 the step sits before ExecStart" "pre=$pre_ln start=$start_ln"
fi
check "U3 no other ExecStartPre can block a start" \
      "$(grep -c '^ExecStartPre=' "$UNIT")" 1
if command -v systemd-analyze >/dev/null 2>&1; then
  # Verify a copy under a concrete instance name. Only the parse of OUR line is
  # graded: a box without the bundle installed reports missing executables for
  # the rest, and that is not this row's to grade.
  inst="${UNIT##*/}"; inst="${inst/.service/x8195.service}"
  mkdir -p "$TMP/units"; cp "$UNIT" "$TMP/units/$inst"
  va=$(cd "$TMP/units" && systemd-analyze verify "./$inst" 2>&1)
  if grep -qiE 'ExecStartPre.*(invalid|failed to parse|unknown)' <<<"$va"; then
    bad "U4 systemd parses the ExecStartPre line" "$va"
  else
    ok "U4 systemd parses the ExecStartPre line"
  fi
else
  echo "SKIP: U4 (no systemd-analyze here)"
fi

# ---------- D: the dispatch ----------
if grep -qE '^ +_seed_perms\) cmd_agent_seed_perms "\$@" ;;$' src/main.sh; then
  ok "D1 main.sh routes agent _seed_perms to cmd_agent_seed_perms, no registry lock"
else
  bad "D1 main.sh routes agent _seed_perms to cmd_agent_seed_perms, no registry lock" \
      "$(grep -n '_seed_perms' src/main.sh)"
fi
fn_body=$(awk '/^cmd_agent_seed_perms\(\) \{/{on=1} on{print} on&&/^}/{exit}' src/cmd_agent_lifecycle.sh)
if [[ -z "$fn_body" ]]; then
  bad "D2 cmd_agent_seed_perms is defined in cmd_agent_lifecycle.sh"
elif grep -qE 'with_registry_lock|registry_lock|flock' <<<"$fn_body"; then
  bad "D2 cmd_agent_seed_perms takes no lock (agent restart holds it across this step)"
else
  ok "D2 cmd_agent_seed_perms takes no lock (agent restart holds it across this step)"
fi

# ---------- F: the function, normalize stubbed ----------
F_OUT=$(bash -c '
  set -uo pipefail
  eval "$1"
  registry_read() { printf "%s" "{\"agents\":{\"agy1\":{\"type\":\"antigravity\",\"authProfile\":\"acme\"}}}"; }
  normalize_restart_profile_perms() { echo "CALL:$1"; return "${NORM_RC:-0}"; }
  cmd_agent_seed_perms agy1;    echo "rc=$?"
  cmd_agent_seed_perms ghost;   echo "rc=$?"
  cmd_agent_seed_perms;         echo "rc=$?"
  NORM_RC=1 cmd_agent_seed_perms agy1; echo "rc=$?"
  registry_read() { return 1; }
  cmd_agent_seed_perms agy1;    echo "rc=$?"
' _ "$fn_body" 2>&1)
check "F1 a known seat is normalized, by name" "$(sed -n 1,2p <<<"$F_OUT" | tr '\n' ' ')" "CALL:agy1 rc=0 "
check "F2 an unknown seat is a no-op" "$(sed -n 3p <<<"$F_OUT")" "rc=0"
check "F3 an empty name is a no-op" "$(sed -n 4p <<<"$F_OUT")" "rc=0"
check "F4 a failing normalize never fails the step" "$(sed -n 5,6p <<<"$F_OUT" | tr '\n' ' ')" "CALL:agy1 rc=0 "
check "F5 an unreadable registry is a no-op" "$(sed -n 7p <<<"$F_OUT")" "rc=0"

# ---------- A: the real chain as root, then the real start block as the seat ----------
ROOT_OK=1
if [[ $EUID -eq 0 ]]; then as_root() { "$@"; }
elif sudo -n true; then as_root() { sudo -n "$@"; }
else ROOT_OK=0
fi
if (( ! ROOT_OK )); then
  echo "SKIP: A arms need root or passwordless sudo (the step runs as root)"
elif [[ $EUID -eq 0 ]]; then
  echo "SKIP: A arms need a non-root uid to play the seat (root reads a 0600 file)"
else
  PROF="$TMP/auth-profiles"
  TOK="$PROF/acme/antigravity/.gemini/antigravity-cli/antigravity-oauth-token"
  mkdir -p "$(dirname "$TOK")"
  echo 'ya29.agy-8195' > "$TOK"
  START=bin/5dive-agent-start
  xfn() { awk -v m="$1() {" 'substr($0,1,length(m))==m { on=1 } on { print } on && $0 == "}" { exit }' "$START"; }
  HELPER=""; for f in assert_cred_seeded cred_seed_breadcrumb_path cred_seed_breadcrumb_write cred_seed_failed cred_seed_ok cred_src_readable cred_seed_why; do HELPER+="$(xfn "$f")"$'\n'; done
  AGY_BLOCK=$(awk -v marker='if [[ "$TYPE" == "antigravity" ]]; then' '$0==marker{on=1} on{print} on&&$0=="fi"{exit}' "$START")
  mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/sudo"; chmod +x "$TMP/bin/sudo"
  SEAT="$TMP/seat-home"; mkdir -p "$SEAT"
  boot_seat() { # the shipped agy block, as this (non-root) uid, sudo refused
    env PATH="$TMP/bin:$PATH" TYPE=antigravity HOME="$SEAT" WORKDIR="$TMP" \
        PROFILE_STATE_DIR="$PROF/acme/antigravity" bash -c "set -uo pipefail
$HELPER
$AGY_BLOCK" 2>&1
  }
  # As the vendor CLI and the nightly left it on teal-fox: a 0600 token under
  # 0700 vendor dirs, owned by someone else (root here stands in for claude).
  # The store and the account dir are 2750 on a box (measured on poke-two), and
  # the normalize leaves them alone, so the fixture does too.
  as_root chown -R 0:0 "$PROF"
  as_root chmod 0600 "$TOK"
  as_root chmod 0700 "$(dirname "$TOK")" "$PROF/acme/antigravity/.gemini" "$PROF/acme/antigravity"
  as_root chmod 0750 "$PROF" "$PROF/acme"
  # The seat reads the account through a group it is in (claude on a box): give
  # the fixture the test uid's primary group, so g+r is exactly the seat's read.
  as_root chgrp -R "$(id -g)" "$PROF"

  out=$(boot_seat)
  check "A0 precondition: before the step, the seat boots on an unreadable token (breadcrumb)" \
        "$( [[ -s "$SEAT/.5dive-cred-seed-failed" ]] && echo yes )" yes

  # The step, as systemd's `+` runs it: root, the real modules, every OS seam
  # (group create, ACL write) pointed at the fixture, never at this box.
  mods=""
  for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/agent_setup.sh \
           lib/state.sh lib/registry.sh lib/codex_login_sync.sh cmd_auth.sh cmd_agent_lifecycle.sh; do
    [[ -f "src/$f" ]] && mods+=" src/$f"
  done
  as_root env AUTH_PROFILES_DIR="$PROF" FIVEDIVE_CLS_LOCK="$TMP/cls.lock" \
      FIVEDIVE_DEFAULT_CRED_HOME="$TMP/no-default-home" MODS="$mods" bash -c '
    set -uo pipefail
    for m in $MODS; do source "$m"; done
    AUTH_PROFILES_DIR="'"$PROF"'"
    declare -A TYPE_AUTH=([codex]="" [grok]="")
    is_known_type() { case "$1" in codex|grok|claude|hermes|openclaw|antigravity) return 0;; *) return 1;; esac; }
    registry_read() { printf %s "{\"agents\":{\"agy1\":{\"type\":\"antigravity\",\"authProfile\":\"acme\"}}}"; }
    _sp_groupadd() { return 1; }
    _sp_seat_readers_sync() { :; }
    secrets_group() { _sp_shared_group; }
    cmd_agent_seed_perms agy1
  ' >"$TMP/step.log" 2>&1
  check "A1 the step leaves the account token 0640 (was 0600)" "$(as_root stat -c %a "$TOK")" 640
  check "A2 ...and its dirs group-traversable" "$(as_root stat -c %a "$(dirname "$TOK")")" 750

  out=$(boot_seat)
  check "A3 the next start seeds the token with no sudo" \
        "$(cat "$SEAT/.gemini/antigravity-cli/antigravity-oauth-token" 2>/dev/null)" "ya29.agy-8195"
  check "A4 ...prints no ERROR line" "$(grep -c '^ERROR' <<<"$out")" 0
  check "A5 ...and leaves no breadcrumb" \
        "$( [[ -e "$SEAT/.5dive-cred-seed-failed" ]] && echo present || echo absent )" absent
  [[ $fail -eq 0 ]] || { echo "--- step log"; cat "$TMP/step.log"; echo "--- boot"; echo "$out"; }
fi

exit $fail
