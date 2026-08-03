#!/usr/bin/env bash
# DIVE-2025 unit harness: does the post-create self-check probe whether the
# credential actually REACHED the agent?
#
# The defect this pins: the self-check answered "is this agent authed?" by
# reading `defer_auth` — a flag recording what the OPERATOR CHOSE. Deferred
# login raised an issue (correct); a COMPLETED login was checked by nothing at
# all, not even an `_hc_ok` entry. So a credential that silently never reached
# the agent still printed "self-check PASS — reachable & autonomous".
#
# WHY THE UID MATTERS, AND WHY THIS HARNESS IS BUILT AROUND IT. `agent create`
# runs as root, and root can read every credential on the box. A readability
# probe run from create's own uid therefore passes unconditionally: it would
# swap a lie for a vacuous truth and this harness would go green on both. So
# the assertions below are written in terms of TWO uids — presence answered as
# root (whose `-e` is the only trustworthy ABSENT verdict, since it traverses
# 0700 profile dirs), readability answered as the agent. `cred_readable_by_agent`
# is the single seam where the agent-uid read happens, and it is stubbed here:
# a harness that shelled out to real `sudo -u` would grade the runner's sudo
# policy, not the code, and would be unrunnable in CI.
#
# The UNREADABLE row is the one that has to survive: it is the shape of
# DIVE-1900 / gh#214, where a present-but-unreadable credential presents as an
# EXPIRED token (`invalid_grant "Malformed auth code"`) so the intuitive fix — a
# re-tap — changes nothing. It must never collapse into ABSENT.
#
# Run: bash tests/selfcheck_cred_reached_unit.sh
set -uo pipefail

# DIVE-2211: name the tree this harness grades. NOTE the absence of
# `2>/dev/null` — redirecting here would swallow the helper's own stderr line,
# which IS the payload.
. "$(dirname "${BASH_SOURCE[0]}")/lib/grading_tree.sh" \
  || printf 'grading tree: UNRESOLVED (tests/lib/grading_tree.sh not reachable; no tree named)\n' >&2
cd "$(dirname "$0")/.."
SRC=src

TMP="$(mktemp -d /tmp/selfcheck-cred-reached.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for f in header.sh lib/error_codes.sh lib/output.sh lib/validation.sh \
         lib/state.sh lib/audit.sh lib/registry.sh; do
  # shellcheck source=/dev/null
  source "$SRC/$f"
done
# shellcheck source=/dev/null
source "$SRC/cmd_auth.sh"          # profile_type_auth_path
# shellcheck source=/dev/null
source "$SRC/cmd_agent_create.sh"

set +e   # header.sh enabled `set -e`; this harness asserts on values, not exits

# --- degrade, do not crash ----------------------------------------------------
# Against a tree WITHOUT the fix the probe is undefined, and a
# command-not-found abort proves nothing about behaviour. This shim makes the
# pre-fix tree fail through the ASSERTIONS instead — emitting nothing, which is
# exactly what origin/main's self-check contributes on the completed-login path.
# It never fires on a tree that has the feature, so it cannot mask a regression.
command -v selfcheck_cred_reached_agent >/dev/null || selfcheck_cred_reached_agent() { :; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains: $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "does NOT contain: $3" "$2"; }

# --- fixtures -----------------------------------------------------------------
export AUTH_PROFILES_DIR="$TMP/profiles"
export AGENT_HOME_ROOT="$TMP/home"
NAME=probe
mkdir -p "$AGENT_HOME_ROOT/agent-$NAME"

# The seam. AGENT_CAN_READ selects what the agent's uid would have answered;
# READ_CALLS records that the probe actually consulted it, which is what keeps
# the "readable" row from passing for the wrong reason (see section 5).
READ_CALLS="$TMP/read-calls"; : > "$READ_CALLS"
AGENT_CAN_READ=1
cred_readable_by_agent() { printf '%s %s\n' "$1" "$2" >> "$READ_CALLS"; (( AGENT_CAN_READ )); }

# A grok profile credential: HOME-redirect type, so the path exercises
# profile_type_auth_path's per-type branch rather than a bare default.
prof=p1
cred="$AUTH_PROFILES_DIR/$prof/grok/.grok/auth.json"
mkdir -p "$(dirname "$cred")"
reset_fixture() {
  rm -f "$AGENT_HOME_ROOT/agent-$NAME/.5dive-cred-seed-failed"
  mkdir -p "$(dirname "$cred")"; printf '{"token":"t"}\n' > "$cred"
  AGENT_CAN_READ=1; : > "$READ_CALLS"
}

