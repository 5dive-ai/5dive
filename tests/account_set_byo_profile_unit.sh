#!/usr/bin/env bash
# `5dive account set` — configure a BYO provider profile without creating an agent.
#
# WHAT IT IS. `account` is the abstraction for reusable auth profiles, but only
# the OAuth half went through it: writing a BYO provider key meant `agent auth
# set`, an AGENT-scoped verb doing account-scoped work. `account set` is a thin
# wrapper over the same writer, so the profile it produces must be the one
# `agent auth set` produces — arm A2 diffs them byte for byte, because a second
# writer of one credential store is a divergence discovered during an incident.
#
# WHAT IT MUST NOT DO. Rotation is a stated reason the verb exists, so it cannot
# simply refuse a profile that already has credentials — but a silent clobber
# makes `account set` a way to quietly re-point a live profile at another
# provider, and every agent bound to it changes behaviour on its next restart
# with nothing in the audit trail saying why. Hence --replace, and hence the
# audit row. And the key must not reach argv or the log: arms D and C grade both
# halves of that, the second against the REAL audit_log rather than the stub.
#
# Nothing here touches the box: a throwaway STATE_DIR/AUTH_PROFILES_DIR, and the
# few calls that would (root, chown/chmod, systemctl, the registry) are stubbed.
#
#   bash tests/account_set_byo_profile_unit.sh   (no root, no network)
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

TMP="$(mktemp -d /tmp/account-set-byo.XXXXXX)"

# shellcheck disable=SC1090
for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh lib/models.sh \
         lib/agent_setup.sh lib/state.sh lib/audit.sh lib/registry.sh lib/actor.sh \
         cmd_agent_create.sh cmd_auth.sh cmd_account.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
set +e
STATE_DIR="$TMP"; AUTH_PROFILES_DIR="$TMP/auth-profiles"; JSON_MODE=0
mkdir -p "$AUTH_PROFILES_DIR"

# --- The box, stubbed out ----------------------------------------------------
# `fail` EXITS in production, so it stays exiting here: a stub that returned
# would let a refused write run on and land the profile anyway, and the harness
# would grade a path production never takes. Refusal arms run in subshells.
require_root()  { :; }
chown()         { :; }
chmod()         { :; }
systemctl()     { :; }
registry_read() { printf '{"agents":{}}'; }
step()          { :; }
warn()          { :; }
AUDIT_CAPTURE="$TMP/audit.captured"
: >"$AUDIT_CAPTURE"
audit_log()     { printf '%s\n' "$*" >>"$AUDIT_CAPTURE"; }

PASS=0; FAIL=0
ok_t()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad_t() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
has()   { [[ "$1" == *"$2"* ]]; }

