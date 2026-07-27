#!/usr/bin/env bash
# DIVE-2102 — the capability registry answers "confirmed holder" and nothing else.
#
# The assertions that matter are the NEGATIVE-SPACE ones: absence, staleness and
# a corrupt store must all render as NOT-CONFIRMED, and none of them may render
# as a confirmed non-holder. That asymmetry is the ticket's blast-radius bound,
# so it is what this file spends most of its arms on.
set -uo pipefail

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

echo
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: capability registry confirms only declared+fresh (capability, AGENT) pairs; absence, staleness and corruption all read as NOT-CONFIRMED ($checked assertions)"
else
  echo "FAIL: $fails of $checked capability-registry assertion(s) failed" >&2
fi
[[ "$fails" -eq 0 ]]