echo "== 1. completed login, credential readable by the agent =="
reset_fixture
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "readable credential yields an ok: entry" "$out" "ok:auth credential readable by agent-probe"
hasnt "readable credential raises no issue" "$out" "issue:"

echo "== 2. present but UNREADABLE by the agent — the DIVE-1900 shape =="
reset_fixture
AGENT_CAN_READ=0
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "unreadable raises an issue"            "$out" "issue:"
has "issue names it a perms fault"          "$out" "perms fault"
has "issue names the misleading symptom"    "$out" "Malformed auth code"
has "issue gives the root-only remedy"      "$out" "5dive agent restart"
hasnt "unreadable is NOT reported as absent" "$out" "no auth credential"
hasnt "unreadable does not also report ok"   "$out" "ok:"

echo "== 3. genuinely ABSENT stays distinct from unreadable =="
reset_fixture
rm -f "$cred"
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "absent raises an issue"            "$out" "issue:no auth credential"
has "absent says GO LOG IN"             "$out" "5dive agent auth login grok"
hasnt "absent is not a perms fault"     "$out" "perms fault"
# The empty-file case: a login that started and never finalized (DIVE-1803's
# antigravity onboarding shape) leaves a readable 0-byte token behind.
reset_fixture
: > "$cred"
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "empty credential is called EMPTY"  "$out" "EMPTY"
hasnt "empty credential is not an ok"   "$out" "ok:"

echo "== 4. the boot seed's breadcrumb wins, and carries its own reason =="
reset_fixture
printf 'could not seed grok auth.json from /x (source present but UNREADABLE by agent-probe)\n' \
  > "$AGENT_HOME_ROOT/agent-$NAME/.5dive-cred-seed-failed"
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "breadcrumb raises an issue"              "$out" "issue:credential did NOT reach the agent"
has "breadcrumb's own reason is carried through" "$out" "source present but UNREADABLE"
hasnt "breadcrumb suppresses the ok entry"    "$out" "ok:"
# A readable source with a FAILED seed is the whole point: the source being
# fine says nothing about whether the copy landed. Without the breadcrumb arm
# this row reports a clean PASS.
has "breadcrumb outranks a readable source"   "$out" "did NOT reach"

echo "== 5. the probe consults the AGENT's uid, not create's =="
reset_fixture
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
seam=$(cat "$READ_CALLS")
has "readability was asked of agent-probe" "$seam" "agent-probe"
has "...about the credential path"         "$seam" "$cred"
# Liveness for the negative assertions above: prove the seam can say NO and
# that the code routes that answer somewhere. A stub that always returned true
# would make section 2 unreachable and this whole harness vacuous.
AGENT_CAN_READ=0
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" "")
has "a NO from the seam changes the verdict" "$out" "NOT readable"

echo "== 6. types and paths the probe must NOT invent a verdict for =="
reset_fixture
# opencode has no credential sentinel: profile_type_auth_path returns 1.
out=$(selfcheck_cred_reached_agent "$NAME" opencode "$prof" "")
hasnt "no-sentinel type raises no issue" "$out" "issue:"
hasnt "no-sentinel type claims no ok"    "$out" "ok:"
# BYO writes an API key to combined.env, not the type's OAuth sentinel —
# probing the sentinel would report a false ABSENT for a working agent.
rm -f "$cred"
mkdir -p "$AUTH_PROFILES_DIR/$prof"; printf 'OPENAI_API_KEY=k\n' > "$AUTH_PROFILES_DIR/$prof/combined.env"
out=$(selfcheck_cred_reached_agent "$NAME" grok "$prof" openrouter)
hasnt "BYO does not report a false ABSENT" "$out" "no auth credential"
has   "BYO probes combined.env instead"    "$(cat "$READ_CALLS")" "combined.env"

echo "== 7. the probe is WIRED into the self-check, not merely defined =="
# A function nobody calls fixes nothing. Grade the call site: the completed-
# login arm of the defer_auth branch must reach the probe. Static, because the
# self-check lives mid-way through a ~900-line create and cannot be invoked
# without a real box.
blk=$(awk '/auth: deferred login still pending/,/^  if \(\( \$\{#_hc_issues\[@\]\} == 0 \)\)/' "$SRC/cmd_agent_create.sh")
has "completed-login arm exists (an else on defer_auth)" "$blk" "else"
has "self-check calls the probe"                          "$blk" "selfcheck_cred_reached_agent"
has "issue: lines reach _hc_issues"                       "$blk" "_hc_issues+="
has "ok: lines reach _hc_ok"                              "$blk" "_hc_ok+="

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
