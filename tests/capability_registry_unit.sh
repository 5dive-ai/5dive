#!/usr/bin/env bash
# DIVE-2102 — the capability registry answers "confirmed holder" and nothing else.
#
# The assertions that matter are the NEGATIVE-SPACE ones: absence, staleness and
# a corrupt store must all render as NOT-CONFIRMED, and none of them may render
# as a confirmed non-holder. That asymmetry is the ticket's blast-radius bound,
# so it is what this file spends most of its arms on.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
STATE_DIR="$work/state"; mkdir -p "$STATE_DIR"
export STATE_DIR
export CAPABILITY_DB="$STATE_DIR/capabilities.json"
export CAPABILITY_LOCK="$STATE_DIR/capabilities.lock"

warn() { printf 'warn: %s\n' "$*" >&2; }
# shellcheck source=../src/lib/capability.sh
source "$ROOT/src/lib/capability.sh"

fails=0; checked=0
ok()   { checked=$((checked+1)); printf '  ok   %s\n' "$1"; }
bad()  { checked=$((checked+1)); fails=$((fails+1)); printf '  FAIL %s\n' "$1" >&2; }
want() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "-- confirmed-holder is TRUE only for a declared, fresh (capability, AGENT) pair"
capability_declare delegated_push dev root provisioned
want "declared holder confirms"                 'capability_confirmed_holder delegated_push dev'
want "SAME capability, DIFFERENT agent: not confirmed" '! capability_confirmed_holder delegated_push main'
want "SAME agent, DIFFERENT capability: not confirmed" '! capability_confirmed_holder audit_append dev'
want "holders lists exactly the declared agent"  '[[ "$(capability_holders delegated_push)" == "dev" ]]'

echo "-- absence is NOT a negative claim, it is silence"
want "undeclared agent is not confirmed"        '! capability_confirmed_holder delegated_push neverseen'
want "unknown capability yields no holders"      '[[ -z "$(capability_holders no_such_cap)" ]]'
want "no capability_is_not_holder exists to be misused" \
     '! declare -F capability_is_not_holder >/dev/null'

echo "-- a STALE row reads as ABSENT, never as present and never as an error"
CAPABILITY_TTL_SECONDS=1
python3 - "$CAPABILITY_DB" <<'PY'
import json,sys,time
p=sys.argv[1]; d=json.load(open(p))
for r in d:
    if r["holder_agent"]=="dev": r["verified_at"]=int(time.time())-99999
json.dump(d,open(p,"w"))
PY
want "stale row is not confirmed"               '! capability_confirmed_holder delegated_push dev'
want "stale row is not listed as a holder"      '[[ -z "$(capability_holders delegated_push)" ]]'
want "stale read exits non-zero, not 2 (usage)" 'capability_confirmed_holder delegated_push dev; [[ $? -eq 1 ]]'
CAPABILITY_TTL_SECONDS=604800

echo "-- a CORRUPT store reads as empty, so it cannot confirm anything"
cp "$CAPABILITY_DB" "$work/backup.json"
printf 'not json at all {{{' > "$CAPABILITY_DB"
want "corrupt store confirms nobody"            '! capability_confirmed_holder delegated_push dev'
want "corrupt store lists no holders"           '[[ -z "$(capability_holders delegated_push)" ]]'
want "corrupt store still accepts a declare"    'capability_declare delegated_push dev root provisioned'
want "...and the store is valid JSON after"     'jq -e . "$CAPABILITY_DB" >/dev/null'

echo "-- re-declaring UPSERTS rather than duplicating"
capability_declare delegated_push dev root provisioned
capability_declare delegated_push dev root backfilled
want "one row per (capability, agent)"          '[[ "$(jq "[.[]|select(.name==\"delegated_push\" and .holder_agent==\"dev\")]|length" "$CAPABILITY_DB")" == "1" ]]'
want "latest source wins"                       '[[ "$(jq -r ".[]|select(.holder_agent==\"dev\")|.source" "$CAPABILITY_DB")" == "backfilled" ]]'

