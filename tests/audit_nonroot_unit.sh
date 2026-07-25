#!/usr/bin/env bash
# DIVE-1989 — the audit log recorded PRIVILEGED operations, not agent actions,
# and a lost row left no trace anywhere.
#
# WHY THIS EXISTS. Two independent holes, both of which made "absent from the
# audit log" read as "the action never happened":
#
#   1. Nine `task`/`task need` sub-events were emitted as
#      `[[ $EUID -eq 0 ]] && audit_log ... || true`. Measured on this box before
#      the fix: `5dive task precedent off` as agent-dev produced ZERO rows; the
#      byte-identical command under sudo produced one. The gate looked honest —
#      it skipped a write that would EACCES on the 640 root:claude log — but it
#      long outlived the reason for it: DIVE-1268 gave `_emit_audit_line` a
#      privileged `_audit_append` fallback, so the non-root case has been
#      handled for months. The gates just never got removed, and nothing said
#      the log was therefore root-only.
#   2. Both append paths ended in a bare `|| true`. When the fallback failed the
#      row evaporated silently. DIVE-1988 could not decide whether three
#      DIVE-1801 rows were dropped by that fallback or were fixture reuse, and
#      no amount of re-reading the audit log could ever settle it: a drop is
#      precisely the event the log cannot record.
#
# What is pinned here:
#   1. a non-root caller whose direct append is impossible still lands the row —
#      via the privileged fallback, called with the exact line;
#   2. a FAILED fallback leaves a drop marker carrying the lost row verbatim,
#      so the absence is observable where it would otherwise be invisible;
#   3. a SUCCEEDING fallback leaves no marker (no false alarms);
#   4. a non-JSON line yields no marker rather than a corrupt one;
#   5. the drop marker file is group-writable, so the second agent to drop a row
#      is not itself silenced by the first agent's file ownership (DIVE-1888);
#   6. `audit_log` is never re-gated on $EUID anywhere in src/ — the regression
#      that this whole ticket is about, asserted against the tree.
# Run: bash tests/audit_nonroot_unit.sh   (no root, no network)
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/audit-nonroot-unit.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/audit.sh; do
  source "$SRC/$f"
done
set +e   # AFTER sourcing: header.sh turns `set -e` back on.

# Suite guard: remember the REAL log's length so the check at the bottom proves
# this run never appended to the fleet's audit log. AUDIT_LOG is redirected into
# TMP below, but a regression that hardcodes the path would sail past every
# assertion here while quietly writing to production.
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The isolated log. `notify/` is created 2770 by audit_init in production; we
# mirror the shape by hand because audit_init chowns to root:claude and this
# suite runs unprivileged.
LOGDIR="$TMP/log"
mkdir -p "$LOGDIR/notify"
AUDIT_LOG="$LOGDIR/agent-audit.log"
DROPS="$LOGDIR/notify/audit-drops.log"
ROW='{"ts":"2026-07-25T21:00:00+00:00","user":"agent-dev","cmd":"task precedent","result":"off","code":0,"args":["pref=precedent_autoclear"]}'

# Force the non-root branch: a 000 file is not `-w` for its own unprivileged
# owner, which is exactly the shape of the real 640 root:claude log seen from an
# agent. Skip rather than pass if we are root — `-w` is always true for uid 0, so
# the branch under test is unreachable and a green run would be a lie.
: >"$AUDIT_LOG"; chmod 000 "$AUDIT_LOG"
if [[ $EUID -eq 0 || -w "$AUDIT_LOG" ]]; then
  echo "SKIP - must run unprivileged: the non-root fallback branch is unreachable as root"
  exit 0
fi

SUDO_CALLS="$TMP/sudo.calls"
sudo_ok()   { : >"$SUDO_CALLS"; sudo() { cat >>"$SUDO_CALLS"; return 0; }; }
sudo_fail() { : >"$SUDO_CALLS"; sudo() { cat >>"$SUDO_CALLS"; return 1; }; }
reset()     { : >"$DROPS"; rm -f "$DROPS"; }

# --- 1. non-root caller reaches the privileged fallback with the exact line ---
reset; sudo_ok
_emit_audit_line "$ROW"
if [[ "$(cat "$SUDO_CALLS")" == "$ROW" ]]; then
  ok_t "non-root append routes the exact line through the privileged fallback"
else
  bad_t "non-root append routes the exact line through the privileged fallback" \
        "got: $(cat "$SUDO_CALLS")"
fi

# --- 2. a SUCCEEDING fallback leaves no marker -------------------------------
if [[ ! -e "$DROPS" ]]; then
  ok_t "a delivered row leaves no drop marker"
else
  bad_t "a delivered row leaves no drop marker" "marker: $(cat "$DROPS")"
fi

# --- 3. a FAILED fallback leaves a marker carrying the lost row --------------
reset; sudo_fail
_emit_audit_line "$ROW"
if [[ -s "$DROPS" ]]; then
  GOT_CMD=$(jq -r '.row.cmd' <"$DROPS" 2>/dev/null)
  GOT_REASON=$(jq -r '.reason' <"$DROPS" 2>/dev/null)
  if [[ "$GOT_CMD" == "task precedent" && "$GOT_REASON" == "privileged-fallback-failed" ]]; then
    ok_t "a dropped row is recorded with its payload and a reason"
  else
    bad_t "a dropped row is recorded with its payload and a reason" \
          "cmd=$GOT_CMD reason=$GOT_REASON"
  fi
else
  bad_t "a dropped row is recorded with its payload and a reason" "no marker written"
fi

# --- 4. the marker is group-writable, so a second agent is not silenced -------
# DIVE-1888: the setgid dir gives the file group `claude` but NOT group write, so
# without an explicit chmod only the creating agent could ever append. That would
# make every other agent's drop itself a silent drop — the bug, one layer down.
if [[ -e "$DROPS" ]]; then
  MODE=$(stat -c '%a' "$DROPS")
  if [[ "${MODE: -2:1}" =~ [2367] ]]; then
    ok_t "drop marker is group-writable (mode $MODE)"
  else
    bad_t "drop marker is group-writable" "mode $MODE has no group-write bit"
  fi
else
  bad_t "drop marker is group-writable" "no marker to inspect"
fi

# --- 5. a non-JSON line yields no marker rather than a corrupt one -----------
reset; sudo_fail
_emit_audit_line 'not json at all'
if [[ ! -s "$DROPS" ]]; then
  ok_t "a non-JSON line produces no marker instead of a corrupt one"
else
  bad_t "a non-JSON line produces no marker instead of a corrupt one" "$(cat "$DROPS")"
fi

# --- 6. no audit_log call anywhere in src/ is re-gated on $EUID --------------
# The whole defect, as a grep. Nine sites had this shape; a tenth added later
# would silently re-open the hole for whichever verb it guards.
unset -f sudo
GATED=$(grep -rn 'EUID -eq 0 \]\] && audit_log' "$SRC/" 2>/dev/null)
if [[ -z "$GATED" ]]; then
  ok_t "no audit_log call is gated on \$EUID"
else
  bad_t "no audit_log call is gated on \$EUID" "$GATED"
fi

# --- 7. suite guard: the real fleet log was never touched --------------------
REALLOG_NOW=0
[[ -r "$REALLOG" ]] && REALLOG_NOW=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)
if [[ "$REALLOG_NOW" == "$REALLOG_OFFSET" ]]; then
  ok_t "this run appended nothing to the production audit log"
else
  bad_t "this run appended nothing to the production audit log" \
        "grew from $REALLOG_OFFSET to $REALLOG_NOW bytes"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
