#!/usr/bin/env bash
# DIVE-2130 — `5dive push` was audited NON-UNIFORMLY: a refused push wrote no
# audit row while the sink was demonstrably alive on the same box, same second,
# same binary.
#
# The dispatch site was never the problem. `AUDIT_CMD="push"` is set, the EXIT
# trap fires, and `audit_log push error 3 -- …` is reached — measured under
# `bash -x` on 2026-08-10. The row died AFTER that, twice over, and the two
# causes are independent, which is why the symptom looked incoherent:
#
#   A. THE BARE `return` (universal; landed 2026-08-02 with DIVE-2518).
#      `_actor_identity_claim` ended its agree-branches with a BARE `return`,
#      which yields `$?`. Called from `audit_log`, which the EXIT trap invokes
#      with the process's own exit status still pending, that hands back the
#      TRAP'S status — 3 for a refused push, not the 0 `printf ''` just set
#      (bash 5.2.21; the same function returns 0 when called outside a trap,
#      which is why it read as correct everywhere else). Under `set -e` that
#      killed the shell mid-trap, before the row was rendered. Effect: EVERY
#      dispatcher-audited verb that exited non-zero wrote nothing, fleet-wide.
#      Signature in the production log: `push` error rows stop dead on
#      2026-08-02 while `ok` rows continue to 2026-08-09.
#
#   B. THE UNSEPARATED jq POSITIONALS (predates A; args-dependent).
#      `--args` does NOT stop jq's option parsing. Any AUDIT_ARGS element
#      starting with `-` — and AUDIT_ARGS is `("$@")` for most verbs — made jq
#      exit 2 with "Unknown option", stderr swallowed, `line` empty, and the
#      old `|| return 0` dropped the row in silence, pass or fail. This is what
#      the DIVE-2129 probe (`push … --branch=probe-nonexistent`) hit on
#      2026-07-26, while plain `push DIVE-N` refusals were still logging fine.
#
# Both make "absent from the audit log" mean something other than "it did not
# happen", on the one privileged outward-facing rail whose row is the fleet's
# only record that a delegated push occurred — the DIVE-1989 shape, again.
#
# WHAT IS PINNED HERE (each arm named by the way it can fail):
#   T1  the real shape: a non-zero exit through the EXIT trap lands an `error`
#       row. This is the regression itself; it fails on any re-introduction of
#       an errexit-fatal status inside audit_log, not just on a bare `return`.
#   T2  the mechanism, isolated: `_actor_identity_claim` returns 0 when a
#       non-zero status is pending. T1 alone would pass if someone silenced the
#       trap while leaving the helper leaking the caller's status.
#   T3  a zero exit still lands an `ok` row — the half that never broke, so a
#       fix that trades one for the other is caught.
#   T4  a dash-leading argument survives into `.args` (cause B). Asserted on the
#       VALUE, not on "a row exists": a row that silently lost its arguments is
#       the same evidence failure one field down.
#   T5  a render failure leaves a drop MARKER rather than evaporating. Forced
#       with a non-numeric code, which is the one input `--argjson` still
#       rejects after the `--` fix.
#   T6  tree scan: no bare `return` survives in audit.sh's status-returning
#       helpers. The class, not the instance.
#   T7  suite guard: this run appended nothing to the production audit log.
# Run: bash tests/audit_exit_trap_row_unit.sh   (no root, no network)
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
trap 'rc=$?; rm -rf "${TMP:-}"; echo "HARNESS-RC=$rc"' EXIT
cd "$(dirname "$0")/.."
SRC=src
TMP="$(mktemp -d /tmp/audit-exit-trap-unit.XXXXXX)"

# Suite guard: the production log must be byte-identical at the end. AUDIT_LOG is
# redirected into TMP below, but a regression that hardcodes the path would sail
# past every assertion here while quietly writing to the fleet's log.
REALLOG=/var/log/5dive/agent-audit.log
REALLOG_OFFSET=0
[[ -r "$REALLOG" ]] && REALLOG_OFFSET=$(wc -c <"$REALLOG" 2>/dev/null || echo 0)

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/actor.sh lib/audit.sh; do
  source "$SRC/$f"
done
set +e   # AFTER sourcing: header.sh turns `set -e` back on.

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# The isolated log. `notify/` is created 2770 by audit_init in production; we
# mirror the shape by hand because audit_init chowns root:claude and this suite
# runs unprivileged.
LOGDIR="$TMP/log"
mkdir -p "$LOGDIR/notify"
AUDIT_LOG="$LOGDIR/agent-audit.log"
DROPS="$LOGDIR/notify/audit-drops.log"
reset() { : >"$AUDIT_LOG"; rm -f "$DROPS"; }