KEY1='sk-or-v1-firstkey0123456789'
KEY2='sk-or-v1-secondkey987654321'
MODEL='stealth/union-alpha'
envf()  { printf '%s/%s/combined.env' "$AUTH_PROFILES_DIR" "$1"; }
sum()   { [[ -f "$(envf "$1")" ]] && sha256sum <"$(envf "$1")" | cut -d' ' -f1; }
run()   { ( "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }
run_in(){ local k="$1"; shift; ( printf '%s' "$k" | "$@" ) >"$TMP/out" 2>"$TMP/err"; printf '%s' "$?"; }

# --- 0) PRECONDITION: a fresh profile carries nothing ------------------------
account_types_authed_arr fresh-name
[[ -z "${ACCOUNT_TYPES_AUTHED[*]:-}" ]] \
  && ok_t "precondition: an unwritten profile reports no credentials (the refusal arms can be reached)" \
  || bad_t "precondition: a fresh profile is empty" "reports [${ACCOUNT_TYPES_AUTHED[*]:-}]"

# --- A) It writes the profile, and it is the SAME profile agent auth set writes
RC="$(run_in "$KEY1" cmd_account_set or-alpha --type=claude --provider=openrouter --api-key=- --model="$MODEL")"
[[ "$RC" == "0" ]] \
  && ok_t "A0: account set writes a BYO profile with no agent involved" \
  || bad_t "A0: account set succeeds" "rc=$RC err: $(head -2 "$TMP/err")"
{ has "$(cat "$(envf or-alpha)" 2>/dev/null)" "ANTHROPIC_AUTH_TOKEN=${KEY1}" \
  && has "$(cat "$(envf or-alpha)" 2>/dev/null)" "openrouter"; } \
  && ok_t "A1: the profile carries the key and the provider endpoint" \
  || bad_t "A1: the credential landed" "$(cat "$(envf or-alpha)" 2>/dev/null | head -4)"
# The same thing, written the old way, under a different name.
RC="$(run_in "$KEY1" cmd_auth_set claude --auth-profile=or-beta --api-key=- --provider=openrouter --model="$MODEL")"
if [[ "$RC" == "0" ]] && [[ -f "$(envf or-beta)" ]]; then
  [[ "$(sum or-alpha)" == "$(sum or-beta)" ]] \
    && ok_t "A2: byte-identical to the profile 'agent auth set' writes — one writer, not two" \
    || bad_t "A2: the two writers agree" "$(diff <(cat "$(envf or-alpha)") <(cat "$(envf or-beta)") | head -6)"
else
  bad_t "A2: the control profile was written at all" "rc=$RC err: $(head -2 "$TMP/err")"
fi

# --- B) A profile that already has credentials is not clobbered -------------
BEFORE="$(sum or-alpha)"
RC="$(run_in "$KEY2" cmd_account_set or-alpha --type=claude --provider=deepseek --api-key=-)"
[[ "$RC" != "0" ]] \
  && ok_t "B1: a second write over existing claude credentials is REFUSED" \
  || bad_t "B1: the replace guard refuses" "it succeeded (rc=$RC)"
has "$(cat "$TMP/err")" "--replace" \
  && ok_t "B2: ... and the refusal names the flag that would allow it" \
  || bad_t "B2: the refusal names --replace" "stderr: $(head -2 "$TMP/err")"
[[ "$(sum or-alpha)" == "$BEFORE" ]] \
  && ok_t "B3: ... and the profile is byte-for-byte untouched — the guard protected it, not just complained" \
  || bad_t "B3: the refused write changed nothing" "the profile moved"
[[ ! -s "$AUDIT_CAPTURE" ]] \
  && ok_t "B4: ... and a REFUSED replace writes no audit row (nothing happened to record)" \
  || bad_t "B4: no audit row on a refusal" "captured: $(cat "$AUDIT_CAPTURE")"

# --- C) --replace goes through, and it is audited ---------------------------
RC="$(run_in "$KEY2" cmd_account_set or-alpha --type=claude --provider=deepseek --api-key=- --replace)"
[[ "$RC" == "0" ]] \
  && ok_t "C1: with --replace the write goes through — rotation still works" \
  || bad_t "C1: --replace allows the write" "rc=$RC err: $(head -2 "$TMP/err")"
has "$(cat "$(envf or-alpha)")" "ANTHROPIC_AUTH_TOKEN=${KEY2}" \
  && ok_t "C2: ... and the new key replaced the old one" \
  || bad_t "C2: the new key landed" "$(head -3 "$(envf or-alpha)")"
{ has "$(cat "$AUDIT_CAPTURE")" "profile=or-alpha" && has "$(cat "$AUDIT_CAPTURE")" "provider=deepseek"; } \
  && ok_t "C3: ... and an audit row names the profile and the provider" \
  || bad_t "C3: the replace is audited" "captured: $(cat "$AUDIT_CAPTURE")"
{ ! has "$(cat "$AUDIT_CAPTURE")" "$KEY1" && ! has "$(cat "$AUDIT_CAPTURE")" "$KEY2"; } \
  && ok_t "C4: ... and NEVER the key" \
  || bad_t "C4: the audit row omits the key" "captured: $(cat "$AUDIT_CAPTURE")"

# C5 grades the OTHER half of "never the key": main.sh audits the dispatcher's
# own argv, so a literal --api-key=<value> reaches audit_log as an argument.
# Graded against the REAL audit_log, not the capture stub above — the stub is
# this harness's and the redaction is src/lib/audit.sh's.
#
# `_emit_audit_line` is stubbed rather than the log file pointed somewhere: a
# sourced-library caller is FENCED out of the audit log by design (#996), so a
# harness cannot reach the writer, only the line it would have written. That is
# the half this arm is about anyway.
(
  unset -f audit_log; . "$SRC/lib/audit.sh"
  mkdir -p "$TMP/real-audit"
  _emit_audit_line() { printf '%s\n' "$1" >>"$TMP/real-audit/line.json"; }
  audit_log "account set" "ok" 0 -- or-alpha --type=claude "--api-key=$KEY1"
) >/dev/null 2>&1
REAL="$(cat "$TMP/real-audit/line.json" 2>/dev/null)"
{ [[ -n "$REAL" ]] && ! has "$REAL" "$KEY1" && has "$REAL" "<redacted>"; } \
  && ok_t "C5: a literal --api-key in argv is redacted before it reaches the audit log" \
  || bad_t "C5: argv redaction covers --api-key" "row: ${REAL:0:200}"

# --- D) Both key forms, and which one is documented -------------------------
RC="$(run_in "$KEY1" cmd_account_set or-stdin --type=claude --provider=openrouter --api-key=- --model="$MODEL")"
{ [[ "$RC" == "0" ]] && has "$(cat "$(envf or-stdin)" 2>/dev/null)" "$KEY1"; } \
  && ok_t "D1: --api-key=- reads the key from stdin (the documented form)" \
  || bad_t "D1: the stdin form works" "rc=$RC"
RC="$(run cmd_account_set or-literal --type=claude --provider=openrouter --api-key="$KEY1" --model="$MODEL")"
{ [[ "$RC" == "0" ]] && has "$(cat "$(envf or-literal)" 2>/dev/null)" "$KEY1"; } \
  && ok_t "D2: a literal --api-key still works — discouraged is not removed" \
  || bad_t "D2: the literal form still works" "rc=$RC err: $(head -2 "$TMP/err")"
U="$(_account_set_usage)"
{ has "$U" "--replace" && has "$U" "DISCOURAGED" && has "$U" "audited"; } \
  && ok_t "D3: the usage text states BOTH rules — stdin-preferred, and replace-is-required-and-audited" \
  || bad_t "D3: both rules are in the usage text" "usage: ${U:0:300}"

# --- E) `account login` is untouched ----------------------------------------
LOGIN_CALLS="$TMP/login.calls"; : >"$LOGIN_CALLS"
cmd_auth_login() { printf '%s\n' "$*" >>"$LOGIN_CALLS"; }
RC="$(run cmd_account_login or-alpha --type=claude --api-key=-)"
{ [[ "$RC" != "0" ]] && has "$(cat "$TMP/err")" "unknown flag"; } \
  && ok_t "E1: 'account login --api-key=' still fails with unknown flag — login's surface did not grow" \
  || bad_t "E1: login rejects --api-key" "rc=$RC err: $(head -2 "$TMP/err")"
RC="$(run cmd_account_login or-alpha --type=claude)"
{ [[ "$RC" == "0" ]] && has "$(cat "$LOGIN_CALLS")" "--auth-profile=or-alpha"; } \
  && ok_t "E2: ... and the OAuth flow still routes to cmd_auth_login unchanged" \
  || bad_t "E2: login still delegates" "rc=$RC calls: $(cat "$LOGIN_CALLS")"

# --- F) The name and type are validated the way account login validates them -
F_BAD=()
[[ "$(run_in "$KEY1" cmd_account_set 'Bad Name' --type=claude --provider=openrouter --api-key=-)" != "0" ]] || F_BAD+=("invalid-name-accepted")
[[ "$(run_in "$KEY1" cmd_account_set or-x --type=nosuchtype --provider=openrouter --api-key=-)" != "0" ]]  || F_BAD+=("unknown-type-accepted")
[[ "$(run_in "$KEY1" cmd_account_set default --type=claude --provider=openrouter --api-key=-)" != "0" ]]   || F_BAD+=("reserved-default-accepted")
[[ "$(run cmd_account_set or-y --type=claude --provider=openrouter)" != "0" ]]                             || F_BAD+=("missing-api-key-accepted")
(( ${#F_BAD[@]} == 0 )) \
  && ok_t "F1: invalid name, unknown type, the reserved 'default', and a missing key are each refused" \
  || bad_t "F1: the validations hold" "${F_BAD[*]}"

# --- G) THE CLI ACTUALLY ROUTES TO IT ---------------------------------------
# Every arm above calls cmd_account_set directly, which says nothing about
# whether `5dive account set` reaches it: the dispatcher and the usage line live
# in main.sh, and a verb nobody can type is not a feature. Graded through a
# bundle this builds itself, as a black box.
BUNDLE="$TMP/5dive"
if BUILD_OUT="$BUNDLE" ./build.sh >"$TMP/build.log" 2>&1; then
  ok_t "G0: a bundle builds (the artifact the verb ships in)"
  G_BAD=()
  has "$("$BUNDLE" account 2>&1)" "|set|" || G_BAD+=("the account usage line does not name 'set'")
  # Non-root, so the registry lock refuses first — which is itself the proof the
  # arm wants: the dispatcher resolved `set` to a MUTATING account verb rather
  # than falling through to "unknown account command".
  SET_OUT="$(HOME="$TMP" "$BUNDLE" account set 2>&1)"
  has "$SET_OUT" "unknown account command" && G_BAD+=("'account set' is not dispatched: $SET_OUT")
  has "$SET_OUT" "account set"              || G_BAD+=("'account set' did not reach the verb: $SET_OUT")
  has "$("$BUNDLE" --help 2>&1)" "5dive account set" || G_BAD+=("--help does not document the verb")
  (( ${#G_BAD[@]} == 0 )) \
    && ok_t "G1: 5dive account set is dispatched, locked like the other mutating account verbs, and in --help" \
    || bad_t "G1: the CLI routes to the verb" "${G_BAD[*]}"
else
  bad_t "G0: a bundle builds" "$(tail -3 "$TMP/build.log")"
fi

# =============================================================================
# MUTANT — take the replace guard out and the clobber comes back.
# =============================================================================
# BEFORE/AFTER on purpose: "the guard is gone" is also true of a sed that matched
# nothing, which would make the arm below vacuous.
ORIG="$(declare -f cmd_account_set)"
MUT="$(printf '%s\n' "$ORIG" | sed 's/^\([[:space:]]*\)if (( had )) && (( ! replace )); then$/\1if false; then/')"
has "$ORIG" 'had )) && (( ! replace' \
  && ok_t "M0a: BEFORE — the shipped verb really does carry the replace guard" \
  || bad_t "M0a: the guard is in the shipped verb" "not found; the mutant arm below is vacuous"
{ has "$MUT" 'if false; then' && ! has "$MUT" 'had )) && (( ! replace'; } \
  && ok_t "M0b: AFTER — the mutation really removed it (the sed matched)" \
  || bad_t "M0b: the mutation took" "the sed did not match; the mutant is not mutated"

eval "$MUT"
BEFORE="$(sum or-stdin)"
RC="$(run_in "$KEY2" cmd_account_set or-stdin --type=claude --provider=deepseek --api-key=-)"
{ [[ "$RC" == "0" ]] && [[ "$(sum or-stdin)" != "$BEFORE" ]]; } \
  && ok_t "M1: MUTANT — the second write silently REPLACES a live profile's credentials (B1/B3 would be red on it)" \
  || bad_t "M1: mutant clobbers" "rc=$RC profile changed: $([[ "$(sum or-stdin)" != "$BEFORE" ]] && echo yes || echo no)"

eval "$ORIG"
BEFORE="$(sum or-literal)"
RC="$(run_in "$KEY2" cmd_account_set or-literal --type=claude --provider=deepseek --api-key=-)"
{ [[ "$RC" != "0" ]] && [[ "$(sum or-literal)" == "$BEFORE" ]]; } \
  && ok_t "M2: RESTORE took — the guard is back and refuses again" \
  || bad_t "M2: restore took" "rc=$RC (later arms would grade the mutant)"

echo "-----"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