echo "-- teardown drops rows, so a reaped agent stops being a confirmed holder"
capability_declare audit_append gone root provisioned
capability_declare delegated_push gone root provisioned
want "reaped agent confirmed before forget"     'capability_confirmed_holder audit_append gone'
capability_forget_agent gone
want "forget clears EVERY capability for it"    '! capability_confirmed_holder audit_append gone && ! capability_confirmed_holder delegated_push gone'
want "forget leaves other agents intact"        'capability_confirmed_holder delegated_push dev'

echo "-- the declared set matches what the sudoers policy actually grants"
# The registry claiming a grant the policy does not emit is the drift this
# ticket exists to prevent, so assert against render_standard_sudoers itself
# rather than against a second hand-written list.
# shellcheck source=../src/cmd_agent_create.sh
fail() { printf 'fail: %s\n' "$*" >&2; return 1; }
eval "$(awk '/^render_standard_sudoers\(\) \{/,/^\}/' "$ROOT/src/cmd_agent_create.sh")"
for cp in 0 1; do
  policy=$(render_standard_sudoers testuser "$cp")
  emits_push=0; grep -q '5dive _push_do' <<<"$policy" && emits_push=1
  declares_push=0
  _capability_names_for_standard "$cp" | grep -qx delegated_push && declares_push=1
  want "can_push=$cp: policy emits push ($emits_push) == registry declares it ($declares_push)" \
       "[[ $emits_push -eq $declares_push ]]"
done
want "unconditional grants are always declared" \
     '[[ "$(_capability_names_for_standard 0 | wc -l)" -eq 4 ]]'

echo "-- the store must be READABLE BY AGENTS, not just written by root"
# olivia, DIVE-2102 iteration 1: the writer shipped chmod and dropped chown, so
# the store landed root:root 640 — unreadable by the only audience it exists
# for. The read path is fail-soft, so EACCES became the same NOT-CONFIRMED as
# absence and the oracle silently answered "nobody holds anything" forever.
# This harness runs both sides as ONE principal inside its own mktemp -d, so it
# structurally cannot observe the boundary. Assert what it CAN: the writer's
# ownership intent, structurally; and the real ownership only where root can be
# established, otherwise NOT-REACHED — never a pass.
# Not a magic count — the invariant is that EVERY staged temp gets published
# through the helper, so the two numbers must track each other as writers are
# added. A hardcoded 2 went stale the moment reconcile became the third.
want "every mktemp writer publishes through the helper" \
     '[[ "$(grep -c "tmp=\$(mktemp)" "$ROOT/src/lib/capability.sh")" -eq "$(grep -c "_capability_publish \"\$tmp\"" "$ROOT/src/lib/capability.sh")" ]]'
want "the publish helper chowns to the agent-readable group" \
     'awk "/^_capability_publish\(\) \{/,/^\}/" "$ROOT/src/lib/capability.sh" | grep -q "chown root:claude"'
want "no writer mv's a tmp without going through it" \
     '! grep -qE "^\s+mv \"\$tmp\" \"\$CAPABILITY_DB\"" "$ROOT/src/lib/capability.sh"'
if [[ "$(id -u)" -eq 0 ]]; then
  capability_declare delegated_push dev root provisioned
  want "store group is claude (root run)" '[[ "$(stat -c %G "$CAPABILITY_DB")" == "claude" ]]'
  want "store is group-readable (root run)" '[[ "$(stat -c %a "$CAPABILITY_DB")" == "640" ]]'
else
  checked=$((checked+2))
  printf '  NOT-REACHED  real ownership needs root; %s cannot chown (structural arms above stand in)\n' "$(id -un)"
fi

echo "-- capability_forget_agent must HAVE A CALLER (defined is not called)"
# The function existed and was argued for in the commit AND the wiki while
# having ZERO callers, so the drift-by-deletion hole it 'closed' stayed open.
# A grep for the definition would have passed. This asserts the CALL SITE, and
# that it sits in teardown next to the sudoers removal that makes it true.
want "forget is called from src/, not just defined" \
     '[[ "$(grep -rn "capability_forget_agent" "$ROOT/src" --include=*.sh | grep -vc "^.*capability.sh:")" -ge 1 ]]'