# --- T1: a non-zero exit through the real EXIT trap lands an error row -------
# The subshell reproduces production exactly: errexit on, on_exit_audit as the
# EXIT trap, AUDIT_CMD set by the dispatcher, and a refusal-shaped exit. Before
# the fix the shell died inside the trap and this file stayed empty.
reset
( set -e
  trap on_exit_audit EXIT
  AUDIT_CMD="push"; AUDIT_ARGS=("DIVE-2130")
  exit 3
) >/dev/null 2>&1
row=$(grep '"cmd":"push"' "$AUDIT_LOG" 2>/dev/null | tail -1)
got_result=$(jq -r '.result // "<none>"' <<<"${row:-{\}}" 2>/dev/null)
got_code=$(jq -r '.code // "<none>"' <<<"${row:-{\}}" 2>/dev/null)
if [[ "$got_result" == "error" && "$got_code" == "3" ]]; then
  ok_t "a refused (non-zero) verb writes its error row from the EXIT trap"
else
  bad_t "a refused (non-zero) verb writes its error row from the EXIT trap" \
        "result=$got_result code=$got_code row=${row:-<no row written>}"
fi

# --- T2: the mechanism — the helper must not leak a pending status -----------
# Called with 3 pending from inside an EXIT trap, which is the ONLY context that
# exposed it: the same call outside a trap returned 0 before the fix too, so a
# probe without the trap is vacuous and would have passed all along.
claim_rc=$(
  ( set +e
    trap 'v=$(_actor_identity_claim); echo "$?" >"$TMP/claim.rc"' EXIT
    exit 3 ) >/dev/null 2>&1
  cat "$TMP/claim.rc" 2>/dev/null
)
if [[ "$claim_rc" == "0" ]]; then
  ok_t "_actor_identity_claim returns 0 with a non-zero status pending"
else
  bad_t "_actor_identity_claim returns 0 with a non-zero status pending" \
        "returned '${claim_rc:-<unset>}' — a bare \`return\` is leaking \$?"
fi

# --- T3: the success path is unchanged ---------------------------------------
reset
( set -e
  trap on_exit_audit EXIT
  AUDIT_CMD="push"; AUDIT_ARGS=("DIVE-2130")
  exit 0
) >/dev/null 2>&1
got_result=$(jq -r '.result // "<none>"' <<<"$(tail -1 "$AUDIT_LOG" 2>/dev/null)" 2>/dev/null)
if [[ "$got_result" == "ok" ]]; then
  ok_t "a clean exit still writes its ok row"
else
  bad_t "a clean exit still writes its ok row" "result=$got_result"
fi

# --- T4: a dash-leading argument survives into .args -------------------------
reset
audit_log "push" "error" 3 -- "DIVE-2130" "--branch=probe-nonexistent" "--dry-run"
args=$(jq -cr '.args // []' <<<"$(tail -1 "$AUDIT_LOG" 2>/dev/null)" 2>/dev/null)
if [[ "$args" == '["DIVE-2130","--branch=probe-nonexistent","--dry-run"]' ]]; then
  ok_t "flag-shaped arguments are recorded, not eaten by jq's option parser"
else
  bad_t "flag-shaped arguments are recorded, not eaten by jq's option parser" \
        "args=${args:-<no row written>}"
fi

# --- T4b: NO arguments at all still renders -----------------------------------
# The `--` added for T4 lands with nothing after it whenever AUDIT_ARGS is empty
# (`5dive doctor`, and every verb invoked bare). jq 1.7 accepts a trailing `--`,
# but that is a property of jq, not of this code, so it is asserted rather than
# assumed — a fix for the flag case that broke the bare case would be a strictly
# worse trade, since bare invocations are the common ones.
reset
audit_log "doctor" "ok" 0 --
args=$(jq -cr '.args // "<missing>"' <<<"$(tail -1 "$AUDIT_LOG" 2>/dev/null)" 2>/dev/null)
if [[ "$args" == "[]" ]]; then
  ok_t "an argument-less verb still renders its row (empty positional list)"
else
  bad_t "an argument-less verb still renders its row (empty positional list)" \
        "args=${args:-<no row written>}"
fi

# --- T5: a row that cannot be rendered leaves a marker, not a silence --------
reset
audit_log "push" "error" "not-a-number" -- "DIVE-2130" 2>/dev/null
if [[ ! -s "$AUDIT_LOG" && -s "$DROPS" ]] && grep -q 'render-failed' "$DROPS"; then
  ok_t "an unrenderable row leaves a drop marker instead of evaporating"
else
  bad_t "an unrenderable row leaves a drop marker instead of evaporating" \
        "log=$(wc -c <"$AUDIT_LOG" 2>/dev/null) marker=$(cat "$DROPS" 2>/dev/null || echo '<none>')"
fi

# --- T6: the class — no bare `return` in audit.sh's status-returning helpers --
BARE=$(grep -n "printf [^;]*; *return; *}" "$SRC/lib/audit.sh")
if [[ -z "$BARE" ]]; then
  ok_t "no bare \`return\` survives in audit.sh (it would hand back \$?)"
else
  bad_t "no bare \`return\` survives in audit.sh (it would hand back \$?)" "$BARE"
fi

# --- T7: suite guard ----------------------------------------------------------
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