want "...and specifically in delete_agent_user" \
     'awk "/^delete_agent_user\(\) \{/,/^\}/" "$ROOT/src/cmd_agent_create.sh" | grep -q capability_forget_agent'
want "the mint is called from write_standard_sudoers" \
     'awk "/^write_standard_sudoers\(\) \{/,/^\}/" "$ROOT/src/cmd_agent_create.sh" | grep -q capability_declare_standard'
want "re-verify is called from the heartbeat tick" \
     'grep -q "_hb_capability_reverify_sweep" "$ROOT/src/cmd_heartbeat.sh" && [[ "$(grep -c "_hb_capability_reverify_sweep" "$ROOT/src/cmd_heartbeat.sh")" -ge 2 ]]'

echo "-- re-verification MEASURES the artifact; it never just bumps verified_at"
# Every arm below is a TRANSITION test with its own fixture: assert the state
# BEFORE, act, assert the state AFTER. Iteration 2's arms shared state and ran in
# order, so two of three mutations to the real function still passed — an arm that
# asserts only a final condition can be satisfied by the state it inherited.
sudoers_dir="$work/sudoers"; mkdir -p "$sudoers_dir"
export CAPABILITY_SUDOERS_DIR="$sudoers_dir"

reset_rv() { # <user> — put the agent in a known CONFIRMED state, independent of prior arms
  capability_forget_agent "$1"
  capability_declare a2a_deliver   "$1" root provisioned
  capability_declare delegated_push "$1" root provisioned
}

# A. policy grants push -> push CONFIRMED, and it is a real re-derivation
reset_rv rvA; capability_forget_agent rvA
render_standard_sudoers rvA 1 > "$sudoers_dir/rvA"
want "A: no rows before"            '! capability_confirmed_holder delegated_push rvA'
capability_reverify_from_sudoers rvA
want "A: push confirmed after"      'capability_confirmed_holder delegated_push rvA'
want "A: stamped source=reverified" '[[ "$(jq -r ".[]|select(.holder_agent==\"rvA\" and .name==\"delegated_push\")|.source" "$CAPABILITY_DB")" == "reverified" ]]'

# B. policy LOSES push -> the row must be DROPPED, not left to expire
reset_rv rvB
render_standard_sudoers rvB 0 > "$sudoers_dir/rvB"
want "B: push confirmed BEFORE"     'capability_confirmed_holder delegated_push rvB'
capability_reverify_from_sudoers rvB
want "B: push DROPPED after"        '! capability_confirmed_holder delegated_push rvB'
want "B: other caps survive"        'capability_confirmed_holder a2a_deliver rvB'

# C. policy file GONE -> every row forgotten (the -r branch)
reset_rv rvC
rm -f "$sudoers_dir/rvC"
want "C: confirmed BEFORE"          'capability_confirmed_holder a2a_deliver rvC'
capability_reverify_from_sudoers rvC
want "C: ALL rows gone after"       '! capability_confirmed_holder a2a_deliver rvC && ! capability_confirmed_holder delegated_push rvC'

# D. a policy that is NOT a standard policy -> decline, do not claim standard caps
reset_rv rvD
printf 'rvD ALL=(ALL) NOPASSWD: ALL\n' > "$sudoers_dir/rvD"
want "D: confirmed BEFORE"          'capability_confirmed_holder a2a_deliver rvD'
capability_reverify_from_sudoers rvD
want "D: admin policy claims NOTHING" '! capability_confirmed_holder a2a_deliver rvD'

echo
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: capability registry confirms only declared+fresh (capability, AGENT) pairs; absence, staleness and corruption all read as NOT-CONFIRMED ($checked assertions)"
else
  echo "FAIL: $fails of $checked capability-registry assertion(s) failed" >&2
fi
[[ "$fails" -eq 0 ]]
